#requires -Version 7
<#
.SYNOPSIS
  Build the Personal Projects site and deploy it to the Ubuntu server over SSH.

.DESCRIPTION
  Read-only by default: builds the site locally and shows an rsync DRY-RUN of
  what would change on the server. Nothing is written to the server until you
  pass -Push.

  Server details come from deploy/deploy.config.json (gitignored) merged over
  the shared host.config.env. Copy deploy.config.example.json to
  deploy.config.json and fill it in, or pass the parameters directly.

.EXAMPLE
  ./Deploy-Site.ps1
      Build + dry-run. Shows what would change on the server. No changes made.

.EXAMPLE
  ./Deploy-Site.ps1 -Push
      Build + actually sync to the server.

.NOTES
  Never hand-edit the live server. Change the site or this script and redeploy.
#>
[CmdletBinding()]
param(
    [switch]$Push,                       # actually deploy (default: dry-run only)
    [ValidateSet('staging','prod')]
    [string]$Env = 'staging',            # which box: staging default, prod explicit (../../STAGING-PLAN.md) - picks host.config.<env>.env
    [string]$Server,                     # e.g. myhost.example.com
    [string]$SshUser,                    # e.g. deploy
    [string]$RemotePath,                 # e.g. /var/www/personal-projects
    [int]$SshPort = 0,                   # 0/unset = emit no -p, so ~/.ssh/config decides (an explicit -p overrides a Host alias's Port)
    [string]$SshKey,                     # path to private key (optional)
    [switch]$SkipBuild,                  # deploy the existing ./public as-is
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
$SiteRoot = Split-Path -Parent $PSScriptRoot          # StaticishSite/
. (Join-Path $PSScriptRoot '../../../../common/Utils.ps1')
# Deploy-config loader lives at the NginxService root (../.. from this deploy/).
. (Join-Path $PSScriptRoot '../../Load-DeployConfig.ps1')

# --- Load config file (params override it) -------------------------------
# host.config.env + deploy.config.json, merged. Params still win when passed.
$configJson = Join-Path $PSScriptRoot 'deploy.config.json'
if (Test-Path $configJson) {
    $cfg = Import-DeployConfig -ServiceDeployDir $PSScriptRoot -Env $Env
    if (-not $Server)     { $Server     = $cfg.Server }
    if (-not $SshUser)    { $SshUser    = $cfg.SshUser }
    if (-not $RemotePath) { $RemotePath = $cfg.RemotePath }
    if (-not $SshKey -and $cfg.SshKey) { $SshKey = $cfg.SshKey }
    if ($cfg.SshPort -and -not $SshPort) { $SshPort = [int]$cfg.SshPort }
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

# --- Build ---------------------------------------------------------------
$publicDir = Join-Path $SiteRoot 'public'
if (-not $SkipBuild) {
    Write-Host "== Building site ==" -ForegroundColor Cyan
    & (Join-Path $SiteRoot 'build.sh') --build
    if ($LASTEXITCODE -ne 0) { throw "build.sh failed (exit $LASTEXITCODE)." }
}
if (-not (Test-Path $publicDir)) { throw "No build output at $publicDir. Run without -SkipBuild." }

# --- Deploy (rsync over ssh) ---------------------------------------------
# Trailing slash on source => copy contents of public/, not the dir itself.
$sshParts = @('ssh')
if ($SshPort) { $sshParts += "-p $SshPort" }
if ($SshKey) { $sshParts += "-i `"$SshKey`"" }
$sshCmd = $sshParts -join ' '

$remote = "{0}@{1}:{2}" -f $SshUser, $Server, $RemotePath
$rsyncArgs = @(
    '-az', '--delete', '--itemize-changes',
    '-e', $sshCmd,
    ("{0}/" -f $publicDir),
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
