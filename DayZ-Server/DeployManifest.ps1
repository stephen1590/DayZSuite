#requires -Version 7
<#
.SYNOPSIS
  The deploy's record of what it PLACED, so it can remove what it no longer places.

.DESCRIPTION
  Dot-source this; it defines three functions and nothing else. No side effects on load.

  THE BUG IT CLOSES: `$items` in Deploy-DayZServer.ps1 copies files one at a time and nothing
  reconciles, so anything ever shipped stays on the box forever. Deleting a script from the
  repo does NOT remove it from the box; every retirement leaves a corpse. Eight of them were
  measured on prod on 2026-08-01, including three builders retired eleven days earlier.

  WHY NOT `rsync --delete`, which solves the identical problem for ConfigViewer in one line:
  ConfigViewer's webroot is entirely deploy-owned, so a directory boundary exists. The DayZ
  server dir has none. Persistence, logs, host.env, mpmissions/, profiles/, the game binaries
  and every box-owned config sit in the same tree as the deploy's files, and the corpses are
  in the ROOT, interleaved with all of it. No scoping of --delete reaches them safely.

  THE SAFETY PROPERTY, which matters more than the cleanup: this can only ever remove a path
  the deploy itself recorded placing. It forms no opinion about anything else on the box. Its
  three hard limits, each with a test:
    - a path outside ServerDir is never a target (the 5 systemd units in /etc are in `$items`;
      removing a unit is an outage, not a cleanup)
    - a path still being shipped is never a target, even if a sweep list names it
    - a missing OR corrupt manifest reads as empty, so the failure mode is doing nothing
#>

# Read the previous run's record. Absent or unreadable both mean "no record", which means
# "remove nothing" - the only safe reading. A parse error here must never become a deletion.
function Read-DeployManifest {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    try {
        $doc = Get-Content -Raw $Path | ConvertFrom-Json
        return @($doc.placed | Where-Object { $_ })
    } catch { return @() }
}

# The one-time sweep list, kept as DATA. It names retired scripts, and three gates assert that a
# retired script's name appears in no .ps1/.sh - rightly, since a name in a script reads as a
# caller. A path in a delete list is the opposite of a call, so it lives in a text file.
# Missing file = empty list = the reconcile falls back to manifest-only. Never an error.
function Read-RetiredPaths {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    try {
        return @(Get-Content -LiteralPath $Path |
                 ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
                 Where-Object { $_ })
    } catch { return @() }
}

function Write-DeployManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Placed
    )
    $doc = [ordered]@{
        _readme = 'Written by Deploy-DayZServer.ps1. The paths this deploy placed. The next ' +
                  'deploy removes what it placed before and no longer places. Deleting this ' +
                  'file is safe: reconcile goes inert until the next deploy rewrites it.'
        written = (Get-Date -Format 'o')
        placed  = @($Placed | Sort-Object -Unique)
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $doc | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding utf8
}

<#
.SYNOPSIS
  What this deploy should remove: placed last time, not placed now, and inside the server dir.
.PARAMETER Retired
  A one-time sweep list of ServerDir-relative paths, for corpses that predate the manifest.
  Shipping always wins over sweeping - a name here that is back in $items is kept. Prune an
  entry once every box has run one deploy with it; a permanent list is memory-maintained
  state, which is the disease this mechanism exists to cure.

.PARAMETER Protected
  ServerDir-relative paths or prefixes this must NEVER remove, whatever the manifest says.

  The near miss that added it, 2026-08-02: seven config files left `$items` because the box
  owns them now. The previous manifest still listed them as placed, so the next run would have
  read them as orphans and deleted them - taking Expansion loot registration and the admin
  list with it. **"We stopped shipping it" and "we retired it" are the same set difference.**
  They cannot be told apart from the manifest alone, so the caller declares what is off
  limits: every registry surface, and every deny-listed prefix. A deploy has no business
  deleting either. Protection is by prefix, so a whole directory can be handed over at once.
#>
function Get-DeployOrphans {
    param(
        [AllowEmptyCollection()][string[]]$Previous  = @(),
        [AllowEmptyCollection()][string[]]$Current   = @(),
        [Parameter(Mandatory)][string]$ServerDir,
        [AllowEmptyCollection()][string[]]$Retired   = @(),
        [AllowEmptyCollection()][string[]]$Protected = @()
    )
    # Compare on normalised full paths so 'a/../b' and 'b' cannot disagree. GetFullPath is
    # pure string math - it does not touch the disk, so a path that no longer exists still
    # normalises, which is exactly the case we are here for.
    $norm = { param($p) if ([string]::IsNullOrWhiteSpace($p)) { $null } else { [IO.Path]::GetFullPath($p) } }
    $rootFull = (& $norm $ServerDir).TrimEnd([IO.Path]::DirectorySeparatorChar, '/')
    $inRoot = {
        param($full)
        # Prefix match on the root PLUS a separator, so /srv/dayz-server-old is not "inside"
        # /srv/dayz-server. The root itself is excluded: never a removal target.
        $full -and $full.Length -gt $rootFull.Length + 1 -and
        ($full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar) -or $full.StartsWith($rootFull + '/'))
    }

    $currentFull = @($Current  | ForEach-Object { & $norm $_ } | Where-Object { $_ })
    $candidates  = @($Previous | ForEach-Object { & $norm $_ } | Where-Object { $_ })
    $candidates += @($Retired  | Where-Object { $_ } | ForEach-Object { & $norm (Join-Path $rootFull $_) })

    # Normalised protected prefixes. Blank entries are dropped: one would protect everything
    # and silently turn the reconcile off, which fails safe but fails silently.
    $protectedFull = @($Protected | Where-Object { $_ } |
                       ForEach-Object { (& $norm (Join-Path $rootFull $_)).TrimEnd([IO.Path]::DirectorySeparatorChar, '/') } |
                       Where-Object { $_ })
    $isProtected = {
        param($full)
        foreach ($p in $protectedFull) {
            if ($full -eq $p -or $full.StartsWith($p + [IO.Path]::DirectorySeparatorChar) -or $full.StartsWith($p + '/')) { return $true }
        }
        $false
    }

    @($candidates | Sort-Object -Unique |
        Where-Object { & $inRoot $_ } |
        Where-Object { $_ -notin $currentFull } |
        Where-Object { -not (& $isProtected $_) })
}
