---
title: API
weight: 40
---

## API

A signed HTTP API that controls the box's services. Each service gets its own
path namespace - DayZ lives under `/dayz/*`. Every call must be signed. Every
action comes from a fixed allowlist - there is no arbitrary-command path. The
table below is the full set.

### Connect

|             |                                          |
| ----------- | ---------------------------------------- |
| **Address** | `https://api.cytonicmushroom.ddns.net`   |
| **Auth**    | HMAC-SHA256 signature on every request   |
| **Access**  | By shared secret - ask the host          |

### Actions

Trigger one with `POST /dayz/<action>` - grouped actions with
`POST /dayz/<group>/<action>`.

| Action                     | What it does                                                                | Destructive? |
| -------------------------- | --------------------------------------------------------------------------- | ------------ |
| `status`                   | server info: uptime, players, map, mods, next restart                       | no           |
| `players`                  | online player count + roster                                                | no           |
| `positions`                | live player map positions, anonymized to coordinates only                   | no           |
| `missions`                 | installed missions - the candidates a `mapchange` can switch to             | no           |
| `logs/files` / `logs/read` | list every log file / read any slice - engine noise pre-filtered            | no           |
| `configs/*`                | read allowlisted config files - replace the editable ones (with rollback)   | no           |
| `terrain/*`                | baked heightmap lookup - terrain height at world X/Z                        | no           |
| `broadcast`                | in-game message to all players                                              | no           |
| `start`                    | start the server                                                            | no           |
| `restart` / `stop`         | restart or stop the server                                                  | yes          |
| `mapchange`                | switch mission and restart                                                  | yes          |
| `update`                   | queue a game update for the next restart (arms it - does not restart now)   | no           |
| `update/status`            | installed vs latest build, whether one is queued, and the last update result| no           |
| `update/cancel`            | cancel a queued update                                                      | no           |

Host load is a **root** endpoint, not a `/dayz` action (it's about the whole box):
`POST /sysload` - CPU, memory, disk, plus the game server's own footprint. Signed
like the actions above.

`POST /whoami` is another root endpoint: it returns the calling key's own identity,
scope (`full` or `observe`), and namespaces. An access-aware UI reads it to show operator
vs read-only controls instead of probing with a write it may not be allowed to make.

### Calling it

Sign the exact request body with HMAC-SHA256. Send the signature in
`X-Signature-256`:

```bash
body='{"message":"Server restarting in 5 minutes"}'
sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.* //')
curl -sS https://api.cytonicmushroom.ddns.net/dayz/broadcast \
  -H "content-type: application/json" \
  -H "x-signature-256: sha256=$sig" \
  -d "$body"
```

- Read actions also take query params: `POST /dayz/logs/read?limit=200&type=adm`
  (body wins on a clash). Destructive actions read the signed body only.

Some reads need no auth at all:

- `GET /` - the whole-API index: every endpoint plus the action list.
- `GET /dayz/actions` - the DayZ action allowlist with descriptions.
- `GET /openapi.json` - the full OpenAPI spec.
- `GET /healthz` - liveness probe.
- `GET /dayz/server-info` - the current-server-info snapshot: state, uptime,
  players, map, mod list, next scheduled restart. Same payload as `status`, and
  only what the Steam server browser already publishes. This is what powers the
  server-info panel on this site.

### Guardrails

Hard to misuse by design:

- **Player guard** - destructive actions refuse while anyone is online, or when
  the player count can't be verified. Override with `{"force": true}` in the body.
- **Warning first** - if anyone is connected, `restart` / `stop` / `mapchange`
  broadcast an in-game warning and wait 15 seconds before running.
- **Cooldowns** - repeat an action too fast and you get a `409` with the seconds
  left to wait.
- **Rate limit** - 30 requests per minute per IP, across everything.
- **Audited** - every call is logged, accepted or rejected.

### Updates

Updates ride the reboot, they are not a separate disruptive event. `update` arms a flag; the
next server start pulls the latest server build and mods before the engine comes up, then
clears the flag. That next start can be the scheduled restart, a manual `restart`, or a forced
one - any of them applies a queued update.

- **Nothing is kicked by `update`.** Arming only sets the flag, so it is non-destructive. The
  disruption is the restart you choose to run, gated by the normal player guard.
- **Auto-check.** The box checks Steam on a timer (default every 4 hours). If the installed
  build is behind, it arms the flag automatically and broadcasts a heads-up. The update then
  applies on the next restart with no API call at all.
- **Read the result.** `update/status` reports the installed build, the latest known build,
  whether an update is queued, and the last applied update's outcome plus a log tail. On a
  failure the server boots on the old build and the next auto-check re-arms.
