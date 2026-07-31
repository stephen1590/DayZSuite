#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Seed the STAGING box's config from PROD's LIVE state - the required starting point for any
    staging test (STAGING-PLAN.md). One-way and enforced: prod is read-only, only staging is
    written. It can never write prod or the repo mirror.
.DESCRIPTION
    Staging seeds config only when MISSING, and the pull family is prod-pinned, so nothing ever
    carries prod's live config onto staging - a staging test would run against a frozen seed, not
    prod. This copies prod's box-owned config SOURCES onto staging, then restarts staging so its
    prestart rebuilds every live file from them. After it runs, staging == prod for config.

    Registry-driven - the fifth consumer of config-registry.json (the one contract). The source
    set is exactly the rows that carry box-owned live state:
      spawns       profiles/AI_Shared/map-points.json      (the spawn-point store)
      live FILE    the web-edited expansion_types_tuning pair
      live FOLDER  the LIVE mission config (mpmissions/<map>/{db,env,expansion/settings}/*.json)
    *.defaults.* and registry-'generated' artifacts are excluded (defaults are frozen; artifacts
    are rebuilt at prestart). Each file must PARSE (its registry 'check') before it may land on
    staging, so a half-written prod file can never corrupt the staging box.

    Report-only by default. -Fix copies, writes a .prod-sync marker on staging (timestamp + prod's
    config-overrides sha, so the staging deploy can require a fresh sync), and restarts staging so
    the mission rebuilds from the synced config. -NoRestart skips the restart (applies next boot).
.EXAMPLE
    ./Sync-StagingFromProd.ps1            # dry-run: what would be copied prod -> staging
.EXAMPLE
    ./Sync-StagingFromProd.ps1 -Fix       # copy, mark, and restart staging
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$NoRestart,
    [string]$ProdHost,
    [string]$StagingHost,
    [string]$RemoteUser = 'ubuntu',
    [string]$RemotePath = '/home/ubuntu/servers/dayz-server',
    [switch]$NoLog
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../common/Utils.ps1')   # Get-Stdout, Write-CsvLog

function Get-DeployerHost([string]$envName) {
    $f = Join-Path $PSScriptRoot "deployer.$envName.env"
    if (-not (Test-Path $f) -and $envName -eq 'prod') { $f = Join-Path $PSScriptRoot 'deployer.env' }   # legacy prod name
    $h = $null; $u = 'ubuntu'
    if (Test-Path $f) {
        foreach ($l in Get-Content $f) {
            if ($l -match '^\s*DEPLOY_REMOTE_HOST\s*=\s*(.+?)\s*$') { $h = $Matches[1] }
            if ($l -match '^\s*DEPLOY_REMOTE_USER\s*=\s*(.+?)\s*$') { $u = $Matches[1] }
        }
    }
    [pscustomobject]@{ Host = $h; User = $u }
}
function Show-Ok($m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Show-Skip($m) { Write-Host "[SKIP] $m" -ForegroundColor Yellow }
function Log($action, $detail) {
    if ($NoLog -or -not (Get-Command Write-CsvLog -ErrorAction SilentlyContinue)) { return }
    $logDir = Join-Path $PSScriptRoot 'logs'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir 'sync-staging.csv') -Row ([pscustomobject]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Action = $action; Detail = $detail })
}

# --- resolve hosts: PROD = source (read-only), STAGING = dest (write) ----------------------
$prod = Get-DeployerHost 'prod'; $stg = Get-DeployerHost 'staging'
if ($ProdHost)    { $prod.Host = $ProdHost }
if ($StagingHost) { $stg.Host  = $StagingHost }
if (-not $prod.Host) { Write-Error 'prod host not resolved (deployer.prod.env DEPLOY_REMOTE_HOST or -ProdHost)'; exit 1 }
if (-not $stg.Host)  { Write-Error 'staging host not resolved (deployer.staging.env DEPLOY_REMOTE_HOST or -StagingHost)'; exit 1 }
# SAFETY: never, ever write prod. The destination must not be the prod host.
if ($stg.Host -eq $prod.Host) { Write-Error "REFUSING: staging host ($($stg.Host)) equals the prod host. This tool only writes staging."; exit 1 }
$prodT = "$($prod.User)@$($prod.Host)"; $stgT = "$($stg.User)@$($stg.Host)"
$cm = @('-o','ControlMaster=auto','-o','ControlPath=/tmp/sync-cm-%C','-o','ControlPersist=60','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=accept-new')
Write-Host "`nSOURCE (read-only): $prodT`:$RemotePath" -ForegroundColor Cyan
Write-Host "DEST   (write)    : $stgT`:$RemotePath   [$(if ($Fix) { 'APPLY' } else { 'report-only - re-run with -Fix' })]`n" -ForegroundColor Cyan

# --- build the source set from the registry ------------------------------------------------
$reg = Get-Content -Raw (Join-Path $PSScriptRoot 'config-registry.json') | ConvertFrom-Json
$genRe = @(@($reg.generated) | ForEach-Object { '^' + ([regex]::Escape("$_") -replace '\\\*','.*') + '$' })
$items = [System.Collections.Generic.List[object]]::new()
function Add-Item($rel, $check) { $items.Add([pscustomobject]@{ rel = $rel; check = $check }) }

# overrides document + spawns store + live FILE rows (fixed box paths)
foreach ($r in $reg.surfaces | Where-Object { $_.name -eq 'overrides' -or $_.mirror -eq 'spawns' -or ($_.mirror -eq 'live' -and $_.box) }) {
    if ($r.box) { Add-Item $r.box ([string]$r.check) }
}
# live FOLDER rows: enumerate prod's actual files (exclude *.defaults.* and generated artifacts)
foreach ($r in $reg.surfaces | Where-Object { $_.mirror -eq 'live' -and $_.dir }) {
    $glob = if ($r.mirrorGlob) { [string]$r.mirrorGlob } else { '*.json' }
    foreach ($sub in @($r.subfolders)) {
        $relDir = "$($r.dir)/$sub"
        $find = "cd '$RemotePath/$relDir' 2>/dev/null && ls -1 $glob 2>/dev/null"
        $names = @((Get-Stdout { ssh @cm $prodT $find } | Out-String) -split "`n" |
                   ForEach-Object { $_.Trim() } |
                   Where-Object { $_ -and $_ -notmatch '/|\.\.' -and $_ -notmatch '\.defaults\.' } |
                   Where-Object { $n = $_; -not ($genRe | Where-Object { $n -match $_ -or "$relDir/$n" -match $_ }) })
        foreach ($n in $names) { Add-Item "$relDir/$n" 'json' }
    }
}

# --- copy loop: hash-compare, parse-validate, byte-exact scp prod -> staging ----------------
$copied = 0; $same = 0; $bad = 0; $missing = 0
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('sync-staging-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
try {
    foreach ($it in $items) {
        $rel = $it.rel
        $pSha = (Get-Stdout { ssh @cm $prodT "sha256sum '$RemotePath/$rel' 2>/dev/null | cut -c1-64" } | Out-String).Trim()
        if (-not $pSha) { Show-Skip "$rel - not on prod (skipped)"; $missing++; continue }
        $sSha = (Get-Stdout { ssh @cm $stgT "sha256sum '$RemotePath/$rel' 2>/dev/null | cut -c1-64" } | Out-String).Trim()
        if ($pSha -eq $sSha) { $same++; continue }
        $local = Join-Path $tmpDir ($rel -replace '[\\/]', '__')
        & scp @cm -q "${prodT}:$RemotePath/$rel" $local 2>$null
        if (-not (Test-Path $local)) { Show-Skip "$rel - could not read from prod"; $bad++; continue }
        $raw = Get-Content -Raw -LiteralPath $local
        $ok = switch ([string]$it.check) {
            'json'  { try { $null = $raw | ConvertFrom-Json; $true } catch { $false } }
            'xml'   { try { $null = [xml]$raw; $true } catch { $false } }
            default { $true }
        }
        if (-not $ok) { Show-Skip "$rel - prod copy does not parse as $($it.check) (staging left unchanged)"; $bad++; continue }
        $copied++
        Write-Host ('  {0,-7} {1}' -f $(if ($sSha) { 'UPDATE' } else { 'NEW' }), $rel)
        if ($Fix) {
            if ($rel -match '/') {
                $dir = $rel -replace '/[^/]+$', ''
                ssh @cm $stgT "mkdir -p '$RemotePath/$dir'" | Out-Null
            }
            & scp @cm -q $local "${stgT}:$RemotePath/$rel"
        }
    }
} finally { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue }

Write-Host ("`n{0} to copy, {1} in sync, {2} not on prod, {3} rejected{4}" -f $copied, $same, $missing, $bad, $(if (-not $Fix) { ' (dry-run)' } else { '' }))
if ($bad) { Write-Warning "$bad file(s) failed to parse/read - staging left unchanged for those." }

if (-not $Fix) {
    Write-Host "`nReport only. Re-run with -Fix to copy + mark + restart staging." -ForegroundColor Cyan
    exit 0
}

# --- marker (lets the staging deploy require a fresh sync) + restart ------------------------
$stamp  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$marker = "synced_at=$stamp`nprod_host=$($prod.Host)`nfiles_copied=$copied`n"
$marker | ssh @cm $stgT "cat > '$RemotePath/.prod-sync'"
Show-Ok "wrote staging marker $RemotePath/.prod-sync (synced_at=$stamp)"
Log 'sync' "copied=$copied same=$same prod=$($prod.Host)"

if ($NoRestart) {
    Write-Host "`n-NoRestart: files are in place; they apply on the next staging boot." -ForegroundColor Yellow
    exit 0
}
Write-Host "`nRestarting staging so prestart rebuilds live files from prod's sources..." -ForegroundColor Cyan
ssh @cm $stgT 'sudo systemctl restart dayz-server'
Start-Sleep -Seconds 3
$state = (Get-Stdout { ssh @cm $stgT 'systemctl is-active dayz-server' } | Out-String).Trim()
Show-Ok "staging dayz-server: $state (mission rebuilds from the synced config on this boot)"
Log 'restart' "state=$state"
exit 0
