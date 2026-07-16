// Server tick: every 20s, dump the live bandit registry to the profiles dir.
//
// MissionServer only exists on the server, so this never runs on a client even if the PBO
// were mis-loaded. 20s matches the map overlay's 30s poll comfortably (the file is always
// at most 20s stale). Writing an empty [] when no bandits are up is fine — the overlay just
// shows nothing.

modded class MissionServer
{
    override void OnInit()
    {
        super.OnInit();
        // 20s repeating. Use the call queue, NOT Timer.Run(this,"name"): as of game build
        // 24041098 the engine rejects a modded MissionServer as the 'Managed' arg to Timer.Run
        // ("Types 'MissionServer@…' and 'Managed' are unrelated"), which corrupts the whole
        // modded MissionServer chain and cascades Expansion into "Bad type" — mission scripts
        // then fail to load and player connect stays disabled. CallLater takes a direct method
        // reference and sidesteps the conversion.
        GetGame().GetCallQueue(CALL_CATEGORY_SYSTEM).CallLater(AIB_TrackerTick, 20000, true);
    }

    void AIB_TrackerTick()
    {
        AIB_Tracker.WriteSnapshot("$profile:AI_Bandits/live_positions.json");
    }
}
