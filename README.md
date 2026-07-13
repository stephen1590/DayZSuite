# DayZ Dedicated Server on Linux — Setup Guide & Postmortem

**Current deployment (since 2026-07-05):** OVH VPS `servermander.ovh` (Ubuntu), user
`ubuntu`, install `/home/ubuntu/servers/dayz-server`, systemd unit `dayz-server.service`,
game port **2301**, Steam query port **27016**. Players join `servermander.ovh:2301`.
**There is no local install** — the dev box (meshroom) holds only this tooling folder
(retired as a server 2026-07-06); deploys run remotely via `Deploy-DayZServer.ps1`.
Earlier hosts: meshroom LAN (2026-07-03→06) and `tv` behind ProtonVPN (abandoned, see postmortem).

References:
- https://dzconfig.com/wiki — config file reference (serverDZ.cfg, types.xml,
  events.xml, cfggameplay.json, log analysis). Preferred source for config tuning;
  accessible without Cloudflare blocks.
- https://community.bistudio.com/wiki/DayZ:Hosting_a_Linux_Server — original setup
  guide (Cloudflare-gated; open in a browser).

## Folder layout (deployable setup)

- `deploy/` — the deployable payload, source of truth for the live server:
  `update.sh`, `prestart.sh`, the `dayz-server.service` unit template, `serverDZ.cfg`,
  `messages.xml` (native scheduled restart + notices), `dayz-rcon.ps1`, the staged
  `profiles/VPPAdminTools/.../SuperAdmins.txt`, and the tuned
  `profiles/AI_Bandits/{DynamicAIB,StaticAIB}.json` (the mod's runtime `AIB.log`
  stays live-only).
- `Deploy-DayZServer.ps1` — **read-only by default**: reports drift between `deploy/`
  and the live locations (server dir + systemd units). `-Fix` runs the full chain:
  **player guard** (queries the live count over RCon and **refuses to deploy if anyone
  is online**, or if the server is up but the count can't be verified; `-Force`
  overrides) → sync files (units **rendered per-host** from `host.env`) →
  **auto-runs `update.sh` if the unit references mods missing on disk** (steamcmd —
  kicks any live Steam session of the server account; update failure skips the
  restart) → `daemon-reload` → restart → arm `dayz-restart.timer`. `-NoRestart` =
  files-only (skips guard, update, restart, timer). Transcript + CSV in `./logs/`.
  **Remote by default:** a bare run *is* the deploy — syncs this tooling + `common/` to
  the VPS (`ubuntu@servermander.ovh:dayz-tooling`) and runs the apply step there over
  ssh. `-Local` applies to the machine it runs on instead (the ssh leg uses it on the
  VPS; there is no local server install on the dev box anymore).
- `host.env` — per-host deploy values (`DEPLOY_USER`/`DEPLOY_GROUP`/`DEPLOY_HOME`) that
  Deploy renders the units with. Per-host, **not** in the payload (like `map.env`); copy
  `host.env.example` to `host.env` on each host. Absent → built-in ubuntu (VPS) defaults.
- `Push-DayZServer.ps1` / `Pull-DayZServer.ps1` — rsync/ssh save/state movers
  (`ubuntu@servermander.ovh` by default; dry-run by default, `-Execute` to transfer).
  **The local-mirror model is retired** (no local install since 2026-07-06) — config
  flows only via Deploy. What remains useful: **Pull** as the **off-box save backup**
  (pulls `mpmissions` saves + configs down to the dev box; run it occasionally so a
  VPS disk loss can't take the world with it). **Push** was the one-time migration
  seed (`-Force`) and a deliberate save-restore tool — rarely needed now.
- `_DZSync.ps1` — shared helper both scripts dot-source: the exclude categories
  (logs / saves / heavy rebuildables) and the rsync runner live here **once**, so
  push and pull can't drift (cf. postmortem #1).

---

## First-time install (new host)

One-time bootstrap for a fresh box, run as the **service user** — never `sudo` the
Steam login (it caches under `/root`, where the service can't see it). Layout is
`~/servers/{dayz-server, steamcmd, steamhome}`. `update.sh` and `prestart.sh` are
**self-locating**, so the same files work on any host with no edits.

```bash
# 1. 32-bit libs for steamcmd
sudo apt install -y lib32gcc-s1          # Ubuntu/Debian  ·  Arch: sudo pacman -S lib32-gcc-libs

# 2. steamcmd — lives OUTSIDE dayz-server/, so a Push never carries it; install fresh
mkdir -p ~/servers/steamcmd && cd ~/servers/steamcmd
wget -qO- https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar zxf -

# 3. steamclient.so where the server looks for it (or it exits at startup)
mkdir -p ~/.steam/sdk64
ln -sf ~/servers/steamcmd/linux64/steamclient.so ~/.steam/sdk64/steamclient.so

# 4. One-time Steam login — account that OWNS DayZ (anonymous fails), Steam Guard once.
#    Isolated HOME so the desktop Steam client can't clobber the cache (postmortem #5).
HOME=~/servers/steamhome ~/servers/steamcmd/steamcmd.sh +login robotsd3stroyjpn +quit

# 5. Server files. Fresh box: update.sh downloads app 223350 + mods. Migration target:
#    files already present from Push-DayZServer.ps1 -Force, and update.sh just validates.
bash ~/servers/dayz-server/update.sh

# 6. Configure serverDZ.cfg (hostname, passwords, maxPlayers, steamQueryPort=27016).

# 7. Install + start the systemd unit (see note — one host-specific file), then:
sudo systemctl daemon-reload && sudo systemctl enable --now dayz-server
journalctl -u dayz-server -f             # expect SteamGameServer_Init, bind on 2301 + 27016

# 8. Ports (UDP). LAN needs none; an internet VPS does:
sudo ufw allow 2301/udp && sudo ufw allow 27016/udp
```

**The systemd units are the one host-specific piece** — systemd needs literal paths and
a literal `User=` (and `%h` is `/root` for system services, so they can't self-locate
like the scripts) — but you **no longer hand-edit them**. Deploy renders them per-host.
On a new host: `git clone` this folder, copy `host.env.example` → `host.env` and set
`DEPLOY_USER`/`DEPLOY_GROUP`/`DEPLOY_HOME`, then let Deploy install the rendered units,
scripts, and configs in one shot:

```bash
cp host.env.example host.env && $EDITOR host.env      # set user/group/home for THIS host
pwsh ./Deploy-DayZServer.ps1                          # drift report — should be all Missing/InSync
pwsh ./Deploy-DayZServer.ps1 -Fix                     # renders units for this host, installs, restarts
```
(A Push doesn't carry the units — they live in `/etc`, not under `dayz-server/` — so
Deploy is how they get there. Pure-manual one-off without Deploy: `sed -e 's#{{DEPLOY_HOME}}#/home/ubuntu#g' -e 's#{{DEPLOY_USER}}#ubuntu#' -e 's#{{DEPLOY_GROUP}}#ubuntu#' deploy/dayz-server.service | sudo tee /etc/systemd/system/dayz-server.service`.)

---

## Postmortem — what broke, what worked, and why (2026-07-03)

### 1. `Failed to execute update.sh: Exec format error` (status=203/EXEC)

**Why:** `update.sh` had no `#!/bin/bash` shebang — the steamcmd command was the
first line. An interactive shell forgives that (it falls back to running the file
with sh); **systemd does not** — the kernel's `execve` needs the shebang to know
the interpreter, so systemd fails at the EXEC step.

**Trap that prolonged it:** two files named `update.sh` existed (the template in
this folder and the live one in `~/servers/dayz-server/`). The fix was applied to
the template while systemd kept executing the unfixed live file. Always verify the
exact path from the journal line: `head -1 <that path>`.

**What worked:** `#!/bin/bash` as line 1 of `/home/meshy/servers/dayz-server/update.sh`.

### 2. `Cached credentials not found` → `ERROR (Invalid Password)` (status=5/NOTINSTALLED)

**Why (two facts compound):**
- **DayZ's server app 223350 cannot be downloaded with `+login anonymous`** —
  unusual among dedicated servers, it requires a Steam account that *owns DayZ*.
- steamcmd on meshroom had never logged in as that account — the server files were
  copied over from `tv`, so no credential cache existed here. Under systemd there
  is no terminal, so steamcmd's password prompt read nothing → "Invalid Password".

**What worked:** a one-time **interactive** login as the service user (no sudo —
that would cache under /root):

```bash
~/servers/steamcmd/steamcmd.sh +login robotsd3stroyjpn +quit
```

(password + Steam Guard code once; credentials cached in `~/Steam`). After that,
the unmodified `ExecStartPre` succeeded — no `Environment=HOME=` override was
needed; systemd provided the correct home for `User=meshy` on this version.

### 3. Non-issue: `-mod=1559212036;1564026768;` with missing mod directories

Expected to block startup — it doesn't. The server logs warnings and runs vanilla.
Still worth removing from `ExecStart` until mods are actually installed (workshop
download with the owning account + `@mod` symlinks + `keys/*.bikey`; joining
clients must run the same mods).

### 4. Abandoned: hosting behind ProtonVPN (host `tv`)

Why it fought back on every front: the Steam browser listed the server at the
**VPN exit IP** (unjoinable — Proton drops unsolicited inbound); the kill-switch
firewall ate direct LAN joins; and Proton port forwarding offers only a **single,
randomly-numbered** port (can't be 2301, and no second port for query 27016).
Conclusion: host on a machine without a VPN. LAN play needs no port forwarding at all.

### 5. Desktop Steam client clobbers steamcmd's cached login

**Why:** steamcmd and the desktop Steam client share `~/.local/share/Steam` by
default. Whenever the client runs (it lives on meshroom too), it rewrites
`config.vdf` and wipes steamcmd's cached credentials — the service then fails with
`Cached credentials not found` again on its next update, even though the login
"worked yesterday".

**What worked:** give the server's steamcmd an isolated `HOME`
(`/home/meshy/servers/steamhome`), exported inside `update.sh`. The one-time
interactive login must use the same HOME:

```bash
HOME=/home/meshy/servers/steamhome /home/meshy/servers/steamcmd/steamcmd.sh +login robotsd3stroyjpn +quit
```

After that, desktop Steam and the server updater never touch each other's state.

### 6. Every service restart killed the Steam session (logged out desktop/in-game)

**Why:** Steam permits **one active session per account** — arbitration happens on
Valve's side, so the isolated HOME can't help. The unit's `ExecStartPre` ran
steamcmd on every start, logging in as `robotsd3stroyjpn`; if the same account was
signed in on the desktop (or in DayZ itself), Valve terminated that session.

**What worked:** removed `ExecStartPre` from the unit — restarts no longer touch
Steam at all. Updates are now **manual, on patch days only** (DayZ patches every
few months; a version mismatch will show up as clients failing to join):

```bash
bash ~/servers/dayz-server/update.sh   # kicks any live session of the account — run while not playing
sudo systemctl restart dayz-server
```

The canonical alternative — a dedicated Steam account owning DayZ just for the
server — costs a second copy of the game; not worth it for a LAN server.

---

## Mods

**`deploy/mods.conf` is the single source of truth** — enable/disable/reorder there,
then `./Deploy-DayZServer.ps1 -Fix` (drift detection auto-runs `update.sh` for any
enabled `@folder` missing on disk; run `update.sh` by hand only on game-patch days —
see postmortem #6; formerly `ExecStartPre`). **Line order in `mods.conf` = load order**
= the unit's `-mod=` line, built verbatim from the enabled lines in sequence.

### Enabled — core & gameplay mods (in load order)

| Folder | Workshop ID | Mod | Notes |
|---|---|---|---|
| `@cf` | [1559212036](https://steamcommunity.com/sharedfiles/filedetails/?id=1559212036) | Community Framework | Base dependency for most of the below. |
| `@vppadmintools` | [1828439124](https://steamcommunity.com/sharedfiles/filedetails/?id=1828439124) | VPPAdminTools | Requires CF. Admin teleport/spawn tooling; feeds `Sync-VPPCoordinates.ps1`. |
| `@aibandits` | [3628006769](https://steamcommunity.com/sharedfiles/filedetails/?id=3628006769) | AI Bandits | Requires CF; ~400 MB. |
| `@aibunleashed` | [3682348844](https://steamcommunity.com/sharedfiles/filedetails/?id=3682348844) | AIB_Unleashed | Squad tactics / stealth / breaching add-on, loads after `@aibandits`. Server-side only. |
| `@aibvoices` | [3679500367](https://steamcommunity.com/sharedfiles/filedetails/?id=3679500367) | AI Bandit Voices | `optional` in `mods.conf` — **removed from the workshop**, steamcmd may never fetch it. Client-side too (players must subscribe); with `verifySignatures = 2`, a missing `.bikey` fails signature checks for anyone running it. |
| `@dayzdog` | [2471347750](https://steamcommunity.com/sharedfiles/filedetails/?id=2471347750) | DayZ-Dog (Hunterz) | CF only. Feeds AI Bandits groups' `dog` field (see `Build-AIBandits.ps1`). |
| `@codelock` | [1646187754](https://steamcommunity.com/sharedfiles/filedetails/?id=1646187754) | Code Lock (Room Service) | Combination-lock replacement for base security. |

### Enabled — DayZ-Expansion module family (in load order)

Expansion isn't one mod — it's a suite of 16 separate Workshop items that load
together. `mods.conf` groups the interdependent ones with inline `# Dependencies:`
comments; that's reflected in the Notes column below.

| Folder | Workshop ID | Mod | Notes |
|---|---|---|---|
| `@dabsframework` | [2545327648](https://steamcommunity.com/sharedfiles/filedetails/?id=2545327648) | Dabs Framework (dab / InclementD) | Framework — required by the whole Expansion family; must load first. |
| `@expansion` | [2116151222](https://steamcommunity.com/sharedfiles/filedetails/?id=2116151222) | DayZ-Expansion | Base package — overgrown map POIs, kill feed, player list, grave crosses, street-light generators. Needs `@dabsframework` loaded first. |
| `@expansionlicensed` | [2116157322](https://steamcommunity.com/sharedfiles/filedetails/?id=2116157322) | DayZ-Expansion-Licensed | Bohemia-licensed content pack (animations, economy, vehicles, etc.) — required by BaseBuilding, Vehicles, and Missions below. |
| `@expansionbasebuilding` | [2792982513](https://steamcommunity.com/sharedfiles/filedetails/?id=2792982513) | DayZ-Expansion-BaseBuilding | Territory system + modular base building. Depends on Licensed + Book. |
| `@expansionbook` | [2572324799](https://steamcommunity.com/sharedfiles/filedetails/?id=2572324799) | DayZ-Expansion-Book | In-game stat/recipe/server-info book; integrates with Groups & Territory. Depends on Licensed. |
| `@expansionvehicles` | [2291785437](https://steamcommunity.com/sharedfiles/filedetails/?id=2291785437) | DayZ-Expansion-Vehicles | Helicopters, boats, cars, amphibious vehicles, keys, towing. Depends on Licensed. |
| `@expansiongroups` | [2792983364](https://steamcommunity.com/sharedfiles/filedetails/?id=2792983364) | DayZ-Expansion-Groups | Team/party system, shared HUD, pinging, map markers. Depends on Book. |
| `@expansionmissions` | [2792984177](https://steamcommunity.com/sharedfiles/filedetails/?id=2792984177) | DayZ-Expansion-Missions | Dynamic mission framework — contamination zones, mission & player-triggered airdrops. Depends on Licensed. |
| `@expansionspawnselection` | [2804241648](https://steamcommunity.com/sharedfiles/filedetails/?id=2804241648) | DayZ-Expansion-SpawnSelection | Map-based spawn point selection + custom starting loadouts. No extra deps. |
| `@expansionchat` | [2792982897](https://steamcommunity.com/sharedfiles/filedetails/?id=2792982897) | DayZ-Expansion-Chat | Global / proximity / vehicle / admin / party chat channels. No extra deps. |
| `@expansionmapassets` | [2792983824](https://steamcommunity.com/sharedfiles/filedetails/?id=2792983824) | DayZ-Expansion-Map-Assets | Decorative static-object + builder-item pack. No extra deps. |
| `@expansionanimations` | [2793893086](https://steamcommunity.com/sharedfiles/filedetails/?id=2793893086) | DayZ-Expansion-Animations | Vehicle animations (guitar, boat, tractor, heli, bus). No extra deps. |
| `@expansionquests` | [2828486817](https://steamcommunity.com/sharedfiles/filedetails/?id=2828486817) | DayZ-Expansion-Quests | MMO-style quest framework — collection/delivery/combat/exploration objectives. No extra deps. |
| `@expansionpersonalstorage` | [2946236937](https://steamcommunity.com/sharedfiles/filedetails/?id=2946236937) | DayZ-Expansion-PersonalStorage | Private virtual inventory / storage cases (Tarkov-style stash). No extra deps. |
| `@expansionweapons` | [2792985069](https://steamcommunity.com/sharedfiles/filedetails/?id=2792985069) | DayZ-Expansion-Weapons | Extra firearms, optics, and grenades (crossbows, RPGs, tear gas, etc.). No extra deps. |
| `@expansionnavigation` | [2792984722](https://steamcommunity.com/sharedfiles/filedetails/?id=2792984722) | DayZ-Expansion-Navigation | Satellite map, 2D/3D markers, compass + GPS HUD, player position. No extra deps. |

**Not used:** `@expansionbundle` ([2572331007](https://steamcommunity.com/sharedfiles/filedetails/?id=2572331007), DayZ-Expansion-Bundle — the all-in-one package) is
intentionally excluded; this server runs the modular pieces above instead.

### Disabled (commented out in `mods.conf`, kept for reference)

| Folder | Workshop ID | Mod | Why disabled |
|---|---|---|---|
| `@knockknock` | [3638393043](https://steamcommunity.com/sharedfiles/filedetails/?id=3638393043) | Knock Knock AI Bandits | Bandits ambush from behind doors; disabled for now. |
| `@basebuildingplus` | [1710977250](https://steamcommunity.com/sharedfiles/filedetails/?id=1710977250) | BaseBuildingPlus | Disabled 2026-07-11 — client version-mismatch kicks. |
| `@bicycle` | [2971190303](https://steamcommunity.com/sharedfiles/filedetails/?id=2971190303) | DayZ-Bicycle (Hunterz) | Disabled 2026-07-12 — bicycle animations conflicted with `@expansionanimations`; kept Expansion's instead. |
| `@survivoranimations` | [2918418331](https://steamcommunity.com/sharedfiles/filedetails/?id=2918418331) | Survivor Animations (Hunterz) | Dependency of `@bicycle` (must precede it); disabled with it. |

**Removed entirely** (no longer in `mods.conf`): `@trader` (Trader / Dr_J0nes) — deprecated 2026-07-12; trading is handled by `@expansionmarket` (DayZ-Expansion-Market) instead, and its `profiles/Trader/*.txt` config was deleted.

Each enabled mod is rsync-copied out of `steamapps/workshop/content/221100/<id>/` into
its `@folder` in the server root (workshop copy stays pristine for steamcmd's
bookkeeping), **all filenames lowercased** — the Linux server is case-sensitive and
workshop mods ship mixed-case; without this, joins fail on missing PBOs. The
copy+lowercase re-runs every start, so mod updates stay fixed. `*.bikey` keys are
copied into `keys/`.

**Keep every `@folder` in `mods.conf` lowercase** — `update.sh` always lowercases the
on-disk folder, so a mixed-case entry (e.g. `@expansionCore`) makes the rendered
`-mod=` line reference a directory that doesn't exist, hard-crashing the server at
boot. This caused a crash-loop on 2026-07-11.

Current unit launch parameter (quoted, **no trailing semicolon**), built by
`Deploy-DayZServer.ps1` from the enabled lines above in order:

```
"-mod=@cf;@dabsframework;@expansioncore;@expansion;@expansionlicensed;@expansionbasebuilding;@expansionbook;@expansionvehicles;@expansiongroups;@expansionmissions;@expansionani;@expansionmarket;@expansionspawnselection;@expansionchat;@expansionmapassets;@expansionanimations;@expansionquests;@expansionpersonalstorage;@expansionweapons;@expansionnavigation;@vppadmintools;@aibandits;@aibunleashed;@aibvoices;@dayzdog;@codelock"
```

Admin access: Steam64 IDs in
`profiles/VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt`
(`76561197985350538` = robotsd3stroyjpn; staged before first modded boot). Admin
password per `profiles/VPPAdminTools/Permissions/credentials.txt` after first
boot, or `vppDisablePassword = 1;` in `serverDZ.cfg`.

Clients must run the same mods (`verifySignatures = 2`): subscribe to every
**enabled** mod above on the workshop and enable them all in the launcher, in the
same order as `mods.conf`. AI Bandits and DayZ-Dog in particular ship custom NPC/
entity classes, so clients need them installed to render bandits/dogs, not just
the server.

### AI Bandits — config, tuning, and monitoring

The mod generates JSON configs under `profiles/AI_Bandits/` on first boot
(`DynamicAIB.json`, `StaticAIB.json`), then they're hand-tuned. Both are now in
the deploy payload and tracked by `Deploy-DayZServer.ps1`; the mod's runtime
`AIB.log` stays live-only. Re-tuning means editing the live file, then copying it
back into `deploy/profiles/AI_Bandits/` (or the next `-Fix` will revert it).

**`DynamicAIB.json`** defines patrol groups. `Group1` (faction Bandits) patrols
the Balota / southwest coast on three waypoints (DayZ coords are `X Y-height Z`):

| Point | X | Y | Z |
|---|---|---|---|
| WP1 / sniper trigger | 5237.82 | 9.57 | 2157.80 |
| WP2 (patrol centre) | 4887.84 | 9.56 | 2578.27 |
| WP3 | 4917.62 | 9.54 | 2599.98 |

Teleport a player to WP2 (`4887 / 2578` — VPP takes X/Z and resolves height) to
trigger the group. Spawns are **proximity-gated**, so an empty zone stays empty —
that's why a fresh boot shows no bandits until someone walks in.

**`BanditAI_Mirek` was removed** from `Group1`'s `npcclasses`: its class is broken
in the current release (`Cannot create non-ai vehicle BanditAI_Mirek` →
`must be inherited from class 'Head'`), so every spawn attempt hard-failed and
spammed the RPT. The group now runs four working variants — Keiko, Linda, Rolf,
Denis. `BanditAI_Denis` logs cosmetic head-config warnings but spawns fine; drop
him the same way if he renders wrong. Config is read at boot, so a restart applies edits.

**Monitoring — `AIB.log` is inert for normal activity.** `tail -f AIB.log` sits
silent because the mod only writes it for specific debug events, not routine
spawns/patrol. The living log is the RPT:

```bash
grep -iE 'bandit|BanditAI|Create entity' "$(ls -t ~/servers/dayz-server/profiles/*.RPT | head -1)" | tail -20
```

Entity-creation lines confirm the patrol spawned; combat/kill events land here too.
The RPT rotates on every restart — re-run against the newest file after a reboot.

### Hardening included in the current unit template

`TimeoutStartSec=900` — a generous start window. `ExecStartPre` is now
`prestart.sh` (local backups only — not steamcmd, see postmortem #6), so the
original multi-GB-download-vs-90s-timeout risk is gone; the headroom stays as
cheap insurance for a slow tar of a large `storage_1`.

---

## Setup from scratch

### 1. Dependencies

steamcmd is a 32-bit binary:

- Ubuntu/Debian: `sudo apt install lib32gcc-s1`
- Arch (multilib repo enabled): `sudo pacman -S lib32-gcc-libs`

### 2. Install steamcmd

```bash
mkdir -p ~/servers/steamcmd ~/servers/dayz-server
cd ~/servers/steamcmd
wget https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
tar -xvzf steamcmd_linux.tar.gz
```

### 3. One-time Steam login (required — anonymous does NOT work for DayZ)

```bash
~/servers/steamcmd/steamcmd.sh +login <account_that_owns_dayz> +quit
```

Run as the user the service will run as. Steam Guard prompts once; credentials
are then cached and all later runs are non-interactive. The Steam *client* never
needs to run — steamcmd is a standalone downloader that exits when done.

### 4. Download/update the server (app ID 223350)

`update.sh` (in `deploy/`) owns this: self-locating, it runs steamcmd for the app +
all three mods, then lowercases and key-syncs them (see the Mods section). Run it
**manually** on patch days — *not* from the unit (postmortem #6).

Notes:
- `+force_install_dir` must come **before** `+login`.
- Append `validate` to `+app_update 223350` to verify files (slower; resets
  edited files inside the install dir).
- Experimental branch is a separate app ID: `1042420`.

### 5. Configuration

`serverDZ.cfg` in the server root (see dzconfig.com/wiki for every field):
hostname, password, passwordAdmin, maxPlayers, `steamQueryPort = 27016;`,
mission `template` under `class Missions`. Keep a pristine copy before editing.

#### Day/night cycle (time acceleration)

`serverTimeAcceleration` (X) scales the **full 24 in-game-hour cycle**;
`serverNightTimeAcceleration` (Y) applies an *additional* multiplier during
night only. Derived from the in-cfg comments:

```
full_cycle_real_hours = 24 / X
night_real_hours      = 24 / (X * Y)
day_real_hours        = full_cycle_real_hours - night_real_hours
```

**Current (`deploy/serverDZ.cfg`): X=6, Y=4** → full cycle 4h real = **3h day /
1h night**. Solved from the target (day=3h, night=1h): night gives
`X*Y=24`, substituting into the day equation gives `X=6`, `Y=24/6=4`.

To retarget, pick desired `day_real_hours`/`night_real_hours`, then:
`X = 24 / (day + night)`, `Y = 24 / (X * night)`.

### 6. systemd service

Templates in this folder: `update.sh`, `dayz-server.service` (install to
`/etc/systemd/system/`). Key points learned the hard way: shebang in the script,
`chmod +x`, correct absolute paths, `User=` set to the account whose `~/Steam`
holds the cached login.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now dayz-server
journalctl -u dayz-server -f
```

Server logs (RPT, ADM, crash dumps) land in `<install>/profiles/`.

### 7. Ports (UDP) — LAN play needs no router forwarding

| Port  | Purpose                        |
|-------|--------------------------------|
| 2301  | Game port (`-port=2301`)       |
| 27016 | Steam query (`steamQueryPort`) |

Only forward these on the router if internet players should join.

---

## Map switching (characters follow the server)

Three missions ship with the install: `dayzOffline.chernarusplus`,
`dayzOffline.enoch` (Livonia — free for all clients since 1.26),
`dayzOffline.sakhal` (requires Frostline DLC on every client).

**To switch:** edit `DAYZ_MISSION=` in `~/servers/dayz-server/map.env`, then
`sudo systemctl restart dayz-server`. The choice persists until changed again
(`-mission=` on the command line overrides serverDZ.cfg's Missions class, so the
cfg never drifts).

On every start, `prestart.sh` (ExecStartPre — local file ops only, never steamcmd):

1. Backs up the active mission's `storage_1/` to `backups/<mission>/` (keeps 10).
2. On a map change, copies `players.db` to the new mission — **characters follow
   the server**, overwriting the destination's set (the backup from step 1 covers
   regrets). World state (bases/vehicles) stays per-map; positions are raw
   coordinates, so teleport players via VPP after their first login on the new map.

`map.env` and `.last-map` are runtime state — not in the deploy payload, don't delete.

## Migrating to an external host

Moving from LAN-on-meshroom to an externally-reachable server. The save state is
small and portable; what actually changes is the **exposure model**, not the game.

### Copy vs rebuild

**Copy (the irreplaceable state):**

- `mpmissions/<mission>/storage_1/` — world + `players.db` (the actual saves)
- `serverDZ.cfg`, `profiles/` (VPP `SuperAdmins.txt`, the `AI_Bandits/` configs)
- the `UbuntuHost/DayZ Server/` deploy payload + scripts

For the **initial seed** (server empty, local is the source), the saves come across
with `Push-DayZServer.ps1 -Execute -Force` — the plain push protects the server's
saves, so the seed needs `-Force`. The deploy payload travels via git and is
installed on the new host with `Deploy-DayZServer.ps1 -Fix`. Once the server is
live it becomes the main copy: routine pushes drop `-Force` (config only), and
`Pull-DayZServer.ps1 -Execute` refreshes this dev machine from it.

**Rebuild on the new host (don't copy — faster, avoids stale binaries):**

- steamcmd + DayZ app 223350 (~20 GB) and the mods — `update.sh` re-downloads and
  re-lowercases them from scratch
- the Steam credential cache — a fresh one-time interactive login on the new box
  (same isolated-HOME dance as postmortem #5)

### Changes needed for external exposure

| Area | LAN today | External |
|---|---|---|
| Firewall / ports | none needed | open **UDP 2301 + 27016** on the host `ufw` (below); on the OVH VPS also configure the **Edge Network Firewall** upstream — see *OVH Edge Network Firewall* below. No NAT/router forwarding — the VPS has a public IP directly. |
| Admin gate | `vppDisablePassword = 1` | **re-enable** the VPP password — on a public box the Steam64 SuperAdmins list shouldn't be the only factor. |
| Secrets | `passwordAdmin`/`password` are templated (`{{DEPLOY_ADMIN_PASSWORD}}`/`{{DEPLOY_SERVER_PASSWORD}}` in `serverDZ.cfg`, real values only in gitignored `host.env`) | same setup works externally — just **rotate the values in `host.env`** if this repo could ever go public. |
| Steam session | patch-day update kicks the desktop session (minor) | a 24/7 shared server makes this bite — a **dedicated Steam account owning a 2nd copy of DayZ** finally pays off, decoupling server updates from your personal account. |
| Distro deps | Arch `lib32-gcc-libs` | a Ubuntu/Debian VPS needs `lib32gcc-s1` instead (already in Setup §1). |
| Backups | `prestart.sh` keeps 10 on-box | add an **off-box copy** — a single VPS disk failure loses everything otherwise. |

Already portable and carrying over unchanged: `verifySignatures = 2`,
`forceSameBuild = 1`, BattlEye (`-BEpath=battleye`), and the whole
download → lowercase → key-sync pipeline.

### OVH Edge Network Firewall (upstream of the VPS)

`servermander.ovh` sits behind OVH's **Edge Network Firewall** — a hardware filter
on OVH's network, *upstream of the VPS*. It's worth configuring **in addition to**
the host `ufw`, not instead of it: it drops denied traffic before it ever reaches the
VPS NIC/CPU, whereas `ufw` can only drop after the packet has arrived. That upstream
drop is the whole point — **accepted traffic costs the same either way; the win is on
denies and floods** — so the edge is where the `deny all` and any abusive-IP blocklists
belong, and the host `ufw` stays as the stateful correctness net.

Three properties shape every rule:

- **Stateless** — it does not track connections. A blanket `deny all` therefore also
  blocks the *replies* to connections the VPS initiates (apt, steamcmd, DNS, NTP); those
  must be allowed back in explicitly (rows 0, 4, 5 below).
- **Inbound-only** — rules apply to traffic *to* the VPS IP; the server's outbound is
  untouched. So the reply problem above is specifically about inbound reply packets.
- **Default-allow, IPv4-only, 20 rules (priority 0–19)** — unmatched traffic passes, so
  a final `deny all` is mandatory. "Priority" is just rule-evaluation order (first match
  wins), *not* QoS — the same first-match model `ufw` uses; `ufw` just expresses it by
  list position (`ufw insert 1 …` ≈ priority 0) instead of a number.

The protocol dropdown has **no "all"** — options are AH / ESP / GRE / ICMP / IPV4 / TCP /
UDP. Use **`IPv4`** (any protocol, no ports) for the catch-all deny.

Ruleset for this server (game port **2301**, query **27016** — match `serverDZ.cfg`):

| Prio | Action | Protocol | Dest port | Source IP | Source port | TCP state | Purpose |
|---|---|---|---|---|---|---|---|
| 0 | Accept | TCP | — | — | — | Established | return traffic for outbound TCP (apt, steamcmd, git) |
| 1 | Accept | TCP | 22 | your admin IP | — | — | SSH |
| 2 | Accept | UDP | 2301–2306 | — | **blank** | — | DayZ game port(s) |
| 3 | Accept | UDP | 27016 | — | **blank** | — | Steam query / server browser |
| 4 | Accept | UDP | — | — | 53 | — | DNS replies (stateless workaround) |
| 5 | Accept | UDP | — | — | 123 | — | NTP replies |
| 6 | Accept | ICMP | — | — | — | — | ping + path-MTU discovery |
| 7 | Accept | TCP | 443 | — | **blank** | — | nginx / HTTPS (see reverse-proxy note) |
| 8 | Accept | TCP | 64738 | — | **blank** | — | Mumble voice (TCP) |
| 9 | Accept | UDP | 64738 | — | **blank** | — | Mumble voice (UDP) |
| 19 | Deny | IPv4 | — | — | — | — | catch-all — **must be last** |

**⚠ Source-port field: this is the trap. Leave it BLANK on every inbound service row
(2, 3, 7, 8, 9).** It is only set on *reply* rows (4, 5), which admit return traffic
from a server the VPS queried. Setting a source port on an inbound service row means
"only accept packets that were *sent from* that port" — but real clients (Steam browser,
NAT'd players, the Steam master reply) send from random ephemeral ports, so the rule
silently drops all of them. **Proven 2026-07-07**: the live config had source ports
2301–2306 / 27016 filled on rows 2/3 → server invisible in browser, most players
couldn't join. An A2S probe from an ephemeral source port got no reply; the same probe
forced to source port 27016 replied — that asymmetry *is* the fingerprint of this bug.

- Match on **destination port** = inbound to your services (game, query, HTTPS).
- Match on **source port** = replies to *your* outbound (DNS, NTP) only.

**One protocol per rule.** The dropdown has no combined TCP+UDP. Anything needing both
(Mumble) takes two rules — rows 8 and 9. `IPv4` matches all protocols but can't filter
by port, so it's only for a trusted-source-IP allow or the catch-all deny.

**Caveats — the stateless tax:**

- Rows 4–5 ("allow anything from UDP source port 53/123") are looser than a stateful rule
  — an attacker can spoof those source ports. Standard trade-off for a stateless edge.
- **Keep the host `ufw` regardless** — it's the stateful layer that handles the ephemeral
  UDP replies the edge can't reason about. Not double work: **edge = load/DDoS layer,
  host = correctness layer.**

**The 20-rule limit — don't scale services here.** The edge is a coarse DDoS front line,
not a per-service firewall. Three levers keep you well under 20 (currently ~9 used):

1. **Reverse proxy collapses all web services to one rule.** nginx on TCP 443 fronts
   every web app via vhosts/paths — 1 app or 50, still one edge rule (row 7). The edge
   never sees the individual services; nginx routes them internally.
2. **Port ranges** fold contiguous ports into one rule (row 2 = 2301–2306).
3. **Push granular/stateful filtering to the host `ufw`/nftables** — no rule limit, and
   stateful so replies are automatic. But note: while row 19 `deny all` stands, the edge
   is first in path, so **every public port still needs an edge accept row** — the host
   firewall refines *within* what the edge admits; it can't override an edge drop.

Thin host `ufw` to pair with it (the stateful net — `allow outgoing` makes all the
return traffic in rows 0/4/5 just work on the host side):

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from <your-admin-IP> to any port 22 proto tcp   # SSH
sudo ufw allow 2301/udp                                        # DayZ game
sudo ufw allow 27016/udp                                       # Steam query
sudo ufw enable
```

### OVH Game Firewall (separate from the Edge firewall — NOT redundant)

The VPS has a **second** OVH layer, the **Game Firewall**, easily mistaken for a
duplicate of the Edge firewall. It is not — it does a different job and both are kept:

- **Edge Network Firewall** (above) = a stateless inbound allow/deny ACL. Decides *what
  traffic is permitted*.
- **Game Firewall** = *not* an allow/deny list. It tags UDP ports as **game traffic** so
  OVH's always-on anti-DDoS scrubber applies game-aware mitigation profiles instead of
  generically blackholing bursty UDP. This is the fix for the proven "VAC drops game-rate
  UDP" problem (see postmortem) — **removing these tags brings that back.**

Its columns are only **Game protocol / Start port / End port / Status** — there is **no
source or destination**, and no accept/deny. The two port fields are the **start and end
of a range**, not source-and-destination:

- single port → put the same number in both (e.g. `27016`–`27016`);
- range → low and high (e.g. `2301`–`2306`).

Entries for this server:

| Game protocol | Start | End | Keep? |
|---|---|---|---|
| Other | 2301 | 2306 | ✅ game ports |
| Other | 27016 | 27016 | ✅ query port |
| Other | 64738 | 64738 | ✅ Mumble — bursty real-time UDP benefits from game-mode mitigation |
| Other | 443 | 443 | ❌ **remove** — 443 is TCP (nginx/HTTPS); game mitigation is UDP-oriented and can false-positive on web traffic |

Rule of thumb: the Game firewall lists **only your real-time UDP ports** (game, query,
voice). TCP web ports (443) do not belong here — they belong in the Edge firewall only.

### Hardcoded paths: RESOLVED (2026-07-06)

Historically every script baked in the dev host's user/home. Now: the shell scripts
**self-locate** (paths derive from their own location), and the systemd units are
**templates** with `{{DEPLOY_USER}}`/`{{DEPLOY_GROUP}}`/`{{DEPLOY_HOME}}` placeholders
that Deploy renders from `host.env`. Nothing host-specific lives in the payload.

The tuned `profiles/AI_Bandits/` configs (waypoints, the Mirek removal) are
already in the payload, so they travel with the move — just re-copy any live edits
made after this into `deploy/` first.

## Scheduled restart with in-game warnings — NATIVE (messages.xml)

DayZ ships this built-in: **`messages.xml`** (https://dzconfig.com/wiki/messages) in the
active mission's `db/` folder. The tracked copy lives at `deploy/messages.xml`;
`prestart.sh` injects it into whichever mission is active on every start, so **map
switches keep the schedule**. Current config: `deadline 240` + `shutdown 1` +
`countdown 1` → clean shutdown every 4 h with automatic player warnings at
90/60/45/30/20/15/10/5/2/1 minutes, plus an on-connect greeting (`#name`/`#tmin`
placeholders).

`shutdown` **stops** the server — **`Restart=always` in the unit brings it back up**,
completing the restart (a clean exit is code 0, which `Restart=on-failure` would NOT
relaunch — this also makes VPP's manual restart button reliable). The deadline re-arms
on each boot, so the cadence is "4 h since last start".

Verify the unit of `deadline` on the first cycle: BI wiki says **minutes** (240 = 4 h);
if warnings/shutdown come absurdly fast, dzconfig's page means seconds → use 14400.

*History:* a systemd-timer + RCon-countdown stack (`dayz-restart.{timer,service}` +
`restart-with-warning.sh`) previously did this job — retired 2026-07-06 as reinvention;
leftovers were removed from hosts as a **one-off** (cleanup doesn't live in the deploy
script — one-off fixes stay one-offs). `dayz-rcon.ps1` **stays**: the deploy
player-guard queries `players` through it, and it's a general admin tool.

**RCon prereq (for the player guard / admin use)** — in
`<server>/battleye/beserver_x64.cfg` (localhost-only, no firewall port), then restart
once so BattlEye reads it:
```
RConPassword <pick-a-password>
RConPort 2306
RConIP 127.0.0.1
```
Gotcha: BattlEye may read its config from a **nested** `battleye/battleye/` path — if
nothing listens on 2306 after a restart, drop the cfg in the nested folder too.

## Log archiving — daily zip + month retention (dayz-logarchive.timer)

**`deploy/Archive-Logs.ps1`** is a *generic* log archiver (reusable for any service:
`-SourceDir /var/log/myapp -Name myapp -Fix`). For DayZ it runs as
`dayz-logarchive.{service,timer}` (deployed + enabled by `Deploy-DayZServer.ps1 -Fix`):
daily at 00:20, `Persistent=true` so a run missed while the host was down fires at the
next boot — "day rolled over but nothing archived since the last reboot" is covered
natively by systemd, no state file needed.

Behavior (house rules apply: read-only default, `-Fix` to act, CSV run log, output in
a named subdirectory):

- Dead logs (top-level `*.log/*.RPT/*.ADM/*.mdmp` in `profiles/`, last written before
  today) are zipped per last-write date into `profiles/archive/dayz-logs-<yyyymmdd>.zip`
  and the originals removed — but only after the zip entry is size-verified. Files
  still open (checked with `fuser`) are skipped and picked up the next day; that's why
  the ever-open `error.log` stays put by design.
- Zips older than 31 days are pruned, judged by the **zip's mtime** (an ancient log
  archived today still gets a full retention window — never zip-then-prune).
- Streams via .NET `ZipArchive`: `Compress-Archive` and `ZipArchiveMode.Update` both
  buffer whole files in RAM and die on multi-GB logs ("Stream was too long" — hit on
  the 50 GB runaway `crash_*.log` from the 2026-07-05 VPP hang). Appends rebuild the
  zip through a `.tmp` + atomic rename, so an interrupted run never corrupts an archive.

`prestart.sh` `KEEP_LOGS` is now a safety net at 40 (was 12): the archiver owns
retention; the boot-time prune only matters if the timer breaks.

## Troubleshooting quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `Exec format error` / 203/EXEC | Missing shebang (or BOM/CRLF) in the script systemd executes | `#!/bin/bash` first line of the *live* file; `head -1 file \| cat -A` to verify |
| `Cached credentials not found` → `Invalid Password` / 5/NOTINSTALLED | No cached Steam login for the service user; anonymous unsupported for 223350 | One-time interactive `steamcmd +login <account> +quit` as that user |
| Server exits over `steamclient.so` | Steam client lib not found | `mkdir -p ~/.steam/sdk64 && ln -sf ~/servers/steamcmd/linux64/steamclient.so ~/.steam/sdk64/` |
| Listed in browser but unjoinable | Listing shows a VPN/public IP you can't reach | LAN: direct-connect `<LAN-IP>:2301`; don't host behind a VPN |
| Service dies mid-update on patch day | Default 90s start timeout vs long steamcmd download | `TimeoutStartSec=900` in `[Service]` |
