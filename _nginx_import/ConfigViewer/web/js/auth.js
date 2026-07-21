// auth.js — credential cookie. The Key ID + derived secret the user pastes live in a
// cookie so a reload stays signed in; cleared the moment the API rejects them (401).
// Extracted from index.html (P1 modular split). Native ES module, no build step.
const COOKIE = 'cfgview';

export function saveCred(c) { document.cookie = `${COOKIE}=${encodeURIComponent(JSON.stringify(c))};Path=/;Secure;SameSite=Strict;Max-Age=2592000`; }

export function loadCred() {
  const m = document.cookie.match(/(?:^|;\s*)cfgview=([^;]+)/);
  if (!m) return null;
  try { const c = JSON.parse(decodeURIComponent(m[1])); return c && c.id && c.secret ? c : null; } catch { return null; }
}

export function clearCred() { document.cookie = `${COOKIE}=;Path=/;Secure;SameSite=Strict;Max-Age=0`; }

// handle(err): the shared 401 responder. If the API rejects the credentials, clear them and
// show the login view. The login view itself belongs to the app shell, so it's INJECTED via
// setOnUnauthorized(fn) at boot — this module stays free of any UI/view dependency.
let onUnauthorized = () => {};
export function setOnUnauthorized(fn) { onUnauthorized = fn; }
export function handle(err) {
  if (err.status === 401) { clearCred(); onUnauthorized('Credentials rejected — please enter them again.'); return true; }
  return false;
}
