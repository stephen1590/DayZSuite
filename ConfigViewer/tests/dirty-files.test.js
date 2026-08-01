// TDD for E4 (Scale-Ready): the ONE named-dirty mechanism. Written BEFORE
// web/js/dirty-files.js exists - first run must fail with a module-not-found.
//
// Owner spec (verbatim, PLAN.md E4): "saving should prompt for confirmation now.
// The dialogue should tell you what files you edited and are currently saving."
// The pure logic lives here: which files changed between two overrides-doc
// snapshots, the pill text, and the confirm-dialog text. The DOM wiring in the
// editors stays thin and untested-by-node.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { changedFiles, formatUnsaved, confirmSaveText, confirmSave } from '../web/js/dirty-files.js';

const doc = (files = {}, missions = {}) => ({ files, mpmissions: missions });

test('identical docs -> no changed files', () => {
  const a = doc({ 'messages.xml': { '/x': 1 } });
  assert.deepEqual(changedFiles(a, JSON.parse(JSON.stringify(a))), []);
});

test('a changed mission-file value names file + mission', () => {
  const before = doc({}, { 'dayzOffline.sakhal': { 'db/types.xml': { '/a': 3 } } });
  const after  = doc({}, { 'dayzOffline.sakhal': { 'db/types.xml': { '/a': 3888000 } } });
  assert.deepEqual(changedFiles(before, after), ['db/types.xml (dayzOffline.sakhal)']);
});

test('an added server-dir file is named plainly; a removed one too', () => {
  const before = doc({ 'a.xml': { '/x': 1 } });
  const after  = doc({ 'b.json': { '/y': 2 } });
  assert.deepEqual(changedFiles(before, after).sort(), ['a.xml', 'b.json']);
});

test('the common layer is labelled (common)', () => {
  const before = doc({}, { common: { 'expansion/settings/MapSettings.json': { '/m': 0 } } });
  const after  = doc({}, { common: { 'expansion/settings/MapSettings.json': { '/m': 1 } } });
  assert.deepEqual(changedFiles(before, after), ['expansion/settings/MapSettings.json (common)']);
});

test('underscore comment keys are ignored at every level', () => {
  const before = doc({ _readme: 'was' }, { _note: 'x' });
  const after  = doc({ _readme: 'changed' }, { _note: 'y', 'dayzOffline.sakhal': { _hint: 'z' } });
  assert.deepEqual(changedFiles(before, after), []);
});

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
