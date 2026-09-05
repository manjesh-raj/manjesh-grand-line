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
    case kubernetes
    case vault
    case docs
    case runbooks
    case postmortems
    case dictation
    case tools
    case whiteboard
    case stickyBoard
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
        case .hosts, .logAnalyzer, .kubernetes, .health, .schedules: return .operations
        // `fm/grandline-docs-split-runbooks-postmortems` added Runbooks and
        // Postmortems here, promoted out of `DocsController`'s own tabs into
        // their own destinations - see `DaylightModuleSelfTest.checkSpaceTable`,
        // updated alongside this per this file's own "change it here and in
        // that test together" rule.
        case .vault, .docs, .runbooks, .postmortems, .tools, .dictation, .whiteboard, .stickyBoard: return .stores
        case .updates, .bootstrap, .automation, .githubSync, .settings: return .engineering
        }
    }

    /// Whether this module's card renders on the Overview canvas
    /// specifically (`fm/grandline-overview-canvas-trim`).
    ///
    /// True by default; false for the twelve modules the captain asked
    /// removed from Overview after reviewing a live screenshot - the canvas
    /// had grown to eighteen cards, most of which duplicated a page already
    /// one click away via its own space (Command/Operations/Stores/
    /// Engineering), the nav, or `⌘K`. What Overview keeps is the pair with
    /// no other home (`.briefing`/`.fleet`, `space == nil`) plus the small
    /// "operational pulse" set the captain wants visible at a glance without
    /// switching spaces: `.mergeQueue`, `.console`, `.health`, `.schedules`.
    ///
    /// **This is presentation-only, exactly like `space`/`isVisible` above -
    /// it removes a module's card from the Overview canvas, nothing else.**
    /// A module with `appearsOnOverview == false` still has its own
    /// `RailDestination`, is still fully functional, and still renders its
    /// card on its own space's canvas via `isVisible(in:)` below (which only
    /// special-cases `.overview`) - `.tasks`' card still shows on Command,
    /// `.vault`'s still shows on Stores, and so on. Nothing was deleted.
    var appearsOnOverview: Bool {
        switch self {
        case .tasks, .hosts, .updates, .bootstrap, .automation, .githubSync,
             .logAnalyzer, .kubernetes, .vault, .docs, .runbooks, .postmortems, .dictation, .tools, .whiteboard, .stickyBoard, .settings:
            return false
        default:
            return true
        }
    }

    /// Is this module shown while `space` is selected?
    ///
    /// Overview is special-cased to `appearsOnOverview` rather than "every
    /// module" (§5.3's own model, extended by the trim above); every other
    /// space is unaffected and still shows exactly the modules whose own
    /// `space` matches.
    func isVisible(in space: DaylightSpace) -> Bool {
        if space == .overview { return appearsOnOverview }
        return self.space == space
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
        case .kubernetes: return .kubernetes
        case .vault: return .vault
        case .docs: return .docs
        case .runbooks: return .runbooks
        case .postmortems: return .postmortems
        case .dictation: return .dictation
        case .tools: return .tools
        case .whiteboard: return .whiteboard
        case .stickyBoard: return .stickyBoard
        case .settings: return .settings
        }
    }

    /// B5 (`data/grand-line-e2e-audit/report.md`): the space a given
    /// destination belongs to, derived from the module table above rather than
    /// restated - so there is one mapping, not two that can disagree.
    ///
    /// `nil` for a destination no module opens (nothing to highlight) and for
    /// `.overview`/`.homeCanvas`, whose space is whichever one the captain
    /// last picked, not a property of the destination.
    static func space(forDestination dest: RailDestination) -> DaylightSpace? {
        guard dest != .overview, dest != .homeCanvas else { return nil }
        return allCases.first { $0.opens == dest }?.space
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
        case .kubernetes: return "cube.transparent"
        case .vault: return "lock.fill"
        case .docs: return "book.fill"
        case .runbooks: return "list.bullet.rectangle"
        case .postmortems: return "doc.text.magnifyingglass"
        case .dictation: return "mic.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .whiteboard: return "scribble.variable"
        case .stickyBoard: return "note.text"
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
        case .kubernetes: return "Kubernetes"
        case .vault: return "Vault"
        case .docs: return "Docs"
        case .runbooks: return "Runbooks"
        case .postmortems: return "Postmortems"
        case .dictation: return "Dictation"
        case .tools: return "Tools"
        case .whiteboard: return "Whiteboard"
        case .stickyBoard: return "Sticky Board"
        case .settings: return "Settings"
        }
    }

    /// Canvas order, top-left to bottom-right. Declaration order is the
    /// order - `allCases` is the only list.
    static var canvasOrder: [DaylightModule] { allCases }
}
