// Manjesh Grand Line - native macOS app.
//
// F6's list body: the reverse-chronological event feed on Overview's "Log"
// tab, with TODAY / YESTERDAY / dated day headers.
//
// A single-column, view-based `NSTableView`, not an `NSStackView` of permanent
// rows - the same choice, for the same measured reason, as
// `ReviewPRListView`/`DiffResultView`/`BlockContainerView`/`HostsListSection`
// before it (see `ReviewPRListView.swift`'s header for the full history: an
// `NSStackView` of a few hundred nested rows has blown this app's main thread
// up by 13 and then 102 seconds, twice). A history feed is the one list here
// that only ever grows, so it is exactly the shape that would hit it again.
//
// Like `ReviewPRListView`, this owns no scroller of its own: Overview's page
// is already one outer `NSScrollView`, so the table is sized to its own full
// content height and left for that to carry.

import AppKit

/// One event row: a `HelmAccentRow` carrying the kind's hue, a time-of-day
/// kicker and the event's one-line title, reused across table rows via
/// `makeView(withIdentifier:owner:)`.
private final class FleetLogRowCellView: NSView {
    private let accentRow = HelmAccentRow(hover: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        accentRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentRow)
        NSLayoutConstraint.activate([
            accentRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            accentRow.topAnchor.constraint(equalTo: topAnchor),
            accentRow.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ event: FleetLogEvent, theme: HelmTheme) {
        accentRow.configure(HelmAccentRow.Content(
            tint: event.kind.tint,
            kicker: FleetLogFeed.kicker(for: event),
            title: event.title,
            badgeSymbol: event.kind.symbol
        ), theme: theme)
    }
}

/// A day header row - "TODAY" / "YESTERDAY" / "Tuesday 12 August".
private final class FleetLogHeaderCellView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = HelmType.kicker()
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ text: String, theme: HelmTheme) {
        label.stringValue = text.uppercased()
        label.textColor = HelmTheme.mutedInk(theme)
    }
}

final class FleetLogListView: NSView {

    /// Fixed heights - an event row's title never wraps
    /// (`Content.titleWraps` stays false), so nothing here needs
    /// `usesAutomaticRowHeights`.
    /// Measured at chrome text scale 1.0 - see `HelmType.scaledRowHeight`.
    static let baseEventRowHeight: CGFloat = 60
    static var eventRowHeight: CGFloat { HelmType.scaledRowHeight(baseEventRowHeight) }
    static let headerRowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 6
    static let emptyRowHeight: CGFloat = 180

    let tableView = NSTableView()

    private var rows: [FleetLogFeed.Row] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var tableHeight: NSLayoutConstraint!
    private var emptyTitle = "Nothing logged yet"
    private var emptyBody = ""

    /// The mockup's filter-pill row: All plus one pill per kind, in
    /// `FleetLogEventKind`'s own declaration order. Lives here rather than on
    /// `FleetLogFeed` because `HelmSegmentedTabs.Item` is AppKit and that file
    /// is deliberately AppKit-free.
    static let allFilterID = "all"

    static var filterItems: [HelmSegmentedTabs.Item] {
        [.init(id: allFilterID, title: "All")]
            + FleetLogEventKind.allCases.map { .init(id: $0.rawValue, title: $0.pluralTitle) }
    }

    /// `nil` for the "All" pill (and for an id that is not a kind, which can
    /// only mean the pill list and this mapping drifted).
    static func kind(forFilterID id: String) -> FleetLogEventKind? {
        id == allFilterID ? nil : FleetLogEventKind(rawValue: id)
    }

    private static let columnID = NSUserInterfaceItemIdentifier("fleetLogColumn")
    private static let eventViewID = NSUserInterfaceItemIdentifier("fleetLogEventRow")
    private static let headerViewID = NSUserInterfaceItemIdentifier("fleetLogHeaderRow")
    private static let emptyViewID = NSUserInterfaceItemIdentifier("fleetLogEmpty")

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
        tableView.intercellSpacing = NSSize(width: 0, height: Self.rowSpacing)
        tableView.rowHeight = Self.eventRowHeight
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tableView)
        let height = tableView.heightAnchor.constraint(equalToConstant: Self.emptyRowHeight)
        tableHeight = height
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
    }

    func setRows(_ rows: [FleetLogFeed.Row], theme: HelmTheme, emptyTitle: String, emptyBody: String) {
        self.rows = rows
        self.theme = theme
        self.emptyTitle = emptyTitle
        self.emptyBody = emptyBody
        recomputeHeight()
        tableView.reloadData()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        // GL-32 (audit §6.1): a chrome-text-scale change arrives as an
        // app-wide theme re-fire, so re-deriving the row height here is what
        // makes a fixed-height list actually grow with the setting instead of
        // clipping its descenders at "Larger".
        tableView.rowHeight = Self.eventRowHeight
        tableView.reloadData()
    }

    private func recomputeHeight() {
        guard !rows.isEmpty else {
            tableHeight.constant = Self.emptyRowHeight
            return
        }
        let total = rows.reduce(CGFloat(0)) { sum, row in
            switch row {
            case .header: return sum + Self.headerRowHeight
            case .event: return sum + Self.eventRowHeight
            }
        }
        tableHeight.constant = total + max(0, CGFloat(rows.count) - 1) * Self.rowSpacing
    }

    // MARK: Probe / self-test surface

    var debugRowCount: Int { rows.count }
    var debugTableHeight: CGFloat { tableHeight.constant }
}

extension FleetLogListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.isEmpty ? 1 : rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard !rows.isEmpty else { return Self.emptyRowHeight }
        switch rows[row] {
        case .header: return Self.headerRowHeight
        case .event: return Self.eventRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !rows.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? HelmEmptyState)
                ?? {
                    let v = HelmEmptyState(symbol: "clock.arrow.circlepath", title: emptyTitle,
                                           body: emptyBody, size: .standard, boxed: true)
                    v.identifier = Self.emptyViewID
                    return v
                }()
            empty.setText(title: emptyTitle, body: emptyBody)
            empty.applyTheme(theme)
            return empty
        }

        switch rows[row] {
        case .header(let text):
            let view = (tableView.makeView(withIdentifier: Self.headerViewID, owner: nil) as? FleetLogHeaderCellView)
                ?? {
                    let v = FleetLogHeaderCellView()
                    v.identifier = Self.headerViewID
                    return v
                }()
            view.configure(text, theme: theme)
            return view
        case .event(let event):
            let view = (tableView.makeView(withIdentifier: Self.eventViewID, owner: nil) as? FleetLogRowCellView)
                ?? {
                    let v = FleetLogRowCellView()
                    v.identifier = Self.eventViewID
                    return v
                }()
            view.configure(event, theme: theme)
            return view
        }
    }
}
