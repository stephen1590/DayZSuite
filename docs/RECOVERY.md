# Recovery — rebuild the server from this repo

The promise: if the box dies, a fresh one is **one deploy away** from the full config
state. The repo carries committed mirrors of everything the box owned; `-Fix` seeds them
onto any box that lacks them. No config is hand-restored file by file.

## The short version

```bash
# 0. New box reachable over ssh, deploy user with passwordless sudo (docs/SETUP.md)
cp host.env.example host.env && $EDITOR host.env        # passwords + Steam account
$EDITOR deployer.env                                     # point at the new host

./Deploy-DayZServer.ps1          # report first - expect Missing everywhere
./Deploy-DayZServer.ps1 -Fix     # ships code, seeds all config mirrors, downloads mods, starts
./Confirm-LiveConfigs.ps1           # prove it: zero-MISS, valid artifacts, unit active
```

That is the whole config restore. The seeded `config-overrides.json` mirror carries every
web edit ever pulled; the `config-defaults/` mirror carries the frozen baselines; prestart
rebuilds the live files from them on first boot exactly as the old box did.

## Why this works

Every config file is box-owned with a committed repo mirror (see
[CONFIGURATION.md](CONFIGURATION.md), "Who owns what"). The deploy never overwrites a
live config - but on a box that has none, the mirrors ARE the restore. The freshness of
that restore equals the freshness of the last pull, which is why the pulls run on every
deploy and why `./Pull-Configs.ps1 -Execute` + a commit after web-editing sessions
matters: **git history is the backup.**

## What the repo does NOT carry (restore by hand or accept loss)

- **Player/world state** - `mpmissions/<mission>/storage_1/` (players.db, world
  persistence). The box keeps rolling tarballs in `backups/<mission>/` (newest 10), but
  those die with the box. For real insurance, copy them off-box periodically
  (`Pull-DayZServer.ps1` grabs them, or a plain rsync/cron).
- **`host.env`** - secrets, deliberately never in git. Keep a copy in your password
  manager.
- **Box-only setup** - steamcmd's one-time interactive Steam login, `gai.conf` IPv4 fix,
  battleye `beserver_x64.cfg` (RCon password), OVH firewall rules. All in
  [SETUP.md](SETUP.md) / [NETWORKING.md](NETWORKING.md).
- **Workshop mod content** - not carried, not needed: `-Fix` re-downloads every enabled
  mod from `mods.conf` via steamcmd.

## Partial recovery — one file went bad on the box

- A config file or baseline was deleted: just redeploy. Seed-if-missing restores it from
  the mirror; prestart rebuilds the live file.
- The overrides document got corrupted on the box: restore it from the repo mirror by
  deleting the box copy, then redeploy (the seed ships the mirror back), then restart.
- A web-editing session went wrong: the box snapshots every override write
  (`.overrides-versions/`, keep 10) - roll back there, or use git history on the mirror.
