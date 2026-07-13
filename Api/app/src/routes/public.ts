// Public, UNAUTHENTICATED read: GET /dayz/server-info — the payload behind the site's
// "current server info" panel. It returns exactly the signed `status` action's
// output and nothing more: state, uptime, players, map, mods, next restart. It lives
// under /dayz because it is the DayZ server's info (its public twin of /dayz/status).
//
// Why no auth is acceptable HERE and nowhere else: every field is already public
// via the Steam server browser (the query port publishes name, map, player count,
// and the full mod list to anyone), so this endpoint discloses nothing new — it
// just makes the same data fetchable by the site without shipping a secret to
// browsers. It changes no state, and it is NOT an allowlisted action name, so the
// authenticated command pipeline is untouched.
//
// A short in-process cache (10s) means a page full of visitors costs one sudo +
// RCon round-trip, and also stands in for the per-action cooldown that command
// calls get. Not audited per-hit — it is cached and public; nginx's access log
// covers who fetched it.
import type { FastifyInstance } from 'fastify';
import type { Action } from '../actions.js';

interface Deps {
  actions: Record<string, Action>;
}

const CACHE_MS = 10_000;

export function registerPublic(app: FastifyInstance, deps: Deps): void {
  let cache: { at: number; body: Record<string, unknown> } | null = null;

  app.get('/dayz/server-info', async (_req, reply) => {
    // Public data for a static site's fetch(): allow any origin, GET only.
    reply.header('access-control-allow-origin', '*');
    reply.header('cache-control', 'public, max-age=10');

    if (cache && Date.now() - cache.at < CACHE_MS) {
      return reply.send(cache.body);
    }
    try {
      const result = await deps.actions.status.run({});
      cache = { at: Date.now(), body: { ...result, generatedAt: new Date().toISOString() } };
      return reply.send(cache.body);
    } catch {
      // Don't leak bridge internals on the public surface.
      return reply.code(502).send({ ok: false, error: 'unavailable' });
    }
  });
}
