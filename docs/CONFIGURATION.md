# Configuration

## `host.env` — secrets and settings for the server itself

`host.env` describes the box it lives on — everything in it gets rendered into something
that runs there. It is per-host (a dev machine acting as a deploy control point doesn't
need one at all), gitignored, copied from `host.env.example`, and never committed:

| Key | Used by | Notes |
|---|---|---|
| `DEPLOY_USER` / `DEPLOY_GROUP` / `DEPLOY_HOME` | `Deploy-DayZServer.ps1` | Rendered into the systemd unit template (`{{DEPLOY_USER}}` etc.). Falls back to built-in defaults if unset. |
| `DEPLOY_SERVER_PASSWORD` / `DEPLOY_ADMIN_PASSWORD` | `Deploy-DayZServer.ps1` | Rendered into `serverDZ.cfg`'s `password`/`passwordAdmin`. No default — deploy refuses to run until both are set. |
| `DEPLOY_STEAM_ACCOUNT` | `Deploy-DayZServer.ps1` (rendered into `update.sh`) | The Steam account that owns DayZ; steamcmd needs it to download the app/mods. No default. |

Any value can be overridden per-invocation with the matching CLI flag (`-DeployUser`,
etc.) without touching `host.env` at all.

## DEPLOY_REMOTE_HOST / DEPLOY_REMOTE_USER

Deliberately **not** in `host.env`. Which host to reach isn't a setting the server has
about itself — it's config for whichever machine is *initiating* a deploy (your laptop,
a CI runner, wherever you run `Deploy-DayZServer.ps1`, `Pull-DayZServer.ps1`, or
`Sync-VPPCoordinates.ps1` without `-Local`). Putting it in `host.env` would mean the file
that lives on the server also has to somehow tell other machines how to reach that same
server — the two roles don't fit in one file, and a global machine dotfile doesn't fit
either (it's config for *this repo checkout*, not your whole machine).

Instead, it's a second local file: `deployer.env`, copied from `deployer.env.example`,
gitignored, and — like `host.env` — never rsynced to the server (both are explicitly
excluded from the deploy payload):

```bash
cp deployer.env.example deployer.env
$EDITOR deployer.env
```

```ini
DEPLOY_REMOTE_HOST=your-host
#DEPLOY_REMOTE_USER=ubuntu
```

`DEPLOY_REMOTE_USER` defaults to `ubuntu` if omitted. Both accept an
[SSH config](https://man.openbsd.org/ssh_config) `Host` alias as the value, if you'd
rather manage the actual hostname/identity file there. Either can also be overridden
per-invocation with `-RemoteHost`/`-RemoteUser`, which always win over `deployer.env`.
Running with `-Local` (i.e. directly on the server) needs neither — there's nothing to
reach.

## Config overrides — patching mod/vanilla files without owning them

`config-overrides.json` patches individual fields into config files this repo doesn't
otherwise own the whole content of (vanilla mission files, mod-generated configs). The
key idea: **we never store a full copy of the baseline file** — only the field-level
delta. When a game or mod update rewrites its baseline, your override still applies on
top by name instead of fighting (or silently losing to) the update.

Shape:

```jsonc
{
  "files": {
    "<relpath under the server dir>": { "<selector>": "<value>" }
  },
  "mpmissions": {
    "common": { "<mission-relative file>": { "<selector>": "<value>" } },  // applied to every mission first
    "<mission-name>": { /* same shape, applied AFTER common, wins on conflict */ }
  }
}
```

Selectors: XML files use XPath (an attribute node like
`//var[@name='X']/@value`, or an element's text like `//type[@name='Y']/nominal`); JSON
files use a dotted key path (`chanceToSpawn`, or `a.b.c`). Keys starting with `_` are
ignored (used for the schema's own `_readme` field).

**Applied at runtime, not at deploy time** — `prestart.sh` runs
`Apply-ConfigOverrides.ps1 -Fix` on every server start, before the engine reads the
files. Editing `config-overrides.json` and restarting is enough; no redeploy needed.
`Deploy-DayZServer.ps1` only *reports* the pending diff, so a deploy shows you what the
next restart will apply without a second writer touching the live files.

Fail-soft by design: a missing file or an unmatched selector is logged as a warning and
skipped — one broken override never blocks the others or the server boot.

**Not managed here:** full-file-owned configs — see the AI bandit section below — are
authored wholesale under `deploy/`, not patched.

## AI bandit spawns

The AI Bandits mod reads one fixed path full of raw per-map world coordinates, with no
per-map awareness built in. This repo composes that flat file from a source tree on every
boot instead of shipping a single static config:

```
deploy/profiles/AI_Bandits/common/DynamicAIB.common.json    map-agnostic: loadout kits, squad templates, sniper templates
deploy/profiles/AI_Bandits/maps/<mission>/DynamicAIB.json   per-map placements only: name, coordinates, size, which template
deploy/profiles/AI_Bandits/maps/<mission>/StaticAIB.json    per-map fixed sentry NPCs (no shared layer)
```

`Build-AIBandits.ps1` merges `common ⊕ maps/<mission>` into the flat file the mod reads,
expanding each placement's `size` into that many NPC classes drawn from the loadout kit's
pool. It runs automatically via `prestart.sh` on every boot, using whichever mission is
currently active — so a map switch can never leave a stale map's coordinates in place. A
mission with no per-map file gets an empty bandit config, never another map's.

Bandit **types** (loadout/weapon/accuracy/faction) are defined once in `common/` and
apply to every map; only **placements** (coordinates) are per-map. Retune a type once,
every map picks it up; add or move a placement in the relevant per-map file.

See [`deploy/profiles/AI_Bandits/README.md`](../deploy/profiles/AI_Bandits/README.md) for
the full schema, including the native-passthrough escape hatch for dropping in an
unmodified community config.

### Spawn points sourced from admin bookmarks (VPP)

Some maps source their dynamic spawns entirely from VPPAdminTools bookmarks instead of a
hand-authored per-map file: an admin captures a position in-game, and
`Sync-VPPCoordinates.ps1` pulls the bookmark list down and classifies each entry by a
naming convention (`<map>_<category>_<size>_<name>` → a fully-classified spawn group;
`<map>_<name>` → coordinates only; no map prefix → an ordinary bookmark, ignored). The
mapping from letter/category/size tokens to real templates lives in
`deploy/profiles/AI_Bandits/common/classification.json`.

```bash
pwsh ./Sync-VPPCoordinates.ps1                  # dry-run: show what was found
pwsh ./Sync-VPPCoordinates.ps1 -Execute          # write the coordinate files
pwsh ./Sync-VPPCoordinates.ps1 -Execute -Build   # also preview the composed output locally
```

The live TeleportLocation store is read-only from this tooling's side — it also holds
admins' personal teleport bookmarks, so it's never written back to.

## Admin permissions (VPPAdminTools)

- `deploy/profiles/VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt` — Steam64 IDs
  with full admin access. Full-file owned; edit and redeploy.
- `deploy/profiles/VPPAdminTools/Permissions/UserGroups/UserGroups.json` — named
  permission groups with specific capability lists, for admins who shouldn't have every
  permission.
- `vppDisablePassword` in `serverDZ.cfg` controls whether VPP's in-game admin password
  prompt is skipped in favor of gating purely on the Steam64 ID lists above. On a
  publicly-joinable server, prefer requiring both.

## Log archiving

`deploy/Archive-Logs.ps1` is a generic log archiver (reusable for any service via
`-SourceDir`/`-Name`), deployed as a systemd timer (`dayz-logarchive.timer`) that runs
daily. It zips yesterday-and-older `*.log`/`*.RPT`/`*.ADM`/`*.mdmp` files per day into
`profiles/archive/`, skips files still open, and prunes zips past a retention window —
judged by the zip's own age, so an old log archived today still gets a full window.
Read-only by default like everything else here; `-Fix` is what actually writes/deletes.

## Trading

Trading is provided by the DayZ-Expansion-Market mod (`@expansionmarket`). Its item
price/category files, trader-zone placement, and player-to-player market config live
under the mission's own `expansion/` tree on the server rather than in this repo's deploy
payload — bring them under version control here the same way as other full-file-owned
configs if you want them tracked.
