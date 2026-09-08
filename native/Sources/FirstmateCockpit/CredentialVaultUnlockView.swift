// Manjesh Grand Line - native macOS app.
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
        case unlock(touchIDAvailable: Bool)
        case unreadable(reason: String, backupPath: String?)
    }

    /// Create a new vault with this password. The controller does the work.
    var onCreate: ((String) -> Void)?
    var onUnlock: ((String) -> Void)?
    var onUnlockWithTouchID: (() -> Void)?

    private let card = HelmCard()
    private let iconTile = IconTileView(size: HelmMetrics.tileLarge, cornerRadius: 12)
    private let titleLabel = NSTextField(labelWithString: "Poneglyph")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let passwordField = HelmSecureTextField(placeholder: "Master password")
    private let confirmField = HelmSecureTextField(placeholder: "Confirm master password")
    private let strengthLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = HelmButton(title: "Unlock", variant: .primary)
    private let touchIDButton = HelmButton(title: "Unlock with Touch ID", variant: .secondary, symbol: "touchid")
    private let orLabel = NSTextField(labelWithString: "or")
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

        titleLabel.font = HelmType.pageTitle(.serif)
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
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.keyEquivalent = "\r"
        touchIDButton.target = self
        touchIDButton.action = #selector(touchIDClicked)

        let orRow = NSStackView(views: [orLabel])
        orRow.orientation = .horizontal
        orRow.alignment = .centerY

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s3
        column.translatesAutoresizingMaskIntoConstraints = false
        for view in [iconTile, titleLabel, subtitleLabel, passwordField, confirmField,
                     strengthLabel, messageLabel, primaryButton, orRow, touchIDButton] as [NSView] {
            column.addArrangedSubview(view)
        }
        // The two fields and the primary action fill the column's width; the
        // labels and the icon tile keep their own size. Without the width ties
        // a leading-aligned vertical stack leaves both fields at their
        // intrinsic width, which is narrower than the card.
        for view in [passwordField, confirmField, primaryButton, touchIDButton] as [NSView] {
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
            primaryButton.title = "Create Poneglyph"
            primaryButton.isHidden = false
            orLabel.isHidden = true
            touchIDButton.isHidden = true
            updateStrength()

        case .unlock(let touchIDAvailable):
            iconTile.configure(symbol: "lock.fill", tint: .accent)
            titleLabel.stringValue = "Poneglyph"
            subtitleLabel.stringValue = "Enter your master password to unlock."
            passwordField.isHidden = false
            passwordField.placeholderString = "Master password"
            confirmField.isHidden = true
            strengthLabel.isHidden = true
            primaryButton.title = "Unlock"
            primaryButton.isHidden = false
            orLabel.isHidden = !touchIDAvailable
            touchIDButton.isHidden = !touchIDAvailable

        case .unreadable(let reason, let backupPath):
            iconTile.configure(symbol: "exclamationmark.triangle.fill", tint: .critical)
            titleLabel.stringValue = "Poneglyph unavailable"
            subtitleLabel.stringValue = reason
            passwordField.isHidden = true
            confirmField.isHidden = true
            strengthLabel.isHidden = true
            // Deliberately no primary action. See this file's header: offering
            // "create a new vault" here is how real credentials get destroyed.
            primaryButton.isHidden = true
            orLabel.isHidden = true
            touchIDButton.isHidden = true
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
            return
        }
        let strength = CredentialVaultPasswordStrength.evaluate(password)
        strengthLabel.stringValue = "Strength: \(strength.label)"
        strengthLabel.textColor = CredentialVaultInk.text(strength.tint, in: theme)
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
            onCreate?(password)
        case .unlock:
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
