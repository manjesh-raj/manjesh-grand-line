// Grand Line - native macOS app.
//
// One cell of the Appearance page's theme grid: a miniature of the app drawn
// in a palette's own tokens, its name, and a checkmark when it is the active
// one.
//
// `fm/grandline-settings-page-redesign`. The card this replaces was three
// equal-width swatches (`backgroundHex` / `chromeBackgroundHex` /
// `accentHex`) in a strip, which tells a captain what colours a theme
// contains but not what the app *looks like* in it - and the difference
// between two palettes with the same three hues in different roles is exactly
// what a picker has to show. The captain's reference draws a small window
// instead: a sidebar column with a selected row, two lines of content, and a
// card with an accent chip. Every value below is read from the `HelmTheme`
// being previewed, so the miniature is the palette rather than a picture of
// one.
//
// **Five tokens, in the roles the app really puts them in**:
//
//   `backgroundHex`        the page ground, behind everything
//   `chromeBackgroundHex`  the sidebar and the card - the app's own surfaces
//   `chromeInkHex`         the text lines
//   `accentHex`            the selected sidebar row and the card's chip
//   `chromeLineHex`        the card's hairline against the ground
//
// Which is also why this is a view rather than a `layer.contents` image: the
// grid re-flows on a window resize (`HelmResponsiveGrid`), and a raster would
// have to be re-rendered per column count.

import AppKit

final class SettingsThemeCard: NSView {

    /// The preview's height. Enough for a sidebar column, two content lines
    /// and a card to read as three distinct things at this width - below
    /// about 56 the card and the second line merge.
    static let previewHeight: CGFloat = 68
    let theme: HelmTheme
    private(set) var isActive: Bool

    let nameLabel = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private let preview = NSView()

    /// Fired on a real click, a keyboard press or a VoiceOver activation.
    /// The card's chrome is a `HoverHighlightView`, so the hover fill, the
    /// pressed state, the focus ring and the announced role all come from
    /// that one component (GL-16) rather than from a plain view wearing a
    /// gesture recognizer.
    var onSelect: (() -> Void)?

    let hoverView = HoverHighlightView()

    init(theme: HelmTheme, isActive: Bool) {
        self.theme = theme
        self.isActive = isActive
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        preview.wantsLayer = true
        preview.layer?.cornerRadius = HelmMetrics.rControl
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)

        // The sidebar column: the app's chrome surface, with a selected row in
        // the accent and three resting rows in damped ink. 30% of the width,
        // which is what the reference draws and roughly what this app's own
        // 208pt column is against a page.
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = surface.cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(sidebar)

        let sidebarRows = NSStackView(views: (0..<4).map { index in
            Self.bar(color: index == 0 ? accent : ink.withAlphaComponent(0.35), height: 3)
        })
        sidebarRows.orientation = .vertical
        sidebarRows.alignment = .leading
        sidebarRows.distribution = .fillEqually
        sidebarRows.spacing = 4
        sidebarRows.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarRows)

        // The content column: two text lines and a card carrying an accent
        // chip, which is what every page in this app actually is.
        let line1 = Self.bar(color: ink.withAlphaComponent(0.85), height: 3)
        let line2 = Self.bar(color: ink.withAlphaComponent(0.4), height: 3)

        let miniCard = NSView()
        miniCard.wantsLayer = true
        miniCard.layer?.backgroundColor = surface.cgColor
        miniCard.layer?.cornerRadius = 3
        miniCard.layer?.borderWidth = 1
        miniCard.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        miniCard.translatesAutoresizingMaskIntoConstraints = false

        let chip = Self.bar(color: accent, height: 6)
        chip.layer?.cornerRadius = 3
        miniCard.addSubview(chip)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(line1)
        content.addSubview(line2)
        content.addSubview(miniCard)
        preview.addSubview(content)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: preview.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
            sidebar.widthAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 0.3),

            sidebarRows.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 5),
            sidebarRows.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -5),
            sidebarRows.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 7),

            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            content.topAnchor.constraint(equalTo: preview.topAnchor),
            content.bottomAnchor.constraint(equalTo: preview.bottomAnchor),

            line1.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 7),
            line1.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            line1.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.66),

            line2.leadingAnchor.constraint(equalTo: line1.leadingAnchor),
            line2.topAnchor.constraint(equalTo: line1.bottomAnchor, constant: 5),
            line2.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.42),

            miniCard.leadingAnchor.constraint(equalTo: line1.leadingAnchor),
            miniCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -7),
            miniCard.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -7),
            miniCard.heightAnchor.constraint(equalToConstant: 17),

            chip.trailingAnchor.constraint(equalTo: miniCard.trailingAnchor, constant: -4),
            chip.centerYAnchor.constraint(equalTo: miniCard.centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 12),

            preview.heightAnchor.constraint(equalToConstant: Self.previewHeight),
        ])

        nameLabel.stringValue = theme.name
        nameLabel.font = .systemFont(ofSize: HelmType.scaled(11), weight: isActive ? .semibold : .regular)
        nameLabel.lineBreakMode = .byTruncatingTail
        // Otherwise the longest name's own compression resistance beats the
        // grid row's `.fillEqually` distribution and that one card comes out
        // wider than its siblings - measured at 130pt against 107 before the
        // card this replaces was fixed the same way.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        check.image = HelmSymbol.image("checkmark.circle.fill", pointSize: 11, weight: .regular)
        check.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        check.isHidden = !isActive
        check.translatesAutoresizingMaskIntoConstraints = false
        check.setContentHuggingPriority(.required, for: .horizontal)

        let nameRow = NSStackView(views: [nameLabel, check])
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = HelmMetrics.s1
        // Gotcha (10): the checkmark belongs at the row's trailing edge, not
        // wherever the name happens to end.
        nameRow.distribution = .fill
        nameRow.translatesAutoresizingMaskIntoConstraints = false

        hoverView.cornerRadius = HelmMetrics.rControl
        hoverView.translatesAutoresizingMaskIntoConstraints = false
        hoverView.accessibilityRoleOverride = .radioButton
        hoverView.accessibilityLabelOverride = theme.name
        // A real click recognizer plus the accessibility press hook, which is
        // this app's established shape for a clickable `HoverHighlightView` -
        // the recognizer covers the mouse, `onAccessibilityPress` covers
        // VoiceOver and the keyboard, and both land on the same closure.
        hoverView.addGestureRecognizer(NSClickGestureRecognizer(target: self,
                                                                action: #selector(cardClicked)))
        hoverView.onAccessibilityPress = { [weak self] in self?.onSelect?() }

        let column = NSStackView(views: [preview, nameRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s1 + 1
        column.translatesAutoresizingMaskIntoConstraints = false
        hoverView.addSubview(column)
        addSubview(hoverView)

        NSLayoutConstraint.activate([
            hoverView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hoverView.topAnchor.constraint(equalTo: topAnchor),
            hoverView.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: hoverView.leadingAnchor, constant: 4),
            column.trailingAnchor.constraint(equalTo: hoverView.trailingAnchor, constant: -4),
            column.topAnchor.constraint(equalTo: hoverView.topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: hoverView.bottomAnchor, constant: -4),
            preview.widthAnchor.constraint(equalTo: column.widthAnchor),
            nameRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    @objc private func cardClicked() { onSelect?() }

    private static func bar(color: NSColor, height: CGFloat) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = height / 2
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    /// The selected ring, the name's weight and the checkmark, in the colours
    /// of the theme the grid is currently *in* - which is not the theme this
    /// card previews.
    ///
    /// The distinction is the whole reason this takes a parameter: the ring
    /// and the resting fill have to read against the card the grid sits on
    /// (the active palette's surface), while everything inside the preview is
    /// drawn in the previewed palette's own tokens and never moves.
    func applyTheme(_ current: HelmTheme) {
        hoverView.layer?.masksToBounds = true
        hoverView.layer?.borderWidth = isActive ? 2 : 1
        hoverView.layer?.borderColor = (isActive
            ? HelmTheme.nsColor(current.accentHex)
            : HelmTheme.nsColor(current.chromeLineHex).withAlphaComponent(0.6)).cgColor
        hoverView.normalColor = isActive
            ? HelmTheme.nsColor(current.accentHex).withAlphaComponent(0.08)
            : (current.isDaylight ? HelmField.fill(current) : .clear)
        hoverView.hoverColor = current.isDaylight
            ? HelmTheme.nsColor(current.daylightTokens.rowHover)
            : HelmTheme.nsColor(current.chromeLineHex).withAlphaComponent(0.22)
        nameLabel.textColor = HelmTheme.nsColor(current.chromeInkHex)
    }
}
