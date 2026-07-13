// The command API: POST /dayz/:action — the authenticated way to TRIGGER a server
// action. This is the path a real caller (an admin page, a Discord bot, CLI/cron)
// uses. Every request must carry a valid HMAC-SHA256 signature over the raw body.
//
// Pipeline:  signature -> action exists -> player guard (destructive) ->
//            cooldown -> run -> audit.
import type { FastifyInstance } from 'fastify';
import type { AppConfig } from '../config.js';
import type { Action } from '../actions.js';
import type { DayzBridge } from '../dayz.js';
import type { Cooldowns } from '../guard.js';
import type { Audit } from '../audit.js';
import { verifyHmac } from '../auth.js';

interface Deps {
  cfg: AppConfig;
  actions: Record<string, Action>;
  dayz: DayzBridge;
  cooldowns: Cooldowns;
  audit: Audit;
}

// Raw body captured by the content-type parser in server.ts, for HMAC verification.
type WithRaw = { rawBody?: Buffer };

export function registerCommands(app: FastifyInstance, deps: Deps): void {
  const { cfg, actions, dayz, cooldowns, audit } = deps;

  // Discoverability for operators (no secrets): what can be triggered?
  app.get('/actions', async () => ({
    actions: Object.fromEntries(
      Object.entries(actions).map(([name, a]) => [name, { destructive: a.destructive, describe: a.describe }]),
    ),
  }));

  app.post('/dayz/:action', async (req, reply) => {
    const ctx = { ip: req.ip, url: req.url };
    const name = (req.params as { action: string }).action;

    // 1. Authenticate over the exact bytes we received.
    const raw = (req as WithRaw).rawBody ?? Buffer.alloc(0);
    const sig = req.headers['x-signature-256'] as string | undefined;
    if (!verifyHmac(raw, sig, cfg.secret)) {
      audit('reject:bad_signature', name, ctx);
      return reply.code(401).send({ ok: false, error: 'bad_signature' });
    }

    // 2. Allowlist.
    const action = actions[name];
    if (!action) {
      audit('reject:unknown_action', name, ctx);
      return reply.code(404).send({ ok: false, error: 'unknown_action', message: `no action '${name}'` });
    }

    const body = (req.body ?? {}) as Record<string, unknown>;
    const force = body.force === true;

    // 3. Player guard (destructive only). A null count = "cannot verify" = refuse,
    //    matching the DayZ deploy's conservative guard — unless explicitly forced.
    if (action.destructive && cfg.playerGuard && !force) {
      const p = await dayz.players();
      if (p.count === null) {
        audit('reject:players_unverifiable', name, ctx, { raw: p.raw });
        return reply.code(409).send({
          ok: false,
          error: 'players_unverifiable',
          message: 'could not verify player count over RCon; pass {"force":true} to proceed anyway',
        });
      }
      if (p.count > 0) {
        audit('reject:players_online', name, ctx, { players: p.count });
        return reply.code(409).send({
          ok: false,
          error: 'players_online',
          message: `${p.count} player(s) online — pass {"force":true} to proceed`,
          players: p.count,
        });
      }
    }

    // 4. Cooldown — the custom "you already asked for this" reply.
    const cdSec = cfg.cooldownSeconds[name] ?? cfg.cooldownSeconds.default;
    const cd = cooldowns.check(name, cdSec);
    if (!cd.ok) {
      audit('reject:cooldown', name, ctx, { retryAfter: cd.retryAfter });
      reply.header('Retry-After', String(cd.retryAfter));
      return reply.code(409).send({
        ok: false,
        error: 'cooldown',
        action: name,
        message: `'${name}' was already triggered ${cd.agoSec}s ago — wait ${cd.retryAfter}s before trying again`,
        retryAfter: cd.retryAfter,
      });
    }
    cooldowns.mark(name);

    // 5. Run + audit.
    try {
      const result = await action.run(body);
      audit('ok', name, ctx, result);
      return reply.send({ ok: true, action: name, ...result });
    } catch (e) {
      const status = (e as { statusCode?: number }).statusCode ?? 500;
      const message = e instanceof Error ? e.message : String(e);
      audit('error', name, ctx, { status, message });
      return reply.code(status).send({ ok: false, error: 'action_failed', message });
    }
  });
}
