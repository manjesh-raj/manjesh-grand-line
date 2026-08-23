// Manjesh Grand Line - native macOS app.
//
// `RailDestination` - the app's fixed body destinations.
//
// Split out of `IconRailController.swift` (a P3 item in the production
// review's own batch, section 21) once GL-37 gave this enum a second real
// consumer: `DestinationRegistry.swift` maps every case here onto a body
// view, and `AppShellController` switches on nothing else. It was declared in
// the rail's own file for historical reasons - the rail was the only thing
// that used it - and 108 lines of enum plus its accumulated doc comment
// sitting above a 1,900-line view controller made both harder to find.
//
// Nothing about the enum changed in that move. **Daylight Phase 2 did change
// one thing about it**: the case order used to be load-bearing (the rail
// iterated `allCases` to lay itself out top to bottom), and with the rail
// gone nothing iterates it for layout any more. See the enum's own doc
// comment below.

import AppKit

/// The rail's eleven destinations. Switching order (captain correction,
/// theme-audit task): Overview, Console, Hosts, then Review, then Settings -
/// overriding fixes4 Fix 2's Console/Hosts-first ordering. Note that this is
/// the *switching* order only - Settings' *visual* position in the rail is
/// moved to after the dynamic per-host icon block (see `loadView`), directly
/// above the avatar. `.updates` (cockpit-native-updates-page) follows the
/// same rule: it is a real `RailDestination` for switching purposes, but its
/// *visual* position is pinned directly above Settings (so above the avatar,
/// below the per-host icon block) regardless of case order here. `.bootstrap`
/// (cockpit-bootstrap-scaffold) follows the identical convention, pinned
/// between `.updates` and `.settings`.
/// `.docs` (cockpit-docs-viewer) follows the identical convention too, pinned
/// directly *above* `.updates` - so the bottom-anchored group reads Docs,
/// Updates, Bootstrap, Settings, avatar.
/// `.tools` (cockpit-tools-page-core) follows the identical convention too,
/// pinned directly *above* `.docs` - so the bottom-anchored group reads
/// Tools, Docs, Updates, Bootstrap, Settings, avatar.
/// `.vault` (fm/grandline-vault-tab) follows the identical convention too,
/// pinned directly *above* `.docs` and below `.tools` - so the bottom-
/// anchored group reads Tools, Vault, Docs, Updates, Bootstrap, Settings,
/// avatar.
/// `.dictation` (fm/grandline-dictation-mvp, phase 1) follows the identical
/// convention too, pinned directly *above* `.docs` and below `.vault` - so
/// the bottom-anchored group reads Tools, Vault, Dictation, Docs, Setup
/// (-> Updates, Bootstrap, Automation flyout), avatar.
/// `fm/grandline-rail-setup-group` merged `.updates`/`.bootstrap`'s two
/// standalone rail rows into one "Setup" entry, directly above `.docs`, that
/// opens a small flyout `NSPopover` listing Updates and Bootstrap - so the
/// bottom-anchored group visually reads Tools, Vault, Docs, Setup
/// (-> Updates, Bootstrap flyout), avatar. Both cases remain real
/// `RailDestination`s for switching purposes - only their rail position/
/// visibility changed; see `IconRailController.buildSetupButton()`/
/// `showSetupFlyout()`. `.automation` (fm/grandline-automation-pipeline)
/// follows the identical convention: a third real `RailDestination` with no
/// rail row of its own, reachable only as the Setup flyout's third entry,
/// below Updates and Bootstrap. `.githubSync` (fm/grandline-setup-github-sync)
/// follows the identical convention too: a fourth real `RailDestination` with
/// no rail row of its own, reachable only as the Setup flyout's fourth entry,
/// below Automation.
/// `.schedules` (fm/grandline-schedules-sidebar-move) is the opposite of all
/// of the above: F11's Schedules card used to live nested inside `.automation`
/// (still behind the Setup flyout), and the captain's own correction was that
/// it should NOT be a flyout/sub-page destination - it gets its own rail
/// icon, directly visible, alongside Tools/Vault/Dictation/Docs. It stays a
/// utility (`isDailyUse == false`, see that property's own doc comment for
/// the criterion: it runs itself and reports to Health rather than being
/// something a captain checks in on daily), pinned directly *above* `.docs`
/// and below `.dictation` - so the bottom-anchored group now reads Tools,
/// Vault, Dictation, Schedules, Docs, Setup
/// (-> Updates, Bootstrap, Automation, GitHub Sync flyout), avatar.
/// `.automation`'s own "Run Automation" pipeline stepper is unaffected and
/// stays exactly where it was.
/// `.health` (fm/grandline-health-sidebar-move) is the same move applied to
/// F1/GL-11's Health card: it used to be the last card on the Settings page,
/// scrolled to past Connection/Appearance/Terminal/Security/Backup. It is a
/// utility (`isDailyUse == false` - it reports on background services rather
/// than being something a captain checks in on daily), pinned directly
/// *above* "Setup" and below `.docs` - the same "it's the thing you check
/// when something feels stale, so it goes last" placement its old Settings-
/// card comment used to explain - so the bottom-anchored group now reads
/// Tools, Vault, Dictation, Schedules, Docs, Health, Setup (-> Updates,
/// Bootstrap, Automation, GitHub Sync flyout), avatar. Settings' own
/// Connection/Appearance/Terminal/Security/Backup cards are unaffected and
/// stay exactly where they were.
/// `fm/grandline-avatar-menu-and-setup-guide` removed `.settings`'s own
/// standalone rail row entirely - it is still a real `RailDestination` for
/// switching purposes (`AppShellController.show(.settings)` is unchanged),
/// but its only entry point now is a "Settings" row inside the avatar
/// popover, alongside "Logout" (see `AvatarLogoutPopoverController`). This
/// continues the same crowding-reduction direction as the Setup group
/// consolidation above - one less item in the bottom-anchored utility group.
/// `.shift` (cockpit-shift-foundation) is different from all of the above:
/// it's a daily-use destination, not a utility, so it is NOT part of the
/// bottom-anchored group - it lives in `navStack` alongside the other fixed
/// destinations. `fm/cockpit-shift-rail-position` moved it from right after
/// `.overview` to right after `.hosts` (captain correction), so `navStack`
/// reads Overview, Console, Hosts, Shift, Review - `loadView`'s `navStack`
/// loop gets this for free just from case order (case order drives
/// `navStack`'s iteration order, same as every other `navStack` member).
///
/// `isDailyUse` (fm/grandline-sidebar-labeled-nav) marks the 6
/// `navStack` members (Overview, Console, Hosts, Shift, Review, Log
/// Analyzer - the last added by `fm/grandline-log-analyzer-build`) as the set
/// that lives in the top `navStack` block rather than the bottom-anchored
/// utility group - `navStack`'s loop and the bottom-anchored `loadView` block
/// both filter on this directly. It no longer selects a *different visual
/// style*: `fm/grandline-sidebar-nav-polish` gave every row (daily-use,
/// utility, and per-host) the same labeled icon-over-text treatment after
/// live captain feedback that icon-only utility rows looked inconsistent
/// once the rest of the rail had labels - see `labeledRailButton(for:)`.
/// **Daylight Phase 2 note.** The icon rail this enum is named after no
/// longer exists as a visible surface - `DaylightBarController`'s floating
/// bar plus `HomeCanvasController`'s module grid replaced it (migration
/// §5.1). The enum itself survives unchanged and un-renamed, deliberately:
/// §5.1's own "survives" list names it as the routing enum, every menu item,
/// keyboard shortcut and deep-link closure in the app switches on it, and
/// `DestinationRegistry` keys its table off it. Renaming it would be a
/// large, purely cosmetic diff across ~20 files.
///
/// Two consequences of the rail's removal that matter when editing this file:
///   - **Case order is no longer load-bearing.** It used to be the rail's
///     top-to-bottom order (`allCases` drove `navStack`'s loop). Nothing
///     iterates `allCases` for layout any more; the canvas's own order is
///     `DaylightModule.canvasOrder`. The long history below is kept because
///     it records real captain decisions about grouping, not because
///     reordering these cases still moves anything on screen.
///   - `isDailyUse` and `flyoutTint` have no remaining consumer in the shell.
///     They are left in place rather than deleted so the rail's own
///     decision history stays greppable; if a future phase wants a rail-like
///     surface back, they are what it should read.
enum RailDestination: CaseIterable {
    /// Daylight Phase 2: the home canvas (`HomeCanvasController`) - the hub
    /// every module card and every drill page's back button returns to. It is
    /// a real destination in every sense (a registered slot, an eager mount,
    /// reachable through `show(_:)`), so nothing about routing needed a
    /// second concept.
    case homeCanvas
    case overview, console, hosts, shift, review, logAnalyzer, tools, vault, dictation, schedules, health, docs, updates, bootstrap, automation, githubSync, settings

    var symbol: String {
        switch self {
        // §4's tile table: the canvas is the app itself, so it takes the
        // app's own mark.
        case .homeCanvas: return "sailboat.fill"
        case .overview: return "square.grid.2x2"
        // fm/grandline-rail-followup-fixes: the captain asked for the menu
        // bar's Shift/Tasks status item to use the same "sailboat" glyph as
        // the app's own logo mark, since that standalone item has no nearby
        // app branding to associate it back to this app (see
        // `ShiftMenuBarController.init`). The rail's own `.shift` row
        // deliberately keeps `checkmark.circle` rather than also switching
        // to `sailboat` - the rail already shows the real sailboat logo mark
        // directly above this row (`IconRailController.loadView`'s `mark`),
        // so a second sailboat a few rows down would read as a duplicate
        // icon rather than a clearer one.
        case .shift: return "checkmark.circle"
        case .hosts: return "server.rack"
        case .console: return "terminal"
        case .review: return "arrow.triangle.branch"
        // `fm/grandline-log-analyzer-build`: a magnifier over lines - the
        // "read this output" idea, distinct from `.review`'s branch glyph
        // and from Console's bare terminal.
        case .logAnalyzer: return "text.magnifyingglass"
        case .tools: return "wrench.and.screwdriver"
        case .vault: return "lock.shield"
        case .dictation: return "waveform"
        // `fm/grandline-schedules-sidebar-move`: a calendar - matches
        // `SchedulesCardView`'s own header icon, so the rail row and the
        // card it opens onto agree.
        case .schedules: return "calendar"
        // `fm/grandline-health-sidebar-move`: matches `HealthCardView`'s own
        // header icon, so the rail row and the card it opens onto agree.
        case .health: return "waveform.path.ecg"
        case .docs: return "book.closed"
        case .updates: return "steeringwheel"
        case .bootstrap: return "hammer"
        case .automation: return "bolt.fill"
        case .githubSync: return "arrow.2.squarepath"
        case .settings: return "gearshape"
        }
    }

    var title: String {
        switch self {
        case .homeCanvas: return "Home"
        case .overview: return "Fleet"
        case .shift: return "Tasks"
        case .hosts: return "Hosts"
        case .console: return "Console"
        case .review: return "Review"
        case .logAnalyzer: return "Log Analyzer"
        case .tools: return "Tools"
        case .vault: return "Vault"
        case .dictation: return "Dictation"
        case .schedules: return "Schedules"
        case .health: return "Health"
        case .docs: return "Docs"
        case .updates: return "Updates"
        case .bootstrap: return "Bootstrap"
        case .automation: return "Automation"
        case .githubSync: return "GitHub Sync"
        case .settings: return "Settings"
        }
    }

    /// The hue this destination's icon carries wherever it is drawn as an
    /// `IconTileView` rather than a bare rail glyph - today that is the Setup
    /// flyout's four rows (`SetupFlyoutViewController`).
    ///
    /// `fm/grandline-sre-lead-and-setup-icons`: every one of those rows used
    /// to pass a hardcoded `.accent`, so all four rendered the identical
    /// teal tile and the flyout read as one undifferentiated block - measured
    /// in a real render, all four glyphs sampled the same `rgb(165,218,229)`.
    /// The captain's own proposed mockup assigns each row a distinct hue, and
    /// sampling that mockup's pixels resolves each one to a `HelmTint` this
    /// app already has: blue `.info` for Updates, amber `.warn` for
    /// Bootstrap, the theme accent for Automation, magenta `.violet` for
    /// GitHub Sync. Semantic tints, not literals, so all 12 palettes resolve
    /// their own hues.
    ///
    /// Every other destination keeps `.accent` - the rail's own rows are
    /// plain tinted glyphs with no tile behind them, and this property is
    /// only consulted where a tile is actually drawn.
    ///
    /// **Measured caveat, recorded rather than hidden:** `.accent` for
    /// Automation resolves to the *same hue as a neighbouring row* in 3 of
    /// the 12 palettes, because those palettes genuinely define their accent
    /// as that hue - `tokyo-night-dark`/`-light` set `accentHex` to their own
    /// blue (`ansiHex[4]`, so Updates and Automation match) and
    /// `rose-pine-main` sets it to its own magenta (`ansiHex[5]`, so
    /// Automation and GitHub Sync match). Swapping Automation to `.good`
    /// removes every collision (measured: zero in all 12), but `.good` is
    /// green in `helm-dark` where the captain's own reference mockup shows
    /// the accent cyan - and the brief names those screenshots as ground
    /// truth. Exact fidelity in the reference palette was chosen over
    /// collision-freedom in three others; this is still a strict improvement
    /// everywhere, since before this all four rows shared one hue in all 12.
    /// Revisit by adding a genuinely distinct semantic `HelmTint` case, not
    /// by hardcoding a literal here.
    var flyoutTint: HelmTint {
        switch self {
        case .updates: return .info
        case .bootstrap: return .warn
        case .automation: return .accent
        case .githubSync: return .violet
        case .homeCanvas, .overview, .console, .hosts, .shift, .review, .logAnalyzer,
             .tools, .vault, .dictation, .schedules, .health, .docs, .settings: return .accent
        }
    }

    var isDailyUse: Bool {
        switch self {
        case .homeCanvas, .overview, .console, .hosts, .shift, .review, .logAnalyzer: return true
        case .tools, .vault, .dictation, .schedules, .health, .docs, .updates, .bootstrap, .automation, .githubSync, .settings: return false
        }
    }
}
