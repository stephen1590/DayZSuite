# Scale-Ready

Codebase remediation to make the DayZ **ConfigViewer** and config system scale past the two structural walls the 2026-07-24 architecture audit found. The Api backend is sound and out of scope except one small fix.

## Start here

- **[Live tracker board](https://claude.ai/code/artifact/c4278af0-a112-4e25-a305-979b22b0452f)** - the visual dashboard (private artifact; mirrors PROGRESS.md).
- **[PLAN.md](PLAN.md)** - the full project plan: goals, workstreams, phased tasks, acceptance criteria, sequencing, risks.
- **[UI-ABSTRACTION-CONTRACT.md](UI-ABSTRACTION-CONTRACT.md)** - the alignment spec for the UI render abstraction. **Read this first if you are building the editor-UI abstraction in a parallel effort.** It is the target both efforts must hit so we get ONE render primitive, not a 14th one-off.
- **[PROGRESS.md](PROGRESS.md)** - the living status tracker. Update it as tasks move.

## The two walls (from the audit)

1. **The override delta engine is duplicated across tiers.** It is written twice in two languages - TypeScript in the Api, PowerShell on the box - kept in sync only by comments, and the two use *different XPath engines* (`xpath` npm vs .NET `SelectSingleNode`). A selector can silently apply an edit to the wrong node on the box. **HIGH risk.** → **Workstream A** retires it (two-copy model).
2. **The UI render pattern has zero abstraction.** Build-HTML-string → `innerHTML` → `querySelectorAll` → `addEventListener` is copy-pasted 13+ times. Two god-files: `editor.js` (1199 lines, 6 jobs), `map.js` (2064 lines, 5 jobs). → **Workstream B** abstracts the pattern and splits the god-files.

## Not slop

The audit was explicit: clean module layers, no circular deps, real shared utilities, comments that explain *why*. The problem is **missing abstraction + duplication, not mess.** This project fixes structure, not code quality.

## Sources of truth

- Config model + two-copy migration design: **[../CONFIG-ARCHITECTURE.md](../CONFIG-ARCHITECTURE.md)**. This project operationalizes its migration; it does not re-explain it.
- Config surface registry: `../DayZ-Server/config-registry.json`.

Created 2026-07-24. Plan basis: the 2026-07-24 three-reader audit (ConfigViewer JS, Api TS, cross-tier duplication). Current-code specifics here come from that audit, not a fresh code pass - confirm exact internals when each task starts.
