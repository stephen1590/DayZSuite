#requires -Version 7
<#
  deploy-ships-code-only.test.ps1 - the deploy stops stamping server-owned config.

  WRITTEN BEFORE THE REMOVAL, so it must FAIL on first run.

  Owner, 2026-08-02: "those files are all owned by the server. We should not touch them, but
  they should have a backup process."

  Until now $items shipped seven config files DRIFT-OVERWRITE - hash-compared and re-copied
  whenever they differed - so the deploy stamped the box's copy on EVERY run, not just a fresh
  one. Five are Expansion/custom CE loot definitions; two are VPP admin permission data.

  Removing them is behaviour-neutral TODAY and that was verified before doing it, not assumed:
  the 2026-08-02 prod run reported all seven InSync, so the box copy and the repo copy were
  byte-identical at the moment the deploy stopped touching them. Freezing them freezes them at
  exactly what the repo holds.

  The backup that remains is the repo's own copy under DayZ-Server/deploy/, which is what the
  deploy used to ship FROM. That is a static backup and it is honest to call it that: it is
  correct only while nothing on the box rewrites these files, which is true today (all seven
  are web:'view' or have no surface row at all, so no editor can reach them). The moment one
  becomes writable it needs a real mirror, and that is blocked on a classification gap the
  registry does not currently express - see the tracker.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dzRoot = Split-Path -Parent $here

$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what, [string[]]$detail = @()) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" }
    else { $script:fail++; Write-Host "  [FAIL] $what"; foreach ($d in $detail) { Write-Host "         $d" } }
}

$deploy = Get-Content -Raw (Join-Path $dzRoot 'Deploy-DayZServer.ps1')

# Every Src the $items array ships. Both quoting styles the array uses.
$srcs = @([regex]::Matches($deploy, 'Src\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
Check ($srcs.Count -gt 10) "read the `$items ship list ($($srcs.Count) entries)"

# --- 1. no server-owned config ships -------------------------------------------
$configPrefixes = @('custom-ce/', 'profiles/VPPAdminTools/')
$shipped = @($srcs | Where-Object { $s = $_; ($configPrefixes | Where-Object { $s -like "$_*" }).Count -gt 0 })
Check ($shipped.Count -eq 0) `
    "the deploy ships no server-owned config" `
    @("STILL SHIPPED: $($shipped -join ', ')",
      "The box owns these. A deploy that overwrites them is a config push, not a code ship.")

# --- 2. nor any .json/.xml that is not code ------------------------------------
# init.c, .pbo, .sh, .ps1, unit files and templates are code. A bare data file is not.
$dataShipped = @($srcs | Where-Object { $_ -match '\.(json|xml)$' } |
                Where-Object { $_ -notmatch 'config-registry\.json$' })   # the registry IS code - box tooling reads it
Check ($dataShipped.Count -eq 0) `
    "the deploy ships no loose .json/.xml data" `
    @("STILL SHIPPED: $($dataShipped -join ', ')")

# --- 3. the backup still exists -----------------------------------------------
# Removing the ship must not also remove the copy. These are the disaster-recovery source.
foreach ($rel in 'deploy/custom-ce/custom-ce.json',
                 'deploy/custom-ce/custom_types.xml',
                 'deploy/custom-ce/expansion_types.xml',
                 'deploy/custom-ce/expansion_spawnabletypes.xml',
                 'deploy/custom-ce/maps/dayzOffline.enoch/expansion_types.xml',
                 'deploy/profiles/VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt',
                 'deploy/profiles/VPPAdminTools/Permissions/UserGroups/UserGroups.json') {
    Check (Test-Path (Join-Path $dzRoot $rel)) "backup copy still in the repo: $(Split-Path $rel -Leaf)"
}

# --- 4. none of them is writable, which is what makes a STATIC backup honest ----
$registry = Get-Content -Raw (Join-Path $dzRoot 'config-registry.json') | ConvertFrom-Json
# The real hazard is writable AND unmirrored - a backup that goes stale on the first edit.
# Writable-and-mirrored is fine and already exists: expansion_types_tuning.xml and its Enoch
# twin are the web-edited CE tuning pair, category 'owned' with seed + mirror:'live'. They sit
# under custom-ce/ beside the files this test freezes, which is exactly why the check is
# "is it backed up", not "is it writable".
$unbacked = @($registry.surfaces | Where-Object {
    $_.box -and ($_.box -like 'custom-ce/*' -or $_.box -like 'profiles/VPPAdminTools/*') -and
    $_.category -in @('owned', 'input') -and $_.mirror -ne 'live' })
Check ($unbacked.Count -eq 0) `
    "every writable file under these paths is mirrored, so its backup cannot go stale" `
    @("WRITABLE BUT UNMIRRORED: $(($unbacked | ForEach-Object { $_.name }) -join ', ')",
      "Deploy-Api puts owned/input rows in OWNED_FILES and own-write accepts them. A writable",
      "file with only a static repo copy has a backup that is wrong the first time it is edited.")

Write-Host "`ndeploy-ships-code-only: $pass passed, $fail failed"
if ($fail) { exit 1 } else { exit 0 }
