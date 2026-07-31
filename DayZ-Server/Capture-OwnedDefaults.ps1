#requires -Version 7
<#
.SYNOPSIS
  Capture the frozen `default` companion for OWNED config surfaces that do not have one
  (CONFIG-ARCHITECTURE.md two-copy model).

.DESCRIPTION
  The two-copy model says an owned file keeps two whole copies - a frozen `default`
  reference and the `live` file - and the UI DISPLAYS the diff (never applies it).

  This is now the ONLY writer of a `<stem>.defaults.<ext>` companion. It used to share that
  job with Apply-ConfigOverrides, which captured a baseline for the files it patched and
  therefore had to be skipped here; that engine is deleted (2026-07-31), so every owned row
  is captured by one mechanism with one rule. The skip that existed for override targets is
  gone with it - a file that used to be patched is now simply an owned file like any other.

  For each registry row with category 'owned' and a 'box' path:
    - SKIP if a default already exists. SEED-IF-MISSING ONLY: the default is the frozen
      reference, and re-capturing it from live would silently erase the delta being compared.
      (Same doctrine as the deploy's config seeding - never overwrite box-owned content.)
    - SKIP if the live file is not on disk - a default is never invented.
    - otherwise copy live -> <stem>.defaults.<ext>, byte for byte.

  READ-ONLY BY DEFAULT: a bare run reports what it WOULD capture. -Fix performs the copies.
  Idempotent: a second run is a no-op.

.EXAMPLE
  ./Capture-OwnedDefaults.ps1 -ServerDir ~/servers/dayz-server              # report
  ./Capture-OwnedDefaults.ps1 -ServerDir ~/servers/dayz-server -Fix         # capture
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerDir,
    [string]$Registry,
    [Alias('Apply')][switch]$Fix,
    [switch]$NoLog
)
$ErrorActionPreference = 'Stop'

if (-not $Registry) { $Registry = Join-Path $ServerDir 'config-registry.json' }
if (-not (Test-Path -LiteralPath $ServerDir)) { Write-Error "ServerDir not found: $ServerDir"; exit 1 }
if (-not (Test-Path -LiteralPath $Registry))  { Write-Error "config-registry.json not found: $Registry"; exit 1 }

function Show-Info($m) { Write-Host $m }
function Show-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

# <name>.<ext> -> <name>.defaults.<ext>; extensionless -> <name>.defaults. Mirrors the same
# rule dayz-ctl's _defaults_path() and own-editor.js defaultsPathOf() use - three copies of
# this convention now exist, which is why it is stated identically in all three.
function Get-DefaultsPath([string]$rel) {
    $dir = [IO.Path]::GetDirectoryName($rel)
    $leaf = [IO.Path]::GetFileName($rel)
    $i = $leaf.LastIndexOf('.')
    $newLeaf = if ($i -gt 0) { $leaf.Substring(0, $i) + '.defaults' + $leaf.Substring($i) } else { "$leaf.defaults" }
    if ([string]::IsNullOrEmpty($dir)) { return $newLeaf }
    return ($dir + '/' + $newLeaf) -replace '\\', '/'
}

$registryDoc = Get-Content -Raw -LiteralPath $Registry | ConvertFrom-Json

$owned = @($registryDoc.surfaces | Where-Object { $_ -and $_.category -eq 'owned' -and $_.box })
Show-Info "Owned surfaces declared: $($owned.Count)$(if (-not $Fix) { '  (report only - re-run with -Fix to capture)' })"

$captured = 0; $skipExisting = 0; $skipAbsent = 0
$rows = @()
foreach ($row in $owned) {
    $rel     = "$($row.box)"
    $livePath = Join-Path $ServerDir $rel
    $defRel   = Get-DefaultsPath $rel
    $defPath  = Join-Path $ServerDir $defRel

    if (Test-Path -LiteralPath $defPath) {
        $skipExisting++; $rows += [pscustomobject]@{ rel = $rel; action = 'skip-default-exists' }
        continue
    }
    if (-not (Test-Path -LiteralPath $livePath)) {
        $skipAbsent++; $rows += [pscustomobject]@{ rel = $rel; action = 'skip-live-absent' }
        Show-Warn "$rel - declared owned but not on disk; no default invented"
        continue
    }
    $bytes = (Get-Item -LiteralPath $livePath).Length
    Show-Info "  [capture] $rel -> $defRel ($bytes bytes)$(if (-not $Fix) { ' (would)' })"
    $rows += [pscustomobject]@{ rel = $rel; action = ($Fix ? 'captured' : 'would-capture') }
    if ($Fix) { Copy-Item -LiteralPath $livePath -Destination $defPath -Force; $captured++ }
}

if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    foreach ($r in $rows) {
        [pscustomobject]@{ timestamp = $stamp; relpath = $r.rel; action = $r.action; mode = ($Fix ? 'fix' : 'report') } |
            Export-Csv -Append -Path (Join-Path $logDir 'capture-owned-defaults.csv') -NoTypeInformation
    }
}

$verb = if ($Fix) { 'captured' } else { 'to capture' }
Show-Info "`nCapture-OwnedDefaults: $(if ($Fix) { $captured } else { @($rows | Where-Object action -eq 'would-capture').Count }) $verb, $skipExisting already had a default, $skipAbsent not on disk"
exit 0
