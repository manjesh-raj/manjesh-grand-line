// Manjesh Grand Line - native macOS app.
//
// New/Edit Task sheet (cockpit-shift-create-edit, phase 2 of Shift - see
// AGENTS.md's "Shift" section), redesigned by fm/grandline-task-editor-redesign
// against a captain-supplied HTML/CSS mockup, and moved onto the shared form
// scaffold by Phase 6 of the full-app UI audit.
//
// **This sheet is where the app's form language came from.** The big
// placeholder-styled title field, the uppercase section kickers, the clickable
// field cards for Priority/Project, the `NSSwitch`-backed due-date card, the
// sunken tag/description fields and the ⌘⏎ footer were all built here first;
// §6.4 of the audit asks for exactly that language to become the default across
// all six editors. Phase 6 promoted every one of those shapes into
// `HelmForm.swift` (`HelmFormSheet`, `HelmFieldCard`, `HelmToggleRow`,
// `HelmTextField`, `HelmTextView`, `HelmDotAccessory`) so the other five sheets
// share them rather than copy them - which means this file now *reads* almost
// entirely as behaviour: date detection, tag chips, the attachment well, and
// what Save writes. None of that behaviour changed.
//
// Three things the scaffold took over that were bugs or near-bugs here:
//
// 1. `shiftEditorFieldFillColor` was one of the three byte-identical copies of
//    the sunken-field fill the audit counted (§3.2). It is now
//    `HelmField.fill`, and this file has no colour derivation of its own left.
// 2. The `sectionLabels` re-tint used to miss its first firing, because
//    `ThemeManager.observe` fires synchronously at registration - before the
//    `sectionLabel(...)` calls further down `loadView` had appended anything -
//    so the four kickers rendered in the system `.labelColor`, *brighter* than
//    the body text they label (audit §5.1). `HelmFormSheet.refreshTheme()` is
//    the general form of the one-line fix, called at the end of every editor's
//    `loadView`.
// 3. `resizeToFitContent()` - `presentAsSheet` reads the root view's frame
//    verbatim, so a hardcoded height leaves slack that `.gravityAreas` injects
//    into an arbitrary row (fm/grandline-task-editor-layout-fix). That is
//    `HelmFormSheet.sizeToFitContent()` now, and all four non-scrolling sheets
//    get it rather than just this one.
//
// The mockup's Attachments drag-and-drop section is deliberately NOT part of
// this - that is a different (already-shipped) attachment mechanism in this
// app; these passes restructure presentation, not the attachment model.

import AppKit
import UniformTypeIdentifiers

final class ShiftTaskEditorController: NSViewController, NSTextFieldDelegate {

    private let editing: ShiftTask?
    private let projects: [ShiftProject]
    /// Pre-selects the Project card for a brand-new task opened from inside
    /// a project's own detail page ("+ Add Task", fm/cockpit-shift-project-
    /// page-redesign) - ignored when editing an existing task, which already
    /// has its own `projectID`.
    private let defaultProjectID: String?
    /// The existing attachment's bytes, if any - fetched by the caller
    /// (`ShiftController`, which owns the store) *before* presenting this
    /// sheet, so this controller never touches `ShiftStore` directly. `nil`
    /// for a brand-new task or one with no attachment.
    private let existingAttachmentData: Data?

    /// Seeds for a brand-new task opened with a starting point already in
    /// hand - `defaultProjectID`'s own shape, extended by
    /// `fm/straw-hat-task-proposal-full-editor` for the Straw Hat Pirates
    /// confirm-card flow: a crew member's draft has a title, an optional due
    /// date and optional free-text notes, and the captain reviews/adjusts
    /// everything else (priority, project, tags) themselves before Save. All
    /// four are ignored when `task` is non-nil - editing an existing task
    /// already has its own values for each.
    private let prefillTitle: String?
    private let prefillDescription: String?
    private let prefillDueDate: String?
    private let prefillDueTime: String?

    /// Called with the assembled task and the captain's attachment decision
    /// on Save. The caller (`ShiftController`) persists both via
    /// `ShiftStore.addTask`/`updateTask`.
    var onSave: ((ShiftTask, ShiftAttachmentChange) -> Void)?
    /// The sheet's Delete button, handed the task's id. Its owner confirms
    /// and deletes - see `deleteTask()` below.
    var onDelete: ((String) -> Void)?

    private var form: HelmFormSheet!

    private let attachmentWell = ShiftImageAttachmentWell()
    private let chooseImageButton = HelmButton(title: "Choose Image\u{2026}", variant: .secondary, target: nil, action: nil)
    /// `nil` until the captain interacts with the well in this session -
    /// `.unchanged` is reported on Save if this stays `nil`, so an ordinary
    /// edit that never touches the attachment never rewrites the image file.
    private var attachmentChange: ShiftAttachmentChange?

    private let titleField = HelmTextField(placeholder: "What needs to be done?", style: .lead)
    private var hintLabel: NSTextField?
    private let detectedRow = NSStackView()
    private let detectedIcon = NSImageView(image: HelmSymbol.image("calendar.badge.checkmark", pointSize: 11,
                                                               weight: HelmSymbol.weight(for: .medium)) ?? NSImage())
    private let detectedLabel = NSTextField(labelWithString: "")

    private var selectedPriority: ShiftPriority
    private let priorityDot = HelmDotAccessory()
    private lazy var priorityCard = HelmFieldCard(label: "Priority", accessory: priorityDot)

    private var selectedProjectID: String?
    private let projectIconTile = IconTileView(size: 22, cornerRadius: HelmMetrics.rChip)
    private lazy var projectCard = HelmFieldCard(label: "Project", accessory: projectIconTile)

    /// E6: the field-card idiom with a themed calendar popover, replacing
    /// the `.textFieldAndStepper` picker the audit calls "the single most
    /// dated AppKit control still visible in the app". `target`/`action`,
    /// `dateValue`, `isEnabled` and `isHidden` all read the same, which is
    /// what makes this a type change rather than a rework of this sheet.
    private let dueDatePicker = HelmDateField()
    private lazy var dueRow = HelmToggleRow(title: "Set due date",
                                            subtitle: "Add a date and optional time",
                                            trailing: dueDatePicker)

    /// Daylight §6.9's chips-in-well, replacing the field-plus-separate-flow
    /// pattern this row used to be. The interaction is unchanged (Return or a
    /// trailing comma commits, the ✕ on a chip removes it); Backspace on an
    /// empty editor now pops the last tag, which the two-view version had no
    /// way to offer.
    private let tagsInput = HelmChipInput(placeholder: "Add a tag and press Return")
    private var tagChips: [String] = []

    private let descriptionView = HelmTextView(height: 110)

    // MARK: Repeat and reminder (F5)

    /// The Repeat card, its weekday chips and the Remind me card.
    ///
    /// All three live under the due-date row and **disable together when the
    /// task has no due date**, because a rule with no anchor recurs zero
    /// times and a reminder with no due time has nothing to be early for
    /// (`ShiftTask.recurrence`'s own doc comment). Disabling states that
    /// where a silently-ignored setting would not.
    private let repeatCard = HelmFieldCard(label: "Repeat")
    private let reminderCard = HelmFieldCard(label: "Remind me")
    private let weekdayRow = NSStackView()
    private var weekdayChips: [HelmButton] = []
    private let recurrencePreview = NSTextField(labelWithString: "")

    /// The rule being edited, `nil` for a task that happens once. Held rather
    /// than read back off the cards so the weekday chips and the preview line
    /// have one source of truth between them.
    private var recurrence: ShiftRecurrence?
    private var reminderMinutes: Int?

    /// Once the person edits the due-date controls directly (switch or
    /// picker), further title edits stop overwriting their choice - only a
    /// brand-new detected phrase should ever clobber a still-untouched Due
    /// field, never a deliberate manual edit.
    private var dueManuallyEdited = false

    init(task: ShiftTask?, projects: [ShiftProject], defaultProjectID: String? = nil, existingAttachmentData: Data? = nil,
         prefillTitle: String? = nil, prefillDescription: String? = nil,
         prefillDueDate: String? = nil, prefillDueTime: String? = nil) {
        self.editing = task
        self.projects = projects
        self.defaultProjectID = defaultProjectID
        self.existingAttachmentData = existingAttachmentData
        self.prefillTitle = prefillTitle
        self.prefillDescription = prefillDescription
        self.prefillDueDate = prefillDueDate
        self.prefillDueTime = prefillDueTime
        self.recurrence = task?.recurrence
        self.reminderMinutes = task?.reminderMinutesBefore
        self.selectedPriority = task?.priority ?? .normal
        let candidateProjectID = task?.projectID ?? defaultProjectID
        self.selectedProjectID = projects.contains { $0.id == candidateProjectID } ? candidateProjectID : nil
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let form = HelmFormSheet(title: editing == nil ? "New Task" : "Edit Task")
        self.form = form
        view = form
        form.onApplyTheme = { [weak self] theme in self?.applyExtraTheme(theme) }

        // MARK: Title + natural-language date hint

        titleField.stringValue = editing?.title ?? prefillTitle ?? ""
        titleField.delegate = self
        form.addLead(titleField)
        hintLabel = form.addLeadHint(hintAttributedString(muted: .labelColor, emphasis: .labelColor))

        let clearDetected = HelmButton(symbol: "xmark.circle.fill", variant: .quiet, size: .small,
                                       target: self, action: #selector(dismissDetected))
        detectedLabel.font = HelmType.caption()
        detectedRow.addArrangedSubview(detectedIcon)
        detectedRow.addArrangedSubview(detectedLabel)
        detectedRow.addArrangedSubview(clearDetected)
        detectedRow.orientation = .horizontal
        detectedRow.spacing = HelmMetrics.s2 - 2
        detectedRow.alignment = .centerY
        detectedRow.isHidden = true
        form.addRow(detectedRow)

        // MARK: Details - Priority / Project field cards

        form.addSection("Details")
        priorityCard.onClick = { [weak self] in self?.priorityCardClicked() }
        projectIconTile.configure(symbol: "folder.fill", tint: .info, pointSize: 11)
        projectCard.onClick = { [weak self] in self?.projectCardClicked() }
        updatePriorityCard()
        updateProjectCard()
        form.addColumns([priorityCard, projectCard])

        // MARK: Due date

        dueDatePicker.target = self
        dueDatePicker.action = #selector(dueDatePickerChanged)
        // `editing?.dueDate` and `editing?.dueTime` are `String??` collapsed
        // by optional chaining - genuinely `nil` when editing an existing
        // task that has no due date, not merely "editing is nil". The prefill
        // must never fill that in, so it only applies for a brand-new task.
        let initialDueDate = editing != nil ? editing?.dueDate : prefillDueDate
        let initialDueTime = editing != nil ? editing?.dueTime : prefillDueTime
        let existingDue = ShiftDateFormatting.dateTime(from: initialDueDate, time: initialDueTime)
        if let existingDue {
            dueRow.isOn = true
            dueDatePicker.dateValue = existingDue
            dueDatePicker.isEnabled = true
        } else {
            dueRow.isOn = false
            dueDatePicker.dateValue = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
            dueDatePicker.isEnabled = false
        }
        dueDatePicker.isHidden = !dueRow.isOn
        dueRow.onToggle = { [weak self] in self?.hasDueToggled() }
        form.addRow(dueRow)

        // MARK: Repeat and reminder (F5)

        form.addSection("Repeat")
        buildRepeatControls()
        form.addColumns([repeatCard, reminderCard])
        form.addRow(weekdayRow)
        form.addRow(recurrencePreview)
        syncRepeatControls()

        // MARK: Tags

        form.addSection("Tags")
        tagChips = editing?.tags ?? []
        tagsInput.setTokens(tagChips)
        tagsInput.onTokensChanged = { [weak self] tokens in
            guard let self else { return }
            self.tagChips = tokens
            // The well grows and shrinks with its chip count, so the sheet
            // re-measures - the same reason `renderTagChips` did.
            self.form?.sizeToFitContent()
        }
        form.addRow(tagsInput)

        // MARK: Description

        form.addSection("Description")
        descriptionView.string = editing?.description ?? prefillDescription ?? ""
        form.addRow(descriptionView)

        // MARK: Attachment (existing feature, unchanged)

        chooseImageButton.target = self
        chooseImageButton.action = #selector(chooseImageClicked)
        chooseImageButton.controlSize = .small
        form.addSection("Attachment", actions: [chooseImageButton])
        attachmentWell.onImageChosen = { [weak self] data in self?.attachmentChange = .set(data) }
        attachmentWell.onRemove = { [weak self] in self?.attachmentChange = .removed }
        if let existingAttachmentData {
            attachmentWell.showExisting(data: existingAttachmentData)
        }
        form.addRow(attachmentWell)

        // MARK: Footer

        form.setFooter(target: self,
                       confirmTitle: editing == nil ? "Create Task" : "Save",
                       confirm: #selector(save),
                       cancel: #selector(cancel),
                       // ⌘Return rather than a plain Return, because this
                       // sheet's multi-line Description field consumes Return
                       // as a newline. `performKeyEquivalent:` reaches the
                       // button regardless of first responder.
                       confirmModifiers: [.command],
                       // `fm/grandline-tasks-kanban-devops-split`: a task had
                       // no delete anywhere until now. The sheet is where
                       // every other editable record in this app offers one
                       // (`SnippetEditorController`,
                       // `CredentialVaultDetailController`), and like those
                       // it only *asks* - `onDelete`'s owner runs GL-06's
                       // shared confirmation.
                       delete: editing == nil ? nil : (title: "Delete", action: #selector(deleteTask)))

        form.setSubtitle("Something to do.")
        form.refreshTheme()
        form.sizeToFitContent()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
    }

    // MARK: Theming

    /// Everything the scaffold does not own: this sheet's own hint line,
    /// detected-date row, priority dot, tag chips and attachment well.
    private func applyExtraTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        hintLabel?.attributedStringValue = hintAttributedString(muted: muted, emphasis: ink)
        detectedIcon.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        detectedLabel.textColor = muted
        updatePriorityDotColor(theme: theme)
        // The weekday chips theme themselves (`HelmButton` observes
        // `ThemeManager` directly); only their *selected* variant is this
        // sheet's to decide, and `syncRepeatControls` owns that.
        recurrencePreview.textColor = muted
        tagsInput.applyTheme(theme)
        attachmentWell.applyTheme(theme)
    }

    private func hintAttributedString(muted: NSColor, emphasis: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: HelmType.caption(), .foregroundColor: muted]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: emphasis]
        result.append(NSAttributedString(string: "Tip: type natural dates like ", attributes: base))
        result.append(NSAttributedString(string: "tomorrow 3pm", attributes: bold))
        result.append(NSAttributedString(string: " or ", attributes: base))
        result.append(NSAttributedString(string: "next Monday", attributes: bold))
        result.append(NSAttributedString(string: ".", attributes: base))
        return result
    }

    // MARK: Priority / Project field cards

    private func priorityTint(_ priority: ShiftPriority) -> HelmTint {
        switch priority {
        case .high: return .critical
        case .normal: return .info
        case .low: return .neutral
        }
    }

    private func updatePriorityDotColor(theme: HelmTheme) {
        priorityDot.setColor(HelmTheme.nsColor(priorityTint(selectedPriority).hex(in: theme)))
    }

    private func updatePriorityCard() {
        priorityCard.value = selectedPriority.rawValue.capitalized
        updatePriorityDotColor(theme: ThemeManager.shared.theme)
    }

    private func updateProjectCard() {
        projectCard.value = projects.first(where: { $0.id == selectedProjectID })?.name ?? "No project"
    }

    private func priorityCardClicked() {
        let menu = NSMenu()
        for priority in ShiftPriority.allCases {
            let item = NSMenuItem(title: priority.rawValue.capitalized, action: #selector(priorityItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.state = priority == selectedPriority ? .on : .off
            item.representedObject = priority.rawValue
            menu.addItem(item)
        }
        priorityCard.popMenu(menu)
    }

    @objc private func priorityItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let priority = ShiftPriority(rawValue: raw) else { return }
        selectedPriority = priority
        updatePriorityCard()
    }

    private func projectCardClicked() {
        let menu = NSMenu()
        let noneItem = NSMenuItem(title: "No project", action: #selector(projectItemSelected(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.state = selectedProjectID == nil ? .on : .off
        menu.addItem(noneItem)
        for project in projects {
            let item = NSMenuItem(title: project.name, action: #selector(projectItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.state = project.id == selectedProjectID ? .on : .off
            item.representedObject = project.id
            menu.addItem(item)
        }
        projectCard.popMenu(menu)
    }

    @objc private func projectItemSelected(_ sender: NSMenuItem) {
        selectedProjectID = sender.representedObject as? String
        updateProjectCard()
    }

    // MARK: Live date detection

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        // `HelmChipInput` owns its own editor and its own delegate, so the tag
        // row no longer routes through here at all.
        guard field === titleField else { return }
        guard !dueManuallyEdited else { return }
        guard let parsed = ShiftDateParser.parse(titleField.stringValue) else {
            let wasHidden = detectedRow.isHidden
            detectedRow.isHidden = true
            if !wasHidden { form.sizeToFitContent() }
            return
        }
        dueRow.isOn = true
        dueDatePicker.isEnabled = true
        dueDatePicker.isHidden = false
        if parsed.hasTime {
            dueDatePicker.dateValue = parsed.date
        } else {
            // Keep whatever time-of-day is already in the picker (default
            // 9:00 AM) - a date-only phrase like "next mon" shouldn't
            // silently zero out the time to midnight.
            let existingTime = Calendar.current.dateComponents([.hour, .minute], from: dueDatePicker.dateValue)
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: parsed.date)
            comps.hour = existingTime.hour
            comps.minute = existingTime.minute
            dueDatePicker.dateValue = Calendar.current.date(from: comps) ?? parsed.date
        }
        let (dateStr, timeStr) = ShiftDateFormatting.components(from: dueDatePicker.dateValue)
        detectedLabel.stringValue = "Detected: \(ShiftDateFormatting.friendly(dateStr, time: parsed.hasTime ? timeStr : nil))"
        let wasHidden = detectedRow.isHidden
        detectedRow.isHidden = false
        if wasHidden { form.sizeToFitContent() }
    }

    @objc private func dismissDetected() {
        let wasHidden = detectedRow.isHidden
        detectedRow.isHidden = true
        dueManuallyEdited = true
        if !wasHidden { form.sizeToFitContent() }
    }

    private func hasDueToggled() {
        dueManuallyEdited = true
        let on = dueRow.isOn
        dueDatePicker.isEnabled = on
        dueDatePicker.isHidden = !on
        detectedRow.isHidden = true
        // F5: the repeat and reminder controls have no meaning without an
        // anchor, so they follow this switch rather than sitting enabled
        // over a task that can never recur.
        syncRepeatControls()
        form.sizeToFitContent()
    }

    // MARK: Repeat and reminder (F5)

    private func buildRepeatControls() {
        repeatCard.configureChoices(ShiftRecurrence.presets.map(\.title),
                                    selectedIndex: Self.presetIndex(for: recurrence)) { [weak self] index in
            guard let self else { return }
            var picked = ShiftRecurrence.presets[index].rule
            // A preset switch keeps the weekday selection the captain has
            // already made, as long as the new rule is still weekly - which
            // is what makes "Every week" plus three chips reachable without
            // re-picking the days after every preset change.
            if picked?.frequency == .weekly, let existing = self.recurrence, existing.frequency == .weekly,
               ShiftRecurrence.presets[index].title != "Every weekday" {
                picked?.weekdays = existing.weekdays
            }
            self.recurrence = picked
            self.syncRepeatControls()
            self.form?.sizeToFitContent()
        }

        let reminderTitles = ["No reminder"] + ShiftReminderOffset.choices.map(ShiftReminderOffset.label(for:))
        reminderCard.configureChoices(reminderTitles,
                                      selectedIndex: Self.reminderIndex(for: reminderMinutes)) { [weak self] index in
            guard let self else { return }
            self.reminderMinutes = index == 0 ? nil : ShiftReminderOffset.choices[index - 1]
            self.syncRepeatControls()
        }

        weekdayRow.orientation = .horizontal
        weekdayRow.alignment = .centerY
        weekdayRow.spacing = HelmMetrics.s2 - 2
        // AGENTS.md gotcha (10): a horizontal stack left at `.gravityAreas`
        // honours no hugging priority, so the seven chips would be spread by
        // Auto Layout's own tie-breaking rather than sitting together.
        weekdayRow.distribution = .fill
        weekdayRow.translatesAutoresizingMaskIntoConstraints = false
        for weekday in Self.weekdayOrder() {
            // The chip's own letter, not an abbreviation - "M T W T F S S" is
            // the row the captain reviewed in the mockup. The full weekday
            // name is the accessibility label, because two of the seven
            // letters are ambiguous on their own.
            let name = ShiftRecurrence.shortWeekdayName(weekday)
            let chip = HelmButton(title: String(name.prefix(1)), variant: .secondary, size: .small,
                                  target: self, action: #selector(weekdayChipClicked(_:)))
            chip.tag = weekday
            chip.setAccessibilityLabel(name)
            chip.widthAnchor.constraint(equalToConstant: 30).isActive = true
            weekdayChips.append(chip)
            weekdayRow.addArrangedSubview(chip)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        weekdayRow.addArrangedSubview(spacer)

        recurrencePreview.font = HelmType.caption()
        recurrencePreview.lineBreakMode = .byTruncatingTail
    }

    @objc private func weekdayChipClicked(_ sender: HelmButton) {
        guard var rule = recurrence, rule.frequency == .weekly else { return }
        if rule.weekdays.contains(sender.tag) {
            rule.weekdays.remove(sender.tag)
        } else {
            rule.weekdays.insert(sender.tag)
        }
        recurrence = rule
        syncRepeatControls()
    }

    /// Re-derives every repeat control from `recurrence`/`reminderMinutes`.
    ///
    /// One function rather than per-control updates, because the three
    /// controls constrain each other: the chips only apply to a weekly rule,
    /// the preview names whatever the chips now say, and all of it is dead
    /// without a due date.
    private func syncRepeatControls() {
        let hasDue = dueRow.isOn
        repeatCard.isEnabled = hasDue
        reminderCard.isEnabled = hasDue
        repeatCard.select(Self.presetIndex(for: recurrence))
        reminderCard.select(Self.reminderIndex(for: reminderMinutes))

        let weekly = hasDue && recurrence?.frequency == .weekly
        weekdayRow.isHidden = !weekly
        let selected = recurrence?.weekdays ?? []
        for chip in weekdayChips {
            // `.primary` for a selected day is the same on/off pair the
            // app's other multi-select chip rows use, and it carries the
            // accent fill the mockup shows.
            chip.variant = selected.contains(chip.tag) ? .primary : .secondary
        }

        recurrencePreview.isHidden = !hasDue
        recurrencePreview.stringValue = previewText()
    }

    /// The line under the controls: what this rule means, and when the next
    /// few occurrences actually land.
    ///
    /// Real dates rather than a restatement of the rule - the mockup's
    /// "next 9 occurrences shown" exists so a captain can verify by eye that
    /// "every weekday" is the pattern they meant, which a second English
    /// sentence cannot do.
    private func previewText() -> String {
        guard dueRow.isOn else { return "" }
        guard let rule = recurrence else {
            guard let minutes = reminderMinutes else { return "Happens once." }
            return "Happens once. Reminder \(ShiftReminderOffset.label(for: minutes).lowercased())."
        }
        let anchor = dueDatePicker.dateValue
        let upcoming = rule.occurrences(anchor: anchor, from: anchor, through: nil, limit: 4)
            .dropFirst()
            .map { ShiftDateFormatting.friendly(ShiftDateFormatting.components(from: $0).0) }
        var text = rule.displayName + "."
        if upcoming.isEmpty {
            text += " No further occurrences."
        } else {
            text += " Next: " + upcoming.joined(separator: ", ") + "."
        }
        if let minutes = reminderMinutes {
            text += " Reminder \(ShiftReminderOffset.label(for: minutes).lowercased())."
        }
        return text
    }

    /// Which preset a rule is, or the "Does not repeat" row for a rule this
    /// sheet's own list cannot name (a hand-edited `INTERVAL=3`, say). The
    /// rule itself is *not* discarded by this - only Save writes, and Save
    /// writes `recurrence`, which an unrecognised rule still occupies.
    private static func presetIndex(for rule: ShiftRecurrence?) -> Int {
        guard let rule else { return 0 }
        let normalized = rule.normalized
        for (index, preset) in ShiftRecurrence.presets.enumerated() {
            guard let candidate = preset.rule?.normalized else { continue }
            if candidate.frequency == normalized.frequency && candidate.interval == normalized.interval
                && (candidate.weekdays == normalized.weekdays || candidate.weekdays.isEmpty) {
                return index
            }
        }
        return 0
    }

    private static func reminderIndex(for minutes: Int?) -> Int {
        guard let minutes, let index = ShiftReminderOffset.choices.firstIndex(of: minutes) else { return 0 }
        return index + 1
    }

    /// The seven weekdays starting at the captain's own locale's first day,
    /// so the chip row reads in the same order as the calendar view's columns.
    private static func weekdayOrder() -> [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { ((first - 1 + $0) % 7) + 1 }
    }

    @objc private func dueDatePickerChanged() {
        dueManuallyEdited = true
        let wasHidden = detectedRow.isHidden
        detectedRow.isHidden = true
        if !wasHidden { form.sizeToFitContent() }
    }

    // MARK: Attachment

    @objc private func chooseImageClicked() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
            self?.attachmentWell.handle(image: image)
        }
    }

    // MARK: Save

    @objc private func save() {
        let titleText = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !titleText.isEmpty else {
            view.window?.makeFirstResponder(titleField)
            NSSound.beep()
            return
        }
        // Commit anything typed but not yet committed, or a captain who typed
        // a tag and went straight for Save would silently lose it.
        tagsInput.commitPendingText()

        var task = editing ?? ShiftTask.fresh()
        task.title = titleText
        task.description = descriptionView.string
        task.priority = selectedPriority
        if dueRow.isOn {
            let (dateStr, timeStr) = ShiftDateFormatting.components(from: dueDatePicker.dateValue)
            task.dueDate = dateStr
            task.dueTime = timeStr
        } else {
            task.dueDate = nil
            task.dueTime = nil
        }
        task.projectID = selectedProjectID
        task.tags = tagChips
        // A rule or a reminder with no due date to anchor on is dropped
        // rather than saved: the controls are already disabled in that
        // state, so this only catches a task whose due date was switched
        // off *after* a rule was picked.
        task.recurrence = dueRow.isOn ? recurrence : nil
        task.reminderMinutesBefore = dueRow.isOn ? reminderMinutes : nil
        onSave?(task, attachmentChange ?? .unchanged)
        dismiss(self)
    }

    @objc private func cancel() {
        dismiss(self)
    }

    /// Asks; never deletes. The confirmation and the store call both belong
    /// to `ShiftController.confirmDeleteTask`, so the sheet's Delete and a
    /// card's context menu cannot end up with two different prompts - or, as
    /// GL-06 found across three editors, one prompt and one silent deletion.
    @objc private func deleteTask() {
        guard let id = editing?.id else { return }
        onDelete?(id)
        dismiss(self)
    }

    #if FM_SELFTESTS
    /// The prefilled field values a suite cannot otherwise reach - `titleField`
    /// etc. are `private`, and `presentAsSheet` cannot be relied on to work
    /// headlessly (no self-test in this codebase does - see
    /// `DaylightChromeSelfTest`'s own convention of mounting a sheet directly).
    var debugTitleText: String { titleField.stringValue }
    var debugDescriptionText: String { descriptionView.string }
    var debugDueRowIsOn: Bool { dueRow.isOn }
    var debugDueDateValue: Date { dueDatePicker.dateValue }
    /// Triggers the real `save()` - the same method the footer's own Save
    /// button target/action calls.
    func debugTriggerSave() { save() }
    #endif
}
