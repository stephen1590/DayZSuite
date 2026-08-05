// maintenance.js — the server status/control cluster: footer stats bar, the update pill/panel,
// the Maintenance tab, and the operator-scope UI.
import { el } from './dom.js';
import { escapeHtml, attr, setGlobalMsg } from './ui.js';
import { apiPost, rateLimited } from './api-client.js';
import { loadCred, handle } from './auth.js';
import { setScope, getScope, isOperator } from './state.js';
import { sparkline, chartSvg, colourFor, fmt } from './charts.js';
import { FAST_MS, pollsForTick } from './poll-plan.js';

// ===================== server stats bar =====================
// Live DayZ status from POST /dayz/status (readOnly) — polled while signed in.
let statsTimer = null;
const STATS_POLL_MS = 45000;   // footer /dayz/status — relaxed; visibility-pause + refresh-on-return cover freshness

function sbStat(k, v) {
  return `<span class="sb-stat"><span class="sb-k">${escapeHtml(k)}</span><span class="sb-v">${escapeHtml(v)}</span></span>`;
}
function renderStats(s) {
  const up = s.status === 'active';
  el.statsbar.className = up ? 'sb-up' : 'sb-down';   // class on the bar; the dot lives inside #sbStats
  const parts = [`<span class="sb-state"><span class="sb-dot"></span>${up ? 'Online' : 'Offline'}</span>`];
  parts.push(sbStat('players', s.players == null ? '—' : String(s.players)));
  if (s.map) parts.push(sbStat('mission', s.map));
  if (up && s.uptimeHuman) parts.push(sbStat('uptime', s.uptimeHuman));
  if (up && s.restart && s.restart.inHuman) parts.push(sbStat('next restart', '~' + s.restart.inHuman));
  if (typeof s.modCount === 'number') parts.push(sbStat('mods', String(s.modCount)));
  parts.push('<span class="sb-foot">live</span>');   // cadence varies: maint tab feeds this bar at its own pace
  el.sbStats.innerHTML = parts.join('');   // only the polled half — the restart control (#sbActions) is left alone
}
async function loadStats() {
  if (rateLimited()) return;      // API said back off — skip this tick, timer stays armed
  if (maintTimer) return;         // Maintenance tab already polls /dayz/status + update and feeds this bar
  const cred = loadCred();
  if (!cred) return;
  try {
    renderStats(await apiPost('/dayz/status', cred));
  } catch (err) {
    if (handle(err)) return;   // 401 -> clears cred + showLogin (which stops polling)
    el.statsbar.className = 'sb-down';
    el.sbStats.innerHTML = '<span class="sb-state"><span class="sb-dot"></span>Server</span><span class="sb-err">stats unavailable</span>';
  }
  loadUpdate(cred);   // best-effort, independent of the stats call — never blocks the bar
}
export function startStats() { stopStats(); loadStats(); statsTimer = setInterval(loadStats, STATS_POLL_MS); }
export function stopStats() { if (statsTimer) { clearInterval(statsTimer); statsTimer = null; } }

// Restart control — gated behind the "Arm restart" checkbox so it can't fire on a stray
// click. POST /dayz/restart is destructive; the API still enforces its own player guard
// (refuses while players are online unless forced), and we surface that message as-is.
function armRestart() { el.sbRestart.disabled = !el.sbArm.checked; }
async function restartServer() {
  const cred = loadCred();
  if (!cred) return;
  el.sbRestart.disabled = true;
  setGlobalMsg('Restart issued — warning players and cycling the server…', false);
  try {
    await apiPost('/dayz/restart', cred, {});
    setGlobalMsg('Server restarting.', false, true);
    el.sbArm.checked = false;   // disarm after a successful trigger
    loadStats();
  } catch (err) {
    if (handle(err)) return;
    setGlobalMsg('Restart refused: ' + err.message, true);   // e.g. players online, or key lacks write scope
  } finally {
    armRestart();   // re-enable only if still armed
  }
}

// ===================== Update control =====================
// Non-destructive: `update` ARMS a deferred update that the NEXT server start applies (see
// the DayZ prestart hook), so there's no arm-gate like restart. update-check.sh may arm it
// automatically when a newer build appears; we surface that, plus the last applied update's
// outcome, as a pill + a detail popover. Polled alongside the stats bar.
let updateStatus = null;

function freshLastRun(u) {
  if (!u.lastRun || !u.lastRun.ok || !u.lastRun.finishedAt) return false;
  const t = Date.parse(u.lastRun.finishedAt);
  return !isNaN(t) && (Date.now() - t) < 24 * 3600 * 1000;   // show a recent success for a day
}
export function renderUpdate(u) {
  updateStatus = u || null;
  const box = el.sbUpdate, pill = el.sbUpdPill;
  if (!u) { box.classList.add('hidden'); closeUpdatePanel(); return; }
  let cls = '', text = '', show = true, queue = false, cancel = false;
  if (u.pending) { cls = 'is-pending'; text = '⟳ Update queued'; cancel = true; }
  else if (u.updateAvailable) { cls = 'is-avail'; text = '● Update available'; queue = true; }
  else if (u.lastRun && u.lastRun.ok === false) { cls = 'is-fail'; text = '⚠ Update failed'; }
  else if (freshLastRun(u)) { cls = 'is-ok'; text = '✓ Updated'; }
  else { show = false; }
  box.classList.toggle('hidden', !show);
  el.sbUpdQueue.classList.toggle('hidden', !queue);
  el.sbUpdCancel.classList.toggle('hidden', !cancel);
  if (!show) { closeUpdatePanel(); return; }
  pill.className = 'sb-pill ' + cls;
  pill.textContent = text;
  pill.title = updateTitle(u);
  if (!el.updPanel.classList.contains('hidden')) renderUpdatePanel();   // keep an open panel fresh
}
function updateTitle(u) {
  const p = ['installed: ' + (u.installedBuild || '?')];
  if (u.latestBuild) p.push('latest: ' + u.latestBuild);
  if (u.pending && u.pendingReason) p.push('queued: ' + u.pendingReason);
  return p.join('  ·  ') + '  (click for details)';
}
async function loadUpdate(cred) {
  try { renderUpdate(await apiPost('/dayz/update/status', cred)); }
  catch (err) { if (err.status === 401) handle(err); /* otherwise leave the pill as-is */ }
}
async function queueUpdate() {
  const cred = loadCred(); if (!cred) return;
  el.sbUpdQueue.disabled = true;
  try {
    const r = await apiPost('/dayz/update', cred, { reason: 'queued from ConfigViewer' });
    setGlobalMsg('Update queued — it applies at the next restart.', false, true);
    renderUpdate(r.status);
  } catch (err) {
    if (handle(err)) return;
    setGlobalMsg('Could not queue update: ' + err.message, true);   // e.g. key lacks write scope
  } finally { el.sbUpdQueue.disabled = false; }
}
async function cancelUpdate() {
  const cred = loadCred(); if (!cred) return;
  el.sbUpdCancel.disabled = true;
  try {
    const r = await apiPost('/dayz/update/cancel', cred);
    setGlobalMsg('Queued update cancelled.', false, true);
    renderUpdate(r.status);
  } catch (err) {
    if (handle(err)) return;
    setGlobalMsg('Could not cancel update: ' + err.message, true);
  } finally { el.sbUpdCancel.disabled = false; }
}

// Detail popover — build ids, when last checked, what's queued, and the last applied
// update's outcome + log tail. This is the "response on the page" for an auto/manual update.
function updRow(k, v, cls) {
  return `<div class="upd-row"><span class="k">${escapeHtml(k)}</span><span class="v${cls ? ' ' + cls : ''}">${escapeHtml(v)}</span></div>`;
}
function fmtWhen(iso) { const d = new Date(iso); return isNaN(d.getTime()) ? iso : d.toLocaleString(); }
function renderUpdatePanel() {
  const u = updateStatus;
  if (!u) { closeUpdatePanel(); return; }
  const rows = [
    updRow('Installed build', u.installedBuild || 'unknown'),
    updRow('Latest build', u.latestBuild || (u.checkOk ? 'unknown' : 'not checked yet')),
    updRow('State', u.pending ? 'update queued' : u.updateAvailable ? 'update available' : 'up to date',
      u.pending || u.updateAvailable ? 'warn' : 'good'),
  ];
  if (u.pending && u.pendingReason) rows.push(updRow('Queued', u.pendingReason));
  if (u.checkedAt) rows.push(updRow('Last checked', fmtWhen(u.checkedAt)));
  let last = '';
  const lr = u.lastRun;
  if (lr) {
    const okCls = lr.ok ? 'good' : 'bad';
    const outcome = lr.ok ? 'succeeded' : 'failed (exit ' + (lr.exitCode == null ? '?' : lr.exitCode) + ')';
    last = '<div class="upd-lbl">Last applied update</div>' +
      updRow('Result', outcome, okCls) +
      updRow('Build', (lr.fromBuild || '?') + ' → ' + (lr.toBuild || '?')) +
      updRow('Finished', lr.finishedAt ? fmtWhen(lr.finishedAt) : '—');
    if (lr.log) last += '<div class="upd-lbl">Update log (tail)</div><pre class="upd-log">' + escapeHtml(lr.log) + '</pre>';
  }
  el.updPanel.innerHTML =
    '<h4>Server update<button type="button" class="upd-close" id="updClose" aria-label="Close">×</button></h4>' +
    rows.join('') + last;
  el.updPanel.querySelector('#updClose').addEventListener('click', closeUpdatePanel);
}
function openUpdatePanel() { renderUpdatePanel(); el.updPanel.classList.remove('hidden'); }
function closeUpdatePanel() { if (el.updPanel) el.updPanel.classList.add('hidden'); }
function toggleUpdatePanel() { if (el.updPanel.classList.contains('hidden')) openUpdatePanel(); else closeUpdatePanel(); }

// ===================== Maintenance page =====================
// Access level comes from the key's OWN grant (POST /whoami): 'full' = Operator (may act),
// 'observe' = Viewer (read-only). The API enforces the same server-side; this just makes the
// UI honest — viewers get disabled controls instead of clicking into a 403.
// apiScope + isOperator -> js/state.js (shared session scope; gates writes across tabs).
let maintTimer = null;
let maintMissionsLoaded = false;

// Two-speed polling — the cadence itself lives in poll-plan.js, which is where the request
// count is asserted by the test suite. Last-known values are kept per source so a fast tick
// can re-render the whole page without refetching the slow half; without this, the Disk and
// Swap rows would blink out on every tick that did not include /sysload.
let tick = 0;
let lastStatus = null;    // /dayz/status  - state, roster AND the unit footprint
let lastHost = null;      // /sysload      - disk, swap, cores, host uptime
let series = null;        // /dayz/timeseries - history + the current value of each metric
let chartHours = 24;
let chartKeys = null;     // Set of metric keys; seeded from the server's own catalogue
let catalogued = false;

export async function loadWhoami() {
  const cred = loadCred(); if (!cred) return;
  try { const r = await apiPost('/whoami', cred); setScope(r.scope); }
  catch (err) { if (err.status === 401) { handle(err); return; } setScope(null); }
  applyScopeUi();
}
function applyScopeUi() {
  const op = isOperator();
  const label = getScope() === 'full' ? 'Operator' : getScope() === 'observe' ? 'Viewer (read-only)' : 'Unknown';
  el.mntRole.textContent = label;
  el.mntRole.className = 'mnt-role ' + (getScope() === 'full' ? 'is-op' : getScope() === 'observe' ? 'is-view' : '');
  const navSpan = el.mntNavRole.querySelector('span'); if (navSpan) navSpan.textContent = label;
  el.mntViewerNote.classList.toggle('hidden', op || getScope() === null);
  // Non-destructive writes: enabled directly for operators.
  el.mntSend.disabled = !op;
  el.mntStart.disabled = !op;            // start isn't destructive (server is down)
  el.mntArm.disabled = !op;
  el.mntForce.disabled = !op;
  el.mntMapSel.disabled = !op;
  if (!op) el.mntArm.checked = false;
  applyArm();                            // restart/stop/mapchange also require "arm"
  renderMaintUpdate();                   // refresh queue/cancel enabled state
}
function applyArm() {
  const armed = isOperator() && el.mntArm.checked;
  el.mntRestart.disabled = !armed;
  el.mntStop.disabled = !armed;
  el.mntMapGo.disabled = !armed || !el.mntMapSel.value;
}

function mntKV(k, v, cls) {
  return `<div class="mnt-kv"><span class="k">${escapeHtml(k)}</span><span class="v${cls ? ' ' + cls : ''}">${escapeHtml(v)}</span></div>`;
}
function humanDur(sec) {
  sec = Math.max(0, Math.floor(sec || 0));
  const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
  if (d) return `${d}d ${h}h`; if (h) return `${h}h ${m}m`; return `${m}m`;
}
const gbFromMb = (mb) => (mb / 1024).toFixed(1);
function mntMetric(k, pct, unit, sub) {
  const p = (typeof pct === 'number') ? pct : null;
  const cls = p == null ? '' : p >= 90 ? 'bad' : p >= 75 ? 'warn' : 'good';
  const col = p == null ? 'var(--muted)' : p >= 90 ? 'var(--danger)' : p >= 75 ? 'var(--accent)' : 'var(--ok)';
  const w = p == null ? 0 : Math.max(0, Math.min(100, p));
  return `<div class="mnt-metric"><div class="top"><span class="k">${escapeHtml(k)}</span><span class="v ${cls}">${p == null ? '—' : p + unit}</span></div>`
    + `<div class="mnt-bar"><i style="width:${w}%;background:${col}"></i></div>`
    + (sub ? `<div class="meta" style="font-size:11px">${escapeHtml(sub)}</div>` : '') + '</div>';
}

/** One metric's history as an inline sparkline, or '' when there is nothing to draw.
 *  Points come from the SAME response that supplies the number above them. */
function sparkFor(key, label) {
  const m = series && Array.isArray(series.metrics) ? series.metrics.find((x) => x.key === key) : null;
  if (!m || !m.points.length) return '';
  return `<div class="mnt-lbl">${escapeHtml(label)}</div>`
    + `<svg class="spark" viewBox="0 0 300 30" preserveAspectRatio="none" role="img" aria-label="${attr(label)}">`
    + sparkline(m.points, { from: series.from, to: series.to, colour: colourFor(key) })
    + '</svg>';
}

function renderMaintStatus(s) {
  if (!s) { el.mntStatusBody.innerHTML = '<span class="meta">unavailable</span>'; el.mntDot.className = 'mnt-dot'; el.mntNavSummary.textContent = 'unavailable'; return; }
  const up = s.status === 'active';
  el.mntDot.className = 'mnt-dot ' + (up ? 'up' : 'down');
  const rows = [mntKV('State', up ? 'Online' : (s.status || 'offline'), up ? 'good' : 'bad'),
    mntKV('Players', s.players == null ? '—' : String(s.players)), mntKV('Mission', s.map || '—')];
  if (up && s.uptimeHuman) rows.push(mntKV('Uptime', s.uptimeHuman));
  if (up && s.restart && s.restart.inHuman) rows.push(mntKV('Next restart', '~' + s.restart.inHuman));
  if (typeof s.modCount === 'number') rows.push(mntKV('Mods', String(s.modCount)));
  rows.push(sparkFor('players_online', `Players online · ${chartHours}h`));
  el.mntStatusBody.innerHTML = rows.join('');
  el.mntNavSummary.textContent = up ? `Online · ${s.players ?? '—'} players · ${s.map || '—'}` : 'Offline';
}
// Two sources, deliberately: `h` is /sysload (the unprivileged host half - disk, swap, cores,
// uptime) and `unit` is the dayz footprint off /dayz/status, which already takes that snapshot -
// avoiding a second privileged call for the same numbers.
function renderMaintHost(h, unit) {
  if (!h && !unit) { el.mntHostBody.innerHTML = '<span class="meta">unavailable</span>'; return; }
  const parts = [];
  if (h && h.cpu) {
    parts.push(mntMetric('CPU', h.cpu.busyPct, '%', `load ${h.cpu.load1} · ${h.cpu.cores} cores`));
    parts.push(sparkFor('host_load', `Load · ${chartHours}h`));
  }
  if (h && h.memoryMb) {
    parts.push(mntMetric('Memory', h.memoryMb.usedPct, '%', `${gbFromMb(h.memoryMb.total - h.memoryMb.available)} / ${gbFromMb(h.memoryMb.total)} GB`));
    parts.push(sparkFor('host_mem_avail', `Memory free · ${chartHours}h`));
  }
  if (h && h.diskRootGb) parts.push(mntMetric('Disk /', h.diskRootGb.usedPct, '%', `${h.diskRootGb.free} GB free of ${h.diskRootGb.total}`));
  if (h && h.swapMb && h.swapMb.total) parts.push(mntKV('Swap', `${h.swapMb.used} / ${h.swapMb.total} MB`));
  if (h && typeof h.uptimeSec === 'number') parts.push(mntKV('Host uptime', humanDur(h.uptimeSec)));
  if (unit) {
    parts.push('<div class="mnt-lbl">DayZ process</div>');
    parts.push(mntKV('Memory', unit.memoryMb + ' MB'));
    parts.push(mntKV('Threads', String(unit.tasks)));
    parts.push(mntKV('Log dir', unit.logDirMb + ' MB'));
    parts.push(mntKV('Persistence', unit.persistenceMb + ' MB'));
    parts.push(mntKV('Unit restarts', String(unit.unitRestarts)));
  }
  el.mntHostBody.innerHTML = parts.join('');
}
// Fed from /dayz/status, not a poll of its own: `status` already makes the RCon query, so a
// separate roster poll would just repeat the same query.
function renderMaintPlayers(s) {
  if (!s) { el.mntPlayersBody.innerHTML = '<span class="meta">unavailable</span>'; return; }
  if (s.players == null) { el.mntPlayersBody.innerHTML = '<span class="meta">count unavailable (RCon down)</span>'; return; }
  if (!s.players) { el.mntPlayersBody.innerHTML = '<span class="meta">No players online.</span>'; return; }
  const rows = (s.roster || []).map((pl) =>
    `<li><span class="pn">${escapeHtml(pl.name || '—')}</span><span class="pp">${escapeHtml(pl.ping != null ? pl.ping + 'ms' : '')}</span></li>`).join('');
  el.mntPlayersBody.innerHTML = `<div class="meta" style="margin-bottom:6px">${s.players} online</div><ul class="mnt-players">${rows}</ul>`;
}

// ===================== Charts =====================
// The picker is built from the catalogue the API returns, so the browser holds no second copy
// of the allowlist. It owns the palette only (colourFor), with a documented fallback.
function renderPicker(available) {
  el.mntPicker.innerHTML = available.map((m) => {
    const cls = m.pinned ? ' class="pinned"' : '';
    const dis = m.pinned ? ' disabled' : '';
    const checked = chartKeys.has(m.key) ? ' checked' : '';
    const tail = m.pinned ? '<span class="pin">always on</span>' : `<span class="sname">${escapeHtml(m.series)}</span>`;
    return `<label${cls}><input type="checkbox" data-key="${attr(m.key)}"${checked}${dis}>${escapeHtml(m.label)}${tail}</label>`;
  }).join('');
}

/** Seed the selection from the server's own defaults, once. Returns true the first time, so
 *  the caller can refetch immediately instead of leaving the default lines blank for a tick. */
function adoptCatalogue(s) {
  if (catalogued || !s || !Array.isArray(s.available) || !s.available.length) return false;
  catalogued = true;
  chartKeys = new Set(s.available.filter((m) => m.pinned || m.on).map((m) => m.key));
  renderPicker(s.available);
  return true;
}

function renderCharts() {
  if (!series || !Array.isArray(series.metrics)) {
    el.mntCharts.innerHTML = '<span class="meta">History unavailable — Prometheus did not answer.</span>';
    return;
  }
  const rows = series.metrics.map((m) => {
    const colour = colourFor(m.key);
    const now = m.latest ? fmt(m.latest.value, m.unit) : '—';
    return '<div class="chartrow"><div class="hd">'
      + `<strong>${escapeHtml(m.label)}</strong><span class="meta">${escapeHtml(m.series)}</span>`
      + `<span class="now" style="color:${colour}">${escapeHtml(now)}</span></div>`
      + '<svg class="chart" viewBox="0 0 900 132" preserveAspectRatio="none">'
      + chartSvg(m.points, { from: series.from, to: series.to, unit: m.unit, colour })
      + '</svg></div>';
  }).join('');
  el.mntCharts.innerHTML = rows || '<span class="meta">Nothing selected.</span>';
}

/** Refetch just the charts — for a range change, a checkbox, or the first catalogue load.
 *  Everything else on the page keeps its last-known values. */
async function refreshCharts() {
  const cred = loadCred(); if (!cred) return;
  try {
    series = await apiPost('/dayz/timeseries', cred, { metrics: chartKeys ? [...chartKeys] : [], hours: chartHours });
  } catch (err) {
    if (handle(err)) return;
    series = null;
  }
  if (adoptCatalogue(series)) { refreshCharts(); return; }
  renderCharts();
  renderMaintStatus(lastStatus);
  renderMaintHost(lastHost, lastStatus && lastStatus.unit);
}
function renderMaintUpdate() {
  const u = updateStatus, info = el.mntUpdateInfo;
  if (!info) return;
  if (!u) { info.innerHTML = '<span class="meta">unavailable</span>'; el.mntUpdLogWrap.style.display = 'none'; return; }
  const rows = [mntKV('Installed', u.installedBuild || 'unknown'),
    mntKV('Latest', u.latestBuild || (u.checkOk ? 'unknown' : 'not checked yet')),
    mntKV('State', u.pending ? 'update queued' : u.updateAvailable ? 'update available' : 'up to date', u.pending || u.updateAvailable ? 'warn' : 'good')];
  if (u.pending && u.pendingReason) rows.push(mntKV('Queued', u.pendingReason));
  if (u.checkedAt) rows.push(mntKV('Checked', fmtWhen(u.checkedAt)));
  if (u.lastRun) rows.push(mntKV('Last update', (u.lastRun.ok ? 'ok' : 'failed (exit ' + (u.lastRun.exitCode == null ? '?' : u.lastRun.exitCode) + ')') + ' · ' + (u.lastRun.finishedAt ? fmtWhen(u.lastRun.finishedAt) : '—'), u.lastRun.ok ? 'good' : 'bad'));
  info.innerHTML = rows.join('');
  const op = isOperator();
  el.mntUpdQueue.disabled = !op || u.pending;
  el.mntUpdCancel.disabled = !op || !u.pending;
  if (u.lastRun && u.lastRun.log) { el.mntUpdLog.textContent = u.lastRun.log; el.mntUpdLogWrap.style.display = ''; }
  else el.mntUpdLogWrap.style.display = 'none';
}

async function loadMissions(cred) {
  try {
    const r = await apiPost('/dayz/missions', cred);
    const opts = (r.missions || []).map((m) => `<option value="${attr(m)}">${escapeHtml(m)}</option>`).join('');
    el.mntMapSel.innerHTML = '<option value="">Select a mission…</option>' + opts;
    maintMissionsLoaded = true;
  } catch { /* leave the select; map change just stays unusable */ }
}
/** Only the charts carry a body; the rest are signed empty like they always were. */
function bodyFor(path) {
  if (path !== '/dayz/timeseries') return undefined;
  return { metrics: chartKeys ? [...chartKeys] : [], hours: chartHours };
}

async function loadMaint() {
  if (rateLimited()) return;      // API said back off — skip this tick, timer stays armed
  const cred = loadCred(); if (!cred) return;
  // Which reads this tick: the fast pair every time, the slow pair every third (poll-plan.js).
  const paths = pollsForTick(tick++);
  const settled = await Promise.allSettled(paths.map((p) => apiPost(p, cred, bodyFor(p))));
  const got = {};
  paths.forEach((p, i) => { got[p] = settled[i]; });

  const st = got['/dayz/status'];
  if (st && st.status === 'rejected' && st.reason && st.reason.status === 401) { handle(st.reason); return; }
  if (st) {
    lastStatus = st.status === 'fulfilled' ? st.value : null;
    if (lastStatus) renderStats(lastStatus);   // feed the footer bar too — loadStats stands down while this tab polls
  }
  const ts = got['/dayz/timeseries'];
  if (ts) series = ts.status === 'fulfilled' ? ts.value : null;
  const host = got['/sysload'];
  if (host) lastHost = host.status === 'fulfilled' ? host.value : null;
  const upd = got['/dayz/update/status'];
  if (upd && upd.status === 'fulfilled') { renderUpdate(upd.value); renderMaintUpdate(); }

  // Seeding the picker changes what we want charted, so refetch once rather than show the
  // default lines a tick late.
  if (adoptCatalogue(series)) { refreshCharts(); }

  renderMaintStatus(lastStatus);
  renderMaintHost(lastHost, lastStatus && lastStatus.unit);
  renderMaintPlayers(lastStatus);
  renderCharts();
  if (!maintMissionsLoaded) loadMissions(cred);
}
export function startMaint() { stopMaint(); tick = 0; loadMaint(); maintTimer = setInterval(loadMaint, FAST_MS); }
export function stopMaint() { if (maintTimer) { clearInterval(maintTimer); maintTimer = null; } }

// Shared action runner for the maintenance controls: post, toast, refresh, restore gating.
async function maintAct(path, body, okMsg, busyBtns) {
  const cred = loadCred(); if (!cred) return;
  busyBtns.forEach((b) => { b.disabled = true; });
  try {
    const r = await apiPost(path, cred, body || {});
    setGlobalMsg(okMsg, false, true);
    if (r && r.status) renderUpdate(r.status);
    loadMaint();
  } catch (err) {
    if (handle(err)) return;
    setGlobalMsg('Failed: ' + err.message, true);   // e.g. players online (409), or read-only key (403)
  } finally {
    applyScopeUi();   // restore enabled/disabled from scope + arm
  }
}
async function mntBroadcast() {
  const msg = el.mntMsg.value.trim();
  if (!msg) { setGlobalMsg('Enter a message first.', true); return; }
  const cred = loadCred(); if (!cred) return;
  el.mntSend.disabled = true;
  try { await apiPost('/dayz/broadcast', cred, { message: msg }); setGlobalMsg('Message sent to players.', false, true); el.mntMsg.value = ''; }
  catch (err) { if (handle(err)) return; setGlobalMsg('Broadcast failed: ' + err.message, true); }
  finally { el.mntSend.disabled = !isOperator(); }
}

export function initMaint() {
  el.sbArm.addEventListener('change', armRestart);
  el.sbRestart.addEventListener('click', restartServer);
  el.sbUpdPill.addEventListener('click', toggleUpdatePanel);
  el.sbUpdQueue.addEventListener('click', queueUpdate);
  el.sbUpdCancel.addEventListener('click', cancelUpdate);
  // Dismiss the update popover on outside-click or Esc (the pill toggles it itself).
  document.addEventListener('click', (e) => {
    if (el.updPanel.classList.contains('hidden')) return;
    if (el.updPanel.contains(e.target) || e.target === el.sbUpdPill) return;
    closeUpdatePanel();
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeUpdatePanel(); });
  // Maintenance page controls (all gated to Operator keys; the API is the real enforcer).
  el.mntRefresh.addEventListener('click', () => { tick = 0; loadMaint(); });   // a manual refresh pulls the slow half too
  // Charts: delegated, so re-rendering the picker never loses its handler.
  el.mntChartRange.addEventListener('click', (e) => {
    const b = e.target.closest('button[data-range]');
    if (!b) return;
    chartHours = Number(b.dataset.range);
    for (const o of el.mntChartRange.querySelectorAll('button')) o.setAttribute('aria-pressed', String(o === b));
    refreshCharts();
  });
  el.mntPicker.addEventListener('change', (e) => {
    const cb = e.target.closest('input[data-key]');
    if (!cb || !chartKeys) return;
    if (cb.checked) chartKeys.add(cb.dataset.key); else chartKeys.delete(cb.dataset.key);
    refreshCharts();
  });
  el.mntArm.addEventListener('change', applyArm);
  el.mntMapSel.addEventListener('change', applyArm);
  el.mntStart.addEventListener('click', () => maintAct('/dayz/start', {}, 'Start issued.', [el.mntStart, el.mntRestart, el.mntStop]));
  el.mntRestart.addEventListener('click', () => maintAct('/dayz/restart', el.mntForce.checked ? { force: true } : {}, 'Restart issued.', [el.mntStart, el.mntRestart, el.mntStop]));
  el.mntStop.addEventListener('click', () => maintAct('/dayz/stop', el.mntForce.checked ? { force: true } : {}, 'Stop issued.', [el.mntStart, el.mntRestart, el.mntStop]));
  el.mntMapGo.addEventListener('click', () => {
    const m = el.mntMapSel.value; if (!m) return;
    maintAct('/dayz/mapchange', el.mntForce.checked ? { mission: m, force: true } : { mission: m }, `Switching to ${m} and restarting…`, [el.mntMapGo]);
  });
  el.mntSend.addEventListener('click', mntBroadcast);
  el.mntUpdQueue.addEventListener('click', () => maintAct('/dayz/update', { reason: 'queued from Maintenance page' }, 'Update queued for next restart.', [el.mntUpdQueue, el.mntUpdCancel]));
  el.mntUpdCancel.addEventListener('click', () => maintAct('/dayz/update/cancel', {}, 'Queued update cancelled.', [el.mntUpdQueue, el.mntUpdCancel]));
}
