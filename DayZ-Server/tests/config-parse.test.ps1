#requires -Version 7
<#
.SYNOPSIS
  The shared parse check behind every config pull/validate. Must accept a UTF-8 BOM.

  WHY (found 2026-08-01): Pull-Configs validated a pulled box file with a bare `[xml]$text`
  cast. DayZ ships several mission files WITH a UTF-8 BOM, and that cast REJECTS a string
  whose first character is U+FEFF - so the pull logged "box copy does not parse as xml" and
  silently left the repo copy stale. Measured 1:1 on prod: db/globals.xml (all three maps)
  and Sakhal db/events.xml carry a BOM and were rejected; every BOM-free file pulled.

  The failure mode is the dangerous kind - it looks like box corruption ("does not parse")
  when the box file is perfectly valid, and it fails CLOSED into "no mirror", which is the
  exact state that lost the vehicle lifetimes. Hence a shared, tested validator instead of
  an inline cast repeated per consumer.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'ConfigParse.ps1')

$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" }
    else     { $script:fail++; Write-Host "  [FAIL] $what" }
}

$BOM  = [char]0xFEFF
$xml  = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<variables><var name="a" value="1" /></variables>'
$json = '{ "a": 1 }'

# --- the regression that started this ---
Check (Test-ConfigParses ($BOM + $xml) 'xml')  'XML with a UTF-8 BOM parses (the prod regression)'
Check (Test-ConfigParses ($BOM + $json) 'json') 'JSON with a UTF-8 BOM parses'

# --- still correct for the ordinary cases ---
Check (Test-ConfigParses $xml  'xml')  'plain XML parses'
Check (Test-ConfigParses $json 'json') 'plain JSON parses'

# --- must still REJECT what it always rejected ---
Check (-not (Test-ConfigParses '<variables><var></variables>' 'xml')) 'malformed XML is rejected'
Check (-not (Test-ConfigParses '{ "a": }' 'json'))                    'malformed JSON is rejected'
Check (-not (Test-ConfigParses ''    'xml'))                          'empty content is rejected'
Check (-not (Test-ConfigParses "  `n " 'xml'))                        'whitespace-only content is rejected'
Check (-not (Test-ConfigParses $xml 'none'))                          "an undeclared check kind is rejected (never pull unvalidated)"
Check (-not (Test-ConfigParses $xml ''))                              'an empty check kind is rejected'

# --- a BOM must not be mistaken for content ---
Check (-not (Test-ConfigParses $BOM 'xml')) 'a lone BOM is not valid XML'

Write-Host "`nconfig-parse: $pass passed, $fail failed"
exit ($fail -gt 0 ? 1 : 0)
