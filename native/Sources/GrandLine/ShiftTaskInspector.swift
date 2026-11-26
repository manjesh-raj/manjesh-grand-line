// Grand Line - native macOS app.
//
// UX-04 of full review 4: a task's details open beside the board, in the
// sidebar shell's inspector, rather than in a modal sheet over it.
//
// Selecting a card (or a List row) fills the inspector with the task's title,
// when it is due and how it repeats, its project and priority, a checklist of
// its subtasks, its notes and its activity. Every edit saves as it is made,
// the way the Notebook saves: a typed title or note after a short pause, a
// tick, a pick or a new checklist item at once. The board stays live, so the
// captain can drag another card or open another task while one is showing.
//
// The New Task sheet stays (a focused form is right for a record that does
// not exist yet), and "Open in editor…" still reaches the sheet for the
// fields the inspector does not carry: tags and the image.
//
// The words are `TaskInspectorWords`, pure, so a suite can assert them
// without a window. The view reports intents and never touches the store;
// `ShiftController` owns every write.

import AppKit

// MARK: - The words

enum TaskInspectorWords {

    /// A chip's words, its hue (`nil` reads as a quiet chip) and what a click
    /// on it does.
    struct Chip: Equatable {
        let text: String
        let tint: HelmTint?
        let toolTip: String
    }

    static let title = "Task"
    static let emptyTitle = "No task selected"
    static let emptyBody = "Select a card on the board, or a row in the list, to see its details here."
    static let titlePlaceholder = "Task title"
    static let addItemPlaceholder = "Add an item"
    static let notesKicker = "Notes"
    static let activityKicker = "Activity"
    static let openEditorTitle = "Open in Editor\u{2026}"
    static let openEditorToolTip = "Tags, the image and every other field, in the task editor"

    /// "Today 9:30", "Tomorrow", "28 Nov 14:00", "Overdue 2 days", or "No
    /// date". Overdue wears the critical hue and today the warning amber,
    /// exactly as a board card's due line does (`ShiftTaskSignals.dueCaption`).
    static func dueChip(_ task: ShiftTask, now: Date, calendar: Calendar = .current) -> Chip {
        let change = "Change the date, the time or the repeat"
        guard let dayString = task.dueDate, let day = ShiftDateFormatting.date(from: dayString) else {
            return Chip(text: "No date", tint: nil, toolTip: "Give it a date, a time or a repeat")
        }
        let clock = task.dueTime.map { " " + ShiftDateFormatting.clock($0) } ?? ""
        if ShiftDue.isOverdue(date: dayString, time: task.dueTime, now: now, calendar: calendar) {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day),
                                               to: calendar.startOfDay(for: now)).day ?? 0
            let text = days <= 0 ? "Overdue\(clock)" : "Overdue \(days) \(days == 1 ? "day" : "days")"
            return Chip(text: text, tint: .critical, toolTip: change)
        }
        if calendar.isDate(day, inSameDayAs: now) {
            return Chip(text: "Today\(clock)", tint: .warn, toolTip: change)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) {
            return Chip(text: "Tomorrow\(clock)", tint: nil, toolTip: change)
        }
        return Chip(text: ShiftDateFormatting.monthDay(day) + clock, tint: nil, toolTip: change)
    }

    /// The repeat rule's pattern ("Every Mon, Wed, Fri"), or `nil` for a task
    /// that happens once.
    static func repeatChip(_ task: ShiftTask) -> Chip? {
        guard let rule = task.recurrence else { return nil }
        return Chip(text: rule.patternName, tint: nil, toolTip: "Change the repeat")
    }

    static func projectChip(name: String?) -> Chip {
        Chip(text: name ?? "No project", tint: nil, toolTip: "Move it to another project")
    }

    /// Every priority is said, so the chip is always there to click. Only
    /// High carries a hue.
    static func priorityChip(_ priority: ShiftPriority) -> Chip {
        switch priority {
        case .high: return Chip(text: "High", tint: .critical, toolTip: "Change the priority")
        case .normal: return Chip(text: "Normal priority", tint: nil, toolTip: "Change the priority")
        case .low: return Chip(text: "Low priority", tint: nil, toolTip: "Change the priority")
        }
    }

    /// "Checklist", or "Checklist · 1 of 3".
    static func checklistKicker(_ subtasks: [ShiftSubtask]) -> String {
        guard !subtasks.isEmpty else { return "Checklist" }
        return "Checklist \u{00B7} \(subtasks.filter(\.done).count) of \(subtasks.count)"
    }

    /// What happened to the task, newest kind first: the focus time logged on
    /// it, how often its date was pushed back, and when it was made.
    ///
    /// GL-14: a month of the activity log that could not be read is said, so
    /// a missing focus line is never read as "no focus time".
    static func activityLines(task: ShiftTask, entries: [ShiftActivityEntry], unreadable: Bool,
                              now: Date, calendar: Calendar = .current) -> [String] {
        let mine = entries.filter { $0.targetID == task.id }
        var lines: [String] = []
        let focus = mine.filter { $0.kind == FocusActivityLog.kind }
        let seconds = focus.reduce(0) { $0 + ($1.durationSeconds ?? 0) }
        if seconds > 0 {
            let latest = focus.compactMap { ShiftStore.date(fromISO8601: $0.timestamp) }.max()
            lines.append("Focused \(FocusTimerFormat.total(seconds))" + (latest.map { " \u{00B7} " + dayWord($0, now: now, calendar: calendar) } ?? ""))
        }
        let pushes = mine.filter { $0.kind == "task_due_date_changed" }.count
        if pushes == 1 { lines.append("Pushed back once") } else if pushes > 1 { lines.append("Pushed back \(pushes) times") }
        if let created = ShiftStore.date(fromISO8601: task.createdAt) {
            lines.append("Created \u{00B7} " + dayWord(created, now: now, calendar: calendar))
        }
        if unreadable { lines.append("Some of the activity log could not be read, so this may be short.") }
        return lines
    }

    /// "today", "yesterday", "Mon" within the week, else "28 Nov".
    static func dayWord(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if (2...6).contains(days) {
            return ShiftRecurrence.shortWeekdayName(calendar.component(.weekday, from: date))
        }
        return ShiftDateFormatting.monthDay(date)
    }
}

// MARK: - A chip that opens something

/// One of the inspector's fact chips: a capsule with its words, tinted when
/// the fact is a warning (overdue, High) and quiet otherwise. A
/// `HoverHighlightView`, so it carries the button role, the focus ring and
/// the keyboard press (GL-16).
final class ShiftInspectorChip: HoverHighlightView {
    private let label = NSTextField(labelWithString: "")
    private(set) var chip = TaskInspectorWords.Chip(text: "", tint: nil, toolTip: "")
    private var onPress: ((ShiftInspectorChip) -> Void)?

    init(onPress: @escaping (ShiftInspectorChip) -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        label.font = HelmType.chip()
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pressed)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func pressed() { onPress?(self) }

    func configure(_ chip: TaskInspectorWords.Chip, theme: HelmTheme) {
        self.chip = chip
        label.stringValue = chip.text
        toolTip = chip.toolTip
        accessibilityLabelOverride = "\(chip.text). \(chip.toolTip)"
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        cornerRadius = HelmMetrics.rChip + 2
        let fill: NSColor
        if let tint = chip.tint {
            let surface = HelmContrast.tintedSurface(tintHex: tint.hex(in: theme), theme: theme,
                                                     target: HelmContrast.textTarget)
            fill = surface.fill
            label.textColor = surface.foreground
        } else {
            fill = HelmField.fill(theme)
            label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        }
        normalColor = fill
        hoverColor = fill.blended(withFraction: 0.08, of: HelmTheme.nsColor(theme.chromeInkHex)) ?? fill
    }

    var text: String { label.stringValue }
    var textColor: NSColor? { label.textColor }
}

// MARK: - A checklist row

/// A subtask: its check, its words (struck through once done) and, on hover,
/// a remove button.
final class ShiftInspectorChecklistRow: HoverHighlightView {
    let check = ShiftTaskCheckBadge(size: 16)
    private let label = NSTextField(wrappingLabelWithString: "")
    let removeButton = HelmButton(symbol: "xmark", variant: .quiet, size: .small, target: nil, action: nil)
    private(set) var subtask: ShiftSubtask
    var onToggle: ((Bool) -> Void)?
    var onRemove: (() -> Void)?

    init(subtask: ShiftSubtask) {
        self.subtask = subtask
        super.init(frame: .zero)
        label.font = HelmType.caption()
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        check.target = self
        check.action = #selector(checkClicked)
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.toolTip = "Remove this item"
        removeButton.setAccessibilityLabel("Remove \(subtask.title)")
        removeButton.alphaValue = 0
        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        removeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [check, label, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        onHoverChange = { [weak self] hovering in self?.removeButton.alphaValue = hovering ? 1 : 0 }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ subtask: ShiftSubtask, width: CGFloat, theme: HelmTheme) {
        self.subtask = subtask
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        var attributes: [NSAttributedString.Key: Any] = [.font: HelmType.caption(), .foregroundColor: subtask.done ? muted : ink]
        if subtask.done { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        label.attributedStringValue = NSAttributedString(string: subtask.title, attributes: attributes)
        label.setAccessibilityLabel(subtask.title)
        // Gotcha (22): the row's own width, less its rigid siblings.
        label.preferredMaxLayoutWidth = max(40, width - 16 - 22 - 2 * HelmMetrics.s2)
        check.setChecked(subtask.done, tint: HelmTheme.nsColor(theme.accentHex))
        check.setAccessibilityLabel(subtask.title)
    }

    @objc private func checkClicked() { onToggle?(!subtask.done) }
    @objc private func removeClicked() { onRemove?() }

    var debugText: String { label.stringValue }
    var debugIsStruck: Bool {
        guard label.attributedStringValue.length > 0 else { return false }
        return label.attributedStringValue.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil
    }
}

// MARK: - The inspector's view

/// The selected task, top to bottom: its title, its facts as chips, the
/// checklist, the notes and the activity, and the way to the full editor.
final class ShiftTaskInspectorView: NSView, NSTextFieldDelegate, NSTextViewDelegate {

    /// How long a pause in typing waits before the title or the notes save.
    static let autosaveDelay: TimeInterval = 0.5
    static let padding = NSEdgeInsets(top: HelmMetrics.s3, left: HelmMetrics.s4, bottom: HelmMetrics.s4, right: HelmMetrics.s4)

    /// The task's id, its title and its notes, after a pause in typing or
    /// when the field is left.
    var onEditText: ((String, String, String) -> Void)?
    var onToggleSubtask: ((String, Bool) -> Void)?
    var onAddSubtask: ((String) -> Void)?
    var onRemoveSubtask: ((String) -> Void)?
    /// A chip was pressed; the controller opens the right picker beside it.
    var onEditSchedule: ((NSView) -> Void)?
    var onPickProject: ((NSView) -> Void)?
    var onPickPriority: ((NSView) -> Void)?
    var onOpenEditor: (() -> Void)?
    var onDelete: (() -> Void)?

    override var isFlipped: Bool { true }

    let titleField = HelmTextField(placeholder: TaskInspectorWords.titlePlaceholder, style: .lead)
    private(set) lazy var dueChip = ShiftInspectorChip { [weak self] chip in self?.onEditSchedule?(chip) }
    private(set) lazy var repeatChip = ShiftInspectorChip { [weak self] chip in self?.onEditSchedule?(chip) }
    private(set) lazy var projectChip = ShiftInspectorChip { [weak self] chip in self?.onPickProject?(chip) }
    private(set) lazy var priorityChip = ShiftInspectorChip { [weak self] chip in self?.onPickPriority?(chip) }
    private let checklistKicker = NSTextField(labelWithString: "")
    private let checklistStack = NSStackView()
    let addItemField = HelmTextField(placeholder: TaskInspectorWords.addItemPlaceholder)
    private let notesKicker = NSTextField(labelWithString: "")
    let notesView = HelmTextView(height: 88)
    private let activityKicker = NSTextField(labelWithString: "")
    private let activityStack = NSStackView()
    let openEditorButton = HelmButton(title: TaskInspectorWords.openEditorTitle, variant: .secondary, size: .small)
    let deleteButton = HelmButton(title: "Delete\u{2026}", variant: .quiet, size: .small)
    private let stack = NSStackView()

    private(set) var taskID: String?
    private var subtasks: [ShiftSubtask] = []
    private var pendingSave: DispatchWorkItem?
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleField.font = HelmType.rounded(HelmType.scaled(17), .semibold)
        titleField.isEditable = true
        titleField.cell?.wraps = true
        titleField.cell?.isScrollable = false
        titleField.usesSingleLineMode = false
        titleField.lineBreakMode = .byWordWrapping
        titleField.maximumNumberOfLines = 0
        titleField.delegate = self
        titleField.setAccessibilityLabel("Title")
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let factsTop = chipRow([dueChip, repeatChip])
        let factsBottom = chipRow([projectChip, priorityChip])

        checklistStack.orientation = .vertical
        checklistStack.alignment = .leading
        checklistStack.spacing = HelmMetrics.s1
        addItemField.delegate = self
        addItemField.setAccessibilityLabel("Add a checklist item")

        notesView.textView.delegate = self
        notesView.textView.setAccessibilityLabel("Notes")

        activityStack.orientation = .vertical
        activityStack.alignment = .leading
        activityStack.spacing = HelmMetrics.s0

        openEditorButton.target = self
        openEditorButton.action = #selector(openEditorClicked)
        openEditorButton.toolTip = TaskInspectorWords.openEditorToolTip
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.toolTip = "Delete this task"
        let footer = NSStackView(views: [openEditorButton, NSView(), deleteButton])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.alignment = .centerY

        for view in [titleField, factsTop, factsBottom, checklistKicker, checklistStack, addItemField,
                     notesKicker, notesView, activityKicker, activityStack, footer] as [NSView] {
            stack.addArrangedSubview(view)
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.setCustomSpacing(HelmMetrics.s3, after: titleField)
        stack.setCustomSpacing(HelmMetrics.s5 - HelmMetrics.s1, after: factsBottom)
        stack.setCustomSpacing(HelmMetrics.s5 - HelmMetrics.s1, after: addItemField)
        stack.setCustomSpacing(HelmMetrics.s5 - HelmMetrics.s1, after: notesView)
        stack.setCustomSpacing(HelmMetrics.s5, after: activityStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let pad = Self.padding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad.top),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad.left),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad.right),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad.bottom),
        ])
        for view in [titleField, checklistStack, addItemField, notesView, activityStack, footer] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    private func chipRow(_ chips: [ShiftInspectorChip]) -> NSStackView {
        let row = NSStackView(views: chips)
        row.orientation = .horizontal
        row.spacing = HelmMetrics.s2 - 2
        row.alignment = .centerY
        row.distribution = .fill
        row.detachesHiddenViews = true
        return row
    }

    override func layout() {
        super.layout()
        // Gotcha (22): from the pane's own width, never the label's.
        let width = max(80, bounds.width - Self.padding.left - Self.padding.right)
        if abs(titleField.preferredMaxLayoutWidth - width) > 0.5 {
            titleField.preferredMaxLayoutWidth = width
            for case let row as ShiftInspectorChecklistRow in checklistStack.arrangedSubviews {
                row.configure(row.subtask, width: width, theme: theme)
            }
            for case let label as NSTextField in activityStack.arrangedSubviews { label.preferredMaxLayoutWidth = width }
            needsLayout = true
        }
    }

    private var contentWidth: CGFloat { max(80, bounds.width - Self.padding.left - Self.padding.right) }

    // MARK: Filling it

    /// Show `task`. A new task flushes what was being typed into the old one
    /// first. The same task keeps whatever field the captain is typing in:
    /// a store change from the save itself must not put the caret back.
    func configure(task: ShiftTask, projectName: String?, activity: [String], now: Date = Date()) {
        if task.id != taskID {
            flushPendingEdits()
            taskID = task.id
            titleField.stringValue = task.title
            notesView.string = task.description
            addItemField.stringValue = ""
        } else {
            if titleField.currentEditor() == nil { titleField.stringValue = task.title }
            if window?.firstResponder !== notesView.textView { notesView.string = task.description }
        }
        dueChip.configure(TaskInspectorWords.dueChip(task, now: now), theme: theme)
        if let rule = TaskInspectorWords.repeatChip(task) {
            repeatChip.configure(rule, theme: theme)
            repeatChip.isHidden = false
        } else {
            repeatChip.isHidden = true
        }
        projectChip.configure(TaskInspectorWords.projectChip(name: projectName), theme: theme)
        priorityChip.configure(TaskInspectorWords.priorityChip(task.priority), theme: theme)
        setSubtasks(task.subtasks)
        setActivity(activity)
        applyKickers()
    }

    private func setSubtasks(_ items: [ShiftSubtask]) {
        subtasks = items
        let existing = checklistStack.arrangedSubviews.compactMap { $0 as? ShiftInspectorChecklistRow }
        if existing.map(\.subtask.id) != items.map(\.id) {
            existing.forEach { $0.removeFromSuperview() }
            for item in items {
                let row = ShiftInspectorChecklistRow(subtask: item)
                let id = item.id
                row.onToggle = { [weak self] done in self?.onToggleSubtask?(id, done) }
                row.onRemove = { [weak self] in self?.onRemoveSubtask?(id) }
                checklistStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: checklistStack.widthAnchor).isActive = true
            }
        }
        for (row, item) in zip(checklistStack.arrangedSubviews.compactMap { $0 as? ShiftInspectorChecklistRow }, items) {
            row.configure(item, width: contentWidth, theme: theme)
        }
        checklistStack.isHidden = items.isEmpty
    }

    private func setActivity(_ lines: [String]) {
        activityStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for line in lines {
            let label = NSTextField(wrappingLabelWithString: line)
            label.font = HelmType.caption()
            label.textColor = HelmTheme.mutedInk(theme)
            label.preferredMaxLayoutWidth = contentWidth
            activityStack.addArrangedSubview(label)
        }
        activityKicker.isHidden = lines.isEmpty
        activityStack.isHidden = lines.isEmpty
    }

    private func applyKickers() {
        let muted = HelmTheme.mutedInk(theme)
        for (label, words) in [(checklistKicker, TaskInspectorWords.checklistKicker(subtasks)),
                               (notesKicker, TaskInspectorWords.notesKicker),
                               (activityKicker, TaskInspectorWords.activityKicker)] {
            label.attributedStringValue = NSAttributedString(string: words.uppercased(),
                                                             attributes: HelmType.kickerAttributes(color: muted))
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        titleField.applyTheme(theme)
        titleField.font = HelmType.rounded(HelmType.scaled(17), .semibold)
        for chip in [dueChip, repeatChip, projectChip, priorityChip] { chip.applyTheme(theme) }
        setSubtasks(subtasks)
        for case let label as NSTextField in activityStack.arrangedSubviews { label.textColor = HelmTheme.mutedInk(theme) }
        applyKickers()
    }

    // MARK: Saving as you type

    /// Saves now whatever a pause would have saved.
    func flushPendingEdits() {
        guard let pending = pendingSave else { return }
        pendingSave = nil
        pending.cancel()
        commitText()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil
            self?.commitText()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveDelay, execute: work)
    }

    private func commitText() {
        guard let taskID else { return }
        onEditText?(taskID, titleField.stringValue, notesView.string)
    }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as AnyObject?) === titleField { scheduleSave() }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if (notification.object as AnyObject?) === titleField {
            flushPendingEdits()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === addItemField, selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        addItem()
        return true
    }

    func textDidChange(_ notification: Notification) { scheduleSave() }

    func textDidEndEditing(_ notification: Notification) { flushPendingEdits() }

    /// Return in the Add an item field: the item joins the checklist and the
    /// field stays ready for the next one.
    private func addItem() {
        let words = addItemField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        addItemField.stringValue = ""
        onAddSubtask?(words)
    }

    @objc private func openEditorClicked() {
        flushPendingEdits()
        onOpenEditor?()
    }

    @objc private func deleteClicked() {
        flushPendingEdits()
        onDelete?()
    }

    #if FM_SELFTESTS
    var debugChecklistRows: [ShiftInspectorChecklistRow] {
        checklistStack.arrangedSubviews.compactMap { $0 as? ShiftInspectorChecklistRow }
    }
    var debugChecklistKicker: String { checklistKicker.stringValue }
    var debugActivityLines: [String] {
        activityStack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }
    var debugHasPendingSave: Bool { pendingSave != nil }
    #endif
}
