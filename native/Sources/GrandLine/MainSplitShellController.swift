// Grand Line - native macOS app.
//
// `MainSplitShellController` - the sidebar layout (stage 3 of the modular-shell
// migration, full review section 5.8 step 3).
//
// The window root the captain gets with Settings > Appearance > Window layout
// set to Sidebar:
//
//   root                                  (the window's content view)
//   ├── NSSplitViewController.view
//   │   ├── sidebar   WorkspaceSidebarController - every page, the pins, the
//   │   │             live sessions, the account menu
//   │   ├── content   the workspace's body container (the same
//   │   │             `DestinationMounter`, the same 29 pages), with the
//   │   │             status line under it
//   │   └── inspector WorkspaceInspectorController - collapsed, empty until
//   │                 stage 4 gives pages something to show in it
//   └── the lock overlay (LockPresenter), over all three
//
// plus the window's own toolbar (`WorkspaceToolbar`), title and subtitle,
// which name the page the way the floating bar's drill header did.
//
// **It hosts exactly what the floating bar hosts.** The pages, the stores, the
// navigator, the host sessions and the lock are the `Workspace` this shell
// shares with `AppShellController`; nothing here builds a page or a store, and
// `ShellSplitSelfTest` fails if that changes. What this file owns is chrome:
// where each floating-bar control went (the inventory's "Shell chrome" rows
// name each one), and the `WorkspaceChrome` hooks that keep it in step with
// whatever the workspace shows.
//
// **The title bar is the system's.** The floating bar hides the title bar and
// moves the traffic lights onto itself (`WindowChromeFusion`); this shell does
// the opposite - a standard titled window with a unified toolbar - so the app
// delegate skips the fusion for it. The step 3 plan asked for that decision up
// front because `ChromeFusionRootView` does not apply to a titled window.
//
// **The toolbar sits outside the lock overlay.** The overlay covers the
// content view, and a toolbar is drawn above it in the title bar, so while the
// lock is up this shell hides the toolbar and the title outright rather than
// trusting the overlay to cover them.

import AppKit

final class MainSplitShellController: WorkspaceShellController {

    /// The prototype's sidebar width, which is where it opens; the captain
    /// can drag it between `sidebarMinimum` and `sidebarMaximum`.
    static let sidebarWidth: CGFloat = 236
    static let sidebarMinimum: CGFloat = 200
    static let sidebarMaximum: CGFloat = 320
    /// The narrowest the content column may be, which is the widest page's
    /// own minimum: the 29 pages were laid out for the floating bar's
    /// full-width body, and two of them hold more width than a column beside
    /// the sidebar has at 1100pt - Log Analyzer 938pt and DevOps Commands
    /// 929pt, measured as the width each pushed a 1100pt window to. A page
    /// that is wider than its column does not shrink, it grows the window
    /// (AGENTS.md gotcha (13)), so the column is never allowed to be
    /// narrower than this. Below `contentMinimum` plus the sidebar the system
    /// collapses the sidebar instead - the standard macOS behaviour - and
    /// brings it back when the window is wide enough again.
    ///
    /// Stage 4 lowers this as each module's page is reflowed for the column;
    /// `MainSplitShellSelfTest` fails if a page outgrows it first.
    static let contentMinimumWithOverlayScrollers: CGFloat = 940

    /// `contentMinimumWithOverlayScrollers`, plus one scroller's track while
    /// the system draws legacy scrollers. "Show scroll bars: Always" gives a
    /// scroll view a real track (gotcha (4)), and each page's floor grows by
    /// exactly that. Measured on CI's runner, which shows them always: Log
    /// Analyzer and Kubernetes need 953pt there against about 938pt with
    /// overlay scrollers, and DevOps Commands 943pt against 929pt.
    static var contentMinimum: CGFloat {
        guard NSScroller.preferredScrollerStyle == .legacy else { return contentMinimumWithOverlayScrollers }
        return contentMinimumWithOverlayScrollers + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    private let splitController = NSSplitViewController()
    let sidebar = WorkspaceSidebarController()
    let inspector = WorkspaceInspectorController()
    private let statusLine = WorkspaceStatusLine()
    private lazy var contentPane = WorkspaceContentPaneController(body: workspace.content.bodyContainer,
                                                                   statusLine: statusLine)
    private var sidebarItem: NSSplitViewItem!
    private var contentItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private(set) var toolbar: WorkspaceToolbar!

    /// The floating bar's three dropdowns, rebuilt for this chrome. Each is
    /// the same controller the bar uses - the same panel, the same store, the
    /// same rows - opened from a toolbar button instead of a bar square.
    let notificationCenter = NotificationCenterController()
    let recents = RecentDestinationsController()
    private let clipboardHistory = ClipboardHistoryController()

    private var history = NavigationHistory()

    /// What the title bar names: the page's title and its live subtitle -
    /// the drill header's two lines (`chrome.drillTitle`, `chrome.drillSubtitle`).
    private var pageTitle = ""
    private var pageSubtitle = ""
    /// The showing page, for re-reading its live subtitle and actions.
    private weak var pageController: NSViewController?
    private var pageIsHome = true
    private var lockOverlayIsShown = false
    private var didSettleInitialSidebarWidth = false
    private var themeToken: ThemeObservation?
    private var windowResizeObserver: NSObjectProtocol?

    /// Whether the sidebar is collapsed because the window is too narrow for
    /// it, rather than because the captain hid it - only then does widening
    /// the window bring it back.
    private var sidebarCollapsedForRoom = false
    /// The sidebar's width as the captain left it: where it opens, then
    /// wherever they last dragged its divider. Not read off the pane on the
    /// way into a collapse - measured: by the time a narrowing window's
    /// resize notification arrives, the split view has already squeezed the
    /// sidebar to its 200pt minimum, and that is not a width anyone chose.
    private var sidebarThickness: CGFloat = MainSplitShellController.sidebarWidth
    /// The inset macOS 26 floats the sidebar in (0 before it), measured once
    /// the panes are first laid out.
    private var sidebarInset: CGFloat = 0
    /// The room the sidebar's pane takes while it shows.
    private var sidebarPaneWidth: CGFloat { sidebarThickness + sidebarInset }
    private var dividerDragObserver: NSObjectProtocol?
    private var scrollerStyleObserver: NSObjectProtocol?

    override var namesThePageInTheTitleBar: Bool { true }
    override var clipboardHistoryController: ClipboardHistoryController? { clipboardHistory }

    // MARK: Build

    override func loadView() {
        // T-14d: the same launch interval the floating bar's `loadView` has,
        // under this shell's own name.
        let loadViewInterval = LaunchSignposts.begin("MainSplitShellController.loadView")
        defer { LaunchSignposts.end("MainSplitShellController.loadView", loadViewInterval) }

        let root = WorkspaceShellRootView(frame: NSRect(x: 0, y: 0, width: 1220, height: 720))
        root.wantsLayer = true
        root.onWindowChange = { [weak self] window in self?.attach(to: window) }
        view = root
        paintGroundAndFollowTextScale()

        buildSplitView(in: root)
        buildToolbar()
        wireSidebar()
        statusLine.attachFocusTimer(workspace.focusTimer)
        recents.configure(registry: workspace.navigator.recentDestinations) { [weak self] kind in
            self?.workspace.navigator.navigateToRecentDestination(kind)
        }
        clipboardHistory.anchor = toolbar.clipboardAnchor
        notificationCenter.onBadgeCountChanged = { [weak self] count in self?.toolbar.setNotificationCount(count) }

        // The pages go into the content pane, as its children - the same
        // registration, mount, wiring and landing the floating bar runs, in
        // the same order.
        workspace.content.parentController = contentPane
        _ = contentPane.view
        workspace.registerDestinations()
        workspace.content.mounter.mountEagerSlots()
        workspace.wireEagerPages()
        workspace.showLaunchLanding()

        // Added last, so it covers the sidebar, the content and the
        // inspector - see `LockPresenter.install`.
        workspace.lock.install(in: self, over: root)
        workspace.lock.onOverlayVisibilityChanged = { [weak self] shown in self?.lockOverlayDidChange(shown) }

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.toolbar?.applyThemeSymbol(theme) }
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let windowResizeObserver { NotificationCenter.default.removeObserver(windowResizeObserver) }
        if let dividerDragObserver { NotificationCenter.default.removeObserver(dividerDragObserver) }
        if let scrollerStyleObserver { NotificationCenter.default.removeObserver(scrollerStyleObserver) }
    }

    private func buildSplitView(in root: NSView) {
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // Opens at the prototype's width; `viewDidLayout` relaxes the range
        // once the split view has a real size.
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = true
        // The content column takes every change in the window's width; the
        // sidebar keeps the width it has, and the inspector its fixed one.
        // `HelmSplitPage`'s measured priority, for its reason: held at the
        // default 260, a page's own grow ties (480) won and the sidebar
        // swung out to its 320pt maximum as pages changed; and held above
        // 489, the divider can no longer be dragged.
        sidebarItem.holdingPriority = HelmSplitPage.sidebarHoldingPriority

        contentItem = NSSplitViewItem(viewController: contentPane)
        contentItem.minimumThickness = Self.contentMinimum
        contentItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 250)
        contentItem.titlebarSeparatorStyle = .automatic
        // The column's floor follows the scroll bar setting (`contentMinimum`).
        // A lower floor is applied before the panes are fitted, so a sidebar
        // that comes back is not held to the old one. A higher floor is
        // applied after, so the sidebar steps aside before the column's
        // minimum can push the window wider.
        scrollerStyleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let floor = Self.contentMinimum
            if floor < self.contentItem.minimumThickness { self.contentItem.minimumThickness = floor }
            self.fitPanesToWindow()
            self.contentItem.minimumThickness = floor
        }

        inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = WorkspaceInspectorController.width
        inspectorItem.maximumThickness = WorkspaceInspectorController.width
        inspectorItem.canCollapse = true
        inspectorItem.canCollapseFromWindowResize = true
        inspectorItem.isCollapsed = true
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 270)
        inspector.onClose = { [weak self] in self?.setInspectorShown(false) }

        for item in [sidebarItem, contentItem, inspectorItem] { splitController.addSplitViewItem(item!) }
        addChild(splitController)
        let split = splitController.view
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // `loadView`'s own theme and text-scale observers can lay the root
        // out before the split view exists, so this waits for a pass that
        // has actually sized the sidebar at its opening width.
        guard !didSettleInitialSidebarWidth, let sidebarItem, splitController.isViewLoaded,
              sidebar.view.frame.width > 0 else { return }
        didSettleInitialSidebarWidth = true
        if let pane = splitController.splitView.arrangedSubviews.first {
            sidebarInset = max(0, pane.frame.width - sidebar.view.frame.width)
        }
        sidebarItem.minimumThickness = Self.sidebarMinimum
        sidebarItem.maximumThickness = Self.sidebarMaximum
        // A drag of the sidebar's divider is the captain choosing its width;
        // every other resize of the panes is the window's (or the split
        // view's own) doing. The notification's divider index cannot tell
        // them apart - measured: it is set for every resize of the panes -
        // so a width is taken as chosen only while the mouse is down on it.
        dividerDragObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitController.splitView, queue: .main
        ) { [weak self] _ in
            guard let self, NSEvent.pressedMouseButtons & 1 != 0,
                  !self.sidebarItem.isCollapsed, self.sidebar.view.frame.width > 0 else { return }
            self.sidebarThickness = self.sidebar.view.frame.width
        }
    }

    private func buildToolbar() {
        toolbar = WorkspaceToolbar(splitView: splitController.splitView)
        toolbar.onToggleSidebar = { [weak self] in self?.toggleWorkspaceSidebar() }
        toolbar.onBack = { [weak self] in self?.step(.back) }
        toolbar.onForward = { [weak self] in self?.step(.forward) }
        toolbar.onRecents = { [weak self] anchor in self?.recents.togglePanel(under: anchor) }
        toolbar.onSelectSpace = { [weak self] space in self?.selectSpace(space) }
        toolbar.onToggleTheme = { ThemeManager.shared.toggle() }
        toolbar.onNotifications = { [weak self] anchor in self?.notificationCenter.togglePanel(under: anchor) }
        toolbar.onToggleInspector = { [weak self] in
            guard let self else { return }
            self.setInspectorShown(self.inspectorItem.isCollapsed)
        }
        toolbar.onSearch = { [weak self] in self?.workspace.onSearchTapped?() }
    }

    private func wireSidebar() {
        sidebar.onSelectDestination = { [weak self] destination in self?.workspace.navigator.show(destination) }
        sidebar.onSelectSession = { [weak self] id in self?.workspace.hosts.switchToSession(hostID: id) }
        sidebar.onEndSession = { [weak self] id in self?.workspace.hosts.confirmEndSession(hostID: id) }
        // The session strip's "+" opened Hosts; so does Console's own menu.
        sidebar.onConnectHost = { [weak self] in self?.workspace.navigator.show(.hosts) }
        sidebar.onTogglePin = { [weak self] destination in self?.toggleQuickAccessPin(destination) }
        sidebar.isPinned = { [weak self] destination in self?.isQuickAccessPinned(destination) ?? false }
        sidebar.onOpenSettings = { [weak self] in self?.workspace.navigator.show(.settings) }
        sidebar.onLogOut = { [weak self] in self?.requestLogout() }
        sidebar.reload(pinned: AppSettings.shared.quickAccess.pinned, sessions: workspace.hosts.sessions)
    }

    // MARK: The window

    /// The root view reached a window: install the toolbar and name the page.
    /// Also runs for the tour lab's and the suites' off-screen windows, which
    /// is what lets them render this chrome.
    private func attach(to window: NSWindow?) {
        guard let window else { return }
        if windowResizeObserver == nil {
            // Registered globally, like the floating bar's own resize
            // observer, and filtered to this shell's window.
            windowResizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let resized = note.object as? NSWindow, resized === self.view.window else { return }
                self.fitPanesToWindow()
                self.workspace.windowOverflowGuard.windowDidResize(resized)
            }
        }
        if window.toolbar !== toolbar.toolbar { window.toolbar = toolbar.toolbar }
        window.toolbarStyle = .unified
        // Three ordinary panes in reading order - the window can work the
        // loop out itself, which the floating bar's two independently
        // anchored halves could not.
        window.autorecalculatesKeyViewLoop = true
        // The launch landing ran before there was a window to put Home's
        // spaces into; now there is.
        toolbar.reconcileDynamicItems()
        applyTitleBar()
        fitPanesToWindow()
    }

    // MARK: Room for the content column

    /// The content column's width with the sidebar showing, at `windowWidth`.
    private func columnWidthWithSidebar(windowWidth: CGFloat) -> CGFloat {
        windowWidth - sidebarPaneWidth - (inspectorItem.isCollapsed ? 0 : WorkspaceInspectorController.width)
    }

    /// Keep the content column at least `contentMinimum` wide: collapse the
    /// sidebar when the window is too narrow for both, and bring it back
    /// once there is room again - unless the captain hid it.
    ///
    /// Runs on every resize of this window, *before* the layout pass the
    /// resize schedules, which is what stops a page wider than the column
    /// from growing the window instead (gotcha (13)). The system's own
    /// `canCollapseFromWindowResize` covers a live drag of the window edge,
    /// but not a frame the app sets - the launch frame, the autosaved one,
    /// a zoom.
    private func fitPanesToWindow() {
        guard let window = view.window, sidebarItem != nil else { return }
        let width = window.contentRect(forFrameRect: window.frame).width
        guard width > 0 else { return }
        if !sidebarItem.isCollapsed {
            if columnWidthWithSidebar(windowWidth: width) < Self.contentMinimum {
                setSidebarCollapsed(true, animated: false)
                sidebarCollapsedForRoom = true
            }
        } else if sidebarCollapsedForRoom, columnWidthWithSidebar(windowWidth: width) >= Self.contentMinimum {
            // Lay the panes out at the window's new width first, with the
            // sidebar still collapsed - which is safe, the column only gets
            // wider - so the expand below is measured against the size the
            // split view will actually have.
            view.layoutSubtreeIfNeeded()
            setSidebarCollapsed(false, animated: false)
            sidebarCollapsedForRoom = false
        }
    }

    /// Collapse or expand the sidebar - the one path every route takes (the
    /// toolbar button, ⌥⌘S, ⌘⇧D, and the window running out of room).
    ///
    /// An expand pins the pane at the width it last had for the length of the
    /// expand, then lets the captain drag it again: a split view re-expanding
    /// a pane after the window changed size underneath it hands the pane
    /// whatever its holding priorities settle on - measured: the 320pt
    /// maximum, after a 1100pt window grew back to 1512 - which is not the
    /// width anyone chose.
    private func setSidebarCollapsed(_ collapsed: Bool, animated: Bool) {
        guard sidebarItem.isCollapsed != collapsed else { return }
        let animate = animated && view.window != nil && !HelmMotion.isReduced
        if !collapsed {
            sidebarItem.minimumThickness = sidebarThickness
            sidebarItem.maximumThickness = sidebarThickness
        }
        let release: () -> Void = { [weak self] in
            guard let self, !collapsed else { return }
            self.sidebarItem.minimumThickness = Self.sidebarMinimum
            self.sidebarItem.maximumThickness = Self.sidebarMaximum
        }
        guard animate else {
            sidebarItem.isCollapsed = collapsed
            splitController.splitView.layoutSubtreeIfNeeded()
            release()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = HelmMotion.moveDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.sidebarItem.animator().isCollapsed = collapsed
        }, completionHandler: release)
    }



    /// Widen the window, inside its screen, so the column keeps
    /// `contentMinimum` with the panes the captain just asked for. Only ever
    /// after an explicit request (showing the sidebar or the inspector),
    /// never on navigation.
    private func makeRoom(sidebarShown: Bool, inspectorShown: Bool) {
        guard let window = view.window else { return }
        let needed = Self.contentMinimum + (sidebarShown ? sidebarPaneWidth : 0)
            + (inspectorShown ? WorkspaceInspectorController.width : 0)
        let current = window.contentRect(forFrameRect: window.frame).width
        guard current < needed else { return }
        var frame = window.frame
        frame.size.width += needed - current
        if let screen = window.screen?.visibleFrame {
            frame.size.width = min(frame.width, screen.width)
            frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        }
        window.setFrame(frame, display: true)
    }

    /// The window's title and subtitle, or nothing at all while the lock
    /// overlay is up - the title would name the page it is hiding.
    private func applyTitleBar() {
        guard let window = view.window else { return }
        window.toolbar?.isVisible = !lockOverlayIsShown
        window.titleVisibility = lockOverlayIsShown ? .hidden : .visible
        window.titlebarAppearsTransparent = lockOverlayIsShown
        window.title = lockOverlayIsShown ? AppPaths.displayName : pageTitle
        window.subtitle = lockOverlayIsShown ? "" : pageSubtitle
    }

    private func lockOverlayDidChange(_ shown: Bool) {
        lockOverlayIsShown = shown
        applyTitleBar()
    }

    // MARK: The sidebar and the inspector

    /// The toolbar's sidebar button. Collapses fully, the system's own
    /// behaviour, and the button then sits beside the traffic lights.
    func toggleWorkspaceSidebar() {
        let collapse = !sidebarItem.isCollapsed
        // The captain's choice wins over the window's: a sidebar they hid
        // stays hidden when the window widens, and one they show gets the
        // room it needs.
        sidebarCollapsedForRoom = false
        if !collapse { makeRoom(sidebarShown: true, inspectorShown: !inspectorItem.isCollapsed) }
        setSidebarCollapsed(collapse, animated: true)
    }

    func setInspectorShown(_ shown: Bool) {
        if shown {
            // The inspector takes its room from the window, then from the
            // sidebar if the window cannot grow enough - never from the
            // column, which a page may need every point of.
            makeRoom(sidebarShown: !sidebarItem.isCollapsed, inspectorShown: true)
            if let window = view.window, !sidebarItem.isCollapsed,
               window.contentRect(forFrameRect: window.frame).width - sidebarPaneWidth
                - WorkspaceInspectorController.width < Self.contentMinimum {
                setSidebarCollapsed(true, animated: false)
                sidebarCollapsedForRoom = true
            }
        }
        HelmMotion.animate(view.window != nil, duration: HelmMotion.moveDuration) {
            self.inspectorItem.animator().isCollapsed = !shown
        }
        toolbar.setInspectorShown(shown)
        if !shown { fitPanesToWindow() }
    }

    /// ⌘⇧D: the sidebar is the whole map, so this opens it if it was
    /// collapsed and puts the keyboard in it.
    @discardableResult
    override func revealDestinationMap() -> Bool {
        if sidebarItem.isCollapsed {
            sidebarCollapsedForRoom = false
            makeRoom(sidebarShown: true, inspectorShown: !inspectorItem.isCollapsed)
            setSidebarCollapsed(false, animated: false)
        }
        sidebar.focusList()
        return true
    }

    /// ⌥⌘S, Go > Toggle Sidebar. On the seven pages with a column of their
    /// own it still toggles that column, exactly as in the floating bar; on
    /// every other page, where it used to do nothing, it shows or hides this
    /// shell's sidebar.
    override func toggleSidebarFromMenu() {
        if workspace.navigator.showingSplitPage != nil {
            super.toggleSidebarFromMenu()
        } else {
            toggleWorkspaceSidebar()
        }
    }

    // MARK: Back and forward

    private func step(_ step: NavigationHistory.Step) {
        guard let target = step == .back ? history.backTarget : history.forwardTarget else { return }
        let before = history.current?.identityKey
        history.expect(step)
        workspace.navigator.navigateToRecentDestination(target)
        history.finishStep(step, arrived: history.current?.identityKey != before)
        toolbar.setHistory(canGoBack: history.canGoBack, canGoForward: history.canGoForward)
    }

    // MARK: Chrome verbs

    override func showToast(_ message: String) {
        // Bottom centre of the content column, not of the whole window - the
        // sidebar is not where a page's confirmation belongs.
        Toast.show(in: contentPane.view, message: message)
    }

    override func quickAccessDidChange(_ configuration: QuickAccessConfiguration) {
        sidebar.reload(pinned: configuration.pinned, sessions: workspace.hosts.sessions)
    }

    // MARK: WorkspaceChrome

    override func workspaceDidShow(_ dest: RailDestination, slot: DestinationSlot) {
        let page = slot.controller as? DaylightDrillActions
        pageController = slot.controller
        pageIsHome = dest == .homeCanvas
        pageTitle = slot.title
        pageSubtitle = page?.drillHeaderSubtitle ?? dest.drillSubtitle
        applyTitleBar()
        // Home has no actions of its own; its spaces sit in the middle
        // instead, where the floating bar showed its pills.
        toolbar.setPageActions(pageIsHome ? [] : page?.drillHeaderActions ?? [])
        toolbar.setSpaces(visible: pageIsHome, selected: workspace.homeCanvas.selectedSpace)
    }

    override func workspaceDidRevealHostPage(_ controller: ConsoleController, label: String) {
        pageController = controller
        pageIsHome = false
        pageTitle = label
        pageSubtitle = "Dedicated host page"
        applyTitleBar()
        toolbar.setPageActions(controller.drillHeaderActions)
        toolbar.setSpaces(visible: false, selected: workspace.homeCanvas.selectedSpace)
    }

    override func workspaceCurrentDestinationDidChange(_ kind: RecentDestinationKind) {
        history.arrive(kind)
        toolbar.setHistory(canGoBack: history.canGoBack, canGoForward: history.canGoForward)
        sidebar.select(kind)
    }

    override func workspaceSubtitleMayHaveChanged() {
        guard let page = pageController as? DaylightDrillActions, let subtitle = page.drillHeaderSubtitle else { return }
        pageSubtitle = subtitle
        applyTitleBar()
    }

    override func workspaceActionsMayHaveChanged() {
        guard !pageIsHome else { return }
        toolbar.setPageActions((pageController as? DaylightDrillActions)?.drillHeaderActions ?? [])
    }

    override func workspaceSessionsDidChange(_ registry: HostSessionRegistry) {
        sidebar.reload(pinned: AppSettings.shared.quickAccess.pinned, sessions: registry)
        statusLine.render(sessions: registry.sessions)
        workspace.refreshShowingHostsLiveSessionState()
    }

    #if FM_SELFTESTS
    var debugStatusLine: WorkspaceStatusLine { statusLine }
    var debugContentPane: NSView { contentPane.view }
    var debugSidebarIsCollapsed: Bool { sidebarItem.isCollapsed }
    var debugInspectorIsCollapsed: Bool { inspectorItem.isCollapsed }
    var debugSidebarWidth: CGFloat { sidebar.view.frame.width }
    /// The split view's first pane, which holds the sidebar panel - what the
    /// tour lab paints under its render of the sidebar.
    var debugSidebarPane: NSView? { splitController.splitView.arrangedSubviews.first }
    var debugHistory: NavigationHistory { history }
    var debugPageTitle: (title: String, subtitle: String) { (pageTitle, pageSubtitle) }
    var debugLockOverlayIsShown: Bool { lockOverlayIsShown }
    func debugStep(_ step: NavigationHistory.Step) { self.step(step) }
    #endif
}

/// The content column: the workspace's body container under the toolbar,
/// and the status line under that.
final class WorkspaceContentPaneController: NSViewController {
    private let body: NSView
    private let statusLine: WorkspaceStatusLine
    private var themeToken: ThemeObservation?

    init(body: NSView, statusLine: WorkspaceStatusLine) {
        self.body = body
        self.statusLine = statusLine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 984, height: 720))
        root.wantsLayer = true
        view = root
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)
        root.addSubview(statusLine)
        NSLayoutConstraint.activate([
            // The toolbar is drawn over the top of this pane (the window has
            // a full-size content view), so the pages start under it.
            body.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: statusLine.topAnchor),
            statusLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusLine.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        // The pane paints the page ground under the toolbar too, which is
        // what the toolbar's glass samples.
        themeToken = ThemeManager.shared.observe { [weak self] theme in
            self?.view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        }
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }
}

/// A root view that says when it reaches a window, which is when a shell can
/// install window-level chrome (a toolbar, a title).
final class WorkspaceShellRootView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
