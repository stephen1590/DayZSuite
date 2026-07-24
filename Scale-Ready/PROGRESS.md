# Scale-Ready - Progress

Canonical status tracker (git-tracked). The [Claude Artifact dashboard](https://claude.ai/code/artifact/c4278af0-a112-4e25-a305-979b22b0452f) mirrors this file - **update here first**, then reflect it in the artifact.

**Status legend:** `TODO` · `WIP` (in progress) · `BLOCKED` · `REVIEW` · `DONE`
**Owners:** `plan` (this effort) · `ui-chat` (parallel editor-UI abstraction) · `joint`

**Rollup:** 0 / 15 done · Phase 0 not started · last updated 2026-07-24.

---

## Workstreams
- **A** - retire the override delta engine (two-copy). Removes Wall 1 + the HIGH drift risk.
- **B** - UI render abstraction + god-file split. Removes Wall 2. Aligns with the parallel editor-UI effort.
- **C** - foundations (formatting, naming, TYPES_BASE, conformance scaffold).
- **D** - deferred (Api split at ~50 actions). Not scheduled.

## Task board

| ID | Phase | Workstream | Task | Owner | Deps | Deploy | Status |
|----|-------|-----------|------|-------|------|--------|--------|
| C1 | 0 | C | Prettier + config (format-only commit) | plan | - | none | TODO |
| C2 | 0 | C | Naming / code-style rule in CLAUDE.md | plan | - | none | TODO |
| C3 | 0 | C | TYPES_BASE → registry field | plan | - | ConfigViewer (+Api?) | TODO |
| C4 | 0 | C | Conformance-test scaffold | plan | - | none | TODO |
| A0 | 1 | A | Classify 21 surfaces A/B; add `category` | plan | C4 | none | TODO |
| B0 | 1 | B | Agree the render primitive (sign the contract) | joint | - | none | TODO |
| B1 | 1 | B | Build primitive + one reference view | ui-chat | B0 | ConfigViewer | TODO |
| A1 | 1 | A/B | Pilot: whole-file + diff editor for ONE owned file | joint | A0, B1 | ConfigViewer (+Api?) | TODO |
| A2 | 2 | A | Migrate owned files one at a time (loadouts/airdrop first) | plan | A1 | per file | TODO |
| B3 | 2 | B | Roll primitive across remaining views | joint | B1, A1 | ConfigViewer | TODO |
| B4 | 2 | B | Split god-files (editor.js, map.js) | plan | B3 | ConfigViewer | TODO |
| A3 | 3 | A | Delete the delta engine (point of no return) | plan | A2=100% | Api+ConfigViewer+DayZ | TODO |
| A4 | 3 | A | Reconcile-on-update + conformance gate fail-closed | plan | A3, C4 | DayZ | TODO |
| B5 | 3 | B | Scale smoke test (new tab ~80 lines) | plan | B3, B4 | none | TODO |
| -- | 4 | - | Verify / Definition of Done | plan | all | - | TODO |
| WS-D | - | D | Api actions split at ~50 (deferred, not scheduled) | plan | - | Api | TODO |

## Update protocol
1. Move a task's status here first (this file is canonical).
2. On `DONE`, add a one-line note under the log below with date + what shipped + deploy done.
3. Reflect the change in the Claude Artifact dashboard.
4. Do NOT mark A3 `DONE` until every A2 file is migrated - it is the irreversible delete.

## Log
- 2026-07-24 - project created (plan, contract, tracker) from the 2026-07-24 audit. Nothing started.
