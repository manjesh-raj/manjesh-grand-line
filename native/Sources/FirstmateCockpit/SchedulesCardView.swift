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
    private let addButton = HelmButton(title: "+ New Schedule", variant: .secondary)

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
            actions: [countBadge, addButton]
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

        let actions = NSStackView(views: [overflow, toggle])
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
        for control in [overflow, toggle] as [NSView] {
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
    var debugRowCount: Int { rowsStack.arrangedSubviews.count }
    var debugShowsEmptyState: Bool { rowsStack.arrangedSubviews.contains { $0 is HelmEmptyState } }
    func debugMenu(for schedule: AutomationSchedule) -> NSMenu { buildOverflowMenu(for: schedule) }
    func debugMetaLine(for schedule: AutomationSchedule, now: Date) -> String {
        rowContent(schedule, now: now, isRunning: schedule.id == runningScheduleID).meta ?? ""
    }
    #endif
}
