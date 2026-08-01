#requires -Version 7
<#
.SYNOPSIS
  Every owned file must be mirrored to the repo AND seedable back onto a fresh box.

  WHY (found 2026-08-01): `seed` and `mirror` are the same mechanism seen from both ends.
  Pull-Configs pulls the live box file INTO the row's `seed` path - that is the git history.
  Deploy-DayZServer copies that same `seed` back to the box ONLY when the box is missing it -
  that is disaster recovery. So `seed: null` means BOTH "the change never reaches git" AND
  "a rebuilt box silently reverts to the vendor default".

  That is the no-data-loss rule CONFIG-ARCHITECTURE.md wrote for the override-engine delete:
  once nothing patches the file at boot, THE SEED IS THE VALUE. It was measured on
  db/types.xml, where 19 restored vehicle lifetimes existed on the box and nowhere else.

  Two invariants, both gate-asserted here rather than written in a doc:
   1. an owned row Pull-Configs CAN validate (check json|xml) must be seeded + mirror:'live'
   2. an owned row it CANNOT validate (check none) must NOT claim mirror:'live' - the puller
      skips it with a warning, so declaring one would be a mirror that silently never runs.
#>
$ErrorActionPreference = 'Stop'
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$root     = Split-Path -Parent $here
$registry = Join-Path $root 'config-registry.json'
$parser   = Join-Path $root 'ConfigParse.ps1'

$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what, [string[]]$detail = @()) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" }
    else { $script:fail++; Write-Host "  [FAIL] $what"; foreach ($d in $detail) { Write-Host "         $d" } }
}

$rows  = (Get-Content -Raw -LiteralPath $registry | ConvertFrom-Json).surfaces
$owned = @($rows | Where-Object { $_.category -eq 'owned' -and $_.box })

# Which check kinds can actually be validated? PROBE the shared validator rather than
# hardcoding or grepping - adding a kind to ConfigParse.ps1 is what unlocks a row here.
. $parser
$probe = @{ json = '{ "a": 1 }'; xml = '<r><a/></r>'; text = 'plain' }
$validKinds = @($probe.Keys | Where-Object { Test-ConfigParses $probe[$_] $_ } | Sort-Object)
Check ($validKinds.Count -ge 2) "ConfigParse.ps1 validates kinds (found: $($validKinds -join ', '))"

$mirrorable = @($owned | Where-Object { $validKinds -contains [string]$_.check })
$opaque     = @($owned | Where-Object { $validKinds -notcontains [string]$_.check })
Write-Host "  owned rows: $($owned.Count)  mirrorable: $($mirrorable.Count)  opaque(check not validatable): $($opaque.Count)"

# 1. seeded
$noSeed = @($mirrorable | Where-Object { -not $_.seed } | ForEach-Object { "$($_.name) ($($_.box))" })
Check ($noSeed.Count -eq 0) "every mirrorable owned row has a seed (a rebuilt box keeps the value)" $noSeed

# 2. mirrored live
$noMirror = @($mirrorable | Where-Object { $_.mirror -ne 'live' } | ForEach-Object { "$($_.name) mirror=$($_.mirror)" })
Check ($noMirror.Count -eq 0) "every mirrorable owned row is mirror:'live' (the change reaches git)" $noMirror

# 3. the seed path is DERIVABLE from the box path, never hand-picked
$badPath = @($mirrorable | Where-Object { $_.seed -and $_.seed -ne ('deploy/' + $_.box) } |
             ForEach-Object { "$($_.name): seed='$($_.seed)' want='deploy/$($_.box)'" })
Check ($badPath.Count -eq 0) "every seed is exactly 'deploy/' + its box path" $badPath

# 4. no two rows write the same seed file
$dupes = @($rows | Where-Object { $_.seed } | Group-Object seed | Where-Object Count -gt 1 |
           ForEach-Object { "$($_.Name) claimed by $($_.Count) rows" })
Check ($dupes.Count -eq 0) 'no two registry rows share a seed path' $dupes

# 5. an opaque row must NOT claim a mirror the puller will skip
$lyingMirror = @($opaque | Where-Object { $_.mirror -eq 'live' } |
                 ForEach-Object { "$($_.name) check='$($_.check)' claims mirror:'live' but Pull-Configs skips it" })
Check ($lyingMirror.Count -eq 0) "no opaque row claims a mirror that never runs" $lyingMirror
if ($opaque.Count) {
    Write-Host "  [note] $($opaque.Count) owned row(s) are NOT mirrored - Pull-Configs has no validator for their check kind:"
    foreach ($o in $opaque) { Write-Host "         $($o.name) (check='$($o.check)') $($o.box)" }
}

Write-Host "`nowned-mirror-contract: $pass passed, $fail failed"
exit ($fail -gt 0 ? 1 : 0)
