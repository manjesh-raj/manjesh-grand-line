// Grand Line - native macOS app.
//
// The sidebar shell's sidebar (stages 3 and 4 of the modular-shell migration,
// full review section 5.8): a source list over the module table, hosted in the
// split view's sidebar item.
//
// It lists Home and the seventeen modules under the four groups the module
// table assigns (Work, Observe, Workbench, Machine), the captain's quick-access
// pins in a Pinned section, and the live host sessions as children of Console.
// A module's pages are its tabs in the window toolbar, so every one of the 29
// destinations is one click on its module and one on its tab; a pin keeps a
// page itself one click away.
//
// Two halves, the same split the rest of this app uses:
//
//   - `WorkspaceSidebarModel` - which rows exist, in what order. Pure logic,
//     read straight off `ModuleTable`, `QuickAccessConfiguration` and the
//     session registry, and asserted headless by `SplitShellModelSelfTest`.
//   - `WorkspaceSidebarController` - the `NSOutlineView` that draws them, the
//     account header above it, and the context menus.
//
// The sidebar draws state, it does not navigate: a click is forwarded to the
// shell, which routes through the `Navigator` like every other entry point,
// and the row is lit from what the workspace reports is showing.

import AppKit

/// One row of the sidebar.
enum WorkspaceSidebarEntry: Equatable {
    /// A section header: "Pinned", or one of the four groups.
    case section(String)
    /// Home, or one of the seventeen modules.
    case module(WorkspaceModule)
    /// A pinned page, in the Pinned section.
    case pinned(RailDestination)
    /// A live host session, a child of Console.
    case session(hostID: UUID)
}

/// Which rows the sidebar shows, in order.
enum WorkspaceSidebarModel {

    struct Node: Equatable {
        let entry: WorkspaceSidebarEntry
        var children: [Node] = []
    }

    static let pinnedTitle = "Pinned"

    /// The sidebar's top level: Home, the Pinned section (when a pin needs
    /// one), then the four groups.
    ///
    /// The Pinned section lists only the pins that are one of several pages
    /// in their module - Straw Hat Pirates inside Crew, Hosts inside
    /// Connections - because a page that is its module's only page already
    /// has a row of its own here, and listing it twice was most of the
    /// section (four of the floating bar's seven default pins). The pins
    /// themselves are unchanged: the floating bar still draws every one.
    static func roots(pinned: [RailDestination], sessions: [HostSession]) -> [Node] {
        var roots = [Node(entry: .module(.home))]
        let nested = pinned.filter(\.isNestedInItsModule)
        if !nested.isEmpty {
            roots.append(Node(entry: .section(pinnedTitle), children: nested.map { Node(entry: .pinned($0)) }))
        }
        for group in WorkspaceGroup.allCases {
            let rows = modules(in: group).map { module -> Node in
                guard module == .console else { return Node(entry: .module(module)) }
                return Node(entry: .module(.console), children: sessions.map { Node(entry: .session(hostID: $0.hostID)) })
            }
            roots.append(Node(entry: .section(group.title), children: rows))
        }
        return roots
    }

    /// The modules in `group`, in the module table's sidebar order.
    static func modules(in group: WorkspaceGroup) -> [WorkspaceModule] {
        WorkspaceModule.allCases.filter { $0.group == group }
    }

    /// Every module the sidebar lists once, outside the Pinned section - the
    /// completeness `SplitShellModelSelfTest` asserts against the module table.
    static func listedModules() -> [WorkspaceModule] {
        [.home] + WorkspaceGroup.allCases.flatMap(modules(in:))
    }
}

extension WorkspaceModule {
    /// The page a module opens on the first time: its first tab, or its one
    /// page.
    var primaryRoute: RailDestination {
        tabs.first?.route ?? ModuleTable.routes(in: self).first ?? .homeCanvas
    }

    /// The module's pages, each once, in tab order: what its row offers to pin
    /// when it has more than one.
    var pages: [RailDestination] {
        let fromTabs = tabs.map(\.route)
        let ordered = fromTabs + ModuleTable.routes(in: self).filter { !fromTabs.contains($0) }
        return ordered.enumerated().filter { index, route in ordered.firstIndex(of: route) == index }.map(\.element)
    }
}

extension RailDestination {
    /// Whether this page is one of several in its module, so a pin is the
    /// only way to reach it in one click from the sidebar.
    var isNestedInItsModule: Bool { ModuleTable.module(for: self).pages.count > 1 }
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
    var onSelectDestination: ((RailDestination) -> Void)?
    var onSelectSession: ((UUID) -> Void)?
    var onEndSession: ((UUID) -> Void)?
    var onConnectHost: (() -> Void)?
    var onTogglePin: ((RailDestination) -> Void)?
    var isPinned: ((RailDestination) -> Bool)?
    var onOpenSettings: (() -> Void)?
    var onLogOut: (() -> Void)?

    let outlineView = WorkspaceSidebarOutlineView()
    private let scrollView = NSScrollView()
    private let header = WorkspaceSidebarHeader()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace.sidebar.column"))

    private var roots: [WorkspaceSidebarItem] = []
    private var sessions: [HostSession] = []
    private var shortcutIndexByHost: [UUID: Int] = [:]
    /// Section titles the captain collapsed, so a rebuild (a session coming
    /// or going) keeps them collapsed. In memory only: like the window's own
    /// sidebar width, it is not worth a preference.
    private var collapsedSections: Set<String> = []
    /// What the workspace last said is showing, so a rebuild can light the
    /// same row again.
    private var current: RecentDestinationKind?
    /// Whether the lit row is a page's Pinned copy: true when the captain
    /// picked it from the Pinned section, so that row stays lit rather than
    /// the highlight jumping to the page's module a moment after the click.
    private var currentIsFromPinned = false
    /// The pinned page the captain just picked, until the navigation it
    /// causes comes back through `select(_:)`.
    private var pendingPinnedPick: RailDestination?
    /// Guards the programmatic selection that lights a row, so it is never
    /// mistaken for the captain picking one.
    private var isApplyingSelection = false
    private var themeToken: ThemeObservation?

    // MARK: Build

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 236, height: 600))
        view = root

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
        outlineView.setAccessibilityLabel("Sidebar")
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            // The window's traffic lights and the sidebar toggle sit in the
            // title bar over this column, so the header starts below it.
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: HelmMetrics.s1),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s2),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s2),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s1),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        rebuild()
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    // MARK: What the shell tells it

    /// The pins or the sessions changed: rebuild the rows, keeping what the
    /// captain collapsed and the row that is lit.
    func reload(pinned: [RailDestination], sessions registry: HostSessionRegistry) {
        sessions = registry.sessions
        shortcutIndexByHost = Dictionary(sessions.compactMap { session in
            registry.shortcutIndex(for: session.hostID).map { (session.hostID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        pinnedCache = pinned
        guard isViewLoaded else { return }
        rebuild()
    }

    /// What is showing changed. Lights its row, opening the section (and, for
    /// a session, Console) it sits in.
    func select(_ kind: RecentDestinationKind?) {
        if let pendingPinnedPick, kind == .rail(pendingPinnedPick) {
            currentIsFromPinned = true
        } else if kind?.identityKey != current?.identityKey {
            currentIsFromPinned = false
        }
        pendingPinnedPick = nil
        current = kind
        guard isViewLoaded else { return }
        applySelection()
    }

    /// ⌘⇧D: the sidebar is the whole map, so the keyboard lands in it.
    func focusList() {
        view.window?.makeFirstResponder(outlineView)
    }

    private var pinnedCache: [RailDestination] = AppSettings.shared.quickAccess.pinned

    private func rebuild() {
        roots = WorkspaceSidebarModel.roots(pinned: pinnedCache, sessions: sessions).map(WorkspaceSidebarItem.init)
        isApplyingSelection = true
        outlineView.reloadData()
        for item in roots where item.isSection {
            if case .section(let title) = item.entry, !collapsedSections.contains(title) {
                outlineView.expandItem(item, expandChildren: true)
            }
        }
        isApplyingSelection = false
        applySelection()
    }

    private func applySelection() {
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
        outlineView.scrollRowToVisible(row)
    }

    /// The row that stands for `kind`: a session row for a host page, the
    /// Pinned copy when the captain picked it from there, otherwise the row of
    /// the module the page lives in.
    private func item(for kind: RecentDestinationKind?) -> WorkspaceSidebarItem? {
        guard let kind else { return nil }
        let all = roots.flatMap { [$0] + $0.children + $0.children.flatMap(\.children) }
        switch kind {
        case .host(let id, _):
            return all.first { $0.entry == .session(hostID: id) } ?? all.first { $0.entry == .module(.console) }
        case .rail(let destination):
            if currentIsFromPinned, let pinned = all.first(where: { $0.entry == .pinned(destination) }) {
                return pinned
            }
            return all.first { $0.entry == .module(ModuleTable.module(for: destination)) }
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
        guard let item = item as? WorkspaceSidebarItem else { return HelmType.scaledRowHeight(28) }
        switch item.entry {
        case .section: return HelmType.scaledRowHeight(30)
        case .module, .pinned: return HelmType.scaledRowHeight(28)
        case .session: return HelmType.scaledRowHeight(26)
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
            cell.configure(title: title, theme: theme)
            return cell
        case .module(let module):
            let cell = WorkspaceSidebarPageCell()
            let liveCount = module == .console ? sessions.filter(\.isConnected).count : 0
            cell.configure(symbol: module.symbol, title: module.title,
                           trailing: liveCount > 0 ? "\(liveCount)" : nil,
                           trailingHelp: liveCount > 0 ? "\(liveCount) connected" : nil,
                           theme: theme)
            cell.setLit(lit, theme: theme)
            return cell
        case .pinned(let destination):
            let cell = WorkspaceSidebarPageCell()
            cell.configure(symbol: destination.symbol, title: destination.title, trailing: nil, trailingHelp: nil,
                           theme: theme)
            cell.setLit(lit, theme: theme)
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

    func outlineViewSelectionDidChange(_ notification: Notification) {
        paintLitRow()
        guard !isApplyingSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? WorkspaceSidebarItem else { return }
        activate(item)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? WorkspaceSidebarItem,
              case .section(let title) = item.entry else { return }
        collapsedSections.insert(title)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? WorkspaceSidebarItem,
              case .section(let title) = item.entry else { return }
        collapsedSections.remove(title)
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
    }

    /// A row was picked - by a click or by the arrow keys, which is what makes
    /// the list keyboard-navigable the way a source list should be.
    private func activate(_ item: WorkspaceSidebarItem) {
        switch item.entry {
        case .section:
            return
        case .module(let module):
            pendingPinnedPick = nil
            onSelectModule?(module)
        case .pinned(let destination):
            pendingPinnedPick = destination
            onSelectDestination?(destination)
        case .session(let hostID):
            pendingPinnedPick = nil
            onSelectSession?(hostID)
        }
    }

    // MARK: The context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? WorkspaceSidebarItem else { return }
        switch item.entry {
        case .section:
            return
        case .module(let module):
            menu.addItem(menuItem("Open \(module.title)", symbol: module.symbol) { [weak self] in
                self?.onSelectModule?(module)
            })
            if module == .console {
                menu.addItem(menuItem("Connect to a Host\u{2026}", symbol: "plus.circle") { [weak self] in
                    self?.onConnectHost?()
                })
            }
            // The quick-access pins, edited where they are drawn - the
            // floating bar's ⌘⇧D map offered the same two verbs - for each
            // page a module holds several of. A module that is one page is
            // already its own row.
            guard module.pages.count > 1 else { return }
            menu.addItem(.separator())
            for destination in module.pages {
                addPinItem(for: destination, to: menu)
            }
        case .pinned(let destination):
            menu.addItem(menuItem("Open \(destination.title)", symbol: destination.symbol) { [weak self] in
                self?.onSelectDestination?(destination)
            })
            menu.addItem(.separator())
            addPinItem(for: destination, to: menu)
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

    private func addPinItem(for destination: RailDestination, to menu: NSMenu) {
        let pinned = isPinned?(destination) ?? false
        let title = pinned ? "Unpin \(destination.title) from Sidebar" : "Pin \(destination.title) to Sidebar"
        menu.addItem(menuItem(title, symbol: pinned ? "pin.slash" : "pin") { [weak self] in
            self?.onTogglePin?(destination)
        })
    }

    private func menuItem(_ title: String, symbol: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = WorkspaceSidebarMenuItem(title: title, action: #selector(WorkspaceSidebarMenuItem.fire), keyEquivalent: "")
        item.target = item
        item.handler = action
        item.image = HelmSymbol.image(symbol, pointSize: HelmType.scaled(13), weight: .medium)
        return item
    }

    // MARK: The account header

    private func showAccountMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem("Settings\u{2026}", symbol: "gearshape") { [weak self] in self?.onOpenSettings?() })
        menu.addItem(.separator())
        menu.addItem(menuItem("Log Out\u{2026}", symbol: "lock") { [weak self] in self?.onLogOut?() })
        // Just below the header, whichever way its coordinates run.
        let below = header.isFlipped ? header.bounds.maxY + HelmMetrics.s1 : -HelmMetrics.s1
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: header)
    }

    // MARK: Theme

    private func applyTheme(_ theme: HelmTheme) {
        header.applyTheme(theme)
        guard isViewLoaded else { return }
        // GL-32: the row heights follow the chrome text scale.
        outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outlineView.numberOfRows))
        // A theme observer repaints - it never fetches (GL-24). Every cell
        // reads the theme when it is built, so a reload is the repaint.
        isApplyingSelection = true
        outlineView.reloadData()
        for item in roots where item.isSection {
            if case .section(let title) = item.entry, !collapsedSections.contains(title) {
                outlineView.expandItem(item, expandChildren: true)
            }
        }
        isApplyingSelection = false
        applySelection()
    }

    #if FM_SELFTESTS
    /// What the sidebar draws, top to bottom, as the suite reads it: every
    /// visible row's entry.
    var debugVisibleEntries: [WorkspaceSidebarEntry] {
        (0..<outlineView.numberOfRows).compactMap { (outlineView.item(atRow: $0) as? WorkspaceSidebarItem)?.entry }
    }
    /// The lit row's entry, or nil.
    var debugSelectedEntry: WorkspaceSidebarEntry? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return (outlineView.item(atRow: row) as? WorkspaceSidebarItem)?.entry
    }
    /// Pick a row the way a click does: select it, which is what fires
    /// `outlineViewSelectionDidChange`.
    func debugClick(_ entry: WorkspaceSidebarEntry) -> Bool {
        guard let row = (0..<outlineView.numberOfRows).first(where: {
            (outlineView.item(atRow: $0) as? WorkspaceSidebarItem)?.entry == entry
        }) else { return false }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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
    #endif
}

/// The outline view, with one seam a suite needs: `clickedRow` is set by
/// AppKit only during a real right-click, so a check of the context menu
/// stands in for it here rather than reimplementing the menu.
final class WorkspaceSidebarOutlineView: NSOutlineView {
    #if FM_SELFTESTS
    var debugClickedRow: Int?
    override var clickedRow: Int { debugClickedRow ?? super.clickedRow }
    #endif
}

/// A menu item that runs a closure - the sidebar's context menu is rebuilt on
/// every open, so a closure per row is simpler than a selector per verb.
final class WorkspaceSidebarMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

// MARK: - Rows

/// The lit row is a soft accent wash, as the prototype draws it, rather than
/// the system's solid selection with white text - the sidebar is the app's
/// map, and the current page should read as "here", not as a selected
/// object. It is the same wash, and the same corrected accent ink, that a
/// page's own column (`HelmPageSidebar`) gives its selected row, so the two
/// sidebars side by side on Tasks or Settings read as one idiom.
final class WorkspaceSidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: HelmMetrics.s2, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: HelmMetrics.rChip + 1, yRadius: HelmMetrics.rChip + 1)
        Self.wash(ThemeManager.shared.theme).setFill()
        path.fill()
    }

    static func wash(_ theme: HelmTheme) -> NSColor {
        HelmTheme.nsColor(theme.accentHex).withAlphaComponent(HelmAccentRow.selectionWash)
    }

    /// The lit row's label: the accent, corrected until it clears the text
    /// floor on the wash over the sidebar's own fill. Set by the controller
    /// rather than left to the source list, which tints a selected row's
    /// text with the *system* accent - measured: blue text on Gruvbox's
    /// orange wash.
    static func litInk(_ theme: HelmTheme) -> NSColor {
        let panel = HelmTheme.sidePanelFill(theme)
        let washed = panel.blended(withFraction: HelmAccentRow.selectionWash, of: HelmTheme.nsColor(theme.accentHex)) ?? panel
        return HelmContrast.legibleTintedText(tintHex: theme.accentHex, overAnyOf: [washed, panel], theme: theme)
    }

    /// Keep the row's text in its ordinary colour on the wash.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A section header: "Pinned", "Work", ...
final class WorkspaceSidebarSectionCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: HelmType.scaled(11), weight: .semibold)
        textField = label
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The theme's muted ink, never a system grey: those know nothing about
    /// the palette (`FM_RUN_CONTRAST_TESTS`' rule), and the system's tertiary
    /// grey was measured near-invisible over Dracula's sidebar.
    func configure(title: String, theme: HelmTheme) {
        label.stringValue = title
        label.textColor = HelmTheme.mutedInk(theme)
        setAccessibilityLabel(title)
    }
}

/// A module or a pinned page: its symbol in the theme's accent, its name, and
/// an optional count on the trailing edge.
final class WorkspaceSidebarPageCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: HelmType.scaled(13))
        label.lineBreakMode = .byTruncatingTail
        // Gotcha (5): only the title may give way.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.translatesAutoresizingMaskIntoConstraints = false
        count.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(11), weight: .regular)
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        imageView = icon
        textField = label
        for view in [icon, label, count] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: HelmType.scaled(18)),
            icon.heightAnchor.constraint(equalToConstant: HelmType.scaled(18)),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: HelmMetrics.s2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: HelmMetrics.s1),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(symbol: String, title: String, trailing: String?, trailingHelp: String?, theme: HelmTheme) {
        icon.image = HelmSymbol.image(symbol, pointSize: HelmType.scaled(13), weight: .medium)
        icon.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        setLit(false, theme: theme)
        label.stringValue = title
        count.textColor = HelmTheme.mutedInk(theme)
        count.stringValue = trailing ?? ""
        count.isHidden = trailing == nil
        count.toolTip = trailingHelp
        setAccessibilityLabel(trailingHelp.map { "\(title), \($0)" } ?? title)
    }

    func setLit(_ lit: Bool, theme: HelmTheme) {
        label.textColor = lit ? WorkspaceSidebarRowView.litInk(theme) : HelmTheme.nsColor(theme.chromeInkHex)
    }

    #if FM_SELFTESTS
    var debugTitle: String { label.stringValue }
    var debugTrailing: String? { count.isHidden ? nil : count.stringValue }
    var debugIconTint: NSColor? { icon.contentTintColor }
    var debugLabelColor: NSColor? { label.textColor }
    #endif
}

/// A live session under Console: a state dot, the host's label, and its
/// ⌃⌘ shortcut.
final class WorkspaceSidebarSessionCell: NSTableCellView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: HelmType.scaled(12.5))
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        shortcut.font = .systemFont(ofSize: HelmType.scaled(11))
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

    func setLit(_ lit: Bool, theme: HelmTheme) {
        label.textColor = lit ? WorkspaceSidebarRowView.litInk(theme) : HelmTheme.nsColor(theme.chromeInkHex)
    }

    func configure(session: HostSession, shortcutIndex: Int?, theme: HelmTheme) {
        setLit(false, theme: theme)
        label.stringValue = session.label
        // Connected reads as the good hue; a restored page that has not
        // started reads as muted, never as live - the registry's own rule.
        dot.layer?.backgroundColor = (session.isConnected
            ? HelmTheme.nsColor(HelmTint.good.hex(in: theme))
            : HelmTheme.mutedInk(theme)).cgColor
        shortcut.textColor = HelmTheme.mutedInk(theme)
        shortcut.stringValue = shortcutIndex.map { "\u{2303}\u{2318}\($0)" } ?? ""
        toolTip = "\(session.label) \u{00B7} \(session.stateText)"
        setAccessibilityLabel("\(session.label), \(session.stateText)")
    }

    #if FM_SELFTESTS
    var debugTitle: String { label.stringValue }
    var debugShortcut: String { shortcut.stringValue }
    #endif
}

// MARK: - The account header

/// The top of the sidebar: the app's tile and name over this Mac, and the
/// account menu (Settings, Log Out) that the floating bar keeps behind its
/// avatar.
final class WorkspaceSidebarHeader: HoverHighlightView {
    private let tile = HelmGradientTile(size: .module)
    private let title = NSTextField(labelWithString: AppPaths.displayName)
    private let subtitle = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cornerRadius = HelmMetrics.rChip + 3
        accessibilityRoleOverride = .menuButton
        accessibilityLabelOverride = "\(AppPaths.displayName) account menu"
        toolTip = "Settings and Log Out"

        tile.configure(symbol: "sailboat.fill", hue: .blue)
        tile.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: HelmType.scaled(13.5), weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        subtitle.stringValue = "This Mac \u{00B7} \(NSUserName())"
        subtitle.font = .systemFont(ofSize: HelmType.scaled(11))
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

    static let height: CGFloat = 42

    @objc private func clicked() { onClick?() }

    func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        title.textColor = ink
        subtitle.textColor = HelmTheme.mutedInk(theme)
        chevron.contentTintColor = HelmTheme.mutedInk(theme)
        hoverColor = ink.withAlphaComponent(0.06)
    }

    #if FM_SELFTESTS
    var debugTitle: String { title.stringValue }
    var debugSubtitle: String { subtitle.stringValue }
    #endif
}
