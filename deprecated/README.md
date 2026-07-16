# deprecated/

Retired tooling, kept for history. Nothing here is shipped or run.

- Excluded from the deploy rsync (`--exclude=deprecated` in `Deploy-DayZServer.ps1`), so it never reaches the box.
- Not in the `$items` manifest, so no file here is copied into the server dir.
- Nothing in the live deploy references these paths.

## VPP-coordinate spawn source (retired 2026-07-15)

AI-bandit spawns used to be sourced from VPP admin bookmarks. The definitive source is now `deploy/profiles/AI_Bandits/spawn-points.json`, edited in the ConfigViewer Map tab and pulled box-authoritative by `Sync-SpawnPoints.ps1`.

| Item | Was | Notes |
|---|---|---|
| `Sync-VPPCoordinates.ps1` | One-shot importer: pulls VPP `TeleportLocation.json` off the box into `vpp-coordinates.json` | Read-only pull. Never touched live admin bookmarks. |
| `Migrate-SpawnPoints.ps1` | One-shot migrator: converts `vpp-coordinates.json` into `spawn-points.json` | Already run once (123 Sakhal points seeded). |
| `VPPCoordinates/` | The imported data + timestamped backups | Superseded by `spawn-points.json`. |

Paths inside these scripts still reference their old repo/box locations. They are archived as-is, not maintained. To re-seed from a fresh VPP capture you would restore them and fix the paths first.

Live VPP admin data on the box (`profiles/VPPAdminTools/ConfigurablePlugins/TeleportManager/TeleportLocation.json`) is admin-owned and was never part of this tooling.
