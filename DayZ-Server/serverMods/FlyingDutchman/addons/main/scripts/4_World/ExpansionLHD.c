// LHD hull hook — every ExpansionLHD that comes to life on the server (freshly spawned OR
// loaded back from vehicle persistence) reports to ShipPatroller.RegisterHull. This is the
// cap-proof stray detector: a map-wide GetObjectsAtPosition3D purge silently truncates at the
// engine's result cap (observed: exactly 1024) and MISSED persisted hulls parked at old route
// positions (owner-observed ghosts, staging 2026-07-24). Hooking EEInit sees every instance.
//
// Server-only, same pattern as LiveTracker's eAIBase hook. requiredAddons carries
// DayZExpansion_Vehicles_Scripts (read from the shipped vehicles_scripts.pbo) so this
// override actually applies to the real class.

modded class ExpansionLHD
{
    override void EEInit()
    {
        super.EEInit();
        if (GetGame() && GetGame().IsServer())
            ShipPatroller.RegisterHull(this);
    }
}
