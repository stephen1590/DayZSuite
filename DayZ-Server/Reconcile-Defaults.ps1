#requires -Version 7
<#
.SYNOPSIS
  Reconcile an OWNED config file after a game/mod update rewrote its baseline
  (CONFIG-ARCHITECTURE.md Phase 4). 3-way merge via `git merge-file` - the recorded
  decision; no hand-rolled merger.

.DESCRIPTION
  Inputs: -OldDefault (the frozen baseline the live file was edited against),
  -NewDefault (the vendor's post-update baseline), -Live (the box-owned file with
  our edits). Report-only by default. -Fix on a CLEAN merge writes the merged live
  file (parse-validated first) and adopts the new default as the frozen baseline.
  A CONFLICT never touches the live file - -Fix writes a marker-annotated copy to
  reconcile-conflicts/ beside the live file for HUMAN review (the whole point:
  reconcile is reviewed, never silently re-stamped), and exits nonzero.

  Exit: 0 = clean (or no-op), 2 = conflict (human required), 1 = error.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OldDefault,
    [Parameter(Mandatory)][string]$NewDefault,
    [Parameter(Mandatory)][string]$Live,
    [switch]$Fix,
    [switch]$NoLog
)
$ErrorActionPreference = 'Stop'
foreach ($f in $OldDefault, $NewDefault, $Live) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Error "not found: $f"; exit 1 }
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Error "git not found - git merge-file is the merge engine."; exit 1 }

function Test-ParsesByExtension([string]$path, [string]$text) {
    try {
        switch -Regex ($path) {
            '\.json$' { $null = $text | ConvertFrom-Json -AsHashtable; return $true }
            '\.xml$'  { $x = [xml]::new(); $x.LoadXml($text); return $true }
            default   { return $true }   # other extensions: merge only, no parse assertion
        }
    } catch { return $false }
}

# git merge-file -p prints the merge to stdout; exit code = conflict count (negative = error).
$merged = & git merge-file -p -L 'LIVE (our edits)' -L 'OLD DEFAULT' -L 'NEW DEFAULT' -- $Live $OldDefault $NewDefault 2>&1 | Out-String
$rc = $LASTEXITCODE
if ($rc -lt 0) { Write-Error "git merge-file failed: $merged"; exit 1 }

$liveText = Get-Content -Raw -LiteralPath $Live
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$liveName = Split-Path -Leaf $Live
if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    [pscustomobject]@{ timestamp = $stamp; live = $Live; result = ($rc -eq 0 ? 'clean' : 'conflict'); conflicts = $rc; mode = ($Fix ? 'fix' : 'report') } |
        Export-Csv -Append -Path (Join-Path $logDir 'reconcile.csv') -NoTypeInformation
}

if ($rc -eq 0) {
    if ($merged -eq $liveText) { Write-Host "CLEAN - no-op: the update changes nothing this file overrides ($liveName)"; exit 0 }
    Write-Host "CLEAN - 3-way merge succeeds: our edits + the vendor's changes combine with no conflict ($liveName)"
    if ($Fix) {
        if (-not (Test-ParsesByExtension $Live $merged)) { Write-Error "merged result does not parse - refusing to write $liveName (treat as a conflict, review by hand)"; exit 2 }
        Set-Content -LiteralPath $Live -Value $merged -NoNewline
        Copy-Item -LiteralPath $NewDefault -Destination $OldDefault -Force   # adopt the new baseline
        Write-Host "APPLIED: merged live written; new default adopted as the frozen baseline"
    } else {
        Write-Host "(report only - re-run with -Fix to write)"
    }
    exit 0
}

Write-Host "CONFLICT: $rc region(s) changed on BOTH sides - human review required, live file untouched ($liveName)"
if ($Fix) {
    $confDir = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Live)) 'reconcile-conflicts'
    New-Item -ItemType Directory -Force -Path $confDir | Out-Null
    $copy = Join-Path $confDir "$liveName.$stamp.merge"
    Set-Content -LiteralPath $copy -Value $merged -NoNewline
    Write-Host "marker-annotated merge written for review: $copy"
    Write-Host "resolve there, then paste the result through the config UI (the owned-file editor) - never onto the box by hand"
}
exit 2
