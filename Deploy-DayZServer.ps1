#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Validates (default) or deploys (-Fix) the DayZ server setup from ./deploy onto this machine.
.DESCRIPTION
    Read-only by default: reports drift between the ./deploy payload and the live
    locations (server dir + systemd units). -Fix copies the payload into place (sudo
    for units), reloads systemd, and restarts the service unless -NoRestart.

    Host portability: the systemd units in the payload are TEMPLATES with
    {{DEPLOY_USER}}/{{DEPLOY_GROUP}}/{{DEPLOY_HOME}} placeholders; per-host values
    come from `host.env` beside this script (or the -Deploy* params), and the units
    are RENDERED before comparing and deploying — the SAME payload is drift-clean on
    any host. host.env is per-host and NOT part of the payload (like map.env); absent
    => built-in defaults (ubuntu, the VPS). Copy host.env.example on each new host.

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
    [string]$RemoteTarget = "ubuntu@servermander.ovh",
    [string]$RemoteDir    = "dayz-tooling",
    [string]$HostEnv    = (Join-Path $PSScriptRoot "host.env"),
    [string]$DeployUser,
    [string]$DeployGroup,
    [string]$DeployHome,
    [string]$ServerDir,
    [string]$UnitPath   = "/etc/systemd/system/dayz-server.service"
)

# --- Remote is the DEFAULT: there is no local server install anymore (meshroom is
# tooling-only since 2026-07-06); the VPS is the one deployment. A bare run rsyncs
# this tooling folder + common/ to the target and runs the apply step THERE over ssh
# (-t so sudo can prompt). The ssh leg re-invokes this script with -Local on the VPS.
# Remote's own logs/ and host.env are excluded from --delete, so they survive; the
# first run seeds host.env from the example.
if (-not $Local) {
    $sshOpt = "ssh -o ConnectTimeout=10"
    Write-Host "Deploying to ${RemoteTarget}:${RemoteDir} (Fix=$Fix)`n"
    & rsync -az --delete -e $sshOpt --exclude=logs --exclude=mirror --exclude=host.env "$PSScriptRoot/" "${RemoteTarget}:${RemoteDir}/"
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
# DEPLOY_SERVER_PASSWORD/DEPLOY_ADMIN_PASSWORD have NO built-in default (unlike
# user/group/home) — they are secrets and must never be baked into this tracked
# script. serverDZ.cfg carries them only as {{...}} placeholders; see the hard-fail
# check below.
$hv = [ordered]@{ DEPLOY_USER = 'ubuntu'; DEPLOY_GROUP = 'ubuntu'; DEPLOY_HOME = '/home/ubuntu'; DEPLOY_SERVER_PASSWORD = $null; DEPLOY_ADMIN_PASSWORD = $null }
if (Test-Path $HostEnv) {
    foreach ($line in Get-Content $HostEnv) {
        if ($line -match '^\s*(DEPLOY_USER|DEPLOY_GROUP|DEPLOY_HOME|DEPLOY_SERVER_PASSWORD|DEPLOY_ADMIN_PASSWORD)\s*=\s*(.+?)\s*$') { $hv[$Matches[1]] = $Matches[2] }
    }
}
if ($DeployUser)  { $hv.DEPLOY_USER  = $DeployUser }
if ($DeployGroup) { $hv.DEPLOY_GROUP = $DeployGroup }
if ($DeployHome)  { $hv.DEPLOY_HOME  = $DeployHome }
$DeployUser = $hv.DEPLOY_USER; $DeployGroup = $hv.DEPLOY_GROUP; $DeployHome = $hv.DEPLOY_HOME
$DeployServerPassword = $hv.DEPLOY_SERVER_PASSWORD
$DeployAdminPassword  = $hv.DEPLOY_ADMIN_PASSWORD
if (-not $DeployServerPassword -or -not $DeployAdminPassword) {
    Write-Error "DEPLOY_SERVER_PASSWORD / DEPLOY_ADMIN_PASSWORD not set in $HostEnv. serverDZ.cfg's join/admin passwords are host-local secrets, never in the tracked payload. Copy host.env.example to host.env and fill both in, then re-run."
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

# Render=$true items are systemd unit TEMPLATES: their {{DEPLOY_*}} placeholders are
# substituted with this host's values before hashing and deploying.
$items = @(
    @{ Src = "update.sh";           Dst = Join-Path $ServerDir "update.sh";    Sudo = $false; Exec = $true  }
    # The registry ships next to update.sh so on-box (manual) update runs read the same set.
    @{ Src = "mods.conf";           Dst = Join-Path $ServerDir "mods.conf";   Sudo = $false; Exec = $false }
    @{ Src = "prestart.sh";         Dst = Join-Path $ServerDir "prestart.sh";  Sudo = $false; Exec = $true  }
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
    # Spawn classification (VPP name tokens -> template/size) + the pulled VPP coordinate
    # captures. Build-AIBandits overlays the coords onto placements by name at prestart, so both
    # must be on the box. The TeleportLocation.snapshot.json sibling is audit-only, NOT shipped;
    # the live TeleportLocation.json is admin-owned and is never deployed over.
    @{ Src = "profiles/AI_Bandits/common/classification.json"
       Dst = Join-Path $ServerDir "profiles/AI_Bandits/common/classification.json"; Sudo = $false; Exec = $false }
    @{ Src = "profiles/VPPAdminTools/VPPCoordinates/vpp-coordinates.json"
       Dst = Join-Path $ServerDir "profiles/VPPAdminTools/VPPCoordinates/vpp-coordinates.json"; Sudo = $false; Exec = $false }
    # Dr Jones Trader config (full-file owned, PascalCase - case-sensitive on Linux). Read from
    # $profile:Trader/. TraderConfig is the item catalog; TraderObjects places the NPCs (Sakhal
    # coords); Variables = safezone/timers; Admins = vehicle-trade admin IDs.
    @{ Src = "profiles/Trader/TraderConfig.txt"
       Dst = Join-Path $ServerDir "profiles/Trader/TraderConfig.txt"; Sudo = $false; Exec = $false }
    @{ Src = "profiles/Trader/TraderObjects.txt"
       Dst = Join-Path $ServerDir "profiles/Trader/TraderObjects.txt"; Sudo = $false; Exec = $false }
    @{ Src = "profiles/Trader/TraderVariables.txt"
       Dst = Join-Path $ServerDir "profiles/Trader/TraderVariables.txt"; Sudo = $false; Exec = $false }
    @{ Src = "profiles/Trader/TraderAdmins.txt"
       Dst = Join-Path $ServerDir "profiles/Trader/TraderAdmins.txt"; Sudo = $false; Exec = $false }
    @{ Src = "profiles/AI_Bandits/maps/dayzOffline.sakhal/DynamicAIB.json"
       Dst = Join-Path $ServerDir "profiles/AI_Bandits/maps/dayzOffline.sakhal/DynamicAIB.json"; Sudo = $false; Exec = $false }
    @{ Src = "profiles/AI_Bandits/maps/dayzOffline.sakhal/StaticAIB.json"
       Dst = Join-Path $ServerDir "profiles/AI_Bandits/maps/dayzOffline.sakhal/StaticAIB.json"; Sudo = $false; Exec = $false }
    # Chernarus: third-party mod-native full-file (scalespeeder), copied verbatim by the builder's
    # native passthrough - dormant until the server runs dayzOffline.chernarusplus. See SOURCE.md.
    @{ Src = "profiles/AI_Bandits/maps/dayzOffline.chernarusplus/DynamicAIB.json"
       Dst = Join-Path $ServerDir "profiles/AI_Bandits/maps/dayzOffline.chernarusplus/DynamicAIB.json"; Sudo = $false; Exec = $false }
    @{ Src = "profiles/VPPAdminTools/ItemPresets.json"
       Dst = Join-Path $ServerDir "profiles/VPPAdminTools/ItemPresets.json"; Sudo = $false; Exec = $false }
    # KnockKnock settings are NOT a full-file item: it's the mod's own generated config, so
    # we PATCH only chanceToSpawn via config-overrides.json (survives mod updates). See the
    # Apply-ConfigOverrides step below.
    @{ Src = "messages.xml";        Dst = Join-Path $ServerDir "messages.xml";  Sudo = $false; Exec = $false }
    @{ Src = "dayz-rcon.ps1";       Dst = Join-Path $ServerDir "dayz-rcon.ps1"; Sudo = $false; Exec = $true  }
    @{ Src = "Archive-Logs.ps1";    Dst = Join-Path $ServerDir "Archive-Logs.ps1"; Sudo = $false; Exec = $true }
    # Override engine + manifest live in the SERVER dir so prestart.sh applies them on every
    # start (Src '..' = tooling root, the parent of deploy/). An admin can edit
    # config-overrides.json and just restart — prestart patches the live files pre-boot.
    @{ Src = "../Apply-ConfigOverrides.ps1"; Dst = Join-Path $ServerDir "Apply-ConfigOverrides.ps1"; Sudo = $false; Exec = $true }
    @{ Src = "../config-overrides.json";     Dst = Join-Path $ServerDir "config-overrides.json";     Sudo = $false; Exec = $false }
    # AI bandit builder lives in the server dir so prestart composes the flat DynamicAIB/StaticAIB
    # from common + maps/<mission> on every start (see the AI_Bandits source tree above).
    @{ Src = "../Build-AIBandits.ps1";       Dst = Join-Path $ServerDir "Build-AIBandits.ps1";       Sudo = $false; Exec = $true }
    @{ Src = "dayz-server.service"; Dst = $UnitPath;                            Sudo = $true;  Exec = $false; Render = $true }
    @{ Src = "dayz-logarchive.service"; Dst = "/etc/systemd/system/dayz-logarchive.service"; Sudo = $true; Exec = $false; Render = $true }
    @{ Src = "dayz-logarchive.timer";   Dst = "/etc/systemd/system/dayz-logarchive.timer";   Sudo = $true; Exec = $false }
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
            Replace('{{DEPLOY_ADMIN_PASSWORD}}', $DeployAdminPassword)
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
