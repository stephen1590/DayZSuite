# Scale-Ready - Progress

Canonical status tracker (git-tracked). The [Claude Artifact dashboard](https://claude.ai/code/artifact/c4278af0-a112-4e25-a305-979b22b0452f) mirrors this file - **update here first**, then reflect it in the artifact.

**Status legend:** `TODO` · `WIP` (in progress) · `BLOCKED` · `REVIEW` · `DONE`
**Owners:** `plan` (this effort) · `ui-chat` (parallel editor-UI abstraction) · `joint`

**Rollup:** 20 / 42 done · **Workstream A COMPLETE — A3 shipped, the delta engine is deleted and off both boxes (32/0 gate)** · every E-row (E1-E11) is now LIVE; E5/E7/E10 want your eye in a browser · **WS-S:** S1 + S2 done, S6 absorbed into S3, **S8 is the only blocker left** · **Workstream B still not started** — B1 unbuilt, and `editor.js` only shrank because A3 deleted code, not because it was split · **T4 UNPINNED** — its condition (the overrides migration) is met · last updated **2026-08-01 (sixth pass)**.

> **2026-07-31 reconciliation.** This file sat untouched from 2026-07-24 while work continued
> against `CONFIG-ARCHITECTURE.md` alone - so Workstream A progressed, B and C did not, and
> nobody was reading the rollup. `CONFIG-ARCHITECTURE.md` has been MOVED into this folder: it is
> Workstream A's design doc, not a second plan. Status below is measured from code, not recalled.
>
> **Wall 2 moved the WRONG WAY.** Audit baseline vs today:
>
> | | audit 2026-07-24 | 2026-07-31 | |
> |---|---|---|---|
> | `editor.js` | 1199 lines | **1297** | +98 |
> | `map.js` | 2064 lines | **2530** | +466 |
> | `innerHTML` sites | "13+" | **46** (23+23) | — |
>
> Every feature since the audit was built INTO the god-files, because B1 (the render primitive)
> was never built to build them on. That is the compounding cost the audit predicted.

---

## Workstreams
- **S** - the box owns every config (owner 2026-08-01). Ownership is whoever writes the file LAST, not a flag we pick; the only declaration is the deny list.
- **A** - retire the override delta engine (two-copy). Removes Wall 1 + the HIGH drift risk.
- **B** - UI render abstraction + god-file split. Removes Wall 2. Aligns with the parallel editor-UI effort.
- **C** - foundations (formatting, naming, TYPES_BASE, conformance scaffold).
- **D** - deferred (Api split at ~50 actions). Not scheduled.

## Task board

| ID | Phase | Workstream | Task | Owner | Deps | Deploy | Status |
|----|-------|-----------|------|-------|------|--------|--------|
| C1 | 0 | C | Prettier + config (format-only commit) | plan | - | none | TODO — no config file exists |
| C2 | 0 | C | Naming / code-style rule in CLAUDE.md | plan | - | none | TODO — absent from CLAUDE.md |
| C3 | 0 | C | TYPES_BASE → registry field | plan | - | ConfigViewer (+Api?) | TODO — still hardcoded, `types-editor.js:17` |
| C4 | 0 | C | Conformance-test scaffold | plan | - | none | WIP — `ConfigViewer/tests/` has mocks + own-editor harness; no conformance test |
| A0 | 1 | A | Classify 21 surfaces A/B; add `category` | plan | C4 | none | **DONE** 2026-07-29 — registry rows carry `category` |
| B0 | 1 | B | Agree the render primitive (sign the contract) | joint | - | none | TODO — contract unsigned |
| B1 | 1 | B | Build primitive + one reference view | ui-chat | B0 | ConfigViewer | TODO — `ui.js`/`dom.js` are helpers (escapeHtml/toast/$), NOT a render primitive |
| A1 | 1 | A/B | Pilot: whole-file + diff editor for ONE owned file | joint | A0, B1 | ConfigViewer (+Api?) | **DONE** — `own-editor.js` + CM6 `unifiedMergeView`, LIVE since 2026-07-30 01:31 |
| A2 | 2 | A | Migrate owned files one at a time (loadouts/airdrop first) | plan | A1 | per file | **DONE 2026-07-31** — tail cut over in 2 guarded ops (BanditLoadout 359 leaves, then the remaining 20 files). Doc **67,649 → 2,742 bytes**; **548 → 12 leaves**. All 23 live files verified BYTE-IDENTICAL before/after. Only `server-settings.json` (12 leaves) remains, deliberately - it is the generator input, not an owned file |
| B3 | 2 | B | Roll primitive across remaining views | joint | B1, A1 | ConfigViewer | TODO — blocked on B1 |
| B4 | 2 | B | Split god-files (editor.js, map.js) | plan | B3 | ConfigViewer | **IMPROVED, not by B4** — `editor.js` **1314 → 604 lines** and innerHTML 23 → 10, as a side effect of A3 deleting the override editor. `map.js` unchanged at **2533**. The split B4 actually calls for has still not been done |
| A3 | 3 | A | Delete the delta engine (point of no return) | plan | A2=100% | Api+ConfigViewer+DayZ | **DONE + LIVE 2026-08-01** — the delta engine is deleted in the repo and off both boxes. `tests/override-engine-deleted.test.ps1` **32/0**: applier, manifest, Sync script, prestart call, 4 dayz-ctl verbs, 6 API actions, `override-diff*.ts`, the browser editor and 5 retired tests all provably absent. Prod verified after restart: 0 override lines in prestart, all 12 formerly-forced settings KEPT |
| A4 | 3 | A | Reconcile-on-update + conformance gate fail-closed | plan | A3, C4 | DayZ | WIP — `Reconcile-Defaults.ps1` built (7/7); gate asserts niche cap + mods.conf single-owner (Test-Configs **27/0 green**, re-run 2026-07-31 against the working tree) |
| B5 | 3 | B | Scale smoke test (new tab ~80 lines) | plan | B3, B4 | none | TODO |
| E1 | 2 | B | **Deprecate the "Fields" view for OWNED surfaces; "Edit" is the default, XML included** | plan | - | ConfigViewer | **LIVE 2026-08-01** — deployed; Fields view unreachable, `edit` is the default for every owned row |
| E2 | 2 | B | **Edit view: drop the full box border, keep a single left "thread" rule** | plan | - | ConfigViewer | **LIVE 2026-08-01** — deployed |
| E3 | 2 | B | **Per-file description + metadata under the filename, sourced from the DayZ config knowledge base** | plan | - | Api+ConfigViewer | **DONE 2026-07-31** — registry `about`/`aboutUrl` → CONFIG_MAP (8 cols) → config-list → `aboutBlock()` in all three chromes. 27 rows carry text; LIVE (Api deployed 04:32, ConfigViewer editor.js 04:23). Source: https://low.ms/knowledgebase/dayz-server-configuration |
| E4 | 2 | B/U | **Save confirmation names the edited files (owner 2026-07-31 - verbatim quote in PLAN.md); ONE dirty registry across all editors** | plan | - | ConfigViewer | **LIVE 2026-08-01** — deployed; all 4 save paths confirm by filename |
| T1 | 0 | T | ONE test runner (`Invoke-Tests.ps1`), wired fail-closed into all 3 deploys | plan | - | none | **DONE 2026-07-31** (ae27bac) — runner at repo root, TDD 17/17 (seen red first), repo run 10/10 in ~6.5s; wired into all 3 deploys (dry-run warns, ship aborts, `-SkipTests` escape, missing runner = hard stop); non-vacuous: planted red suite flipped Deploy-Api's gate to "would be blocked", then removed |
| T2 | 0 | T | Shared test harness convention; no test ships to the webroot | plan | T1 | ConfigViewer | PARTLY DONE — `chat-format.test.js` still ships to the webroot. Counter styles now 4 (ps1 / sh / js / node:test) |
| T3 | 2 | T | Cross-map parity assertions (3 missions agree unless registry-declared) | plan | C4 | none | TODO |
| E5 | 3 | A/B | **server-settings.json: JSON editor + compile-on-save (owner clarification verbatim in PLAN.md E5)** | plan | Api deploy | Api THEN ConfigViewer | **LIVE 2026-08-01** — Api + ConfigViewer both deployed; server-settings.json edits in the JSON editor. NOT verified in a browser by me |
| E6 | 2 | B | **"View default" shows the default SIDE BY SIDE (owner 2026-07-31, verbatim in PLAN.md E6)** | plan | - | ConfigViewer | **DONE + LIVE 2026-08-01** — the blocker was the BOX, not the UI: `_own_check` matched `OWNED_FILES` with `grep -qxF`, so a `.defaults` companion was refused for every file row (**served 0 of 33**). `_own_check` now takes a mode — a `.defaults` resolves against its stem, is served on read, refused on write. Measured after deploy: **25 served, 8 refused, all 8 correct** (5 disabled-mod + 3 non-json/xml). Also closed the inverse hazard: 21 baselines under the Expansion dirs had been WRITABLE |
| E7 | 2 | B | **RO/RW badge is inconsistent - only some rows show it** | plan | - | ConfigViewer | **LIVE 2026-08-01** (1ac7ed6) — every row states its access; the override count no longer replaces the badge. Not verified in a browser by me |
| E8 | 2 | B | **Lingering "overrides" / "Use Fields" language in the UI** | plan | - | ConfigViewer | **DONE 2026-08-01** — the vocabulary went with the engine (A3). Remaining `overrid*` in shipped JS: 42 comments + `types-editor.js`, which is CORRECT usage — the CE tuning file genuinely overrides the base types at load time. `'Use Fields'` / `ovrView`: **0 occurrences** |
| E9 | 2 | B | **"N overridden" count shown with no context and no highlights** | plan | - | ConfigViewer | **DONE 2026-08-01** — per-field delta tracking died with the engine (A3); there is no count to show |
| E10 | 2 | B | **BBP_Settings.json: "Whole-file view unavailable - not readable on the box."** | plan | - | ConfigViewer+Api | **LIKELY DONE, needs your eye** — two separate causes both fixed today: the whole-file view (1ac7ed6) and the phantom unsaved-change on this exact file (4ef6b3f, number-literal reformatting). Deployed. Open it and say if anything is still wrong |
| E11 | 2 | B | **Edit view still says "Deltas only... Save writes just your changes to config-overrides.json"** | plan | A3 | ConfigViewer | **DONE 2026-08-01** — the delta text described a mechanism that no longer exists (A3) |
| T4 | 3 | T | **Post-deploy LIVE verification (health checks in all 3 deploys)** | plan | A3 | all 3 | **PINNED by owner 2026-07-31** — *"Put a pin in testing until we're done with the overrides migration. Remember it. Don't forget. We need to expand testing."* Deferred, NOT dropped. Measured gap: all 14 suites are offline (no test touches a running service) and no deploy calls a health check; `Confirm-LiveConfigs.ps1` exists and is never invoked. UNPIN WHEN A3 IS DONE |
| U1 | 0 | U | Freeze mechanism counts (write verbs, editor mounts) as gate maximums | plan | - | none | **DONE 2026-07-31** — `tests/mechanism-counts.test.ps1` via the T1 runner (gates ALL 3 deploys, incl. Deploy-Api which Test-Configs never sees): 6 write verbs max (the old "7" miscounted settings-write's patrols key), the 7-module `apiPost`-caller set pinned by name, apiPost single-definition. Non-vacuous: planted verb + planted writer both red, reverted |
| U2 | 2 | U | Migrate each bespoke write verb onto the generic path, DELETE it (rolling) | plan | U1, T1 | Api per verb | TODO — candidates: file-write, spawn-write, settings-write, types-write, patrol path |
| G1 | 1 | G | Registry rows declare generator inputs + builder | plan | C4 | none | TODO |
| G2 | 2 | G | ONE propagation engine (common → 3 maps); bespoke builder logic deleted per cutover | plan | G1, T1 | DayZ per builder | TODO — 5 bespoke builders today; only custom-CE has a common→per-map overlay |
| P1 | 0 | P | Design contract into GameServices/CLAUDE.md | plan | - | none | **DONE 2026-07-31** (396023d) — contract section in GameServices/CLAUDE.md, committed |
| P2 | 2 | P | Design decisions as named gate assertions (counts, parity, niche cap) | plan | U1, T3 | none | TODO — niche cap + mods.conf single-owner already exist as the pattern's proof |
| S1 | 1 | S | Freeze today's effective access map (`access-baseline.csv`) | plan | - | none | **DONE 2026-08-01** — 907 files; model spot-checked against real `dayz-ctl` 44/44 then 30/30 after a correction (`writable` had measured only the own-write gate, understating 5 bespoke-verb files) |
| S2 | 1 | S | Capture state 0 on the first write; `.defaults` readable, never writable | plan | - | Api | **DONE + LIVE 2026-08-01** (1616f48, Api deployed 23:17) — capture moved INTO own-write, before the replace. Prestart capture REMOVED (4bbee2b, not yet deployed) — it read post-edit content and froze the edit as the baseline, proven twice on prod. own-verbs 21→27 |
| S3 | 2 | S | Config leaves `$items`; the box owns it; write the deny list | plan | S1, S2 | DayZ | TODO — 5 `custom-ce` config files are still deploy-stamped. **Absorbed S6** (owner 2026-08-01): a dynamic secret-scanner was the wrong shape - the secret-bearing paths are 4 known folders, so they go in the deny list with ONE assertion that they resolve `hidden`. No exposure exists today (a file with no row is already invisible); the risk starts when opt-in-by-default ships, so list + assertion land together |
| S4 | 2 | S | Box masks derived from the five-scenario resolver; `ro` enforced on the box | plan | S3, S6 | Api | TODO — **blocked on a decision**: 5 files carry a bespoke write verb, so making one `rw` grants a SECOND write path unless WS-U retires the verb in the same change |
| S5 | 2 | S | Mirror is a BACKUP, never a seed; delete the per-row seed/mirror | plan | S3 | DayZ | TODO — supersedes the 2026-08-01 per-row wiring (29 rows), correct for the old model, boilerplate under this one |
| S7 | 3 | S | UI reads the mode; DELETE `web`/`writable`/`seed`/`mirror` | plan | S4, S5 | ConfigViewer | TODO — a migration ends at deletion |
| S8 | 2 | S | Prove the `generated` set is complete (builders declare outputs) | plan | - | none | TODO — unverifiable today: all 5 builders write via a `$outPath` variable, and `mpmissions/*/custom/` (6 files rewritten every boot) is in no declaration at all |
| -- | 4 | - | Verify / Definition of Done | plan | all | - | TODO |
| WS-D | - | D | Api actions split at ~50 (deferred, not scheduled) | plan | - | Api | TODO — ~42 actions today |

## Update protocol
1. Move a task's status here first (this file is canonical).
2. On `DONE`, add a one-line note under the log below with date + what shipped + deploy done.
3. Reflect the change in the Claude Artifact dashboard.
4. Do NOT mark A3 `DONE` until every A2 file is migrated - it is the irreversible delete.

## Log
- 2026-07-24 - project created (plan, contract, tracker) from the 2026-07-24 audit. Nothing started.
- 2026-07-31 - **tracker reconciled after 7 days of drift.** This file was never updated; work ran
  against `CONFIG-ARCHITECTURE.md` alone, which covers Workstream A only. Result: A0/A1 delivered,
  A2 delivered then partly regressed, A4 half-built - and B/C untouched while both god-files GREW.
  `CONFIG-ARCHITECTURE.md` moved into this folder (it is A's design doc, not a rival plan); the 3
  `../CONFIG-ARCHITECTURE.md` links plus `README.md` and `STAGING-PLAN.md` pointers rewritten.
- 2026-07-31 - **OWNER DECISION: A3 PROCEEDS. Phase 3's "keep the patch niche" is OVERRULED.**
  Owner's words: "You KNOW where we want to end up. No Overrides. Just whole file ownership and
  modifying with a better UI/Syntax manager." So the end state is the one this board and
  `CONFIG-ARCHITECTURE.md` always described: the delta engine is DELETED, every config surface
  becomes an owned whole file, and editing happens in the CM6 editor against a frozen default.
  This settles the contradiction - `CONFIG-ARCHITECTURE.md`'s Phase 3 entry is now historical
  record, not standing direction. What must go, per that doc's own target section:
    - `Apply-ConfigOverrides.ps1` (the applier) - remove from prestart, then delete
    - `config-overrides.json` + the selector grammar (dotted-path / XPath)
    - `override-diff.ts` / `override-diff-xml.ts` + `configs/preview-override`
    - `override-write` / `override-versions` / `override-rollback` verbs in dayz-ctl
  Remaining work is A2's tail: 22 files / 548 leaves still on the engine must become owned
  surfaces before A3's delete can run (A3 dep is "A2=100%"). BanditLoadout (359 leaves) first -
  it is 65% of what is left and the gate is already red on it.
  B1 stays blocking for UI work only; it does not block A2/A3.
- 2026-07-31 (second pass) - **OWNER REFRAME encoded into the docs.** The four needs (README.md)
  are now the spec; the "two walls" stay as faces of need 1. Added: WS-U (one write path - corrects
  the 07-24 "Api is sound / out of scope" call), WS-G (one common→per-map propagation engine),
  WS-T (one test runner, wired fail-closed - 10 test files / 0 runners was the measured hole),
  WS-P (design rules live in CLAUDE.md + gate assertions only). Task rows T1-T3, U1-U2, G1-G2,
  P1-P2 added above; NOTHING removed. P1 done in the same pass (CLAUDE.md Design contract +
  changelog rationale). CONFIG-ARCHITECTURE.md synced to the A3-proceeds overrule and now carries
  the OPEN db/types.xml dual-classification decision (both classifications live; gate blind to it
  by design of the niche cap). UI-ABSTRACTION-CONTRACT absorbed the de-facto json-editor-ui
  adoption (3 consumers) - sign B0 around what exists. Stale facts corrected in this file:
  gate 27/0 (was noted 26/1), editor.js 1314 (was noted 1297). All of it UNCOMMITTED, like the
  rest of the tree - the commit decision is the owner's.
- 2026-07-31 (third pass) - **owner gave the go; tree COMMITTED + T1 SHIPPED.** Docs reframe
  committed as 396023d (CLAUDE.md un-ignored - the design contract must be versioned), the
  accumulated 2026-07-30/31 feature work as 360e059 (all 10 suites run green first), T1 as
  ae27bac. The runner is live in all three deploy scripts, fail-closed, proven non-vacuous.
  **E4 added** (owner request, verbatim in PLAN.md): save confirmation must NAME the edited
  files; root cause is 4 parallel dirty-state mechanisms, fix is ONE dirty registry + one
  dialog. Design proof owed to the owner before the UI is built.
- 2026-07-31 (third pass, cont.) - **U1 SHIPPED**: `tests/mechanism-counts.test.ps1` pins 6
  write verbs / the 7-module apiPost-caller set / apiPost single-definition, enforced by the
  T1 runner on every deploy. The ratchet only goes down: U2 deletes a verb, the same change
  lowers the pin. Measurement corrected the ledger's "7 write verbs" - settings-write's
  `patrols` key is a KEY, not a verb.
- 2026-07-31 (fourth pass) - **E4 BUILT** (design approved first): `dirty-files.js` + all 4 save
  paths confirm by name, pill/tab-switch warning name files, 3 pill copies collapsed to one
  helper. TDD 8/8 red-first, plus a 5/5 wiring guard (written after, non-vacuity proven).
  **A3 decision landed** - owner ruled owned-file-wins and required the 20 lifetime values to
  move INTO the owned file, so `Convert-ToOwned.ps1` was built TDD 22/22 as the generic
  cutover: verify-then-freeze, refuse on any unapplied row, live file provably untouched.
  Box step deliberately NOT run (prod + possible restart = owner's call). Corrected the stale
  "NOT a whole-file ownership case" header in vehicle-lifetime-overrides.test.ps1.
- 2026-08-01 - **WS-S OPENED (owner ruling): opt-in by default.** *"Can't we just track which files are
  explicitly locked and show the remaining XML or JSON files? I don't want this to be complicated."* Three
  requirements, verbatim: (1) opt in by default; (2) rw / ro / hidden flags for files AND folders, subfolders
  and files inheriting; (3) reconfigure to be equivalent to today's access map, with rw as the default.
  Model written into CONFIG-ARCHITECTURE.md § Surface access model; tasks S1-S7 in PLAN.md.
  **Mirroring becomes DERIVED from access** (`rw` → mirrored; `ro`/`hidden` → not), which is what collapses
  "what is tracked" and "what is exposed" into ONE list - the actual simplification.
  Measured on prod to size it: 459 non-default json/xml under the server dir; 25 files of vendor map geometry
  hold **52.8 MB**, the other 434 hold **8.0 MB**. So one `ro` glob removes 98% of the weight.
  **The catch, and why S6 blocks S4:** that 434 includes `VPPAdminTools/ConfigurablePlugins/SteamAPI.json`
  with a `STEAM_API_KEY` field (**empty today - nothing is leaking**), plus BanList / CodeLock perms /
  player profiles. Opt-in-by-default turns the deny list into a security boundary, so it gets a gate
  assertion, not a memo. Also noted: the 2026-08-01 per-row `seed`/`mirror` wiring (29 rows) was the right
  fix for the OLD model and becomes boilerplate under this one - S5 deletes it. The `ConfigParse.ps1`
  BOM fix from the same day survives either way and matters MORE here (far more files flow through it).
- 2026-08-01 (sixth pass) - **TRACKER RECONCILED. It had gone stale again - the same failure this
  file recorded on 2026-07-31.** I appended log entries all day but never revisited the BOARD, so
  rows still said "BUILT, not deployed" for work that shipped hours earlier. Owner: *"why do all
  the performative stuff if you aren't keeping up with it?"* Fair. Status below is MEASURED.
  **Workstream A is COMPLETE.** A3 shipped: `override-engine-deleted.test.ps1` 32/0 - applier,
  manifest, prestart call, 4 dayz-ctl verbs, 6 API actions, override-diff*.ts, the browser editor
  and 5 retired tests all provably absent, on both boxes.
  **Every E-row is LIVE (E1-E11).** E6 was the interesting one: the blocker was never the UI. The
  box refused to serve a `.defaults` companion for any file row (`grep -qxF` exact match, served
  **0 of 33**), so side-by-side was impossible no matter what the front end did. Fixed in
  `_own_check`; measured after deploy: 25 served, 8 refused, all 8 correct. It also closed the
  inverse - 21 baselines under the Expansion dirs had been WRITABLE through the API.
  E8/E9/E11 needed no rewording: the vocabulary left with the engine. `'Use Fields'`/`ovrView` are
  now 0 occurrences; the `overrid*` that remain are 42 comments plus types-editor.js, where the
  word is CORRECT - the CE tuning file really does override the base types at load.
  **B4 corrected, not celebrated:** editor.js 1314 -> 604 lines and innerHTML 23 -> 10, but that is
  A3 deleting code, NOT the split B4 asks for. map.js is unchanged at 2533. B1 is still unbuilt.
  **T4 is UNPINNED** - the owner's condition (finish the overrides migration) is now met.
- 2026-08-01 (third pass) - **S2 LIVE + S6 ABSORBED + a symptom-vs-cause correction.**
  Api deployed 23:17 UTC, ConfigViewer pushed. Verified on the box, not assumed: `.defaults`
  served beside file rows went 0/33 -> 25 served with 8 refused, and all 8 refusals are correct
  (5 disabled-mod configs + 3 non-json/xml). `own-write` on a .defaults now returns "the frozen
  default is read-only", closing the 21 writable baselines. Owner restarted 23:27:58 and the 19
  Sakhal vehicle lifetimes are LIVE at 3888000, 19/19, with CE logging on.
  **S6 absorbed into S3** (owner): it was scoped as a dynamic content scanner; the secret-bearing
  paths are 4 known static folders. What survives is one assertion that they resolve `hidden`.
  Also established there is NO exposure today - a file with no registry row is already invisible -
  so the deny list and its assertion belong in the same task, not as a gate before it.
  **Symptom vs cause, caught by verifying after the restart:** I archived 5 out-of-scope
  `.defaults` and prestart RE-CREATED all 5 within minutes, because `Capture-OwnedDefaults` still
  runs there and captures for every owned row missing one - from the CURRENT content, i.e. after
  any edit. Deleting the files treated the symptom. The fix is removing that call: capture-on-write
  (S2, now live) covers the legitimate case and is the only path that captures BEFORE the edit.
  Consistent with the owner's rule - the 5 are files we author, and files we author need no state 0.
- 2026-08-01 (second pass) - **WS-S MODEL CORRECTED, and the first version of it was wrong.**
  I proposed declaring rw/ro/hidden per path across three then four axes. The owner pushed back:
  ownership is not a preference, it is **whoever writes the file last** - which the pipeline
  already encodes in $items, the registry seeds and the builder outputs. Five scenarios replace
  the axes (CONFIG-ARCHITECTURE.md); the only thing genuinely declared is the deny list.
  Target restated in the owner's words: *"The server box owns all files now... a 'drop in place'
  server config manager that doesn't need a deployment to seed files."* So scenario 1 (deploy
  stamps the file) is a DEFECT TO REMOVE, not a category to keep - 5 custom-ce config files
  still sit in $items.
  **Defaults rule narrowed by the owner:** generated files never need one; a server-made file
  needs its original kept WHEN A CHANGE IS MADE, for rollback to state 0. No origin
  classification is needed to implement that - own-write is replace-only, so every target
  pre-existed: capture if missing, before the replace, never re-capture.
  **S2 BUILT (1616f48).** Three defects, one cause - nothing captured a baseline at the moment
  of change. (a) no write path captured anything, and Capture-OwnedDefaults runs at PRESTART,
  i.e. AFTER the edit, which froze the edit as the baseline (proven: tuning file and its
  .defaults byte-identical, same mtime, so they diff to nothing). (b) `_defaults_path` had been
  DELETED from the template by the A3 override sweep, so the next Api deploy would have removed
  the only code that can locate a baseline. (c) .defaults was backwards in BOTH directions -
  served 0 of 33 beside file rows (why side-by-side was impossible) while 21 under the Expansion
  dirs were WRITABLE. own-verbs 21 -> 27, 8 red first, 2 non-vacuity proven.
  **S8 added:** the `generated` set cannot currently be proven complete - all 5 builders write
  through a `$outPath` variable, and `mpmissions/*/custom/` (6 files rewritten every boot) is in
  no declaration at all. Harmless today; under opt-in-by-default an edit there is silently wiped.
  **Not deployed, not cleaned:** the Api deploy and the removal of 5 out-of-scope `.defaults`
  from prod both need the owner to name them.
- 2026-07-31 (fifth pass) - **T4 PINNED** by the owner (testing expansion deferred until the
  overrides migration is done; recorded in PLAN.md T4, the row above, and the root Open Work
  ledger). **NO-DATA-LOSS finding on the A3 delete**: freezing protects the live box but NOT a
  rebuilt one - the seed becomes the value once the engine is gone. 10 of server-settings.json's
  12 leaves were no-ops; 2 were not (cycle multipliers 5→8, 4→4.5), so a rebuild would have
  silently reverted the day/night cycle. Seed corrected; new registry-driven gate
  `tests/override-seed-parity.test.ps1` (TDD 16/16, red first on exactly those 2) makes it a
  standing rule. All 12 leaves are now provable no-ops. Suite 15/15, Test-Configs 27/0.
