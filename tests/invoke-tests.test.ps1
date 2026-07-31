#requires -Version 7
<#
  invoke-tests.test.ps1 - TDD harness for Invoke-Tests.ps1 (Scale-Ready T1: the ONE
  test runner, wired fail-closed into all three deploys).
  Written BEFORE the runner exists: first run must FAIL ("runner exists").

  Everything runs against throwaway fixture trees under the system temp dir - the
  runner is pointed at them with -Root, so this file never triggers a recursive
  run over the real repo.
#>
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$runner = Join-Path (Split-Path -Parent $here) 'Invoke-Tests.ps1'

$script:tests = 0; $script:fails = 0
function Assert([string]$name, [bool]$cond) {
    $script:tests++
    if ($cond) { Write-Host "  ok: $name" }
    else       { $script:fails++; Write-Host "FAIL: $name" }
}

Assert 'runner exists' (Test-Path $runner)
if (-not (Test-Path $runner)) { Write-Host "TESTS: $($script:tests), FAILED: $($script:fails)"; exit 1 }

$fixtures = [System.Collections.Generic.List[string]]::new()
function New-Fixture {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("invoketests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d | Out-Null
    $fixtures.Add($d)
    $d
}
function Invoke-Runner([string]$root, [switch]$WithLog) {
    # NB: a one-element array from an if-expression unwraps to a STRING, and splatting a
    # string to a native command passes it char-by-char. Build the argv list explicitly.
    [string[]]$argv = '-NoProfile', '-File', $runner, '-Root', $root
    if (-not $WithLog) { $argv += '-NoLog' }
    $out = & pwsh @argv 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($out -join "`n") }
}

try {
    # --- 1. all-green tree: ps1 + sh + js all pass -> exit 0, count reported -----
    $f = New-Fixture
    New-Item -ItemType Directory -Path (Join-Path $f 'a/tests') -Force | Out-Null
    Set-Content (Join-Path $f 'a/tests/one.test.ps1') 'exit 0'
    Set-Content (Join-Path $f 'a/tests/two.test.sh')  "#!/usr/bin/env bash`nexit 0"
    Set-Content (Join-Path $f 'a/three.test.js') "import { test } from 'node:test'; test('t', () => {});"
    $r = Invoke-Runner $f
    Assert 'green tree exits 0'            ($r.Exit -eq 0)
    Assert 'green tree reports 3 files'    ($r.Out -match '\b3\b')

    # --- 2. one red suite -> nonzero exit, failing file NAMED, its output shown --
    $f = New-Fixture
    Set-Content (Join-Path $f 'good.test.ps1') 'exit 0'
    Set-Content (Join-Path $f 'bad.test.sh') "#!/usr/bin/env bash`necho BOOM_MARKER`nexit 1"
    $r = Invoke-Runner $f
    Assert 'red tree exits nonzero'        ($r.Exit -ne 0)
    Assert 'failing file is named'         ($r.Out -match 'bad\.test\.sh')
    Assert 'failing suite output surfaced' ($r.Out -match 'BOOM_MARKER')

    # --- 3. exclusions: .git / node_modules / deploy/stage are never discovered --
    $f = New-Fixture
    foreach ($d in '.git/x', 'pkg/node_modules/y', 'Api/deploy/stage/app') {
        New-Item -ItemType Directory -Path (Join-Path $f $d) -Force | Out-Null
        Set-Content (Join-Path $f "$d/hidden.test.ps1") 'exit 1'   # would fail if ever run
    }
    Set-Content (Join-Path $f 'real.test.ps1') 'exit 0'
    $r = Invoke-Runner $f
    Assert 'excluded dirs not discovered'  ($r.Exit -eq 0)
    Assert 'exactly 1 file discovered'     ($r.Out -match '\b1\b')

    # --- 4. FAIL-CLOSED: zero tests discovered is an ERROR, never a pass ---------
    $f = New-Fixture
    Set-Content (Join-Path $f 'notatest.ps1') 'exit 0'
    $r = Invoke-Runner $f
    Assert 'empty discovery exits nonzero' ($r.Exit -ne 0)
    Assert 'empty discovery says so'       ($r.Out -match '0 test files')

    # --- 5. .ts runs via node type stripping -------------------------------------
    $f = New-Fixture
    Set-Content (Join-Path $f 'typed.test.ts') "import { test } from 'node:test'; const n: number = 1; test('t', () => { if (n !== 1) throw new Error('no'); });"
    $r = Invoke-Runner $f
    Assert 'ts suite passes'               ($r.Exit -eq 0)

    # --- 6. cwd rule: every suite runs with cwd = its own directory --------------
    $f = New-Fixture
    New-Item -ItemType Directory -Path (Join-Path $f 'deep/tests') -Force | Out-Null
    Set-Content (Join-Path $f 'deep/tests/cwd.test.sh') "#!/usr/bin/env bash`n[ `"`$PWD`" = `"`$(cd `"`$(dirname `"`$0`")`" && pwd)`" ] || exit 1"
    $r = Invoke-Runner $f
    Assert 'suite cwd is its own dir'      ($r.Exit -eq 0)

    # --- 7. CSV log: append-mode rows under <root>/test-logs; -NoLog writes none -
    $f = New-Fixture
    Set-Content (Join-Path $f 'one.test.ps1') 'exit 0'
    $r = Invoke-Runner $f -WithLog
    $logDir = Join-Path $f 'test-logs'
    $csv = Get-ChildItem $logDir -Filter '*.csv' -ErrorAction SilentlyContinue | Select-Object -First 1
    Assert 'log csv written'               ($null -ne $csv)
    if ($csv) {
        $rows = Import-Csv $csv.FullName
        Assert 'log has a row per suite'   (@($rows).Count -ge 1)
        Assert 'log rows carry timestamps' ($null -ne @($rows)[0].Timestamp -and @($rows)[0].Timestamp -ne '')
        $r2 = Invoke-Runner $f -WithLog
        Assert 'log appends, not replaces' (@(Import-Csv $csv.FullName).Count -gt @($rows).Count)
    }
    $f2 = New-Fixture
    Set-Content (Join-Path $f2 'one.test.ps1') 'exit 0'
    $r = Invoke-Runner $f2
    Assert '-NoLog writes nothing'         (-not (Test-Path (Join-Path $f2 'test-logs')))
}
finally {
    foreach ($d in $fixtures) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "TESTS: $($script:tests), FAILED: $($script:fails)"
if ($script:fails) { exit 1 } else { exit 0 }
