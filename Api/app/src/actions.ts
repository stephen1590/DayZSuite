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
import type { HeightmapStore } from './heightmap.js';
import type { TimeseriesQuery } from './timeseries.js';
import { METRICS, RANGE_HOURS } from './timeseries.js';
import { statusView, humanDuration } from './status-view.js';
import { sanitizeText } from './dayz.js';
import { bigStringify } from './lossless-json.js';

export interface ActionError extends Error {
  statusCode: number;
}

function fail(statusCode: number, message: string): ActionError {
  return Object.assign(new Error(message), { statusCode });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}


/** OpenAPI fragment for an action. The spec is GENERATED from these and the dev-mode
 *  check validates the handler against `response`, which describes `result` (the fields
 *  merged into the { ok, action, ...result } envelope). */
export type JSONSchema = Record<string, unknown>;
export interface ActionSchema {
  summary?: string;
  body?: JSONSchema;
  query?: JSONSchema;
  response: JSONSchema;
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
  /** Request/response schema — the spec is generated from these (optional per action). */
  schema?: ActionSchema;
  run(params: Record<string, unknown>): Promise<Record<string, unknown>>;
}

// Shape of the update system's status (dayz-ctl update-status). Reused by the `update`,
// `update/status` and `update/cancel` actions. Build ids are strings (Steam's are numeric
// but we never do math on them); nulls mean "unknown" (no check yet / manifest absent).
const UPDATE_STATUS_SCHEMA: JSONSchema = {
  type: 'object',
  properties: {
    installedBuild: { type: 'string', nullable: true },
    latestBuild: { type: 'string', nullable: true },
    updateAvailable: { type: 'boolean' },
    checkedAt: { type: 'string', nullable: true },
    checkOk: { type: 'boolean' },
    pending: { type: 'boolean' },
    pendingReason: { type: 'string', nullable: true },
    lastRun: {
      type: 'object', nullable: true,
      properties: {
        startedAt: { type: 'string', nullable: true }, finishedAt: { type: 'string', nullable: true },
        exitCode: { type: 'integer', nullable: true }, ok: { type: 'boolean' },
        fromBuild: { type: 'string', nullable: true }, toBuild: { type: 'string', nullable: true },
        reason: { type: 'string', nullable: true }, log: { type: 'string', nullable: true },
      },
    },
  },
};

export function buildActions(dayz: DayzBridge, warnSeconds: number, heightmaps: HeightmapStore, timeseries: TimeseriesQuery): Record<string, Action> {
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

  // Read the update system's status across the sudo bridge (dayz-ctl update-status returns
  // one JSON object). Shared by the three update actions below.
  async function readUpdateStatus(): Promise<Record<string, unknown>> {
    const r = await dayz.ctl('update-status');
    if (r.code !== 0) throw fail(502, `update-status failed: ${(r.stderr || r.stdout).trim()}`);
    try {
      return JSON.parse(r.stdout);
    } catch {
      throw fail(502, 'update-status returned unparseable JSON');
    }
  }

  const lifecycle = (verb: 'restart' | 'stop' | 'start', destructive: boolean, ok: string): Action => ({
    destructive,
    readOnly: false,
    describe: `${verb} the DayZ server`,
    schema: { summary: `${verb} the DayZ server`, response: { type: 'object', properties: { message: { type: 'string' } } } },
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
      describe: 'server info: state, uptime, players (count + roster), map, mod list, next scheduled restart, and the unit footprint (memory, threads, log + persistence sizes, restarts). ONE call covers the whole server picture — it makes exactly one unit snapshot and one RCon query, so a dashboard needs neither a second players read nor the dayz half of /sysload.',
      schema: { response: { type: 'object', properties: {
        status: { type: 'string' }, since: { type: 'string', nullable: true },
        uptimeSeconds: { type: 'integer', nullable: true }, uptimeHuman: { type: 'string', nullable: true },
        players: { type: 'integer', nullable: true },
        roster: { type: 'array', items: { $ref: '#/components/schemas/Player' } },
        map: { type: 'string', nullable: true },
        modCount: { type: 'integer' }, mods: { type: 'array', items: { $ref: '#/components/schemas/Mod' } },
        restart: { type: 'object', nullable: true },
        unit: { type: 'object', properties: {
          memoryMb: { type: 'number' }, tasks: { type: 'integer' }, cpuTimeSec: { type: 'integer' },
          unitRestarts: { type: 'integer' }, logDirMb: { type: 'number' }, persistenceMb: { type: 'number' },
          mainPid: { type: 'integer', nullable: true },
        } },
      } } },
      async run() {
        // One dayz-ctl round-trip for the unit snapshot, one RCon call for players.
        // Players degrades to null (RCon down != status broken); the snapshot itself
        // failing is a real error.
        const [i, p] = await Promise.all([
          dayz.info(),
          dayz.players().catch(() => ({ count: null, players: [], raw: '' })),
        ]);
        return statusView(i, p, Math.floor(Date.now() / 1000));
      },
    },

    // Historical charts for the Maintenance tab. Reads the on-box Prometheus over loopback —
    // no dayz-ctl, no sudo, no pwsh. The browser sends KEYS from the server-owned table in
    // timeseries.ts and can never express a query, so there is nothing to inject; Grafana is
    // not in the path, so no allow_embedding / anonymous auth / public dashboard is needed.
    // The reply carries each metric's CURRENT value beside its history, which is what lets the
    // tab drop a separate poll instead of gaining one.
    timeseries: {
      destructive: false,
      readOnly: true,
      describe: `historical series for the charts: { "metrics": ["players_online", ...], "hours": ${RANGE_HOURS.join('|')} }. Keys come from the server-owned allowlist (${METRICS.map((m) => m.key).join(', ')}) — PromQL is never accepted. Each metric comes back with its points AND its latest value, so a caller needs no second request. Read-only, loopback Prometheus, briefly cached.`,
      schema: {
        body: { type: 'object', properties: {
          metrics: { type: 'array', items: { type: 'string', enum: METRICS.map((m) => m.key) },
            description: 'metric keys to chart; the pinned one is always included' },
          hours: { type: 'integer', enum: [...RANGE_HOURS], description: 'window size' },
        } },
        response: { type: 'object', properties: {
          hours: { type: 'integer' }, step: { type: 'integer' },
          from: { type: 'integer' }, to: { type: 'integer' },
          available: { type: 'array', items: { type: 'object', properties: {
            key: { type: 'string' }, label: { type: 'string' }, series: { type: 'string' },
            unit: { type: 'string' }, pinned: { type: 'boolean' }, on: { type: 'boolean' },
          } } },
          metrics: { type: 'array', items: { type: 'object', properties: {
            key: { type: 'string' }, label: { type: 'string' }, series: { type: 'string' }, unit: { type: 'string' },
            points: { type: 'array', items: { type: 'array', items: { type: 'number' } },
              description: '[epochSeconds, value] pairs. Prometheus OMITS what it never collected and so does this — a hole is an outage, and the UI draws it as a band rather than joining across it.' },
            latest: { type: 'object', nullable: true, properties: { at: { type: 'integer' }, value: { type: 'number' } } },
          } } },
        } },
      },
      async run(params) {
        // resolveMetrics / resolveHours throw 400s that name the offending value.
        return timeseries(params.metrics ?? [], params.hours ?? 24) as unknown as Record<string, unknown>;
      },
    },

    players: {
      destructive: false,
      readOnly: true,
      describe: 'current online players: count + roster (num, name, guid, ping, ip, lobby) via RCon',
      schema: { response: { type: 'object', properties: {
        count: { type: 'integer', nullable: true },
        players: { type: 'array', items: { $ref: '#/components/schemas/Player' } },
        raw: { type: 'string' },
      } } },
      async run() {
        const p = await dayz.players();
        return { count: p.count, players: p.players, raw: p.raw };
      },
    },

    mapchange: {
      destructive: true,
      readOnly: false,
      describe: 'switch the active mission and restart (body: { "mission": "dayzOffline.enoch" })',
      schema: {
        body: { type: 'object', required: ['mission'], properties: { mission: { type: 'string', description: 'mission folder under mpmissions/' } } },
        response: { type: 'object', properties: { message: { type: 'string' } } },
      },
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

    missions: {
      destructive: false,
      readOnly: true,
      describe: 'installed missions (folder names under mpmissions/) — the candidates a "mapchange" can switch to',
      schema: { response: { type: 'object', properties: { missions: { type: 'array', items: { type: 'string' } } } } },
      async run() {
        const r = await dayz.ctl('mission-list');
        if (r.code !== 0) throw fail(502, `mission-list failed: ${(r.stderr || r.stdout).trim()}`);
        const missions = r.stdout.split('\n').map((s) => s.replace(/\r$/, '').trim()).filter(Boolean);
        return { missions };
      },
    },

    broadcast: {
      destructive: false,
      readOnly: false,
      describe: 'send an in-game message to all players (body: { "message": "..." })',
      schema: {
        body: { type: 'object', required: ['message'], properties: { message: { type: 'string' } } },
        response: { type: 'object', properties: { message: { type: 'string' }, text: { type: 'string' } } },
      },
      async run(params) {
        const text = sanitizeText(String(params.message ?? ''));
        if (!text) throw fail(400, 'empty "message"');
        const r = await dayz.ctl('broadcast', text);
        if (r.code !== 0) throw fail(502, `broadcast failed: ${(r.stderr || r.stdout).trim()}`);
        return { message: 'broadcast sent', text };
      },
    },

    // Update system — ARM a deferred update; the download + swap happen on the next server
    // start (prestart.sh), so arming is non-destructive (nobody is kicked). update-check.sh
    // arms automatically when a newer build appears; this is the manual trigger. `restart`
    // (or the next scheduled restart) is what actually applies it.
    update: {
      destructive: false,
      readOnly: false,
      describe: 'queue a server update for the next restart — arms it; the next start (scheduled, manual, or forced) pulls the latest server build + mods. Does NOT restart now. Body: { reason? }',
      schema: {
        body: { type: 'object', properties: { reason: { type: 'string', description: 'free-text note surfaced in the update status' } } },
        response: { type: 'object', properties: { message: { type: 'string' }, status: UPDATE_STATUS_SCHEMA } },
      },
      async run(params) {
        const reason = String(params.reason ?? '').trim();
        const r = await dayz.ctl('update-arm', reason);
        if (r.code !== 0) throw fail(502, `update-arm failed: ${(r.stderr || r.stdout).trim()}`);
        // Best-effort heads-up to anyone online — no wait, since arming disrupts nothing.
        try {
          const p = await dayz.players();
          if (p.count) await dayz.ctl('broadcast', sanitizeText('[SERVER] A game update is queued - it applies at the next restart.'));
        } catch { /* broadcast is best-effort — never fail the arm on it */ }
        return { message: 'update queued for next restart', status: await readUpdateStatus() };
      },
    },

    'update/status': {
      destructive: false,
      readOnly: true,
      describe: 'update status: installed vs latest build, whether an update is available or already queued, and the last applied update outcome (with its log tail)',
      schema: { response: UPDATE_STATUS_SCHEMA },
      async run() {
        return readUpdateStatus();
      },
    },

    'update/cancel': {
      destructive: false,
      readOnly: false,
      describe: 'cancel a queued update (clears the pending flag) — no-op if none is queued',
      schema: { response: { type: 'object', properties: { message: { type: 'string' }, status: UPDATE_STATUS_SCHEMA } } },
      async run() {
        const r = await dayz.ctl('update-disarm');
        if (r.code !== 0) throw fail(502, `update-disarm failed: ${(r.stderr || r.stdout).trim()}`);
        return { message: 'update cancelled', status: await readUpdateStatus() };
      },
    },

    positions: {
      destructive: false,
      readOnly: true,
      describe: 'live player map positions, ANONYMIZED to [{x,z}] only — from the CustomServerMods LiveTracker serverMod (profiles/LiveTracker/players.json, rewritten every 20s from the live player roster, replacing the old minutes-lagged .ADM scrape). stale (>60s = server/mod down) or missing returns none rather than a frozen snapshot.',
      schema: {
        response: { type: 'object', properties: {
          players: { type: 'array', items: { type: 'object', properties: { x: { type: 'number' }, z: { type: 'number' } } } },
          count: { type: 'integer' },
          at: { type: 'string', nullable: true },   // box-clock HH:MM:SS of the freshest snapshot, for a staleness hint
        } },
      },
      async run() {
        // Read the LiveTracker player snapshot (a 20s heartbeat file). Same freshness contract as
        // the AI overlay: once the file passes the staleness window, drop positions rather than
        // plot ghosts from a dead server/mod. Coords are already {x,z} (mod writes p[0]/p[2]) — no
        // transform. The mod NEVER writes any id/name/GUID, so {x,z} is genuinely all there is.
        const STALE_SEC = 60;   // 3 missed 20s writes
        const r = await dayz.ctl('live-players');
        if (r.code === 2) return { players: [], count: 0, at: null };   // mod not loaded yet (fresh boot)
        if (r.code !== 0) throw fail(502, `live-players failed: ${(r.stderr || r.stdout).trim()}`);
        let env: { ageSec?: number; at?: string; positions?: Array<{ x: number; z: number }> };
        try { env = JSON.parse(r.stdout); }
        catch { throw fail(503, 'players.json unreadable (torn mid-write) — retry'); }   // caller keeps last-known
        const ageSec = typeof env.ageSec === 'number' ? env.ageSec : null;
        const stale = ageSec === null || ageSec > STALE_SEC;
        const players = (!stale && Array.isArray(env.positions)) ? env.positions.map((p) => ({ x: p.x, z: p.z })) : [];
        return { players, count: players.length, at: stale ? null : (env.at ?? null) };
      },
    },

    bandits: {
      destructive: false,
      readOnly: true,
      describe: 'live AI positions [{x,z,type,age}] from the CustomServerMods LiveTracker serverMod (profiles/LiveTracker/ai.json, rewritten every 20s). type = "eai" (ExpansionAI) | "bandit" (AI Bandits, only when @aibandits is loaded — retired); age = seconds that NPC has been alive this session (game clock, resets on restart). ageSec = seconds since the last FILE write; stale = older than the 60s freshness window (3 missed writes = server/mod down). stale and missing both return NO positions, so the map never plots a frozen snapshot.',
      schema: {
        response: { type: 'object', properties: {
          positions: { type: 'array', items: { type: 'object', properties: {
            x: { type: 'number' }, z: { type: 'number' },
            type: { type: 'string' },    // 'bandit' (AI Bandits, InfectedBanditBase) | 'eai' (ExpansionAI, eAIBase)
            age: { type: 'integer' },     // seconds this NPC has been alive at snapshot (session clock; resets on restart)
          } } },
          count: { type: 'integer' },
          ageSec: { type: 'integer', nullable: true },   // seconds since the file was last written; null when missing/unknown
          stale: { type: 'boolean' },                     // true = file older than the freshness window → positions dropped
          missing: { type: 'boolean' },                   // true = serverMod hasn't written the file yet (fresh boot / not loaded)
        } },
      },
      async run() {
        // Freshness, not liveness: the serverMod rewrites the file every 20s even when empty, so
        // its mtime is a heartbeat. dayz-ctl returns {ageSec, positions}; once ageSec passes the
        // window we drop the positions and flag stale rather than plot a snapshot from a dead
        // server/mod. The coords are already {x,z} (the mod writes p[0]/p[2]) — no transform.
        const STALE_SEC = 60;   // 3 missed 20s writes
        const r = await dayz.ctl('live-ai');
        if (r.code === 2) return { positions: [], count: 0, ageSec: null, stale: false, missing: true };
        if (r.code !== 0) throw fail(502, `live-ai failed: ${(r.stderr || r.stdout).trim()}`);
        let env: { ageSec?: number; positions?: Array<{ x: number; z: number; type?: string; age?: number }> };
        try { env = JSON.parse(r.stdout); }
        catch { throw fail(503, 'ai.json unreadable (torn mid-write) — retry'); }   // caller keeps last-known
        const ageSec = typeof env.ageSec === 'number' ? env.ageSec : null;
        const stale = ageSec === null || ageSec > STALE_SEC;
        const positions = (!stale && Array.isArray(env.positions)) ? env.positions : [];
        return { positions, count: positions.length, ageSec, stale, missing: false };
      },
    },

    ship: {
      destructive: false,
      readOnly: true,
      describe: 'the patrol ship position [{x,z,state,target}] from the FlyingDutchman serverMod (profiles/FlyingDutchman/ship.json, rewritten every ~20s; [] while no ship is alive). state = "patrol" | "docked" (town stop) | "halted" (holding for nearby players); target = the waypoint label it is heading to. Same freshness contract as the other live layers. missing = the mod is not enabled — it ships DORMANT, so missing is the normal state until the ship goes live.',
      schema: {
        response: { type: 'object', properties: {
          positions: { type: 'array', items: { type: 'object', properties: {
            x: { type: 'number' }, z: { type: 'number' },
            state: { type: 'string' },   // 'patrol' | 'docked' | 'halted'
            target: { type: 'string' },  // waypoint label the ship is heading to
          } } },
          route: { type: 'array', items: { type: 'object', properties: {
            x: { type: 'number' }, z: { type: 'number' },
            label: { type: 'string' },   // waypoint name — the map draws the loop through these
          } } },
          docks: { type: 'array', items: { type: 'object', properties: {
            x: { type: 'number' }, z: { type: 'number' },
            label: { type: 'string' },   // shore boarding pad(s) — "board here" markers
          } } },
          count: { type: 'integer' },
          ageSec: { type: 'integer', nullable: true },
          stale: { type: 'boolean' },
          missing: { type: 'boolean' },
        } },
      },
      async run() {
        // Mirrors the bandits/live-ai contract: heartbeat mtime, stale window, missing = mod off.
        // route + docks ride along even when the position is stale — they are static config.
        const STALE_SEC = 60;   // 3 missed ~20s writes
        const r = await dayz.ctl('live-ship');
        if (r.code === 2) return { positions: [], route: [], docks: [], count: 0, ageSec: null, stale: false, missing: true };
        if (r.code !== 0) throw fail(502, `live-ship failed: ${(r.stderr || r.stdout).trim()}`);
        let env: { ageSec?: number; positions?: Array<{ x: number; z: number; state?: string }>; route?: Array<{ x: number; z: number; label?: string }>; docks?: Array<{ x: number; z: number; label?: string }> };
        try { env = JSON.parse(r.stdout); }
        catch { throw fail(503, 'ship.json unreadable (torn mid-write) — retry'); }
        const ageSec = typeof env.ageSec === 'number' ? env.ageSec : null;
        const stale = ageSec === null || ageSec > STALE_SEC;
        const positions = (!stale && Array.isArray(env.positions)) ? env.positions : [];
        const route = Array.isArray(env.route) ? env.route : [];
        const docks = Array.isArray(env.docks) ? env.docks : [];
        return { positions, route, docks, count: positions.length, ageSec, stale, missing: false };
      },
    },

    'world-time': {
      destructive: false,
      readOnly: true,
      describe: 'the in-game world clock {year,month,day,hour,minute} from the CustomServerMods LiveTracker serverMod (profiles/LiveTracker/time.json, rewritten every 20s). ageSec = seconds since the last write; stale (>60s) flags a dead server/mod and nulls the fields; missing = mod not loaded yet (fresh boot). hour is the number that drives the day/night cycle (serverTimeAcceleration).',
      schema: {
        response: { type: 'object', properties: {
          year: { type: 'integer', nullable: true },
          month: { type: 'integer', nullable: true },
          day: { type: 'integer', nullable: true },
          hour: { type: 'integer', nullable: true },
          minute: { type: 'integer', nullable: true },
          ageSec: { type: 'integer', nullable: true },
          stale: { type: 'boolean' },
          missing: { type: 'boolean' },
        } },
      },
      async run() {
        // Same freshness contract as the position overlays: a stale file (server/mod down) nulls
        // the clock rather than reporting a frozen time. The mod writes a one-element array.
        const STALE_SEC = 60;
        const r = await dayz.ctl('world-time');
        if (r.code === 2) return { year: null, month: null, day: null, hour: null, minute: null, ageSec: null, stale: false, missing: true };
        if (r.code !== 0) throw fail(502, `world-time failed: ${(r.stderr || r.stdout).trim()}`);
        let env: { ageSec?: number; clock?: Array<{ year: number; month: number; day: number; hour: number; minute: number }> };
        try { env = JSON.parse(r.stdout); }
        catch { throw fail(503, 'time.json unreadable (torn mid-write) — retry'); }
        const ageSec = typeof env.ageSec === 'number' ? env.ageSec : null;
        const stale = ageSec === null || ageSec > STALE_SEC;
        const c = Array.isArray(env.clock) && env.clock.length ? env.clock[0] : null;
        if (!c || stale) return { year: null, month: null, day: null, hour: null, minute: null, ageSec, stale, missing: false };
        return { year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute, ageSec, stale, missing: false };
      },
    },

    // Logs group — the scroll/query surface over the server logs. `log` (above) stays
    // as the simple "tail the newest" shortcut; these add file choice, line ranges,
    // filtering and cursor-style paging for a log-viewer UI.
    'logs/sources': {
      destructive: false,
      readOnly: true,
      describe: 'list the browsable log sources (server rpt/adm + each mod that keeps its own logs) — ids feed the "source" param of the "logs/files" and "logs/read" actions. Add a source in deploy.config.json Dayz.LogSources.',
      schema: { response: { type: 'object', properties: { sources: { type: 'array', items: { type: 'object', properties: {
        id: { type: 'string' }, label: { type: 'string' },
      } } } } } },
      async run() {
        const r = await dayz.ctl('log-sources');
        if (r.code !== 0) throw fail(502, `log-sources failed: ${(r.stderr || r.stdout).trim()}`);
        // dayz-ctl emits "id<TAB>label", one per declared source, registry order.
        const sources = r.stdout
          .split('\n')
          .map((l) => l.replace(/\r$/, ''))
          .filter(Boolean)
          .map((line) => {
            const [id, label] = line.split('\t');
            return { id, label: label || id };
          })
          .filter((s) => s.id && /^[a-z0-9_-]+$/.test(s.id));
        return { sources };
      },
    },

    'logs/files': {
      destructive: false,
      readOnly: true,
      describe: 'list one log source\'s files, newest first — names feed the "logs/read" action. Params: source (an id from "logs/sources"; default rpt)',
      schema: {
        query: { type: 'object', properties: {
          source: { type: 'string', description: 'log source id from the "logs/sources" action (default rpt)' },
        } },
        response: { type: 'object', properties: { files: { type: 'array', items: { type: 'object', properties: {
          name: { type: 'string' }, sizeBytes: { type: 'integer' }, modified: { type: 'string' },
        } } } } },
      },
      async run(params) {
        const source = String(params.source ?? 'rpt') || 'rpt';
        if (!/^[a-z0-9_-]+$/.test(source)) throw fail(400, 'invalid "source" (use an id from the "logs/sources" action)');
        const r = await dayz.ctl('log-list', source);
        if (r.code === 2) throw fail(404, `unknown log source: ${source} (see the "logs/sources" action)`);
        if (r.code !== 0) throw fail(502, `log-list failed: ${(r.stderr || r.stdout).trim()}`);
        // dayz-ctl emits "name<TAB>bytes<TAB>mtime-iso", newest first.
        const files = r.stdout
          .split('\n')
          .map((l) => l.replace(/\r$/, ''))
          .filter(Boolean)
          .map((line) => {
            const [name, bytes, modified] = line.split('\t');
            return { name, sizeBytes: parseInt(bytes, 10) || 0, modified };
          })
          .filter((f) => f.name);
        return { files };
      },
    },

    'logs/read': {
      destructive: false,
      readOnly: true,
      describe: 'read a slice of one log: range, filter, scroll. Params: source (an id from "logs/sources"; default rpt) picks which log family; file (a name from "logs/files") or omit to read that source\'s newest file; offset = 1-based line to start at (omit for the tail); limit 1-500 (default 100); filter = grep -E regex matched per line; ignoreCase; raw = include the known-noise lines the box-side pre-filter hides by default (engine spam like Sakhal\'s "Unknown object class" — pattern set in deploy.config.json Dayz.LogNoiseFilter; noiseHidden reports how many were dropped). With a filter, offset/limit page through the MATCHED lines; every returned line keeps its original line number (n), and nextOffset/prevOffset are ready-made cursors for scrolling.',
      schema: {
        query: { type: 'object', properties: {
          source: { type: 'string', description: 'log source id from the "logs/sources" action (default rpt)' },
          file: { type: 'string', description: 'exact log filename from the "logs/files" action; omit to read the source\'s newest file' },
          offset: { type: 'integer', minimum: 0, description: '1-based line to start at — within the matched lines when "filter" is set; 0/omitted = the last "limit" lines (tail)' },
          limit: { type: 'integer', minimum: 1, maximum: 500, description: 'lines per page (default 100, max 500)' },
          filter: { type: 'string', maxLength: 256, description: 'ERE regex (grep -E syntax) — only matching lines come back' },
          ignoreCase: { type: 'boolean', description: 'case-insensitive filter matching' },
          raw: { type: 'boolean', description: 'disable the box-side noise pre-filter (deploy.config.json Dayz.LogNoiseFilter) and include the hidden engine-spam lines' },
        } },
        response: { type: 'object', properties: {
          file: { type: 'string' }, path: { type: 'string' },
          totalLines: { type: 'integer' }, matchedLines: { type: 'integer' },
          noiseHidden: { type: 'integer', description: 'lines hidden by the noise pre-filter (0 when raw is set or no filter is configured)' },
          offset: { type: 'integer' }, count: { type: 'integer' },
          nextOffset: { type: 'integer', nullable: true }, prevOffset: { type: 'integer', nullable: true },
          lines: { type: 'array', items: { type: 'object', properties: { n: { type: 'integer' }, text: { type: 'string' } } } },
        } },
      },
      async run(params) {
        const limit = Math.min(Math.max(parseInt(String(params.limit ?? ''), 10) || 100, 1), 500);
        const offset = Math.max(parseInt(String(params.offset ?? ''), 10) || 0, 0);
        const filter = String(params.filter ?? '');
        if (filter.length > 256) throw fail(400, '"filter" too long (max 256 chars)');
        const ci = params.ignoreCase === true || String(params.ignoreCase ?? '') === 'true';
        const raw = params.raw === true || String(params.raw ?? '') === 'true';
        const source = String(params.source ?? 'rpt') || 'rpt';
        if (!/^[a-z0-9_-]+$/.test(source)) throw fail(400, 'invalid "source" (use an id from the "logs/sources" action)');
        // Target: an exact filename from logs/files, or @newest = the source's newest file.
        // Shape check here; dayz-ctl re-validates the name against the source's own glob and
        // never forms a path from anything that isn't a bare existing name in the source dir.
        let target: string;
        if (params.file !== undefined && String(params.file) !== '') {
          target = String(params.file);
          if (!/^[A-Za-z0-9._-]+$/.test(target)) throw fail(400, 'invalid "file" (use a name from the "logs/files" action)');
        } else {
          target = '@newest';
        }
        // Positional verb args: source, name, then offset/limit/filter — empty placeholders keep 'raw' in slot 8.
        const args = [source, target, String(offset), String(limit), filter, ci ? 'ci' : '', raw ? 'raw' : ''];
        const r = await dayz.ctl('log-read', ...args);
        if (r.code === 2) throw fail(404, `log not found: ${source}/${target}`);
        if (r.code === 3) throw fail(400, 'invalid "filter" (grep -E syntax)');
        if (r.code !== 0) throw fail(502, `log-read failed: ${(r.stderr || r.stdout).trim()}`);
        // dayz-ctl's contract: line 1 = path, line 2 = total<TAB>matched<TAB>start<TAB>hidden,
        // rest = "<original-line-number>:<text>".
        const out = r.stdout.split('\n');
        const path = (out[0] ?? '').trim();
        const [total, matched, start, hidden] = (out[1] ?? '').split('\t').map((s) => parseInt(s, 10) || 0);
        const lines = out.slice(2)
          .filter((l) => l !== '')
          .map((l) => {
            const colon = l.indexOf(':');
            return colon > 0
              ? { n: parseInt(l.slice(0, colon), 10) || 0, text: l.slice(colon + 1).replace(/\r$/, '') }
              : { n: 0, text: l.replace(/\r$/, '') };
          });
        const next = start + lines.length <= matched && lines.length > 0 ? start + lines.length : null;
        const prev = start > 1 ? Math.max(1, start - limit) : null;
        return {
          file: path.split('/').pop() ?? path,
          path,
          totalLines: total,
          matchedLines: matched,
          noiseHidden: hidden,
          offset: start,
          count: lines.length,
          nextOffset: next,
          prevOffset: prev,
          lines,
        };
      },
    },

    'configs/list': {
      destructive: false,
      readOnly: true,
      describe: 'list the config files available to retrieve (names for the "configs/get" action)',
      schema: { response: { type: 'object', properties: { configs: { type: 'array', items: { type: 'object', properties: { group: { type: 'string' }, name: { type: 'string' }, label: { type: 'string' }, path: { type: 'string' }, readonly: { type: 'boolean' }, kind: { type: 'string' }, about: { type: 'string' }, aboutUrl: { type: 'string' } } } } } } },
      async run() {
        const r = await dayz.ctl('config-list');
        if (r.code !== 0) throw fail(502, `config-list failed: ${(r.stderr || r.stdout).trim()}`);
        const safe = /^[A-Za-z0-9_./-]+$/;
        // dayz-ctl emits "group<TAB>name<TAB>label<TAB>relpath<TAB>ro<TAB>kind<TAB>about<TAB>aboutUrl"
        // per file (single files + expanded folder contents). The relpath is the UI's dedup key
        // across a file's read alias and folder listing; ro='1' marks a web:'view'
        // surface the editor locks read-only; kind is the registry 'web' value (view/file/patch/
        // types/...) so the editor can pick a surface-specific view (e.g. 'types' -> the CE types
        // editor); about + aboutUrl are the "About this file" line under the filename and its
        // citation link (folder-expanded rows carry neither and emit empty fields).
        // Tolerate short lines from an older ctl (ro/kind absent -> false/'file'). Drop names
        // we couldn't serve.
        // aboutUrl is re-validated here even though Deploy-Api already checks it: the editor
        // renders it as an href, so http(s)-only is enforced at BOTH ends, never once.
        const httpUrl = /^https?:\/\/[^\s<>"']+$/;
        const configs = r.stdout
          .split('\n')
          .map((l) => l.replace(/\r$/, ''))
          .filter(Boolean)
          .map((line) => {
            const p = line.split('\t');
            return p.length >= 3
              ? { group: p[0], name: p[1], label: p[2], path: p[3] && safe.test(p[3]) ? p[3] : p[1], readonly: p[4] === '1', kind: p[5] && /^[a-z]+$/.test(p[5]) ? p[5] : 'file', about: (p[6] || '').trim(), aboutUrl: httpUrl.test((p[7] || '').trim()) ? (p[7] || '').trim() : '' }
              : { group: 'General', name: p[0], label: p[0], path: p[0], readonly: false, kind: 'file', about: '', aboutUrl: '' };
          })
          .filter((c) => c.name && safe.test(c.name));
        return { configs };
      },
    },

    'configs/get': {
      destructive: false,
      readOnly: true,
      describe: 'retrieve one allowlisted config file (params: { "name": "serverSettings" }; see the "configs/list" action for names)',
      schema: {
        query: { type: 'object', required: ['name'], properties: { name: { type: 'string' } } },
        response: { type: 'object', properties: { name: { type: 'string' }, path: { type: 'string' }, content: { type: 'string' } } },
      },
      async run(params) {
        const name = String(params.name ?? '');
        if (!/^[A-Za-z0-9_./-]+$/.test(name) || name.includes('..')) throw fail(400, 'invalid or missing "name"');
        const r = await dayz.ctl('config', name);
        if (r.code === 2) throw fail(404, `unknown config '${name}' (see the "configs/list" action for valid names)`);
        if (r.code === 3) throw fail(413, `config '${name}' is too large to retrieve`);
        if (r.code !== 0) throw fail(502, `config failed: ${(r.stderr || r.stdout).trim()}`);
        // dayz-ctl's contract: line 1 = the resolved path, the rest = the contents.
        const nl = r.stdout.indexOf('\n');
        const path = (nl >= 0 ? r.stdout.slice(0, nl) : r.stdout).trim();
        const content = nl >= 0 ? r.stdout.slice(nl + 1) : '';
        return { name, path, content };
      },
    },




    // Mod-docs browser — the read-only analogue of configs/list + configs/get, but the files
    // live INSIDE the @mod folders (readmes, notices, example configs), discovered by dayz-ctl.
    'docs/list': {
      destructive: false,
      readOnly: true,
      describe: 'list documentation files bundled in the @mod folders (paths for the "docs/get" action)',
      schema: {
        response: { type: 'object', properties: { docs: { type: 'array', items: { type: 'object', properties: {
          mod: { type: 'string' }, path: { type: 'string' }, name: { type: 'string' },
        } } } } },
      },
      async run() {
        const r = await dayz.ctl('doc-list');
        if (r.code !== 0) throw fail(502, `doc-list failed: ${(r.stderr || r.stdout).trim()}`);
        const safe = /^[A-Za-z0-9_@./-]+$/;
        // dayz-ctl emits "mod<TAB>relpath<TAB>relname" per file.
        const docs = r.stdout
          .split('\n')
          .map((l) => l.replace(/\r$/, ''))
          .filter(Boolean)
          .map((line) => {
            const p = line.split('\t');
            return { mod: p[0] ?? '', path: p[1] ?? '', name: p[2] ?? p[1] ?? '' };
          })
          .filter((d) => d.path && safe.test(d.path));
        return { docs };
      },
    },

    'docs/get': {
      destructive: false,
      readOnly: true,
      describe: 'retrieve one mod-doc file by relpath (params: { "name": "@aibunleashed/readme.txt" }; see the "docs/list" action)',
      schema: {
        query: { type: 'object', required: ['name'], properties: { name: { type: 'string', description: 'a path from the "docs/list" action' } } },
        response: { type: 'object', properties: { name: { type: 'string' }, path: { type: 'string' }, content: { type: 'string' } } },
      },
      async run(params) {
        const name = String(params.name ?? '');
        if (!/^[A-Za-z0-9_@./-]+$/.test(name) || name.includes('..')) throw fail(400, 'invalid or missing "name"');
        const r = await dayz.ctl('doc-read', name);
        if (r.code === 2) throw fail(404, `unknown doc '${name}'`);
        if (r.code === 3) throw fail(413, `doc '${name}' is too large to retrieve`);
        if (r.code !== 0) throw fail(502, `doc-read failed: ${(r.stderr || r.stdout).trim()}`);
        const nl = r.stdout.indexOf('\n');
        const path = (nl >= 0 ? r.stdout.slice(0, nl) : r.stdout).trim();
        const content = nl >= 0 ? r.stdout.slice(nl + 1) : '';
        return { name, path, content };
      },
    },

    'configs/writable': {
      destructive: false,
      readOnly: true,
      describe: 'list the box-owned files an admin may replace whole via configs/set-own (ban/allow lists)',
      schema: { response: { type: 'object', properties: { files: { type: 'array', items: { type: 'object', properties: { name: { type: 'string' }, path: { type: 'string' } } } } } } },
      async run() {
        const r = await dayz.ctl('file-list');
        if (r.code !== 0) throw fail(502, `file-list failed: ${(r.stderr || r.stdout).trim()}`);
        const files = r.stdout
          .split('\n')
          .map((l) => l.replace(/\r$/, ''))
          .filter(Boolean)
          .map((line) => { const [name, path] = line.split('\t'); return { name, path }; })
          .filter((f) => f.name && f.path);
        return { files };
      },
    },

    'configs/readonly': {
      destructive: false,
      readOnly: true,
      describe: 'list the generated (compiler-output) config globs the web editor must render read-only; own-write refuses to target any of them',
      schema: { response: { type: 'object', properties: { files: { type: 'array', items: { type: 'string' } } } } },
      async run() {
        const r = await dayz.ctl('config-generated');
        if (r.code !== 0) throw fail(502, `config-generated failed: ${(r.stderr || r.stdout).trim()}`);
        const files = r.stdout
          .split('\n')
          .map((l) => l.replace(/\r$/, '').trim())
          .filter(Boolean);
        return { files };
      },
    },

    'configs/disabled': {
      destructive: false,
      readOnly: true,
      describe: 'list config surface relpaths whose owning mod is disabled in mods.conf; the web editor drops these rows so a turned-off mod stops surfacing its config files (the box-side files stay intact)',
      schema: { response: { type: 'object', properties: { files: { type: 'array', items: { type: 'string' } } } } },
      async run() {
        const r = await dayz.ctl('config-disabled');
        if (r.code !== 0) throw fail(502, `config-disabled failed: ${(r.stderr || r.stdout).trim()}`);
        const files = r.stdout
          .split('\n')
          .map((l) => l.replace(/\r$/, '').trim())
          .filter(Boolean);
        return { files };
      },
    },

    'configs/owned': {
      destructive: false,
      readOnly: true,
      describe: 'the owned-surface masks (registry category:\'owned\'): files = exact relpaths, dirs = folders whose json/xml files are owned. The web editor routes matching rows to the whole-file two-copy editor (configs/own + configs/set-own) instead of a raw text edit. edited = owned files that have a captured .defaults baseline beside them, i.e. saved through the editor at least once — the tree marks those; it does NOT mean the content differs from the baseline today.',
      schema: { response: { type: 'object', properties: { files: { type: 'array', items: { type: 'string' } }, dirs: { type: 'array', items: { type: 'string' } }, edited: { type: 'array', items: { type: 'string' } } } } },
      async run() {
        const r = await dayz.ctl('config-owned');
        if (r.code !== 0) throw fail(502, `config-owned failed: ${(r.stderr || r.stdout).trim()}`);
        const files: string[] = []; const dirs: string[] = []; const edited: string[] = [];
        for (const line of r.stdout.split('\n')) {
          const [k, v] = line.replace(/\r$/, '').split('\t');
          if (k === 'F' && v) files.push(v);
          else if (k === 'D' && v) dirs.push(v);
          else if (k === 'E' && v) edited.push(v);
        }
        return { files, dirs, edited };
      },
    },

    'configs/own': {
      destructive: false,
      readOnly: true,
      describe: 'one category-\'owned\' config file raw, plus its version hash — the generic whole-file read of the two-copy model (Phase 1). path = a ServerDir-relative file under an owned registry surface (json/xml only). Pass the version back to configs/set-own as baseVersion so a concurrent admin edit is rejected (409).',
      schema: {
        query: { type: 'object', required: ['path'], properties: { path: { type: 'string', description: 'ServerDir-relative path of an owned config file (e.g. profiles/ExpansionMod/Loadouts/TownLoadout.json)' } } },
        response: { type: 'object', properties: { path: { type: 'string' }, version: { type: 'string' }, content: { type: 'string' } } },
      },
      async run(params) {
        const path = String(params.path ?? '');
        if (!/^[A-Za-z0-9_./-]+$/.test(path) || path.includes('..')) throw fail(400, 'invalid or missing "path"');
        const r = await dayz.ctl('own-read', path);
        if (r.code === 2) throw fail(404, `'${path}' is not an owned config surface (or its file is not on the box)`);
        if (r.code !== 0) throw fail(502, `own-read failed: ${(r.stderr || r.stdout).trim()}`);
        // dayz-ctl's contract: line 1 = sha256, the rest = the raw contents.
        const nl = r.stdout.indexOf('\n');
        const version = (nl >= 0 ? r.stdout.slice(0, nl) : r.stdout).trim();
        const content = nl >= 0 ? r.stdout.slice(nl + 1) : '';
        return { path, version, content };
      },
    },

    'configs/set-own': {
      destructive: false,
      readOnly: false,
      describe: 'replace one category-\'owned\' config file whole — the generic whole-file write of the two-copy model; the bespoke types/settings writers migrate onto it. The box validates by extension (JSON parse / well-formed XML), refuses generated + disabled-mod + non-owned paths, snapshots the outgoing version (.own-versions/, keep 30), and writes atomically. Pass baseVersion (from configs/own) for optimistic concurrency (409 on conflict).',
      schema: {
        body: { type: 'object', required: ['path', 'content'], properties: {
          path: { type: 'string', description: 'ServerDir-relative path of an owned config file (same path configs/own takes)' },
          content: { type: 'string', description: 'the complete new document (whole file, not a delta)' },
          baseVersion: { type: 'string', description: 'the version hash from configs/own this edit was based on — the box rejects the write with 409 if the file changed since. Omit to skip the check (last-write-wins).' },
        } },
        response: { type: 'object', properties: { message: { type: 'string' }, version: { type: 'string' } } },
      },
      async run(params) {
        const path = String(params.path ?? '');
        if (!/^[A-Za-z0-9_./-]+$/.test(path) || path.includes('..')) throw fail(400, 'invalid or missing "path"');
        if (typeof params.content !== 'string' || !params.content.trim()) throw fail(400, '"content" must be the whole document');
        if (params.content.length > 2097152) throw fail(413, '"content" too large (max 2MB)');
        // Content travels over STDIN (ctlStdin puts '-' at $2), so the path rides third — own-write's arg order.
        const extra: string[] = [path];
        if (typeof params.baseVersion === 'string' && params.baseVersion.length) extra.push(`base=${params.baseVersion}`);
        const r = await dayz.ctlStdin('own-write', params.content, ...extra);
        if (r.code === 2) throw fail(404, `'${path}' is not an owned config surface (or its file is not on the box)`);
        if (r.code === 5) throw fail(409, (r.stderr || r.stdout).trim().replace(/^dayz-ctl:\s*/, ''));  // concurrent-edit conflict
        if (r.code !== 0) throw fail(502, `own-write failed: ${(r.stderr || r.stdout).trim()}`);
        // stdout = "ok\n<newVersion>" — hand the new version back so the caller can rebase.
        const lines = r.stdout.split('\n').map((s) => s.trim()).filter(Boolean);
        return { message: `${path} saved (previous version snapshotted on the box); restart the server to apply`, version: lines.length > 1 ? lines[1] : '' };
      },
    },



    // Terrain group — baked-heightmap lookups, no game-server involvement. Slashed
    // names route as /dayz/terrain/<name> via the grouped dispatcher in commands.ts.
    'terrain/heightmaps': {
      destructive: false,
      readOnly: true,
      describe: 'list the maps with baked terrain heightmaps (inputs for the terrain/surface-y action)',
      schema: { response: { type: 'object', properties: { maps: { type: 'array', items: { type: 'object', properties: {
        map: { type: 'string' }, worldSize: { type: 'number' }, gridN: { type: 'integer' },
        cellSize: { type: 'number' }, minY: { type: 'number' }, maxY: { type: 'number' }, sizeBytes: { type: 'integer' },
      } } } } } },
      async run() {
        // Pure local file metadata — no dayz-ctl, no game server involvement.
        return { maps: heightmaps.list() };
      },
    },

    'terrain/surface-y': {
      destructive: false,
      readOnly: true,
      describe: 'resolve terrain height Y at world X/Z from the baked heightmap (single: map, x, z — or bulk: body { map, points: [{x,z},…] }; see "terrain/heightmaps" for maps)',
      schema: {
        query: { type: 'object', required: ['map'], properties: {
          map: { type: 'string', description: 'a map name from the "terrain/heightmaps" action (e.g. sakhal)' },
          x: { type: 'number', description: 'world X in meters (0..worldSize) — single mode' },
          z: { type: 'number', description: 'world Z in meters (0..worldSize) — single mode' },
        } },
        body: { type: 'object', properties: {
          map: { type: 'string' },
          x: { type: 'number' }, z: { type: 'number' },
          points: { type: 'array', maxItems: 2000, description: 'bulk mode: up to 2000 {x,z} pairs resolved in one call; out-of-range points come back with y: null',
            items: { type: 'object', required: ['x', 'z'], properties: { x: { type: 'number' }, z: { type: 'number' } } } },
        } },
        response: { type: 'object', properties: {
          map: { type: 'string' }, x: { type: 'number' }, z: { type: 'number' },
          y: { type: 'number' }, worldSize: { type: 'number' }, cellSize: { type: 'number' },
          count: { type: 'integer' }, points: { type: 'array', items: { type: 'object', properties: { x: { type: 'number' }, z: { type: 'number' }, y: { type: 'number', nullable: true } } } },
        } },
      },
      async run(params) {
        // Baked-grid lookup, validated to <=0.5 m against an in-engine SurfaceY oracle
        // (see DayZHeightmap). Same bilinear math as the ConfigViewer sampler.
        const map = String(params.map ?? '');
        if (!/^[a-z0-9_-]+$/i.test(map)) throw fail(400, 'invalid or missing "map" (see the "terrain/heightmaps" action)');
        const hm = heightmaps.get(map);
        if (!hm) {
          const known = heightmaps.list().map((m) => m.map);
          throw fail(404, `no heightmap for '${map}' (available: ${known.length ? known.join(', ') : 'none shipped yet'})`);
        }
        const ws = hm.meta.worldSize;
        // Bulk mode: one signed call resolves a whole point set (a map UI's worth) —
        // per-point calls would burn the global rate limit. Out-of-range points are
        // y:null rather than failing the batch, so one stray bookmark can't kill it.
        if (Array.isArray(params.points)) {
          const pts = params.points as Array<Record<string, unknown>>;
          if (pts.length < 1 || pts.length > 2000) throw fail(400, '"points" must hold 1..2000 entries');
          const points = pts.map((p) => {
            const px = Number(p?.x);
            const pz = Number(p?.z);
            if (!Number.isFinite(px) || !Number.isFinite(pz)) throw fail(400, 'every "points" entry needs numeric x and z');
            const inRange = px >= 0 && px <= ws && pz >= 0 && pz <= ws;
            return { x: px, z: pz, y: inRange ? Math.round(heightmaps.sample(hm, px, pz) * 1000) / 1000 : null };
          });
          return { map, worldSize: ws, cellSize: hm.meta.cellSize, count: points.length, points };
        }
        const x = Number(params.x);
        const z = Number(params.z);
        if (!Number.isFinite(x) || !Number.isFinite(z)) throw fail(400, '"x" and "z" must be numbers (meters)');
        if (x < 0 || x > ws || z < 0 || z > ws) throw fail(400, `x/z out of range for ${map} (0..${ws})`);
        const y = Math.round(heightmaps.sample(hm, x, z) * 1000) / 1000;
        return { map, x, z, y, worldSize: ws, cellSize: hm.meta.cellSize };
      },
    },


  };
}
