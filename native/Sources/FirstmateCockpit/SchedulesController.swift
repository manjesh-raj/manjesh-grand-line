// Manjesh Grand Line - native macOS app.
//
// The `.schedules` rail destination (fm/grandline-schedules-sidebar-move).
//
// F11 originally shipped the "Schedules" card nested inside the Automation
// page, itself only reachable via the Setup flyout - two hops from the rail
// (hover/click Setup, then scroll past the pipeline stepper). The captain's
// own correction: a captain who wants to check on a schedule, or add one,
// should not have to know a flyout exists. This gives Schedules its own rail
// icon, directly visible in the sidebar, with no flyout or sub-page step.
//
// This is a presentation-layer move, not a rewrite: `SchedulesCardView`,
// `ScheduleStore`, `ScheduleRunner` and `AutomationSchedule` are all
// untouched. `AutomationController`'s "Run Automation" pipeline stepper
// (Firstmate home / Dotfiles / Agent instructions / Software checklist /
// Restore config) is unaffected and stays exactly where it was, behind the
// Setup flyout.
//
// Placement: the utility group (`RailDestination.isDailyUse == false`),
// alongside Tools/Vault/Dictation/Docs - a schedule "runs itself and reports
// to Health" (per `ScheduleRunner.swift`'s own header) rather than something
// a captain checks in on daily, which is the same criterion that already
// keeps Vault/Docs/Tools out of the daily-use `navStack` group.

import AppKit

final class SchedulesController: NSViewController, DaylightDrillActions {

    private let scheduleStore: ScheduleStore

    init(scheduleStore: ScheduleStore) {
        self.scheduleStore = scheduleStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var scrollView: NSScrollView!

    /// The card itself - see `SchedulesCardView`'s own header for why it is a
    /// self-contained view (owning rendering, deciding nothing) rather than
    /// business logic that belongs on this controller.
    private let schedulesCard = SchedulesCardView()

    /// Set by `AppShellController` - "re-read my subtitle". The header is the
    /// shell's; this page only says when its numbers moved.
    var onDrillSubtitleChanged: (() -> Void)?

    // MARK: Drill header (Daylight §6.4)

    /// Counted off the same `ScheduleStore` array the rows below render, and
    /// off `ScheduleRunner`'s own "is one running" state - so the header and
    /// the rows can never disagree, and nothing new is read to produce it.
    var drillHeaderSubtitle: String? {
        let all = scheduleStore.schedules
        guard !all.isEmpty else { return "No schedules yet" }
        let noun = all.count == 1 ? "1 schedule" : "\(all.count) schedules"
        if ScheduleRunner.shared.runningScheduleID != nil { return "\(noun) \u{00B7} one running now" }
        let paused = all.filter { !$0.isEnabled }.count
        let failing = all.filter { $0.isEnabled && $0.lastRun?.verdict == .failed }.count
        let needsYou = all.filter { $0.isEnabled && $0.lastRun?.verdict == .changed }.count
        var parts = [noun]
        if failing > 0 { parts.append("\(failing) failing") }
        if needsYou > 0 { parts.append("\(needsYou) needs you") }
        if paused > 0 { parts.append("\(paused) paused") }
        if failing == 0 && needsYou == 0 && paused == 0 { parts.append("all running on their own") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// §6.4's action cluster: this page's one primary action, hoisted out of
    /// the card header. Caller-owned - `SchedulesCardView` still owns the
    /// button and its handler.
    var drillHeaderActions: [NSView] { [schedulesCard.addButton] }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 720))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.refreshSchedules()
        }

        // The page-level explanatory line is gone (Daylight §6.4): the drill
        // header above now names the destination and carries its live numbers,
        // the card header states where runs are logged, and the empty state
        // says the same sentence this label did, verbatim, at the one moment a
        // captain actually needs it.
        let schedulesCardView = buildSchedulesCard()

        let stack = NSStackView(views: [schedulesCardView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            schedulesCardView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // AGENTS.md gotcha #4: pin the document view to the *clip* view,
            // never the outer scroll view - see `AutomationController`'s
            // identical comment for the full reasoning.
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scrollView = scroll
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshSchedules()
        scrollToTop()
    }

    private func scrollToTop() {
        guard let scroll = scrollView else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Schedules (F11)

    /// Wires `SchedulesCardView`'s closures - every one of them is a decision
    /// that needs either a store write or a sheet presentation, which is
    /// exactly the split between that view and this controller. Moved here
    /// verbatim from `AutomationController.buildSchedulesCard()`.
    private func buildSchedulesCard() -> NSView {
        schedulesCard.onNewSchedule = { [weak self] in self?.presentScheduleEditor(editing: nil) }
        schedulesCard.onEditSchedule = { [weak self] schedule in self?.presentScheduleEditor(editing: schedule) }
        schedulesCard.onDeleteSchedule = { [weak self] schedule in self?.confirmDeleteSchedule(schedule) }
        schedulesCard.onRunNow = { [weak self] schedule in
            ScheduleRunner.shared.runNow(schedule)
            self?.refreshSchedules()
        }
        schedulesCard.onToggleEnabled = { [weak self] schedule, enabled in
            guard let self else { return }
            self.scheduleStore.setEnabled(enabled, id: schedule.id)
            // Pausing a schedule should also retire whatever its last run left
            // in the notification center - a paused schedule reporting drift
            // it will not re-check is a stale claim.
            if !enabled {
                NotificationSources.clearScheduleResult(scheduleID: schedule.id)
            }
            self.refreshSchedules()
        }
        // The runner is what knows a run just finished; the card re-reads the
        // store rather than being handed a result, so there is one source of
        // truth for what a row shows.
        // The card re-renders on every store change and every run-state
        // change; the header's own line has to follow the same signal.
        schedulesCard.onStateChanged = { [weak self] in self?.onDrillSubtitleChanged?() }
        ScheduleRunner.shared.onRunStateChanged = { [weak self] _ in self?.refreshSchedules() }
        scheduleStore.onChange = { [weak self] in self?.refreshSchedules() }
        refreshSchedules()
        return schedulesCard.card
    }

    private func refreshSchedules() {
        guard isViewLoaded else { return }
        schedulesCard.setSchedules(scheduleStore.schedules,
                                   runningID: ScheduleRunner.shared.runningScheduleID,
                                   theme: theme)
    }

    private func presentScheduleEditor(editing: AutomationSchedule?) {
        let editor = ScheduleEditorController(schedule: editing)
        editor.onSave = { [weak self] schedule in
            guard let self else { return }
            if editing == nil {
                self.scheduleStore.add(schedule)
                Toast.show(in: self.view, message: "Schedule created")
            } else {
                self.scheduleStore.update(schedule)
                Toast.show(in: self.view, message: "Schedule saved")
            }
            self.refreshSchedules()
        }
        editor.onDelete = { [weak self] id in
            guard let self else { return }
            self.scheduleStore.delete(id: id)
            NotificationSources.clearScheduleResult(scheduleID: id)
            self.refreshSchedules()
        }
        presentAsSheet(editor)
    }

    /// A schedule is cheap to recreate, but deleting one silently on a menu
    /// click would still be a surprise - and this app confirms every other
    /// record delete (see `HostsController`'s own confirm alert).
    #if FM_SELFTESTS
    /// The card this page renders - so a suite can read the real time/tick
    /// columns it built rather than re-deriving them.
    var debugSchedulesCard: SchedulesCardView? { isViewLoaded ? schedulesCard : nil }
    #endif

    private func confirmDeleteSchedule(_ schedule: AutomationSchedule) {
        let alert = NSAlert()
        alert.messageText = "Delete this schedule?"
        alert.informativeText = "\(schedule.action.title) will stop running on its own. "
            + "The action itself stays available to run by hand on its own page."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        scheduleStore.delete(id: schedule.id)
        NotificationSources.clearScheduleResult(scheduleID: schedule.id)
        refreshSchedules()
    }
}
