# archive/

Preserved copies of config the pipeline is about to replace. Nothing here is
shipped, seeded, mirrored, or validated - it is a durable "don't lose this" store,
outside every deploy/gate path. Rename-and-keep only; never delete or overwrite an
existing snapshot.

| File | What | When |
|---|---|---|
| `map-points.snapshot-2026-07-23.json` | The authored AI map-points store (32 Sakhal points) as it was before the AI-settings inversion. Was the SOURCE feeding the Expansion AI builders; being replaced by points DERIVED from the live AIPatrol/AILocation settings. | 2026-07-23 |
| `Build-AIBandits.ps1` | The BanditAI prestart compiler (common scaffolding + per-map placements -> the mod's flat DynamicAIB/StaticAIB). BanditAI is retired; the script was dormant since the 2026-07-23 disable. Archived - NOT reusable for the map inversion (it template-expands kit pools for a dead mod's schema; Build-MapPoints is a pure projection the other way). To resurrect: move back to the repo root and restore its prestart block, deploy rows and gate steps from git history. | 2026-07-23 |
