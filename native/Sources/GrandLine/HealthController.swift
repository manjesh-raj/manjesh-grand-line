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
// In the sidebar layout the page is the prototype's (stage 6): summary cards
// over one table of services, Copy diagnostics at the toolbar's far right and
// Refresh beside the toolbar's other actions - see `HealthCardView`'s header.
// The floating bar's page is unchanged.

import AppKit

final class HealthController: NSViewController, DaylightDrillActions {

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
    /// `ServiceHealthRegistry` state the rows below render, so the two can
    /// never disagree - and honest about the launch case, where nothing has
    /// reported yet.
    var drillHeaderSubtitle: String? {
        let counts = HealthCardView.verdictCounts()
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
        drawsSidebarLayout ? [refreshButton, healthCard.diagnosticsButton] : [healthCard.diagnosticsButton]
    }

    /// The services Retry can run again, by service - see
    /// `HealthCardView.retryActions`. Set by the workspace.
    var retryActions: [HealthService: () -> Void] {
        get { healthCard.retryActions }
        set { healthCard.retryActions = newValue }
    }

    /// Set once, by `adoptSidebarLayout()`.
    private(set) var drawsSidebarLayout = false
    private var stack: NSStackView?

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
        let stack = NSStackView(views: [healthCard.card])
        self.stack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            healthCard.card.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let scroll = NSScrollView()
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
            // AGENTS.md gotcha #4: pin the document view to the *clip* view,
            // never the outer scroll view - see `SchedulesController`'s
            // identical comment for the full reasoning.
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scrollView = scroll

        healthCard.refresh(theme: theme)
        // The card rebuilds itself on every `ServiceHealthRegistry` report;
        // the header's own subtitle has to follow the same signal.
        healthCard.onStateChanged = { [weak self] in self?.onDrillSubtitleChanged?() }
        // UI12: the empty state's "Open Schedules" call-to-action. Forwarded
        // rather than handled - this page knows no more about navigation than
        // Fleet's or Schedules' own `onNavigateToDestination` does.
        healthCard.onOpenDestination = { [weak self] dest in self?.onNavigateToDestination?(dest) }
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
        guard let scroll = scrollView else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugHealthCard: HealthCardView { healthCard }
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

extension HealthController: SidebarLayoutAdopting, WorkspacePrimaryActionProviding {

    func adoptSidebarLayout() {
        guard !drawsSidebarLayout else { return }
        _ = view
        drawsSidebarLayout = true
        let table = healthCard.adoptTableLayout()
        stack?.addArrangedSubview(table)
        if let stack { table.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        // The shell reads the page's actions right after this, on the same
        // first show, so the toolbar picks up Refresh and the primary action.
        healthCard.refresh(theme: theme)
    }

    /// Copy diagnostics, at the toolbar's far right.
    var workspacePrimaryAction: NSView? { drawsSidebarLayout ? healthCard.diagnosticsButton : nil }
}
