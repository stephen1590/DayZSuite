// FlyingDutchman server hook — schedules the patrol tick.
//
// This is its OWN modded MissionServer (separate -serverMod from CustomServerMods); modded
// classes stack, each calling super, so both mods' OnInit run. DORMANT unless
// ShipPatroller.ENABLED (false while staging), so with the flag off this override does nothing
// but call super — the server behaves exactly as before.
//
// CallLater with a DIRECT method ref (never Timer.Run with 'this' — that corrupts the modded
// MissionServer chain and disables player connect; see CustomServerMods/MissionServer.c).

modded class MissionServer
{
    override void OnInit()
    {
        super.OnInit();
        // Runtime enable marker: the SAME PBO is safe on every box. The ship wakes only where an
        // operator created $profile:FlyingDutchman/enable (touch + restart server to enable,
        // rm + restart to disable). No marker (prod today) = fully dormant: no spawn, no tick.
        ShipPatroller.ENABLED = FileExist("$profile:FlyingDutchman/enable");
        if (!ShipPatroller.ENABLED) return;
        ShipPatroller.Init();
        ShipFerry.Init();
        GetGame().GetCallQueue(CALL_CATEGORY_SYSTEM).CallLater(DutchmanTick, ShipPatroller.TICK_MS, true);
        GetGame().GetCallQueue(CALL_CATEGORY_SYSTEM).CallLater(FerryTick, ShipFerry.TICK_MS, true);
    }

    void DutchmanTick()
    {
        ShipPatroller.Tick();
    }

    void FerryTick()
    {
        ShipFerry.Tick();
    }
}
