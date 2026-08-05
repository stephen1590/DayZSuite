// Source-level guards for fixes that live in DOM-string builders (no browser in the test
// runner, so these assert the CONTRACT, not the pixels).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const JS = readFileSync(join(root, 'web/js/editor.js'), 'utf8');
const OWN = readFileSync(join(root, 'web/js/own-editor.js'), 'utf8');
const CSS = readFileSync(join(root, 'web/style.css'), 'utf8');

// The guarantee: when you compare, you see BOTH copies at once, side by side, and nothing makes
// you flip between them. An inline diff that re-diffs the whole document per keystroke is
// unreadable once a file has diverged, so this lives in its own view - but where it lives is not
// the promise being tested, only that both copies are visible together.
test('E6: the frozen default is shown SIDE BY SIDE with the live copy, never one-or-the-other', () => {
  assert.match(OWN, /new CM\.MergeView\(/, 'both copies must be rendered together');
  assert.match(OWN, /a: \{ doc: live/, 'left: the live document, unsaved edits included');
  assert.match(OWN, /let def = st\.defText/, 'the right-hand copy IS the frozen default...');
  assert.match(OWN, /b: \{ doc: def/, '...and it is what the right pane renders');
  assert.match(OWN, /defaultsPathOf/, 'the default must be FETCHED alongside the live copy');
  assert.doesNotMatch(OWN, /wfShowDefault|showDefault/, 'no live-or-default swap may come back');
  assert.match(OWN, /collapseUnchanged/, 'identical stretches collapse, or a diverged file is a wall of red');
});

test('E6: the Live/Default toggle and its state are GONE, not just hidden', () => {
  assert.doesNotMatch(JS, /wfVToggle/, 'the toggle element must be removed');
  assert.doesNotMatch(JS, /let wfDraft[^;]*wfShowDefault/, 'the toggle state variable must be retired with it');
  // a migration ends at deletion - a dead flag left behind is how the next reader re-adds the button
  const decl = JS.match(/^\s*let .*wfShowDefault.*$/m);
  assert.equal(decl, null, 'wfShowDefault must not be declared anywhere');
});

test('E6: the compare view is display-only - the box never applies it', () => {
  assert.match(OWN, /revertControls: false/,
    'a revert arrow between chunks would make this view a write path; the two-copy model forbids that');
  assert.match(OWN, /readOnly\.of\(true\)/, 'and both copies are read-only');
});

test('E7: EVERY nav row states its access - no silent fallback to no badge', () => {
  // Anchored on the ASSIGNMENT, not one implementation expression, so a correct fix cannot be
  // blocked by a test pinned to the wrong expression.
  const i = JS.indexOf('const writable =');
  assert.notEqual(i, -1, 'access must be computed for every row');
  const block = JS.slice(i, i + 400);
  assert.match(block, /own-badge">rw/, 'writable rows say rw');
  assert.match(block, /ro-badge">ro/, 'locked rows say ro');
  assert.doesNotMatch(block, /:\s*''\s*;/, 'no empty-string fallback - that is what left most rows unlabelled');
});

// Exactly one badge per row - nothing else may ride alongside or displace the access badge.
test('E7: the access badge is the ONLY badge - nothing can displace it again', () => {
  const i = JS.indexOf('const writable =');
  const block = JS.slice(i, i + 400);
  assert.doesNotMatch(block, /ovr-badge/, 'the override count is deleted, not merely reordered');
  const badges = block.match(/const badge = ([^;]*);/);
  assert.ok(badges, 'the badge must be built in one place');
  assert.match(badges[1], /^\s*writable \? /, 'one ternary, one badge - no concatenated second badge to fight it');
});

// Meaning: the box captured a .defaults baseline for this file, i.e. it has been saved through
// the editor at least once. The marker rides beside the FILENAME, never in the badge slot - a
// second thing in that slot would displace the access badge.
test('the tree marks files that have been edited here, without touching the access badge', () => {
  const i = JS.indexOf('const writable = canWrite(r)');
  const block = JS.slice(i, i + 1400);   // the row builder, comments included
  assert.match(block, /edited-mark/, 'the row must carry an edited marker');
  assert.match(block, /const badge = writable \?/, 'the access badge stays ONE ternary, undisplaced');
  assert.match(block, /'<\/span>' \+ edited \+ badge/,
    'the marker sits with the filename, ahead of the badge - it may never take the badge slot');
  assert.match(JS, /editedFiles/, 'and it comes from the box, not from a guess in the browser');
});

test('the edited marker states what it means, and does not overclaim', () => {
  // It says "edited here", NOT "differs from the default" - the box reports a captured baseline,
  // and a file saved back to identical content still has one.
  assert.match(JS, /title="[^"]*edited/i, 'the marker needs a tooltip saying what it means');
  assert.doesNotMatch(JS, /title="[^"]*differs from/i, 'it must not claim a content comparison it never made');
});

test('E10: an absent file says so, instead of claiming it is unreadable', () => {
  assert.match(JS, /404 \? 'ABSENT'/, '404 must be classified as absent, not unreadable');
  assert.match(JS, /function fileMissingNote/, 'one shared wording for a file the box did not return');
  assert.match(JS, /not on the box yet/, 'the note must say the file does not exist rather than implying a permission fault');
});

// The day/night cycle editor is a purpose-built visualisation, INTERACTIVE, and drives the same
// document the editor holds rather than writing override rows.
test('the day/night cycle editor is interactive, not a read-only readout', () => {
  assert.match(JS, /class="cyc-in"/, 'the sliders must exist');
  assert.match(JS, /function wireCycle/, 'and be wired');
});

test('the cycle editor shows on BOTH edit paths, not just the owned one', () => {
  const hits = JS.match(/wireCycle\(row\)/g) || [];
  assert.ok(hits.length >= 2, `cycle editor wired on ${hits.length} path(s); it belongs to the FILE, so it must show in the owned editor AND the whole-file edit view`);
});

test('the sliders write through the editor document, never override rows', () => {
  const i = JS.indexOf('function wireCycle');
  const body = JS.slice(i, i + 1800);
  // A handle hands back ONE pane, and under two-pane editing that pane may be the projection, so
  // writing through it would edit a copy. ownSetPath edits whichever side is actually holding
  // the document.
  assert.match(body, /ownSetPath\(row\.key, \[sel\], n\)/, 'must drive the open document');
  assert.doesNotMatch(body, /layerMapRW/, 'must NOT write an override delta - that mechanism is being deleted');
});

test('the hardcoded "still override-managed" claim is gone from the chrome', () => {
  assert.doesNotMatch(JS, /still override-managed/,
    'that string asserted the rows are being applied without ever checking the file exists');
  // The live-branch wording is legitimate, but ONLY behind an existence check. Every place
  // editor.js still says it must be guarded by an ABSENT test - that is what makes the three
  // surfaces (summary bar, file panel, footer note) agree instead of contradicting each other.
  for (const m of JS.matchAll(/re-applies them at every restart/g)) {
    const ctx = JS.slice(Math.max(0, m.index - 700), m.index);
    assert.match(ctx, /err === 'ABSENT'/,
      'an unguarded "the box re-applies these" claim - it is false for a file the box does not have');
  }
});

// `access` is tri-valued, so `!== 'lock'` would call every reference surface writable. rw must
// mean the panel will really let you write: an owned whole-file editor, or the types editor.
test('E7: rw is derived from an EDIT PATH, never from "not locked"', () => {
  const i = JS.indexOf('const writable =');
  const expr = JS.slice(i, JS.indexOf(';', i));
  assert.doesNotMatch(expr, /access\s*!==\s*'lock'/,
    "access is edit|view|lock - 'not locked' includes view, which has no edit path at all");
  assert.match(expr, /canWrite\(/,
    'rw must come from the ONE predicate, not a second expression beside the badge');
});

// Two determination points is the bug itself: `access !== 'lock'` alone would badge reference
// rows rw, or `ownFile || types` alone would miss `access === 'own'` and put a Save button under
// an ro badge. Every write path belongs in canWrite, and nothing else may decide.
test('E7: canWrite covers EVERY write path the editor offers', () => {
  const fn = JS.slice(JS.indexOf('function canWrite('), JS.indexOf('function rowByKey('));
  for (const path of ['ownFile', 'types', "access === 'own'"]) {
    assert.ok(fn.includes(path), `canWrite must account for ${path} - a write path it misses is a wrong badge`);
  }
});
