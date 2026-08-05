// EVERY shipped browser module must parse AS A MODULE.
//
// `node --check foo.js` parses in the SCRIPT goal, which does not catch a duplicate `const NAME`
// redeclaration - the same bytes parsed as .mjs (the MODULE goal, matching the browser's
// <script type="module">) are rejected immediately. A file that passes --check can still crash
// the browser at load with "Uncaught SyntaxError: redeclaration of const".
//
// This runs every file the deploy actually ships through a MODULE-goal parse. It is cheap, it is
// total (no file list to keep in sync - it globs), and it fails the deploy before a broken bundle
// reaches a browser.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, copyFileSync, mkdtempSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const JS_DIR = join(dirname(fileURLToPath(import.meta.url)), '../web/js');
const files = readdirSync(JS_DIR).filter((f) => f.endsWith('.js') && !f.endsWith('.test.js'));

test('there are shipped modules to check (guard is not vacuous)', () => {
  assert.ok(files.length > 5, `only found ${files.length} modules in web/js`);
});

for (const f of files) {
  test(`${f} parses in the MODULE goal`, () => {
    // .mjs so node parses with the module goal - the same goal the browser uses for
    // <script type="module">. A plain `node --check foo.js` does NOT catch redeclarations here.
    const dir = mkdtempSync(join(tmpdir(), 'modparse-'));
    const as = join(dir, f.replace(/\.js$/, '.mjs'));
    try {
      copyFileSync(join(JS_DIR, f), as);
      execFileSync(process.execPath, ['--check', as], { stdio: 'pipe' });
    } catch (err) {
      const msg = (err.stderr ? err.stderr.toString() : err.message).split('\n').slice(0, 6).join('\n');
      assert.fail(`${f} is not valid as an ES module - the browser will refuse to load it:\n${msg}`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
}
