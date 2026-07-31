// override-status.js - what the remaining override rows on a file ACTUALLY do.
//
// Owner, 2026-07-31: "This literally says the file doesn't exist yet, but 2 overrides are
// present? Make it make sense!"
//
// Both statements were true and the UI printed them as if unrelated. Apply-ConfigOverrides
// patches a file it can open; a missing target is a warning and a skip, not a create
// (Apply-ConfigOverrides.ps1:302). So an override row against an absent file is INERT - it is
// carried in the manifest, logged as [WARN] file not found at every prestart, and changes
// nothing. Proven on staging 2026-07-31: 15 such rows across 7 file targets, each one warned
// and skipped in the 21:35 prestart, against 134 rows that do apply.
//
// A count alone reads as "these values are being forced on this file". When the file is not
// there, that is the opposite of the truth. One function decides the wording so the chrome
// summary and the file-view panel cannot tell the owner two different stories.
//
// file: the fetchRowFile() result - { text, err } - or null/undefined if not fetched yet.
//   err === 'ABSENT'  -> the box answered 404: allowlisted, nothing there.
//   any other err     -> we do NOT know. Never guess in either direction.
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

export function overrideStatus(count, file) {
  const n = count || 0;
  if (n === 0) return { kind: 'none', warn: false, text: 'owned whole - edits save the entire file' };

  // Three states, not two. 'signed out' / a 500 means we could not look - that is NOT evidence
  // the file is missing, and it is not evidence it is there either.
  const present = !!(file && file.text != null);
  const absent = !!(file && file.text == null && file.err === 'ABSENT');
  const known = present || absent;

  if (absent) {
    return {
      kind: 'dead',
      warn: true,
      text: `${plural(n, 'override row')} here target a file that is not on the box, so the box `
        + 'logs "file not found" and skips them at every restart. They change nothing today. '
        + 'They are listed below so they can be dropped or moved onto the owned file.',
    };
  }
  if (!known) {
    return { kind: 'unknown', warn: false, text: `${plural(n, 'override row')} on this file - checking the box copy…` };
  }
  return {
    kind: 'live',
    warn: false,
    text: `${plural(n, 'value')} here are still managed by the old override system - the box `
      + 're-applies them at every restart, so a whole-file edit to any of these will not stick '
      + 'until this file is owned whole.',
  };
}
