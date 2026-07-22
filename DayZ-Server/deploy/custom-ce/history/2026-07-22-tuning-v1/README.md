# Tuning v1 - refill rates, not spawn counts

Applied 2026-07-22. Baseline it patches: `../2026-07-22-baseline-upstream/`.

## What changed

| | Before | After | |
|---|---|---|---|
| Total nominal | 2187 | 2067 | -5.5% (food only) |
| Total min | 1051 | 547 | -48% |
| Types with restock 0 | 105 | 18 | 87 moved to 1800 |

140 types tuned in the shared file, 143 in the Enoch variant.

## Rules

1. **min = 25% of nominal** (floor 1), all 140 types. Upstream averaged 43%, peaking at
   86%. The nominal-to-min gap decides how much loot can leave the world before CE
   refills - a narrow gap pins an item at nominal permanently. Average gap 8.1 -> 10.9.
2. **food nominal 25 -> 10** on the 8 dairy/bread types. The only nominal change.
3. **restock 0 -> 1800** on 87 non-essentials. Ammo, magazines and medical keep 0.

## What this does NOT do

Peak availability is unchanged for everything except food. Nominal is the spawn target
and it barely moved. What moved is how far the world drains before CE tops it back up,
and how long it waits. Expect fewer items on average over a session, same ceiling.

The 46 colour-variant duplicates (7 Landrover door colours etc., 655 nominal, 30% of the
file's world loot) are UNTOUCHED. They remain the largest source of volume and the most
direct cause of the car-door complaint. Deliberately left for a separate decision.

## Regeneration

Both files are GENERATED from the expansion_types.xml they sit beside. An Expansion
update changes upstream nominals and makes these stale - regenerate, do not hand-edit.

The per-map split is mandatory, not stylistic: 33 of the tuned types have different
tier values in the Chernarus and Enoch variants. A single shared tuning file would
carry Chernarus Tier4 tags onto Enoch, which defines no Tier4, and those 33 types
would stop spawning there entirely.
