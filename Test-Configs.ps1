#requires -version 7
<#
.SYNOPSIS
    PRE-DEPLOY test: build the real config artifacts OFFLINE from the repo mirrors and assert
    they are correct - before anything ships. No box access, no writes to prod.
.DESCRIPTION
    "Box builds, dev validates" done properly: not a prediction, an actual build. The box
    rebuilds every patched file as frozen-default + override patches at prestart, then composes
    the AI-bandit configs. Dev has the same inputs (config-defaults/ baselines + config-overrides.json
    + the AI_Bandits source tree + spawn-points) and the same engines (Apply-ConfigOverrides,
    Build-AIBandits). So this stages a throwaway ServerDir from the mirrors, runs the ACTUAL
    build chain against it, and validates the produced artifacts. If it passes, the live deploy
    runs the identical scripts on the identical inputs — the result is already known.

    This is the GATE. Run it (after Pull-Configs refreshes the mirrors from the box) before a
    -Fix deploy. Confirm-LiveConfigs.ps1 is the AFTER: it confirms the running server matches.

    Staging is reconstructed exactly as the box builds:
      - every config-defaults/<rel> baseline is placed at its live path (as both the frozen
        <stem>.defaults<ext> AND a live <stem><ext> for the engine to rebuild) - identical to
        the box's reversible-default rebuild.
      - registry seed rows WITHOUT a captured baseline (classification, StaticAIB, Babaku,
        messages) are placed from their repo seed - identical to a box that has them.
    Then: Apply-ConfigOverrides -Fix (force-create) + Build-AIBandits -Fix per declared mission.

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
#    Build overwrites the fixed output path per mission, so validate each before the next runs.
foreach ($m in $missions) {
    try { $null = & (Join-Path $PSScriptRoot "Build-AIBandits.ps1") -ServerDir $StagingDir -Mission $m -Fix 6>&1 }
    catch { Show-Fail "Build-AIBandits threw for ${m}: $($_.Exception.Message)"; continue }
    foreach ($rel in @("profiles/AI_Bandits/DynamicAIB.json", "profiles/AI_Bandits/StaticAIB.json")) {
        $p = Join-Path $StagingDir $rel
        if (-not (Test-Path $p)) { Show-Fail "$rel not produced for $m"; continue }
        try { $null = Get-Content -Raw $p | ConvertFrom-Json; Show-Pass "$rel composed for $m parses" }
        catch { Show-Fail "$rel for $m - invalid JSON: $($_.Exception.Message)" }
    }
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
