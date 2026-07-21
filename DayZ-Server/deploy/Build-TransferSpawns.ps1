#requires -Version 7
<#
.SYNOPSIS
  Hand the active mission's own spawn points + a transfer generation to the server-only
  TransferSpawn mod. Run by prestart.sh before each server start.

.DESCRIPTION
  Reads the active mission's cfgplayerspawnpoints.xml, takes its <travel> spawn points
  (the game's designated map-transfer locations; falls back to <fresh> if a map defines
  no travel group), and writes them with the caller-supplied generation to
  profiles/transfer_spawn.json — which the TransferSpawn PBO reads to relocate migrated
  characters after a map switch.

  Report-only by default (prints what it would write). Writes only with -Fix. Fail-soft:
  a parse problem prints a warning and leaves any existing file in place, so it can never
  block server start (prestart calls it with `|| true`).

.EXAMPLE
  ./Build-TransferSpawns.ps1 -ServerDir . -Mission dayzOffline.sakhal -Gen 3
      Report the points that would be written for generation 3. No changes.

.EXAMPLE
  ./Build-TransferSpawns.ps1 -ServerDir . -Mission dayzOffline.sakhal -Gen 3 -Fix
      Write profiles/transfer_spawn.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerDir,
    [Parameter(Mandatory)][string]$Mission,
    [int]$Gen = 0,
    [switch]$Fix
)

$ErrorActionPreference = 'Stop'

$xmlPath = Join-Path $ServerDir "mpmissions/$Mission/cfgplayerspawnpoints.xml"
$outPath = Join-Path $ServerDir 'profiles/transfer_spawn.json'

if (-not (Test-Path $xmlPath)) {
    Write-Warning "TransferSpawn: no cfgplayerspawnpoints.xml at $xmlPath — leaving any existing $outPath untouched."
    return
}

try {
    [xml]$doc = Get-Content -Raw $xmlPath
} catch {
    Write-Warning "TransferSpawn: could not parse $xmlPath ($($_.Exception.Message)) — leaving $outPath untouched."
    return
}

# <travel> is the game's map-transfer group; every playable mission has a populated <fresh>,
# so that is the guaranteed-safe fallback.
$nodes = $doc.SelectNodes('/playerspawnpoints/travel//pos')
$src = 'travel'
if (-not $nodes -or $nodes.Count -eq 0) {
    $nodes = $doc.SelectNodes('/playerspawnpoints/fresh//pos')
    $src = 'fresh'
}
if (-not $nodes -or $nodes.Count -eq 0) {
    Write-Warning "TransferSpawn: $Mission has no travel/fresh <pos> points — leaving $outPath untouched."
    return
}

$ci = [System.Globalization.CultureInfo]::InvariantCulture
$points = foreach ($n in $nodes) {
    [pscustomobject]@{
        x = [math]::Round([double]::Parse($n.x, $ci), 2)
        z = [math]::Round([double]::Parse($n.z, $ci), 2)
    }
}

Write-Host "TransferSpawn: $Mission -> $($points.Count) $src points, gen $Gen -> $outPath"
if (-not $Fix) {
    Write-Host "Report only. Re-run with -Fix to write." -ForegroundColor Yellow
    return
}

# Compact, stable JSON: { "gen": N, "points": [ {"x":..,"z":..}, … ] }. Hand-built so the
# shape matches the mod's TS_Config exactly regardless of the PS version's ConvertTo-Json quirks.
$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append('{"gen":').Append($Gen).Append(',"points":[')
for ($i = 0; $i -lt $points.Count; $i++) {
    if ($i -gt 0) { [void]$sb.Append(',') }
    [void]$sb.Append('{"x":').Append($points[$i].x.ToString($ci)).Append(',"z":').Append($points[$i].z.ToString($ci)).Append('}')
}
[void]$sb.Append(']}')

New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
Set-Content -Path $outPath -Value $sb.ToString() -NoNewline -Encoding utf8
Write-Host "TransferSpawn: wrote $outPath"
