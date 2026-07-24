// A durable tally of which players have ever connected, keyed on the BattlEye GUID —
// the stable per-account id. NOT keyed on IP: IPs are dynamic, shared (CGNAT, one
// household), and VPN-maskable, so they answer "which address" not "which person".
//
// Feeds two Prometheus gauges: UNIQUE players (distinct GUIDs seen in the trailing
// window) and NEW players (distinct GUIDs whose first-ever sighting is in that window).
//
// Why the box computes the window instead of PromQL: the natural phrasing —
// count(distinct guid) over [24h] — needs one Prometheus series PER GUID, and GUIDs
// churn without bound. That is a cardinality blow-up. Holding first/last-seen per GUID
// here and emitting two plain gauges keeps Prometheus at two series total.
//
// Lives under systemd's StateDirectory (/var/lib/api), mode 0600, atomic tmp+rename —
// the same posture as keys.ts. Box-only state with no backup: nothing downstream breaks
// if it is lost, and it self-heals to a full picture within one window.
import { readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

/** Trailing window for both gauges. Hardcoded: the dashboard asks for 24h specifically. */
export const WINDOW_MS = 24 * 60 * 60 * 1000;

// An online roster is re-observed every scrape, so lastSeen alone would rewrite the file
// on nearly every scrape. Coalesce routine lastSeen updates to at most one write per
// this interval; a brand-new GUID still flushes immediately (below). The at-risk loss on
// a crash is one interval of lastSeen freshness — trivial against a 24h window.
const FLUSH_INTERVAL_MS = 60_000;

interface Seen {
  /** First-ever sighting, epoch seconds. Drives the NEW count. */
  first: number;
  /** Most recent sighting, epoch seconds. Drives the UNIQUE count. */
  last: number;
}

export class PlayerLedger {
  private seen = new Map<string, Seen>();
  private dirty = false;
  private lastFlush = 0;

  constructor(private path: string) {
    try {
      const obj = JSON.parse(readFileSync(path, 'utf8')) as Record<string, Partial<Seen>>;
      for (const [guid, s] of Object.entries(obj)) {
        if (guid && typeof s?.first === 'number' && typeof s?.last === 'number') {
          this.seen.set(guid, { first: s.first, last: s.last });
        }
      }
    } catch {
      // Missing or corrupt file = start empty. The tally rebuilds from live rosters; a
      // lost file only resets NEW/UNIQUE for the current window, nothing critical.
    }
  }

  /**
   * Fold a live roster into the tally. `guids` are the non-empty BattlEye GUIDs on the
   * server right now (a blank guid = a player BattlEye hasn't identified yet; the caller
   * drops those). `nowMs` is the observation time. Persists (debounced) on any change.
   */
  record(guids: string[], nowMs: number): void {
    const nowSec = Math.floor(nowMs / 1000);
    let novel = false; // a never-before-seen GUID — the "new player" event, worth persisting now
    for (const guid of guids) {
      const s = this.seen.get(guid);
      if (s) {
        s.last = nowSec;
      } else {
        this.seen.set(guid, { first: nowSec, last: nowSec });
        novel = true;
      }
      this.dirty = true;
    }
    // Flush a brand-new player immediately (never risk losing the NEW event); otherwise
    // coalesce lastSeen churn to one write per interval.
    if (this.dirty && (novel || nowMs - this.lastFlush >= FLUSH_INTERVAL_MS)) this.flush(nowMs);
  }

  /** Distinct-GUID counts over the trailing WINDOW_MS as of `nowMs`. */
  counts(nowMs: number): { unique24h: number; new24h: number } {
    const cutoffSec = Math.floor((nowMs - WINDOW_MS) / 1000);
    let unique24h = 0;
    let new24h = 0;
    for (const s of this.seen.values()) {
      if (s.last >= cutoffSec) unique24h++;
      if (s.first >= cutoffSec) new24h++;
    }
    return { unique24h, new24h };
  }

  private flush(nowMs: number): void {
    // tmp + rename: a crash mid-write can never truncate the live ledger.
    mkdirSync(dirname(this.path), { recursive: true });
    const obj: Record<string, Seen> = {};
    for (const [guid, s] of this.seen) obj[guid] = s;
    const tmp = `${this.path}.tmp`;
    writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n', { mode: 0o600 });
    renameSync(tmp, this.path);
    this.dirty = false;
    this.lastFlush = nowMs;
  }
}
