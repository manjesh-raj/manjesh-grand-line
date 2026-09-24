// Grand Line - native macOS app.
//
// The vault's gate: one view with three states, driven by what is actually on
// disk rather than by a flag.
//
//   * **`.create`** - no vault exists here yet. Two password fields, a live
//     strength meter, and a warning that says plainly what this password
//     protects and that it cannot be recovered. This screen writes the only
//     copy of the vault, so `CredentialVaultStore.createVault` refuses if a
//     file is already there; this state is only ever shown for `.absent`.
//   * **`.unlock`** - a vault exists. One password field, plus a Touch ID
//     button when a key is stored on this Mac. First unlock on a new Mac looks
//     exactly like this: the encrypted file arrived with the `manjesh-config`
//     clone, and there is nothing else to configure.
//   * **`.unreadable`** - GL-01. The file is there and could not be read. This
//     state deliberately offers **no** way to create a new vault: doing so
//     would write over real, intact, encrypted credentials, which is precisely
//     the failure GL-01 exists to prevent. It names the backup copy instead.
//
// **This is a plain `NSView`, not a sheet or a separate window.** It is shown
// in place of the list inside the same destination, so a lock is a state of the
// Poneglyph page rather than a modal the captain has to dismiss - and so the
// existing whole-app lock screen (`LockScreenController`) stays the only
// full-window gate. The two passwords are independent by the captain's own
// decision ("Let us have different passwords for the vault as well as the
// application password"), and keeping this gate inside the page is what makes
// that read as two separate things rather than one lock asked twice.

import AppKit

final class CredentialVaultUnlockView: NSView {

    enum Mode: Equatable {
        case create
        /// `recoveryAvailable` defaults to false so every existing call site
        /// (and every existing suite) reads unchanged - F17's door is only
        /// offered on a vault that actually has a printed key behind it.
        case unlock(touchIDAvailable: Bool, recoveryAvailable: Bool = false)
        case unreadable(reason: String, backupPath: String?)
    }

    /// Create a new vault with this password. The controller does the work.
    var onCreate: ((String) -> Void)?
    var onUnlock: ((String) -> Void)?
    var onUnlockWithTouchID: (() -> Void)?
    /// F17: unlock with a printed recovery key. The controller runs the
    /// unwrap; this view only collects the typed code.
    var onUnlockWithRecoveryKey: ((String) -> Void)?

    private let card = HelmCard()
    private let iconTile = IconTileView(size: HelmMetrics.tileLarge, cornerRadius: 12)
    private let titleLabel = NSTextField(labelWithString: "Poneglyph")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let passwordField = HelmSecureTextField(placeholder: "Master password")
    private let confirmField = HelmSecureTextField(placeholder: "Confirm master password")
    private let strengthLabel = NSTextField(labelWithString: "")
    /// Review #3's UX8: "a password manager owes the user that sentence at
    /// *creation* time ('There is no recovery. Write this down.'), plus a
    /// strength meter and a 'confirm you saved it' step."
    ///
    /// The sentence already existed - as the tail of a five-clause subtitle
    /// paragraph, which is exactly where a reader's eye does not go. It is its
    /// own tinted card now, above the fields rather than below them, because
    /// the one moment it changes behaviour is *before* the captain has chosen
    /// a password rather than after.
    private var recoveryWarningCard: NSView?
    private let recoveryWarningLabel = NSTextField(wrappingLabelWithString:
        "There is no recovery. If you forget this password, every credential in "
        + "this vault is gone - Grand Line cannot reset it, and neither can anyone else. "
        + "Write it down somewhere safe before you continue.")
    /// The meter half. The label alone said "Strength: Fair", which is a
    /// verdict rather than a meter - this is the same `HelmProgressBar` the
    /// Hosts keychain card already uses, so the app draws one bar, not two.
    private let strengthBar = HelmProgressBar()
    /// The "confirm you saved it" step. The create button is disabled until
    /// this is on.
    private let savedItRow = HelmToggleRow(
        title: "I have written my master password down somewhere safe")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = HelmButton(title: "Unlock", variant: .primary)
    private let touchIDButton = HelmButton(title: "Unlock with Touch ID", variant: .secondary, symbol: "touchid")
    private let orLabel = NSTextField(labelWithString: "or")
    /// F17. A `.quiet` link rather than a third bordered button: it is the
    /// door you take once, on the worst day, and it must not compete with
    /// the password field every other day.
    private let recoveryLinkButton = HelmButton(title: "Use a recovery key", variant: .quiet, size: .small,
                                                symbol: "shield.lefthalf.filled")
    /// Deliberately a plain field, not a secure one: a captain is
    /// transcribing 32 characters off a printed sheet, and masking that is
    /// how a typo becomes five failed attempts and a throttle.
    private let recoveryField = HelmTextField(placeholder: "7QK4 2MRD 9FTV \u{2026}")
    private var usingRecoveryKey = false
    private var recoveryAvailable = false
    private var infoCard: NSView?
    private let infoLabel = NSTextField(wrappingLabelWithString: "")

    private let column = NSStackView()
    private var mode: Mode = .create
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = HelmType.pageTitle(.display)
        subtitleLabel.font = HelmType.body()
        strengthLabel.font = HelmType.chip()
        messageLabel.font = HelmType.caption()
        infoLabel.font = HelmType.caption()

        passwordField.target = self
        passwordField.action = #selector(primaryClicked)
        confirmField.target = self
        confirmField.action = #selector(primaryClicked)
        // Live strength feedback while typing, which only the create state
        // shows - `HelmSecureTextField` is an `NSSecureTextField`, so this is
        // the ordinary control-text-did-change path.
        passwordField.delegate = self
        // The gate reads both fields, so both have to report a change - before
        // this, typing a matching confirmation left the button disabled until
        // something else happened to re-evaluate it.
        confirmField.delegate = self
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.keyEquivalent = "\r"
        touchIDButton.target = self
        touchIDButton.action = #selector(touchIDClicked)
        recoveryLinkButton.target = self
        recoveryLinkButton.action = #selector(recoveryLinkClicked)
        recoveryField.isHidden = true

        let orRow = NSStackView(views: [orLabel])
        orRow.orientation = .horizontal
        orRow.alignment = .centerY

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s3
        column.translatesAutoresizingMaskIntoConstraints = false
        recoveryWarningLabel.font = HelmType.caption()
        savedItRow.onToggle = { [weak self] in self?.updateCreateAvailability() }
        let warningCard = NSView()
        warningCard.wantsLayer = true
        warningCard.translatesAutoresizingMaskIntoConstraints = false
        recoveryWarningLabel.translatesAutoresizingMaskIntoConstraints = false
        warningCard.addSubview(recoveryWarningLabel)
        NSLayoutConstraint.activate([
            recoveryWarningLabel.leadingAnchor.constraint(equalTo: warningCard.leadingAnchor, constant: HelmMetrics.s3),
            recoveryWarningLabel.trailingAnchor.constraint(equalTo: warningCard.trailingAnchor, constant: -HelmMetrics.s3),
            recoveryWarningLabel.topAnchor.constraint(equalTo: warningCard.topAnchor, constant: HelmMetrics.s3),
            recoveryWarningLabel.bottomAnchor.constraint(equalTo: warningCard.bottomAnchor, constant: -HelmMetrics.s3),
        ])
        recoveryWarningCard = warningCard

        // Order matters: the warning sits **above** the fields. The one moment
        // "there is no recovery" changes what a captain does is before they
        // choose a password, not after.
        for view in [iconTile, titleLabel, subtitleLabel, warningCard, passwordField, recoveryField, confirmField,
                     strengthBar, strengthLabel, savedItRow, messageLabel,
                     primaryButton, orRow, touchIDButton, recoveryLinkButton] as [NSView] {
            column.addArrangedSubview(view)
        }
        for view in [warningCard, strengthBar, savedItRow] as [NSView] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        strengthBar.heightAnchor.constraint(equalToConstant: HelmProgressBar.height).isActive = true
        // The two fields and the primary action fill the column's width; the
        // labels and the icon tile keep their own size. Without the width ties
        // a leading-aligned vertical stack leaves both fields at their
        // intrinsic width, which is narrower than the card.
        for view in [passwordField, recoveryField, confirmField, primaryButton, touchIDButton] as [NSView] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        subtitleLabel.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        messageLabel.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        card.setBody(column, insets: NSEdgeInsets(top: HelmMetrics.s5, left: HelmMetrics.s5,
                                                  bottom: HelmMetrics.s5, right: HelmMetrics.s5))
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // Centred, capped, and - per AGENTS.md's host-editor gotcha (3) -
        // positioned with inequalities plus a `centerX` tie rather than a
        // required width equality, which would make the whole window snap back
        // to the one width where that equality has zero slack.
        let cap = card.widthAnchor.constraint(equalToConstant: 420)
        cap.priority = HelmDaylightPriority.contentTie
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: HelmMetrics.pageGutter),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.pageGutter),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            cap,
        ])

        setMode(.create)
    }

    // MARK: Mode

    func setMode(_ mode: Mode) {
        self.mode = mode
        messageLabel.stringValue = ""
        messageLabel.isHidden = true
        infoCard?.isHidden = true

        switch mode {
        case .create:
            iconTile.configure(symbol: "lock.shield.fill", tint: .accent)
            titleLabel.stringValue = "Set up your vault"
            subtitleLabel.stringValue = "Choose a master password. It encrypts every credential you store here, and it is never saved anywhere - not on disk, not in the Keychain, not in the vault file. Nobody can recover it for you."
            passwordField.isHidden = false
            passwordField.placeholderString = "Master password"
            confirmField.isHidden = false
            strengthLabel.isHidden = false
            strengthBar.isHidden = false
            recoveryWarningCard?.isHidden = false
            savedItRow.isHidden = false
            // A fresh gate every time this state is entered: a captain who
            // backed out of creation and came back has not confirmed anything.
            savedItRow.isOn = false
            primaryButton.title = "Create Poneglyph"
            primaryButton.isHidden = false
            orLabel.isHidden = true
            touchIDButton.isHidden = true
            recoveryLinkButton.isHidden = true
            recoveryField.isHidden = true
            usingRecoveryKey = false
            updateStrength()

        case .unlock(let touchIDAvailable, let recoveryAvailable):
            self.recoveryAvailable = recoveryAvailable
            self.usingRecoveryKey = false
            recoveryField.stringValue = ""
            iconTile.configure(symbol: "lock.fill", tint: .accent)
            titleLabel.stringValue = "Poneglyph"
            subtitleLabel.stringValue = "Enter your master password to unlock."
            passwordField.isHidden = false
            passwordField.placeholderString = "Master password"
            confirmField.isHidden = true
            strengthLabel.isHidden = true
            strengthBar.isHidden = true
            recoveryWarningCard?.isHidden = true
            savedItRow.isHidden = true
            primaryButton.isEnabled = true
            primaryButton.title = "Unlock"
            primaryButton.isHidden = false
            orLabel.isHidden = !touchIDAvailable
            touchIDButton.isHidden = !touchIDAvailable
            applyRecoveryMode()

        case .unreadable(let reason, let backupPath):
            iconTile.configure(symbol: "exclamationmark.triangle.fill", tint: .critical)
            titleLabel.stringValue = "Poneglyph unavailable"
            subtitleLabel.stringValue = reason
            passwordField.isHidden = true
            confirmField.isHidden = true
            strengthLabel.isHidden = true
            strengthBar.isHidden = true
            recoveryWarningCard?.isHidden = true
            savedItRow.isHidden = true
            // Deliberately no primary action. See this file's header: offering
            // "create a new vault" here is how real credentials get destroyed.
            primaryButton.isHidden = true
            orLabel.isHidden = true
            touchIDButton.isHidden = true
            recoveryLinkButton.isHidden = true
            recoveryField.isHidden = true
            usingRecoveryKey = false
            if let backupPath {
                showInfo("Your original file was copied aside to \(backupPath) before anything else happened. Nothing has been overwritten.")
            } else {
                showInfo("Nothing has been overwritten. Grand Line will not create a new vault while a file it cannot read is on disk.")
            }
        }
        applyTheme(theme)
    }

    /// Show a rejection or a failure. Never clears the password field for a
    /// wrong password - retyping a long passphrase because of one typo is a
    /// worse experience than leaving it to be corrected.
    func showMessage(_ text: String, tint: HelmTint = .critical) {
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
        messageLabel.textColor = CredentialVaultInk.text(tint, in: theme)
    }

    func clearPasswordFields() {
        passwordField.stringValue = ""
        confirmField.stringValue = ""
        updateStrength()
    }

    #if FM_SELFTESTS
    var debugPasswordField: HelmSecureTextField { passwordField }
    var debugConfirmField: HelmSecureTextField { confirmField }
    /// UX8's "confirm you saved it" step, and the gate it drives.
    var debugSavedItRow: HelmToggleRow { savedItRow }
    var debugPrimaryButton: HelmButton { primaryButton }
    var debugRecoveryWarningText: String { recoveryWarningLabel.stringValue }
    var debugRecoveryWarningVisible: Bool { recoveryWarningCard?.isHidden == false }
    var debugStrengthBarVisible: Bool { !strengthBar.isHidden }
    /// Drives the same path `controlTextDidChange` does, so a suite can set a
    /// field and have the gate re-evaluate exactly as typing would.
    func debugFieldsChanged() { updateStrength() }
    var debugRecoveryLinkVisible: Bool { !recoveryLinkButton.isHidden }
    var debugRecoveryFieldVisible: Bool { !recoveryField.isHidden }
    var debugPasswordFieldVisible: Bool { !passwordField.isHidden }
    var debugSubtitleText: String { subtitleLabel.stringValue }
    var debugPrimaryTitle: String { primaryButton.title }
    var debugMessageText: String { messageLabel.stringValue }
    func debugClickRecoveryLink() { recoveryLinkClicked() }
    func debugTypeRecoveryKey(_ code: String) { recoveryField.stringValue = code }
    func debugClickPrimary() { primaryClicked() }
    #endif

    func focusPasswordField() {
        window?.makeFirstResponder(passwordField)
    }

    /// Disable the controls while a derivation is running - PBKDF2 is
    /// deliberately slow, and a second Return before the first finishes would
    /// otherwise queue a duplicate attempt (and, at the throttle boundary, burn
    /// an attempt the captain did not make).
    func setBusy(_ busy: Bool) {
        primaryButton.isEnabled = !busy
        touchIDButton.isEnabled = !busy
        passwordField.isEnabled = !busy
        recoveryField.isEnabled = !busy
        recoveryLinkButton.isEnabled = !busy
        confirmField.isEnabled = !busy
        if busy { showMessage("Deriving your key\u{2026}", tint: .neutral) }
    }

    private func showInfo(_ text: String) {
        infoLabel.stringValue = text
        if infoCard == nil {
            let box = NSView()
            box.wantsLayer = true
            box.translatesAutoresizingMaskIntoConstraints = false
            infoLabel.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(infoLabel)
            NSLayoutConstraint.activate([
                infoLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: HelmMetrics.s3),
                infoLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -HelmMetrics.s3),
                infoLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: HelmMetrics.s3),
                infoLabel.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -HelmMetrics.s3),
            ])
            column.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            infoCard = box
        }
        infoCard?.isHidden = false
    }

    private func updateStrength() {
        guard case .create = mode else { return }
        let password = passwordField.stringValue
        guard !password.isEmpty else {
            strengthLabel.stringValue = "At least \(CredentialVaultPasswordStrength.minimumLength) characters. A long passphrase beats a short complicated one."
            strengthLabel.textColor = HelmTheme.mutedInk(theme)
            strengthBar.configure(fraction: 0)
            updateCreateAvailability()
            return
        }
        let strength = CredentialVaultPasswordStrength.evaluate(password)
        strengthLabel.stringValue = "Strength: \(strength.label)"
        strengthLabel.textColor = CredentialVaultInk.text(strength.tint, in: theme)
        strengthBar.configure(fraction: Self.strengthFraction(strength))
        strengthBar.applyTheme(theme, hue: Self.strengthHue(strength))
        updateCreateAvailability()
    }

    /// How full the meter is for each verdict.
    ///
    /// `tooShort` is deliberately not zero: an empty field is zero, and a
    /// password that is genuinely too short is further along than nothing.
    /// Derived from the enum's own `rawValue` rather than a second table, so a
    /// fifth verdict cannot be added without the bar following it.
    static func strengthFraction(_ strength: CredentialVaultPasswordStrength) -> Double {
        let maximum = Double(CredentialVaultPasswordStrength.strong.rawValue)
        return (Double(strength.rawValue) + 1) / (maximum + 1)
    }

    /// The bar's hue tracks the label's tint, so the meter and the word beside
    /// it can never disagree about whether a password is good.
    static func strengthHue(_ strength: CredentialVaultPasswordStrength) -> HelmDomainHue {
        switch strength.tint {
        case .critical: return .rose
        case .warn: return .amber
        default: return .teal
        }
    }

    /// UX8's "confirm you saved it" gate.
    ///
    /// The create button is disabled until the password is long enough, the
    /// two fields match **and** the captain has ticked the confirmation. The
    /// gate is a real disable rather than a rejection after the click,
    /// because the point of the step is to be read before the password is
    /// committed - a dialog that says "you should have written it down" after
    /// the vault exists is not a step, it is a reproach.
    ///
    /// `primaryClicked` still re-checks all three. A disabled button is a
    /// courtesy; the guard is the contract, and Return in a text field reaches
    /// the action directly.
    private func updateCreateAvailability() {
        guard case .create = mode else { return }
        primaryButton.isEnabled = canCreate
    }

    /// Whether the create action may proceed - one definition, read by both
    /// the button's enabled state and the action's own guard.
    private var canCreate: Bool {
        let password = passwordField.stringValue
        return CredentialVaultPasswordStrength.evaluate(password) != .tooShort
            && password == confirmField.stringValue
            && savedItRow.isOn
    }

    // MARK: Actions

    @objc private func primaryClicked() {
        switch mode {
        case .create:
            let password = passwordField.stringValue
            let confirm = confirmField.stringValue
            guard CredentialVaultPasswordStrength.evaluate(password) != .tooShort else {
                showMessage("Use at least \(CredentialVaultPasswordStrength.minimumLength) characters.")
                window?.makeFirstResponder(passwordField)
                return
            }
            guard password == confirm else {
                showMessage("The two passwords don't match.")
                window?.makeFirstResponder(confirmField)
                return
            }
            guard savedItRow.isOn else {
                showMessage("Write your master password down first, then tick the box. "
                            + "There is no way to recover it later.", tint: .warn)
                return
            }
            onCreate?(password)
        case .unlock:
            guard !usingRecoveryKey else {
                let code = recoveryField.stringValue
                guard CredentialVaultRecovery.looksWellFormed(code) else {
                    // Said before a derivation runs, because an obviously
                    // short code is a transcription slip rather than a wrong
                    // key - and letting it through would burn a real attempt
                    // against the throttle.
                    showMessage("A recovery key is \(CredentialVaultRecovery.codeCharacterCount) letters and digits - "
                                + "check the sheet and try again.")
                    window?.makeFirstResponder(recoveryField)
                    return
                }
                onUnlockWithRecoveryKey?(code)
                return
            }
            let password = passwordField.stringValue
            guard !password.isEmpty else {
                window?.makeFirstResponder(passwordField)
                NSSound.beep()
                return
            }
            onUnlock?(password)
        case .unreadable:
            break
        }
    }

    @objc private func touchIDClicked() { onUnlockWithTouchID?() }

    // MARK: F17 - the recovery door

    @objc private func recoveryLinkClicked() {
        usingRecoveryKey.toggle()
        applyRecoveryMode()
        window?.makeFirstResponder(usingRecoveryKey ? recoveryField : passwordField)
    }

    /// Swap the field and the wording. Both directions in one function, so
    /// the two states cannot drift - and so backing out of the recovery door
    /// really does restore the ordinary one.
    private func applyRecoveryMode() {
        recoveryLinkButton.isHidden = !recoveryAvailable
        guard recoveryAvailable else {
            recoveryField.isHidden = true
            passwordField.isHidden = false
            return
        }
        recoveryField.isHidden = !usingRecoveryKey
        passwordField.isHidden = usingRecoveryKey
        if usingRecoveryKey {
            subtitleLabel.stringValue = "Type the recovery key from the sheet you printed. "
                + "Spaces and dashes do not matter, and O reads as 0."
            primaryButton.title = "Unlock with the recovery key"
            recoveryLinkButton.title = "Use the master password instead"
            recoveryLinkButton.symbolName = "key.fill"
            // Touch ID holds the key derived from the *password*; offering it
            // beside the recovery door would be a third answer to a question
            // the captain has already answered.
            orLabel.isHidden = true
            touchIDButton.isHidden = true
        } else {
            subtitleLabel.stringValue = "Enter your master password to unlock."
            primaryButton.title = "Unlock"
            recoveryLinkButton.title = "Use a recovery key"
            recoveryLinkButton.symbolName = "shield.lefthalf.filled"
            if case .unlock(let touchIDAvailable, _) = mode {
                orLabel.isHidden = !touchIDAvailable
                touchIDButton.isHidden = !touchIDAvailable
            }
        }
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        orLabel.textColor = HelmTheme.mutedInk(theme)
        orLabel.font = HelmType.caption()
        iconTile.applyTheme(theme)
        infoLabel.textColor = HelmTheme.mutedInk(theme)
        if let infoCard {
            HelmCard.applyCardSurface(to: infoCard, theme: theme, cornerRadius: HelmMetrics.rRow)
        }
        // UX8's warning wears the app's own "this matters" surface rather than
        // a plain card, and its text goes through `CredentialVaultInk` like
        // every other tinted string on this page - a tinted hue is safe as a
        // fill and is NOT automatically safe as text (AGENTS.md's colour
        // rules), and `FM_RUN_CONTRAST_TESTS` sweeps every theme.
        if let recoveryWarningCard {
            recoveryWarningCard.wantsLayer = true
            recoveryWarningCard.layer?.cornerRadius = HelmMetrics.rRow
            // `HelmContrast.tintedSurface` resolves the wash and the label
            // *together*, which is the whole point: AGENTS.md's colour rule is
            // that a `HelmTint` hue is safe as a fill and is NOT automatically
            // safe as text, and this is the component that settles both at
            // once rather than leaving the label to be guessed at.
            // `FM_RUN_CONTRAST_TESTS` sweeps every theme against the floor.
            let resolved = HelmContrast.tintedSurface(tintHex: HelmTint.warn.hex(in: theme),
                                                      theme: theme,
                                                      target: HelmContrast.textTarget)
            recoveryWarningCard.layer?.backgroundColor = resolved.fill.cgColor
            recoveryWarningLabel.textColor = resolved.foreground
        }
        savedItRow.applyTheme(theme)
        if !messageLabel.stringValue.isEmpty {
            // Re-resolve against the new theme rather than leaving a colour
            // computed against the previous one - the staleness class
            // `VaultController.recipeDetailLabel` was corrected for.
            messageLabel.textColor = CredentialVaultInk.text(.critical, in: theme)
        }
        updateStrength()
    }
}

extension CredentialVaultUnlockView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateStrength()
    }
}
