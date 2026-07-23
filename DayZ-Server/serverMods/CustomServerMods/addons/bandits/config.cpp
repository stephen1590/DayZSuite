// CustomServerMods_Bandits — the OPTIONAL bandit-tracking hook, split out of the core mod so
// the core (eAI tracking + fresh-spawn buff) loads on Expansion ALONE. This PBO is the ONLY
// thing that touches an @aibandits class, so it is loaded as its OWN -serverMod (@custom_server_mods_bandits)
// and ONLY when @aibandits is enabled. When bandits are off, this PBO is simply not loaded —
// nothing references InfectedBanditBase, so the class-merge SEGV that took the server down
// (2026-07-23, @aibandits disabled while this hook was welded into the core) cannot happen.
//
// Load order matters: requiredAddons names AI_Bandits (owns InfectedBanditBase) AND
// CustomServerMods (owns AIB_Tracker, which InfectedBanditBase.c calls). Both must compile
// first — the engine merges every -serverMod's 4_World into one module in requiredAddons order.
//
// TO RE-ENABLE BANDIT TRACKING when @aibandits returns:
//   1. mods.conf: uncomment @aibandits (and @dayzdog if wanted).
//   2. Deploy ships this PBO to @custom_server_mods_bandits/addons (guarded $items entry).
//   3. Unit -serverMod: @custom_server_mods;@custom_server_mods_bandits (core first).
class CfgPatches
{
    class CustomServerMods_Bandits
    {
        units[] = {};
        weapons[] = {};
        requiredVersion = 0.1;
        requiredAddons[] = {"DZ_Data", "AI_Bandits", "CustomServerMods"};
    };
};

class CfgMods
{
    class CustomServerMods_Bandits
    {
        dir = "CustomServerMods_Bandits";
        name = "Custom Server Mods - Bandit hook (server-only, optional)";
        author = "servermander";
        type = "mod";
        dependencies[] = {"World"};
        class defs
        {
            class worldScriptModule
            {
                value = "";
                files[] = {"CustomServerMods_Bandits/scripts/4_World"};
            };
        };
    };
};
