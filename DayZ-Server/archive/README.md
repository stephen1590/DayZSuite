# archive/

Preserved copies of config the pipeline is about to replace. Nothing here is
shipped, seeded, mirrored, or validated - it is a durable "don't lose this" store,
outside every deploy/gate path. Rename-and-keep only; never delete or overwrite an
existing snapshot.

| File | What | When |
|---|---|---|
| `map-points.snapshot-2026-07-23.json` | The authored AI map-points store (32 Sakhal points) as it was before the AI-settings inversion. Was the SOURCE feeding the Expansion AI builders; being replaced by points DERIVED from the live AIPatrol/AILocation settings. | 2026-07-23 |
| `Build-AIBandits.ps1` | The BanditAI prestart compiler (common scaffolding + per-map placements -> the mod's flat DynamicAIB/StaticAIB). BanditAI is retired; the script was dormant since the 2026-07-23 disable. Archived - NOT reusable for the map inversion (it template-expands kit pools for a dead mod's schema; Build-MapPoints is a pure projection the other way). To resurrect: move back to the repo root and restore its prestart block, deploy rows and gate steps from git history. | 2026-07-23 |
| `Build-AIPatrols.ps1`, `Build-AILocations.ps1` | The Expansion AI DRAFT builders. Composed `AIPatrols.draft.json` / `AILocations.draft.json` from the frozen authored `map-points.json` + a frozen base, as a "what map-points would produce" PREVIEW. Retired in Phase 4 (map inversion) - adversarially confirmed nothing ever read the drafts (the mod reads the live `AIPatrolSettings.json`/`AILocationSettings.json`; `Build-MapPoints` now derives the map store FROM those). The two `*.draft.json` globs stay in the registry `generated` list as mirror-exclusions for any residual box files. To resurrect: move back to root, restore the prestart calls, deploy rsync+items rows, and the gate compose/assert steps from git history. | 2026-07-23 |
| `Sync-SpawnPoints.ps1` | Mirrored the box's authored `map-points.json` back into the repo. Retired in Phase 4 once `map-points.json` was locked read-only (frozen source, no longer web-editable) - the mirror had nothing changing to pull. Removed from the `Pull-Configs.ps1` sequence. The committed mirror (`deploy/profiles/AI_Shared/map-points.json`) stays as the frozen reference. To resurrect: move back to root and re-add to Pull-Configs' `$syncs`. | 2026-07-23 |
