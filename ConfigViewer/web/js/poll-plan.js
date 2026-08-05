// poll-plan.js — WHAT the Maintenance tab fetches, and HOW OFTEN. One place, so the cost of
// the tab is a number you can read rather than four setInterval calls to add up.
//
// Every dayz-ctl round trip crosses `sudo` and spawns a pwsh AS ROOT - a crash there takes every
// bridge verb and the Players panel down with it. So the cadence is a real cost, not housekeeping.
//
// FAST carries everything that changes minute to minute. /dayz/status brings the unit
// snapshot, the player count AND the roster in one bridge pair; /dayz/timeseries brings the
// history plus the current value of each charted metric and never touches the bridge at all.
//
// SLOW carries what does not move fast enough to be worth a root process every 20 seconds:
// disk, swap, host uptime and the build-update check.
export const FAST_MS = 20000;

/** Slow reads land every Nth fast tick — 3 x 20s = once a minute. */
export const SLOW_EVERY = 3;

export const FAST_POLLS = ['/dayz/status', '/dayz/timeseries'];
export const SLOW_POLLS = ['/sysload', '/dayz/update/status'];

/** Tick 0 loads everything so the tab is never blank; after that the slow set rejoins every
 *  SLOW_EVERY ticks. Per minute: 2x3 + 2 = 8 requests. */
export function pollsForTick(n) {
  return n % SLOW_EVERY === 0 ? [...FAST_POLLS, ...SLOW_POLLS] : [...FAST_POLLS];
}
