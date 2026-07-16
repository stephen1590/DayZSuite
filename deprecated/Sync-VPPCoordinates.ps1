#!/usr/bin/env pwsh
<#
.SYNOPSIS
    DEPRECATED (2026-07-15). Pulls VPP TeleportManager locations off the live server into
    vpp-coordinates.json. VPP is NO LONGER the source of truth for AI-bandit spawns — the
    repo/web is (spawn-points.json, edited in the ConfigViewer Map tab, box-authoritative).
    This is now a ONE-SHOT IMPORTER, not part of the deploy: run it only to seed the repo from
    a fresh batch of VPP captures, then convert with Migrate-SpawnPoints.ps1. The deploy uses
    Sync-SpawnPoints.ps1 (box->repo) instead. Kept for that occasional import; safe to delete
    once no more coordinates are captured in-game.
.DESCRIPTION
    Roles are INVERTED from the rest of the deploy: for spawn coordinates the LIVE box
    is authoritative, because admins capture positions in-game with VPPAdminTools (real,
    on-grid, never guessed). This script pulls that list DOWN into the repo so the AIB
    generator can build placements from it. We only ever READ the server's
    TeleportLocation.json — it is never pushed back (it also holds admins' personal
    teleport bookmarks; clobbering it would wipe their saves).

    Spawn points are named by convention so they can live in the same VPP store as
    ordinary bookmarks without collision. Vocab (map letters / categories / sizes) comes
    from classification.json, so each name falls into one of three Kinds:

        Classified      <Map>_<Category>_<Size>_<Name>   e.g. S_Mil_L_Geo_Mitchland
                        -> the matching group gets coords + template + size
        CoordinateOnly  <Map>_<Name>                     e.g. S_Aniva
                        -> the matching group gets ONLY its coordinates updated
        NonSpawn        no map prefix                     e.g. Cherno, NWAF
                        -> an ordinary teleport bookmark; ignored by the generator

    ArbitraryName may contain underscores (Geo_Mitchland); only the leading fixed fields
    are tokens. Every entry is kept in the snapshot with its Kind, so the report doubles
    as the migration checklist.

    Read-only by default: a bare run FETCHES + PARSES + PRINTS what it found and what it
    WOULD write. Add -Execute to actually write the files under
    deploy/profiles/VPPAdminTools/VPPCoordinates/ :
        TeleportLocation.snapshot.json   verbatim copy from the box (audit / fidelity)
        vpp-coordinates.json             normalised records the generator consumes
    -Execute backs up whatever was previously pulled into a backups/ subdirectory (timestamped,
    never a same-dir .bak sibling) before overwriting — skipped when the fetch is byte-identical
    to the last pull, so an unchanged box never grows the backup pile.

    FALLBACK + DEFAULT: a normal run overwrites vpp-coordinates.json ONLY when the pull yields
    USABLE spawn data (>=1 classified or coordinate-only bookmark). If the box file is missing,
    empty, unreadable, or holds only ordinary bookmarks, the run does NOT clobber good coords or
    abort a deploy - it falls back to the committed vpp-coordinates.default.json baseline. Seed or
    refresh that baseline explicitly, OUTSIDE the deploy sync, with -SetDefault:

        -SetDefault -Execute   pull live coords and WRITE them to vpp-coordinates.default.json
                               (refuses to bless an empty default)

    ONE-COMMAND CHAIN: add -Build to also run Build-AIBandits.ps1 against deploy/ right after the
    pull, once per mission under deploy/profiles/AI_Bandits/maps/ — a single invocation pulls the
    live bookmarks AND shows you every map's composed DynamicAIB, instead of two scripts run by
    hand. This ALWAYS writes a real, inspectable file per mission under ./preview/AI_Bandits/ (a
    plain top-level folder, never shipped, never confused with deploy/'s real sources) — that is
    the whole point of -Build: you asked to SEE the output, not just a truncated console table.
    The real file the mod reads never exists here at all; it's generated on the box at every
    boot by prestart.sh and never persists even there between restarts.
.EXAMPLE
    ./Sync-VPPCoordinates.ps1                     # dry-run: show the parsed table, write nothing
.EXAMPLE
    ./Sync-VPPCoordinates.ps1 -Execute -Build     # pull + save, then write ./preview/AI_Bandits/*.json
.EXAMPLE
    ./Sync-VPPCoordinates.ps1 -SetDefault -Execute # bless current live coords as the fallback baseline
#>
[CmdletBinding()]
param(
    [string]$RemoteHost,                                        # dev-machine-local — see deployer.env, or -RemoteHost
    [string]$RemoteUser = "ubuntu",                             # override via deployer.env's DEPLOY_REMOTE_USER if it differs
    [string]$RemotePath = "/home/ubuntu/servers/dayz-server",  # dayz-server root on the box
    # TeleportLocation.json location under the server root (VPP writes it here).
    [string]$TeleportRel = "profiles/VPPAdminTools/ConfigurablePlugins/TeleportManager/TeleportLocation.json",
    # Classification config: maps letter/category/size tokens to real values (hand-maintained).
    [string]$ClassificationPath = (Join-Path $PSScriptRoot "deploy/profiles/AI_Bandits/common/classification.json"),
    [string]$OutDir = (Join-Path $PSScriptRoot "deploy/profiles/VPPAdminTools/VPPCoordinates"),
    [switch]$Execute,   # actually write the files (default is a dry-run)
    [switch]$Build,     # chain: also run Build-AIBandits.ps1 against deploy/, writing ./preview/AI_Bandits/<mission>.json
    [switch]$SetDefault, # ad-hoc, OUTSIDE the deploy sync: bless the current live coords as vpp-coordinates.default.json (the fallback used when a normal pull yields no usable data). Needs -Execute to write.
    [switch]$NoLog
)

. (Join-Path $PSScriptRoot "_DZSync.ps1")
. (Join-Path $PSScriptRoot "../../common/Utils.ps1")

Resolve-DZDeployerEnv -ScriptRoot $PSScriptRoot -RemoteHost ([ref]$RemoteHost) -RemoteUser ([ref]$RemoteUser) -BoundParameters $PSBoundParameters
Assert-DZHost @{ RemoteHost = $RemoteHost; RemoteUser = $RemoteUser; RemotePath = $RemotePath }

# Classification vocab drives the parse: which single-letter map prefixes, category tokens,
# and size buckets are real. Kept in ONE file (classification.json) so the sync and the
# builder can't drift on what a name means. Fail hard if it's missing — without it we can't
# tell a spawn point from an ordinary teleport bookmark.
if (-not (Test-Path $ClassificationPath)) {
    Write-Error "Classification config not found: $ClassificationPath"
    exit 2
}
$cls        = Get-Content -Raw -LiteralPath $ClassificationPath | ConvertFrom-Json
$mapLetters = @($cls.maps.PSObject.Properties.Name)
$categories = @($cls.categories.PSObject.Properties.Name)
$sizes      = @($cls.sizes.PSObject.Properties.Name)

$target    = "${RemoteUser}@${RemoteHost}"
$remoteFile = "$RemotePath/$TeleportRel"

# --- Fetch (read-only): cat the file over ssh. Get-Stdout drops the ErrorRecord noise
#     ssh/2>&1 would otherwise fold into the string stream. ------------------------------
Write-Host "Fetching VPP teleport locations from ${target}:$remoteFile"
$raw = Get-Stdout { ssh -o ConnectTimeout=10 $target "cat '$remoteFile'" } | Out-String

# Soft-fail by design: a missing / empty / invalid pull is NOT fatal. $pullOk drives the write
# dispatch below - a normal run with no usable data falls back to vpp-coordinates.default.json
# instead of clobbering good coords or aborting the deploy. $locs stays empty so the classifier
# below no-ops.
$pullOk = $true
$doc = $null
$locs = @()
if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) {
    Write-Warning "Could not read $remoteFile on $target (ssh exit $LASTEXITCODE) — no live data this run."
    $pullOk = $false
} else {
    try { $doc = $raw | ConvertFrom-Json } catch {
        Write-Warning "Fetched content is not valid JSON — no live data this run: $_"
        $pullOk = $false
    }
}
if ($pullOk) {
    $locs = @($doc.m_TeleportLocations)
    if (-not $locs.Count) { Write-Warning "No m_TeleportLocations in the file — no live data this run."; $pullOk = $false }
}

# --- Classify each entry by splitting on '_' and testing fields against the vocab. --------
#   Classified     : <Map>_<Cat>_<Name...>  (Map/Cat/Size all known) -> coords + template + size
#   CoordinateOnly : <Map>_<Name...>               (Map known, not classified) -> coords only
#   NonSpawn       : anything else (no map prefix; e.g. Chernarus bookmarks)  -> ignored
# ArbitraryName keeps its underscores (Geo_Mitchland); only the fixed leading fields are tokens.
$records = foreach ($l in $locs) {
    $name = [string]$l.m_Name
    $p = @($l.m_Position)
    $x, $y, $z = $p[0], $p[1], $p[2]
    $f = $name -split '_'

    $kind = 'NonSpawn'; $map = $null; $cat = $null; $size = $null; $arb = $name
    if ($f.Count -ge 2 -and ($mapLetters -contains $f[0])) {
        $map = $f[0]
        if ($categories -contains $f[1]) {
            # A known CATEGORY in field 2 makes it a spawn. SIZE (field 3) is OPTIONAL: if it's a
            # known size token it overrides, otherwise it's part of the name and the group inherits
            # its template's default size. So S_Mil_IslandBlockade and S_Mil_L_IslandBlockade both work.
            $kind = 'Classified'; $cat = $f[1]
            if ($f.Count -ge 4 -and ($sizes -contains $f[2])) {
                $size = $f[2]; $arb = ($f[3..($f.Count - 1)] -join '_')
            } else {
                $arb = ($f[2..($f.Count - 1)] -join '_')
            }
        } else {
            $kind = 'CoordinateOnly'; $arb = ($f[1..($f.Count - 1)] -join '_')
        }
    }
    [PSCustomObject]@{
        RawName       = $name
        Kind          = $kind
        Map           = $map
        Category      = $cat
        Size          = $size
        ArbitraryName = $arb
        X             = $x; Y = $y; Z = $z
        Pos           = ('{0} {1} {2}' -f $x, $y, $z)   # DynamicAIB pos string, ready to drop in
    }
}

$records    = @($records)
$classified = @($records | Where-Object { $_.Kind -eq 'Classified' })
$coordOnly  = @($records | Where-Object { $_.Kind -eq 'CoordinateOnly' })
$nonSpawn   = @($records | Where-Object { $_.Kind -eq 'NonSpawn' })

# A pull that parsed but has zero SPAWN records (empty file, or only ordinary bookmarks) is not
# usable spawn data - treat it like a failed pull so the dispatch below falls back to the default.
if ($pullOk -and (($classified.Count + $coordOnly.Count) -eq 0)) {
    Write-Warning "Pull has no spawn points (0 classified/coordinate-only of $($records.Count) bookmark(s)) — no usable spawn data this run."
    $pullOk = $false
}

# --- Report the three buckets. -------------------------------------------------------------
Write-Host ("`nParsed {0} location(s): {1} classified, {2} coordinate-only, {3} non-spawn.`n" -f `
    $records.Count, $classified.Count, $coordOnly.Count, $nonSpawn.Count)
if ($classified.Count) {
    Write-Host "Classified (coords + template + size override the matching group):"
    $classified | Sort-Object Map, Category, Size, ArbitraryName |
        Format-Table Map, Category, Size, ArbitraryName, X, Y, Z -AutoSize | Out-Host
}
if ($coordOnly.Count) {
    Write-Host "Coordinate-only (update ONLY the coords of a same-named group):"
    $coordOnly | Sort-Object Map, ArbitraryName |
        Format-Table Map, ArbitraryName, X, Y, Z -AutoSize | Out-Host
}
if ($nonSpawn.Count) {
    Write-Host "Non-spawn (no map prefix — ignored; e.g. ordinary teleport bookmarks):"
    Write-Host ('  ' + (($nonSpawn.RawName | Sort-Object) -join ', ') + "`n")
}

# --- Write. Three paths: (1) -SetDefault blesses the live coords as the committed baseline;
#     (2) normal + usable pull refreshes the working vpp-coordinates.json; (3) normal + no usable
#     pull falls back to vpp-coordinates.default.json so a deploy never ships empty. ------------
$snapshotPath = Join-Path $OutDir "TeleportLocation.snapshot.json"
$normPath     = Join-Path $OutDir "vpp-coordinates.json"
$defaultPath  = Join-Path $OutDir "vpp-coordinates.default.json"
$backupDir    = Join-Path $OutDir "backups"

if ($SetDefault) {
    # Ad-hoc, OUTSIDE the deploy sync: capture the current live coords as the fallback baseline.
    # Refuses to bless an empty default (that would defeat the whole safety net).
    if (-not $pullOk) {
        Write-Error "-SetDefault: live pull has no usable spawn coordinates — refusing to overwrite the default with nothing. Capture spawn bookmarks in-game first."
        exit 1
    }
    if ($Execute) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        if (Test-Path $defaultPath) {
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            $bstamp = Get-Date -Format "yyyyMMdd_HHmmss"
            Copy-Item -LiteralPath $defaultPath -Destination (Join-Path $backupDir "vpp-coordinates.default.$bstamp.json") -Force
            Write-Host "Backed up previous default to $backupDir (*.$bstamp.json)"
        }
        ($records | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $defaultPath -Encoding utf8
        Write-Host ("Set default baseline ({0} records, {1} spawns): {2}" -f $records.Count, ($classified.Count + $coordOnly.Count), $defaultPath)
    } else {
        Write-Host "Dry-run (-SetDefault) — would write $($records.Count) records to the baseline:`n  $defaultPath`n  Re-run with -Execute to write."
    }
}
elseif ($pullOk) {
    # Usable live data -> refresh the working file the deploy ships and the builder consumes.
    if ($Execute) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        $prevRaw = if (Test-Path $snapshotPath) { (Get-Content -Raw -LiteralPath $snapshotPath).TrimEnd() } else { $null }
        if ($null -ne $prevRaw -and $prevRaw -eq $raw.TrimEnd()) {
            Write-Host "No change since the last pull — snapshot/vpp-coordinates.json left as-is (no backup needed)."
        } else {
            # Back up whatever was pulled last time before overwriting — a subdirectory, never a
            # same-dir '.bak'/'fixed_' sibling, so the live snapshot/vpp-coordinates.json stay
            # unambiguous. Skipped on a first-ever pull (nothing to back up yet).
            if (Test-Path $snapshotPath) {
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                $bstamp = Get-Date -Format "yyyyMMdd_HHmmss"
                Copy-Item -LiteralPath $snapshotPath -Destination (Join-Path $backupDir "TeleportLocation.snapshot.$bstamp.json") -Force
                if (Test-Path $normPath) {
                    Copy-Item -LiteralPath $normPath -Destination (Join-Path $backupDir "vpp-coordinates.$bstamp.json") -Force
                }
                Write-Host "Backed up previous pull to $backupDir (*.$bstamp.json)"
            }
            # Verbatim snapshot — exactly what the box returned, for audit and to diff drift later.
            $raw.TrimEnd() | Set-Content -LiteralPath $snapshotPath -Encoding utf8
            # Normalised list — every entry with its parsed fields + Kind.
            ($records | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $normPath -Encoding utf8
            Write-Host "Wrote:`n  $snapshotPath`n  $normPath"
        }
    } else {
        Write-Host "Dry-run — nothing written. Re-run with -Execute to save to:`n  $snapshotPath`n  $normPath"
    }
}
else {
    # No usable live data -> fall back to the committed default so the deploy ships good coords
    # instead of nothing. Soft by design: never aborts the deploy (exit 0).
    if (Test-Path $defaultPath) {
        if ($Execute) {
            $defRaw = (Get-Content -Raw -LiteralPath $defaultPath).TrimEnd()
            $curRaw = if (Test-Path $normPath) { (Get-Content -Raw -LiteralPath $normPath).TrimEnd() } else { $null }
            if ($defRaw -eq $curRaw) {
                Write-Host "No usable live data — vpp-coordinates.json already equals the default; left as-is."
            } else {
                New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
                if (Test-Path $normPath) {
                    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                    $bstamp = Get-Date -Format "yyyyMMdd_HHmmss"
                    Copy-Item -LiteralPath $normPath -Destination (Join-Path $backupDir "vpp-coordinates.$bstamp.json") -Force
                }
                Copy-Item -LiteralPath $defaultPath -Destination $normPath -Force
                Write-Warning "No usable live data — fell back to the default baseline (vpp-coordinates.default.json -> vpp-coordinates.json)."
            }
        } else {
            Write-Host "Dry-run — no usable live data; would fall back to the default baseline:`n  $defaultPath -> $normPath"
        }
    } else {
        Write-Warning "No usable live data AND no default baseline yet ($defaultPath). Left vpp-coordinates.json untouched. Seed one once with:  ./Sync-VPPCoordinates.ps1 -SetDefault -Execute  (after capturing spawn bookmarks)."
    }
}

# --- Run log (CSV, append, timestamped; -NoLog to disable). --------------------------------
if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir "vppcoords.csv") -Row ([PSCustomObject]@{
        Timestamp      = Get-Date -Format "s"
        Source         = "${target}:$remoteFile"
        DryRun         = (-not $Execute)
        Total          = $records.Count
        Classified     = $classified.Count
        CoordinateOnly = $coordOnly.Count
        NonSpawn       = $nonSpawn.Count
    })
}

# --- Chain: build + WRITE a real preview per mission, outside deploy/ so it's never mistaken
#     for a shipped source. This is the whole point of -Build - an actual file to open, not just
#     a console table. -------------------------------------------------------------------------
if ($Build) {
    if (-not $Execute) { Write-Warning "-Build without -Execute previews the LAST pulled vpp-coordinates.json, not this fetch." }
    $builder     = Join-Path $PSScriptRoot "Build-AIBandits.ps1"
    $deployDir   = Join-Path $PSScriptRoot "deploy"
    $mapsDir     = Join-Path $deployDir "profiles/AI_Bandits/maps"
    $previewDir  = Join-Path $PSScriptRoot "preview/AI_Bandits"
    if (-not (Test-Path $builder)) {
        Write-Error "Build-AIBandits.ps1 not found next to this script - can't chain -Build."
    } else {
        $missions = @(Get-ChildItem -LiteralPath $mapsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        if (-not $missions.Count) { Write-Warning "No per-map folders under $mapsDir - nothing to build." }
        foreach ($m in $missions) {
            Write-Host "`n--- Build-AIBandits: $m ---"
            & $builder -ServerDir $deployDir -Mission $m -PreviewOut (Join-Path $previewDir "$m.DynamicAIB.json")
        }
    }
}
