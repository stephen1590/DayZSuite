// TWO cases for a duplicate/copy control in the structured editor, and only ONE of them is ours
// to build:
//   - ARRAY ITEMS: json-editor 2.17 already ships a per-row copy button (it splices the copy in at
//     i+1). It is off by default behind `enable_array_copy`, and the theme already carries its
//     icon. Turning it on is the whole change - writing a second one would be a parallel mechanism.
//   - OBJECT PROPERTIES: the lib has nothing, because a copy needs a NAME. That is what
//     duplicateProperty below is for, and inventing a name silently is the trap - so the rule is
//     spelled out and tested: "<key> copy", then "<key> copy 2", never an overwrite.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { duplicateProperty, uniqueKey } from '../web/js/json-editor-ui.js';

test('uniqueKey: the first copy is named plainly', () => {
  assert.equal(uniqueKey('Name', ['Name']), 'Name copy');
});

test('uniqueKey: further copies count up instead of colliding', () => {
  assert.equal(uniqueKey('Name', ['Name', 'Name copy']), 'Name copy 2');
  assert.equal(uniqueKey('Name', ['Name', 'Name copy', 'Name copy 2']), 'Name copy 3');
});

test('uniqueKey: a free name is still suffixed - a duplicate is never the same key', () => {
  assert.equal(uniqueKey('Name', ['Other']), 'Name copy');
});

test('duplicateProperty: the copy lands directly after the property it copies', () => {
  const out = duplicateProperty({ x: 1, y: 2 }, 'x');
  assert.deepEqual(Object.keys(out), ['x', 'x copy', 'y']);
  assert.equal(out['x copy'], 1);
});

test('duplicateProperty: an existing copy name is never overwritten', () => {
  const out = duplicateProperty({ x: 1, 'x copy': 9 }, 'x');
  assert.equal(out['x copy'], 9, 'the existing key survives untouched');
  assert.equal(out['x copy 2'], 1);
});

test('duplicateProperty: the copy is DEEP - editing one must never edit the other', () => {
  const src = { a: { Items: [{ n: 1 }] } };
  const out = duplicateProperty(src, 'a');
  out['a copy'].Items[0].n = 99;
  assert.equal(out.a.Items[0].n, 1);
  assert.equal(src.a.Items[0].n, 1, 'the input object must not be mutated either');
});

test('duplicateProperty: refuses anything that is not an object property', () => {
  assert.equal(duplicateProperty({ x: 1 }, 'nope'), null);
  assert.equal(duplicateProperty(['a', 'b'], '0'), null, 'array items are the lib own control, not this one');
  assert.equal(duplicateProperty('scalar', 'x'), null);
  assert.equal(duplicateProperty(null, 'x'), null);
  assert.equal(duplicateProperty(7, 'x'), null);
});

// The array half of the ask is an OPTION, not code, so this is what there is to assert without a
// browser: that the option is actually passed. Stated plainly - it reads the source, so it proves
// the flag is set, not that the lib then renders the button.
test('the array copy button is enabled on the shared mount (enable_array_copy)', () => {
  const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../web/js/json-editor-ui.js'), 'utf8');
  assert.match(src, /enable_array_copy:\s*true/,
    'json-editor ships a per-row array copy button behind this option - without it, array items have no duplicate control');
});
