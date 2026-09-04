// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-k8s-cluster-tail`: the `.kubernetes` destination - items 1
// and 5 of the captain-approved scout report
// (`data/grandline-k8s-toolkit-scout/report.md`), the multi-pod Log Tail
// (stern-equivalent) and the read-only Cluster browser (k9s-equivalent),
// living on one standalone page.
//
// **The shape was decided by the report, not here.** Its "second dimension"
// section works the question through in full and lands on **Shape C, the
// hybrid**: the moment the Cluster browser is promoted, one standalone
// `.kubernetes` destination owns the big screens (its own value proposition
// is "one dedicated screen for cluster state", not "a toggle on my
// terminal"), the host page keeps its ambient context badge (an anchor has to
// live in the chrome of the terminal being typed into), and the host page's
// "Tail Logs" button becomes a **pre-scoped deep link** into this page - the
// same idiom Overview's ready-to-merge tile already uses to reach Review.
// That deep link is `AppShellController.openKubernetes(hostID:tab:)`.
//
// **Standalone-but-host-scoped, and the report is blunt that pretending
// otherwise would be dishonest.** The bridge types commands into one
// specific host's already-authenticated terminal session, and that session is
// the only cluster credential that exists anywhere (five prior attempts,
// PRs #70-73, proved a second automated connection can never complete the
// password-gated hop - see `sre_kubectl_mcp.py`'s own header). So a standalone
// page is a different *front door*, never a different *transport*: it must
// answer "which authenticated session am I driving?" before it can show a
// single pod. Hence the scope strip, read from `HostSessionRegistry` - this
// app's one answer to "which hosts are live" - and an honest wall when
// nothing is live, rather than an empty table that looks like an empty
// cluster.
//
// **The feed tab is explicit and visible, never a silent background tab.**
// The bridge is single-flight and refuses while the captain is typing, so
// polling their working tab would both spam it and stall constantly. The
// report's accepted cost is a dedicated tab: duplicate the host's tab,
// complete the one manual hop-2 login by hand, pin it as the feed. This page
// makes that a step the captain takes and can see - a tab picker plus a
// "Duplicate a tab for the feed" button - rather than something that happens
// behind them. `KubeBridge` then owns everything after that, including the
// backoff/give-up that `fm/grandline-k8s-badge-fixes` had to add to the
// context badge after a real tab with no `kubectl` got hammered forever.
//
// **Read-only, permanently.** Every command goes through `KubeCommand`'s
// closed enum: `get`, `top`, `events`, `describe`, `logs`, all already
// allowed by `sre_kubectl_mcp.py`'s `_ALLOWED_VERBS`, so this task widens no
// allowlist at all. There is no exec, no edit, no delete, no scale, and there
// must never be one here even as a convenience - a mutating action belongs in
// the Command Library, behind the risk gate it already has.

import AppKit

/// One of the target host's terminal tabs, as much of it as this page needs.
///
/// Deliberately not a `TabModel`: this page never touches a terminal
/// directly, it only hands one to `KubeBridge`. The same reasoning
/// `HostSession` uses for not being a reference to a `ConsoleController`.
struct KubeFeedTab {
    let id: UUID
    let name: String
    let terminal: SRELeadBridgeTerminal
}

/// Everything this page needs from the app shell, as closures.
///
/// Forward-don't-own (`AppShellController.onPresentHostEditor`'s convention):
/// this controller knows nothing about `hostConsoles`, `ConsoleController` or
/// how a host's argv is built, and the shell knows nothing about pods.
struct KubeSessionAccess {
    /// The named host's currently open tabs, in tab-strip order.
    var tabs: (UUID) -> [KubeFeedTab] = { _ in [] }
    /// Duplicate that host's current tab and hand back the new one, already
    /// renamed as a feed. `nil` when the host has no page or no tab to
    /// duplicate.
    var duplicateTabForFeed: (UUID) -> KubeFeedTab? = { _ in nil }
    /// Whether a sibling bridge (SRE Lead's, or the context badge's) is
    /// mid-command on that tab - `KubeBridge.isTerminalBusyElsewhere`'s seam.
    var isTabBusyElsewhere: (UUID, UUID) -> Bool = { _, _ in false }
    /// Bring that host's own console page forward, so the captain can do the
    /// one manual hop-2 login.
    var revealHost: (UUID) -> Void = { _ in }
    /// Open the Hosts destination - the empty state's one action.
    var openHosts: () -> Void = {}
}

final class KubernetesController: NSViewController, DaylightDrillActions {

    // MARK: Injected

    let sessions: HostSessionRegistry
    var access: KubeSessionAccess

    /// Set by `AppShellController` after construction, for the same reason
    /// every other page's is: the shell owns the closures, and wiring them at
    /// `init` would mean the shell existing before its own children.
    func configure(access: KubeSessionAccess) { self.access = access }

    init(sessions: HostSessionRegistry, access: KubeSessionAccess = KubeSessionAccess()) {
        self.sessions = sessions
        self.access = access
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let sessionsToken { sessions.unobserve(sessionsToken) }
        clusterTimer?.invalidate()
        tailTimer?.invalidate()
    }

    // MARK: State

    enum PageTab: String { case cluster, logTail }
    enum ClusterTab: String { case pods, deployments, services, events }

    var theme: HelmTheme = ThemeManager.shared.theme
    var themeToken: ThemeObservation?
    var sessionsToken: UUID?

    var scopeHostID: UUID?
    var pageTab: PageTab = .cluster
    var clusterTab: ClusterTab = .pods

    /// The bridge for the current scope's feed tab. Torn down and rebuilt
    /// whenever the scope or the feed tab changes - never re-aimed, so a
    /// `describe` queued against one cluster can't be answered by another
    /// (`KubeBridge.retarget`'s own rule).
    var bridge: KubeBridge?
    var feedTabID: UUID?
    var feedTabName: String?

    var namespace = "default"

    var pods: [KubePod] = []
    var deployments: [KubeDeployment] = []
    var services: [KubeService] = []
    var events: [KubeEvent] = []
    var clusterMessage: String?
    var lastRefreshedAt: Date?
    var isRefreshingCluster = false

    let merger = KubeLogMerger()
    var selectedPods: [String] = []
    var isTailPaused = false
    var errorsOnly = false
    var tailStatus: String?

    var clusterTimer: Timer?
    var tailTimer: Timer?

    /// The Cluster browser polls only while it is genuinely on screen. A
    /// gentle 30s cadence (the scout mockup's own number) rather than the
    /// tail's 5s: cluster state is checked, not watched, and every poll costs
    /// three visible commands in the feed tab.
    static let clusterPollInterval: TimeInterval = 30

    // MARK: Views

    var root: NSView!
    var scopeCard: HelmCard!
    var scopeTabsHost: NSView!
    var scopeTabs: HelmSegmentedTabs?
    var scopeEmptyState: HelmEmptyState!
    var feedCard: HelmCard!
    var feedTabPicker: HelmPopUpButton!
    var feedStatusLabel: NSTextField!
    var retryFeedButton: HelmButton!
    var workArea: NSView!
    var pageTabs: HelmSegmentedTabs!
    var clusterContainer: NSView!
    var tailContainer: NSView!

    var namespaceField: HelmTextField!
    var clusterTabs: HelmSegmentedTabs!
    var clusterTable: KubeResourceTableView!
    var clusterStatusLabel: NSTextField!
    var describeDrawer: NSView!
    var describeTitleLabel: NSTextField!
    var describeTextView: NSTextView!
    var describeScroll: NSScrollView!

    var podPickerStack: NSStackView!
    var podPickerScroll: NSScrollView!
    var logList: KubeLogListView!
    var tailStatusLabel: NSTextField!
    var pauseButton: HelmButton!
    var errorsOnlyButton: HelmButton!

    let refreshButton = HelmButton(title: "Refresh", variant: .quiet, symbol: "arrow.clockwise")

    var onDrillSubtitleChanged: (() -> Void)?

    // MARK: Drill header

    var drillHeaderActions: [NSView] { [refreshButton] }

    /// Live numbers off the state this page already renders - never a fresh
    /// read, so the header and the body can never disagree.
    var drillHeaderSubtitle: String? {
        guard let scopeHostID, let session = sessions.session(for: scopeHostID) else {
            return sessions.isEmpty ? "No live host session" : "Pick a bastion to scope to"
        }
        guard feedTabID != nil else { return "\(session.label) \u{00B7} no feed tab yet" }
        if bridge?.hasStoppedRetrying == true { return "\(session.label) \u{00B7} feed unavailable" }
        var parts = ["\(session.label) \u{00B7} ns \(namespace)"]
        if pageTab == .cluster {
            if !pods.isEmpty {
                let unhealthy = pods.filter { $0.health != .healthy }.count
                parts.append(unhealthy > 0 ? "\(pods.count) pods, \(unhealthy) need a look" : "\(pods.count) pods, all healthy")
            }
        } else if !selectedPods.isEmpty {
            parts.append(isTailPaused ? "tail paused" : "tailing \(selectedPods.count)")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 720))
        container.wantsLayer = true
        root = container
        view = container

        buildScopeCard()
        buildFeedCard()
        buildWorkArea()

        let stack = NSStackView(views: [scopeCard, feedCard, workArea])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s4
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: HelmMetrics.s4),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -HelmMetrics.s4),
            scopeCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            workArea.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)

        themeToken = ThemeManager.shared.observe { [weak self] theme in
            self?.applyTheme(theme)
        }
        sessionsToken = sessions.observe { [weak self] _ in
            self?.sessionsChanged()
        }
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // A scope may have gone live (or away) while this page was hidden.
        sessionsChanged()
        restartTimers()
        if feedTabID != nil, pageTab == .cluster, pods.isEmpty, clusterMessage == nil {
            refreshCluster()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // Every poll types a visible command into the captain's own bastion
        // session, so a page nobody is looking at must not keep doing it.
        // GL-13's own rule applied to a much louder kind of background work.
        clusterTimer?.invalidate(); clusterTimer = nil
        tailTimer?.invalidate(); tailTimer = nil
    }

    // MARK: Build

    func buildScopeCard() {
        scopeCard = HelmCard()
        scopeTabsHost = NSView()
        scopeTabsHost.translatesAutoresizingMaskIntoConstraints = false
        scopeEmptyState = HelmEmptyState(
            symbol: "bolt.horizontal.circle",
            title: "No live host session",
            body: "Every kubectl command runs inside a bastion session you have already logged into - that session is the only cluster credential there is. Connect a host first and come back.",
            size: .standard,
            boxed: false,
            accessory: {
                let button = HelmButton(title: "Open Hosts", variant: .secondary)
                button.target = self
                button.action = #selector(openHostsTapped)
                return button
            }(),
            hue: RailDestination.hosts.domainHue)
        scopeEmptyState.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [scopeTabsHost, scopeEmptyState])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s3
        body.translatesAutoresizingMaskIntoConstraints = false
        _ = scopeCard.setHeader(symbol: "point.3.connected.trianglepath.dotted",
                                tint: .info,
                                title: "Scope",
                                subtitle: "Which authenticated bastion session these commands run in.")
        scopeCard.setBody(body, insets: HelmCard.contentInsets)
        NSLayoutConstraint.activate([
            scopeTabsHost.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scopeEmptyState.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
    }

    func buildFeedCard() {
        feedCard = HelmCard()
        feedTabPicker = HelmPopUpButton()
        feedTabPicker.target = self
        feedTabPicker.action = #selector(feedTabPicked)

        let duplicate = HelmButton(title: "Duplicate a tab for the feed", variant: .secondary, size: .small)
        duplicate.target = self
        duplicate.action = #selector(duplicateFeedTapped)

        let openHost = HelmButton(title: "Open the host page", variant: .quiet, size: .small)
        openHost.target = self
        openHost.action = #selector(revealHostTapped)

        // The one way back in once `KubeBridge` has given up (see its own
        // header): giving up is never a dead end, only a pause until asked to
        // try again. Hidden while the feed is working - a retry button beside
        // a healthy feed invites a pointless extra command in the captain's
        // own tab.
        retryFeedButton = HelmButton(title: "Try again", variant: .primary, size: .small)
        retryFeedButton.target = self
        retryFeedButton.action = #selector(retryFeedTapped)
        retryFeedButton.isHidden = true

        feedStatusLabel = NSTextField(wrappingLabelWithString: "")
        feedStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [feedTabPicker, duplicate, openHost, retryFeedButton!])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = HelmMetrics.s2
        controls.distribution = .fill
        // Gotcha (12): the *stack*-level priorities are the ones that bite on
        // an `NSStackView`; the content-level ones are a no-op on a view with
        // no intrinsic size. The picker is what yields.
        controls.setHuggingPriority(.required, for: .horizontal)
        for control in [duplicate, openHost, retryFeedButton!] {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        feedTabPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let body = NSStackView(views: [feedStatusLabel, controls])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s3
        body.translatesAutoresizingMaskIntoConstraints = false
        // `fm/grandline-k8s-feed-tab-stall-fix`: the second sentence is the
        // one that matters - a captain checking on this tab by typing into it
        // directly is exactly what pauses every automated command until it
        // goes quiet again (`KubeBridge`'s own activity-quiet-window check).
        // Stated up front rather than discovered by confusion.
        _ = feedCard.setHeader(symbol: "dot.radiowaves.left.and.right",
                               tint: .warn,
                               title: "Feed tab",
                               subtitle: "A dedicated tab this page types into, so your working terminal stays clean. "
                                   + "Typing into it yourself pauses automated commands until it goes quiet again.")
        feedCard.setBody(body, insets: HelmCard.contentInsets)
        feedStatusLabel.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    func buildWorkArea() {
        workArea = NSView()
        workArea.translatesAutoresizingMaskIntoConstraints = false

        pageTabs = HelmSegmentedTabs(items: [
            .init(id: PageTab.cluster.rawValue, title: "Cluster"),
            .init(id: PageTab.logTail.rawValue, title: "Log Tail"),
        ], selected: PageTab.cluster.rawValue)
        pageTabs.onSelect = { [weak self] id in
            guard let self, let tab = PageTab(rawValue: id) else { return }
            self.pageTab = tab
            self.restartTimers()
            self.render()
            if tab == .cluster, self.pods.isEmpty, self.clusterMessage == nil { self.refreshCluster() }
        }

        namespaceField = HelmTextField(placeholder: "namespace")
        namespaceField.stringValue = namespace
        namespaceField.target = self
        namespaceField.action = #selector(namespaceCommitted)
        namespaceField.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let nsLabel = NSTextField(labelWithString: "Namespace")
        nsLabel.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [pageTabs, nsLabel, namespaceField])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = HelmMetrics.s3
        topRow.distribution = .fill
        topRow.setHuggingPriority(.required, for: .horizontal)
        topRow.translatesAutoresizingMaskIntoConstraints = false

        buildClusterContainer()
        buildTailContainer()

        for child in [topRow, clusterContainer!, tailContainer!] { workArea.addSubview(child) }
        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: workArea.leadingAnchor),
            topRow.topAnchor.constraint(equalTo: workArea.topAnchor),
            topRow.trailingAnchor.constraint(lessThanOrEqualTo: workArea.trailingAnchor),
        ])
        for child in [clusterContainer!, tailContainer!] {
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: workArea.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: workArea.trailingAnchor),
                child.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: HelmMetrics.s3),
                child.bottomAnchor.constraint(equalTo: workArea.bottomAnchor),
            ])
        }
        // A page with no feed yet still needs a sensible minimum so the cards
        // above it do not stretch to fill the window. 499, never required:
        // a content constraint above `NSLayoutPriorityWindowSizeStayPut` (500)
        // is a window-size cap, which is AGENTS.md gotcha (13) and has shipped
        // here four times.
        let minHeight = workArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
        minHeight.priority = NSLayoutConstraint.Priority(499)
        minHeight.isActive = true
    }

    func buildClusterContainer() {
        clusterContainer = NSView()
        clusterContainer.translatesAutoresizingMaskIntoConstraints = false

        clusterTabs = HelmSegmentedTabs(items: [
            .init(id: ClusterTab.pods.rawValue, title: "Pods"),
            .init(id: ClusterTab.deployments.rawValue, title: "Deployments"),
            .init(id: ClusterTab.services.rawValue, title: "Services"),
            .init(id: ClusterTab.events.rawValue, title: "Events"),
        ], selected: ClusterTab.pods.rawValue, size: .compact)
        clusterTabs.onSelect = { [weak self] id in
            guard let self, let tab = ClusterTab(rawValue: id) else { return }
            self.clusterTab = tab
            self.hideDescribeDrawer()
            self.renderClusterTable()
            self.onDrillSubtitleChanged?()
            // Services and Events are fetched only when their tab is opened
            // (the mockup's own "each costs one more get, run only when that
            // tab is opened") - a sweep that always fetched all five would
            // double the visible commands for tables nobody is looking at.
            if (tab == .services && self.services.isEmpty) || (tab == .events && self.events.isEmpty) {
                self.refreshCluster()
            }
        }

        clusterStatusLabel = NSTextField(labelWithString: "")
        clusterStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        clusterTable = KubeResourceTableView()
        buildDescribeDrawer()

        let header = NSStackView(views: [clusterTabs, clusterStatusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = HelmMetrics.s3
        header.translatesAutoresizingMaskIntoConstraints = false
        clusterStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for child in [header, clusterTable!, describeDrawer!] { clusterContainer.addSubview(child) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: clusterContainer.leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: clusterContainer.trailingAnchor),
            header.topAnchor.constraint(equalTo: clusterContainer.topAnchor),

            clusterTable.leadingAnchor.constraint(equalTo: clusterContainer.leadingAnchor),
            clusterTable.trailingAnchor.constraint(equalTo: clusterContainer.trailingAnchor),
            clusterTable.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s3),

            describeDrawer.leadingAnchor.constraint(equalTo: clusterContainer.leadingAnchor),
            describeDrawer.trailingAnchor.constraint(equalTo: clusterContainer.trailingAnchor),
            describeDrawer.topAnchor.constraint(equalTo: clusterTable.bottomAnchor, constant: HelmMetrics.s3),
            describeDrawer.bottomAnchor.constraint(equalTo: clusterContainer.bottomAnchor),
        ])
        clusterTable.setContentHuggingPriority(.defaultLow, for: .vertical)

        clusterTable.onSelectRow = { [weak self] key in
            guard let self, self.clusterTab == .pods else { return }
            self.describePod(key)
        }
    }

    func buildDescribeDrawer() {
        describeDrawer = NSView()
        describeDrawer.translatesAutoresizingMaskIntoConstraints = false
        describeDrawer.wantsLayer = true

        describeTitleLabel = NSTextField(labelWithString: "")
        describeTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let close = HelmButton(title: "Close", variant: .quiet, size: .small)
        close.target = self
        close.action = #selector(closeDescribeTapped)
        close.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [describeTitleLabel, NSView(), close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = HelmMetrics.s2
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false
        describeTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        describeTextView = NSTextView()
        describeTextView.isEditable = false
        describeTextView.isSelectable = true
        describeTextView.drawsBackground = false
        describeTextView.textContainerInset = NSSize(width: 8, height: 8)
        describeTextView.isHorizontallyResizable = true
        describeTextView.textContainer?.widthTracksTextView = false
        describeTextView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                               height: CGFloat.greatestFiniteMagnitude)
        describeScroll = NSScrollView()
        describeScroll.documentView = describeTextView
        describeScroll.hasVerticalScroller = true
        describeScroll.hasHorizontalScroller = true
        describeScroll.autohidesScrollers = true
        describeScroll.drawsBackground = true
        describeScroll.borderType = .noBorder
        describeScroll.translatesAutoresizingMaskIntoConstraints = false
        // Phase 0's D4, and `HelmContrastSelfTest.checkEveryTextViewIsThemed`
        // is a *per-file* source guard: an owned `NSTextView` paints its own
        // selection, so it must reach `HelmSelection` in the same file that
        // creates it. `applyDescribeTheme()` re-applies on every theme change
        // (a field editor's selection attributes do not survive one on their
        // own); this seeds it before the first render.
        HelmSelection.apply(to: describeTextView, theme: theme)

        describeDrawer.addSubview(header)
        describeDrawer.addSubview(describeScroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: describeDrawer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: describeDrawer.trailingAnchor),
            header.topAnchor.constraint(equalTo: describeDrawer.topAnchor),
            describeScroll.leadingAnchor.constraint(equalTo: describeDrawer.leadingAnchor),
            describeScroll.trailingAnchor.constraint(equalTo: describeDrawer.trailingAnchor),
            describeScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s2),
            describeScroll.bottomAnchor.constraint(equalTo: describeDrawer.bottomAnchor),
            describeScroll.heightAnchor.constraint(equalToConstant: 220),
        ])
        describeDrawer.isHidden = true
    }

    func buildTailContainer() {
        tailContainer = NSView()
        tailContainer.translatesAutoresizingMaskIntoConstraints = false

        podPickerStack = NSStackView()
        podPickerStack.orientation = .vertical
        podPickerStack.alignment = .leading
        podPickerStack.spacing = 2
        podPickerStack.translatesAutoresizingMaskIntoConstraints = false

        let pickerDoc = FlippedView()
        pickerDoc.translatesAutoresizingMaskIntoConstraints = false
        pickerDoc.addSubview(podPickerStack)
        NSLayoutConstraint.activate([
            podPickerStack.leadingAnchor.constraint(equalTo: pickerDoc.leadingAnchor, constant: 6),
            podPickerStack.trailingAnchor.constraint(equalTo: pickerDoc.trailingAnchor, constant: -6),
            podPickerStack.topAnchor.constraint(equalTo: pickerDoc.topAnchor, constant: 6),
            podPickerStack.bottomAnchor.constraint(lessThanOrEqualTo: pickerDoc.bottomAnchor, constant: -6),
        ])
        podPickerScroll = NSScrollView()
        podPickerScroll.documentView = pickerDoc
        podPickerScroll.hasVerticalScroller = true
        podPickerScroll.drawsBackground = false
        podPickerScroll.borderType = .noBorder
        podPickerScroll.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (4): the document view is width-pinned to the *clip* view,
        // never to the scroll view, or a non-overlay scroller's real ~15pt
        // track renders the trailing edge underneath it.
        pickerDoc.widthAnchor.constraint(equalTo: podPickerScroll.contentView.widthAnchor).isActive = true

        pauseButton = HelmButton(title: "Pause", variant: .secondary, size: .small)
        pauseButton.target = self
        pauseButton.action = #selector(togglePauseTapped)
        errorsOnlyButton = HelmButton(title: "Errors only", variant: .secondary, size: .small)
        errorsOnlyButton.target = self
        errorsOnlyButton.action = #selector(toggleErrorsOnlyTapped)
        let clearButton = HelmButton(title: "Clear", variant: .quiet, size: .small)
        clearButton.target = self
        clearButton.action = #selector(clearTailTapped)

        tailStatusLabel = NSTextField(wrappingLabelWithString: KubeLogTailSession.limitsNote)
        tailStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        tailStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controls = NSStackView(views: [pauseButton, errorsOnlyButton, clearButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = HelmMetrics.s2
        controls.setHuggingPriority(.required, for: .horizontal)
        controls.translatesAutoresizingMaskIntoConstraints = false

        logList = KubeLogListView()

        let rightColumn = NSStackView(views: [controls, logList!, tailStatusLabel])
        rightColumn.orientation = .vertical
        rightColumn.alignment = .leading
        rightColumn.spacing = HelmMetrics.s2
        rightColumn.translatesAutoresizingMaskIntoConstraints = false
        logList.setContentHuggingPriority(.defaultLow, for: .vertical)

        tailContainer.addSubview(podPickerScroll)
        tailContainer.addSubview(rightColumn)
        NSLayoutConstraint.activate([
            podPickerScroll.leadingAnchor.constraint(equalTo: tailContainer.leadingAnchor),
            podPickerScroll.topAnchor.constraint(equalTo: tailContainer.topAnchor),
            podPickerScroll.bottomAnchor.constraint(equalTo: tailContainer.bottomAnchor),
            podPickerScroll.widthAnchor.constraint(equalToConstant: 230),

            rightColumn.leadingAnchor.constraint(equalTo: podPickerScroll.trailingAnchor, constant: HelmMetrics.s3),
            rightColumn.trailingAnchor.constraint(equalTo: tailContainer.trailingAnchor),
            rightColumn.topAnchor.constraint(equalTo: tailContainer.topAnchor),
            rightColumn.bottomAnchor.constraint(equalTo: tailContainer.bottomAnchor),
            logList.widthAnchor.constraint(equalTo: rightColumn.widthAnchor),
            tailStatusLabel.widthAnchor.constraint(equalTo: rightColumn.widthAnchor),
        ])
        tailContainer.isHidden = true
    }
}
