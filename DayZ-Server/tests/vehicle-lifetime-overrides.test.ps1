#requires -Version 7
<#
.SYNOPSIS
  TDD test for the Sakhal vehicle lifetime overrides on db/types.xml.

  WRITTEN BEFORE the rows existed in the overrides doc: the -OverridesPath assertions
  must FAIL first (the live doc has no db/types.xml block at all), then pass once the
  19 rows are written through override-write.

  WHY these rows exist: db/types.xml ships vanilla lifetimes of 3 seconds on every
  drivable class (Offroad_02 ships 0). Vanilla gets away with it because vehicles are
  event-spawned and inherit the EVENT lifetime - but any vehicle that stops being an
  event instance falls back to the type lifetime and is swept in 3 seconds. These are
  genuine field tweaks on a vendor-rewritten file, i.e. the patch niche Phase 3 kept
  (CONFIG-ARCHITECTURE.md) - NOT a whole-file ownership case.

  Runs the REAL Apply-ConfigOverrides against a throwaway ServerDir. No box, no sudo.
  Self-contained by default; pass -TypesPath to run against a real 885KB types.xml.
#>
param(
    # Optional: a real db/types.xml to apply against instead of the built-in fixture.
    [string]$TypesPath = '',
    # Optional: a config-overrides doc that must ALREADY carry exactly these 19 rows.
    [string]$OverridesPath = ''
)
$ErrorActionPreference = 'Stop'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$apply = Join-Path $here '../Apply-ConfigOverrides.ps1'

# ---- SPEC: the 19 drivable classes that must persist, and the 2 deliberately held back ----
$VEHICLES = @(
    'OffroadHatchback', 'OffroadHatchback_Blue', 'OffroadHatchback_White'   # Ada 4x4
    'Hatchback_02', 'Hatchback_02_Blue'                                     # Gunter 2
    'Sedan_02', 'Sedan_02_Grey', 'Sedan_02_Red'                             # Sarka 120
    'CivilianSedan', 'CivilianSedan_Black', 'CivilianSedan_Wine'            # Olga 24
    'Truck_01_Covered', 'Truck_01_Covered_Blue', 'Truck_01_Covered_Orange'  # V3S
    'Offroad_02'                                                            # Sakhal 4x4
    'Boat_01_Black', 'Boat_01_Blue', 'Boat_01_Camo', 'Boat_01_Orange'       # boats
)
# Static loot PROPS, not drivables - held back on purpose. Raising these would make map
# scenery persist 45 days. Named here so the test fails loudly if someone adds them.
$HELD   = @('Land_Boat_Small9_DE', 'StaticObj_PatrolBoat_Military_DE')
$TARGET = '3888000'
$MISSION = 'dayzOffline.sakhal'
$REL     = 'db/types.xml'
function Sel([string]$cls) { "/types/type[@name='$cls']/lifetime" }

$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  [FAIL] $what" -ForegroundColor Red }
}

# ---- throwaway ServerDir ----
$work = Join-Path ([IO.Path]::GetTempPath()) "veh-lt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$missionDir = Join-Path $work "mpmissions/$MISSION/db"
New-Item -ItemType Directory -Force -Path $missionDir | Out-Null
$typesFile = Join-Path $missionDir 'types.xml'

if ($TypesPath -and (Test-Path $TypesPath)) {
    Copy-Item $TypesPath $typesFile
    Write-Host "fixture: REAL types.xml from $TypesPath"
} else {
    # Vanilla-shaped fixture: every vehicle at 3 (Offroad_02 at 0, as vanilla ships it),
    # the held props at 3, plus decoys that must not move.
    $sb = [Text.StringBuilder]::new()
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.AppendLine('<types>')
    foreach ($v in $VEHICLES) {
        $lt = if ($v -eq 'Offroad_02') { 0 } else { 3 }
        [void]$sb.AppendLine("    <type name=`"$v`"><nominal>0</nominal><lifetime>$lt</lifetime><min>0</min></type>")
    }
    foreach ($h in $HELD) { [void]$sb.AppendLine("    <type name=`"$h`"><nominal>0</nominal><lifetime>3</lifetime><min>0</min></type>") }
    foreach ($d in @('AKM', 'Mag_AKM_30Rnd', 'TunaCan')) {
        [void]$sb.AppendLine("    <type name=`"$d`"><nominal>10</nominal><lifetime>7200</lifetime><min>5</min></type>")
    }
    [void]$sb.AppendLine('</types>')
    Set-Content -Path $typesFile -Value $sb.ToString()
    Write-Host 'fixture: built-in synthetic types.xml'
}

# ---- 1. every selector must resolve to EXACTLY one node (catches a typo'd class name) ----
[xml]$before = Get-Content -Raw $typesFile
$ambiguous = @()
foreach ($v in $VEHICLES) {
    $n = $before.SelectNodes((Sel $v)).Count
    if ($n -ne 1) { $ambiguous += "$v matched $n" }
}
Check ($ambiguous.Count -eq 0) "all $($VEHICLES.Count) selectors resolve to exactly one node$(if($ambiguous){' - ' + ($ambiguous -join '; ')})"

$baselineHigh = ($before.SelectNodes("/types/type/lifetime") | Where-Object { $_.InnerText -eq $TARGET }).Count

# ---- build the manifest under test (mission-scoped, matching the live doc's layout) ----
$patch = [ordered]@{}
foreach ($v in $VEHICLES) { $patch[(Sel $v)] = $TARGET }
$manifest = @{ mpmissions = @{ $MISSION = @{ $REL = $patch } } }
$manifestPath = Join-Path $work 'manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath

$null = & $apply -ServerDir $work -Manifest $manifestPath -Fix 6>&1

# ---- 2..4 assertions on the patched file ----
[xml]$after = Get-Content -Raw $typesFile
$wrong = @()
foreach ($v in $VEHICLES) {
    $got = $after.SelectSingleNode((Sel $v)).InnerText
    if ($got -ne $TARGET) { $wrong += "$v=$got" }
}
Check ($wrong.Count -eq 0) "all $($VEHICLES.Count) vehicle lifetimes are $TARGET$(if($wrong){' - wrong: ' + ($wrong -join ', ')})"

$heldWrong = @()
foreach ($h in $HELD) {
    $node = $after.SelectSingleNode((Sel $h))
    if ($node -and $node.InnerText -eq $TARGET) { $heldWrong += $h }
}
Check ($heldWrong.Count -eq 0) "held-back static props untouched$(if($heldWrong){' - LEAKED: ' + ($heldWrong -join ', ')})"

$afterHigh = ($after.SelectNodes("/types/type/lifetime") | Where-Object { $_.InnerText -eq $TARGET }).Count
Check (($afterHigh - $baselineHigh) -eq $VEHICLES.Count) "exactly $($VEHICLES.Count) lifetimes changed, nothing else (delta=$($afterHigh - $baselineHigh))"

# ---- 5. the shipped doc must carry exactly these rows (the RED assertion pre-write) ----
if ($OverridesPath) {
    if (-not (Test-Path $OverridesPath)) {
        Check $false "overrides doc exists at $OverridesPath"
    } else {
        $doc = Get-Content -Raw $OverridesPath | ConvertFrom-Json -AsHashtable
        $block = $null
        if ($doc.mpmissions -and $doc.mpmissions[$MISSION]) { $block = $doc.mpmissions[$MISSION][$REL] }
        Check ($null -ne $block) "overrides doc has an mpmissions.$MISSION['$REL'] block"
        if ($block) {
            $want = @{}; foreach ($v in $VEHICLES) { $want[(Sel $v)] = $TARGET }
            $missing = @($want.Keys | Where-Object { -not $block.ContainsKey($_) })
            # Keys starting with _ are comments - the apply engine ignores them, so must we.
            $extra   = @($block.Keys | Where-Object { -not $want.ContainsKey($_) -and -not $_.StartsWith('_') })
            $badval  = @($want.Keys | Where-Object { $block.ContainsKey($_) -and "$($block[$_])" -ne $TARGET })
            Check ($missing.Count -eq 0) "no missing rows$(if($missing){' - ' + ($missing -join '; ')})"
            Check ($extra.Count   -eq 0) "no unexpected rows$(if($extra){' - ' + ($extra -join '; ')})"
            Check ($badval.Count  -eq 0) "every row value is $TARGET$(if($badval){' - ' + ($badval -join '; ')})"
            $heldRows = @($block.Keys | Where-Object { $k = $_; $HELD | Where-Object { $k -like "*'$_'*" } })
            Check ($heldRows.Count -eq 0) "doc does not patch the held-back props$(if($heldRows){' - ' + ($heldRows -join '; ')})"
        }
    }
}

Remove-Item -Recurse -Force $work
Write-Host "`nvehicle-lifetime-overrides: $pass passed, $fail failed"
exit ($fail -gt 0 ? 1 : 0)
