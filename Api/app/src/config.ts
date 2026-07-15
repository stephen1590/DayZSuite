// Runtime configuration for the API service.
//
// Two sources, deliberately split:
//   * config.json  — non-secret settings (port, cooldowns, VPP rules). Rendered
//                    from deploy.config.json by Deploy-Api.ps1; safe to read.
//   * environment  — the SECRETS (HMAC signing secret, VPP URL token). Generated
//                    ONCE on the box by deploy.sh into /etc/api/secrets.env
//                    and injected by systemd (EnvironmentFile). They never live in
//                    the PowerShell config or the repo.
import { readFileSync } from 'node:fs';

export interface VppRule {
  /** Trigger when this substring appears in the incoming VPP event text. */
  match: string;
  /** Name of the action to run (must exist in the action registry). */
  action: string;
  /** Parameters passed to the action (e.g. { mission: "dayzOffline.enoch" }). */
  params?: Record<string, unknown>;
}

export interface AppConfig {
  host: string;
  port: number;
  /** Path to the privileged control script invoked via `sudo`. */
  dayzCtl: string;
  /** Per-action cooldown in seconds; `default` applies to any unlisted action. */
  cooldownSeconds: Record<string, number>;
  /** Refuse destructive actions while players are online (unless {force:true}). */
  playerGuard: boolean;
  /** Seconds to broadcast-warn and wait before a restart/stop/mapchange action, if anyone's on. 0 = skip. */
  restartWarningSeconds: number;
  /** Directory for the CSV audit trail. */
  auditDir: string;
  /** Server-side store for derived API keys (minted via /keys/create). */
  keysFile: string;
  /** Per-map baked terrain grids for the surface-y action (see heightmap.ts). */
  heightmapsDir: string;
  rateLimit: { max: number; windowMs: number };
  /** HMAC-SHA256 shared secret for the /dayz command API (from env). */
  secret: string;
  vpp: {
    enabled: boolean;
    /** Secret path token VPP embeds in its webhook URL (from env). */
    token: string;
    rules: VppRule[];
  };
}

export function loadConfig(): AppConfig {
  const path = process.env.API_CONFIG ?? '/etc/api/config.json';
  const raw = JSON.parse(readFileSync(path, 'utf8')) as Record<string, any>;

  const secret = process.env.HMAC_SECRET ?? '';
  if (!secret) throw new Error('HMAC_SECRET is not set (expected via systemd EnvironmentFile).');

  const vppToken = process.env.VPP_TOKEN ?? '';

  return {
    host: raw.host ?? '127.0.0.1',
    port: Number(raw.port ?? 3100),
    dayzCtl: raw.dayz?.ctl ?? '/usr/local/bin/dayz-ctl',
    cooldownSeconds: { default: 3, ...(raw.cooldownSeconds ?? {}) },
    playerGuard: raw.playerGuard ?? true,
    restartWarningSeconds: Number(raw.dayz?.restartWarningSeconds ?? 15),
    auditDir: raw.auditDir ?? '/var/log/api',
    keysFile: raw.keysFile ?? '/var/lib/api/keys.json',
    heightmapsDir: raw.heightmapsDir ?? '/var/lib/api/heightmaps',
    rateLimit: {
      max: Number(raw.rateLimit?.max ?? 30),
      windowMs: Number(raw.rateLimit?.windowMs ?? 60_000),
    },
    secret,
    vpp: {
      enabled: raw.vpp?.enabled ?? false,
      token: vppToken,
      rules: Array.isArray(raw.vpp?.rules) ? (raw.vpp.rules as VppRule[]) : [],
    },
  };
}
