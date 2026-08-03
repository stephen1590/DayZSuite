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

# --- 1. dayz-ctl *-write verbs: the EXACT set ---------------------------------
# Was a `<= 6` ceiling. That shape failed on 2026-07-31: A3 deleted override-write
# seven hours after the pin was written, the real count fell to 5, and a ceiling
# cannot notice a mechanism LEAVING - so the pin never came down and the gate
# would have waved a replacement through as "no change". An exact set fails in
# BOTH directions: a new verb, and a retirement that forgets to lower the pin.
$tpl = Get-Content -Raw (Join-Path $repo 'Api/deploy/templates/dayz-ctl.template')
$writeVerbs = @([regex]::Matches($tpl, '(?m)^\s*([a-z][a-z-]*-write)\)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
# 2026-08-02: lowered 6 -> 5. override-write left with the delta engine on 2026-07-31.
$PINNED_WRITE_VERBS = @('own-write', 'file-write', 'settings-write', 'spawn-write', 'types-write') | Sort-Object
$added   = @($writeVerbs | Where-Object { $_ -notin $PINNED_WRITE_VERBS })
$removed = @($PINNED_WRITE_VERBS | Where-Object { $_ -notin $writeVerbs })
Assert "dayz-ctl *-write verbs = the pinned set ($($writeVerbs.Count): $($writeVerbs -join ', '))" `
    ($added.Count -eq 0 -and $removed.Count -eq 0) `
    "ADDED: $($added -join ', ') | RETIRED-BUT-STILL-PINNED: $($removed -join ', '). Adding one breaks the one-write-path rule - use own-write or STOP and surface. Retiring one is the goal: lower this pin IN THE SAME CHANGE, which is the step that was missed on 2026-07-31."

# --- 1b. every verb that WRITES, not just the ones named *-write --------------
# The name-based pin above is blind by construction: it counts labels, so a verb
# that writes a file under any other name is invisible to it. Three such verbs
# already exist. This assertion reads the case BODIES instead, so a new write
# path cannot hide behind its name.
$caseStart = $tpl.IndexOf('  restart|start|stop)')
$body = if ($caseStart -ge 0) { $tpl.Substring($caseStart) } else { $tpl }
$labels = [regex]::Matches($body, '(?m)^  ([a-z][a-z0-9|_-]*)\)\s*$')
# A durable write: an atomic tmp->target replace, a redirect into an uppercase
# path variable, or removal of one. Lowercase vars ($_old) are snapshot rotation.
$writePattern = '(mv\s+-f\s+"\$tmp")|([^0-9&]>\s*"\$[A-Z_]+)|(rm\s+-f\s+"\$[A-Z_]+")'
$writers = @()
for ($i = 0; $i -lt $labels.Count; $i++) {
    $from = $labels[$i].Index + $labels[$i].Length
    $to   = if ($i + 1 -lt $labels.Count) { $labels[$i + 1].Index } else { $body.Length }
    if ($body.Substring($from, $to - $from) -match $writePattern) { $writers += $labels[$i].Groups[1].Value }
}
$writers = @($writers | Sort-Object)
# 2026-08-02: set-map / update-arm / update-disarm were invisible to the name pin.
$PINNED_WRITERS = @(
    'set-map'         # writes $SERVER_DIR/map.env
    'spawn-write', 'file-write', 'types-write', 'own-write', 'settings-write'
    'update-arm'      # writes $UPDATE_PENDING
    'update-disarm'   # removes $UPDATE_PENDING
) | Sort-Object
$wAdded   = @($writers | Where-Object { $_ -notin $PINNED_WRITERS })
$wRemoved = @($PINNED_WRITERS | Where-Object { $_ -notin $writers })
Assert "dayz-ctl verbs that write a file = the pinned set ($($writers.Count): $($writers -join ', '))" `
    ($wAdded.Count -eq 0 -and $wRemoved.Count -eq 0) `
    "ADDED: $($wAdded -join ', ') | RETIRED-BUT-STILL-PINNED: $($wRemoved -join ', '). Any verb that writes the server dir is a write path whatever it is called. Route it through own-write, or STOP and surface."

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
