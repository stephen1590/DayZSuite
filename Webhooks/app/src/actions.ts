// The action registry — the ALLOWLIST. A webhook can only ever invoke a name that
// exists here; there is no arbitrary-command path. Each action maps to one or more
// `dayz-ctl` verbs. `destructive` actions are subject to the player guard.
//
// Adding a capability later (e.g. controlling another service) is a new entry here
// plus a matching verb in dayz-ctl — not a new endpoint or new privilege.
import type { DayzBridge } from './dayz.js';
import { sanitizeText } from './dayz.js';

export interface ActionError extends Error {
  statusCode: number;
}

function fail(statusCode: number, message: string): ActionError {
  return Object.assign(new Error(message), { statusCode });
}

export interface Action {
  /** Kicks players / interrupts play -> gated by the player guard. */
  destructive: boolean;
  /** One-line description surfaced by GET /actions. */
  describe: string;
  run(params: Record<string, unknown>): Promise<Record<string, unknown>>;
}

export function buildActions(dayz: DayzBridge): Record<string, Action> {
  const lifecycle = (verb: 'restart' | 'stop' | 'start', destructive: boolean, ok: string): Action => ({
    destructive,
    describe: `${verb} the DayZ server`,
    async run() {
      const r = await dayz.ctl(verb);
      if (r.code !== 0) throw fail(502, `${verb} failed: ${(r.stderr || r.stdout).trim()}`);
      return { message: ok };
    },
  });

  return {
    restart: lifecycle('restart', true, 'restart issued'),
    stop: lifecycle('stop', true, 'stop issued'),
    start: lifecycle('start', false, 'start issued'),

    status: {
      destructive: false,
      describe: 'report whether the DayZ server unit is active',
      async run() {
        const r = await dayz.ctl('status');
        return { status: r.stdout.trim() || 'unknown' };
      },
    },

    players: {
      destructive: false,
      describe: 'current online player count (via RCon)',
      async run() {
        const p = await dayz.players();
        return { players: p.count, raw: p.raw };
      },
    },

    map: {
      destructive: true,
      describe: 'switch the active mission and restart (body: { "mission": "dayzOffline.enoch" })',
      async run(params) {
        const mission = String(params.mission ?? '');
        // Shape check here; dayz-ctl re-validates against installed missions.
        if (!/^[A-Za-z0-9_.-]+$/.test(mission)) throw fail(400, 'invalid or missing "mission"');
        const r = await dayz.ctl('set-map', mission);
        if (r.code === 2) throw fail(400, `unknown mission '${mission}' (not installed under mpmissions/)`);
        if (r.code !== 0) throw fail(502, `set-map failed: ${(r.stderr || r.stdout).trim()}`);
        return { message: `map set to ${mission}; server restarting` };
      },
    },

    broadcast: {
      destructive: false,
      describe: 'send an in-game message to all players (body: { "message": "..." })',
      async run(params) {
        const text = sanitizeText(String(params.message ?? ''));
        if (!text) throw fail(400, 'empty "message"');
        const r = await dayz.ctl('broadcast', text);
        if (r.code !== 0) throw fail(502, `broadcast failed: ${(r.stderr || r.stdout).trim()}`);
        return { message: 'broadcast sent', text };
      },
    },
  };
}
