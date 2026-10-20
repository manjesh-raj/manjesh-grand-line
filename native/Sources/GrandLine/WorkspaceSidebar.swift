// Grand Line - native macOS app.
//
// The Workspace shell's sidebar: the whole app as one labelled list.
//
// UX-01 of the 2026-10 review. Before this, a page was reached from a Home
// card, a space pill, a quick-access square, Recents, ⌘K or the
// all-destinations overlay, and opening one replaced the bar's wordmark and
// pills with a back button - so on every page but Home there was no
// persistent sense of where you were or what else existed. This list is that
// map, always on screen: seventeen modules from `ModuleTable`, in Home plus
// four headed groups, with the active module's children (live sessions,
// task views, settings categories) under it.
//
// SHAPE
//
// An `NSOutlineView` rather than a stack of buttons, because a source list is
// what gives VoiceOver the app's map (rows, levels, selection) and the
// keyboard its arrows for free. The rows are this file's own cell views
// rather than the `.sourceList` style's, for the reason `HelmSplitPage`'s
// header records: the source-list style resolves its selection and text
// colours from the system's vibrancy, which none of the 26 palettes chose
// and which an off-screen render cannot draw. The outline keeps the
// behaviour; Helm draws the rows.
//
// Selection flows one way. A click or an arrow key reports the module (or
// child) through `onSelectModule` / `onSelectChild`; the shell navigates and
// then tells the sidebar what is showing through `setSelection`. A
// programmatic selection never re-fires the callbacks.
//
// Below 1100pt of window width the column collapses to icons (the review's
// section 4.2), and every row keeps its name as a tooltip and an
// accessibility label.

import AppKit

/// One child row under the active module: a live session, a task view, a
/// settings category.
struct WorkspaceSidebarChild: Equatable {
    /// Stable within its module, so the shell can tell which child a click
    /// meant and which one to light.
    let id: String
    let title: String
    /// A status dot, drawn in this tint. `nil` draws no dot.
    let dot: HelmTint?
    /// A short trailing caption ("2", "⌃⌘1").
    let accessory: String?
    /// What VoiceOver adds after the title - the state a dot shows, in words.
    let spokenDetail: String?

    init(id: String, title: String, dot: HelmTint? = nil, accessory: String? = nil, spokenDetail: String? = nil) {
        self.id = id
        self.title = title
        self.dot = dot
        self.accessory = accessory
        self.spokenDetail = spokenDetail
    }

    static func == (lhs: WorkspaceSidebarChild, rhs: WorkspaceSidebarChild) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.accessory == rhs.accessory
            && lhs.spokenDetail == rhs.spokenDetail
            && String(describing: lhs.dot) == String(describing: rhs.dot)
    }
}

/// What a module row shows at its trailing edge.
enum WorkspaceSidebarAccessory: Equatable {
    /// A muted count or short word ("7", "2 live").
    case caption(String)
    /// A filled count badge in a tint - "needs you".
    case badge(Int, HelmTint)
    /// A small glyph, e.g. the vault's lock state.
    case symbol(String, accessibility: String)

    static func == (lhs: WorkspaceSidebarAccessory, rhs: WorkspaceSidebarAccessory) -> Bool {
        switch (lhs, rhs) {
        case let (.caption(a), .caption(b)): return a == b
        case let (.badge(a, ta), .badge(b, tb)): return a == b && String(describing: ta) == String(describing: tb)
        case let (.symbol(a, la), .symbol(b, lb)): return a == b && la == lb
        default: return false
        }
    }
}

/// An outline item. A class, because `NSOutlineView` identifies items by
/// reference.
final class WorkspaceSidebarNode: NSObject {
    enum Kind {
        case section(WorkspaceSection)
        case module(WorkspaceModuleID)
        case child(WorkspaceModuleID, WorkspaceSidebarChild)
    }
    let kind: Kind
    var children: [WorkspaceSidebarNode] = []

    init(_ kind: Kind) { self.kind = kind }

    var moduleID: WorkspaceModuleID? {
        switch kind {
        case .module(let id), .child(let id, _): return id
        case .section: return nil
        }
    }
}

final class WorkspaceSidebarController: NSViewController {

    /// The column's width when expanded, and its icon-only width.
    static let expandedWidth: CGFloat = 232
    /// Wide enough that the window's traffic lights (measured, they span
    /// x 9...69) sit inside the column rather than over the page.
    static let compactWidth: CGFloat = 76
    /// The window width under which the column shows icons only.
    ///
    /// The review proposed 1100pt. Measured against the pages as they are,
    /// that is too narrow: Log Analyzer's page holds a required minimum of
    /// 973.5pt and DevOps Commands' 964.5pt, so a full sidebar beside either
    /// in a window under ~1206pt pushes the page past its column. 1210 is that
    /// minimum plus the full column and its divider, rounded up.
    static let compactBelowWindowWidth: CGFloat = 1210

    static let moduleRowHeight: CGFloat = 28
    static let childRowHeight: CGFloat = 26
    static let sectionRowHeight: CGFloat = 32
    static let compactSectionRowHeight: CGFloat = 13

    // MARK: Inputs (set by the shell)

    var onSelectModule: ((WorkspaceModuleID) -> Void)?
    var onSelectChild: ((WorkspaceModuleID, WorkspaceSidebarChild) -> Void)?
    /// A child row's context menu - e.g. "End Session" on a live session.
    var childMenu: ((WorkspaceModuleID, WorkspaceSidebarChild) -> NSMenu?)?
    /// The footer's account menu items.
    var onOpenSettings: (() -> Void)?
    var onLogout: (() -> Void)?

    /// The active module's children. Asked on every `reloadChildren()`.
    var childrenProvider: ((WorkspaceModuleID) -> [WorkspaceSidebarChild])?
    /// A module row's trailing accessory. Asked on every `reloadAccessories()`.
    var accessoryProvider: ((WorkspaceModuleID) -> WorkspaceSidebarAccessory?)?

    // MARK: State

    private(set) var selectedModule: WorkspaceModuleID = .home
    private(set) var selectedChildID: String?
    private(set) var isCompact = false

    private let scroll = NSScrollView()
    let outline = WorkspaceSidebarOutlineView()
    private let footer = WorkspaceSidebarFooter()
    private var roots: [WorkspaceSidebarNode] = []
    private var moduleNodes: [WorkspaceModuleID: WorkspaceSidebarNode] = [:]
    private var isApplyingSelection = false
    /// Set when the outline's own selection moved (a click's mouse-down or
    /// an arrow key) and was reported, so the click's action that follows on
    /// mouse-up does not report the same choice twice.
    private var reportedSinceLastClick = false
    private var themeToken: ThemeObservation?

    override func loadView() {
        let root = WorkspaceSidebarBackground(frame: NSRect(x: 0, y: 0, width: Self.expandedWidth, height: 600))
        root.wantsLayer = true
        view = root

        buildTree()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("module"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.backgroundColor = .clear
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = 0
        outline.indentationMarkerFollowsCell = false
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .custom
        outline.focusRingType = .none
        outline.allowsEmptySelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.setAccessibilityLabel("Modules")
        outline.setAccessibilityIdentifier("workspace-sidebar")
        outline.contextMenuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        outline.onMouseDown = { [weak self] in self?.reportedSinceLastClick = false }

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.onClick = { [weak self] in self?.showAccountMenu() }
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            // The traffic lights and the toolbar sit over the top of this
            // column (the window is full-size-content), so the list starts
            // under the safe area rather than at the window's top edge.
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: HelmMetrics.s1),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        outline.reloadData()
        expandSections()
        applySelectionToOutline()

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    // MARK: Tree

    private func buildTree() {
        roots = []
        moduleNodes = [:]
        for section in WorkspaceSection.allCases {
            let modules = ModuleTable.modules(in: section).map { descriptor -> WorkspaceSidebarNode in
                let node = WorkspaceSidebarNode(.module(descriptor.id))
                moduleNodes[descriptor.id] = node
                return node
            }
            if section.title == nil {
                roots.append(contentsOf: modules)
            } else {
                let header = WorkspaceSidebarNode(.section(section))
                header.children = modules
                roots.append(header)
            }
        }
    }

    private func expandSections() {
        for node in roots {
            if case .section = node.kind { outline.expandItem(node) }
        }
    }

    /// Re-ask the children provider for the active module and redraw them.
    /// Children are shown under the active module only (and never in the
    /// icon-only column), which keeps seventeen rows the resting height of
    /// the list.
    func reloadChildren() {
        guard isViewLoaded else { return }
        for (id, node) in moduleNodes {
            let wanted: [WorkspaceSidebarChild] = (id == selectedModule && !isCompact)
                ? (childrenProvider?(id) ?? []) : []
            let current = node.children.compactMap { child -> WorkspaceSidebarChild? in
                if case .child(_, let value) = child.kind { return value }
                return nil
            }
            guard wanted != current else { continue }
            node.children = wanted.map { WorkspaceSidebarNode(.child(id, $0)) }
            outline.reloadItem(node, reloadChildren: true)
            if node.children.isEmpty {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
        }
        applySelectionToOutline()
    }

    /// Re-ask the accessory provider for every module row.
    func reloadAccessories() {
        guard isViewLoaded else { return }
        for node in moduleNodes.values {
            let row = outline.row(forItem: node)
            guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? WorkspaceSidebarModuleCell, case .module(let id) = node.kind else { continue }
            cell.setAccessory(accessoryProvider?(id), theme: ThemeManager.shared.theme)
        }
    }

    // MARK: Selection

    /// Light `module` (and `child`, if one of its children is what is
    /// showing). Never fires the selection callbacks.
    func setSelection(module: WorkspaceModuleID, childID: String?) {
        let moduleChanged = module != selectedModule
        selectedModule = module
        selectedChildID = childID
        guard isViewLoaded else { return }
        if moduleChanged {
            reloadChildren()
        } else {
            applySelectionToOutline()
        }
        refreshSelectedStyling()
    }

    private func applySelectionToOutline() {
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        var target: WorkspaceSidebarNode? = moduleNodes[selectedModule]
        if let selectedChildID, let node = target,
           let child = node.children.first(where: {
               if case .child(_, let value) = $0.kind { return value.id == selectedChildID }
               return false
           }) {
            target = child
        }
        let row = target.map { outline.row(forItem: $0) } ?? -1
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
        refreshSelectedStyling()
    }

    private func refreshSelectedStyling() {
        let theme = ThemeManager.shared.theme
        outline.enumerateAvailableRowViews { rowView, row in
            guard let node = outline.item(atRow: row) as? WorkspaceSidebarNode else { return }
            (rowView.view(atColumn: 0) as? WorkspaceSidebarCellStyling)?
                .applyTheme(theme, selected: isSelected(node), compact: isCompact)
        }
    }

    private func isSelected(_ node: WorkspaceSidebarNode) -> Bool {
        switch node.kind {
        case .module(let id): return id == selectedModule && selectedChildID == nil
        case .child(let id, let child): return id == selectedModule && child.id == selectedChildID
        case .section: return false
        }
    }

    @objc private func rowClicked() {
        // A click that moved the selection was already reported by
        // `outlineViewSelectionDidChange`. One on the row that is already
        // selected never reaches it (and re-choosing a module is how the
        // captain gets back to its first tab), so that one reports here.
        if reportedSinceLastClick {
            reportedSinceLastClick = false
            return
        }
        report(row: outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow)
    }

    private func report(row: Int) {
        guard row >= 0, let node = outline.item(atRow: row) as? WorkspaceSidebarNode else { return }
        switch node.kind {
        case .module(let id):
            onSelectModule?(id)
        case .child(let id, let child):
            onSelectChild?(id, child)
        case .section:
            applySelectionToOutline()
        }
    }

    // MARK: Compact (icon-only) mode

    func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        isCompact = compact
        guard isViewLoaded else { return }
        footer.isCompact = compact
        outline.reloadData()
        expandSections()
        reloadChildren()
        reloadAccessories()
    }

    // MARK: Menus

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, let node = outline.item(atRow: row) as? WorkspaceSidebarNode,
              case .child(let id, let child) = node.kind else { return nil }
        return childMenu?(id, child)
    }

    private func showAccountMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(accountSettings), keyEquivalent: "")
        settings.target = self
        settings.withSymbol("gearshape")
        menu.addItem(settings)
        menu.addItem(.separator())
        let logout = NSMenuItem(title: "Log Out\u{2026}", action: #selector(accountLogout), keyEquivalent: "")
        logout.target = self
        logout.withSymbol("rectangle.portrait.and.arrow.right")
        menu.addItem(logout)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: footer.bounds.maxY + 4), in: footer)
    }

    @objc private func accountSettings() { onOpenSettings?() }
    @objc private func accountLogout() { onLogout?() }

    // MARK: Theme

    private func applyTheme(_ theme: HelmTheme) {
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        (view as? WorkspaceSidebarBackground)?.applyTheme(theme)
        footer.applyTheme(theme)
        refreshSelectedStyling()
        reloadAccessories()
    }

    // MARK: Probe surface

    #if FM_SELFTESTS
    /// The rows as the outline lays them out, top to bottom: a section
    /// header's title, a module's title, or a child's title with a leading
    /// "  ".
    var debugRowTitles: [String] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? WorkspaceSidebarNode else { return nil }
            switch node.kind {
            case .section(let section): return "# " + (section.title ?? "")
            case .module(let id): return ModuleTable.descriptor(id).title
            case .child(_, let child): return "  " + child.title
            }
        }
    }

    /// Select `row` the way a click does (through the outline's own action).
    func debugClickRow(_ row: Int) { report(row: row) }

    /// What the outline's own `mouseDown` does before AppKit's handling.
    func debugSimulateMouseDown() { reportedSinceLastClick = false }

    func debugRow(ofModule id: WorkspaceModuleID) -> Int {
        moduleNodes[id].map { outline.row(forItem: $0) } ?? -1
    }

    var debugSelectedRow: Int { outline.selectedRow }

    func debugCell(atRow row: Int) -> NSView? {
        outline.view(atColumn: 0, row: row, makeIfNecessary: true)
    }

    var debugFooter: WorkspaceSidebarFooter { footer }
    #endif
}

// MARK: - Data source and delegate

extension WorkspaceSidebarController: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? WorkspaceSidebarNode else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? WorkspaceSidebarNode else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? WorkspaceSidebarNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? WorkspaceSidebarNode, case .section = node.kind else { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? WorkspaceSidebarNode, case .section = node.kind else { return true }
        return false
    }

    // Sections and the active module stay open; the outline's own
    // disclosure would otherwise let a click fold a group away.
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        isApplyingSelection
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? WorkspaceSidebarNode else { return Self.moduleRowHeight }
        switch node.kind {
        case .section: return isCompact ? Self.compactSectionRowHeight : HelmType.scaledRowHeight(Self.sectionRowHeight)
        case .module: return HelmType.scaledRowHeight(Self.moduleRowHeight)
        case .child: return HelmType.scaledRowHeight(Self.childRowHeight)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        WorkspaceSidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? WorkspaceSidebarNode else { return nil }
        let theme = ThemeManager.shared.theme
        let cell: NSView & WorkspaceSidebarCellStyling
        switch node.kind {
        case .section(let section):
            let header = WorkspaceSidebarSectionCell()
            header.configure(title: section.title ?? "")
            cell = header
        case .module(let id):
            let row = WorkspaceSidebarModuleCell()
            row.configure(ModuleTable.descriptor(id))
            row.setAccessory(accessoryProvider?(id), theme: theme)
            cell = row
        case .child(_, let child):
            let row = WorkspaceSidebarChildCell()
            row.configure(child)
            cell = row
        }
        cell.applyTheme(theme, selected: isSelected(node), compact: isCompact)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        // Every selection change the shell did not make itself is the
        // captain's choice - an arrow key or a click - and navigates at once,
        // the way Mail's mailbox list does.
        reportedSinceLastClick = true
        report(row: outline.selectedRow)
    }
}

// MARK: - Views

/// The outline, with a per-row context menu hook.
final class WorkspaceSidebarOutlineView: NSOutlineView {
    var contextMenuProvider: ((Int) -> NSMenu?)?
    /// Fired before AppKit's own mouse-down handling, so the controller can
    /// tell a click that moved the selection from one that did not.
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

    /// A click on a module while the window is in the background goes there
    /// at once, the way Finder's and Mail's sidebars do, rather than only
    /// bringing the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return contextMenuProvider?(row)
    }

    // The outline's own selection fill is replaced by the cells' (see
    // `WorkspaceSidebarRowView`), so Return and Space on the selected row are
    // what a keyboard user needs: both open it.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49, selectedRow >= 0 {
            sendAction(action, to: target)
            return
        }
        super.keyDown(with: event)
    }
}

/// The column's ground. Opaque and Helm-painted, so the 26 palettes keep
/// their own sidebar tone (see the file header).
final class WorkspaceSidebarBackground: NSView {
    private var edge = NSColor.clear

    func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.sidePanelFill(theme).cgColor
        edge = HelmTheme.sidePanelEdge(theme)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The hairline on the trailing edge, where the column meets the page.
        edge.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// A row view that draws nothing: selection is the cell's own rounded wash,
/// in the theme's ink, so it reads the same in every palette.
final class WorkspaceSidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
}

protocol WorkspaceSidebarCellStyling: AnyObject {
    func applyTheme(_ theme: HelmTheme, selected: Bool, compact: Bool)
}

/// The shared look of a selectable row: a rounded wash at 8pt side insets.
class WorkspaceSidebarSelectableCell: NSTableCellView {
    let wash = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wash.wantsLayer = true
        wash.layer?.cornerRadius = HelmMetrics.rControl
        wash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wash)
        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2 + 2),
            wash.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(HelmMetrics.s2 + 2)),
            wash.topAnchor.constraint(equalTo: topAnchor),
            wash.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyWash(_ theme: HelmTheme, selected: Bool) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        wash.layer?.backgroundColor = selected
            ? ink.withAlphaComponent(theme.mode == .dark ? 0.10 : 0.08).cgColor
            : NSColor.clear.cgColor
    }
}

final class WorkspaceSidebarModuleCell: WorkspaceSidebarSelectableCell, WorkspaceSidebarCellStyling {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let badge = HelmSidebarBadge()
    private let glyph = NSImageView()
    private var titleLeading: NSLayoutConstraint!
    private var iconLeading: NSLayoutConstraint!
    private var iconCenter: NSLayoutConstraint!
    private var symbolName = ""
    private(set) var moduleTitle = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [icon, title, caption, badge, glyph] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.alignment = .right
        caption.setContentHuggingPriority(.required, for: .horizontal)
        caption.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20)
        iconCenter = icon.centerXAnchor.constraint(equalTo: centerXAnchor)
        titleLeading = title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9)
        // Below required, so a hidden title in the icon-only column (whose
        // constraints still take part in layout - AGENTS.md gotcha (15))
        // overflows quietly instead of squeezing the icon it sits beside.
        let titleFits = title.trailingAnchor.constraint(lessThanOrEqualTo: caption.leadingAnchor,
                                                        constant: -HelmMetrics.s1)
        titleFits.priority = .defaultHigh
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 16),
            titleLeading,
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleFits,
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            caption.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        icon.imageScaling = .scaleProportionallyDown
        glyph.imageScaling = .scaleProportionallyDown
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ module: ModuleDescriptor) {
        symbolName = module.symbol
        moduleTitle = module.title
        title.stringValue = module.title
        toolTip = module.summary
        setAccessibilityRole(.row)
        setAccessibilityLabel(module.title)
        if let chord = module.chord {
            setAccessibilityHelp("\(module.summary). \(chord.displayString)")
        } else {
            setAccessibilityHelp(module.summary)
        }
    }

    func setAccessory(_ accessory: WorkspaceSidebarAccessory?, theme: HelmTheme) {
        caption.isHidden = true
        badge.isHidden = true
        glyph.isHidden = true
        switch accessory {
        case .caption(let text)?:
            caption.stringValue = text
            caption.isHidden = false
        case .badge(let count, let tint)?:
            badge.configure(count: count, tint: tint, theme: theme)
            badge.isHidden = false
        case .symbol(let name, let label)?:
            glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            glyph.setAccessibilityLabel(label)
            glyph.isHidden = false
        case nil:
            break
        }
        let muted = HelmTheme.mutedInk(theme)
        caption.textColor = muted
        caption.font = HelmType.tabularCaption()
        glyph.contentTintColor = muted
        var label = moduleTitle
        switch accessory {
        case .caption(let text)?: label += ", \(text)"
        case .badge(let count, _)?: label += ", \(count) need you"
        case .symbol(_, let text)?: label += ", \(text)"
        case nil: break
        }
        setAccessibilityLabel(label)
    }

    func applyTheme(_ theme: HelmTheme, selected: Bool, compact: Bool) {
        applyWash(theme, selected: selected)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        title.textColor = ink
        title.font = .systemFont(ofSize: HelmType.scaled(13), weight: selected ? .semibold : .medium)
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: HelmType.scaled(13), weight: .medium))
        // Monochrome at rest, accent for the active item (review section
        // 4.10, principle 3).
        icon.contentTintColor = selected ? HelmTheme.nsColor(theme.accentHex) : HelmTheme.mutedInk(theme)
        title.isHidden = compact
        iconLeading.isActive = !compact
        iconCenter.isActive = compact
        if compact {
            caption.isHidden = true
            glyph.isHidden = true
        }
        setAccessibilitySelected(selected)
    }
}

final class WorkspaceSidebarChildCell: WorkspaceSidebarSelectableCell, WorkspaceSidebarCellStyling {
    /// The status dot's diameter (the review's "identity in an 8pt dot").
    static let dotSide: CGFloat = HelmMetrics.s2
    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private var dotTint: HelmTint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [dot, title, caption] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.setContentHuggingPriority(.required, for: .horizontal)
        caption.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: HelmMetrics.s2 + 1),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: caption.leadingAnchor, constant: -HelmMetrics.s1),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            caption.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ child: WorkspaceSidebarChild) {
        title.stringValue = child.title
        caption.stringValue = child.accessory ?? ""
        caption.isHidden = child.accessory == nil
        dotTint = child.dot
        dot.isHidden = child.dot == nil
        toolTip = child.title
        setAccessibilityRole(.row)
        setAccessibilityLabel([child.title, child.spokenDetail, child.accessory].compactMap { $0 }.joined(separator: ", "))
    }

    func applyTheme(_ theme: HelmTheme, selected: Bool, compact: Bool) {
        applyWash(theme, selected: selected)
        title.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        title.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: selected ? .semibold : .regular)
        caption.textColor = HelmTheme.mutedInk(theme)
        caption.font = HelmType.tabularCaption()
        if let dotTint {
            dot.layer?.backgroundColor = HelmTheme.nsColor(dotTint.hex(in: theme)).cgColor
        }
        setAccessibilitySelected(selected)
    }
}

final class WorkspaceSidebarSectionCell: NSTableCellView, WorkspaceSidebarCellStyling {
    private let title = NSTextField(labelWithString: "")
    private let rule = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.translatesAutoresizingMaskIntoConstraints = false
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        addSubview(title)
        addSubview(rule)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rule.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(title text: String) {
        title.stringValue = text.uppercased()
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    func applyTheme(_ theme: HelmTheme, selected _: Bool, compact: Bool) {
        title.attributedStringValue = NSAttributedString(
            string: title.stringValue,
            attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
        title.isHidden = compact
        rule.isHidden = !compact
        rule.layer?.backgroundColor = HelmTheme.sidePanelEdge(theme).cgColor
    }
}

/// A filled count badge for "needs you" - the one place the sidebar uses a
/// semantic fill, because it is a state that is not the default.
final class HelmSidebarBadge: NSView {
    static let height: CGFloat = 18
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5),
        ])
        layer?.cornerRadius = Self.height / 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(count: Int, tint: HelmTint, theme: HelmTheme) {
        let fill = HelmTheme.nsColor(tint.hex(in: theme))
        layer?.backgroundColor = fill.cgColor
        label.stringValue = count > 99 ? "99+" : "\(count)"
        label.font = .systemFont(ofSize: HelmType.scaled(11), weight: .bold)
        label.textColor = HelmContrast.legibleOn(fill: fill, preferring: .white)
        setAccessibilityElement(false)
    }

    #if FM_SELFTESTS
    var debugText: String { label.stringValue }
    #endif
}

/// The account row at the bottom of the column.
final class WorkspaceSidebarFooter: NSView {
    static let discSide: CGFloat = 20
    var onClick: (() -> Void)?
    var isCompact = false { didSet { applyCompact() } }

    private let rule = NSView()
    private let avatar = NSTextField(labelWithString: "")
    private let avatarDisc = NSView()
    private let name = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var discLeading: NSLayoutConstraint!
    private var discCenter: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for view in [rule, avatarDisc, avatar, name, chevron] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        rule.wantsLayer = true
        avatarDisc.wantsLayer = true
        avatarDisc.layer?.cornerRadius = Self.discSide / 2
        avatar.alignment = .center
        let fullName = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        name.stringValue = fullName
        name.lineBreakMode = .byTruncatingTail
        avatar.stringValue = String(fullName.prefix(1)).uppercased()
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        discLeading = avatarDisc.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20)
        discCenter = avatarDisc.centerXAnchor.constraint(equalTo: centerXAnchor)
        // Below required, so the hidden name in the icon-only column cannot
        // squeeze the avatar (measured: it drew an oval).
        let nameFits = name.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor,
                                                      constant: -HelmMetrics.s1)
        nameFits.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rule.heightAnchor.constraint(equalToConstant: 1),
            discLeading,
            avatarDisc.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarDisc.widthAnchor.constraint(equalToConstant: Self.discSide),
            avatarDisc.heightAnchor.constraint(equalToConstant: Self.discSide),
            avatar.centerXAnchor.constraint(equalTo: avatarDisc.centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: avatarDisc.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: avatarDisc.trailingAnchor, constant: 9),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameFits,
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Account: \(fullName)")
        setAccessibilityHelp("Settings and log out")
        toolTip = "Account"
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    private func applyCompact() {
        name.isHidden = isCompact
        chevron.isHidden = isCompact
        discLeading.isActive = !isCompact
        discCenter.isActive = isCompact
    }

    #if FM_SELFTESTS
    /// Every text or glyph the row draws besides the avatar, visible now.
    var debugVisibleExtras: [String] {
        var out: [String] = []
        if !name.isHiddenOrHasHiddenAncestor { out.append("name") }
        if !chevron.isHiddenOrHasHiddenAncestor { out.append("chevron") }
        return out
    }
    #endif

    func applyTheme(_ theme: HelmTheme) {
        rule.layer?.backgroundColor = HelmTheme.sidePanelEdge(theme).cgColor
        let accent = HelmTheme.nsColor(theme.accentHex)
        avatarDisc.layer?.backgroundColor = accent.cgColor
        avatar.font = .systemFont(ofSize: HelmType.scaled(10.5), weight: .bold)
        avatar.textColor = HelmContrast.legibleOn(fill: accent, preferring: .white)
        name.font = .systemFont(ofSize: HelmType.scaled(13), weight: .medium)
        name.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        chevron.contentTintColor = HelmTheme.mutedInk(theme)
    }
}
