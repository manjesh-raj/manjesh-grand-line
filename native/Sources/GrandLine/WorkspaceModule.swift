// Grand Line - native macOS app.
//
// The Module table: the seventeen sidebar items of the Workspace shell, in
// five sections, and which of the thirty `RailDestination` routes each one
// answers to.
//
// WHY IT EXISTS
//
// The 2026-10 end-to-end review (UX-01) counted thirty destinations, six
// "spaces" and five ways to reach a page - a Home card, a space pill, a
// quick-access square, Recents, the ⌘K palette and the all-destinations
// overlay - each covering a different subset, and nothing on screen that
// showed the whole app at once. The fix it recommended, and the captain chose,
// is design A ("Workspace"): a persistent source-list sidebar of seventeen
// labelled modules in four groups, a toolbar that names the module and holds
// its actions, a content column, and an inspector.
//
// This file is the review's section 5.2 `ModuleDescriptor`, kept as data
// rather than a protocol so a suite can iterate it. It is deliberately the
// smallest useful row: identity, the sidebar section, the chord, and the
// module's tabs. A tab is a route the app already has (a `RailDestination`,
// and optionally one of that page's own sub-pages), so consolidating thirty
// destinations into seventeen modules changes *where a page is listed*, not
// what the page is - every existing controller is still mounted, lazily and
// unchanged, by `DestinationMounter`.
//
// `RailDestination` stays the stable deep-link id. Notifications, App
// Intents, widgets, ⌘K and Recents keep naming the thirty routes, and the
// shell maps a route to its module and tab through `module(for:)` here.
//
// THE RULES THE SUITE HOLDS
//
// `ModuleTableSelfTest` asserts that every route resolves to exactly one
// module and one tab, that a module's chord is unique, and that the table
// agrees with the per-destination facts it is derived from (titles, symbols,
// the ⌘N owner). A new `RailDestination` therefore fails the run until it is
// given a module - it cannot silently become unreachable from the sidebar.

import AppKit

/// The sidebar's sections, top to bottom. Home stands alone above the first
/// header, which is why it has no title.
enum WorkspaceSection: String, CaseIterable {
    case home
    case work
    case observe
    case workbench
    case machine

    /// The section header the sidebar draws, or `nil` for the untitled Home
    /// section.
    var title: String? {
        switch self {
        case .home: return nil
        case .work: return "Work"
        case .observe: return "Observe"
        case .workbench: return "Workbench"
        case .machine: return "Machine"
        }
    }
}

/// The seventeen modules, in sidebar order.
enum WorkspaceModuleID: String, CaseIterable {
    case home
    case tasks, connections, crew, knowledge, secrets
    case kubernetes, logs, health, schedules
    case tools, whiteboard, stickyBoard, code, dictation
    case setup, settings
}

/// A sub-page a module tab can name inside a page that already has its own
/// internal tabs. The page conforms to `WorkspaceSubpageHosting` and is asked
/// to show it after the route itself is shown.
///
/// Raw string values rather than a typed enum per page, so this table does
/// not have to import every page's own tab type - the page parses the string
/// back into its own enum and ignores one it does not know.
struct WorkspaceSubpage: RawRepresentable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A page whose own internal tabs a module tab can select.
protocol WorkspaceSubpageHosting: AnyObject {
    /// Show `subpage`. A page that does not recognise the value leaves itself
    /// as it is.
    func showWorkspaceSubpage(_ subpage: WorkspaceSubpage)

    /// The sub-page showing now, so the shell can light the matching module
    /// tab when the page changed it itself.
    var currentWorkspaceSubpage: WorkspaceSubpage? { get }
}

/// One tab of a module: a route, optionally narrowed to one of that page's
/// own sub-pages.
struct WorkspaceModuleTab: Equatable {
    let title: String
    let route: RailDestination
    let subpage: WorkspaceSubpage?

    init(_ title: String, _ route: RailDestination, subpage: WorkspaceSubpage? = nil) {
        self.title = title
        self.route = route
        self.subpage = subpage
    }
}

/// A module chord: the key equivalent and its modifiers, as `NSMenuItem`
/// takes them.
struct WorkspaceChord: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    /// The chord as the menu and the palette print it, e.g. "⌘1".
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "\u{2303}" }
        if modifiers.contains(.option) { text += "\u{2325}" }
        if modifiers.contains(.shift) { text += "\u{21E7}" }
        if modifiers.contains(.command) { text += "\u{2318}" }
        return text + key.uppercased()
    }
}

/// One sidebar item.
struct ModuleDescriptor {
    let id: WorkspaceModuleID
    let title: String
    /// The SF Symbol the sidebar row draws, monochrome at rest.
    let symbol: String
    let section: WorkspaceSection
    /// ⌘1-⌘6 for Home and the Work group, and nothing for the rest: the
    /// review's section 4.7 gives chords to the six items used most, and ⌘,
    /// stays Settings' own (it is the app menu's standard item).
    let chord: WorkspaceChord?
    /// The module's tabs, in order. The first is where a click on the sidebar
    /// item lands. A module with one tab shows no tab strip.
    let tabs: [WorkspaceModuleTab]
    /// A short line for the palette and the sidebar's tooltip: what the
    /// module is for, in the captain's words rather than the page's history.
    let summary: String

    var defaultTab: WorkspaceModuleTab { tabs[0] }

    /// The routes this module answers to, in tab order and without
    /// duplicates (two tabs may share a route and differ by sub-page).
    var routes: [RailDestination] {
        var seen: Set<RailDestination> = []
        return tabs.compactMap { seen.insert($0.route).inserted ? $0.route : nil }
    }

    /// The identity hue of the module's first route, for the one place the
    /// shell draws identity (an 8pt dot), never a fill.
    var hue: HelmDomainHue { defaultTab.route.domainHue }
}

enum ModuleTable {

    /// The seventeen rows, in sidebar order. Section 4.3 of the review is the
    /// source; the "Was" column there is the `tabs` column here.
    static let all: [ModuleDescriptor] = [
        ModuleDescriptor(
            id: .home, title: "Home", symbol: "house", section: .home,
            chord: WorkspaceChord(key: "1", modifiers: .command),
            tabs: [WorkspaceModuleTab("Home", .homeCanvas),
                   WorkspaceModuleTab("Today", .dailyOverview)],
            summary: "What needs you, today's plan, the crew and live sessions"),

        ModuleDescriptor(
            id: .tasks, title: "Tasks", symbol: "checkmark.circle", section: .work,
            chord: WorkspaceChord(key: "2", modifiers: .command),
            tabs: [WorkspaceModuleTab("Board", .shift)],
            summary: "Personal and fleet tasks, follow-ups and projects"),
        ModuleDescriptor(
            id: .connections, title: "Connections", symbol: "point.3.connected.trianglepath.dotted",
            section: .work,
            chord: WorkspaceChord(key: "3", modifiers: .command),
            tabs: [WorkspaceModuleTab("Hosts", .hosts, subpage: WorkspaceSubpage("hosts")),
                   WorkspaceModuleTab("Keys", .hosts, subpage: WorkspaceSubpage("keys")),
                   WorkspaceModuleTab("Snippets", .hosts, subpage: WorkspaceSubpage("snippets")),
                   WorkspaceModuleTab("Commands", .commandLibrary),
                   WorkspaceModuleTab("Console", .console)],
            summary: "Hosts, keys, snippets, commands and live sessions"),
        ModuleDescriptor(
            id: .crew, title: "Crew", symbol: "person.2", section: .work,
            chord: WorkspaceChord(key: "4", modifiers: .command),
            tabs: [WorkspaceModuleTab("In flight", .overview),
                   WorkspaceModuleTab("Merge queue", .review),
                   WorkspaceModuleTab("Ask the crew", .strawHat)],
            summary: "The firstmate fleet: decisions, work in flight and the merge queue"),
        ModuleDescriptor(
            id: .knowledge, title: "Knowledge", symbol: "book.closed", section: .work,
            chord: WorkspaceChord(key: "5", modifiers: .command),
            tabs: [WorkspaceModuleTab("Pages", .notebook),
                   WorkspaceModuleTab("Runbooks", .runbooks),
                   WorkspaceModuleTab("Postmortems", .postmortems),
                   WorkspaceModuleTab("Playbook", .docs),
                   WorkspaceModuleTab("Reading list", .readingList)],
            summary: "Notes, runbooks, postmortems, the playbook and links to read"),
        ModuleDescriptor(
            id: .secrets, title: "Secrets", symbol: "lock", section: .work,
            chord: WorkspaceChord(key: "6", modifiers: .command),
            tabs: [WorkspaceModuleTab("Poneglyph", .poneglyph),
                   WorkspaceModuleTab("Automic Vault", .vault)],
            summary: "Poneglyph, the encrypted credential vault, and Automic Vault"),

        ModuleDescriptor(
            id: .kubernetes, title: "Kubernetes", symbol: "cube", section: .observe, chord: nil,
            tabs: [WorkspaceModuleTab("Cluster", .kubernetes)],
            summary: "Read-only cluster browsing and multi-pod log tailing"),
        ModuleDescriptor(
            id: .logs, title: "Logs", symbol: "text.magnifyingglass", section: .observe, chord: nil,
            tabs: [WorkspaceModuleTab("Log Analyzer", .logAnalyzer)],
            summary: "Collect, analyse and explain captured output"),
        ModuleDescriptor(
            id: .health, title: "Health", symbol: "heart", section: .observe, chord: nil,
            tabs: [WorkspaceModuleTab("Services", .health)],
            summary: "This app's own background services"),
        ModuleDescriptor(
            id: .schedules, title: "Schedules", symbol: "calendar", section: .observe, chord: nil,
            tabs: [WorkspaceModuleTab("Schedules", .schedules)],
            summary: "Unattended runs of actions this app already has"),

        ModuleDescriptor(
            id: .tools, title: "Tools", symbol: "wrench.and.screwdriver", section: .workbench, chord: nil,
            tabs: [WorkspaceModuleTab("Tools", .tools)],
            summary: "Nine offline utilities, including the Scratchpad"),
        ModuleDescriptor(
            id: .whiteboard, title: "Whiteboard", symbol: "scribble.variable", section: .workbench, chord: nil,
            tabs: [WorkspaceModuleTab("Whiteboard", .whiteboard)],
            summary: "An Excalidraw canvas, offline, with AI diagrams"),
        ModuleDescriptor(
            id: .stickyBoard, title: "Sticky Board", symbol: "note.text", section: .workbench, chord: nil,
            tabs: [WorkspaceModuleTab("Board", .stickyBoard)],
            summary: "A freeform corkboard of quick notes"),
        ModuleDescriptor(
            id: .code, title: "Code", symbol: "chevron.left.forwardslash.chevron.right",
            section: .workbench, chord: nil,
            tabs: [WorkspaceModuleTab("Code Preview", .codePreview)],
            summary: "Paste code, read it properly, run it in a sandbox"),
        ModuleDescriptor(
            id: .dictation, title: "Dictation", symbol: "mic", section: .workbench, chord: nil,
            tabs: [WorkspaceModuleTab("Dictation", .dictation)],
            summary: "Speech to text, on this machine"),

        ModuleDescriptor(
            id: .setup, title: "Setup", symbol: "hammer", section: .machine, chord: nil,
            tabs: [WorkspaceModuleTab("Tools", .updates),
                   WorkspaceModuleTab("Setup steps", .bootstrap),
                   WorkspaceModuleTab("Automation", .automation),
                   WorkspaceModuleTab("Forks", .githubSync)],
            summary: "Tool updates, machine setup, automation and fork sync"),
        ModuleDescriptor(
            id: .settings, title: "Settings", symbol: "gearshape", section: .machine, chord: nil,
            tabs: [WorkspaceModuleTab("Settings", .settings)],
            summary: "Preferences, stored on this Mac"),
    ]

    // `ModuleTableSelfTest` holds that every id has exactly one row; the
    // first row wins if that ever breaks, rather than trapping at launch.
    private static let byID: [WorkspaceModuleID: ModuleDescriptor] =
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    private static let byRoute: [RailDestination: WorkspaceModuleID] = {
        var map: [RailDestination: WorkspaceModuleID] = [:]
        for module in all {
            for route in module.routes where map[route] == nil { map[route] = module.id }
        }
        return map
    }()

    static func descriptor(_ id: WorkspaceModuleID) -> ModuleDescriptor {
        // Every case has a row; `ModuleTableSelfTest` holds that, so a missing
        // one is a programming error rather than a state to render.
        guard let descriptor = byID[id] else {
            preconditionFailure("no module row for \(id.rawValue)")
        }
        return descriptor
    }

    /// The module that owns `route`, or `nil` for a route no row lists -
    /// which `ModuleTableSelfTest` makes a failing run rather than a state.
    static func owner(of route: RailDestination) -> ModuleDescriptor? {
        byRoute[route].map(descriptor)
    }

    /// The module that owns `route`. Every route has exactly one owner.
    static func module(for route: RailDestination) -> ModuleDescriptor {
        guard let module = owner(of: route) else {
            preconditionFailure("no module owns route \(route.rawValue)")
        }
        return module
    }

    /// The tab a route lands on: the first tab of its module naming that
    /// route, or, when `subpage` is given, the tab naming both.
    static func tab(for route: RailDestination, subpage: WorkspaceSubpage? = nil) -> WorkspaceModuleTab {
        let module = module(for: route)
        if let subpage, let exact = module.tabs.first(where: { $0.route == route && $0.subpage == subpage }) {
            return exact
        }
        return module.tabs.first { $0.route == route } ?? module.defaultTab
    }

    /// The modules of one section, in sidebar order.
    static func modules(in section: WorkspaceSection) -> [ModuleDescriptor] {
        all.filter { $0.section == section }
    }
}
