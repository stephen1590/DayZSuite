#requires -Version 7
<#
  deny-list.test.ps1 - the paths that must never become a web surface.

  WRITTEN BEFORE THE denyList EXISTS, so the first run must fail.

  WHY THIS IS A SECURITY BOUNDARY AND NOT A PREFERENCE. Today a file with no registry row is
  already invisible, so nothing is exposed and this list changes no behaviour. The moment
  opt-in-by-default ships (WS-S), the default inverts: every .json/.xml under the server dir
  becomes visible unless something says otherwise, and this list becomes the only thing
  standing between the UI and player Steam64 IDs, admin permissions and a STEAM_API_KEY field.

  The owner rejected a content scanner for this, correctly: *"You're just applying blanket
  guesses as a dynamic solution... this shouldn't change often and secrets should be
  known/static to begin with. Just hide them from the UI."* So it is a static list of four
  known folders plus persistence and vendor geometry - and the thing that makes it real is
  this assertion, not the list. A boundary maintained by memory is not one.

  What is asserted: the list exists, it covers the six declared prefixes, and NO surface row
  resolves underneath any of them. That last one is the ratchet - it fails the day someone
  adds a row under a denied path, whether by hand or by a resolver refactor.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dzRoot = Split-Path -Parent $here

$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" }
    else     { $script:fail++; Write-Host "  [FAIL] $what" }
}

$registry = Get-Content -Raw (Join-Path $dzRoot 'config-registry.json') | ConvertFrom-Json

# --- 1. the declaration exists -------------------------------------------------
# Filter nulls: an ABSENT denyList surfaces as $null, and @($null) has Count 1 - which made the
# first version of this assertion pass against a registry that declared nothing at all.
$deny = @($registry.denyList | Where-Object { $_ })
Check ($deny.Count -gt 0) "config-registry.json declares a denyList ($($deny.Count) entries)"

# Every entry carries its reason. A bare path invites someone to delete it as noise.
Check (-not ($deny | Where-Object { -not $_.path -or -not $_.why })) `
    'every denyList entry declares both a path and a why'

# --- 2. it covers the six paths the model names --------------------------------
# CONFIG-ARCHITECTURE.md "Deny list" section. Named individually so dropping one is a
# failure rather than a smaller number nobody reads.
$required = @(
    'profiles/users'           # player profile data
    'profiles/VPPAdminTools'   # STEAM_API_KEY field + BanList player IDs
    'profiles/CodeLock'        # player lock permissions
    'profiles/LiveTracker'     # 20s runtime snapshots, would churn git every pull
    'storage_'                 # persistence, not config
    'mapgroup'                 # vendor geometry: 25 files, 52.8 MB, never edited
)
$declared = @($deny | ForEach-Object { $_.path })
foreach ($r in $required) {
    Check (($declared | Where-Object { $_ -like "$r*" }).Count -gt 0) "denyList covers '$r'"
}

# --- 3. THE RATCHET: no surface row resolves under a denied path ---------------
# Today this holds trivially - none of those paths has a row. It is here for the day the
# default inverts, and for the refactor that would otherwise silently drop one.
$rows = @($registry.surfaces | ForEach-Object {
    $p = if ($_.box) { $_.box } elseif ($_.dir) { $_.dir } else { $null }
    if ($p) { [pscustomobject]@{ name = $_.name; path = "$p".Trim() } }
})
$violations = @(foreach ($row in $rows) {
    foreach ($d in $declared) {
        $dp = "$d".Trim().TrimEnd('/')
        # A blank entry would prefix-match EVERY path and report the whole registry as a
        # violation. Skip it here; assertion 2 is what fails a malformed entry.
        if (-not $dp) { continue }
        if ($row.path -eq $dp -or $row.path -like "$dp/*" -or $row.path -like "$dp*") {
            [pscustomobject]@{ row = $row.name; path = $row.path; deny = $d }
        }
    }
})
Check ($violations.Count -eq 0) `
    "no surface row resolves under a denied path$(if($violations){' - ' + (($violations | ForEach-Object { "$($_.row) ($($_.path)) under $($_.deny)" }) -join '; ')})"

# --- 4. the generated set does not smuggle one back in -------------------------
$genViolations = @(foreach ($g in $registry.generated) {
    foreach ($d in $declared) {
        $dp = "$d".Trim().TrimEnd('/')
        # A blank entry would prefix-match EVERY path and report the whole registry as a
        # violation. Skip it here; assertion 2 is what fails a malformed entry.
        if (-not $dp) { continue }
        if ("$g" -like "$dp*") { "$g under $d" }
    }
})
Check ($genViolations.Count -eq 0) `
    "no 'generated' entry sits under a denied path$(if($genViolations){' - ' + ($genViolations -join '; ')})"

# --- 5. OWNED IS NOT EDITABLE -------------------------------------------------
# Ownership is who writes the file LAST; editability is whether the UI offers a write path.
# Flipping a row to `owned` to unlock a writer uses the ownership field as an access flag - which
# is how `category` became one, and why every file needs a hand-declared row today.
#
# The near miss that added this, 2026-08-02: the plan for retiring `spawn-write` was to reclassify
# map-points.json from 'reference' to 'owned' so own-write would accept it. That file is a FROZEN
# legacy store, read-only since the map inversion, and its live counterpart is rebuilt by a builder
# every prestart. Marking it owned would have declared a generated, superseded file editable purely
# to unlock a verb nobody can call - the verb was already dead behind MAP_POINTS_DEPRECATED.
#
# The checkable half of the rule: a file a BUILDER writes cannot also be one the UI writes. Two
# writers, one file, and the builder wins at every restart - so the edit is silently discarded.
$genPatterns = @($registry.generated | Where-Object { $_ })
$editable = @($registry.surfaces | Where-Object { $_.box -and $_.category -in @('owned', 'input') })
$clash = @(foreach ($row in $editable) {
    foreach ($g in $genPatterns) {
        # registry globs use '*' for the mission segment
        $rx = '^' + [regex]::Escape("$g").Replace('\*', '[^/]*') + '$'
        if ("$($row.box)".Trim() -match $rx) { "$($row.name) ($($row.box)) is generated by a builder" }
    }
})
Check ($clash.Count -eq 0) `
    "no editable row is also a builder output$(if($clash){' - ' + ($clash -join '; ')})"

Write-Host "`ndeny-list: $pass passed, $fail failed"
if ($fail) { exit 1 } else { exit 0 }
