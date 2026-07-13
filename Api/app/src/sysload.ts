// Host load overview — the host stats are gathered UNPRIVILEGED, straight from
// /proc, statfs, and the os module (never the sudo bridge; least privilege cuts
// both ways). This is a ROOT-level endpoint (POST /sysload), not a dayz action:
// it is about the whole box, not the game server. It does carry an optional `dayz`
// block — the one part that crosses the bridge for the unit's own footprint — which
// degrades to null rather than failing the host overview.
import { readFile, statfs } from 'node:fs/promises';
import { loadavg, cpus, uptime } from 'node:os';
import type { DayzBridge } from './dayz.js';

interface CpuTimes {
  busy: number;
  total: number;
}

async function readCpuTimes(): Promise<CpuTimes> {
  const stat = await readFile('/proc/stat', 'utf8');
  // First line: "cpu  user nice system idle iowait irq softirq steal ..."
  const fields = stat.slice(0, stat.indexOf('\n')).trim().split(/\s+/).slice(1).map(Number);
  const total = fields.reduce((a, b) => a + b, 0);
  const idle = fields[3] + (fields[4] ?? 0); // idle + iowait
  return { busy: total - idle, total };
}

const pct = (used: number, total: number): number | null =>
  total > 0 ? Math.round((used / total) * 1000) / 10 : null;

export async function collectSysload(): Promise<Record<string, unknown>> {
  // CPU utilisation is a rate, not a state — sample /proc/stat twice, 250ms apart.
  const a = await readCpuTimes();
  await new Promise((r) => setTimeout(r, 250));
  const b = await readCpuTimes();
  const busyPct = pct(b.busy - a.busy, b.total - a.total);

  // MemAvailable (not MemFree) is the kernel's own "how much can apps still use"
  // estimate — free counts neither reclaimable cache nor buffers.
  const meminfo = await readFile('/proc/meminfo', 'utf8');
  const kb = (key: string): number => {
    const m = new RegExp(`^${key}:\\s+(\\d+) kB`, 'm').exec(meminfo);
    return m ? parseInt(m[1], 10) : 0;
  };
  const memTotal = kb('MemTotal');
  const memAvail = kb('MemAvailable');
  const swapTotal = kb('SwapTotal');
  const swapFree = kb('SwapFree');

  const fs = await statfs('/');
  const diskTotal = fs.blocks * fs.bsize;
  const diskFree = fs.bavail * fs.bsize;

  const [load1, load5, load15] = loadavg().map((n) => Math.round(n * 100) / 100);
  const mb = (kbVal: number): number => Math.round(kbVal / 1024);
  const gb = (bytes: number): number => Math.round((bytes / 2 ** 30) * 10) / 10;

  return {
    uptimeSec: Math.round(uptime()),
    cpu: { cores: cpus().length, load1, load5, load15, busyPct },
    memoryMb: { total: mb(memTotal), available: mb(memAvail), usedPct: pct(memTotal - memAvail, memTotal) },
    swapMb: { total: mb(swapTotal), used: mb(swapTotal - swapFree) },
    diskRootGb: { total: gb(diskTotal), free: gb(diskFree), usedPct: pct(diskTotal - diskFree, diskTotal) },
  };
}

/**
 * Host overview PLUS the dayz-server unit's own footprint. The dayz block is the one
 * part that crosses the sudo bridge (unit memory/cpu via dayz-ctl info; profiles/ +
 * persistence sizes are unreadable to the service user — game home is 0750). It
 * degrades to `dayz: null` (with `dayzError`) rather than failing the host overview.
 */
export async function collectSystemLoad(dayz: DayzBridge): Promise<Record<string, unknown>> {
  const host = await collectSysload();
  try {
    const i = await dayz.info();
    const mb = (bytes: number): number => Math.round((bytes / 2 ** 20) * 10) / 10;
    return {
      ...host,
      dayz: {
        state: i.state,
        mainPid: i.pid || null,
        memoryMb: mb(i.memBytes),
        tasks: i.tasks,
        cpuTimeSec: Math.round(i.cpuNsec / 1e9),
        unitRestarts: i.restarts,
        logDirMb: mb(i.logDirBytes),
        persistenceMb: mb(i.storageBytes),
      },
    };
  } catch (e) {
    return { ...host, dayz: null, dayzError: e instanceof Error ? e.message : String(e) };
  }
}
