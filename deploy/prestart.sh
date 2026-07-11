#!/bin/bash
# Map lifecycle hook — run by systemd (ExecStartPre) before each server start.
#   1) Backs up the active mission's storage_1 (players.db + world data) to ./backups,
#      keeping the newest 10 per mission.
#   2) If map.env selects a different mission than last start: characters follow the
#      server — players.db is copied to the new mission's storage. Positions are raw
#      map coordinates, so teleport players to sane spots after their first login.
# Local file operations only: no steamcmd, so no Steam session impact.
# Self-locating (derives SERVER from its own path) — same file works on any host.
set -euo pipefail

SERVER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MISSIONS=$SERVER/mpmissions
STATE=$SERVER/.last-map
KEEP=10        # storage backups per mission
KEEP_LOGS=40   # raw RPT/ADM safety net only — dayz-logarchive.timer zips dead logs daily; this must stay well above one day's boot count so pruning never beats the archiver

[ -f "$SERVER/map.env" ] || echo "DAYZ_MISSION=dayzOffline.chernarusplus" > "$SERVER/map.env"
source "$SERVER/map.env"
TARGET=$DAYZ_MISSION
LAST=$(cat "$STATE" 2>/dev/null || echo "$TARGET")

backup() {
    local st="$MISSIONS/$1/storage_1" dir="$SERVER/backups/$1"
    [ -d "$st" ] || return 0
    mkdir -p "$dir"
    tar -czf "$dir/storage_1-$(date +%Y%m%d_%H%M%S).tar.gz" -C "$MISSIONS/$1" storage_1
    # || true: with pipefail, ls exits 2 when a glob matches nothing — best-effort
    # pruning must never block server start (took the server down 2026-07-07)
    ls -t "$dir"/storage_1-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -- || true
}

# Keep the native restart/notice config present in whichever mission is active —
# messages.xml is per-mission (db/), so a map switch would otherwise silently drop
# the 4-hour restart schedule. Deployed to $SERVER/messages.xml by Deploy.
if [ -f "$SERVER/messages.xml" ]; then
    cp -f "$SERVER/messages.xml" "$MISSIONS/$TARGET/db/messages.xml"
fi

# Field-level config overrides: patch our deltas (config-overrides.json) into the live
# CE/mod files NOW, before the engine reads them at boot, so overrides survive mod/game
# updates and an admin can just edit the manifest + restart. The applier is fail-soft
# per-field; the `|| true` guarantees a bad override can NEVER block server start (a
# failing ExecStartPre took the server down 2026-07-07). Applies to all missions' files.
if [ -f "$SERVER/Apply-ConfigOverrides.ps1" ] && command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$SERVER/Apply-ConfigOverrides.ps1" -ServerDir "$SERVER" -Fix || true
fi

# AI bandit configs (DynamicAIB/StaticAIB) are RAW per-map world coords, but the mod reads one
# fixed path. Compose the active map's flat config from common + maps/$TARGET NOW, before the
# engine reads it, so a map switch can never leave another map's coords in place. Fail-soft +
# `|| true`: a bad source can NEVER block server start; a map with no per-map file gets no bandits.
if [ -f "$SERVER/Build-AIBandits.ps1" ] && command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$SERVER/Build-AIBandits.ps1" -ServerDir "$SERVER" -Mission "$TARGET" -Fix || true
fi

# Server-log retention: each boot writes fresh RPT/ADM/mdmp into profiles/; with 4h
# scheduled restarts that's ~6/day forever. Keep the newest KEEP_LOGS of each.
for pat in '*.RPT' '*.ADM' '*.mdmp'; do
    ls -t "$SERVER/profiles/"$pat 2>/dev/null | tail -n +$((KEEP_LOGS + 1)) | xargs -r rm -- || true
done

backup "$LAST"

if [ "$TARGET" != "$LAST" ]; then
    backup "$TARGET"    # its players.db is about to be overwritten — keep a copy
    if [ -f "$MISSIONS/$LAST/storage_1/players.db" ]; then
        mkdir -p "$MISSIONS/$TARGET/storage_1"
        cp -f "$MISSIONS/$LAST/storage_1/players.db" "$MISSIONS/$TARGET/storage_1/players.db"
        echo "Map switch $LAST -> $TARGET: players.db migrated (teleport players after first login)"
    else
        echo "Map switch $LAST -> $TARGET: no players.db to migrate"
    fi
fi
echo "$TARGET" > "$STATE"
