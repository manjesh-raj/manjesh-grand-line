// Manjesh Grand Line - native macOS app.
//
// `HelmDrillHeader` - the back affordance every drill page gets (Daylight
// migration §5.2's last bullet, §6.4).
//
// **Where it lives, and why that is the whole point.** This is a *shell*
// header, owned by `AppShellController` and sitting between the floating bar
// and the body container - not a header each destination builds for itself.
// One view therefore gives all fifteen destinations a working back button, a
// domain-hued tile and a live title, without editing a single destination
// controller. That matters for two reasons:
//
//   1. §5.1's survives list is explicit that `DestinationRegistry`'s
//      permanent-mount model does not change. A drill page is still exactly
//      the mounted destination view it was; this only pins it
//      `HelmDrillHeader.height` further down.
//   2. Restyling each page's own header chrome (its in-page hero titles, its
//      action clusters) is **Phase 4**, in §7's table order. Doing it here
//      would mean touching every destination in the shell phase, which is how
//      a structural migration turns into an unreviewable diff.
//
// So the version here is §6.4's row minus the per-page action cluster: back
// button, tile, title, subtitle. Phase 4 moves each page's own primary/quiet
// actions into the trailing slot this leaves room for.
//
// **The canvas has no drill header**, by definition - it is the hub, not a
// spoke. `AppShellController` collapses this to zero height there, and
// collapsing means `isHidden` *and* a zero height constraint: an ordinary
// hidden `NSView`'s constraints still participate fully in Auto Layout
// (AGENTS.md gotcha (11)), so hiding alone would leave a 56pt gap above the
// canvas.

import AppKit

final class HelmDrillHeader: NSView {

    /// §6.4's row height: a 36pt back button plus breathing room above and
    /// below, matching §2.7's 20pt top margin under the bar region.
    static let height: CGFloat = 56
    /// §6.4's back button: 36pt, radius 14, card fill, hair border.
    static let backButtonSide: CGFloat = 36

    /// The back action - `AppShellController` wires it to `show(.homeCanvas)`,
    /// which is what preserves the canvas's last-selected space (the canvas
    /// owns that state and is never rebuilt).
    var onBack: (() -> Void)?

    private let backButton = HoverHighlightView()
    private let backGlyph = NSImageView()
    private let tile = HelmGradientTile(size: .drill)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        backGlyph.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        backGlyph.translatesAutoresizingMaskIntoConstraints = false

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.cornerRadius = HelmMetrics.dWell
        backButton.wantsLayer = true
        backButton.layer?.borderWidth = 1
        backButton.addSubview(backGlyph)
        backButton.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(backClicked)))
        backButton.accessibilityLabelOverride = "Back to home"
        backButton.toolTip = "Back to home"
        backButton.setContentHuggingPriority(.required, for: .horizontal)
        backButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = HelmType.drillTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = HelmType.caption()
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (13): a title's own >500 compression resistance is a
        // window-width floor, and this header sits above every destination.
        for label in [titleLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        addSubview(backButton)
        addSubview(tile)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.pageGutter),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: Self.backButtonSide),
            backButton.heightAnchor.constraint(equalToConstant: Self.backButtonSide),
            backGlyph.centerXAnchor.constraint(equalTo: backButton.centerXAnchor),
            backGlyph.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            tile.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: HelmMetrics.s3),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HelmMetrics.s3),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                constant: -HelmMetrics.pageGutter),
        ])

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// Point the header at a destination. `subtitle` is optional live detail
    /// the shell already knows (a host page's label, for instance).
    func configure(title: String, subtitle: String, symbol: String, hue: HelmDomainHue) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        tile.configure(symbol: symbol, hue: hue)
    }

    @objc private func backClicked() { onBack?() }

    private func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)

        layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        backButton.normalColor = surface
        backButton.hoverColor = theme.isDaylight
            ? HelmTheme.nsColor(DaylightPalette.inset)
            : line.withAlphaComponent(0.5)
        backButton.layer?.borderColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.6).cgColor
        backGlyph.contentTintColor = ink

        titleLabel.font = HelmType.drillTitle()
        titleLabel.textColor = ink
        subtitleLabel.font = HelmType.caption()
        subtitleLabel.textColor = muted
    }

    // MARK: Probe / self-test surface

    var titleForTests: String { titleLabel.stringValue }
    var subtitleForTests: String { subtitleLabel.stringValue }

    /// Fires the real back path a click or a VoiceOver press would.
    @discardableResult
    func debugActivateBack() -> Bool { backButton.performPrimaryAction() }
}
