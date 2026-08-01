# Config Architecture

> **Single source of truth** for how DayZ server config is managed across the box, the API, and the web UI. If any other doc, code comment, or artifact disagrees with this file, either this file wins or this file is wrong and gets fixed here first. Don't re-explain the config model elsewhere - point at this file.
>
> Rendered snapshots (presentation only, private Claude links): the *reassessment* and *two-copy-model* artifacts.

**Status (2026-07-31): Phases 0-2 and 4 DONE; the Phase 3 "keep a patch niche" decision is OVERRULED by the owner - the engine dies fully.** Owner's words (PROGRESS.md log, 2026-07-31): "No Overrides. Just whole file ownership and modifying with a better UI/Syntax manager." The two-copy path is LIVE (generic own-read/own-write + CM6/navigator editor on prod); the A2 tail cutover took the override doc from 14,881 to **12 leaves**, all `server-settings.json` (a generator INPUT, not an owned file - it moves to the settings-write path, then the engine + doc + `override-*` verbs + `override-diff*.ts` are deleted). `Apply-ConfigOverrides` still runs at prestart until that delete. **One OPEN decision blocks it: `db/types.xml`** - see Open items. The Phase 3 text below is kept as historical record.

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

The universal applier disappears. What replaces it: nothing for Category A, and builders for Category B. The diff moves from the write path (correctness-critical) to the read path (cosmetic if wrong). The 98 KB `config-overrides.json`, the selector grammar, and `override-diff*.ts` are all retired.

### Owner's statement of the model (2026-07-31 - the categories in the owner's own terms)

Every regular xml/json has a `*.defaults.*` copy beside it. Two kinds:

- **2.1 Direct replacements** = Category A above. The live file is edited whole; the default is the frozen diff baseline.
- **2.2 Generator inputs** = Category B above, with a requirement the original table under-specified: inputs include **COMMON files that propagate into multiple per-map files** (we edit for 3 maps). Propagation is ONE declarative mechanism - registry rows declare a surface's inputs and builder - not N hand-rolled builders each inventing its own layout. As of 2026-07-31 only custom-CE has a common→per-map overlay; the other builders (`Apply-ServerCfg`, `Build-TransferSpawns`, `Build-MapPoints`, `Build-BabakuSpawns`) are bespoke. Unifying them is **WS-G in [PLAN.md](PLAN.md)** (G1 declare inputs, G2 one engine, delete bespoke logic per cutover).

### The box owns every config — WS-S (owner ruling 2026-08-01)

Owner's words: *"The server box owns all files now. The server box (via ui) maintains the owned versions and keeps a .default if modified. This should be easily a 'drop in place' server config manager that doesn't need a deployment to seed files. I don't want these configs in my repo anymore."*

**Target: a drop-in-place config manager.** A fresh box installs DayZ and its mods, which write their own configs. The UI owns them from first touch. **No deploy step seeds config.** The repo ships CODE — scripts, PBOs, templates, `prestart.sh` — and nothing else.

#### Ownership is not a flag we pick. It is whoever writes the file LAST.

That is the whole model. Five scenarios, and `ro`/`rw` falls out of them rather than being declared per path:

| # | last writer | example | an edit on the box survives? | resolves to |
|---|---|---|---|---|
| 1 | **the deploy** (`$items`) | `custom-ce/expansion_types.xml`, `mods.conf`, `prestart.sh` | no — next deploy stamps it | `ro` |
| 2 | **the web editor** | `db/types.xml`, `expansion_types_tuning.xml`, `server-settings.json` | **yes** | `rw` — THE owned case |
| 3 | **a prestart builder** | `serverDZ.cfg`, `mpmissions/*/custom/*`, `map-points.generated.json` | no — next restart rebuilds it | `ro` + generated |
| 4 | **the game engine** | `storage_*/`, logs, `profiles/users/` | n/a — not config | `hidden` |
| 5 | **capture, once** | `*.defaults.*` | must not be edited | `ro` |

**Scenario 1 is a defect to remove, not a category to keep.** Five config files are still deploy-stamped (`custom-ce/{custom-ce.json, custom_types.xml, expansion_types.xml, expansion_spawnabletypes.xml, maps/dayzOffline.enoch/expansion_types.xml}`). Under the target they leave `$items` and become scenario 2. When scenario 1 holds only code, "the box owns every config" is true by construction and needs no declaration.

#### The `.defaults` rule — state 0, captured at the moment of change

Owner: *"Generated files don't need defaults. Server made files (like types.xml) need defaults when a change is made (we need the original version persistent if we need to rollback to state 0)."*

**Capture a default if one is missing, immediately before the first write. Never re-capture.**

No origin classification is required, because `own-write` is replace-only — `_own_check` requires the file to exist — so every write target already existed. "Pre-existing when we first touched it" IS "server/mod made". A generated file never reaches the write path at all (scenario 3 is `ro`), so it can never acquire one.

**Capturing at prestart is wrong and was actively harmful.** It runs AFTER the edit, so it freezes the edit as the baseline. Measured on prod 2026-08-01:

```
custom-ce/expansion_types_tuning.xml           81476 B  Jul 30 18:14
custom-ce/expansion_types_tuning.defaults.xml  81476 B  Jul 30 18:14
```

Same size, same second — the "baseline" is a copy of the change, so the diff shows nothing. Enoch identical. Capture belongs in the write verb; `Capture-OwnedDefaults` at prestart retires to a backstop.

**A default is immutable and readable.** Both were broken, in opposite directions, measured on prod: a companion beside a FILE row was refused entirely (**served 0 of 33** — the reason side-by-side comparison was impossible), while **21** companions under the four Expansion folders were fully WRITABLE because `OWNED_DIRS` matches by prefix. `_own_check` now resolves a `.defaults` path against its stem, serves it on read, and refuses it on write.

#### What the repo keeps

Code, plus a **read-only mirror** of the live configs for history and disaster recovery. The mirror is a BACKUP, never a seed — nothing is copied from it onto a running box. That distinction is what lets "no config in the repo as a source" and "the change is tracked in git" both be true.

#### Deny list — the only thing genuinely declared

Everything else is derived. What remains to write down is scenario 4 plus anything secret-bearing:

```
profiles/users            player profile data
profiles/VPPAdminTools    STEAM_API_KEY (empty today) + BanList player IDs
profiles/CodeLock         player lock permissions
profiles/LiveTracker      20s runtime snapshots - would churn git every pull
storage_*                 persistence, not config
mapgroup* / mapcluster*   vendor geometry: 25 files, 52.8 MB, never edited
```

Measured 2026-08-01: of 459 non-default json/xml under the server dir, those 25 geometry files hold 52.8 MB and the other 434 hold 8.0 MB. **WS-S cannot ship without the S6 gate** — a scan that fails closed on secret-shaped fields in anything not hidden. Opt-in-by-default makes this list a security boundary, and a boundary maintained by memory is not one.

**Defaults location convention (name the split, don't paper it):** on the BOX the default lives alongside the live file (`<stem>.defaults.<ext>`, written by Apply-ConfigOverrides for patch targets and `Capture-OwnedDefaults.ps1` for owned files). In the REPO, frozen baselines live in the parallel `config-defaults/` tree. Two conventions for one concept - acceptable while documented HERE, but any new code follows the box convention and reads locations from the registry, never hardcodes either layout.

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
- [x] **Phase 3 — decided 2026-07-29, then OVERRULED 2026-07-31 (see decisions log): the niche is NOT kept; the engine dies fully once `server-settings.json` moves to settings-write and the db/types.xml decision lands.** Historical record of the 07-29 decision: Rump: patch niche KEPT
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

- **2026-07-31** — **OWNER OVERRULE: no patch niche. The delta engine is deleted outright** ("No Overrides. Just whole file ownership and modifying with a better UI/Syntax manager"). This supersedes BOTH 2026-07-29 Phase 3 entries below (niche kept; Edit-file derive path stays) - they are historical record now. Deletion set: `Apply-ConfigOverrides.ps1` (out of prestart, then deleted), `config-overrides.json` + the selector grammar, `override-diff*.ts` + `configs/preview-override`, the `override-*` verbs. Gated on: `server-settings.json` rows → settings-write path, and the db/types.xml decision (Open items).
- **2026-07-31** — **Model restated in the owner's terms (§ "Owner's statement of the model"): 2.1 direct replacements + 2.2 generator inputs with common→per-map propagation as ONE mechanism.** The generator-unification gap became WS-G in PLAN.md. Same date, same source: tests must run as one continuously-run suite (WS-T), and design rules live in CLAUDE.md/gates, not silent readmes (WS-P).
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

## The no-data-loss rule for the engine delete (added 2026-07-31)

Freezing protects the LIVE box. It does not protect a REBUILT one. The deploy seeds a
missing config from its registry `seed` file, and today the overrides re-apply on top; once
they are deleted, **the seed IS the value**. So any override leaf that differs from its seed
is a value that silently reverts on a fresh/disaster-recovery box.

Measured on `server-settings.json` (2026-07-31): 10 of its 12 leaves were exact no-ops, and 2
were not - `serverTimeAcceleration` 5 → 8 and `serverNightTimeAcceleration` 4 → 4.5. Deleting
the engine without touching the seed would have quietly reverted the day/night cycle on any
rebuild, with nothing to notice it.

**Rule, now enforced by `tests/override-seed-parity.test.ps1` (registry-driven, runs on every
deploy):** every remaining override leaf must equal its seed value. Fix the seed to the value
actually in service, and the override row becomes a provable no-op - removable with zero effect
in BOTH directions, live and rebuilt. The seed was corrected to 8 / 4.5 accordingly.

**Do NOT hand-edit the repo's `config-overrides.json` to drop a block.** The box owns that file;
`Sync-ConfigOverrides.ps1` keeps a `last-synced.sha256` marker and REFUSES to pull (exit 3) over
a hand-edited working copy. Removal happens ON THE BOX via `Convert-ToOwned.ps1`, then
`Pull-Configs` mirrors the smaller document back.

## Open items / known gaps

- **DECIDED 2026-07-31 (owner): OWNED FILE WINS.** Owner's words: *"This isn't complicated. Owned file wins, but we need those 20 vehicle-lifetime sync'd into OUR owned files. They're not overrides anymore, but the agent was dumb and kept using the old approach. They SHOULD have been in our owned file."* So the lifetime VALUES stay - they move into the owned file and stop being overrides. Mechanism built for it: **`Convert-ToOwned.ps1`** (TDD 22/22), the generalized form of the freeze trick DayZ-Server/CLAUDE.md documented as a Sakhal hand-procedure. It verifies EVERY selector against the live file first and REFUSES if any value is not already live - because removing a block freezes the live file as it stands, so an unapplied row would silently lock in the wrong value. Report-only by default; `-Fix` removes the block and re-hashes the live file to prove it never changed. Same tool covers the other A3 blocker (`server-settings.json`) - one mechanism, both cutovers. **Runbook (box-side; the box is authoritative for the manifest - `Sync-ConfigOverrides.ps1`: "THERE IS NO DEV WRITE PATH THROUGH THIS FILE"):** 1. `./Convert-ToOwned.ps1 -ServerDir ~/servers/dayz-server -Target 'mpmissions/dayzOffline.sakhal:db/types.xml'` (report). If it REFUSES with unapplied rows, the box has not restarted since they were written - restart once (owner's call), then re-run. 2. same with `-Fix`. 3. repeat for `-Target 'files:server-settings.json'` after its 12 leaves move to the settings-write path. 4. `Pull-Configs` to mirror the now-empty manifest. 5. then, and only then, A3's delete. The superseded record: *(the conflict as found)* —
- **~~OPEN DECISION (owner)~~ (resolved above) — `db/types.xml` was classified BOTH ways and both were live (found 2026-07-31).** The registry (uncommitted) carries `typesSakhal`/`typesEnoch`/`typesChernarus` as `category:'owned'`/`web:'file'`; a parallel session simultaneously wrote ~19 vehicle-lifetime override rows onto the BOX and left `tests/vehicle-lifetime-overrides.test.ps1` asserting it is "NOT a whole-file ownership case". Both gate-green (the niche cap is 60 leaves; the block is ~19). The UI is safe only because override rows suppress the own-editor (`editor.js` `ownLayerCount === 0`), but `own-write` on the file is PERMITTED - a whole-file save would be partly re-patched at next boot. **Pick one:** (a) owned - cut the box rows over (removal freezes the live file; the pre-patch `.defaults` companion already exists, so the diff view keeps showing the lifetime tweaks), consistent with the 07-31 "no overrides" ruling; or (b) niche - drop the owned rows to `web:'view'`. The repo mirror has 0 of the box's rows; a Pull-Configs before the decision will import them.
- **Hold SUPERSEDED 2026-07-29** — the 2026-07-20 "no config work until the config-duplication investigation clears" hold was never formally lifted, but every config change since 07-21 proceeded past it, and the owner's 2026-07-29 priority directive supersedes it. ASSUMPTION surfaced to owner (2026-07-29): the hold is treated as moot. If the duplication investigation is still live, say so and Phase 1 pauses.
- **Test gap CLOSED by retirement** — `Build-AILocations` was retired to `archive/` in the 2026-07-23 map inversion (Phase 4); the uncovered-builder gap no longer exists.
- **Doc cleanup** — stale references still live in other docs (`spawn-points.json` naming, short engine list, outdated Api action catalog, VPP-as-live). Those docs should defer their config-model explanation to this file rather than re-explain it.
