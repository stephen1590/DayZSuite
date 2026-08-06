#!/usr/bin/env bash
# own-verbs.test.sh - offline harness for dayz-ctl's generic owned-file verbs
# (own-read / own-write), the generic whole-file mechanism for owned config.
# Renders dayz-ctl.template with fixture values into a temp dir and exercises the verbs
# against a fake ServerDir. No box, no sudo, no network.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TPL="$HERE/../templates/dayz-ctl.template"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SD="$WORK/serverdir"
mkdir -p "$SD/profiles/ExpansionMod/Loadouts" "$SD/profiles/ExpansionMod/Settings" "$SD/custom-ce" "$SD/profiles/AI_Shared" "$SD/mpmissions/dayzOffline.test/expansion/settings"

# --- fixtures ---------------------------------------------------------------
echo '{"a":1,"sets":[{"x":2}]}'            > "$SD/profiles/ExpansionMod/Loadouts/TownLoadout.json"
echo '{"hostname":"t"}'                     > "$SD/server-settings.json"
echo '<types><type name="X"/></types>'      > "$SD/custom-ce/expansion_types.xml"   # reference - not owned
echo '{"gen":1}'                            > "$SD/profiles/AI_Shared/map-points.generated.json"
echo '{"parked":1}'                         > "$SD/profiles/ExpansionMod/Settings/AISettings.json"
echo 'SECRET=1'                             > "$SD/host.env"
echo '{"m_Version":1,"Patrols":[{"Name":"Alpha"},{"Name":"Bravo"}]}' > "$SD/mpmissions/dayzOffline.test/expansion/settings/AIPatrolSettings.json"
mkdir -p "$SD/profiles/users" "$SD/profiles/SomeMod"
echo '{"steam64":"765611"}'                 > "$SD/profiles/users/player.json"     # denied prefix
echo '{"free":1}'                           > "$SD/profiles/SomeMod/Extra.json"    # NO row anywhere - the flip's subject

# --- render the template with fixture masks ---------------------------------
python3 - "$TPL" "$WORK/dayz-ctl" "$SD" <<'PY'
import sys
tpl, out, sd = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(tpl).read()
vals = {
  '__UNIT__': 'fake.service', '__SERVER_DIR__': sd,
  '__CONFIG_MAP__': 'Server-settings\tserver-settings.json\tGeneral\tServer Settings\t0\tpatch\tSets global economy parameters\thttps://low.ms/knowledgebase/dayz-server-configuration\nexpansionTypesTuning\tcustom-ce/expansion_types_tuning.xml\tCustom CE\tExpansion Types Tuning\t0\ttypes\tCE loot tuning\t\nexpansionTypes\tcustom-ce/expansion_types.xml\tCustom CE\tExpansion Types (base)\t1\tview\tUpstream reference\t',
  '__CONFIG_DIRS__': '', '__IGNORE_EXT__': '', '__WRITE_MAP__': '',
  '__GENERATED__': 'profiles/AI_Shared/map-points.generated.json',
  '__DISABLED_TARGETS__': 'profiles/ExpansionMod/Settings/AISettings.json',
  '__OWNED_FILES__': 'server-settings.json\nban.txt\ncustom-ce/expansion_types_tuning.xml\nmpmissions/*/expansion/settings/AIPatrolSettings.json',
  '__OWNED_DIRS__': 'profiles/ExpansionMod/Loadouts\nprofiles/ExpansionMod/Settings',
  '__OWNED_CHECKS__': 'custom-ce/expansion_types_tuning.xml\tce-types\nmpmissions/*/expansion/settings/AIPatrolSettings.json\tai-patrols',
  '__DENY_LIST__': 'profiles/users\nstorage_',
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

# 3. own-read: an un-granted non-json/xml path refused, exit 2
$CTL own-read deploy/prestart.sh >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && ok "own-read refuses an un-granted non-json/xml path (exit 2)" || bad "own-read un-granted rc=$rc (want 2)"

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
# 17-19. config-list carries about + aboutUrl as fields 7-8. The editor renders these UNDER
# the filename, so a dropped column silently blanks the About block for every file.
out="$($CTL config-list 2>/dev/null | grep '^General	Server-settings	')"
n="$(printf '%s' "$out" | awk -F'\t' '{print NF}')"
[ "$n" = "8" ] && ok "config-list emits 8 TAB fields (about/aboutUrl appended)" \
  || bad "config-list field count is $n, want 8"
[ "$(printf '%s' "$out" | cut -f7)" = "Sets global economy parameters" ] \
  && ok "config-list field 7 = about text" || bad "config-list field 7 (about) wrong: $(printf '%s' "$out" | cut -f7)"
[ "$(printf '%s' "$out" | cut -f8)" = "https://low.ms/knowledgebase/dayz-server-configuration" ] \
  && ok "config-list field 8 = aboutUrl" || bad "config-list field 8 (aboutUrl) wrong: $(printf '%s' "$out" | cut -f8)"

echo
# 20-24. CAPTURE-ON-WRITE. A server/mod-made config must keep its ORIGINAL bytes the first
# time we modify it, so there is always a state-0 to roll back to.
#
# It has to happen IN THE WRITE VERB, before the replace: capturing at prestart instead would
# run AFTER the edit and freeze the EDIT itself as the baseline.
#
# own-write is replace-only (_own_check requires the file to exist), so every target
# pre-existed. That means no origin classification is needed: capture if missing, always.
orig='{"a":1,"orig":true}'
printf '%s' "$orig" > "$SD/profiles/ExpansionMod/Loadouts/CaptureMe.json"
rm -f "$SD/profiles/ExpansionMod/Loadouts/CaptureMe.defaults.json"

printf '{"a":2}' | $CTL own-write - profiles/ExpansionMod/Loadouts/CaptureMe.json >/dev/null 2>&1
[ -f "$SD/profiles/ExpansionMod/Loadouts/CaptureMe.defaults.json" ] \
  && ok "own-write captured a .defaults on first modification" || bad "no .defaults captured on first write"
[ "$(cat "$SD/profiles/ExpansionMod/Loadouts/CaptureMe.defaults.json")" = "$orig" ] \
  && ok "the captured default holds the ORIGINAL bytes, not the edit" \
  || bad "captured default is not the pre-edit content: $(cat "$SD/profiles/ExpansionMod/Loadouts/CaptureMe.defaults.json")"

# Second write must NOT re-capture - that would overwrite state 0 with state 1.
printf '{"a":3}' | $CTL own-write - profiles/ExpansionMod/Loadouts/CaptureMe.json >/dev/null 2>&1
[ "$(cat "$SD/profiles/ExpansionMod/Loadouts/CaptureMe.defaults.json")" = "$orig" ] \
  && ok "a later write does NOT re-capture (state 0 survives)" || bad "second write clobbered the default"

# A .defaults path is never itself a write target - the baseline must be immutable.
printf '{"evil":1}' | $CTL own-write - profiles/ExpansionMod/Loadouts/CaptureMe.defaults.json >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && ok "own-write refuses to target a .defaults path" || bad "a .defaults file was writable"

# A REFUSED write must not leave a default behind (no side effect on the failure path).
printf '%s' '{"z":9}' > "$SD/profiles/ExpansionMod/Loadouts/BadWrite.json"
rm -f "$SD/profiles/ExpansionMod/Loadouts/BadWrite.defaults.json"
printf '{broken' | $CTL own-write - profiles/ExpansionMod/Loadouts/BadWrite.json >/dev/null 2>&1
[ ! -f "$SD/profiles/ExpansionMod/Loadouts/BadWrite.defaults.json" ] \
  && ok "a rejected write captures nothing" || bad "invalid write still created a .defaults"

# 25-27. own-read SERVES a .defaults companion. Because OWNED_FILES is matched with grep -qxF
# and a companion is not itself a row, serving it needs an explicit fallback - that is the whole
# reason the side-by-side default view was impossible for file rows without one.
out="$($CTL own-read profiles/ExpansionMod/Loadouts/CaptureMe.defaults.json 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "own-read SERVES a .defaults companion (the side-by-side fix)" \
  || bad "own-read still refuses a .defaults (rc=$rc out=$out)"
[ "$(printf '%s\n' "$out" | sed -n 2p)" = "$orig" ] \
  && ok "own-read returns the ORIGINAL bytes from the companion" || bad "companion content wrong"

# ...but only when its STEM is an owned surface. A companion of a reference file stays refused.
$CTL own-read mpmissions/dayzOffline.sakhal/mapgroupproto.defaults.xml >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && ok "a .defaults whose stem is NOT owned is still refused" || bad "defaults of a non-owned file was served"

# own-write must NOT refuse on extension. The validation case already falls through for an
# unknown extension - the only thing blocking a .txt save is a separate refusal in _own_check,
# which is an ACCESS gate wearing a validator's clothes. An unrecognised type is a normal
# writable file that simply is not parse-checked.
printf '%s' '76561198000000000\n' > "$SD/ban.txt"
out="$(printf '76561198000000001\n' | $CTL own-write - ban.txt 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "own-write accepts a .txt (no file-type list)" \
  || bad "own-write still refuses an unknown extension (rc=$rc out=$out)"
[ "$(cat "$SD/ban.txt")" = "76561198000000001" ] \
  && ok "the .txt write actually landed" || bad ".txt content not written"
printf '%s' "$out" | grep -qi "not validated\|unvalidated" \
  && ok "an unvalidatable type WARNS rather than failing silently" || bad "no warning that the type was not validated"

# own-write must apply the CE STRUCTURAL check to a types surface, not just well-formedness:
# a half-pasted document can never reach the CE - root must be <types>, every child a
# <type name=...>.
mkdir -p "$SD/custom-ce"
printf '%s' '<types><type name="Nail"><nominal>10</nominal></type></types>' > "$SD/custom-ce/expansion_types_tuning.xml"
printf '%s' '<types><type name="Nail"><nominal>20</nominal></type></types>' | $CTL own-write - custom-ce/expansion_types_tuning.xml >/dev/null 2>&1
[ $? -eq 0 ] && ok "own-write accepts a valid CE types document" || bad "a valid types doc was refused"
# well-formed XML, but NOT a types document - this is what the structural check exists to stop
out="$(printf '%s' '<config><thing/></config>' | $CTL own-write - custom-ce/expansion_types_tuning.xml 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "own-write REFUSES well-formed XML that is not a CE types document" \
  || bad "a non-types XML reached a types surface (rc=$rc out=$out)"
grep -q 'name="Nail"><nominal>20' "$SD/custom-ce/expansion_types_tuning.xml" \
  && ok "the refused write left the previous types document intact" || bad "refused write damaged the file"

# --- config-owned reports which owned files have a CAPTURED BASELINE -------------------------
# An "edited" marker per file in the browsing view means "has been saved through the editor at
# least once", and the box already records exactly that - own-write captures a .defaults companion
# before its FIRST replace, so the companion existing IS the signal. No new verb: config-owned
# grows an 'E' line beside its F/D masks.
printf '%s' '{"a":1}' > "$SD/profiles/ExpansionMod/Loadouts/EditedOnce.json"
printf '%s' '{"a":0}' > "$SD/profiles/ExpansionMod/Loadouts/EditedOnce.defaults.json"
out="$($CTL config-owned 2>&1)"
printf '%s' "$out" | grep -qxF "$(printf 'E\tprofiles/ExpansionMod/Loadouts/EditedOnce.json')" \
  && ok "config-owned marks a file that has a captured baseline" || bad "no E line for an edited file (out=$out)"
# a witness nothing in this harness writes - TownLoadout.json is own-written by an earlier case,
# so the box captures a baseline for it and marking it edited is CORRECT, not a bug
printf '%s' '{"never":1}' > "$SD/profiles/ExpansionMod/Loadouts/NeverEdited.json"
out="$($CTL config-owned 2>&1)"
printf '%s' "$out" | grep -qxF "$(printf 'E\tprofiles/ExpansionMod/Loadouts/NeverEdited.json')" \
  && bad "an unedited file was marked as edited" || ok "a file with no baseline is NOT marked"
# the marker names the LIVE file, never the companion - the tree has no row for a .defaults
printf '%s' "$out" | grep -q "EditedOnce.defaults.json" \
  && bad "the .defaults companion leaked into the masks" || ok "the companion itself is never listed"
# and the existing masks still come through untouched
printf '%s' "$out" | grep -qxF "$(printf 'F\tserver-settings.json')" && ok "config-owned still emits its F masks" || bad "F masks regressed"
printf '%s' "$out" | grep -qxF "$(printf 'D\tprofiles/ExpansionMod/Loadouts')" && ok "config-owned still emits its D masks" || bad "D masks regressed"

# A glob OWNED_FILES row ('*' = the mission segment) resolves per-mission paths, so one registry
# row covers every mission instead of a hand-maintained row per mission.
PATS="mpmissions/dayzOffline.test/expansion/settings/AIPatrolSettings.json"
out="$($CTL own-read "$PATS" 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && [ "$(printf '%s' "$out" | head -1)" = "$(sha "$SD/$PATS")" ] \
  && ok "own-read resolves a glob-matched mission path" || bad "glob mission path not readable (rc=$rc)"

# own-write must run the ai-patrols structural check: object root, Patrols array, unique
# non-empty Names - the guard that stopped the duplicate-Name outage. JSON-valid is not enough.
good='{"m_Version":1,"Patrols":[{"Name":"Alpha"},{"Name":"Charlie"}]}'
out="$(printf '%s' "$good" | $CTL own-write - "$PATS" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(cat "$SD/$PATS")" = "$good" ] \
  && ok "own-write accepts a valid AIPatrolSettings doc via the glob row" || bad "valid patrols doc refused (rc=$rc out=$out)"
before="$(sha "$SD/$PATS")"
printf '%s' '{"Patrols":[{"Name":"Dup"},{"Name":"Dup"}]}' | $CTL own-write - "$PATS" >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(sha "$SD/$PATS")" = "$before" ] \
  && ok "own-write refuses duplicate patrol Names, file intact" || bad "duplicate Names not refused (rc=$rc)"
printf '%s' '{"NotPatrols":[]}' | $CTL own-write - "$PATS" >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(sha "$SD/$PATS")" = "$before" ] \
  && ok "own-write refuses a doc without the Patrols array" || bad "missing Patrols array not refused (rc=$rc)"

# --- THE FLIP: json/xml is editable by default; the exceptions are the masks -----------------
# A json file with NO registry row anywhere is readable and writable - the deny list, the
# generated mask, the disabled-mod mask and view-locked rows are the ONLY things that say no.
FREE="profiles/SomeMod/Extra.json"
out="$($CTL own-read "$FREE" 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && [ "$(printf '%s' "$out" | tail -n +2)" = '{"free":1}' ] \
  && ok "FLIP: an un-rowed json file is readable by default" || bad "un-rowed json not readable (rc=$rc)"
printf '%s' '{"free":2}' | $CTL own-write - "$FREE" >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(cat "$SD/$FREE")" = '{"free":2}' ] \
  && ok "FLIP: an un-rowed json file is writable by default" || bad "un-rowed json not writable (rc=$rc)"
# ...and it earns its edited-marker: the write captured a .defaults, and the E scan finds it
# without any mask membership.
$CTL config-owned 2>/dev/null | grep -qxF "$(printf 'E\t%s' "$FREE")" \
  && ok "config-owned marks the edited default-case (un-rowed) file" || bad "no E line for the flip-edited file"
# the deny list is the boundary - reads AND writes refused underneath it
$CTL own-read profiles/users/player.json >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && ok "denied path refused on read" || bad "denied path was READABLE"
printf '%s' '{"x":1}' | $CTL own-write - profiles/users/player.json >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && ok "denied path refused on write" || bad "denied path was WRITABLE"
# a view-locked row (CONFIG_MAP ro=1) stays read-only through the generic verbs too
out="$($CTL own-read custom-ce/expansion_types.xml 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && ok "view-locked row readable via own-read" || bad "view row not readable (rc=$rc)"
before="$(sha "$SD/custom-ce/expansion_types.xml")"
printf '%s' '<types><type name="Y"/></types>' | $CTL own-write - custom-ce/expansion_types.xml >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(sha "$SD/custom-ce/expansion_types.xml")" = "$before" ] \
  && ok "view-locked row refused on write, file intact" || bad "view-locked row was WRITABLE (rc=$rc)"
# a non-json/xml file with no explicit grant stays unreachable (host.env must never ride these verbs)
$CTL own-read host.env >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && ok "un-granted non-json/xml (host.env) still refused" || bad "host.env leaked through the flip"
# config-list now enumerates the un-rowed file, rw
out="$($CTL config-list 2>/dev/null)"
printf '%s' "$out" | grep -q "$FREE" && ok "config-list enumerates the un-rowed json" || bad "un-rowed json missing from config-list"
printf '%s' "$out" | grep -q "profiles/users/player.json" && bad "config-list lists a DENIED file" || ok "config-list hides denied paths"
printf '%s' "$out" | awk -F'\t' -v f="$FREE" '$4==f && $5=="0"{found=1} END{exit !found}' \
  && ok "the enumerated row is rw (ro=0)" || bad "enumerated row not rw"
printf '%s' "$out" | awk -F'\t' -v f="profiles/AI_Shared/map-points.generated.json" '$4==f && $5=="1"{found=1} END{exit !found}' \
  && ok "an enumerated generated file is ro=1" || bad "generated file not marked ro in enumeration"

echo "own-verbs: $pass passed, $fail failed"
[ $fail -eq 0 ]
