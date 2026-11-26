// Grand Line - native macOS app.
//
// F-02 of full review 4: the two sheets over Home.
//
//  - `PlanMyDaySheet`: step 1 picks up to three tasks, step 2 places them on
//    today's timeline around the meetings, and its last button saves the plan
//    and starts the first focus session (step 3 is the result: the plan is
//    Home's hero, and the toolbar's timer chip is counting).
//  - `CloseTheDaySheet`: ticks what got done, moves the rest, and keeps one
//    line for tomorrow.
//
// Both are a `HelmFormSheet` (the app's one editor-sheet scaffold). The plan
// sheet rebuilds its form for each step inside one root view, so the sheet
// window stays put while its content changes. Every decision is in
// `DayPlanRules`; these views only draw it and route clicks.

import AppKit

// MARK: - A pickable task row

/// One task in step 1, or one planned task in Close the day: the task list's
/// own check badge, the title, when it is due, and a High marker.
final class DayPlanTaskRow: NSView {

    let taskID: String
    var onToggle: ((String) -> Void)?
    let badge = ShiftTaskCheckBadge()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let highLabel = NSTextField(labelWithString: "High")
    private let trailing: NSView?
    private(set) var isChecked = false
    private var isMuted = false

    init(taskID: String, title: String, detail: String, isHigh: Bool, trailing: NSView? = nil) {
        self.taskID = taskID
        self.trailing = trailing
        titleLabel = NSTextField(labelWithString: title)
        detailLabel = NSTextField(labelWithString: detail)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        badge.target = self
        badge.action = #selector(toggle)
        badge.setAccessibilityLabel(title)
        titleLabel.font = HelmType.body()
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = HelmType.caption()
        highLabel.font = .systemFont(ofSize: HelmType.scaled(11), weight: .semibold)
        highLabel.isHidden = !isHigh
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s0
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)
        // Gotcha (5): only the text truncates.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [badge, text, highLabel]
        if let trailing { views.append(trailing) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = HelmMetrics.s3
        row.translatesAutoresizingMaskIntoConstraints = false
        for view in [badge, highLabel] + (trailing.map { [$0] } ?? []) {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s1),
        ])
        setAccessibilityElement(false)
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// A click anywhere on the row ticks it. The badge is a real button and
    /// takes its own clicks, so this is a `mouseDown`, not a recognizer that
    /// would swallow the badge's (gotcha (20)).
    override func mouseDown(with event: NSEvent) {
        if let trailing, trailing.frame.contains(convert(event.locationInWindow, from: nil)) { return }
        toggle()
    }

    @objc private func toggle() { onToggle?(taskID) }

    func setChecked(_ checked: Bool, muted: Bool = false) {
        isChecked = checked
        isMuted = muted
        applyTheme(ThemeManager.shared.theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        badge.setChecked(isChecked, tint: HelmTheme.nsColor(theme.accentHex))
        titleLabel.textColor = HelmField.ink(theme)
        detailLabel.textColor = HelmField.mutedInk(theme)
        highLabel.textColor = HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                                             over: HelmField.fill(theme), theme: theme)
        alphaValue = isMuted ? 0.45 : 1
    }

    #if FM_SELFTESTS
    func debugClickBadge() { badge.performClick(nil) }
    var debugTitle: String { titleLabel.stringValue }
    var debugDetail: String { detailLabel.stringValue }
    #endif
}

// MARK: - The timeline

/// Step 2: today from 9:00 to 18:00, meetings as fixed grey blocks and the
/// picks as blocks that drag to move and drag at the bottom edge to resize,
/// snapping to the quarter hour.
final class DayPlanTimelineView: NSView {

    static let hourHeight: CGFloat = 48
    static let gutter: CGFloat = 52
    static let inset: CGFloat = 8
    static let resizeHandle: CGFloat = 7

    var items: [DayPlan.Item] { didSet { needsDisplay = true } }
    var onChange: (([DayPlan.Item]) -> Void)?
    private let meetings: [MacMeeting]
    private let day: Date

    private enum Drag { case move(index: Int, grabOffset: Int), resize(index: Int) }
    private var drag: Drag?

    init(items: [DayPlan.Item], meetings: [MacMeeting], day: Date) {
        self.items = items
        self.meetings = meetings.filter { !$0.isAllDay && Calendar.current.isDate($0.start, inSameDayAs: day) }
        self.day = day
        let hours = CGFloat(DayPlanRules.dayEndMinute - DayPlanRules.dayStartMinute) / 60
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: hours * Self.hourHeight + Self.inset * 2))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: frame.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Today's timeline")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func y(forMinute minute: Int) -> CGFloat {
        Self.inset + CGFloat(minute - DayPlanRules.dayStartMinute) / 60 * Self.hourHeight
    }

    func minute(forY y: CGFloat) -> Int {
        DayPlanRules.dayStartMinute + Int(((y - Self.inset) / Self.hourHeight * 60).rounded())
    }

    func rect(for item: DayPlan.Item) -> NSRect {
        let top = y(forMinute: item.startMinute)
        return NSRect(x: Self.gutter, y: top + 1, width: bounds.width - Self.gutter - 2,
                      height: y(forMinute: item.endMinute) - top - 2)
    }

    private func rect(start: Int, end: Int) -> NSRect {
        let top = y(forMinute: start)
        return NSRect(x: Self.gutter, y: top + 1, width: bounds.width - Self.gutter - 2, height: max(8, y(forMinute: end) - top - 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.theme
        let ink = HelmField.ink(theme)
        let muted = HelmField.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        // Hour lines and labels.
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: HelmType.scaled(11), weight: .regular),
                                                          .foregroundColor: muted]
        for hour in MacCalendarRules.dayStartHour...MacCalendarRules.dayEndHour {
            let y = y(forMinute: hour * 60)
            line.setFill()
            NSRect(x: Self.gutter, y: y, width: bounds.width - Self.gutter, height: 1).fill()
            let label = NSAttributedString(string: "\(hour):00", attributes: labelAttrs)
            label.draw(at: NSPoint(x: Self.gutter - 10 - label.size().width, y: y - label.size().height / 2))
        }

        // Meetings: fixed, muted, striped.
        for meeting in meetings {
            let start = max(DayPlanRules.dayStartMinute, DayPlanRules.minuteOfDay(meeting.start))
            let end = min(DayPlanRules.dayEndMinute, DayPlanRules.minuteOfDay(meeting.end))
            guard end > start else { continue }
            let r = rect(start: start, end: end)
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            HelmField.fill(theme).setFill()
            path.fill()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            line.withAlphaComponent(0.6).setStroke()
            let stripes = NSBezierPath()
            var x = r.minX - r.height
            while x < r.maxX {
                stripes.move(to: NSPoint(x: x, y: r.maxY))
                stripes.line(to: NSPoint(x: x + r.height, y: r.minY))
                x += 8
            }
            stripes.lineWidth = 1
            stripes.stroke()
            NSGraphicsContext.restoreGraphicsState()
            line.setStroke()
            path.lineWidth = 1
            path.stroke()
            let text = "\(DayPlanRules.clock(minute: start)) \(meeting.title) \u{00B7} meeting"
            drawLabel(text, in: r, color: muted, weight: .regular)
        }

        // The picks.
        let surface = HelmContrast.tintedSurface(tintHex: theme.accentHex, theme: theme, target: 4.5)
        for item in items {
            let r = rect(for: item)
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            surface.fill.setFill()
            path.fill()
            let clashes = DayPlanRules.clash(item, meetings: meetings, on: day) != nil
            HelmTheme.nsColor(clashes ? HelmTint.warn.hex(in: theme) : theme.accentHex).setStroke()
            path.lineWidth = clashes ? 2 : 1
            path.stroke()
            // The resize grip.
            surface.foreground.withAlphaComponent(0.5).setFill()
            NSRect(x: r.midX - 10, y: r.maxY - 4, width: 20, height: 2).fill()
            let span = "\(DayPlanRules.clock(minute: item.startMinute)) to \(DayPlanRules.clock(minute: item.endMinute))"
            drawLabel("\(span) \u{00B7} \(item.title)", in: r, color: surface.foreground, weight: .semibold,
                      trailing: DayPlanRules.length(item.minutes))
        }
        _ = ink
    }

    private func drawLabel(_ text: String, in r: NSRect, color: NSColor, weight: NSFont.Weight, trailing: String? = nil) {
        // A quarter-hour block is too short for the 12pt line, so its label
        // drops to 10pt, centred, and clipped to the block.
        let short = r.height < 20
        let font = NSFont.systemFont(ofSize: HelmType.scaled(short ? 9 : 12), weight: weight)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        var trailingWidth: CGFloat = 0
        if let trailing {
            let t = NSAttributedString(string: trailing, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: HelmType.scaled(11), weight: .medium),
                                                                     .foregroundColor: color])
            trailingWidth = t.size().width + HelmMetrics.s3
            t.draw(at: NSPoint(x: r.maxX - HelmMetrics.s2 - t.size().width, y: r.minY + 4))
        }
        let height = ceil(font.ascender - font.descender)
        let top = short ? r.minY + (r.height - height) / 2 : r.minY + 4
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        NSAttributedString(string: text, attributes: attrs)
            .draw(in: NSRect(x: r.minX + HelmMetrics.s2, y: top,
                             width: r.width - HelmMetrics.s2 * 2 - trailingWidth, height: height))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Dragging

    override func mouseDown(with event: NSEvent) {
        beginDrag(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        continueDrag(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { endDrag() }

    override func resetCursorRects() {
        for item in items {
            let r = rect(for: item)
            addCursorRect(NSRect(x: r.minX, y: r.maxY - Self.resizeHandle, width: r.width, height: Self.resizeHandle), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - Self.resizeHandle), cursor: .openHand)
        }
    }

    func beginDrag(at point: NSPoint) {
        guard let index = items.indices.first(where: { rect(for: items[$0]).contains(point) }) else { drag = nil; return }
        let r = rect(for: items[index])
        if point.y >= r.maxY - Self.resizeHandle {
            drag = .resize(index: index)
        } else {
            drag = .move(index: index, grabOffset: minute(forY: point.y) - items[index].startMinute)
        }
    }

    func continueDrag(to point: NSPoint) {
        guard let drag else { return }
        switch drag {
        case let .move(index, grabOffset):
            items[index] = DayPlanRules.moved(items[index], toStart: minute(forY: point.y) - grabOffset)
        case let .resize(index):
            items[index] = DayPlanRules.resized(items[index], toEnd: minute(forY: point.y))
        }
    }

    func endDrag() {
        guard drag != nil else { return }
        drag = nil
        window?.invalidateCursorRects(for: self)
        onChange?(items)
    }
}

// MARK: - Plan my day

final class PlanMyDaySheet: NSViewController {

    /// Called with the saved plan; Home re-renders its hero from it.
    var onSaved: ((DayPlan) -> Void)?

    private let store: ShiftStore
    private let plans: DayPlanStore
    private let meetings: [MacMeeting]
    private let timer: FocusTimerController?
    private let clock: () -> Date
    private let groups: [(group: DayPlanRules.Group, items: [DayPlanRules.Candidate])]
    private let yesterdayNote: String?
    private(set) var picked: [String]
    private(set) var items: [DayPlan.Item] = []
    private(set) var step = 1
    private var rows: [DayPlanTaskRow] = []
    private var countLabel: NSTextField?
    private var freeLabel: NSTextField?
    private var timeline: DayPlanTimelineView?
    private var nextButton: HelmButton?
    private let root = NSView()
    private weak var form: HelmFormSheet?

    init(store: ShiftStore, plans: DayPlanStore, meetings: [MacMeeting], timer: FocusTimerController?,
         clock: @escaping () -> Date = DayRollover.now) {
        self.store = store
        self.plans = plans
        self.meetings = meetings
        self.timer = timer
        self.clock = clock
        let now = clock()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let completed = DayPlanRules.completedIDs(store: store, now: now)
        let lastPlan = plans.plan(on: yesterday)
        let carried = Set(lastPlan?.items.map(\.taskID).filter { !completed.contains($0) } ?? [])
        yesterdayNote = lastPlan?.tomorrowNote
        groups = DayPlanRules.candidates(tasks: store.activeTasks, carried: carried, now: now)
        if let existing = plans.plan(on: now), existing.closedAt == nil {
            // Changing the plan starts from the plan as it stands.
            let open = Set(store.activeTasks.filter(DayPlanRules.isOpen).map(\.id))
            picked = existing.items.map(\.taskID).filter { open.contains($0) }
            items = existing.items.filter { open.contains($0.taskID) }
        } else {
            picked = DayPlanRules.defaultPicks(groups)
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    var hasDatedWork: Bool { groups.contains { $0.group != .backlog } }

    override func loadView() {
        root.frame = NSRect(x: 0, y: 0, width: HelmFormSheet.width + 40, height: 560)
        view = root
        showStep(1)
    }

    private func install(_ form: HelmFormSheet) {
        root.subviews.forEach { $0.removeFromSuperview() }
        form.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            form.topAnchor.constraint(equalTo: root.topAnchor),
            form.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.form = form
        form.sizeToFitContent()
        root.setFrameSize(form.frame.size)
        preferredContentSize = form.frame.size
    }

    func showStep(_ step: Int) {
        self.step = step
        step == 1 ? buildPick() : buildPlace()
    }

    // MARK: Step 1

    private func buildPick() {
        rows = []
        let form = HelmFormSheet(title: hasDatedWork ? "Pick up to three for today" : "Nothing is due today",
                                 maxContentWidth: HelmFormSheet.width + 40)
        form.setSubtitle(hasDatedWork ? "Plan my day \u{00B7} step 1 of 3 \u{00B7} about 2 minutes"
                                      : "Plan my day \u{00B7} nothing is due")
        _ = form.addCaption(hasDatedWork ? "Three is enough to finish. The rest stays where it is."
                                         : "Pick one thing from the backlog, or take the day lightly.")
        if let yesterdayNote {
            _ = form.addInfoCard(symbol: "text.quote", text: "Last night you wrote: \(yesterdayNote)")
        }
        if groups.isEmpty {
            _ = form.addInfoCard(symbol: "sun.max", text: "There are no open tasks. Add one on Tasks, or enjoy the quiet.")
        }
        for (group, candidates) in groups {
            _ = form.addSection(group.title)
            for candidate in candidates {
                let row = DayPlanTaskRow(taskID: candidate.task.id, title: candidate.task.title,
                                         detail: candidate.when, isHigh: candidate.isHigh)
                row.onToggle = { [weak self] id in self?.toggle(id) }
                rows.append(row)
                form.addRow(row)
            }
            form.endSection()
        }
        if !groups.isEmpty {
            countLabel = form.addCaption("")
        }
        let buttons = form.setFooter(target: self, confirmTitle: hasDatedWork ? "Next: place them" : "Pick these",
                                     confirm: #selector(next), cancel: #selector(skip), hintCaption: "to continue")
        buttons.cancel.title = hasDatedWork ? "Skip today" : "Not today"
        nextButton = buttons.confirm
        install(form)
        refreshPicks()
    }

    private func toggle(_ id: String) {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
        } else if DayPlanRules.canPick(more: picked.count) {
            picked.append(id)
        }
        refreshPicks()
    }

    private func refreshPicks() {
        let full = !DayPlanRules.canPick(more: picked.count)
        for row in rows {
            let on = picked.contains(row.taskID)
            row.setChecked(on, muted: full && !on)
        }
        countLabel?.stringValue = DayPlanRules.pickedSentence(picked.count)
        nextButton?.isEnabled = step == 2 || !picked.isEmpty
    }

    @objc private func next() {
        guard !picked.isEmpty else { return }
        let tasks = picked.compactMap { id in store.activeTasks.first { $0.id == id } }
        // Keep the places already set for picks that stay; place the rest.
        let kept = items.filter { picked.contains($0.taskID) }
        let fresh = DayPlanRules.place(tasks.filter { t in !kept.contains { $0.taskID == t.id } },
                                       meetings: meetings + kept.map { Self.asMeeting($0, day: clock()) }, now: clock())
        items = (kept + fresh).sorted { $0.startMinute < $1.startMinute }
        showStep(2)
    }

    /// A placed item as a busy block, so new picks are placed around it.
    static func asMeeting(_ item: DayPlan.Item, day: Date) -> MacMeeting {
        MacMeeting(id: item.taskID, title: item.title, start: DayPlanRules.date(minute: item.startMinute, on: day),
                   end: DayPlanRules.date(minute: item.endMinute, on: day), isAllDay: false, calendarID: "plan",
                   calendarTitle: "", calendarSource: "", colorHex: "", location: nil, organizer: nil, attendeeCount: 0)
    }

    @objc private func skip() { dismissSheet() }

    // MARK: Step 2

    private var startsFocus: Bool { timer != nil && timer?.isRunning != true }

    private func buildPlace() {
        let form = HelmFormSheet(title: "Place them on today", maxContentWidth: HelmFormSheet.width + 40)
        form.setSubtitle("Plan my day \u{00B7} step 2 of 3")
        _ = form.addCaption("Drag a block to move it, and drag its bottom edge to resize. Meetings stay where they are.")
        let timeline = DayPlanTimelineView(items: items, meetings: meetings, day: clock())
        timeline.onChange = { [weak self] items in
            self?.items = items
            self?.refreshFree()
        }
        self.timeline = timeline
        form.addRow(timeline)
        freeLabel = form.addCaption("")
        let buttons = form.setFooter(target: self, confirmTitle: startsFocus ? "Start focus" : "Save the plan",
                                     confirm: #selector(save), cancel: #selector(skip),
                                     delete: ("Back", #selector(back)),
                                     hintCaption: startsFocus ? "to start" : "to save")
        // The left button is Back, not a delete; Cancel is the close square.
        buttons.delete?.variant = .secondary
        buttons.cancel.isHidden = true
        nextButton = buttons.confirm
        install(form)
        refreshFree()
    }

    private func refreshFree() {
        let free = DayPlanRules.freeMinutes(items: items, meetings: meetings, now: clock())
        let clashes = items.compactMap { item in DayPlanRules.clash(item, meetings: meetings, on: clock()).map { (item, $0) } }
        if let (item, meeting) = clashes.first {
            freeLabel?.stringValue = "\(item.title) overlaps \(meeting.title). \(DayPlanRules.freeSentence(free))."
        } else {
            freeLabel?.stringValue = "\(DayPlanRules.freeSentence(free))."
        }
    }

    @objc private func back() { showStep(1) }

    /// Saves the plan and, when nothing is focusing yet, starts the first
    /// session: step 3.
    @objc func save() {
        let now = clock()
        var plan = plans.plan(on: now) ?? DayPlan(day: DayPlanRules.dayString(now), setAt: now, items: [])
        plan.items = items
        plan.setAt = now
        plan.closedAt = nil
        plans.save(plan)
        if startsFocus, let first = DayPlanRules.nextItem(plan, completed: []),
           let task = store.activeTasks.first(where: { $0.id == first.taskID }) {
            timer?.start(task: task)
        }
        onSaved?(plan)
        dismissSheet()
    }

    private func dismissSheet() {
        if presentingViewController != nil { dismiss(nil) } else { view.window?.close() }
    }

    #if FM_SELFTESTS
    var debugRows: [DayPlanTaskRow] { rows }
    var debugCount: String { countLabel?.stringValue ?? "" }
    var debugFree: String { freeLabel?.stringValue ?? "" }
    var debugTimeline: DayPlanTimelineView? { timeline }
    var debugNextButton: HelmButton? { nextButton }
    var debugTitle: String { form?.headingLabel.stringValue ?? "" }
    func debugNext() { next() }
    func debugBack() { back() }
    func debugSave() { save() }
    #endif
}

// MARK: - Close the day

final class CloseTheDaySheet: NSViewController {

    var onClosed: ((DayPlan) -> Void)?

    private let plan: DayPlan
    private let store: ShiftStore
    private let plans: DayPlanStore
    private let meetingCount: Int
    private let clock: () -> Date
    private(set) var done: Set<String>
    private(set) var moves: [String: DayPlanRules.Move] = [:]
    private var rows: [DayPlanTaskRow] = []
    private var moveTabs: [String: HelmSegmentedTabs] = [:]
    private var dayFields: [String: HelmDateField] = [:]
    private var dayRows: [String: NSView] = [:]
    private var headline: NSTextField?
    private var detail: NSTextField?
    private let noteField = HelmTextField(placeholder: "Waiting on the CA to sign the staging cert. Chase at 10.")
    private weak var form: HelmFormSheet?

    init(plan: DayPlan, store: ShiftStore, plans: DayPlanStore, meetingCount: Int,
         clock: @escaping () -> Date = DayRollover.now) {
        self.plan = plan
        self.store = store
        self.plans = plans
        self.meetingCount = meetingCount
        self.clock = clock
        done = DayPlanRules.completedIDs(store: store, now: clock()).intersection(plan.items.map(\.taskID))
        super.init(nibName: nil, bundle: nil)
        for item in plan.items where !done.contains(item.taskID) { moves[item.taskID] = .tomorrow }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let form = HelmFormSheet(title: "Close the day", maxContentWidth: HelmFormSheet.width + 40)
        view = form
        self.form = form
        form.setSubtitle("\(DayPlanRules.clockTime(clock())). Tick what got done, and choose where the rest goes.")
        let focus = store.focusSecondsTodayByTask(reference: clock())
        _ = form.addSection("Today\u{2019}s plan")
        headline = form.addCaption("")
        headline?.font = HelmType.rowTitle()
        detail = form.addCaption("")
        for item in plan.items {
            let seconds = focus[item.taskID] ?? 0
            let detailText = seconds > 0 ? "focus \(DayPlanRules.length(max(1, seconds / 60)))"
                                         : "\(DayPlanRules.clock(minute: item.startMinute)) \u{00B7} \(DayPlanRules.length(item.minutes))"
            let tabs = HelmSegmentedTabs(items: [.init(id: "tomorrow", title: "Tomorrow"),
                                                 .init(id: "day", title: "Pick a day"),
                                                 .init(id: "backlog", title: "Backlog")],
                                         selected: "tomorrow", size: .compact)
            let id = item.taskID
            tabs.onSelect = { [weak self] choice in self?.choose(choice, for: id) }
            // Gotcha (12): the tabs have no intrinsic width, so a hugging
            // priority cannot stop them taking the row's slack. A fixed width
            // keeps every row's tabs on the same right edge.
            tabs.widthAnchor.constraint(equalToConstant: ceil(tabs.fittingSize.width)).isActive = true
            moveTabs[id] = tabs
            let row = DayPlanTaskRow(taskID: id, title: item.title, detail: detailText, isHigh: false, trailing: tabs)
            row.toolTip = item.title
            row.onToggle = { [weak self] id in self?.toggle(id) }
            rows.append(row)
            form.addRow(row)
            let dayField = HelmDateField(elements: [.yearMonthDay])
            let calendar = Calendar.current
            dayField.dateValue = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: clock())) ?? clock()
            dayField.onChange = { [weak self] date in self?.moves[id] = .day(date) }
            dayFields[id] = dayField
            let dayRow = form.addField("Move \u{201C}\(item.title)\u{201D} to", dayField)
            dayRow.isHidden = true
            dayRows[id] = dayRow
        }
        form.endSection()
        _ = form.addSection("One line for tomorrow (optional)")
        form.addRow(noteField)
        form.endSection()
        let buttons = form.setFooter(target: self, confirmTitle: "Close the day", confirm: #selector(closeDay),
                                     cancel: #selector(later), hintCaption: "to close the day")
        buttons.cancel.title = "Later"
        refresh()
        form.sizeToFitContent()
    }

    private func toggle(_ id: String) {
        if done.contains(id) {
            done.remove(id)
            if moves[id] == nil { moves[id] = .tomorrow }
        } else {
            done.insert(id)
        }
        refresh()
    }

    private func choose(_ choice: String, for id: String) {
        switch choice {
        case "day": moves[id] = .day(dayFields[id]?.dateValue ?? clock())
        case "backlog": moves[id] = .backlog
        default: moves[id] = .tomorrow
        }
        refresh()
    }

    private func refresh() {
        let toMove = plan.items.filter { !done.contains($0.taskID) }.count
        headline?.stringValue = DayPlanRules.closeHeadline(done: done.count, total: plan.items.count)
        detail?.stringValue = DayPlanRules.closeDetail(focusSeconds: store.focusSecondsToday(reference: clock()),
                                                       meetings: meetingCount, toMove: toMove)
        for row in rows {
            let isDone = done.contains(row.taskID)
            row.setChecked(isDone)
            moveTabs[row.taskID]?.isHidden = isDone
            let picksDay: Bool
            if case .day = moves[row.taskID] { picksDay = true } else { picksDay = false }
            dayRows[row.taskID]?.isHidden = isDone || !picksDay
        }
    }

    @objc func closeDay() {
        let now = clock()
        let closed = DayPlanRules.close(plan, done: done, moves: moves, note: noteField.stringValue, store: store, now: now)
        plans.save(closed)
        onClosed?(closed)
        later()
    }

    @objc private func later() {
        if presentingViewController != nil { dismiss(nil) } else { view.window?.close() }
    }

    #if FM_SELFTESTS
    var debugRows: [DayPlanTaskRow] { rows }
    var debugHeadline: String { headline?.stringValue ?? "" }
    var debugDetail: String { detail?.stringValue ?? "" }
    func debugChoose(_ choice: String, for id: String) { moveTabs[id]?.debugClickTab(id: choice) }
    func debugSetNote(_ text: String) { noteField.stringValue = text }
    func debugClose() { closeDay() }
    #endif
}
