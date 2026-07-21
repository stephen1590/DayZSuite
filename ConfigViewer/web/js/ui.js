// ui.js — shared UI + text primitives used across every tab: the transient toast, and the
// HTML-escapers every render path relies on. Extracted from index.html. Native ES module.
import { el } from './dom.js';

let toastTimer;
export function toast(msg, kind) {
  el.toast.textContent = msg || '';
  el.toast.className = 'toast show' + (kind === 'err' ? ' err' : kind === 'ok' ? ' ok' : '');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.toast.className = 'toast'; }, kind === 'err' ? 4200 : 2400);
}
export function setGlobalMsg(text, isErr, isOk) { toast(text, isErr ? 'err' : isOk ? 'ok' : ''); }

// Escapers: escapeHtml for element text, attr for a double-quoted attribute value. Highlighting
// and every render path run on ESCAPED text, so these are the shared safety primitive.
export function escapeHtml(s) { return s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c])); }
export function attr(s) { return escapeHtml(String(s)).replace(/"/g, '&quot;'); }

// Strip a leading UTF-8 BOM from fetched file text (shared by the editor + the map's JSON loads).
export function stripBom(s) { return typeof s === 'string' ? s.replace(/^\uFEFF/, '') : s; }
