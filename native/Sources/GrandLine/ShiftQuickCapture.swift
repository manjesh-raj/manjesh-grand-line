// Grand Line - native macOS app.
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
// an 'ask the crew to file it' option". F4 appended Link as ⌘6.
//
// **CP-1, the hero head** (the hero restyle board,
// `data/grandline-hero-restyle-designs-scout/`, the captain's pick). The
// panel opens on the hero gradient, as ⌘K's lit row, the notifications panel
// and the toasts do: a glass bolt tile, "Capture", the captain's chord, and
// the field in the hero ink, with the date and clipboard chips on the
// gradient. The field sits on the hero's dark shade, never a white wash -
// typed words on a 14% white wash measured 4.49:1 on the board and 7.83:1 on
// the shade. The tile Return files to is lit with the gradient, so the light
// shows where Return goes, and when the crew answers, the light moves to its
// pick before it files. A successful file turns the head into the
// confirmation for the 0.9s it has always stood, then the panel closes. The
// accent border and the two dividers are gone, and refusals sit at the top of
// the body, above the tiles, rather than replacing the footer's hint.
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
// **Key handling lives on the root view, not the field.** ⌘1-⌘6 arrive while
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
/// content view's subtree before any of that - so this is where ⌘1-⌘6 are
/// read from, and the only place they *can* be read from while the captain is
/// still typing.
final class CaptureRootView: NSView {
    var onDestinationChord: ((CaptureDestination) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AGENTS.md gotcha (21): `KeyChord.relevantModifierMask` (⌘⌥⌃⇧), not
        // `.deviceIndependentFlagsMask`. That mask carries Caps Lock, Fn and
        // the numeric-pad flag too, so with Caps Lock on - or a digit typed on
        // the keypad - the exact `== .command` below never matched and every
        // chord on this panel was dead.
        let flags = event.modifierFlags.intersection(KeyChord.relevantModifierMask)
        guard flags == .command,
              let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let digit = Int(characters),
              let destination = CaptureDestination.forChordDigit(digit)
        else { return super.performKeyEquivalent(with: event) }
        return onDestinationChord?(destination) ?? false
    }
}

// MARK: - A keycap

/// One keycap on the panel: the head's chord on the gradient, and each tile's
/// ⌘N.
///
/// Not `HelmKeyHint`: the board draws a chord as one cap ("⌘1"), where that
/// component draws one cap per glyph, and it themes itself in the page's
/// colours, which on the lit tile and the head would be a page-coloured cap on
/// the gradient. The owner paints this one.
final class CaptureKeycap: NSView {
    private let label = NSTextField(labelWithString: "")

    init(_ text: String = "") {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = HelmKeyHint.capCornerRadius
        layer?.borderWidth = HelmField.hairlineBorderWidth
        label.stringValue = text
        label.font = HelmType.chip()
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: axis)
            setContentCompressionResistancePriority(.required, for: axis)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    func paint(fill: NSColor, border: NSColor, ink: NSColor) {
        label.font = HelmType.chip()
        label.textColor = ink
        HelmMotion.withoutActions {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = border.cgColor
        }
    }

    #if FM_SELFTESTS
    var debugInk: NSColor? { label.textColor }
    var debugFill: NSColor? { layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
    #endif
}

// MARK: - One destination tile

/// One of the six tiles: a wash tile of the destination's hue, its name, its
/// chord.
///
/// Built on `HoverHighlightView` for the reason every clickable row in this
/// app is (GL-16): it supplies the button role, the VoiceOver label, the focus
/// ring and the keyboard press, so a tile is reachable without a mouse without
/// any of that being written here. Same shape as
/// `AllDestinationsOverlay.DestinationTileView`, which is the nearest existing
/// tile and was read before this one was written.
///
/// **CP-1: the tile Return files to is lit.** It paints the hero's quiet-ink
/// gradient, its name and keycap in the hero's ink and its tile as glass, so
/// the light shows where Return goes. Every other tile is the card with a
/// hairline, as the board draws them.
final class CaptureDestinationTile: HoverHighlightView {
    let destination: CaptureDestination
    var onClick: (() -> Void)?

    /// The board's 28pt wash tile.
    static let iconSide: CGFloat = 28
    static let glyphPointSize: CGFloat = 13

    private let hero = HelmHeroSurface()
    private let icon = IconTileView(size: CaptureDestinationTile.iconSide, cornerRadius: HelmMetrics.rControl)
    private let glassTile = NSView()
    private let glassGlyph = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let chordCap: CaptureKeycap

    /// Whether this tile is the one Return would file to - lit, so the
    /// default is visible rather than only documented.
    var isDefault = false {
        didSet { applyTheme(currentTheme) }
    }

    private var currentTheme = ThemeManager.shared.theme
    private(set) var palette: HelmHeroSurface.Palette?

    init(destination: CaptureDestination) {
        self.destination = destination
        chordCap = CaptureKeycap("\u{2318}\(destination.chordDigit)")
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

        // The gradient sits under everything and takes no clicks
        // (`HelmHeroSurface.hitTest`), so a click on the lit tile still lands
        // on this view's recognizer. The board's glow is sized from the tile
        // itself, which is `.capsule`'s ellipse, not the card's 220pt circle.
        hero.glowShape = .capsule
        hero.isHidden = true
        hero.layer?.cornerRadius = HelmMetrics.rCard
        addSubview(hero)

        glassTile.wantsLayer = true
        glassTile.layer?.cornerRadius = HelmMetrics.rControl
        glassTile.layer?.borderWidth = 1
        glassTile.isHidden = true
        glassTile.translatesAutoresizingMaskIntoConstraints = false
        glassGlyph.translatesAutoresizingMaskIntoConstraints = false
        glassGlyph.imageScaling = .scaleNone
        glassTile.addSubview(glassGlyph)

        let iconBox = NSView()
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)
        iconBox.addSubview(glassTile)

        nameLabel.stringValue = destination.title
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconBox)
        addSubview(nameLabel)
        addSubview(chordCap)
        NSLayoutConstraint.activate([
            hero.leadingAnchor.constraint(equalTo: leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: trailingAnchor),
            hero.topAnchor.constraint(equalTo: topAnchor),
            hero.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconBox.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconBox.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2 + 1),
            iconBox.widthAnchor.constraint(equalToConstant: Self.iconSide),
            iconBox.heightAnchor.constraint(equalToConstant: Self.iconSide),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            glassTile.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            glassTile.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            glassTile.widthAnchor.constraint(equalToConstant: Self.iconSide),
            glassTile.heightAnchor.constraint(equalToConstant: Self.iconSide),
            glassGlyph.centerXAnchor.constraint(equalTo: glassTile.centerXAnchor),
            glassGlyph.centerYAnchor.constraint(equalTo: glassTile.centerYAnchor),

            nameLabel.topAnchor.constraint(equalTo: iconBox.bottomAnchor, constant: HelmMetrics.s1),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s1),

            chordCap.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: HelmMetrics.s1),
            chordCap.centerXAnchor.constraint(equalTo: centerXAnchor),
            chordCap.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(HelmMetrics.s2 - 1)),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    /// The lit tile's palette: the theme's hero colour through the quiet-ink
    /// rule, the same one the head paints.
    static func palette(in theme: HelmTheme) -> HelmHeroSurface.Palette {
        HelmHeroColumn.palette(for: HelmModuleCard.HeroTone(colour: .themeAccent), in: theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        currentTheme = theme
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        // The destination's identity colour, as a wash with a glyph that
        // clears the icon floor on it (`IconTileView`'s literal path, which
        // routes through `HelmContrast.tintedSurface`). `identityHex` rather
        // than a semantic tint: a tile says "this is the Sticky Board", never
        // "this is a warning".
        icon.configure(symbol: destination.symbol, tint: .accent, pointSize: Self.glyphPointSize)
        icon.overrideFill(hex: destination.hue.identityHex(in: theme))
        icon.applyTheme(theme)
        nameLabel.font = .systemFont(ofSize: HelmType.scaled(12), weight: .semibold)
        if isDefault {
            let palette = Self.palette(in: theme)
            self.palette = palette
            let ink = HelmContrast.color(palette.ink)
            hero.apply(palette)
            hero.isHidden = false
            icon.isHidden = true
            glassTile.isHidden = false
            HelmMotion.withoutActions {
                glassTile.layer?.backgroundColor = ink.withAlphaComponent(PopoverHeroHeader.glassFillAlpha).cgColor
                glassTile.layer?.borderColor = ink.withAlphaComponent(PopoverHeroHeader.glassBorderAlpha).cgColor
                layer?.borderWidth = 0
            }
            glassGlyph.image = HelmSymbol.image(destination.symbol, pointSize: Self.glyphPointSize,
                                                weight: .semibold, hierarchicalColor: ink,
                                                accessibilityDescription: destination.title)
            nameLabel.textColor = ink
            chordCap.paint(fill: ink.withAlphaComponent(PopoverHeroHeader.glassFillAlpha),
                           border: ink.withAlphaComponent(PopoverHeroHeader.glassBorderAlpha), ink: ink)
            normalColor = .clear
            hoverColor = .clear
        } else {
            palette = nil
            hero.isHidden = true
            icon.isHidden = false
            glassTile.isHidden = true
            HelmMotion.withoutActions {
                layer?.borderWidth = 1
                layer?.borderColor = line.cgColor
            }
            nameLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
            chordCap.paint(fill: HelmTheme.nsColor(theme.chromeBackgroundHex), border: line,
                           ink: HelmTheme.mutedInk(theme))
            normalColor = .clear
            hoverColor = line.withAlphaComponent(0.35)
        }
    }

    #if FM_SELFTESTS
    /// The colour the name label is actually painted in.
    var debugNameColor: NSColor { nameLabel.textColor ?? .labelColor }

    /// What the label is painted *over*: the lit tile's lighter stop, where
    /// white ink is closest to failing, and the panel's card otherwise.
    /// Resolving it here rather than in the suite is what keeps the contrast
    /// assertion honest - a tile with no fill of its own is legible against
    /// the panel, not against `.clear`.
    func debugFillColor(under theme: HelmTheme) -> NSColor {
        if isDefault, let palette { return HelmContrast.color(palette.lighterStop) }
        return HelmTheme.nsColor(theme.chromeBackgroundHex)
    }
    var debugIsLit: Bool { !hero.isHidden }
    var debugHeroGradient: [CGColor] { hero.debugGradientColors }
    var debugGlassTileHidden: Bool { glassTile.isHidden }
    var debugChordCap: CaptureKeycap { chordCap }
    #endif
}

// MARK: - A chip under the field

/// One of the chips the mockup draws under the field: the parsed due date, and
/// the pasteboard offer. Clickable, because the pasteboard one inserts.
///
/// CP-1 puts them on the head's gradient: a pill on the hero's dark shade with
/// a glass hairline and the words in the hero's ink, the same recipe as the
/// field above them, because white words on a white wash fail the text floor.
final class CaptureChip: HoverHighlightView {
    var onClick: (() -> Void)?

    /// The board's 22pt pill.
    static let height: CGFloat = 22

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let symbolName: String

    init(symbol: String) {
        self.symbolName = symbol
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 11),
            icon.heightAnchor.constraint(equalToConstant: 11),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    /// A pill at any height.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cornerRadius = newSize.height / 2
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    /// Paint the chip for a hero whose ink is `ink`: `HelmButton`'s ghost
    /// recipe, a shade of the ink's opposite under the words, which can only
    /// add contrast, with the glass hairline the board draws.
    func paint(heroInk ink: NSColor) {
        let shade = HelmButton.heroShade(for: ink)
        icon.image = HelmSymbol.image(symbolName, pointSize: 10, weight: .semibold, hierarchicalColor: ink)
        label.font = .systemFont(ofSize: HelmType.scaled(11.5), weight: .semibold)
        label.textColor = ink
        HelmMotion.withoutActions {
            layer?.borderColor = ink.withAlphaComponent(PopoverHeroHeader.glassBorderAlpha).cgColor
        }
        normalColor = shade.withAlphaComponent(HelmButton.heroFillAlpha)
        hoverColor = shade.withAlphaComponent(HelmButton.heroFillAlpha + 0.06)
    }

    #if FM_SELFTESTS
    var debugTextColor: NSColor? { label.textColor }
    #endif
}

// MARK: - The panel

final class ShiftQuickCaptureController: NSWindowController {

    /// The panel's fixed width - the mockup's own 600pt, which is what six
    /// tiles need before "Credential" starts truncating.
    static let panelWidth: CGFloat = 600

    /// How long a filed capture's confirmation stands in the head before the
    /// panel closes. Unchanged from the status line it replaced.
    static let confirmationHold: TimeInterval = 0.9

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

    /// CP-1: the field in the hero's ink on its dark shade
    /// (`HelmSearchField.heroInk`), led by a plus where a search has its
    /// magnifying glass, as the board draws it.
    private let inputField = HelmSearchField(
        placeholder: "Capture anything - try \u{201C}tomorrow 3pm review deploy notes\u{201D}",
        size: .prominent, symbol: "plus")
    private let head = NSView()
    private let heroSurface = HelmHeroSurface()
    /// The head's working content (the title row, the field, the chips) and
    /// the confirmation that takes its place once a capture is filed.
    private let headContent = NSStackView()
    private let verdictRow = NSStackView()
    private let verdictTile = NSView()
    private let verdictGlyph = NSImageView()
    private let verdictLabel = NSTextField(labelWithString: "")
    private let boltTile = NSView()
    private let boltGlyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Capture")
    private let hotkeyCap = CaptureKeycap("\u{2325}Space")
    private let dateChip = CaptureChip(symbol: "calendar")
    private let clipboardChip = CaptureChip(symbol: "doc.on.clipboard")
    private let chipRow = NSStackView()
    private let sectionLabel = NSTextField(labelWithString: "FILE IT AS")
    private let tileRow = NSStackView()
    private var tiles: [CaptureDestinationTile] = []
    // R2-UX-01 (c): what it does, rather than who does it - the crew is an
    // operator's word, and this panel is everyone's. CP-1 draws it with the
    // sparkle the board gives it, for the same reason.
    private let crewButton = HelmButton(title: "Suggest where it goes",
                                        variant: .quiet, size: .small, symbol: "sparkles")
    private let hintLabel = NSTextField(labelWithString: "")
    /// The body's status line: a refusal (with its warning glyph), or the
    /// crew working (with the kit's inline activity bar).
    private let statusRow = NSStackView()
    private let statusIcon = NSImageView()
    private let statusActivity = HelmProgressBar.inlineActivity(hue: .blue)
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusIsError = false
    private var themeToken: ThemeObservation?
    /// Cleared on every `present()`; set while a crew classification is in
    /// flight so a second click cannot start a second one.
    private var classificationInFlight = false
    /// Set while a filed capture's confirmation stands in the head. A second
    /// Return in those 0.9s used to file the same text a second time.
    private var isConfirming = false

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
        // The head's gradient has to reach the panel's rounded corners, so the
        // window draws no square background of its own behind the content -
        // the palette's arrangement (`UnifiedSearchController.applyTheme`).
        // The shadow is the window's, which follows the content's shape.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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
        AppLockGate.shared.registerSecondaryWindow(owner: self) { [weak self] in self?.window }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    // MARK: Chrome

    /// The board's head and body insets.
    static let headInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
    static let bodyInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
    /// The head's glass bolt tile and the confirmation's glass circle.
    static let boltSide: CGFloat = 22
    static let verdictSide: CGFloat = 30
    static let titleSize: CGFloat = 14
    static let verdictSize: CGFloat = 16

    private func buildUI(in panel: NSPanel) {
        let root = CaptureRootView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 260))
        root.wantsLayer = true
        root.layer?.cornerRadius = HelmMetrics.dSurface
        // The head's gradient is clipped to the panel's rounded top corners.
        root.layer?.masksToBounds = true
        root.onDestinationChord = { [weak self] destination in
            self?.file(to: destination)
            return true
        }
        panel.contentView = root

        inputField.onTextChanged = { [weak self] _ in
            self?.refreshChips()
            self?.resizeToFit()
        }
        inputField.onCommand = { [weak self] selector in self?.handle(command: selector) ?? false }

        buildHead()
        let body = buildBody()

        root.addSubview(head)
        root.addSubview(body)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            head.topAnchor.constraint(equalTo: root.topAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.bodyInsets.left),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.bodyInsets.right),
            body.topAnchor.constraint(equalTo: head.bottomAnchor, constant: Self.bodyInsets.top),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.bodyInsets.bottom),
        ])

        applyTheme(ThemeManager.shared.theme)
        resizeToFit()
    }

    /// The hero head: the gradient, the working content, and the confirmation
    /// laid over it (hidden until a capture is filed).
    private func buildHead() {
        head.translatesAutoresizingMaskIntoConstraints = false
        head.wantsLayer = true
        heroSurface.glowShape = .capsule
        head.addSubview(heroSurface)

        for tile in [boltTile, verdictTile] {
            tile.wantsLayer = true
            tile.layer?.borderWidth = 1
            tile.translatesAutoresizingMaskIntoConstraints = false
        }
        boltTile.layer?.cornerRadius = HelmMetrics.rChip
        verdictTile.layer?.cornerRadius = Self.verdictSide / 2
        for (glyph, tile) in [(boltGlyph, boltTile), (verdictGlyph, verdictTile)] {
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.imageScaling = .scaleNone
            glyph.setAccessibilityElement(false)
            tile.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            ])
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (10)/(12): under `.fill` only the spacer may take the slack.
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [boltTile, titleLabel, spacer, hotkeyCap])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.distribution = .fill
        titleRow.spacing = HelmMetrics.s2
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = HelmMetrics.s2
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        chipRow.addArrangedSubview(dateChip)
        chipRow.addArrangedSubview(clipboardChip)
        clipboardChip.onClick = { [weak self] in self?.insertClipboardText() }
        dateChip.onClick = nil

        // The chip row keeps its height with no chips in it, as the board's
        // `min-height` does, so the head - and the panel - does not jump by a
        // row each time a date is typed or the clipboard empties.
        let chipSlot = NSView()
        chipSlot.translatesAutoresizingMaskIntoConstraints = false
        chipSlot.addSubview(chipRow)

        headContent.orientation = .vertical
        headContent.alignment = .leading
        headContent.spacing = HelmMetrics.s2
        headContent.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleRow, inputField, chipSlot] { headContent.addArrangedSubview(view) }
        headContent.setCustomSpacing(10, after: titleRow)

        verdictLabel.lineBreakMode = .byTruncatingTail
        verdictLabel.translatesAutoresizingMaskIntoConstraints = false
        verdictLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        verdictRow.orientation = .horizontal
        verdictRow.alignment = .centerY
        verdictRow.spacing = HelmMetrics.s3
        verdictRow.translatesAutoresizingMaskIntoConstraints = false
        verdictRow.addArrangedSubview(verdictTile)
        verdictRow.addArrangedSubview(verdictLabel)
        verdictRow.alphaValue = 0

        head.addSubview(headContent)
        head.addSubview(verdictRow)
        let insets = Self.headInsets
        NSLayoutConstraint.activate([
            heroSurface.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            heroSurface.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            heroSurface.topAnchor.constraint(equalTo: head.topAnchor),
            heroSurface.bottomAnchor.constraint(equalTo: head.bottomAnchor),

            headContent.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: insets.left),
            headContent.trailingAnchor.constraint(equalTo: head.trailingAnchor, constant: -insets.right),
            headContent.topAnchor.constraint(equalTo: head.topAnchor, constant: insets.top),
            headContent.bottomAnchor.constraint(equalTo: head.bottomAnchor, constant: -insets.bottom),
            titleRow.widthAnchor.constraint(equalTo: headContent.widthAnchor),
            inputField.widthAnchor.constraint(equalTo: headContent.widthAnchor),
            chipSlot.widthAnchor.constraint(equalTo: headContent.widthAnchor),
            chipSlot.heightAnchor.constraint(equalToConstant: CaptureChip.height),
            chipRow.leadingAnchor.constraint(equalTo: chipSlot.leadingAnchor),
            chipRow.trailingAnchor.constraint(lessThanOrEqualTo: chipSlot.trailingAnchor),
            chipRow.centerYAnchor.constraint(equalTo: chipSlot.centerYAnchor),
            boltTile.widthAnchor.constraint(equalToConstant: Self.boltSide),
            boltTile.heightAnchor.constraint(equalToConstant: Self.boltSide),

            // The confirmation takes the head's place at the head's own
            // height, so the panel does not jump in the moment before it
            // closes.
            verdictRow.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: insets.left + 2),
            verdictRow.trailingAnchor.constraint(lessThanOrEqualTo: head.trailingAnchor, constant: -insets.right),
            verdictRow.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            verdictTile.widthAnchor.constraint(equalToConstant: Self.verdictSide),
            verdictTile.heightAnchor.constraint(equalToConstant: Self.verdictSide),
        ])
    }

    /// The card under the head: the status line, FILE IT AS, the six tiles,
    /// and the footer.
    private func buildBody() -> NSView {
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.setAccessibilityElement(false)

        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = HelmMetrics.s2
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addArrangedSubview(statusIcon)
        statusRow.addArrangedSubview(statusActivity)
        statusRow.addArrangedSubview(statusLabel)
        statusRow.isHidden = true

        tileRow.orientation = .horizontal
        tileRow.alignment = .centerY
        tileRow.spacing = HelmMetrics.s2
        // Gotcha (10): `.gravityAreas` is the default and honours no priority
        // at all, so six equal tiles need `.fillEqually` said out loud.
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

        crewButton.toolTip = AITransparency.willSendToClaude("what you captured")
        crewButton.target = self
        crewButton.action = #selector(askTheCrew)
        crewButton.translatesAutoresizingMaskIntoConstraints = false

        let footerSpacer = NSView()
        footerSpacer.translatesAutoresizingMaskIntoConstraints = false
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [crewButton, footerSpacer, hintLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.spacing = HelmMetrics.s2
        footer.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [statusRow, sectionLabel, tileRow, footer])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s2
        body.setCustomSpacing(10, after: tileRow)
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusRow.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor),
            tileRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            footer.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
        return body
    }

    /// Fit the panel to its content, keeping its top edge where it is.
    ///
    /// `setContentSize` keeps the window's *bottom* edge, so a status line
    /// appearing in the body used to push the head up the screen by a row.
    /// The panel is placed by its top edge (`present`), and that is the edge
    /// that holds.
    private func resizeToFit() {
        guard let window, let root = window.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height
        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        guard abs(content.height - height) > 0.5 || abs(content.width - Self.panelWidth) > 0.5 else { return }
        let target = window.frameRect(forContentRect: NSRect(x: frame.minX, y: frame.maxY - height,
                                                             width: Self.panelWidth, height: height))
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - target.height,
                               width: target.width, height: target.height), display: true)
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
        hideStatus()
        resetHead()
        // The captain's own chord, which Settings > Capture records - the head
        // names the key that opened it.
        hotkeyCap.text = AppSettings.shared.quickCaptureShortcut.displayString
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
        isOpen = true
        window.makeKeyAndOrderFront(nil)
        HelmMotion.fadeIn(window: window)
        inputField.focusEditor()
    }

    /// Open as far as this controller is concerned - set at once by
    /// `present`/`dismiss`, while the fade-out (P3) is still drawing.
    private var isOpen = false

    /// The one way out, from every path (Escape, a hand-off, a filed capture's
    /// confirmation). P3 of the polish report: fades rather than vanishing,
    /// and orders out once the fade lands unless the captain reopened it.
    private func dismiss() {
        guard let window else { return }
        isOpen = false
        HelmMotion.fadeOut(window: window, stillClosed: { [weak self] in self?.isOpen == false }) { [weak window] in
            window?.orderOut(nil)
        }
    }

    // MARK: The chips and the light

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
        // where Return will file before pressing it. CP-1 lights it.
        light(CaptureRouter.defaultDestination(for: draft))
    }

    /// Light the tile for `destination`, and only that one.
    private func light(_ destination: CaptureDestination) {
        for tile in tiles where tile.isDefault != (tile.destination == destination) {
            tile.isDefault = tile.destination == destination
        }
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
        // Asked before the string is read (R2-SEC-03's source guard).
        guard !CredentialVaultClipboard.isConcealed(NSPasteboard.general),
              let raw = NSPasteboard.general.string(forType: .string) else { return }
        let existing = inputField.stringValue
        inputField.stringValue = existing.isEmpty
            ? raw
            : existing + (existing.hasSuffix("\n") ? "" : "\n") + raw
        refreshChips()
        inputField.focusEditor()
    }

    // MARK: Filing

    /// The field editor's command keys, through `HelmSearchField.onCommand`.
    private func handle(command commandSelector: Selector) -> Bool {
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
            dismiss()
            return true
        default:
            return false
        }
    }

    /// File what is typed to `destination`. The one implementation every entry
    /// point (Return, a chord, a tile click, the crew's answer) goes through.
    func file(to destination: CaptureDestination) {
        // The confirmation is standing and the panel is about to close: a
        // second Return here would file the same words twice.
        guard !isConfirming else { return }
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
            dismiss()
        case .refused(let why):
            show(status: why, isError: true)
            // The light shows where Return files. A refused crew pick hands it
            // back to the tile Return would use.
            light(CaptureRouter.defaultDestination(for: draft))
        }
    }

    /// CP-1: the head becomes the confirmation, holds, and the panel closes.
    private func finish(with message: String) {
        hideStatus()
        showVerdict(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmationHold) { [weak self] in
            self?.dismiss()
        }
    }

    /// Swap the head's content for the confirmation. A short cross-fade, and
    /// under Reduce Motion the swap alone (`HelmMotion.fade`).
    private func showVerdict(_ message: String) {
        isConfirming = true
        verdictLabel.stringValue = message
        verdictRow.setAccessibilityLabel(message)
        HelmMotion.fade(headContent, to: 0, duration: HelmMotion.stateDuration, animated: true)
        HelmMotion.fade(verdictRow, to: 1, duration: HelmMotion.stateDuration, animated: true)
    }

    private func resetHead() {
        isConfirming = false
        headContent.alphaValue = 1
        verdictRow.alphaValue = 0
    }

    private func show(status: String, isError: Bool) {
        statusIsError = isError
        statusLabel.stringValue = status
        statusRow.isHidden = false
        paintStatus(ThemeManager.shared.theme)
        resizeToFit()
    }

    private func hideStatus() {
        guard !statusRow.isHidden else { return }
        statusRow.isHidden = true
        statusActivity.isRunning = false
        resizeToFit()
    }

    /// A refusal reads in the theme's critical hue, legible on the card, with
    /// a warning glyph. The crew working reads muted, with the kit's inline
    /// activity bar (which holds still under Reduce Motion on its own).
    private func paintStatus(_ theme: HelmTheme) {
        let card = HelmTheme.nsColor(theme.chromeBackgroundHex)
        statusLabel.font = .systemFont(ofSize: HelmType.scaled(12), weight: .medium)
        if statusIsError {
            let red = HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme), over: card, theme: theme)
            statusLabel.textColor = red
            // One colour, the words' own: a hierarchical symbol draws its
            // secondary layers lighter, which read as a pale triangle beside
            // red words in the first render.
            statusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: HelmType.scaled(11), weight: .semibold))
            statusIcon.contentTintColor = red
            statusIcon.isHidden = false
            statusActivity.isRunning = false
            statusActivity.isHidden = true
        } else {
            statusLabel.textColor = HelmTheme.mutedInk(theme)
            statusIcon.isHidden = true
            statusActivity.isRunning = classificationInFlight
            statusActivity.isHidden = !classificationInFlight
        }
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
        show(status: "Working out where it goes\u{2026}", isError: false)

        let done: (CaptureDestination?) -> Void = { [weak self] destination in
            guard let self else { return }
            self.classificationInFlight = false
            self.crewButton.isEnabled = true
            guard let destination else {
                // GL-14's shape: "the crew could not say" is not "file it as a
                // task". The captain stays in the loop with the text intact.
                self.show(status: "Couldn\u{2019}t work out where it goes - pick a destination.",
                          isError: true)
                return
            }
            self.hideStatus()
            // The light moves to the crew's pick before it files, so the
            // confirmation stands over the tile it went to.
            self.light(destination)
            self.file(to: destination)
        }

        if let classifier {
            classifier(draft.text, done)
            return
        }
        guard let executable = ClaudeOneShot.resolve() else {
            classificationInFlight = false
            crewButton.isEnabled = true
            show(status: "Suggesting a place needs the claude CLI on PATH.", isError: true)
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

    /// The head's palette: the theme's hero colour through the quiet-ink rule
    /// the hero columns, the toasts and the lit tile use.
    static func palette(in theme: HelmTheme) -> HelmHeroSurface.Palette {
        HelmHeroColumn.palette(for: HelmModuleCard.HeroTone(colour: .themeAccent), in: theme)
    }

    private func applyTheme(_ theme: HelmTheme) {
        let muted = HelmTheme.mutedInk(theme)
        guard let root = window?.contentView else { return }
        // `ThemeManager.swift`'s checklist item 2: force the appearance, or
        // everything resolving a system semantic colour - the shared field
        // editor very much included, and this panel is one big field - follows
        // the OS rather than the theme.
        root.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        root.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor

        let palette = Self.palette(in: theme)
        let ink = HelmContrast.color(palette.ink)
        heroSurface.apply(palette)
        // A white-ink hero is a dark surface: the field's caret and selection,
        // and any system colour in the head, take the dark appearance's.
        let darkInk = HelmContrast.relativeLuminance(palette.ink) < 0.5
        head.appearance = NSAppearance(named: darkInk ? .aqua : .darkAqua)
        inputField.heroInk = ink
        for tile in [boltTile, verdictTile] {
            tile.layer?.backgroundColor = ink.withAlphaComponent(PopoverHeroHeader.glassFillAlpha).cgColor
            tile.layer?.borderColor = ink.withAlphaComponent(PopoverHeroHeader.glassBorderAlpha).cgColor
        }
        boltGlyph.image = HelmSymbol.image("bolt.fill", pointSize: 12, weight: .semibold, hierarchicalColor: ink)
        verdictGlyph.image = HelmSymbol.image("checkmark", pointSize: 15, weight: .bold, hierarchicalColor: ink)
        titleLabel.font = HelmType.rounded(HelmType.scaled(Self.titleSize), .bold)
        titleLabel.textColor = ink
        verdictLabel.font = HelmType.rounded(HelmType.scaled(Self.verdictSize), .bold)
        verdictLabel.textColor = ink
        hotkeyCap.paint(fill: ink.withAlphaComponent(PopoverHeroHeader.glassFillAlpha),
                        border: ink.withAlphaComponent(PopoverHeroHeader.glassBorderAlpha), ink: ink)
        dateChip.paint(heroInk: ink)
        clipboardChip.paint(heroInk: ink)

        sectionLabel.attributedStringValue = NSAttributedString(
            string: "FILE IT AS", attributes: HelmType.kickerAttributes(color: muted))
        hintLabel.font = .systemFont(ofSize: HelmType.scaled(11))
        hintLabel.textColor = muted
        hintLabel.stringValue = CaptureHeroWords.hint
        paintStatus(theme)
        for tile in tiles { tile.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    /// The six real tiles, in display order - so a suite can read what the
    /// panel shows and drive a real click through each tile's own `onClick`.
    var debugTiles: [CaptureDestinationTile] { tiles }
    var debugInputField: HelmSearchField { inputField }
    /// The body's status line, while it shows.
    var debugStatusText: String? { statusRow.isHidden ? nil : statusLabel.stringValue }
    var debugStatusIsError: Bool { statusIsError }
    var debugStatusColor: NSColor? { statusLabel.textColor }
    /// The confirmation standing in the head, while it does.
    var debugVerdictText: String? { isConfirming ? verdictLabel.stringValue : nil }
    var debugHeadContentAlpha: CGFloat { headContent.alphaValue }
    var debugVerdictAlpha: CGFloat { verdictRow.alphaValue }
    var debugHintText: String { hintLabel.stringValue }
    var debugHeadPalette: HelmHeroSurface.Palette? { heroSurface.palette }
    var debugHeadGradient: [CGColor] { heroSurface.debugGradientColors }
    var debugHeadView: NSView { head }
    var debugTitleColor: NSColor? { titleLabel.textColor }
    var debugHotkeyText: String { hotkeyCap.text }
    var debugChips: [CaptureChip] { [dateChip, clipboardChip] }
    var debugDateChipText: String? { dateChip.isHidden ? nil : dateChip.text }
    var debugClipboardChipText: String? { clipboardChip.isHidden ? nil : clipboardChip.text }
    var debugRootView: CaptureRootView? { window?.contentView as? CaptureRootView }
    func debugSetText(_ text: String) {
        inputField.stringValue = text
        refreshChips()
    }
    /// Return, through the field's own command path.
    func debugPressReturn() { _ = handle(command: #selector(NSResponder.insertNewline(_:))) }
    func debugResetHead() { resetHead() }

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
