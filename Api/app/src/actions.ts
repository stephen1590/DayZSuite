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
        // Tail the newest ADM via log-read (tail mode: start 0). Contract: line 1 =
        // path, line 2 = totals header, rest = "N:text" — strip the line numbers.
        const r = await dayz.ctl('log-read', 'adm', '0', '500');
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
      describe: 'recent AI-bandit activity from the AIB Unleashed log: spawn + kill positions [{x,z}] — APPROXIMATE (spawn coords, not live tracking; the -serverMod route is the precise one)',
      schema: {
        response: { type: 'object', properties: {
          spawns: { type: 'array', items: { type: 'object', properties: { x: { type: 'number' }, z: { type: 'number' } } } },
          kills: { type: 'array', items: { type: 'object', properties: { x: { type: 'number' }, z: { type: 'number' } } } },
          at: { type: 'string', nullable: true },   // server-clock HH:MM:SS of the newest event
        } },
      },
      async run() {
        // The newest AIB Unleashed log's SPAWN/KILLED lines (line 1 = path, rest = matches).
        // AIB_UL logs positions as (X, elevation, Z) — standard vector — so keep the FIRST and
        // THIRD numbers. (The .ADM player log differs: elevation is LAST there. Same x/z plane.)
        const r = await dayz.ctl('bandit-log', '400');
        if (r.code === 2) return { spawns: [], kills: [], at: null };   // no AIB log yet — not an error
        if (r.code !== 0) throw fail(502, `bandit-log failed: ${(r.stderr || r.stdout).trim()}`);
        const lines = r.stdout.split('\n').slice(1);
        // Hour may or may not be zero-padded depending on the mod's formatter — accept 1-2 digits.
        const RE = /\[(\d{1,2}:\d\d:\d\d)\] \[[A-Z]+\] (SPAWN|KILLED): \S+ at \(([-\d.]+),\s*[-\d.]+,\s*([-\d.]+)\)/;
        const spawns: Array<{ x: number; z: number }> = [];
        const kills: Array<{ x: number; z: number }> = [];
        let at = null;
        for (const raw of lines) {
          const m = RE.exec(raw);
          if (!m) continue;
          const [, ts, kind, xs, zs] = m;
          (kind === 'SPAWN' ? spawns : kills).push({ x: Number(xs), z: Number(zs) });
          at = ts;
        }
        return { spawns, kills, at };
      },
    },

    // Logs group — the scroll/query surface over the server logs. `log` (above) stays
    // as the simple "tail the newest" shortcut; these add file choice, line ranges,
    // filtering and cursor-style paging for a log-viewer UI.
    'logs/files': {
      destructive: false,
      readOnly: true,
      describe: 'list the server log files (rpt + adm), newest first — names feed the "logs/read" action',
      schema: { response: { type: 'object', properties: { files: { type: 'array', items: { type: 'object', properties: {
        name: { type: 'string' }, type: { type: 'string', enum: ['rpt', 'adm'] },
        sizeBytes: { type: 'integer' }, modified: { type: 'string' },
      } } } } } },
      async run() {
        const r = await dayz.ctl('log-list');
        if (r.code !== 0) throw fail(502, `log-list failed: ${(r.stderr || r.stdout).trim()}`);
        // dayz-ctl emits "type<TAB>name<TAB>bytes<TAB>mtime-iso", newest first.
        const files = r.stdout
          .split('\n')
          .map((l) => l.replace(/\r$/, ''))
          .filter(Boolean)
          .map((line) => {
            const [type, name, bytes, modified] = line.split('\t');
            return { name, type, sizeBytes: parseInt(bytes, 10) || 0, modified };
          })
          .filter((f) => f.name && (f.type === 'rpt' || f.type === 'adm'));
        return { files };
      },
    },

    'logs/read': {
      destructive: false,
      readOnly: true,
      describe: 'read a slice of one server log: range, filter, scroll. Params: file (a name from "logs/files") or type rpt|adm (newest, default rpt); offset = 1-based line to start at (omit for the tail); limit 1-500 (default 100); filter = grep -E regex matched per line; ignoreCase; raw = include the known-noise lines the box-side pre-filter hides by default (engine spam like Sakhal\'s "Unknown object class" — pattern set in deploy.config.json Dayz.LogNoiseFilter; noiseHidden reports how many were dropped). With a filter, offset/limit page through the MATCHED lines; every returned line keeps its original line number (n), and nextOffset/prevOffset are ready-made cursors for scrolling.',
      schema: {
        query: { type: 'object', properties: {
          file: { type: 'string', description: 'exact log filename from the "logs/files" action (e.g. DayZServer_x64_2026_07_14.RPT)' },
          type: { type: 'string', enum: ['rpt', 'adm'], description: 'used when "file" is omitted: read the newest log of this type (default rpt)' },
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
        // Target: an exact filename from logs/files, or rpt/adm = newest of that type.
        // Shape check here; dayz-ctl re-validates and never forms a path from anything
        // that isn't a bare existing *.RPT/*.ADM name in its fixed profiles dir.
        let target: string;
        if (params.file !== undefined && String(params.file) !== '') {
          target = String(params.file);
          if (!/^[A-Za-z0-9._-]+\.(RPT|ADM)$/.test(target)) throw fail(400, 'invalid "file" (use a name from the "logs/files" action)');
        } else {
          target = String(params.type ?? 'rpt') === 'adm' ? 'adm' : 'rpt';
        }
        // Positional verb args — empty placeholders keep 'raw' in slot 7.
        const args = [target, String(offset), String(limit), filter, ci ? 'ci' : '', raw ? 'raw' : ''];
        const r = await dayz.ctl('log-read', ...args);
        if (r.code === 2) throw fail(404, `log not found: ${target}`);
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
