// Unit test for the generalized settings-key allowlist (the security boundary: only an allowlisted
// key maps to an allowlisted file). Run: node --test (Node strips the TS types). Confirms, not
// assumes, that the generalization allows exactly patrols+locations and nothing traversable.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SETTINGS_KEYS, isSettingsKey } from './settings-keys.ts';

test('isSettingsKey allows exactly the known keys', () => {
  assert.equal(isSettingsKey('patrols'), true);
  assert.equal(isSettingsKey('locations'), true);
});

test('isSettingsKey rejects unknown / unsafe / non-string keys', () => {
  for (const bad of ['config', 'overrides', 'AIPatrolSettings', '../locations', '', 'PATROLS', undefined, null, 0, {}]) {
    assert.equal(isSettingsKey(bad), false, `${String(bad)} must not be a settings key`);
  }
});

test('each key maps to a fixed AI-settings filename (no caller-supplied path)', () => {
  assert.equal(SETTINGS_KEYS.patrols.file, 'AIPatrolSettings.json');
  assert.equal(SETTINGS_KEYS.locations.file, 'AILocationSettings.json');
  for (const meta of Object.values(SETTINGS_KEYS)) {
    assert.match(meta.file, /^[A-Za-z]+\.json$/, 'filename must be a bare *.json, never a path');
  }
});
