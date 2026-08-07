// The live overlays: one mechanism, three rows.
//
// The bar counted live AI for months while nothing drew them - the renderer was written for a
// retired mod and switched off, and the count came from elsewhere and kept working. The cause
// was three near-identical overlays maintained separately, so a fix to one never reached the
// others. These assert the shared mechanism holds, and that the AI panel says what a spawn
// problem actually needs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { LIVE_LAYERS, LIVE_KINDS, liveLayer, liveVisible, livePositions, liveCount } from '../web/js/map-live-layers.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const JS = readFileSync(join(root, 'web/js/map.js'), 'utf8');

const STATE = {
  players: [{ x: 1, z: 2 }, { x: 3, z: 4 }],
  ai: [{ x: 5, z: 6, type: 'eai', age: 700 }],
  ship: [{ x: 7, z: 8, state: 'patrol', target: 'Dock' }],
};

test('every declared layer is complete - a half-declared row is a layer that half-works', () => {
  assert.ok(LIVE_LAYERS.length >= 3, 'players, AI and the ship at minimum');
  for (const l of LIVE_LAYERS) {
    assert.ok(l.key, 'a key');
    assert.ok(l.cssVar && l.fallback, `${l.key} declares a colour with a fallback`);
    assert.ok(l.marker, `${l.key} declares a marker shape`);
    assert.ok(l.source, `${l.key} declares where its positions come from`);
    assert.equal(typeof l.badge, 'function', `${l.key} declares what the status bar says`);
    assert.equal(typeof l.pick, 'boolean', `${l.key} declares whether it can be clicked`);
  }
  assert.deepEqual(LIVE_KINDS, LIVE_LAYERS.map((l) => l.key), 'the toggle list IS the table');
});

test('live overlays are hidden off the running mission - on every layer at once', () => {
  // Live coordinates on another map are fiction. This used to be repeated per layer, so it
  // could be (and was) forgotten on a new one.
  for (const l of LIVE_LAYERS) {
    assert.equal(liveVisible(l, { onLiveMission: false, selected: true }), false, `${l.key} off-mission`);
    assert.equal(liveVisible(l, { onLiveMission: true, selected: false }), false, `${l.key} toggled off`);
    assert.equal(liveVisible(l, { onLiveMission: true, selected: true }), true, `${l.key} on the live map, toggled on`);
  }
});

test('a layer counts and draws THE SAME positions - the bug that started this', () => {
  for (const l of LIVE_LAYERS) {
    const pos = livePositions(l, STATE);
    assert.equal(liveCount(l, STATE, { onLiveMission: true }), pos.length,
      `${l.key}: the count must come from the positions that get drawn, never a second source`);
  }
  assert.equal(livePositions(liveLayer('NPCs'), STATE).length, 1);
  assert.equal(liveCount(liveLayer('NPCs'), STATE, { onLiveMission: false }), 0, 'off-mission counts zero');
});

test('missing or malformed live state reads as empty, never throws', () => {
  for (const l of LIVE_LAYERS) {
    assert.deepEqual(livePositions(l, {}), [], 'a poller that has not run yet is normal');
    assert.deepEqual(livePositions(l, null), []);
    assert.deepEqual(livePositions(l, { [l.source]: 'nonsense' }), []);
  }
});

test('each layer says its own piece in the status bar', () => {
  const ai = liveLayer('NPCs');
  assert.match(ai.badge(STATE.ai, {}).text, /1 AI/);
  assert.equal(ai.badge([], {}), null, 'nothing to say when there is nothing there');
  assert.equal(ai.badge([], { stale: true }).stale, true, 'a dead feed is labelled, not silently empty');
  assert.match(liveLayer('Players').badge(STATE.players, { at: '10:00' }).text, /2 players.*10:00/);
  assert.match(liveLayer('Ship').badge(STATE.ship, {}).text, /patrol/);
});

test('the map draws every layer through the table, not one function per layer', () => {
  assert.match(JS, /function drawLiveLayers\(/, 'one renderer over the table');
  assert.doesNotMatch(JS, /function drawMapPlayers\(/, 'the per-layer copies must be gone, not left beside it');
  assert.doesNotMatch(JS, /function drawMapAI\(/);
  // The ship keeps its own function for its route and docks - that is genuinely its own, and
  // it still asks the shared gate rather than re-deriving one.
  assert.match(JS, /liveOn\('Ship'\)/, 'even the exception uses the shared visibility rule');
  const names = (JS.match(/'(Players|NPCs|Ship)'/g) || []).length;
  assert.ok(names <= 2, `layer names should barely appear in map.js; found ${names}`);
});

test('a live AI can be picked, and picking one owns the detail panel', () => {
  assert.match(JS, /function mapHitLive\(/, 'hit-testing runs over the pickable layers');
  const hit = JS.slice(JS.indexOf('function mapHitLive('), JS.indexOf('// WHICH patrol'));
  assert.match(hit, /if \(!l\.pick/, 'only layers the table marks pickable can be clicked');
  const sel = JS.slice(JS.indexOf('function selectMapAI('), JS.indexOf('async function loadPlayers('));
  assert.match(sel, /mapSelPt = -1/, 'selecting an AI clears the point selection - one panel, one subject');
});

test('the AI panel is built from the DATA, not from a hardcoded field list', () => {
  const fn = JS.slice(JS.indexOf('function renderAIDetail('), JS.indexOf('function renderMapDetail('));
  for (const hardcoded of ['MinDistRadius', 'MaxDistRadius', 'DespawnRadius', 'NumberOfAI']) {
    assert.ok(!fn.includes(`'${hardcoded}'`) && !fn.includes(`.${hardcoded}`),
      `${hardcoded} must not be named here - an Expansion rename would blank the row silently`);
  }
  assert.match(fn, /Object\.(keys|entries)/, 'the patrol record is walked, so new fields appear on their own');
});

test('the source patrol is presented as INFERRED, with its distance', () => {
  const fn = JS.slice(JS.indexOf('function nearestPatrol('), JS.indexOf('function selectMapAI('));
  assert.match(fn, /Math\.hypot/, 'nearest is measured, not assumed');
  const panel = JS.slice(JS.indexOf('function renderAIDetail('), JS.indexOf('function renderMapDetail('));
  assert.match(panel, /likely patrol/, 'the panel must say the match is a likelihood');
  assert.match(panel, /away/, 'and show how far off it is, so a bad guess looks like one');
});
