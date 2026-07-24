# Persistent Coastal Patrol Ship — implementation plan

**Status:** PLAN ONLY — not started. This is a self-contained handoff so any agent (or the
owner) can pick it up. Read it top to bottom before writing code.

**Goal:** one persistent Expansion ship that patrols the Sakhal coast on water, pausing
outside major coastal towns, lockable so it can't be stolen, halting for nearby players.
Eventually: a way to teleport between the ship and towns.

---

## 0. The one constraint that shapes everything

**DayZ has no native boat AI.** `BoatScript` has no pathfinding and no autonomous driving —
the engine's vehicle controls (`SetThrust`/`SetSteering`/`SetBrake`) are player-input only.
Confirmed against `Public/DayZ-Modding-Wiki/en/06-engine-api/02-vehicles.md`.

**Therefore the patrol is WAYPOINT-TELEPORT, not a physics sim.** Each server tick, the mod
nudges the ship a few metres toward the next waypoint with `SetOrigin`/`SetPosition`; clients
interpolate the small steps into smooth-ish motion. This is the load-bearing design decision —
every requirement below assumes it. "Real sailing" is out of scope and not achievable.

---

## 1. Verified givens (don't re-derive)

| Fact | Value | Source |
|---|---|---|
| Ship class | **`ExpansionLHD`** (the big one). Also `ExpansionBoat`, `ExpansionUtilityBoat`, `ExpansionZodiacBoat` | `DayZ-Server/config-defaults/profiles/ExpansionMod/Settings/VehicleSettings.defaults.json` |
| Map | Sakhal, world size **~15360** (not 12800 — see `DayZ-Server/CLAUDE.md` gotchas) | live `-mission=mpmissions/dayzOffline.sakhal` |
| Lock mod | `@codelock` is loaded | `DayZ-Server/deploy/mods.conf` |
| Home mod | **`CustomServerMods`** (ours, server-only, hemtt-built). New code goes in `addons/main/scripts/4_World/ShipPatroller.c` | this dir |
| Tick pattern | `MissionServer.OnInit` → `GetCallQueue(CALL_CATEGORY_SYSTEM).CallLater(fn, ms, true)` | `addons/main/scripts/5_Mission/MissionServer.c` |
| Precedent to copy | **`LiveTracker.c`** (same mod) — a static class + a MissionServer tick that reads/writes `$profile:` JSON. The ship is the same shape plus entity spawn + movement. | `addons/main/scripts/4_World/LiveTracker.c` |

**Enforce API references** (confirm exact signatures here before using — do NOT trust memory):
- Spawn / flags / `EOnSimulate`: `Public/DayZ-Modding-Wiki/en/06-engine-api/02-vehicles.md`
- `SetPosition`/`SetOrigin`/`SetOrientation`: `.../06-engine-api/01-entity-system.md`
- Water detection, raycast, object queries: `.../06-engine-api/19-terrain-queries.md`

---

## 2. Architecture

One new class `ShipPatroller` + a hook in the existing `MissionServer`:

- `MissionServer.OnInit()` (after the existing `LiveTracker` setup): `ShipPatroller.Spawn()`,
  then a **dedicated movement tick** — `CallLater(ShipPatroller.Tick, 1000, true)` (~1s;
  the 20s LiveTracker cadence is far too coarse for motion). Keep it a *direct method
  reference*, never `Timer.Run(this,...)` — see the MissionServer.c comment on why (it
  corrupts the modded MissionServer chain and disables player connect).
- `ShipPatroller` holds: the ship entity ref, the waypoint list, current-leg index, a state
  enum (`PATROL` / `DWELL` / `HALT`), and timers.

**Persistence decision (recommended): spawn NON-persistent, fresh each boot.** Persisting the
ship risks duplicates accumulating across restarts (a classic object-spawner bug). Spawn one
on every `OnInit`; it lives for the session only and the next restart makes a new one. If a
persistent ship is truly wanted later, that needs a find-existing-by-tag guard on boot — defer.

---

## 3. Data model

```
class ShipWaypoint { float x; float z; int dwellSec; string label; }   // z = engine north
```
- v1: **hardcode** 4–6 waypoints in the class (fast PoC). v2: load from
  `$profile:ShipPatrol/waypoints.json` so they're editable without a rebuild (same
  `JsonFileLoader` pattern LiveTracker uses; `MakeDirectory` first — JsonSaveFile/Load won't
  create parents).
- Waypoints must sit in **open water** off the coast, not on terrain. Author them by reading
  coords off the ConfigViewer map (the same map this whole project builds).

---

## 4. Per-requirement design

| # | Requirement | Mechanism | Effort | Risk |
|---|---|---|---|---|
| 1 | Single persistent ship | `GetGame().CreateObject`/`CreateObjectEx("ExpansionLHD", pos, ECE_PLACE_ON_SURFACE\|ECE_CREATEPHYSICS)` in `OnInit`. Hold the ref. | **S** | Low |
| 2 | Water patrol + avoid terrain | On each tick, step `SetOrigin` a few m toward the next waypoint; before committing, validate the target cell is water (`SurfaceIsSea`/water-depth query, terrain-queries.md). Straight legs between hand-placed water waypoints = collision avoidance by *authoring*, not runtime pathfinding. | **M** | Waypoints must be careful; a bad one beaches the ship |
| 3 | Stop outside towns | At a waypoint with `dwellSec>0`, enter `DWELL`, hold position, resume after the timer. Simple state machine. | **S** | Low |
| 4 | Teleport ship↔town (signs/NPC) | **Deferred to last.** Options: (a) an Expansion NPC/trader-style interactable, (b) a placed sign object with an attached action, (c) a chat command. All need custom Enforce + anti-abuse (cooldown, no-teleport-in-combat) + handling the ship having MOVED between request and arrival (teleport to the ship's *current* pos, and to a fixed safe deck point). | **M–L** | Highest complexity; desync + abuse |
| 5 | Lock (no theft/hijack) | Since the ship is script-moved, players shouldn't drive it anyway. Belt+braces: set it locked via Expansion vehicle lock at spawn (no key issued) and/or attach a `@codelock` CodeLock with an unknown code; also consider refusing driver-seat entry in a hook. | **S** | Low (proven mod) |
| 6 | Halt for nearby players (≤30 min) | Each tick, query players within R metres (`GetGame().GetPlayers()` + distance, or `GetObjectsAtPosition3D`). If any inside R → state `HALT`, stop teleporting (so it never shoves/collides a player). Track halt start; after **30 min** force-resume even if a player loiters (anti-grief). | **M** | Loiter-abuse; pick R so it doesn't halt on distant players |

---

## 5. Movement sketch (verify signatures against the wiki)

```
static void Tick()
{
    if (!s_Ship || !s_Ship.IsAlive()) return;          // ship gone → optionally respawn

    if (PlayerWithin(s_Ship.GetPosition(), HALT_RADIUS)) { EnterHalt(); return; }
    if (s_State == HALT && HaltExpired(HALT_MAX_SEC)) ResumePatrol();
    if (s_State == DWELL) { if (DwellExpired()) NextLeg(); else return; }

    vector shipPos = s_Ship.GetPosition();
    vector target  = WaypointPos(s_Leg);
    vector step    = MoveToward(shipPos, target, STEP_METRES);   // clamp to leg
    if (!IsWater(step)) { /* skip / hold / log — waypoint authoring bug */ return; }
    s_Ship.SetOrigin(step);                                       // small step → clients interp
    FaceHeading(s_Ship, target);                                 // SetOrientation toward target
    if (Reached(step, target)) { if (Dwell(s_Leg) > 0) EnterDwell(); else NextLeg(); }
}
```
Notes: keep `STEP_METRES` small relative to a 1s tick (a few m) so motion reads as smooth, not
teleporty. `SetOrigin` vs `SetPosition`: `SetOrigin` bypasses some placement snapping — test
both on water. `ECE_CREATEPHYSICS` matters for buoyancy; test whether repeated `SetOrigin`
fights physics (may need to disable/re-enable simulation, or `SetOrigin` only).

---

## 6. Risks & gotchas

- **Modded MissionServer is fragile.** A script error here can cascade to "player connect
  disabled" (see MissionServer.c comment). Add ship logic behind `IsServer()` and defensive
  null-checks; keep it in `ShipPatroller`, call it from a thin tick, so a throw can't kill the
  spawn/flu-buff paths. **hemtt does NOT compile Enforce** — errors only surface on server load,
  so test on a restart with the RPT open.
- **Duplicate ships** across restarts — the reason for the non-persistent recommendation.
- **Desync** — large entity teleporting every tick can rubber-band on clients. Small steps
  mitigate; if bad, lengthen the tick + interpolate, or accept visible "hops."
- **Physics fights teleport** — a floating vehicle with active physics may drift/tip when you
  `SetOrigin`. May need to zero velocity each step or manage simulation state.
- **Teleport abuse** (point 4) — cooldown, block in combat/raid, fixed safe deck target.
- **Waypoints on terrain** beach the ship — water-validate at author time AND runtime.

---

## 7. Phased plan (each phase = its own build + deploy + verify)

- **Phase 0 — decisions (owner, below).** Boat model, waypoint count/route, teleport mechanism,
  persistence, lock method.
- **Phase 1 — PoC (spawn + move + lock).** Spawn `ExpansionLHD` at a fixed water point; 3–4
  hardcoded waypoints; 1s tick stepping via `SetOrigin`; lock it. *Accept:* ship appears on
  water, loops the waypoints visibly, can't be entered/stolen, no RPT script errors, players
  still connect.
- **Phase 2 — robustness.** Dwell at town waypoints; runtime water validation; waypoints from
  `waypoints.json`; heading/orientation. *Accept:* pauses at towns, never beaches, route
  editable without rebuild.
- **Phase 3 — player interaction.** Halt within radius + 30-min cap; collision-safe. *Accept:*
  ship stops for an approaching player and resumes, loiter cap works.
- **Phase 4 — teleport (optional, last).** NPC/sign/command ship↔town with cooldown + safe
  target. *Accept:* teleport lands on the ship's current position safely, abuse-guarded.

Plot the ship on the ConfigViewer map for free: it's an `ExpansionLHD` entity, so if desired,
add it to the `LiveTracker` AI/registry export (or a new `ships.json`) — the map already draws
live-position layers.

---

## 8. Build / deploy / test

- Build: `cd DayZ-Server/serverMods/CustomServerMods && hemtt build` → `.hemttout/build/addons/CustomServerMods_main.pbo`. Two warnings (Arma 3 Tools, INVALID-PBOPREFIX) are expected/harmless.
- Deploy: `DayZ-Server/Deploy-DayZServer.ps1 -Fix -Env prod` ships the PBO + restarts. **Prod `-Fix` refuses a dirty tree / non-main branch — commit first.** No web deploy needed unless the map gets a ship layer (then Api + ConfigViewer).
- **The DayZ server only runs on the prod VPS** — there's no local/staging DayZ instance, so mod testing = deploy to prod + restart (do it at zero population; server is often empty). Immediately check the RPT for script-compile errors and that players can still connect. Keep the previous PBO backed up on the box for instant rollback.
- Respect the repo rule: **never build/ship `serverMods` PBOs unless explicitly asked** — the source may be mid-edit.

---

## 9. Open decisions for the owner (Phase 0)

1. **Which boat** — `ExpansionLHD` (big, imposing, slow) or a smaller `ExpansionUtilityBoat`?
2. **Route** — how many stops, which coastal towns, roughly how long a full loop?
3. **Teleport** — NPC on the ship + NPC in town? Signs? A chat command? Or drop point 4 for now?
4. **Persistence** — fresh-per-restart (recommended) or a single persistent hull?
5. **Lock** — Expansion vehicle-lock (no key) vs CodeLock vs just refusing driver entry?
6. **Halt radius** and whether the 30-min cap should nudge the ship *around* the player or just resume through.

---

## 10. Handoff notes

- Copy the **`LiveTracker` + MissionServer tick** pattern — it's the proven shape in this mod.
- `CustomServerMods` is **split** into `addons/main` (live) and `addons/bandits` (dormant,
  only with `@aibandits`). Put ship code in **`main`**. Don't weld addons together — it SEGV'd
  the box before (see `addons/main/config.cpp`).
- Everything server-only: no client ever downloads this mod, so no signing, no client UI unless
  you add an interactable the client already has (Expansion NPC/action).
- If you add a map layer for the ship, mirror the `LiveTracker` → `dayz-ctl` → `actions.ts` →
  `map.js` chain already in place for players/AI.
