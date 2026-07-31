#requires -Version 7
<#
.SYNOPSIS
  The ONE test runner (Scale-Ready T1). Discovers every test suite in the repo and
  runs them all; any red suite - or an empty discovery - is a failure.

.DESCRIPTION
  Discovery: *.test.ps1 / *.test.sh / *.test.js / *.test.ts anywhere under -Root,
  skipping .git/, node_modules/ and deploy/stage/ (staged build-artifact copies).
  A NEW test file is picked up automatically - there is no list to register on.

  Invocation is uniform by extension, each suite as a child process with cwd set
  to the suite's own directory:
    .ps1      pwsh -NoProfile -File
    .sh       bash
    .js/.ts   node --test          (Node 22+ strips the TS types)

  FAIL-CLOSED, both ways:
    - any suite exiting nonzero fails the run (its captured output is printed)
    - discovering ZERO test files fails the run - a broken glob must never let a
      deploy sail through on an accidentally-empty suite

  All three deploys (Deploy-DayZServer, Deploy-Api, Deploy-ConfigViewer) call this
  before shipping. Read-only apart from its own CSV log.

.EXAMPLE
  ./Invoke-Tests.ps1              # run the whole repo suite
  ./Invoke-Tests.ps1 -NoLog       # same, without the CSV log
#>
[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,   # override for fixture-driven self-tests only
    [switch]$NoLog
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../common/Utils.ps1')

$patterns = '*.test.ps1', '*.test.sh', '*.test.js', '*.test.ts'
$skipDirs = '.git', 'node_modules'

function Find-TestFiles([string]$dir) {
    foreach ($sub in [IO.Directory]::EnumerateDirectories($dir)) {
        $leaf = Split-Path $sub -Leaf
        if ($leaf -in $skipDirs) { continue }
        # deploy/stage/ holds a staged COPY of app source (Deploy-Api) - never its own tests
        if ($leaf -eq 'stage' -and (Split-Path (Split-Path $sub -Parent) -Leaf) -eq 'deploy') { continue }
        Find-TestFiles $sub
    }
    foreach ($file in [IO.Directory]::EnumerateFiles($dir)) {
        $leaf = Split-Path $file -Leaf
        foreach ($p in $patterns) { if ($leaf -like $p) { $file; break } }
    }
}

$Root = (Resolve-Path $Root).Path
$found = @(Find-TestFiles $Root | Sort-Object)

if ($found.Count -eq 0) {
    Write-Host "FAIL-CLOSED: discovered 0 test files under $Root - refusing to pass an empty suite."
    exit 2
}

$logPath = Join-Path $Root 'test-logs/invoke-tests.log.csv'
if (-not $NoLog) { New-Item -ItemType Directory -Path (Split-Path $logPath -Parent) -Force | Out-Null }
$failed = [System.Collections.Generic.List[string]]::new()

foreach ($file in $found) {
    $rel = [IO.Path]::GetRelativePath($Root, $file)
    $ext = [IO.Path]::GetExtension($file)
    $sw  = [Diagnostics.Stopwatch]::StartNew()
    Push-Location (Split-Path $file -Parent)
    try {
        $out = switch ($ext) {
            '.ps1'  { & pwsh -NoProfile -File $file 2>&1 }
            '.sh'   { & bash $file 2>&1 }
            default { & node --test $file 2>&1 }   # .js / .ts
        }
        $code = $LASTEXITCODE
    }
    finally { Pop-Location }
    $sw.Stop()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    if ($code -eq 0) {
        Write-Host "PASS  $rel (${secs}s)"
    }
    else {
        $failed.Add($rel)
        Write-Host "FAIL  $rel (exit $code, ${secs}s)"
        foreach ($line in $out) { Write-Host "      | $line" }
    }
    if (-not $NoLog) {
        Write-CsvLog -Path $logPath -Row ([pscustomobject]@{
            Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            File      = $rel
            Result    = if ($code -eq 0) { 'PASS' } else { 'FAIL' }
            ExitCode  = $code
            Seconds   = $secs
        })
    }
}

Write-Host ''
Write-Host "discovered $($found.Count) test files: $($found.Count - $failed.Count) passed, $($failed.Count) failed"
if ($failed.Count) {
    foreach ($f in $failed) { Write-Host "  FAILED: $f" }
    exit 1
}
exit 0
