#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pull the box's ENTIRE config state into the repo mirrors, in one command — the backup
    direction of the pull-only config model.
.DESCRIPTION
    The box owns all game-config content (the web editor writes it; prestart rebuilds live
    files from frozen defaults + overrides). The repo keeps committed MIRRORS so a dead box
    is one `Deploy-DayZServer.ps1 -Fix` away from its config state (docs/RECOVERY.md).
    This runs every mirror pull in sequence:

      Sync-ConfigOverrides.ps1   config-overrides.json        (the overrides document)
      Sync-SpawnPoints.ps1       deploy/profiles/AI_Bandits/spawn-points.json
      Sync-ConfigDefaults.ps1    config-defaults/**           (frozen <stem>.defaults<ext> baselines)

    Together these reconstruct every managed config: live file = frozen default + override
    patches; spawn points are their own store. Files the box never rewrites (seeds that were
    never patched) are still identical to their repo copies by definition.

    Read-only by default (each sync reports what it would pull). -Execute writes the
    mirrors (each sync snapshots into backups/ first, keep 10). Run it after web-editing
    sessions worth keeping, then COMMIT the mirrors — git history is the long-term backup.

    Exits non-zero if any sync fails or blocks (e.g. the box-ownership guard on hand-edited
    mirrors — see Sync-ConfigOverrides.ps1).
.EXAMPLE
    ./Pull-Configs.ps1              # dry-run: what each mirror pull would change
.EXAMPLE
    ./Pull-Configs.ps1 -Execute     # pull all mirrors, then commit them
#>
[CmdletBinding()]
param(
    [string]$RemoteHost,
    [string]$RemoteUser = "ubuntu",
    [switch]$Execute,
    [switch]$NoLog
)

$syncs = @(
    "Sync-ConfigOverrides.ps1"
    "Sync-SpawnPoints.ps1"
    "Sync-ConfigDefaults.ps1"
)

$failed = @()
foreach ($name in $syncs) {
    $script = Join-Path $PSScriptRoot $name
    if (-not (Test-Path $script)) { Write-Warning "$name not found - skipped."; $failed += $name; continue }
    Write-Host "--- $name ---" -ForegroundColor Cyan
    $syncArgs = @{ RemoteUser = $RemoteUser; NoLog = $NoLog; Execute = $Execute }
    if ($RemoteHost) { $syncArgs.RemoteHost = $RemoteHost }
    & $script @syncArgs
    if ($LASTEXITCODE) {
        Write-Warning "$name exited $LASTEXITCODE - see above."
        $failed += $name
    }
    Write-Host ""
}

if ($failed.Count) {
    Write-Error "Pull-Configs: $($failed.Count) sync(s) failed or blocked: $($failed -join ', ')"
    exit 1
}

# Commit the pulled state so git history IS the backup ("commit the history on sync" —
# user directive 2026-07-16; Deploy-DayZServer.ps1 -Fix does the same). Pathspec-limited:
# only the mirrors this script pulls are committed, never unrelated working-tree changes.
if ($Execute) {
    $mirrorPaths = @('config-overrides.json', 'deploy/profiles/AI_Bandits/spawn-points.json', 'config-defaults')
    git -C $PSScriptRoot add -- $mirrorPaths 2>$null
    if (git -C $PSScriptRoot status --porcelain -- $mirrorPaths) {
        git -C $PSScriptRoot commit -q -m "config backup: box state $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -- $mirrorPaths
        Write-Host "Pull-Configs: all syncs OK - config backup committed (git log -- config-overrides.json for history)" -ForegroundColor Green
    } else {
        Write-Host "Pull-Configs: all syncs OK - no config changes since last commit" -ForegroundColor Green
    }
} else {
    Write-Host "Pull-Configs: all syncs OK. dry-run only - re-run with -Execute to write + commit the mirrors" -ForegroundColor Green
}
exit 0
