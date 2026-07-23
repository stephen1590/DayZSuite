// editor.js — the Server Files tab: the merged file tree, the Fields<->File override editor
// (config-overrides.json field patches with per-mission layers), and the box-owned whole-file
// editor (bans/allowlist). Extracted from index.html (P1 modular split).
import { $, el } from './dom.js';
import { toast, setGlobalMsg, escapeHtml, attr, stripBom } from './ui.js';
import { apiPost, rateLimited } from './api-client.js';
import { loadCred, handle } from './auth.js';
import { detectLang, highlight, hlJson } from './highlight.js';
import { isOperator, getActiveMission, setActiveMission } from './state.js';
// Lossless big-int JSON: JS doubles corrupt integers >2^53 (a Steam64 ID typed …750 saved
// as …740, 2026-07-17). Every parse of CONFIG CONTENT goes through bigParse (big literals
// become sentinel strings, no double ever created); every display/serialize goes through
// bigStringify/restoreBigInts (exact literals back out). The API server normalizes to bare
// literals on disk. Plain JSON.parse/stringify remain ONLY for internal snapshots.
import { bigParse, bigStringify, restoreBigInts } from './lossless-json.js';
// CE types-table editor for registry web:'types' surfaces (the Expansion tuning pair) — its
// own module with its OWN save path (configs/set-types), never config-overrides.json.
import { renderTypesEditor, typesAnyDirty } from './types-editor.js';

let shellHooks = { syncHash: () => {} };
export function setEditorHooks(h) { shellHooks = { ...shellHooks, ...h }; }

// #files/<key> deep-link target, consumed once the tree loads (set by the shell applyRoute).
let pendingFile = null;
export function setPendingFile(v) { pendingFile = v || null; }

// ===================== Server Files: state =====================
// overridesDoc is the in-memory copy the editor mutates; Save ships the WHOLE doc to
// configs/set-overrides (the box snapshots + validates + writes). Whole files are fetched
// for context via the curated read (alias) or configs/target (relpath); only deltas saved.
let overridesDoc = {};
// activeMission -> js/state.js (shared: editor resolves 'common' against it, map defaults to it)
let configItems = [];     // /dayz/configs/list — now carries each file's relpath
let boxFiles = [];        // /dayz/configs/writable [{name, path}]
let roRe = [];            // /dayz/configs/readonly — compiled globs of generated (read-only) files
let rows = [];            // the merged tree rows (buildRows)
let selKey = null;        // selected row key
let selMode = null;       // null | 'edit' | 'own'
let ovrView = 'file';   // 'fields' | 'file'
let ovrFilter = '';     // Fields-view text filter — matches on the key/path
let ovrCapOpen = false; // Fields-view "show all" toggle, past the render cap
let ovrLeafMap = new Map();
let lastFileText = null;  // last fetched whole-file text (for Copy)
const fileCache = {};
// Whole-file Edit mode (distinct from the read-only View): edit the entire file, the API diffs
// it against the frozen default to derive a minimal delta, then Apply merges that delta into
// overridesDoc so the normal Save path commits it. wfShowDefault drives the View Live/Default toggle.
let wfDraft = null, wfPreview = null, wfBusy = false, wfShowDefault = false;
function wfReset() { wfDraft = null; wfPreview = null; wfBusy = false; wfShowDefault = false; }

// Dirty tracking: overridesDoc vs its last loaded/saved state. Drives the unsaved
// notification — the header pill, and the beforeunload guard so a reload/close can't
// silently drop edits. (In-memory edits survive a file/tab switch; only a reload or a
// fresh reload-from-server drops them.)
let savedSnapshot = '{}';
// Save gate: true only after config-overrides.json has loaded AND parsed in this session.
// Saving ships the WHOLE doc, so a save before a successful load would replace the box
// manifest with the empty {} above — this is the client half of the shrink guard
// (2026-07-16: a partial save gutted the manifest and a reboot reverted every override).
let overridesLoaded = false;
// Optimistic concurrency: the version hash config-overrides.json had when we loaded it. Sent
// back on Save so the box rejects (409) if another admin wrote in between — no silent clobber.
let ovrBaseVersion = null;
// Overrides-doc dirtiness alone — the guard for adopting/skipping a fresh overrides pull and
// for the Discard flow. The exported isDirty() ORs in the types editor so the header pill and
// the beforeunload guard cover every unsaved edit, whichever editor holds it.
function ovrDirtyOnly() { return JSON.stringify(overridesDoc) !== savedSnapshot; }
export function isDirty() { return ovrDirtyOnly() || typesAnyDirty(); }
function markClean() { savedSnapshot = JSON.stringify(overridesDoc); updateDirtyUi(); }
// Revert every unsaved edit back to the last saved config-overrides.json (the snapshot).
function discardChanges() {
  if (!ovrDirtyOnly()) { setGlobalMsg('No unsaved override changes to discard.', false); return; }
  if (!window.confirm('Discard all unsaved override changes? This reverts to the last saved config-overrides.json.')) return;
  overridesDoc = JSON.parse(savedSnapshot);
  updateDirtyUi(); renderFilesNav(); renderEditor();
  setGlobalMsg('Unsaved changes discarded.', false, true);
}
function updateDirtyUi() { const d = $('ovrDirty'); if (d) d.classList.toggle('on', isDirty()); }

function kindOf(p) { const s = (p || '').toLowerCase(); return s.endsWith('.xml') ? 'xml' : s.endsWith('.json') ? 'json' : 'other'; }
function jsonEnc(v) { return restoreBigInts(JSON.stringify(v)); }   // sentinel big-ints display as bare digits
function valPreview(v) {
  if (v === null || typeof v !== 'object') return jsonEnc(v);
  const n = Array.isArray(v) ? v.length : Object.keys(v).length;
  return (Array.isArray(v) ? '[ ' : '{ ') + n + (Array.isArray(v) ? ' item' : ' field') + (n === 1 ? '' : 's') + (Array.isArray(v) ? ' ]' : ' }');
}

// ===================== layers over config-overrides.json =====================
// A row's patches come in LAYERS: server-dir files have one ('files'); mission files
// have up to two — 'common' (applies to ALL missions) then 'mission' (wins on clash).
function docLayer(layer, fileKey, mission) {
  const mp = overridesDoc.mpmissions || {};
  if (layer === 'files') return (overridesDoc.files || {})[fileKey] || null;
  if (layer === 'common') return (mp.common || {})[fileKey] || null;
  return ((mp[mission] || {}))[fileKey] || null;
}
// Effective patch set for a row: Map selector -> { value, layer }. Mission layer wins.
function effectivePatches(row) {
  const out = new Map();
  const put = (map, layer) => {
    if (!map || typeof map !== 'object') return;
    for (const [k, v] of Object.entries(map)) { if (!k.startsWith('_')) out.set(k, { value: v, layer }); }
  };
  if (row.scope === 'files') put(docLayer('files', row.fileKey), 'files');
  else { put(docLayer('common', row.fileKey), 'common'); if (row.mission) put(docLayer('mission', row.fileKey, row.mission), 'mission'); }
  return out;
}
// The writable {selector: value} map for a layer of a row (creates parents).
function layerMapRW(row, layer) {
  const path = layer === 'files' ? ['files', row.fileKey]
    : layer === 'common' ? ['mpmissions', 'common', row.fileKey]
    : ['mpmissions', row.mission, row.fileKey];
  let cur = overridesDoc;
  for (const k of path) { if (cur[k] === null || typeof cur[k] !== 'object' || Array.isArray(cur[k])) cur[k] = {}; cur = cur[k]; }
  return cur;
}
// Which layer NEW overrides go to for this row (the chrome's selector for mission files).
function newLayerFor(row) {
  if (row.scope === 'files') return 'files';
  if (!row.mission) return 'common';
  const sel = $('ovrLayerSel');
  return sel && sel.value === 'common' ? 'common' : 'mission';
}

// ===================== the merged tree =====================
// One row per FILE, deduped by relpath. Sources: the curated /dayz/configs/list list (now
// with relpaths), the box-writable list, and any override entries the curated list
// doesn't surface. Pure function of its inputs (testable).
function makeRow(relpath, name, label, group) {
  const m = relpath ? relpath.match(/^mpmissions\/([^/]+)\/(.+)$/) : null;
  return {
    key: relpath, relpath, name, label, group,
    scope: m ? 'mission' : 'files',
    mission: m ? m[1] : null,
    fileKey: m ? m[2] : relpath,
    kind: kindOf(relpath || label),
  };
}
// Surfaces the Map tab (map.js) owns as a live spatial store - editable ONLY there, never as a
// config-editor override. An override on the store would fight the Map tab's spawn-write at boot,
// so the config editor shows these READ-ONLY. Name matches map.js's `configs/get?name=Map-points`.
const MAP_STORE_SURFACES = new Set(['Map-points']);
// GENERATED (compiler-output) files: a prestart builder OWNS these (config-registry.json
// "generated", surfaced by /dayz/configs/readonly), so an override on one is clobbered at boot.
// Shown READ-ONLY here - no edit, no save; change the SOURCE (map-points, common templates, the
// frozen base), never the output. A glob's '*' = the mission wildcard and spans '/'.
function globToRe(g) { return new RegExp('^' + g.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$'); }
function isGenerated(rel) { return !!rel && roRe.some((re) => re.test(rel)); }
function buildRows(items, writable, doc, mission) {
  const list = [];
  const byRel = new Map();
  const wByKey = new Map();
  for (const w of writable || []) { if (w && w.name) { wByKey.set(w.name, w); if (w.path) wByKey.set(w.path, w); } }
  for (const it of items || []) {
    const c = (typeof it === 'string') ? { group: 'General', name: it, label: it, path: it } : it;
    if (!c || !c.name || c.name === 'overrides' || c.path === 'config-overrides.json') continue;
    const rel = c.path || c.name;
    if (byRel.has(rel)) continue;                     // first listing wins (alias before folder copy)
    const row = makeRow(rel, c.name, c.label || c.name, c.group || 'General');
    const w = wByKey.get(c.name) || wByKey.get(rel) || null;
    // c.readonly = the registry's web:'view' surfaces (custom-ce types, mods.conf, messages.xml),
    // marked read-only by dayz-ctl's config-list. Locked like the Map-store, but its own copy so
    // the editor says "reference file" instead of "generated at boot".
    row.access = (MAP_STORE_SURFACES.has(c.name) || c.readonly) ? 'lock'   // Map-store or view-only: RO here
      : w ? 'own' : (row.kind === 'other' ? 'lock' : 'edit');
    if (c.readonly) row.readonly = true;
    // c.kind 'types' (registry web:'types') = a CE types file the types-table editor writes via
    // its OWN save path (configs/set-types). access stays 'edit' but renderBody/editorChrome
    // branch to the types view; the standard Save-deltas chrome never renders for these rows.
    if (c.kind === 'types' && !c.readonly) row.types = true;
    if (w) row.writableName = w.name;
    byRel.set(rel, row); list.push(row);
  }
  // Writable files the curated list doesn't surface.
  for (const w of writable || []) {
    if (!w || !w.name || [...byRel.values()].some((r) => r.writableName === w.name)) continue;
    const rel = w.path || w.name;
    if (byRel.has(rel)) { byRel.get(rel).access = 'own'; byRel.get(rel).writableName = w.name; continue; }
    const row = makeRow(rel, w.name, rel, 'box files');
    row.access = 'own'; row.writableName = w.name;
    byRel.set(rel, row); list.push(row);
  }
  // Override entries with no curated row -> their own sections.
  const missionKeys = new Set(list.filter((r) => r.scope === 'mission').map((r) => r.mission + '\n' + r.fileKey));
  const synth = (relpath, name, label, group) => {
    if (relpath && byRel.has(relpath)) return;
    const row = makeRow(relpath, name, label, group);
    row.access = row.kind === 'other' ? 'lock' : 'edit';
    if (relpath) byRel.set(relpath, row);
    list.push(row);
  };
  for (const f of Object.keys(doc.files || {})) {
    if (f.startsWith('_') || byRel.has(f)) continue;
    synth(f, null, f, 'overrides · server dir');
  }
  for (const [layer, files] of Object.entries(doc.mpmissions || {})) {
    if (layer.startsWith('_') || !files || typeof files !== 'object') continue;
    for (const f of Object.keys(files)) {
      if (f.startsWith('_')) continue;
      if (layer === 'common') {
        // The common layer gets its OWN row per file, ALWAYS — 'Map - All Missions'
        // is where all-missions changes live; mission folders show only their own
        // layer. Never registered in byRel (a mission row shares the resolved path).
        const row = makeRow(activeMissionRel(mission, f), null, f, 'Map - All Missions');
        row.key = 'common|' + f; row.scope = 'mission'; row.mission = null; row.fileKey = f; row.kind = kindOf(f);
        row.access = row.kind === 'other' ? 'lock' : 'edit';
        list.push(row);
      } else {
        if (missionKeys.has(layer + '\n' + f)) continue;
        synth('mpmissions/' + layer + '/' + f, null, f, 'overrides · ' + layer);
      }
    }
  }
  // Final sweep: any row that resolves to a GENERATED (compiler-output) file is read-only,
  // however it was created (curated listing, writable, or override-synth). This is the ONE place
  // the generated rule is enforced in the UI, so every code path above inherits it.
  for (const r of list) { if (isGenerated(r.relpath)) { r.access = 'lock'; r.generated = true; } }
  return list;
}
function activeMissionRel(mission, fileKey) { return mission ? 'mpmissions/' + mission + '/' + fileKey : null; }
// The row's OWN layer map (what the tree badge counts): common rows count the common
// layer, mission rows ONLY their mission layer, server-dir rows the files layer.
function ownLayerCount(row) {
  const map = row.scope === 'files' ? docLayer('files', row.fileKey)
    : row.mission === null ? docLayer('common', row.fileKey)
    : docLayer('mission', row.fileKey, row.mission);
  return map ? Object.keys(map).filter((k) => !k.startsWith('_')).length : 0;
}
function rowByKey(k) { return rows.find((r) => r.key === k) || null; }
function currentRow() { return selKey ? rowByKey(selKey) : null; }

function renderFilesNav() {
  rows = buildRows(configItems, boxFiles, overridesDoc, getActiveMission());
  // Preserve the user's expand/collapse choices across rerenders.
  const openState = new Map();
  el.filesNav.querySelectorAll('details.side-grp[data-g]').forEach((d) => openState.set(d.dataset.g, d.open));
  const groups = new Map();
  for (const r of rows) { if (!groups.has(r.group)) groups.set(r.group, []); groups.get(r.group).push(r); }
  // 'Map - All Missions' sits with the map groups: splice it in just before the first
  // group whose rows are mission-scoped (it renders last otherwise, being synthetic).
  let entries = [...groups];
  const ami = entries.findIndex(([g]) => g === 'Map - All Missions');
  if (ami >= 0) {
    const [amiEntry] = entries.splice(ami, 1);
    const firstMap = entries.findIndex(([, list]) => list.some((r) => r.scope === 'mission'));
    entries.splice(firstMap >= 0 ? firstMap : entries.length, 0, amiEntry);
  }
  let html = '';
  let i = 0;
  for (const [g, list] of entries) {
    const bySub = new Map();          // subfolder ('' = top) -> rows
    for (const r of list) {
      const slash = r.label.lastIndexOf('/');
      const sub = slash >= 0 ? r.label.slice(0, slash) : '';
      if (!bySub.has(sub)) bySub.set(sub, []);
      bySub.get(sub).push(Object.assign({}, r, { file: slash >= 0 ? r.label.slice(slash + 1) : r.label }));
    }
    const rowHtml = (r) => {
      const n = ownLayerCount(r);   // a mission row counts ONLY its own layer; common has its own row
      const badge = r.types ? '<span class="own-badge">rw</span>'
        : n > 0 ? '<span class="ovr-badge">' + n + '</span>'
        : r.access === 'own' ? '<span class="own-badge">rw</span>'
        : r.access === 'lock' ? '<span class="ro-badge">ro</span>' : '';
      return '<div class="side-item' + (r.key === selKey ? ' active' : '') + '" data-key="' + attr(r.key) + '" title="' + attr(r.relpath || r.label) + '">' +
        '<span class="fn">' + escapeHtml(r.file) + '</span>' + badge + '</div>';
    };
    let inner = (bySub.get('') || []).map(rowHtml).join('');
    for (const sub of [...bySub.keys()].filter(Boolean).sort()) inner += '<div class="side-sub2">' + escapeHtml(sub) + '</div>' + bySub.get(sub).map(rowHtml).join('');
    const open = openState.has(g) ? openState.get(g) : (i === 0 || list.some((r) => r.key === selKey));
    html += '<details class="side-grp"' + (open ? ' open' : '') + ' data-g="' + attr(g) + '"><summary>' + escapeHtml(g) + '<span class="side-count">' + list.length + '</span></summary>' + inner + '</details>';
    i++;
  }
  if (!rows.length) html = '<span class="meta" style="padding:10px;display:block">No files exposed.</span>';
  el.filesNav.innerHTML = html + '<div class="ovr-add" id="ovrAddFile"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 5v14M5 12h14"/></svg> Add a file to override…</div>';
  const a = $('ovrAddFile'); if (a) a.onclick = addFileFlow;
}

export function showFilesSurface() {
  el.editorPage.classList.toggle('hidden', selMode === 'own');
  el.ownfile.classList.toggle('hidden', selMode !== 'own');
}

function selectRow(key) {
  const row = rowByKey(key);
  if (!row) return;
  selKey = key;
  shellHooks.syncHash();                                     // reflect the open file in the URL (#files/<key>)
  ovrFilter = ''; ovrCapOpen = false;             // fresh file starts unfiltered and capped
  wfReset();                                       // fresh file: drop any whole-file draft/preview
  if (el.workspace) el.workspace.scrollTop = 0;   // fresh file: show the editor header + first fields, not wherever the last file was scrolled
  if (row.access === 'own') { el.editorPage.classList.remove('types-mode'); selMode = 'own'; renderFilesNav(); showFilesSurface(); loadOwn(row); return; }
  selMode = 'edit';
  ovrView = row.types ? 'types' : row.kind === 'other' ? 'file' : 'fields';
  renderFilesNav();
  showFilesSurface();
  el.edEmpty.classList.add('hidden');
  el.edEditor.classList.remove('hidden');
  renderEditor();
}

// A deep link (#files/<key>) stashes its target in pendingFile; select it once the tree is in.
// Nothing pending → reflect whatever's already selected in the URL (symmetry with docs/map).
function consumePendingFile() {
  if (pendingFile) {
    const k = pendingFile; pendingFile = null;
    if (rowByKey(k)) { selectRow(k); return; }   // selectRow syncs the hash itself
  }
  shellHooks.syncHash();
}

// Fetch everything the tree needs. configs/writable degrades to [] on an older API.
export async function loadFiles(preserve) {
  const cred = loadCred();
  if (!cred) return;
  try {
    // Conditional overrides pull: we already hold a parsed doc keyed by ovrBaseVersion, so send
    // that hash — an unchanged box doc answers { unchanged: true } with no payload instead of
    // re-shipping the whole document (it crossed 1MB on 2026-07-23; tab re-entries and the
    // post-save refresh were re-downloading it every time).
    const ovrQ = (overridesLoaded && ovrBaseVersion) ? '?ifVersion=' + encodeURIComponent(ovrBaseVersion) : '';
    const [cfgR, ovrR, boxR, roR] = await Promise.all([
      apiPost('/dayz/configs/list', cred),
      apiPost('/dayz/configs/overrides' + ovrQ, cred),   // content + version hash (optimistic concurrency)
      apiPost('/dayz/configs/writable', cred).catch(() => ({ files: [] })),
      apiPost('/dayz/configs/readonly', cred).catch(() => ({ files: [] })),   // generated (read-only) globs; [] on an older API
    ]);
    configItems = cfgR.configs || [];
    boxFiles = boxR.files || [];
    roRe = (roR.files || []).map(globToRe);
    // On a plain tab re-entry (preserve) keep unsaved override edits — only reload the doc from
    // the server on the initial load, after a save, or after a rollback. unchanged = the box
    // still holds exactly the doc we parsed; nothing to adopt.
    if (!(preserve && ovrDirtyOnly()) && !ovrR.unchanged) {
      try { overridesDoc = bigParse(stripBom(ovrR.content || '{}')); ovrBaseVersion = ovrR.version ?? null; overridesLoaded = true; markClean(); }
      catch { el.filesNav.innerHTML = '<span class="meta" style="padding:10px;display:block">config-overrides.json is not valid JSON.</span>'; return; }
    }
  } catch (err) {
    if (handle(err)) return;
    el.filesNav.innerHTML = '<span class="meta" style="padding:10px;display:block">Could not load: ' + escapeHtml(err.message) + '</span>';
    return;
  }
  if (getActiveMission() === null) {
    try { const s = await apiPost('/dayz/status', cred); setActiveMission(s.map || null); } catch { /* leave null */ }
  }
  renderFilesNav();
  if (selKey && !rowByKey(selKey)) { selKey = null; selMode = null; }
  showFilesSurface();
  if (selMode === 'edit' && currentRow()) { el.edEmpty.classList.add('hidden'); el.edEditor.classList.remove('hidden'); renderEditor(); }
  else if (selMode !== 'own') { el.editorPage.classList.remove('types-mode'); el.edEditor.classList.add('hidden'); el.edEmpty.classList.remove('hidden'); }
  consumePendingFile();   // a #files/<key> deep link selects its file now that the tree exists
  loadVersions();
}

// ===================== whole-file fetching =====================
// XML files written by the box (XmlDocument.Save) carry a UTF-8 BOM; as a JS string
// that's a leading U+FEFF, which breaks JSON.parse and can confuse DOMParser.
// stripBom -> js/ui.js (shared with the map's JSON loads).
// A row's content comes from its curated read alias when it has one, else configs/target
// by relpath (override targets are always in that allowlist).
async function fetchRowFile(row) {
  const ck = 'f|' + row.key;
  if (fileCache[ck]) return fileCache[ck];
  const cred = loadCred();
  if (!cred) return { text: null, err: 'not signed in' };
  try {
    let r;
    if (row.name) r = await apiPost('/dayz/configs/get?name=' + encodeURIComponent(row.name), cred);
    else if (row.relpath) r = await apiPost('/dayz/configs/target?name=' + encodeURIComponent(row.relpath), cred);
    else return { text: null, err: 'no active mission — start the server to resolve common/ files' };
    return (fileCache[ck] = { text: stripBom(r.content ?? ''), path: r.path || row.relpath });
  } catch (err) {
    if (err.status === 401) { handle(err); return { text: null, err: 'signed out' }; }
    return { text: null, err: err.status === 404 ? 'not readable on the box' : err.message };
  }
}
// The frozen-default companion (<name>.defaults<ext>) — the true default, since the live
// file is default+patches. 404 = no default captured yet: omit the default column quietly.
function defaultRelpath(rel) {
  const dot = rel.lastIndexOf('.'), slash = rel.lastIndexOf('/');
  return dot > slash ? rel.slice(0, dot) + '.defaults' + rel.slice(dot) : rel + '.defaults';
}
async function fetchDefaultFile(row) {
  if (!row.relpath) return { text: null };
  const drel = defaultRelpath(row.relpath);
  const ck = 'f|' + drel;
  if (fileCache[ck]) return fileCache[ck];
  const cred = loadCred();
  if (!cred) return { text: null };
  try {
    const r = await apiPost('/dayz/configs/target?name=' + encodeURIComponent(drel), cred);
    return (fileCache[ck] = { text: stripBom(r.content ?? '') });
  } catch (err) { if (err.status === 401) handle(err); return (fileCache[ck] = { text: null }); }
}

// ===================== the Fields ⇄ File editor =====================
// Chrome for a types row: its own segment pair (the types editor owns Save/Discard in its own
// toolbar, so the overrides Save-deltas / Discard buttons NEVER render here — they act on
// config-overrides.json, a different document).
function typesChrome(row) {
  return '<div class="ovr-phead">' +
    '<div class="ovr-ppath"><span class="crumb">files/</span><span class="nm">' + escapeHtml(row.fileKey || row.label) + '</span></div>' +
    '<div class="ovr-pact">' +
      '<span id="ovrDirty" class="ovr-unsaved' + (isDirty() ? ' on' : '') + '"><span class="ud-dot"></span>Unsaved changes</span>' +
      '<div class="seg" id="ovrSeg"><button data-v="types" class="' + (ovrView === 'types' ? 'on' : '') + '">Types editor</button><button data-v="file" class="' + (ovrView === 'file' ? 'on' : '') + '">View file</button></div>' +
      '<button class="btn-sm" id="ovrCopy" type="button">Copy</button>' +
    '</div></div>' +
    '<div class="ovr-sum"><span class="stat d"><span class="dot d"></span>web-edited CE types override layer — each entry fully replaces the same-named upstream type</span>' +
    '<span class="stat" style="margin-left:auto">Restart to apply</span></div>';
}
function editorChrome(row) {
  if (row.types) return typesChrome(row);
  const eff = effectivePatches(row);
  const nOver = eff.size;
  const locked = row.access === 'lock';
  const crumb = row.scope === 'files' ? 'files/' : ('mpmissions · ' + (row.mission || 'all missions') + '/');
  const layerSel = (row.scope === 'mission' && !locked)
    ? '<span class="lay-wrap">New overrides:<select id="ovrLayerSel" class="lay-sel"><option value="mission"' + (row.mission ? '' : ' disabled') + '>this mission only</option><option value="common"' + (row.mission ? '' : ' selected') + '>all missions</option></select></span>'
    : '';
  const summary = row.generated
    ? '<span class="stat"><span class="dot b"></span>generated file — built at boot from map-points + the frozen base; read-only here</span>'
    : row.readonly
    ? '<span class="stat"><span class="dot b"></span>read-only reference file — shipped with the deploy; view only</span>'
    : locked
    ? '<span class="stat"><span class="dot b"></span>read-only file — field overrides apply only to JSON/XML</span>'
    : '<span class="stat d"><span class="dot d"></span><b>' + nOver + '</b> ' + (row.kind === 'xml' ? 'XPath override' + (nOver === 1 ? '' : 's') : 'overridden') + '</span>';
  return '<div class="ovr-phead">' +
    '<div class="ovr-ppath"><span class="crumb">' + escapeHtml(crumb) + '</span><span class="nm">' + escapeHtml(row.fileKey || row.label) + '</span></div>' +
    '<div class="ovr-pact">' +
      '<span id="ovrDirty" class="ovr-unsaved' + (isDirty() ? ' on' : '') + '"><span class="ud-dot"></span>Unsaved changes</span>' +
      layerSel +
      // server-settings.json is fields-only: the whole-file views would expose the same 14
      // toggles a second way, and "Edit file" could add keys the renderer's allowlist refuses.
      (isCycleRow(row) ? '' :
        '<div class="seg" id="ovrSeg"><button data-v="fields" class="' + (ovrView === 'fields' ? 'on' : '') + '">Fields</button><button data-v="file" class="' + (ovrView === 'file' ? 'on' : '') + '">View file</button>' + (locked ? '' : '<button data-v="edit" class="' + (ovrView === 'edit' ? 'on' : '') + '" title="Edit the whole file — Save derives the minimal override delta">Edit file</button>') + '</div>') +
      '<button class="btn-sm" id="ovrCopy" type="button">Copy</button>' +
      (locked ? '' : '<button class="btn-sm" id="ovrDiscard" type="button">Discard</button>') +
      (locked ? '' : '<button class="btn-sm primary" id="ovrSave">Save ' + nOver + ' delta' + (nOver === 1 ? '' : 's') + '</button>') +
    '</div></div>' +
    '<div class="ovr-sum">' + summary + '<span class="stat" style="margin-left:auto">' + (locked ? '' : 'Restart to apply') + '</span></div>';
}
function editorFoot(row) {
  if (row.access === 'lock' || row.types) return '';   // types rows: the note below is about override DELTAS, wrong for a whole-file writer
  return '<div class="ovr-note" style="border-top:1px solid var(--border);border-bottom:none">' +
    '<b style="color:var(--delta)">Deltas only.</b> The whole file shows for context — Save writes just your changes to <span class="mono">config-overrides.json</span>.</div>';
}
async function renderEditor() {
  const row = currentRow();
  if (!row || row.access === 'own') return;
  el.edEditor.innerHTML = editorChrome(row) + '<div class="ovr-body" id="ovrBody"></div>' + editorFoot(row);
  const seg = $('ovrSeg');
  if (seg) seg.onclick = (e) => { const b = e.target.closest('button'); if (!b) return; ovrView = b.dataset.v; renderEditor(); };
  const save = $('ovrSave');
  if (save) save.onclick = () => saveOverrides();
  const discard = $('ovrDiscard');
  if (discard) discard.onclick = () => discardChanges();
  const copy = $('ovrCopy');
  if (copy) copy.onclick = async () => {
    try { await navigator.clipboard.writeText(lastFileText ?? ''); copy.textContent = 'Copied'; }
    catch { copy.textContent = 'Copy failed'; }
    setTimeout(() => { copy.textContent = 'Copy'; }, 1400);
  };
  await renderBody(row);
}
async function renderBody(row) {
  const body = $('ovrBody'); if (!body) return;
  // Fixed-height layout ONLY while the types TABLE shows: the top bars + XML preview stay put
  // and the LIST is the sole scroller (types-mode CSS on #editorPage). Everything else — the
  // overrides editor, and a types row's own 'file' view — keeps the normal workspace scroll.
  const typesTable = !!row.types && ovrView !== 'file';
  el.editorPage.classList.toggle('types-mode', typesTable);
  // Types rows: the table editor is its own view with its own load/save (types-editor.js).
  // The 'file' segment still falls through to the normal read-only whole-file view below.
  if (typesTable) {
    body.innerHTML = '<span class="meta" style="padding:16px;display:block">Loading types…</span>';
    const text = await renderTypesEditor(row, body, {
      onDirty: updateDirtyUi,
      onSaved: () => { delete fileCache['f|' + row.key]; },   // the File view refetches the saved doc
    });
    if (text != null && selKey === row.key) lastFileText = text;   // feed the Copy button
    return;
  }
  body.innerHTML = '<span class="meta" style="padding:16px;display:block">Loading file…</span>';
  const [file, def] = await Promise.all([fetchRowFile(row), row.access === 'lock' ? { text: null } : fetchDefaultFile(row)]);
  if (selKey !== row.key) return;                    // selection changed while awaiting
  lastFileText = file.text;
  const eff = effectivePatches(row);
  // Fields-only rows ignore whatever view the last row left in ovrView (it is module state).
  const view = isCycleRow(row) ? 'fields' : ovrView;
  if (view === 'file') { body.innerHTML = fileViewHtml(row, file, eff, def); wireFileView(row); return; }
  if (view === 'edit' && row.access !== 'lock') { body.innerHTML = editFileHtml(row, file); wireEditFile(row); return; }
  if (row.access === 'lock') {
    body.innerHTML = '<div class="ovr-note">This file type can\'t take field overrides — see the <b>File</b> view for its contents.</div>';
    return;
  }
  const wfNote = wholeFileOf(row) !== undefined
    ? '<div class="ovr-note wf-active"><b>Whole-file override active</b> — the box writes this file verbatim and ignores the field patches below. <button type="button" class="btn-sm" id="wfClear">Revert to field patches</button></div>'
    : '';
  // Fields first: jsonFieldsHtml populates ovrLeafMap, which the cycle panel reads for the
  // live values. The panel still renders ABOVE the list.
  const fieldsHtml = (row.kind === 'xml' ? xmlFieldsHtml(row, eff, def.text) : jsonFieldsHtml(row, eff, file.text, def.text));
  body.innerHTML = wfNote + (file.text === null ? '<div class="ovr-note">Whole-file context unavailable — ' + escapeHtml(file.err || 'unknown') + '. You can still edit existing overrides.</div>' : '') +
    (isCycleRow(row) ? cycleHtml(row, eff) : '') +
    '<div class="fld-filter"><input id="ovrFilter" type="text" placeholder="Filter fields by name…" spellcheck="false" autocomplete="off"><span id="ovrFilterNote" class="meta">no matching fields</span></div>' +
    fieldsHtml;
  const wfClr = $('wfClear'); if (wfClr) wfClr.onclick = () => wholeFileClear(row);
  wireFields(row);
  if (isCycleRow(row)) wireCycle(row);
  applyFieldVisibility();
}
// Fields-view visibility: filter by key substring, and cap the "rest of the file" list until expanded.
function applyFieldVisibility() {
  const body = $('ovrBody'); if (!body) return;
  const q = ovrFilter.trim().toLowerCase();
  let shown = 0;
  body.querySelectorAll('.fld').forEach((r) => {
    const kEl = r.querySelector('.k');
    // Match either what is shown or the real cfg key, so searching "whitelist" still finds
    // the field that now reads "enableAllowList".
    const shown = (kEl?.textContent || '').toLowerCase();
    const real  = (kEl?.dataset.key || '').toLowerCase();
    const vis = q ? (shown.includes(q) || real.includes(q)) : (ovrCapOpen || !r.classList.contains('cap-hide'));
    r.style.display = vis ? '' : 'none';
    if (vis) shown++;
  });
  const moreWrap = $('ovrMoreWrap'); if (moreWrap) moreWrap.style.display = (!q && !ovrCapOpen) ? '' : 'none';
  const note = $('ovrFilterNote'); if (note) note.style.display = (q && shown === 0) ? 'inline' : 'none';
  body.querySelectorAll('.fdiv').forEach((d) => { d.style.display = q ? 'none' : ''; });   // "Rest of file" divider is noise while filtering
}

function flattenJson(obj, prefix, out) {
  for (const [k, v] of Object.entries(obj)) {
    const path = prefix ? prefix + '.' + k : k;
    if (v !== null && typeof v === 'object' && !Array.isArray(v)) flattenJson(v, path, out);
    else out.push({ path, value: v });
  }
  return out;
}
// One overridden-field row. layer = which overrides layer holds it ('common' gets the
// 'all missions' chip); def = the frozen-default value string (context for the change).
function fieldRowOver(row, sel, val, def, layer, help, label) {
  const mode = cxMode(val);
  const e = jsonEnc(val);
  const input = mode
    ? '<div class="cxcell" data-sel="' + attr(sel) + '" data-layer="' + layer + '" data-mode="' + mode + '">'
        + '<div class="cx-collapsed" tabindex="0" title="Click to edit — ' + (mode === 'json' ? 'formatted &amp; highlighted' : 'full text box') + '">'
        + '<span class="cx-caret">&#9656;</span><span class="cx-sum">' + escapeHtml(cxSummary(val, mode)) + '</span></div></div>'
    : '<div class="cxcell scalar" data-sel="' + attr(sel) + '" data-layer="' + layer + '">'
        + '<input class="ovr-inp" data-sel="' + attr(sel) + '" data-layer="' + layer + '" value="' + attr(e) + '">'
        + (row.kind === 'xml' ? '' : '<button type="button" class="cx-btn cx-fmt" title="Format / expand a pasted object or array">&#8690;</button>')
        + '</div>';
  const layerChip = (row.scope === 'mission' && layer === 'common') ? '<span class="tag all">all missions</span>' : '';
  const tag = row.kind === 'xml' ? '<span class="tag">override</span>' : (mode ? '<span class="tag cx">' + mode + '</span>' : '<span class="tag">override</span>');
  const defHtml = def != null ? '<span class="base">default ' + escapeHtml(String(def)) + '</span>' : '';
  return '<div class="fld over">' + keyCell(sel, label) + '<div>' + input + '</div>' + helpCell(help) + '<div class="meta2">' + layerChip + tag + defHtml + '</div><button class="x ovr-rm" data-sel="' + attr(sel) + '" data-layer="' + layer + '" title="Remove override — reverts this field to its default">✕</button></div>';
}
// The comment column. Text comes from the file's own "_help" map, which for
// server-settings.json is lifted verbatim from serverDZ.cfg.template's trailing // comments -
// the game's own documentation of each field, rather than a second set of wording to maintain.
// null = this list has no help at all, so the row keeps the original 4-column grid.
function helpCell(help) { return help === null || help === undefined ? '' : '<div class="hlp">' + escapeHtml(help) + '</div>'; }
// The key cell. A "_labels" entry renames it for READING only — data-key keeps the real
// selector so the filter, the override write and the box all still see the game's own name,
// and the tooltip shows it too, so nobody is left guessing what actually lands in the cfg.
function keyCell(sel, label) {
  const shown = label || sel;
  const renamed = shown !== sel;
  return '<div class="k' + (renamed ? ' renamed' : '') + '" data-key="' + attr(sel) + '" title="' + attr(renamed ? sel + '  (written to serverDZ.cfg under this name)' : sel) + '">' + escapeHtml(shown) + '</div>';
}
// ===================== serverDZ.cfg day/night cycle =====================
// server-settings.json is the web-editable slice of serverDZ.cfg (Apply-ServerCfg renders the
// real file at prestart). Two of its keys only mean anything together: serverTimeAcceleration
// (X) scales in-game time, serverNightTimeAcceleration (Y) multiplies again during night only.
// As bare multipliers they tell an admin nothing, so this panel shows the real-world clock
// players actually feel:
//     day_real = D / X        night_real = (24 - D) / (X * Y)      cycle = day + night
// where D = in-game daylight hours. D varies by map/season; 12 is the standard assumption and
// is stated in the panel rather than hidden.
//
// NOTE: this supersedes the formula that used to be in docs/SETUP.md and .internal/OPERATIONS.md
// (full = 24/X, night = 24/(X*Y), day = full - night). That one treats all 24 in-game hours as
// running at the day rate and then carves night out of the result, so it overstates the cycle
// and breaks outright at Y=1 - no night acceleration reported day = 0 rather than an even split.
// Both docs were corrected to match this. 2026-07-22.
//
// Map selection is NOT here - that is map.env -> the unit's -mission=; serverDZ.cfg's Missions
// block is untouched by the renderer.
const CYCLE_FILE = 'server-settings.json';
const CYCLE_X = 'serverTimeAcceleration';
const CYCLE_Y = 'serverNightTimeAcceleration';
const CYCLE_DAYLIGHT = 12;     // assumed in-game daylight hours; stated in the panel
function isCycleRow(row) { return !!row && row.relpath === CYCLE_FILE; }
function cycleHours(x, y, D = CYCLE_DAYLIGHT) {
  const day = D / x, night = (24 - D) / (x * y);
  return { day, night, full: day + night };
}
function hm(h) {
  if (!isFinite(h) || h <= 0) return '—';
  const t = Math.round(h * 60);
  return (t >= 60 ? Math.floor(t / 60) + 'h ' : '') + (t % 60) + 'm';
}
// Effective value for a cycle key: the pending override wins, else the live file, else the default.
function cycleVal(eff, sel, fallback) {
  const o = eff.get(sel);
  const raw = o ? o.value : (ovrLeafMap.has(sel) ? ovrLeafMap.get(sel) : fallback);
  const n = Number(raw);
  return (isFinite(n) && n > 0) ? n : fallback;
}
const CYCLE_RESTART_H = 4;     // the messages.xml restart schedule, for "cycles per restart"
function cycleOutHtml(x, y) {
  const c = cycleHours(x, y);
  const ok = isFinite(c.full) && c.full > 0;
  const dayPct = ok ? Math.max(0, Math.min(100, (c.day / c.full) * 100)) : 0;
  const bar = !ok ? ''
    : '<div class="cyc-bar"><i class="day" style="width:' + dayPct.toFixed(2) + '%">'
      + (dayPct >= 18 ? 'Daylight ' + escapeHtml(hm(c.day)) : '') + '</i>'
      + '<i class="night" style="width:' + (100 - dayPct).toFixed(2) + '%">'
      + (100 - dayPct >= 18 ? 'Night ' + escapeHtml(hm(c.night)) : '') + '</i></div>';
  const perRestart = ok ? (CYCLE_RESTART_H / c.full) : null;
  const nums = '<div class="cyc-nums">'
    + '<span>Full cycle <b>' + escapeHtml(hm(c.full)) + '</b></span>'
    + '<span>Daylight <b>' + escapeHtml(hm(c.day)) + '</b></span>'
    + '<span>Night <b>' + escapeHtml(hm(c.night)) + '</b></span>'
    + '<span>Cycles per restart <b>' + (perRestart === null ? '—' : perRestart.toFixed(1)) + '</b> <span class="meta">(' + CYCLE_RESTART_H + 'h schedule)</span></span>'
    + '</div>';
  // Y below 1 means night runs SLOWER than day - legal, rarely intended.
  const warn = (y < 1)
    ? '<div class="cyc-warn">Night acceleration below 1 makes night pass slower than daylight — night becomes the longest part of the cycle.</div>' : '';
  return bar + nums + warn;
}
function cycleHtml(row, eff) {
  const x = cycleVal(eff, CYCLE_X, 5), y = cycleVal(eff, CYCLE_Y, 4);
  const ctl = (sel, label, val, min, max, step, hint) =>
    '<div class="cyc-ctl"><label for="cyc-' + sel + '">' + escapeHtml(label) + '</label>'
    + '<div class="cyc-row">'
    + '<input type="range" id="cyc-' + sel + '" class="cyc-in" data-sel="' + attr(sel) + '" min="' + min + '" max="' + max + '" step="' + step + '" value="' + val + '">'
    + '<input type="number" class="cyc-num" data-sel="' + attr(sel) + '" min="' + min + '" max="' + max + '" step="' + step + '" value="' + val + '">'
    + '</div><span class="cyc-hint">' + escapeHtml(hint) + '</span></div>';
  return '<div class="cyc" id="cycPanel">'
    + '<h4>Day / night cycle</h4>'
    + '<p class="cyc-sub">What these two multipliers actually buy in real time, assuming ' + CYCLE_DAYLIGHT + 'h of in-game daylight. Moving a slider writes the same field override as the list below — press Save, then restart to apply.</p>'
    + '<div class="cyc-grid">'
    + ctl(CYCLE_X, 'Time acceleration (X)', x, 1, 24, 0.5, 'Scales in-game time overall. Higher = shorter days.')
    + ctl(CYCLE_Y, 'Night acceleration (Y)', y, 1, 24, 0.5, 'Multiplies again during night only. Higher = shorter nights.')
    + '</div>'
    + '<div class="cyc-out" id="cycOut">' + cycleOutHtml(x, y) + '</div>'
    + '<div class="cyc-foot">'
    + '<span class="cyc-note">Applies at the next restart — Apply-ServerCfg renders serverDZ.cfg at prestart. Map selection is unaffected (that is map.env).</span>'
    // These two keys are hidden from the field list below, so this is the only way back to the
    // frozen default once one is overridden.
    + ((eff.has(CYCLE_X) || eff.has(CYCLE_Y)) ? '<button type="button" class="btn-sm" id="cycReset">Reset to default</button>' : '')
    + '</div></div>';
}
function wireCycle(row) {
  const panel = $('cycPanel'); if (!panel) return;
  const out = $('cycOut');
  const readAll = () => {
    const g = (sel) => Number(panel.querySelector('.cyc-in[data-sel="' + sel + '"]').value);
    return { x: g(CYCLE_X), y: g(CYCLE_Y) };
  };
  const redraw = () => { const v = readAll(); if (out) out.innerHTML = cycleOutHtml(v.x, v.y); };
  // Live readout while dragging; the override is written on release/commit so the field list
  // and the dirty flag update once, not on every intermediate pixel.
  const commit = (sel, valStr) => {
    const n = Number(valStr);
    if (!isFinite(n) || n <= 0) { setGlobalMsg('Acceleration must be a positive number.', true); return; }
    layerMapRW(row, newLayerFor(row))[sel] = n;
    updateDirtyUi();
    renderFilesNav(); renderEditor();
    setGlobalMsg('Unsaved change — press Save.', false);
  };
  panel.querySelectorAll('.cyc-in').forEach((s) => {
    const num = panel.querySelector('.cyc-num[data-sel="' + s.dataset.sel + '"]');
    s.addEventListener('input', () => { if (num) num.value = s.value; redraw(); });
    s.addEventListener('change', () => commit(s.dataset.sel, s.value));
  });
  panel.querySelectorAll('.cyc-num').forEach((n) => {
    const sld = panel.querySelector('.cyc-in[data-sel="' + n.dataset.sel + '"]');
    n.addEventListener('input', () => { if (sld) sld.value = n.value; redraw(); });
    n.addEventListener('change', () => commit(n.dataset.sel, n.value));
  });
  const rst = $('cycReset');
  if (rst) rst.onclick = () => {
    const now = effectivePatches(row);
    let n = 0;
    for (const sel of [CYCLE_X, CYCLE_Y]) {
      const o = now.get(sel);
      if (!o) continue;
      delete layerMapRW(row, o.layer)[sel];
      n++;
    }
    if (!n) return;
    updateDirtyUi(); renderFilesNav(); renderEditor();
    setGlobalMsg('Cycle reverted to default — press Save.', false);
  };
}

function jsonFieldsHtml(row, eff, text, defaultText) {
  let fileObj = null;
  if (text !== null) { try { fileObj = bigParse(text); } catch { fileObj = null; } }
  let defObj = null;
  if (defaultText != null) { try { defObj = bigParse(defaultText); } catch { defObj = null; } }
  const defMap = (defObj && typeof defObj === 'object' && !Array.isArray(defObj)) ? new Map(flattenJson(defObj, '', []).map((l) => [l.path, l.value])) : new Map();
  const leaves = (fileObj && typeof fileObj === 'object' && !Array.isArray(fileObj)) ? flattenJson(fileObj, '', []) : [];
  ovrLeafMap = new Map(leaves.map((l) => [l.path, l.value]));
  // "_help": { key: "comment" } — per-field documentation carried by the file itself.
  const rawHelp = (fileObj && fileObj._help && typeof fileObj._help === 'object' && !Array.isArray(fileObj._help)) ? fileObj._help : null;
  const helpMap = new Map(rawHelp ? Object.entries(rawHelp).filter(([, v]) => typeof v === 'string') : []);
  const hasHelp = helpMap.size > 0;
  const helpFor = (sel) => (hasHelp ? (helpMap.get(sel) || '') : null);
  // "_labels": { key: "display name" } — DISPLAY ONLY. The game dictates the real cfg key
  // (enableWhitelist), so that is what gets written, filtered and patched; this only changes
  // what a human reads. Same idea as the registry surfacing whitelist.txt as "Allowlist".
  const rawLabels = (fileObj && fileObj._labels && typeof fileObj._labels === 'object' && !Array.isArray(fileObj._labels)) ? fileObj._labels : null;
  const labelMap = new Map(rawLabels ? Object.entries(rawLabels).filter(([, v]) => typeof v === 'string' && v) : []);
  const labelFor = (sel) => labelMap.get(sel) || sel;
  // Rows this list must not offer as plain fields:
  //   - anything under an underscore key (_readme/_help) — the override engine drops those, so
  //     showing them as overridable only invites a patch that silently does nothing;
  //   - the two cycle multipliers on server-settings.json — the slider panel above owns them,
  //     and a second editor for the same value is just a way to disagree with yourself.
  const skip = (sel) => sel.startsWith('_') || (isCycleRow(row) && (sel === CYCLE_X || sel === CYCLE_Y));
  let html = '<div class="fields' + (hasHelp ? ' with-help' : '') + '">';
  for (const [sel, p] of eff) {
    if (skip(sel)) continue;
    const def = defMap.has(sel) ? valPreview(defMap.get(sel)) : null;
    html += fieldRowOver(row, sel, p.value, def, p.layer, helpFor(sel), labelFor(sel));
  }
  if (fileObj === null && text !== null) html += '<div class="ovr-note">This file isn\'t valid JSON — showing overrides only.</div>';
  const ctx = leaves.filter((l) => !eff.has(l.path) && !skip(l.path));
  if (ctx.length) {
    html += '<div class="fdiv">Rest of the file — click a value to override it</div>';
    const CAP = 100;   // render all, but hide past CAP behind a Show-more button (filtering ignores the cap)
    ctx.forEach((l, i) => {
      const lm = cxMode(l.value);
      const lprev = lm ? cxSummary(l.value, lm) : valPreview(l.value);
      html += '<div class="fld ctx' + (i >= CAP ? ' cap-hide' : '') + '">' + keyCell(l.path, labelFor(l.path)) + '<div class="v ovr-addv" data-sel="' + attr(l.path) + '" title="Click to override">' + escapeHtml(lprev) + '</div>' + helpCell(helpFor(l.path)) + '<div class="meta2"><button class="addb ovr-addctx" data-sel="' + attr(l.path) + '">+ override</button></div><span></span></div>';
    });
    if (ctx.length > CAP) html += '<div class="fld-more" id="ovrMoreWrap"><button type="button" id="ovrMore" class="ghost">Show ' + (ctx.length - CAP) + ' more field' + (ctx.length - CAP === 1 ? '' : 's') + '</button></div>';
  }
  html += '<div class="frow-add"><button class="ghost" id="ovrAddSel" type="button">+ Add override</button></div></div>';
  return html;
}
// The default value of an XPath selector = evaluate it against the frozen default XML.
function xmlValueAt(doc, sel) {
  try {
    const n = doc.evaluate(sel, doc, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
    if (!n) return null;
    return n.nodeValue != null ? n.nodeValue : n.textContent;
  } catch { return null; }
}
function xmlFieldsHtml(row, eff, defaultText) {
  let doc = null;
  if (defaultText != null) { try { doc = new DOMParser().parseFromString(defaultText, 'application/xml'); if (doc.querySelector('parsererror')) doc = null; } catch { doc = null; } }
  let html = '<div class="ovr-note">XML overrides are XPath selectors — flip to the <b>File</b> view to see each one resolved against the live file.</div><div class="fields">';
  for (const [sel, p] of eff) html += fieldRowOver(row, sel, p.value, doc ? xmlValueAt(doc, sel) : null, p.layer);
  html += '<div class="frow-add"><button class="ghost" id="ovrAddSel" type="button">+ Add XPath override</button></div></div>';
  return html;
}
function xmlEvalHtml(text, sels) {
  if (!sels.length) return '';
  let doc = null, perr = false;
  try { doc = new DOMParser().parseFromString(text, 'application/xml'); perr = !!doc.querySelector('parsererror'); } catch { perr = true; }
  let rows2 = '';
  for (const sel of sels) {
    let state;
    if (perr || !doc) state = 'parse error';
    else { try { state = doc.evaluate(sel, doc, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null).snapshotLength > 0 ? 'ok' : 'none'; } catch { state = 'bad xpath'; } }
    const badge = state === 'ok' ? '<span class="tag">matched</span>' : '<span class="tag warn">' + (state === 'none' ? 'no match' : state) + '</span>';
    rows2 += '<div class="row2">' + badge + '<span class="sel">' + escapeHtml(sel) + '</span></div>';
  }
  return '<div class="xeval"><div class="stat" style="color:var(--faint);margin-bottom:2px">XPaths evaluated against this file</div>' + rows2 + '</div>';
}
function fileViewHtml(row, file, eff, def) {
  const canDef = !!(def && def.text != null);
  const showDef = wfShowDefault && canDef;
  const text = showDef ? def.text : file.text;
  if (text === null) return '<div class="ovr-note">Whole-file view unavailable — ' + escapeHtml(file.err || 'unknown') + '.</div>';
  // Live/Default toggle — lets anyone SEE the frozen baseline the Edit mode diffs against.
  const toggle = canDef ? '<div class="seg wf-vtoggle" id="wfVToggle"><button data-d="live" class="' + (showDef ? '' : 'on') + '">Live file</button><button data-d="def" class="' + (showDef ? 'on' : '') + '">Default</button></div>' : '';
  const head = (!showDef && row.kind === 'xml') ? xmlEvalHtml(file.text, [...eff.keys()]) : '';
  return '<div class="fileview">' + toggle + head + '<pre>' + highlight(text, detectLang(row.relpath || row.label)) + '</pre></div>';
}
function wireFileView(row) {
  const tg = $('wfVToggle');
  if (tg) tg.onclick = (e) => { const b = e.target.closest('button'); if (!b) return; wfShowDefault = (b.dataset.d === 'def'); renderBody(row); };
}

// ===================== whole-file Edit mode =====================
// Which override layer a whole-file delta writes to, and whether that's safe. A files-scope row
// is always its single 'files' layer. A mission file already layering BOTH all-missions (common)
// and this-mission can't be split from a merged whole-file edit — block it, keep Fields for those.
function wfTarget(row) {
  if (row.scope === 'files') return { layer: 'files', ok: true };
  const hasCommon = !!docLayer('common', row.fileKey);
  const hasMission = !!(row.mission && docLayer('mission', row.fileKey, row.mission));
  if (hasCommon && hasMission) return { ok: false, why: 'this file overrides in BOTH the all-missions and this-mission layers — a merged whole-file edit can’t tell them apart. Use Fields here.' };
  if (hasCommon) return { layer: 'common', ok: true };
  if (hasMission) return { layer: 'mission', ok: true };
  return { layer: newLayerFor(row), ok: true };   // fresh file: honour the New-overrides selector
}
function editFileHtml(row, file) {
  if (file.text === null) return '<div class="ovr-note">Whole-file editing needs the live file — ' + escapeHtml(file.err || 'unavailable') + '. Use Fields.</div>';
  const draft = wfDraft != null ? wfDraft : file.text;
  return '<div class="wfedit">' +
    '<div class="wf-bar">' +
      '<span class="wf-hint">Edit the whole file — <b>Preview</b> derives the minimal override delta by diffing the frozen default. Use this only when Fields can’t express the change.</span>' +
      '<button type="button" class="btn-sm" id="wfViewDefault">View default</button>' +
      '<button type="button" class="btn-sm primary" id="wfPreviewBtn"><span class="wf-sp hidden" id="wfSpin"></span>Preview changes</button>' +
    '</div>' +
    '<textarea class="wf-ta" id="wfTa" spellcheck="false" autocomplete="off" wrap="off">' + escapeHtml(draft) + '</textarea>' +
    '<div class="wf-preview" id="wfPrev"></div>' +
  '</div>';
}
function renderWfPreview(row) {
  const box = $('wfPrev'); if (!box) return;
  if (wfBusy) { box.innerHTML = '<div class="ovr-note"><span class="wf-sp"></span>Deriving the delta…</div>'; return; }
  const p = wfPreview;
  if (!p) { box.innerHTML = ''; return; }
  if (p.mode === 'delta') {
    const t = wfTarget(row);
    const keys = Object.keys(p.delta || {});
    const list = keys.length
      ? '<ul class="wf-dlist">' + keys.map((k) => '<li><span class="mono">' + escapeHtml(k) + '</span> = <span class="mono">' + escapeHtml(valPreview(p.delta[k])) + '</span></li>').join('') + '</ul>'
      : '<div class="meta">No changes vs the default — nothing to override.</div>';
    const layerNote = (row.scope !== 'files' && t.ok) ? '<div class="meta">Writes to the <b>' + (t.layer === 'common' ? 'all-missions' : 'this-mission') + '</b> layer.</div>' : '';
    box.innerHTML = '<div class="wf-ptitle wf-ok">' + p.changed + ' override' + (p.changed === 1 ? '' : 's') + ' derived' + (p.hasDefault ? '' : ' — no default captured') + '</div>' + list + layerNote +
      '<div class="wf-pact">' + (t.ok && keys.length ? '<button type="button" class="btn-sm primary" id="wfApplyBtn">Apply to overrides</button>' : '') +
      (t.ok ? '' : '<span class="meta warn">' + escapeHtml(t.why) + '</span>') + '</div>';
    const apply = $('wfApplyBtn'); if (apply) apply.onclick = () => wfApply(row);
  } else {
    const t = wfTarget(row);
    box.innerHTML = '<div class="wf-ptitle wf-warn">Whole-file override</div>' +
      '<div class="ovr-note">' + escapeHtml(p.reason || 'this edit can’t be expressed as a clean delta') + '.<br>Storing it owns this file wholesale — it <b>won’t track baseline / mod updates</b> (the box writes your content verbatim every boot).</div>' +
      '<div class="wf-pact">' + (t.ok ? '<button type="button" class="btn-sm primary" id="wfApplyBtn">Store as whole-file override</button>' : '<span class="meta warn">' + escapeHtml(t.why) + '</span>') + '</div>';
    const apply = $('wfApplyBtn'); if (apply) apply.onclick = () => wfApply(row);
  }
}
async function wfDoPreview(row) {
  const cred = loadCred(); if (!cred) return;
  const ta = $('wfTa'); if (ta) wfDraft = ta.value;
  wfBusy = true; wfPreview = null;
  renderWfPreview(row);
  try {
    const r = await apiPost('/dayz/configs/preview-override', cred, { name: row.relpath, content: wfDraft != null ? wfDraft : '' });
    if (selKey !== row.key) return;                       // selection moved while awaiting
    wfPreview = r;
  } catch (err) {
    if (handle(err)) return;
    wfPreview = { mode: 'wholefile', reason: 'preview failed: ' + err.message };
  } finally {
    if (selKey === row.key) { wfBusy = false; renderWfPreview(row); }
  }
}
// Set / delete a nested path in overridesDoc (object parents created as needed).
function ovrSetPath(keys, val) {
  let cur = overridesDoc;
  for (let i = 0; i < keys.length - 1; i++) { const k = keys[i]; if (!cur[k] || typeof cur[k] !== 'object' || Array.isArray(cur[k])) cur[k] = {}; cur = cur[k]; }
  cur[keys[keys.length - 1]] = val;
}
function ovrDelPath(keys) {
  let cur = overridesDoc;
  for (let i = 0; i < keys.length - 1; i++) { const k = keys[i]; if (!cur[k] || typeof cur[k] !== 'object') return; cur = cur[k]; }
  delete cur[keys[keys.length - 1]];
}
// This row's whole-file override content, if any (files layer, or its mission/common layer).
function wholeFileOf(row) {
  const wf = overridesDoc.wholeFiles || {};
  if (row.scope === 'files') return (wf.files || {})[row.fileKey];
  const mp = wf.mpmissions || {};
  if (row.mission && mp[row.mission] && mp[row.mission][row.fileKey] !== undefined) return mp[row.mission][row.fileKey];
  return (mp.common || {})[row.fileKey];
}
function wholeFileClear(row) {
  const mp = (overridesDoc.wholeFiles || {}).mpmissions || {};
  if (row.scope === 'files') ovrDelPath(['wholeFiles', 'files', row.fileKey]);
  else if (row.mission && mp[row.mission] && mp[row.mission][row.fileKey] !== undefined) ovrDelPath(['wholeFiles', 'mpmissions', row.mission, row.fileKey]);
  else ovrDelPath(['wholeFiles', 'mpmissions', 'common', row.fileKey]);
  updateDirtyUi(); renderFilesNav(); renderEditor();
  setGlobalMsg('Whole-file override cleared — this file goes back to field patches / the default. Save to apply.', false);
}
function wfApply(row) {
  const p = wfPreview; if (!p) return;
  const t = wfTarget(row); if (!t.ok) return;
  const path = t.layer === 'files' ? ['files', row.fileKey]
    : t.layer === 'common' ? ['mpmissions', 'common', row.fileKey]
    : ['mpmissions', row.mission, row.fileKey];
  let msg;
  if (p.mode === 'delta') {
    // The whole-file edit owns this file's override set vs the default → replace the target
    // layer's patch block with the derived delta; drop any prior whole-file entry for it.
    ovrSetPath(path, JSON.parse(JSON.stringify(p.delta)));
    ovrDelPath(['wholeFiles', ...path]);
    const n = Object.keys(p.delta).length;
    msg = 'Applied ' + n + ' override' + (n === 1 ? '' : 's') + ' from the whole-file edit — review in Fields, then Save.';
  } else {
    // Whole-file fallback: own the file wholesale (stored in wholeFiles; the box writes it verbatim
    // and skips this file's patches). It won't track baseline/mod updates — that's the trade.
    ovrSetPath(['wholeFiles', ...path], wfDraft != null ? wfDraft : '');
    ovrDelPath(path);
    msg = 'Stored a whole-file override — this file is now owned wholesale (won’t track baseline updates). Review in Fields, then Save.';
  }
  wfReset();
  updateDirtyUi();
  ovrView = 'fields';
  renderFilesNav(); renderEditor();
  setGlobalMsg(msg, false);
}
function wireEditFile(row) {
  const ta = $('wfTa'); if (ta) ta.oninput = () => { wfDraft = ta.value; wfPreview = null; renderWfPreview(row); };
  const pv = $('wfPreviewBtn'); if (pv) pv.onclick = () => wfDoPreview(row);
  const vd = $('wfViewDefault'); if (vd) vd.onclick = () => { wfShowDefault = true; ovrView = 'file'; renderEditor(); };
  renderWfPreview(row);
}

// ===================== mutations =====================
function addOverride(row, sel, initial) {
  const layer = newLayerFor(row);
  const map = layerMapRW(row, layer);
  if (!(sel in map)) map[sel] = initial;
  renderFilesNav(); renderEditor();
  setGlobalMsg('Override added — edit its value, then Save.', false);
}
// ---- boxed-value editor: expand a summary into a formatted+highlighted JSON box
//      (objects/arrays) or a plain full-text box (long strings), collapse on commit ----
const CX_TEXT_MIN = 80;   // strings longer than this (or multiline) get the text box, not a cramped input
function cxMode(v) {
  if (v !== null && typeof v === 'object') return 'json';
  if (typeof v === 'string' && (v.length > CX_TEXT_MIN || v.includes('\n'))) return 'text';
  return null;            // short scalar — stays a single-line input
}
function cxSummary(v, mode) {
  if (mode === 'json') return valPreview(v);
  const s = String(v).replace(/\s+/g, ' ').trim();
  return '"' + (s.length > 52 ? s.slice(0, 52) + '…' : s) + '"';
}
function cxAutoSize(ta) { ta.style.height = 'auto'; ta.style.height = Math.min(Math.max(ta.scrollHeight, 60), 460) + 'px'; }
function cxCollapse(row, cell, val) {
  const mode = cxMode(val) || 'json';
  cell.dataset.mode = mode;
  cell.classList.remove('open');
  cell.innerHTML = '<div class="cx-collapsed" tabindex="0" title="Click to edit">'
    + '<span class="cx-caret">&#9656;</span><span class="cx-sum">' + escapeHtml(cxSummary(val, mode)) + '</span></div>';
  const el = cell.querySelector('.cx-collapsed');
  el.addEventListener('click', () => cxExpand(row, cell));
  el.addEventListener('keydown', (ev) => { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); cxExpand(row, cell); } });
}
function cxCommit(row, cell, ta, msg, mode) {
  let v;
  if (mode === 'text') { v = ta.value; }
  else { try { v = bigParse(ta.value); } catch { ta.classList.add('bad'); msg.textContent = 'Fix JSON before closing'; msg.classList.add('bad'); ta.focus(); return false; } }
  layerMapRW(row, cell.dataset.layer)[cell.dataset.sel] = v;
  updateDirtyUi(); setGlobalMsg('Unsaved change — press Save.', false);
  if (cxMode(v) === null) renderEditor();   // shrank to a plain scalar — re-render it as an input
  else cxCollapse(row, cell, v);
  return true;
}
function cxExpand(row, cell) {
  const mode = cell.dataset.mode === 'text' ? 'text' : 'json';
  const cur = layerMapRW(row, cell.dataset.layer)[cell.dataset.sel];
  cell.classList.add('open');
  const tools = (mode === 'json' ? '<button type="button" class="cx-btn cx-fmt" title="Re-indent, or parse pasted JSON">Format</button>' : '')
    + '<button type="button" class="cx-btn cx-done">Done</button><span class="cx-msg"></span>';
  cell.innerHTML = (mode === 'json'
      ? '<div class="cx-edit"><pre class="cx-hl" aria-hidden="true"></pre><textarea class="cx-ta" spellcheck="false"></textarea></div>'
      : '<div class="cx-edit text"><textarea class="cx-ta" spellcheck="false"></textarea></div>')
    + '<div class="cx-tools">' + tools + '</div>';
  const ta = cell.querySelector('.cx-ta'), hl = cell.querySelector('.cx-hl'), msg = cell.querySelector('.cx-msg');
  const clearErr = () => { ta.classList.remove('bad'); msg.textContent = ''; msg.classList.remove('bad'); };
  // JSON mode paints the highlight layer behind the transparent textarea; text mode has no layer.
  const paint = () => { if (hl) { hl.innerHTML = hlJson(escapeHtml(ta.value)) + '\n'; hl.scrollTop = ta.scrollTop; hl.scrollLeft = ta.scrollLeft; } };
  ta.value = mode === 'json' ? bigStringify(cur, 2) : String(cur);
  paint(); cxAutoSize(ta);
  ta.addEventListener('input', () => { clearErr(); paint(); cxAutoSize(ta); });
  if (hl) ta.addEventListener('scroll', () => { hl.scrollTop = ta.scrollTop; hl.scrollLeft = ta.scrollLeft; });
  const fmt = cell.querySelector('.cx-fmt');
  // mousedown+preventDefault keeps textarea focus so its blur-commit doesn't race the click.
  if (fmt) fmt.addEventListener('mousedown', (ev) => {
    ev.preventDefault();
    try { ta.value = bigStringify(bigParse(ta.value), 2); clearErr(); paint(); cxAutoSize(ta); ta.focus(); }
    catch { ta.classList.add('bad'); msg.textContent = 'Not valid JSON yet'; msg.classList.add('bad'); }
  });
  cell.querySelector('.cx-done').addEventListener('mousedown', (ev) => { ev.preventDefault(); cxCommit(row, cell, ta, msg, mode); });
  // Clicking outside the cell (real blur) commits; guard the setTimeout against an already-collapsed cell.
  ta.addEventListener('blur', () => setTimeout(() => {
    if (cell.classList.contains('open') && !cell.contains(document.activeElement)) cxCommit(row, cell, ta, msg, mode);
  }, 0));
  ta.focus();
}

function wireFields(row) {
  const body = $('ovrBody'); if (!body) return;
  const filt = $('ovrFilter');
  if (filt) { filt.value = ovrFilter; filt.oninput = () => { ovrFilter = filt.value; applyFieldVisibility(); }; }
  const more = $('ovrMore');
  if (more) more.onclick = () => { ovrCapOpen = true; applyFieldVisibility(); };
  body.querySelectorAll('.ovr-inp').forEach((inp) => inp.addEventListener('change', () => {
    let v;
    try { v = bigParse(inp.value); } catch { inp.style.outline = '2px solid var(--danger)'; setGlobalMsg('Value must be valid JSON (e.g. 110, "text", [1,2]).', true); return; }
    inp.style.outline = '';
    layerMapRW(row, inp.dataset.layer)[inp.dataset.sel] = v;
    updateDirtyUi();
    setGlobalMsg('Unsaved change — press Save.', false);
  }));
  body.querySelectorAll('.ovr-rm').forEach((b) => b.addEventListener('click', () => {
    delete layerMapRW(row, b.dataset.layer)[b.dataset.sel];
    renderFilesNav(); renderEditor();
    setGlobalMsg('Override removed — press Save.', false);
  }));
  const addFrom = (elx) => addOverride(row, elx.dataset.sel, ovrLeafMap.has(elx.dataset.sel) ? ovrLeafMap.get(elx.dataset.sel) : null);
  body.querySelectorAll('.ovr-addctx').forEach((b) => b.addEventListener('click', () => addFrom(b)));
  body.querySelectorAll('.ovr-addv').forEach((v) => v.addEventListener('click', () => addFrom(v)));
  // Complex overrides render collapsed — click/Enter expands the formatted+highlighted editor.
  body.querySelectorAll('.cxcell:not(.scalar) > .cx-collapsed').forEach((el) => {
    const cell = el.closest('.cxcell');
    el.addEventListener('click', () => cxExpand(row, cell));
    el.addEventListener('keydown', (ev) => { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); cxExpand(row, cell); } });
  });
  // Scalar quick-format: parse the box; a complex result upgrades the row to the JSON editor,
  // a scalar is just canonicalised. Serves "paste an array into a former single value".
  body.querySelectorAll('.cxcell.scalar .cx-fmt').forEach((btn) => {
    const cell = btn.closest('.cxcell'); const inp = cell.querySelector('.ovr-inp');
    btn.addEventListener('click', () => {
      let v; try { v = bigParse(inp.value); }
      catch { inp.style.outline = '2px solid var(--danger)'; setGlobalMsg('Value must be valid JSON to format.', true); return; }
      inp.style.outline = '';
      layerMapRW(row, inp.dataset.layer)[inp.dataset.sel] = v;
      updateDirtyUi();
      if (cxMode(v)) { renderEditor(); setGlobalMsg('Expanded into a full editor — edit it, then Save.', false); }
      else { inp.value = jsonEnc(v); setGlobalMsg('Formatted — press Save.', false); }
    });
  });
  const addSel = $('ovrAddSel');
  if (addSel) addSel.onclick = () => {
    const sel = (window.prompt(row.kind === 'xml'
      ? "XPath selector (e.g. //var[@name='TimeHopping']/@value):"
      : 'Dotted key path (e.g. a.b.c):') || '').trim();
    if (sel) addOverride(row, sel, null);
  };
}
function addFileFlow() {
  const where = window.prompt('Override a file in:\n  1 = server dir (files/)\n  2 = a mission (mpmissions/)\nEnter 1 or 2:', '1');
  if (where === null) return;
  let key;
  if (where.trim() === '2') {
    const mission = (window.prompt('Mission layer — "common" (all missions) or a name like dayzOffline.sakhal:', 'common') || '').trim();
    if (!mission) return;
    const file = (window.prompt('File path within the mission (e.g. db/globals.xml):') || '').trim();
    if (!file) return;
    layerMapRW({ scope: 'mission', mission: mission === 'common' ? null : mission, fileKey: file }, mission === 'common' ? 'common' : 'mission');
    key = mission === 'common'
      ? (getActiveMission() ? 'mpmissions/' + getActiveMission() + '/' + file : 'common|' + file)
      : 'mpmissions/' + mission + '/' + file;
  } else {
    const file = (window.prompt('File path under the server dir (e.g. profiles/AIB_Unleashed/AIB_UL_Config.json):') || '').trim();
    if (!file) return;
    layerMapRW({ scope: 'files', fileKey: file }, 'files');
    key = file;
  }
  renderFilesNav();
  if (rowByKey(key)) selectRow(key);
  setGlobalMsg('File added — override its fields, then Save.', false);
}

async function saveOverrides() {
  const cred = loadCred();
  if (!cred) return;
  // Never ship a doc that was never loaded — that would replace the box manifest with
  // this session's empty/partial state (the exact accident of 2026-07-16).
  if (!overridesLoaded) { setGlobalMsg('config-overrides.json never loaded in this session — refusing to save. Reload the tab first.', true); return; }
  const save = $('ovrSave');
  const saveHtml = save ? save.innerHTML : '';
  if (save) { save.disabled = true; save.innerHTML = '<span class="wf-sp"></span>Saving…'; }
  setGlobalMsg('Saving…', false);
  try {
    let saved;
    try {
      saved = await apiPost('/dayz/configs/set-overrides', cred, { document: overridesDoc, baseVersion: ovrBaseVersion });
    } catch (err) {
      // Concurrent-edit conflict: another admin saved config-overrides.json since we loaded it.
      // Never clobber — offer to reload theirs (your unsaved edits here can be copied out first).
      if (err.status === 409 && /conflict|changed since/i.test(err.message || '')) {
        const ok = window.confirm('Another admin saved config-overrides.json since you opened it — saving now would overwrite their changes.\n\n' +
          'Reload their version? Your unsaved changes in this tab are discarded, so copy anything you need first (Cancel to do that).');
        if (ok) { Object.keys(fileCache).forEach((k) => delete fileCache[k]); await loadFiles(); }
        else setGlobalMsg('Save cancelled — reload before saving so you don’t overwrite the other admin.', true);
        return;
      }
      // Box shrink guard: the doc drops >half the current override values. Put the
      // decision to the human; only a deliberate confirm re-sends with the force flag.
      if (err.status === 409 && /shrink-guard/.test(err.message || '')) {
        const ok = window.confirm('The box refused this save:\n\n' + err.message +
          '\n\nThat usually means this tab is holding a PARTIAL document (stale session?). ' +
          'Only continue if you deliberately deleted these overrides.\n\nReplace anyway?');
        if (!ok) { setGlobalMsg('Save cancelled — the box kept its current config-overrides.json.', false); return; }
        saved = await apiPost('/dayz/configs/set-overrides', cred, { document: overridesDoc, baseVersion: ovrBaseVersion, confirmShrink: true });
      } else { throw err; }
    }
    // Rebase in place: the box just accepted THIS document and handed back its new hash — adopt
    // it so the tree refresh below gets 'unchanged' from the conditional pull instead of
    // re-downloading the whole doc we are already holding.
    if (saved && saved.version) ovrBaseVersion = saved.version;
    markClean();
    setGlobalMsg('Saved — restart the server to apply.', false, true);
    Object.keys(fileCache).forEach((k) => delete fileCache[k]);
    await loadFiles();
  } catch (err) {
    if (handle(err)) return;
    setGlobalMsg(err.status === 403 ? 'Your key can’t write — sign in with a full-scope key.' : 'Save failed: ' + err.message, true);
  } finally { if (save) { save.disabled = false; save.innerHTML = saveHtml; } }
}
async function loadVersions() {
  const cred = loadCred();
  if (!cred) return;
  try {
    const r = await apiPost('/dayz/configs/override-versions', cred);
    const versions = r.versions || [];
    el.ovrVersions.innerHTML = versions.length
      ? versions.map((v) => '<div class="ovr-ver"><span class="mono">' + escapeHtml(v) + '</span><span class="spacer"></span><button class="ghost ovr-roll" type="button" data-ver="' + attr(v) + '">Roll back</button></div>').join('')
      : '<span class="meta">No snapshots yet.</span>';
  } catch (err) { if (handle(err)) return; el.ovrVersions.innerHTML = '<span class="meta">Could not load versions.</span>'; }
}
async function rollbackTo(version) {
  const cred = loadCred();
  if (!cred) return;
  if (isDirty() && !window.confirm('You have unsaved override changes. Rolling back replaces the whole document and discards them.\n\nRoll back anyway?')) return;
  try {
    await apiPost('/dayz/configs/override-rollback', cred, { version });
    setGlobalMsg('Rolled back — restart to apply.', false, true);
    Object.keys(fileCache).forEach((k) => delete fileCache[k]);
    loadFiles();
  } catch (err) {
    if (handle(err)) return;
    setGlobalMsg(err.status === 403 ? 'Your key can’t roll back — full-scope key needed.' : 'Rollback failed: ' + err.message, true);
  }
}

// ===================== box-owned whole-file editor =====================
async function loadOwn(row) {
  el.ownPath.textContent = row.relpath || row.label;
  el.ownTa.value = 'Loading…';
  el.ownTa.disabled = true;
  try {
    const r = await apiPost('/dayz/configs/get?name=' + encodeURIComponent(row.name || row.writableName), loadCred());
    if (selKey !== row.key) return;
    el.ownTa.value = stripBom(r.content ?? '');
    el.ownTa.disabled = false;
  } catch (err) {
    if (handle(err)) return;
    el.ownTa.value = '';
    setGlobalMsg('Could not load ' + (row.label || '') + ': ' + err.message, true);
  }
}
async function saveOwnFile() {
  const cred = loadCred();
  const row = currentRow();
  if (!cred || !row || !row.writableName) return;
  el.ownSave.disabled = true;
  setGlobalMsg('Saving…', false);
  try {
    await apiPost('/dayz/configs/set-file', cred, { name: row.writableName, content: el.ownTa.value });
    setGlobalMsg('Saved — previous version snapshotted on the box.', false, true);
    Object.keys(fileCache).forEach((k) => delete fileCache[k]);
  } catch (err) {
    if (handle(err)) return;
    setGlobalMsg(err.status === 403 ? 'Your key can’t write — sign in with a full-scope key.' : 'Save failed: ' + err.message, true);
  } finally { el.ownSave.disabled = false; }
}

// The selected file key, so the shell can build #files/<key>.
export function getSelKey() { return selKey; }

export function initEditor() {

  el.filesNav.addEventListener('click', (e) => {
    const it = e.target.closest('.side-item'); if (!it || !it.dataset.key) return;
    if (it.dataset.key !== selKey) selectRow(it.dataset.key);
  });
  el.ownSave.addEventListener('click', () => saveOwnFile());
  el.ovrVersions.addEventListener('click', (e) => {
    const b = e.target.closest('button.ovr-roll'); if (!b) return;
    rollbackTo(b.dataset.ver);
  });
}
