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

## 10.4.0 - The notifications panel's hero head (N-1)

The captain's pick from the notifications hero board (`data/grandline-notifications-hero-design-scout/`): N-1 Hero head for the panel the sidebar layout's bell opens.
The panel now opens on the hero gradient, as the sidebar, Home's hero cards and the Console's three popovers do.
It is a minor release: the panel is a new surface, and no kit file changed for it.

- `Notifications panel` none → 1.0.0 (new): N-1 Hero head. The head is a `PopoverHeroHeader` with a glass bell tile on the quiet-ink palette. Its kicker keeps "Waiting for you" and the date, the headline is the verdict ("4 things need you", "1 update for you", "All caught up"), the second line says how much is unread, and a 48pt ring of unread items sits in the trailing slot. Inbox, Snoozed and Mark all read are `heroInk` ghost pills on the gradient, the chosen list `heroSelection`. Open Home stays in the footer. The triage cards, their order, the snooze menu, Hide, Mute, read state, Undo, the keys and the VoiceOver actions are unchanged, and the bell's badge still counts every item waiting. The words are `NotificationHeroWords`, pure and asserted in CI's blocking lane.

`PopoverHeroHeader` (not a kit file) gains two options, both off by default: the `.verdict` title style (a kicker above a rounded heavy headline, the row top-aligned) and `quietInk`, which paints `HelmHeroSurface.palette(accent:quietInk:)`. Compose, Claude usage and SRE Lead pass neither and draw as before.

The same release carries TO-1 Hero capsule, the captain's toast pick from the hero restyle board (`data/grandline-hero-restyle-designs-scout/`).
One kit component gained an option for it, and no existing call site changed.

- `HelmHeroSurface` 1.2.0 → 1.3.0 (minor): `glowShape`. `.capsule` sizes the glow from the surface's own bounds, as an ellipse on its top-right corner, the way the board's radial gradient draws it on a surface far wider than it is tall. The card's 220pt glow lay across the right half of a 36pt toast as a grey wash (`#3d567b` against the board's `#2b4267` on Lavender). `.card`, the default, is unchanged, so every existing hero draws as before.
- `Toasts` none → 1.0.0 (new): TO-1 Hero capsule. The capsule paints the hero's quiet-ink gradient with the message in its white ink, through `HelmType`'s scaled 12pt semibold rather than a literal system font. Its glass circle holds the kind's glyph, a check for done, a triangle for a warning and a cross for a failure, each in that state's hue lifted by `HelmHeroSurface.signalColor`. `Toast.show` takes a `Feedback.Kind` (done by default), `Feedback.report` passes its own through, and the plain callers whose message is a failure or a refusal now say so: before this every toast drew a green check, "Docs sync failed" included. Undo is a `heroInk` ghost pill ringed by a hairline that drains over the six seconds the offer stands, with no ring under Reduce Motion. Each toast posts one VoiceOver announcement, with "Undo available" when it has Undo. The words are `ToastHeroWords`, pure and asserted in CI's blocking lane. Timings, stacking and the single Undo slot are unchanged, and the pill is 36pt tall rather than 34pt.

It also carries DH-2 Hero pill, the captain's Dictation HUD pick from the same board.

- `Dictation HUD` none → 1.0.0 (new): DH-2 Hero pill. The floating HUD paints the Dictation hero gradient on Dic-1's two tones (`DictationController.heroTone`): the accent while dictation goes right, the theme's amber for "Copied" and the failures. A glass glyph tile, the constant kicker "Dictation · Grand Line" over the state's own words (unchanged), a level meter while listening and a sweep while transcribing, both still under Reduce Motion. The pill is 52pt tall and as wide as its words, with a white hairline and the window's shadow, and the capsule glow. It follows the theme, which reverses review #3's decision to leave it unthemed: its words clear 4.5:1 on its own gradient, so legibility no longer depends on what is behind it. The non-activating panel, its position, its auto-hide delays and its one announcement per state are unchanged.

It also carries K-2 Lit selection, the captain's ⌘K palette pick from the same board (the alternative, not the recommended K-1).

- `HelmSearchField` 1.1.0 → 1.2.0 (minor): `wellSurface`, the `HelmField.Surface` a `HelmTextField` already takes. `.raised` paints the card's own colour with the raised hairline, for a search field sitting on a card: the inset well is the Lavender palette's `side` colour, which reads as a tinted hole on a white card. Ignored while `heroInk` is set. `.inset`, the default, is unchanged, so every existing search field draws as before.
- `⌘K palette` none → 1.0.0 (new): K-2 Lit selection. The palette sits on the opaque card surface rather than H1's `.menu` material, with the field in a raised well and an `esc` keycap. Rows rest on the card with a faint wash tile of their own hue (`IconTileView`), and the selected row is the one lit thing: the quiet-ink hero gradient with its glow, the title in the hero's ink and the meta line at 80%, a glass tile, and its hint as a shade pill with an ink hairline. Only the selected row shows its hint, kept in the row at zero alpha so titles truncate at the same point and VoiceOver still reads it. §6.11's gradient tile on every row and its `inset` fill with a 3pt ink edge are gone. The footer gains "↑ ↓ to move". The 600pt width, the placeholder, the groups and their overflow line, the keys, "No matches.", the row roles and the height animation, still skipped under Reduce Motion, are unchanged. The header height is now derived from the field's real height: the old 61pt constant described a 32pt field and left the results 8pt short of their own rows.

And it carries CP-1 Hero head capture, the captain's ⌥Space capture panel pick from the same board. No kit file changed for it.

- `Capture panel` none → 1.0.0 (new): CP-1 Hero head capture. The panel opens on the quiet-ink hero gradient with a glass bolt tile, "Capture" and the captain's own chord (read from `AppSettings.quickCaptureShortcut`, where it was a literal "⌥Space"). The field is `HelmSearchField.heroInk` on the hero's dark shade, led by a plus, and the date and clipboard chips are shade pills on the gradient. The tile Return files to is lit with the gradient, and the light moves to the crew's pick before it files. A filed capture's confirmation takes the head for the same 0.9s, cross-faded, and swapped outright under Reduce Motion. The accent border and the dividers are gone, refusals sit at the top of the body, and the hint reads ⌘1–⌘6, derived from the destinations (it stopped at ⌘5 after Link became ⌘6). Return, the chords, the refusals that keep the panel open, the hand-off, the lock gate and the fades are unchanged, apart from three fixes: Caps Lock no longer kills the chords (gotcha (21)), a second Return during the confirmation no longer files twice, and the panel keeps its top edge when a status line appears.

And it carries TK-1 Record preview sheet, the captain's pick for the New Task and Edit Task sheet on the same board.
Two kit components gained an option for it, and no existing call site changed.

- `HelmFormSheet` 1.1.0 → 1.2.0 (minor): `setHeroHeader(_:)`, a hero across the top of a `.sheet`, where only `.panel` chrome had a header slot (`setPanelHeader`). The hero spans the sheet edge to edge and stays put while the fields scroll, and it replaces the heading block (title, subtitle and close square) and the Daylight ribbon. The title's words become the sheet's accessibility label. A carded form under a hero paints the page's ground between its cards and keeps the card surface under its footer. The hero is held to its content's height at a low priority, because nothing else ties it: measured, it otherwise took all 640pt between the top and the footer and left the fields 0pt tall. Both layouts take one, so the Follow-up, Project and Snippet sheets can adopt it with no further kit change. A sheet that never calls it draws as before.
- `HelmChipInput` 1.0.0 → 1.1.0 (minor): `wellSurface`, the `HelmField.Surface` a `HelmTextField` and a `HelmTextView` already take, and `HelmFormSheet.adoptWells` now reaches it. On a section card the inset chip well read as a lavender hole beside the raised Description. `.inset`, the default, is unchanged.
- `Task sheet` none → 1.0.0 (new): TK-1 Record preview sheet. The sheet opens on the task's own card as the board will draw it, on the quiet-ink hero gradient (`RecordPreviewHeader`'s new `.sheet` style, which is not a kit file): a glass tile and the kicker "New task · not saved yet" or "Edit task · Board › In Progress" (the task's real column), the card with its priority-hued tile, its title, a High badge and the due date and project, and the priority, project, repeat, reminder and tags as shade capsules that wrap. The card is redrawn on every keystroke and pick from the task Save would write, so its title is the title as it will be saved, without the date words Save lifts out (U16). The title stays the first field and the first responder, now a raised prominent well in the rounded face, and the five sections are numbered cards with raised wells on the page's ground. The tip and the Detected line, every section and control, the keys, the validation, the focus order, the 520 by 760 sheet and every outcome are unchanged. The words are `TaskHeroWords`, pure and asserted in CI's blocking lane.

And it carries the first half of CR-1 Crew band, the captain's Crew pick on the same board: the band itself and its Needs you and In flight tabs.
Four kit components gained an option for it, and no existing call site changed apart from one inline-strip fix.

- `HelmHeroColumn` 1.4.0 → 1.5.0 (minor): three `.band` options the board draws. `Header.status` is a glass `HelmHeroStatusPill` at the band's top right, its dot the state's hue lifted onto the gradient by `HelmHeroSurface.signalColor`, with the header row top-aligned so it sits level with the kicker. `bandViews` are drawn between the words and the foot, each on a line of its own across the band, and a `HelmHeroTileGrid` among them is laid out at the band's width and painted with the hero card's tile recipe. `footRule` draws a hairline in the ink across the band above the foot. `.column` and `.panel` draw none of them, and a band given none of them draws as before.
- `HelmHeroTile` 1.0.0 → 1.1.0 (minor): `tint`, the fact's hue, which `HelmHeroTileGrid.paint` draws as the dot before the label. `HelmHeroCard` passes its dots itself and is unchanged.
- `HelmHeroTileGrid` 1.0.0 → 1.1.0 (minor): `paint(palette:theme:)`, the hero card's tile recipe (the ink, the wash away from it and its hover step, and each tile's `tint` as a lifted dot) for a grid on a hero that is not a `HelmHeroCard`.
- `HelmKPIStrip` 1.3.0 → 1.4.0 (minor): an `.inline` item can be an action. Its column becomes an `InlineActionCell`, a `HoverHighlightView`, so it is a button to VoiceOver and the keyboard with a focus ring, and it takes a shade on hover (the ghost pill's on a hero), with its caption underlined. Also a fix for every inline strip: each column's trailing inset now holds at the labels' floor. A stack keeps its edge insets only at its hugging priority (250), under the strip's equal-column tie (251), so the widest caption gave up its inset and ran into the hairline after it.
- `Crew (page)` none → 1.0.0 (new): CR-1 Crew band on Needs you and In flight, sidebar layout only. Each tab opens on one `HelmHeroColumn` in `.band`, which replaces the grey header line (`WorkspaceHeaderLineCollapsing`, as Tasks), the answer banner, the boxed figures, the briefing card and Needs you's summary line and boxed empty state. In flight: the `FleetGreeting` verdict as the headline, the watcher as a glass status pill, the Morning briefing's line with Regenerate and Dismiss until tomorrow as ghost icons over Home's Br-3 sentence tiles (each still opening its page), and the six figures as an inline strip in the hero ink, with Ready to merge still the one that opens Review. Needs you: "2 tasks are waiting on you" over the open decisions, waiting and blocked counts, with the band as the empty state, and a failed read paints the dimmed tone, says when it last read and keeps the carried rows. In flight's band is dimmed too when the PR scan fails, and when the crew's task list could not be read it says so rather than "Nothing needs you right now". The rows, Reply, the keys and every action are unchanged, Log keeps its header line until its own band lands, and the floating bar's Fleet page draws exactly what it drew before. The words are `CrewHeroWords`, pure and asserted in CI's blocking lane.

And it carries the Review tab of CR-1, the second half of the Crew band.
One kit component moved for it, a visual fix that changes no call site.

- `HelmHeroColumn` 1.5.0 → 1.5.1 (patch): a band's ring sits at the band's trailing edge, as the boards draw it. The words and the ring's caption both hugged at 250, and the engine broke the tie toward the caption, so the ring sat right after the words with the rest of the band behind its caption. The words now hug at 249 (`bandWordsHug`) when a ring is present, so they take the slack. Raising the caption's hug to 251 moved the ring too, but a raised hug is a width ceiling (gotcha (13)), and it grew a 1100pt window to 1463pt on Connections with the inspector open. A band without a ring, a column and a panel draw as before.
- `Crew (page)` 1.0.0 → 1.1.0 (minor): CR-1 on Review, sidebar layout only. The page opens on the same band as Needs you and In flight, drawn through the same helpers (`CrewBand`). Its headline is how many pull requests are ready to merge ("2 pull requests are ready to merge"), its second line the checks running and failing and the forges they are on, its ring ready over open, and its figures Open PRs, Ready to merge, Checks running and Checks failing. The band replaces the grey header line, the count line and the boxed figures, and on a clean scan with nothing open it is the empty state, so the two empty forge cards go. A scan that reached nothing paints the dimmed tone, says when it tried and when it last read everything, draws no count, and moves Show folder path onto the band, where it reveals the path as a row on the gradient. A scan that missed some forges is dimmed too and keeps the pull requests it found, counted and said to be partial. The forge cards, their rows, Review and Merge, the merge confirm, Refresh in the toolbar and the floating bar's Review page are unchanged. The words are `CrewHeroWords.review`, pure and asserted in CI's blocking lane.

And it carries RP-2 Question head, the captain's pick for the Needs you reply composer on the same board.
No kit file changed for it.

- `Reply composer` none → 1.0.0 (new): RP-2 Question head, sidebar layout only. Reply on Needs you turns the decision row and its composer into one card (`FleetReplyCard`). Its head is the question in full on the quiet-ink hero gradient, in the theme's amber for a blocked task: a glass tile with the state's glyph lifted by `HelmHeroSurface.signalColor`, the row's own kicker, the decision's note as a rounded headline that wraps to every line it needs (the row and the old address line both clipped it), and the repo with the decision or decisions the answer is addressed to. The row's Reply/Cancel button rides on the head as a `heroInk` ghost ×. Under it is the `HelmPromptWell` Compose, SRE Lead and the Crew input use, with no hint line, then today's caption, the status, `HelmKeyHint`s for ⌘↩ and Esc, Cancel and Send. ⌘↩ reaches the card through `performKeyEquivalent` and sends only while the well has focus, ↩ is a new line and Esc cancels. The words, the three outcomes and their messages, focus on open and across a refresh, and the card keyed by task id so typed text survives one are unchanged. A delivery now closes only its own card, where it used to close whichever reply was open. The floating bar's dashboard keeps `FleetMessageComposer` under the row. The words are `ReplyHeroWords`, pure and asserted in CI's blocking lane.

And it carries MB-1 Hero head popover, the captain's menu-bar popover pick from the same board.
One kit component gained an option for it, and no existing call site changed.

- `HelmSegmentedTabs` 1.2.0 → 1.3.0 (minor): `heroInk` and `heroSelection`, the strip on a hero gradient as the board's `.hsegh` draws it. Each segment is its own capsule: the shade and the ink hairline `HelmButton.heroInk` paints a ghost pill with, under the ink's words. The chosen one is solid ink with its words in `heroSelection`, the hero's deeper stop, and a selection under 4.5:1 on the ink falls back to the shade. Keyboard focus is a 2pt ring of the ink drawn 3pt outside the pill in place of the accent ring, which does not show on a gradient of the accent, and it follows `HelmFocusVisibility` as the system ring does. The row's inset grows to `HelmFocusRing.inset` to hold the ring, and the gap between capsules is 4pt. The sliding selection, ← →, the radio roles and their values are unchanged. Built for MB-1's head and general enough for the Crew band's Log filter. `nil`, the default, changes nothing.
- `Menu-bar popover` none → 1.0.0 (new): MB-1 Hero head popover. The compact popover opens on the quiet-ink hero gradient: a `PopoverHeroHeader` in the `.verdict` style with a glass sailboat tile, and words that follow the tab (`CompactHeroWords`): "Today · Tue 24 Nov" over "2 of 6 done today" and the streak and overdue count, with a 44pt ring of done today; "3 notes on the board", counting the whole board rather than the five rows; "3 codes ready", or "Poneglyph is locked"; "Ask the crew". A count the popover cannot read says it is not loaded rather than zero. The tab strip moved into the head as `HelmSegmentedTabs.heroInk`, and the gear is a `heroInk` ghost pill. The Today pane leaves its own header out here only (`TasksBridgePane(showsHeader:)`), and the Tasks menu-bar item keeps it. Locked, the head says "Grand Line is locked" under a padlock and closes up without the tabs, and the pane keeps the same password check, now a centred column of the field, Unlock and the error line. The capture line and the password are raised wells. The ⌃⌥G hint hugs its keys: the footer's slack had set "toggle" about 70pt away from them. The 330 by 520 size, the panes, the capture line, ⌃⌥G, Open full window, ← →, the radio roles and every action are unchanged. The headline is 15pt, the board's size, rather than the `.verdict` 21pt (`PopoverHeroHeader`'s new `titleSize`): beside the ring and the gear the Today words have 168pt, and at 21pt "2 of 6 done today" measures 177pt.

`PopoverHeroHeader` (not a kit file) gains three options for it, all off by default: `titleSize` for the `.verdict` headline, `setSymbol(_:)` for the tile's glyph and `setBodyHidden(_:)`, which takes the body out and closes the head up under its words. Compose, Claude usage, SRE Lead and the notifications panel pass none of them and draw as before.

And it carries the Log tab of CR-1, the last piece of the Crew band.
One kit component gained an option for it, and no existing call site changed.

- `HelmHeroColumn` 1.5.1 → 1.6.0 (minor): a `HelmSegmentedTabs` handed to a column takes the hero ink like the other kit controls. The column sets its `heroInk` to the ink and its `heroSelection` to the nav rows' selected words (`NavInk.selectedInk`), so the chosen segment is solid ink with the gradient's deep stop for words, and it re-hands both on every theme pass. A column with no segmented strip on it draws as before.
- `Crew (page)` 1.1.0 → 1.2.0 (minor): CR-1 on Log, sidebar layout only. The tab opens on the same band as Needs you, In flight and Review: "5 events today" over what they were ("1 merge · 1 task update · 1 investigation saved · 2 incident updates. Latest at 10:32 AM."), "Quiet so far today" with when the last event was, or "Nothing logged yet" as the empty state with no filter and no second empty card. The filter moved onto the band's foot as the same `HelmSegmentedTabs` in the hero ink, each segment with its count ("Merges 3"). Its radio roles and VoiceOver labels, ← →, the sliding selection and what it filters are unchanged, and the grey header line goes as on the other Crew tabs. A log file or a month of Shift's activity that is there and cannot be read paints the dimmed tone and says when it tried and what is unknown, and a segment whose kind could not be read carries no count rather than a zero (`FleetLogFeed.read`, `FleetLogStore.eventsChecked`, `ShiftStore.recentActivityChecked`). The feed sits straight under the band, and its table is as tall as its rows: the last card had been cut 13pt short in both layouts. The floating bar's Log keeps its filter over the feed in the theme's recipe, without counts. The words are `CrewHeroWords.log`, pure and asserted in CI's blocking lane.

## 10.3.0 - The lighthouse lock screen and the treasure chest gate

The captain's picks from the lamp lock-screen board (`data/grandline-login-lamp-design-scout/`): L-2 Lighthouse with the Going Merry and card style C-4 Open sea for the lock screen, and S-1 Treasure chest with card style V-4 Open for the Secrets page.
Both gates float a cardless form on an illustrated scene, so the field, its focus and the round buttons gained a scene variant.
It is a minor release: five components gained an option, one surface is new, and no existing call site changed.

- `HelmField` 1.1.0 → 1.2.0 (minor): `Surface.scene(onDark:)` is a pill well floating over an illustration rather than sitting on a card. Its fill is the theme's light surface at low alpha, its text takes the colour that reads on the scene the caller names, and `applySunken` rounds it to a pill. The cell paints no fill of its own for it, which would show as a second, squarer band.
- `HelmCenteredSecureTextFieldCell` 1.0.0 → 1.1.0 (minor): `trailingAccessoryWidth` keeps room clear at the trailing edge for an accessory drawn inside the well, so typed dots never run under it.
- `HelmSecureTextField` 1.1.0 → 1.2.0 (minor): exposes the cell's `trailingAccessoryWidth`. The lock screen's and the Secrets gate's in-field arrows use it.
- `HelmInputSurface` 1.1.0 → 1.2.0 (minor): a focused scene well over a dark scene rings in the scene's own light rather than the accent, which read as a hole in a dusk sky.
- `HelmIconButton` 1.0.1 → 1.1.0 (minor): `Style.circle(side:fill:glyph:border:)` draws a solid round button for an action on a scene rather than a card, with a hover step, a halved disabled fill and an oval focus ring. `.plain` is the resting card action, as before.

- `Lock screen` none → 1.0.0 (new): L-2 Lighthouse. The locked state starts dark with the form transparent, inert and still first responder. Any key or a tap on the lighthouse lights the lamp, and a second tap dims it while the field is empty. The lens turns as render-server keyframes, the fog is a drifting noise texture, the Going Merry sails at 80% and the form sits 40pt higher in the C-4 Open sea style: a round avatar, a pill field and an arrow inside it. Reduce Motion, VoiceOver and every other state start lit.
- `Secrets (page)` 1.0.0 → 1.1.0 (minor): the unlock gate is S-1 Treasure chest with V-4 Open. While the chest is shut the page is dark and the form is not there. A key or a tap opens it (side by side from 900pt, stacked below), and the padlock reaches Touch ID even while it is shut. The create and unreadable states keep their card.

## 10.2.0 - Home, Tasks, Calendar and the Sticky Board, from the five-screen board

The captain's picks from the five-screen redesign board (`data/grandline-page-redesign-options/`): Hg-2 for Home, Tf-2 for Tasks, Cf-4 for Calendar and Sk-1 for the Sticky Board.
It is a minor release: two components gained an option, one is new, and no call site had to change.

- `HelmHeroCard` 2.0.0 → 2.1.0 (minor): `Content.greeting` draws the page's greeting in the display voice (`HelmType.heroTitle`) above the headline, which then drops to a 17pt second line. `Content.status` draws the day's verdict as a glass pill at the top right, its dot in the verdict's colour. The words wrap beside the pill, which never grows past 340pt. A card with neither draws as 2.0.0 did.
- `HelmHeroStatusPill` none → 1.0.0 (new): the hero's verdict pill. A dot and wrapping words on the tiles' own wash, with a hairline in the ink, as one static-text element for VoiceOver.
- `HelmButton` 1.3.0 → 1.4.0 (minor): `heroSelection` draws a hero ghost pill as the chosen one of a set, solid in the hero's ink with its label in the colour given (the hero's deeper stop). Tasks' Smart views and the calendar's filter menus use it.

- `Home (page)` 2.1.0 → 2.2.0 (minor): the greeting is the briefing hero's title and the day's verdict its pill (Hg-2). The date leads the hero's kicker. The greeting keeps its own row on the page when the briefing is not drawn as the hero.
- `Tasks board (page)` 1.2.0 → 1.3.0 (minor): the band is the page's filters (Tf-2). Its figures (All open, Due today, Overdue) pick the scope and Follow-ups jumps to its card, and Smart views and the project and sort menus are glass pills under a hairline. The filter row and the grey count line above the band are gone.
- `Calendar (page)` none → 1.0.0 (new): the month head carries the Tasks page's filters as three glass menus on its top edge (Cf-4), and its kicker says how many of the period's dates are a repeat rule's, not yet tasks. The caption line above the calendar is gone.
- `Sticky Board (page)` none → 1.0.0 (new): the case-file title is a typewritten case tag pinned to the cork, with a name the captain can rename and a meta line of stamp, counts and sync (Sk-1). The frame is 4pt instead of 7pt, the cork's corners are rounded and its grain is finer. A floating pill holds New note and a colour filter.

The sidebar layout's header line gains an opt-out: a page whose own hero says what its subtitle said (`WorkspaceHeaderLineCollapsing.drawsSubtitleOnHeaderLine`) leaves the line empty, and the empty line gives up its slot. Tasks and the Sticky Board use it.

## 10.1.0 - Home card polish and the Crew terminal prompt

Three fixes the captain asked for together (`fm/grandline-widget-polish`).
It is a minor release: a fixed card height gained a floor, and no call site moved.

- `HelmResponsiveGrid` 1.0.0 → 1.1.0 (minor): a `fixedHeight` item is never shorter than the cards tied beside it in its row. The saved height is a floor, not a ceiling: a card dragged taller still holds its height, and one dragged (or left) below its neighbours draws at their height. The floor sits on the tied cards' guide, so a taller fixed card does not pull its neighbours up. A row with no tied card has nothing to floor to.

- `Home Fleet card` 1.1.0 → 1.1.1 (patch): a stale watcher no longer dims the card to grey. Its counts are real, and the amber "Watcher stale" pill, the headline and the body already say they may be behind, so the card keeps the theme accent (or the captain's colour) like Claude and Hosts beside it. A fleet that was never read still dims (GL-14).
- `Home Claude card` 1.1.0 → 1.1.1 (patch): the card joins its row's height tie again, so by default it is as tall as Fleet and Hosts. It left the tie when its dense report was the tallest card on the row; as the split hero it is the shortest. The captain's own card was shorter for a second reason: a saved 264pt height beside 276pt neighbours, which `HelmResponsiveGrid` 1.1.0's floor now draws at the row's height. A failed refresh over a real reading keeps the card's colour, by the same rule as Fleet.

The Crew page's message input is now `HelmPromptWell`, the terminal-prompt composer Compose and SRE Lead use: a "❯" prompt, monospaced text in the terminal scheme's colours, a block cursor, and the send button on the prompt line. Return still sends and Shift-Return still adds a line.

## 10.0.0 - The Morning briefing hero as sentence tiles

The captain's pick from the briefing card board (`data/grandline-briefing-card/board/`): Br-3 with the H-b headline.
The hero's headline wrapped nowhere and was cut off with an ellipsis, and its words sat in a 560pt column that left the middle of a wide card empty.
It now leads with a headline that wraps across the whole card, and every briefing sentence is a tile labelled with the page it came from.
It is a major release because `HelmHeroCard.Content` lost its `body`, which the tiles replace.

- `HelmHeroCard` 1.0.2 → 2.0.0 (major): `Content.tiles` replaces `body`, and `Content.Ring` gains a `label` and a link. The headline and the kicker wrap and are never truncated. The 560pt `textMaxWidth` cap and the trailing 86pt ring are gone: tiles fill the width in balanced rows (`rows(count:width:)`), and the services figure is the last tile, with a 40pt ring. A tile's wash moves away from the ink, so text in a tile never reads worse than on the gradient. `onActivateTile` and `onActivateRing` report clicks.
- `HelmHeroTile` none → 1.0.0 (new): one fact in the hero, as a frosted well with a dot, a page kicker and the wrapped sentence, or a small ring before the words. A tile that points somewhere is a `HoverHighlightView` with a click, so it has the button role, the focus ring and the keyboard press.
- `HelmHeroTileGrid` none → 1.0.0 (new): lays the hero's tiles out in rows that each fill the width, every tile in a row as tall as the tallest, at a height derived from the width the card gives it.
- `Home (page)` 2.0.0 → 2.1.0 (minor): the Morning briefing hero leads with the AI's own short headline (a new optional `headline` on the stored briefing, with the first sentence as the fallback) over one tile per sentence, each opening its page. "Open Needs you" shows only when a crew task is waiting on a decision or blocked, not whenever the fleet verdict is amber (a failed PR scan made it amber with nothing needing the captain).

## 9.4.0 - Console fixes: a terminal-prompt composer and a one-line band

The captain's picks from the Console fixes board (`data/grandline-console-fixes/board/`): C1 for both composers and B2 for the band.
It is a minor release: one new component, and the Console page's own changes.

- `HelmPromptWell` none → 1.0.0 (new): C1. A text input drawn as a terminal prompt, in the terminal scheme's colours: an optional "~" hint line, a "❯" prompt, typed text in the scheme's green, and a block cursor it draws itself. The cursor shows the moment the field has focus, is hollow in a window that is not key, and stops blinking under Reduce Motion. The placeholder starts after the cursor. Focus lights the border and glow every other well uses. A caller adds a footer (Compose) or a trailing control (SRE Lead's send button).
- `HelmPromptTextView` none → 1.0.0 (new): the well's text view. It reports changes to its text and its selection, including a caller setting `string`.
- `Console (page)` 1.1.0 → 1.2.0 (minor): the Compose popover and SRE Lead's composer take `HelmPromptWell`, so neither hides its caret under its placeholder any more. The session band is one 40pt line (B2): where, and the live state in plain words, with the chips; it no longer shows the tab count or the shell and folder, and it no longer polls. The page gives up the empty header line, so the band sits 8pt under the window toolbar and the tab strip directly under the band. A tab added without being selected no longer draws its terminal over the selected one, which is what left the tab dot on Herdr while the captain typed in Shell.

## 9.3.0 - Compose, Claude usage and SRE Lead in the hero language

The picks from the console popovers board (`data/grand-line-console-popovers-sre-mockups/`): Comp-1, Use-1 and Sre-2.
The Compose popover, the Claude usage popover and the SRE Lead panel each open on the hero gradient, and both composers are raised wells.
It is a minor release: every kit change is an opt-in option or a fix, and nothing is removed.

- `HelmComposerCard` 1.0.0 → 1.1.0 (minor): `surface`, `.inset` by default and `.raised` for the card-coloured well with a hairline stepped toward ink. Both composers were the Lavender palette's `side` colour on a lavender panel.
- `HelmButton` 1.2.0 → 1.3.0 (minor): `surface`, which draws a `.secondary` button as the raised well. The Compose examples, its Copy and SRE Lead's question chips use it, so a chip beside a raised well is not a lavender pill.
- `HelmStatusPill` 1.0.0 → 1.1.0 (minor): `heroInk`, a ghost pill on a hero gradient (SRE Lead's status). The pill also holds its word at the width its cell draws it, rounded up: the label's intrinsic width sat a fraction under what the cell needs, and where layout rounds to whole points (a 1x display, an off-window render) "AHEAD" drew as "AHE…".
- `HelmRingGauge` 1.2.0 → 1.3.0 (minor): `showsDashedTrack`, for a window with no reading (GL-14). The Claude usage popover's rings use it.
- `Console (page)` 1.0.0 → 1.1.0 (minor): Comp-1 and Sre-2. Compose opens on a hero with a raised intent well, a fixed 420pt width with the command wrapping, a result card in the terminal scheme's colours with Copied feedback and the target tab named, a working card, and an error row with Try again. SRE Lead's header is a hero with the host and "read-only kubectl", a ghost status pill that says Working during a turn, and the postmortem button. The thread has question bubbles, one answer card with sections and a collapsing Finding, Copy on code and on the answer, Stop, Try again, and starter and follow-up chips above a pill composer.
- `Claude usage popover` none → 1.0.0 (new): Use-1. A hero with a ring per window, including the Fable week, a Refresh button, rows with a countdown and a pace pill coloured by the pace rather than the bar, a critical warning row and a Retry on failure.

## 9.2.0 - Console, Add Host and Add Key in the hero language

The picks from the Console / Add Host / Add Key board (`data/grand-line-console-addhost-mockups/`): the S1 hero style, Con-1, Host-1 and Key-1.
Console opens on a hero band for its session, and its terminal is a padded card on every page.
The host and key forms in the inspector open on a hero that previews the record, put each section on a card with raised wells, and report every validation problem inline.
It is a minor release: every kit change is an opt-in option, a new parameter or a fix, and nothing is removed.

- `HelmField` 1.0.0 → 1.1.0 (minor): `Surface`, with `.inset` (every form's well, unchanged) and `.raised`, the card's own colour with a hairline stepped 28% toward ink, lifted 5% in a dark register. `fill`, `border`, `ink`, `mutedInk` and `applySunken` take a surface. On the Lavender palette the inset well is `side` on a lavender panel and had no visible edge; the faintest raised edge across the 26 app themes measures 1.89:1 against its fill.
- `HelmFieldCentering` 1.0.0 → 1.1.0 (minor): field text sits `horizontalInset` (6pt) in from the well's edge on top of the cell's own 2pt, in every form. It started 2pt from the border before.
- `HelmTextField` 1.0.0 → 1.1.0 (minor): `wellSurface`, and `showsIssue`, which gives the well the critical hue's border until the form clears it.
- `HelmSecureTextField` 1.0.0 → 1.1.0 (minor): `wellSurface`.
- `HelmTextView` 1.0.0 → 1.1.0 (minor): `wellSurface`, and the well is a plain wrapper view around the scroll view. AppKit reset the edge set on the `NSScrollView`'s own layer, so every multi-line well drew no box in a real window.
- `HelmFieldCard` 1.0.0 → 1.1.0 (minor): `wellSurface`.
- `HelmToggleRow` 1.0.0 → 1.1.0 (minor): `wellSurface`.
- `HelmFormSheet` 1.0.0 → 1.1.0 (minor): `sectionStyle: .cards` puts each section and its rows on a card, `wellSurface` paints every field the form holds with one recipe, and `endSection()` and `adoptWells(in:)` go with them. The defaults draw exactly what the six editors drew before.
- `HelmInputSurface` 1.0.0 → 1.1.0 (minor): `fill(_:focused:surface:)` and `apply(...surface:)`.
- `Connections (page)` 1.0.0 → 1.1.0 (minor): Host-1 and Key-1. The host form opens on `RecordPreviewHeader`, the host's card on the hero updated as it is typed, with the name as the first Connection field, Environment as a segmented track and the SSH key as a list (`HostKeyPicker`) with each key's type, host count and Touch ID. Validation runs the same rules but shows every problem under its field and in the footer, with no beep and no modal. The key form asks first how the key is added (`KeyPathChoices`): generate, import, or a key pair already in ~/.ssh (`SSHKeyDirectoryScan`), which reads only `.pub` files until one is picked. Its public key preview takes its card's width; it was laid out zero points wide.
- `Console (page)` none → 1.0.0 (new): Con-1. Every Console page opens with `ConsoleSessionBand`: this Mac's shells with the tab and live-session counts and the current shell's name and folder, or a host page's environment, state, address and key, and a chip per live session with switch and end, plus Connect. It replaces the sidebar layout's SESSIONS strip; the floating bar keeps its strip. The shared console has the host page's margin and the terminal is a card on every page in every palette.

## 9.1.0 - Six colour palettes as app theme families

Six two-colour palettes join the seven app theme families, each with a light and a dark register, from the colour-options board (`data/grand-line-color-options/`).
They are Chart and Fathom (deep blue and warm creme), Porcelain and Port (black cherry and porcelain), Ice and Midnight (ice blue and midnight navy), Lavender and Powder (powder blue and lavender white), Pearl and Abyss (midnight teal and pearl), and Oat and Forest (oat milk and forest green).
Every classic family draws exactly what it drew before.
It is a minor release: two tokens and one option are added, and nothing is removed.

- `HelmHeroSurface` 1.1.0 → 1.2.0 (minor): `palette(for:)` draws from the theme's hero colour, `HelmTheme.heroAccentHex`. That is the register's pinned hero when it has one, otherwise the accent, so every classic register and terminal scheme gets the palette it always had. Fathom pins its heroes to Chart's deep blue `#07518A`, and Forest pins them to Oat's forest green `#1D4A35`. A dark register's accent has to be light to read as text, and the hero rule deepens a light colour by a third, which turned those two palettes' heroes grey.
- `HelmModuleCard` 1.4.0 → 1.5.0 (minor): a hero card's `.themeAccent` tone is the theme's hero colour, so Home's Claude, Fleet and Hosts cards, the hero columns and the split cards follow a pinned hero with the sidebar. A preset or a custom card colour is unchanged in every theme.
- `HelmDomainHue` 1.0.0 → 1.1.0 (minor): on one of the six palettes the blue hue resolves to the palette's accent, in `pair(in:)` and `identityHex(in:)`. Primary buttons (New Task, Add Host), a page's blue tile and every other place that asks for the app's blue take the palette instead of Daylight's `3D6BE8`. The classic families keep §2.2's pairs exactly.
- `Settings (page)` 1.0.0 → 1.1.0 (minor): Appearance's theme grid draws the seven classic families as before, then a PALETTES heading and the six palettes in the same tiles. A palette is selected, marked and named in the "is showing" line like any family, and Settings' search finds every palette and register by name. The welcome sheet's look step keeps the seven classics.
- `WorkspaceSidebar` 4.0.0 → 4.1.0 (minor): the sidebar's gradient follows the theme's hero colour, so Fathom's and Forest's sidebars are their pinned colour.
- `Tasks board (page)` 1.1.0 → 1.2.0 (minor): the Tasks band, the Backlog lane band and the Calendar's month head take the hero colour.
- `Setup (page)` 1.0.0 → 1.1.0 (minor): Setup's hero takes the hero colour in its accent tone. Its amber and red tones are unchanged.

## 9.0.0 - DevOps Hub as a page of project cards

The design picked on the second DevOps Hub board (`data/grand-line-devops-hub-page/`, layout A): the DevOps Hub row opens a page on Connections' pattern, and the projects are cards on it rather than rows in the sidebar.
No kit file changed.
It is a major release because the sidebar loses a row kind and the page's structure is replaced.

- `WorkspaceSidebar` 3.1.0 → 4.0.0 (major): the DevOps Hub row has no children. The project rows, their menu (`WorkspaceSidebarProjectAction`) and the session cell's project drawing are removed. The row keeps its badge exactly as before: a red dot for a failed start, an amber dot for a missing folder, a count of the projects serving, the scanning dash while one starts, and nothing while all are stopped. A click on a module row that is already lit now reaches the shell (`onReselectModule`), which DevOps Hub uses to go back to its cards.
- `DevOps Hub (page)` 1.0.0 → 2.0.0 (major): the page is two views. The project cards are a `HelmHeroColumn` in a `HelmSplitPage` pane (the verdict, a ring of projects running over projects registered, Running or Recent, an Add Project row, and Projects / Running / Attention at its foot), a filter row (search, All / Running / Attention, Grid / List) and the projects as `HelmCardGrid`'s roomy cards, each with Start or Stop, Open and Edit, or as a `HelmDataTable`. Below the collapse width the column becomes a band over the cards. Open shows the project inside the page: 1.0.0's project page, with a Projects button on its strip and over its hero card. The strip's Reload, Open in Browser and Restart keep only their glyphs below 820pt. The two views are places in the window's Back and Forward history.

## 8.1.0 - DevOps Hub, a local project served and shown in Grand Line

The design confirmed on the DevOps Hub board (`data/grand-line-devops-hub/`): a DevOps Hub row in Work with its local projects nested under it, and layout C for a project's page.
No kit file changed. It is a minor release because the page is a new surface and the sidebar gained a row kind.

- `WorkspaceSidebar` 3.0.0 → 3.1.0 (minor): DevOps Hub's projects are its children in the sidebar, drawn by the session row's own cell: a state dot (the ink at half strength while stopped, amber while starting, the good hue while serving, red when a start failed, a steady amber when the folder is missing), the name, and the port while it serves. The DevOps Hub row's badge is a red or amber dot for a failure or a missing folder, otherwise a quiet count of the projects serving, and nothing while all are stopped. A project row's menu starts, stops, restarts, opens in the browser, copies the address, opens Project Settings and shows the folder in Finder. A module row folded by hand stays folded across a rebuild. A module row with children no longer pushes its level's cells right by the disclosure's width: the chevron sits in the leading gutter, so a live session or a project never narrows the module names. DevOps Hub takes no ⌘ number, so Kubernetes keeps ⌘8 and Logs ⌘9.
- `DevOps Hub (page)` none → 1.0.0 (new): layout C. Whenever there is no site to show (not started, starting, failed, folder not found) the page is a centred `HelmHeroColumn` in `.panel` over a dimmed preview of the site's own share image, with a checks card under it that says what Start checks or checked. The panel is the accent, red when a start failed and amber when the folder is missing, with a ring while the site loads. Running, the hero is a 44pt strip on `HelmHeroSurface`: a state dot, the address as a copy button, the uptime and files served, and Reload, Open in Browser, Restart and Stop as the kit's ghost pills. The site fills the rest of the page in a web view.

## 8.0.0 - The whole sidebar as a hero column (Sb-4)

The captain's Sb-4 pick on the sidebar board: the app's own sidebar becomes the hero column Secrets (S-3) and Settings already wear.
It is a major release because the sidebar stops drawing the system's sidebar material.

- `HelmHeroColumn` 1.3.0 → 1.4.0 (minor): `NavInk`, a navigation row's colours on the gradient as values, from `navInk(for:in:)`. It carries the ink, the quiet ink, the rule, the hover, the selected pill's words, the appearance controls on the gradient take, a count's pill and a state mark lifted to read on the gradient or on the selected pill. It is for a list that draws its own rows, which the sidebar's `NSOutlineView` does. The column takes its nav rows' pill words from it, so `HelmHeroNavRow` paints exactly as before. A count's pill is a shade of the ink's opposite rather than the board's 22% wash of the ink, which put white digits at 3.5:1 on Dusk.
- `WorkspaceSidebar` 2.0.0 → 3.0.0 (major): Sb-4. The pane is the hero's gradient in the theme's accent, edge to edge and under the title bar, on a plain split item rather than the system's sidebar item, so it no longer draws the sidebar material (Liquid Glass on macOS 26). The account header sits in the ink with a translucent glyph tile. Group titles are small caps in the quiet ink with the group's row count, which steps aside for the disclosure chevron under the pointer. Rows keep the Large size, in the ink at a medium weight, with a hairline in the ink between two rows. The lit row is a pill in the ink with its words in the hero's deep colour, and the keyboard ring is drawn inside the pill in that colour. Badges are in the ink: a quiet count, a pill for a count that wants the captain, and dots and glyphs in their state hue lifted for the gradient. Live sessions still nest under Connections with their dots and ⌃⌘ chords. Context menus keep the theme's own appearance. It is still the `NSOutlineView` it was, so disclosure, keyboard navigation, context menus, VoiceOver and the collapsed state are unchanged. There is no strip of figures at the foot.

## 7.3.0 - Settings' split cards (Set-2)

The Settings pick on the second page-redesign board: every Settings page opens with a split card, built on 7.1.0's `HelmHeroSplitCard`.

- `HelmHeroColumn` 1.2.0 → 1.3.0 (minor): `Accessory`, a page's own view in a `.panel`'s ring slot with its caption centred under it in the quiet ink, passed to `configure(header:sections:foot:tone:accessory:)`. A ring wins when both are set, and `.band` and `.column` draw none. Settings › Appearance puts its theme family's preview there. A `.panel` now only bounds its content at the bottom and hugs it, so on a card taller than its words the pills stay under the words rather than sinking to the card's foot, and a stacked card's panel is its content's height.
- `Settings (page)` none → 1.0.0 (new): Set-2. In the sidebar layout each of the nine pages opens with a split card. The panel, in the theme's accent, says what the page has set now ("Dusk is showing.", "Locks after 15 minutes idle. Touch ID for sudo is on.", "Last export 12 Nov, 1.8 MB."), amber while the page needs attention (capture without Accessibility, a shortcut clash) and dimmed where the reading is absent (App Intents on a copy that publishes none). The card's own half holds the page's main rows, moved out of their sections rather than copied: Appearance, Window layout, Density and Profile on Appearance, with a preview of the theme family and Match macOS as the pill. A section left empty goes, and its foot follows the card. The column is allowed 900pt, and below 840pt the card stacks. The floating bar's Settings keeps its hero and its 680pt column.

## 7.2.0 - Setup as Sup-1: a full hero with boxed tiles on all four sub-pages

The captain's pick for Setup on the second page-redesign board: the five summary tiles on each of Setup's four sub-pages become one full hero with the sub-page's own verdict, the five figures as inset tiles, the setup-steps ring and the sub-page's actions as ghost pills.

- `HelmKPIStrip` 1.2.0 → 1.3.0 (minor): `heroInk` now also styles a `.boxed` strip, as the board's inset hero tiles. Each cell puts its figure over its caption in the ink, on a translucent shade of the ink's opposite instead of the card surface, with no border or resting shadow, at a 64pt height. A word figure ("Off", "In sync") is set at 17pt and a number at 26pt, and both still step down to fit. A quiet or unknown figure takes the ink at 72%. A tinted figure keeps its signal through `HelmHeroSurface.signalColor`, given the new `heroPalette`, because a boxed tile can be a fact about another page. A hero tile draws no detail line. Without `heroInk` a boxed strip is unchanged.
- `HelmDataTable` 1.0.0 → 1.0.1 (patch): a re-render keeps the hovered row. `setRows` used to drop the hover, so a page that re-rendered while the pointer rested on a row (Tasks' store reloading in the background) hid that row's ⋯ until the pointer moved. The table keeps the pointer's last position and finds the row under it again. Caught as a flake in CI on `SidebarRedesignsSelfTest`'s follow-up hover check.
- `Setup (page)` none → 1.0.0 (new): Sup-1. In the sidebar layout, Updates, Setup steps, Automation and GitHub sync each open with `SetupHeroRow` in place of the five-tile summary row: the kicker "Setup · This Mac", a verdict and a line that are the sub-page's own, the sub-page's actions as ghost pills that mirror its own controls (Check for updates; Run full setup and Refresh; Run Automation and Refresh; Sync All and Refresh), the same five figures as hero tiles, and an 86pt ring of the setup steps done. The gradient is the accent, amber while the sub-page's own subject needs attention and red when something failed, diverged or is paused, and it dims while the sub-page's own reading has not been taken. At 1060pt and over everything sits in one row, narrower the tiles go under the words, and under 560pt the ring steps out. The floating bar's Setup pages are unchanged.
- `GitHub sync (page)` 1.0.1 → 1.1.0 (minor): the page opens with Setup's hero, whose verdict states the forks (in sync, behind, diverged, partly read, not checked, or pushing paused) and names a fork carrying commits of its own.

## 7.1.0 - Dictation's split card (Dic-1)

The captain's Dictation pick on the second page-redesign board: the status beside the controls on one split card.
The split card's frame moves into the kit, since Automic Vault's S-1 card had drawn it as page code and Dictation is the second page to want it.

- `HelmHeroSplitCard` none → 1.0.0 (new): the split card. A `HelmHeroColumn` panel at the leading edge (470pt by default, held under 500 so it is never a floor on the window) beside a `detail` view on the card's own surface that the page fills, the card as tall as the taller half. Below `stackedBelow` (900pt by default) the panel goes across the top and the detail sits under it. `onStackedChange` tells a page when it switches. Automic Vault's card is now built on it, with a `.band` panel, and draws exactly as it did.
- `HelmHeroColumn` 1.1.0 → 1.2.0 (minor): `.panel`, the third layout and the split card's default. The words at the hero card's title size on the left with the foot's pills under them, and the hero's 86pt ring with its caption centred under it on the right, as `HelmModuleCard`'s wide `.heroSplit` panel draws it. Its body wraps to as many lines as it needs, and its pills keep their own width. `Ring.isDimmed` draws a ring in the quiet ink, for a reading that is absent rather than low.
- `Dictation (page)` none → 1.0.0 (new): Dic-1. A split card replaces the Status, Shortcut, Cleanup and Local Whisper Engine cards. The panel carries the verdict, the engine and the library in a line, the local model as the ring (a tick when ready, the percentage while it downloads, dimmed when it is absent or the engine is off), and Re-check permissions as its pill. While a permission is missing the panel is the theme's amber and the pill is Request Access. The card's own half holds the shortcut recorder with its reset, Clean up my sentences, Use local Whisper engine and the model row with its action and its menu, as Settings rows. Words I use often and Recent Dictations sit side by side under it, one above the other on a narrow page. The footnote under the page is gone: the kicker says On device and the cleanup row says what it sends.

## 7.0.0 - Home's band and the sidebar's search go; Tasks T-4, Secrets S-3 and a Hosts hero card

The captain's five changes in one release: Home loses the band between the briefing hero and the cards, the sidebar loses its search pill, Tasks and Secrets take their page-redesign picks (T-4 and S-3, with S-1's split card on Automic Vault), and Home's Hosts card becomes a hero card like Claude usage and Fleet.

- `HelmModuleCard` 1.3.0 → 1.4.0 (minor): `.heroList`, the full hero with a titled run of `HelmHeroRow`s under its words and ring, each row with its own ghost pill and handler (gotcha (20)'s arbitration keeps a pill's click off the card). Narrow stacks the headline and a small ring, the body, then the rows; standard puts the rows under the words and the 86pt ring; wide lays the words, the rows and the ring side by side. It paints with the quiet-ink palette, through `HeroTone.palette(in:quietInk:)`, so the rows' 80% second lines clear the text floor.
- `HelmHeroColumn` 1.0.0 → 1.1.0 (minor): `setRing(_:)` moves the header's ring in place, for a ring that counts down, without rebuilding the column. The kicker stays on one line (a long one in a band wrapped to two), and the ring's caption wraps at the room a narrowed column really has. A `HelmHeroNavRow` in a section takes the ink, with the stop furthest from it for a selected pill's words.
- `HelmHeroNavRow` none → 1.0.0 (new): a row the captain picks on a hero column - a glyph, a title and a count in the ink, the selected row a pill in the ink with its words in the hero's deep stop. A `HoverHighlightView`, so it is a button to VoiceOver and the keyboard; a press runs `onSelect` with the row's id and the page decides what is selected.
- `Home (page)` 1.0.1 → 2.0.0 (major): in the sidebar layout, the band between the Morning briefing hero and the cards is removed - the four KPI tiles (Tasks due today, PRs ready to merge, Services healthy, Claude week) and the Needs attention card with its Refresh and its "Everything else is clear" footer. The cards start one grid gap under the hero. The floating bar's hub keeps its attention card as column 1.
- `Home Hosts card` none → 1.0.0 (new): the Hosts card as a `.heroList` hero card - the live-session verdict, the ring of saved hosts online, and the three hosts connected last (the saved hosts before anything was connected), each with Switch for a live session or Connect. It takes the Claude and Fleet cards' palette menu: narrow, default and full width, a colour, and Hide from Home. The floating bar's fitted hub keeps its rows.
- `WorkspaceSidebar` 1.0.0 → 2.0.0 (major): the "Search or jump to" pill is removed, since the toolbar's Search and ⌘K are on every page. An 8pt gap separates the account header from Home.
- `Tasks board (page)` 1.0.2 → 1.1.0 (minor): T-4. A slim hero band over the filter row on Board and List (the kicker and the day's verdict, Due today / Overdue / Follow-ups / Done in 7 days inline, and a small ring of the week's done work), whose figures and then ring step out on a narrow page. Each lane is a card whose header is a toned band - the accent for Backlog, slate for In Progress, the theme's green for Done and its amber for Follow-ups - with the count as a big number, a detail line and a ghost "+" that adds to that lane. The floating bar's board is unchanged.
- `Secrets (page)` none → 1.0.0 (new): S-3. In the sidebar layout the Kinds and Collections column is a hero column in the split's sidebar pane: the vault's state, the auto-lock countdown ring (from the page's own idle clock, moved in place every second), the same rows with their search-scoped counts in the ink, the selected one a pill, and Lock now at its foot. The table takes the rest of the page, and on a narrow page the column narrows toward 228pt before the table loses its 2FA codes or row controls.
- `Automic Vault (page)` none → 1.0.0 (new): S-1's split card, which the captain kept for this tab. The launchers' verdict and a ring of how many are hardened on a gradient, amber while a launcher needs attention, with View Fix on the gradient for one launcher; the verified launchers as rows beside it, each with its state and its own View Fix. Below a 900pt card the gradient goes across the top. It stands in for the attention banner and the Verified Launchers table in the sidebar layout; the floating bar is unchanged.

## 6.8.0 - Hero columns: Health (H-4) and Connections (C-4)

The captain's picks on the page-redesign board: Health's verdict, ring and buckets, and Connections' session verdict, recent hosts and Quick connect, each in a hero column beside the page's content.

- `HelmHeroColumn` none → 1.0.0 (new): the hero's gradient as a page's column. A header (kicker, headline, body, ring), titled sections of rows, and a foot pushed to the column's bottom, all in the hero's ink. It hands the ink to the `HelmButton`, `HelmSearchField` and `HelmKPIStrip` put on it. `.column` scrolls inside the gradient when the window is short, so it is never a floor on the window's height. `.band` lays the same header and foot across the top of a narrow page. It paints with `HelmHeroSurface.palette(accent:quietInk:)`, so 80% ink clears the text floor too.
- `HelmHeroRow` none → 1.0.0 (new): one row on the gradient. A big rounded figure (a quiet one for a zero) or a translucent glyph tile, a title, a second line in 80% ink and an optional trailing control, with an ink hairline above it when it follows another row.
- `HelmHeroSurface` 1.0.0 → 1.1.0 (minor): `palette(accent:quietInk:)`, the palette rule deepened until white at a lower alpha also clears the text floor on the lighter stop. The plain rule stops at the floor for white, so 80% white measured 3.41:1 on it.
- `HelmButton` 1.1.0 → 1.2.0 (minor): `heroInk`, a ghost pill on a hero gradient. The border is the ink at 38% and the label the ink. The fill is a translucent shade of the ink's opposite (`heroShade`), 16% at rest, deeper on hover and press, because a frosted wash of the ink itself lifts the backdrop toward the label (a pressed 28% white wash measured 2.73:1 on Rosé Pine).
- `HelmSearchField` 1.0.0 → 1.1.0 (minor): `heroInk`, a field on a hero gradient (the same shade under its well, an ink hairline, a 2pt ink ring on focus in place of the accent lamp), and a `symbol` init option for the well's glyph.
- `HelmCardGrid` 1.0.0 → 1.1.0 (minor): `init(cardHeight:minimumCardWidth:maximumColumns:)`, so a grid can take C-1's roomy card (`roomyCardHeight` 98, `roomyMinimumCardWidth` 280) and a column cap, and an instance `plan(width:)` that honours both.
- `HelmGridCardView` 1.1.0 → 1.2.0 (minor): the icon buttons stand in a column of their own at the trailing edge, centred, and every line of text stops before it, where only the title did and a long address ran under the bolt and the pencil. The tile is the Daylight `HelmGradientTile`, in a host's own colour where it has one, and the card's content is centred on its height.
- `HelmSplitPage` 1.1.0 → 1.2.0 (minor): `collapsesBelowWidth` puts the sidebar away on a page narrower than that and brings it back when there is room, without forgetting the captain's Toggle Sidebar. `pin(_:insets:yieldsWidth:)` holds a column's trailing edge at 490 and a pane minimum of `yieldingMinimumThickness`, so the content's floor moves the divider rather than the window. `preferredSidebarWidth` is the width the column comes back at, and a column with one has no drag. `floorWidth(of:)` is the narrowest a view can be before its constraints would hold the window open, which is what a page adds to its column for `collapsesBelowWidth`. `onNarrowChanged` fires before the divider moves.
- `Health (page)` none → 1.0.0 (new): H-4. The page is a `HelmSplitPage`. The hero column (verdict, healthy ring, Healthy / Recent failure / Failing / Not run yet with the services in each, and Retry and Diagnostics pills while something needs attention) is its sidebar, the theme's accent and red while a service fails, dimmed before anything reports. The table starts at the top of the page beside it, and the summary cards over it are gone. On a page too narrow for the column and a table that keeps every column (1153pt), or with the column hidden, the same column is a band over the table.
- `Connections (page)` none → 1.0.0 (new): C-4. The split's sidebar pane holds a hero column in the sidebar layout: the session verdict and the online ring, the three hosts connected last with Switch or Connect pills, a Quick connect field, and Keys, Snippets and Groups at its foot. The host cards are C-1's 98pt card, two to a row. Recent leaves the grid while the column shows and returns above All hosts when the column is put away (the inspector opening, a narrow window, Toggle Sidebar), and H3's Connect button steps aside beside the column, whose field takes a typed user@host. The floating bar's page is unchanged.

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

Thirteen pages moved onto the scaffold and dropped their private scroll setups and top constants: Health, Tools, Updates, Bootstrap, Automation, GitHub sync, Dictation, Review, Overview, Vault, Logs, Schedules and Commands. Home, Tasks and Calendar, Connections, Settings, Kubernetes, Runbooks, Postmortems, Crew, Whiteboard, Sticky Board, Notebook, Reading list, Docs and Secrets keep their own layouts (split panes, web islands, a board, a canvas) and take the line through the token or `pinFirstContent`. Console's session strip is that module's first content and sits on the line. The first content moved from ten heights between 76pt and 117pt to 96pt on every page (`MainSplitShellPanesSelfTest.checkEveryPageStartsAtOneHeight`).

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
