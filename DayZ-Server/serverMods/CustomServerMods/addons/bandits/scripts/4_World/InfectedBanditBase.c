// AI Bandits hook — registers every bandit into LiveTracker (registry lives in LiveTracker.c,
// in the main addon). Dormant unless @aibandits is loaded (bandits are retired as of 2026-07-23).
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
            LiveTracker.Register(this, "bandit");
    }

    override void EEDelete(EntityAI parent)
    {
        LiveTracker.Unregister(this);
        super.EEDelete(parent);
    }
}
