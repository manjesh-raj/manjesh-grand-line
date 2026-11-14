// Grand Line - native macOS app.
//
// The When panel (tasks-calendar plan PR 5): one component for a task's date,
// time, repeat rule and reminder, in two hosts.
//
//   - **The task editor sheet**, where it replaced the "Set due date" switch
//     and the separate Repeat and Remind cards.
//   - **A popover on the calendar**, from a task's chip or a tray row's
//     Pick… (`ShiftSchedulePopover`, below). The page reports where the
//     chip is and this side presents a real `NSPopover` there.
//
// The rows are the board's: Date with Today, Tomorrow, Next Mon and No date;
// Time as All day or At a time; Repeat; Every N; On (the weekday circles, or
// the monthly choice); Ends; a preview with a five-week strip, the next
// dates and the literal `recurrence:` line; and Remind.
//
// Every control's action is one mutation of `ShiftScheduleDraft`, and every
// row is re-derived from the draft afterwards (`sync()`), so the two hosts and
// the suites drive one set of rules. Nothing here writes a store: the host
// reads `draft` when it saves.

import AppKit

final class ShiftScheduleEditor: NSView {

    /// The schedule as the captain has it now.
    private(set) var draft: ShiftScheduleDraft
    /// A control changed the draft. Not called for `setDraft`.
    var onChange: ((ShiftScheduleDraft) -> Void)?
    /// Rows appeared or disappeared, so the host may need a new height.
    var onHeightChange: (() -> Void)?

    /// `settings.yaml`'s `all_day_reminder_at`, for the Remind wording of a
    /// task with no time.
    private let allDayReminderAt: String
    /// The clock behind Today, Tomorrow and "a repeat with no date starts
    /// today". Injectable so a suite can pin it.
    var now: () -> Date = { Date() }

    static let labelWidth: CGFloat = 52
    private static let rowSpacing: CGFloat = HelmMetrics.s2 + 2

    private let rows = NSStackView()
    private var rowLabels: [NSTextField] = []

    private let dateField = HelmDateField(elements: [.yearMonthDay])
    private var quickButtons: [HelmButton] = []
    private let timeTabs = HelmSegmentedTabs(items: [HelmSegmentedTabs.Item(id: "allDay", title: "All day"),
                                                     HelmSegmentedTabs.Item(id: "atTime", title: "At a time")],
                                             selected: "allDay", size: .compact)
    private let timeField = HelmDateField(elements: [.hourMinute])
    private let repeatPopup = HelmPopUpButton()
    private let intervalDown = HelmButton(symbol: "minus", variant: .secondary, size: .small)
    private let intervalUp = HelmButton(symbol: "plus", variant: .secondary, size: .small)
    private let intervalValue = NSTextField(labelWithString: "1")
    private let unitPopup = HelmPopUpButton()
    private let unitLabel = NSTextField(labelWithString: "week")
    private var weekdayButtons: [HelmButton] = []
    private let monthlyPopup = HelmPopUpButton()
    private let endPopup = HelmPopUpButton()
    private let untilField = HelmDateField(elements: [.yearMonthDay])
    private let countDown = HelmButton(symbol: "minus", variant: .secondary, size: .small)
    private let countUp = HelmButton(symbol: "plus", variant: .secondary, size: .small)
    private let countValue = NSTextField(labelWithString: "10")
    private let countSuffix = NSTextField(labelWithString: "times")
    private let reminderPopup = HelmPopUpButton()

    private let previewCard = NSView()
    private let previewRange = NSTextField(labelWithString: "")
    private let previewCount = NSTextField(labelWithString: "")
    private let previewStrip = ShiftSchedulePreviewStrip()
    private let previewSummary = NSTextField(wrappingLabelWithString: "")
    private let previewDetail = NSTextField(wrappingLabelWithString: "")
    private let previewRule = NSTextField(wrappingLabelWithString: "")

    private var timeRow: NSView!
    private var everyRow: NSView!
    private var weekdayRow: NSView!
    private var monthlyRow: NSView!
    private var endsRow: NSView!
    private var untilHolder: NSView!
    private var countHolder: NSView!

    private var themeToken: ThemeObservation?

    init(draft: ShiftScheduleDraft, allDayReminderAt: String = ShiftDue.defaultAllDayReminderAt) {
        self.draft = draft
        self.allDayReminderAt = allDayReminderAt
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 400))
        translatesAutoresizingMaskIntoConstraints = false
        build()
        sync()
        // After the chrome exists: `observe` fires synchronously at
        // registration (AGENTS.md's theming rules).
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { if let themeToken { ThemeManager.shared.unobserve(themeToken) } }

    /// Replaces the draft from outside (the sheet's title detection) without
    /// calling `onChange`, which is how the sheet tells its own detection
    /// apart from the captain's edits.
    func setDraft(_ newDraft: ShiftScheduleDraft) {
        draft = newDraft
        sync()
    }

    private var today: String { ShiftDateFormatting.components(from: now()).dateStr }

    // MARK: Building

    private func build() {
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Self.rowSpacing
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Date
        dateField.onChange = { [weak self] date in
            self?.edit { $0.setDay(ShiftDateFormatting.components(from: date).dateStr) }
        }
        dateField.setAccessibilityLabel("Due date")
        let quick = hStack([], spacing: HelmMetrics.s1 + 2)
        for (index, title) in ["Today", "Tomorrow", "Next Mon", "No date"].enumerated() {
            let button = HelmButton(title: title, variant: .secondary, size: .small,
                                    target: self, action: #selector(quickClicked(_:)))
            button.tag = index
            quickButtons.append(button)
            quick.addArrangedSubview(rigid(button))
        }
        quick.addArrangedSubview(spacer())
        let dateColumn = NSStackView(views: [dateField, quick])
        dateColumn.orientation = .vertical
        dateColumn.alignment = .leading
        dateColumn.spacing = HelmMetrics.s2 - 2
        dateField.widthAnchor.constraint(equalTo: dateColumn.widthAnchor).isActive = true
        quick.widthAnchor.constraint(equalTo: dateColumn.widthAnchor).isActive = true
        addRow("Date", dateColumn, alignTop: true)

        // Time
        timeTabs.onSelect = { [weak self] id in
            guard let self else { return }
            let today = self.today
            self.edit { draft in
                draft.time = id == "atTime" ? (draft.time ?? Self.defaultTime) : nil
                if draft.time != nil && draft.day == nil { draft.setDay(today) }
            }
        }
        timeField.onChange = { [weak self] date in
            self?.edit { $0.time = ShiftDateFormatting.components(from: date).timeStr }
        }
        timeField.setAccessibilityLabel("Due time")
        timeField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        // AGENTS.md gotcha (12): the segmented control has no intrinsic width,
        // so hugging says nothing about it. A real low-priority `width == 0`,
        // above the spacer's, keeps it at its pills and leaves the slack to
        // the spacer, so the time sits beside it.
        let tabsCollapse = timeTabs.widthAnchor.constraint(equalToConstant: 0)
        tabsCollapse.priority = NSLayoutConstraint.Priority(260)
        tabsCollapse.isActive = true
        timeRow = addRow("Time", hStack([timeTabs, timeField, spacer()], spacing: HelmMetrics.s2))

        // Repeat
        repeatPopup.target = self
        repeatPopup.action = #selector(repeatChosen)
        repeatPopup.setAccessibilityLabel("Repeat")
        addRow("Repeat", repeatPopup)

        // Every
        intervalDown.target = self
        intervalDown.action = #selector(intervalDownClicked)
        intervalDown.setAccessibilityLabel("Fewer")
        intervalUp.target = self
        intervalUp.action = #selector(intervalUpClicked)
        intervalUp.setAccessibilityLabel("More")
        intervalValue.font = HelmType.body()
        intervalValue.alignment = .center
        intervalValue.widthAnchor.constraint(equalToConstant: 26).isActive = true
        unitPopup.addItems(withTitles: ShiftScheduleDraft.Unit.allCases.map { $0.title(plural: false) })
        unitPopup.target = self
        unitPopup.action = #selector(unitChosen)
        unitPopup.setAccessibilityLabel("Unit")
        unitLabel.font = HelmType.body()
        everyRow = addRow("Every", hStack([intervalDown, intervalValue, intervalUp, unitPopup, unitLabel, spacer()],
                                          spacing: HelmMetrics.s1 + 2))

        // On: the weekday circles
        let circles = hStack([], spacing: HelmMetrics.s1 + 1)
        for weekday in Self.weekdayOrder() {
            let name = ShiftRecurrence.longWeekdayName(weekday)
            let button = HelmButton(title: String(ShiftRecurrence.shortWeekdayName(weekday).prefix(1)),
                                    variant: .secondary, size: .small,
                                    target: self, action: #selector(weekdayClicked(_:)))
            button.tag = weekday
            // Two of the seven letters are ambiguous on their own.
            button.setAccessibilityLabel(name)
            button.toolTip = name
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            weekdayButtons.append(button)
            circles.addArrangedSubview(rigid(button))
        }
        circles.addArrangedSubview(spacer())
        weekdayRow = addRow("On", circles)

        // On: the monthly choice
        monthlyPopup.target = self
        monthlyPopup.action = #selector(monthlyChosen)
        monthlyPopup.setAccessibilityLabel("Day of the month")
        monthlyRow = addRow("On", monthlyPopup)

        // Ends
        endPopup.addItems(withTitles: ShiftScheduleDraft.End.allCases.map(\.title))
        endPopup.target = self
        endPopup.action = #selector(endChosen)
        endPopup.setAccessibilityLabel("Ends")
        untilField.onChange = { [weak self] date in
            self?.edit { $0.setUntil(ShiftDateFormatting.components(from: date).dateStr) }
        }
        untilField.setAccessibilityLabel("Last date")
        untilHolder = untilField
        countDown.target = self
        countDown.action = #selector(countDownClicked)
        countDown.setAccessibilityLabel("Fewer times")
        countUp.target = self
        countUp.action = #selector(countUpClicked)
        countUp.setAccessibilityLabel("More times")
        countValue.font = HelmType.body()
        countValue.alignment = .center
        countValue.widthAnchor.constraint(equalToConstant: 30).isActive = true
        countSuffix.font = HelmType.body()
        countHolder = hStack([countDown, countValue, countUp, countSuffix], spacing: HelmMetrics.s1 + 2)
        untilField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        endsRow = addRow("Ends", hStack([endPopup, untilField, countHolder, spacer()], spacing: HelmMetrics.s2))

        // The preview, the panel's full width as the board draws it, so the
        // strip and the rule line are not squeezed under the label column.
        buildPreview()
        rows.addArrangedSubview(previewCard)
        previewCard.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true

        // Remind
        reminderPopup.target = self
        reminderPopup.action = #selector(reminderChosen)
        reminderPopup.setAccessibilityLabel("Remind me")
        addRow("Remind", reminderPopup)
    }

    private func buildPreview() {
        previewCard.wantsLayer = true
        previewCard.layer?.cornerRadius = HelmMetrics.rControl
        previewCard.translatesAutoresizingMaskIntoConstraints = false

        previewRange.font = HelmType.kicker()
        previewCount.font = HelmType.caption()
        previewCount.alignment = .right
        previewCount.setContentHuggingPriority(.required, for: .horizontal)
        previewCount.setContentCompressionResistancePriority(.required, for: .horizontal)
        previewRange.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewRange.lineBreakMode = .byTruncatingTail
        let head = hStack([previewRange, previewCount], spacing: HelmMetrics.s2)
        // The range is this row's flexible member. AGENTS.md gotcha (13): left
        // at `hStack`'s required hug, "no wider than my text" travelled up the
        // card's required width ties and capped the sheet's whole field column
        // at 305pt.
        previewRange.setContentHuggingPriority(.defaultLow, for: .horizontal)

        previewSummary.font = HelmType.rowTitle()
        previewDetail.font = HelmType.caption()
        previewRule.font = HelmType.code()
        previewRule.isSelectable = true
        previewRule.lineBreakMode = .byCharWrapping
        for label in [previewSummary, previewDetail, previewRule] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let column = NSStackView(views: [head, previewStrip, previewSummary, previewDetail, previewRule])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s1 + 2
        column.setCustomSpacing(HelmMetrics.s2, after: previewStrip)
        column.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(column)
        let inset = HelmMetrics.s2 + 2
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: previewCard.topAnchor, constant: inset),
            column.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: inset),
            column.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: -inset),
            column.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: -inset),
        ])
        for view in [head, previewStrip, previewSummary, previewDetail, previewRule] as [NSView] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    /// One labelled row: a fixed label column and a control that fills the
    /// rest. AGENTS.md gotcha (10): `.fill`, with the label rigid and the
    /// control the one view that flexes. The label is centred on a one-line
    /// control, and on the first line of a taller one (`alignTop`, the date
    /// field over its chips).
    @discardableResult
    private func addRow(_ title: String, _ control: NSView, alignTop: Bool = false) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = HelmField.labelFont()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        rowLabels.append(label)
        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = alignTop ? .top : .centerY
        row.spacing = HelmMetrics.s2
        row.translatesAutoresizingMaskIntoConstraints = false
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        if alignTop {
            // The first line is a `HelmField.controlHeight` field.
            label.centerYAnchor.constraint(equalTo: row.topAnchor,
                                           constant: HelmField.controlHeight / 2).isActive = true
        }
        return row
    }

    private func hStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views where !(view is ShiftScheduleSpacer) { rigid(view) }
        return stack
    }

    /// A row's control: it keeps its own width and leaves the slack to the
    /// row's spacer. Applied as each control joins a row, including the ones
    /// added after `hStack` built it.
    @discardableResult
    private func rigid(_ view: NSView) -> NSView {
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(Self.controlCompression, for: .horizontal)
        return view
    }

    /// A spacer that takes a row's slack. AGENTS.md gotcha (12): content
    /// priorities are no-ops on a bare view, so it carries a real low
    /// priority `width == 0`.
    private func spacer() -> NSView {
        let view = ShiftScheduleSpacer()
        view.translatesAutoresizingMaskIntoConstraints = false
        let zero = view.widthAnchor.constraint(equalToConstant: 0)
        zero.priority = .defaultLow
        zero.isActive = true
        return view
    }

    static let defaultTime = "09:00"

    /// How hard a row's controls resist squeezing: above every default, so
    /// the spacer gives way first, and below required. Measured: with
    /// `.required`, the date chips' 324pt under Daylight's bold weight beat
    /// the popover's own 408pt width tie, and AppKit broke the tie instead -
    /// the whole panel rendered 337pt wide. A larger text scale must truncate
    /// a chip, never collapse the panel.
    static let controlCompression = NSLayoutConstraint.Priority(740)

    /// The seven weekdays from the captain's own first weekday, the order of
    /// the calendar's columns.
    static func weekdayOrder(calendar: Calendar = .current) -> [Int] {
        (0..<7).map { ((calendar.firstWeekday - 1 + $0) % 7) + 1 }
    }

    // MARK: Actions

    private func edit(_ change: (inout ShiftScheduleDraft) -> Void) {
        var next = draft
        change(&next)
        guard next != draft else {
            sync()
            return
        }
        draft = next
        sync()
        onChange?(draft)
    }

    @objc private func quickClicked(_ sender: HelmButton) {
        let quick = ShiftScheduleDraft.quickDays(today: today)
        if sender.tag < quick.count {
            let day = quick[sender.tag].day
            edit { $0.setDay(day) }
        } else {
            edit { $0.setDay(nil) }
        }
    }

    @objc private func repeatChosen() {
        let kinds = repeatMenu
        let index = repeatPopup.indexOfSelectedItem
        guard kinds.indices.contains(index) else { return }
        let today = self.today
        edit { $0.setRepeat(kinds[index], today: today) }
    }

    @objc private func intervalDownClicked() { edit { $0.stepInterval(by: -1) } }
    @objc private func intervalUpClicked() { edit { $0.stepInterval(by: 1) } }

    @objc private func unitChosen() {
        let units = ShiftScheduleDraft.Unit.allCases
        let index = unitPopup.indexOfSelectedItem
        guard units.indices.contains(index) else { return }
        edit { $0.setUnit(units[index]) }
    }

    @objc private func weekdayClicked(_ sender: HelmButton) {
        edit { $0.toggleWeekday(sender.tag) }
    }

    @objc private func monthlyChosen() {
        let modes = ShiftScheduleDraft.MonthlyMode.allCases
        let index = monthlyPopup.indexOfSelectedItem
        guard modes.indices.contains(index) else { return }
        edit { $0.setMonthlyMode(modes[index]) }
    }

    @objc private func endChosen() {
        let ends = ShiftScheduleDraft.End.allCases
        let index = endPopup.indexOfSelectedItem
        guard ends.indices.contains(index) else { return }
        edit { $0.setEnd(ends[index]) }
    }

    @objc private func countDownClicked() { edit { $0.stepCount(by: -1) } }
    @objc private func countUpClicked() { edit { $0.stepCount(by: 1) } }

    @objc private func reminderChosen() {
        let index = reminderPopup.indexOfSelectedItem
        edit { draft in
            draft.reminderMinutes = index <= 0 ? nil : ShiftReminderOffset.choices[index - 1]
        }
    }

    // MARK: Re-deriving the rows

    /// The Repeat menu's cases, with "Custom rule" while the draft holds one.
    private var repeatMenu: [ShiftScheduleDraft.Repeat] {
        ShiftScheduleDraft.Repeat.menu + (draft.customRule != nil ? [.customRule] : [])
    }

    private func sync() {
        let hiddenBefore = [timeRow, everyRow, weekdayRow, monthlyRow, endsRow, previewCard].map { $0?.isHidden }
        let hasDay = draft.day != nil

        // Date
        if let day = draft.day, let date = ShiftDateFormatting.dateTime(from: day, time: Self.defaultTime) {
            dateField.dateValue = date
        }
        dateField.emptyText = hasDay ? nil : "No date"
        let quick = ShiftScheduleDraft.quickDays(today: today)
        for button in quickButtons {
            let lit = button.tag < quick.count ? quick[button.tag].day == draft.day : !hasDay
            button.variant = lit ? .primary : .secondary
            if button.tag == 2, quick.count > 2 { button.title = quick[2].title }
        }

        // Time
        timeRow.isHidden = !hasDay
        timeTabs.select(draft.time == nil ? "allDay" : "atTime")
        timeField.isHidden = draft.time == nil
        if let time = draft.time, let date = ShiftDateFormatting.dateTime(from: draft.day ?? today, time: time) {
            timeField.dateValue = date
        }

        // Repeat
        let kinds = repeatMenu
        repeatPopup.removeAllItems()
        repeatPopup.addItems(withTitles: kinds.map(\.title))
        repeatPopup.selectItem(at: kinds.firstIndex(of: draft.repeatKind) ?? 0)

        // Every
        everyRow.isHidden = !draft.showsEvery
        let interval = draft.shownInterval
        intervalValue.stringValue = "\(interval)"
        intervalDown.isEnabled = draft.repeatKind == .custom && interval > ShiftScheduleDraft.intervalRange.lowerBound
        intervalUp.isEnabled = interval < ShiftScheduleDraft.intervalRange.upperBound
        unitPopup.isHidden = !draft.showsUnitPicker
        unitLabel.isHidden = draft.showsUnitPicker
        let unit = draft.effectiveUnit ?? .week
        for (index, item) in ShiftScheduleDraft.Unit.allCases.enumerated() {
            unitPopup.item(at: index)?.title = item.title(plural: interval != 1)
        }
        unitPopup.selectItem(at: ShiftScheduleDraft.Unit.allCases.firstIndex(of: unit) ?? 1)
        unitLabel.stringValue = unit.title(plural: interval != 1)

        // On
        weekdayRow.isHidden = !draft.showsWeekdays
        let lit = draft.displayedWeekdays
        for button in weekdayButtons {
            button.variant = lit.contains(button.tag) ? .primary : .secondary
            button.setAccessibilityValue(lit.contains(button.tag) ? "selected" : "not selected")
        }
        monthlyRow.isHidden = !draft.showsMonthly
        monthlyPopup.removeAllItems()
        monthlyPopup.addItems(withTitles: ShiftScheduleDraft.MonthlyMode.allCases.map(draft.monthlyTitle))
        monthlyPopup.selectItem(at: ShiftScheduleDraft.MonthlyMode.allCases.firstIndex(of: draft.monthlyMode) ?? 0)

        // Ends
        endsRow.isHidden = !draft.showsEnds
        endPopup.selectItem(at: ShiftScheduleDraft.End.allCases.firstIndex(of: draft.end) ?? 0)
        untilHolder.isHidden = draft.end != .onDate
        countHolder.isHidden = draft.end != .afterCount
        if let until = draft.recurrence?.until ?? draft.until, let date = ShiftDateFormatting.date(from: until) {
            untilField.dateValue = date
        }
        countValue.stringValue = "\(draft.count)"
        countSuffix.stringValue = draft.count == 1 ? "time" : "times"
        countDown.isEnabled = draft.count > ShiftScheduleDraft.countRange.lowerBound
        countUp.isEnabled = draft.count < ShiftScheduleDraft.countRange.upperBound

        // Preview
        let preview = ShiftSchedulePreview(draft: draft, today: now())
        previewCard.isHidden = preview == nil
        if let preview {
            previewRange.stringValue = preview.rangeTitle.uppercased()
            previewCount.stringValue = preview.countText
            previewStrip.preview = preview
            previewSummary.stringValue = preview.summary
            previewDetail.stringValue = preview.detail
            previewRule.stringValue = preview.ruleLine ?? ""
            previewRule.isHidden = preview.ruleLine == nil
            previewStrip.setAccessibilityLabel("\(preview.summary). \(preview.detail)")
        }

        // Remind: a reminder needs a date to be early for.
        let allDayAt = draft.time == nil ? allDayReminderAt : nil
        reminderPopup.removeAllItems()
        reminderPopup.addItems(withTitles: ["No reminder"] + ShiftReminderOffset.choices.map {
            ShiftReminderOffset.label(for: $0, allDayAt: allDayAt)
        })
        if let minutes = draft.reminderMinutes, !ShiftReminderOffset.choices.contains(minutes) {
            // A hand-edited offset no choice names stays selected, named.
            reminderPopup.addItem(withTitle: ShiftReminderOffset.label(for: minutes, allDayAt: allDayAt))
            reminderPopup.selectItem(at: reminderPopup.numberOfItems - 1)
        } else {
            reminderPopup.selectItem(at: draft.reminderMinutes.flatMap { ShiftReminderOffset.choices.firstIndex(of: $0) }
                .map { $0 + 1 } ?? 0)
        }
        reminderPopup.isEnabled = hasDay

        let hiddenAfter = [timeRow, everyRow, weekdayRow, monthlyRow, endsRow, previewCard].map { $0?.isHidden }
        needsLayout = true
        if hiddenBefore != hiddenAfter { onHeightChange?() }
    }

    // MARK: Layout and theme

    /// AGENTS.md gotcha (22): the wrapping labels' width comes from this
    /// view's own resolved width, which they do not decide.
    override func layout() {
        super.layout()
        let available = max(120, bounds.width - 2 * (HelmMetrics.s2 + 2))
        var changed = false
        for label in [previewSummary, previewDetail, previewRule] where abs(label.preferredMaxLayoutWidth - available) > 0.5 {
            label.preferredMaxLayoutWidth = available
            label.invalidateIntrinsicContentSize()
            changed = true
        }
        if changed { super.layout() }
    }

    private func applyTheme(_ theme: HelmTheme) {
        let ink = HelmField.ink(theme)
        let muted = HelmField.mutedInk(theme)
        for label in rowLabels { label.textColor = muted }
        for label in [intervalValue, unitLabel, countValue, countSuffix, previewSummary] { label.textColor = ink }
        for label in [previewRange, previewCount, previewDetail, previewRule] { label.textColor = muted }
        timeTabs.applyTheme(theme)
        previewCard.layer?.backgroundColor = HelmField.fill(theme).cgColor
        previewCard.layer?.borderWidth = HelmField.hairlineBorderWidth
        previewCard.layer?.borderColor = HelmField.border(theme).cgColor
        previewStrip.theme = theme
    }

    // MARK: Self-test surface (GL-27)

    #if FM_SELFTESTS
    var debugDateField: HelmDateField { dateField }
    var debugQuickButtons: [HelmButton] { quickButtons }
    var debugTimeTabs: HelmSegmentedTabs { timeTabs }
    var debugTimeField: HelmDateField { timeField }
    var debugRepeatPopup: HelmPopUpButton { repeatPopup }
    var debugIntervalUp: HelmButton { intervalUp }
    var debugIntervalDown: HelmButton { intervalDown }
    var debugIntervalText: String { intervalValue.stringValue }
    var debugUnitPopup: HelmPopUpButton { unitPopup }
    var debugWeekdayButtons: [HelmButton] { weekdayButtons }
    var debugMonthlyPopup: HelmPopUpButton { monthlyPopup }
    var debugEndPopup: HelmPopUpButton { endPopup }
    var debugCountUp: HelmButton { countUp }
    var debugCountDown: HelmButton { countDown }
    var debugReminderPopup: HelmPopUpButton { reminderPopup }
    var debugPreviewHidden: Bool { previewCard.isHidden }
    var debugPreviewSummary: String { previewSummary.stringValue }
    var debugPreviewDetail: String { previewDetail.stringValue }
    var debugRuleLine: String { previewRule.isHidden ? "" : previewRule.stringValue }
    var debugPreview: ShiftSchedulePreview? { previewStrip.preview }
    var debugRowHidden: (time: Bool, every: Bool, weekdays: Bool, monthly: Bool, ends: Bool) {
        (timeRow.isHidden, everyRow.isHidden, weekdayRow.isHidden, monthlyRow.isHidden, endsRow.isHidden)
    }

    /// A popup's own target/action, the way a pick from its menu reaches it.
    /// `performClick` would open the menu and track it modally.
    @discardableResult
    static func debugChoose(_ popup: NSPopUpButton, title: String) -> Bool {
        let index = popup.indexOfItem(withTitle: title)
        guard index >= 0, let action = popup.action else { return false }
        popup.selectItem(at: index)
        return popup.sendAction(action, to: popup.target)
    }
    #endif
}

/// A row's slack, told apart from the controls `hStack` makes rigid.
private final class ShiftScheduleSpacer: NSView {}

// MARK: - The preview strip

/// Five weeks of day numbers with the dates the rule lands on filled in the
/// accent, the due date ringed and a skipped date struck through.
///
/// The fill is the primary button's own pair (the accent with
/// `selectionTextHex` on it), which `FM_RUN_CONTRAST_TESTS` already holds to
/// the floor in every theme, rather than a new tinted text colour.
final class ShiftSchedulePreviewStrip: NSView {

    var preview: ShiftSchedulePreview? { didSet { needsDisplay = true } }
    var theme: HelmTheme = ThemeManager.shared.theme { didSet { needsDisplay = true } }

    static let headHeight: CGFloat = 16
    static let rowHeight: CGFloat = 24

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: Self.headHeight + Self.rowHeight * CGFloat(ShiftSchedulePreview.weeks))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let preview else { return }
        let columnWidth = bounds.width / 7
        let ink = HelmField.ink(theme)
        let muted = HelmField.mutedInk(theme)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let onAccent = HelmTheme.nsColor(theme.selectionTextHex)

        let headFont = NSFont.systemFont(ofSize: HelmType.scaled(10), weight: .semibold)
        for (index, head) in preview.weekdayHeads.enumerated() {
            let rect = NSRect(x: CGFloat(index) * columnWidth, y: 0, width: columnWidth, height: Self.headHeight)
            drawCentred(head, in: rect, font: headFont, colour: muted)
        }

        let side: CGFloat = 20
        for (index, cell) in preview.cells.enumerated() {
            let column = CGFloat(index % 7)
            let row = CGFloat(index / 7)
            let slot = NSRect(x: column * columnWidth, y: Self.headHeight + row * Self.rowHeight,
                              width: columnWidth, height: Self.rowHeight)
            let disc = NSRect(x: slot.midX - side / 2, y: slot.midY - side / 2, width: side, height: side)
            var colour = cell.isPast ? muted.withAlphaComponent(0.6) : ink
            if cell.isOccurrence {
                accent.setFill()
                NSBezierPath(ovalIn: disc).fill()
                colour = onAccent
            }
            if cell.isDue {
                accent.setStroke()
                let ring = NSBezierPath(ovalIn: disc.insetBy(dx: cell.isOccurrence ? -1.5 : 0.75,
                                                             dy: cell.isOccurrence ? -1.5 : 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            let weight: NSFont.Weight = cell.isToday || cell.isDue || cell.isOccurrence ? .bold : .regular
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: HelmType.scaled(11), weight: weight),
                .foregroundColor: cell.isSkipped ? muted : colour,
            ]
            if cell.isSkipped { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            drawCentred("\(cell.number)", in: slot, attributes: attributes)
        }
    }

    private func drawCentred(_ text: String, in rect: NSRect, font: NSFont, colour: NSColor) {
        drawCentred(text, in: rect, attributes: [.font: font, .foregroundColor: colour])
    }

    private func drawCentred(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

// MARK: - The calendar's popover

/// The When panel as a popover on the calendar, from a task's chip or a tray
/// row's Pick….
///
/// It edits a draft and hands it back when it closes, through Done or a
/// click outside it, which is how a calendar's own popover behaves. Escape
/// closes it without a change. The host applies the draft to the task as it
/// is in the store at that moment, so an edit that arrived while the popover
/// was open is not reverted with it.
final class ShiftSchedulePopover: NSObject, NSPopoverDelegate {

    /// The draft, when it differs from the task the popover opened on.
    var onCommit: ((ShiftScheduleDraft) -> Void)?
    /// "Open task…": after any change is committed, the full editor.
    var onOpenTask: (() -> Void)?
    /// The popover closed, whichever way.
    var onClose: (() -> Void)?

    private let task: ShiftTask
    private let popover = NSPopover()
    private let content: ShiftSchedulePopoverController
    private var discarded = false
    private var openTaskAfterClose = false

    init(task: ShiftTask, projectName: String?, allDayReminderAt: String) {
        self.task = task
        content = ShiftSchedulePopoverController(task: task, projectName: projectName,
                                                 allDayReminderAt: allDayReminderAt)
        super.init()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.animates = !HelmMotion.isReduced
        popover.delegate = self
        content.onDone = { [weak self] in self?.popover.performClose(nil) }
        content.onCancel = { [weak self] in
            self?.discarded = true
            self?.popover.performClose(nil)
        }
        content.onOpenTask = { [weak self] in
            self?.openTaskAfterClose = true
            self?.popover.performClose(nil)
        }
        // GL-09: a popover is its own window and floats above the lock
        // overlay, so the lock has to be able to close it.
        AppLockGate.shared.registerLockDismissiblePopover(owner: self) { [weak self] in self?.popover }
    }

    var isShown: Bool { popover.isShown }
    var editor: ShiftScheduleEditor { content.editor }

    func show(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        popover.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        let draft = content.editor.draft
        if !discarded, draft.changes(task) { onCommit?(draft) }
        if openTaskAfterClose { onOpenTask?() }
        onClose?()
    }

    #if FM_SELFTESTS
    var debugPopover: NSPopover { popover }
    var debugContent: ShiftSchedulePopoverController { content }
    #endif
}

/// The popover's content: the task's name, the panel, and a footer with
/// "Open task…" and Done.
final class ShiftSchedulePopoverController: NSViewController {

    static let width: CGFloat = 424

    let editor: ShiftScheduleEditor
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenTask: (() -> Void)?

    private let task: ShiftTask
    private let projectName: String?
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let openButton = HelmButton(title: "Open task\u{2026}", variant: .quiet, size: .small)
    private let doneButton = HelmButton(title: "Done", variant: .primary, size: .small)
    private var themeToken: ThemeObservation?

    init(task: ShiftTask, projectName: String?, allDayReminderAt: String) {
        self.task = task
        self.projectName = projectName
        editor = ShiftScheduleEditor(draft: ShiftScheduleDraft(task: task), allDayReminderAt: allDayReminderAt)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { if let themeToken { ThemeManager.shared.unobserve(themeToken) } }

    override func loadView() {
        // The root stays frame-based: the popover sizes it to
        // `preferredContentSize`. AGENTS.md gotcha (11): a required width on
        // a frame-based root fights the autoresizing constraints of whatever
        // frame it has, and AppKit broke this panel's tie that way - the
        // panel collapsed to its weekday row's 337pt. The width lives on the
        // column instead, which is constraint-based.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 480))
        root.wantsLayer = true
        view = root

        titleLabel.stringValue = task.title
        titleLabel.font = HelmType.rowTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.stringValue = [projectName ?? "No project",
                                 "\(task.priority.rawValue.capitalized) priority"].joined(separator: " \u{00B7} ")
        metaLabel.font = HelmType.caption()
        let head = NSStackView(views: [titleLabel, metaLabel])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 2

        openButton.target = self
        openButton.action = #selector(openClicked)
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        doneButton.keyEquivalent = "\r"
        let gap = NSView()
        let zero = gap.widthAnchor.constraint(equalToConstant: 0)
        zero.priority = .defaultLow
        zero.isActive = true
        let foot = NSStackView(views: [openButton, gap, doneButton])
        foot.orientation = .horizontal
        foot.distribution = .fill
        foot.alignment = .centerY
        for button in [openButton, doneButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let column = NSStackView(views: [head, editor, foot])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s3
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        let inset = HelmMetrics.s4
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.s3),
            column.widthAnchor.constraint(equalToConstant: Self.width - 2 * inset),
        ])
        for view in [head, editor, foot] as [NSView] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        editor.onHeightChange = { [weak self] in self?.fitHeight() }

        themeToken = ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.titleLabel.textColor = HelmField.ink(theme)
            self?.metaLabel.textColor = HelmField.mutedInk(theme)
        }
        fitHeight()
    }

    /// The popover follows the panel's rows as they show and hide.
    private func fitHeight() {
        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: ceil(view.fittingSize.height))
        if preferredContentSize != size { preferredContentSize = size }
    }

    @objc private func doneClicked() { onDone?() }
    @objc private func openClicked() { onOpenTask?() }

    /// Escape closes without a change.
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    #if FM_SELFTESTS
    var debugDoneButton: HelmButton { doneButton }
    var debugOpenButton: HelmButton { openButton }
    var debugTitle: String { titleLabel.stringValue }
    #endif
}
