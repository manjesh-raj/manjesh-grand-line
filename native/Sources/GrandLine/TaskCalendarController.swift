// Grand Line - native macOS app.
//
// The calendar half of Tasks: Tasks' Calendar view, a child of the Tasks page
// (`ShiftController`), beside Board, List and Weekly review (tasks-calendar
// plan PR 4, the captain's decision 1A).
//
// It was Tasks' third tab (F5), then a page of its own behind the Calendar
// sidebar row (PR 542's Schedule-X page). A calendar that is a page of its
// own has none of the Tasks page's filters, its project picker or its New
// task, so it is a view of Tasks again and the sidebar row is a door to it:
// the row, the toolbar's calendar button, the Go menu's ⌘0, ⌘K and Recents
// all land on this view, and the row is lit while it shows
// (`ModuleTable.sidebarModule(for:pageTab:)`). It stays its own controller
// rather than more of the Tasks page (GL-36).
//
// What it shows is Shift's own records by their date, through the Tasks
// page's filters (`taskFilter`, `followUpFilter`): every active task, the
// finished tasks filed in the months the visible period touches (so a past
// month shows what got done in it), and every pending follow-up. Beside the
// card, the Unscheduled tray lists the open tasks with no date and pins the
// overdue ones, so no open task the filters keep is invisible here (GL-14).
// It owns none of them. A click on a task's chip, or its tray row's Pick…,
// opens the When panel beside it (`ShiftSchedulePopover`, tasks-calendar plan
// PR 5), and the panel's "Open task…" opens the same editor the Tasks page
// opens (`ShiftRecordSheets`). A projection, a finished task and a follow-up
// open their editor or notice as before. A double-click or New task opens
// New Task dated to that day, a drop or the panel writes the new date through
// the store with an Undo that restores what this controller already held
// (GL-33), and the check on a real chip or an Agenda row completes the record
// (the captain's decision 4A) with an Undo that puts it back.
//
// Day, Week, Month and Agenda are the card's own pills, the one switcher for
// the calendar's period: the window toolbar draws Tasks' views, not these.

import AppKit

final class TaskCalendarController: NSViewController {

    let store: ShiftStore
    private let calendarView = ShiftCalendarView()
    private var themeToken: ThemeObservation?

    /// The Tasks page's filters: the scope (All tasks, Due today, Overdue,
    /// My priorities, Recently updated) and the project, so a filter set on
    /// Board is the filter on the calendar too. Every task this view draws
    /// or lists, finished ones included, runs through `taskFilter`.
    var taskFilter: (ShiftTask) -> Bool = { _ in true }
    /// The project filter for follow-ups, as the board's Follow-ups lane
    /// applies it.
    var followUpFilter: (ShiftFollowUp) -> Bool = { _ in true }

    /// The Tasks page's header line follows the visible period's count.
    var onDrillSubtitleChanged: (() -> Void)?
    /// The empty state's Open List: the Tasks page's own List view.
    var onOpenTaskList: (() -> Void)?

    /// The When panel while it shows. One at a time: a second chip's click
    /// closes the first, which commits it.
    private var schedulePopover: ShiftSchedulePopover?

    init(store: ShiftStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// The page's own margins around the card: room for its shadow
    /// (`task-calendar.css`'s body padding). The Tasks page lets the view
    /// overhang its column by these, so the card's edges line up with the
    /// filter row above it.
    static let cardInsets = NSEdgeInsets(top: 4, left: 6, bottom: 14, right: 6)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 984, height: 720))
        root.wantsLayer = true
        view = root
        root.addSubview(calendarView)
        NSLayoutConstraint.activate([
            calendarView.topAnchor.constraint(equalTo: root.topAnchor),
            calendarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            calendarView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            calendarView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        calendarView.onOpenTask = { [weak self] id in self?.openTask(id: id) }
        calendarView.onOpenFollowUp = { [weak self] id in self?.openFollowUp(id: id) }
        calendarView.onAddTask = { [weak self] day, time in self?.addTask(on: day, time: time) }
        calendarView.onMoveTask = { [weak self] id, day, time in self?.rescheduleTask(id: id, to: day, time: time) }
        calendarView.onMoveFollowUp = { [weak self] id, day, time in
            self?.rescheduleFollowUp(id: id, to: day, time: time)
        }
        calendarView.onCompleteTask = { [weak self] id in self?.completeTask(id: id) }
        calendarView.onCompleteFollowUp = { [weak self] id in self?.completeFollowUp(id: id) }
        calendarView.onScheduleFromTray = { [weak self] id, kind, when in
            self?.scheduleFromTray(id: id, kind: kind, when: when)
        }
        calendarView.onEditSchedule = { [weak self] id, anchor, edge in
            self?.editSchedule(id: id, anchor: anchor, edge: edge)
        }
        calendarView.onNewTask = { [weak self] in self?.newTaskFromMenu() }
        calendarView.onOpenList = { [weak self] in self?.onOpenTaskList?() }
        calendarView.completedTasks = { [weak self] months in
            guard let self else { return [] }
            return self.store.completedTasks(inMonths: months).filter(self.taskFilter)
        }
        calendarView.onPeriodChanged = { [weak self] in self?.onDrillSubtitleChanged?() }

        themeToken = ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.calendarView.applyTheme(theme)
        }
        render()
    }

    // MARK: Data

    /// Every active task and every follow-up the Tasks page's filters keep.
    /// Finished tasks are not handed over here: the view asks for the
    /// `completed/` months its visible period needs
    /// (`ShiftCalendarView.completedTasks`), so October shows what got done
    /// in October rather than only what the board's 7-day Done column still
    /// holds.
    ///
    /// The Tasks page calls this from its own render, which is where a store
    /// change arrives (REL-02), so this view does not observe the store
    /// twice.
    func render() {
        guard isViewLoaded else { return }
        calendarView.configure(tasks: store.activeTasks.filter(taskFilter),
                               followUps: store.followUps.filter(followUpFilter),
                               projects: store.projects)
        onDrillSubtitleChanged?()
    }

    /// The visible period's own count, or its stated absence (GL-14). The
    /// Tasks page's header carries it while this view shows.
    var caption: String { calendarView.caption }

    /// What a task chip's colour says: priority or project.
    var colouring: ShiftCalendarColouring { calendarView.colouring }

    func setColouring(_ colouring: ShiftCalendarColouring) {
        _ = view
        calendarView.setColouring(colouring)
    }

    // MARK: Opening and adding

    private func openTask(id: String) {
        if let task = store.activeTasks.first(where: { $0.id == id }) {
            ShiftRecordSheets.presentTaskEditor(
                from: self, store: store, task: task,
                onSaved: { [weak self] in self?.render() },
                onDelete: { [weak self] id in self?.confirmDeleteTask(id: id) })
            return
        }
        guard let done = store.allCompletedTasks().first(where: { $0.id == id }) else { return }
        ShiftRecordSheets.showCompletedNotice(for: done)
    }

    private func openFollowUp(id: String) {
        guard let item = store.followUps.first(where: { $0.id == id }) else { return }
        ShiftRecordSheets.presentFollowUpEditor(from: self, store: store, followUp: item,
                                                onSaved: { [weak self] in self?.render() },
                                                onDelete: { [weak self] id in self?.confirmDeleteFollowUp(id: id) })
    }

    private func confirmDeleteTask(id: String) {
        guard ShiftRecordSheets.confirmDeleteTask(id: id, store: store, in: view) else { return }
        render()
    }

    private func confirmDeleteFollowUp(id: String) {
        guard ShiftRecordSheets.confirmDeleteFollowUp(id: id, store: store, in: view) else { return }
        render()
    }

    /// A double-click on a day: the same New Task sheet every other
    /// affordance opens, with that day already filled in - and the time too,
    /// when the click landed on a slot in the week or day view.
    func addTask(on day: String, time: String? = nil) {
        var prefill = ShiftTask.fresh()
        prefill.dueDate = day
        prefill.dueTime = time
        ShiftRecordSheets.presentTaskEditor(
            from: self, store: store, task: nil, prefill: prefill,
            onSaved: { [weak self] in self?.render() },
            onDelete: { [weak self] id in self?.confirmDeleteTask(id: id) })
    }

    /// The day New Task is dated to: today while today is in the period on
    /// screen, otherwise the day the calendar is focused on.
    var newTaskDay: String {
        let today = ShiftDateFormatting.components(from: Date()).dateStr
        guard let range = calendarView.visibleDays else { return today }
        if (range.start...range.end).contains(today) { return today }
        return calendarView.focusedDay ?? range.start
    }

    /// ⌘N and the Tasks page's New task, while this view shows.
    func newTaskFromMenu() { addTask(on: newTaskDay) }

    // MARK: The tray

    /// A tray row's Today or Tomorrow dates the record through the same path
    /// a drop takes (the reschedule rule, the store, Undo). A task's Pick…
    /// arrives at `editSchedule` instead, with its row's place; a follow-up's
    /// (and a task's whose row the page could not measure) opens the
    /// record's editor.
    func scheduleFromTray(id: String, kind: ShiftCalendarEntry.Kind, when: String, now: Date = Date()) {
        let calendar = Calendar.current
        let offset: Int
        switch when {
        case "today": offset = 0
        case "tomorrow": offset = 1
        default:
            if kind == .followUp { openFollowUp(id: id) } else { openTask(id: id) }
            return
        }
        guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { return }
        let day = ShiftDateFormatting.components(from: date).dateStr
        if kind == .followUp {
            rescheduleFollowUp(id: id, to: day, time: nil)
        } else {
            rescheduleTask(id: id, to: day, time: nil)
        }
    }

    // MARK: Completing

    /// The check on a real chip or an Agenda row (the captain's decision 4A).
    ///
    /// It takes the one path every other surface takes,
    /// `ShiftStore.setTaskCompleted`: the record moves to this month's
    /// `completed/` file and, for a repeating task, the next instance is
    /// written to `active.yaml`. The page is redrawn from the store, so the
    /// chip is struck through on its day and the next date becomes the real
    /// chip. A projection never reaches here, because the page draws no check
    /// on one (`ShiftCalendarEntry.isCompletable`), and a record that is no
    /// longer open is left alone.
    ///
    /// Undo is a real restore (GL-33). The task is reopened with the status
    /// it had, and the instance this completion spawned is withdrawn - but
    /// only while it is exactly as it was spawned. Reopening alone would
    /// leave two live instances of one series, which is why the store's own
    /// reopen does not withdraw anything (`ShiftStore.nextOccurrence`'s
    /// header). An instance edited since the check keeps its edits, and the
    /// toast says so rather than pretending the series is back as it was.
    func completeTask(id: String, now: Date = Date()) {
        guard let task = store.activeTasks.first(where: { $0.id == id }),
              task.status != .completed, task.status != .cancelled else {
            render()
            return
        }
        let before = Set(store.activeTasks.map(\.id))
        store.setTaskCompleted(id: id, completed: true, now: now)
        render()
        // A refused write is already reported, and the task is still live.
        guard !store.activeTasks.contains(where: { $0.id == id }) else { return }
        let spawned = store.activeTasks.first { !before.contains($0.id) }
        var message = "\u{201C}\(task.title)\u{201D} completed"
        if let spawned, let next = spawned.dueDate {
            message += ", next \(ShiftDateFormatting.friendly(next, time: spawned.dueTime))"
        }
        Toast.showUndo(in: view, message: message) { [weak self] in
            guard let self else { return }
            self.store.setTaskCompleted(id: id, completed: false)
            if var reopened = self.store.activeTasks.first(where: { $0.id == id }), reopened.status != task.status {
                reopened.status = task.status
                self.store.updateTask(reopened)
            }
            if let spawned, let current = self.store.activeTasks.first(where: { $0.id == spawned.id }) {
                if current == spawned {
                    self.store.deleteTask(id: spawned.id)
                } else {
                    Toast.show(in: self.view,
                               message: "Reopened. The next \u{201C}\(spawned.title)\u{201D} was edited, so it stays.")
                }
            }
            self.render()
        }
    }

    // MARK: The When panel

    /// The When panel for a live task, beside its chip or tray row. Anything
    /// else the page names (a finished task) opens the way a click always
    /// did.
    func editSchedule(id: String, anchor: NSRect, edge: NSRectEdge) {
        guard let task = store.activeTasks.first(where: { $0.id == id }) else {
            openTask(id: id)
            return
        }
        schedulePopover?.close()
        let projectName = task.projectID.flatMap { pid in store.projects.first { $0.id == pid }?.name }
        let popover = ShiftSchedulePopover(task: task, projectName: projectName,
                                           allDayReminderAt: store.settings.allDayReminderAt)
        popover.onCommit = { [weak self] draft in self?.commitSchedule(draft, taskID: id) }
        popover.onOpenTask = { [weak self] in self?.openTask(id: id) }
        popover.onClose = { [weak self, weak popover] in
            if let self, self.schedulePopover === popover { self.schedulePopover = nil }
        }
        schedulePopover = popover
        popover.show(relativeTo: anchor, of: calendarView, preferredEdge: edge)
    }

    /// The panel's draft, written into the task as the store has it now, so
    /// an edit that arrived while the panel was open (a sync, the sheet) is
    /// kept. Undo restores the four fields this method read (GL-33).
    func commitSchedule(_ draft: ShiftScheduleDraft, taskID id: String) {
        guard let task = store.activeTasks.first(where: { $0.id == id }), draft.changes(task) else { return }
        let updated = draft.applied(to: task)
        store.updateTask(updated)
        render()
        let previous = (task.dueDate, task.dueTime, task.recurrence, task.reminderMinutesBefore, task.occurrence)
        Toast.showUndo(in: view, message: Self.scheduleToast(from: task, to: updated)) { [weak self] in
            guard let self,
                  var current = self.store.activeTasks.first(where: { $0.id == id }) else { return }
            (current.dueDate, current.dueTime, current.recurrence, current.reminderMinutesBefore,
             current.occurrence) = previous
            self.store.updateTask(current)
            self.render()
        }
    }

    /// The same check on a pending follow-up: marked done, which takes it off
    /// the calendar, with an Undo that marks it pending again.
    func completeFollowUp(id: String, now: Date = Date()) {
        guard let item = store.followUps.first(where: { $0.id == id }), item.status == .pending else {
            render()
            return
        }
        store.setFollowUpStatus(id: id, done: true, now: now)
        render()
        Toast.showUndo(in: view, message: "\u{201C}\(item.title)\u{201D} completed") { [weak self] in
            guard let self else { return }
            self.store.setFollowUpStatus(id: id, done: false)
            self.render()
        }
    }

    /// What the panel's change did, in one line.
    static func scheduleToast(from old: ShiftTask, to new: ShiftTask) -> String {
        let name = "\u{201C}\(new.title)\u{201D}"
        guard let day = new.dueDate else { return "\(name) has no date now" }
        let when = ShiftDateFormatting.friendly(day, time: new.dueTime)
        if old.dueDate == nil { return "\(name) scheduled for \(when)" }
        if old.dueDate != new.dueDate || old.dueTime != new.dueTime { return "\(name) moved to \(when)" }
        if old.recurrence != new.recurrence {
            guard let rule = new.recurrence else { return "\(name) no longer repeats" }
            let pattern = rule.patternName
            return "\(name) repeats \(pattern.prefix(1).lowercased() + pattern.dropFirst())"
        }
        return new.reminderMinutesBefore == nil ? "\(name) has no reminder now" : "\(name)\u{2019}s reminder changed"
    }

    // MARK: Dropping

    /// A task dropped on a new day (or a new time).
    ///
    /// The store is written, the page is redrawn from it, and a real Undo
    /// restores the date and time this method already held (GL-33). A refused
    /// or no-op drop writes nothing, and `render()` pushes the store's events
    /// back so the page drops the position it drew optimistically.
    func rescheduleTask(id: String, to day: String, time: String?) {
        guard let task = store.activeTasks.first(where: { $0.id == id }) else {
            render()
            return
        }
        switch ShiftCalendarReschedule.apply(task: task, day: day, time: time) {
        case .unchanged:
            render()
        case .refused(let reason):
            render()
            Toast.show(in: view, message: reason)
        case .moved(let moved):
            let previousDue = task.dueDate
            let previousTime = task.dueTime
            store.updateTask(moved)
            render()
            let phrase = ShiftDateFormatting.friendly(day, time: moved.dueTime)
            // A task with no date is not "moved" anywhere: it is scheduled.
            let verb = previousDue == nil ? "scheduled for" : "moved to"
            Toast.showUndo(in: view, message: "\u{201C}\(task.title)\u{201D} \(verb) \(phrase)") { [weak self] in
                // Re-read first, so an edit made while the toast was up is
                // not reverted along with the date.
                guard let self,
                      var current = self.store.activeTasks.first(where: { $0.id == id }) else { return }
                current.dueDate = previousDue
                current.dueTime = previousTime
                self.store.updateTask(current)
                self.render()
            }
        }
    }

    /// The same, for a follow-up's own date.
    func rescheduleFollowUp(id: String, to day: String, time: String?) {
        guard let item = store.followUps.first(where: { $0.id == id }) else {
            render()
            return
        }
        switch ShiftCalendarReschedule.apply(followUp: item, day: day, time: time) {
        case .unchanged:
            render()
        case .refused(let reason):
            render()
            Toast.show(in: view, message: reason)
        case .moved(let moved):
            let previousDay = item.followUpAt
            let previousTime = item.followUpTime
            store.updateFollowUp(moved)
            render()
            let phrase = ShiftDateFormatting.friendly(day, time: moved.followUpTime)
            Toast.showUndo(in: view, message: "\u{201C}\(item.title)\u{201D} moved to \(phrase)") { [weak self] in
                guard let self,
                      var current = self.store.followUps.first(where: { $0.id == id }) else { return }
                current.followUpAt = previousDay
                current.followUpTime = previousTime
                self.store.updateFollowUp(current)
                self.render()
            }
        }
    }

    // MARK: Debug hooks (GL-27)

    #if FM_SELFTESTS
    var debugCalendarView: ShiftCalendarView { calendarView }
    var debugSchedulePopover: ShiftSchedulePopover? { schedulePopover }
    #endif
}
