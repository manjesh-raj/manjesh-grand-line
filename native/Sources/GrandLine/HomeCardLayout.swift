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

    /// A card's size on Home: a width in `HomeCardGrid.columns` and, once
    /// the captain has dragged it, a height of its own.
    ///
    /// Free sizing replaced three fixed sizes (Small, Large, Full Width). The
    /// width is still a share of the grid rather than a point width, so a card
    /// keeps its place in the composition when the window changes size; the
    /// grid is fine enough (24 columns) that a drag reads as continuous.
    struct CardSize: Equatable {
        /// Columns of `HomeCardGrid.columns`, 1 through all of them.
        var columns: Int
        /// The captain's height in points, or nil for the card's own -
        /// as tall as its content, and as tall as its row (`equalHeights`).
        var height: CGFloat?

        init(columns: Int, height: CGFloat? = nil) {
            self.columns = min(max(1, columns), HomeCardGrid.columns)
            self.height = height
        }

        /// The three sizes this replaced, as widths. At four of the old
        /// columns (the sidebar layout at 1512) these are exactly the widths
        /// they used to resolve to, which is what keeps a migrated layout
        /// looking as it did.
        static let small = CardSize(columns: HomeCardGrid.columns / 4)
        static let large = CardSize(columns: HomeCardGrid.columns / 2)
        static let fullWidth = CardSize(columns: HomeCardGrid.columns)
    }

    /// The fixed sizes a layout was saved with before free sizing. Read so a
    /// saved layout keeps its look, and still written as the nearest one so
    /// an older build reading this value draws roughly the same Home.
    enum LegacySize: String {
        case small, large, wide

        var size: CardSize {
            switch self {
            case .small: return .small
            case .large: return .large
            case .wide: return .fullWidth
            }
        }

        /// The nearest fixed size to `columns`.
        init(nearest columns: Int) {
            let quarter = HomeCardGrid.columns / 4
            let half = HomeCardGrid.columns / 2
            if columns <= (quarter + half) / 2 {
                self = .small
            } else if columns < (half + HomeCardGrid.columns) / 2 {
                self = .large
            } else {
                self = .wide
            }
        }
    }

    /// The shown cards' ids, in order. An id this build does not know - a
    /// newer build's card - stays where it is through every edit here rather
    /// than being dropped on the next write (AGENTS.md's passthrough rule for
    /// a whole-value rewrite, GL-01).
    private(set) var shownIDs: [String]
    /// The fixed sizes, by card id - what a layout saved before free sizing
    /// carries, and what this build still writes for an older one to read.
    private(set) var sizeIDs: [String: String]
    /// The free sizes, by card id. Wins over `sizeIDs` for a card in both.
    private(set) var cardSizeIDs: [String: CardSize]

    init(shown: [DaylightModule], sizes: [DaylightModule: CardSize] = [:]) {
        shownIDs = shown.map(\.rawValue)
        sizeIDs = [:]
        cardSizeIDs = [:]
        for (module, size) in sizes { setSize(size, for: module) }
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

    /// A card's size: the captain's, a fixed size it was saved with, or the
    /// card's own span.
    func size(of module: DaylightModule) -> CardSize {
        if let size = cardSizeIDs[module.rawValue] { return size }
        if let legacy = sizeIDs[module.rawValue].flatMap(LegacySize.init(rawValue:)) { return legacy.size }
        return Self.ownSize(of: module)
    }

    /// The size a card has before anyone sizes it.
    static func ownSize(of module: DaylightModule) -> CardSize {
        module.gridSpan >= 2 ? .large : .small
    }

    /// Whether the captain has sized this card - what Reset Size undoes.
    func hasCustomSize(_ module: DaylightModule) -> Bool {
        size(of: module) != Self.ownSize(of: module)
    }

    mutating func show(_ module: DaylightModule) {
        guard !shownIDs.contains(module.rawValue) else { return }
        shownIDs.append(module.rawValue)
    }

    mutating func hide(_ module: DaylightModule) {
        shownIDs.removeAll { $0 == module.rawValue }
    }

    /// Size a card. A height is snapped and held inside
    /// `HomeCardGrid.heightRange`, so a stored value is always one the grid
    /// would draw.
    mutating func setSize(_ size: CardSize, for module: DaylightModule) {
        var size = size
        size.height = size.height.map(HomeCardGrid.storedHeight)
        cardSizeIDs[module.rawValue] = size
        sizeIDs[module.rawValue] = LegacySize(nearest: size.columns).rawValue
    }

    /// Put a card back to its own size.
    mutating func resetSize(of module: DaylightModule) {
        cardSizeIDs[module.rawValue] = nil
        sizeIDs[module.rawValue] = nil
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
    //
    // `sizes` is the fixed-size map every build has written, and `cardSizes`
    // the free sizes this one adds. A layout saved before free sizing has
    // only `sizes`, and `size(of:)` reads it as the width it always drew - so
    // the migration is a read, and nothing is rewritten until the captain
    // changes something. This build keeps writing `sizes` too, as the
    // nearest fixed size, so an older build reading the same domain still
    // draws roughly the Home the captain arranged.

    private struct Stored: Codable {
        var shown: [String]
        var sizes: [String: String]
        var cardSizes: [String: StoredSize]

        init(shown: [String], sizes: [String: String], cardSizes: [String: StoredSize]) {
            self.shown = shown
            self.sizes = sizes
            self.cardSizes = cardSizes
        }

        // GL-01: every key optional, so a value written by an older or newer
        // build still reads. A `cardSizes` this build cannot read is dropped
        // rather than taking the cards and their order down with it.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            shown = try container.decodeIfPresent([String].self, forKey: .shown) ?? []
            sizes = try container.decodeIfPresent([String: String].self, forKey: .sizes) ?? [:]
            cardSizes = ((try? container.decodeIfPresent([String: StoredSize].self, forKey: .cardSizes)) ?? nil) ?? [:]
        }
    }

    private struct StoredSize: Codable {
        var columns: Int?
        var height: Double?
    }

    var storedData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let cardSizes = cardSizeIDs.mapValues { StoredSize(columns: $0.columns, height: $0.height.map(Double.init)) }
        return try? encoder.encode(Stored(shown: shownIDs, sizes: sizeIDs, cardSizes: cardSizes))
    }

    init?(storedData: Data) {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: storedData) else { return nil }
        shownIDs = stored.shown
        sizeIDs = stored.sizes
        cardSizeIDs = stored.cardSizes.compactMapValues { size in
            guard let columns = size.columns else { return nil }
            return CardSize(columns: columns, height: size.height.map { HomeCardGrid.storedHeight(CGFloat($0)) })
        }
    }
}

/// The grid Home's arranged cards are laid out on, as numbers.
///
/// Pure, so the sizing rules are asserted without a window
/// (`SplitShellModelSelfTest`). The canvas lays the rows out with
/// `HelmResponsiveGrid.spanningRows`, which is the same row builder the rest
/// of the canvas uses, at this grid's fixed column count.
enum HomeCardGrid {
    /// The columns a width is measured in. Fine enough that a drag reads as
    /// continuous - about 50pt a column at the sidebar layout's 1512 - and
    /// divisible by two, three and four, so halves, thirds and quarters all
    /// line up across rows.
    static let columns = 24

    /// The step a dragged height snaps to.
    static let heightStep: CGFloat = 8

    /// The tallest a card may be made. A card is a summary, and past this it
    /// is mostly empty paper.
    static var maximumHeight: CGFloat { HelmType.scaled(720) }

    /// The heights a captain's height is held inside. The floor is the card's
    /// own; a card whose content needs more is drawn taller regardless,
    /// because a card never clips its body (`HelmModuleCard`'s `bodyBottom`).
    static var heightRange: ClosedRange<CGFloat> { HelmModuleCard.minimumHeight...maximumHeight }

    /// `height`, snapped to the step and held in `heightRange`.
    static func storedHeight(_ height: CGFloat) -> CGFloat {
        let snapped = (height / heightStep).rounded() * heightStep
        return min(max(snapped, heightRange.lowerBound), heightRange.upperBound)
    }

    /// One column's width. The same arithmetic as `HelmResponsiveGrid.itemWidth`.
    static func unitWidth(containerWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        HelmResponsiveGrid.itemWidth(containerWidth: containerWidth, columns: columns, spacing: spacing)
    }

    /// The width `span` columns take, gaps included.
    static func width(columns span: Int, containerWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        let unit = unitWidth(containerWidth: containerWidth, spacing: spacing)
        return unit * CGFloat(span) + spacing * CGFloat(max(0, span - 1))
    }

    /// The columns nearest a dragged `width`, held to the grid.
    static func columns(nearestWidth width: CGFloat, containerWidth: CGFloat, spacing: CGFloat) -> Int {
        let unit = unitWidth(containerWidth: containerWidth, spacing: spacing)
        guard unit > 0 else { return columns }
        let span = ((width + spacing) / (unit + spacing)).rounded()
        return min(max(1, Int(span)), columns)
    }

    /// The fewest columns that are still `minWidth` wide at this container.
    static func minimumColumns(containerWidth: CGFloat, minWidth: CGFloat, spacing: CGFloat) -> Int {
        for span in 1...columns where width(columns: span, containerWidth: containerWidth, spacing: spacing) + 0.5 >= minWidth {
            return span
        }
        return columns
    }

    /// Home's cards in rows, and the columns each one is drawn at, at a
    /// container whose narrowest readable card is `minimum` columns.
    /// `spans` are the captain's widths, in order; each placement's `index`
    /// points back into them.
    ///
    /// The rows are the captain's own: `spans` packed onto the grid in order,
    /// so at a width where every card can be read, every card is exactly the
    /// width it was given. Where the window has made a card too narrow - the
    /// sidebar open, or a narrower window than the one Home was arranged in -
    /// the card's row makes room for it. Widening the card on its own is what
    /// this replaced, and it overflowed the row: with the sidebar open, a row
    /// of 12, 7 and 5 columns became 12, 7 and 6, so Health dropped to the
    /// next row, pushed Merge queue onto a row of its own, and every row
    /// ended short of the right edge.
    ///
    /// - A too-narrow card is held at the minimum. The columns it needs come
    ///   from the row's spare columns first, then from the widest card in the
    ///   row, one at a time - so every other card keeps its width, and a full
    ///   row still ends at the grid's edge.
    /// - A row with more cards than fit at the minimum is split into as few
    ///   rows as hold them, cut where the parts are most even, and each part
    ///   fills the grid in proportion to the widths its cards were given.
    static func rows(spans: [Int], minimum: Int) -> [[HelmResponsiveGrid.SpanPlacement]] {
        let minimum = min(max(1, minimum), columns)
        let perRow = max(1, columns / minimum)
        var rows: [[HelmResponsiveGrid.SpanPlacement]] = []
        for row in HelmResponsiveGrid.packRows(spans: spans, columns: columns) {
            guard row.count > perRow else {
                let total = row.reduce(0) { $0 + $1.span }
                let raised = row.reduce(0) { $0 + max($1.span, minimum) }
                rows.append(fit(row, to: min(columns, max(total, raised)), minimum: minimum))
                continue
            }
            var start = 0
            for length in evenSplit(row.map(\.span), perRow: perRow) {
                rows.append(fit(Array(row[start..<start + length]), to: columns, minimum: minimum))
                start += length
            }
        }
        return rows
    }

    /// The captain's widths with the row of the card at `index` as it is
    /// drawn, and every other card as it was - what a drag on that card
    /// starts from. The captain sizes what they see: a drag measures the
    /// card's drawn width, so its row has to be stored at the widths it is
    /// drawn at, or a column a row-mate was given would go back to the
    /// widest card the moment the drag ends. From there a drag works exactly
    /// as it does when nothing was too narrow.
    ///
    /// A row the window has split is left alone: its parts are drawn in
    /// proportion to the stored widths, so a drag already moves the card,
    /// and storing the parts would rewrite the whole composition.
    static func drawnSpans(_ spans: [Int], minimum: Int, rowOf index: Int) -> [Int] {
        let rows = rows(spans: spans, minimum: minimum)
        guard let row = rows.first(where: { $0.contains { $0.index == index } }) else { return spans }
        let packed = HelmResponsiveGrid.packRows(spans: spans, columns: columns)
        guard let own = packed.first(where: { $0.contains { $0.index == index } }),
              own.map(\.index) == row.map(\.index) else { return spans }
        var kept = spans
        for placement in row { kept[placement.index] = placement.span }
        return kept
    }

    /// `row`'s cards on `target` columns, none narrower than `minimum`:
    /// grown in proportion to their widths when the target is wider than
    /// they are, then each too-narrow card raised to the minimum with the
    /// columns taken from the widest card that has them to give.
    private static func fit(_ row: [HelmResponsiveGrid.SpanPlacement], to target: Int,
                            minimum: Int) -> [HelmResponsiveGrid.SpanPlacement] {
        var spans = row.map(\.span)
        let total = spans.reduce(0, +)
        if target > total, total > 0 {
            // Largest remainder, so the shares add up to exactly the target.
            let shares = spans.map { Double($0) * Double(target) / Double(total) }
            spans = shares.map { Int($0.rounded(.down)) }
            let order = spans.indices.sorted { shares[$0] - Double(spans[$0]) > shares[$1] - Double(spans[$1]) }
            for index in order.prefix(target - spans.reduce(0, +)) { spans[index] += 1 }
        }
        spans = spans.map { max($0, minimum) }
        var excess = spans.reduce(0, +) - target
        while excess > 0 {
            guard let widest = spans.indices.filter({ spans[$0] > minimum }).max(by: { spans[$0] < spans[$1] }) else { break }
            spans[widest] -= 1
            excess -= 1
        }
        return zip(row, spans).map { HelmResponsiveGrid.SpanPlacement(index: $0.index, span: $1) }
    }

    /// How many cards each part of a split row takes: as few parts as hold
    /// `perRow` cards each, cut so the widest part is as narrow as it can be
    /// - a 12, 6 and 6 row two to a row is the 12, then the two 6s, not the
    /// 12 and a 6 over a lone 6. On a tie the earlier part takes more.
    private static func evenSplit(_ spans: [Int], perRow: Int) -> [Int] {
        let count = spans.count
        let parts = (count + perRow - 1) / perRow
        // best[i][j]: the narrowest widest part over the first i cards in j parts.
        var best = Array(repeating: Array(repeating: Int.max, count: parts + 1), count: count + 1)
        var cut = Array(repeating: Array(repeating: 0, count: parts + 1), count: count + 1)
        best[0][0] = 0
        for i in 1...count {
            for j in 1...min(i, parts) {
                for start in max(0, i - perRow)..<i where best[start][j - 1] != Int.max {
                    let widest = max(best[start][j - 1], spans[start..<i].reduce(0, +))
                    if widest <= best[i][j] {
                        best[i][j] = widest
                        cut[i][j] = start
                    }
                }
            }
        }
        var lengths: [Int] = []
        var end = count
        for part in stride(from: parts, to: 0, by: -1) {
            let start = cut[end][part]
            lengths.insert(end - start, at: 0)
            end = start
        }
        return lengths
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
        "Drag a card's edge or corner to size it, move it earlier or later, or hide it. Any card Home is not showing can be added here.")
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

    /// The Add menu: the hidden cards under the sidebar group of the module
    /// each one opens - Home, then Work, Observe, Workbench and Machine -
    /// so the captain finds a card where its page is in the sidebar.
    ///
    /// R2-ARCH-01: it was grouped by the floating bar's spaces (Command,
    /// Operations, Stores, Engineering), a second map of the app in the
    /// layout that has none (R2-UX-02's two taxonomies). This file is the
    /// sidebar layout's own, so it reads only the module table.
    func addMenu() -> NSMenu {
        let menu = NSMenu()
        let sections: [(title: String, group: WorkspaceGroup?)] = [("Home", nil)]
            + WorkspaceGroup.allCases.map { ($0.title, $0) }
        let groups: [(title: String, cards: [DaylightModule])] = sections.map { section in
            (section.title, hiddenCards.filter { ModuleTable.module(for: $0.opens).group == section.group })
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
/// The controls a card wears while the captain arranges Home: put its size
/// back, move it earlier or later, and hide it. They sit over the card's own
/// header actions, which a click must not reach while the card is being
/// arranged. The size itself is dragged, from the card's edges
/// (`HomeCardResizeHandle`).
final class HomeCardCustomizeStrip: NSView {
    var onResetSize: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onHide: (() -> Void)?

    private let resetSizeButton = HelmButton(symbol: "arrow.uturn.backward", variant: .quiet, size: .small)
    private let earlierButton = HelmButton(symbol: "arrow.left", variant: .quiet, size: .small)
    private let laterButton = HelmButton(symbol: "arrow.right", variant: .quiet, size: .small)
    private let hideButton = HelmButton(symbol: "eye.slash", variant: .quiet, size: .small)
    private var themeToken: ThemeObservation?

    init(cardTitle: String, hasCustomSize: Bool, canMoveEarlier: Bool, canMoveLater: Bool) {
        super.init(frame: .zero)
        resetSizeButton.toolTip = "Reset to its own size"
        resetSizeButton.setAccessibilityLabel("Reset the size of \(cardTitle)")
        resetSizeButton.isEnabled = hasCustomSize
        resetSizeButton.target = self
        resetSizeButton.action = #selector(resetSizeClicked)
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

        let row = NSStackView(views: [resetSizeButton, earlierButton, laterButton, hideButton])
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

    /// Whether the card has a size of the captain's to put back.
    func setHasCustomSize(_ hasCustomSize: Bool) {
        resetSizeButton.isEnabled = hasCustomSize
    }

    @objc private func resetSizeClicked() { onResetSize?() }
    @objc private func earlierClicked() { onMove?(-1) }
    @objc private func laterClicked() { onMove?(1) }
    @objc private func hideClicked() { onHide?() }

    #if FM_SELFTESTS
    var debugResetSizeButton: HelmButton { resetSizeButton }
    var debugEarlierButton: HelmButton { earlierButton }
    var debugLaterButton: HelmButton { laterButton }
    var debugHideButton: HelmButton { hideButton }
    #endif
}

/// One of the three grips a card wears while Home is being arranged: its
/// trailing edge (width), its bottom edge (height) and its bottom-trailing
/// corner (both).
///
/// The handle only reports where the pointer is; the canvas turns that into
/// a size on its grid and lays Home out again, so the card itself is the
/// preview and its neighbours reflow as it is dragged. The same shape as
/// `CodePreviewSidebarResizeHandle`: plain mouse tracking, a double-click to
/// put the size back, and a test hook that drives the real handlers.
final class HomeCardResizeHandle: NSView {
    enum Edge: CaseIterable {
        case trailing, bottom, corner

        var resizesWidth: Bool { self != .bottom }
        var resizesHeight: Bool { self != .trailing }
    }

    let edge: Edge
    /// A drag starts and moves (the pointer in window coordinates), and ends.
    var onBegin: ((Edge, NSPoint) -> Void)?
    var onDrag: ((Edge, NSPoint) -> Void)?
    var onEnd: ((Edge) -> Void)?
    /// A double-click: put this edge's dimension back to the card's own.
    var onReset: ((Edge) -> Void)?
    /// VoiceOver's increment and decrement: one column, or one height step.
    var onStep: ((Edge, Int) -> Void)?

    /// How far the grip area reaches in from the card's edge.
    static let thickness: CGFloat = 12
    /// The corner grip's square.
    static let cornerSize: CGFloat = 22

    /// Lit while this card is the one being resized, so a handle rebuilt
    /// mid-drag still reads as held.
    var isActive = false {
        didSet { refreshGrip() }
    }

    private var hovering = false
    private var dragging = false
    private var tracking: NSTrackingArea?
    private let grip = CAShapeLayer()
    private var theme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    init(edge: Edge, cardTitle: String) {
        self.edge = edge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        grip.lineCap = .round
        grip.fillColor = nil
        layer?.addSublayer(grip)
        switch edge {
        case .trailing:
            setAccessibilityElement(true)
            setAccessibilityRole(.handle)
            setAccessibilityLabel("Width of \(cardTitle)")
            toolTip = "Drag to change the width - double-click to reset"
        case .bottom:
            setAccessibilityElement(true)
            setAccessibilityRole(.handle)
            setAccessibilityLabel("Height of \(cardTitle)")
            toolTip = "Drag to change the height - double-click to fit the content"
        case .corner:
            // The two edges already say this to VoiceOver.
            setAccessibilityElement(false)
            toolTip = "Drag to change the size - double-click to reset"
        }
        themeToken = ThemeManager.shared.observe { [weak self] theme in
            self?.theme = theme
            self?.refreshGrip()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// Pin the handle into `card`, on top of everything the card draws.
    /// Inside the card's bounds rather than straddling its edge, because a
    /// point outside a view's frame never reaches its subviews' `hitTest`.
    func install(in card: NSView) {
        card.addSubview(self, positioned: .above, relativeTo: nil)
        let corner = Self.cornerSize
        var constraints: [NSLayoutConstraint]
        switch edge {
        case .trailing:
            constraints = [
                trailingAnchor.constraint(equalTo: card.trailingAnchor),
                widthAnchor.constraint(equalToConstant: Self.thickness),
                // Below the header row, so the arranging controls keep their clicks.
                topAnchor.constraint(equalTo: card.topAnchor, constant: HelmMetrics.s6),
                bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -corner),
            ]
        case .bottom:
            constraints = [
                bottomAnchor.constraint(equalTo: card.bottomAnchor),
                heightAnchor.constraint(equalToConstant: Self.thickness),
                leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: corner),
                trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -corner),
            ]
        case .corner:
            constraints = [
                trailingAnchor.constraint(equalTo: card.trailingAnchor),
                bottomAnchor.constraint(equalTo: card.bottomAnchor),
                widthAnchor.constraint(equalToConstant: corner),
                heightAnchor.constraint(equalToConstant: corner),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    override func layout() {
        super.layout()
        refreshGrip()
    }

    private var cursor: NSCursor {
        switch edge {
        case .trailing: return .resizeLeftRight
        case .bottom: return .resizeUpDown
        case .corner:
            if #available(macOS 15.0, *) { return .frameResize(position: .bottomRight, directions: .all) }
            return .crosshair
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshGrip()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshGrip()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragging = false
            onReset?(edge)
            return
        }
        dragging = true
        refreshGrip()
        onBegin?(edge, event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        cursor.set()
        onDrag?(edge, event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        refreshGrip()
        onEnd?(edge)
    }

    override func accessibilityPerformIncrement() -> Bool {
        onStep?(edge, 1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onStep?(edge, -1)
        return true
    }

    /// A short capsule on an edge, two diagonal strokes in the corner - the
    /// window corner's own grip - inside the card's rounded corner.
    private func refreshGrip() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        grip.frame = bounds
        let lit = hovering || dragging || isActive
        let color = lit ? HelmTheme.nsColor(theme.accentHex) : HelmTheme.mutedInk(theme).withAlphaComponent(0.55)
        grip.strokeColor = color.cgColor
        let path = CGMutablePath()
        let length: CGFloat = 28
        switch edge {
        case .trailing:
            grip.lineWidth = 4
            let x = bounds.maxX - 6
            path.move(to: CGPoint(x: x, y: bounds.midY - length / 2))
            path.addLine(to: CGPoint(x: x, y: bounds.midY + length / 2))
        case .bottom:
            grip.lineWidth = 4
            let y: CGFloat = isFlipped ? bounds.maxY - 6 : 6
            path.move(to: CGPoint(x: bounds.midX - length / 2, y: y))
            path.addLine(to: CGPoint(x: bounds.midX + length / 2, y: y))
        case .corner:
            // Kept inside the card's largest corner radius (20), whose arc is
            // ~6pt in from each edge along the diagonal.
            grip.lineWidth = 1.5
            let x = bounds.maxX
            path.move(to: CGPoint(x: x - 7, y: 12))
            path.addLine(to: CGPoint(x: x - 12, y: 7))
            path.move(to: CGPoint(x: x - 7, y: 17))
            path.addLine(to: CGPoint(x: x - 17, y: 7))
        }
        grip.path = path
    }

    #if FM_SELFTESTS
    /// A whole drag through the real mouse handlers, from the handle's centre
    /// by `dx`, `dy` points (positive `dy` is down the page), so a suite
    /// exercises the same arithmetic a pointer does.
    func debugDrag(dx: CGFloat, dy: CGFloat, steps: Int = 4) {
        let start = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                               clickCount: clicks, pressure: 1)
        }
        // Window coordinates are unflipped: down the page is a smaller y.
        let end = NSPoint(x: start.x + dx, y: start.y - dy)
        if let down = event(.leftMouseDown, start) { mouseDown(with: down) }
        for step in 1...max(1, steps) {
            let t = CGFloat(step) / CGFloat(max(1, steps))
            let point = NSPoint(x: start.x + dx * t, y: start.y - dy * t)
            if let drag = event(.leftMouseDragged, point) { mouseDragged(with: drag) }
        }
        if let up = event(.leftMouseUp, end) { mouseUp(with: up) }
    }

    func debugDoubleClick() {
        let start = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: 0,
                                         windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                         clickCount: 2, pressure: 1) {
            mouseDown(with: down)
        }
    }

    var debugGripColor: CGColor? { grip.strokeColor }
    #endif
}

/// The size a card is being dragged to, shown on the card while it is: its
/// width and height in points.
final class HomeCardSizeBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = HelmType.tabularCaption()
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            label.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s1),
        ])
        setAccessibilityElement(false)
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    func show(width: CGFloat, height: CGFloat) {
        label.stringValue = "\(Int(width.rounded())) \u{00D7} \(Int(height.rounded()))"
    }

    var text: String { label.stringValue }

    private func applyTheme(_ theme: HelmTheme) {
        HelmCard.applyCardSurface(to: self, theme: theme, cornerRadius: HelmMetrics.rChip + 3)
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        label.font = HelmType.tabularCaption()
    }
}
