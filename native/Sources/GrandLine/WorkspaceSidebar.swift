// Grand Line - native macOS app.
//
// The sidebar shell's sidebar (stages 3 and 4 of the modular-shell migration,
// full review section 5.8): a source list over the module table, hosted in the
// split view's sidebar item.
//
// It lists Home and the seventeen modules under the four groups the module
// table assigns (Work, Observe, Workbench, Machine), and the live host
// sessions as children of Console. A module's pages are its tabs in the window
// toolbar, so every one of the 29 destinations is one click on its module and
// one on its tab.
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

import AppKit

/// One row of the sidebar.
enum WorkspaceSidebarEntry: Equatable {
    /// A section header: one of the four groups.
    case section(String)
    /// Home, or one of the seventeen modules.
    case module(WorkspaceModule)
    /// A live host session, a child of Console.
    case session(hostID: UUID)
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
    static func roots(sessions: [HostSession], hidden: Set<WorkspaceModule> = []) -> [Node] {
        var roots = [Node(entry: .module(.home))]
        for group in WorkspaceGroup.allCases {
            let shown = modules(in: group, hidden: hidden)
            guard !shown.isEmpty else { continue }
            let rows = shown.map { module -> Node in
                guard module == .console else { return Node(entry: .module(module)) }
                return Node(entry: .module(.console), children: sessions.map { Node(entry: .session(hostID: $0.hostID)) })
            }
            roots.append(Node(entry: .section(group.title), children: rows))
        }
        return roots
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
    /// The page a module opens on the first time: its first tab, or its one
    /// page.
    var primaryRoute: RailDestination {
        tabs.first?.route ?? ModuleTable.routes(in: self).first ?? .homeCanvas
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
    /// Home and the seventeen modules.
    static let moduleRowHeight: CGFloat = 32
    /// A live session under Console: one step down from a module.
    static let sessionRowHeight: CGFloat = 30
    /// A group heading, with the room above it that separates the groups.
    static let sectionRowHeight: CGFloat = 34
    static let moduleTextSize: CGFloat = 15
    static let sessionTextSize: CGFloat = 14
    static let sectionTextSize: CGFloat = 13
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
    var onSelectSession: ((UUID) -> Void)?
    var onEndSession: ((UUID) -> Void)?
    var onConnectHost: (() -> Void)?
    var onLogOut: (() -> Void)?

    let outlineView = WorkspaceSidebarOutlineView()
    private let scrollView = NSScrollView()
    private let header = WorkspaceSidebarHeader()
    /// The rule between the account header and Home (stage 6): without it
    /// the header's tile and Home's glyph read as one cramped block.
    private let headerRule = NSView()
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

    // MARK: Build

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: MainSplitShellController.sidebarWidth, height: 600))
        view = root

        header.translatesAutoresizingMaskIntoConstraints = false
        header.onClick = { [weak self] in self?.showAccountMenu() }
        root.addSubview(header)
        headerRule.wantsLayer = true
        headerRule.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerRule)

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

        NSLayoutConstraint.activate([
            // The window's traffic lights and the sidebar toggle sit in the
            // title bar over this column, so the header starts below it.
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: HelmMetrics.s1),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s2),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s2),

            // The rule sits between two equal gaps, inset like the rows'
            // own wash so it lines up with the list rather than the panel.
            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Self.headerRuleGap),
            headerRule.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s3),
            headerRule.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s3),
            headerRule.heightAnchor.constraint(equalToConstant: 1),
            scrollView.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: Self.headerRuleGap),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        hiddenObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.hiddenModulesDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.setHiddenModules(AppSettings.shared.hiddenModules) }
        rebuild()
    }

    /// The captain showed or hid a module in Settings: rebuild the rows.
    func setHiddenModules(_ modules: Set<WorkspaceModule>) {
        guard modules != hidden else { return }
        hidden = modules
        guard isViewLoaded else { return }
        rebuild()
    }

    /// The space above and below the header rule.
    static let headerRuleGap: CGFloat = HelmMetrics.s2

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let hiddenObserver { NotificationCenter.default.removeObserver(hiddenObserver) }
    }

    // MARK: What the shell tells it

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
    /// a session, Console) it sits in.
    func select(_ kind: RecentDestinationKind?) {
        current = kind
        guard isViewLoaded else { return }
        applySelection()
    }

    /// ⌘⇧D: the sidebar is the whole map, so the keyboard lands in it.
    func focusList() {
        view.window?.makeFirstResponder(outlineView)
    }

    /// What the badges draw from (`WorkspaceSignals`).
    private var signals = WorkspaceSignals()

    /// The signals changed: repaint each module row's badge in place.
    func setSignals(_ signals: WorkspaceSignals) {
        self.signals = signals
        guard isViewLoaded else { return }
        let theme = ThemeManager.shared.theme
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? WorkspaceSidebarItem, case .module(let module) = item.entry,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkspaceSidebarPageCell
            else { continue }
            cell.setBadge(signals.badge(for: module), theme: theme)
        }
    }

    private func rebuild() {
        roots = WorkspaceSidebarModel.roots(sessions: sessions, hidden: hidden).map(WorkspaceSidebarItem.init)
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

    /// The row that stands for `kind`: a session row for a host page,
    /// otherwise the row of the module the page lives in.
    private func item(for kind: RecentDestinationKind?) -> WorkspaceSidebarItem? {
        guard let kind else { return nil }
        let all = roots.flatMap { [$0] + $0.children + $0.children.flatMap(\.children) }
        switch kind {
        case .host(let id, _):
            return all.first { $0.entry == .session(hostID: id) } ?? all.first { $0.entry == .module(.console) }
        case .rail(let destination):
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
        typealias M = WorkspaceSidebarMetrics
        guard let item = item as? WorkspaceSidebarItem else { return HelmType.scaledRowHeight(M.moduleRowHeight) }
        switch item.entry {
        case .section: return HelmType.scaledRowHeight(M.sectionRowHeight)
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
            cell.configure(title: title, theme: theme)
            return cell
        case .module(let module):
            let cell = WorkspaceSidebarPageCell()
            cell.configure(symbol: module.symbol, title: module.title, badge: signals.badge(for: module), theme: theme)
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
            onSelectModule?(module)
        case .session(let hostID):
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
        // The divider recipe the layout's other rules use, so they are one
        // weight.
        headerRule.layer?.backgroundColor = HelmDisplayAccessibility.strengthenedEdge(
            HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(HelmCard.dividerAlpha), theme: theme).cgColor
        guard isViewLoaded else { return }
        // R2-PERF-02: a theme change repaints the rows it can see, in place,
        // the way `setSignals` repaints a badge. It used to reload the list -
        // twenty cells rebuilt, the hovered row's fill dropped and the list
        // scrolled back to the lit row - on every ⌘-toggle and every sunset
        // under Follow system. GL-24: a theme observer repaints.
        let scale = ChromeTextScale.shared.scale
        guard scale != builtTextScale else {
            repaintRows(theme)
            return
        }
        builtTextScale = scale
        // GL-32: a text-scale change re-fires the theme too, and that one
        // does rebuild: the row heights and every font follow the scale, and
        // a cell sets its fonts and sizes once, when it is built.
        outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outlineView.numberOfRows))
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
                (cell as? WorkspaceSidebarSectionCell)?.configure(title: title, theme: theme)
            case .module(let module):
                (cell as? WorkspaceSidebarPageCell)?.repaint(badge: signals.badge(for: module), lit: row == selected,
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
    /// The cell drawn for `entry`, scrolled into view first - the way the
    /// list draws a row the captain scrolls to.
    func debugCell(for entry: WorkspaceSidebarEntry) -> NSView? {
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
    var debugHeaderRule: NSView { headerRule }
    /// Draw the list's scroller as `style` - a legacy track narrows every
    /// row, the way "Show scroll bars: Always" does (gotcha (4)).
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

/// The lit row is a soft accent wash, as the prototype draws it, rather than
/// the system's solid selection with white text - the sidebar is the app's
/// map, and the current page should read as "here", not as a selected
/// object. It is the same wash, and the same corrected accent ink, that a
/// page's own column (`HelmPageSidebar`) gives its selected row, so the two
/// sidebars side by side on Tasks or Settings read as one idiom.
///
/// The wash and the hover fill ease (`HelmRowWash`, the motion table's state
/// row), as the prototype's rows do: the lit row's wash fades across to the
/// new row on a navigation, and a row under the pointer takes a faint ink
/// fill. Neither moves under Reduce Motion, and a rebuild of the rows paints
/// at once: the list builds its row views after the selection is applied, so
/// a new row's first paint is already the lit state (`HelmRowWash`).
final class WorkspaceSidebarRowView: NSTableRowView {
    private let fill: HelmRowWash
    private var hovering = false

    override init(frame frameRect: NSRect) {
        fill = HelmRowWash(frame: .zero)
        super.init(frame: frameRect)
        addSubview(fill, positioned: .below, relativeTo: nil)
        // `.inVisibleRect`: AppKit keeps the area matched to the row, so
        // there is no `updateTrackingAreas` bookkeeping per resize.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The wash replaces the drawn selection.
    override func drawSelection(in dirtyRect: NSRect) {}

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { paintFill() } }
    }

    /// R2-A11Y-01: the accent ring on the lit row while the keyboard is in
    /// the list (`WorkspaceSidebarOutlineView.showsKeyboardFocus`).
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
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        paintFill()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        paintFill()
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
        fill.paint(color, cornerRadius: HelmMetrics.rChip + 1, animated: animated)
        refreshFocus()
    }

    static func wash(_ theme: HelmTheme) -> NSColor {
        HelmTheme.nsColor(theme.accentHex).withAlphaComponent(HelmAccentRow.selectionWash)
    }

    /// The prototype's row hover: the page ink at 6%, the same fill the
    /// account header above the list takes.
    static func hover(_ theme: HelmTheme) -> NSColor {
        HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(WorkspaceSidebarHeader.hoverAlpha)
    }

    #if FM_SELFTESTS
    var debugFill: HelmRowWash { fill }
    var debugHovering: Bool { hovering }
    #endif

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

/// A section header: "Work", "Observe", ...
final class WorkspaceSidebarSectionCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: HelmType.scaled(WorkspaceSidebarMetrics.sectionTextSize), weight: .semibold)
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

/// A module: its symbol in the theme's accent, its name, and the module's
/// badge on the trailing edge (`WorkspaceSignals.badge`).
final class WorkspaceSidebarPageCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    let badgeView = WorkspaceSidebarBadgeView()
    private var title = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: HelmType.scaled(WorkspaceSidebarMetrics.moduleTextSize))
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
        icon.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        self.title = title
        setLit(false, theme: theme)
        label.stringValue = title
        setBadge(badge, theme: theme)
    }

    /// The badge alone, in place - a signal changing repaints one row's
    /// trailing edge, never the list.
    func setBadge(_ badge: WorkspaceBadge?, theme: HelmTheme) {
        badgeView.configure(badge, theme: theme)
        // VoiceOver hears the module and then what its badge says.
        setAccessibilityLabel(badge.map { "\(title), \($0.description)" } ?? title)
    }

    func setLit(_ lit: Bool, theme: HelmTheme) {
        label.textColor = lit ? WorkspaceSidebarRowView.litInk(theme) : HelmTheme.nsColor(theme.chromeInkHex)
    }

    /// R2-PERF-02: the colours of a built row, for a theme change. The
    /// symbol image and the title stay, and only what the palette decides moves.
    func repaint(badge: WorkspaceBadge?, lit: Bool, theme: HelmTheme) {
        icon.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        setLit(lit, theme: theme)
        setBadge(badge, theme: theme)
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

/// A module row's badge: a count, a dot or a symbol. A quiet count is the
/// row's muted ink, as the prototype draws Tasks' and Setup's; one that wants
/// the captain (Crew's) is a pill, its fill the attention hue washed over the
/// sidebar and its digits corrected to clear the text floor on that fill
/// (`FM_RUN_CONTRAST_TESTS`' rule: a hue is a safe fill, not automatically
/// safe text). Hidden, not empty, when there is nothing to say - an empty
/// pill reads as a zero (GL-14).
final class WorkspaceSidebarBadgeView: NSView {
    static let height: CGFloat = WorkspaceSidebarMetrics.badgeHeight
    /// How much of the attention hue the pill's fill takes.
    static let pillWash: CGFloat = 0.22

    private let label = NSTextField(labelWithString: "")
    private let symbol = NSImageView()
    private let dot = NSView()
    private var labelInset: [NSLayoutConstraint] = []
    private(set) var badge: WorkspaceBadge?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
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
            heightAnchor.constraint(equalToConstant: Self.height),
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

    func configure(_ badge: WorkspaceBadge?, theme: HelmTheme) {
        self.badge = badge
        isHidden = badge == nil
        toolTip = badge?.description
        label.isHidden = true
        symbol.isHidden = true
        dot.isHidden = true
        layer?.backgroundColor = nil
        guard let badge else { return }
        let panel = HelmTheme.sidePanelFill(theme)
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
                let fill = Self.pillFill(for: badge.tone, theme: theme)
                layer?.backgroundColor = fill.cgColor
                label.textColor = HelmContrast.legibleOn(fill: fill, preferring: Self.hue(badge.tone, theme))
                label.font = .monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            } else {
                label.textColor = HelmTheme.mutedInk(theme)
                label.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
            }
        case .dot:
            dot.isHidden = false
            dot.layer?.backgroundColor = Self.ink(for: badge.tone, over: panel, theme: theme).cgColor
        case .symbol(let name):
            symbol.isHidden = false
            symbol.image = HelmSymbol.image(name, pointSize: HelmType.scaled(WorkspaceSidebarMetrics.badgeTextSize),
                                            weight: .semibold)
            symbol.contentTintColor = badge.tone == .neutral
                ? HelmTheme.mutedInk(theme) : Self.ink(for: badge.tone, over: panel, theme: theme)
        }
    }

    static func hue(_ tone: WorkspaceBadge.Tone, _ theme: HelmTheme) -> NSColor {
        switch tone {
        case .neutral: return HelmTheme.mutedInk(theme)
        case .attention: return HelmTheme.nsColor(HelmTint.warn.hex(in: theme))
        case .alarm: return HelmTheme.nsColor(HelmTint.critical.hex(in: theme))
        }
    }

    /// A tone as a mark on `surface`: the hue, corrected until it clears the
    /// text floor there (a dot or a glyph that says "failing" is read like a
    /// word).
    static func ink(for tone: WorkspaceBadge.Tone, over surface: NSColor, theme: HelmTheme) -> NSColor {
        switch tone {
        case .neutral: return HelmTheme.mutedInk(theme)
        case .attention: return HelmContrast.legibleTintedText(tintHex: HelmTint.warn.hex(in: theme), over: surface, theme: theme)
        case .alarm: return HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme), over: surface, theme: theme)
        }
    }

    /// The attention pill's opaque fill over the sidebar's.
    static func pillFill(for tone: WorkspaceBadge.Tone, theme: HelmTheme) -> NSColor {
        let panel = HelmTheme.sidePanelFill(theme)
        return panel.blended(withFraction: pillWash, of: hue(tone, theme)) ?? panel
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
        label.font = .systemFont(ofSize: HelmType.scaled(WorkspaceSidebarMetrics.sessionTextSize))
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
/// account menu (Log Out) that the floating bar keeps behind its avatar.
final class WorkspaceSidebarHeader: HoverHighlightView {
    private let tile = HelmGradientTile(size: .module)
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

        tile.configure(symbol: "sailboat.fill", hue: .blue)
        tile.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: HelmType.scaled(15), weight: .semibold)
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

    /// What VoiceOver reads before "menu button".
    static let accessibilityLabel = "\(AppPaths.displayName), Log Out"

    @objc private func clicked() { onClick?() }

    func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        title.textColor = ink
        subtitle.textColor = HelmTheme.mutedInk(theme)
        chevron.contentTintColor = HelmTheme.mutedInk(theme)
        hoverColor = ink.withAlphaComponent(Self.hoverAlpha)
    }

    /// The page ink's share of a hovered row or header in the sidebar.
    static let hoverAlpha: CGFloat = 0.06

    #if FM_SELFTESTS
    var debugTitle: String { title.stringValue }
    var debugSubtitle: String { subtitle.stringValue }
    #endif
}
