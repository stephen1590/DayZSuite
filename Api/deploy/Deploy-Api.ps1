#requires -Version 7
<#
.SYNOPSIS
  Stage-and-ship deploy for the API service (Fastify/Node). TLS/nginx is handled
  SEPARATELY by ../../Provision-Tls.ps1 -Service Api (the NginxService root).

.DESCRIPTION
  Flow: render -> stage -> ship -> run.

    1. RENDER  config.json (from deploy.config.json), plus the templated
               api.service / deploy.env / dayz-ctl / api.sudoers
    2. STAGE   the full bundle + the app source (src/, package.json, tsconfig.json)
               into stage/app/ — real files you can review/diff
    3. SHIP    (-Apply) rsync stage/app/ to ~/.deploy/<SiteName>/app/ on the box
    4. RUN     (-Apply) ssh: bash deploy.sh there (a STATIC script — see
               remote/deploy.sh; it reads its values from the shipped deploy.env,
               builds the app, installs the unit + the dayz-ctl privilege bridge,
               and generates secrets ONCE)

  Report-only by default: builds the stage and stops, so a dry run's output IS the
  staged directory. Nothing on the server changes without -Apply.

  This script contains NO tunable values and NO secrets. Values live in
  deploy.config.json; the HMAC secret + VPP token are generated on the box by
  deploy.sh and printed once.

.EXAMPLE
  ./Deploy-Api.ps1            # dry run: render + stage for review
  ./Deploy-Api.ps1 -Apply     # ship + build + install + (re)start

.NOTES
  Never hand-edit the live box. Change config/template/src and redeploy.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [ValidateSet('staging','prod')]
    [string]$Env = 'staging',   # which box: staging default, prod explicit (../../STAGING-PLAN.md) - picks host.config.<env>.env
    [string]$ConfigPath,
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
# Shared code utils live at Dev/common (four levels up: deploy -> Api ->
# NginxService -> UbuntuHost -> Dev).
. (Join-Path $PSScriptRoot '../../../../common/Utils.ps1')
# Deploy-config loader lives at the NginxService root (../.. from this deploy/).
. (Join-Path $PSScriptRoot '../../Load-DeployConfig.ps1')

# --- Load the service deploy config (the ONLY source of tunable values) ----
# host.config.env + deploy.config.json, merged by Import-DeployConfig; ${Key}
# refs resolved. -ConfigPath overrides which deploy.config.json is used.
$serviceDeployDir = if ($ConfigPath) {
    if (-not (Test-Path $ConfigPath)) { throw "No deploy config at: $ConfigPath (copy deploy.config.example.json -> deploy.config.json)." }
    Split-Path -Parent (Resolve-Path $ConfigPath).Path
} else { $PSScriptRoot }
$cfg = Import-DeployConfig -ServiceDeployDir $serviceDeployDir -Env $Env

foreach ($key in @('Server','SshUser','SiteName','AppDir','NodeMajor','NodeBin','RunUser','Port','AuditDir')) {
    if (-not $cfg[$key]) { throw "Api deploy config is missing '$key'." }
}
if (-not $cfg.Dayz -or -not $cfg.Dayz.Unit -or -not $cfg.Dayz.ServerDir) {
    throw "Api deploy config needs Dayz.Unit and Dayz.ServerDir."
}
$restartWarnSec = if ($cfg.Dayz.RestartWarningSeconds) { [int]$cfg.Dayz.RestartWarningSeconds } else { 15 }

# Log-noise pre-filter (ERE) baked into dayz-ctl's log-read. Single-quote-escaped
# for the bash assignment. Absent/empty = filter off.
$logNoise = if ($cfg.Dayz.LogNoiseFilter) { "$($cfg.Dayz.LogNoiseFilter)" } else { '' }
if ($logNoise -match "`t|`n") { throw "Api Dayz.LogNoiseFilter must not contain tabs or newlines." }
if ($logNoise -match '\^') { throw "Api Dayz.LogNoiseFilter must not use ^ anchors (it also runs against numbered 'N:text' streams)." }
$logNoiseSq = $logNoise.Replace("'", "'\''")

# Config-retrieval allowlist, baked into dayz-ctl as two tables. THIS is the mask:
# only these are retrievable, only relative to ServerDir. Two entry shapes:
#   { name, path }  -> a single file          -> CONFIG_MAP  "name<TAB>relpath"
#   { group, dir }  -> a whole folder (its files, recursively, enumerated on the
#                      box at read time)       -> CONFIG_DIRS "group<TAB>reldir"
# Validate here; dayz-ctl re-checks every read. Absent = feature off.
#
# SOURCE = the SINGLE config registry in the DayZ-Server repo (config is a DayZ-Server
# dependency; the API references it by SIBLING PATH at deploy time — read here on the dev
# machine, rendered into the box's dayz-ctl; nothing extra lands on the box). Default path
# assumes the standard checkout (DayZ-Server beside NginxService under UbuntuHost); override
# with "ConfigRegistry" in deploy.config.json. Rows map to the two shapes above:
#   box (single file), web != 'none'  -> { name, path=box, writable }
#   dir (folder)                       -> { group, dir, subfolders }
# web:'none' rows are deploy-seeded-but-not-web-exposed (e.g. per-map StaticAIB) — skipped.
$registryPath = if ($cfg.ConfigRegistry) {
    if ([IO.Path]::IsPathRooted($cfg.ConfigRegistry)) { $cfg.ConfigRegistry } else { Join-Path $PSScriptRoot $cfg.ConfigRegistry }
} else { Join-Path $PSScriptRoot '../../../DayZ-Server/config-registry.json' }
if (-not (Test-Path $registryPath)) {
    throw "Config registry not found at: $registryPath`nThe web config allowlist is defined in the DayZ-Server repo (config-registry.json). Check that repo out beside NginxService, or set 'ConfigRegistry' in deploy.config.json."
}
$registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
$allConfigs = @($registry.surfaces) | Where-Object { $_ -and ($_.web -ne 'none') } | ForEach-Object {
    if ($_.dir) { [pscustomobject]@{ group = $_.group; dir = $_.dir; subfolders = $_.subfolders } }
    else        { [pscustomobject]@{ name = $_.name; path = $_.box; writable = [bool]$_.writable } }
}
$fileEntries  = @($allConfigs | Where-Object { $_.path })
$dirEntries   = @($allConfigs | Where-Object { $_.dir -and -not $_.path })
foreach ($c in $fileEntries) {
    if ("$($c.name)" -notmatch '^[A-Za-z0-9_.-]+$') { throw "Api Configs: invalid file name '$($c.name)' (allowed: A-Z a-z 0-9 . _ -)." }
    if ("$($c.path)" -match '^\s*/' -or "$($c.path)" -match '\.\.') { throw "Api Configs: '$($c.name)' path must be relative to ServerDir with no '..': $($c.path)." }
}
foreach ($c in $dirEntries) {
    if (-not "$($c.group)".Trim()) { throw "Api Configs: folder entry for dir '$($c.dir)' needs a 'group' label." }
    if ("$($c.group)" -match "`t|`n") { throw "Api Configs: group label must not contain tabs/newlines: '$($c.group)'." }
    if ("$($c.dir)" -match '^\s*/' -or "$($c.dir)" -match '\.\.') { throw "Api Configs: folder 'dir' must be relative to ServerDir with no '..': $($c.dir)." }
    foreach ($s in @($c.subfolders)) {
        if ("$s" -match '^\s*/' -or "$s" -match '\.\.') { throw "Api Configs: subfolder must be relative to the dir with no '..': '$s' (in '$($c.group)')." }
        if ("$s" -match "[,`t`n]") { throw "Api Configs: subfolder must not contain comma/tab/newline: '$s' (in '$($c.group)')." }
    }
}
$configMap  = ($fileEntries | ForEach-Object { "$($_.name)`t$($_.path)" }) -join "`n"
# CONFIG_DIRS: "group<TAB>reldir<TAB>subfolders". Files come from the dir root
# (non-recursive) plus each named subfolder's root. Empty subfolders = root only.
$configDirs = ($dirEntries | ForEach-Object {
    $subs = if ($_.subfolders) { (@($_.subfolders | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ',') } else { '' }
    "$($_.group)`t$($_.dir)`t$subs"
}) -join "`n"
# Global ignore-filetype: extensions hidden from every FOLDER listing (single-file
# entries are always shown). Normalized to a lowercase, dot-stripped comma list.
foreach ($x in @($cfg.ConfigIgnoreExt)) {
    if ("$x" -and "$x" -notmatch '^[.\sA-Za-z0-9]+$') { throw "Api ConfigIgnoreExt: '$x' is not a plain extension." }
}
$ignoreExt = if ($cfg.ConfigIgnoreExt) {
    (@($cfg.ConfigIgnoreExt | ForEach-Object { "$_".Trim().TrimStart('.').ToLower() } | Where-Object { $_ }) -join ',')
} else { '' }
# Whole-file WRITE mask -> WRITE_MAP "name<TAB>relpath": the Configs entries flagged
# "writable": true (box-owned operational lists). Only these may be replaced whole
# (snapshot-first) via set-file; dayz-ctl re-validates every write. None flagged =
# feature off. Field-patch writes (config-overrides) are separate and need no flag.
foreach ($c in @($allConfigs | Where-Object { $_.writable -and -not $_.path })) {
    throw "Api Configs: 'writable' applies only to single-file entries (offender: group '$($c.group)$($c.dir)') — a folder can't be whole-file writable."
}
$writeEntries = @($fileEntries | Where-Object { $_.writable })
$writeMap = ($writeEntries | ForEach-Object { "$($_.name)`t$($_.path)" }) -join "`n"

# Generated-artifact READ-ONLY mask -> GENERATED (one ServerDir-relative glob per line). These are
# prestart COMPILER outputs (config-registry.json "generated"): the web editor renders any match
# read-only (no edit/save) and override-write REFUSES a patch targeting one, so an auto-generated
# value can never be hand-edited into a silent loss. '*' = the mission wildcard; no leading '/' or
# '..'. Absent = feature off.
$generatedList = @($registry.generated)
foreach ($g in $generatedList) {
    if ("$g" -match '^\s*/' -or "$g" -match '\.\.') { throw "Api Configs: generated path must be ServerDir-relative with no '..': '$g'." }
    if ("$g" -notmatch '^[A-Za-z0-9_.*/-]+$') { throw "Api Configs: generated path has invalid chars (allowed A-Z a-z 0-9 . _ - / *): '$g'." }
}
$generated = (@($generatedList | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join "`n")

# Mod-docs browser -> DOCS_* template vars. Roots are ServerDir-relative globs (e.g. "@*"),
# Extensions/Names filter the recursive scan, MaxDepth bounds it. All read-only.
$docs = $cfg.Docs
$docsRoots = ''; $docsExt = ''; $docsNames = ''; $docsMaxDepth = '3'
if ($docs) {
    foreach ($r in @($docs.Roots)) {
        if ("$r" -match '^\s*/' -or "$r" -match '\.\.') { throw "Api Docs.Roots: root must be a ServerDir-relative glob with no '..': '$r'." }
        if ("$r" -match "[\s`t`n]") { throw "Api Docs.Roots: root glob must not contain whitespace: '$r'." }
    }
    foreach ($x in @($docs.Extensions)) {
        if ("$x" -and "$x" -notmatch '^[.A-Za-z0-9]+$') { throw "Api Docs.Extensions: '$x' is not a plain extension." }
    }
    foreach ($n in @($docs.Names)) {
        if ("$n" -and "$n" -notmatch '^[A-Za-z0-9_-]+$') { throw "Api Docs.Names: '$n' is not a plain name prefix." }
    }
    $docsRoots = (@($docs.Roots    | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' ')
    $docsExt   = (@($docs.Extensions | ForEach-Object { "$_".Trim().TrimStart('.').ToLower() } | Where-Object { $_ }) -join ',')
    $docsNames = (@($docs.Names     | ForEach-Object { "$_".Trim().ToLower() } | Where-Object { $_ }) -join ' ')
    if ($null -ne $docs.MaxDepth) { $docsMaxDepth = "$([int]$docs.MaxDepth)" }
}

# Log-source registry (Dayz.LogSources) -> "id<TAB>reldir<TAB>glob<TAB>label" rows for
# dayz-ctl's log-sources/log-list/log-read. The id set is closed here, so the box never
# forms a dir or glob from caller input - only a matched id selects a fixed dir + pattern.
# Same field guards as Docs.Roots (ServerDir-relative, no '..', no whitespace). Labels may
# carry spaces but no single quote (they render into a single-quoted bash var) or TAB/NL.
$logSources = ''
if ($cfg.Dayz.LogSources) {
    $seenLogId = @{}
    foreach ($s in @($cfg.Dayz.LogSources)) {
        $id = "$($s.id)".Trim(); $dir = "$($s.dir)".Trim(); $glob = "$($s.glob)".Trim(); $label = "$($s.label)".Trim()
        if ($id -notmatch '^[a-z0-9_-]+$') { throw "Api Dayz.LogSources: id '$id' must be [a-z0-9_-]." }
        if ($seenLogId.ContainsKey($id)) { throw "Api Dayz.LogSources: duplicate id '$id'." }
        $seenLogId[$id] = $true
        if (-not $dir -or $dir -match '^\s*/' -or $dir -match '\.\.') { throw "Api Dayz.LogSources[$id]: dir must be a ServerDir-relative path with no '..': '$dir'." }
        if ($dir -match "[\s`t`n]") { throw "Api Dayz.LogSources[$id]: dir must not contain whitespace: '$dir'." }
        if (-not $glob -or $glob -match '/' -or $glob -match '\.\.') { throw "Api Dayz.LogSources[$id]: glob must be a bare filename pattern (no '/' or '..'): '$glob'." }
        if ($glob -match "[\s`t`n]") { throw "Api Dayz.LogSources[$id]: glob must not contain whitespace: '$glob'." }
        if (-not $label) { $label = $id }
        if ($label -match "['`t`n]") { throw "Api Dayz.LogSources[$id]: label must not contain single quotes, tabs or newlines: '$label'." }
        $logSources += "$id`t$dir`t$glob`t$label`n"
    }
    $logSources = $logSources.TrimEnd("`n")
}
foreach ($tool in 'rsync', 'ssh') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' not found on PATH." }
}
$SshPort = if ($cfg.SshPort) { [int]$cfg.SshPort } else { 22 }
$appSrc  = Join-Path $PSScriptRoot '../app'
if (-not (Test-Path (Join-Path $appSrc 'package.json'))) { throw "App source not found at $appSrc" }

# --- RENDER + STAGE ---------------------------------------------------------
function Expand-File([string]$RelPath, [hashtable]$Vars) {
    $p = Join-Path $PSScriptRoot $RelPath
    if (-not (Test-Path $p)) { throw "Template not found: $p" }
    $text = Get-Content -Raw $p
    foreach ($k in $Vars.Keys) { $text = $text.Replace($k, [string]$Vars[$k]) }
    return $text
}

$stageDir = Join-Path $PSScriptRoot 'stage/app'
if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }   # generated output, rebuilt every run
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

# config.json — the app's non-secret runtime settings, built from deploy.config.json
# (ConvertTo-Json rather than token-replacement, because it carries structured data
# like cooldowns and VPP rules). Secrets are NOT here.
$appConfig = [ordered]@{
    host            = '127.0.0.1'
    port            = [int]$cfg.Port
    dayz            = [ordered]@{
        ctl                   = '/usr/local/bin/dayz-ctl'
        restartWarningSeconds = $restartWarnSec
    }
    cooldownSeconds = $cfg.Cooldowns
    playerGuard     = [bool]$cfg.PlayerGuard
    auditDir        = $cfg.AuditDir
    keysFile        = if ($cfg.KeysFile) { $cfg.KeysFile } else { '/var/lib/api/keys.json' }
    heightmapsDir   = if ($cfg.HeightmapsDir) { $cfg.HeightmapsDir } else { '/var/lib/api/heightmaps' }
    rateLimit       = [ordered]@{ max = [int]$cfg.RateLimit.Max; windowMs = [int]$cfg.RateLimit.WindowMs }
    vpp             = [ordered]@{ enabled = [bool]$cfg.Vpp.Enabled; rules = @($cfg.Vpp.Rules) }
}
Set-Content -NoNewline -Path (Join-Path $stageDir 'config.json') -Value (
    $appConfig | ConvertTo-Json -Depth 6)

Set-Content -NoNewline -Path (Join-Path $stageDir 'deploy.env') -Value (
    Expand-File 'templates/deploy.env.template' @{
        '__NODE_MAJOR__' = "$($cfg.NodeMajor)"
        '__RUN_USER__'   = $cfg.RunUser
        '__APP_DIR__'    = $cfg.AppDir
        '__AUDIT_DIR__'  = $cfg.AuditDir
    })

Set-Content -NoNewline -Path (Join-Path $stageDir 'api.service') -Value (
    Expand-File 'templates/api.service.template' @{
        '__NODE_BIN__'  = $cfg.NodeBin
        '__APP_DIR__'   = $cfg.AppDir
        '__RUN_USER__'  = $cfg.RunUser
        '__AUDIT_DIR__' = $cfg.AuditDir
    })

Set-Content -NoNewline -Path (Join-Path $stageDir 'dayz-ctl') -Value (
    Expand-File 'templates/dayz-ctl.template' @{
        '__UNIT__'       = $cfg.Dayz.Unit
        '__SERVER_DIR__' = $cfg.Dayz.ServerDir
        '__CONFIG_MAP__'  = $configMap
        '__CONFIG_DIRS__' = $configDirs
        '__IGNORE_EXT__'  = $ignoreExt
        '__WRITE_MAP__'   = $writeMap
        '__GENERATED__'   = $generated
        '__LOG_NOISE__'   = $logNoiseSq
        '__DOCS_ROOTS__'    = $docsRoots
        '__DOCS_EXT__'      = $docsExt
        '__DOCS_NAMES__'    = $docsNames
        '__DOCS_MAXDEPTH__' = $docsMaxDepth
        '__LOG_SOURCES__'   = $logSources
    })

Set-Content -NoNewline -Path (Join-Path $stageDir 'api.sudoers') -Value (
    Expand-File 'templates/api.sudoers.template' @{ '__RUN_USER__' = $cfg.RunUser })

Copy-Item (Join-Path $PSScriptRoot 'remote/deploy.sh') (Join-Path $stageDir 'deploy.sh')

# App source (built ON the box). Ship package.json/tsconfig/src; never node_modules
# or a prior dist — deploy.sh installs + builds fresh.
Copy-Item (Join-Path $appSrc 'package.json') $stageDir
Copy-Item (Join-Path $appSrc 'tsconfig.json') $stageDir
if (Test-Path (Join-Path $appSrc 'package-lock.json')) { Copy-Item (Join-Path $appSrc 'package-lock.json') $stageDir }
Copy-Item (Join-Path $appSrc 'src') $stageDir -Recurse

# --- Report -----------------------------------------------------------------
$target = "$($cfg.SshUser)@$($cfg.Server)"
Write-Host "Target : $target (port $SshPort)   Node: $($cfg.NodeMajor).x   App: $($cfg.AppDir)" -ForegroundColor Cyan
Write-Host "Public : https://$($cfg.Hostnames[0])   ->  127.0.0.1:$($cfg.Port)"
Write-Host "DayZ   : unit '$($cfg.Dayz.Unit)'  dir $($cfg.Dayz.ServerDir)"
Write-Host "Configs: $(@($fileEntries).Count) file(s)$(if (@($fileEntries).Count) { ' (' + ((@($fileEntries) | ForEach-Object { $_.name }) -join ', ') + ')' }) + $(@($dirEntries).Count) folder(s)$(if (@($dirEntries).Count) { ' (' + ((@($dirEntries) | ForEach-Object { $_.dir }) -join ', ') + ')' })"
Write-Host "Guard  : playerGuard=$($cfg.PlayerGuard)  restartWarn=${restartWarnSec}s  vpp=$($cfg.Vpp.Enabled)  rules=$(@($cfg.Vpp.Rules).Count)"
Write-Host "Staged : $stageDir" -ForegroundColor Cyan
Get-ChildItem $stageDir | ForEach-Object { Write-Host ("         {0,-20} {1,8:n0} B" -f $_.Name, $_.Length) }

# --- SHIP + RUN (or stop after staging) --------------------------------------
$remoteStage = ".deploy/$($cfg.SiteName)/app"   # relative to the SSH user's home
$sshArgs = @('-p', "$SshPort"); if ($cfg.SshKey) { $sshArgs += @('-i', $cfg.SshKey) }
$logDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'

if (-not $Apply) {
    Write-Host "== DRY RUN — stage built, nothing shipped (review the files above, then -Apply) ==" -ForegroundColor Yellow
} else {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $runLog = Join-Path $logDir "deploy_$((Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss'))Z.log"
    Write-Host "== Shipping stage/app -> ${target}:$remoteStage ==" -ForegroundColor Green

    & ssh @sshArgs $target "mkdir -p '$remoteStage'"
    if ($LASTEXITCODE -ne 0) { throw "ssh mkdir failed (exit $LASTEXITCODE)." }

    $sshCmd = (@('ssh') + $sshArgs) -join ' '
    & rsync -az --delete -e $sshCmd "$stageDir/" "${target}:$remoteStage/"
    if ($LASTEXITCODE -ne 0) { throw "rsync failed (exit $LASTEXITCODE)." }

    Write-Host "== Running deploy.sh on the server (full output -> $runLog) ==" -ForegroundColor Green
    & ssh @sshArgs $target "bash '$remoteStage/deploy.sh'" 2>&1 | Tee-Object -FilePath $runLog
    if ($LASTEXITCODE -ne 0) { throw "Remote deploy failed (exit $LASTEXITCODE). See $runLog" }

    Write-Host ""
    Write-Host "Done. Provision TLS if you haven't yet:" -ForegroundColor Green
    Write-Host "  ../../Provision-Tls.ps1 -Service Api -Apply" -ForegroundColor Green
    Write-Host "The deploy printed your HMAC secret + VPP URL once (also in the log above) —" -ForegroundColor Green
    Write-Host "copy them into your caller / VPP now; they are not stored in the repo." -ForegroundColor Green
}

# --- CSV log ------------------------------------------------------------------
if (-not $NoLog) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir 'deploy.csv') -Row ([PSCustomObject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        mode      = if ($Apply) { 'apply' } else { 'dryrun' }
        service   = 'Api'
        server    = $cfg.Server
        appdir    = $cfg.AppDir
    })
}
