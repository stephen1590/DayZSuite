// Namespaces — the top-level SERVICE domains this API fronts. The API started as a
// DayZ bridge; it is now a general control plane where each service lives under its
// own path prefix (/dayz/*, and future /<service>/*). A derived key is scoped to a
// set of namespaces (plus a capability: see KeyScope), so a key minted for one
// service cannot reach another that gets added later.
//
// This is the ONE list of real namespaces. A route module declares which namespace
// it serves (registerCommands = 'dayz'); key creation validates requested namespaces
// against this list so a key can never be minted for a service that doesn't exist.
// Adding a service = a new entry here + its route module.
export const NAMESPACES = ['dayz'] as const;
export type Namespace = (typeof NAMESPACES)[number];

/** Wildcard grant: a key holding this reaches every namespace, present and future. */
export const ALL_NAMESPACES = '*';

/** Does a key whose grants are `held` reach `required`? */
export function namespaceAllowed(held: readonly string[], required: string): boolean {
  return held.includes(ALL_NAMESPACES) || held.includes(required);
}

/**
 * Validate a requested namespace grant list. Returns the cleaned list, or null if any
 * entry is neither '*' nor a known namespace. An empty/absent list is caller error too
 * (a key that reaches nothing is useless) — callers default it before calling this.
 */
export function validateNamespaces(list: unknown): string[] | null {
  if (!Array.isArray(list) || list.length === 0) return null;
  const out: string[] = [];
  for (const n of list) {
    const s = String(n);
    if (s !== ALL_NAMESPACES && !(NAMESPACES as readonly string[]).includes(s)) return null;
    if (!out.includes(s)) out.push(s);
  }
  return out;
}
