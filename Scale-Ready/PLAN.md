# Scale-Ready - Project Plan

**Created:** 2026-07-24
**Basis:** the 2026-07-24 architecture audit (three readers: ConfigViewer JS, Api TS, cross-tier duplication).
**Config-model source of truth:** [../CONFIG-ARCHITECTURE.md](../CONFIG-ARCHITECTURE.md). This plan orchestrates and schedules; it does not re-explain the config model.

---

## 1. Why this project

The audit found the codebase is **not slop** - it is honestly built, cleanly layered, well-documented. But it will not scale, for two specific reasons, plus one dangerous hidden one:

- **Wall 1 - the duplicated override engine (HIGH risk).** Override logic is written twice in two languages (Api TypeScript + box PowerShell), synced only by comments, using two different XPath engines. On the XML/PowerShell apply path there is no round-trip proof, so a selector can resolve to a different node on the box and write your edit to the **wrong place, silently.**
- **Wall 2 - the un-abstracted UI render pattern.** The build-string → `innerHTML` → `querySelectorAll` → `addEventListener` dance is copy-pasted 13+ times. Two god-files (`editor.js` 1199 lines, `map.js` 2064 lines). Adding a tab is 150-200 lines of the same dance rewritten. Fine at 6 tabs; breaks near 10.
- The Api backend is sound; only one small fix is in scope.

**The insight that shapes the plan:** retiring the override engine (the two-copy migration we already decided) is *also* the fix for the HIGH silent-drift risk. Wall 1's remedy and the drift remedy are the same work.

## 2. Goals

- Remove Wall 1: retire the override delta engine; move to the two-copy model (`default` + `live`, diff shown not applied).
- Remove Wall 2: one reusable UI render primitive used by every view; split the two god-files.
- Prove it scales: adding a new view/editor costs ~80 lines, not ~200, and no new copy of the render dance.
- Keep every step incremental and reversible; old and new paths coexist during migration.

## 3. Non-goals (explicit, so scope stays whole)

- Rewriting the Api. It is sound. (One small fix, C3. A future split at ~50 actions is noted, not scheduled - see WS-D.)
- Changing the deploy model, the registry contract, or the box-owns-truth doctrine.
- Adding a build step or heavy framework to ConfigViewer beyond the decided pieces (CodeMirror 6 for text editing; a light render primitive for view chrome - see the contract).
- Formatting/naming as the headline. They are foundations (C1/C2), not the point.

## 4. Principles

- **One source of truth per concern** - the registry for surfaces; two whole copies per owned file.
- **Move the diff off the write path** - the UI shows it; the box never applies it.
- **Compose, don't copy** - one render primitive; no per-view re-implementation.
- **Incremental + reversible** - both paths coexist; migrate one file / one view at a time.
- **A part ships only when the whole is proven consistent** - a fail-closed conformance gate.

## 5. Workstreams

- **WS-A - Retire the override delta engine (config → two-copy).** Removes Wall 1 + the HIGH drift risk. Design detail lives in CONFIG-ARCHITECTURE.md.
- **WS-B - UI render abstraction + god-file split.** Removes Wall 2. **This is the workstream that must align with the parallel editor-UI effort** - see [UI-ABSTRACTION-CONTRACT.md](UI-ABSTRACTION-CONTRACT.md).
- **WS-C - Foundations.** Formatting + naming standard, TYPES_BASE → registry, conformance-test scaffold. Small, enabling.
- **WS-D - Deferred.** Api actions split at ~50 actions. Not scheduled; recorded so it is not lost.

## 6. The convergence point

WS-A and WS-B intersect at **the editor**. WS-A's first real deliverable is a whole-file editor that shows a default-vs-live diff (A1). That editor is built on CodeMirror 6 + the WS-B render primitive (B2). The parallel editor-UI abstraction lands exactly here. So: **the editor is the shared pilot for both workstreams.** Get its shape right (per the contract) and both walls start coming down at the same seam.

---

## Service impact + safe checkpoints (read before running anything)

**The running game server is decoupled from this work.** The chaos lives in the tooling - ConfigViewer, the Api, and the config pipeline - not in the server. Config edits *stage*; they never force a reboot. Stop the whole project at any point and the server keeps running its current config, untouched. Reboots are not a factor this project introduces.

### The real impact surface

| Deploy | Touches | Game / player impact |
|---|---|---|
| **none** | repo / data / dev | none |
| **ConfigViewer** (rsync static) | the web UI only | none |
| **Api** (service restart) | admin API, ~1s blip | none |
| **DayZ** (pipeline scripts) | prestart builders, applied at the next restart | behaviour-preserving; no forced reboot |

Almost every task is no-deploy or ConfigViewer/Api - **zero game impact**. The only server-pipeline touch is **A3** (editing `Apply-ConfigOverrides.ps1`); it ships a script that runs at the *next natural restart* (the ~6h cycle or an operator's choice), never a forced one.

### Why reboots are a non-factor

- **Staging, not applying.** Editing or migrating config changes the next-boot inputs; the live mission files the server is running now do not change until a restart it was having anyway.
- **Behaviour-preserving, proven offline.** Each migrated file's built output is verified byte-identical before/after (freeze-current-output, the Sakhal-cutover pattern), so a restart rebuilds the same files - a non-event.
- **Prestart is fail-soft** (`|| true`). Even a broken pipeline script cannot block boot; the server comes up on the existing live files.

### Safe checkpoints

- **Every task boundary is a safe stop.** The tooling is always in one of two working states - old path or migrated path - never a broken hybrid; both coexist until A3.
- **Interrupted mid-task (out of tokens, etc.):** repo edits are inert until the deploy step, so prod is untouched; after a successful deploy + verify, prod is in the new good state. The write-path self-protects during that window - atomic whole-doc writes, `base=sha` optimistic concurrency, auto-snapshots (`.overrides-versions/`, `.types-versions/`, ...), shrink guard.
- **Stranded is not a failure mode.** Stop anywhere and the server runs on; the half-migrated UI/API never reaches the game.

### The one point of no return

**A3 - delete the delta engine.** Do it deliberately when A2 = 100% and the C4 conformance gate is green. Recoverable via git revert + redeploy, behaviour-preserving at the next restart, fail-soft if wrong. It is the one step not to *start* on low runway - everything before it is coexisting and reversible.

---

## 7. Phased tasks

Each task carries: **acceptance** (done = this is true), **deps**, **tier(s)**, **deploy** (what must redeploy), **reversible**, **owner** (this-plan / editor-UI-chat / either).

### Phase 0 - Foundations

**C1 - Prettier + config**
- Add repo dev-tooling: root `package.json` (dev-only, `node_modules` gitignored, never shipped), `.prettierrc` (`singleQuote: true`, `semi: true`, `printWidth: 100`, `tabWidth: 2`, `trailingComma: all`), `.prettierignore` (node_modules, dist, web/tiles, the wiki submodule, generated files). One format-only commit.
- **Acceptance:** `prettier --check` clean; Api `tsc` compiles; every ConfigViewer JS still parses (`node --check`); `lossless-json.js`/`.ts` still in sync and the `` sentinel untouched.
- **Deps:** none. **Tier:** dev-tooling. **Deploy:** none. **Reversible:** yes. **Owner:** this-plan.

**C2 - Naming + code-style rule**
- Add a short **Code style** section to the GameServices CLAUDE.md: functions are verbs, no 1-2 char names except loop indices, no cryptic abbreviations (`state` not `st`, `element` not `el`). Applies to all new code.
- **Acceptance:** rule present; new code in later phases follows it. Existing-name renames are their own later pass, not bundled into format commits.
- **Deps:** none. **Tier:** docs. **Deploy:** none. **Reversible:** yes. **Owner:** this-plan.

**C3 - TYPES_BASE → registry**
- Move the hardcoded `TYPES_BASE` map out of `types-editor.js` into a `config-registry.json` field; the editor reads it. (Audit MEDIUM: adding a 3rd types surface currently crashes the editor.)
- **Acceptance:** a hypothetical 3rd types surface added to the registry does not crash the editor; registry is the sole source of the base↔tuning pairing.
- **Deps:** none. **Tier:** registry + ConfigViewer (+ Api if the pairing is rendered into CONFIG_MAP). **Deploy:** ConfigViewer (+ Api if needed). **Reversible:** yes. **Owner:** this-plan.

**C4 - Conformance-test scaffold**
- Stand up the fail-closed gate test: every registry surface has its box path, its Api allowlist entry, and (if editable) its UI binding. Start green for today's surfaces.
- **Acceptance:** the test runs in `Test-Configs.ps1` (or a sibling); it passes now and fails if a surface is half-wired across tiers.
- **Deps:** none. **Tier:** test. **Deploy:** none. **Reversible:** yes. **Owner:** this-plan.

### Phase 1 - Two-copy foundation + UI primitive + the pilot

**A0 - Classify surfaces**
- Classify all ~21 registry surfaces **A (owned)** vs **B (computed)**; add a `category` field to the registry. Data only.
- **Acceptance:** every surface tagged A or B; C4 asserts `category` present on every row.
- **Deps:** C4. **Tier:** registry. **Deploy:** none (data). **Reversible:** yes. **Owner:** this-plan.

**B0 - Agree the render primitive (the contract)**
- Finalize [UI-ABSTRACTION-CONTRACT.md](UI-ABSTRACTION-CONTRACT.md) with the parallel editor-UI effort. Choose the primitive; accept the reusability constraint (one primitive for all views).
- **Acceptance:** contract signed off by both efforts; primitive chosen; open decisions resolved.
- **Deps:** none. **Tier:** design. **Deploy:** none. **Reversible:** yes. **Owner:** editor-UI-chat + this-plan (joint).

**B1 - Build the primitive + one reference view**
- Vendor/build the chosen primitive; convert ONE simple view (candidate: the maintenance stats bar or the logs source selector) as the reference implementation.
- **Acceptance:** the converted view renders and binds events with **zero** manual `querySelectorAll`/`addEventListener`; behavior identical to before.
- **Deps:** B0. **Tier:** ConfigViewer. **Deploy:** ConfigViewer (rsync). **Reversible:** yes. **Owner:** editor-UI-chat.

**A1 - Pilot: whole-file + diff editor for ONE owned file**
- Build display-diff + whole-file save for a single Category-A file, on CodeMirror 6 + the primitive (B2 seam). The delta path stays untouched and functional.
- **Acceptance:** the pilot file is editable as a whole file with a default-vs-live diff shown; the old delta path still works for every other file; proven offline (no prod deploy required to demonstrate).
- **Deps:** A0, B1. **Tier:** ConfigViewer (+ Api read/write verbs if the whole-file save path is new). **Deploy:** ConfigViewer (+ Api if new verbs). **Reversible:** yes. **Owner:** editor-UI-chat + this-plan (this is the convergence).

### Phase 2 - Roll out both walls

**A2 - Migrate owned files, one at a time**
- Priority order, worst-first: the **big whole-array overrides (Expansion loadouts, airdrop, market)** - they bloat `config-overrides.json` AND carry the XPath drift risk. Per file: seed the live copy from today's built output (freeze-current-output, the proven Sakhal-patrol pattern), switch its write path to whole-file, retire its delta entries.
- **Acceptance:** each migrated file edits as a whole file; it is removed from the `config-overrides.json` manifest; behavior-preserving (built output byte-identical before/after); the next mirror pull carries the smaller doc.
- **Deps:** A1. **Tier:** box (PowerShell) + registry + ConfigViewer. **Deploy:** per file - Api and/or ConfigViewer as its verbs/UI change; a DayZ deploy only if a builder input changes. **Reversible:** yes (per file). **Owner:** this-plan.

**B3 - Roll the primitive across the remaining views**
- Convert every remaining view to the primitive.
- **Acceptance:** `grep` proves **zero** instances of the build-string → `innerHTML` → `querySelectorAll` → `addEventListener` dance remain.
- **Deps:** B1, B2. **Tier:** ConfigViewer. **Deploy:** ConfigViewer. **Reversible:** per view. **Owner:** editor-UI-chat + this-plan.

**B4 - Split the god-files**
- Break `editor.js` (6 responsibilities) and `map.js` (5) into single-purpose modules.
- **Acceptance:** no file mixes >1 responsibility; each module single-purpose; import graph still a DAG (no cycles); behavior unchanged.
- **Deps:** B3 (views on the primitive first, so the split is mechanical). **Tier:** ConfigViewer. **Deploy:** ConfigViewer. **Reversible:** yes. **Owner:** this-plan.

### Phase 3 - Delete the old engine + harden

**A3 - Delete the delta engine**
- Remove `override-diff.ts`, `override-diff-xml.ts`, `config-overrides.json`, and the selector-apply in `Apply-ConfigOverrides.ps1`. Editor fully on CodeMirror; no view depends on the delta path.
- **Acceptance:** no code path references the delta engine; **the HIGH XPath-divergence risk is gone** (no XPath apply on the box); all tests green; a from-scratch box boot produces identical live files.
- **Deps:** A2 complete (every owned file migrated). **Tier:** Api + box + ConfigViewer. **Deploy:** Api + ConfigViewer + DayZ. **Reversible:** via git (this is the point of no return - gated on A2 being 100%). **Owner:** this-plan.

**A4 - Reconcile-on-update + conformance gate enforced**
- Add the update-time 3-way reconcile (old-default vs new-default vs live, human-reviewed) for owned files. Turn the C4 conformance gate fail-closed in the pre-deploy path.
- **Acceptance:** a game/mod update surfaces owned-file conflicts for review instead of silently re-stamping; the gate blocks ship if any surface is not wired across all tiers.
- **Deps:** A3, C4. **Tier:** box + test. **Deploy:** DayZ. **Reversible:** yes. **Owner:** this-plan.

**B5 - Scale smoke test**
- Add a throwaway new tab using the primitive; measure the cost.
- **Acceptance:** the new view is ~80 lines and wired with no boilerplate; then removed. Proves Wall 2 is down.
- **Deps:** B3, B4. **Tier:** ConfigViewer (throwaway). **Deploy:** none. **Reversible:** yes. **Owner:** this-plan.

### Phase 4 - Verify scale (Definition of Done)

The project is DONE when:
- No override delta engine exists; no XPath apply runs on the box (Wall 1 + HIGH risk gone).
- Every editable config surface is a two-copy owned file or a computed artifact; `config-overrides.json` is deleted.
- Zero copies of the old render dance remain; every view uses the one primitive (Wall 2 gone).
- `editor.js` and `map.js` are split into single-purpose modules.
- Conformance + builder-shape + live-parse tests are green and fail-closed.
- Adding a new view costs ~80 lines (B5 proved it).

---

## 8. Sequencing summary

```
Phase 0  C1  C2  C3  C4                     (foundations, no prod risk)
Phase 1  A0  B0 -> B1 -> [A1 + B2 = pilot]  (the editor convergence)
Phase 2  A2 (rolling)   B3 (rolling)  B4
Phase 3  A3  A4         B5
Phase 4  verify / DoD
```

WS-A (config/box) and WS-B (frontend) run largely in parallel after Phase 1, meeting only at the editor.

## 9. Risks + mitigations

- **R1 - the parallel UI effort builds an editor-ONLY abstraction.** Then it doesn't solve the 13-view wall; it adds a 14th pattern. **Mitigation:** the reusability constraint in the contract - the primitive is view-agnostic, the editor is its first consumer, not its owner. B0 sign-off gates this.
- **R2 - big-bang temptation.** **Mitigation:** incremental; both paths coexist; per-file / per-view reversibility; A3 (the delete) is gated on A2 being 100%.
- **R3 - XPath divergence writes to the wrong node DURING migration.** **Mitigation:** migrate the XML / whole-array overrides FIRST (A2 priority) and prefer whole-file for XML surfaces, removing the XPath apply before it can bite.
- **R4 - behavior drift when seeding live from built output.** **Mitigation:** freeze-current-output (the proven Sakhal-patrol cutover pattern); verify built output byte-identical before/after.
- **R5 - deploy coupling surprises.** **Mitigation:** every task names its deploy needs; most of WS-B is ConfigViewer-only rsync; WS-A touches Api + box.
- **R6 - collisions with the parallel session's commits.** **Mitigation:** this folder + PROGRESS tracker; explicit per-task owner; agree a branch/commit discipline in B0.

## 10. References

- [../CONFIG-ARCHITECTURE.md](../CONFIG-ARCHITECTURE.md) - two-copy model, migration steps 0-4, decisions log. WS-A's design source of truth.
- [UI-ABSTRACTION-CONTRACT.md](UI-ABSTRACTION-CONTRACT.md) - WS-B alignment spec.
- `../DayZ-Server/config-registry.json` - the surface registry (one contract, four consumers).
- The 2026-07-24 audit - the three-reader findings this plan is built on.
