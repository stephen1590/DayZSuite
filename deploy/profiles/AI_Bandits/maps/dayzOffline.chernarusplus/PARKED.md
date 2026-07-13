# PARKED — Chernarus bandits (come back to this)

**Status:** kept in the project, **not deployed.** The `$items` ship line for this folder's
`DynamicAIB.json` was removed from `Deploy-DayZServer.ps1` on 2026-07-12, so nothing here reaches
the server. The server currently runs **Sakhal only**, whose dynamic spawns come from VPP.

**Why it's kept:** `DynamicAIB.json` is a complete, working compose-schema bandit config
(groups + snipers) with third-party coordinates and license attribution — see `SOURCE.md`. No
reason to throw it away; it's ready to go if Chernarus ever comes back.

**To reactivate:**

1. Re-add the Chernarus `DynamicAIB.json` entry to `$items` in `Deploy-DayZServer.ps1`.
2. Set `DAYZ_MISSION=dayzOffline.chernarusplus` in `map.env` and restart.
3. `Build-AIBandits.ps1` composes it for that mission at prestart; Sakhal/VPP is untouched.

**To revisit (the coordinate-only question):** Chernarus is authored/coordinate-based, **not**
VPP-driven — there are no `C_...` VPP bookmarks for it. If it's ever reactivated, decide whether
to bring it under the VPP "one source of truth" model (capture `C_...` bookmarks, let the mirror
drive it) or keep it as a standalone authored map. That's the trade-off that motivated the
CoordinateOnly setup in the first place.
