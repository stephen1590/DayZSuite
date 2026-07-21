// Key management: POST /keys/{create,list,revoke} — how the WIZARD key mints
// derived API keys for other platforms (a Discord bot, a dashboard, cron).
//
// WIZARD ONLY, by design: a derived key must never mint or revoke keys, so an
// X-Key-Id header here is rejected outright, before signature verification.
// The wizard stays the one stable root credential (generated at deploy, in
// /etc/api/secrets.env); everything else is disposable and individually
// revocable without touching any other caller.
//
// A created key's secret is returned ONCE, in the create response. After that
// it exists only in the server-side store — list never includes secrets.
import type { FastifyInstance } from 'fastify';
import type { AppConfig } from '../config.js';
import type { Audit } from '../audit.js';
import type { KeyStore, KeyScope } from '../keys.js';
import { NAMESPACES, validateNamespaces } from '../namespaces.js';
import { verifyHmac } from '../auth.js';

interface Deps {
  cfg: AppConfig;
  audit: Audit;
  keyStore: KeyStore;
}

type WithRaw = { rawBody?: Buffer };

export function registerKeys(app: FastifyInstance, deps: Deps): void {
  const { cfg, audit, keyStore } = deps;

  // Shared gate for all three endpoints. Returns false if the reply was sent.
  // Reject rows are attributed to 'unauthenticated' (never 'wizard') so a failed
  // attempt can't masquerade as the wizard in the ledger; the claimed key id, if
  // any, is recorded for investigators. Only a request that passes both checks is
  // the wizard — the handlers below audit their success as key 'wizard'.
  function wizardOnly(req: any, reply: any, what: string): boolean {
    const url = '/keys/' + what;
    const claimed = req.headers['x-key-id'] as string | undefined;
    if (claimed) {
      audit('reject:keys_not_wizard', what, { ip: req.ip, url, key: 'unauthenticated' }, { claimed });
      reply.code(403).send({ ok: false, error: 'wizard_required', message: 'key management requires the wizard key (no X-Key-Id)' });
      return false;
    }
    const raw = (req as WithRaw).rawBody ?? Buffer.alloc(0);
    const sig = req.headers['x-signature-256'] as string | undefined;
    if (!verifyHmac(raw, sig, cfg.secret)) {
      audit('reject:bad_signature', 'keys:' + what, { ip: req.ip, url, key: 'unauthenticated' });
      reply.code(401).send({ ok: false, error: 'bad_signature' });
      return false;
    }
    return true;
  }

  app.post('/keys/create', async (req, reply) => {
    if (!wizardOnly(req, reply, 'create')) return;
    const ctx = { ip: req.ip, url: '/keys/create', key: 'wizard' };
    const body = (req.body ?? {}) as Record<string, unknown>;
    const id = String(body.id ?? '');
    const scope = String(body.scope ?? 'full');
    if (scope !== 'full' && scope !== 'observe') {
      return reply.code(400).send({ ok: false, error: 'bad_scope', message: 'scope must be "full" or "observe"' });
    }
    // namespaces = which services the key reaches. Default to ['dayz'] (the only
    // service today) when omitted; validate any provided list against the registry
    // so a key can't be minted for a namespace that doesn't exist.
    const namespaces = validateNamespaces(body.namespaces ?? [...NAMESPACES]);
    if (!namespaces) {
      return reply.code(400).send({
        ok: false,
        error: 'bad_namespaces',
        message: `namespaces must be a non-empty list of: ${['*', ...NAMESPACES].join(', ')}`,
      });
    }
    const key = keyStore.create(id, scope as KeyScope, namespaces);
    if (key === undefined) {
      return reply.code(400).send({ ok: false, error: 'bad_id', message: 'id must be 2-32 chars: letters/digits, then also _ or -' });
    }
    if (key === null) {
      audit('reject:key_exists', 'keys:create', ctx, { id });
      return reply.code(409).send({ ok: false, error: 'key_exists', message: `key '${id}' already exists — revoke it first to reissue` });
    }
    audit('ok', 'keys:create', ctx, { id: key.id, scope: key.scope, namespaces: key.namespaces });
    return reply.send({
      ok: true,
      id: key.id,
      scope: key.scope,
      namespaces: key.namespaces,
      secret: key.secret,
      message: 'store this secret now — it is never shown again',
    });
  });

  app.post('/keys/list', async (req, reply) => {
    if (!wizardOnly(req, reply, 'list')) return;
    audit('ok', 'keys:list', { ip: req.ip, url: '/keys/list', key: 'wizard' });
    return reply.send({ ok: true, keys: keyStore.list() });
  });

  // Adjust a key's capability and/or namespaces on the fly — same secret, no rotation.
  app.post('/keys/update', async (req, reply) => {
    if (!wizardOnly(req, reply, 'update')) return;
    const ctx = { ip: req.ip, url: '/keys/update', key: 'wizard' };
    const body = (req.body ?? {}) as Record<string, unknown>;
    const id = String(body.id ?? '');
    const patch: { scope?: KeyScope; namespaces?: string[] } = {};
    if (body.scope !== undefined) {
      const scope = String(body.scope);
      if (scope !== 'full' && scope !== 'observe') {
        return reply.code(400).send({ ok: false, error: 'bad_scope', message: 'scope must be "full" or "observe"' });
      }
      patch.scope = scope;
    }
    if (body.namespaces !== undefined) {
      const ns = validateNamespaces(body.namespaces);
      if (!ns) {
        return reply.code(400).send({
          ok: false,
          error: 'bad_namespaces',
          message: `namespaces must be a non-empty list of: ${['*', ...NAMESPACES].join(', ')}`,
        });
      }
      patch.namespaces = ns;
    }
    if (patch.scope === undefined && patch.namespaces === undefined) {
      return reply.code(400).send({ ok: false, error: 'nothing_to_update', message: 'provide "scope" and/or "namespaces"' });
    }
    const key = keyStore.update(id, patch);
    if (!key) {
      return reply.code(404).send({ ok: false, error: 'unknown_key', message: `no key '${id}'` });
    }
    audit('ok', 'keys:update', ctx, { id: key.id, scope: key.scope, namespaces: key.namespaces });
    return reply.send({ ok: true, id: key.id, scope: key.scope, namespaces: key.namespaces, message: 'updated; secret unchanged' });
  });

  app.post('/keys/revoke', async (req, reply) => {
    if (!wizardOnly(req, reply, 'revoke')) return;
    const ctx = { ip: req.ip, url: '/keys/revoke', key: 'wizard' };
    const body = (req.body ?? {}) as Record<string, unknown>;
    const id = String(body.id ?? '');
    if (!keyStore.revoke(id)) {
      return reply.code(404).send({ ok: false, error: 'unknown_key', message: `no key '${id}'` });
    }
    audit('ok', 'keys:revoke', ctx, { id });
    return reply.send({ ok: true, id, message: 'revoked — requests signed with it now 401' });
  });
}
