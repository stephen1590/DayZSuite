// state.js — shared session state. The API key's scope gates every write: 'full' = operator
// (can change server state), 'observe' = viewer (read-only), null = unknown (treat as read-only).
// Set from /whoami (Maintenance) and cleared on logout; read via isOperator() by every tab with
// write actions (Maintenance, Map, Editor). Extracted from index.html (P1 modular split).
let apiScope = null;
export function setScope(s) { apiScope = s || null; }
export function getScope() { return apiScope; }
export const isOperator = () => apiScope === 'full';

// The mission the server is currently RUNNING (from /dayz/status). The editor resolves
// 'common' overrides against it; the map defaults its selector to it. Lazily fetched by
// whichever tab needs it first; null = not known yet.
let activeMission = null;
export function setActiveMission(m) { activeMission = m || null; }
export function getActiveMission() { return activeMission; }
