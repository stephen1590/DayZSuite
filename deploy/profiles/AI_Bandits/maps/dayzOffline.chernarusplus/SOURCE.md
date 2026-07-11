# Chernarus DynamicAIB — coordinates third-party, bandits now shared/global

`DynamicAIB.json` here is our **compose-schema** (`groups[]` + `snipers[]`), each entry
referencing a **global template** in `../../common/DynamicAIB.common.json`. Only the
**locations** are Chernarus-specific; the bandit material (loadouts, weapons, sizes, accuracy,
sniper kits) is shared across every map so the same NPC types appear everywhere.

- **Coordinates source:** scalespeeder — "CHERNARUS DayZ AI Bandits Better NPC Loadouts, Manned Roadblocks & Snipers" (Jan 2026)
  https://github.com/scalespeeder/CHERNARUS-DayZ-AI-Bandits-PC-MOD-Better-NPC-Loadouts-Manned-Roadblocks-Snipers-Files-Jan-26
  The waypoints/sniper positions/trigger points below are transcribed from that repo.
- **Base mod:** AI Bandits by HunterZ — https://steamcommunity.com/sharedfiles/filedetails/?id=3628006769
- **Terms:** provided "as is" (MIT-style, no warranty). Attribution retained here.
- **Changed from the original:** scalespeeder shipped a verbatim native file with loadouts baked
  in per group. We **promoted those bandit types into shared `common` templates**
  (`roadblock`, `patrol_akm`, `airfield_m4`, `guard_patrol`, `svd_nest`) so they're reusable on
  Sakhal and future maps. Coordinates are unchanged; loadouts/weapons/sizes now come from `common`
  (retune them there and every map updates). Template overrides preserve the original per-site
  tuning (Petrovka acc-90/M4, TISY guards, Balotoa roaming sniper `fixedpos:0`).
- **NOT included:** the repo's `road-blocks-chernarus.json` (a custom OBJECT-SPAWNER file for
  physical roadblock props) is a separate system, not AI Bandits config — it would need an object
  spawner (e.g. VPP's), not this pipeline. Left out pending a decision.

Only active when the server runs `dayzOffline.chernarusplus`; the shared templates it uses are
also available to Sakhal (which can add its own placements/snipers referencing them).
