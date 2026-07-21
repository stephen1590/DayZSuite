#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Regenerate LEGIT pristine config defaults by standing up a throwaway local DayZ
    server with the real mod set, then reconcile them against today's frozen baselines.

.DESCRIPTION
    The frozen baselines in config-defaults/ were captured from the LIVE file the first
    time prestart patched it (Apply-ConfigOverrides.ps1) — so each "default" is really
    "pristine default + whatever was already baked in". Re-capturing on the box can't fix
    that (the live file is already default+patches). The only source of truth is a clean
    server + the mods themselves:

      - globals.xml (chernarus/enoch/sakhal)        -> STATIC vanilla mission file, copied
                                                        straight from the clean download.
      - sakhal expansion/settings/*.json            -> written by Expansion into the mission
        (Spawn/Map/AIPatrol)                           on first boot (empty mission).
      - ExpansionMod SocialMediaSettings,           -> written by each mod into an EMPTY
        AIB_Unleashed AIB_UL_Config,                   profile on first boot.
        KnockKnockAIBandits_Settings

    One boot of the SAKHAL mission with an empty profile generates all six mod-authored
    files; the three globals are copied post-download. Everything lands in a named
    candidate dir — config-defaults/ is NEVER touched. A reconcile report then diffs each
    capture against the current baseline AND config-overrides.json, so you can see which
    fields you have actually changed vs which were silently baked into the old baseline.

    Fidelity: the boot loads the EXACT mods.conf set + order that prod runs (the modline is
    derived the same way Deploy-DayZServer.ps1 renders {{DEPLOY_MODLINE}}), and reuses
    deploy/update.sh verbatim for the steamcmd download + mod sync — same tool, same result.

    READ-ONLY BY DEFAULT: a bare run REPORTS the plan (paths, the 27-mod chain, steamcmd +
    login state, what it would capture) and, if a candidate already exists, prints the
    reconcile report — it downloads nothing and boots nothing. -Run performs the heavy work
    (bootstrap steamcmd, download ~15GB, boot, harvest) into the candidate dir. Fail-soft:
    a file the boot didn't produce is reported missing, never faked.

    Steam Guard is interactive and cannot be automated. If steamcmd has no cached session,
    the script prints the one-time login command and stops; run it, then re-run with -Run.

    Nothing here writes to the box or to config-defaults/. Adopting a candidate is a separate,
    deliberate step you take after reading the reconcile report.

.EXAMPLE
    ./Generate-ConfigDefaults.ps1
        Dry run: show the plan + the mod chain + login state; reconcile if a candidate exists.

.EXAMPLE
    ./Generate-ConfigDefaults.ps1 -Run -SteamAccount myaccount
        Bootstrap steamcmd, download the server + 27 mods, boot sakhal once, harvest the 9
        pristine defaults into config-defaults-candidate/, then print the reconcile report.

.EXAMPLE
    ./Generate-ConfigDefaults.ps1 -Reconcile
        Re-run only the reconcile report against an existing candidate dir (no download/boot).
#>
[CmdletBinding()]
param(
    # Do the heavy work (steamcmd bootstrap + download + boot + harvest). Omit for a dry run.
    [switch]$Run,
    # Only (re)print the reconcile report against an existing candidate; implies no download/boot.
    [switch]$Reconcile,
    # Promote the captured candidates into config-defaults/ (the real baselines). WRITE action —
    # off by default. Operates on the existing candidate dir; no download/boot. config-overrides.json
    # is NOT touched: every current baseline<->default delta is already covered by an override, so
    # adopting is behavior-neutral (overrides re-apply on prestart) and just makes the baselines honest.
    [switch]$Adopt,
    # Steam account that OWNS DayZ (anonymous login fails). Falls back to DEPLOY_STEAM_ACCOUNT
    # in deploy/host.env, matching how the real deploy sources it.
    [string]$SteamAccount,
    # Where the throwaway server + steamcmd live. ~15GB; never inside the repo.
    [string]$WorkRoot = (Join-Path $HOME ".cache/dayz-defaults"),
    # Mission the boot loads. Sakhal so Expansion writes the sakhal mission settings too.
    [string]$Mission = "dayzOffline.sakhal",
    # How long to let the boot run while polling for the generated files before stopping it.
    # 27 mods + Expansion loading sakhal is slow on first boot — give it room.
    [int]$BootTimeoutSeconds = 360,
    # Candidate output dir (mirrors config-defaults/ layout). config-defaults/ is never touched.
    [string]$CandidateDir = (Join-Path $PSScriptRoot "config-defaults-candidate"),
    # Bypass the cached-login detection and proceed to download (insurance if steamcmd's
    # config.vdf format doesn't carry the account name plaintext on your build).
    [switch]$SkipLoginCheck,
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "../../../common/Utils.ps1")

# ---- repo paths ----------------------------------------------------------------------
$deployDir   = Join-Path $PSScriptRoot "deploy"
$modsConf    = Join-Path $deployDir "mods.conf"
$updateSh    = Join-Path $deployDir "update.sh"
$baselineDir = Join-Path $PSScriptRoot "config-defaults"
$overrides   = Join-Path $PSScriptRoot "config-overrides.json"

# ---- local server layout update.sh self-locates against ------------------------------
#   <WorkRoot>/servers/{dayz-server,steamcmd,steamhome}
$serversDir  = Join-Path $WorkRoot "servers"
$serverDir   = Join-Path $serversDir "dayz-server"
$steamcmdDir = Join-Path $serversDir "steamcmd"
$steamHome   = Join-Path $serversDir "steamhome"
$steamcmdSh  = Join-Path $steamcmdDir "steamcmd.sh"
$genProfile  = Join-Path $WorkRoot "genprofile"     # EMPTY profile so mods write fresh settings
$steamcmdUrl = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
# steamcmd ignores XDG_DATA_HOME and stores its install + login cache under $HOME/Steam
# (NOT $HOME/.local/share/Steam) — the login token lives in config.vdf here. update.sh uses
# the same $HOME, so a login cached here is the one the download step reuses.
$loginVdf    = Join-Path $steamHome "Steam/config/config.vdf"

# ---- console + log helpers (match the house scripts' tagged output) ------------------
function Show-Info ($m) { Write-Host "  $m" }
function Show-Step ($m) { Write-Host "`n== $m" -ForegroundColor Cyan }
function Show-Warn ($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Show-Ok   ($m) { Write-Host "  + $m" -ForegroundColor Green }
function Show-Miss ($m) { Write-Host "  - $m" -ForegroundColor DarkYellow }

$script:log = @()
function Add-Log ($phase, $item, $status, $detail) {
    $script:log += [PSCustomObject]@{
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        Phase = $phase; Item = $item; Status = $status; Detail = $detail
    }
}
# A cached steamcmd login means config.vdf exists AND carries the account name (a FAILED
# login leaves config.vdf but no account token, so file-existence alone is a false positive).
# -SkipLoginCheck forces true for steamcmd builds whose vdf doesn't store the name plaintext.
function Test-SteamLogin {
    if ($SkipLoginCheck) { return $true }
    if (-not (Test-Path $loginVdf)) { return $false }
    if (-not $SteamAccount) { return $true }   # account unknown (dry run): can't verify, assume present
    return [bool](Select-String -Path $loginVdf -Pattern $SteamAccount -SimpleMatch -Quiet)
}

function Save-Log {
    if ($NoLog) { return }
    $logDir = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $logPath = Join-Path $logDir "generate-config-defaults.csv"
    foreach ($row in $script:log) { Write-CsvLog -Path $logPath -Row $row }
    Write-Host "`nLog: $logPath" -ForegroundColor DarkGray
}

# ---- the 9 defaults, data-driven -----------------------------------------------------
# Rel = server-relative path of the LIVE file. Src = where the pristine copy comes from:
#   mission-static : copied from the clean download (no boot).
#   mission-gen    : written by a mod INTO the mission on boot (harvested from the boot mission).
#   profile-gen    : written by a mod INTO the empty profile on boot.
$targets = @(
    @{ Rel = "mpmissions/dayzOffline.chernarusplus/db/globals.xml"; Src = "mission-static" }
    @{ Rel = "mpmissions/dayzOffline.enoch/db/globals.xml";         Src = "mission-static" }
    @{ Rel = "mpmissions/dayzOffline.sakhal/db/globals.xml";        Src = "mission-static" }
    @{ Rel = "mpmissions/dayzOffline.sakhal/expansion/settings/SpawnSettings.json";    Src = "mission-gen" }
    @{ Rel = "mpmissions/dayzOffline.sakhal/expansion/settings/MapSettings.json";      Src = "mission-gen" }
    @{ Rel = "mpmissions/dayzOffline.sakhal/expansion/settings/AIPatrolSettings.json"; Src = "mission-gen" }
    @{ Rel = "profiles/ExpansionMod/Settings/SocialMediaSettings.json";                Src = "profile-gen" }
    @{ Rel = "profiles/AIB_Unleashed/AIB_UL_Config.json";                              Src = "profile-gen" }
    @{ Rel = "profiles/KnockKnockAIBandits/KnockKnockAIBandits_Settings.json";         Src = "profile-gen" }
)

# The default filename is the live name with ".defaults" before the extension.
function Get-DefaultRel ([string]$rel) {
    $dir  = [IO.Path]::GetDirectoryName($rel) -replace '\\','/'
    $base = [IO.Path]::GetFileNameWithoutExtension($rel)
    $ext  = [IO.Path]::GetExtension($rel)
    if ($dir) { "$dir/$base.defaults$ext" } else { "$base.defaults$ext" }
}

# ---- shared helpers (borrowed shape from Sync-ConfigDefaults.ps1) ---------------------
function Remove-Bom ([string]$t) { if ($t) { $t.TrimStart([char]0xFEFF) } else { $t } }
function Test-Parses ([string]$t, [string]$ext) {
    if (-not $t -or -not $t.Trim()) { return $false }
    switch ($ext) {
        '.json' { try { $null = $t | ConvertFrom-Json; $true } catch { $false } }
        '.xml'  { try { $null = [xml]$t; $true } catch { $false } }
        default { $true }
    }
}

# Resolve where a generated target's pristine copy lives after the boot.
function Resolve-GenSource ($t, $profileRoot, $missionDir) {
    if ($t.Src -eq 'profile-gen') {
        # Rel is 'profiles/<...>' — the profile root IS the -profiles dir, so strip 'profiles/'.
        return (Join-Path $profileRoot ($t.Rel -replace '^profiles/',''))
    }
    # mission-gen: Rel is 'mpmissions/<mission>/expansion/...' — map onto the boot mission dir.
    return (Join-Path $missionDir ($t.Rel -replace '^mpmissions/[^/]+/',''))
}

# Validate + copy one captured file into the candidate dir under its .defaults name.
function Save-Capture ($t, [string]$srcPath) {
    $defRel = Get-DefaultRel $t.Rel
    $dst    = Join-Path $CandidateDir $defRel
    $ext    = [IO.Path]::GetExtension($t.Rel)
    if (-not (Test-Path $srcPath)) { Show-Miss "$($t.Rel) : not produced ($($t.Src))"; Add-Log 'harvest' $t.Rel 'missing' $srcPath; return }
    $txt = Remove-Bom (Get-Content $srcPath -Raw)
    if (-not (Test-Parses $txt $ext)) { Show-Warn "$($t.Rel) : produced but does not parse as $ext — skipped"; Add-Log 'harvest' $t.Rel 'unparsable' $srcPath; return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Set-Content -Path $dst -Value $txt -NoNewline
    Show-Ok "$($t.Rel) -> $defRel"
    Add-Log 'harvest' $t.Rel 'captured' $dst
}

# Flatten a JSON object to leaf dotted paths -> stringified value (arrays indexed [n]).
function Get-JsonLeaves ($node, [string]$prefix, $acc) {
    if ($null -eq $acc) { $acc = [ordered]@{} }
    if ($node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $node.PSObject.Properties) { Get-JsonLeaves $p.Value ("$prefix.$($p.Name)".TrimStart('.')) $acc | Out-Null }
    } elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
        $i = 0; foreach ($v in $node) { Get-JsonLeaves $v "$prefix[$i]" $acc | Out-Null; $i++ }
    } else {
        $acc[$prefix] = "$node"
    }
    return $acc
}
# Field-level diff of two config texts. Returns "path : base -> cand" lines. Handles the two
# kinds present: JSON (leaf paths) and globals-style XML (compare <var name=".." value=".."/>).
function Compare-Configs ([string]$baseTxt, [string]$candTxt, [string]$ext) {
    $out = @()
    if ($ext -eq '.json') {
        $b = Get-JsonLeaves ($baseTxt | ConvertFrom-Json) '' $null
        $c = Get-JsonLeaves ($candTxt | ConvertFrom-Json) '' $null
        foreach ($k in ($b.Keys + $c.Keys | Select-Object -Unique | Sort-Object)) {
            $bv = if ($b.Contains($k)) { $b[$k] } else { '<absent>' }
            $cv = if ($c.Contains($k)) { $c[$k] } else { '<absent>' }
            if ($bv -ne $cv) { $out += "$k : $bv -> $cv" }
        }
    } elseif ($ext -eq '.xml') {
        $bx = [xml]$baseTxt; $cx = [xml]$candTxt
        $bm = @{}; foreach ($v in $bx.SelectNodes('//*[@name][@value]')) { $bm[$v.name] = $v.value }
        $cm = @{}; foreach ($v in $cx.SelectNodes('//*[@name][@value]')) { $cm[$v.name] = $v.value }
        foreach ($k in ($bm.Keys + $cm.Keys | Select-Object -Unique | Sort-Object)) {
            $bv = if ($bm.ContainsKey($k)) { $bm[$k] } else { '<absent>' }
            $cv = if ($cm.ContainsKey($k)) { $cm[$k] } else { '<absent>' }
            if ($bv -ne $cv) { $out += "$k : $bv -> $cv" }
        }
    }
    return $out
}

# The set of server-relative file paths config-overrides.json patches (common -> '<mission>').
function Get-OverrideFileKeys {
    if (-not (Test-Path $overrides)) { return @{} }
    $doc = Get-Content $overrides -Raw | ConvertFrom-Json
    $keys = @{}
    if ($doc.files) { foreach ($p in $doc.files.PSObject.Properties.Name) { if (-not $p.StartsWith('_')) { $keys[$p] = 'files' } } }
    if ($doc.mpmissions) {
        foreach ($layer in $doc.mpmissions.PSObject.Properties.Name) {
            if ($layer.StartsWith('_')) { continue }
            foreach ($f in $doc.mpmissions.$layer.PSObject.Properties.Name) {
                if ($f.StartsWith('_')) { continue }
                $rel = if ($layer -eq 'common') { "mpmissions/<mission>/$f" } else { "mpmissions/$layer/$f" }
                $keys[$rel] = $layer
            }
        }
    }
    return $keys
}

# Reconcile: candidate (legit default) vs current baseline vs overrides. Surfaces fields
# that DIFFER from the legit default but have NO override — the values silently baked into
# the old baseline (the hidden edits that made config-defaults/ confusing).
function Invoke-Reconcile {
    Show-Step "Reconcile: candidate (legit default) vs current baseline vs overrides"
    if (-not (Test-Path $CandidateDir)) { Show-Warn "no candidate dir yet ($CandidateDir) — run with -Run first"; return }
    $ovrKeys = Get-OverrideFileKeys
    foreach ($t in $targets) {
        $rel      = $t.Rel
        $defRel   = Get-DefaultRel $rel
        $candPath = Join-Path $CandidateDir $defRel
        $basePath = Join-Path $baselineDir  $defRel
        $ext      = [IO.Path]::GetExtension($rel)
        if (-not (Test-Path $candPath)) { Show-Miss "$rel : not captured (candidate missing)"; Add-Log 'reconcile' $rel 'missing-candidate' $candPath; continue }

        $missionRel = $rel -replace '^mpmissions/[^/]+/', 'mpmissions/<mission>/'
        $patched = $ovrKeys.ContainsKey($rel) -or $ovrKeys.ContainsKey($missionRel)

        if (-not (Test-Path $basePath)) {
            Show-Ok "$rel : NEW legit default (no current baseline)"
            Add-Log 'reconcile' $rel 'new-default' "patched=$patched"; continue
        }
        $candTxt = Remove-Bom (Get-Content $candPath -Raw)
        $baseTxt = Remove-Bom (Get-Content $basePath -Raw)
        $same = $candTxt.Trim() -eq $baseTxt.Trim()
        if ($ext -eq '.json') {
            try { $same = ((ConvertTo-Json ($candTxt|ConvertFrom-Json) -Depth 40) -eq (ConvertTo-Json ($baseTxt|ConvertFrom-Json) -Depth 40)) } catch {}
        }
        if ($same) {
            Show-Info "$rel : baseline already matches legit default. ok"
            Add-Log 'reconcile' $rel 'match' "patched=$patched"
        } else {
            $note = if ($patched) { "file HAS overrides" } else { "NO override on this file — baked-in hidden edit" }
            Show-Warn "$rel : legit default differs from baseline ($note)"
            $diffs = @(Compare-Configs $baseTxt $candTxt $ext)
            $show  = $diffs | Select-Object -First 12
            foreach ($d in $show) { Write-Host "      $d" -ForegroundColor DarkGray }
            if ($diffs.Count -gt $show.Count) { Write-Host "      … +$($diffs.Count - $show.Count) more field(s)" -ForegroundColor DarkGray }
            Add-Log 'reconcile' $rel 'differs' "patched=$patched; fields=$($diffs.Count)"
        }
    }
    Write-Host "`n  Each line reads  field : old-baseline -> legit-default." -ForegroundColor DarkGray
    Write-Host "  For a field you DIDN'T override, old-baseline was hiding that value; decide per field:" -ForegroundColor DarkGray
    Write-Host "  promote it to a real override (keep today's behavior, now visible), or adopt the legit default (reset)." -ForegroundColor DarkGray
}

# Adopt: copy each captured candidate over its config-defaults/ baseline. WRITE action, -Adopt only.
# git is the backup (config-defaults/ is versioned). Report-only when $Apply is false.
function Invoke-Adopt ([bool]$Apply) {
    Show-Step ($(if ($Apply) { "Adopt: promoting candidates into config-defaults/ (WRITING)" }
                else         { "Adopt (report-only): candidates that WOULD replace config-defaults/" }))
    if (-not (Test-Path $CandidateDir)) { Show-Warn "no candidate dir ($CandidateDir) — run with -Run first"; return }
    $copied = 0; $missing = 0
    foreach ($t in $targets) {
        $defRel   = Get-DefaultRel $t.Rel
        $candPath = Join-Path $CandidateDir $defRel
        $basePath = Join-Path $baselineDir  $defRel
        if (-not (Test-Path $candPath)) { Show-Miss "$($t.Rel) : no candidate — skipped"; Add-Log 'adopt' $t.Rel 'skip-no-candidate' $candPath; $missing++; continue }
        if ($Apply) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $basePath) | Out-Null
            Copy-Item $candPath $basePath -Force
            Show-Ok "$defRel"
            Add-Log 'adopt' $t.Rel 'copied' $defRel
        } else {
            Show-Info "would replace  $defRel"
            Add-Log 'adopt' $t.Rel 'would-copy' $defRel
        }
        $copied++
    }
    if ($Apply) { Show-Ok "adopted $copied file(s) into config-defaults/ ($missing skipped). config-overrides.json unchanged." }
    else        { Write-Host "`n  $copied file(s) would be promoted ($missing skipped). Re-run with -Adopt to write. config-overrides.json is NOT touched." -ForegroundColor Cyan }
}

# ===================== parse the mod registry (one source of truth) ====================
if (-not (Test-Path $modsConf)) { Write-Error "mods.conf not found at $modsConf"; exit 1 }
# Same derivation Deploy-DayZServer.ps1 uses: first token of every non-# line, in file order.
$enabledMods = @(Get-Content $modsConf | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') } |
    ForEach-Object { ($_ -split '\s+')[0] })
$modLine = $enabledMods -join ';'

if (-not $SteamAccount) {
    $hostEnv = Join-Path $deployDir "host.env"
    if (Test-Path $hostEnv) {
        $m = Select-String -Path $hostEnv -Pattern '^\s*DEPLOY_STEAM_ACCOUNT\s*=\s*(.+?)\s*$' | Select-Object -First 1
        if ($m) { $SteamAccount = $m.Matches[0].Groups[1].Value }
    }
}

$haveSteamcmd = Test-Path $steamcmdSh
$haveLogin    = Test-SteamLogin

# ===================== plan / dry-run =================================================
Show-Step "Plan"
Show-Info "Work root      : $WorkRoot   (server + steamcmd + steamhome; ~15GB)"
Show-Info "Candidate out  : $CandidateDir   (config-defaults/ is NEVER touched)"
Show-Info "Boot mission   : $Mission   (empty profile: $genProfile)"
Show-Info "Steam account  : $(if ($SteamAccount) { $SteamAccount } else { '<unset — pass -SteamAccount or set DEPLOY_STEAM_ACCOUNT in deploy/host.env>' })"
Show-Info "Mod chain      : $($enabledMods.Count) mods from deploy/mods.conf"
Write-Host "                 $modLine" -ForegroundColor DarkGray
Show-Info "Will capture   : $($targets.Count) files ->"
foreach ($t in $targets) { Write-Host ("                   [{0,-13}] {1}" -f $t.Src, $t.Rel) -ForegroundColor DarkGray }
Show-Info "steamcmd       : $(if ($haveSteamcmd) { "present ($steamcmdSh)" } else { 'not bootstrapped yet' })"
Show-Info "steam login    : $(if ($haveLogin) { 'cached session found' } else { 'no cached session — interactive login needed' })"

if ($Adopt) {
    Invoke-Reconcile
    Invoke-Adopt $true
    Save-Log
    return
}
if ($Reconcile) {
    Invoke-Reconcile
    Invoke-Adopt $false   # show what -Adopt would promote, without writing
    Save-Log
    return
}
if (-not $Run) {
    Invoke-Reconcile
    Write-Host "`nREPORT ONLY — nothing downloaded or booted. Re-run with -Run to generate." -ForegroundColor Cyan
    Save-Log
    return
}

# ===================== the heavy path (-Run) =========================================
if (-not $SteamAccount) { Write-Error "No Steam account. Pass -SteamAccount <name> (must own DayZ) or set DEPLOY_STEAM_ACCOUNT in deploy/host.env."; exit 1 }
New-Item -ItemType Directory -Force -Path $serversDir, $serverDir, $steamcmdDir, $steamHome, $genProfile | Out-Null

# -- Phase 1: bootstrap steamcmd from Valve's tarball (registry-free, no sudo, no Docker) --
Show-Step "1/5 steamcmd"
if (-not (Test-Path $steamcmdSh)) {
    $tgz = Join-Path $steamcmdDir "steamcmd_linux.tar.gz"
    Show-Info "fetching $steamcmdUrl"
    Invoke-WebRequest -Uri $steamcmdUrl -OutFile $tgz
    & tar -xzf $tgz -C $steamcmdDir
    Add-Log 'steamcmd' 'bootstrap' 'ok' $steamcmdDir
    Show-Ok "steamcmd bootstrapped"
} else { Show-Info "steamcmd already present" }

# -- Phase 2: require an interactive login (Steam Guard cannot be automated) --
Show-Step "2/5 steam login"
if (-not $haveLogin) {
    Show-Warn "No cached Steam session. Run this ONE-TIME interactive login (password + Steam Guard), then re-run with -Run:"
    Write-Host "`n    HOME='$steamHome' XDG_DATA_HOME='$steamHome/.local/share' '$steamcmdSh' +login $SteamAccount +quit`n" -ForegroundColor White
    Add-Log 'login' $SteamAccount 'needed' 'interactive'
    Save-Log
    exit 2
}
Show-Info "cached session present"

# -- Phase 3: download server + mods by REUSING deploy/update.sh verbatim --
# update.sh self-locates to <serversDir>/{dayz-server,steamcmd,steamhome} and reads mods.conf
# beside it. We stage both, render its one placeholder, and run it — the same download +
# lowercase + bikey sync prod gets, no reimplementation.
Show-Step "3/5 download server + mods (this is the ~15GB step)"
Copy-Item $modsConf (Join-Path $serverDir "mods.conf") -Force
(Get-Content $updateSh -Raw).Replace('{{DEPLOY_STEAM_ACCOUNT}}', $SteamAccount) |
    Set-Content (Join-Path $serverDir "update.sh") -NoNewline
& chmod +x (Join-Path $serverDir "update.sh")
New-Item -ItemType Directory -Force -Path (Join-Path $serverDir "keys") | Out-Null
& bash (Join-Path $serverDir "update.sh")
if ($LASTEXITCODE -ne 0) { Show-Warn "update.sh exit $LASTEXITCODE — continuing; per-file harvest verifies presence" }
Add-Log 'download' 'update.sh' "exit$LASTEXITCODE" $serverDir

# -- Phase 3b: harvest the STATIC vanilla globals right after download (no boot needed) --
New-Item -ItemType Directory -Force -Path $CandidateDir | Out-Null
foreach ($t in ($targets | Where-Object { $_.Src -eq 'mission-static' })) {
    Save-Capture $t (Join-Path $serverDir $t.Rel)
}

# -- Phase 4: one boot of the mission with an EMPTY profile; poll for generated files --
Show-Step "4/5 boot $Mission once to generate mod settings"
$missionDir = Join-Path $serverDir "mpmissions/$Mission"
if (-not (Test-Path (Join-Path $serverDir "DayZServer"))) { Write-Error "DayZServer binary missing after download — cannot boot."; exit 1 }
if (-not (Test-Path $missionDir)) {
    Show-Warn "mission $Mission not in download — skipping boot; sakhal + profile files can't be generated"
} else {
    # Minimal throwaway cfg — NEVER the deployed serverDZ.cfg (that carries live passwords).
    # Two keys are load-bearing here:
    #   1. `instanceId` is MANDATORY. Without it the engine aborts config validation with
    #      "[ERROR][Server config] :: instanceId parameter is mandatory ..." and self-terminates
    #      on a 10s countdown ("[Server] :: termination in: 10" -> "Server creation failed") BEFORE
    #      mission OnInit — so no mod writes its settings and the profile comes out empty.
    #   2. The `class Missions { class DayZ { template=... } }` block is what actually starts the
    #      mission (prod's serverDZ.cfg has it; -mission= alone loads the world but leaves no
    #      mission to run). Note the `class` keyword: a bare `Missions { }` fails cfg parse with
    #      "'{' encountered instead of '='".
    $cfg = Join-Path $serverDir "serverDZ.defaultgen.cfg"
    @"
hostname="defaultgen";
instanceId=1;
maxPlayers=1;
verifySignatures=0;
class Missions
{
    class DayZ
    {
        template="$Mission";
    };
};
"@ | Set-Content $cfg
    # Same launch shape as the unit's ExecStart, minus BE, on a throwaway port + empty profile.
    # No -freezecheck: it's a watchdog that can kill a slow first-load boot (27 mods) on a
    # busy dev box, and a generation boot has no players to protect.
    $bootArgs = @(
        "-config=$(Split-Path -Leaf $cfg)", "-mission=mpmissions/$Mission", "-port=2401",
        "-mod=$modLine", "-profiles=$genProfile", "-dologs", "-adminlog"
    )
    Show-Info "launching (port 2401, profile $genProfile)…"
    $proc = Start-Process -FilePath (Join-Path $serverDir "DayZServer") -ArgumentList $bootArgs `
        -WorkingDirectory $serverDir -PassThru `
        -RedirectStandardOutput (Join-Path $WorkRoot "boot.out.log") `
        -RedirectStandardError  (Join-Path $WorkRoot "boot.err.log")
    # Poll for the generated files; stop as soon as all appear or we time out.
    $wantGen = @($targets | Where-Object { $_.Src -in 'profile-gen','mission-gen' })
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    $present = 0
    do {
        Start-Sleep -Seconds 5
        $present = @($wantGen | Where-Object { Test-Path (Resolve-GenSource $_ $genProfile $missionDir) }).Count
        Show-Info "generated $present/$($wantGen.Count) so far…"
    } while ($present -lt $wantGen.Count -and (Get-Date) -lt $deadline)
    # Stop the throwaway server (SIGINT for a clean-ish exit, then force if needed).
    try { & kill -INT $proc.Id 2>$null; $null = $proc.WaitForExit(20000) } catch {}
    if (-not $proc.HasExited) { try { $proc.Kill() } catch {} }
    Add-Log 'boot' $Mission "gen$present/$($wantGen.Count)" "timeout=${BootTimeoutSeconds}s"

    foreach ($t in $wantGen) { Save-Capture $t (Resolve-GenSource $t $genProfile $missionDir) }
}

# -- Phase 5: reconcile the fresh candidate against the current baseline --
Show-Step "5/5 reconcile"
Invoke-Reconcile
Save-Log
