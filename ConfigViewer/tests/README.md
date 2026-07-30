# ConfigViewer tests

## own-editor.harness.html - DOM harness for the two-copy editor

Runs `web/js/own-editor.js` (the REAL module + real ui/dom/vendor imports) against mocked
api-client/auth via an import map - no box, no auth, no network. The page SELF-SCORES:
it renders the CM6 editor with a live-vs-default diff and prints a JSON verdict ending in
`"ALL_PASS": true|false`.

Run (from `ConfigViewer/`):

    python3 -m http.server 8917
    # open http://127.0.0.1:8917/tests/own-editor.harness.html

Checks: module loads, CM6 renders, live content shown, unified diff gutter present
(deleted default line visible), Save disabled while clean, dirty-tracking clean at rest.

Lives OUTSIDE web/ so it can never deploy. Headless firefox hangs pre-request on the dev
box (2026-07-29, fresh profile + --no-remote both) - run it in a normal browser.
