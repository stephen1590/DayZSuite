// Owner UI pass, 2026-07-31. Source-level guards for three fixes that live in DOM-string builders
// (no browser in the test runner, so these assert the CONTRACT, not the pixels).
//
//  E6  "AND I SAID WE NEED TO BE ABLE TO SEE THE DEFAULT SIDE BY SIDE WITH OUR OWNED VERSION.
//       There's still a separate button that changes the view."
//  E7  "how come the RO/RW only applies to a few items? Be consistent."
//  E10 "why do I see this? `Whole-file view unavailable — not readable on the box.`"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const JS = readFileSync(join(root, 'web/js/editor.js'), 'utf8');
const OWN = readFileSync(join(root, 'web/js/own-editor.js'), 'utf8');
const CSS = readFileSync(join(root, 'web/style.css'), 'utf8');

// The owner's requirement outlived the mechanism that first carried it. The override editor's
// side-by-side file view is deleted; the SAME guarantee now has to hold in the owned editor,
// which is the only place an editable file is shown at all.
test('E6: an owned file is shown against its frozen default, with no toggle to choose one', () => {
  assert.match(OWN, /unifiedMergeView\(\{ original: st\.defText/,
    'the frozen default must be rendered against the live document, not behind a switch');
  assert.match(OWN, /defaultsPathOf/, 'the default must be FETCHED alongside the live copy');
  assert.doesNotMatch(OWN, /wfShowDefault|showDefault/, 'no view-switcher state may come back');
});

test('E6: the Live/Default toggle and its state are GONE, not just hidden', () => {
  assert.doesNotMatch(JS, /wfVToggle/, 'the toggle element must be removed');
  assert.doesNotMatch(JS, /let wfDraft[^;]*wfShowDefault/, 'the toggle state variable must be retired with it');
  // a migration ends at deletion - a dead flag left behind is how the next reader re-adds the button
  const decl = JS.match(/^\s*let .*wfShowDefault.*$/m);
  assert.equal(decl, null, 'wfShowDefault must not be declared anywhere');
});

test('E6: the diff is display-only - the box never applies it', () => {
  assert.match(OWN, /mergeControls: false/,
    'accept/reject controls would make the diff a write path; the two-copy model forbids that');
});

test('E7: EVERY nav row states its access - no silent fallback to no badge', () => {
  const i = JS.indexOf('const writable = r.access !== ');
  assert.notEqual(i, -1, 'access must be computed for every row');
  const block = JS.slice(i, i + 400);
  assert.match(block, /own-badge">rw/, 'writable rows say rw');
  assert.match(block, /ro-badge">ro/, 'locked rows say ro');
  assert.doesNotMatch(block, /:\s*''\s*;/, 'no empty-string fallback - that is what left most rows unlabelled');
});

test('E7: an override count no longer REPLACES the access badge', () => {
  const i = JS.indexOf('const writable = r.access !== ');
  const block = JS.slice(i, i + 400);
  // count and access badge must both be emitted, concatenated - not chosen between
  assert.match(block, /ovr-badge[\s\S]{0,120}\+\s*\(writable/, 'the count rides alongside the access badge');
});

test('E10: an absent file says so, instead of claiming it is unreadable', () => {
  assert.match(JS, /404 \? 'ABSENT'/, '404 must be classified as absent, not unreadable');
  assert.match(JS, /function fileMissingNote/, 'one shared wording for a file the box did not return');
  assert.match(JS, /not on the box yet/, 'the note must say the file does not exist rather than implying a permission fault');
});

// Owner 2026-07-31: "you got rid of the day/night cycle editor view.... THAT WAS USEFUL VISUALLY.
// Keep it. That had no bearing on the 'form input' method." Retiring the Fields VIEW was never a
// reason to lose a purpose-built visualisation. It is back, INTERACTIVE, and now drives the same
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
  assert.match(body, /setValue\(\[sel\], n\)/, 'must drive the open document');
  assert.doesNotMatch(body, /layerMapRW/, 'must NOT write an override delta - that mechanism is being deleted');
});

// Owner bug 2026-07-31: "This literally says the file doesn't exist yet, but 2 overrides are
// present? Make it make sense!" The count and the file's existence were rendered by two
// unrelated pieces of code, so they contradicted each other. Both now go through
// override-status.js. These guard the wiring; the wording itself is unit-tested there.


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




