# GameServices - everything on the box with a DayZ dependency

ONE repo for **servermander.ovh**: the DayZ game server, the nginx + TLS layer,
every service behind it, the staging VM tooling, and the planning docs. If it is
DayZ-related or a DayZ dependency, it lives here. The only exception on the box
is CryptPad - no DayZ relationship, so it is an independent sibling repo at
`../CryptPad/` that reaches into this one for shared infrastructure.

```text
GameServices/
├── DayZ-Server/              the game server: deploy code + config mirror (UDP, NOT behind nginx)
├── StaticishSite/            Hugo site at the apex  cytonicmushroom.ddns.net
├── Api/                      command/observability API at  api.  (drives the DayZ server via sudo dayz-ctl)
├── ConfigViewer/             DayZ web UI at  configs.
├── Monitoring/               Prometheus + node_exporter + Grafana at  grafana.
├── staging/                  local QEMU staging VM tooling (New-StagingVm.ps1, staging.env)
│
├── host.config.<env>.env     ONE source of truth: Server / SshUser / BaseDomain / AdminEmail (flat KEY=VALUE)
├── Load-DeployConfig.ps1     loads host.config.<env>.env + a service's deploy.config.json (merged, ${refs} resolved)
├── Provision-Tls.ps1         shared engine: installs nginx+certbot, issues a per-service cert,
│                             installs that service's vhost
├── templates/                token-rendered inputs to the engine
├── remote/provision-tls.sh   STATIC bash that runs ON the box (no values baked in)
├── common/Deploy-Helpers.ps1 shared SHIP+RUN helpers
└── CLAUDE.md  STAGING-PLAN.md  MAINTENANCE-PLAN.md  CONFIG-ARCHITECTURE.md
```

> The **Api** is served behind nginx but its actions land on **DayZ-Server** -
> now a sibling folder in this same repo. That crossing is one-directional and
> declared in its config - see [Api/README.md](Api/README.md).

> `Provision-Tls.ps1` resolves `-Service` in this repo first, then one directory
> up - that second path is how the sibling CryptPad repo provisions its edge from
> here without copying anything. One engine, one `host.config.<env>.env`.

Code utilities (`Get-Stdout`, `Write-CsvLog`) live at `Dev/common/Utils.ps1`, two
levels **above** this repo. Every deploy script dot-sources that shared util from
outside the repo; the repo assumes it stays at `Dev/UbuntuHost/GameServices/`
with `Dev/common/` two levels up. That holds in practice - these scripts only
ever run from the dev machine. They rsync/ssh to the box. The box never clones
this repo, so the path always resolves. A standalone clone *elsewhere* would
need `Utils.ps1` copied in.

---

## Three layers (why there are two deploy scripts per service)

| Layer                   | What it is                                              | How often it runs                      |
| ----------------------- | ------------------------------------------------------- | -------------------------------------- |
| **Host base**           | nginx + certbot installed, ACME webroot, the box set up | once (idempotent - re-runs are no-ops) |
| **Per-service edge**    | that service's nginx vhost + its TLS certificate        | rarely - only when the vhost changes   |
| **Per-service payload** | the actual content/app                                  | often - every update                   |

The host base sets up automatically - whichever service you provision **first**
does it, so no service depends on another having run. Certificates last 90 days.
`certbot.timer` renews them **automatically, forever**. You never run a cert
command on a schedule.

---

## Deploy each service independently

Every command below is **report-only by default** and prints exactly what it
would do. Add the apply flag to actually touch the box.

| Service       | Layer                  | Command                                      | Apply flag |
| ------------- | ---------------------- | -------------------------------------------- | ---------- |
| StaticishSite | edge (vhost + cert)    | `./Provision-Tls.ps1 -Service StaticishSite` | `-Apply`   |
| StaticishSite | payload (site content) | `StaticishSite/deploy/Deploy-Site.ps1`       | `-Push`    |
| Api           | edge (vhost + cert)    | `./Provision-Tls.ps1 -Service Api`           | `-Apply`   |
| Api           | payload (app build)    | `Api/deploy/Deploy-Api.ps1`                  | `-Apply`   |
| ConfigViewer  | edge (vhost + cert)    | `./Provision-Tls.ps1 -Service ConfigViewer`  | `-Apply`   |
| ConfigViewer  | payload (web assets)   | `ConfigViewer/deploy/Deploy-ConfigViewer.ps1`| `-Push`    |

**Edge before payload, always.** `Provision-Tls.ps1` is what installs nginx and creates the
service's webroot (`mkdir` + `chown` to the ssh user). Push a payload to a box that was never
provisioned and rsync fails with **exit 11** — it cannot create `/var/www/<service>` as a
non-root user. Between services the order is free; within one service it is not.

The services share **nothing** but the nginx daemon itself:

- different certs
- different vhost files
- different payload directories on the box (`/var/www/personal-projects`,
  `/opt/api`, …)

Update any one at any time without touching the others.

### First-time go-live (services in any order; edge before payload within each)

```powershell
# 1. Static site (also sets up the host base on first run)
./Provision-Tls.ps1 -Service StaticishSite -Apply
StaticishSite/deploy/Deploy-Site.ps1 -Push

# 2. Each remaining service, edge then payload
./Provision-Tls.ps1 -Service Api -Apply
Api/deploy/Deploy-Api.ps1 -Apply
```

Use `-SkipTls` on `Provision-Tls.ps1` to bring a service up over plain HTTP
*before* its DNS name points at the box (issuing a cert would fail until it
resolves). Re-run without `-SkipTls` once DNS is live.

---

## How a deploy actually runs: render → stage → ship → run

`Provision-Tls.ps1` and the per-service `Deploy-*.ps1` scripts follow the same
shape. Nothing is built as a string inside the script. Nothing lands on the box
that you can't read as a file first:

1. **Render** - the templates are filled in with values from that service's
   `deploy/deploy.config.json` (domain, paths, upload cap, …).
2. **Stage** - the result is written to `<service>/deploy/stage/{tls,app}/` -
   real files. **A dry run stops here - the staged directory *is* the review
   artifact.** Inspect it before applying.
3. **Ship** *(apply only)* - `rsync -az --delete` copies the stage to
   `~/.deploy/<SiteName>/{tls,app}/` on the box.
4. **Run** *(apply only)* - `ssh bash <script>.sh` runs the **static** bash from
   the service's `remote/`, which reads its values only from the shipped
   `provision.env` / `deploy.env`. Full output is tee'd to
   `<service>/logs/<step>_<utc-timestamp>Z.log`.

`Deploy-Site.ps1` is simpler - it builds Hugo and `rsync`s `./public` straight to
the webroot (dry-run by default, `-Push` to apply) - no staging needed.

---

## Where things live (so you never hunt for a value)

- **Box address / SSH / email:** `host.config.<env>.env` at this root - the only
  place, for every service including the out-of-repo ones. Nested services find it
  two levels up automatically; a sibling service passes `-HostConfigDir` instead.
  There is exactly one copy.
- **Per-service settings:** that service's `deploy/deploy.config.json` - the
  **only** place tunables live. The scripts themselves hold no values, only flow.
  Where two files must agree - e.g. an nginx `client_max_body_size` and an app's
  own upload cap - both render from a **single** config value so they cannot drift.
- **nginx vhosts:** each service's `deploy/nginx/*.conf.template`.
- **What ran, and when:** `<service>/logs/` - a `*.csv` audit row per run plus the
  full tee'd output log of each apply.

**Never hand-edit the live box.** Change the template or config here and redeploy.
Every apply regenerates the deployed files from these sources.

---

## Known coupling (one, and it's nginx's nature)

There is a single nginx daemon - that's the one unavoidable shared fact. Any
`nginx -t` / reload validates *all* installed vhosts at once. A broken vhost in
one service can block a reload for the other. That's nginx being nginx - it
cannot be split.

> **Open item:** the `default_server` → 404 catch-all (what happens to
> subdomains no service claims) lives *inside StaticishSite's vhost* right now.
> That makes every other service's fallback routing depend on StaticishSite - it
> shouldn't. The proper home is a host-level catch-all owned by this
> nginx layer (this repo's root templates), belonging to no service. Not yet lifted.
