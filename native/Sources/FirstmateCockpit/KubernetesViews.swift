// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-k8s-cluster-tail`: the `.kubernetes` destination's own views -
// the Cluster browser's resource tables, its describe drawer, and the Log
// Tail's line stream.
//
// **Every list here is a demand-driven `NSTableView`, from the first line of
// the first draft, and that is not caution.** This codebase has hit the
// "an `NSStackView` of many permanent rows blows up far faster than the row
// count" pathology *four* times, each time in production: the Diff tool's
// ~13.6s Auto Layout pass at ~340 rows, Block View's ~102s at 400 blocks, the
// Review page's "stuck forever on Loading" (which was this exact bug, not a
// loading bug), and the Tools-page resize handler. `DiffResultView.swift`,
// `BlockView.swift` and `ReviewPRListView.swift` each carry the write-up. A
// Log Tail's whole job is an unbounded growing stream and a pod table on a
// busy namespace is hundreds of rows, so both are exactly the shape that
// pathology finds. The task brief says as much in as many words.
//
// Rows are fixed-height (`DiffResultView`/`HostsListSection`'s simpler
// convention) rather than `usesAutomaticRowHeights`: a log line does not wrap
// (it scrolls horizontally, like a terminal) and a resource row is one line
// of columns, so nothing here needs measurement.

import AppKit

// MARK: - Resource table

/// A generic, demand-driven multi-column table for one kubectl resource kind.
///
/// Multi-column with a real `headerView`, unlike every other table in this
/// app (all of which are single-column with `headerView = nil`): the whole
/// point of a Cluster browser is reading *columns* - restarts against age
/// against status - and a k9s-equivalent that rendered each pod as one
/// free-form row would be strictly worse than the raw `kubectl get` output it
/// replaces. `NSTableColumn` also gives the captain column resizing for free.
final class KubeResourceTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    struct Column {
        let title: String
        /// Fraction of the table's width. Fractions rather than points so the
        /// table reflows with the window; the sum should be 1.
        let widthFraction: CGFloat
        let isMonospaced: Bool
        init(_ title: String, _ widthFraction: CGFloat, monospaced: Bool = false) {
            self.title = title
            self.widthFraction = widthFraction
            self.isMonospaced = monospaced
        }
    }

    /// One rendered row: its cell strings plus the signal tint the whole row
    /// carries (a failing pod, a warning event). `tint == nil` means "no
    /// signal", drawn in ordinary ink - a colour with nothing to say is
    /// noise, the same rule Overview's stat tiles already follow.
    struct Row {
        let values: [String]
        let tint: HelmTint?
        /// Opaque caller key handed back on selection - the pod name the
        /// describe drawer needs, without this view knowing what a pod is.
        let key: String
        init(values: [String], tint: HelmTint? = nil, key: String) {
            self.values = values
            self.tint = tint
            self.key = key
        }
    }

    static let rowHeight: CGFloat = 26

    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private var columns: [Column] = []
    private var rows: [Row] = []
    #if FM_SELFTESTS
    var rowsForTests: [Row] { rows }
    var columnsForTests: [Column] { columns }
    #endif
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// Fired with a row's `key` on selection. `nil` for a table whose rows
    /// have nothing to open (Deployments, Services, Events) - and when it is
    /// `nil` the table refuses selection outright rather than highlighting a
    /// row that does nothing.
    var onSelectRow: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.rowHeight = Self.rowHeight
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Replaces the whole table. Columns are rebuilt only when they actually
    /// change - switching Pods -> Deployments does change them, but a 30s
    /// refresh of the same tab must not, or the captain's own column resizing
    /// would be discarded on every poll.
    func setContent(columns: [Column], rows: [Row], theme: HelmTheme) {
        self.theme = theme
        if self.columns.map(\.title) != columns.map(\.title) {
            self.columns = columns
            rebuildColumns()
        }
        self.rows = rows
        applyTheme(theme)
        tableView.reloadData()
    }

    private func rebuildColumns() {
        for existing in tableView.tableColumns { tableView.removeTableColumn(existing) }
        for (index, column) in columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kubeCol\(index)"))
            tableColumn.title = column.title
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            tableColumn.minWidth = 44
            tableView.addTableColumn(tableColumn)
        }
        layoutColumnWidths()
    }

    override func layout() {
        super.layout()
        layoutColumnWidths()
    }

    /// Fraction-of-width sizing, re-derived from the clip view's real width
    /// on every layout pass.
    ///
    /// The clip view, never `scroll`'s own width: with "Show scroll bars:
    /// Always" a non-overlay scroller reserves a real ~15pt track that
    /// narrows the clip view without narrowing `scroll`'s frame, so sizing
    /// off the outer view renders the last column under the scroller. That is
    /// AGENTS.md gotcha (4), caught in review rather than by inspection, and
    /// it applies to a column-width computation exactly as it does to a
    /// document view's own width tie.
    private func layoutColumnWidths() {
        let available = scroll.contentView.bounds.width - CGFloat(max(0, columns.count - 1)) * tableView.intercellSpacing.width
        guard available > 0, columns.count == tableView.tableColumns.count else { return }
        for (index, column) in columns.enumerated() {
            tableView.tableColumns[index].width = max(44, available * column.widthFraction)
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        tableView.headerView?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        tableView.reloadData()
    }

    var selectedKey: String? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return nil }
        return rows[row].key
    }

    func clearSelection() { tableView.deselectAll(nil) }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { onSelectRow != nil }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let columnIndex = tableView.tableColumns.firstIndex(of: tableColumn),
              row < rows.count, columnIndex < columns.count else { return nil }
        let cellID = NSUserInterfaceItemIdentifier("kubeCell\(columnIndex)")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = cellID
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        let column = columns[columnIndex]
        let rowModel = rows[row]
        label.stringValue = columnIndex < rowModel.values.count ? rowModel.values[columnIndex] : ""
        label.font = column.isMonospaced ? HelmType.code() : HelmType.body()
        // The signal tint reaches only the *first* column (the name), never
        // every cell: a whole row of red is louder than the fault it is
        // reporting, and the row's own values (STATUS, RESTARTS) already say
        // what is wrong. `legibleTintedText` corrects the hue against both
        // surfaces a row can land on, per `HelmContrast`'s own rule that a
        // tint is safe as a fill and is *not* automatically safe as text.
        if columnIndex == 0, let tint = rowModel.tint {
            label.textColor = HelmContrast.legibleTintedText(
                tintHex: tint.hex(in: theme),
                overAnyOf: [HelmTheme.nsColor(theme.chromeBackgroundHex), HelmTheme.nsColor(theme.backgroundHex)],
                theme: theme)
        } else {
            label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        }
        label.toolTip = label.stringValue
        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let key = selectedKey else { return }
        onSelectRow?(key)
    }
}

// MARK: - Log tail list

/// The Log Tail's own stream: one line per row, pod-coloured, demand-driven.
final class KubeLogListView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    static let rowHeight: CGFloat = 17

    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private var lines: [KubeLogLine] = []
    private var tintForPod: (String) -> HelmTint = { _ in .accent }
    private var theme: HelmTheme = ThemeManager.shared.theme

    private static let columnID = NSUserInterfaceItemIdentifier("kubeLogColumn")
    private static let cellID = NSUserInterfaceItemIdentifier("kubeLogCell")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = Self.rowHeight
        tableView.dataSource = self
        tableView.delegate = self

        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        // A log line is not wrapped - it scrolls, like the terminal it came
        // from. Wrapping would need `usesAutomaticRowHeights`, which is what
        // makes a big table expensive again.
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Replaces the visible window. `follow` scrolls to the newest line -
    /// suppressed while the captain has scrolled back, which is what makes
    /// reading an older line possible at all while a 5s poll keeps appending.
    func setLines(_ lines: [KubeLogLine], tintForPod: @escaping (String) -> HelmTint, theme: HelmTheme, follow: Bool) {
        self.lines = lines
        self.tintForPod = tintForPod
        self.theme = theme
        applyThemeChrome()
        tableView.reloadData()
        if follow, !lines.isEmpty { tableView.scrollRowToVisible(lines.count - 1) }
    }

    /// Whether the captain is currently parked at the bottom. The caller uses
    /// this to decide `follow` on the next append, so appending never yanks
    /// the view away from a line being read.
    var isScrolledToBottom: Bool {
        guard !lines.isEmpty else { return true }
        let visible = tableView.rows(in: scroll.contentView.documentVisibleRect)
        guard visible.length > 0 else { return true }
        return visible.location + visible.length >= lines.count - 1
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        applyThemeChrome()
        tableView.reloadData()
    }

    private func applyThemeChrome() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = theme.isDaylight ? HelmMetrics.dSurface : HelmMetrics.rCard
        layer?.backgroundColor = Self.surfaceColor(for: theme).cgColor
        scroll.backgroundColor = Self.surfaceColor(for: theme)
    }

    /// What a log line is drawn *on*, and therefore what every colour here is
    /// corrected against - one definition, so the fill and the correction can
    /// never disagree. Daylight's dark log card, exactly as
    /// `LogRawPaneView.surfaceColor` already does for the Log Analyzer's own
    /// raw pane (this is the second surface in the app where that token is
    /// genuinely usable; Console's is blocked because SwiftTerm paints its
    /// own cells).
    static func surfaceColor(for theme: HelmTheme) -> NSColor {
        theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.termBackground)
            : HelmTheme.nsColor(theme.backgroundHex)
    }

    static func inkColor(for theme: HelmTheme) -> NSColor {
        theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.termInk)
            : HelmTheme.nsColor(theme.chromeInkHex)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < lines.count else { return nil }
        let cell: KubeLogLineCell
        if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? KubeLogLineCell {
            cell = reused
        } else {
            cell = KubeLogLineCell()
            cell.identifier = Self.cellID
        }
        let line = lines[row]
        cell.configure(line, tint: tintForPod(line.pod), theme: theme)
        return cell
    }
}

/// One log row: a pod tag in that pod's own colour, then the line.
///
/// Built once and re-pointed at a different `KubeLogLine` on reuse
/// (`configure`), never rebuilt - `BlockRowView`/`DiffRowView`/
/// `ReviewPRRowCellView`'s established reuse shape.
private final class KubeLogLineCell: NSView {
    private let podLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [podLabel, textLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byClipping
            label.isSelectable = true
            addSubview(label)
        }
        podLabel.alignment = .right
        NSLayoutConstraint.activate([
            podLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            podLabel.widthAnchor.constraint(equalToConstant: 150),
            podLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.leadingAnchor.constraint(equalTo: podLabel.trailingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // A log line is one of potentially thousands of rows inside a table
        // inside a page that is itself tied to `bodyContainer`, and an
        // `NSTextField` resists compression at 750 by default - above
        // `NSLayoutPriorityWindowSizeStayPut` (500). A long line would
        // therefore become a floor on the whole window's width, which is
        // AGENTS.md gotcha (13) and has shipped four times in this codebase.
        // The horizontal scroller is what carries an over-long line instead.
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        podLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ line: KubeLogLine, tint: HelmTint, theme: HelmTheme) {
        let surface = KubeLogListView.surfaceColor(for: theme)
        podLabel.stringValue = shortPodName(line.pod)
        podLabel.toolTip = line.pod
        podLabel.font = HelmType.code()
        podLabel.textColor = HelmContrast.legibleTintedText(tintHex: tint.hex(in: theme), over: surface, theme: theme)

        textLabel.stringValue = line.text
        textLabel.font = HelmType.code()
        // An error line takes the semantic critical hue *over the pod hue* -
        // "this line is a problem" outranks "this line came from that pod",
        // and the pod tag on the left still says which one.
        textLabel.textColor = line.isError
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme), over: surface, theme: theme)
            : KubeLogListView.inkColor(for: theme)
        textLabel.toolTip = line.timestampText.isEmpty ? nil : "\(line.timestampText)  \(line.pod)"
    }

    /// A real pod name is `<deployment>-<replicaset-hash>-<pod-hash>`, which
    /// at full length would need a column wider than most log lines. The
    /// generated suffixes are what get dropped - the deployment prefix is the
    /// part a captain reads - and the full name is always the tooltip.
    private func shortPodName(_ name: String) -> String {
        let parts = name.split(separator: "-")
        guard parts.count > 2 else { return name }
        return parts.dropLast(2).joined(separator: "-")
    }
}

#if FM_SELFTESTS
extension KubeResourceTableView {
    /// The rows this table was actually handed - so a suite can assert what a
    /// captain *sees* (a broken pod's row carrying a signal tint) rather than
    /// only that the model classified it correctly. A regression that drops
    /// the tint on the way into the table is invisible to a model-level check.
    var debugRows: [Row] { rowsForTests }
    var debugColumnTitles: [String] { columnsForTests.map(\.title) }
}
#endif
