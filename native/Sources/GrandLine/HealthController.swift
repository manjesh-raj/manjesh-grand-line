// Grand Line - native macOS app.
//
// The `.health` rail destination (fm/grandline-health-sidebar-move).
//
// F1 / GL-11 originally shipped the "Health" card as the last card on the
// Settings page - a diagnostic surface a captain had to scroll past
// Connection/Appearance/Terminal/Security/Backup to reach. The captain's own
// correction, the same move F11's Schedules card already got
// (`fm/grandline-schedules-sidebar-move`): a surface worth checking on
// directly should not need a scroll-within-Settings step. This gives Health
// its own rail icon, directly visible in the sidebar, with no scroll or
// flyout step.
//
// This is a presentation-layer move, not a rewrite: `HealthCardView`,
// `ServiceHealthRegistry`, and `PersistenceFailureReporter` are all
// untouched. Settings' own Connection/Appearance/Terminal/Security/Backup
// cards are unaffected and stay exactly where they were.
//
// Placement: the utility group (`RailDestination.isDailyUse == false`),
// alongside Tools/Vault/Dictation/Schedules/Docs - Health "runs itself and
// reports" (every background service reports its own outcome to it) rather
// than something a captain checks in on daily, the same criterion that
// already keeps Schedules/Vault/Docs/Tools out of the daily-use `navStack`
// group.
//
// In the sidebar layout the page is the prototype's (stage 6): one table of
// services, Copy diagnostics at the toolbar's far right and Refresh beside the
// toolbar's other actions - see `HealthCardView`'s header. The floating bar's
// page is unchanged.
//
// H-4 (the page-redesign board, the captain's pick) made that page a
// `HelmSplitPage`: the hero column - the verdict, the ring and the four
// buckets, red while something fails - is the split's sidebar, and the table
// scrolls beside it, starting at the top of the page. On a page too narrow
// for both (`heroCollapseWidth`), or when the captain hides the column with
// Toggle Sidebar, the same column moves across the top of the table as a band,
// so the verdict never leaves the screen.

import AppKit

final class HealthController: NSViewController, DaylightDrillActions, HelmSplitPageHosting {

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var scrollView: NSScrollView!

    /// The card itself - see `HealthCardView`'s own header for why it is a
    /// self-contained view (owning rendering, deciding nothing) rather than
    /// business logic that belongs on this controller.
    private let healthCard = HealthCardView()

    /// Set by `AppShellController` - "re-read my subtitle". The header is the
    /// shell's; this page only says when its numbers moved.
    var onDrillSubtitleChanged: (() -> Void)?

    /// Where this page hands a destination change up - the same shape
    /// `FleetController.onNavigateToDestination` already uses. UI12.
    var onNavigateToDestination: ((RailDestination) -> Void)?

    // MARK: Drill header (Daylight §6.4)

    /// §7's "drill header with a live subtitle". Counted from the same
    /// `ServiceHealthSummary` the rows below and Home's Health card render
    /// (R5-BUG-02), so they can never disagree - and honest about the launch
    /// case, where nothing has reported yet.
    var drillHeaderSubtitle: String? {
        let counts = ServiceHealthRegistry.shared.summary()
        guard counts.total > 0 else { return "No background service has reported yet" }
        let services = counts.total == 1 ? "1 service" : "\(counts.total) services"
        if counts.failing > 0 { return "\(services) \u{00B7} \(counts.failing) failing" }
        if counts.degraded > 0 { return "\(services) \u{00B7} \(counts.degraded) with a recent failure" }
        if counts.healthy == counts.total { return "\(services) \u{00B7} all healthy" }
        return "\(services) \u{00B7} \(counts.healthy) healthy"
    }

    /// §7 hoists "Copy diagnostics" into the header - it is this page's one
    /// action, and it applies to the whole card rather than to any one row.
    /// Caller-owned: `HealthCardView` still owns the button and its handler.
    var drillHeaderActions: [NSView] {
        [refreshButton, healthCard.diagnosticsButton]
    }

    /// The services Retry can run again, by service - see
    /// `HealthCardView.retryActions`. Set by the workspace.
    var retryActions: [HealthService: () -> Void] {
        get { healthCard.retryActions }
        set { healthCard.retryActions = newValue }
    }

    /// H-4: the column beside the table.
    private(set) var splitPage: HelmSplitPage?
    private var stack: NSStackView?
    /// S03: the page frame.
    private var scaffold: HelmPageScaffold?

    /// Read every service's latest report again and redraw - the rows'
    /// relative times ("13 minutes ago") are written once per render. It runs
    /// nothing: a service is re-run only by its own Retry.
    ///
    /// R2-UI-02: the app's one Refresh (`HelmButton.refresh()`), labelled, as
    /// on Review, Automic Vault, Schedules and Dictation - it was a bare glyph
    /// here, the one Refresh in the toolbar a captain had to recognise.
    private lazy var refreshButton: HelmButton = {
        let button = HelmButton.refresh()
        button.target = self
        button.action = #selector(refreshTapped)
        button.toolTip = "Read every service's latest report again"
        return button
    }()

    @objc private func refreshTapped() {
        healthCard.refresh(theme: theme)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 720))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            // P2: a hidden page repainting eagerly is pure waste - it would
            // rebuild again on its next appearance anyway - and with every
            // destination mounted for the session (GL-37) that waste is what
            // made ⌘⌥T stall the main thread for ~0.7-1.0s. Deferred to
            // `viewWillAppear` when this page is not the one showing.
            self?.refreshCardIfVisible()
        }

        // D5: the page used to carry its own subtitle restating what the top
        // bar and the card header already say ("Health", "last run and last
        // error"), three times on one screen. The card is the page.
        //
        // S03: the page frame - scroll, flipped document, gutter and the
        // first-content line - is `HelmPageScaffold`'s.
        let scaffold = HelmPageScaffold(spacing: 14)
        scaffold.install(in: root)
        scaffold.addContent(healthCard.card)
        self.stack = scaffold.stack
        self.scaffold = scaffold
        scrollView = scaffold.scrollView

        healthCard.refresh(theme: theme)
        // The card rebuilds itself on every `ServiceHealthRegistry` report;
        // the header's own subtitle has to follow the same signal.
        healthCard.onStateChanged = { [weak self] in self?.onDrillSubtitleChanged?() }
        // UI12: the empty state's "Open Schedules" call-to-action. Forwarded
        // rather than handled - this page knows no more about navigation than
        // Fleet's or Schedules' own `onNavigateToDestination` does.
        healthCard.onOpenDestination = { [weak self] dest in self?.onNavigateToDestination?(dest) }

        // P-03 of the 2026-11-25 review: the sidebar is the only layout, so
        // the page builds its sidebar presentation as part of loading.
        buildSidebarPresentation()
    }

    private let scrollMemory = HelmScrollMemory()

    override func viewWillDisappear() {
        super.viewWillDisappear()
        scrollMemory.remember(scrollView)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // P3: only when it would change what is on screen - see
        // `HealthCardView.refreshIfNeeded(theme:)`.
        healthCard.refreshIfNeeded(theme: theme)
        // P3: keep the captain's place unless the page changed (`HelmScrollMemory`).
        scrollMemory.restore(scrollView) { scrollToTop() }
    }

    /// P2: the theme observer's rebuild, skipped while this page is not the
    /// one showing. `refreshIfNeeded` on the next appearance catches it,
    /// because the theme it renders against will differ from the one the card
    /// last rendered.
    private func refreshCardIfVisible() {
        guard isViewLoaded, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        healthCard.refresh(theme: theme)
    }

    /// The card's wrapping description labels wrap at a width derived from the
    /// card's own - which is only known once a layout pass has run (D6's
    /// other half: the hardcoded 360pt cap that left the right half of a wide
    /// window empty).
    override func viewDidLayout() {
        super.viewDidLayout()
        healthCard.layoutDidChange()
    }

    private func scrollToTop() {
        scaffold?.scrollToTop()
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugHealthCard: HealthCardView { healthCard }
    /// The width rule has finished: the pane is open exactly when the split
    /// wants it, and the column is drawn as a column there or a band over
    /// the table otherwise. Both moves wait a run-loop turn
    /// (`HelmSplitPage.evaluateWidth`), so a check reading the table's
    /// columns waits for this first.
    var debugHeroColumnIsArranged: Bool {
        guard let split = splitPage else { return true }
        let open = !split.isSidebarCollapsed
        return open == split.sidebarIsWanted
            && healthCard.heroColumn.arrangement == (open ? .column : .band)
    }
    var debugScaffold: HelmPageScaffold? { scaffold }
    func debugRefresh() { refreshTapped() }
    var debugRefreshButton: HelmButton { refreshButton }
    #endif

    #if FM_SELFTESTS
    var debugHealthRowCount: Int { healthCard.debugRowCount }
    var debugCardWidth: CGFloat { healthCard.card.bounds.width }
    var debugSummaryValues: [String] { healthCard.debugSummaryValues }
    /// Forces the *legacy* (non-overlay) scroller style regardless of this
    /// machine's real mouse/trackpad state, so a self-test can reproduce "a
    /// mouse is attached" (this app's own documented "Show scroll bars:
    /// Always" scenario - see AGENTS.md gotcha #4) even when run headless,
    /// where `NSScroller.preferredScrollerStyle` would otherwise default to
    /// `.overlay` with no real pointing device present.
    func debugForceLegacyScrollerStyle() { scrollView.scrollerStyle = .legacy }
    #endif
}

// MARK: - The sidebar layout

extension HealthController: WorkspacePrimaryActionProviding {

    func buildSidebarPresentation() {
        let table = healthCard.adoptTableLayout()
        stack?.addArrangedSubview(table)
        if let stack { table.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        adoptHeroColumn()
        // The shell reads the page's actions right after this, on the same
        // first show, so the toolbar picks up Refresh and the primary action.
        healthCard.refresh(theme: theme)
    }

    /// Below this page width the column gives way to the band: the column,
    /// the gutters either side of the table, and the table at the width that
    /// still shows every column. The board accepted a narrower table that
    /// truncates its descriptions sooner, not one that loses Recent runs -
    /// measured, a fixed 880 left a 639pt table with no runs column at a
    /// 1277pt window (`ReviewTwoA11yPerfSelfTest`).
    static let heroCollapseWidth: CGFloat = HelmMetrics.pageGutter + HelmHeroColumn.width
        + HelmSplitPage.dividerThickness + 2 * HelmMetrics.pageGutter + HealthCardView.allColumnsWidth

    /// H-4: the page becomes a split, with the hero column as its sidebar
    /// and the scrolling table as its content.
    private func adoptHeroColumn() {
        guard let scaffold else { return }
        let paneWidth = HelmMetrics.pageGutter + HelmHeroColumn.width
        // A column of one width that yields to the table's floor, so the
        // window never grows for it (`HelmSplitPage` 1.2.0).
        let split = HelmSplitPage(sidebarWidth: paneWidth, minimum: HelmSplitPage.yieldingMinimumThickness,
                                  maximum: paneWidth, surface: .pageGround)
        addChild(split)
        view.addSubview(split.view, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: view.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // The scrolling table moves into the content pane, so the column
        // stays put while the list scrolls.
        scaffold.removeFromSuperview()
        HelmSplitPage.pin(scaffold, in: split.contentPane, insets: NSEdgeInsets())
        placeHeroColumn(asBand: false, in: split)
        split.collapsesBelowWidth = Self.heroCollapseWidth
        split.preferredSidebarWidth = paneWidth
        // The width rule moves the column in the same turn as it collapses
        // the pane, so the table has its full width on the very next layout:
        // a second turn left a slow CI runner reading a table still 639pt
        // wide, with Recent runs hidden (`ReviewTwoA11yPerfSelfTest`).
        split.onNarrowChanged = { [weak self, weak split] _ in
            guard let self, let split else { return }
            self.placeHeroColumn(asBand: !split.sidebarIsWanted, in: split)
        }
        split.onSidebarCollapseChanged = { [weak self, weak split] collapsed in
            // The collapse is reported from inside the split's own resize;
            // moving a view between panes waits a turn.
            DispatchQueue.main.async {
                guard let self, let split else { return }
                self.placeHeroColumn(asBand: collapsed, in: split)
            }
        }
        splitPage = split
    }

    /// The column in the split's sidebar pane, or across the top of the
    /// table as a band while the pane is put away.
    private func placeHeroColumn(asBand: Bool, in split: HelmSplitPage) {
        guard let scaffold else { return }
        let column = healthCard.heroColumn
        let alreadyThere = asBand ? column.superview === scaffold : column.superview === split.sidebarPane
        guard !alreadyThere else { return }
        if column.superview === scaffold { scaffold.setTopSlot(nil) }
        column.removeFromSuperview()
        column.setArrangement(asBand ? .band : .column)
        if asBand {
            scaffold.setTopSlot(column)
        } else {
            HelmSplitPage.pin(column, in: split.sidebarPane,
                              insets: NSEdgeInsets(top: HelmMetrics.pageContentInset, left: HelmMetrics.pageGutter,
                                                   bottom: HelmMetrics.pageGutter, right: 0),
                              yieldsWidth: true)
        }
    }

    /// Copy diagnostics, at the toolbar's far right.
    var workspacePrimaryAction: NSView? { healthCard.diagnosticsButton }
}
