// Server-side store for DERIVED API keys - minted on demand by the wizard key
// (see routes/keys.ts), so callers like a Discord bot get their own credential
// and rotating the wizard never breaks them.
//
// Secrets are stored in PLAINTEXT, deliberately: HMAC is symmetric, so the server
// must know the actual secret to verify a signature - hashing would make the keys
// unverifiable. That is the same posture as the wizard in /etc/api/secrets.env.
// The file lives under systemd's StateDirectory (/var/lib/api), owned by the
// service user, mode 0600. Derived secrets are independent random values, NOT
// derived from the wizard - otherwise rotating the wizard would kill every
// derived key, which is exactly the problem derived keys exist to avoid.
import { randomBytes } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export type KeyScope = 'full' | 'observe';

export interface ApiKey {
  id: string;
  secret: string;
  /** Capability: full = every action, observe = read-only actions only. */
  scope: KeyScope;
  /** Namespaces (service domains) this key may reach, e.g. ['dayz'] or ['*']. */
  namespaces: string[];
  createdAt: string;
}

const ID_RE = /^[a-z0-9][a-z0-9_-]{1,31}$/i;

// Keys minted before the namespace axis existed have no `namespaces` field. They
// were created when DayZ was the only service, so that is exactly their reach —
// default them to ['dayz'] (never '*', which would silently grant future services).
const LEGACY_NAMESPACES = ['dayz'];

export class KeyStore {
  private keys = new Map<string, ApiKey>();

  constructor(private path: string) {
    try {
      const list = JSON.parse(readFileSync(path, 'utf8')) as ApiKey[];
      for (const k of list) {
        // Normalise on load so lookups/list see a uniform shape; the field
        // materialises in the file on the next write (create/revoke).
        if (!Array.isArray(k.namespaces) || k.namespaces.length === 0) {
          k.namespaces = [...LEGACY_NAMESPACES];
        }
        this.keys.set(k.id, k);
      }
    } catch {
      // Missing or unreadable file = no derived keys yet. A corrupt file also
      // lands here - keys can be re-minted with the wizard, nothing is lost
      // that the wizard can't recreate.
    }
  }

  /** undefined = bad id shape; null = id taken. Otherwise the new key, secret included (shown once). */
  create(id: string, scope: KeyScope, namespaces: string[]): ApiKey | null | undefined {
    // 'wizard' is reserved: audit rows attribute wizard-signed requests as key
    // "wizard", so a derived key with that id would be indistinguishable from the
    // real wizard in the ledger.
    if (!ID_RE.test(id) || id.toLowerCase() === 'wizard') return undefined;
    if (this.keys.has(id)) return null;
    const key: ApiKey = {
      id,
      secret: randomBytes(32).toString('hex'),
      scope,
      namespaces,
      createdAt: new Date().toISOString(),
    };
    this.keys.set(id, key);
    this.persist();
    return key;
  }

  find(id: string): ApiKey | undefined {
    return this.keys.get(id);
  }

  /** Metadata only - secrets never leave the box after creation. */
  list(): Array<Omit<ApiKey, 'secret'>> {
    return [...this.keys.values()].map(({ secret: _, ...meta }) => meta);
  }

  revoke(id: string): boolean {
    const existed = this.keys.delete(id);
    if (existed) this.persist();
    return existed;
  }

  /**
   * Change an existing key's capability and/or namespaces IN PLACE — id, secret, and
   * createdAt are untouched, so callers keep working with the same credential (no
   * rotation). Returns the updated key, or null if no such id. The caller validates
   * the values before calling; only provided fields are changed.
   */
  update(id: string, patch: { scope?: KeyScope; namespaces?: string[] }): ApiKey | null {
    const key = this.keys.get(id);
    if (!key) return null;
    if (patch.scope) key.scope = patch.scope;
    if (patch.namespaces) key.namespaces = patch.namespaces;
    this.persist();
    return key;
  }

  private persist(): void {
    // tmp + rename: a crash mid-write can never truncate the live key file.
    mkdirSync(dirname(this.path), { recursive: true });
    const tmp = `${this.path}.tmp`;
    writeFileSync(tmp, JSON.stringify([...this.keys.values()], null, 2) + '\n', { mode: 0o600 });
    renameSync(tmp, this.path);
  }
}
