// The action registry — the ALLOWLIST. A caller can only ever invoke a name that
// exists here; there is no arbitrary-command path. Anything PRIVILEGED maps to one
// or more `dayz-ctl` verbs; host stats (sysload's top level) are gathered
// unprivileged in-process, and only the dayz-unit block crosses the sudo bridge
// (game home is 0750 — its sizes are unreadable without it). `destructive` actions
// are subject to the player guard.
//
// Adding a capability later (e.g. controlling another service) is a new entry here
// plus — only if it needs privilege — a matching verb in dayz-ctl; nothing else
// gains privilege.
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

function humanDuration(sec: number): string {
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

export interface Action {
  /** Kicks players / interrupts play -> gated by the player guard. */
  destructive: boolean;
  /**
   * True = observing only, changes nothing (status/players/log/...). This is what
   * scope-'observe' derived keys are limited to. Distinct from `destructive`:
   * broadcast and start are non-destructive but DO change state, so they are
   * not readOnly.
   */
  readOnly: boolean;
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
    readOnly: false,
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
      readOnly: true,
      describe: 'server info: state, uptime, players, map, mod list, next scheduled restart',
      async run() {
        // One dayz-ctl round-trip for the unit snapshot, one RCon call for players.
        // Players degrades to null (RCon down != status broken); the snapshot itself
        // failing is a real error.
        const [i, p] = await Promise.all([
          dayz.info(),
          dayz.players().catch(() => ({ count: null, players: [], raw: '' })),
        ]);
        const now = Math.floor(Date.now() / 1000);
        const running = i.state === 'active' && i.sinceEpoch > 0;
        const up = running ? Math.max(0, now - i.sinceEpoch) : null;

        // The native messages.xml scheduler stops the server <deadline> minutes
        // after start (Restart=always brings it back), so next restart = unit
        // start + deadline. Estimated: mission load shifts it by a minute or two.
        let restart: Record<string, unknown> | null = null;
        if (running && i.deadlineMin > 0) {
          const at = i.sinceEpoch + i.deadlineMin * 60;
          restart = {
            everyMinutes: i.deadlineMin,
            nextAt: new Date(at * 1000).toISOString(),
            inSeconds: Math.max(0, at - now),
            inHuman: humanDuration(Math.max(0, at - now)),
            estimated: true,
          };
        }

        return {
          status: i.state,
          since: i.sinceEpoch > 0 ? new Date(i.sinceEpoch * 1000).toISOString() : null,
          uptimeSeconds: up,
          uptimeHuman: up === null ? null : humanDuration(up),
          players: p.count,
          map: i.mission,
          modCount: i.mods.length,
          mods: i.mods,
          restart,
        };
      },
    },

    players: {
      destructive: false,
      readOnly: true,
      describe: 'current online players: count + roster (num, name, guid, ping, ip, lobby) via RCon',
      async run() {
        const p = await dayz.players();
        return { count: p.count, players: p.players, raw: p.raw };
      },
    },

    map: {
      destructive: true,
      readOnly: false,
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
      readOnly: false,
      describe: 'send an in-game message to all players (body: { "message": "..." })',
      async run(params) {
        const text = sanitizeText(String(params.message ?? ''));
        if (!text) throw fail(400, 'empty "message"');
        const r = await dayz.ctl('broadcast', text);
        if (r.code !== 0) throw fail(502, `broadcast failed: ${(r.stderr || r.stdout).trim()}`);
        return { message: 'broadcast sent', text };
      },
    },

    log: {
      destructive: false,
      readOnly: true,
      describe: 'tail the newest DayZ server log (params: lines 1-500 default 100, type rpt|adm default rpt)',
      async run(params) {
        // Clamp here for a friendly reply; dayz-ctl re-validates and re-caps anyway.
        const lines = Math.min(Math.max(parseInt(String(params.lines ?? ''), 10) || 100, 1), 500);
        const type = String(params.type ?? 'rpt') === 'adm' ? 'adm' : 'rpt';
        const r = await dayz.ctl('log', type, String(lines));
        if (r.code === 2) throw fail(404, `no .${type} logs found under profiles/`);
        if (r.code !== 0) throw fail(502, `log failed: ${(r.stderr || r.stdout).trim()}`);
        // dayz-ctl's contract: line 1 = the file it picked, the rest = the tail.
        const nl = r.stdout.indexOf('\n');
        const file = (nl >= 0 ? r.stdout.slice(0, nl) : r.stdout).trim();
        const tail = nl >= 0 ? r.stdout.slice(nl + 1) : '';
        return { file, type, lines, tail };
      },
    },

    configs: {
      destructive: false,
      readOnly: true,
      describe: 'list the config files available to retrieve (names for the "config" action)',
      async run() {
        const r = await dayz.ctl('config-list');
        if (r.code !== 0) throw fail(502, `config-list failed: ${(r.stderr || r.stdout).trim()}`);
        const safe = /^[A-Za-z0-9_./-]+$/;
        // dayz-ctl emits "group<TAB>name<TAB>label" per file (single files + expanded
        // folder contents). Tolerate a bare name too. Drop names we couldn't serve.
        const configs = r.stdout
          .split('\n')
          .map((l) => l.replace(/\r$/, ''))
          .filter(Boolean)
          .map((line) => {
            const p = line.split('\t');
            return p.length >= 3
              ? { group: p[0], name: p[1], label: p[2] }
              : { group: 'General', name: p[0], label: p[0] };
          })
          .filter((c) => c.name && safe.test(c.name));
        return { configs };
      },
    },

    config: {
      destructive: false,
      readOnly: true,
      describe: 'retrieve one allowlisted config file (params: { "name": "overrides" }; see the "configs" action for names)',
      async run(params) {
        const name = String(params.name ?? '');
        if (!/^[A-Za-z0-9_./-]+$/.test(name) || name.includes('..')) throw fail(400, 'invalid or missing "name"');
        const r = await dayz.ctl('config', name);
        if (r.code === 2) throw fail(404, `unknown config '${name}' (see the "configs" action for valid names)`);
        if (r.code === 3) throw fail(413, `config '${name}' is too large to retrieve`);
        if (r.code !== 0) throw fail(502, `config failed: ${(r.stderr || r.stdout).trim()}`);
        // dayz-ctl's contract: line 1 = the resolved path, the rest = the contents.
        const nl = r.stdout.indexOf('\n');
        const path = (nl >= 0 ? r.stdout.slice(0, nl) : r.stdout).trim();
        const content = nl >= 0 ? r.stdout.slice(nl + 1) : '';
        return { name, path, content };
      },
    },

  };
}
