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

. (Join-Path $PSScriptRoot "../../common/Utils.ps1")

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
