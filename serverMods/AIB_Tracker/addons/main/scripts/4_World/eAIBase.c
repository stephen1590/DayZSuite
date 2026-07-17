// ExpansionAI (eAI) hook — registers every Expansion AI into AIB_Tracker.
//
// eAIBase is DayZ-Expansion's AI entity (extends PlayerBase, NOT DayZInfected — a different
// tree from the bandits). It's defined in @expansion/addons/scripts.pbo (CfgPatches
// DayZExpansion_Scripts, named in requiredAddons so this override applies). Everything that
// spawns Expansion AI funnels through it: ExpansionAIPatrol, ExpansionAIPatrolManager, and
// the Missions / Quests combat spawns. Hooking the base catches them all.
//
// Server-only, same as the bandit hook: eAI only exist server-side, and IsServer() guards.
// No faction/type detail yet — that needs the eAI group API confirmed against the source;
// v1 tags every Expansion AI "eai". Add faction later by reading GetGroup() here.

modded class eAIBase
{
    override void EEInit()
    {
        super.EEInit();
        if (GetGame() && GetGame().IsServer())
            AIB_Tracker.Register(this, "eai");
    }

    override void EEDelete(EntityAI parent)
    {
        AIB_Tracker.Unregister(this);
        super.EEDelete(parent);
    }
}
