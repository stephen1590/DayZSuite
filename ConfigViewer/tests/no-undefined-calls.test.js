// Every function a shipped module CALLS must be defined or imported in that module.
//
// A deleted function whose call sites survive produces a ReferenceError only at runtime, in the
// browser, on the exact code path that still calls it:
//   - module-parse.test.js parses each file. A call to a missing function is VALID SYNTAX.
//   - no test renders a DOM, so no test executes that code path to trip it.
// This closes that gap statically - no browser, no DOM, no fixtures.
//
// LIMITS, stated so nobody trusts this further than it goes: it is a lexical scan, not a
// scope-aware one. It sees top-level declarations and imports; a name only ever defined as a
// nested helper or a destructured callback param can produce a false positive, in which case
// add it to KNOWN below WITH a reason. It does not check arity, types, or member calls
// (`foo.bar()`), and it cannot see runtime property access. It catches deletions. That is the job.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const JS_DIR = join(dirname(fileURLToPath(import.meta.url)), '../web/js');
const files = readdirSync(JS_DIR).filter((f) => f.endsWith('.js') && !f.endsWith('.test.js'));

// Language keywords and platform globals. `foo(` after one of these is a control-flow construct
// or a built-in, not a call into module code.
const GLOBALS = new Set([
  'if', 'for', 'while', 'switch', 'catch', 'return', 'typeof', 'function', 'await', 'new',
  'else', 'do', 'try', 'in', 'of', 'delete', 'void', 'yield', 'async', 'super', 'this', 'throw',
  'Set', 'Map', 'WeakMap', 'Object', 'Array', 'JSON', 'Number', 'String', 'Boolean', 'Symbol',
  'RegExp', 'Math', 'Date', 'Promise', 'Error', 'TypeError', 'Proxy', 'BigInt', 'Intl',
  'parseInt', 'parseFloat', 'isFinite', 'isNaN', 'structuredClone', 'queueMicrotask',
  'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'requestAnimationFrame',
  'encodeURIComponent', 'decodeURIComponent', 'encodeURI', 'decodeURI', 'btoa', 'atob',
  'console', 'window', 'document', 'fetch', 'alert', 'confirm', 'prompt', 'URL', 'URLSearchParams',
  'Blob', 'FormData', 'Headers', 'Request', 'Response', 'AbortController', 'TextEncoder',
  'TextDecoder', 'Image', 'Event', 'CustomEvent', 'DOMParser', 'XMLSerializer', 'MutationObserver',
  'ResizeObserver', 'IntersectionObserver', 'localStorage', 'sessionStorage', 'navigator', 'crypto',
  'getComputedStyle', 'Uint8Array', 'Uint16Array', 'Uint32Array', 'Int8Array', 'Float32Array',
  'Float64Array', 'ArrayBuffer', 'DataView', 'import',
]);

// name -> why it is exempt. Empty today; every future entry needs a reason, not just a name.
const KNOWN = new Map();

// TWO passes, deliberately different strengths.
//
// CALLS are read from a heavily stripped copy (comments, strings, template literals, regex
// literals) because a word before '(' inside prose or a pattern is not a call.
// DECLARATIONS are read from a copy with COMMENTS ONLY removed. The aggressive stripper is
// regex-based and can over-match - in highlight.js its regex-literal rule swallowed the whole
// span containing `function hlXml`, which then read as an undefined call to itself. Stripping
// comments cannot run away like that, and the failure mode is right: an over-generous
// declaration set only ever misses a bug, while an over-eager stripper INVENTS one.
const stripComments = (src) => src
  .replace(/\/\*[\s\S]*?\*\//g, ' ')
  .replace(/(^|[^:])\/\/[^\n]*/g, '$1 ');
function codeOnly(src) {
  return stripComments(src)
    .replace(/`(?:\\[\s\S]|\$\{[^}]*\}|[^\\`])*`/g, '``')
    .replace(/'(?:\\[\s\S]|[^\\'])*'/g, "''")
    .replace(/"(?:\\[\s\S]|[^\\"])*"/g, '""')
    // Regex literals LAST, once quotes are gone. A pattern like /ExpLog_(\d+)/ otherwise reads
    // as a call to ExpLog_. Anchored on the operators a literal can legally follow, so a
    // division sign is not mistaken for one.
    .replace(/([=(,:[!&|?{};+\-*%]|return|typeof)(\s*)\/(?![/*])(?:\\.|\[(?:\\.|[^\]])*\]|[^/\n\\])+\/[gimsuy]*/g, '$1$2 RE ');
}

function declaredIn(src, code) {
  const d = new Set();
  for (const m of code.matchAll(/(?:export\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)/g)) d.add(m[1]);
  for (const m of code.matchAll(/(?:const|let|var)\s+([A-Za-z_$][\w$]*)/g)) d.add(m[1]);
  for (const m of code.matchAll(/class\s+([A-Za-z_$][\w$]*)/g)) d.add(m[1]);
  // destructured binds + params, e.g. `const { a, b: c } = x` and `({ onDirty }) =>`
  for (const m of code.matchAll(/\{([^{}]*)\}\s*(?:=|=>|\))/g)) {
    for (const part of m[1].split(',')) {
      const name = part.split(':').pop().split('=')[0].trim();
      if (/^[A-Za-z_$][\w$]*$/.test(name)) d.add(name);
    }
  }
  // plain params, BOTH shapes: `(a, b) =>` and `function f(a, b)`. A parameter is a binding -
  // map.js:chipBar takes colorOf/countOf as callbacks and calls them, which an arrow-only
  // version of this flagged as undefined.
  for (const re of [/\(([^()]*)\)\s*=>/g, /function\s*\*?\s*[A-Za-z_$][\w$]*\s*\(([^()]*)\)/g]) {
    for (const m of code.matchAll(re)) {
      for (const part of m[1].split(',')) {
        const name = part.split('=')[0].replace(/\.\.\./, '').trim();
        if (/^[A-Za-z_$][\w$]*$/.test(name)) d.add(name);
      }
    }
  }
  for (const m of src.matchAll(/import\s*\{([^}]*)\}\s*from/g)) {
    for (const part of m[1].split(',')) d.add(part.split(' as ').pop().trim());
  }
  for (const m of src.matchAll(/import\s+([A-Za-z_$][\w$]*)\s*(?:,|from)/g)) d.add(m[1]);
  return d;
}

test('the scan has modules to check (guard is not vacuous)', () => {
  assert.ok(files.length > 5, `only found ${files.length} modules in web/js`);
});

for (const f of files) {
  test(`${f} calls nothing it does not define or import`, () => {
    const src = readFileSync(join(JS_DIR, f), 'utf8');
    const code = codeOnly(src);
    const declared = declaredIn(src, stripComments(src));
    const missing = [];
    for (const m of code.matchAll(/(?<![.\w$?])([A-Za-z_$][\w$]*)\s*\(/g)) {
      const name = m[1];
      if (declared.has(name) || GLOBALS.has(name) || KNOWN.has(name)) continue;
      if (!missing.includes(name)) missing.push(name);
    }
    assert.deepEqual(missing, [],
      `${f} calls ${missing.join(', ')} but never defines or imports it - a ReferenceError the moment that line runs`);
  });
}
