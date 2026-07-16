// Mark a character that was LOADED FROM STORAGE (an existing character) versus a fresh
// spawn. Only an existing character carries a stale position after a map switch, so only
// it should be relocated. A fresh character is created new and never calls OnStoreLoad,
// so its flag stays false and TransferSpawn leaves it on the vanilla fresh-spawn path.
modded class PlayerBase
{
    bool m_TS_FromStorage;

    override bool OnStoreLoad(ParamsReadContext ctx, int version)
    {
        bool ok = super.OnStoreLoad(ctx, version);
        if (ok)
            m_TS_FromStorage = true;   // this character existed in players.db before this boot
        return ok;
    }
}
