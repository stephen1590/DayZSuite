// CustomServerMods (ex-AIB_Tracker) — OUR server-only mod for backend logic that can't be
// expressed as config: live AI position export + fresh-spawn survival buff. Grows one small
// feature at a time; class/method names from the tracker era are kept (AIB_Tracker etc.).
//
// Loaded via -serverMod ONLY: it is never sent to, required by, or downloaded by clients.
//
// Feature 1 — AI position export: hooks the AI entity classes and, on a server timer, writes
// the living NPCs' [{x,z,type,age}] positions to $profile:AI_Bandits/live_positions.json —
// which the API reads and the Config UI map overlays, exactly like the anonymised player layer.
// Two AI class trees are tracked, each in its own 4_World hook file, both feeding one
// registry (AIB_Tracker.c):
//   - AI Bandits    InfectedBanditBase (extends DayZInfected)   type "bandit"  — @aibandits
//   - ExpansionAI   eAIBase            (extends PlayerBase)      type "eai"     — bundled in
//                                                                                 @expansion
//                   (ExpansionAIPatrol / Missions / Quests all spawn eAIBase)
//
// Feature 2 — fresh-spawn flu buff (5_Mission/MissionServer.c): influenza resistance
// (ONLY — no stat changes) on every NEW character, applied via OnClientNewEvent — ABOVE the
// EquipCharacter fork Expansion hijacks when StartingClothing.EnableCustomClothing=1
// (which silently killed the old init.c StartingEquipSetup approach).
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
    class CustomServerMods
    {
        units[] = {};
        weapons[] = {};
        requiredVersion = 0.1;
        requiredAddons[] = {"DZ_Data", "AI_Bandits", "DayZExpansion_Scripts"};
    };
};

class CfgMods
{
    class CustomServerMods
    {
        dir = "CustomServerMods";
        name = "Custom Server Mods (server-only)";
        author = "servermander";
        type = "mod";
        dependencies[] = {"World", "Mission"};
        class defs
        {
            class worldScriptModule
            {
                value = "";
                files[] = {"CustomServerMods/scripts/4_World"};
            };
            class missionScriptModule
            {
                value = "";
                files[] = {"CustomServerMods/scripts/5_Mission"};
            };
        };
    };
};
