// The live position tracker + snapshot writer.
//
// (Formerly AIB_Tracker — renamed 2026-07-24. It never only tracked AI Bandits: it tracks
// the Expansion eAI tree and, as of this rename, connected PLAYERS and the world clock too.
// AIBandits are retired, so the old name was a misnomer.)
//
// AI is kept in a registry: the per-class hooks (eAIBase.c here in main; InfectedBanditBase.c
// in the split-off bandits addon) call Register/Unregister, because we need per-entity spawn
// metadata (type, age) the entity can't cheaply give back. Players need NO registry —
// GetGame().GetPlayers() IS the live server roster. The MissionServer tick calls the three
// Write* methods every 20s; they write to $profile:LiveTracker/ for the API to read:
//   ai.json      [{x,z,type,age}]  — living NPCs (eai, and bandit when @aibandits is on)
//   players.json [{x,z}]           — connected players, ANONYMIZED (no id/name/GUID ever)
//   time.json    [{year,month,day,hour,minute}]  — the in-game world clock

class LivePoint
{
    float  x;      // east  — map X, matches the player overlay so both layers align
    float  z;      // north — map Z (engine Y = elevation, dropped)
    string type;   // "bandit" (InfectedBanditBase) | "eai" (eAIBase)
    int    age;    // seconds this NPC has been alive at snapshot time (session clock)
}

// A player fix — position ONLY. No id, name, or GUID is ever written, so nothing identifying
// leaves the box (the same anonymized contract the API's player overlay already promised).
class LivePlayerPoint
{
    float x;
    float z;
}

// The in-game world clock at snapshot time. Feeds the API's world-time stat. Written as a
// one-element array so it uses the SAME proven JsonFileLoader<array<...>> path as the others.
class LiveClock
{
    int year;
    int month;
    int day;
    int hour;
    int minute;
}

// One live NPC + the metadata we can't read back off the entity cheaply.
class LiveEntry
{
    EntityAI ent;
    string   type;
    int      spawnSec;   // session-clock seconds at spawn; age = now - spawnSec at write
}

class LiveTracker
{
    // Live NPCs, kept in sync by the EEInit/EEDelete hooks. Array (not set) because we store
    // a metadata record per entity, not the bare ref; membership stays deduped on Register.
    private static ref array<ref LiveEntry> s_Live = new array<ref LiveEntry>();

    // Session-clock seconds. GetTime() is milliseconds since the game started, so it resets
    // every restart — age is "seconds alive THIS session", not wall-clock. Good enough for a
    // live snapshot the map redraws every 20s; documented as such in the API describe.
    static int NowSec()
    {
        return (int)(GetGame().GetTime() / 1000);
    }

    static void Register(EntityAI ent, string type)
    {
        if (!ent)
            return;
        // Guard against a double EEInit registering the same entity twice.
        foreach (LiveEntry existing : s_Live)
            if (existing.ent == ent)
                return;
        LiveEntry rec = new LiveEntry();
        rec.ent = ent;
        rec.type = type;
        rec.spawnSec = NowSec();
        s_Live.Insert(rec);
    }

    static void Unregister(EntityAI ent)
    {
        for (int i = s_Live.Count() - 1; i >= 0; i--)
        {
            if (s_Live[i].ent == ent)
            {
                s_Live.Remove(i);
                return;
            }
        }
    }

    // Snapshot of LIVING NPCs as [{"x":..,"z":..,"type":..,"age":..}], pruning dead/deleted
    // as it goes. GetPosition() = <X, Y, Z> with Y = elevation; we keep p[0] (east) and
    // p[2] (north) — the SAME (x,z) the map plots and the player overlay uses.
    static void WriteAiSnapshot(string path)
    {
        int now = NowSec();
        array<ref LivePoint> pts = new array<ref LivePoint>();
        for (int i = s_Live.Count() - 1; i >= 0; i--)
        {
            LiveEntry e = s_Live[i];
            EntityAI ent = e.ent;
            if (!ent || !ent.IsAlive())
            {
                s_Live.Remove(i);   // corpse or GC'd — drop it, it's not an ACTIVE NPC
                continue;
            }
            vector p = ent.GetPosition();
            LivePoint pt = new LivePoint();
            pt.x = p[0];
            pt.z = p[2];
            pt.type = e.type;
            pt.age = now - e.spawnSec;
            pts.Insert(pt);
        }
        JsonFileLoader<array<ref LivePoint>>.JsonSaveFile(path, pts);
    }

    // Snapshot of connected players, ANONYMIZED to {x,z}. GetPlayers() is the live server
    // roster (the same call the vanilla admin log uses), so no registry is needed — this is
    // why players update every 20s instead of on the .ADM's minutes-scale cadence.
    static void WritePlayerSnapshot(string path)
    {
        array<Man> players = new array<Man>();
        GetGame().GetPlayers(players);
        array<ref LivePlayerPoint> pts = new array<ref LivePlayerPoint>();
        foreach (Man man : players)
        {
            PlayerBase pb = PlayerBase.Cast(man);
            if (!pb || !pb.IsAlive())
                continue;   // lobby/connecting/dead have no meaningful live position
            vector p = pb.GetPosition();
            LivePlayerPoint pt = new LivePlayerPoint();
            pt.x = p[0];
            pt.z = p[2];
            pts.Insert(pt);
        }
        JsonFileLoader<array<ref LivePlayerPoint>>.JsonSaveFile(path, pts);
    }

    // The in-game world date/time. One-element array (see LiveClock) to reuse the proven
    // array JsonSaveFile path — the API reads element [0].
    static void WriteTimeSnapshot(string path)
    {
        int year, month, day, hour, minute;
        GetGame().GetWorld().GetDate(year, month, day, hour, minute);
        LiveClock c = new LiveClock();
        c.year = year;
        c.month = month;
        c.day = day;
        c.hour = hour;
        c.minute = minute;
        array<ref LiveClock> arr = new array<ref LiveClock>();
        arr.Insert(c);
        JsonFileLoader<array<ref LiveClock>>.JsonSaveFile(path, arr);
    }
}
