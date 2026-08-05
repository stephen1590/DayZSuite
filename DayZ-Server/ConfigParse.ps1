#requires -Version 7
<#
.SYNOPSIS
  THE parse check for config content, shared by every consumer that validates a box file.

.DESCRIPTION
  Dot-source this; it defines Test-ConfigParses and nothing else (no side effects, so a
  test can load it directly).

  One rule worth stating: DayZ ships several mission files with a UTF-8 BOM, and
  PowerShell's `[xml]$string` cast REJECTS a string starting with U+FEFF - the BOM is a
  byte-order mark for a FILE, and has no meaning once the bytes are already a .NET string.

  So: strip a leading BOM, then parse. An unknown kind is ALWAYS false - a caller must not
  be able to pull content nothing validated (that is how a bad file reaches the repo, and
  eventually a rebuilt box).

.EXAMPLE
  . (Join-Path $PSScriptRoot 'ConfigParse.ps1')
  if (-not (Test-ConfigParses $text $row.check)) { <reject> }
#>

function Test-ConfigParses {
    [OutputType([bool])]
    param(
        # The file CONTENT, already read into a string.
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Text,
        # The registry row's `check` tag: 'json' | 'xml' | 'text'. Anything else = not validatable.
        [Parameter(Position = 1)][AllowNull()][AllowEmptyString()][string]$Kind
    )
    if ($null -eq $Text) { return $false }
    # A BOM is file framing, not content. Strip it BEFORE any parse or emptiness test, or a
    # BOM-only file reads as non-empty and a BOM'd document fails the [xml] cast.
    $t = $Text.TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($t)) { return $false }
    switch ([string]$Kind) {
        'json'  { try { $null = $t | ConvertFrom-Json; return $true } catch { return $false } }
        'xml'   { try { $null = [xml]$t;               return $true } catch { return $false } }
        # 'text' - the OTHER kind. ban.txt / whitelist.txt / map.env are
        # real owned surfaces that are neither JSON nor XML; declaring check:'none' left them
        # permanently unmirrorable. The only honest claim about a freeform file is "this is
        # readable text, not binary or truncated" - which still catches the failures that
        # matter for a pull. A NUL byte means we fetched a binary, so refuse.
        'text'  { return (-not $t.Contains([char]0)) }
        # No default validator ON PURPOSE: refuse to bless content nothing checked.
        default { return $false }
    }
}
