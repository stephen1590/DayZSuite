# Mods

`deploy/mods.conf` is the single source of truth for enabling, disabling, and ordering
mods — this page mirrors it for reference; if the two ever disagree, `mods.conf` wins.
**Line order in `mods.conf` is load order**, which becomes the systemd unit's `-mod=`
line built verbatim from the enabled lines in sequence.

Toggling a mod: comment/uncomment its line in `deploy/mods.conf`, then
`./Deploy-DayZServer.ps1 -Fix` — drift detection auto-downloads any newly-enabled mod
that isn't on disk yet.

Clients must subscribe to and enable every **enabled** mod below on the Steam Workshop,
in the same order, to join (`verifySignatures = 2` enforces matching signatures).

## Core & gameplay mods

| Folder | Workshop ID | Mod | Notes |
|---|---|---|---|
| `@cf` | [1559212036](https://steamcommunity.com/sharedfiles/filedetails/?id=1559212036) | Community Framework | Base dependency for most mods below. |
| `@vppadmintools` | [1828439124](https://steamcommunity.com/sharedfiles/filedetails/?id=1828439124) | VPPAdminTools | Requires CF. Admin teleport/spawn tooling; feeds `Sync-VPPCoordinates.ps1`. |
| `@aibandits` | [3628006769](https://steamcommunity.com/sharedfiles/filedetails/?id=3628006769) | AI Bandits | Requires CF. |
| `@aibunleashed` | [3682348844](https://steamcommunity.com/sharedfiles/filedetails/?id=3682348844) | AIB_Unleashed | Squad tactics / stealth / breaching add-on, loads after `@aibandits`. Server-side only. |
| `@aibvoices` | [3679500367](https://steamcommunity.com/sharedfiles/filedetails/?id=3679500367) | AI Bandit Voices | Marked `optional` in `mods.conf` — no longer listed on the Workshop, so steamcmd may never fetch it. Client-side too; with `verifySignatures = 2` a missing key fails signature checks for anyone running it. |
| `@dayzdog` | [2471347750](https://steamcommunity.com/sharedfiles/filedetails/?id=2471347750) | DayZ-Dog (Hunterz) | CF only. Feeds AI Bandits groups' `dog` field. |
| `@codelock` | [1646187754](https://steamcommunity.com/sharedfiles/filedetails/?id=1646187754) | Code Lock (Room Service) | Combination-lock replacement for base security. |

## DayZ-Expansion module family

Expansion is a suite of separate Workshop items that load together, not one mod.
`mods.conf` groups the interdependent ones with inline `# Dependencies:` comments.

| Folder | Workshop ID | Mod | Notes |
|---|---|---|---|
| `@dabsframework` | [2545327648](https://steamcommunity.com/sharedfiles/filedetails/?id=2545327648) | Dabs Framework | Framework required by the whole Expansion family; must load first. |
| `@expansioncore` | [2291785308](https://steamcommunity.com/sharedfiles/filedetails/?id=2291785308) | DayZ-Expansion-Core | Shared core services for the Expansion family. |
| `@expansion` | [2116151222](https://steamcommunity.com/sharedfiles/filedetails/?id=2116151222) | DayZ-Expansion | Base package — map POIs, kill feed, player list, grave crosses, street-light generators. Needs Dabs Framework loaded first. |
| `@expansionlicensed` | [2116157322](https://steamcommunity.com/sharedfiles/filedetails/?id=2116157322) | DayZ-Expansion-Licensed | Bohemia-licensed content pack (animations, economy, vehicles) — required by BaseBuilding, Vehicles, and Missions below. |
| `@expansionbasebuilding` | [2792982513](https://steamcommunity.com/sharedfiles/filedetails/?id=2792982513) | DayZ-Expansion-BaseBuilding | Territory system + modular base building. Depends on Licensed + Book. |
| `@expansionbook` | [2572324799](https://steamcommunity.com/sharedfiles/filedetails/?id=2572324799) | DayZ-Expansion-Book | In-game stat/recipe/server-info book; integrates with Groups & Territory. Depends on Licensed. |
| `@expansionvehicles` | [2291785437](https://steamcommunity.com/sharedfiles/filedetails/?id=2291785437) | DayZ-Expansion-Vehicles | Helicopters, boats, cars, amphibious vehicles, keys, towing. Depends on Licensed. |
| `@expansiongroups` | [2792983364](https://steamcommunity.com/sharedfiles/filedetails/?id=2792983364) | DayZ-Expansion-Groups | Team/party system, shared HUD, pinging, map markers. Depends on Book. |
| `@expansionmissions` | [2792984177](https://steamcommunity.com/sharedfiles/filedetails/?id=2792984177) | DayZ-Expansion-Missions | Dynamic mission framework — contamination zones, mission & player-triggered airdrops. Depends on Licensed. |
| `@expansionani` | [2792982069](https://steamcommunity.com/sharedfiles/filedetails/?id=2792982069) | DayZ-Expansion-Animations (core) | Shared animation set used by the Expansion family. |
| `@expansionmarket` | [2572328470](https://steamcommunity.com/sharedfiles/filedetails/?id=2572328470) | DayZ-Expansion-Market | Trading system — see [CONFIGURATION.md](CONFIGURATION.md) for how trader config is managed. |
| `@expansionspawnselection` | [2804241648](https://steamcommunity.com/sharedfiles/filedetails/?id=2804241648) | DayZ-Expansion-SpawnSelection | Map-based spawn point selection + custom starting loadouts. |
| `@expansionchat` | [2792982897](https://steamcommunity.com/sharedfiles/filedetails/?id=2792982897) | DayZ-Expansion-Chat | Global / proximity / vehicle / admin / party chat channels. |
| `@expansionmapassets` | [2792983824](https://steamcommunity.com/sharedfiles/filedetails/?id=2792983824) | DayZ-Expansion-Map-Assets | Decorative static-object + builder-item pack. |
| `@expansionanimations` | [2793893086](https://steamcommunity.com/sharedfiles/filedetails/?id=2793893086) | DayZ-Expansion-Animations | Vehicle animations (guitar, boat, tractor, heli, bus). |
| `@expansionquests` | [2828486817](https://steamcommunity.com/sharedfiles/filedetails/?id=2828486817) | DayZ-Expansion-Quests | MMO-style quest framework — collection/delivery/combat/exploration objectives. |
| `@expansionpersonalstorage` | [2946236937](https://steamcommunity.com/sharedfiles/filedetails/?id=2946236937) | DayZ-Expansion-PersonalStorage | Private virtual inventory / storage cases. |
| `@expansionweapons` | [2792985069](https://steamcommunity.com/sharedfiles/filedetails/?id=2792985069) | DayZ-Expansion-Weapons | Extra firearms, optics, and grenades. |
| `@expansionnavigation` | [2792984722](https://steamcommunity.com/sharedfiles/filedetails/?id=2792984722) | DayZ-Expansion-Navigation | Satellite map, 2D/3D markers, compass + GPS HUD, player position. |

**Not used:** `@expansionbundle` (the all-in-one package) is intentionally excluded; this
config runs the modular pieces above instead.

## Disabled (kept in `mods.conf` for reference)

| Folder | Workshop ID | Mod | Why disabled |
|---|---|---|---|
| `@knockknock` | [3638393043](https://steamcommunity.com/sharedfiles/filedetails/?id=3638393043) | Knock Knock AI Bandits | Bandits ambush from behind doors. |
| `@basebuildingplus` | [1710977250](https://steamcommunity.com/sharedfiles/filedetails/?id=1710977250) | BaseBuildingPlus | Client version-mismatch kicks against the current mod set. |
| `@bicycle` | [2971190303](https://steamcommunity.com/sharedfiles/filedetails/?id=2971190303) | DayZ-Bicycle (Hunterz) | Bicycle animations conflicted with `@expansionanimations`; kept Expansion's instead. |
| `@survivoranimations` | [2918418331](https://steamcommunity.com/sharedfiles/filedetails/?id=2918418331) | Survivor Animations (Hunterz) | Dependency of the bicycle mod (must precede it); disabled with it. |

## Mechanics worth knowing

- Each enabled mod is copied out of `steamapps/workshop/content/221100/<id>/` into its
  `@folder` in the server root by `update.sh`, with **every filename lowercased** — the
  Linux server is case-sensitive and Workshop mods ship mixed-case, so joins fail on
  missing files without this step. The copy+lowercase re-runs on every `update.sh`
  invocation, so mod updates stay fixed automatically. `*.bikey` files are copied into
  `keys/`.
- **Keep every `@folder` name in `mods.conf` lowercase.** `update.sh` always lowercases
  the on-disk folder, so a mixed-case entry makes the rendered `-mod=` line reference a
  directory that doesn't exist — a hard crash at boot.
- `@aibandits` and `@dayzdog` ship custom NPC/entity classes, so clients need them
  installed to render bandits/dogs at all, not just the server.
