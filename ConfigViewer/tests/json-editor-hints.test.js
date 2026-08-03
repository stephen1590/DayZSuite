// TDD for the `hints` extension point - written BEFORE resolveHint exists, so the first run
// must fail on a missing export.
//
// WHY IT EXISTS. json-editor-ui is the shared structured editor and it has two consumers, but it
// could never REPLACE a hand-built editor, because it had no way to be told anything
// domain-specific. So map.js kept its own 550-line editor beside it and the mechanism count went
// UP, not down. The UI contract specified this descriptor on day one - "any DayZ-specific nicety
// is an optional, generic `hints` descriptor passed by ConfigViewer, never code inside the
// package" - and nobody built it. This is that descriptor.
//
// THE BINDING CONSTRAINT: nothing in here may know what DayZ is. No field names, no -1 semantics,
// no waypoints. The caller supplies all of it. These tests use DayZ-shaped examples deliberately -
// if any of them could only be satisfied by special-casing a name inside the package, the design
// is wrong.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveHint, partitionByPriority } from '../web/js/json-editor-hints.js';

test('no hints -> a plain field, never a crash', () => {
  assert.deepEqual(resolveHint('AnyKey', 5, undefined), {});
  assert.deepEqual(resolveHint('AnyKey', 5, {}), {});
  assert.deepEqual(resolveHint('AnyKey', 5, null), {});
});

// --- badge: a caller-computed label beside the field ---------------------------
// Covers "-1 means inherit from the global setting" without the package knowing that.
test('badge comes from the caller and can depend on the VALUE', () => {
  const hints = { badge: (key, value) => (typeof value === 'number' && value < 0 ? 'inherits' : null) };
  assert.equal(resolveHint('MinDistRadius', -1, hints).badge, 'inherits');
  assert.equal(resolveHint('MinDistRadius', 250, hints).badge, undefined,
    'a null badge must be absent, not a null property to render');
});

test('a badge function that throws cannot break the editor', () => {
  const hints = { badge: () => { throw new Error('caller bug'); } };
  assert.deepEqual(resolveHint('X', 1, hints), {}, 'fails soft - the field still renders');
});

// --- enum: pick a known value or free-type -------------------------------------
// Covers LoadBalancingCategory offering the categories defined elsewhere in the same document.
test('enum offers suggestions for a named key', () => {
  const hints = { enums: { LoadBalancingCategory: ['Alpha', 'Bravo'] } };
  assert.deepEqual(resolveHint('LoadBalancingCategory', 'Alpha', hints).suggestions, ['Alpha', 'Bravo']);
  assert.equal(resolveHint('Other', 'x', hints).suggestions, undefined);
});

test('enums may be a FUNCTION, so suggestions can come from the live document', () => {
  const hints = { enums: (key) => (key === 'Cat' ? ['a', 'b'] : null) };
  assert.deepEqual(resolveHint('Cat', 'a', hints).suggestions, ['a', 'b']);
  assert.equal(resolveHint('Nope', 'a', hints).suggestions, undefined);
});

test('an empty suggestion list is not a dropdown', () => {
  assert.equal(resolveHint('Cat', 'a', { enums: { Cat: [] } }).suggestions, undefined);
});

// --- readOnly + summary: show it, do not invite typing into it -----------------
// Covers Waypoints, which are edited by dragging on the map. Rendering them as an editable
// array is worse than not rendering them - it invites an edit the map will overwrite.
test('readOnly marks a field, and summary replaces its control', () => {
  const hints = {
    readOnly: ['Waypoints'],
    summary: (key, value) => (key === 'Waypoints' ? `${value.length} point(s) - drag on the map` : null),
  };
  const h = resolveHint('Waypoints', [[1, 2, 3], [4, 5, 6]], hints);
  assert.equal(h.readOnly, true);
  assert.equal(h.summary, '2 point(s) - drag on the map');
});

test('readOnly may be a predicate, not just a list', () => {
  const hints = { readOnly: (key) => key.startsWith('_') };
  assert.equal(resolveHint('_internal', 1, hints).readOnly, true);
  assert.equal(resolveHint('normal', 1, hints).readOnly, undefined);
});

test('summary without readOnly still renders - they are independent', () => {
  const h = resolveHint('Count', 3, { summary: () => '3 things' });
  assert.equal(h.summary, '3 things');
  assert.equal(h.readOnly, undefined);
});

// --- priority: the few fields that matter first, the rest folded away ----------
// Covers "core inline, the other ~35 under Advanced".
test('priority marks listed keys and only those', () => {
  const hints = { priority: ['Name', 'Chance'] };
  assert.equal(resolveHint('Name', 'x', hints).priority, true);
  assert.equal(resolveHint('Chance', 1, hints).priority, true);
  assert.equal(resolveHint('Anything', 1, hints).priority, undefined);
});

// --- the whole point: one call, several hints, no interference -----------------
test('hints compose - a field can be prioritised AND badged', () => {
  const hints = {
    priority: ['Speed'],
    badge: (k, v) => (v < 0 ? 'inherits' : null),
  };
  const h = resolveHint('Speed', -1, hints);
  assert.equal(h.priority, true);
  assert.equal(h.badge, 'inherits');
});

test('a hint for one key never leaks onto another', () => {
  const hints = { priority: ['A'], readOnly: ['B'], enums: { C: ['x'] } };
  assert.deepEqual(resolveHint('D', 1, hints), {});
});

// --- partitionByPriority -------------------------------------------------------
// NOTE: written AFTER the function, unlike everything above. Recorded rather than hidden -
// these are regression guards, not TDD, and one of them found a real bug on first run.
test('priority keys come out FIRST, in the caller order, not the document order', () => {
  const [head, tail] = partitionByPriority(['Z', 'Chance', 'A', 'Name'], { priority: ['Name', 'Chance'] });
  assert.deepEqual(head, ['Name', 'Chance'], 'the caller decided Name leads, though the doc lists it last');
  assert.deepEqual(tail, ['Z', 'A'], 'the rest keep document order');
});

test('a priority key the document does not have is dropped, not rendered empty', () => {
  const [head, tail] = partitionByPriority(['A'], { priority: ['Missing', 'A'] });
  assert.deepEqual(head, ['A']);
  assert.deepEqual(tail, []);
});

test('no hints -> everything is tail, nothing is lost', () => {
  const [head, tail] = partitionByPriority(['A', 'B'], undefined);
  assert.deepEqual(head, []);
  assert.deepEqual(tail, ['A', 'B']);
});

test('every key appears exactly once across head and tail', () => {
  const keys = ['a', 'b', 'c', 'd'];
  const [head, tail] = partitionByPriority(keys, { priority: ['c', 'a'] });
  assert.deepEqual([...head, ...tail].sort(), keys.slice().sort(), 'no key duplicated or dropped');
});
