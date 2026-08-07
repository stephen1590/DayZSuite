// Live AI on the map.
//
// The bar counted live AI for months while nothing drew them: the renderer was written for a
// retired mod and switched off, and the count came from a different source that kept working.
// A number with no marker is worse than neither, so these pin the whole path - the layer draws,
// it can be picked, and the panel it opens carries the metadata needed to troubleshoot a spawn.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const JS = readFileSync(join(root, 'web/js/map.js'), 'utf8');

test('the live-AI layer is DRAWN, not merely counted', () => {
  assert.match(JS, /function drawMapAI\(/, 'there must be a renderer for live AI');
  assert.match(JS, /drawMapAI\(ctx\)/, 'and the frame must call it');
  const fn = JS.slice(JS.indexOf('function drawMapAI('), JS.indexOf('function mapHitAI('));
  assert.match(fn, /mapBandits\.positions/, 'it must draw the SAME data the bar counts');
  assert.match(fn, /mapLiveSel\.has\('NPCs'\)/, 'and respect the layer toggle that reports the count');
  assert.match(fn, /mapMission !== getActiveMission\(\)/,
    'live positions only mean anything on the running mission - plotting them on another map is fiction');
});

test('a live AI can be picked, and picking one owns the detail panel', () => {
  assert.match(JS, /function mapHitAI\(/, 'a hit test for the AI markers');
  assert.match(JS, /function selectMapAI\(/, 'and a selection for them');
  const sel = JS.slice(JS.indexOf('function selectMapAI('), JS.indexOf('async function loadPlayers('));
  assert.match(sel, /mapSelPt = -1/, 'selecting an AI must clear the point selection - one panel, one subject');
  const detail = JS.slice(JS.indexOf('function renderMapDetail('), JS.indexOf('function renderMapDetail(') + 400);
  assert.match(detail, /mapSelAI > -1.*renderAIDetail\(\)/s, 'the panel must hand over to the AI view when one is picked');
});

test('the AI panel carries what a spawn problem needs', () => {
  const fn = JS.slice(JS.indexOf('function renderAIDetail('), JS.indexOf('function renderMapDetail('));
  for (const field of ['Type', 'Position', 'Alive for', 'Snapshot age']) {
    assert.ok(fn.includes(field), `the panel must report ${field} - it is what the tracker actually knows`);
  }
  for (const setting of ['MinDistRadius', 'MaxDistRadius', 'DespawnRadius', 'RespawnTime', 'Chance', 'NumberOfAI']) {
    assert.ok(fn.includes(setting), `the panel must show ${setting} - the settings that decide whether this AI should exist`);
  }
  assert.match(fn, /inherits/, "-1 must read as 'inherits', never as a literal -1 nobody can act on");
  assert.match(fn, /stale/, 'a stale snapshot must be labelled, or an old position reads as current');
});

test('the source patrol is presented as INFERRED, with its distance', () => {
  // The tracker reports a position and nothing else. Naming a patrol as fact would be a guess
  // wearing a label, and two patrols can share ground.
  const fn = JS.slice(JS.indexOf('function nearestPatrol('), JS.indexOf('function selectMapAI('));
  assert.match(fn, /Math\.hypot/, 'nearest is measured, not assumed');
  assert.match(fn, /Waypoints/, 'measured against the patrol waypoints in the live document');
  const panel = JS.slice(JS.indexOf('function renderAIDetail('), JS.indexOf('function renderMapDetail('));
  assert.match(panel, /likely patrol/, 'the panel must say the match is a likelihood');
  assert.match(panel, /away/, 'and show how far off it is, so a bad guess is visible as a bad guess');
});
