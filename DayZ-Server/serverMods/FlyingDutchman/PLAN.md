# FlyingDutchman — implementation plan

**Status:** dormant prototype coded (`ShipPatroller.c` + `MissionServer.c`, `ENABLED=false`, not
loaded). This plan is the handoff so any agent (or the owner) can finish it.

**Goal:** one persistent Expansion ship that patrols the Sakhal coast on water, pausing outside
major coastal towns, lockable against hijack but destructible (with a reward for sinking it).
Optionally: teleport between the ship and towns.

---

## Decisions locked by the owner

| Decision | Choice | Why |
|---|---|---|
| Movement | **The ship MOVES along waypoints** - small `SetPosition` steps per tick (reads as sailing), NOT engine driving. "Teleport" refers ONLY to player boarding, never to ship movement | No fuel to manage; deterministic; no reliance on absent boat-AI |
| Boarding | **Teleport on/off is the boarding mechanism** (sign/NPC, Phase 5) - an offshore LHD isn't feasibly boardable by swimming | Owner: "teleporting is for players looking to get on and off the ship in a feasible manner" |
| Map | **Trackable via the live-map system**: mod writes its own `ship.json` (LiveTracker file convention, ~20s heartbeat) - a FILE convention, NO LiveTracker class dependency | Ship code must never be able to break the proven tracker; backend chain (`live-ship` verb + `/dayz/ship`) already built, degrades to `missing` while dormant |
| Ship | `ExpansionLHD` | Verified class (also `ExpansionBoat`/`UtilityBoat`/`ZodiacBoat`) |
| Destructibility | **Destructible** — players may blow it up; add a **reward** for doing so | Owner wants it as a combat objective, not an invulnerable prop |
| Persistence | **Respawn where it left off** — save position+leg, restore on restart | No entity persistence (avoids duplicate hulls); a small state file instead |
| Distribution | **Its own server-only mod** (`FlyingDutchman`) | No client download; only needs `@expansionvehicles` (already enforced) |

**On "does it need real driving?"** No. `SetThrust`/`SetSteering` ARE script-callable
(`proto native`, so real scripted driving is technically possible — the earlier "player-input
only" claim was wrong), and Expansion AI does NOT drive vehicles (checked `AISettings.json`). But
real driving needs **fuel** and a driver/engine sim, which the owner explicitly doesn't want.
Teleport wins. Real driving is documented here only as a rejected alternative.

---

## What the prototype already does (`ShipPatroller.c`)

- `ENABLED` kill switch (false), `Init` → `MakeDirectory` + `BuildRoute` + `LoadState` + `Spawn`.
- `Spawn`: `CreateObjectEx("ExpansionLHD", pos, ECE_CREATEPHYSICS | ECE_INITAI)`.
- `Tick` (1s): player-halt (radius + 30-min cap) → dwell → step toward leg via `SetPosition` +
  `SetOrientation` → reach → next leg (loops) → `SaveState`.
- `LoadState`/`SaveState`: `$profile:FlyingDutchman/state.json` (leg + pos), leg clamped.

**Stubbed / TODO (kept as no-ops so the class compiles):**
- `LockShip` — lock against hijack. Options: Expansion vehicle lock (locked, no key) or a
  `@codelock` attachment. Ship must stay destructible.
- `IsWater` — returns true. Real water test: `06-engine-api/19-terrain-queries.md` (SurfaceY /
  GetSurface; confirm if a `SurfaceIsSea` exists). Until then, author waypoints on open water.
- Route is hardcoded placeholder coords — replace with real Sakhal water waypoints.

---

## Risks / gotchas

- **hemtt does NOT compile Enforce.** A dormant class still compiles at load, so a bad signature
  breaks the mod *even disabled*. The PoC uses only confident calls; the uncertain ones are
  stubbed. Confirm `JsonLoadFile`, `VectorToAngles`, `CreateObjectEx` flags, `ECE_*` on the box
  before enabling.
- **Modded MissionServer is fragile** — a throw here can disable player connect. Ship logic is
  behind `IsServer()` + null-guards and `ENABLED`, and uses `CallLater` (never `Timer.Run(this)`).
- **Teleporting a physics hull** may fight buoyancy / rubber-band on clients. Small `STEP_METRES`
  mitigates; if it tips or drifts, may need to zero velocity each step or disable simulation.
- **Waypoints on terrain beach the ship** — validate at author time (and add the runtime IsWater).
- **Blown-up ship** currently stays gone until the next restart (then respawns at the saved leg).
  If a mid-session respawn is wanted, add a destroyed→timer→respawn path.

---

## Phased plan

- **Phase 1 — v1 (owner-scoped, coded).** The ship sails the route normally and HALTS while any
  player is within **300m** (30-min anti-loiter cap); resume-on-restart; trackable on the map
  (`ship.json`). *Accept:* ship appears, sails the loop visibly, stops when a player comes
  within 300m and resumes when they leave (or the cap expires), resumes at the right leg after
  a restart, no RPT script errors, players still connect.
- **Phase 2 — robustness.** Real `IsWater`; lock it; dwell at towns; waypoints from
  `waypoints.json`; author the real Sakhal route; tune halt radius/cap from play. *Accept:*
  pauses at towns, never beaches, can't be boarded, route editable without a rebuild.
- **Phase 4 — reward for sinking it.** Detect destruction → grant a reward (Expansion market
  money / an item cache / a quest hook). *Accept:* blowing it up pays out once, no dupes.
- **Phase 5 — teleport (optional).** NPC/sign/command ship↔town, cooldown + safe deck target +
  teleport-to-current-position (the ship moves). *Accept:* lands safely, abuse-guarded.

---

## Enabling + deploying (when ready to TEST — not while staging)

1. Set `ShipPatroller.ENABLED = true`.
2. Wire it into loading (currently NOT wired, on purpose):
   - Add `@flying_dutchman` to the unit `ExecStart` `-serverMod` chain
     (`DayZ-Server/deploy/dayz-server.service`).
   - Add `serverMods/FlyingDutchman/.hemttout/build/addons/FlyingDutchman_main.pbo` to
     the two PBO lists in `DayZ-Server/Deploy-DayZServer.ps1` (pre-flight check + ship list).
   - The deploy must place the PBO under `@flying_dutchman/addons/` on the box.
3. `hemtt build`, commit (prod `-Fix` needs a clean tree), `Deploy-DayZServer.ps1 -Fix -Env prod`.
4. Test on the box (zero population): watch the RPT for script-compile errors, confirm players
   connect, confirm the ship spawns and moves, then `state.json` after a restart. Keep the prior
   state to roll back (revert the flag + redeploy).

The DayZ server only runs on prod — there's no local instance — so testing = deploy + restart.

---

## Open decisions for the owner

1. **Route** — which coastal towns, how many stops, rough loop time?
2. **Lock method** — Expansion vehicle-lock vs CodeLock vs just refuse driver entry?
3. **Reward for sinking** — Expansion market money? an item cache on the wreck? a quest?
4. **Teleport (Phase 5)** — NPC on deck + NPC in town? signs? a command? or skip it?
5. **Halt radius / 30-min cap** — nudge around the player, or just resume through after the cap?
6. Map overlay — plot the ship on the ConfigViewer map (mirror the LiveTracker chain)?
