// Who may write what. Pure predicates, no DOM - so the badge contract can be tested by CALLING
// them rather than by reading the source of the module that draws the badge.

// A file the two-copy model owns whole. EDITABLE BY DEFAULT: any json/xml surface the box lists
// is own-editable unless an exception says no (view-locked, generated, map-owned, disabled,
// denied - denied paths never reach the browser at all). Mirrors dayz-ctl's _own_check default;
// the box re-enforces everything on every read and write.
export function isOwnedRel(rel) {
  return !!rel && /\.(json|xml)$/i.test(rel) && !/\.defaults\./.test(rel);
}

// THE single answer to "can this row be written". The nav badge and the editor chrome both read
// it, so the badge can never promise something the panel refuses. A fourth write path is added
// HERE, never beside a badge.
export function canWrite(r) {
  if (!r) return false;
  return !!(r.ownFile             // owned whole-file editor (own-write)
    || r.types                    // CE types editor (own-write)
    || r.access === 'own');       // explicitly granted surface - ban.txt / whitelist.txt
}
