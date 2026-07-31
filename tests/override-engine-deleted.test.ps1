#requires -Version 7
<#
  override-engine-deleted.test.ps1

  The owner's ruling, 2026-07-31: "No Overrides. Just whole file ownership and modifying with a
  better UI/Syntax manager."  A migration is DONE when the replaced mechanism is DELETED - an
  abstraction that leaves the old path alive is two mechanisms, not one.

  WRITTEN BEFORE THE DELETION, so it must FAIL on first run. It is the gate that keeps the
  engine from coming back: every piece below has to be absent, in every tier at once. A partial
  removal (UI gone, verbs still there) fails just as loudly as no removal.

  NOT covered here and deliberately so: whether PROD's live files already carry the 12
  server-settings.json values. That is a live-box question, it cannot be answered offline, and
  it gates the PROD deploy - not this repo state.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent

$script:tests = 0; $script:fails = 0
function Assert([string]$name, [bool]$cond, [string]$why = '') {
    $script:tests++
    if ($cond) { Write-Host "  ok: $name" }
    else { $script:fails++; Write-Host "FAIL: $name"; if ($why) { Write-Host "      $why" } }
}
function NoFile([string]$rel) { -not (Test-Path (Join-Path $root $rel)) }
function Grep([string]$rel, [string]$pattern) {
    $p = Join-Path $root $rel
    if (-not (Test-Path $p)) { return $false }
    (Select-String -Path $p -Pattern $pattern -SimpleMatch -Quiet) -eq $true
}

# --- 1. the box engine is gone -----------------------------------------------
Assert 'Apply-ConfigOverrides.ps1 is deleted'   (NoFile 'DayZ-Server/Apply-ConfigOverrides.ps1')
Assert 'config-overrides.json is deleted'       (NoFile 'DayZ-Server/config-overrides.json')
Assert 'Sync-ConfigOverrides.ps1 is deleted'    (NoFile 'DayZ-Server/Sync-ConfigOverrides.ps1')
Assert 'prestart.sh no longer runs the applier' (-not (Grep 'DayZ-Server/deploy/prestart.sh' 'Apply-ConfigOverrides'))
Assert 'the deploy no longer ships the applier' (-not (Grep 'DayZ-Server/Deploy-DayZServer.ps1' 'Apply-ConfigOverrides.ps1'))

# --- 2. the control-plane verbs are gone -------------------------------------
foreach ($verb in 'override-read', 'override-write', 'override-versions', 'override-rollback') {
    Assert "dayz-ctl verb '$verb' is gone" (-not (Grep 'Api/deploy/templates/dayz-ctl.template' "  ${verb})"))
}

# --- 3. the API surface is gone ----------------------------------------------
Assert 'override-diff.ts is deleted'     (NoFile 'Api/app/src/override-diff.ts')
Assert 'override-diff-xml.ts is deleted' (NoFile 'Api/app/src/override-diff-xml.ts')
foreach ($action in "'configs/overrides'", "'configs/set-overrides'", "'configs/override-versions'",
                    "'configs/override-rollback'", "'configs/preview-override'", "'configs/target'") {
    Assert "API action $action is gone" (-not (Grep 'Api/app/src/actions.ts' "    ${action}:"))
}

# --- 4. the browser editor is gone -------------------------------------------
Assert 'override-status.js is deleted' (NoFile 'ConfigViewer/web/js/override-status.js')
foreach ($sym in 'effectivePatches', 'layerMapRW', 'saveOverrides', 'overrideContextHtml', 'ovrLayerSel') {
    Assert "editor.js no longer defines '$sym'" (-not (Grep 'ConfigViewer/web/js/editor.js' $sym))
}
Assert 'no module posts to configs/set-overrides' `
    (-not (Get-ChildItem (Join-Path $root 'ConfigViewer/web/js') -Filter *.js |
           Where-Object { Select-String -Path $_.FullName -Pattern 'configs/set-overrides' -SimpleMatch -Quiet }))

# --- 5. the declaration is gone ----------------------------------------------
$reg = Get-Content -Raw (Join-Path $root 'DayZ-Server/config-registry.json') | ConvertFrom-Json
Assert "registry has no 'overrides' surface row" (-not ($reg.surfaces | Where-Object { $_.name -eq 'overrides' }))
Assert "registry has no web:'patch' row"         (-not ($reg.surfaces | Where-Object { $_.web -eq 'patch' }))
Assert 'every surface row declares a category'   (-not ($reg.surfaces | Where-Object { -not $_.category }))

# --- 6. the tests that only existed for the engine are gone ------------------
foreach ($t in 'DayZ-Server/tests/apply-overrides-multimatch.test.ps1',
               'DayZ-Server/tests/override-seed-parity.test.ps1',
               'DayZ-Server/tests/vehicle-lifetime-overrides.test.ps1',
               'ConfigViewer/tests/override-context.test.js',
               'ConfigViewer/tests/override-status.test.js') {
    Assert "retired test removed: $(Split-Path $t -Leaf)" (NoFile $t)
}

Write-Host ''
Write-Host "TESTS: $($script:tests), FAILED: $($script:fails)"
if ($script:fails) { exit 1 } else { exit 0 }
