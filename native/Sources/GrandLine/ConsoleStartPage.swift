// Grand Line - native macOS app.
//
// UX-11 of the 2026-11-25 full review: the Console opens on a start page, not
// an empty box. With no shell open the page was an empty card, and the way
// to start was a small Connect in the band's corner. Now the card holds
// three ways to start - a new shell on this Mac, the hosts connected to most
// recently, and the captain's snippets - and Return opens the first.
//
// A snippet is typed into a new shell without its Return, so nothing runs
// that the captain did not send.

import AppKit

/// What the start page offers, as values. Pure, so the choice of hosts and
/// snippets is asserted in CI's blocking lane.
enum ConsoleStartWords {
    struct HostTile: Equatable {
        let id: UUID
        let title: String
        let detail: String
    }

    static let hostLimit = 3
    static let snippetLimit = 4

    /// The hosts connected to most recently, newest first: the ones the
    /// captain connects to.
    static func hosts(_ hosts: [Host], now: Date = Date()) -> [HostTile] {
        hosts.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(hostLimit)
            .map { HostTile(id: $0.id, title: $0.label,
                            detail: "connected " + HostsController.relativeText($0.lastConnectedAt ?? now, now: now)) }
    }

    /// The snippets Console can run, in the captain's own order.
    static func snippets(_ snippets: [Snippet]) -> [Snippet] {
        Array(snippets.prefix(snippetLimit))
    }

    /// The shell a new tab runs, by name: "zsh".
    static var shellName: String {
        let path = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return (path as NSString).lastPathComponent
    }
}

final class ConsoleStartPage: NSView {
    var onNewShell: (() -> Void)?
    var onHost: ((UUID) -> Void)?
    var onSnippet: ((Snippet) -> Void)?

    private let title = NSTextField(labelWithString: "Start a session")
    private let subtitle = NSTextField(labelWithString: "Return opens the first one.")
    private let tilesRow = NSStackView()
    private let snippetsTitle = NSTextField(labelWithString: "SNIPPETS")
    private let snippetsRow = NSStackView()
    private var tiles: [(view: HoverHighlightView, title: NSTextField, detail: NSTextField, icon: NSImageView)] = []
    private var tileActions: [() -> Void] = []
    private var snippetButtons: [HelmButton] = []
    private var snippets: [Snippet] = []
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = HelmMetrics.rCard
        title.font = .systemFont(ofSize: HelmType.scaled(17), weight: .bold)
        subtitle.font = HelmType.caption()
        snippetsTitle.font = HelmType.kicker()
        tilesRow.orientation = .horizontal
        tilesRow.spacing = HelmMetrics.s3
        tilesRow.distribution = .fillEqually
        tilesRow.alignment = .top
        snippetsRow.orientation = .horizontal
        snippetsRow.spacing = HelmMetrics.s2
        let column = NSStackView(views: [title, subtitle, tilesRow, snippetsTitle, snippetsRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s1
        column.setCustomSpacing(HelmMetrics.s4, after: subtitle)
        column.setCustomSpacing(HelmMetrics.s5, after: tilesRow)
        column.setCustomSpacing(HelmMetrics.s2, after: snippetsTitle)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s6),
            column.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s6),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.s6),
            tilesRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        let preferred = column.widthAnchor.constraint(equalToConstant: Self.maxWidth)
        preferred.priority = HelmDaylightPriority.contentTie
        preferred.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Start a session")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static let maxWidth: CGFloat = 860
    static let minimumColumns = 3

    /// The tiles and the snippets, rebuilt only when they change.
    func configure(hosts: [ConsoleStartWords.HostTile], snippets: [Snippet]) {
        for view in tilesRow.arrangedSubviews { tilesRow.removeArrangedSubview(view); view.removeFromSuperview() }
        tiles = []
        tileActions = []
        addTile(symbol: "terminal", title: "New shell on this Mac", detail: "\(ConsoleStartWords.shellName) \u{00B7} \u{21A9}") { [weak self] in
            self?.onNewShell?()
        }
        for host in hosts {
            addTile(symbol: "server.rack", title: host.title, detail: host.detail) { [weak self] in self?.onHost?(host.id) }
        }
        // At least three to a row, so a short list does not stretch its tiles.
        for _ in tiles.count..<max(Self.minimumColumns, tiles.count) { tilesRow.addArrangedSubview(NSView()) }
        self.snippets = snippets
        for view in snippetsRow.arrangedSubviews { snippetsRow.removeArrangedSubview(view); view.removeFromSuperview() }
        snippetButtons = snippets.enumerated().map { index, snippet in
            let button = HelmButton(title: snippet.label, variant: .secondary, size: .small, symbol: "text.insert",
                                    target: self, action: #selector(snippetTapped(_:)))
            button.tag = index
            button.toolTip = "Type \u{201C}\(snippet.command)\u{201D} into a new shell"
            snippetsRow.addArrangedSubview(button)
            return button
        }
        snippetsTitle.isHidden = snippets.isEmpty
        snippetsRow.isHidden = snippets.isEmpty
        applyTheme(theme)
    }

    private func addTile(symbol: String, title: String, detail: String, action: @escaping () -> Void) {
        let tile = HoverHighlightView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.cornerRadius = HelmMetrics.rRow
        tile.accessibilityRoleOverride = .button
        tile.accessibilityLabelOverride = "\(title), \(detail)"
        let icon = NSImageView(image: HelmSymbol.image(symbol, pointSize: HelmType.scaled(13), weight: .medium) ?? NSImage())
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(14), weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = HelmType.caption()
        detailLabel.lineBreakMode = .byTruncatingTail
        for view in [icon, titleLabel, detailLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(view)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inset = HelmMetrics.s4
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: inset),
            icon.topAnchor.constraint(equalTo: tile.topAnchor, constant: inset),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: tile.trailingAnchor, constant: -inset),
            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: HelmMetrics.s3),
            detailLabel.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: tile.trailingAnchor, constant: -inset),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -inset),
        ])
        // GL-16: the click recognizer is also Return, Space and VoiceOver's press.
        tile.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tileClicked(_:))))
        tilesRow.addArrangedSubview(tile)
        tiles.append((tile, titleLabel, detailLabel, icon))
        tileActions.append(action)
    }

    @objc private func tileClicked(_ sender: NSClickGestureRecognizer) {
        guard let tile = sender.view, let index = tiles.firstIndex(where: { $0.view === tile }) else { return }
        tileActions[index]()
    }

    @objc private func snippetTapped(_ sender: HelmButton) {
        guard snippets.indices.contains(sender.tag) else { return }
        onSnippet?(snippets[sender.tag])
    }

    /// Return opens the first tile: a new shell.
    func openFirst() { tileActions.first?() }

    override var acceptsFirstResponder: Bool { !isHidden }

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter.
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection(KeyChord.relevantModifierMask).isEmpty {
            openFirst()
            return
        }
        super.keyDown(with: event)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        // The card's own colour, as a terminal fills it when a tab is open.
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        title.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitle.textColor = HelmTheme.mutedInk(theme)
        snippetsTitle.textColor = HelmTheme.mutedInk(theme)
        let fill = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        for (index, tile) in tiles.enumerated() {
            HelmCard.applyCardSurface(to: tile.view, theme: theme, cornerRadius: HelmMetrics.rRow,
                                      daylightRadius: HelmMetrics.rRow)
            tile.view.normalColor = fill
            tile.view.hoverColor = fill.blended(withFraction: 0.06, of: accent) ?? fill
            // The first tile is what Return opens, so it wears the accent edge.
            if index == 0 { tile.view.layer?.borderColor = accent.cgColor; tile.view.layer?.borderWidth = 1.5 }
            tile.title.textColor = HelmTheme.nsColor(theme.chromeInkHex)
            tile.detail.textColor = HelmTheme.mutedInk(theme)
            tile.icon.contentTintColor = HelmContrast.legibleOn(fill: fill, preferring: accent,
                                                                target: HelmContrast.nonTextTarget)
        }
    }

    #if FM_SELFTESTS
    var debugTileTitles: [String] { tiles.map(\.title.stringValue) }
    var debugSnippetTitles: [String] { snippetButtons.map(\.title) }
    func debugClickTile(_ index: Int) { if tileActions.indices.contains(index) { tileActions[index]() } }
    func debugClickSnippet(_ index: Int) { if snippetButtons.indices.contains(index) { snippetButtons[index].performClick(nil) } }
    #endif
}
