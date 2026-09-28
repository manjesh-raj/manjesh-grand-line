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
// ## The three deliberate deviations from the mockup
//
//   1. **No Refresh button in the header.** The mockup puts one there, beside
//      a "Fleet read 4 minutes ago" subline. On the real Home page this card
//      sits a few points under the hero band, which already carries a Refresh
//      that re-runs exactly the pass the mockup's one would - two Refresh
//      buttons one above the other is the kind of duplication review #3's UX5
//      objected to on this very page.
//   2. **The subline is the day and the time this was composed**, not "Fleet
//      read 4 minutes ago". Tasks and follow-ups come from an in-memory store
//      this page re-reads on every render, so a fleet-freshness line would be
//      a claim about a different source - and a freshness phrase derived from
//      a read that just happened can only ever say "just now", which tells a
//      captain nothing. `DailyReviewDigest.kicker` is the same "as of" line
//      the Today page's card already carries, so the two agree.
//   3. **No "Everything else is clear: [chips]" strip.** It links to Home
//      cards for sources this card does not read, and inventing that link
//      would mean this page fetching something (its file header's first rule).
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

    private let card = HelmCard()
    private let headerTile = IconTileView(size: HelmMetrics.tileBase, cornerRadius: 9)
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let headlineLabel = NSTextField(labelWithString: "")
    private let sublineLabel = NSTextField(labelWithString: "")
    /// The list. Rebuilt wholesale on every render.
    private let listStack = NSStackView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var summary: NeedsAttentionSummary?
    private var subline: String = ""

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

        let headerRow = NSStackView(views: [headerTile, textColumn])
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

    // MARK: Rows

    private func row(for item: NeedsAttentionItem) -> NSView {
        let view = NeedsAttentionRowView()
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

    private let checkBadge = ShiftTaskCheckBadge()
    private let actionButton = HelmButton(title: "Open", variant: .quiet, size: .small)
    private let row: HelmAccentRow
    private var onToggle: (() -> Void)?
    private var onOpen: (() -> Void)?

    override init(frame frameRect: NSRect) {
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        row = HelmAccentRow(leadingControl: checkBadge, trailingAccessory: actionButton)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        checkBadge.target = self
        checkBadge.action = #selector(checkboxClicked)
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

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setActionReveal(_ reveal: HelmAccentRow.ActionReveal) { row.actionReveal = reveal }

    func configure(_ item: NeedsAttentionItem,
                   theme: HelmTheme,
                   onToggle: @escaping () -> Void,
                   onOpen: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onOpen = onOpen

        let tint: HelmTint = item.tone == .late ? .critical : .info
        row.configure(HelmAccentRow.Content(
            tint: tint,
            kicker: item.source,
            title: item.text,
            meta: item.meta,
            chipText: item.chipText,
            // §6.5's signal wash: a late row is the one thing on this card
            // that needs the captain *now*, which is exactly what the opt-in
            // is for.
            isSignal: item.tone == .late), theme: theme)

        // Always unchecked: this card lists what is still open, so a row that
        // gets ticked leaves the list on the next render rather than sitting
        // there struck through.
        checkBadge.setChecked(false, tint: HelmTheme.nsColor(tint.hex(in: theme)))
        checkBadge.setAccessibilityLabel("Mark \u{201C}\(item.text)\u{201D} as done")

        actionButton.title = item.actionTitle
        actionButton.toolTip = item.kind == .task
            ? "Open this task in Tasks"
            : "Open this follow-up in Tasks"
    }

    @objc private func checkboxClicked() { onToggle?() }

    @objc private func actionClicked() { onOpen?() }

    #if FM_SELFTESTS
    var debugRow: HelmAccentRow { row }
    var debugActionTitle: String { actionButton.title }
    /// A **real** `performClick`, so the assertion runs the same target/action
    /// path a captain's click does rather than the handler behind it.
    func debugPressCheckbox() { checkBadge.performClick(nil) }
    func debugPressAction() { actionButton.performClick(nil) }
    #endif
}
