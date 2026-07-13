// Root-level HOST endpoints — about the whole box, not any one service, so they sit
// OUTSIDE the namespace tree. Today: POST /sysload (cpu/memory/disk/uptime + the
// dayz-server unit's footprint).
//
// Authenticated but namespace-free: it needs a valid signature (wizard or any derived
// key), because host internals shouldn't be fully public like /server-info — but it is
// read-only and not tied to a service, so no namespace or capability gate applies. Any
// authenticated caller may read it.
import type { FastifyInstance } from 'fastify';
import type { AppConfig } from '../config.js';
import type { DayzBridge } from '../dayz.js';
import type { Audit } from '../audit.js';
import type { KeyStore } from '../keys.js';
import { collectSystemLoad } from '../sysload.js';
import { authenticateRequest } from '../auth-request.js';

interface Deps {
  cfg: AppConfig;
  dayz: DayzBridge;
  audit: Audit;
  keyStore: KeyStore;
}

export function registerHost(app: FastifyInstance, deps: Deps): void {
  const { cfg, dayz, audit, keyStore } = deps;

  app.post('/sysload', async (req, reply) => {
    const auth = authenticateRequest(req, keyStore, cfg.secret);
    const ctx = { ip: req.ip, url: '/sysload', key: auth.identity };
    if (!auth.authed) {
      audit('reject:bad_signature', 'sysload', ctx, auth.claimedKey ? { claimed: auth.claimedKey } : {});
      return reply.code(401).send({ ok: false, error: 'bad_signature' });
    }
    try {
      const load = await collectSystemLoad(dayz);
      audit('ok', 'sysload', ctx);
      return reply.send({ ok: true, action: 'sysload', ...load });
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      audit('error', 'sysload', ctx, { message });
      return reply.code(502).send({ ok: false, error: 'sysload_failed', message });
    }
  });
}
