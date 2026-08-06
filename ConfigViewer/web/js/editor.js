// editor.js — the Server Files tab: the merged file tree, and the routing from a selected row
// to its editor. Three destinations, no fourth:
//   owned   -> own-editor.js   (whole file, live beside its frozen default, configs/set-own)
//   types   -> types-editor.js (the CE types table, configs/set-own)
//   the rest-> a read-only file view
// Nothing in this module writes config-overrides.json - there is no such document.
import { $, el } from './dom.js';
import { setGlobalMsg, escapeHtml, attr, stripBom } from './ui.js';
import { apiPost } from './api-client.js';
import { loadCred, handle } from './auth.js';
import { detectLang, highlight } from './highlight.js';
import { getActiveMission, setActiveMission } from './state.js';
// CE types-table editor for registry web:'types' surfaces (the Expansion tuning pair) — its
// own VIEW over the shared save path (configs/set-own).
import { renderTypesEditor, typesAnyDirty, typesDirtyNames } from './types-editor.js';
import { renderOwnEditor, renderOwnCompare, ownAnyDirty, ownDirtyNames, ownSetPath } from './own-editor.js';
// Named-dirty: the header pill and the unload guard say WHICH files are unsaved.
import { formatUnsaved, confirmSave } from './dirty-files.js';

let shellHooks = { syncHash: () => {} };
export function setEditorHooks(h) { shellHooks = { ...shellHooks, ...h }; }

// #files/<key> deep-link target, consumed once the tree loads (set by the shell applyRoute).
let pendingFile = null;
export function setPendingFile(v) { pendingFile = v || null; }

// ===================== Server Files: state =====================
// activeMission -> js/state.js (shared: editor resolves 'common' against it, map defaults to it)
let configItems = [];     // /dayz/configs/list — now carries each file's relpath
let boxFiles = [];        // /dayz/configs/writable [{name, path}]
let roRe = [];            // /dayz/configs/readonly — compiled globs of generated (read-only) files
let disabledSet = new Set(); // /dayz/configs/disabled — relpaths whose owning mod is off in mods.conf; dropped from the tree
// /dayz/configs/owned `edited` — owned files the box has a captured .defaults baseline for, i.e.
// saved through the editor at least once. It is NOT a content comparison: a file saved back to
// identical bytes still has a baseline, so the tree marker says "edited here", never "differs".
let editedFiles = new Set();
let rows = [];            // the merged tree rows (buildRows)
let selKey = null;        // selected row key
let selMode = null;       // null | 'edit' | 'own'
let edView = 'file';      // which view a row shows: 'types' (the CE table) | 'file'
let lastFileText = null;  // last fetched whole-file text (for Copy)
const fileCache = {};

// Unsaved state now has exactly TWO owners - the owned editor and the types editor. This module
// holds none of its own: with the override document gone there is nothing here left to dirty.
export function isDirty() { return typesAnyDirty() || ownAnyDirty(); }
export function dirtyNames() { return [...typesDirtyNames(), ...ownDirtyNames()]; }
// ONE pill renderer for both chromes.
function dirtyPillText() { return formatUnsaved(dirtyNames()) || 'Unsaved changes'; }
export function dirtyPillHtml() {
  return '<span id="ovrDirty" class="ovr-unsaved' + (isDirty() ? ' on' : '') + '" title="' +
    attr(dirtyNames().join('\n')) + '"><span class="ud-dot"></span>' + escapeHtml(dirtyPillText()) + '</span>';
}
function updateDirtyUi() {
  const d = $('ovrDirty');
  if (!d) return;
  d.classList.toggle('on', isDirty());
  d.title = dirtyNames().join('\n');
  d.innerHTML = '<span class="ud-dot"></span>' + escapeHtml(dirtyPillText());
}

function kindOf(p) { const s = (p || '').toLowerCase(); return s.endsWith('.xml') ? 'xml' : s.endsWith('.json') ? 'json' : 'other'; }


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
// A surface whose owning mod is DISABLED in mods.conf (configs/disabled): dropped from the tree
// entirely, so a mod turned off there stops surfacing its config files and override-patch targets.
function isDisabledMod(rel) { return !!rel && disabledSet.has(rel); }
// A file the two-copy model owns whole. EDITABLE BY DEFAULT: any json/xml surface the box
// lists is own-editable unless an exception says no (view-locked, generated, map-owned,
// disabled, denied - denied paths never arrive here at all). Mirrors dayz-ctl's _own_check
// default; the box re-enforces everything on every read/write.
function isOwnedRel(rel) {
  return !!rel && /\.(json|xml)$/i.test(rel) && !/\.defaults\./.test(rel);
}
function buildRows(items, writable, mission) {
  const list = [];
  const byRel = new Map();
  const wByKey = new Map();
  for (const w of writable || []) { if (w && w.name) { wByKey.set(w.name, w); if (w.path) wByKey.set(w.path, w); } }
  for (const it of items || []) {
    const c = (typeof it === 'string') ? { group: 'General', name: it, label: it, path: it } : it;
    if (!c || !c.name) continue;
    const rel = c.path || c.name;
    if (byRel.has(rel)) continue;                     // first listing wins (alias before folder copy)
    const row = makeRow(rel, c.name, c.label || c.name, c.group || 'General');
    // about/aboutUrl come from the registry row via CONFIG_MAP -> config-list. Set here rather
    // than inside makeRow because this is the ONLY call site that has the API payload.
    // Absent = no block.
    row.about = (c.about || '').trim();
    row.aboutUrl = (c.aboutUrl || '').trim();
    const w = wByKey.get(c.name) || wByKey.get(rel) || null;
    // c.readonly = the registry's web:'view' surfaces (custom-ce types, mods.conf, messages.xml),
    // marked read-only by dayz-ctl's config-list. Locked like the Map-store, but its own copy so
    // the editor says "reference file" instead of "generated at boot".
    row.access = (MAP_STORE_SURFACES.has(c.name) || c.readonly) ? 'lock'   // Map-store or view-only: RO here
      : w ? 'own' : (row.kind === 'other' ? 'lock' : 'edit');
    if (c.readonly) row.readonly = true;
    // c.kind 'types' (registry web:'types') = a CE types file the types-table editor writes
    // via configs/set-own. access stays 'edit' but renderBody/typesChrome branch to the
    // types view; the standard Save-deltas chrome never renders for these rows.
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
  // Rows come only from the registry-backed listings; an undeclared file is a missing registry
  // row to fix, not a ghost row to click.
  // Final sweep: any row resolving to a GENERATED (compiler-output) file is locked read-only,
  // however it was created (curated listing or writable). This is the ONE place the generated
  // rule is enforced in the UI, so every code path above inherits it.
  for (const r of list) { if (isGenerated(r.relpath)) { r.access = 'lock'; r.generated = true; } }
  // AIPatrolSettings.json is MAP-OWNED - patrols and globals are edited on the Map tab
  // (direct-write, out of the override system). Read-only here so it is never override-patched
  // and the Patrols array is never dumped as a field blob.
  for (const r of list) { if (r.relpath && /(^|\/)mpmissions\/[^/]+\/expansion\/settings\/AIPatrolSettings\.json$/.test(r.relpath)) { r.access = 'lock'; r.mapOwned = true; } }
  // Two-copy routing: an owned surface edits WHOLE in the own-editor - being declared owned in
  // the registry is the whole test.
  for (const r of list) {
    if (r.access === 'edit' && !r.types && !r.generated && !r.mapOwned && !r.readonly
        && isOwnedRel(r.relpath)) r.ownFile = true;
  }
  // Final drop: any row whose owning mod is disabled in mods.conf is removed entirely — a turned-off
  // mod must not surface here. Done last so every path above is covered. The box-side files remain
  // on disk (reversible); re-enable the mod + redeploy the Api.
  return disabledSet.size ? list.filter((r) => !isDisabledMod(r.relpath)) : list;
}
// THE single answer to "can this row be written". The nav badge and the editor chrome both
// read it. Three write paths, ONE predicate. A fourth is added HERE, never beside a badge.
function canWrite(r) {
  if (!r) return false;
  return !!(r.ownFile             // owned whole-file editor (own-write)
    || r.types                    // CE types editor (own-write)
    || r.access === 'own');       // file-list writable surface - ban.txt / whitelist.txt
}

function rowByKey(k) { return rows.find((r) => r.key === k) || null; }
function currentRow() { return selKey ? rowByKey(selKey) : null; }

function renderFilesNav() {
  rows = buildRows(configItems, boxFiles, getActiveMission());
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
      // Every row states its access, always - no empty fallback. `access` is edit|view|lock,
      // not a boolean; rw means exactly what the panel will let you do (an owned whole-file
      // editor, or the types editor) - everything else is ro.
      const writable = canWrite(r);
      const badge = writable ? '<span class="own-badge">rw</span>' : '<span class="ro-badge">ro</span>';
      // Beside the NAME, never in the badge slot - a second element there would displace the
      // access badge.
      const edited = editedFiles.has(r.relpath)
        ? '<span class="edited-mark" title="edited here — saved through this editor at least once, so the box holds a frozen baseline for it">\u270e</span>'
        : '';
      return '<div class="side-item' + (r.key === selKey ? ' active' : '') + '" data-key="' + attr(r.key) + '" title="' + attr(r.relpath || r.label) + '">' +
        '<span class="fn">' + escapeHtml(r.file) + '</span>' + edited + badge + '</div>';
    };
    let inner = (bySub.get('') || []).map(rowHtml).join('');
    for (const sub of [...bySub.keys()].filter(Boolean).sort()) inner += '<div class="side-sub2">' + escapeHtml(sub) + '</div>' + bySub.get(sub).map(rowHtml).join('');
    const open = openState.has(g) ? openState.get(g) : (i === 0 || list.some((r) => r.key === selKey));
    html += '<details class="side-grp"' + (open ? ' open' : '') + ' data-g="' + attr(g) + '"><summary>' + escapeHtml(g) + '<span class="side-count">' + list.length + '</span></summary>' + inner + '</details>';
    i++;
  }
  if (!rows.length) html = '<span class="meta" style="padding:10px;display:block">No files exposed.</span>';
  el.filesNav.innerHTML = html;
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
  if (el.workspace) el.workspace.scrollTop = 0;   // fresh file: show the editor header + first fields, not wherever the last file was scrolled
  if (row.access === 'own') { el.editorPage.classList.remove('types-mode'); selMode = 'own'; renderFilesNav(); showFilesSurface(); loadOwn(row); return; }
  selMode = 'edit';
  // EDIT is the default view for every OWNED surface, XML included. server-settings.json is the
  // ONE exception, and it is not an exception to the rule - it is a different KIND of surface:
  // not a file the game reads, but the INPUT set Apply-ServerCfg turns into serverDZ.cfg (itself
  // a read-only generated artifact). It is a GENERATOR INPUT - the UI edits the inputs, never
  // the generated output - so its purpose-built form stays rather than whole-file editing, which
  // would let an admin type keys the renderer's allowlist silently drops.
  // A locked row has nothing to edit, so it falls back to the read-only file view.
  edView = row.types ? 'types'
    : (row.access === 'lock' || row.kind === 'other') ? 'file'
    : 'edit';
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
    const [cfgR, boxR, roR, disR, ownR] = await Promise.all([
      apiPost('/dayz/configs/list', cred),
      apiPost('/dayz/configs/writable', cred).catch(() => ({ files: [] })),
      apiPost('/dayz/configs/readonly', cred).catch(() => ({ files: [] })),   // generated (read-only) globs; [] on an older API
      apiPost('/dayz/configs/disabled', cred).catch(() => ({ files: [] })),   // disabled-mod relpaths to drop; [] on an older API
      apiPost('/dayz/configs/owned', cred).catch(() => ({ files: [], dirs: [] })),   // owned-surface masks; empty on an older API = no rows route to the whole-file editor
    ]);
    configItems = cfgR.configs || [];
    boxFiles = boxR.files || [];
    roRe = (roR.files || []).map(globToRe);
    disabledSet = new Set(disR.files || []);
    editedFiles = new Set(ownR.edited || []);   // absent on an older API = no marks, never a wrong mark
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
}

// ===================== whole-file fetching =====================
// XML files written by the box (XmlDocument.Save) carry a UTF-8 BOM; as a JS string
// that's a leading U+FEFF, which breaks JSON.parse and can confuse DOMParser.
// stripBom -> js/ui.js (shared with the map's JSON loads).
// A row's content comes from its curated read alias. Every registry row carries a read alias
// (asserted by the registry contract test), so a row without one is a declaration bug, not a
// path to route around.
async function fetchRowFile(row) {
  const ck = 'f|' + row.key;
  if (fileCache[ck]) return fileCache[ck];
  const cred = loadCred();
  if (!cred) return { text: null, err: 'not signed in' };
  try {
    let r;
    if (row.name) r = await apiPost('/dayz/configs/get?name=' + encodeURIComponent(row.name), cred);
    else return { text: null, err: 'this row has no read alias - its registry entry is incomplete' };
    return (fileCache[ck] = { text: stripBom(r.content ?? ''), path: r.path || row.relpath });
  } catch (err) {
    if (err.status === 401) { handle(err); return { text: null, err: 'signed out' }; }
    // 404 = the path is allowlisted but nothing is there. Saying "not readable" reads like a
    // permission fault; the usual cause is a file its mod only writes at runtime.
    return { text: null, err: err.status === 404 ? 'ABSENT' : err.message };
  }
}

// ===================== the Fields ⇄ File editor =====================
// Chrome for a types row: its own segment pair (the types editor owns Save/Discard in its own
// toolbar; this chrome only carries the view switcher and Copy).
function typesChrome(row) {
  return '<div class="ovr-phead">' +
    '<div class="ovr-ppath"><span class="crumb">files/</span><span class="nm">' + escapeHtml(row.fileKey || row.label) + '</span></div>' +
    '<div class="ovr-pact">' +
      dirtyPillHtml() +
      '<div class="seg" id="ovrSeg"><button data-v="types" class="' + (edView === 'types' ? 'on' : '') + '">Types editor</button><button data-v="file" class="' + (edView === 'file' ? 'on' : '') + '">View file</button></div>' +
      '<button class="btn-sm" id="ovrCopy" type="button">Copy</button>' +
    '</div></div>' +
    aboutBlock(row) +
    '<div class="ovr-sum"><span class="stat d"><span class="dot d"></span>web-edited CE types override layer — each entry fully replaces the same-named upstream type</span>' +
    '<span class="stat" style="margin-left:auto">Restart to apply</span></div>';
}
// "About this file" - the registry's plain-English description, rendered UNDER the filename with
// a citation link. ONE helper for every chrome (types / owned / read-only) so the block can
// never drift between surface types. Empty string when the row has no about text, so a surface
// without one renders exactly as before. The href is http(s)-only by the time it reaches here:
// Deploy-Api throws on a non-http aboutUrl and the Api re-validates it on the way out.
function aboutBlock(row) {
  if (!row || !row.about) return '';
  const link = row.aboutUrl
    ? '<a class="about-src" href="' + attr(row.aboutUrl) + '" target="_blank" rel="noopener noreferrer">source</a>'
    : '';
  return '<div class="ovr-about"><span class="about-lbl">About</span>' +
    '<span class="about-txt">' + escapeHtml(row.about) + '</span>' + link + '</div>';
}
function ownChrome(row) {
  return '<div class="ovr-phead">' +
    '<div class="ovr-ppath"><span class="crumb">' + escapeHtml(row.scope === 'mission' ? 'mpmissions · ' + (row.mission || '') + '/' : 'files/') + '</span><span class="nm">' + escapeHtml(row.fileKey || row.label) + '</span></div>' +
    '<div class="ovr-pact">' +
      dirtyPillHtml() +
      // Editing and comparing are different jobs, so they are different views - the same segment
      // switcher every other row uses. Comparing is never the landing view.
      '<div class="seg" id="ovrSeg"><button data-v="edit" class="' + (edView === 'edit' ? 'on' : '') + '">Editor</button>' +
      '<button data-v="compare" class="' + (edView === 'compare' ? 'on' : '') + '">Compare with default</button></div>' +
      '<button class="btn-sm" id="ovrCopy" type="button">Copy</button>' +
    '</div></div>' +
    aboutBlock(row) +
    '<div class="ovr-sum"><span class="stat d"><span class="dot d"></span>' +
    (edView === 'compare'
      ? 'live file beside the frozen default — read-only; the box never applies a diff'
      : 'owned file — edited whole, saved whole') + '</span>' +
    '<span class="stat" style="margin-left:auto">Restart to apply</span></div>';
}
// A read-only row (registry reference/browse surfaces): filename, About, and the file itself.
// No save path, because nothing here is writable - the owned and types editors own every write.
function viewChrome(row) {
  const crumb = row.scope === 'files' ? 'files/' : ('mpmissions \u00b7 ' + (row.mission || 'all missions') + '/');
  return '<div class="ovr-phead">' +
    '<div class="ovr-ppath"><span class="crumb">' + escapeHtml(crumb) + '</span><span class="nm">' + escapeHtml(row.fileKey || row.label) + '</span></div>' +
    '<div class="ovr-pact">' + dirtyPillHtml() + '<button class="btn-sm" id="ovrCopy" type="button">Copy</button></div>' +
    '</div>' + aboutBlock(row) +
    '<div class="ovr-sum"><span class="stat"><span class="dot b"></span>' +
    (row.generated ? 'generated file — built at boot from its declared inputs; edit those, not this'
                   : 'read-only reference file — shipped with the deploy; view only') +
    '</span></div>';
}
async function renderEditor() {
  const row = currentRow();
  if (!row || row.access === 'own') return;
  const chrome = row.ownFile ? ownChrome(row) : row.types ? typesChrome(row) : viewChrome(row);
  el.edEditor.innerHTML = chrome + '<div class="ovr-body" id="ovrBody"></div>';
  const seg = $('ovrSeg');
  if (seg) seg.onclick = (e) => { const b = e.target.closest('button'); if (!b) return; edView = b.dataset.v; renderEditor(); };
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
  // Owned rows: the whole-file two-copy editor (own-editor.js) - its own load/save path.
  if (row.ownFile && edView === 'compare') {
    el.editorPage.classList.remove('types-mode');
    const text = await renderOwnCompare(row, body);
    if (text != null && selKey === row.key) lastFileText = text;
    return;
  }
  if (row.ownFile) {
    el.editorPage.classList.remove('types-mode');
    const text = await renderOwnEditor(row, body, {
      onDirty: updateDirtyUi,
      onSaved: () => { delete fileCache['f|' + row.key]; },
    });
    if (text != null && selKey === row.key) lastFileText = text;
    // The generator-input driver keeps its context panel ABOVE the document - the numbers it
    // reports are the file's own, so it can only ever agree with what is on screen.
    if (isCycleRow(row) && text != null) {
      let doc = null; try { doc = JSON.parse(stripBom(text)); } catch { /* unparseable: skip the panel, the editor still works */ }
      if (doc) { body.insertAdjacentHTML('afterbegin', cycleHtml(doc)); wireCycle(row); }
    }
    return;
  }
  const typesTable = !!row.types && edView !== 'file';
  el.editorPage.classList.toggle('types-mode', typesTable);
  // Types rows: the table editor is its own view with its own load/save (types-editor.js).
  // The 'file' segment still falls through to the read-only whole-file view below.
  if (typesTable) {
    body.innerHTML = '<span class="meta" style="padding:16px;display:block">Loading types\u2026</span>';
    const text = await renderTypesEditor(row, body, {
      onDirty: updateDirtyUi,
      onSaved: () => { delete fileCache['f|' + row.key]; },   // the File view refetches the saved doc
    });
    if (text != null && selKey === row.key) lastFileText = text;   // feed the Copy button
    return;
  }
  // Everything else is READ-ONLY: a row is either owned (handled above), types (handled above),
  // or a reference/generated file only displayed here. There is no third editable state.
  body.innerHTML = '<span class="meta" style="padding:16px;display:block">Loading file\u2026</span>';
  const file = await fetchRowFile(row);
  if (selKey !== row.key) return;                    // selection changed while awaiting
  lastFileText = file.text;
  if (file.text === null) { body.innerHTML = '<div class="ovr-note">' + escapeHtml(fileMissingNote(file)) + '</div>'; return; }
  if (row.mapOwned) {
    body.innerHTML = '<div class="ovr-note"><b>Edited on the Map tab.</b> Patrols are edited individually on the map (click a patrol \u2192 Edit fields); the map-wide defaults via the map\'s <b>Global settings</b>. This file is read-only here so a raw edit can\'t break spawns.</div>'
      + '<div class="fileview"><pre>' + highlight(file.text, detectLang(row.relpath || row.label)) + '</pre></div>';
    return;
  }
  body.innerHTML = '<div class="fileview"><pre>' + highlight(file.text, detectLang(row.relpath || row.label)) + '</pre></div>';
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
// The day/night cycle editor. The sliders drive the SAME document the editor below holds, via
// the navigator's setValue.
function cycleHtml(doc) {
  const num = (k, d) => { const n = Number(doc && doc[k]); return (isFinite(n) && n > 0) ? n : d; };
  const x = num(CYCLE_X, 5), y = num(CYCLE_Y, 4);
  const ctl = (sel, label, val, min, max, step, hint) =>
    '<div class="cyc-ctl"><label for="cyc-' + sel + '">' + escapeHtml(label) + '</label>'
    + '<div class="cyc-row">'
    + '<input type="range" id="cyc-' + sel + '" class="cyc-in" data-sel="' + attr(sel) + '" min="' + min + '" max="' + max + '" step="' + step + '" value="' + val + '">'
    + '<input type="number" class="cyc-num" data-sel="' + attr(sel) + '" min="' + min + '" max="' + max + '" step="' + step + '" value="' + val + '">'
    + '</div><span class="cyc-hint">' + escapeHtml(hint) + '</span></div>';
  return '<div class="cyc" id="cycPanel">'
    + '<h4>Day / night cycle</h4>'
    + '<p class="cyc-sub">What these two multipliers buy in real time, assuming ' + CYCLE_DAYLIGHT + 'h of in-game daylight. Moving a slider edits the document below - press Save, then restart to apply.</p>'
    + '<div class="cyc-grid">'
    + ctl(CYCLE_X, 'Time acceleration (X)', x, 1, 24, 0.5, 'Scales in-game time overall. Higher = shorter days.')
    + ctl(CYCLE_Y, 'Night acceleration (Y)', y, 1, 24, 0.5, 'Multiplies again during night only. Higher = shorter nights.')
    + '</div>'
    + '<div class="cyc-out" id="cycOut">' + cycleOutHtml(x, y) + '</div>'
    + '<div class="cyc-foot"><span class="cyc-note">Applies at the next restart - Apply-ServerCfg compiles serverDZ.cfg from this file at prestart. Map selection is unaffected (that is map.env).</span></div>'
    + '</div>';
}
// Wire the sliders to whichever editor currently holds the document: the owned whole-file editor
// when the file is owned, else the whole-file edit view. One write path, no parallel store.
function wireCycle(row) {
  const panel = $('cycPanel'); if (!panel) return;
  const out = $('cycOut');
  const readAll = () => {
    const g = (sel) => Number(panel.querySelector('.cyc-in[data-sel="' + sel + '"]').value);
    return { x: g(CYCLE_X), y: g(CYCLE_Y) };
  };
  const redraw = () => { const v = readAll(); if (out) out.innerHTML = cycleOutHtml(v.x, v.y); };
  const commit = async (sel, valStr) => {
    const n = Number(valStr);
    if (!isFinite(n) || n <= 0) { setGlobalMsg('Acceleration must be a positive number.', true); return; }
    // One document, one write path: the slider edits whichever side is holding it. ownSetPath
    // moves the gold box to the structured side if it is not already there, warning first if
    // that costs the admin their raw formatting - the same prompt as clicking the pane.
    if (!(await ownSetPath(row.key, [sel], n))) {
      setGlobalMsg('The document is not in a state the sliders can edit - fix the raw text first.', true);
      return;
    }
    updateDirtyUi();
    setGlobalMsg('Unsaved change - press Save.', false);
  };
  panel.querySelectorAll('.cyc-in').forEach((sld) => {
    const num = panel.querySelector('.cyc-num[data-sel="' + sld.dataset.sel + '"]');
    sld.addEventListener('input', () => { if (num) num.value = sld.value; redraw(); });
    sld.addEventListener('change', () => commit(sld.dataset.sel, sld.value));
  });
  panel.querySelectorAll('.cyc-num').forEach((n) => {
    const sld = panel.querySelector('.cyc-in[data-sel="' + n.dataset.sel + '"]');
    n.addEventListener('input', () => { if (sld) sld.value = n.value; redraw(); });
    n.addEventListener('change', () => commit(n.dataset.sel, n.value));
  });
}
// One wording for a file the box could not hand back, used by every surface that shows it.
function fileMissingNote(file) {
  if (file && file.err === 'ABSENT') return 'This file is not on the box yet. Nothing has created it - a mod that writes its config on first run has not run, or it has never been generated. It is allowlisted, so it will appear here once it exists.';
  return 'Whole-file view unavailable - ' + (file && file.err ? file.err : 'unknown') + '.';
}


// ---- boxed-value editor: expand a summary into a formatted+highlighted JSON box
//      (objects/arrays) or a plain full-text box (long strings), collapse on commit ----
const CX_TEXT_MIN = 80;   // strings longer than this (or multiline) get the text box, not a cramped input



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
  // Name the file before writing, like every other save path.
  if (!confirmSave([row.writableName])) return;
  el.ownSave.disabled = true;
  setGlobalMsg('Saving…', false);
  try {
    // These .txt lists go through the ONE generic write path (set-own) like every other owned
    // file; set-own takes the ServerDir-relative PATH.
    await apiPost('/dayz/configs/set-own', cred, { path: row.relpath || row.writableName, content: el.ownTa.value });
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
}
