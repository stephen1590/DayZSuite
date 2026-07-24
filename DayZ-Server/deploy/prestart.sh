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
UPDATE_TIMEOUT=2400   # hard ceiling (40m) for an armed update; MUST stay below the unit's TimeoutStartSec so systemd never kills us mid-download

# Installed game-server APP build id, straight from the Steam manifest on disk. Shared by
# the deferred-update block below and mirrored by update-check.sh / dayz-ctl update-status.
installed_build() {
    local m="$SERVER/steamapps/appmanifest_223350.acf"
    [ -f "$m" ] || return 0
    # `|| true`: prestart runs under set -e — a missing buildid / SIGPIPE from head must not abort the boot.
    grep -oE '"buildid"[[:space:]]*"[0-9]+"' "$m" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true
}

# --- Deferred game/mod update -------------------------------------------------------
# If armed (.update-pending present — set by the API's `update` action or update-check.sh),
# pull the latest server app + mods NOW. The engine isn't up yet, so swapping the binary is
# safe, and the server was going down for this restart anyway — the update rides the reboot
# instead of being its own disruptive event. `timeout` caps the worst case so a slow/hung
# steamcmd can never brick the boot (a blocking ExecStartPre took the server down 2026-07-07);
# the outcome is recorded for the status surface and the flag is cleared either way. On
# failure we boot with whatever's on disk — update-check.sh re-arms next cycle if still
# behind, so failures retry on the check cadence, not on every single boot. Never exits.
if [ -f "$SERVER/.update-pending" ] && [ -x "$SERVER/update.sh" ]; then
    _ureason="$(head -1 "$SERVER/.update-pending" 2>/dev/null || true)"
    _ufrom="$(installed_build)"
    _ustarted="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _ulog="$SERVER/profiles/update-last.log"
    mkdir -p "$SERVER/profiles"
    echo "prestart: applying armed update ($_ureason)"
    set +e
    timeout "$UPDATE_TIMEOUT" bash "$SERVER/update.sh" > "$_ulog" 2>&1
    _urc=$?
    set -e
    _uto="$(installed_build)"
    _uok=0; [ "$_urc" -eq 0 ] && _uok=1
    {
        echo "startedAt=$_ustarted"
        echo "finishedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "exitCode=$_urc"
        echo "ok=$_uok"
        echo "fromBuild=${_ufrom:-}"
        echo "toBuild=${_uto:-}"
        echo "reason=$_ureason"
    } > "$SERVER/.update-lastrun"
    tail -n 80 "$_ulog" 2>/dev/null > "$SERVER/.update-lastlog" || true
    rm -f "$SERVER/.update-pending"
    if [ "$_uok" = 1 ]; then
        echo "prestart: update ok (build ${_ufrom:-?} -> ${_uto:-?})"
    else
        echo "prestart: update FAILED (exit $_urc, 124=timeout) — booting with existing files; see $_ulog" >&2
    fi
fi
# ------------------------------------------------------------------------------------

# Self-heal a deleted map.env from the deployed example (the ONE home of the default —
# no literal mission name here, so the default can't drift between seed sites).
[ -f "$SERVER/map.env" ] || cp "$SERVER/map.env.example" "$SERVER/map.env"
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

# Rebuild serverDZ.cfg = serverDZ.cfg.template + host.env passwords + server-settings.json's
# allowlisted toggles. Runs right AFTER Apply-ConfigOverrides so a web edit to
# server-settings.json is already patched in before we read it. The renderer refuses to write
# a half-rendered file (missing host.env, leftover placeholder), so the worst case is the
# previous serverDZ.cfg surviving unchanged - and the `|| true` keeps it off the boot path.
if [ -f "$SERVER/Apply-ServerCfg.ps1" ] && command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$SERVER/Apply-ServerCfg.ps1" -ServerDir "$SERVER" -Fix || true
fi
# If the cfg STILL doesn't exist here, the engine cannot boot and Restart=always will loop
# forever - that exact loop happened 2026-07-23 (renderer refused on a blank admin password
# while serverDZ.cfg was absent, so every boot failed with nothing naming the cause). We do
# NOT exit (prestart never blocks boot by doctrine; the engine fails either way) - but this
# line turns a mystery loop into a named error in journalctl.
if [ ! -f "$SERVER/serverDZ.cfg" ]; then
    echo "prestart: FATAL - serverDZ.cfg is missing and Apply-ServerCfg could not render it (check host.env: DEPLOY_ADMIN_PASSWORD must be non-empty; DEPLOY_SERVER_PASSWORD= empty is fine = open server). The engine cannot start without it - this boot WILL fail and systemd will keep retrying." >&2
fi

# Bubaku (SpawnerBubaku) composer RETIRED 2026-07-24: @babaku is disabled in mods.conf (it hung off
# the BanditAI cluster - all co-disabled), so composing its fixed-path spawn file every boot was dead
# work the unloaded mod never reads. Build-BabakuSpawns.ps1 + the per-map SpawnerBubaku sources stay
# in the repo (reversible, like the AI_Bandits tree). To restore: re-enable @babaku in mods.conf,
# un-comment the two lines below, its Test-Configs gate step, and its Deploy-DayZServer $items ship.
# The stale copy on the box is inert - remove whenever.
#if [ -f "$SERVER/Build-BabakuSpawns.ps1" ] && command -v pwsh >/dev/null 2>&1; then
#    pwsh -NoProfile -File "$SERVER/Build-BabakuSpawns.ps1" -ServerDir "$SERVER" -Mission "$TARGET" -Fix || true
#fi

# AI bandit configs (DynamicAIB/StaticAIB) are RAW per-map world coords, but the mod reads one
# fixed path. Compose the active map's flat config from common + maps/$TARGET NOW, before the
# engine reads it, so a map switch can never leave another map's coords in place. Fail-soft +
# `|| true`: a bad source can NEVER block server start; a map with no per-map file gets no bandits.
#
# BanditAI retired 2026-07-23; its compiler lives in archive/Build-AIBandits.ps1 (repo), with
# restore instructions in archive/README.md. The stale copy on the box is inert - remove whenever.

# Expansion AI draft builders (Build-AILocations / Build-AIPatrols) RETIRED 2026-07-23 (Phase 4,
# archive/). They composed *.draft.json PREVIEWS from the frozen authored map-points.json; nothing
# ever read the drafts (the mod reads the live AILocation/AIPatrolSettings.json). The inversion runs
# the other way now - Build-MapPoints below derives the map store FROM those live files.

# Map inversion Phase 2 (2026-07-23): derive the Map tab's point store FROM the active
# mission's live AILocationSettings/AIPatrolSettings (the web-edited truth). Writes
# profiles/AI_Shared/map-points.generated.json - registry 'generated', read-only in the UI.
# The authored map-points.json is frozen (archive/) and no longer rendered. Fail-soft +
# `|| true`: can never block boot; an unparseable source leaves the previous store untouched.
if [ -f "$SERVER/Build-MapPoints.ps1" ] && command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$SERVER/Build-MapPoints.ps1" -ServerDir "$SERVER" -Mission "$TARGET" -Fix || true
fi

# Common custom CE types (modded items, e.g. CodeLock): copy the map-agnostic custom_types.xml
# into the active mission's custom/ folder and register <ce folder="custom"> in its
# cfgeconomycore.xml, idempotently - the vanilla db/types.xml is never touched, so a game update
# can't drop the types. Fail-soft + `|| true`: can never block boot.
if [ -f "$SERVER/Apply-CustomCE.ps1" ] && command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$SERVER/Apply-CustomCE.ps1" -ServerDir "$SERVER" -Mission "$TARGET" -Fix || true
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

# Map-transfer safe spawn (server-only TransferSpawn mod). A "transfer generation" bumps on
# every mission switch; the mod relocates each existing character ONCE per generation to one
# of the new map's own spawn points, so a migrated character never keeps a stale old-map
# position. The counter persists in .transfer-gen; the active map's points + current gen are
# handed to the mod as profiles/transfer_spawn.json (rewritten every boot so a map switch
# always ships the new map's points). Fail-soft + `|| true`: never blocks server start.
GENFILE="$SERVER/.transfer-gen"
TGEN=$(cat "$GENFILE" 2>/dev/null || echo 0)
case "$TGEN" in ''|*[!0-9]*) TGEN=0 ;; esac
[ "$TARGET" != "$LAST" ] && TGEN=$((TGEN + 1))
echo "$TGEN" > "$GENFILE"
if [ -f "$SERVER/Build-TransferSpawns.ps1" ] && command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$SERVER/Build-TransferSpawns.ps1" -ServerDir "$SERVER" -Mission "$TARGET" -Gen "$TGEN" -Fix || true
fi

echo "$TARGET" > "$STATE"
