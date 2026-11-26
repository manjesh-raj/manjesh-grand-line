// Grand Line - native macOS app.
//
// The sidebar shell's sidebar (stages 3 and 4 of the modular-shell migration,
// full review section 5.8): a source list over the module table, hosted in the
// split view's sidebar item.
//
// It lists Home and the eighteen modules under the four groups the module
// table assigns (Work, Observe, Workbench, Machine), the live host sessions
// as children of Connections, where a host is launched from. DevOps Hub's
// local projects are cards on its own page, not rows here, and the DevOps Hub
// row carries their badge. A
// module's pages are its tabs in the window toolbar, so every one of the 29
// destinations is one click on its module and one on its tab.
//
// **There are no pins here** (stage 6, the captain's call): a Pinned section
// listed pages that already had a row and a tab, so it was the same map twice.
// The quick-access pins themselves are untouched - the floating bar still
// draws them and still edits them from its ⌘⇧D map.
//
// Two halves, the same split the rest of this app uses:
//
//   - `WorkspaceSidebarModel` - which rows exist, in what order. Pure logic,
//     read straight off `ModuleTable` and the session registry, and asserted
//     headless by `SplitShellModelSelfTest`.
//   - `WorkspaceSidebarController` - the `NSOutlineView` that draws them, the
//     account header above it, and the context menus.
//
// The sidebar draws state, it does not navigate: a click is forwarded to the
// shell, which routes through the `Navigator` like every other entry point,
// and the row is lit from what the workspace reports is showing.
//
// **Sb-4: the whole sidebar is a hero column** (3.0.0, the Sb-4 design from
// the sidebar board, `data/grand-line-sidebar-mockups/`). The pane is the
// hero's gradient in the theme's accent (`HelmHeroSurface`, through
// `HelmHeroColumn`'s palette rule), edge to edge and under the title bar, so
// the shell gives it a plain split item rather than the system's sidebar
// material. Every word, glyph, count and mark is in the gradient's ink
// (`HelmHeroColumn.NavInk`), the lit row is a pill in the ink with its words
// in the hero's deep colour, the groups are small-caps titles with their row
// counts, and a hairline in the ink separates two rows - Secrets' S-3 column,
// applied to the app's own map.
//
// It is still the `NSOutlineView` it was, because that is what gives the
// sidebar its group disclosure, arrow-key navigation, context menus and
// VoiceOver tree; only its paint changed. A rebuild on `HelmHeroColumn`
// itself would have had to write all four again for a flat stack of rows.
// There is still no foot under Settings: the board drew a strip of three
// figures there, and it was left out.

import AppKit

/// One row of the sidebar.
enum WorkspaceSidebarEntry: Equatable {
    /// A section header: one of the four groups.
    case section(String)
    /// Home, or one of the eighteen modules.
    case module(WorkspaceModule)
    /// A live host session, a child of Connections (`sessionsParent`).
    case session(hostID: UUID)
}

/// A DevOps Hub project as the DevOps Hub row's badge reads it
/// (`WorkspaceSignals.devopsHubBadge`): its name and a mark for its state.
/// Pure, so `DevOpsHubModelSelfTest` asserts every state's mark headless.
struct WorkspaceSidebarProject: Equatable {
    let id: String
    let name: String
    let state: LocalProjectState
    let port: UInt16

    /// What the project's state means to the badge.
    enum Mark: Equatable {
        /// Not started.
        case idle
        /// Starting: the badge's scanning dash.
        case starting
        /// Serving: counted.
        case live
        /// A start failed: the red dot.
        case failed
        /// The folder is not where it should be: the amber dot.
        case attention
    }

    var mark: Mark {
        switch state {
        case .notStarted: return .idle
        case .starting: return .starting
        case .running: return .live
        case .failed: return .failed
        case .folderNotFound: return .attention
        }
    }
}

/// Which rows the sidebar shows, in order.
enum WorkspaceSidebarModel {

    struct Node: Equatable {
        let entry: WorkspaceSidebarEntry
        var children: [Node] = []
    }

    /// The sidebar's top level: Home, then the four groups, without the
    /// modules the captain's profile hides (R2-UX-01 (b)). A group with
    /// nothing left in it is left out too, rather than drawn as an empty
    /// heading.
    /// UX-28: the module pinned to the sidebar's foot rather than listed,
    /// so it never scrolls away - Settings, where the text size is changed.
    /// It keeps its place in every other map (the Go menu, its chord).
    static let footModule: WorkspaceModule = .settings

    static func roots(sessions: [HostSession], hidden: Set<WorkspaceModule> = []) -> [Node] {
        var roots = [Node(entry: .module(.home))]
        for group in WorkspaceGroup.allCases {
            let shown = modules(in: group, hidden: hidden).filter { $0 != footModule }
            guard !shown.isEmpty else { continue }
            let parent = sessionsParent(hidden: hidden)
            let rows = shown.map { module -> Node in
                guard module == parent else { return Node(entry: .module(module)) }
                return Node(entry: .module(module), children: sessions.map { Node(entry: .session(hostID: $0.hostID)) })
            }
            roots.append(Node(entry: .section(group.title), children: rows))
        }
        return roots
    }

    /// The row the live sessions sit under: Connections, where a host is
    /// launched from, so a session is listed beside the host it came from.
    /// Every session in the registry is a saved host's SSH session; a local
    /// shell has no row of its own. Console takes them only when the
    /// captain's profile hides Connections, so a session keeps a row. With
    /// both hidden there is none, which is what a hidden Console meant
    /// before, and ⌃⌘1...9 still reach every session.
    static func sessionsParent(hidden: Set<WorkspaceModule> = []) -> WorkspaceModule? {
        [WorkspaceModule.connections, .console].first { !hidden.contains($0) }
    }

    /// The modules in `group`, in the module table's sidebar order.
    static func modules(in group: WorkspaceGroup, hidden: Set<WorkspaceModule> = []) -> [WorkspaceModule] {
        WorkspaceModule.allCases.filter { $0.group == group && !hidden.contains($0) }
    }

    /// Every module the sidebar lists, once - the completeness
    /// `SplitShellModelSelfTest` asserts against the module table.
    static func listedModules(hidden: Set<WorkspaceModule> = []) -> [WorkspaceModule] {
        [.home] + WorkspaceGroup.allCases.flatMap { modules(in: $0, hidden: hidden) }
    }
}

extension WorkspaceModule {
    /// The page a module opens on the first time: its first tab that is its
    /// own (Knowledge's Docs - its Notebook tab belongs to the Notebook door
    /// row, R5-UX-05), its one page, or for a door row the route it is a door
    /// to.
    var primaryRoute: RailDestination {
        let own = tabs.first { ModuleTable.sidebarModule(for: $0.route, pageTab: $0.name) == self }
        return (own ?? tabs.first)?.route ?? ModuleTable.routes(in: self).first ?? doorRoute ?? .homeCanvas
    }

    /// The module's pages, each once, in tab order.
    var pages: [RailDestination] {
        let fromTabs = tabs.map(\.route)
        let ordered = fromTabs + ModuleTable.routes(in: self).filter { !fromTabs.contains($0) }
        return ordered.enumerated().filter { index, route in ordered.firstIndex(of: route) == index }.map(\.element)
    }
}

/// The sidebar's sizes, in one place.
///
/// The system's Large source-list size (Apple's Human Interface Guidelines,
/// Sidebars: 32pt rows, 24pt icons, 15pt text). The column drew the Medium
/// size (28pt rows, 13pt text) until stage 7, when the captain asked for
/// bigger text and icons because the column had room to spare below
/// Settings. Every row still fits the column's 264pt width beside its badge
/// (U-03 widened it from 236, which still fits and is where it narrows to),
/// and the list scrolls in a window too short to show it all, as it always
/// did. Each size goes through `HelmType.scaled`, so the chrome text scale
/// still moves all of them together.
enum WorkspaceSidebarMetrics {
    /// Home and the modules.
    static let moduleRowHeight: CGFloat = 32
    /// A live session under Connections: one step down from a module.
    static let sessionRowHeight: CGFloat = 30
    /// A group heading, with the room above it that separates the groups.
    /// 34 until review #4: with Console holding one session the default list
    /// (24 rows) came out 836pt against an 823pt clip view in a 950pt window,
    /// so the lit row's scroll left Home half under the header (R4-BUG-03).
    /// 30 brings the list to 820pt, and only the gap above each heading gives.
    /// R5-UX-05 added Runbooks to an Operator's Observe group, one 32pt row,
    /// and the gap gave again: 24 keeps the default list (25 rows with one
    /// session) inside the same clip view, and every row keeps the Large
    /// size. The feel pass's search pill (item 4) took 25pt more of the
    /// column, and the captain's call was that the gap gives once more: 18
    /// is the 13pt heading's own height with a 2pt foot, so the default list
    /// still fits a 950pt window with every row at the Large size.
    static let sectionRowHeight: CGFloat = 18
    /// Sb-4 keeps the Large size chosen at stage 7, and takes
    /// the hero rows' heavier weight: on a gradient a regular-weight label
    /// reads thin.
    static let moduleTextSize: CGFloat = 15
    static let sessionTextSize: CGFloat = 14
    static let labelWeight: NSFont.Weight = .medium
    /// Sb-4's group titles are the hero column's small-caps kicker. A
    /// collapsed group carries what is waiting inside it at the trailing
    /// edge, in a pill that fits the 18pt heading row (UI-02).
    static let sectionTextSize: CGFloat = 11
    static let sectionBadgeHeight: CGFloat = 16
    /// The lit row's pill and a hovered row's fill: `HelmHeroNavRow`'s radius.
    static let pillRadius: CGFloat = 8
    /// The icon's box, and the symbol drawn in it at the Medium symbol scale.
    static let iconSide: CGFloat = 24
    static let symbolPointSize: CGFloat = 16
    /// A badge's digits, and the pill they sit in.
    static let badgeTextSize: CGFloat = 12
    static let badgeHeight: CGFloat = 19
    static let badgeSymbolSide: CGFloat = 14
    /// The ⌃⌘ shortcut beside a session.
    static let shortcutTextSize: CGFloat = 12
}

/// Sb-4: the sidebar's colours - the hero column's navigation ink on the
/// theme's accent, the same tone the Secrets column paints in.
enum WorkspaceSidebarInk {
    static let tone = HelmModuleCard.HeroTone(colour: .themeAccent)

    /// One palette per theme, since every cell asks on every repaint.
    private static var cached: (key: String, ink: HelmHeroColumn.NavInk)?

    static func of(_ theme: HelmTheme) -> HelmHeroColumn.NavInk {
        let key = "\(theme.id)|\(theme.heroAccentHex)"
        if let cached, cached.key == key { return cached.ink }
        let ink = HelmHeroColumn.navInk(for: tone, in: theme)
        cached = (key, ink)
        return ink
    }

    /// What a menu the sidebar opens is drawn in: the theme's own mode, not
    /// the gradient's, since a menu floats over the page rather than the pane.
    static func menuAppearance(_ theme: HelmTheme) -> NSAppearance? {
        NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
    }
}

/// The outline view's item: a node with object identity, which is what
/// `NSOutlineView` keys its expansion state on.
final class WorkspaceSidebarItem: NSObject {
    let entry: WorkspaceSidebarEntry
    let children: [WorkspaceSidebarItem]

    init(_ node: WorkspaceSidebarModel.Node) {
        entry = node.entry
        children = node.children.map(WorkspaceSidebarItem.init)
    }

    var isSection: Bool {
        if case .section = entry { return true }
        return false
    }
}

final class WorkspaceSidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {

    // Forwarded, never owned - the sidebar has no idea what navigating is.
    var onSelectModule: ((WorkspaceModule) -> Void)?
    /// A click on a module's row while it is already lit: DevOps Hub's goes
    /// back to its project cards from a project's own view.
    var onReselectModule: ((WorkspaceModule) -> Void)?
    var onSelectSession: ((UUID) -> Void)?
    var onEndSession: ((UUID) -> Void)?
    var onConnectHost: (() -> Void)?
    var onLogOut: (() -> Void)?

    let outlineView = WorkspaceSidebarOutlineView()
    private let scrollView = NSScrollView()
    /// The account header. The feel pass's "Search or jump to" pill sat
    /// under it until the captain removed it: the toolbar's Search (and ⌘K)
    /// is on every page, so the sidebar's copy of it was a second entry
    /// point to the same palette. A plain gap now separates the header from
    /// Home (`headerGap`).
    private let header = WorkspaceSidebarHeader()
    /// UX-28: Settings, pinned under the list with a hairline above it.
    private let foot = WorkspaceSidebarFoot()
    /// UX-28: the list's last 16pt fade while more rows are below.
    private let listFade = CAGradientLayer()
    /// Sb-4: the pane's gradient, under everything, from the window's top
    /// edge (the traffic lights sit on it) to its foot. It stays put while
    /// the list scrolls over it.
    private let surface = HelmHeroSurface()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace.sidebar.column"))

    private var roots: [WorkspaceSidebarItem] = []
    private var sessions: [HostSession] = []
    private var shortcutIndexByHost: [UUID: Int] = [:]
    /// DevOps Hub's projects, for its row's badge.
    private var projects: [WorkspaceSidebarProject] = []
    /// Section titles the captain collapsed, so a rebuild (a session coming
    /// or going) keeps them collapsed. In memory only: like the window's own
    /// sidebar width, it is not worth a preference.
    private var collapsedSections: Set<String> = []
    /// Modules whose children were folded away by hand (Connections' live
    /// sessions), kept across a rebuild the same way.
    private var collapsedModules: Set<WorkspaceModule> = []
    /// What the workspace last said is showing, so a rebuild can light the
    /// same row again.
    private var current: RecentDestinationKind?
    /// The showing page's own tab, which decides the lit row on a page that
    /// a door row opens a view of (`ModuleTable.sidebarModule(for:pageTab:)`).
    private var currentPageTab: String?
    /// Guards the programmatic selection that lights a row, so it is never
    /// mistaken for the captain picking one.
    private var isApplyingSelection = false
    private var themeToken: ThemeObservation?
    /// The modules the captain's profile leaves out (R2-UX-01 (b)).
    private var hidden: Set<WorkspaceModule> = AppSettings.shared.hiddenModules
    private var hiddenObserver: NSObjectProtocol?
    /// The chrome text scale the rows were built at. A change of it is the
    /// one theme re-fire that rebuilds them (R2-PERF-02).
    private var builtTextScale = ChromeTextScale.shared.scale
    /// The density the rows were last built at: a change rebuilds them, as a
    /// text-scale change does, because both move `HelmType.scaledRowHeight`.
    private var builtDensity = HelmDensity.current

    // MARK: Build

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: MainSplitShellController.sidebarWidth, height: 600))
        root.wantsLayer = true
        view = root

        root.addSubview(surface)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onClick = { [weak self] in self?.showAccountMenu() }
        root.addSubview(header)

        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        // The lit row is drawn by `WorkspaceSidebarRowView` (a soft accent
        // wash), which only `.regular` hands to the row view - the source
        // list's own selection is a separate system view drawn over it.
        outlineView.selectionHighlightStyle = .regular
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = HelmMetrics.s3
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        // A click on the row that is already lit changes no selection, so
        // it reaches the shell through the table's own action instead.
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.setAccessibilityLabel("Sidebar")
        outlineView.onReturnKey = { [weak self] in self?.activateSelectionNow() }
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        root.addSubview(scrollView)
        foot.translatesAutoresizingMaskIntoConstraints = false
        foot.onClick = { [weak self] in self?.onSelectModule?(WorkspaceSidebarModel.footModule) }
        root.addSubview(foot)
        // UX-28: the fade is a mask on the list, so the gradient under it
        // shows through, whatever the palette.
        scrollView.wantsLayer = true
        HelmMotion.withoutImplicitAnimation {
            listFade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listMoved),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(listMoved),
                                               name: NSView.frameDidChangeNotification, object: outlineView)

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // The window's traffic lights and the sidebar toggle sit in the
            // title bar over this column, so the header starts below it.
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: HelmMetrics.s1),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s2),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s2),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Self.headerGap),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: foot.topAnchor),
            foot.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s2),
            foot.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s2),
            foot.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.s2),
        ])

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        hiddenObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.hiddenModulesDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.setHiddenModules(AppSettings.shared.hiddenModules) }
        rebuild()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        listMoved()
    }

    /// UX-28: the fade shows only while rows are hidden below the list's
    /// foot, so a list that fits, or one scrolled to its end, is not dimmed.
    @objc private func listMoved() {
        // The foot's glyph sits under the listed rows' glyphs.
        let homeRow = outlineView.row(forItem: roots.first)
        if homeRow >= 0, let cell = outlineView.view(atColumn: 0, row: homeRow, makeIfNecessary: false) {
            foot.alignCell(toX: cell.convert(cell.bounds, to: foot).minX)
        }
        let clip = scrollView.contentView
        let hiddenBelow = outlineView.frame.height - clip.bounds.maxY > 1
        HelmMotion.withoutActions {
            listFade.frame = scrollView.bounds
            let height = max(scrollView.bounds.height, 1)
            let start = max(0, 1 - Self.listFadeHeight / height)
            // The layer's y runs up in an unflipped scroll view: the fade is
            // at location 0, the list's foot.
            listFade.startPoint = CGPoint(x: 0.5, y: 1)
            listFade.endPoint = CGPoint(x: 0.5, y: 0)
            listFade.locations = [0, NSNumber(value: Double(start)), 1]
            scrollView.layer?.mask = hiddenBelow ? listFade : nil
        }
    }

    /// UX-28: how much of the list's foot fades when it continues.
    static let listFadeHeight: CGFloat = 16

    /// The captain showed or hid a module in Settings: rebuild the rows.
    func setHiddenModules(_ modules: Set<WorkspaceModule>) {
        guard modules != hidden else { return }
        hidden = modules
        guard isViewLoaded else { return }
        rebuild()
    }

    /// The space between the account header and the list's first row.
    static let headerGap: CGFloat = HelmMetrics.s2

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let hiddenObserver { NotificationCenter.default.removeObserver(hiddenObserver) }
    }

    // MARK: What the shell tells it

    /// DevOps Hub's projects changed: repaint its row's badge in place, as
    /// any badge change does. The projects are cards on its page, not rows.
    func reload(projects: [WorkspaceSidebarProject]) {
        self.projects = projects
        guard isViewLoaded else { return }
        let theme = ThemeManager.shared.theme
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? WorkspaceSidebarItem,
                  item.entry == .module(.devopsHub) else { continue }
            let view = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            (view as? WorkspaceSidebarPageCell)?.setBadge(badge(for: .devopsHub), theme: theme)
        }
        refreshSectionBadges()
    }

    /// The sessions changed: rebuild the rows, keeping what the captain
    /// collapsed and the row that is lit.
    func reload(sessions registry: HostSessionRegistry) {
        sessions = registry.sessions
        shortcutIndexByHost = Dictionary(sessions.compactMap { session in
            registry.shortcutIndex(for: session.hostID).map { (session.hostID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        guard isViewLoaded else { return }
        rebuild()
    }

    /// What is showing changed. Lights its row, opening the section (and, for
    /// a session, Connections) it sits in. `pageTab` is the page's own tab, which
    /// lights the Calendar row on Tasks' Calendar view.
    func select(_ kind: RecentDestinationKind?, pageTab: String? = nil) {
        current = kind
        currentPageTab = pageTab
        guard isViewLoaded else { return }
        applySelection()
    }

    /// ⌘⇧D: the sidebar is the whole map, so the keyboard lands in it.
    func focusList() {
        view.window?.makeFirstResponder(outlineView)
    }

    /// What the badges draw from (`WorkspaceSignals`).
    private var signals = WorkspaceSignals()

    /// `module`'s badge. The live-session count goes on the row the sessions
    /// are listed under.
    private func badge(for module: WorkspaceModule) -> WorkspaceBadge? {
        if module == .devopsHub { return WorkspaceSignals.devopsHubBadge(projects) }
        return signals.badge(for: module, sessionsUnder: WorkspaceSidebarModel.sessionsParent(hidden: hidden))
    }

    /// The signals changed: repaint each module row's badge in place, and
    /// each folded section's sum of them.
    func setSignals(_ signals: WorkspaceSignals) {
        self.signals = signals
        guard isViewLoaded else { return }
        let theme = ThemeManager.shared.theme
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? WorkspaceSidebarItem, case .module(let module) = item.entry,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkspaceSidebarPageCell
            else { continue }
            cell.setBadge(badge(for: module), theme: theme)
        }
        refreshSectionBadges()
    }

    /// UI-02 of full review 4: a section's title carries a number only when
    /// it is folded, and then it is what is waiting in the rows it hides.
    /// It used to be the section's row count, drawn where the rows draw
    /// their attention counts, so "WORK 8" read as eight things waiting.
    private func sectionBadge(for item: WorkspaceSidebarItem) -> WorkspaceBadge? {
        guard case .section(let title) = item.entry else { return nil }
        let folded = isViewLoaded && outlineView.row(forItem: item) >= 0 && !outlineView.isItemExpanded(item)
        let badges = item.children.compactMap { child -> WorkspaceBadge? in
            guard case .module(let module) = child.entry else { return nil }
            return badge(for: module)
        }
        return Self.sectionBadge(title: title, folded: folded, rows: badges)
    }

    /// What a section's title draws: nothing while it is open, and the sum
    /// of its rows' waiting counts, as a pill, while it is folded. A
    /// folded section with nothing waiting draws nothing either.
    static func sectionBadge(title: String, folded: Bool, rows: [WorkspaceBadge]) -> WorkspaceBadge? {
        guard folded else { return nil }
        let waiting = rows.filter { $0.waiting > 0 }
        let total = waiting.reduce(0) { $0 + $1.waiting }
        guard total > 0 else { return nil }
        let tone: WorkspaceBadge.Tone = waiting.contains { $0.tone == .alarm } ? .alarm : .attention
        let words = waiting.map(\.description).joined(separator: "; ")
        return WorkspaceBadge(mark: .count("\(total)"), tone: tone,
                              description: "\(total) waiting in \(title): \(words)", waiting: total)
    }

    /// Where the rows' badges end, in the list's own coordinates: a module
    /// cell's trailing edge less the badge's inset. Home, the first row, is
    /// a module row. A section title lines its badge up with it.
    private func rowBadgeEnd() -> CGFloat {
        // The drawn cell when there is one: `frameOfCell` does not narrow
        // for a legacy scroller's track, and the drawn cell does.
        if outlineView.numberOfRows > 0, let cell = outlineView.view(atColumn: 0, row: 0, makeIfNecessary: false) {
            return cell.convert(cell.bounds, to: outlineView).maxX - HelmMetrics.s2
        }
        let rowEnd = outlineView.numberOfRows > 0 ? outlineView.frameOfCell(atColumn: 0, row: 0).maxX
            : outlineView.bounds.width
        return rowEnd - HelmMetrics.s2
    }

    /// Repaint every section title's badge in place - after a fold, an
    /// unfold, or a change to the rows' own badges.
    private func refreshSectionBadges() {
        guard isViewLoaded else { return }
        let theme = ThemeManager.shared.theme
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? WorkspaceSidebarItem, case .section(let title) = item.entry,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkspaceSidebarSectionCell
            else { continue }
            cell.configure(title: title, badge: sectionBadge(for: item), theme: theme)
            cell.badgeEndInList = { [weak self] in self?.rowBadgeEnd() }
        }
    }

    private func rebuild() {
        // A rebuild (a session coming or going, a module shown or hidden)
        // does not change what is lit, so it does not move the list either:
        // it used to scroll to the lit row every time, undoing a scroll the
        // captain had made (R4-BUG-03). The very first build has nothing to
        // keep and reveals the lit row as a navigation does.
        let isFirstBuild = roots.isEmpty
        let origin = scrollView.contentView.bounds.origin
        roots = WorkspaceSidebarModel.roots(sessions: sessions, hidden: hidden)
            .map(WorkspaceSidebarItem.init)
        isApplyingSelection = true
        outlineView.reloadData()
        expandSections()
        isApplyingSelection = false
        applySelection(reveal: isFirstBuild)
        if !isFirstBuild { restoreScroll(to: origin) }
    }

    /// Opens every section not collapsed by hand, and inside them
    /// every module row except the ones they folded.
    private func expandSections() {
        for item in roots where item.isSection {
            guard case .section(let title) = item.entry, !collapsedSections.contains(title) else { continue }
            outlineView.expandItem(item, expandChildren: true)
            for child in item.children {
                if case .module(let module) = child.entry, collapsedModules.contains(module) {
                    outlineView.collapseItem(child)
                }
            }
        }
    }

    /// Puts the list back where it was, or as near as a shorter list allows.
    private func restoreScroll(to origin: NSPoint) {
        let clip = scrollView.contentView
        let furthest = max(0, outlineView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: origin.x, y: min(max(0, origin.y), furthest)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls `row` into sight, except that a list taller than its clip view
    /// by less than one row stays at the top: `scrollRowToVisible` on a
    /// bottom row would lift the whole column by the overflow and push Home
    /// under the header, to show a few more points of a row that is already
    /// mostly in sight (R4-BUG-03).
    ///
    /// R5-UI-09: otherwise the row's section header comes into sight with it,
    /// when the two fit together. At 1100x760 a visit to Settings scrolled
    /// the list to the bottom, and Knowledge was then lit under a "Work"
    /// heading cut in half at the top: `scrollRowToVisible` alone moves only
    /// as far as the row, so wherever the last scroll left the list is where
    /// the top edge cut. A section taller than the list reveals the row
    /// alone, as before.
    private func reveal(row: Int) {
        let clip = scrollView.contentView
        let rect = outlineView.rect(ofRow: row)
        let overflow = outlineView.frame.height - clip.bounds.height
        if overflow > 0, overflow < rect.height, rect.maxY > clip.bounds.height {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 0))
            scrollView.reflectScrolledClipView(clip)
            return
        }
        var target = rect
        if let section = sectionRow(containing: row) {
            let withHeading = rect.union(outlineView.rect(ofRow: section))
            if withHeading.height <= clip.bounds.height { target = withHeading }
        }
        outlineView.scrollToVisible(target)
    }

    /// The row of the section heading `row` sits under, however deep (a
    /// session row is a module's child), or `nil` for a row in no section.
    private func sectionRow(containing row: Int) -> Int? {
        var item = outlineView.item(atRow: row)
        while let parent = outlineView.parent(forItem: item) { item = parent }
        guard let top = item as? WorkspaceSidebarItem, top.isSection else { return nil }
        let sectionRow = outlineView.row(forItem: top)
        return sectionRow >= 0 && sectionRow != row ? sectionRow : nil
    }

    private func applySelection(reveal shouldReveal: Bool = true) {
        foot.setLit(footIsLit, theme: ThemeManager.shared.theme)
        guard let item = item(for: current) else {
            isApplyingSelection = true
            outlineView.deselectAll(nil)
            isApplyingSelection = false
            return
        }
        // Open the section the row sits in, so the lit row is never hidden
        // inside a collapsed one.
        if let parent = outlineView.parent(forItem: item) as? WorkspaceSidebarItem, !outlineView.isItemExpanded(parent) {
            outlineView.expandItem(parent)
            if case .section(let title) = parent.entry { collapsedSections.remove(title) }
        }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        isApplyingSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isApplyingSelection = false
        if shouldReveal { reveal(row: row) }
    }

    /// UX-28: the page showing is the foot's module.
    private var footIsLit: Bool {
        guard case .rail(let destination)? = current else { return false }
        return ModuleTable.sidebarModule(for: destination, pageTab: currentPageTab) == WorkspaceSidebarModel.footModule
    }

    /// The row that stands for `kind`: a session row for a host page,
    /// otherwise the row of the module the page lives in.
    private func item(for kind: RecentDestinationKind?) -> WorkspaceSidebarItem? {
        guard let kind else { return nil }
        let all = roots.flatMap { [$0] + $0.children + $0.children.flatMap(\.children) }
        switch kind {
        case .host(let id, _):
            return all.first { $0.entry == .session(hostID: id) } ?? all.first { $0.entry == .module(.console) }
        case .rail(let destination):
            // A door row the captain hid leaves its view to the module the
            // page lives in, so a row is still lit.
            let module = ModuleTable.sidebarModule(for: destination, pageTab: currentPageTab)
            return all.first { $0.entry == .module(module) }
                ?? all.first { $0.entry == .module(ModuleTable.module(for: destination)) }
        }
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? WorkspaceSidebarItem else { return roots.count }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? WorkspaceSidebarItem else { return roots[index] }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? WorkspaceSidebarItem else { return false }
        return !item.children.isEmpty
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? WorkspaceSidebarItem)?.isSection ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? WorkspaceSidebarItem)?.isSection ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        typealias M = WorkspaceSidebarMetrics
        guard let item = item as? WorkspaceSidebarItem else { return HelmType.scaledRowHeight(M.moduleRowHeight) }
        switch item.entry {
        // A heading never takes Compact's step: 18 is already the floor its
        // 13pt label fits in, so it follows the text scale alone.
        case .section: return max(HelmType.scaledRowHeight(M.sectionRowHeight), HelmType.scaled(M.sectionRowHeight))
        case .module: return HelmType.scaledRowHeight(M.moduleRowHeight)
        case .session: return HelmType.scaledRowHeight(M.sessionRowHeight)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        WorkspaceSidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? WorkspaceSidebarItem else { return nil }
        let theme = ThemeManager.shared.theme
        // A row scrolled into view after the selection settled still has to
        // know whether it is the lit one.
        let lit = outlineView.selectedRowIndexes.contains(outlineView.row(forItem: item))
        switch item.entry {
        case .section(let title):
            let cell = WorkspaceSidebarSectionCell()
            cell.configure(title: title, badge: sectionBadge(for: item), theme: theme)
            cell.badgeEndInList = { [weak self] in self?.rowBadgeEnd() }
            return cell
        case .module(let module):
            let cell = WorkspaceSidebarPageCell()
            cell.configure(symbol: module.symbol, title: module.title, badge: badge(for: module), theme: theme)
            cell.setLit(lit, theme: theme)
            // R2-UX-03: the row says its chord, as a menu item would.
            cell.toolTip = WorkspaceGoMenu.chordText(for: module, hidden: hidden).map { "\(module.title) (\($0))" }
                ?? module.title
            return cell
        case .session(let hostID):
            let cell = WorkspaceSidebarSessionCell()
            if let session = sessions.first(where: { $0.hostID == hostID }) {
                cell.configure(session: session, shortcutIndex: shortcutIndexByHost[hostID], theme: theme)
                cell.setLit(lit, theme: theme)
            }
            return cell
        }
    }

    /// R2-PERF-03: how long a selection the arrow keys made rests before it
    /// navigates - the Finder's own wait before it previews. Holding ↓ from
    /// Home to Settings used to open, and so build, every page on the way.
    static let keyboardSettle: TimeInterval = 0.12
    private var pendingKeyboardActivation: DispatchWorkItem?

    @objc private func rowClicked(_ sender: Any?) {
        guard outlineView.clickStartedOnLitRow else { return }
        let row = outlineView.clickedRow
        guard row >= 0, row == outlineView.selectedRow,
              let item = outlineView.item(atRow: row) as? WorkspaceSidebarItem,
              case .module(let module) = item.entry else { return }
        onReselectModule?(module)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        paintLitRow()
        guard !isApplyingSelection else { return }
        pendingKeyboardActivation?.cancel()
        pendingKeyboardActivation = nil
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? WorkspaceSidebarItem else { return }
        // A click, VoiceOver's press and every other pick navigate at once.
        guard outlineView.isHandlingKeyDown else {
            activate(item)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingKeyboardActivation = nil
            // The shell may have lit another row meanwhile. Only the row the
            // keys left selected navigates.
            guard self.outlineView.selectedRow >= 0,
                  self.outlineView.item(atRow: self.outlineView.selectedRow) as? WorkspaceSidebarItem === item else { return }
            self.activate(item)
        }
        pendingKeyboardActivation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keyboardSettle, execute: work)
    }

    /// Return in the list: open the selected row now rather than after the
    /// settle.
    private func activateSelectionNow() {
        guard let pending = pendingKeyboardActivation else { return }
        pending.cancel()
        pendingKeyboardActivation = nil
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? WorkspaceSidebarItem else { return }
        activate(item)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        refreshRules()
        guard let item = notification.userInfo?["NSObject"] as? WorkspaceSidebarItem else { return }
        switch item.entry {
        case .section(let title):
            collapsedSections.insert(title)
            refreshSectionBadges()
        // A rebuild's own collapse of a folded module is not a fold by hand.
        case .module(let module) where !isApplyingSelection: collapsedModules.insert(module)
        default: break
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        refreshRules()
        guard let item = notification.userInfo?["NSObject"] as? WorkspaceSidebarItem else { return }
        switch item.entry {
        case .section(let title):
            collapsedSections.remove(title)
            refreshSectionBadges()
        case .module(let module) where !isApplyingSelection: collapsedModules.remove(module)
        default: break
        }
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? WorkspaceSidebarRowView)?.showsTopRule = showsRule(atRow: row, selected: outlineView.selectedRow)
    }

    /// Sb-4: the hairline in the ink between two rows, as the hero column
    /// draws it - above a module row that follows another row, and never
    /// beside the lit pill or under a group title.
    private func showsRule(atRow row: Int, selected: Int) -> Bool {
        guard row > 0, row != selected, row - 1 != selected,
              let item = outlineView.item(atRow: row) as? WorkspaceSidebarItem, case .module = item.entry,
              let above = outlineView.item(atRow: row - 1) as? WorkspaceSidebarItem, !above.isSection
        else { return false }
        return true
    }

    /// The rules of every row the list has built: a selection, a collapse or
    /// an expansion moves which rows are neighbours.
    private func refreshRules() {
        let selected = outlineView.selectedRow
        outlineView.enumerateAvailableRowViews { rowView, row in
            (rowView as? WorkspaceSidebarRowView)?.showsTopRule = self.showsRule(atRow: row, selected: selected)
        }
    }

    /// Give the lit row its accent ink and every other row its ordinary ink.
    /// Runs for every selection change, the captain's and the shell's.
    private func paintLitRow() {
        let theme = ThemeManager.shared.theme
        let selected = outlineView.selectedRow
        for row in 0..<outlineView.numberOfRows {
            let view = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            (view as? WorkspaceSidebarPageCell)?.setLit(row == selected, theme: theme)
            (view as? WorkspaceSidebarSessionCell)?.setLit(row == selected, theme: theme)
        }
        refreshRules()
    }

    /// A row was picked - by a click or by the arrow keys, which is what makes
    /// the list keyboard-navigable the way a source list should be.
    private func activate(_ item: WorkspaceSidebarItem) {
        switch item.entry {
        case .section:
            return
        case .module(let module):
            onSelectModule?(module)
        case .session(let hostID):
            onSelectSession?(hostID)
        }
    }

    // MARK: The context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.appearance = WorkspaceSidebarInk.menuAppearance(ThemeManager.shared.theme)
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? WorkspaceSidebarItem else { return }
        switch item.entry {
        case .section:
            return
        case .module(let module):
            menu.addItem(menuItem("Open \(module.title)", symbol: module.symbol) { [weak self] in
                self?.onSelectModule?(module)
            })
            if module == .console || module == .connections {
                menu.addItem(menuItem("Connect to a Host\u{2026}", symbol: "plus.circle") { [weak self] in
                    self?.onConnectHost?()
                })
            }
        case .session(let hostID):
            let label = sessions.first { $0.hostID == hostID }?.label ?? "Session"
            menu.addItem(menuItem("Open \(label)", symbol: "terminal") { [weak self] in
                self?.onSelectSession?(hostID)
            })
            menu.addItem(.separator())
            menu.addItem(menuItem("End Session\u{2026}", symbol: "xmark.circle") { [weak self] in
                self?.onEndSession?(hostID)
            })
        }
    }

    private func menuItem(_ title: String, symbol: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = WorkspaceSidebarMenuItem(title: title, action: #selector(WorkspaceSidebarMenuItem.fire), keyEquivalent: "")
        item.target = item
        item.handler = action
        item.image = HelmSymbol.image(symbol, pointSize: HelmType.scaled(13), weight: .medium)
        return item
    }

    // MARK: The account header

    /// The header's menu: Log Out, and only Log Out (stage 6, the captain's
    /// call). Settings is a sidebar module of its own, and ⌘, and the app
    /// menu still open it, so a second Settings here was the same place
    /// three ways.
    private func accountMenu() -> NSMenu {
        let menu = NSMenu()
        menu.appearance = WorkspaceSidebarInk.menuAppearance(ThemeManager.shared.theme)
        menu.addItem(menuItem("Log Out\u{2026}", symbol: "lock") { [weak self] in self?.onLogOut?() })
        return menu
    }

    private func showAccountMenu() {
        let menu = accountMenu()
        // Just below the header, whichever way its coordinates run.
        let below = header.isFlipped ? header.bounds.maxY + HelmMetrics.s1 : -HelmMetrics.s1
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: header)
    }

    // MARK: Theme

    private func applyTheme(_ theme: HelmTheme) {
        header.applyTheme(theme)
        foot.applyTheme(theme)
        guard isViewLoaded else { return }
        // Sb-4: the gradient, and the gradient's appearance for everything
        // AppKit draws on it - the group disclosure chevron and the scroller.
        let ink = WorkspaceSidebarInk.of(theme)
        surface.apply(ink.palette)
        view.appearance = ink.appearance
        // R2-PERF-02: a theme change repaints the rows it can see, in place,
        // the way `setSignals` repaints a badge. It used to reload the list -
        // twenty cells rebuilt, the hovered row's fill dropped and the list
        // scrolled back to the lit row - on every ⌘-toggle and every sunset
        // under Follow system. GL-24: a theme observer repaints.
        let scale = ChromeTextScale.shared.scale
        let density = HelmDensity.current
        guard scale != builtTextScale || density != builtDensity else {
            repaintRows(theme)
            return
        }
        builtTextScale = scale
        builtDensity = density
        // UX-28: the foot's row is built at a scale too.
        foot.rebuildForScale(theme: theme)
        // GL-32: a text-scale change re-fires the theme too, and that one
        // does rebuild: the row heights and every font follow the scale, and
        // a cell sets its fonts and sizes once, when it is built.
        outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outlineView.numberOfRows))
        isApplyingSelection = true
        outlineView.reloadData()
        expandSections()
        isApplyingSelection = false
        applySelection()
    }

    /// Every row the list has built, in its new colours. A row scrolled into
    /// view later is built with them (`viewFor`), so nothing is missed.
    private func repaintRows(_ theme: HelmTheme) {
        let selected = outlineView.selectedRow
        outlineView.enumerateAvailableRowViews { rowView, row in
            (rowView as? WorkspaceSidebarRowView)?.themeDidChange()
            guard let item = outlineView.item(atRow: row) as? WorkspaceSidebarItem else { return }
            let cell = rowView.numberOfColumns > 0 ? rowView.view(atColumn: 0) : nil
            switch item.entry {
            case .section(let title):
                (cell as? WorkspaceSidebarSectionCell)?.configure(title: title, badge: sectionBadge(for: item),
                                                                  theme: theme)
            case .module(let module):
                (cell as? WorkspaceSidebarPageCell)?.repaint(badge: badge(for: module), lit: row == selected,
                                                             theme: theme)
            case .session(let hostID):
                guard let cell = cell as? WorkspaceSidebarSessionCell,
                      let session = sessions.first(where: { $0.hostID == hostID }) else { return }
                cell.configure(session: session, shortcutIndex: shortcutIndexByHost[hostID], theme: theme)
                cell.setLit(row == selected, theme: theme)
            }
        }
    }

    #if FM_SELFTESTS
    /// What the sidebar draws, top to bottom, as the suite reads it: every
    /// visible row's entry.
    /// The rows the captain can pick, in order: the list's, then the module
    /// pinned to the foot (UX-28), which is always last.
    var debugVisibleEntries: [WorkspaceSidebarEntry] {
        (0..<outlineView.numberOfRows).compactMap { (outlineView.item(atRow: $0) as? WorkspaceSidebarItem)?.entry }
            + [.module(WorkspaceSidebarModel.footModule)]
    }
    /// The lit row's entry, the foot's when it is lit, or nil.
    var debugSelectedEntry: WorkspaceSidebarEntry? {
        if foot.debugIsLit { return .module(WorkspaceSidebarModel.footModule) }
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return (outlineView.item(atRow: row) as? WorkspaceSidebarItem)?.entry
    }
    /// Pick a row the way a click does: select it, which is what fires
    /// `outlineViewSelectionDidChange`.
    func debugClick(_ entry: WorkspaceSidebarEntry) -> Bool {
        if entry == .module(WorkspaceSidebarModel.footModule) { return foot.row.performPrimaryAction() }
        guard let row = (0..<outlineView.numberOfRows).first(where: {
            (outlineView.item(atRow: $0) as? WorkspaceSidebarItem)?.entry == entry
        }) else { return false }
        outlineView.debugClickedRow = row
        defer { outlineView.debugClickedRow = nil }
        outlineView.clickStartedOnLitRow = row == outlineView.selectedRow
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // The table's action follows every click, as it does on mouse-up.
        _ = outlineView.sendAction(outlineView.action, to: outlineView.target)
        return true
    }
    /// The context menu a right-click on `entry` would show.
    func debugContextMenuTitles(for entry: WorkspaceSidebarEntry) -> [String] {
        guard let row = (0..<outlineView.numberOfRows).first(where: {
            (outlineView.item(atRow: $0) as? WorkspaceSidebarItem)?.entry == entry
        }), let menu = outlineView.menu else { return [] }
        outlineView.debugClickedRow = row
        defer { outlineView.debugClickedRow = nil }
        menuNeedsUpdate(menu)
        return menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }
    /// Run a context-menu item by title, through its real target/action.
    func debugPerformContextMenuItem(_ title: String, on entry: WorkspaceSidebarEntry) -> Bool {
        guard let row = (0..<outlineView.numberOfRows).first(where: {
            (outlineView.item(atRow: $0) as? WorkspaceSidebarItem)?.entry == entry
        }), let menu = outlineView.menu else { return false }
        outlineView.debugClickedRow = row
        defer { outlineView.debugClickedRow = nil }
        menuNeedsUpdate(menu)
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else { return false }
        menu.performActionForItem(at: index)
        return true
    }
    var debugHeader: WorkspaceSidebarHeader { header }
    /// Sb-4: the pane's gradient.
    var debugSurface: HelmHeroSurface { surface }
    /// Collapse or expand a group the way its disclosure chevron does.
    func debugSetSection(_ title: String, expanded: Bool) {
        guard let item = roots.first(where: { $0.entry == .section(title) }) else { return }
        if expanded { outlineView.expandItem(item) } else { outlineView.collapseItem(item) }
    }
    /// The cell drawn for `entry`, scrolled into view first - the way the
    /// list draws a row the captain scrolls to.
    /// The drawn height of `entry`'s row, or nil when it has none.
    func debugRowHeight(for entry: WorkspaceSidebarEntry) -> CGFloat? {
        guard let item = (0..<outlineView.numberOfRows).lazy
            .compactMap({ self.outlineView.item(atRow: $0) as? WorkspaceSidebarItem })
            .first(where: { $0.entry == entry }) else { return nil }
        let row = outlineView.row(forItem: item)
        return row >= 0 ? outlineView.rect(ofRow: row).height : nil
    }

    func debugCell(for entry: WorkspaceSidebarEntry) -> NSView? {
        if entry == .module(WorkspaceSidebarModel.footModule) { return foot.debugCell }
        guard let row = (0..<outlineView.numberOfRows).first(where: {
            (outlineView.item(atRow: $0) as? WorkspaceSidebarItem)?.entry == entry
        }) else { return nil }
        outlineView.scrollRowToVisible(row)
        outlineView.layoutSubtreeIfNeeded()
        return outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
    }
    /// The row view drawn for `entry`.
    func debugRowView(for entry: WorkspaceSidebarEntry) -> WorkspaceSidebarRowView? {
        guard let row = (0..<outlineView.numberOfRows).first(where: {
            (outlineView.item(atRow: $0) as? WorkspaceSidebarItem)?.entry == entry
        }) else { return nil }
        return outlineView.rowView(atRow: row, makeIfNecessary: false) as? WorkspaceSidebarRowView
    }

    /// Draw the list's scroller as `style` - a legacy track narrows every
    /// row, the way "Show scroll bars: Always" does (gotcha (4)).
    /// UX-28: the pinned foot, and whether the list's foot is fading.
    var debugFoot: WorkspaceSidebarFoot { foot }
    var debugListFades: Bool { scrollView.layer?.mask === listFade }
    var debugScrollView: NSScrollView { scrollView }

    func debugSetScrollerStyle(_ style: NSScroller.Style) {
        scrollView.scrollerStyle = style
        scrollView.tile()
        view.layoutSubtreeIfNeeded()
    }
    /// The account menu's items, as the header's click would show them.
    var debugAccountMenuTitles: [String] { accountMenu().items.filter { !$0.isSeparatorItem }.map(\.title) }
    /// Run an account-menu item by title, through its real target/action.
    func debugPerformAccountMenuItem(_ title: String) -> Bool {
        let menu = accountMenu()
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else { return false }
        menu.performActionForItem(at: index)
        return true
    }
    #endif
}

/// The outline view, with one seam a suite needs: `clickedRow` is set by
/// AppKit only during a real right-click, so a check of the context menu
/// stands in for it here rather than reimplementing the menu.
///
/// R2-A11Y-01: it also says when the keyboard is in the list. The lit row
/// is drawn by `WorkspaceSidebarRowView`, which suppresses the source list's
/// own emphasised selection - the one cue a stock sidebar gives for focus -
/// so with nothing else the lit row looked the same whether or not the keys
/// would move it. While the list holds the keyboard because a key put it
/// there (⌘⇧D, Tab, Full Keyboard Access - `HelmFocusVisibility`), the lit
/// row wears an accent ring as well as its wash. A mouse click does not
/// light it, and the first arrow key after one does.
final class WorkspaceSidebarOutlineView: NSOutlineView {

    /// Whether the click in flight began on the row that was already lit,
    /// which is the one click that changes no selection
    /// (`WorkspaceSidebarController.rowClicked`).
    var clickStartedOnLitRow = false

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        clickStartedOnLitRow = row >= 0 && row == selectedRow
        super.mouseDown(with: event)
    }
    private(set) var showsKeyboardFocus = false {
        didSet {
            guard showsKeyboardFocus != oldValue else { return }
            enumerateAvailableRowViews { rowView, _ in (rowView as? WorkspaceSidebarRowView)?.refreshFocus() }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { showsKeyboardFocus = HelmFocusVisibility.shouldShowRing }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { showsKeyboardFocus = false }
        return resigned
    }

    // MARK: Cells keep their place beside a disclosure

    /// Where a cell under a section heading starts, past its level's indent.
    /// It is AppKit's own leading for a level with nothing to disclose
    /// (16pt for a module row, measured).
    static let cellLeading: CGFloat = 4

    /// When any row at a level can be expanded (Connections with a live
    /// session), `NSOutlineView` moves every
    /// cell at that level right by the disclosure's width - 9pt, measured - so
    /// every module name loses 9pt, and the longer ones truncate at the
    /// Larger text size. The cells keep their place instead, and the chevron
    /// sits in the leading gutter just before its own row's cell.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        guard let leading = steadyCellLeading(row: row), frame.minX > leading else { return frame }
        frame.size.width += frame.minX - leading
        frame.origin.x = leading
        return frame
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard !frame.isEmpty, let leading = steadyCellLeading(row: row) else { return frame }
        frame.origin.x = max(0, leading - frame.width)
        return frame
    }

    /// The steady leading for `row`, or nil for a section heading or a row at
    /// the top level, which keep AppKit's own frames.
    private func steadyCellLeading(row: Int) -> CGFloat? {
        guard row >= 0, row < numberOfRows, let item = item(atRow: row) as? WorkspaceSidebarItem,
              !item.isSection else { return nil }
        let level = self.level(forRow: row)
        guard level >= 1 else { return nil }
        return CGFloat(level) * indentationPerLevel + Self.cellLeading
    }

    /// R2-PERF-03: true while a key event is being handled, so the
    /// controller can tell a selection the arrow keys made from a click.
    private(set) var isHandlingKeyDown = false
    /// Return or Enter, which open the selected row at once.
    var onReturnKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if window?.firstResponder === self { showsKeyboardFocus = true }
        if event.keyCode == 36 || event.keyCode == 76, let onReturnKey {
            onReturnKey()
            return
        }
        isHandlingKeyDown = true
        defer { isHandlingKeyDown = false }
        super.keyDown(with: event)
    }

    #if FM_SELFTESTS
    var debugClickedRow: Int?
    override var clickedRow: Int { debugClickedRow ?? super.clickedRow }
    /// How many times the list has been reloaded (R2-PERF-02).
    private(set) var debugReloadCount = 0
    override func reloadData() {
        debugReloadCount += 1
        super.reloadData()
    }
    #endif
}

/// A menu item that runs a closure - the sidebar's context menu is rebuilt on
/// every open, so a closure per row is simpler than a selector per verb.
final class WorkspaceSidebarMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

// MARK: - Rows

/// Sb-4: the lit row is a pill in the gradient's ink with its words in the
/// hero's deep colour - `HelmHeroNavRow`'s "white pill" - and a row under the
/// pointer takes the ink at 12%. Both come from `HelmHeroColumn.NavInk`, so
/// the sidebar and the Secrets column beside it draw one idiom. (Before Sb-4
/// the lit row was a 20% accent wash over the system's sidebar material.)
///
/// The pill and the hover fill ease (`HelmRowWash`, the motion table's state
/// row), as the prototype's rows do: the lit row's wash fades across to the
/// new row on a navigation, and a row under the pointer takes a faint ink
/// fill. Neither moves under Reduce Motion, and a rebuild of the rows paints
/// at once: the list builds its row views after the selection is applied, so
/// a new row's first paint is already the lit state (`HelmRowWash`).
final class WorkspaceSidebarRowView: NSTableRowView {
    private let fill: HelmRowWash
    private let rule = NSView()
    private var hovering = false

    /// Sb-4: the hairline in the ink above this row, set by the controller,
    /// which knows the row's neighbours.
    var showsTopRule = false {
        didSet {
            rule.isHidden = !showsTopRule
            paintRule()
        }
    }

    /// The rule's colour. Painted whenever it is shown, not only with the
    /// fill: a row view built after the last theme change is never hovered
    /// or lit before it draws, and its rule came out colourless (measured:
    /// no rules at all after a profile change rebuilt the rows).
    private func paintRule() {
        HelmMotion.withoutActions {
            rule.layer?.backgroundColor = WorkspaceSidebarInk.of(ThemeManager.shared.theme).rule.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        fill = HelmRowWash(frame: .zero)
        super.init(frame: frameRect)
        addSubview(fill, positioned: .below, relativeTo: nil)
        rule.wantsLayer = true
        rule.isHidden = true
        addSubview(rule, positioned: .above, relativeTo: fill)
        // `.inVisibleRect`: AppKit keeps the area matched to the row, so
        // there is no `updateTrackingAreas` bookkeeping per resize.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The wash replaces the drawn selection.
    override func drawSelection(in dirtyRect: NSRect) {}

    /// A source list's selected row also gets the system's selection
    /// material, an `NSVisualEffectView` AppKit adds to the row view. The
    /// pill replaces it, and on the gradient nothing the system blends
    /// should show under or over the pill, so it stays hidden.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview is NSVisualEffectView { subview.isHidden = true }
    }

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { paintFill() } }
    }

    /// R2-A11Y-01: a ring on the lit row while the keyboard is in the list
    /// (`WorkspaceSidebarOutlineView.showsKeyboardFocus`). Sb-4 draws it
    /// inside the pill in the pill's own words colour: an ink ring around an
    /// ink pill would not show.
    private(set) var showsFocusRing = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshFocus()
    }

    func refreshFocus() {
        let outline = sequence(first: superview, next: { $0?.superview })
            .lazy.compactMap { $0 as? WorkspaceSidebarOutlineView }.first
        let focused = isSelected && selectionHighlightStyle != .none && (outline?.showsKeyboardFocus ?? false)
        showsFocusRing = focused
        let theme = ThemeManager.shared.theme
        HelmMotion.withoutActions {
            fill.layer?.borderWidth = focused ? Self.focusRingWidth : 0
            fill.layer?.borderColor = focused ? Self.litInk(theme).cgColor : nil
        }
    }

    static let focusRingWidth: CGFloat = 2

    override func layout() {
        super.layout()
        fill.frame = bounds.insetBy(dx: HelmMetrics.s2, dy: 1)
        // The board's rule runs under the row's words, inset from the pill's
        // edge as `HelmHeroNavRow`'s is.
        let inset = fill.frame.minX + HelmMetrics.s2
        rule.frame = NSRect(x: inset, y: isFlipped ? 0 : bounds.height - 1,
                            width: max(0, bounds.width - 2 * inset), height: 1)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        paintFill()
        groupTitle?.setPointerInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        paintFill()
        groupTitle?.setPointerInside(false)
    }

    /// A group title's cell. The outline view draws a group's disclosure
    /// chevron at the row's trailing edge while the pointer is over it, which
    /// is where the title's count sits.
    private var groupTitle: WorkspaceSidebarSectionCell? {
        guard isGroupRowStyle, numberOfColumns > 0 else { return nil }
        return view(atColumn: 0) as? WorkspaceSidebarSectionCell
    }

    /// The palette changed: the same fill and ring in the new colours, at
    /// once - a theme change is a repaint, not a state change to ease.
    func themeDidChange() {
        paintFill(animated: false)
    }

    /// The lit row's wash, a hovered row's fill, or nothing. A section header
    /// takes no hover: it is a label, not a place.
    private func paintFill(animated: Bool = true) {
        let theme = ThemeManager.shared.theme
        let color: NSColor?
        if isSelected && selectionHighlightStyle != .none {
            color = Self.wash(theme)
        } else if hovering && !isGroupRowStyle {
            color = Self.hover(theme)
        } else {
            color = nil
        }
        fill.paint(color, cornerRadius: WorkspaceSidebarMetrics.pillRadius, animated: animated)
        paintRule()
        refreshFocus()
    }

    /// The lit row's pill: the gradient's ink.
    static func wash(_ theme: HelmTheme) -> NSColor {
        WorkspaceSidebarInk.of(theme).ink
    }

    /// A row under the pointer: the ink at `HelmHeroNavRow.hoverAlpha`, the
    /// same fill the account header above the list takes.
    static func hover(_ theme: HelmTheme) -> NSColor {
        WorkspaceSidebarInk.of(theme).hover
    }

    #if FM_SELFTESTS
    var debugFill: HelmRowWash { fill }
    var debugHovering: Bool { hovering }
    var debugRule: NSView { rule }
    #endif

    /// The lit row's words, glyph and focus ring: the hero's deep colour on
    /// the ink pill (`NavInk.selectedInk`). Set by the controller rather than
    /// left to the source list, which tints a selected row's text with the
    /// *system* accent - measured: blue text on Gruvbox's orange wash.
    static func litInk(_ theme: HelmTheme) -> NSColor {
        WorkspaceSidebarInk.of(theme).selectedInk
    }

    /// Keep the row's text in its ordinary colour on the wash.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A section header: "WORK", "OBSERVE", ... Sb-4 draws it as the hero
/// column's section title: small caps in the quiet ink. UI-02: while the
/// section is folded, what is waiting in its rows sits at the trailing edge
/// in the rows' own badge pill. An open section draws no number, because its
/// rows say it themselves.
final class WorkspaceSidebarSectionCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let badgeView = WorkspaceSidebarBadgeView(height: WorkspaceSidebarMetrics.sectionBadgeHeight)
    private var title = ""
    private var badgeTrailing: NSLayoutConstraint!
    private var pointerInside = false

    /// Where the rows' badges end, in the list's coordinates, so the badge
    /// ends there too. A group row's cell spans a different width from a
    /// module row's (16pt wider at the default width, measured), and the
    /// outline's own frame for it is the module rows' - read from it, the
    /// pill ended 14pt off - so the cell places itself once it is laid out.
    /// Asked at every layout rather than stored: a scroller that appears
    /// ("Show scroll bars: Always", every CI runner) narrows the rows after
    /// the cell was built, and a stored end left the pill 15pt short.
    var badgeEndInList: (() -> CGFloat?)? {
        didSet { needsLayout = true }
    }

    override func layout() {
        if let end = badgeEndInList?(), let list = superview?.superview {
            let inset = max(0, bounds.maxX - convert(NSPoint(x: end, y: 0), from: list).x)
            if abs(badgeTrailing.constant + inset) > 0.25 { badgeTrailing.constant = -inset }
        }
        super.layout()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        // Not the cell's `textField`: a source list restyles a group row's
        // text field in the system's own grey, over the quiet ink (measured
        // in Sb-4's suite).
        addSubview(label)
        addSubview(badgeView)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1),
            // A 2pt foot, so the heading's own height fits the 18pt row.
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s0),
            badgeView.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: HelmMetrics.s2),
            badgeView.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
        badgeTrailing = badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2)
        badgeTrailing.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(title: String, badge: WorkspaceBadge?, theme: HelmTheme) {
        self.title = title
        let quiet = WorkspaceSidebarInk.of(theme).quiet
        label.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: [.font: NSFont.systemFont(ofSize: HelmType.scaled(WorkspaceSidebarMetrics.sectionTextSize),
                                                  weight: .bold),
                         .kern: HelmType.kickerKern, .foregroundColor: quiet])
        badgeView.configure(badge, theme: theme)
        badgeView.isHidden = badge == nil || pointerInside
        // The badge is not an element of its own, so the title says it.
        setAccessibilityLabel(badge.map { "\(title), \($0.description)" } ?? title)
    }

    /// The outline view's disclosure chevron takes the row's trailing edge
    /// while the pointer is over the title, so the badge steps aside for it.
    func setPointerInside(_ inside: Bool) {
        pointerInside = inside
        badgeView.isHidden = badgeView.badge == nil || inside
    }

    #if FM_SELFTESTS
    var debugTitle: String { label.stringValue }
    /// The number the title shows, or nil when it shows none.
    var debugCount: String? { badgeView.isHidden ? nil : badgeView.debugText }
    var debugBadgeView: WorkspaceSidebarBadgeView { badgeView }
    var debugTitleColor: NSColor? {
        label.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
    #endif
}

/// A module: its symbol, its name, and the module's badge on the trailing
/// edge (`WorkspaceSignals.badge`), all in the gradient's ink - or, on the lit
/// row's pill, in the pill's words colour.
final class WorkspaceSidebarPageCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    let badgeView = WorkspaceSidebarBadgeView()
    private var title = ""
    private var badge: WorkspaceBadge?
    private var isLit = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: HelmType.scaled(WorkspaceSidebarMetrics.moduleTextSize),
                                 weight: WorkspaceSidebarMetrics.labelWeight)
        label.lineBreakMode = .byTruncatingTail
        // Gotcha (5): only the title may give way.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        imageView = icon
        textField = label
        for view in [icon, label, badgeView] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: HelmType.scaled(WorkspaceSidebarMetrics.iconSide)),
            icon.heightAnchor.constraint(equalToConstant: HelmType.scaled(WorkspaceSidebarMetrics.iconSide)),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: HelmMetrics.s2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeView.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: HelmMetrics.s1),
            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(symbol: String, title: String, badge: WorkspaceBadge?, theme: HelmTheme) {
        icon.image = HelmSymbol.image(symbol, pointSize: HelmType.scaled(WorkspaceSidebarMetrics.symbolPointSize),
                                      weight: .medium)
        self.title = title
        label.stringValue = title
        self.badge = badge
        setLit(false, theme: theme)
    }

    /// The badge alone, in place - a signal changing repaints one row's
    /// trailing edge, never the list.
    func setBadge(_ badge: WorkspaceBadge?, theme: HelmTheme) {
        self.badge = badge
        badgeView.configure(badge, theme: theme, onPill: isLit)
        // VoiceOver hears the module and then what its badge says.
        setAccessibilityLabel(badge.map { "\(title), \($0.description)" } ?? title)
    }

    /// The row's words and glyph: the ink, or the pill's words on the lit
    /// row. The badge follows, since a mark on the pill is drawn for the pill.
    func setLit(_ lit: Bool, theme: HelmTheme) {
        isLit = lit
        let ink = WorkspaceSidebarInk.of(theme)
        let words = lit ? ink.selectedInk : ink.ink
        label.textColor = words
        icon.contentTintColor = words
        setBadge(badge, theme: theme)
    }

    /// R2-PERF-02: the colours of a built row, for a theme change. The
    /// symbol image and the title stay, and only what the palette decides moves.
    func repaint(badge: WorkspaceBadge?, lit: Bool, theme: HelmTheme) {
        self.badge = badge
        setLit(lit, theme: theme)
    }

    #if FM_SELFTESTS
    var debugTitle: String { label.stringValue }
    var debugBadge: WorkspaceBadge? { badgeView.badge }
    var debugIconTint: NSColor? { icon.contentTintColor }
    var debugLabelColor: NSColor? { label.textColor }
    var debugLabel: NSTextField { label }
    var debugIcon: NSImageView { icon }
    #endif
}

/// A module row's badge: a count, a dot or a symbol, in the gradient's ink
/// (Sb-4). A quiet count is the quiet ink, as the board draws Tasks' and
/// Setup's; one that needs attention (Crew's) is a pill with its digits in
/// the ink (`NavInk.countPill`). A dot or a glyph that says something is wrong
/// keeps its state hue, lifted until it reads on the gradient
/// (`NavInk.signal`). On the lit row's pill every one of them takes the
/// pill's words colour instead. Hidden, not empty, when there is nothing to
/// say - an empty pill reads as a zero (GL-14).
final class WorkspaceSidebarBadgeView: NSView {
    static let height: CGFloat = WorkspaceSidebarMetrics.badgeHeight
    /// This badge's own height: a row's, or a section title's smaller pill.
    private let pillHeight: CGFloat

    private let label = NSTextField(labelWithString: "")
    private let symbol = NSImageView()
    private let dot = NSView()
    private var labelInset: [NSLayoutConstraint] = []
    private(set) var badge: WorkspaceBadge?

    convenience init() { self.init(height: Self.height) }

    override convenience init(frame frameRect: NSRect) {
        self.init(height: Self.height)
        frame = frameRect
    }

    init(height: CGFloat) {
        pillHeight = height
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        label.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(WorkspaceSidebarMetrics.badgeTextSize),
                                                weight: .regular)
        label.alignment = .center
        symbol.imageScaling = .scaleProportionallyDown
        dot.wantsLayer = true
        dot.layer?.cornerRadius = WorkspaceSidebarSessionCell.dotSide / 2
        for view in [label, symbol, dot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        labelInset = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
        ]
        NSLayoutConstraint.activate(labelInset + [
            heightAnchor.constraint(equalToConstant: pillHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: WorkspaceSidebarSessionCell.dotSide),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: HelmType.scaled(WorkspaceSidebarMetrics.badgeSymbolSide)),
            symbol.heightAnchor.constraint(equalToConstant: HelmType.scaled(WorkspaceSidebarMetrics.badgeSymbolSide)),
            symbol.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: WorkspaceSidebarSessionCell.dotSide),
            dot.heightAnchor.constraint(equalToConstant: WorkspaceSidebarSessionCell.dotSide),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The row carries the words; the badge is their picture.
        setAccessibilityElement(false)
        configure(nil, theme: ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ badge: WorkspaceBadge?, theme: HelmTheme, onPill: Bool = false) {
        self.badge = badge
        isHidden = badge == nil
        toolTip = badge?.description
        label.isHidden = true
        symbol.isHidden = true
        dot.isHidden = true
        layer?.backgroundColor = nil
        guard let badge else { return }
        let ink = WorkspaceSidebarInk.of(theme)
        let words = onPill ? ink.selectedInk : ink.ink
        switch badge.mark {
        case .count(let text):
            label.isHidden = false
            label.stringValue = text
            let pill = badge.tone != .neutral
            let inset = pill ? HelmMetrics.s2 - 2 : 0
            labelInset[0].constant = inset
            labelInset[1].constant = -inset
            let size = HelmType.scaled(WorkspaceSidebarMetrics.badgeTextSize)
            if pill {
                layer?.backgroundColor = Self.pillFill(theme: theme, onPill: onPill).cgColor
                label.textColor = words
                label.font = .monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            } else {
                label.textColor = words.withAlphaComponent(HelmHeroColumn.quietInkAlpha)
                label.font = .monospacedDigitSystemFont(ofSize: size, weight: .medium)
            }
        case .dot:
            dot.isHidden = false
            dot.layer?.backgroundColor = Self.ink(for: badge.tone, theme: theme, onPill: onPill).cgColor
        case .symbol(let name):
            symbol.isHidden = false
            symbol.image = HelmSymbol.image(name, pointSize: HelmType.scaled(WorkspaceSidebarMetrics.badgeTextSize),
                                            weight: .semibold)
            symbol.contentTintColor = Self.ink(for: badge.tone, theme: theme, onPill: onPill)
        }
    }

    /// A tone as a mark on the gradient, or on the lit row's pill: the quiet
    /// ink for a neutral one, and otherwise the state hue lifted until it
    /// clears the non-text floor there (a dot or a glyph that says "failing"
    /// is read like a word).
    static func ink(for tone: WorkspaceBadge.Tone, theme: HelmTheme, onPill: Bool = false) -> NSColor {
        let ink = WorkspaceSidebarInk.of(theme)
        switch tone {
        case .neutral:
            return (onPill ? ink.selectedInk : ink.ink).withAlphaComponent(HelmHeroColumn.quietInkAlpha)
        case .attention: return ink.signal(tintHex: HelmTint.warn.hex(in: theme), selected: onPill)
        case .alarm: return ink.signal(tintHex: HelmTint.critical.hex(in: theme), selected: onPill)
        }
    }

    /// The attention pill's fill (`NavInk.countPill`).
    static func pillFill(theme: HelmTheme, onPill: Bool = false) -> NSColor {
        WorkspaceSidebarInk.of(theme).countPill(selected: onPill)
    }

    #if FM_SELFTESTS
    var debugText: String? { label.isHidden ? nil : label.stringValue }
    var debugTextColor: NSColor? { label.isHidden ? nil : label.textColor }
    var debugFill: NSColor? { layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
    var debugMarkColor: NSColor? {
        if !dot.isHidden { return dot.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
        if !symbol.isHidden { return symbol.contentTintColor }
        return nil
    }
    #endif
}

/// A live session under Connections: a state dot, the host's label, and its
/// ⌃⌘ shortcut, in the gradient's ink. The dot keeps the good hue, lifted to
/// read on the gradient, while the session is connected.
final class WorkspaceSidebarSessionCell: NSTableCellView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private var isLive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: HelmType.scaled(WorkspaceSidebarMetrics.sessionTextSize),
                                 weight: WorkspaceSidebarMetrics.labelWeight)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        shortcut.font = .systemFont(ofSize: HelmType.scaled(WorkspaceSidebarMetrics.shortcutTextSize))
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        textField = label
        for view in [dot, label, shortcut] { addSubview(view) }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1 + 1),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: HelmMetrics.s2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: HelmMetrics.s1),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static let dotSide: CGFloat = 7

    /// The words, the shortcut and the dot, on the gradient or on the lit
    /// row's pill.
    func setLit(_ lit: Bool, theme: HelmTheme) {
        let ink = WorkspaceSidebarInk.of(theme)
        let words = lit ? ink.selectedInk : ink.ink
        label.textColor = words
        shortcut.textColor = words.withAlphaComponent(HelmHeroColumn.quietInkAlpha)
        // Connected reads as the good hue; a restored page that has not
        // started reads as the ink at half strength, never as live - the
        // registry's own rule.
        let colour = isLive ? ink.signal(tintHex: HelmTint.good.hex(in: theme), selected: lit)
            : words.withAlphaComponent(Self.idleDotAlpha)
        dot.layer?.backgroundColor = colour.cgColor
    }

    static let idleDotAlpha: CGFloat = 0.5

    func configure(session: HostSession, shortcutIndex: Int?, theme: HelmTheme) {
        isLive = session.isConnected
        setLit(false, theme: theme)
        label.stringValue = session.label
        shortcut.stringValue = shortcutIndex.map { "\u{2303}\u{2318}\($0)" } ?? ""
        toolTip = "\(session.label) \u{00B7} \(session.stateText)"
        setAccessibilityLabel("\(session.label), \(session.stateText)")
    }

    #if FM_SELFTESTS
    var debugTitle: String { label.stringValue }
    var debugShortcut: String { shortcut.stringValue }
    var debugLabelColor: NSColor? { label.textColor }
    var debugDotColor: NSColor? { dot.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
    #endif
}

// MARK: - The account header

/// The top of the sidebar: the app's tile and name over this Mac, and the
/// account menu (Log Out) that the floating bar keeps behind its avatar.
///
/// Sb-4: it sits in the gradient's ink. The tile is the hero's translucent
/// glyph tile (the ink at 22% under the sailboat) rather than a gradient
/// tile, which would be a gradient on the gradient.
final class WorkspaceSidebarHeader: HoverHighlightView {
    private let tile = NSView()
    private let tileGlyph = NSImageView()
    private let title = NSTextField(labelWithString: AppPaths.displayName)
    private let subtitle = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cornerRadius = HelmMetrics.rChip + 3
        // R2-A11Y-03: it opens a menu, so it is a menu button, and the menu
        // holds Log Out and nothing else, so the label names that rather
        // than promising an account menu. The app's name stays first because
        // it is the text on screen.
        accessibilityRoleOverride = .menuButton
        accessibilityLabelOverride = Self.accessibilityLabel
        toolTip = "Log Out"

        tile.wantsLayer = true
        tile.layer?.cornerRadius = Self.tileRadius
        tile.translatesAutoresizingMaskIntoConstraints = false
        tileGlyph.image = HelmSymbol.image("sailboat.fill", pointSize: HelmType.scaled(14), weight: .semibold)
        tileGlyph.imageScaling = .scaleNone
        tileGlyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(tileGlyph)
        title.font = .systemFont(ofSize: HelmType.scaled(15), weight: .bold)
        title.lineBreakMode = .byTruncatingTail
        subtitle.stringValue = "This Mac \u{00B7} \(NSUserName())"
        subtitle.font = .systemFont(ofSize: HelmType.scaled(12))
        subtitle.lineBreakMode = .byTruncatingTail
        for label in [title, subtitle] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        chevron.image = HelmSymbol.image("chevron.up.chevron.down", pointSize: HelmType.scaled(11), weight: .medium)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.translatesAutoresizingMaskIntoConstraints = false
        for view in [tile, text, chevron] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: Self.tileSide),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSide),
            tileGlyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            tileGlyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HelmMetrics.s2 + 1),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: HelmMetrics.s1),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // GL-16: the click recognizer is also what Return, Space and
        // VoiceOver's press reach, through `performPrimaryAction`.
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static let height: CGFloat = 46
    static let tileSide: CGFloat = 30
    static let tileRadius: CGFloat = 10

    /// What VoiceOver reads before "menu button".
    static let accessibilityLabel = "\(AppPaths.displayName), Log Out"

    @objc private func clicked() { onClick?() }

    func applyTheme(_ theme: HelmTheme) {
        let ink = WorkspaceSidebarInk.of(theme)
        title.textColor = ink.ink
        subtitle.textColor = ink.ink.withAlphaComponent(Self.secondaryAlpha)
        chevron.contentTintColor = ink.ink.withAlphaComponent(Self.secondaryAlpha)
        tile.layer?.backgroundColor = ink.ink.withAlphaComponent(Self.tileFillAlpha).cgColor
        tileGlyph.contentTintColor = ink.ink
        hoverColor = ink.hover
    }

    /// The board's header: "This Mac · manjesh" and the chevron at 85% of the
    /// ink, the tile's fill at 22%.
    static let secondaryAlpha: CGFloat = 0.85
    static let tileFillAlpha: CGFloat = 0.22

    #if FM_SELFTESTS
    var debugTitle: String { title.stringValue }
    var debugSubtitle: String { subtitle.stringValue }
    var debugTitleColor: NSColor? { title.textColor }
    var debugSubtitleColor: NSColor? { subtitle.textColor }
    #endif
}

/// UX-28: the sidebar's foot - a hairline in the ink, then Settings as a row
/// that never scrolls away. The row is the list's own page cell (its glyph,
/// its words, its size), lit as the list lights a row: the ink as a pill with
/// the pill's words. The row is a `HoverHighlightView`, so it is a button to
/// VoiceOver, draws a focus ring and takes Return and Space (GL-16).
final class WorkspaceSidebarFoot: NSView {
    private let rule = NSView()
    private var cell = WorkspaceSidebarPageCell()
    let row = HoverHighlightView()
    private var rowHeight: NSLayoutConstraint?
    private var isLit = false
    var onClick: (() -> Void)?
    private lazy var cellLeading = cell.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: HelmMetrics.s1)

    /// Line the glyph up with the list's glyphs: `x` is where a listed row's
    /// cell starts, in this view's coordinates. The list's own indent comes
    /// from the outline view's level indentation and row insets, so it is
    /// read rather than restated.
    func alignCell(toX x: CGFloat) {
        let constant = max(0, x)
        guard abs(cellLeading.constant - constant) > 0.25 else { return }
        cellLeading.constant = constant
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let module = WorkspaceSidebarModel.footModule
        row.cornerRadius = WorkspaceSidebarMetrics.pillRadius
        row.accessibilityRoleOverride = .button
        row.accessibilityLabelOverride = module.title
        row.toolTip = WorkspaceGoMenu.chordText(for: module).map { "\(module.title) (\($0))" } ?? module.title
        rule.wantsLayer = true
        for view in [rule, row, cell] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        cell.configure(symbol: module.symbol, title: module.title, badge: nil, theme: ThemeManager.shared.theme)
        addSubview(rule)
        addSubview(row)
        row.addSubview(cell)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            // The list's own rules start under the glyphs.
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s1),
            rule.heightAnchor.constraint(equalToConstant: 1),
            row.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: HelmMetrics.s1),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        pinCell()
        let height = row.heightAnchor.constraint(equalToConstant: HelmType.scaledRowHeight(WorkspaceSidebarMetrics.moduleRowHeight))
        height.isActive = true
        rowHeight = height
        // GL-16: the click recognizer is also what Return, Space and
        // VoiceOver's press reach, through `performPrimaryAction`.
        row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    private func pinCell() {
        cellLeading = cell.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: cellLeading.constant)
        NSLayoutConstraint.activate([
            cell.topAnchor.constraint(equalTo: row.topAnchor),
            cell.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            cellLeading,
            cell.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
    }

    /// GL-32: a text-scale or density change rebuilds the row, as it
    /// rebuilds the list's rows - a cell sets its fonts and sizes once.
    func rebuildForScale(theme: HelmTheme) {
        let module = WorkspaceSidebarModel.footModule
        cell.removeFromSuperview()
        cell = WorkspaceSidebarPageCell()
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.configure(symbol: module.symbol, title: module.title, badge: nil, theme: theme)
        row.addSubview(cell)
        pinCell()
        rowHeight?.constant = HelmType.scaledRowHeight(WorkspaceSidebarMetrics.moduleRowHeight)
        applyTheme(theme)
    }

    func setLit(_ lit: Bool, theme: HelmTheme) {
        isLit = lit
        row.accessibilityValueOverride = lit ? "selected" : nil
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        let ink = WorkspaceSidebarInk.of(theme)
        rule.layer?.backgroundColor = ink.rule.cgColor
        cell.setLit(isLit, theme: theme)
        row.normalColor = isLit ? ink.ink : .clear
        row.hoverColor = isLit ? ink.ink : ink.hover
    }

    #if FM_SELFTESTS
    var debugIsLit: Bool { isLit }
    var debugCell: WorkspaceSidebarPageCell { cell }
    #endif
}
