#requires -Version 7
<#
  server-settings-surface.test.ps1 - the server-settings surface contract, across all three tiers.

  Owner, verbatim: "We are getting rid of the fields view,
  remember? Use the JSON/XML editor. The server-settings compiles (not explicit write) on
  a save to create our OWNED file... It's a driver for the settings."

  server-settings.json is a 2.2 GENERATOR INPUT: the driver. serverDZ.cfg is the generated
  owned output and Apply-ServerCfg is the compiler (its allowlist is closed and enforced at
  RENDER time, so no editor can widen it). The file is therefore edited like every other
  owned surface - the JSON editor - and saved whole through own-write.

  THE ORDERING THIS TEST PROTECTS: own-write refuses any path outside the box's rendered
  OWNED_FILES. If ConfigViewer stops forcing the Fields view while the Api still excludes
  the file, its save path silently becomes the override engine's whole-file flow (the very
  thing A3 deletes) or nothing at all. So the Api-side inclusion and the UI-side removal
  are asserted TOGETHER - neither may land alone.

  Lives in the repo-root tests/ because it spans registry + Api + ConfigViewer, same as
  mechanism-counts.test.ps1.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here

$script:tests = 0; $script:fails = 0
function Assert([string]$name, [bool]$cond, [string]$why = '') {
    $script:tests++
    if ($cond) { Write-Host "  ok: $name" }
    else { $script:fails++; Write-Host "FAIL: $name"; if ($why) { Write-Host "      $why" } }
}

$registry = Get-Content -Raw (Join-Path $repo 'DayZ-Server/config-registry.json') | ConvertFrom-Json
$deployApi = Get-Content -Raw (Join-Path $repo 'Api/deploy/Deploy-Api.ps1')
$editorJs = Get-Content -Raw (Join-Path $repo 'ConfigViewer/web/js/editor.js')

$row = $registry.surfaces | Where-Object { $_.box -eq 'server-settings.json' } | Select-Object -First 1
Assert 'registry has the server-settings.json surface' ($null -ne $row)

# --- 1. classification: an INPUT (driver), edited as a whole file --------------
Assert "category stays 'input' (a renderer input, not a game-read file) - got '$($row.category)'" `
    ($row.category -eq 'input') `
    "the owner's 2.2 category. 'owned' would be wrong - the game never reads this file."
Assert "web is 'file' (the JSON editor), NOT 'patch' - got '$($row.web)'" `
    ($row.web -eq 'file') `
    "'patch' renders the override delta UI, which dies with the engine (A3)."

# --- 2. blast radius: widening OWNED_FILES to 'input' exposes ONLY this --------
$inputRows = @($registry.surfaces | Where-Object { $_.category -eq 'input' })
Assert "exactly ONE category:'input' row exists (got $($inputRows.Count))" ($inputRows.Count -eq 1) `
    "OWNED_FILES now includes 'input'. A second input row would silently become whole-file writable - classify it deliberately first."

# --- 3. Api side: the owned-surface mask must include 'input' ------------------
Assert "Deploy-Api's owned-surface mask includes category 'input'" `
    ($deployApi -match "category\s+-in\s+@\('owned',\s*'input'\)") `
    "own-write refuses paths outside OWNED_FILES, so without this the UI change below leaves server-settings.json with NO save path."

# --- 4. UI side: the Fields view is gone for this row -------------------------
Assert 'editor.js no longer forces the Fields view for server-settings' `
    ($editorJs -notmatch "isCycleRow\(row\)\s*\?\s*'fields'") `
    "the Fields view renders the override delta - retired by E1/E5."
Assert 'editor.js has no Fields-view fallback left for the cycle row' `
    ($editorJs -notmatch "isCycleRow\(row\)\s*\?\s*cycleHtml") `
    "the cycle panel must render as context in the owned editor, not inside the retired Fields view."

# --- 5. ...but the cycle CONTEXT survives (not silently dropped) ---------------
Assert 'the day/night cycle panel is still rendered somewhere' ($editorJs -match 'cycleHtml\(') `
    "the owner values this as the form's context - losing it is a regression, not a cleanup."
Assert 'the cycle panel no longer writes override rows' `
    ($editorJs -notmatch '(?s)function wireCycle.{0,800}layerMapRW') `
    "writing a delta row is the old engine's path; the panel is read-only context now."

Write-Host ''
Write-Host "TESTS: $($script:tests), FAILED: $($script:fails)"
if ($script:fails) { exit 1 } else { exit 0 }
