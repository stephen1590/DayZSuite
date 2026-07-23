---
title: DayZ - Commie Lobby
weight: 10
---

## DayZ - *Commie Lobby*

A modded **DayZ** dedicated server running on a dedicated box. DayZ-Expansion,
dynamic missions and airdrops, admin tooling, and a scheduled restart cycle keep
the map fresh without wiping your progress.

### Connect

|                 |                                         |
| --------------- | --------------------------------------- |
| **Server name** | [US-PNW] Commie Lobby (PVE)             |
| **Address**     | `51.81.167.216:2301`                    |
| **Query port**  | `27016`                                 |
| **Host**        | `cytonicmushroom.ddns.net`              |
| **Map**         | Sakhal                                  |
| **Build**       | Current stable - `forceSameBuild` is on |

> [!NOTE]
> **`forceSameBuild` is enabled.** Your DayZ client must be on the same stable
> build as the server. If DayZ just pushed an update, verify your game files before
> connecting.

### How to join

{{% steps %}}

1. **Add the server**

   In DayZ, open the server browser and add `51.81.167.216:2301` as a favorite,
   or search for **Commie Lobby**.

1. **Download the mods**

   On first join, DayZ prompts you to subscribe to the server's mods. Accept - the
   game downloads them from the Steam Workshop and restarts itself with them loaded.

1. **Join the server**

   Launch again with the mods enabled and join. You're in.

{{% /steps %}}

### Mods

These run server-side - DayZ pulls whatever your client needs automatically when
you connect.

| Mod                          | Role                                             | Workshop                                                                                   | Status   |
| ---------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------ | -------- |
| **Community Framework (CF)** | Required framework dependency for the other mods | [1559212036](https://steamcommunity.com/sharedfiles/filedetails/?id=1559212036)            | Enabled  |
| **VPPAdminTools**            | Server administration & moderation tools         | [1828439124](https://steamcommunity.com/sharedfiles/filedetails/?id=1828439124)            | Enabled  |
| **Code Lock**                | Combination locks for doors, gates, and stashes  | [1646187754](https://steamcommunity.com/sharedfiles/filedetails/?id=1646187754)            | Enabled  |
| **AI Bandits**               | Hostile roaming AI - patrols and ambushes        | [3628006769](https://steamcommunity.com/sharedfiles/filedetails/?id=3628006769)            | Disabled |
| **Knock Knock**              | AI Bandits add-on                                | [3638393043](https://steamcommunity.com/sharedfiles/filedetails/?id=3638393043)            | Disabled |
| **AIB Unleashed**            | AI Bandits add-on (expanded AI)                  | [3682348844](https://steamcommunity.com/sharedfiles/filedetails/?id=3682348844)            | Disabled |
| **AI Bandit Voices**         | AI Bandits add-on - voice lines for the bandits  | [3679500367](https://steamcommunity.com/sharedfiles/filedetails/?id=3679500367) (delisted) | Disabled |
| **DayZ-Dog**                 | Tameable companion dogs                          | [2471347750](https://steamcommunity.com/sharedfiles/filedetails/?id=2471347750)            | Disabled |

> [!NOTE]
> The **Disabled** mods above are switched off on the server right now, so your client
> is not asked to download them. They stay listed here because they have run before and
> may return.

#### DayZ-Expansion

A separate mod family - 20 pieces, each its own Workshop item, all required for **DayZ-Expansion**:

| Mod                 | Role                                                                                     | Workshop                                                                        | Status  |
| ------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ------- |
| **Dabs Framework**  | Required framework dependency for DayZ-Expansion                                         | [2545327648](https://steamcommunity.com/sharedfiles/filedetails/?id=2545327648) | Enabled |
| **Core**            | Shared core framework required by every Expansion module                                 | [2291785308](https://steamcommunity.com/sharedfiles/filedetails/?id=2291785308) | Enabled |
| **Expansion**       | Base package - new points of interest, kill feed, player list, quality-of-life additions | [2116151222](https://steamcommunity.com/sharedfiles/filedetails/?id=2116151222) | Enabled |
| **Licensed**        | Licensed content pack required by several modules below                                  | [2116157322](https://steamcommunity.com/sharedfiles/filedetails/?id=2116157322) | Enabled |
| **BaseBuilding**    | Territory system + expanded base building                                                | [2792982513](https://steamcommunity.com/sharedfiles/filedetails/?id=2792982513) | Enabled |
| **Book**            | In-game book - stats, recipes, server info                                               | [2572324799](https://steamcommunity.com/sharedfiles/filedetails/?id=2572324799) | Enabled |
| **Vehicles**        | Extra vehicles - helicopters, boats, cars, amphibious rides                              | [2291785437](https://steamcommunity.com/sharedfiles/filedetails/?id=2291785437) | Enabled |
| **Groups**          | Party/group system with a shared HUD and map pings                                       | [2792983364](https://steamcommunity.com/sharedfiles/filedetails/?id=2792983364) | Enabled |
| **Missions**        | Dynamic missions - contamination zones, airdrops                                         | [2792984177](https://steamcommunity.com/sharedfiles/filedetails/?id=2792984177) | Enabled |
| **AI**              | AI NPC framework - powers quest and mission AI                                           | [2792982069](https://steamcommunity.com/sharedfiles/filedetails/?id=2792982069) | Enabled |
| **Market**          | Trader market system - buy and sell at the safezone traders                              | [2572328470](https://steamcommunity.com/sharedfiles/filedetails/?id=2572328470) | Enabled |
| **SpawnSelection**  | Pick your spawn point on the map after death                                             | [2804241648](https://steamcommunity.com/sharedfiles/filedetails/?id=2804241648) | Enabled |
| **Chat**            | Extra chat channels (proximity, vehicle, party, admin)                                   | [2792982897](https://steamcommunity.com/sharedfiles/filedetails/?id=2792982897) | Enabled |
| **Map-Assets**      | Decorative map objects                                                                   | [2792983824](https://steamcommunity.com/sharedfiles/filedetails/?id=2792983824) | Enabled |
| **Animations**      | Extra vehicle animations                                                                 | [2793893086](https://steamcommunity.com/sharedfiles/filedetails/?id=2793893086) | Enabled |
| **Quests**          | Quest system - collection, delivery, combat, and exploration objectives                  | [2828486817](https://steamcommunity.com/sharedfiles/filedetails/?id=2828486817) | Enabled |
| **PersonalStorage** | Private virtual storage stash                                                            | [2946236937](https://steamcommunity.com/sharedfiles/filedetails/?id=2946236937) | Enabled |
| **Weapons**         | Extra firearms, optics, and grenades                                                     | [2792985069](https://steamcommunity.com/sharedfiles/filedetails/?id=2792985069) | Enabled |
| **Navigation**      | Satellite map, GPS, compass, and marker HUD                                              | [2792984722](https://steamcommunity.com/sharedfiles/filedetails/?id=2792984722) | Enabled |

> [!NOTE]
> **DayZ-Expansion-Bundle** (the all-in-one package) is intentionally not used. This
> server runs the 20 modular pieces above instead - it won't show up in your subscribe
> prompt.

### Gameplay notes

- **The world persists** - bases, vehicles, and stashed loot survive restarts
  (central economy). Build like you mean to keep it.
- **Dynamic missions and airdrops** - DayZ-Expansion seeds timed events across the
  map: contamination zones, airdrops, and quest objectives. Some are AI-defended -
  worth the risk for the gear, not a free grab.
- **Accelerated day/night cycle** - a full day/night runs about **2 hours real
  time**: roughly **90 minutes of daylight, 30 minutes of night**. Night falls
  faster than you'd expect, so plan supply runs around it.
- **Traders** - buy and sell gear for in-game currency at **safezone** trader points
  (part of the DayZ-Expansion market). No fighting inside the zone.
- **Code locks** - lock doors, gates, and stashes with a combination code instead of
  a key. Don't forget the code.
- **AI Bandits** *(currently disabled)* - hostile roaming AI that patrol, ambush, and
  dig into settlements across the map. Switched off on the server right now - see
  **Bandits** below for what they bring when they are on.
- **Dogs** *(currently disabled)* - the DayZ-Dog mod adds tameable companion dogs.
  Switched off on the server right now.

### Bandits - know what you're walking into

> [!NOTE]
> **AI Bandits are currently disabled on the server.** The tiers below describe what
> they bring when the mod is switched back on.

Not every bandit is the same fight. Roughly, from most to least dangerous:

1. **Hardened raiders** - heavily armed and armored. Move in large packs, lob
   grenades, shoot straight. The most valuable ground is guarded by these. Don't
   engage without gear, backup, and a way out.
2. **Armed patrols** - rifle-carrying groups of moderate size. A serious threat in
   the open, but beatable with cover and a working firearm.
3. **Settlement holdouts** - smaller armed bands squatting in populated areas.
   Still deadly in numbers, but less disciplined than the raiders.
4. **Scavengers & stragglers** - no firearm at all: just a blade (knife, machete, or
   a bat), usually in pairs. Dangerous only up close.
5. **Desperates** - the bottom rung: no gun at all, just fists or a crude club,
   almost always alone and barely a threat. Wretched, cornered, and carrying next to
   nothing - but a safe first kill.

> [!TIP]
> When bandits are on, the **scavenger** and **desperate** tiers are deliberately
> **more forgiving** - small, poorly armed, and easy to catch off guard. If you're
> fresh off the coast or short on gear, they're the safest way to pick a fight
> without getting instantly wiped.

### Restarts

The server runs a **6-hour restart cycle** with in-game warnings counting down
from **90 minutes to 1 minute** before each restart. Restarts are automatic and
quick.

> [!CAUTION]
> When a restart warning appears, get somewhere safe and log out if you can - you'll
> reconnect to the same character and world once it's back up (usually under a
> minute).
