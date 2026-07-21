# Config Architecture

> **Single source of truth** for how DayZ server config is managed across the box, the API, and the web UI. If any other doc, code comment, or artifact disagrees with this file, either this file wins or this file is wrong and gets fixed here first. Don't re-explain the config model elsewhere - point at this file.
>
> Rendered snapshots (presentation only, private Claude links): the *reassessment* and *two-copy-model* artifacts.

**Status: mid-redesign.** The box runs the **current model** below. The **target model** is agreed (2026-07-20) but **not built**. Do not describe the target as if it exists.

---

## Canonical names

Old docs drift on these. These are the truth, verified against code:

| Thing | Canonical | Retired name (do not use) |
|---|---|---|
| AI-bandit spawn store | `profiles/AI_Bandits/map-points.json` (registry surface `Spawn-points`) | `spawn-points.json` (renamed 2026-07-15) |
| The service | **Api** | Webhooks (renamed 2026-07-13) |
| VPP webhooks | event/FPS telemetry feed only | a live command-relay path (deprecated 2026-07-15) |

---

## Current model — what the box runs today

Three tiers. The box owns the truth; the API is a signed relay; the browser is a client.

- **Registry** — `DayZ-Server/config-registry.json`. One row per surface (21 today). Fields: `name`, `box`, `scope`, `seed`, `mirror`, `web`, `writable`, `check`. Four consumers read it: Api allowlist, Deploy seed-if-missing, Sync/Pull mirroring, Confirm-LiveConfigs parse-check.
- **Defaults** — `DayZ-Server/config-defaults/` holds frozen `<stem>.defaults.<ext>` baselines, refreshed by hand via `Generate-ConfigDefaults.ps1`.
- **Overrides** — `DayZ-Server/config-overrides.json` (~98 KB) holds field-level deltas: dotted-path selectors for JSON, XPath for XML, layered common vs per-mission. Box-authoritative; the repo copy is a mirror.
- **Apply + build at prestart** — `deploy/prestart.sh` runs these engines in order, fail-soft (`|| true`) so bad config can't block boot:
  1. `Apply-ConfigOverrides.ps1` — default + deltas → live file
  2. `deploy/Build-BabakuSpawns.ps1`
  3. `Build-AIBandits.ps1`
  4. `Build-AILocations.ps1`
  5. `Build-AIPatrols.ps1`
  6. `Apply-CustomCE.ps1`
  7. `deploy/Build-TransferSpawns.ps1`
- **The API** — Fastify/TS, relays signed HTTP → `sudo dayz-ctl` (closed verb set, re-validated on the box). ~38 actions in `Api/app/src/actions.ts`. Config edits: `override-diff.ts` / `override-diff-xml.ts` compute a delta, the box stores and applies it.
- **The web UI** — ConfigViewer, a dependency-free SPA. Hand-rolled editor (`editor.js`), `highlight.js`, `lossless-json.js`.

### The problem this causes

The override model is written three times — browser JS, API TS, box PowerShell — held in sync only by comments. Nothing proves the three agree, so they drift silently: a delta the API computes but the box applies differently falls back to whole-file or no-ops, with no error. That is the root cause of the "missed requirements and rewrites." Full diagnosis: the *reassessment* artifact.

---

## Target model — agreed 2026-07-20, NOT built

Stop applying diffs. The diff becomes something the UI **shows**, never something the box **applies**. Every config is one of two kinds:

| | **Owned files** (Category A) | **Computed artifacts** (Category B) |
|---|---|---|
| Holds | two whole copies: `default` + `live` | shared/common inputs + per-map inputs |
| Live value is | the exact file the game reads, edited in place | consolidated output for the active mission |
| UI | shows default-vs-live diff; saves the whole live file | edits the *inputs* |
| Prestart | no-op (validate only) | builder regenerates (deterministic, idempotent) |
| On update | reconcile: 3-way merge (old-default vs new-default vs live), human-reviewed | rebuild from inputs |
| Examples | mod profile configs, bans/whitelist | DynamicAIB, transfer_spawn, custom-CE, babaku |

The universal applier disappears. What replaces it: nothing for Category A, and small explicit builders for Category B (which already exist). The diff moves from the write path (correctness-critical) to the read path (cosmetic if wrong). The 98 KB `config-overrides.json`, the selector grammar, and `override-diff*.ts` are all retired.

**One honest catch:** deltas re-stamped your changes onto a vendor rewrite. But defaults are already refreshed by hand today, so that survival was already manual. The target keeps the same touch-point as a reviewed 3-way merge instead of a silent re-stamp.

---

## State-change procedure — how a part stays integrated with the whole

One rule: **a part cannot ship until the whole is proven consistent.** Each kind of change has one path, and every path ends at the same fail-closed gate.

- **Operator edits an owned file** — edit whole file → review diff → save (version check) → box writes + snapshots → mirror to repo. No build, no apply. Git history is a readable diff.
- **New config type** — add a contract row (category + tier bindings). Build stays **red** until every tier is wired (box path, API allowlist, UI binding). That red build *is* the integration guarantee.
- **Game/mod update** — new baseline → reconcile owned files (3-way, human) → rebuild computed artifacts → refresh defaults → gate.

Underneath: **one contract** defines the whole, **one fail-closed gate** asserts it before ship, **single authority per file** (box-owned / builder-owned / repo-owned — never dual-write).

---

## Testing

Retiring the applier makes the hard test easy — there's no cross-language delta to prove equal.

| Test | Asserts |
|---|---|
| Conformance | every registry surface has its box path, API allowlist entry, and (if editable) UI binding |
| Builder shape | each builder produces valid, correctly-shaped output offline; running twice is identical |
| Live parse + reconcile | every live owned file parses; no reconcile conflict left unresolved |
| Post-deploy smoke | RCon ping + `is-active` + live configs load |

Principle: **test the seams, not just the tiers.** Isolated tier tests pass while integration breaks.

---

## Migration — no big-bang, one file at a time

Delta path and two-copy path coexist while surfaces move across, each step reversible.

0. **Classify all 21 surfaces** A vs B; add `category` to the contract. Pure data, no deploy. *(safe under a freeze)*
1. **Build display-diff + whole-file save for ONE owned file** while the delta path stays untouched. *(additive, no deploy)*
2. **Migrate owned files one at a time** — seed the live copy from today's built output, switch its write path to whole-file, retire its delta entries. *(reversible)*
3. **Delete the delta engine** — remove `override-diff*.ts`, `config-overrides.json`, the selector apply. Editor moves to **CodeMirror 6**.
4. **Add reconcile-on-update + conformance gate.** Builders untouched throughout.

---

## Decisions log

- **2026-07-20** — Adopt the two-copy model; retire the delta/override engine. Why: the override model was re-implemented across browser/API/box and drifted silently, causing missed requirements and rewrites. Two copies move the diff off the write path.
- **2026-07-20** — Editor engine = **CodeMirror 6** (MIT). Why: native merge/diff view (the two-copy core UX), lints against the contract schema, far lighter than Monaco. `vscode.dev` is a hosted IDE, not embeddable; Monaco is its embeddable engine but heavier.
- **2026-07-15** — `spawn-points.json` → `map-points.json`.
- **2026-07-15** — VPP webhooks deprecated for command relay (event/FPS feed only).
- **2026-07-13** — Service renamed Webhooks → Api.

---

## Open items / known gaps

- **HELD** — config-duplication investigation (the map-tiles "dump" vs the web UI, multi-editor). Team is looking into it; no config work proceeds until it clears.
- **Test gap** — `Build-AILocations` runs at prestart but is not covered by `Test-Configs.ps1` (found in the 2026-07-20 doc audit). Add coverage when the hold lifts.
- **Doc cleanup** — stale references still live in other docs (`spawn-points.json` naming, short engine list, outdated Api action catalog, VPP-as-live). Those docs should defer their config-model explanation to this file rather than re-explain it.
