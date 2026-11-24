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
//
// **The unlock state is a treasure chest** (`fm/grandline-login-lamp-design-scout`,
// board design S-1 with card style V-4 Open). While the chest is shut the page
// is dark and the form is not there; opening it brings in a cardless form: a
// gold avatar, a pill field with an arrow inside it, and a round Touch ID
// button. `VaultChestScene` draws the chest. Four rules hold whatever the
// chest is doing:
//
//   * Typing always works. The form is hidden by alpha, never `isHidden`, so
//     the password field stays first responder, and any key opens the chest
//     (a local key-down monitor that returns every event unchanged).
//   * The padlock is a Touch ID button whenever Touch ID can open the vault,
//     shut chest or not, so the chest never stands between the captain and it.
//   * Nothing is ever said in an invisible form: a message or a busy state
//     opens the chest first.
//   * Only `.unlock` has a chest. Creating a vault and the unreadable state
//     keep the card exactly as it was.
//
// Reduce Motion and VoiceOver start with the chest open, and tapping the
// chest again closes it only while the field is empty.

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
    private let titleLabel = NSTextField(labelWithString: CredentialVaultUnlockView.pageName)
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let passwordField = HelmSecureTextField(placeholder: "Master password")
    private let confirmField = HelmSecureTextField(placeholder: "Confirm master password")
    /// **Review bug B11.** A plain `labelWithString` here truncated with no
    /// ellipsis at every window width: the hint it carries before a password
    /// is typed ("At least 10 characters. A long passphrase beats a short
    /// complicated one.") needs 412pt and the 420pt-capped card gives it 376.
    /// Measured on this branch, identical at 1512pt and 1100pt - the card is
    /// capped, so the window's width never mattered. It alternates with a
    /// short verdict ("Strength: Fair"), which is why nobody noticed: the
    /// state that truncates is the one before the captain has typed anything.
    private let strengthLabel = NSTextField(wrappingLabelWithString: "")
    /// Review #3's UX8: "a password manager owes the user that sentence at
    /// *creation* time ('There is no recovery. Write this down.'), plus a
    /// strength meter and a 'confirm you saved it' step."
    ///
    /// The sentence already existed - as the tail of a five-clause subtitle
    /// paragraph, which is exactly where a reader's eye does not go. It is its
    /// own tinted card now, above the fields rather than below them, because
    /// the one moment it changes behaviour is *before* the captain has chosen
    /// a password rather than after.
    ///
    /// R4-UX-02 of the fourth full review: the sentence used to say "There is
    /// no recovery", on the same page whose toolbar offers a recovery kit
    /// (F17). Both cannot be true. What is true is that the *password* cannot
    /// be reset by anyone, and that a printed recovery key - a second wrap of
    /// the same vault key, see `CredentialVaultRecovery` - is the one other
    /// way in. So the warning says that, and the step it points at is
    /// `printRecoveryKitRow` just below.
    private var recoveryWarningCard: NSView?
    private let recoveryWarningLabel = NSTextField(wrappingLabelWithString:
        "Forget this password and the vault stays sealed, unless you print the recovery key now. "
        + "Grand Line cannot reset the password, and neither can anyone else. "
        + "Write it down somewhere safe before you continue.")
    /// The meter half. The label alone said "Strength: Fair", which is a
    /// verdict rather than a meter - this is the same `HelmProgressBar` the
    /// Hosts keychain card already uses, so the app draws one bar, not two.
    private let strengthBar = HelmProgressBar()
    /// The "confirm you saved it" step. The create button is disabled until
    /// this is on.
    private let savedItRow = HelmToggleRow(
        title: "I have written my master password down somewhere safe")
    /// R4-UX-02: the recovery step, offered at creation. On by default and
    /// never a gate - a captain may still decline it - because the moment a
    /// vault is created is the one moment a printed key is free to make. It
    /// asks nothing of this view: the controller opens the existing recovery
    /// kit (`CredentialVaultRecoverySheetController`) once the vault exists
    /// and is unlocked, so the code is minted, shown and copied by the same
    /// concealed paths the toolbar's button already uses.
    private let printRecoveryKitRow = HelmToggleRow(
        title: "Print a recovery key next",
        subtitle: "Opens the recovery kit as soon as the vault exists.")
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

    // MARK: The chest (S-1) and the open form (V-4)

    private let chest = VaultChestScene()
    /// Holds the card. While the chest is shut it is transparent and refuses
    /// clicks, and it is never `isHidden` (typing-first, see the header).
    private let formHost = VaultGateHost()
    private let goldAvatar = VaultGoldAvatarView()
    /// The password field with the arrow inside it, and the round Touch ID
    /// button beside it. In the create state it is just the field.
    private let passwordRow = NSStackView()
    private let passwordWell = NSView()
    private let arrowButton = HelmIconButton(symbol: "arrow.right", label: "Unlock")
    private let touchRoundButton = HelmIconButton(symbol: "touchid", label: "Unlock with Touch ID")
    /// The field's own surface, for every state but the open form.
    private var classicWellSurface: HelmField.Surface = .inset
    /// The unlock state draws the chest and the open form.
    private var openStyle = false
    private var isLit = true
    private var touchIDAvailable = false
    private var keyMonitor: Any?
    private var cardCap: NSLayoutConstraint!
    private var cardMax: NSLayoutConstraint!
    private var classicCentreX: NSLayoutConstraint!
    private var sideCentreX: NSLayoutConstraint!
    private var formCentreY: NSLayoutConstraint!
    private var layoutMode: VaultChestScene.Layout = .side

    /// The open form's column, as the board's `.vform { width: 300px }`.
    static let openFormWidth: CGFloat = 300
    /// Side by side from this width; the chest sits under the form below it.
    static let sideLayoutMinimumWidth: CGFloat = 900
    /// Centre to centre, chest to form, side by side (the board's 330 and 850).
    static let sideSeparation: CGFloat = 520

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        classicWellSurface = passwordField.wellSurface

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

        // V-4: the arrow sits inside the pill, and the round Touch ID button
        // beside it. Both are hidden outside the unlock state, where the row is
        // just the field at the column's width.
        passwordWell.translatesAutoresizingMaskIntoConstraints = false
        passwordWell.addSubview(passwordField)
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        arrowButton.target = self
        arrowButton.action = #selector(primaryClicked)
        arrowButton.isHidden = true
        passwordWell.addSubview(arrowButton)
        NSLayoutConstraint.activate([
            passwordField.leadingAnchor.constraint(equalTo: passwordWell.leadingAnchor),
            passwordField.trailingAnchor.constraint(equalTo: passwordWell.trailingAnchor),
            passwordField.topAnchor.constraint(equalTo: passwordWell.topAnchor),
            passwordField.bottomAnchor.constraint(equalTo: passwordWell.bottomAnchor),
            arrowButton.trailingAnchor.constraint(equalTo: passwordWell.trailingAnchor, constant: -4),
            arrowButton.centerYAnchor.constraint(equalTo: passwordWell.centerYAnchor),
        ])
        touchRoundButton.target = self
        touchRoundButton.action = #selector(touchIDClicked)
        touchRoundButton.isHidden = true
        touchRoundButton.setContentHuggingPriority(.required, for: .horizontal)
        touchRoundButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        passwordRow.orientation = .horizontal
        passwordRow.alignment = .centerY
        passwordRow.distribution = .fill
        passwordRow.spacing = 10
        passwordRow.translatesAutoresizingMaskIntoConstraints = false
        passwordRow.addArrangedSubview(passwordWell)
        passwordRow.addArrangedSubview(touchRoundButton)
        goldAvatar.isHidden = true

        // Order matters: the warning sits **above** the fields. The one moment
        // "there is no recovery" changes what a captain does is before they
        // choose a password, not after.
        for view in [goldAvatar, iconTile, titleLabel, subtitleLabel, warningCard, passwordRow, recoveryField, confirmField,
                     strengthBar, strengthLabel, savedItRow, printRecoveryKitRow, messageLabel,
                     primaryButton, orRow, touchIDButton, recoveryLinkButton] as [NSView] {
            column.addArrangedSubview(view)
        }
        for view in [warningCard, strengthBar, savedItRow, printRecoveryKitRow] as [NSView] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        strengthBar.heightAnchor.constraint(equalToConstant: HelmProgressBar.height).isActive = true
        // The two fields and the primary action fill the column's width; the
        // labels and the icon tile keep their own size. Without the width ties
        // a leading-aligned vertical stack leaves both fields at their
        // intrinsic width, which is narrower than the card.
        for view in [passwordRow, recoveryField, confirmField, primaryButton, touchIDButton] as [NSView] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        subtitleLabel.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        messageLabel.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        // B11: a wrapping label in a leading-aligned vertical stack has no
        // width Auto Layout is obliged to give it, so it needs the same tie
        // the two labels above already have - see `HelmEmptyState`'s own note
        // on the "No / sa" failure this shape produces without one.
        strengthLabel.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        card.setBody(column, insets: NSEdgeInsets(top: HelmMetrics.s5, left: HelmMetrics.s5,
                                                  bottom: HelmMetrics.s5, right: HelmMetrics.s5))
        card.translatesAutoresizingMaskIntoConstraints = false
        // The chest's back below the form and its front above it, so in the
        // stacked layout the form rises out of the chest (see `VaultChestScene`).
        formHost.translatesAutoresizingMaskIntoConstraints = false
        formHost.wantsLayer = true
        formHost.addSubview(card)
        for view in [chest.backView, formHost, chest.frontView] { addSubview(view) }
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: formHost.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: formHost.trailingAnchor),
            card.topAnchor.constraint(equalTo: formHost.topAnchor),
            card.bottomAnchor.constraint(equalTo: formHost.bottomAnchor),
        ])
        for view in [chest.backView, chest.frontView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            view.isHidden = true
        }
        chest.chestHotspot.onClick = { [weak self] in self?.chestClicked() }
        chest.chestHotspot.onHover = { [weak self] on in
            guard let self, self.openStyle else { return }
            self.chest.setHovering(on && !self.isLit)
        }
        chest.padlockHotspot.onClick = { [weak self] in self?.padlockClicked() }

        // Centred, capped, and - per AGENTS.md's host-editor gotcha (3) -
        // positioned with inequalities plus a `centerX` tie rather than a
        // required width equality, which would make the whole window snap back
        // to the one width where that equality has zero slack.
        let cap = card.widthAnchor.constraint(equalToConstant: 420)
        cap.priority = HelmDaylightPriority.contentTie
        // S03: centred, but never above the page frame's first-content line.
        // The setup card is tall, and centred in a 950pt window it rose to
        // 86pt from the window's top, 10pt above every other page's first
        // content and nearly touching the header line (measured). The centre
        // gives way first, and it sits below the window's 500 (gotcha (13)):
        // at 750 the centre held at 750 grew a short window to keep the
        // tall card centred under the floor (measured, 722 to 731pt).
        let centred = formHost.centerYAnchor.constraint(equalTo: centerYAnchor)
        centred.priority = NSLayoutConstraint.Priority(490)
        let maxWidth = card.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        // Side by side, the form sits right of centre. Below the window's 500
        // (gotcha (13)), so a narrow page moves the form in rather than
        // growing the window to keep it there.
        let sideX = formHost.centerXAnchor.constraint(equalTo: centerXAnchor, constant: Self.sideSeparation / 2)
        sideX.priority = NSLayoutConstraint.Priority(490)
        let classicX = formHost.centerXAnchor.constraint(equalTo: centerXAnchor)
        NSLayoutConstraint.activate([
            classicX,
            centred,
            formHost.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: HelmMetrics.pageContentInset),
            formHost.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: HelmMetrics.pageGutter),
            formHost.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.pageGutter),
            maxWidth,
            cap,
        ])
        cardCap = cap
        cardMax = maxWidth
        classicCentreX = classicX
        sideCentreX = sideX
        formCentreY = centred

        setMode(.create)
    }

    // MARK: Mode

    func setMode(_ mode: Mode) {
        self.mode = mode
        let wasOpenStyle = openStyle
        if case .unlock = mode { openStyle = true } else { openStyle = false }
        messageLabel.stringValue = ""
        messageLabel.isHidden = true
        infoCard?.isHidden = true

        switch mode {
        case .create:
            iconTile.configure(symbol: "lock.shield.fill", tint: .accent)
            titleLabel.stringValue = "Set up your vault"
            subtitleLabel.stringValue = "Choose a master password. It encrypts every credential you store here, and it is never saved anywhere - not on disk, not in the Keychain, not in the vault file. Nobody can reset it for you."
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
            printRecoveryKitRow.isHidden = false
            printRecoveryKitRow.isOn = true
            primaryButton.title = Self.createTitle
            primaryButton.isHidden = false
            orLabel.isHidden = true
            touchIDButton.isHidden = true
            recoveryLinkButton.isHidden = true
            recoveryField.isHidden = true
            usingRecoveryKey = false
            updateStrength()

        case .unlock(let touchIDAvailable, let recoveryAvailable):
            self.touchIDAvailable = touchIDAvailable
            self.recoveryAvailable = recoveryAvailable
            self.usingRecoveryKey = false
            recoveryField.stringValue = ""
            iconTile.configure(symbol: "lock.fill", tint: .accent)
            titleLabel.stringValue = Self.pageName
            subtitleLabel.stringValue = "Enter your master password to unlock."
            passwordField.isHidden = false
            passwordField.placeholderString = "Master password"
            confirmField.isHidden = true
            strengthLabel.isHidden = true
            strengthBar.isHidden = true
            recoveryWarningCard?.isHidden = true
            savedItRow.isHidden = true
            printRecoveryKitRow.isHidden = true
            primaryButton.isEnabled = true
            primaryButton.title = "Unlock"
            primaryButton.isHidden = false
            orLabel.isHidden = !touchIDAvailable
            touchIDButton.isHidden = !touchIDAvailable
            applyRecoveryMode()

        case .unreadable(let reason, let backupPath):
            iconTile.configure(symbol: "exclamationmark.triangle.fill", tint: .critical)
            titleLabel.stringValue = "\(Self.pageName) unavailable"
            subtitleLabel.stringValue = reason
            passwordField.isHidden = true
            confirmField.isHidden = true
            strengthLabel.isHidden = true
            strengthBar.isHidden = true
            recoveryWarningCard?.isHidden = true
            savedItRow.isHidden = true
            printRecoveryKitRow.isHidden = true
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
        // A fresh gate starts with the chest shut. Re-rendering the same
        // unlock state (the page re-renders often) leaves it as it is.
        if openStyle && !wasOpenStyle {
            enterGate()
        } else if !openStyle {
            setLit(true)
        }
        updateKeyMonitor()
        needsLayout = true
    }

    /// Show a rejection or a failure. Never clears the password field for a
    /// wrong password - retyping a long passphrase because of one typo is a
    /// worse experience than leaving it to be corrected.
    func showMessage(_ text: String, tint: HelmTint = .critical) {
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
        messageLabel.textColor = CredentialVaultInk.text(tint, in: theme)
        // Nothing is said in an invisible form: the chest opens first. A
        // rejection while it is open jolts the lid instead.
        guard openStyle, !text.isEmpty else { return }
        if !isLit {
            openChest(.key)
        } else if tint == .critical {
            chest.jolt()
        }
    }

    /// R4-UX-02: whether the captain asked for the recovery kit to open once
    /// the vault they are creating exists.
    var wantsRecoveryKitAfterCreate: Bool { printRecoveryKitRow.isOn }

    func clearPasswordFields() {
        passwordField.stringValue = ""
        confirmField.stringValue = ""
        updateStrength()
    }

    /// R4-UI-07: the vault as the running layout names it - "Secrets" beside
    /// the sidebar's Secrets row and tab, "Poneglyph" in the floating bar,
    /// whose page is titled that. The card used to say "Poneglyph" under a
    /// "Work › Secrets" crumb.
    static var pageName: String { PlaceName.short(.poneglyph) }

    /// The create button. "Create Secrets" would read as making a secret, so
    /// the sidebar layout's says what the card's title already calls it.
    static var createTitle: String {
        PlaceName.layout == .floatingBar ? "Create \(pageName)" : "Create vault"
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugPasswordField: HelmSecureTextField { passwordField }
    var debugConfirmField: HelmSecureTextField { confirmField }
    /// UX8's "confirm you saved it" step, and the gate it drives.
    var debugSavedItRow: HelmToggleRow { savedItRow }
    var debugPrintRecoveryKitRow: HelmToggleRow { printRecoveryKitRow }
    var debugPrimaryButton: HelmButton { primaryButton }
    var debugRecoveryWarningText: String { recoveryWarningLabel.stringValue }
    var debugRecoveryWarningVisible: Bool { recoveryWarningCard?.isHidden == false }
    var debugStrengthBarVisible: Bool { !strengthBar.isHidden }
    /// Review bug B11: the two strings the review measured truncating at every
    /// window width. `fittingSize` is what the text needs; `frame` is what it
    /// got.
    var debugStrengthLabel: NSTextField { strengthLabel }
    var debugCard: NSView? { card }
    /// S-1 / V-4: the chest and the open form.
    var debugOpenStyle: Bool { openStyle }
    var debugIsLit: Bool { isLit }
    var debugFormHostAlpha: CGFloat { formHost.alphaValue }
    var debugFormHostInert: Bool { formHost.isInert }
    var debugFormHostIsHidden: Bool { formHost.isHidden }
    var debugChest: VaultChestScene { chest }
    var debugChestShown: Bool { !chest.backView.isHidden && !chest.frontView.isHidden }
    var debugArrowButton: HelmIconButton { arrowButton }
    var debugTouchRoundButton: HelmIconButton { touchRoundButton }
    var debugGoldAvatarShown: Bool { !goldAvatar.isHidden }
    var debugIconTileShown: Bool { !iconTile.isHidden }
    var debugKeyMonitorInstalled: Bool { keyMonitor != nil }
    var debugLayoutMode: VaultChestScene.Layout { layoutMode }
    var debugFormHostFrame: NSRect { formHost.frame }
    /// The chest's and the padlock's real click paths.
    func debugClickChest() { chest.chestHotspot.debugClick() }
    func debugClickPadlock() { chest.padlockHotspot.debugClick() }
    /// What the key monitor does with a key in this window.
    func debugKeyDown() { handleKeyDown() }
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
        arrowButton.isEnabled = !busy
        touchRoundButton.isEnabled = !busy
        // The rays pulse while the key is derived.
        chest.setChecking(busy && openStyle)
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
                            + "Nobody can reset it later.", tint: .warn)
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
        syncOpenControls()
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
        printRecoveryKitRow.applyTheme(theme)
        if !messageLabel.stringValue.isEmpty {
            // Re-resolve against the new theme rather than leaving a colour
            // computed against the previous one - the staleness class
            // `VaultController.recipeDetailLabel` was corrected for.
            messageLabel.textColor = CredentialVaultInk.text(.critical, in: theme)
        }
        updateStrength()
        applyOpenStyle()
    }

    // MARK: V-4 Open

    /// Restyles the card for the open form in the unlock state, and back to
    /// the card everywhere else. Called from `applyTheme`, so it repaints on a
    /// theme change and never fetches (GL-24).
    private func applyOpenStyle() {
        let open = openStyle
        chest.backView.isHidden = !open
        chest.frontView.isHidden = !open
        goldAvatar.isHidden = !open
        iconTile.isHidden = open
        column.alignment = open ? .centerX : .leading
        for label in [titleLabel, subtitleLabel, messageLabel] { label.alignment = open ? .center : .natural }
        // The open form is the board's 300pt column; the card keeps 420.
        let width = open ? Self.openFormWidth + 2 * HelmMetrics.s5 : 420
        cardCap.constant = width
        cardMax.constant = width
        passwordField.wellSurface = open ? .scene(onDark: theme.mode == .dark) : classicWellSurface
        passwordField.applyTheme(theme)
        syncOpenControls()
        guard open else { return }
        chest.applyTheme(theme, touchID: touchIDAvailable)
        goldAvatar.applyTheme()
        HelmMotion.withoutImplicitAnimation {
            card.layer?.backgroundColor = NSColor.clear.cgColor
            card.layer?.borderWidth = 0
            card.layer?.shadowOpacity = 0
        }
        let accent = HelmTheme.nsColor(theme.accentHex)
        let onAccent = HelmContrast.legible(
            HelmTheme.nsColor(theme.mode == .dark ? theme.backgroundHex : theme.chromeBackgroundHex), over: accent)
        arrowButton.style = .circle(side: HelmField.controlHeight - 8, fill: accent, glyph: onAccent, border: nil)
        touchRoundButton.style = .circle(side: HelmField.controlHeight, fill: HelmTheme.nsColor(theme.chromeBackgroundHex),
                                         glyph: HelmTheme.nsColor(theme.chromeInkHex),
                                         border: HelmTheme.nsColor(theme.chromeLineHex))
    }

    /// Which of the open form's controls show. The Unlock button only comes
    /// back for the recovery door, whose field has no arrow of its own.
    private func syncOpenControls() {
        passwordRow.isHidden = passwordField.isHidden
        let open = openStyle
        arrowButton.isHidden = !open || usingRecoveryKey
        touchRoundButton.isHidden = !open || usingRecoveryKey || !touchIDAvailable
        passwordField.trailingAccessoryWidth = arrowButton.isHidden ? 0 : HelmField.controlHeight - 2
        guard open else { return }
        primaryButton.isHidden = !usingRecoveryKey
        orLabel.isHidden = true
        touchIDButton.isHidden = true
    }

    // MARK: Layout

    override func layout() {
        let side = bounds.width >= Self.sideLayoutMinimumWidth
        layoutMode = side ? .side : .stacked
        let sideBySide = openStyle && side
        if classicCentreX.isActive == sideBySide {
            classicCentreX.isActive = !sideBySide
            sideCentreX.isActive = sideBySide
        }
        // Stacked, the form rises above the chest, so the pair is centred
        // rather than the form alone.
        formCentreY.constant = openStyle && !side ? -(VaultChestScene.stackedLift) : 0
        super.layout()
        guard openStyle else { return }
        let form = formHost.frame
        let half = VaultChestArt.groupSize.width / 2
        let topLeft = side
            ? CGPoint(x: form.midX - Self.sideSeparation - half, y: form.midY)
            : CGPoint(x: form.midX - half, y: form.minY - 6)
        chest.layout(bounds: bounds, chestTopLeft: topLeft, layout: layoutMode,
                     formCentre: CGPoint(x: form.midX, y: form.midY))
    }

    // MARK: The chest

    enum LightSource { case pointer, key }

    /// Reduce Motion and VoiceOver start open: there is nothing to work out.
    private static var startsLit: Bool { HelmMotion.isReduced || NSWorkspace.shared.isVoiceOverEnabled }

    private var activeField: NSTextField { usingRecoveryKey ? recoveryField : passwordField }

    /// A fresh gate: the chest shut, unless something is already typed or a
    /// check is running.
    private func enterGate() {
        setLit(Self.startsLit || !activeField.stringValue.isEmpty || !passwordField.isEnabled)
    }

    /// Open or shut at once, with no animation.
    private func setLit(_ lit: Bool) {
        isLit = lit
        formHost.layer?.removeAnimation(forKey: "gate")
        formHost.alphaValue = lit ? 1 : 0
        formHost.isInert = !lit
        guard openStyle else { return }
        if lit { chest.showOpen(reducedMotion: HelmMotion.isReduced) } else { chest.showShut() }
    }

    /// Opens the chest. From the pointer it is the full swing; from a key it
    /// is quick, because whoever is typing is already halfway through.
    func openChest(_ source: LightSource) {
        guard openStyle, !isLit else { return }
        isLit = true
        formHost.isInert = false
        let reduced = HelmMotion.isReduced
        chest.open(fast: source == .key, reducedMotion: reduced)
        revealForm(fast: source == .key, reduced: reduced)
    }

    /// "Tap again to close" never throws away a half-typed password or
    /// interrupts a check.
    private var canShut: Bool {
        openStyle && isLit && activeField.stringValue.isEmpty && passwordField.isEnabled && !Self.startsLit
    }

    func shutChest() {
        guard canShut else { return }
        isLit = false
        formHost.isInert = true
        hideForm()
        chest.shut()
    }

    private func chestClicked() {
        chest.setHovering(false)
        if isLit { shutChest() } else { openChest(.pointer) }
        window?.makeFirstResponder(activeField)
    }

    /// The padlock is the Touch ID button whenever Touch ID can open the
    /// vault, shut chest or not. Without it, it is part of the chest.
    private func padlockClicked() {
        guard touchIDAvailable, !usingRecoveryKey, passwordField.isEnabled else {
            chestClicked()
            return
        }
        openChest(.key)
        touchIDClicked()
    }

    /// What a key in this window does: opens a shut chest, or glints by the
    /// treasure in an open one.
    private func handleKeyDown() {
        guard openStyle, !isHiddenOrHasHiddenAncestor else { return }
        if isLit { chest.glint() } else { openChest(.key) }
    }

    /// The first key opens the chest. A local monitor needs no Accessibility
    /// grant, and it returns every event unchanged, so the field editor still
    /// gets every key, Return and Tab included.
    private func updateKeyMonitor() {
        let wanted = openStyle && window != nil
        if wanted, keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if let self, event.window === self.window { self.handleKeyDown() }
                return event
            }
        } else if !wanted, let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateKeyMonitor()
        if window == nil { chest.stopLoops() } else if openStyle { chest.startLoops() }
    }

    /// GL-13: nothing loops on a gate nobody can see. A gate shown again (the
    /// vault relocked, or the page revisited) starts shut again, unless
    /// something is typed in it.
    override func viewDidHide() {
        super.viewDidHide()
        chest.stopLoops()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        guard openStyle else { return }
        enterGate()
    }

    // MARK: The form's entrance

    /// A transform about the form's bottom centre (the board's
    /// `transform-origin: 50% 100%`), with CSS's y-down offsets.
    private func formTransform(dx: CGFloat, dy: CGFloat, scale: CGFloat) -> CATransform3D {
        guard let layer = formHost.layer else { return CATransform3DIdentity }
        let w = layer.bounds.width
        let anchor = CGPoint(x: layer.anchorPoint.x * w, y: layer.anchorPoint.y * layer.bounds.height)
        var t = CATransform3DMakeTranslation(anchor.x - w / 2, anchor.y, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(scale, scale, 1))
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(w / 2 - anchor.x + dx, -anchor.y - dy, 0))
        return t
    }

    private func revealForm(fast: Bool, reduced: Bool) {
        formHost.alphaValue = 1
        guard let layer = formHost.layer else { return }
        let animation: CAAnimation
        if reduced {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.22
            animation = fade
        } else if layoutMode == .side {
            // The light reaches the form and it comes up beside the chest.
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0
            opacity.toValue = 1
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: formTransform(dx: -26, dy: 0, scale: 0.97))
            move.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            let group = CAAnimationGroup()
            group.animations = [opacity, move]
            group.duration = fast ? 0.26 : 0.64
            group.beginTime = CACurrentMediaTime() + (fast ? 0.04 : 0.42)
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            animation = group
        } else {
            // Stacked, it rises out of the chest.
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 1, 1]
            let move = CAKeyframeAnimation(keyPath: "transform")
            move.values = [formTransform(dx: 0, dy: 250, scale: 0.55), formTransform(dx: 0, dy: 170, scale: 0.7),
                           formTransform(dx: 0, dy: -6, scale: 1.01), CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
            for keyframes in [opacity, move] { keyframes.keyTimes = [0, 0.2, 0.78, 1] }
            let group = CAAnimationGroup()
            group.animations = [opacity, move]
            group.duration = fast ? 0.32 : 0.76
            group.beginTime = CACurrentMediaTime() + (fast ? 0.06 : 0.36)
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
            animation = group
        }
        animation.fillMode = .backwards
        layer.add(animation, forKey: "gate")
    }

    private func hideForm() {
        formHost.alphaValue = 0
        guard let layer = formHost.layer else { return }
        let group = CAAnimationGroup()
        if layoutMode == .side {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 1
            opacity.toValue = 0
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            move.toValue = NSValue(caTransform3D: formTransform(dx: -26, dy: 0, scale: 0.97))
            group.animations = [opacity, move]
            group.duration = 0.38
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        } else {
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [1, 1, 0]
            let move = CAKeyframeAnimation(keyPath: "transform")
            move.values = [CATransform3DIdentity, formTransform(dx: 0, dy: -8, scale: 1),
                           formTransform(dx: 0, dy: 250, scale: 0.55)].map { NSValue(caTransform3D: $0) }
            for keyframes in [opacity, move] { keyframes.keyTimes = [0, 0.2, 1] }
            group.animations = [opacity, move]
            group.duration = 0.46
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.45)
        }
        layer.add(group, forKey: "gate")
    }
}

/// The open form's host. While the chest is shut it is transparent and
/// refuses clicks; it is never `isHidden`, because hiding the view that holds
/// the first responder moves first responder elsewhere.
private final class VaultGateHost: NSView {
    var isInert = false
    override func hitTest(_ point: NSPoint) -> NSView? { isInert ? nil : super.hitTest(point) }
}

/// V-4 Open's avatar: a gold, ringed coin with the vault's lock on it.
private final class VaultGoldAvatarView: NSView {
    static let side: CGFloat = 64
    private let gradient = CAGradientLayer()
    private let glyph = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = false
        layer?.cornerRadius = Self.side / 2
        layer?.borderWidth = 3
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        gradient.cornerRadius = Self.side / 2
        gradient.masksToBounds = true
        // The board's 135deg: light at the top left, deep at the bottom right.
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(gradient)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleNone
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        HelmMotion.withoutImplicitAnimation { gradient.frame = bounds }
    }

    /// The gold and its ring are the treasure's own paint, in every theme.
    func applyTheme() {
        HelmMotion.withoutImplicitAnimation {
            gradient.colors = [VaultChestArt.Avatar.top.cgColor, VaultChestArt.Avatar.bottom.cgColor]
            layer?.borderColor = VaultChestArt.Avatar.ring.cgColor
            layer?.shadowColor = VaultChestArt.Avatar.shadow.cgColor
        }
        glyph.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold))
        glyph.contentTintColor = VaultChestArt.Avatar.glyph
    }
}

extension CredentialVaultUnlockView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateStrength()
    }
}
