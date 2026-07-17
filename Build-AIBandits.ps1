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

  MASTER OFF SWITCH: common/DynamicAIB.common.json -> flags.useSpawnLocations. Default ENABLED
  (also the default when the key is absent). Set it to 0 to emit EMPTY Dynamic + Static files —
  no bandits anywhere, "effectively no mod" — WITHOUT deleting any authored placement, so it is
  fully reversible (flip back to 1). The common file is already the "Aib-common" item in the
  Server Files UI (an existing config-overrides target), so this flag is editable there with no
  new files or allowlist changes. The mod stays loaded; to unload it entirely, comment its lines
  in deploy/mods.conf instead.

  PER-TYPE OFF SWITCH: common/DynamicAIB.common.json -> flags.spawnTypes, a map of
  groupTemplate/sniperTemplate NAME -> 0/1 (missing or 1 = spawn normally; 0 = every placement of
  that type emits no bandits). Finer-grained than useSpawnLocations - kill just 'sniper' or just
  'raider_heavy' while the rest spawn. Reversible (flip back to 1), authored placements untouched,
  builder-read only (stripped from the composed file), and editable in the same 'Aib-common' UI
  item. Does NOT affect native full-file maps (raw GroupLocations have no templates to gate) - the
  build logs that explicitly so it is never a silent no-op.

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

$stats = [ordered]@{ Groups = 0; Snipers = 0; Overlaid = 0; Created = 0; CreatedBase = 0; Removed = 0; SkippedType = 0; Warn = 0 }
function Show-Warn($m) { $script:stats.Warn++; Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Show-Info($m) { Write-Host $m }
function Read-Json($path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json }

# Compose a mod-format "X Y Z" waypoint string from numeric coords, invariant culture so a
# non-US locale can't emit comma decimals the engine would misread.
function Format-Pos($x, $y, $z) {
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    '{0} {1} {2}' -f ([double]$x).ToString($ci), ([double]$y).ToString($ci), ([double]$z).ToString($ci)
}

# Set a property on a PSCustomObject whether or not it already exists (ConvertFrom-Json
# objects have no property we didn't parse). Used by the spawn-points overlay to add/replace pos etc.
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

# MASTER on/off for AI spawns (default ENABLED = "use spawn locations"). Set from the common
# file's flags.useSpawnLocations, read below. Initialised here so the StaticAIB pass - which runs
# outside the common block - still honours it, and so a MISSING common defaults to ENABLED
# (unchanged behaviour), never a silent force-empty.
$spawnsEnabled = $true

# --- DynamicAIB: merge common + per-map placements ----------------------------------------
$commonPath = Join-Path $aiRoot 'common/DynamicAIB.common.json'
$mapPath    = Join-Path $aiRoot "maps/$Mission/DynamicAIB.json"
$outPath    = Join-Path $aiRoot 'DynamicAIB.json'

if (-not (Test-Path $commonPath)) {
    Show-Warn "no common/DynamicAIB.common.json under $aiRoot - cannot build DynamicAIB; leaving any existing flat file untouched."
} else {
    $common = Read-Json $commonPath
    # flags.useSpawnLocations = 0 -> emit EMPTY Dynamic + Static (no bandits, reversible); absent
    # or non-zero -> compose placements as normal. Authored placements are never deleted.
    if ($common.flags -and $null -ne $common.flags.useSpawnLocations) { $spawnsEnabled = ([int]$common.flags.useSpawnLocations -ne 0) }
    # Per-TYPE spawn toggle (finer than the master switch): flags.spawnTypes maps a
    # groupTemplate/sniperTemplate NAME -> 0/1. Missing key or non-zero = spawn normally; 0 =
    # every placement of that type emits nothing (reversible; authored placement kept). Builder-
    # read only - never copied into the composed file (like useSpawnLocations). '_readme' is docs.
    $typeEnabled = @{}
    if ($common.flags -and $common.flags.spawnTypes) {
        foreach ($tp in $common.flags.spawnTypes.PSObject.Properties) {
            if ($tp.Name -eq '_readme') { continue }
            $typeEnabled[[string]$tp.Name] = ([int]$tp.Value -ne 0)
        }
    }
    $disabledTypes = @($typeEnabled.Keys | Where-Object { -not $typeEnabled[$_] } | Sort-Object)
    $groupsSpec = @()
    $native = $false
    if (-not $spawnsEnabled) {
        # DISABLED: leave $mapDoc unread ($null) and $groupsSpec empty. The overlay is also
        # gated below, so spawn-points can't re-create groups. The normal composition path then
        # writes a valid file with empty GroupLocations/SniperLocations - no bandits.
        Show-Info "DynamicAIB[$Mission]: AI spawns DISABLED (flags.useSpawnLocations = 0) - emitting EMPTY file; authored placements untouched$(if (-not $Fix) { ' (report-only)' })."
    } elseif (Test-Path $mapPath) {
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
            if ($disabledTypes.Count) { Show-Info "DynamicAIB[$Mission]: NOTE - flags.spawnTypes ($($disabledTypes -join ', ')) does NOT apply to a native full-file map (raw GroupLocations, no templates to gate)." }
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

    # --- spawn-points OVERLAY (non-destructive) -------------------------------------------
    # spawn-points.json is the DEFINITIVE spawn store: box/web-edited (seeded once from the last
    # VPP snapshot in 2026-07; the ConfigViewer Map tab is the editor). Update/create placements IN
    # MEMORY from it; the authored maps/*.json on disk is NEVER rewritten - we only mutate the
    # parsed $groupsSpec before composing. Match is by name (point .name == group .name, the
    # stable unique key). A point with a 'category' sets template (+ 'size' when given); a point
    # with none becomes a base 'holdout':
    #   * point, no group   -> CREATE  (category -> real template+size; else a base 'holdout')
    #   * point + group     -> UPDATE  (coords always; category also overrides template+size)
    # Unlike the retired VPP mirror this is a UNION/UPSERT - it NEVER removes authored groups,
    # because the file is now hand-edited, not a live 1:1 pull that could legitimately delete.
    # FAIL-SOFT: missing classification.json or spawn-points.json => no overlay at all.
    $clsPath   = Join-Path $aiRoot 'common/classification.json'
    $spawnPath = Join-Path $aiRoot 'spawn-points.json'
    if ($spawnsEnabled -and -not $native -and (Test-Path $clsPath) -and (Test-Path $spawnPath)) {
        $cls     = Read-Json $clsPath
        # Map letter(s) for this mission = classification.maps keys whose value == $Mission.
        $letters = @($cls.maps.PSObject.Properties | Where-Object { $_.Value -eq $Mission } | ForEach-Object { $_.Name })
        $spawnDoc = Read-Json $spawnPath
        $mapPts   = @($spawnDoc.points | Where-Object { $letters -contains $_.map })
        if ($letters.Count -and $mapPts.Count) {
            $byName = @{}
            foreach ($g in $groupsSpec) { if ($g.name) { $byName[[string]$g.name] = $g } }
            foreach ($p in $mapPts) {
                $pos = Format-Pos $p.x $p.y $p.z
                $g   = $byName[[string]$p.name]
                if ($g) {
                    Set-Prop $g 'pos' $pos
                    if ($g.PSObject.Properties['waypoints']) { $g.PSObject.Properties.Remove('waypoints') }
                    if ($p.category) {
                        Set-Prop $g 'template' ([string]$cls.categories.$($p.category))
                        # Size is OPTIONAL; only override when one was given, else the template's
                        # default size (via Merge-Template) stands.
                        if ($p.size) { Set-Prop $g 'size' ([int]$cls.sizes.$($p.size)) }
                    }
                    $script:stats.Overlaid++
                }
                else {
                    # No authored group of this name: create one. A category token gives it a real
                    # template (+ size); without one it becomes a base 'holdout' - give the point a
                    # category (e.g. Scav) in the editor to make it something other than a holdout.
                    $tmpl = if ($p.category) { [string]$cls.categories.$($p.category) } else { 'holdout' }
                    $new  = [pscustomobject]@{ name = [string]$p.name; template = $tmpl; pos = $pos }
                    if ($p.category -and $p.size) { Set-Prop $new 'size' ([int]$cls.sizes.$($p.size)) }
                    $groupsSpec += $new
                    $byName[[string]$p.name] = $new          # a duplicate-named point updates, not re-adds
                    if ($p.category) { $script:stats.Created++ } else { $script:stats.CreatedBase++ }
                }
            }
            Show-Info "DynamicAIB[$Mission]: spawn-points -> $($stats.Overlaid) updated, $($stats.Created) created, $($stats.CreatedBase) created as base holdouts."
        }
    }

    if (-not $native) {
        $groupLocations = @()
        $templateByName = @{}   # name -> template, for the preview table only (never written to the composed JSON)
        $skippedByType  = @()   # placements dropped by flags.spawnTypes (kind/name/type), for the report
        foreach ($g in $groupsSpec) {
            try {
                # Per-type toggle: a placement whose template is switched off in flags.spawnTypes
                # emits nothing. Reversible - flip the type back to 1. Authored placement untouched.
                if ($g.template -and $typeEnabled.ContainsKey([string]$g.template) -and -not $typeEnabled[[string]$g.template]) {
                    $script:stats.SkippedType++
                    $skippedByType += [pscustomobject]@{ Kind = 'group'; Name = [string]$g.name; Type = [string]$g.template }
                    continue
                }
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
                # Per-type toggle (same as groups) for sniper-nest templates.
                if ($s.template -and $typeEnabled.ContainsKey([string]$s.template) -and -not $typeEnabled[[string]$s.template]) {
                    $script:stats.SkippedType++
                    $skippedByType += [pscustomobject]@{ Kind = 'sniper'; Name = [string]$s.name; Type = [string]$s.template }
                    continue
                }
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
        if ($skippedByType.Count) {
            Show-Info "DynamicAIB[$Mission]: $($skippedByType.Count) placement(s) skipped by flags.spawnTypes (off: $($disabledTypes -join ', ')):"
            $skippedByType | Sort-Object Kind, Name | Format-Table -AutoSize | Out-Host
        }
        Show-Info "DynamicAIB[$Mission]: $($stats.Groups) group(s), $($stats.Snipers) sniper(s), $($stats.SkippedType) skipped by type, $($stats.Warn) warning(s)$(if (-not $Fix) { ' (report-only)' })."
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
if ($spawnsEnabled -and (Test-Path $staticMap)) {
    if ($Fix) { Copy-Item $staticMap $staticOut -Force }
    Show-Info "StaticAIB[$Mission]: from maps/$Mission/StaticAIB.json$(if (-not $Fix) { ' (report-only)' })."
} else {
    if ($Fix) {
        ([ordered]@{ NPCDebug = 0; version = 1; NPCLocations = @(); PredefinedWeapons = @() } |
            ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $staticOut -Encoding utf8
    }
    $why = if (-not $spawnsEnabled) { 'AI spawns DISABLED (flags.useSpawnLocations = 0)' } else { 'none for this map' }
    Show-Info "StaticAIB[$Mission]: $why - empty file$(if (-not $Fix) { ' (report-only)' })."
}

[pscustomobject]$stats
