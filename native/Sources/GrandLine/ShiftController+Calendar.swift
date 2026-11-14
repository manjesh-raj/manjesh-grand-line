// Grand Line - native macOS app.
//
// Tasks' Calendar view: the Tasks page's half of it (tasks-calendar plan
// PR 4, the captain's decision 1A).
//
// The calendar itself is `TaskCalendarController`, a child controller this
// page embeds under its filter row, so the 3,500-line page does not grow a
// calendar too (GL-36). What lives here is the glue, and it is what makes
// Tasks one surface rather than two pages:
//
//   - **The filters are the page's.** The scope (All tasks, Due today,
//     Overdue, My priorities, Recently updated) and the project picker run
//     through the same `matchesFilters` the board and the list use, so a
//     filter set on Board is the filter on the calendar, its tray and its
//     caption too. Follow-ups take the project filter, as the board's
//     Follow-ups lane does.
//   - **New task and ⌘N** date the new task to the day the calendar shows
//     while this view is up, through the calendar's own `newTaskFromMenu`.
//   - **The header's line** is the calendar's caption, so the column states
//     what the visible period holds and what the grid cannot show (GL-14).
//   - **Colour by Priority or Project** sits beside the filters while the
//     calendar shows, and in the Filter menu when the row collapses.
//
// The calendar fills the visible height under the filter row
// (`applyCalendarHeight`), and grows the page past it rather than squeezing
// its month below `ShiftCalendarView.minimumHeight`.

import AppKit

extension ShiftController {

    // MARK: Building

    /// The calendar child, on the page's own store (GL-23), seeing tasks
    /// through the page's filters.
    func makeCalendar() -> TaskCalendarController {
        let calendar = TaskCalendarController(store: store)
        calendar.taskFilter = { [weak self] task in self?.matchesFilters(task) ?? true }
        calendar.followUpFilter = { [weak self] item in
            guard let filter = self?.projectFilter else { return true }
            return item.projectID == filter
        }
        calendar.onDrillSubtitleChanged = { [weak self] in
            guard let self, self.isShowingCalendar else { return }
            self.onDrillSubtitleChanged?()
        }
        calendar.onOpenTaskList = { [weak self] in self?.selectModuleTab(named: "List") }
        return calendar
    }

    /// The section joins the dashboard the first time the Calendar view
    /// shows, after the board, so a session that never opens it builds no
    /// web view and lays out nothing for it.
    func embedCalendarIfNeeded() {
        guard calendarSection.superview == nil else { return }
        _ = view
        calendarSection.translatesAutoresizingMaskIntoConstraints = false
        calendarSection.isHidden = true
        let index = (dashboardContainer.arrangedSubviews.firstIndex(of: boardSection) ?? -1) + 1
        dashboardContainer.insertArrangedSubview(calendarSection, at: index)
        calendarSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        addChild(calendar)
        let page = calendar.view
        page.translatesAutoresizingMaskIntoConstraints = false
        calendarSection.addSubview(page)
        // The card's own margins overhang the section, so the card's edges
        // line up with the filter row above it.
        let insets = TaskCalendarController.cardInsets
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: calendarSection.topAnchor, constant: -insets.top),
            page.leadingAnchor.constraint(equalTo: calendarSection.leadingAnchor, constant: -insets.left),
            page.trailingAnchor.constraint(equalTo: calendarSection.trailingAnchor, constant: insets.right),
            page.bottomAnchor.constraint(equalTo: calendarSection.bottomAnchor, constant: insets.bottom),
        ])
        // Below the window's hold on its size (gotcha (13)): the document
        // view is free to grow, so a short window scrolls the page rather
        // than squeezing the month under its floor.
        let tie = calendarSection.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
        tie.priority = NSLayoutConstraint.Priority(490)
        calendarHeightTie = tie
    }

    func makeColourControl() -> NSStackView {
        let label = NSTextField(labelWithString: "Colour by")
        label.font = HelmType.chip()
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let tabs = HelmSegmentedTabs(items: ShiftCalendarColouring.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                     selected: ShiftCalendarColouring.saved.rawValue, size: .compact)
        tabs.setAccessibilityLabel("Colour calendar chips by")
        tabs.onSelect = { [weak self] id in
            guard let colouring = ShiftCalendarColouring(rawValue: id) else { return }
            self?.setCalendarColouring(colouring)
        }
        let stack = NSStackView(views: [label, tabs])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = HelmMetrics.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.required, for: .horizontal)
        stack.setClippingResistancePriority(.required, for: .horizontal)
        return stack
    }

    private var colourTabs: HelmSegmentedTabs? { colourControl.arrangedSubviews.last as? HelmSegmentedTabs }

    func paintColourControl(_ theme: HelmTheme) {
        (colourControl.arrangedSubviews.first as? NSTextField)?.textColor = HelmTheme.mutedInk(theme)
        colourTabs?.applyTheme(theme)
    }

    // MARK: State

    /// Whether the Calendar view is what the page shows.
    var isShowingCalendar: Bool {
        topLevelView == .dashboard && tasksView == .calendar && !isProjectDetailFullPage
            && !store.isInFailedLoadState
    }

    /// The header's line on the Calendar view: the calendar's caption, after
    /// the project it is filtered to, as the page's own line names it.
    var calendarSubtitle: String {
        let caption = calendar.caption
        guard let filter = projectFilter,
              let name = store.projects.first(where: { $0.id == filter })?.name, !name.isEmpty else { return caption }
        return "\(name) \u{00B7} " + caption
    }

    /// What the calendar's chips are coloured by, remembered per machine.
    var calendarColouring: ShiftCalendarColouring {
        calendarSection.superview == nil ? ShiftCalendarColouring.saved : calendar.colouring
    }

    func setCalendarColouring(_ colouring: ShiftCalendarColouring) {
        embedCalendarIfNeeded()
        calendar.setColouring(colouring)
        colourTabs?.select(colouring.rawValue)
    }

    /// New task and ⌘N on the Calendar view: dated to the day on screen.
    func newTaskOnCalendar() {
        embedCalendarIfNeeded()
        calendar.newTaskFromMenu()
    }

    // MARK: Layout

    /// Shows the section on the Calendar view, and holds it to the height
    /// under the filter row while it shows. The tie is released otherwise,
    /// because a hidden view keeps its constraints (gotcha (15)).
    func applyCalendarVisibility() {
        guard calendarSection.superview != nil else { return }
        let showing = isShowingCalendar
        calendarSection.isHidden = !showing
        if showing { applyCalendarHeight() }
        calendarHeightTie?.isActive = showing
    }

    /// The tie's constant: the clip view's height less what sits above and
    /// below the section - the content's top inset, the filter row (or, in
    /// the floating bar, the tab row) and its spacing, and the foot.
    func applyCalendarHeight() {
        guard let tie = calendarHeightTie else { return }
        let rowAbove: NSView? = drawsSidebarLayout ? workspaceFilterRow : topToolbar
        let rowHeight = rowAbove.map { $0.isHidden ? 0 : $0.fittingSize.height + contentStack.spacing } ?? 0
        let reserved = Self.contentTopInset + rowHeight + HelmMetrics.s5
        if tie.constant != -reserved { tie.constant = -reserved }
    }

    /// The content stack's distance from the top of the scroll document.
    static let contentTopInset: CGFloat = 24

    /// The floating bar's tab row: the sort and the Done window belong to
    /// the board and the list, and Colour by to the calendar. The sidebar
    /// layout's filter row decides the same in `fitFilterRow`.
    func applyTabRowAccessories() {
        guard !drawsSidebarLayout else { return }
        let dashboard = topLevelView == .dashboard
        let calendar = tasksView == .calendar
        sortPopup.isHidden = !dashboard || calendar
        doneWindowNote.isHidden = !dashboard || calendar
        colourControl.isHidden = !dashboard || !calendar
    }

    #if FM_SELFTESTS
    var debugCalendarSection: NSView { calendarSection }
    var debugColourControl: NSStackView { colourControl }
    #endif
}
