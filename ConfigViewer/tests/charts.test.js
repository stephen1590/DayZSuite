// THE RULE THIS FILE EXISTS TO ENFORCE: a gap is DRAWN, never interpolated. Prometheus omits
// the points it never collected, so a run of missing timestamps IS an outage. Joining the two
// sides with a straight line claims a measurement that was never taken, and would draw a severe
// outage as a smooth line through the crater.
//
// charts.js is deliberately DOM-free and returns SVG markup as a string: it is the geometry,
// not the wiring, so it is provable here with no browser. It also never imports apiPost, which
// keeps it off the box-writing module list mechanism-counts.test.ps1 pins.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { STEP, segments, gaps, fmt, colourFor, sparkline, chartSvg } from '../web/js/charts.js';

const T0 = 1785600000;
// A clean 6h run at the 300s step: 72 points, no holes.
const clean = Array.from({ length: 72 }, (_, i) => [T0 + i * STEP, 10 + i]);
// The same run with 40 minutes missing in the middle (points 30..37 never collected).
const holed = clean.filter((_, i) => i < 30 || i >= 38);

test('the step is the 300s the API queries at', () => {
  assert.equal(STEP, 300);
});

// --- segments: the anti-interpolation primitive ---------------------------------------------
test('an unbroken series is ONE segment', () => {
  assert.equal(segments(clean).length, 1);
  assert.equal(segments(clean)[0].length, clean.length, 'no point is dropped');
});

test('a gap in a series produces MORE THAN ONE segment', () => {
  const segs = segments(holed);
  assert.equal(segs.length, 2, 'the hole splits the line in two');
  assert.equal(segs[0].length + segs[1].length, holed.length, 'every collected point is still drawn');
  assert.equal(segs[0][segs[0].length - 1][0], T0 + 29 * STEP, 'first segment ends at the last point before the hole');
  assert.equal(segs[1][0][0], T0 + 38 * STEP, 'second segment starts at the first point after it');
});

test('two holes produce three segments', () => {
  const twice = clean.filter((_, i) => !(i >= 10 && i < 18) && !(i >= 40 && i < 50));
  assert.equal(segments(twice).length, 3);
});

test('the split threshold is a MISSED step, not merely an uneven one', () => {
  // Prometheus timestamps drift by a second or two; that is not an outage. The break is
  // step * 1.8, so one skipped sample splits and jitter does not.
  const jittery = [[T0, 1], [T0 + STEP + 2, 2], [T0 + 2 * STEP - 3, 3]];
  assert.equal(segments(jittery).length, 1, 'a couple of seconds of drift is not a gap');
  const skipped = [[T0, 1], [T0 + 2 * STEP, 2]];
  assert.equal(segments(skipped).length, 2, 'one missed sample IS a gap');
});

test('empty and single-point series do not throw', () => {
  assert.deepEqual(segments([]), []);
  assert.equal(segments([[T0, 1]]).length, 1);
});

// --- gaps: the band that gets drawn instead of a line ----------------------------------------
test('an interior gap is reported as the span between the points that bracket it', () => {
  const g = gaps(holed, T0, T0 + 71 * STEP);
  assert.equal(g.length, 1);
  assert.deepEqual(g[0], [T0 + 29 * STEP, T0 + 38 * STEP]);
});

test('a series that starts late reports a LEADING gap', () => {
  const late = clean.slice(20);
  const g = gaps(late, T0, T0 + 71 * STEP);
  assert.equal(g.length, 1);
  assert.equal(g[0][0], T0, 'the band starts at the window edge, not at the first point');
  assert.equal(g[0][1], late[0][0]);
});

test('a series that stops early reports a TRAILING gap', () => {
  const early = clean.slice(0, 40);
  const end = T0 + 71 * STEP;
  const g = gaps(early, T0, end);
  assert.equal(g.length, 1);
  assert.deepEqual(g[0], [early[early.length - 1][0], end]);
});

test('a clean series covering the whole window reports NO gaps', () => {
  assert.deepEqual(gaps(clean, T0, T0 + 71 * STEP), []);
});

test('an empty series reports no gaps rather than one giant band', () => {
  // Nothing collected at all is "no data" - the caller renders that, not a misleading band.
  assert.deepEqual(gaps([], T0, T0 + 3600), []);
});

// --- the rendered output: the claim has to survive to the markup -----------------------------
const strokePaths = (svg) => [...svg.matchAll(/<path\b[^>]*stroke:[^>]*\bd="([^"]+)"|<path\b[^>]*\bd="([^"]+)"[^>]*stroke:/g)]
  .map((m) => m[1] ?? m[2]);
const allPathData = (svg) => [...svg.matchAll(/\bd="([^"]+)"/g)].map((m) => m[1]);

test('a holed series renders TWO separate lines, never one crossing the hole', () => {
  const svg = chartSvg(holed, { from: T0, to: T0 + 71 * STEP, unit: '', colour: 'var(--info)' });
  const lines = strokePaths(svg);
  assert.equal(lines.length, 2, 'one stroked path per segment');
  // Every collected point must appear exactly once across the two lines: nothing dropped,
  // nothing bridged. Each path is M followed by L per subsequent point.
  const drawn = lines.reduce((n, d) => n + (d.match(/[ML]/g) || []).length, 0);
  assert.equal(drawn, holed.length, 'every point drawn once, no invented midpoint');
});

test('the hole is drawn AS A BAND, and labelled when it is wide enough to read', () => {
  const svg = chartSvg(holed, { from: T0, to: T0 + 71 * STEP, unit: '', colour: 'var(--info)' });
  assert.match(svg, /<rect[^>]*class="gap"/, 'the outage is visible as a band');
  assert.match(svg, /not collected/, 'and is named, so nobody reads it as a flat line');
});

test('a clean series renders ONE line and no band', () => {
  const svg = chartSvg(clean, { from: T0, to: T0 + 71 * STEP, unit: '', colour: 'var(--info)' });
  assert.equal(strokePaths(svg).length, 1);
  assert.doesNotMatch(svg, /class="gap"/);
});

test('sparklines obey the same rule - no bridging in the small chart either', () => {
  const svg = sparkline(holed, { from: T0, to: T0 + 71 * STEP, colour: 'var(--ok)' });
  assert.equal(strokePaths(svg).length, 2, 'the sparkline splits at the gap too');
  assert.match(svg, /<rect[^>]*class="gap"/);
});

test('an empty series renders a "no data" note, not an empty chart that looks like zero', () => {
  const svg = chartSvg([], { from: T0, to: T0 + 3600, unit: '', colour: 'var(--info)' });
  assert.match(svg, /no data/i);
  assert.deepEqual(allPathData(svg), [], 'nothing is plotted');
  assert.equal(sparkline([], { from: T0, to: T0 + 3600, colour: 'var(--ok)' }), '',
    'an empty sparkline draws nothing at all');
});

test('a flat series still renders a line (a constant is data, not a divide-by-zero)', () => {
  const flat = Array.from({ length: 20 }, (_, i) => [T0 + i * STEP, 7]);
  const svg = chartSvg(flat, { from: T0, to: T0 + 19 * STEP, unit: '', colour: 'var(--ok)' });
  assert.equal(strokePaths(svg).length, 1);
  assert.doesNotMatch(svg, /NaN/, 'a zero value-range must not produce NaN coordinates');
});

test('no rendered coordinate is ever NaN or Infinity', () => {
  for (const svg of [
    chartSvg(holed, { from: T0, to: T0 + 71 * STEP, unit: 'bytes', colour: 'var(--drift)' }),
    sparkline(clean, { from: T0, to: T0 + 71 * STEP, colour: 'var(--info)' }),
  ]) {
    assert.doesNotMatch(svg, /NaN|Infinity/);
  }
});

// --- units + colours -------------------------------------------------------------------------
test('fmt renders each unit the way the POC does', () => {
  assert.equal(fmt(1073741824, 'bytes'), '1.00 GB');
  assert.equal(fmt(6800.4, 'fps'), '6800 fps');
  assert.equal(fmt(0.42, ''), '0.42', 'small numbers keep their precision');
  assert.equal(fmt(1234.6, ''), '1235', 'large numbers round');
});

test('colourFor covers every server key and falls back rather than emitting undefined', () => {
  // The server owns the allowlist; the browser owns the palette. The fallback is what makes
  // that split safe - a key added server-side gets a real colour, never "var(undefined)".
  assert.match(colourFor('server_fps'), /^var\(--[a-z0-9-]+\)$/);
  assert.match(colourFor('a_key_the_browser_has_never_heard_of'), /^var\(--[a-z0-9-]+\)$/);
});
