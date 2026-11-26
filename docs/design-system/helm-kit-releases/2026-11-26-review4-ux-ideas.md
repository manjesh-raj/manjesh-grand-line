# 2026-11-26 - Full review 4's UX ideas

The kit changes behind the UX ideas the captain picked from the 2026-11-25 full review.
Every option is off by default, so no other call site draws differently.

- `HelmButton` 1.4.0 → 1.5.0 (minor): `heroProminent`, the one action a hero offers, drawn solid in the hero's ink with its words in the hero's deep stop (the boards' white pill). `HelmHeroColumn` hands it its words on every theme pass.
- `HelmHeroColumn` 1.7.0 → 1.8.0 (minor): a `heroProminent` button gets the pill words as its `heroSelection` (UX-06's "Open Needs you"), and a button handed in as a band view keeps its own width at the band's leading edge instead of filling the band. A `.column` draws its header's `status` as a glass pill under its kicker, and a band can carry a ring and a status at once (UX-18: Health says "1 failing" in a pill and its ring's arc instead of turning the column red).
- `HelmModuleCard` 2.0.0 → 2.0.1 (patch): a `.heroSummary` with no figures draws no strip, so a short hero (UX-02's healthy Health card) has no rule over nothing.
- `HelmDataTable` 1.1.0 → 1.2.0 (minor): `isCollapsed` folds a table to its card's own header while keeping its rows (UX-22's Up to date group, opened on request).
