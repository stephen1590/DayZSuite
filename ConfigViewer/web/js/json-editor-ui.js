// json-editor-ui.js — reusable themed wrapper around the vendored @json-editor/json-editor.
// One call mounts a fully-themed, drift-tolerant JSON editor into any element:
//   const h = await mountJsonEditor(host, { schema, startval, onChange });
// Pairs with ../jsoneditor-theme.css (the .je-mount / .je-pathbar visual theme). The ~537 KB lib
// is lazy-loaded on first use, so a page that never mounts an editor never pays for it. No global
// IDs are used, so several editors can coexist on one page.
//
// Everything below the constructor is DOM glue derived from the markup json-editor emits under
// theme 'html' with iconlib null. It restyles STRUCTURE, never the data: lifts each array item's
// delete/move controls up into its title row, titles array items "Key [i/N]" (never an inferred
// schema name), flags schema-unknown (drift) nodes, badges array length / null, and drives the
// path calculator. DayZ/Expansion owns the model - unknown nodes must survive, so nothing here
// assumes a closed schema.

const LIB_SRC = 'vendor/jsoneditor-2.17.1.min.js';   // resolved against the document, not this module
let libPromise = null;

function ensureLib(src) {
  if (window.JSONEditor) return Promise.resolve(window.JSONEditor);
  if (libPromise) return libPromise;
  libPromise = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src || LIB_SRC;
    s.onload = () => (window.JSONEditor ? resolve(window.JSONEditor) : reject(new Error('JSONEditor global missing after load')));
    s.onerror = () => reject(new Error('failed to load ' + s.src));
    document.head.appendChild(s);
  });
  return libPromise;
}

const titleRow = (elh) => elh.querySelector(':scope > .je-object__title, :scope > .je-header');
const nameSpanOf = (row) => row && row.querySelector(':scope > span:not([class])');
const IX = /\.(\d+)$/;
const safeVal = (ed) => { try { return ed.getValue(); } catch (_) { return undefined; } };

// Caret direction is authoritative from json-editor's own collapsed flag, not a guessed toggle.
function syncCarets(ed) {
  Object.values(ed.editors || {}).forEach((e) => { if (e && e.toggle_button) e.toggle_button.dataset.state = e.collapsed ? 'Expand' : 'Collapse'; });
}
// Collapse empty/null collapsibles once, so a fresh open isn't a wall of empty panels.
function minimizeEmpties(ed) {
  Object.values(ed.editors || {}).forEach((e) => {
    if (!e || !e.toggle_button || e.collapsed) return;
    let v; try { v = e.getValue(); } catch (_) { return; }
    if ((Array.isArray(v) && !v.length) || v === null || v === undefined) e.toggle_button.click();
  });
}

// Runs after each render (ready + change). `root` is the .je-mount element.
function decorate(root, ed) {
  // 1) lift each array item's bottom control span (delete/move) up into its title row
  root.querySelectorAll('.json-editor-btntype-move[data-i], .json-editor-btntype-delete[data-i]').forEach((btn) => {
    const ctl = btn.parentElement; if (!ctl || ctl.classList.contains('je-lifted')) return;
    const item = btn.closest('[data-schemapath]'); const row = titleRow(item);
    if (row) { ctl.classList.add('je-lifted'); row.appendChild(ctl); }
  });
  // 2) per-node: positional title for array items, green object-"+" by the name, status badge
  root.querySelectorAll('[data-schemapath]').forEach((node) => {
    const row = titleRow(node); if (!row) return;
    const name = nameSpanOf(row); const path = node.getAttribute('data-schemapath');
    const m = path.match(IX);
    if (m && name) {                       // array item -> "ParentKey [i+1/N]" (no inferred schema name)
      const idx = +m[1], parentPath = path.replace(IX, ''), key = parentPath.split('.').pop();
      let n = '?'; try { const pe = ed.getEditor(parentPath); const v = pe && pe.getValue(); if (Array.isArray(v)) n = v.length; } catch (_) {}
      const want = key + ' [' + (idx + 1) + '/' + n + ']';
      if (name.textContent !== want) name.textContent = want;
    }
    // object "add property" button -> lifted out of the sibling .je-object__controls span and
    // placed right after the name, green (distinct from the array "add item" +). Its click
    // handler + modal are JS-referenced by the lib, so relocating the element keeps them working.
    const props = node.querySelector(':scope > .je-object__controls .json-editor-btntype-properties, :scope > .je-header .json-editor-btntype-properties');
    if (props && name && props.previousElementSibling !== name) { props.classList.add('je-props'); name.after(props); }
    // status after the name
    let v; try { const e = ed.getEditor(path); v = e ? e.getValue() : undefined; } catch (_) { v = undefined; }
    let txt = '';
    if (Array.isArray(v)) txt = v.length ? '[' + v.length + ']' : '[ ] (null)';
    else if (v === null || v === undefined) txt = 'null';
    row.classList.toggle('je-empty', txt.indexOf('null') > -1);   // null/empty -> dimmed gold
    let badge = row.querySelector(':scope > .je-status');
    if (txt && name) { if (!badge) { badge = document.createElement('span'); badge.className = 'je-status'; name.after(badge); } badge.textContent = txt; badge.classList.toggle('je-null', txt.indexOf('null') > -1); }
    else if (badge) badge.remove();
  });
  // 3) tooltips from the hidden label text; caret comes from json-editor's own collapsed flag
  root.querySelectorAll('button[class*="json-editor-btn"]').forEach((b) => { const t = (b.textContent || '').trim(); if (t && !b.getAttribute('title')) b.setAttribute('title', t); });
  syncCarets(ed);
}

// Path calculator: the data-schemapath of the focused field as breadcrumbs + a depth count, plus
// a copy button that yields a paste-ready dot path (leading "root" dropped). Wired to `root`.
function buildPathbar(root) {
  const bar = document.createElement('div'); bar.className = 'je-pathbar';
  const trail = document.createElement('span'); trail.className = 'je-trail';
  trail.innerHTML = '<span class="jp-empty">select a field to see its path</span>';
  const copy = document.createElement('button'); copy.type = 'button'; copy.className = 'jp-copy';
  copy.title = 'Copy this data path'; copy.textContent = 'copy'; copy.disabled = true;
  bar.append(trail, copy);
  let current = '';
  const show = (target) => {
    const n = target && target.closest && target.closest('[data-schemapath]'); if (!n) return;
    const segs = n.getAttribute('data-schemapath').replace(/\]/g, '').split(/[.\[]/).filter(Boolean);
    current = segs.slice(1).join('.');     // drop 'root' -> a paste-ready data path
    copy.disabled = !current;
    trail.innerHTML = segs.map((s, i) => '<span class="jp-seg' + (i === segs.length - 1 ? ' jp-cur' : '') + '">' + s.replace(/[<>&]/g, '') + '</span>').join('<span class="jp-sep">›</span>') + '<span class="jp-depth">depth ' + (segs.length - 1) + '</span>';
  };
  root.addEventListener('focusin', (e) => show(e.target));
  root.addEventListener('click', (e) => show(e.target));
  copy.addEventListener('click', () => {
    if (!current) return;
    const done = () => { copy.classList.add('ok'); const o = copy.textContent; copy.textContent = '✓ copied'; setTimeout(() => { copy.classList.remove('ok'); copy.textContent = o; }, 1100); };
    const fallback = () => { const ta = document.createElement('textarea'); ta.value = current; ta.style.position = 'fixed'; ta.style.opacity = '0'; document.body.appendChild(ta); ta.select(); try { document.execCommand('copy'); } catch (_) {} ta.remove(); done(); };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(current).then(done, fallback);
    else fallback();
  });
  return bar;
}

// Mount a themed editor into `host`. Returns a handle once the lib is loaded and the editor wired.
//   opts: { schema, startval, onChange(value), pathbar=true, density='inline'|'stacked',
//           minimizeEmpty=true, theme='html', libSrc, editorOptions }
// handle: { editor, getValue(), on(evt,fn), setDensity(d), destroy() }
export async function mountJsonEditor(host, opts = {}) {
  const {
    schema, startval, theme = 'html', pathbar = true, density = 'inline',
    minimizeEmpty = true, onChange, libSrc, editorOptions = {},
  } = opts;
  const JE = await ensureLib(libSrc);
  host.innerHTML = '';
  const mount = document.createElement('div');
  mount.className = density === 'stacked' ? 'je-mount je-stacked' : 'je-mount';
  if (pathbar) host.appendChild(buildPathbar(mount));   // path bar above the editor, wired to the mount
  host.appendChild(mount);

  const ed = new JE(mount, {
    schema, startval, theme, iconlib: null, disable_edit_json: true, disable_collapse: false,
    collapsed: false, show_errors: 'never', prompt_before_delete: false, object_layout: 'normal',
    ...editorOptions,
  });
  const fire = () => { if (onChange) onChange(safeVal(ed)); };
  ed.on('ready', () => { if (minimizeEmpty) minimizeEmpties(ed); decorate(mount, ed); fire(); });
  ed.on('change', () => { decorate(mount, ed); fire(); });
  mount.addEventListener('click', (e) => { if (e.target.closest('.json-editor-btntype-toggle')) requestAnimationFrame(() => syncCarets(ed)); });

  return {
    editor: ed,
    getValue: () => safeVal(ed),
    on: (evt, fn) => ed.on(evt, fn),
    setDensity: (d) => mount.classList.toggle('je-stacked', d === 'stacked'),
    destroy: () => { try { ed.destroy(); } catch (_) {} host.innerHTML = ''; },
  };
}
