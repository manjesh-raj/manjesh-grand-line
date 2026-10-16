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
// ## The list scrolls inside the card (`fm/grandline-home-fit-implement`)
//
// The captain asked for Home to fit the window, with the follow-ups list
// scrolling inside its own card rather than growing the page. So the list sits
// in its own `NSScrollView`, and the card's height comes from its host:
//
//   - The scroll view prefers the list's full height (`listShowsAllRows`, 490)
//     and never goes below three rows (`minimumVisibleRows`, required). When
//     the host gives the card less room than the whole list, the 499 column
//     tie wins over the 490 preference and the list scrolls. When it gives
//     more, the scroll view absorbs the slack, so the clear strip stays at the
//     card's foot and the empty space sits under the last row.
//   - The total is always in the eyebrow ("NEEDS ATTENTION \u{00B7} 10"), and
//     while rows are clipped a "+N more" pill sits on the list's bottom edge
//     over a short fade. It goes away once the last row is in view.
//   - The scroller is the small control size and follows the system's
//     scroll-bar setting, because the pill already says there is more.
//   - A row that takes keyboard focus scrolls itself into view, and VoiceOver
//     hears the list as one group naming how many rows it has and how many
//     are visible. Every row stays in the accessibility tree.
//   - A wheel event over a list that has nothing to scroll goes to the page,
//     so the page's own fallback scroll (the minimum window with Larger text)
//     still works with the pointer over the card.
//
// Rows are the N1 shape the captain picked: the title on line one, and the
// kind and the state together on line two ("Follow-up \u{00B7} Overdue 27 days
// \u{00B7} since 18 Sep"), the state run in its tint. The separate kicker line
// and the far-right caption are gone, so every row is the same height and the
// status sits under the title rather than a page-width away from it.
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
    /// The list's own scroll view - see the file header.
    private let listScroll = NeedsAttentionListScrollView()
    private let listDocument = FlippedView()
    /// The list's preferred height, at `listShowsAllRows`.
    private var listShowsAll: NSLayoutConstraint?
    /// The floor: `minimumVisibleRows` rows, or every row when there are
    /// fewer.
    private var listFloor: NSLayoutConstraint?
    /// "+N more", while rows are clipped below the visible part of the list.
    private let morePill = NeedsAttentionMorePill()
    private let moreFade = NeedsAttentionFadeView()
    /// Scrolling, and the clip or the list changing size, all move the cue.
    private var cueObservers: [NSObjectProtocol] = []
    /// The width the host laid this card out at, which decides the compact
    /// header - see `setLayoutWidth`.
    private var layoutWidth: CGFloat = 0
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

    /// UI-13: re-derives the subline (the fleet's "read 4 min ago") so it
    /// stays true while the card sits on screen. Called once a minute, only
    /// while the card is in a window; it rewrites one label and fetches
    /// nothing (GL-24).
    var sublineProvider: (() -> String)?
    private var tick: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// At least this many rows are always on screen, which is what sets the
    /// card's own minimum height.
    static let minimumVisibleRows = 3
    /// The list's preference for showing every row. Under the 499 a host ties
    /// the card's height with, so a page that has to fit wins; over anything
    /// that merely stretches.
    static let listShowsAllRows = NSLayoutConstraint.Priority(490)
    /// How hard the notes and the clear strip hold their own height, so a
    /// stretched card's slack goes to the list - measured: without it the
    /// clear strip grew to a 160pt grey block at 1512x945.
    static let footHug = NSLayoutConstraint.Priority(495)
    /// Below this card width the headline drops to 15pt and wraps to three
    /// lines, Refresh is a glyph, and the rows shorten their state.
    static let compactHeaderWidth: CGFloat = 420
    /// Below this width the clear strip drops its "Everything else is clear"
    /// lead and keeps only the readings.
    static let clearLeadWidth: CGFloat = 560
    /// The compact headline's line limit. Three rather than the board's two:
    /// measured in a 293pt column, the captain's own two-clause verdict
    /// ("Five things are late, and 1 task needs your call.") needs three
    /// lines at 15pt, and a verdict cut mid-sentence is the one thing the
    /// compact header exists to avoid.
    static let compactHeadlineLines = 3
    /// The header's single-line labels in a page column: under every
    /// stack's 250 clipping resistance, so they truncate rather than
    /// overflow.
    static let columnLineResistance = NSLayoutConstraint.Priority(249)

    deinit {
        tick?.invalidate()
        for observer in cueObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// GL-13: the tick runs only while the card is in a window, and a hidden
    /// page skips it (the shell hides destinations rather than removing them).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tick?.invalidate()
        tick = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tickSubline() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func tickSubline() {
        guard !isHiddenOrHasHiddenAncestor, let provider = sublineProvider else { return }
        setSubline(provider())
    }

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
        buildListScroll()

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.distribution = .fill
        body.translatesAutoresizingMaskIntoConstraints = false
        body.setHuggingPriority(.defaultLow, for: .horizontal)
        body.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for view in [listScroll, notesStack, clearStrip] as [NSView] {
            body.addArrangedSubview(view)
            // gotcha (13): this card spans the page, so a full-width tie is
            // `contentTie`, never required.
            let tie = view.widthAnchor.constraint(equalTo: body.widthAnchor)
            tie.priority = HelmDaylightPriority.contentTie
            tie.isActive = true
        }
        card.setBody(body)

        // The pill and its fade sit over the list's bottom edge, outside the
        // scroll view so they do not scroll with it.
        body.addSubview(moreFade)
        body.addSubview(morePill)
        NSLayoutConstraint.activate([
            moreFade.leadingAnchor.constraint(equalTo: listScroll.leadingAnchor),
            moreFade.trailingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            moreFade.bottomAnchor.constraint(equalTo: listScroll.bottomAnchor),
            moreFade.heightAnchor.constraint(equalToConstant: 28),
            morePill.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            morePill.bottomAnchor.constraint(equalTo: listScroll.bottomAnchor, constant: -HelmMetrics.s2),
        ])
        morePill.onPress = { [weak self] in self?.pageDown() }

        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme(theme)
    }

    /// The list's scroll view: vertical only, no background, the small
    /// scroller, and a flipped document pinned to the clip view (gotchas (4)
    /// and (9)).
    private func buildListScroll() {
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = false
        listScroll.autohidesScrollers = true
        listScroll.verticalScroller?.controlSize = .small
        listScroll.verticalScrollElasticity = .allowed
        listScroll.horizontalScrollElasticity = .none
        listDocument.translatesAutoresizingMaskIntoConstraints = false
        listDocument.addSubview(list)
        listScroll.documentView = listDocument
        // Two halves. `>=` at 490 is "show every row unless the host's 499
        // says otherwise"; `==` at 249 is the list's natural height where
        // nothing stretches the card (the shelf), so the height is never
        // ambiguous. Where a host does stretch it, the notes and the clear
        // strip hug at `footHug` and the list takes the slack, which leaves
        // the strip at the card's foot.
        let showsAll = listScroll.heightAnchor.constraint(greaterThanOrEqualTo: list.heightAnchor)
        showsAll.priority = Self.listShowsAllRows
        let natural = listScroll.heightAnchor.constraint(equalTo: list.heightAnchor)
        // Under 250, the list stack's own hugging: at 251 this tie pulled
        // the *list* up to the scroll view's height and stretched its first
        // row - measured at 1512x945.
        natural.priority = NSLayoutConstraint.Priority(249)
        let floor = listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        NSLayoutConstraint.activate([
            listDocument.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            listDocument.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
            listDocument.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: listDocument.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: listDocument.trailingAnchor),
            list.topAnchor.constraint(equalTo: listDocument.topAnchor),
            list.bottomAnchor.constraint(equalTo: listDocument.bottomAnchor),
            showsAll,
            natural,
            floor,
        ])
        notesStack.setHuggingPriority(Self.footHug, for: .vertical)
        clearRow.setHuggingPriority(Self.footHug, for: .vertical)
        listShowsAll = showsAll
        listFloor = floor
        listScroll.setAccessibilityRole(.group)

        listScroll.contentView.postsBoundsChangedNotifications = true
        listScroll.contentView.postsFrameChangedNotifications = true
        listDocument.postsFrameChangedNotifications = true
        list.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        cueObservers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: listScroll.contentView,
                               queue: .main) { [weak self] _ in self?.updateMoreCue() },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: listScroll.contentView,
                               queue: .main) { [weak self] _ in self?.updateMoreCue() },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: listDocument,
                               queue: .main) { [weak self] _ in self?.updateMoreCue() },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: list,
                               queue: .main) { [weak self] _ in self?.updateMoreCue() },
        ]

        moreFade.translatesAutoresizingMaskIntoConstraints = false
        moreFade.isHidden = true
        moreFade.setAccessibilityElement(false)
        morePill.isHidden = true
    }

    override func layout() {
        super.layout()
        updateMoreCue()
    }

    /// The host's laid-out width for this card. Below `compactHeaderWidth`
    /// the header is the compact one; it also lets the headline wrap against
    /// a width this card does not itself decide (gotcha (22)).
    func setLayoutWidth(_ width: CGFloat) {
        guard abs(width - layoutWidth) > 0.5 else { return }
        layoutWidth = width
        if summary != nil { rebuild() }
    }

    private var isCompact: Bool { layoutWidth > 0 && layoutWidth < Self.compactHeaderWidth }

    // MARK: The "+N more" cue

    /// Each row's bottom edge in the list, from the rows' own heights and the
    /// 1pt hairlines between them - taken at rebuild, so the count below
    /// never depends on whether the list's stack has placed its rows yet.
    /// Measured: counted from row frames, the cue was stale one run in three
    /// after a rebuild that left the list's and the clip's frames unchanged,
    /// because nothing then re-triggered the count.
    private var rowBottoms: [CGFloat] = []

    /// How many rows lie wholly or partly below the visible part of the list.
    private var rowsBelowTheFold: Int {
        let visible = listScroll.contentView.documentVisibleRect
        guard let total = rowBottoms.last, total > visible.height + 0.5 else { return 0 }
        return rowBottoms.filter { $0 > visible.maxY + 0.5 }.count
    }

    /// Taken synchronously, on every scroll, every frame change of the clip,
    /// the document or the list, every rebuild and every layout. It reads
    /// only the clip's visible rect and `rowBottoms`, both of which are
    /// current at each of those moments, so there is nothing to wait for.
    /// Measured: an earlier version hopped to the next main-queue turn, and
    /// on CI's runner that queued update had still not run when a suite
    /// read the cue (its log showed it pending), so the cue was stale.
    private func updateMoreCue() {
        let hidden = rowsBelowTheFold
        morePill.isHidden = hidden == 0
        moreFade.isHidden = hidden == 0
        if hidden > 0 { morePill.configure(count: hidden, theme: theme) }
        let total = rowBottoms.count
        let visible = total - hidden
        listScroll.setAccessibilityLabel(hidden == 0
            ? "Needs attention, \(total) \(total == 1 ? "item" : "items")"
            : "Needs attention, \(total) items, \(visible) visible")
    }

    /// The pill's press: one page down, keeping one row of context.
    private func pageDown() {
        let clip = listScroll.contentView
        let visible = clip.documentVisibleRect
        let maxY = max(0, listDocument.frame.height - visible.height)
        let target = min(maxY, visible.minY + max(visible.height - 53, 53))
        clip.scroll(to: NSPoint(x: 0, y: target))
        listScroll.reflectScrolledClipView(clip)
        updateMoreCue()
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
        configureHeader(summary)
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
        listScroll.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        moreFade.surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        morePill.applyTheme(theme)
        if isCompact {
            // The compact header's headline: 15pt rather than the hero's 19pt,
            // so a two-clause verdict fits two lines of a 293pt column.
            // After `header.applyTheme`, which sets the hero face.
            header.titleLabel.font = HelmType.rounded(HelmType.scaled(15), .heavy)
        }
    }

    private func rebuild() {
        guard let summary else { return }

        configureHeader(summary)

        var rows: [NSView] = summary.items.map { row(for: $0) }
        rows += summary.gaps.map { gapRow($0) }
        list.setRows(rows, theme: theme)
        listScroll.isHidden = rows.isEmpty
        listFloor?.constant = Self.floorHeight(of: rows)
        var bottom: CGFloat = 0
        rowBottoms = rows.enumerated().map { index, row in
            bottom += row.fittingSize.height + (index > 0 ? 1 : 0)
            return bottom
        }

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

        rebuildClearStrip(summary.clearNotes, hasItems: !summary.items.isEmpty,
                          showsLead: layoutWidth <= 0 || layoutWidth >= Self.clearLeadWidth)

        // UI-4: the card carries the page's only attention edge, and only
        // while it is saying that something needs the captain.
        card.setAttentionEdge(summary.items.isEmpty && summary.gaps.isEmpty ? nil : summary.tint)

        paintChrome()
        needsLayout = true
        updateMoreCue()
    }

    /// The header, in its full or its compact form.
    ///
    /// Compact is the hero header with a 15pt headline wrapping to at most
    /// three lines and Refresh as a glyph. The subline stays: it is the
    /// fleet's freshness (UX5), the one thing on the page no other card can
    /// say, and it costs one caption line in a column whose list absorbs
    /// the difference. The headline's
    /// wrap width is derived from the host's width, never from the label's
    /// own (gotcha (22)).
    private func configureHeader(_ summary: NeedsAttentionSummary) {
        let compact = isCompact
        header.configure(leading: .tile(symbol: summary.symbol, tint: summary.tint),
                         title: summary.headline, eyebrow: summary.eyebrow,
                         subline: subline)
        let title = header.titleLabel
        title.toolTip = summary.headline
        refreshButton.title = compact ? "" : "Refresh"
        refreshButton.toolTip = compact ? "Refresh" : nil
        refreshButton.setAccessibilityLabel("Refresh")
        if layoutWidth > 0 {
            // In a page column the headline wraps against the column's own
            // width. Measured: left on one line at 477pt, the hero label's
            // 490 compression resistance beat the header stack's clipping
            // and the verdict ran past the card into the Claude card.
            title.cell?.wraps = true
            title.cell?.truncatesLastVisibleLine = true
            title.maximumNumberOfLines = compact ? Self.compactHeadlineLines : 2
            title.lineBreakMode = .byWordWrapping
            // The header row is tile, text, spacer, actions with a 12pt gap
            // between each - three gaps, not one. Measured: counting one left
            // the headline 12pt too wide, and whether the row then clipped
            // the Refresh off the card or squeezed the text was Auto
            // Layout's own tie-break.
            //
            // Floored, less one point: a label's intrinsic width is rounded up
            // to a whole device pixel, which is a whole point on a 1x display.
            // Measured on CI's 1x runner: with zero slack the row came out 1pt
            // wide and the Refresh ended at 278 in a 293pt card (277 is its
            // edge), where a 2x Mac rounds to half a point and fits.
            let actions = refreshButton.isHidden ? 0 : refreshButton.fittingSize.width + HelmMetrics.s3
            title.preferredMaxLayoutWidth = max(80, (layoutWidth - HelmMetrics.s4 * 2
                                                     - HelmSectionHeader.tileSide(for: .hero)
                                                     - HelmMetrics.s3 * 2 - actions).rounded(.down) - 1)
            // The eyebrow and the subline are single lines that must truncate
            // in a column. At the header's 490 their compression resistance
            // ties the text column's own 490 clipping resistance and loses to
            // the row's 250, so a long subline ran off the card. Under 250
            // they give way first; the subline's full text is on its hover.
            for label in [header.eyebrowLabel, header.sublineLabel] {
                label.setContentCompressionResistancePriority(Self.columnLineResistance, for: .horizontal)
            }
            header.sublineLabel.toolTip = subline
        } else {
            for label in [header.eyebrowLabel, header.sublineLabel] {
                label.setContentCompressionResistancePriority(HelmSectionHeader.textResistance, for: .horizontal)
            }
            header.sublineLabel.toolTip = nil
            title.cell?.wraps = false
            title.maximumNumberOfLines = 1
            title.lineBreakMode = .byTruncatingTail
            title.preferredMaxLayoutWidth = 0
        }
    }

    /// The list's floor: the first `minimumVisibleRows` rows and the
    /// hairlines between them, or all of them when there are fewer.
    private static func floorHeight(of rows: [NSView]) -> CGFloat {
        let shown = rows.prefix(minimumVisibleRows)
        guard !shown.isEmpty else { return 0 }
        return shown.reduce(0) { $0 + $1.fittingSize.height } + CGFloat(shown.count - 1)
    }

    @objc private func refreshClicked() { onRefresh?() }

    // MARK: The closing strip

    /// UI-2: "Everything else is clear" and one check-and-word per source
    /// that was read and is fine. Readouts, not controls - which is why they
    /// are no longer pill-shaped. The widget each one would scroll to is
    /// already on screen a few hundred points below.
    private func rebuildClearStrip(_ notes: [String], hasItems: Bool, showsLead: Bool) {
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
        lead.isHidden = !showsLead
        // In a narrow column the readings stack, one per line, rather than
        // truncating each other on one line.
        clearRow.orientation = isCompact ? .vertical : .horizontal
        clearRow.alignment = isCompact ? .leading : .centerY
        clearRow.spacing = isCompact ? HelmMetrics.s1 : HelmMetrics.s4
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
        // One above the strip row's own 250 hugging, which it tied at 250:
        // measured, "Claude plan limits comfortable" truncated with room to
        // spare in a 293pt column on one render and not the next.
        label.setContentCompressionResistancePriority(HelmDaylightPriority.columnHug, for: .horizontal)
        let pair = NSStackView(views: [glyph, label])
        pair.orientation = .horizontal
        pair.alignment = .centerY
        // gotcha (10): `.fill`, or a pair stretched to a stacked strip's
        // width spreads its glyph and its words apart.
        pair.distribution = .fill
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        pair.spacing = HelmMetrics.s1
        pair.translatesAutoresizingMaskIntoConstraints = false
        pair.setHuggingPriority(.required, for: .horizontal)
        return pair
    }

    // MARK: Rows

    private func row(for item: NeedsAttentionItem) -> NSView {
        let view = NeedsAttentionRowView(showsCheckbox: !item.kind.isSignal)
        view.configure(item, theme: theme, compact: isCompact,
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
    var debugListScroll: NeedsAttentionListScrollView { listScroll }
    /// The "+N more" pill's count, or `nil` while it is hidden.
    var debugMoreCount: Int? { morePill.isHidden ? nil : morePill.count }
    /// What the cue was last computed from, for a failure message that says
    /// why - the cached row bottoms, the clip's visible rect, the document's
    /// height and the window's first responder.
    var debugCueState: String {
        let visible = listScroll.contentView.documentVisibleRect
        return "visible \(visible), document \(listDocument.frame.height), "
            + "row bottoms \(rowBottoms.map { Int($0) }), "
            + "first responder \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")"
    }
    var debugMorePill: NeedsAttentionMorePill { morePill }
    var debugIsCompact: Bool { isCompact }
    var debugListAccessibilityLabel: String? { listScroll.accessibilityLabel() }
    /// Fires the minute tick now, through the same path the timer takes.
    func debugTickSubline() { tickSubline() }
    var debugTickIsRunning: Bool { tick?.isValid ?? false }
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

    /// - Parameter compact: a narrow column (the 960pt minimum window's
    ///   293pt). Beside the action there is room for the state's first phrase
    ///   and little else, so the line becomes "Overdue 27 days" alone - the
    ///   checkbox or the signal glyph still says what kind of row it is - and
    ///   the full "Follow-up \u{00B7} Overdue 27 days \u{00B7} since 18 Sep" moves
    ///   to the row's hover text. Measured: with the kind kept, the state was
    ///   cut at "Overdue 27".
    func configure(_ item: NeedsAttentionItem,
                   theme: HelmTheme,
                   compact: Bool = false,
                   onToggle: @escaping () -> Void,
                   onOpen: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onOpen = onOpen

        let tint = item.tint
        // N1 (`fm/grandline-home-fit-implement`): the title, then one line
        // carrying the kind and the state together - "Follow-up \u{00B7}
        // Overdue 27 days \u{00B7} since 18 Sep" - with the state run in its
        // tint, and the item's own meta after it. The kicker line and the
        // trailing caption are gone: the status sits under the title instead
        // of a page-width away, and every row is the same height.
        var content = HelmAccentRow.Content(
            tint: tint,
            kicker: "",
            title: item.text,
            meta: item.meta,
            // A signal row has no checkbox in the badge slot, so the row's
            // own badge carries the tone instead - the component's
            // documented fallback, and the nearest thing it has to the
            // reference's severity dot.
            badgeSymbol: item.kind.isSignal ? Self.signalBadgeSymbol(for: item.tone) : nil)
        let state = item.chipText
        content.metaPrefix = compact ? nil : item.source
        content.metaLead = compact ? (state.components(separatedBy: " \u{00B7} ").first ?? state) : state
        content.metaLeadTint = Self.captionTint(for: item.tone)
        if compact {
            content.hint = [item.source, state, item.meta].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " \u{00B7} ")
        }
        row.configure(content, theme: theme)
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

    // MARK: Focus scrolls the row into view

    /// The card's list scrolls inside the card, so a row that takes keyboard
    /// focus below the visible part of it has to bring itself into view, or
    /// Tab would move focus somewhere the captain cannot see.
    /// `includesDescendants`, because the focusable views are the row's own
    /// card, its checkbox and its action - never this adapter.
    private var focusRegistration: HelmFocusRegistration?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusRegistration == nil, window != nil {
            focusRegistration = HelmFocusSensing.shared.register(self, includesDescendants: true) { [weak self] focused in
                guard focused, let self else { return }
                self.scrollToVisible(self.bounds)
            }
        } else if window != nil {
            HelmFocusSensing.shared.noteWindowChanged(for: self)
        }
    }

    deinit {
        if let focusRegistration { HelmFocusSensing.shared.unregister(focusRegistration) }
    }

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
    var debugActionButton: HelmButton { actionButton }
    #endif
}

// MARK: - The list's scroll view

/// The attention list's scroll view. It only differs from a plain one in
/// where a wheel event goes when the list has nothing to scroll: to the page,
/// so the page's own fallback scroll (the minimum window with Larger text)
/// still works with the pointer over this card.
final class NeedsAttentionListScrollView: NSScrollView {
    /// Whether a wheel event here belongs to the page rather than the list.
    var forwardsWheelToPage: Bool {
        (documentView?.frame.height ?? 0) <= contentView.bounds.height + 0.5
    }

    override func scrollWheel(with event: NSEvent) {
        if forwardsWheelToPage {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - "+N more"

/// The pill on the list's bottom edge while rows are clipped. The kit's
/// `HelmStatusPill` in its neutral tint, made pressable: a click, Return or
/// Space, or VoiceOver's press scrolls the list down a page.
final class NeedsAttentionMorePill: NSView {
    var onPress: (() -> Void)?
    private let pill = HelmStatusPill(style: .pill)
    private(set) var count = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        pill.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        toolTip = "Scroll the list down"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(count: Int, theme: HelmTheme) {
        self.count = count
        pill.configure(text: "+\(count) more", tint: .neutral, theme: theme)
        setAccessibilityLabel("\(count) more \(count == 1 ? "item" : "items") below")
    }

    func applyTheme(_ theme: HelmTheme) { pill.applyTheme(theme) }

    override func mouseDown(with event: NSEvent) { onPress?() }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

// MARK: - The fade under "+N more"

/// A short fade from clear to the card surface on the list's bottom edge,
/// so the "+N more" pill reads as sitting over rows that continue. Its own
/// view so the gradient follows its own bounds in `layout()`.
final class NeedsAttentionFadeView: NSView {
    private let gradient = CAGradientLayer()
    var surface: NSColor = .clear {
        didSet {
            HelmMotion.withoutImplicitAnimation {
                gradient.colors = [surface.withAlphaComponent(0).cgColor, surface.cgColor]
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(gradient)
        // Layer space is unflipped here: y = 1 is the top edge.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        HelmMotion.withoutImplicitAnimation { gradient.frame = bounds }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
