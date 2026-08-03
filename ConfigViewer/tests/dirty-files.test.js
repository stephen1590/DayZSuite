// TDD for the ONE named-dirty mechanism. Written BEFORE
// web/js/dirty-files.js exists - first run must fail with a module-not-found.
//
// Owner spec, verbatim: "saving should prompt for confirmation now.
// The dialogue should tell you what files you edited and are currently saving."
// The pure logic lives here: the pill text, the confirm-dialog text, and what
// counts as an edit. The DOM wiring in the editors stays thin and untested-by-node.
//
// changedFiles() and its 5 tests were removed 2026-08-02: it diffed two overrides-doc
// snapshots, a document A3 deleted, so it was dead the day it shipped.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatUnsaved, confirmSaveText, confirmSave } from '../web/js/dirty-files.js';

test('formatUnsaved: empty, short list, truncated list', () => {
  assert.equal(formatUnsaved([]), '');
  assert.equal(formatUnsaved(['a.xml', 'b.json']), 'Unsaved: a.xml, b.json');
  assert.equal(formatUnsaved(['a', 'b', 'c', 'd', 'e']), 'Unsaved: a, b, c +2 more');
});

test('confirmSaveText names every file and asks', () => {
  const t = confirmSaveText(['db/types.xml (dayzOffline.sakhal)', 'serverDZ.cfg']);
  assert.match(t, /Save these changes\?/);
  assert.match(t, /db\/types\.xml \(dayzOffline\.sakhal\)/);
  assert.match(t, /serverDZ\.cfg/);
});

test('confirmSave passes the text to the injected confirm and returns its answer', () => {
  let seen = null;
  assert.equal(confirmSave(['x.json'], (msg) => { seen = msg; return true; }), true);
  assert.match(seen, /x\.json/);
  assert.equal(confirmSave(['x.json'], () => false), false);
});

// TDD, owner bug 2026-07-31: "And when I go to save: `Save these changes? You edited and are
// saving:` AND NOTHING IS LISTED!"
//
// saveOverrides() derives the list from the doc diff. Click Save with nothing changed and the
// list is empty, so the dialog asked the owner to confirm a write it could not name. A prompt
// that lists nothing is worse than no prompt - it trains you to click through the one that
// matters. An empty list is not a dialog to render, it is a save that must not happen.
test('confirmSave with NO changed files never prompts and never approves', () => {
  let asked = false;
  assert.equal(confirmSave([], () => { asked = true; return true; }), false,
    'an empty list must refuse, even if the confirm function would say yes');
  assert.equal(asked, false, 'the dialog must not be shown at all');
  assert.equal(confirmSave(null, () => { asked = true; return true; }), false);
  assert.equal(asked, false);
});

test('confirmSaveText can never render an empty bullet list', () => {
  for (const empty of [[], null, undefined]) {
    const t = confirmSaveText(empty);
    assert.doesNotMatch(t, /You edited and are saving:\s*$/,
      'the exact string the owner saw: a heading with nothing under it');
    assert.match(t, /nothing to save|no unsaved/i, 'say what is actually true');
  }
});

// Owner, 2026-08-01: "Going to server settings automatically detects a change - why?"
//
// The structured JSON navigator fires its change event ON MOUNT, so the editor's draft became a
// RE-SERIALISED copy of the document before the owner touched anything. The box's file is
// pretty-printed; the re-serialisation was not. Different bytes, identical data -> the file
// showed unsaved changes the moment it opened, on every owned JSON surface.
//
// Byte equality is the wrong question for a structured editor. It can never round-trip a file
// byte-for-byte, so "did the bytes change" always answers yes. The right question is whether the
// DATA changed. That is this function, and it lives here because dirty-files.js is the one place
// that decides what "unsaved" means.
import { jsonEquivalent } from '../web/js/dirty-files.js';

test('formatting-only differences are NOT a change', () => {
  assert.equal(jsonEquivalent('{\n  "a": 1\n}', '{"a":1}'), true, 'indentation is not an edit');
  assert.equal(jsonEquivalent('{"a":1}\n', '{"a":1}'), true, 'a trailing newline is not an edit');
  assert.equal(jsonEquivalent('{ "a" : 1 }', '{"a":1}'), true, 'whitespace is not an edit');
});

test('a real value change IS a change', () => {
  assert.equal(jsonEquivalent('{"a":1}', '{"a":2}'), false);
  assert.equal(jsonEquivalent('{"a":1}', '{"a":1,"b":2}'), false, 'an added key is an edit');
  assert.equal(jsonEquivalent('{"a":1,"b":2}', '{"a":1}'), false, 'a removed key is an edit');
});

test('key ORDER is a change - a config file is read by humans in order', () => {
  // Not folded away: reordering is a real edit to the file even though the data is equal, and
  // silently discarding it would lose the owner's change.
  assert.equal(jsonEquivalent('{"a":1,"b":2}', '{"b":2,"a":1}'), false);
});

test('unparseable input is treated as changed, never as clean', () => {
  // A draft that does not parse must never report "no changes" - that would let the editor
  // discard a broken-but-real edit without warning.
  assert.equal(jsonEquivalent('{not json', '{"a":1}'), false);
  assert.equal(jsonEquivalent('{"a":1}', '{also not json'), false);
});

test('big integers survive the comparison', () => {
  // Steam64 IDs exceed 2^53. If the comparison round-tripped through a JS double, a file holding
  // one would flip between "changed" and "not changed" on formatting alone.
  const a = '{"id": 76561198012345678}';
  const b = '{\n  "id": 76561198012345678\n}';
  assert.equal(jsonEquivalent(a, b), true);
  assert.equal(jsonEquivalent(a, '{"id": 76561198012345679}'), false, 'a one-digit difference must register');
});

// REGRESSION, owner 2026-08-01: opening profiles/BaseBuildingPlus/BBP_Settings.json showed
// unsaved changes with nothing touched - the exact symptom e0a75c4 was supposed to have closed.
//
// canon() strips insignificant WHITESPACE but never touches the digits of a number token. The
// structured navigator's draft is not the source bytes - it is the source PARSED to real JS
// numbers, then JSON.stringify'd back out. JS's number-to-string does not reproduce the source
// spelling: a trailing ".0" on a whole-number float is dropped (0.0 -> 0) and an exponent's case
// and zero-padding are normalised (1.5E-07 -> 1.5e-7). Same value, different text, and canon()
// only compares text - so a file with either shape reads as changed on the moment it opens, even
// though the previous fix already made "did the bytes change" the wrong question for a structured
// editor once.
import { bigParse, restoreBigInts } from '../web/js/lossless-json.js';
import { readFileSync } from 'node:fs';
const jsonEnc = (v) => restoreBigInts(JSON.stringify(v, null, 2));   // mirrors own-editor.js's jsonEnc

test('a whole-number float ("0.0") reformatted to "0" is NOT a change', () => {
  assert.equal(jsonEquivalent('{"a": 0.0}', '{"a": 0}'), true);
  assert.equal(jsonEquivalent('{"a": 100.0}', '{"a": 100}'), true);
});

test('exponent notation reformatted by JS number->string is NOT a change', () => {
  // JSON.stringify(JSON.parse('-9.999999974752427E-07')) === '-9.999999974752427e-7'
  assert.equal(jsonEquivalent('{"a": -9.999999974752427E-07}', '{"a": -9.999999974752427e-7}'), true);
  assert.equal(jsonEquivalent('{"a": 1.5E+10}', '{"a": 15000000000}'), true);
});

test('a real change hidden inside reformatted-number text still registers', () => {
  assert.equal(jsonEquivalent('{"a": 0.0}', '{"a": 1}'), false);
  // NOT '...427' vs '...428' - at 16 significant digits both spellings round to the SAME IEEE-754
  // double (proven: Number("-9.999999974752427E-07") === Number("-9.999999974752428e-7")), so no
  // text- or value-based comparison could tell them apart; that is a real double-precision limit,
  // not a bug. Change a leading digit instead, which changes the double unambiguously.
  assert.equal(jsonEquivalent('{"a": -9.999999974752427E-07}', '{"a": -8.999999974752427E-07}'), false);
});

test('the real BBP_Settings.json (box bytes) does not appear dirty the moment it opens', () => {
  // Fixture is the ACTUAL box file (fetched read-only 2026-08-01) - it holds both shapes above for
  // real: "0.0" orientation components and one "-9.999999974752427E-07" exponent literal. A
  // synthetic-only fixture is how this class of bug got past the first fix.
  const raw = readFileSync(new URL('./fixtures/BBP_Settings.json', import.meta.url), 'utf8');
  const draft = jsonEnc(bigParse(raw));   // exactly what own-editor.js produces on mount, untouched
  assert.notEqual(draft, raw, 'sanity: the re-serialised draft really is byte-different from the source');
  assert.equal(jsonEquivalent(raw, draft), true,
    'no edit was made - opening the file must never read as an unsaved change');
});
