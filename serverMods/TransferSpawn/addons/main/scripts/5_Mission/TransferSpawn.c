// The relocator. Reads the two files prestart.sh writes into $profile: and moves each
// existing character, once per transfer generation, to one of the active mission's own
// spawn points.
//
//   $profile:transfer_spawn.json        { "gen": <int>, "points": [ {"x":..,"z":..}, … ] }
//     gen    - bumped by prestart.sh on every mission switch (0 = no switch has happened)
//     points - the active mission's <travel> spawn points (fallback <fresh>), x/z only
//
//   $profile:transfer_spawn_state.json  { "relocated": { "<steamId>": <gen>, … } }
//     last generation each character was relocated for — so nobody is moved twice per switch.
//     Owned by this mod; persists in the profiles dir across restarts.

class TS_Point
{
    float x;
    float z;
}

class TS_Config
{
    int gen;
    ref array<ref TS_Point> points;
}

class TS_State
{
    ref map<string, int> relocated;
}

class TransferSpawn
{
    static const string CFG_PATH   = "$profile:transfer_spawn.json";
    static const string STATE_PATH = "$profile:transfer_spawn_state.json";

    static ref TS_Config s_Cfg;
    static ref TS_State  s_State;
    static bool          s_Loaded;

    // Read both files once, at server init. Missing files are fine: gen stays 0 (no relocation).
    static void Init()
    {
        s_Cfg = new TS_Config();
        if (FileExist(CFG_PATH))
            JsonFileLoader<TS_Config>.JsonLoadFile(CFG_PATH, s_Cfg);
        if (!s_Cfg.points)
            s_Cfg.points = new array<ref TS_Point>();

        s_State = new TS_State();
        if (FileExist(STATE_PATH))
            JsonFileLoader<TS_State>.JsonLoadFile(STATE_PATH, s_State);
        if (!s_State.relocated)
            s_State.relocated = new map<string, int>();

        s_Loaded = true;
        Print("[TransferSpawn] init: gen=" + Gen() + " points=" + PointCount());
    }

    // Enforce Script rejects object refs used as booleans in an EXPRESSION (ternary/&&) —
    // `if (ref)` is special-cased and works, but `ref ? a : b` does not. Keep these as ifs.
    static int Gen()
    {
        if (!s_Cfg)
            return 0;
        return s_Cfg.gen;
    }

    static int PointCount()
    {
        if (!s_Cfg || !s_Cfg.points)
            return 0;
        return s_Cfg.points.Count();
    }

    // Called (deferred) after an existing character is ready. Relocates once per generation.
    static void OnCharacterReady(PlayerBase player)
    {
        if (!s_Loaded)
            Init();
        if (!player || !player.m_TS_FromStorage)
            return;                                  // fresh character — leave it on the vanilla path
        if (Gen() <= 0 || PointCount() == 0)
            return;                                  // no switch has happened, or no points to use

        PlayerIdentity id = player.GetIdentity();
        if (!id)
            return;
        string uid = id.GetId();

        int seen = 0;
        if (s_State.relocated.Contains(uid))
            seen = s_State.relocated.Get(uid);
        if (seen >= Gen())
            return;                                  // already moved for this switch

        TS_Point p = s_Cfg.points.Get(Math.RandomInt(0, PointCount()));
        vector pos = Vector(p.x, GetGame().SurfaceY(p.x, p.z), p.z);
        player.SetPosition(pos);

        s_State.relocated.Set(uid, Gen());
        JsonFileLoader<TS_State>.JsonSaveFile(STATE_PATH, s_State);
        Print("[TransferSpawn] relocated " + uid + " -> " + pos.ToString() + " (gen " + Gen() + ")");
    }
}
