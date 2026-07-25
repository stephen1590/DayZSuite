// FlyingDutchman — server-only mod: one persistent Expansion ship patrolling the Sakhal
// coast. Loaded via -serverMod ONLY, never sent to / downloaded by clients.
//
// Clients need @expansionvehicles (ALREADY enforced) for the ExpansionLHD class. This mod
// DOES take a compile-time dependency on the vehicles scripts (requiredAddons below): the
// stray-hull purge hooks `modded class ExpansionLHD` (EEInit registry — the only cap-proof
// way to see persistence-loaded hulls), and a modded class only applies when its owner addon
// is named. Owner read from the shipped vehicles_scripts.pbo: DayZExpansion_Vehicles_Scripts.
//
// DORMANT: ShipPatroller.ENABLED = false ships it inert — spawns nothing, schedules nothing.
// Flip it on (and add the mod to the -serverMod chain) only when ready to test on the box.
//
// Movement is WAYPOINT-TELEPORT (SetPosition steps toward hand-placed water waypoints), NOT
// engine driving: no fuel, no driver, no reliance on autonomous boat AI (which DayZ lacks). The
// ship is lockable against hijack but DESTRUCTIBLE — players may blow it up (a reward hook is a
// later feature). Its last position + patrol leg persist to $profile:FlyingDutchman/state.json
// so a restart respawns it where it left off.
class CfgPatches
{
    class FlyingDutchman
    {
        units[] = {};
        weapons[] = {};
        requiredVersion = 0.1;
        requiredAddons[] = {"DZ_Data", "DayZExpansion_Vehicles_Scripts"};
    };
};

class CfgMods
{
    class FlyingDutchman
    {
        dir = "FlyingDutchman";
        name = "Flying Dutchman (server-only)";
        author = "servermander";
        type = "mod";
        dependencies[] = {"World", "Mission"};
        class defs
        {
            class worldScriptModule
            {
                value = "";
                files[] = {"FlyingDutchman/scripts/4_World"};
            };
            class missionScriptModule
            {
                value = "";
                files[] = {"FlyingDutchman/scripts/5_Mission"};
            };
        };
    };
};
