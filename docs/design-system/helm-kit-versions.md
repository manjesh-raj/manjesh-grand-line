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

## 6.7.0 - Hero cards: the palette stays, and either card can be hidden

The captain found the Claude card showing Customize's reset, move and hide controls outside Customize, with no palette, while the Fleet card had its palette and no way to hide it.

- `Home Claude card` 1.0.0 → 1.1.0 (minor): the palette menu ends with "Hide from Home" on Home's arranged cards. It is the same edit Customize's hide button makes, and the toast that follows has Undo and says Customize brings the card back.
- `Home Fleet card` 1.0.0 → 1.1.0 (minor): the same "Hide from Home" item, which the Fleet card had no way to do outside Customize.
- `Home (page)` 1.0.0 → 1.0.1 (patch): leaving Customize ends a resize drag that is still in progress and keeps the size it reached. A drag whose mouse-up never arrived used to survive Done, and the rebuild kept its card with Customize's strip and grips still on it, which hid the card's own palette.

## 6.6.0 - Hero cards: Claude usage and Fleet

The captain's picks on the widget-style board: the Claude usage card as the split hero, the Fleet card as the full hero, each with a size and a colour the captain chooses.

- `HelmHeroSurface` none → 1.0.0 (new): the briefing hero's gradient and glow as a view of their own, with the palette rule (`palette(accent:)`) moved onto it unchanged. `dimmed(_:)` steps a colour most of the way to a grey of its own lightness, for a stale reading (GL-14). `signalColor(tintHex:on:)` lifts a state hue until it clears the non-text floor on both stops, for a ring's arc on the gradient. It takes no clicks.
- `HelmHeroCard` 1.0.1 → 1.0.2 (patch): paints a `HelmHeroSurface` instead of its own two layers. `Palette` is the surface's, and `palette(for:)` and `palette(accent:)` forward to it, so nothing it draws changes.
- `HelmModuleCard` 1.2.0 → 1.3.0 (minor): `Content.hero` paints the card with the hero surface in a `HeroTone` (the theme's accent or a fixed colour, optionally dimmed). Two body kinds draw on it: `.heroSummary` (headline, body, ring and a KPI strip, the whole card on the gradient) and `.heroSplit` (headline and ring on a panel down the leading edge, 226pt or 470pt, or on a band across the top below 400pt, with `.usageReportDense`'s rows on the card beside or under it). Every word on the gradient takes the palette's ink, and a ring's arc takes a warning or limit colour through `signalColor`. `Content.headerMenu` adds a second header control that opens a menu, with the same gesture arbitration as the header action (gotcha (20)), and hidden while Customize arranges.
- `HelmKPIStrip` 1.1.0 → 1.2.0 (minor): `heroInk`, so an `.inline` strip can sit on a hero gradient (figures and captions in the ink, a quiet figure at 72%, hairlines at 32%), and `figureSize`, for the hero's 22pt and 24pt figures.
- `Home Claude card` none → 1.0.0 (new): the split hero on every shelf card. The headline is `claudeChip`'s verdict as a sentence, the ring is the spend against its cap when the spend is the verdict and otherwise the window that runs out first, and the report beside it is the dense report's own rows. The floating bar's fitted hub keeps its dense card.
- `Home Fleet card` none → 1.0.0 (new): the full hero on every shelf card, with a ring of what is done today out of everything the snapshot knows (done, working and queued). A blocked crewmate now reads red rather than amber, and a stale watcher dims the card.

## 6.5.0 - Feel pass: CI's two findings

- `HelmSegmentedTabs` 1.1.0 → 1.2.0 (minor): two init options for a strip in system chrome. `pillInset` overrides the size's horizontal pill inset, and `labelSize` fixes the label's point size so it does not follow the chrome text scale. The window toolbar's tabs take 8pt and 11.5pt: the toolbar is system chrome that never followed the text scale, and at 1512pt with Larger text the wider strip pushed Crew's and Connections' crumbs into the overflow menu on CI (`WorkspaceToolbarSelfTest`). `FeelPassSelfTest` now holds the strip to the system control's width at every text scale.
- `HelmHeroCard` 1.0.0 → 1.0.1 (patch): the gradient's colour writes go through `HelmMotion.withoutImplicitAnimation`, the app's one gradient gate, like every other gradient site (`DaylightHardeningSelfTest`).

## 6.4.0 - Feel pass item 4: the sidebar's search pill

- `WorkspaceSidebar` none → 1.0.0 (new): a 28pt "Search or jump to" pill with the ⌘K keycap under the account header opens the same ⌘K palette as the toolbar's Search. Its words are corrected against its deeper hover fill, so they clear the text floor in every theme. It replaces stage 6's 1pt header rule as the divider between the header and Home, with 6pt above and below it. To keep the whole default list inside a 950pt window (R4-BUG-03), the group heading rows go from 24pt to 18pt (a 2pt foot under the 13pt heading), the captain's call. Headings take no Compact step, because 18pt is already the height their label needs.

## 6.3.0 - Feel pass item 6: Comfortable and Compact density

- `HelmDensity` none → 1.0.0 (new): Comfortable or Compact, stored as `AppSettings.density` and chosen in Settings, Appearance, Window. Compact's row factor is the prototype's 30/36.
- `HelmType` 1.1.0 → 1.2.0 (minor): `scaledRowHeight` multiplies by the density's row factor after the text scale, rounding a Compact height to a whole point. Comfortable multiplies by exactly 1 and is not rounded, so every existing height is unchanged. A density change re-fires the current theme, which is where every list already re-reads its row height.

## 6.2.0 - Feel pass item 5: the toolbar tabs slide

- `HelmSegmentedTabs` 1.0.0 → 1.1.0 (minor): `setToolTip(_:forID:)`, so a segment can explain itself on hover.
- `WorkspaceToolbar` 1.1.1 → 1.2.0 (minor): the module tabs in the toolbar's centre are a `HelmSegmentedTabs` (compact) instead of an `NSSegmentedControl`, so the selection is the kit's thumb sliding from the old tab to the new one, as the page's own filter rows already do. The strip is rebuilt only when the tab names change, a count change retitles its pill, and the theme repaints it. Everything else in the toolbar stays a system control.

## 6.1.0 - Feel pass items 1 to 3: the display title, the hero and its ring

The native feel pass on Home (the Fable second-opinion review's Stage 1, cut to the feasibility audit's six items).
This release carries items 1 to 3: the greeting title, the Morning briefing hero and the Home KPI strip.

- `HelmType` 1.0.0 → 1.1.0 (minor): `displayTitle()`, `displayTitleKern` and `displayTitleAttributes(color:)`, a page's 30pt bold display title, tracked at the prototype's -0.025em, with tabular numerals. Home's greeting is its first user.
- `HelmRingGauge` 1.1.0 → 1.2.0 (minor): `init(side:)`, so a ring can be drawn larger than 66pt with its stroke and centre label scaled to match (`heroSide` is 86). `trackColorOverride` and `labelColorOverride` let a ring sit on a coloured gradient. The track and arc colours now change without an implicit cross-fade on a theme change.
- `HelmHeroCard` none → 1.0.0 (new): a full-width card on the theme's accent, washed from a lighter corner to a deeper one with a radial glow, carrying a kicker, a headline, a three-line body, up to two actions and an 86pt count ring. White ink is kept wherever it clears the text floor; otherwise both stops are deepened until it does (`FeelPassSelfTest` sweeps every theme).
- `Home (page)` none → 1.0.0 (new): in the sidebar layout, Home opens with a greeting as its display title and a one-line summary of the day (the column's date line is dropped, since the summary carries the date), then the Morning briefing as a `HelmHeroCard` with the services ring, then a `.boxed` `HelmKPIStrip` of four tiles (tasks due today, PRs ready to merge, services healthy, Claude week), each a button to the page that owns it. The briefing leaves the card grid while it is the hero, and Customize draws it as a card again. No sparklines: nothing records a series. The floating bar's hub is unchanged.

## 6.0.0 - S03: one page frame

- `HelmPageScaffold` none → 1.0.0 (new): the page frame. A scrolling page hands it its blocks and keeps none of the mechanics: the scroll view, the flipped document pinned to the clip view (gotchas (4) and (9)), the 24pt gutter, the first-content line and an optional top slot that stays put while the content scrolls. A page that does not scroll reaches the same line through `HelmPageScaffold.pinFirstContent`.
- `HelmMetrics` 1.0.0 → 1.1.0 (minor): `pageHeaderLine` (32), `pageContentTop` (44) and `pageContentInset` (12), measured from the toolbar's bottom. Under the 52pt toolbar they put the header text at 68pt and every page's first content at 96pt from the window's top.
- `WorkspaceModuleHeader` 1.0.0 → 2.0.0 (major): the scaffold's header-line slot. It no longer hides when a page has no subtitle, nor on Connections and Console: the slot keeps its 32pt either way (required, so no page's height tie can grow it), and an empty line is not an accessibility element. `configure(title:subtitle:)` takes a `nil` title for a module that draws no line. It enters the table at this release.

Thirteen pages moved onto the scaffold and dropped their private scroll setups and top constants: Health, Tools, Updates, Bootstrap, Automation, GitHub sync, Dictation, Review, Overview, Vault, Logs, Schedules and Commands. Home, Tasks and Calendar, Connections, Settings, Kubernetes, Runbooks, Postmortems, Crew, Whiteboard, Sticky Board, Notebook, Reading list, Docs and Secrets keep their own layouts (split panes, web islands, a board, a canvas) and take the line through the token or `pinFirstContent`. Console's session strip is that module's first content and sits on the line. The first content moved from ten heights between 76pt and 117pt to 96pt on every page (`MainSplitShellSelfTest.checkEveryPageStartsAtOneHeight`).

## 5.0.1 - S22: an empty state follows the theme

- `HelmEmptyState` 1.0.0 → 1.0.1 (patch): the state observes the theme itself instead of painting it once at `init`. The inspector never passed a theme change on, so after Dusk to Daylight its "Nothing selected" kept Dusk's ink (E8E6DE) and muted ink on Daylight's light column, which read as a pale title. The label is not vibrant (`allowsVibrancy` false, plain Aqua appearance), so the system glass was not the cause.

## 5.0.0 - Layer shadows at §2.5's blur

- `HelmCard` 1.1.0 → 2.0.0 (major): `applyElevation` sets `CALayer.shadowRadius` to half the elevation's `NSShadow` blur, because `shadowRadius` is a standard deviation and an `NSShadow` (or CSS) blur is twice one. Every layer-backed elevation had rendered at twice §2.5's blur, and the floating bar's halo filled the window's top strip (`AppShellBodyWidthSelfTest`'s top-strip case on `nord-snow`). The `blurScale` parameter is removed: its one caller, the toast, used 0.5 to work around the same doubling and now renders the same pixels without it.

## 4.0.4 - S27 follow-up: the crew panel is never a width floor

- `WorkspaceInspectorCrewPanel` 1.0.0 → 1.0.1 (patch): the panel's tie to the inspector pane yields at 490, so the composer's own required width can never be a floor on the window or the split view, and the shell mounts the panel only while the captain has the pane open. A collapsed pane holding it collapsed the sidebar at Home's narrowest width on CI's 1x runner (`MainSplitShellSelfTest`, "homeCanvas at 898pt").

## 4.0.3 - S23 follow-up: the no-session wall sits in the middle of the page

- `Kubernetes (page)` 1.0.1 → 1.0.2 (patch): with no live host session the page is the "No live host session" wall centred in the page, and the Session card hides. Shortening the card's explanation in S23 had moved the wall out of the middle third UXP-13 requires (`PagePolishUXPSelfTest`).

## 4.0.2 - S16 follow-up: the Filter popover closes on lock

- `HelmFilterBar` 1.0.0 → 1.0.1 (patch): registers its popover with `AppLockGate.registerLockDismissiblePopover`, so a Filter popover left open when the app locks does not stay readable above the overlay (GL-09, `LockGateCoverageSelfTest`).

## 4.0.1 - S20 follow-up: HelmIconButton hands hover to AppKit

- `HelmIconButton` 1.0.0 → 1.0.1 (patch): `mouseEntered` and `mouseExited` call `super`, so AppKit's own tracking sees the hover and can never fire the button's action from it (`AppKitAuditSelfTest`'s Hover_hoverNeverActivatesAControl).

## 4.0.0 - S27: the inspector's crew panel

- `WorkspaceInspector` 1.0.0 → 2.0.0 (major): the content model has a default: a page that never fills the pane shows `WorkspaceInspectorCrewPanel` instead of "No details for this page", and a page with details keeps showing them. `modulesWithDetails` and the "No details" copy are retired. It enters the table at this release.
- `WorkspaceInspectorCrewPanel` none → 1.0.0 (new): Operator-only "Ask the crew": a chip naming the context sent (the page's own summary line), three suggested asks per module from a small table, the crew's own composer and reply at inspector width, the trust line, and Continue in Crew. A Personal install gets the page's shortcuts and the tip of the day.
- `StrawHatMenuBarPopoverController` 1.0.0 → 1.1.0 (minor): `openFullChatTitle` and `askQuestion(_:)`, so the inspector hosts this same composer (it already took `init(width:showsOwnHeader:)`) instead of a third crew chat. It enters the table at this release.

## 3.6.0 - S21: page tabs by number

- `WorkspaceGoMenu` 1.0.0 → 1.1.0 (minor): ⌃1 to ⌃9 as hidden Go menu rows (key equivalents still work while hidden) that open the showing module's tab by number, in both window layouts. Previous Tab ⌘⇧[ and Next Tab ⌘⇧] were already there (R2-UX-03). It enters the table at this release.
- `PageShortcuts` 1.0.0 → 1.1.0 (minor): a module with tabs lists them by name with ⌃1 to ⌃n beside "Previous or next tab". It enters the table at this release.

## 3.5.0 - S20: HelmIconButton, 28pt targets

- `HelmIconButton` none → 1.0.0 (new): a glyph-only button: the glyph at 14pt in at least a 28 x 28pt target, invisible at rest, the inset field fill under the pointer, a real `.exterior` focus ring, an optional contrast-corrected tint, and one label for the tooltip and VoiceOver.
- `HelmGridCardView` 1.0.0 → 1.1.0 (minor): a card's glyph actions (a host's bolt and pencil) are `HelmIconButton`s, so each is a 28pt target rather than the glyph's own 16pt.

The inspector's close and the Tasks lanes' "+" adopt it. `FM_RUN_UIUX_PROPOSALS_TESTS` fails on a bare `NSButton` set to `.imageOnly` outside the kit unless its line carries a `HelmIconButton-exempt:` reason; the session-pill and tab-chip closes, a checklist box, a row check badge, a card disclosure and the window toolbar's system items carry one.

## 3.4.2 - S24: GitHub sync rows say what to do

- `GitHub sync (page)` 1.0.0 → 1.0.1 (patch): a fork whose check or sync failed reads what failed, why and what to do ("Couldn't reach GitHub · gh is not signed in on this Mac · run gh auth login, then Check again"), mapped from gh's cases (not signed in, not installed, rate limited, repository missing, no network, anything else). The raw command and output stay in Show Details. It enters the table at this release.

## 3.4.1 - S23: the Kubernetes page shows its shape

- `Kubernetes (page)` 1.0.0 → 1.0.1 (patch): until a feed tab exists, the Pods table's header (naming the namespace, "appears once a feed tab is logged in") over skeleton rows fills the page under the Session card, and the card's two-sentence explanation is one shorter line that keeps the pause warning. It enters the table at this release.

## 3.4.0 - S18: loading states for the web islands

- `HelmSkeletonList` 1.0.0 → 1.1.0 (minor): `init(island:caption:)`: a web island's loader - its shape, the shimmer (Reduce Motion aware), the loading phrase under it, and after five seconds "Still loading. If this keeps happening, Copy diagnostics has the details."
- `HelmSkeletonRow` 1.0.0 → 1.1.0 (minor): `Shape.editor` (a gutter and code lines), `.canvas` (a faint 32pt grid) and `.monthGrid` (a header over five weeks), drawn as one path sized to the island.

Code (Monaco), the Whiteboard (Excalidraw) and the Calendar (Schedule-X) show their skeleton until the bridge's ready message, then cross-fade it out (`HelmMotion.stateDuration`). Code and the Whiteboard used the empty-state component for "Starting the editor…"; the Calendar showed nothing. The header line keeps the page's summary while loading instead of the loading phrase.

## 3.3.0 - S26: theme tiles show the pair

- `SettingsThemeCard` 1.1.0 → 1.2.0 (minor): a family tile draws both registers side by side (light left, dark right, each in its own tokens) with the check on the half that is showing, and its caption names the pair once ("Daylight · Dusk"). The "Light:" / "Dark:" line is gone. `setActiveMode(_:)` moves the check. A terminal scheme card is unchanged.

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
