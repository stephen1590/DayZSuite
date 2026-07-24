#!/usr/bin/env bash
# Monitoring stack provisioner — runs ON the box, shipped there by
# Deploy-Monitoring.ps1. STATIC script: every tunable comes from monitoring.env
# beside it (rendered from deploy.config.json). Idempotent — re-running converges.
#
# Installs Prometheus + node_exporter from the Ubuntu repos and Grafana OSS from
# Grafana's own apt repo (no Docker, no container registries). Everything binds
# to loopback; Grafana's only public face is the nginx vhost provisioned
# separately by Provision-Tls.ps1 -Service Monitoring.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ./monitoring.env

echo "== install (apt: prometheus, prometheus-node-exporter) =="
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq prometheus prometheus-node-exporter

echo "== install grafana (OSS package, Grafana Labs apt repo) =="
if ! test -f /etc/apt/keyrings/grafana.gpg; then
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg >/dev/null
fi
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    | sudo tee /etc/apt/sources.list.d/grafana.list >/dev/null
sudo apt-get update -qq
# Grafana is PINNED + held: a stack redeploy must never pull a surprise Grafana upgrade
# as a side effect of a dashboard/config change. A point release once broke mid-configure
# on the plugins-bundled move (grafana/grafana#123110). The deploy is the authority —
# unhold, install exactly GRAFANA_VERSION, re-hold. Bump GrafanaVersion in
# deploy.config.json to move it deliberately. No --allow-downgrades: a downgrade must fail
# loudly, not silently roll Grafana's sqlite schema back.
sudo apt-mark unhold grafana 2>/dev/null || true
sudo apt-get install -y -qq "grafana=${GRAFANA_VERSION}"
sudo apt-mark hold grafana

echo "== configure prometheus + node_exporter =="
# Ubuntu's packaging reads daemon flags from ARGS in /etc/default/<unit>.
# Loopback listen + retention are OUR config: written whole on every run.
sudo tee /etc/default/prometheus >/dev/null <<EOF
# Managed by GameServices/Monitoring — do not hand-edit; redeploy instead.
ARGS="--web.listen-address=${PROMETHEUS_LISTEN} --storage.tsdb.retention.time=${RETENTION_TIME}"
EOF
sudo tee /etc/default/prometheus-node-exporter >/dev/null <<EOF
# Managed by GameServices/Monitoring — do not hand-edit; redeploy instead.
ARGS="--web.listen-address=${NODE_EXPORTER_LISTEN}"
EOF
sudo install -m 0644 prometheus.yml /etc/prometheus/prometheus.yml

# Gate before restart: a bad scrape config must not take the running instance down.
promtool check config /etc/prometheus/prometheus.yml

echo "== configure grafana =="
# Grafana reads GF_* env; a systemd drop-in keeps the package's own
# /etc/default/grafana-server untouched. Loopback bind; nginx does TLS + the
# public name; analytics/phone-home off; no self-serve signups.
GRAFANA_ADDR=${GRAFANA_LISTEN%:*}
GRAFANA_PORT=${GRAFANA_LISTEN##*:}
sudo mkdir -p /etc/systemd/system/grafana-server.service.d
sudo tee /etc/systemd/system/grafana-server.service.d/override.conf >/dev/null <<EOF
# Managed by GameServices/Monitoring — do not hand-edit; redeploy instead.
[Service]
Environment=GF_SERVER_HTTP_ADDR=${GRAFANA_ADDR}
Environment=GF_SERVER_HTTP_PORT=${GRAFANA_PORT}
Environment=GF_SERVER_DOMAIN=${GRAFANA_DOMAIN}
Environment=GF_SERVER_ROOT_URL=https://${GRAFANA_DOMAIN}/
Environment=GF_ANALYTICS_REPORTING_ENABLED=false
Environment=GF_ANALYTICS_CHECK_FOR_UPDATES=false
Environment=GF_USERS_ALLOW_SIGN_UP=false
EOF
sudo install -m 0640 -o root -g grafana grafana-datasource.yml /etc/grafana/provisioning/datasources/monitoring.yaml
sudo install -m 0640 -o root -g grafana grafana-dashboards.yml /etc/grafana/provisioning/dashboards/monitoring.yaml
sudo mkdir -p /etc/grafana/provisioning/alerting
sudo install -m 0640 -o root -g grafana grafana-alerting.yml /etc/grafana/provisioning/alerting/monitoring.yaml
sudo mkdir -p /var/lib/grafana/dashboards
sudo rm -f /var/lib/grafana/dashboards/*.json
sudo install -m 0644 dashboards/*.json /var/lib/grafana/dashboards/

echo "== start =="
sudo systemctl daemon-reload
# Clear any start-rate-limit throttle from a prior failed attempt (e.g. a port
# collision on an earlier run) — otherwise systemd refuses the restart below.
sudo systemctl reset-failed prometheus prometheus-node-exporter grafana-server 2>/dev/null || true
sudo systemctl enable --now prometheus prometheus-node-exporter grafana-server
sudo systemctl restart prometheus prometheus-node-exporter grafana-server

echo "== verify =="
for i in $(seq 1 15); do
    curl -fsS "http://${PROMETHEUS_LISTEN}/-/ready" >/dev/null 2>&1 && break
    sleep 1
done
curl -fsS "http://${PROMETHEUS_LISTEN}/-/ready" && echo
# No `curl | head`: head closing the pipe makes curl exit 23, which pipefail
# turns into a false provisioning failure. Fetch whole, print the first line.
node_sample=$(curl -fsS "http://${NODE_EXPORTER_LISTEN}/metrics")
echo "${node_sample%%$'\n'*}"
for i in $(seq 1 30); do
    curl -fsS "http://${GRAFANA_LISTEN}/api/health" >/dev/null 2>&1 && break
    sleep 1
done
curl -fsS "http://${GRAFANA_LISTEN}/api/health"; echo

# One-time admin credential. Grafana ships admin/admin; rotate it to a generated
# secret through the RUNNING server's API — not grafana-cli, which resets the
# wrong sqlite db unless pointed at the real data dir and panics under sudo -u
# from a CWD it can't stat. The API path has none of those footguns. Generated on
# the box, printed ONCE (same doctrine as the API secrets), never in the repo.
# Marker (set only on success) guards re-runs; rotate by deleting it + redeploying.
if ! sudo test -f /var/lib/grafana/.admin-password-set; then
    ADMIN_PW=$(openssl rand -hex 16)
    if curl -fsS -X PUT -u "admin:admin" -H 'Content-Type: application/json' \
        "http://${GRAFANA_LISTEN}/api/user/password" \
        -d "{\"oldPassword\":\"admin\",\"newPassword\":\"${ADMIN_PW}\"}" >/dev/null; then
        sudo touch /var/lib/grafana/.admin-password-set
        echo ""
        echo "=================================================================="
        echo " Grafana admin credential (printed ONCE — copy it now)"
        echo "   user:     admin"
        echo "   password: ${ADMIN_PW}"
        echo "=================================================================="
    else
        echo "WARN: could not rotate the admin password via API (default admin/admin" >&2
        echo "      may already have been changed). Left as-is; set it in the UI." >&2
    fi
fi

# Target health is informational, not fatal: an app exporter that isn't deployed
# yet shows down here without failing the provision. First scrape needs a cycle.
echo "-- scrape targets (after first cycle) --"
sleep 5
curl -fsS "http://${PROMETHEUS_LISTEN}/api/v1/targets" \
    | grep -o '"scrapeUrl":"[^"]*"\|"health":"[^"]*"' \
    | sed 's/"scrapeUrl":"/  /; s/"health":"/    -> /; s/"//g' || true

echo "Done. Grafana: https://${GRAFANA_DOMAIN} (after Provision-Tls.ps1 -Service Monitoring)."
