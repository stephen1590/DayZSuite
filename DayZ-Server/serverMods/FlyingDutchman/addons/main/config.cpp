// FlyingDutchman — server-only mod: one persistent Expansion ship patrolling the Sakhal
// coast. Loaded via -serverMod ONLY, never sent to / downloaded by clients.
//
// Clients need @expansionvehicles (ALREADY enforced) for the ExpansionLHD class — resolved by
// NAME at spawn. requiredAddons names the vehicles scripts only to pin compile ORDER (we call
// Expansion Core's ExpansionNotification; vehicles requires core, so core compiles first).
// NO modded classes on vehicle types: a server-only override on a networked vehicle class was
// prime suspect for clients failing to render the ship (removed 2026-07-25).
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
