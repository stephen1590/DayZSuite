// Event-SOURCE ingress — for senders that EMIT events rather than issue commands.
//
// VPPAdminTools is exactly this: its "WebHooks" feature POSTs Discord-formatted JSON
// ({ content, embeds: [...] }) to a URL whenever an in-game event fires (player join,
// admin action, ...). It cannot set an HMAC header, so it authenticates the only way
// a Discord-style sender can: a secret token baked into the URL path
// (/dayz/sources/vpp/<token>) — treat that URL like a password. It lives under the
// 'dayz' namespace because it is a DayZ-specific feed (its token auth is separate
// from the derived-key namespace scoping on the /dayz command API).
//
// By default this endpoint only RECEIVES and audits the event feed. Turning a VPP
// event into an action is opt-in via `vpp.rules` (substring match -> action) in the
// config, and is disabled (empty) by default — pattern-matching log text is brittle
// and should be enabled deliberately.
import type { FastifyInstance } from 'fastify';
import type { AppConfig } from '../config.js';
import type { Action } from '../actions.js';
import type { Audit } from '../audit.js';
import { verifyToken } from '../auth.js';

interface Deps {
  cfg: AppConfig;
  actions: Record<string, Action>;
  audit: Audit;
}

interface DiscordEmbed {
  title?: string;
  description?: string;
}
interface DiscordPayload {
  content?: string;
  embeds?: DiscordEmbed[];
}

function flattenText(body: DiscordPayload): string {
  const parts = [body.content ?? ''];
  if (Array.isArray(body.embeds)) {
    for (const e of body.embeds) parts.push(e?.title ?? '', e?.description ?? '');
  }
  return parts.join(' ').replace(/\s+/g, ' ').trim();
}

export function registerSources(app: FastifyInstance, deps: Deps): void {
  const { cfg, actions, audit } = deps;

  app.post('/dayz/sources/vpp/:token', async (req, reply) => {
    const ctx = { ip: req.ip, url: '/dayz/sources/vpp/***' }; // never log the token
    const token = (req.params as { token: string }).token;

    // Disabled or wrong token -> 404 (don't confirm the endpoint exists).
    if (!cfg.vpp.enabled || !verifyToken(token, cfg.vpp.token)) {
      audit('reject:vpp_auth', 'vpp', ctx);
      return reply.code(404).send();
    }

    const body = (req.body ?? {}) as DiscordPayload;
    const text = flattenText(body);
    audit('vpp:event', 'vpp', ctx, { text: text.slice(0, 300) });

    // Opt-in rules: fire an allowlisted action when the event text matches.
    for (const rule of cfg.vpp.rules) {
      if (!rule.match || !text.includes(rule.match)) continue;
      const action = actions[rule.action];
      if (!action) {
        audit('vpp:rule_unknown_action', rule.action, ctx, { match: rule.match });
        continue;
      }
      try {
        const result = await action.run(rule.params ?? {});
        audit('vpp:triggered', rule.action, ctx, { match: rule.match, ...result });
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        audit('vpp:trigger_failed', rule.action, ctx, { match: rule.match, message });
      }
    }

    // VPP/Discord senders don't consume a body; a 204 keeps their logs clean.
    return reply.code(204).send();
  });
}
