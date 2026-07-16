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
a CI runner, wherever you run `Deploy-DayZServer.ps1` or `Pull-DayZServer.ps1`
without `-Local`). Putting it in `host.env` would mean the file
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
files. Editing overrides in the web editor (or the box copy directly) and restarting is
enough; no redeploy needed. `Deploy-DayZServer.ps1` only *reports* the pending diff, so
a deploy shows you what the next restart will apply without a second writer touching the
live files.

Fail-soft by design: a missing file or an unmatched selector is logged as a warning and
skipped — one broken override never blocks the others or the server boot.

**Not managed here:** full-file-owned configs — see the AI bandit section below — are
authored wholesale under `deploy/`, not patched.

### Who owns what — the pull-only config model (2026-07-16)

One rule: **the deploy ships code and overwrites it; it never overwrites config content.**
Every file is in exactly one class, and the class decides the direction it moves:

- **Code (repo-owned, ships on drift):** scripts, systemd units, PBOs, `update.sh`,
  `prestart.sh`, `serverDZ.cfg` (rendered from `host.env`), `mods.conf`, the `custom-ce/`
  injection layer, VPP permission files. Only the deploy writes these — edit in the repo,
  redeploy.
- **Config content (box-owned, seed-if-missing):** `config-overrides.json`,
  `spawn-points.json`, the AI_Bandits source tree, the Babaku per-map sources,
  `messages.xml`, every mod-generated settings file, and the frozen `.defaults`
  baselines. The box writes these (web editor, prestart's capture); the deploy copies
  one to the box **only when it's missing there** (fresh box / disaster recovery —
  reported `BoxOwned` otherwise) and pulls them back into committed repo **mirrors**.
- **Host-local (never moves):** `host.env`, `deployer.env`, `map.env`, battleye configs.

To change a config value: **use the web editor (ConfigViewer) and restart.** It writes
the box's live document; the next deploy's pull mirrors it into the repo for backup. To
add a brand-new field: same thing — the overrides engine **force-creates** missing JSON
keys at boot (reported `[NEW]`), so nothing needs to pre-exist anywhere. Repo-side edits
to seed files affect *future fresh boxes only*.

**Never edit the repo `config-overrides.json` by hand.** The sync records the hash it
last wrote (`backups/config-overrides/last-synced.sha256`); unexplained local edits
make it refuse to run — and abort the deploy — instead of silently pulling over them.
`-AcceptLocalLoss` discards them (a snapshot lands in `backups/` first).

Backups: run `./Pull-Configs.ps1 -Execute` after a web-editing session worth keeping and
commit the mirrors — git history is the long-term config backup.

### Test → deploy → validate

Config changes go through a repeatable, gated pipeline so a broken config can't reach prod:

1. **Test (before deploy)** — `./Test-Configs.ps1` builds the real artifacts *offline* from
   the repo mirrors, running the same engines the box runs (`Apply-ConfigOverrides` force-create
   and `Build-AIBandits`) against a throwaway server dir. It fails on a dead override, a malformed
   composed artifact, or a missing force-created key. Because the inputs and engines are identical
   to the box's, a green result means the live build is already known-good. It runs **automatically
   inside `Deploy-DayZServer.ps1 -Fix`** (after the pulls, before the ship) and **aborts the deploy**
   on failure — `-SkipConfigTest` bypasses in an emergency. A "file not found" for a common override
   into a mission that lacks that file (e.g. parked Chernarus) is reported as a benign note, not a
   failure.
2. **Deploy** — `./Deploy-DayZServer.ps1 -Fix` pulls the box's live config into the mirrors, runs
   the gate, ships code, restarts.
3. **Validate (after deploy)** — `./Confirm-LiveConfigs.ps1` confirms the *running* server matches:
   every override applied (zero-MISS), composed artifacts valid, unit active. This is the only part
   that needs the box — you can't confirm a restart's result before the restart.

Recovery: see [RECOVERY.md](RECOVERY.md).

### The config registry — one list

Every config surface is declared once, in `config-registry.json`, and four consumers read
that one file. Add or change a config there and nothing else needs editing:

- **the web allowlist** — `NginxService/Api`'s `Deploy-Api.ps1` reads the registry by
  sibling reference at deploy time (config is a DayZ-Server dependency; the API references
  it, so the list lives with the server it describes). Rows with `web` != `none` become the
  read/write allowlist baked into `dayz-ctl`.
- **the deploy seed** — rows with a `seed` are copied to a fresh box if missing.
- **the pulls** — the `mirror` tag says which pull backs each file up.
- **the validator** — rows with a `check` are parse-asserted by `Confirm-LiveConfigs.ps1`.

Each row carries a `scope`: **`shared`** (one file applied to every map — edit once) or
**`map:<mission>`** (belongs to that mission only). The AI-bandit shared templates
(`common/`) are `shared`; per-map placements (`maps/<mission>/`) are `map:<mission>`. Adding
a map is a few `map:<mission>` rows; the shared layer stays a single file. See the
`_readme` in `config-registry.json` for the full field reference.

### Frozen baselines

Prestart rebuilds every patched file as *frozen default + patches*
(`<stem>.defaults<ext>` beside the live file, captured from the live file the first time
it is patched). The baselines are **box-born and box-owned**: `Sync-ConfigDefaults.ps1`
pulls them into the `config-defaults/` mirror (committed), and the deploy seeds one back
only when the box lacks it. To refresh a baseline after a mod update, delete the
`.defaults` file on the box and restart — prestart re-captures the current pristine
file, and the next pull updates the mirror.

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

### Spawn points sourced from spawn-points.json (repo/web-edited)

Some maps source their dynamic spawns entirely from `spawn-points.json` — the definitive
AI-bandit spawn store — instead of a hand-authored per-map file. Each point has `name`,
`map` (the S/C/E letter), optional `category`/`size`, and `x`/`y`/`z`. `classification.json`
maps the `category` token to a template and the `size` letter to a member count
(`deploy/profiles/AI_Bandits/common/classification.json`); a point with no `category` becomes
a base holdout.

Edit it in the **ConfigViewer Map tab** (turn on Edit: drag to move, click to add, edit fields,
Save). Save writes the box copy live and applies at the next restart; the deploy pulls it back
into the repo (`Sync-SpawnPoints.ps1`, box-authoritative). You can also hand-edit the file.

```bash
pwsh ./Sync-SpawnPoints.ps1            # dry-run: what pulling the box's spawn-points would change
pwsh ./Sync-SpawnPoints.ps1 -Execute   # pull the box's live spawn-points.json into the repo
```

VPP is no longer the source. The old one-shot importer/migrator is archived under
`deprecated/` (see `deprecated/README.md`) and never runs in the deploy. The live TeleportLocation
store is read-only from this tooling's side — it also holds
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

`common/Archive-Logs.ps1` (shipped into the server dir by the deploy) is a generic log archiver (reusable for any service via
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
