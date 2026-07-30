# Config Architecture

> **Single source of truth** for how DayZ server config is managed across the box, the API, and the web UI. If any other doc, code comment, or artifact disagrees with this file, either this file wins or this file is wrong and gets fixed here first. Don't re-explain the config model elsewhere - point at this file.
>
> Rendered snapshots (presentation only, private Claude links): the *reassessment* and *two-copy-model* artifacts.

**Status: Phases 0-2 DONE (2026-07-29); Phase 3-4 pending owner decisions.** The two-copy path is LIVE: the generic own-read/own-write verbs + CM6 whole-file editor are deployed to prod, and all 15 chaotic patch targets are cut over - the box override doc is down from 14,881 to **175 leaves (-98.8%)**, the rump being genuine field tweaks + parked disabled-mod patches. The mirror is pulled + auto-committed (552b29b); the gate passes 24/0 against the slim world. `Apply-ConfigOverrides` still runs at prestart FOR THE RUMP until the Phase 3 decision (tiny patch niche for game-rewritten files vs full retirement). The worklist below is the per-file status ledger.

---

## Canonical names

Old docs drift on these. These are the truth, verified against code:

| Thing | Canonical | Retired name (do not use) |
|---|---|---|
| AI spawn store (frozen legacy) | `profiles/AI_Shared/map-points.json` (registry surface `Map-points`; read-only since the 2026-07-23 map inversion - live AI settings are the source) | `spawn-points.json`, `AI_Bandits/map-points.json` |
| The service | **Api** | Webhooks (renamed 2026-07-13) |
| VPP webhooks | event/FPS telemetry feed only | a live command-relay path (deprecated 2026-07-15) |

---

## Current model — what the box runs today

Three tiers. The box owns the truth; the API is a signed relay; the browser is a client.

- **Registry** — `DayZ-Server/config-registry.json`. One row per surface (21 today). Fields: `name`, `box`, `scope`, `seed`, `mirror`, `web`, `writable`, `check`. Four consumers read it: Api allowlist, Deploy seed-if-missing, Sync/Pull mirroring, Confirm-LiveConfigs parse-check.
- **Defaults** — `DayZ-Server/config-defaults/` holds frozen `<stem>.defaults.<ext>` baselines, refreshed by hand via `Generate-ConfigDefaults.ps1`.
- **Overrides** — `DayZ-Server/config-overrides.json` (**175 leaves after the 2026-07-29 Phase 2 sweep**; was 1.1 MB / 14,881 leaves at Phase 0, ~98 KB - was ~98 KB when this doc was written; the growth is 13 Loadout files + AirdropSettings expressed as patch lists) holds field-level deltas: dotted-path selectors for JSON, XPath for XML, layered common vs per-mission, plus a `wholeFiles` layer. Box-authoritative; the repo copy is a mirror. KNOWN ENGINE LIMIT (2026-07-29): `Apply-ConfigOverrides` uses `SelectSingleNode` - a multi-match XPath silently patches only the first node, so wildcard selectors are impossible.
- **Apply + build at prestart** — `deploy/prestart.sh` runs these engines in order, fail-soft (`|| true`) so bad config can't block boot *(list corrected 2026-07-29 - the AI draft builders and Babaku were retired 07-23/07-24)*:
  1. `Apply-ServerCfg.ps1` — serverDZ.cfg from template + host.env + server-settings.json
  2. `Apply-ConfigOverrides.ps1` — default + deltas → live file
  3. `Apply-CustomCE.ps1`
  4. `deploy/Build-TransferSpawns.ps1`
  5. `Build-MapPoints.ps1` — derives the read-only map store FROM live AI settings
- **Already on the target pattern** (whole-file, box-validated, snapshotted, `base=` optimistic concurrency): the CE types tuning pair via `types-write` (2026-07-23), `AIPatrolSettings.json` via `patrol-write` + the Sakhal manifest cutover (2026-07-24), and bans/whitelist via the older `set-file`. These three bespoke verbs are the prototypes the generic Phase 1 verb replaces.
- **The API** — Fastify/TS, relays signed HTTP → `sudo dayz-ctl` (closed verb set, re-validated on the box). ~38 actions in `Api/app/src/actions.ts`. Config edits: `override-diff.ts` / `override-diff-xml.ts` compute a delta, the box stores and applies it.
- **The web UI** — ConfigViewer, a dependency-free SPA. Hand-rolled editor (`editor.js`), `highlight.js`, `lossless-json.js`.

### The problem this causes

The override model is written three times — browser JS, API TS, box PowerShell — held in sync only by comments. Nothing proves the three agree, so they drift silently: a delta the API computes but the box applies differently falls back to whole-file or no-ops, with no error. That is the root cause of the "missed requirements and rewrites." Full diagnosis: the *reassessment* artifact.

---

## Target model — agreed 2026-07-20, BUILT through Phase 2 (2026-07-29; Phases 3-4 pending)

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

## Migration — no big-bang, one file at a time (ACTIVE, owner priority 2026-07-29)

Delta path and two-copy path coexist while surfaces move across, each step reversible.
The proven cutover trick (Sakhal AIPatrolSettings, 2026-07-24): **removing a file's block from
the manifest freezes the live file at its current built state** - behavior-preserving by
construction, because a file absent from the manifest is never rebuilt.

- [x] **Phase 0 — classify + re-baseline** (2026-07-29): registry rows carry `category`
      (owned | computed | reference); this doc corrected to current reality; worklist below.
- [ ] **Phase 1 — one generic whole-file mechanism.** Generalize `types-write`/`patrol-write`/
      `set-file` into ONE registry-driven verb (row's `check` picks the validator; snapshots +
      `base=` concurrency as proven). UI: two-copy diff view on **CodeMirror 6** (decision log)
      with **XML + JSON syntax editing** (owner requirement 2026-07-29). Folds in the
      deploy-owns-frozen-defaults item: the frozen default IS the `default` copy.
- [x] **Phase 2 — DONE 2026-07-29.** All 15 chaotic targets cut over (13 Loadouts incl.
      PlayerMaleSuit, AirdropSettings, BookSettings) + the empty SpawnerBubaku block deleted.
      One guarded override-write per file, every live file proven byte-identical throughout;
      AirdropSettings needed `force` (the shrink guard correctly flagged the deliberate
      mass-delete as its removal exceeded half the by-then-shrunken doc). Box doc:
      **14,881 -> 175 leaves (-98.8%)**. Rollback: one snapshot per step in .overrides-versions/
      (first: 20260729T233038Z). The rows now open the whole-file editor:
      cut the block (live file freezes), flip the row to the whole-file path, verify, next.
      ONE Loadout end-to-end first, then the other 12, then AirdropSettings, BookSettings.
      Owner call 2026-07-29: the Loadouts are OURS - they should always have been owned files.
      Quick win any time: delete the EMPTY SpawnerBubaku block.
- [x] **Phase 3 — DONE 2026-07-29 (both halves owner-decided).** Rump: patch niche KEPT
      (owner's scoping words; 175 leaves = genuine field tweaks + parked disabled-mod patches).
      Engine completed, not retired: Set-XmlNode patches EVERY XPath match (SelectNodes, TDD
      4/4, gate 24/0 - ships with the next DayZ deploy). Part 2 (retire override-diff*/Edit-file
      derive path) CLOSED AS SUPERSEDED - see decisions log; the path stays, bounded to the niche.

- [x] **Phase 4 engine — BUILT 2026-07-29.** `DayZ-Server/Reconcile-Defaults.ps1`: 3-way
      merge (old-default vs new-default vs live) via `git merge-file` per the decisions log.
      Report-only default; -Fix writes only a CLEAN parse-validated merge + adopts the new
      baseline; a CONFLICT never touches live - marker-annotated copy to reconcile-conflicts/
      for human review, resolved through the owned-file editor. TDD 7/7
      (tests/reconcile.test.ps1; fixture note: adjacent-line both-side edits are REAL diff3
      conflicts, verified). Part 2 DONE 2026-07-29: the capture
      pipeline already existed (Generate-ConfigDefaults -Run -> config-defaults-candidate/);
      the update-day runbook connecting capture -> 3-way merge -> owned-editor push -> gate is
      `DayZ-Server/docs/RECONCILE.md` (incl. the now-stale promote-mode assumption flagged).
      **Phase 4 COMPLETE - and with it every build phase of this migration.**

### Worklist — override targets by class (measured from the box doc, 2026-07-29: 36 targets, 14,881 leaves)

| Class | Targets | Leaves | Action |
|---|---|---|---|
| Whole-doc rewrites as patches | 13 Loadouts (~10.6k), AirdropSettings (4,009), BookSettings (111) | 14,686 (98.7%) | Phase 2 → owned files |
| Genuine field tweaks | 19 targets (globals timers, events lifetimes, server-settings, MapSettings, …) | 195 (1.3%) | hold for Phase 3 decision |
| Dead weight | SpawnerBubaku (EMPTY block), 3 parked disabled-mod targets, inert AIPatrols.control | ~57 | delete / stay parked |

---

## Decisions log

- **2026-07-29** — **Phase 3 part 2 CLOSED as superseded (owner call): the Edit-file derive path STAYS.** The 2026-07-20 "retire override-diff*" rationale was cross-language drift on BIG documents; Phase 2 removed every big document from the patch system, so the derive path now only ever sees the ~19-file / 175-leaf niche - and a parallel session rebuilt the path the same day (json-editor-ui structured navigator feeding preview-override). override-diff*.ts + configs/preview-override + the Edit-file view are KEPT with that bounded scope. If the niche ever regrows whole-document patches, this decision is wrong - the worklist classification is the guard.
- **2026-07-29** — **Phase 3 rump decision: KEEP the patch niche** for genuine field tweaks on game-rewritten baselines. ASSUMPTION adopted from the owner's own scoping words ("works well if your changes are basic or minimal fields") rather than a fresh ask - veto reverts it. Consequences: config-overrides.json (175 leaves) + Apply-ConfigOverrides STAY for the niche; what retires is the chaos machinery - override-diff*.ts / the whole-doc-edit-derives-delta UI path (queued); the kept engine got its completion: Set-XmlNode now patches EVERY XPath match (SelectNodes loop, tests/apply-overrides-multimatch.test.ps1 TDD 4/4, gate 24/0) so wildcard overrides ("all vehicle events") finally work.

- **2026-07-29** — Migration re-activated as OWNER PRIORITY. It never got scheduled after the 2026-07-20 agreement; in those 9 days the override doc grew ~98 KB → 1.1 MB (the Loadouts + AirdropSettings landed as patch lists) - the exact failure the target model predicted.
- **2026-07-29** — The Expansion Loadouts are OURS (owner statement): custom content that should always have been separate owned files, never override targets. They migrate in Phase 2.
- **2026-07-29** — The whole-file editor must support **XML editing with syntax support**, not just JSON (owner requirement). Covered by the CodeMirror 6 decision below (its `@codemirror/lang-xml` + merge view); the hand-rolled `highlight.js`/`cx-edit` overlay does not extend to this.
- **2026-07-20** — Adopt the two-copy model; retire the delta/override engine. Why: the override model was re-implemented across browser/API/box and drifted silently, causing missed requirements and rewrites. Two copies move the diff off the write path.
- **2026-07-20** — Editor engine = **CodeMirror 6** (MIT). Why: native merge/diff view (the two-copy core UX), lints against the contract schema, far lighter than Monaco. `vscode.dev` is a hosted IDE, not embeddable; Monaco is its embeddable engine but heavier.
- **2026-07-15** — `spawn-points.json` → `map-points.json`.
- **2026-07-15** — VPP webhooks deprecated for command relay (event/FPS feed only).
- **2026-07-13** — Service renamed Webhooks → Api.

---

## Open items / known gaps

- **Hold SUPERSEDED 2026-07-29** — the 2026-07-20 "no config work until the config-duplication investigation clears" hold was never formally lifted, but every config change since 07-21 proceeded past it, and the owner's 2026-07-29 priority directive supersedes it. ASSUMPTION surfaced to owner (2026-07-29): the hold is treated as moot. If the duplication investigation is still live, say so and Phase 1 pauses.
- **Test gap CLOSED by retirement** — `Build-AILocations` was retired to `archive/` in the 2026-07-23 map inversion (Phase 4); the uncovered-builder gap no longer exists.
- **Doc cleanup** — stale references still live in other docs (`spawn-points.json` naming, short engine list, outdated Api action catalog, VPP-as-live). Those docs should defer their config-model explanation to this file rather than re-explain it.
