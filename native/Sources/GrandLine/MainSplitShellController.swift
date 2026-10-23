// Grand Line - native macOS app.
//
// `MainSplitShellController` - the sidebar layout (stages 3 and 4 of the
// modular-shell migration, full review section 5.8 steps 3 and 4).
//
// The window root the captain gets with Settings > Appearance > Window layout
// set to Sidebar:
//
//   root                                  (the window's content view)
//   ├── NSSplitViewController.view
//   │   ├── sidebar   WorkspaceSidebarController - Home and the seventeen
//   │   │             modules, the live sessions, the account menu
//   │   ├── content   the module's large title, Console's session strip, the
//   │   │             workspace's body container (the same
//   │   │             `DestinationMounter`, the same 29 pages), down to
//   │   │             the foot of the window
//   │   └── inspector WorkspaceInspectorController - collapsed, empty until
//   │                 a page has something to show in it
//   └── the lock overlay (LockPresenter), over all three
//
// plus the window's own toolbar (`WorkspaceToolbar`): the crumb that names
// the module, the module's tabs in the middle, the page's own actions, and a
// running focus timer's chip.
//
// **A module is the table's, not a new controller.** Step 4 consolidates the
// 29 destinations into the seventeen modules in the module table only: a
// module's tabs are its pages (`WorkspaceModule.tabs`), a click on one shows
// that page through the navigator, and a deep link to any of the 29 routes
// lands on its page and lights its module and tab. Where a module's tabs are
// one page's own tabs (Tasks, Crew's In flight and Log, Connections' Hosts,
// Keys and Snippets, Kubernetes), the page hides its own control in this
// layout and the toolbar drives it (`ModuleTabHosting`).
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

    /// The column's floor while the inspector shows a page's details: the
    /// inspector takes its width out of the column rather than out of the
    /// sidebar or the window. A page that fills the inspector (Hosts,
    /// Poneglyph) is laid out to fit this, so a selection can open the
    /// inspector at any window width without growing the window, and the
    /// sidebar comes and goes at exactly the same width with or without it.
    static var inspectorColumnMinimum: CGFloat { contentMinimum - WorkspaceInspectorController.width }

    private let splitController = NSSplitViewController()
    let sidebar = WorkspaceSidebarController()
    let inspector = WorkspaceInspectorController()
    /// What the sidebar's badges draw from.
    private lazy var signalsMonitor = WorkspaceSignalsMonitor(workspace: workspace)
    private lazy var contentPane = WorkspaceContentPaneController(body: workspace.content.bodyContainer)
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

    /// The module showing, and the page in it. The crumb and the header name
    /// the module; the header's second line is the page's live subtitle, the
    /// drill header's second line (`chrome.drillTitle`, `chrome.drillSubtitle`).
    private(set) var currentModule: WorkspaceModule = .home
    private var currentRoute: RailDestination = .homeCanvas
    /// Console's dedicated host page is showing, which is not a route.
    private var showingHostPage = false
    private var hostPageLabel = ""
    private var pageSubtitle = ""
    /// The tab each module showed last, so its sidebar row reopens it.
    private var lastTab: [WorkspaceModule: ModuleTab] = [:]
    /// The pages whose own tab control the toolbar has taken over.
    private var adoptedTabHosts: Set<ObjectIdentifier> = []
    /// The pages that switched to their sidebar-layout presentation
    /// (`SidebarLayoutAdopting`).
    private var adoptedPages: Set<ObjectIdentifier> = []
    /// The showing page, when it fills the inspector with its selection.
    private weak var inspectorSource: WorkspaceInspectorSource?
    /// The captain's standing choice to see the selected item's details. The
    /// inspector button and the pane's close button turn it off and back on;
    /// it starts on, so selecting a host or a credential shows its details,
    /// as the prototype does.
    private var inspectorWanted = true
    /// The captain opened the inspector themselves, so it stays open with its
    /// empty state while nothing is selected.
    private var inspectorPinnedOpen = false
    /// The page whose details the open inspector last brought in.
    private var inspectorEntranceSource: ObjectIdentifier?
    /// The showing page, for re-reading its live subtitle and actions.
    private weak var pageController: NSViewController?
    private var lockOverlayIsShown = false
    private var didSettleInitialSidebarWidth = false
    private var themeToken: ThemeObservation?
    private var windowResizeObserver: NSObjectProtocol?
    /// F7's ring popover, hanging off the toolbar's focus chip.
    private var focusPopover: NSPopover?
    private var focusTimerToken: UUID?

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
    private var dayChangeObserver: NSObjectProtocol?
    private var hiddenModulesObserver: NSObjectProtocol?

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
        attachFocusTimer()
        signalsMonitor.onChange = { [weak self] signals in self?.signalsDidChange(signals) }
        signalsMonitor.start()
        signalsDidChange(signalsMonitor.signals)
        recents.configure(registry: workspace.navigator.recentDestinations) { [weak self] kind in
            self?.workspace.navigator.navigateToRecentDestination(kind)
        }
        clipboardHistory.anchor = toolbar.clipboardAnchor
        notificationCenter.onBadgeCountChanged = { [weak self] count in self?.toolbar.setNotificationCount(count) }
        // Console's session strip: the floating bar's own, with its verbs.
        contentPane.sessionStrip.onSelect = { [weak self] id in self?.workspace.hosts.switchToSession(hostID: id) }
        contentPane.sessionStrip.onClose = { [weak self] id in self?.workspace.hosts.confirmEndSession(hostID: id) }
        contentPane.sessionStrip.onAddRequested = { [weak self] in self?.workspace.navigator.show(.hosts) }

        // Home's own space shows the captain's arranged cards in this layout
        // only, set before Home's first render (it mounts eagerly). The
        // floating bar never sets one, so its hub is unchanged.
        applyProfileToHome()
        // R2-UX-01 (b): a profile chosen later (the welcome sheet, Settings)
        // moves Home's default cards with it. A layout the captain arranged
        // is theirs and stays.
        hiddenModulesObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.hiddenModulesDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.applyProfileToHome() }
        workspace.homeCanvas.onCardLayoutChanged = { layout in AppSettings.shared.homeCardLayout = layout }
        workspace.homeCanvas.onCustomizingChanged = { [weak self] _ in self?.refreshModuleChrome() }

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
        // Home's subtitle is the date, so it turns over at midnight.
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.currentModule == .home else { return }
            self.pageSubtitle = Self.homeSubtitle()
            self.refreshModuleChrome()
        }
    }

    /// Home's cards for the captain's profile: their arranged set, or the
    /// profile's own when they have not arranged one.
    private func applyProfileToHome() {
        let canvas = workspace.homeCanvas
        canvas.standardCardLayout = .standard(for: AppSettings.shared.workspaceProfile ?? .operator)
        workspace.homeCanvas.cardLayout = AppSettings.shared.homeCardLayout
    }

    /// Home's header under its title: the day, as the prototype draws it.
    /// Home has no live subtitle of its own - its attention card says what
    /// needs the captain - so the date is the one line that adds something.
    static func homeSubtitle(_ date: Date = Date()) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let windowResizeObserver { NotificationCenter.default.removeObserver(windowResizeObserver) }
        if let dividerDragObserver { NotificationCenter.default.removeObserver(dividerDragObserver) }
        if let scrollerStyleObserver { NotificationCenter.default.removeObserver(scrollerStyleObserver) }
        if let dayChangeObserver { NotificationCenter.default.removeObserver(dayChangeObserver) }
        if let hiddenModulesObserver { NotificationCenter.default.removeObserver(hiddenModulesObserver) }
        if let focusTimerToken { workspace.focusTimer.unobserve(focusTimerToken) }
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
            let floor = self.columnFloor
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
        inspector.setContent(nil)

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
        // so a width is taken as chosen only while this window is handling
        // a mouse drag that is not a live resize of the window itself.
        dividerDragObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitController.splitView, queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.view.window, Self.isDividerDrag(NSApp?.currentEvent, in: window),
                  !self.sidebarItem.isCollapsed, self.sidebar.view.frame.width > 0 else { return }
            self.sidebarThickness = self.sidebar.view.frame.width
        }
    }

    /// Whether `event` is the captain dragging a divider in `window`.
    ///
    /// Not `NSEvent.pressedMouseButtons`, which is the whole machine's mouse:
    /// a button held anywhere - another app, or dragging this window's own
    /// edge narrower - made a resize of the panes read as a choice, and the
    /// sidebar's squeezed width then became the width it came back at.
    /// Measured in `MainSplitShellSelfTest`, about one run in ten on main: the
    /// sidebar came back at 200pt, 203.5pt and 212.5pt because its remembered
    /// width already was that.
    static func isDividerDrag(_ event: NSEvent?, in window: NSWindow) -> Bool {
        guard let event, event.type == .leftMouseDragged, event.window === window else { return false }
        return !window.inLiveResize
    }

    private func buildToolbar() {
        toolbar = WorkspaceToolbar(splitView: splitController.splitView)
        toolbar.onToggleSidebar = { [weak self] in self?.toggleWorkspaceSidebar() }
        toolbar.onBack = { [weak self] in self?.step(.back) }
        toolbar.onForward = { [weak self] in self?.step(.forward) }
        toolbar.onRecents = { [weak self] anchor in self?.recents.togglePanel(under: anchor) }
        toolbar.onSelectTab = { [weak self] index in self?.tabClicked(index) }
        toolbar.onModuleAction = { [weak self] in self?.moduleActionClicked() }
        toolbar.onQuickConnectConsole = { [weak self] in self?.quickConnectConsole() }
        toolbar.onQuickConnectHosts = { [weak self] in self?.revealHostsQuickConnect() }
        toolbar.onToggleTheme = { ThemeManager.shared.toggle() }
        toolbar.onNotifications = { [weak self] anchor in self?.notificationCenter.togglePanel(under: anchor) }
        toolbar.onToggleInspector = { [weak self] in
            guard let self else { return }
            self.setInspectorShown(self.inspectorItem.isCollapsed)
        }
        toolbar.onSearch = { [weak self] in self?.workspace.onSearchTapped?() }
        toolbar.onFocusChip = { [weak self] anchor in self?.toggleFocusPopover(under: anchor) }
    }

    private func wireSidebar() {
        sidebar.onSelectModule = { [weak self] module in self?.openModule(module) }
        sidebar.onSelectSession = { [weak self] id in self?.workspace.hosts.switchToSession(hostID: id) }
        sidebar.onEndSession = { [weak self] id in self?.workspace.hosts.confirmEndSession(hostID: id) }
        // The session strip's "+" opened Hosts; so does Console's own menu.
        sidebar.onConnectHost = { [weak self] in self?.workspace.navigator.show(.hosts) }
        // The account menu is Log Out only (stage 6). Settings is its own
        // sidebar module, and ⌘, and the app menu still reach it.
        sidebar.onLogOut = { [weak self] in self?.requestLogout() }
        sidebar.reload(sessions: workspace.hosts.sessions)
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
        toolbar.setCompact(width < WorkspaceToolbar.compactWidth)
        let floor = columnFloor
        if !sidebarItem.isCollapsed {
            if columnWidthWithSidebar(windowWidth: width) < floor {
                setSidebarCollapsed(true, animated: false)
                sidebarCollapsedForRoom = true
            }
        } else if sidebarCollapsedForRoom, columnWidthWithSidebar(windowWidth: width) >= floor {
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
        #if FM_SELFTESTS
        lastPaneMotionForTests = (pane: "sidebar", collapsed: collapsed, duration: animate ? WorkspaceMotion.paneDuration : nil)
        #endif
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
            // The pin holds for one more main-queue turn. A page re-lays out
            // for the narrower column on that turn (Home's grid,
            // `HomeCanvasController`'s clip-view observer), and until it has,
            // its cards still hold the wider column's widths at `contentTie`
            // (499) - above the sidebar's own 489. Released at once, the
            // sidebar came back squeezed to its 200pt minimum (measured on
            // Home after a 1100-to-1512 round trip).
            if collapsed { release() } else { DispatchQueue.main.async(execute: release) }
            return
        }
        // R2-BUG-02: the eased expand handed back a sidebar squeezed to its
        // 200pt minimum, on every run in the review's lab and 1 in 9 in PR
        // #523's. Instrumented, the cause is not the page: Home had already
        // re-laid out for the narrower column when the pin came off. It is
        // the split view's own held divider position, which an animated
        // uncollapse leaves where the animation started, so releasing the
        // range let the pane fall to its minimum (measured: 236pt at the
        // release, 200pt after the next layout pass). Setting the divider to
        // the pinned width first makes that the position the split holds,
        // and the release then waits the same one turn the plain path does.
        WorkspaceMotion.setCollapsed(sidebarItem, collapsed, animated: true) { [weak self] in
            guard !collapsed, let self else { release(); return }
            self.splitController.splitView.setPosition(self.sidebarPaneWidth, ofDividerAt: 0)
            self.splitController.splitView.layoutSubtreeIfNeeded()
            DispatchQueue.main.async(execute: release)
        }
    }



    /// Widen the window, inside its screen, so the column keeps
    /// `contentMinimum` with the panes the captain just asked for. Only ever
    /// after an explicit request (showing the sidebar or the inspector),
    /// never on navigation.
    private func makeRoom(sidebarShown: Bool, inspectorShown: Bool) {
        guard let window = view.window else { return }
        let floor = inspectorShown && inspectorSource?.inspectorContent != nil
            ? Self.inspectorColumnMinimum : Self.contentMinimum
        let needed = floor + (sidebarShown ? sidebarPaneWidth : 0)
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

    /// The toolbar, or nothing at all while the lock overlay is up - the
    /// crumb and the tabs would name what it is hiding.
    ///
    /// The crumb names the module, so the system title stays out of the
    /// toolbar. It still names the window - for the Window menu, Mission
    /// Control and VoiceOver - and says only the app's name under the lock.
    private func applyTitleBar() {
        guard let window = view.window else { return }
        window.toolbar?.isVisible = !lockOverlayIsShown
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = lockOverlayIsShown
        window.title = lockOverlayIsShown ? AppPaths.displayName : windowTitle
        window.subtitle = ""
    }

    private var windowTitle: String { showingHostPage ? hostPageLabel : currentModule.title }

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

    /// The captain's own request, from the inspector button, the pane's close
    /// button or ⌥⌘I: the only route that may widen the window for it.
    func setInspectorShown(_ shown: Bool) {
        inspectorWanted = shown
        inspectorPinnedOpen = shown
        let details = shown && inspectorSource?.inspectorContent != nil
        if shown {
            if details { contentItem.minimumThickness = Self.inspectorColumnMinimum }
            // The inspector takes its room from the window, then from the
            // sidebar if the window cannot grow enough - never from the
            // column, which a page may need every point of.
            makeRoom(sidebarShown: !sidebarItem.isCollapsed, inspectorShown: true)
            let floor = details ? Self.inspectorColumnMinimum : Self.contentMinimum
            if let window = view.window, !sidebarItem.isCollapsed,
               window.contentRect(forFrameRect: window.frame).width - sidebarPaneWidth
                - WorkspaceInspectorController.width < floor {
                setSidebarCollapsed(true, animated: false)
                sidebarCollapsedForRoom = true
            }
        }
        setInspectorCollapsed(!shown, animated: true)
    }

    /// Collapse or expand the inspector pane, then settle the column's floor
    /// for what it now shows. A lower floor goes on before the pane opens and
    /// a higher one after it has closed, so the column never asks for more
    /// than the window has (gotcha (13)).
    private func setInspectorCollapsed(_ collapsed: Bool, animated: Bool) {
        if !collapsed, columnFloor(inspectorShown: true) < contentItem.minimumThickness {
            contentItem.minimumThickness = columnFloor(inspectorShown: true)
        }
        toolbar.setInspectorState(shown: !collapsed, wanted: inspectorWanted)
        let settle: () -> Void = { [weak self] in
            guard let self else { return }
            self.contentItem.minimumThickness = self.columnFloor
            self.fitPanesToWindow()
        }
        guard inspectorItem.isCollapsed != collapsed else { settle(); return }
        let duration = WorkspaceMotion.setCollapsed(inspectorItem, collapsed, animated: animated && view.window != nil,
                                                    completion: settle)
        #if FM_SELFTESTS
        lastPaneMotionForTests = (pane: "inspector", collapsed: collapsed, duration: duration)
        #endif
        // The prototype's inspector slides in as it opens, whether the
        // captain opened it or a selection did; it closes at once.
        if collapsed {
            inspectorEntranceSource = nil
        } else {
            inspector.playEntrance()
            inspectorEntranceSource = inspector.hostedContentView == nil ? nil : inspectorSource.map(ObjectIdentifier.init)
        }
    }

    /// The column's floor for what the inspector shows now.
    private var columnFloor: CGFloat { columnFloor(inspectorShown: !inspectorItem.isCollapsed) }

    private func columnFloor(inspectorShown: Bool) -> CGFloat {
        inspectorShown && inspector.hostedContentView != nil ? Self.inspectorColumnMinimum : Self.contentMinimum
    }

    /// Match the inspector to the showing page and the captain's choice: the
    /// selected item's details while there is a selection, nothing when there
    /// is none. Runs on every page change and every selection change, and
    /// never grows the window - an automatic change only ever opens the pane
    /// where it fits.
    private func reconcileInspector() {
        guard inspectorItem != nil else { return }
        let wasOpen = !inspectorItem.isCollapsed
        let source = inspectorSource.map(ObjectIdentifier.init)
        let content = inspectorSource?.inspectorContent
        inspector.setContent(content, emptyText: inspectorSource?.inspectorEmptyText)
        var shown = inspectorPinnedOpen || (inspectorWanted && content != nil)
        if shown, let window = view.window {
            let floor = columnFloor(inspectorShown: true)
            let width = window.contentRect(forFrameRect: window.frame).width
            if width - WorkspaceInspectorController.width < floor {
                // Not even the column alone has room beside it: the captain's
                // earlier request does not carry over to this page.
                shown = false
                inspectorPinnedOpen = false
            }
        }
        setInspectorCollapsed(!shown, animated: false)
        // Open already, and now another page's details: the panel arrives
        // again, as the prototype's does when the module changes under it. A
        // new selection on the same page swaps in place.
        guard shown else { return }
        if content != nil {
            if wasOpen, source != inspectorEntranceSource { inspector.playEntrance() }
            inspectorEntranceSource = source
        } else {
            inspectorEntranceSource = nil
        }
    }

    // MARK: Pages in the sidebar layout

    /// The first time a page shows here, it switches to its sidebar-layout
    /// presentation, and a page that fills the inspector starts reporting its
    /// selection to it.
    private func adoptPage(_ controller: NSViewController?) {
        guard let controller else { return }
        if adoptedPages.insert(ObjectIdentifier(controller)).inserted {
            (controller as? SidebarLayoutAdopting)?.adoptSidebarLayout()
            if let source = controller as? WorkspaceInspectorSource {
                source.onInspectorContentChanged = { [weak self, weak source] in
                    guard let self, let source, self.inspectorSource === source else { return }
                    self.reconcileInspector()
                }
                source.onShowInspector = { [weak self, weak source] in
                    guard let self, let source, self.inspectorSource === source else { return }
                    self.setInspectorShown(true)
                }
            }
        }
        inspectorSource = controller as? WorkspaceInspectorSource
    }

    /// ⌘⇧D: the sidebar is the whole map, so this opens it if it was
    /// collapsed and puts the keyboard in it.
    @discardableResult
    override func revealDestinationMap() -> Bool {
        if sidebarItem.isCollapsed {
            sidebarCollapsedForRoom = false
            makeRoom(sidebarShown: true, inspectorShown: !inspectorItem.isCollapsed)
            setSidebarCollapsed(false, animated: true)
        }
        sidebar.focusList()
        return true
    }

    /// ⌥⌘S, Go > Toggle Sidebar. On a page with a column of its own it still
    /// toggles that column, exactly as in the floating bar; everywhere else -
    /// including a page whose column is put away, as Connections' is while the
    /// toolbar draws its tabs - it shows or hides this shell's sidebar.
    override func toggleSidebarFromMenu() {
        if let page = workspace.navigator.showingSplitPage, !page.pageForcesCollapse {
            super.toggleSidebarFromMenu()
        } else {
            toggleWorkspaceSidebar()
        }
    }

    // MARK: Modules and their tabs

    /// A module's sidebar row: the tab it showed last, or its first.
    override func openModule(_ module: WorkspaceModule) {
        if let tab = lastTab[module] ?? module.tabs.first {
            open(tab)
        } else {
            workspace.navigator.show(module.primaryRoute)
        }
    }

    override func openModuleTab(_ tab: ModuleTab) { open(tab) }

    override func hidesPage(_ destination: RailDestination) -> Bool {
        AppSettings.shared.hiddenModules.contains(ModuleTable.module(for: destination))
    }

    /// Show a tab: its page through the navigator, like every other route,
    /// then - for one of a page's own tabs - that tab, through the page.
    private func open(_ tab: ModuleTab) {
        let from = currentTab
        if showingHostPage || currentRoute != tab.route { workspace.navigator.show(tab.route) }
        guard !showingHostPage, currentRoute == tab.route else { return }
        if tab.isPageTab, let host = pageController as? ModuleTabHosting {
            // One of the page's own tabs is not a navigation, so nothing
            // animated it: the page stays and its content changes under it.
            // It takes a navigation's motion instead (`WorkspaceMotion`).
            let switching = host.selectedModuleTabName != tab.name
            if switching { workspace.content.crossfadeOutgoingPage(unless: false) }
            host.selectModuleTab(named: tab.name)
            if switching { playTabEntrance(towardsLater: from.map { isLater(tab, than: $0) } ?? true) }
        }
        refreshModuleChrome()
    }

    /// Whether `tab` sits after `other` in its module's tab row.
    private func isLater(_ tab: ModuleTab, than other: ModuleTab) -> Bool {
        let tabs = currentModule.tabs
        guard let a = tabs.firstIndex(of: tab), let b = tabs.firstIndex(of: other) else { return true }
        return a > b
    }

    /// The showing page arrives the way a navigation's does - from the
    /// trailing side for a later tab, the leading side for an earlier one.
    private func playTabEntrance(towardsLater: Bool) {
        guard let page = pageController?.view else { return }
        workspace.content.animateDestinationEntrance(page, direction: towardsLater ? .drillIn : .back, skip: false)
    }

    private func tabClicked(_ index: Int) {
        let tabs = currentModule.tabs
        guard tabs.indices.contains(index) else { return }
        open(tabs[index])
    }

    /// The tab the showing page stands for.
    private var currentTab: ModuleTab? {
        guard !showingHostPage else { return nil }
        let host = currentRoute == currentModule.pageTabHost ? pageController as? ModuleTabHosting : nil
        return ModuleTable.tab(for: currentRoute, pageTab: host?.selectedModuleTabName)
    }

    /// The first time a page that draws its module's tabs shows here, the
    /// toolbar takes them over: the page hides its own control, and reports
    /// every switch it makes by itself so the toolbar follows.
    private func adoptTabHost(_ host: ModuleTabHosting) {
        guard adoptedTabHosts.insert(ObjectIdentifier(host)).inserted else { return }
        host.setModuleTabControlHidden(true)
        host.onModuleTabChanged = { [weak self, weak host] in
            guard let self, let host, (self.pageController as? ModuleTabHosting) === host else { return }
            self.refreshModuleChrome()
        }
    }

    /// The module's one action: a real verb with no other home in this
    /// layout. Console's is Quick Connect, which has two icons of its own
    /// (`quickConnectConsole` and the Hosts icon's `revealHostsQuickConnect`).
    private func moduleActionClicked() {
        switch currentModule {
        case .home: setHomeCustomizing(!workspace.homeCanvas.isCustomizing)
        case .connections: openFleetLog()
        default: break
        }
    }

    /// Quick Connect's Console icon: Console's current session with the
    /// keyboard in it, and a new one only when there is none (the captain's
    /// Option B - `ConsoleController.focusOrOpenSession`). The Hosts icon
    /// beside it is what Quick Connect always did: Connections' Hosts tab
    /// with its quick-connect field focused, where typing filters the saved
    /// hosts and Return connects to one or to a typed `ssh user@host`.
    private func quickConnectConsole() {
        workspace.navigator.show(.console)
        workspace.console.focusOrOpenSession()
    }

    /// Everything that names or belongs to the showing module: the crumb, the
    /// tabs, the module's action, the header and the session strip.
    private func refreshModuleChrome() {
        guard toolbar != nil else { return }
        let module = currentModule
        if showingHostPage {
            toolbar.setCrumb(group: module.title, module: hostPageLabel)
        } else {
            toolbar.setCrumb(group: module.group?.title, module: module.title)
        }
        // R2-UX-02: Home draws no tabs. Its five spaces were a second map of
        // the app over the sidebar's four groups; Home is its own arranged
        // cards now, and Customize adds any other space's card to them.
        if module == .home {
            toolbar.setTabs([], selected: nil)
        } else {
            let tabs = module.tabs
            let current = currentTab
            if let current { lastTab[module] = current }
            // The page that draws the module's tabs may count what each
            // holds (Connections' hosts, keys and snippets), even while one
            // of the module's other pages is showing.
            let counts = moduleTabHost(for: module)?.moduleTabCounts ?? [:]
            toolbar.setTabs(tabs.map(\.name), counts: tabs.map { counts[$0.name] },
                            selected: current.flatMap { tabs.firstIndex(of: $0) },
                            accessibilityLabel: "\(module.title) tabs")
        }
        switch module {
        case .home:
            let customizing = workspace.homeCanvas.isCustomizing
            toolbar.setModuleAction(title: customizing ? "Done" : "Customize",
                                    symbol: customizing ? "checkmark" : "square.grid.2x2",
                                    tooltip: customizing ? "Finish arranging Home" : "Choose Home's cards, their size and order")
        case .console:
            toolbar.setModuleAction(title: nil)
        case .connections:
            toolbar.setModuleAction(title: "Activity", symbol: "clock.arrow.circlepath",
                                    tooltip: "The captain's log, where every connection is recorded")
        default:
            toolbar.setModuleAction(title: nil)
        }
        toolbar.setQuickConnect(module == .console)
        contentPane.setHeader(title: module.showsHeader ? module.title : nil, subtitle: pageSubtitle)
        contentPane.setSessionStripVisible(module == .console && !workspace.hosts.sessions.isEmpty)
        applyTitleBar()
    }

    /// The mounted page that draws `module`'s tabs, if it has one and it has
    /// mounted.
    private func moduleTabHost(for module: WorkspaceModule) -> ModuleTabHosting? {
        guard let route = module.pageTabHost else { return nil }
        return workspace.content.mounter.slot(for: route.slot)?.controller as? ModuleTabHosting
    }

    /// The showing page's actions in the toolbar: its primary one at the
    /// trailing edge after Search, the rest before the trailing cluster.
    private func applyPageActions(_ controller: NSViewController?, isHome: Bool = false) {
        guard !isHome else {
            toolbar.setPageActions([])
            toolbar.setPrimaryAction(nil)
            return
        }
        let primary = (controller as? WorkspacePrimaryActionProviding)?.workspacePrimaryAction
        let actions = (controller as? DaylightDrillActions)?.drillHeaderActions ?? []
        toolbar.setPageActions(actions.filter { $0 !== primary })
        toolbar.setPrimaryAction(primary)
    }

    /// R2-UX-02: Home has one space in this layout, its own. A route that
    /// still names another space (a ⌘K verb, a notification, an older saved
    /// session) lands on Home's own cards rather than on a filter nothing on
    /// screen can switch back from.
    override func selectSpace(_ space: DaylightSpace) {
        super.selectSpace(.overview)
    }

    /// Home's Customize mode, on Home's own space - the one whose cards are
    /// the captain's to arrange.
    func setHomeCustomizing(_ customizing: Bool) {
        if customizing, workspace.homeCanvas.selectedSpace != .overview { selectSpace(.overview) }
        workspace.homeCanvas.setCustomizing(customizing)
        refreshModuleChrome()
    }

    // MARK: Badges

    private func signalsDidChange(_ signals: WorkspaceSignals) {
        sidebar.setSignals(signals)
    }

    // MARK: F7 - the focus timer chip

    /// Follow the app's one `FocusTimerController` into the toolbar's chip.
    /// Every button in the popover acts on the controller directly - the
    /// floating bar's own contract.
    private func attachFocusTimer() {
        // GL-09 / §5.1(b): a popover left open when the app lock fires stays
        // readable and interactive above the overlay, so it is closed on the
        // way in - it names the captain's current task.
        AppLockGate.shared.registerLockDismissiblePopover(owner: self) { [weak self] in self?.focusPopover }
        focusTimerToken = workspace.focusTimer.observe { [weak self] in self?.renderFocusChip() }
        renderFocusChip()
    }

    /// Repaint the chip from the live session, and take it out of the
    /// toolbar entirely when nothing is running.
    private func renderFocusChip() {
        let timer = workspace.focusTimer
        guard let session = timer.session else {
            toolbar.setFocusChip(nil)
            // The popover is about a session that no longer exists.
            focusPopover?.performClose(nil)
            focusPopover = nil
            return
        }
        // Read through the controller, never off a `Date()` of this shell's
        // own - see `FocusTimerController.fraction` for why.
        toolbar.setFocusChip((fraction: timer.fraction ?? 0, countdown: timer.countdownText ?? "0:00",
                              title: session.taskTitle, paused: timer.isPaused))
    }

    private func toggleFocusPopover(under anchor: NSView) {
        let timer = workspace.focusTimer
        // An anchor out of any window (a chip the toolbar has not placed)
        // is no place to hang a popover - AppKit raises on it.
        guard timer.isRunning, anchor.window != nil else { return }
        if let focusPopover, focusPopover.isShown {
            focusPopover.performClose(nil)
            self.focusPopover = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        // ThemeManager's checklist item 2: the popover's own chrome resolves
        // system semantic colours, so it needs the theme's light/dark mode.
        popover.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        let panel = FocusTimerPanelController(timer: timer)
        // B28: the panel closes *this* popover, never a window.
        panel.onRequestClose = { [weak self, weak popover] in
            popover?.performClose(nil)
            self?.focusPopover = nil
        }
        popover.contentViewController = panel
        // Under the chip: the toolbar is the top edge of the window.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
        focusPopover = popover
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

    // MARK: WorkspaceChrome

    override func workspaceDidShow(_ dest: RailDestination, slot: DestinationSlot) {
        let page = slot.controller as? DaylightDrillActions
        pageController = slot.controller
        currentRoute = dest
        showingHostPage = false
        currentModule = ModuleTable.module(for: dest)
        pageSubtitle = page?.drillHeaderSubtitle ?? dest.drillSubtitle
        if dest == .homeCanvas, pageSubtitle.isEmpty { pageSubtitle = Self.homeSubtitle() }
        adoptPage(slot.controller)
        if dest == currentModule.pageTabHost, let host = slot.controller as? ModuleTabHosting { adoptTabHost(host) }
        // Home has no actions of its own; its spaces sit in the middle
        // instead, where the floating bar showed its pills.
        applyPageActions(slot.controller, isHome: dest == .homeCanvas)
        refreshModuleChrome()
        reconcileInspector()
    }

    override func workspaceDidRevealHostPage(_ controller: ConsoleController, label: String) {
        pageController = controller
        showingHostPage = true
        hostPageLabel = label
        currentModule = .console
        pageSubtitle = "Dedicated host page"
        inspectorSource = nil
        applyPageActions(controller)
        refreshModuleChrome()
        reconcileInspector()
    }

    override func workspaceCurrentDestinationDidChange(_ kind: RecentDestinationKind) {
        history.arrive(kind)
        toolbar.setHistory(canGoBack: history.canGoBack, canGoForward: history.canGoForward)
        sidebar.select(kind)
    }

    override func workspaceSubtitleMayHaveChanged() {
        guard let page = pageController as? DaylightDrillActions, let subtitle = page.drillHeaderSubtitle else { return }
        pageSubtitle = subtitle
        contentPane.setHeader(title: currentModule.showsHeader ? currentModule.title : nil, subtitle: pageSubtitle)
    }

    override func workspaceActionsMayHaveChanged() {
        guard currentModule != .home else { return }
        applyPageActions(pageController)
    }

    override func workspaceCrewDidRead() {
        signalsMonitor.crewDidRead()
    }

    override func workspaceSessionsDidChange(_ registry: HostSessionRegistry) {
        // The signals first, so the rows the reload below builds carry
        // Console's new count.
        signalsMonitor.sessionsDidChange(registry.sessions)
        sidebar.reload(sessions: registry)
        contentPane.sessionStrip.render(registry)
        contentPane.setSessionStripVisible(currentModule == .console && !registry.sessions.isEmpty)
        workspace.refreshShowingHostsLiveSessionState()
    }

    #if FM_SELFTESTS
    /// The last time a pane collapsed or expanded: which, which way, and the
    /// duration it eased over (nil when it landed at once).
    private(set) var lastPaneMotionForTests: (pane: String, collapsed: Bool, duration: TimeInterval?)?
    var debugFocusPopoverIsShown: Bool { focusPopover?.isShown ?? false }
    var debugSignalsMonitor: WorkspaceSignalsMonitor { signalsMonitor }
    var debugInspector: WorkspaceInspectorController { inspector }
    var debugContentPane: NSView { contentPane.view }
    var debugBodyContainer: NSView { workspace.content.bodyContainer }
    var debugSidebarIsCollapsed: Bool { sidebarItem.isCollapsed }
    var debugInspectorIsCollapsed: Bool { inspectorItem.isCollapsed }
    var debugColumnMinimum: CGFloat { contentItem.minimumThickness }
    /// The inspector back at its launch state: wanted, not held open.
    func debugResetInspectorPreference() {
        inspectorWanted = true
        inspectorPinnedOpen = false
        reconcileInspector()
    }
    var debugInspectorSource: WorkspaceInspectorSource? { inspectorSource }
    var debugSidebarWidth: CGFloat { sidebar.view.frame.width }
    /// The split view's first pane, which holds the sidebar panel - what the
    /// tour lab paints under its render of the sidebar.
    var debugSidebarPane: NSView? { splitController.splitView.arrangedSubviews.first }
    var debugHistory: NavigationHistory { history }
    /// The module header as drawn, or nil when the module has none.
    var debugHeader: (title: String, subtitle: String)? {
        contentPane.header.isHidden ? nil : (contentPane.header.debugTitle, contentPane.header.debugSubtitle)
    }
    var debugSessionStripIsShown: Bool { !contentPane.sessionStrip.isHidden }
    var debugSessionStrip: SessionStripView { contentPane.sessionStrip }
    /// The content pane's own views, front to back - what the guard against
    /// a strip under the body counts.
    var debugContentPaneSubviews: [NSView] { contentPane.view.subviews }
    var debugCurrentTab: ModuleTab? { currentTab }
    var debugLastTab: [WorkspaceModule: ModuleTab] { lastTab }
    func debugOpenModule(_ module: WorkspaceModule) { openModule(module) }
    func debugClickTab(_ index: Int) { tabClicked(index) }
    func debugModuleAction() { moduleActionClicked() }
    var debugLockOverlayIsShown: Bool { lockOverlayIsShown }
    func debugStep(_ step: NavigationHistory.Step) { self.step(step) }
    #endif
}

/// The content column, top to bottom: the module's large title, Console's
/// session strip, and the workspace's body container, which runs to the foot
/// of the window. The layout drew a status strip under the body until the
/// captain had it removed from every module; its readouts live in the
/// sidebar's badges, Console's session strip, Home's Claude card, the Tasks
/// sync pill and the toolbar's focus chip.
final class WorkspaceContentPaneController: NSViewController {
    private let body: NSView
    let header = WorkspaceModuleHeader()
    /// The floating bar's session strip, on Console only: one chip per live
    /// session, the same view and the same three verbs.
    let sessionStrip = SessionStripView()
    /// The header and the strip, each in layout only while it shows - a
    /// stack that detaches its hidden views, so neither needs a height
    /// constraint fighting its own content to collapse.
    private let topStack = NSStackView()
    private var themeToken: ThemeObservation?

    init(body: NSView) {
        self.body = body
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 984, height: 720))
        root.wantsLayer = true
        view = root
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = 0
        topStack.detachesHiddenViews = true
        topStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, sessionStrip] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = true
            topStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: topStack.widthAnchor).isActive = true
        }
        sessionStrip.heightAnchor.constraint(equalToConstant: SessionStripView.height).isActive = true
        // With both hidden the stack has no content to measure, so nothing
        // else says how tall it is. Below the window's 500 (gotcha (13)), and
        // below every arranged view's own height, so it only ever settles the
        // empty case.
        let collapsed = topStack.heightAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(topStack)
        root.addSubview(body)
        NSLayoutConstraint.activate([
            // The toolbar is drawn over the top of this pane (the window has
            // a full-size content view), so everything starts under it.
            topStack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            topStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: topStack.bottomAnchor),
            // No module draws a column of its own beside the body: Knowledge's
            // tree was the one, and the captain had it removed in stage 7.
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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

    /// The module's title and its page's subtitle, or no header at all.
    func setHeader(title: String?, subtitle: String) {
        _ = view
        if let title { header.configure(title: title, subtitle: subtitle) }
        header.isHidden = title == nil
    }

    func setSessionStripVisible(_ visible: Bool) {
        _ = view
        sessionStrip.isHidden = !visible
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
