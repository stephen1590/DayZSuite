// API service entrypoint. Binds to localhost only — nginx terminates TLS on the
// public `api.` name and proxies here (see deploy/nginx/api.conf.template).
import Fastify from 'fastify';
import rateLimit from '@fastify/rate-limit';
import { loadConfig } from './config.js';
import { makeAudit } from './audit.js';
import { makeDayz } from './dayz.js';
import { buildActions } from './actions.js';
import { HeightmapStore } from './heightmap.js';
import { Cooldowns } from './guard.js';
import { KeyStore } from './keys.js';
import { registerCommands } from './routes/commands.js';
import { registerSources } from './routes/sources.js';
import { registerKeys } from './routes/keys.js';
import { registerPublic } from './routes/public.js';
import { registerHost } from './routes/host.js';
import { NAMESPACES } from './namespaces.js';
import { buildSpec } from './spec.js';

const cfg = loadConfig();
const audit = makeAudit(cfg.auditDir);
const dayz = makeDayz(cfg);
const heightmaps = new HeightmapStore(cfg.heightmapsDir);
const actions = buildActions(dayz, cfg.restartWarningSeconds, heightmaps);
const cooldowns = new Cooldowns();
const keyStore = new KeyStore(cfg.keysFile);

const app = Fastify({
  logger: true,
  // nginx sets X-Forwarded-For; trust it so req.ip is the real client, not 127.0.0.1.
  trustProxy: true,
  bodyLimit: 256 * 1024,
});

// Keep the RAW body so HMAC is verified over the exact bytes, while still parsing
// JSON for handlers. Empty bodies are allowed (many triggers carry no payload).
app.addContentTypeParser('application/json', { parseAs: 'buffer' }, (_req, body, done) => {
  const buf = body as Buffer;
  (_req as { rawBody?: Buffer }).rawBody = buf;
  try {
    done(null, buf.length ? JSON.parse(buf.toString('utf8')) : {});
  } catch {
    // A malformed JSON body is a client error (400), not a server fault (500). Mark
    // the error so Fastify replies 400 instead of surfacing an unhandled exception.
    done(Object.assign(new Error('invalid JSON body'), { statusCode: 400 }), undefined);
  }
});

// Global rate limit with a CUSTOM reply (the "slow down" message the operator asked
// for). Per-action cooldowns (see routes/commands.ts) layer on top of this.
await app.register(rateLimit, {
  global: true,
  max: cfg.rateLimit.max,
  timeWindow: cfg.rateLimit.windowMs,
  errorResponseBuilder: (_req, ctx) => ({
    ok: false,
    error: 'rate_limited',
    message: `too many requests — retry in ${Math.ceil(ctx.ttl / 1000)}s`,
    retryAfter: Math.ceil(ctx.ttl / 1000),
  }),
});

// Live route table for the discovery endpoint (GET /). Auto-populated as EVERY route
// registers, so a new endpoint or namespace shows up in discovery for free — no
// hand-kept list to drift out of date (the exact problem a per-namespace /actions had
// for the whole-API view). Added before any route so it captures all of them.
const routeTable: Array<{ method: string; path: string }> = [];
app.addHook('onRoute', (r) => {
  const methods = Array.isArray(r.method) ? r.method : [r.method];
  for (const m of methods) {
    if (m === 'HEAD' || m === 'OPTIONS') continue;
    if (!routeTable.some((e) => e.method === m && e.path === r.url)) routeTable.push({ method: m, path: r.url });
  }
});

// GET / — the whole-API index: every registered endpoint (auto-collected above) PLUS
// the dayz action allowlist expanded from the single POST /dayz/:action route. Public,
// no secrets. Per-namespace action detail also lives at GET /dayz/actions.
app.get('/', async () => ({
  service: 'servermander-api',
  namespaces: NAMESPACES,
  endpoints: routeTable
    .slice()
    .sort((a, b) => a.path.localeCompare(b.path) || a.method.localeCompare(b.method)),
  actions: {
    dayz: Object.fromEntries(
      Object.entries(actions).map(([n, a]) => [n, { destructive: a.destructive, readOnly: a.readOnly, describe: a.describe }]),
    ),
  },
}));

app.get('/healthz', async () => ({ ok: true }));

// The OpenAPI spec, generated from the live action registry — the single source the
// Config Viewer's Swagger tab and the Bruno generator both consume. Public (docs only).
app.get('/openapi.json', async () => buildSpec(actions));

registerCommands(app, { cfg, actions, dayz, cooldowns, audit, keyStore });
registerSources(app, { cfg, actions, audit });
registerKeys(app, { cfg, audit, keyStore });
registerHost(app, { cfg, dayz, audit, keyStore });
registerPublic(app, { actions });

// Dev completeness guard: every registered route must appear in the generated spec (the
// /dayz/:action dispatcher is covered by the per-action paths). Catches a root route
// added to the code but not to spec.ts ROOT_ROUTES — before it ships an incomplete spec.
if (process.env.NODE_ENV !== 'production') {
  const specPaths = new Set(Object.keys((buildSpec(actions).paths ?? {}) as Record<string, unknown>));
  for (const r of routeTable) {
    if (r.path === '/dayz/:action' || r.path === '/dayz/:group/:action') continue;
    const p = r.path.replace(/:(\w+)/g, '{$1}');
    if (!specPaths.has(p)) app.log.warn(`route ${r.method} ${r.path} missing from generated OpenAPI — add it to spec.ts ROOT_ROUTES`);
  }
}

app.setNotFoundHandler((_req, reply) => reply.code(404).send({ ok: false, error: 'not_found' }));

try {
  await app.listen({ host: cfg.host, port: cfg.port });
  app.log.info(`api listening on ${cfg.host}:${cfg.port} (vpp ${cfg.vpp.enabled ? 'enabled' : 'disabled'})`);
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
