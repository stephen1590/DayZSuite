// Historical series for the Maintenance tab's charts, read from the on-box Prometheus over
// loopback. THE BROWSER SENDS A KEY, NEVER PromQL: the table below is the whole vocabulary,
// and the query string for each row lives here, server-side. There is no free-form query
// path, so there is nothing to inject and no new credential anywhere — Prometheus listens on
// loopback, unauthenticated, and stays unreachable from outside the box. The address comes
// from config (Deploy-Api derives it from the Monitoring stack); this module never knows a port.
//
// Grafana is deliberately NOT in this path. Embedding it would have meant allow_embedding,
// anonymous auth or a public dashboard — three ways to widen the box's public surface for a
// feature that only ever needs ten numbers.
//
// Adding a chart = adding a row here. That is the same shape as a config-registry row: one
// declaration, and the tiers derive from it (the picker is built from what this returns).
export interface MetricDef {
  /** What the browser sends. Bare snake_case; the only caller-supplied token in the path. */
  key: string;
  /** Display name — served to the browser so the picker has ONE source, not a second table. */
  label: string;
  /** The Prometheus series. Never accepted from a caller. */
  series: string;
  /** How the UI formats the value. */
  unit: 'bytes' | 'fps' | '';
  /** Always charted, whatever the caller asks for (the UI shows it checked + disabled). */
  pinned?: boolean;
  /** Ticked by default on first load. */
  on?: boolean;
}

export const METRICS: MetricDef[] = [
  { key: 'server_fps', label: 'Server FPS', series: 'dayz_server_fps', unit: 'fps', pinned: true },
  { key: 'players_online', label: 'Players online', series: 'dayz_players_online', unit: '', on: true },
  { key: 'host_load', label: 'Host load (1m)', series: 'node_load1', unit: '' },
  { key: 'dayz_memory', label: 'DayZ memory', series: 'dayz_process_memory_bytes', unit: 'bytes' },
  { key: 'host_mem_avail', label: 'Host memory free', series: 'node_memory_MemAvailable_bytes', unit: 'bytes' },
  { key: 'dayz_threads', label: 'DayZ threads', series: 'dayz_process_tasks', unit: '' },
  { key: 'persistence_size', label: 'Persistence size', series: 'dayz_persistence_bytes', unit: 'bytes' },
  { key: 'log_dir_size', label: 'Log dir size', series: 'dayz_log_dir_bytes', unit: 'bytes' },
  { key: 'unique_players_24h', label: 'Unique players (24h)', series: 'dayz_players_unique_24h', unit: '' },
  { key: 'server_up', label: 'Server up/down', series: 'dayz_up', unit: '' },
];

/** Step between points. 300s over 24h is 288 points — enough to see an incident, small enough
 *  to send. It is also the gap yardstick: the browser splits a line at 1.8 missed steps. */
export const STEP_SECONDS = 300;

/** The only windows on offer. Prometheus keeps 30d, but a 30d line at this step is 8640 points
 *  of noise, so the picker is capped to these three. */
export const RANGE_HOURS = [6, 12, 24] as const;

const BY_KEY = new Map(METRICS.map((m) => [m.key, m]));

/** Cache window. Long enough that a second browser tab is free, short enough that the "now"
 *  value the panels print is never visibly behind. Same shape as metrics.ts. */
const CACHE_TTL_MS = 15_000;

interface HttpError extends Error { statusCode: number }
function fail(statusCode: number, message: string): HttpError {
  return Object.assign(new Error(message), { statusCode });
}

export function isMetricKey(k: unknown): boolean {
  return typeof k === 'string' && BY_KEY.has(k);
}

/**
 * Caller keys -> table rows. Refuses anything that is not a key BY NAME, forces the pinned
 * row in, de-duplicates, and returns TABLE order (so the chart stack reads the same for
 * everyone regardless of what order the checkboxes were clicked).
 */
export function resolveMetrics(keys: unknown): MetricDef[] {
  if (!Array.isArray(keys)) throw fail(400, '"metrics" must be an array of metric keys');
  for (const k of keys) {
    if (!isMetricKey(k)) {
      throw fail(400, `unknown metric key ${JSON.stringify(k)} — pick from: ${METRICS.map((m) => m.key).join(', ')}`);
    }
  }
  const want = new Set(keys as string[]);
  return METRICS.filter((m) => m.pinned || want.has(m.key));
}

export function resolveHours(h: unknown): number {
  const n = typeof h === 'number' ? h : typeof h === 'string' && h.trim() !== '' ? Number(h) : NaN;
  if (!Number.isFinite(n) || !(RANGE_HOURS as readonly number[]).includes(n)) {
    throw fail(400, `"hours" must be one of ${RANGE_HOURS.join(', ')}`);
  }
  return n;
}

/**
 * One instant query for every requested metric at once. The alternation is assembled from
 * table series names only — a caller can never place a character in it, because the only
 * input that selects a row is a key that already matched the allowlist. Anchored, so a name
 * that is a prefix of another cannot drag it along.
 */
export function nameSelector(defs: MetricDef[]): string {
  return `{__name__=~"^(${defs.map((d) => d.series).join('|')})$"}`;
}

export interface Point extends Array<number> { 0: number; 1: number }
export interface MetricSeries {
  key: string; label: string; series: string; unit: string;
  points: Array<[number, number]>;
  latest: { at: number; value: number } | null;
}
/** The catalogue as served: pinned/on are normalised to real booleans so the picker can render
 *  a checkbox state directly instead of re-deriving "absent means false". */
export interface MetricOffer extends MetricDef { pinned: boolean; on: boolean }
export interface TimeseriesResult {
  hours: number; step: number; from: number; to: number;
  available: MetricOffer[];
  metrics: MetricSeries[];
}

const CATALOGUE: MetricOffer[] = METRICS.map((m) => ({ ...m, pinned: m.pinned === true, on: m.on === true }));

/** Prometheus renders sample values as strings, including "NaN" and "+Inf". A non-finite
 *  sample is not a measurement — dropping it is the same rule as never bridging a gap. */
function sample(v: unknown): number | null {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

export function makeTimeseries(promUrl: string, fetchImpl: typeof fetch = fetch) {
  const base = promUrl.replace(/\/$/, '');
  const cache = new Map<string, { at: number; body: Promise<TimeseriesResult> }>();

  async function ask(path: string, params: Record<string, string>): Promise<any> {
    const url = `${base}/api/v1/${path}?${new URLSearchParams(params).toString()}`;
    let res: Awaited<ReturnType<typeof fetch>>;
    try {
      res = await fetchImpl(url);
    } catch (e) {
      // Prometheus down / not installed. A 503 says "the history is unavailable"; a 500 would
      // claim the API itself broke, and the tab would show an error where it should show a gap.
      throw fail(503, `Prometheus unreachable at ${base}: ${e instanceof Error ? e.message : String(e)}`);
    }
    if (!res.ok) throw fail(503, `Prometheus returned HTTP ${res.status}`);
    return res.json();
  }

  async function collect(defs: MetricDef[], hours: number): Promise<TimeseriesResult> {
    const to = Math.floor(Date.now() / 1000);
    const from = to - hours * 3600;

    // One range query per series, plus ONE instant query covering all of them. The instant
    // value is what the panels print: the range's last point is step-aligned and can be up to
    // 300s behind, which would make the players count read staler than it does today.
    const ranges = defs.map((d) => ask('query_range', {
      query: d.series, start: String(from), end: String(to), step: String(STEP_SECONDS),
    }));
    const instant = ask('query', { query: nameSelector(defs) });
    const [rangeBodies, instantBody] = await Promise.all([Promise.all(ranges), instant]);

    const now = new Map<string, { at: number; value: number }>();
    for (const r of instantBody?.data?.result ?? []) {
      const name = r?.metric?.__name__;
      const at = Number(r?.value?.[0]);
      const value = sample(r?.value?.[1]);
      if (name && Number.isFinite(at) && value !== null) now.set(name, { at, value });
    }

    const metrics: MetricSeries[] = defs.map((d, i) => {
      const values = rangeBodies[i]?.data?.result?.[0]?.values ?? [];
      const points: Array<[number, number]> = [];
      for (const [t, v] of values) {
        const value = sample(v);
        const at = Number(t);
        // Holes stay holes. Prometheus omits what it never collected and this passes the
        // omission through untouched — the browser draws it as a band.
        if (value !== null && Number.isFinite(at)) points.push([at, value]);
      }
      return { key: d.key, label: d.label, series: d.series, unit: d.unit, points, latest: now.get(d.series) ?? null };
    });

    return { hours, step: STEP_SECONDS, from, to, available: CATALOGUE, metrics };
  }

  return function query(keys: unknown, hours: unknown): Promise<TimeseriesResult> {
    const defs = resolveMetrics(keys);
    const h = resolveHours(hours);
    const ck = `${h}|${defs.map((d) => d.key).join(',')}`;
    const hit = cache.get(ck);
    if (hit && Date.now() - hit.at < CACHE_TTL_MS) return hit.body;
    const entry = { at: Date.now(), body: collect(defs, h) };
    // A failed collection must not be served for a whole TTL — drop it so the next poll retries.
    entry.body.catch(() => { if (cache.get(ck) === entry) cache.delete(ck); });
    cache.set(ck, entry);
    return entry.body;
  };
}

export type TimeseriesQuery = ReturnType<typeof makeTimeseries>;
