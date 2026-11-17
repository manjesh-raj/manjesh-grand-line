# Helm kit versions

The Helm kit is every `Helm*.swift` file in `native/Sources/GrandLine/`.
`native/Sources/GrandLine/HelmKitVersion.swift` holds its version table: `HelmKit.version` for the kit as a whole and one semantic version per component.
This file is the release notes for that table, newest release first.
`FM_RUN_HELM_KIT_VERSION_TESTS` reads it, so its shape is part of the contract.

## How to release

1. Change the component.
2. Bump that component's version in `HelmKit.components` (or `HelmKit.surfaces` for an app-level view).
3. Add a section at the top of this file for the new kit version, with one bullet per component that moved.
4. Move `HelmKit.version` by the largest bump in the section.
5. Run `FM_RUN_HELM_KIT_VERSION_TESTS=1 .build/debug/GrandLine` and paste the digest it prints into `HelmKit.sourceDigests`.

The suite prints a new digest only once one of the file's versions has moved.
A changed kit file with no bump fails the run.

## The bump rule

- **patch**: a visual tweak that changes no call site.
- **minor**: a new or extended component, option or token.
- **major**: a breaking replacement, or a removal.
- **new**: a component that did not exist. It enters at 1.0.0 and moves the kit by a minor.

The kit version moves by the largest bump in its release.
A removal is written `` `Name` 1.2.0 → removed (removed) `` and moves the kit by a major.

## Bullet format

Each bullet starts with the component name in backticks, the two versions and the bump kind:

```
- `HelmPageSidebar` 1.0.0 → 1.1.0 (minor): what changed, and the proposal or PR.
```

A change that is not a kit component (a private list retired inside a page, for example) is written as plain prose under the section, without the backticked shape.

## 3.2.0 - S25: the welcome sheet's choice cards, theme tiles and height

- `HelmChoiceCard` none → 1.0.0 (new): a choice as a card: a title, the description inside, a selected ring with a check, a radio button to VoiceOver, Return or Space to pick, and the arrow keys to move the choice within its group.
- `SettingsThemeCard` 1.0.0 → 1.1.0 (minor): `SettingsThemeCard.family(_:mode:isActive:)`, the one family-tile construction Settings › Appearance and the welcome sheet share, and `setActive(_:)`. It enters the table at this release.

The welcome sheet's profile step is two equal-weight choice cards with each description inside, where Operator used to be the primary button. The look step shows Settings' seven family tiles four to a row instead of seven word pills. The sheet's height comes from its tallest step instead of a fixed 470pt. Settings › Profile keeps its three-way switch (it has a Custom state the two cards do not), noted in the PR as a follow-up.

## 3.1.0 - S16: one filter row, one collapse rule

- `HelmFilterBar` none → 1.0.0 (new): five slots in a fixed order (scope, pop-ups, chips, search, trailing). When the slots at their own widths do not fit, or below a page's `collapseWidth`, everything but the scope folds into one "Filter · n" button whose popover holds the folded controls themselves. A view the page hides stays hidden folded or not.

Tasks (Board, List and Calendar), Setup › Updates, Logs and Secrets › Poneglyph build their row with it. Tasks' R4-UI-08 Filter menu is replaced by the bar's popover, and Calendar's "Colour by" is a pop-up in the trailing slot where Board and List have their sort. Connections keeps its own row for now (see the PR's deviations).

## 3.0.0 - S14: one number recipe

- `HelmKPIStrip` 1.0.0 → 1.1.0 (minor): `Density` (`.inline`, the strip as it was, and `.boxed`, each figure on the card surface with its caption above a 28pt figure that steps down to fit). `Item` gains an optional `Detail` line or pill, `isAction` with `onActivate`, a tooltip, and `Item.figure(_:caption:tint:signals:unknownReason:detail:)`. Both densities share the unknown rule (a dash, the reason as a tooltip) and the tint rule (colour only when the figure is not the default).
- `HelmStatTile` 1.0.0 → removed (removed): Crew's six tiles and Review's three are a `.boxed` strip, without the icons (the caption says it). "ready to merge" is still the one cell that is a button.
- `HelmMetricCard` 1.0.0 → removed (removed): Setup's summary row, Health, Logs and Weekly review are a `.boxed` strip. R5-BUG-03's theme fix (the row follows the theme by itself) is kept.
- `HelmMetricRow` 1.0.0 → removed (removed): the boxed strip lays its own cells out.

`FM_RUN_UIUX_PROPOSALS_TESTS` fails on a use of either retired component in the app's code.

## 2.3.0 - S15: one card header recipe

- `HelmSectionHeader` 1.0.0 → 1.1.0 (minor): `Size.card`: a 26pt tile (`HelmMetrics.tileSmall`), a title, a wrapping subtitle, the count in a `HelmCountBadge` and the card's one action in the trailing slot.
- `HelmCard` 1.0.0 → 1.1.0 (minor): `setHeader(_: HelmSectionHeader)`, the one card header recipe. `setHeader(_ view:)` is deprecated for a card's title (documented, not `@available`, so the filter-row callers do not turn into build warnings), and `FM_RUN_UIUX_PROPOSALS_TESTS` fails on a `setHeader(` handed a bare label.

Dictation's six cards (Status, Shortcut, Cleanup, Local Whisper Engine, Words I use often, Recent Dictations) adopt it. "Request … Access" and the model's "Download Model" / "Cancel" / "Re-download" move into the header's trailing slot, the two lists' counts become count badges, and the three 40pt body tiles the headers now name are gone.

## 2.2.0 - S17: one notice for "something on this page needs you"

- `HelmNotice` none → 1.0.0 (new): a card with a tinted tile, an optional kicker, a title, a body, up to two trailing actions and an optional dismiss. An informational notice has no edge; `.warn` and `.critical` carry the card's 3pt attention edge in their hue.

Home's tip, Secrets' Automic Vault warning, GitHub sync's "Pushing is paused" and Crew's answer banner adopt it. Secrets' filled amber band and GitHub sync's private `SetupPausedPushNotice` are deleted, and Home's tip is no longer an edged accent row (UI-4 keeps the only edge on Home for the attention card). Secrets' notice gains "View Fix…" when one launcher needs attention; Crew's setup prompt gains an "Open Setup › Setup steps" button where the whole row used to be the link.

## 2.1.0 - S12: one glyph per meaning

- `HelmSymbol` 1.0.0 → 1.1.0 (minor): `HelmSymbol.Role`, a table from a meaning to its one glyph (`themeLight` sun, `themeDark` moon, `dailyNote` calendar day, `inspector` sidebar). A symbol bound to two roles fails `FM_RUN_UIUX_PROPOSALS_TESTS`.
- `WorkspaceToolbar` 1.1.0 → 1.1.1 (patch): a page action's overflow-menu entry takes its explicit menu title before its visible one, so a button showing a short word on the toolbar is still named in full in the menu.

The Notebook's "Today's note" draws the daily-note glyph instead of the light theme's sun, and keeps the short word "Today" beside it where the window toolbar is compact. The Notebook's daily rows use the same glyph. The theme toggle and the inspector button read their glyphs from the table.

## 2.0.0 - S13: project colours are a stored identity

- `ShiftProjectPalette` 1.0.0 → 2.0.0 (major): a project's colour is stored on the project (`ShiftProject.hue`) and resolved through `HelmDomainHue.categoricalHex`, the seven-hue categorical ramp, never a theme's `warn` or `critical` slot. `ShiftStore.addProject` gives a new project the first free hue, the project sheet and the project detail form gain a swatch row, and the FNV-1a hash stays as the fallback for a record with no stored hue. `tint(forProjectID:)` and `tints` are removed, so it enters the table at 2.0.0.
- `HelmPageSidebar` 1.1.0 → 1.2.0 (minor): `RowIndicator.hueDot(HelmDomainHue)`, a dot in a categorical identity hue, for a record that stores its own colour.
- `HelmButton` 1.0.0 → 1.1.0 (minor): `tintHex`, a literal label hue that overrides `tint` and is contrast-corrected the same way (a project's filter chip).

The Tasks board, list, table, calendar (chips, legend and the Unscheduled tray), the sidebar's project rows, the project filter chips and the project pop-up all read the stored hue. Three new projects are blue, teal and violet. An existing project keeps a hash colour, now from the categorical set, until it is edited.

## 1.7.0 - S05: Settings content beside its nav

- `HelmSplitPage` 1.0.0 → 1.1.0 (minor): `ContentAlignment` (`.centered`, `.leading`), `leadingContentGutter` (32pt) and `alignCappedColumn(_:in:alignment:)`, the one place a capped column's anchor and margins come from, with `horizontalMargins(for:)` for its grow tie.

Settings passes `.leading`: its column and header sit 32pt past the band's edge with the slack on the right, in both window layouts. The cap and gotcha 13's priorities are unchanged.

## 1.6.0 - S06: cards hug their content

- `HelmModuleCard` 1.1.0 → 1.2.0 (minor): `hugsContent` drops the hub's 124pt `minimumHeight` floor for a card that sits in a grid of its own kind. Every Home card keeps the floor.
- `HelmPlateCard` 1.1.0 → 1.1.1 (patch): an `.onAim` plate's height is a floor at its header, so a row's per-row `equalHeights` can stretch it to its tallest neighbour.
- `Home Tasks card` 1.0.0 → 1.0.1 (patch): the urgent tasks as rows (overdue, then due today) with "Showing n of m", where a lone "1 task" numeral left most of the card empty. It enters the table at this release.

Tools' plates hug their two lines of description and each row matches its tallest plate. Runbook and Postmortem grids pass `equalHeights` per row. `HelmResponsiveGrid` already equalised per row, so it is unchanged.

## 1.5.0 - S02: the window toolbar's icons in two groups

- `WorkspaceToolbar` 1.0.0 → 1.1.0 (minor): `WorkspaceToolbar.Group`. **Open** is Quick Connect's two icons and the calendar, then a space the toolbar manages. **Window** is the light/dark toggle, the bell and the inspector, then Search and the page's primary action. The Open group shares Quick Connect's overflow priority, so a narrow window moves it to the overflow menu as one. The groups are an order, a space and a priority, not `NSToolbarItemGroup`, so every item identifier and the captain's saved arrangement survive.

## 1.4.0 - S04: one page-sidebar surface

- `HelmPageSidebar` 1.0.0 → 1.1.0 (minor): `Surface.band`, now the default, plus `HelmPageSidebar.Band` (the side-panel fill and its edge hairline, theme-following) and `bandPaneWidth` / `bandInsets` (Settings' own numbers, so every band is one width with one padding).

Schedules, Reading list and Notebook hold their columns in a `.sidePanel` split pane with the band's width and padding, where they sat on the page ground. Settings reads the same constants and looks as it did. Commands' column loses its card and sits on a full-height band behind it. Code's "Snippets" and "Quick actions" cards are one band running from the page's edge to the status bar, with the two actions as its footer (the private card pair is removed). Tasks, Hosts and Poneglyph keep `.plain` explicitly.

## 1.3.0 - S07: Runbook and Postmortem cards are the control

- `HelmPlateCard` 1.0.0 → 1.1.0 (minor): `Content.actionReveal` (`.always`, the default and the plate as it was, or `.onAim`) and `Content.onDuplicate`. An `.onAim` plate has no action row: the whole card opens (click, Return, Space, VoiceOver), its subtitle is the record's meta line, it is as tall as its header, and duplicate and delete show as 28pt corner glyphs only on hover or focus. ⌫ deletes through the caller's confirm and ⌘D duplicates.

Runbooks and Postmortems opt in. A runbook's meta line is "OpenSSL · 1 step · updated 5 min ago", a postmortem's "Updated 5 min ago · Root cause: …", and a runbook can be duplicated ("<title> copy"). Their Open buttons and resting trash glyphs are gone.

## 1.2.2 - S08: Follow-ups is a lane like the other three

- `Tasks board (page)` 1.0.1 → 1.0.2 (patch): in the sidebar layout the Follow-ups lane wears the status lanes' wash, keeps its amber dot and gains a dashed "Add follow-up" row; its first card lines up with the other lanes'. In the floating bar it stays classic, with a quiet "Add follow-up" at the leading edge like "Add task". The lane's style is now set on every render, so the first render (before the sidebar shell adopts the page) can no longer fix it in the classic shape.

## 1.2.1 - S09: the Done window moves into the Done lane

- `Tasks board (page)` 1.0.0 → 1.0.1 (patch): "Done · last 7 days" leaves the filter row in both layouts and its collapsed Filter menu. The Done lane's count reads "1 · last 7 days", and the List's done tasks sit under a "Done · last 7 days" group header.

## 1.2.0 - S10: the Morning briefing reads as prose

- `HelmContrast` 1.0.0 → 1.1.0 (minor): `quietLink(tintHex:theme:)` and `quietLinkDot(_:font:)`, the one recipe for a link inside prose (ink text, a dot in the target's hue, a faint hover underline).
- `MorningBriefingCard` 1.0.0 → 1.0.1 (patch): every clause is ink with a leading dot, the hover underline is faint, and only a bad state word ("overdue") keeps its colour. The same paragraph view draws Home's briefing card.

## 1.1.0 - S11: the Health card says one verdict

- `HelmRingGauge` 1.0.0 → 1.1.0 (minor): `configure(value:total:tint:)` takes an optional verdict tint for the arc.
- `HelmModuleCard` 1.0.0 → 1.1.0 (minor): the `.ring` and `.ringWithLines` bodies take an optional `tint`, which the arc and the title both paint.
- `StateVocabulary` 1.0.0 → 1.1.0 (minor): `StateWord.tint`, the colour a surface leads with for each state.
- `Home Health card` 1.0.0 → 1.0.1 (patch): the title is the worst verdict in its colour, the ring takes the same tint, the "1 failing" pill is gone, and the note adds "6 of 8 healthy, 1 not run yet".

## 1.0.0 - baseline (S01)

The kit as it stood at `30e26ac3`, minted by S01 of the 2026-11-17 UI/UX proposals.
Every component and every surface in `HelmKitVersion.swift` starts at 1.0.0.
`HelmKitVersionSelfTest` is new with it.
