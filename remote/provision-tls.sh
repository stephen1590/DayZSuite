#!/usr/bin/env bash
# nginx + Let's Encrypt (HTTP-01) provisioning — runs ON the server, from the
# shipped stage directory (rsynced there by ../Provision-Tls.ps1 -Apply).
# This file is STATIC: no values live here — they come from ./provision.env;
# no nginx content lives here — it comes from the shipped .conf files:
#   nginx-http-only.conf   (only when SKIP_TLS=1: plain HTTP, pre-DNS)
#   nginx-bootstrap.conf   (port-80 ACME-only vhost, pre-certificate)
#   nginx-site.conf        (the full 80-redirect + 443 site)
#
# Idempotent — safe to re-run: package installs are no-ops when present,
# cert issuance is skipped if the cert already exists (certbot.timer renews).
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source ./provision.env

SUDO=; [ "$(id -u)" -ne 0 ] && SUDO=sudo
export DEBIAN_FRONTEND=noninteractive

echo '== packages =='
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq nginx certbot

echo '== webroots =='
$SUDO mkdir -p "$ACME_WEBROOT"
$SUDO chown -R www-data:www-data "$ACME_WEBROOT"
if [ -n "${WEBROOT:-}" ]; then
  # Owned by the deploy user (not root) so content rsyncs can write into it;
  # default 755/644 perms still leave it readable by nginx (www-data).
  $SUDO mkdir -p "$WEBROOT"
  $SUDO chown -R "$SSH_USER:$SSH_USER" "$WEBROOT"
fi

# Install a shipped conf as THE site and (re)load nginx.
enable_site() {
  $SUDO install -m 0644 "$1" "/etc/nginx/sites-available/$SITE_NAME"
  $SUDO ln -sf "/etc/nginx/sites-available/$SITE_NAME" "/etc/nginx/sites-enabled/$SITE_NAME"
  $SUDO rm -f /etc/nginx/sites-enabled/default
  $SUDO nginx -t
  $SUDO systemctl enable --now nginx
  $SUDO systemctl reload nginx
}

if [ "$SKIP_TLS" = "1" ]; then
  echo '== nginx (plain HTTP, no TLS) =='
  enable_site ./nginx-http-only.conf
  echo '== done (HTTP only — no certificate issued; re-run WITHOUT -SkipTls once DNS points here) =='
  exit 0
fi

echo '== nginx bootstrap (port 80, ACME only) =='
enable_site ./nginx-bootstrap.conf

echo '== certificate =='
if $SUDO test -f "/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"; then
  echo 'cert already present — skipping issuance (renewal handled by certbot.timer)'
else
  CERT_ARGS=()
  for h in $HOSTNAMES; do CERT_ARGS+=(-d "$h"); done   # intentional word split: space-joined SANs
  $SUDO certbot certonly --webroot -w "$ACME_WEBROOT" "${CERT_ARGS[@]}" \
    --non-interactive --agree-tos -m "$ADMIN_EMAIL" \
    --deploy-hook 'systemctl reload nginx'
fi

echo '== nginx full config (80 redirect + 443 site) =='
$SUDO install -m 0644 ./nginx-site.conf "/etc/nginx/sites-available/$SITE_NAME"
$SUDO nginx -t
$SUDO systemctl reload nginx

echo '== auto-renewal =='
$SUDO systemctl enable --now certbot.timer
$SUDO systemctl list-timers certbot.timer --no-pager || true
echo '== done =='
