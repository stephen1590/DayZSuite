# Server-only mods (`-serverMod`)

Mods here load via **`-serverMod`**, not `-mod`. That means the server runs them but
**never advertises, requires, or ships them to clients** - players join exactly as they
do now and never download anything. Use this for backend/admin logic only.

## AIB_Tracker

Exports **live AI Bandit positions** for the Config UI map overlay. The `@aibandits`
mod logs nothing about active NPCs (verified against the live RPT), so this is the only
way to get them. It:

- hooks `InfectedBanditBase` (`extends DayZInfected`) via `EEInit`/`EEDelete` into a live registry,
- every 20s writes living bandits' `[{x,z}]` to `profiles/AI_Bandits/live_positions.json`.

The API reads that file; the map draws the dots. Anonymised is moot (NPCs), and no
client ever sees the mod.

### Build (Arch, libre toolchain - no DayZ Tools/Windows)

Packer is **HEMTT** (MIT/Apache, actively maintained) - `armake2` is abandoned and won't
build against OpenSSL 3. Install once: AUR `hemtt-bin`, a GitHub release binary, or
`cargo install hemtt` (uses rustls, no OpenSSL). Server-only mods need **no signing**, so
`hemtt build` is the whole build:

```sh
cd "UbuntuHost/DayZ Server/serverMods/AIB_Tracker"
hemtt build
# -> .hemttout/build/addons/AIB_Tracker_main.pbo
```

The mod is a HEMTT project: source lives in `addons/main/`, and `addons/main/$PBOPREFIX$`
pins the in-PBO prefix (`AIB_Tracker`) that `config.cpp`'s `files[]` paths resolve against.
HEMTT honors that file and bakes the flat prefix into the PBO. Two warnings are expected
and harmless: `Arma 3 Tools not found` (nothing to binarize) and `INVALID-PBOPREFIX`
(HEMTT prefers its Arma `z\...\addons\...` scheme; DayZ wants the flat prefix we set).

### Deploy

1. Ship `@aib_tracker/addons/AIB_Tracker_main.pbo` to the box (it's OUR artifact - it comes
   from the repo, not Steam Workshop). Assemble the mod folder from the build output:
   `mkdir -p @aib_tracker/addons && cp .hemttout/build/addons/AIB_Tracker_main.pbo @aib_tracker/addons/`.
2. Add `-serverMod=@aib_tracker` to the unit `ExecStart` (see `deploy/dayz-server.service`).
3. Restart the server.

### Test (prove it works before wiring the UI)

Get a player near a bandit camp so a group spawns, then on the box:

```sh
cat profiles/AI_Bandits/live_positions.json    # should be [{"x":..,"z":..}, ...]
```

**If it stays `[]` with bandits up:** the `modded class` didn't apply - almost always the
`requiredAddons` name in `config.cpp` (`AI_Bandits`) not matching the real `@aibandits`
CfgPatches class. Confirm that name (unrapify its `config.bin`) and re-pack. Everything
else (the class, the hook, the write path) is confirmed against the live box.
