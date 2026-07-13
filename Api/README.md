# Webhooks - authenticated bridge from HTTP to allowlisted server actions

A small [Fastify](https://fastify.dev) (Node/TypeScript) service that turns **signed
HTTP calls** into a **fixed set of server actions**. First consumer: the DayZ server
(restart, map switch, broadcast, …). It is deliberately general - adding other
applications later is a config entry, not a rewrite.

It is served *behind nginx*, so it lives **inside `NginxService/`** as a sibling of
CryptPad. Its *effects*, however, land on the **DayZ server, which lives outside**
`NginxService/` (DayZ is UDP, not proxied). That crossing is real and deliberate - it
is made explicit here, not hidden (see [The one deliberate coupling](#the-one-deliberate-coupling)).

```text
Webhooks/
├── app/                     Fastify + TypeScript source (built on the box)
│   └── src/
│       ├── server.ts        bootstrap: raw-body parser, rate limit, routes
│       ├── config.ts        config.json (non-secret) + env (secrets)
│       ├── auth.ts          HMAC-SHA256 + URL-token verify (constant-time)
│       ├── guard.ts         per-action cooldowns
│       ├── dayz.ts          the `sudo dayz-ctl` bridge + player count
│       ├── actions.ts       THE ALLOWLIST (restart/stop/start/status/players/map/broadcast)
│       └── routes/
│           ├── commands.ts  POST /dayz/:action        (HMAC-signed - the trigger API)
│           └── sources.ts   POST /sources/vpp/:token  (event feed from VPP)
└── deploy/                  render → stage → ship → run (same shape as CryptPad)
    ├── Deploy-Webhooks.ps1
    ├── deploy.config.json     ← EVERY tunable lives here
    ├── nginx/                webhooks.conf.template (reverse proxy)
    ├── templates/            webhooks.service, deploy.env, dayz-ctl, sudoers
    └── remote/deploy.sh      STATIC installer that runs on the box
```

---

## What it can do (the allowlist)

A webhook can only ever invoke a name in [`app/src/actions.ts`](app/src/actions.ts).
There is no arbitrary-command path.

| Action                       | Effect                                                                                   | Destructive?  |
| ---------------------------- | ---------------------------------------------------------------------------------------- | ------------- |
| `restart` / `stop` / `start` | warn (if anyone's on) → `systemctl … dayz-server`                                        | restart, stop |
| `status`                     | is the unit active?                                                                      | no            |
| `players`                    | current online count (RCon)                                                              | no            |
| `map`                        | warn (if anyone's on) → write `map.env` → restart (`{ "mission": "dayzOffline.enoch" }`) | yes           |
| `broadcast`                  | in-game message to all (`{ "message": "…" }`)                                            | no            |

Every action maps to a verb in **`dayz-ctl`** - the single privileged script (below).
Adding a capability = a new action here **and** a new verb there - nothing else gains
privilege.

---

## Security model (defense in depth)

This service can reboot a game server from the public internet, so it is layered:

1. **TLS + one way in.** Node binds `127.0.0.1` only - nginx terminates TLS on
   `hooks.<domain>` and is the sole ingress. No new public ports (80/443 only).
2. **Authenticate every call.** Command endpoints require an **HMAC-SHA256** signature
   over the raw body (`X-Signature-256: sha256=<hex>`), constant-time compared. The VPP
   event endpoint authenticates by a **secret token in the URL** (that is all a
   Discord-style sender can do - treat the URL like a password).
3. **No command passthrough.** The action name is looked up in the allowlist - payload
   text (e.g. a broadcast) is sanitised and passed as an **argv element**, never through
   a shell.
4. **Least privilege - one script, one sudoers line.** The service runs as the
   unprivileged `webhooks` user, whose *entire* root capability is:
   `webhooks ALL=(root) NOPASSWD: /usr/local/bin/dayz-ctl`

   `dayz-ctl` has a closed verb set (`restart|start|stop|status|players|broadcast|set-map`)
   and re-validates every argument (mission name whitelisted against installed
   `mpmissions/` - broadcast text reduced to capped printable ASCII) regardless of what
   the service already checked.
5. **Rate limit + cooldown.** A coarse global IP rate limit, plus a **per-action
   cooldown** - a second `restart` inside the window gets a friendly `409` telling it
   how many seconds to wait (customisable in `deploy.config.json → Cooldowns`).
6. **Player guard.** Destructive actions refuse while players are online (or if the
   count can't be verified over RCon), unless the body says `{"force": true}` - the same
   conservative stance as the DayZ deploy's guard.
7. **Warn before yanking anyone offline.** Once a destructive action actually runs
   (guard passed, or `force: true` overrode it), `restart` / `stop` / `map` first
   check the live player count again. If anyone's connected, they get an in-game
   broadcast and `Dayz.RestartWarningSeconds` (default 15s) to reach safety
   *before* `dayz-ctl` is called. Skipped entirely when nobody's on.

   The warning is a courtesy, not the safety mechanism. Actual data-safety comes
   from `dayz-server.service`'s `ExecStop=kill -s INT` - the engine treats that
   as a clean shutdown and saves, same as the native `messages.xml` schedule and
   VPP's manual restart button.

   Default fits nginx's 30s `proxy_read_timeout` on this vhost, with margin.
   Raise it past ~25s and bump that timeout too - otherwise callers see a
   client-side timeout even though the restart still completes.
8. **Audit everything.** Every decision (accepted / rejected / failed) is written to
   journald (full JSON) **and** a fixed-column CSV ledger in `AuditDir`.

> **Why the systemd unit is only lightly sandboxed:** the service's job is to `sudo`
> to a helper, and systemd's strict sandbox (like CryptPad's) both breaks `sudo`
> (`NoNewPrivileges`) and propagates to the helper's child processes (blocking
> `map.env` writes / `systemctl`). The boundary here is the **sudoers allowlist +
> `dayz-ctl` validation**, not systemd confinement. This is called out in the unit.

---

## VPP compatibility - read this before wiring VPP

**VPPAdminTools' "WebHooks" feature is *outbound* and Discord-shaped.** It POSTs
Discord-format JSON (`{ content, embeds }`) to a URL when in-game events fire (player
join/leave, admin actions, fall damage, …). It is an **event feed, not a command
channel** - there is no built-in way for VPP to say "reboot now."

So the two ingress styles are distinct on purpose:

- **`POST /dayz/:action` (commands)** - the real *trigger* path. Use it from a caller
  built to issue commands: a small admin page, a Discord **bot** with slash commands,
  or CLI/cron. HMAC-signed.
- **`POST /sources/vpp/:token` (event source)** - receives and **audits** VPP's feed.
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

AI Bandits are **start-time**. `Build-AIBandits.ps1` composes the flat config in
`prestart.sh`, and the mod reads a fixed path **at boot**. BattlEye RCon exposes
only its fixed command set - mods can't register custom RCon verbs. So there is
**no external hook to spawn a bandit event at coordinates without a restart**.

The only real levers are an RCon broadcast, or editing the per-map placement,
redeploying, and **restarting**. A live, instant, located event would need a mod
that watches a file or endpoint - out of scope.

Per your call, the live version is **scrapped**. If you later want the
restart-based version, it slots in as a new action.

---

## Deploy (same two-layer shape as the other services)

Report-only by default - add the apply flag to touch the box.

| Layer               | Command                                     | Apply flag |
| ------------------- | ------------------------------------------- | ---------- |
| edge (vhost + cert) | `../../Provision-Tls.ps1 -Service Webhooks` | `-Apply`   |
| payload (the app)   | `deploy/Deploy-Webhooks.ps1`                | `-Apply`   |

### First-time go-live

```powershell
# 1. Edge - issue the cert + install the reverse-proxy vhost.
#    Use -SkipTls first if hooks.<domain> doesn't resolve yet, then re-run without it.
../../Provision-Tls.ps1 -Service Webhooks -Apply

# 2. Payload - build the app, install the unit + dayz-ctl + sudoers, generate secrets.
deploy/Deploy-Webhooks.ps1 -Apply

# 3. Retrieve the generated secrets ON THE BOX (never printed to the local log):
#    sudo cat /etc/webhooks/secrets.env
#    → HMAC_SECRET  (sign command requests)
#    → VPP_TOKEN    (goes in the VPP webhook URL: https://hooks.<domain>/sources/vpp/<token>)
```

The DayZ server must already be deployed (dayz-ctl calls its `dayz-rcon.ps1` and unit).

### Calling the command API

```bash
# body must be signed with HMAC-SHA256 over the EXACT bytes sent
body='{"message":"Server restarting in 5 minutes"}'
sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$HMAC_SECRET" -hex | sed 's/^.* //')
curl -sS https://hooks.<domain>/dayz/broadcast \
  -H "content-type: application/json" \
  -H "x-signature-256: sha256=$sig" \
  -d "$body"

# GET /actions  (no auth) lists what can be triggered - GET /healthz is a liveness probe.
```

---

## Where things live (so you never hunt for a value)

- **All tunables:** [`deploy/deploy.config.json`](deploy/deploy.config.json) - port,
  cooldowns, player guard, rate limit, which DayZ unit/dir, VPP rules. The scripts hold
  no values.
- **Secrets:** generated once on the box → `/etc/webhooks/secrets.env` (never in the
  repo or the deploy log).
- **The allowlist (what can happen at all):** [`app/src/actions.ts`](app/src/actions.ts).
- **The privilege surface:** [`deploy/templates/dayz-ctl.template`](deploy/templates/dayz-ctl.template)
  - [`webhooks.sudoers.template`](deploy/templates/webhooks.sudoers.template).
- **What ran, and when:** `AuditDir` on the box (CSV) + `journalctl -u webhooks` - deploy
  runs are logged to `logs/` here.

**Never hand-edit the live box.** Change a template / config / source here and redeploy.

---

## The one deliberate coupling

The service lives inside `NginxService/` but drives DayZ, which lives outside it.
That coupling is one-directional and declared: `deploy.config.json → Dayz` names
the unit and server dir. The service reaches DayZ **only** through `dayz-ctl` -
never into DayZ's deploy internals.

Nothing in the DayZ project depends on this service. Remove it and the game
server is unaffected.
