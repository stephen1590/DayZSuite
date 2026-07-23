// CustomServerMods (ex-AIB_Tracker) — OUR server-only mod for backend logic that can't be
// expressed as config: live AI position export + fresh-spawn survival buff. Grows one small
// feature at a time; class/method names from the tracker era are kept (AIB_Tracker etc.).
//
// Loaded via -serverMod ONLY: it is never sent to, required by, or downloaded by clients.
//
// Feature 1 — AI position export: hooks the AI entity classes and, on a server timer, writes
// the living NPCs' [{x,z,type,age}] positions to $profile:AI_Bandits/live_positions.json —
// which the API reads and the Config UI map overlays, exactly like the anonymised player layer.
// This CORE addon tracks the ExpansionAI tree ONLY, so it depends on @expansion, NEVER on
// @aibandits — it loads and runs with bandits fully disabled:
//   - ExpansionAI   eAIBase            (extends PlayerBase)      type "eai"     — bundled in
//                                                                                 @expansion
//                   (ExpansionAIPatrol / Missions / Quests all spawn eAIBase)
// The bandit hook (InfectedBanditBase, type "bandit", needs @aibandits) lives in the SEPARATE
// optional addon addons/bandits -> @custom_server_mods_bandits, loaded as its own -serverMod
// only when @aibandits is on. Welding it into this addon SEGV-crashed the box on 2026-07-23
// when @aibandits was disabled (modded a class that no longer existed). Keep them split.
//
// Feature 2 — fresh-spawn flu buff (5_Mission/MissionServer.c): influenza resistance
// (ONLY — no stat changes) on every NEW character, applied via OnClientNewEvent — ABOVE the
// EquipCharacter fork Expansion hijacks when StartingClothing.EnableCustomClothing=1
// (which silently killed the old init.c StartingEquipSetup approach).
//
// requiredAddons names the addon that OWNS each hooked base class, so this compiles AFTER
// it and the `modded class` override actually applies:
//   - DayZExpansion_Scripts — @expansion/scripts.pbo, owns eAIBase (eAIBase.c hooks it)
// NO AI_Bandits here — that dependency lives in the split-off bandits addon. If a test shows
// eai MISSING from the JSON, confirm @expansion's real CfgPatches class name (unrapify its
// config.bin) and match it here.
class CfgPatches
{
    class CustomServerMods
    {
        units[] = {};
        weapons[] = {};
        requiredVersion = 0.1;
        requiredAddons[] = {"DZ_Data", "DayZExpansion_Scripts"};
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
