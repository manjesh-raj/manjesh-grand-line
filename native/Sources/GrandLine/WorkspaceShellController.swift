// Grand Line - native macOS app.
//
// `WorkspaceShellController` - the window's root content view controller,
// whichever layout the captain chose.
//
// Stage 3 of the modular-shell migration (full review section 5.8, step 3)
// adds a second shell beside the floating bar, so there are two layouts now:
//
//   - `AppShellController` - the floating bar, the space pills and the drill
//     header. Unchanged, and still a choice in Settings > Appearance.
//   - `MainSplitShellController` - a sidebar, a window toolbar, the content
//     column, and an inspector. The default since PR #523.
//
// A change of layout is applied the next time the app opens.
//
// Both host the same `Workspace`: the same 29 pages, the same
// `DestinationMounter`, the same host pages, the same lock. This class is
// what they share - the workspace itself, the window's ground, and the API
// the app delegate, the menus and the suites call on "the shell". Until
// stage 3 that API lived on `AppShellController` and forwarded to the
// workspace; it moved here unchanged, so it works whichever shell is showing.
//
// What differs between the two is the chrome, so a shell subclass overrides
// the `WorkspaceChrome` hooks (what to draw when the workspace navigates) and
// the handful of chrome verbs below that only a shell can answer: where a
// toast lands, where the clipboard panel drops from, how the quick-access
// pins are drawn, and whether ⌘⇧D's map is a panel or the sidebar.

import AppKit

/// Which shell the main window hosts. Read once at launch, so a change in
/// Settings applies the next time the app opens - see
/// `AppSettings.workspaceLayout`.
enum WorkspaceLayout: String, CaseIterable {
    /// The floating bar with its space pills and drill header. Still a
    /// first-class choice in Settings, never removed.
    case floatingBar
    /// The sidebar, window toolbar, content column and inspector - the default.
    case sidebar

    /// The layout a fresh install gets, and anyone who never chose one. The
    /// one place the default is spelled: `AppSettings.workspaceLayout` falls
    /// back to it, and so does the tour lab through that setting, so a
    /// second literal cannot drift from it. `SplitShellModelSelfTest`'s
    /// `checkTheDefaultIsTheSidebar` fails if it reverts.
    static let standard: WorkspaceLayout = .sidebar

    var title: String {
        switch self {
        case .floatingBar: return "Floating bar"
        case .sidebar: return "Sidebar"
        }
    }
}

class WorkspaceShellController: NSViewController, WorkspaceChrome {

    /// Everything this shell hosts - see this file's header.
    let workspace: Workspace

    private var chromeTextScaleObservation: ChromeTextScaleObservation?

    /// The account menu's Log Out, once confirmed - forwarded to the app
    /// delegate's `AppLockController`, which is what actually flips the lock
    /// state, matching how host-editor presentation is forwarded rather than
    /// owned here.
    var onLogoutRequested: (() -> Void)?

    /// Raised when something asks for the all-destinations map. Owned by
    /// the app delegate, which owns the overlay itself - the same shape as
    /// `onSearchTapped`.
    ///
    /// **Assigned in `main.swift`, beside `onSearchTapped`, and it must stay
    /// assigned**: its one caller is ⌘K's "All Destinations…" verb, and an
    /// unassigned optional closure here is a palette row that silently does
    /// nothing. That is exactly what shipped - the assignment was missing
    /// from the first, and the bar's overflow menu carried a second row with
    /// the same defect until
    /// `fm/grandline-remove-dead-all-destinations-overflow` removed it.
    /// `NavigationCoherenceSelfTest.checkTheMapIsActuallyReachable` guards the
    /// assignment itself (a source guard - the behaviour needs a real
    /// `AppDelegate`, and `NSApp` is nil in a headless suite), because nothing
    /// about a dead closure is visible in a diff or on screen.
    var onShowAllDestinations: (() -> Void)?

    /// `hostsPanel` and `settings` are autoclosures since PERF-01: the app
    /// delegate (and every suite) still writes the page's construction at the
    /// call site, but it runs on the page's first use rather than here.
    ///
    /// `required` so the app delegate can build whichever shell the setting
    /// names through one call (`layout.shellType.init(...)`).
    required init(
        hostsPanel: @autoclosure @escaping () -> HostsController, console: ConsoleController,
        settings: @autoclosure @escaping () -> SettingsController,
        hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, shiftStore: ShiftStore,
        dictationStore: DictationStore, commandLibraryStore: CommandLibraryStore,
        scheduleStore: ScheduleStore,
        docsRunbookStore: DocsRunbookStore = DocsRunbookStore(),
        makeHostConsole: @escaping () -> ConsoleController
    ) {
        // T-14d: the launch interval Instruments reads, ended as the last
        // line of this initialiser - see `LaunchSignposts.swift`. The stores
        // and the eager pages it measures are built by `Workspace`, inside
        // the same interval.
        let initInterval = LaunchSignposts.begin("WorkspaceShellController.init")
        self.workspace = Workspace(
            hostsPanel: hostsPanel, console: console, settings: settings,
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: shiftStore,
            dictationStore: dictationStore, commandLibraryStore: commandLibraryStore,
            scheduleStore: scheduleStore, docsRunbookStore: docsRunbookStore,
            makeHostConsole: makeHostConsole)
        super.init(nibName: nil, bundle: nil)
        workspace.chrome = self
        workspace.content.parentController = self
        LaunchSignposts.end("WorkspaceShellController.init", initInterval)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: The window's ground and the chrome text scale

    /// What both shells' `loadView` does once its root view is `view`: paint
    /// the window's ground and turn a chrome-text-scale change into the
    /// app-wide repaint.
    ///
    /// The ground has to paint. Before Daylight Phase 2 the rail and the top
    /// bar between them covered every pixel of the root; the floating bar
    /// deliberately does not - there is a real 20pt band of ground between
    /// the bar's bottom edge and the body container, which is what makes the
    /// bar read as floating rather than as a header strip - and the sidebar
    /// shell's glass sidebar and toolbar sample whatever is under them. A
    /// layer-backed view with no explicit background paints nothing at all
    /// (AGENTS.md gotcha (8)), so that ground would show the window's own
    /// backing through it.
    ///
    /// The shell is an app-lifetime singleton, so the theme token is discarded
    /// like every other such observer here.
    func paintGroundAndFollowTextScale() {
        _ = ThemeManager.shared.observe { [weak self] theme in
            self?.view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        }

        // GL-32: one place turns a chrome-text-scale change into the app-wide
        // repaint every page already knows how to do. See
        // `ThemeManager.reapplyCurrentTheme`'s own note on why this rides the
        // theme observer rather than adding a second fan-out of its own. The
        // token is kept for the shell's lifetime - it is the window's root and
        // lives for the process.
        chromeTextScaleObservation = ChromeTextScale.shared.observe { [weak self] _ in
            guard let self, self.isViewLoaded else { return }
            ThemeManager.shared.reapplyCurrentTheme()
            // B33: the theme re-fire above reaches every font a page derives
            // inside its own `applyTheme`. This second pass reaches the ones
            // it cannot - a label built once in `loadView` and only ever
            // re-coloured afterwards - by re-deriving from the recipe the
            // label itself carries. It runs *after* the re-fire so a page
            // that rebuilt its rows is not walked twice over stale views.
            // See `HelmTextScale.swift` for why the recipe travels with the
            // label rather than being re-written at 150 call sites.
            HelmTextScale.reapply(in: self.view)
            self.view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: WorkspaceChrome - overridden by each shell

    func workspaceDidShow(_ dest: RailDestination, slot: DestinationSlot) {}
    func workspaceDidRevealHostPage(_ controller: ConsoleController, label: String) {}
    func workspaceCurrentDestinationDidChange(_ kind: RecentDestinationKind) {}
    func workspaceSubtitleMayHaveChanged() {}
    func workspaceActionsMayHaveChanged() {}
    func workspaceSessionsDidChange(_ registry: HostSessionRegistry) {}
    func workspaceCrewDidRead() {}
    func workspaceKeyViewLoopMayHaveChanged() {}
    var workspaceWindow: NSWindow? { view.window }

    // MARK: The chrome verbs each shell answers

    /// Whether the window's own title bar names the page. The sidebar shell
    /// draws a standard toolbar, so the window title and subtitle are the
    /// page's name and live subtitle; the floating bar hides the title bar,
    /// and the app delegate composes "Grand Line - <page>" for Mission
    /// Control and the Window menu instead.
    var namesThePageInTheTitleBar: Bool { false }

    /// A transient confirmation (GL-30) - "Fix 5: a host save closes its own
    /// (separate) editor window immediately, so the confirmation has to live
    /// somewhere that's still around afterward - the main window, regardless
    /// of which destination happens to be showing."
    func showToast(_ message: String) {
        Toast.show(in: view, message: message)
    }

    /// The account menu's Log Out, and the Hosts sidebar's user row: one
    /// confirmation (`HelmConfirm.confirmLogout`), then the app delegate's
    /// lock. The floating bar routes this through its own avatar panel.
    func requestLogout() {
        guard HelmConfirm.confirmLogout() else { return }
        onLogoutRequested?()
    }

    /// ⌘⇧D. The sidebar shell's sidebar *is* the map, so it reveals and
    /// focuses it and answers `true`; the floating bar answers `false` and the
    /// app delegate opens the `AllDestinationsOverlay` panel instead.
    @discardableResult
    func revealDestinationMap() -> Bool { false }

    // MARK: Spaces (Daylight §5.3)

    /// A space was picked: land on the canvas if we are not already there,
    /// then filter it.
    ///
    /// Both halves live in the shell rather than in either component, which
    /// is what keeps §5.3's rule true from both directions - the chrome does
    /// not know what a canvas is, and the canvas does not know how to
    /// navigate. The floating bar also lights its pill first.
    func selectSpace(_ space: DaylightSpace) {
        workspace.homeCanvas.select(space: space)
        workspace.navigator.show(.homeCanvas)
    }

    /// The canvas itself, for a caller that wants the hub without changing
    /// the space (the app delegate's launch landing).
    @objc func showHomeCanvas() { workspace.navigator.show(.homeCanvas) }

    /// The Go menu's five space items (⌘1-⌘5) - UX4's "give ⌘1-⌘5 to the
    /// spaces (the original Daylight spec)".
    ///
    /// This wrapper existed once and was deleted with the View menu
    /// (`fm/grandline-console-tabs-restore-tabmenu-fix` - see `buildMenu`'s
    /// own note). It comes back in the same shape it had: the menu carries the
    /// 1-based `shortcutIndex` in its tag, and `selectSpace(_:)` - which the
    /// bar's own pills call - does the work, so a menu item and a pill click
    /// cannot diverge.
    @objc func selectSpaceByShortcut(_ sender: NSMenuItem) {
        guard let space = DaylightSpace.allCases.first(where: { $0.shortcutIndex == sender.tag }) else { return }
        selectSpace(space)
    }

    /// The Go menu's per-destination rows - UX3's "a 'Go' menu listing every
    /// destination".
    ///
    /// Keyed off the destination's own raw value in `representedObject`, the
    /// same shape the bar's quick-access overflow menu uses, so neither has to
    /// hold a parallel array of tags.
    @objc func selectDestinationFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let destination = RailDestination(rawValue: raw) else { return }
        workspace.navigator.show(destination)
    }

    /// R2-UX-02: the sidebar layout's Go menu rows (`WorkspaceGoMenu`) - a
    /// module, as its sidebar row opens it, and one of a module's tabs.
    @objc func selectModuleFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let module = WorkspaceModule(rawValue: raw) else { return }
        openModule(module)
    }

    @objc func selectModuleTabFromMenu(_ sender: NSMenuItem) {
        guard let tab = WorkspaceGoMenu.tab(from: sender.representedObject) else { return }
        openModuleTab(tab)
    }

    /// A module's page. The sidebar layout reopens the tab the module showed
    /// last, as its sidebar row does; a shell with no modules shows the
    /// module's first page.
    func openModule(_ module: WorkspaceModule) { workspace.navigator.show(module.primaryRoute) }

    /// One of a module's tabs. The sidebar layout selects a page's own tab
    /// through the page; a shell with no toolbar tabs shows the tab's page.
    func openModuleTab(_ tab: ModuleTab) { workspace.navigator.show(tab.route) }

    // MARK: The configurable quick-access pins (UX1/UX2)

    /// Pin or unpin `destination`, persist the result, and redraw the pins.
    ///
    /// The one write path. `AppSettings.quickAccess` is the store of record and
    /// a shell holds only a cache of what it drew, so a caller that wrote the
    /// setting directly would leave the pins stale until the next launch.
    func toggleQuickAccessPin(_ destination: RailDestination) {
        let next = AppSettings.shared.quickAccess.toggling(destination)
        AppSettings.shared.quickAccess = next
        quickAccessDidChange(next)
    }

    /// Whether `destination` is currently pinned - what a context menu reads
    /// to decide between "Pin" and "Unpin".
    func isQuickAccessPinned(_ destination: RailDestination) -> Bool {
        AppSettings.shared.quickAccess.contains(destination)
    }

    /// Redraw the pins from `configuration`. The floating bar redraws its
    /// shortcut row; the sidebar shell redraws its Pinned section.
    func quickAccessDidChange(_ configuration: QuickAccessConfiguration) {}

    // MARK: Clipboard history (F3)

    /// The shell's one `ClipboardHistoryController` (and so the one
    /// `ClipboardHistoryStore`, GL-23). The floating bar owns it on the bar,
    /// which decides where its panel drops down from; the sidebar shell owns
    /// its own, anchored under the toolbar.
    var clipboardHistoryController: ClipboardHistoryController? { nil }

    /// ⌘⇧V. The menu's way in, and the one place the "paste it back" toast
    /// is worded.
    @objc func toggleClipboardHistory() {
        clipboardHistoryController?.toggle()
    }

    /// PF2: drain the clipboard history's off-main write before the process
    /// goes away. The app delegate is where `applicationWillTerminate` lives.
    func shutdownClipboardHistory() {
        clipboardHistoryController?.shutdown()
    }

    /// Arm the capture loop. Called once, from `main.swift` - never at init;
    /// see `ClipboardHistoryController.startCapturing()` for why.
    func startClipboardHistoryCapture() {
        guard let clipboardHistory = clipboardHistoryController else { return }
        clipboardHistory.startCapturing()
        clipboardHistory.onPasted = { [weak self] _ in
            self?.showToast("Copied - \u{2318}V to paste it")
        }
    }

    // MARK: The workspace's API, forwarded
    //
    // Everything below is a one-line forward to the part that does the work
    // since stage 2 (see `Workspace.swift`'s header). The app delegate, the
    // menu and the suites call these on whichever shell is showing.

    // The stores other surfaces read.
    var codePreviewStore: CodePreviewStore { workspace.codePreviewStore }
    var readingListStore: ReadingListStore { workspace.readingListStore }
    var notebookStore: NotebookStore { workspace.notebookStore }
    var stickyBoardStore: StickyBoardStore { workspace.stickyBoardStore }
    var shiftStore: ShiftStore { workspace.shiftStore }
    var focusTimer: FocusTimerController { workspace.focusTimer }
    var windowOverflowGuard: WindowOverflowGuard { workspace.windowOverflowGuard }

    static func consolePeekRow(name: String,
                               running: Bool,
                               lastExit: TabModel.ExitOutcome) -> HelmModulePeekRow {
        Workspace.consolePeekRow(name: name, running: running, lastExit: lastExit)
    }

    // The callbacks the app delegate wires.
    var onPresentHostEditor: ((Host?) -> Void)? {
        get { workspace.onPresentHostEditor } set { workspace.onPresentHostEditor = newValue }
    }
    var onSendCommandToHosts: ((DevOpsCommand, [String: String], String) -> Void)? {
        get { workspace.onSendCommandToHosts } set { workspace.onSendCommandToHosts = newValue }
    }
    var onKeyChordChanged: ((KeyChord) -> Void)? {
        get { workspace.onKeyChordChanged } set { workspace.onKeyChordChanged = newValue }
    }
    var onTerminalShortcutsChanged: ((TerminalShortcutSet) -> Void)? {
        get { workspace.onTerminalShortcutsChanged } set { workspace.onTerminalShortcutsChanged = newValue }
    }
    var onQuickCaptureShortcutChanged: ((KeyChord) -> Void)? {
        get { workspace.onQuickCaptureShortcutChanged } set { workspace.onQuickCaptureShortcutChanged = newValue }
    }
    var onDictationLocalWhisperChanged: ((Bool) -> Void)? {
        get { workspace.onDictationLocalWhisperChanged } set { workspace.onDictationLocalWhisperChanged = newValue }
    }
    var onSearchTapped: (() -> Void)? {
        get { workspace.onSearchTapped } set { workspace.onSearchTapped = newValue }
    }
    var onRunSnippet: ((Snippet) -> Void)? {
        get { workspace.onRunSnippet } set { workspace.onRunSnippet = newValue }
    }
    var onSessionStateChanged: (() -> Void)? {
        get { workspace.navigator.onSessionStateChanged } set { workspace.navigator.onSessionStateChanged = newValue }
    }
    var onCurrentDestinationChanged: ((String?) -> Void)? {
        get { workspace.navigator.onCurrentDestinationChanged }
        set { workspace.navigator.onCurrentDestinationChanged = newValue }
    }
    var onReconnectHost: ((UUID) -> Bool)? {
        get { workspace.navigator.onReconnectHost } set { workspace.navigator.onReconnectHost = newValue }
    }
    var onUnlocked: (() -> Void)? {
        get { workspace.lock.onUnlocked } set { workspace.lock.onUnlocked = newValue }
    }
    var onLockStateChanged: ((Bool) -> Void)? {
        get { workspace.lock.onLockStateChanged } set { workspace.lock.onLockStateChanged = newValue }
    }

    // The lock.
    func showLock(reason: AppLockReason) { workspace.lock.showLock(reason: reason) }
    func openWithoutLock() { workspace.lock.openWithoutLock() }
    func attemptUnlockFromCompactMode(password: String, completion: @escaping (Bool) -> Void) {
        workspace.lock.attemptUnlockFromCompactMode(password: password, completion: completion)
    }
    static var appPasswordRetryBaseDelay: TimeInterval { LockPresenter.appPasswordRetryBaseDelay }
    static var appPasswordRetryCeiling: TimeInterval { LockPresenter.appPasswordRetryCeiling }
    static func appPasswordRetryDelay(attempt: Int) -> TimeInterval { LockPresenter.appPasswordRetryDelay(attempt: attempt) }

    // The body area's transition.
    typealias TransitionDirection = WorkspaceContent.TransitionDirection
    static var destinationTransitionDuration: TimeInterval { WorkspaceContent.destinationTransitionDuration }
    static var destinationTransitionOffset: CGFloat { WorkspaceContent.destinationTransitionOffset }
    var pageCrossfade: PageCrossfade? {
        get { workspace.content.pageCrossfade } set { workspace.content.pageCrossfade = newValue }
    }
    #if FM_SELFTESTS
    var lastTransitionForTests: (direction: TransitionDirection, skipped: Bool,
                                 reducedMotion: Bool, entryOffset: CGFloat)? {
        workspace.content.lastTransitionForTests
    }
    #endif

    // Navigation.
    func show(_ dest: RailDestination) { workspace.navigator.show(dest) }
    var recentDestinations: RecentDestinations { workspace.navigator.recentDestinations }
    var currentContextTitle: String? { workspace.navigator.currentContextTitle }
    var isTerminalDestinationShowing: Bool { workspace.navigator.isTerminalDestinationShowing }
    var contextualNewAction: ContextualNewAction { workspace.navigator.contextualNewAction }
    func runInConsole(label: String, command: String, completion: ((Bool) -> Void)? = nil) {
        workspace.navigator.runInConsole(label: label, command: command, completion: completion)
    }
    func captureSessionState() -> SessionRestoreState { workspace.navigator.captureSessionState() }
    func restoreTabs(from state: SessionRestoreState) { workspace.navigator.restoreTabs(from: state) }
    @discardableResult
    func restoreDestination(from state: SessionRestoreState) -> Bool {
        workspace.navigator.restoreDestination(from: state)
    }
    func activeTabShortcutTarget() -> TabShortcutHandling? { workspace.navigator.activeTabShortcutTarget() }
    func forgetRecentHost(id: UUID) { workspace.navigator.forgetRecentHost(id: id) }
    func showShiftDestination() { workspace.navigator.showShiftDestination() }
    func openFleetLog() { workspace.navigator.openFleetLog() }
    func openShiftTask(id: String) { workspace.navigator.openShiftTask(id: id) }
    func openShiftFollowUp(id: String) { workspace.navigator.openShiftFollowUp(id: id) }
    func openShiftProject(id: String) { workspace.navigator.openShiftProject(id: id) }
    func openKubernetes(hostID: UUID, showTail: Bool) { workspace.navigator.openKubernetes(hostID: hostID, showTail: showTail) }
    func openRunbook(id: String) { workspace.navigator.openRunbook(id: id) }
    func openReadingListLink(id: String) { workspace.navigator.openReadingListLink(id: id) }
    func openNotebookPage(id: String) { workspace.navigator.openNotebookPage(id: id) }
    func openPostmortem(id: String) { workspace.navigator.openPostmortem(id: id) }
    func openDestinationForCrew(_ dest: RailDestination, hint: String?) {
        workspace.navigator.openDestinationForCrew(dest, hint: hint)
    }
    func openStickyNote(id: String) { workspace.navigator.openStickyNote(id: id) }
    func openCodeSnippet(named name: String) { workspace.navigator.openCodeSnippet(named: name) }
    func openCommandLibraryCommand(id: String) { workspace.navigator.openCommandLibraryCommand(id: id) }
    func sendCommandToConsole(_ text: String) { workspace.navigator.sendCommandToConsole(text) }
    func openLogAnalyzer(with capture: LogTerminalCapture, hostLabel: String) {
        workspace.navigator.openLogAnalyzer(with: capture, hostLabel: hostLabel)
    }
    func updateToolFromNotification(_ toolID: String) { workspace.navigator.updateToolFromNotification(toolID) }
    func syncForkFromNotification(_ repoFullName: String) { workspace.navigator.syncForkFromNotification(repoFullName) }

    // The menu's verbs. Their selectors are what `buildMenu` names, so they
    // stay on the shell and forward - whichever shell is showing.
    @objc func newContextualItem() { workspace.navigator.newContextualItem() }
    @objc func newSavedLinkFromMenu() { workspace.navigator.newSavedLinkFromMenu() }
    @objc func newNotebookPageFromMenu() { workspace.navigator.newNotebookPageFromMenu() }
    @objc func newStickyNoteFromMenu() { workspace.navigator.newStickyNoteFromMenu() }
    @objc func newCodeSnippetFromMenu() { workspace.navigator.newCodeSnippetFromMenu() }
    @objc func runCodeSnippetFromMenu() { workspace.navigator.runCodeSnippetFromMenu() }
    @objc func toggleSidebarFromMenu() { workspace.navigator.toggleSidebarFromMenu() }
    @objc func toggleCodePreviewSidebarFromMenu() { workspace.navigator.toggleCodePreviewSidebarFromMenu() }
    @objc func captureScreenRegionFromMenu() { workspace.navigator.captureScreenRegionFromMenu() }
    @objc func copyWhiteboardImageFromMenu() { workspace.navigator.copyWhiteboardImageFromMenu() }
    @objc func newCredentialFromMenu() { workspace.navigator.newCredentialFromMenu() }
    @objc func newScheduleFromMenu() { workspace.navigator.newScheduleFromMenu() }
    @objc func newCommandFromMenu() { workspace.navigator.newCommandFromMenu() }
    @objc func newRunbookFromMenu() { workspace.navigator.newRunbookFromMenu() }
    @objc func lockPoneglyph() { workspace.navigator.lockPoneglyph() }
    @objc func revealHostsQuickConnect() { workspace.navigator.revealHostsQuickConnect() }
    @objc func activateConsoleFind() { workspace.navigator.activateConsoleFind() }
    @objc func selectSettings() { workspace.navigator.selectSettings() }
    @objc func selectHosts() { workspace.navigator.selectHosts() }
    @objc func newHostFromMenu() { workspace.navigator.newHostFromMenu() }
    @objc func selectKeys() { workspace.navigator.selectKeys() }
    @objc func selectSnippets() { workspace.navigator.selectSnippets() }
    @objc func newKeyFromMenu() { workspace.navigator.newKeyFromMenu() }
    @objc func newSnippetFromMenu() { workspace.navigator.newSnippetFromMenu() }
    @objc func newShiftTaskFromMenu() { workspace.navigator.newShiftTaskFromMenu() }
    @objc func newShiftFollowUpFromMenu() { workspace.navigator.newShiftFollowUpFromMenu() }
    @objc func newShiftProjectFromMenu() { workspace.navigator.newShiftProjectFromMenu() }
    @objc func showShiftWeeklyReview() { workspace.navigator.showShiftWeeklyReview() }
    @objc func showLogAnalyzer() { workspace.navigator.showLogAnalyzer() }
    @objc func analyzeClipboardInLogAnalyzer() { workspace.navigator.analyzeClipboardInLogAnalyzer() }
    @objc func logAnalyzerCopyAnalysis() { workspace.navigator.logAnalyzerCopyAnalysis() }
    @objc func logAnalyzerSendToTerminal() { workspace.navigator.logAnalyzerSendToTerminal() }
    @objc func logAnalyzerInvestigateFurther() { workspace.navigator.logAnalyzerInvestigateFurther() }
    @objc func logAnalyzerCreateRCA() { workspace.navigator.logAnalyzerCreateRCA() }
    @objc func selectSessionByShortcut(_ sender: NSMenuItem) { workspace.hosts.selectSession(atShortcutIndex: sender.tag) }
    @objc func nextSession() { workspace.hosts.nextSession() }
    @objc func previousSession() { workspace.hosts.previousSession() }

    // Host pages and live sessions.
    var sessions: HostSessionRegistry { workspace.hosts.sessions }
    var restoreTurnScheduler: (@escaping () -> Void) -> Void {
        get { workspace.hosts.restoreTurnScheduler } set { workspace.hosts.restoreTurnScheduler = newValue }
    }
    func queueRestoredHostConsoles(_ hosts: [(host: Host, args: [String])]) {
        workspace.hosts.queueRestoredHostConsoles(hosts)
    }
    func connectHost(_ host: Host, args: [String], navigate: Bool = true) {
        workspace.hosts.connectHost(host, args: args, navigate: navigate)
    }
    func isHostConnected(_ host: Host) -> Bool { workspace.hosts.isHostConnected(host) }
    func sendCommandToHost(_ host: Host, args: [String], text: String) {
        workspace.hosts.sendCommandToHost(host, args: args, text: text)
    }
    func revealHost(_ host: Host, args: [String]) { workspace.hosts.revealHost(host, args: args) }
    func removeHostConsole(id: UUID) { workspace.hosts.removeHostConsole(id: id) }
    func switchToSession(hostID: UUID) { workspace.hosts.switchToSession(hostID: hostID) }
    func confirmEndSession(hostID: UUID) { workspace.hosts.confirmEndSession(hostID: hostID) }
    func openSRELeadForCrew(hostHint: String?) -> String? { workspace.hosts.openSRELeadForCrew(hostHint: hostHint) }
    func shutdownAllHostConsoles() { workspace.hosts.shutdownAllHostConsoles() }
    #if FM_SELFTESTS
    var pendingRestoredHostIDsForTests: [UUID] { workspace.hosts.pendingRestoredHostIDsForTests }
    #endif

    // The pages' own quit-time flushes and menu-bar surfaces.
    func shutdownStickyBoard(deadline: DispatchTime) { workspace.shutdownStickyBoard(deadline: deadline) }
    func shutdownScratchpads() { workspace.shutdownScratchpads() }
    func shutdownReadingList(deadline: DispatchTime) { workspace.shutdownReadingList(deadline: deadline) }
    func shutdownCodePreview(deadline: DispatchTime) { workspace.shutdownCodePreview(deadline: deadline) }
    func shutdownNotebook(deadline: DispatchTime) { workspace.shutdownNotebook(deadline: deadline) }
    func shutdownCredentialVault(deadline: DispatchTime) { workspace.shutdownCredentialVault(deadline: deadline) }
    func shutdownStrawHatCrew() { workspace.shutdownStrawHatCrew() }
    func askCrewFromMenuBar(_ text: String, completion: @escaping (Result<[StrawHatSection], StrawHatError>) -> Void) {
        workspace.askCrewFromMenuBar(text, completion: completion)
    }
    var poneglyphQuickCodes: [PoneglyphQuickCode] { workspace.poneglyphQuickCodes }
    var poneglyphIsUnlocked: Bool { workspace.poneglyphIsUnlocked }
    @discardableResult
    func copyPoneglyphCodeFromMenuBar(id: String) -> String? { workspace.copyPoneglyphCodeFromMenuBar(id: id) }
    func setDictationEngineStatus(_ status: DictationStatus) { workspace.setDictationEngineStatus(status) }
    func makeCaptureFiler() -> CaptureFiler { workspace.makeCaptureFiler() }

    // MARK: Test hooks every shell answers
    //
    // Moved from `AppShellController` with the rest of the API in stage 3.
    // They read the workspace, never a shell's chrome, so a suite can drive
    // either layout through the same surface.

    /// `AppShellBodyWidthSelfTest` reads this rather than `bodyContainer`
    /// directly - everything else only ever needs to add/remove/toggle a
    /// destination view, never measure the container itself.
    var bodyContainerFrameForTests: NSRect { workspace.content.bodyContainer.frame }
    var bodyContainerForTests: NSView { workspace.content.bodyContainer }

    /// Full review #3's PF1. How many of the body container's embedded
    /// destination views are currently attached to it by active constraints,
    /// and how many of those are actually showing.
    ///
    /// Exposed as counts rather than the constraints themselves so the suite
    /// asserts the *property* - "a hidden page is out of the window's
    /// constraint graph, a showing one is in it" - rather than the content's
    /// private storage shape.
    var destinationLayoutAttachmentForTests: (attached: Int, showing: Int, embedded: Int) {
        var attached = 0
        var showing = 0
        let body = workspace.content.bodyContainer
        for (key, pins) in workspace.content.destinationPins {
            guard let view = body.subviews.first(where: { ObjectIdentifier($0) == key }) else { continue }
            if pins.contains(where: { $0.isActive }) { attached += 1 }
            if !view.isHidden { showing += 1 }
        }
        return (attached, showing, workspace.content.destinationPins.count)
    }

    var activeHostIDForTests: UUID? { workspace.navigator.activeHostID }

    /// F2: the restored page for a host, so a self-test can assert it exists
    /// and - the property that matters - has not started its `ssh`.
    func debugHostConsole(id: UUID) -> ConsoleController? { workspace.hosts.hostConsoles[id] }

    /// The set the Home canvas's own "N live sessions" reads, resolved through
    /// the real closure (audit 2 §4.6). A test that rebuilt the predicate
    /// would be asserting its own copy rather than the shipped one.
    func debugConnectedHostIDs() -> Set<UUID> { workspace.homeCanvas.connectedHostIDs?() ?? [] }

    /// Drives the real Recents click handler (finding 4.3). A test that
    /// reimplemented its switch-vs-reconnect decision would be asserting its
    /// own copy of the logic rather than the shipped one.
    func debugNavigateToRecent(_ kind: RecentDestinationKind) {
        workspace.navigator.navigateToRecentDestination(kind)
    }

    /// GL-37: which destination slots have actually been built.
    /// `DestinationMountingSelfTest` asserts this is exactly the eager set
    /// at launch, grows by one on a first visit, and does not grow again on
    /// a revisit.
    var mountedDestinationSlotsForTests: [DestinationSlotID] {
        workspace.content.mounter.mountedSlots.map(\.id)
    }

    /// The view a mounted slot owns, for identity comparison across a
    /// navigate-away-and-back cycle - `nil` while the slot is unmounted,
    /// deliberately, so a test cannot accidentally build the thing it is
    /// asserting stays unbuilt.
    func destinationViewIfMountedForTests(_ id: DestinationSlotID) -> NSView? {
        guard let slot = workspace.content.mounter.slot(for: id), slot.isMounted else { return nil }
        return slot.controller.view
    }

    #if FM_SELFTESTS
    /// The shared Firstmate console, so audit 2 §4.1's own case can drive the
    /// real `restoreTabs(from:)` launch path and then read the tabs that
    /// actually landed.
    ///
    /// Guarded, unlike some of its older neighbours here: GL-27's lesson is
    /// that a `debug*` hook living in a production file keeps shipping unless
    /// it says otherwise, so a *new* one is compiled into debug builds only.
    var debugConsole: ConsoleController { workspace.console }

    /// Which destination is showing, in the same terms `show(_:)` takes.
    ///
    /// Read off `currentDestinationKind`, the one piece of state the Recents
    /// dropdown, the tab shortcuts and F2's own capture already share - never
    /// a second notion of "what is on screen", which is how those three would
    /// start disagreeing.
    var debugCurrentDestination: RailDestination? {
        guard case .rail(let dest)? = workspace.navigator.currentDestinationKind else { return nil }
        return dest
    }

    /// Which host page is showing, or nil. Straw Hat phase 3's handoff suite
    /// asserts a refusal *did not* switch, which needs the nil case.
    var debugActiveHostID: UUID? { workspace.navigator.activeHostID }

    /// The Whiteboard destination, so the crew's "draw it out" handoff can be
    /// asserted against that page's own composer rather than against a copy
    /// of the prefill this suite passed in.
    var debugWhiteboard: WhiteboardController { workspace.whiteboard }

    var debugBootstrap: BootstrapController { workspace.bootstrap }

    /// The Home page and the Tasks page, for `ReviewTourLab`'s `demo home`
    /// and `tasks <view>` verbs - so a tour can render both pages in the
    /// state the captain sees rather than in their first paint.
    var debugHomeCanvas: HomeCanvasController { workspace.homeCanvas }
    var debugSchedules: SchedulesController { workspace.schedules }
    /// P9: a destination's mounted controller, for `SplitSidebarSelfTest`.
    func debugSlotController(_ dest: RailDestination) -> NSViewController? { workspace.content.mounter.slot(for: dest.slot)?.controller }
    var debugShift: ShiftController { workspace.shift }
    /// The Fleet page, for the tour lab's `demo decision` and `fleet reply`.
    var debugOverview: FleetController { workspace.overview }

    /// Compiled into debug builds only since stage 2 moved the seeding into
    /// `HostSessionCoordinator`, where it is guarded (GL-27).
    func debugSeedHostConsole(_ controller: ConsoleController, hostID: UUID) {
        workspace.hosts.debugSeedHostConsole(controller, hostID: hostID)
    }

    /// PERF-01: which lazy destinations have been *constructed* - a wider
    /// question than `mountedDestinationSlotsForTests`, because a page can be
    /// built without being mounted (a reach-in that forgot `isBuilt`).
    var builtLazyDestinationsForTests: Set<DestinationSlotID> { workspace.builtDestinations }
    var homeCanvasForTests: HomeCanvasController { workspace.homeCanvas }
    /// `fm/grandline-engineering-cards-stale-counts`: the two detail pages
    /// whose own state the Engineering hub's cards summarise, so
    /// `SummaryFreshnessSelfTest` can drive the real page and read the real
    /// card rather than standing either of them in.
    var updatesForTests: UpdatesController { workspace.updates }
    var githubSyncForTests: GitHubSyncController { workspace.githubSync }
    /// The Settings page itself, so a suite can drive its own category
    /// sidebar - `fm/grandline-settings-page-sidebar-redesign` made the page
    /// master/detail, and which pane is showing decides how tall its
    /// document is.
    var settingsForTests: SettingsController { workspace.settings }
    var debugPoneglyph: CredentialVaultController { workspace.debugPoneglyph }
    var debugPoneglyphStore: CredentialVaultStore { workspace.debugPoneglyphStore }
    #endif
}

extension WorkspaceLayout {
    /// The shell this layout builds - what the app delegate calls `init` on.
    var shellType: WorkspaceShellController.Type {
        switch self {
        case .floatingBar: return AppShellController.self
        case .sidebar: return MainSplitShellController.self
        }
    }
}
