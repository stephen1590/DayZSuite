#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Mirror the box's Expansion AI loadouts into the repo - BOX-AUTHORITATIVE, pull-first.
    The Expansion counterpart of Sync-SpawnPoints: the box OWNS the loadouts (they are edited there),
    the repo is a committed MIRROR + fresh-box seed. This NEVER overwrites a live box loadout.
.DESCRIPTION
    Per loadout in deploy/profiles/ExpansionMod/Loadouts/*Loadout.json:
      - box HAS it, differs, repo NOT hand-edited  -> PULL it into the repo (box wins). Snapshot the
                                                       previous repo copy first (backups/, keep N).
      - box HAS it, identical                      -> nothing.
      - box LACKS it (fresh box / disaster recovery)-> SEED it from the repo. This is the ONLY push, and
                                                       only for a file the box doesn't have - nothing to clobber.
      - box HAS it, differs, AND the repo copy was HAND-EDITED since the last sync -> HARD FAIL (exit 3).
        The box is authoritative: edit loadouts on the BOX, not the repo mirror. Resolve the diff by hand,
        then re-run. There is NO -Force by design - a diff we cannot resolve stops the run, it never
        pushes through.

    The hand-edit detector is a per-file sha256 marker (backups/loadouts/last-synced.json) recording the
    hash this script last wrote to each repo copy; a mismatch means someone edited the repo, not the box.

    VALIDATOR: a repo file that isn't valid JSON aborts the whole run before anything. A box copy that
    isn't valid JSON is REJECTED for that one loadout (never pull a corrupt file); the rest proceed.

    Read-only by default (reports what -Execute would do). -Execute writes the repo mirror (+ seeds a
    box that lacks a file) and updates the marker. Only Custom/authored loadouts are touched - the tracked
    set is exactly what lives in the repo Loadouts dir, so stock loadouts (Bandit, East, West, ...) that
    exist only on the box are never pulled or pushed.
.EXAMPLE
    ./Sync-Loadouts.ps1              # dry-run: what pulling the box (and seeding a fresh box) would change
.EXAMPLE
    ./Sync-Loadouts.ps1 -Execute     # pull the box's live loadouts into the repo mirror (+ seed any it lacks)
#>
[CmdletBinding()]
param(
    [string]$RemoteHost,
    [string]$RemoteUser  = "ubuntu",
    [string]$RemotePath  = "/home/ubuntu/servers/dayz-server",
    [string]$LoadoutRel  = "profiles/ExpansionMod/Loadouts",                                  # under the server root
    [string]$LocalDir    = (Join-Path $PSScriptRoot "deploy/profiles/ExpansionMod/Loadouts"),
    [string]$BackupDir   = (Join-Path $PSScriptRoot "backups/loadouts"),
    [int]$KeepVersions   = 10,
    [switch]$Execute,
    [switch]$NoLog
)

. (Join-Path $PSScriptRoot "_DZSync.ps1")
. (Join-Path $PSScriptRoot "../../common/Utils.ps1")

$MarkerPath = Join-Path $BackupDir "last-synced.json"

function Test-JsonText([string]$t) { if (-not $t -or -not $t.Trim()) { return $false }; try { $null = $t | ConvertFrom-Json; return $true } catch { return $false } }
function Get-TextHash([string]$t) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    ([System.BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($t)))).Replace('-', '').ToLower()
}
# Canonical form for CONTENT comparison + hashing: parse then re-serialise COMPACT, so the box
# reserialising a file (whitespace only, identical content - the game does this on load) is NOT
# seen as an edit. Order-preserving, so semantically-equal files hash equal.
function Get-Canonical([string]$t) { $t | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 40 }

Resolve-DZDeployerEnv -ScriptRoot $PSScriptRoot -RemoteHost ([ref]$RemoteHost) -RemoteUser ([ref]$RemoteUser) -BoundParameters $PSBoundParameters
Assert-DZHost @{ RemoteHost = $RemoteHost; RemoteUser = $RemoteUser; RemotePath = $RemotePath }
$target    = "${RemoteUser}@${RemoteHost}"
$remoteDir = "$RemotePath/$LoadoutRel"

# --- repo loadouts (the tracked set) + validate (never mirror against an invalid repo file) ---
$files = @(Get-ChildItem -LiteralPath $LocalDir -Filter '*Loadout.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
if (-not $files.Count) { Write-Error "No *Loadout.json under $LocalDir - nothing to mirror."; exit 2 }
$bad = @(); foreach ($f in $files) { try { $null = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { $bad += $f.Name } }
if ($bad.Count) { Write-Error "Invalid repo JSON (fix before syncing): $($bad -join ', ')"; exit 1 }

# --- marker (per-file hash the script last wrote; detects repo hand-edits) --------------------
$marker = @{}
$firstRun = -not (Test-Path $MarkerPath)
if (-not $firstRun) { try { (Get-Content -Raw -LiteralPath $MarkerPath | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $marker[$_.Name] = [string]$_.Value } } catch { } }

# --- classify each loadout (read the box copy once, cache it) ---------------------------------
$pull = @(); $seed = @(); $same = @(); $conflict = @(); $rejected = @()
$boxRawText = @{}   # box content (raw) cached for the pull write
foreach ($f in $files) {
    $repoCanon = Get-Canonical ((Get-Content -Raw -LiteralPath $f.FullName))
    $boxRaw    = Get-Stdout { ssh -o ConnectTimeout=10 $target "cat '$remoteDir/$($f.Name)' 2>/dev/null" } | Out-String
    if (-not $boxRaw.Trim()) { $seed += $f; continue }                        # box lacks it -> seed (safe: nothing to clobber)
    if (-not (Test-JsonText $boxRaw)) { $rejected += $f.Name; continue }      # corrupt box copy -> skip this one
    $boxRawText[$f.Name] = $boxRaw
    if ((Get-Canonical $boxRaw) -eq $repoCanon) { $same += $f; continue }     # SAME CONTENT (reformatting ignored)
    $repoHash = Get-TextHash $repoCanon
    if ((-not $firstRun) -and $marker[$f.Name] -and ($marker[$f.Name] -ne $repoHash)) { $conflict += $f.Name }  # repo content changed AND box differs
    else { $pull += $f }                                                      # box authoritative -> pull it
}

# --- HARD FAIL on an unresolvable diff (no force) ---------------------------------------------
if ($conflict.Count) {
    Write-Error ("Loadout mirror CONFLICT - the box differs AND these repo copies were hand-edited: $($conflict -join ', ').`n" +
        "         The BOX is authoritative for loadouts - make loadout changes on the box, not the repo mirror.`n" +
        "         Resolve by hand (diff box vs repo for each), align them, then re-run. There is no -Force.")
    exit 3
}
if ($rejected.Count) { Write-Warning "Box copy not valid JSON - skipped (won't mirror a corrupt file): $($rejected -join ', ')" }

# --- report -----------------------------------------------------------------------------------
Write-Host "Loadout mirror ($target):" -ForegroundColor Cyan
Write-Host ("  pull box->repo: {0} | seed repo->box (box lacks): {1} | already in sync: {2}" -f $pull.Count, $seed.Count, $same.Count)
$pull | ForEach-Object { Write-Host "  pull  $($_.Name)" -ForegroundColor Yellow }
$seed | ForEach-Object { Write-Host "  seed  $($_.Name)" -ForegroundColor Green }
if (-not $pull.Count -and -not $seed.Count) { Write-Host "  nothing to do - repo mirror matches the box." -ForegroundColor Green }

if ($Execute) {
    # snapshot the repo copies we're about to overwrite (pull targets) - reversible
    if ($pull.Count) {
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $snapDir = Join-Path $BackupDir $stamp
        New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
        foreach ($f in $pull) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $snapDir $f.Name) -Force }
        Get-ChildItem -LiteralPath $BackupDir -Directory | Sort-Object Name -Descending | Select-Object -Skip $KeepVersions | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  snapshot -> $snapDir (keep $KeepVersions)"
    }
    foreach ($f in $pull) {                                    # PULL: box CONTENT -> repo mirror, re-serialised pretty (reviewable diffs)
        $pretty = $boxRawText[$f.Name] | ConvertFrom-Json | ConvertTo-Json -Depth 40
        Set-Content -LiteralPath $f.FullName -Value $pretty -Encoding utf8
        $marker[$f.Name] = Get-TextHash (Get-Canonical $boxRawText[$f.Name])
    }
    foreach ($f in $seed) {                                    # SEED: repo -> box (box lacks it; nothing to clobber)
        Get-Stdout { scp -q $f.FullName "${target}:$remoteDir/$($f.Name)" } | Out-Null
        $marker[$f.Name] = Get-TextHash (Get-Canonical ((Get-Content -Raw -LiteralPath $f.FullName)))
    }
    foreach ($f in $same) { $marker[$f.Name] = Get-TextHash (Get-Canonical ((Get-Content -Raw -LiteralPath $f.FullName))) }  # arm marker
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    ($marker | ConvertTo-Json) | Set-Content -LiteralPath $MarkerPath -Encoding utf8
    Write-Host "Mirror updated ($($pull.Count) pulled, $($seed.Count) seeded)." -ForegroundColor Green
} elseif ($pull.Count -or $seed.Count) {
    Write-Host "Dry-run - re-run with -Execute to apply." -ForegroundColor Yellow
}

if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot "logs"; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir "loadouts.csv") -Row ([PSCustomObject]@{
        Timestamp = Get-Date -Format "s"; Target = "${target}:$remoteDir"
        Pull = $pull.Count; Seed = $seed.Count; Same = $same.Count; Conflict = $conflict.Count; DryRun = (-not $Execute)
    })
}

# Explicit success so a leaked $LASTEXITCODE from an inner ssh/scp doesn't fail callers (Pull-Configs/Deploy).
exit 0
