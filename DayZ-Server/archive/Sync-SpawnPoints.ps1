#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pull the LIVE map-points.json off the box into the repo mirror — the backup path for
    the box-owned spawn store (ConfigViewer Map editor -> configs/set-spawns).
.DESCRIPTION
    The LIVE box is authoritative for map-points.json (the definitive AI-bandit spawn
    store, written whole via the API's spawn-write verb and snapshotted there). This pulls
    that copy DOWN into the repo MIRROR — a committed backup, and the seed a fresh box gets
    (the deploy only ever seeds it to a box that has none; it never overwrites a live copy).
    Same box-authoritative shape as Sync-ConfigOverrides.ps1.

    Read-only by default (shows what pulling WOULD change). -Execute writes:
      deploy/profiles/AI_Shared/map-points.json      the working copy the deploy ships (= the box's)
      backups/map-points/*.json                       timestamped snapshot of the PREVIOUS repo copy

    VALIDATOR: a pulled file that is not valid JSON, or that lacks a `points` array, is REJECTED —
    a corrupt/foreign file never enters the repo or the ship.

    NO usable box copy (fresh box, empty, or invalid): the repo working copy is LEFT UNTOUCHED and
    ships as-is. There is no separate fallback seed because the repo copy already IS the seed — it
    was migrated from the last VPP snapshot (Migrate-SpawnPoints.ps1, deleted 2026-07-16 — git history) and is authoritative until
    the box has real edits to mirror back. Every overwrite is snapshotted to backups/, so nothing
    is ever lost.

    TRANSITION NOTE: until an admin edits spawns on the box (via the web editor), the box copy is
    just the last-deployed one, so a pull is a no-op. Deprecates the old VPP pull path
    (deleted 2026-07-16 — recover from git history if ever needed).
.EXAMPLE
    ./Sync-SpawnPoints.ps1                     # dry-run: what pulling the box would change
.EXAMPLE
    ./Sync-SpawnPoints.ps1 -Execute            # pull the box's live map-points.json into the repo
#>
[CmdletBinding()]
param(
    [string]$RemoteHost,
    [string]$RemoteUser = "ubuntu",
    [string]$RemotePath = "/home/ubuntu/servers/dayz-server",
    [string]$SpawnRel   = "profiles/AI_Shared/map-points.json",                # shared spawn store (feeds AIB + Expansion), neutral location
    [string]$LocalPath  = (Join-Path $PSScriptRoot "deploy/profiles/AI_Shared/map-points.json"),
    [string]$BackupDir  = (Join-Path $PSScriptRoot "backups/map-points"),
    [int]$KeepVersions  = 20,
    [switch]$Execute,
    [switch]$NoLog
)

. (Join-Path $PSScriptRoot "_DZSync.ps1")
. (Join-Path $PSScriptRoot "../../../common/Utils.ps1")

Resolve-DZDeployerEnv -ScriptRoot $PSScriptRoot -RemoteHost ([ref]$RemoteHost) -RemoteUser ([ref]$RemoteUser) -BoundParameters $PSBoundParameters
Assert-DZHost @{ RemoteHost = $RemoteHost; RemoteUser = $RemoteUser; RemotePath = $RemotePath }

$target = "${RemoteUser}@${RemoteHost}"

# The validator: valid JSON AND shaped like a spawn document (has a points array).
function Test-SpawnText([string]$text) {
    if (-not $text -or -not $text.Trim()) { return $false }
    try { $doc = $text | ConvertFrom-Json } catch { return $false }
    return ($null -ne $doc) -and ($null -ne $doc.PSObject.Properties['points'])
}

# Snapshot the current LocalPath into BackupDir and prune to KeepVersions (the rollback source).
function Backup-Local {
    if (-not (Test-Path $LocalPath)) { return }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item -LiteralPath $LocalPath -Destination (Join-Path $BackupDir "map-points.$stamp.json") -Force
    Get-ChildItem $BackupDir -Filter "map-points.*.json" | Sort-Object Name -Descending |
        Select-Object -Skip $KeepVersions | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "  snapshot -> $BackupDir/map-points.$stamp.json (keep $KeepVersions)"
}

# --- Fetch the box's live map-points store (read-only) ------------------------------------
$remoteFile = "$RemotePath/$SpawnRel"
Write-Host "Fetching map-points from ${target}:$remoteFile"
$raw = Get-Stdout { ssh -o ConnectTimeout=10 $target "cat '$remoteFile'" } | Out-String

$pullOk = $true
if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) {
    Write-Warning "Could not read $remoteFile on $target (ssh exit $LASTEXITCODE) — no live spawns this run; keeping the repo copy."
    $pullOk = $false
} elseif (-not (Test-SpawnText $raw)) {
    Write-Warning "Box map-points.json is not valid JSON with a 'points' array — REJECTED; keeping the repo copy."
    $pullOk = $false
}

$curTrim = if (Test-Path $LocalPath) { (Get-Content -Raw -LiteralPath $LocalPath).TrimEnd() } else { $null }

if ($pullOk) {
    $boxTrim = $raw.TrimEnd()
    if ($boxTrim -eq $curTrim) {
        Write-Host "Box spawn-points identical to the repo copy — nothing to pull."
    } elseif ($Execute) {
        Backup-Local
        $boxTrim | Set-Content -LiteralPath $LocalPath -Encoding utf8
        Write-Host "Pulled the box's live map-points.json into the repo (admin/web edits preserved)."
    } else {
        Write-Host "Dry-run — the box's spawn-points DIFFER from the repo copy; -Execute would pull them in (snapshotting the current one first)."
    }
} else {
    # No usable box copy — the repo working copy IS the seed; leave it as-is and let the deploy ship it.
    Write-Host "No usable box spawn-points — leaving the repo copy as the authoritative seed."
}

if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir "spawnpoints.csv") -Row ([PSCustomObject]@{
        Timestamp = Get-Date -Format "s"
        Source    = "${target}:$remoteFile"
        DryRun    = (-not $Execute)
        PullOk    = $pullOk
    })
}

# Explicit success: without this, $LASTEXITCODE from the last inner ssh/native call leaks
# to callers that check it (Pull-Configs, Deploy).
exit 0
