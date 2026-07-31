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

// Infer a permissive, drift-tolerant JSON Schema from an example value (a config file's own
// content) - the "schema from examples" input json-editor requires. Every object allows unknown
// props (additionalProperties:true) and nothing is required, so model drift still renders as
// editable additional-property nodes. It does NOT constrain saving: the value round-trips through
// the caller's existing save path unchanged. Array element schemas are merged so a union of keys
// across elements is captured (optional keys don't vanish from the add-item template).
export function inferSchema(v) {
  if (Array.isArray(v)) return { type: 'array', items: v.length ? v.map(inferSchema).reduce(mergeSchema) : {} };
  if (v && typeof v === 'object') {
    const properties = {};
    for (const k of Object.keys(v)) properties[k] = inferSchema(v[k]);
    return { type: 'object', properties, additionalProperties: true };
  }
  if (typeof v === 'number') return { type: 'number' };
  if (typeof v === 'boolean') return { type: 'boolean' };
  if (typeof v === 'string') return { type: 'string' };
  return {};   // null / undefined -> permissive (any)
}
// What the focused node is CALLED. The navigator mounts a fresh editor per focus, rooted at the
// focused subtree, so json-editor's own root label is always the literal "root" however deep you
// clicked (the 2026-07-31 bug report). The path knows better, so the path names it.
// Array items read "Parent [i+1]" - 1-based, matching the array-item titles the decorator already
// writes elsewhere in this file.
export function titleForPath(path) {
  const p = path || [];
  if (!p.length) return 'root';
  const last = p[p.length - 1];
  if (typeof last === 'number') {
    const parent = p.length > 1 ? String(p[p.length - 2]) : 'root';
    return parent + ' [' + (last + 1) + ']';
  }
  return String(last);
}

// The size shown next to the name, derived from the DATA. It used to come from the editor
// widget's internal `rows`, which only exists on array editors - so an object could never report
// a field count, and anything whose rows were absent fell through to the empty-array text.
// "(null)" is now reachable ONLY by a genuinely empty array.
export function sizeBadge(v) {
  if (Array.isArray(v)) return v.length ? '[' + v.length + ']' : '[ ] (null)';
  if (v && typeof v === 'object') { const n = Object.keys(v).length; return n ? '{' + n + '}' : '{ }'; }
  return '';
}

// The schema handed to a freshly mounted focus editor: the inferred shape PLUS the title its
// header renders. Keeping these together is what stops the two drifting apart again.
export function schemaForFocus(sub, path) {
  return { ...inferSchema(sub), title: titleForPath(path) };
}

function mergeSchema(a, b) {
  if (!a || !a.type) return b && b.type ? b : (a || {});
  if (!b || !b.type) return a;
  if (a.type !== b.type) return {};                    // mixed element types -> permissive
  if (a.type === 'object') {
    const properties = { ...(a.properties || {}) };
    for (const k of Object.keys(b.properties || {})) properties[k] = properties[k] ? mergeSchema(properties[k], b.properties[k]) : b.properties[k];
    return { type: 'object', properties, additionalProperties: true };
  }
  if (a.type === 'array') return { type: 'array', items: mergeSchema(a.items || {}, b.items || {}) };
  return { type: a.type };
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
    if (e.rows && e.rows.length === 0) e.toggle_button.click();   // empty array -> collapse (O(1); no getValue)
  });
}
// Big-file guard: json-editor builds every node eagerly, so a large recursive file (thousands of
// editors) is a heavy first paint. Collapsing the root's direct container children hides those
// subtrees (display:none -> no layout/paint) until the user drills in - a few clicks, and the file
// opens instantly. Only kicks in past the threshold, so small/medium files stay fully expanded.
function collapseTopLevel(ed) {
  Object.entries(ed.editors || {}).forEach(([path, e]) => {
    if (/^root\.[^.]+$/.test(path) && e && e.toggle_button && !e.collapsed) e.toggle_button.click();
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
      const pe = ed.getEditor(parentPath);
      const n = (pe && pe.rows) ? pe.rows.length : '?';   // O(1) row count - never getValue (it serializes the whole subtree)
      const want = key + ' [' + (idx + 1) + '/' + n + ']';
      if (name.textContent !== want) name.textContent = want;
    }
    // object "add property" button -> lifted out of the sibling .je-object__controls span and
    // placed right after the name, green (distinct from the array "add item" +). Its click
    // handler + modal are JS-referenced by the lib, so relocating the element keeps them working.
    const props = node.querySelector(':scope > .je-object__controls .json-editor-btntype-properties, :scope > .je-header .json-editor-btntype-properties');
    if (props && name && props.previousElementSibling !== name) { props.classList.add('je-props'); name.after(props); }
    // status after the name: array length from the editor's own .rows (O(1)). getValue() here
    // would serialize the whole subtree per node - the O(n^2) storm that made big files crawl.
    // Badge from the DATA (sizeBadge), not the widget's internal `rows`. rows exists only on array
    // editors, so an object could never report a field count and a missing rows fell through to the
    // empty-array text - the "[ ] (null) on everything" bug. rows.length is still preferred for a
    // BUILT array editor because it is O(1) and always current mid-edit; getValue() here would
    // serialize the whole subtree per node (the O(n^2) storm that made big files crawl).
    const ce = ed.getEditor(path);
    let txt = '';
    if (ce && ce.rows) txt = ce.rows.length ? '[' + ce.rows.length + ']' : '[ ] (null)';
    else if (ce && ce.schema && ce.schema.type === 'object') txt = sizeBadge(ce.value || {});
    row.classList.toggle('je-empty', txt.indexOf('null') > -1);   // empty array -> dimmed gold
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
    minimizeEmpty = true, collapseLargeOver = null, onChange, libSrc, editorOptions = {},
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
  // Coalesce decorate() across a burst of changes into one run per frame - on a big tree
  // (thousands of editors) a per-keystroke full re-scan would make typing lag. onChange is
  // only called when the caller wants it (guarded), so a caller that reads getValue() lazily
  // pays nothing per keystroke.
  let decoratePending = false;
  const scheduleDecorate = () => { if (decoratePending) return; decoratePending = true; requestAnimationFrame(() => { decoratePending = false; decorate(mount, ed); }); };
  ed.on('ready', () => {
    const big = collapseLargeOver && Object.keys(ed.editors || {}).length > collapseLargeOver;
    // On a big file the top-level collapse hides the bulk already - running minimizeEmpties would
    // click a toggle (forcing a reflow) for EVERY empty array (1000+ on a real loadout) for nothing.
    // So: big files get one cheap top-level collapse; only small files pay the per-empty tidy.
    if (big) collapseTopLevel(ed);
    else if (minimizeEmpty) minimizeEmpties(ed);
    decorate(mount, ed); fire();
  });
  ed.on('change', () => { scheduleDecorate(); fire(); });
  mount.addEventListener('click', (e) => { if (e.target.closest('.json-editor-btntype-toggle')) requestAnimationFrame(() => syncCarets(ed)); });

  return {
    editor: ed,
    getValue: () => safeVal(ed),
    on: (evt, fn) => ed.on(evt, fn),
    setDensity: (d) => mount.classList.toggle('je-stacked', d === 'stacked'),
    destroy: () => { try { ed.destroy(); } catch (_) {} host.innerHTML = ''; },
  };
}

// ===================== jump-to-node navigator =====================
// The whole file is shown as a clickable JSON map on the right; the editor on the left mounts ONLY
// the node you click ("jump to"). A loadout is 3600+ nodes as one tree but ~200 for one Set and 1-3
// for a value - so the editor is always tiny and instant, and OPENING a file builds no editors at
// all (just the JSON text). This is the real fix for big files, not a render-everything hack.
const getP = (o, p) => p.reduce((c, k) => (c == null ? undefined : c[k]), o);
const setP = (o, p, val) => { if (!p.length) return val; let c = o; for (let i = 0; i < p.length - 1; i++) c = c[p[i]]; c[p[p.length - 1]] = val; return o; };
const jnEsc = (s) => String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
// Attribute-safe escape (data-p holds JSON.stringify(path), which contains double quotes).
const jnAttr = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Render a value as clickable, path-tagged JSON. Every node carries data-p (its path) so a click
// can jump the editor there. The node at `focus` is marked .jn-focus.
function jnRenderJson(v, path, focus, ind) {
  const pj = jnAttr(JSON.stringify(path));
  const foc = (focus && JSON.stringify(path) === JSON.stringify(focus)) ? ' jn-focus' : '';
  const pad = '  '.repeat(ind), pad1 = '  '.repeat(ind + 1);
  if (Array.isArray(v)) {
    if (!v.length) return '<span class="jn-node jn-punc' + foc + '" data-p="' + pj + '">[]</span>';
    return '<span class="jn-node jn-punc' + foc + '" data-p="' + pj + '">[</span>\n'
      + v.map((x, i) => pad1 + jnRenderJson(x, path.concat(i), focus, ind + 1)).join(',\n') + '\n' + pad + ']';
  }
  if (v && typeof v === 'object') {
    const ks = Object.keys(v);
    if (!ks.length) return '<span class="jn-node jn-punc' + foc + '" data-p="' + pj + '">{}</span>';
    return '<span class="jn-node jn-punc' + foc + '" data-p="' + pj + '">{</span>\n'
      + ks.map((k) => pad1 + '<span class="jn-node jn-key" data-p="' + jnAttr(JSON.stringify(path.concat(k))) + '">"' + jnEsc(k) + '"</span>: '
        + jnRenderJson(v[k], path.concat(k), focus, ind + 1)).join(',\n') + '\n' + pad + '}';
  }
  const cls = v === null ? 'jn-nul' : typeof v === 'number' ? 'jn-num' : typeof v === 'boolean' ? 'jn-bool' : 'jn-str';
  return '<span class="jn-node ' + cls + foc + '" data-p="' + pj + '">' + jnEsc(JSON.stringify(v)) + '</span>';
}

// Mount the navigator into `host`. opts: { doc, onChange(doc) }. Returns { getDoc, focusTo, destroy }.
export async function mountJsonNavigator(host, opts = {}) {
  const { doc, onChange } = opts;
  let workingDoc = doc;
  let focus = [];            // default: root loaded on open
  let curHandle = null;

  host.classList.add('jn-wrap');
  host.innerHTML =
    '<div class="jn-bar"><span class="jn-crumbs"></span></div>'
    + '<div class="jn-split">'
    + '<div class="jn-editor"></div>'
    + '<pre class="jn-json"></pre></div>';
  const crumbs = host.querySelector('.jn-crumbs');
  const edPane = host.querySelector('.jn-editor');
  const jsonPane = host.querySelector('.jn-json');

  const renderJson = () => { jsonPane.innerHTML = jnRenderJson(workingDoc, [], focus, 0); };
  let rerenderPending = false;
  const scheduleRerender = () => { if (rerenderPending) return; rerenderPending = true; requestAnimationFrame(() => { rerenderPending = false; renderJson(); }); };

  const renderCrumbs = () => {
    const segs = ['root', ...(focus || [])];
    crumbs.innerHTML = segs.map((s, i) => '<span class="jn-crumb' + (i === segs.length - 1 ? ' jn-cur' : '') + '" data-d="' + i + '">' + jnEsc(String(s)) + '</span>')
      .join('<span class="jn-sep">›</span>');
  };
  // Prominent centered spinner OVER the editor pane; mount the focused node beneath it and drop the
  // spinner once built. Painted before the (main-thread-blocking) construction, so loading is always
  // visible. Root ([]) is the default focus; small jumps are near-instant.
  const focusTo = (path) => {
    focus = path;
    renderCrumbs(); renderJson();
    edPane.innerHTML = '<div class="jn-mnt"></div><div class="jn-spin"><span class="jn-sp"></span><span>Loading editor…</span></div>';
    const mnt = edPane.querySelector('.jn-mnt');
    const spin = edPane.querySelector('.jn-spin');
    requestAnimationFrame(() => setTimeout(async () => {
      if (JSON.stringify(focus) !== JSON.stringify(path)) return;   // jumped again meanwhile
      const sub = getP(workingDoc, path);
      if (curHandle) { try { curHandle.destroy(); } catch (_) {} curHandle = null; }
      curHandle = await mountJsonEditor(mnt, {
        // schemaForFocus, not inferSchema: it carries the TITLE, so the header names the node you
        // clicked instead of the literal "root" at every depth (2026-07-31 bug report).
        schema: schemaForFocus(sub, path), startval: sub, pathbar: true, collapseLargeOver: 400,
        onChange: (val) => { if (!path.length) workingDoc = val; else setP(workingDoc, path, val); scheduleRerender(); if (onChange) onChange(workingDoc); },
      });
      if (spin) spin.remove();
    }, 0));
  };

  jsonPane.addEventListener('click', (e) => { const n = e.target.closest('.jn-node'); if (!n) return; try { focusTo(JSON.parse(n.getAttribute('data-p'))); } catch (_) {} });
  crumbs.addEventListener('click', (e) => { const c = e.target.closest('.jn-crumb'); if (!c) return; focusTo((focus || []).slice(0, +c.getAttribute('data-d'))); });

  renderCrumbs(); renderJson();
  focusTo([]);   // load the root editor by default
  return { getDoc: () => workingDoc, focusTo, destroy: () => { if (curHandle) { try { curHandle.destroy(); } catch (_) {} } host.innerHTML = ''; } };
}
