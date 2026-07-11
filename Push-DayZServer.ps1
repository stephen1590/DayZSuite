#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pushes local (dev) config up to the server (main) over rsync/ssh. Protects the server's live saves by default.
.DESCRIPTION
    Roles: the SERVER is the main copy (authoritative on live saves); this LOCAL
    machine is the dev branch (leads on config). So a push carries config/setup UP
    and, by default, does NOT touch the server's save state (mpmissions/*/storage_*)
    — you develop config here and deploy it up without clobbering player progress.

    Read-only by default: a bare run is a --dry-run. Add -Execute to transfer.
      (default)          push config/setup only; saves + heavy data excluded
      -Execute           do the config push for real
      -Execute -Force    push EVERYTHING (incl. saves + the DayZ app + @mods) — the
                         initial migration seed, or a deliberate save restore. This
                         OVERWRITES the server's live saves.

    --delete makes the server mirror local within the pushed set; excluded paths on
    the server are protected. The versioned deploy payload (Deploy-DayZServer.ps1 +
    deploy/, incl. the systemd unit) travels via git, not here.
.EXAMPLE
    ./Push-DayZServer.ps1                 # dry-run: what a config push would change
.EXAMPLE
    ./Push-DayZServer.ps1 -Execute        # deploy config up (server saves untouched)
.EXAMPLE
    ./Push-DayZServer.ps1 -Execute -Force # full mirror up — seeds/overwrites saves too
#>
[CmdletBinding()]
param(
    [string]$RemoteHost = "servermander.ovh",                  # migration target (OVH Ubuntu VPS)
    [string]$RemoteUser = "ubuntu",
    [string]$RemotePath = "/home/ubuntu/servers/dayz-server",  # absolute path to dayz-server on the new host
    [string]$LocalPath  = "/home/meshy/servers/dayz-server",
    [switch]$Execute,                # actually transfer (default is a dry-run)
    [switch]$Force,                  # include saves + the DayZ app + @mods (overwrites server saves)
    [switch]$NoLog
)

. (Join-Path $PSScriptRoot "_DZSync.ps1")
. (Join-Path $PSScriptRoot "../../common/Utils.ps1")

Assert-DZHost @{ RemoteHost = $RemoteHost; RemoteUser = $RemoteUser; RemotePath = $RemotePath }
if (-not (Test-Path $LocalPath)) { Write-Error "LocalPath not found: $LocalPath"; exit 2 }

$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp    = Get-Date -Format "yyyyMMdd_HHmmss"
$rsyncLog = Join-Path $logDir "push_$stamp.log"

$excludes = $DZ_LOG_EXCLUDES
if (-not $Force) { $excludes += $DZ_SAVE_EXCLUDES + $DZ_HEAVY_EXCLUDES }  # protect saves, skip heavy

if ($Execute -and $Force) {
    Write-Warning "FORCE push: this OVERWRITES the server's live saves and pushes everything. Ctrl-C now if unsure."
}

$exit = Invoke-DZSync -Src "$LocalPath/" -Dst "${RemoteUser}@${RemoteHost}:${RemotePath}/" `
                      -Excludes $excludes -Execute:$Execute -LogFile $rsyncLog `
                      -Label ("PUSH local -> server (Force={0})" -f [bool]$Force)

if (-not $NoLog) {
    Write-CsvLog -Path (Join-Path $logDir "push.csv") -Row ([PSCustomObject]@{
        Timestamp   = Get-Date -Format "s"
        Direction   = "push"
        Destination = "${RemoteUser}@${RemoteHost}:${RemotePath}"
        DryRun      = (-not $Execute)
        Force       = [bool]$Force
        RsyncExit   = $exit
        LogFile     = $rsyncLog
    })
}

if ($exit -ne 0) { Write-Warning "rsync exit=$exit (see $rsyncLog)"; exit 1 }
if (-not $Execute) {
    Write-Host "`nDry-run only — nothing written. Review above, then re-run with -Execute."
} else {
    Write-Host "`nPush complete. Details: $rsyncLog"
}
