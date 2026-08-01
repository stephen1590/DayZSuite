#requires -Version 7
<#
.SYNOPSIS
  Retired scripts are DELETED, and nothing still points at them.

  Standing rule (GameServices/CLAUDE.md): a migration ENDS AT DELETION. An abstraction that
  leaves the old path on disk is two mechanisms, not one. These three each had their job taken
  over and were then left lying around:

    Sync-Loadouts.ps1        the Loadouts became owned files in A2; the generic own-write path
                             replaced it. ZERO references anywhere in the repo when audited.
    Capture-OwnedDefaults.ps1 capture moved INTO own-write (2026-08-01) because capturing at
                             prestart read post-edit content and froze the EDIT as the baseline.
    Reconcile-Defaults.ps1   3-way merge for a game update that rewrites a baseline. Built
                             2026-07-29 and NEVER invoked by anything - so deleting it removes
                             no live behaviour. The CAPABILITY gap it leaves is real and is
                             recorded in the tracker; an unwired script was never covering it.

  This test is the ratchet: it fails if any of them reappears, or if a caller is re-added.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)

$RETIRED = @('Sync-Loadouts.ps1', 'Capture-OwnedDefaults.ps1', 'Reconcile-Defaults.ps1')

$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" }
    else     { $script:fail++; Write-Host "  [FAIL] $what" }
}

foreach ($s in $RETIRED) {
    Check (-not (Test-Path (Join-Path $repo "DayZ-Server/$s"))) "$s is deleted"
}

# Nothing may still invoke them. Docs/changelog may MENTION them (history is not a caller), so
# only executable sources count - a stale call is what actually breaks a boot or a deploy.
$srcs = Get-ChildItem $repo -Recurse -File -Include *.ps1, *.sh -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|archive|tests)[\\/]' }
foreach ($s in $RETIRED) {
    $hits = @($srcs | Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match [regex]::Escape($s) } |
             ForEach-Object { $_.FullName.Replace($repo, '').TrimStart('\', '/') })
    Check ($hits.Count -eq 0) "no script or shell file still invokes $s$(if($hits){' - ' + ($hits -join ', ')})"
}

Write-Host "`nno-dead-scripts: $pass passed, $fail failed"
exit ($fail -gt 0 ? 1 : 0)
