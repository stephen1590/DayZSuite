#requires -Version 7
<#
.SYNOPSIS
  TDD test for Capture-OwnedDefaults.ps1. Written BEFORE the script exists - first run must
  FAIL (script missing).

  THE GAP IT CLOSES (found 2026-07-31): the two-copy model says an OWNED file keeps a frozen
  `default` beside its `live` copy, and the own-editor diffs them. Nothing captured that first
  copy for most owned files, so the editor showed "no frozen default captured, plain edit" with
  nothing to compare against. Six of the eight newly-declared mission surfaces were like that.

  UPDATED 2026-07-31 (engine deletion): this script is now the SOLE writer of a defaults
  companion. It used to share the job with Apply-ConfigOverrides and had to skip that engine's
  files; the engine is deleted, so the skip is deleted with it and every owned row is captured
  by one rule. A file that used to be patched is now an owned file like any other.

  Contract:
   - report-only by default; -Fix writes (project rule: modifications need an explicit flag)
   - for every registry row with category 'owned' AND a 'box' path, capture live -> default
   - SEED-IF-MISSING ONLY: an existing default is NEVER overwritten (it is the frozen
     reference; re-capturing from live would silently erase the very delta being compared)
   - ONE rule for every owned row: no second writer, so no per-file exemption
   - never invent a default for a file that is not on disk
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tool = Join-Path $here '../Capture-OwnedDefaults.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) "cod-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path (Join-Path $work 'mpmissions/dayzOffline.sakhal/db') | Out-Null
$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  [FAIL] $what" -ForegroundColor Red }
}
$M = 'mpmissions/dayzOffline.sakhal'

# --- fixture live files -------------------------------------------------------------------
'<weather><x>1</x></weather>'      | Set-Content (Join-Path $work "$M/cfgweather.xml")
'<types><type name="A"/></types>'  | Set-Content (Join-Path $work "$M/db/types.xml")
'<spawn><a/></spawn>'              | Set-Content (Join-Path $work "$M/cfgplayerspawnpoints.xml")
'<eco><old/></eco>'                | Set-Content (Join-Path $work "$M/cfgeconomycore.xml")
# an ALREADY-CAPTURED default that must not be clobbered
'<eco><PRISTINE/></eco>'           | Set-Content (Join-Path $work "$M/cfgeconomycore.defaults.xml")

# --- fixture registry: 4 owned rows + 1 reference row (reference must be skipped) ----------
@{
    surfaces = @(
        @{ name = 'weather';   box = "$M/cfgweather.xml";           category = 'owned';     web = 'file' }
        @{ name = 'types';     box = "$M/db/types.xml";             category = 'owned';     web = 'file' }
        @{ name = 'spawnPts';  box = "$M/cfgplayerspawnpoints.xml"; category = 'owned';     web = 'file' }
        @{ name = 'ceCore';    box = "$M/cfgeconomycore.xml";       category = 'owned';     web = 'file' }
        @{ name = 'proto';     box = "$M/mapgroupproto.xml";        category = 'reference'; web = 'view' }
        @{ name = 'absent';    box = "$M/notondisk.xml";            category = 'owned';     web = 'file' }
    )
} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $work 'config-registry.json')

$common = @{ ServerDir = $work; Registry = (Join-Path $work 'config-registry.json') }

# 1. REPORT mode writes nothing
$out = & $tool @common 6>&1 | Out-String
Check ($LASTEXITCODE -eq 0) "report: exits 0"
Check (-not (Test-Path (Join-Path $work "$M/cfgweather.defaults.xml"))) "report: writes NOTHING (no default created)"
Check ($out -match 'cfgweather') "report: names the file it would capture"

# 2. -Fix captures the untouched owned files
$null = & $tool @common -Fix 6>&1
Check (Test-Path (Join-Path $work "$M/cfgweather.defaults.xml"))          "fix: captured cfgweather.defaults.xml"
Check (Test-Path (Join-Path $work "$M/cfgplayerspawnpoints.defaults.xml")) "fix: captured cfgplayerspawnpoints.defaults.xml"
Check ((Get-Content -Raw (Join-Path $work "$M/cfgweather.defaults.xml")).Trim() -eq '<weather><x>1</x></weather>') "fix: default is a byte copy of live"

# 3. an EXISTING default is never overwritten
Check ((Get-Content -Raw (Join-Path $work "$M/cfgeconomycore.defaults.xml")) -match 'PRISTINE') "fix: existing default NOT clobbered (seed-if-missing)"

# 4. a file that used to be an override target is now captured like any other owned row.
# This assertion is INVERTED from its original form on purpose: it used to prove the skip
# existed. With one writer there is no skip, and a formerly-patched file must get a default.
Check (Test-Path (Join-Path $work "$M/db/types.defaults.xml")) "fix: captures db/types.xml - no override exemption any more"

# 5. category 'reference' is not captured, and a missing file is not invented
Check (-not (Test-Path (Join-Path $work "$M/mapgroupproto.defaults.xml"))) "fix: skips category 'reference'"
Check (-not (Test-Path (Join-Path $work "$M/notondisk.defaults.xml")))     "fix: never invents a default for an absent file"

# 6. re-running is a clean no-op
$out2 = & $tool @common -Fix 6>&1 | Out-String
Check ($LASTEXITCODE -eq 0 -and (Get-Content -Raw (Join-Path $work "$M/cfgweather.defaults.xml")).Trim() -eq '<weather><x>1</x></weather>') "fix: idempotent - second run changes nothing"

Remove-Item -Recurse -Force $work
Write-Host "`ncapture-owned-defaults: $pass passed, $fail failed"
exit ($fail -gt 0 ? 1 : 0)
