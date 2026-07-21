#!/bin/bash
# update-check.sh — the AUTO half of the update system. Run on a timer
# (dayz-update-check.timer) as the game user. It NEVER updates or restarts anything;
# it only compares build ids and, if the game server app is behind, ARMS a deferred
# update (writes .update-pending). The actual download happens on the next server
# start, inside prestart.sh — see that file. This keeps the disruptive part (steamcmd +
# a fresh binary) riding the reboot the server was going to do anyway.
#
# What it detects: the DayZ Dedicated Server APP build id (appid 223350) vs Steam's
# latest for the public branch. It does NOT detect workshop-MOD updates — those are
# caught by Deploy's missing-mod path / a manual update.sh run. Game patches (the ones
# that version-lock clients out) are exactly the app-build case this covers.
#
# Self-locating, same layout as update.sh:  ~/servers/{dayz-server (this dir), steamcmd, steamhome}
# The steamcmd app_info call opens a Steam SESSION (bumping any live session of the
# account) each run — keep the timer interval sane. Fail-soft throughout: a check that
# can't reach Steam or can't parse a build id changes NOTHING (never arms on a guess).
set -uo pipefail

SERVER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVERS="$(dirname -- "$SERVER")"
STEAMCMD="$SERVERS/steamcmd/steamcmd.sh"
STEAM_ACCOUNT={{DEPLOY_STEAM_ACCOUNT}}   # owns DayZ; rendered from host.env by Deploy-DayZServer.ps1
APPID=223350
UNIT=dayz-server
MANIFEST="$SERVER/steamapps/appmanifest_${APPID}.acf"

export HOME="$SERVERS/steamhome"
export XDG_DATA_HOME="$HOME/.local/share"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Installed build id: the buildid recorded in the Steam app manifest on disk.
installed_build() {
  [ -f "$MANIFEST" ] || return 0
  grep -oE '"buildid"[[:space:]]*"[0-9]+"' "$MANIFEST" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true
}

# Latest build id for the PUBLIC branch, from Steam's app info. app_info_update forces a
# fresh pull (steamcmd otherwise serves stale cache). We isolate the "public" branch block
# (guarded by first seeing "branches", so a stray "public" elsewhere can't match) and take
# its buildid. mawk-safe: no gawk-only match() array, just a small line window + grep.
latest_build() {
  [ -x "$STEAMCMD" ] || return 0
  local info
  info="$("$STEAMCMD" +@ShutdownOnFailedCommand 1 +force_install_dir "$SERVER/" \
            +login "$STEAM_ACCOUNT" +app_info_update 1 +app_info_print "$APPID" +quit 2>/dev/null)" || true
  printf '%s\n' "$info" | awk '
    /"branches"/ { inbr=1 }
    inbr && /"public"/ { want=6; next }
    want>0 { if ($0 ~ /"buildid"/) { print; exit } want-- }
  ' | grep -oE '[0-9]+' | head -1
}

installed="$(installed_build)"
latest="$(latest_build)"
ok=0; [ -n "$latest" ] && ok=1

# Record the check for the status surface (dayz-ctl update-status reads this file).
{
  echo "installedBuild=${installed:-}"
  echo "latestBuild=${latest:-}"
  echo "checkedAt=$(now_iso)"
  echo "checkOk=$ok"
} > "$SERVER/.update-check"

# Nothing to do unless we got a real latest that differs from installed.
[ "$ok" = 1 ] || { echo "update-check: could not determine latest build (Steam unreachable / parse failed) — no change"; exit 0; }
[ -n "$installed" ] || { echo "update-check: no installed build id (appmanifest missing?) — no change"; exit 0; }
if [ "$latest" = "$installed" ]; then
  echo "update-check: up to date (build $installed)"
  exit 0
fi

# Behind. Arm the deferred update — but only once: an existing .update-pending means we
# already armed (manually or a prior check), so don't rewrite it or re-broadcast every run.
if [ -f "$SERVER/.update-pending" ]; then
  echo "update-check: build $latest available (installed $installed) — already armed, leaving .update-pending as-is"
  exit 0
fi

printf 'auto: build %s available (installed %s) - queued %s\n' "$latest" "$installed" "$(now_iso)" \
  > "$SERVER/.update-pending"
echo "update-check: armed deferred update — build $installed -> $latest (applies on next server start)"

# One-time heads-up to anyone online. Best-effort: no RCon (server down / not configured)
# just means no message — the update still applies on the next start regardless.
if [ "$(systemctl is-active "$UNIT" 2>/dev/null || true)" = active ] && [ -f "$SERVER/dayz-rcon.ps1" ] && command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File "$SERVER/dayz-rcon.ps1" "$SERVER" \
    "say -1 [SERVER] A game update is queued - it applies automatically at the next scheduled restart." >/dev/null 2>&1 || true
fi
