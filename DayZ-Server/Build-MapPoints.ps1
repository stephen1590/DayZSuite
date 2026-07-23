#requires -Version 7
<#
.SYNOPSIS
  Derive the Map tab's point store from the ACTIVE mission's live Expansion AI settings,
  every prestart.

.DESCRIPTION
  Phase 2 of the map inversion (2026-07-23). The OLD direction had map-points.json as the
  authored source that Build-AIPatrols/Build-AILocations composed drafts FROM. The NEW
  direction inverts that: the live, web-edited AILocationSettings.json / AIPatrolSettings.json
  ARE the truth, and this script derives a read-only point store FROM them for the Map tab
  to render (Phase 3). The authored map-points.json is frozen (snapshot in archive/) and no
  longer rendered - see MAP_POINTS_DEPRECATED in ConfigViewer's map.js.

  Reads   mpmissions/<mission>/expansion/settings/AILocationSettings.json
          mpmissions/<mission>/expansion/settings/AIPatrolSettings.json
  Writes  profiles/AI_Shared/map-points.generated.json     (registry 'generated': read-only
                                                            in the web editor, never mirrored)

  The store mirrors the two source files 1:1 (owner's call, 2026-07-23) instead of merging
  into one tagged list, so Phase 3 can present each list as-if editing its source file and
  Phase 4 can lock per-file:
    locations[]      one per RoamingLocations entry - positional (Position -> x/y/z)
    patrols[]        one per Patrols entry with NO ObjectClassName - positional; the marker
                     is the FIRST waypoint, the full Waypoints ride along for route rendering
    objectPatrols[]  one per Patrols entry WITH an ObjectClassName - these spawn at EVERY
                     instance of that object class, so they have no single map position and
                     are listed, never plotted. Dropping them would silently lose real config.

  DETERMINISTIC: same inputs -> byte-identical output (no timestamps), so drift checks stay
  meaningful. FAIL-SOFT: an ABSENT source file yields that section empty (a mission that has
  not booted Expansion yet genuinely has no such points); an UNPARSEABLE source leaves the
  previous output untouched (never clobber a good store with a broken read). Report-only by
  default; -Fix writes. Run by prestart.sh wrapped in `|| true` - can NEVER block boot.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerDir,
    [string]$Mission,
    [Alias('Apply')][switch]$Fix
)

$ErrorActionPreference = 'Stop'

function Show-Info($m) { Write-Host $m }
function Show-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

# Resolve the active mission the same way the engine does (map.env), unless one was passed.
if (-not $Mission) {
    $mapEnv = Join-Path $ServerDir 'map.env'
    if (Test-Path $mapEnv) {
        $m = Select-String -LiteralPath $mapEnv -Pattern '^\s*DAYZ_MISSION=(.+)$' | Select-Object -First 1
        if ($m) { $Mission = $m.Matches[0].Groups[1].Value.Trim() }
    }
    if (-not $Mission) { $Mission = 'dayzOffline.chernarusplus' }
}

$settingsDir = Join-Path $ServerDir "mpmissions/$Mission/expansion/settings"
$locPath     = Join-Path $settingsDir 'AILocationSettings.json'
$patPath     = Join-Path $settingsDir 'AIPatrolSettings.json'
$outDir      = Join-Path $ServerDir 'profiles/AI_Shared'
$outPath     = Join-Path $outDir 'map-points.generated.json'

if (-not (Test-Path (Join-Path $ServerDir "mpmissions/$Mission"))) {
    Show-Warn "mission dir not found: mpmissions/$Mission - skipped."; return
}

# --- read the two sources (absent = empty section; unparseable = keep previous output) -------
$locDoc = $null; $patDoc = $null
if (Test-Path $locPath) {
    try { $locDoc = Get-Content -Raw -LiteralPath $locPath | ConvertFrom-Json }
    catch { Show-Warn "AILocationSettings.json is not valid JSON - leaving map-points.generated.json untouched ($($_.Exception.Message))."; return }
} else { Show-Warn "no AILocationSettings.json for $Mission - locations will be empty." }
if (Test-Path $patPath) {
    try { $patDoc = Get-Content -Raw -LiteralPath $patPath | ConvertFrom-Json }
    catch { Show-Warn "AIPatrolSettings.json is not valid JSON - leaving map-points.generated.json untouched ($($_.Exception.Message))."; return }
} else { Show-Warn "no AIPatrolSettings.json for $Mission - patrols will be empty." }

# --- locations: RoamingLocations, all positional -------------------------------------------
$locations = @()
foreach ($l in @($locDoc.RoamingLocations)) {
    if (-not $l -or -not $l.Name) { continue }
    $p = @($l.Position)
    $locations += [ordered]@{
        name    = [string]$l.Name
        x       = [double]$p[0]; y = [double]$p[1]; z = [double]$p[2]
        radius  = [double]$l.Radius
        type    = [string]$l.Type
        enabled = [int]$l.Enabled
    }
}

# --- patrols: split on ObjectClassName ------------------------------------------------------
# Name is NOT required: the mod's stock object patrols carry an EMPTY Name and are identified
# by ObjectClassName alone (enoch ships that way; requiring a name silently dropped all 17).
$patrols = @(); $objectPatrols = @()
foreach ($pt in @($patDoc.Patrols)) {
    if (-not $pt) { continue }
    $objClass = [string]$pt.ObjectClassName
    if ($objClass) {
        # Spawns at every instance of the class; waypoints are offsets near origin - not a point.
        $objectPatrols += [ordered]@{
            name       = if ("$($pt.Name)") { [string]$pt.Name } else { $objClass }
            objectClass = $objClass
            faction    = [string]$pt.Faction
            loadout    = [string]$pt.Loadout
            count      = [int]$pt.NumberOfAI
            countMax   = [int]$pt.NumberOfAIMax
            behaviour  = [string]$pt.Behaviour
            chance     = [double]$pt.Chance
        }
        continue
    }
    $wps = @($pt.Waypoints)
    if (-not $wps.Count) { Show-Warn "patrol '$([string]$pt.Name)' has no waypoints and no object class - not plottable, skipped."; continue }
    $first = @($wps[0])
    $patrols += [ordered]@{
        name      = [string]$pt.Name
        x         = [double]$first[0]; y = [double]$first[1]; z = [double]$first[2]
        faction   = [string]$pt.Faction
        loadout   = [string]$pt.Loadout
        count     = [int]$pt.NumberOfAI
        countMax  = [int]$pt.NumberOfAIMax
        behaviour = [string]$pt.Behaviour
        speed     = [string]$pt.Speed
        chance    = [double]$pt.Chance
        persist   = [int]$pt.Persist
        waypoints = @($wps | ForEach-Object { ,@($_ | ForEach-Object { [double]$_ }) })
    }
}

$store = [ordered]@{
    _readme       = "GENERATED every prestart by Build-MapPoints.ps1 from the ACTIVE mission's live Expansion AI settings - AILocationSettings.json (locations) + AIPatrolSettings.json (patrols/objectPatrols). NEVER edit this file: edit those source files (web editor) and restart. objectPatrols spawn at every instance of their object class, so they have no map position and are listed, not plotted. The pre-inversion authored store is archived at archive/map-points.snapshot-2026-07-23.json."
    version       = 2
    mission       = $Mission
    locations     = $locations
    patrols       = $patrols
    objectPatrols = $objectPatrols
}

$json  = ($store | ConvertTo-Json -Depth 8) + "`n"
$state = if (-not (Test-Path $outPath)) { 'Missing' }
         elseif ((Get-Content -Raw -LiteralPath $outPath) -eq $json) { 'InSync' }
         else { 'Drift' }

Show-Info ("MapPoints[{0}]: {1} location(s), {2} patrol(s), {3} object patrol(s) -> map-points.generated.json {4}{5}." -f `
    $Mission, $locations.Count, $patrols.Count, $objectPatrols.Count, $state, $(if (-not $Fix) { ' (report-only)' }))
if (-not $Fix -or $state -eq 'InSync') { return }

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Set-Content -LiteralPath $outPath -Value $json -NoNewline -Encoding utf8
Show-Info "MapPoints[$Mission]: map-points.generated.json written."
