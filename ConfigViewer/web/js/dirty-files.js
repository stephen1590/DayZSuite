// dirty-files.js - E4 (Scale-Ready): the ONE named-dirty mechanism.
// The shell's guard and the header pill knew THAT something was unsaved; nobody
// could say WHICH files. Every editor now reports names through here, and every
// save prompts with the exact list first. Pure logic only - no DOM, so the node
// test suite (tests/dirty-files.test.js) covers it; editors keep the thin wiring.

const isComment = (k) => typeof k === 'string' && k.startsWith('_');

// Do two JSON texts hold the same document? Byte equality is the wrong question for a STRUCTURED
// editor: it re-serialises what it loaded, so its output is never byte-identical to the file on
// the box even with zero edits. Comparing bytes made every owned JSON surface open already-dirty
// (owner, 2026-08-01: "Going to server settings automatically detects a change - why?").
//
// Key ORDER counts as a change on purpose - reordering a config is a real edit to the file, and
// folding it away would silently drop it. Unparseable input counts as CHANGED, never as clean:
// reporting "no changes" for a draft that does not parse would let a broken edit vanish.
//
// Big integers: compared as raw text, not through JSON.parse, so a Steam64 ID past 2^53 cannot
// be rounded into a false match. The editors' bigParse/bigStringify pair owns that on the write
// path; here it is enough never to introduce a double.
export function jsonEquivalent(a, b) {
  const canon = (t) => {
    if (typeof t !== 'string') return null;
    // Strip insignificant whitespace WITHOUT parsing: everything outside a string literal.
    let out = '', inStr = false, esc = false;
    for (const ch of t) {
      if (esc) { out += ch; esc = false; continue; }
      if (ch === '\\' && inStr) { out += ch; esc = true; continue; }
      if (ch === '"') { inStr = !inStr; out += ch; continue; }
      if (!inStr && (ch === ' ' || ch === '\n' || ch === '\r' || ch === '\t')) continue;
      out += ch;
    }
    return inStr ? null : out;   // unterminated string -> not parseable, treat as different
  };
  const ca = canon(a), cb = canon(b);
  if (ca === null || cb === null) return false;
  // A canonical form that is not plausibly a document (unbalanced) must not compare equal.
  const balanced = (s) => {
    let d = 0, inStr = false, esc = false;
    for (const ch of s) {
      if (esc) { esc = false; continue; }
      if (ch === '\\' && inStr) { esc = true; continue; }
      if (ch === '"') { inStr = !inStr; continue; }
      if (inStr) continue;
      if (ch === '{' || ch === '[') d++;
      else if (ch === '}' || ch === ']') d--;
      if (d < 0) return false;
    }
    return d === 0;
  };
  if (!balanced(ca) || !balanced(cb)) return false;
  return ca === cb;
}

// Which FILES differ between two overrides-doc snapshots. Labels: 'file' for the
// server-dir layer, 'file (common)' / 'file (<mission>)' for mission layers.
// Underscore keys are comments at every level - the apply engine ignores them, so do we.
export function changedFiles(before, after) {
  const out = new Set();
  const filesOf = (doc) => (doc && doc.files) || {};
  const missionsOf = (doc) => (doc && doc.mpmissions) || {};

  const diffLayer = (a, b, label) => {
    for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) {
      if (isComment(key)) continue;
      if (JSON.stringify(a[key]) !== JSON.stringify(b[key])) out.add(label(key));
    }
  };

  diffLayer(filesOf(before), filesOf(after), (f) => f);
  const am = missionsOf(before), bm = missionsOf(after);
  for (const mission of new Set([...Object.keys(am), ...Object.keys(bm)])) {
    if (isComment(mission)) continue;
    diffLayer(am[mission] || {}, bm[mission] || {}, (f) => `${f} (${mission})`);
  }
  return [...out];
}

// Header-pill text. Empty when clean; caps at 3 names so the pill stays a pill.
export function formatUnsaved(files) {
  if (!files || !files.length) return '';
  const shown = files.slice(0, 3).join(', ');
  const more = files.length - 3;
  return 'Unsaved: ' + shown + (more > 0 ? ` +${more} more` : '');
}

// The confirmation dialog body - the owner's ask, verbatim: tell me what files
// I edited and am currently saving, BEFORE the write happens.
// An EMPTY list is not a dialog. Owner, 2026-07-31: "when I go to save ... AND NOTHING IS
// LISTED!" - Save is always enabled, so clicking it with a clean doc asked for confirmation
// of a write that could not be named. A prompt that lists nothing trains you to click through
// the one that matters.
export function confirmSaveText(files) {
  if (!files || !files.length) return 'Nothing to save - no unsaved changes in this tab.';
  return 'Save these changes?\n\nYou edited and are saving:\n' +
    files.map((f) => `  • ${f}`).join('\n');
}

// One confirm for every save path. confirmFn is injectable for tests; in the
// browser it defaults to window.confirm - the house dialog idiom.
// Nothing changed -> refuse WITHOUT prompting. Callers already treat false as "abort", so an
// empty list can never reach a write, whichever editor asked.
export function confirmSave(files, confirmFn) {
  if (!files || !files.length) return false;
  const ask = confirmFn || ((m) => window.confirm(m));
  return ask(confirmSaveText(files));
}
