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
#   * creates the data dir once and NEVER clobbers it
#   * seeds the invite-only RESTRICT_REGISTRATION decree once when enabled
#     (RestrictRegistration), never overriding a later admin-panel change
#   * re-renders customize/application_config.js every run (managed policy:
#     guests may open/edit shared docs but cannot create anything new, min
#     password length) while preserving the generated-once loginSalt
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

echo "== registration policy (invite-only = ${RESTRICT_REGISTRATION:-false}) =="
# CryptPad has NO config.js key for invite-only registration — it is a runtime
# "decree". We SEED it: append a RESTRICT_REGISTRATION line to the datastore's
# decree log, in the exact on-disk shape CryptPad writes itself — a JSON array
# [command, args, author, time] (loaded unauthenticated, so a seeded line is
# honoured on boot). Seed ONLY when the flag is on AND no such decree exists yet,
# so we never duplicate and never re-impose it over a later admin-panel change;
# the admin panel is the live authority once the decree is present. The
# bootstrap admin must already exist — Deploy-CryptPad.ps1 refuses the flag with
# empty AdminKeys, so we can't lock everyone out here.
DECREE_DIR="$DATA_DIR/data/decrees"
DECREE_FILE="$DECREE_DIR/decree.ndjson"
if [ "${RESTRICT_REGISTRATION:-false}" = "true" ]; then
  $SUDO -u "$RUN_USER" mkdir -p "$DECREE_DIR"
  if $SUDO test -f "$DECREE_FILE" && $SUDO grep -q '"RESTRICT_REGISTRATION"' "$DECREE_FILE"; then
    echo 'RESTRICT_REGISTRATION already recorded — admin panel owns it now, left as-is'
  else
    printf '["RESTRICT_REGISTRATION",[true],"deploy-bootstrap",%s]\n' "$(date +%s%3N)" \
      | $SUDO -u "$RUN_USER" tee -a "$DECREE_FILE" >/dev/null
    echo 'seeded RESTRICT_REGISTRATION — new signups now require an invite link'
  fi
else
  echo 'open registration (RestrictRegistration=false) — not managed here'
fi

echo '== config.js (shipped file) =='
$SUDO install -o "$RUN_USER" -g "$RUN_USER" -m 0644 ./config.js "$APP_DIR/config/config.js"

echo '== application_config.js (managed policy; loginSalt preserved) =='
# Client-served AppConfig override. loginSalt MUST stay stable once accounts
# exist (changing it locks everyone out), so it is generated ONCE and then
# preserved — carried forward by reading it back out of the previous file. The
# rest is POLICY we re-apply on every deploy (so it stays managed here, never
# hand-edited on the box). Every creatable document type goes in
# registeredOnlyTypes => guests can open/edit docs shared with them by link but
# cannot CREATE anything new (uploads included); link access is unaffected.
$SUDO -u "$RUN_USER" mkdir -p "$APP_DIR/customize"
APPCFG="$APP_DIR/customize/application_config.js"
SALT=
if $SUDO test -f "$APPCFG"; then
  SALT=$($SUDO sed -n "s/.*loginSalt *= *'\([a-f0-9]*\)'.*/\1/p" "$APPCFG" | head -n1)
fi
if [ -z "$SALT" ]; then
  SALT=$(openssl rand -hex 32)
  echo 'generated a fresh loginSalt'
else
  echo 'preserved the existing loginSalt'
fi
$SUDO -u "$RUN_USER" tee "$APPCFG" >/dev/null <<EOF
define(['/common/application_config_internal.js'], function (AppConfig) {
    // loginSalt: generated once, preserved on every redeploy (see deploy.sh).
    AppConfig.loginSalt = '$SALT';
    AppConfig.minimumPasswordLength = 8;

    // Guest policy: open/edit documents shared with you by link, but create
    // NOTHING new. Every creatable document type is marked "registered-only",
    // so a guest who clicks "New" is sent to log in, while opening an existing
    // document by its link is unaffected (link access never consults this list).
    // The explicit list covers the known apps even if CryptPad renames its type
    // index; the availablePadTypes pass adds any future types automatically.
    // 'drive' and 'teams' are session areas, not documents, so we leave them.
    var explicit = ['pad', 'sheet', 'doc', 'presentation', 'code', 'slide',
                    'form', 'poll', 'kanban', 'whiteboard', 'file'];
    var dynamic = (AppConfig.availablePadTypes || []).filter(function (t) {
        return ['drive', 'teams'].indexOf(t) === -1;
    });
    AppConfig.registeredOnlyTypes = (AppConfig.registeredOnlyTypes || []).slice();
    explicit.concat(dynamic).forEach(function (t) {
        if (AppConfig.registeredOnlyTypes.indexOf(t) === -1) {
            AppConfig.registeredOnlyTypes.push(t);
        }
    });
    return AppConfig;
});
EOF

echo '== systemd unit (shipped file) =='
$SUDO install -o root -g root -m 0644 ./cryptpad.service /etc/systemd/system/cryptpad.service
$SUDO systemctl daemon-reload
$SUDO systemctl enable cryptpad
$SUDO systemctl restart cryptpad
sleep 2
$SUDO systemctl --no-pager --full status cryptpad || true
echo '== done =='
