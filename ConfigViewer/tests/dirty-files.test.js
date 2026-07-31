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
