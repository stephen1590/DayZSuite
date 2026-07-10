// In-memory per-action cooldown. Single-threaded Node makes check+mark effectively
// atomic within a request. This is what stops a caller from spamming `restart`.
export interface CooldownOk {
  ok: true;
}
export interface CooldownBlocked {
  ok: false;
  retryAfter: number; // seconds until the action is allowed again
  agoSec: number; // seconds since the last successful trigger
}
export type CooldownResult = CooldownOk | CooldownBlocked;

export class Cooldowns {
  private last = new Map<string, number>();

  /** Non-mutating: is `action` allowed right now? */
  check(action: string, cooldownSec: number): CooldownResult {
    const prev = this.last.get(action) ?? 0;
    const elapsed = (Date.now() - prev) / 1000;
    if (elapsed < cooldownSec) {
      return { ok: false, retryAfter: Math.ceil(cooldownSec - elapsed), agoSec: Math.floor(elapsed) };
    }
    return { ok: true };
  }

  /** Record that `action` just fired; starts its cooldown window. */
  mark(action: string): void {
    this.last.set(action, Date.now());
  }
}
