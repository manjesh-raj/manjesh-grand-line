// Manjesh Grand Line - native macOS app.
//
// `DaylightSpace` - the six space pills, and the module-to-space table
// behind them (Daylight migration §5.3, §5.4).
//
// Five of the six filter the home canvas's module grid, which is the model
// this file was written for. The sixth (`.dailyOverview`, labelled
// "Overview") opens a page of its own instead - see `destination` below for
// the one seam that makes that possible, and `docs/history/39-daily-review.md`
// for why the daily review needed a page rather than a filter.
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

/// One of the six the bar's space pills offer.
///
/// Declaration order **is** pill order, left to right, and is what `⌘1`…`⌘6`
/// index into - `allCases` is the single source for both. `.dailyOverview` is
/// declared first because the captain asked for the new Overview tab leftmost,
/// which moved Home from ⌘1 to ⌘2 (Home keeps its own ⌘0 in the Go menu).
enum DaylightSpace: String, CaseIterable {
    /// `fm/grandline-overview-page-daily-review`: the sixth pill, and the one
    /// that is **not** a canvas filter - see `destination` below. It opens
    /// F20's daily review as a page of its own.
    ///
    /// The case is named `dailyOverview`, not `overview`: `.overview` already
    /// means the canvas pill labelled "Home", and the *destination* of the
    /// same name already means the Fleet dashboard. Two meanings for one word
    /// is what produced `data/grandline-daily-review-card-not-showing`'s whole
    /// investigation (F20's spec said "Overview", the implementation read that
    /// as `RailDestination.overview`, and the captain was looking at Home).
    /// A third would have been worse than the first two.
    case dailyOverview
    case overview
    case command
    case operations
    case stores
    case engineering

    /// The pill's label, and the canvas hero title for every space except
    /// the first one (which shows a time-of-day greeting instead - see
    /// `HomeCanvasController.renderGreeting`).
    ///
    /// **`.overview`'s label is "Home", not "Overview"** (review #3 §7). The
    /// app had three user-facing names - "Home", "Overview" and "Fleet" - for
    /// two things: the canvas hub, and the fleet dashboard drill page. "Home"
    /// already won the canvas everywhere that matters (`RailDestination
    /// .homeCanvas.title`, the File menu's Cmd-0 item, `HomeCanvasController`
    /// itself), and "Fleet" already won the drill page (`RailDestination
    /// .overview.title`, `DaylightModule.fleet.title`). This pill was the last
    /// surface still calling the canvas's default state "Overview", which read
    /// as a third thing. The **case name** deliberately stays `.overview`: it
    /// is the persisted raw value behind the space selection, and this file's
    /// own header is explicit that a space is presentation state that can be
    /// renamed without touching data code.
    var title: String {
        switch self {
        // The only user-facing "Overview" in the app, and deliberately so -
        // see `NavigationCoherenceSelfTest.checkOverviewNamesExactlyOneThing`,
        // which allows the word here and in `RailDestination.title` and
        // nowhere else.
        case .dailyOverview: return "Overview"
        case .overview: return "Home"
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
        // Carried for completeness rather than drawn: this pill opens a page,
        // so no canvas hero ever renders it. Kept real (and asserted
        // non-empty) so a future surface that lists the spaces has something
        // honest to show.
        case .dailyOverview: return "Your day, in one card."
        case .overview: return "Your whole control room at a glance."
        case .command: return "Console, tasks and the merge queue."
        case .operations: return "Hosts, logs, health and schedules - the running systems."
        case .stores: return "Vault, docs, tools and dictation - your reference shelf."
        case .engineering: return "Toolchain setup and this machine's settings."
        }
    }

    /// C1's hero badge for this space.
    ///
    /// Only Overview's hero reports a *verdict* (it renders
    /// `FleetGreeting.Answer`, badge and all); every other space's hero says
    /// what the space is, so this is an identity glyph rather than a state
    /// one - see `HomeCanvasController.setHero`.
    ///
    /// Every symbol here is asserted to resolve by
    /// `CanvasListsControlsSelfTest.checkC1HeroSymbolsResolve`, for the
    /// reason `DaylightModule.symbol` already carries: `NSImage(
    /// systemSymbolName:)` returns nil silently and this app has shipped an
    /// invisible icon exactly that way before.
    var heroSymbol: String {
        switch self {
        // The same glyph `DailyReviewCard` puts in its own header, so the
        // pill, the drill header and the card all read as one thing.
        case .dailyOverview: return "sun.max"
        case .overview: return "sailboat.fill"
        case .command: return "terminal.fill"
        case .operations: return "gauge.with.dots.needle.33percent"
        case .stores: return "archivebox.fill"
        case .engineering: return "hammer.fill"
        }
    }

    /// The 1-based index this space's `⌘N` shortcut carries.
    var shortcutIndex: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The page this pill **opens**, for a space that is a destination rather
    /// than a filter over the canvas's module grid - `nil` for the five that
    /// filter the canvas, which is every space this file was written for.
    ///
    /// **This is the one seam that lets a pill be a page.** The file header's
    /// rule still holds: a space is presentation state, and nothing in the
    /// data layer knows spaces exist. What changed is that
    /// `AppShellController.selectSpace` now asks *where* a pill goes instead
    /// of assuming the canvas - one table, read by the shell's navigation, by
    /// `DaylightModule.space(forDestination:)` (so the ⌘K / deep-link path
    /// lights the right pill) and by nothing else.
    ///
    /// A space with a destination has no modules, no canvas greeting and no
    /// grid: `filtersCanvas` below is what every canvas-shaped loop should
    /// filter on rather than naming this case.
    var destination: RailDestination? {
        switch self {
        case .dailyOverview: return .dailyOverview
        case .overview, .command, .operations, .stores, .engineering: return nil
        }
    }

    /// Whether picking this pill filters the home canvas (the original
    /// model) rather than navigating to a page of its own.
    var filtersCanvas: Bool { destination == nil }

    /// The space whose own page this destination is, if any - the reverse of
    /// `destination`, and the one place that lookup is spelled out.
    ///
    /// `AppShellController.show` reads it to decide whether the bar keeps its
    /// space pills (a top-level page) or swaps them for the drill cluster (a
    /// page the captain drilled into). Without it, a pill that opens a page
    /// lit that pill and then hid the whole pill strip behind a back arrow -
    /// which is what the captain reported against the new Overview tab.
    static func owning(destination: RailDestination) -> DaylightSpace? {
        allCases.first { $0.destination == destination }
    }
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
    // `fm/grandline-claude-status-card-implement`: the captain's picked
    // "Status strip" readout of Claude's five quota figures. Declared here,
    // directly after `.briefing`, because `canvasOrder` is `allCases`
    // (declaration order) and this is a status line the captain wants at the
    // top of the launch landing - the same reasoning `.poneglyph` and
    // `.commandLibrary` record for their own placements below.
    case claudeStatus
    case fleet
    case tasks
    case mergeQueue
    case console
    // `fm/grandline-devops-space-and-diagram-tool`: declared here, at the end
    // of the Command-space group, because `canvasOrder` below is `allCases`
    // (declaration order) - so a space reassignment ALONE would have left this
    // card rendering first on the Command canvas, ahead of Tasks/Merge queue/
    // Console. `.poneglyph`'s own note below records the same lesson, learned
    // the hard way. Appended to the group rather than slotted in by topic,
    // matching how a new quick-access bar icon is added: the group reads in the
    // order the captain asked for each entry, and appending is what stops a
    // move shuffling a card he already knows the position of.
    case commandLibrary
    // `fm/grandline-home-card-reorg`: the captain's third placement ask for
    // this card, and the first one that gives it a space of its own. Its two
    // earlier positions were both Overview-only orderings -
    // `fm/polish-straw-hat-overview-card-and-voice-c8d3` declared it right
    // after `.fleet` so the crew sat "beside the briefing and the fleet board
    // at the top of Overview", and `fm/straw-hat-voice-order-composer-polish-8dd2`
    // moved it to the very end of the enum so it rendered LAST on Overview
    // instead. The captain has now asked for it on the **Command** page
    // rather than on Home, so its `space` is `.command` below and
    // `appearsOnOverview` is false.
    //
    // The declaration moves here with it, appended to the end of the
    // Command-space group, for exactly the reason `.commandLibrary` above and
    // `.poneglyph` below both record: `canvasOrder` is `allCases`
    // (declaration order), so a group's members render in the order they are
    // declared. Leaving the case at the very end of the enum would have
    // rendered the same way *today* - it is last either way - but only by
    // accident, and the next module appended after it would have silently
    // pushed the crew card ahead of its own. Appending to the group rather
    // than slotting it in by topic keeps the Command canvas reading
    // Tasks / Merge queue / Console / DevOps Commands / Straw Hat Pirates,
    // which is the existing order plus one card at the end.
    case strawHat
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
    // `fm/move-poneglyph-to-stores-space-282a` moved `.poneglyph` here, right
    // after `.vault`, when its `space` moved from `.engineering` to `.stores`
    // below - `DaylightModule.canvasOrder` is `allCases` (declaration order),
    // so leaving the case where it sat beside the other Setup cases would
    // have made its card render first on the Stores canvas, ahead of Vault/
    // Docs/etc., rather than beside the destination it is most often
    // discussed alongside (see `VaultController.swift`'s header for the
    // Vault/Poneglyph naming history).
    case poneglyph
    case docs
    // `fm/grandline-feature-f1-notebook`: appended beside the two markdown
    // destinations it generalises, so the Stores canvas reads Docs, Notebook,
    // Runbooks, Postmortems. `canvasOrder` is `allCases`, so declaration order
    // is the only thing that places a card.
    case notebook
    // `fm/grandline-feature-f4-reading-list`: appended beside the markdown
    // destinations it sits with on the Stores shelf. `canvasOrder` is
    // `allCases`, so declaration order is the only thing that places a card.
    case readingList
    case runbooks
    case postmortems
    case dictation
    case tools
    case whiteboard
    case stickyBoard
    case codePreview
    case settings

    /// Which space this module belongs to, or `nil` for the three that appear
    /// **only** on Overview (locked decision 5: "The Morning briefing and
    /// Fleet cards appear ONLY on Overview", plus `.claudeStatus`, which has
    /// the same "no other home" property).
    ///
    /// The other four spaces show exactly the modules whose space matches;
    /// Overview's own subset is `appearsOnOverview` below rather than "every
    /// module", and a `nil` here is no longer the only way onto it.
    var space: DaylightSpace? {
        switch self {
        // `.claudeStatus` joins the same "no other home" set: Claude's quota
        // is not a Command surface, an Operations one, a Store or a Setup
        // page, and the captain asked for this card on the launch landing
        // specifically. `DaylightModuleSelfTest.overviewOnly` is updated with
        // it, per this file's own "change it here and in that test together"
        // rule.
        //
        // `.strawHat` used to be a fourth member of this set
        // (`fm/polish-straw-hat-overview-card-and-voice-c8d3` filed the crew
        // chat here on the reading that it had no natural space of its own).
        // `fm/grandline-home-card-reorg` is the captain's own correction after
        // using the shipped page: the crew is something he *commands*, so the
        // card belongs on Command beside the Console and the task queue rather
        // than on Home. It has a real space now, so it is in the `.command`
        // line below and out of this one.
        case .briefing, .claudeStatus, .fleet: return nil
        // `fm/grandline-devops-space-and-diagram-tool` moved `.commandLibrary`
        // here out of `.stores` below. `fm/grandline-tasks-kanban-devops-split`
        // had promoted it out of `ShiftController`'s own tab switcher into its
        // own destination and filed it under Stores on the reading that a
        // library of saved commands is reference material; the captain used the
        // shipped page and corrected that - a saved shell command is something
        // he *runs*, so it belongs beside the Console he runs it in, not on the
        // shelf beside the docs. Its `domainHue` was already `.teal` (the
        // "running systems" hue Console/Hosts/Log Analyzer/Kubernetes share)
        // and needed no change - that choice reads as more obviously right
        // here than it did in Stores. See `DaylightModuleSelfTest`'s
        // `lockedMembership`, updated alongside this per this file's own
        // "change it here and in that test together" rule.
        //
        // `fm/grandline-home-card-reorg` added `.strawHat` here, out of the
        // Overview-only set above - the captain's own ask after using the
        // shipped Home page. See `DaylightModuleSelfTest`'s `lockedMembership`
        // and `overviewOnly`, both updated alongside this per this file's own
        // "change it here and in that test together" rule.
        case .console, .tasks, .mergeQueue, .commandLibrary, .strawHat: return .command
        case .hosts, .logAnalyzer, .kubernetes, .health, .schedules: return .operations
        // `fm/grandline-docs-split-runbooks-postmortems` added Runbooks and
        // Postmortems here, promoted out of `DocsController`'s own tabs into
        // their own destinations - see `DaylightModuleSelfTest.checkSpaceTable`,
        // updated alongside this per this file's own "change it here and in
        // that test together" rule.
        //
        // Poneglyph's own history: `fm/implement-grand-line-secrets-vault-poneg-ad`
        // moved it (then Automic Vault's hardening panel) out of `.vault` into
        // Setup/Engineering; `fm/swap-vault-poneglyph-naming-in-grand-lin-1f`
        // swapped which feature each of `.vault`/`.poneglyph` shows (Automic
        // Vault's panel reclaimed `.vault`, the credential vault took
        // `.poneglyph`) with no space-table change, since a destination's
        // *slot* is independent of which controller populates it - see
        // `VaultController.swift`'s header for that history. The captain then
        // asked for Poneglyph to move out of Engineering into Stores
        // (`fm/move-poneglyph-to-stores-space-282a`), so it sits here now
        // rather than beside the other four Setup pages.
        case .vault, .poneglyph, .docs, .notebook, .readingList, .runbooks, .postmortems, .tools, .dictation, .whiteboard, .stickyBoard, .codePreview: return .stores
        case .updates, .bootstrap, .automation, .githubSync, .settings: return .engineering
        }
    }

    /// Whether this module's card renders on the Overview canvas
    /// specifically (`fm/grandline-overview-canvas-trim`).
    ///
    /// True by default; false for the modules the captain asked removed from
    /// Overview after reviewing a live screenshot - the canvas had grown to
    /// eighteen cards, most of which duplicated a page already one click away
    /// via its own space (Command/Operations/Stores/Engineering), the nav, or
    /// `⌘K`.
    ///
    /// **What Overview keeps is five cards** (`fm/grandline-home-card-reorg`):
    /// the three with no other home (`.briefing`, `.claudeStatus`, `.fleet` -
    /// `space == nil`) plus what is left of the original trim's "operational
    /// pulse" set, `.mergeQueue` and `.health`.
    ///
    /// The count has moved four times, and every move was a captain ask after
    /// using the shipped page - which is why the history is worth keeping
    /// rather than overwriting. `fm/grandline-overview-canvas-trim` locked
    /// **six**. `fm/polish-straw-hat-overview-card-and-voice-c8d3` made it
    /// **seven**, giving the crew chat its own card.
    /// `fm/grandline-claude-status-card-implement` made it **eight** with the
    /// quota strip. `fm/grandline-home-card-reorg` took it to **five**: the
    /// crew card moved to the Command space, and `.console` and `.schedules`
    /// came off Home because each already carries a card on its own space's
    /// canvas one pill away. `DaylightModuleSelfTest.overviewVisibleModules`
    /// is typed out as a literal precisely so changing that count has to be a
    /// deliberate edit in two places.
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
             .logAnalyzer, .kubernetes, .vault, .docs, .notebook, .readingList, .runbooks, .postmortems, .dictation, .tools, .whiteboard, .stickyBoard, .codePreview,
             // `fm/implement-grand-line-secrets-vault-poneg-ad`: a *new* module
             // has to be listed here explicitly, because the `default` below
             // returns `true` - and `true` would put a seventh card on Overview,
             // against the captain's own locked six-card decision. Caught by
             // `DaylightModuleSelfTest`'s literal `overviewVisibleModules` list,
             // which is exactly why that list is typed out rather than derived.
             .poneglyph,
             // `fm/grandline-tasks-kanban-devops-split`: same rule - a new
             // module has to opt out explicitly, because `default` returns
             // `true` and Overview's card count is a locked captain decision.
             .commandLibrary,
             // `fm/grandline-home-card-reorg`: the captain reviewed the live
             // Home page and asked for these three off it. `.console` and
             // `.schedules` were two of the four "operational pulse" cards the
             // original trim deliberately kept - he has since found both
             // redundant, because each already has its own card one pill away
             // (Console on Command, Schedules on Operations) and a card that
             // repeats a page the captain can reach in one click is exactly
             // the duplication the trim existed to remove. Their `space` is
             // deliberately unchanged: this is the presentation-only opt-out
             // this property is for, so both still render on their own space's
             // canvas via `isVisible(in:)` - nothing was deleted.
             //
             // `.strawHat` is here for the other reason a module lands on this
             // list: it now has a real space (`.command`, above), so it stops
             // being an Overview-only card for the same reason `.tasks` and
             // `.hosts` already are - its space's canvas is where it lives.
             .console, .schedules, .strawHat,
             .settings:
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
        // Two for the strip as well, and for a reason of the same kind as the
        // briefing's: five columns need measure. At one column (255pt) the
        // five keys truncate to initials; at a real span-2 width (526pt) each
        // column gets ~85pt, which is enough for "EXTRA USAGE" over "$137.62"
        // - measured by `ClaudeStatusCardSelfTest`, not assumed.
        //
        // `HelmResponsiveGrid.packRows` degrades a span-2 card to span 1 in a
        // single-column grid, so `HomeCanvasController.claudeStripColumnCap`
        // splits the strip's columns to match rather than letting them
        // truncate - the same shape as `briefingClauseCap`.
        case .claudeStatus: return 2
        default: return 1
        }
    }

    /// The destination a click on this module's card opens.
    var opens: RailDestination {
        switch self {
        case .briefing, .fleet: return .overview
        // The Claude-usage control lives on Console - the same destination
        // `HomeCanvasController.follow` already resolves a `.quota` briefing
        // clause to, and for the same stated reason: open the page that owns
        // the thing the card is about rather than invent a destination.
        case .claudeStatus: return .console
        case .strawHat: return .strawHat
        case .tasks: return .shift
        case .mergeQueue: return .review
        case .console: return .console
        case .health: return .health
        case .hosts: return .hosts
        case .updates: return .updates
        case .bootstrap: return .bootstrap
        case .automation: return .automation
        case .githubSync: return .githubSync
        case .poneglyph: return .poneglyph
        case .schedules: return .schedules
        case .logAnalyzer: return .logAnalyzer
        case .kubernetes: return .kubernetes
        case .vault: return .vault
        case .docs: return .docs
        case .notebook: return .notebook
        case .readingList: return .readingList
        case .runbooks: return .runbooks
        case .postmortems: return .postmortems
        case .dictation: return .dictation
        case .tools: return .tools
        case .whiteboard: return .whiteboard
        case .stickyBoard: return .stickyBoard
        case .codePreview: return .codePreview
        case .commandLibrary: return .commandLibrary
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
        // A space that *is* a page owns its own destination, and no module
        // opens it - so this table is consulted first. Same one mapping rule:
        // `DaylightSpace.destination` is read, never restated.
        if let space = DaylightSpace.allCases.first(where: { $0.destination == dest }) { return space }
        // **More than one module can open the same destination**, and the one
        // that *owns* it is the one that lives on a space. An Overview-only
        // module that merely deep-links elsewhere is not that destination's
        // home - `.claudeStatus` opens `.console` the way the briefing's
        // `.quota` clause does, and it has no space of its own.
        //
        // Preferring a module with a real space rather than taking the first
        // match makes this independent of declaration order, which `allCases`
        // otherwise makes load-bearing here. It was not: declaring
        // `.claudeStatus` before `.console` made Console's own Recents kicker
        // read "Home" (`RecentDestinationsSelfTest.
        // kindPropertiesForRailAndHost` caught it by name).
        let openers = allCases.filter { $0.opens == dest }
        return openers.first { $0.space != nil }?.space ?? openers.first?.space
    }

    /// §4's SF Symbol for this module's gradient tile. Every one of these is
    /// verified to resolve by `DaylightModuleSelfTest.checkSymbolsResolve` -
    /// `NSImage(systemSymbolName:)` returns nil silently, and this app has
    /// shipped an invisible icon exactly that way before.
    var symbol: String {
        switch self {
        case .briefing: return "cup.and.saucer.fill"
        case .claudeStatus: return "gauge.with.needle"
        case .fleet: return "sailboat.fill"
        // Only the fallback: `HomeCanvasController.fillStrawHat` gives this
        // card `StrawHatFlag.image`, the crew's own Jolly Roger. Kept in sync
        // with `RailDestination.strawHat.symbol` by hand - a card and the page
        // it opens should not disagree even in their fallback.
        case .strawHat: return "person.3.fill"
        case .tasks: return "checkmark.circle.fill"
        case .mergeQueue: return "arrow.triangle.branch"
        case .console: return "terminal.fill"
        case .health: return "heart.text.square.fill"
        case .hosts: return "desktopcomputer"
        case .updates: return "steeringwheel"
        case .bootstrap: return "hammer.fill"
        case .automation: return "bolt.fill"
        case .githubSync: return "arrow.2.squarepath"
        case .poneglyph: return "doc.text.image"
        case .schedules: return "clock.fill"
        case .logAnalyzer: return "text.magnifyingglass"
        case .kubernetes: return "cube.transparent"
        case .vault: return "lock.fill"
        case .docs: return "book.fill"
        // Kept in sync with `RailDestination.notebook.symbol` by hand, like
        // `.strawHat` and `.commandLibrary` below - a card and the page it
        // opens should not disagree even in their fallback.
        case .notebook: return "book.and.wrench"
        // Kept in sync with `RailDestination.readingList.symbol` by hand, like
        // `.notebook` above - a card and the page it opens should not disagree
        // even in their fallback.
        case .readingList: return "bookmark.fill"
        case .runbooks: return "list.bullet.rectangle"
        case .postmortems: return "doc.text.magnifyingglass"
        case .dictation: return "mic.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .whiteboard: return "scribble.variable"
        case .stickyBoard: return "note.text"
        case .codePreview: return "chevron.left.forwardslash.chevron.right"
        // Kept in sync with `RailDestination.commandLibrary.symbol` by hand,
        // like `.strawHat` above - a card and the page it opens should not
        // disagree even in their fallback.
        case .commandLibrary: return "books.vertical"
        case .settings: return "slider.horizontal.3"
        }
    }

    /// §2.2's hue for this area of the app.
    ///
    /// Read from the destination this module opens wherever that is the same
    /// idea (`RailDestination.domainHue`, Phase 1's own table), so the module
    /// card and the drill page it opens can never disagree about a hue. The
    /// two exceptions are `.briefing`/`.fleet`, which share one destination
    /// (`.overview`) but not a hue: the briefing is amber (§4), Fleet is
    /// blue. `.strawHat` needs no exception - it opens its own destination,
    /// so the `default` below reads that page's own violet.
    var hue: HelmDomainHue {
        switch self {
        case .briefing: return .amber
        case .fleet: return .blue
        // Identity, not a verdict: the card's hue must not move with the
        // reading, or a comfortable week and an exhausted one would be two
        // different cards. The severity lives in the strip's own tracks.
        case .claudeStatus: return .violet
        default: return opens.domainHue
        }
    }

    /// The card's title.
    var title: String {
        switch self {
        case .briefing: return "Morning briefing"
        case .claudeStatus: return "Claude"
        case .fleet: return "Fleet"
        case .strawHat: return "Straw Hat Pirates"
        case .tasks: return "Tasks"
        case .mergeQueue: return "Merge queue"
        case .console: return "Console"
        case .health: return "Health"
        case .hosts: return "Hosts"
        case .updates: return "Updates"
        case .bootstrap: return "Bootstrap"
        case .automation: return "Automation"
        case .githubSync: return "GitHub Sync"
        case .poneglyph: return "Poneglyph"
        case .schedules: return "Schedules"
        case .logAnalyzer: return "Log Analyzer"
        case .kubernetes: return "Kubernetes"
        case .vault: return "Vault"
        case .docs: return "Docs"
        case .notebook: return "Notebook"
        case .readingList: return "Reading List"
        case .runbooks: return "Runbooks"
        case .postmortems: return "Postmortems"
        case .dictation: return "Dictation"
        case .tools: return "Tools"
        case .whiteboard: return "Whiteboard"
        case .stickyBoard: return "Sticky Board"
        case .codePreview: return "Code Preview"
        case .commandLibrary: return "DevOps Commands"
        case .settings: return "Settings"
        }
    }

    /// Canvas order, top-left to bottom-right. Declaration order is the
    /// order - `allCases` is the only list.
    static var canvasOrder: [DaylightModule] { allCases }
}
