// Owner (2026-07-31): "Reduce the padding between objects. It looks like a major one is
// je-object__controls adding 15 pixels even if there aren't controls present. And
// je-indented-panel has massive 10x padding. we don't need that. Where else?"
//
// Measured before the change - and the library styles NONE of these classes, so every pixel
// is ours (jsoneditor-theme.css):
//   tier rule, applied to EVERY nested node   padding-left 10 + margin-left 3 = 13px
//   .je-indented-panel                        padding-left 11 + margin-left 7 = 18px
//   -> 31px of horizontal inset PER NESTING LEVEL, and 12px of vertical rhythm.
//
// Nesting compounds, so this is the thing that makes a deep document unreadable. This test is a
// BUDGET: the theme may not spend more than the numbers below per level. It is a regression guard
// in the same spirit as the mechanism-count freeze - density creeps back one rule at a time.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const CSS = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../web/jsoneditor-theme.css'), 'utf8');

// Body of the first rule whose selector contains `sel`.
function ruleBody(sel) {
  const i = CSS.indexOf(sel);
  assert.notEqual(i, -1, `rule not found: ${sel}`);
  return CSS.slice(i, CSS.indexOf('}', i));
}
// px value of a longhand, or of side `side` in a shorthand (t r b l).
function px(body, prop, side) {
  const m = body.match(new RegExp(prop + '\\s*:([^;]*)'));
  if (!m) return 0;
  const parts = m[1].trim().split(/\s+/).map((v) => (parseFloat(v) || 0));
  if (parts.length === 1) return parts[0];
  const [t, r, b = t, l = r] = parts;
  return { top: t, right: r, bottom: b, left: l }[side] ?? 0;
}

const TIER = ruleBody('.je-mount [data-schemapath]:not');
const PANEL = ruleBody('.je-mount .je-indented-panel');

test('horizontal inset per nesting level stays within budget', () => {
  const tier = px(TIER, 'padding-left') + px(TIER, 'margin-left');
  const panel = px(PANEL, 'padding', 'left') + px(PANEL, 'margin', 'left');
  const total = tier + panel;
  assert.ok(total <= 20, `per-level indent is ${total}px (tier ${tier} + panel ${panel}); budget is 20px. It was 31px and made deep documents unreadable.`);
});

test('vertical rhythm per nesting level stays within budget', () => {
  const v = px(PANEL, 'padding', 'top') + px(PANEL, 'padding', 'bottom')
    + px(PANEL, 'margin', 'top') + px(PANEL, 'margin', 'bottom');
  assert.ok(v <= 4, `panel spends ${v}px vertically per level; budget is 4px. It was 8px.`);
});

test('an EMPTY controls span is collapsed, not left holding a blank row', () => {
  // The add-property button is lifted out to sit beside the name (json-editor-ui decorate()),
  // so the original span is usually left with nothing in it - but still took a line box.
  assert.match(CSS, /\.je-object__controls[^{]*\{[^}]*display\s*:\s*none/,
    'need a rule collapsing .je-object__controls when it holds no button');
});

test('the tier guide itself survives - density must not delete the visual hierarchy', () => {
  assert.match(TIER, /border-left/, 'the left tier rule is the hierarchy cue; reducing padding must not remove it');
  assert.ok(px(TIER, 'padding-left') >= 4, 'keep enough inset that the guide reads as a tier, not a smudge');
});

// Owner, 2026-08-01: "Please make jn-editor and jn-json have independent scrolling."
//
// Before: .jn-json was capped (max-height 60vh, overflow auto) but .jn-editor had NO bound, so
// the form pane grew to its content and pushed the whole page. Scrolling to the bottom of a long
// form scrolled the document away from the JSON preview - the two panes could not be read against
// each other, which is the entire point of showing them side by side.
//
// Both panes must be independently scrollable AND share one height, so neither can drift past the
// other. The height lives in a custom property for exactly that reason: two literals would be two
// places to change.
test('the navigator panes scroll independently', () => {
  const ed = CSS.match(/\.jn-editor\s*\{([^}]*)\}/);
  const js = CSS.match(/\.jn-json\s*\{([^}]*)\}/);
  assert.ok(ed && js, 'both panes must be styled');
  for (const [name, rule] of [['.jn-editor', ed[1]], ['.jn-json', js[1]]]) {
    assert.match(rule, /overflow\s*:\s*auto/, `${name} must scroll on its own`);
    assert.match(rule, /max-height\s*:\s*var\(--jn-pane-h/, `${name} must take the SHARED pane height, not its own literal`);
    assert.match(rule, /min-height\s*:\s*0/, `${name} needs min-height:0 or flex refuses to let it shrink and scroll`);
  }
});

test('the shared pane height is defined once', () => {
  const decls = CSS.match(/--jn-pane-h\s*:/g) || [];
  assert.equal(decls.length, 1, `--jn-pane-h declared ${decls.length} times; one definition or it is not shared`);
});

test('the split stretches both panes to equal height', () => {
  const split = CSS.match(/\.jn-split\s*\{([^}]*)\}/);
  assert.ok(split, '.jn-split must be styled');
  assert.doesNotMatch(split[1], /align-items\s*:\s*flex-start/,
    'flex-start lets each pane size to its own content - they must stretch to the same height');
});
