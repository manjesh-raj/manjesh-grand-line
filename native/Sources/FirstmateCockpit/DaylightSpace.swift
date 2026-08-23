// Manjesh Grand Line - native macOS app.
//
// `DaylightSpace` - the five space pills, and the module-to-space table
// behind them (Daylight migration §5.3, §5.4).
//
// **The one rule this file exists to keep true: a space is presentation
// state and nothing else.** No store, poller, registry or notification
// source knows spaces exist. `HomeCanvasController` owns the currently
// selected space, `DaylightBarController` draws the pills, and the table
// below is consulted only when deciding which module cards to lay out. That
// is deliberate - it means a space can be renamed, reordered or dropped
// without touching a single line of data code, and it means nothing in the
// app can develop a second, drifting opinion about which area a page belongs
// to.
//
// The five spaces and their exact membership are a **locked captain
// decision** (the migration spec's own decisions block, items 3-5), restated
// here as code and asserted by `DaylightModuleSelfTest.checkSpaceTable`
// against that same list. Do not re-litigate the membership; if it ever
// genuinely changes, change it here and in that test together so the two
// cannot disagree.

import Foundation

/// One of the five filters the bar's space pills switch between.
///
/// Declaration order **is** pill order, left to right, and is what `⌘1`…`⌘5`
/// index into - `allCases` is the single source for both.
enum DaylightSpace: String, CaseIterable {
    case overview
    case command
    case operations
    case stores
    case engineering

    /// The pill's label, and the canvas hero title for every space except
    /// Overview (which shows a time-of-day greeting instead - see
    /// `HomeCanvasController.renderGreeting`).
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .command: return "Command"
        case .operations: return "Operations"
        case .stores: return "Stores"
        case .engineering: return "Engineering"
        }
    }

    /// §5.4's subtitle copy, verbatim. Overview's is generated from real
    /// fleet state instead and this string is its only fallback - shown
    /// before the first snapshot lands, never as a claim about the fleet.
    var subtitle: String {
        switch self {
        case .overview: return "Your whole control room at a glance."
        case .command: return "Console, tasks and the merge queue."
        case .operations: return "Hosts, logs, health and schedules - the running systems."
        case .stores: return "Vault, docs, tools and dictation - your reference shelf."
        case .engineering: return "Toolchain setup and this machine's settings."
        }
    }

    /// The 1-based index this space's `⌘N` shortcut carries.
    var shortcutIndex: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

/// Every module the canvas can render.
///
/// A module is *not* a destination: `.briefing` and `.fleet` have no page of
/// their own on the canvas's own terms (they open Overview), and the per-host
/// console pages deliberately have no module at all. The mapping to a
/// `RailDestination` is `opens` below, which is what a card's click calls
/// `show(_:)` with.
///
/// **Every module is one column wide and every card is the same height,
/// except the Morning briefing, which is two columns wide and the same
/// height.** That reads as three decisions and is really the captain's own
/// two, arrived at over three passes:
///
///   1. §6.1 gave the briefing a "wide variant" spanning two grid columns.
///      Phase 2 shipped it.
///   2. PR #259 read a captain instruction about uniform sizing as covering
///      the briefing too and removed the wide variant entirely - `span` and
///      `HelmModuleCard.Content.isWide` were deleted.
///   3. That was a misreading. The briefing genuinely needs the extra width
///      for its generated paragraph, so `gridSpan` below restores it; what
///      the instruction was actually asking for is that *every other* card
///      match, in **height** as well as width - which PR #259 never
///      addressed, since each body kind still rendered at its own natural
///      height and left the rows ragged.
///
/// So: `gridSpan` is 2 for exactly one module and 1 for the rest, and
/// `HelmModuleCard.standardHeight` applies to all of them. Any *other* module
/// asking for span 2 is per-card sizing creeping back;
/// `DaylightModuleSelfTest.checkUniformCardSizing` fails the build if the set
/// of wide modules changes or if a row ever renders cards of differing height.
///
/// **The four Setup sub-pages each get their own card** (`.updates`,
/// `.bootstrap`, `.automation`, `.githubSync`) rather than one aggregate
/// "Setup" card, also on the captain's direct instruction. Each reads the
/// signal its own page owns out of `BackgroundSignalsPoller.lastCounts` -
/// already computed for the Notification Center, never a fresh check from the
/// canvas. They keep the Setup flyout's own glyphs so a captain used to that
/// flyout recognises them here, and they all resolve to §2.2's amber through
/// `opens.domainHue` because the hue belongs to the *area*, not the page.
enum DaylightModule: String, CaseIterable {
    case briefing
    case fleet
    case tasks
    case mergeQueue
    case console
    case health
    case hosts
    case updates
    case bootstrap
    case automation
    case githubSync
    case schedules
    case logAnalyzer
    case vault
    case docs
    case dictation
    case tools
    case settings

    /// Which space this module belongs to, or `nil` for the two that appear
    /// **only** on Overview (locked decision 5: "The Morning briefing and
    /// Fleet cards appear ONLY on Overview").
    ///
    /// Overview shows every module regardless; the other four spaces show
    /// exactly the modules whose space matches.
    var space: DaylightSpace? {
        switch self {
        case .briefing, .fleet: return nil
        case .console, .tasks, .mergeQueue: return .command
        case .hosts, .logAnalyzer, .health, .schedules: return .operations
        case .vault, .docs, .tools, .dictation: return .stores
        case .updates, .bootstrap, .automation, .githubSync, .settings: return .engineering
        }
    }

    /// Is this module shown while `space` is selected?
    func isVisible(in space: DaylightSpace) -> Bool {
        space == .overview || self.space == space
    }

    /// How many grid columns this module's card consumes (§6.1's "wide
    /// variant").
    ///
    /// Two for the Morning briefing and one for everything else - see the
    /// three-pass history in this enum's own doc comment for why that is the
    /// shape rather than "all one" or "whichever card feels important". The
    /// briefing is the only module whose body is prose, and prose needs
    /// measure: at one column its paragraph wrapped so tightly that it had to
    /// be cut to three clauses to fit.
    ///
    /// `HelmResponsiveGrid.packRows` degrades a span-2 card to span 1 in a
    /// single-column grid rather than overflowing, so a very narrow window
    /// needs no special case here.
    var gridSpan: Int {
        switch self {
        case .briefing: return 2
        default: return 1
        }
    }

    /// The destination a click on this module's card opens.
    var opens: RailDestination {
        switch self {
        case .briefing, .fleet: return .overview
        case .tasks: return .shift
        case .mergeQueue: return .review
        case .console: return .console
        case .health: return .health
        case .hosts: return .hosts
        case .updates: return .updates
        case .bootstrap: return .bootstrap
        case .automation: return .automation
        case .githubSync: return .githubSync
        case .schedules: return .schedules
        case .logAnalyzer: return .logAnalyzer
        case .vault: return .vault
        case .docs: return .docs
        case .dictation: return .dictation
        case .tools: return .tools
        case .settings: return .settings
        }
    }

    /// §4's SF Symbol for this module's gradient tile. Every one of these is
    /// verified to resolve by `DaylightModuleSelfTest.checkSymbolsResolve` -
    /// `NSImage(systemSymbolName:)` returns nil silently, and this app has
    /// shipped an invisible icon exactly that way before.
    var symbol: String {
        switch self {
        case .briefing: return "cup.and.saucer.fill"
        case .fleet: return "sailboat.fill"
        case .tasks: return "checkmark.circle.fill"
        case .mergeQueue: return "arrow.triangle.branch"
        case .console: return "terminal.fill"
        case .health: return "heart.text.square.fill"
        case .hosts: return "desktopcomputer"
        case .updates: return "steeringwheel"
        case .bootstrap: return "hammer.fill"
        case .automation: return "bolt.fill"
        case .githubSync: return "arrow.2.squarepath"
        case .schedules: return "clock.fill"
        case .logAnalyzer: return "text.magnifyingglass"
        case .vault: return "lock.fill"
        case .docs: return "book.fill"
        case .dictation: return "mic.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .settings: return "slider.horizontal.3"
        }
    }

    /// §2.2's hue for this area of the app.
    ///
    /// Read from the destination this module opens wherever that is the same
    /// idea (`RailDestination.domainHue`, Phase 1's own table), so the module
    /// card and the drill page it opens can never disagree about a hue. The
    /// two exceptions are the Overview-only pair, which share a destination
    /// but not a hue: the briefing is amber (§4), Fleet is blue.
    var hue: HelmDomainHue {
        switch self {
        case .briefing: return .amber
        case .fleet: return .blue
        default: return opens.domainHue
        }
    }

    /// The card's title.
    var title: String {
        switch self {
        case .briefing: return "Morning briefing"
        case .fleet: return "Fleet"
        case .tasks: return "Tasks"
        case .mergeQueue: return "Merge queue"
        case .console: return "Console"
        case .health: return "Health"
        case .hosts: return "Hosts"
        case .updates: return "Updates"
        case .bootstrap: return "Bootstrap"
        case .automation: return "Automation"
        case .githubSync: return "GitHub Sync"
        case .schedules: return "Schedules"
        case .logAnalyzer: return "Log Analyzer"
        case .vault: return "Vault"
        case .docs: return "Docs"
        case .dictation: return "Dictation"
        case .tools: return "Tools"
        case .settings: return "Settings"
        }
    }

    /// Canvas order, top-left to bottom-right. Declaration order is the
    /// order - `allCases` is the only list.
    static var canvasOrder: [DaylightModule] { allCases }
}
