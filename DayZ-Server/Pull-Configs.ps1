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
      Sync-SpawnPoints.ps1       deploy/profiles/AI_Shared/map-points.json
      Sync-ConfigDefaults.ps1    config-defaults/**           (frozen <stem>.defaults<ext> baselines)
      (inline)                   config-mirror/**             (LIVE files of registry folder rows
                                                               tagged "mirror":"live" - mission
                                                               expansion/settings and anything else
                                                               so tagged. Registry-driven: adding a
                                                               mirrored surface is one line there.)
      (inline)                   registry FILE rows tagged "mirror":"live" - pulled back INTO
                                 their own 'seed' path (seed = latest mirror, the map-points
                                 model; e.g. the web-edited expansion_types_tuning pair).

    Together these reconstruct every managed config: live file = frozen default + override
    patches; spawn points are their own store. Files the box never rewrites (seeds that were
    never patched) are still identical to their repo copies by definition.

    Read-only by default (each sync reports what it would pull). -Execute writes the
    mirrors (each sync snapshots into backups/ first; retention is per-sync - overrides 30,
    map-points 20, loadouts 10). Run it after web-editing
    sessions worth keeping, then COMMIT the mirrors — git history is the long-term backup.

    PROD-ONLY BY DESIGN: the mirrors are the committed history of what runs on PROD, so
    every sync here resolves deployer.prod.env (staging is never pulled back — see
    ../STAGING-PLAN.md deviation table). There is deliberately no -Env switch on the
    pull family.

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
    [string]$RemotePath = "/home/ubuntu/servers/dayz-server",   # absolute: '~' does not expand inside the quoted ssh command
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

# --- LIVE folder mirror (config-mirror/) --------------------------------------------------
# Box-born config that no seed and no other pull covers. Driven ENTIRELY by config-registry.json:
# any FOLDER row tagged "mirror":"live" has its subfolders pulled here, so adding a mirrored
# surface is a registry line, not a new script. Deliberately inline rather than a sixth Sync-*.
#
# Why this exists: mission expansion/settings files (AIPatrolSettings, AILocationSettings, ...) are
# written by the mod on a mission's first boot and hand-edited thereafter. No registry row seeded
# them and no pull captured them, so they lived ONLY on prod - a fresh box and every staging VM
# had none of it, and enoch silently lost 17 patrols for five days with no diff to notice it.
. (Join-Path $PSScriptRoot "_DZSync.ps1")
. (Join-Path $PSScriptRoot "../../../common/Utils.ps1")   # Get-Stdout - strips ErrorRecords from 2>&1
Resolve-DZDeployerEnv -ScriptRoot $PSScriptRoot -RemoteHost ([ref]$RemoteHost) -RemoteUser ([ref]$RemoteUser) -BoundParameters $PSBoundParameters
$target    = "${RemoteUser}@${RemoteHost}"
$mirrorDir = Join-Path $PSScriptRoot "config-mirror"
$registry  = Get-Content -Raw (Join-Path $PSScriptRoot "config-registry.json") | ConvertFrom-Json
$liveRows  = @($registry.surfaces | Where-Object { $_.mirror -eq 'live' -and $_.dir })
# Compiled 'generated' globs ('*' spans '/', matching the UI and dayz-ctl) - never mirrored.
$genRe = @(@($registry.generated) | ForEach-Object {
    '^' + ([regex]::Escape("$_") -replace '\\\*', '.*') + '$'
})

Write-Host "--- Live folder mirror (config-mirror/) ---" -ForegroundColor Cyan
$pulled = 0; $same = 0; $bad = 0
foreach ($row in $liveRows) {
    foreach ($sub in @($row.subfolders)) {
        $glob   = if ($row.mirrorGlob) { [string]$row.mirrorGlob } else { '*.json' }
        $relDir = "$($row.dir)/$sub"
        # List first, then fetch one by one - a file must PARSE before it may enter the repo, so a
        # half-written box file can never overwrite a good committed copy.
        $find = "cd '$RemotePath/$relDir' 2>/dev/null && ls -1 $glob 2>/dev/null"
        # NEVER pull a *.defaults.* here - those are config-defaults/'s files (Sync-ConfigDefaults
        # owns them). One file, one mirror: two mirrors of the same path is the drift this replaces.
        # NEVER pull a registry-'generated' file either: it is rebuilt from its sources every boot,
        # so mirroring it would churn git history on every restart and back up an artifact whose
        # inputs are already backed up. The registry is the single authority for that list.
        $names = @((Get-Stdout { ssh -o ConnectTimeout=10 $target $find } | Out-String) -split "`n" |
                   ForEach-Object { $_.Trim() } |
                   Where-Object { $_ -and $_ -notmatch '/|\.\.' -and $_ -notmatch '\.defaults\.' } |
                   Where-Object { $n = $_; -not ($genRe | Where-Object { $n -match $_ -or "$relDir/$n" -match $_ }) })
        foreach ($n in $names) {
            $text = Get-Stdout { ssh -o ConnectTimeout=10 $target "cat '$RemotePath/$relDir/$n'" } | Out-String
            try { $null = $text | ConvertFrom-Json } catch { Write-Warning "  SKIP $relDir/$n - does not parse as JSON on the box"; $bad++; continue }
            $dst = Join-Path $mirrorDir "$relDir/$n"
            $old = if (Test-Path $dst) { Get-Content -Raw -LiteralPath $dst } else { $null }
            if ($old -eq $text) { $same++; continue }
            $pulled++
            Write-Host ("  {0,-8} {1}" -f $(if ($old) { 'CHANGED' } else { 'NEW' }), "$relDir/$n")
            if ($Execute) {
                New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
                Set-Content -LiteralPath $dst -Value $text -NoNewline -Encoding utf8
            }
        }
    }
}
Write-Host ("  {0} to pull, {1} in sync, {2} rejected{3}" -f $pulled, $same, $bad, $(if (-not $Execute) { ' (dry-run)' } else { '' }))
if ($bad) { Write-Warning "config-mirror: $bad file(s) rejected - the repo copy is unchanged for those." }
Write-Host ""

# --- LIVE file mirror (seed = latest mirror) ----------------------------------------------
# FILE rows tagged "mirror":"live" (2026-07-23: the web-edited expansion_types_tuning pair) are
# pulled back INTO their registry 'seed' path - the map-points model. NOT into config-mirror/:
# the seed path already holds a copy of this exact file, and "one file, one mirror" (above)
# forbids a second. The box copy must pass the row's 'check' parse before it may enter the repo,
# so a half-written box file can never overwrite a good committed copy.
$liveFileRows  = @($registry.surfaces | Where-Object { $_.mirror -eq 'live' -and $_.box })
$liveFilePaths = @()
Write-Host "--- Live file mirror (registry file rows -> their seed path) ---" -ForegroundColor Cyan
$fPulled = 0; $fSame = 0; $fBad = 0
foreach ($row in $liveFileRows) {
    if (-not $row.seed) { Write-Warning "  SKIP $($row.name) - mirror:'live' file row has no seed path (nowhere to pull to)."; $fBad++; continue }
    $text = Get-Stdout { ssh -o ConnectTimeout=10 $target "cat '$RemotePath/$($row.box)'" } | Out-String
    if (-not $text.Trim()) { Write-Warning "  SKIP $($row.name) - box copy missing/empty ($($row.box))."; $fBad++; continue }
    $ok = switch ([string]$row.check) {
        'json'  { try { $null = $text | ConvertFrom-Json; $true } catch { $false } }
        'xml'   { try { $null = [xml]$text;               $true } catch { $false } }
        default { $false }   # a mirrored file row must declare a parse check - refuse unvalidated pulls
    }
    if (-not $ok) { Write-Warning "  SKIP $($row.name) - box copy does not parse as $($row.check)."; $fBad++; continue }
    $dst = Join-Path $PSScriptRoot $row.seed
    $liveFilePaths += $row.seed
    $old = if (Test-Path $dst) { Get-Content -Raw -LiteralPath $dst } else { $null }
    if ($old -eq $text) { $fSame++; continue }
    $fPulled++
    Write-Host ("  {0,-8} {1}" -f $(if ($null -ne $old) { 'CHANGED' } else { 'NEW' }), $row.seed)
    if ($Execute) {
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Set-Content -LiteralPath $dst -Value $text -NoNewline -Encoding utf8
    }
}
Write-Host ("  {0} to pull, {1} in sync, {2} rejected{3}" -f $fPulled, $fSame, $fBad, $(if (-not $Execute) { ' (dry-run)' } else { '' }))
if ($fBad) { Write-Warning "live file mirror: $fBad file(s) rejected/skipped - the repo copy is unchanged for those." }
Write-Host ""

# Commit the pulled state so git history IS the backup ("commit the history on sync" —
# user directive 2026-07-16; Deploy-DayZServer.ps1 -Fix does the same). Pathspec-limited:
# only the mirrors this script pulls are committed, never unrelated working-tree changes.
if ($Execute) {
    $mirrorPaths = @('config-overrides.json', 'deploy/profiles/AI_Shared/map-points.json', 'config-defaults', 'config-mirror') + $liveFilePaths
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
