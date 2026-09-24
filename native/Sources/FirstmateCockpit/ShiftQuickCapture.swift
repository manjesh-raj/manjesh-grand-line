// Manjesh Grand Line - native macOS app.
//
// ⌥Space: the universal capture panel (F2 of full review #3 §8), and the
// global hotkey that opens it.
//
// **The chord is the captain's since `fm/grandline-capture-global-hotkey-
// configurable`** - ⌥Space is the default rather than the definition, stored
// in `AppSettings.quickCaptureShortcut` and recorded on Settings > Capture.
// Everything below still says ⌥Space because that is what it ships as and
// what every other page prints; read it as "the capture chord". That task
// also fixed the reason it fired only while this app was frontmost - see
// `ShiftGlobalHotkey`'s own header, at the bottom of this file, for the
// diagnosis and for what was measured versus inferred.
//
// **What this was, and what F2 changed.** The panel shipped in phase 5 of
// `cockpit-shift-power-features` as a one-destination capture: a field, a hint
// line, Return, and a Shift task. The report's F2 finding is that the panel,
// `ShiftDateParser` and all five destination stores already existed, so the
// only thing missing was routing - "type text, then ⌘1 task / ⌘2 sticky / ⌘3
// note / ⌘4 credential / ⌘5 code snippet, with the pasteboard pre-filled and
// an 'ask the crew to file it' option". The field, the parse, the accent
// border, the brief confirmation and the lock gate are all unchanged; five
// tiles, a chip row and a crew button are what is new.
//
// **⌘1 is Return, deliberately.** The report leaves the default open and the
// brief asks for a judgment call. Return still files a task, exactly as it has
// since phase 5, because that is the muscle memory this panel has already
// taught - a captain who never learns a chord loses nothing. ⌘1 is its
// equivalent rather than its replacement, so the two can never disagree about
// what "the default" means (`file(to: .task)` is the one implementation).
//
// **Where the writes happen: not here.** The panel owns no store. Every
// destination is reached through a `CaptureFiler` the shell installs, for the
// reason `RecentDestinationsPopover`'s header states about its own registry -
// this is a floating panel, and the stores belong to the pages. It matters
// more than usual for one of the five: `CredentialVaultStore` caches an
// unlocked key, so GL-23 forbids a second instance, and the vault can be
// locked when ⌥Space fires. ⌘4 therefore **hands off** rather than writing -
// it opens Poneglyph's own Add sheet with the secret already in the secret
// field - which is also the honest answer for a credential, since a captured
// line is a secret and a secret is not a title. The other four file silently
// and say so.
//
// **The pasteboard, as a chip rather than as pre-filled text.** The mockup the
// captain reviewed draws the clipboard as a chip under the field
// ("clipboard: 10.42.0.0/16"), not as text already in it, and that is what is
// built here: a 4KB paste dropped into a 600pt field on every ⌥Space would be
// hostile, and a chip is one click away from the same result while staying
// legible. The chip is **suppressed for anything Poneglyph copied** - the
// concealed pasteboard markers `CredentialVaultClipboard` writes - so a
// capture panel opened twenty seconds after a vault copy never quotes the
// secret back at the captain. That is the same rule F3's clipboard history
// enforces, read from the same one place.
//
// **Key handling lives on the root view, not the field.** ⌘1-⌘5 arrive while
// the field editor has focus, and a field editor's `doCommandBy` never sees a
// command-modified digit. AppKit offers `performKeyEquivalent` down the
// content view's own subtree before the responder chain gets a `keyDown`,
// which is what `CaptureRootView` overrides - so the chords work while typing,
// which is the only time they are ever pressed.

import AppKit
import ApplicationServices

// MARK: - Filing

/// The result of asking the app to file a draft.
///
/// Three cases rather than a `Bool` because the panel says something different
/// for each, and because "handed off" is a real outcome here rather than a
/// half-success - ⌘4 opens a sheet and the capture is not yet saved.
enum CaptureFilingOutcome: Equatable {
    /// Written to its store. The panel shows the destination's own
    /// confirmation and dismisses itself.
    case filed(CaptureDestination)
    /// Routed somewhere the captain now has to finish (⌘4's Add sheet). The
    /// panel dismisses immediately so it is not floating over the sheet.
    case handedOff(CaptureDestination)
    /// Nothing was written, and this is why. The panel stays open with the
    /// message, so the typed text is never lost to a failure.
    case refused(String)
}

/// How the panel reaches the five stores.
///
/// A struct of one closure rather than a protocol: there is exactly one real
/// implementation (`AppShellController.makeCaptureFiler()`) and one test
/// double, and a protocol would buy nothing but a second file.
struct CaptureFiler {
    let file: (CaptureDestination, CaptureDraft) -> CaptureFilingOutcome

    /// A filer that refuses everything, naming why.
    ///
    /// The panel's default, so a `ShiftQuickCaptureController` built before
    /// the shell exists (or in a suite that only cares about the chrome) is
    /// inert rather than crashing - and visibly inert, rather than silently
    /// swallowing a capture.
    static let unwired = CaptureFiler { _, _ in
        .refused("Capture isn\u{2019}t wired to the app yet.")
    }
}

// MARK: - The panel's root view

/// The panel's content view, which exists for one override.
///
/// See this file's header: a command-modified digit never reaches a field
/// editor's `doCommandBy`, and `performKeyEquivalent` is dispatched down the
/// content view's subtree before any of that - so this is where ⌘1-⌘5 are
/// read from, and the only place they *can* be read from while the captain is
/// still typing.
final class CaptureRootView: NSView {
    var onDestinationChord: ((CaptureDestination) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let digit = Int(characters),
              let destination = CaptureDestination.forChordDigit(digit)
        else { return super.performKeyEquivalent(with: event) }
        return onDestinationChord?(destination) ?? false
    }
}

// MARK: - One destination tile

/// One of the five tiles: symbol, name, chord.
///
/// Built on `HoverHighlightView` for the reason every clickable row in this
/// app is (GL-16): it supplies the button role, the VoiceOver label, the focus
/// ring and the keyboard press, so a tile is reachable without a mouse without
/// any of that being written here. Same shape as
/// `AllDestinationsOverlay.DestinationTileView`, which is the nearest existing
/// tile and was read before this one was written.
final class CaptureDestinationTile: HoverHighlightView {
    let destination: CaptureDestination
    var onClick: (() -> Void)?

    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let chordLabel = NSTextField(labelWithString: "")

    /// Whether this tile is the one Return would file to. Drawn as the
    /// mockup's selected tile - hue border plus a wash - so the default is
    /// visible rather than only documented.
    var isDefault = false {
        didSet { applyTheme(currentTheme) }
    }

    private var currentTheme = ThemeManager.shared.theme

    init(destination: CaptureDestination) {
        self.destination = destination
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityLabelOverride = "File as \(destination.title), command \(destination.chordDigit)"
        accessibilityRoleOverride = .button
        onAccessibilityPress = { [weak self] in self?.onClick?() }
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        cornerRadius = HelmMetrics.rCard
        pressScale = HelmModuleCard.pressScale
        wantsLayer = true
        layer?.borderWidth = 1

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.stringValue = destination.title
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        chordLabel.stringValue = "\u{2318}\(destination.chordDigit)"
        chordLabel.alignment = .center
        chordLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(nameLabel)
        addSubview(chordLabel)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2 + 1),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            nameLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: HelmMetrics.s1),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s1),

            chordLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: HelmMetrics.s1),
            chordLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            chordLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(HelmMetrics.s2 + 1)),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    func applyTheme(_ theme: HelmTheme) {
        currentTheme = theme
        let hue = HelmTheme.nsColor(destination.hue.identityHex(in: theme))
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        // The selected tile paints a wash of its own hue and then has to put
        // a *label* on it, so the pair comes from `HelmContrast.tintedSurface`
        // at the 4.5:1 text target rather than from the raw hue - AGENTS.md's
        // "a `HelmTint` hue is safe as a fill and is NOT automatically safe as
        // text", which `FM_RUN_CONTRAST_TESTS` sweeps every theme against.
        let resolved = HelmContrast.tintedSurface(tintHex: destination.hue.identityHex(in: theme),
                                                  theme: theme,
                                                  target: HelmContrast.textTarget)
        let ink = isDefault ? resolved.foreground : HelmTheme.nsColor(theme.chromeInkHex)

        icon.image = HelmSymbol.image(destination.symbol, pointSize: 15, weight: .semibold,
                                      hierarchicalColor: isDefault ? resolved.foreground : hue,
                                      accessibilityDescription: destination.title)
        nameLabel.font = .systemFont(ofSize: HelmType.scaled(12), weight: .semibold)
        nameLabel.textColor = ink
        chordLabel.font = HelmType.code()
        chordLabel.textColor = isDefault ? ink : HelmTheme.mutedInk(theme)

        layer?.borderColor = (isDefault ? hue : line).cgColor
        normalColor = isDefault ? resolved.fill : .clear
        hoverColor = isDefault ? resolved.fill : line.withAlphaComponent(0.35)
    }

    #if FM_SELFTESTS
    /// The colour the name label is actually painted in.
    var debugNameColor: NSColor { nameLabel.textColor ?? .labelColor }

    /// What the label is painted *over*: this tile's own wash when it is the
    /// default, and the panel behind it otherwise. Resolving it here rather
    /// than in the suite is what keeps the contrast assertion honest - a tile
    /// with no fill of its own is legible against the panel, not against
    /// `.clear`.
    func debugFillColor(under theme: HelmTheme) -> NSColor {
        isDefault ? normalColor : HelmTheme.nsColor(theme.chromeBackgroundHex)
    }
    #endif
}

// MARK: - A chip under the field

/// One of the chips the mockup draws under the field: the parsed due date, and
/// the pasteboard offer. Clickable, because the pasteboard one inserts.
final class CaptureChip: HoverHighlightView {
    var onClick: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let symbolName: String
    private let isAccent: Bool

    init(symbol: String, accent: Bool) {
        self.symbolName = symbol
        self.isAccent = accent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        cornerRadius = HelmMetrics.rChip
        accessibilityRoleOverride = .button
        onAccessibilityPress = { [weak self] in self?.onClick?() }
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        wantsLayer = true
        layer?.borderWidth = 1

        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 11),
            icon.heightAnchor.constraint(equalToConstant: 11),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            topAnchor.constraint(equalTo: label.topAnchor, constant: -3),
            bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    func applyTheme(_ theme: HelmTheme) {
        let hue = isAccent ? HelmTheme.nsColor(theme.accentHex) : HelmTheme.mutedInk(theme)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        icon.image = HelmSymbol.image(symbolName, pointSize: 10, weight: .semibold,
                                      hierarchicalColor: hue)
        label.font = .systemFont(ofSize: HelmType.scaled(11))
        label.textColor = isAccent
            ? HelmContrast.legibleTintedText(tintHex: theme.accentHex, over: surface, theme: theme)
            : HelmTheme.mutedInk(theme)
        layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        normalColor = .clear
        hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.35)
    }
}

// MARK: - The panel

final class ShiftQuickCaptureController: NSWindowController, NSTextFieldDelegate {

    /// The panel's fixed width - the mockup's own 600pt, which is what five
    /// tiles need before "Credential" starts truncating.
    static let panelWidth: CGFloat = 600

    /// Installed by the shell. See this file's header for why the panel owns
    /// no store.
    var filer: CaptureFiler = .unwired

    /// Fired after a successful file, so the shell can refresh whatever was
    /// showing. Kept from the pre-F2 panel, where it meant only "a task was
    /// added"; it now carries which destination it was.
    var onCaptured: ((CaptureDestination) -> Void)?

    /// "Ask the crew to file it" runs a real `claude -p`. Injected so a suite
    /// can assert the routing without a CLI - `nil` means "resolve the
    /// captain's own", which is what the app does.
    var classifier: ((String, @escaping (CaptureDestination?) -> Void) -> Void)?

    private let inputField = HelmTextField(
        placeholder: "Capture anything \u{2014} try \u{201C}tomorrow 3pm review deploy notes\u{201D}",
        style: .prominent)
    private let titleLabel = NSTextField(labelWithString: "Capture")
    private let hotkeyChip = NSTextField(labelWithString: "\u{2325}Space")
    private let dateChip = CaptureChip(symbol: "calendar", accent: true)
    private let clipboardChip = CaptureChip(symbol: "doc.on.clipboard", accent: false)
    private let chipRow = NSStackView()
    private let sectionLabel = NSTextField(labelWithString: "FILE IT AS")
    private let tileRow = NSStackView()
    private var tiles: [CaptureDestinationTile] = []
    private let crewButton = HelmButton(title: "Ask the crew to file it",
                                        variant: .quiet, size: .small, symbol: "person.2")
    private let hintLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let topDivider = NSView()
    private let bottomDivider = NSView()
    private var themeToken: ThemeObservation?
    /// Cleared on every `present()`; set while a crew classification is in
    /// flight so a second click cannot start a second one.
    private var classificationInFlight = false

    init(filer: CaptureFiler = .unwired) {
        self.filer = filer
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 260),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: panel)
        buildUI(in: panel)
        _ = panel.followHelmTheme()
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        // Audit §5.1: gating `present()` only covers *opening* while locked.
        // This panel is `.floating`, so one already open when the lock fires
        // stayed up over the lock screen with a live capture field behind it -
        // the idle lock implies nobody was typing, but the 12h session-expiry
        // lock can fire mid-use. Registered once, here, where the window is
        // created; the gate orders it out on every lock.
        AppLockGate.shared.registerSecondaryWindow { [weak self] in self?.window }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    // MARK: Chrome

    private func buildUI(in panel: NSPanel) {
        let root = CaptureRootView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 260))
        root.wantsLayer = true
        root.layer?.cornerRadius = HelmMetrics.dSurface
        root.layer?.borderWidth = 1.5
        root.onDestinationChord = { [weak self] destination in
            self?.file(to: destination)
            return true
        }
        panel.contentView = root

        inputField.delegate = self

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        hotkeyChip.translatesAutoresizingMaskIntoConstraints = false
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isHidden = true
        statusLabel.lineBreakMode = .byTruncatingTail

        let bolt = NSImageView()
        bolt.translatesAutoresizingMaskIntoConstraints = false
        bolt.image = HelmSymbol.image("bolt.fill", pointSize: 14, weight: .semibold)
        boltIcon = bolt

        let header = NSStackView(views: [bolt, titleLabel, NSView(), hotkeyChip])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = HelmMetrics.s2
        header.translatesAutoresizingMaskIntoConstraints = false

        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = HelmMetrics.s2
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        chipRow.addArrangedSubview(dateChip)
        chipRow.addArrangedSubview(clipboardChip)
        clipboardChip.onClick = { [weak self] in self?.insertClipboardText() }
        dateChip.onClick = nil

        for divider in [topDivider, bottomDivider] {
            divider.wantsLayer = true
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }

        tileRow.orientation = .horizontal
        tileRow.alignment = .centerY
        tileRow.spacing = HelmMetrics.s2
        // Gotcha (10): `.gravityAreas` is the default and honours no priority
        // at all, so five equal tiles need `.fillEqually` said out loud.
        tileRow.distribution = .fillEqually
        tileRow.translatesAutoresizingMaskIntoConstraints = false
        for destination in CaptureDestination.allCases {
            let tile = CaptureDestinationTile(destination: destination)
            // F4: which tile is the default is now a function of what has been
            // typed (`CaptureRouter.defaultDestination`), re-evaluated on every
            // keystroke by `refreshChips`. `.task` is what an empty panel
            // shows, which is what it always showed.
            tile.isDefault = destination == .task
            tile.onClick = { [weak self] in self?.file(to: destination) }
            tiles.append(tile)
            tileRow.addArrangedSubview(tile)
        }

        crewButton.target = self
        crewButton.action = #selector(askTheCrew)
        crewButton.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [crewButton, NSView(), hintLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = HelmMetrics.s2
        footer.translatesAutoresizingMaskIntoConstraints = false

        for view in [header, inputField, chipRow, topDivider, sectionLabel, tileRow,
                     bottomDivider, footer, statusLabel] {
            root.addSubview(view)
        }

        let gutter = HelmMetrics.s4
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.panelWidth),

            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s3),

            inputField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            inputField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            inputField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s2),

            chipRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            chipRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -gutter),
            chipRow.topAnchor.constraint(equalTo: inputField.bottomAnchor, constant: HelmMetrics.s2),

            topDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topDivider.topAnchor.constraint(equalTo: chipRow.bottomAnchor, constant: HelmMetrics.s3),

            sectionLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            sectionLabel.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: HelmMetrics.s3),

            tileRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            tileRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            tileRow.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: HelmMetrics.s2),

            bottomDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomDivider.topAnchor.constraint(equalTo: tileRow.bottomAnchor, constant: HelmMetrics.s3),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            footer.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor, constant: HelmMetrics.s2),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.s3),

            statusLabel.leadingAnchor.constraint(equalTo: crewButton.trailingAnchor, constant: HelmMetrics.s3),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: hintLabel.leadingAnchor, constant: -HelmMetrics.s2),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])

        applyTheme(ThemeManager.shared.theme)
        resizeToFit()
    }

    private var boltIcon: NSImageView?

    private func resizeToFit() {
        guard let window, let root = window.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height
        window.setContentSize(NSSize(width: Self.panelWidth, height: height))
    }

    // MARK: Presenting

    func present() {
        // GL-09: ⌥Space is a *global* hotkey - it fires while another app is
        // frontmost, which is exactly why it kept working over the lock
        // screen. A locked app must not open a capture field, and must
        // certainly not accept the write behind it.
        guard AppLockGate.shared.allows(.quickCapture) else {
            AppLog.lifecycle.info("quick capture refused - app is locked (GL-09)")
            NSSound.beep()
            return
        }
        guard let window else { return }
        inputField.stringValue = ""
        classificationInFlight = false
        crewButton.isEnabled = true
        statusLabel.isHidden = true
        hintLabel.isHidden = false
        refreshChips()
        resizeToFit()
        if let screen = NSScreen.main {
            let x = screen.frame.midX - window.frame.width / 2
            let y = screen.frame.maxY - 160
            window.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        } else {
            window.center()
        }
        // A quick-capture invocation can arrive while some other app is
        // frontmost (that's the whole point of a global hotkey) - `orderFront`
        // alone would show the panel behind the still-frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(inputField)
    }

    // MARK: The chips

    /// Re-read the parsed date and the pasteboard. Called on every `present()`
    /// and on every keystroke, so the date chip tracks what is typed.
    private func refreshChips() {
        let draft = CaptureRouter.draft(from: inputField.stringValue)
        if let due = draft.dueDate {
            dateChip.isHidden = false
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = draft.dueHasTime ? "EEE d MMM, h:mm a" : "EEE d MMM"
            dateChip.text = formatter.string(from: due)
        } else {
            dateChip.isHidden = true
        }

        if let offer = Self.pasteboardOffer() {
            clipboardChip.isHidden = false
            clipboardChip.text = "clipboard: \(CaptureRouter.elide(offer, limit: 48))"
        } else {
            clipboardChip.isHidden = true
        }
        chipRow.isHidden = dateChip.isHidden && clipboardChip.isHidden

        // F4: the default tile moves with the text, so the captain can see
        // where Return will file before pressing it.
        let preferred = CaptureRouter.defaultDestination(for: draft)
        for tile in tiles { tile.isDefault = tile.destination == preferred }
    }

    /// What the pasteboard is offering, as one line - or nil when there is
    /// nothing to offer.
    ///
    /// **Nil for anything Poneglyph copied.** The concealed markers are read
    /// through `CredentialVaultClipboard.isConcealed(_:)`, the one place this
    /// app decides what "a secret is on the pasteboard" means, so the capture
    /// panel and the clipboard history can never disagree about it.
    static func pasteboardOffer(_ pasteboard: NSPasteboard = .general) -> String? {
        guard !CredentialVaultClipboard.isConcealed(pasteboard) else { return nil }
        guard let raw = pasteboard.string(forType: .string) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: "\n", with: " \u{23ce} ")
    }

    private func insertClipboardText() {
        guard let raw = NSPasteboard.general.string(forType: .string),
              !CredentialVaultClipboard.isConcealed(NSPasteboard.general) else { return }
        let existing = inputField.stringValue
        inputField.stringValue = existing.isEmpty
            ? raw
            : existing + (existing.hasSuffix("\n") ? "" : "\n") + raw
        refreshChips()
        window?.makeFirstResponder(inputField)
    }

    // MARK: Filing

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return is whichever chord the default tile is showing, not a
            // fourth code path - see this file's header. Before F4 that was
            // always ⌘1; it is now `CaptureRouter.defaultDestination`, so a
            // capture that is nothing but a URL lands on the reading list
            // rather than becoming a task titled with a URL.
            file(to: CaptureRouter.defaultDestination(for: CaptureRouter.draft(from: inputField.stringValue)))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.orderOut(nil)
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshChips()
        resizeToFit()
    }

    /// File what is typed to `destination`. The one implementation every entry
    /// point (Return, a chord, a tile click, the crew's answer) goes through.
    func file(to destination: CaptureDestination) {
        let draft = CaptureRouter.draft(from: inputField.stringValue)
        guard !draft.isEmpty else {
            NSSound.beep()
            return
        }
        switch filer.file(destination, draft) {
        case .filed:
            onCaptured?(destination)
            finish(with: destination.confirmation)
        case .handedOff:
            onCaptured?(destination)
            window?.orderOut(nil)
        case .refused(let why):
            show(status: why, isError: true)
        }
    }

    private func finish(with message: String) {
        show(status: message, isError: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.window?.orderOut(nil)
        }
    }

    private func show(status: String, isError: Bool) {
        statusLabel.stringValue = status
        statusLabel.textColor = isError
            ? HelmTheme.nsColor(ThemeManager.shared.theme.ansiHex[1])
            : HelmTheme.nsColor(ThemeManager.shared.theme.ansiHex[2])
        statusLabel.isHidden = false
        hintLabel.isHidden = true
        resizeToFit()
    }

    // MARK: "Ask the crew to file it"

    @objc private func askTheCrew() {
        let draft = CaptureRouter.draft(from: inputField.stringValue)
        guard !draft.isEmpty else {
            NSSound.beep()
            return
        }
        guard !classificationInFlight else { return }
        classificationInFlight = true
        crewButton.isEnabled = false
        show(status: "Asking the crew\u{2026}", isError: false)

        let done: (CaptureDestination?) -> Void = { [weak self] destination in
            guard let self else { return }
            self.classificationInFlight = false
            self.crewButton.isEnabled = true
            guard let destination else {
                // GL-14's shape: "the crew could not say" is not "file it as a
                // task". The captain stays in the loop with the text intact.
                self.show(status: "The crew couldn\u{2019}t place it \u{2014} pick a destination.",
                          isError: true)
                return
            }
            for tile in self.tiles { tile.isDefault = tile.destination == destination }
            self.file(to: destination)
        }

        if let classifier {
            classifier(draft.text, done)
            return
        }
        guard let executable = ClaudeOneShot.resolve() else {
            classificationInFlight = false
            crewButton.isEnabled = true
            show(status: "The crew needs the claude CLI on PATH.", isError: true)
            return
        }
        ClaudeOneShot.run(executable: executable,
                          prompt: CaptureRouter.classificationPrompt(for: draft.text),
                          timeout: CaptureRouter.classificationTimeout,
                          label: "capture classify") { result in
            switch result {
            case .success(let reply):
                done(CaptureRouter.parseClassification(reply.text))
            case .failure(let error):
                AppLog.ai.error("capture classification failed: \(error.message, privacy: .public)")
                done(nil)
            }
        }
    }

    // MARK: Theme

    private func applyTheme(_ theme: HelmTheme) {
        let accent = HelmTheme.nsColor(theme.accentHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        guard let root = window?.contentView else { return }
        // `ThemeManager.swift`'s checklist item 2: force the appearance, or
        // everything resolving a system semantic colour - the shared field
        // editor very much included, and this panel is one big field - follows
        // the OS rather than the theme.
        root.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        root.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        root.layer?.borderColor = accent.cgColor

        boltIcon?.image = HelmSymbol.image("bolt.fill", pointSize: 14, weight: .semibold,
                                           hierarchicalColor: accent)
        titleLabel.font = HelmType.rowTitle()
        titleLabel.textColor = ink
        hotkeyChip.font = HelmType.code()
        hotkeyChip.textColor = muted
        sectionLabel.attributedStringValue = NSAttributedString(
            string: "FILE IT AS", attributes: HelmType.kickerAttributes(color: muted))
        hintLabel.font = .systemFont(ofSize: HelmType.scaled(11))
        hintLabel.textColor = muted
        hintLabel.stringValue = "\u{23CE} file as a task \u{00B7} \u{2318}1\u{2013}\u{2318}5 choose \u{00B7} Esc dismiss"
        statusLabel.font = .systemFont(ofSize: HelmType.scaled(12), weight: .medium)
        topDivider.layer?.backgroundColor = line.withAlphaComponent(0.6).cgColor
        bottomDivider.layer?.backgroundColor = line.withAlphaComponent(0.6).cgColor
        dateChip.applyTheme(theme)
        clipboardChip.applyTheme(theme)
        for tile in tiles { tile.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    /// The five real tiles, in display order - so a suite can read what the
    /// panel shows and drive a real click through each tile's own `onClick`.
    var debugTiles: [CaptureDestinationTile] { tiles }
    var debugInputField: HelmTextField { inputField }
    var debugStatusText: String? { statusLabel.isHidden ? nil : statusLabel.stringValue }
    var debugDateChipText: String? { dateChip.isHidden ? nil : dateChip.text }
    var debugClipboardChipText: String? { clipboardChip.isHidden ? nil : clipboardChip.text }
    var debugRootView: CaptureRootView? { window?.contentView as? CaptureRootView }
    func debugSetText(_ text: String) {
        inputField.stringValue = text
        refreshChips()
    }

    /// Drive the crew button's own action, so a suite exercises the real
    /// routing rather than a reimplementation of it.
    func debugAskTheCrew() { askTheCrew() }
    #endif
}

/// Registers the captain's configurable quick-capture shortcut (⌥Space out of
/// the box). Two monitors are needed to cover both cases the brief calls out:
/// a **local** monitor (`NSEvent.addLocalMonitorForEvents`) fires while this
/// app is frontmost but some other window has focus, no permission required;
/// a **global** monitor (`NSEvent.addGlobalMonitorForEvents`) fires while a
/// *different* app is frontmost - the actual "from anywhere" case - but per
/// Apple's own documentation that only delivers keyDown/keyUp/flagsChanged
/// events once the process is a trusted Accessibility client
/// (`AXIsProcessTrusted`). `requestPermissionIfNeeded()` triggers the real
/// system prompt via `AXIsProcessTrustedWithOptions`; until granted, the
/// global monitor is registered but macOS simply never calls it - no crash,
/// no error, just silence, which is why `isAccessibilityTrusted` exists for
/// callers to check honestly rather than assuming the hotkey works everywhere
/// just because `start()` didn't throw.
///
/// ## What `fm/grandline-capture-global-hotkey-configurable` changed, and why
///
/// The captain reported that ⌥Space opened the panel only while Grand Line
/// itself was frontmost. Three candidate causes were checked live against his
/// own running instance before any code was touched, and two were eliminated:
/// Accessibility trust **is** granted (`AXIsProcessTrusted()` read `true`
/// through a read-only `lldb` attach, the same technique
/// `fm/grandline-live-gap-rootcause-scout` established), and nothing else on
/// the machine claims ⌥Space (no `com.apple.symbolichotkeys` entry binds
/// keycode 49 with the Option flag alone, no launcher app is installed, and
/// Secure Event Input was off). That left the third: this class's own
/// matching predicate, which was the one hotkey in the app that never adopted
/// `KeyChord.relevantModifierMask`.
///
/// The old predicate was
/// `event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.option]`.
/// `.deviceIndependentFlagsMask` is `0xFFFF0000` - it carries Caps Lock, Fn,
/// the numeric-pad flag and the help flag alongside ⌘⌥⌃⇧ - so **any** ambient
/// flag riding along on the event makes that exact equality false and the
/// chord silently stops matching. `KeyChord`'s own header already writes down
/// why that mask is the wrong one ("Caps Lock's flag reflects a toggle
/// *state*, not a momentary press, so a captain who happens to have Caps Lock
/// on would silently break matching"), and `DictationHotkey` - the one global
/// hotkey in this app that demonstrably does fire from any app - has always
/// masked with `KeyChord.relevantModifierMask` instead. Matching here now
/// goes through `KeyChord` too, so there is one definition of "does this
/// event mean this chord" rather than three.
///
/// **Why "works when frontmost" was not evidence that the monitors were
/// fine.** The Shift menu carries a ⌥Space key equivalent of its own
/// (`main.swift`'s `quickCaptureItem`, kept deliberately as the
/// no-Accessibility fallback), so the frontmost case has two independent
/// implementations. A predicate defect that kills both monitors still leaves
/// the panel opening from the menu bar, which is exactly the shape the
/// captain described. Any future "the hotkey half-works" report should
/// establish which of the two paths fired before concluding anything about
/// the other.
///
/// **What was not verified.** Nobody reproduced a real global ⌥Space
/// keystroke being delivered to (or withheld from) this process. That needs a
/// live keypress while a different app is frontmost, and this repo's agent
/// shell has no Accessibility permission of its own (AGENTS.md's "Verifying
/// native UI bugs" section) - the only way to get one would have been to
/// inject an event source into the captain's own running app, which is beyond
/// the read-only attach the convention sanctions. The predicate defect above
/// is proven from the code and from `KeyChord`'s own documented rule; that it
/// is the *whole* of what the captain saw is inference, and is recorded as
/// such in `docs/history/33-capture-and-clipboard.md`.
///
/// ## Two event shapes, one class
///
/// Now that the chord is recordable it can be either shape, so this follows
/// `DictationHotkey`'s established handling rather than inventing a second
/// one: a **modifier-only** chord fires `.flagsChanged` and a **regular key +
/// modifiers** chord fires `.keyDown`, and `start()` installs only the pair
/// the current shortcut actually needs. `updateShortcut(_:)` tears the old
/// pair down and installs the new one, so switching shapes can never leave a
/// stale monitor listening for a chord nobody can press any more.
///
/// A capture trigger is a *press*, not a hold, so only the down edge matters -
/// there is no `onUp` here and no `isHeld` latch. A modifier-only chord is
/// still accepted (the recorder is left at `.any`), and fires once on the
/// flag appearing; `isHeld` exists purely so releasing it does not fire a
/// second time.
final class ShiftGlobalHotkey {
    // Internal (not `private`) for the same reason `DictationHotkey`'s are:
    // `ShiftGlobalHotkeySelfTest` asserts that `start()`/`updateShortcut(_:)`
    // install a real monitor object for the mechanism the current shortcut
    // needs, and tear down the other mechanism's. Driving `matches(_:)`
    // alone proves the predicate and says nothing about whether anything is
    // listening - which is precisely the gap this class shipped with.
    var localFlagsMonitor: Any?
    var globalFlagsMonitor: Any?
    var localKeyMonitor: Any?
    var globalKeyMonitor: Any?
    private let handler: () -> Void
    /// Only meaningful for a modifier-only chord: a bare modifier's
    /// `.flagsChanged` fires on both the press and the release, and a capture
    /// trigger must open one panel, not two.
    private var isHeld = false
    private(set) var shortcut: KeyChord

    /// Whether the process was a trusted Accessibility client at the moment
    /// the current monitors were installed.
    ///
    /// macOS arms a global monitor from the trust the process has *when the
    /// monitor is registered*; granting trust afterwards does not reach back
    /// and arm one that is already installed. This records what was true at
    /// install time so `reassertIfTrustChanged()` can notice the transition,
    /// and so the Settings page can say "granted, but this monitor predates
    /// the grant" rather than only "granted".
    private(set) var installedWhileTrusted = false

    init(shortcut: KeyChord = .quickCaptureDefault, handler: @escaping () -> Void) {
        self.shortcut = shortcut
        self.handler = handler
    }

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the real system "Accessibility" permission prompt if not already
    /// granted. Safe to call every launch - a no-op (returns `true`
    /// immediately, no dialog) once already granted.
    @discardableResult
    func requestPermissionIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Idempotent: every call tears the previous pair down first, so a second
    /// `start()` cannot leak a monitor the way the pre-`fm/grandline-capture-
    /// global-hotkey-configurable` version could.
    func start() {
        stopMonitors()
        isHeld = false
        installedWhileTrusted = isAccessibilityTrusted
        if shortcut.isModifierOnly {
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsEvent(event)
                return event
            }
            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsEvent(event)
            }
        } else {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Swallowing the event is what stops ⌥Space also reaching the
                // focused field as a non-breaking space while this app is
                // frontmost.
                if self.matches(event) {
                    self.fire()
                    return nil
                }
                return event
            }
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.matches(event) else { return }
                self.fire()
            }
        }
        AppLog.lifecycle.info(
            "quick capture hotkey installed: \(self.shortcut.displayString, privacy: .public), accessibility trusted: \(self.installedWhileTrusted, privacy: .public)")
    }

    func stop() {
        stopMonitors()
        isHeld = false
    }

    private func stopMonitors() {
        for monitor in [localFlagsMonitor, globalFlagsMonitor, localKeyMonitor, globalKeyMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        localFlagsMonitor = nil
        globalFlagsMonitor = nil
        localKeyMonitor = nil
        globalKeyMonitor = nil
    }

    /// Swaps in a newly recorded shortcut and restarts monitoring under
    /// whichever mechanism that combo needs - the same contract (and the same
    /// reason) `DictationHotkey.updateShortcut(_:)` documents: a plain
    /// property set would leave the old monitor type installed and deaf to
    /// the new chord's real event shape.
    func updateShortcut(_ newShortcut: KeyChord) {
        shortcut = newShortcut
        start()
    }

    /// Reinstalls the monitors if Accessibility trust has been granted since
    /// they were installed.
    ///
    /// Launch requests the permission and installs the monitors in the same
    /// breath, so a captain who grants it in the System Settings pane that
    /// prompt opens is granting it *after* the global monitor already exists -
    /// and macOS does not arm an already-registered global monitor
    /// retroactively. Before this, the only cure was relaunching the app, and
    /// nothing said so. Cheap enough to call on every app activation: it is
    /// one `AXIsProcessTrusted()` read and returns immediately unless the
    /// answer actually changed.
    @discardableResult
    func reassertIfTrustChanged() -> Bool {
        guard !installedWhileTrusted, isAccessibilityTrusted else { return false }
        AppLog.lifecycle.info("quick capture hotkey: accessibility granted since install - reinstalling monitors")
        start()
        return true
    }

    /// Internal (not `private`) so the suite can drive the real predicate
    /// rather than a second copy of it.
    ///
    /// Masking with `KeyChord.relevantModifierMask` (⌘⌥⌃⇧ only) rather than
    /// `.deviceIndependentFlagsMask` is the fix described in this class's
    /// header: an ambient Caps Lock or Fn flag must not decide whether the
    /// captain's shortcut works. Exact equality on what is left matches
    /// `DictationHotkey.handleKeyEvent`'s rule for a regular-key chord - a
    /// deliberate combo means that combo, not that combo plus anything.
    func matches(_ event: NSEvent) -> Bool {
        guard !shortcut.isModifierOnly, event.keyCode == shortcut.keyCode else { return false }
        return event.modifierFlags.intersection(KeyChord.relevantModifierMask) == shortcut.modifiers
    }

    /// Internal for the same reason - a modifier-only chord's `.flagsChanged`
    /// path, which fires on the press edge only.
    func handleFlagsEvent(_ event: NSEvent) {
        guard shortcut.isModifierOnly, event.keyCode == shortcut.keyCode else { return }
        let current = event.modifierFlags.intersection(KeyChord.relevantModifierMask)
        let isPressed = !shortcut.modifiers.isEmpty && current.contains(shortcut.modifiers)
        if isPressed && !isHeld {
            isHeld = true
            fire()
        } else if !isPressed {
            isHeld = false
        }
    }

    private func fire() {
        handler()
    }
}
