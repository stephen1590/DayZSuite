// Bug report (owner, 2026-07-31): "Clicking on any JSON node shows `root[ ] (null)` even if
// it's on an object or property BELOW the root. It looks like it should be the property name
// and array size if it is an array."
//
// CAUSE: the navigator mounts a FRESH editor per focus, rooted at the focused subtree, with
// `schema: inferSchema(sub)`. inferSchema never emits a `title`, so json-editor falls back to
// its default root label - "root" - no matter how deep you clicked. And the size badge was read
// from the editor's internal `rows`, which only exists on array editors, so it could not report
// a name or a size for anything else.
//
// FIX: two pure helpers the navigator uses - titleForPath (what to call the focused node) and
// sizeBadge (what to show next to it, derived from the DATA, not the widget's internals).
// Written BEFORE they exist: first run must fail on the missing exports.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { titleForPath, sizeBadge, schemaForFocus } from '../web/js/json-editor-ui.js';

test('titleForPath: root stays "root"', () => {
  assert.equal(titleForPath([]), 'root');
});

test('titleForPath: an object property is named by its key', () => {
  assert.equal(titleForPath(['Patrols']), 'Patrols');
  assert.equal(titleForPath(['a', 'b', 'deepKey']), 'deepKey');
});

test('titleForPath: an array item is named "Parent [i+1]", 1-based like the rest of the UI', () => {
  assert.equal(titleForPath(['Patrols', 0]), 'Patrols [1]');
  assert.equal(titleForPath(['Patrols', 11]), 'Patrols [12]');
});

test('titleForPath: an array item directly under root still reads sensibly', () => {
  assert.equal(titleForPath([3]), 'root [4]');
});

test('sizeBadge: arrays report their length', () => {
  assert.equal(sizeBadge([1, 2, 3]), '[3]');
  assert.equal(sizeBadge(['only']), '[1]');
});

test('sizeBadge: an EMPTY array is the only thing that may say null', () => {
  assert.equal(sizeBadge([]), '[ ] (null)');
});

test('sizeBadge: objects report their field count, never "(null)"', () => {
  assert.equal(sizeBadge({ a: 1, b: 2 }), '{2}');
  assert.equal(sizeBadge({}), '{ }');
});

test('sizeBadge: scalars get no badge at all', () => {
  for (const v of ['text', 7, true, null, undefined]) assert.equal(sizeBadge(v), '');
});

test('schemaForFocus: carries the inferred schema PLUS the title the header shows', () => {
  const s = schemaForFocus({ Name: 'x' }, ['Patrols', 2]);
  assert.equal(s.title, 'Patrols [3]');
  assert.equal(s.type, 'object');
  assert.deepEqual(Object.keys(s.properties), ['Name']);
});

test('schemaForFocus: root keeps the plain "root" title (no regression at depth 0)', () => {
  assert.equal(schemaForFocus({ a: 1 }, []).title, 'root');
});

// ---------------------------------------------------------------------------
// Owner follow-up (2026-07-31): array items under a focused array still read
// "root [x/6]  [+]  [ ] (null)". Two further defects, both distinct from the first fix:
//
//  a) The item title takes its parent's name from the schemapath. When the focused node IS
//     the array, the mounted editor's parent path is the literal "root", so every item read
//     "root [x/N]" instead of "LandSpawnPositions [x/N]".
//  b) The badge tested `if (ed.rows)`. An EMPTY ARRAY IS TRUTHY in JS, so any editor exposing
//     rows: [] - including object rows - fell into the array branch and printed "[ ] (null)".
//     That is the stray bracket and the bogus null the owner is seeing on sub-OBJECTS.
import { parentKeyOf, badgeForNode } from '../web/js/json-editor-ui.js';

test('parentKeyOf: at the mount root, the focused node name is used, not "root"', () => {
  assert.equal(parentKeyOf('root', 'LandSpawnPositions'), 'LandSpawnPositions');
});

test('parentKeyOf: a nested parent still uses its own key', () => {
  assert.equal(parentKeyOf('root.Traders.Stock', 'LandSpawnPositions'), 'Stock');
});

test('parentKeyOf: no root title available -> "root" (unchanged fallback)', () => {
  assert.equal(parentKeyOf('root', null), 'root');
  assert.equal(parentKeyOf('root', ''), 'root');
});

test('badgeForNode: an OBJECT with an empty rows array is NOT an empty array', () => {
  // the exact reported shape: a sub-object rendering "[ ] (null)"
  assert.equal(badgeForNode({ schema: { type: 'object' }, rows: [], editors: { x: 1, y: 2, z: 3 } }), '{3}');
});

test('badgeForNode: objects report field count; empty object is "{ }" not null', () => {
  assert.equal(badgeForNode({ schema: { type: 'object' }, editors: { a: 1 } }), '{1}');
  assert.equal(badgeForNode({ schema: { type: 'object' }, editors: {} }), '{ }');
});

test('badgeForNode: arrays still report length, empty still says null', () => {
  assert.equal(badgeForNode({ schema: { type: 'array' }, rows: [1, 2, 3, 4, 5, 6] }), '[6]');
  assert.equal(badgeForNode({ schema: { type: 'array' }, rows: [] }), '[ ] (null)');
});

test('badgeForNode: untyped schema falls back to the shape actually present', () => {
  assert.equal(badgeForNode({ schema: {}, rows: [1, 2] }), '[2]');
  assert.equal(badgeForNode({ schema: {}, editors: { a: 1 } }), '{1}');
});

test('badgeForNode: scalars and missing editors get nothing', () => {
  assert.equal(badgeForNode({ schema: { type: 'string' } }), '');
  assert.equal(badgeForNode(null), '');
});
