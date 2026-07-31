#requires -Version 7
<#
.SYNOPSIS
  Table-driven contract test for the DECLARED mission config surfaces.
  Supersedes ce-logging-surface.test.ps1 (that file tested one surface with the same
  assertions copy-pasted three times; this drives them from a table - one mechanism, N cases).

  Scope source (owner, 2026-07-30): https://low.ms/knowledgebase/dayz-server-configuration
  Every config file that reference lists must be DECLARED in config-registry.json, so nothing
  the docs call a config surface is invisible to the gate, the mirror and the web editor.

  Owner classification decisions (2026-07-30):
   - the six admin-tunable files      -> category 'owned',     web 'file'  (two-copy editor)
   - mapgroupproto.xml (1.2-1.5 MB)   -> category 'reference', web 'view'  (read-only: game-owned
                                          loot positions, rewritten by updates, too big to edit
                                          in-browser and near the API's 2 MB write cap)
   - init.c (Enforce script, not cfg) -> category 'reference', web 'view'  (code belongs to the
                                          deploy pipeline + git, not a web textbox; no compile check)

  Also asserted: every row carries 'about' + 'aboutUrl' (shown under the filename in the editor),
  and neither may contain a TAB or newline - both ride the TAB-delimited CONFIG_MAP line, where a
  stray TAB would silently split into a phantom field (same trap already guarded for label/group).
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

$registry  = Get-Content -Raw (Join-Path $root 'config-registry.json') | ConvertFrom-Json
$overrides = Get-Content -Raw (Join-Path $root 'config-overrides.json') | ConvertFrom-Json

$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++ }
    else     { $script:fail++; Write-Host "  [FAIL] $what" -ForegroundColor Red }
}

$missions = @('dayzOffline.sakhal', 'dayzOffline.enoch', 'dayzOffline.chernarusplus')

# file -> expected category / web / check. Verified present in ALL THREE missions on the box.
$expected = @(
    @{ f = 'db/types.xml';             cat = 'owned';     web = 'file'; chk = 'xml'  }
    @{ f = 'db/events.xml';            cat = 'owned';     web = 'file'; chk = 'xml'  }
    @{ f = 'db/globals.xml';           cat = 'owned';     web = 'file'; chk = 'xml'  }
    @{ f = 'cfgeconomycore.xml';       cat = 'owned';     web = 'file'; chk = 'xml'  }
    @{ f = 'cfgweather.xml';           cat = 'owned';     web = 'file'; chk = 'xml'  }
    @{ f = 'cfgspawnabletypes.xml';    cat = 'owned';     web = 'file'; chk = 'xml'  }
    @{ f = 'cfgplayerspawnpoints.xml'; cat = 'owned';     web = 'file'; chk = 'xml'  }
    @{ f = 'mapgroupproto.xml';        cat = 'reference'; web = 'view'; chk = 'xml'  }
    @{ f = 'init.c';                   cat = 'reference'; web = 'view'; chk = 'none' }
)

foreach ($m in $missions) {
    foreach ($e in $expected) {
        $rel  = "mpmissions/$m/$($e.f)"
        $rows = @($registry.surfaces | Where-Object { $_.box -eq $rel })

        Check ($rows.Count -eq 1) "$rel : exactly one registry row (found $($rows.Count))"
        if ($rows.Count -ne 1) { continue }
        $row = $rows[0]

        Check ($row.category -eq $e.cat)  "$rel : category '$($e.cat)' (got '$($row.category)')"
        Check ($row.web      -eq $e.web)  "$rel : web '$($e.web)' (got '$($row.web)')"
        Check ($row.check    -eq $e.chk)  "$rel : check '$($e.chk)' (got '$($row.check)')"
        Check ($row.scope    -eq "map:$m") "$rel : scope 'map:$m' (got '$($row.scope)')"
        Check (@($registry.generated) -notcontains $rel) "$rel : not a 'generated' artifact"

        # about + aboutUrl: shown under the filename in the editor, sourced from the KB page
        Check ([bool]"$($row.about)".Trim())    "$rel : has a non-empty 'about'"
        Check ("$($row.about)" -notmatch "[`t`n]") "$rel : 'about' has no TAB/newline (CONFIG_MAP is TAB-delimited)"
        Check ("$($row.aboutUrl)" -like 'https://low.ms/*') "$rel : 'aboutUrl' points at the KB source (got '$($row.aboutUrl)')"
        Check ("$($row.aboutUrl)" -notmatch "[`t`n]") "$rel : 'aboutUrl' has no TAB/newline"

        # a 'view' row must never also be writable - web:'view' is enforced read-only end to end
        if ($e.web -eq 'view') { Check (-not $row.writable) "$rel : view row is not 'writable'" }

        # an OWNED row must not carry a wholeFiles blob - that is the deprecated pattern
        $wf = $overrides.wholeFiles
        $hasBlob = $false
        if ($wf -and $wf.mpmissions -and $wf.mpmissions.$m) {
            $hasBlob = ($wf.mpmissions.$m.PSObject.Properties.Name -contains $e.f)
        }
        Check (-not $hasBlob) "$rel : no wholeFiles blob in config-overrides.json (deprecated whole-file pattern)"
    }
}


# --- generator INPUTS are not owned files ---------------------------------------------------
# server-settings.json is not a file the game reads: Apply-ServerCfg turns it into serverDZ.cfg
# (a read-only generated artifact). CONFIG-ARCHITECTURE.md's target table calls this Category B -
# "UI: edits the inputs". Classifying it 'owned' put it in the box's OWNED_FILES, which permits
# own-write - a whole-file replace that bypasses the 14-toggle allowlist Apply-ServerCfg enforces,
# so an admin could store keys the renderer silently drops. An input must never be own-writable.
$inputs = @($registry.surfaces | Where-Object { $_.category -eq 'input' })
Check ($inputs.Count -ge 1) "at least one surface is classified 'input' (generator parameter set)"
$ss = @($registry.surfaces | Where-Object { $_.box -eq 'server-settings.json' })
Check ($ss.Count -eq 1) "server-settings.json has exactly one registry row"
if ($ss.Count -eq 1) {
    Check ($ss[0].category -eq 'input') "server-settings.json is category 'input', not 'owned' (got '$($ss[0].category)')"
    # Deploy-Api's OWNED_FILES predicate is: category -eq 'owned' -and box -and web -ne 'types'
    $wouldBeOwnWritable = ($ss[0].category -eq 'owned' -and $ss[0].box -and $ss[0].web -ne 'types')
    Check (-not $wouldBeOwnWritable) "server-settings.json is NOT own-writable (excluded from OWNED_FILES)"
}
foreach ($i in $inputs) {
    Check ($i.category -ne 'owned') "input surface '$($i.name)' is not also 'owned'"
}

Write-Host "`nregistry-surface-contract: $pass passed, $fail failed"
exit ($fail -gt 0 ? 1 : 0)
