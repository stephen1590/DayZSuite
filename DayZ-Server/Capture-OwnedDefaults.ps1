#requires -Version 7
<#
.SYNOPSIS
  Capture the frozen `default` companion for OWNED config surfaces that do not have one
  (CONFIG-ARCHITECTURE.md two-copy model).

.DESCRIPTION
  The two-copy model says an owned file keeps two whole copies - a frozen `default`
  reference and the `live` file - and the UI DISPLAYS the diff (never applies it).
  Nothing built that first copy for files outside the patch niche: the only writer of a
  `<stem>.defaults.<ext>` companion is Apply-ConfigOverrides, and it writes one only for
  files it PATCHES. An owned file with no override rows therefore has no default at all,
  so the own-editor renders "no frozen default captured, plain edit" and there is nothing
  to compare. This closes that gap - one mechanism for every owned row, not a per-file copy.

  For each registry row with category 'owned' and a 'box' path:
    - SKIP if the file is targeted by config-overrides.json (mission layer, common layer, or
      wholeFiles). Apply-ConfigOverrides owns that companion, and capturing a POST-patch live
      file would bake the patches into the supposedly pristine baseline.
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
    [string]$Manifest,
    [Alias('Apply')][switch]$Fix,
    [switch]$NoLog
)
$ErrorActionPreference = 'Stop'

if (-not $Registry) { $Registry = Join-Path $ServerDir 'config-registry.json' }
if (-not $Manifest) { $Manifest = Join-Path $ServerDir 'config-overrides.json' }
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
$manifestDoc = if (Test-Path -LiteralPath $Manifest) { Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json } else { $null }

function Test-HasProp($obj, [string]$name) {
    if ($null -eq $obj) { return $false }
    return ($obj.PSObject.Properties.Name -contains $name)
}

# Is this ServerDir-relative path targeted by the override engine (any layer, incl. wholeFiles)?
function Test-IsOverrideTarget([string]$rel) {
    if ($null -eq $manifestDoc) { return $false }
    $m = [regex]::Match($rel, '^mpmissions/([^/]+)/(.+)$')
    foreach ($root in @($manifestDoc, $manifestDoc.wholeFiles)) {
        if ($null -eq $root) { continue }
        if ($m.Success) {
            $mission = $m.Groups[1].Value
            $sub     = $m.Groups[2].Value
            if (Test-HasProp $root 'mpmissions') {
                foreach ($layer in @($mission, 'common')) {
                    if ((Test-HasProp $root.mpmissions $layer) -and (Test-HasProp $root.mpmissions.$layer $sub)) { return $true }
                }
            }
        } else {
            if ((Test-HasProp $root 'files') -and (Test-HasProp $root.files $rel)) { return $true }
        }
    }
    return $false
}

$owned = @($registryDoc.surfaces | Where-Object { $_ -and $_.category -eq 'owned' -and $_.box })
Show-Info "Owned surfaces declared: $($owned.Count)$(if (-not $Fix) { '  (report only - re-run with -Fix to capture)' })"

$captured = 0; $skipExisting = 0; $skipOverride = 0; $skipAbsent = 0
$rows = @()
foreach ($row in $owned) {
    $rel     = "$($row.box)"
    $livePath = Join-Path $ServerDir $rel
    $defRel   = Get-DefaultsPath $rel
    $defPath  = Join-Path $ServerDir $defRel

    if (Test-IsOverrideTarget $rel) {
        $skipOverride++; $rows += [pscustomobject]@{ rel = $rel; action = 'skip-override-target' }
        Show-Info "  [skip] $rel - an override target; Apply-ConfigOverrides owns its default"
        continue
    }
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
Show-Info "`nCapture-OwnedDefaults: $(if ($Fix) { $captured } else { @($rows | Where-Object action -eq 'would-capture').Count }) $verb, $skipExisting already had a default, $skipOverride override-owned, $skipAbsent not on disk"
exit 0
