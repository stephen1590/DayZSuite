#!/usr/bin/env bash
# CryptPad app deploy — runs ON the server, from the shipped stage directory.
# Shipped there (with deploy.env, config.js, cryptpad.service) by
# ../Deploy-CryptPad.ps1 -Apply. This file is STATIC: no values live here —
# they all come from ./deploy.env (rendered from deploy.config.json).
#
# Idempotent — safe to re-run to update to a new REF:
#   * clones CryptPad on first run, else fetches + checks out the pinned tag
#   * rebuilds (npm ci / install:components / build)
#   * installs the shipped config.js + systemd unit verbatim, every run
#   * creates the data dir once and NEVER clobbers it; the loginSalt in
#     customize/application_config.js is generated once and then preserved.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source ./deploy.env

SUDO=; [ "$(id -u)" -ne 0 ] && SUDO=sudo
export DEBIAN_FRONTEND=noninteractive

echo '== prerequisites =='
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq git curl ca-certificates build-essential python3

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

echo "== service user ($RUN_USER) =="
if ! id "$RUN_USER" >/dev/null 2>&1; then
  $SUDO useradd --system --create-home --home-dir "/home/$RUN_USER" \
    --shell /usr/sbin/nologin "$RUN_USER"
fi

echo "== fetch CryptPad $REF =="
if [ ! -d "$APP_DIR/.git" ]; then
  $SUDO mkdir -p "$APP_DIR"
  $SUDO chown "$RUN_USER:$RUN_USER" "$APP_DIR"
  $SUDO -u "$RUN_USER" git clone --depth 1 --branch "$REF" "$REPO_URL" "$APP_DIR"
else
  $SUDO -u "$RUN_USER" git -C "$APP_DIR" fetch --depth 1 origin "refs/tags/$REF:refs/tags/$REF"
  $SUDO -u "$RUN_USER" git -C "$APP_DIR" checkout -f "$REF"
fi

echo '== build (npm ci / install:components / build) =='
$SUDO -u "$RUN_USER" -H bash -c "cd '$APP_DIR' && npm ci && npm run install:components && npm run build"

echo "== data dir ($DATA_DIR) =="
$SUDO mkdir -p "$DATA_DIR"
$SUDO chown -R "$RUN_USER:$RUN_USER" "$DATA_DIR"
$SUDO chmod 0750 "$DATA_DIR"
# Secondary SFTP access: put the SSH user in the service group so it can READ
# the data (0750). It does NOT get write access — CryptPad owns its data.
$SUDO usermod -aG "$RUN_USER" "$SSH_USER"

echo '== config.js (shipped file) =='
$SUDO install -o "$RUN_USER" -g "$RUN_USER" -m 0644 ./config.js "$APP_DIR/config/config.js"

echo '== application_config.js (loginSalt — generated once, then preserved) =='
$SUDO -u "$RUN_USER" mkdir -p "$APP_DIR/customize"
APPCFG="$APP_DIR/customize/application_config.js"
if $SUDO test -f "$APPCFG"; then
  echo 'application_config.js exists — keeping the existing loginSalt'
else
  SALT=$(openssl rand -hex 32)
  $SUDO -u "$RUN_USER" tee "$APPCFG" >/dev/null <<EOF
define(['/common/application_config_internal.js'], function (AppConfig) {
    AppConfig.loginSalt = '$SALT';
    AppConfig.minimumPasswordLength = 8;
    return AppConfig;
});
EOF
  echo 'generated a fresh loginSalt'
fi

echo '== systemd unit (shipped file) =='
$SUDO install -o root -g root -m 0644 ./cryptpad.service /etc/systemd/system/cryptpad.service
$SUDO systemctl daemon-reload
$SUDO systemctl enable cryptpad
$SUDO systemctl restart cryptpad
sleep 2
$SUDO systemctl --no-pager --full status cryptpad || true
echo '== done =='
