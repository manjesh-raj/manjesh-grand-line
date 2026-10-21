// Grand Line - native macOS app.
//
// `ModuleTable` - step 0 of the modular-shell migration (full review section
// 5.8): one visible row per destination, and the module each one moves into.
//
// **What this is for.** A destination's identity is spread over six tables
// today (ARCH-03 of the 2026-10 end-to-end review):
//
//   - `RailDestination` - its title and symbol,
//   - `HelmDaylight`'s `RailDestination.domainHue` - its hue,
//   - `DestinationRegistry` - its body slot and its drill subtitle,
//   - `AppShellController`'s `register(...)` lines - whether it mounts eagerly,
//   - `DaylightModule` - the space it lives in and the Home cards that open it,
//   - `ContextualNewAction` - what ⌘N creates on it.
//
// The rows below restate all six as literal data, one row per destination,
// so the spread is one table a reader can see at once.
// They are typed out rather than derived on purpose: a row computed from the
// table it is checked against asserts nothing.
// `ModuleTableSelfTest` asserts that every row agrees with each of the six old
// tables, so the two sources of truth cannot drift while both exist.
//
// **What it does not do yet.** Nothing in the shell reads this table.
// It changes no behaviour, mounts nothing and draws nothing.
// Step 3 of the migration builds the split-view shell over it, and step 4 makes
// the sidebar's groups and children come from it.
//
// **The planned home of each destination** is the `module` and `child` columns.
// They follow the captain's modular workspace prototype (Version 2): eighteen
// sidebar items, which are Home plus seventeen modules in four groups, with
// Console as its own module.
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

    var title: String {
        switch self {
        case .home: return "Home"
        case .tasks: return "Tasks"
        case .crew: return "Crew"
        case .connections: return "Connections"
        case .console: return "Console"
        case .knowledge: return "Knowledge"
        case .secrets: return "Secrets"
        case .kubernetes: return "Kubernetes"
        case .logs: return "Logs"
        case .health: return "Health"
        case .schedules: return "Schedules"
        case .tools: return "Tools"
        case .whiteboard: return "Whiteboard"
        case .stickyBoard: return "Sticky Board"
        case .code: return "Code"
        case .dictation: return "Dictation"
        case .setup: return "Setup"
        case .settings: return "Settings"
        }
    }

    /// `nil` for Home, which sits above the four groups.
    var group: WorkspaceGroup? {
        switch self {
        case .home: return nil
        case .tasks, .crew, .connections, .console, .knowledge, .secrets: return .work
        case .kubernetes, .logs, .health, .schedules: return .observe
        case .tools, .whiteboard, .stickyBoard, .code, .dictation: return .workbench
        case .setup, .settings: return .machine
        }
    }

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
    var children: [String] {
        switch self {
        case .tasks: return ["Board", "List", "Calendar", "Weekly review"]
        case .crew: return ["Needs you", "In flight", "Merge queue", "Review", "Ask the crew", "Log"]
        case .connections: return ["Hosts", "Sessions", "Keys", "Snippets", "Commands"]
        case .knowledge: return ["Notebook", "Runbooks", "Postmortems", "Playbook", "Reading list"]
        case .secrets: return ["Poneglyph", "Automic Vault"]
        case .kubernetes: return ["Cluster", "Log Tail"]
        case .setup: return ["Updates", "Setup steps", "Automation", "GitHub sync"]
        case .settings: return SettingsController.Category.allCases.map(\.title)
        case .home, .console, .logs, .health, .schedules, .tools, .whiteboard, .stickyBoard, .code, .dictation:
            return []
        }
    }
}

/// One destination, with everything the six old tables say about it and the
/// module it moves into.
struct ModuleDescriptor {
    /// The stable route id. Notifications, App Intents, ⌘K, Recents and
    /// session restore all address a page by this, and they keep doing so
    /// after the consolidation.
    let route: RailDestination
    /// `RailDestination.title`.
    let title: String
    /// `RailDestination.symbol`.
    let symbol: String
    /// `RailDestination.domainHue`.
    let hue: HelmDomainHue
    /// `RailDestination.slot`.
    let slot: DestinationSlotID
    /// `RailDestination.drillSubtitle` - the static fallback under the title.
    let subtitle: String
    /// The `mountsEagerly` flag in the destination's `register(...)` line.
    let mountsEagerly: Bool
    /// `DaylightModule.space(forDestination:)`.
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
}

enum ModuleTable {

    /// Every destination, in `RailDestination` declaration order.
    static let rows: [ModuleDescriptor] = [
        ModuleDescriptor(route: .homeCanvas, title: "Home", symbol: "sailboat.fill", hue: .blue,
                         slot: .homeCanvas, subtitle: "", mountsEagerly: true, space: nil,
                         homeCards: [], newAction: .task, module: .home, child: nil),
        ModuleDescriptor(route: .overview, title: "Fleet", symbol: "square.grid.2x2", hue: .blue,
                         slot: .overview, subtitle: "Dispatched crew, decisions and the morning briefing",
                         mountsEagerly: true, space: nil, homeCards: [.briefing, .fleet],
                         newAction: .task, module: .crew, child: "In flight"),
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
        ModuleDescriptor(route: .shift, title: "Tasks", symbol: "checkmark.circle", hue: .rose,
                         slot: .shift, subtitle: "A task board, follow-ups and projects",
                         mountsEagerly: false, space: .command, homeCards: [.tasks],
                         newAction: .task, module: .tasks, child: nil),
        ModuleDescriptor(route: .review, title: "Review", symbol: "arrow.triangle.branch", hue: .green,
                         slot: .review, subtitle: "Open pull requests, ready to merge",
                         mountsEagerly: true, space: .command, homeCards: [.mergeQueue],
                         newAction: .task, module: .crew, child: "Review"),
        ModuleDescriptor(route: .logAnalyzer, title: "Log Analyzer", symbol: "text.magnifyingglass", hue: .teal,
                         slot: .logAnalyzer, subtitle: "Collect, analyse and explain captured output",
                         mountsEagerly: false, space: .operations, homeCards: [.logAnalyzer],
                         newAction: .task, module: .logs, child: nil),
        ModuleDescriptor(route: .kubernetes, title: "Kubernetes", symbol: "cube.transparent", hue: .teal,
                         slot: .kubernetes, subtitle: "Read-only cluster browsing and multi-pod log tailing",
                         mountsEagerly: false, space: .operations, homeCards: [.kubernetes],
                         newAction: .task, module: .kubernetes, child: nil),
        ModuleDescriptor(route: .tools, title: "Tools", symbol: "wrench.and.screwdriver", hue: .slate,
                         slot: .tools, subtitle: "Nine offline utilities",
                         mountsEagerly: false, space: .stores, homeCards: [.tools],
                         newAction: .task, module: .tools, child: nil),
        ModuleDescriptor(route: .whiteboard, title: "Whiteboard", symbol: "scribble.variable", hue: .violet,
                         slot: .whiteboard, subtitle: "An Excalidraw canvas, offline, with AI diagrams",
                         mountsEagerly: false, space: .stores, homeCards: [.whiteboard],
                         newAction: .task, module: .whiteboard, child: nil),
        ModuleDescriptor(route: .codePreview, title: "Code Preview",
                         symbol: "chevron.left.forwardslash.chevron.right", hue: .blue,
                         slot: .codePreview, subtitle: "Paste code and read it properly, synced to your config repo",
                         mountsEagerly: false, space: .stores, homeCards: [.codePreview],
                         newAction: .codeSnippet, module: .code, child: nil),
        ModuleDescriptor(route: .stickyBoard, title: "Sticky Board", symbol: "note.text", hue: .amber,
                         slot: .stickyBoard, subtitle: "A freeform corkboard of quick sticky notes",
                         mountsEagerly: false, space: .stores, homeCards: [.stickyBoard],
                         newAction: .stickyNote, module: .stickyBoard, child: nil),
        ModuleDescriptor(route: .commandLibrary, title: "DevOps Commands", symbol: "books.vertical", hue: .teal,
                         slot: .commandLibrary, subtitle: "Your saved shell commands, parameterised and ready to run",
                         mountsEagerly: false, space: .command, homeCards: [.commandLibrary],
                         newAction: .command, module: .connections, child: "Commands"),
        ModuleDescriptor(route: .vault, title: "Vault", symbol: "lock.shield", hue: .violet,
                         slot: .vault, subtitle: "Secret names and tool hardening status from Automic Vault",
                         mountsEagerly: false, space: .stores, homeCards: [.vault],
                         newAction: .task, module: .secrets, child: "Automic Vault"),
        ModuleDescriptor(route: .dictation, title: "Dictation", symbol: "waveform", hue: .rose,
                         slot: .dictation, subtitle: "Speech to text, on this machine",
                         mountsEagerly: false, space: .stores, homeCards: [.dictation],
                         newAction: .task, module: .dictation, child: nil),
        ModuleDescriptor(route: .schedules, title: "Schedules", symbol: "calendar", hue: .violet,
                         slot: .schedules, subtitle: "Unattended runs of actions this app already has",
                         mountsEagerly: false, space: .operations, homeCards: [.schedules],
                         newAction: .schedule, module: .schedules, child: nil),
        ModuleDescriptor(route: .health, title: "Health", symbol: "waveform.path.ecg", hue: .green,
                         slot: .health, subtitle: "How this app's own background services are doing",
                         mountsEagerly: false, space: .operations, homeCards: [.health],
                         newAction: .task, module: .health, child: nil),
        ModuleDescriptor(route: .docs, title: "Docs", symbol: "book.closed", hue: .blue,
                         slot: .docs, subtitle: "The DevOps Playbook, browsable offline",
                         mountsEagerly: false, space: .stores, homeCards: [.docs],
                         newAction: .task, module: .knowledge, child: "Playbook"),
        ModuleDescriptor(route: .notebook, title: "Notebook", symbol: "book.and.wrench", hue: .blue,
                         slot: .notebook, subtitle: "Linked markdown pages, in your own config repo",
                         mountsEagerly: false, space: .stores, homeCards: [.notebook],
                         newAction: .notebookPage, module: .knowledge, child: "Notebook"),
        ModuleDescriptor(route: .readingList, title: "Reading List", symbol: "bookmark.fill", hue: .green,
                         slot: .readingList, subtitle: "Links you saved to read, with titles read on this machine",
                         mountsEagerly: false, space: .stores, homeCards: [.readingList],
                         newAction: .savedLink, module: .knowledge, child: "Reading list"),
        ModuleDescriptor(route: .runbooks, title: "Runbooks", symbol: "list.bullet.rectangle", hue: .blue,
                         slot: .runbooks, subtitle: "Step-by-step operational procedures",
                         mountsEagerly: false, space: .stores, homeCards: [.runbooks],
                         newAction: .runbook, module: .knowledge, child: "Runbooks"),
        ModuleDescriptor(route: .postmortems, title: "Postmortems", symbol: "doc.text.magnifyingglass", hue: .amber,
                         slot: .postmortems, subtitle: "Incident write-ups and root causes",
                         mountsEagerly: false, space: .stores, homeCards: [.postmortems],
                         newAction: .task, module: .knowledge, child: "Postmortems"),
        ModuleDescriptor(route: .updates, title: "Updates", symbol: "steeringwheel", hue: .amber,
                         slot: .updates, subtitle: "Every tool in the catalog, and what needs updating",
                         mountsEagerly: false, space: .engineering, homeCards: [.updates],
                         newAction: .task, module: .setup, child: "Updates"),
        ModuleDescriptor(route: .bootstrap, title: "Bootstrap", symbol: "hammer", hue: .amber,
                         slot: .bootstrap, subtitle: "Set this machine up, and see what has drifted",
                         mountsEagerly: false, space: .engineering, homeCards: [.bootstrap],
                         newAction: .task, module: .setup, child: "Setup steps"),
        ModuleDescriptor(route: .automation, title: "Automation", symbol: "bolt.fill", hue: .amber,
                         slot: .automation, subtitle: "Run every setup step in order, unattended",
                         mountsEagerly: false, space: .engineering, homeCards: [.automation],
                         newAction: .task, module: .setup, child: "Automation"),
        ModuleDescriptor(route: .githubSync, title: "GitHub Sync", symbol: "arrow.2.squarepath", hue: .amber,
                         slot: .githubSync, subtitle: "Pull upstream into each of your personal forks",
                         mountsEagerly: false, space: .engineering, homeCards: [.githubSync],
                         newAction: .task, module: .setup, child: "GitHub sync"),
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
    static func descriptor(for route: RailDestination) -> ModuleDescriptor? {
        rows.first { $0.route == route }
    }

    /// The destinations that move into `module`, in table order.
    static func routes(in module: WorkspaceModule) -> [RailDestination] {
        rows.filter { $0.module == module }.map(\.route)
    }
}
