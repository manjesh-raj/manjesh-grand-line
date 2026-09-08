// Manjesh Grand Line - native macOS app.
//
// Add / Edit credential. One sheet for both, which is what the mockup shows and
// says ("Add uses this identical form, empty and titled 'Add credential'") -
// two forms would be two places for a field to be forgotten.
//
// Built on `HelmFormSheet`, the scaffold the app's other nine editor sheets
// already share (Phase 6 of the full-app UI audit): the sheet owns its own
// background, its forced appearance and its one `ThemeManager` observation, and
// every field is a `HelmField` well rather than a stock bezel.
//
// Two things specific to this sheet:
//
//   * **The secret field is a `HelmSecureTextField` with a Show toggle.** It is
//     masked by default even here, because the most common reason to open this
//     sheet on an existing item is to change the *notes* or the tags - not to
//     look at the value. The toggle is local to this sheet and logs nothing:
//     the captain is editing the item, and the audit log's `revealed` event
//     means "the value was put on screen from the list or the detail view",
//     which is the fact worth keeping. Conflating an edit-form unmask with a
//     deliberate reveal would make the log noisier and less meaningful.
//   * **Tags are a `HelmChipInput`**, not a comma-separated field - the same
//     control the task editor and the Dictation vocabulary well use, so
//     Return-or-comma commits a chip and Backspace on an empty editor pops the
//     last one.

import AppKit

final class CredentialVaultEditorController: NSViewController {

    /// Called with the assembled credential on Save. The caller persists it -
    /// `add` for a new one, `update` for an edit - so this sheet never touches
    /// the store and cannot half-write a record.
    var onSave: ((VaultCredential) -> Void)?
    /// Delete, offered only when editing. The caller runs the confirm-and-undo
    /// flow, which lives with the list so the undo toast has a container that
    /// outlives this sheet.
    var onDelete: ((VaultCredential) -> Void)?

    private let existing: VaultCredential?

    private let titleField = HelmTextField(placeholder: "What is this credential?", style: .lead)
    private let categoryCard = HelmFieldCard(label: "Category")
    private let accountField = HelmTextField(placeholder: "user@example.com, an IAM user, an ARN\u{2026}")
    private let secretField = HelmSecureTextField(placeholder: "The value you'll paste elsewhere")
    private let plainSecretField = HelmTextField(placeholder: "The value you'll paste elsewhere")
    private let showSecretButton = HelmButton(title: "Show", variant: .quiet, size: .small, symbol: "eye")
    private let locationField = HelmTextField(placeholder: "console.aws.amazon.com, an endpoint\u{2026}")
    private let tagsInput = HelmChipInput(placeholder: "Add a tag and press Return")
    private let notesView = HelmTextView(height: 90)
    private let touchIDToggle = HelmToggle()
    private var touchIDRow: HelmToggleRow!

    private var selectedCategory: CredentialCategory
    private var secretIsVisible = false

    /// `nil` for Add, an existing record for Edit.
    init(editing credential: VaultCredential?) {
        self.existing = credential
        self.selectedCategory = credential?.category ?? .other
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let isEditing = existing != nil
        // The Poneglyph destination's own domain hue, so this sheet's ribbon
        // and its focus rings match the page it was opened from - §6.10's
        // own rule, and the reason `HelmFormSheet` takes a hue at all.
        let form = HelmFormSheet(title: isEditing ? "Edit credential" : "Add credential",
                                 scrolls: true,
                                 domainHue: RailDestination.poneglyph.domainHue)
        view = form

        form.addLead(titleField)

        form.addSection("Details", number: "01")
        categoryCard.configureChoices(CredentialCategory.allCases.map(\.title),
                                      selectedIndex: CredentialCategory.allCases.firstIndex(of: selectedCategory) ?? 0) { [weak self] index in
            guard let self, CredentialCategory.allCases.indices.contains(index) else { return }
            self.selectedCategory = CredentialCategory.allCases[index]
        }
        form.addRow(categoryCard)
        form.addField("Account / username", accountField)
        form.addField("Where it's used", locationField)

        form.addSection("Secret", number: "02")
        // The field and its Show toggle in one row. Exactly one of the masked
        // and plain fields is in layout at a time rather than both being built
        // and one hidden: an `NSStackView` drops a hidden arranged subview out
        // of layout entirely, which is what keeps the row's height stable
        // across the toggle.
        let secretRow = NSStackView(views: [secretField, plainSecretField, showSecretButton])
        secretRow.orientation = .horizontal
        secretRow.alignment = .centerY
        secretRow.spacing = HelmMetrics.s2
        secretRow.distribution = .fill
        secretRow.setHuggingPriority(.required, for: .horizontal)
        showSecretButton.setContentHuggingPriority(.required, for: .horizontal)
        showSecretButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        showSecretButton.target = self
        showSecretButton.action = #selector(toggleSecretVisibility)
        showSecretButton.toolTip = "Show the value in this form while you edit it"
        plainSecretField.isHidden = true
        form.addRow(secretRow)

        form.addSection("Organise", number: "03")
        form.addField("Tags", tagsInput)
        form.addRow(notesView)

        form.addSection("Protection", number: "04")
        touchIDRow = HelmToggleRow(title: "Require Touch ID to reveal",
                                   subtitle: "An extra gate on top of unlocking the vault, for your most sensitive items.",
                                   trailing: touchIDToggle)
        form.addRow(touchIDRow)

        if let existing {
            titleField.stringValue = existing.title
            accountField.stringValue = existing.account
            secretField.stringValue = existing.secret
            plainSecretField.stringValue = existing.secret
            locationField.stringValue = existing.location
            tagsInput.setTokens(existing.tags)
            notesView.string = existing.notes
            touchIDToggle.isOn = existing.requiresTouchIDToReveal
        }

        form.setFooter(target: self,
                       confirmTitle: isEditing ? "Save" : "Add credential",
                       confirm: #selector(save),
                       cancel: #selector(cancel),
                       // ⌘Return, not a bare one: the notes field is
                       // multi-line and eats a plain Return, which is the same
                       // reason the task editor confirms this way.
                       confirmModifiers: [.command],
                       delete: isEditing ? (title: "Delete", action: #selector(deleteTapped)) : nil)

        form.setSubtitle("Everything here is encrypted with your master password before it touches disk.")
        form.refreshTheme()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
    }

    // MARK: Actions

    /// Keeps the two fields in step so whichever one is visible is the one
    /// `save` reads - see `currentSecret`.
    @objc private func toggleSecretVisibility() {
        secretIsVisible.toggle()
        if secretIsVisible {
            plainSecretField.stringValue = secretField.stringValue
        } else {
            secretField.stringValue = plainSecretField.stringValue
        }
        secretField.isHidden = secretIsVisible
        plainSecretField.isHidden = !secretIsVisible
        showSecretButton.title = secretIsVisible ? "Hide" : "Show"
        showSecretButton.symbolName = secretIsVisible ? "eye.slash" : "eye"
    }

    private var currentSecret: String {
        secretIsVisible ? plainSecretField.stringValue : secretField.stringValue
    }

    @objc private func save() {
        let titleText = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !titleText.isEmpty else {
            view.window?.makeFirstResponder(titleField)
            NSSound.beep()
            return
        }
        // Any pending chip text is committed rather than dropped - a captain
        // who typed a tag and hit Save without pressing Return meant to add it.
        tagsInput.commitPendingText()

        var credential = existing ?? VaultCredential(title: titleText)
        credential.title = titleText
        credential.category = selectedCategory
        credential.account = accountField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // The secret is NOT trimmed: a trailing space or newline can be part of
        // a real token, and silently altering a stored value is worse than
        // storing exactly what was typed.
        credential.secret = currentSecret
        credential.location = locationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        credential.tags = tagsInput.tokens
        credential.notes = notesView.string
        credential.requiresTouchIDToReveal = touchIDToggle.isOn

        onSave?(credential)
        closeSheet()
    }

    @objc private func deleteTapped() {
        guard let existing else { return }
        // The sheet closes first, so the confirm modal and the undo toast are
        // presented by the page - which outlives this sheet. A toast shown on a
        // view that is about to be torn down would flash and vanish.
        closeSheet()
        onDelete?(existing)
    }

    @objc private func cancel() { closeSheet() }

    private func closeSheet() {
        // Audit 2's finding: `dismiss(_:)` *raises* rather than no-opping when
        // nothing presented the controller, so the guard is real rather than
        // defensive.
        if presentingViewController != nil {
            dismiss(self)
        } else {
            view.window?.close()
        }
    }

    #if FM_SELFTESTS
    var debugTitleField: HelmTextField { titleField }
    var debugSecretField: HelmSecureTextField { secretField }
    var debugPlainSecretField: HelmTextField { plainSecretField }
    var debugShowSecretButton: HelmButton { showSecretButton }
    var debugNotesView: HelmTextView { notesView }
    var debugTagsInput: HelmChipInput { tagsInput }
    var debugTouchIDToggle: HelmToggle { touchIDToggle }
    var debugSecretIsVisible: Bool { secretIsVisible }
    func debugSave() { save() }
    func debugSelectCategory(_ category: CredentialCategory) { selectedCategory = category }
    #endif
}
