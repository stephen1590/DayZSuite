#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pulls VPP TeleportManager locations off the live server and saves them as the
    coordinate source-of-truth for AI Bandit spawn generation.
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
.EXAMPLE
    ./Sync-VPPCoordinates.ps1            # dry-run: show the parsed table, write nothing
.EXAMPLE
    ./Sync-VPPCoordinates.ps1 -Execute   # pull + save the snapshot and normalised list
#>
[CmdletBinding()]
param(
    [string]$RemoteHost = "servermander.ovh",                  # main copy (OVH Ubuntu VPS)
    [string]$RemoteUser = "ubuntu",
    [string]$RemotePath = "/home/ubuntu/servers/dayz-server",  # dayz-server root on the box
    # TeleportLocation.json location under the server root (VPP writes it here).
    [string]$TeleportRel = "profiles/VPPAdminTools/ConfigurablePlugins/TeleportManager/TeleportLocation.json",
    # Classification config: maps letter/category/size tokens to real values (hand-maintained).
    [string]$ClassificationPath = (Join-Path $PSScriptRoot "deploy/profiles/AI_Bandits/common/classification.json"),
    [string]$OutDir = (Join-Path $PSScriptRoot "deploy/profiles/VPPAdminTools/VPPCoordinates"),
    [switch]$Execute,   # actually write the files (default is a dry-run)
    [switch]$NoLog
)

. (Join-Path $PSScriptRoot "_DZSync.ps1")
. (Join-Path $PSScriptRoot "../../common/Utils.ps1")

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
if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) {
    Write-Error "Could not read $remoteFile on $target (ssh exit $LASTEXITCODE). Is the path right and the host reachable?"
    exit 1
}

try { $doc = $raw | ConvertFrom-Json } catch {
    Write-Error "Fetched content is not valid JSON: $_"
    exit 1
}
$locs = @($doc.m_TeleportLocations)
if (-not $locs.Count) { Write-Warning "No m_TeleportLocations found in the file — nothing to parse." }

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

$classified = @($records | Where-Object { $_.Kind -eq 'Classified' })
$coordOnly  = @($records | Where-Object { $_.Kind -eq 'CoordinateOnly' })
$nonSpawn   = @($records | Where-Object { $_.Kind -eq 'NonSpawn' })

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

# --- Write (only under -Execute). ----------------------------------------------------------
$snapshotPath = Join-Path $OutDir "TeleportLocation.snapshot.json"
$normPath     = Join-Path $OutDir "vpp-coordinates.json"
if ($Execute) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    # Verbatim snapshot — exactly what the box returned, for audit and to diff drift later.
    $raw.TrimEnd() | Set-Content -LiteralPath $snapshotPath -Encoding utf8
    # Normalised list — every entry with its parsed fields + Conforms flag.
    ($records | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $normPath -Encoding utf8
    Write-Host "Wrote:`n  $snapshotPath`n  $normPath"
} else {
    Write-Host "Dry-run — nothing written. Re-run with -Execute to save to:`n  $snapshotPath`n  $normPath"
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
