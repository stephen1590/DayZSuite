<#
.SYNOPSIS
  One-shot seed of spawn-points.json (the new definitive spawn store) from the legacy
  VPP snapshot vpp-coordinates.json. Report-only by default; -Execute writes the file.

.DESCRIPTION
  The repo/web page is now the source of truth for AI-bandit spawn locations - not VPP.
  This converts the last VPP-pulled snapshot into the clean, VPP-neutral schema that
  Build-AIBandits.ps1 reads and the ConfigViewer Map tab edits:

    { "version": 1, "points": [
        { "name": "S_Mil_Mitchland", "map": "S", "category": "Mil", "x": .., "y": .., "z": .. },
        { "name": "S_Vostok",        "map": "S",                     "x": .., "y": .., "z": .. }
    ] }

  Field mapping from a vpp-coordinates.json record:
    name  <- RawName        (kept as the STABLE UNIQUE key; ArbitraryName is not unique -
                             e.g. S_Scav_Bayakovo1 vs S_Desp_Bayakovo1 share a bare name)
    map   <- Map            (the S/C/E letter; classification.json maps it to a mission)
    category <- Category    (omitted when null -> the builder treats it as a base holdout)
    size  <- Size           (omitted when null -> the template's default size stands)
    x/y/z <- X/Y/Z          (Pos is dropped; the builder recomposes "x y z")

  NonSpawn records (the Chernarus admin teleport bookmarks, Map == null) are DROPPED:
  they were never spawns, only along for the ride in the raw VPP snapshot.

  Kept as provenance - re-run it if you want to re-seed from a fresher VPP snapshot
  before the cutover deploy. After cutover, edit spawn-points.json directly (web or hand).

.EXAMPLE
  ./Migrate-SpawnPoints.ps1              # report: show the buckets, write nothing
  ./Migrate-SpawnPoints.ps1 -Execute     # write deploy/profiles/AI_Bandits/spawn-points.json
#>
[CmdletBinding()]
param(
    [string]$ServerDir = (Join-Path $PSScriptRoot 'deploy'),
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'

$vppPath = Join-Path $ServerDir 'profiles/VPPAdminTools/VPPCoordinates/vpp-coordinates.json'
$outPath = Join-Path $ServerDir 'profiles/AI_Bandits/spawn-points.json'

if (-not (Test-Path $vppPath)) { throw "vpp-coordinates.json not found at $vppPath" }

$records = @(Get-Content -Raw -LiteralPath $vppPath | ConvertFrom-Json)
$mode    = if ($Execute) { 'execute' } else { 'report' }
Write-Host "Migrate-SpawnPoints [$mode]: $vppPath -> $outPath`n"

$dropped = @($records | Where-Object { $_.Kind -eq 'NonSpawn' -or -not $_.Map })
$spawns  = @($records | Where-Object { $_.Kind -ne 'NonSpawn' -and $_.Map })

$points = @($spawns | ForEach-Object {
    $p = [ordered]@{ name = [string]$_.RawName; map = [string]$_.Map }
    if ($_.Category) { $p.category = [string]$_.Category }
    if ($_.Size)     { $p.size     = [string]$_.Size }
    $p.x = [double]$_.X; $p.y = [double]$_.Y; $p.z = [double]$_.Z
    [pscustomobject]$p
} | Sort-Object map, name)

# Buckets, purely for the report.
$classified = @($points | Where-Object { $_.PSObject.Properties['category'] })
$coordOnly  = @($points | Where-Object { -not $_.PSObject.Properties['category'] })
Write-Host ("  Classified (category set) : {0}" -f $classified.Count)
Write-Host ("  CoordinateOnly (base)     : {0}" -f $coordOnly.Count)
Write-Host ("  Dropped (NonSpawn)        : {0}" -f $dropped.Count)
Write-Host ("  Total spawn points        : {0}`n" -f $points.Count)

$points | Group-Object map | ForEach-Object { Write-Host ("  map {0}: {1} point(s)" -f $_.Name, $_.Count) }

$doc = [ordered]@{ version = 1; points = $points }
$json = $doc | ConvertTo-Json -Depth 20

if ($Execute) {
    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
    $json | Set-Content -LiteralPath $outPath -Encoding utf8
    Write-Host "`nWrote $($points.Count) point(s) to $outPath"
} else {
    Write-Host "`n(report-only; re-run with -Execute to write)"
}
