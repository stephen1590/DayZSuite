// E4 wiring assertion (the P2 pattern: a design decision that CAN be asserted, IS).
// The pure logic has its own suite (dirty-files.test.js); this one guards the WIRING -
// every save path must name its files before writing. A new save path that skips the
// confirm fails here instead of shipping silently.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const JS = join(dirname(fileURLToPath(import.meta.url)), '../web/js');
const read = (f) => readFileSync(join(JS, f), 'utf8');

// file -> the save function that must confirm first
// 2026-07-31: editor.js:saveOverrides was the fourth entry. It is DELETED with the override
// engine - editor.js holds no save path at all now, it only routes a row to one of these.
const SAVE_PATHS = [
  ['own-editor.js', 'doSave'],          // whole owned file
  ['types-editor.js', 'doSave'],        // types tuning
  ['map.js', 'savePatrolEdit'],         // patrols (whole AIPatrolSettings doc)
  ['editor.js', 'saveOwnFile'],         // bans/priority/whitelist text files (configs/set-file)
];

// Body of `async function <name>(` up to the next top-level `\n}` - good enough for a
// wiring assertion and it needs no parser dependency.
function bodyOf(src, fn) {
  const start = src.indexOf(`async function ${fn}(`);
  assert.notEqual(start, -1, `${fn} not found - rename? update this test WITH the design decision`);
  const end = src.indexOf('\n}', start);
  return src.slice(start, end === -1 ? undefined : end);
}

for (const [file, fn] of SAVE_PATHS) {
  test(`${file}:${fn} confirms with the file list before writing`, () => {
    const src = read(file);
    assert.match(src, /import \{[^}]*confirmSave[^}]*\} from '\.\/dirty-files\.js'/,
      `${file} must import confirmSave from the ONE dirty-files module`);
    const body = bodyOf(src, fn);
    assert.match(body, /confirmSave\(/, `${fn} must call confirmSave before its write`);
    const confirmAt = body.indexOf('confirmSave(');
    const postAt = body.indexOf('apiPost(');
    assert.ok(postAt === -1 || confirmAt < postAt,
      `${fn} calls apiPost before confirmSave - the prompt must come FIRST`);
  });
}

test('the dirty pill markup is rendered from ONE helper, not copied per chrome', () => {
  const src = read('editor.js');
  const inlineCopies = (src.match(/class="ovr-unsaved/g) || []).length;
  assert.equal(inlineCopies, 1, 'ovr-unsaved markup must exist once (dirtyPillHtml) - a copy per chrome is the god-file pattern this removed');
});

// The point of deleting the override engine: editor.js ROUTES, it does not write. If a save
// path reappears here, the god-file is growing back.
// editor.js keeps exactly ONE write - the bans/whitelist text files. Everything that was
// override machinery is gone; if any of these strings comes back, the god-file is regrowing.
test('the override write paths are gone from editor.js', () => {
  const src = read('editor.js');
  // Match the CALL, not the word: a comment explaining what was removed is documentation and
  // should survive; an apiPost to a deleted endpoint is a 404 waiting for a user.
  for (const ep of ['set-overrides', 'preview-override', 'override-rollback', 'target']) {
    assert.ok(!src.includes(`/dayz/configs/${ep}`),
      `editor.js calls /dayz/configs/${ep} - that endpoint is deleted; it would 404 at runtime`);
  }
});
