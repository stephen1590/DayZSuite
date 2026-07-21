# config-defaults/ — frozen default baselines

Mirror of the `<name>.defaults<ext>` files that sit beside each patched config file on the box.
Paths beneath here are **server-relative**, e.g.:

```
config-defaults/profiles/AIB_Unleashed/AIB_UL_Config.defaults.json
config-defaults/mpmissions/dayzOffline.sakhal/db/globals.defaults.xml
```

## What these are

A default is the pristine copy of a file captured the first time prestart patched it (see
`Apply-ConfigOverrides.ps1`). The live file is rebuilt every prestart as **default + the current
patches from `config-overrides.json`**, so removing an override reverts the field to its default
and accidental drift is wiped.

## How they sync

- **Born on the box** at prestart (capture-if-missing).
- **Pulled here** by `Sync-ConfigDefaults.ps1` during a deploy — but only ones the repo lacks, so
  once captured the repo copy is authoritative and a hand-edit wins.
- **Shipped back** to the ServerDir by `Deploy-DayZServer.ps1` (repo -> box), so a hand-edited
  default takes effect.

## Editing / refreshing

- **Edit a default:** change the file here and deploy. It ships to the box; the live file rebuilds
  from it on the next start.
- **Refresh after a mod update** (adopt the mod's new baseline): delete the file BOTH here and on
  the box, then deploy — prestart re-captures the current pristine file and the sync pulls it back.

These files are hidden from the Configs list and the config viewer's file tree; they surface only
as the "default" value shown beside each override in the editor.
