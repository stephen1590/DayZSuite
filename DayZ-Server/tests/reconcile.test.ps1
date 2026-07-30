#requires -Version 7
<#
.SYNOPSIS
  TDD test for Reconcile-Defaults.ps1 (CONFIG-ARCHITECTURE.md Phase 4: reconcile-on-update).
  Written BEFORE the implementation - first run must fail (script missing).

  Contract under test: 3-way merge of old-default vs new-default vs live via git merge-file
  (recorded decision - no hand-rolled merger). Report-only by default; -Fix writes the merged
  live file + adopts the new default as the frozen baseline. Conflicts NEVER auto-write.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tool = Join-Path $here '../Reconcile-Defaults.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) "rec-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  [FAIL] $what" -ForegroundColor Red }
}

# Fixture: OLD default; LIVE = admin changed maxPlayers; NEW default = vendor added a key.
# NOTE: the two sides change WELL-SEPARATED lines - adjacent-line changes on both sides
# are a real conflict under diff3 semantics (verified while writing this test), not a clean merge.
@'
{
  "maxPlayers": 60,
  "a": 1,
  "b": 2,
  "c": 3,
  "d": 4,
  "newFeature": 0
}
'@ | Set-Content (Join-Path $work 'old.json')
@'
{
  "maxPlayers": 42,
  "a": 1,
  "b": 2,
  "c": 3,
  "d": 4,
  "newFeature": 0
}
'@ | Set-Content (Join-Path $work 'live.json')
@'
{
  "maxPlayers": 60,
  "a": 1,
  "b": 2,
  "c": 3,
  "d": 4,
  "newFeature": 1
}
'@ | Set-Content (Join-Path $work 'new.json')

# 1. REPORT mode: clean 3-way merge detected, NOTHING written
$out = & $tool -OldDefault (Join-Path $work 'old.json') -NewDefault (Join-Path $work 'new.json') -Live (Join-Path $work 'live.json') 6>&1 | Out-String
Check ($LASTEXITCODE -eq 0 -and $out -match 'CLEAN') "report: clean merge detected (exit 0, says CLEAN)"
Check ((Get-Content -Raw (Join-Path $work 'live.json')) -match '"maxPlayers": 42') "report: live file untouched"

# 2. -Fix on the clean case: live keeps the admin edit AND gains the vendor key; old default adopted
$null = & $tool -OldDefault (Join-Path $work 'old.json') -NewDefault (Join-Path $work 'new.json') -Live (Join-Path $work 'live.json') -Fix 6>&1
$merged = Get-Content -Raw (Join-Path $work 'live.json')
Check ($merged -match '"maxPlayers": 42' -and $merged -match '"newFeature": 1') "fix: merged live keeps admin edit + vendor change"
Check ((Get-Content -Raw (Join-Path $work 'old.json')) -match '"newFeature": 1') "fix: new default adopted as the frozen baseline"

# 3. CONFLICT: same line changed on both sides -> report nonzero, -Fix REFUSES to write
@'
{
  "maxPlayers": 60
}
'@ | Set-Content (Join-Path $work 'old2.json')
@'
{
  "maxPlayers": 42
}
'@ | Set-Content (Join-Path $work 'live2.json')
@'
{
  "maxPlayers": 100
}
'@ | Set-Content (Join-Path $work 'new2.json')
$out = & $tool -OldDefault (Join-Path $work 'old2.json') -NewDefault (Join-Path $work 'new2.json') -Live (Join-Path $work 'live2.json') 6>&1 | Out-String
Check ($LASTEXITCODE -ne 0 -and $out -match 'CONFLICT') "conflict: reported (nonzero exit, says CONFLICT)"
$null = & $tool -OldDefault (Join-Path $work 'old2.json') -NewDefault (Join-Path $work 'new2.json') -Live (Join-Path $work 'live2.json') -Fix 6>&1
Check ($LASTEXITCODE -ne 0 -and (Get-Content -Raw (Join-Path $work 'live2.json')) -match '"maxPlayers": 42') "conflict: -Fix refuses - live untouched, human decides"
$conflictCopy = Get-ChildItem (Join-Path $work 'reconcile-conflicts') -ErrorAction SilentlyContinue
Check ($null -ne $conflictCopy -and (Get-Content -Raw $conflictCopy[0].FullName) -match '<<<<<<<') "conflict: marked-up copy written to reconcile-conflicts/ subdir for review"

Remove-Item -Recurse -Force $work
Write-Host "`nreconcile: $pass passed, $fail failed"
exit ($fail -gt 0 ? 1 : 0)
