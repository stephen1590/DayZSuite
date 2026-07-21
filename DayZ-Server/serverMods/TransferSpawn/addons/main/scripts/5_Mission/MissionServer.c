// Server hooks for the map-switch relocator.
//
// OnInit          - read the transfer config/state once at boot (logs gen + point count).
// OnClientReadyEvent - fires when a client's character is fully ready (fresh OR existing).
//   We defer ~1.5 s via the call queue before moving them: setting position on the same
//   frame the engine finishes spawning can be overwritten. TransferSpawn itself decides
//   whether this character actually gets moved (existing only, once per generation).
modded class MissionServer
{
    override void OnInit()
    {
        super.OnInit();
        TransferSpawn.Init();
    }

    override void OnClientReadyEvent(PlayerIdentity identity, PlayerBase player)
    {
        super.OnClientReadyEvent(identity, player);
        if (player)
            GetGame().GetCallQueue(CALL_CATEGORY_SYSTEM).CallLater(this.TS_RelocateLater, 1500, false, player);
    }

    // Instance wrapper so CallLater has a valid target (it can't take a bare static method).
    void TS_RelocateLater(PlayerBase player)
    {
        TransferSpawn.OnCharacterReady(player);
    }
}
