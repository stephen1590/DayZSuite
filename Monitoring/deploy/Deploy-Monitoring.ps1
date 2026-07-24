#requires -Version 7
<#
.SYNOPSIS
  Stage-and-ship deploy for the Monitoring stack (Prometheus + node_exporter).

.DESCRIPTION
  Flow: render -> stage -> ship -> run.

    1. RENDER  prometheus.yml (built-in prometheus/node jobs + one row per
               ScrapeJobs entry) and monitoring.env from deploy.config.json
    2. STAGE   into stage/monitoring/ — real files you can review/diff
    3. SHIP    (-Apply) rsync the stage to ~/.deploy/<SiteName>/ on the box
    4. RUN     (-Apply) ssh: bash provision.sh there (STATIC — apt install,
               loopback listeners, retention, scrape config, verify)

  Report-only by default: builds the stage and stops, so a dry run's output IS
  the staged directory. Nothing on the server changes without -Apply.

  The stack is GENERIC and repeatable: no service names are baked into the
  templates or provision.sh. Everything box-specific is data in
  deploy.config.json (ScrapeJobs) + host.config.env (which box). Grafana will
  land in this same service later; capture comes first so history accrues.

.EXAMPLE
  ./Deploy-Monitoring.ps1           # dry run: render + stage for review
  ./Deploy-Monitoring.ps1 -Apply    # ship + install + start + verify

.NOTES
  Never hand-edit the live box. Change config/template and redeploy.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [ValidateSet('staging','prod')]
    [string]$Env = 'staging',   # which box: staging default, prod explicit (../../STAGING-PLAN.md) - picks host.config.<env>.env
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
# Shared code utils live at Dev/common (deploy -> Monitoring -> GameServices ->
# UbuntuHost -> Dev); deploy-config loader + SHIP/RUN helpers at the repo root/common.
. (Join-Path $PSScriptRoot '../../../../common/Utils.ps1')
. (Join-Path $PSScriptRoot '../../Load-DeployConfig.ps1')
. (Join-Path $PSScriptRoot '../../common/Deploy-Helpers.ps1')

$cfg = Import-DeployConfig -ServiceDeployDir $PSScriptRoot -Env $Env
foreach ($key in @('Server', 'SshUser', 'SiteName', 'PrometheusListen', 'NodeExporterListen', 'GrafanaListen', 'GrafanaVersion', 'RetentionTime', 'ScrapeIntervalSec')) {
    if (-not $cfg[$key]) { throw "Monitoring deploy config is missing '$key'." }
}
if (@($cfg.Hostnames).Count -lt 1) { throw "Monitoring deploy config needs Hostnames (Grafana's public name, used for root_url)." }
if ("$($cfg.RetentionTime)" -notmatch '^\d+[smhdwy]$') { throw "Monitoring RetentionTime must be a Prometheus duration (e.g. 180d): '$($cfg.RetentionTime)'." }
foreach ($l in @($cfg.PrometheusListen, $cfg.NodeExporterListen, $cfg.GrafanaListen)) {
    if ("$l" -notmatch '^[\w.\[\]:-]+:\d+$') { throw "Monitoring listen address must be host:port: '$l'." }
}

# ScrapeJobs -> YAML rows. Validated here (closed charset, host:port) so a config
# typo fails the render, not the box's promtool check. Same generated-table pattern
# as the Api's CONFIG_MAP.
$extraJobs = ''
$seenJob = @{ prometheus = $true; node = $true }
foreach ($j in @($cfg.ScrapeJobs)) {
    $name = "$($j.Job)".Trim()
    if ($name -notmatch '^[a-z0-9_-]+$') { throw "Monitoring ScrapeJobs: job '$name' must be [a-z0-9_-]." }
    if ($seenJob.ContainsKey($name)) { throw "Monitoring ScrapeJobs: duplicate job '$name' (prometheus/node are built in)." }
    $seenJob[$name] = $true
    if ("$($j.Target)" -notmatch '^[\w.\[\]:-]+:\d+$') { throw "Monitoring ScrapeJobs[$name]: Target must be host:port: '$($j.Target)'." }
    $path = if ($j.Path) { "$($j.Path)" } else { '/metrics' }
    if ($path -notmatch '^/[\w./-]*$') { throw "Monitoring ScrapeJobs[$name]: Path must be an absolute URL path: '$path'." }
    $interval = if ($j.IntervalSec) { [int]$j.IntervalSec } else { [int]$cfg.ScrapeIntervalSec }

    $extraJobs += "`n  - job_name: $name`n"
    $extraJobs += "    scrape_interval: ${interval}s`n"
    if ($path -ne '/metrics') { $extraJobs += "    metrics_path: $path`n" }
    $extraJobs += "    static_configs:`n      - targets: ['$($j.Target)']`n"
}

# --- RENDER + STAGE ---------------------------------------------------------
function Expand-File([string]$RelPath, [hashtable]$Vars) {
    $p = Join-Path $PSScriptRoot $RelPath
    if (-not (Test-Path $p)) { throw "Template not found: $p" }
    $text = Get-Content -Raw $p
    foreach ($k in $Vars.Keys) { $text = $text.Replace($k, [string]$Vars[$k]) }
    return $text
}

$stageDir = Join-Path $PSScriptRoot 'stage/monitoring'
if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }   # generated output, rebuilt every run
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

Set-Content -NoNewline -Path (Join-Path $stageDir 'prometheus.yml') -Value (
    Expand-File 'templates/prometheus.yml.template' @{
        '__SCRAPE_INTERVAL__'   = "$([int]$cfg.ScrapeIntervalSec)"
        '__PROMETHEUS_LISTEN__'   = $cfg.PrometheusListen
        '__NODE_EXPORTER_LISTEN__' = $cfg.NodeExporterListen
        '__EXTRA_JOBS__'        = $extraJobs.TrimEnd("`n")
    })

Set-Content -NoNewline -Path (Join-Path $stageDir 'monitoring.env') -Value (
    Expand-File 'templates/monitoring.env.template' @{
        '__PROMETHEUS_LISTEN__'    = $cfg.PrometheusListen
        '__NODE_EXPORTER_LISTEN__' = $cfg.NodeExporterListen
        '__RETENTION_TIME__'       = $cfg.RetentionTime
        '__GRAFANA_VERSION__'      = $cfg.GrafanaVersion
        '__GRAFANA_LISTEN__'       = $cfg.GrafanaListen
        '__GRAFANA_DOMAIN__'       = @($cfg.Hostnames)[0]
    })

Set-Content -NoNewline -Path (Join-Path $stageDir 'grafana-datasource.yml') -Value (
    Expand-File 'templates/grafana-datasource.yml.template' @{
        '__PROMETHEUS_LISTEN__' = $cfg.PrometheusListen
        '__SCRAPE_INTERVAL__'   = "$([int]$cfg.ScrapeIntervalSec)"
    })
Set-Content -NoNewline -Path (Join-Path $stageDir 'grafana-dashboards.yml') -Value (
    Expand-File 'templates/grafana-dashboards.yml.template' @{})

# Alert rules (provisioned as code). Thresholds from the Alerts block; sensible
# defaults if it's absent so a minimal config still ships working rules.
$alerts = if ($cfg.Alerts) { $cfg.Alerts } else { @{} }
$diskFreePct = if ($null -ne $alerts.DiskFreePctBelow) { [int]$alerts.DiskFreePctBelow } else { 10 }
$memUsedPct  = if ($null -ne $alerts.MemUsedPctAbove)  { [int]$alerts.MemUsedPctAbove }  else { 90 }
$cpuBusyPct  = if ($null -ne $alerts.CpuBusyPctAbove)  { [int]$alerts.CpuBusyPctAbove }  else { 90 }
foreach ($v in @($diskFreePct, $memUsedPct, $cpuBusyPct)) {
    if ($v -lt 1 -or $v -gt 99) { throw "Monitoring Alerts thresholds must be 1-99 (got $v)." }
}
Set-Content -NoNewline -Path (Join-Path $stageDir 'grafana-alerting.yml') -Value (
    Expand-File 'templates/grafana-alerting.yml.template' @{
        '__DISK_FREE_PCT__' = "$diskFreePct"
        '__MEM_USED_PCT__'  = "$memUsedPct"
        '__CPU_BUSY_PCT__'  = "$cpuBusyPct"
    })

# --- Dashboards: repo-authored + vendored ------------------------------------
# Node Exporter Full (grafana.com dashboard 1860) is the standard host board —
# vendored PINNED, fetched once and reused (same pattern as ConfigViewer's
# swagger-ui; vendor/ is gitignored so a fresh checkout re-fetches).
$NodeExpRev = 37
$vendorDir = Join-Path $PSScriptRoot 'vendor'
$nodeDash = Join-Path $vendorDir "node-exporter-full-rev$NodeExpRev.json"
if (-not (Test-Path $nodeDash)) {
    Write-Host "Vendoring Node Exporter Full (grafana.com dashboard 1860 rev $NodeExpRev)…"
    New-Item -ItemType Directory -Force -Path $vendorDir | Out-Null
    Invoke-WebRequest -Uri "https://grafana.com/api/dashboards/1860/revisions/$NodeExpRev/download" -OutFile $nodeDash
}
$dashStage = Join-Path $stageDir 'dashboards'
New-Item -ItemType Directory -Force -Path $dashStage | Out-Null
foreach ($d in @(Get-ChildItem (Join-Path $PSScriptRoot 'dashboards') -Filter '*.json') + (Get-Item $nodeDash)) {
    # Provisioned dashboards cannot prompt for a datasource — bind the import-time
    # ${DS_PROMETHEUS} placeholder to the provisioned datasource uid (a contract
    # with grafana-datasource.yml.template).
    $json = (Get-Content -Raw $d.FullName).Replace('${DS_PROMETHEUS}', 'prometheus')
    $null = $json | ConvertFrom-Json   # parse gate: a broken dashboard fails the render, not the box
    Set-Content -NoNewline -Path (Join-Path $dashStage $d.Name) -Value $json
}

Copy-Item (Join-Path $PSScriptRoot 'remote/provision.sh') (Join-Path $stageDir 'provision.sh')

# --- Report -----------------------------------------------------------------
$target = "$($cfg.SshUser)@$($cfg.Server)"
Write-Host "Target    : $target" -ForegroundColor Cyan
Write-Host "Prometheus: $($cfg.PrometheusListen)  retention $($cfg.RetentionTime)  scrape $($cfg.ScrapeIntervalSec)s"
Write-Host "Node exp. : $($cfg.NodeExporterListen)"
Write-Host "Grafana   : $($cfg.GrafanaListen)  ->  https://$(@($cfg.Hostnames)[0])  (vhost via Provision-Tls -Service Monitoring)"
Write-Host "Jobs      : prometheus, node$(@($cfg.ScrapeJobs) | ForEach-Object { ', ' + $_.Job })"
Write-Host "Dashboards: $((Get-ChildItem $dashStage -Filter '*.json' | ForEach-Object { $_.BaseName }) -join ', ')"
Write-Host "Alerts    : server-offline, collector-down, disk<${diskFreePct}%, mem>${memUsedPct}%, cpu>${cpuBusyPct}%  (in-Grafana, no contact point)"
Write-Host "Staged    : $stageDir" -ForegroundColor Cyan
Get-ChildItem $stageDir | ForEach-Object { Write-Host ("            {0,-16} {1,6:n0} B" -f $_.Name, $_.Length) }

# --- SHIP + RUN (or stop after staging) -------------------------------------
$logDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'

if (-not $Apply) {
    Write-Host "== DRY RUN — stage built, nothing shipped (review the files above, then -Apply) ==" -ForegroundColor Yellow
} else {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $runLog = Join-Path $logDir "provision_$((Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss'))Z.log"
    # .deploy/<SiteName>/stack — NOT the .deploy/<SiteName> root: Provision-Tls ships to
    # .deploy/<SiteName>/tls, and our rsync --delete at the root would wipe it.
    Write-Host "== Shipping stage/monitoring -> ${target}:.deploy/$($cfg.SiteName)/stack ==" -ForegroundColor Green
    Invoke-RemoteDeploy -Cfg $cfg -StageDir $stageDir -RemoteStage ".deploy/$($cfg.SiteName)/stack" -Script 'provision.sh' -RunLog $runLog
    Write-Host ""
    Write-Host "Done. Loopback-only — inspect with:  ssh -L 9090:$($cfg.PrometheusListen) $target  then http://localhost:9090" -ForegroundColor Green
}

# --- CSV log ------------------------------------------------------------------
if (-not $NoLog) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir 'deploy.csv') -Row ([PSCustomObject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        mode      = if ($Apply) { 'apply' } else { 'dryrun' }
        service   = 'Monitoring'
        server    = $cfg.Server
        jobs      = (@('prometheus', 'node') + @(@($cfg.ScrapeJobs) | ForEach-Object { $_.Job })) -join ' '
    })
}
