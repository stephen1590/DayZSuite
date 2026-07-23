#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Validates (default) or deploys (-Fix) the DayZ server setup from ./deploy onto this machine.
.DESCRIPTION
    Read-only by default: reports drift between the ./deploy payload and the live
    locations (server dir + systemd units). -Fix copies the payload into place (sudo
    for units), reloads systemd, and restarts the service unless -NoRestart.

    OWNERSHIP RULE (pull-only config model, 2026-07-16): the deploy ships CODE and
    overwrites it on drift; it never overwrites CONFIG CONTENT. Config-content items
    ($items entries flagged Seed, plus the config-defaults/ mirror) are copied only to a
    box that doesn't have them — fresh box or disaster recovery — and reported BoxOwned
    otherwise. Config changes are made in the web editor (ConfigViewer), which writes the
    box directly; the deploy's sync steps pull those box copies back into the repo as
    committed mirrors/backups. See docs/CONFIGURATION.md + docs/RECOVERY.md.

    Host portability: the systemd units in the payload are TEMPLATES with
    {{DEPLOY_USER}}/{{DEPLOY_GROUP}}/{{DEPLOY_HOME}} placeholders; per-host values
    come from `host.env` (or the -Deploy* params), and the units are RENDERED before
    comparing and deploying — the SAME payload is drift-clean on any host. host.env
    is per-host, never in the payload, and lives ON THE BOX at
    <server dir>/host.env (moved there 2026-07-16 when the persistent ~/dayz-tooling
    checkout was retired); absent => built-in defaults (ubuntu, the VPS). A fresh box
    gets it seeded from host.env.example — then fill in the secrets there.

    Two separate local, gitignored files: host.env describes the SERVER (lives there,
    rendered into what runs there). deployer.env describes where to REACH the server
    (dev-machine-local; only read when NOT -Local; never rsynced over). Never conflate
    the two — see deployer.env.example.

    SINGLE SOURCE OF TRUTH (2026-07-16): the box's ~/servers/dayz-server is the ONLY
    home of live config; this repo is CODE + committed config HISTORY. Deploy stages
    the runtime payload into a transient $RemoteDir (deploy-stage/ INSIDE the server
    dir, wiped each run) — the box never carries a second copy of the repo, and there
    is exactly one DayZ location on the box.

    Full output goes to a timestamped transcript in ./logs plus a CSV summary; -NoLog disables both.
.EXAMPLE
    ./Deploy-DayZServer.ps1                   # drift report on STAGING (default env = staging)
    ./Deploy-DayZServer.ps1 -Fix              # apply on STAGING (mirror pulls + auto-commit skipped there)
    ./Deploy-DayZServer.ps1 -Env prod -Fix    # THE prod deploy: requires clean main; pulls mirrors + commits
    ./Deploy-DayZServer.ps1 -Local            # on-box apply (used by the ssh leg on the box itself)
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$NoRestart,
    [switch]$NoLog,
    [switch]$Force,                                         # deploy even with players online / unverifiable count
    [switch]$SkipConfigTest,                                # bypass the offline pre-deploy config gate (emergency only)
    [switch]$Local,                                         # apply to THIS machine (the ssh leg uses this on the VPS)
    [ValidateSet('staging','prod')]
    [string]$Env = 'staging',                               # which box: staging is the DEFAULT, prod must be explicit (STAGING-PLAN.md). Picks deployer.<env>.env; ignored under -Local
    [string]$RemoteHost,                                    # dev-machine-local — see deployer.env below, or -RemoteHost
    [string]$RemoteUser   = "ubuntu",                       # override via deployer.env's DEPLOY_REMOTE_USER if it differs
    [string]$RemoteDir    = "servers/dayz-server/deploy-stage",  # transient payload staging INSIDE the server dir (home-relative for ssh/rsync) — wiped and re-shipped every deploy, so the box has exactly ONE DayZ location and this subfolder is just the delivery truck: templates land here, get rendered with host.env's secrets, pass the player guard, then are PLACED into the server dir / systemd. Never a second copy of the repo (~/dayz-tooling retired 2026-07-16).
    [string]$HostEnv     = (Join-Path $PSScriptRoot "host.env"),
    [string]$DeployerEnv = '',                              # default: deployer.<Env>.env (legacy deployer.env accepted for prod only)
    [string]$DeployUser,
    [string]$DeployGroup,
    [string]$DeployHome,
    [string]$ServerDir,
    [string]$UnitPath   = "/etc/systemd/system/dayz-server.service"
)

# deployer.<env>.env is dev-machine-local config (which box to reach) — the opposite of
# host.env (which describes the server itself) and never rsynced there (see the --exclude
# below). One file per environment (deployer.staging.env / deployer.prod.env) so the -Env
# selector, not an edit, picks the target; bare deployer.env is accepted for PROD only as
# the legacy name. Read early, only filling params not given explicitly on the command line.
if (-not $DeployerEnv) {
    $DeployerEnv = Join-Path $PSScriptRoot "deployer.$Env.env"
    if (-not (Test-Path $DeployerEnv) -and $Env -eq 'prod') {
        $legacy = Join-Path $PSScriptRoot "deployer.env"
        if (Test-Path $legacy) { $DeployerEnv = $legacy; Write-Host "using legacy deployer.env for prod - rename it deployer.prod.env" }
    }
}
if ((-not $PSBoundParameters.ContainsKey('RemoteHost') -or -not $PSBoundParameters.ContainsKey('RemoteUser')) -and (Test-Path $DeployerEnv)) {
    foreach ($line in Get-Content $DeployerEnv) {
        if (-not $PSBoundParameters.ContainsKey('RemoteHost') -and $line -match '^\s*DEPLOY_REMOTE_HOST\s*=\s*(.+?)\s*$') { $RemoteHost = $Matches[1] }
        if (-not $PSBoundParameters.ContainsKey('RemoteUser') -and $line -match '^\s*DEPLOY_REMOTE_USER\s*=\s*(.+?)\s*$') { $RemoteUser = $Matches[1] }
    }
}

# --- Remote is the DEFAULT: there is no local server install anymore (meshroom is
# tooling-only since 2026-07-06); the VPS is the one deployment. A bare run rsyncs
# this tooling folder + common/ to the target and runs the apply step THERE over ssh
# (-t so sudo can prompt). The ssh leg re-invokes this script with -Local on the VPS.
# Remote's own logs/ and host.env are excluded from --delete, so they survive; the
# first run seeds host.env from the example.
if (-not $Local) {
    if (-not $RemoteHost) {
        Write-Error "DEPLOY_REMOTE_HOST is not set for env '$Env'. Copy deployer.env.example to deployer.$Env.env (dev-machine-local, gitignored — never host.env, that's server config) and set it, or pass -RemoteHost explicitly. -Local skips this if you're running directly on the server."
        exit 2
    }
    $RemoteTarget = "${RemoteUser}@${RemoteHost}"
    $sshOpt = "ssh -o ConnectTimeout=10"
    Write-Host "=== env: $Env -> $RemoteTarget ===`n" -ForegroundColor Cyan

    # PROD DEPLOY GUARD (STAGING-PLAN.md phase 1): prod only ever runs a REVIEWED commit —
    # a -Fix to prod refuses a dirty tree or a non-main branch. Staging deploys the working
    # tree freely (that's what it's for). Checked before anything touches the network.
    if ($Env -eq 'prod' -and $Fix) {
        $branch = git -C $PSScriptRoot symbolic-ref --short HEAD 2>$null
        $dirty  = git -C $PSScriptRoot status --porcelain
        if ($branch -ne 'main') { Write-Error "prod deploy refused: branch is '$branch', not main. Merge to main first, or rehearse on staging (bare run = -Env staging)."; exit 5 }
        if ($dirty)             { Write-Error "prod deploy refused: working tree is dirty. Commit or stash first - prod runs reviewed commits only. Uncommitted:`n$($dirty -join "`n")"; exit 5 }
    }

    # MIRROR PULLS + AUTO-COMMIT ARE PROD-ONLY (STAGING-PLAN.md deviation table): the repo
    # mirror is the committed history of what runs on PROD. Pulling a staging box here would
    # auto-commit staging config into that history — so under any other env the three pulls
    # and the backup commit below are skipped entirely; staging is never pulled back.
    if ($Env -ne 'prod') {
        Write-Host "--- mirror pulls skipped (prod-only; env=$Env) ---`n"
    }

    # Spawn points: the live box is authoritative for AI-bandit spawn locations (the web Map
    # editor writes map-points.json at runtime via the API). Pull it DOWN into the repo
    # mirror — committed backup + fresh-box seed; the deploy below only ever SEEDS it to a
    # box that has none. Report-only unless -Fix; the sync validates JSON and snapshots the
    # mirror before overwriting.
    $spawnSync = Join-Path $PSScriptRoot "Sync-SpawnPoints.ps1"
    if ($Env -eq 'prod' -and (Test-Path $spawnSync)) {
        Write-Host "--- spawn points (pull-before-push: box authoritative) ---"
        if ($Fix) { & $spawnSync -RemoteHost $RemoteHost -RemoteUser $RemoteUser -NoLog:$NoLog -Execute }
        else      { & $spawnSync -RemoteHost $RemoteHost -RemoteUser $RemoteUser -NoLog:$NoLog }
        Write-Host ""
    }

    # Config overrides: the live box is authoritative (the web editor writes the document at
    # runtime). Pull the box's config-overrides.json DOWN into the repo MIRROR — the committed
    # backup, and the seed a fresh box gets. Read-only unless -Fix; the sync validates JSON and
    # snapshots the mirror before overwriting. The deploy below only ever SEEDS this file to a
    # box that doesn't have one — it never overwrites a live document.
    $ovrSync = Join-Path $PSScriptRoot "Sync-ConfigOverrides.ps1"
    if ($Env -eq 'prod' -and (Test-Path $ovrSync)) {
        Write-Host "--- config overrides (pull: box authoritative, repo = mirror/seed) ---"
        if ($Fix) { & $ovrSync -RemoteHost $RemoteHost -RemoteUser $RemoteUser -NoLog:$NoLog -Execute }
        else      { & $ovrSync -RemoteHost $RemoteHost -RemoteUser $RemoteUser -NoLog:$NoLog }
        # The sync exits non-zero when it REFUSES to run: hand edits on the box-owned mirror
        # (exit 3). Proceeding would ship a mirror that silently loses either the hand edits or
        # the box's state — stop the whole deploy and surface its message instead.
        if ($LASTEXITCODE) { Write-Error "config-overrides sync blocked the deploy (exit $LASTEXITCODE) — see above."; exit $LASTEXITCODE }
        Write-Host ""
    }

    # Frozen defaults: the box-born baselines behind the reversible overrides (config-defaults/).
    # Same pull: the mirror follows the box (new captures and re-captures come down); the -Local
    # step below only ever seeds a baseline the box LACKS back from the mirror.
    $defSync = Join-Path $PSScriptRoot "Sync-ConfigDefaults.ps1"
    if ($Env -eq 'prod' -and (Test-Path $defSync)) {
        Write-Host "--- config defaults (pull: box authoritative, repo = mirror/seed) ---"
        if ($Fix) { & $defSync -RemoteHost $RemoteHost -RemoteUser $RemoteUser -NoLog:$NoLog -Execute }
        else      { & $defSync -RemoteHost $RemoteHost -RemoteUser $RemoteUser -NoLog:$NoLog }
        Write-Host ""
    }

    # Pre-deploy config GATE: build the real artifacts OFFLINE from the just-pulled mirrors and
    # refuse to ship if an override is dead or a composed artifact is malformed. This is what
    # makes the process repeatable/reliable — the identical engines run on the identical inputs
    # here first, so a green gate means the box build is already known-good. Runs dev-side before
    # anything ships. Under -Fix a failure ABORTS (never ship un-buildable config); a bare dry-run
    # just reports it. -SkipConfigTest bypasses (emergencies only). See Test-Configs.ps1.
    if (-not $SkipConfigTest) {
        $preflight = Join-Path $PSScriptRoot "Test-Configs.ps1"
        if (Test-Path $preflight) {
            Write-Host "--- pre-deploy config gate (Test-Configs.ps1: offline build + validate) ---"
            & $preflight -NoLog:$NoLog
            $gate = $LASTEXITCODE
            if ($gate -and $Fix) { Write-Error "pre-deploy config gate FAILED (exit $gate) — NOT shipping. Fix the config, or pass -SkipConfigTest to override."; exit $gate }
            elseif ($gate)       { Write-Warning "pre-deploy config gate failed (exit $gate) — a -Fix would be blocked here. Dry-run continues." }
            Write-Host ""
        }
    }

    # Committed config history: each PROD -Fix deploy commits the just-pulled box config
    # state, so `git log -- config-overrides.json` is the browsable history of what actually
    # ran on the box ("backup the configs to the repo; commit the history on sync" — user
    # directive 2026-07-16). Pathspec-limited on purpose: only the pulled mirrors are ever
    # committed here, never unrelated working-tree changes. Prod-only, same reason as the
    # pulls above: staging state must never enter the prod mirror history.
    if ($Fix -and $Env -eq 'prod') {
        $mirrorPaths = @('config-overrides.json', 'deploy/profiles/AI_Shared/map-points.json', 'config-defaults', 'config-mirror')
        git -C $PSScriptRoot add -- $mirrorPaths 2>$null
        if (git -C $PSScriptRoot status --porcelain -- $mirrorPaths) {
            git -C $PSScriptRoot commit -q -m "config backup: box state $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -- $mirrorPaths
            Write-Host "config backup committed (git log -- config-overrides.json for history)`n"
        } else {
            Write-Host "config backup: no changes since last commit`n"
        }
    }

    # PULL-ONLY CONFIG MODEL (2026-07-16): the dev box does not push config content, full
    # stop (MAINTENANCE-PLAN.md addendum 2026-07-16b). Config-content items in $items below
    # are flagged Seed=$true: copied only when MISSING on the box (fresh box / disaster
    # recovery), never overwriting a live copy. New config fields are created box-side by
    # the overrides engine (force-create) via the web editor — nothing config-shaped ships
    # from here to an existing box.

    # The server-only PBOs ship as artifacts — fail fast HERE (with the build command)
    # rather than confusing the remote leg with a path that never left this machine.
    foreach ($pbo in 'serverMods/CustomServerMods/.hemttout/build/addons/CustomServerMods_main.pbo',
                     'serverMods/TransferSpawn/.hemttout/build/addons/TransferSpawn_main.pbo') {
        if (-not (Test-Path (Join-Path $PSScriptRoot $pbo))) {
            Write-Error "server-only PBO not built: $pbo`nBuild it first:  cd '$(Split-Path (Split-Path (Split-Path (Join-Path $PSScriptRoot $pbo))))'; hemtt build"
            exit 4
        }
    }

    # PAYLOAD-ONLY STAGING (2026-07-16, replaces the whole-repo ~/dayz-tooling mirror): ship
    # exactly what the -Local leg needs — the runtime payload, its seeds, and this script —
    # into a transient staging dir that is WIPED first (no stale files, no drift, no second
    # source of truth on the box). Dev-only tooling (Sync-*, Test-*, docs/, serverMods
    # source, test/) never leaves this repo. host.env is NOT staged: it lives on the box in
    # the server dir and survives every wipe.
    Write-Host "Deploying to ${RemoteTarget}:${RemoteDir} (payload-only staging, Fix=$Fix)`n"
    $payload = [System.Collections.Generic.List[string]]::new()
    # EVERY root-level file an $items row reaches with a '../' Src must be listed here, or it
    # never reaches deploy-stage and the copy fails ON THE BOX, mid-deploy (the Test-Path below
    # skips a missing entry silently). Test-Configs cross-checks the two lists so that mismatch
    # fails the gate on the dev machine instead. Cost one broken prod deploy, 2026-07-22.
    foreach ($f in 'Deploy-DayZServer.ps1', 'Apply-ConfigOverrides.ps1', 'Apply-CustomCE.ps1',
                   'Apply-ServerCfg.ps1',
                   'Build-AIBandits.ps1', 'Build-AILocations.ps1', 'Build-AIPatrols.ps1', 'config-registry.json', 'host.env.example',
                   'config-overrides.json',
                   'serverMods/CustomServerMods/.hemttout/build/addons/CustomServerMods_main.pbo',
                   'serverMods/TransferSpawn/.hemttout/build/addons/TransferSpawn_main.pbo') {
        if (Test-Path (Join-Path $PSScriptRoot $f)) { $payload.Add($f) }
    }
    # Directories shipped WHOLE to the box's deploy-stage. The seed steps later in this script run
    # ON THE BOX from that stage, so a mirror dir missing here silently seeds nothing - its
    # Test-Path just returns false against a path that only exists on the dev machine.
    foreach ($d in 'deploy', 'config-defaults', 'config-mirror') {
        $base = Join-Path $PSScriptRoot $d
        if (Test-Path $base) {
            Get-ChildItem $base -Recurse -File | ForEach-Object {
                $payload.Add($_.FullName.Substring($PSScriptRoot.Length + 1))
            }
        }
    }
    $listFile = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllLines($listFile, $payload)
    ssh -o ConnectTimeout=10 $RemoteTarget "rm -rf $RemoteDir && mkdir -p $RemoteDir"
    if ($LASTEXITCODE) { Write-Error "staging-dir reset failed (exit $LASTEXITCODE)"; exit 1 }
    & rsync -az -e $sshOpt --files-from=$listFile "$PSScriptRoot/" "${RemoteTarget}:${RemoteDir}/"
    $rsyncExit = $LASTEXITCODE
    Remove-Item $listFile -Force
    if ($rsyncExit) { Write-Error "payload rsync failed (exit $rsyncExit)"; exit 1 }
    $commonSrc = (Resolve-Path (Join-Path $PSScriptRoot "../../../common")).Path
    & rsync -az --delete -e $sshOpt "$commonSrc" "${RemoteTarget}:${RemoteDir}/"
    if ($LASTEXITCODE) { Write-Error "common/ rsync failed (exit $LASTEXITCODE)"; exit 1 }
    # host.env lives in the server dir on the box (survives the staging wipe; rescued out of
    # ~/dayz-tooling 2026-07-16). Fresh box: seed it from the example, then the -Local leg
    # hard-fails on the placeholder secrets with instructions — fill them in ON THE BOX.
    $flags = @('-Local'); if ($Fix) { $flags += '-Fix' }; if ($NoRestart) { $flags += '-NoRestart' }; if ($NoLog) { $flags += '-NoLog' }; if ($Force) { $flags += '-Force' }
    ssh -t -o ConnectTimeout=10 $RemoteTarget "mkdir -p ~/servers/dayz-server && { [ -f ~/servers/dayz-server/host.env ] || cp $RemoteDir/host.env.example ~/servers/dayz-server/host.env; } && cd $RemoteDir && pwsh -NoProfile ./Deploy-DayZServer.ps1 $($flags -join ' ')"
    exit $LASTEXITCODE
}

# Find common/Utils.ps1 without assuming the dev-machine layout: dev box has it at
# ../../../common (Dev/common, three up from DayZ-Server inside GameServices); a flat
# copy on another host can put it at ./common or ../common.
$utils = "../../../common/Utils.ps1", "../common/Utils.ps1", "./common/Utils.ps1" |
    ForEach-Object { Join-Path $PSScriptRoot $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $utils) { throw "common/Utils.ps1 not found near $PSScriptRoot (tried ../../../common, ../common, ./common)" }
. $utils

# --- Per-host values: built-in defaults (the VPS) <- host.env <- explicit -Deploy* params ---
# DEPLOY_SERVER_PASSWORD/DEPLOY_ADMIN_PASSWORD/DEPLOY_STEAM_ACCOUNT have NO built-in default
# (unlike user/group/home) — they identify a real account/secret and must never be baked into
# this tracked script. serverDZ.cfg/update.sh carry them only as {{...}} placeholders; see the
# hard-fail check below.
$hv = [ordered]@{ DEPLOY_USER = 'ubuntu'; DEPLOY_GROUP = 'ubuntu'; DEPLOY_HOME = '/home/ubuntu'; DEPLOY_SERVER_PASSWORD = $null; DEPLOY_ADMIN_PASSWORD = $null; DEPLOY_STEAM_ACCOUNT = $null; DEPLOY_UPDATE_CHECK_INTERVAL = '4h' }
# host.env lives ON THE BOX in the server dir (moved out of the retired ~/dayz-tooling,
# 2026-07-16) — the staging dir beside this script is transient and never carries it.
# The script-dir path stays first so an explicit -HostEnv (or a legacy layout) still wins.
if (-not (Test-Path $HostEnv)) {
    $boxEnv = Join-Path $HOME 'servers/dayz-server/host.env'
    if (Test-Path $boxEnv) { $HostEnv = $boxEnv }
}
if (Test-Path $HostEnv) {
    foreach ($line in Get-Content $HostEnv) {
        if ($line -match '^\s*(DEPLOY_USER|DEPLOY_GROUP|DEPLOY_HOME|DEPLOY_SERVER_PASSWORD|DEPLOY_ADMIN_PASSWORD|DEPLOY_STEAM_ACCOUNT|DEPLOY_UPDATE_CHECK_INTERVAL)\s*=\s*(.+?)\s*$') { $hv[$Matches[1]] = $Matches[2] }
    }
}
if ($DeployUser)  { $hv.DEPLOY_USER  = $DeployUser }
if ($DeployGroup) { $hv.DEPLOY_GROUP = $DeployGroup }
if ($DeployHome)  { $hv.DEPLOY_HOME  = $DeployHome }
$DeployUser = $hv.DEPLOY_USER; $DeployGroup = $hv.DEPLOY_GROUP; $DeployHome = $hv.DEPLOY_HOME
$DeployServerPassword = $hv.DEPLOY_SERVER_PASSWORD
$DeployAdminPassword  = $hv.DEPLOY_ADMIN_PASSWORD
$DeploySteamAccount   = $hv.DEPLOY_STEAM_ACCOUNT
# Auto-update-check cadence. A systemd time span (e.g. '4h', '90min', '1d'); 'off' disables
# the whole auto-check (the timer is stopped/left disabled, the manual API arm still works).
$DeployUpdateCheckInterval = $hv.DEPLOY_UPDATE_CHECK_INTERVAL
$UpdateCheckEnabled = ($DeployUpdateCheckInterval -and $DeployUpdateCheckInterval -ne 'off')
if (-not $DeployAdminPassword){#-not $DeployServerPassword -or -not $DeployAdminPassword) {
    Write-Error "DEPLOY_SERVER_PASSWORD / DEPLOY_ADMIN_PASSWORD not set in $HostEnv. serverDZ.cfg's join/admin passwords are host-local secrets, never in the tracked payload. Copy host.env.example to host.env and fill both in, then re-run."
    exit 2
}
if (-not $DeploySteamAccount) {
    Write-Error "DEPLOY_STEAM_ACCOUNT not set in $HostEnv. update.sh needs the Steam account that owns DayZ (anonymous login fails), never baked into the tracked payload. Copy host.env.example to host.env and fill it in, then re-run."
    exit 2
}
if (-not $ServerDir) { $ServerDir = "$DeployHome/servers/dayz-server" }

$envState = if (Test-Path $HostEnv) { "from $(Split-Path -Leaf $HostEnv)" } else { "built-in defaults (no host.env)" }
Write-Host "Target host: user=$DeployUser group=$DeployGroup home=$DeployHome  [$envState]`n"

$deployDir = Join-Path $PSScriptRoot "deploy"
# Box-side deploy logs live with the server, NOT in the staging dir — staging is wiped on
# every deploy, and these transcripts are the record of what shipped when.
$logDir    = Join-Path $ServerDir ".deploy-logs"
$stamp     = Get-Date -Format "yyyyMMdd_HHmmss"
if (-not $NoLog) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Start-Transcript -Path (Join-Path $logDir "deploy_$stamp.log") | Out-Null
}

# --- Player guard: -Fix ends in a server restart, which drops everyone mid-session.
# Runs BEFORE any file is touched. Queries the live count over RCon (localhost); if
# players are online — or the server is up but the count can't be verified — refuse.
# -Force overrides; -NoRestart skips the guard (files-only never disturbs the process).
if (($Fix -and -not $NoRestart)) {
    $svcState = systemctl is-active dayz-server 2>$null
    if ($svcState -eq 'active') {
        $reply = pwsh -NoProfile -File (Join-Path $deployDir "dayz-rcon.ps1") $ServerDir "players" 2>&1 | Out-String
        if ($reply -match '\((\d+) players? in total\)') {
            $online = [int]$Matches[1]
            if ($online -gt 0 -and -not $Force) {
                Write-Error "$online player(s) online — refusing to deploy (deploy restarts the server). Wait, or use -NoRestart for files-only, or -Force to restart anyway."
                if (-not $NoLog) { Stop-Transcript | Out-Null }
                exit 3
            }
            Write-Host "Player check: $online online$(if ($online -and $Force) { ' — -Force given, deploying anyway' })."
        } elseif (-not $Force) {
            Write-Error "Server is up but player count could not be verified over RCon (is RCon enabled in battleye/beserver_x64.cfg?). Refusing to restart blind — -NoRestart for files-only, -Force to override."
            if (-not $NoLog) { Stop-Transcript | Out-Null }
            exit 3
        } else {
            Write-Warning "player count unverifiable — -Force given, proceeding."
        }
    } else {
        Write-Host "Player check: dayz-server not active — no players possible."
    }
}

# Mod registry: deploy/mods.conf is the ONE place the mod set + load order is defined.
# Enabled lines (in file order) render the unit's {{DEPLOY_MODLINE}}, drive update.sh's
# downloads, and feed the missing-mod check below — toggle a mod there, -Fix, done.
$modsConfPath = Join-Path $deployDir "mods.conf"
$enabledMods = @(Get-Content $modsConfPath | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') } |
    ForEach-Object { ($_ -split '\s+')[0] })
$ModLine = $enabledMods -join ';'
Write-Host "Mod chain (deploy/mods.conf, $($enabledMods.Count) enabled): $ModLine`n"

# Server-only mod (-serverMod=@custom_server_mods): OUR CustomServerMods PBO (ex-AIB_Tracker;
# AI position export + fresh-spawn buff). It is NOT a workshop item, so it's NOT in mods.conf
# and never touches update.sh — it's an artifact HEMTT packs from serverMods/CustomServerMods
# (the build output IS the addons folder). Build and deploy stay separate explicit steps,
# like the rest of Code->Document->Deploy: the PBO must already be built here. If it's
# missing we STOP with the build command rather than silently packing mid-deploy. The PBO
# ships as a normal $items entry below into @custom_server_mods/addons on the box.
# serverMods/ is a sibling of deploy/ (the tooling root, $PSScriptRoot) — NOT under deploy/.
$trackerSrcDir = Join-Path $PSScriptRoot "serverMods/CustomServerMods"
$trackerPbo    = Join-Path $trackerSrcDir ".hemttout/build/addons/CustomServerMods_main.pbo"
if (-not (Test-Path $trackerPbo)) {
    Write-Error "Server-only tracker PBO not built: $trackerPbo`nBuild it first:  cd '$trackerSrcDir'; hemtt build"
    if (-not $NoLog) { Stop-Transcript | Out-Null }
    exit 4
}
# Stale check: any source file newer than the packed PBO means a rebuild is due. Non-fatal —
# ships what's built so a deploy is never blocked by a forgotten repack, but you're told.
$trackerNewest = Get-ChildItem (Join-Path $trackerSrcDir "addons") -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
if ($trackerNewest -and $trackerNewest.LastWriteTimeUtc -gt (Get-Item $trackerPbo).LastWriteTimeUtc) {
    Write-Warning "CustomServerMods source ($($trackerNewest.Name)) is newer than its PBO — run 'hemtt build' in $trackerSrcDir to repack before deploying it."
}

# Second server-only mod (-serverMod=…;@transfer_spawn): OUR TransferSpawn PBO — relocates
# migrated characters to the new map's own spawn points on a map switch. Same rules as the
# tracker: HEMTT artifact, must be pre-built, guarded here, shipped as an $items entry below.
$tspawnSrcDir = Join-Path $PSScriptRoot "serverMods/TransferSpawn"
$tspawnPbo    = Join-Path $tspawnSrcDir ".hemttout/build/addons/TransferSpawn_main.pbo"
if (-not (Test-Path $tspawnPbo)) {
    Write-Error "Server-only TransferSpawn PBO not built: $tspawnPbo`nBuild it first:  cd '$tspawnSrcDir'; hemtt build"
    if (-not $NoLog) { Stop-Transcript | Out-Null }
    exit 4
}
$tspawnNewest = Get-ChildItem (Join-Path $tspawnSrcDir "addons") -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
if ($tspawnNewest -and $tspawnNewest.LastWriteTimeUtc -gt (Get-Item $tspawnPbo).LastWriteTimeUtc) {
    Write-Warning "TransferSpawn source ($($tspawnNewest.Name)) is newer than its PBO — run 'hemtt build' in $tspawnSrcDir to repack before deploying."
}

# Render=$true items are systemd unit TEMPLATES: their {{DEPLOY_*}} placeholders are
# substituted with this host's values before hashing and deploying.
$items = @(
    @{ Src = "update.sh";           Dst = Join-Path $ServerDir "update.sh";    Sudo = $false; Exec = $true; Render = $true }
    # Auto-update checker (arms a deferred update when a newer server build exists) — runs on
    # dayz-update-check.timer as the game user; needs the Steam account like update.sh.
    @{ Src = "update-check.sh";     Dst = Join-Path $ServerDir "update-check.sh"; Sudo = $false; Exec = $true; Render = $true }
    # The registry ships next to update.sh so on-box (manual) update runs read the same set.
    @{ Src = "mods.conf";           Dst = Join-Path $ServerDir "mods.conf";   Sudo = $false; Exec = $false }
    # Server-only CustomServerMods PBO -> @custom_server_mods/addons on the box (matches
    # -serverMod=@custom_server_mods in the unit). OUR artifact from HEMTT, guarded above;
    # drift-checked like any payload file. (The old @aib_tracker dir on the box is inert once
    # the unit renders the new name — remove it whenever convenient.)
    @{ Src = "../serverMods/CustomServerMods/.hemttout/build/addons/CustomServerMods_main.pbo"
       Dst = Join-Path $ServerDir "@custom_server_mods/addons/CustomServerMods_main.pbo"; Sudo = $false; Exec = $false }
    # Second server-only PBO -> @transfer_spawn/addons (matches -serverMod=…;@transfer_spawn).
    @{ Src = "../serverMods/TransferSpawn/.hemttout/build/addons/TransferSpawn_main.pbo"
       Dst = Join-Path $ServerDir "@transfer_spawn/addons/TransferSpawn_main.pbo"; Sudo = $false; Exec = $false }
    @{ Src = "prestart.sh";         Dst = Join-Path $ServerDir "prestart.sh";  Sudo = $false; Exec = $true  }
    # The ONE home of the default mission. The real map.env is runtime state, seeded from
    # this below only when missing; prestart.sh also self-heals a deleted map.env from it.
    @{ Src = "map.env.example";     Dst = Join-Path $ServerDir "map.env.example"; Sudo = $false; Exec = $false }
    # prestart.sh calls this to write profiles/transfer_spawn.json for the TransferSpawn PBO.
    @{ Src = "Build-TransferSpawns.ps1"; Dst = Join-Path $ServerDir "Build-TransferSpawns.ps1"; Sudo = $false; Exec = $false }
    # serverDZ.cfg is a prestart ARTIFACT now, not a deploy-rendered file: Apply-ServerCfg.ps1
    # builds it from this template + host.env (the two passwords) + the box-owned
    # server-settings.json, so the web-exposed toggles (hostname, maxPlayers, the day/night
    # cycle, ...) take effect on a restart instead of needing a repo edit and a redeploy.
    # The template ships UNRENDERED — the passwords stay {{...}} here and resolve on the box,
    # so no deploy-time temp file ever holds them.
    @{ Src = "serverDZ.cfg.template"; Dst = Join-Path $ServerDir "serverDZ.cfg.template"; Sudo = $false; Exec = $false }
    @{ Src = "profiles/VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt"
       Dst = Join-Path $ServerDir "profiles/VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt"
       Sudo = $false; Exec = $false }
    # VPP permission groups: full-file owned (we author it, nothing regenerates it) — NOT a
    # config-overrides patch. Steam64IDs + per-group permission lists, copied verbatim.
    @{ Src = "profiles/VPPAdminTools/Permissions/UserGroups/UserGroups.json"
       Dst = Join-Path $ServerDir "profiles/VPPAdminTools/Permissions/UserGroups/UserGroups.json"
       Sudo = $false; Exec = $false }
    # NOTE: box-owned CONFIG CONTENT (the AI_Bandits source tree, map-points.json, classification,
    # per-map StaticAIB, messages.xml, config-overrides.json, the Babaku per-map sources) is NO
    # LONGER listed here. It is declared once in config-registry.json and seeded-if-missing by the
    # "Config content" section below (single source; the API allowlist + pulls + validator read the
    # same file). $items now carries CODE only (ships on drift). Architecture recap that used to
    # live here: AI_Bandits DynamicAIB/StaticAIB are per-map raw coords composed at prestart from
    # common (shared templates, scope:shared) + maps/<mission> (per-map, scope:map:<mission>);
    # Sakhal's dynamic spawns come entirely from map-points.json; Chernarus is PARKED (map.env +
    # its registry/seed present but not the active mission — see maps/dayzOffline.chernarusplus/PARKED.md);
    # KnockKnock/AIB_UL/etc. are mod-generated, patched via config-overrides.json (not seeded).
    @{ Src = "dayz-rcon.ps1";       Dst = Join-Path $ServerDir "dayz-rcon.ps1"; Sudo = $false; Exec = $true  }
    # Shared log-archive engine — single source in common/ (rsynced to the box alongside the
    # tooling tree); copied into the server dir so dayz-logarchive.timer runs it there.
    @{ Src = "../common/Archive-Logs.ps1"; Dst = Join-Path $ServerDir "Archive-Logs.ps1"; Sudo = $false; Exec = $true }
    # Override engine lives in the SERVER dir so prestart.sh applies the overrides document on
    # every start (Src '..' = tooling root, the parent of deploy/). The engine is CODE (ships,
    # overwrites); the DOCUMENT is box-owned config content - the web editor writes it live,
    # the pull above mirrors it back, and it is only ever SEEDED to a box that has none
    # (fresh box / disaster recovery: the mirror carries every web edit back onto the box).
    @{ Src = "../Apply-ConfigOverrides.ps1"; Dst = Join-Path $ServerDir "Apply-ConfigOverrides.ps1"; Sudo = $false; Exec = $true }
    # (config-overrides.json itself is box-owned content — seeded from config-registry.json below,
    #  not shipped here; the engine above is code and ships on drift.)
    # AI bandit builder lives in the server dir so prestart composes the flat DynamicAIB/StaticAIB
    # from common + maps/<mission> on every start (see the AI_Bandits source tree above).
    @{ Src = "../Build-AIBandits.ps1";       Dst = Join-Path $ServerDir "Build-AIBandits.ps1";       Sudo = $false; Exec = $true }
    # serverDZ.cfg renderer (template + host.env secrets + server-settings.json). Lives in the
    # server dir because prestart rebuilds serverDZ.cfg on every start; the ENGINE is code, the
    # server-settings.json DOCUMENT is box-owned content seeded from config-registry.json.
    @{ Src = "../Apply-ServerCfg.ps1";       Dst = Join-Path $ServerDir "Apply-ServerCfg.ps1";       Sudo = $false; Exec = $true }
    # Expansion AI patrol builder (twin of Build-AIBandits): prestart composes AIPatrolSettings.json
    # from the frozen base + 'expansion'-toggled map-points on every start. Same map-points store,
    # independent on/off (profiles/ExpansionMod/AIPatrols.control.json). Lives in the server dir.
    @{ Src = "../Build-AIPatrols.ps1";       Dst = Join-Path $ServerDir "Build-AIPatrols.ps1";       Sudo = $false; Exec = $true }
    # Expansion AI location builder (twin of Build-AIPatrols): prestart composes AILocationSettings.json
    # (RoamingLocations) from the frozen base + 'expansion'-toggled map-points on every start. Same
    # map-points store, geography only (no factions/loadouts). Lives in the server dir.
    @{ Src = "../Build-AILocations.ps1";     Dst = Join-Path $ServerDir "Build-AILocations.ps1";     Sudo = $false; Exec = $true }
    # Custom CE types (modded loot like CodeLock + the AI Bandits mod's bandit_types.xml): the
    # manifest (custom-ce.json) lists every extra types file; our own live in custom-ce/, mod ones
    # are pulled from their doc folder at prestart. Apply-CustomCE copies them into the active
    # mission's custom/ folder and regenerates <ce folder="custom"> in its cfgeconomycore.xml
    # (never the vanilla types.xml). Add a modded types file = one line in custom-ce.json.
    @{ Src = "custom-ce/custom-ce.json";     Dst = Join-Path $ServerDir "custom-ce/custom-ce.json";   Sudo = $false; Exec = $false }
    @{ Src = "custom-ce/custom_types.xml";   Dst = Join-Path $ServerDir "custom-ce/custom_types.xml"; Sudo = $false; Exec = $false }
    # Expansion CE (from the DayZ-Expansion-Missions mission templates): none of our missions ever
    # registered these, so NO Expansion item spawned as world loot. The shared types file is the
    # Chernarus variant (usage-based, Tier1-4 - fits chernarusplus AND sakhal); Enoch defines no
    # Tier4, so its re-tiered template variant ships under maps/ and wins there (Apply-CustomCE's
    # per-map override). spawnabletypes is byte-identical across every template - truly shared.
    # expansion_events.xml is NOT shipped: map-specific AND inert without per-map cfgeventspawns
    # positions, which no mission has yet - separate task.
    @{ Src = "custom-ce/expansion_types.xml";          Dst = Join-Path $ServerDir "custom-ce/expansion_types.xml";          Sudo = $false; Exec = $false }
    @{ Src = "custom-ce/expansion_spawnabletypes.xml"; Dst = Join-Path $ServerDir "custom-ce/expansion_spawnabletypes.xml"; Sudo = $false; Exec = $false }
    @{ Src = "custom-ce/maps/dayzOffline.enoch/expansion_types.xml"; Dst = Join-Path $ServerDir "custom-ce/maps/dayzOffline.enoch/expansion_types.xml"; Sudo = $false; Exec = $false }
    # Our loot-balance tuning, registered AFTER expansion_types.xml so each <type> replaces the
    # upstream entry (min 25% of nominal, food nominal cut, restock 1800 on non-essentials). GENERATED
    # from the template above - regenerate after an Expansion update or the values go stale. It needs
    # the SAME per-map split as the file it patches: 33 of the tuned types differ between the Chernarus
    # and Enoch variants, so one shared file would restore Tier4 on Enoch and kill them there.
    @{ Src = "custom-ce/expansion_types_tuning.xml";   Dst = Join-Path $ServerDir "custom-ce/expansion_types_tuning.xml";   Sudo = $false; Exec = $false }
    @{ Src = "custom-ce/maps/dayzOffline.enoch/expansion_types_tuning.xml"; Dst = Join-Path $ServerDir "custom-ce/maps/dayzOffline.enoch/expansion_types_tuning.xml"; Sudo = $false; Exec = $false }
    @{ Src = "../Apply-CustomCE.ps1";        Dst = Join-Path $ServerDir "Apply-CustomCE.ps1";        Sudo = $false; Exec = $true }
    # Bubaku spawner composer lives in the server dir so prestart writes the fixed-path file from
    # the active map's source on every start (mirrors Build-TransferSpawns/Build-AIBandits). Engine
    # is CODE (ships on drift); the per-map SOURCES are box-owned content — seeded from
    # config-registry.json below.
    @{ Src = "Build-BabakuSpawns.ps1"; Dst = Join-Path $ServerDir "Build-BabakuSpawns.ps1"; Sudo = $false; Exec = $false }
    @{ Src = "dayz-server.service"; Dst = $UnitPath;                            Sudo = $true;  Exec = $false; Render = $true }
    @{ Src = "dayz-logarchive.service"; Dst = "/etc/systemd/system/dayz-logarchive.service"; Sudo = $true; Exec = $false; Render = $true }
    @{ Src = "dayz-logarchive.timer";   Dst = "/etc/systemd/system/dayz-logarchive.timer";   Sudo = $true; Exec = $false }
    # Auto-update-check unit + timer (timer interval rendered from host.env). The timer is
    # enabled/disabled by DEPLOY_UPDATE_CHECK_INTERVAL in the -Fix block below.
    @{ Src = "dayz-update-check.service"; Dst = "/etc/systemd/system/dayz-update-check.service"; Sudo = $true; Exec = $false; Render = $true }
    @{ Src = "dayz-update-check.timer";   Dst = "/etc/systemd/system/dayz-update-check.timer";   Sudo = $true; Exec = $false; Render = $true }
)

# PRE-FLIGHT: every payload source must exist BEFORE we copy anything. Without this the first
# missing file surfaces as a bare Copy-Item error partway through, leaving the box half-updated
# and the cause ("it was never rsynced into deploy-stage") invisible.
$absent = @($items | Where-Object { -not (Test-Path (Join-Path $deployDir $_.Src)) })
if ($absent) {
    $names = ($absent | ForEach-Object { $_.Src }) -join ', '
    Write-Error ("payload incomplete - these `$items sources are not in deploy-stage: $names`n" +
        "A '../' Src must ALSO be listed in the root-file payload list near the top of this script, " +
        "and a directory in the 'deploy', 'config-defaults', 'config-mirror' ship list. Nothing was copied.")
    if (-not $NoLog) { Stop-Transcript | Out-Null }
    exit 4
}

$results = @()
foreach ($i in $items) {
    $src = Join-Path $deployDir $i.Src
    $tmp = $null
    if ($i.Render) {
        $rendered = ([IO.File]::ReadAllText($src)).
            Replace('{{DEPLOY_HOME}}', $DeployHome).
            Replace('{{DEPLOY_USER}}', $DeployUser).
            Replace('{{DEPLOY_GROUP}}', $DeployGroup).
            Replace('{{DEPLOY_MODLINE}}', $ModLine).
            Replace('{{DEPLOY_SERVER_PASSWORD}}', $DeployServerPassword).
            Replace('{{DEPLOY_ADMIN_PASSWORD}}', $DeployAdminPassword).
            Replace('{{DEPLOY_STEAM_ACCOUNT}}', $DeploySteamAccount).
            Replace('{{DEPLOY_UPDATE_CHECK_INTERVAL}}', $DeployUpdateCheckInterval)
        $tmp = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($tmp, $rendered)
        $src = $tmp
    }
    $state = if (-not (Test-Path $i.Dst)) { "Missing" }
             else {
                 try {
                     if ((Get-FileHash $src).Hash -eq (Get-FileHash $i.Dst -ErrorAction Stop).Hash) { "InSync" } else { "Drift" }
                 } catch { "NoRead" }   # exists but unreadable (e.g. root 0600) — -Fix re-copies it with the payload's perms
             }
    $action = "none"
    if ($Fix -and $state -ne "InSync") {
        if ($i.Sudo) { sudo cp $src $i.Dst } else {
            New-Item -ItemType Directory -Force -Path (Split-Path $i.Dst) | Out-Null
            Copy-Item $src $i.Dst -Force
        }
        if ($i.Exec) { chmod +x $i.Dst }
        $action = "deployed"
    }
    if ($tmp) { Remove-Item $tmp -Force }
    Write-Host ("{0,-8} {1,-9} {2}" -f $state, $action, $i.Dst)
    $results += [PSCustomObject]@{
        Timestamp = Get-Date -Format "s"; File = $i.Src; State = $state; Action = $action
    }
}

# map.env is runtime state (which mission boots) — seeded ONLY when missing, like host.env.
# It must exist BEFORE the first service start: systemd loads the unit's EnvironmentFile
# ahead of ExecStartPre, so relying on prestart's self-heal alone costs one failed boot
# (and without the unit's "-" prefix it deadlocked a fresh box outright — staging gap #2).
$mapEnvPath = Join-Path $ServerDir "map.env"
if (-not (Test-Path $mapEnvPath)) {
    if ($Fix) {
        Copy-Item (Join-Path $ServerDir "map.env.example") $mapEnvPath
        Write-Host "Seeded map.env from map.env.example - edit DAYZ_MISSION on the box + restart to switch maps"
    } else {
        Write-Host "map.env  Missing  (-Fix will seed it from map.env.example)"
    }
}

# serverDZ.cfg is prestart-generated (Apply-ServerCfg). prestart runs before every start so it
# normally exists by the time the engine reads it - but prestart SKIPS the compiler when pwsh
# is absent, and a box with no serverDZ.cfg does not boot at all. Render it once here, with the
# same engine, so the file can never be missing. Present = leave it; prestart owns it from then on.
$serverCfgPath  = Join-Path $ServerDir "serverDZ.cfg"
$applyServerCfg = Join-Path $ServerDir "Apply-ServerCfg.ps1"
if (-not (Test-Path $serverCfgPath)) {
    if ($Fix -and (Test-Path $applyServerCfg)) {
        & $applyServerCfg -ServerDir $ServerDir -Fix
    } else {
        Write-Host "serverDZ.cfg  Missing  (-Fix renders it from serverDZ.cfg.template + host.env + server-settings.json)"
    }
}

# --- Config content: box-owned, SEEDED from the single registry (config-registry.json). Every
# surface with a 'seed' is copied to the box ONLY when missing there (fresh box / disaster
# recovery); an existing box copy is authoritative and reported BoxOwned (never overwritten -
# the web editor owns config changes). This is the ONE list of config files: the API allowlist,
# the pulls, and Confirm-LiveConfigs all read the same config-registry.json. Add a config = one row.
$registryPath = Join-Path $PSScriptRoot "config-registry.json"
if (Test-Path $registryPath) {
    Write-Host "`n--- Config content (config-registry.json -> seed-if-missing) ---"
    $seedRows = @((Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json).surfaces | Where-Object { $_.seed })
    foreach ($s in $seedRows) {
        $src = Join-Path $PSScriptRoot $s.seed      # seed paths are repo-root-relative
        $dst = Join-Path $ServerDir $s.box
        if (-not (Test-Path $src)) {
            Write-Host ("{0,-8} {1,-9} {2}" -f "SEEDGONE", "none", $s.box)
            Write-Warning "registry seed source missing: $($s.seed) (a fresh box could not be seeded with '$($s.name)')."
            $results += [PSCustomObject]@{ Timestamp = Get-Date -Format "s"; File = $s.seed; State = "SeedGone"; Action = "none" }
            continue
        }
        $state = if (Test-Path $dst) { "BoxOwned" } else { "Missing" }
        $action = "none"
        if ($Fix -and $state -eq "Missing") {
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item $src $dst -Force
            $action = "seeded"
        }
        Write-Host ("{0,-8} {1,-9} {2}" -f $state, $action, $s.box)
        $results += [PSCustomObject]@{ Timestamp = Get-Date -Format "s"; File = $s.seed; State = $state; Action = $action }
    }
} else {
    Write-Warning "config-registry.json not found next to Deploy — no config content will be seeded (fresh-box restore would be incomplete)."
}

# --- Frozen defaults: config-defaults/ is a PULLED MIRROR of the box-born <stem>.defaults<ext>
# baselines (Sync-ConfigDefaults.ps1) - box-owned config content like the rest. SEED ONLY: a
# baseline missing on the box (fresh box / disaster recovery) is restored from the mirror so
# prestart rebuilds live = that exact default + patches; an existing box baseline is
# authoritative and never overwritten (a re-capture after a mod update must stick).
$defaultsDir = Join-Path $PSScriptRoot "config-defaults"
if (Test-Path $defaultsDir) {
    Write-Host "`n--- Frozen defaults (config-defaults/ mirror -> seed-if-missing) ---"
    $defFiles = @(Get-ChildItem -Path $defaultsDir -Recurse -File | Where-Object Name -ne 'README.md')
    foreach ($f in $defFiles) {
        $rel = $f.FullName.Substring($defaultsDir.Length).TrimStart('/', '\')
        $dst = Join-Path $ServerDir $rel
        $state = if (Test-Path $dst) { "BoxOwned" } else { "Missing" }
        $action = "none"
        if ($Fix -and $state -eq "Missing") {
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item $f.FullName $dst -Force
            $action = "seeded"
        }
        Write-Host ("{0,-8} {1,-9} {2}" -f $state, $action, $rel)
    }
    if (-not $defFiles.Count) { Write-Host "  (none yet - born on first prestart, pulled into the repo by Sync-ConfigDefaults)" }
}

# --- Live folder mirror: config-mirror/ is a PULLED MIRROR of the LIVE files behind registry
# folder rows tagged "mirror":"live" (Pull-Configs). Same rule as config-defaults/ - SEED ONLY:
# restored when missing on the box (fresh box / disaster recovery / a staging VM that has never
# booted that mission), never overwritten when present. This is what makes staging able to hold
# prod's real mission config instead of whatever the mod happens to generate on first boot.
$mirrorDir = Join-Path $PSScriptRoot "config-mirror"
if (Test-Path $mirrorDir) {
    Write-Host "`n--- Live config mirror (config-mirror/ -> seed-if-missing) ---"
    $mirFiles = @(Get-ChildItem -Path $mirrorDir -Recurse -File | Where-Object Name -ne 'README.md')
    foreach ($f in $mirFiles) {
        $rel = $f.FullName.Substring($mirrorDir.Length).TrimStart('/', '\')
        $dst = Join-Path $ServerDir $rel
        $state = if (Test-Path $dst) { "BoxOwned" } else { "Missing" }
        $action = "none"
        if ($Fix -and $state -eq "Missing") {
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item $f.FullName $dst -Force
            $action = "seeded"
        }
        Write-Host ("{0,-8} {1,-9} {2}" -f $state, $action, $rel)
    }
    if (-not $mirFiles.Count) { Write-Host "  (empty - run Pull-Configs.ps1 -Execute against prod to populate it)" }
}

# Mods referenced by the unit but missing on disk: in -Fix mode, download them NOW by
# running update.sh (just synced above, so it has the current mod list). The player
# guard already ensured nobody is on the server; the steamcmd login still kicks any
# live Steam session of the server account elsewhere — accepted cost of hands-off
# deploys. On update failure the restart is skipped so the running server stays
# consistent. Report mode just warns.
# The mod set comes straight from mods.conf ($enabledMods, parsed above) — no more
# regex-scraping the unit (an unanchored '-mod=' once matched a commented-out ExecStart
# and silently skipped update.sh, 2026-07-10: unit advertised 13 mods, disk had 6).
$missingMods = @($enabledMods | Where-Object { $_ -and -not (Test-Path (Join-Path $ServerDir $_)) })
if ($missingMods.Count) {
    if ($Fix -and -not $NoRestart) {
        Write-Host "Mods missing under ${ServerDir}: $($missingMods -join ', ') — running update.sh (steamcmd; kicks any live Steam session of the server account; may take a while)."
        bash (Join-Path $ServerDir "update.sh")
        if ($LASTEXITCODE) {
            Write-Error "update.sh failed (exit $LASTEXITCODE) — skipping restart so the running server stays consistent. Fix the cause and re-run."
            if (-not $NoLog) { Stop-Transcript | Out-Null }
            exit 4
        }
        $stillMissing = @($enabledMods | Where-Object { $_ -and -not (Test-Path (Join-Path $ServerDir $_)) })
        if ($stillMissing.Count) {
            Write-Warning "still missing after update.sh: $($stillMissing -join ', ') (optional/removed workshop item?) — restarting anyway; drop them from the -mod line if clients get signature kicks."
        }
    } else {
        Write-Warning "unit references mods not present under ${ServerDir}: $($missingMods -join ', ') — the next '-Fix' will auto-download them via update.sh."
    }
}

# --- Config overrides: the AUTHORITATIVE apply now happens at RUNTIME in prestart.sh, which
# patches the live CE/mod files on every server start (before the engine reads them). So an
# admin can edit config-overrides.json and just restart — no deploy needed. Here we only
# REPORT the pending diff (what the coming restart's prestart will apply), never write, so a
# deploy shows the field-level changes without a second writer. FAIL-SOFT is prestart's job.
$applier = Join-Path $PSScriptRoot "Apply-ConfigOverrides.ps1"
if (Test-Path $applier) {
    Write-Host "`n--- Config overrides (pending — applied by prestart on next start) ---"
    # Pull-only model: prestart applies the BOX's own document ($ServerDir/config-overrides.json),
    # so report against that copy. Fall back to the repo mirror only when the box has none yet
    # (fresh box — the mirror is exactly what -Fix seeds there).
    $liveManifest = Join-Path $ServerDir 'config-overrides.json'
    if (-not (Test-Path $liveManifest)) { $liveManifest = Join-Path $PSScriptRoot 'config-overrides.json' }
    $ovr = & $applier -ServerDir $ServerDir -Manifest $liveManifest      # report-only, no -Fix
    if ($ovr.Warn -gt 0) { Write-Warning "config overrides: $($ovr.Warn) override(s) will fail at apply time (see [WARN] lines above)." }
} else {
    Write-Warning "Apply-ConfigOverrides.ps1 not found next to Deploy — skipping config override report."
}

$restarted = $false
if ($Fix) {
    sudo systemctl daemon-reload
    # Boot persistence: `enable` (NOT --now) only writes the wants symlink, so it is safe
    # under -NoRestart and a no-op on a box that already has it. Without this a rebuilt box
    # comes up with the game server dead after every reboot — found on staging 2026-07-21,
    # where the unit was 'disabled' after a clean deploy (RECOVERY.md depends on this).
    sudo systemctl enable dayz-server
    # Timer enable is safe under -NoRestart: it never touches the game server process.
    sudo systemctl enable --now dayz-logarchive.timer
    # Auto-update-check timer: on unless DEPLOY_UPDATE_CHECK_INTERVAL=off. Disabling only
    # stops the periodic check — the manual API arm + prestart apply path are unaffected.
    if ($UpdateCheckEnabled) {
        Write-Host "Auto-update check: every $DeployUpdateCheckInterval (enabling dayz-update-check.timer)"
        sudo systemctl enable --now dayz-update-check.timer
    } else {
        Write-Host "Auto-update check: disabled (DEPLOY_UPDATE_CHECK_INTERVAL=off) — stopping dayz-update-check.timer"
        sudo systemctl disable --now dayz-update-check.timer 2>$null
    }
    if (-not $NoRestart) {
        sudo systemctl restart dayz-server
        Start-Sleep -Seconds 3
        $active = systemctl is-active dayz-server
        Write-Host "Service state after restart: $active"
        $restarted = $true
    }
} elseif (($results | Where-Object { $_.State -notin 'InSync', 'BoxOwned' })) {
    Write-Host "`nDrift detected. Re-run with -Fix to deploy."
}

if (-not $NoLog) {
    $csv = Join-Path $logDir "deploy.csv"
    $results | ForEach-Object { Write-CsvLog -Path $csv -Row $_ }
    Write-CsvLog -Path $csv -Row ([PSCustomObject]@{
        Timestamp = Get-Date -Format "s"; File = "(summary)"; State = "Fix=$Fix"; Action = "restarted=$restarted"
    })
    Stop-Transcript | Out-Null
    # Retention: the CSV appends forever (one summary row per run), transcripts get pruned.
    Get-ChildItem $logDir -Filter 'deploy_*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 30 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
