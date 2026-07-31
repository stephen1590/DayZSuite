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
// The SAME structured editor the Map tab uses (mountJsonEditor) and the same object-oriented
// navigator layout the server-files Edit view has always used - one editor, not a per-file one-off.
// It replaces only the WIDGET; the save path stays whole-file `configs/set-own`. That is the
// difference from the old wf-json mount, which fed the override-delta flow being deleted (A3).
import { mountJsonNavigator } from './json-editor-ui.js';
import { confirmSave } from './dirty-files.js';           // E4: name the files before saving
import { bigParse, restoreBigInts } from './lossless-json.js';

// Big-int-safe encode, identical to editor.js jsonEnc: the sentinel round-trips so a 17-digit
// Steam64 in a config never degrades to a float.
function jsonEnc(v) { return restoreBigInts(JSON.stringify(v)); }

// Above this combined size the unified diff is skipped - see the size guard in renderOwnEditor.
const DIFF_MAX_CHARS = 400_000;
let CMp = null;                                   // the 445KB vendor bundle loads on FIRST use only
function loadCM() { CMp ??= import('../vendor/codemirror/cm6.esm.js'); return CMp; }

// Per-row state, kept across file switches (same in-memory-survival contract as the other
// editors): key -> { path, version, baseText, defText, draft, view }
const states = new Map();

export function ownAnyDirty() {
  for (const st of states.values()) if (st.draft != null && st.draft !== st.baseText) return true;
  return false;
}

// E4: WHICH owned files are dirty, by name - the shell pill and the save dialog
// both need names, not a boolean. See js/dirty-files.js.
// The live JSON handle for a row, so a purpose-built control (the day/night sliders) can edit the
// SAME document the editor holds rather than keeping its own copy. null when the row is not
// mounted as structured JSON (raw-text/CM6 surfaces).
export function ownJsonHandle(key) {
  const st = states.get(key);
  return (st && st.json) ? st.json : null;
}

export function ownDirtyNames() {
  const out = [];
  for (const st of states.values()) if (st.draft != null && st.draft !== st.baseText) out.push(st.path);
  return out;
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
    draft: null, view: null, json: null,
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
    if (st.json) { try { st.json.destroy(); } catch (_) {} st.json = null; renderOwnEditor({ key: st.key, relpath: st.path }, body, hooks); return; }
    if (st.view) st.view.dispatch({ changes: { from: 0, to: st.view.state.doc.length, insert: st.baseText } });
    else { const ta = body.querySelector('#ownTa'); if (ta) ta.value = st.baseText; }
    refreshBar(st, body, hooks);
    setGlobalMsg('Edits discarded.', false, true);
  };
}

// The document text, from whichever editor actually mounted: CodeMirror normally, or the plain
// textarea fallback when CM6 failed to start. Without this, Save silently no-ops on the fallback.
function currentText(st, body) {
  if (st.json) return jsonEnc(st.json.getDoc());     // structured navigator (JSON files)
  if (st.view) return st.view.state.doc.toString();  // CodeMirror (XML, or JSON that failed to parse)
  const ta = body.querySelector('#ownTa');
  return ta ? ta.value : null;
}

async function doSave(st, body, hooks) {
  const cred = loadCred();
  if (!cred) return;
  const content0 = currentText(st, body);
  if (content0 === null) return;
  if (!confirmSave([st.path])) return;                    // E4: name the file before writing
  const save = body.querySelector('#ownSave');
  if (save) { save.disabled = true; save.textContent = 'Saving…'; }
  try {
    const content = content0;
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
  // JSON -> the object-oriented navigator (same component as the Map tab and the old Edit view).
  // XML falls through to CodeMirror below: json-editor has no XML model, so a syntax editor is
  // the honest answer there rather than inventing a second structured widget.
  if (!st.path.endsWith('.xml')) {
    let startval;
    try { startval = bigParse(st.draft ?? st.baseText); } catch { startval = undefined; }
    if (startval !== undefined) {
      // .wf-json is the navigator's own host class (the Edit view used it too) - .own-cm is
      // styled for CodeMirror and would clip the split panes.
      body.innerHTML = '<div id="ownHead">' + toolbarHtml(st) + '</div><div class="wf-json" id="ownJson"></div>';
      const host = body.querySelector('#ownJson');
      try {
        const h = await mountJsonNavigator(host, {
          doc: startval,
          onChange: () => {
            const was = isDirtySt(st);
            st.draft = jsonEnc(h ? h.getDoc() : startval);
            if (isDirtySt(st) !== was) refreshBar(st, body, hooks);
          },
        });
        st.json = h;
        st.view = null;
        wireBar(st, body, hooks);
        return st.baseText;
      } catch (err) {
        // fall through to CodeMirror rather than leaving a blank pane
        setGlobalMsg('Structured editor unavailable (' + (err && err.message ? err.message : err) + ') — using the syntax editor.', true);
      }
    }
    // startval === undefined: the file does not parse as JSON. A syntax editor is the only way
    // to FIX that, so CodeMirror below is the correct fallback, not a failure.
  }
  body.innerHTML = '<div id="ownHead">' + toolbarHtml(st) + '</div><div class="own-cm" id="ownCm"></div>';
  try {
  const lang = st.path.endsWith('.xml') ? CM.xml() : CM.json();
  // Token colors = the app's OWN t-* palette (style.css), on the app's always-dark code
  // surface (--pre-bg) - the same look as the File view and log panes, in BOTH themes.
  // Class-mapped so style.css stays the single owner of the colors.
  const appHighlight = CM.HighlightStyle.define([
    { tag: CM.tags.propertyName, class: 't-key' },
    { tag: CM.tags.attributeName, class: 't-key' },
    { tag: [CM.tags.string, CM.tags.attributeValue], class: 't-str' },
    { tag: CM.tags.number, class: 't-num' },
    { tag: [CM.tags.bool, CM.tags.null, CM.tags.keyword], class: 't-kw' },
    { tag: CM.tags.comment, class: 't-com' },
    { tag: CM.tags.tagName, class: 't-tag' },
  ]);
  const exts = [
    CM.basicSetup, lang, CM.syntaxHighlighting(appHighlight),
    CM.EditorView.updateListener.of((u) => {
      if (!u.docChanged) return;
      const was = isDirtySt(st);
      st.draft = u.state.doc.toString();
      if (isDirtySt(st) !== was) refreshBar(st, body, hooks);
    }),
  ];
  // The unified diff gutter vs the frozen default — display-only (the box never applies diffs).
  // SIZE GUARD: the merge view diffs the whole document against the whole default, so cost is
  // ~2x the file. db/types.xml is 886 KB and mapgroupproto.xml 1.5 MB; running the diff on those
  // locks the tab. Above the cap the file is still fully editable, just without the diff gutter.
  const bigDoc = (st.baseText.length + (st.defText ? st.defText.length : 0)) > DIFF_MAX_CHARS;
  if (st.defText != null && !bigDoc) exts.push(CM.unifiedMergeView({ original: st.defText, mergeControls: false }));
  st.view = new CM.EditorView({
    doc: st.draft ?? st.baseText,
    extensions: exts,
    parent: body.querySelector('#ownCm'),
  });
  if (bigDoc) {
    const n = body.querySelector('#ownHead .meta');
    if (n) n.textContent = 'whole document — diff vs the frozen default is off for files this large (' + Math.round(st.baseText.length / 1024) + ' KB)';
  }
  wireBar(st, body, hooks);
  return st.baseText;
  } catch (err) {
    // Never leave a half-built body behind: a CM6 mount failure used to render the toolbar and
    // an empty container, which reads as a blank page. Fall back to a plain textarea - it is
    // still a working whole-file editor on the same own-write path, just without highlighting.
    body.innerHTML = '<div id="ownHead">' + toolbarHtml(st) + '</div>' +
      '<div class="ovr-note">Syntax editor failed to start (' + escapeHtml(err && err.message ? err.message : String(err)) +
      '). Falling back to a plain text editor — saving still works.</div>' +
      '<textarea class="own-ta" id="ownTa" spellcheck="false" autocomplete="off" wrap="off"></textarea>';
    const ta = body.querySelector('#ownTa');
    ta.value = st.draft ?? st.baseText;
    ta.addEventListener('input', () => {
      const was = isDirtySt(st);
      st.draft = ta.value;
      if (isDirtySt(st) !== was) refreshBar(st, body, hooks);
    });
    wireBar(st, body, hooks);
    return st.baseText;
  }
}
