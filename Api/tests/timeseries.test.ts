// TDD for the Prometheus timeseries ALLOWLIST. Written BEFORE app/src/timeseries.ts exists,
// so the first run must fail with ERR_MODULE_NOT_FOUND.
//
// THE SECURITY BOUNDARY: the browser sends a KEY from a fixed table and never PromQL. The
// server holds the query string. There is no free-form query path to escape from, so what
// follows pins the table and proves the resolver refuses everything that is not a key.
// Same shape as settings-keys.test.ts, which guards the other key->file allowlist.
//
// LIVES HERE, NOT IN app/src/: Deploy-Api.ps1 copies app/src wholesale and remote/deploy.sh
// rsyncs it to /opt/api/src, so a test placed beside the code ships to the live box. The
// runner globs the whole repo, so it is found here just the same.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  METRICS, isMetricKey, resolveMetrics, resolveHours, nameSelector, STEP_SECONDS, makeTimeseries,
} from '../app/src/timeseries.ts';

const keys = () => METRICS.map((m) => m.key);
const err = (fn: () => unknown): { statusCode?: number; message: string } => {
  try { fn(); } catch (e) { return e as { statusCode?: number; message: string }; }
  throw new Error('expected a throw, got none');
};

// --- 1. the table, pinned in BOTH directions -----------------------------------------------
// An exact set, not a ceiling: a key silently LEAVING is as much a defect as one appearing.
// That is the lesson mechanism-counts.test.ps1 records - a ceiling cannot see a retirement.
test('the allowlist is exactly the owner-approved key -> series table', () => {
  const APPROVED: Record<string, string> = {
    server_fps: 'dayz_server_fps',
    players_online: 'dayz_players_online',
    host_load: 'node_load1',
    dayz_memory: 'dayz_process_memory_bytes',
    host_mem_avail: 'node_memory_MemAvailable_bytes',
    dayz_threads: 'dayz_process_tasks',
    persistence_size: 'dayz_persistence_bytes',
    log_dir_size: 'dayz_log_dir_bytes',
    unique_players_24h: 'dayz_players_unique_24h',
    server_up: 'dayz_up',
  };
  assert.deepEqual(
    Object.fromEntries(METRICS.map((m) => [m.key, m.series])), APPROVED,
    'adding or dropping a chart is a deliberate edit to this table, never a drive-by',
  );
});

test('server_fps is PINNED; players_online is on by default', () => {
  assert.equal(METRICS.find((m) => m.key === 'server_fps')?.pinned, true,
    'the pin is server-owned - a browser cannot turn it off');
  assert.equal(METRICS.filter((m) => m.pinned).length, 1, 'exactly one pinned metric');
  assert.equal(METRICS.find((m) => m.key === 'players_online')?.on, true);
});

test('every row carries the label + unit the UI renders (one table, no browser-side twin)', () => {
  for (const m of METRICS) {
    assert.match(m.key, /^[a-z][a-z0-9_]*$/, `${m.key} must be a bare snake_case key`);
    assert.match(m.series, /^[a-z][a-z0-9_]*$/, `${m.series} must be a bare metric name`);
    assert.ok(m.label && m.label.trim().length, `${m.key} needs a label`);
    assert.ok(['bytes', 'fps', ''].includes(m.unit), `${m.key} has an unknown unit '${m.unit}'`);
  }
});

// --- 2. the resolver refuses everything that is not a key -----------------------------------
test('isMetricKey allows exactly the known keys', () => {
  for (const k of keys()) assert.equal(isMetricKey(k), true, `${k} must be a key`);
});

test('isMetricKey rejects unknown / unsafe / non-string keys', () => {
  for (const bad of ['fps', 'SERVER_FPS', 'dayz_up', '../server_fps', '', 'server_fps ',
    undefined, null, 0, {}, [], true]) {
    assert.equal(isMetricKey(bad), false, `${String(bad)} must not be a metric key`);
  }
});

test('an unknown key is a 400 that NAMES the offending key', () => {
  const e = err(() => resolveMetrics(['server_fps', 'cpu_temp']));
  assert.equal(e.statusCode, 400);
  assert.match(e.message, /cpu_temp/, 'the caller must be told which key was refused');
  assert.doesNotMatch(e.message, /dayz_/, 'the refusal must not leak the PromQL side of the table');
});

test('anything resembling PromQL is refused as a key - there is no query path', () => {
  const promql = [
    'dayz_up', 'up', 'rate(dayz_up[5m])', 'dayz_players_online{job="dayz-api"}',
    'sum(dayz_up) by (instance)', '{__name__=~".+"}', 'dayz_up or vector(1)',
    'server_fps;dayz_up', 'server_fps[24h]', 'server_fps offset 5m', 'topk(5, dayz_up)', '1',
    'node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes',
  ];
  for (const q of promql) {
    assert.equal(isMetricKey(q), false, `PromQL must never pass as a key: ${q}`);
    assert.equal(err(() => resolveMetrics([q])).statusCode, 400, `resolveMetrics must refuse: ${q}`);
  }
});

test('resolveMetrics keeps TABLE order and always includes the pinned metric', () => {
  assert.deepEqual(resolveMetrics(['host_load', 'players_online']).map((m) => m.key),
    ['server_fps', 'players_online', 'host_load'],
    'the pin is added server-side and the table order is the display order');
  assert.deepEqual(resolveMetrics([]).map((m) => m.key), ['server_fps'],
    'an empty selection still draws the pinned line');
  assert.deepEqual(resolveMetrics(['server_fps', 'server_fps']).map((m) => m.key), ['server_fps'],
    'duplicates collapse');
});

test('resolveMetrics refuses a non-array "metrics"', () => {
  for (const bad of ['server_fps', { key: 'server_fps' }, 5, null]) {
    assert.equal(err(() => resolveMetrics(bad)).statusCode, 400);
  }
});

test('hours is exactly 6, 12 or 24', () => {
  for (const h of [6, 12, 24]) assert.equal(resolveHours(h), h);
  assert.equal(resolveHours('12'), 12, 'a numeric string from a query param is fine');
  for (const bad of [1, 5, 25, 48, 720, 0, -6, 'all', '', null, undefined, {}, NaN]) {
    assert.equal(err(() => resolveHours(bad)).statusCode, 400, `hours ${String(bad)} must be refused`);
  }
});

// --- 3. the instant-value selector is built from the table, never from input ----------------
test('nameSelector is fully anchored and built only from allowlisted series names', () => {
  const sel = nameSelector(resolveMetrics(['host_load']));
  assert.equal(sel, '{__name__=~"^(dayz_server_fps|node_load1)$"}');
  // Anchors are the whole defence: without them a series name that is a prefix of another
  // would drag the other one back too.
  const alts = /\^\((.+)\)\$/.exec(sel)![1].split('|');
  const known = new Set(METRICS.map((m) => m.series));
  for (const a of alts) {
    assert.ok(known.has(a), `${a} is not an allowlisted series`);
    assert.match(a, /^[a-z][a-z0-9_]*$/, 'a series name cannot carry regex metacharacters');
  }
});

// --- 4. every allowlisted series is one this repo actually produces --------------------------
// The dayz_* half is provable offline and IS the real drift risk: metrics.ts is ours, and
// renaming a gauge there would silently empty a chart. node_* comes from node_exporter, which
// the repo deploys but does not author - the live existence check is the PROM_URL test below.
test('every dayz_* series in the allowlist is emitted by metrics.ts', () => {
  const src = readFileSync(new URL('../app/src/metrics.ts', import.meta.url), 'utf8');
  const emitted = new Set<string>();
  for (const m of src.matchAll(/\bone\(\s*'([a-z][a-z0-9_]*)'/g)) emitted.add(m[1]);
  for (const m of src.matchAll(/\bname:\s*'([a-z][a-z0-9_]*)'/g)) emitted.add(m[1]);
  assert.ok(emitted.size > 5, 'sanity: the scan found the exporter gauges');
  for (const m of METRICS.filter((x) => x.series.startsWith('dayz_'))) {
    assert.ok(emitted.has(m.series),
      `${m.key} -> ${m.series} is charted but metrics.ts never emits it - that chart is permanently empty`);
  }
});

test('every node_* series comes from an exporter the Monitoring stack deploys', () => {
  const cfg = readFileSync(new URL('../../Monitoring/deploy/deploy.config.json', import.meta.url), 'utf8');
  assert.ok(METRICS.some((m) => m.series.startsWith('node_')), 'sanity: there are host series');
  assert.match(cfg, /"NodeExporterListen"/,
    'the node_* charts assume node_exporter is deployed by the Monitoring stack');
});

// LIVE existence check - the only way to prove a series is really in the TSDB. Skipped loudly
// when there is no Prometheus to ask, so it never passes vacuously.
test('every allowlisted series exists in a real Prometheus (set PROM_URL to run)', async (t) => {
  const url = process.env.PROM_URL;
  if (!url) { t.skip('PROM_URL not set - with a tunnel up: PROM_URL=http://127.0.0.1:9090 node --test'); return; }
  const res = await fetch(`${url}/api/v1/label/__name__/values`);
  assert.ok(res.ok, `Prometheus label query failed: HTTP ${res.status}`);
  const body = await res.json() as { data: string[] };
  const live = new Set(body.data);
  const missing = METRICS.filter((m) => !live.has(m.series)).map((m) => `${m.key} -> ${m.series}`);
  assert.deepEqual(missing, [], 'these charts would draw nothing');
});

// --- 5. the query: one range fetch per metric + ONE instant fetch for "now" -----------------
const rangeBody = (points: Array<[number, number]>) => ({
  status: 'success',
  data: {
    resultType: 'matrix',
    result: points.length ? [{ metric: {}, values: points.map(([t, v]) => [t, String(v)]) }] : [],
  },
});
const instantBody = (vals: Record<string, number>) => ({
  status: 'success',
  data: {
    resultType: 'vector',
    result: Object.entries(vals).map(([n, v]) => ({ metric: { __name__: n }, value: [1785700000, String(v)] })),
  },
});

/** Fake Prometheus: records every URL asked for, answers range and instant queries. */
function fakeProm(series: Record<string, Array<[number, number]>>) {
  const seen: string[] = [];
  const impl = async (url: string) => {
    seen.push(url);
    const u = new URL(url);
    const q = u.searchParams.get('query') ?? '';
    if (u.pathname.endsWith('/query_range')) return { ok: true, json: async () => rangeBody(series[q] ?? []) };
    const latest: Record<string, number> = {};
    for (const [name, pts] of Object.entries(series)) {
      if (q.includes(name) && pts.length) latest[name] = pts[pts.length - 1][1];
    }
    return { ok: true, json: async () => instantBody(latest) };
  };
  return { seen, impl: impl as unknown as typeof fetch };
}

const FPS: Array<[number, number]> = [[1785600000, 6600], [1785600300, 6700], [1785600600, 6800]];
const PLAYERS: Array<[number, number]> = [[1785600000, 2], [1785600300, 3], [1785600600, 3]];

test('the response carries the points AND the latest value, so no second request is needed', async () => {
  const prom = fakeProm({ dayz_server_fps: FPS, dayz_players_online: PLAYERS });
  const r = await makeTimeseries('http://127.0.0.1:9090', prom.impl)(['players_online'], 24);

  assert.deepEqual(r.metrics.map((m) => m.key), ['server_fps', 'players_online']);
  const players = r.metrics.find((m) => m.key === 'players_online')!;
  assert.deepEqual(players.points, PLAYERS, 'the drawn line');
  assert.equal(players.latest?.value, 3, 'the number the panel prints, from the SAME response');
  assert.equal(r.step, STEP_SECONDS);
  assert.equal(r.hours, 24);
  assert.equal(r.to - r.from, 24 * 3600, 'the window matches the requested hours');
});

test('the response carries the whole catalogue so the picker has ONE source', async () => {
  const prom = fakeProm({ dayz_server_fps: FPS });
  const r = await makeTimeseries('http://127.0.0.1:9090', prom.impl)([], 6);
  assert.deepEqual(r.available.map((m) => m.key), keys(), 'the picker is built from the server table');
  for (const a of r.available) {
    assert.ok('label' in a && 'unit' in a && 'pinned' in a && 'on' in a);
  }
});

test('exactly ONE instant query serves every requested metric', async () => {
  const prom = fakeProm({ dayz_server_fps: FPS, dayz_players_online: PLAYERS, node_load1: [[1785600600, 0.4]] });
  await makeTimeseries('http://127.0.0.1:9090', prom.impl)(['players_online', 'host_load'], 12);
  assert.equal(prom.seen.filter((u) => !u.includes('/query_range')).length, 1,
    'one vector selector covers all three - not one round trip each');
  assert.equal(prom.seen.filter((u) => u.includes('/query_range')).length, 3, 'one range fetch per metric');
});

test('the range query asks for the requested window at the fixed step', async () => {
  const prom = fakeProm({ dayz_server_fps: FPS });
  await makeTimeseries('http://127.0.0.1:9090', prom.impl)([], 6);
  const u = new URL(prom.seen.find((s) => s.includes('/query_range'))!);
  assert.equal(u.searchParams.get('query'), 'dayz_server_fps', 'the query is the table series, verbatim');
  assert.equal(u.searchParams.get('step'), String(STEP_SECONDS));
  assert.equal(Number(u.searchParams.get('end')) - Number(u.searchParams.get('start')), 6 * 3600);
  assert.equal(u.origin, 'http://127.0.0.1:9090', 'loopback only');
});

test('a series Prometheus does not have degrades to no points and a null latest', async () => {
  const prom = fakeProm({ dayz_server_fps: [] });
  const r = await makeTimeseries('http://127.0.0.1:9090', prom.impl)([], 24);
  assert.deepEqual(r.metrics[0].points, []);
  assert.equal(r.metrics[0].latest, null, 'a missing feed reads as "no data", never as a stale number');
});

test('gaps are passed through untouched - the API never invents a point', async () => {
  // Prometheus omits what it never collected. Filling the hole here would push a fabricated
  // measurement to the chart, where it is indistinguishable from a real one.
  const holed: Array<[number, number]> = [[1785600000, 1], [1785600300, 1], [1785604800, 1]];
  const prom = fakeProm({ dayz_server_fps: holed });
  const r = await makeTimeseries('http://127.0.0.1:9090', prom.impl)([], 24);
  assert.deepEqual(r.metrics[0].points, holed, 'same points in, same points out');
});

test('NaN samples are dropped rather than plotted as zero', async () => {
  const nanProm = (async (url: string) => ({
    ok: true,
    json: async () => (String(url).includes('/query_range')
      ? { status: 'success', data: { resultType: 'matrix', result: [{ metric: {}, values: [[1785600000, 'NaN'], [1785600300, '0.5']] } ] } }
      : { status: 'success', data: { resultType: 'vector', result: [{ metric: { __name__: 'dayz_server_fps' }, value: [1785600300, 'NaN'] }] } }),
  })) as unknown as typeof fetch;
  const r = await makeTimeseries('http://127.0.0.1:9090', nanProm)([], 6);
  assert.deepEqual(r.metrics[0].points, [[1785600300, 0.5]], 'the NaN sample is gone, the real one stays');
  assert.equal(r.metrics[0].latest, null, 'a NaN instant value is no value at all');
});

test('identical requests inside the cache window make ONE round of fetches', async () => {
  const prom = fakeProm({ dayz_server_fps: FPS });
  const query = makeTimeseries('http://127.0.0.1:9090', prom.impl);
  await query([], 24);
  const after = prom.seen.length;
  await query([], 24);
  assert.equal(prom.seen.length, after, 'a second browser tab must not double the Prometheus load');
  await query([], 6);
  assert.ok(prom.seen.length > after, 'a different window is a different question');
});

test('a Prometheus that is down fails the action, it does not fabricate a chart', async () => {
  const down = (async () => { throw new Error('ECONNREFUSED'); }) as unknown as typeof fetch;
  await assert.rejects(() => makeTimeseries('http://127.0.0.1:9090', down)([], 24));
  const http500 = (async () => ({ ok: false, status: 500, json: async () => ({}) })) as unknown as typeof fetch;
  await assert.rejects(() => makeTimeseries('http://127.0.0.1:9090', http500)([], 24));
});

test('a failed collection is not cached for the whole window', async () => {
  let calls = 0;
  const flaky = (async (url: string) => {
    calls++;
    if (calls <= 2) throw new Error('ECONNREFUSED');
    return { ok: true, json: async () => (String(url).includes('/query_range') ? rangeBody(FPS) : instantBody({ dayz_server_fps: 6800 })) };
  }) as unknown as typeof fetch;
  const query = makeTimeseries('http://127.0.0.1:9090', flaky);
  await assert.rejects(() => query([], 24));
  await assert.doesNotReject(() => query([], 24), 'the next poll must retry, not serve the failure');
});
