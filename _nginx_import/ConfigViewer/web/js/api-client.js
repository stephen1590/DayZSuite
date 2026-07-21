// api-client.js — the wire layer for the DayZ Config UI. Signs each request (HMAC-SHA256,
// Web Crypto) and POSTs it to the same-origin /api proxy; owns the shared rate-limit backoff.
// Extracted from index.html (P1 modular split). Native ES module, no build step.
//
// Extension is .js (NOT .mjs) on purpose: the vhost sends X-Content-Type-Options: nosniff, and
// .mjs is absent from nginx's default mime.types — it would be served as octet-stream and the
// browser would refuse to execute the module. .js gets a JS MIME (proven: the vendored Swagger
// bundle loads on this box).

const API = '/api';
export const enc = new TextEncoder();

// HMAC-SHA256 the request bytes with the derived secret, exactly the way the API verifies it.
export async function sign(secret, bytes) {
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, bytes);
  return 'sha256=' + [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// While rate-limited (HTTP 429) every poller skips its ticks until the window passes,
// instead of hammering an already-limited API. Manual actions still go through — they
// surface the 429 message directly, and a failed one refreshes the deadline anyway.
let rateLimitedUntil = 0;
export const rateLimited = () => Date.now() < rateLimitedUntil;

export async function apiPost(path, cred, bodyObj) {
  const bodyStr = bodyObj === undefined ? '' : JSON.stringify(bodyObj);
  const sig = await sign(cred.secret, enc.encode(bodyStr));
  const headers = { 'X-Key-Id': cred.id, 'X-Signature-256': sig };
  const init = { method: 'POST', headers };
  if (bodyObj !== undefined) { headers['Content-Type'] = 'application/json'; init.body = bodyStr; }
  const res = await fetch(API + path, init);
  let data = {};
  try { data = await res.json(); } catch { /* non-JSON body */ }
  if (res.status === 429) {
    const sec = Number(data.retryAfter ?? res.headers.get('Retry-After')) || 30;
    rateLimitedUntil = Date.now() + sec * 1000;
    const err = new Error(`Rate limited by the API — backing off for ${sec}s`); err.status = 429; throw err;
  }
  if (!res.ok) { const err = new Error(data.message || data.error || `HTTP ${res.status}`); err.status = res.status; throw err; }
  return data;
}
