#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pulls the server (main) down to this local (dev) machine over rsync/ssh — refreshes dev from prod.
.DESCRIPTION
    Roles: the SERVER is the main copy (authoritative on live saves); this LOCAL
    machine is the dev branch. A pull brings the server's state DOWN so you can work
    against real data. Unlike push, saves are INCLUDED by default — grabbing the
    live world/players is the whole point. This OVERWRITES local (the dev copy),
    which is expected.

    Read-only by default: a bare run is a --dry-run. Add -Execute to transfer.
      (default)        pull saves + config down; the DayZ app + @mods excluded (rebuildable)
      -Execute         do the pull for real (overwrites local)
      -Execute -Force  also pull the DayZ app + @mods + binaries (rarely needed)

    --delete makes local mirror the server within the pulled set, overwriting the local
    working copy — that's the point (the box is authoritative on live state).

    NOT the repo's config backup. Config content lives on the box (web editor) and is
    mirrored into the REPO — with committed history — by Pull-Configs.ps1. THIS tool is
    the off-box FULL working mirror: the whole server tree including saves/persistence the
    repo never carries. It's the disaster-recovery grab for player/world state that
    docs/RECOVERY.md points at, not a config sync.
.EXAMPLE
    ./Pull-DayZServer.ps1                 # dry-run: what would come down
.EXAMPLE
    ./Pull-DayZServer.ps1 -Execute        # pull saves + config to local
.EXAMPLE
    ./Pull-DayZServer.ps1 -Execute -Force # full mirror down, incl. app + @mods
#>
[CmdletBinding()]
param(
    [string]$RemoteHost,                                        # dev-machine-local — see deployer.env, or -RemoteHost
    [string]$RemoteUser = "ubuntu",                             # override via deployer.env's DEPLOY_REMOTE_USER if it differs
    [string]$RemotePath = "/home/ubuntu/servers/dayz-server",  # absolute path to dayz-server on the server
    [string]$LocalPath  = "/home/meshy/servers/dayz-server",
    [switch]$Execute,                # actually transfer (default is a dry-run)
    [switch]$Force,                  # also pull the DayZ app + @mods + binaries
    [switch]$NoLog
)

. (Join-Path $PSScriptRoot "_DZSync.ps1")
. (Join-Path $PSScriptRoot "../../../common/Utils.ps1")

Resolve-DZDeployerEnv -ScriptRoot $PSScriptRoot -RemoteHost ([ref]$RemoteHost) -RemoteUser ([ref]$RemoteUser) -BoundParameters $PSBoundParameters
Assert-DZHost @{ RemoteHost = $RemoteHost; RemoteUser = $RemoteUser; RemotePath = $RemotePath }
if (-not (Test-Path $LocalPath)) { Write-Error "LocalPath not found: $LocalPath"; exit 2 }

$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp    = Get-Date -Format "yyyyMMdd_HHmmss"
$rsyncLog = Join-Path $logDir "pull_$stamp.log"

$excludes = $DZ_LOG_EXCLUDES
if (-not $Force) { $excludes += $DZ_HEAVY_EXCLUDES }   # saves INCLUDED; skip only the heavy rebuildables

$exit = Invoke-DZSync -Src "${RemoteUser}@${RemoteHost}:${RemotePath}/" -Dst "$LocalPath/" `
                      -Excludes $excludes -Execute:$Execute -LogFile $rsyncLog `
                      -Label ("PULL server -> local (Force={0})" -f [bool]$Force)

if (-not $NoLog) {
    Write-CsvLog -Path (Join-Path $logDir "pull.csv") -Row ([PSCustomObject]@{
        Timestamp   = Get-Date -Format "s"
        Direction   = "pull"
        Source      = "${RemoteUser}@${RemoteHost}:${RemotePath}"
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
    Write-Host "`nPull complete. Details: $rsyncLog"
}
