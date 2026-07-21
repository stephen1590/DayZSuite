// Last server-status snapshot pushed by VPPAdminTools' WebHooks (its ServerStatusMessage
// carries "Server FPS: N" on a timer). VPP POSTs it to /dayz/sources/vpp/<token>
// (routes/sources.ts), which parses the FPS and stores it here; the /metrics collector
// (metrics.ts) reads it. Push-in, pull-out: Prometheus scrapes whenever it likes and we
// serve the last received sample plus its age, so a stopped feed reads as STALE rather
// than a frozen number. In-process singleton — one value for the one game server.

interface ServerStatus {
  fps: number;
  receivedAtMs: number;
}

let last: ServerStatus | null = null;

export function setServerFps(fps: number): void {
  last = { fps, receivedAtMs: Date.now() };
}

export function getServerStatus(): ServerStatus | null {
  return last;
}
