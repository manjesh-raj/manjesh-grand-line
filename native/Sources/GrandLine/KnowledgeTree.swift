// Grand Line - native macOS app.
//
// The Knowledge tree - the sidebar layout's one tree over Notebook, Runbooks,
// Postmortems and the Docs playbook (the later page work of the
// modular-shell migration).
//
// The prototype draws Knowledge as one tree with the page beside it. In the
// sidebar layout the shell draws this tree as a column at the leading edge of
// the Knowledge module, beside whichever of those four tabs is showing; the
// Reading list keeps its own cards, as the prototype draws it. Clicking an
// item opens that tab and that item through the page's own "open this" path -
// the same one ⌘K uses - so the tree adds a way in, never a second editor.
//
// **Where its rows come from.** The shared stores the pages themselves read
// (`NotebookStore`, `DocsRunbookStore`) and `DocsStore`, read off the main
// thread whenever Knowledge shows and whenever a Knowledge page reports an
// edit (`KnowledgeTreePage`). Not from the pages: they mount lazily (GL-37),
// so a tree fed by them would show empty groups it had never read.
//
// **Honest state.** A group it has not read yet says "Reading", one that read
// nothing says so, and the playbook says "Not synced yet" until the Updates
// page's sync has put a copy on this Mac - never an empty group that looks
// like an answer.

import AppKit

/// What a Knowledge page changed.
enum KnowledgeChange {
    /// Its list: a create, a save, a delete, a reload. The tree reads again.
    case list
    /// Only which item it shows. The tree moves its selection, and reads
    /// nothing.
    case showing
}

/// A Knowledge page the tree can open items on and follow.
protocol KnowledgeTreePage: AnyObject {
    /// The tree id of the item the page is showing (`KnowledgeTreeItem.id`),
    /// or `nil` when it shows its own list.
    var knowledgeShowingItemID: String? { get }
    /// Called after the page changed its list or the item it shows.
    var onKnowledgeChanged: ((KnowledgeChange) -> Void)? { get set }
    /// Open the item with this tree id, through the page's own open path.
    func openKnowledgeItem(id: String)
}

/// One row of the tree.
struct KnowledgeTreeItem: Equatable {
    enum Kind: Equatable {
        /// A top-level group, which is also its tab.
        case section
        /// A Notebook folder.
        case folder
        /// A page, a runbook, a postmortem or the playbook.
        case item
        /// A group's honest placeholder: still reading, or nothing there.
        case note
    }

    let id: String
    let kind: Kind
    let title: String
    let symbol: String
    /// The tab the row belongs to.
    let route: RailDestination
    var children: [KnowledgeTreeItem] = []

    static func notebookID(_ pageID: String) -> String { "notebook:\(pageID)" }
    static func runbookID(_ id: String) -> String { "runbook:\(id)" }
    static func postmortemID(_ id: String) -> String { "postmortem:\(id)" }
    static let playbookID = "docs:playbook"

    /// The store's own id inside a tree id - "runbook:abc" is "abc".
    static func storeID(_ treeID: String) -> String {
        guard let colon = treeID.firstIndex(of: ":") else { return treeID }
        return String(treeID[treeID.index(after: colon)...])
    }
}

/// The tree's rows, read from the stores.
enum KnowledgeTreeModel {

    struct Snapshot: Equatable {
        var notebook: [NotebookPage.Listing]
        var runbooks: [(id: String, title: String)]
        var postmortems: [(id: String, title: String)]
        var playbookSynced: Bool

        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.notebook == b.notebook && a.playbookSynced == b.playbookSynced
                && a.runbooks.map(\.id) == b.runbooks.map(\.id) && a.runbooks.map(\.title) == b.runbooks.map(\.title)
                && a.postmortems.map(\.id) == b.postmortems.map(\.id)
                && a.postmortems.map(\.title) == b.postmortems.map(\.title)
        }
    }

    /// Reads the stores. Safe off the main thread - the pages' own reloads
    /// already read the same stores from a background queue.
    static func read(notebook: NotebookStore, runbooks: DocsRunbookStore) -> Snapshot {
        Snapshot(notebook: notebook.listPages().map { NotebookPage.Listing(id: $0.id, title: $0.title) },
                 runbooks: runbooks.listRunbooks().map { (id: $0.id, title: $0.title) },
                 postmortems: runbooks.listPostmortems().map { (id: $0.id, title: $0.title) },
                 playbookSynced: DocsStore.isSynced)
    }

    /// The four groups, with `nil` for a snapshot not read yet.
    static func sections(_ snapshot: Snapshot?) -> [KnowledgeTreeItem] {
        func note(_ route: RailDestination, _ text: String) -> KnowledgeTreeItem {
            KnowledgeTreeItem(id: "note:\(route.rawValue)", kind: .note, title: text, symbol: "", route: route)
        }
        let reading = "Reading\u{2026}"
        var notebook = KnowledgeTreeItem(id: "section:notebook", kind: .section, title: "Notebook",
                                         symbol: "book.and.wrench", route: .notebook)
        var runbooks = KnowledgeTreeItem(id: "section:runbooks", kind: .section, title: "Runbooks",
                                         symbol: "list.bullet.rectangle", route: .runbooks)
        var postmortems = KnowledgeTreeItem(id: "section:postmortems", kind: .section, title: "Postmortems",
                                            symbol: "doc.text.magnifyingglass", route: .postmortems)
        var docs = KnowledgeTreeItem(id: "section:docs", kind: .section, title: "Docs",
                                     symbol: "book.closed", route: .docs)
        guard let snapshot else {
            for (index, route) in [RailDestination.notebook, .runbooks, .postmortems, .docs].enumerated() {
                let child = note(route, reading)
                switch index {
                case 0: notebook.children = [child]
                case 1: runbooks.children = [child]
                case 2: postmortems.children = [child]
                default: docs.children = [child]
                }
            }
            return [notebook, runbooks, postmortems, docs]
        }

        // Notebook: top-level pages first, then one folder per folder, in the
        // store's own order - the page column's arrangement.
        var top: [KnowledgeTreeItem] = []
        var folders: [String: [KnowledgeTreeItem]] = [:]
        var folderOrder: [String] = []
        for page in snapshot.notebook {
            let item = KnowledgeTreeItem(id: KnowledgeTreeItem.notebookID(page.id), kind: .item, title: page.title,
                                         symbol: "doc.text", route: .notebook)
            let folder = page.folder
            if folder.isEmpty {
                top.append(item)
            } else {
                if folders[folder] == nil { folderOrder.append(folder) }
                folders[folder, default: []].append(item)
            }
        }
        notebook.children = top + folderOrder.sorted().map { folder in
            KnowledgeTreeItem(id: "folder:\(folder)", kind: .folder, title: NotebookStore.humanise(lastComponentOf: folder),
                              symbol: "folder", route: .notebook, children: folders[folder] ?? [])
        }
        if notebook.children.isEmpty { notebook.children = [note(.notebook, "No pages yet")] }

        runbooks.children = snapshot.runbooks.map {
            KnowledgeTreeItem(id: KnowledgeTreeItem.runbookID($0.id), kind: .item, title: $0.title,
                              symbol: "list.bullet.rectangle", route: .runbooks)
        }
        if runbooks.children.isEmpty { runbooks.children = [note(.runbooks, "No runbooks yet")] }

        postmortems.children = snapshot.postmortems.map {
            KnowledgeTreeItem(id: KnowledgeTreeItem.postmortemID($0.id), kind: .item, title: $0.title,
                              symbol: "doc.text.magnifyingglass", route: .postmortems)
        }
        if postmortems.children.isEmpty { postmortems.children = [note(.postmortems, "No postmortems yet")] }

        docs.children = [snapshot.playbookSynced
            ? KnowledgeTreeItem(id: KnowledgeTreeItem.playbookID, kind: .item, title: "DevOps Playbook",
                                symbol: "book", route: .docs)
            : note(.docs, "Not synced yet")]
        return [notebook, runbooks, postmortems, docs]
    }

    /// Only the items whose title matches `query`, with the groups and
    /// folders that hold them. An empty query keeps everything.
    static func filtered(_ sections: [KnowledgeTreeItem], query: String) -> [KnowledgeTreeItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sections }
        func keep(_ item: KnowledgeTreeItem) -> KnowledgeTreeItem? {
            switch item.kind {
            case .note: return nil
            case .item: return item.title.lowercased().contains(q) ? item : nil
            case .section, .folder:
                var copy = item
                copy.children = item.children.compactMap(keep)
                return copy.children.isEmpty ? nil : copy
            }
        }
        return sections.compactMap(keep)
    }
}

extension NotebookPage {
    /// What the tree needs of a page: no content.
    struct Listing: Equatable {
        let id: String
        let title: String
        var folder: String {
            guard let slash = id.lastIndex(of: "/") else { return "" }
            return String(id[..<slash])
        }
    }
}

// MARK: - The column

final class KnowledgeTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    /// The prototype's 240pt tree column, plus its hairline.
    static let width: CGFloat = 248

    /// A row was chosen: its tab, and its item (nil for a group, which opens
    /// the tab on its own list).
    var onOpen: ((RailDestination, String?) -> Void)?

    private let notebookStore: NotebookStore
    private let runbookStore: DocsRunbookStore
    private let search = HelmSearchField(placeholder: "Search Knowledge")
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let edge = NSView()
    private var sections: [KnowledgeTreeItem] = KnowledgeTreeModel.sections(nil)
    private var shown: [KnowledgeTreeItem] = []
    private var snapshot: KnowledgeTreeModel.Snapshot?
    private var query = ""
    private var selectedID: String?
    private var readGeneration = 0
    private var isApplyingSelection = false
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?
    /// Groups the captain collapsed, kept across reloads.
    private var collapsed: Set<String> = []

    init(notebookStore: NotebookStore, runbookStore: DocsRunbookStore) {
        self.notebookStore = notebookStore
        self.runbookStore = runbookStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 600))
        root.wantsLayer = true
        view = root

        search.translatesAutoresizingMaskIntoConstraints = false
        search.onTextChanged = { [weak self] text in
            self?.query = text
            self?.applyRows()
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("knowledge"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        // `.plain`, never `.sourceList`: the source-list style installs the
        // private system-accent selection material (audit §5.2). The row view
        // paints selection from the theme instead.
        outline.style = .plain
        outline.selectionHighlightStyle = .none
        outline.intercellSpacing = NSSize(width: 0, height: HelmMetrics.s0)
        outline.indentationPerLevel = HelmMetrics.s4
        outline.rowHeight = HelmType.scaledRowHeight(28)
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // By default the outline column widens itself for indented rows, so a
        // long title in a folder ran past the column's visible edge instead of
        // truncating.
        outline.autoresizesOutlineColumn = false
        outline.setAccessibilityLabel("Knowledge")

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        edge.wantsLayer = true
        edge.translatesAutoresizingMaskIntoConstraints = false
        for view in [search, scroll, edge] as [NSView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s3),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s3),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s3),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: HelmMetrics.s2),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s2),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s2),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edge.topAnchor.constraint(equalTo: root.topAnchor),
            edge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edge.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
        ])
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        applyRows()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The outline's one column has to end at the clip's edge, or a long
        // title runs under it rather than truncating (measured: the first
        // layout left the column wider than the 248pt column).
        outline.sizeLastColumnToFit()
    }

    // MARK: Reading

    /// Read the stores again, off the main thread, and select `itemID` once
    /// they are in. Overlapping reads land in order (the newest wins).
    func reload(selecting itemID: String?) {
        _ = view
        selectedID = itemID
        applySelection()
        readGeneration &+= 1
        let generation = readGeneration
        let notebook = notebookStore
        let runbooks = runbookStore
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = KnowledgeTreeModel.read(notebook: notebook, runbooks: runbooks)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.readGeneration == generation else { return }
                self.apply(snapshot)
            }
        }
    }

    /// Select `itemID` without reading again - the page changed which item it
    /// shows.
    func select(itemID: String?) {
        selectedID = itemID
        applySelection()
    }

    private func apply(_ snapshot: KnowledgeTreeModel.Snapshot) {
        guard snapshot != self.snapshot else {
            applySelection()
            return
        }
        self.snapshot = snapshot
        sections = KnowledgeTreeModel.sections(snapshot)
        applyRows()
    }

    private func applyRows() {
        shown = KnowledgeTreeModel.filtered(sections, query: query)
        outline.reloadData()
        let filtering = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        func expand(_ items: [KnowledgeTreeItem]) {
            for item in items where !item.children.isEmpty {
                if filtering || !collapsed.contains(item.id) {
                    outline.expandItem(Box.wrap(item, in: self))
                }
                expand(item.children)
            }
        }
        expand(shown)
        applySelection()
    }

    private func applySelection() {
        guard isViewLoaded else { return }
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        guard let selectedID, let box = boxes[selectedID] else {
            outline.deselectAll(nil)
            refreshRowStates()
            return
        }
        // Open the groups above it, so the selected row is on screen.
        var parent = outline.parent(forItem: box)
        while let p = parent {
            outline.expandItem(p)
            parent = outline.parent(forItem: p)
        }
        let row = outline.row(forItem: box)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
        refreshRowStates()
    }

    // MARK: Boxes

    /// `NSOutlineView` identifies items by object identity, so each row's
    /// value rides in a stable box, kept by id across reloads.
    private var boxes: [String: Box] = [:]

    final class Box: NSObject {
        var item: KnowledgeTreeItem
        init(_ item: KnowledgeTreeItem) { self.item = item }

        static func wrap(_ item: KnowledgeTreeItem, in owner: KnowledgeTreeController) -> Box {
            if let box = owner.boxes[item.id] {
                box.item = item
                return box
            }
            let box = Box(item)
            owner.boxes[item.id] = box
            return box
        }
    }

    // MARK: NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let box = item as? Box else { return shown.count }
        return box.item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let items = (item as? Box)?.item.children ?? shown
        return Box.wrap(items[index], in: self)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let box = item as? Box else { return false }
        return !box.item.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let box = item as? Box else { return false }
        return box.item.kind == .item || box.item.kind == .section
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let box = item as? Box else { return outline.rowHeight }
        return box.item.kind == .section ? HelmType.scaledRowHeight(32) : HelmType.scaledRowHeight(28)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let view = KnowledgeTreeRowView()
        if let box = item as? Box {
            view.configure(selected: box.item.id == selectedID, selectable: box.item.kind == .item, theme: theme)
        }
        return view
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let box = item as? Box else { return nil }
        let cell = (outlineView.makeView(withIdentifier: KnowledgeTreeCell.reuseID, owner: nil) as? KnowledgeTreeCell)
            ?? KnowledgeTreeCell()
        cell.configure(box.item, theme: theme)
        return cell
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let box = notification.userInfo?["NSObject"] as? Box,
              query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        collapsed.insert(box.item.id)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let box = notification.userInfo?["NSObject"] as? Box else { return }
        collapsed.remove(box.item.id)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        refreshRowStates()
    }

    private func refreshRowStates() {
        for row in 0..<outline.numberOfRows {
            guard let box = outline.item(atRow: row) as? Box,
                  let view = outline.rowView(atRow: row, makeIfNecessary: false) as? KnowledgeTreeRowView else { continue }
            view.configure(selected: box.item.id == selectedID, selectable: box.item.kind == .item, theme: theme)
        }
    }

    /// A click opens the row: a group opens its tab, an item its page.
    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let box = outline.item(atRow: row) as? Box else { return }
        open(box.item)
    }

    private func open(_ item: KnowledgeTreeItem) {
        switch item.kind {
        case .section:
            selectedID = item.id
            applySelection()
            onOpen?(item.route, nil)
        case .item:
            selectedID = item.id
            applySelection()
            onOpen?(item.route, item.id)
        case .folder, .note:
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        // Return opens the selected row, as a click does.
        if event.keyCode == 36 || event.keyCode == 76, outline.selectedRow >= 0,
           let box = outline.item(atRow: outline.selectedRow) as? Box {
            open(box.item)
            return
        }
        super.keyDown(with: event)
    }

    private func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        view.layer?.backgroundColor = HelmTheme.sidePanelFill(theme).cgColor
        edge.layer?.backgroundColor = HelmTheme.sidePanelEdge(theme).cgColor
        outline.rowHeight = HelmType.scaledRowHeight(28)
        outline.reloadData()
        applyRows()
    }

    #if FM_SELFTESTS
    var debugSections: [KnowledgeTreeItem] { shown }
    var debugSelectedID: String? { selectedID }
    var debugSearchField: HelmSearchField { search }
    var debugHasRead: Bool { snapshot != nil }
    /// Click the row with this id, through the same open path a click takes.
    func debugOpen(id: String) -> Bool {
        guard let box = boxes[id] else { return false }
        open(box.item)
        return true
    }
    func debugSetQuery(_ text: String) {
        query = text
        applyRows()
    }
    /// Read the stores now, on this thread, for a suite.
    func debugReadNow() {
        _ = view
        apply(KnowledgeTreeModel.read(notebook: notebookStore, runbooks: runbookStore))
    }
    var debugVisibleTitles: [String] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? Box)?.item.title }
    }
    #endif
}

private final class KnowledgeTreeRowView: NSTableRowView {
    private var rowSelected = false
    private var selectable = true
    private var theme: HelmTheme = ThemeManager.shared.theme

    func configure(selected: Bool, selectable: Bool, theme: HelmTheme) {
        rowSelected = selected
        self.selectable = selectable
        self.theme = theme
        setAccessibilitySelected(selected)
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard rowSelected else { return }
        let base = HelmTheme.sidePanelFill(theme)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let fill = base.blended(withFraction: HelmAccentRow.selectionWash, of: accent) ?? base
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: HelmMetrics.s0 / 2),
                     xRadius: HelmMetrics.rControl, yRadius: HelmMetrics.rControl).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

private final class KnowledgeTreeCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("KnowledgeTreeCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var iconLeading: NSLayoutConstraint!
    private var labelToIcon: NSLayoutConstraint!
    private var labelAtEdge: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        textField = label
        imageView = icon
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1)
        labelToIcon = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: HelmMetrics.s2)
        labelAtEdge = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1)
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            labelToIcon,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.s1),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: KnowledgeTreeItem, theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        switch item.kind {
        case .section:
            icon.isHidden = true
            labelToIcon.isActive = false
            labelAtEdge.isActive = true
            label.attributedStringValue = NSAttributedString(
                string: item.title.uppercased(), attributes: HelmType.kickerAttributes(color: muted))
        case .note:
            icon.isHidden = true
            labelToIcon.isActive = false
            labelAtEdge.isActive = true
            label.font = HelmType.caption()
            label.textColor = muted
            label.stringValue = item.title
        case .folder, .item:
            icon.isHidden = false
            labelAtEdge.isActive = false
            labelToIcon.isActive = true
            icon.image = HelmSymbol.image(item.symbol, pointSize: HelmType.scaled(12))
            icon.contentTintColor = muted
            label.font = item.kind == .folder ? .systemFont(ofSize: HelmType.scaled(12.5), weight: .medium) : HelmType.body()
            label.textColor = ink
            label.stringValue = item.title
        }
        label.toolTip = item.title.count > 26 ? item.title : nil
        setAccessibilityLabel(item.title)
    }
}
