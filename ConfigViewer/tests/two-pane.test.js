// Two-pane editing (raw CM6 + structured navigator over ONE document): default to the raw text
// editor, render the structured side when it can parse, and highlight the side that owns the
// edit in a gold box.
//
// The RULE is what lives here, so every two-pane editor gets the same answers:
//   - which side may take the edit, and when the user must be warned first
//   - where an unparseable raw buffer fails, so the structured side can SAY so instead of
//     rendering a stale tree beside text that no longer produces it
//   - what counts as dirty when one side re-serialises the document just by owning it
// The DOM wiring stays in own-editor.js.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  RAW, STRUCTURED, jsonFailIndex, lineColOf, errorPoint, parseFailure, switchIntent, isDocDirty,
} from '../web/js/two-pane.js';

// --------------------------------------------------------------------------- locate the failure
// The engine's own message is not a location: node 22 reports "Unexpected token ','" with NO
// position for the two most common hand-edit mistakes (a stray comma and a trailing comma).
// So the scan below is the primary locator and the engine's message is the fallback.

test('jsonFailIndex: a valid document has no failure point', () => {
  for (const ok of [
    '{}', '[]', '{"a":1}', '  {"a": [1, 2.5, -3e-7, true, false, null]}  ',
    '{"a":{"b":[{"c":"x"}]}}', '{"s":"quote \\" and \\\\ and \\u00e9"}', '"top level string"', '7',
  ]) assert.equal(jsonFailIndex(ok), -1, ok);
});

test('jsonFailIndex: a stray comma where a value belongs points AT the comma', () => {
  const t = '{\n  "a": 1,\n  "b": ,\n}';
  assert.equal(jsonFailIndex(t), t.indexOf('"b": ,') + 5);
});

test('jsonFailIndex: a missing comma between properties points at the next key', () => {
  const t = '{\n  "a": 1\n  "b": 2\n}';
  assert.equal(jsonFailIndex(t), t.indexOf('"b"'));
});

test('jsonFailIndex: a trailing comma in an array points at the closing bracket', () => {
  const t = '{\n  "xs": [1, 2,]\n}';
  assert.equal(jsonFailIndex(t), t.indexOf(']'));
});

test('jsonFailIndex: an unterminated string fails at the end of the text', () => {
  const t = '{"a": "x}';
  assert.equal(jsonFailIndex(t), t.length);
});

test('jsonFailIndex: a raw newline inside a string is where it breaks', () => {
  const t = '{"a": "one\ntwo"}';
  assert.equal(jsonFailIndex(t), t.indexOf('\n'));
});

test('jsonFailIndex: a truncated document fails at the end', () => {
  const t = '{"a": {"b": 1';
  assert.equal(jsonFailIndex(t), t.length);
});

test('jsonFailIndex: junk after the document is reported where it starts', () => {
  const t = '{"a": 1} oops';
  assert.equal(jsonFailIndex(t), t.indexOf('oops'));
});

test('jsonFailIndex: empty and whitespace-only text fail at the end', () => {
  assert.equal(jsonFailIndex(''), 0);
  assert.equal(jsonFailIndex('   \n  '), 6);
});

test('jsonFailIndex: an unquoted key points at the key', () => {
  const t = '{\n  Name: "b"\n}';
  assert.equal(jsonFailIndex(t), t.indexOf('Name'));
});

test('lineColOf: 1-based line and column, counted from the index', () => {
  const t = 'a\nbc\ndef';
  assert.deepEqual(lineColOf(t, 0), { line: 1, col: 1 });
  assert.deepEqual(lineColOf(t, 2), { line: 2, col: 1 });
  assert.deepEqual(lineColOf(t, 4), { line: 2, col: 3 });
  assert.deepEqual(lineColOf(t, 7), { line: 3, col: 3 });
  assert.deepEqual(lineColOf(t, t.length), { line: 3, col: 4 });   // EOF is a real position
});

test('errorPoint: reads the V8 form ("at position N")', () => {
  const t = '{"a": 1';
  assert.equal(errorPoint("Expected ',' or '}' after property value in JSON at position 7 (line 1 column 8)", t), 7);
});

test('errorPoint: reads the SpiderMonkey form (line/column, no position)', () => {
  const t = 'a\nbc\ndef';
  // line 2 column 3 -> index 4
  assert.equal(errorPoint('JSON.parse: unexpected character at line 2 column 3 of the JSON data', t), 4);
});

test('errorPoint: a message with neither form yields -1, never a guess', () => {
  assert.equal(errorPoint('Unexpected end of JSON input', 'x'), -1);
  assert.equal(errorPoint('', 'x'), -1);
});

// --------------------------------------------------------------------------- the parse-fail state

test('parseFailure: a document that parses has no failure', () => {
  assert.equal(parseFailure('{"a": [1, 2]}'), null);
  assert.equal(parseFailure('{"steam64": 76561198065425750}'), null);   // big ints go through bigParse
});

test('parseFailure: names the line, the column and the source line that broke', () => {
  const t = '{\n  "a": 1,\n  "b": ,\n}';
  const f = parseFailure(t);
  assert.equal(f.line, 3);
  assert.equal(f.col, 8);                       // the comma, 1-based, in '  "b": ,'
  assert.equal(f.source, '  "b": ,');
  assert.equal(f.caret, '       ^');            // 7 pad chars then the marker
  assert.ok(f.message.length > 0, 'the engine message is carried through');
});

test('parseFailure: the caret pads with the SOURCE whitespace so it lines up under a tab', () => {
  const t = '{\n\t"a" 1\n}';
  const f = parseFailure(t);
  assert.equal(f.source, '\t"a" 1');
  assert.equal(f.caret[0], '\t', 'a tab is padded with a tab, or the marker sits in the wrong place');
});

test('parseFailure: an empty buffer is a failure, not an empty document', () => {
  const f = parseFailure('');
  assert.ok(f, 'empty text must not read as a valid document');
  assert.equal(f.line, 1);
});

// --------------------------------------------------------------------------- who owns the edit

test('switchIntent: the structured side cannot take a document that does not parse', () => {
  const r = switchIntent(STRUCTURED, { current: '{"a": ,}', projected: '{"a": ,}' });
  assert.equal(r.ok, false);
  assert.ok(r.failure, 'the caller needs the failure to render it');
  assert.match(r.message, /line 1/);
  assert.match(r.message, /not discarded|held/i, 'the user must be told their text is kept');
});

test('switchIntent: no divergence switches silently - a projection is not a decision', () => {
  const same = '{"a": 1}';
  const r = switchIntent(STRUCTURED, { current: same, projected: same });
  assert.equal(r.ok, true);
  assert.equal(r.needsConfirm, false);
  assert.equal(r.message, '');
});

test('switchIntent: raw edits diverge, so switching to the structured side warns first', () => {
  const r = switchIntent(STRUCTURED, { current: '{"a": 2}', projected: '{"a": 1}' });
  assert.equal(r.ok, true);
  assert.equal(r.needsConfirm, true);
  assert.match(r.message, /raw/i);
  assert.match(r.message, /format/i, 'the warning must name what switching costs');
});

test('switchIntent: structured edits diverge, so switching back to raw warns first', () => {
  const r = switchIntent(RAW, { current: '{"a": 2}', projected: '{"a": 1}' });
  assert.equal(r.ok, true);
  assert.equal(r.needsConfirm, true);
  assert.match(r.message, /structured/i);
});

test('switchIntent: the raw side always accepts the document - it is text, it cannot fail to hold it', () => {
  const r = switchIntent(RAW, { current: '{"a": ,}', projected: '{"a": 1}' });
  assert.equal(r.ok, true);
});

// --------------------------------------------------------------------------- dirty, with two sides

test('isDocDirty: no draft, or a draft equal to the file, is clean', () => {
  assert.equal(isDocDirty(null, '{"a":1}', { isJson: true }), false);
  assert.equal(isDocDirty('{"a":1}', '{"a":1}', { isJson: true }), false);
});

test('isDocDirty: for XML the bytes ARE the document', () => {
  assert.equal(isDocDirty('<a> </a>', '<a></a>', { isJson: false }), true);
});

test('isDocDirty: re-serialising a JSON file by switching sides is NOT an edit', () => {
  // what the structured side produces from an unedited file: same data, different bytes
  assert.equal(isDocDirty('{\n  "a": 1\n}', '{"a":1}', { isJson: true, rawEdited: false }), false);
});

test('isDocDirty: a byte-level edit typed in the RAW pane counts, even with no data change', () => {
  // formatting is content when the admin typed it - byte comparison is right on that side only
  assert.equal(isDocDirty('{\n  "a": 1\n}', '{"a":1}', { isJson: true, rawEdited: true }), true);
});

test('isDocDirty: a real data change is dirty from either side', () => {
  assert.equal(isDocDirty('{"a":2}', '{"a":1}', { isJson: true, rawEdited: false }), true);
  assert.equal(isDocDirty('{"a":2}', '{"a":1}', { isJson: true, rawEdited: true }), true);
});

test('isDocDirty: an unparseable draft is never reported clean', () => {
  assert.equal(isDocDirty('{"a": ,}', '{"a":1}', { isJson: true, rawEdited: false }), true);
});

// --------------------------------------------------------------------------- keep the file's shape
// Every config on the box, and every frozen .defaults, is FOUR-space indented. A hardcoded
// two-space re-serialisation on save re-indents the whole document, and the compare view then
// reports every single line as changed.
import { detectIndent, canonicalJson } from '../web/js/two-pane.js';

test('detectIndent: reads the document own indentation', () => {
  assert.equal(detectIndent('{\n    "a": 1\n}'), '    ');
  assert.equal(detectIndent('{\n  "a": 1\n}'), '  ');
  assert.equal(detectIndent('{\n\t"a": 1\n}'), '\t');
});

test('detectIndent: nested depth does not confuse it - the FIRST step is the unit', () => {
  assert.equal(detectIndent('{\n    "a": {\n        "b": 1\n    }\n}'), '    ');
});

test('detectIndent: a minified or single-line document falls back to two spaces', () => {
  assert.equal(detectIndent('{"a":1}'), '  ');
  assert.equal(detectIndent(''), '  ');
  assert.equal(detectIndent(null), '  ');
});

test('detectIndent: ignores blank and whitespace-only lines', () => {
  assert.equal(detectIndent('{\n\n    "a": 1\n}'), '    ');
});

test('canonicalJson: re-serialises both sides the same way so formatting stops reading as change', () => {
  const a = '{\n    "a": 1,\n    "b": [1,2]\n}';
  const b = '{\n  "a": 1,\n  "b": [ 1, 2 ]\n}';
  assert.equal(canonicalJson(a, '  '), canonicalJson(b, '  '));
});

test('canonicalJson: a big integer survives canonicalisation exactly', () => {
  assert.match(canonicalJson('{"id": 76561198065425750}', '  '), /76561198065425750/);
});

test('canonicalJson: unparseable text returns null rather than a lie', () => {
  assert.equal(canonicalJson('{"a": ,}', '  '), null);
});

// --------------------------------------------------------------------------- commit, not follow
// Two bugs of one shape: the shipped navigator rebuilds the whole document map into innerHTML on
// every change (json-editor-ui scheduleRerender), and an unshipped two-pane editor re-projected
// the other side on a debounce after every edit. Both make the editor you are typing in stall on
// work you did not ask for. A projection is now COMMITTED: the other side goes visibly out of
// date and catches up when you say so.
import { projectionStatus } from '../web/js/two-pane.js';

test('projectionStatus: the projection is in sync when it matches what it was built from', () => {
  const s = projectionStatus('{"a": 1}', '{"a": 1}');
  assert.equal(s.stale, false);
  assert.match(s.label, /sync/i);
});

test('projectionStatus: ANY change to the owning side marks it out of date', () => {
  assert.equal(projectionStatus('{"a": 2}', '{"a": 1}').stale, true);
  assert.equal(projectionStatus('{"a": 1} ', '{"a": 1}').stale, true, 'whitespace counts - the projection was built from other bytes');
});

test('projectionStatus: never projected reads out of date, never "in sync"', () => {
  assert.equal(projectionStatus('{"a": 1}', null).stale, true);
  assert.equal(projectionStatus('{"a": 1}', undefined).stale, true);
});

test('projectionStatus: the label says what to do, so the pane never just looks broken', () => {
  assert.match(projectionStatus('{"a": 2}', '{"a": 1}').label, /out of date/i);
});

// Regression gates for the actual complaint. Source-level, and stated as such: they prove the
// per-change rebuild mechanisms are GONE, not that the replacement feels good in a browser.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
const JS = (f) => readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../web/js/', f), 'utf8');

test('own-editor: editing never schedules an automatic re-projection', () => {
  const src = JS('own-editor.js');
  assert.doesNotMatch(src, /scheduleMirror|PROJECT_DEBOUNCE_MS/,
    'a debounced re-projection is the freeze the owner reported - the other side updates on commit only');
  assert.match(src, /commitTo/, 'and there must BE a commit path, or the other side can never catch up');
});

test('opening a file does not build the structured side (owner 2026-08-04, second report)', () => {
  // json-editor builds EVERY node eagerly - json-editor-ui says so in its own big-file comment,
  // and collapseLargeOver exists because of it. Building it at open means every owned file pays a
  // thousands-of-widgets construction before the raw editor can be typed in. Raw owns the document
  // by default, so raw is the only side that has to exist by default.
  const src = JS('own-editor.js');
  const i = src.indexOf('export async function renderOwnEditor');
  assert.ok(i > 0, 'renderOwnEditor must exist to be checked');
  const body = src.slice(i);
  assert.doesNotMatch(body, /await projectStructured/,
    'mounting the editor must not build the projection - it is committed on demand, like every other projection here');
});

test('typing costs nothing per keystroke (owner: "I can\'t even finish typing a variable")', () => {
  // The update listener ran on EVERY keypress and did two O(document) things: serialised the whole
  // buffer to a string for dirty tracking, and re-answered "is this dirty" by scanning both copies.
  // On a real config that is hundreds of KB allocated per character typed.
  const src = JS('own-editor.js');
  const i = src.indexOf('updateListener.of');
  assert.ok(i > 0, 'the raw editor must have an update listener to check');
  const listener = src.slice(i, i + 900);
  assert.doesNotMatch(listener, /doc\.toString\(\)/,
    'serialising the document on every keystroke is the typing stall');
  assert.doesNotMatch(listener, /isDirtySt|jsonEquivalent/,
    'a full dirty comparison per keystroke is the same cost wearing a different hat - cache the flag');
});

test('the structured side does not serialise the document on every change', () => {
  const src = JS('own-editor.js');
  const i = src.indexOf('onChange: () => {');
  assert.ok(i > 0, 'the navigator onChange must exist to check');
  assert.doesNotMatch(src.slice(i, i + 500), /jsonEnc\(/,
    'jsonEnc walks the whole document - it belongs on commit and save, not on keypress');
});

// The editor edits (sync, save, discard) and nothing else. Comparing is a VIEW, per file,
// reached by the same segment switcher every other row already uses.
test('the editor carries no diff at all - not inline, not as a toggle', () => {
  const src = JS('own-editor.js');
  const i = src.indexOf('function mountRaw');
  const mount = src.slice(i, src.indexOf('\n}', i));
  assert.doesNotMatch(mount, /unifiedMergeView/,
    'an inline diff re-diffs the whole document on every change AND is unreadable when the file has diverged');
  assert.doesNotMatch(src, /id="ownDiff"|diffComp/, 'no toggle either - comparing is a separate view now');
});

test('comparing is a separate view with a side-by-side renderer', () => {
  const src = JS('own-editor.js');
  assert.match(src, /export async function renderOwnCompare/, 'the compare view needs its own entry point');
  assert.match(src, /MergeView/, 'side-by-side means CodeMirror MergeView, not a unified gutter');
  assert.match(src, /collapseUnchanged/,
    'unchanged regions must collapse, or a drastically diverged file opens on 50+ lines of red - the owner exact complaint');
});

test('leaving the editor captures the document first - a view switch must not eat edits', () => {
  // Dirty tracking stopped serialising per keystroke, so st.draft is only current at transitions.
  // Both entry points tear the body down; if they do that before capturing, switching to Compare
  // and back re-mounts from a stale draft and the typed edits are gone.
  const src = JS('own-editor.js');
  for (const fn of ['renderOwnEditor', 'renderOwnCompare']) {
    const i = src.indexOf('export async function ' + fn);
    const head = src.slice(i, i + 400);
    assert.match(head, /captureDraft\(prev\)/, fn + ' must capture the live document before replacing the body');
    assert.ok(head.indexOf('captureDraft') < head.indexOf('body.innerHTML'), fn + ' captures BEFORE the teardown, not after');
  }
});

test('the editor writes the file back in ITS OWN indentation, not a hardcoded one', () => {
  const src = JS('own-editor.js');
  assert.doesNotMatch(src, /JSON\.stringify\(v, null, 2\)/,
    'a hardcoded indent re-formats every file that does not already use it - the source of the diff noise');
  assert.match(src, /detectIndent/, 'the indent comes from the document');
});

test('the compare view diffs accurately on a real config, and can ignore formatting', () => {
  const src = JS('own-editor.js');
  const i = src.indexOf('export async function renderOwnCompare');
  const view = src.slice(i);
  assert.match(view, /diffConfig/, 'CodeMirror scanLimit defaults to 500 - a real config blows past it and the alignment degrades');
  assert.match(view, /canonicalJson/, 'and an already-reformatted file needs a compare that ignores formatting');
});

test('compare OPENS formatting-blind - raw bytes is the opt-in (owner 2026-08-04)', () => {
  // A byte-for-byte compare against a re-indented file reports the whole file as changed and
  // tells you nothing. Values-first is the useful landing state; raw bytes stays one click away
  // because it is the truth about what is on disk.
  const src = JS('own-editor.js');
  assert.match(src, /cmpNormalise: true/, 'the compare view must open formatting-blind');
  const i = src.indexOf('export async function renderOwnCompare');
  assert.match(src.slice(i), /st\.cmpNormalise && !isXml\(st\)/,
    'and it must stay off for XML, which has no canonical form here');
});

test('the compare view is syntax-highlighted, from the SAME palette as the editor', () => {
  // The first cut of the compare view had neither the language nor the palette - two plain-text
  // panes.
  const src = JS('own-editor.js');
  assert.equal((src.match(/HighlightStyle\.define/g) || []).length, 1,
    'one palette definition only - a second copy is how two surfaces drift apart');
  const i = src.indexOf('export async function renderOwnCompare');
  assert.match(src.slice(i), /syntaxExts\(st, CM\)/, 'the compare panes must use it too');
});

test('owned rows offer Editor and Compare, and open on the EDITOR', () => {
  const src = JS('editor.js');
  const i = src.indexOf('function ownChrome');
  const chrome = src.slice(i, src.indexOf('\n}', i));
  assert.match(chrome, /data-v="edit"/, 'the editor segment');
  assert.match(chrome, /data-v="compare"/, 'the compare segment');
  assert.match(src, /renderOwnCompare/, 'and renderBody must route to it');
  // default view for an owned row is the editor: comparing is opt-in, never the landing view
  assert.match(src, /edView = row\.types \? 'types'/, 'the default-view rule must still be one expression');
  assert.doesNotMatch(src, /edView = 'compare'/, 'nothing may default a row into the compare view');
});

test('the navigator does not rebuild the whole JSON map on every change', () => {
  const src = JS('json-editor-ui.js');
  assert.doesNotMatch(src, /scheduleRerender/,
    'this rebuilt jsonPane.innerHTML from the entire document on every keystroke - the "perpetual updating" the owner hit');
});
