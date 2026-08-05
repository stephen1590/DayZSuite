# ConfigViewer tests

## own-editor.harness.html - DOM harness for the two-copy editor

Runs `web/js/own-editor.js` (the REAL module + real ui/dom/vendor imports) against mocked
api-client/auth via an import map - no box, no auth, no network. The page SELF-SCORES:
it renders the CM6 editor with a live-vs-default diff and prints a JSON verdict ending in
`"ALL_PASS": true|false`.

Run (from `ConfigViewer/`):

    python3 -m http.server 8917
    # open http://127.0.0.1:8917/tests/own-editor.harness.html

Checks: module loads, CM6 renders, Save disabled while clean, dirty-tracking clean at rest,
and the E16 two-pane contract - both panes present, structured on the LEFT, raw owning the
document, exactly one gold box, the projection inert, the structured side NOT built until
committed, and a commit that builds it without moving the gold box.

**Reproducing the open-time lock-up:** add `?big=400` for a synthetic 400-entry config. Watch
`msToTypeable` (how long until the file can be typed in) against `msToBuildStructured` (the
opt-in cost of the structured side). Building the structured side at open is what made those two
one number, and it is why an owned file took seconds to become editable (owner, 2026-08-04).

Lives OUTSIDE web/ so it can never deploy. Headless firefox hangs pre-request on the dev
box (2026-07-29, fresh profile + --no-remote both) - run it in a normal browser.
