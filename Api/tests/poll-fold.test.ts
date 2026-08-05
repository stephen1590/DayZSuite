// Regression guard for the poll fold: `status` carries the roster and the unit footprint in
// one call, so the Maintenance tab needs neither a second RCon query nor a second unit snapshot.
//
// WHY THIS IS A GATE AND NOT A SENTENCE IN A CHANGE NOTICE: every dayz-ctl round trip crosses
// `sudo` and spawns a pwsh AS ROOT — a process that can die and take every bridge verb and the
// Players panel down with it. Poll count is not a tidiness metric here — it is how hard we lean
// on the thing that breaks. A claim that it went down has to be checkable by the runner, or it rots.
//
// NOTE ON REACH: actions.ts imports its siblings with `.js` specifiers (right for the tsc
// NodeNext build, unresolvable under Node's type stripping), so no test can import the action
// registry. The response shape is therefore proven by EXECUTING status-view.ts, and the
// per-cycle call counts by reading the action bodies. Both halves are named below so nobody
// mistakes the structural half for an execution one.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { statusView } from '../app/src/status-view.ts';
import { collectSysload } from '../app/src/sysload.ts';
import { FAST_POLLS, SLOW_POLLS, SLOW_EVERY, pollsForTick } from '../../ConfigViewer/web/js/poll-plan.js';

// The four endpoints the fast+slow tick replaced (maintenance.js's old loadMaint):
// /dayz/status, /sysload, /dayz/players, /dayz/update/status.
const POLLS_BEFORE = 4;
// dayz.players() ran twice per cycle: once inside `status`, once for the roster.
const PLAYERS_CALLS_BEFORE = 2;

const actionsSrc = readFileSync(new URL('../app/src/actions.ts', import.meta.url), 'utf8');
const block = (from: string, to: string): string => {
  const a = actionsSrc.indexOf(from);
  const b = actionsSrc.indexOf(to, a);
  assert.ok(a >= 0 && b > a, `could not slice ${from} .. ${to} out of actions.ts`);
  return actionsSrc.slice(a, b);
};
const countOf = (hay: string, needle: RegExp): number => (hay.match(needle) || []).length;

const INFO = {
  state: 'active', sinceEpoch: 1785600000, pid: 123,
  memBytes: 4_000_000_000, tasks: 77, cpuNsec: 1e12, restarts: 4,
  mission: 'dayzOffline.sakhal', deadlineMin: 240,
  logDirBytes: 50_000_000, storageBytes: 200_000_000,
  mods: [{ folder: '@cf', name: 'CF' }],
};
const ROSTER = {
  count: 2,
  players: [
    { num: 1, name: 'Ana', guid: 'a'.repeat(32), verified: true, ip: '10.0.0.1', port: 2304, ping: 42, inLobby: false },
    { num: 2, name: 'Bo', guid: 'b'.repeat(32), verified: true, ip: '10.0.0.2', port: 2304, ping: 51, inLobby: false },
  ],
};

// --- 1. the fold, EXECUTED: status carries what the deleted /dayz/players poll fetched ------
test('status returns the ROSTER, not just the count', () => {
  // Dropping the roster here is what forces a second RCon round trip elsewhere; carrying it
  // is the whole fold.
  const r = statusView(INFO as never, ROSTER as never, INFO.sinceEpoch + 3600);
  assert.equal(r.players, 2, 'the count stays where every existing caller expects it');
  assert.ok(Array.isArray(r.roster), 'the roster rides on the call that already paid for it');
  assert.equal((r.roster as unknown[]).length, 2);
  assert.equal((r.roster as Array<{ name: string }>)[0].name, 'Ana');
});

test('status returns the unit footprint from the snapshot it already takes', () => {
  const r = statusView(INFO as never, ROSTER as never, INFO.sinceEpoch + 3600);
  const unit = r.unit as Record<string, number>;
  assert.equal(unit.memoryMb, 3814.7, 'the memory figure the Host load card used to get from /sysload');
  assert.equal(unit.tasks, 77);
  assert.equal(unit.unitRestarts, 4);
  assert.ok(unit.logDirMb > 0 && unit.persistenceMb > 0);
});

test('the rest of the status contract is unchanged - nothing was traded away for the fold', () => {
  const r = statusView(INFO as never, ROSTER as never, INFO.sinceEpoch + 3600);
  assert.equal(r.status, 'active');
  assert.equal(r.map, 'dayzOffline.sakhal');
  assert.equal(r.modCount, 1);
  assert.equal(r.uptimeSeconds, 3600);
  assert.equal(r.uptimeHuman, '1h 0m');
  assert.equal((r.restart as { inHuman: string }).inHuman, '3h 0m', 'next restart still computed');
});

test('an RCon that did not answer degrades to a null count and an empty roster', () => {
  const r = statusView(INFO as never, { count: null, players: [] } as never, INFO.sinceEpoch);
  assert.equal(r.players, null, 'null means "could not verify", never 0');
  assert.deepEqual(r.roster, [], 'and the panel shows no players rather than a stale list');
});

// --- 2. /sysload stops duplicating the unit snapshot, EXECUTED -------------------------------
test('the /sysload collector needs no bridge at all - it is host-only now', async () => {
  // A dayz.info() call here would duplicate the unit snapshot `status` already takes. Host
  // stats come from /proc unprivileged; nothing here may cross sudo.
  const load = await collectSysload();
  assert.ok(load.cpu && load.memoryMb && load.diskRootGb, 'the host half is intact');
  assert.equal('dayz' in load, false, 'the unit block moved to status - one owner, not two');
  const src = readFileSync(new URL('../app/src/sysload.ts', import.meta.url), 'utf8');
  assert.doesNotMatch(src, /DayzBridge/, 'the host collector must not import the privileged bridge');
  assert.doesNotMatch(src, /collectSystemLoad/, 'the duplicate collector is deleted, not left orphaned');
});

test('nothing still calls the deleted collector', () => {
  const host = readFileSync(new URL('../app/src/routes/host.ts', import.meta.url), 'utf8');
  assert.doesNotMatch(host, /collectSystemLoad/, 'an orphaned caller would not compile');
  assert.match(host, /collectSysload\(\)/, '/sysload now calls the host-only collector with no bridge');
});

// --- 3. per-cycle bridge calls, read from the action bodies ----------------------------------
const statusBody = block('    status: {', '    // Historical charts');
const timeseriesBody = block('    timeseries: {', '    players: {');

test('the status action crosses the bridge exactly twice - one info, one players', () => {
  assert.equal(countOf(statusBody, /dayz\.players\(\)/g), 1, 'one RCon query per status call');
  assert.equal(countOf(statusBody, /dayz\.info\(\)/g), 1, 'one unit snapshot per status call');
  assert.equal(countOf(statusBody, /dayz\.ctl\(/g), 0, 'and no extra verbs');
});

test('dayz.players() is invoked ONCE per cycle, not twice', () => {
  // The fast tick is status + timeseries. Sum their RCon calls: it was 2 (status + players).
  const perCycle = countOf(statusBody, /dayz\.players\(\)/g) + countOf(timeseriesBody, /dayz\.players\(\)/g);
  assert.equal(perCycle, 1,
    `RCon runs ${perCycle}x per cycle; it ran ${PLAYERS_CALLS_BEFORE}x before and must now run once`);
  assert.ok(perCycle < PLAYERS_CALLS_BEFORE, 'the duplicate is gone, not merely renamed');
});

test('the charts action crosses the sudo bridge ZERO times', () => {
  // It reads Prometheus over loopback. A dayz-ctl call here would undo the whole fold.
  assert.equal(countOf(timeseriesBody, /dayz\.(players|info|ctl|ctlStdin)\(/g), 0);
  assert.match(timeseriesBody, /timeseries\(/, 'it goes to the Prometheus query, nothing else');
});

// --- 4. the tab's cycle ------------------------------------------------------------------------
test('the fast tick issues FEWER requests per cycle than before', () => {
  assert.ok(FAST_POLLS.length < POLLS_BEFORE,
    `the fast cycle is ${FAST_POLLS.length} requests; it must be fewer than the ${POLLS_BEFORE} it replaced`);
  assert.deepEqual(FAST_POLLS, ['/dayz/status', '/dayz/timeseries']);
});

test('/dayz/players is polled by NOTHING - the migration ended at deletion', () => {
  assert.equal(FAST_POLLS.includes('/dayz/players'), false);
  assert.equal(SLOW_POLLS.includes('/dayz/players'), false);
  const src = readFileSync(new URL('../../ConfigViewer/web/js/maintenance.js', import.meta.url), 'utf8');
  assert.doesNotMatch(src, /apiPost\(\s*'\/dayz\/players'/,
    'the roster now rides on /dayz/status; a leftover poll would restore the duplicate RCon');
});

test('the slow tick carries what only it can answer, at a third of the rate', () => {
  assert.deepEqual(SLOW_POLLS, ['/sysload', '/dayz/update/status']);
  assert.equal(SLOW_EVERY, 3, '20s fast tick -> the slow reads land every 60s');
});

test('pollsForTick folds the slow reads into every third tick and no other', () => {
  assert.deepEqual(pollsForTick(0), [...FAST_POLLS, ...SLOW_POLLS], 'the first tick loads everything');
  assert.deepEqual(pollsForTick(1), FAST_POLLS);
  assert.deepEqual(pollsForTick(2), FAST_POLLS);
  assert.deepEqual(pollsForTick(3), [...FAST_POLLS, ...SLOW_POLLS]);
});

test('requests per minute go DOWN, and the count is checked rather than asserted in prose', () => {
  // 3 fast ticks a minute at 20s, plus one slow round.
  const perMinuteAfter = FAST_POLLS.length * 3 + SLOW_POLLS.length;
  const perMinuteBefore = POLLS_BEFORE * 3;
  assert.ok(perMinuteAfter < perMinuteBefore,
    `${perMinuteAfter} requests/min must be fewer than the ${perMinuteBefore} before`);
  assert.equal(perMinuteBefore, 12);
  assert.equal(perMinuteAfter, 8);
});

test('root pwsh spawns per minute go DOWN too - the reason any of this matters', () => {
  // status: info + players. update/status: one ctl. timeseries + sysload: none.
  const spawnsAfter = 2 * 3 + 1;
  // Before: status(2) + sysload(1) + players(1) + update(1) = 5, three times a minute.
  const spawnsBefore = 5 * 3;
  assert.equal(spawnsBefore, 15);
  assert.equal(spawnsAfter, 7);
  assert.ok(spawnsAfter < spawnsBefore);
});
