#requires -Version 7
<#
  override-seed-parity.test.ps1 - the NO-DATA-LOSS gate for the A3 engine delete.

  WHY THIS EXISTS. Deleting the override delta engine freezes each live file as it
  stands, so the LIVE box keeps its values. A rebuilt box does not: the deploy seeds a
  missing config from its registry `seed` file, and today the overrides re-apply on top.
  Once they are gone, the seed IS the value. So any override leaf whose value differs
  from the seed is a value that silently REVERTS on a fresh/disaster-recovery box.

  Found by this test on 2026-07-31: 10 of server-settings.json's 12 leaves were exact
  no-ops, and 2 were not - serverTimeAcceleration 5 -> 8 and serverNightTimeAcceleration
  4 -> 4.5. Deleting the engine without fixing the seed would have quietly reverted the
  day/night cycle on any rebuild.

  THE RULE: every remaining override leaf must equal its seed value. Then removing the
  block is provably lossless in BOTH directions - live box (frozen) and fresh box
  (seeded) - instead of only the one we can see.

  Registry-driven: it derives seed paths from config-registry.json, so a new patched
  file is covered automatically. Written BEFORE the seed was corrected (TDD): the first
  run must FAIL on exactly those two cycle keys.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

$script:tests = 0; $script:fails = 0
function Assert([string]$name, [bool]$cond, [string]$why = '') {
    $script:tests++
    if ($cond) { Write-Host "  ok: $name" }
    else { $script:fails++; Write-Host "FAIL: $name"; if ($why) { Write-Host "      $why" } }
}

$overrides = Get-Content -Raw (Join-Path $root 'config-overrides.json') | ConvertFrom-Json -AsHashtable
$registry  = Get-Content -Raw (Join-Path $root 'config-registry.json')  | ConvertFrom-Json

# Compare the way the applier does - invariant strings, so 4.5 and "4.5" agree and an
# int/double mismatch is not a false alarm.
function AsKey($v) {
    if ($null -eq $v) { return '<null>' }
    if ($v -is [bool]) { return ([bool]$v) ? 'true' : 'false' }
    [string]::Format([cultureinfo]::InvariantCulture, '{0}', $v)
}

$filesLayer = if ($overrides.files) { $overrides.files } else { @{} }
$checked = 0

foreach ($rel in @($filesLayer.Keys | Where-Object { -not $_.StartsWith('_') })) {
    $row = $registry.surfaces | Where-Object { $_.box -eq $rel } | Select-Object -First 1
    Assert "registry declares a surface for the patched file '$rel'" ($null -ne $row) `
        "an override patches a file the registry does not know - the seed cannot be found, so loss cannot be ruled out"
    if (-not $row) { continue }

    Assert "'$rel' declares a seed (needed to survive a box rebuild)" ([bool]$row.seed) `
        "no seed: a fresh box gets no copy of this file at all, so its overridden values are lost outright"
    if (-not $row.seed) { continue }

    $seedPath = Join-Path $root $row.seed
    Assert "seed file exists: $($row.seed)" (Test-Path $seedPath)
    if (-not (Test-Path $seedPath)) { continue }

    $seed = Get-Content -Raw $seedPath | ConvertFrom-Json -AsHashtable
    foreach ($key in @($filesLayer[$rel].Keys | Where-Object { -not $_.StartsWith('_') })) {
        $checked++
        $want = AsKey $filesLayer[$rel][$key]
        $have = if ($seed.ContainsKey($key)) { AsKey $seed[$key] } else { '<ABSENT>' }
        Assert "$rel : '$key' seed matches the override ($have)" ($have -eq $want) `
            "seed='$have' override='$want' - after the engine delete a REBUILT box would use '$have', silently reverting this setting. Fix the seed to '$want' (the value actually in service), then the override row is a provable no-op and can be removed."
    }
}

Assert 'at least one override leaf was checked (test is not vacuous)' ($checked -gt 0) `
    'no leaves left in the files layer - if the engine is already gone, retire this test with it'

Write-Host ''
Write-Host "override-seed parity: $checked leaf/leaves checked"
Write-Host "TESTS: $($script:tests), FAILED: $($script:fails)"
if ($script:fails) { exit 1 } else { exit 0 }
