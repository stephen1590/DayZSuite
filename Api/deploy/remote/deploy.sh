#!/usr/bin/env bash
# API-service app deploy — runs ON the server, from the shipped stage directory.
# Shipped there (with deploy.env, config.json, api.service, dayz-ctl,
# api.sudoers, and the app source) by ../Deploy-Api.ps1 -Apply. This file
# is STATIC: no values live here — they come from ./deploy.env (rendered from
# deploy.config.json).
#
# Idempotent — safe to re-run to ship new code/config:
#   * installs Node if the major is too old
#   * creates the service user once
#   * copies the app source to $APP_DIR, installs deps, builds, prunes dev deps
#   * installs config.js[on] + unit + the dayz-ctl privilege bridge + sudoers, every run
#   * generates the HMAC secret + VPP token ONCE (then preserves them)
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source ./deploy.env

SUDO=; [ "$(id -u)" -ne 0 ] && SUDO=sudo
export DEBIAN_FRONTEND=noninteractive

echo '== prerequisites =='
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq curl ca-certificates openssl

echo '== node.js =='
NEED_NODE=1
if command -v node >/dev/null 2>&1; then
  MAJ=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  if [ "$MAJ" -ge "$NODE_MAJOR" ]; then NEED_NODE=0; fi
fi
if [ "$NEED_NODE" -eq 1 ]; then
  echo "installing Node $NODE_MAJOR.x from NodeSource"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | $SUDO -E bash -
  $SUDO apt-get install -y -qq nodejs
fi
echo "node $(node --version), npm $(npm --version)"

# dayz-ctl uses pwsh (via the DayZ deploy's dayz-rcon.ps1) for the players/broadcast
# verbs. It is not installed here (that is the DayZ deploy's concern) — just warn.
command -v pwsh >/dev/null 2>&1 || \
  echo 'WARN: pwsh not found — restart/stop/start/set-map work, but players/broadcast need it (installed with the DayZ server).'

echo "== service user ($RUN_USER) =="
if ! id "$RUN_USER" >/dev/null 2>&1; then
  $SUDO useradd --system --create-home --home-dir "/home/$RUN_USER" \
    --shell /usr/sbin/nologin "$RUN_USER"
fi

echo "== app source -> $APP_DIR =="
$SUDO mkdir -p "$APP_DIR"
# Replace code, but never touch node_modules/dist here (rebuilt below).
$SUDO rsync -a --delete --exclude node_modules --exclude dist \
  ./src ./package.json ./tsconfig.json $( [ -f ./package-lock.json ] && echo ./package-lock.json ) \
  "$APP_DIR/"
$SUDO chown -R "$RUN_USER:$RUN_USER" "$APP_DIR"

echo '== install deps + build =='
if [ -f "$APP_DIR/package-lock.json" ]; then INSTALL='npm ci'; else INSTALL='npm install --no-audit --no-fund'; fi
$SUDO -u "$RUN_USER" -H bash -c "cd '$APP_DIR' && $INSTALL && npm run build && npm prune --omit=dev"

echo '== config + secrets (/etc/api) =='
$SUDO mkdir -p /etc/api
$SUDO install -o root -g "$RUN_USER" -m 0640 ./config.json /etc/api/config.json
SECRETS=/etc/api/secrets.env
if $SUDO test -f "$SECRETS"; then
  echo 'secrets.env exists — keeping the existing HMAC secret + VPP token'
else
  echo 'generating HMAC secret + VPP token (once)'
  HMAC=$(openssl rand -hex 32)
  VPPT=$(openssl rand -hex 24)
  printf 'HMAC_SECRET=%s\nVPP_TOKEN=%s\n' "$HMAC" "$VPPT" | $SUDO tee "$SECRETS" >/dev/null
fi
$SUDO chown root:"$RUN_USER" "$SECRETS"
$SUDO chmod 0640 "$SECRETS"

echo "== audit dir ($AUDIT_DIR) =="
$SUDO mkdir -p "$AUDIT_DIR"
$SUDO chown "$RUN_USER:$RUN_USER" "$AUDIT_DIR"
$SUDO chmod 0750 "$AUDIT_DIR"

echo '== privilege bridge (/usr/local/bin/dayz-ctl) + sudoers =='
$SUDO install -o root -g root -m 0755 ./dayz-ctl /usr/local/bin/dayz-ctl
# Validate the sudoers fragment in isolation BEFORE installing it — a bad file in
# /etc/sudoers.d can lock out sudo entirely.
$SUDO install -o root -g root -m 0440 ./api.sudoers /etc/sudoers.d/api
if ! $SUDO visudo -cf /etc/sudoers.d/api >/dev/null; then
  $SUDO rm -f /etc/sudoers.d/api
  echo 'ERROR: sudoers fragment failed validation — removed it.' >&2
  exit 1
fi

echo '== systemd unit =='
$SUDO install -o root -g root -m 0644 ./api.service /etc/systemd/system/api.service
$SUDO systemctl daemon-reload
$SUDO systemctl enable api
$SUDO systemctl restart api
sleep 2
$SUDO systemctl --no-pager --full status api || true

echo
echo '== done =='
echo 'Secrets are NOT printed here (this output is logged). Retrieve them ON THE BOX with:'
echo '    sudo cat /etc/api/secrets.env'
echo '  - HMAC_SECRET: sign command requests   X-Signature-256: sha256=<hmac-sha256(secret, raw-body)>'
echo '  - VPP_TOKEN  : put in the VPP webhook URL  https://api.<domain>/sources/vpp/<VPP_TOKEN>'
