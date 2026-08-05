#!/usr/bin/env bash
# prestart-mod-gate.test.sh - harness for prestart.sh's mod_enabled() gate.
#
# WHY THIS EXISTS (the project's core thesis - one concept, ONE owner):
# mods.conf is the ONLY place mod enablement is written; prestart DERIVES execution from it
# through this one function. Disabling a mod any other way - a ship-list edit, a commented-out
# call site - creates a second copy of the same fact that nothing keeps in sync, and leaves a
# retired step as an unmanaged orphan on the box.
#
# Extracts mod_enabled() out of prestart.sh and exercises it against fixture mods.conf files.
# No box, no sudo, no network.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PRESTART="$HERE/../deploy/prestart.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  [PASS] $1"; }
bad() { fail=$((fail+1)); echo "  [FAIL] $1"; }

# Pull just the function out of prestart.sh so the rest of the boot script never runs.
sed -n '/^mod_enabled()/,/^}/p' "$PRESTART" > "$WORK/fn.sh"
if [ ! -s "$WORK/fn.sh" ]; then
  echo "  [FAIL] mod_enabled() not found in deploy/prestart.sh"
  echo ""
  echo "prestart-mod-gate: 0 passed, 1 failed"
  exit 1
fi
# shellcheck disable=SC1090
. "$WORK/fn.sh"

cat > "$WORK/mods.conf" <<'EOF'
# comment header describing the format
@cf                          1559212036
@expansioncore               2116157322
@expansion                   2572331007
#@babaku                     2482312670
#@knockknock                 3638393043   # disabled under the config
  #@aibandits                3628006769
@codelock                    1834157940
EOF

SERVER="$WORK"

# 1-2. enabled mods are detected
mod_enabled '@cf'          && ok "enabled mod detected (@cf)"        || bad "@cf reported disabled"
mod_enabled '@codelock'    && ok "enabled mod detected (@codelock)"  || bad "@codelock reported disabled"

# 3-5. commented-out mods are disabled, including indented and trailing-comment forms
mod_enabled '@babaku'      && bad "@babaku reported ENABLED (it is commented out)" || ok "commented mod is disabled (@babaku)"
mod_enabled '@knockknock'  && bad "@knockknock reported ENABLED"                   || ok "commented mod with trailing comment is disabled (@knockknock)"
mod_enabled '@aibandits'   && bad "@aibandits reported ENABLED (indented comment)" || ok "indented commented mod is disabled (@aibandits)"

# 6. PREFIX SAFETY: '@expansion' must not be satisfied by '@expansioncore'. A naive grep for
#    the bare name matches every longer sibling and would silently keep a retired step alive.
mod_enabled '@expansion'   && ok "exact match works (@expansion present in its own right)" || bad "@expansion missed"
cat > "$WORK/mods.conf" <<'EOF'
@expansioncore               2116157322
EOF
mod_enabled '@expansion'   && bad "PREFIX BUG: '@expansion' matched '@expansioncore'" || ok "prefix safety: @expansion does not match @expansioncore"

# 7. a mod absent from the file entirely is disabled
mod_enabled '@nosuchmod'   && bad "absent mod reported enabled" || ok "absent mod is disabled"

# 8. FAIL-OPEN when mods.conf is missing: prestart must never block boot on a missing file
#    (a failing ExecStartPre can take the server down).
rm -f "$WORK/mods.conf"
mod_enabled '@anything'    && ok "missing mods.conf fails OPEN (never blocks boot)" || bad "missing mods.conf failed closed - can block boot"

echo ""
echo "prestart-mod-gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
