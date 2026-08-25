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
    private var theme: HelmTheme = ThemeManager.shared.theme

    private let rowsStack = NSStackView()

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
            self?.rebuild()
        }

        let title = NSTextField(labelWithString: "Run History")
        title.font = HelmType.sectionTitle()

        let subtitle = NSTextField(labelWithString: schedule.action.title)
        subtitle.font = HelmType.caption()
        subtitle.textColor = HelmTheme.mutedInk(theme)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        // AGENTS.md gotcha #9: a plain `NSView` document view is not flipped,
        // so a short list rests against the *bottom* of the clip view instead
        // of starting under the header.
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: content.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // AGENTS.md gotcha #4: pin the document view to the *clip* view,
            // never the outer scroll view.
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let close = HelmButton(title: "Close", variant: .primary, target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, close])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, subtitle, scroll, footer])
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

        rebuild()
    }

    private func rebuild() {
        for v in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let entries = historyStore.entries(for: schedule.id)
        guard !entries.isEmpty else {
            let empty = HelmEmptyState(
                symbol: "clock.badge.questionmark",
                body: "No runs recorded in the last 7 days."
            )
            rowsStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            return
        }

        for entry in entries {
            let row = buildRow(entry)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    private func buildRow(_ entry: ScheduleRunHistoryEntry) -> NSView {
        let row = HelmAccentRow(hover: false)
        row.configure(HelmAccentRow.Content(
            tint: entry.verdict.tint,
            kicker: entry.verdict.label,
            title: Self.timestampFormatter.string(from: entry.at),
            meta: entry.summary,
            badgeSymbol: entry.verdict.symbol,
            // B2: a real failure summary ("gh api: 502 from GitHub while
            // checking fork drift, will retry...") is long, this sheet is
            // 460pt wide, and it is a read-only browsing surface with
            // vertical room - so the whole sentence beats an ellipsis here.
            // The width ties in `HelmAccentRow` are what stop it clipping
            // mid-glyph either way.
            metaWraps: true
        ), theme: theme)
        return row
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    @objc private func closeClicked() {
        dismiss(self)
    }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugRowCount: Int { rowsStack.arrangedSubviews.count }
    var debugShowsEmptyState: Bool { rowsStack.arrangedSubviews.contains { $0 is HelmEmptyState } }
    #endif
}
