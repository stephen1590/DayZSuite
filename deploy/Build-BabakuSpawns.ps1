#requires -Version 7
<#
.SYNOPSIS
  Drop the active mission's SpawnerBubaku source into the ONE fixed path the mod reads.
  Run by prestart.sh before each server start.

.DESCRIPTION
  SpawnerBubaku (Bubaku) reads a single fixed file — profiles/SpawnerBubaku/SpawnerBubakuV2.json —
  but its spawn coordinates are map-specific. This composes that fixed file from the ACTIVE map's
  source (profiles/SpawnerBubaku/maps/<mission>/SpawnerBubakuV2.json) so a map switch can never
  leave the previous map's spawns in place:

    - source present and valid JSON      -> copy it to the fixed path
    - source absent, OR present-but-bad  -> write an empty-but-valid file (spawns nothing)

  The empty fallback ({ "loglevel": 0, "BubakLocations": [] }) is a valid, do-nothing config, so
  a map with no Bubaku source — or a corrupt one — never ships a broken file that could fault the
  mod. This is the one behaviour delta vs the old inline copy: a corrupt source now degrades to
  empty-valid instead of shipping the corruption.

  Report-only by default (prints what it would write). Writes only with -Fix. Fail-soft: never
  throws for a missing/bad source, so it can never block server start (prestart calls it with
  `|| true`). The same engine runs in Test-Configs.ps1 offline, so the gate proves this exact
  output before deploy.

.EXAMPLE
  ./Build-BabakuSpawns.ps1 -ServerDir . -Mission dayzOffline.sakhal
      Report which source would land at the fixed path. No changes.

.EXAMPLE
  ./Build-BabakuSpawns.ps1 -ServerDir . -Mission dayzOffline.sakhal -Fix
      Write profiles/SpawnerBubaku/SpawnerBubakuV2.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerDir,
    [string]$Mission,
    [switch]$Fix
)

$ErrorActionPreference = 'Stop'

function Show-Info($m) { Write-Host $m }
function Show-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

# Resolve the active mission the same way the engine + prestart do (map.env), unless one was passed.
if (-not $Mission) {
    $mapEnv = Join-Path $ServerDir 'map.env'
    if (Test-Path $mapEnv) {
        $m = Select-String -LiteralPath $mapEnv -Pattern '^\s*DAYZ_MISSION=(.+)$' | Select-Object -First 1
        if ($m) { $Mission = $m.Matches[0].Groups[1].Value.Trim() }
    }
    if (-not $Mission) { $Mission = 'dayzOffline.chernarusplus' }
}

$srcPath = Join-Path $ServerDir "profiles/SpawnerBubaku/maps/$Mission/SpawnerBubakuV2.json"
$outPath = Join-Path $ServerDir 'profiles/SpawnerBubaku/SpawnerBubakuV2.json'
$empty   = '{ "loglevel": 0, "BubakLocations": [] }'

# Decide the payload: the map's source if it parses, else the empty-but-valid fallback.
$payload = $null; $mode = 'empty'
if (Test-Path $srcPath) {
    $raw = Get-Content -Raw -LiteralPath $srcPath
    try { $doc = $raw | ConvertFrom-Json; $payload = $raw; $mode = 'copy'; $count = @($doc.BubakLocations).Count }
    catch { Show-Warn "Bubaku source for '$Mission' is not valid JSON ($($_.Exception.Message)) - shipping empty-valid instead." }
}
if ($mode -eq 'empty') { $payload = $empty }

if ($mode -eq 'copy') { Show-Info "Bubaku: $Mission -> $count location(s) from maps/$Mission/SpawnerBubakuV2.json -> $outPath" }
else                  { Show-Info "Bubaku: $Mission has no usable source -> empty-valid file (spawns nothing) -> $outPath" }

if (-not $Fix) {
    Show-Info "Report only. Re-run with -Fix to write."
    return
}

New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
Set-Content -Path $outPath -Value $payload -NoNewline -Encoding utf8
Show-Info "Bubaku: wrote $outPath"
