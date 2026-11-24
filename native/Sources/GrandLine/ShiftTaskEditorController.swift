// Grand Line - native macOS app.
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
//    get it rather than just this one. This sheet has scrolled since the When
//    panel (tasks-calendar plan PR 5), so it no longer takes it.
//
// The mockup's Attachments drag-and-drop section is deliberately NOT part of
// this - that is a different (already-shipped) attachment mechanism in this
// app; these passes restructure presentation, not the attachment model.
//
// **TK-1 "Record preview sheet"** (the hero restyle board,
// `data/grandline-hero-restyle-designs-scout/`) gave the sheet the hero
// language the host and key forms already speak (Host-1):
//
//   - It opens on the task's own card as the board will draw it, on the hero
//     gradient (`RecordPreviewHeader`'s `.sheet` style, in
//     `HelmFormSheet.setHeroHeader`). The card is redrawn on every keystroke
//     and every pick, from the task Save would write right now - so its
//     title is the title as it will be saved, without the date words Save
//     lifts out of it (U16), and they come back the moment the detection is
//     dismissed. The kicker says whether the task is new or which board
//     column it is in, and the facts are its priority, project, repeat,
//     reminder and tags. The words are `TaskHeroWords`.
//   - The title is still the first field and the first responder, now a
//     raised well under the hero rather than a borderless heading.
//   - Each section is a numbered card and every field a raised well
//     (`SectionStyle.cards`, `wellSurface: .raised`), on the page's ground.
//
// The tip and its Detected line, every section, the keys, the validation,
// the focus order, the 520 by 760 sheet and every outcome are unchanged.

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

    /// TK-1: a raised well under the hero. Prominent, the kit's one step up
    /// from a form field, and set in the rounded display face because it
    /// still names the record.
    private let titleField = HelmTextField(placeholder: TaskHeroWords.titlePlaceholder, style: .prominent)
    /// The task's card as the board will draw it, redrawn on every change.
    private let preview = RecordPreviewHeader(tileSize: ShiftTaskEditorController.previewTileSide, style: .sheet,
                                              kickerSymbol: "checklist")
    static let previewTileSide: CGFloat = 34
    /// The title well's face: the board's 17pt semibold, rounded.
    static func titleFont() -> NSFont { HelmType.rounded(HelmType.scaled(17), .semibold) }
    /// Settings' all-day reminder clock, for the preview's reminder fact.
    private let allDayReminderAt: String
    private var hintLabel: NSTextField?
    private let detectedRow = NSStackView()
    private let detectedIcon = NSImageView(image: HelmSymbol.image("calendar.badge.checkmark", pointSize: 11,
                                                               weight: HelmSymbol.weight(for: .medium)) ?? NSImage())
    private let detectedLabel = NSTextField(labelWithString: "")

    /// **Review defect U16.** The live detection behind the "Detected: ..."
    /// row, kept so Save can take those words back out of the title.
    ///
    /// Held rather than re-parsed at Save time on purpose: the captain may
    /// have dismissed the row or driven the due switch by hand since, and
    /// in both of those cases the phrase stays in the title. Re-parsing
    /// would have no way to know that happened.
    ///
    /// The title is **not** rewritten while typing. Editing the field out
    /// from under someone mid-sentence is worse than the defect; the lift
    /// happens once, on Save.
    private var detectedPhrase: ShiftParsedDate?

    private var selectedPriority: ShiftPriority
    private let priorityDot = HelmDotAccessory()
    private lazy var priorityCard = HelmFieldCard(label: "Priority", accessory: priorityDot)

    private var selectedProjectID: String?
    private let projectIconTile = IconTileView(size: 22, cornerRadius: HelmMetrics.rChip)
    private lazy var projectCard = HelmFieldCard(label: "Project", accessory: projectIconTile)

    /// The When panel (tasks-calendar plan PR 5): the date, the time (All
    /// day or At a time), the repeat rule and the reminder, in the one
    /// component the calendar's popover also uses. It replaced the "Set due
    /// date" switch and the Repeat and Remind cards, which is also what
    /// stopped a date-only task being saved with a time of day it never had.
    private let scheduleEditor: ShiftScheduleEditor

    /// Daylight §6.9's chips-in-well, replacing the field-plus-separate-flow
    /// pattern this row used to be. The interaction is unchanged (Return or a
    /// trailing comma commits, the ✕ on a chip removes it); Backspace on an
    /// empty editor now pops the last tag, which the two-view version had no
    /// way to offer.
    private let tagsInput = HelmChipInput(placeholder: "Add a tag and press Return")
    private var tagChips: [String] = []

    private let descriptionView = HelmTextView(height: 110)

    /// Once the person edits the When panel directly, further title edits
    /// stop overwriting their choice - only a brand-new detected phrase
    /// should ever clobber a still-untouched date, never a deliberate manual
    /// edit.
    private var dueManuallyEdited = false
    /// The rule the When panel held before a repeat phrase in the title
    /// replaced it. `nil` while no detected rule is in place.
    private var ruleBeforeDetection: ShiftRecurrence??

    init(task: ShiftTask?, projects: [ShiftProject], defaultProjectID: String? = nil, existingAttachmentData: Data? = nil,
         prefillTitle: String? = nil, prefillDescription: String? = nil,
         prefillDueDate: String? = nil, prefillDueTime: String? = nil,
         allDayReminderAt: String = ShiftDue.defaultAllDayReminderAt) {
        self.editing = task
        self.projects = projects
        self.defaultProjectID = defaultProjectID
        self.existingAttachmentData = existingAttachmentData
        self.prefillTitle = prefillTitle
        self.prefillDescription = prefillDescription
        self.prefillDueDate = prefillDueDate
        self.prefillDueTime = prefillDueTime
        // `task?.dueDate` is `String??` collapsed by optional chaining -
        // genuinely `nil` when editing an existing task that has no due date,
        // not merely "editing is nil". The prefill must never fill that in,
        // so it only applies for a brand-new task.
        self.scheduleEditor = ShiftScheduleEditor(
            draft: ShiftScheduleDraft(day: task != nil ? task?.dueDate : prefillDueDate,
                                      time: task != nil ? task?.dueTime : prefillDueTime,
                                      recurrence: task?.recurrence,
                                      reminderMinutes: task?.reminderMinutesBefore),
            allDayReminderAt: allDayReminderAt)
        self.allDayReminderAt = allDayReminderAt
        self.selectedPriority = task?.priority ?? .normal
        let candidateProjectID = task?.projectID ?? defaultProjectID
        self.selectedProjectID = projects.contains { $0.id == candidateProjectID } ? candidateProjectID : nil
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // Scrolling since the When panel: with a repeat rule's rows and its
        // preview the form measured 1,218pt, taller than a laptop's screen, so
        // a fixed sheet would put Save below the bottom edge.
        // The content cap is the column a 520pt sheet actually has. Left at
        // the default 520, the scrolling layout's preferred column width (at
        // 750, over the window's 500 hold - AGENTS.md gotcha (13)) widened the
        // sheet to 564pt, measured.
        let form = HelmFormSheet(title: editing == nil ? "New Task" : "Edit Task", scrolls: true,
                                 maxContentWidth: HelmFormSheet.width - 2 * HelmFormSheet.gutter,
                                 sectionStyle: .cards, wellSurface: .raised)
        form.setFrameSize(NSSize(width: HelmFormSheet.width, height: Self.sheetHeight))
        self.form = form
        view = form
        form.onApplyTheme = { [weak self] theme in self?.applyExtraTheme(theme) }

        // MARK: The hero (TK-1)

        preview.tile.configure(symbol: "checkmark.circle", tint: .info, pointSize: HelmType.scaled(15))
        form.setHeroHeader(preview)

        // MARK: Title + natural-language date hint

        titleField.stringValue = editing?.title ?? prefillTitle ?? ""
        titleField.font = Self.titleFont()
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

        form.addSection("Details", number: "01")
        priorityCard.onClick = { [weak self] in self?.priorityCardClicked() }
        projectIconTile.configure(symbol: "folder.fill", tint: .info, pointSize: 11)
        projectCard.onClick = { [weak self] in self?.projectCardClicked() }
        updatePriorityCard()
        updateProjectCard()
        form.addColumns([priorityCard, projectCard])

        // MARK: When

        form.addSection("When", number: "02")
        scheduleEditor.onChange = { [weak self] _ in self?.scheduleEdited() }
        form.addRow(scheduleEditor)

        // MARK: Tags

        form.addSection("Tags", number: "03")
        tagChips = editing?.tags ?? []
        tagsInput.setTokens(tagChips)
        tagsInput.onTokensChanged = { [weak self] tokens in
            guard let self else { return }
            self.tagChips = tokens
            self.refreshPreview()
        }
        form.addRow(tagsInput)

        // MARK: Description

        form.addSection("Description", number: "04")
        descriptionView.string = editing?.description ?? prefillDescription ?? ""
        form.addRow(descriptionView)

        // MARK: Attachment (existing feature, unchanged)

        chooseImageButton.target = self
        chooseImageButton.action = #selector(chooseImageClicked)
        chooseImageButton.controlSize = .small
        form.addSection("Attachment", number: "05", actions: [chooseImageButton])
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

        // The hero replaced the heading block, and "Something to do." with
        // it: the card says what the task is.
        refreshPreview()
        form.refreshTheme()
    }

    /// The sheet's height. It scrolls inside that, so it fits a 13-inch
    /// screen under the window's title bar with room to spare.
    static let sheetHeight: CGFloat = 760

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
    }

    // MARK: The preview (TK-1)

    /// The task Save would write right now, built exactly as Save builds it.
    /// The preview is drawn from this, so the card can only ever show what
    /// Save would store.
    private func assembledTask() -> ShiftTask {
        var task = editing ?? ShiftTask.fresh()
        task.title = TaskHeroWords.savedTitle(titleField.stringValue, detected: detectedPhrase,
                                              hasDueDate: scheduleEditor.draft.day != nil)
        task.description = descriptionView.string
        task.priority = selectedPriority
        // The date, the time, the rule and the reminder, through the one
        // mapping the calendar's popover also writes with. A rule or a
        // reminder with no date to anchor on is dropped there.
        task = scheduleEditor.draft.applied(to: task)
        task.projectID = selectedProjectID
        task.tags = tagChips
        return task
    }

    /// Redraw the card from what the sheet holds. Called after every change
    /// the card shows: a keystroke in the title, a priority or project pick,
    /// a When edit, a tag, and the Detected line's dismissal.
    private func refreshPreview() {
        let task = assembledTask()
        let projectName = projects.first { $0.id == task.projectID }?.name
        preview.tile.configure(symbol: "checkmark.circle", tint: priorityTint(task.priority),
                               pointSize: HelmType.scaled(15))
        preview.update(.init(kicker: TaskHeroWords.kicker(editing: editing?.status),
                             title: task.title,
                             titlePlaceholder: TaskHeroWords.titlePlaceholder,
                             subtitle: TaskHeroWords.subtitle(dueDate: task.dueDate, dueTime: task.dueTime,
                                                              projectName: projectName),
                             badge: TaskHeroWords.badge(for: task.priority),
                             badgeTint: .critical,
                             facts: TaskHeroWords.facts(for: task, projectName: projectName,
                                                        allDayReminderAt: allDayReminderAt),
                             subtitleSymbol: "calendar"))
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
        // The When panel themes itself, so the calendar's popover and this
        // sheet paint it the same way.
        tagsInput.applyTheme(theme)
        attachmentWell.applyTheme(theme)
    }

    private func hintAttributedString(muted: NSColor, emphasis: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: HelmType.caption(), .foregroundColor: muted]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: HelmType.scaled(11.5), weight: .semibold), .foregroundColor: emphasis]
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
        refreshPreview()
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
        refreshPreview()
    }

    // MARK: Live date detection

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        // `HelmChipInput` owns its own editor and its own delegate, so the tag
        // row no longer routes through here at all.
        guard field === titleField else { return }
        // Every keystroke redraws the card, on whichever path below returns.
        defer { refreshPreview() }
        guard !dueManuallyEdited else { return }
        guard let parsed = ShiftDateParser.parse(titleField.stringValue) else {
            restoreRuleBeforeDetection()
            detectedRow.isHidden = true
            return
        }
        if parsed.recurrence == nil { restoreRuleBeforeDetection() }
        let (dateStr, timeStr) = ShiftDateFormatting.components(from: parsed.date)
        var draft = scheduleEditor.draft
        draft.setDay(dateStr)
        // A date-only phrase like "next mon" keeps whatever the panel's Time
        // row already says, rather than silently making it all day or
        // inventing a time.
        if parsed.hasTime { draft.time = timeStr }
        // A repeat phrase ("every tue") is lifted out of the title on save
        // just as the date is, so its rule must land in the panel here, or the
        // phrase would be cut from the title with nothing saved in its place
        // (tasks-calendar plan PR 7).
        if let rule = parsed.recurrence {
            if ruleBeforeDetection == nil { ruleBeforeDetection = .some(draft.recurrence) }
            draft = Self.draft(draft, with: rule)
        }
        // `setDraft`, not an edit: the panel's own `onChange` is how this
        // sheet knows the captain took the date over, and detection is not
        // the captain. Review defect U16's second half lives on here too: a
        // date that arrived by detection leaves Remind live, because the
        // panel re-derives every row from the draft.
        scheduleEditor.setDraft(draft)
        var detected = ShiftDateFormatting.friendly(dateStr, time: parsed.hasTime ? timeStr : nil)
        if let rule = parsed.recurrence { detected += " \u{00B7} \(rule.displayName)" }
        detectedLabel.stringValue = "Detected: \(detected)"
        detectedRow.isHidden = false
        detectedPhrase = parsed
    }

    @objc private func dismissDetected() {
        detectedRow.isHidden = true
        dueManuallyEdited = true
        // U16: the captain has said "that is not a date" - so the title
        // keeps the words, and Save must not lift them out of it.
        detectedPhrase = nil
        restoreRuleBeforeDetection()
        refreshPreview()
    }

    /// Puts back the rule the When panel held before a repeat phrase in the
    /// title replaced it: the phrase is gone, or the detection was dismissed.
    private func restoreRuleBeforeDetection() {
        guard let before = ruleBeforeDetection else { return }
        ruleBeforeDetection = nil
        scheduleEditor.setDraft(Self.draft(scheduleEditor.draft, with: before))
    }

    /// The panel's draft with its repeat rule replaced, keeping the day, the
    /// time and the reminder.
    private static func draft(_ draft: ShiftScheduleDraft, with rule: ShiftRecurrence?) -> ShiftScheduleDraft {
        ShiftScheduleDraft(day: draft.day, time: draft.time, recurrence: rule, reminderMinutes: draft.reminderMinutes)
    }

    /// The captain changed the When panel by hand. That supersedes the
    /// detection, including keeping the phrase in the title (U16), and
    /// stops later title edits from moving the date.
    private func scheduleEdited() {
        dueManuallyEdited = true
        detectedPhrase = nil
        // Whatever the panel holds now is the captain's, so a dismissed or
        // retyped phrase has nothing of its own to put back.
        ruleBeforeDetection = nil
        detectedRow.isHidden = true
        refreshPreview()
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
        // U16: the detected phrase has become structured data in the due
        // field, so it comes out of the prose. `titleWithoutDatePhrase`
        // returns the title unchanged when the phrase *was* the whole title.
        // The preview's card shows the title through the same function.
        let titleText = TaskHeroWords.savedTitle(titleField.stringValue, detected: detectedPhrase,
                                                 hasDueDate: scheduleEditor.draft.day != nil)
        guard !titleText.isEmpty else {
            view.window?.makeFirstResponder(titleField)
            NSSound.beep()
            return
        }
        // Commit anything typed but not yet committed, or a captain who typed
        // a tag and went straight for Save would silently lose it.
        tagsInput.commitPendingText()
        onSave?(assembledTask(), attachmentChange ?? .unchanged)
        dismissIfPresented()
    }

    /// AGENTS.md gotcha (6) has the other half of this: `dismiss(_:)` is a
    /// no-op for a controller whose window took it as `contentViewController`.
    /// For one that was never presented *at all* it is worse than a no-op -
    /// AppKit raises `NSInternalInconsistencyException` ("maybe this view
    /// controller was not presented?") and the process dies. A window-backed
    /// suite that drives the real Save button hits exactly that, so the
    /// check is here rather than in each caller.
    private func dismissIfPresented() {
        if presentingViewController != nil {
            dismiss(self)
        } else {
            view.window?.close()
        }
    }

    @objc private func cancel() {
        dismissIfPresented()
    }

    /// Asks; never deletes. The confirmation and the store call both belong
    /// to `ShiftController.confirmDeleteTask`, so the sheet's Delete and a
    /// card's context menu cannot end up with two different prompts - or, as
    /// GL-06 found across three editors, one prompt and one silent deletion.
    @objc private func deleteTask() {
        guard let id = editing?.id else { return }
        onDelete?(id)
        dismissIfPresented()
    }

    #if FM_SELFTESTS
    /// The prefilled field values a suite cannot otherwise reach - `titleField`
    /// etc. are `private`, and `presentAsSheet` cannot be relied on to work
    /// headlessly (no self-test in this codebase does - see
    /// `DaylightChromeSelfTest`'s own convention of mounting a sheet directly).
    var debugTitleText: String { titleField.stringValue }
    var debugDescriptionText: String { descriptionView.string }
    /// The When panel itself, for a suite that clicks its real controls.
    var debugScheduleEditor: ShiftScheduleEditor { scheduleEditor }
    var debugHasDueDate: Bool { scheduleEditor.draft.day != nil }
    /// Triggers the real `save()` - the same method the footer's own Save
    /// button target/action calls.
    func debugTriggerSave() { save() }

    /// Review defect U16: whether the Repeat and Remind pickers are live.
    /// Read off the controls, not re-derived from the draft - the whole
    /// defect was that the two had drifted apart.
    var debugRepeatEnabled: Bool { scheduleEditor.debugRepeatPopup.isEnabled }
    var debugReminderEnabled: Bool { scheduleEditor.debugReminderPopup.isEnabled }

    /// Drives the real `controlTextDidChange` path a keystroke in the title
    /// field takes - never the private helper behind it, which would leave
    /// the wiring free to be deleted with this check still green
    /// (AGENTS.md's `debug*` hook rule).
    func debugTypeTitle(_ text: String) {
        titleField.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                          object: titleField))
    }

    /// Drives the real "that is not a date" button's action.
    func debugDismissDetected() { dismissDetected() }

    /// TK-1: the hero card and the title well, read off the real views.
    var debugPreview: RecordPreviewHeader { preview }
    var debugTitleField: NSTextField { titleField }
    var debugTagsInput: HelmChipInput { tagsInput }
    /// A pick from the Priority or Project menu, entering where the menu
    /// item's own action does - the card's menu is built per click, so the
    /// item is the one thing a suite cannot reach.
    func debugChoosePriority(_ priority: ShiftPriority) {
        let item = NSMenuItem()
        item.representedObject = priority.rawValue
        priorityItemSelected(item)
    }
    func debugChooseProject(id: String?) {
        let item = NSMenuItem()
        item.representedObject = id
        projectItemSelected(item)
    }
    #endif
}
