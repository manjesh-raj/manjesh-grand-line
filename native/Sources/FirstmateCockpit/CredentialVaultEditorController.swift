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
//   * **The secret field is a `HelmRevealableSecretField`.** It is
//     masked by default even here, because the most common reason to open this
//     sheet on an existing item is to change the *notes* or the tags - not to
//     look at the value. The toggle is local to this sheet and logs nothing:
//     the captain is editing the item, and the audit log's `revealed` event
//     means "the value was put on screen from the list or the detail view",
//     which is the fact worth keeping. Conflating an edit-form unmask with a
//     deliberate reveal would make the log noisier and less meaningful.
//   * **F16 adds a kind, a generator and a 2FA section to this same one
//     sheet**, rather than a second "Add secure note" sheet - for the reason
//     the header above already gives about Add and Edit. A secure note is the
//     same record with its body in the same sealed `secret` field, so it is
//     the same form with the secret control swapped for a multi-line one and
//     the Two-factor section hidden. The generator is inline in the Secret
//     section because the mockup's own note says a generator you have to go
//     and find is one you do not use.
//   * **Tags are a `HelmChipInput`**, not a comma-separated field - the same
//     control the task editor and the Dictation vocabulary well use, so
//     Return-or-comma commits a chip and Backspace on an empty editor pops the
//     last one.

import AppKit

final class CredentialVaultEditorController: NSViewController, NSTextFieldDelegate {

    /// Called with the assembled credential on Save. The caller persists it -
    /// `add` for a new one, `update` for an edit - so this sheet never touches
    /// the store and cannot half-write a record.
    var onSave: ((VaultCredential) -> Void)?
    /// Delete, offered only when editing. The caller runs the confirm-and-undo
    /// flow, which lives with the list so the undo toast has a container that
    /// outlives this sheet.
    var onDelete: ((VaultCredential) -> Void)?

    private let existing: VaultCredential?

    /// F16: copying a generated password out of this sheet goes through the
    /// vault's own concealed writer and its auto-clear, exactly like copying
    /// a stored value - never a bare `NSPasteboard.setString`. Wired by the
    /// page, which owns the clipboard controller.
    var onCopyGenerated: ((String) -> Void)?

    private let titleField = HelmTextField(placeholder: "What is this credential?", style: .lead)
    private let kindCard = HelmFieldCard(label: "Kind")
    private let categoryCard = HelmFieldCard(label: "Category")
    private let accountField = HelmTextField(placeholder: "user@example.com, an IAM user, an ARN\u{2026}")
    private let secretControl =
        HelmRevealableSecretField(placeholder: "The value you'll paste elsewhere")
    private let locationField = HelmTextField(placeholder: "console.aws.amazon.com, an endpoint\u{2026}")
    private let tagsInput = HelmChipInput(placeholder: "Add a tag and press Return")
    private let notesView = HelmTextView(height: 90)
    // `HelmToggleRow` already builds and owns its own switch (laid out beside
    // the title/subtitle) - it is a self-contained control, not a label that
    // needs an external toggle handed to it via `trailing:`. A prior version
    // of this row passed a second, separate `HelmToggle` into `trailing:`,
    // which rendered two switches for one setting (and, since nothing ever
    // called that `HelmToggle`'s own `applyTheme`, left it untethered from
    // theme changes too). `touchIDRow.isOn` is the single source of truth.
    private var touchIDRow: HelmToggleRow!

    // F16. The note body is its own control rather than a mode of
    // `secretField`: a one-line `NSSecureTextField` cannot show six lines of
    // a break-glass procedure, and a captain editing a note is not editing a
    // secret they need masked from someone behind them - they are reading it.
    private let noteBodyView = HelmTextView(height: 150, monospaced: true)
    private let generator = PasswordGeneratorPanel()
    private let generatorToggleButton = HelmButton(title: "Generate a password", variant: .quiet, size: .small, symbol: "wand.and.stars")
    private let totpField = HelmTextField(placeholder: "otpauth://totp/\u{2026} or a base32 secret")
    private let totpPasteButton = HelmButton(title: "Paste", variant: .secondary, size: .small, symbol: "doc.on.clipboard")
    private let totpStatusLabel = NSTextField(labelWithString: "")
    private var totpSectionViews: [NSView] = []
    private var secretRowViews: [NSView] = []
    private var noteRowViews: [NSView] = []

    private var selectedCategory: CredentialCategory
    private var selectedKind: CredentialKind

    /// F2: a secret handed in by ⌥Space's router, to seed the secret field of
    /// an **Add** sheet.
    ///
    /// Deliberately separate from `existing` rather than "just pass a draft
    /// `VaultCredential` as `editing`": `existing != nil` is what makes this
    /// sheet say "Edit credential", offer Delete, and route its save through
    /// `store.update`. A captured secret is a new record, so it must not
    /// touch any of that - only the one field it actually fills.
    private let capturedSecret: String?

    /// `nil` for Add, an existing record for Edit. `capturedSecret` seeds an
    /// Add sheet's secret field (F2) and is ignored when editing.
    init(editing credential: VaultCredential?, capturedSecret: String? = nil) {
        self.existing = credential
        self.capturedSecret = credential == nil ? capturedSecret : nil
        self.selectedCategory = credential?.category ?? .other
        self.selectedKind = credential?.kind ?? .login
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
        kindCard.configureChoices(CredentialKind.allCases.map(\.title),
                                  selectedIndex: CredentialKind.allCases.firstIndex(of: selectedKind) ?? 0) { [weak self] index in
            guard let self, CredentialKind.allCases.indices.contains(index) else { return }
            self.selectedKind = CredentialKind.allCases[index]
            self.applyKind()
        }
        form.addRow(kindCard)
        categoryCard.configureChoices(CredentialCategory.allCases.map(\.title),
                                      selectedIndex: CredentialCategory.allCases.firstIndex(of: selectedCategory) ?? 0) { [weak self] index in
            guard let self, CredentialCategory.allCases.indices.contains(index) else { return }
            self.selectedCategory = CredentialCategory.allCases[index]
        }
        form.addRow(categoryCard)
        form.addField("Account / username", accountField)
        form.addField("Where it's used", locationField)

        form.addSection("Secret", number: "02")
        // The field and its Show toggle, through the one component that owns
        // that pairing (`HelmRevealableSecretField`) - the Settings page's two
        // Google OAuth fields are the other host. Masked by default even here,
        // because the most common reason to open this sheet on an existing
        // item is to change the notes or the tags, not to look at the value.
        let secretRow = secretControl
        secretControl.revealHint = "Show the value in this form while you edit it"
        form.addRow(secretRow)

        generatorToggleButton.target = self
        generatorToggleButton.action = #selector(toggleGenerator)
        let generatorToggleRow = NSStackView(views: [generatorToggleButton])
        generatorToggleRow.orientation = .horizontal
        generatorToggleRow.alignment = .centerY
        generatorToggleRow.translatesAutoresizingMaskIntoConstraints = false
        form.addRow(generatorToggleRow)

        generator.isHidden = true
        generator.onUse = { [weak self] value in self?.useGeneratedPassword(value) }
        generator.onCopy = { [weak self] value in self?.onCopyGenerated?(value) }
        form.addRow(generator)

        // The note body sits in this same section, hidden for a login. A
        // hidden arranged subview of an `NSStackView` is out of layout
        // entirely, so the two variants cost each other no height.
        noteBodyView.isHidden = true
        form.addRow(noteBodyView)
        // The generator is deliberately NOT in this list. `applyKind` shows
        // everything in it for a login, and the generator's visibility is
        // owned by its own toggle - putting it here made switching back to
        // a login silently re-open a panel nobody had asked for.
        secretRowViews = [secretRow, generatorToggleRow]
        noteRowViews = [noteBodyView]

        let totpHeader = form.addSection("Two-factor", number: "03")
        totpPasteButton.target = self
        totpPasteButton.action = #selector(pasteTOTPFromClipboard)
        totpPasteButton.toolTip = "Read an otpauth:// URI or a base32 seed from the clipboard"
        let totpRow = NSStackView(views: [totpField, totpPasteButton])
        totpRow.orientation = .horizontal
        totpRow.alignment = .centerY
        totpRow.spacing = HelmMetrics.s2
        totpRow.distribution = .fill
        totpRow.translatesAutoresizingMaskIntoConstraints = false
        totpRow.setHuggingPriority(.required, for: .horizontal)
        totpPasteButton.setContentHuggingPriority(.required, for: .horizontal)
        totpPasteButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        form.addRow(totpRow)
        totpStatusLabel.font = HelmType.caption()
        totpStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        form.addRow(totpStatusLabel)
        totpField.delegate = self
        totpSectionViews = [totpHeader, totpRow, totpStatusLabel]

        form.addSection("Organise", number: "04")
        form.addField("Tags", tagsInput)
        form.addRow(notesView)

        form.addSection("Protection", number: "05")
        touchIDRow = HelmToggleRow(title: "Require Touch ID to reveal",
                                   subtitle: "An extra gate on top of unlocking the vault, for your most sensitive items.")
        form.addRow(touchIDRow)

        if let existing {
            titleField.stringValue = existing.title
            accountField.stringValue = existing.account
            secretControl.stringValue = existing.secret
            locationField.stringValue = existing.location
            tagsInput.setTokens(existing.tags)
            notesView.string = existing.notes
            touchIDRow.isOn = existing.requiresTouchIDToReveal
            noteBodyView.string = existing.secret
            totpField.stringValue = existing.totp.map(Self.describeForEditing) ?? ""
        } else if let capturedSecret {
            // F2's hand-off: the captured line *is* the secret, so it fills
            // the secret field and nothing else. The title is left empty on
            // purpose - `save` already refuses an untitled credential and
            // focuses the title field, which is exactly the one thing the
            // captain still has to supply.
            secretControl.stringValue = capturedSecret
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
        applyKind()
        renderTOTPStatus()
        form.refreshTheme()
        generator.applyTheme(ThemeManager.shared.theme)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
    }

    // MARK: Actions

    // MARK: F16 - kind, generator, two-factor

    /// Swap the Secret section's control and hide Two-factor, which a note
    /// has no use for. Called on load and on every kind change, so the two
    /// paths cannot drift.
    private func applyKind() {
        let isNote = selectedKind == .secureNote
        secretRowViews.forEach { $0.isHidden = isNote }
        noteRowViews.forEach { $0.isHidden = !isNote }
        // A note closes the generator and resets the button, so switching
        // back to a login starts from the closed state rather than showing
        // a panel nobody asked for.
        if isNote {
            generator.isHidden = true
            generatorToggleButton.title = "Generate a password"
        }
        totpSectionViews.forEach { $0.isHidden = isNote }
    }

    @objc private func toggleGenerator() {
        generator.isHidden.toggle()
        generatorToggleButton.title = generator.isHidden ? "Generate a password" : "Hide the generator"
        if !generator.isHidden { generator.applyTheme(ThemeManager.shared.theme) }
    }

    /// The generator's one write into the form. Deliberately explicit - see
    /// `PasswordGeneratorPanel`'s header on why dragging the slider must not
    /// overwrite a password the captain already typed.
    private func useGeneratedPassword(_ value: String) {
        secretControl.stringValue = value
    }

    /// Read a 2FA seed from the clipboard.
    ///
    /// **Refuses a concealed pasteboard.** `CredentialVaultClipboard.
    /// isConcealed` is this app's one definition of "a secret is on the
    /// pasteboard", and every reader must ask it *before* reading the string
    /// - so this is control flow, not a filter (the rule in AGENTS.md's
    /// "Stores, subprocesses and secrets"). A vault value the captain copied
    /// thirty seconds ago must not be silently pasted in here as a 2FA seed.
    @objc private func pasteTOTPFromClipboard() {
        guard !CredentialVaultClipboard.isConcealed() else {
            totpStatusLabel.stringValue = "The clipboard holds a concealed secret - paste it by hand if you meant to."
            renderTOTPStatusColour(ok: false)
            NSSound.beep()
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return
        }
        totpField.stringValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
        renderTOTPStatus()
    }

    /// Say what the typed seed actually is, live. A 2FA secret is the one
    /// field here whose mistake is invisible until a login fails at the
    /// worst moment, so the sheet states what it parsed rather than only
    /// accepting the text.
    private func renderTOTPStatus() {
        let text = totpField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            totpStatusLabel.stringValue = "Paste an otpauth:// URI or a base32 seed to get a rotating code on this credential's row."
            renderTOTPStatusColour(ok: true)
            return
        }
        guard let config = TOTP.parse(text) else {
            totpStatusLabel.stringValue = "That isn't a readable otpauth URI or base32 seed - nothing will be stored."
            renderTOTPStatusColour(ok: false)
            return
        }
        var parts = ["\(config.digits) digits", "every \(config.period)s", config.algorithm.displayName]
        if !config.issuer.isEmpty { parts.insert(config.issuer, at: 0) }
        // The live code itself, which is the only check that proves the seed
        // is the right one rather than merely well formed - the captain
        // compares it against their phone.
        if let code = TOTP.code(config, at: TOTPTicker.shared.now) {
            parts.append("code now \(TOTP.grouped(code))")
        }
        totpStatusLabel.stringValue = parts.joined(separator: " \u{00B7} ")
        renderTOTPStatusColour(ok: true)
    }

    private func renderTOTPStatusColour(ok: Bool) {
        let theme = ThemeManager.shared.theme
        totpStatusLabel.textColor = ok
            ? HelmTheme.mutedInk(theme)
            : CredentialVaultInk.text(.critical, in: theme)
    }

    /// What the field shows when re-opening a credential that already has a
    /// seed: a real `otpauth://` URI, so the captain can copy it straight
    /// into another app and so nothing is lost by round-tripping the form.
    private static func describeForEditing(_ config: VaultTOTP) -> String {
        var components = URLComponents()
        components.scheme = "otpauth"
        components.host = "totp"
        components.path = "/" + (config.issuer.isEmpty ? "credential" : config.issuer)
        var query = [URLQueryItem(name: "secret", value: config.secret)]
        if !config.issuer.isEmpty { query.append(.init(name: "issuer", value: config.issuer)) }
        query.append(.init(name: "algorithm", value: config.algorithm.displayName))
        query.append(.init(name: "digits", value: "\(config.digits)"))
        query.append(.init(name: "period", value: "\(config.period)"))
        components.queryItems = query
        return components.string ?? config.secret
    }

    private var currentSecret: String { secretControl.stringValue }

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
        credential.kind = selectedKind
        credential.category = selectedCategory
        credential.account = accountField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // The secret is NOT trimmed: a trailing space or newline can be part of
        // a real token, and silently altering a stored value is worse than
        // storing exactly what was typed.
        // A secure note's body IS its secret - the same sealed field, so it
        // takes the same per-item subkey with no parallel storage path (see
        // `CredentialKind`'s own note). Not trimmed, for the same reason a
        // password is not.
        credential.secret = selectedKind == .secureNote ? noteBodyView.string : currentSecret
        // A note has no second factor, so a kind switched to note drops any
        // seed that was typed rather than storing one nothing would ever
        // show.
        credential.totp = selectedKind == .secureNote
            ? nil
            : TOTP.parse(totpField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        credential.location = locationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        credential.tags = tagsInput.tokens
        credential.notes = notesView.string
        credential.requiresTouchIDToReveal = touchIDRow.isOn

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

    // MARK: Field delegate

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === totpField else { return }
        renderTOTPStatus()
    }

    #if FM_SELFTESTS
    var debugTitleField: HelmTextField { titleField }
    var debugSecretControl: HelmRevealableSecretField { secretControl }
    var debugSecretField: HelmSecureTextField { secretControl.maskedField }
    var debugPlainSecretField: HelmTextField { secretControl.plainField }
    var debugShowSecretButton: HelmButton { secretControl.revealButton }
    var debugNotesView: HelmTextView { notesView }
    var debugTagsInput: HelmChipInput { tagsInput }
    var debugTouchIDRow: HelmToggleRow { touchIDRow }
    var debugKindCard: HelmFieldCard { kindCard }
    var debugNoteBodyView: HelmTextView { noteBodyView }
    var debugGenerator: PasswordGeneratorPanel { generator }
    var debugGeneratorIsShown: Bool { !generator.isHidden }
    var debugTOTPField: HelmTextField { totpField }
    var debugTOTPStatusText: String { totpStatusLabel.stringValue }
    var debugTOTPSectionIsShown: Bool { !(totpSectionViews.first?.isHidden ?? true) }
    var debugNoteBodyIsShown: Bool { !noteBodyView.isHidden }
    var debugSecretRowIsShown: Bool { !(secretRowViews.first?.isHidden ?? true) }
    func debugSelectKind(_ kind: CredentialKind) {
        selectedKind = kind
        applyKind()
    }
    func debugToggleGenerator() { toggleGenerator() }
    func debugSetTOTPText(_ text: String) {
        totpField.stringValue = text
        renderTOTPStatus()
    }
    func debugPasteTOTP() { pasteTOTPFromClipboard() }
    var debugSecretIsVisible: Bool { secretControl.isRevealed }
    func debugSave() { save() }
    func debugSelectCategory(_ category: CredentialCategory) { selectedCategory = category }
    #endif
}
