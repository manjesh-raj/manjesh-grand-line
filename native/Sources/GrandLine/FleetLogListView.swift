// Grand Line - native macOS app.
//
// F6's list body: the reverse-chronological event feed on Crew's "Log" tab.
//
// UX-07 of the 2026-11-25 review: a compact timeline in one card rather than
// a stack of 60pt cards. One line per event under its day and hour headings,
// and a run of the same kind folded into one line ("Created 8 tasks"), which
// Show all opens in place. Ten "Created ..." events from one minute filled
// the window; they are one line now.
//
// A single-column, view-based `NSTableView`, not an `NSStackView` of permanent
// rows - the same choice, for the same measured reason, as
// `ReviewPRListView`/`DiffResultView`/`BlockContainerView` before it (see `ReviewPRListView.swift`'s header for the full history: an
// `NSStackView` of a few hundred nested rows has blown this app's main thread
// up by 13 and then 102 seconds, twice). A history feed is the one list here
// that only ever grows, so it is exactly the shape that would hit it again.
//
// Like `ReviewPRListView`, this owns no scroller of its own: Overview's page
// is already one outer `NSScrollView`, so the table is sized to its own full
// content height and left for that to carry.

import AppKit

/// A day heading ("TODAY") or an hour heading ("11 AM"), with a hairline
/// above an hour that follows another.
private final class FleetLogHeadingCellView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let rule = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        addSubview(label)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ text: String, isDay: Bool, showsRule: Bool, theme: HelmTheme) {
        label.stringValue = text.uppercased()
        label.font = isDay ? HelmType.kicker() : .systemFont(ofSize: HelmType.scaled(10.5), weight: .semibold)
        label.textColor = HelmTheme.mutedInk(theme)
        rule.isHidden = !showsRule
        rule.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
    }
}

/// One line: the time, the kind's dot and what happened. A folded run says
/// its count in bold and offers Show all (or Hide).
private final class FleetLogLineCellView: NSView {
    private let time = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let text = NSTextField(labelWithString: "")
    let toggle = HelmButton(title: "", variant: .quiet, size: .small)
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        time.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(11.5), weight: .regular)
        time.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = FleetLogListView.dotSide / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [time, dot, text, toggle] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            time.leadingAnchor.constraint(equalTo: leadingAnchor),
            time.centerYAnchor.constraint(equalTo: centerYAnchor),
            time.widthAnchor.constraint(equalToConstant: FleetLogListView.timeColumnWidth),
            dot.leadingAnchor.constraint(equalTo: time.trailingAnchor, constant: HelmMetrics.s3),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: FleetLogListView.dotSide),
            dot.heightAnchor.constraint(equalToConstant: FleetLogListView.dotSide),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: HelmMetrics.s2 + 2),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: HelmMetrics.s2),
            toggle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func toggled() { onToggle?() }

    func configure(event: FleetLogEvent, indented: Bool, theme: HelmTheme) {
        time.stringValue = indented ? "" : FleetLogFeed.time(for: event)
        let attributed = NSAttributedString(string: event.title, attributes: [
            .font: NSFont.systemFont(ofSize: HelmType.scaled(13)),
            .foregroundColor: HelmTheme.nsColor(theme.chromeInkHex),
        ])
        apply(attributed, tint: event.kind.tint, theme: theme)
        text.toolTip = event.title
        toggle.isHidden = true
        setAccessibilityLabel("\(FleetLogFeed.time(for: event)), \(event.title)")
    }

    func configure(run: FleetLogFeed.Run, theme: HelmTheme) {
        guard let first = run.events.first else { return }
        time.stringValue = FleetLogFeed.time(for: first)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let font = NSFont.systemFont(ofSize: HelmType.scaled(13))
        let line = NSMutableAttributedString(string: "\(run.verb) ", attributes: [.font: font, .foregroundColor: ink])
        line.append(NSAttributedString(string: run.countPhrase, attributes: [
            .font: NSFont.systemFont(ofSize: HelmType.scaled(13), weight: .semibold), .foregroundColor: ink,
        ]))
        if run.events.count <= FleetLogFeed.Run.namesShownUpTo {
            line.append(NSAttributedString(string: ": " + run.names.joined(separator: ", "),
                                           attributes: [.font: font, .foregroundColor: ink]))
        }
        apply(line, tint: first.kind.tint, theme: theme)
        text.toolTip = run.names.joined(separator: "\n")
        let opens = run.events.count > FleetLogFeed.Run.namesShownUpTo || run.isExpanded
        toggle.isHidden = !opens
        toggle.title = run.isExpanded ? "Hide" : "Show all"
        toggle.setAccessibilityLabel(run.isExpanded ? "Hide the \(run.countPhrase)" : "Show all \(run.countPhrase)")
        setAccessibilityLabel("\(FleetLogFeed.time(for: first)), \(run.text)")
    }

    private func apply(_ attributed: NSAttributedString, tint: HelmTint, theme: HelmTheme) {
        text.attributedStringValue = attributed
        time.textColor = HelmTheme.mutedInk(theme)
        let card = HelmTheme.nsColor(theme.chromeBackgroundHex)
        dot.layer?.backgroundColor = HelmContrast.legibleOn(fill: card, preferring: HelmTheme.nsColor(tint.hex(in: theme)),
                                                            target: HelmContrast.nonTextTarget).cgColor
    }
}

final class FleetLogListView: NSView {

    /// UX-07's line heights, at chrome text scale 1.0 (`HelmType.scaledRowHeight`).
    static let baseLineHeight: CGFloat = 26
    static var lineHeight: CGFloat { HelmType.scaledRowHeight(baseLineHeight) }
    static var dayHeight: CGFloat { HelmType.scaledRowHeight(26) }
    static var hourHeight: CGFloat { HelmType.scaledRowHeight(24) }
    /// Kept for the suites that size a feed: one line's height.
    static var eventRowHeight: CGFloat { lineHeight }
    static let rowSpacing: CGFloat = 2
    static let emptyRowHeight: CGFloat = 180
    static let timeColumnWidth: CGFloat = 52
    static let dotSide: CGFloat = 7
    /// The card's padding around the timeline.
    static let padding = NSEdgeInsets(top: HelmMetrics.s3, left: HelmMetrics.s4, bottom: HelmMetrics.s3,
                                      right: HelmMetrics.s4)

    let tableView = NSTableView()

    private var events: [FleetLogEvent] = []
    private var rows: [FleetLogFeed.TimelineRow] = []
    /// The runs the captain opened with Show all.
    private var expanded: Set<String> = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var tableHeight: NSLayoutConstraint!
    private var emptyTitle = "Nothing logged yet"
    private var emptyBody = ""

    /// The filter's segments: Today and All (UX-07: each says its scope),
    /// then one per kind, in `FleetLogEventKind`'s own declaration order.
    /// Lives here rather than on `FleetLogFeed` because
    /// `HelmSegmentedTabs.Item` is AppKit and that file is deliberately
    /// AppKit-free.
    static let allFilterID = "all"
    static let todayFilterID = "today"

    static var filterItems: [HelmSegmentedTabs.Item] {
        [.init(id: todayFilterID, title: "Today"), .init(id: allFilterID, title: "All")]
            + FleetLogEventKind.allCases.map { .init(id: $0.rawValue, title: $0.pluralTitle) }
    }

    /// `nil` for Today, All (and for an id that is not a kind, which can only
    /// mean the pill list and this mapping drifted).
    static func kind(forFilterID id: String) -> FleetLogEventKind? {
        id == allFilterID || id == todayFilterID ? nil : FleetLogEventKind(rawValue: id)
    }

    private static let columnID = NSUserInterfaceItemIdentifier("fleetLogColumn")
    private static let lineViewID = NSUserInterfaceItemIdentifier("fleetLogLine")
    private static let headingViewID = NSUserInterfaceItemIdentifier("fleetLogHeading")
    private static let emptyViewID = NSUserInterfaceItemIdentifier("fleetLogEmpty")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // `.plain`, as `HelmDataTable`'s: the default style resolves to
        // `.inset` and pads the rows with 10pt the height below never knew
        // about (see `recomputeHeight`).
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: Self.rowSpacing)
        tableView.rowHeight = Self.lineHeight
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tableView)
        let height = tableView.heightAnchor.constraint(equalToConstant: Self.emptyRowHeight)
        tableHeight = height
        let p = Self.padding
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p.left),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p.right),
            tableView.topAnchor.constraint(equalTo: topAnchor, constant: p.top),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p.bottom),
            height,
        ])
        applyTheme(theme)
    }

    /// The feed, newest first. Runs keep their open or folded state across
    /// a refresh, by their first event's id.
    func setEvents(_ events: [FleetLogEvent], theme: HelmTheme, emptyTitle: String, emptyBody: String) {
        self.events = events
        self.theme = theme
        self.emptyTitle = emptyTitle
        self.emptyBody = emptyBody
        rebuildRows()
    }

    private func rebuildRows() {
        rows = FleetLogFeed.timelineRows(for: events, expanded: expanded)
        recomputeHeight()
        tableView.reloadData()
    }

    /// Show all, or Hide, on a folded run.
    func toggleRun(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        rebuildRows()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        // UX-07: the timeline is one card.
        HelmCard.applyCardSurface(to: self, theme: theme)
        // GL-32 (audit §6.1): a chrome-text-scale change arrives as an
        // app-wide theme re-fire, so re-deriving the row height here is what
        // makes a fixed-height list actually grow with the setting instead of
        // clipping its descenders at "Larger".
        tableView.rowHeight = Self.lineHeight
        recomputeHeight()
        tableView.reloadData()
    }

    private func height(of row: FleetLogFeed.TimelineRow) -> CGFloat {
        switch row {
        case .day: return Self.dayHeight
        case .hour: return Self.hourHeight
        case .event, .run: return Self.lineHeight
        }
    }

    /// The table is exactly as tall as its rows. Each row's rect is its
    /// height plus the intercell spacing, with the cell centred in it, so
    /// the sum counts one spacing per row.
    private func recomputeHeight() {
        let heights = rows.isEmpty ? [Self.emptyRowHeight] : rows.map(height(of:))
        tableHeight.constant = heights.reduce(0) { $0 + $1 + Self.rowSpacing }
    }

    // MARK: Probe / self-test surface

    var debugRowCount: Int { rows.count }
    var debugTableHeight: CGFloat { tableHeight.constant }
    #if FM_SELFTESTS
    /// What the empty state says when no row matches.
    var debugEmptyText: (title: String, body: String) { (emptyTitle, emptyBody) }
    var debugRows: [FleetLogFeed.TimelineRow] { rows }
    #endif
}

extension FleetLogListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.isEmpty ? 1 : rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.isEmpty ? Self.emptyRowHeight : height(of: rows[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !rows.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? HelmEmptyState)
                ?? {
                    let v = HelmEmptyState(symbol: "clock.arrow.circlepath", title: emptyTitle,
                                           body: emptyBody, size: .standard)
                    v.identifier = Self.emptyViewID
                    return v
                }()
            empty.setText(title: emptyTitle, body: emptyBody)
            empty.applyTheme(theme)
            return empty
        }
        func heading() -> FleetLogHeadingCellView {
            (tableView.makeView(withIdentifier: Self.headingViewID, owner: nil) as? FleetLogHeadingCellView)
                ?? { let v = FleetLogHeadingCellView(); v.identifier = Self.headingViewID; return v }()
        }
        func line() -> FleetLogLineCellView {
            (tableView.makeView(withIdentifier: Self.lineViewID, owner: nil) as? FleetLogLineCellView)
                ?? { let v = FleetLogLineCellView(); v.identifier = Self.lineViewID; return v }()
        }
        switch rows[row] {
        case .day(let text):
            let view = heading()
            view.configure(text, isDay: true, showsRule: false, theme: theme)
            return view
        case .hour(let text):
            let view = heading()
            // A hairline between two hours of one day.
            let follows = row > 0 && { if case .day = rows[row - 1] { return false } else { return true } }()
            view.configure(text, isDay: false, showsRule: follows, theme: theme)
            return view
        case .event(let event):
            let view = line()
            // An event a run opened lines up under the run, with no time.
            var inRun = false
            for earlier in rows[..<row].reversed() {
                if case .run(let run) = earlier { inRun = run.isExpanded && run.events.contains(event); break }
                if case .event = earlier { continue }
                break
            }
            view.configure(event: event, indented: inRun, theme: theme)
            return view
        case .run(let run):
            let view = line()
            view.configure(run: run, theme: theme)
            view.onToggle = { [weak self] in self?.toggleRun(run.id) }
            return view
        }
    }
}
