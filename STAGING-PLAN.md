# Staging Environment — Plan (local VM topology)

> Permanent staging mirror as a **local QEMU/KVM Ubuntu VM** on the dev machine. Purpose: every change is reviewable on staging **before** it reaches prod — starting with the current stakeholder approval. Supersedes the earlier second-VPS draft (owner call 2026-07-21: isolation + zero cost over remote access). Config model: `CONFIG-ARCHITECTURE.md`. VM tooling: `staging/New-StagingVm.ps1` + `staging/staging.env`.

**Status 2026-07-21: phases 0 and 1 DONE. VM procured + booted (Ubuntu 26.04, `ssh staging-vm` works). Env selector + guards built and PROVEN: bare deploys resolve staging-vm and skip mirror pulls (gate 24/0); prod `-Fix` refused a dirty tree pre-network (exit 5). Next: phase 2 — build the box via SETUP.md (VM lacks pwsh, as a fresh box should).**

---

## Scope (owner call 2026-07-21)

Staging exists to test **the DayZ server and its dependencies**. Nothing else gets deployed there.

| In scope | Why |
|---|---|
| `DayZ-Server` | the system under test |
| `Api` | drives the game server through `sudo dayz-ctl`; the config writer's backend |
| `ConfigViewer` | the web UI the stakeholder reviews changes in |
| nginx (via `Provision-Tls -SkipTls`) | its remote script installs nginx and lays down the two vhosts above |

**Out of scope — do not deploy to staging:** `CryptPad` (unrelated to DayZ — as of 2026-07-21 it
is out of scope *by structure*, not by exception: it was split into its own sibling repo
`UbuntuHost/CryptPad/` for exactly this reason. Its broken deploy config was fixed in the same
change — it was a truncated copy missing the closing brace *and* the admin signing key),
`StaticishSite`
(a Hugo site, no DayZ relationship), `Monitoring`/Grafana (telemetry, not under review).

Consequence for the fresh-box order: prod is `Site → DayZ → Api → ConfigViewer`; **staging is
`DayZ → Api → ConfigViewer`**, because the only reason Site went first was its ownership of the
nginx `default_server` catch-all.

## The parity contract

Reliability comes from **one code path, two targets** — staging has no code of its own.

**Identical by construction (not by discipline):**

- **Deploy scripts** — the same `Deploy-*.ps1` files, zero environment forks. An env selector picks the config set; the VM is reached via the `staging-vm` ssh alias, so every script sees just another host. The alias is the SINGLE AUTHORITY for the VM's address: `host.config.staging.env` sets no `SshPort`, because an explicit `ssh -p` overrides a Host alias's `Port` (that bug pointed a deploy at the dev machine's own sshd on 2026-07-21).
- **Box shape** — separate host = nothing renamed. Same unit names, dirs, ports, payloads, registry, seed-if-missing, overrides pipeline, prestart engines, and the same Test-Configs gate.
- **Setup procedure** — staging is built by following `DayZ-Server/docs/SETUP.md` + the in-scope deploy order (`DayZ → Api → ConfigViewer`) verbatim. A gap found on the VM = fix the docs first (Code → Document → Deploy). This doubles as the disaster-recovery proof for the DayZ half. Three gaps found so far: missing pwsh/rsync deps, the fresh-box `map.env` boot deadlock, and the hardcoded `ssh -p 22` that overrode the VM's ssh alias.
- **Secrets mechanism** — generated on each box the same way; staging holds staging values only. The stakeholder never touches a prod credential. **Currently violated:** the VM's `host.env` was filled with prod's `DEPLOY_SERVER_PASSWORD`/`DEPLOY_ADMIN_PASSWORD`, so staging's `serverDZ.cfg` carries prod credentials and prod's `hostname` (`[US-PNW] Commie Lobby (PVE)`). Give staging its own passwords and a distinct hostname before the stakeholder gets access.

**Enumerated deviations — each pinned to ONE place:**

| Deviation | Prod | Staging VM | Pinned in |
|---|---|---|---|
| TLS/DNS | HTTP-01 certs on public DDNS | http-only (`Provision-Tls -SkipTls` bootstrap vhost; certbot refused on staging) + `BaseDomain=localhost` (`*.localhost` = browser secure context, Web Crypto works) | `host.config.staging.env` + the Provision-Tls staging guard |
| Mirror-pull + auto-commit | runs (prod owns the repo mirror) | **skipped** — staging is never pulled back | `Deploy-DayZServer.ps1` env guard; pull family prod-pinned in `_DZSync.ps1` |
| Deploy source | reviewed commit on clean `main` only (`-Fix` refuses otherwise) | working tree deploys freely — that's what review is for | `Deploy-DayZServer.ps1` prod guard |
| Ingress | OVH edge firewall, public UDP | slirp hostfwd, all binds 127.0.0.1 (stricter than prod) | `staging/New-StagingVm.ps1` |
| Services present | all six (Site, CryptPad, DayZ, Api, ConfigViewer, Monitoring - CryptPad from its own repo since 2026-07-21) | DayZ + Api + ConfigViewer only | the Scope table above |
| nginx catch-all | StaticishSite's vhost owns `default_server` | none — Site is out of scope and `provision-tls.sh` removes nginx's stock default site, so an unknown name falls through to the first-loaded vhost instead of a Hugo 404 | the Scope table above |
| Hardware | bare VPS | KVM VM, slower | — (review pacing only) |
| gai.conf IPv6 fix | required (OVH quirk) | likely unneeded (slirp) — SETUP notes it as conditional | `docs/SETUP.md` |

**The audit rule:** every `if ($Env …)` branch in deploy code must map to a row in this table. A grep that finds an env conditional not listed here is a red finding. Deviations cannot accumulate silently.

## Deploy-layer changes (phase 1 — DONE 2026-07-21)

1. **Env selector — built.** Every deploy script takes `-Env` (ValidateSet staging|prod), **default staging**. Web services: `Import-DeployConfig -Env` picks `host.config.<env>.env` (threaded through Deploy-Site/CryptPad/ConfigViewer/Api/Monitoring + Provision-Tls; `$cfg.Env` exposed). DayZ: `Deploy-DayZServer -Env` picks `deployer.<env>.env`. Bare legacy names (`host.config.env`, `deployer.env`) still read as PROD with a rename nudge.
2. **TRAP — mirror-pull is prod-only — built.** Deploy-DayZServer skips the three pulls + the backup auto-commit unless env == prod (prints the skip). The standalone pull family (`Pull-Configs`, `Sync-*`, `Pull-DayZServer`) is prod-PINNED via `Resolve-DZDeployerEnv`'s prod default — deliberately no `-Env` switch there.
3. **Prod deploy guard — built.** `-Env prod -Fix` refuses a dirty tree or non-main branch (exit 5) before anything touches the network. Staging deploys the working tree freely.
4. `Confirm-LiveConfigs -Env` (default staging) — built. Provision-Tls refuses staging without `-SkipTls` (staging is http-only; the `-SkipTls` bootstrap vhost IS the staging vhost).

## VM procurement (phase 0 — tooling done)

`staging/New-StagingVm.ps1` — report-only default; `-Fix` procures (SHA256-verified Ubuntu cloud image, cloud-init seed, qcow2 overlay over a pristine base, ssh alias); `-Start` boots; `-Wipe -Fix` resets staging by deleting one file. Config via `staging/staging.env` (deployer.env conventions): VM library dir on the big mount, disk/mem/cpu/version overrides. Ports (all 127.0.0.1): ssh 2222, http 8080, https 8443, game 2302-2306/udp, query 27016/udp, RCon 2310/udp.

- Ubuntu version: **26.04** (matches prod; script default).
- Steam login is interactive once, at DayZ install (phase 2).

## Config parity + promote

- Fresh staging seeds from the repo mirror (registry rows + `config-defaults/` + `config-mirror/`) = prod-shaped as of the last prod pull. Refresh = `-Wipe -Fix` + redeploy.
- **Corrected 2026-07-21.** This line previously claimed parity the code did not deliver. Live mission config (`mpmissions/*/expansion/settings/*.json`) had NO seed row and was in NO pull, so it existed only on prod: staging could not reproduce it, and enoch's loss of 17 patrols went unseen for 5 days. Fixed by the registry `"mirror":"live"` tag (Pull-Configs pulls, the deploy seeds). **Still unreproducible on staging: `battleye/beserver_x64.cfg`** - staging therefore has no RCon at all. Tracked in `MAINTENANCE-PLAN.md` P0b along with the coverage check that would have caught both.
- Review edits happen on staging (full-scope access — it's disposable).
- **Promote = re-apply on prod** (ConfigViewer for config, `-Env prod` deploy from clean main for code). Never rsync config staging → prod.

## Stakeholder access — OPEN DECISION

Everything binds to 127.0.0.1 on the dev machine. Isolation is total; remote access is not free:

- **Local-first review** (default): screen share or in person; browse `http://configs.localhost:8080`; join the game from the dev machine.

  **Joining the staging server from the dev machine — CONNECT MANUALLY** (verified working
  2026-07-21). The game port is **2301** (not the DayZ default 2302); Steam query is 27016; both
  forwarded to 127.0.0.1. **No server browser will ever list it**, and that is by design, not a
  fault:

  - *Community browser* — sourced from the Steam master list, which needs a public IP. The VM has none.
  - *LAN tab* — LAN discovery is broadcast-based, and slirp user-networking does not carry
    broadcasts between the guest's 10.0.2.0/24 and the host's LAN.

  Direct/manual connect to `127.0.0.1:2301` is the supported path. The client must load the same
  mod set as the server (28 mods), and `serverDZ.cfg`'s password applies. Symptom check: if the
  server's RPT shows `Player connect enabled` but no connection lines, the client never reached
  it — that is a discovery problem, not a server problem.

  **Consequence for stakeholder access:** this only works from the dev machine itself. A
  stakeholder on any other PC gets nothing over slirp — no browser entry, no direct connect —
  which forces the LAN-binds/WireGuard decision below if they are to play rather than watch.
- **Remote game access** (if required): open the UDP hostfwds to the LAN, or WireGuard to the stakeholder. A decision + small script change, not a default.
- Web-only remote review is cheap: an ssh tunnel to their machine.

Before the first session either way: prove one prod rollback (`override-rollback` + git) so approval comes with a working undo.

## Workflow (once built)

1. Prod stays frozen until the stakeholder signs off on the process.
2. Change lands on staging (working tree/branch) → stakeholder reviews there.
3. Approved → commit to main → `-Env prod` deploy (guards enforce clean main) → `Confirm-LiveConfigs`.
4. Staging re-seeded from the prod mirror periodically to stay honest.

## Phases

| Phase | What | State |
|---|---|---|
| 0 | VM procurement | **done 2026-07-21** — VM booted, Ubuntu 26.04, `ssh staging-vm` verified |
| 1 | Env selector + prod-only mirror-pull guard + prod clean-main guard | **done 2026-07-21** — built + proven (see Deploy-layer changes above) |
| 2 | Build the box via SETUP.md (DayZ → Api → ConfigViewer); doubles as the disaster-recovery doc proof | **in progress** — DayZ server running on Chernarus; nginx + ConfigViewer live (`http://configs.localhost:8080` → HTTP 200). Remaining: `Provision-Tls -Service Api -SkipTls -Apply` then `Deploy-Api.ps1 -Apply`. Four doc/code gaps found and fixed so far (pwsh+rsync deps, `map.env` boot deadlock, hardcoded `ssh -p 22`, undocumented edge-before-payload order) |
| 3 | Seed configs, stakeholder access, rollback proof | after 2 |
| 4 | First review session → unfreeze prod behind the new workflow | — |
| later | Promote-Configs.ps1, parity-audit grep in the gate, staging Grafana | as needed |

## Open decisions

1. ~~Prod Ubuntu version~~ — resolved: **26.04** (owner-confirmed; script default matches).
2. Stakeholder: local review sessions, or remote access needed (LAN binds / WireGuard)?
3. Written change log per review, or staging walkthrough only? (Cheap: generate from git log.)
