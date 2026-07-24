# Server-only mods (`-serverMod`)

Mods here load via **`-serverMod`**, not `-mod`. That means the server runs them but
**never advertises, requires, or ships them to clients** - players join exactly as they
do now and never download anything. Use this for backend/admin logic only.

## CustomServerMods

The grab-bag server-only mod - backend features that can't be expressed as config, one
small hook per feature. (The tracker was `AIB_Tracker` until 2026-07-24; renamed to
`LiveTracker` once it tracked eAI + players + the world clock, not just the now-retired AI
Bandits. Output moved from `profiles/AI_Bandits/live_positions.json` to `profiles/LiveTracker/`.)

### Feature: live position export

Exports live map data for the Config UI overlays, on a 20s `MissionServer` tick
(`LiveTracker.c` → `LiveTrackerTick`), into `profiles/LiveTracker/`:

- **`ai.json`** — living NPCs `[{x,z,type,age}]`. Hooks two AI base classes via
  `EEInit`/`EEDelete` into one live registry:
  - `eAIBase` (`extends PlayerBase`, bundled in `@expansion/scripts.pbo` — what
    `ExpansionAIPatrol` / Missions / Quests spawn) — tagged `type: "eai"`,
  - `InfectedBanditBase` (`extends DayZInfected`, `@aibandits`) — tagged `type: "bandit"`,
    in the split-off `bandits` addon, dormant unless `@aibandits` loads (bandits retired).
  `age` = seconds alive this session (game clock, resets on restart).
- **`players.json`** — connected players `[{x,z}]`, ANONYMIZED. Uses `GetGame().GetPlayers()`
  (the live roster, the same call the vanilla admin log uses), so it is 20s-fresh — this
  REPLACES the minutes-lagged `.ADM` scrape the player overlay used to depend on. NO id/name/
  GUID is ever written, so `{x,z}` is genuinely all that leaves the box.
- **`time.json`** — the in-game world clock `[{year,month,day,hour,minute}]` from
  `GetGame().GetWorld().GetDate()`. Feeds the API's `world-time` stat (the day/night `hour`).

The API reads these (`dayz-ctl live-ai` / `live-players` / `world-time` → `Api/app/src/actions.ts`
`bandits` / `positions` / `world-time`); the map draws the dots. No client ever sees the mod.

> **Note:** `dayz-ctl live-ai` inlines `ai.json` verbatim, but the API's `bandits` response
> schema (`Api/app/src/actions.ts`) only serialises fields it declares — so `type`/`age` are
> declared there too (regenerate `openapi.json` with `npm run spec`). Colouring eAI vs bandit
> differently on the overlay is a separate UI change, not yet done.

### Feature: fresh-spawn flu buff

Every **new** character (relogs skip it) gets, ~2s after creation via
`MissionServer.OnClientNewEvent` (`5_Mission/MissionServer.c`):

- `SetTemporaryResistanceToAgent(eAgents.INFLUENZA, 900)` - 15 min flu immunity. The
  vanilla cold-exposure infection (`AutoinfectCheck`) is hard-gated on this being
  non-zero, so fresh spawns can't contract flu until it expires (unbuffed onset on
  Sakhal is ~5-6 min).

That is the whole buff - no stat changes. A heat-buffer fill was tried and rejected
(2026-07-18, showed as `+++` on the HUD); freezing stays vanilla.

Why a serverMod and not `init.c`: Expansion's spawn-selection module **replaces**
`EquipCharacter` whenever `StartingClothing.EnableCustomClothing = 1` (our loadout
system), so the mission's `StartingEquipSetup` - where an earlier hand-added buff lived -
never runs. `OnClientNewEvent` sits above that fork and can't be severed by it. The dead
buff lines in the box's Sakhal `init.c` (added 2026-07-03 by hand) are obsolete once this
ships.

### Build (Arch, libre toolchain - no DayZ Tools/Windows)

Packer is **HEMTT** (MIT/Apache, actively maintained) - `armake2` is abandoned and won't
build against OpenSSL 3. Install once: AUR `hemtt-bin`, a GitHub release binary, or
`cargo install hemtt` (uses rustls, no OpenSSL). Server-only mods need **no signing**, so
`hemtt build` is the whole build:

```sh
cd "UbuntuHost/DayZ-Server/serverMods/CustomServerMods"
hemtt build
# -> .hemttout/build/addons/CustomServerMods_main.pbo
```

The mod is a HEMTT project: source lives in `addons/main/`, and `addons/main/$PBOPREFIX$`
pins the in-PBO prefix (`CustomServerMods`) that `config.cpp`'s `files[]` paths resolve against.
HEMTT honors that file and bakes the flat prefix into the PBO. Two warnings are expected
and harmless: `Arma 3 Tools not found` (nothing to binarize) and `INVALID-PBOPREFIX`
(HEMTT prefers its Arma `z\...\addons\...` scheme; DayZ wants the flat prefix we set).

### Deploy

1. Ship `@custom_server_mods/addons/CustomServerMods_main.pbo` to the box (it's OUR
   artifact - it comes from the repo, not Steam Workshop). `Deploy-DayZServer.ps1` does
   this as a normal payload item.
2. `-serverMod=@custom_server_mods` in the unit `ExecStart` (see `deploy/dayz-server.service`).
3. Restart the server. (The old `@aib_tracker/` dir on the box is inert after the renamed
   unit lands - remove it whenever convenient.)

### Test (prove it works before wiring the UI)

Get a player near an eAI patrol so a group spawns, then on the box:

```sh
cat profiles/LiveTracker/ai.json        # [{"x":..,"z":..,"type":..,"age":..}, ...]
cat profiles/LiveTracker/players.json   # [{"x":..,"z":..}, ...]  (you, anonymized)
cat profiles/LiveTracker/time.json      # [{"year":..,"month":..,"day":..,"hour":..,"minute":..}]
```

**If it stays `[]` with AI up:** a `modded class` didn't apply - almost always a
`requiredAddons` name in `config.cpp` not matching the real CfgPatches class of the PBO
that owns the base (`AI_Bandits` for bandits, `DayZExpansion_Scripts` for `eAIBase`).
Confirm the name (unrapify its `config.bin`) and re-pack. **If only one `type` is missing,**
just that tree's addon name is wrong - the other proves the class/hook/write path work.
