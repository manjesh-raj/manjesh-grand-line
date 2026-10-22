// Grand Line - native macOS app.
//
// The two cells Poneglyph's credential table needs beyond `HelmDataTable`'s
// own: the live 2FA code, and a row's Reveal and Copy.
//
// The sidebar layout draws Secrets › Poneglyph as the prototype's table
// (`CredentialVaultController`'s "The sidebar layout" extension). Both cells
// keep the list row's rules exactly, because they are the captain's own:
//
//   - **Reveal and Copy are separate, with their own icons.** Reveal shows the
//     value on the row and never touches the clipboard; Copy writes the
//     clipboard and never puts the value on screen ("I don't always want to
//     reveal when I copy, for example while screen sharing").
//   - **A 2FA code is read from `TOTPTicker.shared.now`**, the one clock every
//     surface that draws a code uses, and a click copies exactly the code on
//     screen.

import AppKit

/// The live 2FA code: the countdown ring and the code, which copies itself.
final class CredentialTOTPCell: NSView {
    private let ring = TOTPRingView()
    private let codeButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "doc.on.doc")
    var onCopy: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        codeButton.target = self
        codeButton.action = #selector(copyClicked)
        codeButton.setContentHuggingPriority(.required, for: .horizontal)
        codeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [ring, codeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = HelmMetrics.s1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The same reading `CredentialVaultListSection`'s row makes, from the
    /// same clock.
    func update(_ config: VaultTOTP, now: Date, theme: HelmTheme) {
        let remaining = TOTP.secondsRemaining(config, at: now)
        ring.fraction = TOTP.fractionRemaining(config, at: now)
        ring.secondsText = "\(remaining)"
        ring.applyTheme(theme, urgent: remaining <= 5)
        if let code = TOTP.code(config, at: now) {
            codeButton.title = TOTP.grouped(code)
            codeButton.isEnabled = true
            codeButton.toolTip = "Copy this 2FA code - it changes in \(remaining)s"
            ring.setAccessibilityLabel("Two-factor code expires in \(remaining) seconds")
        } else {
            codeButton.title = "Seed unreadable"
            codeButton.isEnabled = false
            codeButton.toolTip = "This credential's stored 2FA seed is not valid base32 - edit it to fix"
            ring.fraction = 0
            ring.secondsText = "!"
        }
    }

    @objc private func copyClicked() { onCopy?() }

    #if FM_SELFTESTS
    var debugCodeButton: HelmButton { codeButton }
    #endif
}

/// A credential row's always-visible controls: the Touch ID mark, Reveal and
/// Copy. A secure note has neither Reveal nor Copy - it is prose, read in the
/// inspector, never pasted.
final class CredentialRowControls: NSView {
    private let touchID = NSImageView()
    private let revealButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "eye")
    private let copyButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "doc.on.doc")
    private var reveal: (() -> Void)?
    private var copy: (() -> Void)?

    init(requiresTouchID: Bool, isRevealed: Bool,
         reveal: (() -> Void)?, copy: (() -> Void)?, theme: HelmTheme) {
        self.reveal = reveal
        self.copy = copy
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        touchID.image = HelmSymbol.image("touchid", pointSize: HelmType.scaled(11), weight: .semibold)
        touchID.imageScaling = .scaleProportionallyUpOrDown
        touchID.contentTintColor = HelmTheme.mutedInk(theme)
        touchID.toolTip = "Requires Touch ID to reveal"
        touchID.isHidden = !requiresTouchID
        revealButton.symbolName = isRevealed ? "eye.slash" : "eye"
        revealButton.tint = isRevealed ? .warn : nil
        revealButton.toolTip = isRevealed
            ? "Hide the value again (this never touched the clipboard)"
            : "Show the value on this row - does not copy it"
        revealButton.setAccessibilityLabel(isRevealed ? "Hide value" : "Reveal value")
        revealButton.isHidden = reveal == nil
        revealButton.target = self
        revealButton.action = #selector(revealClicked)
        copyButton.toolTip = "Copy the value to the clipboard - does not show it on screen"
        copyButton.setAccessibilityLabel("Copy value")
        copyButton.isHidden = copy == nil
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        for view in [touchID, revealButton, copyButton] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let stack = NSStackView(views: [touchID, revealButton, copyButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = HelmMetrics.s1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func revealClicked() { reveal?() }
    @objc private func copyClicked() { copy?() }

    #if FM_SELFTESTS
    var debugRevealButton: HelmButton? { revealButton.isHidden ? nil : revealButton }
    var debugCopyButton: HelmButton? { copyButton.isHidden ? nil : copyButton }
    var debugTouchIDShown: Bool { !touchID.isHidden }
    #endif
}
