// highlight.js — dependency-free syntax highlighting for the file + docs viewers. Runs on
// ESCAPED text (escapeHtml from ui.js), inserting only our own <span> classes. Extracted from
// index.html (P1 modular split). Shared by editor.js (File view) and the docs renderer.
import { escapeHtml } from './ui.js';

export function detectLang(path) {
  const p = (path || '').toLowerCase();
  if (p.endsWith('.json')) return 'json';
  if (p.endsWith('.xml')) return 'xml';
  if (p.endsWith('.cfg') || p.endsWith('.conf') || p.endsWith('.ini')) return 'ini';
  return 'text';
}
export function hlJson(s) {
  return s.replace(/("(?:[^"\\]|\\.)*")(\s*:)|("(?:[^"\\]|\\.)*")|\b(true|false|null)\b|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/g,
    (m, key, colon, str, kw, num) => {
      if (key !== undefined) return `<span class="t-key">${key}</span>${colon}`;
      if (str !== undefined) return `<span class="t-str">${str}</span>`;
      if (kw !== undefined) return `<span class="t-kw">${kw}</span>`;
      if (num !== undefined) return `<span class="t-num">${num}</span>`;
      return m;
    });
}
function hlIni(s) {
  return s.replace(/("(?:[^"\\]|\\.)*")|((?:#|\/\/)[^\n]*)|(-?\b\d+(?:\.\d+)?\b)/g,
    (m, str, com, num) => {
      if (str !== undefined) return `<span class="t-str">${str}</span>`;
      if (com !== undefined) return `<span class="t-com">${com}</span>`;
      if (num !== undefined) return `<span class="t-num">${num}</span>`;
      return m;
    });
}
function hlXml(s) {
  return s
    .replace(/(&lt;!--[\s\S]*?--&gt;)/g, '<span class="t-com">$1</span>')
    .replace(/(&lt;\/?)([\w:.-]+)((?:(?!&gt;)[\s\S])*?)(\/?&gt;)/g, (m, open, name, attrs, close) => {
      const a = attrs.replace(/([\w:.-]+)(=)("(?:[^"\\]|\\.)*")/g, '<span class="t-key">$1</span>$2<span class="t-str">$3</span>');
      return `<span class="t-tag">${open}${name}</span>${a}<span class="t-tag">${close}</span>`;
    });
}
export function highlight(raw, lang) {
  const e = escapeHtml(raw);
  if (lang === 'json') return hlJson(e);
  if (lang === 'ini') return hlIni(e);
  if (lang === 'xml') return hlXml(e);
  return e;
}
