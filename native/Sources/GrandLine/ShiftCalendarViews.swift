// Grand Line - native macOS app.
//
// The Tasks page's calendar - the third view beside Board and List (F5 of
// full review #3 §8, `docs/history/34-recurrence-and-calendar.md`).
//
// **Month is the default, deliberately.** The report left week-vs-month open
// and the mockup the captain reviewed draws a month grid, for a reason worth
// keeping here: the thing a recurrence rule needs a person to *see* is the
// pattern. Five chips in a row across a week, repeated down four weeks, is
// "every weekday" verified by eye - and that is exactly the check a week view
// cannot offer. Week is still here, because a day with six tasks on it is
// unreadable at month density.
//
// **A projected occurrence is drawn differently from a real task.** Only one
// instance of a recurring task exists in `active.yaml` at a time
// (`ShiftStore.nextOccurrence`'s header says why); everything after it is a
// *projection* of the rule, not a record. Drawing the two identically would
// be GL-14's own failure in a new place - a thing that does not exist yet
// rendered as a thing that does. So a projection is drawn at reduced alpha
// with no completion affordance, and its chip says so in its accessibility
// label.
//
// **The grid lays itself out by hand.** 42 cells x up to 4 chips is ~200
// views, and putting that in the window's constraint graph is precisely
// AGENTS.md gotcha (15)'s measured cost - a full re-solve of every required
// constraint in the window on any invalidation. `layout()` computing frames
// costs nothing when nothing changes and cannot reach the window's own size
// derivation at all.

import AppKit

// MARK: - The model

/// How much of the calendar is on screen.
enum ShiftCalendarScale: String, CaseIterable {
    case month, week

    var title: String {
        switch self {
        case .month: return "Month"
        case .week: return "Week"
        }
    }
}

/// One task's appearance on one day.
///
/// A value rather than a view so the placement rules are assertable without a
/// window - which is what lets the recurrence projection be covered by the
/// blocking CI lane rather than only by the windowed one.
struct ShiftCalendarEntry: Equatable {
    var taskID: String
    var title: String
    var day: String          // "YYYY-MM-DD"
    var time: String?        // "HH:MM", nil for an all-day task
    var projectID: String?
    var priority: ShiftPriority
    /// `true` for a date the recurrence rule produces but no task record
    /// exists for yet - see this file's header.
    var isProjected: Bool
    var isCompleted: Bool
}

/// What lands on which day. Pure; no AppKit.
enum ShiftCalendarModel {

    /// Every entry falling inside `[from, through]`, sorted by time then
    /// title so two runs of the same data produce the same grid.
    ///
    /// A task contributes its own due date when that date is in range, and -
    /// if it carries a rule - every occurrence the rule produces in range
    /// after it. The real record is always the earliest of the two, because
    /// `next(after:)` never returns the anchor itself.
    ///
    /// `perTaskLimit` bounds a daily rule across a long window (GL-35).
    static func entries(tasks: [ShiftTask], from: Date, through: Date,
                        calendar: Calendar = .current,
                        perTaskLimit: Int = 200) -> [ShiftCalendarEntry] {
        var out: [ShiftCalendarEntry] = []
        for task in tasks {
            guard let dueDate = task.dueDate else { continue }
            guard let anchor = ShiftDateFormatting.dateTime(from: dueDate, time: task.dueTime) else { continue }

            if anchor >= calendar.startOfDay(for: from) && anchor <= through {
                out.append(entry(for: task, day: dueDate, time: task.dueTime, projected: false))
            }
            guard let rule = task.recurrence else { continue }
            // A completed task's rule has already been advanced by
            // `ShiftStore.nextOccurrence` into a real successor record, so
            // projecting it again would double every repeated task on the
            // grid for as long as the completed one stays in the Done window.
            guard task.status != .completed, task.status != .cancelled else { continue }
            let projected = rule.occurrences(anchor: anchor, from: max(from, anchor.addingTimeInterval(1)),
                                             through: through, calendar: calendar, limit: perTaskLimit)
            for date in projected {
                let (day, time) = ShiftDateFormatting.components(from: date)
                out.append(entry(for: task, day: day, time: task.dueTime == nil ? nil : time, projected: true))
            }
        }
        return out.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            // An all-day task sorts above a timed one: it is the day's
            // heading, not an event inside it.
            switch (lhs.time, rhs.time) {
            case let (l?, r?) where l != r: return l < r
            case (nil, .some): return true
            case (.some, nil): return false
            default: return lhs.title < rhs.title
            }
        }
    }

    private static func entry(for task: ShiftTask, day: String, time: String?,
                              projected: Bool) -> ShiftCalendarEntry {
        ShiftCalendarEntry(taskID: task.id, title: task.title, day: day, time: time,
                           projectID: task.projectID, priority: task.priority,
                           isProjected: projected,
                           isCompleted: task.status == .completed)
    }

    /// The grid's own date range: whole weeks covering `anchor`'s month (six
    /// rows, always - a five-row month that becomes six the next month makes
    /// the page jump), or the single week containing it.
    ///
    /// Always starts on the captain's own locale's first weekday, which is
    /// also the order the editor's weekday chips use.
    static func range(for anchor: Date, scale: ShiftCalendarScale,
                      calendar: Calendar = .current) -> (start: Date, days: Int) {
        let startOfDay = calendar.startOfDay(for: anchor)
        switch scale {
        case .week:
            return (weekStart(of: startOfDay, calendar: calendar), 7)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: startOfDay)
            let firstOfMonth = calendar.date(from: components) ?? startOfDay
            return (weekStart(of: firstOfMonth, calendar: calendar), 42)
        }
    }

    static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        var back = weekday - calendar.firstWeekday
        if back < 0 { back += 7 }
        return calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: date)) ?? date
    }
}

// MARK: - The view

final class ShiftCalendarView: NSView {

    /// Opens the task behind a chip - the same `ShiftController.openBoardTask`
    /// path the board's cards use, so there is one "open a task" in this page.
    var onOpenTask: ((String) -> Void)?
    /// A new task on a clicked day, pre-dated to it.
    var onAddTask: ((String) -> Void)?

    private(set) var scale: ShiftCalendarScale = .month
    private(set) var anchor: Date = Date()

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let scaleTabs = HelmSegmentedTabs(items: ShiftCalendarScale.allCases.map {
        .init(id: $0.rawValue, title: $0.title)
    }, selected: ShiftCalendarScale.month.rawValue, size: .compact)
    private lazy var previousButton = HelmButton(symbol: "chevron.left", variant: .secondary, size: .small,
                                                 target: self, action: #selector(goPrevious))
    private lazy var todayButton = HelmButton(title: "Today", variant: .secondary, size: .small,
                                              target: self, action: #selector(goToday))
    private lazy var nextButton = HelmButton(symbol: "chevron.right", variant: .secondary, size: .small,
                                             target: self, action: #selector(goNext))

    private let weekdayHeader = ShiftCalendarWeekdayHeader()
    private let grid = ShiftCalendarGridView()
    private var gridHeight: NSLayoutConstraint?

    private var tasks: [ShiftTask] = []
    private var projects: [ShiftProject] = []

    /// The grid's own height, per scale. A required constant is safe here in
    /// a way a required *width* is not (AGENTS.md gotcha (13) is about a
    /// content minimum reaching the window through a page's width): this page
    /// is inside a vertical scroll view, so a tall grid scrolls rather than
    /// growing the window.
    private static let monthHeight: CGFloat = 588
    private static let weekHeight: CGFloat = 340

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = HelmType.sectionTitle()
        subtitleLabel.font = HelmType.captionSmall()
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scaleTabs.onSelect = { [weak self] id in
            guard let self, let scale = ShiftCalendarScale(rawValue: id) else { return }
            self.setScale(scale)
        }
        for control in [previousButton, todayButton, nextButton] {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        previousButton.setAccessibilityLabel("Previous")
        nextButton.setAccessibilityLabel("Next")

        let navStack = NSStackView(views: [previousButton, todayButton, nextButton])
        navStack.orientation = .horizontal
        navStack.spacing = HelmMetrics.s1 + 2
        navStack.distribution = .fill
        navStack.setHuggingPriority(.required, for: .horizontal)

        let toolbar = NSStackView(views: [titleStack, navStack, scaleTabs])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = HelmMetrics.s3
        // AGENTS.md gotcha (10)/(12): `.fill` plus stack-level hugging on the
        // nested stacks, because content-priority APIs are no-ops on a view
        // with no intrinsic size and an `NSStackView` has none.
        toolbar.distribution = .fill
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        grid.onOpenTask = { [weak self] id in self?.onOpenTask?(id) }
        grid.onAddTask = { [weak self] day in self?.onAddTask?(day) }

        let stack = NSStackView(views: [toolbar, weekdayHeader, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let height = grid.heightAnchor.constraint(equalToConstant: Self.monthHeight)
        gridHeight = height
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            weekdayHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            height,
        ])
        applyTheme(ThemeManager.shared.theme)
    }

    // MARK: Data

    func configure(tasks: [ShiftTask], projects: [ShiftProject]) {
        self.tasks = tasks
        self.projects = projects
        rebuild()
    }

    func setScale(_ scale: ShiftCalendarScale) {
        guard scale != self.scale else { return }
        self.scale = scale
        scaleTabs.select(scale.rawValue)
        gridHeight?.constant = scale == .month ? Self.monthHeight : Self.weekHeight
        rebuild()
    }

    /// Moves the window to the period containing `date` - how the page jumps
    /// to a task's own month when something else selects it.
    func show(date: Date) {
        anchor = date
        rebuild()
    }

    @objc private func goPrevious() { step(-1) }
    @objc private func goNext() { step(1) }
    @objc private func goToday() {
        anchor = Date()
        rebuild()
    }

    private func step(_ direction: Int) {
        let calendar = Calendar.current
        let unit: Calendar.Component = scale == .month ? .month : .weekOfYear
        anchor = calendar.date(byAdding: unit, value: direction, to: anchor) ?? anchor
        rebuild()
    }

    private func rebuild() {
        let calendar = Calendar.current
        let (start, days) = ShiftCalendarModel.range(for: anchor, scale: scale, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? start
        let entries = ShiftCalendarModel.entries(tasks: tasks, from: start,
                                                 through: end.addingTimeInterval(-1), calendar: calendar)
        var byDay: [String: [ShiftCalendarEntry]] = [:]
        for entry in entries { byDay[entry.day, default: []].append(entry) }

        titleLabel.stringValue = Self.periodTitle(anchor: anchor, scale: scale, start: start, days: days)
        let projected = entries.filter(\.isProjected).count
        subtitleLabel.stringValue = Self.subtitle(total: entries.count, projected: projected)

        grid.configure(start: start, days: days, anchorMonth: anchor, scale: scale,
                       entriesByDay: byDay, projects: projects)
        weekdayHeader.configure(start: start)
        applyTheme(ThemeManager.shared.theme)
    }

    /// "September 2026", or "14 - 20 Sep 2026" for a week.
    static func periodTitle(anchor: Date, scale: ShiftCalendarScale, start: Date, days: Int,
                            calendar: Calendar = .current) -> String {
        switch scale {
        case .month:
            return monthYearFormatter.string(from: anchor)
        case .week:
            let last = calendar.date(byAdding: .day, value: days - 1, to: start) ?? start
            return "\(dayMonthFormatter.string(from: start)) - \(monthDayYearFormatter.string(from: last))"
        }
    }

    /// GL-14: "no tasks in this month" is a real, stated answer, never a
    /// blank grid the reader has to interpret. The projected count is stated
    /// separately because a month showing 40 chips of which 35 are
    /// projections is a different fact from a month with 40 real tasks.
    static func subtitle(total: Int, projected: Int) -> String {
        guard total > 0 else { return "Nothing scheduled in this period." }
        let real = total - projected
        var text = real == 1 ? "1 task" : "\(real) tasks"
        if projected > 0 { text += ", \(projected) projected from a repeat rule" }
        return text
    }

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMy")
        return f
    }()

    private static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let monthDayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdy")
        return f
    }()

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        scaleTabs.applyTheme(theme)
        weekdayHeader.applyTheme(theme)
        grid.applyTheme(theme)
    }

    // MARK: Debug hooks (GL-27)

    #if FM_SELFTESTS
    var debugScale: ShiftCalendarScale { scale }
    var debugTitle: String { titleLabel.stringValue }
    var debugSubtitle: String { subtitleLabel.stringValue }
    var debugCells: [ShiftCalendarDayCell] { grid.debugCells }
    func debugCell(day: String) -> ShiftCalendarDayCell? { grid.debugCells.first { $0.day == day } }
    func debugSelectScale(_ scale: ShiftCalendarScale) { setScale(scale) }
    func debugStep(_ direction: Int) { step(direction) }
    #endif
}

// MARK: - The weekday header

/// The seven column headings, in the captain's own locale's week order.
final class ShiftCalendarWeekdayHeader: NSView {
    private var labels: [NSTextField] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        for _ in 0..<7 {
            let label = NSTextField(labelWithString: "")
            label.font = HelmType.kicker()
            label.alignment = .center
            addSubview(label)
            labels.append(label)
        }
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(start: Date) {
        let calendar = Calendar.current
        for (index, label) in labels.enumerated() {
            guard let date = calendar.date(byAdding: .day, value: index, to: start) else { continue }
            label.stringValue = Self.headingFormatter.string(from: date).uppercased()
        }
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width / 7
        for (index, label) in labels.enumerated() {
            label.frame = NSRect(x: CGFloat(index) * width, y: 4, width: width, height: 14)
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        for label in labels { label.textColor = HelmTheme.mutedInk(theme) }
    }

    private static let headingFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
}

// MARK: - The grid

/// The 7-column grid of day cells. Lays its own cells out - see this file's
/// header for why this is not Auto Layout.
final class ShiftCalendarGridView: NSView {

    var onOpenTask: ((String) -> Void)?
    var onAddTask: ((String) -> Void)?

    private var cells: [ShiftCalendarDayCell] = []
    private var rows = 6

    /// The gap between two cells, which is where the grid's own background
    /// is seen. One point, not `HelmMetrics.s1`: this is a rule between two
    /// days, not spacing between two cards.
    private static let hairline: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func configure(start: Date, days: Int, anchorMonth: Date, scale: ShiftCalendarScale,
                   entriesByDay: [String: [ShiftCalendarEntry]], projects: [ShiftProject]) {
        let calendar = Calendar.current
        rows = max(1, days / 7)
        // Cells are reused rather than rebuilt: a month step is a re-fill of
        // 42 existing views, not 42 teardowns and 42 constructions, which is
        // what keeps paging through a year from churning the view tree.
        while cells.count < days {
            let cell = ShiftCalendarDayCell()
            cell.onOpenTask = { [weak self] id in self?.onOpenTask?(id) }
            cell.onAddTask = { [weak self] day in self?.onAddTask?(day) }
            addSubview(cell)
            cells.append(cell)
        }
        for (index, cell) in cells.enumerated() {
            guard index < days else {
                cell.isHidden = true
                continue
            }
            cell.isHidden = false
            let date = calendar.date(byAdding: .day, value: index, to: start) ?? start
            let day = ShiftDateFormatting.components(from: date).0
            cell.configure(date: date, day: day,
                           inFocusMonth: scale == .week
                               || calendar.isDate(date, equalTo: anchorMonth, toGranularity: .month),
                           isToday: calendar.isDateInToday(date),
                           entries: entriesByDay[day] ?? [],
                           projects: projects,
                           maxChips: scale == .month ? 3 : 8)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let visible = cells.filter { !$0.isHidden }
        guard !visible.isEmpty else { return }
        let columnWidth = bounds.width / 7
        let rowHeight = bounds.height / CGFloat(rows)
        for (index, cell) in visible.enumerated() {
            let column = index % 7
            let row = index / 7
            // Integral frames: a fractional column width on a non-retina
            // scale leaves a visible seam between two cells that both round
            // their own edges independently.
            let x = (CGFloat(column) * columnWidth).rounded()
            let nextX = (CGFloat(column + 1) * columnWidth).rounded()
            let y = (CGFloat(row) * rowHeight).rounded()
            let nextY = (CGFloat(row + 1) * rowHeight).rounded()
            // Inset by the hairline so the grid's own background shows
            // *between* the cells rather than only around them. Measured in a
            // real render (`docs/history/34-recurrence-and-calendar.md`): with
            // the cells tiled edge to edge, a light theme's card and page
            // tones are close enough that the whole month read as one
            // undifferentiated field with no day boundaries at all.
            cell.frame = NSRect(x: x, y: y,
                                width: nextX - x - Self.hairline,
                                height: nextY - y - Self.hairline)
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        // The grid is the line colour and the cells are drawn on top of it,
        // so the 1pt gaps between them read as the rules of the calendar.
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(theme.isDaylight ? 1 : 0.5).cgColor
        layer?.cornerRadius = HelmMetrics.rCard
        layer?.masksToBounds = true
        for cell in cells { cell.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    var debugCells: [ShiftCalendarDayCell] { cells.filter { !$0.isHidden } }
    #endif
}

// MARK: - One day

/// One day of the grid: its number, its chips, and an overflow count.
final class ShiftCalendarDayCell: HoverHighlightView {

    var onOpenTask: ((String) -> Void)?
    var onAddTask: ((String) -> Void)?

    private(set) var day: String = ""
    private(set) var entries: [ShiftCalendarEntry] = []

    private let numberLabel = NSTextField(labelWithString: "")
    private let todayPill = NSView()
    private let overflowLabel = NSTextField(labelWithString: "")
    private var chips: [ShiftCalendarChipView] = []
    private var inFocusMonth = true
    private var isToday = false
    private var maxChips = 3
    private var projects: [ShiftProject] = []

    /// The cell's own inner inset, and the chip height. Constants rather than
    /// `HelmMetrics` spacings because the grid's rhythm is a cell size, not
    /// the page's stack spacing.
    private static let inset: CGFloat = 5
    private static let chipHeight: CGFloat = 17
    private static let headerHeight: CGFloat = 19

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // GL-16: a clickable surface is a `HoverHighlightView`, which supplies
        // the role, the focus ring and the keyboard press.
        setAccessibilityRole(.button)
        numberLabel.font = HelmType.captionSmall()
        numberLabel.alignment = .center
        todayPill.wantsLayer = true
        overflowLabel.font = HelmType.captionSmall()
        addSubview(todayPill)
        addSubview(numberLabel)
        addSubview(overflowLabel)

        let click = NSClickGestureRecognizer(target: self, action: #selector(cellClicked))
        click.numberOfClicksRequired = 2
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func configure(date: Date, day: String, inFocusMonth: Bool, isToday: Bool,
                   entries: [ShiftCalendarEntry], projects: [ShiftProject], maxChips: Int) {
        self.day = day
        self.entries = entries
        self.inFocusMonth = inFocusMonth
        self.isToday = isToday
        self.maxChips = maxChips
        self.projects = projects

        numberLabel.stringValue = "\(Calendar.current.component(.day, from: date))"
        todayPill.isHidden = !isToday

        let shown = Array(entries.prefix(maxChips))
        while chips.count < shown.count {
            let chip = ShiftCalendarChipView()
            chip.onClick = { [weak self] id in self?.onOpenTask?(id) }
            addSubview(chip)
            chips.append(chip)
        }
        for (index, chip) in chips.enumerated() {
            guard index < shown.count else {
                chip.isHidden = true
                continue
            }
            chip.isHidden = false
            chip.configure(entry: shown[index])
        }
        let hidden = entries.count - shown.count
        overflowLabel.isHidden = hidden <= 0
        overflowLabel.stringValue = hidden > 0 ? "+\(hidden) more" : ""

        // The whole day is one accessible element: its date and what is on
        // it, so a screen reader is not asked to walk 42 unlabelled boxes.
        setAccessibilityLabel(Self.accessibilityLabel(day: day, entries: entries))
        needsLayout = true
        applyTheme(ThemeManager.shared.theme)
    }

    /// Spelled out rather than derived at read time so the projected chips
    /// are *named* as projections - the one fact a sighted reader gets from
    /// the reduced alpha and nobody else would.
    static func accessibilityLabel(day: String, entries: [ShiftCalendarEntry]) -> String {
        let date = ShiftDateFormatting.friendly(day)
        guard !entries.isEmpty else { return "\(date), nothing scheduled" }
        let described = entries.map { $0.isProjected ? "\($0.title), repeats" : $0.title }
        return "\(date), \(entries.count) item\(entries.count == 1 ? "" : "s"): " + described.joined(separator: ", ")
    }

    @objc private func cellClicked() {
        onAddTask?(day)
    }

    override func layout() {
        super.layout()
        let width = bounds.width - Self.inset * 2
        todayPill.frame = NSRect(x: bounds.width - Self.inset - 22, y: Self.inset - 1, width: 22, height: 16)
        todayPill.layer?.cornerRadius = 8
        numberLabel.frame = NSRect(x: bounds.width - Self.inset - 22, y: Self.inset, width: 22, height: 14)

        var y = Self.headerHeight
        for chip in chips where !chip.isHidden {
            chip.frame = NSRect(x: Self.inset, y: y, width: width, height: Self.chipHeight)
            y += Self.chipHeight + 2
        }
        overflowLabel.frame = NSRect(x: Self.inset + 2, y: y, width: width, height: 13)
    }

    func applyTheme(_ theme: HelmTheme) {
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        // An out-of-month day is the page's own background rather than a
        // card: the grid is a single surface with hairlines between cells,
        // so a day outside the month recedes into the page instead of
        // becoming a second card colour.
        let fill = inFocusMonth ? surface : HelmTheme.nsColor(theme.backgroundHex)
        normalColor = fill
        hoverColor = fill.hoverShifted(by: 0.08, forMode: theme.mode)
        cornerRadius = 0
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        if isToday {
            let accent = HelmTheme.nsColor(theme.accentHex)
            todayPill.layer?.backgroundColor = accent.cgColor
            // GL-16 / the tint rule: an accent *fill* is safe, an accent
            // label is not - the number on the pill goes through the
            // contrast helper rather than being assumed readable.
            numberLabel.textColor = HelmContrast.legibleOn(fill: accent, preferring: ink)
        } else {
            numberLabel.textColor = inFocusMonth ? ink : muted
        }
        overflowLabel.textColor = muted
        for chip in chips { chip.applyTheme(theme, projects: projects) }
    }

    #if FM_SELFTESTS
    var debugChipTitles: [String] { chips.filter { !$0.isHidden }.map(\.title) }
    var debugProjectedFlags: [Bool] { chips.filter { !$0.isHidden }.map(\.isProjected) }
    var debugOverflowText: String { overflowLabel.isHidden ? "" : overflowLabel.stringValue }
    var debugIsToday: Bool { isToday }
    var debugInFocusMonth: Bool { inFocusMonth }
    var debugChipAlphas: [CGFloat] { chips.filter { !$0.isHidden }.map(\.alphaValue) }
    #endif
}

// MARK: - One chip

/// One task on one day.
final class ShiftCalendarChipView: HoverHighlightView {

    var onClick: ((String) -> Void)?

    private(set) var taskID: String = ""
    private(set) var title: String = ""
    private(set) var isProjected = false

    private let bar = NSView()
    private let label = NSTextField(labelWithString: "")
    private let repeatIcon = NSImageView()
    private var tint: HelmTint = .neutral
    private var isCompleted = false

    /// How faint a projected occurrence is drawn. Low enough to read as
    /// "not yet real" beside a solid chip, high enough to stay legible -
    /// the chip's own label still goes through `HelmContrast`, so this only
    /// moves the whole chip, never its contrast against its own fill.
    static let projectedAlpha: CGFloat = 0.55

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
        bar.wantsLayer = true
        label.font = HelmType.captionSmall()
        label.lineBreakMode = .byTruncatingTail
        repeatIcon.image = HelmSymbol.image("repeat", pointSize: 8, weight: .semibold)
        addSubview(bar)
        addSubview(label)
        addSubview(repeatIcon)
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func configure(entry: ShiftCalendarEntry) {
        taskID = entry.taskID
        title = entry.title
        isProjected = entry.isProjected
        isCompleted = entry.isCompleted
        tint = ShiftProjectPalette.tint(forProjectID: entry.projectID)
        let prefix = entry.time.map { "\(ShiftDateFormatting.clock($0)) " } ?? ""
        label.stringValue = prefix + entry.title
        repeatIcon.isHidden = !entry.isProjected
        alphaValue = entry.isProjected ? Self.projectedAlpha : 1
        setAccessibilityLabel(entry.isProjected ? "\(entry.title), repeats on this day" : entry.title)
        needsLayout = true
    }

    @objc private func clicked() {
        onClick?(taskID)
    }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: 0, width: 3, height: bounds.height)
        let iconWidth: CGFloat = repeatIcon.isHidden ? 0 : 13
        label.frame = NSRect(x: 6, y: 1, width: max(0, bounds.width - 8 - iconWidth), height: bounds.height - 2)
        repeatIcon.frame = NSRect(x: bounds.width - iconWidth - 1, y: 3, width: max(0, iconWidth - 2),
                                  height: bounds.height - 6)
    }

    func applyTheme(_ theme: HelmTheme, projects: [ShiftProject]) {
        _ = projects
        // A tinted chip is a tinted *surface*, so the fill and the label both
        // come from `HelmContrast.tintedSurface` rather than being picked -
        // AGENTS.md's colour rule: a `HelmTint` hue is safe as a fill and is
        // not automatically safe as text.
        //
        // `.neutral` is the exception, and it has to be: `ShiftProjectPalette`
        // resolves a task with **no project** to `.neutral`, which is
        // `chromeInkHex` - full page ink. Washed as a surface that produces a
        // near-black bar on a light page, which is what a real render showed:
        // the commonest chip on the grid was also its heaviest. An
        // unprojected task gets the app's own well fill instead, which is the
        // same "no identity signal" treatment the board's cards already use.
        let fill: NSColor
        let foreground: NSColor
        if tint == .neutral {
            fill = HelmField.fill(theme)
            foreground = HelmTheme.nsColor(theme.chromeInkHex)
        } else {
            let surface = HelmContrast.tintedSurface(tintHex: tint.hex(in: theme), theme: theme,
                                                     target: HelmContrast.textTarget)
            fill = surface.fill
            foreground = surface.foreground
        }
        normalColor = fill
        hoverColor = fill.hoverShifted(by: 0.12, forMode: theme.mode)
        cornerRadius = HelmMetrics.rChip - 2
        bar.layer?.backgroundColor = tint == .neutral
            ? HelmTheme.mutedInk(theme).cgColor
            : HelmTheme.nsColor(tint.hex(in: theme)).cgColor
        label.textColor = foreground
        repeatIcon.contentTintColor = foreground
        if isCompleted {
            label.attributedStringValue = NSAttributedString(
                string: label.stringValue,
                attributes: [.font: HelmType.captionSmall(), .foregroundColor: foreground,
                             .strikethroughStyle: NSUnderlineStyle.single.rawValue])
        }
    }
}
