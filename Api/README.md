# Api - authenticated control plane for the box

A small [Fastify](https://fastify.dev) (Node/TypeScript) service that turns **signed
HTTP calls** into a **fixed set of server actions**, served at `api.<domain>`. Each
SERVICE it fronts lives under its own path **namespace** - today that's DayZ
(`/dayz/*`: restart, map switch, broadcast, log tail, host stats, …), with more to
follow. Generic/host endpoints (`/healthz`, `/sysload`) and key management
(`/keys/*`) sit at the root, outside any namespace. Adding a service is a new route
module + a namespace entry, not a rewrite. (Formerly "Webhooks" on `hooks.<domain>` -
renamed 2026-07-13; the `hooks.` name and the DayZ-only framing are both retired.)

It is served *behind nginx*, so it lives **inside `NginxService/`** as a sibling of
CryptPad. Its *effects*, however, land on the **DayZ server, which lives outside**
`NginxService/` (DayZ is UDP, not proxied). That crossing is real and deliberate - it
is made explicit here, not hidden (see [The one deliberate coupling](#the-one-deliberate-coupling)).

```text
Api/
├── app/                     Fastify + TypeScript source (built on the box)
│   └── src/
│       ├── server.ts        bootstrap: raw-body parser, rate limit, routes
│       ├── config.ts        config.json (non-secret) + env (secrets)
│       ├── auth.ts          HMAC-SHA256 + URL-token verify (constant-time)
│       ├── guard.ts         per-action cooldowns
│       ├── dayz.ts          the `sudo dayz-ctl` bridge + player count
│       ├── sysload.ts       host stats (/proc, statfs) + the dayz unit footprint
│       ├── auth-request.ts  shared credential resolve + HMAC verify + attribution
│       ├── namespaces.ts    the service-namespace registry (dayz, …) + scope checks
│       ├── actions.ts       THE /dayz ALLOWLIST (restart/stop/start/status/players/map/broadcast/log/configs/config)
│       └── routes/
│           ├── commands.ts  POST /dayz/:action + GET /dayz/actions  (HMAC-signed trigger API)
│           ├── keys.ts      POST /keys/:op            (wizard-only derived-key management)
│           ├── host.ts      POST /sysload             (root, authed host load)
│           ├── public.ts    GET  /dayz/server-info    (PUBLIC, cached - the site's info panel)
│           └── sources.ts   POST /dayz/sources/vpp/:token (VPP event feed)
└── deploy/                  render → stage → ship → run (same shape as CryptPad)
    ├── Deploy-Api.ps1
    ├── deploy.config.json     ← EVERY tunable lives here
    ├── nginx/                api.conf.template (reverse proxy)
    ├── templates/            api.service, deploy.env, dayz-ctl, sudoers
    └── remote/deploy.sh      STATIC installer that runs on the box
```

---

## What it can do (the allowlist)

A caller can only ever invoke a name in [`app/src/actions.ts`](app/src/actions.ts).
There is no arbitrary-command path.

**Discovering the surface:** `GET /` (public) is the whole-API index — every endpoint
(root + all namespaces, auto-collected from the live route table, so nothing drifts)
plus the dayz action allowlist. `GET /dayz/actions` is the focused per-namespace list.

| Action | Effect | Destructive? |
|---|---|---|
| `restart` / `stop` / `start` | warn (if anyone's on) → `systemctl … dayz-server` | restart, stop |
| `status` | server info: state, uptime, players, map, mod list (names from each mod's `meta.cpp`), next scheduled restart | no |
| `players` | online player count + BattlEye's full reply (RCon) | no |
| `map` | warn (if anyone's on) → write `map.env` → restart (`{ "mission": "dayzOffline.enoch" }`) | yes |
| `broadcast` | in-game message to all (`{ "message": "…" }`) | no |
| `log` | tail of the newest DayZ RPT or ADM log (`lines` 1-500 default 100, `type` rpt\|adm) | no |
| `configs` / `config` | list / retrieve the allowlisted config files (secrets redacted) | no |

These are the `/dayz/*` **namespace** actions. Host load is **not** among them:
`POST /sysload` lives at the **root** (it is about the whole box, not the game
server) - authenticated but namespace-free, see below.

Every **privileged** action maps to a verb in **`dayz-ctl`** - the single privileged
script (below). `status` and the root `/sysload` share the argument-less `info` verb:
one privileged snapshot (unit props, running mod list, restart deadline, dir sizes)
that each slices differently. `/sysload`'s host stats stay the deliberate exception:
`/proc` and `statfs` need no root, so they never touch the sudo bridge - only its
dayz block rides on `info` (the game home is 0750; its sizes are unreadable without
it, and the block degrades to `null` if the bridge errors). Adding a capability = a
new action here **and** (only if it needs privilege) a new verb there; nothing else
gains privilege.

`status` computes **next restart** from the unit's start time + the `messages.xml`
shutdown deadline (the native scheduler restarts the server that many minutes after
start). It is marked `estimated` - mission load shifts it by a minute or two.

**Read-only actions accept URL query params** (e.g. `POST /dayz/log?lines=200&type=adm`
with an empty signed body). Destructive actions read *only* the HMAC-signed JSON body -
the query string isn't signed, and a replayed signed request must not be steerable by
tampering with it.

---

## Security model (defense in depth)

This service can reboot a game server from the public internet, so it is layered:

1. **TLS + one way in.** Node binds `127.0.0.1` only; nginx terminates TLS on
   `api.<domain>` and is the sole ingress. No new public ports (80/443 only).
2. **Authenticate every call.** Command endpoints require an **HMAC-SHA256** signature
   over the raw body (`X-Signature-256: sha256=<hex>`), constant-time compared - keyed
   with the wizard secret, or a **derived key** (below). The VPP event endpoint
   authenticates by a **secret token in the URL** (that is all a Discord-style sender
   can do - treat the URL like a password). The deliberate public exceptions are
   `GET /dayz/server-info` (plus `/healthz` and `GET /dayz/actions`): read-only, no
   state change, and nothing in server-info that the Steam server browser doesn't
   already publish - see [`routes/public.ts`](app/src/routes/public.ts). `POST /sysload`
   is authed (host internals) but namespace-free: any valid key or the wizard.
3. **Wizard key mints derived keys - never hand out the wizard.** The deploy-generated
   wizard (in `/etc/api/secrets.env`) is the root credential; other platforms (a
   Discord bot, a dashboard, cron) get their own key via `POST /keys/create`
   (wizard-signed, body `{ "id": "discord-bot", "scope": "observe", "namespaces": ["dayz"] }`).
   The secret is returned **once**; callers send `X-Key-Id: <id>` and sign with it.
   Derived keys live server-side (`/var/lib/api/keys.json`, service-user-owned, 0600),
   are independent random values - so **rotating the wizard never breaks them** - and
   are individually revocable (`/keys/revoke`, takes effect immediately) and
   adjustable in place (`/keys/update` changes scope/namespaces **without rotating the
   secret**, so the caller keeps working). A key is
   **(capability × namespaces)**, two independent axes:
   - **capability** - `scope` `full` (any action) or `observe` (read-only only:
     status/players/log/configs/config). Wrong capability → 403 `forbidden_scope`.
   - **namespaces** - which services it may reach (`["dayz"]`, or `["*"]` for all
     present and future). A key for one service can't touch another. Wrong namespace
     → 403 `forbidden_namespace`. Keys minted before this axis existed default to
     `["dayz"]`.

   Key management itself is always wizard-only, and every audit row records which
   key signed the request.
4. **No command passthrough.** The action name is looked up in the allowlist; payload
   text (e.g. a broadcast) is sanitised and passed as an **argv element**, never through
   a shell.
5. **Least privilege - one script, one sudoers line.** The service runs as the
   unprivileged `api` user, whose *entire* root capability is:
   ```
   api ALL=(root) NOPASSWD: /usr/local/bin/dayz-ctl
   ```
   `dayz-ctl` has a closed verb set (`restart|start|stop|status|players|broadcast|set-map|log|config|config-list|info`)
   and re-validates every argument (mission name whitelisted against installed
   `mpmissions/`; broadcast text reduced to capped printable ASCII; log tail capped at
   500 lines of the newest file in a fixed directory - caller input never forms a path)
   regardless of what the service already checked.
6. **Rate limit + cooldown.** A coarse global IP rate limit, plus a **per-action
   cooldown** - a second `restart` inside the window gets a friendly `409` telling it
   how many seconds to wait (customisable in `deploy.config.json → Cooldowns`).
7. **Player guard.** Destructive actions refuse while players are online (or if the
   count can't be verified over RCon), unless the body says `{"force": true}` - the same
   conservative stance as the DayZ deploy's guard.
8. **Warn before yanking anyone offline.** Once a destructive action actually runs
   (guard passed, or `force: true` overrode it), `restart` / `stop` / `map` first check
   the live player count again - if anyone's connected, they get an in-game broadcast
   and `Dayz.RestartWarningSeconds` (default 15s) to reach safety *before* `dayz-ctl`
   is called. Skipped entirely when nobody's on. The actual data-safety comes from
   `dayz-server.service`'s `ExecStop=kill -s INT` (the engine treats that as a clean
   shutdown and saves, same as the native `messages.xml` schedule and VPP's manual
   restart button) - the warning just means players aren't cut off without notice.
   Default fits nginx's 30s `proxy_read_timeout` on this vhost with margin; raise it
   past ~25s and bump that timeout too, or callers see a client-side timeout even
   though the restart still completes.
9. **Audit everything.** Every decision (accepted / rejected / failed) is written to
   journald (full JSON) **and** a fixed-column CSV ledger in `AuditDir`.

> **Why the systemd unit is only lightly sandboxed:** the service's job is to `sudo`
> to a helper, and systemd's strict sandbox (like CryptPad's) both breaks `sudo`
> (`NoNewPrivileges`) and propagates to the helper's child processes (blocking
> `map.env` writes / `systemctl`). The boundary here is the **sudoers allowlist +
> `dayz-ctl` validation**, not systemd confinement. This is called out in the unit.

---

## VPP compatibility - read this before wiring VPP

**VPPAdminTools' "WebHooks" feature is _outbound_ and Discord-shaped.** It POSTs
Discord-format JSON (`{ content, embeds }`) to a URL when in-game events fire (player
join/leave, admin actions, fall damage, …). It is an **event feed, not a command
channel** - there is no built-in way for VPP to say "reboot now."

So the two ingress styles are distinct on purpose:

- **`POST /dayz/:action` (commands)** - the real *trigger* path. Use it from a caller
  built to issue commands: a small admin page, a Discord **bot** with slash commands,
  or CLI/cron. HMAC-signed.
- **`POST /dayz/sources/vpp/:token` (event source)** - receives and **audits** VPP's feed.
  Turning a VPP event into an action is opt-in via `Vpp.Rules` (substring match →
  action), **disabled by default** because pattern-matching log text is brittle. Example
  rule (an admin types a magic phrase in-game that VPP logs to us):
  ```powershell
  Vpp = @{ Enabled = $true; Rules = @(
      @{ match = '!restart-now'; action = 'restart'; params = @{} }
  )}
  ```

If the goal is "an admin presses a button and the server restarts," the clean path is a
**companion Discord bot / admin page** hitting the command API - not VPP. The VPP feed
is best used for *observability* (and, cautiously, the opt-in rules).

## Bandit "events" - not achievable live (yet)

AI Bandits are **start-time**: `Build-AIBandits.ps1` composes the flat config in
`prestart.sh`, and the mod reads a fixed path **at boot**. BattlEye RCon exposes only its
fixed command set (mods can't register custom RCon verbs), so there is **no external hook
to spawn a bandit event at coordinates without a restart**. The only real levers are (a)
an RCon broadcast, or (b) editing the per-map placement + redeploy + **restart**. Live,
instant, located events would need a mod that watches a file/endpoint - out of scope. Per
your call, the live version is **scrapped**; if you later want the restart-based version,
it slots in as a new action.

---

## Deploy (same two-layer shape as the other services)

Report-only by default; add the apply flag to touch the box.

| Layer | Command | Apply flag |
|---|---|---|
| edge (vhost + cert) | `../../Provision-Tls.ps1 -Service Api` | `-Apply` |
| payload (the app) | `deploy/Deploy-Api.ps1` | `-Apply` |

### First-time go-live

```powershell
# 1. Edge - issue the cert + install the reverse-proxy vhost.
#    Use -SkipTls first if api.<domain> doesn't resolve yet, then re-run without it.
../../Provision-Tls.ps1 -Service Api -Apply

# 2. Payload - build the app, install the unit + dayz-ctl + sudoers, generate secrets.
deploy/Deploy-Api.ps1 -Apply

# 3. Retrieve the generated secrets ON THE BOX (never printed to the local log):
#    sudo cat /etc/api/secrets.env
#    → HMAC_SECRET  (sign command requests)
#    → VPP_TOKEN    (goes in the VPP webhook URL: https://api.<domain>/dayz/sources/vpp/<token>)
```

The DayZ server must already be deployed (dayz-ctl calls its `dayz-rcon.ps1` and unit).

### Calling the command API

```bash
# body must be signed with HMAC-SHA256 over the EXACT bytes sent
body='{"message":"Server restarting in 5 minutes"}'
sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$HMAC_SECRET" -hex | sed 's/^.* //')
curl -sS https://api.<domain>/dayz/broadcast \
  -H "content-type: application/json" \
  -H "x-signature-256: sha256=$sig" \
  -d "$body"

# Read-only actions can carry their params in the query string with an empty
# signed body (query params are ignored on destructive actions - see above):
sig=$(printf '' | openssl dgst -sha256 -hmac "$HMAC_SECRET" -hex | sed 's/^.* //')
curl -sS -X POST "https://api.<domain>/dayz/log?lines=200&type=rpt" \
  -H "x-signature-256: sha256=$sig"

# Host load is a ROOT endpoint (about the box, not dayz) - authed, empty signed body:
curl -sS -X POST "https://api.<domain>/sysload" -H "x-signature-256: sha256=$sig"

# GET /            (no auth) is the whole-API index: every endpoint + the dayz actions.
# GET /dayz/actions (no auth) is the focused dayz allowlist; GET /healthz is liveness.

# GET /dayz/server-info (no auth) is the PUBLIC current-server-info snapshot for the
# static site's panel: state, uptime, players, map, mods, next restart. Cached 10s,
# CORS *, GET only. No auth is deliberate - the Steam server browser already
# publishes every one of those fields; see app/src/routes/public.ts for the full
# rationale. It is not an action name, so the signed command pipeline is untouched.
curl -sS https://api.<domain>/dayz/server-info
```

---

## Where things live (so you never hunt for a value)

- **All tunables:** [`deploy/deploy.config.json`](deploy/deploy.config.json) - port,
  cooldowns, player guard, rate limit, which DayZ unit/dir, VPP rules. The scripts hold
  no values.
- **The HTTP surface spec:** [`openapi.yaml`](openapi.yaml) - OpenAPI 3.0, kept in
  sync with `actions.ts`. [`bruno/`](bruno/) is a ready-to-use Bruno collection with
  automatic HMAC signing; `bruno/spec-to-bru.mjs` scaffolds new requests from the
  spec (see [`bruno/README.md`](bruno/README.md)).
- **Secrets:** generated once on the box → `/etc/api/secrets.env` (never in the
  repo or the deploy log).
- **The allowlist (what can happen at all):** [`app/src/actions.ts`](app/src/actions.ts).
- **The privilege surface:** [`deploy/templates/dayz-ctl.template`](deploy/templates/dayz-ctl.template)
  + [`api.sudoers.template`](deploy/templates/api.sudoers.template).
- **What ran, and when:** `AuditDir` on the box (CSV) + `journalctl -u api`; deploy
  runs are logged to `logs/` here.

**Never hand-edit the live box.** Change a template / config / source here and redeploy.

---

## The one deliberate coupling

The service lives inside `NginxService/` but drives DayZ, which lives outside it. That is
one-directional and declared: `deploy.config.json → Dayz` names the unit + server dir, and
the service reaches DayZ **only** through `dayz-ctl` - never into DayZ's deploy internals.
Nothing in the DayZ project depends on this service; it can be removed with no effect on
the game server.
