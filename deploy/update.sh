#!/bin/bash
# DayZ server + mods updater — auto-run by Deploy-DayZServer.ps1 -Fix when mods are
# missing; run manually on game-patch days. The steamcmd login bumps the account's
# other Steam session — the deploy player-guard covers this server, but it still kicks
# that account anywhere else. Follow a manual run with: sudo systemctl restart dayz-server
#
# Self-locating: every path derives from where THIS script lives, so the same file
# works unchanged on any host — no per-host edits.
# Expected layout:  ~/servers/{dayz-server (this dir), steamcmd, steamhome}
#
# One-time interactive login first (password + Steam Guard), using the same HOME:
#   HOME=~/servers/steamhome ~/servers/steamcmd/steamcmd.sh +login <account> +quit
set -euo pipefail

SERVER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVERS="$(dirname -- "$SERVER")"                  # ~/servers
STEAMCMD="$SERVERS/steamcmd/steamcmd.sh"
STEAM_ACCOUNT={{DEPLOY_STEAM_ACCOUNT}}              # account that OWNS DayZ (anonymous fails); rendered from host.env by Deploy-DayZServer.ps1
WORKSHOP="$SERVER/steamapps/workshop/content/221100"

# Isolated HOME: the desktop Steam client shares ~/.local/share/Steam and clobbers
# steamcmd's cached login; keeping steamcmd's data here makes the two independent.
export HOME="$SERVERS/steamhome"
export XDG_DATA_HOME="$HOME/.local/share"

# The mod set lives in mods.conf (shipped next to this script) — ONE registry for
# enable/disable/order; this script only executes it. Parse enabled lines into the
# required/optional id lists ('optional' = best-effort, e.g. delisted items).
MODS_CONF="$SERVER/mods.conf"
[ -f "$MODS_CONF" ] || { echo "ERROR: $MODS_CONF missing — deploy it (single mod registry)"; exit 1; }
REQUIRED_ITEMS=""; OPTIONAL_ITEMS=""
while read -r line; do
    line="${line%%#*}"                          # strip comments (whole-line and inline)
    set -- $line; folder="${1:-}"; id="${2:-}"; flag="${3:-}"
    [ -n "$folder" ] || continue
    if [ "$flag" = "optional" ]; then OPTIONAL_ITEMS="$OPTIONAL_ITEMS $id"
    else REQUIRED_ITEMS="$REQUIRED_ITEMS $id"; fi
done < "$MODS_CONF"

# ONE steamcmd session for the app + every workshop item. Auth is the cached token
# (the one-time interactive login) — no password/Guard prompt — but each steamcmd
# invocation still opens a Steam SESSION (bumping any live session of the account),
# so the happy path is exactly one. Exit code ignored: steamcmd's is unreliable and
# a single failed item must not abort the chain — presence is verified per-dir below.

dl_args=(+app_update 223350)
for id in $REQUIRED_ITEMS $OPTIONAL_ITEMS; do dl_args+=(+workshop_download_item 221100 "$id"); done
"$STEAMCMD" +force_install_dir "$SERVER/" +login "$STEAM_ACCOUNT" "${dl_args[@]}" +quit || true

# Targeted retries ONLY for items the single pass didn't land (downloads resume
# across sessions). Historic failure cause was broken IPv6 to the Steam CDN — see
# README; if retries loop here, check /etc/gai.conf v4 precedence first.
retry_item() {
    local id=$1 tries=3 n
    for ((n = 1; n <= tries; n++)); do
        echo "workshop $id: missing after main pass — retry $n/$tries"
        "$STEAMCMD" +force_install_dir "$SERVER/" +login "$STEAM_ACCOUNT" \
            +workshop_download_item 221100 "$id" +quit || true
        [ -d "$WORKSHOP/$id" ] && return 0
    done
    echo "ERROR: workshop item $id failed after $tries retries"
    return 1
}

for id in $REQUIRED_ITEMS; do
    [ -d "$WORKSHOP/$id" ] || retry_item "$id"       # set -e aborts the run on required-item failure
done
for id in $OPTIONAL_ITEMS; do
    [ -d "$WORKSHOP/$id" ] || retry_item "$id" \
        || echo "WARN: optional workshop item $id unavailable — drop its @mod from the unit -mod line if it stays gone"
done

# Copy each mod out of steamapps (kept pristine for steamcmd's own bookkeeping),
# lowercase everything (the Linux server is case-sensitive, workshop mods aren't),
# then drop the mod's .bikey into the server keys dir.
sync_mod() {
    src="$WORKSHOP/$1"
    dst="$SERVER/$2"
    [ -d "$src" ] || { echo "ERROR: workshop item $1 not downloaded"; return 1; }
    rsync -a --delete "$src/" "$dst/"
    find "$dst" -depth | while IFS= read -r p; do
        b=$(basename "$p")
        l=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
        [ "$b" = "$l" ] || mv -T "$p" "$(dirname "$p")/$l"
    done
    # Mods ship their bikey under keys/ OR key/ (BBP uses key/); some server-side mods ship none.
    cp -f "$dst"/keys/*.bikey "$dst"/key/*.bikey "$SERVER/keys/" 2>/dev/null || true
}

# Sync every enabled mod from mods.conf. A required mod that failed to download aborts
# the run (set -e); an 'optional' one only warns — it must never block a game update.
while read -r line; do
    line="${line%%#*}"
    set -- $line; folder="${1:-}"; id="${2:-}"; flag="${3:-}"
    [ -n "$folder" ] || continue
    if [ "$flag" = "optional" ]; then
        sync_mod "$id" "$folder" \
            || echo "WARN: optional $folder not synced — disable it in mods.conf if it stays unavailable"
    else
        sync_mod "$id" "$folder"
    fi
done < "$MODS_CONF"
