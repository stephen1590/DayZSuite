// The Expansion AI settings files the map editor may read/write, keyed by a short name. THIS is the
// allowlist for configs/settings + configs/set-settings. dayz-ctl's settings-read/settings-write
// carries the matching case table (relpath + required array + whether Names must be unique). Add a
// file = one row here AND one case there - one mechanism, no per-file verb/action/endpoint.
export const SETTINGS_KEYS = {
  patrols: { file: 'AIPatrolSettings.json', label: 'AIPatrolSettings' },
  locations: { file: 'AILocationSettings.json', label: 'AILocationSettings' },
} as const;

export type SettingsKey = keyof typeof SETTINGS_KEYS;

export function isSettingsKey(k: unknown): k is SettingsKey {
  return typeof k === 'string' && Object.prototype.hasOwnProperty.call(SETTINGS_KEYS, k);
}
