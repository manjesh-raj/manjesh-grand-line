// Grand Line - native macOS app.
//
// The UI/UX revamp's component kit (UI-39): the shared pieces the Home and
// Tasks pages were each re-deriving privately, so every later page can be
// built from them rather than from a fifth copy.
//
// The revamp's finding was not that the app lacked a design system - it has a
// complete one (`HelmDesignSystem.swift`) - but that four ideas had no class
// of their own, so each page spelled them out by hand:
//
//   - **A status pill** was a function (`ToolRowLayout.pill`) that paints a
//     view the caller supplies, with 25 call sites across 18 files and two
//     hand-rolled copies that painted raw colour as text. `HelmStatusPill`
//     is the view, and it takes a `HelmTint`.
//   - **A section header** (tile or dot, title, a muted count, a trailing
//     action) was built by hand three times on Tasks alone and six times on
//     Home. `HelmSectionHeader` is the one header, in three sizes.
//   - **A flat list** - rows separated by a hairline inside one card, rather
//     than each row being a bordered card of its own - had no container, so
//     every list nested a bordered row inside a bordered card. `HelmFlatList`
//     is that container; `HelmAccentRow.Style.flat` is its row.
//
// Everything here is `NSStackView` layout, a layer fill, a 1px line and SF
// fonts, on the existing tokens. Nothing in this file invents a colour.
//
// AppKit landmines this file is shaped around (AGENTS.md):
//
//   - gotcha (10)/(12): every horizontal stack is `.fill`, and the one flexible
//     member is a text column given the *stack*-level priorities.
//   - gotcha (11): every view clears `translatesAutoresizingMaskIntoConstraints`
//     before its constraints go on.
//   - gotcha (13): nothing here carries a width constraint above
//     `HelmDaylightPriority.contentTie`.

import AppKit

// MARK: - HelmStatusPill

/// The app's one status pill: a capsule of contrast-corrected tint behind a
/// short word, or - for a state that is the default - a dot and a word.
///
/// **Why a class.** The pill recipe (capsule, `HelmType.chip()`, 9/3 padding,
/// `HelmContrast.tintedSurface`) lived in `ToolRowLayout.pill`, which paints a
/// view the caller supplies. That made the recipe re-spellable, and it was:
/// the Tasks page's sync pill overrode its font to a 10.5pt mono that
/// bypassed the 11pt floor, and two pills on that page painted a raw hue as
/// text with no contrast correction at all. A view that owns its own label
/// cannot be re-spelled from outside.
///
/// **Two styles, one rule.** The revamp's Rule 3 is that colour means a state
/// that is not the default. So a default state ("Synced", "All clear") is
/// `.dotWord` - an 8pt dot in the hue and the word in contrast-corrected ink -
/// and only a non-default state ("Local changes", "Conflict", "Not read")
/// takes the capsule.
///
/// It takes a `HelmTint`, never a hex. The one exception is
/// `configure(text:literalHex:)`, for a record carrying a colour the
/// *captain* chose (a saved host's own accent) - the same carve-out
/// `HelmAccentRow.Content.tintHex` documents.
final class HelmStatusPill: NSView {

    enum Style: Equatable {
        /// The capsule. For a state that is not the default.
        case pill
        /// An 8pt dot and the word. For the default state, where a capsule
        /// would spend colour on "nothing is wrong".
        case dotWord
    }

    /// Settable: a list row's status moves between the two as its state
    /// changes ("Up to date" is a dot and a word, "Update available" a pill).
    var style: Style {
        didSet { if style != oldValue { applyStyleLayout(); applyTheme(lastTheme) } }
    }
    /// 1.1.0: a pill on a hero gradient (SRE Lead's header, Sre-2). The
    /// capsule takes `HelmButton`'s ghost recipe - a translucent shade of the
    /// ink's opposite, a hairline of the ink - and the word is the ink itself,
    /// so it reads as the hero's own words rather than a tinted chip pasted on
    /// it. `.pill` only. `nil`, the default, changes nothing.
    var heroInk: NSColor? {
        didSet { if heroInk != oldValue { applyTheme(lastTheme) } }
    }

    /// The word. Read-only to callers - the pill owns its font and colour.
    let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var colorHex: String?
    private var tint: HelmTint?
    private var lastTheme: HelmTheme = ThemeManager.shared.theme
    private var pillConstraints: [NSLayoutConstraint] = []
    private var dotConstraints: [NSLayoutConstraint] = []
    /// 1.1.0: the word's width as its cell draws it, rounded up to a whole
    /// point. The label's intrinsic width can sit a fraction under what the
    /// cell needs (40.5pt against 44.1pt with the cell's insets, measured on
    /// "AHEAD"), and where layout rounds to whole points - a 1x display, or a
    /// view rendered off-window - the pill came out 0.1pt short and drew
    /// "AHE…".
    ///
    /// Not required: a row that deliberately squeezes a pill still truncates
    /// it. 740 sits under the label's own compression resistance (750), so it
    /// adds no new way for a pill to push on a window (gotcha (13)).
    private lazy var wordWidth: NSLayoutConstraint = {
        let floor = label.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        floor.priority = NSLayoutConstraint.Priority(740)
        return floor
    }()

    static let dotSize: CGFloat = 8

    init(style: Style = .pill) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = HelmType.chip()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = Self.dotSize / 2
        addSubview(dot)
        // Added here, before `ToolRowLayout.pill` ever sees it, so that
        // helper adds no constraints of its own (it only does for a label it
        // has to parent) - this class owns both layouts.
        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        // `ToolRowLayout.pill`'s 9/3 padding, which is the pill recipe.
        pillConstraints = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ]
        dotConstraints = [
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: HelmMetrics.s1 + 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ]
        applyStyleLayout()
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func applyStyleLayout() {
        NSLayoutConstraint.deactivate(pillConstraints + dotConstraints)
        NSLayoutConstraint.activate(style == .pill ? pillConstraints : dotConstraints)
        dot.isHidden = style == .pill
    }

    var text: String { label.stringValue }

    func configure(text: String, tint: HelmTint, theme: HelmTheme = ThemeManager.shared.theme) {
        self.tint = tint
        self.colorHex = nil
        label.stringValue = text
        applyTheme(theme)
    }

    /// The same, choosing the style in one call - for a status whose default
    /// state is a dot and a word and whose other states are a pill (UI-43).
    func configure(text: String, tint: HelmTint, style: Style, theme: HelmTheme = ThemeManager.shared.theme) {
        self.style = style
        configure(text: text, tint: tint, theme: theme)
    }

    /// For a colour the captain chose, never one the app decides - see the
    /// class comment.
    func configure(text: String, literalHex: String, theme: HelmTheme = ThemeManager.shared.theme) {
        self.tint = nil
        self.colorHex = literalHex
        label.stringValue = text
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        lastTheme = theme
        let hex = colorHex ?? tint?.hex(in: theme) ?? theme.chromeInkHex
        switch style {
        case .pill:
            ToolRowLayout.pill(text: label.stringValue, colorHex: hex, into: self, label: label, theme: theme)
            // `ToolRowLayout.pill` sets the twelve legacy palettes' semibold;
            // the kit's one chip face is `HelmType.chip()` everywhere.
            label.font = HelmType.chip()
            if let heroInk {
                let ghost = HelmButton.heroPalette(ink: heroInk, enabled: true)
                layer?.backgroundColor = ghost.fill.cgColor
                layer?.borderColor = ghost.border.cgColor
                layer?.borderWidth = 1
                label.textColor = heroInk
            } else {
                layer?.borderWidth = 0
            }
        case .dotWord:
            layer?.borderWidth = 0
            let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
            dot.layer?.backgroundColor = HelmTheme.nsColor(hex).cgColor
            label.font = HelmType.chip()
            label.textColor = HelmContrast.legibleTintedText(tintHex: hex, over: surface, theme: theme)
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        wordWidth.constant = ceil(label.cell?.cellSize.width ?? 0)
        wordWidth.isActive = true
        setAccessibilityLabel(label.stringValue)
    }

    #if FM_SELFTESTS
    var debugLabel: NSTextField { label }
    var debugFill: NSColor? { layer?.backgroundColor.map { NSColor(cgColor: $0) ?? .clear } }
    var debugDotColor: NSColor? { dot.layer?.backgroundColor.map { NSColor(cgColor: $0) ?? .clear } }
    #endif
}

// MARK: - HelmSectionHeader

/// The app's one section header: an optional tile or dot, a title, a muted
/// count, and a trailing slot for actions.
///
/// **Three sizes, one shape.**
///
///   - `.section` - a card's own header (Follow-ups, Projects, Pushed back):
///     a 30pt tile, the `moduleTitle` face, the count beside it.
///   - `.lane` - a board lane or a list group (Backlog, In Progress): an 8pt
///     dot, the `rowTitle` face, the count beside it. A tile at the top of
///     three lanes reads as three buttons; a dot says which pile this is at a
///     fraction of the weight.
///   - `.hero` - the page's lead card (Home's Needs attention): a 34pt tile
///     beside an eyebrow, a 19pt heavy rounded headline and a subline.
///
/// The count is text, never a capsule. A capsule is `HelmStatusPill`'s, and
/// it means a state; a count is a number, and it sits muted beside its title
/// the way OmniFocus and Tower set theirs (the revamp's section 7).
final class HelmSectionHeader: NSView {

    /// `.card` (S15 of the 2026-11-17 UI/UX proposals) is a card's own
    /// header: a 26pt tile, a title, a subtitle under it, the count in a
    /// `HelmCountBadge` and the card's one action in the trailing slot.
    /// `HelmCard.setHeader(_:)` takes it.
    enum Size: Equatable { case section, lane, hero, card }

    enum Leading: Equatable {
        case none
        case dot(HelmTint)
        case tile(symbol: String, tint: HelmTint)
    }

    let size: Size
    let titleLabel: NSTextField
    let countLabel: NSTextField
    let eyebrowLabel = NSTextField(labelWithString: "")
    let sublineLabel = NSTextField(labelWithString: "")
    private let tile: IconTileView
    private let dot = NSView()
    private let actionStack = NSStackView()
    /// `.card` only: the count, as the kit's count pill rather than the
    /// muted figure the other sizes draw beside the title.
    private let countBadge = HelmCountBadge()
    private var actionViews: [NSView] = []
    private var leading: Leading = .none

    static let dotSize: CGFloat = 8
    /// Above every stack default and the spacer, under the window's own 500.
    static let textResistance = NSLayoutConstraint.Priority(490)
    /// `.card`: the row clips only after its text has truncated.
    static let cardClippingResistance = NSLayoutConstraint.Priority(495)
    static func tileSide(for size: Size) -> CGFloat {
        switch size {
        case .hero: return HelmMetrics.tileBase
        case .card: return HelmMetrics.tileSmall
        case .section, .lane: return 30
        }
    }

    /// - Parameters:
    ///   - titleLabel, countLabel: caller-owned labels, for a page that
    ///     rewrites the title or the count as data arrives (Tasks' "2 pending")
    ///     and already holds the label. The header still owns their fonts and
    ///     colours, so the page only ever sets `stringValue`.
    init(size: Size,
         titleLabel: NSTextField = NSTextField(labelWithString: ""),
         countLabel: NSTextField = NSTextField(labelWithString: "")) {
        self.size = size
        self.titleLabel = titleLabel
        self.countLabel = countLabel
        let side = Self.tileSide(for: size)
        tile = IconTileView(size: side, cornerRadius: HelmMetrics.dTileSmall)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        for label in [titleLabel, countLabel, eyebrowLabel, sublineLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
        }
        // gotcha (13): a header can span the page, so no label in it may be
        // a width floor - its compression resistance stays under 500. But it
        // must beat the spacer beside it, which has no intrinsic width and
        // would otherwise take the title's room and truncate a headline that
        // fits (measured: "Two things a..." on a 1512pt Home).
        for label in [titleLabel, eyebrowLabel, sublineLabel] {
            label.setContentCompressionResistancePriority(Self.textResistance, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = Self.dotSize / 2
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
        ])
        for view in [dot, tile] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.isHidden = true
        }

        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = HelmMetrics.s2
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.setHuggingPriority(.required, for: .horizontal)
        actionStack.setClippingResistancePriority(.required, for: .horizontal)

        // The title and the count share one baseline row; the hero size puts
        // an eyebrow above that row and a subline below it.
        let titleRow = NSStackView(views: [titleLabel, countLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = HelmMetrics.s2 - 2
        titleRow.distribution = .fill
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.setHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.setClippingResistancePriority(Self.textResistance, for: .horizontal)

        let textColumn: NSView
        if size == .card {
            // One line that truncates: the card's trailing action must never
            // be the thing that gives way (it is required; the text is 490).
            let column = NSStackView(views: [titleRow, sublineLabel])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = HelmMetrics.s0
            column.translatesAutoresizingMaskIntoConstraints = false
            column.setHuggingPriority(.defaultLow, for: .horizontal)
            column.setClippingResistancePriority(Self.textResistance, for: .horizontal)
            eyebrowLabel.isHidden = true
            countLabel.isHidden = true
            countBadge.isHidden = true
            countBadge.setContentHuggingPriority(.required, for: .horizontal)
            countBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
            actionStack.addArrangedSubview(countBadge)
            textColumn = column
        } else if size == .hero {
            let column = NSStackView(views: [eyebrowLabel, titleRow, sublineLabel])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = HelmMetrics.s0
            column.setCustomSpacing(HelmMetrics.s1, after: eyebrowLabel)
            column.translatesAutoresizingMaskIntoConstraints = false
            column.setHuggingPriority(.defaultLow, for: .horizontal)
            column.setClippingResistancePriority(Self.textResistance, for: .horizontal)
            textColumn = column
        } else {
            eyebrowLabel.isHidden = true
            sublineLabel.isHidden = true
            textColumn = titleRow
        }

        // A spacer rather than letting the text column absorb the slack, so
        // the title row hugs its text and the actions sit at the trailing
        // edge under `.fill` (gotcha (10)).
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [dot, tile, textColumn, spacer, actionStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = size == .lane ? HelmMetrics.s2 : HelmMetrics.s3
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        // A `.card` header compresses its text before it clips its trailing
        // action, so its clipping resistance sits just above the text's 490 -
        // still under the window's 500 (gotcha (13)).
        row.setClippingResistancePriority(size == .card ? Self.cardClippingResistance : .defaultLow, for: .horizontal)
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// - Parameters:
    ///   - count: the muted figure beside the title ("4", "2 pending"), or
    ///     `nil` for none. Never a zero standing in for an unknown (GL-14) -
    ///     a caller that has not read its list passes `nil`.
    func configure(leading: Leading = .none,
                   title: String,
                   count: String? = nil,
                   eyebrow: String? = nil,
                   subline: String? = nil) {
        self.leading = leading
        titleLabel.stringValue = title
        countLabel.stringValue = count ?? ""
        countLabel.isHidden = (count ?? "").isEmpty || size == .card
        if size == .card {
            countBadge.text = count ?? ""
            countBadge.isHidden = (count ?? "").isEmpty
            sublineLabel.stringValue = subline ?? ""
            sublineLabel.isHidden = (subline ?? "").isEmpty
            refreshActionStackVisibility()
        }
        if size == .hero {
            eyebrowLabel.stringValue = (eyebrow ?? "").uppercased()
            eyebrowLabel.isHidden = (eyebrow ?? "").isEmpty
            sublineLabel.stringValue = subline ?? ""
            sublineLabel.isHidden = (subline ?? "").isEmpty
        }
        switch leading {
        case .none:
            dot.isHidden = true
            tile.isHidden = true
        case .dot:
            dot.isHidden = false
            tile.isHidden = true
        case let .tile(symbol, tint):
            dot.isHidden = true
            tile.isHidden = false
            tile.configure(symbol: symbol, tint: tint, pointSize: size == .hero ? 15 : size == .card ? 12 : 13)
        }
        applyTheme(ThemeManager.shared.theme)
    }

    /// The trailing slot. Replaces whatever was there.
    func setActions(_ views: [NSView]) {
        for view in actionStack.arrangedSubviews where view !== countBadge {
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            actionStack.addArrangedSubview(view)
        }
        actionViews = views
        refreshActionStackVisibility()
    }

    private func refreshActionStackVisibility() {
        actionStack.isHidden = actionViews.isEmpty && (size != .card || countBadge.isHidden)
    }

    func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        switch size {
        case .section:
            titleLabel.font = HelmType.moduleTitle()
        case .lane:
            titleLabel.font = HelmType.rowTitle()
        case .card:
            titleLabel.font = HelmType.cardTitle()
            sublineLabel.font = HelmType.caption()
            sublineLabel.textColor = muted
            countBadge.applyTheme(theme)
        case .hero:
            titleLabel.font = HelmType.rounded(HelmType.scaled(19), .heavy)
            eyebrowLabel.attributedStringValue = NSAttributedString(
                string: eyebrowLabel.stringValue,
                attributes: HelmType.kickerAttributes(color: muted))
            sublineLabel.font = HelmType.caption()
            sublineLabel.textColor = muted
        }
        titleLabel.textColor = ink
        countLabel.font = HelmType.metric(11, weight: .medium)
        countLabel.textColor = muted
        if case let .dot(tint) = leading {
            // A hue as a *fill* is always safe - it is never text.
            dot.layer?.backgroundColor = HelmTheme.nsColor(tint.hex(in: theme)).cgColor
        }
        tile.applyTheme(theme)
    }

    #if FM_SELFTESTS
    var debugLeading: Leading { leading }
    var debugActions: [NSView] { actionStack.arrangedSubviews }
    var debugTileVisible: Bool { !tile.isHidden }
    var debugDotVisible: Bool { !dot.isHidden }
    var debugSubline: String { sublineLabel.isHidden ? "" : sublineLabel.stringValue }
    var debugCountBadgeText: String? { countBadge.isHidden || size != .card ? nil : countBadge.text }
    var debugTileSide: CGFloat { tile.fittingSize.width }
    #endif
}

// MARK: - HelmFlatList

/// A list of flat rows inside one card: the rows carry no border, and a
/// hairline separates each from the next.
///
/// The revamp's Rule 1 - one bordered surface per level. A card is the only
/// thing with a border and a shadow; a row inside it is flat. Before this,
/// every list in the app put a bordered `HelmAccentRow` card inside a
/// bordered `HelmCard`, and the Tasks board put those inside a bordered
/// column inside the page - four nested outlines where the mockups draw one.
///
/// The separators belong to the list rather than to the rows, so a row knows
/// nothing about whether it is first or last, and a rebuilt list can never
/// leave a doubled or dangling line.
final class HelmFlatList: NSView {

    private let stack = NSStackView()
    private var separators: [NSView] = []
    private(set) var rows: [NSView] = []
    /// Whether a hairline also runs above the first row - for a list that
    /// sits directly under a header with no divider of its own.
    var separatesFirstRow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setRows(_ newRows: [NSView], theme: HelmTheme = ThemeManager.shared.theme) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        separators.removeAll()
        rows = newRows
        for (index, row) in newRows.enumerated() {
            if index > 0 || separatesFirstRow { add(makeSeparator()) }
            add(row)
        }
        applyTheme(theme)
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        // Full width at `contentTie`, never required: a list can span the
        // page, and a required width tie on something page-wide is gotcha
        // (13)'s window-size cap.
        let tie = view.widthAnchor.constraint(equalTo: stack.widthAnchor)
        tie.priority = HelmDaylightPriority.contentTie
        tie.isActive = true
    }

    private func makeSeparator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        separators.append(line)
        return line
    }

    func applyTheme(_ theme: HelmTheme) {
        let color = Self.hairRowColor(theme)
        for line in separators { line.layer?.backgroundColor = color.cgColor }
    }

    /// §6.5's `hairRow` - a lighter line than a card's own outline, so a list
    /// reads as one object rather than as stacked boxes. The twelve legacy
    /// palettes take a damped `chromeLineHex`, the same split
    /// `HelmCard.applyTheme` already makes for its header divider.
    static func hairRowColor(_ theme: HelmTheme) -> NSColor {
        theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.hairRow)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(HelmCard.dividerAlpha)
    }

    /// §6.5's `rowHover` over `base`: Daylight's own token, or a light wash of
    /// page ink on the other palettes - the fill every flat row shares.
    static func rowHoverColor(_ theme: HelmTheme, over base: NSColor) -> NSColor {
        theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.rowHover)
            : (base.blended(withFraction: 0.06, of: HelmTheme.nsColor(theme.chromeInkHex)) ?? base)
    }

    /// P5: Up and Down move between the rows, the way a table does.
    /// Return and Space already press a focused row (`HoverHighlightView`).
    override func keyDown(with event: NSEvent) {
        if HelmListNavigation.handle(event, rows: rows) { return }
        super.keyDown(with: event)
    }

    #if FM_SELFTESTS
    var debugSeparatorCount: Int { separators.count }
    #endif
}

// MARK: - Arrow keys in a custom list

/// P5 of the Grand Line vs Automic Vault polish report: Up and Down between
/// the rows of a list this app builds from views rather than from an
/// `NSTableView`.
///
/// A focused row (a `HoverHighlightView`) handles Return and Space itself
/// and passes every other key up the responder chain, so the list that owns
/// the rows sees the arrows. It moves the keyboard to the previous or next
/// row that can take it - the row itself, or its first control when the row
/// is not focusable but carries one (a "Start" button). At either end the key
/// is consumed and nothing moves, as in a table, rather than beeping.
enum HelmListNavigation {

    /// Whether `event` was an arrow this handled.
    static func handle(_ event: NSEvent, rows: [NSView]) -> Bool {
        let step: Int
        switch event.keyCode {
        case 125: step = 1    // Down
        case 126: step = -1   // Up
        default: return false
        }
        guard event.modifierFlags.intersection(KeyChord.relevantModifierMask).isEmpty,
              let window = rows.first?.window,
              let responder = window.firstResponder as? NSView,
              let current = rows.firstIndex(where: { responder === $0 || responder.isDescendant(of: $0) })
        else { return false }
        var index = current + step
        while rows.indices.contains(index) {
            if let target = focusTarget(in: rows[index]) {
                window.makeFirstResponder(target)
                target.scrollToVisible(target.bounds)
                return true
            }
            index += step
        }
        return true
    }

    /// The view in `row` that takes the keyboard: the row itself, or its
    /// first descendant that can.
    static func focusTarget(in row: NSView) -> NSView? {
        if row.canBecomeKeyView { return row }
        for sub in row.subviews {
            if let found = focusTarget(in: sub) { return found }
        }
        return nil
    }
}

/// A plain container whose subviews are a list's rows, for a list laid out
/// by hand rather than through `HelmFlatList` - a module card's peek rows.
final class HelmKeyboardListView: NSView {
    override func keyDown(with event: NSEvent) {
        if HelmListNavigation.handle(event, rows: subviews) { return }
        super.keyDown(with: event)
    }
}

// MARK: - HelmReading

/// A value that was fetched: not read yet, read, or failed to read.
///
/// GL-14 - unknown is never rendered as zero - is this app's most-cited rule,
/// and the revamp found it broken in three places on Home and Tasks alone:
/// Fleet drew a missing firstmate home as 0/0/0 under "All clear", Health
/// titled "nothing has reported yet" as "Healthy", and Tasks drew a failed
/// YAML read as "0 open tasks". Each had the information to know better and
/// a plain number to draw it with. A view that takes a `HelmReading` cannot
/// draw a zero for an unknown, because there is no number in the two
/// unknown cases to draw.
enum HelmReading<Value> {
    /// Nothing has been read yet - the first fetch is still out.
    case unread
    /// A real reading.
    case value(Value)
    /// The read was attempted and failed, with the reason to show the
    /// captain. The last good value, if a caller has one, travels separately
    /// rather than inside this case, so a stale number is never mistaken for
    /// a current one.
    case failed(String)

    /// The em dash every unknown renders as.
    static var dash: String { "\u{2014}" }

    var value: Value? {
        if case let .value(value) = self { return value }
        return nil
    }

    var isKnown: Bool { value != nil }

    /// The text to draw: the formatted value, or a dash for either unknown.
    func text(_ format: (Value) -> String) -> String {
        value.map(format) ?? Self.dash
    }

    /// The caption a strip or a pill uses for an unknown - "Not read" for
    /// either case, because "failed" is a reason and belongs in a tooltip
    /// or a subline, not in a two-word label.
    static var unknownCaption: String { "Not read" }
}

extension HelmReading: Equatable where Value: Equatable {}

// MARK: - HelmKPIStrip

/// A row of numbers without boxes: each a 19pt semibold figure over an 11pt
/// caption, separated by 1px hairlines, on whatever surface it sits on.
///
/// It replaces boxed stat tiles where a card already provides the surface -
/// Fleet's three tiles on Home (UI-9), Weekly Review's three, the stat tiles
/// on Hosts, Updates and Schedules (UI-44). A tile is a bordered box, and a
/// bordered box inside a bordered card is two surfaces at one level.
///
/// An item carries a `HelmReading`, so an unknown renders as a dash rather
/// than a zero by construction (GL-14).
///
/// **One number recipe (S14 of the 2026-11-17 UI/UX proposals).** "A number
/// with a caption" was drawn three ways: this strip, `HelmStatTile` (a boxed
/// tile with an icon) and `HelmMetricCard` (a boxed card with the caption
/// above a 28pt figure). The two boxed recipes are removed and the strip has
/// two densities instead:
///
///   - `.inline`: inside a card that already gives the surface (Home's Fleet
///     card, Schedules). The figure over its caption, hairlines between.
///   - `.boxed`: a page's summary row (Crew, Setup, Health, Logs, Weekly
///     review). The same items, each on the card surface, caption above the
///     figure. A page can switch density without changing its data.
///
/// Both share the unknown rule (a dash, "not read" for the reason, never 0)
/// and the tint rule (colour only when the state is not the default).
///
/// **1.3.0: boxed tiles on a hero.** A `.boxed` strip given `heroInk` draws
/// its cells as the board's inset hero tiles (Setup's Sup-1): the figure over
/// its caption, both in the ink, on a translucent shade of the ink's opposite
/// rather than on the card surface. A shade, as under `HelmButton`'s ghost
/// pill, because it can only add contrast to ink the hero's palette already
/// holds at the text floor. Unlike `.inline`, a tinted figure keeps its
/// signal: a boxed tile can be a fact about another page (a diverged dotfiles
/// repo on the Updates page), so the hero's own verdict cannot carry it. With
/// `heroPalette` set it takes `HelmHeroSurface.signalColor`, which clears the
/// non-text floor on both stops - the large-text floor a 26pt figure needs.
final class HelmKPIStrip: NSView {

    enum Density: Equatable { case inline, boxed }

    struct Item: Equatable {
        enum Emphasis: Equatable {
            /// Page ink.
            case normal
            /// Muted - a zero that is fine ("0 working"), so the numbers that
            /// mean something carry the weight.
            case quiet
            /// A state colour, contrast-corrected - for a figure that is
            /// itself the signal ("2 overdue").
            case tinted(HelmTint)
        }

        /// `.boxed` only: one more fact under the figure - a muted line, or
        /// a tinted pill when the fact is a judgement ("+3 vs last week").
        struct Detail: Equatable {
            let text: String
            var tint: HelmTint? = nil
        }

        let reading: HelmReading<String>
        let caption: String
        let emphasis: Emphasis
        var detail: Detail? = nil
        /// `.boxed` only: the cell is a button that calls `onActivate`.
        var isAction = false
        /// Shown on hover. A failed reading's reason is the default.
        var toolTip: String? = nil

        init(_ reading: HelmReading<String>, caption: String, emphasis: Emphasis = .normal,
             detail: Detail? = nil, isAction: Bool = false, toolTip: String? = nil) {
            self.reading = reading
            self.caption = caption
            self.emphasis = emphasis
            self.detail = detail
            self.isAction = isAction
            self.toolTip = toolTip
        }

        /// A figure that may be unknown: `nil` text is a dash (with the reason
        /// as a tooltip when there is one, GL-14), and `tint` colours it only
        /// when `signals` says the figure is itself the signal. The shape the
        /// retired `HelmMetricCard.configure(text:signals:unknownReason:)` had.
        static func figure(_ text: String?, caption: String, tint: HelmTint? = nil, signals: Bool = false,
                           unknownReason: String? = nil, detail: Detail? = nil) -> Item {
            let reading: HelmReading<String> = text.map { .value($0) }
                ?? unknownReason.map { .failed($0) } ?? .unread
            let emphasis: Emphasis = (signals && text != nil) ? (tint.map { .tinted($0) } ?? .normal) : .normal
            return Item(reading, caption: caption, emphasis: emphasis, detail: detail)
        }

        /// A known count, quiet when it is zero.
        static func count(_ value: Int, caption: String, tintWhenNonZero: HelmTint? = nil) -> Item {
            let emphasis: Emphasis
            if value == 0 {
                emphasis = .quiet
            } else if let tint = tintWhenNonZero {
                emphasis = .tinted(tint)
            } else {
                emphasis = .normal
            }
            return Item(.value("\(value)"), caption: caption, emphasis: emphasis)
        }
    }

    static let metricSize: CGFloat = 19
    static let captionSize: CGFloat = 11
    /// `.boxed`: the figure, the smallest it shrinks to before truncating,
    /// the caption and the cell heights (with and without a detail line).
    static let boxedMetricSize: CGFloat = 28
    static let boxedMinimumMetricSize: CGFloat = 14
    static let boxedCaptionSize: CGFloat = 11.5
    static let boxedHeight: CGFloat = 82
    static let boxedDetailHeight: CGFloat = 108

    let density: Density
    /// `.boxed`: called with the index of an `isAction` cell that was pressed.
    var onActivate: ((Int) -> Void)?
    private var cells: [BoxedCell] = []

    /// R4-UI-02: a column's figure and caption keep their own width ahead of
    /// the equal-column tie, which is `columnHug`. Measured on Home's Fleet
    /// card at 1512 and 1280: three equal columns left "Done today" about
    /// 60pt against the 61pt it sets in, and it read "Done tod..." while
    /// "Working" and "Queued" beside it had room to spare. Still far under
    /// `contentTie`, which is what ties the card to its column (gotcha (13)),
    /// so a caption can widen its column and never the card.
    static let labelFloorPriority = NSLayoutConstraint.Priority(HelmDaylightPriority.columnHug.rawValue + 1)
    /// From a separator to the next column's figures.
    static let columnInset: CGFloat = HelmMetrics.s4

    private let row = NSStackView()
    private var items: [Item] = []
    private var valueLabels: [NSTextField] = []
    private var captionLabels: [NSTextField] = []
    private var separators: [NSView] = []
    private let topRule = NSView()
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// 1.2.0: the ink of a strip drawn on a hero gradient (Home's Fleet
    /// hero, through `HelmModuleCard`). Every caption and known figure takes
    /// it, a quiet or unknown figure takes it at `heroQuietAlpha`, and the
    /// hairlines at `heroRuleAlpha`. A tinted figure is ink too: on a
    /// gradient the card's own verdict carries the state, not a figure.
    /// `nil` - every other strip - paints the theme's colours.
    var heroInk: NSColor? {
        didSet { if heroInk != oldValue { applyTheme(theme) } }
    }
    static let heroQuietAlpha: CGFloat = 0.72
    static let heroRuleAlpha: CGFloat = 0.32

    /// 1.3.0, `.boxed` only: the palette of the hero under the strip, so a
    /// tinted tile figure can take `HelmHeroSurface.signalColor` on it.
    /// Without one a tinted figure is ink, as on `.inline`.
    var heroPalette: HelmHeroSurface.Palette? {
        didSet { if heroPalette != oldValue { applyTheme(theme) } }
    }
    /// 1.3.0: a hero tile's height, its figure (a word figure - "Off", "In
    /// sync" - is set smaller, as the board draws it), its caption's ink and
    /// its shade's alpha.
    static let heroTileHeight: CGFloat = 64
    static let heroMetricSize: CGFloat = 26
    static let heroWordMetricSize: CGFloat = 17
    static let heroCaptionAlpha: CGFloat = 0.85
    static let heroTileFillAlpha: CGFloat = 0.14

    /// 1.2.0: the `.inline` figure's size before the text scale. 19 on a
    /// card; Fleet's hero sets the prototype's 24.
    var figureSize: CGFloat = HelmKPIStrip.metricSize {
        didSet { if figureSize != oldValue { applyTheme(theme) } }
    }

    /// Whether a hairline runs above the strip - Fleet's card puts its
    /// sentence above the numbers and a rule between them.
    var showsTopRule: Bool = false {
        didSet { topRule.isHidden = !showsTopRule; topRuleGap?.constant = showsTopRule ? HelmMetrics.s3 : 0 }
    }
    private var topRuleGap: NSLayoutConstraint?

    init(density: Density = .inline) {
        self.density = density
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = density == .boxed ? HelmMetrics.s4 : 0
        row.distribution = density == .boxed ? .fillEqually : .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        // gotcha (12)+(13): the stack-level APIs, both yielding, so a strip
        // inside a card is never a window-width floor.
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        topRule.wantsLayer = true
        topRule.translatesAutoresizingMaskIntoConstraints = false
        topRule.isHidden = true
        addSubview(topRule)
        addSubview(row)
        let gap = row.topAnchor.constraint(equalTo: topRule.bottomAnchor)
        topRuleGap = gap
        NSLayoutConstraint.activate([
            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRule.topAnchor.constraint(equalTo: topAnchor),
            topRule.heightAnchor.constraint(equalToConstant: 1),
            gap,
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    override convenience init(frame frameRect: NSRect) { self.init(density: .inline) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ newItems: [Item], theme: HelmTheme = ThemeManager.shared.theme) {
        if density == .boxed {
            configureBoxed(newItems, theme: theme)
            return
        }
        items = newItems
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        valueLabels.removeAll()
        captionLabels.removeAll()
        separators.removeAll()

        var columns: [NSView] = []
        for (index, item) in newItems.enumerated() {
            if index > 0 {
                let line = NSView()
                line.wantsLayer = true
                line.translatesAutoresizingMaskIntoConstraints = false
                line.widthAnchor.constraint(equalToConstant: 1).isActive = true
                separators.append(line)
                row.addArrangedSubview(line)
                line.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
            }
            let value = NSTextField(labelWithString: item.reading.text { $0 })
            value.font = HelmType.metric(figureSize)
            value.lineBreakMode = .byTruncatingTail
            let caption = NSTextField(labelWithString: item.caption)
            caption.font = .systemFont(ofSize: HelmType.scaled(Self.captionSize), weight: .medium)
            caption.lineBreakMode = .byTruncatingTail
            for label in [value, caption] {
                label.translatesAutoresizingMaskIntoConstraints = false
                label.setContentCompressionResistancePriority(Self.labelFloorPriority, for: .horizontal)
            }
            valueLabels.append(value)
            captionLabels.append(caption)

            let column = NSStackView(views: [value, caption])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = HelmMetrics.s0
            column.edgeInsets = NSEdgeInsets(top: HelmMetrics.s1, left: index == 0 ? 0 : Self.columnInset,
                                             bottom: HelmMetrics.s1, right: HelmMetrics.s2)
            column.translatesAutoresizingMaskIntoConstraints = false
            // At the labels' own floor, or the column clips what its labels
            // refuse to give up (gotcha (12): the stack-level API). The row
            // above stays `.defaultLow`, so the strip is never the card's floor.
            column.setClippingResistancePriority(Self.labelFloorPriority, for: .horizontal)
            column.setHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(column)
            if let first = columns.first {
                // Equal columns where every label fits, at `columnHug`: above
                // the stacks' own 250, below `labelFloorPriority`, so a
                // caption that needs more takes it from its neighbours rather
                // than truncating (R4-UI-02).
                let equal = column.widthAnchor.constraint(equalTo: first.widthAnchor)
                equal.priority = HelmDaylightPriority.columnHug
                equal.isActive = true
            }
            columns.append(column)
        }
        setAccessibilityLabel(newItems.map { "\($0.caption) \($0.reading.text { $0 })" }
            .joined(separator: ", "))
        applyTheme(theme)
    }

    /// `.boxed`: one cell per item, updated in place while the count holds,
    /// so a refresh never rebuilds the row (P2, `KeyedRefreshSelfTest`).
    private func configureBoxed(_ newItems: [Item], theme: HelmTheme) {
        items = newItems
        if cells.count != newItems.count {
            for view in row.arrangedSubviews {
                row.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            let anyDetail = newItems.contains { $0.detail != nil }
            cells = newItems.indices.map { index in
                let cell = BoxedCell(height: anyDetail ? Self.boxedDetailHeight : Self.boxedHeight)
                cell.onPress = { [weak self] in self?.onActivate?(index) }
                row.addArrangedSubview(cell)
                return cell
            }
        }
        for (cell, item) in zip(cells, newItems) { cell.configure(item) }
        setAccessibilityLabel(newItems.map { "\($0.caption) \($0.reading.text { $0 })" }.joined(separator: ", "))
        applyTheme(theme)
    }

    /// The figure's colour for an item: muted for an unknown or a quiet
    /// figure, a contrast-corrected state colour for a tinted one, else ink.
    static func valueColor(_ item: Item, over surface: NSColor, theme: HelmTheme) -> NSColor {
        guard item.reading.isKnown else { return HelmTheme.mutedInk(theme) }
        switch item.emphasis {
        case .normal: return HelmTheme.nsColor(theme.chromeInkHex)
        case .quiet: return HelmTheme.mutedInk(theme)
        case let .tinted(tint):
            return HelmContrast.legibleTintedText(tintHex: tint.hex(in: theme), overAnyOf: [surface], theme: theme)
        }
    }

    /// 1.3.0: a hero tile's figure. Ink for a known figure, the ink at
    /// `heroQuietAlpha` for a quiet or unknown one, and for a tinted one the
    /// state hue lifted onto `palette` when there is one.
    static func heroValueColor(_ item: Item, ink: NSColor, palette: HelmHeroSurface.Palette?,
                               theme: HelmTheme) -> NSColor {
        guard item.reading.isKnown else { return ink.withAlphaComponent(heroQuietAlpha) }
        switch item.emphasis {
        case .normal: return ink
        case .quiet: return ink.withAlphaComponent(heroQuietAlpha)
        case let .tinted(tint):
            guard let palette else { return ink }
            return HelmHeroSurface.signalColor(tintHex: tint.hex(in: theme), on: palette)
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        if density == .boxed {
            for cell in cells {
                cell.heroInk = heroInk
                cell.heroPalette = heroPalette
                cell.applyTheme(theme)
            }
            return
        }
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        for (index, item) in items.enumerated() where index < valueLabels.count {
            let color: NSColor
            if let heroInk {
                let quiet = !item.reading.isKnown || item.emphasis == .quiet
                color = quiet ? heroInk.withAlphaComponent(Self.heroQuietAlpha) : heroInk
            } else if !item.reading.isKnown {
                color = muted
            } else {
                switch item.emphasis {
                case .normal: color = ink
                case .quiet: color = muted
                case let .tinted(tint):
                    color = HelmContrast.legibleTintedText(tintHex: tint.hex(in: theme), over: surface, theme: theme)
                }
            }
            valueLabels[index].textColor = color
            valueLabels[index].font = HelmType.metric(figureSize)
            captionLabels[index].textColor = heroInk ?? muted
        }
        let line = heroInk?.withAlphaComponent(Self.heroRuleAlpha) ?? HelmFlatList.hairRowColor(theme)
        for separator in separators { separator.layer?.backgroundColor = line.cgColor }
        topRule.layer?.backgroundColor = line.cgColor
    }

    #if FM_SELFTESTS
    var debugValues: [String] { valueLabels.map(\.stringValue) }
    var debugCaptions: [String] { captionLabels.map(\.stringValue) }
    /// R4-UI-02: the caption labels themselves, for their laid-out widths.
    var debugCaptionLabels: [NSTextField] { captionLabels }
    var debugValueColors: [NSColor?] { valueLabels.map(\.textColor) }
    var debugSeparatorCount: Int { separators.count }
    var debugHasBorder: Bool { (layer?.borderWidth ?? 0) > 0 }
    var debugCells: [BoxedCell] { cells }
    #endif

    /// One `.boxed` cell: the caption above the figure on the card surface,
    /// an optional detail line or pill, and a press when the item is an
    /// action. Nested so it is the strip's implementation, not a third stat
    /// component.
    final class BoxedCell: NSView {
        private let card = HelmCard()
        private let captionLabel = NSTextField(labelWithString: "")
        private let valueLabel = NSTextField(labelWithString: "")
        private let detailLabel = NSTextField(labelWithString: "")
        private let detailPill = HelmStatusPill(style: .pill)
        private let stack = NSStackView()
        private var item = Item(.unread, caption: "")
        private var theme: HelmTheme = ThemeManager.shared.theme
        private let height: CGFloat
        private var heightConstraint: NSLayoutConstraint?
        var onPress: (() -> Void)?
        /// 1.3.0: the strip's `heroInk` and `heroPalette`, handed down.
        var heroInk: NSColor? {
            didSet { if heroInk != oldValue { arrange() } }
        }
        var heroPalette: HelmHeroSurface.Palette?

        init(height: CGFloat) {
            self.height = height
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            captionLabel.font = .systemFont(ofSize: HelmType.scaled(HelmKPIStrip.boxedCaptionSize), weight: .medium)
            valueLabel.font = HelmType.metric(HelmKPIStrip.boxedMetricSize)
            detailLabel.font = HelmType.caption()
            for label in [captionLabel, valueLabel, detailLabel] {
                label.lineBreakMode = .byTruncatingTail
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            stack.setViews([captionLabel, valueLabel, detailLabel, detailPill], in: .top)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = HelmMetrics.s1
            stack.detachesHiddenViews = true
            stack.translatesAutoresizingMaskIntoConstraints = false
            detailLabel.isHidden = true
            detailPill.isHidden = true
            card.setBody(stack, insets: HelmCard.contentInsets)
            card.translatesAutoresizingMaskIntoConstraints = false
            addSubview(card)
            let tall = heightAnchor.constraint(equalToConstant: height)
            heightConstraint = tall
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: leadingAnchor),
                card.trailingAnchor.constraint(equalTo: trailingAnchor),
                card.topAnchor.constraint(equalTo: topAnchor),
                card.bottomAnchor.constraint(equalTo: bottomAnchor),
                tall,
            ])
            setAccessibilityElement(true)
            // GL-16: an action cell is keyboard-reachable and draws a real ring.
            focusRingType = .exterior
            addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pressed)))
        }

        override var acceptsFirstResponder: Bool { item.isAction }
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: card.layer?.cornerRadius ?? HelmMetrics.rRow,
                         yRadius: card.layer?.cornerRadius ?? HelmMetrics.rRow).fill()
        }

        override func keyDown(with event: NSEvent) {
            if item.isAction, event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 {
                onPress?()
                return
            }
            super.keyDown(with: event)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        func configure(_ item: Item) {
            self.item = item
            captionLabel.stringValue = item.caption
            valueLabel.stringValue = item.reading.text { $0 }
            let detail = item.detail
            let pill = detail?.tint != nil
            // A hero tile carries no detail line: it is one figure among the
            // hero's, and its height is the board's.
            detailPill.isHidden = !pill || heroInk != nil
            detailLabel.isHidden = detail == nil || pill || heroInk != nil
            detailLabel.stringValue = pill ? "" : (detail?.text ?? "")
            var reason: String?
            if case let .failed(why) = item.reading { reason = why }
            toolTip = item.toolTip ?? reason
            setAccessibilityRole(item.isAction ? .button : .staticText)
            setAccessibilityLabel([item.caption, item.reading.isKnown ? item.reading.text { $0 } : "not known yet",
                                   detail?.text].compactMap { $0 }.joined(separator: ", "))
            fitFigure()
            applyTheme(theme)
        }

        @objc private func pressed() {
            guard item.isAction else { return }
            onPress?()
        }

        override func accessibilityPerformPress() -> Bool {
            guard item.isAction else { return false }
            onPress?()
            return true
        }

        override func layout() {
            super.layout()
            fitFigure()
        }

        /// 1.3.0: the hero tile's insets, the board's 8pt by 10pt.
        static let heroInsets = NSEdgeInsets(top: HelmMetrics.s2, left: HelmMetrics.rRow,
                                             bottom: HelmMetrics.s2, right: HelmMetrics.rRow)

        /// Whether the figure is a word ("Off", "In sync", a dash) rather
        /// than a number, which a hero tile sets smaller.
        private var figureIsWord: Bool {
            !valueLabel.stringValue.contains { $0.isNumber }
        }

        /// The card's order and insets: caption over figure on the card
        /// surface, figure over caption on a hero tile.
        private func arrange() {
            let hero = heroInk != nil
            stack.setViews(hero ? [valueLabel, captionLabel, detailLabel, detailPill]
                                : [captionLabel, valueLabel, detailLabel, detailPill], in: .top)
            stack.spacing = hero ? 0 : HelmMetrics.s1
            card.setBody(stack, insets: hero ? Self.heroInsets : HelmCard.contentInsets)
            heightConstraint?.constant = hero ? HelmKPIStrip.heroTileHeight : height
            configure(item)
        }

        /// The figure steps down a point at a time until it fits its cell, so a
        /// long value ("0 / 13", "Paused") never truncates at a narrow width.
        private func fitFigure() {
            let insets = heroInk == nil ? HelmCard.contentInsets : Self.heroInsets
            let room = floor(bounds.width - insets.left - insets.right)
            guard room > 0 else { return }
            var size = heroInk == nil ? HelmKPIStrip.boxedMetricSize
                : (figureIsWord ? HelmKPIStrip.heroWordMetricSize : HelmKPIStrip.heroMetricSize)
            var font = HelmType.metric(size)
            while size > HelmKPIStrip.boxedMinimumMetricSize,
                  (valueLabel.stringValue as NSString).size(withAttributes: [.font: font]).width > room {
                size -= 1
                font = HelmType.metric(size)
            }
            if valueLabel.font != font { valueLabel.font = font }
        }

        func applyTheme(_ theme: HelmTheme) {
            self.theme = theme
            card.applyTheme(theme)
            if let heroInk {
                applyHero(heroInk)
                return
            }
            captionLabel.textColor = HelmTheme.mutedInk(theme)
            detailLabel.textColor = HelmTheme.mutedInk(theme)
            valueLabel.textColor = HelmKPIStrip.valueColor(item, over: HelmTheme.nsColor(theme.chromeBackgroundHex),
                                                           theme: theme)
            if let detail = item.detail, let tint = detail.tint {
                detailPill.configure(text: detail.text, tint: tint, theme: theme)
            }
        }

        /// 1.3.0: the tile on a hero. The card's surface, border and resting
        /// shadow give way to the shade; the words take the ink.
        private func applyHero(_ ink: NSColor) {
            card.layer?.backgroundColor = HelmButton.heroShade(for: ink)
                .withAlphaComponent(HelmKPIStrip.heroTileFillAlpha).cgColor
            card.layer?.borderWidth = 0
            card.layer?.shadowOpacity = 0
            card.layer?.cornerRadius = HelmMetrics.rRow
            captionLabel.textColor = ink.withAlphaComponent(HelmKPIStrip.heroCaptionAlpha)
            valueLabel.textColor = HelmKPIStrip.heroValueColor(item, ink: ink, palette: heroPalette, theme: theme)
        }

        #if FM_SELFTESTS
        var debugIsHeroTile: Bool { heroInk != nil }
        var debugCaptionColor: NSColor? { captionLabel.textColor }
        var debugFillColor: CGColor? { card.layer?.backgroundColor }
        var debugFigureIsAboveCaption: Bool {
            (stack.arrangedSubviews.firstIndex(of: valueLabel) ?? 0)
                < (stack.arrangedSubviews.firstIndex(of: captionLabel) ?? 0)
        }
        var debugCaption: String { captionLabel.stringValue }
        var debugValue: String { valueLabel.stringValue }
        var debugValuePointSize: CGFloat { valueLabel.font?.pointSize ?? 0 }
        var debugValueFits: Bool {
            let width = (valueLabel.stringValue as NSString).size(withAttributes: [.font: valueLabel.font as Any]).width
            return width <= valueLabel.frame.width + 0.5
        }
        var debugValueColor: NSColor? { valueLabel.textColor }
        var debugCard: HelmCard { card }
        var debugDetail: String? {
            item.detail == nil ? nil : (detailPill.isHidden ? detailLabel.stringValue : detailPill.text)
        }
        var debugDetailIsPill: Bool { !detailPill.isHidden }
        var debugIsAction: Bool { item.isAction }
        func debugPress() { _ = accessibilityPerformPress() }
        #endif
    }
}

// MARK: - HelmRelativeTime

/// The app's one "how long ago" phrase (UI-13): "just now", "4 min ago",
/// "3h ago", "2d ago".
///
/// Home alone carried five formatters for the age of a reading - "Fleet read
/// 4 minutes ago", "Fleet read at 10:18", "Updated 3h ago", and two more -
/// so the same age read differently on two cards a few points apart. This is
/// the short form every one of them now takes. Deliberately not
/// `RelativeDateTimeFormatter`, whose "4 minutes ago" / "in 0 seconds" is
/// longer than a header has room for and wrong for a reading that cannot be
/// in the future.
enum HelmRelativeTime {
    static func phrase(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int((seconds / 60).rounded(.down))
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int((seconds / 3600).rounded(.down))
        if hours < 24 { return "\(hours)h ago" }
        return "\(Int((seconds / 86_400).rounded(.down)))d ago"
    }
}

// MARK: - The overflow menu

/// UI-47: a page's secondary actions behind one quiet "⋯" button.
///
/// The rule it carries: the bar or toolbar shows the page's primary action,
/// one more, and the view controls; everything else is one click away here.
/// A page that put six or eight same-weight pills in a row made the one that
/// mattered impossible to find. Each item runs the same handler its old
/// button did, so moving an action into the menu changes where it lives, not
/// what it does.
final class HelmOverflowMenu: NSObject {
    struct Item {
        /// Read as the menu opens - an action whose name follows the page's
        /// state ("Clear" before an analysis, "Discard" after) stays one item.
        let currentTitle: () -> String
        var title: String { currentTitle() }
        let symbol: String?
        /// Read each time the menu opens, so an item follows the page's own
        /// state (a missing bundle, an empty board) without being rebuilt.
        let isEnabled: () -> Bool
        let run: () -> Void

        init(_ title: String, symbol: String? = nil,
             isEnabled: @escaping () -> Bool = { true }, run: @escaping () -> Void) {
            self.init(title: { title }, symbol: symbol, isEnabled: isEnabled, run: run)
        }

        init(title: @escaping () -> String, symbol: String? = nil,
             isEnabled: @escaping () -> Bool = { true }, run: @escaping () -> Void) {
            self.currentTitle = title
            self.symbol = symbol
            self.isEnabled = isEnabled
            self.run = run
        }
    }

    let items: [Item]
    private(set) lazy var button: HelmButton = HelmPageToolbar.iconButton(
        symbol: "ellipsis", tooltip: tooltip, target: self, action: #selector(open(_:)))
    private let tooltip: String

    init(items: [Item], tooltip: String = "More actions") {
        self.items = items
        self.tooltip = tooltip
        super.init()
        button.setAccessibilityLabel(tooltip)
    }

    /// The menu as it would open now - built fresh, so enablement is current.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, item) in items.enumerated() {
            let entry = NSMenuItem(title: item.title, action: #selector(picked(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.isEnabled = item.isEnabled()
            if let symbol = item.symbol { entry.withSymbol(symbol) }
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func open(_ sender: NSView) {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + HelmMetrics.s1), in: sender)
    }

    @objc private func picked(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        items[sender.tag].run()
    }

    #if FM_SELFTESTS
    var debugTitles: [String] { items.map(\.title) }
    func debugRun(_ title: String) { items.first { $0.title == title }?.run() }
    #endif
}
