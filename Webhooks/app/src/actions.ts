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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export interface Action {
  /** Kicks players / interrupts play -> gated by the player guard. */
  destructive: boolean;
  /** One-line description surfaced by GET /actions. */
  describe: string;
  run(params: Record<string, unknown>): Promise<Record<string, unknown>>;
}

export function buildActions(dayz: DayzBridge, warnSeconds: number): Record<string, Action> {
  // Give connected players a chance to reach safety before an action that's about to
  // disconnect them: broadcast, then wait. Skipped when nobody's on, or the count
  // can't be verified (RCon down) -- don't block the action on a guess, the player
  // guard upstream already made that call. This is what actually saves player data:
  // whoever is still connected gets the warning time instead of being cut off mid-
  // action; the server's own clean-exit path (see dayz-server.service ExecStop) does
  // the rest once dayz-ctl's systemctl call runs.
  async function warnAndWait(effect: string): Promise<void> {
    if (warnSeconds <= 0) return;
    const p = await dayz.players();
    if (!p.count) return;
    const text = sanitizeText(`[SERVER] ${effect} in ${warnSeconds}s - get to safety!`);
    await dayz.ctl('broadcast', text);
    await sleep(warnSeconds * 1000);
  }

  const lifecycle = (verb: 'restart' | 'stop' | 'start', destructive: boolean, ok: string): Action => ({
    destructive,
    describe: `${verb} the DayZ server`,
    async run() {
      if (destructive) await warnAndWait(verb === 'restart' ? 'Server restarting' : 'Server stopping');
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
        await warnAndWait('Map changing, server restarting');
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
