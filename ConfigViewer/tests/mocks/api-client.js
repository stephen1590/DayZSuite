// Mock api-client for the own-editor DOM harness: serves a live doc + a differing frozen
// default so the unified merge gutter has something to show. No network, no auth.
export const enc = new TextEncoder();
export async function sign() { return 'sha256=mock'; }
export const rateLimited = () => false;
const LIVE = '{\n    "m_Version": 13,\n    "Sets": [\n        { "Name": "TownEdited", "Weight": 5 }\n    ]\n}';
const DEF  = '{\n    "m_Version": 13,\n    "Sets": [\n        { "Name": "TownDefault", "Weight": 1 },\n        { "Name": "RemovedInLive", "Weight": 2 }\n    ]\n}';
export async function apiPost(path) {
  if (path.includes('.defaults')) return { version: 'def1', content: DEF };
  if (path.includes('configs/own')) return { version: 'live1', content: LIVE };
  throw Object.assign(new Error('unexpected: ' + path), { status: 500 });
}
