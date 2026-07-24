# UI Render Abstraction - Alignment Contract

**Purpose:** keep this project and the parallel editor-UI effort pointed at the same target. As of 2026-07-24 the parallel effort has a design proof - **`json-ui`** - and this contract is now written to align to it, not to a hypothetical.

**The parallel work (`json-ui`):** a generic, shape-dispatched JSON editor shipped as a **self-contained, dependency-free, framework-agnostic package** - native ES modules (no build step), a CSS-token contract, a README, a version. The host calls `mountEditor(container, value, { onChange, hints })`, the package renders the editable structure, **the host owns persistence.** It replaces the bespoke editors (the config editor's raw textarea; the map editor's `meField` / `lbcSectionHtml` / `waypointsSectionHtml`). Source of truth for its design is that chat's proof, not this file.

---

## Honest scope: `json-ui` solves the worst of Wall 2, not all of it

Wall 2 (the audit) has two parts. Naming them separately keeps us from over-claiming:

- **Wall 2a - structured-data editing.** The recursive field / tree / table rendering inside `editor.js` and `map.js`. This is the densest, most-duplicated code and the source of the "slop" feeling. **`json-ui` solves this.** Adopt it.
- **Wall 2b - general view chrome.** The build-HTML-string → `innerHTML` → `querySelectorAll` → `addEventListener` dance for nav lists, tabs, filters, buttons across logs / maintenance / map-chrome / editor-chrome. **`json-ui` does not touch this.** It is a separate, smaller decision - a light render helper, or fold it into the god-file split (B4), or defer it. Decide at B0; do not assume `json-ui` covers it.

## Why `json-ui` is the right call (and a better fit than my first draft)

My earlier draft recommended a generic render primitive (lit-html) for all views. That was aimed at Wall 2b. The parallel effort built the more valuable thing first - the structured-editor for Wall 2a - and it lines up with WS-A better than a render primitive would:

- **It IS the two-copy editor.** `json-ui` edits the whole document and hands it back via `onChange`; the host owns the save. That is exactly the two-copy model - whole-file save, no delta. WS-A's pilot (A1) should be built **on `json-ui`**, not on a bespoke diff editor.
- **It is drift-tolerant, the same ethos as two-copy.** It renders the actual JSON, edits in place by path, and lets unrecognized nodes ride through a save untouched - so an Expansion update can't silently drop a field. That is the reconcile-on-update safety (A4) getting help from the editor layer for free.
- **It is already view-agnostic within data-editing.** It is designed to serve both the config editor and the map field sections. No DayZ knowledge lives in the package; ConfigViewer is just a consumer.

## The binding rules

1. **No DayZ content in the package.** Any DayZ-specific nicety (field labels, force-a-table, field order) is an optional, generic `hints` descriptor passed by ConfigViewer - never code inside `json-ui`.
2. **Host owns persistence.** The package never saves. ConfigViewer wires `onChange` to the whole-file save path (the two-copy write), so the editor and the config model agree by construction.
3. **Fails soft, surfaces surprises.** A vanished/renamed node falls back to the generic renderer and can raise a "new/unexpected field" note - never a throw, never a silent mis-render.
4. **Themed only through CSS tokens.** The package inherits ConfigViewer's look via tokens (including the shared `--tree-guide` hierarchy token). No hardcoded colours.
5. **Wall 2b is not `json-ui`'s job.** Keep the view-chrome decision explicit and separate so neither effort assumes the other did it.

## Build order (settled in the parallel chat, adopted here)

1. **`json-ui` standalone first** - prove the package in isolation (its own `packages/json-ui/`, graduating to its own repo/submodule later).
2. **Swap the map editor** (LBC / waypoints) to consume it - delete the bespoke `lbcSectionHtml` / `waypointsSectionHtml` / `meField`.
3. **Make config docs editable in the config view via `json-ui`** - this is where it meets WS-A's two-copy pilot (A1).

## Convergence with WS-A

The editor is where WS-A (two-copy) and WS-B (`json-ui`) meet. Concretely: A1 = "a Category-A config file, edited whole via `json-ui`, saved whole by the host." Ship that once and both walls start coming down at the same seam. This replaces the earlier "CodeMirror 6 diff editor" idea for structured JSON - `json-ui` is the better tool for structured data; keep CodeMirror only if a raw-text/free-form surface still needs it.

## Open decisions (reconcile at B0)

- **Wall 2b (view chrome):** light render helper, fold into B4, or defer → decision: _____
- **`json-ui` location:** `packages/json-ui/` now, own repo/submodule later → confirm timing → decision: _____
- **`hints` descriptor shape** (how ConfigViewer passes DayZ specifics) → decision: _____
- **CodeMirror 6:** still wanted for any raw-text surface, or dropped entirely → decision: _____
- **Branch / commit discipline** so the two efforts don't collide → decision: _____
