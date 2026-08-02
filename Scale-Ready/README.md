# Scale-Ready

Codebase remediation to make the DayZ **ConfigViewer** and config system scale. Reframed 2026-07-31 (owner): the 2026-07-24 audit's "two walls" are two faces of ONE disease - **mechanisms get built as one-offs, and no migration ever finishes by deleting what it replaced**. The scope is the whole config system: UI, write path, generators, tests, and the enforcement of this design itself.

## The owner's four needs (the actual spec - everything below serves these)

1. **One mechanism, not N.** Shared UI elements, shared editing practices, shared design principles - abstract and reshare. A migration is DONE when the replaced one-off is DELETED, not when the new path works. (Measured 2026-07-31: 7 parallel write verbs, ~7 edit surfaces, 87 innerHTML sites.)
2. **The two-copy model.** A frozen `*.defaults.*` copy lives alongside every live config. Two categories:
   2.1 **Direct replacements** - the live file is edited whole; the default is the diff baseline.
   2.2 **Generator inputs** - inputs (including COMMON files shared across the 3 maps) propagate into the generated live files. One declarative propagation mechanism, not N hand-rolled builders.
3. **Reproducibility + testing.** Tests are written FIRST, run as ONE suite, and re-run on every change/deploy - so a change provably does not break legacy behavior. A test nothing re-runs does not count. (Measured 2026-07-31: 10 test files, zero runners invoke them.)
4. **Design enforcement, not silent readmes.** A design principle lives where an agent is guaranteed to meet it: the CLAUDE.md chain (auto-loaded) or a fail-closed gate assertion. Every feature request is placed against the whole design - which surface category, which editor, which write path - BEFORE building.

## Start here

- **[PROGRESS.md](PROGRESS.md)** - THE tracker. One file, git-tracked. A rendered dashboard and a `tracker.html` both used to shadow it and both drifted; they are deleted (2026-08-01).
- **[PLAN.md](PLAN.md)** - the full project plan: goals, workstreams, phased tasks, acceptance criteria, sequencing, risks.
- **[UI-ABSTRACTION-CONTRACT.md](UI-ABSTRACTION-CONTRACT.md)** - the alignment spec for the UI render abstraction. **Read this first if you are building the editor-UI abstraction in a parallel effort.** It is the target both efforts must hit so we get ONE render primitive, not a 14th one-off.
- **[PROGRESS.md](PROGRESS.md)** - the living status tracker. Update it as tasks move.

## The two walls (from the audit - kept; they are faces of need 1)

1. **The override delta engine is duplicated across tiers.** It is written twice in two languages - TypeScript in the Api, PowerShell on the box - kept in sync only by comments, and the two use *different XPath engines* (`xpath` npm vs .NET `SelectSingleNode`). A selector can silently apply an edit to the wrong node on the box. **HIGH risk.** → **Workstream A** retires it (two-copy model). *Status 2026-07-31: nearly done - override doc 14,881 → 12 leaves.*
2. **The UI render pattern has zero abstraction.** Build-HTML-string → `innerHTML` → `querySelectorAll` → `addEventListener` is copy-pasted 13+ times. Two god-files: `editor.js` (1199 lines, 6 jobs), `map.js` (2064 lines, 5 jobs). → **Workstream B** abstracts the pattern and splits the god-files. *Status 2026-07-31: regressed - 1314 and 2530 lines.*

**What the original framing missed** (the 2026-07-31 reframe adds workstreams for each):

- The **write path** has the same disease as the UI: 7 parallel save verbs. "The Api is sound and out of scope" was wrong scoping - the transport/auth framework is sound; the verb proliferation is not. → **WS-U**.
- The **generators** (Category B) were declared fine because they exist - but they are 5 hand-rolled one-offs with no shared common→per-map propagation mechanism. → **WS-G**.
- **Tests** accumulated as per-change artifacts with no runner, so nothing ever re-runs them. → **WS-T**.
- The **plan itself** was a silent readme nobody was forced to read - PROGRESS sat stale for 7 days while work ran elsewhere. → **WS-P**.

## Not slop

The audit was explicit: clean module layers, no circular deps, real shared utilities, comments that explain *why*. The problem is **missing abstraction + duplication, not mess.** This project fixes structure, not code quality.

## Sources of truth

- Config model + two-copy migration design: **[CONFIG-ARCHITECTURE.md](CONFIG-ARCHITECTURE.md)**. This project operationalizes its migration; it does not re-explain it.
- Config surface registry: `../DayZ-Server/config-registry.json`.

Created 2026-07-24. Plan basis: the 2026-07-24 three-reader audit (ConfigViewer JS, Api TS, cross-tier duplication). Current-code specifics here come from that audit, not a fresh code pass - confirm exact internals when each task starts.
