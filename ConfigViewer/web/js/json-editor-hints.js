// json-editor-hints.js — the extension point that lets the SHARED structured editor replace a
// hand-built one instead of sitting beside it.
//
// The problem it closes: json-editor-ui could render any JSON, but it could not be told anything
// domain-specific, so every view that needed a domain affordance kept its own editor. Two editors,
// then three. The UI contract called for this descriptor on day one and it was never built, which
// is the whole reason map.js still hand-rolls ~550 lines of field rendering.
//
// THE BINDING RULE: nothing here knows what DayZ is. No field names, no "-1 means inherit", no
// waypoints. The caller passes functions and lists; this resolves them per field. If a change here
// ever needs a domain word, the change belongs in the caller.
//
// A hints descriptor (every key optional):
//   badge:     (key, value) => string | null      a label rendered beside the field
//   enums:     { key: [..] } | (key) => [..]      suggestions; the field stays free-text
//   readOnly:  [keys] | (key) => bool             show it, do not invite editing
//   summary:   (key, value) => string | null      replace the control with this text
//   priority:  [keys]                             render first; the caller folds the rest away
//
// Every caller hook is wrapped: a throwing hint degrades to no hint. A editor that dies because a
// caller's badge function hit an undefined is a worse outcome than a missing badge.

function safe(fn, ...args) {
  try { return fn(...args); } catch (_) { return null; }
}

// Resolve one field against a descriptor. Returns ONLY the keys that apply, so a caller can
// `if ('badge' in h)` and a renderer never has to distinguish null from absent.
export function resolveHint(key, value, hints) {
  const out = {};
  if (!hints || typeof hints !== 'object') return out;

  if (typeof hints.badge === 'function') {
    const b = safe(hints.badge, key, value);
    if (b) out.badge = b;
  }

  if (hints.enums) {
    let list = null;
    if (typeof hints.enums === 'function') list = safe(hints.enums, key, value);
    else if (Object.prototype.hasOwnProperty.call(hints.enums, key)) list = hints.enums[key];
    // An empty list is not a dropdown - offering zero choices is worse than offering none,
    // because the control changes shape for no gain.
    if (Array.isArray(list) && list.length) out.suggestions = list.slice();
  }

  if (hints.readOnly) {
    const ro = typeof hints.readOnly === 'function'
      ? safe(hints.readOnly, key, value)
      : (Array.isArray(hints.readOnly) && hints.readOnly.includes(key));
    if (ro) out.readOnly = true;
  }

  if (typeof hints.summary === 'function') {
    const s = safe(hints.summary, key, value);
    if (s) out.summary = s;
  }

  if (Array.isArray(hints.priority) && hints.priority.includes(key)) out.priority = true;

  return out;
}

// Split a key list into [priority, rest], preserving the caller's priority ORDER rather than the
// document's. The caller decides what to do with `rest` - inline, collapsed, or dropped.
export function partitionByPriority(keys, hints) {
  const pri = (hints && Array.isArray(hints.priority)) ? hints.priority : [];
  const head = pri.filter((k) => keys.includes(k));
  const tail = keys.filter((k) => !head.includes(k));
  return [head, tail];
}
