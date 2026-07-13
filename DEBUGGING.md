# DayZ Server Debug Cheatsheet

## Access

```bash
ssh ubuntu@servermander.ovh
sudo systemctl status dayz-server          # up? recent restarts?
journalctl -u dayz-server -f               # live systemd/service-level output (boot, crashes, exit codes)
journalctl -u dayz-server --since "1 hour ago"
```

`journalctl` only covers the **process lifecycle** (start/stop/crash) — it does not see
in-game events like trades. For those you need the game's own logs.

## Where game logs live

All under `~/servers/dayz-server/profiles/` on the box:

| File | What's in it |
|---|---|
| `*.RPT` | Server-side script/engine log — errors, warnings, mod script output, entity creation. This is what most mods (including AI Bandits) log to (see `README.md`). |
| `*.ADM` | Admin log (enabled by `-adminlog` in the unit) — player-attributable actions: connects, kills, chat, and (for most trader mods) buy/sell transactions. |
| `*.mdmp` | Crash dumps. |
| `AIB.log` | AI Bandits mod's own log — mostly inert, only fires on specific debug events. |
| `profiles/archive/*.zip` | Yesterday-and-older RPT/ADM/mdmp, zipped daily by `dayz-logarchive.timer` -> `Archive-Logs.ps1`, one zip per day, 31-day retention. |

**Rotation matters**: RPT/ADM roll on every restart (and the server restarts every 4h via
`messages.xml`). Always grab the *newest* file, not a fixed name:

```bash
ls -t ~/servers/dayz-server/profiles/*.ADM | head -1
ls -t ~/servers/dayz-server/profiles/*.RPT | head -1
```

## Searching logs

```bash
# live, newest file
grep -iE 'trad|bought|sold' "$(ls -t ~/servers/dayz-server/profiles/*.ADM | head -1)"

# across today's rotations (multiple restarts happened today)
grep -iE 'trad|bought|sold' ~/servers/dayz-server/profiles/*.ADM

# player name search (narrow to the reporter)
grep -i "PlayerName" ~/servers/dayz-server/profiles/*.ADM

# yesterday-or-older: unzip the day in question first
unzip -p ~/servers/dayz-server/profiles/archive/dayz-logs-20260710.zip '*.ADM' | grep -i "PlayerName"
```

RPT for mod/script errors (this is where a broken item reference would surface, similar to
how the `BanditAI_Mirek` failure showed up per README):

```bash
grep -iE 'trader|economy|error' "$(ls -t ~/servers/dayz-server/profiles/*.RPT | head -1)"
```

## RCON (live queries, no log needed)

```bash
pwsh "deploy/dayz-rcon.ps1" /home/ubuntu/servers/dayz-server "players"
```

Confirms who's online right now — useful to correlate a report's timestamp against server
population.

## Trader-specific: "trader didn't give an item"

Trading is provided by **DayZ-Expansion-Market** (`@expansionmarket`, `deploy/mods.conf`) — the
standalone Dr Jones Trader (`@trader`) was deprecated 2026-07-12. Expansion Market's config
currently lives on the box, **not yet in the deploy payload** (config-drift to close): item
price/category files under `profiles/ExpansionMod/Traders/*.json`, trader-zone placement under
`mpmissions/<mission>/expansion/traderzones/`, and player-to-player market under
`mpmissions/<mission>/expansion/p2pmarket/`. Common root causes, cheapest check first:

1. **Full inventory** — by far the most common cause; the trade completes (money moves) but
   the item silently fails to spawn because there's no cargo/slot space. No error anywhere —
   ask the reporter if their inventory was full.
2. **Buy/Sell disabled for that item** — in the relevant `ExpansionMod/Traders/*.json`, an item
   can be configured buy-only, sell-only, or excluded; confirm the category file even lists the
   classname the reporter tried.
3. **Item not in the economy (`types.xml`)** — market files can reference classnames the mission
   economy doesn't define; a missing/misspelled classname usually throws at server **boot**, not
   at trade time — check RPT from the last boot, not from the trade time.

Practical order: get the reporter's name + rough time -> grep `.ADM`/`.RPT` for the transaction
or an Expansion market error -> if the trade shows completed, it's (1); if there's a boot-time
error, it's (2)/(3).
