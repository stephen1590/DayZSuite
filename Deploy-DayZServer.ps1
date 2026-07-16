#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Validates (default) or deploys (-Fix) the DayZ server setup from ./deploy onto this machine.
.DESCRIPTION
    Read-only by default: reports drift between the ./deploy payload and the live
    locations (server dir + systemd units). -Fix copies the payload into place (sudo
    for units), reloads systemd, and restarts the service unless -NoRestart.

    Every run also pulls the live spawn-points.json off the box first (Sync-SpawnPoints.ps1)
    so runtime edits from the ConfigViewer Map editor aren't clobbered by re-shipping the repo
    copy — see that script for the snapshot-before-overwrite + no-op-when-unchanged behavior.

    Host portability: the systemd units in the payload are TEMPLATES with
    {{DEPLOY_USER}}/{{DEPLOY_GROUP}}/{{DEPLOY_HOME}} placeholders; per-host values
    come from `host.env` beside this script (or the -Deploy* params), and the units
    are RENDERED before comparing and deploying — the SAME payload is drift-clean on
    any host. host.env is per-host and NOT part of the payload (like map.env); absent
    => built-in defaults (ubuntu, the VPS). Copy host.env.example on each new host.

    Two separate local, gitignored files: host.env describes the SERVER (lives there,
    rendered into what runs there). deployer.env describes where to REACH the server
    (dev-machine-local; only read when NOT -Local; never rsynced over). Never conflate
    the two — see deployer.env.example.

    Full output goes to a timestamped transcript in ./logs plus a CSV summary; -NoLog disables both.
.EXAMPLE
    ./Deploy-DayZServer.ps1                   # THE deploy (default = remote): drift report on the VPS
    ./Deploy-DayZServer.ps1 -Fix              # THE deploy: apply on the VPS (+restart, arm timer)
    ./Deploy-DayZServer.ps1 -Local            # on-box apply (used by the ssh leg on the VPS itself)
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$NoRestart,
    [switch]$NoLog,
    [switch]$Force,                                         # deploy even with players online / unverifiable count
    [switch]$Local,                                         # apply to THIS machine (the ssh leg uses this on the VPS)
    [string]$RemoteHost,                                    # dev-machine-local — see deployer.env below, or -RemoteHost
    [string]$RemoteUser   = "ubuntu",                       # override via deployer.env's DEPLOY_REMOTE_USER if it differs
    [string]$RemoteDir    = "dayz-tooling",
    [string]$HostEnv     = (Join-Path $PSScriptRoot "host.env"),
    [string]$DeployerEnv = (Join-Path $PSScriptRoot "deployer.env"),
    [string]$DeployUser,
    [string]$DeployGroup,
    [string]$DeployHome,
    [string]$ServerDir,
    [string]$UnitPath   = "/etc/systemd/system/dayz-server.service"
)

# deployer.env is dev-machine-local config (which box to reach) — the opposite of host.env
# (which describes the server itself) and never rsynced there (see the --exclude below).
# Read it early, only filling params not already given explicitly on the command line.
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
        Write-Error "DEPLOY_REMOTE_HOST is not set. Copy deployer.env.example to deployer.env (dev-machine-local, gitignored — never host.env, that's server config) and set it, or pass -RemoteHost explicitly. -Local skips this if you're running directly on the server."
        exit 2
    }
    $RemoteTarget = "${RemoteUser}@${RemoteHost}"
    $sshOpt = "ssh -o ConnectTimeout=10"

    # Spawn points: the live box is authoritative for AI-bandit spawn locations (admins/the web
    # editor write spawn-points.json at runtime via the API — roles are inverted from the rest of
    # this deploy). Pull it DOWN FIRST so edits made since the last deploy aren't clobbered by the
    # rsync re-shipping the repo copy. Report-only unless -Fix; the sync validates JSON, snapshots
    # the repo copy before overwriting, and leaves the repo seed untouched for a fresh/empty box.
    # (Replaces the old Sync-VPPCoordinates pull — VPP is no longer the source; see that script,
    # now a one-shot importer, and Migrate-SpawnPoints.ps1 for the original seed.)
    $spawnSync = Join-Path $PSScriptRoot "Sync-SpawnPoints.ps1"
    if (Test-Path $spawnSync) {
        Write-Host "--- spawn points (pull-before-push: box authoritative) ---"
        if ($Fix) { & $spawnSync -RemoteHost $RemoteHost -RemoteUser $RemoteUser -NoLog:$NoLog -Execute }
        else      { & $spawnSync -RemoteHost $RemoteHost -RemoteUser $RemoteUser -NoLog:$NoLog }
        Write-Host ""
    }

    # Config overrides: the live box is authoritative (an admin sets overrides at runtime via
    # the ConfigViewer). Pull the box's config-overrides.json DOWN before the rsync re-ships it,
    # so admin edits aren't clobbered. Read-only unless -Fix; the sync validates JSON, snapshots
    # the repo copy before overwriting, and falls back to config-overrides.fallback.json for a
    # fresh/empty/invalid box.
    $ovrSync = Join-Path $PSScriptRoot "Sync-ConfigOverrides.ps1"
    if (Test-Path $ovrSync) {
        Write-Host "--- config overrides (pull-before-push: box authoritative) ---"
        if ($Fix) { & $ovrSync -RemoteHost $RemoteHost -RemoteUser $RemoteUser -NoLog:$NoLog -Execute }
        else      { & $ovrSync -RemoteHost $RemoteHost -RemoteUser $RemoteUser -NoLog:$NoLog }
        Write-Host ""
    }

    # Frozen defaults: the box-born baselines behind the reversible overrides (config-defaults/).
    # Same pull-before-push — capture the ones the repo lacks (repo authoritative once captured);
    # the rsync + the -Local step below ship config-defaults/ back to the ServerDir.
    $defSync = Join-Path $PSScriptRoot "Sync-ConfigDefaults.ps1"
    if (Test-Path $defSync) {
        Write-Host "--- config defaults (pull-before-push: box-born, repo-authoritative once captured) ---"
        if ($Fix) { & $defSync -RemoteHost $RemoteHost -RemoteUser $RemoteUser -NoLog:$NoLog -Execute }
        else      { & $defSync -RemoteHost $RemoteHost -RemoteUser $RemoteUser -NoLog:$NoLog }
        Write-Host ""
    }

    Write-Host "Deploying to ${RemoteTarget}:${RemoteDir} (Fix=$Fix)`n"
    & rsync -az --delete -e $sshOpt --exclude=logs --exclude=mirror --exclude=backups --exclude=host.env --exclude=deployer.env "$PSScriptRoot/" "${RemoteTarget}:${RemoteDir}/"
    if ($LASTEXITCODE) { Write-Error "tooling rsync failed (exit $LASTEXITCODE)"; exit 1 }
    $commonSrc = (Resolve-Path (Join-Path $PSScriptRoot "../../common")).Path
    & rsync -az --delete -e $sshOpt "$commonSrc" "${RemoteTarget}:${RemoteDir}/"
    if ($LASTEXITCODE) { Write-Error "common/ rsync failed (exit $LASTEXITCODE)"; exit 1 }
    $flags = @('-Local'); if ($Fix) { $flags += '-Fix' }; if ($NoRestart) { $flags += '-NoRestart' }; if ($NoLog) { $flags += '-NoLog' }; if ($Force) { $flags += '-Force' }
    ssh -t -o ConnectTimeout=10 $RemoteTarget "cd $RemoteDir && { [ -f host.env ] || cp host.env.example host.env; } && pwsh -NoProfile ./Deploy-DayZServer.ps1 $($flags -join ' ')"
    exit $LASTEXITCODE
}

# Find common/Utils.ps1 without assuming the dev-machine layout: dev box has it at
# ../../common; a flat copy on another host can put it at ./common or ../common.
$utils = "../../common/Utils.ps1", "../common/Utils.ps1", "./common/Utils.ps1" |
    ForEach-Object { Join-Path $PSScriptRoot $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $utils) { throw "common/Utils.ps1 not found near $PSScriptRoot (tried ../../common, ../common, ./common)" }
. $utils

# --- Per-host values: built-in defaults (the VPS) <- host.env <- explicit -Deploy* params ---
# DEPLOY_SERVER_PASSWORD/DEPLOY_ADMIN_PASSWORD/DEPLOY_STEAM_ACCOUNT have NO built-in default
# (unlike user/group/home) — they identify a real account/secret and must never be baked into
# this tracked script. serverDZ.cfg/update.sh carry them only as {{...}} placeholders; see the
# hard-fail check below.
$hv = [ordered]@{ DEPLOY_USER = 'ubuntu'; DEPLOY_GROUP = 'ubuntu'; DEPLOY_HOME = '/home/ubuntu'; DEPLOY_SERVER_PASSWORD = $null; DEPLOY_ADMIN_PASSWORD = $null; DEPLOY_STEAM_ACCOUNT = $null; DEPLOY_UPDATE_CHECK_INTERVAL = '4h' }
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
if (-not $DeployServerPassword -or -not $DeployAdminPassword) {
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
$logDir    = Join-Path $PSScriptRoot "logs"
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

# Server-only mod (-serverMod=@aib_tracker): OUR AIB_Tracker PBO. It is NOT a workshop item,
# so it's NOT in mods.conf and never touches update.sh — it's an artifact HEMTT packs from
# serverMods/AIB_Tracker (the build output IS the addons folder). Build and deploy stay
# separate explicit steps, like the rest of Code->Document->Deploy: the PBO must already be
# built here. If it's missing we STOP with the build command rather than silently packing
# mid-deploy. The PBO ships as a normal $items entry below into @aib_tracker/addons on the box.
# serverMods/ is a sibling of deploy/ (the tooling root, $PSScriptRoot) — NOT under deploy/.
$trackerSrcDir = Join-Path $PSScriptRoot "serverMods/AIB_Tracker"
$trackerPbo    = Join-Path $trackerSrcDir ".hemttout/build/addons/AIB_Tracker_main.pbo"
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
    Write-Warning "AIB_Tracker source ($($trackerNewest.Name)) is newer than its PBO — run 'hemtt build' in $trackerSrcDir to repack before deploying the tracker."
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
    # Server-only tracker PBO -> @aib_tracker/addons on the box (matches -serverMod=@aib_tracker
    # in the unit). OUR artifact from HEMTT, guarded above; drift-checked like any payload file.
    @{ Src = "../serverMods/AIB_Tracker/.hemttout/build/addons/AIB_Tracker_main.pbo"
       Dst = Join-Path $ServerDir "@aib_tracker/addons/AIB_Tracker_main.pbo"; Sudo = $false; Exec = $false }
    # Second server-only PBO -> @transfer_spawn/addons (matches -serverMod=…;@transfer_spawn).
    @{ Src = "../serverMods/TransferSpawn/.hemttout/build/addons/TransferSpawn_main.pbo"
       Dst = Join-Path $ServerDir "@transfer_spawn/addons/TransferSpawn_main.pbo"; Sudo = $false; Exec = $false }
    @{ Src = "prestart.sh";         Dst = Join-Path $ServerDir "prestart.sh";  Sudo = $false; Exec = $true  }
    # prestart.sh calls this to write profiles/transfer_spawn.json for the TransferSpawn PBO.
    @{ Src = "Build-TransferSpawns.ps1"; Dst = Join-Path $ServerDir "Build-TransferSpawns.ps1"; Sudo = $false; Exec = $false }
    @{ Src = "serverDZ.cfg";        Dst = Join-Path $ServerDir "serverDZ.cfg"; Sudo = $false; Exec = $false; Render = $true }
    @{ Src = "profiles/VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt"
       Dst = Join-Path $ServerDir "profiles/VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt"
       Sudo = $false; Exec = $false }
    # VPP permission groups: full-file owned (we author it, nothing regenerates it) — NOT a
    # config-overrides patch. Steam64IDs + per-group permission lists, copied verbatim.
    @{ Src = "profiles/VPPAdminTools/Permissions/UserGroups/UserGroups.json"
       Dst = Join-Path $ServerDir "profiles/VPPAdminTools/Permissions/UserGroups/UserGroups.json"
       Sudo = $false; Exec = $false }
    # AI_Bandits DynamicAIB/StaticAIB are per-map (raw world coords) and the mod reads one fixed
    # path, so the flat profiles/AI_Bandits/*.json is NOT shipped - it's a generated artifact,
    # composed each start by Build-AIBandits.ps1 (prestart) from common + maps/<mission>. We ship
    # the SOURCE tree; add a new maps/<mission>/DynamicAIB.json (+ line here) to cover another map.
    @{ Src = "profiles/AI_Bandits/common/DynamicAIB.common.json"
       Dst = Join-Path $ServerDir "profiles/AI_Bandits/common/DynamicAIB.common.json"; Sudo = $false; Exec = $false }
    # Spawn classification (category token -> template, size letter -> count) + the definitive
    # spawn-points.json store. Build-AIBandits composes groups from these by name at prestart, so
    # both must be on the box. spawn-points.json is pulled-before-push (box authoritative — the web
    # editor writes it live); the pull happens in the remote block above before this rsync/copy.
    @{ Src = "profiles/AI_Bandits/common/classification.json"
       Dst = Join-Path $ServerDir "profiles/AI_Bandits/common/classification.json"; Sudo = $false; Exec = $false }
    @{ Src = "profiles/AI_Bandits/spawn-points.json"
       Dst = Join-Path $ServerDir "profiles/AI_Bandits/spawn-points.json"; Sudo = $false; Exec = $false }
    # Sakhal has NO per-map DynamicAIB.json: its dynamic spawns come ENTIRELY from spawn-points.json
    # (with classification.json above), composed into groups by the builder at prestart.
    # Only StaticAIB (fixed sentry NPCs) is per-map for Sakhal.
    @{ Src = "profiles/AI_Bandits/maps/dayzOffline.sakhal/StaticAIB.json"
       Dst = Join-Path $ServerDir "profiles/AI_Bandits/maps/dayzOffline.sakhal/StaticAIB.json"; Sudo = $false; Exec = $false }
    # Chernarus: PARKED — kept in the repo but intentionally NOT deployed (its $items ship line was
    # removed 2026-07-12). It's a working compose-schema config (scalespeeder coordinates + shared
    # common templates), dormant until someone runs dayzOffline.chernarusplus. To reactivate:
    # re-add its ship line here and switch map.env. See maps/dayzOffline.chernarusplus/PARKED.md.
    # KnockKnock settings are NOT a full-file item: it's the mod's own generated config, so
    # we PATCH only chanceToSpawn via config-overrides.json (survives mod updates). See the
    # Apply-ConfigOverrides step below.
    @{ Src = "messages.xml";        Dst = Join-Path $ServerDir "messages.xml";  Sudo = $false; Exec = $false }
    @{ Src = "dayz-rcon.ps1";       Dst = Join-Path $ServerDir "dayz-rcon.ps1"; Sudo = $false; Exec = $true  }
    # Shared log-archive engine — single source in common/ (rsynced to the box alongside the
    # tooling tree); copied into the server dir so dayz-logarchive.timer runs it there.
    @{ Src = "../common/Archive-Logs.ps1"; Dst = Join-Path $ServerDir "Archive-Logs.ps1"; Sudo = $false; Exec = $true }
    # Override engine + manifest live in the SERVER dir so prestart.sh applies them on every
    # start (Src '..' = tooling root, the parent of deploy/). An admin can edit
    # config-overrides.json and just restart — prestart patches the live files pre-boot.
    @{ Src = "../Apply-ConfigOverrides.ps1"; Dst = Join-Path $ServerDir "Apply-ConfigOverrides.ps1"; Sudo = $false; Exec = $true }
    @{ Src = "../config-overrides.json";     Dst = Join-Path $ServerDir "config-overrides.json";     Sudo = $false; Exec = $false }
    # AI bandit builder lives in the server dir so prestart composes the flat DynamicAIB/StaticAIB
    # from common + maps/<mission> on every start (see the AI_Bandits source tree above).
    @{ Src = "../Build-AIBandits.ps1";       Dst = Join-Path $ServerDir "Build-AIBandits.ps1";       Sudo = $false; Exec = $true }
    # Common custom CE types (modded items like CodeLock): the map-agnostic source + its applier
    # live in the server dir; prestart copies the types into the active mission's custom/ folder
    # and registers <ce folder="custom"> in that mission's cfgeconomycore.xml (never the vanilla
    # types.xml). Add modded types to custom-ce/custom_types.xml - no new ship line per item.
    @{ Src = "custom-ce/custom_types.xml";   Dst = Join-Path $ServerDir "custom-ce/custom_types.xml"; Sudo = $false; Exec = $false }
    @{ Src = "../Apply-CustomCE.ps1";        Dst = Join-Path $ServerDir "Apply-CustomCE.ps1";        Sudo = $false; Exec = $true }
    @{ Src = "dayz-server.service"; Dst = $UnitPath;                            Sudo = $true;  Exec = $false; Render = $true }
    @{ Src = "dayz-logarchive.service"; Dst = "/etc/systemd/system/dayz-logarchive.service"; Sudo = $true; Exec = $false; Render = $true }
    @{ Src = "dayz-logarchive.timer";   Dst = "/etc/systemd/system/dayz-logarchive.timer";   Sudo = $true; Exec = $false }
    # Auto-update-check unit + timer (timer interval rendered from host.env). The timer is
    # enabled/disabled by DEPLOY_UPDATE_CHECK_INTERVAL in the -Fix block below.
    @{ Src = "dayz-update-check.service"; Dst = "/etc/systemd/system/dayz-update-check.service"; Sudo = $true; Exec = $false; Render = $true }
    @{ Src = "dayz-update-check.timer";   Dst = "/etc/systemd/system/dayz-update-check.timer";   Sudo = $true; Exec = $false; Render = $true }
)

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

# --- Frozen defaults: ship config-defaults/ (the repo mirror) into the ServerDir, so a
# hand-edited default takes effect and prestart has the baseline it rebuilds live = default +
# patches from. Repo-authoritative: the dev-side Sync-ConfigDefaults.ps1 pulled box-born
# defaults up first. Paths beneath config-defaults/ are server-relative and map 1:1. -Fix writes.
$defaultsDir = Join-Path $PSScriptRoot "config-defaults"
if (Test-Path $defaultsDir) {
    Write-Host "`n--- Frozen defaults (config-defaults/ -> ServerDir) ---"
    $defFiles = @(Get-ChildItem -Path $defaultsDir -Recurse -File)
    foreach ($f in $defFiles) {
        $rel = $f.FullName.Substring($defaultsDir.Length).TrimStart('/', '\')
        $dst = Join-Path $ServerDir $rel
        $state = if (-not (Test-Path $dst)) { "Missing" }
                 elseif ((Get-FileHash $f.FullName).Hash -eq (Get-FileHash $dst).Hash) { "InSync" } else { "Drift" }
        $action = "none"
        if ($Fix -and $state -ne "InSync") {
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item $f.FullName $dst -Force
            $action = "deployed"
        }
        Write-Host ("{0,-8} {1,-9} {2}" -f $state, $action, $rel)
    }
    if (-not $defFiles.Count) { Write-Host "  (none yet - born on first prestart, pulled into the repo by Sync-ConfigDefaults on the next deploy)" }
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
    $ovr = & $applier -ServerDir $ServerDir      # report-only, no -Fix
    if ($ovr.Warn -gt 0) { Write-Warning "config overrides: $($ovr.Warn) override(s) will fail at apply time (see [WARN] lines above)." }
} else {
    Write-Warning "Apply-ConfigOverrides.ps1 not found next to Deploy — skipping config override report."
}

$restarted = $false
if ($Fix) {
    sudo systemctl daemon-reload
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
} elseif (($results | Where-Object State -ne "InSync")) {
    Write-Host "`nDrift detected. Re-run with -Fix to deploy."
}

if (-not $NoLog) {
    $csv = Join-Path $logDir "deploy.csv"
    $results | ForEach-Object { Write-CsvLog -Path $csv -Row $_ }
    Write-CsvLog -Path $csv -Row ([PSCustomObject]@{
        Timestamp = Get-Date -Format "s"; File = "(summary)"; State = "Fix=$Fix"; Action = "restarted=$restarted"
    })
    Stop-Transcript | Out-Null
}
