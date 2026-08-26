// Manjesh Grand Line - native macOS app.
//
// F11's "View History..." sheet - the Schedules card's "..." overflow menu,
// next to Run Now/Edit/Delete. Shows the last 7 days of runs for one schedule
// (`ScheduleRunHistoryStore.entries(for:)`), newest first: timestamp, verdict,
// and the same outcome summary the schedule row itself already shows for its
// single most-recent run.
//
// A small, non-form sheet in the same minimal shape
// `ShiftSnoozeCustomController` already established (forced appearance only,
// no explicit themed root layer - a real `NSWindow` sheet already paints its
// own background once appearance is forced) rather than `HelmFormSheet`:
// there is nothing to save here, this only reads.
//
// Rows are `HelmAccentRow`, matching `SchedulesCardView`'s own row component
// for the same reason that file gives - a run is a record with its own state,
// not a dense checklist item.
//
// P5 (`data/grand-line-e2e-audit/report.md`): they live in a **table view**,
// not a plain `NSStackView` of one permanent row per entry. 7-day retention
// with a frequent schedule (or heavy "Run Now" use) reaches hundreds of rows,
// and this codebase has documented the `NSStackView`-of-permanent-rows
// pathology blowing up non-linearly past ~300 rows at least three times
// (`DiffResultView.swift` - 13.6s; `BlockView.swift` - 102s;
// `ReviewPRListView.swift`). Measured here before the change: 200 seeded
// entries -> 681ms to build the sheet. A table only builds row views for
// what is visible.
//
// Automatic row heights, unlike `ShiftListViews`' fixed `rowHeight`: B2 lets
// this sheet's meta line *wrap* (a real failure summary is long and this
// sheet is narrow), so a row's height genuinely varies with its content.

import AppKit

final class ScheduleHistoryController: NSViewController {

    private let schedule: AutomationSchedule
    private let historyStore: ScheduleRunHistoryStore

    /// P3 (production review, section 21): a sheet built fresh on every
    /// presentation needs its `ThemeManager` observation stored and removed in
    /// `deinit`, or it leaks a dead closure into `ThemeManager.observers` on
    /// every presentation - the same fix `ShiftSnoozeCustomController` and the
    /// six `HelmFormSheet` editors already carry.
    private var themeObservation: ThemeObservation?
    /// M5: the footer's Close button, kept so a self-test can measure where it
    /// actually lands rather than trusting the constraints that declared it.
    private weak var closeButton: HelmButton?
    private var theme: HelmTheme = ThemeManager.shared.theme

    private let table = HelmTableView()
    private var entries: [ScheduleRunHistoryEntry] = []
    private let titleLabel = NSTextField(labelWithString: "Run History")
    private let subtitleLabel = NSTextField(labelWithString: "")

    private static let columnID = NSUserInterfaceItemIdentifier("scheduleHistoryCol")
    private static let rowViewID = NSUserInterfaceItemIdentifier("scheduleHistoryRow")
    private static let emptyViewID = NSUserInterfaceItemIdentifier("scheduleHistoryEmpty")

    init(schedule: AutomationSchedule, historyStore: ScheduleRunHistoryStore = .shared) {
        self.schedule = schedule
        self.historyStore = historyStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 480))
        view = root
        themeObservation = ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.theme = theme
            self?.applyChromeTheme()
            // B8: re-colour the sheet's own chrome, not only its rows. The
            // subtitle used to be coloured once from whatever theme was
            // current at build time and never again, so a theme switch while
            // the sheet was open left the heading in the old theme's ink.
            self?.table.reloadData()
        }

        titleLabel.font = HelmType.sectionTitle()

        subtitleLabel.stringValue = schedule.action.title
        subtitleLabel.font = HelmType.caption()
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.autoresizingMask = [.width]
        // A wrapping meta line means a row's height is content-dependent.
        table.usesAutomaticRowHeights = true
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let close = HelmButton(title: "Close", variant: .primary, target: self, action: #selector(closeClicked))
        closeButton = close
        close.keyEquivalent = "\r"
        // M5 (gotchas 10 + 12): this row is `[flexible spacer, Close]` pinned
        // to the sheet's full width, so *something* has to absorb the slack.
        // It used to be left at the default `.gravityAreas` distribution with
        // the plan resting on `spacer.setContentHuggingPriority` - a documented
        // no-op on a bare `NSView`, which has no intrinsic content size - and
        // no hugging on the button at all, so who grew was Auto Layout
        // tie-breaking. That is the exact nondeterministic shape behind the
        // Updates-chevron, Bootstrap-row and Hosts-"Connect ~900pt wide"
        // incidents. `.fill` plus a real (low-priority, so it yields rather
        // than fighting the width tie) zero-width constraint on the spacer and
        // `.required` hugging on the button makes the button's own width the
        // only stable answer.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
        close.setContentHuggingPriority(.required, for: .horizontal)
        close.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NSStackView(views: [spacer, close])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, subtitleLabel, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        applyChromeTheme()
        rebuild()
    }

    /// B8: everything on this sheet that carries a theme-derived colour and is
    /// not rebuilt by `reloadData()`.
    private func applyChromeTheme() {
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
    }

    private func rebuild() {
        entries = historyStore.entries(for: schedule.id)
        table.reloadData()
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    @objc private func closeClicked() {
        #if FM_SELFTESTS
        debugCloseRequests += 1
        #endif
        // `dismiss(_:)` raises rather than no-opping when nothing presented
        // this controller (measured, contrary to the "documented no-op" note
        // in AGENTS.md gotcha 6), so the sheet says what it needs rather than
        // trusting its own presentation state.
        guard presentingViewController != nil else { return }
        dismiss(self)
    }

    /// M6: every sibling sheet in this app pairs Return with Escape
    /// (`ShiftSnoozeCustomController`, `PortForwardingController`, both Vault
    /// sheets, and `HelmFormSheet.setFooter` for all nine form sheets). This
    /// one - deliberately not a `HelmFormSheet`, since it is read-only and has
    /// nothing to save - shipped only the Return half, so a keyboard user had
    /// to tab to Close. `cancelOperation` rather than a second key equivalent:
    /// there is one dismissal path, and it is the button's own action.
    override func cancelOperation(_ sender: Any?) {
        closeClicked()
    }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// M6: how many times a dismissal was actually requested, so a test can
    /// tell an Escape that routes to Close from one that does nothing
    /// (`dismiss(_:)` is a documented no-op on a sheet that was never
    /// presented, so its effect is not observable on its own).
    var debugCloseRequests = 0
    var debugRowCount: Int { entries.count }
    var debugShowsEmptyState: Bool { entries.isEmpty }
    var debugTitleColor: NSColor? { titleLabel.textColor }
    /// M5: the real Close button and the row it lives in, so a test measures
    /// resolved frames rather than the constraints that were declared.
    var debugFooterFrames: (footer: NSRect, close: NSRect)? {
        guard let close = closeButton, let footer = close.superview else { return nil }
        return (footer.frame, close.frame)
    }
    var debugSubtitleColor: NSColor? { subtitleLabel.textColor }
    /// The real row view the table produces for `row`, so a test measures what
    /// the captain sees rather than a fixture.
    func debugRowView(at row: Int) -> NSView? {
        self.tableView(table, viewFor: table.tableColumns.first, row: row)
    }
    #endif
}

// MARK: - Table data

extension ScheduleHistoryController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { max(entries.count, 1) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !entries.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? HelmEmptyState)
                ?? {
                    let v = HelmEmptyState(symbol: "clock.badge.questionmark",
                                           body: "No runs recorded in the last 7 days.")
                    v.identifier = Self.emptyViewID
                    return v
                }()
            empty.applyTheme(theme)
            return empty
        }
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? HelmAccentRow)
            ?? {
                let v = HelmAccentRow(hover: false)
                v.identifier = Self.rowViewID
                return v
            }()
        let entry = entries[row]
        rowView.configure(HelmAccentRow.Content(
            tint: entry.verdict.tint,
            kicker: entry.verdict.label,
            title: Self.timestampFormatter.string(from: entry.at),
            meta: entry.summary,
            badgeSymbol: entry.verdict.symbol,
            // B2: a real failure summary ("gh api: 502 from GitHub while
            // checking fork drift, will retry...") is long, this sheet is
            // 460pt wide, and it is a read-only browsing surface with vertical
            // room - so the whole sentence beats an ellipsis here. The width
            // ties in `HelmAccentRow` are what stop it clipping mid-glyph
            // either way.
            metaWraps: true
        ), theme: theme)
        return rowView
    }
}
