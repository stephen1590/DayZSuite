// The live registry + the entity hook.
//
// InfectedBanditBase extends DayZInfected (confirmed by unpacking @aibandits), and
// BanditAI_Base extends InfectedBanditBase — so hooking the BASE catches every bandit
// subclass. Server-only: the whole PBO loads via -serverMod, and the register call is
// guarded on IsServer() as a belt-and-braces.

class AIB_Point
{
    float x;
    float z;
}

class AIB_Tracker
{
    // Live bandits, kept in sync by the EEInit/EEDelete hooks below. A set gives O(1)-ish
    // membership and no duplicates; weak in the sense that we also prune dead refs on write.
    private static ref set<InfectedBanditBase> s_Live = new set<InfectedBanditBase>();

    static void Register(InfectedBanditBase b)
    {
        if (b && s_Live.Find(b) == -1)
            s_Live.Insert(b);
    }

    static void Unregister(InfectedBanditBase b)
    {
        int i = s_Live.Find(b);
        if (i != -1)
            s_Live.Remove(i);
    }

    // Snapshot of LIVING bandits as [{"x":..,"z":..}], pruning dead/deleted as it goes.
    // GetPosition() = <X, Y, Z> with Y = elevation; we keep p[0] (east) and p[2] (north) —
    // the SAME (x,z) the map plots and the player overlay uses, so both layers align.
    static void WriteSnapshot(string path)
    {
        array<ref AIB_Point> pts = new array<ref AIB_Point>();
        for (int i = s_Live.Count() - 1; i >= 0; i--)
        {
            InfectedBanditBase b = s_Live.Get(i);
            if (!b || !b.IsAlive())
            {
                s_Live.Remove(i);   // corpse or GC'd — drop it, it's not an ACTIVE bandit
                continue;
            }
            vector p = b.GetPosition();
            AIB_Point pt = new AIB_Point();
            pt.x = p[0];
            pt.z = p[2];
            pts.Insert(pt);
        }
        JsonFileLoader<array<ref AIB_Point>>.JsonSaveFile(path, pts);
    }
}

modded class InfectedBanditBase
{
    override void EEInit()
    {
        super.EEInit();
        if (GetGame() && GetGame().IsServer())
            AIB_Tracker.Register(this);
    }

    override void EEDelete(EntityAI parent)
    {
        AIB_Tracker.Unregister(this);
        super.EEDelete(parent);
    }
}
