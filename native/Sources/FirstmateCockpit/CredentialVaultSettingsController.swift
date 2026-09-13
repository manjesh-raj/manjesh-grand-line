// Manjesh Grand Line - native macOS app.
//
// Poneglyph settings and the full audit log - the mockup's sixth screen.
//
// Four sections, in the mockup's own order: Locking, Clipboard, Backup & sync,
// Audit log. Everything here is a property of *this vault* rather than of the
// app, which is why it lives in `VaultSettings` inside the encrypted file
// rather than in `AppSettings`/`UserDefaults`: a fresh machine that restored the
// vault should restore how it is meant to behave along with it.
//
// **The audit log is read-only and values-free, by construction rather than by
// filtering here.** `VaultAuditEvent` has no field a secret value could travel
// in (see its own doc comment), so this screen cannot leak one however it
// renders. What it does show is every create/update/delete/reveal/copy/lock/
// unlock/sync event with its timestamp and its method - and reveal and copy as
// genuinely distinct kinds, which is the whole reason the log is worth keeping.

import AppKit

final class CredentialVaultSettingsController: NSViewController {

    /// Persisted by the caller, which owns the store.
    var onSettingsChanged: ((VaultSettings) -> Void)?
    var onSyncNow: (() -> Void)?
    var onChangeMasterPassword: ((String, String, @escaping (Result<Void, Error>) -> Void) -> Void)?
    /// `true` to turn Touch ID unlock on (storing the derived key), `false` to
    /// forget it. Returns whether it worked, so the toggle can spring back
    /// rather than lying about the state.
    var onSetTouchIDUnlock: ((Bool, @escaping (Result<Void, Error>) -> Void) -> Void)?

    private var settings: VaultSettings
    private let auditEvents: [VaultAuditEvent]
    private let syncSummary: String
    private let touchIDAvailable: Bool

    private let autoLockCard = HelmFieldCard(label: "Lock the vault after")
    private let clipboardCard = HelmFieldCard(label: "Clear clipboard after")
    // `HelmToggleRow` already builds and owns its own switch - it is a
    // self-contained control, not a label that needs an external toggle
    // handed to it via `trailing:`. A prior version of this row passed a
    // second, separate `HelmToggle` into `trailing:`, which rendered two
    // switches for one setting. `touchIDRow.isOn` (and its own `.toggle` for
    // the `isEnabled` gate) is the single source of truth.
    private var touchIDRow: HelmToggleRow!
    private let currentPasswordField = HelmSecureTextField(placeholder: "Current master password")
    private let newPasswordField = HelmSecureTextField(placeholder: "New master password")
    private let confirmPasswordField = HelmSecureTextField(placeholder: "Confirm new master password")
    private let passwordMessage = NSTextField(wrappingLabelWithString: "")
    private var form: HelmFormSheet!

    init(settings: VaultSettings,
         auditEvents: [VaultAuditEvent],
         syncSummary: String,
         touchIDAvailable: Bool) {
        self.settings = settings
        self.auditEvents = auditEvents
        self.syncSummary = syncSummary
        self.touchIDAvailable = touchIDAvailable
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let sheet = HelmFormSheet(title: "Poneglyph settings",
                                  scrolls: true,
                                  domainHue: RailDestination.poneglyph.domainHue)
        form = sheet
        view = sheet

        sheet.addSection("Locking", number: "01")
        autoLockCard.configureChoices(VaultSettings.autoLockChoices.map(VaultSettings.autoLockLabel),
                                      selectedIndex: VaultSettings.autoLockChoices.firstIndex(of: settings.autoLockSeconds) ?? 1) { [weak self] index in
            guard let self, VaultSettings.autoLockChoices.indices.contains(index) else { return }
            self.settings.autoLockSeconds = VaultSettings.autoLockChoices[index]
            self.onSettingsChanged?(self.settings)
        }
        sheet.addRow(autoLockCard)

        let touchIDRow = HelmToggleRow(
            title: "Unlock with Touch ID",
            subtitle: touchIDAvailable
                ? "Stores your derived key - never your password - in this Mac's Keychain, for this device only. It does not travel to another machine, so the first unlock there is always your password."
                : "This Mac has no biometry available.")
        touchIDRow.isOn = settings.touchIDUnlockEnabled
        touchIDRow.toggle.isEnabled = touchIDAvailable
        touchIDRow.onToggle = { [weak self] in self?.touchIDToggled() }
        self.touchIDRow = touchIDRow
        sheet.addRow(touchIDRow)

        sheet.addSection("Clipboard", number: "02")
        clipboardCard.configureChoices(VaultSettings.clipboardChoices.map(VaultSettings.clipboardLabel),
                                       selectedIndex: VaultSettings.clipboardChoices.firstIndex(of: settings.clipboardClearSeconds) ?? 1) { [weak self] index in
            guard let self, VaultSettings.clipboardChoices.indices.contains(index) else { return }
            self.settings.clipboardClearSeconds = VaultSettings.clipboardChoices[index]
            self.onSettingsChanged?(self.settings)
        }
        sheet.addRow(clipboardCard)
        _ = sheet.addCaption("Never clears something you copied from somewhere else afterward - Grand Line checks that the clipboard is still the value it put there before clearing anything.")

        sheet.addSection("Backup & sync", number: "03")
        let syncButton = HelmButton(title: "Sync now", variant: .secondary, symbol: "arrow.triangle.2.circlepath",
                                    target: self, action: #selector(syncNowClicked))
        let syncLabel = NSTextField(wrappingLabelWithString: syncSummary)
        syncLabel.font = HelmType.caption()
        let syncRow = NSStackView(views: [syncLabel, syncButton])
        syncRow.orientation = .horizontal
        syncRow.alignment = .centerY
        syncRow.spacing = HelmMetrics.s3
        syncRow.distribution = .fill
        syncButton.setContentHuggingPriority(.required, for: .horizontal)
        syncButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        syncLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sheet.addRow(syncRow)

        sheet.addSection("Master password", number: "04")
        _ = sheet.addInfoCard(symbol: "key.fill",
                              text: "Changing it re-encrypts every credential under a new key. Your old password stops working immediately, and any Touch ID key on this Mac is forgotten because it can no longer open anything.")
        // L3 (end-to-end review): the re-key is all-or-nothing for the file on
        // disk, but the vault is committed and pushed to `manjesh-config` on
        // every change - so **every earlier commit still holds the old
        // ciphertext under the old key**, and rewriting that history is not
        // something this button can offer. A captain rotating "because it may
        // have leaked" is therefore protecting future writes only, which is
        // exactly the case where they most need to know it. Said here, next to
        // the action, rather than left to be inferred from the sync section
        // three sections up.
        _ = sheet.addInfoCard(symbol: "exclamationmark.triangle.fill",
                              text: "If you think this password may have leaked, rotate the underlying secrets too. Earlier commits in your config repo still hold the old encrypted vault, and the old password still opens those - changing it here protects everything written from now on, not what is already in that history.")
        sheet.addRow(currentPasswordField)
        sheet.addRow(newPasswordField)
        sheet.addRow(confirmPasswordField)
        let changeButton = HelmButton(title: "Change master password", variant: .secondary,
                                      target: self, action: #selector(changePasswordClicked))
        sheet.addRow(changeButton)
        passwordMessage.font = HelmType.caption()
        passwordMessage.isHidden = true
        sheet.addRow(passwordMessage)

        sheet.addSection("Audit log", number: "05")
        if auditEvents.isEmpty {
            _ = sheet.addCaption("Nothing recorded yet.")
        } else {
            let shown = auditEvents.sorted { $0.at > $1.at }.prefix(Self.maxShownEvents)
            for event in shown {
                sheet.addRow(auditRow(event))
            }
            if auditEvents.count > Self.maxShownEvents {
                // "No silent caps": say what is not on screen.
                _ = sheet.addCaption("Showing the \(Self.maxShownEvents) most recent of \(auditEvents.count) events. The vault keeps up to \(CredentialVaultStore.maxAuditEvents).")
            }
        }

        sheet.setFooter(target: self,
                        confirmTitle: "Done",
                        confirm: #selector(closeClicked),
                        cancel: #selector(closeClicked),
                        // Every control here applies as it is changed, so there
                        // is nothing for Return to "save" - saying otherwise
                        // would be the wrong shortcut hint.
                        hint: "Changes apply as you make them")
        sheet.refreshTheme()
    }

    private static let maxShownEvents = 60

    private func auditRow(_ event: VaultAuditEvent) -> NSView {
        let theme = ThemeManager.shared.theme
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: event.kind.symbol, accessibilityDescription: event.summary)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        glyph.contentTintColor = CredentialVaultInk.text(event.kind.tint, in: theme)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.widthAnchor.constraint(equalToConstant: 16).isActive = true

        var summary = event.summary
        if let detail = event.detail, !detail.isEmpty { summary += " \u{00B7} \(detail)" }
        let text = NSTextField(labelWithString: summary)
        text.font = HelmType.caption()
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let when = NSTextField(labelWithString: CredentialVaultFormat.relative(event.at))
        when.font = HelmType.captionSmall()
        when.textColor = HelmTheme.mutedInk(theme)
        when.toolTip = CredentialVaultFormat.absolute(event.at)
        when.setContentHuggingPriority(.required, for: .horizontal)
        when.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [glyph, text, when])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        row.distribution = .fill
        return row
    }

    // MARK: Actions

    private func touchIDToggled() {
        let wanted = touchIDRow.isOn
        onSetTouchIDUnlock?(wanted) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.settings.touchIDUnlockEnabled = wanted
            case .failure(let error):
                // Spring back rather than showing a state that isn't real.
                self.touchIDRow.isOn = !wanted
                self.showPasswordMessage(error.localizedDescription, tint: .critical)
            }
        }
    }

    @objc private func syncNowClicked() { onSyncNow?() }

    @objc private func changePasswordClicked() {
        let current = currentPasswordField.stringValue
        let new = newPasswordField.stringValue
        let confirm = confirmPasswordField.stringValue
        guard !current.isEmpty else {
            showPasswordMessage("Enter your current master password.", tint: .critical)
            return
        }
        guard CredentialVaultPasswordStrength.evaluate(new) != .tooShort else {
            showPasswordMessage("The new password needs at least \(CredentialVaultPasswordStrength.minimumLength) characters.", tint: .critical)
            return
        }
        guard new == confirm else {
            showPasswordMessage("The two new passwords don't match.", tint: .critical)
            return
        }
        showPasswordMessage("Re-encrypting\u{2026}", tint: .neutral)
        onChangeMasterPassword?(current, new) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.currentPasswordField.stringValue = ""
                self.newPasswordField.stringValue = ""
                self.confirmPasswordField.stringValue = ""
                self.touchIDRow.isOn = false
                self.showPasswordMessage("Master password changed. Every credential is now encrypted under the new key.", tint: .good)
            case .failure(let error):
                self.showPasswordMessage(error.localizedDescription, tint: .critical)
            }
        }
    }

    private func showPasswordMessage(_ text: String, tint: HelmTint) {
        passwordMessage.stringValue = text
        passwordMessage.isHidden = text.isEmpty
        passwordMessage.textColor = CredentialVaultInk.text(tint, in: ThemeManager.shared.theme)
    }

    @objc private func closeClicked() {
        if presentingViewController != nil {
            dismiss(self)
        } else {
            view.window?.close()
        }
    }

    #if FM_SELFTESTS
    var debugTouchIDRow: HelmToggleRow { touchIDRow }
    var debugCurrentPasswordField: HelmSecureTextField { currentPasswordField }
    var debugNewPasswordField: HelmSecureTextField { newPasswordField }
    var debugConfirmPasswordField: HelmSecureTextField { confirmPasswordField }
    var debugPasswordMessage: String { passwordMessage.stringValue }
    func debugChangePassword() { changePasswordClicked() }
    var debugSettings: VaultSettings { settings }
    #endif
}
