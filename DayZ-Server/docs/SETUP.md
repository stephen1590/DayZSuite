# First-time setup

One-time bootstrap for a fresh Linux host. Run everything as the **service user** — never
`sudo` the Steam login, since it caches credentials under `/root`, where the service
account can't see them.

Expected layout: `~/servers/{dayz-server, steamcmd, steamhome}`. The shipped scripts are
self-locating (paths derive from where the script itself lives), so the same files work
unchanged on any host — nothing here needs per-host edits except `host.env`, which
describes the server itself (passwords, Steam account) and stays on that host.

## 1. Dependencies

**PowerShell (`pwsh`) is a hard dependency of the deploy pipeline itself** — the deploy's
on-box leg is `pwsh ./Deploy-DayZServer.ps1 -Local`, and prestart rebuilds every config
artifact with pwsh on EVERY boot. Without it the first deploy dies at
`pwsh: command not found`. PowerShell is MIT-licensed; Microsoft's apt repo is the
first-party package source (version-agnostic via `lsb_release`):

```bash
wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb"
sudo dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb
sudo apt update && sudo apt install -y powershell
pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'   # prove it
```

`rsync` must exist on the box too — the deploy delivers its payload over rsync:

```bash
sudo apt install -y rsync
```

steamcmd is a 32-bit binary:

```bash
sudo apt install -y lib32gcc-s1          # Ubuntu/Debian
sudo pacman -S lib32-gcc-libs            # Arch (multilib repo enabled)
```

## 2. Install steamcmd

steamcmd lives **outside** `dayz-server/` so a save-sync never carries it along:

```bash
mkdir -p ~/servers/steamcmd && cd ~/servers/steamcmd
wget -qO- https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar zxf -
```

`steamclient.so` needs to be where the DayZ server looks for it, or it exits at startup:

```bash
mkdir -p ~/.steam/sdk64
ln -sf ~/servers/steamcmd/linux64/steamclient.so ~/.steam/sdk64/steamclient.so
```

## 3. One-time Steam login (required — anonymous does not work)

DayZ's dedicated server app cannot be downloaded with `+login anonymous`; it needs a
Steam account that owns the game. Isolate the login under its own `HOME` — the desktop
Steam client shares `~/.local/share/Steam` by default and will silently wipe steamcmd's
cached credentials if the two share a home directory:

```bash
HOME=~/servers/steamhome ~/servers/steamcmd/steamcmd.sh +login <your_steam_account> +quit
```

Password + Steam Guard code once; after that, credentials are cached and every later run
is non-interactive. The Steam *client* itself never needs to run on this box — steamcmd
is a standalone downloader that exits when done.

## 4. Configure host.env (on the server)

The repo never lives on the server (single-source model, 2026-07-16). Deploys run from
your dev machine and stage only the runtime payload into
`~/servers/dayz-server/deploy-stage` — a transient subfolder that is wiped and
re-shipped on every deploy, so the box has exactly one DayZ location. The one
persistent per-host file is `host.env`, and it lives WITH the server:

```bash
mkdir -p ~/servers/dayz-server
# the first deploy seeds host.env from host.env.example automatically; to pre-create it:
$EDITOR ~/servers/dayz-server/host.env   # DEPLOY_USER/GROUP/HOME, DEPLOY_STEAM_ACCOUNT,
                                          # DEPLOY_SERVER_PASSWORD, DEPLOY_ADMIN_PASSWORD
```

`host.env` never leaves this host — it's the only place these values live. It describes
*this* server; it has no opinion on how anything reaches it.

## 5. Deploy (from your dev machine)

Deploy needs to know which host to reach — that's *your* machine's config, not the
server's: `cp deployer.env.example deployer.prod.env` (or `deployer.staging.env` for
the local staging VM) next to the script and set `DEPLOY_REMOTE_HOST` — see
[CONFIGURATION.md](CONFIGURATION.md#deploy_remote_host--deploy_remote_user).
Every deploy command below targets STAGING by default; add `-Env prod` to reach the
VPS (../STAGING-PLAN.md).

```bash
./Deploy-DayZServer.ps1          # drift report — on a fresh box everything shows Missing
./Deploy-DayZServer.ps1 -Fix     # renders + installs everything, downloads the DayZ app
                                 # and every enabled mod, starts the service
```

Steps 1–3 above (steamcmd, the one-time Steam login) still have to happen on the server
itself — they can't be done remotely.

`-Fix` auto-runs `update.sh` (steamcmd) whenever the systemd unit references a mod that
isn't on disk yet — on a fresh host that's everything, so the first `-Fix` can take a
while. Follow progress with:

```bash
journalctl -u dayz-server -f    # expect SteamGameServer_Init, then a bind on the game port
```

## 6. Firewall

See [NETWORKING.md](NETWORKING.md) for the full picture; at minimum, an internet-facing
host needs the game and query ports open over UDP:

```bash
sudo ufw allow 2301/udp
sudo ufw allow 27016/udp
```

LAN-only play needs no port forwarding at all.

## Notes on the systemd unit

The systemd unit is the one piece of this setup that's genuinely host-specific — systemd
needs literal paths and a literal `User=`, and there's no way for a system service to
self-locate the way the shell scripts do. You never hand-edit it, though: it ships as a
**template** (`deploy/dayz-server.service`) with `{{DEPLOY_USER}}`/`{{DEPLOY_GROUP}}`/
`{{DEPLOY_HOME}}` placeholders, and `Deploy-DayZServer.ps1` renders it from `host.env`
before installing — the same repo is drift-clean on any host.

Manual one-off render without running Deploy (rarely needed):

```bash
sed -e 's#{{DEPLOY_HOME}}#/home/ubuntu#g' -e 's#{{DEPLOY_USER}}#ubuntu#' -e 's#{{DEPLOY_GROUP}}#ubuntu#' \
  deploy/dayz-server.service | sudo tee /etc/systemd/system/dayz-server.service
```

## Day/night cycle

`serverTimeAcceleration` (X) scales in-game time; `serverNightTimeAcceleration` (Y)
multiplies again during night only. Each portion of the in-game day is divided by the
rate that applies to it, where `D` = in-game daylight hours (12 unless the map/season
says otherwise):

```
day_real_hours   = D / X
night_real_hours = (24 - D) / (X * Y)
full_cycle_real  = day_real_hours + night_real_hours
```

To retarget from a desired `day_real_hours`/`night_real_hours` (D = 12):

```
X = 12 / day_real_hours
Y = day_real_hours / night_real_hours      # Y IS the day:night ratio
```

**Current (`deploy/serverDZ.cfg.template`): X=5, Y=4** → 2h24m daylight + 36m night =
a **3h** full cycle, and Y=4 means daylight runs 4x longer than night.

Both values are web-editable — `server-settings.json` in the config editor has cycle
sliders that show these numbers live. Don't hand-edit `serverDZ.cfg`; it is rendered
at every prestart by `Apply-ServerCfg.ps1`.

> Corrected 2026-07-22. The earlier formula here (`full = 24/X`, `night = 24/(X*Y)`,
> `day = full - night`) charged all 24 in-game hours at the day rate and then subtracted
> night out of the result, so it overstated the cycle — and at Y=1 it reported zero
> daylight instead of an even split.

## Updating the server (patch days)

Steam sessions are single-active-per-account, so `update.sh` is **not** run automatically
on every restart — it would kick any other live session of the Steam account (desktop
client, or the account itself in-game) on every service restart. Run it by hand only when
a game patch actually needs picking up:

```bash
bash ~/servers/dayz-server/update.sh    # kicks any other live session — run while not playing
sudo systemctl restart dayz-server
```

`Deploy-DayZServer.ps1 -Fix` also auto-runs it, but only when a mod referenced by the unit
is actually missing on disk — a normal deploy with everything already present never
touches steamcmd.

## Map switching

Edit `DAYZ_MISSION=` in `~/servers/dayz-server/map.env`, then
`sudo systemctl restart dayz-server`. Character saves follow the server across a map
switch (positions are raw per-map coordinates, so teleport players to sane spots after
their first login on the new map); world state — bases, vehicles — stays per-map.
`map.env` and `.last-map` are runtime state, not part of the deploy payload — `map.env`
is SEEDED from the deployed `map.env.example` when missing (fresh box), and `prestart.sh`
re-creates it the same way if it's ever deleted. `map.env.example` is the one home of the
default mission; edits to `map.env` on the box are never overwritten by a deploy.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Exec format error` / `203/EXEC` | Missing shebang (or CRLF/BOM) in a script systemd executes | Confirm `#!/bin/bash` is the literal first line: `head -1 file \| cat -A` |
| `Cached credentials not found` → `Invalid Password` | No cached Steam login for the service user; anonymous login isn't supported | One-time interactive `steamcmd +login <account> +quit` as that user |
| Server exits over `steamclient.so` | Steam client lib not found | `mkdir -p ~/.steam/sdk64 && ln -sf ~/servers/steamcmd/linux64/steamclient.so ~/.steam/sdk64/` |
| Listed in the browser but unjoinable | The listed address isn't reachable from where you're connecting (e.g. a VPN exit IP) | Don't host behind a VPN with a strict kill-switch/NAT; LAN players should direct-connect to the LAN IP |
| Service dies mid-update on patch day | Default systemd start timeout is shorter than a large steamcmd download | `TimeoutStartSec=900` is already set in the shipped unit template |
