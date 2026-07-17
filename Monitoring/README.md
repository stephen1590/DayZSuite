# Monitoring

Server performance history, end to end: Prometheus + node_exporter capture it,
Grafana shows it at `grafana.<BaseDomain>`. Everything binds to loopback;
Grafana's nginx vhost (TLS via `../Provision-Tls.ps1 -Service Monitoring`) is
the only public face, guarded by Grafana's own login. All from OS/vendor apt
repos, systemd services, no Docker. Long-term this replaces the ConfigViewer's
live-only performance panels.

## What gets captured

- **Host** - node_exporter on `127.0.0.1:9100`: CPU, load, memory, swap, disk,
  network. Covers everything the API's `/sysload` hand-computes, and more.
- **Apps** - one scrape job per `ScrapeJobs` row in `deploy/deploy.config.json`.
  Today: the API's `GET /metrics` (`dayz_*` series - unit state/memory/CPU,
  restarts, players, ping, mission, persistence/log sizes). That endpoint is
  local-only: both nginx vhosts refuse the path and the app rejects proxied
  requests.
- **Itself** - `prometheus` and `node` jobs are built in.

Retention defaults to 30 days (`RetentionTime`).

## Dashboards

Dashboards are code, shipped by the deploy (UI edits are not persisted - save a
copy in Grafana to experiment):

- `deploy/dashboards/dayz-server.json` - the DayZ board (status, players, ping,
  memory, CPU, restarts, disk footprint, collector health).
- Node Exporter Full (grafana.com #1860, pinned revision) - the standard host
  board, vendored into `deploy/vendor/` on first deploy.

The datasource uid `prometheus` is a contract between
`templates/grafana-datasource.yml.template` and the shipped dashboards.

## Alerts

Alert rules are provisioned as code too
(`templates/grafana-alerting.yml.template`), bound to the `prometheus`
datasource. The starter set:

| Rule | Fires when | For |
|---|---|---|
| DayZ server offline | `dayz_up < 1` (unit down, or /metrics unreachable) | 3m |
| DayZ collector down | sudo bridge or RCon collector failing | 5m |
| Host root disk low | root fs free below `Alerts.DiskFreePctBelow` (10%) | 5m |
| Host memory high | used above `Alerts.MemUsedPctAbove` (90%) | 10m |
| Host CPU high | busy above `Alerts.CpuBusyPctAbove` (90%) | 10m |

Thresholds live in the `Alerts` block of `deploy.config.json`. **No contact
point yet** ("in-Grafana only") - alerts show state on Grafana's Alerting page
and on dashboard panels, but notify nowhere. To get pinged off-box, add a
`contactPoints:`/`policies:` block to the alerting template (e.g. a Discord
webhook) and redeploy.

## Deploy

Two steps, both report-only until you pass the apply flag:

```powershell
# 1. The stack: Prometheus, node_exporter, Grafana, datasource + dashboards
./deploy/Deploy-Monitoring.ps1           # dry run - renders + stages for review
./deploy/Deploy-Monitoring.ps1 -Apply    # apt install, configure, start, verify

# 2. Grafana's public face: TLS cert + nginx vhost (once)
../Provision-Tls.ps1 -Service Monitoring          # dry run
../Provision-Tls.ps1 -Service Monitoring -Apply
```

The first `-Apply` prints the generated Grafana admin password ONCE - save it.
Rotate it by deleting `/var/lib/grafana/.admin-password-set` on the box and
redeploying.

The `dayz-api` target shows `down` until the API with `/metrics` is deployed
(`../Api/deploy/Deploy-Api.ps1 -Apply`). That is informational, not a failure.

## Prometheus directly (no vhost)

Prometheus itself stays loopback-only. To poke at it:

```bash
ssh -L 9090:127.0.0.1:9090 ubuntu@<server>
# then open http://localhost:9090  (Status -> Targets, or Graph)
```

## Reusing on another box

The stack is generic - no service names are baked into the templates or
`provision.sh`. On a new box:

1. Point `../host.config.env` at it (or use a second checkout).
2. Copy `deploy/deploy.config.example.json` to `deploy.config.json`; trim
   `ScrapeJobs` to what that box runs (an empty list is fine - host metrics
   alone still work).
3. `./deploy/Deploy-Monitoring.ps1 -Apply`.

Adding a new app to capture = expose `/metrics` on it + one `ScrapeJobs` row.
Its dashboard = one JSON in `deploy/dashboards/` (bind panels to datasource uid
`prometheus`).
