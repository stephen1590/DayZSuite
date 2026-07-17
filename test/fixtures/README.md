# Test fixtures

Representative, real-shaped mission files used ONLY by `Test-Configs.ps1` to run the prestart
build engines offline. They are **test scaffolding, not mirrored config** — never shipped to the
box, never pulled from it.

| Fixture | Engine it feeds | Why it's a fixture, not a mirror |
|---|---|---|
| `cfgeconomycore.xml` | `Apply-CustomCE.ps1` | Game-owned mission file. A game update rewrites it; the `<ce folder="custom">` block is re-registered every boot. Mirroring a file the game overwrites would go stale — so it isn't in `config-registry.json`. |
| `cfgplayerspawnpoints.xml` | `Build-TransferSpawns.ps1` | Ships with each mission, game-owned. Same reason. |

## What the gate proves vs. what it doesn't

The offline gate stages these into each declared mission and runs the **real** engines against
them. That proves the engines are **sound** — they produce valid, correctly-shaped artifacts.

It does **not** prove the live box's mission file has this exact shape (it's game-owned and can
change with an update). That residual is covered AFTER the deploy by `Confirm-LiveConfigs.ps1`,
which parse-checks the artifacts the box actually produced (`transfer_spawn.json`, the patched
`cfgeconomycore.xml`).

Keep these minimal but real — a stripped-down stub that skips `<travel>` or an existing `<ce>`
block would hide the engine paths the gate exists to test.
