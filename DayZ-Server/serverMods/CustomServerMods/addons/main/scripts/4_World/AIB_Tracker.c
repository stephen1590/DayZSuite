// The live AI registry + the snapshot writer.
//
// One registry for every tracked AI tree. The per-class hooks (InfectedBanditBase.c,
// eAIBase.c) call Register/Unregister; the MissionServer tick calls WriteSnapshot every
// 20s. We key on EntityAI (the common ancestor of both bandit and eAI entities) and carry
// the type tag + spawn time alongside each ref, so the snapshot can label every dot without
// re-deriving its class. A dead/deleted entity is pruned lazily on the next write.

class AIB_Point
{
    float  x;      // east  — map X, matches the player overlay so both layers align
    float  z;      // north — map Z (engine Y = elevation, dropped)
    string type;   // "bandit" (InfectedBanditBase) | "eai" (eAIBase)
    int    age;    // seconds this NPC has been alive at snapshot time (session clock)
}

// One live entity + the metadata we can't read back off the entity cheaply.
class AIB_Entry
{
    EntityAI ent;
    string   type;
    int      spawnSec;   // session-clock seconds at spawn; age = now - spawnSec at write
}

class AIB_Tracker
{
    // Live NPCs, kept in sync by the EEInit/EEDelete hooks. Array (not set) because we store
    // a metadata record per entity, not the bare ref; membership stays deduped on Register.
    private static ref array<ref AIB_Entry> s_Live = new array<ref AIB_Entry>();

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
        foreach (AIB_Entry existing : s_Live)
            if (existing.ent == ent)
                return;
        AIB_Entry rec = new AIB_Entry();
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
    static void WriteSnapshot(string path)
    {
        int now = NowSec();
        array<ref AIB_Point> pts = new array<ref AIB_Point>();
        for (int i = s_Live.Count() - 1; i >= 0; i--)
        {
            AIB_Entry e = s_Live[i];
            EntityAI ent = e.ent;
            if (!ent || !ent.IsAlive())
            {
                s_Live.Remove(i);   // corpse or GC'd — drop it, it's not an ACTIVE NPC
                continue;
            }
            vector p = ent.GetPosition();
            AIB_Point pt = new AIB_Point();
            pt.x = p[0];
            pt.z = p[2];
            pt.type = e.type;
            pt.age = now - e.spawnSec;
            pts.Insert(pt);
        }
        JsonFileLoader<array<ref AIB_Point>>.JsonSaveFile(path, pts);
    }
}
