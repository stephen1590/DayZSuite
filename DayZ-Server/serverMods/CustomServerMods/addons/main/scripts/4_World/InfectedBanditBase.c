// AI Bandits hook — registers every bandit into AIB_Tracker (registry lives in AIB_Tracker.c).
//
// InfectedBanditBase extends DayZInfected (confirmed by unpacking @aibandits), and
// BanditAI_Base extends InfectedBanditBase — so hooking the BASE catches every bandit
// subclass. Server-only: the whole PBO loads via -serverMod, and the register call is
// guarded on IsServer() as belt-and-braces.

modded class InfectedBanditBase
{
    override void EEInit()
    {
        super.EEInit();
        if (GetGame() && GetGame().IsServer())
            AIB_Tracker.Register(this, "bandit");
    }

    override void EEDelete(EntityAI parent)
    {
        AIB_Tracker.Unregister(this);
        super.EEDelete(parent);
    }
}
