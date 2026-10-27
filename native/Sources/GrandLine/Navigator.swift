// Grand Line - native macOS app.
//
// `Navigator` - where the captain is, and every way of moving them: `show(_:)`
// for a destination, the reveal of a host page, Recents, the session-restore
// snapshot, contextual ⌘N, and every route the menus, ⌘K, notifications, the
// crew, the menu bar extras and the Home cards call.
//
// Split out of `AppShellController` in stage 2 of the modular-shell migration
// (full review section 5.8, step 2). From step 3 both shells navigate through
// it - the classic floating-bar shell and the split-view shell - so it holds
// the navigation and leaves the chrome to whichever shell is showing:
// `Workspace.chrome` is told what is now on screen and draws it (the drill
// header, the space pill and the scroll edge today). Nothing about where a
// route lands changed in the move: every method below is the shell's own code.
//
// `RailDestination` stays the stable route id, so a notification, an App
// Intent, a widget, ⌘K and Recents keep addressing a page exactly as before.
//
// An `NSObject`, so its menu verbs keep their `@objc` names: the classic
// shell's menu still targets `AppShellController`, which forwards here, and
// step 3 can point the main menu at the navigator itself whichever shell is
// showing.

import AppKit

final class Navigator: NSObject {

    unowned let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init()
    }

    private var content: WorkspaceContent { workspace.content }
    private var hosts: HostSessionCoordinator { workspace.hosts }

    /// Set while a host's dedicated page is showing; `nil` whenever a fixed
    /// `RailDestination` is current, so `removeHostConsole` knows whether to
    /// navigate away. It used to be mirrored by the rail's own
    /// `activeHostID` for per-host icon highlighting; with the rail gone
    /// (Daylight §5.1) this is the only copy.
    private(set) var activeHostID: UUID?

    // MARK: Recent destinations (`fm/grandline-recents-navigation`)

    /// The app's one recency tracker across every destination - rail or host
    /// page alike. Written only from the moments this controller already
    /// owns "what's on screen changed" (`show(_:)`, `revealHostConsole`, and
    /// the one narrow bypass that jumps straight to a host's tab from a
    /// background SRE Lead reply notification) via `updateRecentDestinations
    /// (arriving:)`. Read by `DaylightBarController`'s own Recents popover,
    /// wired once in `loadView()`.
    let recentDestinations = RecentDestinations()

    /// F2: fires whenever the captured session state may have changed - i.e.
    /// on every navigation. Wired by the app delegate to its own
    /// `saveSessionState()`, which is what makes the restore survive a crash
    /// or a force-quit rather than only a clean ⌘Q.
    var onSessionStateChanged: (() -> Void)?

    /// Review #3 §7: the window title used to be the static app name, so
    /// Mission Control, the Window menu and the window's proxy menu all
    /// showed twenty-seven identical entries. Fires with
    /// `currentContextTitle` on every navigation - the app delegate composes
    /// the real title from it (`AppDelegate.windowTitle(context:)`).
    ///
    /// Wired from the same funnel `onSessionStateChanged` uses
    /// (`updateRecentDestinations`), for the same reason: `show(_:)`,
    /// `revealHostConsole` and the SRE Lead reply-jump bypass all pass
    /// through it, so there is one place that can know where the captain is
    /// and no second notion of it to drift.
    var onCurrentDestinationChanged: ((String?) -> Void)?

    /// The human-readable name of whatever is on screen - a destination's own
    /// title, or a host page's label. `nil` before the first navigation.
    ///
    /// Read off `currentDestinationKind` through `RecentDestinationKind
    /// .title`, which is already the one place that answers "what is this
    /// page called" for the Recents dropdown. A second switch here would be a
    /// second answer.
    var currentContextTitle: String? { currentDestinationKind?.title }

    /// Whatever `updateRecentDestinations(arriving:)` last recorded as
    /// current - the one piece of state that lets it know what was "on
    /// screen" a moment ago, so the *next* navigation can record the right
    /// outgoing destination. `nil` only before the app's very first
    /// navigation.
    private(set) var currentDestinationKind: RecentDestinationKind?

    /// `currentDestinationKind`, for the menu actions in this file that must
    /// only fire on one page. Read-only on purpose: a menu action may ask
    /// where the captain is, never move them.
    private var currentDestinationKindForMenus: RecentDestinationKind? { currentDestinationKind }

    /// F12's `.consoleOnly` question: is a terminal what the captain is
    /// typing into right now? True on the Console destination and on a host
    /// page, which is a console with a saved host behind it.
    ///
    /// Read off the same `currentDestinationKind` the Recents dropdown and the
    /// menu actions use, for that property's own reason - a second notion of
    /// "which page is showing" is a second thing to keep in step. The app's
    /// *frontmost-ness* is deliberately not folded in here:
    /// `SnippetExpander.currentContext` asks the workspace about that, and
    /// keeping the two readings separate is what lets the policy state them as
    /// two conditions rather than one opaque Bool.
    var isTerminalDestinationShowing: Bool {
        switch currentDestinationKind {
        case .rail(let destination): return destination == .console
        case .host: return true
        case nil: return false
        }
    }

    /// Open `command` as a new tab in the shared Firstmate console and bring
    /// Console forward, so its output (and any `sudo` prompt) is visible
    /// immediately - the one path every Bootstrap-page action that can invoke
    /// `darwin-rebuild switch` uses (`bootstrap.sh`, `rebuild.sh`, the initial
    /// clone).
    func runInConsole(label: String, command: String, completion: ((Bool) -> Void)? = nil) {
        workspace.console.openCommandTab(label: label, command: command) { exitCode in completion?(exitCode == 0) }
        show(.console)
    }

    // MARK: Destination switching

    /// Internal (not `private`): the app delegate also calls this directly
    /// after connecting the Firstmate console, so the new tab is visible
    /// immediately instead of landing silently in the background.
    func show(_ dest: RailDestination) {
        // B4 (UI modernization audit §3B): the report asks for the transition
        // to be "skipped when the destination is already visible", and this is
        // the only point where that is still knowable - `hideAllDestinations()`
        // one line down erases it.
        let wasAlreadyShowing = currentDestinationKind == .rail(dest)
        content.crossfadeOutgoingPage(unless: wasAlreadyShowing)
        hideAllDestinations()

        // GL-37: one table lookup replaces the fifteen-case switch this used
        // to be (and the matching line-per-destination in
        // `hideAllDestinations`). The slot is mounted here if this is its
        // first visit - see `DestinationRegistry.swift`.
        guard let slot = content.mounter.show(dest.slot) else { return }

        // `fm/grandline-recents-navigation`: records whatever was showing a
        // moment ago and removes `dest` itself from the list - see
        // `RecentDestinations`'s own recording method's doc comment for why a
        // captain never sees "where I already am" in the dropdown.
        updateRecentDestinations(arriving: .rail(dest))

        // The chrome half of a navigation - the drill header, the scroll
        // edge's re-target and the space pill - belongs to whichever shell is
        // showing. The classic shell's `workspaceDidShow` is exactly what
        // stood here, in the same order.
        workspace.chrome?.workspaceDidShow(dest, slot: slot)

        // B2: the bar's lit shortcut is pushed from `updateRecentDestinations`
        // a few lines up, the one call every navigation route makes - not
        // from here, which the SRE Lead reply-jump bypasses.

        // B4: the page arrives rather than teleporting. Nothing above this
        // line knows or cares that it animates; see `animateDestinationEntrance`.
        content.animateDestinationEntrance(slot.controller.view,
                                           direction: dest == .homeCanvas ? .back : .drillIn,
                                           skip: wasAlreadyShowing)

        // §8 Phase 6: which destination is showing decides where the bar's
        // chain hands off, so the loop is re-derived on every navigation.
        workspace.chrome?.workspaceKeyViewLoopMayHaveChanged()
    }

    // MARK: Contextual ⌘N (UX4)

    /// What ⌘N would create right now - the File menu re-reads this on every
    /// open so the item's own title says which thing it means.
    ///
    /// `workspace.hostsPanel.currentTab` is consulted only for `.hosts`; see
    /// `ContextualNewAction.forDestination`.
    var contextualNewAction: ContextualNewAction {
        guard case .rail(let destination)? = currentDestinationKind else {
            // A host page is not a `RailDestination` at all. It is a console,
            // and a console owns nothing creatable, so it takes the same
            // universal-capture fallback every other such page takes.
            return .task
        }
        return ContextualNewAction.forDestination(
            destination,
            hostsTab: destination == .hosts ? workspace.hostsPanel.currentTab : nil)
    }

    /// Perform whatever ⌘N means on the page that is showing.
    ///
    /// Every branch dispatches the *existing* menu action rather than
    /// re-implementing the creation, which is the same rule
    /// `UnifiedSearchActionProvider` follows: one way to create each thing, so
    /// a fix to the sheet cannot miss an entry point.
    @objc func newContextualItem() {
        switch contextualNewAction {
        // On the Calendar, ⌘N is its own New Task, dated to the day on
        // screen, rather than a trip to Tasks with an undated one.
        case .task where currentDestinationKind == .rail(.calendar): workspace.calendar.newTaskFromMenu()
        case .task: newShiftTaskFromMenu()
        case .host: newHostFromMenu()
        case .sshKey: newKeyFromMenu()
        case .snippet: newSnippetFromMenu()
        case .stickyNote: newStickyNoteFromMenu()
        case .codeSnippet: newCodeSnippetFromMenu()
        case .credential: newCredentialFromMenu()
        case .schedule: newScheduleFromMenu()
        case .command: newCommandFromMenu()
        case .runbook: newRunbookFromMenu()
        case .notebookPage: newNotebookPageFromMenu()
        case .savedLink: newSavedLinkFromMenu()
        }
    }

    /// The five creation verbs UX4 found with no shortcut and no menu item at
    /// all. Each follows the established shape - select the destination first
    /// so the sheet has something to present over, then act on it - so they
    /// work from wherever the captain happened to be.
    /// F1's own creation verb, following the established shape: select the
    /// destination first so the page exists, then act on it.
    /// F4's own creation verb, the same shape as every other one here: select
    /// the destination first so the page exists, then act on it.
    @objc func newSavedLinkFromMenu() {
        show(.readingList)
        workspace.readingList.newLinkFromMenu()
    }

    @objc func newNotebookPageFromMenu() {
        show(.notebook)
        workspace.notebook.newPageFromMenu()
    }

    @objc func newStickyNoteFromMenu() {
        show(.stickyBoard)
        workspace.stickyBoard.addNoteFromMenu()
    }

    /// UX10's "Make a task" promotion. The board raises a note; this navigates
    /// to Tasks and opens the editor already filled in.
    ///
    /// Wired here rather than on the board because this controller is the one
    /// place that holds both destinations - the same forward-don't-own shape
    /// every other cross-destination action in this app uses.
    func makeTaskFromStickyNote(_ note: StickyNote) {
        show(.shift)
        workspace.shift.presentTaskEditor(prefilledFrom: note)
    }

    @objc func newCodeSnippetFromMenu() {
        show(.codePreview)
        workspace.codePreview.newSnippetFromMenu()
    }

    /// F11's ⌘R. Unlike every creation verb above, this one deliberately does
    /// **not** navigate first: ⌘R means "run what I am looking at", and a
    /// chord that jumps to another destination and executes a snippet the
    /// captain was not looking at is the wrong answer in a way a no-op is not.
    ///
    /// So it is a no-op anywhere but Code Preview. This app implements no
    /// `validateMenuItem` (see `NavigationCoherenceSelfTest`'s note on why
    /// that matters for chords), so the item stays enabled everywhere and the
    /// guard lives here.
    @objc func runCodeSnippetFromMenu() {
        guard case .rail(.codePreview)? = currentDestinationKindForMenus else { return }
        workspace.codePreview.runCodeSnippet()
    }

    /// P9's Toggle Sidebar (⌥⌘S): collapse or reopen the showing page's
    /// split-view sidebar, animated. A no-op on a page without one, for
    /// `runCodeSnippetFromMenu`'s reason - this app implements no
    /// `validateMenuItem`, so the guard lives here.
    @objc func toggleSidebarFromMenu() {
        showingSplitPage?.toggleSidebar(nil)
    }

    /// The showing page's own split view, when it has one - the seven pages
    /// whose column is a real `HelmSplitPage`. The sidebar shell asks, so ⌥⌘S
    /// toggles the page's column where there is one and its own sidebar
    /// everywhere else.
    var showingSplitPage: HelmSplitPage? {
        guard case .rail(let dest)? = currentDestinationKindForMenus,
              let host = content.mounter.slot(for: dest.slot)?.controller as? HelmSplitPageHosting else { return nil }
        return host.splitPage
    }

    /// Code Preview's ⌘B: show or hide the snippet list. A no-op anywhere
    /// else, for `runCodeSnippetFromMenu`'s reason - a chord that navigated to
    /// toggle a column the captain is not looking at would be a surprise.
    @objc func toggleCodePreviewSidebarFromMenu() {
        guard case .rail(.codePreview)? = currentDestinationKindForMenus else { return }
        workspace.codePreview.toggleSidebarFromMenu()
    }

    /// F15's ⌘⇧S. Unlike `runCodeSnippetFromMenu` - which refuses off its own
    /// page because ⌘R has a page-local meaning - this one *navigates*: the
    /// capture is the thing the captain asked for, the Whiteboard is only
    /// where it lands, and refusing because they happened to be on Console
    /// would make the chord feel broken. Same shape as every `new*FromMenu`
    /// below.
    @objc func captureScreenRegionFromMenu() {
        show(.whiteboard)
        workspace.whiteboard.captureTapped()
    }

    /// The copy half. This one *does* refuse off-page: there is no board to
    /// copy anywhere else, and navigating to the Whiteboard to copy whatever
    /// happens to be on it is not what the item says.
    @objc func copyWhiteboardImageFromMenu() {
        guard case .rail(.whiteboard)? = currentDestinationKindForMenus else { return }
        workspace.whiteboard.copyImageTapped()
    }

    @objc func newCredentialFromMenu() {
        show(.poneglyph)
        workspace.poneglyph.newCredentialFromMenu()
    }

    @objc func newScheduleFromMenu() {
        show(.schedules)
        workspace.schedules.newScheduleFromMenu()
    }

    @objc func newCommandFromMenu() {
        show(.commandLibrary)
        workspace.commandLibrary.newCommandFromMenu()
    }

    @objc func newRunbookFromMenu() {
        show(.runbooks)
        workspace.runbooks.newRunbookFromMenu()
    }

    /// UX1's "Lock Poneglyph" ⌘K verb.
    ///
    /// Deliberately does **not** navigate first, unlike every creation verb
    /// above: locking the vault is a thing a captain does *because* they are
    /// walking away, and dragging them onto the vault page to do it would be
    /// the opposite of what they asked for. The slot is mounted if this is its
    /// first use - GL-37 - and locking an already-locked vault is a no-op.
    @objc func lockPoneglyph() {
        // A vault whose page has never been built has never been unlocked, so
        // there is nothing to lock - and `lockFromMenu` reaches the page's own
        // views, which would force a full mount just to re-lock an already
        // locked store. `isViewLoaded` is the honest test for "has this page
        // ever existed", and it is what keeps this verb free on a cold app.
        guard workspace.isBuilt(.poneglyph), workspace.poneglyph.isViewLoaded else { return }
        workspace.poneglyph.lockFromMenu()
    }

    /// Drop a deleted host's Recents row (finding 4.3). Called by the app
    /// delegate's own host-delete diffing, which is the one place that knows
    /// a host has genuinely left the store - `removeHostConsole` cannot be
    /// that place, because it is also what "End session" calls, and an ended
    /// session's row must stay listed and reconnect.
    func forgetRecentHost(id: UUID) {
        recentDestinations.forget(.host(id: id, label: ""))
    }

    /// The shared tail of `HostSessionCoordinator.connectHost` and
    /// `switchToSession` - one definition of "this host's page is now the
    /// thing on screen", so the drill header, the registry's active session
    /// and the focused terminal can never disagree about which of them is
    /// showing.
    func revealHostPage(_ controller: ConsoleController, hostID: UUID, label: String) {
        let wasAlreadyShowing = currentDestinationKind == .host(id: hostID, label: label)
        content.crossfadeOutgoingPage(unless: wasAlreadyShowing)
        hideAllDestinations()
        content.setDestinationVisible(controller.view, true)
        // B4: a host page is a drill-in like any other.
        content.animateDestinationEntrance(controller.view, direction: .drillIn, skip: wasAlreadyShowing)
        // `fm/grandline-recents-navigation`: a saved host's own page is one of
        // the destinations the captain explicitly wants tracked - this is the
        // one place both a fresh connect and switching back into a live
        // session reach, so it needs no separate hook at either call site.
        updateRecentDestinations(arriving: .host(id: hostID, label: label))
        // The drill header and the scroll edge (a host console has no page
        // scroll view, so that correctly clears the edge rather than leaving
        // the previous page's state) - the chrome half, as in `show(_:)`.
        workspace.chrome?.workspaceDidRevealHostPage(controller, label: label)
        activeHostID = hostID
        hosts.sessions.setActive(hostID)
        controller.focusCurrentTab()
        controller.markCurrentTabAsRead()
        workspace.chrome?.workspaceKeyViewLoopMayHaveChanged()
    }

    // MARK: F2 - session restoration

    /// Where the captain is right now, in a form that survives a relaunch.
    ///
    /// Reads the same `currentDestinationKind` the Recents dropdown and the
    /// tab shortcuts already read, and the same `hosts.hostConsoles` dictionary the
    /// session strip does - never a second notion of "what is open".
    ///
    /// See `SessionRestore.swift` for exactly what is and is not captured.
    func captureSessionState() -> SessionRestoreState {
        var destination: String?
        var activeHost: String?
        switch currentDestinationKind {
        case .rail(let dest): destination = dest.rawValue
        case .host(let id, _): activeHost = id.uuidString
        case nil: break
        }
        return SessionRestoreState(
            destination: destination,
            activeHostID: activeHost,
            // Sorted so an unchanged session encodes to identical bytes -
            // `Dictionary.keys` has no defined order, and without this the
            // save-only-when-changed check below would write on every
            // navigation regardless.
            // PERF-08: a page still queued for restore is open too - this
            // runs on every navigation, including the one restore itself
            // makes before the queue has drained.
            openHostIDs: (Array(hosts.hostConsoles.keys) + hosts.pendingRestoredHostIDs)
                .map(\.uuidString).sorted(),
            consoleTabs: workspace.console.isViewLoaded ? workspace.console.restorableConsoleTabs() : [],
            // `isBuilt` first: this runs on every navigation, and asking an
            // unbuilt Tools page whether its view is loaded would build it.
            toolTabs: workspace.isBuilt(.tools) && workspace.tools.isViewLoaded ? workspace.tools.restorableToolTabs() : []
        )
    }

    /// Restores the halves that need no host store: the shared Console's tabs
    /// and the Tools page's tabs.
    ///
    /// Mounting each page here is deliberate and is what makes the lazy half
    /// work: `DestinationRegistry` would otherwise not build these until the
    /// captain visited them, and a page that does not exist cannot hold
    /// restored tabs. Mounting is not showing - `ConsoleController.addTab`
    /// only starts a tab's process `if hasAppeared`, so a restored Console the
    /// captain does not open forks no shells until they do.
    func restoreTabs(from state: SessionRestoreState) {
        if !state.consoleTabs.isEmpty {
            // Touching `view` forces `loadView` - enough for a controller to
            // hold tabs. It is NOT a mount: `DestinationRegistry` still embeds
            // the page on its first visit, and `ConsoleController.addTab` only
            // starts a tab's process `if hasAppeared`, so a restored Console
            // the captain does not open forks no shells until they do.
            _ = workspace.console.view
            workspace.console.restoreConsoleTabs(state.consoleTabs)
        }
        if !state.toolTabs.isEmpty {
            _ = workspace.tools.view
            workspace.tools.restoreToolTabs(state.toolTabs)
        }
    }

    /// Restores the destination that was showing.
    ///
    /// Returns `false` when the state named a host page, which this method
    /// cannot open on its own (it needs the host record and its resolved `ssh`
    /// argv, which this controller deliberately knows nothing about - the same
    /// boundary `connectHost`'s own `args` parameter draws). The app delegate
    /// handles that case; everything else is an ordinary `show(_:)`.
    ///
    /// A destination this build no longer has lands on Home. The Today page
    /// (`dailyOverview`) is the case that made this explicit: a captain who
    /// quit on it still has that raw value saved, and Home is the page its
    /// one remaining card moved to.
    @discardableResult
    func restoreDestination(from state: SessionRestoreState) -> Bool {
        guard state.activeHostID == nil else { return false }
        guard let raw = state.destination else { return false }
        show(RailDestination(rawValue: raw) ?? .homeCanvas)
        return true
    }

    /// Audit §2 item 7: which page a tab keyboard shortcut should act on
    /// right now, or `nil` when none should.
    ///
    /// Derived from `currentDestinationKind` - the state the Recents dropdown
    /// already keeps current on *every* navigation path (`show(_:)`,
    /// `revealHostConsole`, and the SRE Lead reply-jump bypass all funnel
    /// through `updateRecentDestinations`) - rather than a second notion of
    /// "what is showing" invented for the shortcuts. A dedicated host page is
    /// a `ConsoleController` with its own tabs, so ⌘T/⌘W/⌘1 mean exactly what
    /// they mean on the shared Console; that is the reason this resolves a
    /// controller instead of switching on `RailDestination` alone.
    ///
    /// Everything else answers `nil`, which is what keeps ⌘R on the Docs page
    /// (or in the Whiteboard's web view) out of this feature's hands.
    func activeTabShortcutTarget() -> TabShortcutHandling? {
        switch currentDestinationKind {
        case .host(let id, _):
            return hosts.hostConsoles[id]
        case .rail(let dest):
            switch dest {
            case .console: return workspace.console
            case .tools: return workspace.tools
            default: return nil
            }
        case nil:
            return nil
        }
    }

    /// Records the navigation into `recentDestinations` and remembers
    /// `kind` as the new "current" - the one call site both `show(_:)` and
    /// `revealHostConsole` (and the SRE Lead reply-jump bypass) make, so the
    /// leaving/arriving bookkeeping can never drift between them.
    func updateRecentDestinations(arriving kind: RecentDestinationKind) {
        recentDestinations.recordNavigation(leaving: currentDestinationKind, arriving: kind)
        currentDestinationKind = kind
        // B2: the chrome lights the bar square for this page, and darkens
        // whichever was lit before. Here rather than at each route because
        // this is the one call they all make - the SRE Lead reply-jump used to
        // bypass the push and left the previous page's square lit over a host
        // page. A host page is not a `RailDestination`, so no square stands
        // for it and it clears the bar. The bar draws state, it does not track
        // navigation.
        workspace.chrome?.workspaceCurrentDestinationDidChange(kind)
        // Review #3 §7: the window title carries the current destination, so
        // Mission Control and the Window menu name a page rather than the app.
        onCurrentDestinationChanged?(kind.title)
        // A page that pushed the window past its screen is usually the page
        // being left - see `WindowOverflowGuard`.
        workspace.windowOverflowGuard.destinationDidChange(in: workspace.chrome?.workspaceWindow)
        // F2: every navigation path funnels through here, so this is the one
        // hook that keeps the saved session current without a timer. The app
        // delegate's own handler writes only when the state actually changed.
        onSessionStateChanged?()
    }

    /// A Recents row was clicked - dispatched to whichever navigation
    /// primitive already handles that kind, never a third path.
    /// Open whatever a Recents row names.
    ///
    /// **A `.host` row whose session has since ended reconnects rather than
    /// doing nothing** (full-app audit, finding 4.3). `RecentDestinations`'
    /// own header is explicit that a host page the captain closed deliberately
    /// stays listed until it ages out of the cap - which made
    /// `switchToSession`'s "no-op for a host with no live session" guard
    /// (correct for the strip and the shortcuts, which only ever name live
    /// ones) reachable here as a silently dead click: the row is still there,
    /// looks exactly like every other row, and does nothing. The three ways a
    /// session ends - the strip's ✕, the Hosts row's "End session", deleting
    /// the host - all clear `hosts.hostConsoles`, so all three produced it.
    ///
    /// Reconnecting is the honest reading of what the row means: "take me back
    /// to that host page". A host that is no longer saved at all cannot be
    /// reconnected, so its row is dropped instead of pretending - see
    /// `onReconnectHost`.
    /// Reconnect a saved host that no longer has a live session, by id.
    /// Returns whether the host still exists to be reconnected to.
    ///
    /// Forward-don't-own (`onSearchTapped`'s convention): this controller has
    /// no `HostStore` and does not know how a host's `ssh` argv is built -
    /// `connectHost` needs both, which is exactly why `switchToSession` was
    /// written to need neither. The app delegate owns the store and already
    /// has the one `connectToHost` path every other reconnect goes through.
    var onReconnectHost: ((UUID) -> Bool)?

    func navigateToRecentDestination(_ kind: RecentDestinationKind) {
        switch kind {
        case .rail(let dest):
            show(dest)
        case .host(let id, _):
            if hosts.sessions.session(for: id) != nil {
                hosts.switchToSession(hostID: id)
            } else if onReconnectHost?(id) != true {
                // The host is gone from the store entirely - nothing to
                // reconnect to, so stop listing it rather than leaving a row
                // that can only ever do nothing.
                recentDestinations.forget(.host(id: id, label: ""))
            }
        }
    }

    func hideAllDestinations() {
        // Only mounted slots have a view to hide - asking an unmounted one
        // for `controller.view` here would build it and defeat GL-37's whole
        // point. Host pages are tracked separately (they are not fixed
        // `RailDestination` cases) and were always lazily built.
        content.mounter.hideAll()
        for controller in hosts.hostConsoles.values where controller.isViewLoaded {
            content.setDestinationVisible(controller.view, false)
        }
        activeHostID = nil
        // `fm/grandline-session-switcher`: no session's page is on screen any
        // more. The sessions themselves are untouched - a live session that is
        // not showing is still live, just not active - so the strip keeps its
        // pills and simply stops filling one of them in.
        hosts.sessions.setActive(nil)
    }

    /// The Hosts menu's "Quick Connect" (⌘K): reveal the Hosts destination
    /// and focus its quick-connect field, regardless of which destination
    /// was active. No longer shared with the topbar Search control (Fix 4).
    @objc func revealHostsQuickConnect() {
        show(.hosts)
        workspace.hostsPanel.focusQuickConnect()
    }


    /// The Edit menu's "Find in Terminal" (no longer ⌘K as of phase 4 - see
    /// main.swift's Edit menu comment; ⌘K now opens the unified search
    /// palette instead): invoke the exact same find action the console
    /// toolbar's magnifying-glass icon uses, on whichever console is actually
    /// on screen. Fix 1: if a host's dedicated page is showing, find there
    /// rather than yanking the captain over to the unrelated shared
    /// Firstmate console just because that's this method's historical
    /// default - otherwise this action would silently navigate away from the
    /// session being read and search the wrong terminal. With no host page
    /// active, the original behaviour holds: bring Console forward (so the
    /// find bar it triggers is visible) first.
    @objc func activateConsoleFind() {
        if let activeHostID, let controller = hosts.hostConsoles[activeHostID] {
            controller.showFind()
            return
        }
        show(.console)
        workspace.console.showFind()
    }

    /// The App menu's "Settings…" (⌘,): select the Settings rail destination
    /// rather than opening a separate window.
    @objc func selectSettings() {
        show(.settings)
    }

    /// The Hosts menu's "Show Hosts": select the Hosts rail destination.
    @objc func selectHosts() {
        show(.hosts)
        workspace.hostsPanel.select(tab: .hosts)
    }

    /// The Hosts menu's "New Host…".
    ///
    /// GL-37: this used to target `HostsController` directly, which was the
    /// one menu item in the app that could reach a destination's own
    /// view-touching method without going through `show(_:)` first. With the
    /// Hosts slot mounted lazily that would mean invoking a page that has
    /// not been built yet, so it now follows the same shape every other
    /// menu item here already uses - select the destination, then act on it.
    @objc func newHostFromMenu() {
        show(.hosts)
        workspace.hostsPanel.newHost()
    }

    /// The Keys menu's "Manage Keys…" (⌘⇧K). Phase 5 of the full-app UI audit
    /// folded the SSH Keys window into the Hosts destination as a tab, so
    /// this now selects that destination and that tab rather than opening a
    /// second window.
    @objc func selectKeys() {
        show(.hosts)
        workspace.hostsPanel.select(tab: .keys)
    }

    /// The Snippets menu's "Manage Snippets…" (⌘⌥P) - same shape as
    /// `selectKeys`.
    @objc func selectSnippets() {
        show(.hosts)
        workspace.hostsPanel.select(tab: .snippets)
    }

    /// The Keys menu's "New Key…" (⌘⇧N): reveal the Keys tab and open the key
    /// editor sheet on it, regardless of which destination was showing.
    @objc func newKeyFromMenu() {
        show(.hosts)
        workspace.hostsPanel.newKey()
    }

    /// The Snippets menu's "New Snippet…" (⌘⌥N) - same shape.
    @objc func newSnippetFromMenu() {
        show(.hosts)
        workspace.hostsPanel.newSnippet()
    }

    /// The Shift menu's "New Task…" (⌘N) - selects the Shift destination
    /// first so the sheet has something to present over, then opens the New
    /// Task editor regardless of whichever destination was showing before.
    @objc func newShiftTaskFromMenu() {
        show(.shift)
        workspace.shift.presentNewTaskEditor()
    }

    /// The Shift menu's "New Follow-up…" (⌘⇧F) - same shape as
    /// `newShiftTaskFromMenu` above.
    @objc func newShiftFollowUpFromMenu() {
        show(.shift)
        workspace.shift.presentNewFollowUpEditor()
    }

    /// The Shift menu's "New Project…" (cockpit-fix-shift-new-project) - no
    /// keyboard shortcut, since ⌘⇧P (the pattern ⌘N/⌘⇧F would suggest for a
    /// third Shift creation action) is already claimed by "Search Shift…"
    /// below - same shape as "Weekly Review", which also has no shortcut.
    @objc func newShiftProjectFromMenu() {
        show(.shift)
        workspace.shift.presentNewProjectEditor()
    }

    // MARK: Search / menu bar / quick-capture navigation (phase 5)

    /// The Shift menu's "Search Shift…" (⌘⇧P) and the search palette's own
    /// entry point - selects the Shift destination so a result's editor
    /// sheet (below) has somewhere to present over.
    // MARK: The session switcher's menu verbs

    /// ⌘⌃1-9 in the Hosts menu: the session at that position. The menu
    /// carries the 1-based index in its tag.
    @objc func selectSessionByShortcut(_ sender: NSMenuItem) { hosts.selectSession(atShortcutIndex: sender.tag) }
    @objc func nextSession() { hosts.nextSession() }
    @objc func previousSession() { hosts.previousSession() }

    func showShiftDestination() { show(.shift) }

    /// The ⌘⇧P search palette's "Weekly Review" navigation, and the Shift
    /// menu's own "Weekly Review" item.
    @objc func showShiftWeeklyReview() {
        show(.shift)
        workspace.shift.showWeeklyReview()
    }

    /// A search-palette or menu-bar-popover selection resolving to a task/
    /// follow-up/project - each opens the same editor sheet the Shift page's
    /// own row click already uses, so there is exactly one "open this task"
    /// behavior regardless of entry point.
    /// The app's own activity feed - Overview's captain's log.
    ///
    /// Wired to the Hosts sidebar's TOOLS > Activity row. `show(_:)` mounts
    /// the destination if this is its first visit, which is why the tab switch
    /// follows rather than precedes it.
    func openFleetLog() {
        show(.overview)
        workspace.overview.showLogTab()
    }

    func openShiftTask(id: String) {
        show(.shift)
        workspace.shift.openTask(id: id)
    }

    /// `fm/grandline-k8s-cluster-tail`: the Shape-C deep link. A host page's
    /// own "Tail Logs" / "Cluster" toolbar buttons land here with that host
    /// already selected as the scope, so the captain reaches the same one
    /// implementation from either front door - the identical idiom Overview's
    /// ready-to-merge tile already uses to reach Review.
    func openKubernetes(hostID: UUID, showTail: Bool) {
        show(.kubernetes)
        workspace.kubernetes.openScoped(hostID: hostID, showTail: showTail)
    }

    func openShiftFollowUp(id: String) {
        show(.shift)
        workspace.shift.openFollowUp(id: id)
    }

    func openShiftProject(id: String) {
        show(.shift)
        workspace.shift.openProject(id: id)
    }

    // MARK: Unified search navigation (phase 4, "Knowledge and speed")

    /// The `⌘K` unified search palette's own entry point for a Runbook/
    /// Postmortem result, and the Log Analyzer's "Create Runbook"/"Generate
    /// Postmortem" actions - switches to the item's own destination first,
    /// exactly like every other `open*(id:)` wrapper above, so it has
    /// somewhere to open into. `fm/grandline-docs-split-runbooks-postmortems`
    /// renamed these from `openDocsRunbook`/`openDocsPostmortem` once
    /// Runbooks/Postmortems stopped being Docs tabs.
    func openRunbook(id: String) {
        show(.runbooks)
        workspace.runbooks.openRunbook(id: id)
    }

    /// ⌘K's own deep link into a saved link - it opens the page's own reader,
    /// not the system browser, because the palette is inside this app.
    func openReadingListLink(id: String) {
        show(.readingList)
        workspace.readingList.openReader(id: id)
    }

    /// ⌘K's own deep link into a notebook page.
    func openNotebookPage(id: String) {
        show(.notebook)
        workspace.notebook.openPage(id: id)
    }

    func openPostmortem(id: String) {
        show(.postmortems)
        workspace.postmortems.openPostmortem(id: id)
    }

    // MARK: Straw Hat crew handoffs (phase 3, M3.2)

    /// `open_destination`: select the page, and where that page has an entry
    /// point worth landing on, open it carrying what the crew was talking
    /// about.
    ///
    /// The second half is the app's own established convention rather than an
    /// extra: every `open*(id:)` wrapper above *reveals the record* rather
    /// than only selecting its destination, because audit bug 4.3 corrected
    /// exactly that dead end once for Recents. A "draw it out" handoff that
    /// left the captain on an empty whiteboard, having discarded the idea
    /// Usopp was describing, is the same shape.
    ///
    /// The Whiteboard is the only destination with such an entry point today
    /// (its own "Generate diagram" composer - reused, never a second
    /// generator), so it is the only special case, and every other
    /// destination ignores the hint.
    func openDestinationForCrew(_ dest: RailDestination, hint: String?) {
        show(dest)
        guard dest == .whiteboard, let hint, !hint.isEmpty else { return }
        // Deferred one turn: the composer is an `NSPopover` anchored on the
        // "Generate diagram" button, which lives in the *drill header* that
        // `show(_:)` has only just repopulated - showing a popover relative to
        // a button that has not been laid out yet places it against a zero
        // rect.
        DispatchQueue.main.async { [weak self] in
            self?.workspace.whiteboard.openDiagramComposer(prefill: hint)
        }
    }

    /// ⌘K landing actions for the two newest stores (audit §6.5b / §6.6b).
    ///
    /// Same shape as the two above: select the destination, then reveal the
    /// record. Selecting alone would leave the captain to hunt for the note
    /// or snippet they just searched for, which is the dead-end shape bug 4.3
    /// already corrected once for Recents.
    func openStickyNote(id: String) {
        show(.stickyBoard)
        workspace.stickyBoard.revealNote(id: id)
    }

    func openCodeSnippet(named name: String) {
        show(.codePreview)
        workspace.codePreview.openSnippet(named: name)
    }

    // MARK: Command palette navigation (F5)

    /// F5 (`fm/grandline-feature-f5-command-palette-expansion`): the command
    /// palette's action for a saved command that still needs a parameter
    /// filled in - switches to the DevOps Commands destination and selects
    /// it, so the captain completes it on the real form (with its real
    /// Copy/Send buttons and their real risk gate) rather than the palette
    /// sending a half-substituted template.
    ///
    /// `fm/grandline-tasks-kanban-devops-split`: this used to `show(.shift)`
    /// and ask that page to switch to its third tab. The library is its own
    /// destination now, so the navigation is a plain `show` like every other
    /// palette landing.
    func openCommandLibraryCommand(id: String) {
        show(.commandLibrary)
        workspace.commandLibrary.openCommand(id: id)
    }

    /// The command palette's send action for a command that needs no input -
    /// the identical call `workspace.shift.onSendCommandToTerminal` is wired to above,
    /// so both surfaces type into whichever console tab is in front. The risk
    /// gate runs *before* this (see `CommandRiskConfirmation`); this method is
    /// only the delivery half.
    func sendCommandToConsole(_ text: String) {
        workspace.console.sendCommandLibraryTextToActiveTab(text)
    }

    // MARK: Log Analyzer (`fm/grandline-log-analyzer-build`)

    /// ⌘⇧L / the Log Analyzer menu's "Open Log Analyzer" - switches to the
    /// destination and focuses its input so a paste lands immediately (spec
    /// §24's own success-criteria flow: ⌘⇧L → paste → ⌘↵).
    @objc func showLogAnalyzer() {
        show(.logAnalyzer)
        workspace.logAnalyzer.focusForPaste()
    }

    /// The clipboard quick action (spec §2).
    @objc func analyzeClipboardInLogAnalyzer() {
        show(.logAnalyzer)
        workspace.logAnalyzerCaptureSource = nil
        workspace.logAnalyzer.analyzeClipboard()
    }

    /// Spec §2's terminal bridge. Called from the app delegate, which owns
    /// the host consoles' `onAnalyzeLogs` closure - the capture decision
    /// itself is made in `ConsoleController` (which has the tab, its block
    /// tracker and its selection) via `LogTerminalCaptureBuilder`, so this
    /// only routes an already-built capture to the page.
    func openLogAnalyzer(with capture: LogTerminalCapture, hostLabel: String) {
        show(.logAnalyzer)
        workspace.logAnalyzer.importTerminalCapture(capture, hostLabel: hostLabel)
    }

    /// The remaining spec §24 shortcuts, all routed through the destination
    /// so they behave identically whether they came from the menu or the
    /// page's own buttons.
    @objc func logAnalyzerCopyAnalysis() { showThenRun { $0.menuCopyAnalysis() } }
    @objc func logAnalyzerSendToTerminal() { showThenRun { $0.menuSendToTerminal() } }
    @objc func logAnalyzerInvestigateFurther() { showThenRun { $0.menuInvestigateFurther() } }
    @objc func logAnalyzerCreateRCA() { showThenRun { $0.menuCreateRCA() } }

    // MARK: The notification popover's expanded rows
    //
    // `fm/grandline-notification-ambient-expand-fix`. The popover can be open
    // before either page has ever been mounted - that is the normal case at
    // launch - so a child row's Update/Sync arrives here as an id rather than
    // as a closure over a row that does not exist yet. Same shape as
    // `showLogAnalyzer`/`showThenRun` above: show the destination, which
    // mounts it on a first visit, then hand the page the work. The page owns
    // the confirmation, the busy state and the log; see
    // `BackgroundSignalsPoller.onUpdateTool` for why none of that is done
    // here.

    func updateToolFromNotification(_ toolID: String) {
        show(.updates)
        workspace.updates.requestUpdateFromNotification(toolID: toolID)
    }

    func syncForkFromNotification(_ repoFullName: String) {
        show(.githubSync)
        workspace.githubSync.requestSyncFromNotification(repoFullName: repoFullName)
    }

    private func showThenRun(_ body: (LogAnalyzerController) -> Void) {
        show(.logAnalyzer)
        body(workspace.logAnalyzer)
    }

    /// The SRE Lead reply notification's jump straight to one tab of a
    /// background host page. It bypasses `revealHostPage` because it has to
    /// focus one specific tab, and it is moved here verbatim from the closure
    /// `connectHost` installs: no crossfade, no entrance and no key view loop
    /// re-derivation, and the registry's active session is left as
    /// `hideAllDestinations` set it - exactly what that closure did.
    func jumpToHostPage(_ controller: ConsoleController, hostID: UUID, label hostLabel: String,
                        focusingTab tabID: UUID) {
        hideAllDestinations()
        content.setDestinationVisible(controller.view, true)
        // `fm/grandline-recents-navigation`: this bypasses `revealHost
        // Console` (it also needs to focus one specific tab), but it
        // is a real navigation like any other - and skipping this
        // would leave `currentDestinationKind` stale for whatever the
        // *next* real navigation tries to record as "outgoing".
        updateRecentDestinations(arriving: .host(id: hostID, label: hostLabel))
        workspace.chrome?.workspaceDidRevealHostPage(controller, label: hostLabel)
        activeHostID = hostID
        controller.selectAndFocusTab(id: tabID)
    }

    /// The incident card's Evidence tab reopening a saved Log Analyzer
    /// investigation, in the three steps `connectHost`'s closure took.
    func openSavedInvestigation(id investigationID: String) {
        show(.logAnalyzer)
        workspace.logAnalyzerCaptureSource = nil
        workspace.logAnalyzer.openSavedInvestigation(id: investigationID)
    }

}
