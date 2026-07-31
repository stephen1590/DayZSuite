#requires -Version 7
<#
.SYNOPSIS
  Cut ONE file off the override delta engine and onto whole-file ownership, without
  changing a byte of the live file. The generic form of the freeze trick (Scale-Ready A3).

.DESCRIPTION
  Apply-ConfigOverrides only rebuilds files LISTED in config-overrides.json. So removing
  a file's block does not revert it - it FREEZES the live file exactly as it stands, and
  from then on the file is owned whole (edited in the ConfigViewer two-copy editor).

  That is only behaviour-preserving if the live file ALREADY carries every override value,
  i.e. a boot has applied them. This script proves that first:

    1. resolve the target's block in the manifest
    2. evaluate EVERY selector against the LIVE file (XPath for XML, dotted key for JSON)
    3. all match  -> safe: report it, and with -Fix remove the block
       any differ -> REFUSE and name them. Freezing there would silently lock in a value
                     the manifest never intended - the "behaviour differs between settings"
                     failure this project exists to stop.

  READ-ONLY by default (house rule): a bare run verifies and reports. -Fix writes.
  The LIVE FILE IS NEVER WRITTEN by this script, in either mode.

.EXAMPLE
  ./Convert-ToOwned.ps1 -ServerDir ~/servers/dayz-server -Target 'mpmissions/dayzOffline.sakhal:db/types.xml'
  ./Convert-ToOwned.ps1 -ServerDir ~/servers/dayz-server -Target 'files:server-settings.json' -Fix
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerDir,
    # '<layer>:<relpath>' - layer is 'files' or 'mpmissions/<mission>'
    [Parameter(Mandatory)][string]$Target,
    [string]$Manifest,
    [switch]$Fix,
    [switch]$NoLog
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../common/Utils.ps1')

if (-not $Manifest) { $Manifest = Join-Path $PSScriptRoot 'config-overrides.json' }
if (-not (Test-Path $Manifest))  { Write-Error "No manifest at: $Manifest"; exit 2 }
if (-not (Test-Path $ServerDir)) { Write-Error "No server dir at: $ServerDir"; exit 2 }

$parts = $Target.Split(':', 2)
if ($parts.Count -ne 2) { Write-Error "-Target must be '<layer>:<relpath>', e.g. 'mpmissions/dayzOffline.sakhal:db/types.xml'"; exit 2 }
$layer, $rel = $parts[0], $parts[1]

$doc = Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json -AsHashtable

# --- locate the block + the live file ---------------------------------------
$container = $null; $liveFile = $null
if ($layer -eq 'files') {
    if ($doc.files) { $container = $doc.files }
    $liveFile = Join-Path $ServerDir $rel
}
elseif ($layer -like 'mpmissions/*') {
    $mission = $layer.Substring('mpmissions/'.Length)
    if ($doc.mpmissions -and $doc.mpmissions[$mission]) { $container = $doc.mpmissions[$mission] }
    $liveFile = Join-Path (Join-Path (Join-Path $ServerDir 'mpmissions') $mission) $rel
}
else { Write-Error "Unknown layer '$layer' - use 'files' or 'mpmissions/<mission>'"; exit 2 }

if ($null -eq $container -or -not $container.ContainsKey($rel)) {
    # No block. Two very different situations, told apart by the LIVE FILE - after a cutover
    # the manifest looks identical to "never listed", so the manifest alone cannot say which:
    #   live file exists  -> already owned. Idempotent SUCCESS, so a re-run in a runbook is quiet.
    #   live file absent  -> a typo'd/unknown target. Fail loudly rather than report success.
    if (Test-Path $liveFile) {
        Write-Host "already owned: no block for '$rel' under '$layer', and the live file is there - nothing to cut over."
        exit 0
    }
    Write-Error "Unknown target: no block for '$rel' under '$layer', and no live file at $liveFile."
    exit 2
}
$block = $container[$rel]
$selectors = @($block.Keys | Where-Object { -not $_.StartsWith('_') })

if (-not (Test-Path $liveFile)) {
    Write-Error "Live file not found: $liveFile - cannot prove the freeze is safe. Run this where the live tree is (the box), or point -ServerDir at it."
    exit 3
}

# --- verify the live file already carries every override value ---------------
$isXml = $rel.ToLower().EndsWith('.xml')
$live = Get-Content -Raw -LiteralPath $liveFile
$mismatch = [System.Collections.Generic.List[string]]::new()
$verified = 0

function Get-JsonAt($root, [string]$dotted) {
    $cur = $root
    foreach ($k in $dotted.Split('.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [hashtable]) { if (-not $cur.ContainsKey($k)) { return $null }; $cur = $cur[$k] }
        else { $p = $cur.PSObject.Properties[$k]; if (-not $p) { return $null }; $cur = $p.Value }
    }
    $cur
}
# Compare as invariant strings: the manifest stores "3888000", the XML holds 3888000.
function Same($a, $b) {
    if ($null -eq $a -or $null -eq $b) { return $false }
    [string]$sa = if ($a -is [bool]) { ([bool]$a) ? 'true' : 'false' } else { [string]::Format([cultureinfo]::InvariantCulture, '{0}', $a) }
    [string]$sb = if ($b -is [bool]) { ([bool]$b) ? 'true' : 'false' } else { [string]::Format([cultureinfo]::InvariantCulture, '{0}', $b) }
    $sa.Trim() -eq $sb.Trim()
}

if ($isXml) {
    $xml = [xml]$live
    foreach ($sel in $selectors) {
        $nodes = $xml.SelectNodes($sel)
        if (-not $nodes -or $nodes.Count -eq 0) { $mismatch.Add("$sel -> selector matches NOTHING in the live file"); continue }
        foreach ($n in $nodes) {
            $have = if ($n -is [System.Xml.XmlAttribute]) { $n.Value } else { $n.InnerText }
            if (Same $have $block[$sel]) { $verified++ }
            else { $mismatch.Add("$sel -> live '$have', manifest '$($block[$sel])'") }
        }
    }
}
else {
    $json = $live | ConvertFrom-Json -AsHashtable
    foreach ($sel in $selectors) {
        $have = Get-JsonAt $json $sel
        if ($null -eq $have) { $mismatch.Add("$sel -> key missing from the live file"); continue }
        if (Same $have $block[$sel]) { $verified++ }
        else { $mismatch.Add("$sel -> live '$have', manifest '$($block[$sel])'") }
    }
}

Write-Host "target   : $layer -> $rel"
Write-Host "live file: $liveFile"
Write-Host "selectors: $($selectors.Count) declared, $verified verified against the live file"

if ($mismatch.Count) {
    Write-Host ''
    Write-Host "REFUSING: the live file does not carry these override values, so freezing it would lock in something the manifest never intended:" -ForegroundColor Red
    foreach ($m in $mismatch) { Write-Host "  $m" -ForegroundColor Red }
    Write-Host ''
    Write-Host "Most likely the server has not restarted since these rows were written - Apply-ConfigOverrides only applies them at boot/prestart."
    Write-Host "Restart once (owner's call) so the values land in the live file, then re-run this. Nothing was changed."
    if (-not $NoLog) {
        Write-CsvLog -Path (Join-Path $PSScriptRoot 'logs/convert-to-owned.log.csv') -Row ([pscustomobject]@{
            Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Target = $Target; Result = 'REFUSED'
            Selectors = $selectors.Count; Verified = $verified; Mismatched = $mismatch.Count; Applied = $false
        })
    }
    exit 4
}

Write-Host "SAFE to freeze: every declared value is already live, so removing the block changes nothing on disk." -ForegroundColor Green

if (-not $Fix) {
    Write-Host ''
    Write-Host "(report only - re-run with -Fix to remove the block and own the file whole)"
    exit 0
}

# --- apply: remove the block, never touch the live file ----------------------
$liveHashBefore = (Get-FileHash -LiteralPath $liveFile -Algorithm SHA256).Hash
$container.Remove($rel)
$json = $doc | ConvertTo-Json -Depth 12
Set-Content -LiteralPath $Manifest -Value $json -NoNewline:$false
$liveHashAfter = (Get-FileHash -LiteralPath $liveFile -Algorithm SHA256).Hash

if ($liveHashBefore -ne $liveHashAfter) { Write-Error "INTERNAL: the live file changed during the cutover - it must not. Investigate before restarting."; exit 5 }

Write-Host "cut over : block removed from the manifest; live file SHA256 unchanged ($($liveHashBefore.Substring(0,12))…)" -ForegroundColor Green
Write-Host "next     : the file is now owned whole - edit it in ConfigViewer's file editor. Capture-OwnedDefaults gives it a frozen default if it has none."
if (-not $NoLog) {
    Write-CsvLog -Path (Join-Path $PSScriptRoot 'logs/convert-to-owned.log.csv') -Row ([pscustomobject]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Target = $Target; Result = 'CUTOVER'
        Selectors = $selectors.Count; Verified = $verified; Mismatched = 0; Applied = $true
    })
}
exit 0
