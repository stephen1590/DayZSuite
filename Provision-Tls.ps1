#requires -Version 7
<#
.SYNOPSIS
  Shared, service-agnostic provisioner: nginx + Let's Encrypt TLS (HTTP-01) for
  ONE service on the box. Every service (StaticishSite, CryptPad, ...) runs THIS
  script; the differences live entirely in that service's deploy/deploy.config.json
  and its nginx templates. No service names are hard-coded here.

.DESCRIPTION
  Flow: render -> stage -> ship -> run.

    1. RENDER  the service's nginx templates + provision.env from its
               deploy.config.json (plus ./templates/nginx-bootstrap.conf.template)
    2. STAGE   the bundle into <Service>/deploy/stage/tls/ — real files you
               can review/diff
    3. SHIP    (-Apply) rsync the stage to ~/.deploy/<SiteName>/tls/ on the box
    4. RUN     (-Apply) ssh: bash provision-tls.sh there (a STATIC script —
               see ./remote/provision-tls.sh; values come from provision.env)

  Report-only by default: builds the stage and stops. Nothing on the server
  changes without -Apply. Idempotency (skip issuance if cert exists, etc.)
  lives in remote/provision-tls.sh — read it there.

  Host-level setup (nginx + certbot, /var/www/acme, dropping the distro default)
  happens idempotently on every run, so whichever service you deploy FIRST sets
  up the box — no service depends on another having run. Each service gets its
  own cert and its own sites-available/<SiteName>; provisioning one never touches
  another's files.

  The config is deploy.config.json, merged over host.config.env by
  Load-DeployConfig.ps1 (which also resolves ${Key} references), giving:
    Server, SshUser, AdminEmail   - from the shared host.config.env
    SshPort (opt), SshKey (opt)
    SiteName                      - nginx sites-available/<name>
    Hostnames                     - string[]; server_name + one -d per name (SAN)
    NginxTemplate                 - path (rel. to deploy/) of the 443 vhost template
    NginxHttpOnlyTemplate (opt)   - plain-HTTP fallback template (for -SkipTls)
    Webroot (opt)                 - static webroot; if set, remote script mkdir+chown
                                    it to SshUser; injected as __WEBROOT__
    TemplateVars (opt)            - hashtable of extra __TOKEN__ => value

  Templates are rendered by replacing tokens. The engine always injects:
    __HOSTNAME__ (Hostnames[0]), __SERVER_NAMES__ (all, space-joined),
    __CERT_NAME__ (Hostnames[0]), __ACME_WEBROOT__, and __WEBROOT__ if Webroot set.

.EXAMPLE
  ./Provision-Tls.ps1 -Service StaticishSite            # dry run: stage only
  ./Provision-Tls.ps1 -Service StaticishSite -Apply     # ship + provision
  ./Provision-Tls.ps1 -Service CryptPad -Apply -SkipTls # plain HTTP before DNS

.NOTES
  Sets up the server ONCE per service. App/content deploys happen separately.
  Never hand-edit the deployed nginx config — change the template and re-run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Service, # e.g. StaticishSite | CryptPad
    [switch]$Apply,
    [ValidateSet('staging','prod')]
    [string]$Env = 'staging',   # which box: staging default, prod explicit (STAGING-PLAN.md) - picks host.config.<env>.env
    [switch]$SkipTls,       # plain HTTP only — use before DNS points here; REQUIRED on staging
    [string]$ConfigPath,    # override; default <Service>/deploy/deploy.config.json (sibling of this script)
    [switch]$NoLog
)

# Staging is http-only by design (STAGING-PLAN.md deviation table: no public DNS, no
# HTTP-01). The bootstrap path (-SkipTls) is exactly the staging vhost; certbot never
# runs there.
if ($Env -eq 'staging' -and -not $SkipTls) {
    Write-Error "staging is http-only: re-run with -SkipTls (TLS/certbot is prod-only - see STAGING-PLAN.md deviation table)."
    exit 2
}

$ErrorActionPreference = 'Stop'
# Shared code utils live at Dev/common (one level ABOVE UbuntuHost). This engine
# lives at UbuntuHost/NginxService; ../../common resolves to Dev/common.
. (Join-Path $PSScriptRoot '../../common/Utils.ps1')
# Deploy-config loader: host.config.env + <service>/deploy.config.json, merged.
. (Join-Path $PSScriptRoot 'Load-DeployConfig.ps1')

# --- Resolve + load the service's deploy config ---------------------------
# -ConfigPath (optional) points at a deploy.config.json to override the default
# of <Service>/deploy/deploy.config.json (a sibling of this script).
if ($ConfigPath) {
    if (-not (Test-Path $ConfigPath)) { throw "No deploy config at: $ConfigPath." }
    $serviceDeployDir = Split-Path -Parent (Resolve-Path $ConfigPath).Path
} else {
    $serviceDeployDir = Join-Path $PSScriptRoot "$Service/deploy"
}
if (-not (Test-Path (Join-Path $serviceDeployDir 'deploy.config.json'))) {
    throw "No deploy config for '$Service' at $serviceDeployDir/deploy.config.json (copy deploy.config.example.json, or pass -ConfigPath)."
}
$cfg = Import-DeployConfig -ServiceDeployDir $serviceDeployDir -Env $Env

foreach ($key in @('Server','SshUser','AdminEmail','SiteName','NginxTemplate')) {
    if (-not $cfg[$key]) { throw "Service '$Service' config is missing '$key'." }
}
$Hostnames = @($cfg.Hostnames)
if ($Hostnames.Count -lt 1) { throw "Service '$Service' config needs at least one entry in Hostnames." }
if ($SkipTls -and -not $cfg.NginxHttpOnlyTemplate) { throw "Service '$Service' has no NginxHttpOnlyTemplate; cannot use -SkipTls." }
foreach ($tool in 'rsync', 'ssh') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' not found on PATH." }
}

$SshPort     = if ($cfg.SshPort) { [int]$cfg.SshPort } else { 22 }
$acmeWebroot = '/var/www/acme'
$certName    = $Hostnames[0]
$serverNames = ($Hostnames -join ' ')

# --- RENDER + STAGE --------------------------------------------------------
$vars = @{
    '__HOSTNAME__'     = $Hostnames[0]
    '__SERVER_NAMES__' = $serverNames
    '__CERT_NAME__'    = $certName
    '__ACME_WEBROOT__' = $acmeWebroot
    '__SITE_NAME__'    = $cfg.SiteName
    '__ADMIN_EMAIL__'  = $cfg.AdminEmail
    '__SSH_USER__'     = $cfg.SshUser
    '__WEBROOT__'      = "$($cfg.Webroot)"                  # empty string if unset
    '__SKIP_TLS__'     = $(if ($SkipTls) { '1' } else { '0' })
}
if ($cfg.TemplateVars) { foreach ($k in $cfg.TemplateVars.Keys) { $vars[$k] = $cfg.TemplateVars[$k] } }

function Expand-Template([string]$BaseDir, [string]$RelPath) {
    $p = Join-Path $BaseDir $RelPath
    if (-not (Test-Path $p)) { throw "Template not found: $p" }
    $text = Get-Content -Raw $p
    foreach ($k in $vars.Keys) { $text = $text.Replace($k, [string]$vars[$k]) }
    return $text
}

$stageDir = Join-Path $serviceDeployDir 'stage/tls'
if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }   # generated output, rebuilt every run
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

Set-Content -NoNewline -Path (Join-Path $stageDir 'provision.env') -Value (
    Expand-Template $PSScriptRoot 'templates/provision.env.template')

if ($SkipTls) {
    Set-Content -NoNewline -Path (Join-Path $stageDir 'nginx-http-only.conf') -Value (
        Expand-Template $serviceDeployDir $cfg.NginxHttpOnlyTemplate)
} else {
    Set-Content -NoNewline -Path (Join-Path $stageDir 'nginx-bootstrap.conf') -Value (
        Expand-Template $PSScriptRoot 'templates/nginx-bootstrap.conf.template')
    Set-Content -NoNewline -Path (Join-Path $stageDir 'nginx-site.conf') -Value (
        Expand-Template $serviceDeployDir $cfg.NginxTemplate)
}

Copy-Item (Join-Path $PSScriptRoot 'remote/provision-tls.sh') (Join-Path $stageDir 'provision-tls.sh')

# --- Report ----------------------------------------------------------------
$target = "$($cfg.SshUser)@$($cfg.Server)"
Write-Host "Service: $Service   Target: $target (port $SshPort)" -ForegroundColor Cyan
Write-Host "Host(s): $serverNames"
if ($cfg.Webroot) { Write-Host "Webroot: $($cfg.Webroot)   ACME: $acmeWebroot" } else { Write-Host "ACME   : $acmeWebroot" }
Write-Host "Staged : $stageDir" -ForegroundColor Cyan
Get-ChildItem $stageDir | ForEach-Object { Write-Host ("         {0,-24} {1,8:n0} B" -f $_.Name, $_.Length) }

# --- SHIP + RUN (or stop after staging) --------------------------------------
$remoteStage = ".deploy/$($cfg.SiteName)/tls"   # relative to the SSH user's home
$sshArgs = @('-p', "$SshPort"); if ($cfg.SshKey) { $sshArgs += @('-i', $cfg.SshKey) }
$logDir = Join-Path (Split-Path -Parent $serviceDeployDir) 'logs'

if (-not $Apply) {
    Write-Host "== DRY RUN — stage built, nothing shipped (review the files above, then -Apply) ==" -ForegroundColor Yellow
} else {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $runLog = Join-Path $logDir "provision_$((Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss'))Z.log"
    Write-Host "== Shipping stage/tls -> ${target}:$remoteStage ==" -ForegroundColor Green

    & ssh @sshArgs $target "mkdir -p '$remoteStage'"
    if ($LASTEXITCODE -ne 0) { throw "ssh mkdir failed (exit $LASTEXITCODE)." }

    $sshCmd = (@('ssh') + $sshArgs) -join ' '
    & rsync -az --delete -e $sshCmd "$stageDir/" "${target}:$remoteStage/"
    if ($LASTEXITCODE -ne 0) { throw "rsync failed (exit $LASTEXITCODE)." }

    Write-Host "== Running provision-tls.sh on the server (full output -> $runLog) ==" -ForegroundColor Green
    & ssh @sshArgs $target "bash '$remoteStage/provision-tls.sh'" 2>&1 | Tee-Object -FilePath $runLog
    if ($LASTEXITCODE -ne 0) { throw "Remote provisioning failed (exit $LASTEXITCODE). See $runLog" }

    Write-Host ""
    if ($SkipTls) {
        Write-Host "Done. http://$($cfg.Server) should now answer (plain HTTP, no cert)." -ForegroundColor Green
        Write-Host "Once DNS points $serverNames at this server, re-run WITHOUT -SkipTls to add HTTPS." -ForegroundColor Yellow
    } else {
        Write-Host "Done. https://$certName should now serve with a signed cert." -ForegroundColor Green
    }
}

# --- CSV log -------------------------------------------------------------
if (-not $NoLog) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir 'provision.csv') -Row ([PSCustomObject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        mode      = if ($Apply) { 'apply' } else { 'dryrun' }
        service   = $Service
        server    = $cfg.Server
        hostnames = $serverNames
    })
}
