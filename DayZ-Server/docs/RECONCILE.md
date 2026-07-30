# Update-day reconcile runbook (CONFIG-ARCHITECTURE.md Phase 4)

What to run, in order, after a game or mod update - so owned files keep the admin's edits
AND inherit the vendor's changes, with every merge human-reviewed. Treat this like SETUP.md:
it is the procedure, not advice.

The three tools (all exist, all report-only by default):

| Tool | Role |
|---|---|
| `Generate-ConfigDefaults.ps1 -Run` | captures the POST-update pristine baselines into `config-defaults-candidate/` |
| `Reconcile-Defaults.ps1` | 3-way merge per file: `config-defaults/<rel>` (old) vs `config-defaults-candidate/<rel>` (new) vs the live file (`git merge-file`; conflicts never auto-write) |
| the owned-file editor (ConfigViewer) | the ONLY way merged content reaches the box (`configs/set-own` - snapshot + concurrency) |

## Procedure

1. **Freeze config edits** (tell other admins; concurrent UI saves will 409 anyway, but don't race).
2. `Pull-Configs.ps1 -Execute` - commit the PRE-update box state (mirrors + auto-commit = the rollback point).
3. Run the update (update.sh / workshop as usual). The box's LIVE owned files are NOT touched by
   the update for our-authored files (Loadouts); game-owned mission files may be rewritten -
   that is exactly what the patch NICHE covers (overrides re-apply at prestart; nothing to do).
4. `Generate-ConfigDefaults.ps1 -Run` - capture the new pristine baselines into `config-defaults-candidate/`.
5. Per owned surface where the candidate differs from `config-defaults/`:
   `./Reconcile-Defaults.ps1 -OldDefault config-defaults/<rel> -NewDefault config-defaults-candidate/<rel> -Live <pulled live copy>`
   - **CLEAN** → re-run with `-Fix` (writes the merged copy locally + adopts the baseline), then
     paste/save the merged file through the ConfigViewer owned-file editor. Never onto the box by hand.
   - **CONFLICT** (exit 2) → resolve the marker-annotated copy in `reconcile-conflicts/`, save the
     resolution through the editor, then adopt the baseline (copy candidate → config-defaults).
6. `Test-Configs.ps1` - the gate must pass before anything else ships.
7. `Pull-Configs.ps1 -Execute` - commit the post-reconcile state.

## Known stale claim in Generate-ConfigDefaults

Its promote-mode comment says adopting candidates is behavior-neutral because "every
baseline<->default delta is already covered by an override". TRUE for the patch niche; NO LONGER
true for owned files since the 2026-07-29 Phase 2 sweep (their deltas left the override doc).
For owned files the 3-way merge above IS the adoption path - do not blind-promote their baselines.
