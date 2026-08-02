#requires -Version 7
<#
  mechanism-counts.test.ps1 - the one-off freeze.
  Design decisions that CAN be gate assertions ARE ones - a rule in a doc gets missed:
  the mechanism counts below are pinned at their 2026-07-31 measured values as
  MAXIMUMS. They may only go DOWN (WS-U migrations delete a verb, then the pin
  here is lowered in the same change). Adding an Nth+1 write verb or a new
  box-writing UI module is a STOP-AND-SURFACE decision, never a drive-by -
  a pin only ever moves DOWN - raising one means a mechanism was added, which is the defect.

  Runs on EVERY deploy via Invoke-Tests.ps1 (T1) - including Deploy-Api, which
  Test-Configs does not gate.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here

$script:tests = 0; $script:fails = 0
function Assert([string]$name, [bool]$cond, [string]$why = '') {
    $script:tests++
    if ($cond) { Write-Host "  ok: $name" }
    else {
        $script:fails++
        Write-Host "FAIL: $name"
        if ($why) { Write-Host "      $why" }
    }
}

# --- 1. dayz-ctl write verbs: max 6 (measured 2026-07-31) --------------------
# override-write / spawn-write / file-write / types-write / own-write /
# settings-write. WS-U's target is ONE generic write path - this pin only goes
# down as U2 migrates+deletes verbs (own-write is the survivor).
$tpl = Get-Content -Raw (Join-Path $repo 'Api/deploy/templates/dayz-ctl.template')
$writeVerbs = [regex]::Matches($tpl, '(?m)^\s*([a-z][a-z-]*-write)\)') | ForEach-Object { $_.Groups[1].Value }
$MAX_WRITE_VERBS = 6
Assert "dayz-ctl write verbs <= $MAX_WRITE_VERBS (found $($writeVerbs.Count): $($writeVerbs -join ', '))" `
    ($writeVerbs.Count -le $MAX_WRITE_VERBS) `
    "A NEW write verb breaks the one-write-path rule. Use the generic own-write path, or STOP and surface the gap."

# --- 2. box-writing UI modules: the exact set, no additions ------------------
# Every file under web/js that calls apiPost (the ONE write transport). A new
# module gaining write access is a design decision, not a side effect.
$allowedWriters = @(
    'api-client.js'    # defines apiPost - the ONE transport
    'editor.js'        # overrides doc + owned-file chrome (god-file, B4 splits it)
    'own-editor.js'    # whole-file editor (CM6 + JSON navigator)
    'types-editor.js'  # types tuning editor
    'map.js'           # map editor (patrols, LBC, waypoints)
    'maintenance.js'   # server actions (restart, mods, messages)
    'logs.js'          # log actions
) | Sort-Object
$writers = Get-ChildItem (Join-Path $repo 'ConfigViewer/web/js') -Filter '*.js' |
    Where-Object { $_.Name -notlike '*.test.js' } |
    Where-Object { (Get-Content -Raw $_.FullName) -match 'apiPost\s*\(' } |
    ForEach-Object { $_.Name } | Sort-Object
$unexpected = @($writers | Where-Object { $_ -notin $allowedWriters })
Assert "box-writing UI modules = the pinned set (found $($writers.Count))" `
    ($unexpected.Count -eq 0) `
    "NEW writer(s): $($unexpected -join ', '). A module gaining box-write access is a stop-and-surface decision."

# --- 3. apiPost is defined ONCE - the transport has one owner ----------------
$defs = Get-ChildItem (Join-Path $repo 'ConfigViewer/web/js') -Filter '*.js' |
    Where-Object { (Get-Content -Raw $_.FullName) -match '(?m)^\s*(export\s+)?(async\s+)?function\s+apiPost\b' } |
    ForEach-Object { $_.Name }
Assert "apiPost defined exactly once (in $($defs -join ', '))" `
    (@($defs).Count -eq 1 -and @($defs)[0] -eq 'api-client.js') `
    "A second write transport is a parallel mechanism - the design contract forbids it."

Write-Host ''
Write-Host "TESTS: $($script:tests), FAILED: $($script:fails)"
if ($script:fails) { exit 1 } else { exit 0 }
