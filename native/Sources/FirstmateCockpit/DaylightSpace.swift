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
/// **Every module renders at the same single-column size.** The migration
/// spec's §6.1 gave the Morning briefing a "wide variant" spanning two grid
/// columns, and that is what Phase 2 shipped; the captain overrode it after
/// seeing it live, because one double-width card among a dozen uniform ones
/// reads as inconsistent rather than as emphasis. There is deliberately no
/// `span` property here any more - reintroducing one is how per-card sizing
/// creeps back, and `DaylightModuleSelfTest.checkUniformCardSizing` fails the
/// build if any row ever renders cards of differing widths.
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
