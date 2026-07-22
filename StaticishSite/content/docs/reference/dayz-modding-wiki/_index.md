---
title: "DayZ Modding Wiki"
weight: 10
bookCollapseSection: true
---

# DayZ Modding Wiki

A mirror of the StarDZ Team community wiki. I did not write this - read the
caveats below before acting on any of it.

## Source and licence

| | |
|---|---|
| Project | [DayZ Modding Wiki](https://github.com/StarDZ-Team/DayZ-Modding-Wiki) by StarDZ Team |
| Live site | [stardz-team.github.io/DayZ-Modding-Wiki](https://stardz-team.github.io/DayZ-Modding-Wiki/) |
| Licence | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| Pinned commit | `1148527` (2026-03-27) |
| Mirrored | English chapters only |

Licensed under CC BY-SA 4.0. No changes were made to the text. This page and the
chapters below are redistributed under the same licence.

## Read this first

The upstream project describes its current state as pre alpha, and it is
assembled with AI assistance. It is broad and often useful. It is not
authoritative. Two problems I hit directly:

- The serverDZ.cfg chapter documents 25 parameters and omits several real ones,
  including `steamQueryPort`, `motd`, `respawnTime`, `timeStampFormat` and
  `allowFilePatching`. Treat its lists as partial.
- Day and night cycle maths on community sources is frequently wrong. Check my
  own [DayZ server notes](../../game-servers/dayz/) for the corrected formula.

Verify anything here against [dzconfig.com/wiki/serverdz](https://dzconfig.com/wiki/serverdz)
or the mod's own repository before you change a live server.

## Updating the mirror

The wiki is a git submodule pinned to a reviewed commit, so it never changes
under you. To move it forward:

```bash
git -C StaticishSite/external/DayZ-Modding-Wiki fetch origin
git -C StaticishSite/external/DayZ-Modding-Wiki checkout <commit>
git add StaticishSite/external/DayZ-Modding-Wiki
```

Update the pinned commit in the table above in the same change.
