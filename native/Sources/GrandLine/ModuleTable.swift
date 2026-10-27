// Grand Line - native macOS app.
//
// `ModuleTable` - step 0 of the modular-shell migration (full review section
// 5.8): one visible row per destination, and the module each one moves into.
//
// **What this is for.** A destination's identity used to be spread over six
// tables (ARCH-03 of the 2026-10 end-to-end review), and step 0 restated them
// here as one row per destination. R2-ARCH-03 of the second review finished
// the job: the rows below are now the source.
//
//   - `RailDestination.title`, `.symbol` and `.domainHue`, the drill line
//     (`RailDestination.drillSubtitle`) and the floating bar's space for a
//     destination (`DaylightModule.space(forDestination:)`) read their row.
//     Why each destination has the name, glyph, hue and line it has is
//     written beside its row.
//   - A sidebar item's title, group, children, symbol, tab host and header
//     are its row in `ModuleTable.modules`.
//   - What stays elsewhere and is checked against these rows: the body slot
//     (`DestinationRegistry`, a type), the eager-mount flag (the
//     `register(...)` lines in `Workspace.registerDestinations`), the Home
//     cards that open a destination (`DaylightModule.opens`) and what ⌘N
//     creates (`ContextualNewAction`).
//
// `ModuleTableSelfTest` asserts both halves: the rows agree with what stays
// elsewhere, and a typed-out fixture pins what every destination and module
// is called and where it lives, so an edit here is a deliberate one.
//
// **Who reads it.** The sidebar layout does, and the floating bar reads none
// of it. Since step 4 the sidebar's rows are the modules themselves, and a
// module's children are the tabs the window toolbar draws for it
// (`WorkspaceModule.tabs`); nothing here mounts or draws anything.
//
// **The planned home of each destination** is the `module` and `child` columns.
// They follow the captain's modular workspace prototype (Version 2): eighteen
// sidebar items, which are Home plus seventeen modules in four groups, with
// Console as its own module - and a nineteenth since, the Calendar row the
// captain's later mockup puts in Work after Tasks.
// `docs/modular-shell/feature-inventory.md` is the feature-level half of the
// same plan, and its suite checks that every destination row there names the
// module this table does.

import Foundation

/// A sidebar section in the modular shell. Home sits above the groups and
/// belongs to none of them.
enum WorkspaceGroup: String, CaseIterable {
    case work
    case observe
    case workbench
    case machine

    var title: String {
        switch self {
        case .work: return "Work"
        case .observe: return "Observe"
        case .workbench: return "Workbench"
        case .machine: return "Machine"
        }
    }
}

/// One sidebar item in the modular shell, in sidebar order.
enum WorkspaceModule: String, CaseIterable {
    case home
    case tasks
    case calendar
    case crew
    case connections
    case console
    case knowledge
    case secrets
    case kubernetes
    case logs
    case health
    case schedules
    case tools
    case whiteboard
    case stickyBoard
    case code
    case dictation
    case setup
    case settings

    /// R2-ARCH-03: the module's own row in `ModuleTable.modules`, where every
    /// fact below is written down once.
    private var row: WorkspaceModuleDescriptor { ModuleTable.row(for: self) }

    var title: String { row.title }

    /// `nil` for Home, which sits above the four groups.
    var group: WorkspaceGroup? { row.group }

    /// The module's tabs or sidebar children, by name.
    ///
    /// Empty means the module is one page with no named children of its own
    /// (Console's live sessions are children too, but they are created at run
    /// time and have no fixed names).
    /// The inventory suite checks every `Module › Child` reference against this
    /// list, so a planned home cannot name a tab that does not exist.
    ///
    /// Where the prototype drew different tabs from the ones the real page has,
    /// the real page wins: Kubernetes keeps its Cluster and Log Tail tabs.
    /// Knowledge's fourth tab is Docs, the captain's rename of the prototype's
    /// Playbook: it is the Docs page, which shows the DevOps Playbook.
    ///
    /// The same rule took two of the prototype's tabs out in step 4, because no
    /// real view is behind them: a ready PR carries its Merge button on Review
    /// (Crew's Merge queue), and the live sessions are Console's, in the
    /// sidebar and in Console's session strip (Connections' Sessions).
    ///
    /// Crew's Needs you came back with the later page work as a real view:
    /// the Fleet page's own Needs your call list and each task's open
    /// decisions, in one place (`FleetController`'s "Crew › Needs you").
    var children: [String] { row.children }
}

// MARK: - The module's chrome in the sidebar layout

extension WorkspaceModule {

    /// The sidebar row's symbol. A module that is one page uses that page's
    /// own, so nothing a captain recognises changes; a module of several pages
    /// has one of its own.
    var symbol: String {
        row.symbol ?? ModuleTable.routes(in: self).first.map(\.symbol) ?? "square.grid.2x2"
    }

    /// The page that draws those of this module's children that are its own
    /// tabs rather than destinations: Shift's views are Tasks' tabs, the
    /// Fleet page's Needs you, Dashboard and Log are Crew's Needs you, In
    /// flight and Log, the Hosts
    /// page's Hosts, SSH Keys and Snippets are Connections' first three, and
    /// Kubernetes' Cluster and Log Tail are its own.
    var pageTabHost: RailDestination? { row.pageTabHost }

    /// Whether the window toolbar draws this module's children as tabs.
    /// Settings keeps its categories in its own page column, as the prototype
    /// does, and a module that is one page has no children.
    var drawsToolbarTabs: Bool { self != .settings && !children.isEmpty }

    /// The tabs the window toolbar draws for this module, in `children` order.
    /// A tab is a destination of its own when a row claims it, and otherwise
    /// one of `pageTabHost`'s own tabs. Its `route` is the page either way, so
    /// every one of the 29 routes still lands on its page.
    var tabs: [ModuleTab] {
        guard drawsToolbarTabs else { return [] }
        return children.compactMap { name in
            if let row = ModuleTable.rows.first(where: { $0.module == self && $0.child == name }) {
                return ModuleTab(module: self, name: name, route: row.route, isPageTab: row.route == pageTabHost)
            }
            guard let host = pageTabHost else { return nil }
            return ModuleTab(module: self, name: name, route: host, isPageTab: true)
        }
    }

    /// Whether the content column opens with the module's large title and its
    /// page's live subtitle. The captain dropped it on Connections and Console;
    /// every other module keeps it.
    var showsHeader: Bool { row.showsHeader }
}

/// One sidebar item, as `ModuleTable.modules` writes it down (R2-ARCH-03).
struct WorkspaceModuleDescriptor {
    let module: WorkspaceModule
    let title: String
    /// `nil` for Home, which sits above the four groups.
    let group: WorkspaceGroup?
    /// `WorkspaceModule.children` - see its note for what counts.
    let children: [String]
    /// The sidebar row's own symbol, or `nil` for a module of one page,
    /// which takes that page's.
    var symbol: String? = nil
    /// The page that draws those of the children that are its own tabs.
    var pageTabHost: RailDestination? = nil
    /// Whether the content column opens with the module's large title.
    var showsHeader = true
}

/// One tab of a module, as the window toolbar draws it.
struct ModuleTab: Equatable {
    let module: WorkspaceModule
    /// The child's name, as `WorkspaceModule.children` declares it.
    let name: String
    /// The page that draws the tab.
    let route: RailDestination
    /// Whether the tab is one of that page's own tabs, which it selects through
    /// `ModuleTabHosting`, rather than the page itself.
    let isPageTab: Bool
}

/// One destination, with everything the six old tables say about it and the
/// module it moves into.
struct ModuleDescriptor {
    /// The stable route id. Notifications, App Intents, ⌘K, Recents and
    /// session restore all address a page by this, and they keep doing so
    /// after the consolidation.
    let route: RailDestination
    /// What every surface calls the page (`RailDestination.title` reads it).
    let title: String
    /// Its SF Symbol (`RailDestination.symbol` reads it).
    let symbol: String
    /// The hue of the area it belongs to (`RailDestination.domainHue`).
    let hue: HelmDomainHue
    /// `RailDestination.slot`, checked against `DestinationRegistry`.
    let slot: DestinationSlotID
    /// The static line under the title (`RailDestination.drillSubtitle`) -
    /// the fallback for a page with no live line of its own.
    let subtitle: String
    /// The `mountsEagerly` flag in the destination's `register(...)` line.
    let mountsEagerly: Bool
    /// The floating bar's space for it (`DaylightModule.space(forDestination:)`).
    let space: DaylightSpace?
    /// The Home canvas cards whose click opens this destination, in canvas
    /// order (`DaylightModule.opens`).
    let homeCards: [DaylightModule]
    /// `ContextualNewAction.forDestination(_:)` with no Hosts tab, i.e. what
    /// ⌘N creates on the page as it first opens.
    let newAction: ContextualNewAction
    /// The sidebar item this destination moves into.
    let module: WorkspaceModule
    /// The tab inside `module`, or `nil` when the destination is the module's
    /// whole page.
    let child: String?
    /// R2-UX-10: the narrowest the sidebar layout's content column may be
    /// while this page shows, with overlay scrollers (the shell adds a legacy
    /// scroller's track itself). A page wider than its column grows the
    /// window (gotcha (13)), so this is the page's own measured minimum;
    /// below it plus the sidebar, the sidebar steps aside for this page only.
    /// `MainSplitShellSelfTest` fails if a page outgrows its floor.
    var minimumContentWidth: CGFloat = ModuleTable.defaultMinimumContentWidth
}

enum ModuleTable {

    /// Every destination, in `RailDestination` declaration order.
    static let rows: [ModuleDescriptor] = [
        // Its symbol:
        //   §4's tile table: the canvas is the app itself, so it takes the
        //   app's own mark.
        // Its hue:
        //   The hub itself carries the app's own identity hue.
        ModuleDescriptor(route: .homeCanvas, title: "Home", symbol: "sailboat.fill", hue: .blue,
                         slot: .homeCanvas, subtitle: "", mountsEagerly: true, space: nil,
                         homeCards: [], newAction: .task, module: .home, child: nil),
        // Its title:
        //   **UX issue X3.** "Overview" once named a page here, a space pill,
        //   a group header in the Go menu and an item inside that header -
        //   while "Home" and "Fleet" were each also in use for something
        //   adjacent. Home is the canvas and Fleet is the crew dashboard, and
        //   "Overview" now names nothing, which is what
        //   `NavigationCoherenceSelfTest.checkNavigationNamesAreDistinct`
        //   enforces.
        // Its hue:
        //   Fleet
        // Its line:
        //   `fm/polish-straw-hat-overview-card-and-voice-c8d3` narrowed this: the
        //   crew chat is its own destination now, so Fleet's line is about the
        //   dispatched-crewmate board it actually shows.
        ModuleDescriptor(route: .overview, title: "Fleet", symbol: "square.grid.2x2", hue: .blue,
                         slot: .overview, subtitle: "Dispatched crew, decisions and the morning briefing",
                         mountsEagerly: true, space: nil, homeCards: [.briefing, .fleet],
                         newAction: .task, module: .crew, child: "In flight",
                         // R2-UX-10: the fleet table's columns, measured at 743pt.
                         minimumContentWidth: 760),
        // Its symbol:
        //   Only the *fallback*, for a `StrawHatFlag` payload that stops
        //   decoding - both tiles that render this destination take the Jolly
        //   Roger itself. A group of people rather than one, and distinct from
        //   `.overview`'s grid and `.shift`'s checkmark.
        // Its hue:
        //   `fm/polish-straw-hat-overview-card-and-voice-c8d3`: violet is this
        //   app's own "AI feature" hue - the composer popovers' tinted tile,
        //   Dictation's clean-up card, the Whiteboard's Claude-generated
        //   diagrams - and the crew chat is the largest AI surface in the app.
        //   It is only the tile's *fallback* hue in practice (both tiles render
        //   the Jolly Roger artwork), but it is what the page's focus ring and
        //   primary button take, so it has to be a real choice.
        ModuleDescriptor(route: .strawHat, title: "Straw Hat Pirates", symbol: "person.3.fill", hue: .violet,
                         slot: .strawHat, subtitle: "Ask the crew - every write is yours to confirm",
                         mountsEagerly: false, space: .command, homeCards: [.strawHat],
                         newAction: .task, module: .crew, child: "Ask the crew"),
        ModuleDescriptor(route: .console, title: "Console", symbol: "terminal", hue: .teal,
                         slot: .console, subtitle: "Terminals, hosts and the shared Firstmate session",
                         mountsEagerly: true, space: .command, homeCards: [.claudeStatus, .console],
                         newAction: .task, module: .console, child: nil),
        ModuleDescriptor(route: .hosts, title: "Hosts", symbol: "server.rack", hue: .teal,
                         slot: .hosts, subtitle: "Saved hosts, SSH keys and snippets",
                         mountsEagerly: false, space: .operations, homeCards: [.hosts],
                         newAction: .host, module: .connections, child: "Hosts"),
        // Its symbol:
        //   fm/grandline-rail-followup-fixes: the captain asked for the menu
        //   bar's Shift/Tasks status item to use the same "sailboat" glyph as
        //   the app's own logo mark, since that standalone item has no nearby
        //   app branding to associate it back to this app (see
        //   `ShiftMenuBarController.init`). The rail's own `.shift` row
        //   deliberately keeps `checkmark.circle` rather than also switching
        //   to `sailboat` - the rail already shows the real sailboat logo mark
        //   directly above this row (`IconRailController.loadView`'s `mark`),
        //   so a second sailboat a few rows down would read as a duplicate
        //   icon rather than a clearer one.
        // Its hue:
        //   Tasks
        // Its line:
        //   `fm/grandline-tasks-kanban-devops-split` narrowed this: DevOps
        //   Commands is its own destination now. In practice this static string
        //   is a fallback only - `ShiftController` conforms to
        //   `DaylightDrillActions` and always supplies its own live subtitle.
        ModuleDescriptor(route: .shift, title: "Tasks", symbol: "checkmark.circle", hue: .rose,
                         slot: .shift, subtitle: "A task board, follow-ups and projects",
                         mountsEagerly: false, space: .command, homeCards: [.tasks],
                         newAction: .task, module: .tasks, child: nil),
        // Its symbol:
        //   A calendar with a check: what it shows is tasks by their due
        //   date. The plain `calendar` glyph is Schedules', a few rows down
        //   the same sidebar, and two identical icons would read as one page.
        //   The toolbar's calendar button reads this row too, so the button
        //   and the row it opens agree.
        // Its hue:
        //   Tasks, whose records it draws.
        // Its line:
        //   A fallback only - `TaskCalendarController` supplies the visible
        //   period's own count (GL-14).
        // Its module:
        //   Its own sidebar row in Work, after Tasks, where the captain's
        //   mockup puts it. It was Tasks' third tab until then
        //   (`docs/history/34-recurrence-and-calendar.md`).
        ModuleDescriptor(route: .calendar, title: "Calendar", symbol: "calendar.badge.checkmark", hue: .rose,
                         slot: .calendar, subtitle: "Tasks and follow-ups by the day they are due",
                         mountsEagerly: false, space: .command, homeCards: [],
                         newAction: .task, module: .calendar, child: nil),
        // Its hue:
        //   Merge queue
        ModuleDescriptor(route: .review, title: "Review", symbol: "arrow.triangle.branch", hue: .green,
                         slot: .review, subtitle: "Open pull requests, ready to merge",
                         mountsEagerly: true, space: .command, homeCards: [.mergeQueue],
                         newAction: .task, module: .crew, child: "Review"),
        // Its symbol:
        //   `fm/grandline-log-analyzer-build`: a magnifier over lines - the
        //   "read this output" idea, distinct from `.review`'s branch glyph
        //   and from Console's bare terminal.
        ModuleDescriptor(route: .logAnalyzer, title: "Log Analyzer", symbol: "text.magnifyingglass", hue: .teal,
                         slot: .logAnalyzer, subtitle: "Collect, analyse and explain captured output",
                         mountsEagerly: false, space: .operations, homeCards: [.logAnalyzer],
                         newAction: .task, module: .logs, child: nil,
                         // R2-UX-10: one of the two pages the old single floor
                         // was set by, unreflowed. 940 held when the page was
                         // shown at a narrow width; a window narrowed while it
                         // shows needs 973 (measured), so it keeps 980.
                         minimumContentWidth: 980),
        // Its symbol:
        //   The Kubernetes logo is literally a ship's helm, which would suit
        //   this app's nautical identity - but `steeringwheel` is already
        //   Updates'. `cube.transparent` is the next-closest read for "a
        //   cluster of things you can see into", and is unclaimed here.
        // Its hue:
        //   `fm/grandline-k8s-cluster-tail`: the Operations space's own hue,
        //   shared with Hosts/Console/Log Analyzer for the same reason the four
        //   Setup pages share amber - the hue belongs to the *area*, and this
        //   page is the running systems seen from a different angle.
        ModuleDescriptor(route: .kubernetes, title: "Kubernetes", symbol: "cube.transparent", hue: .teal,
                         slot: .kubernetes, subtitle: "Read-only cluster browsing and multi-pod log tailing",
                         mountsEagerly: false, space: .operations, homeCards: [.kubernetes],
                         newAction: .task, module: .kubernetes, child: nil),
        ModuleDescriptor(route: .tools, title: "Tools", symbol: "wrench.and.screwdriver", hue: .slate,
                         slot: .tools, subtitle: "Nine offline utilities",
                         mountsEagerly: false, space: .stores, homeCards: [.tools],
                         newAction: .task, module: .tools, child: nil),
        // Its symbol:
        //   `fm/grand-line-whiteboard-excalidraw`: a hand-drawn scribble - the
        //   one glyph in this family that reads as "sketch on a surface" rather
        //   than as a document or a tool, which is what an infinite hand-drawn
        //   canvas is. Verified to resolve (`NSImage(systemSymbolName:)` returns
        //   nil silently, and this app has shipped an invisible icon that way).
        // Its hue:
        //   `fm/grand-line-whiteboard-excalidraw`: violet is this app's own "AI
        //   feature" hue (the composer popovers' tinted tile, Dictation's
        //   clean-up card), and the Whiteboard's headline capability is the
        //   Claude-generated diagram.
        ModuleDescriptor(route: .whiteboard, title: "Whiteboard", symbol: "scribble.variable", hue: .violet,
                         slot: .whiteboard, subtitle: "An Excalidraw canvas, offline, with AI diagrams",
                         mountsEagerly: false, space: .stores, homeCards: [.whiteboard],
                         newAction: .task, module: .whiteboard, child: nil),
        // Its symbol:
        //   `fm/grandline-monaco-code-preview`: the angle-brackets glyph - the
        //   one symbol in this family that reads as "source code" rather than
        //   as a document (`.docs`), a terminal (`.console`) or a tool. Verified
        //   to resolve (`NSImage(systemSymbolName:)` returns nil silently, and
        //   this app has shipped an invisible icon that way).
        // Its hue:
        //   `fm/grandline-monaco-code-preview`: blue is the "reading material"
        //   hue in §2.2's table (Docs, Runbooks, the Fleet overview), and a
        //   panel whose whole job is reading a snippet properly belongs there.
        //   Deliberately not the Whiteboard's violet - that is this app's AI
        //   hue, and there is no AI anywhere in this destination.
        ModuleDescriptor(route: .codePreview, title: "Code Preview",
                         symbol: "chevron.left.forwardslash.chevron.right", hue: .blue,
                         slot: .codePreview, subtitle: "Paste code and read it properly, synced to your config repo",
                         mountsEagerly: false, space: .stores, homeCards: [.codePreview],
                         newAction: .codeSnippet, module: .code, child: nil),
        // Its symbol:
        //   `fm/grandline-sticky-board`: a note glyph reads as "a quick thought
        //   written down", distinct from `.docs`' closed book (reference
        //   material) and `.whiteboard`'s scribble (a drawing surface).
        // Its hue:
        //   `fm/grandline-sticky-board`: amber - the warm, paper-note-adjacent
        //   hue this app has not yet given a Stores-space destination of its
        //   own, distinct from Whiteboard's AI-feature violet (Sticky Board has
        //   no AI in it at all).
        ModuleDescriptor(route: .stickyBoard, title: "Sticky Board", symbol: "note.text", hue: .amber,
                         slot: .stickyBoard, subtitle: "A freeform corkboard of quick sticky notes",
                         mountsEagerly: false, space: .stores, homeCards: [.stickyBoard],
                         newAction: .stickyNote, module: .stickyBoard, child: nil),
        // Its symbol:
        //   `fm/grandline-tasks-kanban-devops-split`: a shelf of books - the
        //   one glyph in this family that reads as "a library you look things
        //   up in" rather than as a single document (`.docs`' closed book), a
        //   terminal (`.console`) or a tool. Deliberately not a terminal glyph:
        //   this destination is where commands are *kept*, not where they run.
        //   Verified to resolve - `NSImage(systemSymbolName:)` returns nil
        //   silently, and this app has shipped an invisible icon that way.
        // Its hue:
        //   `fm/grandline-tasks-kanban-devops-split`: teal is the "running
        //   systems" hue this app already gives Console, Hosts, Log Analyzer
        //   and Kubernetes, and a library of saved shell commands is what gets
        //   typed into exactly those. Deliberately not the blue its then-Stores
        //   neighbours carry (reading material) - these are things you *run*.
        //   `fm/grandline-devops-space-and-diagram-tool` then moved the module
        //   itself into the Command space on the captain's own correction, which
        //   needed no change here: the hue was already Console's, and sharing it
        //   with a space sibling is exactly what §2.2's "the hue belongs to the
        //   area" rule asks for.
        ModuleDescriptor(route: .commandLibrary, title: "DevOps Commands", symbol: "books.vertical", hue: .teal,
                         slot: .commandLibrary, subtitle: "Your saved shell commands, parameterised and ready to run",
                         mountsEagerly: false, space: .command, homeCards: [.commandLibrary],
                         newAction: .command, module: .connections, child: "Commands",
                         // R2-UX-10: the other page that set the old floor;
                         // 964 measured the same way as Log Analyzer's.
                         minimumContentWidth: 980),
        // Its line:
        //   `fm/swap-vault-poneglyph-naming-in-grand-lin-1f` reclaimed `.vault`
        //   for Automic Vault's hardening panel - the credential vault's own
        //   line moved to `.poneglyph` below. In practice this static string is
        //   a fallback only: `VaultController` conforms to
        //   `DaylightDrillActions` and always supplies its own live subtitle
        //   (secret/launcher counts), which `AppShellController.applyDrillHeader`
        //   prefers.
        ModuleDescriptor(route: .vault, title: "Vault", symbol: "lock.shield", hue: .violet,
                         slot: .vault, subtitle: "Secret names and tool hardening status from Automic Vault",
                         mountsEagerly: false, space: .stores, homeCards: [.vault],
                         newAction: .task, module: .secrets, child: "Automic Vault"),
        ModuleDescriptor(route: .dictation, title: "Dictation", symbol: "waveform", hue: .rose,
                         slot: .dictation, subtitle: "Speech to text, on this machine",
                         mountsEagerly: false, space: .stores, homeCards: [.dictation],
                         newAction: .task, module: .dictation, child: nil),
        // Its symbol:
        //   `fm/grandline-schedules-sidebar-move`: a calendar - matches
        //   `SchedulesCardView`'s own header icon, so the rail row and the
        //   card it opens onto agree.
        ModuleDescriptor(route: .schedules, title: "Schedules", symbol: "calendar", hue: .violet,
                         slot: .schedules, subtitle: "Unattended runs of actions this app already has",
                         mountsEagerly: false, space: .operations, homeCards: [.schedules],
                         newAction: .schedule, module: .schedules, child: nil),
        // Its symbol:
        //   `fm/grandline-health-sidebar-move`: matches `HealthCardView`'s own
        //   header icon, so the rail row and the card it opens onto agree.
        ModuleDescriptor(route: .health, title: "Health", symbol: "waveform.path.ecg", hue: .green,
                         slot: .health, subtitle: "How this app's own background services are doing",
                         mountsEagerly: false, space: .operations, homeCards: [.health],
                         newAction: .task, module: .health, child: nil),
        // Its line:
        //   `fm/grandline-docs-split-runbooks-postmortems` narrowed this to
        //   just the Playbook, since Runbooks and Postmortems are their own
        //   destinations now.
        ModuleDescriptor(route: .docs, title: "Docs", symbol: "book.closed", hue: .blue,
                         slot: .docs, subtitle: "The DevOps Playbook, browsable offline",
                         mountsEagerly: false, space: .stores, homeCards: [.docs],
                         newAction: .task, module: .knowledge, child: "Docs"),
        // Its symbol:
        //   `fm/grandline-feature-f1-notebook`: an open book with a pen over it
        //   - the one glyph in this family that reads as "somewhere you write"
        //   rather than as reference material you read (`.docs`' closed book),
        //   a procedure (`.runbooks`' list) or a loose thought
        //   (`.stickyBoard`'s note). Verified to resolve -
        //   `NSImage(systemSymbolName:)` returns nil silently, and this app has
        //   shipped an invisible icon that way.
        // Its hue:
        //   `fm/grandline-feature-f1-notebook`: blue is §2.2's "reading
        //   material" hue - Docs, Runbooks, the Fleet overview - and the
        //   notebook is the general form of the two markdown destinations that
        //   already carry it. It is also the hue the reviewed F1 mockup draws
        //   the page's icon tile and primary button in, so the shipped page and
        //   the mockup the captain approved agree.
        // Its line:
        //   In practice a fallback only: `NotebookController` conforms to
        //   `DaylightDrillActions` and always supplies its own live line (page
        //   count and sync state).
        ModuleDescriptor(route: .notebook, title: "Notebook", symbol: "book.and.wrench", hue: .blue,
                         slot: .notebook, subtitle: "Linked markdown pages, in your own config repo",
                         mountsEagerly: false, space: .stores, homeCards: [.notebook],
                         newAction: .notebookPage, module: .knowledge, child: "Notebook"),
        // Its symbol:
        //   `fm/grandline-feature-f4-reading-list`: a bookmark, which is what a
        //   link inbox is - distinct from `.docs`' closed book (reference you
        //   read), `.notebook`'s book-and-pen (somewhere you write) and
        //   `.stickyBoard`'s note (a loose thought). Verified to resolve:
        //   `NSImage(systemSymbolName:)` returns nil silently, and this app has
        //   shipped an invisible icon that way.
        // Its hue:
        //   `fm/grandline-feature-f4-reading-list`: green, which is the hue the
        //   reviewed F4 mockup draws the page's icon tile, its primary button
        //   and its summarised card's accent rule in - so the shipped page and
        //   the mockup the captain approved agree. It is also the one hue in
        //   §2.2's set not already spoken for on the Stores shelf.
        // Its line:
        //   In practice a fallback only: `ReadingListController` conforms to
        //   `DaylightDrillActions` and always supplies its own live line (unread
        //   and saved counts, plus the sync state).
        ModuleDescriptor(route: .readingList, title: "Reading List", symbol: "bookmark.fill", hue: .green,
                         slot: .readingList, subtitle: "Links you saved to read, with titles read on this machine",
                         mountsEagerly: false, space: .stores, homeCards: [.readingList],
                         newAction: .savedLink, module: .knowledge, child: "Reading list"),
        // Its symbol:
        //   `fm/grandline-docs-split-runbooks-postmortems`: reused verbatim
        //   from the icons this exact file's own Runbooks/Postmortems empty
        //   states already carried before the split, so the destination and
        //   the empty state a captain saw there agree.
        // Its hue:
        //   `fm/grandline-docs-split-runbooks-postmortems`: the same two hues
        //   the runbook/postmortem plate cards already used before the split
        //   (`HelmDomainHue(tint:)` maps `.info` -> `.blue`, `.warn` -> `.amber`
        //   - the exact `HelmTint` each `DocGridItem` carried), so a card and
        //   the destination it opens can never disagree about a hue.
        ModuleDescriptor(route: .runbooks, title: "Runbooks", symbol: "list.bullet.rectangle", hue: .blue,
                         slot: .runbooks, subtitle: "Step-by-step operational procedures",
                         mountsEagerly: false, space: .stores, homeCards: [.runbooks],
                         newAction: .runbook, module: .knowledge, child: "Runbooks"),
        ModuleDescriptor(route: .postmortems, title: "Postmortems", symbol: "doc.text.magnifyingglass", hue: .amber,
                         slot: .postmortems, subtitle: "Incident write-ups and root causes",
                         mountsEagerly: false, space: .stores, homeCards: [.postmortems],
                         newAction: .task, module: .knowledge, child: "Postmortems"),
        // Its hue:
        //   (shared by .updates, .bootstrap, .automation, .githubSync, .poneglyph)
        //   Setup
        // Its line:
        //   `fm/grandline-separate-setup-destinations` split the one line these
        //   four shared ("Toolchain, machine config and fork sync") into four,
        //   now that each is its own page with its own title above it. In
        //   practice all four are fallbacks only: every one of them conforms to
        //   `DaylightDrillActions` and supplies its own live line (update
        //   counts, step counts, fork counts), which
        //   `AppShellController.applyDrillHeader` prefers.
        ModuleDescriptor(route: .updates, title: "Updates", symbol: "steeringwheel", hue: .amber,
                         slot: .updates, subtitle: "Every tool in the catalog, and what needs updating",
                         mountsEagerly: false, space: .engineering, homeCards: [.updates],
                         newAction: .task, module: .setup, child: "Updates"),
        // Its hue:
        //   (shared by .updates, .bootstrap, .automation, .githubSync, .poneglyph)
        //   Setup
        ModuleDescriptor(route: .bootstrap, title: "Bootstrap", symbol: "hammer", hue: .amber,
                         slot: .bootstrap, subtitle: "Set this machine up, and see what has drifted",
                         mountsEagerly: false, space: .engineering, homeCards: [.bootstrap],
                         newAction: .task, module: .setup, child: "Setup steps"),
        // Its hue:
        //   (shared by .updates, .bootstrap, .automation, .githubSync, .poneglyph)
        //   Setup
        ModuleDescriptor(route: .automation, title: "Automation", symbol: "bolt.fill", hue: .amber,
                         slot: .automation, subtitle: "Run every setup step in order, unattended",
                         mountsEagerly: false, space: .engineering, homeCards: [.automation],
                         newAction: .task, module: .setup, child: "Automation"),
        // Its hue:
        //   (shared by .updates, .bootstrap, .automation, .githubSync, .poneglyph)
        //   Setup
        ModuleDescriptor(route: .githubSync, title: "GitHub Sync", symbol: "arrow.2.squarepath", hue: .amber,
                         slot: .githubSync, subtitle: "Pull upstream into each of your personal forks",
                         mountsEagerly: false, space: .engineering, homeCards: [.githubSync],
                         newAction: .task, module: .setup, child: "GitHub sync"),
        // Its symbol:
        //   `fm/implement-grand-line-secrets-vault-poneg-ad`: a Poneglyph is a
        //   stone slab carrying hidden inscriptions - fitting for the captain's
        //   personal credential vault, which is what this destination shows
        //   after `fm/swap-vault-poneglyph-naming-in-grand-lin-1f` reclaimed
        //   "Vault" for Automic Vault's hardening panel (see `VaultController`'s
        //   header for the full history). `doc.text.image` is the closest read
        //   for "an inscribed tablet of secrets" in this family and is
        //   unclaimed here. Verified to resolve - `NSImage(systemSymbolName:)`
        //   returns nil silently, and this app has shipped an invisible icon
        //   that way before.
        // Its hue:
        //   (shared by .updates, .bootstrap, .automation, .githubSync, .poneglyph)
        //   Setup
        // Its line:
        //   The credential vault's own line, moved here from `.vault` by the
        //   same swap noted above. In practice this static string is a fallback
        //   only: `CredentialVaultController` conforms to `DaylightDrillActions`
        //   directly now (`fm/poneglyph-own-destination-and-strawhat-toolbar-
        //   shortcut` gave it its own slot instead of sharing the
        //   since-retired `SetupContainerController`'s) and always supplies its
        //   own live
        //   subtitle (credential count, lock state), which
        //   `AppShellController.applyDrillHeader` prefers - the same
        //   "conforming page wins, this is just what an unmigrated page would
        //   show" shape every other case in this switch already follows.
        ModuleDescriptor(route: .poneglyph, title: "Poneglyph", symbol: "doc.text.image", hue: .amber,
                         slot: .poneglyph, subtitle: "Your credentials, encrypted and one click from the clipboard",
                         mountsEagerly: false, space: .stores, homeCards: [.poneglyph],
                         newAction: .credential, module: .secrets, child: "Poneglyph"),
        ModuleDescriptor(route: .settings, title: "Settings", symbol: "gearshape", hue: .slate,
                         slot: .settings, subtitle: "Connection, appearance, terminal, security and backup",
                         mountsEagerly: false, space: .engineering, homeCards: [.settings],
                         newAction: .task, module: .settings, child: nil),
    ]

    /// The row for `route`. Every case has exactly one, which
    /// `ModuleTableSelfTest` asserts, so the fallback is unreachable in a
    /// tested build.
    /// R2-UX-10: the column floor of a page that names none. Measured with
    /// every page laid out in a narrower column at the default text scale:
    /// the widest of them (Settings 635pt, Updates 630pt, Schedules 623pt)
    /// sit under this, which keeps the sidebar beside them down to about
    /// 906pt. Scaled with the chrome text size by the shell.
    static let defaultMinimumContentWidth: CGFloat = 660

    /// R2-UX-10: a page tab wider than its page's floor. Tasks' Weekly
    /// review measured 920pt against 517pt for its Board, List and Calendar,
    /// so only that tab gives up the sidebar at a laptop width.
    static let pageTabMinimumContentWidths: [RailDestination: [String: CGFloat]] = [
        .shift: ["Weekly review": 940],
    ]

    /// The column floor `route`'s page needs (`ModuleDescriptor.minimumContentWidth`),
    /// or its page tab's when that tab names a wider one.
    static func minimumContentWidth(for route: RailDestination, pageTab: String? = nil) -> CGFloat {
        let page = descriptor(for: route)?.minimumContentWidth ?? defaultMinimumContentWidth
        guard let pageTab, let tab = pageTabMinimumContentWidths[route]?[pageTab] else { return page }
        return max(page, tab)
    }

    static func descriptor(for route: RailDestination) -> ModuleDescriptor? {
        byRoute[route]
    }

    /// The rows by route. Every title, symbol and hue lookup in the app
    /// comes through here since R2-ARCH-03, so it is a dictionary rather than
    /// a walk of the rows. A second row for a route would be dropped here;
    /// `ModuleTableSelfTest` fails on one first.
    private static let byRoute: [RailDestination: ModuleDescriptor] =
        Dictionary(rows.map { ($0.route, $0) }, uniquingKeysWith: { first, _ in first })

    /// Every sidebar item, in `WorkspaceModule` declaration order.
    ///
    /// A module of one page names no symbol and takes that page's own, so
    /// nothing a captain recognises changes; a module of several pages has
    /// one of its own. `pageTabHost` is the page that draws those of the
    /// module's children that are its own tabs rather than destinations:
    /// Shift's views are Tasks' tabs, the Fleet page's Needs you, Dashboard
    /// and Log are Crew's Needs you, In flight and Log, the Hosts page's
    /// Hosts, SSH Keys and Snippets are Connections' first three, the
    /// Calendar's Month, Week, Day and Agenda are its own, and Kubernetes'
    /// Cluster and Log Tail are its own. The captain dropped the content
    /// column's header on Connections and Console; the Calendar draws the
    /// mockup's heading itself, with its count beside it, so the column's
    /// header would only repeat it. Every other module keeps it.
    static let modules: [WorkspaceModuleDescriptor] = [
        WorkspaceModuleDescriptor(module: .home, title: "Home", group: nil, children: []),
        WorkspaceModuleDescriptor(module: .tasks, title: "Tasks", group: .work,
                                  children: ["Board", "List", "Weekly review"], pageTabHost: .shift),
        WorkspaceModuleDescriptor(module: .calendar, title: "Calendar", group: .work,
                                  children: ["Month", "Week", "Day", "Agenda"], pageTabHost: .calendar,
                                  showsHeader: false),
        WorkspaceModuleDescriptor(module: .crew, title: "Crew", group: .work,
                                  children: ["Needs you", "In flight", "Review", "Ask the crew", "Log"],
                                  symbol: "person.3.fill", pageTabHost: .overview),
        WorkspaceModuleDescriptor(module: .connections, title: "Connections", group: .work,
                                  children: ["Hosts", "Keys", "Snippets", "Commands"], symbol: "server.rack",
                                  pageTabHost: .hosts, showsHeader: false),
        WorkspaceModuleDescriptor(module: .console, title: "Console", group: .work, children: [], showsHeader: false),
        WorkspaceModuleDescriptor(module: .knowledge, title: "Knowledge", group: .work,
                                  children: ["Notebook", "Runbooks", "Postmortems", "Docs", "Reading list"],
                                  symbol: "books.vertical"),
        WorkspaceModuleDescriptor(module: .secrets, title: "Secrets", group: .work,
                                  children: ["Poneglyph", "Automic Vault"], symbol: "key.fill"),
        WorkspaceModuleDescriptor(module: .kubernetes, title: "Kubernetes", group: .observe,
                                  children: ["Cluster", "Log Tail"], pageTabHost: .kubernetes),
        WorkspaceModuleDescriptor(module: .logs, title: "Logs", group: .observe, children: []),
        WorkspaceModuleDescriptor(module: .health, title: "Health", group: .observe, children: []),
        WorkspaceModuleDescriptor(module: .schedules, title: "Schedules", group: .observe, children: []),
        WorkspaceModuleDescriptor(module: .tools, title: "Tools", group: .workbench, children: []),
        WorkspaceModuleDescriptor(module: .whiteboard, title: "Whiteboard", group: .workbench, children: []),
        WorkspaceModuleDescriptor(module: .stickyBoard, title: "Sticky Board", group: .workbench, children: []),
        WorkspaceModuleDescriptor(module: .code, title: "Code", group: .workbench, children: []),
        WorkspaceModuleDescriptor(module: .dictation, title: "Dictation", group: .workbench, children: []),
        WorkspaceModuleDescriptor(module: .setup, title: "Setup", group: .machine,
                                  children: ["Updates", "Setup steps", "Automation", "GitHub sync"], symbol: "hammer"),
        WorkspaceModuleDescriptor(module: .settings, title: "Settings", group: .machine,
                                  children: SettingsController.Category.allCases.map(\.title)),
    ]

    private static let byModule: [WorkspaceModule: WorkspaceModuleDescriptor] =
        Dictionary(modules.map { ($0.module, $0) }, uniquingKeysWith: { first, _ in first })

    /// `module`'s row. Every module has one, which `ModuleTableSelfTest`
    /// asserts; the fallback only keeps a missing row from crashing.
    static func row(for module: WorkspaceModule) -> WorkspaceModuleDescriptor {
        byModule[module] ?? WorkspaceModuleDescriptor(module: module, title: module.rawValue, group: nil, children: [])
    }

    /// The destinations that move into `module`, in table order.
    static func routes(in module: WorkspaceModule) -> [RailDestination] {
        rows.filter { $0.module == module }.map(\.route)
    }

    /// The module `route` lives in.
    static func module(for route: RailDestination) -> WorkspaceModule {
        descriptor(for: route)?.module ?? .home
    }

    /// The tab `route` stands for. On a page that draws several of its
    /// module's tabs, `pageTab` is which of its own tabs is showing; a page
    /// that has not said yet stands for the first of them.
    static func tab(for route: RailDestination, pageTab: String?) -> ModuleTab? {
        let tabs = module(for: route).tabs.filter { $0.route == route }
        return tabs.first { $0.name == pageTab } ?? tabs.first
    }
}
