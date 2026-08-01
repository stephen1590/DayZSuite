# Scale-Ready - Project Plan

**Created:** 2026-07-24. **Reframed:** 2026-07-31 (owner) - see §1a. Nothing was removed in the reframe; four workstreams were added (U, G, T, P) and one wrong scoping call was corrected (§3).
**Basis:** the 2026-07-24 architecture audit (three readers: ConfigViewer JS, Api TS, cross-tier duplication) + the owner's four-needs statement of 2026-07-31 (recorded in [README.md](README.md) - that list is the spec this plan serves).
**Config-model source of truth:** [CONFIG-ARCHITECTURE.md](CONFIG-ARCHITECTURE.md). This plan orchestrates and schedules; it does not re-explain the config model.

---

## 1. Why this project

The audit found the codebase is **not slop** - it is honestly built, cleanly layered, well-documented. But it will not scale, for two specific reasons, plus one dangerous hidden one:

- **Wall 1 - the duplicated override engine (HIGH risk).** Override logic is written twice in two languages (Api TypeScript + box PowerShell), synced only by comments, using two different XPath engines. On the XML/PowerShell apply path there is no round-trip proof, so a selector can resolve to a different node on the box and write your edit to the **wrong place, silently.**
- **Wall 2 - the un-abstracted UI render pattern.** The build-string → `innerHTML` → `querySelectorAll` → `addEventListener` dance is copy-pasted 13+ times. Two god-files (`editor.js` 1199 lines, `map.js` 2064 lines). Adding a tab is 150-200 lines of the same dance rewritten. Fine at 6 tabs; breaks near 10.
- The Api backend is sound; only one small fix is in scope. *(Corrected 2026-07-31: the framework is sound, the write-VERB proliferation is not - see §3 and WS-U.)*

**The insight that shapes the plan:** retiring the override engine (the two-copy migration we already decided) is *also* the fix for the HIGH silent-drift risk. Wall 1's remedy and the drift remedy are the same work.

## 1a. The 2026-07-31 reframe (owner) - one disease, not two walls

Seven days of work proved the walls are symptoms. The disease: **mechanisms get built as one-offs and no migration ever finishes by deleting what it replaced.** Evidence, measured from code 2026-07-31:

- 7 parallel write verbs for "save a config" (`override-write`, `own-write`, `types-write`, `settings-write`, `file-write`, `spawn-write`, the patrol path) - each with its own validation/snapshot/concurrency semantics. `types-write` was built as "the prototype the generic verb replaces"; it was never replaced.
- ~7 distinct edit surfaces in the UI (Fields grid, whole-file textarea, json-editor navigator, own-editor CM6, the 540-line types-editor, the server-settings form, map.js bespoke editors).
- 5 hand-rolled generators, each inventing its own input layout; only custom-CE has a common→per-map overlay.
- 10 test files, zero runners - each test is a per-change artifact nothing re-runs.

**The standing rule this adds (encoded in GameServices/CLAUDE.md, enforced by WS-P gates): a migration is DONE when the replaced mechanism is DELETED. A new abstraction that leaves the old path alive is N+1, not 1 - it made the problem worse.**

## 2. Goals

- Remove Wall 1: retire the override delta engine; move to the two-copy model (`default` + `live`, diff shown not applied). *(Need 2.1)*
- Remove Wall 2: one reusable UI render primitive used by every view; split the two god-files. *(Need 1, UI face)*
- **One write path** (added 2026-07-31): every config save goes through the generic registry-driven verb; the bespoke verbs are migrated onto it and deleted. *(Need 1, write face)*
- **One propagation mechanism** (added 2026-07-31): generator inputs - including common files shared across the 3 maps - are declared in the registry and propagated by one engine, not N hand-rolled builders. *(Need 2.2)*
- **One test suite** (added 2026-07-31): a single runner discovers and runs every test; every deploy gate runs the runner fail-closed. A test outside the runner does not exist. *(Need 3)*
- **Enforced design** (added 2026-07-31): the design contract lives in the CLAUDE.md chain and in gate assertions - the two channels an agent cannot skip. *(Need 4)*
- Prove it scales: adding a new view/editor costs ~80 lines, not ~200, and no new copy of the render dance.
- Keep every step incremental and reversible; old and new paths coexist during migration - **but coexistence is a phase, not an end state: each migration closes with the deletion of the old path.**

## 3. Non-goals (explicit, so scope stays whole)

- Rewriting the Api wholesale. Its transport/auth/action framework is sound. **Corrected 2026-07-31: the config WRITE VERBS are NOT exempt** - the original "Api is sound and out of scope" call wrongly shielded the verb proliferation that need 1 targets; that is WS-U now. (The ~50-action split stays deferred - see WS-D.)
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
- **WS-U - One write path** (added 2026-07-31). Migrate each bespoke write verb (`types-write`, `settings-write`, `file-write`, `spawn-write`, the patrol path) onto the generic registry-driven path, then DELETE the verb. Per-surface validation stays - it becomes the registry row's `check`, not a private verb.
- **WS-G - One propagation mechanism** (added 2026-07-31). Generator inputs declared per registry row (`inputs:` - common + per-map); ONE engine renders them into the generated live files. The 5 builders become rows on that engine or thin wrappers over a shared library; each cutover deletes the bespoke logic it replaces.
- **WS-T - Testing architecture** (added 2026-07-31). One runner (`Invoke-Tests.ps1`) that discovers `tests/*.test.*` repo-wide; every deploy gate runs it fail-closed; one shared harness convention (one pass/fail counter, not three); cross-map behavior-parity assertions so the 3 missions cannot silently diverge. Tests are written FIRST (the existing CLAUDE.md TDD rule) - WS-T is what makes them KEEP running.
- **WS-S - One surface declaration, opt-in by default** (added 2026-08-01, owner ruling). Stop declaring which files are surfaces; declare only the exceptions. Every `.json`/`.xml` under the server dir is `rw` (visible, editable, mirrored) unless a path declares `ro` or `hidden`; folders inherit to everything beneath. Mirroring is DERIVED from access, which is what collapses "what is tracked" and "what is exposed" into ONE list. Kills 27+ rows of boilerplate and removes the silent-omission failure mode that lost the vehicle lifetimes. Model + the measured numbers: [CONFIG-ARCHITECTURE.md](CONFIG-ARCHITECTURE.md) § Surface access model. **Cannot ship without S6** - opt-in-by-default makes the deny list a security boundary.
- **WS-P - Design enforcement** (added 2026-07-31). The design contract goes into GameServices/CLAUDE.md (auto-loaded) and into gate assertions (fail-closed): mechanism counts (write verbs, editor mounts) may only go DOWN; a feature request names its surface category, editor, and write path before build. The niche leaf-cap assertion is the existence proof of this pattern.

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

### Added 2026-07-31 - WS-U / WS-G / WS-T / WS-P tasks (slot alongside Phases 0-3; deps below, not phase labels, order them)

**T1 - One test runner, wired fail-closed**
- Build `Invoke-Tests.ps1`: discovers `tests/*.test.*` (ps1 / sh / js) repo-wide, runs all, one summary. Wire into Deploy-DayZServer (beside Test-Configs), Deploy-Api, Deploy-ConfigViewer - red blocks the ship.
- **Acceptance:** every existing test file (10 as of 2026-07-31) runs from ONE command; a deliberately broken test blocks a deploy (proven non-vacuous, then reverted).
- **Deps:** none. **Do this first - every other task proves itself through it.** **Deploy:** none (dev tooling + deploy-script edit). **Reversible:** yes.

**T2 - Shared test harness + housekeeping**
- One pass/fail/counter convention shared by all tests (today there are three). Move `chat-format.test.js` out of `web/js/` - test files must never ship to the prod webroot.
- **Acceptance:** no test file inside a shipped directory; the runner counts every test; new tests get the shared harness by copying one pattern.
- **Deps:** T1. **Deploy:** ConfigViewer (removes the shipped test). **Reversible:** yes.

**E5 - server-settings.json: JSON editor + compile-on-save (owner clarification 2026-07-31, verbatim)**
> *"We are getting rid of the fields view, remember? Use the JSON/XML editor. The server-settings compiles (not explicit write) on a save to create our OWNED file, which only has fields matching default non-owned file. The settings-json is more of a web form to generate our owned file based on context in the form. It's a driver for the settings."*

- **The model this settles.** `server-settings.json` is a **2.2 file** (owner's own category: an input that GENERATES a direct replacement), not a write-path problem. It is the DRIVER; `serverDZ.cfg` is the generated owned output; `Apply-ServerCfg` is the compiler, and its allowlist is already closed and enforced at render time, so nothing an editor writes can widen it. My earlier framing ("which write verb?") was wrong - the question was never the transport.
- **Build:** (1) registry `Server-settings` `web:'patch'` → `'file'`, category stays `'input'` (accurate - it is a renderer input, not a game-read file); (2) `Deploy-Api` OWNED_FILES includes `'input'` rows - exactly ONE row exists, so the exposure is precisely this file; (3) `editor.js` drops the two `isCycleRow` special-cases that force the Fields view (lines ~365 and ~606), so it renders the standard JSON editor like every owned surface; (4) the cycle panel survives as computed CONTEXT above the editor, reading the two multipliers from the document instead of writing override rows (`wireCycle`'s `layerMapRW` commit path dies with the Fields view).
- **HARD ORDERING - do not ship these out of order.** The Api must deploy FIRST. `own-write` refuses any path not in the box's rendered OWNED_FILES, so a ConfigViewer-only deploy leaves server-settings.json with no working save path at all - the Fields view gone and own-write refusing. Api → verify the file appears as an owned surface → ConfigViewer.
- **Acceptance:** server-settings.json opens in the JSON editor; a save writes the whole file via own-write; the next prestart compiles serverDZ.cfg from it; the cycle numbers still show; no Fields view anywhere in the app.
- **Deps:** Api deploy. **Deploy:** Api THEN ConfigViewer. **Reversible:** yes (revert both, in reverse order).
- **BUILT 2026-07-31, NOT DEPLOYED.** Registry `web:'file'`; `Deploy-Api` mask is `category -in @('owned','input')` (dry run: owned surfaces 32 -> 33, exactly this file); both `isCycleRow` Fields-view forcings removed; `cycleHtml` is now READ-ONLY context computed from the document and rendered above the owned editor; `wireCycle`, `cycleVal` and the orphaned slider CSS deleted (a migration ends at deletion).
- **The ordering worry resolved itself - the existing design already handles it.** `r.ownFile` requires BOTH `isOwnedRel` (the Api's OWNED_FILES) AND `ownLayerCount === 0`, so while the 12 override rows are still on the box the row keeps the override editor and only flips to the JSON editor once the Api ships AND `Convert-ToOwned` empties the block. That flip IS the migration UX, exactly as the code comment at editor.js:266 intended. Interim caveat: in the window after a ConfigViewer ship but before the cutover, the row's default view is `edit`, which saves through the whole-file OVERRIDE path - functional, but it writes a `wholeFiles` entry, so do the cutover promptly.
- **UNVERIFIED IN A BROWSER** - no test covers rendering, and staging-vm is powered off. Needs a look on staging before prod.

**E6 - "View default" shows the default SIDE BY SIDE, not instead of (owner 2026-07-31, verbatim)**
> *"And click on view default should pull the default up along-side. Side by side comparisons are helpful :("*

- **Today it REPLACES.** `wfShowDefault` is a toggle: `editor.js:846` flips Live/Default and re-renders the same pane, and `editor.js:1002` ("View default") sets `wfShowDefault = true; ovrView = 'file'`. You lose the live text to see the default, so nothing can be compared at a glance.
- **The comparison already exists one surface over** - the own-editor mounts CodeMirror's `unifiedMergeView` against the frozen `.defaults` copy. So this is NOT a new capability, it is the same capability missing from the file/fields view. Reuse it rather than hand-rolling a second diff (need 1: abstract and reshare).
- **Build:** replace the Live/Default toggle with a two-pane compare in the file view - default on the left, live on the right - or mount the existing merge view there. Decide WHICH at design-proof time; do not build a third diff renderer either way.
- **Acceptance:** "View default" shows both copies at once; no surface renders a diff through code that is not the shared merge view.
- **Deps:** none. **Deploy:** ConfigViewer. **Reversible:** yes. **NOT BUILT** - UI, so it needs a design proof first (standing rule).

**T4 - Post-deploy LIVE verification (PINNED by the owner 2026-07-31 - deliberately deferred, NOT dropped)**
> Owner: *"Put a pin in testing until we're done with the overrides migration. Remember it. Don't forget. We need to expand testing."*

- **Why it is pinned, not cancelled:** T1 proved the code is self-consistent (GATED). NOTHING proves a deploy actually worked (LIVE). Measured 2026-07-31: all 14 test suites are fully offline - no test touches a running service - and no deploy calls any health check. `Confirm-LiveConfigs.ps1` already SSHes in and validates the live tree, and **no deploy has ever called it** - the same "a tool nobody remembers to run" disease T1 cured for tests.
- **Scope when unpinned (3 parts, ~2h):** (1) DayZ deploy calls `Confirm-LiveConfigs.ps1 -Env <env>` after the restart, `[WARN]` fails the deploy; (2) Api deploy fetches a real SIGNED route post-`deploy.sh` and fails on non-200 - not just `/health`; (3) ConfigViewer deploy re-fetches `index.html` + one JS module after the rsync and compares bytes against what it shipped (catches a half-synced webroot - the shape of the 2026-07-31 gallery outage where every route 500'd and only visitors noticed).
- **Unpin condition:** the override delta engine is DELETED (A3 done). Not before.
- **Deps:** A3. **Deploy:** all three (deploy-script edits). **Reversible:** yes.

**T3 - Cross-map parity assertions**
- For every map-scoped surface, assert the 3 missions agree on classification and shape unless the registry row DECLARES the divergence (e.g. Sakhal-only CE logging). "Behavior wildly differs between settings" becomes a red gate, not a discovery.
- **Acceptance:** an undeclared divergence between missions fails Test-Configs; declared ones are listed in the run output.
- **Deps:** C4. **Deploy:** none. **Reversible:** yes.

**U1 - Freeze the mechanism counts**
- Gate assertion: write-verb count and editor-mount count are pinned at today's values as a MAXIMUM. They may only go down.
- **Acceptance:** adding a write verb or a new box-writing UI module fails the gate with a message naming this plan.
- **Deps:** none. **Deploy:** none. **Reversible:** yes.
- **Delivered 2026-07-31** as `tests/mechanism-counts.test.ps1`, run by the T1 runner on ALL THREE deploys - deliberately NOT in Test-Configs, which only gates DayZ deploys while a new write verb ships via Deploy-Api. Measured pins: **6** write verbs (`override/spawn/file/types/own/settings-write` - the earlier "7" counted settings-write's `patrols` KEY as a verb), the **7-module set** of `apiPost` callers in `web/js` (editor, own-editor, types-editor, map, maintenance, logs + api-client defining it), and apiPost defined ONCE. Proven non-vacuous: a planted 7th verb and a planted writer module both went red with the stop-and-surface message, then reverted.

**U2 - Migrate each bespoke write verb onto the generic path, then DELETE it (rolling)**
- Worst-first order decided at start (candidates: `file-write`, `spawn-write`, `settings-write`, `types-write`, patrol path). Per verb: the registry row carries what the verb encoded (validator = `check`, pairing, scope), the UI switches to the generic call, the verb is deleted from dayz-ctl + actions.ts + the client. Per-surface validation SURVIVES - it moves into the row, not a private verb.
- **Acceptance per verb:** verb gone from all three tiers; behavior preserved (test written first); U1's count drops by one.
- **Deps:** U1, T1. **Deploy:** Api per verb. **Reversible:** per verb.

**G1 - Declare generator inputs in the registry**
- Every `computed`/`input` surface's row names its inputs (common + per-map) and its builder. The wiring leaves the scripts' insides and becomes data.
- **Acceptance:** conformance asserts every computed surface declares inputs + builder; no builder reads a path the registry does not know.
- **Deps:** C4. **Deploy:** none (data). **Reversible:** yes.

**G2 - One propagation engine (rolling)**
- One engine renders declared inputs → generated live files (common propagates to the 3 maps). The 5 builders become registry declarations or thin wrappers over the shared library; each cutover deletes the bespoke logic it replaces. Freeze-current-output proof per file (byte-identical before/after), same as the A2 pattern.
- **Acceptance per builder:** bespoke propagation logic deleted; output byte-identical; a new common→3-maps surface costs a registry row, not a script.
- **Deps:** G1, T1. **Deploy:** DayZ per builder (prestart scripts). **Reversible:** per builder.

**P1 - Design contract into GameServices/CLAUDE.md**
- The four needs + the retirement rule, compressed to the always-loaded file. A feature request is placed against the whole design - surface category, editor, write path - BEFORE building.
- **Acceptance:** the contract is in CLAUDE.md; Scale-Ready docs are pointed to from it.
- **Deps:** none. **Deploy:** none. **Reversible:** yes.

**E4 - Save confirmation names the files (owner request 2026-07-31, verbatim)**
> "saving should prompt for confirmation now. The dialogue should tell you what files you edited and are currently saving. I've seen warnings after switching pages, so I don't really know which I edited and can't tell, so I don't end up saving. It would be good to know what exactly I'm saving before confirming."

- Placement (per the design contract - placed BEFORE built): the page-switch warning the owner sees is `editor.js`'s overrides-doc dirty guard (editor.js:60-75, the header pill + beforeunload). own-editor.js, types-editor.js and map.js each hold a PRIVATE dirty state that guard cannot see - four parallel dirty mechanisms is WHY no file list is possible today. The fix is ONE dirty registry (file → dirty state), every editor reports into it; save prompts with the exact list of edited files; the unsaved-changes warning names them too. NOT a fourth bespoke dialog per editor - the registry is the mechanism, the dialog is one consumer.
- **Acceptance:** every save path prompts with the exact file list before writing; the page-switch/unsaved warning names the files; ONE dirty registry, zero per-editor private copies left.
- **Deps:** none to start; converges with U2 (the generic save path consumes the same registry). Design proof shown to the owner before the UI is built (standing rule).
- **Deploy:** ConfigViewer. **Reversible:** yes.
- **BUILT 2026-07-31 (design approved first), NOT DEPLOYED.** `web/js/dirty-files.js` is the one mechanism; the confirm dialog, the header pill and the tab-switch warning are its three consumers. Editors report names through `ownDirtyNames()` / `typesDirtyNames()` / `changedFiles()`. Note the honest limit: the browser's own reload/close dialog (`beforeunload`) shows fixed text no page can change - the named warning fires on tab switch and in the pill instead.

**P2 - Design decisions become gate assertions**
- Every design decision that CAN be asserted, IS: the U1 count freezes, the niche leaf-cap (exists - the pattern's proof), mods.conf single-owner (exists), T3 parity. New decisions add an assertion in the same named gate section, with the rationale in the failure message.
- **Acceptance:** a named "design contract" section exists in Test-Configs; each assertion's failure text says WHY and points here.
- **Deps:** U1, T3. **Deploy:** none. **Reversible:** yes.

### Added 2026-08-01 - WS-S tasks (REVISED twice on 2026-08-01; order S1 → S2 → S3 → S4 → S5 → S7, with S8 alongside)

> **Owner ruling:** *"The server box owns all files now... a 'drop in place' server config manager that doesn't need a deployment to seed files. I don't want these configs in my repo anymore."* Plus, on defaults: *"Generated files don't need defaults. Server made files (like types.xml) need defaults when a change is made (we need the original version persistent if we need to rollback to state 0)."*
>
> **The first cut of this section was wrong.** It proposed declaring `rw`/`ro`/`hidden` per path across three or four axes. Ownership is not a preference - it is **whoever writes the file last**, which the pipeline already encodes. The model is the five scenarios in [CONFIG-ARCHITECTURE.md](CONFIG-ARCHITECTURE.md#the-box-owns-every-config--ws-s-owner-ruling-2026-08-01); the only thing genuinely declared is the deny list.

**S1 - Freeze today's effective access map** — **DONE 2026-08-01** (`Scale-Ready/access-baseline.csv`, 907 files). Model spot-checked against real `dayz-ctl` on 44 of 44, then 30 of 30 after a correction: `writable` initially measured only the own-write gate and understated 5 files editable through a bespoke verb. Columns are now `writable` / `ownWritable` / `writableVia`.

**S2 - Capture state 0 on the first write** — **BUILT 2026-08-01, NOT DEPLOYED** (commit 1616f48).
- `own-write` captures `<stem>.defaults.<ext>` from the current bytes before replacing, only when none exists. No origin classification needed: own-write is replace-only, so every target pre-existed. Prestart capture retires to a backstop.
- `_defaults_path` restored to the template - the A3 delete had removed it, so the next Api deploy would have dropped the only code that can locate a baseline.
- `_own_check` takes a mode: a `.defaults` resolves masks against its STEM, is served on read, refused on write. Closes both prod defects at once (**served 0 of 33** beside file rows; **21 WRITABLE** under the Expansion dirs).
- **Acceptance:** met - `own-verbs.test.sh` 21 → 27, 8 new red first, 2 proven non-vacuous by reverting the read mode.
- **Deploy:** Api. **Reversible:** yes.

**S3 - Config leaves `$items`; the box owns it; write the deny list**
- Remove the 5 config rows from the deploy's `$items` (`custom-ce/{custom-ce.json, custom_types.xml, expansion_types.xml, expansion_spawnabletypes.xml, maps/dayzOffline.enoch/expansion_types.xml}`) so scenario 1 holds CODE ONLY. Delete the registry seed step with it - a drop-in-place manager does not seed.
- Write the deny list (scenario 4 + secret-bearing paths). That list is the whole declaration; everything else derives:
```
profiles/VPPAdminTools    STEAM_API_KEY + BanList player IDs
profiles/CodeLock         player lock permissions
profiles/users            player profile data
storage_*                 persistence, not config
mapgroup* / mapcluster*   vendor geometry: 25 files, 52.8 MB, never edited
profiles/LiveTracker      20s runtime snapshots - would churn git every pull
```
- **Absorbed S6 (owner, 2026-08-01).** S6 was scoped as a dynamic content scanner hunting `*_KEY`/password/token/Steam64 shapes across every non-hidden surface. Owner: *"You're just applying blanket guesses as a dynamic solution... this shouldn't change often and secrets should be known/static to begin with. Just hide them from the UI."* Correct - the secret-bearing paths are four known folders, not a discovery problem. What survives is ONE assertion that those four resolve to `hidden`, so a later refactor cannot silently drop a row. No content scanning.
- **There is no exposure today.** Those paths have no registry row, and today a file with no row is already invisible. The risk begins the moment opt-in-by-default ships - which is why the deny list and its assertion land in the SAME task, not as a separate gate in front of it.
- **Acceptance:** `$items` contains no `.json`/`.xml` config; a dry-run deploy reports zero config placements; the resolver reproduces the S1 baseline except for the intended, listed differences.
- **Deps:** S1, S2. **Deploy:** DayZ. **Reversible:** yes.

**S4 - Box masks derived, not declared**
- `Deploy-Api.ps1` renders the owned masks from the five-scenario resolver instead of per-row fields. `ro` becomes enforceable ON THE BOX rather than a UI convention.
- **Blocked on a decision:** 5 files carry a bespoke write verb (2 CE tuning via `types-write`, map-points via `spawn-write`, bans/allowlist via `file-write`). Making one `rw` grants it `own-write` **on top of** its existing verb - two write paths for one file. Either hold them out of the mask or retire the verb in the same change (WS-U). Not yet decided.
- **Deps:** S3. **Deploy:** Api.

**S5 - Mirror is a BACKUP, never a seed**
- Pull-Configs keeps mirroring every owned file for history and disaster recovery; nothing is ever copied from the mirror onto a running box. The per-row `seed`/`mirror` fields are deleted - both derive. `owned-mirror-contract.test.ps1` is rewritten against the resolver.
- **Deps:** S3. **Deploy:** DayZ.

**S7 - UI reads the mode; DELETE the per-row access fields**
- ConfigViewer takes the mode from the API instead of inferring it from `web`/`writable`/`category`. Then delete `web`, `writable`, `seed`, `mirror`. What survives per row is display metadata (`label`, `group`, `about`) and editor choice for the genuine one-offs.
- **Deps:** S4, S5. **Deploy:** ConfigViewer.

**S8 - Prove the generated set is complete**
- Every prestart builder declares its output paths, and a gate cross-checks them against the `generated` set. Found unverifiable 2026-08-01: all five builders write through a `$outPath` variable, so no grep can resolve them, and `mpmissions/*/custom/` (6 files Apply-CustomCE rewrites every boot) is in NEITHER the box mask nor any declaration. Harmless today because those files are not writable; under opt-in-by-default an edit would be silently wiped at next restart.
- **Deps:** none. **Deploy:** none. **Same class of blocker as S6 - a hazard the new default creates.**

**Known category error, not scheduled:** `cfgeconomycore.xml` is scenario 2 AND 3 at once - the UI edits the CE log toggles while `Apply-CustomCE` regenerates its `<ce folder="custom">` block every prestart. Two writers, one file; a whole-file save races the builder. It has to become a generator input, or the builder must stop writing it.

### Phase 4 - Verify scale (Definition of Done)

The project is DONE when:
- No override delta engine exists; no XPath apply runs on the box (Wall 1 + HIGH risk gone).
- Every editable config surface is a two-copy owned file or a computed artifact; `config-overrides.json` is deleted.
- Zero copies of the old render dance remain; every view uses the one primitive (Wall 2 gone).
- `editor.js` and `map.js` are split into single-purpose modules.
- Conformance + builder-shape + live-parse tests are green and fail-closed.
- Adding a new view costs ~80 lines (B5 proved it).
- **(2026-07-31) ONE generic write path remains; the bespoke verbs are deleted (U2 = 100%).**
- **(2026-07-31) ONE propagation engine renders every computed surface; the bespoke builders' propagation logic is deleted (G2 = 100%).**
- **(2026-07-31) `Invoke-Tests.ps1` runs every test in the repo and every deploy gate runs it fail-closed (T1-T3).**
- **(2026-07-31) The design contract lives in CLAUDE.md + gate assertions; mechanism counts can only fall (P1-P2).**

---

## 8. Sequencing summary

```
Phase 0  C1  C2  C3  C4                     (foundations, no prod risk)
Phase 1  A0  B0 -> B1 -> [A1 + B2 = pilot]  (the editor convergence)
Phase 2  A2 (rolling)   B3 (rolling)  B4
Phase 3  A3  A4         B5
Phase 4  verify / DoD

2026-07-31 additions (cross-cutting, slot alongside the phases):
  T1 FIRST (the runner - everything else proves through it), then U1 + P1 (cheap freezes)
  G1 (data)  ->  G2 (rolling)      U2 (rolling)      T2  T3  P2
```

WS-A (config/box) and WS-B (frontend) run largely in parallel after Phase 1, meeting only at the editor. WS-U/G/T/P are cross-cutting: T1/U1/P1 land immediately in any order after their deps; U2/G2 roll one mechanism at a time like A2/B3.

## 9. Risks + mitigations

- **R1 - the parallel UI effort builds an editor-ONLY abstraction.** Then it doesn't solve the 13-view wall; it adds a 14th pattern. **Mitigation:** the reusability constraint in the contract - the primitive is view-agnostic, the editor is its first consumer, not its owner. B0 sign-off gates this.
- **R2 - big-bang temptation.** **Mitigation:** incremental; both paths coexist; per-file / per-view reversibility; A3 (the delete) is gated on A2 being 100%.
- **R3 - XPath divergence writes to the wrong node DURING migration.** **Mitigation:** migrate the XML / whole-array overrides FIRST (A2 priority) and prefer whole-file for XML surfaces, removing the XPath apply before it can bite.
- **R4 - behavior drift when seeding live from built output.** **Mitigation:** freeze-current-output (the proven Sakhal-patrol cutover pattern); verify built output byte-identical before/after.
- **R5 - deploy coupling surprises.** **Mitigation:** every task names its deploy needs; most of WS-B is ConfigViewer-only rsync; WS-A touches Api + box.
- **R6 - collisions with the parallel session's commits.** **Mitigation:** this folder + PROGRESS tracker; explicit per-task owner; agree a branch/commit discipline in B0. *(This risk FIRED 2026-07-31: two sessions classified `db/types.xml` opposite ways - owned vs patch-niche - and both landed. The decision is logged as OPEN in CONFIG-ARCHITECTURE.md; T3/P2 assertions are the systemic fix.)*
- **R7 - half-migration / N+1 (added 2026-07-31 - this risk already fired repeatedly).** A new shared mechanism ships, the old one-offs stay "temporarily", and the count goes UP: own-write landed while types/settings/file/spawn-write all survived; json-editor-ui landed while every bespoke editor survived. **Mitigation:** the retirement rule (§1a) + U1/P2 count-freeze assertions - a migration without its deletion fails the gate, not the review.
- **R8 - tests rot the moment they pass (added 2026-07-31 - fired: 10 test files, zero runners).** Per-change TDD satisfies the letter of the change-notice rule while nothing ever re-runs the tests. **Mitigation:** T1 - the runner is wired into every deploy; a test outside the runner does not count as a test.

## 10. References

- [CONFIG-ARCHITECTURE.md](CONFIG-ARCHITECTURE.md) - two-copy model, migration steps 0-4, decisions log. WS-A's design source of truth.
- [UI-ABSTRACTION-CONTRACT.md](UI-ABSTRACTION-CONTRACT.md) - WS-B alignment spec.
- `../DayZ-Server/config-registry.json` - the surface registry (one contract, four consumers).
- The 2026-07-24 audit - the three-reader findings this plan is built on.
