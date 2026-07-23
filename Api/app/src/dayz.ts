// The bridge to the DayZ server. The service itself holds NO privilege and knows
// NO server internals — it can only run `sudo dayz-ctl <verb> [arg...]`, a script
// with a closed verb set (see deploy/templates/dayz-ctl.template). Arguments are passed
// as argv (execFile, no shell), so payload text can never be interpreted as a command.
import { execFile } from 'node:child_process';
import type { AppConfig } from './config.js';

export interface CtlResult {
  code: number;
  stdout: string;
  stderr: string;
}

export interface Player {
  /** BattlEye slot number (the leading column). */
  num: number;
  name: string;
  /** 32-char BattlEye GUID; '' if not computed yet ('-'). */
  guid: string;
  /** GUID verified against Steam ('(OK)'); false while pending ('(?)'). */
  verified: boolean;
  ip: string;
  port: number;
  /** Round-trip ping in ms; null while still connecting ('-'). */
  ping: number | null;
  /** Still in the connect/lobby phase (BattlEye suffixes the name ' (Lobby)'). */
  inLobby: boolean;
}

export interface PlayerCount {
  /** null = the count could not be read (server down, or RCon unparseable). */
  count: number | null;
  /** Parsed roster; empty when nobody's on or the reply was unparseable. */
  players: Player[];
  raw: string;
}

export interface DayzMod {
  /** The @folder name from the -mod chain (load order preserved). */
  folder: string;
  /** Display name from the mod's meta.cpp; falls back to the folder name. */
  name: string;
}

/** Parsed output of `dayz-ctl info` — one privileged snapshot of the unit. */
export interface DayzInfo {
  state: string;
  /** Unit ActiveEnterTimestamp as epoch seconds; 0 = not running / unknown. */
  sinceEpoch: number;
  pid: number;
  memBytes: number;
  tasks: number;
  cpuNsec: number;
  /** systemd NRestarts — how often the unit restarted since boot. */
  restarts: number;
  mission: string | null;
  /** messages.xml shutdown deadline in minutes; 0 = no scheduled restart found. */
  deadlineMin: number;
  logDirBytes: number;
  storageBytes: number;
  mods: DayzMod[];
}

export interface DayzBridge {
  ctl(verb: string, ...extra: string[]): Promise<CtlResult>;
  ctlStdin(verb: string, input: string, ...extra: string[]): Promise<CtlResult>;
  players(): Promise<PlayerCount>;
  info(): Promise<DayzInfo>;
}

export function makeDayz(cfg: AppConfig): DayzBridge {
  // Read buffer for dayz-ctl replies. MUST comfortably exceed every payload a verb can emit,
  // or a doc the box happily STORES becomes one the API can never read back: dayz-ctl's write
  // verbs accept up to 2MB (override-write/spawn-write/types-write) and override-read returns
  // the whole document — on 2026-07-23 prod's config-overrides.json grew past the old 1MB
  // buffer mid-editing-session and every editor load died with "stdout maxBuffer length
  // exceeded". 8MB = the 2MB write cap ×4 headroom; still a trivial allocation.
  const CTL_MAX_BUFFER = 8 << 20;
  function ctl(verb: string, ...extra: string[]): Promise<CtlResult> {
    const args = ['-n', cfg.dayzCtl, verb, ...extra];
    return new Promise((resolve, reject) => {
      execFile('sudo', args, { timeout: 20_000, maxBuffer: CTL_MAX_BUFFER }, (err, stdout, stderr) => {
        if (err && typeof (err as NodeJS.ErrnoException).code !== 'number') {
          // Spawn failure / timeout — no exit code. This is an infrastructure error.
          reject(err);
          return;
        }
        const code = typeof (err as { code?: number })?.code === 'number' ? (err as { code: number }).code : 0;
        resolve({ code, stdout: stdout.toString(), stderr: stderr.toString() });
      });
    });
  }

  // Large-payload variant: the document travels over STDIN ('-' placeholder in argv), not as
  // an argument. Linux caps a single argv string at ~128KB (MAX_ARG_STRLEN) — the full
  // override doc was 83KB by 2026-07-16 and spawn-points can pass 128KB outright, so argv
  // would hard-fail saves no matter what the HTTP body limits allow. dayz-ctl treats a
  // literal '-' document as "read stdin" for the write verbs.
  function ctlStdin(verb: string, input: string, ...extra: string[]): Promise<CtlResult> {
    const args = ['-n', cfg.dayzCtl, verb, '-', ...extra];
    return new Promise((resolve, reject) => {
      const child = execFile('sudo', args, { timeout: 20_000, maxBuffer: CTL_MAX_BUFFER }, (err, stdout, stderr) => {
        if (err && typeof (err as NodeJS.ErrnoException).code !== 'number') {
          reject(err);
          return;
        }
        const code = typeof (err as { code?: number })?.code === 'number' ? (err as { code: number }).code : 0;
        resolve({ code, stdout: stdout.toString(), stderr: stderr.toString() });
      });
      // EPIPE if the script dies before draining stdin — the exit code carries the story.
      child.stdin?.on('error', () => {});
      child.stdin?.end(input);
    });
  }

  async function players(): Promise<PlayerCount> {
    const r = await ctl('players');
    const raw = r.stdout.trim();
    // dayz-rcon.ps1 "players" prints BattlEye's reply verbatim: a header, one row per
    // player, then "(N players in total)". Roster comes from the rows; count from the
    // total line (authoritative), falling back to the parsed row count.
    const roster = parsePlayers(raw);
    const m = /\((\d+)\s+players?\s+in\s+total\)/i.exec(raw);
    const count = m ? parseInt(m[1], 10) : roster.length || null;
    return { count, players: roster, raw };
  }

  async function info(): Promise<DayzInfo> {
    const r = await ctl('info');
    if (r.code !== 0) throw new Error(`dayz-ctl info failed: ${(r.stderr || r.stdout).trim()}`);
    // Line protocol: KEY=VALUE, plus one 'MOD=<folder>\t<name>' line per mod.
    const kv = new Map<string, string>();
    const mods: DayzMod[] = [];
    for (const line of r.stdout.split('\n')) {
      if (line.startsWith('MOD=')) {
        const [folder, name] = line.slice(4).split('\t');
        if (folder) mods.push({ folder, name: name?.trim() || folder });
      } else {
        const eq = line.indexOf('=');
        if (eq > 0) kv.set(line.slice(0, eq), line.slice(eq + 1).trim());
      }
    }
    const num = (key: string): number => {
      const n = parseInt(kv.get(key) ?? '', 10);
      return Number.isFinite(n) && n >= 0 ? n : 0;
    };
    return {
      state: kv.get('STATE') || 'unknown',
      sinceEpoch: num('SINCE'),
      pid: num('PID'),
      memBytes: num('MEM_BYTES'),
      tasks: num('TASKS'),
      cpuNsec: num('CPU_NSEC'),
      restarts: num('NRESTARTS'),
      mission: kv.get('MISSION') || null,
      deadlineMin: num('DEADLINE_MIN'),
      logDirBytes: num('LOG_DIR_BYTES'),
      storageBytes: num('STORAGE_BYTES'),
      mods,
    };
  }

  return { ctl, ctlStdin, players, info };
}

/**
 * Parse a BattlEye `players` reply into a roster. Rows look like:
 *   <num>  <ip>:<port>  <ping>  <guid>(<status>)  <name>[ (Lobby)]
 * The header, the '---' separator and the '(N players in total)' line don't start with
 * a slot number, so they fall through. Tolerant of connecting players ('-' ping/guid,
 * '(?)' status). Names may contain spaces; a trailing ' (Lobby)' marks the lobby phase.
 */
export function parsePlayers(raw: string): Player[] {
  const ROW = /^\s*(\d+)\s+([\d.]+):(\d+)\s+(\S+)\s+([0-9a-fA-F-]+)\(([^)]*)\)\s+(.+)$/;
  const roster: Player[] = [];
  for (const line of raw.split(/\r?\n/)) {
    const m = ROW.exec(line);
    if (!m) continue;
    const [, num, ip, port, ping, guid, status, rest] = m;
    const inLobby = /\(Lobby\)\s*$/i.test(rest);
    const name = rest.replace(/\s*\(Lobby\)\s*$/i, '').trim();
    const pingN = parseInt(ping, 10);
    roster.push({
      num: parseInt(num, 10),
      name,
      guid: guid === '-' ? '' : guid,
      verified: status.toUpperCase() === 'OK',
      ip,
      port: parseInt(port, 10),
      ping: Number.isFinite(pingN) ? pingN : null,
      inLobby,
    });
  }
  return roster;
}

/** Strip RCon broadcast text to printable ASCII and cap its length. */
export function sanitizeText(input: string): string {
  return input
    .replace(/[^\x20-\x7E]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 200);
}
