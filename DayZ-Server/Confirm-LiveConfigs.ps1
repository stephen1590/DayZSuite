#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Validate the LIVE server's config state against spec — the dev side of the pull-only
    config model ("box builds, dev validates"). Read-only by nature; never writes anything.
.DESCRIPTION
    The box owns config content end-to-end (web editor writes, prestart builds). What dev
    keeps is the duty to PROVE the result is sound. Checks, in order:

      LOCAL (repo mirrors/seeds parse - a corrupt mirror is a corrupt backup):
        2. deploy/profiles/AI_Shared/map-points.json parses + has a `points` array
        3. every JSON seed in the deploy payload parses; messages.xml parses as XML
      LIVE (over ssh, all read-only):
        4. dayz-server unit is active
        5. the zero-MISS override report is RETIRED: the applier is deleted, so there is no
           apply step left that can silently miss a change. Not yet replaced by a two-copy
           equivalent for the live box; this script reports that gap rather than asserting
           nothing.
        6. COMPOSED ARTIFACTS: the files prestart's builders generate for the active
           mission parse (transfer_spawn.json) — proof the box-side
           build chain produced valid output. (DynamicAIB/StaticAIB dropped: BanditAI retired.)

    Run it after a deploy, after a restart that applied web edits, or ad-hoc. Exits 0 when
    every check passes, 1 otherwise (CI-friendly). CSV log in logs/ unless -NoLog.
.EXAMPLE
    ./Confirm-LiveConfigs.ps1             # full local + live validation on STAGING (default env)
.EXAMPLE
    ./Confirm-LiveConfigs.ps1 -Env prod   # same, against the prod box
.EXAMPLE
    ./Confirm-LiveConfigs.ps1 -LocalOnly  # just the repo mirrors/seeds (no ssh)
#>
[CmdletBinding()]
param(
    [ValidateSet('staging','prod')]
    [string]$Env = 'staging',   # same selector as Deploy-DayZServer: bare = staging, prod explicit
    [string]$RemoteHost,
    [string]$RemoteUser = "ubuntu",
    [string]$RemotePath = "/home/ubuntu/servers/dayz-server",
    [switch]$LocalOnly,
    [switch]$NoLog
)

. (Join-Path $PSScriptRoot "_DZSync.ps1")
. (Join-Path $PSScriptRoot "../../../common/Utils.ps1")

$script:pass = 0; $script:fail = 0
function Show-Pass([string]$msg) { $script:pass++; Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Show-Fail([string]$msg) { $script:fail++; Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Show-Warn([string]$msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }

function Test-ParseFile([string]$path, [string]$kind, [string]$label) {
    if (-not (Test-Path -LiteralPath $path)) { Show-Fail "$label - file missing ($path)"; return $null }
    try {
        $raw = Get-Content -Raw -LiteralPath $path
        $doc = switch ($kind) { 'json' { $raw | ConvertFrom-Json } 'xml' { [xml]$raw } default { $raw } }
        Show-Pass "$label parses"
        return $doc
    } catch { Show-Fail "$label - not valid $kind`: $($_.Exception.Message)"; return $null }
}

# --- LOCAL: every repo seed/mirror the registry declares (single source: config-registry.json).
# Check each surface that has both a repo copy (a 'seed') and a parse kind ('check'). A corrupt
# seed is a corrupt fresh-box restore, so this is the local half of "prove the config is sound".
Write-Host "Local seeds + mirrors (from config-registry.json)" -ForegroundColor Cyan
$registryPath = Join-Path $PSScriptRoot "config-registry.json"
if (-not (Test-Path $registryPath)) {
    Show-Fail "config-registry.json missing - cannot validate config surfaces"
} else {
    $surfaces = @((Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json).surfaces)
    foreach ($s in ($surfaces | Where-Object { $_.seed -and $_.check -and $_.check -ne 'none' })) {
        $doc = Test-ParseFile (Join-Path $PSScriptRoot $s.seed) $s.check "$($s.name) [$($s.scope)]"
        # The definitive spawn store must be shaped like one (a points array).
        if ($doc -and $s.mirror -eq 'spawns') {
            if ($null -ne $doc.PSObject.Properties['points']) { Show-Pass "$($s.name) has a points array ($(@($doc.points).Count) points)" }
            else { Show-Fail "$($s.name) lacks a 'points' array" }
        }
    }
}

# --- LIVE: what the box actually built ------------------------------------------------------
if (-not $LocalOnly) {
    Resolve-DZDeployerEnv -ScriptRoot $PSScriptRoot -RemoteHost ([ref]$RemoteHost) -RemoteUser ([ref]$RemoteUser) -BoundParameters $PSBoundParameters -Env $Env
    Assert-DZHost @{ RemoteHost = $RemoteHost; RemoteUser = $RemoteUser; RemotePath = $RemotePath }
    $target = "${RemoteUser}@${RemoteHost}"

    Write-Host "`nLive box (env: $Env -> $target)" -ForegroundColor Cyan
    $unit = (Get-Stdout { ssh -o ConnectTimeout=10 $target "systemctl is-active dayz-server" } | Out-String).Trim()
    if ($unit -eq 'active') { Show-Pass "dayz-server unit is active" }
    else { Show-Fail "dayz-server unit is '$unit' (expected active)" }

    # The applier is deleted - config files are owned whole, so there is no apply step that
    # can miss. The equivalent live check for the two-copy model would be: every OWNED
    # surface declared in the registry exists on the box and parses - not yet built.
    # Asserting nothing here is honest; asserting the old thing would be a green light on a
    # mechanism that no longer runs.
    Show-Warn "live config verification is NOT implemented for the two-copy model (T4). This run checked the unit only."

    # COMPOSED ARTIFACTS: prestart's builders write these for the ACTIVE mission; each must
    # be valid JSON or the mod reading it starts blind. map.env names the active mission.
    $mission = ((Get-Stdout { ssh -o ConnectTimeout=10 $target "cat '$RemotePath/map.env'" } | Out-String) -split "`n" |
        Where-Object { $_ -match '^DAYZ_MISSION=(.+)$' } | ForEach-Object { $Matches[1].Trim() } | Select-Object -First 1)
    if ($mission) { Show-Pass "active mission: $mission" } else { Show-Fail "could not read map.env for the active mission" }

    # Only artifacts a prestart builder still composes: the bandit and Bubaku compilers are
    # retired with their mods, so a fresh box would never create theirs and this would hard-fail.
    foreach ($rel in @(
        "profiles/transfer_spawn.json"
    )) {
        $raw = Get-Stdout { ssh -o ConnectTimeout=10 $target "cat '$RemotePath/$rel'" } | Out-String
        if (-not $raw.Trim()) { Show-Fail "$rel - missing or empty on the box"; continue }
        try { $null = $raw | ConvertFrom-Json; Show-Pass "$rel (composed artifact) parses" }
        catch { Show-Fail "$rel - not valid JSON: $($_.Exception.Message)" }
    }
}

# --- Summary --------------------------------------------------------------------------------
$color = if ($fail) { 'Red' } else { 'Green' }
Write-Host ("`nLive-config validation: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $color

if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir "testliveconfigs.csv") -Row ([PSCustomObject]@{
        Timestamp = Get-Date -Format "s"; Passed = $pass; Failed = $fail; LocalOnly = [bool]$LocalOnly
    })
}

if ($fail) { exit 1 }
exit 0
