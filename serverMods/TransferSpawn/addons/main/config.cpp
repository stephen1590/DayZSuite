// TransferSpawn — SERVER-ONLY safe spawn on a map switch.
//
// Loaded via -serverMod ONLY: never sent to, required by, or downloaded by clients.
//
// The problem: prestart.sh migrates players.db verbatim across a mission switch, so an
// existing character keeps its raw old-map X/Z — which is meaningless on the new map
// (ocean, inside terrain). DayZ's own `travel` spawn group is official-hive-only, so a
// private server never auto-uses it; the engine just loads the stale position.
//
// The fix: prestart.sh bumps a "transfer generation" on every switch and writes the
// active mission's OWN travel spawn points (fallback fresh) to $profile:transfer_spawn.json.
// This mod relocates each EXISTING character, once per generation, to a random one of those
// points (ground Y from GetGame().SurfaceY) on their first login after the switch. Gear is
// untouched — only the position moves. Fresh characters (no OnStoreLoad) are never touched.
//
// Standalone: no dependency on @aibandits or any workshop mod — it hooks vanilla
// PlayerBase + MissionServer only.
class CfgPatches
{
    class TransferSpawn
    {
        units[] = {};
        weapons[] = {};
        requiredVersion = 0.1;
        requiredAddons[] = {"DZ_Data"};
    };
};

class CfgMods
{
    class TransferSpawn
    {
        dir = "TransferSpawn";
        name = "Transfer Spawn (server-only)";
        author = "servermander";
        type = "mod";
        dependencies[] = {"World", "Mission"};
        class defs
        {
            class worldScriptModule
            {
                value = "";
                files[] = {"TransferSpawn/scripts/4_World"};
            };
            class missionScriptModule
            {
                value = "";
                files[] = {"TransferSpawn/scripts/5_Mission"};
            };
        };
    };
};
