// charts.js — the chart geometry for the Maintenance tab. Pure: takes points, returns SVG
// markup as a string. No DOM, no fetch, no apiPost — which is what makes it testable in node
// and keeps it off the box-writing module list mechanism-counts.test.ps1 pins.
//
// THE ONE RULE: a gap is DRAWN, never interpolated. Prometheus omits the points it never
// collected, so a run of missing timestamps IS an outage. Joining the two sides would draw a
// line across a period nobody measured, reading as a healthy server straight through an outage.
//
// Colours are emitted as `var(--x)` inside a style attribute, NOT as a presentation attribute:
// `fill="var(--x)"` does not resolve, `style="fill:var(--x)"` does. That also means a theme
// switch needs no redraw — the CSS variable re-resolves itself in both :root and
// :root[data-theme="dark"].

/** Matches the API's query step (timeseries.ts STEP_SECONDS). */
export const STEP = 300;

/** A break is a MISSED sample, not mere jitter: Prometheus timestamps drift a second or two. */
const BREAK = 1.8;

/** Wide enough to fit "not collected · N.Nh" without overlapping the band edges. */
const LABEL_MIN_PX = 90;

const GB = 1073741824;

/** The browser owns the palette; the server owns the allowlist. The fallback is what makes
 *  that split safe — a key added server-side gets a real colour, never `var(undefined)`. */
const COLOURS = {
  server_fps: '--accent',
  players_online: '--info',
  host_load: '--info',
  dayz_memory: '--accent',
  host_mem_avail: '--ok',
  dayz_threads: '--muted',
  persistence_size: '--drift',
  log_dir_size: '--drift',
  unique_players_24h: '--ok',
  server_up: '--ok',
};
export function colourFor(key) {
  return `var(${COLOURS[key] || '--info'})`;
}

export function fmt(v, unit) {
  if (unit === 'bytes') return (v / GB).toFixed(2) + ' GB';
  if (unit === 'fps') return Math.round(v) + ' fps';
  return (Math.abs(v) >= 100 ? Math.round(v) : Number(v.toFixed(2))).toString();
}

/** Split a series wherever a sample is missing. Each returned run is drawn as its own line. */
export function segments(points, step = STEP) {
  const out = [];
  let cur = [];
  for (let i = 0; i < points.length; i++) {
    if (i && points[i][0] - points[i - 1][0] > step * BREAK) {
      if (cur.length) out.push(cur);
      cur = [];
    }
    cur.push(points[i]);
  }
  if (cur.length) out.push(cur);
  return out;
}

/**
 * The spans with no data, as [from, to] pairs — including a series that starts late or stops
 * early inside the window. An EMPTY series returns none: "nothing at all" is a no-data note,
 * not a band that implies we know an outage happened.
 */
export function gaps(points, from, to, step = STEP) {
  const g = [];
  for (let i = 1; i < points.length; i++) {
    if (points[i][0] - points[i - 1][0] > step * BREAK) g.push([points[i - 1][0], points[i][0]]);
  }
  if (points.length && points[0][0] - from > step * BREAK) g.unshift([from, points[0][0]]);
  if (points.length && to - points[points.length - 1][0] > step * BREAK) g.push([points[points.length - 1][0], to]);
  return g;
}

const n1 = (v) => v.toFixed(1);
const pathOf = (seg, x, y) => seg.map((p, i) => `${i ? 'L' : 'M'}${n1(x(p[0]))},${n1(y(p[1]))}`).join('');

/** Shared scale maths. A flat series would divide by zero, so a zero range is widened by one. */
function scales(points, from, to, plotW, plotH, left, top, bottom) {
  const vals = points.map((p) => p[1]);
  let hi = Math.max(...vals);
  let lo = Math.min(...vals);
  if (hi === lo) { hi += 1; lo = Math.max(0, lo - 1); }
  const span = to - from || 1;
  return {
    hi,
    lo,
    x: (t) => left + ((t - from) / span) * plotW,
    y: (v) => bottom - ((v - lo) / (hi - lo || 1)) * plotH,
    top,
  };
}

/**
 * The small inline chart under a stat. 300x30 viewBox, stretched by CSS.
 * Returns '' for an empty series — the caller shows nothing rather than an empty frame.
 */
export function sparkline(points, { from, to, colour }) {
  if (!points.length) return '';
  const W = 300, H = 30, pad = 2;
  const s = scales(points, from, to, W, H - pad * 2, 0, 0, H - pad);
  let out = '';
  for (const [a, b] of gaps(points, from, to)) {
    const w = Math.max(1, s.x(b) - s.x(a));
    out += `<rect class="gap" x="${n1(s.x(a))}" y="0" width="${n1(w)}" height="${H}" style="opacity:.10"/>`;
  }
  for (const seg of segments(points)) {
    if (seg.length < 2) continue;
    const d = pathOf(seg, s.x, s.y);
    out += `<path d="${d}L${n1(s.x(seg[seg.length - 1][0]))},${H}L${n1(s.x(seg[0][0]))},${H}Z" style="fill:${colour};opacity:.13"/>`;
    out += `<path d="${d}" style="fill:none;stroke:${colour};stroke-width:1.5;stroke-linejoin:round" vector-effect="non-scaling-stroke"/>`;
  }
  const last = points[points.length - 1];
  out += `<circle cx="${n1(s.x(last[0]))}" cy="${n1(s.y(last[1]))}" r="2.4" style="fill:${colour}"/>`;
  return out;
}

/** The full chart row: gridlines, value + time axes, gap bands, then the line(s). */
export function chartSvg(points, { from, to, unit, colour }) {
  const W = 900, H = 132, L = 52, R = 8, TP = 9, B = 18;
  if (!points.length) return '<text class="axis" x="10" y="20">no data in this window</text>';
  const s = scales(points, from, to, W - L - R, H - TP - B, L, TP, H - B);
  let out = '';

  for (let i = 0; i <= 3; i++) {
    const v = s.lo + (s.hi - s.lo) * (i / 3);
    const yy = s.y(v);
    out += `<line class="grid" x1="${L}" y1="${n1(yy)}" x2="${W - R}" y2="${n1(yy)}"/>`;
    out += `<text class="axis" x="${L - 6}" y="${n1(yy + 3)}" text-anchor="end">${fmt(v, unit)}</text>`;
  }
  for (let i = 0; i <= 6; i++) {
    const t = from + ((to - from) * i) / 6;
    const label = new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    out += `<text class="axis" x="${n1(s.x(t))}" y="${H - 5}" text-anchor="middle">${label}</text>`;
  }
  for (const [a, b] of gaps(points, from, to)) {
    const w = Math.max(1, s.x(b) - s.x(a));
    out += `<rect class="gap" x="${n1(s.x(a))}" y="${TP}" width="${n1(w)}" height="${H - TP - B}" style="opacity:.09"/>`;
    if (w > LABEL_MIN_PX) {
      out += `<text class="gaplbl" x="${n1(s.x(a) + w / 2)}" y="${TP + 13}" text-anchor="middle">not collected · ${((b - a) / 3600).toFixed(1)}h</text>`;
    }
  }
  for (const seg of segments(points)) {
    if (seg.length < 2) continue;
    const d = pathOf(seg, s.x, s.y);
    out += `<path d="${d}L${n1(s.x(seg[seg.length - 1][0]))},${H - B}L${n1(s.x(seg[0][0]))},${H - B}Z" style="fill:${colour};opacity:.12"/>`;
    out += `<path d="${d}" style="fill:none;stroke:${colour};stroke-width:1.6;stroke-linejoin:round" vector-effect="non-scaling-stroke"/>`;
  }
  return out;
}
