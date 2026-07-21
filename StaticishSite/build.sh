#!/bin/bash
# ============================================================================
# build.sh — local preview / production build for the Personal Projects site.
#
#   ./build.sh            # live-reload preview (drafts on), reachable on LAN
#   ./build.sh --build    # production build into ./public
#   ./build.sh --port 1400
#
# The hugo-book theme compiles SCSS, which needs Hugo EXTENDED. If the system
# hugo isn't extended, this fetches an extended build into ./bin automatically.
#
# Deployment to the Ubuntu server is handled separately by deploy/Deploy-Site.ps1.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
PORT=1313
MODE=serve

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build|-b) MODE=build; shift ;;
    --port|-p)  PORT="${2:?--port needs a number}"; shift 2 ;;
    -h|--help)  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Pull in the theme submodule on first run.
if [[ ! -f "$SCRIPT_DIR/themes/hugo-book/theme.toml" ]]; then
  echo "Fetching hugo-book theme..."
  git -C "$SCRIPT_DIR" submodule update --init --recursive
fi

# Resolve an EXTENDED hugo. Prefer the system one if it qualifies; otherwise use
# (or download) a local extended build in ./bin. Sets $HUGO.
is_extended() { "$1" version 2>/dev/null | grep -q '+extended'; }

resolve_hugo() {
  if command -v hugo >/dev/null 2>&1 && is_extended hugo; then
    HUGO="$(command -v hugo)"; return
  fi
  if [[ -x "$BIN_DIR/hugo" ]] && is_extended "$BIN_DIR/hugo"; then
    HUGO="$BIN_DIR/hugo"; return
  fi
  echo "Hugo extended not found — fetching latest into $BIN_DIR ..."
  mkdir -p "$BIN_DIR"
  local ver arch
  ver=$(curl -fsSL https://api.github.com/repos/gohugoio/hugo/releases/latest \
        | grep -m1 '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
  case "$(uname -m)" in
    x86_64|amd64) arch=linux-amd64 ;;
    aarch64|arm64) arch=linux-arm64 ;;
    *) echo "ERROR: unsupported arch $(uname -m); install hugo extended manually." >&2; exit 1 ;;
  esac
  # Download to a file first: piping curl into `tar -x <member>` makes tar exit
  # early (after it finds `hugo`), breaking the pipe and tripping pipefail.
  local tmp
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "https://github.com/gohugoio/hugo/releases/download/v${ver}/hugo_extended_${ver}_${arch}.tar.gz"
  tar -xzf "$tmp" -C "$BIN_DIR" hugo
  rm -f "$tmp"
  HUGO="$BIN_DIR/hugo"
  echo "Installed hugo extended ${ver}."
}

resolve_hugo

# Primary LAN IP so the preview is reachable from other devices; else localhost.
lan_ip() {
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '%s' "${ip:-127.0.0.1}"
}

cd "$SCRIPT_DIR"

if [[ "$MODE" == build ]]; then
  echo "Building production site into ./public ..."
  rm -rf "$SCRIPT_DIR/public" "$SCRIPT_DIR/resources"
  "$HUGO" --minify
  echo "Done. Output in ./public"
else
  LAN_IP="$(lan_ip)"
  echo "Preview: http://$LAN_IP:$PORT  (Ctrl+C to stop)"
  "$HUGO" server \
    --buildDrafts --disableFastRender \
    --bind 0.0.0.0 --baseURL "http://$LAN_IP" --port "$PORT"
fi
