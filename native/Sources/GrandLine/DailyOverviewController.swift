// Grand Line - native macOS app.
//
// The Overview page (`RailDestination.dailyOverview`): F20's daily review, on
// a page of its own.
//
// **This is a host, not a second implementation.** Everything the page shows
// is `DailyReviewCard` rendering `DailyReviewComposer.digest(from:)` - the
// same view and the same composer F20 shipped, the same `AppSettings` gates
// (`dailyReviewEnabled`, `dailyReviewDismissedDay`) and the same
// `DailyReviewCalendarReading` seam. What this file owns is the page around
// it: a scroll view, the page gutter, the empty state for a day the captain
// dismissed, and the drill header's live subtitle.
//
// **Why it exists at all.** F20's spec said "a full-width card on Overview"
// and the implementation read that as `RailDestination.overview` - which the
// Daylight rename had already turned into the *Fleet dashboard*, while the
// landing page the captain calls Overview is `.homeCanvas` / "Home". The
// captain then asked for a genuine sixth top-level tab rather than a move, so
// this page is that tab's destination and Fleet keeps its own copy of the
// card. `data/grandline-daily-review-card-not-showing/report.md` is the scout
// investigation, and `docs/history/39-daily-review.md` carries the decision.
//
// **The duplication is deliberate and bounded**: two hosts, one card, one
// composer, one dismissal key - dismissing on either page dismisses the day on
// both, because both read `AppSettings.shared.dailyReviewDismissedDay`. If
// Fleet's copy is ever dropped, this file changes not at all.

import AppKit

final class DailyOverviewController: NSViewController {

    /// The shared `ShiftStore` (GL-23) - the same instance the Tasks page and
    /// Fleet's own copy of this card read. Never a second one: it caches as
    /// well as writes.
    private let shiftStore: ShiftStore
    private var stickyBoardStore: StickyBoardStore?
    private var readingListStore: ReadingListStore?

    /// Replaced by a stub in `DailyReviewViewSelfTest`, exactly as
    /// `FleetController.dailyReviewCalendar` is - no EventKit call, no
    /// permission prompt, and the captain's real calendar is never read by a
    /// test run.
    var dailyReviewCalendar: DailyReviewCalendarReading = EventKitDailyReviewCalendar()

    /// Navigation out of the card's own buttons, owned by the shell.
    var onNavigateToDestination: ((RailDestination) -> Void)?
    var onOpenShiftTask: ((String) -> Void)?

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()
    private let card = DailyReviewCard()
    private var emptyState: HelmEmptyState!
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// The page's own one-line summary of what it is showing - the card's
    /// headline, recomputed on every render.
    ///
    /// `fm/grandline-overview-layout-fix-gmail-settings` stopped this feeding
    /// a drill header: Overview is a **top-level** page now, so the bar keeps
    /// its wordmark and its space pills and draws no subtitle at all. It is
    /// kept because it is the honest answer to "what is this page saying
    /// right now", which the suite asserts and a later surface can read; it
    /// is deliberately not a `DaylightDrillActions` conformance any more,
    /// because that protocol is about a header this page does not have.
    private(set) var pageSummary: String?

    init(shiftStore: ShiftStore) {
        self.shiftStore = shiftStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Build

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        root.wantsLayer = true
        // AGENTS.md gotcha (8): a full-size destination's root is a plain
        // layer-backed view with a theme fill, never `NSVisualEffectView` -
        // `.behindWindow` vibrancy composites against the desktop.
        view = root

        // Gotcha (9): a plain `NSView` document view is not flipped, so short
        // content rests against the bottom of the clip view and leaves a gap
        // above the card. This page is short by construction - one card - so
        // it is exactly the shape that bug shows up on.
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        buildCard()
        emptyState = buildEmptyState()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = HelmMetrics.s5
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(card)
        contentStack.addArrangedSubview(emptyState)

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            // `fm/grandline-overview-layout-fix-gmail-settings`: the bar's own
            // side margin, not `HelmMetrics.pageGutter`.
            //
            // This page is one full-bleed card sitting immediately under the
            // Daylight bar, and the bar is a floating panel inset
            // `DaylightBarController.sideMargin` (22) from the window - so a
            // 24pt page gutter put the card's edges 2pt inside the chrome
            // directly above it. Measured in a real off-screen render at
            // 1220pt: bar 22..1198, card 24..1196. Small, and the captain saw
            // it at once, because the two edges are vertically adjacent and
            // nothing else on the page competes for the eye. Every other page
            // keeps `pageGutter`; none of them has a single element whose
            // edge lines up with the bar's.
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                                  constant: DaylightBarController.sideMargin),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                   constant: -DaylightBarController.sideMargin),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: HelmMetrics.s5),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            // The card is the page: full width inside the gutter, which is
            // what makes this read as a destination rather than as a card
            // floating in an empty page.
            card.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            emptyState.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

        // Gotcha (4): the document view pins to the **clip** view, never to
        // the scroll view - a non-overlay scroller reserves a real track.
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        // `fm/grandline-overview-layout-fix-gmail-settings` removed the
        // viewport-height minimum that used to live here.
        //
        // It was added so the card "fills the page rather than floating at
        // the top of it", and the captain's own screenshot is what that
        // actually looks like: a 317pt card stretched to 592pt, its three
        // column rules running down through ~275pt of empty background and
        // its footer parked on the bottom edge of the window - a dead zone
        // inside the card rather than under it. Measured in a real
        // off-screen render (`card.fittingSize` 454x317 against a 1172x592
        // frame) before the constraint came out.
        //
        // A card sizes to its content. What is under it is page background,
        // which is what the captain's approved mockup shows and what every
        // other short page in this app already does.

        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            // `ThemeManager.swift`'s checklist item 2: force the appearance,
            // or every system-semantic colour (scroller chrome, the focus
            // ring) follows the OS instead of the chosen theme.
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.applyTheme()
        }
    }

    private func buildCard() {
        card.onDismiss = { [weak self] in self?.dismissDailyReview() }
        card.onOpenSettings = { [weak self] in self?.onNavigateToDestination?(.settings) }
        card.onPlanDay = { [weak self] in self?.onNavigateToDestination?(.shift) }
        card.onStartTask = { [weak self] id in self?.onOpenShiftTask?(id) }
        card.onConnectCalendar = { [weak self] in self?.connectDailyReviewCalendar() }
    }

    /// What the page shows when the card has nothing to draw - the captain
    /// dismissed today's review, or turned the feature off in Settings.
    ///
    /// A dedicated page cannot do what a card in a stack does and simply
    /// vanish: an empty destination is a dead end. The two states say
    /// different things, and both offer the way back.
    private func buildEmptyState() -> HelmEmptyState {
        let settingsButton = HelmButton(title: "Daily review settings", variant: .secondary,
                                        symbol: "gearshape")
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        let state = HelmEmptyState(symbol: "sun.max",
                                   title: "Nothing to review right now",
                                   body: "Today's review is put away.",
                                   size: .standard,
                                   boxed: true,
                                   accessory: settingsButton,
                                   hue: RailDestination.dailyOverview.domainHue)
        state.translatesAutoresizingMaskIntoConstraints = false
        return state
    }

    @objc private func openSettings() { onNavigateToDestination?(.settings) }

    override func viewWillAppear() {
        super.viewWillAppear()
        // cockpit-native-fixes5: force the pending layout pass before reading
        // or setting the scroll position - on the first appearance this view's
        // constraints resolve in the same tick.
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        // Recomputed on every appearance rather than cached for the day, for
        // F20's own reason: it is an in-memory scan of stores the app already
        // holds, and a review that still said "2 due" after both were ticked
        // off would be worse than no page.
        renderDailyReview()
        // The one source that is not in memory: a connected Google account's
        // calendar. Read in the background and re-rendered only if it
        // actually changed - `events(on:)` is synchronous and on the main
        // thread, so the network half can never be in it (GL-04/GL-12).
        // Costs nothing at all when no account is connected.
        DailyReviewCalendarSources.shared.refreshGoogle(for: Date()) { [weak self] changed in
            guard changed, let self, !self.view.isHidden else { return }
            self.renderDailyReview()
        }
    }

    private func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: F20 - the daily review

    /// Hands over the two stores this controller does not own (GL-23: the
    /// shared instances, never a second copy). Called once by
    /// `AppShellController`, which builds them after this controller.
    func attachDailyReviewSources(stickyBoardStore: StickyBoardStore,
                                  readingListStore: ReadingListStore) {
        self.stickyBoardStore = stickyBoardStore
        self.readingListStore = readingListStore
    }

    /// Reads the six sources and renders.
    ///
    /// Ported from `FleetController.renderDailyReview` rather than reimplemented
    /// - same gates, same GL-14 unavailability states, same composer. The one
    /// addition is the empty state, which a page needs and a card in a stack
    /// does not.
    /// Re-render, but only if this page has ever been built.
    ///
    /// The shell calls this on an event that happened somewhere else (a
    /// Google account connecting), and a lazily-mounted page that has never
    /// been visited has no views to render into - touching `view` here would
    /// mount it, which is exactly what GL-37's laziness exists to avoid.
    func renderDailyReviewIfMounted() {
        guard isViewLoaded else { return }
        renderDailyReview()
    }

    func renderDailyReview() {
        guard AppSettings.shared.dailyReviewEnabled else {
            showEmptyState(title: "The daily review is turned off",
                           body: "Turn it back on in Settings to see your day - what is due, who you are "
                               + "waiting on, today's calendar, your board and your reading list.")
            return
        }
        let now = Date()
        guard AppSettings.shared.dailyReviewDismissedDay != MorningBriefing.dayKey(for: now) else {
            showEmptyState(title: "Dismissed for today",
                           body: "Today's review is put away. It comes back tomorrow morning, or turn it "
                               + "off for good in Settings.")
            return
        }

        var inputs = DailyReviewInputs()
        inputs.now = now

        // Tasks and follow-ups - the shared store's own in-memory lists, the
        // same ones the Tasks page is showing.
        if shiftStore.isInFailedLoadState {
            let reason = "your tasks could not be read - a file in the Tasks store failed to parse"
            inputs.tasks = .unavailable(reason)
            inputs.followUps = .unavailable(reason)
        } else {
            inputs.tasks = .available(shiftStore.activeTasks)
            inputs.followUps = .available(shiftStore.followUps)
            var names: [String: String] = [:]
            for project in shiftStore.projects { names[project.id] = project.name }
            inputs.projectNames = names
        }

        // The sticky board and the reading list. A store that was never
        // attached is a wiring mistake rather than a captain-facing state, so
        // it says so plainly rather than pretending the board is empty.
        if let store = stickyBoardStore {
            inputs.stickies = store.isInFailedLoadState
                ? .unavailable("your sticky board could not be read - its file failed to parse")
                : .available(store.activeNotes)
        } else {
            inputs.stickies = .unavailable("the sticky board is not connected to this page")
        }
        if let store = readingListStore {
            inputs.reading = store.isInFailedLoadState
                ? .unavailable("your reading list could not be read - its file failed to parse")
                : .available(store.links)
        } else {
            inputs.reading = .unavailable("the reading list is not connected to this page")
        }

        // Habits: F8 has not shipped. A stated gap, not a hidden section.
        inputs.habits = DailyReviewHabits.read()

        // The calendar. Two sources now - this Mac's own through EventKit,
        // and any connected Google account - each behind its own switch, and
        // `DailyReviewCalendarSources` owns which of them are on. Both are
        // read-only; `nil` means every source is off, which is a state rather
        // than an absence.
        if let calendar = DailyReviewCalendarSources.shared.source(local: dailyReviewCalendar) {
            inputs.calendar = calendar.events(on: now)
        } else {
            inputs.calendar = .unavailable(DisabledDailyReviewCalendar.offReason)
        }
        card.setCalendarConnectable(dailyReviewCalendarIsConnectable())

        let digest = DailyReviewComposer.digest(from: inputs)
        card.render(digest, theme: theme)
        card.isHidden = false
        emptyState.isHidden = true
        setPageSummary(digest.headline)
    }

    private func showEmptyState(title: String, body: String) {
        card.isHidden = true
        emptyState.isHidden = false
        emptyState.setText(title: title, body: body)
        emptyState.applyTheme(theme)
        setPageSummary(title)
    }

    private func setPageSummary(_ line: String) {
        guard pageSummary != line else { return }
        pageSummary = line
        onPageSummaryChanged?()
    }

    /// Set by the shell; called when this page's own summary changes.
    var onPageSummaryChanged: (() -> Void)?

    /// Whether offering "Show today's calendar" can lead anywhere - a denied
    /// or restricted grant cannot be changed from inside this app, and an
    /// unbundled build must not ask at all.
    private func dailyReviewCalendarIsConnectable() -> Bool {
        guard dailyReviewCalendar.canPrompt else { return false }
        switch dailyReviewCalendar.access {
        case .denied, .restricted, .writeOnly: return false
        case .readable: return !AppSettings.shared.dailyReviewCalendarEnabled
        case .notDetermined: return true
        }
    }

    private func connectDailyReviewCalendar() {
        dailyReviewCalendar.requestAccess { [weak self] access in
            guard let self else { return }
            switch access {
            case .readable:
                AppSettings.shared.dailyReviewCalendarEnabled = true
            case .denied, .restricted, .writeOnly, .notDetermined:
                Feedback.report("Grand Line could not read your calendar.", kind: .warning,
                                persistence: .transient, in: self.view)
            }
            self.renderDailyReview()
        }
    }

    private func dismissDailyReview() {
        AppSettings.shared.dailyReviewDismissedDay = MorningBriefing.dayKey()
        renderDailyReview()
    }

    // MARK: Theme

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        card.applyTheme(theme)
        emptyState?.applyTheme(theme)
    }

    #if FM_SELFTESTS
    /// GL-27: debug builds only. The suite drives the real page rather than
    /// the card alone, which is what proves the wiring as well as the render.
    var debugDailyReviewCard: DailyReviewCard { card }
    var debugScrollClipFrame: NSRect { scroll.contentView.frame }
    var debugDocumentFrame: NSRect { scroll.documentView?.frame ?? .zero }
    var debugContentStackFrame: NSRect { contentStack.frame }
    var debugEmptyStateIsShowing: Bool { !(emptyState?.isHidden ?? true) }
    func debugRenderDailyReview() { renderDailyReview() }
    func debugAttachDailyReviewStores(sticky: StickyBoardStore, reading: ReadingListStore) {
        attachDailyReviewSources(stickyBoardStore: sticky, readingListStore: reading)
    }
    #endif
}
