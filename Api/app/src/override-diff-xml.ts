// override-diff-xml.ts — the XML counterpart to override-diff.ts. Derives a config-overrides
// delta from a whole-file XML edit by diffing it against the frozen default, keyed on the CE
// convention (@name attributes), then PROVES it round-trips before trusting it.
//
// Mirrors Apply-ConfigOverrides.ps1's Set-XmlNode: a selector is an XPath that resolves to EITHER
// an attribute node (its .Value is set) or a text-leaf element (its InnerText is set); it is
// MATCH-ONLY (no create). So we only ever emit patches for nodes that exist in BOTH the default
// and the edit and differ in value — an added/removed/reshaped node can't be expressed as a patch,
// so the round-trip fails and we fall back to storing the whole file (the documented escape hatch).
//
// Fidelity: we emit only canonical, engine-agnostic XPaths — absolute paths whose every step is a
// tag plus an optional [@name='literal'] predicate — the subset where xmldom+xpath and the box's
// .NET SelectSingleNode evaluate identically. Anything that can't be addressed that way is skipped
// and caught by the round-trip. Whitespace and attribute order are ignored (a reindent alone is not
// a change), so incidental formatting never forces a whole-file override.

import { DOMParser, XMLSerializer, type Document, type Element, type Node } from '@xmldom/xmldom';
import * as xpath from 'xpath';
import type { OverrideResult } from './override-diff.js';

const ATTRIBUTE_NODE = 2;
const ELEMENT_NODE = 1;

function parseXml(text: string): Document | null {
  // xmldom throws a ParseError on fatal malformation (rather than routing every case through
  // onError), so guard with try/catch AND flag softer errors — either way a bad parse → null,
  // which deriveXmlOverride turns into a safe whole-file fallback.
  let bad = false;
  try {
    const doc = new DOMParser({ onError: (level) => { if (level === 'fatalError' || level === 'error') bad = true; } })
      .parseFromString(text, 'text/xml');
    if (bad || !doc || !doc.documentElement) return null;
    return doc;
  } catch {
    return null;
  }
}

const elementChildren = (el: Element): Element[] =>
  Array.from(el.childNodes as unknown as Node[]).filter((n) => n.nodeType === ELEMENT_NODE) as Element[];

const realAttrs = (el: Element): { name: string; value: string }[] =>
  Array.from(el.attributes as unknown as { name: string; value: string }[])
    .filter((a) => a.name !== 'xmlns' && !a.name.startsWith('xmlns:'));

const xmlLiteral = (s: string) => (s.includes("'") ? `concat('${s.split("'").join("',\"'\",'")}')` : `'${s}'`);

// This element's addressable path step, or null if it can't be canonically addressed (no @name and
// a tag shared with a sibling). Prefer @name (the CE convention); fall back to a unique bare tag.
function step(el: Element): string | null {
  const name = el.getAttribute && el.getAttribute('name');
  if (name != null && name !== '') return `${el.tagName}[@name=${xmlLiteral(name)}]`;
  const parent = el.parentNode as Element | null;
  if (parent && parent.nodeType === ELEMENT_NODE) {
    const sameTag = elementChildren(parent).filter((c) => c.tagName === el.tagName);
    if (sameTag.length > 1) return null; // ambiguous without a name
  }
  return el.tagName;
}

// Absolute canonical path to an element, or null if any ancestor step is unaddressable.
function pathOf(el: Element): string | null {
  const parts: string[] = [];
  let cur: Element | null = el;
  while (cur && cur.nodeType === ELEMENT_NODE) {
    const s = step(cur);
    if (s == null) return null;
    parts.unshift(s);
    cur = cur.parentNode as Element | null;
  }
  return '/' + parts.join('/');
}

// Every addressable leaf value: attribute values, and the text of text-only elements (no element
// children). Keyed by canonical XPath (…/@attr for attributes, the element path for text).
function indexLeaves(doc: Document): Map<string, string> {
  const map = new Map<string, string>();
  const visit = (el: Element) => {
    const base = pathOf(el);
    if (base) {
      for (const a of realAttrs(el)) map.set(`${base}/@${a.name}`, a.value);
      const kids = elementChildren(el);
      if (kids.length === 0) map.set(base, (el.textContent ?? '').trim());
    }
    for (const k of elementChildren(el)) visit(k);
  };
  visit(doc.documentElement as Element);
  return map;
}

// Candidate patches: keys present in BOTH sides whose (trimmed) value changed. Keys that appear on
// only one side (added/removed leaves) are deliberately not emitted — the round-trip rejects them.
function deriveXmlDelta(def: Document, edited: Document): Record<string, string> {
  const di = indexLeaves(def), ei = indexLeaves(edited);
  const delta: Record<string, string> = {};
  for (const [k, ev] of ei) {
    if (di.has(k) && di.get(k)!.trim() !== ev.trim()) delta[k] = ev;
  }
  return delta;
}

// Apply a delta to a fresh parse of the default, exactly as Set-XmlNode would: select the node;
// attribute → set .value; text-leaf element → replace its content with a single text node. A
// selector that matches nothing is a silent no-op (match-only), so the round-trip will catch it.
function applyXmlDelta(defaultText: string, delta: Record<string, string>): Document | null {
  const doc = parseXml(defaultText);
  if (!doc) return null;
  for (const [sel, val] of Object.entries(delta)) {
    // xpath's types target the lib DOM; xmldom's nodes are structurally compatible for our use.
    const node = xpath.select1(sel, doc as any) as unknown as (Node & { nodeType: number; value?: string }) | undefined;
    if (!node) continue;
    if (node.nodeType === ATTRIBUTE_NODE) {
      node.value = val;
    } else if (node.nodeType === ELEMENT_NODE) {
      const el = node as unknown as Element;
      while (el.firstChild) el.removeChild(el.firstChild);
      el.appendChild(doc.createTextNode(val));
    }
  }
  return doc;
}

// Canonical structure for semantic comparison: tag, sorted attributes, element children (order
// preserved), and — for text-only elements — the trimmed text. Whitespace-only text and attribute
// order are ignored, so a reindent is not a difference.
type Norm = { t: string; a: [string, string][]; c: Norm[]; x?: string };
function normalize(el: Element): Norm {
  const kids = elementChildren(el);
  const a = realAttrs(el).map((x) => [x.name, x.value] as [string, string]).sort((p, q) => (p[0] < q[0] ? -1 : p[0] > q[0] ? 1 : 0));
  const n: Norm = { t: el.tagName, a, c: kids.map(normalize) };
  if (kids.length === 0) n.x = (el.textContent ?? '').trim();
  return n;
}
function xmlSemanticEqual(a: Document, b: Document): boolean {
  return JSON.stringify(normalize(a.documentElement as Element)) === JSON.stringify(normalize(b.documentElement as Element));
}

export function deriveXmlOverride(defaultText: string | null, editedText: string): OverrideResult {
  const edited = parseXml(editedText);
  if (!edited) return { mode: 'wholefile', reason: 'edited file is not well-formed XML' };
  if (defaultText == null) return { mode: 'wholefile', reason: 'no frozen default to diff against' };
  const def = parseXml(defaultText);
  if (!def) return { mode: 'wholefile', reason: 'frozen default is not well-formed XML' };

  const delta = deriveXmlDelta(def, edited);
  const applied = applyXmlDelta(defaultText, delta);
  if (applied && xmlSemanticEqual(applied, edited)) {
    return { mode: 'delta', delta, changed: Object.keys(delta).length };
  }
  return { mode: 'wholefile', reason: 'edit could not be expressed as attribute/element-text patches (nodes added, removed, or not addressable by @name)' };
}
