// Grand Line - native macOS app.
//
// The Calendar destination: its own sidebar row in Work, between Tasks and
// Crew, where the captain's mockup puts it.
//
// It was Tasks' third tab (F5, then PR 542's Schedule-X page). The captain
// asked for it in the sidebar, and a calendar reachable both as a Tasks tab
// and as a page of its own would be two answers to "where is the calendar",
// so the tab went and this is the one route. The toolbar's calendar button,
// the Go menu, ⌘K and the floating bar's All Destinations all land here.
//
// What it shows is Shift's own records by their date: every active task, the
// tasks finished inside the Done column's window, and every pending
// follow-up. It owns none of them. A click opens the same editor the Tasks
// page opens (`ShiftRecordSheets`), a double-click or New Task opens New Task
// dated to that day, and a drop writes the new date through the store with
// an Undo that restores the date this controller already held (GL-33).
//
// In the sidebar layout the toolbar draws Month, Week, Day and Agenda as the
// module's tabs (`ModuleTabHosting`), and the page draws the mockup's
// "Calendar" heading with the period's count beside it (GL-14). The card's own Day, Week, Month and Agenda pills
// stay visible there too, because the captain's mockup draws both, and they
// are one path: either reaches `ShiftCalendarView.show(scale:)` or the page's
// own pill handler, and the other follows.

import AppKit

final class TaskCalendarController: NSViewController {

    let store: ShiftStore
    private let calendarView = ShiftCalendarView()
    private var themeToken: ThemeObservation?
    private var renderPendingForStoreChange = false
    /// Set once the sidebar shell shows this page (`SidebarLayoutAdopting`).
    private(set) var drawsSidebarLayout = false

    /// The shell's header line follows the visible period's count.
    var onDrillSubtitleChanged: (() -> Void)?
    /// The toolbar follows a view the page switched by itself (a pill, a
    /// click on a day's number).
    var onModuleTabChanged: (() -> Void)?

    init(store: ShiftStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    private lazy var newTaskButton: HelmButton = {
        let button = HelmButton(title: "New task", variant: .primary, size: .small,
                                symbol: "plus", target: self, action: #selector(newTaskClicked))
        button.toolTip = "New task on the day the calendar is showing (\u{2318}N)"
        return button
    }()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 984, height: 720))
        root.wantsLayer = true
        view = root
        root.addSubview(calendarView)
        NSLayoutConstraint.activate([
            calendarView.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s3),
            calendarView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.pageGutter - 6),
            calendarView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -(HelmMetrics.pageGutter - 6)),
            calendarView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.s3),
        ])

        calendarView.onOpenTask = { [weak self] id in self?.openTask(id: id) }
        calendarView.onOpenFollowUp = { [weak self] id in self?.openFollowUp(id: id) }
        calendarView.onAddTask = { [weak self] day, time in self?.addTask(on: day, time: time) }
        calendarView.onMoveTask = { [weak self] id, day, time in self?.rescheduleTask(id: id, to: day, time: time) }
        calendarView.onMoveFollowUp = { [weak self] id, day, time in
            self?.rescheduleFollowUp(id: id, to: day, time: time)
        }
        var lastScale = calendarView.scale
        calendarView.onPeriodChanged = { [weak self] in
            guard let self else { return }
            self.onDrillSubtitleChanged?()
            if self.calendarView.scale != lastScale {
                lastScale = self.calendarView.scale
                self.onModuleTabChanged?()
            }
        }

        store.observe { [weak self] in self?.scheduleRenderForStoreChange() }
        themeToken = ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.calendarView.applyTheme(theme)
        }
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        render()
    }

    // MARK: Data

    /// Every active task, the tasks the board's Done column still shows (a
    /// month that silently drops everything finished would read as a month
    /// where nothing happened), and every follow-up. The calendar has no
    /// filters of its own: it is the whole schedule.
    private func calendarTasks() -> [ShiftTask] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -ShiftController.doneColumnLookbackDays, to: Date())
        return store.activeTasks + store.allCompletedTasks().filter { task in
            guard let cutoff,
                  let completed = task.completedAt.flatMap(ShiftStore.date(fromISO8601:)) else { return false }
            return completed >= cutoff
        }
    }

    func render() {
        renderPendingForStoreChange = false
        guard isViewLoaded else { return }
        calendarView.configure(tasks: calendarTasks(), followUps: store.followUps)
        onDrillSubtitleChanged?()
    }

    private func scheduleRenderForStoreChange() {
        guard !renderPendingForStoreChange else { return }
        renderPendingForStoreChange = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.renderPendingForStoreChange else { return }
            self.renderPendingForStoreChange = false
            // A page nobody can see does not rebuild; `viewWillAppear` does.
            guard self.isViewLoaded, self.view.window != nil, !self.view.isHiddenOrHasHiddenAncestor else { return }
            self.render()
        }
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
                                                onSaved: { [weak self] in self?.render() })
    }

    private func confirmDeleteTask(id: String) {
        guard ShiftRecordSheets.confirmDeleteTask(id: id, store: store, in: view) else { return }
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

    /// ⌘N and the toolbar's New task.
    func newTaskFromMenu() { addTask(on: newTaskDay) }

    @objc private func newTaskClicked() { newTaskFromMenu() }

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
            Toast.showUndo(in: view, message: "\u{201C}\(task.title)\u{201D} moved to \(phrase)") { [weak self] in
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
    var debugNewTaskButton: HelmButton { newTaskButton }
    #endif
}

// MARK: - The shell's header and actions

extension TaskCalendarController: DaylightDrillActions, WorkspacePrimaryActionProviding, SidebarLayoutAdopting {

    var drillHeaderActions: [NSView] { [newTaskButton] }

    /// GL-14: the visible period's own count, or its stated absence - the
    /// floating bar's drill header line. The sidebar layout draws no module
    /// header for the Calendar (`showsHeader: false`); the page's own
    /// heading row states the count there instead.
    var drillHeaderSubtitle: String? { calendarView.caption }

    var workspacePrimaryAction: NSView? { drawsSidebarLayout ? newTaskButton : nil }

    /// The captain's mockup: a "Calendar" heading over the card, with the
    /// period's count on its row.
    func adoptSidebarLayout() {
        guard !drawsSidebarLayout else { return }
        _ = view
        drawsSidebarLayout = true
        calendarView.showHeading(RailDestination.calendar.title)
        onDrillSubtitleChanged?()
    }
}

// MARK: - Month, Week, Day and Agenda as the module's tabs

extension TaskCalendarController: ModuleTabHosting {
    var moduleTabNames: [String] { ShiftCalendarScale.allCases.map(\.title) }

    var selectedModuleTabName: String { calendarView.scale.title }

    func selectModuleTab(named name: String) {
        _ = view
        guard let scale = ShiftCalendarScale(title: name) else { return }
        calendarView.show(scale: scale)
    }

    /// Nothing to hide: the card's pills are the captain's design in this
    /// layout too, and they are the same path as the toolbar's tabs.
    func setModuleTabControlHidden(_ hidden: Bool) {}
}
