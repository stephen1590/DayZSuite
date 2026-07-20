// AIB_Tracker — SERVER-ONLY live position exporter for the server's AI NPCs.
//
// Loaded via -serverMod ONLY: it is never sent to, required by, or downloaded by clients.
// It hooks the AI entity classes and, on a server timer, writes the living NPCs'
// [{x,z,type,age}] positions to $profile:AI_Bandits/live_positions.json — which the API
// reads and the Config UI map overlays, exactly like the anonymised player layer.
//
// Two AI class trees are tracked, each in its own 4_World hook file, both feeding one
// registry (AIB_Tracker.c):
//   - AI Bandits    InfectedBanditBase (extends DayZInfected)   type "bandit"  — @aibandits
//   - ExpansionAI   eAIBase            (extends PlayerBase)      type "eai"     — bundled in
//                                                                                 @expansion
//                   (ExpansionAIPatrol / Missions / Quests all spawn eAIBase)
//
// requiredAddons names the addon that OWNS each hooked base class, so this compiles AFTER
// them and the `modded class` overrides actually apply:
//   - AI_Bandits           — @aibandits, owns InfectedBanditBase
//   - DayZExpansion_Scripts — @expansion/scripts.pbo, owns eAIBase (eAIBase.c lives there)
// IF A TEST SHOWS ONE TYPE MISSING FROM THE JSON, its addon name is the first thing to
// check: confirm the owning PBO's real CfgPatches class name (unrapify its config.bin) and
// match it here. Everything else (the classes, the hooks, the write dir) is confirmed.
class CfgPatches
{
    class AIB_Tracker
    {
        units[] = {};
        weapons[] = {};
        requiredVersion = 0.1;
        requiredAddons[] = {"DZ_Data", "AI_Bandits", "DayZExpansion_Scripts"};
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
