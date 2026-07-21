// maintenance.js — the server status/control cluster: footer stats bar, the update pill/panel,
// the Maintenance tab, and the operator-scope UI. Extracted from index.html (P1 modular split).
import { el } from './dom.js';
import { escapeHtml, attr, setGlobalMsg } from './ui.js';
import { apiPost, rateLimited } from './api-client.js';
import { loadCred, handle } from './auth.js';
import { setScope, getScope, isOperator } from './state.js';

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
const MAINT_POLL_MS = 20000;

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

function renderMaintStatus(s) {
  if (!s) { el.mntStatusBody.innerHTML = '<span class="meta">unavailable</span>'; el.mntDot.className = 'mnt-dot'; el.mntNavSummary.textContent = 'unavailable'; return; }
  const up = s.status === 'active';
  el.mntDot.className = 'mnt-dot ' + (up ? 'up' : 'down');
  const rows = [mntKV('State', up ? 'Online' : (s.status || 'offline'), up ? 'good' : 'bad'),
    mntKV('Players', s.players == null ? '—' : String(s.players)), mntKV('Mission', s.map || '—')];
  if (up && s.uptimeHuman) rows.push(mntKV('Uptime', s.uptimeHuman));
  if (up && s.restart && s.restart.inHuman) rows.push(mntKV('Next restart', '~' + s.restart.inHuman));
  if (typeof s.modCount === 'number') rows.push(mntKV('Mods', String(s.modCount)));
  el.mntStatusBody.innerHTML = rows.join('');
  el.mntNavSummary.textContent = up ? `Online · ${s.players ?? '—'} players · ${s.map || '—'}` : 'Offline';
}
function renderMaintHost(h) {
  if (!h) { el.mntHostBody.innerHTML = '<span class="meta">unavailable</span>'; return; }
  const parts = [];
  if (h.cpu) parts.push(mntMetric('CPU', h.cpu.busyPct, '%', `load ${h.cpu.load1} · ${h.cpu.cores} cores`));
  if (h.memoryMb) parts.push(mntMetric('Memory', h.memoryMb.usedPct, '%', `${gbFromMb(h.memoryMb.total - h.memoryMb.available)} / ${gbFromMb(h.memoryMb.total)} GB`));
  if (h.diskRootGb) parts.push(mntMetric('Disk /', h.diskRootGb.usedPct, '%', `${h.diskRootGb.free} GB free of ${h.diskRootGb.total}`));
  if (h.swapMb && h.swapMb.total) parts.push(mntKV('Swap', `${h.swapMb.used} / ${h.swapMb.total} MB`));
  if (typeof h.uptimeSec === 'number') parts.push(mntKV('Host uptime', humanDur(h.uptimeSec)));
  if (h.dayz) {
    parts.push('<div class="mnt-lbl">DayZ process</div>');
    parts.push(mntKV('Memory', h.dayz.memoryMb + ' MB'));
    parts.push(mntKV('Log dir', h.dayz.logDirMb + ' MB'));
    parts.push(mntKV('Persistence', h.dayz.persistenceMb + ' MB'));
    parts.push(mntKV('Unit restarts', String(h.dayz.unitRestarts)));
  } else if (h.dayzError) {
    parts.push('<div class="mnt-lbl">DayZ process</div>', `<span class="meta">${escapeHtml(h.dayzError)}</span>`);
  }
  el.mntHostBody.innerHTML = parts.join('');
}
function renderMaintPlayers(p) {
  if (!p) { el.mntPlayersBody.innerHTML = '<span class="meta">unavailable</span>'; return; }
  if (p.count == null) { el.mntPlayersBody.innerHTML = '<span class="meta">count unavailable (RCon down)</span>'; return; }
  if (!p.count) { el.mntPlayersBody.innerHTML = '<span class="meta">No players online.</span>'; return; }
  const rows = (p.players || []).map((pl) =>
    `<li><span class="pn">${escapeHtml(pl.name || '—')}</span><span class="pp">${escapeHtml(pl.ping != null ? pl.ping + 'ms' : '')}</span></li>`).join('');
  el.mntPlayersBody.innerHTML = `<div class="meta" style="margin-bottom:6px">${p.count} online</div><ul class="mnt-players">${rows}</ul>`;
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
async function loadMaint() {
  if (rateLimited()) return;      // API said back off — skip this tick, timer stays armed
  const cred = loadCred(); if (!cred) return;
  const [st, host, players, upd] = await Promise.allSettled([
    apiPost('/dayz/status', cred), apiPost('/sysload', cred),
    apiPost('/dayz/players', cred), apiPost('/dayz/update/status', cred),
  ]);
  if (st.status === 'rejected' && st.reason && st.reason.status === 401) { handle(st.reason); return; }
  if (st.status === 'fulfilled') renderStats(st.value);   // feed the footer bar too — loadStats stands down while this tab polls
  renderMaintStatus(st.status === 'fulfilled' ? st.value : null);
  renderMaintHost(host.status === 'fulfilled' ? host.value : null);
  renderMaintPlayers(players.status === 'fulfilled' ? players.value : null);
  if (upd.status === 'fulfilled') { renderUpdate(upd.value); renderMaintUpdate(); }
  if (!maintMissionsLoaded) loadMissions(cred);
}
export function startMaint() { stopMaint(); loadMaint(); maintTimer = setInterval(loadMaint, MAINT_POLL_MS); }
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
  el.mntRefresh.addEventListener('click', loadMaint);
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
