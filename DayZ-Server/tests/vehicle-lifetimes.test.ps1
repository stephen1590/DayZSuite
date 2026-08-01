#requires -Version 7
<#
.SYNOPSIS
  The 19 Sakhal drivable classes must hold lifetime 3888000 in db/types.xml.

  WHY THIS EXISTS (read before changing it): vanilla ships every drivable class at
  lifetime=3 (Offroad_02 at 0). Vanilla survives that because vehicles are event-spawned
  and inherit the EVENT lifetime - but the moment a vehicle stops being an event instance
  it falls back to the TYPE lifetime and is swept in three seconds.

  This replaces tests/vehicle-lifetime-overrides.test.ps1, which asserted the same values
  through the config-overrides engine. That engine is deleted (owner ruling 2026-07-31:
  "No Overrides. Just whole file ownership"), and db/types.xml is an OWNED whole file -
  so the guarantee now belongs on the FILE, not on a patch manifest.

  It also exists because the old test PASSED GREEN while the values were absent from prod:
  with no -OverridesPath it only exercised the applier against a synthetic fixture and
  never looked at a real types.xml. That vacuity is why the values were silently lost on
  2026-07-31. Hence the self-check below: this test proves it can FAIL before it is
  allowed to claim a pass.

.PARAMETER TypesPath
  The db/types.xml to assert against. DEFAULTS to the repo's mirror of the live prod file
  (registry row typesSakhal, mirror:'live' -> its seed path), so the shared runner asserts
  the REAL values on every run, not just the checker.

  That default is the whole point. The predecessor test took no such path and quietly
  checked a synthetic fixture, so it stayed green while the values were absent from prod -
  which is how they were lost. Until 2026-08-01 no repo copy existed to point at; the
  seed/mirror wiring created one. If the mirror ever disappears, this test FAILS rather
  than silently degrading to "checker works".
#>
param(
    [string]$TypesPath = "$PSScriptRoot/../deploy/mpmissions/dayzOffline.sakhal/db/types.xml",
    # The frozen <stem>.defaults.<ext> companion. Given both, the test proves the ONLY
    # lifetime values that changed are the 19 - the "nothing rode along" guarantee. An
    # absolute count cannot do this: 22 vanilla player-built persistence types (tents,
    # barrels, watchtowers, crates, sea chests) already sit at 3888000 legitimately.
    [string]$BaselinePath = "$PSScriptRoot/../config-defaults/mpmissions/dayzOffline.sakhal/db/types.defaults.xml"
)
$ErrorActionPreference = 'Stop'

# ---- SPEC ----
$VEHICLES = @(
    'OffroadHatchback', 'OffroadHatchback_Blue', 'OffroadHatchback_White'   # Ada 4x4
    'Hatchback_02', 'Hatchback_02_Blue'                                     # Gunter 2
    'Sedan_02', 'Sedan_02_Grey', 'Sedan_02_Red'                             # Sarka 120
    'CivilianSedan', 'CivilianSedan_Black', 'CivilianSedan_Wine'            # Olga 24
    'Truck_01_Covered', 'Truck_01_Covered_Blue', 'Truck_01_Covered_Orange'  # V3S
    'Offroad_02'                                                            # Sakhal 4x4
    'Boat_01_Black', 'Boat_01_Blue', 'Boat_01_Camo', 'Boat_01_Orange'       # boats
)
# Static map SCENERY, not drivables. Raising these would make wrecks persist 45 days.
# Named so the test fails loudly if someone sweeps them in with the vehicles.
$HELD   = @('Land_Boat_Small9_DE', 'StaticObj_PatrolBoat_Military_DE')
$TARGET = '3888000'   # 45 days

$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" }
    else     { $script:fail++; Write-Host "  [FAIL] $what" }
}

# ---- the checker under test: returns the list of problems with a types.xml ----
function Get-LifetimeProblems([string]$path) {
    $problems = @()
    [xml]$doc = Get-Content -Raw -LiteralPath $path
    foreach ($cls in $VEHICLES) {
        $nodes = $doc.SelectNodes("/types/type[@name='$cls']/lifetime")
        if ($nodes.Count -ne 1) { $problems += "$cls matched $($nodes.Count) lifetime nodes (want exactly 1)"; continue }
        if ($nodes[0].InnerText -ne $TARGET) { $problems += "$cls lifetime is $($nodes[0].InnerText), want $TARGET" }
    }
    foreach ($h in $HELD) {
        $n = $doc.SelectSingleNode("/types/type[@name='$h']/lifetime")
        if ($n -and $n.InnerText -eq $TARGET) { $problems += "HELD-BACK prop $h was raised to $TARGET" }
    }
    return , $problems
}

# Every class -> its lifetime. Used to prove nothing but the 19 moved.
function Get-LifetimeMap([string]$path) {
    [xml]$doc = Get-Content -Raw -LiteralPath $path
    $m = @{}
    foreach ($t in $doc.SelectNodes('/types/type')) {
        $lt = $t.SelectSingleNode('lifetime')
        if ($lt) { $m[$t.GetAttribute('name')] = $lt.InnerText }
    }
    return $m
}

# ---- NON-VACUITY: the checker must reject a file that is wrong ----
$tmp = Join-Path ([IO.Path]::GetTempPath()) "vl-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $mk = {
        param($lifetimes, $heldLifetime)
        $sb = [Text.StringBuilder]::new()
        [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
        [void]$sb.AppendLine('<types>')
        foreach ($v in $VEHICLES) { [void]$sb.AppendLine("  <type name=`"$v`"><nominal>0</nominal><lifetime>$($lifetimes[$v])</lifetime></type>") }
        foreach ($h in $HELD)     { [void]$sb.AppendLine("  <type name=`"$h`"><nominal>0</nominal><lifetime>$heldLifetime</lifetime></type>") }
        [void]$sb.AppendLine('  <type name="AKM"><nominal>10</nominal><lifetime>7200</lifetime></type>')
        [void]$sb.AppendLine('</types>')
        $sb.ToString()
    }
    $good = @{}; foreach ($v in $VEHICLES) { $good[$v] = $TARGET }
    $goodPath = Join-Path $tmp 'good.xml'; Set-Content -LiteralPath $goodPath -Value (& $mk $good 3)
    Check ((Get-LifetimeProblems $goodPath).Count -eq 0) 'self-check: a correct file reports no problems'

    $vanilla = @{}; foreach ($v in $VEHICLES) { $vanilla[$v] = 3 }
    $badPath = Join-Path $tmp 'vanilla.xml'; Set-Content -LiteralPath $badPath -Value (& $mk $vanilla 3)
    Check ((Get-LifetimeProblems $badPath).Count -ge $VEHICLES.Count) 'self-check: an UNPATCHED file is rejected (this is the case that shipped to prod)'

    $one = $good.Clone(); $one['Offroad_02'] = 3
    $onePath = Join-Path $tmp 'one.xml'; Set-Content -LiteralPath $onePath -Value (& $mk $one 3)
    $oneProbs = Get-LifetimeProblems $onePath
    Check (($oneProbs.Count -eq 1) -and ($oneProbs[0] -like 'Offroad_02*')) 'self-check: ONE wrong class is caught, and named'

    $leak = Join-Path $tmp 'leak.xml'; Set-Content -LiteralPath $leak -Value (& $mk $good $TARGET)
    Check ((Get-LifetimeProblems $leak).Count -ge 1) 'self-check: raising a held-back static prop is caught'
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

# ---- THE REAL ASSERTION ----
if ($TypesPath) {
    if (-not (Test-Path -LiteralPath $TypesPath)) {
        Check $false "types.xml exists at $TypesPath"
    } else {
        $probs = Get-LifetimeProblems $TypesPath
        foreach ($p in $probs) { Write-Host "         $p" }
        Check ($probs.Count -eq 0) "REAL FILE: all $($VEHICLES.Count) drivable lifetimes are $TARGET in $TypesPath"

        if ($BaselinePath -and (Test-Path -LiteralPath $BaselinePath)) {
            $now = Get-LifetimeMap $TypesPath
            $was = Get-LifetimeMap $BaselinePath
            $moved = @($now.Keys | Where-Object { $was.ContainsKey($_) -and $was[$_] -ne $now[$_] })
            $addedOrGone = @(($now.Keys + $was.Keys | Sort-Object -Unique) | Where-Object { -not ($now.ContainsKey($_) -and $was.ContainsKey($_)) })
            $unexpected = @($moved | Where-Object { $_ -notin $VEHICLES })
            foreach ($u in $unexpected) { Write-Host "         UNEXPECTED lifetime change: $u  $($was[$u]) -> $($now[$u])" }
            Check ($unexpected.Count -eq 0) "vs baseline: no lifetime moved except the $($VEHICLES.Count) drivables"
            Check ($moved.Count -eq $VEHICLES.Count) "vs baseline: exactly $($VEHICLES.Count) lifetimes changed (got $($moved.Count))"
            Check ($addedOrGone.Count -eq 0) "vs baseline: no type added or removed (got $($addedOrGone.Count))"
        }
    }
} else {
    Write-Host '  [note] no -TypesPath given: checker verified, NO real types.xml was asserted.'
}

Write-Host "`nvehicle-lifetimes: $pass passed, $fail failed"
exit ($fail -gt 0 ? 1 : 0)
