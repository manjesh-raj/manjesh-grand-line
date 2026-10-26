// Grand Line - native macOS app.
//
// `HelmCardGrid` - the app's one grid of record cards (H1 and K1 of the
// captain's Termius-style plan): Connections' Hosts and Keys, as cards you
// can recognise at a glance, with the table (`HelmDataTable`) one click away.
//
// One component for both pages, for the reason `HelmDataTable` gives: a
// second hand-built copy is the single most common finding in this
// repository's audits.
//
// **Layout is arithmetic, not constraints.** The cards are laid out by frame
// in a flipped document view, from the clip view's real width: as many
// `minimumCardWidth` columns as fit (`HelmResponsiveGrid.columns`, the app's
// one column rule), each card the same width, a partial last row left short
// rather than stretched. So the grid reflows the moment its column narrows -
// the shell's inspector opening is H7's case - and nothing in it is a
// constraint the window could be sized by (gotcha (13)). Frames are rounded
// to the backing store's pixel grid, so a half-point column width (CI's 1x
// runner) never leaves a card on a blurred edge.
//
// **A card is a `HoverHighlightView`**, so it carries the role, the focus
// ring and the keyboard press every clickable row here has (GL-16). It has
// no click recognizer: a single click selects and a double click activates,
// read from the event's click count in `mouseDown` (H4), so a single click
// never waits to find out whether a second one is coming. The card's own
// icon buttons (H5's bolt and pencil) are real `HelmButton`s, hit-tested
// before the card, so their clicks are theirs alone (gotcha (20)).
//
// Keyboard: arrows move between cards (and select, so the inspector
// follows), Return activates, Space shows the details, ⌘E edits, Delete
// deletes - each only where the page gave the card that action.

import AppKit

final class HelmCardGrid: NSView {

    // MARK: Model

    /// A small fact on a card: a glyph and optional words.
    struct Badge {
        let symbol: String
        let text: String?
        let toolTip: String?
        init(symbol: String, text: String? = nil, toolTip: String? = nil) {
            self.symbol = symbol
            self.text = text
            self.toolTip = toolTip
        }
    }

    /// One of a card's always-visible icon buttons (H5's bolt and pencil).
    struct IconAction {
        let symbol: String
        /// The tooltip and the VoiceOver label.
        let label: String
        let run: () -> Void
    }

    struct Card {
        let key: String
        var symbol: String
        var tint: HelmTint
        /// A colour the captain chose (a host's own accent).
        var tintHex: String?
        var title: String
        var subtitle: String
        var subtitleIsCode = true
        /// A live state, drawn as `HelmStatusPill`'s dot and word.
        var status: (text: String, tint: HelmTint)?
        /// A quiet third line when there is no status ("Last connected 2h ago").
        var detail: String?
        var badges: [Badge] = []
        /// A short quiet chip at the start of the third line - a host's group
        /// in a grid that draws no group headers. The tooltip carries the
        /// whole of it, since the chip truncates.
        var chip: (text: String, toolTip: String)?
        var actions: [IconAction] = []
        /// Double click and Return.
        var activate: (() -> Void)?
        /// Space: open the details.
        var showDetails: (() -> Void)?
        /// ⌘E.
        var edit: (() -> Void)?
        /// Delete. The page confirms.
        var delete: (() -> Void)?
        /// The card's context menu.
        var menu: [HelmDataTable.Action] = []
        /// What VoiceOver reads for the card.
        var accessibilityLabel: String
    }

    struct Section {
        /// A group's name, drawn as the app's kicker. `nil` draws no header.
        let title: String?
        let cards: [Card]
        /// Show only as many cards as one row holds (X2's recent hosts).
        var singleRow = false
    }

    // MARK: Metrics

    static let baseCardHeight: CGFloat = 76
    static var cardHeight: CGFloat { HelmType.scaledRowHeight(baseCardHeight) }
    static let baseMinimumCardWidth: CGFloat = 236
    static var minimumCardWidth: CGFloat { (baseMinimumCardWidth * ChromeTextScale.shared.scale).rounded() }
    static let spacing: CGFloat = 12
    static let headerHeight: CGFloat = 30
    /// The gap above a section header that follows another section.
    static let sectionGap: CGFloat = HelmMetrics.s3

    // MARK: State

    /// The selected card's key, reported when the captain selects one (a
    /// click, an arrow). `nil` when the selection is cleared.
    var onSelect: ((String?) -> Void)?
    var accessibilityName = "Cards" {
        didSet { document.setAccessibilityLabel(accessibilityName) }
    }

    private(set) var selectedKey: String?
    private(set) var sections: [Section] = []
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var cardViews: [String: HelmGridCardView] = [:]
    private var headerLabels: [Int: NSTextField] = [:]
    private var emptyState: HelmEmptyState?
    private var emptyAction: (() -> Void)?
    /// The cards in reading order as last laid out, for arrow keys.
    private var placed: [(id: String, key: String, frame: NSRect)] = []
    private(set) var columnCount = 1
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var laidOutWidth: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        document.setAccessibilityElement(true)
        document.setAccessibilityRole(.group)
        document.setAccessibilityLabel(accessibilityName)
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Content

    /// Show `sections`, keeping the selection on its key when that card is
    /// still listed. Card views are reused by key, so a store change does not
    /// rebuild every card.
    func setSections(_ sections: [Section], selecting key: String? = nil) {
        self.sections = sections
        let keep = key ?? selectedKey
        var wanted = Set<String>()
        for (sectionIndex, section) in sections.enumerated() {
            for card in section.cards {
                let id = Self.viewID(section: sectionIndex, key: card.key)
                wanted.insert(id)
                let view = cardViews[id] ?? {
                    let made = HelmGridCardView()
                    made.grid = self
                    document.addSubview(made)
                    cardViews[id] = made
                    return made
                }()
                view.configure(card, theme: theme)
            }
        }
        for (id, view) in cardViews where !wanted.contains(id) {
            view.removeFromSuperview()
            cardViews[id] = nil
        }
        let allKeys = Set(sections.flatMap { $0.cards.map(\.key) })
        selectedKey = keep.flatMap { allKeys.contains($0) ? $0 : nil }
        refreshSelection()
        laidOutWidth = -1
        needsLayout = true
        layoutCards()
    }

    /// The empty state under the cards, or none.
    func setEmptyState(symbol: String, title: String, body: String, action: HelmDataTable.Action?) {
        emptyState?.removeFromSuperview()
        let caption = title.isEmpty ? body : "\(title). \(body)"
        let state: HelmEmptyState
        if let action {
            let button = HelmButton(title: action.title, variant: .secondary, size: .small, symbol: action.symbol,
                                    target: self, action: #selector(emptyActionClicked))
            state = HelmEmptyState(symbol: symbol, body: caption, size: .quiet, accessory: button)
        } else {
            state = HelmEmptyState(symbol: symbol, body: caption, size: .quiet)
        }
        emptyAction = action?.run
        state.translatesAutoresizingMaskIntoConstraints = true
        state.applyTheme(theme)
        document.addSubview(state)
        emptyState = state
        laidOutWidth = -1
        layoutCards()
    }

    func clearEmptyState() {
        emptyState?.removeFromSuperview()
        emptyState = nil
        emptyAction = nil
        laidOutWidth = -1
        layoutCards()
    }

    @objc private func emptyActionClicked() { emptyAction?() }

    /// Select the card with `key` (or clear), as a click would - reported
    /// through `onSelect` - and scroll it into view.
    func select(key: String?) {
        setSelected(key, notify: true)
        if let key, let entry = placed.first(where: { $0.key == key }) {
            document.scrollToVisible(entry.frame.insetBy(dx: 0, dy: -Self.spacing))
        }
    }

    /// Move the selection without reporting it - the table beside this grid
    /// mirroring a selection the captain made there.
    func setSelected(_ key: String?, notify: Bool) {
        let resolved = key.flatMap { k in sections.contains { $0.cards.contains { $0.key == k } } ? k : nil }
        guard resolved != selectedKey else { return }
        selectedKey = resolved
        refreshSelection()
        if notify { onSelect?(resolved) }
    }

    /// Put the keyboard on the selected card, or the first one.
    func focus() {
        let id = placed.first { $0.key == selectedKey }?.id ?? placed.first?.id
        if let id, let view = cardViews[id] { window?.makeFirstResponder(view) }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        for (id, view) in cardViews {
            guard let card = card(forViewID: id) else { continue }
            view.configure(card, theme: theme)
        }
        for label in headerLabels.values { styleHeader(label) }
        emptyState?.applyTheme(theme)
        refreshSelection()
        laidOutWidth = -1
        needsLayout = true
    }

    private func refreshSelection() {
        for (id, view) in cardViews { view.isSelected = Self.key(fromViewID: id) == selectedKey }
    }

    // MARK: Layout

    private static func viewID(section: Int, key: String) -> String { "\(section)|\(key)" }
    private static func key(fromViewID id: String) -> String {
        String(id[id.index(after: id.firstIndex(of: "|") ?? id.startIndex)...])
    }

    private func card(forViewID id: String) -> Card? {
        guard let bar = id.firstIndex(of: "|"), let section = Int(id[..<bar]), section < sections.count else { return nil }
        let key = Self.key(fromViewID: id)
        return sections[section].cards.first { $0.key == key }
    }

    /// The columns and card width at `width`, the same arithmetic every other
    /// card grid here uses.
    static func plan(width: CGFloat) -> (columns: Int, cardWidth: CGFloat) {
        let columns = HelmResponsiveGrid.columns(containerWidth: width, minItemWidth: minimumCardWidth, spacing: spacing)
        let cardWidth = HelmResponsiveGrid.itemWidth(containerWidth: width, columns: columns, spacing: spacing)
        return (columns, cardWidth)
    }

    /// `value` on the backing store's pixel grid: whole points at 1x, half
    /// points at 2x.
    static func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    override func layout() {
        super.layout()
        layoutCards()
    }

    @objc private func clipResized() {
        // GL-20: the cheap staleness check first.
        guard abs(contentWidth - laidOutWidth) > 0.25 else { return }
        layoutCards()
    }

    /// The width the cards are laid out in. `contentSize`, not the clip
    /// view's bounds: it follows the scroll view's own frame and scroller
    /// style the moment `super.layout()` has set them, while the clip view is
    /// only re-tiled later in the same pass - measured, a grid laid out from
    /// the clip view kept a 574pt plan in a 1200pt column.
    private var contentWidth: CGFloat { scroll.contentSize.width }

    private func layoutCards() {
        let width = contentWidth
        guard width > 0 else { return }
        laidOutWidth = width
        let (columns, cardWidth) = Self.plan(width: width)
        columnCount = columns
        let scale = window?.backingScaleFactor ?? 2
        func px(_ value: CGFloat) -> CGFloat { Self.pixelAligned(value, scale: scale) }
        let height = Self.cardHeight
        var y: CGFloat = 0
        var placed: [(id: String, key: String, frame: NSRect)] = []
        var usedHeaders = Set<Int>()
        for (sectionIndex, section) in sections.enumerated() where !section.cards.isEmpty {
            if y > 0 { y += Self.sectionGap }
            if let title = section.title {
                let label = headerLabels[sectionIndex] ?? {
                    let made = NSTextField(labelWithString: "")
                    document.addSubview(made)
                    headerLabels[sectionIndex] = made
                    return made
                }()
                label.attributedStringValue = NSAttributedString(
                    string: title.uppercased(), attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
                label.setAccessibilityLabel(title)
                label.isHidden = false
                let labelHeight = label.intrinsicContentSize.height
                label.frame = NSRect(x: 2, y: px(y + Self.headerHeight - labelHeight - HelmMetrics.s1),
                                     width: width - 2, height: labelHeight)
                usedHeaders.insert(sectionIndex)
                y += Self.headerHeight
            }
            let shown = section.singleRow ? Array(section.cards.prefix(columns)) : section.cards
            for (index, card) in section.cards.enumerated() {
                let id = Self.viewID(section: sectionIndex, key: card.key)
                guard let view = cardViews[id] else { continue }
                guard index < shown.count else { view.isHidden = true; continue }
                view.isHidden = false
                let row = index / columns, column = index % columns
                let x = px(CGFloat(column) * (cardWidth + Self.spacing))
                let right = px(CGFloat(column) * (cardWidth + Self.spacing) + cardWidth)
                let frame = NSRect(x: x, y: px(y + CGFloat(row) * (height + Self.spacing)), width: right - x, height: height)
                view.frame = frame
                placed.append((id, card.key, frame))
            }
            let rows = (shown.count + columns - 1) / columns
            y += CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * Self.spacing
        }
        for (index, label) in headerLabels where !usedHeaders.contains(index) { label.isHidden = true }
        if let emptyState {
            if y > 0 { y += Self.spacing }
            let fit = emptyState.fittingSize.height
            emptyState.frame = NSRect(x: 0, y: px(y), width: width, height: max(fit, 96))
            y += max(fit, 96)
        }
        self.placed = placed
        let documentHeight = max(y + Self.spacing, scroll.contentView.bounds.height)
        if document.frame.size != NSSize(width: width, height: documentHeight) {
            document.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        }
    }

    private func styleHeader(_ label: NSTextField) {
        let text = label.accessibilityLabel() ?? label.stringValue
        label.attributedStringValue = NSAttributedString(
            string: text.uppercased(), attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
    }

    // MARK: Cards' events

    fileprivate func cardClicked(_ view: HelmGridCardView, clickCount: Int) {
        guard let id = cardViews.first(where: { $0.value === view })?.key else { return }
        setSelected(Self.key(fromViewID: id), notify: true)
        if clickCount >= 2 { card(forViewID: id)?.activate?() }
    }

    fileprivate func cardFocused(_ view: HelmGridCardView) {
        guard let id = cardViews.first(where: { $0.value === view })?.key else { return }
        setSelected(Self.key(fromViewID: id), notify: true)
    }

    fileprivate func card(of view: HelmGridCardView) -> Card? {
        guard let id = cardViews.first(where: { $0.value === view })?.key else { return nil }
        return card(forViewID: id)
    }

    /// Arrow keys: the neighbour in reading order (left, right), or the
    /// card in the row above or below nearest the same column.
    fileprivate func moveFocus(from view: HelmGridCardView, keyCode: UInt16) -> Bool {
        guard let index = placed.firstIndex(where: { cardViews[$0.id] === view }) else { return false }
        let here = placed[index].frame
        var target: Int?
        switch keyCode {
        case 123: target = index > 0 ? index - 1 : nil                    // left
        case 124: target = index + 1 < placed.count ? index + 1 : nil     // right
        case 125, 126:                                                     // down, up
            let down = keyCode == 125
            let candidates = placed.enumerated().filter { down ? $0.element.frame.minY > here.minY + 1
                                                               : $0.element.frame.minY < here.minY - 1 }
            guard let rowY = (down ? candidates.map(\.element.frame.minY).min() : candidates.map(\.element.frame.minY).max())
            else { return true }
            target = candidates.filter { abs($0.element.frame.minY - rowY) < 1 }
                .min { abs($0.element.frame.midX - here.midX) < abs($1.element.frame.midX - here.midX) }?.offset
        default: return false
        }
        guard let target, let next = cardViews[placed[target].id] else { return true }
        window?.makeFirstResponder(next)
        document.scrollToVisible(placed[target].frame.insetBy(dx: 0, dy: -Self.spacing))
        return true
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugScroll: NSScrollView { scroll }
    /// The cards on screen, in reading order, with their frames.
    var debugPlaced: [(key: String, frame: NSRect)] { placed.map { ($0.key, $0.frame) } }
    var debugSectionTitles: [String] { sections.filter { !$0.cards.isEmpty }.compactMap(\.title) }
    func debugCardView(key: String) -> HelmGridCardView? {
        placed.first { $0.key == key }.flatMap { cardViews[$0.id] }
    }
    var debugEmptyState: HelmEmptyState? { emptyState }
    func debugSelect(titled title: String) -> Bool {
        guard let card = sections.flatMap(\.cards).first(where: { $0.title == title }) else { return false }
        select(key: card.key)
        return true
    }
    #endif
}

// MARK: - One card

/// A record card: the tile, the title, one subtitle, a status or detail line
/// or badges, and the always-visible icon buttons.
final class HelmGridCardView: HoverHighlightView {
    fileprivate weak var grid: HelmCardGrid?

    var isSelected = false {
        didSet { if isSelected != oldValue { applyState() } }
    }

    private let tile = IconTileView(size: 34, cornerRadius: 9)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let statusPill = HelmStatusPill(style: .dotWord)
    private let detailLabel = NSTextField(labelWithString: "")
    private let badgeRow = NSStackView()
    private let chip = HelmTagChip(text: "", theme: ThemeManager.shared.theme)
    /// The chip's place in the third line: a text line tall, with the chip's
    /// own padding drawn past it, so a card with a chip keeps its third line
    /// exactly where a card without one has it.
    private let chipSlot = NSView()
    private lazy var chipWidthCap = chip.widthAnchor.constraint(lessThanOrEqualToConstant: Self.chipMaximumWidth)
    /// The third line: the chip, then whichever of the status, the detail
    /// and the badges the card has.
    private let metaRow = NSStackView()
    private let actionRow = NSStackView()
    private var actionButtons: [HelmButton] = []
    private var actionRuns: [() -> Void] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var isFocused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Laid out by frame, by the grid. `HoverHighlightView` turns this
        // off for its usual Auto Layout callers.
        translatesAutoresizingMaskIntoConstraints = true
        cornerRadius = HelmMetrics.rCard
        layer?.borderWidth = 1
        for label in [titleLabel, subtitleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        badgeRow.orientation = .horizontal
        badgeRow.spacing = HelmMetrics.s2
        badgeRow.alignment = .centerY
        badgeRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        // A stack has no intrinsic size, so its own hugging is the one that
        // keeps the badges together rather than spread over the card
        // (gotcha (12)).
        badgeRow.setHuggingPriority(.required, for: .horizontal)
        chipSlot.isHidden = true
        chipSlot.translatesAutoresizingMaskIntoConstraints = false
        chipSlot.addSubview(chip)
        chip.setAccessibilityElement(true)
        chip.setAccessibilityRole(.staticText)
        NSLayoutConstraint.activate([
            chipWidthCap,
            chip.leadingAnchor.constraint(equalTo: chipSlot.leadingAnchor),
            chip.trailingAnchor.constraint(equalTo: chipSlot.trailingAnchor),
            chip.centerYAnchor.constraint(equalTo: chipSlot.centerYAnchor),
            chipSlot.heightAnchor.constraint(equalTo: chip.heightAnchor, constant: -2 * HelmMetrics.s0),
        ])
        for view in [chipSlot, statusPill, detailLabel, badgeRow] as [NSView] { metaRow.addArrangedSubview(view) }
        metaRow.orientation = .horizontal
        metaRow.spacing = HelmMetrics.s2
        metaRow.alignment = .centerY
        metaRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        // The badge row's own shape, one level out (gotcha (12)).
        metaRow.setHuggingPriority(.required, for: .horizontal)
        let text = NSStackView(views: [titleLabel, subtitleLabel, metaRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s0
        text.setCustomSpacing(HelmMetrics.s1, after: subtitleLabel)
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)
        actionRow.orientation = .horizontal
        actionRow.spacing = HelmMetrics.s0
        actionRow.alignment = .centerY
        for view in [tile, text, actionRow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        actionRow.setContentHuggingPriority(.required, for: .horizontal)
        actionRow.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            tile.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3),
            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HelmMetrics.s3),
            text.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3 - 1),
            // Only the title shares its line with the icon buttons; the lines
            // under it run to the card's edge.
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionRow.leadingAnchor, constant: -HelmMetrics.s1),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.s3),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            metaRow.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            actionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            actionRow.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2),
        ])
        onHoverChange = { [weak self] _ in self?.applyState() }
        onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ card: HelmCardGrid.Card, theme: HelmTheme) {
        self.theme = theme
        tile.configure(symbol: card.symbol, tint: card.tint, pointSize: HelmType.scaled(14))
        if let hex = card.tintHex { tile.overrideFill(hex: hex) }
        tile.applyTheme(theme)
        titleLabel.stringValue = card.title
        titleLabel.font = HelmType.rowTitle()
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        titleLabel.toolTip = card.title.count > 26 ? card.title : nil
        subtitleLabel.stringValue = card.subtitle
        subtitleLabel.font = card.subtitleIsCode ? HelmType.code() : HelmType.caption()
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        // The subtitle truncates (a long address, or the Larger text
        // scale); the whole of it is one hover away.
        subtitleLabel.toolTip = card.subtitle
        if let status = card.status {
            statusPill.isHidden = false
            statusPill.configure(text: status.text, tint: status.tint, theme: theme)
        } else {
            statusPill.isHidden = true
        }
        detailLabel.isHidden = card.status != nil || card.detail == nil
        detailLabel.stringValue = card.detail ?? ""
        detailLabel.font = HelmType.captionSmall()
        detailLabel.textColor = HelmTheme.mutedInk(theme)
        if let content = card.chip {
            chipSlot.isHidden = false
            chip.text = content.text
            chip.toolTip = content.toolTip
            chip.setAccessibilityLabel(content.toolTip)
            chip.applyTheme(theme)
            chipWidthCap.constant = Self.chipMaximumWidth
        } else {
            chipSlot.isHidden = true
        }
        rebuildBadges(card.badges)
        rebuildActions(card.actions)
        accessibilityLabelOverride = card.accessibilityLabel
        onAccessibilityPress = card.activate ?? card.showDetails ?? {}
        toolTip = nil
        applyState()
    }

    private func rebuildBadges(_ badges: [HelmCardGrid.Badge]) {
        badgeRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        badgeRow.isHidden = badges.isEmpty
        let muted = HelmTheme.mutedInk(theme)
        for badge in badges {
            let icon = NSImageView()
            icon.image = HelmSymbol.image(badge.symbol, pointSize: HelmType.scaled(10), weight: .medium)
            icon.contentTintColor = muted
            var parts: [NSView] = [icon]
            if let text = badge.text {
                let label = NSTextField(labelWithString: text)
                label.font = HelmType.captionSmall()
                label.textColor = muted
                label.lineBreakMode = .byTruncatingTail
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                parts.append(label)
            }
            let item = NSStackView(views: parts)
            item.orientation = .horizontal
            item.spacing = HelmMetrics.s0
            item.setHuggingPriority(.required, for: .horizontal)
            item.toolTip = badge.toolTip
            item.setAccessibilityElement(true)
            item.setAccessibilityRole(.staticText)
            item.setAccessibilityLabel(badge.toolTip ?? badge.text)
            badgeRow.addArrangedSubview(item)
        }
    }

    private func rebuildActions(_ actions: [HelmCardGrid.IconAction]) {
        actionRuns = actions.map(\.run)
        if actionButtons.count != actions.count || zip(actionButtons, actions).contains(where: { $0.symbolName != $1.symbol }) {
            actionButtons.forEach { $0.removeFromSuperview() }
            actionButtons = actions.enumerated().map { index, action in
                let button = HelmButton(symbol: action.symbol, variant: .quiet, size: .small,
                                        target: self, action: #selector(actionClicked(_:)))
                button.tag = index
                button.setContentHuggingPriority(.required, for: .horizontal)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                actionRow.addArrangedSubview(button)
                return button
            }
        }
        for (button, action) in zip(actionButtons, actions) {
            button.toolTip = action.label
            button.setAccessibilityLabel(action.label)
        }
    }

    @objc private func actionClicked(_ sender: NSButton) {
        guard sender.tag < actionRuns.count else { return }
        actionRuns[sender.tag]()
    }

    /// The widest a chip may grow before it truncates, at the chrome text
    /// scale, so a long group name leaves the rest of the line room.
    static var chipMaximumWidth: CGFloat { HelmType.scaled(96) }

    /// C5: the icon buttons are always there at low emphasis (`.quiet`'s
    /// muted glyph) and at full strength (the same button in the accent, a
    /// contrast-checked `tint`) on hover, selection or keyboard focus. Same
    /// size either way, so the title beside them never reflows.
    var iconsAreEmphasised: Bool { isHovering || isSelected || isFocused }

    private func applyState() {
        let base = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let fill = isSelected ? (base.blended(withFraction: HelmAccentRow.selectionWash, of: accent) ?? base) : base
        normalColor = fill
        hoverColor = isSelected ? fill : HelmFlatList.rowHoverColor(theme, over: base)
        let edge = HelmDisplayAccessibility.strengthenedEdge(
            HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(HelmCard.borderAlpha), theme: theme)
        layer?.borderColor = (isSelected ? accent : edge).cgColor
        layer?.borderWidth = isSelected ? 1.5 : 1
        let tint: HelmTint? = iconsAreEmphasised ? .accent : nil
        actionButtons.forEach { if $0.tint != tint { $0.tint = tint } }
    }

    // MARK: Mouse and keyboard

    /// H4: one click selects, two activate - read from the click count, so a
    /// single click is never held back waiting for a second.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        grid?.cardClicked(self, clickCount: event.clickCount)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let card = grid?.card(of: self), !card.menu.isEmpty else { return nil }
        grid?.cardClicked(self, clickCount: 1)
        let menu = NSMenu()
        for action in card.menu {
            let item = NSMenuItem(title: action.title, action: #selector(HelmGridCardMenuBox.fire), keyEquivalent: "")
            let box = HelmGridCardMenuBox(action.run)
            item.target = box
            item.representedObject = box
            if let symbol = action.symbol { item.image = HelmSymbol.image(symbol, pointSize: HelmType.scaled(12)) }
            menu.addItem(item)
        }
        return menu
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took {
            isFocused = true
            applyState()
            grid?.cardFocused(self)
        }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave {
            isFocused = false
            applyState()
        }
        return gave
    }

    /// Arrows, Return, Space, ⌘E and Delete. Return and Space are handled
    /// here rather than by `HoverHighlightView`'s press, which treats both as
    /// one key.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let card = grid?.card(of: self) else { return false }
        let modifiers = event.modifierFlags.intersection(KeyChord.relevantModifierMask)
        if modifiers == .command {
            // ⌘E edits.
            guard event.keyCode == 14, let edit = card.edit else { return false }
            edit()
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 123, 124, 125, 126:
            return grid?.moveFocus(from: self, keyCode: event.keyCode) ?? false
        case 36, 76:
            card.activate?()
            return card.activate != nil
        case 49:
            card.showDetails?()
            return card.showDetails != nil
        case 51, 117:
            card.delete?()
            return card.delete != nil
        default:
            return false
        }
    }

    /// The card is one VoiceOver button; its icon buttons are its children,
    /// so they stay reachable rather than being folded into its label.
    override func accessibilityChildren() -> [Any]? { actionButtons }

    #if FM_SELFTESTS
    var debugActionButtons: [HelmButton] { actionButtons }
    var debugTitle: String { titleLabel.stringValue }
    var debugSubtitle: String { subtitleLabel.stringValue }
    var debugSubtitleLabel: NSTextField { subtitleLabel }
    var debugStatus: String? { statusPill.isHidden ? nil : statusPill.label.stringValue }
    var debugDetail: String? { detailLabel.isHidden ? nil : detailLabel.stringValue }
    var debugChip: String? { chipSlot.isHidden ? nil : chip.text }
    /// The third line's badges, in the card's own coordinates.
    var debugBadgeRowFrame: NSRect { convert(badgeRow.frame, from: badgeRow.superview) }
    var debugChipView: NSView { chip }
    var debugBadgeTexts: [String] {
        badgeRow.arrangedSubviews.compactMap { $0.accessibilityLabel() }
    }
    var debugIsFocused: Bool { isFocused }
    func debugKey(_ keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window?.windowNumber ?? 0, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else { return }
        keyDown(with: event)
    }
    #endif
}

/// A context-menu item's closure, held by the item.
private final class HelmGridCardMenuBox: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
