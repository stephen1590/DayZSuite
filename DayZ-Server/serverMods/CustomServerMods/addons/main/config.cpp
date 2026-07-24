// CustomServerMods — OUR server-only mod for backend logic that can't be expressed as
// config: live position export + fresh-spawn survival buff. Grows one small feature at a time.
//
// Loaded via -serverMod ONLY: it is never sent to, required by, or downloaded by clients.
//
// Feature 1 — live export (LiveTracker.c): on a 20s server timer, writes to $profile:LiveTracker/
//   - ai.json      living NPCs [{x,z,type,age}] (eai; bandit when @aibandits is on)
//   - players.json connected players [{x,z}], ANONYMIZED (no id/name/GUID leaves the box)
//   - time.json    the in-game world clock [{year,month,day,hour,minute}]
// The API reads these and the Config UI map overlays them. (Renamed from AIB_Tracker 2026-07-24
// — it tracks eAI + players + the clock, not just AI Bandits, which are retired.)
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
