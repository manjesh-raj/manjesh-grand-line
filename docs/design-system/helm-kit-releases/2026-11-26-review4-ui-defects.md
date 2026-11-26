# 2026-11-26 - Full review 4's UI defects

The kit changes behind UI-01 to UI-13 of the 2026-11-25 full review.
Every option is off by default, so no other call site draws differently.

- `HelmDataTable` 1.0.1 → 1.1.0 (minor): two options for Health's services table (UI-07). `Column.fitsContent` lays a column out at its widest cell and its title, with its `width` as the cap, so short facts (a status, a time, a run of dots) stop holding about 140pt each. `subtitleLines` lets a title cell's second line wrap to that many lines before it is cut, and the row grows by a line for each extra line it takes at the column's width. Its cell wraps only in that case, since a `labelWithString` cell never wraps (gotcha (22)), so a one-line table is unchanged.
