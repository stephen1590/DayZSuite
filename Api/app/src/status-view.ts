// The `status` response, projected from ONE unit snapshot and ONE RCon roster.
//
// Split out of actions.ts so it can be executed by a test: the action registry imports its
// siblings with `.js` specifiers (correct for the tsc NodeNext build), which Node's type
// stripping cannot resolve, so nothing under `node --test` can import actions.ts. This module
// has no relative value imports, so it can.
//
// It is also where the poll fold lives. `status` makes both privileged calls (one unit
// snapshot, one RCon roster), so a dashboard never needs a second RCon query (`players`) or a
// second unit snapshot (/sysload) to draw one screen. Each of those crosses sudo and spawns a
// pwsh as root — a costly, fragile path not worth doubling up on.
import type { DayzInfo, Player } from './dayz.js';

export function humanDuration(sec: number): string {
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

const mb = (bytes: number): number => Math.round((bytes / 2 ** 20) * 10) / 10;

export interface RosterSnapshot {
  count: number | null;
  players: Player[];
}

export function statusView(i: DayzInfo, p: RosterSnapshot, nowSec: number): Record<string, unknown> {
  const running = i.state === 'active' && i.sinceEpoch > 0;
  const up = running ? Math.max(0, nowSec - i.sinceEpoch) : null;

  // The native messages.xml scheduler stops the server <deadline> minutes after start
  // (Restart=always brings it back), so next restart = unit start + deadline. Estimated:
  // mission load shifts it by a minute or two.
  let restart: Record<string, unknown> | null = null;
  if (running && i.deadlineMin > 0) {
    const at = i.sinceEpoch + i.deadlineMin * 60;
    restart = {
      everyMinutes: i.deadlineMin,
      nextAt: new Date(at * 1000).toISOString(),
      inSeconds: Math.max(0, at - nowSec),
      inHuman: humanDuration(Math.max(0, at - nowSec)),
      estimated: true,
    };
  }

  return {
    status: i.state,
    since: i.sinceEpoch > 0 ? new Date(i.sinceEpoch * 1000).toISOString() : null,
    uptimeSeconds: up,
    uptimeHuman: up === null ? null : humanDuration(up),
    players: p.count,
    roster: p.players,
    map: i.mission,
    modCount: i.mods.length,
    mods: i.mods,
    restart,
    unit: {
      mainPid: i.pid || null,
      memoryMb: mb(i.memBytes),
      tasks: i.tasks,
      cpuTimeSec: Math.round(i.cpuNsec / 1e9),
      unitRestarts: i.restarts,
      logDirMb: mb(i.logDirBytes),
      persistenceMb: mb(i.storageBytes),
    },
  };
}
