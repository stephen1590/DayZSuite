#requires -version 7
<#
.SYNOPSIS
    Patch field-level overrides from config-overrides.json into the LIVE server config
    files. We never store whole vanilla/mod files - each override targets ONE field BY
    NAME, so a game/mod update that rewrites the baseline is inherited and our deltas
    re-apply on top.

.DESCRIPTION
    Report-only by default (shows what WOULD change); pass -Fix to write.

    FAIL-SOFT BY DESIGN: every patch is independent. A missing file, an unmatched
    selector, or a bad value is logged (MISS/WARN) and the run continues to the next
    change - one broken override never blocks the others or the deploy. The final
    summary line makes any failures loud, and the returned object carries the counts so
    the caller (Deploy) can surface them.

    Manifest shape (see config-overrides.json _readme):
      files.<relpath>              : { selector -> value }   (one file under ServerDir)
      mpmissions.common            : { <mission-rel-file> -> { selector -> value } }  (all missions)
      mpmissions.<mission>         : same, applied AFTER common, wins on conflict
    XML selector = XPath (attribute //var[@name='X']/@value or element //type[@name='Y']/nominal).
    JSON selector = dotted key path (chanceToSpawn or a.b.c). Keys starting with _ are ignored.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerDir,
    [string]$Manifest = (Join-Path $PSScriptRoot 'config-overrides.json'),
    [Alias('Apply')][switch]$Fix
)

$ErrorActionPreference = 'Stop'
$mode = if ($Fix) { 'APPLY' } else { 'REPORT' }

# --- counters -------------------------------------------------------------------
$stats = [ordered]@{ Changed = 0; Same = 0; Warn = 0 }
function Show-Change { $script:stats.Changed++; Write-Host ("  [OK]   {0}" -f $args[0]) -ForegroundColor Green }
function Show-Same   { $script:stats.Same++;    Write-Host ("  [SAME] {0}" -f $args[0]) -ForegroundColor DarkGray }
function Show-Warn   { $script:stats.Warn++;    Write-Host ("  [WARN] {0}" -f $args[0]) -ForegroundColor Yellow }

# --- helpers --------------------------------------------------------------------

# Ordered, culture-invariant stringify so 0.82 never becomes 0,82 and 5 stays 5.
function ConvertTo-InvariantString($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [double] -or $v -is [single] -or $v -is [decimal]) {
        return ([double]$v).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$v
}

# Canonical form for comparing/reporting a JSON patch value. Scalars keep the culture-
# invariant string (so 0.82 never drifts to 0,82). Arrays/objects use compact JSON:
# a plain [string] cast collapses an array of objects to ' ', so two DIFFERENT object
# arrays (e.g. a loadout list, or the SocialMedia NewsFeed) compare equal and the patch
# is silently skipped as "already set". Empty [] round-trips to '[]', so this stays idempotent.
function ConvertTo-CompareKey($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or
        $v -is [double] -or $v -is [single] -or $v -is [decimal]) {
        return ConvertTo-InvariantString $v
    }
    return (ConvertTo-Json $v -Depth 100 -Compress)
}

# Enumerate every real override in the manifest as flat jobs. Each job is fail-soft on
# its own; ordering (common before mission-specific) makes the mission layer win.
function Get-Jobs($manifest, [string]$serverDir) {
    $jobs = [System.Collections.Generic.List[object]]::new()

    # files.<relpath>  -> one absolute file under the server dir
    if ($manifest.PSObject.Properties.Name -contains 'files') {
        foreach ($p in $manifest.files.PSObject.Properties) {
            if ($p.Name.StartsWith('_')) { continue }
            foreach ($sel in $p.Value.PSObject.Properties) {
                if ($sel.Name.StartsWith('_')) { continue }
                $jobs.Add([pscustomobject]@{
                    Label = "files/$($p.Name)"; File = (Join-Path $serverDir $p.Name)
                    Selector = $sel.Name; Value = $sel.Value
                })
            }
        }
    }

    # mpmissions: common applied to EVERY present mission dir, then mission-specific.
    if ($manifest.PSObject.Properties.Name -contains 'mpmissions') {
        $mpRoot = Join-Path $serverDir 'mpmissions'
        $present = if (Test-Path $mpRoot) { Get-ChildItem $mpRoot -Directory | Select-Object -Expand Name } else { @() }
        $mp = $manifest.mpmissions

        $emit = {
            param($layerObj, $missionName, $srcTag)
            foreach ($fileProp in $layerObj.PSObject.Properties) {         # mission-relative file, e.g. db/globals.xml
                if ($fileProp.Name.StartsWith('_')) { continue }
                foreach ($sel in $fileProp.Value.PSObject.Properties) {
                    if ($sel.Name.StartsWith('_')) { continue }
                    $jobs.Add([pscustomobject]@{
                        Label = "$srcTag/$missionName/$($fileProp.Name)"
                        File = (Join-Path (Join-Path $mpRoot $missionName) $fileProp.Name)
                        Selector = $sel.Name; Value = $sel.Value
                    })
                }
            }
        }

        # common first (into each present mission) ...
        if ($mp.PSObject.Properties.Name -contains 'common') {
            foreach ($mission in $present) { & $emit $mp.common $mission 'common' }
        }
        # ... then any mission-specific layer, but only for missions that exist on disk.
        foreach ($layer in $mp.PSObject.Properties) {
            if ($layer.Name -eq 'common' -or $layer.Name.StartsWith('_')) { continue }
            # Empty placeholder sections (reserved slots for future deltas) are silent.
            $hasPatches = @($layer.Value.PSObject.Properties | Where-Object { -not $_.Name.StartsWith('_') }).Count -gt 0
            if (-not $hasPatches) { continue }
            if ($present -notcontains $layer.Name) {
                Show-Warn "mission '$($layer.Name)' in manifest but not on disk under mpmissions/ - skipped"
                continue
            }
            & $emit $layer.Value $layer.Name 'mission'
        }
    }
    return $jobs
}

# --- XML / JSON single-file patchers (mutate an in-memory doc, report per selector) --

function Set-XmlNode($doc, [string]$selector, $value, [string]$label) {
    $node = $doc.SelectSingleNode($selector)
    if ($null -eq $node) { Show-Warn "$label : selector '$selector' matched nothing"; return $false }
    $want = ConvertTo-InvariantString $value
    # XmlAttribute exposes .Value; an element node we treat by its text content.
    if ($node -is [System.Xml.XmlAttribute]) {
        if ($node.Value -eq $want) { Show-Same "$label : $selector already '$want'"; return $false }
        Show-Change "$label : $selector  '$($node.Value)' -> '$want'"; $node.Value = $want; return $true
    } else {
        if ($node.InnerText -eq $want) { Show-Same "$label : $selector already '$want'"; return $false }
        Show-Change "$label : $selector  '$($node.InnerText)' -> '$want'"; $node.InnerText = $want; return $true
    }
}

function Set-JsonKey($root, [string]$dotted, $value, [string]$label) {
    $parts = $dotted.Split('.')
    $cur = $root
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $k = $parts[$i]
        if ($null -eq $cur.PSObject.Properties[$k]) { Show-Warn "$label : path '$dotted' - '$k' not found"; return $false }
        $cur = $cur.$k
    }
    $leaf = $parts[-1]
    if ($null -eq $cur.PSObject.Properties[$leaf]) { Show-Warn "$label : key '$dotted' not found"; return $false }
    $want = ConvertTo-CompareKey $value
    $have = ConvertTo-CompareKey $cur.$leaf
    if ($have -eq $want) { Show-Same "$label : $dotted already '$want'"; return $false }
    Show-Change "$label : $dotted  '$have' -> '$want'"; $cur.$leaf = $value; return $true
}

# --- main -----------------------------------------------------------------------

Write-Host "Config overrides ($mode)  manifest=$Manifest" -ForegroundColor Cyan
if (-not (Test-Path $Manifest)) { Show-Warn "manifest not found: $Manifest"; return [pscustomobject]$stats }
if (-not (Test-Path $ServerDir)) { Show-Warn "server dir not found: $ServerDir"; return [pscustomobject]$stats }

# NB: distinct name from the [string]$Manifest PARAM - PS var names are case-insensitive,
# so reusing $manifest would inherit the [string] constraint and coerce the parsed object
# back into a string.
$mf = Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json
$jobs = Get-Jobs $mf $ServerDir

# Collapse duplicate (file, selector) jobs, keeping the LAST (jobs are emitted common->
# mission, so the mission layer SUPERSEDES common for a shared field). Without this the
# two layers fight every run (common reverts, mission re-sets) - correct final value but
# never idempotent, and a needless rewrite each deploy.
$seen = [ordered]@{}
foreach ($j in $jobs) { $seen["$($j.File)`n$($j.Selector)"] = $j }
$jobs = @($seen.Values)

# Group by target file so each file is parsed once and saved once (whitespace-preserving).
foreach ($grp in ($jobs | Group-Object File)) {
    $file = $grp.Name
    if (-not (Test-Path $file)) {
        foreach ($j in $grp.Group) { Show-Warn "$($j.Label) : file not found ($file)" }
        continue
    }
    $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
    $dirty = $false

    try {
        if ($ext -eq '.xml') {
            $doc = [System.Xml.XmlDocument]::new(); $doc.PreserveWhitespace = $true
            $doc.Load($file)
            foreach ($j in $grp.Group) {
                try { if (Set-XmlNode $doc $j.Selector $j.Value $j.Label) { $dirty = $true } }
                catch { Show-Warn "$($j.Label) : $($_.Exception.Message)" }
            }
            if ($dirty -and $Fix) { $doc.Save($file) }
        }
        elseif ($ext -eq '.json') {
            $root = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
            foreach ($j in $grp.Group) {
                try { if (Set-JsonKey $root $j.Selector $j.Value $j.Label) { $dirty = $true } }
                catch { Show-Warn "$($j.Label) : $($_.Exception.Message)" }
            }
            if ($dirty -and $Fix) {
                ($root | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $file -Encoding utf8
            }
        }
        else {
            foreach ($j in $grp.Group) { Show-Warn "$($j.Label) : unsupported file type '$ext'" }
        }
    }
    catch {
        # Whole-file failure (parse error, unreadable) - warn every job in it, keep going.
        foreach ($j in $grp.Group) { Show-Warn "$($j.Label) : file error - $($_.Exception.Message)" }
    }
}

# --- summary (loud on any warning) ----------------------------------------------
$tag = if ($Fix) { 'applied' } else { 'REPORT ONLY - re-run under -Fix to write' }
$line = "Config overrides: {0} changed, {1} already-set, {2} warning(s)  [{3}]" -f $stats.Changed, $stats.Same, $stats.Warn, $tag
if ($stats.Warn -gt 0) { Write-Host $line -ForegroundColor Yellow } else { Write-Host $line -ForegroundColor Green }

return [pscustomobject]$stats
