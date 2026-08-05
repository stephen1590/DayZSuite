#requires -Version 7
<#
  deploy-manifest.test.ps1 - V1: deleting a file from the repo must remove it from the box.

  The bug: Deploy-DayZServer's $items copies files one at a time and nothing ever reconciles,
  so anything ever shipped stays on the box forever. Deleting a script from the repo does NOT
  remove it from the box.

  Why not rsync --delete, which is how ConfigViewer solves the same problem: ConfigViewer's
  webroot is 100% deploy-owned. The DayZ server dir is not - persistence, logs, host.env,
  mpmissions/, profiles/, the game binaries and every box-owned config share it with the
  deploy's files, and any corpse would sit in the ROOT, interleaved with all of that. There is
  no directory boundary to point --delete at. So the deploy records what it PLACED and removes
  what it no longer places.

  The safety property that matters more than the feature: this can only ever remove a path
  the deploy itself wrote down last time. It has no opinion about anything else on the box.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'DeployManifest.ps1')

$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" }
    else     { $script:fail++; Write-Host "  [FAIL] $what" }
}
function SameSet($a, $b) {
    $x = @($a) | Sort-Object; $y = @($b) | Sort-Object
    (@($x).Count -eq @($y).Count) -and (-not (Compare-Object @($x) @($y) -SyncWindow 0))
}

$SD = if ($IsWindows) { 'C:\srv\dayz' } else { '/home/ubuntu/servers/dayz-server' }
$P  = { param($rel) Join-Path $SD $rel }

# --- 1. the core: what was placed last time and is not placed now is an orphan ---
Check (SameSet (Get-DeployOrphans -Previous @((& $P 'Build-AIPatrols.ps1'), (& $P 'prestart.sh')) `
                                  -Current  @((& $P 'prestart.sh')) -ServerDir $SD) `
               @((& $P 'Build-AIPatrols.ps1'))) `
    'a path in the previous manifest but not the current one is an orphan'

# --- 2. never remove something the deploy still ships ---------------------------
Check (SameSet (Get-DeployOrphans -Previous @((& $P 'prestart.sh')) -Current @((& $P 'prestart.sh')) -ServerDir $SD) @()) `
    'a path still shipped is never an orphan'

# --- 3. FIRST RUN IS INERT. No previous manifest = nothing to reconcile ----------
# The box has files the deploy placed before manifests existed. Treating "no record" as
# "not mine" is the only safe reading - the alternative deletes a box it has never seen.
Check (SameSet (Get-DeployOrphans -Previous @() -Current @((& $P 'prestart.sh')) -ServerDir $SD) @()) `
    'no previous manifest removes nothing - a first run cannot delete anything'

# --- 4. the one-time sweep: named corpses go even with no previous manifest ------
Check (SameSet (Get-DeployOrphans -Previous @() -Current @((& $P 'prestart.sh')) -ServerDir $SD `
                                  -Retired @('Build-AIBandits.ps1', 'Capture-OwnedDefaults.ps1')) `
               @((& $P 'Build-AIBandits.ps1'), (& $P 'Capture-OwnedDefaults.ps1'))) `
    'a Retired entry is swept even with no previous manifest (clears the pre-manifest backlog)'

# --- 5. a Retired entry that is BACK in $items is not removed -------------------
# Belt and braces: if someone re-adds a script and forgets to prune the sweep list, shipping
# wins over deleting. A deploy that removes the file it just copied is worse than a stale list.
Check (SameSet (Get-DeployOrphans -Previous @() -Current @((& $P 'Build-AIBandits.ps1')) -ServerDir $SD `
                                  -Retired @('Build-AIBandits.ps1')) @()) `
    'a Retired path that is shipped again is kept - shipping always beats sweeping'

# --- 5b. handing a file to the box must not delete it -----
# A config file can leave $items because the box now owns it. The manifest from the previous
# deploy would still list it as placed, so the next run would classify it as an orphan and
# remove it. "Stopped shipping it" and "retired it" are indistinguishable to a set difference,
# so the reconcile is told what it must never touch: anything the registry declares a surface,
# and anything under a deny-listed prefix. Both are things a deploy has no business deleting.
$protectedCases = @(
    @{ what = 'a registry-declared surface'; protect = @('custom-ce/custom_types.xml'); path = 'custom-ce/custom_types.xml' }
    @{ what = 'a deny-listed prefix';        protect = @('profiles/VPPAdminTools');     path = 'profiles/VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt' }
    @{ what = 'a file BENEATH a protected dir'; protect = @('custom-ce');               path = 'custom-ce/maps/dayzOffline.enoch/expansion_types.xml' }
)
foreach ($c in $protectedCases) {
    $full = & $P $c.path
    Check (SameSet (Get-DeployOrphans -Previous @($full) -Current @() -ServerDir $SD -Protected $c.protect) @()) `
        "protected - never an orphan: $($c.what)"
}
# ...and protection must not turn the reconcile off. An unprotected corpse still goes.
Check (SameSet (Get-DeployOrphans -Previous @((& $P 'Old-Builder.ps1'), (& $P 'custom-ce/custom_types.xml')) `
                                  -Current @() -ServerDir $SD -Protected @('custom-ce')) `
               @((& $P 'Old-Builder.ps1'))) `
    'protection is surgical - an unprotected retired script is still removed'

# --- 6. THE BLAST-RADIUS GUARD: never anything outside the server dir -----------
# $items ships 5 systemd units into /etc/systemd/system. Removing a unit is not a cleanup,
# it is an outage, and it needs sudo. The reconcile is scoped to the server dir, full stop.
$outside = if ($IsWindows) { 'C:\Windows\System32\drivers\etc\hosts' } else { '/etc/systemd/system/dayz-server.service' }
Check (SameSet (Get-DeployOrphans -Previous @($outside, (& $P 'gone.ps1')) -Current @() -ServerDir $SD) `
               @((& $P 'gone.ps1'))) `
    'a path outside the server dir is NEVER an orphan, even if it left the manifest'

# --- 7. traversal cannot escape the server dir ---------------------------------
$escape = Join-Path $SD '../../etc/passwd'
Check (SameSet (Get-DeployOrphans -Previous @($escape) -Current @() -ServerDir $SD) @()) `
    'a ../ path that resolves outside the server dir is refused'

# --- 8. the server dir ITSELF is never a removal target -------------------------
Check (SameSet (Get-DeployOrphans -Previous @($SD) -Current @() -ServerDir $SD) @()) `
    'the server dir itself is never an orphan'

# --- 9. round trip: what is written is what is read back ------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("dm-" + [Guid]::NewGuid().ToString('N') + ".json")
try {
    $placed = @((& $P 'prestart.sh'), (& $P 'custom-ce/custom-ce.json'))
    Write-DeployManifest -Path $tmp -Placed $placed
    Check (SameSet (Read-DeployManifest -Path $tmp) $placed) 'manifest round-trips the placed set'
    Check (SameSet (Read-DeployManifest -Path (Join-Path ([IO.Path]::GetTempPath()) 'no-such-manifest.json')) @()) `
        'a missing manifest reads as empty, never as an error'
    Set-Content -Path $tmp -Value '{ not json'
    Check (SameSet (Read-DeployManifest -Path $tmp) @()) `
        'a CORRUPT manifest reads as empty - it must degrade to doing nothing, never to deleting wrongly'
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

# --- 10. ON A REAL FILESYSTEM, and 11. actually wired into the deploy -----------
# These are regression guards: asserting a mechanism's SHAPE is not asserting that anything
# can USE it.
$box = Join-Path ([IO.Path]::GetTempPath()) ("box-" + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $box 'custom-ce') | Out-Null
    $keep    = Join-Path $box 'prestart.sh'
    $corpse  = Join-Path $box 'Build-AIPatrols.ps1'
    $boxOwn  = Join-Path $box 'host.env'            # never in a manifest - the deploy never places it
    'x' | Set-Content $keep; 'x' | Set-Content $corpse; 'secret' | Set-Content $boxOwn
    $mf = Join-Path $box '.deploy-manifest.json'
    Write-DeployManifest -Path $mf -Placed @($keep, $corpse)

    $gone = @(Get-DeployOrphans -Previous (Read-DeployManifest -Path $mf) -Current @($keep) -ServerDir $box |
              Where-Object { Test-Path $_ })
    foreach ($g in $gone) { Remove-Item -LiteralPath $g -Force }

    Check ((Test-Path $keep) -and -not (Test-Path $corpse)) `
        'end to end on disk: the retired file is gone, the shipped one stays'
    Check (Test-Path $boxOwn) `
        'a box-owned file the deploy never placed is untouched - it was never in the manifest'
    Write-DeployManifest -Path $mf -Placed @($keep)
    Check (SameSet (Read-DeployManifest -Path $mf) @($keep)) `
        'the manifest now records only what is still shipped, so the next run has nothing to do'
} finally { Remove-Item $box -Recurse -Force -ErrorAction SilentlyContinue }

# --- 12. the sweep list is DATA and the deploy reads it ------------------------
# A name in a script reads as a caller; a delete list is the opposite of a call, so it lives
# in a text file, not a script array.
$dzRoot = Split-Path -Parent $here
$retiredFile = Join-Path $dzRoot 'deploy/retired-paths.txt'
# A sweep list that survives its sweep is a standing hand-maintained list, which is precisely
# what the manifest replaced - so its ABSENCE is the correct end state and this asserts it
# stays absent.
Check (-not (Test-Path $retiredFile)) `
    'deploy/retired-paths.txt is absent - the one-time sweep is spent and must not become standing state'
Check (SameSet (Read-RetiredPaths -Path $retiredFile) @()) `
    'a missing sweep list reads as empty - manifest-only, never an error'
# The parser still has to work: reviving the file for a future one-off must not need new code.
$tmpSweep = Join-Path ([IO.Path]::GetTempPath()) ("sweep-" + [Guid]::NewGuid().ToString('N') + '.txt')
try {
    Set-Content -Path $tmpSweep -Value @('# a comment', '', 'Old-Thing.ps1   # trailing comment', '  Spaced.ps1  ')
    Check (SameSet (Read-RetiredPaths -Path $tmpSweep) @('Old-Thing.ps1', 'Spaced.ps1')) `
        'the parser still strips comments, blanks and surrounding space if the file is ever revived'
} finally { Remove-Item $tmpSweep -Force -ErrorAction SilentlyContinue }
# No "did a name leak back into a script" check here on purpose: scripts may MENTION a
# retired builder in a comment explaining that it is retired, and a mention is not a caller.

$deploy = Get-Content -Raw (Join-Path (Split-Path -Parent $here) 'Deploy-DayZServer.ps1')
Check ($deploy -match 'Get-DeployOrphans' -and $deploy -match 'Write-DeployManifest' -and
       $deploy -match "\.\s*\(Join-Path \`$PSScriptRoot 'DeployManifest\.ps1'\)") `
    'Deploy-DayZServer dot-sources the module AND calls both halves (logic that nothing calls is not a fix)'
# Scoped to the payload block, the same way Test-Configs reads it: a looser regex could match
# the dot-source line elsewhere in the file and pass even with the payload entry deleted.
$payloadBlock = [regex]::Match($deploy, '(?s)foreach \(\$f in (.*?)\) \{')
$shippedList = @([regex]::Matches($payloadBlock.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
Check ($payloadBlock.Success -and $shippedList -contains 'DeployManifest.ps1') `
    'DeployManifest.ps1 is in the root-file payload list, so it reaches deploy-stage on the box'
Check ($deploy -match '(?s)if \(\$Fix\) \{ Write-DeployManifest') `
    'the manifest is written ONLY under -Fix - a report run must leave the box exactly as it found it'

# The guard is only real if the DEPLOY passes it. Asserted separately from the logic because a
# mechanism can be correct and still be unused if nothing calls it.
Check ($deploy -match '-Protected \$protectedPaths') `
    'the deploy passes -Protected to the reconcile'
Check ($deploy -match '\$registryForGuard\.surfaces' -and $deploy -match '\$registryForGuard\.denyList') `
    'the protected set is DERIVED from the registry surfaces AND the denyList, not hand-listed'
# The guard must read the registry from $PSScriptRoot, not $ServerDir - the server copy is the
# one this deploy is about to REPLACE, so on the run that introduces a new protection the
# server copy does not have it yet. A guard derived from the OUTGOING (staged) truth protects
# everything except the change being made.
# Asserted by RESOLVING the path, not by matching the source text: a regex that only matches
# the code SHAPE can pass even when the path it resolves to is wrong (e.g. $deployDir, which
# does not hold the registry - it ships as '../config-registry.json' because $deployDir is the
# deploy/ subfolder). Asserting a mechanism's SHAPE is not asserting it works.
$guardCandidate = [regex]::Match($deploy, "foreach \(\`$cand in \(Join-Path (\`$\w+) 'config-registry\.json'\)")
Check $guardCandidate.Success 'the guard names a directory to read the outgoing registry from'
$guardVar = $guardCandidate.Groups[1].Value
Check ($guardVar -eq '$PSScriptRoot') `
    "the guard reads the registry from `$PSScriptRoot (got '$guardVar') - `$deployDir is the deploy/ subfolder and does NOT hold it"
# And the file really is there, in the repo layout AND therefore in deploy-stage on the box.
$resolved = Join-Path $dzRoot 'config-registry.json'
Check (Test-Path $resolved) "that path resolves to a real registry: $resolved"
$guardReg = Get-Content -Raw $resolved | ConvertFrom-Json
Check (@($guardReg.denyList | Where-Object { $_ }).Count -gt 0) `
    'the registry it reads actually carries the denyList the guard depends on'
Check ($deploy -match "(?m)^\s*\`$protectedPaths \+= 'custom-ce'") `
    'custom-ce is protected explicitly - it left $items but has no surface row of its own'

Write-Host "`ndeploy-manifest: $pass passed, $fail failed"
if ($fail) { exit 1 } else { exit 0 }
