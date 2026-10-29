# Navigation: the rail, the Daylight bar, the window chrome

> Feature history, relocated out of `AGENTS.md` by P1 of full review #3.
> **This file is not imported into an agent session.** Read it when you are
> about to touch this area; the standing rules that apply everywhere live in
> the repository root `AGENTS.md`.
>
> Content below is verbatim from the `AGENTS.md` this was split out of. It is a
> record of what shipped, what was tried, and what replaced it - entries are in
> the order they were written, so a later one can correct an earlier one.

- **Navigation shell.** `AppShellController` is the window's root: a fixed, always-visible `IconRailController` (84pt, labeled+sectioned - see the dedicated bullet below) on the left, and to its right a `TopBarController` (destination title, the Search pill with its ⌘K badge, and the theme-picker button) above a body area. `RailDestination`'s case order (`IconRailController.swift`) drives the rail's top-to-bottom icon order directly - since Swift derives `CaseIterable.allCases` from declaration order, reordering the destinations is a one-line change there (currently `overview, console, hosts, review, settings`, below the sailboat "Home" mark and above the avatar - captain-corrected in cockpit-native-theme-audit-review, overriding fixes4 Fix 2's console/hosts-first order). The body holds all five destinations (`.overview`, `.hosts`, `.console`, `.review`, `.settings`) as permanent children with only `isHidden` toggled - never rebuilt - so navigating away never tears down `ConsoleController`'s running tabs. **`.hosts` and `.console` are decoupled destinations** (cockpit-native-ui-fixes2): `HostsController` and `ConsoleController` are each a standalone full-size body view, not panes of a shared `NSSplitViewController` - Console shows just the Firstmate Shell/Mirror tab strip, and Hosts is reachable on its own rail icon exactly like Settings. Connecting the pinned Firstmate entry (`HostsController.onConnectPinned`, wired in `main.swift`) opens its Shell/Mirror pair in the shared `ConsoleController` and calls `AppShellController.show(.console)`. Connecting a *saved* host goes through a sixth kind of destination outside the `RailDestination` enum entirely - see "Dedicated host pages" below. `.overview` shows `FleetController` (see below); `.review` shows `ReviewController` (cockpit-native-theme-audit-review): the same PR data/actions as Overview's "Ready to merge" (`OpenPRsSource.fetch()` + `FleetDataSource.mergedPRs`), grouped by forge instead of merged into one list; `.settings` shows `SettingsController` embedded directly (not a separate window).
- **`fm/grandline-sidebar-labeled-nav` redesigned the rail from icon-only to a Slack-inspired labeled/sectioned nav**, per a captain-approved Lavish design plan. `IconRailController.width` is 84pt (up from 60pt). The per-host icon block sits between two `NSBox(.separator)` hairline dividers with a small muted "HOSTS" label above it (`hostsSectionLabel`/`dividerAboveHosts`/`dividerBelowHosts`) so it reads as a visually distinct section - kept visible even with zero saved hosts, so an empty state still shows "here's where hosts go" rather than the utility group shifting up.
- **`fm/grandline-sidebar-badges` added "needs you" count badges to the rail.** `IconRailController.attachBadge(to:dest:)` overlays a small pill on every rail button's top-trailing corner - attached generically in `railButton(for:)` regardless of which visual shape that builder produces for a given row (originally two different shapes, unified into one by `fm/grandline-sidebar-nav-polish` below; the badge overlay needed no changes either time since it always positions off the button's own bounds); `setBadgeCount(_:for:)` is the only mutator and hides the badge outright whenever `count <= 0`, per `PRODUCT.md`'s "quiet until it matters." The badge is a fixed white-on-`.systemRed` pill, deliberately not a `HelmTint`-derived color - it's meant to read as an alert the same way regardless of which of the 12 Helm themes is active, matching how macOS itself never re-tints a Dock badge or Mail's unread count. Two destinations wire real counts today, both from data already computed elsewhere, never invented for this badge: `.review` gets `ReviewController`'s own `mergedPRs.count` (the same open-PR list the page renders, via a new `onOpenPRCountChanged` callback fired from `render`), and `.overview` gets `FleetController`'s own `needs_decision`/`blocked` task count (the same set its banner already text-summarizes as "N tasks need your call", via `onNeedsDecisionCountChanged`) - not `.hosts` or `.console`, since neither destination actually shows that signal. `AppShellController` wires both callbacks straight to `rail.setBadgeCount` and calls each controller's new `refreshIfNeeded()` once at launch (a public wrapper around each controller's existing private `refresh()`) so the badges have a real count before the captain ever visits either destination - no new poll loop was added; live updates otherwise ride the same triggers those two pages already had (page visit's `viewWillAppear`, the manual refresh button, a merge action's post-merge `refresh()`). Verified live (not `swift build` alone, per this file's "Verifying native UI bugs" convention): a temporary env-gated probe in `main.swift` + a temporary `IconRailController.debugBadgeState(for:)` (both reverted before commit) dumped real badge geometry/visibility after a real launch - `.review` showed a real nonzero count (this machine's actual open PRs) while `.overview` stayed hidden (no task genuinely needed a decision at the time) - then drove a synthetic nonzero→zero cycle confirming show/hide, and swept `helm-dark`↔`helm-light` confirming the badge's red fill is unaffected by the theme swap.
- **`fm/grandline-sidebar-nav-polish` (follow-up, live captain screenshots) made every row in the rail labeled and fixed a centering bug.** `railButton(for:)` is now the single builder for every `RailDestination` (daily-use and utility alike) - the old branch that gave utility destinations (Tools, Vault, Docs, Updates, Bootstrap, Settings) a compact icon-only style is gone, and `hostRailButton(for:)` picked up the same icon-over-label treatment so pinned hosts show a name too. `RailDestination.isDailyUse` still exists, but only to decide `navStack` membership (top block vs. bottom-anchored utility group) - it no longer selects a different visual style. **Root cause of the off-center active-highlight bug**: `NSButton.attributedTitle` lays out text using the attributed string's own paragraph alignment, not the button's `alignment` property - `restyle(_:)`'s `attributedTitle` construction had no `.paragraphStyle` attribute at all, so it defaulted to natural/left, which then also dragged `imagePosition = .imageAbove`'s icon left (the cell centers the image over the title's actual left-aligned glyph run, not the full button width). Fixed with a shared `attributedRowTitle(_:color:)` helper carrying a centered `NSParagraphStyle` - any future code building an `attributedTitle` on an `imageAbove` button needs the same explicit center alignment, or this class of bug recurs. `attachBadge`'s positioning (previous bullet) needed no change here since it anchors off `button`'s own bounds, not a hardcoded size - it still lands correctly now that every row shares this one labeled shape. Also added a hairline divider (`dividerAboveNav`) between the logo mark and the first daily-use row, matching the existing `dividerAboveHosts`/`dividerBelowHosts` style, per captain request in the same pass. Verified live via a temporary env-gated probe (reverted before commit, per this file's "Verifying native UI bugs" convention below) reading real `NSButtonCell.titleRect(forBounds:)`/`imageRect(forBounds:)` against real button bounds - confirming title/image/bounds center-X all match for every row type (daily-use, utility, host) - plus real host-label text, badge attachment on a labeled utility row, and divider frames, swept across `helm-dark`/`helm-light`.
- **`fm/grandline-rail-followup-fixes` (follow-up, live captain screenshots) found `fm/grandline-sidebar-nav-polish`'s own "fixed and verified" centering claim was incomplete, fixed the badge/Shift/separator issues from the same screenshot round.** **Centering, re-derived from scratch**: the paragraph-style fix above is real and correct for horizontal centering (re-confirmed live), but a real rendered bitmap of an *actually active* row (not just constraint math) showed a second, vertical bug that fix never touched - `NSButtonCell`'s stock `.imageAbove` layout does not vertically center the image+title block in the cell's actual resolved bounds, anchoring it near a fixed low offset instead, so 100% of any extra height the button resolves to beyond its own internal "ideal" size (confirmed live: every row resolves several points taller than its explicit `heightAnchor` constant, an unrelated `NSButtonCell` quirk) lands as dead space above the icon - invisible on an inactive row with no background to reveal it, obvious on the active row's tinted highlight. Fixed with `CenteredImageAboveButtonCell`, a small `NSButtonCell` subclass (bottom of `IconRailController.swift`) overriding `imageRect`/`titleRect` to explicitly center the image-above-title block itself, both axes, in whatever bounds the button actually has - `railButton(for:)`/`hostRailButton(for:)` both assign it in place of the default cell. No amount of `.paragraphStyle`/`alignment` tuning could have fixed this, since both only affect the glyph run within a rect the stock cell had already decided on. **Badge overflow**: `setBadgeCount` now shrinks the badge (8pt font, tighter 3pt label insets, pulled 2pt further in from the button's corner instead of 4pt) specifically once the count renders as 2+ characters (10-99, "99+") - a single-digit count keeps the original sizing untouched, per a captain screenshot showing "12" overflowing past its icon. **Shift → Tasks**: every user-facing "Shift" string now reads "Tasks" - `RailDestination.title`, the topbar destination title (`AppShellController.show`), the main menu bar's "Shift" menu and its "Search Shift…" item, and `ShiftMenuBarController`'s status-item tooltip + its popover header. Internal type/file names (`ShiftController`, `ShiftStore`, etc.) are deliberately untouched - this was a label-only rename. The menu bar status item's icon also changed from `arrow.triangle.2.circlepath` (a refresh glyph, unrelated to what the item does) to `sailboat` - the same symbol as the rail's own logo mark - since a standalone menu bar item has no nearby app branding of its own. The rail's `.shift` row deliberately keeps `checkmark.circle` rather than also switching to `sailboat`: unlike the standalone menu bar item, the rail already shows the real sailboat logo mark a few rows above this one, and a second sailboat there would read as a duplicate icon, not a clearer one. **Daily-use separators**: a hairline `NSBox(.separator)` now sits between each daily-use row (Overview | Console | Hosts | Tasks | Review) inside `navStack`, width-pinned to `navStack.widthAnchor` with a small inset - scoped to that group only, per the captain's ask; the per-host block and the utility group are unaffected. **Verified live** (not just `swift build`, per this file's "Verifying native UI bugs" convention below): a temporary probe rendered the real `IconRailController` to an off-screen bitmap via `NSView.bitmapImageRepForCachingDisplay`/`cacheDisplay(in:to:)` (no Screen Recording/Accessibility permission needed - this draws the view's own layer, it doesn't capture the screen) on an actually-active row, confirming equal top/bottom gaps around the icon+label block before vs. after the cell fix, the double-digit badge sitting fully within its icon's corner instead of overflowing, "Tasks" rendering in place of "Shift", and a divider between every daily-use row - swept across `helm-dark` and `helm-light`, reverted before commit.
- **`fm/grandline-rail-utility-separators` (follow-up) extended the daily-use group's hairline separators to the utility group (Tools | Vault | Docs | Updates | Bootstrap | Settings) for visual consistency, per captain feedback after seeing the daily-use dividers built.** The utility rows are not built as an `NSStackView` (unlike `navStack`) - they're individually positioned `NSButton`s anchored in a bottom-up chain (`settingsButton.bottomAnchor` off `avatar.topAnchor`, each button above it chained the same way) so the per-host block above can grow/shrink freely. A stack-based divider (`navStack`'s arranged-subview approach) doesn't apply here, so each of the 5 separators is a plain sibling `NSBox(.separator)` spliced into that same bottom-up anchor chain (`dividerXY.bottomAnchor` off the button below it, the next button's `bottomAnchor` off the divider's `topAnchor`), sized/centered to match the daily-use dividers' width formula (`Self.width - 28`, centered on `root`). Verified live via a temporary env-gated probe in `main.swift` (reverted before commit, per this file's "Verifying native UI bugs" convention below) rendering the real `IconRailController` off-screen and dumping every `NSBox(.separator)` subview's frame - confirmed all 5 utility dividers render with non-zero, evenly-spaced frames in both `helm-dark` and `helm-light`, with no change to the daily-use group's or per-host block's own dividers.
- **Per-host pinned rail icons (fixes4 Fix 3).** Below the fixed destinations, `IconRailController.setHosts(_:)` renders one extra icon per saved host (its own icon glyph + accent, tooltip = label; click connects via `onConnectHost` exactly like the Hosts list's Connect). Kept live by `HostStore.observe(_:)` - a list of closures (not a single overwritable `onChange`, since both `HostsController.reload()` and the rail's `setHosts` need to hear every add/rename/delete) - `main.swift` registers the rail's observer alongside the Hosts panel's own.
- **Dedicated host pages (cockpit-native-host-pages).** A saved host's rail icon (or the Hosts list's own Connect - both call `AppDelegate.connectToHost`, so there is one connect path for a saved host, not two) opens its **own** page: an independent `ConsoleController` holding only that host's ssh tab(s), never the Firstmate console's Mirror/Shell tabs. `AppShellController.connectHost(_:args:)` builds one lazily per host id via an injected `makeHostConsole` factory (so `AppShellController` stays ignorant of `SSHKeyStore`/`SnippetStore`, matching how it already knows nothing about host persistence), embeds it into the shared body container exactly like a fixed `RailDestination`, and keeps it in a `[UUID: ConsoleController]` dictionary for as long as that host stays saved. The dedup fix for the "second click opens a second tab" bug: `ConsoleController.connectSSHIfNeeded` only calls `openSSH` when `tabs.isEmpty`, so a re-click of an already-connected host's icon just re-shows and re-focuses (`focusCurrentTab()`) the existing page - a deliberate second session still needs the tab chip's own right-click Duplicate. `ConsoleController(opensFirstmateOnLaunch:)` is `false` for these (the shared Firstmate `console` keeps it `true`, its Shell/Mirror pair unchanged). Deleting a host (`HostStore.observe` diffing ids in `main.swift`) tears its page down via `AppShellController.removeHostConsole` (`ConsoleController.shutdown()` + `removeFromSuperview`/`removeFromParent()`), and `applicationWillTerminate` shuts every host console down too (`AppShellController.shutdownAllHostConsoles()`), not just the shared one. None of this is a `RailDestination` case - `IconRailController.activeHostID`/`AppShellController.connectHost` track "a host page is showing" as a separate piece of state from the fixed-destination enum, mirrored on both sides so rail highlighting and body-view switching agree. Zoom (the Console toolbar's own zoom buttons, wired with no explicit `.target`) still resolves correctly per page because each host's `ConsoleController` is a real `addChild` in the responder chain - whichever page's terminal is first responder is what the action reaches, exactly like the Firstmate console already worked. (The Tab menu this originally also covered - `⌘T`/`⌘D`/`⌘W` - is gone now, `fm/grandline-console-tabs-restore-tabmenu-fix`, see "## Menu bar"; those three actions are tab-strip-only per page today, same as everywhere else.)

## Menu bar

- **`fm/grandline-console-tabs-restore-tabmenu-fix` reverted a prior PR ("Remove menu bar clutter, Log Analyzer, Snippets, and collapse Console to one session per window") almost entirely, and redid only the one narrow, still-wanted piece of it differently.** That PR had squashed four things into one commit: (1) removed View/Window/Help; (2) removed the Tab menu's numbered "Select Tab N" items and separately deleted the Snippets feature outright; (3) deleted the Log Analyzer feature outright (keeping only Incident mode's own non-Log-Analyzer attach points, per the captain's instruction at the time); (4) collapsed `ConsoleController` from a dynamic multi-tab collection down to at most one session per window (`TabModel`/`TabChipView` → `ConsoleSession.swift`, one-shot provisioning commands moved from a temporary Console tab to a standalone `ConsoleCommandRunnerWindowController.swift`). The captain's actual, final scope turned out to be: keep (1), fully revert (2)/(3)/(4), and separately hide only the Tab **menu item** (not its capability) - a distinct, narrower ask from what that PR did to Tab. The revert was a single clean `git revert` of the squash commit (it was `main`'s tip, no conflicts) - Log Analyzer (see the dedicated "## Log Analyzer" section), Snippets (the Hosts page's Snippets tab, the Snippets menu, `Host.startupSnippetID`, the backup bundle's `snippets` field), and Console's dynamic multi-tab architecture (`TabModel`/`TabChipView`, described in the Console bullet near the top of "## Native app") are all back exactly as they were before that PR - the revert restored both the code and this file's own prior description of all three in one motion, so none of that documentation needed rewriting beyond what's below.
- **View/Window/Help are removed again, freshly - the same removal, redone, not a new decision.** Standard-system-provided menus that never fit this app: View's `⌘1`-`⌘5` space shortcuts and light/dark toggle duplicated `DaylightBarController`'s own pills/button, its zoom items duplicated the Console toolbar's zoom buttons and Settings' font-size presets; Window's minimize/zoom is native title-bar chrome independent of any menu; Help pointed at two repo docs with no other entry point. Removing them drops `AppShellController`'s `selectSpaceByShortcut(_:)`/`toggleTheme()` (the `NSMenuItem`-shaped wrappers only - `selectSpace(_:)` and `ThemeManager.shared.toggle()` themselves are unaffected, still called directly by `DaylightBarController`'s own space pills and theme-toggle button, per `fm/grandline-daylight-theme-toggle-relocate` below) and `AppDelegate`'s now-callerless `openRepoDoc`/`openSetupGuide`/`openReadme`.
- **The Tab top-level menu is gone from the menu bar too, but this is a genuinely different, narrower removal from what the reverted PR did to it - it removes the *menu item only*, never the capability.** Every action the Tab menu offered is still fully reachable from `TabChipView`'s own UI: the "+" button for New, double-click for Rename, right-click for Rename/Duplicate/Close/**Reconnect** (the tab strip's own new equivalent to the removed ⌘R, added specifically for this: `TabChipView.onReconnect`, wired by `ConsoleController.addTab` to `select(tabID:)` + `reconnectActive()` - exactly what ⌘R used to do; `ToolsController`'s own tab strip leaves it `nil` since its tool tabs have no connection to restart, so its right-click menu simply omits the item), and clicking a chip directly for jump-to-tab-N. What's genuinely lost, and cannot be recovered short of a parallel `NSEvent`-monitor mechanism this fix deliberately didn't build (AppKit's key-equivalent handling only walks items that are part of `NSApp.mainMenu`'s tree - hiding a top-level item via `isHidden` excludes its whole submenu from that walk exactly like never adding it does, there is no "in the tree but invisible in the bar" middle ground): ⌘T (new tab), ⌘D (duplicate), ⇧⌘R (rename), ⌘W (close), ⌘R (reconnect), ⌘1-⌘9 (jump to tab N). Same captain-accepted trade-off as ⌘M silently doing nothing once Window went above - called out explicitly here rather than silently dropped. Two existing shortcuts that were deliberately kept off the newly-freed ⇧⌘R/⌘1-⌘9, since an already-shipped shortcut isn't this fix's to relitigate: Log Analyzer's "Create RCA" stays on **⌘⇧A** (moved there originally only because the Tab menu's "Rename Tab…" owned ⇧⌘R first - see "## Log Analyzer"), and the session switcher stays on **⌘⌃1…9** rather than reclaiming the now-free `⌘1…9` (see "## Session switcher").
- **`ToolsController`'s own, separate multi-instance tab strip is completely unaffected by any of this** - it never had its own top-level menu, and its "+" button plus its tab chips' double-click/right-click were always direct closures, never routed through the (now-gone) shared Tab menu. The two controllers still share matching selector names (`newShellTab`/`duplicateCurrentTab`/`renameCurrentTab`/`closeCurrentTab`) - a harmless holdover from when the Tab menu's nil-target items dispatched through the first-responder chain to whichever controller had focus, kept as-is (renaming would be pure churn, and self-tests already call these methods directly by name) even though nothing routes through a menu to reach them anymore.
- **This removal likely also closes, or substantially narrows, the notch-gap symptom documented in the next bullet** - top-level menu count dropped from the 11 that bullet measured (App, Edit, Hosts, Tasks, Log Analyzer, Keys, Snippets, Tab, View, Window, Help) to 7 (App, Edit, Hosts, Tasks, Log Analyzer, Keys, Snippets). **Not independently re-measured live in this sandbox** (no Screen Recording/Accessibility permission here, and no reason to disturb the captain's own running instance just to check) - treat this as a likely side effect worth confirming the next time that gap is looked at, not a verified fix.

- **The "large gap before View/Window/Help" symptom (captain screenshot, `fm/grandline-menubar-gap-fix` investigation) is a physical camera-notch dead-zone on notched MacBook displays, not a construction bug in `AppDelegate.buildMenu()` - read this before touching that function again, and before assuming any future menu-bar "gap" report is a code defect. Historical: written when View/Window/Help/Tab were still real top-level menus (11 total) - see the bullets above for their current, reduced state.** `buildMenu()`'s top-level item array was read line-by-line and is correct: 11 contiguous `mainMenu.addItem(...)` calls (App, Edit, Hosts, Tasks, Log Analyzer, Keys, Snippets, Tab, View, Window, Help), no stray placeholder item, no hardcoded index, `NSApp.windowsMenu`/`.helpMenu`/`.servicesMenu` assigned only once each. A headless self-test-shaped probe (`AppDelegate()` + `buildMenu()`, exited before `SingleInstanceGuard`/`app.run()` - the same safe pattern every `FM_RUN_*_TESTS` block already uses) confirmed the array itself has no anomaly. The real cause was found by querying the **captain's own already-running instance** live via the Accessibility API (`osascript`/System Events - read-only, no relaunch, no risk to the running process, and the only way to measure real on-screen menu-bar geometry in this sandbox, which has no Screen Recording permission per this file's own "Verifying native UI bugs" convention): `Edit`→`Tab` are all perfectly contiguous (zero gap between any adjacent pair), then `Tab` ends at x=656pt and `View` starts at x=855pt - a real, reproducible 199pt gap, and nothing else. **Confirmed via `NSScreen.auxiliaryTopLeftArea`/`.auxiliaryTopRightArea`** (Apple's own public notch-avoidance geometry API, macOS 12+): on this exact hardware (`Mac17,9`, a notched MacBook Pro, screen 1512x982pt at 2x Retina) the left-safe menu-bar region is `x∈[0,663]` and the right-safe region starts at `x=848` - i.e. the display has a real, unusable pixel gap at `x∈[663,848]` (~185pt) that NO app can draw into, regardless of code. Reproduced the **identical** split (same ~200pt gap, same right-edge position ±8pt) in a totally unrelated, from-scratch throwaway macOS app (different process, different bundle, zero Grand Line code) built purely to test this - confirming it is generic AppKit/WindowServer behavior on this hardware, not anything specific to this app's menu-construction code. Also confirmed empirically that `NSApp.windowsMenu`/`.helpMenu` assignment order relative to `NSApp.mainMenu =` has **zero** effect on the gap (removing those two assignments entirely still reproduces the identical gap) - ruling out the most plausible-looking "ordering bug" theory before accepting the notch explanation. **The mechanism**: macOS does not adaptively squeeze/wrap menu-bar content around the notch - it lays out top-level items left-to-right until the running total would intrude into `[663,848]`, then relocates *everything from that point on* to start flush at the right-safe region's left edge (`~848`+padding), leaving a gap sized `(848 - where the left run naturally ended)`. This is an all-or-nothing relocation per item, not a per-pixel squeeze, confirmed by testing minimal reproductions where the left run ended anywhere from x=596 to x=650 (the right run always started at the same ~x=856 regardless). **Why this app crossed the threshold and (as far as this investigation could tell) always would, without a menu-content change**: total top-level menu-bar width in this app's current `buildMenu()` is ~840pt (App+Edit+Hosts+Tasks+Log Analyzer+Keys+Snippets+Tab+View+Window+Help), which exceeds the 663pt pre-notch budget by ~177pt - accumulated gradually as Hosts/Tasks("Shift")/Log Analyzer/Keys/Snippets/Tab were each added as their own top-level menu across many separate PRs (see this file's own feature-by-feature history above), with nobody hitting the ~663pt threshold until now. **No positioning-only code change (menu order, `NSMenuItem`/`NSMenu` construction, assignment ordering) can close this gap while keeping the current set of 11 top-level menus and their current titles** - the only way to bring total width under 663pt is a genuine content/structure change (e.g. folding Keys and Snippets - which already share one destination in the UI, per Phase 5 of the full-app UI audit above - as submenus under Hosts instead of separate top-level menus, and/or shortening long titles like "Log Analyzer"), which is a product decision, not an implementation one. If a future task is asked to "fix the menu bar gap" again, this is not new information to rediscover - it is a decision to make (accept it as a cosmetic hardware limit, or approve consolidating/shortening specific top-level menus) before any code should change.

## Rail navigation

- **`fm/grandline-rail-setup-group` merged the standalone "Updates" and "Bootstrap" rail icons into one "Setup" entry** (pinned where "Updates" used to be, directly above `.docs`), after a captain-approved discussion that they're both environment/dependency-setup concerns distinct from Settings' app preferences (Settings stayed untouched, its own separate icon). `.updates`/`.bootstrap` remain real `RailDestination` cases with unchanged pages - only their rail position/visibility changed. Two captain corrections landed before the final shape: an in-rail expanding drawer (pushing rows below it up/down) was rejected in favor of a small flyout `NSPopover` anchored to the button's trailing edge, so the rail's own divider rhythm never moves; and click-to-open was rejected in favor of hover-to-open (Dock/menu-bar-submenu style), so there's no disclosure chevron either. `IconRailController.buildSetupButton()`/`showSetupFlyout()`/`SetupFlyoutViewController` are the whole implementation - `HoverTrackingButton`/`HoverTrackingView` report mouse-enter/exit via closures (`NSButton`/`NSView` have no built-in hover callback), and `scheduleShowSetupFlyout()`/`scheduleCloseSetupFlyout()` add a short (`setupCloseDelay`, 0.2s) close-on-hover-out delay so crossing the visual gap between the button and the flyout doesn't dismiss it - `scheduleShowSetupFlyout()` cancels the pending close the moment either view reports the cursor back over it. The flyout's own rows reuse `IconTileView`/`HoverHighlightView` from `HelmUIComponents.swift` (icon-in-tinted-square + label, horizontal instead of the rail's own icon-above-label) so it reads as this app's chrome, not a generic system menu; each row is an `NSClickGestureRecognizer` on a `HoverHighlightView` with no nested real control (same hit-testing-hazard avoidance as the Vault section's status pill). **A real, non-obvious `NSPopover` fact found while verifying this live**: `isShown` does not flip to `false` synchronously the instant `performClose`/`close()` is called - it lags by roughly the close animation's duration - so any test/verification code checking `isShown` immediately after a close call will see a stale `true`; check well after (verified live with an env-gated probe reverted before commit, per this file's "Verifying native UI bugs" convention, using real `HoverTrackingButton`/`HoverTrackingView` hover-simulation and a real synthetic `NSEvent` click through the flyout's own gesture recognizer, swept across `helm-dark`/`helm-light`).

- **`fm/grandline-lock-and-rail-fixes` reworked the rail's spacing rhythm and added a "more hosts" overflow entry**, after live captain feedback that the rail reads crowded/uneven at real-world density (all 11 destinations + a HOSTS section + badges) - density it was never actually tuned against before (every prior spacing pass happened against a shorter rail). Three named constants on `IconRailController` (`rowHeight` 46 (was a hardcoded 52), `rowSpacing` 3 (the gap *within* a group), `sectionGap` 14 (the gap *between* groups - mark/nav/hosts/utility/avatar)) replace what used to be a scatter of inconsistent literals (52/4/10/12/14 doing similar jobs) - any future rail spacing change should go through these constants, not a new one-off literal. Separately, with 2+ pinned hosts, only the first got its own row - the rest collapsed into one "+N" entry (`IconRailController.buildHostsOverflowButton`/`setHosts`) that reveals the remaining hosts on hover, reusing the exact `HoverTrackingButton`/`NSPopover`-on-hover mechanism `buildSetupButton()`/`showSetupFlyout()` already established (see the bullet above) rather than a second interaction pattern - `HostsOverflowFlyoutViewController` is the content-side counterpart to `SetupFlyoutViewController`, kept as its own type since a host's icon tints with its own per-host `accentHex` rather than one of the fixed `HelmTint` cases every `RailDestination` row uses.
- **`fm/grandline-rail-overflow-and-spacing` raised the host-overflow threshold to 3+ pinned hosts** (`hosts.count > 2` in `setHosts`) after captain feedback that collapsing at exactly 2 (1 shown + a "+1" entry) was premature - exactly 1 or 2 hosts always show every row normally. This part of that task held up. **Its accompanying "dead gap" fix did not** - it capped the HOSTS-to-utility-group boundary with a `[sectionGap, sectionGapMax]` range plus a soft (priority 800) bottom pin on `avatar`, and its own live verification only tested one window height, so it missed that the range/soft-pin combination let `hostsStack` itself - not the boundary it was watching - become the actual flexible spacer: `hostsStack` has no height constraint of its own, so with its top pinned via a required chain from the window's top edge (moves up in absolute terms as the window grows) and its bottom pinned near `toolsButton` (held near-fixed by the soft avatar pin), the stack view's frame stretched to fill the gap, growing 1:1 with window height (live-measured: 133pt/433pt/833pt/1433pt at 900/1200/1600/2200pt windows, with only ~103pt of real host-icon content). A captain screenshot on a maximized window showed this as a large dead gap below the pinned host icons. `fm/grandline-rail-spacing-fullheight` replaced the whole range/soft-pin mechanism with a single required, fixed `toolsButton.topAnchor == dividerBelowHosts.bottomAnchor + sectionGap` equality, making the *entire* rail (mark -> nav -> HOSTS -> utility group -> avatar) one fixed top-anchored chain with no free segment anywhere - `vaultButton`/`docsButton`/`setupGroup`/`avatar` no longer need their own anchor to `dividerBelowHosts` at all, since the existing bottom-up equalities already chain each of them to `toolsButton` (Settings had its own standalone row here too, at the time; `fm/grandline-avatar-menu-and-setup-guide` later removed it - see the bullet below). With nothing left to stretch, `avatar`'s position is fully determined top-down, and any leftover space at a tall window collects below it instead - verified live (fresh `IconRailController` + container per test, since reusing one instance across sizes leaves stale layout state behind) at 720/900/1200/1600/2200pt, at 0/1/2/3 pinned hosts (confirming the overflow threshold above is unaffected), and across both `helm-dark`/`helm-light`. **The already-documented, separate, still-open issue remains true and is unaffected by this fix**: the rail's total required content height (~836pt) exceeds this app's own default 720pt-tall launch window, so a too-short window still overflows/clips the avatar off the bottom - confirmed identical before and after this change (both designs are a required, mostly-fixed chain; only where the "flex" lived differed) - not something this task's scope covered.

- **`fm/grandline-avatar-menu-and-setup-guide` removed Settings' standalone rail row entirely** - it is still a real `RailDestination` for switching purposes (`AppShellController.show(.settings)` unchanged, the Settings page itself unchanged), but its only entry point is now a "Settings" row inside the avatar popover, above a divider, above "Logout" (`AvatarLogoutPopoverController`, `IconRailController.swift`) - Settings routine, Logout consequential, per captain-approved ordering. The popover is deliberately kept to just these two rows - an identity/account-style menu, not a general dumping ground for other rail items. The bottom-anchored utility chain (see the fullheight-chain bullet above) collapsed by one row: Tools -> Vault -> Docs -> Setup -> avatar, with `dividerSetupAvatar` now the one boundary directly above the avatar. The same task also collapsed `IconRailController.logoutClicked()` from two sequential `NSAlert`s down to one (captain reversing the original app-lock design's double-confirmation after live use showed it was too much friction) - the single remaining alert keeps the second alert's "you'll need your Grand Line password to get back in" copy, since it states the real stakes most clearly.

- **`fm/grandline-rail-unified-rework` consolidated three near-duplicate row builders (`railButton(for:)`, `buildSetupButton()`, `hostRailButton(for:)`) into one `buildRailRowButton(title:symbol:pointSize:tooltip:existingButton:)`**, after the accumulated per-task patches above left Setup's row subtly out of sync with the rest. The row-content geometry constants (`iconSize`, `contentSpacing`, `titleFontSize`/`titleFont`/`titleHeight`, and a derived `iconCenterYOffsetFromRowCenter`) moved from `CenteredImageAboveButtonCell`'s own private stored properties to `fileprivate static` members on `IconRailController` itself, so the cell that draws the icon and the badge anchor that has to line up with it read exactly one set of numbers - `CenteredImageAboveButtonCell.iconSize`/`.contentSpacing` are now computed properties reading straight through to `IconRailController`'s constants rather than independently-defaulted copies. **A real, verified badge-anchoring lesson**: `attachBadge`'s badge used to overlap a fixed amount into the icon's own top-trailing corner (tuned through `-6`/`6`, then `-12`/`12`, then `-20`/`20` - each verified live) but every overlap amount still visibly collided with `.review`'s `arrow.triangle.branch` glyph, whose ink (confirmed by rendering the SF Symbol standalone to a bitmap and inspecting it) fills *both* top corners of its 20x20 box almost edge-to-edge - a two-pronged upward fork, not a compact centered icon like `.overview`'s `server.rack`. No overlap-based anchor can clear every glyph's ink; the fix was to stop overlapping the icon's box at all - `container.leadingAnchor == iconAnchor.trailingAnchor + 3` places the badge entirely to the icon's *right* (an SF Symbol never draws outside the rect it's given, so this can't collide with any icon regardless of shape), with `centerYAnchor == iconAnchor.topAnchor + 2` keeping it looking like a corner badge with no headroom-above-the-row risk (the earlier `-20` overlap attempt exceeded the ~6-7pt of space above the icon within its own row and got visually clipped against the divider above - any future badge-position tuning needs to stay aware of that same headroom ceiling if it ever reaches back toward overlapping the icon). **Setup switched from hover-to-open back to click-to-toggle** (`setupClicked()`, mirroring `avatarClicked()`/`avatarPopover`'s `.transient` open-if-closed/close-if-open pattern) per live captain feedback during this task - superseding `fm/grandline-rail-setup-group`'s original hover-driven design (the `scheduleShowSetupFlyout`/`scheduleCloseSetupFlyout`/`setupCloseWorkItem` hover-delay machinery is gone for Setup specifically; `hostsOverflowButton`'s own hover flyout is untouched and still uses `setupCloseDelay`). A new `dividerAboveTools` marks the utility group's own top edge (mirroring `dividerAboveNav`'s role below the logo mark) - needed once the two-anchor-groups layout below could leave a large, boundary-less gap directly above Tools. **Layout: two independently-anchored groups, not one centered block** - this task's own first attempt (per its original brief) vertically centered the *entire* rail as one block within the window; the captain watched that running live and overrode it mid-task: the top group (mark through the HOSTS section) stays pinned to the window's top edge exactly as before this task, the bottom group (Tools through the avatar) is newly pinned to the window's *bottom* edge (`avatar.bottomAnchor == root.bottomAnchor - railEdgeMargin`, a real anchor that didn't exist before - previously the whole rail was one single top-anchored chain with no bottom anchor at all, which is *why* leftover space in a tall window used to collect below the avatar), and the only flex point is a required `>=` inequality (`dividerAboveTools.topAnchor >= dividerBelowHosts.bottomAnchor + sectionGap`) between the two groups' own already-fully-determined edges - never a range or soft-priority pin. Structurally this can't regress into PR #131/#132's bug (`hostsStack` itself stretching) since each group is still its own single rigid, fully-required chain; the *only* degree of freedom in the whole layout is that one inequality, verified live to grow correctly (leftover space collects only between HOSTS and Tools) across multiple window heights. **Avatar got a real visual pass**: `avatar` is now a `HoverTrackingButton` (not a plain `NSButton`) with a `CAGradientLayer` (flat avatar color -> the active theme's accent) replacing the old flat fill, and a `layer.borderColor`/`borderWidth` ring that brightens on hover (`restyleAvatar(_:)`, split out of `restyle(_:)` since it also has to re-run on `avatarIsHovering` changes, not just theme changes) - click behavior (`avatarClicked`/`avatarPopover`) is unchanged.

- **`fm/grandline-automation-pipeline` added a third row, "Automation," to the Setup flyout** (`showSetupFlyout()`'s `destinations` array, now `[.updates, .bootstrap, .automation]`) - `.automation` is a real `RailDestination` (own symbol `bolt.fill`, `isDailyUse: false`) with no rail row of its own, exactly like `.updates`/`.bootstrap`. See "Automation" below for the destination itself.

- **A now-historical redesign replaced the always-visible per-host icon block with a single "Hosts" `navStack` row that opens a flyout on click**, reusing the exact `SetupFlyoutViewController`/click-to-toggle mechanism above rather than a second interaction pattern - `dividerAboveHosts`/`hostsSectionLabel`/`hostsStack`/`dividerBelowHosts` (the old per-host icon block, plus its own "more hosts" overflow flyout at 3+ hosts from `fm/grandline-lock-and-rail-fixes`/`fm/grandline-rail-overflow-and-spacing` above) are all deleted outright, not hidden. `IconRailController.buildHostsButton()`/`hostsClicked()`/`showHostsFlyout()` is the rail-row builder, positioned inside the same daily-use `navStack` loop right where `.hosts` (still a real `RailDestination`, case order unchanged) already sat - "Hosts" highlights whenever `.hosts` or a saved host's own dedicated page (`activeHostID != nil`) is showing (there's no more per-host icon to highlight individually). `HostsFlyoutViewController` (replacing `HostsOverflowFlyoutViewController`) lists every saved host - not just the overflow - with a "Manage Hosts & Keys…" trailing row that calls `setActive(.hosts)`/`onSelect?(.hosts)`, opening the real, unchanged `.hosts` destination (`HostsController`) exactly like Setup's own flyout rows dispatch to their destinations; connecting a host still goes through `onConnectHost` unchanged. This same redesign originally added a sibling "VPN" flyout row alongside "Hosts" - see the "VPN (built, then removed)" section for that history; the row and its supporting code no longer exist.
- **Verified live**: a temporary env-gated probe (reverted before commit, per this file's "Verifying native UI bugs" convention) mounted a real `IconRailController` in an off-screen window and confirmed exactly 7 root-level separator boxes with no doubling between the daily-use rows and the utility group, the rail row order Overview/Console/Hosts/Tasks/Review, and the real Hosts flyout rendering un-truncated "DEV Bastion"/"Prod Bastion" plus a real "Manage Hosts & Keys…" row - all via real `NSPopover`s actually shown and read back from `NSApp.windows`, not just constraint math.

- **`fm/grandline-rail-unify-and-mark-polish` supersedes the two-anchor-groups layout from `fm/grandline-rail-unified-rework` above with one continuous, evenly-spaced list.** Real captain screenshots showed the old top-pinned-group/bottom-pinned-group split reading as two visually different gaps (more space above "Tools" than below it; more space after "Setup" than between any other row pair) plus a missing divider after Review. Fix: Tools/Vault/Dictation/Docs/"Setup" - previously individually-positioned `root` subviews, kept out of `navStack` only so the old variable-height per-host icon block above them could grow freely - now simply continue `navStack`'s own arranged-subview loop, separated by the exact same `navStackDivider()` rhythm the daily-use rows already used. That old reason to keep them out of `navStack` no longer applied once the hosts-flyout redesign replaced the variable-height per-host block with the fixed-height "Hosts" flyout row (a sibling "VPN" flyout row existed at this point too - now removed, see the "VPN (built, then removed)" section). **Unified order (current, after VPN's removal)**: Overview, Console, Hosts, Tasks, Review, Tools, Vault, Dictation, Docs, Setup - Overview/Console stay first (existing convention), then daily operational rows (Hosts, Tasks, Review), then frequently-reached utilities (Tools, Vault, Dictation, Docs), then Setup last as the least-frequent maintenance/bootstrap entry, directly above the profile - a captain-specified frequency ordering that matches `RailDestination`'s case order. Only the avatar keeps its own independent bottom anchor with its own divider (`dividerSetupAvatar`) above it - the one deliberate visual exception. The sole remaining flex point is a required `>=` inequality between `navStack.bottomAnchor` (top-anchored from `root.topAnchor`) and `dividerSetupAvatar.topAnchor` (bottom-anchored from `root.bottomAnchor` via `avatar`) - mirroring the old design's connector reasoning, so leftover height in a tall window collects in exactly the gap that already read as "more space after Setup" before this change, rather than a new mechanism. **A real bug caught by this task's own verification probe**: `restyleMark`/`restyleAvatar`-style theming registered via `ThemeManager.shared.observe` in `loadView` fires *synchronously at registration*, which happens before `mark`'s `wantsLayer`/`markGradientLayer` setup runs later in the same method - the first call's `mark.layer?.borderWidth = 1` silently no-oped on a nil layer. `restyleAvatar` already avoided this by virtue of `restyle(_:)` being called a second time at the end of `loadView`, after `avatar` is fully built; `restyleMark` needed the identical second call added there. Confirmed via a temporary probe dumping `mark.layer?.borderWidth` (0.0 before the fix, 1.0 after) across `helm-dark`/`helm-light` at 720/900/1200/2200pt window heights, alongside the divider-gap dump (every inter-row gap in the unified list a uniform 48pt regardless of height; the one flex gap growing 59→227→527→1527pt; the avatar's own gap a constant 62pt) and the bob-animation/lock-state check (`hasBobAnim` true after `setUnlocked(true)`, false after `setUnlocked(false)`) - all reverted before commit.
- **Same task gave the sailboat mark a richer look** (captain: "very bland") via the exact "flat color -> theme accent `CAGradientLayer` + soft accent ring" treatment `restyleAvatar`/`avatarGradientLayer` already established, reused rather than inventing a new visual language or a custom raster asset (`CaptainIcon.swift`'s convention was considered and judged heavier-weight than this needed) - `markGradientLayer` sized once (`mark`'s bounds are fixed 34x34) and re-tinted by a new `restyleMark(_:)`, mirroring `restyleAvatar(_:)`. The existing bob animation and `setUnlocked(_:)`'s lock/unlock weight change are untouched - only the mark's background/tint changed.
- **Same task also added a real active/pressed state to the Hosts/Setup flyout-trigger rows** (a VPN row existed here too at the time - since removed) - previously neither showed any highlight while their own flyout was open, unlike a real destination such as Console. `IconRailController` now conforms to `NSPopoverDelegate`; each `show*Flyout()` sets `popover.delegate = self` and a new `isHostsFlyoutOpen`/`isSetupFlyoutOpen` flag before showing, and `popoverDidClose(_:)` clears the matching flag by comparing `notification.object` against the stored `hostsPopover`/`setupPopover` - firing for *every* dismissal path (explicit re-click via `*Clicked()`, a row selection, or a `.transient` popover's own outside-click auto-dismiss, which never goes through `*Clicked()` at all). `restyle(_:)` folds each flag into that row's existing active-state coloring. Incidentally fixed a related pre-existing gap in the same check: Setup's active-state color never included `.automation`, even though its flyout lists Automation as a third destination - added alongside the flyout-open fix since both are the same class of "does this row's own state look active" bug. Verified live via a temporary probe calling each row's private `*Clicked()` selector by name (`perform(Selector(...))`), confirming a real non-clear `layer.backgroundColor` while open, then calling `performClose(nil)` directly on the popover object (bypassing the controller's own toggle method entirely) and confirming the tint clears - proving `popoverDidClose` itself, not just the explicit re-click path, does the clearing.
- **A follow-up fix addressed a real, live-reproduced bug in the "Setup→avatar" divider `fm/grandline-rail-unify-and-mark-polish` added: every hairline divider in this whole file was silently rendering via AppKit's own system `.separator` color, not this app's Helm theme, because `NSBox(boxType: .separator)` unconditionally ignores any `.fillColor` set on it** - confirmed empirically (not assumed) with a standalone probe: setting `.fillColor = .red` on a `.separator`-typed `NSBox` produced zero visible change. Every divider in this file (`dividerAboveNav`, every `navStackDivider()`-built row separator, and `dividerSetupAvatar`) was `.separator`-typed with no `.fillColor` ever set - so all of them, not just the one the captain flagged, were rendering at only a ~0.09 RGB delta from this rail's own dark chrome background (measured live via a bitmap-sampling probe: `bitmapImageRepForCachingDisplay`/`cacheDisplay`, sampling pixel colors along each divider's own y-center). The Setup→avatar divider happened to be the one the captain actually noticed missing because it sits alone in an otherwise-blank gap with nothing else nearby to visually frame it - `dividerAboveNav` sits right below the mark, and the inter-row dividers sit between visibly distinct icon rows, so their own equally-faint lines are less conspicuously absent. **Fix**: every divider in this file is now a plain `wantsLayer`-backed `NSView` (matching `edgeLine`'s own already-working pattern, and the same pattern used by every OTHER divider throughout this app outside `IconRailController.swift` - Settings/Bootstrap/Shift/Docs/Review/Fleet/`ToolRowLayout`, all a plain layer-backed `NSView` with an explicit `theme.chromeLineHex`-derived `layer.backgroundColor`, never `NSBox`) via a new `makeThemedDivider()` helper + `railDividers: [NSView]` registry + `restyleDividers(_:)`, called a second time at the end of `loadView()` for the same "the `ThemeManager.shared.observe` closure fires synchronously at registration, before later-built divider views exist yet" reason `restyleMark` already needed a second call for (see the bullet above) - `railDividers` only had `dividerAboveNav` in it on that first synchronous run. Verified live (temporary env-gated probe, reverted before commit): all 12 dividers (1 `dividerAboveNav` + 10 `navStackDivider()` rows + 1 `dividerSetupAvatar`) now share the identical, real, working `theme.chromeLineHex`-at-0.5-alpha fill - confirmed via `Mirror`-reflection dumping `railDividers`' real `CGColor`s - across window heights 500-1400pt with no constraint warnings, and the pixel-sampling probe confirmed the color genuinely changed (was the raw system separator color; now the theme-derived blend).

- **`fm/grandline-sre-lead-and-setup-icons` gave each Setup-flyout row its own hue, and re-verified two adjacent surfaces the captain suspected rather than assuming them.**
  **The one real defect:** `SetupFlyoutViewController.loadView()` passed a hardcoded `tint: .accent` for every row, so Updates / Bootstrap / Automation / GitHub Sync all rendered the identical tile - measured in a real off-screen render, all four glyphs sampled the same `rgb(165,218,229)` in `helm-dark`.
  Fixed with `RailDestination.flyoutTint` (declared beside `symbol`/`title`), consulted only where a destination is drawn as an `IconTileView` rather than a bare rail glyph.
  The per-row mapping was not guessed from the captain's colour words - it was recovered by sampling the proposed mockup's own pixels, which resolve to `HelmTint` cases this app already has: Updates `.info`, Bootstrap `.warn`, Automation `.accent`, GitHub Sync `.violet`.
  **A cross-theme trade-off worth knowing before touching it:** `.accent` for Automation collides with a neighbouring row in exactly 3 of the 12 palettes, because those palettes genuinely define their accent as that same hue (`tokyo-night-dark`/`-light` accent == their blue; `rose-pine-main` accent == its magenta).
  `.good` was measured to collide in zero themes but is green in `helm-dark`, where the reference mockup clearly shows the accent cyan - so mockup fidelity in the reference palette won, and the full measurement is recorded on `flyoutTint`'s own doc comment rather than left for someone to rediscover.
  `HelmContrastSelfTest.checkSetupFlyoutTintsAreDistinct` guards the *mapping* (four distinct `HelmTint` cases), deliberately not four distinct resolved hexes - confirmed to catch a real regression, not just to pass, by reverting all four rows to `.accent` and seeing it fail by name.
  The tint hues themselves need no new check: `checkIconTiles` already sweeps every `HelmTint` against the 3:1 icon floor in all 12 themes.
  **Two things verified as ALREADY correct, and left untouched.** The Hosts flyout was already per-host tinted - a real render against the captain's own two saved hosts is a pixel-level match for the proposed screenshot (DEV Bastion amber, Prod Bastion teal, "Manage Hosts & Keys…" neutral), because `HostsFlyoutViewController`'s theme observer tints each row from that host's own `accentHex` and the manage row from `.neutral`.
  The SRE Lead pane's Finding / Recommended-next-action rendering was already the `HelmAccentRow` treatment the mockup proposes - driving a real conversation through the fake-`claude` seam produced a populated pane matching the reference (accent bar, round badge, uppercase `mutedInk` kicker, tinted card border), so the captain's reported gap was the empty-vs-populated state, not a rendering bug.
  **A probe lesson that cost real time here:** an off-screen probe window must call `window.followHelmTheme()` the way `main.swift` does for the real window, or an `NSTextField`'s `.textBackgroundColor` resolves against `.aqua` and the SRE Lead input renders as a glaring white box that looks exactly like a real theming defect.
  The same probe run also confirmed behaviour was preserved by firing every flyout row's real `NSClickGestureRecognizer` target/action: all four Setup destinations and both host connects dispatched correctly.

## Session switcher (live SSH sessions)

**`fm/grandline-session-switcher` made an already-live SSH session reachable in one click or one keystroke from anywhere** - before it, switching from a live DEV session to a live PROD session meant leaving the terminal, navigating to Hosts, finding the row and pressing "Connect", a button that looked identical to opening a brand new connection. Four files: `HostSessionRegistry.swift` (the fact), `SessionStripView.swift` (the strip), plus the live-row/palette/shortcut wiring in `HostsController`/`UnifiedSearchProviders`/`main.swift`. Captain-approved mockup: `data/grandline-session-switcher/session-switcher-mockup.html`.

- **`HostSessionRegistry` is the app's one answer to "which hosts are live", and the point is that there is exactly one.** `AppShellController.hostConsoles` was already the truth but was read in exactly one place (`isHostConnected`, for F9's picker); the switcher needs the same fact in four more (the strip, the Hosts row's live state, the ⌘K group, the shortcuts), and four more independent notions of liveness is how they start disagreeing. **It is a registry, not a monitor** - the same shape and reasoning as `ServiceHealthRegistry`: it polls nothing, opens nothing, and never decides on its own that a session exists. `AppShellController` is the only writer, from the two moments it already owned that fact - `connectHost` (register) and `removeHostConsole` (unregister) - and `SessionSwitcherSelfTest.connectHostIsTheOnlyRegistrar` is a **source** guard on that, because a behavioural check cannot see a second writer added elsewhere.
- **`revealHostConsole` is the shared tail of `connectHost` and `switchToSession`.** `switchToSession(hostID:)` is deliberately a separate entry point rather than a `connectHost` overload: `connectHost` needs the host's resolved `ssh` argv (so its caller needs the host store), while switching back into a session that already exists needs nothing but an id - which is what lets the strip, the palette and the keyboard shortcuts all reach it without any of them learning how a host's argv is built. It is a **no-op** for an id with no live console, so every caller can fire against a possibly-stale id (a just-closed pill, a deleted host) without checking first.
- **The strip is a sibling of the bar in `AppShellController`'s root, not a second row inside `DaylightBarController`.** That controller's geometry (`reservedTopHeight`, its two independently-anchored constraint chains, B4's pill-label priority band) is measured and self-tested as-is, and the vertical stack above the body is the shell's own decision. **Showing it toggles `isHidden` *and* a height constraint *and* the body's top inset** - an ordinary hidden `NSView`'s constraints still participate fully in layout (gotcha (11)), so a strip that only toggled visibility would leave a permanent gap above every destination. Nothing in the strip is a window-width floor: every stack yields (`setClippingResistancePriority(.defaultLow, …)`), the trailing "+" is pinned by an *inequality* at `HelmDaylightPriority.contentTie` (499), and labels truncate rather than resist (gotchas (12)/(13)).
- **Pill order is the registry's insertion order, never sorted.** The ⌘⌃1…9 shortcuts and the strip's left-to-right order are the same list, so re-sorting on label would silently move a captain's ⌘⌃2 out from under them when an unrelated host was renamed. A re-`register` (a rename, a reconnect) refreshes the label and colour and **leaves `startedAt` alone** - "Connected · 14m" says how long the session has been up, not how long since it was last looked at.
- **A pill's dot is the host's own `Host.accentHex`**, a literal hue rather than a semantic `HelmTint` - the same distinction `HelmAccentRow.Content.tintHex` already draws, and what makes a DEV pill amber and a PROD pill teal without the strip knowing what DEV or PROD mean. It needs no contrast correction: a 7pt dot beside a label that already names the host is a redundant cue, not the sole carrier of meaning (the same exemption §2.4's gradient-tile caveat relies on). The active pill is the bar's own selected-pill recipe (solid `ink`, contrast-corrected label), so a live session reads as "selected" in the visual language the space pills already established.
- **The ✕ deliberately never appears on the active pill** (mockup callout c), so a mis-click cannot close the session being read; ending *that* one goes through the Hosts row's own "End session" overflow item. **The confirm is unconditional, and that is the honest reading of "confirm if a command may be mid-flight"**: the only structured record of a running command is `TerminalBlockTracker`'s OSC 133 markers, which exist solely on a host that opted into Block View (off by default, one host at a time), so on every other host the answer is genuinely unknown - confirming only where we happen to know would mean silently killing whatever was running everywhere else.
- **⌘⌃1…9 / ⌘] / ⌘[, not the mockup's ⌘1/⌘2 - and that was forced rather than preferred at the time.** ⌘1-⌘9 was already claimed twice when this shipped: the Tab menu's nil-target "Select Tab N" (only resolved while a Console/Tools tab held first responder) and the View menu's five space items (explicit target, **always enabled**). A session's whole point is being reachable from anywhere, i.e. precisely where the always-enabled space item won, so ⌘1 could never have reached a session. ⌘⌃ is the modifier the Hosts menu already uses (⌘⌃N, ⌘⌃S) and its number space was free; ⌘] / ⌘[ were verified unused. The items live in the **Hosts** menu rather than a new top-level one - a session *is* a host, and this app's menu bar already overran the notched-display budget (see the "Menu bar" section). Both other claimants are gone now (`fm/grandline-console-tabs-restore-tabmenu-fix` removed the Tab and View top-level menus outright, see "## Menu bar"), which frees `⌘1…9` again, but this stays on `⌘⌃1…9` regardless - an already-shipped shortcut isn't that fix's to change.
- **`UnifiedSearchKind.session` sorts first in `groupOrder`, and a live host is skipped by the Hosts provider** (`UnifiedSearchHostProvider.isLive`, defaulting to "nothing is live" so the pre-switcher behaviour is exact). Listing the same host twice, once as "Switch" and once as "Connect", is precisely the ambiguity the switcher removes. **It answers an empty query** - the second exception to the palette's "content providers return nothing until something is typed" contract, after `UnifiedSearchActionProvider`; the set is bounded by however many sessions are open, and a captain who opens ⌘K with two live sessions should see them without typing.
- **A Hosts row's live state is a `chipText`/`chipTint: .good` pair plus a swapped primary action**, deliberately reusing existing components rather than adding a green line to `HelmAccentRow`: `ToolRowLayout.pill` behind that chip is the app's one contrast-corrected chip, so it is legible in all 14 palettes without this page picking a green of its own. **Refreshed on `viewWillAppear` and on every registry change, never on a timer** - a per-minute reload of the whole table would reset scroll and selection for a string that is honest for a whole minute anyway.
- **Verified** with `swift build` (clean debug and release, zero warnings in this app's sources), the release binary confirmed to carry no `FM_RUN_*` strings, the full suite (92 passed, 1 documented skip), and real off-screen PNG renders (`bitmapImageRepForCachingDisplay`/`cacheDisplay`) of the real mounted shell on `daylight` and `helm-dark` - the strip in both its all-idle and active-pill states, and the Hosts page with two live rows beside an idle one - **without ever launching the app**, per the README's worktree rule. `FM_RUN_SESSION_SWITCHER_TESTS` is window-backed, so it joins `run-all-tests.sh`'s `NEEDS_SESSION` list. **Six injected regressions each reproduced by name**: the strip's height left uncollapsed, a ✕ on the active pill, a live row keeping "Connect", the palette listing a live host twice, the registry sorted by label, and a second registrar added outside `AppShellController`.
- **The one honest gap, stated rather than papered over**: the suite creates a session by calling `sessions.register(…)` - the exact line `connectHost` calls - rather than by calling `connectHost`, which forks a real `/usr/bin/ssh`. So it proves the strip, the rows, the palette and the shortcuts all react correctly to a registered session, and does not prove `connectHost` registers one; that is one unconditional line right after `connectSSHIfNeeded`, guarded by the source check above.

## Recents navigation

**`fm/grandline-recents-navigation` added a "Recents" dropdown so a captain who wandered Command -> Console -> Updates -> Sticky Board -> Vault can jump back to any of them in one click** - the captain reviewed four approaches (a full back/forward stack, a single "go back one step" toggle, this dropdown, a keyboard-shortcut-only version) and chose the dropdown, with one explicit placement correction: the button sits **after the space pills**, never next to the logo the reviewed mockup showed it beside. Two new files - `RecentDestinations.swift` (the registry, pure Swift) and `RecentDestinationsPopover.swift` (the button + popover, mirrors `NotificationCenterPopover.swift`'s idiom) - plus wiring in `AppShellController.swift`/`DaylightBarController.swift` and `SelfTests/RecentDestinationsSelfTest.swift`.

- **It is a registry, not a monitor, matching `HostSessionRegistry`'s own shape and reasoning** (deliberately NOT merged with it or its strip UI - that answers a narrower, different question, "which hosts have a live SSH session right now", and is tied to a running process; this is a plain visit log with no notion of "still open"). The one writer is `AppShellController`, from the two places it already funnels every real navigation through: `show(_:)` for a `RailDestination`, and `revealHostConsole` (the shared tail of both a fresh `connectHost` and `switchToSession`) for a saved host's own dedicated page - which has no `RailDestination` case of its own, so `RecentDestinationKind` is `.rail(RailDestination)` or `.host(id:label:)`. In-memory only, deliberately (matching `HostSessionRegistry`) - the captain's own scoping call was that this need not survive a relaunch.
- **The non-obvious part: what gets recorded is the destination being LEFT, never the one being entered.** `RecentDestinations.recordNavigation(leaving:arriving:)` inserts `leaving` (deduped, moved to the top) and unconditionally *removes* `arriving` from the list if it was already there. A naive "record where I just navigated to" model would show "Vault, just now" pinned at the top while the captain is looking at Vault - exactly the self-reference this design avoids, and for free: no destination the app is currently showing can ever appear in its own Recents list, revisiting an already-recent destination moves it to the top with no duplicate, and re-showing the same destination (a stray click on an already-selected quick-access icon, switching canvas spaces while staying on `.homeCanvas`) manufactures no entry at all - all three fall out of one rule with no special-casing at any call site. `AppShellController.updateRecentDestinations(arriving:)` is the one place that calls it, tracking `currentDestinationKind` (private) so the *next* call knows what was just left; it is called from exactly three places - `show(_:)`, `revealHostConsole`, and the one narrow bypass that jumps straight to a host's tab from a background SRE Lead reply notification (which also needed its own `updateRecentDestinations` call, or `currentDestinationKind` would go stale for whatever navigation came next).
- **Capacity is 5** (the captain's own "4-5 entries is about right, not a long history browser"). Tab-level switching (e.g. Console's Shell vs. an SSH tab) is deliberately NOT tracked - the captain's own framing was about destinations, and nothing in `ConsoleController`'s own tab switching calls back into `AppShellController.show(_:)` at all, so this needed no code to exclude.
- **Bar placement**: `DaylightBarController` gained `let recentDestinations = RecentDestinationsController()`, positioned in `loadView()` between `pillRow` and `searchPill` - a fixed leading gap off the pills, then the bar's one compressible joint (previously right after the pills) moved to sit right after this button instead, so there is still exactly one squeeze point in the whole chain (gotcha (13)). `RecentDestinationsController.configure(registry:onSelect:)` is the one late-binding call `AppShellController.loadView()` makes - the bar owns the button and the popover chrome, never what a `RecentDestinations` is or what "navigate" means, the same forward-don't-own shape `onSelectDestination` already established.
- **Verified** with `swift build` (clean debug and release, zero warnings in this app's sources), the release binary confirmed to carry no `FM_RUN_*` strings, and the full suite (103 passed, 1 skipped for the documented Whisper reason) - including a real `AppShellController` mounted in a real window driving real `show(_:)`/`switchToSession` sequences (a seeded `ConsoleController` via a new `debugSeedHostConsole` test hook stands in for `connectHost`'s real `ssh` fork, the same bypass `SessionSwitcherSelfTest` already established for the identical reason), real popover rows read back and clicked, and the button's real geometry/theming across a real light and dark `HelmTheme`. A source guard (`test_recordNavigationIsTheOnlyWriter`) pins `recordNavigation` to exactly one caller, matching `SessionSwitcherSelfTest.test_connectHostIsTheOnlyRegistrar`'s own convention.
- **One thing worth knowing if this area is touched again**: a fully-laid-out `AppShellController` always performs a real launch navigation at `loadView()` time (GL-31: `show(.homeCanvas)`, or `show(.bootstrap)` on a machine with no firstmate home resolved) - so a test mounting the shell and immediately calling `show(_:)` a few times will see that launch destination trailing its own sequence in `recentDestinations.entries` once capacity allows. That is correct, expected behaviour (the launch landing is a real destination once the captain leaves it), not a bug - assert against a leading prefix of the array, not the whole thing, the way this suite's own shell-integration cases do.

## Window chrome fusion (UI modernization audit A1/A2/A3)

**`fm/grandline-window-chrome-fusion` implemented A1, A2 and A3 of the design-led UI modernization audit (`data/grandline-ui-modernization-audit/report.md` §3A, captain-approved as "let's go with the suggested fix" for each).** The report sequences the three together and calls them "the highest-leverage modernization available"; they ship as one change for that reason. **Read §3A and §6 of that report before extending any of this** - and note §6's constraint list, which every part of this respected: no `.behindWindow` vibrancy, tokens not literals, and the existing window-backed suites extended rather than replaced.

- **A1 - the window's own chrome.** `WindowChromeFusion.swift` is the whole thing; **read its header before touching it**, because every number in it was measured against a real `NSWindow` and several contradict what a reasonable person would assume:
  - A stock `.titled` window's titlebar is **32pt**, not the report's estimated ~28, so that is what `.fullSizeContentView` reclaims.
  - The traffic lights land at top-down centre **16**, cluster x **9...69**. **No stock configuration puts them anywhere else**: an `NSToolbar` is the Apple-sanctioned way to grow the titlebar and re-centre them, and it quantises - measured, no toolbar gives 32/centre 16, `.unifiedCompact` 40/20, `.unified` 52/26, `.expanded` 68/16, **regardless of the toolbar item's own height**. None of those is the bar's centre (39), so the toolbar route cannot express this design and the lights are repositioned by hand.
  - **The only hook that holds is a layout pass.** A manual `setFrameOrigin` survives a runloop turn, a key/resign and an appearance change; it is undone by a resize, a `title` change, a `styleMask` touch, and - the one that matters, because this app does it on every resize in `reassertBodyContainerWidthTie` - any forced `layoutSubtreeIfNeeded()`. `ChromeFusionRootView` (the shell's root) re-applies from its own `layout()`, which covers all of them including a synchronous layout with no intervening runloop turn. **A fix hooked only on `NSWindow.didResizeNotification` passes a naive test and fails in use**, which is what that suite's own case exists to catch.
  - **Do not set `postsFrameChangedNotifications` on AppKit's private `NSTitlebarView` and observe it** - doing so segfaulted the probe process outright (exit 139, no output at all). The `layout()` hook needs neither.
  - **The report's own "left padding ~78pt" is right for a bar flush to the window edge and wrong for this one.** This bar is inset `sideMargin` (22pt), so leaving the lights at x 9...69 puts the close button on the page ground *outside* the bar's rounded leading edge with the other two inside it - caught in a real render, not by reading the code. The cluster is therefore moved **horizontally as well**, to the bar's own content inset, and `leadingInset` reserves `contentInset + span + contentInset` (84pt inside the bar) rather than the report's 78 from the window edge. Both numbers come from `WindowChromeFusion` so they cannot drift apart.
  - **The whole cluster is shifted by one delta, never placed button-by-button** - AppKit owns the spacing between them, and re-deriving it here would drift the moment a future macOS changes it.
  - **Full screen is left entirely to AppKit**: it hides the lights and shows them in its own auto-hiding overlay, which is a different container, so `positionTrafficLights` returns early and `leadingInset` drops back to the plain inset (there is no cluster on screen to reserve room for).
  - The window keeps its **title string** (the Window menu, Mission Control and the proxy menu all read it) and all three **standard buttons visible** - unlike this app's two `NSPanel`s, which use the same idiom and hide all three.
- **A2 - the drill header is the bar's leading cluster now.** `HelmDrillHeader` was a full-width 56pt strip pinned across the top of `bodyContainer`; it is the back-chevron + tile + title/subtitle group inside `DaylightBarController`'s bar row. The class keeps its name (~15 doc references and a whole self-test point at it, and it is still "the drill page's header" - only its parent moved).
  - **The action cluster moved out of that class entirely** and is the bar's own trailing-anchored `drillActions` stack, immediately before the search pill. It had to: the bar's leading and trailing areas are two independently-anchored chains with **one** compressible joint between them, and a single view spanning both would re-create the window-width floor that joint exists to prevent. `setActions` is `DaylightBarController.setDrillActions` now, with the caller-owned-views contract unchanged.
  - **The space pills hide on a drill page, and that is measured rather than preferred.** On a real bar at 1440pt the pills take 454pt and the gap between them and the search pill is only 143 - there is nowhere near room for a ~94pt leading cluster plus a page's actions. Hiding them is also what the report's own cited apps (Finder/Settings/App Store) do. They are **arranged subviews**, so hiding each one collapses `pillRow` to nothing (gotcha (11)'s own `NSStackView` exemption); hiding the *stack* would leave 454pt of invisible demand behind. Same mechanism for the leading swap: the wordmark row and the drill cluster are two arranged subviews of one stack, so one leading anchor serves both.
  - **The cluster's own size *is* its content now, and that needed three things the full-width strip never did.** Label hugging went `.defaultLow` -> `.defaultHigh` (low hugging means "happy to stretch", which left the width genuinely ambiguous - measured, the cluster resolved to a **539x0** frame); compression resistance stays `.defaultLow`, which is the half that could cap a window and the half that makes the title truncate first. And a **priority-1 shrink-wrap** (`width == 0`, `height == 0`, `textColumn.width == 0`) pulls it onto the `>=`/`<=` bounds its children set - priority 1 is deliberately below *everything*, including the labels' own 250 compression resistance, so it hugs the text and never squeezes it.
  - **`HelmType.drillTitle()` went 26 -> 15.** 26 was right for a 56pt strip and swamps a 50pt bar row that also carries a subtitle. 15 is one step above the wordmark it replaces (14.5 heavy). `HelmContrastSelfTest`'s type-scale table carries the new value.
  - **The back button is the head of `bar.keyViewChain`**, not `firstBodyKeyView()` - the same reading order it always had, one row up. `keyViewChain` already filters hidden views, so it drops off the canvas for free. Consequence worth knowing: `firstBodyKeyView()` can now legitimately return `nil` for a page whose own content is all static (Review before its fetch lands), which used to be masked because the hand-off *was* the back button.
  - **`comfortableWidth` (700) was left alone, and the measurement says why**: the bar's pill row and search pill already overlap at 800pt, before any of this. A2 does not make that worse - a drill page *frees* room - so the narrowest layout is still the canvas's, exactly as before. Measured after the change, the leading-to-search slack stays positive at 1440/1220/1100/1000/900 on both the canvas and a drill page.
- **A3 - the scroll edge.** `ScrollEdge.swift`'s `ScrollEdgeObserver` is one observer in the shell, re-pointed on every navigation.
  - **It discovers the page's scroll view rather than asking the page for it**, and that is the report's own "all pages inherit" taken literally. A protocol beside `DaylightDrillActions` was rejected after a survey found **zero** of the 24 mounted destinations expose their page scroll view (9 hold it in a `private let`, 8 in a `private var ...!`, the rest have several or none) - it would have meant editing ~17 controllers, and a destination added later would silently opt out by doing nothing.
  - **What counts is geometric**: a scroll view pinned to the destination's own top edge. A page whose top is a static strip - a tab row (Hosts, Setup), a toolbar (Console, Tools, Docs), a session card (Kubernetes) - has nothing sliding under the chrome and correctly gets no edge, as does the Sticky Board's 2-D corkboard.
  - **The report's literal `origin.y > 0` is only right for a flipped document.** It inverts for a non-flipped one (an `NSTableView`'s document is bottom-up, so scrolled-to-top is its *maximum* offset). `ScrollEdgeObserver.isScrolled` asks "is this away from its own top edge" and handles both.
  - **A floating rounded bar expresses "hairline + slight material" as depth, not as a rule under it.** That recipe assumes a full-width strip whose bottom edge is the boundary; this bar is inset, rounded and has a 12pt gap beneath it, so a full-width hairline under it would draw a line attached to nothing. Instead `HelmCard.elevation`'s own second level (§2.5 defines exactly two, and this is what the raised one is for) plus the border going to full strength. **The per-theme split falls out rather than being special-cased**: the elevation helper already resolves Daylight/Dusk separately, and Daylight/Dusk already draw that border at full strength at rest, so on those two depth alone carries the signal - the self-test asserts that direction rather than demanding a change the palette makes impossible.
  - `applyTheme` routes the bar's border and shadow through `applyScrollEdge`, so a theme change cannot silently reset the bar to resting depth while the page under it is still scrolled.
- **Verified** by `swift build` (clean debug and release, zero warnings in this app's sources), the release binary confirmed to carry no `FM_RUN_*` strings and none of the new suite's symbols, the full `./Scripts/run-all-tests.sh` run (135 passed / 0 failed / 1 documented skip), and real off-screen renders of the real mounted shell on `daylight`/`dusk`/`helm-dark`/`gruvbox-light` - including a whole-*window* capture (through `contentView.superview`, since `cacheDisplay` on the content view alone never shows the traffic lights) and the lock screen, which fills the window edge to edge under the now-transparent titlebar. **The app itself was never launched**, per the README's worktree rule. `FM_RUN_WINDOW_CHROME_FUSION_TESTS` is window-backed and joins `run-all-tests.sh`'s `NEEDS_SESSION` list. **Ten injected regressions each reproduced by name**: `.fullSizeContentView` dropped from `apply` and (separately) from `main.swift`'s own literal, the standard buttons hidden, the shell's `layout()` hook removed, the horizontal reposition reverted, a one-way leading swap, a 56pt strip reinstated under the bar, copied action views instead of the caller's own, the literal `origin.y > 0` used for both document orientations, the observer never reaching the bar, and the elevation pinned at resting.
  - **One of those ten initially did not reproduce, and closing it is the transferable part.** The harness's own `makeWindow(fused:)` pre-inserted `.fullSizeContentView` into the style mask, so deleting `apply`'s `insert` changed nothing. It now builds the window at the *pre-A1* mask so `apply` is the only thing that can supply the flag, and a **source guard** covers `main.swift`'s own literal - the two catch different failures and both are needed. **A harness that constructs the thing under test the way production does can be unable to see production's own belt-and-braces go missing.**
- **`fm/grandline-window-chrome-theme-regression` closed two live, captain-reported bugs in this same chrome, neither one caused by the PR that happened to precede the report (`fm/grandline-separate-setup-destinations`, #384 - confirmed by direct code reading: it only touches `AppShellController`'s destination-registration table and the four Setup pages' protocol conformance, none of which appearance/traffic-light code lives in) - both were latent since this chrome's own earlier phases and became newly visible once Dusk (a Daylight-family theme, materialView-enabled) became the default theme.**
  - **The theme desync ("toolbar renders light while the rest of the window stays dark"): `DaylightBarController` was the one controller in the whole app that never forced its own `.appearance`** (`ThemeManager.swift`'s mandatory checklist item 2 - every other destination follows it). Its layer-backed fills and label colours are literal `HelmTheme` hexes, so they tracked correctly regardless; what had no guarantee was `materialView` (the `.withinWindow`/`.headerView` `NSVisualEffectView`, visible only on the Daylight family) and any other AppKit-owned chrome in that subtree - the exact "half-themed" class this codebase already hit for Sticky Board/Code Preview/Whiteboard. Fixed with one line at the top of `DaylightBarController.applyTheme(_:)`: `view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)`. Caught by a new case in `WindowChromeFusionSelfTest.swift` (`test_a1BarForcesItsOwnAppearance`) using the exact discriminating step `DestinationMountingSelfTest.test_everyDestinationForcesItsOwnAppearance` already established: force `window.appearance` to the *opposite* of the active theme after mounting, then assert the bar's own view still resolves to the theme. Confirmed to catch the regression by scripted revert.
  - **The traffic-light overlap ("stuck until the window is moved"): a real, measured AppKit gap in A1's own reposition mechanism, not something #384 touched.** `WindowChromeFusion`'s header already documented that a window `title` change resets the traffic lights the same way a resize does, and claimed re-applying from `ChromeFusionRootView.layout()` "covers every one of those" - **that claim was wrong for title changes specifically, and this is the fix.** Measured with a temporary probe: `NSView.layoutSubtreeIfNeeded()` is a no-op unless something already marked the view `needsLayout` - a window resize/move is a real geometry change that AppKit marks dirty on its own, but a bare `window.title = ...` marks *nothing* on the content view, so nothing ever re-invokes `onLayout`/`positionTrafficLights` after one. A Console tab reports its own shell's title on ordinary activity (`ConsoleController+Tabs.swift`'s `updateWindowTitle`/`setTerminalTitle` - a new prompt, a `cd`), so this fires many times a minute during real use, matching the captain's own report exactly ("after going through a couple of consoles", fixed by "moving the window" - a real geometry change). Also measured: a single title change did not always show the drift; several in a row (simulating shell prompt spam) reliably did. Fixed with `ChromeFusionRootView.viewDidMoveToWindow()` installing an `NSKeyValueObservation` on `window.title` that explicitly sets `needsLayout = true` before forcing `layoutSubtreeIfNeeded()` - `viewDidMoveToWindow` rather than grabbing a window reference during `AppShellController.loadView()`, since the view may not have one yet at that point. Caught by a new case (`test_a1TrafficLightsSurviveTitleChanges`) driving several rapid title changes through the real `ChromeFusionRootView` mechanism (via `window.contentView = root`, matching how `loadView()` installs it, not the constructor); confirmed to catch the regression by scripted revert.
  - Both fixes are additive-only (no other file touched) and the file's own header comment was corrected to state the title-change gap explicitly rather than leave the inaccurate "covers every one of those" claim standing.

- **`fm/grandline-window-chrome-still-broken` is the correction to the entry above: PR #386's *both* diagnoses were wrong, and the real defect had been live since A1 (#374) shipped - close, minimise and zoom were never clickable at all.** Read `WindowChromeFusion.trafficLightHitTest`'s own doc comment before touching the cluster again.
  - **The bug, measured on the real running app rather than reasoned about: `positionTrafficLights` moves the buttons *outside their own superview*, and AppKit's default `hitTest(_:)` rejects a point outside a view's frame before it ever asks that view's subviews.** Measured: `frame.origin.y == -14` inside a superview whose `bounds.height` is 32, and a hit test at each button's own rendered centre returned a plain `NSView` for all three. The cluster rendered perfectly the whole time - a view draws outside its superview's bounds, only clipping stops that, and the titlebar does not clip - which is exactly why every geometry-based self-test passed while the buttons did nothing. **This also explains the captain's own "moving the window unsticks it": a real move or resize makes AppKit reset the cluster to its stock position *inside* the titlebar, where it is briefly clickable until the next layout pass moves it back out - so #386's title-KVO, by re-applying the reposition more often, made it marginally worse.**
  - **The fix is hit-test forwarding, deliberately not reparenting.** `ChromeFusionRootView.hitTest` asks `WindowChromeFusion.trafficLightHitTest` first. Re-adding the buttons as subviews of the bar also works and is what several apps do, but it takes ownership of system views away from AppKit across full-screen transitions and style-mask changes; forwarding is purely additive and leaves them where AppKit put them. Two guards that are not optional: it only claims a button that is **genuinely repositioned** outside its superview (one still inside is AppKit's to handle, and claiming it would steal a click), and it rejects on a **cached cluster rect** written by `positionTrafficLights` before resolving any button - `hitTest` runs on every mouse-moved and every step of every drag, and `standardWindowButton(_:)` is a window-level accessor that reaches into the titlebar.
  - **The theme half was investigated end-to-end on the real app and there is no appearance divergence in the chrome** - so #386's `.appearance` line, while harmless and consistent with `ThemeManager.swift`'s checklist, fixed nothing. Measured in the captain's own configuration (`fm.themeID = daylight`, OS in Dark), at launch **and** across a live `ThemeManager.toggle()`: window, `NSThemeFrame`, `NSTitlebarContainerView`, content view, bar and the bar's own `NSVisualEffectView` all report the same appearance, and the page ground samples to `paper` (`F5F2EA`) exactly. What the screenshots show is **light chrome against a dark terminal, which is K2's dark terminal card on the Daylight family - by design** (see this file's own K2 entry); switching to Dusk renders the whole window dark. **Note the real app's preference domain is `com.manjesh.grandline.native`, not `GrandLine`** - the latter is the unbundled/self-test domain, and reading the wrong one is how #386 came to test a theme the captain was not using (on `helm-dark` the bar's material is `isHidden`, so its fix was a no-op for them).
  - **Why the old suite was green against a broken app, and what closes it.** Every pre-existing A1 case measured where the cluster *is* (`trafficLightCenterForTests`/`trafficLightSpanForTests`, both of which read the button's own frame). Position was never the broken part. `test_a1TrafficLightsAreHitTestable` asks the question geometry cannot - hand the real content view the point AppKit would dispatch and require the button back - and it **asserts the cluster is genuinely outside its superview first, so it cannot pass vacuously**. `test_a1ZoomButtonReallyZooms` is the end-to-end half. **A traffic-light widget ignores a click in a window that is not key**, so that case calls `makeKeyAndOrderFront` on an `OffScreenProbe.window(...)` in an `.accessory` process (genuinely off every screen, and it does not activate the app) and degrades to a printed NOTE where even that is impossible. It used to say "a window parked at `x = -20_000` (invisible)", which was false - see `SelfTests/OffScreenProbeWindow.swift` for the measurements and for why the parking has to be a property of the window's own type.
  - **`FM_RUN_SHIFT_BOARD_VIEW_TESTS` is environment-flaky on a machine somebody is using, and a timeout there is not automatically your regression.** It timed out three times during this task and passed 3/3 immediately afterwards on the identical build. `sample` on the hung process showed the real cause: `ShiftProjectFilterBar.debugClickChip` -> `NSButtonCell.performClick:` runs a **nested event loop** that processes real user input, and a genuine mouse drag on the machine at that moment lands in `NSCoreDragManager._dragUntilMouseUp` and blocks forever. **`sample <pid>` is the tool - a stack trace settles this in one run where bisecting by revert does not.**

## The floating bar and navigation (UI modernization audit B1-B5)

- **`fm/grandline-theme-desync-reinvestigate` closed the captain's long-running "light/dark keeps changing on its own" report at the fifth attempt, and the root cause was in neither place the four earlier attempts looked: `mouseEntered`/`mouseExited` overrides on three `NSButton` subclasses never called `super`, so AppKit fired the control's action on a bare hover.** Sweeping the mouse across the floating bar hit `DaylightThemeToggleButton` (a `DaylightBarIconButton`) and silently flipped the whole app between Dusk and Daylight. Read `DaylightBarIconButton.mouseEntered`'s own doc comment before touching any hover override on a control.
  - **`super` is load-bearing on an `NSControl`, and politeness on an `NSView` - the two are opposite rules and this codebase now documents both.** `NSControl` maintains its press tracking through those two hooks (`-[NSControl(_NSTracking) gestureRecognizerTrackingAction:]` -> `_pressGRActionCellBased:`); starve them and that state machine can send the action on a *later* enter/exit/move. `NSView`'s versions are documented no-ops, which is why the four plain-`NSView` hover consumers (`HoverHighlightView`, `HelmModuleCard`, `TabChipView`, `VocabularyChipView`) are deliberately **not** required to call super and were left untouched. Note this is the mirror image of `HoverHighlightView`'s own long-standing rule ("must NOT override `mouseDown`/`mouseUp`, even calling super"): there an override *steals* a nested button's click, here a missing super *fabricates* one.
  - **The blast radius was far wider than the reported symptom, which is the part worth remembering.** `HelmButton` - the app's single button class, ~128 call sites - had the identical defect, so a hover could in principle fire any action in the app, Merge and Delete included. The theme toggle is simply the one whose misfire is visible instantly and app-wide. `HoverTrackingButton` (the avatar) was the third.
  - **How it was caught, after four attempts had not been: log every `setTheme` with its stack *and* `NSApp.currentEvent`.** The stack named `DaylightBarController.themeToggleClicked`, and the event was `mouseEntered` (raw 8) / `mouseExited` (9) / `mouseMoved` (5) with **no click count** - which is what separates "a real stray click" from "AppKit fabricated an activation". Read the backing event, not just the stack: two of the observed fires genuinely *were* real clicks landing on the probe window, and mistaking those for the bug is how this could have been mis-diagnosed a fifth time.
  - **Why the earlier attempts missed it, stated so the pattern is recognisable.** Both #386 and #387 investigated *rendering* - which view resolves which appearance - and both were right that the rendering is correct: every surface is on-token, the forced appearance holds, and an OS light/dark auto-switch underneath a running app changes nothing (measured). The defect was never that a theme renders wrong; it was that **the app kept leaving the theme the captain had chosen**. #387's "K2 dark terminal card, by design" was a true statement about Daylight that did not account for the captain also having seen it correct - and the reconciliation is that *both* states were real, because the app was oscillating between two themes that each render perfectly.
  - **Two environment facts that matter for any future repro of this class.** The real app's preference domain is `com.manjesh.grandline.native` (`GrandLine` is the unbundled/self-test domain - #387 already recorded this, and it is still the easiest way to test the wrong theme); and this machine has `AppleInterfaceStyleSwitchesAutomatically = 1`, so the OS appearance genuinely moves under the app twice a day. That was a strong-looking hypothesis and is **not** the cause: a probe that flips `NSApp.appearance` at runtime leaves every bar surface unchanged, because `applyTheme` pins a concrete `NSAppearance` on the bar's root.
  - **The regression gate is a source guard, `AppKitAuditSelfTest.test_hoverNeverActivatesAControl`**, which builds the app's class -> superclass map, keeps the `NSButton`/`NSControl` descendants transitively (so a future `: DaylightBarIconButton` subclass cannot fall out of it), and requires every hover override on one to call super. It is a source guard for the reason K3's implicit-animation guard is: reproducing the defect needs the real cursor to cross the real button in a real window, so a behavioural check would be probabilistic - it reproduced in 4 of 5 real launches, not 5 of 5. Confirmed to catch the regression by scripted revert, naming all six overrides by class and file. It also fails if it finds fewer than three such overrides, so a scan that has drifted cannot pass by finding nothing.
  - **Verified** by `swift build` (clean debug and release), the full `./Scripts/run-all-tests.sh` run, and repeated real launches of the sanctioned probe bundle (`Scripts/build-probe-app.sh`, separate bundle id and scratch stores - the captain's own instance was never touched): **5 of 5 post-fix runs show zero spurious activations, and the scripted revert brings them straight back.** All probe instrumentation was reverted before commit, per this file's own convention.

**`fm/grandline-bar-nav-modernization` implemented B1-B5 of the same audit (`data/grandline-ui-modernization-audit/report.md` §3B, captain-approved as "let's go with the suggested fix" for each), the sibling of A1/A2/A3's chrome fusion above.** They ship as one change because the report groups them under one heading and they touch overlapping code. **Read §3B and §6 before extending any of this.** What is worth carrying forward:

- **B1 corrects a *reading* of AGENTS.md gotcha (8) rather than overriding it, and the distinction is the whole finding.** `DaylightBarController`'s header said "No `NSVisualEffectView`, and this is not a stylistic call", citing gotcha (8). But gotcha (8) is a finding about **`.behindWindow`**, which composites against the *desktop* and so renders the wrong tint on every theme; **`.withinWindow`** composites against the window's own content, which is correct for chrome floating over a page. The ban is intact and is now asserted more precisely than before: `DaylightModuleSelfTest.checkBarAnatomy` used to assert the bar contained *no* `NSVisualEffectView` and now asserts it contains no **`.behindWindow`** one, on all 14 palettes. A `.withinWindow` `.headerView` material sits behind the bar's rounded mask **on the Daylight family only** - the twelve legacy palettes keep the byte-for-byte opaque fill, which is B1's own scoping ("their surfaces are already near-black; translucency buys little").
  - **The material is chosen by semantics and its risk is bounded by measurement, because it cannot be seen from here.** `NSVisualEffectView` is composited by the window server, so `cacheDisplay` - this repo's screenshot substitute - captures a flat placeholder for it, and launching a real build to look is forbidden (the captain's instance shares this bundle identity). So: `.headerView`, not the report's literal ".hudWindow-ish", because `.hudWindow` is the material for HUD *panels*, which macOS renders dark by convention and this bar is light on the flagship theme. And `test_b1MaterialCannotBreakContrast` bounds the damage instead of guessing at it - the bar paints `chromeBackgroundHex` at `daylightFillAlpha` (0.72) over a material that composites against `backgroundHex`, so its effective surface is somewhere between those two colours, and the check asserts the bar's own ink clears the floor against **both ends**. That is also what picks the alpha. Confirmed capable of failing by moving Daylight's `paper` to a mid-grey.
  - **"Content visibly slides beneath it" is not true yet, and that is stated rather than implied.** `AppShellController` still starts `bodyContainer` at `reservedTopHeight`, so the material blends against the page ground rather than against a scrolling page. Making content genuinely pass under the bar means starting `bodyContainer` at the window's top edge and insetting ~24 destinations; no finding in §3B asks for it, and the material is correct either way.
- **B2's icon row: one language at rest, state on hover and on the page you are looking at.** The five raster app icons are gone from the bar - every shortcut is its own `RailDestination.symbol`, monochrome, `restingGlyphAlpha` (0.7) muted at rest, and its **domain hue** on hover or while its own destination is showing (`DaylightBarIconButton`, which now owns a tracking area and a `setActiveDestination`; `AppShellController.show(_:)` pushes the active destination exactly as it already pushes the selected space, and `revealHostConsole` clears it because a host page is not a `RailDestination` at all).
  - **The hue is `HelmDomainHue.identityHex(in:)`, never `baseColor(in:)`.** On the twelve legacy palettes `baseColor` resolves through `fallbackTint`, a *semantic* slot - so hovering Tasks (`.rose` -> `.critical`) would turn it red and the icon would be making a claim about Tasks rather than identifying it. That is the exact defect `identityHex` exists for. The cost is that hue differentiation lands only on the Daylight family; the twelve still get a real state response (muted -> full ink), which is the half B2 is actually about.
  - **This reverses `fm/strawhat-toolbar-shortcut-use-jolly-roger-icon-69c3` deliberately, not by accident.** That fix put the Jolly Roger raster on the bar because Straw Hat Pirates' shortcut was falling back to a generic glyph. B2 names that artwork among the five it wants quietened and reserves it for the destination *pages* - where `RailDestination.drillHeaderArtwork` still renders it on the drill header and the canvas card. The earlier fix's real requirement (bar icon and page cannot drift) still holds: both are renderings of one `RailDestination`. `checkBarDestinationIcons`' artwork assertion was inverted rather than deleted.
  - **The bell's badge moved *inside* the tile, and the distinction that makes that work is one both earlier attempts missed.** B2 asks for it "attached to the **symbol's** corner" - and a symbol's corner is not the tile's corner. The 14pt glyph sits well inside the 34pt tile's flat edges, nowhere near the 9pt radius that defeated `fm/grandline-notification-bell-badge-fix` (2pt overlap) and forced `-fix-2` to move the badge outboard entirely. A 1.5pt ring in the tile's own fill separates it from the glyph. That also delivers B2's other half for free: with the outboard badge zone gone, `NotificationBellButton.controlWidth == iconSize`, so the bell, the theme toggle and every shortcut are one 34x34 square by construction. The count abbreviates at 10 ("9+") because a badge that size carries one digit - the exact count is still spoken by the accessibility label and listed in the panel, and the suite asserts that.
- **B3 was a real, reproducible bug and its fix is two halves that each fail on their own.** `updateKeyViewLoop()` ended with `if window.initialFirstResponder == nil { window.initialFirstResponder = chain.first }`, and `chain` starts with the bar - so the first space pill became the window's initial first responder at launch and drew a `HoverHighlightView`'s `.exterior` ring beside a differently-decorated *selected* pill. Visible in every one of the audit's ~95 captures.
  - Half one: the initial first responder is the showing destination's own first key view. **On its own this only moves the stray ring from a pill onto the canvas's first module card.**
  - Half two: **`HelmFocusVisibility`** - a ring is for focus the captain *moved*. Full Keyboard Access always shows one; otherwise the ring appears only when `NSApp.currentEvent` at the moment focus is taken is a key event. **The mechanism is `currentEvent` rather than a keyDown monitor**, which (a) adds nothing for `LockGateCoverageSelfTest`'s monitor sweep to have to exempt and (b) is per-focus-change accurate rather than a latched "keyboard was used once" flag. **It has to be read in `becomeFirstResponder`, not `drawFocusRingMask`** - the latter runs in a later draw pass, by which point `currentEvent` is no longer the key event that moved focus.
  - **Scoped to `HoverHighlightView` only, deliberately.** That one class is both views that can realistically be focused before the captain touches anything (a space pill, a canvas card). `HelmButton`/`HelmPopUpButton`/`HelmStatTile` keep their GL-16 rings untouched: they live inside a page, below the first `HoverHighlightView` in the key loop, so none is ever the initial first responder.
- **B4's transition animates the *incoming* page only, and that is a stated deviation from the finding's own text.** §3B asks for "outgoing view fades to 0 / incoming from 0". Three things in the shell ask "which destination is on screen?" by looking for the one mounted view that is not hidden - `visibleDestinationView()` (which feeds `firstBodyKeyView()` and therefore the whole key loop, and returns the *first* match), plus accessibility and hit-testing - so keeping a second destination visible for 180ms makes all three answer wrong; and the alternative, snapshotting the outgoing page into a throwaway layer, puts a full-page `cacheDisplay` on the main thread on every navigation, which is the class of cost the same audit's §3 energy work went hunting. Both pages are opaque and cover the same rect, so a true crossfade would render them muddled through each other rather than cleaner.
  - Drill-in enters from +10pt, back from -10pt, 0.18s ease-out, `HelmMotion`-gated, skipped when the destination is already showing (the finding's own explicit requirement, and the reason `show(_:)` reads `currentDestinationKind` *before* `hideAllDestinations()` erases it).
  - **`NSAnimationContext.runAnimationGroup`'s body runs synchronously**, so the model transform is already back at identity when `show(_:)` returns - a frame read cannot prove the entry state happened. The suite asserts the recorded decision (`lastTransitionForTests`, including the offset actually applied) *and* that a real animation exists on the layer (`layer.animationKeys()`), which is the only evidence left.
- **B5: `HelmBarPanel` is `UnifiedSearchController`'s panel recipe extracted**, and all three bar dropdowns (Recents, notifications, avatar) use it - borderless, radius 16, window-owned shadow, no arrow, anchored under its control. Three things in it were each found rather than designed:
  - **The shadow has to be the window's** (`hasShadow`), never a layer shadow on the content view: that view clips, which is what makes the radius read, and a layer shadow inside a clipped view is drawn inside its own mask.
  - **The outside-click monitor must ignore clicks on the trigger.** A local `NSEvent` monitor sees the click before it is dispatched, so without that check a second click on the bell closes the panel and the bell's own action immediately reopens it. `UnifiedSearch` never hit this because ⌘K has no on-screen trigger.
  - **`constrainFrameRect(_:to:)` is overridden to hand back the frame unchanged.** AppKit constrains a window on the way to the screen so its titlebar stays reachable - correct for a document window, and for a dropdown it drags the panel away from the control it is attached to (measured: 157pt from where it was placed). `HelmBarPanel.position(under:)` does its own screen-aware clamping, and flips the panel *above* the control rather than sliding it over it. That clamp reads `anchorWindow.screen` with **no `NSScreen.main` fallback**, so an anchor on a second display never has its dropdown yanked onto the primary one.
  - **The lock gate moved with the mechanism**: `registerLockDismissiblePopover` exists because an `NSPopover` tracks its own shown state and ordering its window out leaves it permanently broken; a panel has none, so these use `registerSecondaryWindow` like the ⌘K palette. `LockGateCoverageSelfTest`'s popover-owner floor dropped 9 -> 8 with that reason written in; `FullAppAuditUISelfTest`'s stayed at 8 (now exactly the count) on purpose, so a ninth conversion has to come back and think about it.
- **Verified** by `swift build` (clean debug and release, zero warnings in the files this touched - seven pre-existing `#ImplicitStrongCapture` warnings in files it does not touch come from this sandbox's newer compiler), the release binary confirmed to carry no `FM_RUN_*` strings and none of the new probe symbols, real off-screen renders of the real bar on `daylight`/`dusk`/`helm-dark`/`gruvbox-light`, and the full suite (136 passed / 0 failed / 1 documented skip, `fm.themeID` unchanged) - **without launching the app**, per the README's worktree rule; the captain's own instance was running throughout. `FM_RUN_BAR_NAV_MODERNIZATION_TESTS` is window-backed and joins `run-all-tests.sh`'s `NEEDS_SESSION` list. **Seventeen injected regressions each reproduced by name** (scripted file copies, never `git stash` - see this file's own warning about the shared stash stack), including the original B3 bug itself.
- **Two environment notes, neither a code change, and the second one cost a CI round trip - read it before claiming a build is warning-clean.**
  - SwiftPM's default build system is `swiftbuild` now, which compiles the vendored Metal shaders and therefore needs a Metal toolchain that a CLT-only machine does not have. `swift build --build-system native` (the deprecated-but-present system, and the one that produces the `.build/debug/GrandLine` every suite runs) works. `run-all-tests.sh` invokes a plain `swift build`, so on such a machine use `--no-build` after building by hand.
  - **CI builds with Swift 5.10 (`.github/workflows/ci.yml`'s runner), and a treehouse worktree can have a much newer compiler - and they emit *different diagnostic sets in both directions*.** So "zero warnings in this app's sources", which this file claims in ~30 places, is only ever a claim about the compiler it was run on. Measured, on this branch: the newer local compiler emitted seven `#ImplicitStrongCapture` warnings in files the branch never touched (5.10 has no such diagnostic, which is why `main` is green there), while 5.10 emitted one the local compiler does not - `conditional downcast from 'NSView?' to 'NSView' does nothing`, in a brand-new file - and CI's gate makes any warning in `Sources/GrandLine` a **hard failure**. A local warning-clean build therefore does not imply CI is warning-clean. Two cheap habits close most of the gap: prefer the plainest form that compiles (no redundant `as?`, no unused binding), and treat a CI build failure whose only symptom is the warning gate as a *real* finding about your own diff rather than an environment quirk.

## The canvas is top-anchored, and Overview wears a hero band (C1 revisited)

**`fm/grandline-canvas-top-anchor-plan-b` is the captain's own override of C1's vertical half, taken after using what #376 shipped.** The finding offered three fixes; #376 built (a), *vertically centre the content*. He rejected it live - a page with an empty margin above **and** below reads as floating rather than composed - was shown a mockup comparing it against (b) a hero row and (c) a top-anchored canvas, and picked **(b)**, for all five spaces.

- **The vertical constraints are deliberately back to the pre-C1 shape, and both are required equalities.** `stack.top == document.top + contentTopMargin` and `stack.bottom == document.bottom - 44`. The bottom one is what makes the document exactly as tall as its content, which is in turn what makes a space taller than the viewport **scroll** - so it is load-bearing rather than symmetry, and relaxing it back to a `<=` leaves the document's height undriven. **`document.height >= scroll.contentView.height` is gone with the centring it existed for and must not come back beside them**: a document forced to fill a viewport it is shorter than, while also being exactly its content's height, is two required constraints in direct conflict. C1's *horizontal* half (leading `>=` / trailing `<=` / `centerX ==` plus the 499 `composedContentWidth` tie) is untouched - that part was never what the captain objected to.
- **"Plan B" means two different things for Overview and for the other four, and inventing hero content for the four would have been scope creep.** Only Overview has a verdict worth featuring; Command/Operations/Stores/Engineering just name themselves. So there the change is purely the top-anchoring - i.e. exactly what the report's own option (c) described - and their header renders as the plain row it already was.
- **`heroIsBanner` is `tint != nil`, which is the same predicate that already meant "this hero has no verdict".** `setHero(tint: nil, …)` is how a space with nothing measured is rendered (GL-14: Overview before its first fleet snapshot takes that branch too), and that is exactly when the band must not put a surface under it - otherwise a page that has measured nothing wears the same card as an all-clear. One flag, no second notion of "is this Overview".
- **The band's padding moves in `paintHeroBand`, not in `setHero`.** `select(space:)` calls `render()` → `renderGreeting()` → `setHero` *before* `loadView` on the very first selection, when `heroCardInsets` is still empty - so an inset applied there is silently dropped. `applyTheme` always runs after, and only ever with the view loaded.
- **The wash strength is derived per theme, never picked, and its floor is zero rather than the faintest step.** `heroWashFraction` walks a strongest-to-faintest ladder and returns the first fill where **both** the headline (`chromeInkHex`) and the detail line (`mutedInk`, flattened against *that fill* rather than against the page - its effective colour depends on what is under it) clear `HelmContrast.textTarget`. Measured: `solarized-dark` reaches only **4.47:1** on a 7% wash of its own green, i.e. even `HelmAccentRow.signalWash` - the value the ladder started with - is unaffordable there, so the honest answer is no wash at all. **9 of 14 palettes afford one; worst surviving copy contrast 4.50:1 (tokyo-night-light).** Zero leaves the band on the plain card surface, which `HelmCard` already guarantees is legible, and the hue still reaches the *border* - which is what separates the band from the page in the three themes where `chromeBackgroundHex == backgroundHex` anyway. The self-test asserts both directions: nothing illegible, and **not every palette flattened**, or an over-cautious edit could pass by rendering no band anywhere.
- **The hue reaches a fill and a border and stops there** (`HelmAccentRow`'s own `borderAlpha` and its `HelmContrast.mix` flattening - one idiom, not a second recipe; `NSColor.blended` converts into a *calibrated* space first and drifts from the sRGB composite alpha compositing actually performs). The copy stays `chromeInkHex`/`mutedInk`.
- **No new type size.** The brief asked for "larger type"; the headline is already `heroTitle()` (30pt, the app's largest role), so the step up is the *detail* line moving from `body()` (13) to `sectionTitle()` (15) on the space with a verdict. `HelmContrastSelfTest`'s type-scale table is a fixed list of roles on purpose, and a hero-only literal would be a fifth size in a scale this app spent a phase reducing to four.
- **A render cannot check any of this** - `cacheDisplay` draws a band and a bare row equally happily - so the layer is read instead, and the theme sweep goes through a `debugApplyTheme` hook rather than `ThemeManager.setTheme` (which writes through to the real preference and has poisoned whole suite runs). The sweep asserts the derived fill genuinely **reaches the layer** on all fourteen palettes, compared **component-wise**: `HelmContrast.ratio` is a luminance comparison, so two different hues of similar brightness pass it (a trap this codebase has walked into twice).
- **`test_c1ContentComposesTheSpace` was inverted, not deleted**, per this codebase's precedent for an assertion that has become a record of an overturned decision - it is `test_c1ContentIsTopAnchored` now, and reinstating centring has to come here and read why it went. Three cases joined it: tall content still scrolling (the one regression risk in removing the centring machinery), the band being Overview-only, and the wash ladder.
- **Verified** by `swift build` (clean debug and release, zero warnings in this app's sources), the release binary confirmed to carry no `FM_RUN_*` strings or the new probe hooks, the full `./Scripts/run-all-tests.sh` run (143 passed / 0 failed / 1 documented skip, `fm.themeID` unchanged), the documented `dusk` pre-flight, and real off-screen renders of the real mounted canvas on `daylight`/`helm-dark`/`gruvbox-light` for Overview and two sparse spaces - **without launching the app**, per the README's worktree rule (the captain's packaged instance was running throughout). **Five injected regressions each reproduced by name**: C1's centring restored (which reported the captain's own symptom - content 325.5pt down a 900pt window), the band never raised, the ladder falling back to the faintest step instead of no wash, the padding never applied, and the fill derived but never painted.

## The overflow "…" button drops a dead row, and skips a one-row menu

**The captain's own report:** *"All Destinations in icon shortcuts for hosts is not required (nothing is happening even now). Even that (…) will not be required since it's only Hosts now once we remove this."*
Both halves were right, and the first one was a real defect rather than a preference.

- **"Nothing is happening" was literally true, and the mechanism is worth writing down because it is invisible from every angle a review normally looks.**
  `DaylightBarController.quickAccessMenu()` built an "All Destinations…" `NSMenuItem` wired to `allDestinationsPicked()`, which called `onShowAllDestinations?()` on the bar, which `AppShellController` forwarded to its own `onShowAllDestinations` property - and **nothing in the app ever assigned that property.**
  An unassigned optional closure is not a crash and not a warning. The row rendered correctly, carried the right symbol, highlighted on hover, and did nothing when clicked. No build failed, no test failed, and a screenshot looks perfect.
- **The row is removed rather than repaired, which is what the captain asked for.** The overlay it wanted to open (`AllDestinationsOverlay.swift`, review #3's UX1) was never broken - ⌘⇧D and the Go menu reach it through `AppDelegate.showAllDestinations` directly and always worked. A third route into the same overlay, from a menu the captain had to open first, is not worth a wire.
- **The same defect had a second, unreported instance, and it is fixed rather than removed.** ⌘K's "All Destinations…" verb (`UnifiedSearchProviders`) is the *other* caller of that same never-assigned property, so it was equally dead. That one is a legitimate surface - a searchable palette is where a verb like this belongs - so `main.swift` now assigns `appShell.onShowAllDestinations` beside `onSearchTapped`, and the verb works for the first time.
  `NavigationCoherenceSelfTest.checkTheMapIsActuallyReachable` is a **source guard** on that assignment, deliberately: asserting the behaviour needs a real `AppDelegate`, which needs `NSApplication.shared`, and `NSApp` is nil in a headless suite where reading it *crashes* rather than fails. It carries its own vacuity sentinel (`onSearchTapped`'s assignment) so a moved file fails loudly instead of passing quietly.
- **One overflowing destination now navigates straight to it, with no menu.** This is the captain's "even that (…) will not be required", and it is the common case rather than an edge one: the shipped row pins seven against UX2's cap of six, so a captain who never opens the overlay met a one-row menu every single time.
  **The branch reads the count at click time and nothing else** - `quickAccessOverflowDirectDestination` is `nil` for any count but one, so a narrow window collapsing the whole pinned row still pops a real menu. That direction is the one worth guarding: a fix that assumed "the overflow is always Hosts" would quietly eat the captain's only route to six destinations the moment the window narrowed, and the suite injects exactly that mistake.
  The button's tooltip and accessibility label follow the branch (GL-16) - "More destinations" on a control that opens exactly one page describes the mechanism rather than the outcome, and it is all VoiceOver has.
- **The general overflow mechanism is untouched.** Review #3's B6 collapse behaviour, the menu, and every route through it are as they were; `Audit3BugFixesSelfTest`'s B6 case is extended rather than replaced, and now also asserts that a collapsed row still pops a menu.
- **Verified** by `swift build` (clean, zero warnings in this app's sources), the full `./Scripts/run-all-tests.sh` run before and after, a real off-screen render of the real mounted bar at 1512pt in a real `OffScreenProbe` window (the "…" button laid out at `(1296, 8, 34, 34)`, tooltip `Hosts`, and a real `performClick` reaching Hosts with no menu put up; the same bar with three overflowing destinations reporting a `nil` click target and a `["Hosts", "Tools", "Docs"]` menu) - the probe reverted before commit, per this repo's "Verifying native UI bugs" convention, and deliberately never touching `ThemeManager.setTheme` so it could not poison `fm.themeID`. **Five injected regressions each reproduced by name**: the dead row restored, the direct-navigation branch removed, the branch widened to `overflowDestinations.first` (the "assume it is always one" mistake - caught twice, by the collapsed row and by the multi fixture), the label left generic, and the `main.swift` assignment deleted again.

### The lone-overflow button wears Hosts' own icon, not the ellipsis

The change above was correct about the *click* and wrong about the *glyph*.
The button kept drawing the generic `ellipsis` symbol in the single-overflow case, with only its tooltip and accessibility label saying "Hosts" - so what the captain saw was a bare "…" sitting in the shortcut row where Hosts' icon belongs.
The captain's follow-up was one line: "Keep the host icon as it is in the shortcut menu."

- **An ellipsis is a promise of a menu.** On the single-overflow branch there is no menu, so the button is an ordinary shortcut and should look like one. Two or more overflowing destinations keep the ellipsis, because there the promise is true.
- **The glyph comes from `RailDestination.symbol` and `.domainHue`**, the same pair `DaylightDestinationButton` is built from, rather than a hand-picked second symbol. Hosts' icon in the overflow slot and Hosts' icon anywhere else in the app are one rendering, not two that can drift - the same reasoning that put `RailDestination.symbol` on the shortcut buttons in the first place.
- **`DaylightBarIconButton` gained `applyGlyph(symbol:hue:)`** for this, which made `symbolName`/`hue` `var` rather than `let`. One control with two identities is cheaper than two buttons swapped in and out, and it keeps the hover/active/theme machinery in one place.
- **Nothing else from the change above moved**: no menu popup on the single-overflow branch, the same direct-navigation click, and the same tooltip/accessibility-label branch.
- **Verified** by `swift build` (clean, zero warnings), the full `./Scripts/run-all-tests.sh` run before and after, and a new `Audit3BugFixesSelfTest` case that mounts the real bar in a real `OffScreenProbe` window and compares the overflow button's **rendered bytes** against a freshly built `DaylightDestinationButton(destination: .hosts)` - pixel identical - while also proving those two references genuinely differ from a plain ellipsis button, so the comparison cannot pass vacuously. A click-target assertion could not have caught this: the sibling case passed throughout the defect. **The regression was injected and reproduced by name**: with the `applyGlyph` call removed, the render assertion failed at 1823 differing bytes, alongside the symbol-name and ellipsis checks.

## The shortcut row wears coloured icon tiles (`fm/grandline-topbar-icon-tiles`)

**The captain's ask**: give the top bar's quick-access row the coloured icon tiles #458 had just given the Settings sidebar, instead of the plain monochrome glyphs it had.
The screenshot behind it is `data/grandline-topbar-icon-tiles/captain-screenshots/129-current-monochrome-topbar.png`.

This reverses half of B2 above, so the half it reverses is worth stating precisely.
B2's finding was that the row carried **three icon languages at once**: grey SF Symbol squares, five saturated raster app icons with their own dark backgrounds, and a gradient disc.
That is still fixed and is not what changed.
There is one geometry, one radius, one recipe, and the raster artwork still lives only on the destination pages.
What changed is that the single language is coloured rather than grey, for the reason `HelmPageSidebar.RowIndicator.tile` already records for a column of eight rows: a row of same-coloured glyphs is something you read, and a row of coloured tiles is something you scan.

### The colours are not new, and that was the first thing checked

`RailDestination.domainHue` is already this app's per-destination identity table (Daylight §2.2's "Owns" column), and it is what the tiles use.
Blue for the reading destinations, teal for the running systems, rose for Tasks and Dictation, violet for the AI surfaces, amber for Setup and Sticky Board, green for the merge queue and the Reading List, slate for Settings and Tools.
Inventing a second table on the bar is exactly how a bar icon and the page it opens come to disagree about a colour, which is the defect `RailDestination.symbol` was put on these buttons to prevent in the first place.

Two candidates were rejected.
`RailDestination.flyoutTint` is the rail's legacy `HelmTint` and is `.accent` for every destination but five, so it differentiates nothing.
A fresh literal table would be a second source of truth for a question the app already answers.

**A consequence worth knowing before someone reports it as a bug**: the hue belongs to the *area*, not to the page, so Console and Hosts are both teal and Sticky Board and Poneglyph are both amber in the shipped row.
That is the same decision that gives the four Setup pages one hue, and the glyph is what distinguishes within an area.

### The per-palette split is load-bearing, and it costs something

`DaylightBarIconButton.tileHex(for:in:)` resolves the §2.2 identity hue on the Daylight family and the palette's own corresponding `HelmTint` slot (`fallbackTint`) on the other 24.
That split matches `UnifiedSearch`'s destination tile exactly, which is the app's other place that draws a `RailDestination` as a colour tile.

It is not a convenience.
`identityHex` alone resolves to `HelmTint.neutral` off Daylight, and neutral *is* `chromeInkHex`, so washing it as a tinted surface produces the near-black chip AGENTS.md warns about, eleven times in a row, on 24 of the 26 palettes.
That was injected and the suite reported it as "the row's 6 shortcuts render only 1 distinct tile colours".

The cost is recorded rather than hidden.
`fallbackTint` maps rose onto `.critical` and amber onto `.warn`, which are *semantic* slots, and `RecentDestinationsPopover.makeRow` names routing an identity through it as a defect.
That objection is about an accent **bar**, where one red edge among grey ones on a benign list reads as an alarm.
It does not transfer to this row, where every shortcut carries a tile and the set therefore reads as a categorical palette.
Nothing here is the one coloured thing among neutral siblings, which is the mechanism by which a hue comes to be read as a signal.
Measured on `gruvbox-dark`, Console and Hosts render orange because that palette's own accent is orange, and the row still reads as seven distinct identities rather than as seven warnings.

### State became the wash's depth, and the geometry did not move

Every state is `HelmContrast.tintedSurface` over the button's own hue, which is the one recipe `IconTileView` uses, so the fill and the glyph on it are corrected to the 3:1 non-text floor by the shared helper rather than by a second copy of the maths.
State is then the *depth* of that wash: resting at the shared `tileWashSteps`, hover at `hoverTileWashSteps`, active at `activeTileWashSteps`, each independently corrected, with the ring's alpha strictly increasing across the three.

The rejected alternative was one fill lightened on hover.
It cannot promise the floor, because lightening a fill moves it toward the glyph on a dark palette and away from it on a light one.

**Nothing about the row's geometry changed**, which was the explicit risk in the brief.
No constraint was touched, `DaylightBarIconButton.side` is the 34pt it was, and the tile is the same `iconBackground` subview at the same 9pt radius that was already there.
`checkRowFootprintIsUnchanged` asserts the numbers as **literals** rather than re-deriving them from the code under test, because a guard that reads `DaylightBarIconButton.side` for its own expectation cannot fail when that constant moves.

### Which buttons got a tile, and which did not

The rule falls out of the data rather than out of a list: a button gets a tile when it carries a `HelmDomainHue`, and keeps the plain chrome square when it does not.

- **Tiled**: the six quick-access shortcuts, and the overflow button while it is drawing a single overflowing destination's own icon (the branch `fm/grandline-hosts-shortcut-icon-fix` added, which already hands it that destination's symbol and hue).
- **Not tiled**: the theme toggle, Recents, the clipboard history, and the overflow button while it is drawing the generic ellipsis. None of them opens a destination, so there is no hue that honestly identifies them, and a colour there would be claiming an identity the control does not have. Keeping them plain is also what lets the tiles beside them read as "these are places you can go".
- **Untouched**: the notification bell and the avatar, which are not `DaylightBarIconButton`s at all. The bell owns its badge geometry and the avatar is a gradient disc, both deliberately separate before this change.

`restyleAsPlainSquare` is the pre-tile rendering kept verbatim for that second group, so the exempt controls are byte-identical to what shipped.

### Verification

- **`DaylightBarIconTileSelfTest` (`FM_RUN_BAR_ICON_TILE_TESTS`) is new, and is pure logic rather than window-backed**: it reads layer colours and frames off a hand-laid-out `DaylightBarController` and drives hover through `debugSetHovering`, so it guards the **blocking** CI lane and is deliberately not in `NEEDS_SESSION`. Six cases: the per-destination colour, a 26-palette x 7-hue x 3-state legibility sweep, the state ladder, the exempt controls, both of the overflow button's identities, and the footprint guard.
- **Five injections were each confirmed to fail by name**: the pre-fix rendering restored (three cases failed), every tile painted one hue, the per-palette split dropped for a bare `identityHex` (which is the near-black-chip defect), the theme toggle given a hue, and `DaylightBarIconButton.side` widened by 6pt.
- **`BarNavigationModernizationSelfTest`'s B2 hover case was narrowed rather than deleted.** It used to demand the hovered glyph be the *raw* `identityHex`, which was true while the glyph sat on the plain chrome square. The glyph now sits on a wash of its own hue, so asserting the raw hue would be asserting the exact pairing `HelmContrast` exists to forbid. What survives is the claim B2 actually makes, that the glyph is a rendering of this destination's own hue rather than of ink, measured as the pair `tintedSurface` produces.
- **Real off-screen renders** of the real row at 1512pt on `dusk`, `daylight`, `helm-dark`, `catppuccin-latte`, `gruvbox-dark` and `nord-polar`, read back as PNGs. The probe was reverted before commit and never touched `ThemeManager.setTheme`, so it could not poison `fm.themeID`.
- **Full `./Scripts/run-all-tests.sh` before and after**: 204 passed / 0 failed / 1 documented skip at the baseline, and the same plus the new suite afterwards.

**One trap this cost real time on, for anyone writing a fixture against this bar.**
`DaylightBarController.setQuickAccess` rebuilds the row and ends by re-applying `ThemeManager.shared.theme` to every square.
A fixture that themed the bar *first* therefore had its choice silently replaced by whatever theme is ambient in the test process, and measured the overflow button's tile in a palette nobody asked for.
It reads as a colour bug in the button.
Apply the theme last.
The same fixture pins its own `QuickAccessConfiguration` rather than inheriting `AppSettings.shared.quickAccess`, which is the captain's real stored list and would make "the row shows at least three distinct hues" a claim about their pins rather than about this fix.

## The terminal shortcut borrows Settings' own Terminal tint (`fm/grandline-topbar-terminal-icon-color`)

**The captain's ask**, a one-line follow-up to the row above: the top bar's Console shortcut should be the same colour as the Terminal row on the Settings sidebar.
The screenshots are `data/grandline-topbar-terminal-icon-color/captain-screenshots/134-topbar-current.png` and `135-settings-terminal-color-wanted.png`.

Console's tile was teal, because `RailDestination.domainHue` gives teal to the running-systems area as a whole - the consequence the entry above wrote out in advance.
`DaylightBarIconButton.tileTintOverride(for:)` is the exception to it, and it is deliberately one entry rather than a second table: it returns `SettingsController.Category.terminal.tint` itself, so the two tiles are one value and an edit to either side cannot drift them apart.
`RailDestination.domainHue` is untouched, so Console's page, its drill header and its canvas card are all still teal - this is the bar's tile alone.

**The override resolves unbranched, and that is the whole of the fix.**
A tint is `HelmTint.neutral.hex(in:)` on all 26 palettes, which is exactly how `IconTileView` resolves Settings' own tile.
It deliberately does not take `tileHex`'s Daylight/non-Daylight split: that split exists so a §2.2 *identity* hue survives on a palette with no such table, and this is a borrowed tint rather than an identity.
Expressing the same idea as `HelmDomainHue.slate` was the obvious-looking alternative and is wrong in the one family that matters here - it agrees with Settings on the 24 fallback palettes (`slate.fallbackTint` is `.neutral`) and diverges on Daylight itself, where it resolves to `8B8677`, a warm slate, against Settings' cool `2A2B33`.
The captain's screenshot is a Daylight-family palette.

**Verification.** `DaylightBarIconTileSelfTest` gained one case asserting three separate claims - that the override *is* Settings' tint, that it resolves identically in all 26 palettes while every other shortcut still takes its own domain hue, and that the tile really paints that colour on both sides of the split - plus its own discriminating-power guard, so a future world in which Console's domain hue simply became neutral fails the case rather than passing it vacuously.
The 26-palette legibility sweep now covers borrowed tints as well as the seven domain hues, which is the half that needed it: `.neutral` is `chromeInkHex`, so its wash is the pairing AGENTS.md's colour rules warn about.
Two injections were each confirmed to fail by name - the override removed (the tint check and the sweep's own vacuity guard), and the override routed through `HelmDomainHue.slate` (`daylight: the terminal shortcut resolves #8B8677 where Settings' Terminal row resolves #2A2B33`).
**Scoped local run, per this repo's own convention**: `swift build` clean plus `FM_RUN_BAR_ICON_TILE_TESTS` and `FM_RUN_BAR_NAV_MODERNIZATION_TESTS`, which are the two suites that assert this button's tile at all. CI's full run is unchanged and still gates the merge.

## The tiles get told apart, and the bar's own controls get tiles (`fm/grandline-topbar-icon-tiles-round2`)

**The captain's ask**, a follow-up to the two entries above, against `data/grandline-topbar-icon-tiles-round2/captain-screenshots/143-current-topbar.png`.
Two complaints.
Three icons had no coloured tile at all - Recents, the theme toggle and the notification bell.
Three others rendered in warm amber/tan tones he could not tell apart at a glance, which he named as Docs, Hosts and Schedules.
His guidance on colour was that it should mean something rather than be arbitrary, with Console's grey tile as the example he liked, "because for terminal the black one actually makes sense".

### The three that looked alike were not a colour-choice problem

The report named Docs, Hosts and Schedules, and those three were never the same colour in §2.2's table: `RailDestination.domainHue` gives them blue, teal and violet, and has since the Daylight migration.
Reading the screenshot against the captain's own `fm.themeID` (`ayu-dark`) and the default pin list found the real trio: **Hosts, Poneglyph and Sticky Board**, sitting in one warm tan with only Console between two of them.
He named the destinations from the glyphs, and a closed-book glyph reads as Docs.

The cause is the *resolution*, not the hues.
`DaylightBarIconButton.tileHex` resolved a domain hue through `HelmDomainHue.fallbackTint` on the 24 non-Daylight palettes, which maps §2.2's seven identity hues onto seven `HelmTint` slots.
That map is 1:1, but **a palette is under no obligation to make those seven slots seven colours**.
Ayu publishes a single amber and spends it as both `accent` and its ANSI yellow, so teal (Hosts) and amber (Poneglyph, Sticky Board) resolved to the same tile.

Measured as a washed tile over all 26 palettes, the closest pair of domain hues came out **literally identical** (distance 0.0000 in weighted RGB) on eight palettes and under a 0.035 separation floor on fourteen:

| Palette | Closest pair | Distance |
|---|---|---|
| `tokyo-night-dark`, `tokyo-night-light`, `dracula`, `alucard`, `one-dark`, `oxocarbon-light` | blue / teal | 0.0000 |
| `rose-pine-main` | teal / violet | 0.0000 |
| `rose-pine-dawn` | teal / green | 0.0000 |
| `helm-light` | blue / teal | 0.0173 |
| `nord-snow` | blue / teal | 0.0203 |
| `ayu-dark` (the captain's) | teal / amber | 0.0215 |
| `one-light` | blue / teal | 0.0281 |
| `ayu-light` | teal / amber | 0.0305 |
| `light-owl` | teal / green | 0.0343 |

So the fix is one line of resolution and no new colours: `tileHex` now returns `HelmDomainHue.categoricalHex` - §2.2's own `h1` verbatim - on **every** palette.
The same sweep against those values has a worst pair of **0.0568** and nothing under the floor, with the 3:1 non-text legibility floor still held in all three ladder states (worst 3.0000, `nord-snow`/violet/active).
Docs stays blue, Hosts stays teal and Schedules stays violet, which is the point: the bar was already drawing the app's established identity table, and what it needed was to stop laundering it through a vocabulary that has no room for seven identities.

**The objection `HelmDomainHue.identityHex` records does not apply to a set**, and that is why this is allowed here and not everywhere.
That property falls back to neutral off the Daylight family because one rose accent bar among grey siblings reads as an alarm - a hue becomes a *signal* by being the coloured thing among neutral things.
Where every member of the set carries a tile, nothing is the coloured one and the row reads as a categorical palette instead.
The entry above had already written that argument out for `fallbackTint`; this extends it one step, to the raw table.

**`UnifiedSearch` deliberately still splits, and that is not a drift to reconcile later.**
Its palette row draws one destination tile per *result*, in a list that is mostly not destinations at all, so a result carrying a raw §2.2 hue on a palette with no §2.2 vocabulary really would be the one coloured thing among neutral siblings.
This row draws all seven at once and nothing else.

### The three with no tile

They had none because the previous entry's rule was "a button gets a tile when it carries a `HelmDomainHue`", and these three carry no destination.
The captain overruled that, and he is right: two unexplained grey squares at either end of a row of coloured tiles read as unfinished rather than as a category.
Each of the three got a deliberate hue rather than a default.

- **Recents → `.slate`** (`DaylightBarIconButton.chromeTileHue`). It opens a *panel*, not a page - a way back to a place rather than a place. Slate is the hue §2.2 already gives Settings and Tools, the two destinations that are about the app rather than about the captain's work, and `HelmDomainHue`'s own comment calls it the one slot that claims nothing. A control painted in some destination's identity hue would promise navigation it does not offer, which is the captain's own "avoid confusion with an actual destination tile".
- **The theme toggle → `.slate`**, the same hue and the same reason: appearance is the app's own chrome, and it is Settings' subject. One hue for both states a rule the row can be read by - **a coloured tile is a place, a slate tile is the app itself**. The two sit at opposite ends of the shortcut row rather than side by side, so sharing it costs no legibility.
- **The bell → `.amber`** (`bellTileHue`). The one bar control that is not chrome, because it is the only one asking for something: the panel behind it is this app's "Waiting for you" list. Amber is already this app's attention hue - §2.2 gives it to `dailyOverview` ("here is your day") and `DaylightModule.briefing` carries it.

**The rejected alternatives are worth recording, because both were the obvious pick.**
The theme toggle wanted the palette's own `accentHex` - a control whose entire subject is the active palette, painted in it. That collides with Hosts on half the palettes, since teal's `fallbackTint` *is* `.accent`: the same defect this branch exists to remove.
The bell wanted `.rose`/`.critical`. A bell at rest is not an alarm, and this app already has a louder signal for the case that is - the badge, fixed white-on-`systemRed` and never theme-tinted precisely so it reads as urgent on every palette. A permanently red tile spends that signal on an empty list and leaves the badge nothing to add.

Console's tile was **not touched**, on the captain's explicit instruction. Its borrowed `HelmTint.neutral` is swept alongside the seven hues in the new separation check, because a hue colliding with *it* is the same defect; the closest the two ever come is 0.0568.

### What is still a plain square, and one thing that is not a decision

The overflow button drawing its generic ellipsis keeps `restyleAsPlainSquare`: it opens a menu rather than a surface, so it has no identity to paint, and it still takes a real tile in its other identity.

The clipboard-history button is also still plain, and that is **not** a design decision - it is recorded here so it is not mistaken for one.
That button is laid out with no width or height constraint at all, unlike every other square on the bar, so it resolves to its intrinsic size and does not render; it is absent from the captain's screenshot for that reason.
It is also absent from `DaylightBarController.iconSquares`, so it never receives the bar's `applyTheme` either.
Colouring a control nobody can see would be dressing up a separate bug, and making it appear is a visible change to the bar that nobody has asked for.

### Verification

- **`DaylightBarIconTileSelfTest` gained three cases.** `checkTheBarsOwnControlsAreTiled` asserts each of Recents, the theme toggle and the bell paints the wash of *its own declared hue* on four palettes (both Daylight halves, the captain's `ayu-dark`, and a light non-Daylight one), with its own discriminating-power guard first - that the expected wash is not already the plain chrome square, which would make every assertion after it vacuous. The bell is checked hardest of the three because it is a `NotificationBellButton` and shares none of the tile code: its fill, its contrast-corrected glyph, its ring alpha, and its badge ring following the tile rather than the old chrome surface. `checkEveryPaletteKeepsTheHuesApart` is the sweep in the table above, kept. `checkTheCaptainsThreeAreTellableApart` names Docs, Hosts and Schedules, asserts each still carries §2.2's own hue with no override, and fails in the captain's own wording.
- **The sweep proves it can fail without reverting anything.** It re-runs itself against the replaced `fallbackTint` resolution and fails if *that* no longer collides - a separation floor nothing can breach is the one failure mode a sweep like this has. The floor, 0.045, sits above every measured failure (worst 0.0343) and below the tightest pass (0.0568).
- **Three injections were each confirmed to fail by name**, by copying the file aside and editing it rather than by `git stash`: the resolution reverted to the split (`helm-dark: slate and override:neutral both render rgb(0.21, 0.23, 0.26) ... 0.0000`, plus `helm-light: Docs ... and Hosts ... 0.0173 apart`), Recents' hue removed (`daylight/Recently Visited paints rgb(0.95, 0.94, 0.91), expected the slate wash`), and the bell returned to the plain chrome square (`the bell paints rgb(0.95, 0.94, 0.91), expected the amber wash`).
- **Real off-screen renders** of the real bar at 1512pt on `ayu-dark`, `dusk` and `daylight`, read back as PNGs - which is how the trio in the captain's screenshot was identified in the first place, and how the fix was eyeballed. The probe was reverted before commit and never touched `ThemeManager.setTheme`, so it could not poison `fm.themeID`.
- **Full `./Scripts/run-all-tests.sh`: 207 passed, 0 failed, 1 documented skip.** This is a cross-cutting change - a shared resolution function plus a component every page's bar draws - so the scoped local run the entry above used would not have been enough. No separate *before* pass was taken, and that is stated rather than implied: a sibling worktree was mid-run at dispatch and this repository forbids two concurrent passes (they interleave each other's `fm.themeID` save/restore), and the branch point is `main` at `9637a91` with CI green. `fm.themeID` was `dusk` before and after.

**The separation measure is weighted RGB, deliberately not `HelmContrast.ratio`.**
That helper compares relative *luminance*, so two different hues of equal brightness score as identical - which is the exact defect being measured, so a luminance check here would be blind to it by construction.
AGENTS.md already records that trap in the other direction; this is the same rule applied to a distance rather than to an equality.

---

## The Home page rebuilt against the captain's reference (`fm/grandline-home-page-visual-overhaul`)

The captain called the shipped Home page "not at all great" and supplied a reference: a static HTML/CSS/JS mockup plus two screenshots.
The ask was stronger and more literal than the narrower task before it (PR #491, which only moved "Needs Attention" onto Home): the cards, the layout and the visual language of the whole page were to match.

### The two screenshots are not what the brief said they were

The brief described both PNGs as renders of the mockup, one light and one dark.
They are not.
`reference-dark.png` is the mockup; `reference-light.png` is the **current app** - which is to say, the state being complained about.

That is settled by the file rather than by eye.
The mockup's HTML contains exactly one `<section class="card attention">` and its script never adds a second, while the light screenshot shows two stacked attention cards - the hero band over the Needs Attention card, which is precisely what this app drew.
Rendering the real Home page off-screen at 1512pt confirmed it pixel for pixel: same top bar, same three-column masonry, same pair of cards.
The mockup's CSS also has no card top-ribbon at all, and the light screenshot's cards each wear one, which is `HelmModuleCard.ribbon`.

So the work was done against the HTML and the dark PNG, which agree with each other completely.

### What already matched, which was more than expected

Overview's module set was **already exactly the reference's five** - `DaylightModule.appearsOnOverview` had been trimmed to `.briefing`, `.claudeStatus`, `.fleet`, `.mergeQueue`, `.health` by `fm/grandline-home-card-reorg`.
The Claude card's sectioned usage report, the Health card's `HelmRingGauge`, the chips, the icon tiles and the attention rows' `HelmAccentRow` shape were all already in place.
Nothing in the reference needed a new component except one layout primitive, and the reference's own inline hexes were never used - every colour resolves through `HelmTint`/`HelmDaylight` as before, so the result themes across all 26 palettes rather than the reference's two.

### 1. The grid: a dashboard is not a wrapping shelf

`HelmResponsiveGrid.rows(_:)` and `spanningRows(_:)` both *derive* their column count from the container's width.
That is right for a shelf of interchangeable navigation cards and wrong for Overview, whose five widgets have hand-picked relative sizes that **are** the design.
At the captain's 1512pt the wrapping grid resolved to five 255pt columns and packed the five cards as 2+2+1 / 1+1 - the ragged masonry in his screenshot, with most of the third row empty.

`HelmResponsiveGrid.proportionalRow(views:spans:…)` is the new primitive, built once: twelve tracks, an explicit span per card, widths at `HelmDaylightPriority.contentTie` (499) so no card can become a window-width floor (gotcha (13)), and the stack yielding both its clipping resistance and its hugging for the reason `spanningRows` already records (gotcha (12) - a stack resists clipping at 750, above `NSLayoutPriorityWindowSizeStayPut`).

The reference expresses the layout as a 12-column CSS grid with the Claude card spanning two rows.
A card spanning two rows *beside a column holding exactly those two rows' cards* is the same layout, and it is the one Auto Layout can state without a second placement axis - so row 1 is `[Claude(7) | column of [Briefing, Fleet](5)]` and row 2 is `[Merge queue(7) | Health(5)]`, each row equal-height tied.
That is also what puts the bottoms of Claude and Fleet on one line, and the tops of Merge queue and Health on another, exactly as the reference draws them.

`fitsProportionally` is the single decision point for "dashboard or wrapping grid", and it is arithmetic rather than a literal breakpoint: below about 635pt of content width a 5-track card is narrower than one wrapping column, and the page hands back to `spanningRows`, which already collapses to one card per row.
The hand-placed path also declines when the visible module set is not the five it was written for - `appearsOnOverview` is a captain-editable list, and a sixth card must render somewhere rather than silently vanish.

### 2. One card at the top, not two

The reference draws a single attention card: tinted icon tile, eyebrow, headline, freshness subline, and Refresh on the right, over the item list, over an "Everything else is clear" strip.
The app drew a hero band saying "Nothing needs you right now / Fleet read just now" **over** a Needs Attention card saying "All clear / Nothing is due" - two cards reporting two halves of one question, which is the duplication review #3's UX5 objected to on this very page.

So `heroCard` is hidden on Overview and `NeedsAttentionCard` absorbed its three parts.
The first pass at that card had listed all three as deliberate omissions; every one of those reasons rested on the band existing above it, and the merge removes the reason rather than the caution.

`NeedsAttentionCard.onRefresh` is `nil` by default, so the card is byte-identical for any other host.

**The hero *band* is deleted, not merely unused.** Its washed surface, its border, its `heroBandPadding` and the per-theme contrast ladder that picked its fill (`heroFill`/`heroWashFraction`/`heroWashSteps`) had exactly one caller - the hub - and `heroIsBanner` could no longer be true anywhere.
Leaving a colour derivation behind a permanently-false flag would have left `test_c1HeroWashStaysLegible` asserting code nothing called, which is the "a check that cannot fail" failure one level up.
The four other spaces still draw the plain header row they always did, and `test_c1HeroBandIsOverviewOnly` now asserts that half - four spaces with a row, the hub with none - so it is not a check that a view is simply never built.

### 3. The other three attention sources needed no plumbing

The reference lists the fleet, Claude usage and session checks alongside tasks and follow-ups.
The first pass omitted them on the reading that they would mean new fetching on a page whose first rule is that it never fetches.
That turned out to be wrong: every one of those readings is **already pushed into `HomeCanvasController`** for a card it already draws - the fleet snapshot for the Fleet card, the quota reading for the Claude card, `BackgroundSignalsPoller.lastCounts` for the Setup cards, `ServiceHealthRegistry` for Health.
They arrive as `NeedsAttentionItem`s the controller builds, which is the shape that file was already documented as being open to.

Three things fell out of it:

- **`NeedsAttentionItem.headlineClause`.** Tasks are counted ("Two things are late"); a signal is named ("Claude is near its spend cap"), because a count of one unnamed thing tells the captain nothing. Putting the clause on the item is what stops the headline growing a `switch` over sources.
- **The session-checks row is gated on the poller having finished a pass.** Its first pass lands about ten seconds after launch and this page is the launch landing, so without the gate the hub opened on "Needs attention, 1: one check is waiting" every single time, for ten seconds, about nothing - a false alarm on the one card whose job is to be believed. It is the same distinction `applyPendingSetupSignal` already draws for the four Setup cards.
- **`FleetGreeting.Answer.metaRestatesCards` is the wrong predicate for "is the fleet fine", and using it was a real GL-14 regression.** That flag is a statement about the *detail line*, and it is `true` on the partly-unknown branch where the PR scan failed - so a hub that could not reach the forge fell back to "All clear" over a reading it had not taken. `answer.tint != .good` is the correct test; `DaylightModuleSelfTest` caught it, which is the second time that case has paid for itself.

### 4. Two small card additions, both on the shared component

- **`HelmModuleCard.Body.tiles`** for the Fleet card's Working / Done today / Queued triptych. `HelmStatTile`, which the component index names as the one stat tile, and the three counts are `FleetController`'s own `statsRow` fields rather than a second arithmetic.
- **`HelmModuleCard.Content.footer`** for the Merge queue's "Showing 3 of 33" and "View all 33 open". Worth having beyond the reference: the card shows at most `maxPeekRows` of however many are open and said so nowhere, which is a milder form of GL-14 - a truncation drawn as a whole. Only rendered when there genuinely is more than the card is showing.

### Verification

- **`HomeDashboardSelfTest`** (pure logic, CI's blocking lane): the closure property that a row of spans summing to the track count lays out to *exactly* the container width, at five widths including an odd one and a half-point one (AGENTS.md's 1x/2x rounding rule); the 7:5 ratio as track arithmetic; both sides of the narrow threshold; and `sentenceList`'s serial comma. Each has its own discriminating-power guard first.
- **`HomeDashboardViewSelfTest`** (window-backed, in `NEEDS_SESSION`): the hub has no header row and the four other spaces do; two rows of the right shape; the resolved 7:5 frames with a `1 / backingScaleFactor` tolerance; the narrow degrade; the Fleet tiles' and Merge footer's real numbers; and Daylight against Dusk with a component-wise check that the two surfaces really differ.
- **Four injections, each confirmed to fail by name**, done by copying the file aside rather than by `git stash`: `usesDashboardLayout` forced false (`row 1 holds two members, got 3`), the hero band un-hidden on the hub (`the hub's hero band should be gone`, plus both rewritten C1 cases), the footer never un-hidden (`exactly one card carries a footer, got 0`), and `proportionalWidth` dropping the gutters a span swallows (`should lay out to exactly 1468.0, got 1308.0`).
- **Real off-screen renders** of the real page at 1512pt in Daylight and Dusk, seeded with the reference's own fixture (the two overdue records, a 94% extra-usage reading against a $150 cap, 33 open PRs), read back as PNGs and compared against `reference-dark.png` structurally. That is what caught two defects the suite would not have: the Claude row's chip reporting `1%` for a 94% cap (`claudeSpendFraction` is 0…1 and `percentText` takes a percentage), and the first-run invitation copy rendering as the subline *over a list of four rows*. The probe was deleted before commit.
- **Full `./Scripts/run-all-tests.sh`: 227 passed, 0 failed, 1 documented skip** (`FM_RUN_WHISPER_METAL_FALLBACK_ONLY_TEST`). This is a cross-cutting, whole-page change, so a scoped run was never an option. The **first** pass failed one suite and it is worth recording which: `FM_RUN_READY_TO_MERGE_TESTS` reads the hub's freshness line to prove the hub does not restate the merge-queue card's count, and that line had moved onto the attention card - so the assertion was comparing against an empty string and would have gone on passing for the wrong reason if it had been written any weaker. A targeted run had missed it because it was invoked as `FM_RUN_READY_TO_MERGE_COUNT_TESTS`, which is not a variable and therefore ran nothing and printed nothing. The full run is what caught both.
- **`swift build -c release`**, which caught `debugTiles` reaching `HelmStatTile.debugMetric` across the `#if FM_SELFTESTS` boundary - exactly the gate AGENTS.md says finds that. Worth noting in passing: `HelmModuleCard`'s probe block is *itself* unguarded against GL-27 and gets away with it only because nothing else in it reaches a guarded symbol. Not fixed here.

### What was deliberately not matched

- **The clear strip's chips are readouts, not buttons.** The reference's scroll the matching widget into view; here that widget is already on screen a few hundred points below, and a control whose whole effect is to scroll to something visible is a dead control (gotcha (20) is about how expensive those are to notice).
- **The chips carry no checkmark glyph.** `ToolRowLayout.pill` is the house pill and takes text only; adding a glyph slot for one caller would be hand-rolling a second chip.
- **Attention rows keep D1's reveal-on-aim** for their Start/Open buttons above `HelmAccentRow.alwaysRevealRowCount`, where the reference shows them always. That is a prior deliberate decision about every list in the app, not something this page should overrule on its own.
- **Merge queue rows keep the mono value face** `.peekRows` gives every card, where the reference sets "Checks green" proportionally.

## The top bar's active and pressed states (`fm/grandline-bar-active-state`)

The captain reported that Hosts and the light/dark toggle never showed their colour, while Console and the other shortcuts did.
That was three separate causes, not one.

### What was wrong

- **Hosts is drawn by the overflow control.**
  It is the seventh of the seven default pins against UX2's cap of six, so it is never a `DaylightDestinationButton`.
  `setActiveDestination` only asked those buttons, so the square standing for Hosts could never light.
- **The active state was pushed, not kept.**
  `show(_:)` and `revealHostConsole` each pushed it, and the SRE Lead reply-jump pushed nothing, so the previous page's square stayed lit over a host page.
  The bar kept no copy either, so a pin change (which rebuilds every shortcut) or a resize across `quickAccessCollapseWidth` came back with nothing lit until the next navigation.
- **A real press drew nothing.**
  The pressed state hung off `highlight(_:)`.
  AppKit's own tracking loop highlights the button's cell and never calls that on the control, so only `performClick` reached it.
  Measured with real mouse events posted through the app: with only the `highlight(_:)` hook, a real click never entered the pressed state.
  Even where it did fire, the only effect was a 2% scale.

The toggle had no state at all to show, and its half-filled circle looked the same in both modes.

### The rule now

- A square is lit (its hued tile, at the active ladder) while its page is open, by whatever route the page was opened.
  The overflow control is lit when the open page is one it stands for, in that destination's hue when it draws one, and in `chromeTileHue` while it is a collapsed row's menu.
- The bar keeps the active destination and re-applies it after a rebuild or a collapse.
  The shell pushes it from `updateRecentDestinations`, the one call every navigation route already makes, and a source guard asserts it is the only push site.
- A held press draws the square's tile at `pressedTileWashSteps`, one ladder deeper than the active one, with a full-alpha ring.
  That reads on a page that is already open too.
  It comes from `mouseDown` (HelmButton's shape) and from `highlight(_:)` (the keyboard's `performClick`), through one `setPressed`.
- The light/dark toggle is an action, so it never lights.
  It presses like every other square, and shows the current appearance as a monochrome `sun.max` or `moon` glyph, with the matching VoiceOver value.
  The glyph names the mode that is on, the Control Center convention, and the tooltip names the other one.
- VoiceOver hears "current page" as the lit square's value.

### Verification

- `FM_RUN_BAR_ACTIVE_STATE_TESTS` (window-backed) opens every pinned destination in Daylight and Dusk and asserts exactly that square is lit, in its own active tile.
  It also covers Recents, a space pill, the bar's own clicks, a host page, a pin change and a collapse, reads the pressed tile while AppKit's tracking loop is running, and checks the toggle's glyph, value and press.
- **The press case's first version failed on CI's windowed lane and passed locally.**
  It posted a mouse-down/mouse-up pair to the app's queue and let the app dispatch them.
  On the runner the window is not key, and the first click into a non-key window is consumed by AppKit's activation and first-mouse handling before the button sees it, so "a real click on the Hosts square never entered the pressed state".
  The later toggle click in the same run passed, which fits that reading.
  The case now calls the button's own `mouseDown(with:)` with a real event and puts the matching mouse-up on the process's own queue for AppKit's tracking loop to consume.
  The fixture window is never made key or ordered front, which is the runner's situation, and nothing waits on a clock.
- **One measurement that changes how to read the injection below.**
  A stock `NSButton`'s own `mouseDown(with:)`, called directly, returns at once without tracking, because AppKit drives a stock button's press from a gesture recognizer inside `NSWindow.sendEvent`.
  Overriding `mouseDown` is what makes `super` run the cell tracking loop.
  So with the override removed, the direct-call case fails twice over: no pressed state, and no action.
  The posted-event measurement above is the evidence that `highlight(_:)` alone is not enough.
- `DaylightBarIconTileSelfTest`'s 26-palette legibility sweep now includes the pressed ladder.
- Six injections each failed the new suite by name: no `mouseDown` override, no overflow branch, no re-apply after a row change, the push moved back into `show(_:)`, no toggle glyph swap, and no pressed restyle.
- The tour lab gained `bar hover|press|rest <target>` and `renderbar`, which render the bar's states side by side without a real pointer.

## The sidebar shell, behind a setting (modular-shell stage 3, `fm/grandline-modular-shell-migration-1792578041`)

Step 3 of the full review's migration plan (section 5.8) built a second window layout beside the floating bar.
Settings › Appearance › Window layout picks it (`AppSettings.workspaceLayout`, `fm.workspaceLayout`), and the app delegate reads it once at launch.
The floating bar stays the default until stage 5.

### The shape

- `WorkspaceShellController` is the base class both layouts extend: it builds the one `Workspace`, paints the window's ground, follows the chrome text scale, and carries the API the app delegate, the menus and the suites call on "the shell".
  That API moved up from `AppShellController` unchanged, so every call site works on either layout.
- `AppShellController` is the floating-bar layout and keeps only that chrome.
- `MainSplitShellController` is an `NSSplitViewController` (sidebar, content, inspector) plus a system `NSToolbar` with the unified style, in a standard titled window.
  The app delegate skips `WindowChromeFusion` for it, and the shell installs its toolbar when its root view reaches a window.
- The sidebar (`WorkspaceSidebar.swift`) is a source list over `ModuleTable`: Home, the Pinned section (`AppSettings.quickAccess`), then the four groups, with live sessions as Console's children.
  `WorkspaceSidebarModel` is the pure half and `SplitShellModelSelfTest` asserts every destination has exactly one row outside Pinned.
- The captain renamed Knowledge's fourth tab from the prototype's Playbook to Docs during this stage, because it is the Docs page.
  `ModuleTableSelfTest` pins Knowledge's tabs.

### What was measured on the way

- **A page wider than its column grows the window.**
  The 29 pages were laid out for the floating bar's full-width body.
  Beside a 244pt sidebar pane at 1100pt, Log Analyzer pushed the window to 1182pt and DevOps Commands to 1173pt - their content holds 938pt and 929pt at priorities above the window's 500.
  DevOps Commands' is real: a row of eight buttons at required compression.
  So the content column's minimum is `MainSplitShellController.contentMinimum` (940), and below that plus the sidebar the shell collapses the sidebar and brings it back when there is room.
  `fittingSize` is no guide here: it reported 1512 for Home and 1206.5 for Kubernetes, neither of which pushes a window.
  The working measurement is the growth itself - resize to 1100, show the page, read the window's width.
- **CI's runner shows scroll bars always, and every page's floor grows by one scroller's track there.**
  The first CI run failed at the narrowest width that keeps the sidebar: Log Analyzer and Kubernetes needed 953pt, against about 938pt locally, and DevOps Commands and Vault 943pt.
  The difference is the legacy scroller's 15pt track (gotcha (4)).
  So `contentMinimum` adds one legacy scroller's width while the system draws them, and the shell re-fits the panes when the setting changes.
  Measured locally with overlay scrollers and on CI with legacy ones, the window suite covers both.
- **The system's own collapse covers a live drag only.**
  `canCollapseFromWindowResize` collapsed nothing for a frame set in code (the launch frame, the autosaved one, a zoom), so the shell runs the same rule on `NSWindow.didResizeNotification`.
  By the time that notification arrives the split view has already squeezed the sidebar to its 200pt minimum, so the width the sidebar comes back at is remembered from divider drags only, never read off the pane on the way into a collapse.
- **`NSSplitView.didResizeSubviewsNotification` carries `NSSplitViewDividerIndex` for every resize of the panes**, not only for a drag.
  A width is taken as the captain's only while `NSEvent.pressedMouseButtons` says the mouse is down.
- **Held at the default 260, the sidebar swung to its 320pt maximum** as pages with 480-priority grow ties came and went.
  It is held at `HelmSplitPage.sidebarHoldingPriority` (489), that file's own measured value.
- **A toolbar is drawn above the content view**, so the lock overlay cannot cover it.
  `LockPresenter.onOverlayVisibilityChanged` tells the shell, which hides the toolbar and the page's title while the overlay is up.
- **`NSToolbarItem.badge` is macOS 26 only** and absent from the SDK CI builds against, so the notifications button draws its count as a subview.
- **A view item whose view measures zero** - a page whose four buttons are all hidden - makes AppKit warn that the view "had an ambiguous height or width".
  The page-actions item is in the toolbar only while one of its buttons is visible, and it follows each button's `isHidden`.
- **A source list tints a selected row's text with the system accent**, which on Gruvbox was blue text on the theme's orange wash.
  The lit row's label takes `HelmContrast.legibleTintedText` over the theme accent, the same ink `HelmPageSidebar` gives its selected row.
- **The stock-bezel guard (`FM_RUN_CONTRAST_TESTS`) bans the text `bezelStyle` anywhere in Sources.**
  Toolbar buttons need no bezel style: on macOS 26 the toolbar wraps a plain `NSButton` view item in a glass capsule exactly as it does an image item (measured in a standalone probe).

### Rendering it off-screen

macOS 26 draws the sidebar and the toolbar's capsules as Liquid Glass, which the window server composites, so `cacheDisplay` of the window's frame view captures placeholders: an empty white panel where the sidebar's rows are, and opaque white capsules over the toolbar's buttons in a dark appearance.
`ReviewTourLab.writeSplitShellPNG` renders the frame view (which does include the toolbar, the title and the traffic lights), draws the sidebar's own view over its panel on `HelmTheme.sidePanelFill`, redraws the traffic lights and the sidebar button over that, and in a dark render repaints the capsules as a tint of the ground with their items redrawn on top.
Two traps in it:

- A bitmap rep's plain `draw(in:)` copies rather than composites, so a transparent background replaces what is under it.
  Pass `.sourceOver`.
- Render each theme in its own process.
  After a few dozen dark renders the toolbar's item views stopped drawing their icons in a later light render, while a short dark-then-light run kept them.
  `FM_REVIEW_TOUR_LAYOUT=sidebar` picks the layout, and the stage 3 tours were split into one file per theme.

### Verification

- `FM_RUN_SPLIT_SHELL_MODEL_TESTS` (pure): the sidebar model, `NavigationHistory`, the layout setting, and source guards on the wiring a behaviour check cannot see.
- `FM_RUN_MAIN_SPLIT_SHELL_TESTS` (window-backed): every route through the one mounter, no page growing a window at the narrowest sidebar width or at 1100, the sidebar's clicks, pins and menus, ⌘⇧D and ⌥⌘S, the toolbar's actions, spaces, badge and Back/Forward, the inspector, the lock hiding the toolbar, the status line and the account menu.
- `ShellSplitSelfTest` checks both shells and their base for the responsibilities stage 2 moved into the workspace.
- Confirmed by injection.
  With `main.swift` always building the floating bar, the model suite fails by name.
  With the sidebar never stepping aside for room, the window suite reports the sidebar still showing at 1100, and page after page growing the window: to 1148pt, which is the column's own minimum beside the sidebar, and to 1182pt for Log Analyzer and Kubernetes.
- The tour lab rendered both layouts in Dusk and Daylight at 1512 and 1100.
  In the sidebar layout no page grew the window, and the sidebar measured 236pt at 1512 and stepped aside at 1100.
  The floating bar's renders matched the stage's baseline except where something else changed: the new Window card in Settings, the dotfiles cards (see below), the time of day and live fleet data.
- The classic tour crashed once on the way, in a test seam's unsynchronised array.
  The crash led to a worse finding: every tour and window-backed suite that mounted Bootstrap or Automation ran a real `git fetch` of the captain's dotfiles clone.
  Both are fixed, and [`48-test-hermeticity.md`](48-test-hermeticity.md) has the account.

## The modules, and Home's cards (modular-shell stage 4, `fm/grandline-modular-shell-migration-1792578041`)

Step 4 of the full review's migration plan consolidates the sidebar layout's 29 page rows into Home and the seventeen modules, in the module table only.
No controller was merged, and the floating bar is untouched and still the default.

### The shape

- The sidebar's rows are the modules (`WorkspaceSidebarModel.listedModules()`), and a module's row reopens the tab it showed last.
- A module's children are its tabs in the middle of the window toolbar (`WorkspaceModule.tabs`).
  A tab is a page of its own (Knowledge's five, Secrets' two, Setup's four) or one of a page's own tabs (`WorkspaceModule.pageTabHost`).
  Every one of the 29 routes still lands on its page and lights its module and tab, which `SplitShellModelSelfTest` sweeps.
- Four pages draw tabs that are their module's: Shift (Tasks), the Fleet page (Crew's In flight and Log), Hosts (Connections' Hosts, Keys and Snippets) and Kubernetes.
  They adopt `ModuleTabHosting`: in the sidebar layout the page hides its own control, the toolbar drives the page through the page's own switch, and a switch the page makes by itself reports back.
  The floating bar never calls any of it.
- The toolbar names the module in a crumb ("Work › Crew"), and the content column opens with the module's large title and the page's live subtitle (`WorkspaceModuleHeader`), except on Connections and Console, where the captain dropped it.
  Home's subtitle is the date, because Home has no live subtitle of its own.
- Console's session strip (the floating bar's `SessionStripView`) sits at the top of the Console module, and Console's toolbar action is Quick Connect.
  Connections' is Activity, the captain's log the Hosts page's column linked to before the toolbar's tabs replaced the column.
- Home's own space shows the captain's arranged cards (`HomeCardLayout`, `fm.homeCardLayout`): Customize adds any card from the other spaces, hides, moves and resizes them, and Reset brings Home's own five back.
  Only the sidebar layout hands the canvas a layout, so the floating bar's hub keeps its hand-placed dashboard.

### Decisions

- **A tab is a real view.** The prototype's Crew › Needs you and Crew › Merge queue, and Connections › Sessions, have no view of their own, so they are not tabs: the decisions waiting on the captain are the Fleet dashboard's Needs your call list, a ready PR carries Merge on Review, and the sessions are Console's.
- **Settings keeps its own column**, as the prototype draws it, so its categories are not toolbar tabs.
- **Home keeps its five spaces**, as its toolbar tabs, because ⌘1 to ⌘5 and the Go menu use them.
  Whether they go is a stage 5 question, with the space pills.
- **The shell, not the pages.** Mid-stage the captain asked whether this matched the prototype exactly, and chose to ship the prototype's structure and chrome on today's pages, with the page redesigns, motion, sidebar badges and the rest of the status line in later stages.

### What was measured on the way

- **A page's stale width floor outranks the sidebar.**
  `HelmDaylightPriority.contentTie` is 499 and the sidebar holds at 489.
  Widening a 1100pt window lays the content out at full width with the sidebar still collapsed, so Home's grid rebuilt for a 1464pt column.
  Then the sidebar re-expanded, its pin was released in the same turn, and the grid's 499 pins squeezed it to its 200pt minimum.
  Measured: 200pt after a 1100-to-1512 round trip on Home, where Settings and Tasks came back at 236.
  The canvas rebuilds for the narrower column on the next main-queue turn, so the pin is released on that turn too.
- **Five tabs and a crumb overflow the toolbar at 1100.**
  With Knowledge showing, AppKit put Search, the bell, the light/dark toggle and the page's own actions in the overflow menu.
  The toolbar now goes compact below the prototype's 1240pt breakpoint (Search is its glyph, the crumb names only the module), and its items carry visibility priorities, so the crumb, Recents and the inspector toggle overflow first and Search, the bell and the toggle never do.
  A view item in the overflow menu does nothing without a `menuFormRepresentation`, so Recents and the module's action have one.
  Recents' panel then opens under Back and Forward, which never overflow.
- **Pinned repeated the sidebar.**
  Four of the floating bar's seven default pins are a module of one page (Sticky Board, Code Preview, Tasks, Console), so they were listed twice and pushed Setup and Settings off the bottom at 950pt.
  Pinned now lists only the pins nested inside a module of several pages.
  The floating bar still draws every pin.
- **Customize's strip covered a small card's title, and then let a Refresh show under it.**
  A small card is 255pt, and a strip with a labelled "Small"/"Large" button truncated "Merge queue" and sat over Fleet's status.
  The size is a menu behind one glyph now.
  Laid over the card, the strip still let the bottom of the Claude card's Refresh show under it (Daylight, 1512pt).
  So the card's header row holds the strip in place of the card's own status and action (`HelmModuleCard.setHeaderAccessory`), and the title truncates before it.
  At 31pt the strip stays inside the 32pt header, so a card keeps its height while it is arranged.
  In the header row the strip then stretched across a large card (406 to 460pt against its own 125.5pt).
  It is a container with no intrinsic width, so a required hugging priority on it did nothing (gotcha (12)), and it tied with the title column for the spare width.
  Its own stack hugs at `HelmDaylightPriority.columnHug` now, one step over the title column's 250.
- **Home's own cards in canvas order left a gap.**
  At four columns (1512) and three (1100) the second row had a column to spare.
  The standard arrangement orders and sizes the five so the rows fill.
- **The Hosts page's content kept the inset it uses beside its column** (15pt) once the column was put away.
  It takes the page gutter (24pt) while the toolbar draws its tabs.
- **A page's own column coming back grew the window.**
  Tasks puts its column away for Weekly review and brings it back for the board.
  At 1100pt, with the sidebar collapsed for room, that reopen grew the window by the column's 249pt, to 1349, and the sidebar came back out with it.
  The floating bar shrank the content to 851pt instead, which is what a reopen should do.
  AppKit's default collapse behaviour grows the window whenever the window's minimum width plus the column would not fit, and in the sidebar layout that minimum is the content column's 940pt floor.
  Measured against the floor itself: 500pt kept the window at 1100 and 860pt grew it.
  `HelmSplitPage` now collapses and reopens its column through constraints at the sidebar's own 489, which can never move the window, so the fix covers all seven pages with a column, in both layouts.
  `MainSplitShellSelfTest.checkAPageColumnNeverGrowsTheWindow` drives Tasks' tabs and ⌥⌘S on Settings at 1100pt.

### Found on Home on the way, in both layouts

- **The attention card's headline could start with a lower-case letter.**
  It read "nothing known needs you right now." whenever the fleet was the only thing to report.
  A signal's clause is lower-cased so that it reads well after another clause, and nothing capitalised it when it led the sentence.
  `NeedsAttentionComposer` capitalises the sentence's first letter now.
- **The Merge queue reshuffled on every launch, and drew an untitled PR as a blank row.**
  Both are in [`07-fleet-and-notifications.md`](07-fleet-and-notifications.md), with the fleet's data.

### Verification

- `FM_RUN_SPLIT_SHELL_MODEL_TESTS` (pure): the module list, every route landing on a module and one of its tabs, the groups, the tabs being real views, Home's card layout and how it is stored, and source guards on the wiring a behaviour check cannot see (the four `ModuleTabHosting` adopters, and Home's layout handed over by the sidebar layout only).
- `FM_RUN_MAIN_SPLIT_SHELL_TESTS` (window-backed): every route through the one mounter with its module's row, tab, crumb and header, no page and no page column growing the window, the sidebar's map and pins, the toolbar's tabs driving the four pages, the compact toolbar and its priorities, Console as a module, Customize on Home, the lock, the status line and the account menu.
- Confirmed by injection, in nine runs.
  The model suite fails by name with a module dropped from the sidebar, Home not handed its layout, or Pinned repeating every pin.
  The window suite fails by name with the four pages not adopted as tab hosts, the sidebar's pin released at once (the sidebar back at 200pt), no compact toolbar, a card click allowed in Customize, the toolbar's tab not driving the page, a page's column reopening through the default collapse behaviour (1349pt and 1362pt windows), Customize's controls laid over the card, and the strip with no hug of its own.
  `NeedsAttentionSelfTest`, `FleetDataSelfTest` and `HomeDashboardViewSelfTest` each fail by name with the three Home fixes reverted.
- The tour lab rendered every module and tab in both layouts, in Dusk and Daylight at 1512 and 1100.
  In the sidebar layout no measurement moved the window, the sidebar measured 236pt at 1512, and it stepped aside at 1100.
  The floating bar's 116 renders matched stage 3's except for the time of day and live fleet data.
- 176 targeted suites passed on the final code: those for the files this stage changes, the new cases, and the source guards that scan those files.
  A first pass was cut short by a machine sleep, and four timing and real-event suites failed across it (dotfiles auto-sync, herdr theme sync, the SRE Lead notification and the notification row's real click).
  None of their code changed here, and all four passed on the clean pass.

## The redesigned pages (modular-shell later page work, `fm/grandline-page-redesigns-1792627806`)

The page work stage 4 deferred, for the sidebar layout only: Connections' tables and the shell's inspector, Secrets' credential tables, Knowledge's one tree, and Crew › Needs you.
The floating bar is still the default, and its pages are unchanged.
Each redesigned page switches to its sidebar presentation when the sidebar shell first shows it (`SidebarLayoutAdopting`).
The layout is chosen at launch, so nothing ever switches back.

### The shape

- **One table** (`HelmDataTable`): a header strip, a two-line leading cell, a selected row, a row's headline action and ⋯ on hover and on the selected row, a context menu with the same actions, group and empty rows, and drag to reorder within a group.
  It lays its columns out itself.
  Fixed columns keep their width, one flexible column takes the rest, and a column marked `hiddenBelow` steps out.
  Then the most optional column keeps stepping out while the minimums still do not fit, so a table never scrolls sideways or holds a width that could grow the window.
- **The inspector** shows a page's selection (`WorkspaceInspectorSource`).
  That is Hosts' host, key or snippet (`WorkspaceDetailView`), and Poneglyph's own `CredentialVaultInspectorView`, hosted in the shell's pane without its head.
  It opens on a selection and closes when the selection clears.
  The toolbar button and the inspector's own close button are the captain's choice, and a new selection respects it.
- **Connections**: Hosts, Keys and Snippets are tables under the same search, filters and stat strip.
  Every row and inspector action runs the method the floating bar's row runs.
  The snippet expansion switch is a strip over the Snippets table (`SnippetExpansionPanel.Style.strip`), because the page's right column belongs to the floating bar's layout.
- **Secrets**: Poneglyph is a table whose rows keep Reveal, Copy, the Touch ID mark and the live 2FA code, grouped by category and reorderable within one.
  Automic Vault's secret names and verified launchers are tables under their own cards, with B1's three states.
- **Knowledge**: one tree (`KnowledgeTreeController`) beside Notebook, Runbooks, Postmortems and Docs, read from the shared stores off the main thread, with its own search.
  An item opens its tab and the item through the page's own open path (`KnowledgeTreePage`).
  Each page reports its edits and the item it is showing.
  Notebook puts its page column away there.
  The Reading list keeps its cards, as the prototype draws it.
- **Crew › Needs you**: Crew's first tab, a sidebar-only state of the Fleet page.
  It holds the Needs your call rows and their Reply composer, with a summary of the parked tasks, their open decisions and when they were read.
  The bell's decision entry and Home's fleet row land on it.

### Decisions

- **Only what the real controllers do.**
  No latency, last-connected or Online/Problems split on Hosts, because nothing records them.
  No SRE Lead or Copy ssh command on a host, and no follow-ups on Needs you.
- **The real feature wins where the prototype has none**: the snippet expansion switch, a credential row's own Reveal and Copy, the Touch ID mark, and Automic Vault's recipe card.
- **The tree reads the stores, not the pages.**
  The pages mount lazily (GL-37), so a tree fed by them would show empty groups it had never read.
  A group not read yet says "Reading", and the playbook says "Not synced yet" until a copy is on this Mac.
- **Needs you is a tab now, because it has a view of its own.**
  Stage 4's "A tab is a real view" above left it out, when the decisions waiting on the captain were only the Fleet dashboard's Needs your call list.
  This corrects that entry for Needs you only, and Merge queue and Sessions are still not tabs.
- **Needs you keeps its last good list over a read that failed, and says when it was read** (GL-14).
  The brief's honest-state rules ask for it, and the Fleet data could not tell a failed read from an empty fleet (below).
  Before the first read it says it is reading.
  When the crew's task list cannot be read, the rows stay and the summary says when they were read.
  A task whose own state cannot be read stays listed with its age.
  "Nothing needs you" only follows a read that worked.
  The floating bar's dashboard lists each read as it is, unchanged.
- **A page tells the tree which kind of change it made** (`KnowledgeChange`).
  Opening an item only moves the tree's selection.
  Only a change to a page's list makes the tree read the stores again, where the first version re-read all four on every open.

### What was measured on the way

- **The inspector would have grown the window.**
  The content column's floor is 940pt, so a 320pt inspector at 1100 needs a 1260pt window.
  While the inspector shows a page's details, the floor is 940 less the inspector's width (`MainSplitShellController.inspectorColumnMinimum`), and every page that fills it is laid out for that.
  The sidebar then comes and goes at exactly the same window width with or without the inspector, and a selection never moves the window.
- **`NSTableView`'s `.fullWidth` style pads the table 6pt past each end of its columns.**
  Measured: the table was 12pt wider than its columns, so every row scrolled sideways.
  The table is `.plain`.
- **A reload after a theme change dropped the table's selection without a notification.**
  The inspector was left showing a credential the table had let go of.
  Every reload puts the selection back.
- **`NSGridView.removeRow` leaves the row's views in the grid**, so a new selection drew its fields over the last one's.
  The detail view's fields are stacked rows that are removed for real.
- **`NSOutlineView` widens its outline column for indented rows by default**, so a long title in a folder ran past the tree's edge instead of truncating.
  `autoresizesOutlineColumn` is off.
- **A table's own reselection looped through Poneglyph's render.**
  `setRows` restoring the selection called the page's selection handler, which re-rendered and called `setRows` again.
  The table does not report its own reselection.
- **The floating bar's Hosts column could hand its spare height to the footer.**
  This one is older than this branch, and it was found by the before/after comparison of the floating bar's renders.
  After a tab round trip, the column's footer stack (the keychain card and the user row) was 570pt tall against a 117pt fitting height, and its keychain card sat 501pt above the column's foot, just under the nav rows.
  The rows' stack and the footer stack both hugged at a stack's 250 default, so the column's spare height had two equally cheap homes, and the solver's history decided which one took it.
  That is why it came and went between runs of the same tour.
  `HelmPageSidebar.setFooter` now holds any footer at its content's height with a `height == 0` at `columnHug` (251).
  A hugging priority would have done nothing for Tasks' footer, which is a plain view with no intrinsic size (gotcha (12)).
  `NSView.hasAmbiguousLayout` flags this tie: the footer stack and the keychain card on every run without the fix, and neither with it.
  The frame check alone was not enough, because with the fix reverted it passed three runs in a row on one build of the suite and failed four in a row on the next.
  So `FM_RUN_PAGE_REDESIGNS_TESTS` asserts both.
- **Settings' nav column reports an ambiguous height too, before and after this branch.**
  It is a different mechanism: the list's own height inside Settings' wrapper column, not its footer.
  It was not visible in any render here, and it is left for a Settings change to settle.
- **Automic Vault's own read can land on top of a fixture.**
  Every visit to the page starts an install check and a snapshot read, and a self-test or tour process refuses `av`, so that read lands as a failed read.
  A fixture drawn before it lands is replaced, and that failed the suite's table check on one run.
  The suite and the tour's `demo automic` now wait for the page's read first (`VaultController.debugIsReading`).
- **The Fleet data could not tell a failed read from an empty fleet.**
  `FleetDataSource.parseTasks` answers `[]` for a state folder it could not list (GL-21).
  `FleetTaskCache` can then serve that `[]` for up to five seconds after the folder is readable again.
  `FleetSnapshot.tasksRead` now says whether the list is a real reading: an empty list counts only when the folder can be listed and holds no task files.
  `FleetDataSelfTest` checks it against a scratch firstmate home it pins before anything reads the real one.
- **CI shares its stores across every suite in a lane, so a suite that seeds data has to own its stores.**
  CI points hosts, keys, snippets, the vault, runbooks, tasks and more at one `ci-stores` folder.
  The first CI run of this branch failed `FM_RUN_CREDENTIAL_VAULT_VIEW_TESTS`: this suite's demo vault was still there, so that suite's own `createVault` had nothing to create, and its page read "Locked".
  Locally each process has its own scratch folder, so it passed here until the run was repeated with CI's environment, which reproduced the two failures exactly.
  `FM_RUN_PAGE_REDESIGNS_TESTS` now runs inside its own stores (`withScratchStores`) and fingerprints the caller's stores either side, so a run that writes past it fails by name.
- **A real mouse click on a table row cannot be driven in the off-screen probe window.**
  `NSTableView.mouseDown(with:)` never ran its tracking loop there, and the queued mouse-up stayed queued.
  That held when it was called directly, sent through the window, sent after `makeKey`, and with the mouse-up queued last.
  So the suite selects through the table's selection path, which is where a click's selection change lands, and activates with a real Return through `HelmTableView.keyDown(with:)`.
  Return reaches the same `doubleAction` handler a double click does.

### Verification

- `FM_RUN_PAGE_REDESIGNS_TESTS` is new and window-backed.
  It mounts the real sidebar shell and the real floating bar off screen, with the tour lab's scratch data.
- Every case was shown to catch a revert, by copying the file aside, reverting one thing, and watching the case fail by name:
  - Hosts not adopting its sidebar presentation, Poneglyph not adopting it, Automic Vault not adopting it, the Knowledge tree not shown, and Crew without Needs you.
  - The inspector floor back at 940pt, which grew the window to 1261pt.
  - The table back at `.fullWidth`, which made each table 12pt wider than its card.
  - A plain `reloadData` after a theme change, which dropped the selection.
  - The footer's `height == 0` deactivated, which failed both the ambiguity check and the frame check on four runs out of four.
  - The hover wiring removed, the tracking area removed, `doubleAction` removed, the drag type unregistered, the drop not reporting the move, and Poneglyph not wiring `onReorder`.
  - `tasksRead` always true, an empty list trusted beside a task file, Needs you treating a failed read as a normal one, and Needs you dropping a task it could not read.
  - The suite's own stores bypassed, which failed the fingerprint check and named the eight stores it would have written.
- `debugHover` sends a real mouse event at the row's centre through the tracking view's own handlers, so it fails when the wiring or the hit test goes, not only when the reveal does.
  Drag to reorder goes through the table's own data source: the dragged row's pasteboard item, then `validateDrop` and `acceptDrop` with `CredentialVaultViewSelfTest`'s dragging-info stub.
- Every affected page was rendered with the tour lab in Dusk and Daylight, at 1512 and 1100, in both layouts, before and after.
  The floating bar's renders differ only by time (TOTP codes, relative times, a Refresh pill caught mid-load, Monaco still loading) and by the Hosts footer.
- Not verified: the real app was not launched, VoiceOver was not run, a real pointer never moved over a table, and a real drag never ran.

## The polish: motion, sidebar badges and the rest of the status line (`fm/grandline-sidebar-polish-1792641688`)

The last of what stages 4 and the page work left out, for the sidebar layout only.
The floating bar does not build any of it.

### The shape

- **`WorkspaceSignals`** is one pure model of what every badge and readout draws, with the honest states as a type (`WorkspaceReading`): unknown draws nothing, a first read in flight is a dash, a read is its value, and a failed read keeps the last good value with the time it was read.
- **`WorkspaceSignalsMonitor`** only listens.
  It follows the Shift store, the Health registry, the background signals poller, Tasks' git sync, the vault store's new lock observers, and the Fleet page's two readings (forwarded through `workspaceCrewDidRead` and `workspaceQuotaDidRead`, because both of the Fleet page's closures are already Home's).
  It starts no timer, pass or subprocess, and a source guard keeps it that way.
- **The badges**: Crew's waiting tasks, Tasks due today and overdue, Poneglyph's lock, Health's failing or degraded dot, Setup's updates and drift, Console's live sessions.
  Logs has no signal anywhere in the app, so it has no badge.
- **The status line** gained the crew, a failing service and Poneglyph's lock, then Claude usage and Tasks sync on the right.
  Each readout opens its page; the crew's opens Crew › Needs you.
- **Motion**, on the motion table: the panes through `WorkspaceMotion.setCollapsed`, the inspector's panel sliding 16pt in, a page's own tab or a Home space taking the page change's entrance, and row hover and selection easing through `HelmRowWash`.
  The prototype's 200 and 220ms became the table's 180ms move row rather than new numbers.

### Decisions

- **The badge never builds the vault store.**
  Building it is what starts the vault's git sync (`CredentialVaultStore.init`), and nothing built it at launch before.
  So the monitor waits for whatever builds it first (`GrandLineServices.whenVaultIsBuilt`) and until then reads only whether a vault file exists, which can only be locked.
- **The vault's lock is a list of observers on the store, not a second `onChange`.**
  That closure is Poneglyph's (ARCH-04), and the new list carries a Bool and nothing else.
- **Needs you's bookkeeping runs in both layouts**, so Crew's badge is right before Crew is ever opened.
  Only the sidebar layout lists its result; the floating bar's dashboard lists each read as before.
- **A real zero draws no badge**, as a source list's counts do; the status line says it in words ("Crew all clear").
- **The Tasks badge counts tasks only, by day**, through the same rule compact mode's Today tab uses (`CompactModeDigest.dueCounts`).
- **A row's first paint is instant, and only a change eases.** A sidebar rebuild (a session coming or going) recreates every row view, and the wash fading in from clear on each one would read as a flash.
  A flag that suppressed the fade during a rebuild was built first and then removed: a revert proof showed it did nothing, because the outline view builds its row views after the selection is applied, so the new row's first paint is already the lit state.

### What was measured on the way

- An off-screen sidebar does not realise a row below the fold, so a badge change repaints only the rows that are on screen; a row scrolled in later is built from the current signals.
- `HelmDataTable`'s rows are reused, so a reused row view is handed its new row's state at once, and only a change to a row already on screen eases.

## The captain's fixes from using the sidebar layout (modular-shell stage 6, `fm/grandline-stage6-ui-fixes-1792645871`)

The captain moved to the sidebar layout and sent nine items, each with a screenshot.
This stage is those nine, for the sidebar layout only.
The floating bar is still the default, and its pages draw exactly what they did, with one exception, a Log Analyzer bug found on the way (below).

### The shape

- **No Pinned section, and no Pin or Unpin.**
  Every page is one click on its module's row and one on its tab, so a Pinned section listed pages that already had both.
  The pins themselves are the floating bar's: the saved list, the bar's squares and the ⌘⇧D map's Pin and Unpin are untouched.
- **The account menu is Log Out only.**
  Settings is its own sidebar row, and ⌘, and the app menu still open it.
- **A rule between the account header and Home**, with `WorkspaceSidebarController.headerRuleGap` above and below it, drawn in the status line's own edge recipe.
- **No status line under Console.**
  Console's session strip already lists the live sessions at the top of the module, so the line under the terminal said the same thing again.
  It is still drawn under every other module, which is where the focus timer chip and (from PR #521) the crew, health, vault, Claude and sync readouts live.
  The body and the column end at the line, or at the pane's foot while it is hidden: two alternative constraint pairs, one active.
- **A page's primary action is the toolbar's far-right item, after Search** (`WorkspacePrimaryActionProviding`): Connections' Add Host, New Key or New Snippet for the showing tab, Logs' Analyze, Health's Copy diagnostics.
  It is the page's own button, left out of the page's other actions.
- **Connections** is the prototype's page.
  The tabs count their records ("Hosts 7"), from `ModuleTabHosting.moduleTabCounts`.
  Hosts opens on one filter row under the toolbar: the search (still live filtering, and Return still connects to a typed `ssh user@host`), All and Online with each count, then the floating bar's group and tag filters.
  Each table is one card that ends under its last row (`HelmDataTable.hugsRows`) and scrolls once the rows outgrow the page.
  There is no stat strip and no shortcut footer: the counts are on the tabs and the All / Online filter, Touch ID's reading is on the Keys card, and every chord the footer listed is a Hosts menu item or ⌘K.
  The snippet expansion switch is a plain row over the Snippets table (`SnippetExpansionPanel.Style.inline`), with no sunken box.
- **Logs** opens an analysis on the input (the redacted output, with Clear) beside three summary cards, the patterns as a table and the likely cause, with Investigate Further, Create Incident and ⋯ under it.
  The header reads "Log Analyzer · N lines".
  Analyze is in the toolbar and keeps ⌘↵, its own key equivalent, which the toolbar's button still answers.
- **Health** is summary cards (Healthy, Warnings, Failing, Not run yet) over one service table with a status, the last run and the recent run streak.
  Retry shows on a failing row only where the service has a real "run now": the background signals (`BackgroundSignalsPoller.checkNow()`) and the dotfiles sync (`DotfilesAutoSync.syncNowFromUI()`), the entry points their own pages' buttons use.
  Refresh reads every service's latest report again; it runs nothing.
- **One component for the summary cards**, `HelmMetricCard` and `HelmMetricRow`: a caption over a large number, tinted only when the number is the signal and corrected to clear the text floor, and a dash rather than a zero for a reading not taken yet.

### Decisions

- **Only what the data holds.**
  No latency, last-connected or session-count columns and no Sessions tab on Connections (the live sessions are Console's), no per-pattern sparkline on Logs (the analyzer counts a pattern, it does not keep a series), and no duration sparkline or app uptime on Health (the registry records neither).
- **Logs' cards use the analyzer's own severity words**, "Critical or high" and "Warning", not the prototype's Errors and Warnings.
  The analyzer rates a line by what it says, so a `WARN ... refused` line is High, and cards captioned Warnings would have disagreed with the Level column beside them.
- **The status line stays on the other modules.**
  The captain named Console, so this stage did not decide anything about the line elsewhere.

### What was measured on the way

- **A finished analysis showed an empty Analysis tab, in both layouts.**
  GL-20 made the Log Analyzer's tabs mount lazily, and `mountTab` hid every tab it built.
  The Analysis tab is mounted at build time and is the selected one, and nothing ever showed it, so after an analysis the tab strip sat over an empty space until a tab was clicked.
  A tab now mounts visible when it is the selected one.
  `SidebarPageFixesSelfTest` checks it in both layouts.
- **A data table row with nothing to offer still drew ⋯.**
  `setRevealed` showed the overflow button on any revealed row, so under `actionsAlwaysVisible` every healthy Health row offered an empty menu.
  The button now shows only when the row has a primary action or a menu.
- **The status line's room under Console.**
  A hidden view keeps its constraints (gotcha (11)), so hiding the line alone would have left a 30pt band under the terminal.

### Verification

- `FM_RUN_SIDEBAR_PAGE_FIXES_TESTS` is new and window-backed.
  It mounts the real sidebar shell and the real floating bar off screen, in its own stores.
  It never runs `claude -p`, `av`, a sync or a check: the Log Analyzer's fixture goes through `debugRender`, ⌘↵ is sent through the window with nothing to analyze, and Retry's actions are counters.
- `FM_RUN_MAIN_SPLIT_SHELL_TESTS` and `FM_RUN_SPLIT_SHELL_MODEL_TESTS` changed where this stage changed what they pinned: the Pinned and Pin cases became "the sidebar draws no pins" with source guards, the account menu case checks Log Out only and the header rule, the status line case checks Console, and the toolbar's page-actions case moved to Health because Hosts' only action is now its primary one.
- The tour lab has `demo logs` and `demo health`.
  Every page was rendered in Dusk and Daylight at 1512 and 1100, in both layouts, before and after.

## The sidebar becomes the default window layout (`fm/grandline-sidebar-default-1792652573`)

The captain's call: "Make the sidebar the default now".
The earlier decision still holds, so the floating bar stays a real choice in Settings › Appearance › Window layout and nothing of it was removed.

### What changed

- `WorkspaceLayout.standard` is the one spelling of the default, and it is `.sidebar`.
  `AppSettings.workspaceLayout` falls back to it for a missing or unknown value.
  A stored choice is read as it is, so a captain who picked the floating bar keeps it.
  Reading the setting never writes it, so a captain who never chose keeps following the default.
- The tour lab mounts whatever the setting says.
  Its process has its own empty defaults domain, so an unset `FM_REVIEW_TOUR_LAYOUT` gets the sidebar, as a first launch does.
  A named layout is written to that domain as the captain's choice, so the Window layout row in a tour's render agrees with the shell it mounted.
  Before this, the env var mounted the floating bar while Settings could show a different selection.
- The Window layout caption no longer calls the sidebar "the new workspace, in preview".
  It still says the change takes effect the next time Grand Line opens, because the layout is read once at launch.

### Verification

- `FM_RUN_SPLIT_SHELL_MODEL_TESTS` has two new cases.
  `checkTheDefaultIsTheSidebar` reads a fresh store, a stored sidebar choice and a stored floating bar choice, each in its own scratch domain.
  `checkTheDefaultIsSpelledOnce` is a source guard: `AppSettings` falls back to `WorkspaceLayout.standard`, the tour lab reads the setting, and no app source or the tour lab has a `?? .floatingBar`/`?? .sidebar` fallback of its own.
  Three injections each failed it by name: the `AppSettings` fallback back to `.floatingBar`, `WorkspaceLayout.standard` back to `.floatingBar`, and the tour lab back to a `?? .floatingBar` literal.
- `checkTheLayoutSetting` changed where it pinned the old default: an unknown value now falls back to the sidebar.
- Tours rendered Home and Settings › Appearance in Dusk and Daylight at 1512 and 1100.
  On a fresh scratch store the window is the sidebar layout, with Sidebar selected.
  With the floating bar named, every Home render is byte-identical to the same tour on `main`, and Settings differs only in the caption.

## No status strip on any module (after stage 6, `fm/grandline-remove-status-strip-1792652628`)

Stage 6 took the status strip out from under Console only.
The captain then asked for it gone from every module: "Yes have this removed everywhere".
The floating bar never drew one and is unchanged.

### The shape

- **The content pane is the header, Console's session strip and the body, and nothing under it.**
  The body and Knowledge's tree end at the pane's foot, which is the window's.
  `WorkspaceStatusLine` and `WorkspaceStatusReadout` are deleted, with `WorkspaceSignals.statusItems` and the two readings only the strip drew: Claude usage (and the `workspaceQuotaDidRead` hook that fed it) and Tasks sync.
  `WorkspaceSignals` and its monitor stay, because the sidebar's badges read them.
- **Every readout already had a home, except the focus timer chip.**
  - The crew, Tasks due, Poneglyph's lock and a failing service are their rows' badges, and each badge's tooltip and accessibility label say what the strip said in words.
  - The live sessions are Console's badge, its sidebar children and its session strip, which lists restored sessions too.
  - Claude usage is Home's Claude card (in the standard card layout) and Console's usage popover.
  - Tasks sync is the Tasks page's own sync pill, in the toolbar while Tasks shows.
- **The focus timer chip is a toolbar item**, just before the trailing cluster, while a timer runs - the floating bar shows it beside its search pill.
  It is the same `FocusTimerChip`, and the shell owns its ring popover (closed by the app lock, like the bar's).
  It now shows under Console too, which the strip never did.

### Decisions

- **The chip yields to the page's own actions when the toolbar runs out of room.**
  Measured on Knowledge at 1100: its five tabs leave room for the page's actions (222pt) or the chip, not both.
  The page's actions are one view item with no menu form, so in the overflow menu they would do nothing.
  The chip's menu form ("Focus Timer") opens the same popover, so the chip takes a priority between the low items (the crumb, Recents, the inspector) and the page's actions (`WorkspaceToolbar.focusChipPriority`).
  The module's one action (Customize, Quick Connect, Activity) goes before the chip (`moduleActionPriority`), because its menu form does what its button does and a running timer is the thing to keep in sight.
  Measured on Home at 1100, where Customize and the chip did not both fit.
- **Below the toolbar's compact width the chip shows its ring and countdown without the task's name**, the same breakpoint that makes Search a glyph.
  The name stays in its tooltip and accessibility label.
  With that, the chip fits beside the page's actions on every module with fewer tabs than Knowledge.
- **A page's and a module's actions go in before the chip**, so the chip stays beside the cluster whichever came into the toolbar first.
  Inserted at the theme item's index like them, it landed left of Home's Customize after a module switch put Customize back.
- **"Crew all clear" and "Poneglyph unlocked" have no badge**, because a badge draws nothing for a real zero.
  Crew › Needs you and Poneglyph's own page say both.
  The strip's crew readout opened Needs you directly; the Crew row opens the tab Crew showed last, and the bell's decision entry still opens Needs you.

### What was measured on the way

- **The chip came in left of Home's Customize after a module switch.**
  The module's action is put back at the theme item's index on every switch, so whichever came in last sat nearer the cluster.
  The page's and the module's actions now go in before the chip (`beforeTheFocusChipAndTheCluster`).
- **The full chip pushed Knowledge's actions into the overflow menu at 1100**, which is what made the chip compact there and lower in priority (above).
- **`MainSplitShellSelfTest` failed about one run in ten on main**, with the sidebar coming back at 200pt, 203.5pt or 212.5pt after a 1100-to-1512 round trip.
  It was not the expand's pin: on a failing run the remembered width was already 203.5pt when the pin went on.
  The divider-drag observer took a width as the captain's choice whenever `NSEvent.pressedMouseButtons` said the left button was down, and that is the whole machine's mouse.
  Instrumented, it fired in 4 of 29 runs with the button down and no event in this app at all.
  It now takes a width only for a left-mouse drag in this window that is not a live resize of the window (`MainSplitShellController.isDividerDrag`).
  The same hole was open in the real app: dragging the window's own edge narrower recorded the squeezed sidebar.
- **A second flake in the same suite: the floating bar's pins read back as the default.**
  `AppDefaultsSweep` removed every other suite's defaults domain at start-up, including a domain whose process was still running, and several worktrees run suites on this machine at once.
  It now skips a domain whose pid is alive (`AppDefaultsSweep.isRunning`).
  See [`48-test-hermeticity.md`](48-test-hermeticity.md).

### Verification

- `FM_RUN_SPLIT_SHELL_MODEL_TESTS` (pure logic, CI's blocking lane) fails if any app source declares the strip again, if the content pane stops tying the body and Knowledge's column to its foot, if the inventory offers "Status line" as a place again, or if the chip leaves the toolbar or changes priority band.
- `FM_RUN_MAIN_SPLIT_SHELL_TESTS` measures, under every module, that the body reaches the window's foot.
  It checks that Console's session strip and the sidebar list the live and restored sessions.
  It starts a real timer and checks the chip under four modules and its place beside the cluster, opens and closes the ring popover through the chip's own click, and checks that stopping the timer removes both.
  At 1100 it checks that the chip drops the task's name and never pushes Knowledge's actions into the overflow menu.
- `FM_RUN_SIDEBAR_POLISH_TESTS` checks that Claude usage still reaches Home's Claude card through the Fleet page's closure and is kept through a failed reading.
- The tour lab has `demo focus`.
  Every module's page was rendered in Dusk and Daylight at 1512 and 1100, in both layouts, before and after.
  The floating bar's renders matched pixel for pixel except clock times and the async PR read.

## The captain's second list from the sidebar layout (modular-shell stage 7, `fm/grandline-stage7-tasks-setup-sidebar-1792665154`)

The captain sent six items after living with the sidebar as the default layout.
This stage is those six, for the sidebar layout only.
The floating bar's pages draw exactly what they did, with one exception found on the way: GitHub sync's subtitle (below), which was wrong in both layouts.

### The shape

- **The sidebar is the system's Large source-list size.**
  `WorkspaceSidebarMetrics` is the one table: 32pt module rows with 15pt names and a 24pt icon box (16pt symbol), 34pt group headings in 13pt, 30pt session rows, and a 19pt badge with 12pt digits.
  The column drew the Medium size before (28pt rows, 13pt names).
  Every size goes through `HelmType.scaled`, so the chrome text scale still moves them together.
  The column keeps its 236pt width, and every name and badge fits at that and at the 200pt drag minimum, in Dusk and Daylight.
  At 1100pt the shell still puts the sidebar away for room, as it has since stage 3: the column and a page's 940pt floor do not both fit.
- **Quick Connect is a caption and two icons on Console.**
  They are three toolbar items (`WorkspaceToolbar.QuickConnectIcon`): the caption, Console (`terminal`) and Hosts (`server.rack`).
  Two separate image items, never one merged glyph, the way the trailing cluster's icons are built, and a toolbar space after them so they are their own capsule.
  Hosts is what the one button did: Connections › Hosts with its quick-connect field focused (`revealHostsQuickConnect`).
  Console focuses the session Console already has and opens one only when there is none (`ConsoleController.focusOrOpenSession`, the captain's Option B).
  In the toolbar's overflow menu the caption is the old single Quick Connect item.
- **Knowledge has no tree column.**
  `KnowledgeTree.swift` is deleted, with its hooks in Notebook, Runbooks, Postmortems and Docs, and the content pane's leading column.
  The content takes the tree's 248pt back, and Notebook shows its own Pages column again (the tree was why it was put away).
- **Setup's four tabs share one row of summary cards** (`SetupSummary`, `SetupSummaryRow`): Tools up to date, Updates, Setup steps, Dotfiles and GitHub sync.
  Nothing in the row checks anything.
  It reads `BackgroundSignalsPoller`'s counts (which now carry their totals), `DotfilesAutoSync.reportedStatus` and `ConfigRepoPrivacy.lastReading`, so the cards and the sidebar's Setup badge cannot disagree.
  A reading not taken this session is a dash, with the reason in the card's tooltip.
  - **Updates** is one `HelmDataTable` of tools grouped by category: installed, available or Up to date, and source.
    A row's action is Update only where the updater supports it, otherwise Install in Bootstrap, Run in Terminal or Check.
    Check for updates (Check all) is the toolbar's far-right primary action, the All and Needs Attention filter and the tool filter stay, and a tool's details and last output are in the inspector.
  - **Setup steps** is a list of steps with their status marks.
    Each step's controls open under its Details button, and the current step carries its own action.
    Run full setup is the primary action.
  - **Automation** is one card of switches: each schedule (through `ScheduleStore.setEnabled`, the store Schedules reads), the dotfiles auto-commit and reconnecting dropped sessions, with Manage Schedules.
    Run Automation is the primary action.
  - **GitHub sync** opens on a "Pushing is paused" card (`SetupPausedPushNotice`) with Open on GitHub and Check again, shown only while `ConfigRepoPrivacy` has confirmed the config repo public.
    Under it the forks are one table with commits behind, upstream, last checked and Sync on a fork that is behind.
    Sync all is the primary action and Refresh sits beside it.
- **Tasks' page column is the filter row.**
  The five scopes are one control (with counts on All tasks, Due today and Overdue), Follow-ups is a button with its count, and Projects is a menu that filters to one project, beside the sort and the Done window.
  Settings is the sidebar's own row and Shortcuts is the toolbar's Search, as before.
  New task is the primary action.
  - The board has the prototype's lanes, each a tint that hugs its own cards with a dashed add row, and its cards (`ShiftWorkspaceTaskCard`: project tag, priority and a due line).
  - The List tab is one table: a check that completes and reopens, project, status, priority, due, a focus action and the board's menu on each row.
  - The calendar is the prototype's month card.
  - Weekly review is five cards (completed this week against last week, focus time, overdue, follow-ups open, coming up next week) over Time on tasks beside Pushed back repeatedly.
    The floating bar's strip counted the tasks pushed back 2+ times, so that panel carries the count (`HelmCountBadge`).

### Decisions

- **Option B for the Console icon, the captain's call.**
  The first build opened a new shell session on every click.
  Asked to choose between that, focusing the current session (opening one only when there is none), and a menu of live sessions, the captain chose the second.
  The real app's shared Console always has its Firstmate shell, so in practice the icon brings Console's session forward with the keyboard in it.
- **The Knowledge tree goes, because nothing it offered lacked a home.**
  The toolbar's tabs already switch Notebook, Runbooks, Postmortems, Docs and Reading list.
  Each tab lists its own items, Notebook in its own Pages column again.
  The tree's search field found notebook pages, runbooks and postmortems, and ⌘K does (`UnifiedSearchNotebookProvider`, `UnifiedSearchDocsProvider`).
  Its "Not synced yet" note under Docs is the Docs page's own subtitle and empty state.
- **Only real figures.**
  Focus time and the comparison with last week come from the focus log and the completion history.
  The prototype's review checklist has no data behind it in the app, so Pushed back repeatedly sits beside Time on tasks instead.
  Nothing records when a fork last synced, so the forks table says when each was last checked.
- **The paused card asks for a confirmed public repo.**
  An unanswered visibility check (no `gh`, offline) never blocks a push (GL-22), so it never claims a pause either.

### What was measured on the way

- **GitHub sync said "all in sync" when every check had failed, in both layouts.**
  The subtitle appended "all in sync" whenever nothing was behind or diverged, and a failed check is neither.
  It now says "could not be checked", and "all in sync" only when every row is in sync (GL-14).
- **Updates' category cards came back on the first filter change.**
  `applyFilter` unhid them, so the sidebar layout now filters its one table and returns.
- **Every lane came out as tall as the fullest.**
  The clip view stretches its document, and the cards' stack was pinned to both of the document's ends, so a tie to the stack's height was a tie to the scroll view's own.
  The stack's bottom is now `<=`, the lane's tint ends 8pt under its last card, and the body takes a stack-level hug (gotcha (12)).
- **The calendar's Month and Week switch sat beside the title** rather than at the trailing edge.
  A stack has no intrinsic size, so the title's stack needed a stack-level hug and the switch a fixed width (gotcha (12)).
- **The paused card's two buttons ran out of the card at 1100** while they sat beside the sentence.
  The sentence now wraps under the title at a width derived from the card (gotcha (22)), with the buttons under it.
- **Automation's switch rows and Setup steps' details came out too tall at 1100.**
  A description's `preferredMaxLayoutWidth` changed in `viewDidLayout` without asking for another pass, so both now set `needsLayout` when a width changes.
- **A symbol image view's frame is not its layout box.**
  An `NSImageView` showing an SF Symbol takes its alignment insets from the symbol's alignment rect, so the sidebar's 24pt icon box measures 24.5 x 37.5 as a frame for Home's house.
  The suite measures `alignmentRect(forFrame:)`.
- **Adjacent toolbar icons share one capsule.**
  Without the space, the system drew Quick Connect's two icons and the trailing cluster's three as one capsule of five, and the caption read as the label for all five (measured in a real render).
- **The sidebar's split pane is the sidebar plus an 8pt inset**, so a divider at 236pt makes a 228pt sidebar.
- **The tour lab's Console starts with no session, and a self-test process starts locked.**
  The first is why the suite can drive both halves of Option B through the real toolbar item.
  The second is why the suite unlocks `AppLockGate` for the focus half, and checks that while locked the icon leaves the keyboard where it was.

### Verification

- `FM_RUN_SIDEBAR_REDESIGNS_MODEL_TESTS` is new and pure logic, so it runs in CI's blocking lane.
  It covers the sidebar's sizes and the source guards that keep them in one table, Quick Connect's three items and their wiring (Option B included), that nothing declares the Knowledge tree again, every summary card's honest states, the readings behind them, and that Tasks' filter row keeps every filter the column had.
- `FM_RUN_SIDEBAR_REDESIGNS_TESTS` is new and window-backed (`NEEDS_SESSION`).
  It mounts the real sidebar shell and the real floating bar off screen, in its own stores, with every Console session `/usr/bin/true` and every tool check a fixture.
  It measures the sidebar's rows at 236pt and at the 200pt minimum in both themes, and drives each icon, filter, switch, check and Details button through its own action.
  The floating bar's Tasks, Updates, Setup steps, Automation, GitHub sync and Notebook are checked unchanged.
- Twenty-one revert injections each failed a named check, and each file was restored and confirmed clean against git:
  the Medium row height and a row's name off the table (the model guard and the measured font), Quick Connect not shown on Console, no space after its icons, Option B reverted, a column back beside Knowledge's body (`PageRedesignsSelfTest`), Updates' category cards back, the paused card for an unanswered check, the old "all in sync" subtitle (both layouts), Details doing nothing, a schedule switch writing nothing, a dash shown as "0 / 0", New task not the primary action, the scope control and the project menu not filtering, every lane as tall as the fullest, the List check doing nothing, Focus time not read from the focus log, the Pushed back count missing, Tasks' column coming back (`MainSplitShellSelfTest` and the round trip from Weekly review), and the floating bar's Tasks taking the sidebar layout's primary action.
- `MainSplitShellSelfTest`, `PageRedesignsSelfTest` and `SplitShellModelSelfTest` changed where this stage changed what they pinned: Quick Connect's case drives the Hosts icon, the column reopen is measured on Notebook's Pages column, and the Knowledge cases check that there is no tree.
- The tour lab has `demo setup`, `demo forks` and `demo focuslog`.
  Every affected page was rendered in Dusk and Daylight at 1512 and 1100, in both layouts, before and after.

## The second full review's UX pass (`fm/grandline-review2-ux-1792762059`)

This branch fixes R2-UX-01 to R2-UX-09 of the second full review, and the captain's three UI items U-01 to U-03.
The report is `data/grandline-full-review-2-1792743067/report.md` in the firstmate home.
One commit per id, with the id in the message.

### What shipped

- **R2-UX-02, one taxonomy.**
  In the sidebar layout Home draws no space tabs, and the Go menu is read off `ModuleTable` in sidebar order (`WorkspaceGoMenu`).
  The floating bar keeps its spaces and the spaces' Go menu, because that is the layout they belong to.
- **R2-UX-01 (b), profiles.**
  `WorkspaceProfile` has Personal (ten modules) and Operator (everything).
  A fresh install starts Personal, and an install from before profiles is Operator, so nothing it had disappears.
  The stored truth is `fm.hiddenModules`, and the sidebar, the Go menu, ⌘K and Home's default cards all read it.
  A hidden module's pages are never torn down, and a link that names one still opens it.
- **R2-UX-01 (c), plain language** outside the operator modules: Home's notes, the lock screen's greeting, and quick capture's copy.
- **R2-UX-03 and R2-A11Y-01, chords and focus.**
  ⌘1 to ⌘9 pick the first nine listed modules, and the Go menu shows them.
  On Console, a host page and Tools the same chords keep picking that page's own tab (`TabKeyboardShortcuts` sees the key first).
  That is option A, the captain's choice through firstmate.
  Option B would move those pages' tab chords to ⌥⌘1 to ⌥⌘9.
  ⌘{ and ⌘} step a module's tabs, the sidebar row tooltips name the chord, and a focused sidebar draws a 2pt ring on its lit row.
- **R2-UX-09.** ⌥⌘S always toggles the app sidebar.
  The page's own column (Notebook's Pages, Settings' categories, Schedules' list) is ⌥⇧⌘S, in the sidebar layout only.
- **U-03, the sidebar's width.**
  It opens at 264pt, can be dragged to 200-360pt, and remembers the width (`fm.sidebarWidth`).
  When the window narrows it first gives width back down to 236pt, and only then steps aside.
- **U-02, Quick Connect.** Two icons with no caption, on every module, at the head of the trailing cluster.
- **U-01, the title bar.**
  On macOS 26 an opaque title bar inserts `NSTitlebarBackgroundView` and an `NSHardPocketView` with system material.
  That material, not the toolbar, is what painted a band that did not match the palette.
  `applyTitleBar` keeps the title bar transparent, so the content pane's ground shows through in all 26 palettes.
- **R2-UX-05, one name per level.**
  The crumb names the module.
  The content line under it carries only the live subtitle, and is hidden when there is none.
  Crew's greeting and Settings' hero step aside in the sidebar layout.
- **R2-UX-04 and R2-UI-02.**
  The toolbar enforces one rule: the page's primary verb is the far-right filled button, and every page action is outlined.
  Crew, Automic Vault and Dictation moved their primary out of the page.
  Health's Refresh is `HelmButton.refresh()`.
- **R2-UX-06.**
  Console, Code and Notebook put their page tools in the window toolbar rather than a second row under it.
  Every page action has a working overflow menu form (`WorkspaceToolbarMenuRepresentable`).
- **R2-UX-07, empty states.**
  Tasks shows one start-here state with an example task.
  Schedules shows one centred invitation with an example schedule instead of three empty cards.
  Reading list offers an example link.
  Notebook, Reading list and Schedules share the watermarked look, and Postmortems' copy follows the profile.
- **R2-UX-08, Settings housekeeping.**
  Window layout and Interface text size have a Relaunch Grand Line button while a change is waiting (`AppRelaunch`).
  The lock thresholds are editable (see `15-app-lock.md`).
  The locality fact is said once, in the column footer.
  In the sidebar layout the window's Back and Forward walk Settings' categories, so the page draws no arrows of its own.

### What was measured on the way

- **AppKit synthesises a menu form for a view toolbar item, and it does nothing.**
  Its target is the `NSToolbarItem` itself, with `_standardCustomMenuFormRepresentationClicked:`.
  So an overflowed page action looked present and ran nothing.
  The overflow check rejects any item whose target is an `NSToolbarItem`.
- **The crumb overflowed first on Notebook at 1512**, with about 50pt short.
  Notebook's three-segment Source/Split/Preview switch became a pop-up, and its utilities moved to a More menu.
  Its labelled actions become icons below 1600pt.
  Quick Connect yields first only in the compact toolbar, or it would push out R2-BUG-07's items.
- **R2-BUG-07's guarantee changed, and says so.**
  The crumb stays at 1100 and at 1512, and Recents and the inspector stay from 1700.
  Below that, whatever overflows has a working menu form.
- **The window's Back and Forward recorded destinations only**, so removing Settings' own arrows would have dropped its category history.
  `NavigationHistory` now records a place per entry for a page that adopts `WorkspaceHistoryPlace`.
  An arrival that names no place matches any place on that destination, and the entry keeps the place it was recorded with.
- **A momentary `NSSegmentedControl` drops a selection set from code**, so `selectedSegment` reads -1 and the action does nothing.
  The suite holds the selection with `.selectOne` tracking for the one send, then restores `.momentary`.
- **A second copy cannot be opened next to this one to relaunch.**
  `SingleInstanceGuard` hands its launch straight back.
  So `AppRelaunch` starts a detached `/bin/sh` that waits for this pid to exit and only then runs `open`.
  The pid and the path are positional parameters, never spliced into the script.
- **Setting the window's `backgroundColor` to the palette ground dropped every toolbar item from the frame.**
  U-01's first version did it "for the frame's edges".
  The after-renders showed Daylight with no crumb, no buttons and no bell, while Dusk drew them.
  The title bar rendered alone still drew its items, and removing the one line brought them back with the band still matching.
  The window server's own image of an off-screen window omits the title bar in every theme, so it could not settle the question either way.
  The U-01 check sampled only where no item is drawn, which is why it passed.
  It now also counts the Search item's ink pixels in every palette.
- **Schedules' and Tasks' empty states sat at the top of their scroll documents.**
  Both are placed in the content pane with `placeAsPageEmptyState`, like the Reading list's.
  At the suite's 720pt window a state at the top is close enough to the middle to pass a middle-third test, so the check measures at 950pt and asks for the centre within 8% of the pane.
- **The tour lab starts locked**, so Console never opens its first shell tab, and its tab row renders empty.
  In an unlocked session the row holds the tab chips and "+".
- **`boardTasks()` is a dictionary**, so `isEmpty` on it was never true for an empty store.

### Verification

- `FM_RUN_REVIEW2_UX_MODEL_TESTS` is new and pure logic, in CI's blocking lane.
- `FM_RUN_REVIEW2_UX_TESTS` is new and window-backed (`NEEDS_SESSION`).
  It mounts the real sidebar shell off screen, in its own stores.
- `FM_RUN_APP_LOCK_OPT_IN_TESTS` is new and pure logic.
- Every fix was reverted at least once and failed a named check.
  The proofs are under the task's data folder, one file per id.
- Assertions that legitimately changed: Settings' card count (22 to 23, the Sidebar section), Slice 6's toggle count (7 to 8, the lock switch), the floating-bar subtitle no longer carrying the locality fact (`SettingsSidebarNavigationSelfTest`, `DaylightDrillPageSlice6SelfTest`), and R2-BUG-07's guarantee above.
- Before and after renders were taken with the tour lab in Dusk and Daylight, at 1512 and 1100, in both layouts.

## A column floor per page (R2-UX-10)

The sidebar layout's content column had one 940pt floor, set by Log Analyzer and DevOps Commands, so the sidebar stepped aside below about 1180pt on every page.
`ModuleDescriptor.minimumContentWidth` gives each page its own floor, read on navigation, scaled with the chrome text size.
The values were measured by laying every page and toolbar tab out in a narrower column at text scale 1.0 and 1.3, in Dusk and Daylight: 660pt by default, Fleet 760, Log Analyzer and Commands 980.
940 had only held for those two when they were shown at a narrow width; narrowing the window while either showed needed 973 and 964.
Tasks' Weekly review is the one tab wider than its page (920pt), so it alone steps the sidebar aside, and its width tie is active only while it shows (gotcha (15)).
The inspector takes its room from the sidebar before the window, and in the compact toolbar beside a showing sidebar the crumb yields first, with an overflow item that shows the place in the sidebar.
At 1100 the sidebar now stays beside every page except Log Analyzer, Commands and Tasks' Weekly review, and at 1280 beside every page. `MainSplitShellSelfTest` asserts both, in both palettes.

## The second full review's architecture findings (`fm/grandline-review2-architecture-1792988374`)

### The floating bar is frozen (R2-ARCH-01)

The review called this a decision rather than a fix: keep building every piece of chrome twice, freeze the floating bar, or set a date to retire it.
The captain keeps both layouts, so this took the review's option (a).
The floating bar is the classic layout, kept and maintenance only.
Settings' Window layout row names it "Floating bar (classic)" and says in plain words that new features and page redesigns go to the sidebar (`WorkspaceLayout.maintenanceNote`).
Nothing about the floating bar itself changed, and its regression checks stay.
`docs/modular-shell/feature-inventory.md` records the freeze; AGENTS.md and CONTRIBUTING.md said nothing about building chrome twice, so there was no wrong statement to correct there.

R2-UX-02 had already taken the floating bar's spaces out of the sidebar layout's Go menu and Home's toolbar.
One reader was left: Home's Customize menu filed the cards it offers under the four spaces (Command, Operations, Stores, Engineering).
It now files each card under the sidebar group of the module the card opens, which is where the captain finds that card's page.
`ReviewTwoUXModelSelfTest.checkTheFloatingBarIsFrozenAndHomeHasNoSpaces` guards the label, the note and the menu.

Not done: a retirement date (the review's option (b)), which is the captain's call and is asked separately.

### The floating bar's presentation in its own file (R2-ARCH-04)

Under the freeze, the members only the floating bar's presentation uses moved out of each page's main file into an extension, `<Page>+Classic.swift`.
The main file then carries what the sidebar layout draws.
It is a move, not a rewrite, and it was checked as one: every moved block occurs line for line in the original file, and the original with those blocks cut out is the main file now, ignoring only access modifiers (`verify_move.py` in the task's data folder, run on all seven).
Swift's `private` is file-scoped, so the members the two files share lost `private` (103 declarations across seven pages).
One trap made that more than a compile check: with a page's `private func check(_:)` out of sight, the moved `check(row, forceRefresh: true)` resolved to the suites' global `check(_:_:_:)` instead, and GitHub Sync's `sync(row)` to another `sync()`.
Both were compile errors here, but a quieter overload would not have been, so every name that was private and is used by moved code was checked to be visible to it.

Seven pages moved code: Hosts (the page column, the side panels, the list rows), Poneglyph (the grouped list), Automic Vault (the keyed rows inside its two cards), Notebook (its own toolbar row), Tasks (its own column), Updates (the stats strip and the category cards with their row buttons) and GitHub Sync (the repo rows).
Five did not, and could not without a rewrite: Fleet, Bootstrap and Automation build their classic header or run card in the same method that wires the button the sidebar layout's toolbar shows, and Log Analyzer and Health draw the sidebar layout by re-parenting the same views.
`ClassicPresentationSelfTest` (pure logic) pins the structure, and `FeatureInventorySelfTest` reads a `+Classic.swift` file as part of its page, so no inventory id changed.

### The module table is the source (R2-ARCH-03)

Step 0 had restated six tables in `ModuleTable.rows` and checked the restatement against them, so adding a destination still meant editing every old table as well.
`RailDestination.title`, `.symbol`, `.domainHue` and `.drillSubtitle`, and `DaylightModule.space(forDestination:)`, now read the destination's row, and their switches are gone.
`WorkspaceModule`'s six switches (title, group, children, symbol, tab host, header) became a second table, `ModuleTable.modules`.
The per-case comments that explained a glyph, a hue or a line moved with their values, beside each row.
What the table does not own stays where it was and is still checked against it: the body slot, the eager-mount flag, the Home cards that open a page, ⌘N, the floating bar's grouping and its cards' spaces.

The agreement test could not keep comparing the table with values now derived from it.
So `ModuleTableSelfTest` asserts three things: the rows agree with what stays elsewhere and every symbol resolves, a typed-out fixture pins every destination's and every module's name, glyph, hue, line, space, module and tab, and the workspace has its planned shape.
The fixture was captured from the old switches and passed against them before any switch was deleted, which is the proof that nothing was renamed or moved.
Renaming Console or changing Hosts' glyph in the table fails it by name.

### One way to watch a store (R2-ARCH-08)

Six types exposed a single `var onChange: (() -> Void)?`: `CredentialVaultStore`, `SnippetStore`, `SSHKeyStore`, `ScheduleStore`, `ClipboardHistoryStore` and `TerminalBlockTracker`.
The last assignment won silently, so every new reader needed a channel of its own: the vault grew `observeLock` for the Secrets badge, and `SnippetStore` had already grown a second, additive list for the snippet expander.
All six now conform to `StoreObservable` and keep one `StoreObservers` list: any number of readers, each with a token to unobserve, delivered on the main thread.
A change reported on main is delivered at once, as `onChange` was; one reported from a background queue is hopped to main first.
The protocol is not named `Observable`, which is the Observation framework's type and would be ambiguous in any file importing SwiftUI.
No `onChange` shim was kept, because nothing needed one: the five readers (Poneglyph, Hosts' keys and snippets, Schedules, the clipboard picker) observe instead, and the picker drops its token when it goes.
The vault's `observeLock` stays, as a different signal rather than a workaround: it fires only on a lock or an unlock and carries a Bool.

One trap: the vault's threading suites asserted the thread `onChange` ran on as a stand-in for the mutation's thread.
With delivery always on main, that check would pass whatever thread the mutation ran on.
`StoreObservers.notifyThreadForTests` (debug builds only) reports the thread a change was reported from, before the hop, and those suites read it instead.
`StoreObservableSelfTest` checks that two observers both hear a real change on each of the six, that unobserving one leaves the other, and that an off-main report is delivered on main.
Going back to last-assignment-wins fails it on every store.

### Test hooks out of the release binary (R2-ARCH-09)

`nm` over the release binary, demangled, found thirteen test-only symbols of this app's own: four `debug*` accessors and nine `*ForTests` seams on the shell, Home, the snippet expander and the herdr theme sync.
They sat outside `#if FM_SELFTESTS`, and most were kept out of the binary only by dead-stripping, which a production caller would undo.
Each is guarded now, with the two herdr seams beside them, and production reads the seams through accessors that answer `nil` in a release build.
`Scripts/check-release-symbols.sh` reads the release binary's symbol table and fails on any `debug<Upper>` or `*ForTests` symbol in the `GrandLine` module; CI's release job runs it.
`E2ETestingPolicySelfTest` fails if one of the fifteen moves back outside the guard or the workflow stops running the script.

### The system's parts in the toolbar and the inspector (R2-ARCH-06)

On macOS 14 and later the inspector is `NSSplitViewItem(inspectorWithViewController:)`, which AppKit lays out full height and, on macOS 26, wraps in glass; the controller paints no column of its own there.
Before macOS 14 the hand-drawn pane stays, and a suite forces it so both paths are covered on a machine that has the new one.
An off-screen render draws the system's glass as a placeholder with none of the inspector's views in it (the same in a bare AppKit window), so the tour lab composites the inspector's own views over it, as it already did for the sidebar.
The toolbar is customisable from a right click and Window > Customize Toolbar….
Only the items that are always there are in the palette; the page's own items stay where `reconcileDynamicItems()` puts them.
The result is saved to `AppSettings` and put back the first time the toolbar is in a window, with `autosavesConfiguration` still off.
Two traps: AppKit keeps every live toolbar with the same identifier in step, so a suite's "next launch" toolbar needs an identifier of its own; and a palette item built around a live view would take that view out of the toolbar, so the palette gets copies.
The bell keeps its hand-drawn badge: `NSToolbarItem.badge` is macOS 26 only, and CI's `macos-15` image builds with Swift 6.1.2 for `macosx15.0`, where it does not exist.

### The shell forwards nothing (R2-ARCH-05)

`WorkspaceShellController` carried about a hundred one-line forwards to the workspace's parts.
The main menu targets `workspace.navigator` for its navigation verbs now, and the app delegate, the palette and the suites reach the navigator, the host sessions, the lock and the workspace directly.
The call sites were rewritten from the compiler's own errors, about 500 of them.
`buildMenu` takes optional `MenuTargets`, which lets `NavigationCoherenceSelfTest` build the menu headless with stand-in targets and check that every item targets an object answering its action, in both layouts.
The same suite fails if the shell gains a member that only forwards a same-named member of the workspace.

### main.swift is the entry point (R2-ARCH-02)

`main.swift` was 4,900 lines: the composition root, the menu bar, session restore, the host editor and the self-test dispatch.
It is about 100 now, and holds only what runs before the delegate exists, in the order it always ran.
The rest moved verbatim, in four commits that each build and pass: `SelfTests/SelfTestDispatch.swift` (the 274 flags and the redirect block), `MainMenuBuilder.swift`, `SessionRestoreCoordinator.swift`, `HostEditorPresenter.swift` and `AppComposition.swift` (the `AppDelegate` class).
The four delegate files are extensions of `AppDelegate`, not new types: each reads the delegate's own state and targets its own verbs, so a new type would have rewritten every reference, which is a rewrite rather than a split.
`run-all-tests.sh` discovers suites from the dispatch file, and its `--list`, `--ci` and `--session-only` output is identical before and after.
About thirty suites read `main.swift` as source; they read `SelfTestSources.selfTestDispatchSource()` or `SelfTestSources.appDelegateSource()` (the delegate's files in order, `main.swift` first) now, and the feature inventory reads the delegate's files as `main`, so no inventory id changed.
`LaunchPathSelfTest.mainSwiftIsOnlyTheEntryPoint` caps `main.swift` at 150 lines, rejects a top-level type or function in it, and pins the launch order.


### Home's cards are sized by dragging (free resize)

The captain could only pick Small, Large or Full Width for a Home card, and asked to drag the width and the height to their own taste.
Customize now puts three grips on every card (`HomeCardResizeHandle`): the trailing edge sizes the width, the bottom edge the height, and the corner both.
The size menu in the card's controls became Reset Size, and a double-click on a grip puts that dimension back.

- **The width is a share of a 24-column grid (`HomeCardGrid`), not a point width.**
  A card keeps its place in the composition when the window changes size, and 24 divides by two, three and four, so halves, thirds and quarters line up across rows.
  At the sidebar layout's 1512 a column is about 50pt, which reads as a continuous drag.
- **A card is never narrower than the canvas's 255pt minimum.**
  When the window makes a card too narrow, its row makes room for it (`HomeCardGrid.rows`).
  This first shipped as widening the card on its own to the next quarter, third, half or full row, which overflowed the row; see "Home's rows fill beside the sidebar" below.
- **The height is optional.**
  A card nobody has dragged takes its row's height (`equalHeights`), exactly as before.
  A dragged card has its own height, snapped to 8pt and held between the card's own floor and 720pt, and it is exempt from the row's tie, so its neighbours keep their own heights.
  It is never drawn shorter than its content: the card never clips its body, so the drag stops where the content still fits.
- **The rows are still `HelmResponsiveGrid.spanningRows`**, which gained a fixed column count and a per-item fixed height.
  The fixed height goes on after the floor has measured the item's natural height; measured with it, the floor is the fixed height itself and the card can never be made shorter again without a rebuild.
- **The card being dragged survives the rebuild its own drag causes.**
  Its grips are the views the drag's events go to, and a rebuilt card's grips are new views.
  With the card rebuilt, the rest of the drag went to a view no longer in the page and the card stayed at its old width (measured with the reuse disabled: 588pt instead of the grid's 1192pt).
- **Migration is a read.**
  `fm.homeCardLayout` keeps its `sizes` map and gains `cardSizes`.
  A layout saved with fixed sizes reads `small`, `large` and `wide` as 6, 12 and 24 columns, which at four of the old columns are exactly the widths they drew.
  This build still writes the nearest fixed size into `sizes`, so an older build reading the same domain draws roughly the same Home.

Tests: `FM_RUN_SPLIT_SHELL_MODEL_TESTS` covers the sizes, their snapping and range, persistence, the migration and the grid arithmetic.
`FM_RUN_MAIN_SPLIT_SHELL_TESTS` drags each grip through its real mouse handlers and checks the width, the height, reflow without overlap, the content floor, the double-click and Reset Size.
Injected regressions (the migration mapping, the kept card, the fixed height) each failed a named case.
Verified visually with an off-screen render of the sidebar shell through the tour lab, in Daylight and Dusk.
A real pointer drag in a composited window was not verified, because screen capture is not granted on this machine.

### One sidebar width on every page

The captain reported the sidebar narrower on Home than on Console.
In their screenshots it was the 200pt minimum on Home and their stored 273.5pt on Console.
Home holds its grid's last width as a constant at `contentTie` (499), and the shell's sidebar held its width at 489, so a page's tie won.
Whenever Home had last been laid out for a wider column, it squeezed the sidebar to its minimum on every visit, and the next page's pin put it back.
Two ways in reproduced it on main: putting the sidebar away on Home and bringing it back on another page, and narrowing the window while another page showed.
Both stayed broken for the session, because Home then re-laid out for the squeezed column and held that.

The sidebar now holds at `MainSplitShellController.sidebarRestingPriority`, which is 499.5.
That is above every page's ties and still below the window's 500, so it cannot hold the window's size (gotcha (13)).
A divider drag and `setPosition(_:ofDividerAt:)` both place the divider at 490, which the resting priority would beat.
`WorkspaceShellSplitView` reports both, and the shell drops back to 489 only while a divider is being placed.
A synthetic drag in the off-screen shell moved the sidebar from 220pt to 260pt with the fix, and recorded 260 as the captain's width.
The shell lays the split view out before it restores the resting priority.
Without that, CI's macOS 15 runner left a `setPosition` to 224pt at 264, while macOS 26 passed.

The same work found the split view's own held divider position coming back after a pin was released.
`fm/grandline-flaky-sidebar-width-test-1793096163` fixed that independently for its CI flake (`holdDividerAtSidebarWidth`), and this branch is rebased onto it.
Without that fix, a sidebar placed at 224pt on Console and pinned back to 264 by the next page returned to 224 on Home in five runs of six.

Not fixed here: dragging the divider wider while Home is showing still does nothing, on main and with this change.
Every Home card width is at 499, which beats the drag's 490, so it needs Home's own priorities reworked.

`MainSplitShellSelfTest.checkTheSidebarKeepsOneWidthOnEveryPage` covers both ways in, a placement, and a real press on the divider through the window's event dispatch.
Reverting the resting priority fails it on Home at 200pt, and removing the `mouseDown` hook fails the press check.

### Home's rows fill beside the sidebar

The captain reported Home's cards broken with the sidebar open, while the same Home with the sidebar closed looked right.
Their arrangement was a row of 12, 7 and 5 columns over two halves.
At 1512 with the sidebar open, the grid is 1192pt and the narrowest readable card is 6 columns, so the 5-column Health card was too narrow.
Free sizing widened that one card on its own, to 6 columns, and the row became 25 columns.
Health dropped to the second row, which pushed Merge queue onto a third row of its own at half width, and every row ended short of the right edge.
Home's own cards broke the same way at 1280 and 1100.

`HomeCardGrid.rows` now lays out a whole row at a time:

- **The rows are the captain's own.**
  The stored widths are packed onto the grid in order, so at a width where every card can be read nothing changes.
- **A too-narrow card is held at the minimum, and its row makes room for it.**
  The columns come from the row's spare columns first, then from the widest card in the row, one column at a time.
  The captain's row draws as 11, 7 and 6 at 1512 with the sidebar open, and as 12, 7 and 5 with it closed.
- **A row that cannot hold its cards at the minimum is split.**
  It splits into as few rows as hold them, cut where the parts are most even, and each part fills the grid in proportion to its cards' widths.
  At 1100 with the sidebar open (a 9-column minimum) Home's own 12, 6 and 6 become the 12 alone and the two 6s as halves.
- **A drag sizes what the captain sees.**
  A drag measures the card's drawn width, so when it starts, the dragged card's row is stored at its drawn widths (`HomeCardGrid.drawnSpans`).
  Without that, narrowing Fleet beside the sidebar gave its column back to Morning briefing's stored 12 when the drag ended.
  A row the window has split is left as it was saved, because storing its parts would rewrite the whole composition.
- `HelmResponsiveGrid.spanningRows` takes the rows through `packedRows`, so where a row breaks is the caller's to say.

Tests: `SplitShellModelSelfTest.checkHomeCardGrid` checks the captain's case, splitting, spare columns, the drag's starting point, and that every full row stays full at every minimum from 1 to 24.
`MainSplitShellSelfTest.checkHomeRowsFillBesideTheSidebar` lays out Home's own cards and the captain's arrangement in a real window at 1512, 1280 and 1100, with the sidebar open and closed.
It checks every row reaches the grid's right edge and no card is under the minimum.
It also drags Fleet a column narrower beside the sidebar.
Restoring the per-card widening failed both suites by name (the captain's 1512 case among them), and removing the drag's starting row failed the drag check with Morning briefing back at 12 columns.
Verified visually with tour-lab renders of the captain's arrangement before and after, at 1512, 1280 and 1100.
Not addressed: at 1280 with the sidebar open, Fleet's 7-column card truncates "Done today" in its stat strip, which is the card's own content at that width.

### Home stays in sight at the top of the sidebar (R4-BUG-03)

Full review #4 found Home half hidden under the sidebar's header in several renders at 1512×950, always on pages whose module sits low in the list.
With Console holding one session the default list is 24 rows.
Measured in the off-screen shell, that is 836pt against an 823pt clip view.
Selecting a bottom row ran `scrollRowToVisible`, which lifted the whole column by the 13pt overflow, and nothing scrolled it back on the next page.
A rebuild (a session arriving or leaving) also ran `scrollRowToVisible` on the lit row, which threw away any scroll the captain had made.

Three changes:

- `WorkspaceSidebarMetrics.sectionRowHeight` is 30 rather than 34.
  The heading's label is pinned to the row's bottom, so only the gap above each group heading gives, and the list is 820pt.
  The default set now fits the 950pt window with nothing to scroll.
- A selection whose row is below the fold, in a list that overflows by less than one row, scrolls the list to the top rather than to the row.
  The lit row is then at most that overflow short of fully visible.
- A rebuild that does not change what is lit restores the previous scroll origin, clamped to the new list.

Not done: the review also asked for the default set to fit at the window's minimum height.
That is 620pt, which leaves about 490pt of clip view for 24 rows at the Large source-list size (32pt).
No group spacing reaches that, so below about 950pt the list still scrolls, and the two scroll rules above are what keep Home in sight there.

`SidebarRedesignsSelfTest.checkHomeStaysInSight` visits every module at 950pt with one session and asserts row 0 stays inside the clip view and the list does not overflow.
It also shortens the window so the list overflows by 10pt and visits the last module, and scrolls a 700pt sidebar to 40pt and adds a session.
Confirmed to fail with the 34pt heading (13pt overflow, Home clipped on Settings), with a plain `scrollRowToVisible` (Home scrolled 20pt under the header), and with the rebuild revealing the lit row again (the scroll moved from 40 to 0).

### Full review #4's UI issues (R4-UI-01 to R4-UI-10)

Full review #4 (`data/grandline-full-review-4-fable-1793170500/report.md`, section 7) listed ten UI issues.
Each was reproduced in the review tour lab first, then compared before and after at 1512, 1280, 1100 and 960, in Dusk and Daylight, and at Larger text for the toolbar.
The "before" renders came from a binary built from `main`'s sources, not from the review's own folder.

**R4-UI-01, the toolbar.**
Measured at 1512 on every module, Crew and Connections put Recents and the inspector button in the overflow menu at Default text.
At Larger text, five modules overflowed two to four items each, the inspector button every time.
Two changes:

- The inspector button is `.high` on a page that fills the inspector (Connections, Secrets, Setup, GitHub sync) and stays `.low` everywhere else (`WorkspaceToolbar.setPageHasInspectorContent`).
  At Default text on Connections, Recents and Activity now overflow and the inspector button stays.
- The compact toolbar's 1240pt breakpoint follows the chrome text scale (`WorkspaceToolbar.compactWidth(scale:)`), so at Larger text it starts at 1612.
  Nothing overflows on any module at 1512 with Larger text.

`WorkspaceToolbarSelfTest` asserts both, on every module, at Default and Larger text.
It fails by name with the inspector left at `.low` and with the fixed breakpoint.

**R4-UI-03, the rainbow band, was the lab and not the app.**
macOS 26 wraps the inspector item in its own Liquid Glass view (`NSContainerConcentricGlassEffectView`), which runs the window's full height.
Rendered alone through `cacheDisplay`, that view comes out as the glass shader's texture: a pink panel with red, green and blue bevelled edges.
The lab repaints the inspector only below the toolbar, so the texture's top 52pt showed as a band.
No app view draws in that strip (walked from the frame view at the band's centre).
`ReviewTourLab.writeSplitShellPNG` now hides that view for its one capture.
The live window was not looked at, because this shell has no Screen Recording grant, so one live look from the captain still settles it.
Two more lab fixes from the same pass:

- A web view a visible sibling covers is no longer pasted over it.
- The pale inspector empty-state title in Daylight renders is `cacheDisplay` again.
  The live label reads `0.16, 0.17, 0.20` in a `VibrantLight` appearance.

**The rest.**

- R4-UI-02: `HelmKPIStrip` holds each column's labels at their own width, one step above the equal-column tie (`labelFloorPriority`), so "Done today" takes width from its neighbours rather than truncating.
  The Health ring's note wraps at the column beside the gauge (gotcha (22)), not at the card's body width.
- R4-UI-04: every clause the briefing produces is a link, so the dotted underline covered the whole paragraph.
  The clauses keep their tint at rest, and only the clause under the pointer is underlined, as a temporary attribute.
- R4-UI-05: the Reading list's band under the header is gone.
  Refresh is a page action beside Paste link.
  The band's paste icon ran the same `pasteTapped` as Paste link, so it went, and its drop hint was the drop card's.
- R4-UI-06: an editable shortcut draws its chord as the fixed rows' keycaps (`KeyChord.keycaps`), with a pencil as the edit affordance.
- R4-UI-07: copy that named a module by an older page's title reads `ModuleTable` (through `PlaceName` where the floating bar words it differently).
  Names chosen: Connections, Secrets, Setup, Console and Tools.
  Poneglyph and Automic Vault stay, as the names of the Secrets module's own tabs.
- R4-UI-08: when Tasks' filter row does not fit, the project and sort pop-ups become one Filter button, and the Follow-ups jump and the Done window's note move into its menu.
  It is measured from the expanded controls' fitting widths, so it cannot flip back and forth.
  The scope tabs also stopped taking the row's slack (gotcha (10)).
- R4-UI-09: Snippets says why it asks for Accessibility while access is not granted, and Code opens on a "No snippets yet" invitation rather than an unsaved `snippet-1.txt`.
  The Weekly review lists next week under its lower row, from the same `ShiftStore.nextWeekAgenda` the tile counts.
  The Tasks board is in [`08-tasks-and-shift.md`](08-tasks-and-shift.md).
- R4-UI-10: the floating bar's uncapped Merge queue card is not changed, because the floating bar is frozen as classic (the captain's call, PR #532).

`ReviewFourUISelfTest` covers R4-UI-02, 04, 06, 07, 08 and 09.
`ReadingListViewSelfTest` covers R4-UI-05, and `CodePreviewViewSelfTest` covers the Code invitation.
Each check was injected against: the label floor at `.defaultLow`, the ring note at the body width, an underline at rest, the lane kept off the board, the row never collapsing, and the recorder printing text.

### Full review #4's UX improvements (R4-UX-01 to R4-UX-10)

Section 8 of full review #4 listed ten before/after improvements.
R4-UX-09 (Follow-ups on the board, Projects as the filter pop-up) and R4-UX-10 (the Weekly review's lower row) had already shipped with R4-UI-09, above.
The snooze list and its expiry timer had shipped with PR #551 and #552, so R4-UX-03 here is only the until-time.

- R4-UX-01: the Calendar takes ⌘0 in the sidebar layout's Go menu (`WorkspaceGoMenu.zeroChordModule`).
  It stays out of the ⌘1-⌘9 count, so every digit the captain already knows is where it was.
  ⌘0 was free: the floating bar's Home ⌘0 went with UX issue X3, and `TabKeyboardShortcuts` never claims it.
- R4-UX-02: the vault's creation warning no longer says "There is no recovery" on a page that offers a recovery kit.
  It says the vault stays sealed unless a recovery key is printed, and that nobody can reset the password.
  The creation form offers "Print a recovery key next", on by default and never a gate.
  Once the new vault exists and is unlocked, it opens the existing recovery kit sheet, so the code is minted and shown by the same paths the toolbar's button uses.
- R4-UX-03: a Snoozed row's return time is a chip ("until tomorrow, 9:00 AM"), and the footer after a snooze names the time rather than the preset ("Snoozed until 6:00 PM").
- R4-UX-04: the Hosts side panel has a Test button beside Connect (`HostConnectionTest`).
  It runs `ssh -o BatchMode=yes -o ConnectTimeout=5 [-J] [-p] -- <dest> true` through `Subprocess`, from the stored record, and refuses any host `Host.unsafeFieldNames` flags.
  It leaves out agent forwarding and port forwards, and it does not unlock a saved key (a Keychain read can raise Touch ID), so a host with one reads "Connect will use the saved key" rather than "asks for a password".
  The test is offered on a clean form only, because a form with edits is Cancel and Save.
  When a saved key cannot be used and ssh starts without it, the session strip says "Key refused, asking for a password" for that host, as well as the terminal.
- R4-UX-05: the inspector button is disabled on a page that fills nothing in the inspector, and such a page never opens the empty pane.
  The captain's standing request carries to the next page that has details.
  Home's module cards take the keyboard now (an exterior focus ring), and Return or Space opens the card's module.
- R4-UX-06: the merge confirm reads "#42 Title", then "repo · branch", then the check state, with the URL last.
  The branch comes from the crew task's `.meta`, which `FleetTask` now reads.
- R4-UX-07: Sticky Board and the Reading list already had one `HelmEmptyState` with one action (R2-UX-07's shape), so they are unchanged.
  The Whiteboard gains the same shape over an empty board: one action that draws an example flowchart through `DiagramDSL`, and a click anywhere else starts on the blank board for the rest of the session.
  Kubernetes' scope wall is three numbered steps, and its one action is primary.
- R4-UX-08: a finished backup is a `.lasting` report (`BackupUI.exportReportID`, kicker "Backup Saved") whose bell line says where it was saved, and a local file's row reveals it in Finder.
  A schedule's running row has Stop, and so does its menu.
  It cancels the run's subprocesses through the token a confirmed quit already uses, and the run records "Stopped from the Schedules page.".
  The Fleet page shows Stop in Refresh's place while a pass is in flight, in the window toolbar in the sidebar layout.
  Beside Refresh it was one item too many: CI's 1x runner measured the breadcrumb overflowing at Larger text and 1512pt, which a 2x Mac did not reproduce.
  It abandons the pass rather than killing it (the PR scan's children run on other threads, outside any scope token), and the PR reading says the scan was stopped rather than claiming a count.

`ReviewFourUXSelfTest` covers R4-UX-01, 04, 05, 06, 07 and 08's backup report and Fleet Stop.
The vault, snooze, inspector, Whiteboard, host panel and schedule halves live in their pages' own suites.
The tour lab's `ux <state>` verb puts each state on screen for a render.
