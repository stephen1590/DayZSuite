// Prometheus exposition for the DayZ-specific series (GET /metrics — routes/host.ts).
// Host-level metrics are deliberately NOT here: node_exporter owns the box (cpu,
// memory, disk, network) and does it better than /sysload's hand-rolled /proc reads.
// This module exports only what no off-the-shelf exporter knows — the dayz unit's
// footprint (via the sudo bridge) and the RCon player picture.
//
// Every scrape crosses the sudo bridge (dayz-ctl info: systemctl show + du) and RCon
// (players), so collection is cached briefly: concurrent scrapers share one in-flight
// collection, and Prometheus can shorten its interval without multiplying bridge calls.
import type { DayzBridge } from './dayz.js';
import type { PlayerLedger } from './player-ledger.js';
import { getServerStatus } from './vpp-stats.js';

const CACHE_TTL_MS = 10_000;
// Server FPS is PUSHED by VPP on a timer (default 60s); drop it from /metrics once the
// feed goes quiet so a stale value can't masquerade as live. 3x the default interval.
const FPS_STALE_MS = 180_000;

interface Sample {
  labels?: Record<string, string>;
  value: number;
}
interface Metric {
  name: string;
  help: string;
  type: 'gauge' | 'counter';
  samples: Sample[];
}

// Exposition-format label-value escaping: backslash, double quote, newline.
const esc = (v: string): string => v.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');

function render(metrics: Metric[]): string {
  const lines: string[] = [];
  for (const m of metrics) {
    if (!m.samples.length) continue;
    lines.push(`# HELP ${m.name} ${m.help}`, `# TYPE ${m.name} ${m.type}`);
    for (const s of m.samples) {
      const labels = s.labels && Object.keys(s.labels).length
        ? '{' + Object.entries(s.labels).map(([k, v]) => `${k}="${esc(v)}"`).join(',') + '}'
        : '';
      lines.push(`${m.name}${labels} ${s.value}`);
    }
  }
  return lines.join('\n') + '\n';
}

async function collect(dayz: DayzBridge, ledger: PlayerLedger): Promise<string> {
  // The two sources fail independently (unit down ≠ RCon down); each half degrades to
  // its own *_ok 0 rather than failing the scrape, so Prometheus can alert on the
  // collectors themselves.
  const [info, players] = await Promise.allSettled([dayz.info(), dayz.players()]);
  const metrics: Metric[] = [];
  const one = (name: string, help: string, type: 'gauge' | 'counter', value: number, labels?: Record<string, string>): void => {
    metrics.push({ name, help, type, samples: [{ value, ...(labels ? { labels } : {}) }] });
  };

  one('dayz_info_ok', 'dayz-ctl info succeeded this scrape (0 = the dayz unit series are absent).', 'gauge', info.status === 'fulfilled' ? 1 : 0);
  if (info.status === 'fulfilled') {
    const i = info.value;
    one('dayz_up', 'DayZ systemd unit is active.', 'gauge', i.state === 'active' ? 1 : 0);
    if (i.sinceEpoch > 0) one('dayz_unit_start_time_seconds', 'Unit ActiveEnterTimestamp as epoch seconds; uptime = time() - this.', 'gauge', i.sinceEpoch);
    one('dayz_unit_restarts_total', 'systemd NRestarts — unit restarts since boot.', 'counter', i.restarts);
    one('dayz_process_memory_bytes', 'Unit memory (systemd MemoryCurrent).', 'gauge', i.memBytes);
    one('dayz_process_tasks', 'Unit task (thread) count.', 'gauge', i.tasks);
    one('dayz_process_cpu_seconds_total', 'Unit CPU time (systemd CPUUsageNSec).', 'counter', Math.round(i.cpuNsec / 1e6) / 1e3);
    one('dayz_log_dir_bytes', 'Server log directory size.', 'gauge', i.logDirBytes);
    one('dayz_persistence_bytes', 'Persistence (storage) directory size.', 'gauge', i.storageBytes);
    if (i.deadlineMin > 0) one('dayz_restart_deadline_minutes', 'messages.xml shutdown deadline.', 'gauge', i.deadlineMin);
    one('dayz_mods', 'Mods in the -mod chain.', 'gauge', i.mods.length);
    if (i.mission) one('dayz_mission_info', 'Current mission as a label; value is always 1.', 'gauge', 1, { mission: i.mission });
  }

  // count === null means RCon answered nothing usable (server down or unparseable) —
  // same "unavailable" the Maintenance tab shows, expressed as dayz_players_ok 0.
  const ok = players.status === 'fulfilled' && players.value.count != null;
  one('dayz_players_ok', 'RCon player query succeeded this scrape (0 = player series are absent).', 'gauge', ok ? 1 : 0);
  if (players.status === 'fulfilled' && players.value.count != null) {
    one('dayz_players_online', "Players connected (BattlEye's authoritative total).", 'gauge', players.value.count);
    const pinged = players.value.players.filter((p) => p.ping != null);
    if (pinged.length) {
      metrics.push({
        name: 'dayz_player_ping_milliseconds',
        help: 'Per-player RCon round-trip ping. Slot label keeps series unique if two players share a name.',
        type: 'gauge',
        samples: pinged.map((p) => ({ labels: { slot: String(p.num), player: p.name }, value: p.ping as number })),
      });
    }
  }

  // Durable GUID tally → unique/new player gauges. Fold in only a roster we actually
  // parsed (real GUIDs; a blank guid is a still-connecting player). Emit the counts even
  // on a scrape where RCon didn't answer — they come from the persistent ledger, so the
  // panels shouldn't blink to "No data" on a transient RCon blip.
  const now = Date.now();
  if (players.status === 'fulfilled' && players.value.count != null) {
    const guids = players.value.players.map((p) => p.guid).filter((g) => g);
    ledger.record(guids, now);
  }
  const tally = ledger.counts(now);
  one('dayz_players_unique_24h', 'Distinct BattlEye GUIDs seen in the trailing 24h.', 'gauge', tally.unique24h);
  one('dayz_players_new_24h', 'Distinct BattlEye GUIDs whose first-ever sighting is within the trailing 24h.', 'gauge', tally.new24h);

  // Server FPS — pushed by VPP's server-status webhook, not collected here. Always
  // report its age (so a dead feed is visible), but only report the FPS value while the
  // feed is fresh — a frozen number would otherwise read as live long after VPP stopped.
  const status = getServerStatus();
  if (status) {
    const ageMs = Date.now() - status.receivedAtMs;
    one('dayz_server_status_age_seconds', 'Seconds since the last VPP server-status webhook (freshness of dayz_server_fps).', 'gauge', Math.max(0, Math.round(ageMs / 1000)));
    if (ageMs < FPS_STALE_MS) {
      one('dayz_server_fps', 'DayZ server FPS (g_Game.GetServerFPS()), pushed by VPPAdminTools WebHooks.', 'gauge', status.fps);
    }
  }

  return render(metrics);
}

/** Cached collector: at most one bridge+RCon round per TTL, shared by concurrent scrapes. */
export function makeMetrics(dayz: DayzBridge, ledger: PlayerLedger): () => Promise<string> {
  let cached: { at: number; body: Promise<string> } | null = null;
  return () => {
    if (cached && Date.now() - cached.at < CACHE_TTL_MS) return cached.body;
    const entry = { at: Date.now(), body: collect(dayz, ledger) };
    // A failed collection must not be served for a whole TTL — drop it so the next
    // scrape retries (collect itself degrades per-source, so this is belt-and-braces).
    entry.body.catch(() => { if (cached === entry) cached = null; });
    cached = entry;
    return entry.body;
  };
}
