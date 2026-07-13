# DayZ Dedicated Server — Linux Deployment Toolkit

PowerShell + bash tooling for running a modded DayZ dedicated server on Linux as
config-as-code: a read-only-by-default deploy script that detects drift between this repo
and the live install, a single mod registry that drives load order and downloads, and a
field-level config-override system that survives mod/game updates.

## Features

- **Drift-checked deploy** (`Deploy-DayZServer.ps1`) — reports what differs between this
  repo and the live server; nothing is written until you pass `-Fix`.
- **One mod registry** (`deploy/mods.conf`) — enable/disable/reorder mods in one file; it
  drives the systemd unit's `-mod=` line, steamcmd downloads, and drift checks together.
- **Field-level config overrides** (`config-overrides.json`) — patch individual settings
  into mod/vanilla config files by name, so a mod update rewriting its baseline doesn't
  wipe your tuning.
- **VPP-driven AI bandit spawns** — capture spawn points in-game with admin tooling, sync
  them into the repo, and a builder composes each map's bandit config at every boot.
- **Automatic map-switch handling** — character saves follow the server when you switch
  missions; world state stays per-map.
- **Rolling save backups + daily log archiving**, both with automatic retention.
- **Secrets stay out of the repo** — everything the server itself needs (passwords, Steam
  account) lives in a local, gitignored `host.env` on that host. Which host to deploy *to*
  is separate, dev-machine-local config (`deployer.env`) — the two are never conflated.

## Prerequisites

- A Linux host (Ubuntu and Arch both work) with 32-bit libs for steamcmd:
  `lib32gcc-s1` (Ubuntu/Debian) or `lib32-gcc-libs` (Arch, multilib enabled)
- [PowerShell 7+](https://github.com/PowerShell/PowerShell) (`pwsh`) and `bash`
- A Steam account that **owns DayZ** — steamcmd cannot download the dedicated server app
  anonymously
- `rsync` and `ssh` if deploying to a remote host (the default mode)

## Quick start

```bash
git clone <this-repo-url>
cd <this-repo>
cp host.env.example host.env
$EDITOR host.env   # set DEPLOY_STEAM_ACCOUNT and the two passwords

cp deployer.env.example deployer.env
$EDITOR deployer.env   # set DEPLOY_REMOTE_HOST — which box to deploy TO. Dev-machine-local,
                        # gitignored, never host.env content (see docs/CONFIGURATION.md)

./Deploy-DayZServer.ps1          # dry-run: reports drift, changes nothing
./Deploy-DayZServer.ps1 -Fix     # deploys: renders + installs files, starts the service
```

For a brand-new host with no server files yet, see [docs/SETUP.md](docs/SETUP.md) —
`-Fix` will download the DayZ app and every enabled mod automatically, but steamcmd
needs a one-time interactive login first.

## Repository layout

| Path | Purpose |
| --- | --- |
| `deploy/` | The deployable payload — source of truth for the live server (unit templates, `serverDZ.cfg`, mod registry, admin permissions, AI bandit configs). |
| `Deploy-DayZServer.ps1` | Read-only by default; reports drift. `-Fix` renders per-host templates from `host.env` and installs everything, with a player-online guard before any restart. |
| `host.env` / `host.env.example` | Secrets and settings for the server this file lives on (passwords, Steam account). `host.env` is gitignored — copy the example and fill it in. |
| `deployer.env` / `deployer.env.example` | Dev-machine-local config for whoever is deploying — which host to reach (`DEPLOY_REMOTE_HOST`). Gitignored, never rsynced to the server. |
| `Pull-DayZServer.ps1` | Pulls server saves/config down to a local machine over rsync/ssh — an off-box backup, or to work against real data locally. |
| `Sync-VPPCoordinates.ps1` | Pulls admin-captured spawn-point bookmarks off the live server and normalizes them for the AI bandit generator. |
| `Build-AIBandits.ps1` | Composes each map's bandit spawn config from shared templates + per-map placements. Runs automatically on every server boot. |
| `Apply-ConfigOverrides.ps1` | Applies `config-overrides.json`'s field-level patches to live config files. Runs automatically on every server boot. |
| `_DZSync.ps1` | Shared rsync/host-resolution helpers for the Pull/Sync scripts. |

## Mods

See [docs/MODS.md](docs/MODS.md) for the full enabled/disabled list with Workshop links —
`deploy/mods.conf` is the actual source of truth. Clients must subscribe to and enable
every enabled mod, in the same order, to join.

## Documentation

- [docs/SETUP.md](docs/SETUP.md) — first-time install, steamcmd, systemd, ports, day/night cycle
- [docs/MODS.md](docs/MODS.md) — full mod list and load order
- [docs/NETWORKING.md](docs/NETWORKING.md) — firewall rules and port requirements
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) — `host.env` vs `deployer.env`, config
  overrides, AI bandit tuning, map switching, log archiving

## Config file reference

- [dzconfig.com/wiki](https://dzconfig.com/wiki) — `serverDZ.cfg`, `types.xml`,
  `events.xml`, `cfggameplay.json`, log format reference.
- [BI wiki: Hosting a Linux Server](https://community.bistudio.com/wiki/DayZ:Hosting_a_Linux_Server)
  — the original setup guide this tooling builds on.
