#requires -Version 7
<#
  convert-to-owned.test.ps1 - TDD harness for Convert-ToOwned.ps1 (Scale-Ready A3 tail).
  Written BEFORE the script exists: first run must FAIL on "script exists".

  WHAT IT IS: the ONE mechanism for cutting a file off the override delta engine and
  onto whole-file ownership WITHOUT changing a byte of the live file. DayZ-Server/
  CLAUDE.md documented this as a Sakhal hand-trick ("removing the block FREEZES the
  live file"); this makes it a tool with a proof, usable for every remaining file.

  THE SAFETY THAT MATTERS: removing a block freezes the live file at its CURRENT
  content. That is only behaviour-preserving if the live file already carries every
  override value (i.e. a boot applied them). If any selector disagrees, freezing
  silently locks in a DIFFERENT value than the manifest intends - so the tool must
  REFUSE, not warn. That refusal is the whole point of the test.
#>
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path (Split-Path -Parent $here) 'Convert-ToOwned.ps1'

$script:tests = 0; $script:fails = 0
function Assert([string]$name, [bool]$cond, [string]$why = '') {
    $script:tests++
    if ($cond) { Write-Host "  ok: $name" }
    else { $script:fails++; Write-Host "FAIL: $name"; if ($why) { Write-Host "      $why" } }
}

Assert 'script exists' (Test-Path $script)
if (-not (Test-Path $script)) { Write-Host "TESTS: $($script:tests), FAILED: $($script:fails)"; exit 1 }

$fixtures = [System.Collections.Generic.List[string]]::new()

# A throwaway ServerDir + manifest. $liveLifetime lets a test simulate the DANGEROUS
# case: the manifest says 3888000 but the live file was never rebuilt with it.
function New-Fixture([string]$liveLifetime = '3888000') {
    $work = Join-Path ([IO.Path]::GetTempPath()) ("cto-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $mission = Join-Path $work 'mpmissions/dayzOffline.sakhal/db'
    New-Item -ItemType Directory -Force -Path $mission | Out-Null
    Set-Content (Join-Path $mission 'types.xml') @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<types>
    <type name="OffroadHatchback"><nominal>0</nominal><lifetime>$liveLifetime</lifetime></type>
    <type name="Sedan_02"><nominal>0</nominal><lifetime>$liveLifetime</lifetime></type>
    <type name="AKM"><nominal>10</nominal><lifetime>7200</lifetime></type>
</types>
"@
    Set-Content (Join-Path $work 'server-settings.json') '{ "hostname": "live name", "disableVoN": 1 }'

    $manifest = [ordered]@{
        _readme    = 'comment key - must be ignored'
        files      = [ordered]@{ 'server-settings.json' = [ordered]@{ hostname = 'live name' } }
        mpmissions = [ordered]@{
            'dayzOffline.sakhal' = [ordered]@{
                'db/types.xml' = [ordered]@{
                    _note = 'comment key - must be ignored'
                    "/types/type[@name='OffroadHatchback']/lifetime" = '3888000'
                    "/types/type[@name='Sedan_02']/lifetime"         = '3888000'
                }
                'db/globals.xml' = [ordered]@{ "/globals/var[@name='X']/@value" = '1' }
            }
        }
    }
    $mp = Join-Path $work 'config-overrides.json'
    $manifest | ConvertTo-Json -Depth 9 | Set-Content $mp
    $fixtures.Add($work)
    [pscustomobject]@{ Dir = $work; Manifest = $mp; Types = (Join-Path $mission 'types.xml') }
}

function Run([object]$fx, [string]$target, [switch]$Fix) {
    [string[]]$argv = '-NoProfile', '-File', $script, '-ServerDir', $fx.Dir, '-Manifest', $fx.Manifest, '-Target', $target, '-NoLog'
    if ($Fix) { $argv += '-Fix' }
    $out = & pwsh @argv 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($out -join "`n") }
}
function Block([object]$fx) {
    $d = Get-Content -Raw $fx.Manifest | ConvertFrom-Json -AsHashtable
    if ($d.mpmissions -and $d.mpmissions['dayzOffline.sakhal']) { return $d.mpmissions['dayzOffline.sakhal']['db/types.xml'] }
    $null
}

try {
    $TARGET = 'mpmissions/dayzOffline.sakhal:db/types.xml'

    # --- 1. report mode: verifies, says SAFE, changes NOTHING ------------------
    $fx = New-Fixture
    $before = Get-FileHash $fx.Manifest -Algorithm SHA256
    $r = Run $fx $TARGET
    Assert 'report mode exits 0 when live matches'  ($r.Exit -eq 0) $r.Out
    Assert 'report mode says it is safe to freeze'  ($r.Out -match '(?i)safe')
    Assert 'report mode names the 2 verified rows'  ($r.Out -match '\b2\b')
    Assert 'report mode does NOT edit the manifest' ((Get-FileHash $fx.Manifest -Algorithm SHA256).Hash -eq $before.Hash)

    # --- 2. -Fix removes exactly that block; live file untouched ---------------
    $fx = New-Fixture
    $liveBefore = (Get-FileHash $fx.Types -Algorithm SHA256).Hash
    $r = Run $fx $TARGET -Fix
    Assert '-Fix exits 0'                       ($r.Exit -eq 0) $r.Out
    Assert '-Fix removes the target block'      ($null -eq (Block $fx))
    Assert '-Fix leaves the LIVE file byte-identical (the freeze proof)' `
        ((Get-FileHash $fx.Types -Algorithm SHA256).Hash -eq $liveBefore)
    $doc = Get-Content -Raw $fx.Manifest | ConvertFrom-Json -AsHashtable
    Assert '-Fix keeps the sibling globals.xml block' `
        ($null -ne $doc.mpmissions['dayzOffline.sakhal']['db/globals.xml'])
    Assert '-Fix keeps the files layer'         ($null -ne $doc.files['server-settings.json'])
    Assert '-Fix keeps comment keys'            ($doc.ContainsKey('_readme'))

    # --- 3. THE SAFETY: live file disagrees -> REFUSE, change nothing ----------
    $fx = New-Fixture -liveLifetime '3'
    $before = (Get-FileHash $fx.Manifest -Algorithm SHA256).Hash
    $r = Run $fx $TARGET -Fix
    Assert 'mismatch REFUSES (nonzero exit)'    ($r.Exit -ne 0)
    Assert 'mismatch names the offending selector' ($r.Out -match 'OffroadHatchback')
    Assert 'mismatch leaves the manifest intact' ((Get-FileHash $fx.Manifest -Algorithm SHA256).Hash -eq $before)
    Assert 'mismatch explains WHY freezing is unsafe' ($r.Out -match '(?i)restart|boot|appl')

    # --- 4. files-layer target works the same way -----------------------------
    $fx = New-Fixture
    $r = Run $fx 'files:server-settings.json' -Fix
    Assert 'files-layer cutover exits 0'        ($r.Exit -eq 0) $r.Out
    $doc = Get-Content -Raw $fx.Manifest | ConvertFrom-Json -AsHashtable
    Assert 'files-layer block removed'          (-not $doc.files.ContainsKey('server-settings.json'))
    Assert 'mission layer untouched'            ($null -ne $doc.mpmissions['dayzOffline.sakhal']['db/types.xml'])

    # --- 5. unknown target: clear error, no write ------------------------------
    $fx = New-Fixture
    $r = Run $fx 'mpmissions/dayzOffline.sakhal:db/nope.xml' -Fix
    Assert 'unknown target exits nonzero'       ($r.Exit -ne 0)
    Assert 'unknown target names what it wanted' ($r.Out -match 'nope\.xml')

    # --- 6. idempotent: cutting over twice is a no-op success ------------------
    $fx = New-Fixture
    $null = Run $fx $TARGET -Fix
    $r = Run $fx $TARGET -Fix
    Assert 'second -Fix is a no-op success'     ($r.Exit -eq 0) $r.Out
    Assert 'second -Fix says already owned'     ($r.Out -match '(?i)already|no block')

    # --- 7. RUNS AS SHIPPED: the box has no repo around it ----------------------
    # Found live 2026-07-31: the script dot-sourced ../../../common/Utils.ps1, which resolves only
    # inside the repo. On the box it lives at ~/servers/dayz-server/, so every invocation died with
    # "term not recognized" before doing anything - and the other 22 tests missed it because they
    # run the script FROM the repo, where the path happens to exist. Copy it somewhere with no
    # common/ sibling (exactly how the deploy ships it) and it must still work.
    $fx = New-Fixture
    $shipped = Join-Path $fx.Dir 'Convert-ToOwned.ps1'
    Copy-Item $script $shipped
    [string[]]$argv = '-NoProfile', '-File', $shipped, '-ServerDir', $fx.Dir, '-Manifest', $fx.Manifest, '-Target', $TARGET, '-NoLog'
    $out = & pwsh @argv 2>&1 | ForEach-Object { "$_" }
    $rc = $LASTEXITCODE
    Assert 'runs standalone with no repo/common around it' ($rc -eq 0) ($out -join "`n")
    Assert 'standalone run does not complain about Utils.ps1' (($out -join ' ') -notmatch 'Utils\.ps1')
}
finally {
    foreach ($d in $fixtures) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "TESTS: $($script:tests), FAILED: $($script:fails)"
if ($script:fails) { exit 1 } else { exit 0 }
