// Grand Line - native macOS app.
//
// Con-1 of the Console / Add Host / Add Key board (Helm 9.2.0): the hero band
// across the top of a Console page. It says where the terminal below is - this
// Mac's local shells, or a host's ssh session - with its live state and its
// shell and folder, and carries one chip per live session, so switching to or
// ending a session is a click from any Console page.
//
// B2 of the Console fixes board (`fm/grandline-console-fixes`) made it one
// line, 40pt tall: where the terminal is and its live state in plain words
// ("This Mac · no ssh sessions", "prod-db · Connected · ops@10.0.4.12"),
// and the chips. The captain found the three-line band confusing: its tab
// count repeated the tab strip right under it, and its "zsh · ~" line
// repeated the shell's own prompt.
//
// It replaces the sidebar layout's SESSIONS strip, which listed the same
// sessions in a separate row. The floating bar keeps that strip, under its bar
// on every page. Like the strip, the band reads `HostSessionRegistry` and
// stores nothing of its own, and it hands every decision back through a
// router (`ConsoleSessionBandRouting`): the page knows nothing about
// navigation or about ending a session.

import AppKit

/// What a Console page asks of the shell for its band.
protocol ConsoleSessionBandRouting: AnyObject {
    var bandSessions: HostSessionRegistry { get }
    func bandSwitch(toSession hostID: UUID)
    func bandEndSession(_ hostID: UUID)
    func bandShowThisMac()
    func bandConnect()
}

final class ConsoleSessionBand: NSView {
    /// The words and the place, from the page that owns the band.
    struct Content: Equatable {
        /// Where: "This Mac", or the host's name.
        var title: String
        /// Its state: "no ssh sessions", or "Connected · ops@host".
        var detail: String
        /// `nil` for this Mac; a host's accent for a host page.
        var tileAccentHex: String?
        /// The host whose page this is, so its chip is the lit one.
        var currentHostID: UUID?
        /// Whether to offer a chip back to this Mac's shells.
        var showsThisMac: Bool
    }

    struct Chip: Equatable {
        let hostID: UUID
        let label: String
        let accentHex: String?
        let shortcut: Int?
        let connected: Bool
    }

    var onSwitch: ((UUID) -> Void)?
    var onEnd: ((UUID) -> Void)?
    var onShowThisMac: (() -> Void)?
    var onConnect: (() -> Void)?

    /// B2: one line of words and the chips' 28pt with a 6pt margin.
    static let height: CGFloat = 40

    private let hero = HelmHeroSurface()
    private let tile = IconTileView(size: 24, cornerRadius: 7)
    private let titleLabel = NSTextField(labelWithString: "")
    private let chipRow = NSStackView()
    private var chipViews: [(chip: Chip?, view: HoverHighlightView, label: NSTextField, close: NSButton?)] = []
    private(set) var content = Content(title: "", detail: "", tileAccentHex: nil,
                                       currentHostID: nil, showsThisMac: false)
    private(set) var chips: [Chip] = []
    private var observation: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        addSubview(hero)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = titleLabel
        text.translatesAutoresizingMaskIntoConstraints = false
        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = HelmMetrics.s2
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        tile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        addSubview(text)
        addSubview(chipRow)
        // Three pieces pinned by hand rather than one stack: the words take
        // whatever width the chips leave, and the chips keep their own. A
        // stack row gave the slack to the chip row, which has no intrinsic
        // width, so one chip stretched across the band (gotcha (12)).
        let chipsCollapse = chipRow.widthAnchor.constraint(equalToConstant: 0)
        chipsCollapse.priority = NSLayoutConstraint.Priority(240)
        NSLayoutConstraint.activate([
            hero.leadingAnchor.constraint(equalTo: leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: trailingAnchor),
            hero.topAnchor.constraint(equalTo: topAnchor),
            hero.bottomAnchor.constraint(equalTo: bottomAnchor),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HelmMetrics.s2 + 2),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: chipRow.leadingAnchor, constant: -HelmMetrics.s3),
            chipRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(HelmMetrics.s1 + 2)),
            chipRow.centerYAnchor.constraint(equalTo: centerYAnchor),
            chipRow.leadingAnchor.constraint(greaterThanOrEqualTo: centerXAnchor, constant: -60),
            chipsCollapse,
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        observation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
    }

    /// The live sessions, in the registry's order, with their ⌃⌘ numbers.
    static func chips(from registry: HostSessionRegistry) -> [Chip] {
        registry.sessions.map {
            Chip(hostID: $0.hostID, label: $0.label, accentHex: $0.accentHex,
                 shortcut: registry.shortcutIndex(for: $0.hostID), connected: $0.isConnected)
        }
    }

    func update(_ content: Content, chips: [Chip]) {
        guard content != self.content || chips != self.chips || chipViews.isEmpty else { return }
        let rebuild = chipViews.isEmpty || chips != self.chips || content.currentHostID != self.content.currentHostID
            || content.showsThisMac != self.content.showsThisMac
        self.content = content
        self.chips = chips
        if rebuild { rebuildChips() }
        applyTheme(ThemeManager.shared.theme)
    }

    private func rebuildChips() {
        chipViews.forEach { $0.view.removeFromSuperview() }
        chipViews = []
        if content.showsThisMac {
            chipViews.append(makeChip(nil, title: "This Mac", symbol: "terminal"))
        }
        for chip in chips {
            chipViews.append(makeChip(chip, title: chip.label, symbol: nil))
        }
        chipViews.append(makeChip(nil, title: chips.isEmpty ? "Connect a host" : "Connect", symbol: "plus", isConnect: true))
    }

    private func makeChip(_ chip: Chip?, title: String, symbol: String?, isConnect: Bool = false)
        -> (chip: Chip?, view: HoverHighlightView, label: NSTextField, close: NSButton?) {
        let view = HoverHighlightView()
        view.wantsLayer = true
        view.cornerRadius = 14
        view.translatesAutoresizingMaskIntoConstraints = false
        var parts: [NSView] = []
        if let symbol {
            let glyph = NSImageView()
            glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: HelmType.scaled(10.5), weight: .semibold))
            glyph.identifier = NSUserInterfaceItemIdentifier("glyph")
            parts.append(glyph)
        } else if let chip {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = HelmMetrics.s1
            dot.layer?.backgroundColor = HelmTheme.nsColor(chip.accentHex ?? "A0A4B0").cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: HelmMetrics.s2).isActive = true
            dot.heightAnchor.constraint(equalToConstant: HelmMetrics.s2).isActive = true
            parts.append(dot)
        }
        var text = title
        if let shortcut = chip?.shortcut { text += "  \u{2303}\u{2318}\(shortcut)" }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: HelmType.scaled(11.5), weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        parts.append(label)
        var closeButton: NSButton?
        if let chip {
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "End session")!
                                    .withSymbolConfiguration(.init(pointSize: HelmType.scaled(8.5), weight: .bold))!,
                                 target: self, action: #selector(closeClicked(_:)))
            close.isBordered = false
            close.identifier = NSUserInterfaceItemIdentifier(chip.hostID.uuidString)
            close.toolTip = "End the session on \(chip.label)"
            close.setAccessibilityLabel("End the session on \(chip.label)")
            parts.append(close)
            closeButton = close
        }
        let line = NSStackView(views: parts)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = HelmMetrics.s1 + HelmMetrics.s0
        line.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            line.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            view.heightAnchor.constraint(equalToConstant: 28),
        ])
        if let chip {
            view.identifier = NSUserInterfaceItemIdentifier(chip.hostID.uuidString)
            view.toolTip = chip.connected ? "Switch to \(chip.label)" : "\(chip.label) - restored, not connected"
            view.accessibilityLabelOverride = "Switch to \(chip.label)"
        } else if isConnect {
            view.identifier = NSUserInterfaceItemIdentifier("connect")
            view.toolTip = "Connect a saved host"
            view.accessibilityLabelOverride = "Connect a host"
        } else {
            view.identifier = NSUserInterfaceItemIdentifier("this-mac")
            view.toolTip = "This Mac's shells"
            view.accessibilityLabelOverride = "Show this Mac's shells"
        }
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(chipClicked(_:))))
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        chipRow.addArrangedSubview(view)
        return (chip, view, label, closeButton)
    }

    @objc private func chipClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue else { return }
        switch id {
        case "connect": onConnect?()
        case "this-mac": onShowThisMac?()
        default:
            if let hostID = UUID(uuidString: id) { onSwitch?(hostID) }
        }
    }

    @objc private func closeClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let hostID = UUID(uuidString: raw) else { return }
        onEnd?(hostID)
    }

    func applyTheme(_ theme: HelmTheme) {
        let palette = HelmHeroSurface.palette(for: theme)
        hero.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        let darker = HelmContrast.relativeLuminance(palette.start) < HelmContrast.relativeLuminance(palette.end)
            ? palette.start : palette.end
        let line = NSMutableAttributedString(string: content.title, attributes: [
            .font: NSFont.systemFont(ofSize: HelmType.scaled(13.5), weight: .bold), .foregroundColor: ink])
        if !content.detail.isEmpty {
            line.append(NSAttributedString(string: "  \u{00B7}  \(content.detail)", attributes: [
                .font: NSFont.systemFont(ofSize: HelmType.scaled(13), weight: .medium),
                .foregroundColor: ink.withAlphaComponent(0.82)]))
        }
        titleLabel.attributedStringValue = line
        titleLabel.toolTip = line.string
        if let accent = content.tileAccentHex {
            tile.configure(symbol: "server.rack", tint: .accent, pointSize: HelmType.scaled(11))
            tile.overrideFill(hex: accent)
        } else {
            tile.configure(symbol: "terminal.fill", tint: .accent, pointSize: HelmType.scaled(11))
            tile.overrideFill(hex: "FFFFFF")
        }
        tile.applyTheme(theme)
        for item in chipViews {
            let lit = item.chip.map { $0.hostID == content.currentHostID } ?? false
            let fill = lit ? ink.withAlphaComponent(0.94) : ink.withAlphaComponent(0.14)
            item.view.normalColor = fill
            item.view.hoverColor = lit ? fill : ink.withAlphaComponent(0.24)
            item.view.layer?.borderWidth = 1
            item.view.layer?.borderColor = ink.withAlphaComponent(lit ? 0 : 0.3).cgColor
            let text = lit ? HelmContrast.color(darker) : ink
            item.label.textColor = text
            item.close?.contentTintColor = text.withAlphaComponent(0.8)
            item.view.subviews.first?.subviews.compactMap { $0 as? NSImageView }
                .filter { $0.identifier?.rawValue == "glyph" }
                .forEach { $0.contentTintColor = text }
            if let chip = item.chip, !chip.connected {
                item.label.textColor = text.withAlphaComponent(0.7)
            }
        }
        setAccessibilityLabel([content.title, content.detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    #if FM_SELFTESTS
    /// The band's one line, as drawn.
    var debugLine: String { titleLabel.stringValue }
    func debugChipHostIDs() -> [UUID] { chipViews.compactMap { $0.chip?.hostID } }
    var debugChipTitles: [String] { chipViews.map(\.label.stringValue) }
    var debugLitHostID: UUID? { content.currentHostID }
    func debugClickChip(_ identifier: String) {
        _ = chipViews.first { $0.view.identifier?.rawValue == identifier }?.view.performPrimaryAction()
    }
    func debugClickClose(_ hostID: UUID) {
        chipViews.first { $0.chip?.hostID == hostID }?.close?.performClick(nil)
    }
    var debugGradientColors: [CGColor] { hero.debugGradientColors }
    #endif
}
