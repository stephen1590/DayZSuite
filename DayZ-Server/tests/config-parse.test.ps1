#requires -Version 7
<#
.SYNOPSIS
  The shared parse check behind every config pull/validate. Must accept a UTF-8 BOM.

  WHY: DayZ ships several mission files WITH a UTF-8 BOM, and a bare `[xml]$text` cast
  REJECTS a string whose first character is U+FEFF - so validating a pulled box file with
  that cast logs "does not parse as xml" and silently leaves the repo copy stale.

  The failure mode is the dangerous kind - it looks like box corruption ("does not parse")
  when the box file is perfectly valid, and it fails CLOSED into "no mirror". Hence a shared,
  tested validator instead of an inline cast repeated per consumer.
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

# --- 'text': the OTHER kind ---
# ban.txt / whitelist.txt / map.env are real owned surfaces that are neither JSON nor XML.
# 'text' means "readable text, not binary" - that is the only claim we can honestly make
# about a freeform file, and it is enough to refuse a truncated or binary pull.
Check (Test-ConfigParses "line one`nline two`n" 'text') 'plain text parses as text'
Check (Test-ConfigParses '7656119xxxxxxxxxx' 'text')    'a single-line text file parses'
Check (Test-ConfigParses "MAP=dayzOffline.sakhal`n" 'text') 'a key=value env file parses as text'
Check (-not (Test-ConfigParses '' 'text'))              'empty text is rejected (a truncated pull is not a valid file)'
Check (-not (Test-ConfigParses "  `n`t " 'text'))       'whitespace-only text is rejected'
Check (-not (Test-ConfigParses "bad`0binary" 'text'))   'text containing a NUL byte is rejected (that is a binary file)'
Check (Test-ConfigParses ($BOM + "hello`n") 'text')     'text with a UTF-8 BOM parses'
# 'text' must NOT become a way to smuggle malformed structured content past its own check.
Check (-not (Test-ConfigParses '<variables><var></variables>' 'xml')) "'text' does not weaken the xml check"

# --- a BOM must not be mistaken for content ---
Check (-not (Test-ConfigParses $BOM 'xml')) 'a lone BOM is not valid XML'

Write-Host "`nconfig-parse: $pass passed, $fail failed"
exit ($fail -gt 0 ? 1 : 0)
