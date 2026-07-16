#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pull the LIVE config-overrides.json off the box into the repo — the deploy's
    pull-before-push step so an admin who sets overrides at runtime (ConfigViewer, later)
    is never clobbered by a dev deploy.
.DESCRIPTION
    Roles are INVERTED from most of the deploy: the LIVE box is authoritative for
    config-overrides.json. This pulls that copy DOWN so the repo mirrors it before the
    deploy re-ships it. Modelled on Sync-VPPCoordinates.ps1 (same box-authoritative +
    default-fallback shape).

    Read-only by default (shows what pulling WOULD change). -Execute writes:
      config-overrides.json           the working copy the deploy ships (= the box's live one)
      backups/config-overrides/*.json timestamped snapshot of the PREVIOUS repo copy (keep 10)

    SYNTAX VALIDATOR: a pulled file that is not valid JSON is REJECTED (treated as no usable
    data) — a corrupt overrides file never enters the repo or the ship.

    FALLBACK: if the box has no config-overrides.json (fresh box) or it is empty/invalid, fall
    back to the committed config-overrides.fallback.json seed instead of clobbering the
    working copy or aborting the deploy. (NOT related to the <file>.defaults.<ext> frozen
    baselines under config-defaults/ — this is a disaster-recovery seed for the overrides
    DOCUMENT itself; renamed from config-overrides.default.json to kill that ambiguity.)

    -SetFallback (alias -SetDefault; ad-hoc, OUTSIDE the deploy): re-seed the fallback from
    the CURRENT repo config-overrides.json — the fresh-box seed. Needs -Execute.

    TRANSITION NOTE: the box only holds admin edits once the write path (later phase) exists.
    Until then the box copy is just the last-deployed one, so a pull is a no-op or a fallback.
    Every overwrite is snapshotted to backups/, so nothing is ever lost.
.EXAMPLE
    ./Sync-ConfigOverrides.ps1                     # dry-run: what pulling the box would change
.EXAMPLE
    ./Sync-ConfigOverrides.ps1 -Execute            # pull the box's live overrides into the repo
.EXAMPLE
    ./Sync-ConfigOverrides.ps1 -SetFallback -Execute # re-seed the fallback from the current repo copy
#>
[CmdletBinding()]
param(
    [string]$RemoteHost,
    [string]$RemoteUser = "ubuntu",
    [string]$RemotePath = "/home/ubuntu/servers/dayz-server",
    [string]$OverridesRel = "config-overrides.json",              # under the server root
    [string]$LocalPath   = (Join-Path $PSScriptRoot "config-overrides.json"),
    [string]$FallbackPath = (Join-Path $PSScriptRoot "config-overrides.fallback.json"),
    [string]$BackupDir   = (Join-Path $PSScriptRoot "backups/config-overrides"),
    [int]$KeepVersions   = 10,
    [switch]$Execute,
    [Alias('SetDefault')][switch]$SetFallback,
    [switch]$NoLog
)

. (Join-Path $PSScriptRoot "_DZSync.ps1")
. (Join-Path $PSScriptRoot "../../common/Utils.ps1")

Resolve-DZDeployerEnv -ScriptRoot $PSScriptRoot -RemoteHost ([ref]$RemoteHost) -RemoteUser ([ref]$RemoteUser) -BoundParameters $PSBoundParameters
Assert-DZHost @{ RemoteHost = $RemoteHost; RemoteUser = $RemoteUser; RemotePath = $RemotePath }

$target = "${RemoteUser}@${RemoteHost}"

# The syntax validator: does this text parse as JSON?
function Test-JsonText([string]$text) {
    if (-not $text -or -not $text.Trim()) { return $false }
    try { $null = $text | ConvertFrom-Json; return $true } catch { return $false }
}

# Snapshot the current LocalPath into BackupDir and prune to KeepVersions (the rollback source).
function Backup-Local {
    if (-not (Test-Path $LocalPath)) { return }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item -LiteralPath $LocalPath -Destination (Join-Path $BackupDir "config-overrides.$stamp.json") -Force
    Get-ChildItem $BackupDir -Filter "config-overrides.*.json" | Sort-Object Name -Descending |
        Select-Object -Skip $KeepVersions | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "  snapshot -> $BackupDir/config-overrides.$stamp.json (keep $KeepVersions)"
}

# --- -SetFallback: re-seed the fallback seed from the current repo copy (no box fetch) ----
if ($SetFallback) {
    if (-not (Test-Path $LocalPath)) { Write-Error "-SetFallback: no $LocalPath to bless."; exit 2 }
    $cur = Get-Content -Raw -LiteralPath $LocalPath
    if (-not (Test-JsonText $cur)) { Write-Error "-SetFallback: $LocalPath is not valid JSON — refusing to bless a broken seed."; exit 1 }
    if ($Execute) {
        $cur.TrimEnd() | Set-Content -LiteralPath $FallbackPath -Encoding utf8
        Write-Host "Set the fallback seed from the current repo copy: $FallbackPath"
    } else {
        Write-Host "Dry-run (-SetFallback) — would bless $LocalPath -> $FallbackPath. Re-run with -Execute."
    }
    exit 0
}

# --- Fetch the box's live config-overrides.json (read-only) -------------------------------
$remoteFile = "$RemotePath/$OverridesRel"
Write-Host "Fetching config-overrides from ${target}:$remoteFile"
$raw = Get-Stdout { ssh -o ConnectTimeout=10 $target "cat '$remoteFile'" } | Out-String

$pullOk = $true
if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) {
    Write-Warning "Could not read $remoteFile on $target (ssh exit $LASTEXITCODE) — no live overrides this run."
    $pullOk = $false
} elseif (-not (Test-JsonText $raw)) {
    Write-Warning "Box config-overrides.json is NOT valid JSON — REJECTED (won't pull a corrupt file). Falling back to the fallback seed."
    $pullOk = $false
}

$curTrim = if (Test-Path $LocalPath) { (Get-Content -Raw -LiteralPath $LocalPath).TrimEnd() } else { $null }

if ($pullOk) {
    # Usable live overrides -> mirror them into the repo (the deploy then re-ships them).
    $boxTrim = $raw.TrimEnd()
    if ($boxTrim -eq $curTrim) {
        Write-Host "Box overrides identical to the repo copy — nothing to pull."
    } elseif ($Execute) {
        Backup-Local
        $boxTrim | Set-Content -LiteralPath $LocalPath -Encoding utf8
        Write-Host "Pulled the box's live config-overrides.json into the repo (admin edits preserved)."
    } else {
        Write-Host "Dry-run — the box's overrides DIFFER from the repo copy; -Execute would pull them in (snapshotting the current one first)."
    }
} else {
    # No usable box overrides -> seed from the fallback rather than ship an empty/corrupt file.
    if (Test-Path $FallbackPath) {
        $defTrim = (Get-Content -Raw -LiteralPath $FallbackPath).TrimEnd()
        if ($defTrim -eq $curTrim) {
            Write-Host "No usable box overrides — repo copy already equals the fallback; left as-is."
        } elseif ($Execute) {
            Backup-Local
            $defTrim | Set-Content -LiteralPath $LocalPath -Encoding utf8
            Write-Warning "No usable box overrides — fell back to the seed (config-overrides.fallback.json)."
        } else {
            Write-Host "Dry-run — no usable box overrides; -Execute would fall back to config-overrides.fallback.json."
        }
    } else {
        Write-Warning "No usable box overrides AND no config-overrides.fallback.json. Left $LocalPath as-is. Seed one with: ./Sync-ConfigOverrides.ps1 -SetFallback -Execute"
    }
}

if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir "configoverrides.csv") -Row ([PSCustomObject]@{
        Timestamp  = Get-Date -Format "s"
        Source     = "${target}:$remoteFile"
        DryRun     = (-not $Execute)
        PullOk     = $pullOk
        SetFallback = [bool]$SetFallback
    })
}
