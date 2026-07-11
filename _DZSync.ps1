# Shared helpers for Push-DayZServer.ps1 / Pull-DayZServer.ps1 — dot-source, not a run target.
# ONE place for the exclude categories so push and pull can't drift (see postmortem #1:
# two copies of the same rule is how the update.sh shebang bug hid for so long).

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

# Fail early if the host fields were blanked out.
function Assert-DZHost {
    param([hashtable]$Fields)   # name -> value
    foreach ($k in $Fields.Keys) {
        if (-not $Fields[$k]) {
            Write-Error "Set -$k — host info not configured. Edit the param defaults or pass it on the command line."
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
