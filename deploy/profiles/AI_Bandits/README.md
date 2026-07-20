# AI_Bandits configs — FULL-FILE OWNED, composed PER-MAP

`DynamicAIB.json` / `StaticAIB.json` are the mod's runtime configs full of **raw world
coordinates**. Coordinates are meaningless across maps — a group placed at Sakhal coords lands
in the ocean on Chernarus — but the mod reads **one fixed path** (`profiles/AI_Bandits/*.json`)
with no per-map awareness. So a single shipped file is only ever correct for one map.

We solve that by **composing** the flat file the mod reads from a source tree, on every start:

```
common/DynamicAIB.common.json      map-agnostic: global flags, PredefinedWeapons, loadout kits
maps/<mission>/DynamicAIB.json      per-map PLACEMENTS only: name, coords, size, which kit
maps/<mission>/StaticAIB.json       per-map static NPCs (straight copy — no shared layer)
```

`Build-AIBandits.ps1` (shipped to the server dir, run by `prestart.sh` before each start with
the active mission) merges `common ⊕ maps/<mission>` → the flat `DynamicAIB.json`, expanding each
placement's `size` into that many `npcclasses` from the kit's pool and inlining the kit. The flat
`DynamicAIB.json` / `StaticAIB.json` are therefore **generated artifacts** — never shipped, never
hand-edited (Deploy ships only the source tree + the builder).

**Fail-soft / empty-safe:** a bad group is logged (WARN) and skipped; a map with **no** per-map
file gets an **empty** file (no bandits), never another map's coords. `prestart` wraps the call in
`|| true`, so nothing here can block server boot.

## How this differs from the override model

| Config | How it's managed | Where |
|---|---|---|
| `DynamicAIB.json`, `StaticAIB.json` | **Full-file, composed per-map** — we author the whole document (placements, kits) | this tree |
| KnockKnock `chanceToSpawn`, CE `db/globals.xml` vars | **Field patch** into a mod/vanilla baseline we don't own | `../../config-overrides.json` → `Apply-ConfigOverrides.ps1` |

The override system exists to survive a mod update rewriting a baseline. These `profiles/` files
aren't rewritten by a workshop update, and their content *is* coordinates/kits we define — so
full-file, not patches.

## The model: global bandits, per-map placement

Bandits are **defined globally** in `common/` and only **placed** per-map. Three shared tiers:

| In `common/DynamicAIB.common.json` | What it is |
| --- | --- |
| `loadouts.<name>` | A clothing + loot **kit** (`npcproperties`). Each clothing slot is a pool the mod picks one entry from per NPC. **`loot` drops per-NPC and is multiplied by group size** — in-game the whole array drops on each corpse and repeats pile into stacks, so a size-8 squad turns a 14-item array into ~112 items. **Keep `loot` arrays tiny (2–4 low-value, thematic items); never repeat a valuable.** The corpse's bulk value is its worn kit (clothes/vest/backpack/gun+attachments), which always drops and is set by the loadout/weapon, not `loot`. No condition/health field exists — "ruined/damaged" drops can't be scripted. |
| `groupTemplates.<name>` | A fully-defined **squad**: which loadout, weapon, size, accuracy, grenadechance, dog, faction. |
| `sniperTemplates.<name>` | A reusable **SVD nest**: loadout, weapon, npcclass, accuracy, fixedpos. |

A per-map file just says *put this template here*, e.g.:

```json
{ "groups":  [ { "name": "West Roadblock", "template": "roadblock", "waypoints": ["x y z", ...] } ],
  "snipers": [ { "name": "Hilltop", "template": "svd_nest", "positions": ["x y z", ...], "triggerpos": "x y z" } ] }
```

Retune a bandit **type** once in `common` (every map updates); move/add a **placement** in the
per-map file. The same squads therefore appear on **all** maps — only coordinates differ.

## Editing

- **A bandit type (all maps):** edit the `loadout` / `groupTemplate` / `sniperTemplate` in
  `common/DynamicAIB.common.json`. Clothing/weapon/loot classnames are vanilla DayZ and can drift
  between game versions — an invalid name just means the item is absent (not a crash), worth a
  sanity pass.
- **A placement (one map):** edit `maps/<mission>/DynamicAIB.json`. A group = `name` + `template`
  (or inline `loadout`+`weapon`) + a location (`pos`, or a `waypoints` array of `"x y z"`). Any
  template field can be **overridden inline** per site (`accuracy`, `weapon`, `size`, `dog`, …).
  A sniper = `name` + `template` + `positions[]` + `triggerpos` (+ optional `fixedpos`).
  **`accuracy` and `grenadechance` are 0–100 (percent), NOT 0–1** — `grenadechance: 15` = 15%.
- **A new map:** add `maps/<mission>/DynamicAIB.json` and a matching `$items` line in
  `Deploy-DayZServer.ps1`. No builder change needed.

### Two accepted per-map formats

The builder auto-detects which format a `maps/<mission>/DynamicAIB.json` is:

1. **Compose (ours)** — top-level `groups[]` (and optional `snipers[]`) referencing `common`
   templates/kits. Merged with `common/` into the flat file. **Chernarus uses this** — its
   coordinates come from scalespeeder (see its `SOURCE.md`) but its bandits are the shared
   `common` templates. Chernarus is currently **parked**: kept in-repo but **not deployed**
   (see its `PARKED.md`). (Sakhal has no per-map file — its spawns come from the shared map-points
   store; see below.)
2. **Native passthrough** — a complete mod-format file (top-level `GroupLocations` /
   `SniperLocations` / `PredefinedWeapons`, no `groups`). Copied **verbatim**, `common/` ignored.
   Kept as an escape hatch to drop in a community config unchanged without converting it.

## Sakhal spawns come from the shared map-points store (no per-map DynamicAIB)

Sakhal dynamic bandits are sourced **entirely from `profiles/AI_Shared/map-points.json`** — the
SHARED spawn store (it feeds ExpansionAI too), web-edited — so there is no
`maps/dayzOffline.sakhal/DynamicAIB.json`. Each point
carries `name`, `map`, optional `category`/`size`, and `x`/`y`/`z`; `common/classification.json`
maps the `category` token to a template and the `size` letter to a member count, and the builder
composes a group per point at prestart (a point with no `category` becomes a base holdout).

**Editing:** open the ConfigViewer **Map** tab, turn on **Edit**, then drag a marker to move it,
click empty map to add one, edit fields in the panel, and **Save**. Save writes the box copy live
(via the API's `configs/set-spawns` -> `dayz-ctl spawn-write`, snapshotted, keep 10) and applies at
the next restart. The deploy pulls the box copy back into the repo (`Sync-SpawnPoints.ps1`) so git
stays the durable record. You can also hand-edit `profiles/AI_Shared/map-points.json` directly.

The map-points store was seeded once from the last VPP snapshot. VPP is no longer the source — the
old importer/migrator was deleted 2026-07-16 (git history has it), not part of the
deploy. `StaticAIB.json` for Sakhal (3 fixed sentry NPCs) is a separate system and stays per-map.

Schema note: on a mod update that changes the flat-file schema, adjust the builder's output shape
and/or `common` — the source tree stays; only the composition changes.
