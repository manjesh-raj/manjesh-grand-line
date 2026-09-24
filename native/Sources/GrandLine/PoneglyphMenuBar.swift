// Grand Line - native macOS app.
//
// F16's menu-bar quick-copy: a status item whose popover lists every
// credential with a 2FA seed, each with its live code and a countdown ring,
// so a code can be copied without raising the main window.
//
// **Shaped on `StrawHatMenuBarController` deliberately, not coincidentally.**
// The report's own wording is "a menu-bar quick-copy popover like Straw
// Hat's", and that controller (`StrawHatMenuBar.swift`) is itself modelled on
// `ShiftMenuBarController`. So this is the third instance of one established
// shape: an `NSStatusItem`, a `.transient` `NSPopover` whose content is a
// plain `NSViewController`, the same `AppLockGate` registration and lock
// observer, the same live `ThemeManager` observation, and the same
// `prepareToShow()` split so a suite can drive the real open path without a
// live status button.
//
// **It owns no store**, for the same reason Straw Hat's owns no runner:
// `CredentialVaultStore` caches, GL-23 says a caching store gets exactly one
// instance, and the one that exists belongs to `CredentialVaultController`.
// `codesProvider`/`onCopy` are wired by `AppDelegate` to
// `AppShellController`, which forwards into that page.
//
// ## What it will not show
//
//   * **Anything, while the app is locked.** `.poneglyphMenuBarPopover` is
//     its own `AppLockedSurface` case and the popover does not open at all -
//     not even empty. This is the strictest surface in the app to reason
//     about: a popover is its own window, layered *above* the lock overlay,
//     and what it would display is live authentication codes.
//   * **Anything, while the vault is locked.** Separately from the app lock:
//     an unlocked app with a locked vault gets a one-line "unlock Poneglyph"
//     state and a link into the page. Deriving a code needs the decrypted
//     seed, so there is nothing to show and nothing to leak.
//   * **A password.** The popover copies TOTP codes and nothing else. A code
//     is worth thirty seconds; a stored password is not, and a menu-bar
//     surface with no window and no Touch ID gate is the wrong place to hand
//     one out.

import AppKit

/// One row's worth of what the popover needs. A value type carrying no store
/// reference, so the page hands over a snapshot rather than a live object.
struct PoneglyphQuickCode: Equatable {
    let id: String
    let title: String
    let account: String
    let totp: VaultTOTP
}

final class PoneglyphMenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let content = PoneglyphMenuBarPopoverController()
    private var themeObservation: ThemeObservation?

    /// The rows to show, asked for on every open so a credential added since
    /// the last one appears. Wired to `AppShellController.poneglyphQuickCodes`.
    var codesProvider: (() -> [PoneglyphQuickCode])?
    /// Whether the vault itself is unlocked, which decides between the list
    /// and the "unlock Poneglyph" state.
    var vaultIsUnlocked: (() -> Bool)?
    /// Copy one row's current code. Returns the code copied, or nil.
    var onCopy: ((String) -> String?)?
    /// "Open Poneglyph" - `AppShellController.show(.poneglyph)`.
    var onOpenVault: (() -> Void)?

    override init() {
        super.init()
        // Audit 2 §2.7/§6.2: a popover is its own window above the lock
        // overlay, so it must be closed on a lock rather than merely
        // refused on the next open.
        AppLockGate.shared.registerLockDismissiblePopover { [weak self] in self?.popover }

        if let button = statusItem.button {
            button.image = Self.statusItemIcon()
            button.toolTip = "Copy a 2FA code"
            button.target = self
            button.action = #selector(iconClicked)
        }

        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        content.onCopy = { [weak self] id in self?.onCopy?(id) }
        content.onOpenVault = { [weak self] in
            self?.onOpenVault?()
            self?.popover.performClose(nil)
        }
        content.onSizeChanged = { [weak self] size in self?.popover.contentSize = size }

        AppLockGate.shared.observe { [weak self] _ in
            self?.popover.performClose(nil)
        }

        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            guard let self else { return }
            self.popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self.content.applyTheme(theme)
        }
    }

    /// F22: compact mode merges the vault's 2FA quick-copy into one status
    /// item whose popover carries it as a tab, so the mode hides this one
    /// rather than leaving two doors to the same surface - see
    /// `CompactModePolicy.showsPerFeatureStatusItems`, which is the only
    /// thing that decides this and is asserted in CI's blocking lane.
    ///
    /// Hidden, never torn down: `NSStatusItem.isVisible` is exactly this
    /// API, the item keeps its store observation and its lock observer while
    /// hidden, and turning compact mode off puts it back with its count
    /// already current. An open popover is closed on the way out, because a
    /// popover whose anchor just left the menu bar has nothing to sit under.
    func setStatusItemVisible(_ visible: Bool) {
        statusItem.isVisible = visible
        if !visible { popover.performClose(nil) }
    }

    @objc private func iconClicked() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // GL-09. Refused outright rather than opened empty, exactly as the
        // crew's own popover is: an empty popover invites a second click,
        // and a re-shown one could still carry codes from before the lock.
        guard AppLockGate.shared.allows(.poneglyphMenuBarPopover) else {
            AppLog.lifecycle.info("poneglyph menu-bar popover refused - app is locked (GL-09)")
            NSSound.beep()
            return
        }
        prepareToShow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Everything an open does before the popover is on screen - split out
    /// like `StrawHatMenuBarController.prepareToShow()`, so a suite can
    /// drive the real path without a live `statusItem.button`.
    private func prepareToShow() {
        popover.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        content.applyTheme(ThemeManager.shared.theme)
        content.present(codes: codesProvider?() ?? [],
                        vaultUnlocked: vaultIsUnlocked?() ?? false)
    }

    /// A fresh symbol at menu-bar size. Not the Poneglyph destination's
    /// gradient tile - a status item is a monochrome template glyph, and a
    /// coloured tile there reads as a foreign object in the menu bar.
    private static func statusItemIcon() -> NSImage? {
        let image = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: "Copy a 2FA code")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        image?.isTemplate = true
        return image
    }

    /// The popover stops ticking the moment it closes - GL-13 applied to a
    /// 1Hz timer nobody can see.
    func popoverDidClose(_ notification: Notification) {
        content.stopTicking()
    }

    #if FM_SELFTESTS
    var debugPopover: NSPopover { popover }
    var debugContent: PoneglyphMenuBarPopoverController { content }
    func debugPrepareToShow() { prepareToShow() }
    /// **Only safe to call while the app is locked** - the unlocked branch
    /// reaches `popover.show(relativeTo:of:preferredEdge:)`, which raises
    /// when its anchor has no window, which is the case in a headless
    /// process. `StrawHatMenuBarSelfTest` records the same finding for the
    /// identical call.
    func debugIconClicked() { iconClicked() }
    var debugHasStatusButton: Bool { statusItem.button != nil }
    #endif
}

/// The popover's content: a header, one row per 2FA credential, and a
/// persistent "Open Poneglyph" link.
///
/// Deliberately internal rather than private, the same as
/// `StrawHatMenuBarPopoverController` - a `debug*` property returning this
/// type has to be reachable from a separate self-test file.
final class PoneglyphMenuBarPopoverController: NSViewController {

    static let width: CGFloat = 300

    /// Injectable width, and whether this content draws its own
    /// "Poneglyph / 2FA codes" header.
    ///
    /// Both exist for F22, for the reasons
    /// `StrawHatMenuBarPopoverController`'s own pair records: compact mode's
    /// popover hosts this controller as its Vault tab, a required `300` width
    /// inside a 330pt popover is a constraint conflict, and a second title
    /// under a header that already says "Grand Line" is noise. The standalone
    /// status item passes neither and is unchanged.
    private let contentWidth: CGFloat
    private let showsOwnHeader: Bool

    init(width: CGFloat = PoneglyphMenuBarPopoverController.width, showsOwnHeader: Bool = true) {
        self.contentWidth = width
        self.showsOwnHeader = showsOwnHeader
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    var onCopy: ((String) -> String?)?
    var onOpenVault: (() -> Void)?
    var onSizeChanged: ((NSSize) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Poneglyph")
    private let subtitleLabel = NSTextField(labelWithString: "2FA codes")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let rowsStack = NSStackView()
    private let openButton = HelmButton(title: "Open Poneglyph \u{2192}", variant: .quiet, size: .small)
    private let column = NSStackView()

    private var rows: [PoneglyphQuickCodeRow] = []
    private var codes: [PoneglyphQuickCode] = []
    private var ticker: UUID?
    private var theme: HelmTheme = ThemeManager.shared.theme

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root

        titleLabel.font = HelmType.rowTitle()
        subtitleLabel.font = HelmType.caption()
        emptyLabel.font = HelmType.caption()
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = HelmMetrics.s2
        header.translatesAutoresizingMaskIntoConstraints = false
        // Hidden rather than omitted: a hidden arranged subview of an
        // `NSStackView` drops out of layout entirely (AGENTS.md gotcha (11)'s
        // one named exception), so the column above it closes up with no
        // second constraint path to maintain.
        header.isHidden = !showsOwnHeader

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = HelmMetrics.s2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        openButton.target = self
        openButton.action = #selector(openVault)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s3
        column.translatesAutoresizingMaskIntoConstraints = false
        for child in [header, emptyLabel, rowsStack, openButton] as [NSView] {
            column.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s4),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s4),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s4),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.s4),
            root.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        applyTheme(ThemeManager.shared.theme)
    }

    deinit { TOTPTicker.shared.unobserve(ticker) }

    /// Rebuild for one open. Called by `prepareToShow()`, never on a timer -
    /// the per-second update is `tick()`, which moves numbers rather than
    /// rebuilding views.
    func present(codes: [PoneglyphQuickCode], vaultUnlocked: Bool) {
        _ = view      // force `loadView()`; `loadViewIfNeeded()` is macOS 14+
        self.codes = codes
        rows.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rows = codes.map { code in
            let row = PoneglyphQuickCodeRow(code: code)
            row.onCopy = { [weak self] id in self?.copy(id: id, from: row) }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            return row
        }
        rowsStack.isHidden = rows.isEmpty
        emptyLabel.isHidden = !rows.isEmpty
        if !vaultUnlocked {
            // GL-14's shape: "locked" and "none stored" are different
            // states and read differently. Collapsing them would tell a
            // captain they have no 2FA set up when in fact they have not
            // typed their master password.
            emptyLabel.stringValue = "Poneglyph is locked. Open it and unlock the vault to copy a code from here."
        } else {
            emptyLabel.stringValue = "No credential in your vault carries a 2FA secret yet. "
                + "Add one in the Two-factor section of a credential."
        }
        applyTheme(theme)
        tick()
        startTicking()
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(view.fittingSize)
    }

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = TOTPTicker.shared.observe { [weak self] in self?.tick() }
    }

    func stopTicking() {
        TOTPTicker.shared.unobserve(ticker)
        ticker = nil
    }

    private func tick() {
        let now = TOTPTicker.shared.now
        for row in rows { row.update(now: now, theme: theme) }
    }

    private func copy(id: String, from row: PoneglyphQuickCodeRow) {
        guard onCopy?(id) != nil else {
            row.flash("Couldn't copy")
            return
        }
        row.flash("Copied")
    }

    @objc private func openVault() { onOpenVault?() }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        _ = view
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        emptyLabel.textColor = HelmTheme.mutedInk(theme)
        // `openButton` is a `HelmButton` and themes itself - never set its
        // font, title colour or tint from here (the rule
        // `StrawHatMenuBarPopoverController.applyTheme` states for the same
        // three controls).
        rows.forEach { $0.update(now: TOTPTicker.shared.now, theme: theme) }
    }

    #if FM_SELFTESTS
    var debugRowCount: Int { rows.count }
    var debugEmptyText: String { emptyLabel.isHidden ? "" : emptyLabel.stringValue }
    var debugCodeTexts: [String] { rows.map(\.debugCodeText) }
    var debugTitles: [String] { rows.map(\.debugTitle) }
    var debugSecondsTexts: [String] { rows.map(\.debugSecondsText) }
    var debugIsTicking: Bool { ticker != nil }
    func debugPressCopy(_ index: Int) { rows[index].debugPressCopy() }
    func debugFlashText(_ index: Int) -> String { rows[index].debugFlashText }
    func debugTick() { tick() }
    #endif
}

/// One popover row: title over account, the live code, a countdown ring and
/// a copy button.
final class PoneglyphQuickCodeRow: NSView {

    var onCopy: ((String) -> Void)?

    private let code: PoneglyphQuickCode
    private let titleLabel = NSTextField(labelWithString: "")
    private let accountLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private let ring = TOTPRingView()
    private let copyButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "doc.on.doc")
    private var flashResetWork: DispatchWorkItem?

    init(code: PoneglyphQuickCode) {
        self.code = code
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = HelmType.caption()
        accountLabel.font = HelmType.caption()
        accountLabel.lineBreakMode = .byTruncatingMiddle
        codeLabel.font = .monospacedSystemFont(ofSize: HelmType.scaled(15), weight: .medium)
        codeLabel.isSelectable = true

        let text = NSStackView(views: [titleLabel, codeLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (5): the text column is the only thing allowed to shrink,
        // so a long account name truncates instead of squeezing the ring.
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)

        if !code.account.isEmpty {
            titleLabel.stringValue = code.title
            accountLabel.stringValue = code.account
            text.insertArrangedSubview(accountLabel, at: 1)
        } else {
            titleLabel.stringValue = code.title
        }

        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.toolTip = "Copy this code"
        for control in [ring, copyButton] as [NSView] {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let row = NSStackView(views: [text, ring, copyButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(now: Date, theme: HelmTheme) {
        let remaining = TOTP.secondsRemaining(code.totp, at: now)
        ring.fraction = TOTP.fractionRemaining(code.totp, at: now)
        ring.secondsText = "\(remaining)"
        ring.applyTheme(theme, urgent: remaining <= 5)
        if flashResetWork == nil {
            // GL-14: an unreadable seed says so rather than rendering as a
            // code of zeroes that would fail at a login prompt.
            codeLabel.stringValue = TOTP.code(code.totp, at: now).map(TOTP.grouped) ?? "seed unreadable"
        }
        titleLabel.textColor = HelmTheme.mutedInk(theme)
        accountLabel.textColor = HelmTheme.mutedInk(theme)
        codeLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
    }

    /// Say what happened, in the row itself. A popover has no `Toast` host
    /// that outlives it - the popover closes the moment focus moves - so the
    /// confirmation has to be here, and it has to restore itself.
    func flash(_ text: String) {
        flashResetWork?.cancel()
        codeLabel.stringValue = text
        let work = DispatchWorkItem { [weak self] in
            self?.flashResetWork = nil
            self?.update(now: TOTPTicker.shared.now, theme: ThemeManager.shared.theme)
        }
        flashResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    @objc private func copyTapped() { onCopy?(code.id) }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugCodeText: String { codeLabel.stringValue }
    var debugSecondsText: String { ring.secondsText }
    var debugFlashText: String { codeLabel.stringValue }
    func debugPressCopy() { copyTapped() }
    #endif
}
