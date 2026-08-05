// dirty-files.js - the ONE named-dirty mechanism.
// The shell's guard and the header pill knew THAT something was unsaved; nobody
// could say WHICH files. Every editor now reports names through here, and every
// save prompts with the exact list first. Pure logic only - no DOM, so the node
// test suite (tests/dirty-files.test.js) covers it; editors keep the thin wiring.

// A number is "big" (kept as literal digits, never reformatted) under the exact same rule
// lossless-json.js uses to decide when to sentinel-protect it: a pure integer (no '.', no
// exponent) with 16+ digits may exceed 2^53, so it is never routed through a JS double. Anything
// else (a float, an exponent, or a short integer) is safe to reformat via Number->String, which
// is what canon() below does to match what the structured editor's own round trip produces.
const MIN_BIG_DIGITS = 16;

// Do two JSON texts hold the same document? Byte equality is the wrong question for a STRUCTURED
// editor: it re-serialises what it loaded, so its output is never byte-identical to the file on
// the box even with zero edits.
//
// Whitespace alone is not the whole story: the structured navigator's draft is the source PARSED
// to real JS numbers and re-stringified, and JS's number formatting does not reproduce the source
// spelling - a trailing ".0" on a whole-number float is dropped (0.0 -> 0) and an exponent's
// case/zero-padding is normalised (-9.999999974752427E-07 -> -9.999999974752427e-7). Same value,
// different text; comparing text alone would read that as an edit. canon() reformats each number
// token the same way JSON.stringify would, so two spellings of the same value collapse to the
// same canonical text, while whitespace and everything else stays exactly as it was.
//
// Key ORDER counts as a change on purpose - reordering a config is a real edit to the file, and
// folding it away would silently drop it. Unparseable input counts as CHANGED, never as clean:
// reporting "no changes" for a draft that does not parse would let a broken edit vanish.
//
// Big integers: compared as raw text, never through Number(), so a Steam64 ID past 2^53 cannot
// be rounded into a false match (or a false mismatch). The editors' bigParse/bigStringify pair
// owns exactness on the write path; here it is enough never to introduce a double for one.
export function jsonEquivalent(a, b) {
  const canon = (t) => {
    if (typeof t !== 'string') return null;
    // Strip insignificant whitespace and reformat number tokens, WITHOUT parsing the whole
    // document: everything outside a string literal.
    let out = '', inStr = false, esc = false;
    for (let i = 0; i < t.length; i++) {
      const ch = t[i];
      if (esc) { out += ch; esc = false; continue; }
      if (ch === '\\' && inStr) { out += ch; esc = true; continue; }
      if (ch === '"') { inStr = !inStr; out += ch; continue; }
      if (inStr) { out += ch; continue; }
      if (ch === ' ' || ch === '\n' || ch === '\r' || ch === '\t') continue;
      // A number literal outside a string: consume the whole token (same grammar
      // preserveBigInts uses) and either keep its raw digits (big int) or its JS-canonical
      // reformatting (everything else) - never JSON.stringify(JSON.parse(whole-doc)), so a
      // draft that doesn't fully parse still gets a best-effort canonical form.
      if (ch === '-' || (ch >= '0' && ch <= '9')) {
        let j = i;
        if (t[j] === '-') j++;
        const dStart = j;
        while (j < t.length && t[j] >= '0' && t[j] <= '9') j++;
        const digits = j - dStart;
        let isFloat = false;
        if (t[j] === '.') { isFloat = true; j++; while (j < t.length && t[j] >= '0' && t[j] <= '9') j++; }
        if (t[j] === 'e' || t[j] === 'E') { isFloat = true; j++; if (t[j] === '+' || t[j] === '-') j++; while (j < t.length && t[j] >= '0' && t[j] <= '9') j++; }
        const tok = t.slice(i, j);
        if (!isFloat && digits >= MIN_BIG_DIGITS) { out += tok; }
        else { const n = Number(tok); out += Number.isFinite(n) ? String(n) : tok; }
        i = j - 1;   // the for-loop's i++ advances past the token
        continue;
      }
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

// Header-pill text. Empty when clean; caps at 3 names so the pill stays a pill.
export function formatUnsaved(files) {
  if (!files || !files.length) return '';
  const shown = files.slice(0, 3).join(', ');
  const more = files.length - 3;
  return 'Unsaved: ' + shown + (more > 0 ? ` +${more} more` : '');
}

// The confirmation dialog body: tell the admin what files they edited and are currently saving,
// BEFORE the write happens.
// An EMPTY list is not a dialog - Save is always enabled, so clicking it with a clean doc would
// ask for confirmation of a write that could not be named. A prompt that lists nothing trains
// you to click through the one that matters.
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
