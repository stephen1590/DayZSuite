// Shared request authentication: resolve the credential (wizard secret, or an
// X-Key-Id derived key), verify the HMAC-SHA256 signature over the raw body, and
// report WHO authenticated. Used by every signed endpoint — the /dayz command
// route and the root-level authed endpoints (/sysload) — so the credential rules
// live in exactly one place.
//
// Attribution is the AUTHENTICATED identity, never a claimed-but-unverified one:
// on failure `identity` is 'unauthenticated' and the claimed key id (if any) is
// returned separately for the audit trail. A bogus key id is NEVER checked against
// the wizard secret.
import type { FastifyRequest } from 'fastify';
import type { KeyStore, ApiKey } from './keys.js';
import { verifyHmac } from './auth.js';

export interface AuthResult {
  authed: boolean;
  /** The derived key that authenticated, or undefined for the wizard (when authed). */
  key?: ApiKey;
  /** 'wizard' | '<key id>' when authed; 'unauthenticated' otherwise. For audit. */
  identity: string;
  /** The X-Key-Id presented on a FAILED auth, for the audit `claimed` field. */
  claimedKey?: string;
}

type WithRaw = { rawBody?: Buffer };

export function authenticateRequest(req: FastifyRequest, keyStore: KeyStore, wizardSecret: string): AuthResult {
  const keyId = req.headers['x-key-id'] as string | undefined;
  const key = keyId ? keyStore.find(keyId) : undefined;
  const raw = (req as WithRaw).rawBody ?? Buffer.alloc(0);
  const sig = req.headers['x-signature-256'] as string | undefined;
  const known = !keyId || Boolean(key); // a claimed-but-unknown id must not fall back to the wizard secret
  const authed = known && verifyHmac(raw, sig, key ? key.secret : wizardSecret);
  if (!authed) return { authed: false, identity: 'unauthenticated', claimedKey: keyId };
  return { authed: true, key, identity: keyId ?? 'wizard' };
}

export type { ApiKey };
