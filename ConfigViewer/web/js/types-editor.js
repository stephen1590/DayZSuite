// types-editor.js — the CE types-table editor for registry web:'types' surfaces (the Expansion
// tuning pair). The BASE file (upstream expansion_types.xml) is read-only truth; the TUNING file
// is the box-owned override layer registered after it, so each <type> here fully replaces the
// same-named upstream entry. This editor shows the MERGED view (tuning overlays base), stages
// complete <type> override blocks, and saves the WHOLE tuning file via configs/set-types —
// dayz-ctl validates the structure, snapshots the outgoing version and enforces optimistic
// concurrency (base=<sha256>), so a half-staged document can never reach the CE.
//
// Never writes the base file. Never touches config-overrides.json — this is its own save path.
import { escapeHtml, attr, setGlobalMsg, stripBom } from './ui.js';
import { apiPost } from './api-client.js';
import { loadCred, handle } from './auth.js';
import { highlight, detectLang } from './highlight.js';   // XML preview of the selected type

// Which BASE surface a tuning row overlays. Hardcoded on purpose (two rows today) — promote to
// a config-registry.json field if types surfaces multiply. Keys are registry surface names.
const TYPES_BASE = {
  expansionTypesTuning: 'expansionTypes',
  expansionTypesTuningEnoch: 'expansionTypesEnoch',
};

// Canonical CE child order for serialized <type> blocks (unknown tags keep document order after
// these). Matching the upstream template layout keeps diffs reviewable in git and the file view.
const CHILD_ORDER = ['nominal', 'lifetime', 'restock', 'min', 'quantmin', 'quantmax', 'cost', 'flags', 'category', 'usage', 'value', 'tag'];
const QUICK = ['nominal', 'min', 'lifetime', 'restock'];   // the table's inline columns
const SCALARS = ['nominal', 'lifetime', 'restock', 'min', 'quantmin', 'quantmax', 'cost'];
const NAMELISTS = ['category', 'usage', 'value', 'tag'];   // children carrying name="..." (category 0-1, rest 0-n)
const CAP = 150;                                           // rows rendered before "Show more"

// Per-row editor state, kept across file switches (same in-memory-survival contract as the
// overrides doc): key -> { name, doc, text, version, baseMap, tunMap, rootNodes, edits, removals, ... }
const states = new Map();

export function typesAnyDirty() {
  for (const st of states.values()) if (st.edits.size || st.removals.size) return true;
  return false;
}

function parseTypes(text) {
  if (text == null) return null;
  const doc = new DOMParser().parseFromString(stripBom(text), 'application/xml');
  if (doc.querySelector('parsererror')) return null;
  if (doc.documentElement.tagName !== 'types') return null;
  return doc;
}
function typeMap(doc) {
  const m = new Map();
  if (!doc) return m;
  for (const el of doc.documentElement.children) {
    if (el.tagName === 'type' && el.getAttribute('name')) m.set(el.getAttribute('name'), el);
  }
  return m;
}
function childOf(el, tag) { return [...el.children].find((c) => c.tagName === tag) || null; }
function fieldOf(el, tag) { const c = childOf(el, tag); return c ? c.textContent.trim() : ''; }
function namesOf(el, tag) { return [...el.children].filter((c) => c.tagName === tag).map((c) => c.getAttribute('name') || '').filter(Boolean); }

// The element whose values the row SHOWS: staged edit > live tuning override (unless reverted)
// > base. A reverting TUNING-ONLY type still shows its tuning values (there is no base to fall
// back to) so the row stays visible with its Keep button until the removal is saved.
function effectiveEl(st, name) {
  if (st.edits.has(name)) return st.edits.get(name);
  if (!st.removals.has(name) && st.tunMap.has(name)) return st.tunMap.get(name);
  return st.baseMap.get(name) || st.tunMap.get(name) || null;
}
function isOverridden(st, name) { return st.edits.has(name) || (st.tunMap.has(name) && !st.removals.has(name)); }

// Clone a <type> INTO the tuning document (importNode, not cloneNode): base entries live in a
// SEPARATE DOMParser document (st.baseDoc), so a plain clone would leave the staged block owned
// by baseDoc — and a later setChildText (st.doc.createElement + appendChild) would splice a
// tuning-doc node under a base-doc parent. importNode adopts the copy into st.doc so every staged
// block is single-document. (For a tunMap element, already in st.doc, it is an equivalent copy.)
function cloneForEdit(st, src) { return st.doc.importNode(src, true); }
// Staging: every edit works on a COMPLETE clone of the effective element (all fields carried
// verbatim — the rule the tuning file already follows), so a partial block never exists.
function stageEl(st, name) {
  if (st.edits.has(name)) return st.edits.get(name);
  const src = (!st.removals.has(name) && st.tunMap.get(name)) || st.baseMap.get(name);
  if (!src) return null;
  const clone = cloneForEdit(st, src);
  st.removals.delete(name);          // editing resurrects a reverted override
  st.edits.set(name, clone);
  return clone;
}
// Base types NOT yet in the override layer — the pool the "Add override" picker offers. Base-only
// by policy: the tuning layer OVERRIDES upstream types, it does not invent them, so only names in
// the base file are addable, and each new override is CLONED from its base entry as the template.
function overridableBase(st) {
  const taken = new Set([...st.edits.keys(), ...st.tunMap.keys()]);
  return [...st.baseMap.keys()].filter((n) => !taken.has(n)).sort();
}
// Promote a base type into the tuning layer: refuse a name not in the base (base-only), dedup to
// the existing override if already there, else stage a COMPLETE clone of the base entry so every
// field starts at its real upstream value. Returns true when a row is selected to show.
function addOverride(st, name) {
  const n = (name || '').trim();
  if (!n) return false;
  if (st.edits.has(n) || (st.tunMap.has(n) && !st.removals.has(n))) {
    st.selected = n;
    setGlobalMsg('"' + n + '" is already overridden — selected it.', false);
    return true;
  }
  if (!st.baseMap.has(n)) {
    setGlobalMsg('"' + n + '" is not in the base file — the tuning layer only overrides base types.', true);
    return false;
  }
  st.removals.delete(n);
  st.edits.set(n, cloneForEdit(st, st.baseMap.get(n)));
  st.selected = n;
  setGlobalMsg('Added "' + n + '" — cloned from the base. Tune it, then Save.', false);
  return true;
}
function setChildText(st, el, tag, val) {
  let c = childOf(el, tag);
  if (!c) { c = st.doc.createElement(tag); el.appendChild(c); }
  c.textContent = String(val);
}
function setNamelist(st, el, tag, names) {
  [...el.children].filter((c) => c.tagName === tag).forEach((c) => c.remove());
  for (const n of names) { const c = st.doc.createElement(tag); c.setAttribute('name', n); el.appendChild(c); }
}
function setFlag(st, el, attrName, on) {
  let f = childOf(el, 'flags');
  if (!f) { f = st.doc.createElement('flags'); el.appendChild(f); }
  f.setAttribute(attrName, on ? '1' : '0');
}

// ===================== serialization =====================
function escX(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
function escA(s) { return escX(s).replace(/"/g, '&quot;'); }
// raw=true emits UNescaped text/attr content for the preview: highlight() escapes for HTML
// display itself (it tokenizes on the escaped form), so pre-escaping here would double-encode
// an '&'. Serialization to disk uses raw=false — real XML entities. Tag delimiters (<,>) are
// always literal in the string either way; only content/attr values differ.
function typeXml(el, raw) {
  const ex = raw ? String : escX;
  const ea = raw ? String : escA;
  let out = '    <type name="' + ea(el.getAttribute('name')) + '">\n';
  const kids = [...el.children];
  const done = new Set();
  const emit = (c) => {
    done.add(c);
    if (c.attributes.length === 0) out += '        <' + c.tagName + '>' + ex(c.textContent.trim()) + '</' + c.tagName + '>\n';
    else {
      let attrs = '';
      for (const a of c.attributes) attrs += ' ' + a.name + '="' + ea(a.value) + '"';
      out += '        <' + c.tagName + attrs + '/>\n';
    }
  };
  for (const tag of CHILD_ORDER) for (const c of kids) if (c.tagName === tag && !done.has(c)) emit(c);
  for (const c of kids) if (!done.has(c)) emit(c);
  return out + '    </type>\n';
}
// Rebuild the whole tuning document: the pre-<types> header (XML decl + the ownership comment)
// verbatim, then the ORIGINAL root nodes in order — comments preserved, edited types replaced,
// reverted types skipped — then any brand-new overrides appended.
function serialize(st) {
  const idx = st.text.indexOf('<types');
  const header = idx > 0 ? st.text.slice(0, idx) : '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
  let out = header + '<types>\n';
  const emitted = new Set();
  for (const node of st.rootNodes) {
    if (node.nodeType === Node.COMMENT_NODE) { out += '    <!--' + node.data + '-->\n'; continue; }
    if (node.nodeType !== Node.ELEMENT_NODE || node.tagName !== 'type') continue;
    const n = node.getAttribute('name');
    if (!n || st.removals.has(n)) continue;
    emitted.add(n);
    out += typeXml(st.edits.get(n) || node);
  }
  for (const [n, el] of st.edits) if (!emitted.has(n) && !st.removals.has(n)) out += typeXml(el);
  return out + '</types>\n';
}

// ===================== load =====================
async function loadState(row) {
  const have = states.get(row.key);
  if (have && have.loaded) return have;
  const cred = loadCred();
  if (!cred) throw new Error('not signed in');
  const baseName = TYPES_BASE[row.name];
  const [tun, base] = await Promise.all([
    apiPost('/dayz/configs/types?name=' + encodeURIComponent(row.name), cred),
    baseName
      ? apiPost('/dayz/configs/get?name=' + encodeURIComponent(baseName), cred).catch(() => ({ content: null }))
      : Promise.resolve({ content: null }),
  ]);
  const text = stripBom(tun.content ?? '');
  const doc = parseTypes(text);
  if (!doc) throw new Error('the tuning file on the box does not parse as a <types> document — see the File view');
  const baseDoc = parseTypes(base.content);
  const st = {
    key: row.key, name: row.name, loaded: true,
    doc, text, version: tun.version || null,
    baseDoc, baseMap: typeMap(baseDoc), tunMap: typeMap(doc),
    rootNodes: [...doc.documentElement.childNodes],
    edits: new Map(), removals: new Set(),
    filter: '', overOnly: false, capOpen: false, expanded: new Set(),
    selected: null,   // the type whose full XML shows in the left preview panel
    addOpen: false,   // the "Add override" picker panel is open
    addValue: '',     // in-progress picker text — persisted so a rerender can't drop it
    baseMissing: baseDoc === null,
  };
  states.set(row.key, st);
  return st;
}

// ===================== rendering =====================
function quickCell(st, name, tag, val) {
  return '<input class="ty-in" data-name="' + attr(name) + '" data-tag="' + tag + '" value="' + attr(val) + '">';
}
function rowHtml(st, name, hidden) {
  const el = effectiveEl(st, name);
  if (!el) return '';
  const over = isOverridden(st, name);
  const staged = st.edits.has(name);
  const reverted = st.removals.has(name);
  const tunOnly = !st.baseMap.has(name);
  const badge = staged ? '<span class="tag cx">edited</span>'
    : reverted ? '<span class="tag warn">reverting</span>'
    : over ? '<span class="tag">override</span>'
    : tunOnly ? '<span class="tag warn">tuning-only</span>' : '';
  const open = st.expanded.has(name);
  let html = '<div class="ty-row' + (over || staged ? ' over' : '') + (name === st.selected ? ' selected' : '') + (hidden ? ' cap-hide' : '') + '" data-name="' + attr(name) + '">' +
    '<div class="ty-name mono" title="' + attr(name) + '">' + escapeHtml(name) + '</div>' +
    QUICK.map((t) => '<div>' + quickCell(st, name, t, fieldOf(el, t)) + '</div>').join('') +
    '<div class="ty-badge">' + badge + '</div>' +
    '<div class="ty-act">' +
      '<button type="button" class="ghost ty-more" data-name="' + attr(name) + '">' + (open ? 'Hide' : 'All fields') + '</button>' +
      (over || reverted ? '<button type="button" class="ghost ty-rev" data-name="' + attr(name) + '" title="' + (reverted ? 'Keep the override after all' : 'Drop this override — the upstream entry applies again at the next restart') + '">' + (reverted ? 'Keep' : 'Revert') + '</button>' : '') +
    '</div></div>';
  if (open) html += expandHtml(st, name, el);
  return html;
}
function expandHtml(st, name, el) {
  const flags = childOf(el, 'flags');
  const flagAttrs = flags ? [...flags.attributes] : [];
  let html = '<div class="ty-exp" data-name="' + attr(name) + '">';
  html += '<div class="ty-exp-grid">';
  for (const tag of SCALARS) {
    html += '<label class="ty-fld"><span>' + tag + '</span>' + quickCell(st, name, tag, fieldOf(el, tag)) + '</label>';
  }
  for (const tag of NAMELISTS) {
    html += '<label class="ty-fld wide"><span>' + tag + (tag === 'category' ? '' : ' (comma-sep)') + '</span>' +
      '<input class="ty-nl" data-name="' + attr(name) + '" data-tag="' + tag + '" value="' + attr(namesOf(el, tag).join(', ')) + '" placeholder="none"></label>';
  }
  if (flagAttrs.length) {
    html += '<div class="ty-fld wide"><span>flags</span><div class="ty-flags">' +
      flagAttrs.map((a) => '<label><input type="checkbox" class="ty-flag" data-name="' + attr(name) + '" data-attr="' + attr(a.name) + '"' + (a.value === '1' ? ' checked' : '') + '> ' + escapeHtml(a.name) + '</label>').join('') +
      '</div></div>';
  }
  html += '</div></div>';
  return html;
}
function matches(st, name) {
  const q = st.filter.trim().toLowerCase();
  if (st.overOnly && !isOverridden(st, name) && !st.removals.has(name)) return false;
  if (!q) return true;
  if (name.toLowerCase().includes(q)) return true;
  const el = effectiveEl(st, name);
  if (!el) return false;
  return NAMELISTS.some((t) => namesOf(el, t).some((n) => n.toLowerCase().includes(q)));
}
function allNames(st) {
  // Base order first (upstream template order — familiar), then tuning-only extras.
  const names = [...st.baseMap.keys()];
  for (const n of st.tunMap.keys()) if (!st.baseMap.has(n)) names.push(n);
  return names;
}
// Left preview: the FULL <type> block for the selected row, exactly as it will serialize
// (edits included — reads effectiveEl). Raw XML through highlight() so it renders like the
// File view. The head tag mirrors the row badge so the source (edited/override/base) is clear.
function previewInner(st) {
  if (!st.selected) return '<div class="ty-pv-empty">Select a type to preview its full XML block — every field, not just the four columns.</div>';
  const el = effectiveEl(st, st.selected);
  if (!el) return '<div class="ty-pv-empty">This type has no current definition.</div>';
  const staged = st.edits.has(st.selected);
  const reverting = st.removals.has(st.selected);
  const over = isOverridden(st, st.selected);
  const tag = staged ? '<span class="tag cx">edited</span>'
    : reverting ? '<span class="tag warn">reverting</span>'
    : over ? '<span class="tag">override layer</span>'
    : '<span class="tag warn">base file</span>';
  const hint = over || staged
    ? 'This block is written to the tuning file.'
    : 'Upstream value — editing a field stages an override here.';
  return '<div class="ty-pv-head"><span class="mono">' + escapeHtml(st.selected) + '</span>' + tag + '</div>' +
    '<pre class="ty-pv-xml">' + highlight(typeXml(el, true), detectLang('type.xml')) + '</pre>' +
    '<div class="ty-pv-foot">' + escapeHtml(hint) + '</div>';
}
// Update ONLY the preview + the selected-row highlight, no table rebuild — so selecting a row
// (or clicking into one of its inputs) never blurs the field the user just clicked.
function updatePreview(st, body) {
  const pv = body.querySelector('#tyPreview');
  if (pv) pv.innerHTML = previewInner(st);
  body.querySelectorAll('.ty-row').forEach((r) => r.classList.toggle('selected', r.dataset.name === st.selected));
}
function tableHtml(st) {
  const names = allNames(st).filter((n) => matches(st, n));
  const nOver = allNames(st).filter((n) => isOverridden(st, n)).length;
  const dirty = st.edits.size + st.removals.size;
  const pool = overridableBase(st);            // base types addable as new overrides
  const canAdd = pool.length > 0;
  let html = '<div class="ty-bar">' +
    '<input id="tyFilter" type="text" placeholder="Filter by classname, category, usage or tier…" spellcheck="false" autocomplete="off" value="' + attr(st.filter) + '">' +
    '<label class="ty-only"><input type="checkbox" id="tyOverOnly"' + (st.overOnly ? ' checked' : '') + '> overridden only</label>' +
    '<span class="meta">' + names.length + ' of ' + allNames(st).length + ' types · ' + nOver + ' overridden</span>' +
    '<span class="spacer"></span>' +
    '<button type="button" class="btn-sm" id="tyAddBtn"' + (canAdd ? '' : ' disabled title="' + attr(st.baseMissing ? 'base file unavailable — cannot validate against it' : 'every base type is already overridden') + '"') + '>' + (st.addOpen ? 'Close' : '+ Add override') + '</button>' +
    (dirty ? '<button type="button" class="btn-sm" id="tyDiscard">Discard</button>' : '') +
    '<button type="button" class="btn-sm primary" id="tySave"' + (dirty ? '' : ' disabled') + '>Save ' + (dirty || '') + ' change' + (dirty === 1 ? '' : 's') + '</button>' +
    '</div>' +
    (st.addOpen && canAdd ?
      '<div class="ty-addbar">' +
        '<input id="tyAddInput" list="tyAddList" type="text" placeholder="Base classname to override…" spellcheck="false" autocomplete="off" value="' + attr(st.addValue || '') + '">' +
        '<datalist id="tyAddList">' + pool.map((n) => '<option value="' + attr(n) + '"></option>').join('') + '</datalist>' +
        '<button type="button" class="btn-sm primary" id="tyAddGo">Add override</button>' +
        '<button type="button" class="btn-sm" id="tyAddCancel">Cancel</button>' +
        '<span class="meta">' + pool.length + ' base type' + (pool.length === 1 ? '' : 's') + ' not yet overridden — pick one to clone as the starting point</span>' +
      '</div>' : '') +
    (st.baseMissing ? '<div class="ovr-note">Base file unavailable — showing the tuning file\'s own entries only. Overrides still save.</div>' : '') +
    '<div class="ty-note ovr-note">Edits stage a <b>complete</b> replacement <span class="mono">&lt;type&gt;</span> block in the tuning layer — the base file is never modified. Save rewrites the tuning file (snapshotted on the box); <b>restart to apply</b>.</div>';
  // Two columns: the XML preview of the selected type on the LEFT (sticky), the table on the RIGHT.
  let table = '<div class="ty-head"><div>Classname</div>' + QUICK.map((t) => '<div>' + t + '</div>').join('') + '<div></div><div></div></div>';
  let shown = 0;
  for (const n of names) {
    const hidden = !st.filter && !st.overOnly && !st.capOpen && shown >= CAP && !st.expanded.has(n) && !st.edits.has(n);
    table += rowHtml(st, n, hidden);
    shown++;
  }
  if (!names.length) table += '<div class="ovr-note">No types match.</div>';
  if (!st.filter && !st.overOnly && !st.capOpen && names.length > CAP) {
    table += '<div class="fld-more"><button type="button" id="tyMore" class="ghost">Show ' + (names.length - CAP) + ' more type' + (names.length - CAP === 1 ? '' : 's') + '</button></div>';
  }
  html += '<div class="ty-split">' +
    '<div class="ty-preview" id="tyPreview">' + previewInner(st) + '</div>' +
    '<div class="ty-main">' + table + '</div>' +
    '</div>';
  return html;
}

// ===================== wiring =====================
function commitQuick(st, inp, hooks) {
  const name = inp.dataset.name, tag = inp.dataset.tag;
  const cur = effectiveEl(st, name);
  const now = cur ? fieldOf(cur, tag) : '';
  const v = inp.value.trim();
  if (v === now) return;                                     // no-op — don't stage an identical block
  if (!/^-?\d+$/.test(v)) { inp.classList.add('bad'); setGlobalMsg(tag + ' must be an integer (CE uses -1 for "unset" quantities).', true); return; }
  inp.classList.remove('bad');
  const el = stageEl(st, name);
  if (!el) return;
  setChildText(st, el, tag, v);
  st.selected = name;
  rerender(st, hooks);
  setGlobalMsg('Change staged — press Save, then restart to apply.', false);
}
function wire(st, body, hooks) {
  const filt = body.querySelector('#tyFilter');
  if (filt) {
    filt.oninput = () => { st.filter = filt.value; rerender(st, hooks, true); };
  }
  const only = body.querySelector('#tyOverOnly');
  if (only) only.onchange = () => { st.overOnly = only.checked; rerender(st, hooks); };
  const more = body.querySelector('#tyMore');
  if (more) more.onclick = () => { st.capOpen = true; rerender(st, hooks); };
  // "Add override": toggle the base-type picker, then clone a base type into the tuning layer.
  const addBtn = body.querySelector('#tyAddBtn');
  if (addBtn) addBtn.onclick = () => {
    st.addOpen = !st.addOpen;
    if (!st.addOpen) st.addValue = '';
    rerender(st, hooks);
    if (st.addOpen) { const i = body.querySelector('#tyAddInput'); if (i) i.focus(); }
  };
  const addInput = body.querySelector('#tyAddInput');
  if (addInput) addInput.addEventListener('input', () => { st.addValue = addInput.value; });   // survive an unrelated rerender
  const doAdd = () => {
    if (!addInput) return;
    if (!addOverride(st, addInput.value)) { addInput.focus(); return; }   // refused (not in base) — keep the panel open
    st.addOpen = false; st.addValue = ''; st.filter = '';                 // clear the filter so the new row is visible
    rerender(st, hooks);
    const sel = body.querySelector('.ty-row.selected');
    if (sel) { sel.scrollIntoView({ block: 'center' }); const inp = sel.querySelector('.ty-in'); if (inp) inp.focus(); }
  };
  const addGo = body.querySelector('#tyAddGo');
  if (addGo) addGo.onclick = doAdd;
  if (addInput) addInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); doAdd(); } });
  const addCancel = body.querySelector('#tyAddCancel');
  if (addCancel) addCancel.onclick = () => { st.addOpen = false; st.addValue = ''; rerender(st, hooks); };
  body.querySelectorAll('.ty-in').forEach((inp) => inp.addEventListener('change', () => commitQuick(st, inp, hooks)));
  body.querySelectorAll('.ty-nl').forEach((inp) => inp.addEventListener('change', () => {
    const name = inp.dataset.name, tag = inp.dataset.tag;
    const namesArr = inp.value.split(',').map((s) => s.trim()).filter(Boolean);
    if (tag === 'category' && namesArr.length > 1) { inp.classList.add('bad'); setGlobalMsg('category takes at most one name.', true); return; }
    inp.classList.remove('bad');
    const el = stageEl(st, name);
    if (!el) return;
    setNamelist(st, el, tag, namesArr);
    st.selected = name;
    rerender(st, hooks);
    setGlobalMsg('Change staged — press Save, then restart to apply.', false);
  }));
  body.querySelectorAll('.ty-flag').forEach((cb) => cb.addEventListener('change', () => {
    const el = stageEl(st, cb.dataset.name);
    if (!el) return;
    setFlag(st, el, cb.dataset.attr, cb.checked);
    st.selected = cb.dataset.name;
    rerender(st, hooks);
    setGlobalMsg('Change staged — press Save, then restart to apply.', false);
  }));
  body.querySelectorAll('.ty-more').forEach((b) => b.addEventListener('click', () => {
    const n = b.dataset.name;
    if (st.expanded.has(n)) st.expanded.delete(n); else st.expanded.add(n);
    st.selected = n;
    rerender(st, hooks);
  }));
  body.querySelectorAll('.ty-rev').forEach((b) => b.addEventListener('click', () => {
    const n = b.dataset.name;
    if (st.removals.has(n)) { st.removals.delete(n); }
    else {
      st.edits.delete(n);
      if (st.tunMap.has(n)) st.removals.add(n);              // an unsaved brand-new override just vanishes
    }
    st.selected = n;
    rerender(st, hooks);
    setGlobalMsg(st.removals.has(n) ? 'Override marked for removal — press Save.' : 'Kept.', false);
  }));
  // Select a row (fills the left preview) on interaction, WITHOUT a table rebuild - mousedown
  // fires before focus and updatePreview only swaps the preview + the .selected class, so
  // clicking a row's input still lands in that input. Buttons set selection in their own handlers.
  body.querySelectorAll('.ty-row, .ty-exp').forEach((elx) => elx.addEventListener('mousedown', (e) => {
    if (e.target.closest('button')) return;
    const name = elx.dataset.name;
    if (name && name !== st.selected) { st.selected = name; updatePreview(st, body); }
  }));
  const disc = body.querySelector('#tyDiscard');
  if (disc) disc.onclick = () => {
    if (!window.confirm('Discard all staged type changes for this file?')) return;
    st.edits.clear(); st.removals.clear();
    rerender(st, hooks);
    setGlobalMsg('Staged type changes discarded.', false, true);
  };
  const save = body.querySelector('#tySave');
  if (save) save.onclick = () => doSave(st, body, hooks);
}
function rerender(st, hooks, keepFocus) {
  const body = st._body;
  if (!body) return;
  // The innerHTML rebuild DESTROYS .ty-main — the sole scroller in types-mode (style.css) — so
  // its scrollTop must be carried across the rebuild or every committed edit snaps the list to
  // the top. Same for focus: a commit fires mid-blur and the rebuild dumps focus onto <body>.
  const main = body.querySelector('.ty-main');
  const scroll = main ? main.scrollTop : 0;
  // Focus carry-over: the filter box (while typing) OR a field input. Field identity is
  // data-name + data-tag, scoped to the row vs the expanded panel because the four QUICK tags
  // render an input in BOTH places, so the pair alone is not unique within a row.
  const ae = document.activeElement;
  let active = null;
  if (keepFocus && ae && ae.id === 'tyFilter') active = { sel: '#tyFilter', pos: ae.selectionStart };
  else if (ae && body.contains(ae) && ae.dataset && ae.dataset.name && ae.dataset.tag) {
    const scope = ae.closest('.ty-exp') ? '.ty-exp ' : '.ty-row ';
    active = {
      sel: scope + '[data-name="' + CSS.escape(ae.dataset.name) + '"][data-tag="' + ae.dataset.tag + '"]',
      pos: ae.selectionStart,
    };
  }
  body.innerHTML = tableHtml(st);
  wire(st, body, hooks);
  const m2 = body.querySelector('.ty-main');
  if (m2) m2.scrollTop = scroll;                          // browser clamps if content shrank
  if (active) {
    const f = body.querySelector(active.sel);
    if (f) { f.focus({ preventScroll: true }); if (active.pos != null && f.setSelectionRange) f.setSelectionRange(active.pos, active.pos); }
  }
  if (hooks && hooks.onDirty) hooks.onDirty();
}

async function doSave(st, body, hooks) {
  const cred = loadCred();
  if (!cred) return;
  const save = body.querySelector('#tySave');
  if (save) { save.disabled = true; save.textContent = 'Saving…'; }
  try {
    const content = serialize(st);
    let r;
    try {
      r = await apiPost('/dayz/configs/set-types', cred, { name: st.name, content, baseVersion: st.version });
    } catch (err) {
      // Concurrent edit: another admin saved this file since we loaded it. Never clobber.
      if (err.status === 409) {
        const ok = window.confirm('Another admin saved this types file since you opened it — saving now would overwrite their changes.\n\nReload their version? Your staged edits here are discarded (Cancel to copy anything out first).');
        if (ok) { states.delete(st.key); rerenderFresh(st, body, hooks); }
        else setGlobalMsg('Save cancelled — reload before saving so you don\'t overwrite the other admin.', true);
        return;
      }
      throw err;
    }
    // Adopt the saved document as the new baseline: re-parse it so tunMap/rootNodes reflect
    // exactly what the box now holds, and rebase the version for the next save.
    st.text = content;
    st.doc = parseTypes(content);
    st.tunMap = typeMap(st.doc);
    st.rootNodes = [...st.doc.documentElement.childNodes];
    st.edits.clear(); st.removals.clear();
    st.version = (r && r.version) || null;
    rerender(st, hooks);
    if (hooks && hooks.onSaved) hooks.onSaved();
    setGlobalMsg('Saved — previous version snapshotted on the box. Restart the server to apply.', false, true);
  } catch (err) {
    if (handle(err)) return;
    setGlobalMsg(err.status === 403 ? 'Your key can\'t write — sign in with a full-scope key.' : 'Save failed: ' + err.message, true);
  } finally {
    const s = body.querySelector('#tySave');
    if (s && s.textContent === 'Saving…') { s.disabled = false; s.textContent = 'Save'; }
  }
}
async function rerenderFresh(st, body, hooks) {
  body.innerHTML = '<span class="meta" style="padding:16px;display:block">Reloading…</span>';
  try {
    const fresh = await loadState({ key: st.key, name: st.name });
    fresh._body = body;
    rerender(fresh, hooks);
  } catch (err) {
    body.innerHTML = '<div class="ovr-note">Could not reload: ' + escapeHtml(err.message) + '</div>';
  }
}

// Entry point (called by editor.js renderBody for row.types when the Types view is active).
// Returns the loaded tuning text so the caller can feed Copy / lastFileText.
export async function renderTypesEditor(row, body, hooks) {
  let st;
  try { st = await loadState(row); }
  catch (err) {
    if (handle(err)) return null;
    body.innerHTML = '<div class="ovr-note">Types editor unavailable — ' + escapeHtml(err.message) + '</div>';
    return null;
  }
  st._body = body;
  rerender(st, hooks);
  return st.text;
}
