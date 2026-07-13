#requires -Version 7
<#
.SYNOPSIS
  Deploy the Config Viewer static app to the Ubuntu server over SSH.

.DESCRIPTION
  Read-only by default: shows an rsync DRY-RUN of what would change under the
  webroot. Nothing is written to the server until you pass -Push. There is no
  build step — the app is a single static folder (../web).

  TLS + the nginx vhost are provisioned SEPARATELY, once, by
  ../../Provision-Tls.ps1 -Service ConfigViewer (that also creates the webroot).
  This script only ships content into it.

  Server details come from deploy/deploy.config.json (gitignored) merged over the
  shared host.config.env. Copy deploy.config.example.json to deploy.config.json,
  or pass the parameters directly.

.EXAMPLE
  ./Deploy-ConfigViewer.ps1
      Dry-run. Shows what would change on the server. No changes made.

.EXAMPLE
  ./Deploy-ConfigViewer.ps1 -Push
      Actually sync ../web to the server webroot.

.NOTES
  Never hand-edit the live server. Change ../web or this script and redeploy.
#>
[CmdletBinding()]
param(
    [switch]$Push,                       # actually deploy (default: dry-run only)
    [string]$Server,                     # e.g. myhost.example.com
    [string]$SshUser,                    # e.g. deploy
    [string]$RemotePath,                 # e.g. /var/www/config-viewer
    [int]$SshPort = 22,
    [string]$SshKey,                     # path to private key (optional)
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
$SiteRoot = Split-Path -Parent $PSScriptRoot          # ConfigViewer/
. (Join-Path $PSScriptRoot '../../../../common/Utils.ps1')
# Deploy-config loader lives at the NginxService root (../.. from this deploy/).
. (Join-Path $PSScriptRoot '../../Load-DeployConfig.ps1')

# --- Load config file (params override it) -------------------------------
$configJson = Join-Path $PSScriptRoot 'deploy.config.json'
if (Test-Path $configJson) {
    $cfg = Import-DeployConfig -ServiceDeployDir $PSScriptRoot
    if (-not $Server)     { $Server     = $cfg.Server }
    if (-not $SshUser)    { $SshUser    = $cfg.SshUser }
    if (-not $RemotePath) { $RemotePath = $cfg.RemotePath }
    if (-not $SshKey -and $cfg.SshKey) { $SshKey = $cfg.SshKey }
    if ($cfg.SshPort -and $SshPort -eq 22) { $SshPort = [int]$cfg.SshPort }
}

foreach ($req in @{ Server = $Server; SshUser = $SshUser; RemotePath = $RemotePath }.GetEnumerator()) {
    if (-not $req.Value) {
        throw "Missing '$($req.Key)'. Set it in deploy/deploy.config.json or pass -$($req.Key)."
    }
}

foreach ($tool in 'rsync', 'ssh') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' not found on PATH. Install it (Arch: pacman -S rsync openssh)."
    }
}

$webDir = Join-Path $SiteRoot 'web'
if (-not (Test-Path (Join-Path $webDir 'index.html'))) { throw "No app at $webDir (expected index.html)." }

# --- Stage vendored assets + the API spec into web/ ----------------------
# The API tab embeds Swagger UI (vendored, self-hosted — no CDN) and loads the OpenAPI
# spec same-origin. Both are provisioned here (not committed — see .gitignore) so a fresh
# checkout deploys cleanly. The spec's single source of truth is ../../Api/openapi.yaml;
# swagger-ui-dist is pinned and fetched once, then reused.
$SwaggerVersion = '5.32.8'
$suiDir = Join-Path $webDir 'vendor/swagger-ui'
if (-not (Test-Path (Join-Path $suiDir 'swagger-ui-bundle.js'))) {
    Write-Host "Vendoring swagger-ui-dist $SwaggerVersion (self-hosted, no CDN)…"
    New-Item -ItemType Directory -Force -Path $suiDir | Out-Null
    $tgz = Join-Path ([IO.Path]::GetTempPath()) "swagger-ui-dist-$SwaggerVersion.tgz"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "swui-$SwaggerVersion"
    Invoke-WebRequest -Uri "https://registry.npmjs.org/swagger-ui-dist/-/swagger-ui-dist-$SwaggerVersion.tgz" -OutFile $tgz
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    tar -xzf $tgz -C $tmp
    if ($LASTEXITCODE -ne 0) { throw "tar failed extracting swagger-ui-dist." }
    Copy-Item (Join-Path $tmp 'package/swagger-ui.css') $suiDir -Force
    Copy-Item (Join-Path $tmp 'package/swagger-ui-bundle.js') $suiDir -Force
}
$specSrc = Join-Path $PSScriptRoot '../../Api/openapi.yaml'
if (Test-Path $specSrc) {
    Copy-Item $specSrc (Join-Path $webDir 'openapi.yaml') -Force
} else {
    Write-Warning "API spec not found at $specSrc — the API tab will 404 loading openapi.yaml."
}

# --- Deploy (rsync over ssh) ---------------------------------------------
# Trailing slash on source => copy the CONTENTS of web/, not the dir itself.
$sshParts = @("ssh -p $SshPort")
if ($SshKey) { $sshParts += "-i `"$SshKey`"" }
$sshCmd = $sshParts -join ' '

$remote = "{0}@{1}:{2}" -f $SshUser, $Server, $RemotePath
$rsyncArgs = @(
    '-az', '--delete', '--itemize-changes',
    '-e', $sshCmd,
    ("{0}/" -f $webDir),
    $remote
)
if (-not $Push) { $rsyncArgs = @('--dry-run') + $rsyncArgs }

if ($Push) {
    Write-Host "== Deploying to $remote ==" -ForegroundColor Green
} else {
    Write-Host "== DRY RUN — no changes will be made (use -Push to deploy) ==" -ForegroundColor Yellow
    Write-Host "   Target: $remote"
}

$output = Get-Stdout { rsync @rsyncArgs }
$output | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { throw "rsync failed (exit $LASTEXITCODE)." }

$changedCount = ($output | Where-Object { $_ -match '^[<>ch]' }).Count
Write-Host ""
if ($Push) {
    Write-Host "Deployed. $changedCount item(s) changed on the server." -ForegroundColor Green
    Write-Host "Viewer: https://$(if ($cfg) { $cfg.Hostnames[0] } else { 'configs.<domain>' })" -ForegroundColor Green
} else {
    Write-Host "$changedCount item(s) would change. Re-run with -Push to deploy." -ForegroundColor Yellow
}

# --- CSV log -------------------------------------------------------------
if (-not $NoLog) {
    $logDir = Join-Path $SiteRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir 'deploy.csv') -Row ([PSCustomObject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        mode      = if ($Push) { 'push' } else { 'dryrun' }
        server    = $Server
        remote    = $RemotePath
        changed   = $changedCount
    })
}
