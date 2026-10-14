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

    let style: Style
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var colorHex: String?
    private var tint: HelmTint?

    static let dotSize: CGFloat = 8

    init(style: Style = .pill) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = HelmType.chip()
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        if style == .dotWord {
            dot.wantsLayer = true
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer?.cornerRadius = Self.dotSize / 2
            addSubview(dot)
            addSubview(label)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: leadingAnchor),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
                dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
                label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: HelmMetrics.s1 + 2),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            ])
        }
        // `.pill` adds its label inside `ToolRowLayout.pill`, which owns the
        // capsule's padding constraints and creates them once.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    var text: String { label.stringValue }

    func configure(text: String, tint: HelmTint, theme: HelmTheme = ThemeManager.shared.theme) {
        self.tint = tint
        self.colorHex = nil
        label.stringValue = text
        applyTheme(theme)
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
        let hex = colorHex ?? tint?.hex(in: theme) ?? theme.chromeInkHex
        switch style {
        case .pill:
            ToolRowLayout.pill(text: label.stringValue, colorHex: hex, into: self, label: label, theme: theme)
            // `ToolRowLayout.pill` sets the twelve legacy palettes' semibold;
            // the kit's one chip face is `HelmType.chip()` everywhere.
            label.font = HelmType.chip()
        case .dotWord:
            let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
            dot.layer?.backgroundColor = HelmTheme.nsColor(hex).cgColor
            label.font = HelmType.chip()
            label.textColor = HelmContrast.legibleTintedText(tintHex: hex, over: surface, theme: theme)
            layer?.backgroundColor = NSColor.clear.cgColor
        }
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

    enum Size: Equatable { case section, lane, hero }

    enum Leading: Equatable {
        case none
        case dot(HelmTint)
        case tile(symbol: String, tint: HelmTint)
    }

    let size: Size
    let titleLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    let eyebrowLabel = NSTextField(labelWithString: "")
    let sublineLabel = NSTextField(labelWithString: "")
    private let tile: IconTileView
    private let dot = NSView()
    private let actionStack = NSStackView()
    private var leading: Leading = .none

    static let dotSize: CGFloat = 8
    /// Above every stack default and the spacer, under the window's own 500.
    static let textResistance = NSLayoutConstraint.Priority(490)
    static func tileSide(for size: Size) -> CGFloat { size == .hero ? HelmMetrics.tileBase : 30 }

    init(size: Size) {
        self.size = size
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
        if size == .hero {
            let column = NSStackView(views: [eyebrowLabel, titleRow, sublineLabel])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 1
            column.setCustomSpacing(3, after: eyebrowLabel)
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
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
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
        countLabel.isHidden = (count ?? "").isEmpty
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
            tile.configure(symbol: symbol, tint: tint, pointSize: size == .hero ? 15 : 13)
        }
        applyTheme(ThemeManager.shared.theme)
    }

    /// The trailing slot. Replaces whatever was there.
    func setActions(_ views: [NSView]) {
        for view in actionStack.arrangedSubviews {
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            actionStack.addArrangedSubview(view)
        }
        actionStack.isHidden = views.isEmpty
    }

    func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        switch size {
        case .section:
            titleLabel.font = HelmType.moduleTitle()
        case .lane:
            titleLabel.font = HelmType.rowTitle()
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

    #if FM_SELFTESTS
    var debugSeparatorCount: Int { separators.count }
    #endif
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
final class HelmKPIStrip: NSView {

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

        let reading: HelmReading<String>
        let caption: String
        let emphasis: Emphasis

        init(_ reading: HelmReading<String>, caption: String, emphasis: Emphasis = .normal) {
            self.reading = reading
            self.caption = caption
            self.emphasis = emphasis
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
    /// From a separator to the next column's figures.
    static let columnInset: CGFloat = HelmMetrics.s4

    private let row = NSStackView()
    private var items: [Item] = []
    private var valueLabels: [NSTextField] = []
    private var captionLabels: [NSTextField] = []
    private var separators: [NSView] = []
    private let topRule = NSView()
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// Whether a hairline runs above the strip - Fleet's card puts its
    /// sentence above the numbers and a rule between them.
    var showsTopRule: Bool = false {
        didSet { topRule.isHidden = !showsTopRule; topRuleGap?.constant = showsTopRule ? HelmMetrics.s3 : 0 }
    }
    private var topRuleGap: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 0
        row.distribution = .fill
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

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ newItems: [Item], theme: HelmTheme = ThemeManager.shared.theme) {
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
            value.font = HelmType.metric(Self.metricSize)
            value.lineBreakMode = .byTruncatingTail
            let caption = NSTextField(labelWithString: item.caption)
            caption.font = .systemFont(ofSize: HelmType.scaled(Self.captionSize), weight: .medium)
            caption.lineBreakMode = .byTruncatingTail
            for label in [value, caption] {
                label.translatesAutoresizingMaskIntoConstraints = false
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            valueLabels.append(value)
            captionLabels.append(caption)

            let column = NSStackView(views: [value, caption])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 1
            column.edgeInsets = NSEdgeInsets(top: HelmMetrics.s1, left: index == 0 ? 0 : Self.columnInset,
                                             bottom: HelmMetrics.s1, right: HelmMetrics.s2)
            column.translatesAutoresizingMaskIntoConstraints = false
            column.setClippingResistancePriority(.defaultLow, for: .horizontal)
            column.setHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(column)
            if let first = columns.first {
                // Equal columns, at `contentTie` (gotcha (13)).
                let equal = column.widthAnchor.constraint(equalTo: first.widthAnchor)
                equal.priority = HelmDaylightPriority.contentTie
                equal.isActive = true
            }
            columns.append(column)
        }
        setAccessibilityLabel(newItems.map { "\($0.caption) \($0.reading.text { $0 })" }
            .joined(separator: ", "))
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        for (index, item) in items.enumerated() where index < valueLabels.count {
            let color: NSColor
            if !item.reading.isKnown {
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
            valueLabels[index].font = HelmType.metric(Self.metricSize)
            captionLabels[index].textColor = muted
        }
        let line = HelmFlatList.hairRowColor(theme)
        for separator in separators { separator.layer?.backgroundColor = line.cgColor }
        topRule.layer?.backgroundColor = line.cgColor
    }

    #if FM_SELFTESTS
    var debugValues: [String] { valueLabels.map(\.stringValue) }
    var debugCaptions: [String] { captionLabels.map(\.stringValue) }
    var debugValueColors: [NSColor?] { valueLabels.map(\.textColor) }
    var debugSeparatorCount: Int { separators.count }
    var debugHasBorder: Bool { (layer?.borderWidth ?? 0) > 0 }
    #endif
}
