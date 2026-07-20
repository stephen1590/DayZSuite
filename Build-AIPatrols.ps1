#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Compose a mission's Expansion AIPatrolSettings.json from map-points.json - the file that
    ACTUALLY spawns Expansion AI (Faction + Loadout + NumberOfAI + Waypoints per patrol). The
    Expansion twin of Build-AIBandits: a prestart compiler, run per map, driven by the SAME
    map-points store, with an INDEPENDENT on/off switch. Additive - it never touches BanditAI.
.DESCRIPTION
    THE MODEL (mirrors Build-AIBandits / Build-AILocations):
      - map-points.json (profiles/AI_Bandits/, box/web-edited via the Map tab) is the single point
        store shared by both AI systems. Each point opts in via `spawns` (falls back to top-level
        defaultSpawns). THIS builder consumes only points whose effective spawns include 'expansion'
        - so a point can be AIB-only, Expansion-only, both, or neither, independently.
      - CONTROL: profiles/ExpansionMod/AIPatrols.control.json (the 'ExpansionAI-patrols' UI item).
        enabled=0 -> compose the frozen BASE only (no map-point patrols) - the master OFF switch,
        the Expansion equivalent of DynamicAIB.common flags.useSpawnLocations. Reversible; authored
        placements untouched. categoryLoadouts + default* supply per-patrol faction/loadout/size.
      - BASE = the frozen, shipped AIPatrolSettings default (config-defaults/.../AIPatrolSettings
        .defaults.json - the mod's/admin's authored patrols, captured once). We rebuild the live
        file from BASE + our patrols every boot, so the mod's own patrol set is never lost.
      - MERGE (1st pass): KEEP everything - base patrols first, our map-point patrols appended as a
        distinct trailing block (their S_/E_ names don't collide with the base, so dupes line up for
        review). Enabled=0 or zero 'expansion' points -> ours is empty; a mission with zero
        'expansion' points leaves the file completely UNTOUCHED (non-destructive when unused).
      - Per point -> a ROAMING Patrol:
          Name       = point.name
          Faction    = point.faction, else control.defaultFaction ('Raiders')
          Loadout    = point.loadout, else control.categoryLoadouts[point.category], else defaultLoadout
          NumberOfAI = point.count, else classification.sizes[point.size], else defaultNumberOfAI (1)
          Behaviour  = point.behaviour, else control.defaultBehaviour ('ROAMING')
          Waypoints  = [ [x, y, z] ]  (single waypoint + UseRandomWaypointAsStartPoint = spawn+roam)
        All other patrol fields inherit a safe template modelled on the live 'Podgornoye' patrol.
    FAIL-SOFT: no map-points / no classification / no control => leave the file alone.
    NON-DESTRUCTIVE: BanditAI (DynamicAIB/StaticAIB, Build-AIBandits) is never read or written here.

    Read-only by default (reports what -Fix would write). -Fix / -Apply writes the file.
.EXAMPLE
    ./Build-AIPatrols.ps1 -ServerDir ~/servers/dayz-server -Mission dayzOffline.sakhal
.EXAMPLE
    ./Build-AIPatrols.ps1 -ServerDir ~/servers/dayz-server -Mission dayzOffline.sakhal -Fix
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerDir,
    [string]$Mission,
    [Alias('Apply')][switch]$Fix,
    [string]$PreviewOut   # also write the composed AIPatrolSettings JSON here (any path) - local inspection only
)

$ErrorActionPreference = 'Stop'
$aiRoot      = Join-Path $ServerDir 'profiles/AI_Bandits'
$controlPath = Join-Path $ServerDir 'profiles/ExpansionMod/AIPatrols.control.json'

if (-not $Mission) {
    $mapEnv = Join-Path $ServerDir 'map.env'
    if (Test-Path $mapEnv) {
        $m = Select-String -LiteralPath $mapEnv -Pattern '^\s*DAYZ_MISSION=(.+)$' | Select-Object -First 1
        if ($m) { $Mission = $m.Matches[0].Groups[1].Value.Trim() }
    }
    if (-not $Mission) { $Mission = 'dayzOffline.chernarusplus' }
}

$warn = 0
function Show-Warn($m) { $script:warn++; Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Show-Info($m) { Write-Host $m }
function Read-Json($path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json }
# Effective value of an optional property (ConvertFrom-Json objects lack props we didn't parse).
function Get-Prop($obj, [string]$name, $default) {
    if ($obj -and $obj.PSObject.Properties[$name] -and $null -ne $obj.$name) { return $obj.$name }
    return $default
}

# --- sources -------------------------------------------------------------------------------
# The SHARED spawn store: one neutral file feeding BOTH AIB and Expansion, so it is not under any
# one mod's folder. classification.json (the token vocabulary) still lives in AI_Bandits/common.
$pointsPath = Join-Path $ServerDir 'profiles/AI_Shared/map-points.json'
$clsPath = Join-Path $aiRoot 'common/classification.json'
if (-not (Test-Path $pointsPath)) { Show-Info "AIPatrols[$Mission]: no map-points store - nothing to compose."; exit 0 }
if (-not (Test-Path $clsPath))    { Show-Warn "no classification.json - cannot resolve map letters; skipping."; exit 0 }

$doc = Read-Json $pointsPath
$cls = Read-Json $clsPath
$letters = @($cls.maps.PSObject.Properties | Where-Object { $_.Value -eq $Mission } | ForEach-Object { $_.Name })
if (-not $letters.Count) { Show-Info "AIPatrols[$Mission]: no map letters for this mission in classification.json - skipping."; exit 0 }

# --- control (master switch + per-category loadout map + defaults) --------------------------
if (Test-Path $controlPath) { $ctl = Read-Json $controlPath }
else { Show-Warn "no AIPatrols.control.json - Expansion patrols DISABLED (default off when control absent)."; $ctl = [pscustomobject]@{ enabled = 0 } }
$enabled       = ([int](Get-Prop $ctl 'enabled' 0) -ne 0)
$defFaction    = [string](Get-Prop $ctl 'defaultFaction'    'Raiders')
$defLoadout    = [string](Get-Prop $ctl 'defaultLoadout'    'PlayerSurvivorLoadout')
$defBehaviour  = [string](Get-Prop $ctl 'defaultBehaviour'  'ROAMING')
$defNumberOfAI = [int]   (Get-Prop $ctl 'defaultNumberOfAI' 1)
$catLoadouts   = Get-Prop $ctl 'categoryLoadouts' ([pscustomobject]@{})
$sizes         = Get-Prop $cls 'sizes' ([pscustomobject]@{})

# Default system set a point inherits when it declares no `spawns` of its own.
$defaultSpawns = @(Get-Prop $doc 'defaultSpawns' @('aib', 'expansion'))
function Wants-Expansion($p) {
    # Property PRESENT (even an empty array = 'none') is authoritative; ABSENT inherits defaultSpawns.
    $eff = if ($p.PSObject.Properties['spawns']) { @($p.spawns) } else { $defaultSpawns }
    return ($eff -contains 'expansion')
}

$mine = if ($enabled) { @($doc.points | Where-Object { $letters -contains $_.map -and (Wants-Expansion $_) }) } else { @() }
if (-not $enabled) {
    Show-Info "AIPatrols[$Mission]: ExpansionAI map-point spawns DISABLED (control.enabled = 0) - emitting frozen base only; authored patrols untouched$(if (-not $Fix) { ' (report-only)' })."
} elseif (-not $mine.Count) {
    Show-Info "AIPatrols[$Mission]: no 'expansion'-toggled points for this mission - leaving AIPatrolSettings untouched."
    exit 0
}

# --- BASE (frozen snapshot of the mod/admin patrols; ours are appended onto it) ------------
# Rebuild is base + ours every boot, so the base MUST be a STABLE frozen snapshot, never the
# growing live file (that would re-append ours each boot = runaway duplication). An EMPTY default
# (0 patrols) is NOT a valid base - treating it as one would WIPE the authored patrols. So:
#   1. use the first frozen default that actually HAS patrols;
#   2. else, if the LIVE file has authored patrols, CAPTURE them as the frozen base (self-healing,
#      like Apply-ConfigOverrides reversible defaults) - never wipe what someone authored;
#   3. else compose fresh with only our patrols.
$livePath   = Join-Path $ServerDir "mpmissions/$Mission/expansion/settings/AIPatrolSettings.json"
$frozenPath = Join-Path $ServerDir "config-defaults/mpmissions/$Mission/expansion/settings/AIPatrolSettings.defaults.json"
$ourNames   = @($mine | ForEach-Object { [string]$_.name })

$base = $null; $basePatrols = @()
foreach ($c in @($frozenPath, (Join-Path $ServerDir "mpmissions/$Mission/expansion/settings/AIPatrolSettings.defaults.json"))) {
    if (Test-Path $c) {
        $b = Read-Json $c; $bp = @(Get-Prop $b 'Patrols' @())
        if ($bp.Count) { $base = $b; $basePatrols = $bp; Show-Info "AIPatrols[$Mission]: base = frozen default ($($bp.Count) patrols) from $((Split-Path $c -Leaf))."; break }
    }
}
if (-not $base -and (Test-Path $livePath)) {
    $live = Read-Json $livePath; $lp = @(Get-Prop $live 'Patrols' @())
    if ($lp.Count) {
        $base = $live; $basePatrols = $lp
        Show-Warn "no valid frozen base - CAPTURING the $($lp.Count) live patrol(s) as the frozen base$(if (-not $Fix){' (report-only - would capture on -Fix)'} else {" -> $frozenPath"})."
        if ($Fix) { New-Item -ItemType Directory -Force -Path (Split-Path $frozenPath) | Out-Null; ($live | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $frozenPath -Encoding utf8 }
    }
}
if (-not $base) {
    Show-Warn "no base AIPatrolSettings (frozen, live, or captured) for $Mission - composing a fresh file with only our patrols."
    $base = [pscustomobject]@{ Patrols = @() }; $basePatrols = @()
}
# Dedupe the base against OUR names so a re-capture of a live file that already contains our
# patrols can never double-append them (base patrols with DIFFERENT names - the mod's own - are
# kept as intentional pass-1 dupes for review; only exact name collisions with ours are dropped).
$basePatrols = @($basePatrols | Where-Object { $ourNames -notcontains [string]$_.Name })

# --- a full, valid patrol template modelled on the live 'Podgornoye' roaming patrol ---------
# Only Name/Faction/Loadout/NumberOfAI/Behaviour/Waypoints vary per point; the rest are safe
# defaults the mod already runs with, so an emitted patrol is a drop-in of the same shape.
function New-Patrol($name, $faction, $loadout, $number, $behaviour, $waypoints) {
    [ordered]@{
        Name = [string]$name; Persist = 0; Faction = [string]$faction; Formation = ''
        FormationScale = 1.5; FormationLooseness = 0; Loadout = [string]$loadout; Units = @()
        NumberOfAI = [int]$number; NumberOfAIMax = 0; Behaviour = [string]$behaviour
        LootingBehaviour = 'DEFAULT | UPGRADE'; Speed = 'JOG'; UnderThreatSpeed = 'SPRINT'
        DefaultStance = 'STANDING'; DefaultLookAngle = 0; CanBeLooted = 1; LootDropOnDeath = ''
        UnlimitedReload = 1; SniperProneDistanceThreshold = 0; AccuracyMin = -1; AccuracyMax = -1
        ThreatDistanceLimit = -1; NoiseInvestigationDistanceLimit = -1; MaxFlankingDistance = -1
        EnableFlankingOutsideCombat = -1; DamageMultiplier = -1; DamageReceivedMultiplier = -1
        HeadshotResistance = 0; ShoryukenChance = 0; ShoryukenDamageMultiplier = 0
        CanSpawnInContaminatedArea = 0; CanBeTriggeredByAI = 0; MinDistRadius = -1; MaxDistRadius = -1
        DespawnRadius = -1; MinSpreadRadius = 0; MaxSpreadRadius = 0; Chance = 1; DespawnTime = -1
        RespawnTime = -2; LoadBalancingCategory = 'Survivor'; ObjectClassName = ''
        WaypointInterpolation = ''; UseRandomWaypointAsStartPoint = 1; Waypoints = @($waypoints)
    }
}

# --- our points -> Patrol entries ----------------------------------------------------------
$ours = @()
foreach ($p in ($mine | Sort-Object -Property name)) {
    $faction = [string](Get-Prop $p 'faction' $defFaction)
    # Loadout: explicit point.loadout -> category map -> default.
    $loadout = Get-Prop $p 'loadout' $null
    if (-not $loadout -and $p.category) { $loadout = Get-Prop $catLoadouts ([string]$p.category) $null }
    if (-not $loadout) { $loadout = $defLoadout }
    # NumberOfAI: explicit point.count -> size token -> default.
    $number = Get-Prop $p 'count' $null
    if ($null -eq $number -and $p.PSObject.Properties['size'] -and $p.size) { $number = Get-Prop $sizes ([string]$p.size) $null }
    if ($null -eq $number) { $number = $defNumberOfAI }
    $behaviour = [string](Get-Prop $p 'behaviour' $defBehaviour)
    $loadout   = [string]$loadout
    $wp = @(, @([double]$p.x, [double]$p.y, [double]$p.z))
    $ours += [pscustomobject](New-Patrol $p.name $faction $loadout ([int]$number) $behaviour $wp)
}

# --- merge + compose (base first, ours appended - lined up for review) ---------------------
$out = $base
$allPatrols = @($basePatrols + $ours)
if ($out.PSObject.Properties['Patrols']) { $out.Patrols = $allPatrols }
else { $out | Add-Member -NotePropertyName Patrols -NotePropertyValue $allPatrols }

# The mod's OWN top-level gate (AIPatrolSettings.Enabled). control.enabled is the single
# authority for "do map-point patrols run": when it's ON and we have patrols, GUARANTEE the mod
# actually runs them, so a base captured while Enabled=0 can never silently defeat the toggle.
# When disabled we leave the base's Enabled untouched (the authored base keeps whatever it had).
if ($enabled -and $allPatrols.Count) {
    if ($out.PSObject.Properties['Enabled']) { $out.Enabled = 1 }
    else { $out | Add-Member -NotePropertyName Enabled -NotePropertyValue 1 }
}

$json = $out | ConvertTo-Json -Depth 20
Show-Info "AIPatrols[$Mission]: base $($basePatrols.Count) + $($ours.Count) map-point patrol(s) = $($allPatrols.Count) total$(if (-not $Fix) { ' (report-only)' })."
if ($ours.Count) {
    $ours |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Faction = $_.Faction; Loadout = $_.Loadout; N = $_.NumberOfAI; Behaviour = $_.Behaviour; Pos = ('{0:n0} {1:n0}' -f $_.Waypoints[0][0], $_.Waypoints[0][2]) } } |
        Sort-Object Name | Format-Table -AutoSize | Out-Host
}

if ($PreviewOut) { New-Item -ItemType Directory -Force -Path (Split-Path $PreviewOut) | Out-Null; Set-Content -LiteralPath $PreviewOut -Value $json -Encoding utf8; Show-Info "  preview -> $PreviewOut" }
if ($Fix) {
    New-Item -ItemType Directory -Force -Path (Split-Path $livePath) | Out-Null
    Set-Content -LiteralPath $livePath -Value $json -Encoding utf8
    Show-Info "  wrote $livePath"
} elseif (-not $PreviewOut) {
    Show-Info "  (dry-run - re-run with -Fix to write $livePath)"
}
if ($warn) { Show-Info "AIPatrols[$Mission]: $warn warning(s)." }
exit 0
