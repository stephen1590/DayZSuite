# GameServices — Claude Instructions

> **BEHAVIOUR ONLY.** This file loads verbatim into every request. No history, no dated status, no
> project state, no structure maps. What the repo *is* goes in [README.md](README.md); open work goes
> in the tracker. Update a rule here when friction occurs or a preference is confirmed.

ONE git repo (branch `main`) for everything on the VPS with a DayZ dependency: the game server, the
nginx layer, the services behind it, and the staging tooling. **CryptPad is the sole exception** - no
DayZ relationship, its own sibling repo at `../CryptPad/`.

`DayZ-Server/CLAUDE.md` carries the game-server specifics.

---

## Change notices (mandatory, every change)

Every change ships a terse PR-changelog notice - even a one-liner:

- **Why** - the objective reason.
- **What** - files and the concrete diff.
- **Confirmed by** - a LOCAL unit test written TEST-FIRST: derived from the goal, run and seen to
  FAIL, then code written to make it pass. A test authored after the code restates the code and
  proves nothing. Not a VM or e2e run. No test = say so and why.

Never claim "done" or "verified" without a test that failed first. A question is NOT a build order:
answer it, propose the change, get a go before any non-trivial build. Generalize - one mechanism for
N cases; never ship per-case copy-paste mirrors.

**Comments carry constraints, never history.** No dates, incident stories, owner quotes, commit refs,
before/after narration, or test evidence in source comments - that is change-notice content and it
rots silently. One line stating the timeless trap ("getValue() on a container serializes the whole
subtree") is the ceiling. **If code is not apparent in its function even without comments, that is a
structural defect: FLAG it (tracker row), do not paper it with prose.**

## Working on the box

- **Never hand-patch the live box.** Fix the deploy script, redeploy. Code → Document → Deploy.
- **Report/dry-run first.** Prod deploy permission (owner, standing): Api and ConfigViewer are
  always fine; DayZ-Server is fine when no one is online playing. Anything else against prod
  (`-Fix` / `-Apply` / `-Push`) needs the user's go.
- **PAUSE the staging VM when testing is done** - `virsh suspend staging-vm`. It runs on the
  owner's workstation and heats it; resume (`virsh resume`) only for the run that needs it, and
  suspend again in the same turn. A resumed VM left running is a defect, not a convenience.
- **Never restart prod unasked.** Staging a fix is the ceiling; the restart is the owner's call.
- The VPS is the ONLY install - no local server copy exists to test against.

## Design contract

- **One mechanism per concept.** One write path (the generic registry-driven `own-write`; the bespoke
  verbs are being retired - NEVER add one), one editor family (`json-editor-ui` for structured JSON,
  CM6 for XML and raw text), one propagation engine for generator inputs. A new parallel mechanism is
  a defect to surface, not a shortcut. Mechanism counts only go down.
- **Two-copy config model, no field-patch layer.** Every regular config has a `*.defaults.*`
  companion. A surface is either a direct replacement (edited whole, diffed against the frozen
  default) or a generator input that propagates into generated files through one shared engine.
- **A feature request is PLACED before it is built** - name its surface category, its editor and its
  write path against the whole design. If any answer is "a new one", that is a STOP-and-surface.
- **A test outside the shared runner does not exist.** Tests are written first and live where the
  runner and the deploy gates re-run them.
- **A design decision that CAN be a gate assertion IS one** - rationale in the failure message. A
  decision that lives only in a doc gets missed.

## Structural rules (a violation is STOP-and-surface, never work-around)

- **One concept, one owner.** Mod enablement = `mods.conf`. A config surface = its registry row. Any
  system holding a hand-synced copy of that state is a defect to surface, not a place to remember.
- **If a change requires edits beyond the declaring row plus one consumer, the design is the bug** -
  name it before patching the N places, and it enters `Dev/OPEN-WORK.md`.
- **A cross-system invariant is a gate assertion (`Test-Configs`) or it does not exist.** "Keep X in
  sync with Y" written in a doc is a missing assertion.
- **CryptPad reaches into this repo, never the reverse.** There is ONE TLS engine and ONE
  `host.config.<env>.env` - never copy either into CryptPad. Check the loopback port map in
  [README.md](README.md) before claiming a port in either repo.

## Deploy doctrine

- **Stage-and-ship** - server-bound content is real repo files, never here-string script vars.
- **Config is data** - tunables live in config files (`host.config.<env>.env`, `deploy.config.json`,
  `host.env`), never script params.
- **Shared tools, not shared fates** - no generic deploy engine; each service ships itself.
- **Staging by default** - every deploy script's `-Env` defaults to the local staging VM; `-Env prod`
  is the only way to reach the VPS, and prod `-Fix` demands a clean `main`. Staging is http-only:
  `Provision-Tls` refuses it without `-SkipTls`. Mirror pulls and the backup auto-commit are
  prod-only. Any `if ($cfg.Env ...)` branch is a deliberate deviation - justify it at the branch.
- **Edge before payload, within a service.** `Provision-Tls.ps1` creates the webroot; pushing a
  payload to an unprovisioned box fails with rsync exit 11. Between services the order is free,
  except on a fresh box: StaticishSite first (it owns the nginx `default_server` catch-all), then
  DayZ-Server before Api (dayz-ctl needs its target), then Api before ConfigViewer.
- **`SshPort` is only for boxes reached by real hostname.** An explicit `ssh -p` OVERRIDES a
  `~/.ssh/config` Host alias's `Port`, silently retargeting the deploy at the dev machine's own sshd.
  Leave `SshPort` unset for alias-reached boxes. A password prompt from any deploy means you are not
  talking to the box you think you are - stop and check `ssh -G <target>`.

## Config architecture doctrine

Config is owned whole by the box; nothing patches a file at boot. Owned files keep two whole copies -
a frozen `<stem>.defaults.<ext>` and the live file - and the diff is SHOWN by the UI, never applied by
the box. `own-write` captures the default from the current bytes before its first replace, so state 0
always survives. The repo ships CODE; its config mirror is a BACKUP and is never copied onto a
running box.

**Ownership is not a flag anyone picks: it is whoever writes the file LAST.**

| last writer | example | edit on the box survives? | resolves to |
| --- | --- | --- | --- |
| the deploy (`$items`) | `mods.conf`, `prestart.sh` | no - next deploy stamps it | `ro` |
| the web editor | `db/types.xml`, `server-settings.json` | **yes** | `rw` - the owned case |
| a prestart builder | `serverDZ.cfg`, `mpmissions/*/custom/*` | no - next restart rebuilds it | `ro`, generated |
| the game engine | `storage_*`, logs, `profiles/users/` | n/a - not config | hidden |
| capture, once | `*.defaults.*` | must not be edited | `ro` |

- **OWNED IS NOT EDITABLE.** Ownership is who writes the file LAST; editability is whether the UI
  offers a write path. Ownership is the INPUT, editability falls out of it. Never flip a row to
  `owned` to unlock a writer - that is using the ownership field as an access flag, which is how
  `category` became one in the first place and why every file needs a hand-declared row today. If a
  file is not editable and you want it to be, the question is "who writes it last", not "what flag
  turns this on". Asserted by `DayZ-Server/tests/deny-list.test.ps1`.
- **One contract, declared once** - every config surface lives in `DayZ-Server/config-registry.json`.
  Adding a config means adding a row, not knowledge scattered across tiers.
- **A part ships only when the whole is consistent** - a new or changed config is wired across every
  tier before it ships; the pre-deploy gate fails closed and checks the whole.
- **Single authority per file - never dual-write.**
- **No logic duplicated across tiers** - shared logic lives in one tier; the others call it.
- **Test the seams** - isolated tier tests pass while integration breaks. Cover the cross-tier path.

## Service rules

- **Secrets never enter the repo.** `/etc/api/secrets.env` and `/var/lib/api/keys.json` are generated
  on the box.
- **The Api's config allowlist is not hand-edited.** `Deploy-Api.ps1` derives it from
  `DayZ-Server/config-registry.json` at deploy time. Expose a new surface by adding a registry row.
- **ConfigViewer tiles** (`web/tiles/`, gitignored) come from the MapDataExtraction project. The
  deploy rsync carries `--filter=P /tiles/***` so server-side tiles are never deleted - keep it.
- **`lossless-json` has two copies that must stay in sync:** `Api/app/src/lossless-json.ts` and
  `ConfigViewer/web/js/lossless-json.js`. The sentinel is written as a six-character escape
  (backslash, `u`, `E000`) - NEVER inline the raw character. It is invisible in editors, so it gets
  stripped by anything that touches the file, and the restore regex then degrades to unquoting every
  numeric string.
- **New pollers go through `apiPost`** so they inherit its client-wide 429 backoff.
- **`GET /metrics` on the Api is LOCAL-ONLY.** Three layers enforce it: nginx
  `location = /metrics { return 404; }` in the Api vhost, `location = /api/metrics` in the
  ConfigViewer vhost, and the app 404s any request carrying `X-Forwarded-For`. Keep all three when
  touching those templates.
- **The Monitoring stack stays generic.** Nothing service-specific in its templates or `provision.sh`;
  new capture targets are `ScrapeJobs` rows in its `deploy.config.json`. Dashboards and alert rules
  are code, bound to datasource uid `prometheus`; UI edits to provisioned dashboards are not persisted
  across deploys.
- **Server FPS is PUSH, not pull.** `dayz_server_fps` arrives from VPPAdminTools' server-status
  webhook; everything else in `/metrics` is pulled on scrape. Enable it in VPP's in-game WebHooks
  menu, not via deploy.
- **Never build `serverMods/` PBOs unless asked.**
