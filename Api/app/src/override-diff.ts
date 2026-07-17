// override-diff.ts — derive a config-overrides delta from a WHOLE-FILE edit by diffing it
// against the frozen default, then PROVE the delta reproduces the edit (round-trip). This is
// what lets the UI offer "edit the whole file" while still storing the minimal delta the
// override model needs (so game/mod baseline updates are still inherited, not fought).
//
// Correctness rule: the derived delta MUST apply identically on the box, so this mirrors
// Apply-ConfigOverrides.ps1's JSON selector semantics exactly —
//   * selector = dotted key path (a.b.c), applied by Set-JsonKey with FORCE-CREATE of missing
//     object keys;
//   * a value is a whole leaf (primitive, array, or a whole object subtree);
//   * keys starting with '_' are documentation the apply engine never touches — excluded from
//     both the delta and the round-trip comparison.
//
// The decision is proven, not guessed: derive the delta, re-apply it to the default, and require
// it to reproduce the edited file (ignoring '_' keys). If it can't (a deleted baseline key, a
// reshaped structure, no default at all), we DON'T emit a lossy delta — we fall back to storing
// the whole file as an override, exactly the documented escape hatch.

export type JsonValue = null | boolean | number | string | JsonValue[] | { [k: string]: JsonValue };
export type Delta = Record<string, JsonValue>; // dotted-selector -> whole value

export type OverrideResult =
  | { mode: 'delta'; delta: Delta; changed: number }
  | { mode: 'wholefile'; reason: string };

const isPlainObject = (v: unknown): v is Record<string, JsonValue> =>
  typeof v === 'object' && v !== null && !Array.isArray(v);

function clone<T extends JsonValue>(v: T): T {
  return v === null || typeof v !== 'object' ? v : JSON.parse(JSON.stringify(v));
}

// Deep structural equality. Objects compare key-set + values (order-independent); arrays are
// ordered. NaN doesn't occur in JSON, so === on primitives is enough.
export function deepEqual(a: JsonValue, b: JsonValue): boolean {
  if (a === b) return true;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    return a.every((x, i) => deepEqual(x, b[i]));
  }
  if (isPlainObject(a) && isPlainObject(b)) {
    const ka = Object.keys(a), kb = Object.keys(b);
    if (ka.length !== kb.length) return false;
    return ka.every((k) => Object.prototype.hasOwnProperty.call(b, k) && deepEqual(a[k], b[k]));
  }
  return false;
}

// Recursively drop '_'-prefixed keys — the apply engine ignores them, so they are not config
// for the purposes of diffing and comparison.
export function stripUnderscore(v: JsonValue): JsonValue {
  if (Array.isArray(v)) return v.map(stripUnderscore);
  if (isPlainObject(v)) {
    const out: Record<string, JsonValue> = {};
    for (const k of Object.keys(v)) if (!k.startsWith('_')) out[k] = stripUnderscore(v[k]);
    return out;
  }
  return v;
}

// Walk `edited` against `def`, emitting the minimal dotted-path patches. Recurse ONLY where both
// sides are plain objects; anywhere else the differing value is a whole-leaf patch (a primitive,
// an array replaced wholesale, or a new/retyped object subtree written in one shot — all of which
// Set-JsonKey handles via force-create). Keys in `def` but absent from `edited` (deletions) are
// not expressible as additive patches; they're intentionally left for the round-trip to catch.
export function deriveJsonDelta(def: JsonValue, edited: JsonValue, prefix = ''): Delta {
  const out: Delta = {};
  if (!isPlainObject(edited) || !isPlainObject(def)) return out; // caller guarantees object roots
  for (const k of Object.keys(edited)) {
    if (k.startsWith('_')) continue;
    const path = prefix ? `${prefix}.${k}` : k;
    const ev = edited[k];
    const dv = Object.prototype.hasOwnProperty.call(def, k) ? def[k] : undefined;
    if (isPlainObject(ev) && isPlainObject(dv)) {
      Object.assign(out, deriveJsonDelta(dv, ev, path));
    } else if (dv === undefined || !deepEqual(stripUnderscore(dv), stripUnderscore(ev))) {
      out[path] = ev;
    }
  }
  return out;
}

// Apply a delta to a default, modelling Set-JsonKey: split the selector on '.', force-create any
// missing (or non-object) intermediate key, set the final leaf to the value. Returns a new object.
export function applyJsonDelta(def: JsonValue, delta: Delta): JsonValue {
  const root: Record<string, JsonValue> = isPlainObject(def) ? clone(def) : {};
  for (const [sel, val] of Object.entries(delta)) {
    const parts = sel.split('.');
    let cur: Record<string, JsonValue> = root;
    for (let i = 0; i < parts.length - 1; i++) {
      const p = parts[i];
      if (!isPlainObject(cur[p])) cur[p] = {};
      cur = cur[p] as Record<string, JsonValue>;
    }
    cur[parts[parts.length - 1]] = clone(val);
  }
  return root;
}

// The whole decision for one JSON file. Parse both sides, derive the delta, and REQUIRE it to
// round-trip (apply→default reproduces the edit, ignoring '_' keys) before trusting it. Anything
// that can't be proven becomes a whole-file override with a plain reason.
export function deriveJsonOverride(defaultText: string | null, editedText: string): OverrideResult {
  let edited: JsonValue;
  try { edited = JSON.parse(editedText); } catch { return { mode: 'wholefile', reason: 'edited file is not valid JSON' }; }
  if (defaultText == null) return { mode: 'wholefile', reason: 'no frozen default to diff against' };
  let def: JsonValue;
  try { def = JSON.parse(defaultText); } catch { return { mode: 'wholefile', reason: 'frozen default is not valid JSON' }; }
  if (!isPlainObject(def) || !isPlainObject(edited)) return { mode: 'wholefile', reason: 'top-level is not a JSON object (dotted selectors need an object root)' };

  const delta = deriveJsonDelta(def, edited);
  const applied = applyJsonDelta(def, delta);
  if (deepEqual(stripUnderscore(applied), stripUnderscore(edited))) {
    return { mode: 'delta', delta, changed: Object.keys(delta).length };
  }
  return { mode: 'wholefile', reason: 'edit could not be expressed as additive patches (a baseline key was removed, or the structure was reshaped)' };
}
