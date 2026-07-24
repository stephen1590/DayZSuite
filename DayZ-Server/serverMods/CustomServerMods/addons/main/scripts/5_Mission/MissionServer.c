// Server hooks: the tracker tick + the fresh-spawn survival buff.
//
// MissionServer only exists on the server, so nothing here ever runs on a client even if
// the PBO were mis-loaded.
//
// Tracker tick — every 20s, dump the live AI registry (bandits + eAI) to the profiles dir.
// 20s matches the map overlay's 30s poll comfortably (the file is always at most 20s
// stale). Writing an empty [] when no bandits are up is fine — the overlay just shows
// nothing.
//
// Spawn buff — every NEW character gets influenza resistance, so fresh spawns aren't
// flu-ridden within minutes (vanilla AutoinfectCheck contracts it 5-6 min into cold
// exposure; the resistance gate blocks that path entirely while it lasts; freezing
// itself stays vanilla). Hooked at OnClientNewEvent because it fires for NEW
// characters only (relogs skip it) and sits ABOVE the EquipCharacter fork that Expansion
// replaces when StartingClothing.EnableCustomClothing=1 — which is exactly how the old
// init.c StartingEquipSetup buff silently died. Applied ~2s deferred via the call queue
// so it lands after Expansion's clothing/stat pass, and the resistance timer starts once
// the player is actually in the world.

modded class MissionServer
{
    // Seconds of flu immunity for a fresh spawn. Vanilla decay is 1/s of real time, so
    // 900 = 15 real minutes; the vanilla flu AutoinfectCheck is hard-gated on this being
    // non-zero, so infection via cold exposure is impossible until it runs out.
    const float CSM_SPAWN_FLU_RESIST_SECS = 900;

    override void OnInit()
    {
        super.OnInit();
        // The snapshot files live in their own profile dir. JsonSaveFile does NOT create
        // parent dirs, so make it once at boot or every write silently no-ops on a fresh box.
        MakeDirectory("$profile:LiveTracker");
        // 20s repeating. Use the call queue, NOT Timer.Run(this,"name"): as of game build
        // 24041098 the engine rejects a modded MissionServer as the 'Managed' arg to Timer.Run
        // ("Types 'MissionServer@…' and 'Managed' are unrelated"), which corrupts the whole
        // modded MissionServer chain and cascades Expansion into "Bad type" — mission scripts
        // then fail to load and player connect stays disabled. CallLater takes a direct method
        // reference and sidesteps the conversion.
        GetGame().GetCallQueue(CALL_CATEGORY_SYSTEM).CallLater(LiveTrackerTick, 20000, true);
    }

    void LiveTrackerTick()
    {
        LiveTracker.WriteAiSnapshot("$profile:LiveTracker/ai.json");
        LiveTracker.WritePlayerSnapshot("$profile:LiveTracker/players.json");
        LiveTracker.WriteTimeSnapshot("$profile:LiveTracker/time.json");
    }

    // NB the 1.29 signature RETURNS the new PlayerBase (void here = "Overloaded function
    // 'OnClientNewEvent' not compatible" at boot, which kills the modded MissionServer chain).
    override PlayerBase OnClientNewEvent(PlayerIdentity identity, vector pos, ParamsReadContext ctx)
    {
        PlayerBase player = super.OnClientNewEvent(identity, pos, ctx);
        if (player)
            GetGame().GetCallQueue(CALL_CATEGORY_SYSTEM).CallLater(CSM_ApplySpawnBuff, 2000, false, player);
        return player;
    }

    void CSM_ApplySpawnBuff(PlayerBase player)
    {
        if (!player || !player.IsAlive())
            return;
        // Flu resistance ONLY — owner explicitly rejected a heat-buffer fill (2026-07-18);
        // freezing stays vanilla, this just stops the 5-6-minute spawn flu.
        player.SetTemporaryResistanceToAgent(eAgents.INFLUENZA, CSM_SPAWN_FLU_RESIST_SECS);
    }
}
