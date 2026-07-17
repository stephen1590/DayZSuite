// lossless-json.js — big-integer-preserving JSON for the DayZ Config UI.
// BROWSER COPY of Api/app/src/lossless-json.ts — keep the two in sync.
//
// JavaScript numbers are IEEE-754 doubles: every integer above 2^53 silently snaps to the
// nearest representable double. A Steam64 ID typed as 76561198065425750 became
// 76561198065425740 on every save (proven 2026-07-17). This module keeps integer literals
// EXACT end to end:
//   bigParse:     big integer literals in the JSON TEXT become sentinel strings BEFORE
//                 JSON.parse ever sees them — no double is ever created
//   bigStringify: sentinel strings are unwrapped back to bare literals AFTER stringify
// The API server does the same on its side and normalizes to bare literals on disk.

// Written as an explicit escape ON PURPOSE — a raw U+E000 in source is invisible, and if an
// editor ever stripped it the restore regex would degrade to unquoting EVERY numeric string.
export const BIG = '\uE000';

// Any pure-integer literal with 16+ digits may exceed 2^53; preserve them all (restoring a
// safe 16-digit value is byte-identical anyway).
const MIN_DIGITS = 16;

// Rewrite JSON text so big integer literals become sentinel strings. Real in-string
// tracking (digits inside string values are never touched); pre-existing sentinel chars
// inside strings are stripped so crafted input can't forge a literal through restore.
export function preserveBigInts(text) {
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
      let j = i;
      if (text[j] === '-') j++;
      const dStart = j;
      while (j < text.length && text[j] >= '0' && text[j] <= '9') j++;
      const digits = j - dStart;
      let isFloat = false;
      if (text[j] === '.') { isFloat = true; j++; while (j < text.length && text[j] >= '0' && text[j] <= '9') j++; }
      if (text[j] === 'e' || text[j] === 'E') { isFloat = true; j++; if (text[j] === '+' || text[j] === '-') j++; while (j < text.length && text[j] >= '0' && text[j] <= '9') j++; }
      const tok = text.slice(i, j);
      out += (!isFloat && digits >= MIN_DIGITS) ? '"' + BIG + tok + '"' : tok;
      i = j; continue;
    }
    out += c; i++;
  }
  return out;
}

// Unwrap sentinel strings back to bare integer literals (inverse of preserveBigInts).
export function restoreBigInts(text) {
  return text.replace(new RegExp('"' + BIG + '(-?\\d+)"', 'g'), '$1');
}

// JSON.parse that keeps big integer literals exact (as sentinel strings in memory).
export function bigParse(text) {
  return JSON.parse(preserveBigInts(text));
}

// JSON.stringify that writes big integer literals back out exactly.
export function bigStringify(value, space) {
  return restoreBigInts(JSON.stringify(value, null, space));
}
