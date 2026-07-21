// The command API: POST /dayz/:action — the authenticated way to TRIGGER a server
// action. This is the 'dayz' NAMESPACE of the API (other services get their own
// /<service>/* module). A real caller (an admin page, a Discord bot, CLI/cron) uses
// it. Every request must carry a valid HMAC-SHA256 signature over the raw body —
// keyed with the wizard secret, or (X-Key-Id header) a derived key minted via
// /keys/create. A derived key must hold the 'dayz' namespace, and an "observe" key
// can only run read-only actions.
//
// Pipeline:  signature -> action exists -> namespace -> capability -> player guard
//            (destructive) -> cooldown -> run -> audit (attributed to wizard/key id).
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { AppConfig } from '../config.js';
import type { Action } from '../actions.js';
import type { DayzBridge } from '../dayz.js';
import type { Cooldowns } from '../guard.js';
import type { Audit } from '../audit.js';
import type { KeyStore } from '../keys.js';
import { namespaceAllowed } from '../namespaces.js';
import { authenticateRequest } from '../auth-request.js';
import { responseDrift } from '../spec.js';

// Dev-only guard: does a handler still return what its OpenAPI schema promises? Prod
// (NODE_ENV=production) skips it entirely, so there's zero runtime cost in production.
const DEV = process.env.NODE_ENV !== 'production';

// The namespace this route module serves. One string, in one place.
const NAMESPACE = 'dayz';

interface Deps {
  cfg: AppConfig;
  actions: Record<string, Action>;
  dayz: DayzBridge;
  cooldowns: Cooldowns;
  audit: Audit;
  keyStore: KeyStore;
}

export function registerCommands(app: FastifyInstance, deps: Deps): void {
  const { cfg, actions, dayz, cooldowns, audit, keyStore } = deps;

  // Discoverability for operators (no secrets): what dayz actions can be triggered?
  // Lives under /dayz because it describes THIS namespace's allowlist.
  app.get('/dayz/actions', async () => ({
    actions: Object.fromEntries(
      Object.entries(actions).map(([name, a]) => [name, { destructive: a.destructive, describe: a.describe }]),
    ),
  }));

  // One handler, two routes: flat actions (/dayz/restart) and grouped actions
  // (/dayz/terrain/surface-y — registry name 'terrain/surface-y'). Fastify's :params
  // never match slashes, so grouped names need their own route; the pipeline is
  // identical because the registry key IS the URL suffix either way.
  const handleAction = async (req: FastifyRequest, reply: FastifyReply) => {
    const p = req.params as { action: string; group?: string };
    const name = p.group ? `${p.group}/${p.action}` : p.action;

    // 1. Authenticate (shared helper: wizard secret or an X-Key-Id derived key).
    const auth = authenticateRequest(req, keyStore, cfg.secret);
    const key = auth.key;
    const ctx = { ip: req.ip, url: req.url, key: auth.identity };
    if (!auth.authed) {
      audit('reject:bad_signature', name, ctx, auth.claimedKey ? { claimed: auth.claimedKey } : {});
      return reply.code(401).send({ ok: false, error: 'bad_signature' });
    }

    // 2. Allowlist.
    const action = actions[name];
    if (!action) {
      audit('reject:unknown_action', name, ctx);
      return reply.code(404).send({ ok: false, error: 'unknown_action', message: `no action '${name}'` });
    }

    // 2b. Namespace reach. Everything under this route is the 'dayz' namespace; a
    //     derived key must hold it (or '*'). Wizard (key undefined) reaches all.
    //     This is what stops a key minted for another service reaching DayZ.
    if (key && !namespaceAllowed(key.namespaces, NAMESPACE)) {
      audit('reject:namespace', name, ctx);
      return reply.code(403).send({
        ok: false,
        error: 'forbidden_namespace',
        message: `key '${key.id}' cannot reach the '${NAMESPACE}' namespace`,
      });
    }

    // 2c. Capability. "observe" keys are for dashboards/bots that watch — they can
    //     never change server state, no matter what they sign.
    if (key && key.scope === 'observe' && !action.readOnly) {
      audit('reject:scope', name, ctx);
      return reply.code(403).send({
        ok: false,
        error: 'forbidden_scope',
        message: `key '${key.id}' has scope 'observe' — '${name}' is not a read-only action`,
      });
    }

    // Action params: the signed JSON body. READ-ONLY actions may ALSO fold in URL query
    // params (body wins on a clash) — the query is not HMAC-signed, but for a read the worst
    // a tampered query changes is e.g. how much log comes back (/dayz/logs/read?limit=200). Any
    // action that CHANGES state (non-readOnly: restart/mapchange/broadcast/set-overrides/rollback…)
    // is body-ONLY, so no unsigned query param can steer a write or a replayed request.
    const body = (req.body ?? {}) as Record<string, unknown>;
    const params = action.readOnly ? { ...(req.query as Record<string, unknown>), ...body } : body;
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

    // 4. Cooldown — throttles repeated STATE CHANGES ("you already asked for this").
    //    READ-ONLY actions are exempt by rule: they're idempotent and safe to poll, and the
    //    global per-IP rate limit already covers read floods. Without this a polled read
    //    (e.g. /dayz/status on the dashboard, /dayz/update/status) cools ITSELF down and 409s
    //    on the next tick. The per-read `0` entries in cooldownSeconds are now redundant but
    //    harmless — this rule is the source of truth, not the config list.
    if (!action.readOnly) {
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
    }

    // 5. Run + audit.
    try {
      const result = await action.run(params);
      if (DEV) {
        const drift = responseDrift(action.schema?.response, result);
        if (drift.length) req.log.warn({ action: name, drift }, 'response drift vs openapi schema — update actions.ts schema');
      }
      audit('ok', name, ctx, result);
      return reply.send({ ok: true, action: name, ...result });
    } catch (e) {
      const status = (e as { statusCode?: number }).statusCode ?? 500;
      const message = e instanceof Error ? e.message : String(e);
      audit('error', name, ctx, { status, message });
      return reply.code(status).send({ ok: false, error: 'action_failed', message });
    }
  };

  app.post('/dayz/:action', handleAction);
  app.post('/dayz/:group/:action', handleAction);
}
