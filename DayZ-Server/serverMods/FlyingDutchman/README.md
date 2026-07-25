# FlyingDutchman (server-only)

One persistent Expansion ship (`ExpansionLHD`) that patrols the Sakhal coast, pausing outside
towns. **Server-only** (`-serverMod`) — clients download nothing; they only need
`@expansionvehicles` (already enforced), which supplies the ship class. Resolved by NAME at
spawn, so this mod has no compile-time Expansion dependency.

## Status: DORMANT PROTOTYPE

`ShipPatroller.ENABLED = false` — the mod ships **inert**: spawns nothing, schedules nothing,
does nothing but call `super.OnInit()`. It is also **not yet wired into the `-serverMod` chain**,
so it isn't even loaded. Flip the flag AND add the mod to `-serverMod` (see the deploy) to test.

> **Untested:** hemtt does not compile Enforce script — the PoC is validated by review only until
> it's loaded on the box. See `PLAN.md`.

## How it works (design)

- **The ship MOVES along waypoints - no fuel, no driver.** Small `SetPosition` steps each 1s
  tick toward hand-placed water waypoints read as sailing on clients. Not engine driving (DayZ
  has no autonomous boat AI), and not "teleporting" - that word is reserved for the player
  boarding feature below.
- **Boarding is by teleport (planned).** An offshore LHD is not feasibly boardable by swimming -
  the sign/NPC "teleport to ship / to town" feature IS the boarding mechanism (see PLAN Phase 5).
- **Trackable on the live map.** Writes `$profile:FlyingDutchman/ship.json`
  (`[{x,z,state}]`, ~20s heartbeat, `[]` once destroyed) - the same file convention as
  LiveTracker, deliberately with NO code dependency on it. Backend chain is already in place
  (`dayz-ctl live-ship` → API `/dayz/ship`, `missing:true` while dormant); the map chip lands
  when the ship goes live.
- **Destructible + lockable.** Players can blow it up (a reward hook is a later feature); it's
  locked against hijack (lock is stubbed in the PoC).
- **Resumes where it left off.** Last position + patrol leg persist to
  `$profile:FlyingDutchman/state.json`; a restart respawns the ship at that leg.

## Files

- `addons/main/scripts/4_World/ShipPatroller.c` — the patrol brain (state, route, tick).
- `addons/main/scripts/5_Mission/MissionServer.c` — schedules the tick (gated by `ENABLED`).

## Build

```sh
cd DayZ-Server/serverMods/FlyingDutchman
hemtt build   # -> .hemttout/build/addons/FlyingDutchman_main.pbo  (2 harmless warnings)
```

Full design, phasing, open decisions, and the enable/deploy steps: **`PLAN.md`**.
