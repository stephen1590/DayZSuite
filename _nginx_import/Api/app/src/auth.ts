// Authentication primitives — constant-time only. Never compare secrets with ===.
import { createHmac, timingSafeEqual } from 'node:crypto';

/**
 * Verify an HMAC-SHA256 signature over the EXACT raw request bytes. The header is
 * expected as "sha256=<hex>" (GitHub/Stripe convention). Any parse/length/mismatch
 * returns false — callers treat false as 401 and reveal nothing further.
 */
export function verifyHmac(rawBody: Buffer, header: string | undefined, secret: string): boolean {
  if (!header || !secret) return false;
  const m = /^sha256=([0-9a-f]{64})$/i.exec(header.trim());
  if (!m) return false;
  const expected = createHmac('sha256', secret).update(rawBody).digest();
  let provided: Buffer;
  try {
    provided = Buffer.from(m[1], 'hex');
  } catch {
    return false;
  }
  if (provided.length !== expected.length) return false;
  return timingSafeEqual(provided, expected);
}

/** Constant-time compare of a URL path token against the expected secret. */
export function verifyToken(provided: string | undefined, expected: string): boolean {
  if (!provided || !expected) return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}
