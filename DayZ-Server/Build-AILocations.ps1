#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Compose a DRAFT of a mission's Expansion AILocationSettings RoamingLocations from
    map-points.json, written to AILocations.draft.json beside the live file.

    DRAFT-ONLY since 2026-07-21. It does NOT write AILocationSettings.json - that file is hand-
    authored and box-owned (unlocked in the web editor). This only shows what WOULD be there.
    The Expansion counterpart of Build-AIBandits: a prestart compiler, run per map, driven by the
    SAME map-points store. A map point becomes a roaming DESTINATION (not an AI - AI presence is
    the separate AIPatrols layer). Faction/loadout never live here; AILocationSettings is geography.
.DESCRIPTION
    THE MODEL (mirrors Build-AIBandits):
      - map-points.json (profiles/AI_Bandits/, box/web-edited) is the single point store. Each point
        opts into systems via `spawns` (falls back to top-level defaultSpawns). This builder consumes
        only points whose effective spawns include 'expansion'.
      - BASE = the frozen, shipped AILocationSettings default (config-defaults/.../AILocationSettings
        .defaults.json - the mod's auto-generated settlement locations, captured once). We rebuild the
        live file from BASE + our points every boot, so the output is deterministic and the mod's
        auto-gen set is never lost. ExcludedRoamingBuildings / NoGoAreas / m_Version are preserved.
      - MERGE (1st pass): KEEP everything - base locations first, our points appended as a distinct
        trailing block (their S_/E_ names don't collide with the mod's, so dupes line up for review).
      - Per point -> RoamingLocation { Name, Position:[x,y,z], Radius, Type, Enabled }:
          Type   = point.type, else a base location of the same Name (none today - names don't align),
                   else 'Local'.
          Radius = point.radius, else the average Radius in the base file (~180), else 180.
          Enabled= point.enabled, else 1.
    FAIL-SOFT: no map-points / no classification / no base and no live file => leave the file alone.
    NON-DESTRUCTIVE WHEN UNUSED: a mission with zero 'expansion' points is left completely untouched.

    Read-only by default (reports what -Fix would write). -Fix / -Apply writes the file.
.EXAMPLE
    ./Build-AILocations.ps1 -ServerDir ~/servers/dayz-server -Mission dayzOffline.sakhal
.EXAMPLE
    ./Build-AILocations.ps1 -ServerDir ~/servers/dayz-server -Mission dayzOffline.sakhal -Fix
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerDir,
    [string]$Mission,
    [Alias('Apply')][switch]$Fix,
    [string]$PreviewOut   # also write the composed AILocationSettings JSON here (any path) - local inspection only
)

$ErrorActionPreference = 'Stop'
$aiRoot = Join-Path $ServerDir 'profiles/AI_Bandits'

if (-not $Mission) {
    $mapEnv = Join-Path $ServerDir 'map.env'
    if (Test-Path $mapEnv) {
        $m = Select-String -LiteralPath $mapEnv -Pattern '^\s*DAYZ_MISSION=(.+)$' | Select-Object -First 1
        if ($m) { $Mission = $m.Matches[0].Groups[1].Value.Trim() }
    }
    if (-not $Mission) { $Mission = 'dayzOffline.chernarusplus' }
}

$warn = 0
function Show-Warn($m) { $script:warn++; Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Show-Info($m) { Write-Host $m }
function Read-Json($path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json }
# Effective value of an optional property (ConvertFrom-Json objects lack props we didn't parse).
function Get-Prop($obj, [string]$name, $default) {
    if ($obj -and $obj.PSObject.Properties[$name] -and $null -ne $obj.$name) { return $obj.$name }
    return $default
}

# --- sources -------------------------------------------------------------------------------
# The SHARED spawn store: one neutral file feeding BOTH AIB and Expansion (not under any one
# mod's folder). classification.json (the token vocabulary) still lives in AI_Bandits/common.
$pointsPath = Join-Path $ServerDir 'profiles/AI_Shared/map-points.json'
$clsPath = Join-Path $aiRoot 'common/classification.json'
if (-not (Test-Path $pointsPath)) { Show-Info "AILocations[$Mission]: no map-points store - nothing to compose."; exit 0 }
if (-not (Test-Path $clsPath))    { Show-Warn "no classification.json - cannot resolve map letters; skipping."; exit 0 }

$doc  = Read-Json $pointsPath
$cls  = Read-Json $clsPath
$letters = @($cls.maps.PSObject.Properties | Where-Object { $_.Value -eq $Mission } | ForEach-Object { $_.Name })
if (-not $letters.Count) { Show-Info "AILocations[$Mission]: no map letters for this mission in classification.json - skipping."; exit 0 }

# Default system set a point inherits when it declares no `spawns` of its own.
$defaultSpawns = @(Get-Prop $doc 'defaultSpawns' @('aib', 'expansion'))
function Wants-Expansion($p) {
    # Property PRESENT (even an empty array = 'none') is authoritative; ABSENT inherits defaultSpawns.
    # (@() coerces the ConvertFrom-Json empty-array -> $null case to an empty set, i.e. 'none'.)
    $eff = if ($p.PSObject.Properties['spawns']) { @($p.spawns) } else { $defaultSpawns }
    return ($eff -contains 'expansion')
}

$mine = @($doc.points | Where-Object { $letters -contains $_.map -and (Wants-Expansion $_) })
if (-not $mine.Count) {
    Show-Info "AILocations[$Mission]: no 'expansion'-toggled points for this mission - no draft written."
    exit 0
}

# --- BASE (frozen default preferred; else the live file; else a minimal wrapper) -----------
$livePath = Join-Path $ServerDir "mpmissions/$Mission/expansion/settings/AILocationSettings.json"
# DRAFT is the ONLY write target (2026-07-21) - twin of Build-AIPatrols. The live file is hand-
# authored and box-owned; we read it as a base candidate and never write it.
$draftPath = Join-Path $ServerDir "mpmissions/$Mission/expansion/settings/AILocations.draft.json"
$baseCandidates = @(
    (Join-Path $ServerDir "config-defaults/mpmissions/$Mission/expansion/settings/AILocationSettings.defaults.json"),
    (Join-Path $ServerDir "mpmissions/$Mission/expansion/settings/AILocationSettings.defaults.json"),
    $livePath
)
$basePath = $baseCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($basePath) {
    $base = Read-Json $basePath
    $baseLocs = @(Get-Prop $base 'RoamingLocations' @())
} else {
    Show-Warn "no base AILocationSettings (default or live) for $Mission - composing a fresh file with only our points."
    $base = [pscustomobject]@{ m_Version = 12; RoamingLocations = @(); ExcludedRoamingBuildings = @(); NoGoAreas = @() }
    $baseLocs = @()
}

# Average Radius in the base = the sensible per-map default when a point sets none.
$baseRadii = @($baseLocs | ForEach-Object { Get-Prop $_ 'Radius' $null } | Where-Object { $null -ne $_ })
$defRadius = if ($baseRadii.Count) { [math]::Round(($baseRadii | Measure-Object -Average).Average) } else { 180 }
# Type lookup by exact Name (none align today, but honour it if a point is named for a base location).
$typeByName = @{}
foreach ($l in $baseLocs) { $n = Get-Prop $l 'Name' $null; if ($n) { $typeByName[[string]$n] = (Get-Prop $l 'Type' 'Local') } }

# --- our points -> RoamingLocation entries -------------------------------------------------
$ours = @()
foreach ($p in ($mine | Sort-Object -Property name)) {
    $type = Get-Prop $p 'type' $null
    if (-not $type) { $type = if ($typeByName.ContainsKey([string]$p.name)) { $typeByName[[string]$p.name] } else { 'Local' } }
    $ours += [pscustomobject][ordered]@{
        Name     = [string]$p.name
        Position = @([double]$p.x, [double]$p.y, [double]$p.z)
        Radius   = [double](Get-Prop $p 'radius' $defRadius)
        Type     = [string]$type
        Enabled  = [int](Get-Prop $p 'enabled' 1)
    }
}

# --- merge + compose (base first, ours appended - lined up for review) ---------------------
$out = $base
if ($out.PSObject.Properties['RoamingLocations']) { $out.RoamingLocations = @($baseLocs + $ours) }
else { $out | Add-Member -NotePropertyName RoamingLocations -NotePropertyValue @($baseLocs + $ours) }

$json = $out | ConvertTo-Json -Depth 12
Show-Info "AILocations[$Mission]: base $($baseLocs.Count) + $($ours.Count) map-point location(s) = $($baseLocs.Count + $ours.Count) total (Type default 'Local', Radius default $defRadius)$(if (-not $Fix) { ' (report-only)' })."

if ($PreviewOut) { New-Item -ItemType Directory -Force -Path (Split-Path $PreviewOut) | Out-Null; Set-Content -LiteralPath $PreviewOut -Value $json -Encoding utf8; Show-Info "  preview -> $PreviewOut" }
if ($Fix) {
    New-Item -ItemType Directory -Force -Path (Split-Path $draftPath) | Out-Null
    Set-Content -LiteralPath $draftPath -Value $json -Encoding utf8
    Show-Info "  wrote $draftPath (DRAFT - the live AILocationSettings.json is not touched)"
} elseif (-not $PreviewOut) {
    Show-Info "  (dry-run - re-run with -Fix to write $draftPath)"
}
if ($warn) { Show-Info "AILocations[$Mission]: $warn warning(s)." }
exit 0
