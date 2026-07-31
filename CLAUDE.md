# GameServices — Claude Instructions

ONE git repo (branch `main`) for everything deployed to the OVH VPS `servermander.ovh` (SSH: `ubuntu@servermander.ovh`) that is DayZ-related or a DayZ dependency: the game server, the nginx layer, the services behind it, the staging tooling, and the planning docs. Consolidated 2026-07-21 from the former `DayZ-Server` and `NginxService` repos - both histories preserved in this repo's DAG.

The ONE exception on the box: **CryptPad** has no DayZ relationship and lives in its own independent sibling repo at `../CryptPad/`. It reaches into this repo for shared infrastructure (contract below); this repo never reaches into it.

Subdir rules: `DayZ-Server/CLAUDE.md` carries the game-server specifics.

---

## Change notices (mandatory, every change)

Every change ships a terse PR-changelog notice - even a one-liner: **Why** (objective reason) / **What** (files + concrete diff) / **Confirmed by** (a LOCAL unit test written TEST-FIRST - derived from the goal, run and seen to FAIL, then code makes it pass; a test authored after the code to match it proves nothing; not a VM / e2e run; no test = say so and why). Never claim "done"/"verified" without a test that failed first. A question is NOT a build order: answer it, propose the change, get a go before any non-trivial build. Generalize - one mechanism for N cases; never ship per-case copy-paste mirrors (reducing dependencies + abstracting is the goal).

---

## The box

- The VPS is the ONLY install - no local server copies exist (since 2026-07-06).
- **Never hand-patch the live box.** Fix the deploy script, redeploy. Code → Document → Deploy.
- Report/dry-run mode first - `-Fix` / `-Apply` / `-Push` to prod needs the user's go.
- Gotchas that look like bugs but aren't:
  - OVH edge firewall drops game UDP until rules are added in the OVH panel
  - VPS IPv6 is broken - steamcmd `(Timeout)` means the `gai.conf` IPv4-precedence fix is missing
- Box-only state with NO backup yet: `/etc/api/secrets.env`, `/var/lib/api/keys.json`, CryptPad admin key + admin-panel decrees, `beserver_x64.cfg`. Losing the box loses these (P2 in the plan).

## Layout

| Path | What |
|---|---|
| `DayZ-Server/` | game server code + config mirror. NOT behind nginx (UDP, not proxied); keeps its own `host.env`. Own rules: `DayZ-Server/CLAUDE.md` |
| `StaticishSite/` | Hugo site (hugo-book). Owns the nginx `default_server` catch-all - unknown subdomains 404 here, so it deploys first |
| `Api/` | Fastify/TypeScript on localhost:3100, public at `api.cytonicmushroom.ddns.net`. HMAC-signed requests → allowlisted DayZ actions via `sudo dayz-ctl` |
| `ConfigViewer/` | DayZ web UI. No build step - native ES modules under `web/js/`, deploy = rsync |
| `Monitoring/` | Prometheus + node_exporter + Grafana (public at `grafana.<BaseDomain>`, Grafana login guards it). Loopback stack, generic - scrape targets are config rows, dashboards are code |
| `staging/` | local QEMU staging VM tooling (`New-StagingVm.ps1`, `staging.env`). Design: `STAGING-PLAN.md` |
| `common/Deploy-Helpers.ps1` | shared SHIP+RUN (`New-SshArgs`, `Invoke-RemoteDeploy`) - the P1 extraction. Consumer: Monitoring; migrate the four older Deploy-*.ps1 one at a time |
| `Load-DeployConfig.ps1` | merges `host.config.<env>.env` (flat) + per-service `deploy/deploy.config.json` (nested) with `${Key}` interpolation. Nested services find the host config two levels up; an out-of-repo service passes `-HostConfigDir` |
| `Provision-Tls.ps1` | per-name HTTP-01 certs. `-Service` resolves against exactly two hardcoded places: `<root>/<Service>/deploy`, then `<root>/../<Service>/deploy` (a sibling repo under UbuntuHost). Prints which one it hit |

Code utilities (`Get-Stdout`, `Write-CsvLog`) live at `Dev/common/Utils.ps1`, two levels above this repo.

## Cross-repo contract (the only one left)

- **CryptPad reaches in, never the reverse.** Its edge is `./Provision-Tls.ps1 -Service CryptPad` (the engine's sibling lookup); its payload script dot-sources `Load-DeployConfig.ps1` from here and passes `-HostConfigDir` at this root. There is ONE TLS engine and ONE `host.config.<env>.env` - never copy either into CryptPad. The two repos must stay side by side under `UbuntuHost/`.
- **Loopback port map (check before adding a service, either repo):** CryptPad `3000`+`3003`, Grafana `3001`, API `3100`, Prometheus `9090`, node_exporter `9100`. Grafana's default is 3000 - it collides with CryptPad, hence 3001. The map lives here because port claims span both repos.

## Design contract (owner, 2026-07-31 - standing scope; plan + tasks: `Scale-Ready/PLAN.md`)

- **One mechanism per concept, and a migration ENDS AT DELETION.** One write path (the generic registry-driven own-write; the bespoke verbs are being retired - NEVER add one), one editor family (json-editor-ui navigator for structured JSON, CM6 for XML/raw text), one propagation engine for generator inputs. A new parallel mechanism is a defect to surface, not a shortcut; mechanism counts only go down (gate-asserted as the assertions land).
- **Two-copy config model, no field-patch layer.** Every regular config has a `*.defaults.*` companion. A surface is either a direct replacement (edited whole, diffed vs the frozen default) or a generator input (common + per-map inputs propagate into the generated files - one shared engine, WS-G).
- **A feature request is PLACED before it is built:** name its surface category (owned/computed/reference/input), its editor, and its write path against the whole design. If any answer is "a new one", that is a STOP-and-surface, not a build.
- **A test outside the runner does not exist.** Tests are written first (change-notice rule) AND live where the shared runner + deploy gates re-run them (WS-T; until the runner lands, run the sibling `tests/` by hand and say which in the notice).
- **A design decision that CAN be a gate assertion IS one** - rationale in the failure message. A decision that lives only in a doc will be missed (proven 2026-07-24→31).

## Structural rules (a violation is STOP-and-surface, never work-around)

- **One concept, one owner.** Mod enablement = `mods.conf`. A config surface = its registry row. Any system holding a hand-synced copy of that state is a defect to surface, not a place to remember.
- **If a change requires edits beyond the declaring row + one consumer, the design is the bug** - name it before patching the N places, and it enters Open Work (Dev/CLAUDE.md).
- **A cross-system invariant is a gate assertion (Test-Configs) or it does not exist.** "Keep X in sync with Y" written in a doc = a missing assertion.
- **This file carries contracts, traps, and intent - never structure maps.** Needing a map to edit safely means the structure failed; fix or gate it instead.

## Deploy doctrine

- **Stage-and-ship** - server-bound content is real repo files, never here-string script vars.
- **Config is data** - tunables live in config files (`host.config.<env>.env`, `deploy.config.json`, `host.env`), never script params. `Deploy-Site.ps1` and `Deploy-ConfigViewer.ps1` still take params - legacy violators awaiting the P1b migration, don't copy their pattern.
- **Shared tools, not shared fates** - no generic deploy engine; each service ships itself.
- **Staging by default (2026-07-21)** - every deploy script's `-Env` defaults to the local staging VM (`host.config.staging.env` → `staging-vm`, `BaseDomain=localhost`); `-Env prod` is the only way to reach the VPS, and prod `-Fix` demands clean main. Staging is http-only: `Provision-Tls` refuses it without `-SkipTls`. Mirror pulls + the backup auto-commit are prod-only. Any `if ($cfg.Env ...)` branch must map to a row in `STAGING-PLAN.md`'s deviation table.
- **Fresh-box deploy order:** StaticishSite first (owns the nginx `default_server` catch-all), DayZ-Server before Api (dayz-ctl needs its target), Api before ConfigViewer.
- **`SshPort` is only for boxes reached by real hostname.** An explicit `ssh -p` OVERRIDES a `~/.ssh/config` Host alias's `Port`, so setting `SshPort` for an alias-reached box (staging-vm = 127.0.0.1:2222) silently retargets the deploy at 127.0.0.1:22 - the dev machine's own sshd, which then prompts for a password. Every script omits `-p` entirely when `SshPort` is unset; leave it unset for alias-reached boxes. A password prompt from any deploy means you're not talking to the box you think you are - stop and check `ssh -G <target>`.

## Config architecture doctrine

Direction agreed 2026-07-20 after a full reassessment. These principles hold now; the two-copy target below is agreed but **not built yet** - the box still runs the delta/override engine until files are migrated across.

- **One contract, declared once** - every config surface lives in `DayZ-Server/config-registry.json`. Add a config = add a row, not knowledge scattered across tiers.
- **A part ships only when the whole is consistent** - a new or changed config is wired across every tier before it ships; the pre-deploy gate fails closed and checks the whole *(intent: integration is proven, not hoped)*.
- **Single authority per file - never dual-write** - each file is box-owned, builder-owned, or repo-owned. One owner.
- **No logic duplicated across tiers** - shared logic lives in one tier; the others call it.
- **Test the seams** - isolated tier tests pass while integration breaks. Cover the cross-tier path.

**Target model** (migration ACTIVE - owner priority 2026-07-29): owned files keep two whole copies - `default` reference + `live` - and the diff is shown by the UI, never applied by the box. Per-phase status + worklist live in `CONFIG-ARCHITECTURE.md` - the single source of truth for the config model. Phase 0 (classification, registry `category` field) done; do not add NEW override-patch targets without checking the worklist first.

## Service rules

- **Secrets never enter the repo.** `/etc/api/secrets.env` and `/var/lib/api/keys.json` are generated on the box.
- **The Api's config allowlist is not hand-edited.** `Deploy-Api.ps1` derives it from `DayZ-Server/config-registry.json` at deploy time. To expose a new config surface, add a registry row there.
- **ConfigViewer tiles** (`web/tiles/`, ~323 MB, gitignored) come from the MapDataExtraction project. The deploy rsync carries `--filter=P /tiles/***` so server-side tiles are never deleted - do not remove that filter.
- **lossless-json has two copies that must stay in sync:** `Api/app/src/lossless-json.ts` and `ConfigViewer/web/js/lossless-json.js`. The sentinel is written as the explicit `'\uE000'` escape - NEVER inline the raw character. It is invisible in editors, and if it gets stripped the restore regex degrades to unquoting every numeric string.
- **Rate limits:** API global limit 120 req/min per IP; `apiPost` backs off client-wide on 429. New pollers go through `apiPost` so they inherit the backoff.
- **`GET /metrics` on the Api is LOCAL-ONLY.** Three layers enforce it: nginx `location = /metrics { return 404; }` in the Api vhost, `location = /api/metrics` in the ConfigViewer vhost, and the app 404s any request carrying `X-Forwarded-For`. Keep all three when touching those templates.
- **The Monitoring stack stays generic.** Nothing service-specific in its templates or `provision.sh`; new capture targets are `ScrapeJobs` rows in its `deploy.config.json`. Dashboards and alert rules are code, bound to datasource uid `prometheus` - a contract with `grafana-datasource.yml.template`; UI edits to provisioned dashboards/rules are not persisted across deploys. The Grafana admin password is generated on-box, printed once, stored nowhere in the repo; rotate by deleting `/var/lib/grafana/.admin-password-set` and redeploying.
- **Server FPS is PUSH, not pull.** Everything else in `/metrics` is pulled on scrape; `dayz_server_fps` is pushed by VPPAdminTools' server-status webhook into the API's VPP ingress (`routes/sources.ts` → `vpp-stats.ts` → `/metrics`). Dropped once stale (>180s); `dayz_server_status_age_seconds` reports freshness. Enable in VPP's in-game WebHooks menu, not via deploy.
- **Favicon identity**: one shared "mushroom-monogram" mark across all domains - source SVG + rsvg/magick regen; wired into StaticishSite + ConfigViewer (Api/CryptPad offered, not wired).

## Plans

`MAINTENANCE-PLAN.md` holds the P0-P4 state from the 2026-07-15 triple audit plus addenda. Before proposing a P-item, verify it isn't already done - file presence + git log, not memory. Known debt: P1b - migrate the four older `Deploy-*.ps1` onto `common/Deploy-Helpers.ps1`, migrate the two param scripts to config-only, lift the catch-all to a host-level template.

---

## Changelog

History moved to [CLAUDE-CHANGELOG.md](CLAUDE-CHANGELOG.md). Do not add dated entries here - this file loads into every request. Log rule rationale in the sibling file instead.
