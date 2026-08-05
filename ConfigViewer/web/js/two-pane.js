// two-pane.js — the rule EVERY two-pane editor follows. Pure logic only, no DOM, so the node
// suite covers it (tests/two-pane.test.js) and each editor keeps only its own thin wiring.
//
// The model, and the only thing that keeps two panes honest: ONE document is the truth. The side
// holding the edit owns it; the other side is a PROJECTION of the same document, re-derived, never
// a second copy that has to be reconciled. So there is no drift to merge - there is only a switch
// of ownership, and the two things a switch has to answer:
//   1. may this side take it? (the structured side cannot hold text that does not parse)
//   2. does the user lose anything by switching? (a projection re-formats, so warn when they typed)
// Concurrent BACKEND edits are a different problem and are already handled elsewhere - own-write
// takes baseVersion and returns 409.
//
// JSON-shaped on purpose: json-editor has no XML model, so a structured side only exists for JSON
// and pretending otherwise would invent a mechanism nothing can implement.
import { bigParse, restoreBigInts } from './lossless-json.js';
import { jsonEquivalent } from './dirty-files.js';

export const RAW = 'raw';
export const STRUCTURED = 'structured';

// --------------------------------------------------------------------------------- locating a failure
// Where a JSON document FIRST stops being valid, as a 0-based index; -1 when this scan finds
// nothing wrong. It does not build values and it is not the authority on validity - bigParse is.
// It exists because the engine's message is not a location: node reports the two commonest
// hand-edit mistakes (a stray comma, a trailing comma) as "Unexpected token ','" with NO position
// at all, and "show where it fails" is the whole point of the parse-fail
// state. Anything this scan accepts but bigParse rejects falls back to errorPoint below.
export function jsonFailIndex(text) {
  const t = String(text ?? '');
  const n = t.length;
  let i = 0;
  let bad = -1;
  const fail = (at) => { if (bad < 0) bad = at; return false; };
  const at = () => (i < n ? i : n);
  const ws = () => { while (i < n && (t[i] === ' ' || t[i] === '\n' || t[i] === '\r' || t[i] === '\t')) i++; };

  function string() {                       // t[i] === '"'
    i++;
    while (i < n) {
      const c = t[i];
      if (c === '\\') { i += 2; continue; }
      if (c === '"') { i++; return true; }
      if (c === '\n' || c === '\r') return fail(i);   // a raw newline inside a string is invalid JSON
      i++;
    }
    return fail(n);
  }
  function number() {
    const start = i;
    if (t[i] === '-') i++;
    const dStart = i;
    while (i < n && t[i] >= '0' && t[i] <= '9') i++;
    if (i === dStart) return fail(start);
    if (t[i] === '.') { i++; const d = i; while (i < n && t[i] >= '0' && t[i] <= '9') i++; if (i === d) return fail(at()); }
    if (t[i] === 'e' || t[i] === 'E') { i++; if (t[i] === '+' || t[i] === '-') i++; const d = i; while (i < n && t[i] >= '0' && t[i] <= '9') i++; if (i === d) return fail(at()); }
    return true;
  }
  function object() {
    i++;                                    // '{'
    ws();
    if (t[i] === '}') { i++; return true; }
    for (;;) {
      ws();
      if (t[i] !== '"') return fail(at());
      if (!string()) return false;
      ws();
      if (t[i] !== ':') return fail(at());
      i++;
      if (!value()) return false;
      ws();
      if (t[i] === ',') { i++; continue; }
      if (t[i] === '}') { i++; return true; }
      return fail(at());
    }
  }
  function array() {
    i++;                                    // '['
    ws();
    if (t[i] === ']') { i++; return true; }
    for (;;) {
      if (!value()) return false;
      ws();
      if (t[i] === ',') { i++; continue; }
      if (t[i] === ']') { i++; return true; }
      return fail(at());
    }
  }
  function value() {
    ws();
    if (i >= n) return fail(n);
    const c = t[i];
    if (c === '{') return object();
    if (c === '[') return array();
    if (c === '"') return string();
    if (c === '-' || (c >= '0' && c <= '9')) return number();
    if (t.startsWith('true', i)) { i += 4; return true; }
    if (t.startsWith('false', i)) { i += 5; return true; }
    if (t.startsWith('null', i)) { i += 4; return true; }
    return fail(i);
  }

  if (!value()) return bad;
  ws();
  if (i < n) return i;                      // junk after the document
  return bad;
}

// 1-based line/column of an index. EOF is a real position - a truncated file fails THERE.
export function lineColOf(text, index) {
  const t = String(text ?? '');
  const idx = Math.max(0, Math.min(index, t.length));
  let line = 1, start = 0;
  for (let i = 0; i < idx; i++) if (t[i] === '\n') { line++; start = i + 1; }
  return { line, col: idx - start + 1 };
}

// The engine message as a last-resort locator, both dialects: V8 puts an absolute position in the
// text, SpiderMonkey gives line/column only. -1 rather than a guess - a caret in the wrong place
// is worse than no caret.
export function errorPoint(message, text) {
  const m = String(message || '');
  const pos = m.match(/position (\d+)/i);
  if (pos) return Number(pos[1]);
  const lc = m.match(/line (\d+) column (\d+)/i);
  if (!lc) return -1;
  const t = String(text ?? '');
  const wantLine = Number(lc[1]), wantCol = Number(lc[2]);
  let line = 1, start = 0;
  for (let i = 0; i < t.length && line < wantLine; i++) if (t[i] === '\n') { line++; start = i + 1; }
  return Math.min(start + wantCol - 1, t.length);
}

// Does this text hold a document the structured side can be built from, and if not, WHERE does it
// stop? null means it parses. bigParse is the authority (it is what the projection itself uses),
// so nothing can be reported unparseable that the editor would happily mount.
export function parseFailure(text) {
  const t = String(text ?? '');
  try { bigParse(t); return null; } catch (err) {
    const message = String((err && err.message) || err || 'invalid JSON');
    let idx = jsonFailIndex(t);
    if (idx < 0) idx = errorPoint(message, t);
    if (idx < 0) idx = t.length;
    const { line, col } = lineColOf(t, idx);
    const source = t.split('\n')[line - 1] ?? '';
    // Pad the caret with the SOURCE's own whitespace, so it still lands under the column in a
    // <pre> where a tab is eight columns wide and a space is one.
    let caret = '';
    for (let i = 0; i < col - 1; i++) caret += source[i] === '\t' ? '\t' : ' ';
    return { pos: idx, line, col, message, source, caret: caret + '^' };
  }
}

// --------------------------------------------------------------------------------- who owns the edit
// The answer to a click on the pane that is NOT currently editing.
//   { ok, needsConfirm, message, failure }
// ok:false     - that side cannot take the document; render `failure`, keep the text as typed
// needsConfirm - the current side has diverged since it was projected; ask before re-projecting
export function switchIntent(to, { current, projected } = {}) {
  const cur = current ?? '';
  if (to === STRUCTURED) {
    const failure = parseFailure(cur);
    if (failure) {
      return {
        ok: false,
        needsConfirm: false,
        failure,
        message: 'The raw text does not parse as JSON - line ' + failure.line + ', column ' + failure.col + '.\n\n'
          + 'Nothing is discarded: your text is held exactly as you typed it. Fix the error and the structured view comes back.',
      };
    }
  }
  if (cur === (projected ?? '')) return { ok: true, needsConfirm: false, message: '', failure: null };
  const lost = to === STRUCTURED
    ? 'Switching re-projects the document into the structured view. Your values are kept; your own formatting in the raw text is re-written (2-space indent).'
    : 'Switching re-writes the raw text from the document you edited on the structured side. Your values are kept; the raw text is re-formatted (2-space indent).';
  const side = to === STRUCTURED ? 'raw text' : 'structured';
  return {
    ok: true,
    needsConfirm: true,
    failure: null,
    message: 'You have unsaved edits on the ' + side + ' side.\n\n' + lost + '\n\nSwitch sides?',
  };
}

// The document's OWN indentation, so writing it back does not re-format it. Every config on the
// box and every frozen .defaults copy is four-space indented; serialising at a hardcoded two would
// turn every save into a whole-file re-indent and make the compare view report every line as
// changed.
export function detectIndent(text) {
  const t = String(text ?? '');
  const m = t.match(/\n([ \t]+)\S/);
  return m ? m[1] : '  ';
}

// Both copies re-serialised the same way, so a formatting difference stops reading as a change.
// null when the text does not parse - never a half-truth.
export function canonicalJson(text, indent) {
  // restoreBigInts, or a Steam64 comes back as its sentinel string and the compare view shows a
  // difference that exists only in the encoding.
  try { return restoreBigInts(JSON.stringify(bigParse(String(text ?? '')), null, indent || '  ')); }
  catch (_) { return null; }
}

// Is the projection still a true picture of the document, or has the owning side moved on?
// A projection is COMMITTED, never continuously recomputed: rebuilding the other side costs a full
// parse and a full widget build, which would stall the editor being typed in. So the other side is
// allowed to fall behind, is SAID to be behind, and catches up when asked. Never projected (null)
// is out of date, not "in sync" - the pane has nothing in it to trust.
export function projectionStatus(current, projectedFrom) {
  const stale = projectedFrom == null || current !== projectedFrom;
  return { stale, label: stale ? 'out of date' : 'in sync' };
}

// Dirty, with two sides in play. The structured side re-serialises the document just by owning it,
// so its output is never byte-identical to the file on the box even with zero edits - a byte
// comparison there would open every owned JSON surface already-dirty. Data decides
// on that side. On the RAW side the bytes ARE the document: an admin who typed a blank line meant
// it, and a data-only comparison would refuse to save it.
export function isDocDirty(draft, baseText, opts = {}) {
  if (draft == null || draft === baseText) return false;
  if (!opts.isJson) return true;
  if (opts.rawEdited) return true;
  return !jsonEquivalent(draft, baseText);
}
