// Lossless big-integer JSON (2026-07-17). JavaScript numbers are IEEE-754 doubles: every
// integer above 2^53 (9007199254740991, 16 digits) silently snaps to the nearest
// representable double — a Steam64 ID typed as 76561198065425750 became 76561198065425740
// on every web save (proven; see the DayZ Config UI incident). This module makes the whole
// pipeline preserve integer literals EXACTLY:
//
//   parse:      big integer literals in the JSON TEXT are wrapped as sentinel strings
//               ("<digits>") BEFORE JSON.parse ever sees them, so no double is created
//   stringify:  sentinel strings are unwrapped back to bare literals AFTER JSON.stringify,
//               byte-identical to what the user typed
//
// The browser editor ships the same logic (ConfigViewer web/js/lossless-json.js — keep the
// two copies in sync); either side may hand the other sentinel-wrapped or bare values and
// the write path normalizes to bare literals on disk. Downstream consumers are already
// exact: jq (1.7+) and python3 validate losslessly in dayz-ctl, and PowerShell 7 parses
// integers as int64 in the override applier.

/** Private-use sentinel marking "this string is really a big integer literal".
 *  Written as an explicit escape ON PURPOSE - a raw U+E000 in source is invisible, and if
 *  an editor ever stripped it the restore regex would degrade to unquoting EVERY numeric
 *  string (the exact inverse of this bug). Never inline the raw character. */
export const BIG = '\uE000';

// Any pure-integer literal with 16+ digits may exceed 2^53; preserve them all (restoring a
// safe 16-digit value is byte-identical anyway). Floats/exponents stay plain numbers — the
// game's configs use them only for small values.
const MIN_DIGITS = 16;

/**
 * Rewrite JSON text so big integer literals become sentinel strings. Walks the text with a
 * real in-string tracker (never touches digits inside string values), and strips any
 * pre-existing sentinel characters inside strings so crafted input can't forge a literal
 * through the restore step.
 */
export function preserveBigInts(text: string): string {
  let out = '';
  let i = 0;
  let inStr = false;
  while (i < text.length) {
    const c = text[i];
    if (inStr) {
      if (c === '\\') { out += text.slice(i, i + 2); i += 2; continue; }
      if (c === BIG) { i++; continue; }            // strip forged sentinels
      if (c === '"') inStr = false;
      out += c; i++; continue;
    }
    if (c === '"') { inStr = true; out += c; i++; continue; }
    if (c === '-' || (c >= '0' && c <= '9')) {
      // capture one JSON number token
      let j = i;
      if (text[j] === '-') j++;
      const dStart = j;
      while (j < text.length && text[j] >= '0' && text[j] <= '9') j++;
      const digits = j - dStart;
      let isFloat = false;
      if (text[j] === '.') { isFloat = true; j++; while (j < text.length && text[j] >= '0' && text[j] <= '9') j++; }
      if (text[j] === 'e' || text[j] === 'E') { isFloat = true; j++; if (text[j] === '+' || text[j] === '-') j++; while (j < text.length && text[j] >= '0' && text[j] <= '9') j++; }
      const tok = text.slice(i, j);
      out += (!isFloat && digits >= MIN_DIGITS) ? `"${BIG}${tok}"` : tok;
      i = j; continue;
    }
    out += c; i++;
  }
  return out;
}

/** Unwrap sentinel strings back to bare integer literals (inverse of preserveBigInts). */
export function restoreBigInts(text: string): string {
  return text.replace(new RegExp(`"${BIG}(-?\\d+)"`, 'g'), '$1');
}

/** JSON.parse that keeps big integer literals exact (as sentinel strings in memory). */
export function bigParse(text: string): unknown {
  return JSON.parse(preserveBigInts(text));
}

/** JSON.stringify that writes big integer literals back out exactly. */
export function bigStringify(value: unknown, space?: number): string {
  return restoreBigInts(JSON.stringify(value, null, space));
}
