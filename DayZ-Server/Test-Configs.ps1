#requires -version 7
<#
.SYNOPSIS
    PRE-DEPLOY test: build the real config artifacts OFFLINE from the repo mirrors and assert
    they are correct - before anything ships. No box access, no writes to prod.
.DESCRIPTION
    "Box builds, dev validates" done properly: not a prediction, an actual build. The box
    rebuilds every patched file as frozen-default + override patches at prestart, then composes
    the AI-bandit configs. Dev has the same inputs (config-defaults/ baselines + config-overrides.json
    + the AI_Bandits source tree + spawn-points + Babaku sources + the custom-CE manifest) and
    the SAME engines the box runs at prestart (Apply-ConfigOverrides, Build-AIBandits,
    Build-BabakuSpawns, Apply-CustomCE, Build-TransferSpawns). So this stages a throwaway ServerDir
    from the mirrors, runs the ACTUAL build chain against it, and validates the produced artifacts.
    If it passes, the live deploy runs the identical scripts on the identical inputs — the result
    is already known.

    This is the GATE. Run it (after Pull-Configs refreshes the mirrors from the box) before a
    -Fix deploy. Confirm-LiveConfigs.ps1 is the AFTER: it confirms the running server matches.

    Staging is reconstructed exactly as the box builds:
      - every config-defaults/<rel> baseline is placed at its live path (as both the frozen
        <stem>.defaults<ext> AND a live <stem><ext> for the engine to rebuild) - identical to
        the box's reversible-default rebuild.
      - registry seed rows WITHOUT a captured baseline (classification, StaticAIB, Babaku,
        messages) are placed from their repo seed - identical to a box that has them.
    Then per declared mission, the full prestart config chain: Apply-ConfigOverrides -Fix
    (force-create), Build-AIBandits, Build-BabakuSpawns, Apply-CustomCE, Build-TransferSpawns.

    Two prestart inputs are GAME-OWNED mission files (cfgeconomycore.xml, cfgplayerspawnpoints.xml)
    that a game update rewrites and prestart re-derives - so they are not mirrored. The gate stages
    real-shaped test/fixtures/ copies to run Apply-CustomCE + Build-TransferSpawns against, which
    proves the ENGINES are sound. The live mission-file shape is confirmed AFTER by
    Confirm-LiveConfigs.ps1, not here.

    Read-only w.r.t. the repo and the box: only the throwaway staging dir is written. Exit 0 =
    green (safe to deploy), 1 = a real problem to fix first.
.EXAMPLE
    ./Test-Configs.ps1                 # build + validate offline, all declared missions
.EXAMPLE
    ./Test-Configs.ps1 -KeepStaging    # leave the staged ServerDir for inspection
#>
[CmdletBinding()]
param(
    [string]$OverridesDoc = (Join-Path $PSScriptRoot "config-overrides.json"),   # test a candidate doc without touching the mirror
    [string]$StagingDir,
    [switch]$KeepStaging,
    [switch]$NoLog
)

. (Join-Path $PSScriptRoot "../../../common/Utils.ps1")

$script:pass = 0; $script:fail = 0
function Show-Pass([string]$m) { $script:pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function Show-Fail([string]$m) { $script:fail++; Write-Host "  [FAIL] $m" -ForegroundColor Red }

$defaultsDir  = Join-Path $PSScriptRoot "config-defaults"
$overridesDoc = $OverridesDoc
$registryPath = Join-Path $PSScriptRoot "config-registry.json"
$deployDir    = Join-Path $PSScriptRoot "deploy"
foreach ($p in @($defaultsDir, $overridesDoc, $registryPath)) {
    if (-not (Test-Path $p)) { Write-Error "missing mirror/input: $p (run Pull-Configs.ps1 -Execute first)"; exit 2 }
}
if (-not $StagingDir) {
    $base = if ($env:CLAUDE_SCRATCH) { $env:CLAUDE_SCRATCH } else { Join-Path ([IO.Path]::GetTempPath()) "dayz-config-test" }
    $StagingDir = Join-Path $base "staging-serverdir"
}

# --- Stage a throwaway ServerDir from the mirrors, exactly as the box rebuilds ---------------
if (Test-Path $StagingDir) { Remove-Item -Recurse -Force $StagingDir }
New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null
Write-Host "Staging a throwaway ServerDir from the repo mirrors -> $StagingDir" -ForegroundColor Cyan

# Pass 1: every captured baseline -> live path (both the .defaults AND a live sibling to rebuild).
$stagedDefaults = 0
foreach ($f in @(Get-ChildItem -Path $defaultsDir -Recurse -File | Where-Object Name -ne 'README.md')) {
    $rel  = $f.FullName.Substring($defaultsDir.Length).TrimStart('/', '\')          # e.g. profiles/.../X.defaults.json
    $ext  = [IO.Path]::GetExtension($rel)
    $stem = [IO.Path]::GetFileNameWithoutExtension($rel)                            # X.defaults
    if ($stem.EndsWith('.defaults')) { $stem = $stem.Substring(0, $stem.Length - '.defaults'.Length) }
    $dir      = Split-Path -Parent $rel
    $liveRel  = if ($dir) { Join-Path $dir "$stem$ext" } else { "$stem$ext" }       # X.json
    $defDst   = Join-Path $StagingDir $rel
    $liveDst  = Join-Path $StagingDir $liveRel
    New-Item -ItemType Directory -Force -Path (Split-Path $defDst) | Out-Null
    Copy-Item $f.FullName $defDst  -Force          # the frozen baseline
    Copy-Item $f.FullName $liveDst -Force          # a live file for the engine to overwrite = default + patches
    $stagedDefaults++
}

# Pass 2: registry seed rows with NO captured baseline -> place from the repo seed.
$stagedSeeds = 0
$surfaces = @((Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json).surfaces | Where-Object { $_.seed })
foreach ($s in $surfaces) {
    $ext  = [IO.Path]::GetExtension($s.box)
    $stem = [IO.Path]::GetFileNameWithoutExtension($s.box)
    $bdir = Split-Path -Parent $s.box
    $defRel = if ($bdir) { Join-Path $bdir "$stem.defaults$ext" } else { "$stem.defaults$ext" }
    if (Test-Path (Join-Path $defaultsDir $defRel)) { continue }                    # has a baseline -> pass 1 covered it
    $src = Join-Path $PSScriptRoot $s.seed
    if (-not (Test-Path $src)) { continue }
    $dst = Join-Path $StagingDir $s.box
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item $src $dst -Force
    $stagedSeeds++
}
Write-Host "  staged $stagedDefaults baseline target(s) + $stagedSeeds seed-only file(s)"

# Declared, on-disk missions (same rule the applier uses: mpmissions.<mission> manifest keys).
$mf = Get-Content -Raw -LiteralPath $overridesDoc | ConvertFrom-Json
$declared = @()
if ($mf.PSObject.Properties.Name -contains 'mpmissions') {
    $declared = @($mf.mpmissions.PSObject.Properties.Name | Where-Object { $_ -ne 'common' -and -not $_.StartsWith('_') })
}
$missions = @($declared | Where-Object { Test-Path (Join-Path $StagingDir "mpmissions/$_") })

# Pass 3: prestart-engine inputs that are NOT box-mirrored config.
#   - custom-ce/ (manifest + our own types source) ships from deploy/ as CODE; stage it so
#     Apply-CustomCE has its manifest. Mod-owned sources (@aibandits, @dayzdog) aren't present
#     offline -> skipped fail-soft, exactly as on a box without those mods installed.
#   - cfgeconomycore.xml / cfgplayerspawnpoints.xml are GAME-owned mission files (not mirrored);
#     stage real-shaped test/fixtures/ copies into each mission so the CE + transfer engines run.
$ceSrc = Join-Path $deployDir "custom-ce"
if (Test-Path $ceSrc) {
    $ceDst = Join-Path $StagingDir "custom-ce"
    New-Item -ItemType Directory -Force -Path $ceDst | Out-Null
    Copy-Item (Join-Path $ceSrc '*') $ceDst -Recurse -Force
}
#   - serverDZ.cfg.template ships from deploy/ as CODE; stage it with a THROWAWAY host.env so
#     Apply-ServerCfg can render offline. The dummy passwords never leave this staging dir -
#     the real ones live only in the box's host.env and are never in the repo.
$tplSrc = Join-Path $deployDir "serverDZ.cfg.template"
if (Test-Path $tplSrc) {
    Copy-Item $tplSrc (Join-Path $StagingDir "serverDZ.cfg.template") -Force
    Set-Content -LiteralPath (Join-Path $StagingDir "host.env") -Encoding utf8 `
        -Value "DEPLOY_SERVER_PASSWORD=offline-test-join`nDEPLOY_ADMIN_PASSWORD=offline-test-admin"
}
$fixturesDir = Join-Path $PSScriptRoot "test/fixtures"
$stagedFixtures = 0
foreach ($m in $missions) {
    foreach ($fx in @('cfgeconomycore.xml', 'cfgplayerspawnpoints.xml')) {
        $src = Join-Path $fixturesDir $fx
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $StagingDir "mpmissions/$m/$fx"
        if (Test-Path $dst) { continue }   # a real mirrored copy (future) wins over the fixture
        Copy-Item $src $dst -Force
        $stagedFixtures++
    }
}
Write-Host "  staged custom-ce/ + $stagedFixtures game-file fixture(s) across $($missions.Count) mission(s)"

# --- Run the REAL build chain against the staged dir ----------------------------------------
Write-Host "`nRunning the build chain (Apply-ConfigOverrides + Build-AIBandits) against staging" -ForegroundColor Cyan
# Capture the information stream (6>&1) so the [WARN] lines are inspectable, AND keep the
# RETURNED stats object - the authoritative counts. NEVER derive the verdict from Write-Host
# text (2>&1 doesn't capture the host stream - that false-passed the zero-MISS check once).
$applyCap    = & (Join-Path $PSScriptRoot "Apply-ConfigOverrides.ps1") -ServerDir $StagingDir -Manifest $overridesDoc -Fix 6>&1
$applyResult = @($applyCap | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] }) | Select-Object -Last 1
$warnLines   = @($applyCap | Where-Object { "$_" -match '\[WARN\]' } | ForEach-Object { ("$_" -replace '.*\[WARN\]\s*', '').Trim() })
Write-Host ("  apply: {0} changed, {1} created, {2} same, {3} warning(s)" -f $applyResult.Changed, $applyResult.Created, $applyResult.Same, $applyResult.Warn)

# --- Validate the produced artifacts --------------------------------------------------------
Write-Host "`nValidating built artifacts" -ForegroundColor Cyan

# 1. Zero-MISS. Force-created keys are [NEW], never warnings. Split what remains:
#    a bad SELECTOR / key on a file that IS present is a HARD fail (a dead override that would
#    silently do nothing on the box). a "file not found" is SOFT - a common override into a
#    mission that simply lacks that file (e.g. parked Chernarus has no Expansion MapSettings).
#    Surface the soft ones, block only on the hard ones.
$softMiss = @($warnLines | Where-Object { $_ -match 'file not found' })
$hardMiss = @($warnLines | Where-Object { $_ -notmatch 'file not found' })
if ($hardMiss.Count -eq 0) { Show-Pass "zero-MISS: every override on a present file applies" }
else {
    Show-Fail "$($hardMiss.Count) dead override(s) - would silently do nothing on the box; fix before deploy:"
    $hardMiss | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
}
if ($softMiss.Count) {
    Write-Host "  [note] $($softMiss.Count) override(s) skipped a mission lacking the target file (benign):" -ForegroundColor DarkYellow
    $softMiss | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkYellow }
}

# 2. The force-create payoff, proven offline: the spawnTypes toggles are in the built file.
$aib = Join-Path $StagingDir "profiles/AI_Bandits/common/DynamicAIB.common.json"
if (Test-Path $aib) {
    $doc = Get-Content -Raw $aib | ConvertFrom-Json
    $st = $doc.flags.spawnTypes
    if ($st) { Show-Pass "flags.spawnTypes present in the built DynamicAIB.common.json ($(@($st.PSObject.Properties | Where-Object { -not $_.Name.StartsWith('_') }).Count) type(s))" }
    else { Show-Fail "flags.spawnTypes MISSING from the built DynamicAIB.common.json (force-create did not land)" }
    # Reality the composed output depends on: 124 spawn points do nothing if this gate is off.
    if ($null -ne $doc.flags.useSpawnLocations -and [int]$doc.flags.useSpawnLocations -eq 0) {
        Write-Host "  [note] flags.useSpawnLocations = 0 -> dynamic AI bandit spawns compose EMPTY (spawn-points inert). Intentional?" -ForegroundColor DarkYellow
    }
}

# 3. Compose EACH mission and validate its artifacts (the mod reads these; invalid = boots blind).
#    Every prestart engine that writes a FIXED output path overwrites it per mission, so run +
#    validate each mission before the next runs. Each engine is guarded independently: one bad
#    engine surfaces its own failure without masking the others.
foreach ($m in $missions) {
    # AI bandits: compose the flat DynamicAIB/StaticAIB from common + maps/<m>; assert they parse.
    try { $null = & (Join-Path $PSScriptRoot "Build-AIBandits.ps1") -ServerDir $StagingDir -Mission $m -Fix 6>&1 }
    catch { Show-Fail "Build-AIBandits threw for ${m}: $($_.Exception.Message)" }
    foreach ($rel in @("profiles/AI_Bandits/DynamicAIB.json", "profiles/AI_Bandits/StaticAIB.json")) {
        $p = Join-Path $StagingDir $rel
        if (-not (Test-Path $p)) { Show-Fail "$rel not produced for $m"; continue }
        try { $null = Get-Content -Raw $p | ConvertFrom-Json; Show-Pass "$rel composed for $m parses" }
        catch { Show-Fail "$rel for $m - invalid JSON: $($_.Exception.Message)" }
    }

    # Expansion AI patrols: compose the AIPatrols DRAFT (frozen base + 'expansion' map-points) and
    # assert it parses. The SAME engine the box runs at prestart - proves the draft offline before any
    # restart. Only asserts on missions that actually produce it (no frozen base and no 'expansion'
    # points writes no draft by design - not a failure). The LIVE AIPatrolSettings.json is hand-
    # authored and must be unchanged by this: asserted below.
    $patLive    = Join-Path $StagingDir "mpmissions/$m/expansion/settings/AIPatrolSettings.json"
    $patLiveWas = if (Test-Path $patLive) { (Get-FileHash -LiteralPath $patLive -Algorithm SHA256).Hash } else { $null }
    try { $null = & (Join-Path $PSScriptRoot "Build-AIPatrols.ps1") -ServerDir $StagingDir -Mission $m -Fix 6>&1 }
    catch { Show-Fail "Build-AIPatrols threw for ${m}: $($_.Exception.Message)" }
    $patLiveNow = if (Test-Path $patLive) { (Get-FileHash -LiteralPath $patLive -Algorithm SHA256).Hash } else { $null }
    if ($patLiveWas -ne $patLiveNow) { Show-Fail "Build-AIPatrols MODIFIED the live AIPatrolSettings.json for $m - it must only write the draft" }
    else { Show-Pass "Build-AIPatrols left the live AIPatrolSettings.json untouched for $m" }
    $patRel = "mpmissions/$m/expansion/settings/AIPatrols.draft.json"
    $patP   = Join-Path $StagingDir $patRel
    if (Test-Path $patP) {
        try {
            $pd = Get-Content -Raw $patP | ConvertFrom-Json
            Show-Pass "$patRel composed for $m parses ($(@($pd.Patrols).Count) patrol(s), Enabled=$($pd.Enabled))"
            # Object patrols with persistence abort the mod's ENTIRE AIPatrol load - assert the guard neutralized them.
            $badObj = @($pd.Patrols | Where-Object { $_.PSObject.Properties['ObjectClassName'] -and [string]$_.ObjectClassName -and $_.PSObject.Properties['Persist'] -and [int]$_.Persist -ne 0 })
            if ($badObj.Count) { Show-Fail "$patRel for $m - $($badObj.Count) object patrol(s) still carry Persist!=0 (would abort the mod's AIPatrol load): $(($badObj | ForEach-Object { $_.Name }) -join ', ')" }
            else { Show-Pass "$patRel for $m - object patrols carry no illegal persistence" }
        } catch { Show-Fail "$patRel for $m - invalid JSON: $($_.Exception.Message)" }
    }

    # Expansion AI locations: compose the AILocations DRAFT (frozen base + 'expansion' map-points) and
    # assert it parses - twin of Build-AIPatrols, same live-file-untouched assertion.
    $locLive    = Join-Path $StagingDir "mpmissions/$m/expansion/settings/AILocationSettings.json"
    $locLiveWas = if (Test-Path $locLive) { (Get-FileHash -LiteralPath $locLive -Algorithm SHA256).Hash } else { $null }
    try { $null = & (Join-Path $PSScriptRoot "Build-AILocations.ps1") -ServerDir $StagingDir -Mission $m -Fix 6>&1 }
    catch { Show-Fail "Build-AILocations threw for ${m}: $($_.Exception.Message)" }
    $locLiveNow = if (Test-Path $locLive) { (Get-FileHash -LiteralPath $locLive -Algorithm SHA256).Hash } else { $null }
    if ($locLiveWas -ne $locLiveNow) { Show-Fail "Build-AILocations MODIFIED the live AILocationSettings.json for $m - it must only write the draft" }
    else { Show-Pass "Build-AILocations left the live AILocationSettings.json untouched for $m" }
    $locRel = "mpmissions/$m/expansion/settings/AILocations.draft.json"
    $locP   = Join-Path $StagingDir $locRel
    if (Test-Path $locP) {
        try {
            $ld = Get-Content -Raw $locP | ConvertFrom-Json
            Show-Pass "$locRel composed for $m parses ($(@($ld.RoamingLocations).Count) location(s))"
        } catch { Show-Fail "$locRel for $m - invalid JSON: $($_.Exception.Message)" }
    }

    # Map inversion Phase 2: Build-MapPoints derives the Map tab's store FROM the live AI
    # settings (the reverse direction of the two draft builders above). Assert the store
    # parses AND accounts for every source entry: locations 1:1 with RoamingLocations,
    # patrols + objectPatrols summing to Patrols with the object-class split exact - a
    # dropped patrol here would silently vanish from the Phase 3 map.
    if ((Test-Path $patLive) -or (Test-Path $locLive)) {
        try { $null = & (Join-Path $PSScriptRoot "Build-MapPoints.ps1") -ServerDir $StagingDir -Mission $m -Fix 6>&1 }
        catch { Show-Fail "Build-MapPoints threw for ${m}: $($_.Exception.Message)" }
        $mpP = Join-Path $StagingDir "profiles/AI_Shared/map-points.generated.json"
        if (-not (Test-Path $mpP)) { Show-Fail "map-points.generated.json not produced for $m" }
        else {
            try {
                $mp = Get-Content -Raw $mpP | ConvertFrom-Json
                $srcLocN = if (Test-Path $locLive) { @((Get-Content -Raw $locLive | ConvertFrom-Json).RoamingLocations).Count } else { 0 }
                $srcPats = if (Test-Path $patLive) { @((Get-Content -Raw $patLive | ConvertFrom-Json).Patrols) } else { @() }
                $srcObjN = @($srcPats | Where-Object { "$($_.ObjectClassName)" }).Count
                $gotLoc = @($mp.locations).Count; $gotPat = @($mp.patrols).Count; $gotObj = @($mp.objectPatrols).Count
                # Positional patrols with zero waypoints are legitimately skipped (unplottable) -
                # allow patrols <= positional source count, but the object-class split must be exact.
                $srcPosN = $srcPats.Count - $srcObjN
                if ($gotLoc -ne $srcLocN)      { Show-Fail "map-points.generated for ${m}: $gotLoc location(s) != $srcLocN in AILocationSettings" }
                elseif ($gotObj -ne $srcObjN)  { Show-Fail "map-points.generated for ${m}: $gotObj objectPatrol(s) != $srcObjN object-class patrols in AIPatrolSettings" }
                elseif ($gotPat -gt $srcPosN)  { Show-Fail "map-points.generated for ${m}: $gotPat patrol(s) > $srcPosN positional in AIPatrolSettings" }
                else { Show-Pass "map-points.generated.json derived for $m ($gotLoc location(s), $gotPat patrol(s), $gotObj object patrol(s) - accounts for all source entries)" }
            } catch { Show-Fail "map-points.generated.json for $m - invalid JSON: $($_.Exception.Message)" }
        }
    }

    # Bubaku: fixed-path spawner file from the active map's source (or empty-valid fallback).
    try { $null = & (Join-Path $deployDir "Build-BabakuSpawns.ps1") -ServerDir $StagingDir -Mission $m -Fix 6>&1 }
    catch { Show-Fail "Build-BabakuSpawns threw for ${m}: $($_.Exception.Message)" }
    $bab = Join-Path $StagingDir "profiles/SpawnerBubaku/SpawnerBubakuV2.json"
    if (-not (Test-Path $bab)) { Show-Fail "SpawnerBubakuV2.json not produced for $m" }
    else {
        try {
            $bd = Get-Content -Raw $bab | ConvertFrom-Json
            if ($null -eq $bd.BubakLocations) { Show-Fail "Bubaku for $m - built file has no BubakLocations array" }
            else { Show-Pass "Bubaku composed for $m parses ($(@($bd.BubakLocations).Count) location(s))" }
        } catch { Show-Fail "Bubaku for $m - invalid JSON: $($_.Exception.Message)" }
    }

    # Custom CE: register <ce folder="custom"> into the (fixture) mission cfgeconomycore.xml.
    try { $null = & (Join-Path $PSScriptRoot "Apply-CustomCE.ps1") -ServerDir $StagingDir -Mission $m -Fix 6>&1 }
    catch { Show-Fail "Apply-CustomCE threw for ${m}: $($_.Exception.Message)" }
    $core = Join-Path $StagingDir "mpmissions/$m/cfgeconomycore.xml"
    if (-not (Test-Path $core)) { Show-Fail "cfgeconomycore.xml missing for $m (fixture not staged?)" }
    else {
        try {
            $cx = [xml](Get-Content -Raw $core)
            $customCe = @($cx.economycore.ce | Where-Object { $_.folder -eq 'custom' })
            $regFiles = @($customCe.file.name)
            if (-not $customCe.Count) { Show-Fail "Custom CE for $m - no <ce folder='custom'> block registered" }
            elseif ($regFiles -notcontains 'custom_types.xml') { Show-Fail "Custom CE for $m - custom_types.xml not registered (got: $($regFiles -join ', '))" }
            elseif (-not (Test-Path (Join-Path $StagingDir "mpmissions/$m/custom/custom_types.xml"))) { Show-Fail "Custom CE for $m - custom_types.xml not copied into custom/" }
            else { Show-Pass "Custom CE for $m registers <ce folder='custom'> [$($regFiles -join ', ')], cfgeconomycore.xml valid" }
        } catch { Show-Fail "Custom CE for $m - cfgeconomycore.xml invalid XML after edit: $($_.Exception.Message)" }
    }

    # Transfer spawns: read the (fixture) spawn points, write transfer_spawn.json for the PBO.
    try { $null = & (Join-Path $deployDir "Build-TransferSpawns.ps1") -ServerDir $StagingDir -Mission $m -Gen 1 -Fix 6>&1 }
    catch { Show-Fail "Build-TransferSpawns threw for ${m}: $($_.Exception.Message)" }
    $ts = Join-Path $StagingDir "profiles/transfer_spawn.json"
    if (-not (Test-Path $ts)) { Show-Fail "transfer_spawn.json not produced for $m" }
    else {
        try {
            $td = Get-Content -Raw $ts | ConvertFrom-Json
            $pts = @($td.points)
            if ($null -eq $td.gen -or $pts.Count -eq 0) { Show-Fail "transfer_spawn.json for $m - missing gen or empty points" }
            elseif ($null -eq $pts[0].x -or $null -eq $pts[0].z) { Show-Fail "transfer_spawn.json for $m - point missing x/z" }
            else { Show-Pass "transfer_spawn.json for $m parses (gen $($td.gen), $($pts.Count) point(s))" }
        } catch { Show-Fail "transfer_spawn.json for $m - invalid JSON: $($_.Exception.Message)" }
    }
}

# Mod-owned CE sources (e.g. @aibandits, @dayzdog) live only on the box; offline they're skipped
# fail-soft. Surface which, so a green gate never implies they were tested here.
$ceManifest = Join-Path $StagingDir "custom-ce/custom-ce.json"
if (Test-Path $ceManifest) {
    try {
        $absent = @((Get-Content -Raw $ceManifest | ConvertFrom-Json).files | Where-Object { $_.from -and -not (Test-Path (Join-Path $StagingDir $_.from)) })
        if ($absent.Count) {
            Write-Host "  [note] $($absent.Count) custom-CE source(s) are mod-owned (absent offline, skipped) - confirmed live by Confirm-LiveConfigs:" -ForegroundColor DarkYellow
            $absent | ForEach-Object { Write-Host "         $($_.name) <- $($_.from)" -ForegroundColor DarkYellow }
        }
    } catch { }
}

# 4. Every staged/patched JSON + XML file parses (a corrupt rebuild = a corrupt live file).
$badParse = 0
foreach ($f in @(Get-ChildItem -Path $StagingDir -Recurse -File -Include *.json, *.xml)) {
    try {
        if ($f.Extension -eq '.json') { $null = Get-Content -Raw $f.FullName | ConvertFrom-Json }
        else { $null = [xml](Get-Content -Raw $f.FullName) }
    } catch { $badParse++; Show-Fail "unparseable: $($f.FullName.Substring($StagingDir.Length).TrimStart('/','\')) - $($_.Exception.Message)" }
}
if ($badParse -eq 0) { Show-Pass "all staged/built JSON + XML parse" }

# --- serverDZ.cfg render (Apply-ServerCfg) --------------------------------------------------
# The engine reads serverDZ.cfg before anything else, so a broken render is a dead server. Prove
# offline that the template + host.env + server-settings.json actually produce a bootable file:
# every toggle applied, no placeholder left, and the load-bearing Missions block intact.
$serverCfgScript = Join-Path $PSScriptRoot "Apply-ServerCfg.ps1"
$stagedTpl       = Join-Path $StagingDir "serverDZ.cfg.template"
if ((Test-Path $serverCfgScript) -and (Test-Path $stagedTpl)) {
    $cfgCap   = & $serverCfgScript -ServerDir $StagingDir -Fix 6>&1
    $cfgWarns = @($cfgCap | Where-Object { "$_" -match '\[WARN\]' })
    $builtCfg = Join-Path $StagingDir "serverDZ.cfg"
    if (-not (Test-Path $builtCfg)) {
        Show-Fail "Apply-ServerCfg produced no serverDZ.cfg$(if ($cfgWarns) { ' - ' + (($cfgWarns | Select-Object -First 1) -replace '.*\[WARN\]\s*', '') })"
    } else {
        $cfgText = Get-Content -Raw -LiteralPath $builtCfg
        if ($cfgText -match '\{\{[A-Za-z0-9_]+\}\}') { Show-Fail "rendered serverDZ.cfg still contains an unresolved {{placeholder}}" }
        else { Show-Pass "serverDZ.cfg renders with no unresolved placeholders" }
        # Map selection lives in map.env -> the unit's -mission=, but the engine still needs this
        # block present to run a mission at all. The renderer must never drop it.
        if ($cfgText -match '(?s)class\s+Missions\s*\{.*?template\s*=') { Show-Pass "rendered serverDZ.cfg keeps its class Missions block (map selection unaffected)" }
        else { Show-Fail "rendered serverDZ.cfg lost its class Missions block - the server would boot with no mission" }
        # Every key the web editor may set must actually reach the file.
        $settingsFile = Join-Path $StagingDir "server-settings.json"
        if (Test-Path $settingsFile) {
            $want = (Get-Content -Raw -LiteralPath $settingsFile | ConvertFrom-Json)
            $missed = @()
            foreach ($p in $want.PSObject.Properties) {
                if ($p.Name.StartsWith('_')) { continue }
                $lit = if ($p.Value -is [string]) { '"' + $p.Value + '"' } else { "$($p.Value)" }
                if ($cfgText -notmatch ('(?m)^\s*' + [regex]::Escape($p.Name) + '\s*=\s*' + [regex]::Escape($lit) + '\s*;')) { $missed += $p.Name }
            }
            if ($missed.Count) { Show-Fail "server-settings.json key(s) did not reach serverDZ.cfg: $($missed -join ', ')" }
            else { Show-Pass "all $(@($want.PSObject.Properties | Where-Object { -not $_.Name.StartsWith('_') }).Count) server-settings.json toggle(s) applied to serverDZ.cfg" }

            # The web editor's comment column is the cfg's OWN trailing // comment, copied into
            # server-settings.json's _help. Assert it still matches the template, so editing a
            # comment in serverDZ.cfg.template can never leave the UI quietly describing the
            # old behaviour. Same normalisation the generator used: first // clause, whitespace
            # collapsed.
            $tplText = Get-Content -Raw -LiteralPath $stagedTpl
            $help    = $want._help
            $helpBad = @()
            foreach ($p in $want.PSObject.Properties) {
                if ($p.Name.StartsWith('_')) { continue }
                $m = [regex]::Match($tplText, '(?m)^[ \t]*' + [regex]::Escape($p.Name) + '[ \t]*=.*?;[ \t]*//[ \t]*(.*)$')
                if (-not $m.Success) { $helpBad += "$($p.Name): no // comment in the template"; continue }
                $want2 = $m.Groups[1].Value.Trim()
                $i = $want2.IndexOf('//'); if ($i -gt 0) { $want2 = $want2.Substring(0, $i).Trim() }
                $want2 = [regex]::Replace($want2, '\s+', ' ')
                $have  = if ($help -and $help.PSObject.Properties.Name -contains $p.Name) { [string]$help.$($p.Name) } else { $null }
                if ($null -eq $have)   { $helpBad += "$($p.Name): missing from _help" }
                elseif ($have -ne $want2) { $helpBad += "$($p.Name): _help text differs from the template comment" }
            }
            foreach ($hp in @($help.PSObject.Properties.Name)) {
                if (-not ($want.PSObject.Properties.Name -contains $hp)) { $helpBad += "$hp : _help entry for a key that is not a toggle" }
            }
            if ($helpBad.Count) { Show-Fail "server-settings.json _help out of sync with serverDZ.cfg.template - $($helpBad -join '; ')" }
            else { Show-Pass "server-settings.json _help matches every serverDZ.cfg.template comment (UI comment column)" }

            # _labels renames a field for READING only. A label on a key that is not a toggle
            # would silently do nothing, so treat it as a typo and fail. The real key must also
            # still be the one in the cfg - the toggle check above already proves that.
            if ($want.PSObject.Properties.Name -contains '_labels') {
                $lblBad = @()
                foreach ($lp in @($want._labels.PSObject.Properties)) {
                    if (-not ($want.PSObject.Properties.Name -contains $lp.Name)) { $lblBad += "$($lp.Name): label for a key that is not a toggle" }
                    elseif ([string]::IsNullOrWhiteSpace([string]$lp.Value))       { $lblBad += "$($lp.Name): empty label" }
                }
                if ($lblBad.Count) { Show-Fail "server-settings.json _labels invalid - $($lblBad -join '; ')" }
                else { Show-Pass "server-settings.json _labels ($(@($want._labels.PSObject.Properties).Count)) all rename real toggles (display-only)" }
            }
        }
        if ($cfgWarns.Count) { Write-Host ("  [note] Apply-ServerCfg warned: {0}" -f (($cfgWarns | ForEach-Object { ("$_" -replace '.*\[WARN\]\s*', '').Trim() }) -join '; ')) -ForegroundColor DarkYellow }
    }
}

# --- Deploy payload completeness ------------------------------------------------------------
# Deploy-DayZServer has TWO lists that must agree: the root-file rsync list (what reaches the
# box's deploy-stage) and $items (what gets placed from there into the server dir). A '../' Src
# missing from the rsync list is skipped silently on the dev machine and then fails mid-deploy
# ON THE BOX, half-applied. Static cross-check so that mismatch fails here instead. Both lists
# are plain quoted literals in one file, so a text scan is enough - and a false positive costs
# one obvious gate failure, not a broken deploy.
$deployScript = Join-Path $PSScriptRoot "Deploy-DayZServer.ps1"
if (Test-Path $deployScript) {
    $dtext = Get-Content -Raw -LiteralPath $deployScript
    $fe = [regex]::Match($dtext, '(?s)foreach \(\$f in (.*?)\) \{')
    if (-not $fe.Success) {
        Show-Fail "could not locate the root-file payload list in Deploy-DayZServer.ps1 (this check needs updating)"
    } else {
        $shipped = @([regex]::Matches($fe.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        # '../x' Srcs resolve from deploy/ up to the repo root. common/ ships via its own rsync.
        $needed  = @([regex]::Matches($dtext, 'Src\s*=\s*"\.\./([^"]+)"') | ForEach-Object { $_.Groups[1].Value } |
                     Where-Object { -not $_.StartsWith('common/') } | Select-Object -Unique)
        $unshipped = @($needed | Where-Object { $shipped -notcontains $_ })
        if ($unshipped.Count) { Show-Fail "Deploy `$items reference file(s) that the payload rsync never ships: $($unshipped -join ', ') - add them to the root-file list in Deploy-DayZServer.ps1" }
        else { Show-Pass "every '../' deploy payload source ($($needed.Count)) is in the rsync ship list" }
    }
}

# --- Web-edited CE types surfaces (registry web:'types') -------------------------------------
# The Expansion tuning pair is BOX-OWNED, WEB-EDITED content (2026-07-23): dayz-ctl types-write
# is the only writer, the deploy only seeds-if-missing, Pull-Configs mirrors the box copy back
# into the seed path. Four seams can silently break that contract, so gate all four:
#   1. the registry row shape - a types surface needs seed + mirror:'live' + check:'xml' (the
#      pull refuses to mirror an unvalidated file, and a fresh box could not be seeded);
#   2. the seed document itself - types-write enforces root <types> / <type name=...> children,
#      so a seed failing the same shape could be seeded once but never saved again;
#   3. the editor's hardcoded TYPES_BASE pairing (types-editor.js) - a types row the editor
#      cannot pair with its base surface renders an empty merge view;
#   4. single ownership - a seeded (box-owned) file must NEVER also sit in Deploy's $items ship
#      list: shipping overwrites on drift, clobbering every web edit at the next deploy (the
#      exact dual-ownership the tuning files had before the flip).
Write-Host "`nValidating web-edited types surfaces (config-registry.json web:'types')" -ForegroundColor Cyan
$reg = Get-Content -Raw (Join-Path $PSScriptRoot 'config-registry.json') | ConvertFrom-Json
$typesRows = @($reg.surfaces | Where-Object { $_.web -eq 'types' })
foreach ($row in $typesRows) {
    if (-not $row.seed -or $row.mirror -ne 'live' -or $row.check -ne 'xml') {
        Show-Fail "registry types row '$($row.name)' must carry seed + mirror:'live' + check:'xml' (seed='$($row.seed)' mirror='$($row.mirror)' check='$($row.check)')"
    } else { Show-Pass "registry types row '$($row.name)' carries seed + mirror:'live' + check:'xml'" }
    $seedPath = Join-Path $PSScriptRoot $row.seed
    if (-not (Test-Path $seedPath)) { Show-Fail "types seed missing: $($row.seed)"; continue }
    try {
        [xml]$tdoc = Get-Content -Raw -LiteralPath $seedPath
        # LocalName, NOT Name: PowerShell's XML adapter resolves .Name on <type name="X"> to the
        # ATTRIBUTE value (adapted members shadow the .NET property), so .Name reads "X".
        $tkids = @($tdoc.DocumentElement.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
        $tbad  = @($tkids | Where-Object { $_.LocalName -ne 'type' -or -not $_.GetAttribute('name') })
        if ($tdoc.DocumentElement.LocalName -ne 'types' -or $tbad.Count) {
            Show-Fail "types seed '$($row.seed)' is not a valid CE types doc (root <types>, only <type name=...> children) - types-write would refuse to ever save it"
        } else { Show-Pass "types seed '$($row.seed)' parses as a CE types doc ($($tkids.Count) types)" }
    } catch { Show-Fail "types seed '$($row.seed)' does not parse as XML: $($_.Exception.Message)" }
}
# Seam 3: the registry <-> types-editor.js pairing.
$tePath = Join-Path $PSScriptRoot '../ConfigViewer/web/js/types-editor.js'
if ($typesRows.Count) {
    if (-not (Test-Path $tePath)) { Show-Fail "types-editor.js not found at $tePath (types rows exist but no editor)" }
    else {
        $te = Get-Content -Raw -LiteralPath $tePath
        $mapM = [regex]::Match($te, '(?s)const TYPES_BASE = \{(.*?)\};')
        if (-not $mapM.Success) { Show-Fail "types-editor.js TYPES_BASE map not found (this check needs updating)" }
        else {
            $pairs = @{}
            foreach ($m in [regex]::Matches($mapM.Groups[1].Value, "(\w+):\s*'([^']+)'")) { $pairs[$m.Groups[1].Value] = $m.Groups[2].Value }
            foreach ($row in $typesRows) {
                if (-not $pairs.ContainsKey($row.name)) { Show-Fail "types row '$($row.name)' has no TYPES_BASE entry in types-editor.js - the editor cannot pair it with its base file"; continue }
                $baseName = $pairs[$row.name]
                if (-not ($reg.surfaces | Where-Object { $_.name -eq $baseName })) { Show-Fail "TYPES_BASE pairs '$($row.name)' with unknown surface '$baseName'" }
                else { Show-Pass "types row '$($row.name)' pairs with base surface '$baseName'" }
            }
        }
    }
}
# Seam 4: single ownership - no registry-seeded (box-owned) file may also be shipped by $items.
if (Test-Path $deployScript) {
    $itemsSrcs = @([regex]::Matches($dtext, 'Src\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^\.\./' })
    $seedRows2 = @($reg.surfaces | Where-Object { $_.seed })
    $clobber = @($seedRows2 | Where-Object { $_.seed -like 'deploy/*' -and $itemsSrcs -contains ($_.seed -replace '^deploy/', '') })
    if ($clobber.Count) { Show-Fail "box-owned (seeded) file(s) ALSO in Deploy `$items - every deploy would clobber web edits: $(@($clobber | ForEach-Object { $_.seed }) -join ', ')" }
    else { Show-Pass "no registry-seeded (box-owned) file is shipped by Deploy `$items ($($seedRows2.Count) seed rows checked)" }
}

# --- Summary --------------------------------------------------------------------------------
$color = if ($fail) { 'Red' } else { 'Green' }
Write-Host ("`nPre-deploy config test: {0} passed, {1} failed  (missions: {2})" -f $pass, $fail, ($missions -join ', ')) -ForegroundColor $color
if (-not $KeepStaging) { Remove-Item -Recurse -Force $StagingDir -ErrorAction SilentlyContinue }
else { Write-Host "Staging kept at $StagingDir" }

if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot "logs"; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir "testconfigs.csv") -Row ([PSCustomObject]@{
        Timestamp = Get-Date -Format "s"; Passed = $pass; Failed = $fail; Missions = ($missions -join '|')
    })
}
if ($fail) { exit 1 }
exit 0
