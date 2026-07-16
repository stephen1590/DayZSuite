// AIB_Tracker — SERVER-ONLY live position exporter for the AI Bandits mod (@aibandits).
//
// Loaded via -serverMod ONLY: it is never sent to, required by, or downloaded by clients.
// It hooks the bandit entity class and, on a server timer, writes the living bandits'
// [{x,z}] positions to $profile:AI_Bandits/live_positions.json — which the API reads and
// the Config UI map overlays, exactly like the anonymised player layer.
//
// requiredAddons names AI_Bandits so this compiles AFTER @aibandits and the
// `modded class InfectedBanditBase` actually applies. IF A TEST SHOWS THE JSON STAYS
// EMPTY, the addon name is the first thing to check: confirm the @aibandits PBO's real
// CfgPatches class name (its config.bin is binary; unrapify it or check its meta) and
// match it here. Everything else (the class, the hook, the write dir) is confirmed.
class CfgPatches
{
    class AIB_Tracker
    {
        units[] = {};
        weapons[] = {};
        requiredVersion = 0.1;
        requiredAddons[] = {"DZ_Data", "AI_Bandits"};
    };
};

class CfgMods
{
    class AIB_Tracker
    {
        dir = "AIB_Tracker";
        name = "AIB Live Tracker (server-only)";
        author = "servermander";
        type = "mod";
        dependencies[] = {"World", "Mission"};
        class defs
        {
            class worldScriptModule
            {
                value = "";
                files[] = {"AIB_Tracker/scripts/4_World"};
            };
            class missionScriptModule
            {
                value = "";
                files[] = {"AIB_Tracker/scripts/5_Mission"};
            };
        };
    };
};
