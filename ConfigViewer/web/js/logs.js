// logs.js — the Logs tab: browse the box RPT/ADM logs by day, page a bounded window,
// filter (grep -E), follow the tail. Extracted from index.html (P1 modular split).
import { el } from './dom.js';
import { toast, escapeHtml, attr } from './ui.js';
import { apiPost, rateLimited } from './api-client.js';
import { loadCred, handle } from './auth.js';

// ===================== Logs tab (server log browser) =====================
// Backed by /dayz/logs/files + /dayz/logs/read. The pane holds ONE contiguous
// window [logWin.lo .. logWin.hi] of the (filtered) line stream; scrolling to
// the top edge extends it a page at a time, so scrollback stays cheap no
// matter how big the file is. Line numbers are the file's ORIGINAL numbers
// even when a filter is active (the API keeps them), so context never lies.
const LOG_PAGE = 300;
const LOG_RECENT = 10;        // flat (non-dated) sources show the last N files
let logSources = [];          // logs/sources reply: [{ id, label }] — the source selector
let logCurSource = null;      // selected source id (rpt/adm/mod…); scopes logFiles + reads
let logFilesSource = null;    // the source logFiles currently holds (reload when it changes)
let logFiles = [];            // logs/files reply for the current source, newest first
let logCurFile = null;        // opened filename
let logWin = null;            // { lo, hi, total, matched } — loaded stream window
let logBusy = false;
let logFollowTimer = null;
let logCaseSensitive = false; // Aa toggle; we send ignoreCase unless it's on
let logRegex = false;         // .* toggle; off = the filter is plain text (metacharacters escaped)
let logSelDate = null;        // the date the left column is filtered to (YYYY-MM-DD, UTC)

// Routing stays in the shell (index.html): it injects syncHash/syncHashSoon via
// setLogsShellHooks(), reads logsHashFrag() for the URL, and hands #logs/... deep-link
// targets through setPendingLog(). A displayed log reflects into location.hash as
// #logs/<source>/<file> — shareable and restorable.
let logsShellHooks = { syncHash: () => {}, syncHashSoon: () => {} };
export function setLogsShellHooks(h) { logsShellHooks = { ...logsShellHooks, ...h }; }
let pendingLog = null;        // { source, file } stashed from a deep link; consumed on load
export function setPendingLog(v) { pendingLog = v || null; }
// The hash fragment for the CURRENT logs view, for the shell's currentHash().
export function logsHashFrag() {
  if (!logCurSource) return 'logs';
  let f = 'logs/' + encodeURIComponent(logCurSource);
  if (logCurFile) f += '/' + encodeURIComponent(logCurFile);
  return f;
}

// The backend filter is always a grep -E regex. In plain-text mode we escape the
// ERE metacharacters so a user's "." or "(" matches itself — no reserved-character
// surprises. The set is identical for JS RegExp, so the same escape feeds both the
// server filter and the client-side highlighter.
function ereEscape(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
function logPattern() { const f = el.logFilter.value.trim(); return logRegex ? f : ereEscape(f); }

function logHuman(bytes) {
  if (bytes >= 1048576) return (bytes / 1048576).toFixed(1) + 'M';
  if (bytes >= 1024) return Math.round(bytes / 1024) + 'K';
  return bytes + 'B';
}
// The box names its RPT/ADM logs DayZServer_..._YYYY-MM-DD_HH-MM-SS.RPT in server (UTC)
// time — read the day and start-time straight off the name, fall back to mtime. Mod logs
// rarely carry that stamp; those are shown as a flat recent list, not grouped by day.
const LOG_STAMP = /_(\d{4}-\d\d-\d\d)_(\d\d)-(\d\d)-(\d\d)\.[A-Za-z0-9]+$/;
function logDateOf(f) { const m = LOG_STAMP.exec(f.name); return m ? m[1] : (f.modified || '').slice(0, 10); }
function logTimeOf(f) { const m = LOG_STAMP.exec(f.name); return m ? m[2] + ':' + m[3] + ':' + m[4] : f.name; }
// A source is "dated" when its files carry the name stamp — then the date picker applies.
// Otherwise (mod logs) the picker is hidden and we just show the last LOG_RECENT files.
function logSourceDated() { return logFiles.some((f) => LOG_STAMP.test(f.name)); }
const logByNameDesc = (a, b) => (a.name < b.name ? 1 : a.name > b.name ? -1 : 0);   // newest session first
const logDayFiles = (d) => logFiles.filter((f) => logDateOf(f) === d).sort(logByNameDesc);
function logUtcToday() { const n = new Date(); return n.getUTCFullYear() + '-' + String(n.getUTCMonth() + 1).padStart(2, '0') + '-' + String(n.getUTCDate()).padStart(2, '0'); }

// Left column = source selector + (for dated sources) a date picker + a file dropdown.
// The date picker defaults to today (UTC, to match how the box names RPT/ADM); if today
// has none it falls back to the newest day that does, so the panel is never blank.
// Keep the source selector in sync with logSources / logCurSource.
function renderSourceSel() {
  if (!logSources.length) { el.logSource.innerHTML = '<option disabled selected>—</option>'; el.logSource.disabled = true; return; }
  el.logSource.disabled = false;
  el.logSource.innerHTML = logSources.map((s) =>
    '<option value="' + attr(s.id) + '"' + (s.id === logCurSource ? ' selected' : '') + '>' + escapeHtml(s.label) + '</option>').join('');
}

// One file <option>: "time · size" for dated sources (RPT/ADM), "name · size" for flat ones.
function logFileOpt(f, dated) {
  const label = (dated ? logTimeOf(f) : f.name) + ' · ' + logHuman(f.sizeBytes || 0);
  return '<option value="' + attr(f.name) + '"' + (f.name === logCurFile ? ' selected' : '') + '>' + escapeHtml(label) + '</option>';
}

function renderLogsNav() {
  renderSourceSel();
  if (!logFiles.length) {
    el.logDateRow.classList.add('hidden');
    el.logDate.value = ''; el.logDate.disabled = true;
    el.logFileSel.innerHTML = '<option disabled selected>—</option>'; el.logFileSel.disabled = true;
    el.logNavMeta.textContent = logCurSource ? 'No files for this source on the box.' : 'No log files on the box.';
    return;
  }
  // Flat (mod) source: no date picker — just the last LOG_RECENT files, newest first.
  if (!logSourceDated()) {
    el.logDateRow.classList.add('hidden');
    const recent = [...logFiles].sort(logByNameDesc).slice(0, LOG_RECENT);
    el.logFileSel.disabled = !recent.length;
    el.logFileSel.innerHTML = recent.map((f) => logFileOpt(f, false)).join('');
    el.logNavMeta.textContent = logFiles.length <= LOG_RECENT
      ? logFiles.length + ' file' + (logFiles.length === 1 ? '' : 's')
      : 'last ' + LOG_RECENT + ' of ' + logFiles.length + ' files';
    return;
  }
  // Dated (RPT/ADM) source: date picker scopes the file dropdown to one day.
  el.logDateRow.classList.remove('hidden');
  const dates = [...new Set(logFiles.map(logDateOf))].sort().reverse();
  const today = logUtcToday();
  if (!logSelDate || !dates.includes(logSelDate)) logSelDate = dates.includes(today) ? today : dates[0];
  el.logDate.disabled = false;
  el.logDate.max = dates[0] > today ? dates[0] : today;   // don't cap below the newest log we actually have
  el.logDate.value = logSelDate;

  const day = logDayFiles(logSelDate);
  el.logFileSel.disabled = !day.length;
  el.logFileSel.innerHTML = day.length
    ? day.map((f) => logFileOpt(f, true)).join('')
    : '<option disabled selected>no logs on this date</option>';

  el.logNavMeta.textContent = day.length
    ? day.length + ' file' + (day.length === 1 ? '' : 's') + ' on ' + logSelDate + ' · ' + dates.length + ' day' + (dates.length === 1 ? '' : 's') + ' logged'
    : 'no logs on ' + logSelDate + ' · ' + dates.length + ' day' + (dates.length === 1 ? '' : 's') + ' logged';
}

// Date changed: jump to that day's newest file (the dropdown is already newest-first).
// A day with no logs just refreshes the dropdown — the open file stays put.
function onLogDatePick() {
  const v = el.logDate.value;
  if (!v || v === logSelDate) return;
  logSelDate = v;
  const day = logDayFiles(v);   // already newest-first
  if (day.length) openLog(day[0].name); else renderLogsNav();
}

// Source switched: drop the old source's file/window state and reload from scratch.
function onLogSourcePick() {
  const v = el.logSource.value;
  if (!v || v === logCurSource) return;
  logCurSource = v;
  logCurFile = null; logWin = null; logSelDate = null;
  logFiles = []; logFilesSource = null;
  loadLogsTab(true);
}

export async function loadLogsTab(force) {
  const cred = loadCred();
  if (!cred) return;
  startLogFollow();
  // Source registry: fetch once. Default to 'rpt' if it exists, else the first source.
  if (!logSources.length) {
    try {
      const s = await apiPost('/dayz/logs/sources', cred, {});
      logSources = s.sources || [];
    } catch (e) { if (!handle(e)) toast('Log sources failed: ' + e.message, 'err'); return; }
    if (!logCurSource && logSources.length) logCurSource = (logSources.find((s) => s.id === 'rpt') || logSources[0]).id;
    renderSourceSel();
  }
  // A deep link (#logs/<source>/<file>) targets a specific source + file. Switch to a valid
  // source (a bad one falls through to the current/default) and remember the file to open;
  // force a reload so we land on it rather than the source's newest.
  let wantFile = null;
  if (pendingLog) {
    const p = pendingLog; pendingLog = null;
    if (p.source && logSources.some((s) => s.id === p.source) && p.source !== logCurSource) {
      logCurSource = p.source; logCurFile = null; logWin = null; logSelDate = null;
      logFiles = []; logFilesSource = null;
    }
    wantFile = p.file || null;
    force = true;
  }
  // Files already in hand for this source: just reflect state in the URL and stop (tab revisit).
  if (logFilesSource === logCurSource && logFiles.length && !force) { logsShellHooks.syncHash(); return; }
  try {
    const r = await apiPost('/dayz/logs/files', cred, { source: logCurSource });
    logFiles = r.files || [];
    logFilesSource = logCurSource;
  } catch (e) { if (!handle(e)) toast('Log list failed: ' + e.message, 'err'); return; }
  renderLogsNav();   // establishes logSelDate for dated sources
  // Open: an explicit deep-link file if it still exists; else keep the open file; else newest.
  if (wantFile && logFiles.some((f) => f.name === wantFile)) {
    openLog(wantFile);
  } else if (!logCurFile) {
    const first = logSourceDated()
      ? (logDayFiles(logSelDate)[0] || [...logFiles].sort(logByNameDesc)[0])
      : [...logFiles].sort(logByNameDesc)[0];
    if (first) openLog(first.name); else logsShellHooks.syncHash();
  } else {
    logsShellHooks.syncHash();
  }
}

function logParams(extra) {
  const p = { source: logCurSource, file: logCurFile, limit: LOG_PAGE, ...extra };
  const f = el.logFilter.value.trim();
  if (f) { p.filter = logPattern(); if (!logCaseSensitive) p.ignoreCase = true; }
  return p;
}
async function logFetch(extra) {
  const cred = loadCred();
  if (!cred) return null;
  return apiPost('/dayz/logs/read', cred, logParams(extra));
}

// One rendered line: severity tint + dimmed leading timestamp + <mark>ed filter
// hits. Highlighting finds match ranges on the RAW text, then escapes each
// segment separately, so entities can never split a match or leak markup.
function logLineHtml(n, text) {
  let cls = '';
  if (/\b(error|fault|fatal|crash)/i.test(text)) cls = ' lerr';
  else if (/\bwarn/i.test(text)) cls = ' lwarn';
  let body = null;
  const f = el.logFilter.value.trim();
  if (f) {
    let re = null;
    try { re = new RegExp(logPattern(), logCaseSensitive ? 'g' : 'gi'); } catch { /* keep plain */ }
    if (re) {
      let out = '', last = 0, ok = true;
      for (const m of text.matchAll(re)) {
        if (m[0] === '') { ok = false; break; }        // zero-width match — render plain
        out += escapeHtml(text.slice(last, m.index)) + '<mark>' + escapeHtml(m[0]) + '</mark>';
        last = m.index + m[0].length;
      }
      if (ok) body = out + escapeHtml(text.slice(last));
    }
  }
  if (body === null) body = escapeHtml(text);
  body = body.replace(/^((?:\s?\d{1,2}:\d\d:\d\d(?:\.\d+)?)(?:\s\|)?\s?)/, '<span class="ts">$1</span>');
  return '<div class="ll' + cls + '"><span class="ln">' + n + '</span><span class="lt">' + body + '</span></div>';
}
const logLinesHtml = (lines) => lines.map((l) => logLineHtml(l.n, l.text)).join('');

function logStatusText() {
  if (!logWin) { el.logStatus.textContent = '—'; return; }
  const f = el.logFilter.value.trim();
  el.logStatus.textContent =
    (f ? logWin.matched.toLocaleString() + ' of ' + logWin.total.toLocaleString() + ' lines match'
       : logWin.total.toLocaleString() + ' lines') +
    (logWin.hi >= logWin.lo ? ' · showing ' + logWin.lo.toLocaleString() + '–' + logWin.hi.toLocaleString() : '');
}

// Replace the whole window. offset 0/undefined = the tail; otherwise jump there
// (a line number, or the Nth match while a filter is active).
async function logJump(offset) {
  if (logBusy || !logCurFile) return;
  logBusy = true;
  try {
    const r = await logFetch({ offset: offset || 0 });
    if (!r) return;
    el.logFilter.classList.remove('badre');
    logWin = { lo: r.offset, hi: r.offset + r.count - 1, total: r.totalLines, matched: r.matchedLines };
    el.logLines.innerHTML = r.count ? logLinesHtml(r.lines)
      : '<div class="log-sentinel">no ' + (el.logFilter.value.trim() ? 'matching ' : '') + 'lines</div>';
    el.logEmpty.classList.add('hidden');
    el.logLines.classList.remove('hidden');
    logStatusText();
    logsShellHooks.syncHashSoon();   // log displayed — reflect source+file in the URL (shareable)
    // Tail pins to the bottom; a jump shows the target at the top.
    el.logPane.scrollTop = offset ? 0 : el.logPane.scrollHeight;
  } catch (e) {
    if (!handle(e)) toast('Log read failed: ' + e.message, 'err');
    el.logFilter.classList.toggle('badre', /invalid "filter"/.test(e.message || ''));
  } finally { logBusy = false; }
}

async function logExtend(dir) {  // dir -1 = older (prepend), +1 = newer (append)
  if (logBusy || !logWin || !logCurFile) return;
  const lo = dir < 0 ? Math.max(1, logWin.lo - LOG_PAGE) : logWin.hi + 1;
  const limit = dir < 0 ? logWin.lo - lo : LOG_PAGE;
  if (dir < 0 && limit <= 0) return;
  logBusy = true;
  try {
    const r = await logFetch({ offset: lo, limit });
    if (!r) return;
    logWin.total = r.totalLines; logWin.matched = r.matchedLines;
    if (!r.count) { logStatusText(); return; }
    if (dir < 0) {
      const before = el.logPane.scrollHeight;
      el.logLines.insertAdjacentHTML('afterbegin', logLinesHtml(r.lines));
      logWin.lo = r.offset;
      el.logPane.scrollTop += el.logPane.scrollHeight - before;   // keep the view anchored
    } else {
      const pinned = el.logPane.scrollTop + el.logPane.clientHeight >= el.logPane.scrollHeight - 40;
      el.logLines.insertAdjacentHTML('beforeend', logLinesHtml(r.lines));
      logWin.hi = r.offset + r.count - 1;
      if (pinned) el.logPane.scrollTop = el.logPane.scrollHeight;
    }
    logStatusText();
  } catch (e) { if (!handle(e)) toast('Log read failed: ' + e.message, 'err'); }
  finally { logBusy = false; }
}

function openLog(name) {
  logCurFile = name;
  const f = logFiles.find((x) => x.name === name);
  if (f) logSelDate = logDateOf(f);   // keep the date picker + dropdown on the open file's day
  logWin = null;
  renderLogsNav();
  logJump(0);
}

// Follow: while the Logs tab is visible and the box is ticked, poll past the
// end of the window every few seconds. The logs are append-only, so line
// numbers stay stable and this is just "fetch offset hi+1" — a silent no-op
// when nothing new arrived.
export function startLogFollow() {
  if (logFollowTimer) return;
  logFollowTimer = setInterval(() => {
    if (rateLimited()) return;    // API said back off — skip this tick, timer stays armed
    if (el.logstab.classList.contains('hidden') || !el.logFollow.checked || !logWin) return;
    logExtend(1);
  }, 5000);
}
export function stopLogFollow() {
  clearInterval(logFollowTimer);
  logFollowTimer = null;
}

export function initLogs() {
  el.logSource.addEventListener('change', onLogSourcePick);
  el.logDate.addEventListener('change', onLogDatePick);
  el.logFileSel.addEventListener('change', () => { if (el.logFileSel.value && el.logFileSel.value !== logCurFile) openLog(el.logFileSel.value); });
  el.logPane.addEventListener('scroll', () => {
    if (!logWin) return;
    if (el.logPane.scrollTop < 120) logExtend(-1);
    else if (el.logPane.scrollTop + el.logPane.clientHeight >= el.logPane.scrollHeight - 120 && logWin.hi < logWin.matched) logExtend(1);
  });
  el.logFilter.addEventListener('keydown', (e) => { if (e.key === 'Enter') logJump(0); });
  el.logCase.addEventListener('click', () => {
    logCaseSensitive = !logCaseSensitive;
    el.logCase.classList.toggle('on', logCaseSensitive);
    if (el.logFilter.value.trim()) logJump(0);
  });
  el.logRe.addEventListener('click', () => {
    logRegex = !logRegex;
    el.logRe.classList.toggle('on', logRegex);
    el.logFilter.placeholder = logRegex ? 'filter — grep -E regex, Enter applies' : 'filter — plain text, Enter applies';
    el.logFilter.classList.remove('badre');   // plain-text mode can't be an invalid pattern
    if (el.logFilter.value.trim()) logJump(0);
  });
  el.logGoto.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    const n = parseInt(el.logGoto.value, 10);
    if (n >= 1) logJump(n);
  });
  el.logRefresh.addEventListener('click', () => { loadLogsTab(true); if (logCurFile) logJump(0); });
  el.logLines.addEventListener('click', (e) => {
    const ln = e.target.closest('.ln');
    if (!ln) return;
    const text = ln.textContent + ': ' + ln.parentElement.querySelector('.lt').textContent;
    navigator.clipboard.writeText(text).then(() => toast('Line copied', 'ok'), () => toast(text));
  });
}
