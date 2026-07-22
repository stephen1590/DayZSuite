# Baseline - upstream verbatim, before any tuning

Snapshot taken 2026-07-22, before the first custom-ce loot-balance change.

State at this point:
- `expansion_types.xml` is byte-identical to DayZ-Expansion-Missions
  `Template/Chernarus/expansion_ce/expansion_types.xml` (upstream master, clone dated 2026-01-22).
- `maps/dayzOffline.enoch/expansion_types.xml` is byte-identical to `Template/Enoch/...`.
- No Sakhal override exists. Upstream has never shipped a Sakhal template, so
  dayzOffline.sakhal falls through to the Chernarus file.
- `custom_types.xml` holds one entry we authored (CodeLock).

Registered live: 2026-07-21. Player complaints about vehicle doors and dairy
date from after that. Nothing in this snapshot was tuned by us.
