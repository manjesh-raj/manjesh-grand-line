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
        refreshWatchdogTimer?.invalidate()
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
    /// The adopted feed tab's own terminal, held so `teardownFeed()` can
    /// release the machine-readable geometry it pinned in `adoptFeedTab`.
    /// Weak: this page never keeps a closed tab alive.
    weak var feedTerminal: (any SRELeadBridgeTerminal)?

    /// Whether this page's feed bridge is mid-command on `tabID`.
    ///
    /// The Kubernetes half of the cross-bridge collision guard's third
    /// direction (full-app audit, finding 4.1). `KubeBridge` already refuses
    /// to inject while SRE Lead or the context badge holds the tab; this is
    /// what lets those two refuse back. Answers `false` for any tab that is
    /// not the current feed tab, so a console with several tabs only ever
    /// blocks the one this page is genuinely typing into.
    func isFeedBridgeBusy(onTab tabID: UUID) -> Bool {
        guard feedTabID == tabID else { return false }
        return bridge?.isBusy == true
    }

    var namespace = "default"

    /// Namespaces this cluster actually reported, newest read wins - the
    /// picker's source (audit §6.7b). `nil` until a read has been attempted;
    /// empty after one that came back with nothing usable.
    ///
    /// Kept deliberately separate from `clusterMessage`: a cluster that
    /// forbids `get namespaces` (a scoped service account is the common case
    /// on a bastion) is not a failed *page*, only a picker with nothing to
    /// offer - which is exactly why the typed field below stays.
    var knownNamespaces: [String]?

    var pods: [KubePod] = []
    var deployments: [KubeDeployment] = []
    var services: [KubeService] = []
    var events: [KubeEvent] = []
    var clusterMessage: String?
    var lastRefreshedAt: Date?
    var isRefreshingCluster = false

    /// `fm/grandline-k8s-refresh-stuck-audit`'s mandatory hard safety net,
    /// independent of whatever causes a stuck refresh - see this file's
    /// header and `checkRefreshWatchdog()`'s own doc comment. `isRefreshing
    /// Cluster` must never be trusted to resolve on its own no matter what
    /// bug (this one, or a future one) might otherwise leave it stuck.
    var refreshStartedAt: Date?
    var refreshWatchdogTimer: Timer?
    /// True only while `refreshCluster()`'s own hard ceiling has fired and
    /// forced the page out of an indefinite "Refreshing…" - cleared the
    /// moment a fresh attempt starts, or if the original, once-stuck request
    /// eventually straggles in on its own (`applySweep` clears it too).
    var clusterRefreshStuck = false
    /// Every `refreshCluster()` call gets a fresh id. A batch's completion
    /// only applies its results (and only clears `isRefreshingCluster`) if
    /// its own generation still matches - so a request the watchdog already
    /// forced past, which later straggles in anyway, cannot silently step on
    /// whatever a newer, already-started attempt has since rendered. This is
    /// what keeps the watchdog a genuine safety net rather than a new source
    /// of double-applied or out-of-order state.
    var refreshGeneration = 0
    /// How long a cluster refresh may run with no completion (success or
    /// failure) before this page forces itself out of an indefinite
    /// "Refreshing…" into a clear, actionable "stuck" state - counted from
    /// `refreshStartedAt`, not reset by an in-between `pendingReason`
    /// transition (waiting on contention is still time the captain has been
    /// looking at "Refreshing…" with nothing resolving). Deliberately
    /// independent of `KubeBridge`'s own much shorter `commandTimeout`/
    /// `queueDeadline` - this ceiling exists to catch a dropped completion
    /// *anywhere* along the chain, not to second-guess a genuinely slow
    /// cluster.
    static let clusterRefreshHardCeiling: TimeInterval = 75
    /// How often the watchdog checks - independent of, and much finer than,
    /// `clusterPollInterval`, so the stuck state appears promptly once the
    /// ceiling is crossed rather than waiting for the next 30s poll.
    static let refreshWatchdogInterval: TimeInterval = 5

    let merger = KubeLogMerger()
    var selectedPods: [String] = []
    /// What the pod picker was last built from - see `renderPodPicker`.
    var lastPodPickerSignature: String?
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
    /// `fm/grandline-k8s-ui-revamp`: one card, not two. Scope and Feed tab are
    /// the same question - "which authenticated session am I driving, through
    /// which tab" - and two stacked `HelmCard` headers cost ~120pt of chrome
    /// on a page whose actual content is a table. They remain two independent
    /// *sections* inside it, shown and hidden separately exactly as before.
    var sessionCard: HelmCard!
    var scopeTabsHost: NSView!
    var scopeTabs: HelmSegmentedTabs?
    var scopeEmptyState: HelmEmptyState!
    var feedSection: NSView!
    var feedTabPicker: HelmPopUpButton!
    var feedStatusLabel: NSTextField!
    var retryFeedButton: HelmButton!
    var workArea: NSView!
    var pageTabs: HelmSegmentedTabs!
    var clusterContainer: NSView!
    var tailContainer: NSView!

    var namespaceField: HelmTextField!
    var namespacePicker: HelmPopUpButton!
    var clusterTabs: HelmSegmentedTabs!
    var clusterTable: KubeResourceTableView!
    var clusterStatusLabel: NSTextField!
    /// `fm/grandline-k8s-refresh-stuck-audit`'s mandatory safety net: the
    /// real "Try again" action for a refresh the hard-ceiling watchdog forced
    /// out of an indefinite "Refreshing…". Hidden whenever the feed is
    /// working - a retry button beside a healthy refresh invites a pointless
    /// extra command, matching `retryFeedButton`'s own precedent.
    var clusterRetryButton: HelmButton!
    var describeDrawer: NSView!
    var describeTitleLabel: NSTextField!
    var describeSubtitleLabel: NSTextField!
    var describeTextView: NSTextView!
    var describeScroll: NSScrollView!
    var describeSpinner: NSProgressIndicator!
    var describeCloseButton: HelmButton!
    var describeCopyButton: HelmButton!
    var describeWidthConstraint: NSLayoutConstraint!
    /// The drawer's inner content, pinned to its **trailing** edge at a fixed
    /// width while the drawer's own width animates from zero. See
    /// `buildDescribeDrawer` for why the content cannot simply be pinned to
    /// both of the drawer's edges.
    var describeContent: NSView!
    var describeContentWidthConstraint: NSLayoutConstraint!
    /// Which pod the panel is showing, so a completion arriving after the
    /// captain clicked a different row (or closed the panel) is dropped
    /// instead of overwriting what they are now looking at.
    var describeTarget: String?

    /// How wide the drawer opens: a share of the page, floored so it stays
    /// readable on a narrow window and capped so it never swallows the table
    /// it is describing. `kubectl describe` wraps at nothing, so this is
    /// genuinely about how much of a long line is visible before scrolling.
    static let describeDrawerFraction: CGFloat = 0.46
    static let describeDrawerMinWidth: CGFloat = 380
    static let describeDrawerMaxWidth: CGFloat = 760

    var podPickerStack: NSStackView!
    var podPickerScroll: NSScrollView!
    var logList: KubeLogListView!
    var tailStatusLabel: NSTextField!
    var pauseButton: HelmButton!
    var errorsOnlyButton: HelmButton!

    /// A filled accent pill, matching Setup > Updates' own "Refresh" - one
    /// real, shared, theme-aware definition rather than a page-local muted
    /// `.quiet` look.
    let refreshButton = HelmButton(title: "Refresh", variant: .primary, symbol: "arrow.clockwise")

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

        buildSessionCard()
        buildWorkArea()

        // **Explicit constraints, not a vertical `NSStackView`**
        // (`fm/grandline-k8s-ui-revamp`, the layout half of the captain's
        // report). The page used to stack card / card / work area at the
        // stack's default `.gravityAreas` distribution, which has no defined
        // rule for who absorbs leftover height - so the work area kept its
        // own 320pt minimum and the rest of the window rendered as dead space
        // below a table trapped in a small internal scroller (the captain's
        // "tiny scrollable box on an otherwise-empty page", and the reason
        // the page double-scrolled). Hugging priorities cannot fix that:
        // gotcha (12) - a `HelmCard` is constraint-driven with no intrinsic
        // content size, so content hugging on it is a no-op.
        //
        // Pinning the work area's own bottom to the container is what makes
        // the table genuinely fill the page: the card above it sizes to its
        // content, and everything left over is the table's.
        for child in [sessionCard!, workArea!] { container.addSubview(child) }
        NSLayoutConstraint.activate([
            sessionCard.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: HelmMetrics.pageGutter),
            sessionCard.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -HelmMetrics.pageGutter),
            sessionCard.topAnchor.constraint(equalTo: container.topAnchor, constant: HelmMetrics.s4),

            workArea.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: HelmMetrics.pageGutter),
            workArea.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -HelmMetrics.pageGutter),
            workArea.topAnchor.constraint(equalTo: sessionCard.bottomAnchor, constant: HelmMetrics.s4),
            workArea.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -HelmMetrics.s4),
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

    /// Scope and Feed tab, one card. See `sessionCard`'s own declaration for
    /// why they were merged; the two sections below are still shown and
    /// hidden independently, which is what `render()` drives.
    func buildSessionCard() {
        sessionCard = HelmCard()
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

        buildFeedSection()

        let body = NSStackView(views: [scopeTabsHost, scopeEmptyState, feedSection])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s3
        body.translatesAutoresizingMaskIntoConstraints = false
        _ = sessionCard.setHeader(symbol: "point.3.connected.trianglepath.dotted",
                                  tint: .info,
                                  title: "Session",
                                  subtitle: "Which authenticated bastion session these commands run in, and which of its tabs this page types into. "
                                      + "Typing into the feed tab yourself pauses automated commands until it goes quiet again.")
        sessionCard.setBody(body, insets: HelmCard.contentInsets)
        NSLayoutConstraint.activate([
            scopeTabsHost.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scopeEmptyState.widthAnchor.constraint(equalTo: body.widthAnchor),
            feedSection.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
    }

    private func buildFeedSection() {
        feedSection = NSView()
        feedSection.translatesAutoresizingMaskIntoConstraints = false

        feedTabPicker = HelmPopUpButton()
        feedTabPicker.target = self
        feedTabPicker.action = #selector(feedTabPicked)

        let feedLabel = NSTextField(labelWithString: "Feed tab")
        feedLabel.font = HelmType.kicker()
        feedLabel.translatesAutoresizingMaskIntoConstraints = false

        let duplicate = HelmButton(title: "Duplicate a tab", variant: .secondary, size: .small)
        duplicate.target = self
        duplicate.action = #selector(duplicateFeedTapped)
        duplicate.toolTip = "Duplicate this host's tab and pin the copy as the feed, so your working terminal stays clean."

        let openHost = HelmButton(title: "Open host page", variant: .quiet, size: .small)
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

        // One row, not two: the picker and its actions sit on the same line
        // as the label they belong to, and the status wraps underneath.
        // `fm/grandline-k8s-feed-tab-stall-fix`'s warning stays in the status
        // copy - a captain checking on this tab by typing into it directly is
        // exactly what pauses every automated command until it goes quiet
        // again (`KubeBridge`'s own activity-quiet-window check).
        let controls = NSStackView(views: [feedLabel, feedTabPicker, duplicate, openHost, retryFeedButton!])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = HelmMetrics.s2
        controls.distribution = .fill
        controls.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (12): the *stack*-level priorities are the ones that bite on
        // an `NSStackView`; the content-level ones are a no-op on a view with
        // no intrinsic size. The picker is what yields.
        controls.setHuggingPriority(.required, for: .horizontal)
        for control in [duplicate, openHost, retryFeedButton!] {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        feedLabel.setContentHuggingPriority(.required, for: .horizontal)
        feedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        feedTabPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        feedSection.addSubview(controls)
        feedSection.addSubview(feedStatusLabel)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: feedSection.leadingAnchor),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: feedSection.trailingAnchor),
            controls.topAnchor.constraint(equalTo: feedSection.topAnchor),
            feedStatusLabel.leadingAnchor.constraint(equalTo: feedSection.leadingAnchor),
            feedStatusLabel.trailingAnchor.constraint(equalTo: feedSection.trailingAnchor),
            feedStatusLabel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: HelmMetrics.s2),
            feedStatusLabel.bottomAnchor.constraint(equalTo: feedSection.bottomAnchor),
        ])
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
            // Whichever page just became visible gets the data it shows. The
            // Log Tail's picker is built from the pod list, which the sweep
            // now skips while a non-Pods cluster tab is up (`sweepCommands`).
            if self.pods.isEmpty, self.clusterMessage == nil { self.refreshCluster() }
        }

        namespaceField = HelmTextField(placeholder: "namespace")
        namespaceField.stringValue = namespace
        namespaceField.target = self
        namespaceField.action = #selector(namespaceCommitted)
        namespaceField.widthAnchor.constraint(equalToConstant: 190).isActive = true

        // Audit §6.7b asked to *replace* typed entry with a picker. The field
        // stays, and that is a deliberate correction rather than a half-done
        // change: listing namespaces is a cluster-scoped read, and a bastion
        // service account that can list pods in its own namespace very often
        // cannot list the cluster's namespaces at all. A picker-only control
        // would make a namespace the captain can genuinely use unreachable the
        // moment RBAC says no - so the picker is additive, and disabled with a
        // reason when there is nothing real to offer (GL-14: never an empty
        // menu that reads like an empty cluster).
        namespacePicker = HelmPopUpButton()
        namespacePicker.target = self
        namespacePicker.action = #selector(namespacePicked)
        namespacePicker.translatesAutoresizingMaskIntoConstraints = false
        namespacePicker.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let nsLabel = NSTextField(labelWithString: "Namespace")
        nsLabel.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [pageTabs, nsLabel, namespaceField, namespacePicker])
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
        // A floor so the page still reads sensibly in a short window; the
        // work area's *real* height now comes from being pinned to the
        // container's bottom in `loadView`, so this is only a minimum, not
        // the thing that sizes it. 499, never required: a content constraint
        // above `NSLayoutPriorityWindowSizeStayPut` (500) is a window-size
        // cap, which is AGENTS.md gotcha (13) and has shipped here four times.
        let minHeight = workArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
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
            // Fetch what the captain just asked to look at. The sweep is
            // scoped to the visible tab (`sweepCommands`), so this is the
            // moment the newly-visible table's own command gets run - the
            // mockup's own "each costs one more get, run only when that tab
            // is opened", now applied to Pods' metrics too rather than only
            // to Services and Events. `refreshCluster` no-ops while a sweep
            // is already in flight, so rapid tab clicks collapse into one.
            self.refreshCluster()
        }

        clusterStatusLabel = NSTextField(labelWithString: "")
        clusterStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        clusterTable = KubeResourceTableView()
        buildDescribeDrawer()

        // `fm/grandline-k8s-refresh-stuck-audit`: the hard-ceiling watchdog's
        // own real "Try again" action - see `checkRefreshWatchdog()`. Shown
        // only in the stuck state, never beside a healthy or genuinely
        // running refresh.
        clusterRetryButton = HelmButton(title: "Try again", variant: .primary, size: .small)
        clusterRetryButton.target = self
        clusterRetryButton.action = #selector(retryStuckClusterRefreshTapped)
        clusterRetryButton.isHidden = true
        clusterRetryButton.setContentHuggingPriority(.required, for: .horizontal)
        clusterRetryButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = NSStackView(views: [clusterTabs, clusterStatusLabel, clusterRetryButton!])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = HelmMetrics.s3
        header.translatesAutoresizingMaskIntoConstraints = false
        clusterStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The table fills everything under the header, and the drawer is
        // added *last* so it overlays the table's trailing edge rather than
        // pushing it. Both are what the captain's "tiny scrollable box on an
        // otherwise-empty page" report is about: before this, the table was
        // sandwiched between the header and a permanently-reserved
        // describe area, so it never got the window's real height.
        for child in [header, clusterTable!, describeDrawer!] { clusterContainer.addSubview(child) }
        describeWidthConstraint = describeDrawer.widthAnchor.constraint(equalToConstant: 0)
        // The width yields to the container rather than overhanging it on a
        // narrow window. `leading >=` is required and the width is 999, so a
        // window too narrow for the panel shrinks it - and, crucially, the
        // panel can never become a *floor* on the window's own width, which
        // is gotcha (13) and has shipped in this app four times.
        describeWidthConstraint.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: clusterContainer.leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: clusterContainer.trailingAnchor),
            header.topAnchor.constraint(equalTo: clusterContainer.topAnchor),

            clusterTable.leadingAnchor.constraint(equalTo: clusterContainer.leadingAnchor),
            clusterTable.trailingAnchor.constraint(equalTo: clusterContainer.trailingAnchor),
            clusterTable.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s3),
            clusterTable.bottomAnchor.constraint(equalTo: clusterContainer.bottomAnchor),

            describeDrawer.trailingAnchor.constraint(equalTo: clusterContainer.trailingAnchor),
            describeDrawer.leadingAnchor.constraint(greaterThanOrEqualTo: clusterContainer.leadingAnchor),
            describeDrawer.topAnchor.constraint(equalTo: clusterTable.topAnchor),
            describeDrawer.bottomAnchor.constraint(equalTo: clusterContainer.bottomAnchor),
            describeWidthConstraint,
        ])
        clusterTable.setContentHuggingPriority(.defaultLow, for: .vertical)

        clusterTable.onSelectRow = { [weak self] key in
            guard let self, self.clusterTab == .pods else { return }
            self.describePod(key)
        }
    }

    /// **A real drawer, not appended text** (`fm/grandline-k8s-ui-revamp`,
    /// bug 3). Clicking a pod used to append "Running kubectl describe…" and
    /// then the result *below the table*, so the captain had to scroll down to
    /// discover anything had happened, and the way out was a plain "Close"
    /// text link.
    ///
    /// This is a slide-in side panel over the table's trailing edge, the same
    /// idiom `ConsoleController`'s SRE Lead pane already uses on the host page
    /// (a pinned container whose width constraint animates between 0 and its
    /// open width). It carries its own header with the pod's name, a real
    /// spinner while the command is in flight, a Copy action, and an actual
    /// close button rather than a link - plus Escape, since a panel that
    /// covers content has to be dismissible without aiming.
    ///
    /// It **overlays** rather than displacing: the table keeps its own width
    /// and scroll position, so opening a describe never reflows the rows the
    /// captain was reading.
    func buildDescribeDrawer() {
        describeDrawer = NSView()
        describeDrawer.translatesAutoresizingMaskIntoConstraints = false
        describeDrawer.wantsLayer = true
        // Clipped, so the content genuinely slides out of view as the width
        // animates to zero rather than spilling over the table.
        describeDrawer.layer?.masksToBounds = true

        describeTitleLabel = NSTextField(labelWithString: "")
        describeTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        describeTitleLabel.lineBreakMode = .byTruncatingMiddle
        // Gotcha (13): a long pod name must never become a window-width floor.
        describeTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        describeSubtitleLabel = NSTextField(labelWithString: "")
        describeSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        describeSubtitleLabel.lineBreakMode = .byTruncatingTail
        describeSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        describeSpinner = NSProgressIndicator()
        describeSpinner.style = .spinning
        describeSpinner.controlSize = .small
        describeSpinner.isDisplayedWhenStopped = false
        describeSpinner.translatesAutoresizingMaskIntoConstraints = false

        describeCopyButton = HelmButton(title: "Copy", variant: .quiet, size: .small)
        describeCopyButton.target = self
        describeCopyButton.action = #selector(copyDescribeTapped)
        describeCopyButton.toolTip = "Copy this describe output to the clipboard"

        describeCloseButton = HelmButton(symbol: "xmark", variant: .quiet, size: .small)
        describeCloseButton.target = self
        describeCloseButton.action = #selector(closeDescribeTapped)
        describeCloseButton.toolTip = "Close (Esc)"

        // **Explicit constraints, not nested stacks.** A vertical title
        // column inside a horizontal `.fill` stack collapsed to zero width
        // here - measured, and not fixable with hugging/clipping priorities
        // (gotcha (12) again). The header is small and its shape is fixed, so
        // pinning it directly is both deterministic and shorter.
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        for child in [describeTitleLabel!, describeSubtitleLabel!, describeSpinner!,
                      describeCopyButton!, describeCloseButton!] {
            // `HelmButton` does not clear this itself, and everywhere else in
            // this app it lands in an `NSStackView`, which clears it for you.
            // Left set, AppKit synthesises required frame constraints that
            // silently win over every explicit one here - measured: the Copy
            // button ignored its own width constraint and sat at x=0.
            child.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(child)
        }
        // Explicit sizes for the two trailing controls. A `HelmButton` owns
        // its own font/title/chrome and does not promise a stable intrinsic
        // width, and with only a right-anchored chain to size against, one of
        // them silently absorbed the whole header - measured, with the Copy
        // button laid out at x=0 and the title squeezed to nothing.
        for control in [describeCopyButton!, describeCloseButton!] {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        describeSpinner.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            describeCopyButton.widthAnchor.constraint(equalToConstant: 58),
            describeCloseButton.widthAnchor.constraint(equalToConstant: 26),
            describeSpinner.widthAnchor.constraint(equalToConstant: 16),
        ])
        NSLayoutConstraint.activate([
            describeCloseButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            describeCloseButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            describeCopyButton.trailingAnchor.constraint(equalTo: describeCloseButton.leadingAnchor,
                                                         constant: -HelmMetrics.s2),
            describeCopyButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            describeSpinner.trailingAnchor.constraint(equalTo: describeCopyButton.leadingAnchor,
                                                      constant: -HelmMetrics.s2),
            describeSpinner.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            describeTitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            describeTitleLabel.topAnchor.constraint(equalTo: header.topAnchor),
            describeTitleLabel.trailingAnchor.constraint(equalTo: describeSpinner.leadingAnchor,
                                                         constant: -HelmMetrics.s2),
            describeSubtitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            describeSubtitleLabel.topAnchor.constraint(equalTo: describeTitleLabel.bottomAnchor, constant: 1),
            describeSubtitleLabel.trailingAnchor.constraint(equalTo: describeSpinner.leadingAnchor,
                                                            constant: -HelmMetrics.s2),
            describeSubtitleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        describeTextView = NSTextView()
        describeTextView.isEditable = false
        describeTextView.isSelectable = true
        // Plain text, so `font`/`textColor` apply to the whole document. An
        // `NSTextView` is rich by default, where those two setters only touch
        // the *typing* attributes - so text already in the view keeps whatever
        // it had, which on this deliberately dark output card means near-black
        // glyphs on a near-black background. Caught in a real render: the
        // panel showed an empty black rectangle with the describe output
        // genuinely present in `string`.
        describeTextView.isRichText = false
        describeTextView.usesFontPanel = false
        describeTextView.drawsBackground = false
        describeTextView.textContainerInset = NSSize(width: 10, height: 10)
        // **Wraps to the panel, rather than scrolling horizontally.** The
        // previous inline version was horizontally resizable with an infinite
        // text container, which in a zero-origin `NSTextView` inside a scroll
        // view sizes the document to whatever the layout manager last decided
        // - a real render showed the whole describe squeezed into a ~120pt
        // column with the rest of the panel empty. A side panel is narrow by
        // definition and `kubectl describe` is mostly short key/value lines,
        // so wrapping the handful of long ones is strictly better than making
        // the captain scroll sideways through all of them.
        describeTextView.isHorizontallyResizable = false
        describeTextView.isVerticallyResizable = true
        describeTextView.autoresizingMask = [.width]
        describeTextView.textContainer?.widthTracksTextView = true
        describeScroll = NSScrollView()
        describeScroll.documentView = describeTextView
        describeScroll.hasVerticalScroller = true
        describeScroll.hasHorizontalScroller = false
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

        // **The content lives in an inner view pinned to the trailing edge at
        // a fixed width, not stretched between both of the drawer's edges** -
        // and this is a correctness requirement, not a style choice. The
        // drawer's own width animates down to **zero** when closed; a child
        // pinned to both edges would then be asked for a width of
        // `0 - 2 * inset`, which is unsatisfiable, so AppKit breaks one of
        // those constraints - permanently. Found in a real off-screen render:
        // the panel opened at its full 622pt while its header and scroll view
        // stayed laid out at 93pt, with the title collapsed to nothing.
        //
        // Pinning the content to the trailing edge instead is also what makes
        // this read as a drawer: the content keeps its shape and slides out
        // from behind the clip, rather than being squeezed and re-wrapped on
        // every frame of the animation.
        describeContent = NSView()
        describeContent.translatesAutoresizingMaskIntoConstraints = false
        describeDrawer.addSubview(describeContent)
        describeContent.addSubview(header)
        describeContent.addSubview(describeScroll)
        describeContentWidthConstraint = describeContent.widthAnchor.constraint(equalToConstant: Self.describeDrawerMinWidth)
        NSLayoutConstraint.activate([
            describeContent.trailingAnchor.constraint(equalTo: describeDrawer.trailingAnchor),
            describeContent.topAnchor.constraint(equalTo: describeDrawer.topAnchor),
            describeContent.bottomAnchor.constraint(equalTo: describeDrawer.bottomAnchor),
            describeContentWidthConstraint,

            header.leadingAnchor.constraint(equalTo: describeContent.leadingAnchor, constant: HelmMetrics.s3),
            header.trailingAnchor.constraint(equalTo: describeContent.trailingAnchor, constant: -HelmMetrics.s3),
            header.topAnchor.constraint(equalTo: describeContent.topAnchor, constant: HelmMetrics.s3),
            describeScroll.leadingAnchor.constraint(equalTo: describeContent.leadingAnchor, constant: HelmMetrics.s3),
            describeScroll.trailingAnchor.constraint(equalTo: describeContent.trailingAnchor, constant: -HelmMetrics.s3),
            describeScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s2),
            describeScroll.bottomAnchor.constraint(equalTo: describeContent.bottomAnchor, constant: -HelmMetrics.s3),
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
