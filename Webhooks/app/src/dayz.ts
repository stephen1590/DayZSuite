// The bridge to the DayZ server. The service itself holds NO privilege and knows
// NO server internals — it can only run `sudo dayz-ctl <verb> [arg]`, a script with
// a closed verb set (see deploy/templates/dayz-ctl.template). Arguments are passed
// as argv (execFile, no shell), so payload text can never be interpreted as a command.
import { execFile } from 'node:child_process';
import type { AppConfig } from './config.js';

export interface CtlResult {
  code: number;
  stdout: string;
  stderr: string;
}

export interface PlayerCount {
  /** null = the count could not be read (server down, or RCon unparseable). */
  count: number | null;
  raw: string;
}

export interface DayzBridge {
  ctl(verb: string, arg?: string): Promise<CtlResult>;
  players(): Promise<PlayerCount>;
}

export function makeDayz(cfg: AppConfig): DayzBridge {
  function ctl(verb: string, arg?: string): Promise<CtlResult> {
    const args = ['-n', cfg.dayzCtl, verb];
    if (arg != null) args.push(arg);
    return new Promise((resolve, reject) => {
      execFile('sudo', args, { timeout: 20_000, maxBuffer: 1 << 20 }, (err, stdout, stderr) => {
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

  async function players(): Promise<PlayerCount> {
    const r = await ctl('players');
    // dayz-rcon.ps1 "players" prints BattlEye's reply, e.g. "(3 players in total)".
    const m = /\((\d+)\s+players?\s+in\s+total\)/i.exec(r.stdout);
    return { count: m ? parseInt(m[1], 10) : null, raw: r.stdout.trim() };
  }

  return { ctl, players };
}

/** Strip RCon broadcast text to printable ASCII and cap its length. */
export function sanitizeText(input: string): string {
  return input
    .replace(/[^\x20-\x7E]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 200);
}
