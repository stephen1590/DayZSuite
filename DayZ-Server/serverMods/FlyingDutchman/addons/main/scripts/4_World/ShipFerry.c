// ShipFerry — the linked boarding pads: a SHORE marker that teleports you onto the ship's
// deck, and a DECK pad that teleports you back ashore. Intrinsically linked: the return
// drops you at the shore, the shore sends you to wherever the ship IS.
//
// Interaction is a PROXIMITY PAD, not an action menu: a server-only mod cannot add client
// action entries, so "talk to the sign" becomes "stand at the sign" — walk within PAD_RADIUS,
// hold still through a DWELL_SEC countdown (Expansion notifications count you down), teleport.
//
// THE SHIP KEEPS MOVING — the deck point is computed in the ship's MODEL space and converted
// with ModelToWorld() at the instant of teleport, so boarding lands on the deck wherever the
// hull is. And the deck HEIGHT is not guessed: a downward raycast finds the real flight-deck
// surface (guessing the height risked boarding inside/above the hull — the owner had trouble
// with the in-game ladder, so the landing must be reliable). In practice the ship will usually
// be HALTED when you arrive — you teleport within its 300m player-halt radius.
//
// The shore marker is a vanilla TerritoryFlag pole (tall, unmissable, on every client). Its
// x/z is published to ferry.json so the ConfigViewer map marks "board here".

// One shore boarding pad — published to ferry.json for the map overlay.
class ShipDock
{
    float  x;
    float  z;
    string label;
}

class ShipFerry
{
    // ---- owner-tunable test constants --------------------------------------------------------
    static vector SIGN_POS      = "13627.42 0 5124.00";   // demo island, east coast — inside the patrol loop
    static vector SHORE_ARRIVAL = "13612.40 0 5139.00";   // return landing: dry land just inland of the pole
    // Deck points in ship MODEL space (x = beam, y = height HINT, z = along keel). The Y is only
    // a fallback hint now — DeckLanding() raycasts the real deck height at teleport time.
    static float  DECK_Y_HINT     = 16.0;
    static vector DECK_ARRIVAL_MS = "0 16.0 -30";   // boarding landing: aft, clear of the island/tower
    static vector DECK_PAD_MS     = "0 16.0 25";    // RETURN pad: fore of center (~55m from arrival)
    static float  PAD_RADIUS   = 3.5;               // stand this close…
    static int    DWELL_SEC    = 3;                 // …for this long
    static int    COOLDOWN_SEC = 15;                // per-player, blocks pad ping-pong
    static int    TICK_MS      = 500;               // ferry scan cadence
    static float  DECK_Y_BAND  = 8.0;               // vertical slack for "on the deck pad" (deck-height uncertainty)
    static string FERRY_FILE   = "$profile:FlyingDutchman/ferry.json";

    private static Object s_Sign;
    private static ref map<string, int> s_Dwell = new map<string, int>();      // playerId -> ticks on a pad
    private static ref map<string, int> s_Cooldown = new map<string, int>();   // playerId -> NowSec deadline

    static void Init()
    {
        if (!ShipPatroller.ENABLED) return;
        // Remove any TerritoryFlag already at the configured spot (a persisted/duplicate pole from
        // a prior boot), then spawn exactly ONE fresh — no stacking. Deletes flags within range of
        // SIGN_POS ONLY; safe because the ferry runs solely on an enable-marked box (staging demo,
        // no player territories). MUST be revisited before any server with player base flags.
        array<Object> objects = new array<Object>();
        array<CargoBase> proxyCargos = new array<CargoBase>();
        GetGame().GetObjectsAtPosition3D(SIGN_POS, 15, objects, proxyCargos);
        int removed = 0;
        foreach (Object obj : objects)
        {
            if (obj.GetType() == "TerritoryFlag") { GetGame().ObjectDelete(obj); removed++; }
        }
        if (removed > 0)
            Print("[FlyingDutchman] ferry: cleared " + removed + " existing pole(s) at the marker spot");

        vector pos = SIGN_POS;
        pos[1] = GetGame().SurfaceY(pos[0], pos[2]);
        s_Sign = GetGame().CreateObjectEx("TerritoryFlag", pos, ECE_PLACE_ON_SURFACE);
        if (s_Sign)
            Print("[FlyingDutchman] ferry: shore marker at " + s_Sign.GetPosition().ToString());
        else
            Print("[FlyingDutchman] ferry: FAILED to spawn shore marker at " + pos.ToString());
        WriteFerryMarker();
    }

    // Publish the shore pad to ferry.json so the map marks "board here".
    private static void WriteFerryMarker()
    {
        array<ref ShipDock> docks = new array<ref ShipDock>();
        ShipDock d = new ShipDock();
        vector p = s_Sign ? s_Sign.GetPosition() : SIGN_POS;
        d.x = p[0];
        d.z = p[2];
        d.label = "Board the Flying Dutchman";
        docks.Insert(d);
        JsonFileLoader<array<ref ShipDock>>.JsonSaveFile(FERRY_FILE, docks);
    }

    // Find the ACTUAL deck surface under a horizontal deck point by raycasting straight down.
    // Casts from above the tallest point of the hull (collision-box top) to just below its
    // origin; the first solid hit is the deck. Falls back to the model-space point if nothing
    // is hit. Same raycast Expansion's base-building hologram uses (ObjIntersectView).
    private static vector DeckLanding(EntityAI ship, vector deckXZ)
    {
        float shipY = ship.GetPosition()[1];
        float top = 30.0;
        vector minMax[2];
        if (ship.GetCollisionBox(minMax))
            top = minMax[1][1] + 3.0;   // just above the island/tower
        vector from = Vector(deckXZ[0], shipY + top, deckXZ[2]);
        vector to   = Vector(deckXZ[0], shipY - 5.0, deckXZ[2]);
        vector hitPos, hitDir;
        int hitComp;
        set<Object> hitObjects = new set<Object>();
        bool hit = DayZPhysics.RaycastRV(from, to, hitPos, hitDir, hitComp, hitObjects, null, null, true, false, ObjIntersectView);
        if (hit)
        {
            Print("[FlyingDutchman] ferry: deck raycast found deck at +" + (hitPos[1] - shipY) + "m above hull origin");
            return Vector(hitPos[0], hitPos[1] + 0.3, hitPos[2]);
        }
        Print("[FlyingDutchman] ferry: deck raycast MISS — model-space fallback (+" + DECK_Y_HINT + "m)");
        return deckXZ;
    }

    // Horizontal proximity + a vertical tolerance (the deck height isn't exact, so a pure 3D
    // distance would make the deck pad unreachable if the guess were off).
    private static bool NearPad(vector a, vector b)
    {
        float dx = a[0] - b[0];
        float dz = a[2] - b[2];
        return (dx * dx + dz * dz) <= PAD_RADIUS * PAD_RADIUS && Math.AbsFloat(a[1] - b[1]) <= DECK_Y_BAND;
    }

    static void Tick()
    {
        if (!ShipPatroller.ENABLED || !s_Sign) return;
        int now = ShipPatroller.NowSec();
        EntityAI ship = ShipPatroller.GetShip();

        array<Man> players = new array<Man>();
        GetGame().GetPlayers(players);
        foreach (Man man : players)
        {
            PlayerBase pb = PlayerBase.Cast(man);
            if (!pb || !pb.IsAlive() || !pb.GetIdentity()) continue;
            string id = pb.GetIdentity().GetId();

            int until;
            if (s_Cooldown.Find(id, until) && now < until) continue;

            vector ppos = pb.GetPosition();
            bool onShorePad = NearPad(ppos, s_Sign.GetPosition());
            bool onDeckPad = false;
            if (!onShorePad && ship && ship.IsAlive())
                onDeckPad = NearPad(ppos, ship.ModelToWorld(DECK_PAD_MS));

            if (!onShorePad && !onDeckPad)
            {
                s_Dwell.Set(id, 0);
                continue;
            }

            // Boarding with no ship afloat: say so instead of silently counting.
            if (onShorePad && (!ship || !ship.IsAlive()))
            {
                ExpansionNotification("Flying Dutchman", "The ship is lost at sea — no boarding until the next sailing.").Error(pb.GetIdentity());
                s_Cooldown.Set(id, now + COOLDOWN_SEC);
                continue;
            }

            int ticks;
            if (!s_Dwell.Find(id, ticks)) ticks = 0;
            ticks++;
            s_Dwell.Set(id, ticks);

            int needTicks = DWELL_SEC * 1000 / TICK_MS;
            int wholeSecondsLeft = DWELL_SEC - (ticks * TICK_MS / 1000);
            if (ticks % (1000 / TICK_MS) == 0 && wholeSecondsLeft > 0)
            {
                if (onShorePad)
                    ExpansionNotification("Flying Dutchman", "Boarding in " + wholeSecondsLeft + "…").Info(pb.GetIdentity());
                else
                    ExpansionNotification("Flying Dutchman", "Going ashore in " + wholeSecondsLeft + "…").Info(pb.GetIdentity());
            }
            if (ticks < needTicks) continue;

            s_Dwell.Set(id, 0);
            s_Cooldown.Set(id, now + COOLDOWN_SEC);
            if (onShorePad)
            {
                // Deck point computed NOW — the ship may have sailed since the countdown began —
                // then the height is raycast onto the real deck.
                vector deck = DeckLanding(ship, ship.ModelToWorld(DECK_ARRIVAL_MS));
                pb.SetPosition(deck);
                ExpansionNotification("Flying Dutchman", "Welcome aboard. To leave: stand on the FORE deck pad a few seconds.").Info(pb.GetIdentity());
                Print("[FlyingDutchman] ferry: boarded player at " + deck.ToString());
            }
            else
            {
                vector shore = SHORE_ARRIVAL;
                shore[1] = GetGame().SurfaceY(shore[0], shore[2]) + 0.3;
                pb.SetPosition(shore);
                ExpansionNotification("Flying Dutchman", "Ashore. The marker pole takes you back aboard.").Info(pb.GetIdentity());
                Print("[FlyingDutchman] ferry: returned player ashore at " + shore.ToString());
            }
        }
    }
}
