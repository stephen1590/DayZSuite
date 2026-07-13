---
title: API
weight: 40
---

## API

A signed HTTP API that controls the DayZ server - restart it, switch the map,
broadcast a message, pull logs. Every call must be signed. Every action comes
from a fixed allowlist - there is no arbitrary-command path.

### Connect

|             |                                          |
| ----------- | ---------------------------------------- |
| **Address** | `https://api.cytonicmushroom.ddns.net`   |
| **Auth**    | HMAC-SHA256 signature on every request   |
| **Access**  | By shared secret - ask the host          |

### Actions

Trigger one with `POST /dayz/<action>`. `GET /dayz/actions` lists them live, no auth.

| Action               | What it does                                           | Destructive? |
| -------------------- | ------------------------------------------------------ | ------------ |
| `status`             | server info: uptime, players, map, mods, next restart  | no           |
| `players`            | current online player count                            | no           |
| `log`                | tail the newest server log                             | no           |
| `configs` / `config` | list / fetch allowlisted config files                  | no           |
| `broadcast`          | in-game message to all players                         | no           |
| `start`              | start the server                                       | no           |
| `restart` / `stop`   | restart or stop the server                             | yes          |
| `map`                | switch mission and restart                             | yes          |

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

- Read actions also take query params: `POST /dayz/log?lines=200&type=adm`
  (body wins on a clash). Destructive actions read the signed body only.
- `GET /healthz` is a liveness probe - no auth.
- `GET /dayz/server-info` is the public current-server-info snapshot - no auth, no
  signing. Same payload as `status`: state, uptime, players, map, mod list, next
  scheduled restart. It only exposes what the Steam server browser already
  publishes. This is what powers the server-info panel on this site.

### Guardrails

Hard to misuse by design:

- **Player guard** - destructive actions refuse while anyone is online, or when
  the player count can't be verified. Override with `{"force": true}` in the body.
- **Warning first** - if anyone is connected, `restart` / `stop` / `map`
  broadcast an in-game warning and wait 15 seconds before running.
- **Cooldowns** - repeat an action too fast and you get a `409` with the seconds
  left to wait.
- **Rate limit** - 30 requests per minute per IP, across everything.
- **Audited** - every call is logged, accepted or rejected.
