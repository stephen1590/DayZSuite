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

export function buildActions(dayz: DayzBridge, warnSeconds: number, heightmaps: HeightmapStore): Record<string, Action> {
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
      describe: 'server info: state, uptime, players, map, mod list, next scheduled restart',
      schema: { response: { type: 'object', properties: {
        status: { type: 'string' }, since: { type: 'string', nullable: true },
        uptimeSeconds: { type: 'integer', nullable: true }, uptimeHuman: { type: 'string', nullable: true },
        players: { type: 'integer', nullable: true }, map: { type: 'string', nullable: true },
        modCount: { type: 'integer' }, mods: { type: 'array', items: { $ref: '#/components/schemas/Mod' } },
        restart: { type: 'object', nullable: true },
      } } },
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
      describe: 'live player map positions, ANONYMIZED to [{x,z}] only — parsed from the newest .ADM (needs adminLogPlayerList for a full roster)',
      schema: {
        response: { type: 'object', properties: {
          players: { type: 'array', items: { type: 'object', properties: { x: { type: 'number' }, z: { type: 'number' } } } },
          count: { type: 'integer' },
          at: { type: 'string', nullable: true },   // server-clock HH:MM:SS of the freshest fix, for a staleness hint
        } },
      },
      async run() {
        // Tail the newest ADM via log-read (source 'adm', @newest file, tail mode: start 0).
        // Contract: line 1 = path, line 2 = totals header, rest = "N:text" — strip the numbers.
        const r = await dayz.ctl('log-read', 'adm', '@newest', '0', '500');
        if (r.code === 2) throw fail(404, 'no .ADM log found (server not started, or -adminlog off)');
        if (r.code !== 0) throw fail(502, `log read failed: ${(r.stderr || r.stdout).trim()}`);
        const tail = r.stdout.split('\n').slice(2).map((l) => l.replace(/^\d+:/, ''));
        // Walk the .ADM chronologically, keeping each connected player's LATEST fix. Works off
        // event lines today (hits/connects); once adminLogPlayerList is on, the periodic roster
        // uses the SAME "Player "..." (id=... pos=<x, z, elev>)" shape and is simply the newest.
        // The id is used ONLY as a dedup/connection key and is NEVER returned — {x,z} is all that leaves.
        const RE = /^(\d\d:\d\d:\d\d) \| Player "[^"]*" \(id=([^\s)]+) pos=<([-\d.]+),\s*([-\d.]+),\s*[-\d.]+>\)(.*)$/;
        const live = new Map(); // id -> { x, z, at }
        let at = null;
        for (const raw of tail) {
          const m = RE.exec(raw.replace(/\r$/, ''));
          if (!m) continue;
          const [, ts, id, xs, zs, rest] = m;
          if (/disconnected/.test(rest)) { live.delete(id); continue; }   // left the server — drop the pin
          live.set(id, { x: Number(xs), z: Number(zs), at: ts });
          at = ts;   // lines are chronological, so the last match is the freshest
        }
        return { players: [...live.values()].map((p) => ({ x: p.x, z: p.z })), count: live.size, at };
      },
    },

    bandits: {
      destructive: false,
      readOnly: true,
      describe: 'live AI-bandit positions [{x,z}] from the AIB_Tracker serverMod (profiles/AI_Bandits/live_positions.json, rewritten every 20s). ageSec = seconds since the last write; stale = older than the 60s freshness window (3 missed writes = server/mod down). stale and missing both return NO positions, so the map never plots a frozen snapshot.',
      schema: {
        response: { type: 'object', properties: {
          positions: { type: 'array', items: { type: 'object', properties: { x: { type: 'number' }, z: { type: 'number' } } } },
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
        const r = await dayz.ctl('bandit-live');
        if (r.code === 2) return { positions: [], count: 0, ageSec: null, stale: false, missing: true };
        if (r.code !== 0) throw fail(502, `bandit-live failed: ${(r.stderr || r.stdout).trim()}`);
        let env: { ageSec?: number; positions?: Array<{ x: number; z: number }> };
        try { env = JSON.parse(r.stdout); }
        catch { throw fail(503, 'live_positions.json unreadable (torn mid-write) — retry'); }   // caller keeps last-known
        const ageSec = typeof env.ageSec === 'number' ? env.ageSec : null;
        const stale = ageSec === null || ageSec > STALE_SEC;
        const positions = (!stale && Array.isArray(env.positions)) ? env.positions : [];
        return { positions, count: positions.length, ageSec, stale, missing: false };
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
      schema: { response: { type: 'object', properties: { configs: { type: 'array', items: { type: 'object', properties: { group: { type: 'string' }, name: { type: 'string' }, label: { type: 'string' }, path: { type: 'string' } } } } } } },
      async run() {
        const r = await dayz.ctl('config-list');
        if (r.code !== 0) throw fail(502, `config-list failed: ${(r.stderr || r.stdout).trim()}`);
        const safe = /^[A-Za-z0-9_./-]+$/;
        // dayz-ctl emits "group<TAB>name<TAB>label<TAB>relpath" per file (single files +
        // expanded folder contents). The relpath is the UI's dedup key across a file's
        // read alias / folder listing / override target. Tolerate short lines from an
        // older ctl. Drop names we couldn't serve.
        const configs = r.stdout
          .split('\n')
          .map((l) => l.replace(/\r$/, ''))
          .filter(Boolean)
          .map((line) => {
            const p = line.split('\t');
            return p.length >= 3
              ? { group: p[0], name: p[1], label: p[2], path: p[3] && safe.test(p[3]) ? p[3] : p[1] }
              : { group: 'General', name: p[0], label: p[0], path: p[0] };
          })
          .filter((c) => c.name && safe.test(c.name));
        return { configs };
      },
    },

    'configs/get': {
      destructive: false,
      readOnly: true,
      describe: 'retrieve one allowlisted config file (params: { "name": "overrides" }; see the "configs/list" action for names)',
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

    'configs/target': {
      destructive: false,
      readOnly: true,
      describe: 'retrieve one config-overrides TARGET file in full, by relpath (whole-file context for the overrides editor)',
      schema: {
        query: { type: 'object', required: ['name'], properties: { name: { type: 'string', description: 'server-dir-relative path of a file config-overrides.json patches' } } },
        response: { type: 'object', properties: { name: { type: 'string' }, path: { type: 'string' }, content: { type: 'string' } } },
      },
      async run(params) {
        const name = String(params.name ?? '');
        if (!/^[A-Za-z0-9_./-]+$/.test(name) || name.includes('..')) throw fail(400, 'invalid or missing "name"');
        const r = await dayz.ctl('config-target', name);
        if (r.code === 2) throw fail(404, `unknown config target '${name}' (not an override target or allowlisted config)`);
        if (r.code === 3) throw fail(413, `config target '${name}' is too large to retrieve`);
        if (r.code !== 0) throw fail(502, `config-target failed: ${(r.stderr || r.stdout).trim()}`);
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
      describe: 'list the box-owned files an admin may replace whole via configs/set-file (ban/allow lists)',
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

    'configs/set-file': {
      destructive: false,
      readOnly: false,
      describe: 'replace one box-owned file whole (body: { "name": "Bans", "content": "..." }; snapshots first)',
      schema: {
        body: { type: 'object', required: ['name', 'content'], properties: {
          name: { type: 'string', description: 'a name from the configs/writable list' },
          content: { type: 'string', description: 'the complete new file contents' },
        } },
        response: { type: 'object', properties: { message: { type: 'string' }, name: { type: 'string' } } },
      },
      async run(params) {
        const name = String(params.name ?? '');
        if (!/^[A-Za-z0-9_.-]+$/.test(name)) throw fail(400, 'invalid or missing "name"');
        if (typeof params.content !== 'string') throw fail(400, '"content" must be a string (the whole file)');
        if (params.content.length > 262144) throw fail(413, '"content" too large (max 256KB)');
        const r = await dayz.ctl('file-write', name, params.content);
        if (r.code === 2) throw fail(404, `'${name}' is not a writable file (see configs/writable)`);
        if (r.code !== 0) throw fail(502, `file-write failed: ${(r.stderr || r.stdout).trim()}`);
        return { message: `${name} replaced (previous version snapshotted on the box)`, name };
      },
    },

    'configs/set-overrides': {
      destructive: false,
      readOnly: false,
      describe: 'replace config-overrides.json with a new document (snapshots first; restart to apply)',
      schema: {
        body: { type: 'object', required: ['document'], properties: { document: { type: 'object', description: 'the full config-overrides.json document' } } },
        response: { type: 'object', properties: { message: { type: 'string' } } },
      },
      async run(params) {
        const doc = params.document;
        if (doc === null || typeof doc !== 'object' || Array.isArray(doc)) throw fail(400, '"document" must be a JSON object');
        const r = await dayz.ctl('override-write', JSON.stringify(doc, null, 4));
        if (r.code !== 0) throw fail(502, `override-write failed: ${(r.stderr || r.stdout).trim()}`);
        return { message: 'overrides saved; restart the server to apply' };
      },
    },

    'configs/set-spawns': {
      destructive: false,
      readOnly: false,
      describe: 'replace spawn-points.json (the definitive AI-bandit spawn store) with a new document (snapshots first; restart to apply)',
      schema: {
        body: { type: 'object', required: ['document'], properties: { document: { type: 'object',
          description: 'the full spawn-points.json document: { version, points: [{ name, map, category?, size?, x, y, z }] }' } } },
        response: { type: 'object', properties: { message: { type: 'string' }, points: { type: 'integer' } } },
      },
      async run(params) {
        // Validate here so a malformed document never reaches the box. The builder is fail-soft,
        // but the point of a definitive store is to keep it clean. dayz-ctl re-checks it is JSON.
        const doc = params.document;
        if (doc === null || typeof doc !== 'object' || Array.isArray(doc)) throw fail(400, '"document" must be a JSON object');
        const pts = (doc as { points?: unknown }).points;
        if (!Array.isArray(pts)) throw fail(400, '"document.points" must be an array');
        if (pts.length > 5000) throw fail(400, `too many points (${pts.length}; max 5000)`);
        const names = new Set<string>();
        pts.forEach((raw, i) => {
          if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) throw fail(400, `points[${i}] must be an object`);
          const p = raw as Record<string, unknown>;
          if (typeof p.name !== 'string' || !p.name.trim()) throw fail(400, `points[${i}].name must be a non-empty string`);
          if (typeof p.map !== 'string' || !p.map.trim()) throw fail(400, `points[${i}].map must be a non-empty string`);
          for (const k of ['x', 'y', 'z'] as const) {
            if (typeof p[k] !== 'number' || !Number.isFinite(p[k])) throw fail(400, `points[${i}].${k} must be a finite number`);
          }
          if (p.category !== undefined && p.category !== null && typeof p.category !== 'string') throw fail(400, `points[${i}].category must be a string`);
          if (p.size !== undefined && p.size !== null && typeof p.size !== 'string') throw fail(400, `points[${i}].size must be a string`);
          // The builder upserts by name — a duplicate would silently collapse two points into one.
          if (names.has(p.name)) throw fail(400, `duplicate point name: ${p.name}`);
          names.add(p.name);
        });
        const r = await dayz.ctl('spawn-write', JSON.stringify(doc, null, 2));
        if (r.code !== 0) throw fail(502, `spawn-write failed: ${(r.stderr || r.stdout).trim()}`);
        return { message: 'spawn points saved; restart the server to apply', points: pts.length };
      },
    },

    'configs/override-versions': {
      destructive: false,
      readOnly: true,
      describe: 'list config-overrides.json snapshots (newest first) for rollback',
      schema: { response: { type: 'object', properties: { versions: { type: 'array', items: { type: 'string' } } } } },
      async run() {
        const r = await dayz.ctl('override-versions');
        if (r.code !== 0) throw fail(502, `override-versions failed: ${(r.stderr || r.stdout).trim()}`);
        return { versions: r.stdout.split('\n').map((s) => s.trim()).filter(Boolean) };
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

    'configs/override-rollback': {
      destructive: false,
      readOnly: false,
      describe: 'restore a config-overrides.json snapshot (restart to apply)',
      schema: {
        body: { type: 'object', required: ['version'], properties: { version: { type: 'string' } } },
        response: { type: 'object', properties: { message: { type: 'string' }, version: { type: 'string' } } },
      },
      async run(params) {
        const version = String(params.version ?? '');
        if (!/^[0-9TZ]+$/.test(version)) throw fail(400, 'invalid version');
        const r = await dayz.ctl('override-rollback', version);
        if (r.code === 2) throw fail(404, `unknown version '${version}'`);
        if (r.code !== 0) throw fail(502, `override-rollback failed: ${(r.stderr || r.stdout).trim()}`);
        return { message: `rolled back to ${version}; restart to apply`, version };
      },
    },

  };
}
