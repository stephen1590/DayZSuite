// Webhook service entrypoint. Binds to localhost only — nginx terminates TLS on the
// public `hooks.` name and proxies here (see deploy/nginx/webhooks.conf.template).
import Fastify from 'fastify';
import rateLimit from '@fastify/rate-limit';
import { loadConfig } from './config.js';
import { makeAudit } from './audit.js';
import { makeDayz } from './dayz.js';
import { buildActions } from './actions.js';
import { Cooldowns } from './guard.js';
import { registerCommands } from './routes/commands.js';
import { registerSources } from './routes/sources.js';

const cfg = loadConfig();
const audit = makeAudit(cfg.auditDir);
const dayz = makeDayz(cfg);
const actions = buildActions(dayz, cfg.restartWarningSeconds);
const cooldowns = new Cooldowns();

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
  } catch (err) {
    done(err as Error, undefined);
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

app.get('/healthz', async () => ({ ok: true }));

registerCommands(app, { cfg, actions, dayz, cooldowns, audit });
registerSources(app, { cfg, actions, audit });

app.setNotFoundHandler((_req, reply) => reply.code(404).send({ ok: false, error: 'not_found' }));

try {
  await app.listen({ host: cfg.host, port: cfg.port });
  app.log.info(`webhooks listening on ${cfg.host}:${cfg.port} (vpp ${cfg.vpp.enabled ? 'enabled' : 'disabled'})`);
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
