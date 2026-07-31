// Owner 2026-07-31:
//  E9  "Why show `8 overridden` if we never have context as to what those are?! I don't see any
//       highlights... we want to get away from tracking those individual changes"
//  E8  "there are STILL SO MANY lingering references to 'overrides' and 'Use Fields'"
//  E11 "Deltas only. The whole file shows for context - Save writes just your changes to
//       config-overrides.json." shown on the editor view
//
// A bare count is useless: it names a quantity and hides the thing. Either say WHICH values are
// override-managed, or say nothing. And "Use Fields" points at a view that E1/E5 retired.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
const JS = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../web/js/editor.js'), 'utf8');

test('E9: there is a helper that NAMES the override-managed values', () => {
  assert.match(JS, /function overrideContextHtml/, 'need one shared renderer for the "which values" list');
  assert.match(JS, /re-applied at every restart|reapplied at every restart/i,
    'it must say WHY they matter - they come back at boot, which is the whole hazard');
});

test('E9: the context list is shown in the file view, beside the copies', () => {
  const i = JS.indexOf('function fileViewHtml');
  const body = JS.slice(i, i + 1400);
  assert.match(body, /overrideContextHtml/, 'the side-by-side view must show which values are override-managed');
});

test('E9: the bare count no longer stands alone', () => {
  assert.doesNotMatch(JS, /<b>' \+ nOver \+ '<\/b> ' \+ \(row\.kind === 'xml' \? 'XPath override'/,
    'the unexplained "N overridden" stat must be gone');
});

test('E8: "Use Fields" is gone - that view was retired by E1/E5', () => {
  assert.doesNotMatch(JS, /Use Fields/, 'no user-facing text may send someone to a view that no longer exists');
});

test('E11: the edit note states the real consequence, not just "deltas only"', () => {
  assert.doesNotMatch(JS, /Deltas only\./, 'the bare "Deltas only." banner must go');
  assert.match(JS, /own(ed)? whole|cut (this )?file over|whole-file ownership/i,
    'it should point at the end state (owning the file whole), not just describe the delta');
});
