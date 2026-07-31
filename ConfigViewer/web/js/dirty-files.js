// dirty-files.js - E4 (Scale-Ready): the ONE named-dirty mechanism.
// The shell's guard and the header pill knew THAT something was unsaved; nobody
// could say WHICH files. Every editor now reports names through here, and every
// save prompts with the exact list first. Pure logic only - no DOM, so the node
// test suite (tests/dirty-files.test.js) covers it; editors keep the thin wiring.

const isComment = (k) => typeof k === 'string' && k.startsWith('_');

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
export function confirmSaveText(files) {
  return 'Save these changes?\n\nYou edited and are saving:\n' +
    files.map((f) => `  • ${f}`).join('\n');
}

// One confirm for every save path. confirmFn is injectable for tests; in the
// browser it defaults to window.confirm - the house dialog idiom.
export function confirmSave(files, confirmFn) {
  const ask = confirmFn || ((m) => window.confirm(m));
  return ask(confirmSaveText(files));
}
