// TDD, owner bug 2026-07-31: "This literally says the file doesn't exist yet, but 2 overrides
// are present? Make it make sense!"  (profiles/BaseBuildingPlus/BBP_Settings.json)
//
// Both halves of the contradiction were TRUE and the UI stated them as if unrelated:
//   - config-overrides.json on the box holds 2 rows for that path
//   - the file is not on the box, so Apply-ConfigOverrides logs
//       [WARN] files/profiles/BaseBuildingPlus/BBP_Settings.json : file not found
//     and SKIPS every row, at every restart. (Apply-ConfigOverrides.ps1:302, and proven live -
//     staging's 21:35 prestart emitted 210 of those warnings across 7 files.)
//
// A count with no reachability is worse than no count: it reads as "2 values are being forced
// on this file" when the truth is "2 values do nothing". This module is the ONE place that
// turns (rows, file state) into a statement, so the chrome and the file view cannot disagree.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { overrideStatus } from '../web/js/override-status.js';

const ABSENT = { text: null, err: 'ABSENT' };
const PRESENT = { text: '{}' };
const UNREADABLE = { text: null, err: 'signed out' };

test('no rows: the file is simply owned whole', () => {
  const s = overrideStatus(0, PRESENT);
  assert.equal(s.kind, 'none');
  assert.doesNotMatch(s.text, /\boverride/i, 'do not mention a mechanism that is not acting on this file');
});

test('rows + file absent: says the rows are INERT, not that values are managed', () => {
  const s = overrideStatus(2, ABSENT);
  assert.equal(s.kind, 'dead');
  assert.match(s.text, /\b2\b/, 'still name the count - it is real, it is in the manifest');
  assert.match(s.text, /not on the box|does not exist/i, 'name the actual cause');
  assert.match(s.text, /skip|nothing|no effect/i, 'say plainly that they do nothing');
  assert.doesNotMatch(s.text, /re-applies them at every restart/i,
    'the box CANNOT re-apply a patch to a file that is not there - that sentence is the bug');
});

test('rows + file present: the old live wording, unchanged', () => {
  const s = overrideStatus(2, PRESENT);
  assert.equal(s.kind, 'live');
  assert.match(s.text, /\b2\b/);
  assert.match(s.text, /restart/i, 'a live row IS re-applied at every restart - say so');
});

test('rows + file state not fetched yet: never claims either way', () => {
  const s = overrideStatus(2, null);
  assert.equal(s.kind, 'unknown');
  assert.doesNotMatch(s.text, /not on the box/i);
  assert.doesNotMatch(s.text, /nothing|no effect/i);
});

test('an unreadable file is NOT reported as absent', () => {
  // 'signed out' / a 500 means we do not know whether the file is there. Claiming the rows are
  // dead on that evidence would be the same class of error in the other direction.
  assert.equal(overrideStatus(2, UNREADABLE).kind, 'unknown');
});

test('singular and plural both read correctly', () => {
  assert.match(overrideStatus(1, ABSENT).text, /\b1 override row\b/);
  assert.match(overrideStatus(2, ABSENT).text, /\b2 override rows\b/);
});

test('a dead status is flagged so the caller can style it as a problem', () => {
  assert.equal(overrideStatus(2, ABSENT).warn, true);
  assert.equal(overrideStatus(2, PRESENT).warn, false);
  assert.equal(overrideStatus(0, PRESENT).warn, false);
});
