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

# mods.conf is the ONE owner of mod enablement - nothing else may hold a copy of that state.
# Every consumer DERIVES from it: Deploy-Api renders dayz-ctl's DISABLED_TARGETS from it, the
# web editor drops a surface whose registry 'mod' is disabled, and prestart gates mod-specific
# build steps through this function. Never hand-sync a second copy of this fact.
#
# Enabled = a line whose FIRST token is exactly the @folder. The word boundary matters:
# a bare substring match would let '@expansioncore' satisfy a check for '@expansion' and
# silently keep a retired step running. Commented lines (leading #, indented or not) are
# disabled, which is exactly how mods.conf already expresses "off".
# FAIL-OPEN when mods.conf is absent: prestart must never block boot on a missing file
# (a failing ExecStartPre took the server down 2026-07-07).
mod_enabled() {
    [ -f "$SERVER/mods.conf" ] || return 0
    grep -qE "^[[:space:]]*$1([[:space:]]|\$)" "$SERVER/mods.conf"
}

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

# NOTE (2026-08-01): the frozen-default capture used to run HERE. It is REMOVED, and must not
# come back. Capturing at prestart reads the file's CURRENT content - i.e. AFTER whatever edit
# prompted the boot - so it froze the EDIT as the "baseline" and every diff against it showed
# nothing. Proven twice on prod: expansion_types_tuning.xml and its .defaults were byte-identical
# with the same mtime, and five out-of-scope defaults archived off the box were re-created here,
# from live content, at the very next restart.
#
# Capture belongs in the WRITE path, which is the only place that sees the bytes BEFORE they are
# replaced: dayz-ctl own-write now captures <stem>.defaults.<ext> when none exists (2026-08-01).
# Owner's rule: a server-made file needs its original kept when a change is made; a generated
# file or one we authored never needs one. Nothing is left uncovered - the surfaces still edited
# through the bespoke verbs (types-write / file-write / spawn-write) are all files we author.

# NOTE (2026-07-31): the field-override applier used to run HERE, between the default capture
# and the serverDZ.cfg render. It is deleted - owner's ruling: "No Overrides. Just whole file
# ownership and modifying with a better UI/Syntax manager." Config files are now owned whole
# and edited directly through the web editor; nothing patches them at boot any more. Do not
# reintroduce a patch step: a second writer on a file it does not own is the drift machine
# this removal exists to end.

# Rebuild serverDZ.cfg = serverDZ.cfg.template + host.env passwords + server-settings.json's
# allowlisted toggles. server-settings.json is now edited whole in the web UI, so what we read
# here IS what the operator saved - no patch pass in between. The renderer refuses to write
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

# Bubaku (SpawnerBubaku) composer - gated on @babaku being ENABLED in mods.conf, nothing else.
# Disabling the mod is now ONE edit (comment the line in mods.conf); this step, the config
# surfaces the web editor shows, and dayz-ctl's write guard all derive from that single fact.
# It used to take three hand-synced edits (mods.conf + this call site + the deploy ship list)
# and nothing kept them in agreement.
if mod_enabled '@babaku' && [ -f "$SERVER/Build-BabakuSpawns.ps1" ] && command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$SERVER/Build-BabakuSpawns.ps1" -ServerDir "$SERVER" -Mission "$TARGET" -Fix || true
fi

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
