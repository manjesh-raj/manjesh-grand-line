// Grand Line - native macOS app.
//
// `HelmDataTable` - the app's one multi-column table, for the sidebar layout's
// redesigned pages (the later page work of the modular-shell migration).
//
// The prototype draws one table component for every list of records: a
// column header, a two-line leading cell, a selected row, row actions that
// show on hover, and a context menu. The sidebar layout's Hosts, SSH keys,
// Snippets and Poneglyph lists are all that table, so it is one component
// here rather than four copies (AGENTS.md, "The component index").
//
// What it is built from:
//
//   - **A `HelmCard`**, so the table is the same one bordered surface every
//     other list in the app sits on.
//   - **A view-based `HelmTableView`**, with `.plain` style and no system
//     selection highlight, for the reason `HostsListSection` gives (audit
//     §5.2: `.sourceList` installs the private system-accent material). The
//     row view paints selection and hover itself, from the theme's own accent
//     wash and `HelmFlatList.rowHoverColor` - the recipes `HelmAccentRow` uses.
//   - **Its own header strip** rather than an `NSTableHeaderView`: the stock
//     header paints system chrome (its cells and the filler beyond the last
//     column), and this table lays its columns out itself anyway, so a strip
//     of `HelmType` labels at the same x positions is the whole of it.
//
// **The table sizes its columns itself.** Fixed columns keep their width, the
// one flexible column takes what is left, and a column marked `hiddenBelow`
// steps out when the table is narrower than that - the prototype's optional
// columns, which go below its 1240pt breakpoint. So the table never scrolls
// sideways, and never holds a width that could grow the window (AGENTS.md
// gotcha (13)): nothing here is a constraint on the window at all.
//
// **Group and empty rows span the whole width.** They are `NSTableView` group
// rows, which the delegate is asked for once with no column. They do not
// float (`floatsGroupRows = false`), so a group header scrolls with its rows.

import AppKit

final class HelmDataTable: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    // MARK: Model

    struct Column {
        let id: String
        let title: String
        /// The width a fixed column keeps, and the width a flexible column
        /// starts from before the spare width is shared out.
        var width: CGFloat
        /// The narrowest a flexible column may be squeezed to.
        var minWidth: CGFloat
        /// The column that takes the table's spare width. One per table.
        var flexible: Bool
        /// The column steps out while the table is narrower than this.
        var hiddenBelow: CGFloat?

        init(id: String, title: String, width: CGFloat, minWidth: CGFloat? = nil,
             flexible: Bool = false, hiddenBelow: CGFloat? = nil) {
            self.id = id
            self.title = title
            self.width = width
            self.minWidth = minWidth ?? width
            self.flexible = flexible
            self.hiddenBelow = hiddenBelow
        }
    }

    enum Cell {
        /// Ink text.
        case text(String)
        /// Muted text, for a secondary fact.
        case muted(String)
        /// Monospaced muted text, for an address, a fingerprint or a command.
        case code(String)
        /// The leading cell: a tile, a bold title and an optional second line.
        /// `tintHex` is for a colour the captain chose (a saved host's own
        /// accent), the same carve-out `HelmAccentRow.Content.tintHex` makes.
        case title(String, subtitle: String?, subtitleIsCode: Bool, symbol: String?, tint: HelmTint, tintHex: String?)
        /// A state, as `HelmStatusPill`'s dot and word.
        case status(String, tint: HelmTint)
        /// The captain's own labels, as quiet tags - two, then "+N".
        case tags([String])
        /// Nothing to say: an em dash in muted ink, never a blank cell.
        case none
        /// A view the page owns, such as a live 2FA code.
        case view(NSView)
    }

    struct Action {
        let title: String
        let symbol: String?
        let run: () -> Void

        init(title: String, symbol: String? = nil, run: @escaping () -> Void) {
            self.title = title
            self.symbol = symbol
            self.run = run
        }
    }

    struct Row {
        enum Kind {
            case record(key: String)
            case group(String)
            case empty(symbol: String, title: String, body: String)
        }

        var kind: Kind
        var cells: [String: Cell] = [:]
        /// The row's one headline action ("Connect", "Run"), in the actions
        /// column. Shown on hover and on the selected row, unless the table
        /// shows its actions at rest.
        var primary: Action?
        /// Every other action. They are the row's context menu and the menu
        /// its ⋯ button opens - the same list, so neither can miss one.
        var menu: [Action] = []
        /// Always-visible controls ahead of the primary action, such as a
        /// credential's Reveal and Copy.
        var accessory: NSView?
        /// Double click and Return.
        var activate: (() -> Void)?
        /// Rows that may be reordered among themselves share a group; a drag
        /// never crosses into another one.
        var reorderGroup: String?
        /// The empty state's one action, if it has one.
        var emptyAction: Action?

        static func record(_ key: String) -> Row { Row(kind: .record(key: key)) }
        static func group(_ name: String) -> Row { Row(kind: .group(name)) }
        static func empty(symbol: String, title: String, body: String, action: Action? = nil) -> Row {
            var row = Row(kind: .empty(symbol: symbol, title: title, body: body))
            row.emptyAction = action
            return row
        }

        var key: String? {
            if case .record(let key) = kind { return key }
            return nil
        }

        var isRecord: Bool { key != nil }
    }

    // MARK: Metrics

    static let baseRecordRowHeight: CGFloat = 46
    static var recordRowHeight: CGFloat { HelmType.scaledRowHeight(baseRecordRowHeight) }
    static let baseGroupRowHeight: CGFloat = 30
    static var groupRowHeight: CGFloat { HelmType.scaledRowHeight(baseGroupRowHeight) }
    static let minimumEmptyRowHeight: CGFloat = 160
    static let headerHeight: CGFloat = 30
    /// The inset of the first and last column's content from the card edge.
    static let edgeInset: CGFloat = HelmMetrics.s4
    /// The inset between columns.
    static let cellInset: CGFloat = HelmMetrics.s2

    // MARK: State

    let card = HelmCard()

    /// The selected record's key, or `nil` when the selection is cleared or
    /// lands on nothing selectable.
    var onSelect: ((String?) -> Void)?
    /// A record was dragged to sit directly above `beforeKey`, or at the end
    /// of its group when that is `nil`.
    var onReorder: ((_ draggedKey: String, _ beforeKey: String?) -> Void)?
    /// Show every row's actions at rest rather than on hover and selection.
    var actionsAlwaysVisible = false
    /// Grow to fit every row instead of scrolling, for a table that sits in a
    /// page that already scrolls (a card among cards). Its empty state then
    /// takes `fittedEmptyRowHeight` rather than filling the card.
    var sizesToFitRows = false {
        didSet {
            scroll.hasVerticalScroller = !sizesToFitRows
            fittingHeight.isActive = sizesToFitRows
            updateFittingHeight()
        }
    }
    static let fittedEmptyRowHeight: CGFloat = 96
    private lazy var fittingHeight = scroll.heightAnchor.constraint(equalToConstant: 0)

    private let columns: [Column]
    private let actionsWidth: CGFloat
    private let reorderType: NSPasteboard.PasteboardType?
    private let table = HelmTableView()
    private let scroll = NSScrollView()
    private let header = HelmDataTableHeader()
    private let headerRule = NSView()
    private var rows: [Row] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var hoveredRow = -1
    /// Set while `setRows` puts the selection back on the same record, so
    /// that is not reported as the captain choosing it - a page that
    /// re-renders on selection would otherwise loop.
    private var isApplyingRows = false
    private var laidOutWidth: CGFloat = -1
    private var shownColumnIDs: [String] = []
    private static let actionsColumnID = "helm.actions"

    /// - Parameters:
    ///   - columns: the data columns, leading to trailing.
    ///   - actionsWidth: the trailing column that holds each row's actions.
    ///   - reorderType: a private pasteboard type, when rows may be dragged
    ///     to reorder them (`Row.reorderGroup`).
    init(columns: [Column], actionsWidth: CGFloat, reorderType: NSPasteboard.PasteboardType? = nil) {
        self.columns = columns
        self.actionsWidth = actionsWidth
        self.reorderType = reorderType
        super.init()

        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.resizingMask = []
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        let actions = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Self.actionsColumnID))
        actions.resizingMask = []
        actions.width = actionsWidth
        table.addTableColumn(actions)

        table.headerView = nil
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.backgroundColor = .clear
        // `.plain`, not `.fullWidth`: this table sizes its own columns to the
        // card's width exactly, and `.fullWidth` pads the table 6pt past each
        // end of them (measured: the table 12pt wider than its columns), which
        // scrolled every row sideways. Neither installs the source-list
        // material audit §5.2 is about.
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.floatsGroupRows = false
        table.rowHeight = Self.recordRowHeight
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowActivated)
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.setAccessibilityLabel("Table")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        if let reorderType {
            table.registerForDraggedTypes([reorderType])
            table.setDraggingSourceOperationMask(.move, forLocal: true)
            table.draggingDestinationFeedbackStyle = .gap
        }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewResized),
                                               name: NSView.frameDidChangeNotification,
                                               object: scroll.contentView)

        let tracking = HelmDataTableTracking()
        tracking.onHover = { [weak self] point in self?.pointerMoved(to: point) }
        tracking.translatesAutoresizingMaskIntoConstraints = false

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        headerRule.wantsLayer = true
        headerRule.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, headerRule, scroll, tracking] as [NSView] { body.addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: body.topAnchor),
            header.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerRule.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            headerRule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            // Over the rows only, so the pointer is tracked without taking a
            // single click from them - see `HelmDataTableTracking`.
            tracking.topAnchor.constraint(equalTo: scroll.topAnchor),
            tracking.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            tracking.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            tracking.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        ])
        card.setBody(body, insets: NSEdgeInsets(top: HelmMetrics.s1, left: 0, bottom: HelmMetrics.s1, right: 0))
        layoutColumns(force: true)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Content

    /// Show `rows`, keeping the selection on `selecting` when that record is
    /// still listed. The selection is never left on a group or empty row.
    func setRows(_ rows: [Row], selecting key: String? = nil) {
        let keep = key ?? selectedKey
        self.rows = rows
        hoveredRow = -1
        layoutColumns(force: true)
        updateFittingHeight()
        isApplyingRows = true
        defer { isApplyingRows = false }
        table.reloadData()
        if let keep, let index = rows.firstIndex(where: { $0.key == keep }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
        refreshRowStates()
    }

    /// Select the record with `key` (or clear the selection), as a click on
    /// it would, reporting it through `onSelect`.
    func select(key: String?) {
        guard let key, let index = rows.firstIndex(where: { $0.key == key }) else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    var selectedKey: String? {
        let row = table.selectedRow
        guard row >= 0, row < rows.count else { return nil }
        return rows[row].key
    }

    /// Put the keyboard in the table, on the selected row.
    func focus() { table.window?.makeFirstResponder(table) }

    func scrollToTop() { table.scrollRowToVisible(0) }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        header.applyTheme(theme)
        headerRule.layer?.backgroundColor = HelmFlatList.hairRowColor(theme).cgColor
        // GL-32: a text-scale change arrives as a theme re-fire, so the fixed
        // row height is re-derived here.
        table.rowHeight = Self.recordRowHeight
        reloadKeepingSelection()
        refreshRowStates()
        updateFittingHeight()
    }

    private func updateFittingHeight() {
        guard sizesToFitRows else { return }
        fittingHeight.constant = (0..<rows.count).reduce(CGFloat(0)) { $0 + tableView(table, heightOfRow: $1) }
    }

    /// `reloadData`, with the selected record put back. Measured: a reload
    /// after a theme change left the table with no selection and posted no
    /// notification, so the page went on showing a credential's details beside
    /// a table that had silently let go of it.
    private func reloadKeepingSelection() {
        let keep = selectedKey
        isApplyingRows = true
        defer { isApplyingRows = false }
        table.reloadData()
        if let keep, let index = rows.firstIndex(where: { $0.key == keep }), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    // MARK: Columns

    /// The columns that show at `width`, and the width each one gets.
    ///
    /// A column marked `hiddenBelow` steps out below that width, and - so a
    /// page's thresholds can never be what makes the table overflow - the
    /// most optional one left (the highest `hiddenBelow`) keeps stepping out
    /// while the columns' own minimums still do not fit.
    static func layout(_ columns: [Column], actionsWidth: CGFloat, width: CGFloat) -> [(id: String, width: CGFloat)] {
        var shown = columns.filter { column in column.hiddenBelow.map { width >= $0 } ?? true }
        func minimumTotal(_ set: [Column]) -> CGFloat {
            set.reduce(0) { $0 + ($1.flexible ? $1.minWidth : $1.width) } + actionsWidth
        }
        while minimumTotal(shown) > width,
              let drop = shown.filter({ $0.hiddenBelow != nil }).max(by: { ($0.hiddenBelow ?? 0) < ($1.hiddenBelow ?? 0) }) {
            shown.removeAll { $0.id == drop.id }
        }
        let fixed = shown.filter { !$0.flexible }.reduce(0) { $0 + $1.width } + actionsWidth
        let flexibleCount = max(1, shown.filter(\.flexible).count)
        let share = max(0, width - fixed) / CGFloat(flexibleCount)
        var out = shown.map { column in
            (id: column.id, width: column.flexible ? max(column.minWidth, floor(share)) : column.width)
        }
        out.append((id: actionsColumnID, width: actionsWidth))
        return out
    }

    private func layoutColumns(force: Bool = false) {
        let width = scroll.contentView.bounds.width
        guard width > 0, force || abs(width - laidOutWidth) > 0.5 else { return }
        laidOutWidth = width
        let plan = Self.layout(columns, actionsWidth: actionsWidth, width: width)
        let shown = Set(plan.map(\.id))
        for tableColumn in table.tableColumns {
            let id = tableColumn.identifier.rawValue
            tableColumn.isHidden = !shown.contains(id)
            if let width = plan.first(where: { $0.id == id })?.width { tableColumn.width = width }
        }
        // Hand any rounding to the flexible column, so the columns end at the
        // card's edge exactly and no stock filler is ever drawn beyond them.
        let total = plan.reduce(0) { $0 + $1.width }
        if total < width, let flexible = columns.first(where: { $0.flexible && shown.contains($0.id) }),
           let tableColumn = table.tableColumns.first(where: { $0.identifier.rawValue == flexible.id }) {
            tableColumn.width += width - total
        }
        shownColumnIDs = plan.map(\.id)
        var x: CGFloat = 0
        var frames: [(title: String, x: CGFloat, width: CGFloat)] = []
        for id in shownColumnIDs {
            guard let tableColumn = table.tableColumns.first(where: { $0.identifier.rawValue == id }) else { continue }
            let title = columns.first(where: { $0.id == id })?.title ?? ""
            frames.append((title: title, x: x, width: tableColumn.width))
            x += tableColumn.width
        }
        header.setColumns(frames, edgeInset: Self.edgeInset, cellInset: Self.cellInset)
    }

    @objc private func clipViewResized() {
        // GL-20: a cheap staleness check first - the page this table is on is
        // hidden most of the time, and only a real width change costs a pass.
        guard abs(scroll.contentView.bounds.width - laidOutWidth) > 0.5 else { return }
        layoutColumns()
        if rows.contains(where: { if case .empty = $0.kind { return true }; return false }) {
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        }
    }

    // MARK: Hover, selection and actions

    private func pointerMoved(to point: NSPoint?) {
        let row: Int
        if let point {
            let local = table.convert(point, from: nil)
            row = table.row(at: local)
        } else {
            row = -1
        }
        guard row != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = row
        refreshRowState(previous)
        refreshRowState(row)
    }

    private func refreshRowStates() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) { refreshRowState(row) }
    }

    private func refreshRowState(_ row: Int) {
        guard row >= 0, row < rows.count, rows[row].isRecord else { return }
        let selected = table.selectedRowIndexes.contains(row)
        if let rowView = table.rowView(atRow: row, makeIfNecessary: false) as? HelmDataTableRowView {
            rowView.configure(selected: selected, hovered: row == hoveredRow,
                              separator: row + 1 < rows.count && rows[row + 1].isRecord, theme: theme)
        }
        if let actions = table.view(atColumn: table.column(withIdentifier: NSUserInterfaceItemIdentifier(Self.actionsColumnID)),
                                    row: row, makeIfNecessary: false) as? HelmDataTableActionsCell {
            actions.setRevealed(actionsAlwaysVisible || selected || row == hoveredRow)
        }
    }

    @objc private func rowActivated() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        rows[row].activate?()
    }

    private func menuActions(forRow row: Int) -> [Action] {
        guard row >= 0, row < rows.count, rows[row].isRecord else { return [] }
        var actions: [Action] = []
        if let primary = rows[row].primary { actions.append(primary) }
        actions += rows[row].menu
        return actions
    }

    /// The row's actions as a menu: the context menu and the ⋯ button's.
    private func fill(_ menu: NSMenu, row: Int) {
        menu.removeAllItems()
        for action in menuActions(forRow: row) {
            let item = NSMenuItem(title: action.title, action: #selector(menuItemPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = HelmDataTableActionBox(action.run)
            if let symbol = action.symbol { item.image = HelmSymbol.image(symbol, pointSize: HelmType.scaled(12)) }
            menu.addItem(item)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu, row: table.clickedRow)
    }

    @objc private func menuItemPicked(_ sender: NSMenuItem) {
        (sender.representedObject as? HelmDataTableActionBox)?.run()
    }

    private func showOverflow(forKey key: String, from button: NSView) {
        guard let row = rows.firstIndex(where: { $0.key == key }) else { return }
        let menu = NSMenu()
        fill(menu, row: row)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + HelmMetrics.s1), in: button)
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        row < rows.count && !rows[row].isRecord
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < rows.count && rows[row].isRecord
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return Self.recordRowHeight }
        switch rows[row].kind {
        case .record: return Self.recordRowHeight
        case .group: return Self.groupRowHeight
        case .empty where sizesToFitRows:
            return Self.fittedEmptyRowHeight
        case .empty:
            // The empty state fills what the other rows leave, so it is centred
            // in the card rather than pinned to its top.
            let others = rows.enumerated().reduce(CGFloat(0)) { total, pair in
                guard pair.offset != row else { return total }
                switch pair.element.kind {
                case .record: return total + Self.recordRowHeight
                case .group: return total + Self.groupRowHeight
                case .empty: return total
                }
            }
            return max(Self.minimumEmptyRowHeight, scroll.contentView.bounds.height - others)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = (tableView.makeView(withIdentifier: HelmDataTableRowView.reuseID, owner: nil) as? HelmDataTableRowView)
            ?? { let v = HelmDataTableRowView(); v.identifier = HelmDataTableRowView.reuseID; return v }()
        let isRecord = row < rows.count && rows[row].isRecord
        view.configure(selected: isRecord && tableView.selectedRowIndexes.contains(row),
                       hovered: isRecord && row == hoveredRow,
                       separator: isRecord && row + 1 < rows.count && rows[row + 1].isRecord,
                       theme: theme)
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let item = rows[row]
        switch item.kind {
        case .group(let name):
            guard tableColumn == nil else { return nil }
            let cell = reuse(HelmDataTableGroupCell.self, tableView)
            cell.configure(name: name, theme: theme)
            return cell
        case .empty(let symbol, let title, let body):
            guard tableColumn == nil else { return nil }
            let caption = title.isEmpty ? body : "\(title). \(body)"
            let cell = HelmDataTableEmptyCell(symbol: symbol, caption: caption, action: item.emptyAction)
            cell.applyTheme(theme)
            return cell
        case .record(let key):
            guard let tableColumn else { return nil }
            let id = tableColumn.identifier.rawValue
            let isFirst = shownColumnIDs.first == id
            if id == Self.actionsColumnID {
                let cell = reuse(HelmDataTableActionsCell.self, tableView)
                cell.configure(primary: item.primary, hasMenu: !item.menu.isEmpty, accessory: item.accessory,
                               theme: theme)
                cell.onOverflow = { [weak self, weak cell] in
                    guard let self, let cell else { return }
                    self.showOverflow(forKey: key, from: cell.overflowAnchor)
                }
                cell.setRevealed(actionsAlwaysVisible || tableView.selectedRowIndexes.contains(row) || row == hoveredRow)
                return cell
            }
            let leading = isFirst ? Self.edgeInset : Self.cellInset
            switch item.cells[id] ?? .none {
            case .title(let title, let subtitle, let subtitleIsCode, let symbol, let tint, let tintHex):
                let cell = reuse(HelmDataTableTitleCell.self, tableView)
                cell.configure(title: title, subtitle: subtitle, subtitleIsCode: subtitleIsCode,
                               symbol: symbol, tint: tint, tintHex: tintHex, leading: leading, theme: theme)
                return cell
            case .status(let text, let tint):
                let cell = reuse(HelmDataTableStatusCell.self, tableView)
                cell.configure(text: text, tint: tint, leading: leading, theme: theme)
                return cell
            case .tags(let tags):
                let cell = reuse(HelmDataTableTagsCell.self, tableView)
                cell.configure(tags: tags, leading: leading, theme: theme)
                return cell
            case .view(let view):
                let cell = HelmDataTableHostCell()
                cell.host(view, leading: leading)
                return cell
            case .text(let text):
                let cell = reuse(HelmDataTableTextCell.self, tableView)
                cell.configure(text: text, style: .ink, leading: leading, theme: theme)
                return cell
            case .muted(let text):
                let cell = reuse(HelmDataTableTextCell.self, tableView)
                cell.configure(text: text, style: .muted, leading: leading, theme: theme)
                return cell
            case .code(let text):
                let cell = reuse(HelmDataTableTextCell.self, tableView)
                cell.configure(text: text, style: .code, leading: leading, theme: theme)
                return cell
            case .none:
                let cell = reuse(HelmDataTableTextCell.self, tableView)
                cell.configure(text: "\u{2014}", style: .muted, leading: leading, theme: theme)
                return cell
            }
        }
    }

    private func reuse<T: NSView>(_ type: T.Type, _ tableView: NSTableView) -> T {
        let id = NSUserInterfaceItemIdentifier(String(describing: type))
        if let view = tableView.makeView(withIdentifier: id, owner: nil) as? T { return view }
        let view = T(frame: .zero)
        view.identifier = id
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !isApplyingRows { onSelect?(selectedKey) }
        refreshRowStates()
    }

    // MARK: Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let reorderType, row < rows.count, let key = rows[row].key, rows[row].reorderGroup != nil else { return nil }
        let item = NSPasteboardItem()
        item.setString(key, forType: reorderType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above, let key = draggedKey(info),
              let group = reorderGroup(ofKey: key), reorderGroup(atBoundary: row) == group else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard dropOperation == .above, let key = draggedKey(info),
              let group = reorderGroup(ofKey: key), reorderGroup(atBoundary: row) == group else { return false }
        let before = row < rows.count && rows[row].isRecord && rows[row].reorderGroup == group ? rows[row].key : nil
        onReorder?(key, before)
        return true
    }

    private func draggedKey(_ info: NSDraggingInfo) -> String? {
        guard let reorderType else { return nil }
        return info.draggingPasteboard.string(forType: reorderType)
    }

    private func reorderGroup(ofKey key: String) -> String? {
        rows.first { $0.key == key }?.reorderGroup
    }

    /// The group whose records bracket a drop between rows: the record just
    /// before the boundary, else the one at it (the top of a group, where the
    /// header sits before it).
    private func reorderGroup(atBoundary boundary: Int) -> String? {
        if boundary > 0, boundary - 1 < rows.count, let group = rows[boundary - 1].reorderGroup { return group }
        if boundary < rows.count, let group = rows[boundary].reorderGroup { return group }
        return nil
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugTable: NSTableView { table }
    var debugRows: [Row] { rows }
    var debugShownColumnIDs: [String] { shownColumnIDs }
    var debugHeaderTitles: [String] { header.debugTitles }
    func debugColumnWidth(_ id: String) -> CGFloat? {
        table.tableColumns.first { $0.identifier.rawValue == id && !$0.isHidden }?.width
    }
    /// The record row with `key`, through the same selection path a click
    /// takes.
    func debugSelect(key: String?) { select(key: key) }
    func debugSelect(titled title: String) -> Bool {
        for (index, row) in rows.enumerated() where row.isRecord {
            if case .title(let text, _, _, _, _, _)? = row.cells.values.first(where: {
                if case .title = $0 { return true }; return false
            }), text == title {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                return true
            }
        }
        return false
    }
    /// The live actions cell of the row with `key`.
    func debugActionsCell(key: String) -> HelmDataTableActionsCell? {
        guard let row = rows.firstIndex(where: { $0.key == key }) else { return nil }
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier(Self.actionsColumnID))
        return table.view(atColumn: column, row: row, makeIfNecessary: true) as? HelmDataTableActionsCell
    }
    /// The row's menu, as a right click builds it.
    func debugMenuTitles(key: String) -> [String] {
        guard let row = rows.firstIndex(where: { $0.key == key }) else { return [] }
        let menu = NSMenu()
        fill(menu, row: row)
        return menu.items.map(\.title)
    }
    /// Pick one item of the row's menu, through the item's own target and
    /// action.
    func debugPickMenuItem(key: String, title: String) -> Bool {
        guard let row = rows.firstIndex(where: { $0.key == key }) else { return false }
        let menu = NSMenu()
        fill(menu, row: row)
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { return false }
        return NSApp?.sendAction(action, to: item.target, from: item) ?? {
            _ = (item.target as? NSObject)?.perform(action, with: item)
            return true
        }()
    }
    /// Return on the selected row, the way the keyboard sends it.
    func debugActivateSelected() {
        guard table.selectedRow >= 0 else { return }
        rows[table.selectedRow].activate?()
    }
    func debugHover(key: String?) {
        let row = key.flatMap { k in rows.firstIndex { $0.key == k } } ?? -1
        let previous = hoveredRow
        hoveredRow = row
        refreshRowState(previous)
        refreshRowState(row)
    }
    #endif
}

/// A closure, as an `NSMenuItem`'s represented object.
private final class HelmDataTableActionBox: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

// MARK: - Pointer tracking

/// Tracks the pointer over the rows and returns `nil` from `hitTest`, so it
/// never takes a click, a drag or a scroll from the table under it. The row
/// under the pointer shows its actions, as the prototype's rows do.
private final class HelmDataTableTracking: NSView {
    var onHover: ((NSPoint?) -> Void)?
    private var area: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                         .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseMoved(with event: NSEvent) { onHover?(event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { onHover?(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
}

// MARK: - Header

/// The column titles, at the x positions the table gave its columns.
private final class HelmDataTableHeader: NSView {
    private var labels: [NSTextField] = []
    private var frames: [(title: String, x: CGFloat, width: CGFloat)] = []
    private var edgeInset: CGFloat = 0
    private var cellInset: CGFloat = 0
    private var theme: HelmTheme = ThemeManager.shared.theme

    override var isFlipped: Bool { true }

    func setColumns(_ frames: [(title: String, x: CGFloat, width: CGFloat)], edgeInset: CGFloat, cellInset: CGFloat) {
        self.frames = frames
        self.edgeInset = edgeInset
        self.cellInset = cellInset
        while labels.count < frames.count {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
            labels.append(label)
        }
        for (index, label) in labels.enumerated() {
            label.isHidden = index >= frames.count
            if index < frames.count { label.stringValue = frames[index].title }
        }
        applyTheme(theme)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (index, frame) in frames.enumerated() where index < labels.count {
            let leading = index == 0 ? edgeInset : cellInset
            let label = labels[index]
            let height = label.intrinsicContentSize.height
            label.frame = NSRect(x: frame.x + leading, y: (bounds.height - height) / 2,
                                 width: max(0, frame.width - leading - cellInset), height: height)
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        for label in labels {
            label.font = .systemFont(ofSize: HelmType.scaled(11.5), weight: .medium)
            label.textColor = HelmTheme.mutedInk(theme)
        }
        needsLayout = true
    }

    var debugTitles: [String] { labels.filter { !$0.isHidden }.map(\.stringValue) }
}

// MARK: - Row view

/// Paints a record row's selection, hover and separator from the theme, in
/// place of the system highlight the table has turned off.
final class HelmDataTableRowView: NSTableRowView {
    static let reuseID = NSUserInterfaceItemIdentifier("HelmDataTableRowView")
    private var rowSelected = false
    private var hovered = false
    private var separator = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    func configure(selected: Bool, hovered: Bool, separator: Bool, theme: HelmTheme) {
        self.rowSelected = selected
        self.hovered = hovered
        self.separator = separator
        self.theme = theme
        setAccessibilitySelected(selected)
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let base = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        if rowSelected {
            (base.blended(withFraction: HelmAccentRow.selectionWash, of: accent) ?? base).setFill()
            bounds.fill()
        } else if hovered {
            HelmFlatList.rowHoverColor(theme, over: base).setFill()
            bounds.fill()
        }
        if separator, !rowSelected {
            HelmFlatList.hairRowColor(theme).setFill()
            NSRect(x: HelmDataTable.edgeInset, y: isFlipped ? bounds.maxY - 1 : 0,
                   width: max(0, bounds.width - 2 * HelmDataTable.edgeInset), height: 1).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {}

    #if FM_SELFTESTS
    var debugState: (selected: Bool, hovered: Bool, separator: Bool) { (rowSelected, hovered, separator) }
    #endif
}

// MARK: - Cells

private final class HelmDataTableTextCell: NSView {
    enum Style { case ink, muted, code }
    private let label = NSTextField(labelWithString: "")
    private var leadingConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        leadingConstraint = label.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            leadingConstraint,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmDataTable.cellInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, style: Style, leading: CGFloat, theme: HelmTheme) {
        label.stringValue = text
        label.toolTip = text.count > 24 ? text : nil
        leadingConstraint.constant = leading
        switch style {
        case .ink:
            label.font = HelmType.body()
            label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        case .muted:
            label.font = HelmType.body()
            label.textColor = HelmTheme.mutedInk(theme)
        case .code:
            label.font = HelmType.code()
            label.textColor = HelmTheme.mutedInk(theme)
        }
    }
}

private final class HelmDataTableTitleCell: NSView {
    private let tile = IconTileView(size: 26, cornerRadius: HelmMetrics.rChip)
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private var leadingConstraint: NSLayoutConstraint!
    private var titleToTile: NSLayoutConstraint!
    private var titleToEdge: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [title, subtitle] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s0
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)
        tile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        addSubview(text)
        leadingConstraint = tile.leadingAnchor.constraint(equalTo: leadingAnchor)
        titleToTile = text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HelmMetrics.s3)
        titleToEdge = text.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            leadingConstraint,
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleToTile,
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmDataTable.cellInset),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, subtitle: String?, subtitleIsCode: Bool, symbol: String?,
                   tint: HelmTint, tintHex: String?, leading: CGFloat, theme: HelmTheme) {
        self.title.stringValue = title
        self.title.font = HelmType.rowTitle()
        self.title.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        self.subtitle.stringValue = subtitle ?? ""
        self.subtitle.isHidden = (subtitle ?? "").isEmpty
        self.subtitle.font = subtitleIsCode ? HelmType.code() : HelmType.caption()
        self.subtitle.textColor = HelmTheme.mutedInk(theme)
        self.subtitle.toolTip = (subtitle ?? "").count > 30 ? subtitle : nil
        if let symbol {
            tile.isHidden = false
            tile.configure(symbol: symbol, tint: tint, pointSize: HelmType.scaled(12))
            if let tintHex { tile.overrideFill(hex: tintHex) }
            tile.applyTheme(theme)
            leadingConstraint.constant = leading
            titleToEdge.isActive = false
            titleToTile.isActive = true
        } else {
            tile.isHidden = true
            titleToTile.isActive = false
            titleToEdge.constant = leading
            titleToEdge.isActive = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
    }
}

private final class HelmDataTableStatusCell: NSView {
    private let pill = HelmStatusPill(style: .dotWord)
    private var leadingConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        leadingConstraint = pill.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            leadingConstraint,
            pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmDataTable.cellInset),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, tint: HelmTint, leading: CGFloat, theme: HelmTheme) {
        leadingConstraint.constant = leading
        pill.configure(text: text, tint: tint, theme: theme)
    }
}

/// The captain's own labels: two quiet tags, then "+N". A no-identity tag is
/// `HelmField.fill` under ink text, never a wash of `.neutral` - AGENTS.md's
/// colour rules on why that wash is a near-black chip.
private final class HelmDataTableTagsCell: NSView {
    private let stack = NSStackView()
    private var leadingConstraint: NSLayoutConstraint!
    static let shown = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = HelmMetrics.s1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        leadingConstraint = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            leadingConstraint,
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmDataTable.cellInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(tags: [String], leading: CGFloat, theme: HelmTheme) {
        leadingConstraint.constant = leading
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !tags.isEmpty else {
            let dash = NSTextField(labelWithString: "\u{2014}")
            dash.font = HelmType.body()
            dash.textColor = HelmTheme.mutedInk(theme)
            stack.addArrangedSubview(dash)
            return
        }
        for tag in tags.prefix(Self.shown) { stack.addArrangedSubview(HelmTagChip(text: tag, theme: theme)) }
        if tags.count > Self.shown {
            let more = NSTextField(labelWithString: "+\(tags.count - Self.shown)")
            more.font = HelmType.caption()
            more.textColor = HelmTheme.mutedInk(theme)
            more.toolTip = tags.dropFirst(Self.shown).joined(separator: ", ")
            stack.addArrangedSubview(more)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Tags: " + tags.joined(separator: ", "))
    }
}

/// One quiet tag: `HelmField.fill`, a hairline, and the label in muted ink.
final class HelmTagChip: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String, theme: HelmTheme) {
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = text
        label.font = HelmType.captionSmall()
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1 + HelmMetrics.s0),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(HelmMetrics.s1 + HelmMetrics.s0)),
            label.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s0),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s0),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ theme: HelmTheme) {
        layer?.cornerRadius = HelmMetrics.rChip
        layer?.backgroundColor = HelmField.fill(theme).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = HelmFlatList.hairRowColor(theme).cgColor
        label.textColor = HelmTheme.mutedInk(theme)
    }

    var text: String { label.stringValue }
}

/// Hosts a view the page owns, in a cell.
private final class HelmDataTableHostCell: NSView {
    func host(_ view: NSView, leading: CGFloat) {
        subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmDataTable.cellInset),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

/// The trailing column: a page's always-visible accessory, then the row's
/// primary action and its ⋯ menu, which show on hover and on the selected row.
final class HelmDataTableActionsCell: NSView {
    private let stack = NSStackView()
    private let primaryButton = HelmButton(title: "", variant: .secondary, size: .small)
    private let overflowButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "ellipsis")
    private var accessory: NSView?
    private var primaryRun: (() -> Void)?
    var onOverflow: (() -> Void)?
    var overflowAnchor: NSView { overflowButton }

    override init(frame: NSRect) {
        super.init(frame: frame)
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        overflowButton.target = self
        overflowButton.action = #selector(overflowClicked)
        overflowButton.toolTip = "More actions"
        overflowButton.setAccessibilityLabel("More actions")
        for button in [primaryButton, overflowButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        stack.orientation = .horizontal
        stack.spacing = HelmMetrics.s1
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(primaryButton)
        stack.addArrangedSubview(overflowButton)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmDataTable.edgeInset + HelmMetrics.s1),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(primary: HelmDataTable.Action?, hasMenu: Bool, accessory: NSView?, theme: HelmTheme) {
        if self.accessory !== accessory {
            self.accessory?.removeFromSuperview()
            self.accessory = accessory
            if let accessory {
                accessory.removeFromSuperview()
                stack.insertArrangedSubview(accessory, at: 0)
            }
        }
        primaryRun = primary?.run
        primaryButton.title = primary?.title ?? ""
        primaryButton.symbolName = primary?.symbol
        primaryButton.isHidden = primary == nil
        overflowButton.isHidden = !hasMenu && primary == nil
    }

    /// The primary action and ⋯ show on hover, on the selected row, or always.
    /// Hidden rather than faded: an off-screen render draws an `alphaValue = 0`
    /// view visibly (AGENTS.md), and a hidden control takes no click.
    func setRevealed(_ revealed: Bool) {
        primaryButton.alphaValue = 1
        overflowButton.alphaValue = 1
        let primaryHidden = primaryRun == nil
        primaryButton.isHidden = primaryHidden || !revealed
        overflowButton.isHidden = !revealed
    }

    @objc private func primaryClicked() { primaryRun?() }
    @objc private func overflowClicked() { onOverflow?() }

    #if FM_SELFTESTS
    var debugPrimaryButton: HelmButton { primaryButton }
    var debugOverflowButton: HelmButton { overflowButton }
    var debugRevealed: Bool { !overflowButton.isHidden }
    #endif
}

private final class HelmDataTableGroupCell: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmDataTable.edgeInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmDataTable.edgeInset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, theme: HelmTheme) {
        // The app's one kicker treatment (`HelmType.kickerAttributes`).
        label.attributedStringValue = NSAttributedString(
            string: name.uppercased(), attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(name)
    }
}

/// The table's empty state, as one quiet caption with its action - the
/// card-level recipe `HostsListSection` uses (UI-46).
private final class HelmDataTableEmptyCell: NSView {
    private let state: HelmEmptyState
    private let button: HelmButton?
    private let run: (() -> Void)?

    init(symbol: String, caption: String, action: HelmDataTable.Action?) {
        run = action?.run
        if let action {
            let button = HelmButton(title: action.title, variant: .secondary, size: .small, symbol: action.symbol)
            self.button = button
            state = HelmEmptyState(symbol: symbol, body: caption, size: .quiet, accessory: button)
        } else {
            button = nil
            state = HelmEmptyState(symbol: symbol, body: caption, size: .quiet)
        }
        super.init(frame: .zero)
        button?.target = self
        button?.action = #selector(actionClicked)
        state.translatesAutoresizingMaskIntoConstraints = false
        addSubview(state)
        NSLayoutConstraint.activate([
            state.centerYAnchor.constraint(equalTo: centerYAnchor),
            state.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmDataTable.edgeInset),
            state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmDataTable.edgeInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ theme: HelmTheme) { state.applyTheme(theme) }

    @objc private func actionClicked() { run?() }
}
