// Manjesh Grand Line - native macOS app.
//
// The Settings page's grouped-form vocabulary, as real components.
//
// `fm/grandline-settings-page-redesign`. The captain hand-built a full
// HTML/CSS reference for this page and asked for the real one to match it.
// That reference is a macOS System-Settings-shaped window, and its whole
// content model is four nouns repeated on every one of its eight pages:
//
//   `.hero`     an icon tile, a title and one sentence of description.
//   `.section`  an optional small heading (with an optional trailing aside),
//               above exactly one group.
//   `.group`    a card holding rows, hairline-separated, flush to its edges.
//   `.row`      a label and an optional description on the left, one control
//               on the right - plus `.sub` (indented, dependent) and
//               `.disabled` (dimmed and inert) variants.
//
// They are types here rather than a pile of `build*` helpers on the
// controller for the reason AGENTS.md's component index gives: the page has
// roughly sixty rows across eight pages, and a row's separator inset, its
// disabled dimming and its description re-wrap are each exactly the kind of
// detail that drifts when sixty call sites each spell it out. A suite can
// also reach a `SettingsRow` and ask whether it is enabled, which is what
// makes the reference's `data-dep` behaviour testable at all.
//
// **What is deliberately not here.** No control types: every control in a row
// is one of this app's existing `Helm*` components, handed in by the page
// that owns it. This file decides layout, separators, dimming and theming,
// and nothing about what a row contains.

import AppKit

// MARK: - Row

/// One `.row` of the reference: a label (and optional description) on the
/// left, one control on the right.
///
/// **The trailing control always sits at the row's own trailing edge.** That
/// is AGENTS.md gotcha (10): a horizontal `NSStackView` left at the default
/// `.gravityAreas` distribution honours no hugging priority at all, so with
/// sixty rows of wildly different description lengths the controls would land
/// at sixty different x positions. `.fill` plus `.defaultLow` on the text
/// column and `.required` on the control is the shape that gotcha prescribes,
/// and it is unconditional here rather than opt-in - the page this file
/// serves is a grid of label/control pairs, and a ragged control column is
/// the one thing that makes it not read as one.
final class SettingsRow: NSView {

    /// The reference's `.row` metrics, scaled into this app's own spacing.
    enum Metrics {
        /// `.row { min-height: 44px }`.
        static let minHeight: CGFloat = 44
        /// `.row { padding: 9px 14px }`.
        static let insetH: CGFloat = 14
        static let insetV: CGFloat = 9
        /// `.row { gap: 16px }`.
        static let gap: CGFloat = HelmMetrics.s4
        /// `.row.sub { padding-left: 32px }` - the extra leading inset a
        /// dependent row carries, on top of `insetH`.
        static let subIndent: CGFloat = 18
        /// `.row + .row::before { left: 14px }` - the separator starts at the
        /// label, not at the card's edge.
        static let separatorInset: CGFloat = 14
        /// `.row.icon + .row::before { left: 52px }` - a row with a leading
        /// avatar/tile pushes the separator past it.
        static let iconSeparatorInset: CGFloat = 52
        /// `.row.disabled { opacity: .4 }`.
        static let disabledAlpha: CGFloat = 0.4
    }

    /// Whether this row is a dependent (`data-dep`) row of the toggle above
    /// it, which is both the indent and - when the row is built - the thing
    /// `setRowEnabled` will be driving.
    let isSubRow: Bool

    /// A leading view before the label column (the reference's `.row.icon`:
    /// a Google account's avatar, an intent's tile). `nil` for an ordinary
    /// row, and the difference is visible in the separator inset above.
    private let lead: NSView?

    let titleLabel = NSTextField(labelWithString: "")
    /// `nil` when the row is a bare label - about a third of them are.
    private(set) var descriptionLabel: NSTextField?
    /// The control column. One view: a page that needs two hands them in as
    /// its own `NSStackView`, which is also what keeps this row from having
    /// an opinion about the gap between them.
    let control: NSView

    /// The reference's `.disabled`: dimmed, and inert rather than merely
    /// dimmed. `pointer-events: none` has no AppKit equivalent, so the real
    /// controls are disabled too - a dimmed switch that still flips is worse
    /// than no dimming at all, because it says a setting does not apply and
    /// then applies it.
    var isRowEnabled: Bool = true {
        didSet {
            guard isRowEnabled != oldValue else { return }
            alphaValue = isRowEnabled ? 1 : Metrics.disabledAlpha
            Self.setEnabled(isRowEnabled, on: control)
        }
    }

    init(title: String, description: String? = nil, control: NSView,
         lead: NSView? = nil, isSubRow: Bool = false) {
        self.control = control
        self.lead = lead
        self.isSubRow = isSubRow
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = HelmType.rowTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        var textViews: [NSView] = [titleLabel]
        if let description, !description.isEmpty {
            let label = NSTextField(wrappingLabelWithString: description)
            label.font = HelmType.caption()
            label.translatesAutoresizingMaskIntoConstraints = false
            // Gotcha (13): a wrapping label's intrinsic width at the default
            // 750 compression resistance is a real minimum, and 500 is where
            // a window stops holding its own size - so a card full of these
            // would be a window-width floor. The page re-derives
            // `preferredMaxLayoutWidth` on every layout pass instead (see
            // `SettingsRow.relayoutDescription`).
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textViews.append(label)
            descriptionLabel = label
        }

        let textStack = NSStackView(views: textViews)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (12): a stack has no intrinsic content size, so the
        // *content*-priority APIs are no-ops on it. These are the stack-level
        // pair, and they are what actually makes this column the one that
        // yields.
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        control.translatesAutoresizingMaskIntoConstraints = false
        if let stack = control as? NSStackView {
            stack.setHuggingPriority(.required, for: .horizontal)
            stack.setClippingResistancePriority(.required, for: .horizontal)
            // Gotcha (10) one level in. A control column built as a stack of
            // two or three buttons is itself left at the default
            // `.gravityAreas`, which has no rule for who absorbs leftover
            // width - so the *first* button takes all of it. Measured on the
            // Terminal page's font-size presets, where "12" rendered about
            // 300pt wide beside three compact siblings. `.fill` plus
            // `.required` hugging on each member is that gotcha's own fix,
            // and it is applied here rather than at a dozen call sites.
            if stack.distribution == .gravityAreas {
                stack.distribution = .fill
                for member in stack.arrangedSubviews {
                    member.setContentHuggingPriority(.required, for: .horizontal)
                    member.setContentCompressionResistancePriority(.required, for: .horizontal)
                }
            }
        } else {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        var rowViews: [NSView] = []
        if let lead {
            lead.translatesAutoresizingMaskIntoConstraints = false
            lead.setContentHuggingPriority(.required, for: .horizontal)
            lead.setContentCompressionResistancePriority(.required, for: .horizontal)
            rowViews.append(lead)
        }
        rowViews.append(contentsOf: [textStack, control])

        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.gap
        // Gotcha (10)'s own fix. Without it the priorities above decide
        // nothing at all.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let leading = Metrics.insetH + (isSubRow ? Metrics.subIndent : 0)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.insetH),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.insetV),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.insetV),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Where the separator above this row starts - `.row.icon`'s wider inset
    /// when the row carries a leading view, the plain one otherwise.
    var separatorInset: CGFloat {
        lead == nil ? Metrics.separatorInset : Metrics.iconSeparatorInset
    }

    /// Re-wrap the description against the width the row actually has.
    ///
    /// A `preferredMaxLayoutWidth` guessed once is an *over*-estimate the
    /// moment the card is narrower than the guess, and that is the dangerous
    /// direction: AppKit computes a one-line intrinsic height at the estimate,
    /// the text then wraps narrower, and the extra line draws outside the
    /// label's own frame. Same repair `SettingsController.layoutDidChangeWidths`
    /// already made for the cards this replaced.
    func relayoutDescription(cardWidth: CGFloat) {
        guard let descriptionLabel else { return }
        let leading = Metrics.insetH + (isSubRow ? Metrics.subIndent : 0)
        let leadWidth = lead.map { ceil($0.fittingSize.width) + Metrics.gap } ?? 0
        let controlWidth = ceil(control.fittingSize.width) + Metrics.gap
        let available = max(180, cardWidth - leading - Metrics.insetH - leadWidth - controlWidth)
        guard abs(descriptionLabel.preferredMaxLayoutWidth - available) > 0.5 else { return }
        descriptionLabel.preferredMaxLayoutWidth = available
        descriptionLabel.invalidateIntrinsicContentSize()
    }

    func applyTheme(_ theme: HelmTheme) {
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        descriptionLabel?.textColor = HelmTheme.mutedInk(theme)
    }

    /// Disable (or re-enable) every control in a subtree.
    ///
    /// Recursive because a row's control column is often a stack of two or
    /// three - a pill beside a button, two popups - and disabling only the
    /// container would leave the real controls live under a dimmed row.
    private static func setEnabled(_ enabled: Bool, on view: NSView) {
        // `HelmToggle` is an `NSControl` too, and its own click path is
        // guarded on `isEnabled` - so this one branch really does make the
        // row inert rather than only dim it.
        if let control = view as? NSControl { control.isEnabled = enabled }
        for subview in view.subviews { setEnabled(enabled, on: subview) }
    }
}

// MARK: - Group

/// The reference's `.group`: one card holding rows, hairline-separated, with
/// the rows flush to the card's edges (they carry their own padding).
///
/// A real `HelmCard` with no header and a zero-inset body, rather than a
/// second rounded-background view - AGENTS.md's component index is explicit
/// that a hand-rolled card surface is this repository's commonest audit
/// finding, and `HelmCard` already carries the one fill, the one border, the
/// Daylight elevation and the palette-derived colours.
final class SettingsGroup: NSView {

    let card = HelmCard()
    private(set) var rows: [SettingsRow] = []
    private var separators: [(view: NSView, inset: NSLayoutConstraint)] = []
    private let stack = NSStackView()

    convenience init(rows: [SettingsRow]) {
        self.init(rowViews: rows)
    }

    /// A group whose rows are not all `SettingsRow`s.
    ///
    /// The one real case is an account row: `GmailAccountRow` draws its own
    /// avatar, title, address, status pill and button and has done since the
    /// Gmail task, so wrapping it in a `SettingsRow` gives it a *second*
    /// title - which is exactly what the first render of this page showed,
    /// "Work mail" printed twice. A view handed in here is the whole row.
    init(rowViews: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        self.rows = rowViews.compactMap { $0 as? SettingsRow }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, row) in rowViews.enumerated() {
            if index > 0 {
                // `.row + .row::before` - a hairline at the top of every row
                // but the first, inset to where that row's own label starts.
                let line = NSView()
                line.wantsLayer = true
                line.translatesAutoresizingMaskIntoConstraints = false
                line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(line)
                let inset = line.leadingAnchor.constraint(
                    equalTo: stack.leadingAnchor,
                    constant: (row as? SettingsRow)?.separatorInset ?? SettingsRow.Metrics.separatorInset)
                NSLayoutConstraint.activate([
                    inset,
                    line.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
                ])
                separators.append((line, inset))
            }
            // A `SettingsRow` carries the group's padding itself; anything
            // else is handed in flush and has to be given it here, or its own
            // trailing control sits hard against the card's edge - which is
            // what the first render of the Google Accounts page showed, with
            // both Connect buttons touching the border.
            let hosted = (row as? SettingsRow).map { $0 as NSView } ?? Self.padded(row)
            stack.addArrangedSubview(hosted)
            hosted.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        card.setBody(stack, insets: NSEdgeInsets())
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Wrap a flush custom row in the same insets a `SettingsRow` applies to
    /// itself, so the two kinds of row line up.
    private static func padded(_ view: NSView) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor,
                                          constant: SettingsRow.Metrics.insetH),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor,
                                           constant: -SettingsRow.Metrics.insetH),
            view.topAnchor.constraint(equalTo: host.topAnchor,
                                      constant: SettingsRow.Metrics.insetV),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor,
                                         constant: -SettingsRow.Metrics.insetV),
            host.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsRow.Metrics.minHeight),
        ])
        return host
    }

    /// A group whose body is one arbitrary view rather than a row list - the
    /// theme grid, which is a grid and not a stack of rows.
    convenience init(custom view: NSView, insets: NSEdgeInsets = HelmCard.contentInsets) {
        self.init(rowViews: [])
        card.setBody(view, insets: insets)
    }

    func relayoutDescriptions(cardWidth: CGFloat) {
        for row in rows { row.relayoutDescription(cardWidth: cardWidth) }
    }

    func applyTheme(_ theme: HelmTheme) {
        card.applyTheme(theme)
        for row in rows { row.applyTheme(theme) }
        // The same lighter-than-the-outline hairline `HelmCard` draws under
        // its own header, so a group's internal rules and its header rule are
        // the same line.
        let hair = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.hairRow)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5)
        for (line, _) in separators { line.layer?.backgroundColor = hair.cgColor }
    }
}

// MARK: - Section

/// The reference's `.section`: an optional heading with an optional trailing
/// aside, above exactly one group, with the gap below that separates it from
/// the next section.
final class SettingsSection: NSView {

    let group: SettingsGroup
    private(set) var headingLabel: NSTextField?
    /// `.foot` - the small muted paragraph some sections carry under their
    /// group, which is where this page states what it sends over the network
    /// and what it does not.
    private(set) var footLabel: NSTextField?

    init(heading: String? = nil, aside: NSView? = nil, group: SettingsGroup, foot: String? = nil) {
        self.group = group
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        var columnViews: [NSView] = []

        if heading != nil || aside != nil {
            var headingViews: [NSView] = []
            if let heading {
                let label = NSTextField(labelWithString: heading)
                label.font = HelmType.cardTitle()
                label.translatesAutoresizingMaskIntoConstraints = false
                label.setContentHuggingPriority(.required, for: .horizontal)
                headingLabel = label
                headingViews.append(label)
            }
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            // Gotcha (12): a bare `NSView()` has no intrinsic size either, so
            // a hugging priority on it decides nothing. A spacer that must be
            // the thing that stretches needs no constraint at all - it is the
            // only `.defaultLow` member of a `.fill` row - but it does need
            // the row to have a distribution.
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            headingViews.append(spacer)
            if let aside {
                aside.translatesAutoresizingMaskIntoConstraints = false
                aside.setContentHuggingPriority(.required, for: .horizontal)
                aside.setContentCompressionResistancePriority(.required, for: .horizontal)
                headingViews.append(aside)
            }
            let headingRow = NSStackView(views: headingViews)
            headingRow.orientation = .horizontal
            headingRow.alignment = .centerY
            headingRow.spacing = HelmMetrics.s2
            headingRow.distribution = .fill
            headingRow.translatesAutoresizingMaskIntoConstraints = false
            columnViews.append(headingRow)
        }

        columnViews.append(group)

        if let foot, !foot.isEmpty {
            let label = NSTextField(wrappingLabelWithString: foot)
            label.font = HelmType.caption()
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            footLabel = label
            columnViews.append(label)
        }

        let column = NSStackView(views: columnViews)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2 - 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in columnViews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func relayoutDescriptions(cardWidth: CGFloat) {
        group.relayoutDescriptions(cardWidth: cardWidth)
        if let footLabel, abs(footLabel.preferredMaxLayoutWidth - cardWidth) > 0.5 {
            footLabel.preferredMaxLayoutWidth = cardWidth
            footLabel.invalidateIntrinsicContentSize()
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        group.applyTheme(theme)
        headingLabel?.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        footLabel?.textColor = HelmTheme.mutedInk(theme)
    }
}

// MARK: - Hero

/// The reference's `.hero`: the icon tile, the page's own title, and one
/// sentence saying what the page is for.
///
/// It restates the page title the toolbar also shows, which is deliberate and
/// is the reference's own arrangement: the toolbar title is chrome that stays
/// put while the pane scrolls, and the hero is the top of the document. What
/// the toolbar cannot carry is the sentence.
final class SettingsHero: NSView {

    private let tile = IconTileView(size: 46, cornerRadius: HelmMetrics.rCard)
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")

    init(symbol: String, tint: HelmTint, title: String, description: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        tile.configure(symbol: symbol, tint: tint)
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.stringValue = title
        titleLabel.font = HelmType.pageTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        descriptionLabel.stringValue = description
        descriptionLabel.font = HelmType.caption()
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, descriptionLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [tile, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s3 + 2
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func relayoutDescription(pageWidth: CGFloat) {
        let available = max(200, pageWidth - 46 - HelmMetrics.s3 - 2)
        guard abs(descriptionLabel.preferredMaxLayoutWidth - available) > 0.5 else { return }
        descriptionLabel.preferredMaxLayoutWidth = available
        descriptionLabel.invalidateIntrinsicContentSize()
    }

    func applyTheme(_ theme: HelmTheme) {
        tile.applyTheme(theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        descriptionLabel.textColor = HelmTheme.mutedInk(theme)
    }
}
