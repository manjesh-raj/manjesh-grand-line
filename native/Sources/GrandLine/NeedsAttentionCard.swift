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
// ## The UI/UX revamp (UI-1 to UI-4)
//
// The card is now built from the revamp's kit rather than from rows that are
// cards of their own:
//
//   - the header is `HelmSectionHeader(.hero)` and Refresh is a line button;
//   - the rows are `HelmAccentRow(.flat)` in a `HelmFlatList`, so the card is
//     the only bordered surface - the overdue fact is a red caption, the
//     action shows on aim and the row itself opens the item;
//   - the clear strip is sunk into the card's foot as words with check
//     glyphs, because the pills it used to be read as controls;
//   - the card carries the page's one attention edge, and only while
//     something on it needs the captain.
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
    /// A row's trailing button ("Start" / "Open"), or the row itself, was
    /// clicked.
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
    /// UI-3: the kit's one header, in its hero size - tile, eyebrow, a 19pt
    /// heavy rounded headline and the subline.
    private let header = HelmSectionHeader(size: .hero)
    /// UI-3: a line (secondary) button. Refresh is not the page's primary
    /// action - nothing on Home is - and a filled accent pill in the corner
    /// of the verdict card was the loudest thing on the page.
    private let refreshButton = HelmButton(title: "Refresh", variant: .secondary, size: .small,
                                           symbol: "arrow.clockwise")
    /// UI-1: the rows are flat, separated by hairlines, inside the one card.
    private let list = HelmFlatList()
    /// Quiet lines under the list (the empty promise, the overflow note).
    private let notesStack = NSStackView()
    /// UI-2: the closing strip, sunk into the card's foot.
    private let clearStrip = NSView()
    private let clearRow = NSStackView()
    private let clearRule = NSView()
    private let body = NSStackView()

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
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.isHidden = true
        header.setActions([refreshButton])
        card.setHeader(header, insets: NSEdgeInsets(top: HelmMetrics.s4, left: HelmMetrics.s4,
                                                     bottom: HelmMetrics.s4, right: HelmMetrics.s4))

        notesStack.orientation = .vertical
        notesStack.alignment = .leading
        notesStack.spacing = HelmMetrics.s1
        notesStack.edgeInsets = NSEdgeInsets(top: HelmMetrics.s3, left: HelmMetrics.s4,
                                             bottom: HelmMetrics.s3, right: HelmMetrics.s4)
        notesStack.translatesAutoresizingMaskIntoConstraints = false
        notesStack.setHuggingPriority(.defaultLow, for: .horizontal)
        notesStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        buildClearStrip()

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.distribution = .fill
        body.translatesAutoresizingMaskIntoConstraints = false
        body.setHuggingPriority(.defaultLow, for: .horizontal)
        body.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for view in [list, notesStack, clearStrip] as [NSView] {
            body.addArrangedSubview(view)
            // gotcha (13): this card spans the page, so a full-width tie is
            // `contentTie`, never required.
            let tie = view.widthAnchor.constraint(equalTo: body.widthAnchor)
            tie.priority = HelmDaylightPriority.contentTie
            tie.isActive = true
        }
        card.setBody(body)

        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme(theme)
    }

    /// The strip under the list: a hairline, the sunk `inset` fill, and the
    /// readings that are fine as plain words with green checks. UI-2: these
    /// used to be three green pills, which read as controls and were not.
    private func buildClearStrip() {
        clearStrip.wantsLayer = true
        clearStrip.translatesAutoresizingMaskIntoConstraints = false
        clearStrip.isHidden = true
        clearRule.wantsLayer = true
        clearRule.translatesAutoresizingMaskIntoConstraints = false

        clearRow.orientation = .horizontal
        clearRow.alignment = .centerY
        clearRow.spacing = HelmMetrics.s4
        clearRow.distribution = .fill
        clearRow.translatesAutoresizingMaskIntoConstraints = false
        clearRow.setHuggingPriority(.defaultLow, for: .horizontal)
        clearRow.setClippingResistancePriority(.defaultLow, for: .horizontal)

        clearStrip.addSubview(clearRule)
        clearStrip.addSubview(clearRow)
        NSLayoutConstraint.activate([
            clearRule.leadingAnchor.constraint(equalTo: clearStrip.leadingAnchor),
            clearRule.trailingAnchor.constraint(equalTo: clearStrip.trailingAnchor),
            clearRule.topAnchor.constraint(equalTo: clearStrip.topAnchor),
            clearRule.heightAnchor.constraint(equalToConstant: 1),
            clearRow.leadingAnchor.constraint(equalTo: clearStrip.leadingAnchor, constant: HelmMetrics.s4),
            clearRow.trailingAnchor.constraint(lessThanOrEqualTo: clearStrip.trailingAnchor,
                                               constant: -HelmMetrics.s4),
            clearRow.topAnchor.constraint(equalTo: clearRule.bottomAnchor, constant: 10),
            clearRow.bottomAnchor.constraint(equalTo: clearStrip.bottomAnchor, constant: -10),
        ])
    }

    // MARK: Render

    /// - Parameter subline: the line under the headline - the fleet's
    ///   freshness. The host passes it rather than this card formatting a
    ///   date of its own, so the two places that say when the fleet was read
    ///   can never disagree.
    func render(_ summary: NeedsAttentionSummary, subline: String, theme: HelmTheme) {
        self.summary = summary
        self.subline = subline
        self.theme = theme
        rebuild()
    }

    /// Rewrites only the subline - the freshness phrase ticks once a minute
    /// (UI-13) without rebuilding a row.
    func setSubline(_ subline: String) {
        guard subline != self.subline, let summary else { return }
        self.subline = subline
        header.configure(leading: .tile(symbol: summary.symbol, tint: summary.tint),
                         title: summary.headline, eyebrow: summary.eyebrow, subline: subline)
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
        header.applyTheme(theme)
        list.applyTheme(theme)
        clearRule.layer?.backgroundColor = HelmFlatList.hairRowColor(theme).cgColor
        clearStrip.layer?.backgroundColor = (theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.18)).cgColor
        // The strip is the card's foot, so its lower corners follow the
        // card's - `HelmCard` cannot clip (it casts a shadow), so the strip
        // rounds itself. Unflipped layer space: `MinY` is the bottom.
        clearStrip.layer?.cornerRadius = card.layer?.cornerRadius ?? 0
        clearStrip.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    private func rebuild() {
        guard let summary else { return }

        header.configure(leading: .tile(symbol: summary.symbol, tint: summary.tint),
                         title: summary.headline, eyebrow: summary.eyebrow, subline: subline)

        var rows: [NSView] = summary.items.map { row(for: $0) }
        rows += summary.gaps.map { gapRow($0) }
        list.setRows(rows, theme: theme)
        list.isHidden = rows.isEmpty

        for view in notesStack.arrangedSubviews {
            notesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if summary.items.isEmpty && summary.gaps.isEmpty && summary.clearNotes.isEmpty {
            // Not a restatement of the headline, which already says nothing
            // is due. This one says what the card *is*, so an empty card is
            // still legible as a promise rather than as a card that failed
            // to load.
            notesStack.addArrangedSubview(quietLine(
                "Anything due today, and any follow-up waiting on you, shows up here."))
        }
        if let note = summary.overflowNote {
            notesStack.addArrangedSubview(quietLine(note))
        }
        notesStack.isHidden = notesStack.arrangedSubviews.isEmpty
        // A list with rows already ends on its own last row, so the notes sit
        // directly under it; with no rows they need the card's top padding.
        notesStack.edgeInsets.top = rows.isEmpty ? HelmMetrics.s3 : HelmMetrics.s2

        rebuildClearStrip(summary.clearNotes, hasItems: !summary.items.isEmpty)

        // UI-4: the card carries the page's only attention edge, and only
        // while it is saying that something needs the captain.
        card.setAttentionEdge(summary.items.isEmpty && summary.gaps.isEmpty ? nil : summary.tint)

        paintChrome()
        needsLayout = true
    }

    @objc private func refreshClicked() { onRefresh?() }

    // MARK: The closing strip

    /// UI-2: "Everything else is clear" and one check-and-word per source
    /// that was read and is fine. Readouts, not controls - which is why they
    /// are no longer pill-shaped. The widget each one would scroll to is
    /// already on screen a few hundred points below.
    private func rebuildClearStrip(_ notes: [String], hasItems: Bool) {
        for view in clearRow.arrangedSubviews {
            clearRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !notes.isEmpty else {
            clearStrip.isHidden = true
            return
        }
        clearStrip.isHidden = false

        // "Everything else is clear" only makes sense when there *is*
        // something else; on an empty card the reference says "All clear".
        let lead = NSTextField(labelWithString: hasItems ? "Everything else is clear" : "All clear")
        lead.font = HelmType.caption()
        lead.textColor = HelmTheme.mutedInk(theme)
        lead.lineBreakMode = .byTruncatingTail
        lead.translatesAutoresizingMaskIntoConstraints = false
        lead.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lead.setContentHuggingPriority(.required, for: .horizontal)
        clearRow.addArrangedSubview(lead)
        for note in notes { clearRow.addArrangedSubview(clearNote(note)) }
    }

    private func clearNote(_ text: String) -> NSView {
        let surface = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : HelmTheme.nsColor(theme.chromeBackgroundHex)
        let ok = HelmContrast.legibleTintedText(tintHex: HelmTint.good.hex(in: theme), over: surface, theme: theme)
        let glyph = NSImageView()
        glyph.image = HelmSymbol.image("checkmark", pointSize: 10, weight: .bold)
        glyph.contentTintColor = ok
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setAccessibilityElement(false)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: HelmType.scaled(12), weight: .semibold)
        label.textColor = ok
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pair = NSStackView(views: [glyph, label])
        pair.orientation = .horizontal
        pair.alignment = .centerY
        pair.spacing = HelmMetrics.s1
        pair.translatesAutoresizingMaskIntoConstraints = false
        pair.setHuggingPriority(.required, for: .horizontal)
        return pair
    }

    // MARK: Rows

    private func row(for item: NeedsAttentionItem) -> NSView {
        let view = NeedsAttentionRowView(showsCheckbox: !item.kind.isSignal)
        view.configure(item, theme: theme,
                       onToggle: { [weak self] in self?.onToggleDone?(item) },
                       onOpen: { [weak self] in self?.onOpenItem?(item) })
        return view
    }

    /// GL-14's own rendering, as an attention row rather than a footnote: a
    /// section this card is responsible for and could not read says so in the
    /// list, with its reason in full and no checkbox to pretend it is
    /// actionable.
    private func gapRow(_ gap: DailyReviewGap) -> NSView {
        let row = HelmAccentRow(hover: false, style: .flat)
        row.configure(HelmAccentRow.Content(
            tint: .warn,
            kicker: gap.section,
            title: gap.reason,
            badgeSymbol: "exclamationmark.shield",
            // A reason that truncates is a reason nobody can act on.
            titleWraps: true,
            trailingCaption: "Not available",
            trailingCaptionTint: .warn), theme: theme)
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
    var debugEyebrow: String { header.eyebrowLabel.stringValue }
    var debugHeadline: String { header.titleLabel.stringValue }
    var debugSubline: String { header.sublineLabel.stringValue }
    var debugRows: [NSView] { list.rows }
    var debugAccentRows: [HelmAccentRow] {
        list.rows.compactMap { view in
            (view as? NeedsAttentionRowView)?.debugRow ?? (view as? HelmAccentRow)
        }
    }
    /// Every string the list is currently painting, top to bottom - what lets
    /// a suite assert the card really says what the composer decided, rather
    /// than that the composer merely computed it.
    var debugListText: [String] { DailyReviewCard.collectText(body) }
    var debugHeader: HelmSectionHeader { header }
    var debugCard: HelmCard { card }
    /// Whether the header carries the Refresh. Read off the button's own
    /// visibility rather than off `onRefresh`, so a handler wired to a button
    /// that never renders fails here.
    var debugRefreshButtonVisible: Bool { !refreshButton.isHidden }
    var debugRefreshButton: HelmButton { refreshButton }
    /// The closing strip's words, as painted (the lead and each note).
    var debugClearNotes: [String] {
        guard !clearStrip.isHidden else { return [] }
        return DailyReviewCard.collectText(clearRow)
    }
    var debugClearStrip: NSView { clearStrip }
    /// A **real** `performClick` on the header's Refresh, so the assertion
    /// runs the same target/action path a captain's click does rather than
    /// the handler behind it.
    func debugPressRefresh() { refreshButton.performClick(nil) }

    /// Drive a row's checkbox and its action through the **controls** the real
    /// click reaches, never the handler - AGENTS.md's `debugSetHovering` /
    /// `debugClickDisclosure` lesson: a hook that calls the helper stays green
    /// with the wiring deleted.
    func debugPressCheckbox(atRow index: Int) {
        (list.rows[index] as? NeedsAttentionRowView)?.debugPressCheckbox()
    }

    func debugPressAction(atRow index: Int) {
        (list.rows[index] as? NeedsAttentionRowView)?.debugPressAction()
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
    private let actionButton = HelmButton(title: "Open", variant: .secondary, size: .small)
    private let row: HelmAccentRow
    private var onToggle: (() -> Void)?
    private var onOpen: (() -> Void)?

    init(showsCheckbox: Bool) {
        let badge = showsCheckbox ? ShiftTaskCheckBadge() : nil
        checkBadge = badge
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        // UI-1: a flat row inside the card, the action revealed on aim and
        // the row itself the click target.
        row = HelmAccentRow(leadingControl: badge, trailingAccessory: actionButton, style: .flat)
        row.actionReveal = .onAim
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
            // UI-1: the "Overdue 26 days" fact is a caption in the state
            // colour, not a pill - the row is already on the attention card,
            // so a second capsule shouting the same thing was decoration.
            trailingCaption: item.chipText,
            trailingCaptionTint: Self.captionTint(for: item.tone)), theme: theme)
        row.onClick = { [weak self] in self?.onOpen?() }

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

    /// The caption's colour, by tone: red for late, amber for what is due or
    /// at risk today (the board's own rule - UI-24), and muted for a fact.
    static func captionTint(for tone: NeedsAttentionItem.Tone) -> HelmTint? {
        switch tone {
        case .late: return .critical
        case .risk, .dueToday: return .warn
        case .info: return nil
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
    /// The row's own click, as `HelmAccentRow.accessibilityPerformPress`
    /// reaches it - the row is the click target now (UI-1).
    func debugPressRow() -> Bool { row.accessibilityPerformPress() }
    /// A **real** `performClick`, so the assertion runs the same target/action
    /// path a captain's click does rather than the handler behind it.
    func debugPressCheckbox() { checkBadge?.performClick(nil) }
    func debugPressAction() { actionButton.performClick(nil) }
    #endif
}
