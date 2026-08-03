#requires -Version 7
<#
  webroot-clean.test.ps1 - nothing ships to the public webroot that is not the app.

  WRITTEN BEFORE THE MOVE, so it must FAIL on first run.

  Deploy-ConfigViewer.ps1 rsyncs the WHOLE `web/` tree and carries exactly one filter
  (`--filter=P /tiles/***`, which protects tiles from --delete). So anything sitting in
  `web/` is served publicly, and `chat-format.test.js` was - it had been readable at the
  webroot since it shipped.

  The fix is the MOVE, not an rsync exclude. An exclude leaves the file in the shipped tree
  and makes correctness depend on a filter staying right; moving it out means there is
  nothing to filter. Same reason the deny list beats a content scanner.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$script:tests = 0; $script:fails = 0
function Assert([string]$name, [bool]$cond, [string]$why = '') {
    $script:tests++
    if ($cond) { Write-Host "  ok: $name" }
    else { $script:fails++; Write-Host "FAIL: $name"; if ($why) { Write-Host "      $why" } }
}

$webRoot = Join-Path $root 'ConfigViewer/web'
# tiles/ is a ~300 MB derived pyramid and vendor/ is provisioned by the deploy - neither is ours
# and walking tiles cost 17s on every deploy gate. Prune them at enumeration, not with a filter.
$skip = @('tiles', 'vendor')
$found = [System.Collections.Generic.List[string]]::new()
foreach ($f in (Get-ChildItem $webRoot -File -ErrorAction SilentlyContinue)) { $found.Add($f.FullName) }
foreach ($dir in (Get-ChildItem $webRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $skip })) {
    foreach ($f in (Get-ChildItem $dir.FullName -File -Recurse -ErrorAction SilentlyContinue)) { $found.Add($f.FullName) }
}
$isTest = '\.(test|spec)\.(js|mjs|ts)$'
$strays = @($found | Where-Object { $_ -match $isTest } |
            ForEach-Object { $_.Substring($webRoot.Length + 1) } | Sort-Object -Unique)

Assert "no test file under ConfigViewer/web (the shipped tree)" `
    ($strays.Count -eq 0) `
    "SHIPPED TO THE PUBLIC WEBROOT: $($strays -join ', '). Deploy-ConfigViewer rsyncs all of web/ with no test exclude. Move the test to ConfigViewer/tests/ - the runner finds it there just the same."

Write-Host ''
Write-Host "TESTS: $($script:tests), FAILED: $($script:fails)"
if ($script:fails) { exit 1 } else { exit 0 }
