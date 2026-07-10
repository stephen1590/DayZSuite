#requires -Version 7
<#
.SYNOPSIS
  Stage-and-ship deploy for the Webhooks API (Fastify/Node). TLS/nginx is handled
  SEPARATELY by ../../Provision-Tls.ps1 -Service Webhooks (the NginxService root).

.DESCRIPTION
  Flow: render -> stage -> ship -> run.

    1. RENDER  config.json (from deploy.config.json), plus the templated
               webhooks.service / deploy.env / dayz-ctl / webhooks.sudoers
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
  ./Deploy-Webhooks.ps1            # dry run: render + stage for review
  ./Deploy-Webhooks.ps1 -Apply     # ship + build + install + (re)start

.NOTES
  Never hand-edit the live box. Change config/template/src and redeploy.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$ConfigPath,
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
# Shared code utils live at Dev/common (four levels up: deploy -> Webhooks ->
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
$cfg = Import-DeployConfig -ServiceDeployDir $serviceDeployDir

foreach ($key in @('Server','SshUser','SiteName','AppDir','NodeMajor','NodeBin','RunUser','Port','AuditDir')) {
    if (-not $cfg[$key]) { throw "Webhooks deploy config is missing '$key'." }
}
if (-not $cfg.Dayz -or -not $cfg.Dayz.Unit -or -not $cfg.Dayz.ServerDir) {
    throw "Webhooks deploy config needs Dayz.Unit and Dayz.ServerDir."
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
    dayz            = [ordered]@{ ctl = '/usr/local/bin/dayz-ctl' }
    cooldownSeconds = $cfg.Cooldowns
    playerGuard     = [bool]$cfg.PlayerGuard
    auditDir        = $cfg.AuditDir
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

Set-Content -NoNewline -Path (Join-Path $stageDir 'webhooks.service') -Value (
    Expand-File 'templates/webhooks.service.template' @{
        '__NODE_BIN__'  = $cfg.NodeBin
        '__APP_DIR__'   = $cfg.AppDir
        '__RUN_USER__'  = $cfg.RunUser
        '__AUDIT_DIR__' = $cfg.AuditDir
    })

Set-Content -NoNewline -Path (Join-Path $stageDir 'dayz-ctl') -Value (
    Expand-File 'templates/dayz-ctl.template' @{
        '__UNIT__'       = $cfg.Dayz.Unit
        '__SERVER_DIR__' = $cfg.Dayz.ServerDir
    })

Set-Content -NoNewline -Path (Join-Path $stageDir 'webhooks.sudoers') -Value (
    Expand-File 'templates/webhooks.sudoers.template' @{ '__RUN_USER__' = $cfg.RunUser })

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
Write-Host "Guard  : playerGuard=$($cfg.PlayerGuard)  vpp=$($cfg.Vpp.Enabled)  rules=$(@($cfg.Vpp.Rules).Count)"
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
    Write-Host "  ../../Provision-Tls.ps1 -Service Webhooks -Apply" -ForegroundColor Green
    Write-Host "The deploy printed your HMAC secret + VPP URL once (also in the log above) —" -ForegroundColor Green
    Write-Host "copy them into your caller / VPP now; they are not stored in the repo." -ForegroundColor Green
}

# --- CSV log ------------------------------------------------------------------
if (-not $NoLog) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir 'deploy.csv') -Row ([PSCustomObject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        mode      = if ($Apply) { 'apply' } else { 'dryrun' }
        service   = 'Webhooks'
        server    = $cfg.Server
        appdir    = $cfg.AppDir
    })
}
