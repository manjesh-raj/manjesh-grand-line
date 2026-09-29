// Grand Line - native macOS app.
//
// The Home page's **Needs Attention** card - the captain's "move Due Today
// onto Home" ask, on the app's own components.
//
// `NeedsAttentionData.swift` decides every word and every count; this file
// only draws. That is the same split `DailyReviewCard`/`DailyReviewData` and
// `MorningBriefingCard`/`MorningBriefingData` already use, and for the same
// reason: the numbers are then assertable from a suite with no window at all.
//
// ## Nothing here is a new component
//
// The reference mockup draws a header (icon, eyebrow, sentence, subline) over
// a flat list of rows, each with a leading checkbox, an all-caps source label,
// a coloured chip, the item's text, a quieter meta line and a trailing action
// button. AGENTS.md's component index already names that row -
// `HelmAccentRow`, "a hand-rolled alert/record row (accent bar, badge, kicker,
// body, chip)" - and it already owns the two slots this needs: `leadingControl`
// for the checkbox and `trailingAccessory` for the action. So a row here is
// the same component the Tasks page's own list rows are, configured
// differently; `ShiftTaskCheckBadge` is the same checkbox, not a second one.
//
// The card itself is a `HelmCard`.
//
// ## The card is the page's hero now
//
// The first pass at this card listed three deliberate deviations from the
// mockup - no Refresh button, a composed-at subline rather than a fleet
// freshness one, and no closing "Everything else is clear" strip. All three
// rested on the same reading: that the hub's *separate hero band* above this
// card owned the fleet, so a second Refresh and a second freshness line here
// would be duplication, and a clear strip would mean reading sources this
// card does not own.
//
// `fm/grandline-home-page-visual-overhaul` is the captain asking for the
// reference literally, and the reference draws **one** card there. So the
// hero band is gone from the hub and this card absorbed its three parts: the
// Refresh button (`onRefresh`), the fleet-freshness subline (passed in, as
// the composed-at line already was), and the clear strip
// (`NeedsAttentionSummary.clearNotes`, built by the host from readings it
// already holds). The duplication those deviations avoided is avoided by
// there being one card rather than by this card doing less.
//
// Every one of the three is still optional and still off by default, because
// this card is not only the hub's: `onRefresh` nil hides the button.
//
// ## Rebuild-on-render
//
// The list is rebuilt wholesale from the summary on every `render`, and
// `applyTheme` re-renders from the cached one - `DailyReviewCard`'s own
// arrangement, for its own reason: a rebuild removes the class of bug where a
// row that stopped being due keeps its old chip. It is still GL-24-compliant,
// because the summary is a value this card already holds and nothing is
// fetched.
//
// ## AppKit landmines this card is shaped around (AGENTS.md)
//
//   - gotcha (10)/(12): every horizontal stack here is `.fill` with explicit
//     priorities, and the flexible member is a text stack rather than a
//     container left to Auto Layout's own tie-breaking.
//   - gotcha (5): in the header row only the text column is `.defaultLow`;
//     the tile keeps `.required` so a long headline truncates rather than
//     squeezing the icon.
//   - gotcha (13): this card spans the page width, so nothing in it carries a
//     content priority above `HelmDaylightPriority.contentTie`.
//   - gotcha (11): every view built here clears
//     `translatesAutoresizingMaskIntoConstraints` before any constraint.

import AppKit

final class NeedsAttentionCard: NSView {

    /// A row's checkbox was clicked: mark this item done. The card does not
    /// own a store, so the host writes and re-renders.
    var onToggleDone: ((NeedsAttentionItem) -> Void)?
    /// A row's trailing button ("Start" / "Open") was clicked.
    var onOpenItem: ((NeedsAttentionItem) -> Void)?
    /// The header's Refresh. `nil` - the default - leaves the button out of
    /// the header entirely, which is how any host other than the hub gets
    /// exactly the card it had before.
    ///
    /// Set it **before** the first `render`: the button is an arranged
    /// subview whose visibility is settled there.
    var onRefresh: (() -> Void)? {
        didSet { refreshButton.isHidden = onRefresh == nil }
    }

    private let card = HelmCard()
    private let headerTile = IconTileView(size: HelmMetrics.tileBase, cornerRadius: 9)
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let headlineLabel = NSTextField(labelWithString: "")
    private let sublineLabel = NSTextField(labelWithString: "")
    /// The reference's filled accent pill, which is the same
    /// `HelmButton(.primary)` the hub's hero band carried before this card
    /// absorbed it - one definition, not a second page-local look.
    private let refreshButton = HelmButton(title: "Refresh", variant: .primary,
                                           symbol: "arrow.clockwise")
    /// The list. Rebuilt wholesale on every render.
    private let listStack = NSStackView()
    /// The reference's closing strip. Rebuilt with the list, and hidden -
    /// which for an arranged subview really does remove it from layout
    /// (gotcha (15)'s one such case) - when there is nothing to say.
    private let clearStrip = NSStackView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var summary: NeedsAttentionSummary?
    private var subline: String = ""
    /// See `rebuildClearStrip`.
    private var clearStripWidthTie: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Build

    private func build() {
        // `HelmCard`'s structured `setHeader(symbol:title:subtitle:)` is
        // title-then-subtitle and has no eyebrow slot, and the mockup's
        // eyebrow sits *above* the sentence. So this uses the component's own
        // "arbitrary header view" overload rather than restyling the
        // structured one from outside, which the component index forbids.
        eyebrowLabel.font = HelmType.kicker()
        headlineLabel.font = HelmType.sectionTitle()
        sublineLabel.font = HelmType.caption()
        for label in [eyebrowLabel, headlineLabel, sublineLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            // gotcha (13): this card is page-wide, so no label in it may act
            // as a width floor.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        let textColumn = NSStackView(views: [eyebrowLabel, headlineLabel, sublineLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 1
        textColumn.setCustomSpacing(3, after: eyebrowLabel)
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        // gotcha (12): a stack has no intrinsic size, so the *stack*-priority
        // API is what makes this the column that flexes.
        textColumn.setHuggingPriority(.defaultLow, for: .horizontal)
        textColumn.setClippingResistancePriority(.defaultLow, for: .horizontal)

        headerTile.setContentHuggingPriority(.required, for: .horizontal)
        headerTile.setContentCompressionResistancePriority(.required, for: .horizontal)

        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.isHidden = true
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [headerTile, textColumn, refreshButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = HelmMetrics.s3
        // gotcha (10): the default `.gravityAreas` honours no priority at all.
        headerRow.distribution = .fill
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        card.setHeader(headerRow)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = HelmMetrics.s1
        listStack.distribution = .fill
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.setHuggingPriority(.defaultLow, for: .horizontal)
        listStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        clearStrip.orientation = .horizontal
        clearStrip.alignment = .centerY
        clearStrip.spacing = HelmMetrics.s2
        clearStrip.distribution = .fill
        clearStrip.translatesAutoresizingMaskIntoConstraints = false
        clearStrip.setHuggingPriority(.defaultLow, for: .horizontal)
        clearStrip.setClippingResistancePriority(.defaultLow, for: .horizontal)
        clearStrip.isHidden = true
        // Deliberately **not** added to `listStack` here: `rebuild` empties
        // that stack wholesale (see the file header), so the strip is
        // re-added at the end of every rebuild instead of being torn out by
        // the first one.

        card.setBody(listStack, insets: HelmCard.contentInsets)

        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyTheme(theme)
    }

    // MARK: Render

    /// - Parameter subline: the "as of" line under the headline -
    ///   `DailyReviewDigest.kicker`. The host passes it rather than this card
    ///   formatting a date of its own, so the two cards that render the same
    ///   digest can never disagree about when it was taken.
    func render(_ summary: NeedsAttentionSummary, subline: String, theme: HelmTheme) {
        self.summary = summary
        self.subline = subline
        self.theme = theme
        rebuild()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        paintChrome()
        // The rows are rebuilt rather than re-tinted - see the file header.
        if summary != nil { rebuild() }
    }

    /// Everything that is not a row. Called from both `applyTheme` and
    /// `rebuild`, because either can be the one that runs last.
    private func paintChrome() {
        card.applyTheme(theme)
        headerTile.applyTheme(theme)
        eyebrowLabel.textColor = HelmTheme.mutedInk(theme)
        headlineLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        sublineLabel.textColor = HelmTheme.mutedInk(theme)
        headlineLabel.font = theme.isDaylight ? HelmType.cardTitle() : HelmType.sectionTitle()
    }

    private func rebuild() {
        guard let summary else { return }

        headerTile.configure(symbol: summary.symbol, tint: summary.tint)
        eyebrowLabel.stringValue = summary.eyebrow.uppercased()
        headlineLabel.stringValue = summary.headline
        sublineLabel.stringValue = subline

        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for item in summary.items { add(row(for: item), fullWidth: true) }
        for gap in summary.gaps { add(gapRow(gap), fullWidth: true) }
        if summary.items.isEmpty && summary.gaps.isEmpty {
            // Not a restatement of the headline, which already says nothing
            // is due - measured in an off-screen render, where the two lines
            // read as the same sentence twice. This one says what the card
            // *is*, so an empty card is still legible as a promise rather
            // than as a card that failed to load.
            add(quietLine("Anything due today, and any follow-up waiting on you, shows up here."),
                fullWidth: false)
        }
        if let note = summary.overflowNote {
            add(quietLine(note), fullWidth: false)
        }

        rebuildClearStrip(summary.clearNotes, hasItems: !summary.items.isEmpty)

        // Every child was rebuilt, so re-apply the card's own chrome colours.
        paintChrome()
        needsLayout = true
    }

    /// The stack is `.leading`-aligned, which sizes an arranged subview to
    /// its own fitting width rather than to the column. A row card has to
    /// span the card, so it takes an explicit tie; a quiet line must not,
    /// or the line's own truncation stops working.
    ///
    /// The tie is `HelmDaylightPriority.contentTie` (499), never required:
    /// this card spans the page, and a required width equality on something
    /// page-wide is gotcha (13)'s window-size cap.
    private func add(_ view: NSView, fullWidth: Bool) {
        listStack.addArrangedSubview(view)
        guard fullWidth else { return }
        let tie = view.widthAnchor.constraint(equalTo: listStack.widthAnchor)
        tie.priority = HelmDaylightPriority.contentTie
        tie.isActive = true
    }

    @objc private func refreshClicked() { onRefresh?() }

    // MARK: The closing "everything else is clear" strip

    /// The reference's footer: a lead-in phrase and one green check chip per
    /// source that was read and is fine.
    ///
    /// The chips are **not** `HelmModuleChip`s and not buttons. The
    /// reference's are clickable and scroll the matching widget into view;
    /// here they are readouts, because the widget they would scroll to is
    /// already on screen a few hundred points below on the only page that
    /// draws this strip - a control whose whole effect is to scroll something
    /// already visible is a control that does nothing, and gotcha (20) is
    /// about how expensive a dead control is to notice.
    private func rebuildClearStrip(_ notes: [String], hasItems: Bool) {
        for view in clearStrip.arrangedSubviews {
            clearStrip.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !notes.isEmpty else {
            clearStrip.isHidden = true
            return
        }
        clearStrip.isHidden = false

        // "Everything else is clear" only makes sense when there *is*
        // something else; on an empty card the reference says "All clear:".
        let lead = NSTextField(labelWithString: hasItems ? "Everything else is clear:" : "All clear:")
        lead.font = HelmType.caption()
        lead.textColor = HelmTheme.mutedInk(theme)
        lead.lineBreakMode = .byTruncatingTail
        lead.translatesAutoresizingMaskIntoConstraints = false
        // gotcha (13): page-wide card, so nothing in it may be a width floor.
        lead.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lead.setContentHuggingPriority(.required, for: .horizontal)
        clearStrip.addArrangedSubview(lead)

        for note in notes { clearStrip.addArrangedSubview(clearChip(note)) }

        // gotcha (10): a trailing spacer is what keeps the chips packed at
        // the leading edge under `.fill`, rather than Auto Layout's own
        // tie-breaking deciding which chip absorbs the row's slack.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clearStrip.addArrangedSubview(spacer)

        // The strip outlives the rebuild that empties the list, so its width
        // tie is created once and reused - creating one per rebuild would
        // stack a fresh 499 equality on the same pair of anchors on every
        // render of a page the captain leaves open all day.
        if clearStripWidthTie == nil {
            let tie = clearStrip.widthAnchor.constraint(equalTo: listStack.widthAnchor)
            tie.priority = HelmDaylightPriority.contentTie
            clearStripWidthTie = tie
        }
        listStack.addArrangedSubview(clearStrip)
        clearStripWidthTie?.isActive = true
    }

    /// One green check chip. `HelmContrast.tintedSurface`/`legibleTintedText`
    /// rather than the hue raw, per AGENTS.md's colour rule - a `HelmTint`
    /// hue is safe as a fill and is not automatically safe as text, and this
    /// chip is both at once.
    private func clearChip(_ text: String) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: text)
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = HelmType.chip()
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ToolRowLayout.pill(text: text, colorHex: HelmTint.good.hex(in: theme),
                           into: container, label: label, theme: theme)
        container.setContentHuggingPriority(.required, for: .horizontal)
        return container
    }

    // MARK: Rows

    private func row(for item: NeedsAttentionItem) -> NSView {
        let view = NeedsAttentionRowView(showsCheckbox: !item.kind.isSignal)
        view.configure(item, theme: theme,
                       onToggle: { [weak self] in self?.onToggleDone?(item) },
                       onOpen: { [weak self] in self?.onOpenItem?(item) })
        // D1's discoverability floor: a list this short or shorter keeps
        // every row's action visible, and this card is normally one or two
        // rows. Above that the buttons go quiet until the row is aimed at.
        let rowCount = summary?.items.count ?? 0
        view.setActionReveal(rowCount <= HelmAccentRow.alwaysRevealRowCount ? .always : .onAim)
        return view
    }

    /// GL-14's own rendering, as an attention row rather than a footnote: a
    /// section this card is responsible for and could not read says so in the
    /// list, with its reason in full and no checkbox to pretend it is
    /// actionable.
    private func gapRow(_ gap: DailyReviewGap) -> NSView {
        let row = HelmAccentRow(hover: false)
        row.configure(HelmAccentRow.Content(
            tint: .warn,
            kicker: gap.section,
            title: gap.reason,
            badgeSymbol: "exclamationmark.shield",
            chipText: "Not available",
            // A reason that truncates is a reason nobody can act on.
            titleWraps: true), theme: theme)
        return row
    }

    private func quietLine(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.caption()
        label.textColor = HelmTheme.mutedInk(theme)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    // MARK: Probe / self-test surface
    //
    // GL-27: debug builds only, like every other `debug*` hook in this app.

    #if FM_SELFTESTS
    var debugEyebrow: String { eyebrowLabel.stringValue }
    var debugHeadline: String { headlineLabel.stringValue }
    var debugSubline: String { sublineLabel.stringValue }
    var debugRows: [NSView] { listStack.arrangedSubviews }
    var debugAccentRows: [HelmAccentRow] {
        listStack.arrangedSubviews.compactMap { view in
            (view as? NeedsAttentionRowView)?.debugRow ?? (view as? HelmAccentRow)
        }
    }
    /// Every string the list is currently painting, top to bottom - what lets
    /// a suite assert the card really says what the composer decided, rather
    /// than that the composer merely computed it.
    var debugListText: [String] { DailyReviewCard.collectText(listStack) }
    var debugHeaderTile: IconTileView { headerTile }
    /// Whether the header carries the Refresh the hero band used to. Read
    /// off the button's own visibility rather than off `onRefresh`, so a
    /// handler wired to a button that never renders fails here.
    var debugRefreshButtonVisible: Bool { !refreshButton.isHidden }
    /// The closing strip's chips, as painted.
    var debugClearNotes: [String] {
        guard !clearStrip.isHidden else { return [] }
        return DailyReviewCard.collectText(clearStrip)
    }
    /// A **real** `performClick` on the header's Refresh, so the assertion
    /// runs the same target/action path a captain's click does rather than
    /// the handler behind it.
    func debugPressRefresh() { refreshButton.performClick(nil) }

    /// Drive a row's checkbox and its action through the **controls** the real
    /// click reaches, never the handler - AGENTS.md's `debugSetHovering` /
    /// `debugClickDisclosure` lesson: a hook that calls the helper stays green
    /// with the wiring deleted.
    func debugPressCheckbox(atRow index: Int) {
        (listStack.arrangedSubviews[index] as? NeedsAttentionRowView)?.debugPressCheckbox()
    }

    func debugPressAction(atRow index: Int) {
        (listStack.arrangedSubviews[index] as? NeedsAttentionRowView)?.debugPressAction()
    }
    #endif
}

// MARK: - One row

/// A thin adapter over `HelmAccentRow`, the same shape `ShiftTaskRowView` is
/// for the Tasks page's own list. Everything visual - the accent bar, the
/// kicker, the body, the chip, the card, the hover highlight and the action
/// reveal - comes from that one component; what is left here is which tint a
/// tone maps to and what the two controls do.
final class NeedsAttentionRowView: NSView {

    /// `nil` on a signal row, which has nothing to tick off - see
    /// `NeedsAttentionItem.Kind.signal`. With no leading control the row
    /// falls back to `HelmAccentRow`'s own badge, which is the component's
    /// documented behaviour and the nearest thing it has to the reference's
    /// severity dot.
    private let checkBadge: ShiftTaskCheckBadge?
    private let actionButton = HelmButton(title: "Open", variant: .quiet, size: .small)
    private let row: HelmAccentRow
    private var onToggle: (() -> Void)?
    private var onOpen: (() -> Void)?

    init(showsCheckbox: Bool) {
        let badge = showsCheckbox ? ShiftTaskCheckBadge() : nil
        checkBadge = badge
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        row = HelmAccentRow(leadingControl: badge, trailingAccessory: actionButton)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        badge?.target = self
        badge?.action = #selector(checkboxClicked)
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setActionReveal(_ reveal: HelmAccentRow.ActionReveal) { row.actionReveal = reveal }

    func configure(_ item: NeedsAttentionItem,
                   theme: HelmTheme,
                   onToggle: @escaping () -> Void,
                   onOpen: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onOpen = onOpen

        let tint = item.tint
        row.configure(HelmAccentRow.Content(
            tint: tint,
            kicker: item.source,
            title: item.text,
            meta: item.meta,
            // A signal row has no checkbox in the badge slot, so the row's
            // own badge carries the tone instead - the component's
            // documented fallback, and the nearest thing it has to the
            // reference's severity dot.
            badgeSymbol: item.kind.isSignal ? Self.signalBadgeSymbol(for: item.tone) : nil,
            chipText: item.chipText,
            // §6.5's signal wash: a late row is the one thing on this card
            // that needs the captain *now*, which is exactly what the opt-in
            // is for.
            isSignal: item.tone == .late), theme: theme)

        // Always unchecked: this card lists what is still open, so a row that
        // gets ticked leaves the list on the next render rather than sitting
        // there struck through.
        checkBadge?.setChecked(false, tint: HelmTheme.nsColor(tint.hex(in: theme)))
        checkBadge?.setAccessibilityLabel("Mark \u{201C}\(item.text)\u{201D} as done")

        actionButton.title = item.actionTitle
        switch item.kind {
        case .task: actionButton.toolTip = "Open this task in Tasks"
        case .followUp: actionButton.toolTip = "Open this follow-up in Tasks"
        case .signal: actionButton.toolTip = "Open the page this is about"
        }
    }

    /// The badge glyph for a signal row, by tone. Deliberately the same two
    /// glyphs `NeedsAttentionSummary.symbol` uses for the header tile, so a
    /// card whose headline says something is at risk shows the same mark
    /// beside the row that says so.
    private static func signalBadgeSymbol(for tone: NeedsAttentionItem.Tone) -> String {
        switch tone {
        case .late, .risk: return "exclamationmark.triangle.fill"
        case .dueToday: return "clock.fill"
        case .info: return "info.circle.fill"
        }
    }

    @objc private func checkboxClicked() { onToggle?() }

    @objc private func actionClicked() { onOpen?() }

    #if FM_SELFTESTS
    var debugRow: HelmAccentRow { row }
    var debugActionTitle: String { actionButton.title }
    /// A **real** `performClick`, so the assertion runs the same target/action
    /// path a captain's click does rather than the handler behind it.
    func debugPressCheckbox() { checkBadge?.performClick(nil) }
    func debugPressAction() { actionButton.performClick(nil) }
    #endif
}
