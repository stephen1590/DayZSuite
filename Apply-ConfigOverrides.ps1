#requires -version 7
<#
.SYNOPSIS
    Rebuild the LIVE server config files as "frozen default + your field patches" from
    config-overrides.json, every prestart. A REVERSIBLE overlay: remove a patch and the
    field returns to its default; accidental drift in the live file is wiped and reapplied.

.DESCRIPTION
    Report-only by default (shows what WOULD change); pass -Fix to write.

    REVERSIBLE DEFAULTS: the first time we patch a file (no <name>.defaults<ext> beside it),
    its CURRENT contents are captured as the frozen default. Thereafter each run rebuilds the
    live file = that default + the current patches, so a removed override reverts to default
    and manual edits don't linger. Per-selector reports name the KEY/PROPERTY only, never the
    value - so the deploy output never echoes config contents. Freezing means a mod update is NOT auto-
    inherited for that file: delete its .defaults to fall back to inherit/forward-only, or
    re-capture (delete + re-run) to refresh the baseline. The .defaults files are HIDDEN
    reference baselines - not browsable or editable configs.

    FAIL-SOFT BY DESIGN: every patch is independent. A missing file, an unmatched
    selector, or a bad value is logged (MISS/WARN) and the run continues to the next
    change - one broken override never blocks the others or the deploy. The final
    summary line makes any failures loud, and the returned object carries the counts so
    the caller (Deploy) can surface them.

    Manifest shape (see config-overrides.json _readme):
      files.<relpath>              : { selector -> value }   (one file under ServerDir)
      mpmissions.common            : { <mission-rel-file> -> { selector -> value } }  (all DECLARED missions)
      mpmissions.<mission>         : same, applied AFTER common, wins on conflict
    The mpmissions.<mission> KEYS declare which missions are MANAGED (an empty {} declares one
    with no specific patches). common applies only to declared missions on disk - a foreign dir
    under mpmissions/ (a side project, an admin copy) is never patched or captured.
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
$stats = [ordered]@{ Changed = 0; Same = 0; Warn = 0; Captured = 0 }
function Show-Change  { $script:stats.Changed++;  Write-Host ("  [OK]   {0}" -f $args[0]) -ForegroundColor Green }
function Show-Same    { $script:stats.Same++;     Write-Host ("  [SAME] {0}" -f $args[0]) -ForegroundColor DarkGray }
function Show-Warn    { $script:stats.Warn++;     Write-Host ("  [WARN] {0}" -f $args[0]) -ForegroundColor Yellow }
function Show-Capture { $script:stats.Captured++; Write-Host ("  [DEF]  {0}" -f $args[0]) -ForegroundColor Cyan }

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

    # mpmissions: the manifest's mission KEYS are the declaration of MANAGED missions —
    # common applies only to declared missions present on disk (an empty {} slot declares
    # one with no specific patches yet). A foreign dir under mpmissions/ (a side project,
    # an admin copy) is NEVER touched.
    if ($manifest.PSObject.Properties.Name -contains 'mpmissions') {
        $mpRoot = Join-Path $serverDir 'mpmissions'
        $present = if (Test-Path $mpRoot) { Get-ChildItem $mpRoot -Directory | Select-Object -Expand Name } else { @() }
        $mp = $manifest.mpmissions
        $declared = @($mp.PSObject.Properties.Name | Where-Object { $_ -ne 'common' -and -not $_.StartsWith('_') })

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

        # common first (into each DECLARED mission that exists on disk) ...
        if ($mp.PSObject.Properties.Name -contains 'common') {
            $commonInto = @($declared | Where-Object { $present -contains $_ })
            if (-not $commonInto.Count) {
                Show-Warn "mpmissions.common has patches but no declared mission is on disk - declare missions as mpmissions.<name> keys (an empty {} is enough)"
            }
            foreach ($mission in $commonInto) { & $emit $mp.common $mission 'common' }
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
        if ($node.Value -eq $want) { Show-Same "$label : $selector (unchanged)"; return $false }
        Show-Change "$label : $selector"; $node.Value = $want; return $true
    } else {
        if ($node.InnerText -eq $want) { Show-Same "$label : $selector (unchanged)"; return $false }
        Show-Change "$label : $selector"; $node.InnerText = $want; return $true
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
    if ($have -eq $want) { Show-Same "$label : $dotted (unchanged)"; return $false }
    Show-Change "$label : $dotted"; $cur.$leaf = $value; return $true
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

# Group by target file so each is captured / rebuilt / saved once (whitespace-preserving).
foreach ($grp in ($jobs | Group-Object File)) {
    $file = $grp.Name
    if (-not (Test-Path -LiteralPath $file)) {
        foreach ($j in $grp.Group) { Show-Warn "$($j.Label) : file not found ($file)" }
        continue
    }
    $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()

    # Reversible defaults: <name>.defaults<ext> beside the file is the FROZEN baseline.
    # Born at first patch (a raw copy of the live file); thereafter we rebuild the live file
    # = default + patches every run, so a removed override reverts and manual drift is wiped.
    # It's a hidden reference, never itself a patch target. .defaults present => reversible
    # (rebuild from it); absent => legacy in-place patching (also the pre-capture REPORT state).
    $defaultPath = Join-Path (Split-Path -Parent $file) `
        ('{0}.defaults{1}' -f [IO.Path]::GetFileNameWithoutExtension($file), [IO.Path]::GetExtension($file))
    $haveDefault = Test-Path -LiteralPath $defaultPath
    if (-not $haveDefault) {
        if ($Fix) {
            Copy-Item -LiteralPath $file -Destination $defaultPath -Force
            $haveDefault = $true
            Show-Capture "$($grp.Group[0].Label) : captured $([IO.Path]::GetFileName($defaultPath)) (frozen default = current file)"
        } else {
            Show-Warn "$($grp.Group[0].Label) : no default yet - would capture $([IO.Path]::GetFileName($defaultPath)) under -Fix"
        }
    }

    # Patch SOURCE is the frozen default when we have one (reversible rebuild); otherwise the
    # live file itself (legacy / pre-capture report). Reported changes read 'default -> override'.
    $srcFile = if ($haveDefault) { $defaultPath } else { $file }
    # Reversible mode rewrites unconditionally (reset-from-default wipes any drift, even when
    # every override already equals the default); legacy mode writes only when a value changed.
    $dirty = $false

    try {
        if ($ext -eq '.xml') {
            $doc = [System.Xml.XmlDocument]::new(); $doc.PreserveWhitespace = $true
            $doc.Load($srcFile)
            foreach ($j in $grp.Group) {
                try { if (Set-XmlNode $doc $j.Selector $j.Value $j.Label) { $dirty = $true } }
                catch { Show-Warn "$($j.Label) : $($_.Exception.Message)" }
            }
            if ($Fix -and ($haveDefault -or $dirty)) { $doc.Save($file) }
        }
        elseif ($ext -eq '.json') {
            $root = Get-Content -Raw -LiteralPath $srcFile | ConvertFrom-Json
            foreach ($j in $grp.Group) {
                try { if (Set-JsonKey $root $j.Selector $j.Value $j.Label) { $dirty = $true } }
                catch { Show-Warn "$($j.Label) : $($_.Exception.Message)" }
            }
            if ($Fix -and ($haveDefault -or $dirty)) {
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
$line = "Config overrides: {0} changed, {1} same-as-default, {2} default(s) captured, {3} warning(s)  [{4}]" -f $stats.Changed, $stats.Same, $stats.Captured, $stats.Warn, $tag
if ($stats.Warn -gt 0) { Write-Host $line -ForegroundColor Yellow } else { Write-Host $line -ForegroundColor Green }

return [pscustomobject]$stats
