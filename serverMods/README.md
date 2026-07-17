# Server-only mods (`-serverMod`)

Mods here load via **`-serverMod`**, not `-mod`. That means the server runs them but
**never advertises, requires, or ships them to clients** - players join exactly as they
do now and never download anything. Use this for backend/admin logic only.

## AIB_Tracker

Exports **live AI positions** (AI Bandits + ExpansionAI) for the Config UI map overlay.
Neither `@aibandits` nor Expansion logs active NPC positions (verified against the live
RPT), so this is the only way to get them. It:

- hooks two AI base classes via `EEInit`/`EEDelete` into one live registry (`AIB_Tracker.c`):
  - `InfectedBanditBase` (`extends DayZInfected`, `@aibandits`) — tagged `type: "bandit"`,
  - `eAIBase` (`extends PlayerBase`, bundled in `@expansion/scripts.pbo` — what
    `ExpansionAIPatrol` / Missions / Quests spawn) — tagged `type: "eai"`,
- every 20s writes living NPCs to `profiles/AI_Bandits/live_positions.json` as
  `[{x,z,type,age}]` — `age` = seconds alive this session (game clock, resets on restart).

`x`/`z` are unchanged from the original schema, so every existing consumer keeps working;
`type`/`age` are additive. The API reads that file; the map draws the dots. Anonymised is
moot (NPCs), and no client ever sees the mod.

> **Reaching the map:** `dayz-ctl bandit-live` inlines the file verbatim, but the API's
> `bandits` response schema (`Api/app/src/actions.ts`) only serialises fields it declares —
> so `type`/`age` are declared there too (regenerate `openapi.json` with `npm run spec`).
> Colouring bandit vs eAI differently on the overlay is a separate UI change, not yet done.

### Build (Arch, libre toolchain - no DayZ Tools/Windows)

Packer is **HEMTT** (MIT/Apache, actively maintained) - `armake2` is abandoned and won't
build against OpenSSL 3. Install once: AUR `hemtt-bin`, a GitHub release binary, or
`cargo install hemtt` (uses rustls, no OpenSSL). Server-only mods need **no signing**, so
`hemtt build` is the whole build:

```sh
cd "UbuntuHost/DayZ-Server/serverMods/AIB_Tracker"
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
cat profiles/AI_Bandits/live_positions.json    # should be [{"x":..,"z":..,"type":..,"age":..}, ...]
```

**If it stays `[]` with AI up:** a `modded class` didn't apply - almost always a
`requiredAddons` name in `config.cpp` not matching the real CfgPatches class of the PBO
that owns the base (`AI_Bandits` for bandits, `DayZExpansion_Scripts` for `eAIBase`).
Confirm the name (unrapify its `config.bin`) and re-pack. **If only one `type` is missing,**
just that tree's addon name is wrong - the other proves the class/hook/write path work.
