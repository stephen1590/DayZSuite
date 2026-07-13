# Shared helpers for Pull-DayZServer.ps1 / Sync-VPPCoordinates.ps1 — dot-source, not a run
# target. ONE place for the exclude categories and deployer.env resolution so callers can't drift.

# Runtime logs / crash dumps — noise, never synced in either direction.
$DZ_LOG_EXCLUDES = @(
    "--exclude=*.log"
    "--exclude=profiles/*.RPT"
    "--exclude=profiles/*.ADM"
    "--exclude=profiles/*.mdmp"
    "--exclude=profiles/crash_*"
)

# Live save/persistence state — players.db + world, per mission. The server is the
# main copy of this, so a PUSH protects it by default (only -Force overwrites it);
# a PULL brings it down by default. Excluded == protected from --delete too.
$DZ_SAVE_EXCLUDES = @(
    "--exclude=mpmissions/*/storage_*"
)

# Rebuildable heavy data — the DayZ app, workshop @mods, engine binaries, local
# backups. update.sh regenerates all of it on any host, so it's skipped unless -Force.
$DZ_HEAVY_EXCLUDES = @(
    "--exclude=steamapps/"
    "--exclude=addons/"
    "--exclude=dta/"
    "--exclude=*.so"
    "--exclude=DayZServer"
    "--exclude=@*/"      # every workshop mod folder, present and future — update.sh rebuilds them
    "--exclude=backups/"
)

# RemoteHost/RemoteUser are dev-machine-local (which box to reach) — never host.env content,
# see Deploy-DayZServer.ps1's deployer.env for the same idea. Fills in whichever of the two
# the CALLER didn't pass explicitly, from deployer.env beside the script. A no-op if both were
# already given, or if deployer.env doesn't have that key — Assert-DZHost below catches
# anything still unset (in practice, just a missing host; RemoteUser has its own "ubuntu"
# param default so it's never actually blank).
function Resolve-DZDeployerEnv {
    param(
        [string]$ScriptRoot,
        [ref]$RemoteHost,
        [ref]$RemoteUser,
        [hashtable]$BoundParameters
    )
    if ($BoundParameters.ContainsKey('RemoteHost') -and $BoundParameters.ContainsKey('RemoteUser')) { return }
    $deployerEnv = Join-Path $ScriptRoot "deployer.env"
    if (-not (Test-Path $deployerEnv)) { return }
    foreach ($line in Get-Content $deployerEnv) {
        if (-not $BoundParameters.ContainsKey('RemoteHost') -and $line -match '^\s*DEPLOY_REMOTE_HOST\s*=\s*(.+?)\s*$') { $RemoteHost.Value = $Matches[1] }
        if (-not $BoundParameters.ContainsKey('RemoteUser') -and $line -match '^\s*DEPLOY_REMOTE_USER\s*=\s*(.+?)\s*$') { $RemoteUser.Value = $Matches[1] }
    }
}

# Fail early if the host fields were blanked out.
function Assert-DZHost {
    param([hashtable]$Fields)   # name -> value
    foreach ($k in $Fields.Keys) {
        if (-not $Fields[$k]) {
            Write-Error "Set -$k — host info not configured. Copy deployer.env.example to deployer.env and set DEPLOY_REMOTE_HOST there, or pass -$k on the command line."
            exit 2
        }
    }
}

# One rsync invocation for both directions. Dry-run unless -Execute (read-only by
# default, per the project rule). --delete makes the destination mirror the source
# within the non-excluded set.
function Invoke-DZSync {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][string]$Dst,
        [string[]]$Excludes = @(),
        [switch]$Execute,
        [Parameter(Mandatory)][string]$LogFile,
        [string]$Label = "sync"
    )
    # Build ONE flat argument array. Do NOT assign a flag list through an if-expression
    # and then splat it: a one-element array (@("--dry-run")) collapses to a bare string
    # in the output stream, and splatting a string feeds rsync its characters
    # ("-","-","d","r","y",...). Starting from @() and using += keeps it an array.
    # --mkpath creates a missing destination path (rsync won't make parent dirs);
    # needed on the first push to a fresh host. Requires rsync >= 3.2.3.
    $rsyncArgs = @("-az", "--delete", "--mkpath", "--stats", "-e", "ssh -o ConnectTimeout=10", "--log-file=$LogFile")
    if (-not $Execute) { $rsyncArgs += "--dry-run" }
    $rsyncArgs += $Excludes
    $rsyncArgs += $Src, $Dst

    $mode = if ($Execute) { "EXECUTE (writing)" } else { "DRY-RUN (no changes)" }
    Write-Host "$Label — $mode"
    Write-Host "  $Src -> $Dst"
    # Out-Host so rsync's stdout streams to the console instead of becoming the
    # function's return value — otherwise the caller's $exit is [stats..., code]
    # and "if ($exit -ne 0)" is truthy even on success. Return only the exit code.
    & rsync @rsyncArgs | Out-Host
    return $LASTEXITCODE
}
