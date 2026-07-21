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
import { makeMetrics } from '../metrics.js';
import { authenticateRequest } from '../auth-request.js';

interface Deps {
  cfg: AppConfig;
  dayz: DayzBridge;
  audit: Audit;
  keyStore: KeyStore;
}

export function registerHost(app: FastifyInstance, deps: Deps): void {
  const { cfg, dayz, audit, keyStore } = deps;
  const metrics = makeMetrics(dayz);

  // GET /metrics — Prometheus exposition of the DayZ series (see metrics.ts). LOCAL-ONLY
  // by contract: the on-box Prometheus scrapes 127.0.0.1:<port>/metrics directly. Both
  // nginx vhosts refuse the path outright (api.conf + config-viewer.conf templates), and
  // this guard backstops them: every proxied request carries X-Forwarded-For, a direct
  // loopback scrape does not. Unsigned — the loopback interface is the trust boundary —
  // and unaudited: a 30s scrape cadence would bury the audit log in noise.
  app.get('/metrics', async (req, reply) => {
    if (req.headers['x-forwarded-for']) {
      return reply.code(404).send({ ok: false, error: 'not_found' });
    }
    const body = await metrics();
    return reply.header('content-type', 'text/plain; version=0.0.4; charset=utf-8').send(body);
  });

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

  // POST /whoami — the caller's own authenticated identity + capability. An access-aware UI
  // (the Maintenance page) reads this to show operator vs read-only controls, instead of
  // probing with a write it may not be allowed to make. A caller only ever learns its OWN
  // grant; the signature proves who it is. Like /sysload: authenticated, namespace-free.
  app.post('/whoami', async (req, reply) => {
    const auth = authenticateRequest(req, keyStore, cfg.secret);
    const ctx = { ip: req.ip, url: '/whoami', key: auth.identity };
    if (!auth.authed) {
      audit('reject:bad_signature', 'whoami', ctx, auth.claimedKey ? { claimed: auth.claimedKey } : {});
      return reply.code(401).send({ ok: false, error: 'bad_signature' });
    }
    // The wizard (no derived key) is the root credential: full scope, every namespace.
    const scope = auth.key ? auth.key.scope : 'full';
    const namespaces = auth.key ? auth.key.namespaces : ['*'];
    audit('ok', 'whoami', ctx);
    return reply.send({ ok: true, action: 'whoami', identity: auth.identity, scope, namespaces });
  });
}
