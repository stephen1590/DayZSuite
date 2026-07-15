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
| `logs/files` / `logs/read` | list every log file / read any slice - engine noise pre-filtered            | no           |
| `configs/*`                | read allowlisted config files - replace the editable ones (with rollback)   | no           |
| `terrain/*`                | baked heightmap lookup - terrain height at world X/Z                        | no           |
| `broadcast`                | in-game message to all players                                              | no           |
| `start`                    | start the server                                                            | no           |
| `restart` / `stop`         | restart or stop the server                                                  | yes          |
| `mapchange`                | switch mission and restart                                                  | yes          |

Host load is a **root** endpoint, not a `/dayz` action (it's about the whole box):
`POST /sysload` - CPU, memory, disk, plus the game server's own footprint. Signed
like the actions above.

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
