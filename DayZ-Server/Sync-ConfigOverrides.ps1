#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pull the LIVE config-overrides.json off the box into the repo mirror — the deploy's
    pull step, and the backup path for the box-owned overrides document.
.DESCRIPTION
    The LIVE box is authoritative for config-overrides.json — the web editor
    (ConfigViewer -> API -> dayz-ctl override-write) writes it at runtime, and the box
    snapshots every write (.overrides-versions/, keep 10). The repo working copy is a
    MIRROR: a committed, versioned backup this script maintains. The deploy seeds it back
    only to a box that has NO overrides document (fresh box / disaster recovery) — it
    never overwrites a live one.

    THERE IS NO DEV WRITE PATH THROUGH THIS FILE. To change an override, use the web
    editor (or dayz-ctl on the box) and restart. New feature fields don't need repo
    plumbing either: the overrides engine force-creates missing JSON keys at boot.
    (The staged-overlay mechanism that briefly existed here was retired 2026-07-16 with
    the pull-only config model — see docs/CONFIGURATION.md.)

    BOX-OWNERSHIP GUARD: a marker (backups/config-overrides/last-synced.sha256) records
    the working-copy hash this script last wrote. If config-overrides.json was hand-edited
    since, the sync REFUSES to pull over it (exit 3) — make the change in the web editor
    instead, or pass -AcceptLocalLoss to discard the local edits (the pre-pull snapshot in
    backups/ keeps a copy either way).

    SYNTAX VALIDATOR: a pulled file that is not valid JSON is REJECTED (treated as no
    usable data) — a corrupt overrides file never enters the repo. With no usable box copy
    (fresh box, unreachable, corrupt) the mirror is left untouched: it is the last known
    good state and doubles as the fresh-box seed.

    Read-only by default (shows what pulling WOULD change). -Execute writes:
      config-overrides.json           the repo mirror (= the box's live document)
      backups/config-overrides/*.json timestamped snapshot of the PREVIOUS mirror (keep 10)
      backups/config-overrides/last-synced.sha256   the guard marker
.EXAMPLE
    ./Sync-ConfigOverrides.ps1                     # dry-run: what pulling the box would change
.EXAMPLE
    ./Sync-ConfigOverrides.ps1 -Execute            # pull the box's live document into the mirror
.EXAMPLE
    ./Sync-ConfigOverrides.ps1 -Execute -AcceptLocalLoss  # discard hand edits to the box-owned file
#>
[CmdletBinding()]
param(
    [string]$RemoteHost,
    [string]$RemoteUser = "ubuntu",
    [string]$RemotePath = "/home/ubuntu/servers/dayz-server",
    [string]$OverridesRel = "config-overrides.json",              # under the server root
    [string]$LocalPath   = (Join-Path $PSScriptRoot "config-overrides.json"),
    [string]$BackupDir   = (Join-Path $PSScriptRoot "backups/config-overrides"),
    [int]$KeepVersions   = 10,
    [switch]$Execute,
    [switch]$AcceptLocalLoss,
    [switch]$NoLog
)

. (Join-Path $PSScriptRoot "_DZSync.ps1")
. (Join-Path $PSScriptRoot "../../common/Utils.ps1")

$MarkerPath = Join-Path $BackupDir "last-synced.sha256"

# The syntax validator: does this text parse as JSON?
function Test-JsonText([string]$text) {
    if (-not $text -or -not $text.Trim()) { return $false }
    try { $null = $text | ConvertFrom-Json; return $true } catch { return $false }
}

# Snapshot a file into BackupDir under $Prefix.<stamp>.json and prune to KeepVersions.
function Backup-File([string]$Path, [string]$Prefix) {
    if (-not (Test-Path $Path)) { return }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item -LiteralPath $Path -Destination (Join-Path $BackupDir "$Prefix.$stamp.json") -Force
    Get-ChildItem $BackupDir -Filter "$Prefix.*.json" | Sort-Object Name -Descending |
        Select-Object -Skip $KeepVersions | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "  snapshot -> $BackupDir/$Prefix.$stamp.json (keep $KeepVersions)"
}

Resolve-DZDeployerEnv -ScriptRoot $PSScriptRoot -RemoteHost ([ref]$RemoteHost) -RemoteUser ([ref]$RemoteUser) -BoundParameters $PSBoundParameters
Assert-DZHost @{ RemoteHost = $RemoteHost; RemoteUser = $RemoteUser; RemotePath = $RemotePath }

$target = "${RemoteUser}@${RemoteHost}"

# --- Box-ownership guard -------------------------------------------------------------------
# config-overrides.json is BOX-owned (the web editor writes it); the repo working copy is a
# mirror this script maintains. A direct local edit would be silently replaced by the pull
# below, so refuse to run over one. The marker records the hash this script last wrote; a
# mismatch means hand edits happened since. First run (no marker yet) skips the check.
if (-not (Test-Path $MarkerPath)) {
    # First run: nothing recorded yet, so hand edits cannot be detected. Dry-runs stay
    # read-only by project rule, so the marker only arms on the first -Execute.
    Write-Host "NOTE: box-ownership guard not armed yet (no last-synced marker) - the first -Execute run arms it."
}
if ((Test-Path $MarkerPath) -and (Test-Path $LocalPath)) {
    $curHash  = (Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash
    $lastHash = (Get-Content -Raw -LiteralPath $MarkerPath).Trim()
    if ($lastHash -and ($curHash -ne $lastHash)) {
        if ($AcceptLocalLoss) {
            Write-Warning "config-overrides.json has local direct edits - DISCARDING them (-AcceptLocalLoss; the pre-pull snapshot in backups/ keeps a copy)."
        } else {
            Write-Error ("config-overrides.json has LOCAL DIRECT EDITS since the last sync, but the file is box-owned - the pull would overwrite them. " +
                "Make the change in the web editor (ConfigViewer) instead - it writes the box's live document, which this pull mirrors back. " +
                "Or re-run with -AcceptLocalLoss to discard the local edits (backups/ keeps a snapshot).")
            exit 3
        }
    }
}

# --- Fetch the box's live config-overrides.json (read-only) -------------------------------
$remoteFile = "$RemotePath/$OverridesRel"
Write-Host "Fetching config-overrides from ${target}:$remoteFile"
$raw = Get-Stdout { ssh -o ConnectTimeout=10 $target "cat '$remoteFile'" } | Out-String

$pullOk = $true
if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) {
    Write-Warning "Could not read $remoteFile on $target (ssh exit $LASTEXITCODE) - no live overrides this run; keeping the mirror as-is (it doubles as the fresh-box seed)."
    $pullOk = $false
} elseif (-not (Test-JsonText $raw)) {
    Write-Warning "Box config-overrides.json is NOT valid JSON - REJECTED (won't pull a corrupt file); keeping the mirror as-is."
    $pullOk = $false
}

$curTrim = if (Test-Path $LocalPath) { (Get-Content -Raw -LiteralPath $LocalPath).TrimEnd() } else { $null }

if ($pullOk) {
    $boxTrim = $raw.TrimEnd()
    if ($boxTrim -eq $curTrim) {
        Write-Host "Mirror already matches the box - nothing to write."
        if ($Execute -and -not (Test-Path $MarkerPath)) {
            New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
            (Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash | Set-Content -LiteralPath $MarkerPath
        }
    } elseif ($Execute) {
        Backup-File $LocalPath "config-overrides"
        $boxTrim | Set-Content -LiteralPath $LocalPath -Encoding utf8
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
        (Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash | Set-Content -LiteralPath $MarkerPath
        Write-Host "Pulled the box's live config-overrides.json into the repo mirror."
    } else {
        Write-Host "Dry-run - the box document DIFFERS from the mirror; -Execute would pull it in (snapshotting the current one first)."
    }
} elseif ($null -eq $curTrim) {
    Write-Warning "No usable box overrides AND no repo mirror - nothing to seed a fresh box from. Restore config-overrides.json from git history or backups/."
}

if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir "configoverrides.csv") -Row ([PSCustomObject]@{
        Timestamp  = Get-Date -Format "s"
        Source     = "${target}:$remoteFile"
        DryRun     = (-not $Execute)
        PullOk     = $pullOk
    })
}

exit 0
