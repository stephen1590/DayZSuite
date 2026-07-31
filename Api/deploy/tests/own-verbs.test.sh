#!/usr/bin/env bash
# own-verbs.test.sh - offline TDD harness for dayz-ctl's generic owned-file verbs
# (own-read / own-write), the Phase 1 mechanism of the CONFIG-ARCHITECTURE.md migration.
# Renders dayz-ctl.template with fixture values into a temp dir and exercises the verbs
# against a fake ServerDir. No box, no sudo, no network. Written BEFORE the implementation
# (TDD): first run must FAIL with "unknown verb".
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TPL="$HERE/../templates/dayz-ctl.template"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SD="$WORK/serverdir"
mkdir -p "$SD/profiles/ExpansionMod/Loadouts" "$SD/profiles/ExpansionMod/Settings" "$SD/custom-ce" "$SD/profiles/AI_Shared"

# --- fixtures ---------------------------------------------------------------
echo '{"a":1,"sets":[{"x":2}]}'            > "$SD/profiles/ExpansionMod/Loadouts/TownLoadout.json"
echo '{"hostname":"t"}'                     > "$SD/server-settings.json"
echo '<types><type name="X"/></types>'      > "$SD/custom-ce/expansion_types.xml"   # reference - not owned
echo '{"gen":1}'                            > "$SD/profiles/AI_Shared/map-points.generated.json"
echo '{"parked":1}'                         > "$SD/profiles/ExpansionMod/Settings/AISettings.json"
echo 'SECRET=1'                             > "$SD/host.env"

# --- render the template with fixture masks ---------------------------------
python3 - "$TPL" "$WORK/dayz-ctl" "$SD" <<'PY'
import sys
tpl, out, sd = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(tpl).read()
vals = {
  '__UNIT__': 'fake.service', '__SERVER_DIR__': sd,
  '__CONFIG_MAP__': 'Server-settings\tserver-settings.json\tGeneral\tServer Settings\t0\tpatch\tSets global economy parameters\thttps://low.ms/knowledgebase/dayz-server-configuration',
  '__CONFIG_DIRS__': '', '__IGNORE_EXT__': '', '__WRITE_MAP__': '',
  '__GENERATED__': 'profiles/AI_Shared/map-points.generated.json',
  '__DISABLED_TARGETS__': 'profiles/ExpansionMod/Settings/AISettings.json',
  '__OWNED_FILES__': 'server-settings.json',
  '__OWNED_DIRS__': 'profiles/ExpansionMod/Loadouts\nprofiles/ExpansionMod/Settings',
  '__LOG_NOISE__': '', '__DOCS_ROOTS__': '', '__DOCS_EXT__': '', '__DOCS_NAMES__': '',
  '__DOCS_MAXDEPTH__': '3', '__LOG_SOURCES__': '',
}
for k, v in vals.items(): t = t.replace(k, v)
open(out, 'w').write(t)
PY
chmod +x "$WORK/dayz-ctl"
CTL="bash $WORK/dayz-ctl"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  [PASS] $1"; }
bad()  { fail=$((fail+1)); echo "  [FAIL] $1"; }
sha()  { sha256sum "$1" | awk '{print $1}'; }

# --- tests ------------------------------------------------------------------
# 1. own-read: owned file -> line1 sha, rest raw content
out="$($CTL own-read server-settings.json 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && [ "$(printf '%s' "$out" | head -1)" = "$(sha "$SD/server-settings.json")" ] \
  && [ "$(printf '%s' "$out" | tail -n +2)" = '{"hostname":"t"}' ] \
  && ok "own-read owned file: sha + raw content" || bad "own-read owned file (rc=$rc)"

# 2. own-read: file under an owned DIR
out="$($CTL own-read profiles/ExpansionMod/Loadouts/TownLoadout.json 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && ok "own-read under owned dir" || bad "own-read under owned dir (rc=$rc)"

# 3. own-read: NON-owned (reference) path refused, exit 2
$CTL own-read custom-ce/expansion_types.xml >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && ok "own-read refuses non-owned path (exit 2)" || bad "own-read non-owned rc=$rc (want 2)"

# 4. own-write: valid JSON to owned-dir file -> ok, new sha printed, content replaced
new='{"a":9,"sets":[{"x":3}]}'
out="$(printf '%s' "$new" | $CTL own-write - profiles/ExpansionMod/Loadouts/TownLoadout.json 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(cat "$SD/profiles/ExpansionMod/Loadouts/TownLoadout.json")" = "$new" ] \
  && [ "$(printf '%s\n' "$out" | sed -n 2p)" = "$(sha "$SD/profiles/ExpansionMod/Loadouts/TownLoadout.json")" ] \
  && ok "own-write valid JSON: replaced + new sha on line 2" || bad "own-write valid JSON (rc=$rc out=$out)"

# 5. snapshot of the OUTGOING version exists in .own-versions/
snap="$(ls "$SD/.own-versions/" 2>/dev/null | grep -c 'TownLoadout')"
[ "${snap:-0}" -ge 1 ] && ok "own-write snapshotted the outgoing version" || bad "no snapshot in .own-versions/"

# 6. own-write: INVALID JSON refused, file unchanged
before="$(sha "$SD/profiles/ExpansionMod/Loadouts/TownLoadout.json")"
printf '{broken' | $CTL own-write - profiles/ExpansionMod/Loadouts/TownLoadout.json >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(sha "$SD/profiles/ExpansionMod/Loadouts/TownLoadout.json")" = "$before" ] \
  && ok "own-write refuses invalid JSON, file untouched" || bad "invalid JSON not refused (rc=$rc)"

# 7. own-write: stale base= -> exit 5 (conflict), file unchanged
printf '{"v":1}' | $CTL own-write - server-settings.json base=deadbeef >/dev/null 2>&1; rc=$?
[ $rc -eq 5 ] && [ "$(cat "$SD/server-settings.json")" = '{"hostname":"t"}' ] \
  && ok "own-write stale base= -> exit 5, untouched" || bad "stale base rc=$rc (want 5)"

# 8. own-write: correct base= succeeds
printf '{"v":2}' | $CTL own-write - server-settings.json "base=$(sha "$SD/server-settings.json")" >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(cat "$SD/server-settings.json")" = '{"v":2}' ] \
  && ok "own-write correct base= succeeds" || bad "correct base rc=$rc"

# 9. GENERATED path refused even though under an owned-adjacent tree
printf '{"g":2}' | $CTL own-write - profiles/AI_Shared/map-points.generated.json >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(cat "$SD/profiles/AI_Shared/map-points.generated.json")" = '{"gen":1}' ] \
  && ok "own-write refuses generated artifact" || bad "generated not refused (rc=$rc)"

# 10. DISABLED-mod target refused
printf '{"d":2}' | $CTL own-write - profiles/ExpansionMod/Settings/AISettings.json >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(cat "$SD/profiles/ExpansionMod/Settings/AISettings.json")" = '{"parked":1}' ] \
  && ok "own-write refuses disabled-mod target" || bad "disabled target not refused (rc=$rc)"

# 11. traversal + .env refused
printf 'x' | $CTL own-write - ../outside.json  >/dev/null 2>&1; [ $? -ne 0 ] && ok "traversal refused" || bad "traversal accepted"
printf 'x' | $CTL own-write - host.env         >/dev/null 2>&1; [ $? -ne 0 ] && [ "$(cat "$SD/host.env")" = 'SECRET=1' ] && ok ".env refused" || bad ".env accepted"
$CTL own-read host.env >/dev/null 2>&1; [ $? -ne 0 ] && ok "own-read .env refused" || bad "own-read .env accepted"

# 12. replace-only: absent file under owned dir refused (no create)
printf '{"n":1}' | $CTL own-write - profiles/ExpansionMod/Loadouts/NewLoadout.json >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -f "$SD/profiles/ExpansionMod/Loadouts/NewLoadout.json" ] \
  && ok "own-write is replace-only (no create)" || bad "own-write created a new file"

# 13. XML: well-formed accepted on an owned .xml, malformed refused
echo '<x/>' > "$SD/profiles/ExpansionMod/Loadouts/probe.xml"
printf '<a><b/></a>' | $CTL own-write - profiles/ExpansionMod/Loadouts/probe.xml >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "own-write accepts well-formed XML" || bad "well-formed XML refused (rc=$rc)"
printf '<a><b>'     | $CTL own-write - profiles/ExpansionMod/Loadouts/probe.xml >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && ok "own-write refuses malformed XML" || bad "malformed XML accepted"

echo
# 17-19. config-list carries about + aboutUrl as fields 7-8 (2026-07-30). The editor renders
# these UNDER the filename, so a dropped column silently blanks the About block for every file.
out="$($CTL config-list 2>/dev/null | grep '^General	Server-settings	')"
n="$(printf '%s' "$out" | awk -F'\t' '{print NF}')"
[ "$n" = "8" ] && ok "config-list emits 8 TAB fields (about/aboutUrl appended)" \
  || bad "config-list field count is $n, want 8"
[ "$(printf '%s' "$out" | cut -f7)" = "Sets global economy parameters" ] \
  && ok "config-list field 7 = about text" || bad "config-list field 7 (about) wrong: $(printf '%s' "$out" | cut -f7)"
[ "$(printf '%s' "$out" | cut -f8)" = "https://low.ms/knowledgebase/dayz-server-configuration" ] \
  && ok "config-list field 8 = aboutUrl" || bad "config-list field 8 (aboutUrl) wrong: $(printf '%s' "$out" | cut -f8)"

echo "own-verbs: $pass passed, $fail failed"
[ $fail -eq 0 ]
