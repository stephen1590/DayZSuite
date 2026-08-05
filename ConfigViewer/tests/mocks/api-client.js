// Mock api-client for the own-editor DOM harness: serves a live doc + a differing frozen
// default so the unified merge gutter has something to show. No network, no auth.
export const enc = new TextEncoder();
export async function sign() { return 'sha256=mock'; }
export const rateLimited = () => false;
const LIVE = '{\n    "m_Version": 13,\n    "Sets": [\n        { "Name": "TownEdited", "Weight": 5 }\n    ]\n}';
const DEF  = '{\n    "m_Version": 13,\n    "Sets": [\n        { "Name": "TownDefault", "Weight": 1 },\n        { "Name": "RemovedInLive", "Weight": 2 }\n    ]\n}';

// ?big=N synthesises an N-entry config, because the small doc above cannot reproduce json-editor
// building every node eagerly - a real config is a thousands-of-widgets construction. With
// ?big=400 the harness times how long the file takes to become typeable, which is the number
// that has to stay small. Default is unchanged, so the existing checks measure the same document
// they always did.
const bigN = Number(new URLSearchParams(location.search).get('big')) || 0;
function bigDoc(n) {
  const Sets = [];
  for (let i = 0; i < n; i++) {
    Sets.push({
      Name: 'Set_' + i, Weight: i % 17, Chance: (i % 100) / 100,
      Items: [{ ClassName: 'Item_' + i + '_a', Quantity: i % 5 }, { ClassName: 'Item_' + i + '_b', Quantity: 1 }],
      Attachments: ['Att_' + i, 'Att_' + i + '_alt'],
    });
  }
  return JSON.stringify({ m_Version: 13, Sets }, null, 4);
}
const live = bigN ? bigDoc(bigN) : LIVE;

export async function apiPost(path) {
  if (path.includes('.defaults')) return { version: 'def1', content: bigN ? live : DEF };
  if (path.includes('configs/own')) return { version: 'live1', content: live };
  throw Object.assign(new Error('unexpected: ' + path), { status: 500 });
}
