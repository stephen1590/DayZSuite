# NginxService - the box's web edge

Everything on **servermander.ovh** served *behind nginx* lives in this folder.
nginx + TLS is a **shared requirement** - that makes this the root. Services
that depend on it nest inside. The folder tree *is* the dependency graph:

```text
NginxService/                 ← the shared nginx + Let's Encrypt layer
├── host.config.env           ONE source of truth: Server / SshUser / BaseDomain / AdminEmail (flat KEY=VALUE)
├── host.config.example.env
├── Load-DeployConfig.ps1     loads host.config.env + a service's deploy.config.json (merged, ${refs} resolved)
├── Provision-Tls.ps1         shared engine: installs nginx+certbot, issues a per-service cert,
│                             installs that service's vhost
├── templates/                token-rendered inputs to the engine
│   ├── nginx-bootstrap.conf.template   port-80 ACME-only vhost (pre-certificate)
│   └── provision.env.template          the ONLY bridge of values into the bash step
├── remote/
│   └── provision-tls.sh      STATIC bash that runs ON the box (no values baked in)
│
├── StaticishSite/            ← nested: it is served by nginx
│   └── deploy/ …             Hugo site at the apex  cytonicmushroom.ddns.net
├── CryptPad/                 ← nested: it is served by nginx
│   └── deploy/ …             CryptPad at  pad.  +  pad-sandbox.
└── Api/                      ← nested: it is served by nginx
    └── deploy/ …             command/observability API at  api.  (drives the DayZ server)
```

> The **Api** service is served *here* but its actions land on the **DayZ
> server, which lives outside** this folder. That crossing is one-directional and
> declared in its config - see [Api/README.md](Api/README.md).

> **Rule:** if a service is inside `NginxService/`, it sits behind nginx.
> **DayZ Server** is *not* here - it is UDP, not proxied, and keeps its own
> `host.env`. It lives at `../DayZ Server/`.

Code utilities (`Get-Stdout`, `Write-CsvLog`) live at `Dev/common/Utils.ps1`, one
level **above** this repo. This folder is a single git repo rooted **here**
(branch `main`). DayZ Server is deliberately *not* in it.

Every deploy script dot-sources that shared util from outside the repo. The repo
assumes it stays in place at `Dev/UbuntuHost/NginxService/` with `Dev/common/`
alongside. That holds in practice - these scripts only ever run from the dev
machine. They rsync/ssh to the box. The box never clones this repo, so the path
always resolves. A standalone clone *elsewhere* would need `Utils.ps1` copied in.

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
| CryptPad      | edge (vhost + cert)    | `./Provision-Tls.ps1 -Service CryptPad`      | `-Apply`   |
| CryptPad      | payload (app build)    | `CryptPad/deploy/Deploy-CryptPad.ps1`        | `-Apply`   |
| Api           | edge (vhost + cert)    | `./Provision-Tls.ps1 -Service Api`           | `-Apply`   |
| Api           | payload (app build)    | `Api/deploy/Deploy-Api.ps1`                  | `-Apply`   |

The services share **nothing** but the nginx daemon itself:

- different certs
- different vhost files
- different payload directories on the box (`/var/www/personal-projects`,
  `/opt/cryptpad` + `/var/lib/cryptpad`, `/opt/api`)

Update any one at any time without touching the others.

### First-time go-live (order does not matter)

```powershell
# 1. Static site (also sets up the host base on first run)
./Provision-Tls.ps1 -Service StaticishSite -Apply
StaticishSite/deploy/Deploy-Site.ps1 -Push

# 2. CryptPad
./Provision-Tls.ps1 -Service CryptPad -Apply
CryptPad/deploy/Deploy-CryptPad.ps1 -Apply
```

Use `-SkipTls` on `Provision-Tls.ps1` to bring a service up over plain HTTP
*before* its DNS name points at the box (issuing a cert would fail until it
resolves). Re-run without `-SkipTls` once DNS is live.

---

## How a deploy actually runs: render → stage → ship → run

`Provision-Tls.ps1` and `Deploy-CryptPad.ps1` follow the same shape. Nothing is
built as a string inside the script. Nothing lands on the box that you can't
read as a file first:

1. **Render** - the templates are filled in with values from that service's
   `deploy/deploy.config.json` (domain, paths, upload cap, …).
2. **Stage** - the result is written to `<service>/deploy/stage/{tls,app}/` -
   real files. **A dry run stops here - the staged directory *is* the review
   artifact.** Inspect it before applying.
3. **Ship** *(apply only)* - `rsync -az --delete` copies the stage to
   `~/.deploy/<SiteName>/{tls,app}/` on the box.
4. **Run** *(apply only)* - `ssh bash <script>.sh` runs the **static** bash from
   `remote/` (or `CryptPad/deploy/remote/`), which reads its values only from the
   shipped `provision.env` / `deploy.env`. Full output is tee'd to
   `<service>/logs/<step>_<utc-timestamp>Z.log`.

`Deploy-Site.ps1` is simpler - it builds Hugo and `rsync`s `./public` straight to
the webroot (dry-run by default, `-Push` to apply) - no staging needed.

---

## Where things live (so you never hunt for a value)

- **Box address / SSH / email:** [`host.config.env`](host.config.env) - the only
  place. Every service reads it via `../../host.config.env`.
- **Per-service settings:** that service's `deploy/deploy.config.json` - the
  **only** place tunables live. The scripts themselves hold no values, only flow.
  (CryptPad example: `Ref`, `NodeMajor`, `MaxUploadMb`, `DefaultStorageGb`,
  `AdminKeys` - see [`CryptPad/deploy/deploy.config.json`](CryptPad/deploy/deploy.config.json).)
  Where two files must agree - e.g. nginx `client_max_body_size` and CryptPad's
  `maxUploadSize` - both render from a **single** config value so they cannot drift.
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
> That makes CryptPad's routing depend on StaticishSite - it shouldn't. The
> proper home is a host-level catch-all owned by this `NginxService/` layer,
> belonging to neither service. Not yet lifted.
