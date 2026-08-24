// Manjesh Grand Line - native macOS app.
//
// F11: the "Schedules" card on the Automation page, built to the captain-
// approved mockup - a header with an icon tile, a count, a subtitle saying
// where runs are logged, and a "+ New Schedule" action; then one row per
// schedule showing the action name, the cadence, the notify-on setting, the
// last run, and a toggle that pauses without deleting.
//
// **A plain view class rather than an extension on `AutomationController`.**
// That controller is already 886 lines, and a Swift extension cannot hold
// stored properties - which this card needs several of. The convention this
// follows instead is `HostsListSection` / `ShiftProjectDetailView`: a
// self-contained view that owns its rendering and hands every decision back
// through closures, so `AutomationController` only owns presentation (which
// needs an `NSViewController`) and knows nothing about how a row is drawn.
//
// **Rows are `HelmAccentRow`, not `ToolRowLayout`.** A schedule reads as a
// record the captain created, with its own state and its own actions - which is
// the distinction `HelmAccentRow`'s own doc comment draws against
// `ToolRowLayout`'s fixed-column checklist rows. `ToolRowLayout` is still the
// right component for the pipeline stepper directly above this card on the same
// page.
//
// **A plain `NSStackView` of rows, not an `NSTableView`.** This app's standing
// rule is a demand-driven table once a list can grow into the hundreds (see
// `ShiftListViews.swift`'s header for the measured multi-second layout blowup
// that motivated it). A schedule list is bounded by
// `ScheduledActionKind.allCases` times a handful of useful cadences - realistically
// under ten rows, never hundreds - which is the same reasoning
// `CommandLibraryViews` uses for its category rail.

import AppKit

final class SchedulesCardView: NSObject {

    /// The card to drop into the page's stack.
    let card = HelmCard()

    // MARK: Callbacks - the view decides nothing

    var onNewSchedule: (() -> Void)?
    var onEditSchedule: ((AutomationSchedule) -> Void)?
    var onDeleteSchedule: ((AutomationSchedule) -> Void)?
    var onRunNow: ((AutomationSchedule) -> Void)?
    var onToggleEnabled: ((AutomationSchedule, Bool) -> Void)?

    // MARK: State

    private var schedules: [AutomationSchedule] = []
    private var runningScheduleID: UUID?
    private var theme: HelmTheme = ThemeManager.shared.theme

    private let rowsStack = NSStackView()
    private let countBadge = NSTextField(labelWithString: "")
    /// "+ New Schedule", owned here and *positioned* by whoever hosts the card
    /// - Daylight §6.4 hoists it into the drill header, the same
    /// caller-owned-action arrangement `HealthCardView.diagnosticsButton`
    /// already uses. Still this view's button with this view's handler.
    let addButton = HelmButton(title: "+ New Schedule", variant: .secondary)

    /// Fired whenever the rendered set of schedules changes, so a host page's
    /// own live header line can follow the same signal the rows do rather than
    /// polling.
    var onStateChanged: (() -> Void)?

    override init() {
        super.init()
        buildCard()
    }

    private func buildCard() {
        countBadge.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        countBadge.translatesAutoresizingMaskIntoConstraints = false

        addButton.controlSize = .small
        addButton.target = self
        addButton.action = #selector(newScheduleClicked)
        addButton.toolTip = "Schedule one of the app's existing actions to run on its own"

        card.setHeader(
            symbol: "calendar",
            tint: .info,
            title: "Schedules",
            // The mockup's own subtitle. Both halves are literally true and
            // both are worth stating: a run is always recorded (Health), and a
            // run only ever interrupts you when its own notify setting says so.
            subtitle: "Runs log to Health \u{00B7} notify only when something needs you",
            // §6.4 hoists the add action into the drill header, so the card
            // header keeps the count and the explanatory subtitle - exactly
            // the split Hosts' three cards took in slice 2. The button
            // instance itself is unchanged and is still this view's.
            actions: [countBadge]
        )

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        card.setBody(rowsStack, insets: HelmCard.contentInsets)
    }

    // MARK: Rendering

    /// The one render path. Rows carry theme-derived colours and are rebuilt
    /// from scratch here (the list is under ten rows - see the file header),
    /// so a theme change and a data change are the same operation and there is
    /// no second path that could paint a row with a stale palette.
    func setSchedules(_ schedules: [AutomationSchedule], runningID: UUID?, theme: HelmTheme) {
        self.schedules = schedules
        self.runningScheduleID = runningID
        self.theme = theme
        card.applyTheme(theme)
        rebuild()
        onStateChanged?()
    }

    private func rebuild() {
        for v in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        countBadge.stringValue = schedules.isEmpty ? "" : "\(schedules.count)"
        countBadge.textColor = HelmTheme.mutedInk(theme)

        guard !schedules.isEmpty else {
            let empty = HelmEmptyState(
                symbol: "calendar.badge.plus",
                body: "No schedules yet. Pick one of the app's existing actions and a cadence, "
                    + "and it will run on its own \u{2014} reporting to Health, and telling you only when it matters."
            )
            rowsStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            return
        }

        let now = Date()
        for schedule in schedules {
            let row = buildRow(schedule, now: now)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    private func buildRow(_ schedule: AutomationSchedule, now: Date) -> NSView {
        let isRunning = schedule.id == runningScheduleID

        // The toggle. `NSSwitch` is the one control in this app that genuinely
        // cannot be themed (measured in Phase 2 of the UI audit: it answers
        // `false` to every tint setter it was tried with), so it renders in
        // system chrome here exactly as the six switches in Settings do.
        let toggle = NSSwitch()
        toggle.state = schedule.isEnabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier("schedule-toggle:\(schedule.id.uuidString)")
        toggle.toolTip = schedule.isEnabled ? "Pause this schedule" : "Resume this schedule"
        toggle.setAccessibilityLabel("\(schedule.action.title): \(schedule.isEnabled ? "enabled" : "paused")")

        let overflow = HelmButton(title: "", variant: .quiet, size: .small, symbol: "ellipsis")
        overflow.target = self
        overflow.action = #selector(overflowClicked(_:))
        overflow.identifier = NSUserInterfaceItemIdentifier("schedule-overflow:\(schedule.id.uuidString)")
        overflow.toolTip = "More actions"

        // §7's "mono time column + tick strings". Both live in the row's own
        // trailing cluster, which `HelmAccentRow` right-pins - which is what
        // makes the time genuinely read as a *column* (one constant x across
        // every row) rather than as a label that drifts with the title beside
        // it. Both are built from data the row already shows in prose.
        let timeColumn = timeColumnLabel(schedule)
        let ticks = tickLabel(schedule, isRunning: isRunning)
        #if FM_SELFTESTS
        debugColumns[schedule.id] = (timeColumn, ticks)
        #endif

        let actions = NSStackView(views: [timeColumn, ticks, overflow, toggle])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = HelmMetrics.s2
        // AGENTS.md gotcha (12): a content-priority call is a no-op on an
        // `NSStackView`, and `.gravityAreas` (the default) honours no hugging
        // priority at all - so without `.fill` plus stack-level hugging here
        // AND required content hugging on each control, the solver's tie-break
        // can stretch whichever of them it likes across the row.
        // `HostsListSection`'s identical `actions` stack is the reference.
        actions.distribution = .fill
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.setHuggingPriority(.required, for: .horizontal)
        actions.setClippingResistancePriority(.required, for: .horizontal)
        for control in [timeColumn, ticks, overflow, toggle] as [NSView] {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let row = HelmAccentRow(trailingAccessory: actions, hover: false)
        row.configure(rowContent(schedule, now: now, isRunning: isRunning), theme: theme)
        if let next = ScheduleDueCalculator.nextOccurrence(of: schedule.cadence, after: now, calendar: .current),
           schedule.isEnabled {
            row.toolTip = "Next run: \(Self.tooltipFormatter.string(from: next))"
        } else if !schedule.isEnabled {
            row.toolTip = "Paused \u{2014} the toggle resumes it without losing the schedule."
        }
        return row
    }

    // MARK: §7's time column and run ticks

    /// A fixed-width column so a `2:00 AM` and a `10:30 PM` line up down the
    /// list. Mono for the same reason Console's and Log Analyzer's timestamps
    /// are: proportional digits in a column read as ragged even when the
    /// frames are identical.
    static let timeColumnWidth: CGFloat = 62

    /// The cadence's own clock time - `ScheduleCadence.clockString`, the exact
    /// string `displayString` already puts in the meta line, not a second
    /// formatting of the same two integers.
    private func timeColumnLabel(_ schedule: AutomationSchedule) -> NSTextField {
        let cadence = schedule.cadence.normalized
        let label = NSTextField(labelWithString: ScheduleCadence.clockString(hour: cadence.hour,
                                                                            minute: cadence.minute))
        label.font = HelmType.code()
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.textColor = schedule.isEnabled
            ? HelmTheme.nsColor(theme.chromeInkHex)
            : HelmTheme.mutedInk(theme)
        label.toolTip = schedule.cadence.displayString
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.timeColumnWidth).isActive = true
        return label
    }

    /// §6.8's run ticks, and - exactly as slice 2 recorded for Health's - **a
    /// schedule has no run history to draw**, so this does not invent one.
    /// `AutomationSchedule` carries a single `lastRun` record, not a series,
    /// and collecting a series would be new data collection this slice
    /// forbids. So the string is one glyph for the one run on record: `\u{2713}`
    /// for a clean run, `\u{2715}` for a failed one, `\u{2022}` for a run that
    /// found something needing the captain. A schedule that has never run gets
    /// no glyph at all rather than a fabricated one.
    ///
    /// Returned as a hidden-but-present label rather than omitted, so the
    /// trailing cluster keeps the same arranged-subview count on every row and
    /// the time column above it cannot shift - an `NSStackView` drops a hidden
    /// arranged subview out of layout, which is why the *width* is held
    /// explicitly here too.
    private func tickLabel(_ schedule: AutomationSchedule, isRunning: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = HelmType.code()
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.tickColumnWidth).isActive = true
        guard !isRunning, let last = schedule.lastRun else { return label }
        let glyph: String
        switch last.verdict {
        case .clean: glyph = "\u{2713}"
        case .changed: glyph = "\u{2022}"
        case .failed: glyph = "\u{2715}"
        }
        label.stringValue = glyph
        // The shared contrast-corrected tinted text, never the raw hue as a
        // label (`HelmContrast`'s own §5.7 rule).
        label.textColor = HelmContrast.legibleTintedText(
            tintHex: last.verdict.tint.hex(in: theme),
            over: HelmTheme.nsColor(theme.chromeBackgroundHex),
            theme: theme)
        label.toolTip = "Last run: \(last.verdict.label) \u{00B7} \(last.summary)"
        return label
    }

    /// One glyph wide, so an empty tick column still holds its place.
    static let tickColumnWidth: CGFloat = 14

    /// The kicker carries the run verdict (the most glanceable signal, and the
    /// one that drives the row's hue) and the meta line carries the mockup's
    /// "cadence · notify-on · last run" trio verbatim.
    private func rowContent(_ schedule: AutomationSchedule, now: Date, isRunning: Bool) -> HelmAccentRow.Content {
        let kicker: String
        let tint: HelmTint
        if isRunning {
            kicker = "Running"
            tint = .accent
        } else if !schedule.isEnabled {
            kicker = "Paused"
            tint = .neutral
        } else if let last = schedule.lastRun {
            kicker = last.verdict.label
            tint = last.verdict.tint
        } else {
            kicker = "Not run yet"
            tint = schedule.action.tint
        }

        var meta = schedule.metaLine(now: now)
        if isRunning {
            meta = "\(schedule.cadence.displayString) \u{00B7} running now\u{2026}"
        } else if let last = schedule.lastRun, last.verdict != .clean {
            // A failure or a "found something" run has a reason worth reading
            // on the row itself, not two clicks away.
            meta += " \u{00B7} \(last.summary)"
        }

        return HelmAccentRow.Content(
            tint: tint,
            kicker: kicker,
            title: schedule.action.title,
            meta: meta,
            badgeSymbol: schedule.action.symbol
        )
    }

    private static let tooltipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: Actions

    @objc private func newScheduleClicked() {
        onNewSchedule?()
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        guard let schedule = schedule(from: sender.identifier?.rawValue, prefix: "schedule-toggle:") else { return }
        onToggleEnabled?(schedule, sender.state == .on)
    }

    @objc private func overflowClicked(_ sender: NSButton) {
        guard let schedule = schedule(from: sender.identifier?.rawValue, prefix: "schedule-overflow:") else { return }
        let menu = buildOverflowMenu(for: schedule)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4),
                   in: sender)
    }

    /// One array builds both the overflow menu and (were a context menu added)
    /// any other presentation of the same actions, so the two cannot drift -
    /// the same reasoning `HostsListSection` records for its own rows.
    private func buildOverflowMenu(for schedule: AutomationSchedule) -> NSMenu {
        let menu = NSMenu()
        // AppKit auto-enables a menu item whose target responds to its action,
        // which would silently undo the explicit disable on "Run Now" below.
        menu.autoenablesItems = false
        let runNow = NSMenuItem(title: "Run Now", action: #selector(runNowPicked(_:)), keyEquivalent: "")
        runNow.target = self
        runNow.representedObject = schedule.id.uuidString
        // A manual run while another is in flight would break the "one at a
        // time" guarantee the runner makes, so it is disabled rather than
        // silently dropped.
        runNow.isEnabled = ScheduleRunner.shared.isBusy == false
        menu.addItem(runNow)

        let edit = NSMenuItem(title: "Edit\u{2026}", action: #selector(editPicked(_:)), keyEquivalent: "")
        edit.target = self
        edit.representedObject = schedule.id.uuidString
        menu.addItem(edit)

        menu.addItem(.separator())

        let delete = NSMenuItem(title: "Delete", action: #selector(deletePicked(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = schedule.id.uuidString
        menu.addItem(delete)
        return menu
    }

    @objc private func runNowPicked(_ sender: NSMenuItem) {
        guard let schedule = schedule(fromID: sender.representedObject as? String) else { return }
        onRunNow?(schedule)
    }

    @objc private func editPicked(_ sender: NSMenuItem) {
        guard let schedule = schedule(fromID: sender.representedObject as? String) else { return }
        onEditSchedule?(schedule)
    }

    @objc private func deletePicked(_ sender: NSMenuItem) {
        guard let schedule = schedule(fromID: sender.representedObject as? String) else { return }
        onDeleteSchedule?(schedule)
    }

    private func schedule(from identifier: String?, prefix: String) -> AutomationSchedule? {
        guard let identifier, identifier.hasPrefix(prefix) else { return nil }
        return schedule(fromID: String(identifier.dropFirst(prefix.count)))
    }

    private func schedule(fromID raw: String?) -> AutomationSchedule? {
        guard let raw, let id = UUID(uuidString: raw) else { return nil }
        return schedules.first { $0.id == id }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    private var debugColumns: [UUID: (time: NSTextField, ticks: NSTextField)] = [:]
    var debugRowCount: Int { rowsStack.arrangedSubviews.count }
    /// §7's time column and tick strings, as actually rendered - the frame so
    /// a check can prove the column really is a column (one constant x down
    /// the list), the strings so it can prove a never-run schedule gets no
    /// fabricated tick. Recorded at build time rather than dug back out of the
    /// view tree, which is both cheaper and impossible to mis-index.
    func debugTrailingColumns(for id: UUID) -> (time: String, timeFrameInCard: NSRect, ticks: String)? {
        guard let recorded = debugColumns[id] else { return nil }
        return (recorded.time.stringValue,
                recorded.time.convert(recorded.time.bounds, to: card),
                recorded.ticks.stringValue)
    }
    var debugShowsEmptyState: Bool { rowsStack.arrangedSubviews.contains { $0 is HelmEmptyState } }
    func debugMenu(for schedule: AutomationSchedule) -> NSMenu { buildOverflowMenu(for: schedule) }
    func debugMetaLine(for schedule: AutomationSchedule, now: Date) -> String {
        rowContent(schedule, now: now, isRunning: schedule.id == runningScheduleID).meta ?? ""
    }
    #endif
}
