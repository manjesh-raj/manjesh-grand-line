// Grand Line - native macOS app.
//
// Home's configurable card set (stage 4 of the modular-shell migration): which
// cards Home's own space shows in the sidebar layout, in what order and at
// what size - the prototype's Customize mode, on the app's real cards.
//
// **The cards are the canvas's own.** Every card here is a `DaylightModule`
// the Home canvas already renders on one of its spaces; Customize only says
// which of them Home's own space shows. Nothing new is fetched to fill one,
// and a card hidden here still renders on its own space and still has its
// page in the sidebar.
//
// **The floating bar keeps the hub as it is.** Its Home space is the
// hand-placed dashboard the captain reviewed over several passes, so only the
// sidebar layout hands the canvas a layout (`HomeCanvasController.cardLayout`);
// with none, the canvas draws exactly what it always has.
//
// **The attention card stays at the top.** It is Home's answer to "what needs
// me", not a card among cards, so it is not part of the set.

import AppKit

/// Which cards Home shows, in order, and each card's size.
struct HomeCardLayout: Equatable {

    enum Size: String, CaseIterable {
        case small, large, wide

        var title: String {
            switch self {
            case .small: return "Small"
            case .large: return "Large"
            case .wide: return "Full Width"
            }
        }

        /// The grid columns the card takes. `HelmResponsiveGrid.packRows`
        /// clamps a span to the columns the window has, so full width is any
        /// span past them.
        var span: Int {
            switch self {
            case .small: return 1
            case .large: return 2
            case .wide: return Self.fullWidthSpan
            }
        }

        static let fullWidthSpan = 99
    }

    /// The shown cards' ids, in order. An id this build does not know - a
    /// newer build's card - stays where it is through every edit here rather
    /// than being dropped on the next write (AGENTS.md's passthrough rule for
    /// a whole-value rewrite, GL-01).
    private(set) var shownIDs: [String]
    private(set) var sizeIDs: [String: String]

    init(shown: [DaylightModule], sizes: [DaylightModule: Size] = [:]) {
        shownIDs = shown.map(\.rawValue)
        sizeIDs = Dictionary(sizes.map { ($0.key.rawValue, $0.value.rawValue) }, uniquingKeysWith: { first, _ in first })
    }

    /// Home before the captain arranges it: the hub's own five cards, ordered
    /// and sized so they fill the grid's rows. At four columns (the sidebar
    /// layout at 1512) that is two full rows, and at three (1100) only the
    /// last row has a column to spare. In canvas order the second row left a
    /// column empty at both widths.
    static let standard = HomeCardLayout(shown: [.briefing, .fleet, .health, .claudeStatus, .mergeQueue],
                                         sizes: [.mergeQueue: .large])

    /// R2-UX-01 (b): Home before the captain arranges it, for a profile. The
    /// Operator's is the hub's own five above. A Personal Home leads with what
    /// a general user keeps here - tasks, notes, stickies, saved links, code
    /// and credentials - rather than the fleet, and fills two rows at four
    /// columns the same way.
    static func standard(for profile: WorkspaceProfile) -> HomeCardLayout {
        switch profile {
        case .operator: return standard
        case .personal:
            return HomeCardLayout(shown: [.tasks, .notebook, .stickyBoard, .readingList, .codePreview, .poneglyph],
                                  sizes: [.tasks: .large, .readingList: .large])
        }
    }

    /// The shown cards this build knows, in order.
    var shown: [DaylightModule] { shownIDs.compactMap(DaylightModule.init(rawValue:)) }

    /// Every card Home is not showing, in canvas order - what Customize offers
    /// to add.
    var hidden: [DaylightModule] { DaylightModule.canvasOrder.filter { !shownIDs.contains($0.rawValue) } }

    /// A card's size: the captain's, or the card's own span.
    func size(of module: DaylightModule) -> Size {
        sizeIDs[module.rawValue].flatMap(Size.init(rawValue:)) ?? (module.gridSpan >= 2 ? .large : .small)
    }

    mutating func show(_ module: DaylightModule) {
        guard !shownIDs.contains(module.rawValue) else { return }
        shownIDs.append(module.rawValue)
    }

    mutating func hide(_ module: DaylightModule) {
        shownIDs.removeAll { $0 == module.rawValue }
    }

    mutating func setSize(_ size: Size, for module: DaylightModule) {
        sizeIDs[module.rawValue] = size.rawValue
    }

    /// Swap a shown card with the next known card before it (`offset` < 0)
    /// or after it. Unknown ids keep their places.
    mutating func move(_ module: DaylightModule, by offset: Int) {
        guard offset != 0, let from = shownIDs.firstIndex(of: module.rawValue) else { return }
        let step = offset < 0 ? -1 : 1
        var to = from + step
        while shownIDs.indices.contains(to), DaylightModule(rawValue: shownIDs[to]) == nil { to += step }
        guard shownIDs.indices.contains(to) else { return }
        shownIDs.swapAt(from, to)
    }

    func canMove(_ module: DaylightModule, by offset: Int) -> Bool {
        var copy = self
        copy.move(module, by: offset)
        return copy != self
    }

    // MARK: Stored form

    private struct Stored: Codable {
        var shown: [String]
        var sizes: [String: String]

        init(shown: [String], sizes: [String: String]) {
            self.shown = shown
            self.sizes = sizes
        }

        // GL-01: every key optional, so a value written by an older or newer
        // build still reads.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            shown = try container.decodeIfPresent([String].self, forKey: .shown) ?? []
            sizes = try container.decodeIfPresent([String: String].self, forKey: .sizes) ?? [:]
        }
    }

    var storedData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(Stored(shown: shownIDs, sizes: sizeIDs))
    }

    init?(storedData: Data) {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: storedData) else { return nil }
        shownIDs = stored.shown
        sizeIDs = stored.sizes
    }
}

// MARK: - Customize mode's views

/// The strip above Home's grid while the captain arranges it: what Customize
/// is for, a menu of every card Home is not showing, Reset, and Done.
final class HomeCustomizeTray: NSView {
    var onAdd: ((DaylightModule) -> Void)?
    var onReset: (() -> Void)?
    var onDone: (() -> Void)?
    /// The cards the Add menu offers, set before it opens.
    var hiddenCards: [DaylightModule] = [] {
        didSet { addButton.isEnabled = !hiddenCards.isEmpty }
    }

    private let titleLabel = NSTextField(labelWithString: "Arrange Home")
    private let hintLabel = NSTextField(wrappingLabelWithString:
        "Pick a size for each card, move it earlier or later, or hide it. Every card from the other spaces can be added here.")
    private let addButton = HelmButton(title: "Add a Card", variant: .secondary, size: .small, symbol: "plus")
    private let resetButton = HelmButton(title: "Reset Layout", variant: .quiet, size: .small)
    private let doneButton = HelmButton(title: "Done", variant: .primary, size: .small)
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = HelmType.sectionTitle()
        hintLabel.font = HelmType.body()
        hintLabel.maximumNumberOfLines = 2
        addButton.target = self
        addButton.action = #selector(addClicked)
        resetButton.target = self
        resetButton.action = #selector(resetClicked)
        resetButton.toolTip = "Go back to Home's own cards"
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        // Escape finishes, as it does in the prototype.
        doneButton.keyEquivalent = "\u{1b}"

        let text = NSStackView(views: [titleLabel, hintLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s1
        let buttons = NSStackView(views: [addButton, resetButton, doneButton])
        buttons.orientation = .horizontal
        buttons.spacing = HelmMetrics.s2
        for view in [addButton, resetButton, doneButton] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // Gotcha (5): the text gives way, never the buttons.
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [text, buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s4
        // Gotcha (10): `.fill` and a required hug on the buttons, so only the
        // text column takes the slack.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s3),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s4),
        ])
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    private func applyTheme(_ theme: HelmTheme) {
        HelmCard.applyCardSurface(to: self, theme: theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        hintLabel.textColor = HelmTheme.mutedInk(theme)
        titleLabel.font = HelmType.sectionTitle()
        hintLabel.font = HelmType.body()
    }

    /// The Add menu: the hidden cards under the space each one belongs to, so
    /// a captain who knew a card from Command or Stores finds it there.
    func addMenu() -> NSMenu {
        let menu = NSMenu()
        let groups: [(title: String, cards: [DaylightModule])] = DaylightSpace.allCases.map { space in
            (space.title, hiddenCards.filter { ($0.space ?? .overview) == space })
        }
        for group in groups where !group.cards.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for card in group.cards {
                let item = WorkspaceSidebarMenuItem(title: card.title, action: #selector(WorkspaceSidebarMenuItem.fire),
                                                    keyEquivalent: "")
                item.target = item
                item.image = HelmSymbol.image(card.symbol, pointSize: HelmType.scaled(13), weight: .medium)
                item.handler = { [weak self] in self?.onAdd?(card) }
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func addClicked() {
        let menu = addMenu()
        let below = addButton.isFlipped ? addButton.bounds.maxY + HelmMetrics.s1 : -HelmMetrics.s1
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: addButton)
    }

    @objc private func resetClicked() { onReset?() }
    @objc private func doneClicked() { onDone?() }

    #if FM_SELFTESTS
    var debugAddButton: HelmButton { addButton }
    var debugResetButton: HelmButton { resetButton }
    var debugDoneButton: HelmButton { doneButton }
    #endif
}

/// The controls a card wears while the captain arranges Home: its size, move
/// earlier or later, and hide. They sit over the card's own header actions,
/// which a click must not reach while the card is being arranged.
final class HomeCardCustomizeStrip: NSView {
    var onSize: ((HomeCardLayout.Size) -> Void)?
    var onMove: ((Int) -> Void)?
    var onHide: (() -> Void)?

    /// The size as a menu behind one glyph rather than three segments or a
    /// labelled button: a small card is 255pt, and a label covered its title.
    /// The menu ticks the size the card has.
    private let sizeButton = HelmButton(symbol: "arrow.up.left.and.arrow.down.right", variant: .quiet, size: .small)
    private var size: HomeCardLayout.Size
    private let cardTitle: String
    private let earlierButton = HelmButton(symbol: "arrow.left", variant: .quiet, size: .small)
    private let laterButton = HelmButton(symbol: "arrow.right", variant: .quiet, size: .small)
    private let hideButton = HelmButton(symbol: "eye.slash", variant: .quiet, size: .small)
    private var themeToken: ThemeObservation?

    init(cardTitle: String, size: HomeCardLayout.Size, canMoveEarlier: Bool, canMoveLater: Bool) {
        self.size = size
        self.cardTitle = cardTitle
        super.init(frame: .zero)
        sizeButton.toolTip = "Card size: \(size.title)"
        sizeButton.setAccessibilityLabel("Size of \(cardTitle): \(size.title)")
        sizeButton.target = self
        sizeButton.action = #selector(sizeClicked)
        earlierButton.toolTip = "Move earlier"
        earlierButton.setAccessibilityLabel("Move \(cardTitle) earlier")
        earlierButton.isEnabled = canMoveEarlier
        earlierButton.target = self
        earlierButton.action = #selector(earlierClicked)
        laterButton.toolTip = "Move later"
        laterButton.setAccessibilityLabel("Move \(cardTitle) later")
        laterButton.isEnabled = canMoveLater
        laterButton.target = self
        laterButton.action = #selector(laterClicked)
        hideButton.toolTip = "Hide this card"
        hideButton.setAccessibilityLabel("Hide \(cardTitle)")
        hideButton.target = self
        hideButton.action = #selector(hideClicked)

        let row = NSStackView(views: [sizeButton, earlierButton, laterButton, hideButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s1
        // The card's header row holds the strip in place of the card's own
        // status and action (`HelmModuleCard.setHeaderAccessory`). At 31pt it
        // stays inside that 32pt row, so the card does not change height while
        // it is being arranged - `MainSplitShellSelfTest` measures both.
        row.edgeInsets = NSEdgeInsets(top: HelmMetrics.s1 + 1, left: HelmMetrics.s1, bottom: HelmMetrics.s1 + 1,
                                      right: HelmMetrics.s1)
        row.translatesAutoresizingMaskIntoConstraints = false
        // The header row gives its spare width to whichever column hugs
        // least, and this strip is a container with no intrinsic width to hug
        // with (gotcha (12)), so its stack hugs for it - one step over the
        // title column's 250, the column-hug band of gotcha (13). Without it
        // the strip stretched across a large card's header.
        row.setHuggingPriority(HelmDaylightPriority.columnHug, for: .horizontal)
        for view in row.arrangedSubviews {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    private func applyTheme(_ theme: HelmTheme) {
        HelmCard.applyCardSurface(to: self, theme: theme, cornerRadius: HelmMetrics.rChip + 3)
    }

    /// The three sizes, the current one ticked.
    func sizeMenu() -> NSMenu {
        let menu = NSMenu()
        for option in HomeCardLayout.Size.allCases {
            let item = WorkspaceSidebarMenuItem(title: option.title, action: #selector(WorkspaceSidebarMenuItem.fire),
                                                keyEquivalent: "")
            item.target = item
            item.state = option == size ? .on : .off
            item.handler = { [weak self] in self?.onSize?(option) }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func sizeClicked() {
        let below = sizeButton.isFlipped ? sizeButton.bounds.maxY + HelmMetrics.s1 : -HelmMetrics.s1
        sizeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: sizeButton)
    }

    @objc private func earlierClicked() { onMove?(-1) }
    @objc private func laterClicked() { onMove?(1) }
    @objc private func hideClicked() { onHide?() }

    #if FM_SELFTESTS
    var debugSizeButton: HelmButton { sizeButton }
    var debugEarlierButton: HelmButton { earlierButton }
    var debugLaterButton: HelmButton { laterButton }
    var debugHideButton: HelmButton { hideButton }
    #endif
}
