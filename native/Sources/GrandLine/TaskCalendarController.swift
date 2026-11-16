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
// A tray row dragged onto a day or a time slot is scheduled the same way a
// drop is, a chip dragged onto the tray loses its date the same way, and a
// day's quick add (its +) adds a task there, read by the same title parser
// the New Task sheet uses, with an Undo that removes it again (tasks-calendar
// plan PR 7).
// A repeating task's chip, or one of its projections, dropped on a new day
// asks "Only this occurrence" or "This and following" before anything is
// written, and a right-click on either offers "Skip this occurrence"; a
// skipped date stays on the grid, and its menu offers it back
// (`ShiftSeriesEdit`, tasks-calendar plan PR 6).
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
        calendarView.onMoveOccurrence = { [weak self] id, slot, day, time in
            self?.moveOccurrence(taskID: id, slot: slot, to: day, time: time)
        }
        calendarView.onOccurrenceMenu = { [weak self] id, slot, skipped, anchor in
            self?.showOccurrenceMenu(taskID: id, slot: slot, skipped: skipped, anchor: anchor)
        }
        calendarView.onCompleteTask = { [weak self] id in self?.completeTask(id: id) }
        calendarView.onCompleteFollowUp = { [weak self] id in self?.completeFollowUp(id: id) }
        calendarView.onScheduleFromTray = { [weak self] id, kind, when in
            self?.scheduleFromTray(id: id, kind: kind, when: when)
        }
        calendarView.onEditSchedule = { [weak self] id, anchor, edge in
            self?.editSchedule(id: id, anchor: anchor, edge: edge)
        }
        calendarView.onPlaceFromTray = { [weak self] id, kind, day, time in
            self?.placeFromTray(id: id, kind: kind, day: day, time: time)
        }
        calendarView.onUnschedule = { [weak self] id, kind in self?.unschedule(id: id, kind: kind) }
        calendarView.onQuickAdd = { [weak self] day, text, details in
            self?.quickAdd(on: day, text: text, details: details)
        }
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
    /// it had, and the store's reopen withdraws the instance this completion
    /// spawned - but only while it is untouched since
    /// (`ShiftStore.keepOneLiveInstance`, R5-BUG-10), the one rule every
    /// surface's un-tick shares. An instance edited since the check keeps its
    /// edits and the series, and the toast says so rather than pretending the
    /// series is back as it was.
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
            if let spawned, self.store.activeTasks.contains(where: { $0.id == spawned.id }) {
                Toast.show(in: self.view,
                           message: "Reopened. The next \u{201C}\(spawned.title)\u{201D} was edited, so it stays.")
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

    /// A tray row dragged onto a day, or onto a time slot in Week and Day.
    /// The slot's time is the captain's answer to "when", so an all-day task
    /// takes it (`ShiftCalendarReschedule.apply`'s `adoptsTime`).
    func placeFromTray(id: String, kind: ShiftCalendarEntry.Kind, day: String, time: String?) {
        if kind == .followUp {
            rescheduleFollowUp(id: id, to: day, time: time, adoptsTime: true)
        } else {
            rescheduleTask(id: id, to: day, time: time, adoptsTime: true)
        }
    }

    /// A chip dragged onto the tray: the task loses its date and lands in
    /// the tray, with an Undo that puts back the date, the time and the
    /// reminder this method already held (GL-33).
    func unschedule(id: String, kind: ShiftCalendarEntry.Kind) {
        guard kind == .task else {
            render()
            Toast.show(in: view, message: ShiftCalendarReschedule.followUpKeepsItsDate)
            return
        }
        guard let task = store.activeTasks.first(where: { $0.id == id }) else {
            render()
            return
        }
        switch ShiftCalendarReschedule.unschedule(task: task) {
        case .unchanged:
            render()
        case .refused(let reason):
            render()
            Toast.show(in: view, message: reason)
        case .moved(let cleared):
            let previousDue = task.dueDate
            let previousTime = task.dueTime
            let previousReminder = task.reminderMinutesBefore
            store.updateTask(cleared)
            render()
            Toast.showUndo(in: view, message: "\u{201C}\(task.title)\u{201D} has no date now") { [weak self] in
                guard let self,
                      var current = self.store.activeTasks.first(where: { $0.id == id }) else { return }
                current.dueDate = previousDue
                current.dueTime = previousTime
                current.reminderMinutesBefore = previousReminder
                self.store.updateTask(current)
                self.render()
            }
        }
    }

    // MARK: Quick add

    /// A day's quick add, submitted. Return adds the task straight away;
    /// Command-Return (`details`) opens the New Task sheet with everything
    /// the text said already filled in, for whatever the field cannot set.
    ///
    /// The Undo removes the task this method just added, which is a real
    /// restore of the store as it was (GL-33).
    func quickAdd(on day: String, text: String, details: Bool, now: Date = Date()) {
        guard let draft = ShiftCalendarQuickAdd.draft(text: text, day: day, now: now) else { return }
        let task = ShiftCalendarQuickAdd.task(from: draft)
        if details {
            ShiftRecordSheets.presentTaskEditor(
                from: self, store: store, task: nil, prefill: task,
                onSaved: { [weak self] in self?.render() },
                onDelete: { [weak self] id in self?.confirmDeleteTask(id: id) })
            return
        }
        store.addTask(task)
        render()
        var message = "Added \u{201C}\(task.title)\u{201D} on \(ShiftDateFormatting.friendly(draft.day, time: draft.time))"
        if let rule = draft.recurrence { message += ", \(rule.displayName.lowercased())" }
        Toast.showUndo(in: view, message: message) { [weak self] in
            guard let self, self.store.activeTasks.contains(where: { $0.id == task.id }) else { return }
            self.store.deleteTask(id: task.id)
            self.render()
        }
    }

    // MARK: Dropping

    /// A task dropped on a new day (or a new time).
    ///
    /// The store is written, the page is redrawn from it, and a real Undo
    /// restores the date and time this method already held (GL-33). A refused
    /// or no-op drop writes nothing, and `render()` pushes the store's events
    /// back so the page drops the position it drew optimistically.
    func rescheduleTask(id: String, to day: String, time: String?, adoptsTime: Bool = false) {
        guard let task = store.activeTasks.first(where: { $0.id == id }) else {
            render()
            return
        }
        if task.recurrence != nil, task.status != .completed, task.status != .cancelled {
            moveOccurrence(taskID: id, slot: nil, to: day, time: time, adoptsTime: adoptsTime)
            return
        }
        switch ShiftCalendarReschedule.apply(task: task, day: day, time: time, adoptsTime: adoptsTime) {
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
    func rescheduleFollowUp(id: String, to day: String, time: String?, adoptsTime: Bool = false) {
        guard let item = store.followUps.first(where: { $0.id == id }) else {
            render()
            return
        }
        switch ShiftCalendarReschedule.apply(followUp: item, day: day, time: time, adoptsTime: adoptsTime) {
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

    // MARK: Exceptions

    /// A repeating task's live chip (`slot == nil`) or the projection on
    /// `slot`, dropped on `day` at `time`.
    ///
    /// Nothing is written until the captain says which occurrences the move
    /// reaches. A drop that lands where the occurrence already was, or that
    /// the drop rule refuses, asks nothing. Cancel puts the chip back, because
    /// the page is redrawn from the store either way.
    func moveOccurrence(taskID id: String, slot: String?, to day: String, time: String?,
                        adoptsTime: Bool = false, now: Date = Date()) {
        guard let live = store.activeTasks.first(where: { $0.id == id }) else {
            render()
            return
        }
        let preview = ShiftSeriesEdit.move(live, slot: slot, to: day, time: time, scope: .onlyThis,
                                           adoptsTime: adoptsTime, now: now)
        guard case .write(let change) = preview else {
            render()
            if case .refused(let reason) = preview { Toast.show(in: view, message: reason) }
            return
        }
        let movedTo = change.added ?? change.updated
        let from = slot ?? live.dueDate ?? day
        let fromTime = slot == nil ? live.dueTime : (live.dueTime == nil ? nil : live.slotTime)
        let request = Self.scopeRequest(title: live.title, rule: live.recurrence,
                                        from: ShiftSeriesEdit.phrase(from, time: fromTime),
                                        to: ShiftSeriesEdit.phrase(movedTo.dueDate ?? day, time: movedTo.dueTime))
        let scope: ShiftSeriesScope
        switch HelmConfirm.confirm(request) {
        case .confirm: scope = .onlyThis
        case .extra: scope = .thisAndFollowing
        case .cancel:
            render()
            return
        }
        // Re-read: the dialog was modal, but a sync can still land under it.
        guard let current = store.activeTasks.first(where: { $0.id == id }) else {
            render()
            return
        }
        apply(ShiftSeriesEdit.move(current, slot: slot, to: day, time: time, scope: scope,
                                   adoptsTime: adoptsTime, now: now), to: current, now: now)
    }

    /// "Only this occurrence" or "This and following". Return takes the
    /// smaller change, and Escape cancels.
    static func scopeRequest(title: String, rule: ShiftRecurrence?, from: String, to: String) -> HelmConfirm.Request {
        var body = "\u{201C}\(title)\u{201D}"
        if let pattern = rule?.patternName {
            body += " repeats \(pattern.prefix(1).lowercased() + pattern.dropFirst())."
        } else {
            body += " repeats."
        }
        body += " Move only the occurrence on \(from) to \(to), or that one and every repeat after it?"
        var request = HelmConfirm.Request(title: "Move a repeating task?", body: body)
        request.confirmTitle = scopeOnlyThisTitle
        request.extra = HelmConfirm.ExtraButton(title: scopeFollowingTitle)
        request.cancelTitle = "Cancel"
        request.confirmIsDefault = true
        request.symbol = "repeat"
        return request
    }

    static let scopeOnlyThisTitle = "Only This Occurrence"
    static let scopeFollowingTitle = "This and Following"

    /// "Skip this occurrence", from a chip's menu: a projection's date, or
    /// the live instance (`slot == nil`).
    func skipOccurrence(taskID id: String, slot: String?, now: Date = Date()) {
        guard let live = store.activeTasks.first(where: { $0.id == id }) else {
            render()
            return
        }
        apply(ShiftSeriesEdit.skip(live, slot: slot, now: now), to: live, now: now)
    }

    /// A skipped date's "Restore this occurrence".
    func restoreOccurrence(taskID id: String, slot: String, now: Date = Date()) {
        guard let live = store.activeTasks.first(where: { $0.id == id }) else {
            render()
            return
        }
        apply(ShiftSeriesEdit.restore(live, slot: slot), to: live, now: now)
    }

    /// Writes an exception and offers a real Undo (GL-33): the live record's
    /// schedule as this method read it, and the task the exception split off
    /// withdrawn - but only while it is exactly as it was written, as the
    /// check's Undo does for a spawned instance.
    private func apply(_ outcome: ShiftSeriesEdit.Outcome, to live: ShiftTask, now: Date) {
        switch outcome {
        case .unchanged:
            render()
        case .refused(let reason):
            render()
            Toast.show(in: view, message: reason)
        case .write(let change):
            guard store.applySeriesEdit(change, now: now) else {
                render()
                return
            }
            render()
            Toast.showUndo(in: view, message: Self.exceptionToast(live: live, change: change)) { [weak self] in
                guard let self else { return }
                if var current = self.store.activeTasks.first(where: { $0.id == live.id }) {
                    current.dueDate = live.dueDate
                    current.dueTime = live.dueTime
                    current.recurrence = live.recurrence
                    current.occurrence = live.occurrence
                    current.occurrenceTime = live.occurrenceTime
                    current.seriesID = live.seriesID
                    current.subtasks = live.subtasks
                    self.store.updateTask(current)
                }
                if let added = change.added,
                   let current = self.store.activeTasks.first(where: { $0.id == added.id }) {
                    if current == added {
                        self.store.deleteTask(id: added.id)
                    } else {
                        Toast.show(in: self.view,
                                   message: "Put back. The new \u{201C}\(added.title)\u{201D} was edited, so it stays.")
                    }
                }
                self.render()
            }
        }
    }

    /// What an exception did, in one line.
    static func exceptionToast(live: ShiftTask, change: ShiftSeriesEdit.Change) -> String {
        let name = "\u{201C}\(live.title)\u{201D}"
        let updated = change.updated
        switch change.kind {
        case .skipped:
            // The live record moved on, or a date joined the skipped ones.
            if updated.dueDate != live.dueDate, let was = live.dueDate, let next = updated.dueDate {
                return "Skipped \(name) on \(ShiftSeriesEdit.phrase(was, time: live.dueTime)). "
                    + "Next: \(ShiftSeriesEdit.phrase(next, time: updated.dueTime))"
            }
            let added = (updated.recurrence?.exceptionDates ?? []).subtracting(live.recurrence?.exceptionDates ?? [])
            return "Skipped \(name)" + (added.first.map { " on \(ShiftSeriesEdit.phrase($0, time: nil))" } ?? "")
        case .restored:
            let back = (live.recurrence?.exceptionDates ?? []).subtracting(updated.recurrence?.exceptionDates ?? [])
            return "\(name) is back" + (back.first.map { " on \(ShiftSeriesEdit.phrase($0, time: nil))" } ?? "")
        case .moved(let scope):
            let moved = change.added ?? updated
            let to = ShiftSeriesEdit.phrase(moved.dueDate ?? "", time: moved.dueTime)
            switch scope {
            case .onlyThis: return "\(name) moved to \(to), this time only"
            case .thisAndFollowing: return "\(name) moved to \(to), with every repeat after it"
            }
        }
    }

    /// A repeating task's chip menu, beside the chip: "Skip this
    /// occurrence" on its live chip or a projection, "Restore this
    /// occurrence" on a skipped date, and "Open task…" on all three.
    func showOccurrenceMenu(taskID id: String, slot: String?, skipped: Bool, anchor: NSRect?) {
        guard let menu = occurrenceMenu(taskID: id, slot: slot, skipped: skipped) else { return }
        #if FM_SELFTESTS
        if let debugMenuPresenter {
            debugMenuPresenter(menu)
            return
        }
        #endif
        // At the pointer, as a context menu opens. A click the page could
        // not place opens it under the chip instead.
        var point = calendarView.window.map { calendarView.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        if let anchor, point.map({ !calendarView.bounds.contains($0) }) ?? true {
            point = NSPoint(x: anchor.minX, y: calendarView.isFlipped ? anchor.maxY : anchor.minY)
        }
        menu.popUp(positioning: nil, at: point ?? .zero, in: calendarView)
    }

    /// The menu itself, or `nil` for a record that no longer repeats.
    func occurrenceMenu(taskID id: String, slot: String?, skipped: Bool) -> NSMenu? {
        guard let live = store.activeTasks.first(where: { $0.id == id }), live.recurrence != nil else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let occurrence = OccurrenceRef(taskID: id, slot: slot)
        if skipped, slot != nil {
            let restore = NSMenuItem(title: "Restore This Occurrence", action: #selector(restoreClicked(_:)),
                                     keyEquivalent: "").withSymbol("arrow.uturn.backward")
            restore.target = self
            restore.representedObject = occurrence
            menu.addItem(restore)
        } else {
            let skip = NSMenuItem(title: "Skip This Occurrence", action: #selector(skipClicked(_:)),
                                  keyEquivalent: "").withSymbol("forward.end")
            skip.target = self
            skip.representedObject = occurrence
            menu.addItem(skip)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Task\u{2026}", action: #selector(openClicked(_:)),
                              keyEquivalent: "").withSymbol("arrow.up.forward.square")
        open.target = self
        open.representedObject = occurrence
        menu.addItem(open)
        return menu
    }

    /// Which occurrence a menu item acts on.
    private struct OccurrenceRef {
        let taskID: String
        let slot: String?
    }

    @objc private func skipClicked(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? OccurrenceRef else { return }
        skipOccurrence(taskID: ref.taskID, slot: ref.slot)
    }

    @objc private func restoreClicked(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? OccurrenceRef, let slot = ref.slot else { return }
        restoreOccurrence(taskID: ref.taskID, slot: slot)
    }

    @objc private func openClicked(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? OccurrenceRef else { return }
        openTask(id: ref.taskID)
    }

    // MARK: Debug hooks (GL-27)

    #if FM_SELFTESTS
    var debugCalendarView: ShiftCalendarView { calendarView }
    var debugSchedulePopover: ShiftSchedulePopover? { schedulePopover }
    /// Stands in for `NSMenu.popUp`, which tracks the menu modally.
    var debugMenuPresenter: ((NSMenu) -> Void)?
    #endif
}
