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
const SAVE_PATHS = [
  ['editor.js', 'saveOverrides'],       // the overrides doc (names the edited files, not the transport)
  ['own-editor.js', 'doSave'],          // whole owned file
  ['types-editor.js', 'doSave'],        // types tuning
  ['map.js', 'savePatrolEdit'],         // patrols (whole AIPatrolSettings doc)
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
  assert.equal(inlineCopies, 1, 'ovr-unsaved markup must exist once (dirtyPillHtml) - three copies is the god-file pattern E4 removed');
});
