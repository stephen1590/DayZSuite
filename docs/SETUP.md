# First-time setup

One-time bootstrap for a fresh Linux host. Run everything as the **service user** — never
`sudo` the Steam login, since it caches credentials under `/root`, where the service
account can't see them.

Expected layout: `~/servers/{dayz-server, steamcmd, steamhome}`. The shipped scripts are
self-locating (paths derive from where the script itself lives), so the same files work
unchanged on any host — nothing here needs per-host edits except `host.env`, which
describes the server itself (passwords, Steam account) and stays on that host.

## 1. Dependencies

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

## 4. Clone this repo and configure

```bash
git clone <this-repo-url> ~/dayz-tooling && cd ~/dayz-tooling
cp host.env.example host.env
$EDITOR host.env    # DEPLOY_USER/GROUP/HOME, DEPLOY_STEAM_ACCOUNT,
                     # DEPLOY_SERVER_PASSWORD, DEPLOY_ADMIN_PASSWORD
```

`host.env` is gitignored and never leaves this host — it's the only place these values
live. It describes *this* server; it has no opinion on how anything reaches it.

## 5. Deploy

You're running these commands directly on the host you just set up, so use `-Local` —
it applies the payload to this machine instead of trying to rsync/ssh somewhere:

```bash
pwsh ./Deploy-DayZServer.ps1 -Local          # drift report — should show everything Missing
pwsh ./Deploy-DayZServer.ps1 -Local -Fix     # renders + installs everything, downloads the
                                              # DayZ app and every enabled mod, starts the service
```

**Deploying from a separate control machine instead?** You don't need to clone this repo
onto the server by hand at all — `Deploy-DayZServer.ps1` without `-Local` pushes the
tooling over rsync/ssh and re-runs itself there automatically (auto-seeding the server's
`host.env` from the example on first run — you'd still fill in the secrets afterward).
It just needs to know which host to reach, which is *your* machine's config, not the
server's: `cp deployer.env.example deployer.env` on your control machine and set
`DEPLOY_REMOTE_HOST` there — see
[CONFIGURATION.md](CONFIGURATION.md#deploy_remote_host--deploy_remote_user). Steps 1–3
above (steamcmd, the one-time Steam login) still have to happen on the server itself
either way — they can't be done remotely.

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

`serverDZ.cfg`'s `serverTimeAcceleration` (X) scales the full 24 in-game-hour cycle;
`serverNightTimeAcceleration` (Y) applies an *additional* multiplier during night only:

```
full_cycle_real_hours = 24 / X
night_real_hours      = 24 / (X * Y)
day_real_hours        = full_cycle_real_hours - night_real_hours
```

To retarget from a desired `day_real_hours`/`night_real_hours`:

```
X = 24 / (day + night)
Y = 24 / (X * night)
```

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
`map.env` and `.last-map` are runtime state, not part of the deploy payload.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Exec format error` / `203/EXEC` | Missing shebang (or CRLF/BOM) in a script systemd executes | Confirm `#!/bin/bash` is the literal first line: `head -1 file \| cat -A` |
| `Cached credentials not found` → `Invalid Password` | No cached Steam login for the service user; anonymous login isn't supported | One-time interactive `steamcmd +login <account> +quit` as that user |
| Server exits over `steamclient.so` | Steam client lib not found | `mkdir -p ~/.steam/sdk64 && ln -sf ~/servers/steamcmd/linux64/steamclient.so ~/.steam/sdk64/` |
| Listed in the browser but unjoinable | The listed address isn't reachable from where you're connecting (e.g. a VPN exit IP) | Don't host behind a VPN with a strict kill-switch/NAT; LAN players should direct-connect to the LAN IP |
| Service dies mid-update on patch day | Default systemd start timeout is shorter than a large steamcmd download | `TimeoutStartSec=900` is already set in the shipped unit template |
