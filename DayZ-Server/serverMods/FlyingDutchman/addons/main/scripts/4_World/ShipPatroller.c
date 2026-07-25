// ShipPatroller — the patrol brain for FlyingDutchman.
//
// DORMANT by default (ENABLED = false): ships inert, does NOTHING (no spawn, no tick) until the
// flag is flipped AND the mod is added to the -serverMod chain. Keep it off while staging.
//
// The ship MOVES along hand-placed water waypoints — a few metres per 1s tick via SetPosition,
// which clients read as sailing. This is movement, not teleporting ("teleport" in this project
// refers ONLY to the player boarding feature: getting on/off a ship that's offshore). It is
// also deliberately NOT engine driving: no fuel, no driver, no reliance on DayZ's (absent)
// autonomous boat AI. The ship is DESTRUCTIBLE (players may blow it up — reward hook is a later
// feature) and should be locked against hijack. Last position + leg persist to
// $profile:FlyingDutchman/state.json so a restart resumes where it left off.
//
// TRACKABLE: every ~20s the tick writes $profile:FlyingDutchman/ship.json
// ([{x,z,state}], [] while no ship is alive — mtime is the heartbeat), mirroring the
// LiveTracker file convention so the ConfigViewer map can plot the ship as its own live layer.
// Deliberately a FILE convention, not a LiveTracker class dependency: ship code must never be
// able to break the proven tracker mod.
//
// UNTESTED PROTOTYPE: hemtt does not compile Enforce script, so this is validated only by review
// until the mod is actually loaded on the box. Genuinely uncertain engine calls (a water test,
// the lock) are STUBBED with TODOs so the class compiles cleanly; confirm signatures against the
// DayZ-Modding-Wiki (06-engine-api/02-vehicles.md, 19-terrain-queries.md) before enabling.

class ShipWaypoint
{
    float  x;         // east  (map X)
    float  z;         // north (map Z)
    int    dwellSec;  // seconds to hold here (0 = pass through)
    string label;     // town/landmark, for logs
}

// Persisted state — a one-element array so it uses the same JsonFileLoader<array<...>> path the
// LiveTracker mod already proves out.
class ShipState
{
    float x;
    float z;
    int   leg;
}

// One map fix for the ship overlay (ship.json). state: "patrol" | "docked" | "halted".
// target = the waypoint label the ship is heading to (or holding before) — the map shows it.
class ShipFix
{
    float  x;
    float  z;
    string state;
    string target;
}

class ShipPatroller
{
    // ---- ENABLE SWITCH ---------------------------------------------------------------------
    // Set at boot by MissionServer.OnInit from the $profile:FlyingDutchman/enable marker file —
    // a per-box runtime switch, so the same PBO ships everywhere and only wakes where an
    // operator touched the marker. Default false = inert. Never hand-flip in code.
    static bool ENABLED = false;

    // ---- tunables (treat as constants) -----------------------------------------------------
    // Movement is VELOCITY-DRIVEN: each tick sets the hull's linear velocity toward the target
    // and lets the physics engine move it. This is the third movement design and the first one
    // clients can actually SEE: SetPosition teleports (1Hz and 10Hz both) never replicate to
    // clients for a crewless VEHICLE — players saw a frozen hull that "unloaded" when the real
    // position left their network bubble (owner-observed, staging 2026-07-24). Vehicle netcode
    // replicates the active physics simulation, so motion must come from the simulation:
    // SetVelocity + an awake body. Same calls Expansion's own vehicle-sync code uses
    // (Core/ItemBase.c: SetVelocity(other, car.m_State.m_LinearVelocity)).
    static string SHIP_CLASS   = "ExpansionLHD";  // verified Expansion ship class
    static int    TICK_MS      = 100;             // control cadence (10Hz); physics moves between ticks
    static float  CRUISE_MPS   = 6.0;             // commanded horizontal speed
    static float  REACH_METRES = 12.0;            // "arrived at waypoint" tolerance
    static float  HALT_RADIUS  = 300.0;           // v1 (owner): hold while any player is within 300m
    static int    HALT_MAX_SEC = 1800;            // 30-min cap on a player-forced halt (anti-loiter)
    static string SHIP_FILE    = "$profile:FlyingDutchman/ship.json";   // live output for the map overlay

    // ---- MAP-SPECIFIC route + state (set in Init from GetWorldName) --------------------------
    // Routes are per-world files: waypoints.<world>.json / state.<world>.json — coordinates only
    // mean anything on their own map, so a Sakhal route must never drive the ship on Enoch.
    // A world with NO route file (and no built-in) keeps the ship in port entirely.
    static string s_World;            // lowercased world name, e.g. "sakhal"
    static string s_WaypointsFile;    // $profile:FlyingDutchman/waypoints.<world>.json (EDITABLE)
    static string s_StateFile;        // $profile:FlyingDutchman/state.<world>.json
    static int    SNAPSHOT_EVERY_TICKS = 200;     // ship.json heartbeat (~20s at 10Hz), matching LiveTracker
    static int    HEARTBEAT_EVERY_TICKS = 600;    // RPT activity line every ~60s

    // ---- state -----------------------------------------------------------------------------
    private static EntityAI s_Ship;

    /** The live hull (null before spawn / after destruction) — ShipFerry boards onto it. */
    static EntityAI GetShip() { return s_Ship; }
    private static ref array<ref ShipWaypoint> s_Route;
    private static int  s_Leg = 0;            // current TARGET waypoint index
    private static int  s_DwellUntilSec = 0;
    private static int  s_HaltStartSec = 0;
    private static bool s_Halted = false;
    private static bool s_CapLogged = false;   // one log line per halt when the 30-min cap expires
    private static int  s_TickCount = 0;

    static int NowSec()
    {
        return (int)(GetGame().GetTime() / 1000);
    }

    // The route comes from the EDITABLE per-map box file: waypoints.<world>.json (same shape
    // route.json publishes: [{x,z,dwellSec,label},…]). Edit it on the box, restart the server,
    // done — no rebuild, no deploy. dwellSec > 0 makes the ship hold at that waypoint
    // ("docked"). The boot LogRouteEnvironment audit runs on WHATEVER route loads, so a bad
    // hand-edit shows in the RPT, and out-of-world points are skipped with a warning.
    //
    // Built-in fallback exists for SAKHAL ONLY — the round-3 deep lane (2026-07-24):
    // corridor-verified on the Sat (New) tiles (±100m, strict <60 brightness) AND probed clean
    // in-game, after rounds 1-2 each turned out to cross real ice. On Sakhal it also SEEDS the
    // waypoints file so there is always a file to edit. Any other world without a route file
    // gets an EMPTY route — Init then keeps the ship in port.
    private static void BuildRoute()
    {
        s_Route = new array<ref ShipWaypoint>();
        if (FileExist(s_WaypointsFile))
        {
            array<ref ShipWaypoint> fromFile = new array<ref ShipWaypoint>();
            JsonFileLoader<array<ref ShipWaypoint>>.JsonLoadFile(s_WaypointsFile, fromFile);
            if (fromFile)
            {
                foreach (ShipWaypoint w : fromFile)
                {
                    if (!w) continue;
                    if (w.x <= 0 || w.x >= 15360 || w.z <= 0 || w.z >= 15360)
                    {
                        Print("[FlyingDutchman] waypoints." + s_World + ".json: skipping out-of-world waypoint '" + w.label + "' (" + w.x + "," + w.z + ")");
                        continue;
                    }
                    s_Route.Insert(w);
                }
            }
            if (s_Route.Count() >= 2)
            {
                Print("[FlyingDutchman] route: " + s_Route.Count() + " waypoint(s) loaded from waypoints." + s_World + ".json");
                return;
            }
            Print("[FlyingDutchman] waypoints." + s_World + ".json unusable (fewer than 2 valid waypoints) — falling back");
            s_Route.Clear();
        }
        if (s_World != "sakhal")
            return;   // no built-in route for this map — Init keeps the ship in port
        AddWp(9150,  2300, 0, "deep-lane NW");
        AddWp(10950, 2300, 0, "deep-lane NE");
        AddWp(10950, 700,  0, "deep-lane SE");
        AddWp(9150,  700,  0, "deep-lane SW");
        if (!FileExist(s_WaypointsFile))
        {
            JsonFileLoader<array<ref ShipWaypoint>>.JsonSaveFile(s_WaypointsFile, s_Route);
            Print("[FlyingDutchman] seeded waypoints.sakhal.json with the built-in route — edit it + restart to change the path");
        }
    }

    // Publish the route for the map overlay (drawn as a dashed loop under the ship marker).
    private static void WriteRoute()
    {
        JsonFileLoader<array<ref ShipWaypoint>>.JsonSaveFile("$profile:FlyingDutchman/route.json", s_Route);
    }

    // DIAGNOSTIC v2 — how does Sakhal's sea ice actually manifest? (v1 matched "ice" as a
    // substring and proudly reported spruce trees: PiceaAbies. Never again.) Two honest probes:
    //  1. SURFACE material every ~200m along the route (SurfaceGetType — the same call
    //     ExpansionWreck.c uses). If the sea ice is terrain surface, its material name shows here.
    //  2. Unfiltered TOP object types near the route: a real ice OBJECT classname surfaces in
    //     the counts instead of being guessed at.
    private static void LogRouteEnvironment()
    {
        map<string, int> surfaces = new map<string, int>();
        map<string, int> types = new map<string, int>();
        for (int i = 0; i < s_Route.Count(); i++)
        {
            ShipWaypoint a = s_Route[i];
            ShipWaypoint b = s_Route[(i + 1) % s_Route.Count()];
            float legLen = vector.Distance(Vector(a.x, 0, a.z), Vector(b.x, 0, b.z));
            int steps = (int)(legLen / 200) + 1;
            for (int s = 0; s <= steps; s++)
            {
                float px = a.x + (b.x - a.x) * s / steps;
                float pz = a.z + (b.z - a.z) * s / steps;
                string surf;
                GetGame().SurfaceGetType(px, pz, surf);
                int c;
                if (surfaces.Find(surf, c)) surfaces.Set(surf, c + 1); else surfaces.Insert(surf, 1);
            }
            // object histogram at the corner + leg midpoint (radius 900 covers the corridor)
            for (int k = 0; k < 2; k++)
            {
                float ox = a.x;
                float oz = a.z;
                if (k == 1) { ox = (a.x + b.x) * 0.5; oz = (a.z + b.z) * 0.5; }
                array<Object> objects = new array<Object>();
                array<CargoBase> proxyCargos = new array<CargoBase>();
                GetGame().GetObjectsAtPosition3D(Vector(ox, 0, oz), 900, objects, proxyCargos);
                foreach (Object obj : objects)
                {
                    string t = obj.GetType();
                    if (t == "") continue;
                    int tc;
                    if (types.Find(t, tc)) types.Set(t, tc + 1); else types.Insert(t, 1);
                }
            }
        }
        foreach (string sName, int sCount : surfaces)
            Print("[FlyingDutchman] route surface: '" + sName + "' x" + sCount);
        int distinct = 0;
        foreach (string tName, int tCnt : types)
        {
            distinct++;
            if (tCnt >= 25)
                Print("[FlyingDutchman] route objects: " + tName + " x" + tCnt);
        }
        Print("[FlyingDutchman] route env: " + surfaces.Count() + " surface type(s), " + distinct + " distinct object type(s) (logged x25+)");
    }
    private static void AddWp(float x, float z, int dwellSec, string label)
    {
        ShipWaypoint w = new ShipWaypoint();
        w.x = x; w.z = z; w.dwellSec = dwellSec; w.label = label;
        s_Route.Insert(w);
    }

    static void Init()
    {
        if (!ENABLED) return;
        if (!GetGame() || !GetGame().IsServer()) return;
        MakeDirectory("$profile:FlyingDutchman");
        s_World = GetGame().GetWorldName();
        s_World.ToLower();
        s_WaypointsFile = "$profile:FlyingDutchman/waypoints." + s_World + ".json";
        s_StateFile     = "$profile:FlyingDutchman/state." + s_World + ".json";
        BuildRoute();
        if (!s_Route || s_Route.Count() < 2)
        {
            Print("[FlyingDutchman] no route for map '" + s_World + "' — ship stays in port (create waypoints." + s_World + ".json to enable)");
            ENABLED = false;   // the ferry and all ticks key off this too
            return;
        }
        WriteRoute();
        LoadState();
        LogRouteEnvironment();
        // Spawn is DEFERRED: persisted hulls from earlier runs stream in during world load and
        // register via the ExpansionLHD.c EEInit hook. 20s in, the registry holds every stray —
        // purge them all, then spawn the One Ship. (The old map-wide GetObjectsAtPosition3D
        // purge silently truncated at the engine's ~1024-result cap and missed them — ghosts at
        // old route positions, owner-observed.)
        Print("[FlyingDutchman] deferring spawn 20s — collecting persisted hulls for the purge");
        GetGame().GetCallQueue(CALL_CATEGORY_SYSTEM).CallLater(SpawnAfterWorldLoad, 20000, false);
    }

    // Every server-side ExpansionLHD reports here from EEInit (see ExpansionLHD.c) — spawned,
    // OR loaded back from vehicle persistence. Before the One Ship exists they queue for the
    // boot purge; after it exists, anything that isn't it is a late-streamed stray: delete on
    // sight, so hulls can never accumulate again no matter where persistence parks them.
    private static ref array<EntityAI> s_Hulls = new array<EntityAI>();
    static void RegisterHull(EntityAI hull)
    {
        if (!hull) return;
        if (s_Ship && hull != s_Ship)
        {
            Print("[FlyingDutchman] late-loaded stray " + SHIP_CLASS + " at " + hull.GetPosition().ToString() + " — deleting");
            GetGame().ObjectDelete(hull);
            return;
        }
        foreach (EntityAI known : s_Hulls)
            if (known == hull) return;
        s_Hulls.Insert(hull);
    }

    private static void SpawnAfterWorldLoad()
    {
        int purged = 0;
        foreach (EntityAI hull : s_Hulls)
        {
            if (!hull) continue;
            Print("[FlyingDutchman] purging stray hull at " + hull.GetPosition().ToString());
            GetGame().ObjectDelete(hull);
            purged++;
        }
        s_Hulls.Clear();
        Print("[FlyingDutchman] purge complete: " + purged + " stray hull(s) removed — the One Ship spawns now");
        Spawn();
    }

    private static vector LegPos(int leg)
    {
        if (!s_Route || leg < 0 || leg >= s_Route.Count()) return vector.Zero;
        ShipWaypoint w = s_Route[leg];
        return Vector(w.x, 0, w.z);
    }

    private static void Spawn()
    {
        vector pos = LegPos(s_Leg);
        // Boats: CREATEPHYSICS (buoyancy) + INITAI (start the engine simulation) — see the
        // vehicles wiki. NO PLACE_ON_SURFACE (that snaps to ground, not water).
        Object obj = GetGame().CreateObjectEx(SHIP_CLASS, pos, ECE_CREATEPHYSICS | ECE_INITAI);
        s_Ship = EntityAI.Cast(obj);
        if (!s_Ship)
        {
            Print("[FlyingDutchman] SPAWN FAILED: CreateObjectEx('" + SHIP_CLASS + "') returned null — is @expansionvehicles loaded?");
            return;
        }
        Print("[FlyingDutchman] spawned " + SHIP_CLASS + " at " + pos.ToString() + ", heading to '" + s_Route[s_Leg].label + "' (leg " + s_Leg + "/" + s_Route.Count() + ")");
        // Wake the physics body so buoyancy runs and the hull visibly floats (Expansion parks
        // static preview boats with ActiveState.INACTIVE — ACTIVE is the live state).
        dBodyActive(s_Ship, ActiveState.ACTIVE);
        LockShip(s_Ship);
    }

    // TODO: lock against boarding/hijack — Expansion vehicle lock (set locked, issue no key) or a
    // @codelock CodeLock attachment. Stubbed so the class compiles; the ship stays DESTRUCTIBLE.
    private static void LockShip(EntityAI ship) { }

    // TODO: real water test (terrain-queries.md: SurfaceY/GetSurface; a SurfaceIsSea may exist).
    // For now assume water so the prototype compiles — author waypoints on open water instead.
    private static bool IsWater(vector p) { return true; }

    static void Tick()
    {
        if (!ENABLED) return;
        // Map-overlay heartbeat runs regardless of the hull's fate: [] with a fresh mtime tells
        // the API "mod alive, no ship" — a dead file would read as mod-down instead.
        s_TickCount++;
        if (s_TickCount % SNAPSHOT_EVERY_TICKS == 0)
            WriteSnapshot();
        if (!s_Ship || !s_Ship.IsAlive()) return;   // destroyed/blown up → idle until next restart
        int now = NowSec();
        vector shipPos = s_Ship.GetPosition();

        // RPT activity heartbeat (~60s) — answers "is it actually moving?" from the log alone.
        if (s_TickCount % HEARTBEAT_EVERY_TICKS == 0)
        {
            float distLeft = vector.Distance(shipPos, LegPos(s_Leg));
            Print("[FlyingDutchman] " + CurrentState() + " at " + shipPos.ToString() + " -> '" + s_Route[s_Leg].label + "' (" + Math.Round(distLeft) + "m to go)");
        }

        // Hold for nearby players (never sail into/over them), capped at HALT_MAX_SEC.
        if (PlayerWithin(shipPos, HALT_RADIUS))
        {
            if (!s_Halted)
            {
                s_Halted = true;
                s_HaltStartSec = now;
                s_CapLogged = false;
                Print("[FlyingDutchman] HALT — player within " + HALT_RADIUS + "m at " + shipPos.ToString() + " (resumes when they leave, or after " + (HALT_MAX_SEC / 60) + "min)");
            }
            if (now - s_HaltStartSec < HALT_MAX_SEC) { HoldStill(); return; }   // within the loiter cap → hold
            if (!s_CapLogged)
            {
                s_CapLogged = true;
                Print("[FlyingDutchman] halt cap expired (" + (HALT_MAX_SEC / 60) + "min) — resuming despite nearby player");
            }
        }
        else if (s_Halted)
        {
            s_Halted = false;
            Print("[FlyingDutchman] resuming — no players within " + HALT_RADIUS + "m");
        }

        // Dwell at a town waypoint.
        if (s_DwellUntilSec > now) { HoldStill(); return; }

        vector target = LegPos(s_Leg);
        if (vector.Distance(shipPos, target) <= REACH_METRES)
        {
            ShipWaypoint w = s_Route[s_Leg];
            if (w.dwellSec > 0 && !s_Halted)
                s_DwellUntilSec = now + w.dwellSec;   // begin the stop
            NextLeg();
            Print("[FlyingDutchman] reached '" + w.label + "' — heading to '" + s_Route[s_Leg].label + "'");
            SaveState();
            return;
        }

        // Command cruise velocity toward the target and let PHYSICS move the hull. Vehicle
        // netcode replicates the active simulation (players can watch a pushed car roll);
        // it never replicates SetPosition teleports — both step designs before this froze
        // client-side. Same SetVelocity call Expansion's vehicle-sync glue uses (Core/ItemBase.c).
        vector dir = target - shipPos;
        dir[1] = 0;
        vector vel = GetVelocity(s_Ship);
        vector desired = dir.Normalized() * CRUISE_MPS;
        desired[1] = vel[1];                        // vertical belongs to buoyancy
        SetVelocity(s_Ship, desired);
        dBodyActive(s_Ship, ActiveState.ACTIVE);    // never let the body sleep mid-lane (sleep = frozen + unsynced)
        if (s_TickCount % 10 == 0)
        {
            vector ang = dir.VectorToAngles();
            s_Ship.SetOrientation(Vector(ang[0], 0, 0));   // yaw toward heading (1Hz; physics owns the rest)
            s_Ship.Update();
        }
    }

    // Kill horizontal way while holding (halt/dwell); vertical stays buoyancy's.
    private static void HoldStill()
    {
        if (!s_Ship) return;
        vector vel = GetVelocity(s_Ship);
        SetVelocity(s_Ship, Vector(0, vel[1], 0));
    }

    private static void NextLeg()
    {
        if (!s_Route || s_Route.Count() == 0) return;
        s_Leg = (s_Leg + 1) % s_Route.Count();   // loop the route
    }

    private static bool PlayerWithin(vector p, float radius)
    {
        array<Man> players = new array<Man>();
        GetGame().GetPlayers(players);
        foreach (Man man : players)
        {
            PlayerBase pb = PlayerBase.Cast(man);
            if (pb && pb.IsAlive() && vector.Distance(pb.GetPosition(), p) <= radius)
                return true;
        }
        return false;
    }

    // The map-overlay snapshot: [{x,z,state}] while the ship lives, [] once it's destroyed.
    private static void WriteSnapshot()
    {
        array<ref ShipFix> arr = new array<ref ShipFix>();
        if (s_Ship && s_Ship.IsAlive())
        {
            vector p = s_Ship.GetPosition();
            ShipFix f = new ShipFix();
            f.x = p[0];
            f.z = p[2];
            f.state = CurrentState();
            f.target = s_Route[s_Leg].label;
            arr.Insert(f);
        }
        JsonFileLoader<array<ref ShipFix>>.JsonSaveFile(SHIP_FILE, arr);
    }

    private static string CurrentState()
    {
        int now = NowSec();
        if (s_Halted && now - s_HaltStartSec < HALT_MAX_SEC) return "halted";   // holding for players
        if (s_DwellUntilSec > now) return "docked";                              // town stop
        return "patrol";
    }

    private static void SaveState()
    {
        if (!s_Ship) return;
        vector p = s_Ship.GetPosition();
        ShipState st = new ShipState();
        st.x = p[0]; st.z = p[2]; st.leg = s_Leg;
        array<ref ShipState> arr = new array<ref ShipState>();
        arr.Insert(st);
        JsonFileLoader<array<ref ShipState>>.JsonSaveFile(s_StateFile, arr);
    }

    // Restore the patrol leg from disk so a restart resumes where it left off. Spawn() then places
    // the hull at that leg's waypoint. NOTE: s_Leg is the TARGET leg, so a mid-leg restart places
    // the ship at the waypoint it was heading TOWARD (slightly ahead, never backward). Using the
    // saved x/z for an exact mid-leg resume is a Phase-2 TODO.
    private static void LoadState()
    {
        if (!FileExist(s_StateFile))
            return;   // first boot — no state yet, start at leg 0
        array<ref ShipState> arr = new array<ref ShipState>();
        JsonFileLoader<array<ref ShipState>>.JsonLoadFile(s_StateFile, arr);
        if (arr && arr.Count() > 0)
            s_Leg = arr[0].leg;
        if (!s_Route || s_Leg < 0 || s_Leg >= s_Route.Count())
            s_Leg = 0;   // route changed/corrupt state → start over safely
    }
}
