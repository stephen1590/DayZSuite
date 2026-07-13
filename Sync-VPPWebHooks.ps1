#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Checks (and pulls) VPP's WebHooks config off the live server. Read-only by default.
.DESCRIPTION
    VPPAdminTools' in-game "WebHooks" feature (MenuWebHooks:Create) writes whatever it
    saves into profiles/VPPAdminTools/ConfigurablePlugins/WebHooksManager/ on the box.
    There is no RCon/CLI query for this -- an empty directory there IS "no webhook has
    ever been registered in VPP." This script lists what's in it, which is the check.

    Once an admin creates a webhook in-game pointed at the API service
    (https://api.<domain>/sources/vpp/<VPP_TOKEN> -- retrieve VPP_TOKEN with
    `sudo cat /etc/api/secrets.env` on the box, see
    ../NginxService/Api/README.md), re-run this with -Execute to pull the real
    file(s) down into deploy/profiles/VPPAdminTools/WebHooks/ -- same pull-then-track
    pattern Sync-VPPCoordinates.ps1 uses for TeleportLocation.json.

    This script deliberately does NOT author or push a webhook config: the plugin has
    never written a file here, so its schema is unknown, and guessing risks shipping
    something the mod silently ignores or rejects at boot. Once a real file is pulled,
    wiring it into Deploy-DayZServer.ps1's $items list is a follow-up decision -- push
    it every deploy like UserGroups.json (we own it), or leave it admin-owned/pull-only
    like TeleportLocation.json (VPP owns it, we only audit) -- same question that file
    already answers.
.EXAMPLE
    ./Sync-VPPWebHooks.ps1              # check only: lists what's there (or isn't)
.EXAMPLE
    ./Sync-VPPWebHooks.ps1 -Execute     # pull whatever's there into deploy/profiles/VPPAdminTools/WebHooks/
#>
[CmdletBinding()]
param(
    [string]$RemoteHost,
    [string]$RemoteUser = "ubuntu",
    [string]$RemotePath = "/home/ubuntu/servers/dayz-server",
    [string]$WebHooksRel = "profiles/VPPAdminTools/ConfigurablePlugins/WebHooksManager",
    [string]$OutDir = (Join-Path $PSScriptRoot "deploy/profiles/VPPAdminTools/WebHooks"),
    [switch]$Execute,   # actually write the files (default is a dry-run / check-only)
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "_DZSync.ps1")
. (Join-Path $PSScriptRoot "../../common/Utils.ps1")

Resolve-DZDeployerEnv -ScriptRoot $PSScriptRoot -RemoteHost ([ref]$RemoteHost) -RemoteUser ([ref]$RemoteUser) -BoundParameters $PSBoundParameters
Assert-DZHost @{ RemoteHost = $RemoteHost; RemoteUser = $RemoteUser; RemotePath = $RemotePath }

$target    = "${RemoteUser}@${RemoteHost}"
$remoteDir = "$RemotePath/$WebHooksRel"

Write-Host "Checking ${target}:$remoteDir"
$listing = Get-Stdout { ssh -o ConnectTimeout=10 $target "find '$remoteDir' -maxdepth 1 -type f 2>/dev/null" } | Out-String
$files = @($listing -split "`n" | Where-Object { $_.Trim() })

if (-not $files.Count) {
    Write-Host "`nNo files under $WebHooksRel -- no webhook has been registered in VPP yet." -ForegroundColor Yellow
    Write-Host "Create one via the in-game admin menu (needs MenuWebHooks:Create -- the Admins group already"
    Write-Host "has it, see deploy/profiles/VPPAdminTools/Permissions/UserGroups/UserGroups.json), pointed at:"
    Write-Host "  https://api.<domain>/sources/vpp/<VPP_TOKEN>"
    Write-Host "(VPP_TOKEN: sudo cat /etc/api/secrets.env on the box -- see ../NginxService/Api/README.md)"
    Write-Host "Then re-run this script -- add -Execute once you want it captured into the deploy payload."
} else {
    Write-Host "`nFound $($files.Count) file(s):"
    $files | ForEach-Object { Write-Host "  $_" }

    if ($Execute) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        foreach ($f in $files) {
            $name = Split-Path -Leaf $f
            $dest = Join-Path $OutDir $name
            $raw  = Get-Stdout { ssh -o ConnectTimeout=10 $target "cat '$f'" } | Out-String
            if (Test-Path $dest) {
                # Timestamped backup subdirectory, never a same-dir '.bak'/'fixed_' sibling.
                $backupDir = Join-Path $OutDir "backups"
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                $bstamp = Get-Date -Format "yyyyMMdd_HHmmss"
                Copy-Item -LiteralPath $dest -Destination (Join-Path $backupDir "$name.$bstamp") -Force
            }
            $raw.TrimEnd() | Set-Content -LiteralPath $dest -Encoding utf8
            Write-Host "  Pulled -> $dest"
        }
        Write-Host "`nPulled into $OutDir. Capture-only -- NOT yet wired into Deploy-DayZServer.ps1's deploy" -ForegroundColor Green
        Write-Host "list. Review the file(s) and decide push-every-deploy vs. admin-owned/pull-only, same as" -ForegroundColor Green
        Write-Host "the TeleportLocation.json / vpp-coordinates.json split above it does." -ForegroundColor Green
    } else {
        Write-Host "`nDry-run -- nothing written. Re-run with -Execute to pull into $OutDir."
    }
}

if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir "vppwebhooks.csv") -Row ([PSCustomObject]@{
        Timestamp = Get-Date -Format "s"
        Source    = "${target}:$remoteDir"
        DryRun    = (-not $Execute)
        Files     = $files.Count
    })
}
