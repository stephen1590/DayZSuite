// own-editor.js — the whole-file two-copy editor for category-'owned' surfaces
// (CONFIG-ARCHITECTURE.md Phase 1). The LIVE file is edited in place as TEXT (CodeMirror 6,
// JSON/XML syntax by extension); the frozen DEFAULT (<stem>.defaults.<ext>, reachable via the
// same configs/own read since it sits under the owned dir) is the read-only reference shown as
// a unified diff — the diff is DISPLAY, never something the box applies. Save ships the whole
// document via configs/set-own: the box validates the parse, snapshots the outgoing version,
// and enforces base= optimistic concurrency (409 = another admin saved first).
//
// Editing bytes (not parsed values) deliberately sidesteps the lossless-json round-trip: the
// box only checks the document PARSES; every byte the admin typed is what lands.
import { escapeHtml, setGlobalMsg } from './ui.js';
import { apiPost } from './api-client.js';
import { loadCred, handle } from './auth.js';

let CMp = null;                                   // the 445KB vendor bundle loads on FIRST use only
function loadCM() { CMp ??= import('../vendor/codemirror/cm6.esm.js'); return CMp; }

// Per-row state, kept across file switches (same in-memory-survival contract as the other
// editors): key -> { path, version, baseText, defText, draft, view }
const states = new Map();

export function ownAnyDirty() {
  for (const st of states.values()) if (st.draft != null && st.draft !== st.baseText) return true;
  return false;
}

function defaultsPathOf(rel) {
  const i = rel.lastIndexOf('.');
  return i > 0 ? rel.slice(0, i) + '.defaults' + rel.slice(i) : rel + '.defaults';
}

async function loadState(row) {
  const have = states.get(row.key);
  if (have && have.loaded) return have;
  const cred = loadCred();
  if (!cred) throw new Error('not signed in');
  const [live, def] = await Promise.all([
    apiPost('/dayz/configs/own?path=' + encodeURIComponent(row.relpath), cred),
    apiPost('/dayz/configs/own?path=' + encodeURIComponent(defaultsPathOf(row.relpath)), cred)
      .catch(() => null),                          // no frozen default captured = plain editor, no diff
  ]);
  const st = {
    key: row.key, path: row.relpath, loaded: true,
    version: live.version || null,
    baseText: live.content ?? '',
    defText: def && typeof def.content === 'string' ? def.content : null,
    draft: null, view: null,
  };
  states.set(row.key, st);
  return st;
}

function isDirtySt(st) { return st.draft != null && st.draft !== st.baseText; }

function toolbarHtml(st) {
  const dirty = isDirtySt(st);
  return '<div class="own-bar">' +
    '<span class="tag cx">owned file</span>' +
    '<span class="meta">' + (st.defText != null
      ? 'whole document — the gutter marks changes vs the frozen default'
      : 'whole document — no frozen default captured, plain edit') + '</span>' +
    '<span class="spacer"></span>' +
    (dirty ? '<button type="button" class="btn-sm" id="ownDiscard">Discard</button>' : '') +
    '<button type="button" class="btn-sm primary" id="ownSave"' + (dirty ? '' : ' disabled') + '>Save file</button>' +
    '</div>' +
    '<div class="ty-note ovr-note">Saves the <b>whole file</b> to the box (parse-validated, previous version snapshotted, concurrent edits rejected) — no override delta. <b>Restart to apply.</b></div>';
}

function refreshBar(st, body, hooks) {
  const bar = body.querySelector('#ownHead');
  if (bar) { bar.innerHTML = toolbarHtml(st); wireBar(st, body, hooks); }
  if (hooks && hooks.onDirty) hooks.onDirty();
}

function wireBar(st, body, hooks) {
  const save = body.querySelector('#ownSave');
  if (save) save.onclick = () => doSave(st, body, hooks);
  const disc = body.querySelector('#ownDiscard');
  if (disc) disc.onclick = () => {
    if (!window.confirm('Discard your unsaved edits to this file?')) return;
    st.draft = null;
    if (st.view) st.view.dispatch({ changes: { from: 0, to: st.view.state.doc.length, insert: st.baseText } });
    refreshBar(st, body, hooks);
    setGlobalMsg('Edits discarded.', false, true);
  };
}

async function doSave(st, body, hooks) {
  const cred = loadCred();
  if (!cred || !st.view) return;
  const save = body.querySelector('#ownSave');
  if (save) { save.disabled = true; save.textContent = 'Saving…'; }
  try {
    const content = st.view.state.doc.toString();
    const r = await apiPost('/dayz/configs/set-own', cred, { path: st.path, content, baseVersion: st.version });
    st.version = r.version || null;
    st.baseText = content;
    st.draft = null;
    refreshBar(st, body, hooks);
    if (hooks && hooks.onSaved) hooks.onSaved();
    setGlobalMsg('Saved — previous version snapshotted on the box. Restart the server to apply.', false, true);
  } catch (err) {
    if (handle(err)) return;
    if (err.status === 409) {
      const ok = window.confirm('Another admin saved this file since you opened it.\n\nReload their version? Your edits here are discarded (Cancel to copy them out first).');
      if (ok) { states.delete(st.key); renderOwnEditor({ key: st.key, relpath: st.path }, body, hooks); }
      else setGlobalMsg('Save cancelled — reload before saving so you don\'t overwrite the other admin.', true);
      return;
    }
    setGlobalMsg(err.status === 400 ? 'The box refused the document: ' + err.message
      : err.status === 403 ? 'Your key can\'t write — sign in with a full-scope key.'
      : 'Save failed: ' + err.message, true);
  } finally {
    const s = body.querySelector('#ownSave');
    if (s && s.textContent === 'Saving…') { s.disabled = false; s.textContent = 'Save file'; }
  }
}

// Entry point (called by editor.js renderBody for row.ownFile rows).
// Returns the loaded live text so the caller can feed Copy / lastFileText.
export async function renderOwnEditor(row, body, hooks) {
  body.innerHTML = '<span class="meta" style="padding:16px;display:block">Loading file…</span>';
  let st, CM;
  try { [st, CM] = await Promise.all([loadState(row), loadCM()]); }
  catch (err) {
    if (handle(err)) return null;
    body.innerHTML = '<div class="ovr-note">Owned-file editor unavailable — ' + escapeHtml(err.message) + '</div>';
    return null;
  }
  body.innerHTML = '<div id="ownHead">' + toolbarHtml(st) + '</div><div class="own-cm" id="ownCm"></div>';
  const lang = st.path.endsWith('.xml') ? CM.xml() : CM.json();
  const exts = [
    CM.basicSetup, lang,
    CM.EditorView.updateListener.of((u) => {
      if (!u.docChanged) return;
      const was = isDirtySt(st);
      st.draft = u.state.doc.toString();
      if (isDirtySt(st) !== was) refreshBar(st, body, hooks);
    }),
  ];
  // The unified diff gutter vs the frozen default — display-only (the box never applies diffs).
  if (st.defText != null) exts.push(CM.unifiedMergeView({ original: st.defText, mergeControls: false }));
  st.view = new CM.EditorView({
    doc: st.draft ?? st.baseText,
    extensions: exts,
    parent: body.querySelector('#ownCm'),
  });
  wireBar(st, body, hooks);
  return st.baseText;
}
