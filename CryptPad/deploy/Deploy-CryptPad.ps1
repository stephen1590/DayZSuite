#requires -Version 7
<#
.SYNOPSIS
  Stage-and-ship deploy for the CryptPad app. TLS/nginx is handled SEPARATELY
  by ../../Provision-Tls.ps1 -Service CryptPad (the NginxService root).

.DESCRIPTION
  Flow: render -> stage -> ship -> run.

    1. RENDER  templates/*.template with values from deploy.config.json
    2. STAGE   the full bundle into stage/app/ (config.js, cryptpad.service,
               deploy.env, deploy.sh) — real files you can review/diff
    3. SHIP    (-Apply) rsync stage/app/ to ~/.deploy/<SiteName>/app/ on the box
    4. RUN     (-Apply) ssh: bash deploy.sh there (a STATIC script — see
               remote/deploy.sh; it reads its values from the shipped deploy.env)

  Report-only by default: builds the stage and stops, so a dry run's output IS
  the staged directory. Nothing on the server changes without -Apply.

  This script contains NO tunable values and NO server-bound content. Values
  live in deploy.config.json; content lives in templates/ and remote/. If you
  are hunting for a setting, it is in deploy.config.json.

  Idempotency (clone-once/fetch, data dir + loginSalt preserved, config/unit
  regenerated every run) lives in remote/deploy.sh — read it there.

.EXAMPLE
  ./Deploy-CryptPad.ps1
      Dry run: renders everything into stage/app/ for review. No SSH.

.EXAMPLE
  ./Deploy-CryptPad.ps1 -Apply
      Ship stage/app/ to the server and run deploy.sh (full output is also
      tee'd to logs/deploy_<timestamp>.log).

.NOTES
  Update CryptPad = bump Ref in deploy.config.json, re-run -Apply.
  Never hand-edit the live box. Change config/template and redeploy.
#>
[CmdletBinding()]
param(
    [switch]$Apply,         # actually ship + run (default: stage only)
    [string]$ConfigPath,    # override deploy.config.json
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
# Shared code utils live at Dev/common (four levels up: deploy -> CryptPad ->
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

foreach ($key in @('Server','SshUser','SiteName','AppDir','DataDir','Ref','RepoUrl',
                   'NodeMajor','NodeBin','RunUser','MaxUploadMb','DefaultStorageGb')) {
    if (-not $cfg[$key]) { throw "CryptPad deploy config is missing '$key'." }
}
$Hostnames = @($cfg.Hostnames)
if ($Hostnames.Count -lt 2) {
    throw "CryptPad needs two Hostnames (main + sandbox) in deploy.config.json; got $($Hostnames.Count)."
}
foreach ($tool in 'rsync', 'ssh') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' not found on PATH." }
}

$SshPort = if ($cfg.SshPort) { [int]$cfg.SshPort } else { 22 }

# --- Derived values ---------------------------------------------------------
$mainOrigin          = "https://$($Hostnames[0])"
$sandboxOrigin       = "https://$($Hostnames[1])"
$maxUploadBytes      = [int64]$cfg.MaxUploadMb * 1024 * 1024
$defaultStorageBytes = [int64]$cfg.DefaultStorageGb * 1024 * 1024 * 1024

# adminKeys -> JS array body: one quoted key per line, aligned under the token.
$AdminKeys   = @($cfg.AdminKeys) | Where-Object { $_ -and $_.Trim() }
$adminKeysJs = ($AdminKeys | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ",`n        "

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

Set-Content -NoNewline -Path (Join-Path $stageDir 'config.js') -Value (
    Expand-File 'templates/config.js.template' @{
        '__MAIN_ORIGIN__'           = $mainOrigin
        '__SANDBOX_ORIGIN__'        = $sandboxOrigin
        '__DATA_DIR__'              = $cfg.DataDir
        '__MAX_UPLOAD_BYTES__'      = "$maxUploadBytes"
        '__ADMIN_KEYS__'            = $adminKeysJs
        '__DEFAULT_STORAGE_BYTES__' = "$defaultStorageBytes"
        '__DEFAULT_STORAGE_GB__'    = "$($cfg.DefaultStorageGb)"
    })

Set-Content -NoNewline -Path (Join-Path $stageDir 'cryptpad.service') -Value (
    Expand-File 'templates/cryptpad.service.template' @{
        '__NODE_BIN__' = $cfg.NodeBin
        '__APP_DIR__'  = $cfg.AppDir
        '__DATA_DIR__' = $cfg.DataDir
        '__RUN_USER__' = $cfg.RunUser
    })

Set-Content -NoNewline -Path (Join-Path $stageDir 'deploy.env') -Value (
    Expand-File 'templates/deploy.env.template' @{
        '__REF__'        = $cfg.Ref
        '__REPO_URL__'   = $cfg.RepoUrl
        '__NODE_MAJOR__' = "$($cfg.NodeMajor)"
        '__RUN_USER__'   = $cfg.RunUser
        '__SSH_USER__'   = $cfg.SshUser
        '__APP_DIR__'    = $cfg.AppDir
        '__DATA_DIR__'   = $cfg.DataDir
    })

Copy-Item (Join-Path $PSScriptRoot 'remote/deploy.sh') (Join-Path $stageDir 'deploy.sh')

# --- Report -----------------------------------------------------------------
$target = "$($cfg.SshUser)@$($cfg.Server)"
Write-Host "Target : $target (port $SshPort)   Ref: $($cfg.Ref)   Node: $($cfg.NodeMajor).x" -ForegroundColor Cyan
Write-Host "Origins: main=$mainOrigin  sandbox=$sandboxOrigin"
Write-Host "Admin  : $($AdminKeys.Count) key(s)   Quota: $($cfg.DefaultStorageGb) GB/user   Upload: $($cfg.MaxUploadMb) MB"
if ($AdminKeys.Count -eq 0) {
    Write-Host "         (no admin yet — register at $mainOrigin, copy Settings > Public Signing Key into deploy.config.json AdminKeys, redeploy)" -ForegroundColor DarkYellow
}
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
    Write-Host "  ../../Provision-Tls.ps1 -Service CryptPad -Apply" -ForegroundColor Green
    Write-Host "Then browse $mainOrigin (needs HTTPS to function)." -ForegroundColor Green
}

# --- CSV log ------------------------------------------------------------------
if (-not $NoLog) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir 'deploy.csv') -Row ([PSCustomObject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        mode      = if ($Apply) { 'apply' } else { 'dryrun' }
        service   = 'CryptPad'
        server    = $cfg.Server
        ref       = $cfg.Ref
        appdir    = $cfg.AppDir
    })
}
