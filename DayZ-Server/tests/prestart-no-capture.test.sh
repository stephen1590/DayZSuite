#!/usr/bin/env bash
# prestart must NOT capture .defaults. Capture belongs in the WRITE verb.
#
# WHY (owner ruling 2026-08-01, proven on prod the same day): Capture-OwnedDefaults runs at
# prestart, so it captures from the file's CURRENT content - i.e. AFTER any edit - and freezes
# the edit as the "baseline". Five out-of-scope defaults were archived off prod and prestart
# RE-CREATED all five at the next restart, from live content, same self-referential copies.
#
# own-write now captures state 0 before the first replace (dayz-ctl own-write, 2026-08-01), and
# that is the only path that captures at the right moment. Prestart capture is not a backstop -
# it is a second writer that produces WRONG baselines, so it goes.
#
# Files edited through the remaining bespoke verbs (types-write / file-write / spawn-write) are
# all files WE author - the CE tuning pair, bans/allowlist, the map store - and the owner's rule
# is that authored files need no state 0. So nothing is left uncovered by this removal.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESTART="$HERE/../deploy/prestart.sh"
DEPLOY="$HERE/../Deploy-DayZServer.ps1"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  [PASS] $1"; }
bad() { fail=$((fail+1)); echo "  [FAIL] $1"; }

[ -f "$PRESTART" ] || { echo "prestart.sh not found at $PRESTART"; exit 1; }

grep -q 'Capture-OwnedDefaults' "$PRESTART" \
  && bad "prestart.sh still invokes Capture-OwnedDefaults (it captures AFTER the edit)" \
  || ok "prestart.sh does not capture defaults"

# The script itself may stay on disk as a one-off recovery tool, but the deploy must not keep
# shipping it as part of the boot path. If it is still in $items, prestart can regain the call.
if grep -q 'Capture-OwnedDefaults' "$DEPLOY"; then
  bad "Deploy-DayZServer.ps1 still ships Capture-OwnedDefaults into the server dir"
else
  ok "the deploy no longer ships Capture-OwnedDefaults"
fi

# Positive control: the builders prestart SHOULD still run must survive the edit.
for b in Apply-ServerCfg Apply-CustomCE Build-MapPoints Build-TransferSpawns; do
  grep -q "$b" "$PRESTART" && ok "prestart still runs $b" || bad "prestart lost $b"
done

echo "prestart-no-capture: $pass passed, $fail failed"
[ $fail -eq 0 ]
