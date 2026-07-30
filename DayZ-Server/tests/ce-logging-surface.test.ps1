#requires -Version 7
<#
.SYNOPSIS
  TDD test for exposing cfgeconomycore.xml (the CE logging toggles) as an OWNED web surface.
  Written BEFORE the registry rows exist - the first run MUST fail.

  Goal being tested (owner ask, 2026-07-30): the CE log_ce_* toggles must be editable from the
  ConfigViewer, and must NOT be an override-patch target - the overrides concept is being
  deprecated (CONFIG-ARCHITECTURE.md), so a new surface may only enter as a two-copy OWNED file.

  Contract asserted here:
   1. every mission that has a cfgeconomycore.xml has exactly ONE registry row for it
   2. that row is category:'owned' with a 'box' path and web != 'types'
      -> Deploy-Api.ps1:208 renders it into dayz-ctl's OWNED_FILES (own-read / own-write)
   3. the file is NOT in config-overrides.json
      -> editor.js:248 sets row.ownFile only when ownLayerCount(row) === 0, so this is what
         makes the UI show the whole-file own-editor instead of the override/"default view"
   4. the file is NOT in the registry 'generated' list (it is an input, not a builder artifact)
   5. check:'xml' so Confirm-LiveConfigs parse-guards it
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

$registry  = Get-Content -Raw (Join-Path $root 'config-registry.json') | ConvertFrom-Json
$overrides = Get-Content -Raw (Join-Path $root 'config-overrides.json') | ConvertFrom-Json

$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  [FAIL] $what" -ForegroundColor Red }
}

# The missions this server ships. Each has its own cfgeconomycore.xml on the box, so each
# needs its own row - the registry's established per-mission pattern (expansionTypesTuning /
# expansionTypesTuningEnoch), not one row with a wildcard.
$missions = @('dayzOffline.sakhal', 'dayzOffline.enoch', 'dayzOffline.chernarusplus')

foreach ($m in $missions) {
    $rel  = "mpmissions/$m/cfgeconomycore.xml"
    $rows = @($registry.surfaces | Where-Object { $_.box -eq $rel })

    Check ($rows.Count -eq 1) "$m : exactly one registry row for cfgeconomycore.xml (found $($rows.Count))"
    if ($rows.Count -ne 1) { continue }
    $row = $rows[0]

    Check ($row.category -eq 'owned')      "$m : category is 'owned' (got '$($row.category)')"
    Check ($row.web -ne 'types')           "$m : web is not 'types' - Deploy-Api excludes types rows from OWNED_FILES (got '$($row.web)')"
    Check ($row.web -ne 'patch')           "$m : web is not 'patch' - must not be an override editor row (got '$($row.web)')"
    Check ($row.check -eq 'xml')           "$m : check is 'xml' so Confirm-LiveConfigs parse-guards it (got '$($row.check)')"
    Check ($row.scope -eq "map:$m")        "$m : scope is 'map:$m' (got '$($row.scope)')"

    # Deploy-Api.ps1:208 predicate: category -eq 'owned' -and $_.box -and $_.web -ne 'types'
    $inOwnedFiles = ($row.category -eq 'owned' -and $row.box -and $row.web -ne 'types')
    Check $inOwnedFiles "$m : satisfies the Deploy-Api OWNED_FILES predicate (own-read/own-write allowed)"

    # 3. must NOT carry an override layer - this is the 'not the default view' guarantee
    $layered = $false
    foreach ($p in $overrides.PSObject.Properties) {
        $v = $p.Value
        if ($null -eq $v) { continue }
        if ($v.PSObject.Properties.Name -contains $rel) { $layered = $true }
        foreach ($sub in $v.PSObject.Properties) {
            if ($sub.Value -and ($sub.Value.PSObject.Properties.Name -contains $rel)) { $layered = $true }
        }
    }
    Check (-not $layered) "$m : cfgeconomycore.xml has NO override layer - editor.js renders the own-editor, not the override view"

    # 4. not a builder artifact
    Check (@($registry.generated) -notcontains $rel) "$m : not listed in registry 'generated' (it is an input, not an artifact)"
}

Write-Host "`nce-logging-surface: $pass passed, $fail failed"
exit ($fail -gt 0 ? 1 : 0)
