// What the rw/ro badge PROMISES: it says exactly what the panel will let you do. A row badged
// rw opens with a Save button; a row badged ro has none.
//
// These call the predicate instead of reading the source for it. A source-shape assertion
// ("the badge expression mentions canWrite") passes while the predicate itself is wrong, and
// this contract has shipped wrong twice - once badging every reference file writable, once
// putting a Save button under an ro badge.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { canWrite } from '../web/js/access.js';

// The row shapes buildRows produces, one per surface kind.
const DEFAULT_JSON = { relpath: 'profiles/SomeMod/Extra.json', access: 'edit', ownFile: true };
const VIEW_LOCKED = { relpath: 'mods.conf.xml', access: 'lock', readonly: true };
const GENERATED = { relpath: 'profiles/AI_Shared/map-points.generated.json', access: 'lock', generated: true };
const MAP_OWNED = { relpath: 'mpmissions/m/expansion/settings/AIPatrolSettings.json', access: 'lock', mapOwned: true };
const TYPES = { relpath: 'custom-ce/expansion_types_tuning.xml', access: 'edit', types: true };
const GRANTED = { relpath: 'ban.txt', access: 'own' };
const OTHER_EXT = { relpath: 'host.env', access: 'lock' };

test('editable by default: an ordinary json/xml surface is writable', () => {
  assert.equal(canWrite(DEFAULT_JSON), true);
});

test('the four exceptions are NOT writable', () => {
  assert.equal(canWrite(VIEW_LOCKED), false, 'a view-only reference file');
  assert.equal(canWrite(GENERATED), false, 'a builder output - edit the input instead');
  assert.equal(canWrite(MAP_OWNED), false, 'patrols are edited on the Map tab, not here');
  assert.equal(canWrite(OTHER_EXT), false, 'a type with no explicit grant');
});

test('the other two write paths still badge rw', () => {
  assert.equal(canWrite(TYPES), true, 'the CE types table');
  assert.equal(canWrite(GRANTED), true, 'an explicitly granted non-json/xml file');
});

test('a missing or empty row is never writable', () => {
  for (const bad of [null, undefined, {}]) assert.equal(canWrite(bad), false);
});
