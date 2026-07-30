#requires -Version 7
<#
.SYNOPSIS
  TDD test for Apply-ConfigOverrides multi-match XPath (the SelectSingleNode -> SelectNodes
  fix, CONFIG-ARCHITECTURE.md Phase 3: the kept patch niche gets its engine completed).

  Written BEFORE the fix: the multi-match assertions must FAIL first (only the first node
  patched), then pass. Runs the REAL script against a throwaway ServerDir - no box, no sudo.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$apply = Join-Path $here '../Apply-ConfigOverrides.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) "apply-mm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path (Join-Path $work 'db') | Out-Null

@'
<events>
    <event name="VehicleA"><lifetime>300</lifetime><active>1</active></event>
    <event name="VehicleB"><lifetime>600</lifetime><active>1</active></event>
    <event name="AnimalC"><lifetime>900</lifetime><active>1</active></event>
</events>
'@ | Set-Content (Join-Path $work 'db/events.xml')

@'
{
  "files": {
    "db/events.xml": {
      "//event[starts-with(@name,'Vehicle')]/lifetime": 3888000,
      "//event[@name='AnimalC']/active": 0
    }
  }
}
'@ | Set-Content (Join-Path $work 'manifest.json')

$null = & $apply -ServerDir $work -Manifest (Join-Path $work 'manifest.json') -Fix 6>&1
[xml]$doc = Get-Content -Raw (Join-Path $work 'db/events.xml')
$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  [FAIL] $what" -ForegroundColor Red }
}
$a = $doc.SelectSingleNode("//event[@name='VehicleA']/lifetime").InnerText
$b = $doc.SelectSingleNode("//event[@name='VehicleB']/lifetime").InnerText
$c = $doc.SelectSingleNode("//event[@name='AnimalC']/lifetime").InnerText
$act = $doc.SelectSingleNode("//event[@name='AnimalC']/active").InnerText
Check ($a -eq '3888000') "multi-match: FIRST matched node patched (VehicleA=$a)"
Check ($b -eq '3888000') "multi-match: EVERY matched node patched (VehicleB=$b, want 3888000)"
Check ($c -eq '900')     "multi-match: non-matching node untouched (AnimalC lifetime=$c)"
Check ($act -eq '0')     "single-match selector still exact (AnimalC active=$act)"

Remove-Item -Recurse -Force $work
Write-Host "`napply-overrides-multimatch: $pass passed, $fail failed"
exit ($fail -gt 0 ? 1 : 0)
