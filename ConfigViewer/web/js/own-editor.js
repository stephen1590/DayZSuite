// own-editor.js — the whole-file two-copy editor for category-'owned' surfaces
// The LIVE file is edited in place as TEXT (CodeMirror 6,
// JSON/XML syntax by extension); the frozen DEFAULT (<stem>.defaults.<ext>, reachable via the
// same configs/own read since it sits under the owned dir) is the read-only reference shown as
// a unified diff — the diff is DISPLAY, never something the box applies. Save ships the whole
// document via configs/set-own: the box validates the parse, snapshots the outgoing version,
// and enforces base= optimistic concurrency (409 = another admin saved first).
//
// Editing bytes (not parsed values) deliberately sidesteps the lossless-json round-trip: the
// box only checks the document PARSES; every byte the admin typed is what lands.
//
// BOTH EDITING MODES, SIDE BY SIDE. A JSON surface shows two panes over ONE document: the
// structured navigator on the LEFT, the raw text on the RIGHT.
//   - RAW IS THE DEFAULT and owns the edit. The side that owns it wears the gold box.
//   - The other side is a PROJECTION, never a second copy. It is inert, so there is never a moment
//     where two widgets both think they hold the file.
//   - A projection is COMMITTED, not followed. It is allowed to fall behind, it SAYS it has fallen
//     behind, and its own button brings it up to date - either direction, never on a debounce,
//     since rebuilding a widget while the admin is still typing breaks mid-edit.
//   - Clicking the projection asks for the document (that IS a commit, plus the gold box moves).
//     If the owning side has diverged since it was projected, that re-formats their text, so it
//     warns first - two-pane.js owns that rule and the wording.
//   - If the raw text does not parse, the structured side CANNOT be built from it. It says where
//     it fails and offers to jump there. The stale tree is removed rather than left sitting
//     beside text that no longer produces it, and not one byte of the raw buffer is touched.
// XML keeps a single raw pane: json-editor has no XML model, so there is no second side to show.
import { escapeHtml, setGlobalMsg } from './ui.js';
import { apiPost } from './api-client.js';
import { canWrite } from './access.js';
import { loadCred, handle } from './auth.js';
// The SAME structured editor the Map tab uses (mountJsonEditor) and the same object-oriented
// navigator layout the server-files Edit view has always used - one editor, not a per-file one-off.
// It replaces only the WIDGET; the save path stays whole-file `configs/set-own`.
import { mountJsonNavigator } from './json-editor-ui.js';
import { confirmSave, jsonEquivalent } from './dirty-files.js';   // name the files before saving; compare data not bytes
import { bigParse, restoreBigInts } from './lossless-json.js';
import { RAW, STRUCTURED, parseFailure, switchIntent, isDocDirty, projectionStatus, detectIndent, canonicalJson } from './two-pane.js';

// Big-int-safe encode: the sentinel round-trips so a 17-digit Steam64 in a config never degrades
// to a float. The INDENT is the document's own (detectIndent), never a house style - writing a
// file back must not reformat it.
function jsonEnc(v, indent) { return restoreBigInts(JSON.stringify(v, null, indent || '  ')); }

// Comparing against the frozen default is a SEPARATE VIEW (renderOwnCompare below), never part
// of the editor: an inline diff would re-diff the whole document on every keystroke, and on a
// genuinely diverged file that reads as noise, not signal.
// NO SIZE CAP AND NO DEBOUNCE - the other side updates only when it is TOLD to, at any file size.
let CMp = null;                                   // the 445KB vendor bundle loads on FIRST use only
function loadCM() { CMp ??= import('../vendor/codemirror/cm6.esm.js'); return CMp; }

// Per-row state, kept across file switches (same in-memory-survival contract as the other
// editors): key -> { path, version, baseText, defText, draft, view, json, side, projText, ... }
const states = new Map();

export function ownAnyDirty() {
  for (const st of states.values()) if (isDirtySt(st)) return true;
  return false;
}

export function ownDirtyNames() {
  const out = [];
  for (const st of states.values()) if (isDirtySt(st)) out.push(st.path);
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
    draft: null, view: null, json: null, dirty: false,
    indent: detectIndent(live.content ?? ''),   // write it back the way we found it
    // The compare view opens VALUES-first: byte-for-byte would report an entire re-indented
    // file as changed and say nothing useful. Raw bytes is one click away and still the
    // on-disk truth.
    cmpNormalise: true,
    // Two-pane state. The raw side starts with the document by default.
    side: RAW,
    projText: null,      // the owning side's text when it took the document - divergence is measured from here
    projSrc: null,       // the text the structured projection was last built from
    rawEdited: false,    // has the admin typed in the RAW pane since the last projection?
    projecting: false,   // a projection is writing into an editor - not a user edit
    projSeq: 0,          // guards against a slow projection landing after a newer one
    docVersion: 0,       // bumped on every edit; compared with mirrorVersion to label the projection
    mirrorVersion: null, // the docVersion the OTHER side was last built from - null = never
    body: null, hooks: null, cm: null, editable: null,
  };
  states.set(row.key, st);
  return st;
}

const isXml = (st) => st.path.endsWith('.xml');

// The structured navigator re-serialises the document, so its draft can never be byte-identical
// to the box's file even with zero edits. The rule (and the raw-side exception, where the bytes
// ARE the document) lives in two-pane.js so every two-pane editor answers this the same way.
// Dirty is CACHED, never recomputed per keystroke - it is asked only at the moments the answer
// can change (first edit, save, discard, commit, switch), because answering it per keypress
// means serialising the document and scanning both copies on every character typed.
function isDirtySt(st) { return !!st.dirty; }

// Ask the rule. Materialises the document once - only call this on a transition.
function recomputeDirty(st) {
  const text = st.body ? currentText(st, st.body) : st.draft;
  st.draft = text;
  st.dirty = isDocDirty(text, st.baseText, { isJson: !isXml(st), rawEdited: st.rawEdited });
  return st.dirty;
}

function toolbarHtml(st) {
  const dirty = isDirtySt(st);
  return '<div class="own-bar">' +
    '<span class="tag cx">owned file</span>' +
    '<span class="meta">' + (st.defText != null
      ? 'whole document — use the Compare view to see it against the frozen default'
      : 'whole document — no frozen default captured') + '</span>' +
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
    st.draft = null; st.rawEdited = false; st.dirty = false; st.side = RAW; st.projText = null; st.projSrc = null;
    if (st.json) { try { st.json.destroy(); } catch (_) {} st.json = null; }
    renderOwnEditor({ key: st.key, relpath: st.path }, body, hooks);
    setGlobalMsg('Edits discarded.', false, true);
  };
}

// The document text, from whichever side OWNS it. Ownership decides, not which widget happens to
// be mounted: both sides may be mounted at once, and asking the projection would save the stale
// copy.
function currentText(st, body) {
  if (st.side === STRUCTURED && st.json) return jsonEnc(st.json.getDoc(), st.indent);
  if (st.view) return st.view.state.doc.toString();  // CodeMirror (raw side, XML, or a fallback)
  const scope = body || st.body;
  const ta = scope ? scope.querySelector('#ownTa') : null;
  return ta ? ta.value : null;
}

async function doSave(st, body, hooks) {
  const cred = loadCred();
  if (!cred) return;
  const content0 = currentText(st, body);
  if (content0 === null) return;
  if (!confirmSave([st.path])) return;                    // name the file before writing
  const save = body.querySelector('#ownSave');
  if (save) { save.disabled = true; save.textContent = 'Saving…'; }
  try {
    const content = content0;
    const r = await apiPost('/dayz/configs/set-own', cred, { path: st.path, content, baseVersion: st.version });
    st.version = r.version || null;
    st.baseText = content;
    st.draft = null;
    st.rawEdited = false;
    st.dirty = false;
    st.projText = content;
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

// ============================================================ the two sides

function paneHtml(side, title, hint, inner) {
  return '<section class="tp-pane" data-side="' + side + '">' +
    '<header class="tp-head"><span class="tp-name">' + title + '</span>' +
    '<span class="tp-role"></span><span class="spacer"></span>' +
    '<button type="button" class="btn-sm tp-commit" hidden></button>' +
    '<span class="tp-hint">' + hint + '</span></header>' +
    inner + '</section>';
}

// Gold box on the side that holds the document; the other side is made inert so it cannot be
// typed into by accident - the click still lands, on the pane, which is how you ask for the
// document. (Raw stays a live CodeMirror while projecting, just not editable, so its text can
// still be selected and copied.)
function applySide(st) {
  const body = st.body; if (!body) return;
  body.querySelectorAll('.tp-pane').forEach((pane) => {
    const owns = pane.dataset.side === st.side;
    pane.classList.toggle('tp-own', owns);
    pane.classList.toggle('tp-proj', !owns);
    const hint = pane.querySelector('.tp-hint');
    if (hint) hint.textContent = owns ? 'this side holds the document' : 'click to edit on this side';
  });
  refreshPaneState(st);            // ONE owner for the role text and the commit button
  const jsonHost = body.querySelector('#ownJson');
  if (jsonHost) jsonHost.inert = st.side !== STRUCTURED;
  // Reconfigure only on a real change of side: this runs after every projection, and dispatching
  // into CodeMirror while someone is typing in it is not free.
  const editable = st.side === RAW;
  if (st.view && st.editable && st.editableOn !== editable) {
    st.editableOn = editable;
    st.view.dispatch({ effects: st.editable.reconfigure(st.cm.EditorView.editable.of(editable)) });
  }
}

function failHtml(f) {
  return '<div class="tp-fail">' +
    '<b>The raw text does not parse as JSON</b>' +
    '<div class="tp-where">line ' + f.line + ', column ' + f.col +
    ' <button type="button" class="btn-sm" id="tpJump">Show me</button></div>' +
    '<pre class="tp-src">' + escapeHtml(f.source) + '\n' + escapeHtml(f.caret) + '</pre>' +
    '<div class="tp-msg">' + escapeHtml(f.message) + '</div>' +
    '<p class="meta">Your text is held exactly as you typed it — nothing has been discarded. ' +
    'The structured view comes back on its own once the document parses.</p>' +
    '</div>';
}

function showFail(st, f) {
  const host = st.body && st.body.querySelector('#ownJson');
  if (!host) return;
  if (st.json) { try { st.json.destroy(); } catch (_) {} st.json = null; }
  st.projSrc = null;
  host.classList.remove('jn-wrap');
  host.innerHTML = failHtml(f);
  const jump = host.querySelector('#tpJump');
  if (jump) jump.onclick = (e) => {
    e.stopPropagation();                         // jumping is not a request for the document
    if (!st.view) return;
    st.view.focus();
    st.view.dispatch({ selection: { anchor: Math.min(f.pos, st.view.state.doc.length) }, scrollIntoView: true });
  };
}

function showNote(st, html) {
  const host = st.body && st.body.querySelector('#ownJson');
  if (!host) return;
  if (st.json) { try { st.json.destroy(); } catch (_) {} st.json = null; }
  st.projSrc = null;
  host.classList.remove('jn-wrap');
  host.innerHTML = '<div class="tp-note">' + html + '</div>';
}

// Build the structured side from `text`. Only ever runs because someone asked for it: a commit,
// a switch of sides, or the first mount.
async function projectStructured(st, text) {
  const host = st.body && st.body.querySelector('#ownJson');
  if (!host) return false;
  const f = parseFailure(text);
  if (f) { showFail(st, f); return false; }
  // Same data, different bytes: the tree on screen is already a correct projection of this text,
  // so rebuilding it would throw away the reader's place for nothing.
  if (st.json && st.projSrc != null && jsonEquivalent(text, st.projSrc)) return true;

  const seq = ++st.projSeq;
  let doc;
  try { doc = bigParse(text); } catch (err) { showFail(st, parseFailure(text) || { line: 1, col: 1, pos: 0, message: String(err && err.message || err), source: '', caret: '^' }); return false; }
  if (st.json) { try { st.json.destroy(); } catch (_) {} st.json = null; }
  host.innerHTML = '';
  try {
    const h = await mountJsonNavigator(host, {
      doc,
      // Only the OWNING side writes. While this pane is a projection it is inert, but json-editor
      // also fires onChange once on mount - and letting that land would have the projection
      // overwrite the draft of the side that actually holds the document.
      // Per keystroke in the structured side, same contract as the raw one: no serialising.
      // Reaching here at all means a real edit - the mount-time fire is filtered by st.json being
      // null until the handle is assigned.
      onChange: () => {
        if (st.side !== STRUCTURED || !st.json) return;
        if (!st.dirty) { st.dirty = true; refreshBar(st, st.body, st.hooks); }
        markChanged(st);                         // the raw side falls behind and says so; Update commits it
      },
    });
    if (seq !== st.projSeq) { try { h.destroy(); } catch (_) {} return false; }   // a newer projection won
    st.json = h;
    st.projSrc = text;
    applySide(st);
    return true;
  } catch (err) {
    showNote(st, 'Structured view unavailable — ' + escapeHtml(err && err.message ? err.message : String(err)) +
      '<br>The raw text on the right is unaffected.');
    return false;
  }
}

// Write the document into the RAW pane. Only ever a projection of the side that owns it, so the
// edit is flagged as such: the update listener must not read it back as the admin typing.
function mirrorToRaw(st, text) {
  if (!st.view || text == null) return;
  if (st.view.state.doc.toString() === text) return;
  st.projecting = true;
  st.view.dispatch({ changes: { from: 0, to: st.view.state.doc.length, insert: text } });
  st.projecting = false;
  st.projSrc = text;
}

// Catch the projection up with the document, ON DEMAND, in whichever direction the gold box points.
// This is the commit: it is the only thing that moves the document across, and it is never on a
// timer. Ownership does not change - that is the pane click.
async function commitTo(st, side) {
  if (isXml(st) || side === st.side) return false;
  const cur = currentText(st, st.body);
  if (cur == null) return false;
  const ok = side === STRUCTURED ? await projectStructured(st, cur) : (mirrorToRaw(st, cur), true);
  if (ok) { st.mirrorVersion = st.docVersion; refreshPaneState(st); }
  return ok;
}

// Cheap, per keystroke: bump a counter and re-label the other pane. No parse, no serialise, no
// rebuild - the whole point is that typing costs nothing but typing.
function markChanged(st) {
  st.docVersion++;
  refreshPaneState(st);
}

// The projection pane says whether it still matches the document, and carries the button that
// makes it match. Versions, not text: asking "has it changed" by serialising the structured side
// on every keystroke would cost the same as the rebuild being avoided.
function refreshPaneState(st) {
  const body = st.body; if (!body) return;
  const s = projectionStatus(st.docVersion, st.mirrorVersion);
  body.querySelectorAll('.tp-pane').forEach((pane) => {
    const owns = pane.dataset.side === st.side;
    const role = pane.querySelector('.tp-role');
    if (role) role.textContent = owns ? 'editing' : 'projection · ' + s.label;
    if (role) role.classList.toggle('tp-stale', !owns && s.stale);
    const btn = pane.querySelector('.tp-commit');
    if (btn) {
      btn.hidden = owns;
      btn.disabled = !s.stale;
      btn.textContent = pane.dataset.side === STRUCTURED ? '⟵ Sync to this side' : 'Sync to this side ⟶';
    }
  });
}

// Hand the document to the other side. Returns true when the switch happened.
async function switchTo(st, to) {
  if (!st.body || st.side === to) return true;
  const cur = currentText(st, st.body);
  if (cur == null) return false;
  const intent = switchIntent(to, { current: cur, projected: st.projText ?? cur });
  if (!intent.ok) {
    if (intent.failure) showFail(st, intent.failure);
    setGlobalMsg(intent.message.split('\n')[0], true);
    return false;
  }
  if (intent.needsConfirm && !window.confirm(intent.message)) return false;

  if (to === STRUCTURED) {
    st.side = STRUCTURED;
    // Focus resets to the root: the navigator mounts only the node you are on, and holding a
    // position across a whole-file raw edit would point into a document that no longer exists.
    const ok = await projectStructured(st, cur);
    if (!ok) { st.side = RAW; applySide(st); return false; }
  } else {
    st.side = RAW;
    mirrorToRaw(st, cur);
    st.rawEdited = false;                        // their byte-level edits went with the re-projection
  }
  recomputeDirty(st);                 // the switch re-formatted the document; ask the rule once, here
  st.projText = st.draft;
  st.mirrorVersion = st.docVersion;   // the side that just took the document IS the document
  applySide(st);
  refreshBar(st, st.body, st.hooks);
  return true;
}

// Give a purpose-built control (the day/night sliders) a way to edit the SAME document, whichever
// side is holding it. It takes the structured side first - through the same switch, with the same
// warning - because that is where a path/value write is expressible. A handle to a pane that
// may only be a projection is a way to write into a copy.
export async function ownSetPath(key, path, value) {
  const st = states.get(key);
  if (!st || !st.body) return false;
  if (st.side !== STRUCTURED && !(await switchTo(st, STRUCTURED))) return false;
  if (!st.json || !st.json.setValue) return false;
  st.json.setValue(path, value);
  return true;
}

// ============================================================ mounting

// Language + token colours: the app's OWN t-* palette (style.css) on the always-dark code surface,
// class-mapped so style.css stays the single owner of the colours. ONE definition, used by the
// editor AND the compare view - a second copy is how two surfaces end up looking different.
function syntaxExts(st, CM) {
  const lang = isXml(st) ? CM.xml() : CM.json();
  const appHighlight = CM.HighlightStyle.define([
    { tag: CM.tags.propertyName, class: 't-key' },
    { tag: CM.tags.attributeName, class: 't-key' },
    { tag: [CM.tags.string, CM.tags.attributeValue], class: 't-str' },
    { tag: CM.tags.number, class: 't-num' },
    { tag: [CM.tags.bool, CM.tags.null, CM.tags.keyword], class: 't-kw' },
    { tag: CM.tags.comment, class: 't-com' },
    { tag: CM.tags.tagName, class: 't-tag' },
  ]);
  return [lang, CM.syntaxHighlighting(appHighlight)];
}

function mountRaw(st, CM, host) {
  st.cm = CM;
  st.editable = new CM.Compartment();
  const exts = [
    CM.basicSetup, ...syntaxExts(st, CM),
    st.editable.of(CM.EditorView.editable.of(true)),
    // EVERYTHING in here runs on every keypress, so it does O(1) work and nothing else.
    CM.EditorView.updateListener.of((u) => {
      if (!u.docChanged || st.projecting) return;
      st.rawEdited = true;                       // typed here: the bytes are the admin's, not a re-serialisation
      if (!st.dirty) { st.dirty = true; refreshBar(st, st.body, st.hooks); }   // clean -> dirty, once
      if (!isXml(st)) markChanged(st);
    }),
  ];
  st.view = new CM.EditorView({ doc: st.draft ?? st.baseText, extensions: exts, parent: host });
  st.editableOn = true;                          // matches the compartment's initial value on THIS view
}

// Entry point (called by editor.js renderBody for row.ownFile rows).
// Returns the loaded live text so the caller can feed Copy / lastFileText.
export async function renderOwnEditor(row, body, hooks) {
  const prev = states.get(row.key);
  if (prev) captureDraft(prev);                  // re-entry must never re-mount from a stale draft
  body.innerHTML = '<span class="meta" style="padding:16px;display:block">Loading file…</span>';
  let st, CM;
  try { [st, CM] = await Promise.all([loadState(row), loadCM()]); }
  catch (err) {
    if (handle(err)) return null;
    body.innerHTML = '<div class="ovr-note">Owned-file editor unavailable — ' + escapeHtml(err.message) + '</div>';
    return null;
  }
  st.body = body; st.hooks = hooks;
  // The body is about to be replaced wholesale - tear the old widgets down rather than orphaning
  // them with their listeners still attached to detached DOM.
  if (st.view) { try { st.view.destroy(); } catch (_) {} st.view = null; }
  if (st.json) { try { st.json.destroy(); } catch (_) {} st.json = null; }

  const text = st.draft ?? st.baseText;
  // XML: one pane. json-editor has no XML model, so a syntax editor is the honest answer there
  // rather than inventing a second structured widget beside it.
  if (isXml(st)) {
    body.innerHTML = '<div id="ownHead">' + toolbarHtml(st) + '</div><div class="own-cm" id="ownCm"></div>';
    st.side = RAW;
    try { mountRaw(st, CM, body.querySelector('#ownCm')); }
    catch (err) { return fallbackTextarea(st, body, hooks, err); }
    st.projText = text;
    wireBar(st, body, hooks);
    return st.baseText;
  }

  body.innerHTML = '<div id="ownHead">' + toolbarHtml(st) + '</div>' +
    '<div class="tp-split" id="ownSplit">' +
    paneHtml(STRUCTURED, 'Structured', '', '<div class="wf-json" id="ownJson"></div>') +
    paneHtml(RAW, 'Raw text', '', '<div class="own-cm" id="ownCm"></div>') +
    '</div>';
  try { mountRaw(st, CM, body.querySelector('#ownCm')); }
  catch (err) { return fallbackTextarea(st, body, hooks, err); }
  st.projText = text;
  // Asking for the document by clicking the pane that does not have it - the ONE gesture that
  // moves the gold box, and the one the divergence warning hangs off.
  body.querySelectorAll('.tp-pane').forEach((pane) => {
    pane.addEventListener('click', () => {
      const side = pane.dataset.side;
      if (side !== st.side) switchTo(st, side);
    });
    // Commit is NOT a change of ownership: it brings this pane up to date with the document and
    // leaves the gold box where it is. Stops the click, or asking to look would hand the file over.
    const btn = pane.querySelector('.tp-commit');
    if (btn) btn.addEventListener('click', (e) => { e.stopPropagation(); commitTo(st, pane.dataset.side); });
  });
  // NOT BUILT AT OPEN. json-editor constructs every node eagerly (see the big-file note in
  // json-editor-ui.js), so building the structured side here would make every owned file pay a
  // thousands-of-widgets construction cost before the raw editor could be typed in. Raw owns the
  // document by default, so raw is the only side that has to exist by default; the left side
  // builds when it is asked for, like any other commit.
  st.side = RAW;
  st.mirrorVersion = null;                       // never projected -> the pane reads "out of date"
  showNote(st, 'The structured view is built on demand, so opening a file stays instant.<br>' +
    'Press <b>Sync to this side</b> when you are ready, or click this pane to edit here.');
  applySide(st);
  wireBar(st, body, hooks);
  return st.baseText;
}

// Take the document out of the live widgets and into st.draft. This MUST happen before anything
// tears the editor down - leaving a view for the Compare view and coming back would otherwise
// re-mount from a stale draft and silently discard what the admin typed.
function captureDraft(st) {
  if (!st.body) return;
  const t = currentText(st, st.body);
  if (t != null) st.draft = t;
}

// ============================================================ the Compare view
// A VIEW of its own, per file, reached by the segment switcher - never part of the editor. The
// editor edits; this one only shows.
//
// Side by side, not a unified gutter: on a file that has genuinely diverged from its captured
// baseline the unified form opens on a wall of red and tells you nothing. Unchanged regions are
// COLLAPSED, so what you land on is the changes themselves.
// Read-only on both sides on purpose - this is display, and the box never applies a diff.
export async function renderOwnCompare(row, body) {
  const prev = states.get(row.key);
  if (prev) captureDraft(prev);                  // BEFORE the body goes - unsaved edits live in the widget
  body.innerHTML = '<span class="meta" style="padding:16px;display:block">Loading both copies…</span>';
  let st, CM;
  try { [st, CM] = await Promise.all([loadState(row), loadCM()]); }
  catch (err) {
    if (handle(err)) return null;
    body.innerHTML = '<div class="ovr-note">Compare unavailable — ' + escapeHtml(err.message) + '</div>';
    return null;
  }
  if (st.defText == null) {
    // A file nobody can edit here never gets a baseline captured, so say that instead of
    // pointing at a save that is not on offer.
    body.innerHTML = '<div class="ovr-note">No frozen default exists for this file, so there is nothing to compare against. ' +
      (canWrite(row)
        ? 'The box captures one from the current bytes the first time the file is saved through the editor.'
        : 'Baselines are captured on the first save, and this file is not editable here.') + '</div>';
    return st.baseText;
  }
  // The LIVE side is whatever the editor currently holds, unsaved edits included - comparing the
  // saved copy while the admin has unsaved work in the editor would answer a question nobody asked.
  let live = st.draft ?? st.baseText;
  let def = st.defText;
  const dirty = isDirtySt(st);
  // FORMATTING-BLIND compare (values, not bytes) by default: re-serialising both sides
  // identically shows what actually changed regardless of indent style. Off = the bytes as they
  // are on disk, which is the truth and sometimes the thing you need.
  if (st.cmpNormalise && !isXml(st)) {
    const a = canonicalJson(live, st.indent), b = canonicalJson(def, st.indent);
    if (a != null && b != null) { live = a; def = b; }
  }
  body.innerHTML = '<div class="cmp-head">' +
    '<span class="tag cx">compare</span>' +
    '<span class="meta">left: <b>live file</b>' + (dirty ? ' (including your unsaved edits)' : '') +
    ' — right: <b>frozen default</b>, the bytes captured before the first edit. Read-only: this is a view, and the box never applies a diff.</span>' +
    '<span class="meta cmp-mode">' + (isXml(st) ? 'comparing bytes'
      : st.cmpNormalise ? 'comparing <b>values</b> — indentation and spacing ignored'
      : 'comparing <b>raw bytes</b> — formatting counts as a difference') + '</span>' +
    '<span class="spacer"></span>' +
    (isXml(st) ? '' : '<button type="button" class="btn-sm" id="cmpNorm">' +
      (st.cmpNormalise ? 'Show raw bytes' : 'Ignore formatting') + '</button>') +
    '</div><div class="cmp-split" id="ownCmp"></div>';
  const norm = body.querySelector('#cmpNorm');
  if (norm) norm.onclick = () => { st.cmpNormalise = !st.cmpNormalise; renderOwnCompare(row, body); };
  try {
    // Same highlighting as the editor, plus line numbers - you are reading two copies against
    // each other, so the line you are on has to be nameable. Read-only on both sides.
    const ro = [...syntaxExts(st, CM), CM.lineNumbers(),
      CM.EditorView.editable.of(false), CM.EditorState.readOnly.of(true)];
    new CM.MergeView({
      a: { doc: live, extensions: ro },
      b: { doc: def, extensions: ro },
      parent: body.querySelector('#ownCmp'),
      // Identical stretches collapse to a click-to-expand strip: the point is to land ON the
      // differences, not to scroll past a thousand matching lines to find them.
      collapseUnchanged: { margin: 3, minSize: 8 },
      // Display-only, stated rather than inherited: a revert arrow between chunks would make this
      // view a write path, and the two-copy model says the box never applies a diff.
      revertControls: false,
      // CodeMirror stops scanning for matches after 500 lines by default and then aligns coarsely,
      // which on a real config reads as "the change detection is wrong". Give it room, and a
      // millisecond budget so a pathological file degrades instead of hanging the tab.
      diffConfig: { scanLimit: 20_000, timeout: 5_000 },
    });
  } catch (err) {
    body.innerHTML += '<div class="ovr-note">Side-by-side view failed to start (' +
      escapeHtml(err && err.message ? err.message : String(err)) + '). The editor is unaffected.</div>';
  }
  return st.baseText;
}

// Never leave a half-built body behind on a CM6 mount failure - a bare toolbar over an empty
// container reads as a blank page. Fall back to a plain textarea - it is still a working
// whole-file editor on the same own-write path, just without highlighting.
function fallbackTextarea(st, body, hooks, err) {
  st.view = null; st.json = null; st.side = RAW;
  body.innerHTML = '<div id="ownHead">' + toolbarHtml(st) + '</div>' +
    '<div class="ovr-note">Syntax editor failed to start (' + escapeHtml(err && err.message ? err.message : String(err)) +
    '). Falling back to a plain text editor — saving still works.</div>' +
    '<textarea class="own-ta" id="ownTa" spellcheck="false" autocomplete="off" wrap="off"></textarea>';
  const ta = body.querySelector('#ownTa');
  ta.value = st.draft ?? st.baseText;
  st.projText = ta.value;
  ta.addEventListener('input', () => {
    const was = isDirtySt(st);
    st.draft = ta.value;
    st.rawEdited = true;
    if (isDirtySt(st) !== was) refreshBar(st, body, hooks);
  });
  wireBar(st, body, hooks);
  return st.baseText;
}
