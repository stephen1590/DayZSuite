<#
.SYNOPSIS
  Compose the AI_Bandits mod's flat per-map config from a COMMON layer + per-map PLACEMENTS.

.DESCRIPTION
  The mod reads ONE fixed file (profiles/AI_Bandits/DynamicAIB.json) full of RAW world
  coordinates, with no include/reference mechanism. A single shipped file is therefore only
  ever correct for one map — switch maps and the bandits keep the old map's coords (ocean /
  underground / mid-air spawns).

  So we split the source:
    common/DynamicAIB.common.json   map-agnostic scaffolding: global flags, PredefinedWeapons,
                                    and named loadout kits (npcproperties + class pool).
    maps/<mission>/DynamicAIB.json  per-map PLACEMENTS only: name, coords, size, which kit.
  This script MERGES them into the flat file the mod loads, expanding each placement's
  `size` into that many npcclasses from the kit's pool and inlining the kit's npcproperties.

  StaticAIB has no shared layer worth factoring, so it's a straight per-map copy
  (maps/<mission>/StaticAIB.json -> the flat StaticAIB.json), with an empty-but-valid fallback.

  Run by prestart.sh before each server start with the active mission (real ServerDir, real
  -Fix — that write is the one the mod actually reads, and it lives ONLY on the box, regenerated
  fresh every boot; it is never shipped and never persists locally). FAIL-SOFT: a bad group is
  logged (WARN) and skipped, never aborting the build — and prestart wraps the call in `|| true`
  so it can NEVER block server boot. A map with no per-map file gets an EMPTY file (no bandits),
  never another map's coordinates.

  For a LOCAL look at what would be built (e.g. -ServerDir './deploy' to preview against this
  repo), don't use -Fix — that writes inside deploy/profiles/AI_Bandits/, which looks like a
  shipped source but isn't (confusing). Use -PreviewOut <path> instead: writes the composed
  DynamicAIB JSON to that exact file, any location you choose, regardless of -Fix.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerDir,
    [string]$Mission,
    [Alias('Apply')][switch]$Fix,
    [string]$PreviewOut   # also write the composed DynamicAIB JSON here (any path) - for local inspection only
)

$ErrorActionPreference = 'Stop'

$aiRoot = Join-Path $ServerDir 'profiles/AI_Bandits'

# Resolve the active mission the same way the engine does (map.env), unless one was passed.
if (-not $Mission) {
    $mapEnv = Join-Path $ServerDir 'map.env'
    if (Test-Path $mapEnv) {
        $m = Select-String -LiteralPath $mapEnv -Pattern '^\s*DAYZ_MISSION=(.+)$' | Select-Object -First 1
        if ($m) { $Mission = $m.Matches[0].Groups[1].Value.Trim() }
    }
    if (-not $Mission) { $Mission = 'dayzOffline.chernarusplus' }
}

$stats = [ordered]@{ Groups = 0; Snipers = 0; Overlaid = 0; Created = 0; CreatedBase = 0; Removed = 0; Warn = 0 }
function Show-Warn($m) { $script:stats.Warn++; Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Show-Info($m) { Write-Host $m }
function Read-Json($path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json }

# Set a property on a PSCustomObject whether or not it already exists (ConvertFrom-Json
# objects have no property we didn't parse). Used by the VPP overlay to add/replace pos etc.
function Set-Prop($obj, [string]$name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

# Overlay a per-map PLACEMENT onto a named common TEMPLATE: the placement wins on any field it
# sets (non-null), the template supplies the rest. This is how one global squad/sniper definition
# is reused across maps while a single placement can still tweak a field (accuracy, weapon, size).
# '_readme' keys in templates are documentation only and never merged.
function Merge-Template($placement, $template) {
    $eff = [ordered]@{}
    if ($template) { foreach ($p in $template.PSObject.Properties) { if ($p.Name -ne '_readme') { $eff[$p.Name] = $p.Value } } }
    foreach ($p in $placement.PSObject.Properties) { if ($null -ne $p.Value) { $eff[$p.Name] = $p.Value } }
    [pscustomobject]$eff
}

# --- DynamicAIB: merge common + per-map placements ----------------------------------------
$commonPath = Join-Path $aiRoot 'common/DynamicAIB.common.json'
$mapPath    = Join-Path $aiRoot "maps/$Mission/DynamicAIB.json"
$outPath    = Join-Path $aiRoot 'DynamicAIB.json'

if (-not (Test-Path $commonPath)) {
    Show-Warn "no common/DynamicAIB.common.json under $aiRoot - cannot build DynamicAIB; leaving any existing flat file untouched."
} else {
    $common = Read-Json $commonPath
    $groupsSpec = @()
    $native = $false
    if (Test-Path $mapPath) {
        $mapDoc = Read-Json $mapPath
        $hasOurs   = ($mapDoc.PSObject.Properties.Name -contains 'groups') -and $mapDoc.groups
        $hasNative = $mapDoc.PSObject.Properties.Name -contains 'GroupLocations'
        if ($hasNative -and -not $hasOurs) {
            # NATIVE PASSTHROUGH: this per-map file is ALREADY a full mod-format DynamicAIB (a
            # drop-in community config like scalespeeder's Chernarus set) - it has GroupLocations,
            # not our 'groups' schema. Copy it VERBATIM (preserves its snipers / per-group loadouts
            # / PredefinedWeapons); do NOT compose against common. This is how a community full-file
            # coexists with our compose model on other maps.
            $native = $true
            Show-Info "DynamicAIB[$Mission]: native full-file passthrough - $(@($mapDoc.GroupLocations).Count) group(s), $(@($mapDoc.SniperLocations).Count) sniper(s)$(if (-not $Fix) { ' (report-only)' })."
            if ($Fix) {
                New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                Copy-Item -LiteralPath $mapPath -Destination $outPath -Force
            }
        } elseif ($hasOurs) {
            $groupsSpec = @($mapDoc.groups)
        }
    } else {
        Show-Info "no per-map DynamicAIB for '$Mission' - building an EMPTY groups file (no bandits; safe fallback)."
    }

    # --- VPP coordinate OVERLAY (non-destructive) -----------------------------------------
    # Update matching placements IN MEMORY from the VPP teleport captures pulled by
    # Sync-VPPCoordinates.ps1. The authored maps/*.json on disk is NEVER rewritten - we only
    # mutate the parsed $groupsSpec before composing. Match is by the FULL VPP name (RawName
    # == group .name) - placements are named for their VPP bookmark. CoordinateOnly updates
    # ONLY the coords; Classified also overrides template + size. VPP is the sole source of
    # truth: every bookmark for this map ends up as a group, no hand-authored entry required.
    # The composed set MIRRORS the VPP bookmarks for this map (a 3-way sync), so a deleted
    # bookmark can't leave a stale group with lingering waypoints:
    #   * VPP entry, no group   -> CREATE  (Classified: category gives it a real template+size.
    #                              CoordinateOnly/bare <Map>_<Name>: created as a base 'holdout'.)
    #   * VPP entry + group     -> UPDATE  (coords always; Classified also overrides template+size)
    #   * group, no VPP entry   -> REMOVE  (dropped from this build's output)
    # IN MEMORY only - the authored maps/*.json on disk is never written, so REMOVE just excludes
    # the group from the generated flat file; the source group is preserved for reference.
    # GUARDRAIL: the mirror (incl. removal) runs ONLY when VPP has >=1 spawn entry for this map,
    # so an empty/stale vpp-coordinates.json can never silently wipe every spawn.
    # FAIL-SOFT: missing classification.json or vpp-coordinates.json => no overlay at all.
    $clsPath = Join-Path $aiRoot 'common/classification.json'
    $vppPath = Join-Path $ServerDir 'profiles/VPPAdminTools/VPPCoordinates/vpp-coordinates.json'
    if (-not $native -and (Test-Path $clsPath) -and (Test-Path $vppPath)) {
        $cls     = Read-Json $clsPath
        # Map letter(s) for this mission = classification.maps keys whose value == $Mission.
        $letters = @($cls.maps.PSObject.Properties | Where-Object { $_.Value -eq $Mission } | ForEach-Object { $_.Name })
        $mapVpp  = @(Read-Json $vppPath | Where-Object { $_.Kind -ne 'NonSpawn' -and ($letters -contains $_.Map) })
        if ($letters.Count -and $mapVpp.Count) {
            $byName = @{}
            foreach ($g in $groupsSpec) { if ($g.name) { $byName[[string]$g.name] = $g } }
            $keep = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($r in $mapVpp) {
                $g = $byName[[string]$r.RawName]
                if ($g) {
                    Set-Prop $g 'pos' $r.Pos
                    if ($g.PSObject.Properties['waypoints']) { $g.PSObject.Properties.Remove('waypoints') }
                    if ($r.Kind -eq 'Classified') {
                        Set-Prop $g 'template' ([string]$cls.categories.$($r.Category))
                        # Size is OPTIONAL on the bookmark; only override when one was given, else the
                        # template's default size (via Merge-Template) stands.
                        if ($r.Size) { Set-Prop $g 'size' ([int]$cls.sizes.$($r.Size)) }
                    }
                    [void]$keep.Add([string]$r.RawName)
                    $script:stats.Overlaid++
                }
                elseif ($r.Kind -eq 'Classified') {
                    # Build a placement from the bookmark; omit 'size' when none was given so the
                    # template default applies (a 'size' of 0 would be skipped by the compose loop).
                    $new = [pscustomobject]@{
                        name     = $r.RawName
                        template = [string]$cls.categories.$($r.Category)
                        pos      = $r.Pos
                    }
                    if ($r.Size) { Set-Prop $new 'size' ([int]$cls.sizes.$($r.Size)) }
                    $groupsSpec += $new
                    $byName[$r.RawName] = $new              # so a duplicate bookmark updates, not re-adds
                    [void]$keep.Add([string]$r.RawName)
                    $script:stats.Created++
                }
                else {
                    # CoordinateOnly (bare <Map>_<Name>) with no authored group: VPP is the sole
                    # source, so this becomes a base 'holdout' group unconditionally - not a
                    # configurable/guessed fallback. Give the bookmark a category token (e.g.
                    # rename S_Vostok to S_Scav_Vostok) to make it something other than a holdout.
                    $new = [pscustomobject]@{
                        name     = $r.RawName
                        template = 'holdout'
                        pos      = $r.Pos
                    }
                    $groupsSpec += $new
                    $byName[$r.RawName] = $new
                    [void]$keep.Add([string]$r.RawName)
                    $script:stats.CreatedBase++
                }
            }
            # REMOVE extras: any authored group not backed by a VPP bookmark this build.
            foreach ($x in @($groupsSpec | Where-Object { -not ($_.name -and $keep.Contains([string]$_.name)) })) {
                Show-Info "  removed (no VPP bookmark): $($x.name)"
                $script:stats.Removed++
            }
            $groupsSpec = @($groupsSpec | Where-Object { $_.name -and $keep.Contains([string]$_.name) })
            Show-Info "DynamicAIB[$Mission]: VPP mirror -> $($stats.Overlaid) updated, $($stats.Created) created, $($stats.CreatedBase) created as base holdouts, $($stats.Removed) removed."
        }
    }

    if (-not $native) {
        $groupLocations = @()
        $templateByName = @{}   # name -> template, for the preview table only (never written to the composed JSON)
        foreach ($g in $groupsSpec) {
            try {
                # A placement may reference a global groupTemplate and inherit its fields; any field
                # set on the placement overrides. Placements with no 'template' work as before.
                $tmpl = $null
                if ($g.template) {
                    $tmpl = $common.groupTemplates.$($g.template)
                    if (-not $tmpl) { Show-Warn "group '$($g.name)': template '$($g.template)' not in common.groupTemplates - skipped."; continue }
                }
                $e = if ($tmpl) { Merge-Template $g $tmpl } else { $g }

                $kit = $common.loadouts.$($e.loadout)
                if (-not $kit) { Show-Warn "group '$($g.name)': loadout '$($e.loadout)' not defined in common.loadouts - skipped."; continue }
                $size = [int]$e.size
                $pool = @($kit.classes)
                if ($size -lt 1)        { Show-Warn "group '$($g.name)': size < 1 - skipped."; continue }
                if ($pool.Count -eq 0)  { Show-Warn "group '$($g.name)': loadout '$($e.loadout)' has no classes - skipped."; continue }
                $npcclasses = @(for ($i = 0; $i -lt $size; $i++) { $pool[$i % $pool.Count] })

                # @(...) around the whole if is required: capturing a single-element array from an
                # if-expression ($x = if(){@($e.pos)}) unwraps it to a scalar, and the mod needs an array.
                $waypoints = @( if ($e.waypoints) { $e.waypoints } elseif ($e.pos) { $e.pos } )
                if ($waypoints.Count -eq 0) { Show-Warn "group '$($g.name)': no 'pos' or 'waypoints' - skipped."; continue }

                $groupLocations += [ordered]@{
                    name          = $e.name
                    faction       = if ($e.faction) { $e.faction } else { 'Bandits' }
                    waypoints     = $waypoints
                    npcclasses    = $npcclasses
                    accuracy      = if ($null -ne $e.accuracy) { $e.accuracy } else { 70 }
                    grenadechance = if ($null -ne $e.grenadechance) { $e.grenadechance } else { 0.0 }
                    dog           = if ($null -ne $e.dog) { 0 }#[int]$e.dog } else { 0 }
                    weaponpool    = @($e.weapon)
                    npcproperties = $kit.npcproperties
                }
                $templateByName[$e.name] = if ($g.template) { $g.template } else { '(none)' }
                $script:stats.Groups++
            } catch { Show-Warn "group '$($g.name)': $($_.Exception.Message) - skipped." }
        }

        # SniperLocations: per-map 'snipers[]' referencing a global sniperTemplate + firing spots.
        $sniperLocations = @()
        $snipersSpec = @( if ($mapDoc -and ($mapDoc.PSObject.Properties.Name -contains 'snipers')) { $mapDoc.snipers } )
        foreach ($s in $snipersSpec) {
            try {
                $tmpl = $null
                if ($s.template) {
                    $tmpl = $common.sniperTemplates.$($s.template)
                    if (-not $tmpl) { Show-Warn "sniper '$($s.name)': template '$($s.template)' not in common.sniperTemplates - skipped."; continue }
                }
                $e = if ($tmpl) { Merge-Template $s $tmpl } else { $s }

                $kit = $common.loadouts.$($e.loadout)
                if (-not $kit) { Show-Warn "sniper '$($s.name)': loadout '$($e.loadout)' not defined in common.loadouts - skipped."; continue }
                $positions = @( if ($e.positions) { $e.positions } )
                if ($positions.Count -eq 0) { Show-Warn "sniper '$($s.name)': no 'positions' - skipped."; continue }

                $sniperLocations += [ordered]@{
                    name          = $e.name
                    positions     = $positions
                    npcclass      = if ($e.npcclass) { $e.npcclass } else { 'BanditAI_Keiko' }
                    accuracy      = if ($null -ne $e.accuracy) { $e.accuracy } else { 75 }
                    fixedpos      = if ($null -ne $e.fixedpos) { [int]$e.fixedpos } else { 1 }
                    triggerpos    = if ($e.triggerpos) { $e.triggerpos } else { $positions[0] }
                    weaponpool    = @($e.weapon)
                    npcproperties = $kit.npcproperties
                }
                $script:stats.Snipers++
            } catch { Show-Warn "sniper '$($s.name)': $($_.Exception.Message) - skipped." }
        }

        $out = [ordered]@{
            version           = $common.flags.version
            showtriggers      = $common.flags.showtriggers
            cleanzerovector   = $common.flags.cleanzerovector
            crashsitegroup    = $common.flags.crashsitegroup
            cardamage         = $common.flags.cardamage
            GroupLocations    = $groupLocations
            SniperLocations   = $sniperLocations
            PredefinedWeapons = @($common.weapons)
        }

        # Always show the composed result, not just counts - this IS the dry run: a report-only
        # run must be enough to judge the outcome without needing -Fix or a deploy to see it.
        if ($groupLocations.Count) {
            $groupLocations |
                ForEach-Object { [pscustomobject]@{ Name = $_.name; Template = $templateByName[$_.name]; Faction = $_.faction; Size = @($_.npcclasses).Count; Pos = @($_.waypoints)[0] } } |
                Sort-Object Name | Format-Table -AutoSize | Out-Host
        }
        Show-Info "DynamicAIB[$Mission]: $($stats.Groups) group(s), $($stats.Snipers) sniper(s), $($stats.Warn) warning(s)$(if (-not $Fix) { ' (report-only)' })."
        $json = $null
        if ($Fix -or $PreviewOut) { $json = $out | ConvertTo-Json -Depth 100 }
        if ($Fix) {
            New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
            $json | Set-Content -LiteralPath $outPath -Encoding utf8
        }
        if ($PreviewOut) {
            New-Item -ItemType Directory -Force -Path (Split-Path $PreviewOut) | Out-Null
            $json | Set-Content -LiteralPath $PreviewOut -Encoding utf8
            Show-Info "DynamicAIB[$Mission]: preview written to $PreviewOut"
        }
    }
}

# --- StaticAIB: straight per-map copy; empty-but-valid fallback ----------------------------
$staticMap = Join-Path $aiRoot "maps/$Mission/StaticAIB.json"
$staticOut = Join-Path $aiRoot 'StaticAIB.json'
if (Test-Path $staticMap) {
    if ($Fix) { Copy-Item $staticMap $staticOut -Force }
    Show-Info "StaticAIB[$Mission]: from maps/$Mission/StaticAIB.json$(if (-not $Fix) { ' (report-only)' })."
} else {
    if ($Fix) {
        ([ordered]@{ NPCDebug = 0; version = 1; NPCLocations = @(); PredefinedWeapons = @() } |
            ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $staticOut -Encoding utf8
    }
    Show-Info "StaticAIB[$Mission]: none for this map - empty file$(if (-not $Fix) { ' (report-only)' })."
}

[pscustomobject]$stats
