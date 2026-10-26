// Grand Line - native macOS app (Phase 2 entry point).
//
// One AppKit window whose content is `AppShellController` - the nav-redesign
// task's icon rail + topbar + swappable body (Console/Home, Overview,
// Review, Settings). This file owns only the window, the main menu, and app
// lifecycle - all terminal behaviour lives in `ConsoleController` and its
// helpers. It builds ON Phase 1: the Shell tab is the P1 terminal unchanged, and
// the load-bearing Edit > Paste wiring (which drives screenshot-paste into
// Claude) is preserved here for both tabs.

import AppKit
import SwiftTerm

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    /// Fills the menu-bar strip macOS reserves above a full-screen window, so
    /// the app's ground - not a black band - runs to the top of the display.
    /// See `FullScreenMenuBarFill.swift`'s header for the measurement.
    private var fullScreenMenuBarFill: FullScreenMenuBarFill?
    /// Keeps the sidebar layout's Go menu in step with the hidden modules.
    var goMenuObserver: NSObjectProtocol?
    // Phase 1: saved SSH hosts + the panel that lists and connects them. The
    // panel hands a `ssh` argv to the console, which opens it as a new tab.
    let hostStore = LaunchSignposts.measure("HostStore.init") { HostStore() }
    // Phase 2: the saved-keys Keychain. The console resolves a host's chosen
    // key through it at connect time; the Keys window (below) is where the
    // captain generates/imports/browses them.
    let keyStore = LaunchSignposts.measure("SSHKeyStore.init") { SSHKeyStore() }
    // Phase 3: the saved-command library (B2/B5). The console resolves a
    // host's startup snippet through it at connect time, and the Snippets
    // window's "Run" sends a snippet straight to the active tab.
    let snippetStore = LaunchSignposts.measure("SnippetStore.init") { SnippetStore() }
    // Phase 5 (cockpit-shift-power-features): one `ShiftStore` shared by the
    // main window's Shift page, the menu bar item, the search palette, and
    // quick capture - all read/write the same tasks/follow-ups, never
    // separate store instances that could drift out of sync with each other.
    let shiftStore = LaunchSignposts.measure("ShiftStore.init") { ShiftStore() }
    lazy var console = ConsoleController(keyStore: keyStore, snippetStore: snippetStore)
    // Phase 5 of the full-app UI audit merged the Hosts destination and the
    // two floating SSH Keys / Snippets windows into one destination with
    // three segmented tabs, so this is now the only controller for all three
    // stores' browsing/editing surfaces.
    ///
    /// PERF-01: built on the Hosts page's first use rather than at launch -
    /// the shell takes it as an autoclosure - so its wiring lives in
    /// `wireHostsPanel` rather than in `applicationDidFinishLaunching`, where
    /// assigning a callback would have built it.
    lazy var hostsPanel: HostsController = {
        let panel = HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore)
        wireHostsPanel(panel)
        return panel
    }()
    /// PERF-01: the same shape as `hostsPanel`, for the same reason.
    lazy var settingsController: SettingsController = {
        let settings = SettingsController(hostStore: hostStore, keyStore: keyStore,
                                          snippetStore: snippetStore, dictationStore: dictationStore)
        wireSettings(settings)
        return settings
    }()
    lazy var shiftMenuBar = ShiftMenuBarController(store: shiftStore)
    // `fm/straw-hat-menubar-quick-chat-popover`: the crew's own status item,
    // mirroring `shiftMenuBar`'s shape. `onAsk`/`onOpenFullChat` are wired
    // below, after `appShell` exists - the forward-don't-own convention
    // every out-of-window surface in this app follows.
    lazy var strawHatMenuBar = StrawHatMenuBarController()
    /// F16: Poneglyph's own status item - the third instance of the same
    /// shape, wired below like the other two and owning no store (see
    /// `PoneglyphMenuBarController`'s header).
    lazy var poneglyphMenuBar = PoneglyphMenuBarController()
    /// F22: compact mode - the fourth status item, and the one that *merges*
    /// the three above rather than joining them. `CompactMode.swift`'s header
    /// is the whole design; `CompactModePopover.swift` is the popover the
    /// reviewed mockup draws.
    ///
    /// Two objects rather than one because the content is what a suite wants
    /// to drive (four tabs, a capture line) and the controller is what owns
    /// the `NSStatusItem` - the same split all three of its siblings make.
    lazy var compactModePopover = CompactModePopoverController()
    lazy var compactMode = CompactModeController(content: compactModePopover)
    // F5 (`fm/grandline-feature-f5-command-palette-expansion`): the `⌘K`
    // command palette, now the app's one search/verb surface - it absorbed
    // Shift's own separate ⌘⇧P palette (`ShiftSearchController`, deleted), so
    // there is no second search UI to keep in sync.
    //
    // Its providers are registered in `buildUnifiedSearchIndex()` below, each
    // holding the *shared* store its domain lives in (never a second cached
    // copy - GL-23's own lesson, which is why F5 depends on that fix) and the
    // real action its rows dispatch to.
    //
    // The one exception is `DocsRunbookStore`, which this palette keeps its
    // own instance of (not `appShell`'s private one inside `DocsController`):
    // it re-reads the same git-synced folder fresh on every call, so a second
    // instance costs nothing and caches nothing that could drift - the same
    // reasoning `UpdatesController`/`BootstrapController` already use for
    // their own independent copies of one underlying check (see AGENTS.md).
    let docsRunbookStore = LaunchSignposts.measure("DocsRunbookStore.init") { DocsRunbookStore() }
    lazy var unifiedSearch = UnifiedSearchController(index: buildUnifiedSearchIndex())

    /// UX1's all-destinations map. Lazy, like the search palette beside it -
    /// a captain who never presses ⌘⇧D never builds twenty-six tiles.
    lazy var allDestinations: AllDestinationsOverlayController = {
        let overlay = AllDestinationsOverlayController()
        overlay.onSelect = { [weak self] destination in self?.appShell.workspace.navigator.show(destination) }
        overlay.onTogglePin = { [weak self] destination in
            self?.appShell.toggleQuickAccessPin(destination)
        }
        overlay.isPinned = { [weak self] destination in
            self?.appShell.isQuickAccessPinned(destination) ?? false
        }
        return overlay
    }()

    /// The File menu's one item, held so `menuNeedsUpdate` can re-title it -
    /// UX4. See its construction in `buildMenu` for why the title is part of
    /// the contract rather than decoration.
    var contextualNewItem: NSMenuItem?
    /// Code Preview's ⌘B, held so `menuNeedsUpdate` can say Show or Hide.
    var snippetListItem: NSMenuItem?
    /// F2: the ⌥Space router. Built with the shell's own filer, which is
    /// where every one of the five writes lives (see
    /// `AppShellController.makeCaptureFiler`) - this panel owns no store.
    lazy var shiftQuickCapture: ShiftQuickCaptureController = {
        let capture = ShiftQuickCaptureController(filer: appShell.workspace.makeCaptureFiler())
        return capture
    }()
    lazy var shiftNotifications = ShiftNotificationScheduler(store: shiftStore)
    /// F23: publishes the widget snapshot and drains what a tapped widget
    /// button queued. Holds no store of its own - the `ShiftStore` above and
    /// `appShell`'s one `StickyBoardStore` (GL-23), which is why it is
    /// `lazy`: `appShell` has to exist first.
    lazy var widgetPublisher = WidgetSnapshotPublisher(
        shiftStore: shiftStore,
        stickyStore: appShell.workspace.stickyBoardStore
    )
    /// F2's capture chord. Configurable since
    /// `fm/grandline-capture-global-hotkey-configurable`, so the live
    /// instance is seeded from the stored value rather than from the class's
    /// own default - the same shape `dictationHotkey` below already uses.
    lazy var shiftHotkey = ShiftGlobalHotkey(shortcut: AppSettings.shared.quickCaptureShortcut) { [weak self] in
        self?.shiftQuickCapture.present()
    }

    /// The Shift menu's Capture item, held so the recorded chord can be
    /// re-applied to it without rebuilding the whole menu.
    weak var quickCaptureMenuItem: NSMenuItem?

    /// Print the capture chord on the menu item, or clear it.
    ///
    /// A menu key equivalent can only express a *regular key plus modifiers*.
    /// A modifier-only chord (the recorder accepts one - Right ⌥ on its own,
    /// say) has no menu representation at all, so the item keeps its title and
    /// loses its chord rather than advertising something wrong. The global and
    /// local monitors still carry it; only the printed accelerator goes.
    ///
    /// AGENTS.md's "no key equivalent may be declared twice in
    /// `NSApp.mainMenu`" rule applies to whatever the captain records, and
    /// nothing here can pre-empt that - `NavigationCoherenceSelfTest` fails
    /// the run on a duplicate among the *shipped* items, and a recorded chord
    /// that collides with one of them is the captain's own choice, made
    /// visible by the menu drawing it.
    func applyQuickCaptureMenuChord(_ chord: KeyChord) {
        guard let item = quickCaptureMenuItem else { return }
        guard !chord.isModifierOnly, let character = KeyChord.menuKeyEquivalent(for: chord.keyCode) else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = character
        item.keyEquivalentModifierMask = chord.modifiers
    }
    /// Audit §2 item 7: ⌘T/⌘D/⌘W/⌘R/⇧⌘R/⌘1-9 for Console and Tools tabs,
    /// restored after the Tab menu's removal took them. A local monitor
    /// rather than menu items - see `TabKeyboardShortcuts`'s header for why
    /// a menu is not an option here. Owned alongside the app's other two
    /// monitor-backed shortcuts.
    lazy var tabShortcuts = TabKeyboardShortcuts(
        target: { [weak self] in self?.appShell.workspace.navigator.activeTabShortcutTarget() },
        mainWindow: { [weak self] in self?.window }
    )
    // fm/grandline-dictation-mvp (phase 1): one `DictationEngine` for the
    // app's whole lifetime, driven by `DictationHotkey`'s hold/release
    // callbacks - mirrors `shiftHotkey`/`shiftQuickCapture`'s own shape.
    let dictationEngine = DictationEngine()
    // Phase 2 (fm/grandline-dictation-phase2): transcription history +
    // personal vocabulary, shared by the Dictation page and the engine
    // (vocabulary bias, history recording) - same "one store, every reader/
    // writer shares it" convention as `shiftStore`.
    let dictationStore = LaunchSignposts.measure("DictationStore.init") { DictationStore() }
    // GL-23: one command library for the whole app. The Tasks page's DevOps
    // Commands tab and the Log Analyzer's "from your library" matching both
    // read and write it; two caching instances diverged in-session and
    // last-writer-wins on `recent.yaml`. Same one-store convention as
    // `shiftStore` and `dictationStore` above.
    let commandLibraryStore = LaunchSignposts.measure("CommandLibraryStore.init") { CommandLibraryStore() }
    // F11: the schedules the Automation page's Schedules card manages and
    // `ScheduleRunner` reads. Same one-store convention as `shiftStore`,
    // `dictationStore` and `commandLibraryStore` above - the runner and the
    // card must see the same list, and two instances would be two writers to
    // the same JSON file.
    let scheduleStore = LaunchSignposts.measure("ScheduleStore.init") { ScheduleStore() }
    // fm/grandline-dictation-visual-feedback-hud: the floating on-screen HUD
    // - see DictationHUD.swift's header. Owned here (not by `AppShellController`)
    // since it must appear regardless of whether Grand Line's own window is
    // visible/frontmost.
    let dictationHUD = DictationHUDController()
    // GL-09: dictation is gated on the lock here rather than inside
    // `DictationEngine`, because the gate belongs where the *trigger* is - a
    // hotkey that fires while locked should do nothing at all, not start an
    // engine that then declines. `onUp` is deliberately NOT gated: a recording
    // that was legitimately started before the lock engaged still has to be
    // stopped, or the microphone stays open.
    lazy var dictationHotkey = DictationHotkey(
        shortcut: AppSettings.shared.dictationShortcut,
        onDown: { [weak self] in
            guard AppLockGate.shared.allows(.dictation) else {
                AppLog.lifecycle.info("dictation hotkey refused - app is locked (GL-09)")
                return
            }
            self?.dictationEngine.startRecording()
        },
        onUp: { [weak self] in self?.dictationEngine.stopRecording() }
    )
    // F12 (`fm/grandline-feature-f12-snippet-expander`): the system-wide
    // `;abbrev` expander. One instance for the app's whole lifetime, over the
    // same `snippetStore` the Hosts page edits - same shape as
    // `dictationHotkey`/`shiftHotkey` above, and deliberately the same one
    // Accessibility grant as both. Its monitors are installed only while the
    // captain has turned the feature on; see `SnippetExpander.refresh()`.
    lazy var snippetExpander = SnippetExpander(store: snippetStore)
    // fm/grandline-app-lock: the app-level password lock's timing state
    // machine - see AppLock.swift's header for the idle/hard-logout math.
    let appLock = AppLockController()
    // F4: the `UNUserNotificationCenterDelegate` behind every notification
    // action button (Merge / Open PR / Open task / Snooze 1h / Show in app).
    // Owned here rather than by `AppShellController` for the same reason
    // `dictationHUD` is: it has to work when the app was launched *by* the tap,
    // before any window exists. See NotificationActions.swift's header.
    let notificationRouter = NotificationActionRouter()
    /// Which shell the main window hosts, read once for the process - see
    /// `AppSettings.workspaceLayout` for why a change waits for the next
    /// launch. Both shells host the same `Workspace`; only their chrome
    /// differs (`WorkspaceShellController`'s header).
    let workspaceLayout = AppSettings.shared.workspaceLayout
    // Fix 1: `makeHostConsole` builds a fresh, host-scoped console (its own
    // ssh tab(s) only, no Firstmate host's own Shell tab) for
    // `AppShellController.connectHost` - captured as
    // local constants (not `self`) so this closure, which `appShell` holds
    // onto for its whole lifetime, can't form a retain cycle with `self`.
    lazy var appShell: WorkspaceShellController = {
        let keyStore = self.keyStore
        let snippetStore = self.snippetStore
        // R2-BUG-06: copy names places in the layout this window runs.
        PlaceName.layout = workspaceLayout
        return workspaceLayout.shellType.init(
            // PERF-01: both are autoclosures - evaluated on each page's first
            // use, not here.
            hostsPanel: self.hostsPanel, console: console, settings: self.settingsController,
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: shiftStore,
            dictationStore: dictationStore, commandLibraryStore: commandLibraryStore,
            scheduleStore: scheduleStore,
            // PERF-02: the one `DocsRunbookStore` - the palette's and the
            // shell's pages' - rather than four more built inside the shell.
            docsRunbookStore: docsRunbookStore,
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false) }
        )
    }()
    var hostEditorWindow: NSWindow?
    /// Fix 1: last-seen saved-host ids, so `hostStore.observe` below can
    /// detect a delete (a host id present last time but missing now) and
    /// tear down that host's dedicated page rather than leaving it stranded.
    private var knownHostIDs: Set<UUID> = []

    /// The Hosts page's app-delegate wiring, run once as the page is built
    /// (PERF-01 - see `hostsPanel`).
    private func wireHostsPanel(_ panel: HostsController) {
        // Connect action from the panel: a saved host (has an id) reaches its
        // own dedicated page (Fix 1) - the same one its rail icon opens, via
        // `connectToHost` below; an ad-hoc quick-connect (no saved identity to
        // pin a page to) still opens as a plain tab in the shared Firstmate
        // console, same as before Fix 1.
        panel.onConnect = { [weak self] hostID, label, args, accentHex, keyID, startupSnippetID in
            guard let self else { return }
            if let hostID, let host = self.hostStore.host(id: hostID) {
                self.connectToHost(host)
            } else {
                self.console.openSSH(label: label, args: args, accentHex: accentHex, keyID: keyID, startupSnippetID: startupSnippetID)
                self.appShell.workspace.navigator.show(.console)
            }
        }
        // The pinned "Firstmate" entry (Fix 4) - the same Shell tab
        // the console has always opened at startup, now also reachable from
        // the Hosts list. Unaffected by Fix 1: it's the one destination that
        // deliberately stays on the shared `console`, never a dedicated page.
        panel.onConnectPinned = { [weak self] in
            guard let self else { return }
            self.console.openFirstmateHost()
            self.appShell.workspace.navigator.show(.console)
        }
        // The Hosts page's own quick-actions panel names ⌘K; this is what
        // makes the button do what its label says. Forwarded rather than
        // reached for - that page has never known what an `AppDelegate` is.
        panel.onOpenCommandPalette = { [weak self] in self?.showUnifiedSearch() }
        // The Hosts sidebar's TOOLS rows and its user row. Every one opens
        // something that really exists - see `HostsController.onOpenActivity`
        // for why a nav row with nothing behind it is absent here rather than
        // drawn inert.
        panel.onOpenActivity = { [weak self] in self?.appShell.workspace.navigator.openFleetLog() }
        panel.onOpenCommands = { [weak self] in self?.appShell.workspace.navigator.show(.commandLibrary) }
        panel.onOpenSettings = { [weak self] in self?.appShell.workspace.navigator.show(.settings) }
        panel.onLogout = { [weak self] in self?.appShell.requestLogout() }
        panel.snippetExpansionState = { [weak self] in
            guard let self else { return (enabled: false, trusted: false, armed: false, triggerCount: 0) }
            return (enabled: AppSettings.shared.snippetExpansionEnabled,
                    trusted: self.snippetExpander.isAccessibilityTrusted,
                    armed: self.snippetExpander.isArmed,
                    triggerCount: self.snippetExpander.armedTriggerCount)
        }
        panel.onSnippetExpansionToggled = { [weak self] enabled in
            AppSettings.shared.snippetExpansionEnabled = enabled
            // The settings write alone would leave the monitors exactly as
            // they were - the same trap `DictationHotkey.updateShortcut`'s own
            // header records for the shortcut recorder.
            self?.snippetExpander.refresh()
            // Turning it on is the first moment this feature genuinely needs
            // the permission, which is when this app asks for it (Dictation's
            // own rule). It is the same single grant, so this is a silent
            // no-op for a captain who already granted it for ⌥Space.
            if enabled { self?.snippetExpander.requestPermissionIfNeeded() }
        }
        panel.onRequestAccessibilityTrust = { [weak self] in
            self?.snippetExpander.requestPermissionIfNeeded()
        }
    }

    /// Settings' app-delegate wiring, run once as the page is built (PERF-01 -
    /// see `settingsController`).
    private func wireSettings(_ settings: SettingsController) {
        // Settings > Terminal's font-size stepper (Fix 3) talks straight to
        // the live console; Appearance goes through `ThemeManager` directly
        // since every theme-aware view already observes it.
        settings.onFontSizeStep = { [weak self] delta in
            self?.console.stepFontSize(by: delta)
        }
        // Settings > Security points at the vault rather than drawing the
        // vault's own controls: they live sealed inside the encrypted file,
        // and AGENTS.md is explicit that anything reaching the vault from
        // outside the vault page goes through the vault's own unlock.
        settings.onNavigate = { [weak self] destination in
            self?.appShell.workspace.navigator.show(destination)
        }
        // Settings' three toggles. One callback for all three - see
        // `SettingsController.compactModeToggled`.
        settings.onCompactModeSettingsChanged = { [weak self] in
            self?.compactMode.refresh()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // F2: read the saved session BEFORE anything else, because launch
        // itself navigates. `AppShellController.loadView` ends with a real
        // `show(...)` (GL-31's landing decision), which reaches
        // `updateRecentDestinations` - and once `onSessionStateChanged` is
        // wired further down, that path *writes*. Reading here rather than at
        // the point of use removes the ordering dependency entirely: moving
        // the wiring earlier, which is an easy and invisible mistake, can no
        // longer clobber the state with "wherever launch happened to land"
        // before it has been restored.
        let savedSession = AppSettings.shared.sessionRestoreState

        // Nav-redesign task, item 3: Add/Edit Host is a dedicated full-page
        // window, not a sheet on this ~240pt-wide panel.
        appShell.workspace.onPresentHostEditor = { [weak self] host in
            self?.presentHostEditor(for: host)
        }
        // F9 (v1) - multi-host command execution. Here rather than in
        // `AppShellController` because this is the one object holding the host
        // store, and `connectToHost`'s own argv resolution
        // (`Host.sshArguments(allHosts:)`) needs the full host list to resolve
        // a jump chain.
        appShell.workspace.onSendCommandToHosts = { [weak self] command, values, generated in
            self?.presentMultiHostSend(command: command, values: values, generatedText: generated)
        }
        // Fix 3 (fixes4) pinned a rail icon per saved host here. Daylight
        // Phase 2 removed the rail (§5.1), and the canvas's Hosts module plus
        // the Hosts page's own Connect are the two ways in now - both of which
        // already reach the same `connectToHost` path this did.
        knownHostIDs = Set(hostStore.hosts.map { $0.id })
        // Finding 4 (cockpit-audit-core): a corrupted hosts.json comes up as
        // an empty list with no other signal - surface that once here rather
        // than letting the captain mistake it for "nothing saved yet".
        if let notice = StoreLoadFailure.notice(for: hostStore.loadStatus, what: "saved hosts") {
            appShell.showToast(notice)
        }
        // GL-01: the same treatment for the three stores that used to fail
        // *silently*. Backing the file up is the durability half; saying so is
        // what makes it recoverable - a captain who is never told will not go
        // looking for a `.corrupt-` file. Staged over a second apart so two
        // simultaneous failures do not overwrite each other's toast.
        //
        // Keys first and most emphatically: losing key metadata orphans the
        // Keychain blobs those entries pointed at, and nothing else can clean
        // them up afterwards.
        //
        // REL-21: a file that could not be read at all is reported here too,
        // with the sentence that matches what the store now does about it -
        // it leaves the file alone rather than backing it up and moving on.
        var storeFailureNotices: [String] = []
        if let notice = StoreLoadFailure.notice(for: keyStore.loadStatus, what: "saved SSH keys") {
            storeFailureNotices.append(notice + ". Keychain entries for those keys are still there.")
        }
        if let notice = StoreLoadFailure.notice(for: snippetStore.loadStatus, what: "saved snippets") {
            storeFailureNotices.append(notice)
        }
        for status in [dictationStore.historyLoadStatus, dictationStore.vocabularyLoadStatus] {
            if let notice = StoreLoadFailure.notice(for: status, what: "a dictation file") {
                storeFailureNotices.append(notice)
            }
        }
        // F11: same treatment for schedules. Worth saying out loud rather than
        // silently starting with none, because an unreadable file means every
        // scheduled run stops happening with nothing else anywhere reporting
        // it - the schedules simply are not there to be due.
        if let notice = StoreLoadFailure.notice(for: scheduleStore.loadStatus, what: "saved schedules") {
            storeFailureNotices.append(notice + ". Nothing is scheduled until they are set up again.")
        }
        for (index, notice) in storeFailureNotices.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(index) * 4) { [weak self] in
                self?.appShell.showToast(notice)
            }
        }
        // Finding 4.3: a Recents `.host` row whose session has since ended
        // reconnects instead of doing nothing. Forward-don't-own - the shell
        // has no `HostStore`, so it asks here, and this routes through the
        // same `connectToHost` every other reconnect in the app uses. Returns
        // false only when the host is no longer saved at all, which is what
        // tells the shell to drop the row.
        appShell.workspace.navigator.onReconnectHost = { [weak self] hostID in
            guard let self, let host = self.hostStore.hosts.first(where: { $0.id == hostID }) else { return false }
            self.connectToHost(host)
            return true
        }
        hostStore.observe { [weak self] in
            guard let self else { return }
            let currentIDs = Set(self.hostStore.hosts.map { $0.id })
            // Fix 1: a host id that was known last time but isn't anymore was
            // deleted - tear down its dedicated page so the rail (which just
            // lost that host's icon) can't leave it stranded.
            for removedID in self.knownHostIDs.subtracting(currentIDs) {
                self.appShell.workspace.hosts.removeHostConsole(id: removedID)
                // Finding 4.3: a deleted host's page is the one Recents row
                // that is genuinely unreachable - it can neither switch to a
                // live session nor reconnect - so it stops being listed here
                // rather than waiting to be clicked and found dead. A host
                // page merely *closed* is untouched: that one reconnects.
                self.appShell.workspace.navigator.forgetRecentHost(id: removedID)
            }
            self.knownHostIDs = currentIDs
        }
        // The Snippets tab's "Run" (Phase 3, B2) sends straight to the
        // console's active tab.
        appShell.workspace.onRunSnippet = { [weak self] snippet in
            self?.console.runSnippetInActiveTab(snippet)
        }

        // `fm/grandline-settings-page-redesign`: Settings > Appearance's
        // "Follow system appearance". Started unconditionally - the observer
        // costs nothing while the setting is off, and registering it here is
        // what makes switching it on take effect without a relaunch. It also
        // applies the system's current mode immediately, which is what puts a
        // captain who follows the system on the right half of their pair
        // after an overnight switch.
        SystemAppearanceFollower.shared.start()

        // Settings > Terminal's "Bell & notifications" toggle (Fix 3): this
        // only ever gates whether a macOS banner is ALSO posted for a
        // needs-decision/blocked task - see `FleetNotifier.setEnabled`'s own
        // comment. `FleetNotifier.shared.start()` below always runs
        // regardless, since the in-app Notification Center
        // (`fm/grandline-notification-center`) must stay current whether or
        // not the captain wants OS banners too.
        FleetNotifier.shared.setEnabled(AppSettings.shared.notifyOnNeedsDecision)
        FleetNotifier.shared.onNavigateToOverview = { [weak self] in self?.appShell.workspace.navigator.show(.overview) }
        // E3: the shared "has the captain actually been away for a while?"
        // answer the gated pollers below consult. Registered before any of
        // them start.
        AppActivityState.shared.start()
        FleetNotifier.shared.start()

        // F4: notification action buttons. Every closure here points at the
        // code path the in-app UI already uses - `AppShellController`'s own
        // navigation and `ShiftStore.snoozeFollowUp` - so a notification action
        // and a click inside the app cannot diverge. The merge path needs no
        // wiring: the router defaults to `FleetDataSource.mergePR`, the exact
        // function Review's own Merge button calls.
        //
        // Registered here (not later) because the delegate must be set before
        // `applicationDidFinishLaunching` returns, or an action tap that
        // cold-launched the app is dropped by the system.
        notificationRouter.onShow = { [weak self] destination in self?.appShell.workspace.navigator.show(destination) }
        notificationRouter.onOpenShiftTask = { [weak self] id in self?.appShell.workspace.navigator.openShiftTask(id: id) }
        notificationRouter.onOpenShiftFollowUp = { [weak self] id in self?.appShell.workspace.navigator.openShiftFollowUp(id: id) }
        notificationRouter.onSnoozeFollowUp = { [weak self] id, date in
            self?.shiftStore.snoozeFollowUp(id: id, to: date)
        }
        notificationRouter.register()

        // fm/grandline-notification-center: the slow background poll for the
        // four signals that otherwise only ever recompute on a page visit
        // (tool updates, GitHub Sync drift, Vault attention, Bootstrap
        // setup drift) - see `BackgroundSignalsPoller.swift`'s header for
        // the cadence tradeoff.
        BackgroundSignalsPoller.shared.onNavigateToUpdates = { [weak self] in self?.appShell.workspace.navigator.show(.updates) }
        BackgroundSignalsPoller.shared.onNavigateToGitHubSync = { [weak self] in self?.appShell.workspace.navigator.show(.githubSync) }
        // The per-tool / per-repo halves of the two above, for the
        // notification popover's expanded child rows.
        BackgroundSignalsPoller.shared.onUpdateTool = { [weak self] id in
            self?.appShell.workspace.navigator.updateToolFromNotification(id)
        }
        BackgroundSignalsPoller.shared.onSyncFork = { [weak self] id in
            self?.appShell.workspace.navigator.syncForkFromNotification(id)
        }
        BackgroundSignalsPoller.shared.onNavigateToVault = { [weak self] in self?.appShell.workspace.navigator.show(.vault) }
        BackgroundSignalsPoller.shared.onNavigateToBootstrap = { [weak self] in self?.appShell.workspace.navigator.show(.bootstrap) }
        BackgroundSignalsPoller.shared.start()

        // fm/grandline-herdr-selection-color-sync: keep herdr's own
        // `[theme.custom].selection_bg` (~/.config/herdr/config.toml) in
        // sync with the active Helm theme's accent, so a Shift+drag on a
        // `.shell` tab with drag-forwarding on - which forwards the gesture
        // to herdr and shows herdr's *own* selection rendering - reads in
        // the same colour as everything Grand Line draws itself. No
        // closures to wire: unlike the pollers above, this reacts to
        // `ThemeManager` directly and needs nothing from `AppShellController`.
        HerdrThemeSync.shared.start()

        // `fm/grandline-bootstrap-dotfiles-autocommit`: watch the dotfiles
        // repo's `home/` tree and commit+push edits to it automatically. Wired
        // right beside `HerdrThemeSync` on purpose - that class writes
        // `~/.config/herdr/config.toml`, which is an out-of-store symlink into
        // exactly that tree, so it is one of the writers this watches for. Like
        // it, this needs nothing from `AppShellController`.
        DotfilesAutoSync.shared.start()

        // F11 follow-up: seed the "daily-github-sync" schedule once - a daily
        // 11:10 AM fast-forward of every personal fork, exactly what Setup >
        // GitHub Sync's "Sync All" button already does (`ScheduleActions.
        // forkSync()`). See `ScheduleSeeding.swift`'s header for why this is
        // safe to call on every launch (idempotent, guarded by a persisted
        // one-time flag) rather than only the first.
        ScheduleSeeding.seedDailyGitHubSyncIfNeeded(
            store: scheduleStore,
            alreadySeeded: { AppSettings.shared.didSeedDailyGitHubSyncSchedule },
            markSeeded: { AppSettings.shared.didSeedDailyGitHubSyncSchedule = true }
        )

        // F11: the schedule runner. Distinct from the poller above in the one
        // way that matters - the poller answers "is anything wrong right now"
        // on a cadence nobody chose, while this runs the specific actions the
        // captain asked for at the times they asked for. Both are timers; only
        // this one has a captain-authored schedule behind it.
        // fm/grandline-schedules-sidebar-move: the Schedules card lives on
        // its own rail destination now, not `.automation`.
        //
        // grandline-schedule-daily-updates: seeds the captain-requested
        // "daily-updates" schedule exactly once, ever, on a fresh
        // schedules.json - see `ScheduleStore.seedDailyUpdatesScheduleIfNeeded`'s
        // own doc comment for why this call site (real app launch only, never
        // `ScheduleStore.init()`) is what keeps it out of every self-test that
        // constructs a bare `ScheduleStore()`. Must run before `.start(...)`
        // below, so the freshly-seeded schedule is in `store.schedules` by the
        // time the runner's first tick can see it.
        scheduleStore.seedDailyUpdatesScheduleIfNeeded()
        ScheduleRunner.shared.onNavigateToSchedules = { [weak self] in self?.appShell.workspace.navigator.show(.schedules) }
        ScheduleRunner.shared.start(store: scheduleStore,
                                    hostStore: hostStore,
                                    keyStore: keyStore,
                                    snippetStore: snippetStore,
                                    dictationStore: dictationStore)

        // Phase 5 (cockpit-shift-power-features): menu bar popover + global
        // quick capture + due-item notifications, all reading/writing the one
        // shared `shiftStore` above - never a second instance. (Its fourth
        // member, the ⌘⇧P search palette, was absorbed into ⌘K by F5.)
        //
        // F5: `⌘K` opens the one palette app-wide - the topbar Search pill
        // (wired below), the Edit menu's `⌘K` item, and nothing else. Every
        // row's action was wired into its provider in
        // `buildUnifiedSearchIndex()`; there is no per-result callback here
        // any more, and no second palette (⌘⇧P is gone with
        // `ShiftSearchController`).
        //
        // The bar's Search pill's click, forwarded through `AppShellController.
        // onSearchTapped` (see that property's own doc comment) - not
        // `appShell.bar.onSearchTapped` directly, since `loadView()` (run
        // later, once `window.contentViewController = appShell` is assigned
        // below) wires that control to call back through this property, and
        // would silently clobber a direct assignment made before that point.
        appShell.workspace.onSearchTapped = { [weak self] in self?.unifiedSearch.present() }
        // ⌘K's own "All Destinations…" verb, forwarded the same way the
        // Search pill's click is - and for the same reason the line above
        // gives: `loadView()` has not run yet, so this has to be the shell's
        // property rather than anything reached through `appShell.bar`.
        //
        // **This assignment was missing, and that made the verb dead.** The
        // property existed and `UnifiedSearchProviders` called it, but nothing
        // in the app ever set it, so ⌘K → "All Destinations…" silently did
        // nothing - the same defect, in a second entry point, that
        // `fm/grandline-remove-dead-all-destinations-overflow` removed from
        // the bar's overflow menu. The overlay itself was never broken; only
        // the routes into it were, and ⌘⇧D/Go went through `showAllDestinations`
        // directly and so always worked.
        appShell.onShowAllDestinations = { [weak self] in self?.showAllDestinations() }
        // F2: the toast names where it went, because the router has five
        // answers now and "Task captured" would be wrong for four of them.
        shiftQuickCapture.onCaptured = { [weak self] destination in
            self?.appShell.showToast("Captured to \(destination.railDestination.title)")
        }
        // The global hotkey's system-wide (other-app-frontmost) case needs
        // Accessibility permission - see `ShiftGlobalHotkey`'s header for
        // exactly why. Requesting it here (once, at launch) surfaces the
        // real macOS prompt the first time this app ever runs rather than
        // silently failing later.
        // F3: arm the clipboard-history capture loop. Once, here - see
        // `ClipboardHistoryController.startCapturing()` for why not at init.
        appShell.startClipboardHistoryCapture()
        shiftHotkey.requestPermissionIfNeeded()
        shiftHotkey.start()
        // The prompt above opens System Settings, so a captain granting
        // Accessibility for the first time grants it *after* the global
        // monitor was installed - and macOS never arms an already-registered
        // global monitor retroactively. Coming back to this app is the first
        // moment we can notice, and the check costs one `AXIsProcessTrusted()`
        // read. See `ShiftGlobalHotkey.reassertIfTrustChanged()`.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.shiftHotkey.reassertIfTrustChanged()
            // B20: the snippet expander's global monitor is armed from the
            // same one grant and has exactly the same retroactivity problem.
            self?.snippetExpander.reassertIfTrustChanged()
        }
        tabShortcuts.start()
        // fm/grandline-notification-center: feeds the same due-detection
        // `poll()` already computes for the OS banner into the in-app
        // Notification Center too, rather than only firing a one-shot
        // banner with no record afterward.
        shiftNotifications.onDueCountsChanged = { [weak self] taskCount, followUpCount, overdueCount in
            NotificationSources.setShiftDue(taskCount: taskCount, followUpCount: followUpCount,
                                            overdueCount: overdueCount) {
                self?.appShell.workspace.navigator.showShiftDestination()
            }
        }
        shiftNotifications.start()

        // fm/grandline-dictation-mvp: unlike `shiftHotkey` above, Dictation
        // deliberately does NOT request Accessibility trust eagerly at
        // launch - the task brief asks each Dictation permission to be
        // requested "the first time it's genuinely needed," which for
        // Accessibility is the Dictation page's own status action (or, if
        // Shift's own eager request above already granted it, this monitor
        // just starts working with no further prompt needed - it's the same
        // one process-wide Accessibility trust grant). The hotkey's
        // local+global monitors are still registered now regardless -
        // registering them is free and has nothing to do with whether the
        // grant exists yet.
        dictationEngine.onStatusChanged = { [weak self] status, isCeilingTimeout in
            self?.appShell.workspace.setDictationEngineStatus(status)
            self?.dictationHUD.handle(status, isCeilingTimeout: isCeilingTimeout)
        }
        // Phase 2: bias recognition toward the captain's personal vocabulary,
        // and record every successful (real, pasted) transcript into
        // history - both read/write the one shared `dictationStore` above.
        dictationEngine.vocabularyProvider = { [weak self] in self?.dictationStore.vocabulary ?? [] }
        // Phase 3: read the "Clean up my sentences" toggle fresh at the
        // moment each dictation finishes - see `AppSettings.dictationCleanupEnabled`'s
        // own doc comment for why this defaults to off.
        dictationEngine.cleanupEnabledProvider = { AppSettings.shared.dictationCleanupEnabled }
        // fm/grandline-dictation-whisper-engine: read the "Use local Whisper
        // engine" toggle fresh at the start of every recording - see
        // `AppSettings.dictationLocalWhisperEnabled`'s own doc comment for
        // why this defaults to off.
        dictationEngine.localWhisperEnabledProvider = { AppSettings.shared.dictationLocalWhisperEnabled }
        dictationEngine.onTranscript = { [weak self] text, duration in
            self?.dictationStore.recordHistory(text: text, durationSeconds: duration, date: Date())
        }
        // Phase 2: the Dictation page's shortcut recorder edits
        // `AppSettings.dictationShortcut` itself and reports the change here
        // so the *live* hotkey instance actually picks it up - a plain
        // settings write with no restart would leave the old monitor
        // installed (see `DictationHotkey.updateShortcut`'s own header).
        appShell.workspace.onKeyChordChanged = { [weak self] shortcut in
            self?.dictationHotkey.updateShortcut(shortcut)
        }
        // Settings > Terminal Shortcuts writes `AppSettings.terminalShortcuts`
        // itself and reports the change here so the *live* monitor picks it
        // up on the very next keystroke - the same reason Dictation's
        // recorder reports rather than relying on a settings read per event.
        appShell.workspace.onTerminalShortcutsChanged = { [weak self] shortcuts in
            self?.tabShortcuts.updateTerminalShortcuts(shortcuts)
        }
        // Settings > Capture's recorder, forwarded the same way and for the
        // same reason. The Shift menu's own Capture item is re-keyed here too:
        // it is the no-Accessibility fallback for this exact chord, and a menu
        // still advertising ⌥Space after the captain recorded ⌃⌘C would be a
        // page stating a shortcut the app no longer listens for.
        appShell.workspace.onQuickCaptureShortcutChanged = { [weak self] chord in
            self?.shiftHotkey.updateShortcut(chord)
            self?.applyQuickCaptureMenuChord(chord)
        }
        // E2: turning the toggle off releases any engine that is still
        // resident, so the captain's "off" takes effect now rather than at the
        // next idle expiry.
        appShell.workspace.onDictationLocalWhisperChanged = { [weak self] enabled in
            guard !enabled else { return }
            self?.dictationEngine.releaseWhisperEngine(reason: "local Whisper turned off")
        }
        dictationHotkey.start()

        // F12. Three wirings, all of them "ask the one place that knows":
        // whether a terminal is on screen (the `.consoleOnly` scope's whole
        // question), the store's own change signal, and the page's card (in
        // `wireHostsPanel`, since PERF-01 builds that page on first use).
        snippetExpander.isConsoleFocusedProvider = { [weak self] in
            self?.appShell.workspace.navigator.isTerminalDestinationShowing ?? false
        }
        snippetStore.observe { [weak self] in self?.snippetExpander.rebuildTable() }
        // Off by default, so on a fresh install this installs nothing at all.
        snippetExpander.refresh()

        // `shiftMenuBar` is `lazy` - force it into existence now so its
        // `NSStatusItem` actually appears at launch rather than only the
        // first time something else happens to reference the property.
        _ = shiftMenuBar

        // `fm/straw-hat-menubar-quick-chat-popover`: same reason, same
        // pattern. `onAsk` forwards into `AppShellController.
        // askCrewFromMenuBar`, which is `StrawHatController.send(_:completion:)`
        // - the crew page's own real runner and transcript, never a second
        // conversation. `onOpenFullChat` is the popover's persistent
        // "Open Straw Hat Pirates" affordance.
        strawHatMenuBar.onAsk = { [weak self] text, completion in
            self?.appShell.workspace.askCrewFromMenuBar(text, completion: completion)
        }
        strawHatMenuBar.onOpenFullChat = { [weak self] in self?.appShell.workspace.navigator.show(.strawHat) }
        _ = strawHatMenuBar

        // F16: same pattern, same reason for forcing the `lazy` property.
        // Every closure forwards into `AppShellController`, which forwards
        // into the one `CredentialVaultController` and its one store.
        poneglyphMenuBar.codesProvider = { [weak self] in self?.appShell.workspace.poneglyphQuickCodes ?? [] }
        poneglyphMenuBar.vaultIsUnlocked = { [weak self] in self?.appShell.workspace.poneglyphIsUnlocked ?? false }
        poneglyphMenuBar.onCopy = { [weak self] id in self?.appShell.workspace.copyPoneglyphCodeFromMenuBar(id: id) }
        poneglyphMenuBar.onOpenVault = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window.makeKeyAndOrderFront(nil)
            self?.appShell.workspace.navigator.show(.poneglyph)
        }
        _ = poneglyphMenuBar

        // F22. Same forward-don't-own pattern as the three above, and the
        // same reason for forcing the `lazy` properties - except that this
        // one starts *hidden* and `compactMode.refresh()` (further down, once
        // the window exists) is what decides whether it appears.
        wireCompactMode()

        buildMenu()

        // fm/grandline-app-lock: wire the lock state machine to the shell's
        // overlay and to the menu-disable safety net below. The actual
        // `.launch` lock happens further down, *after* `window.contentViewController
        // = appShell` below has forced `AppShellController.loadView()` to run
        // at least once - `showLock` sets `lockScreen.view.isHidden = false`,
        // but `loadView()` itself unconditionally sets that same property to
        // `true` right after embedding the view (its default hidden state);
        // locking before `loadView()` has ever run meant that default-hidden
        // assignment executed *after* `showLock`'s and silently re-hid the
        // overlay - confirmed live (a real launch dump showed
        // `overlayHidden=true` immediately after `showLock` had already run
        // and correctly disabled the menu). Locking after the window/
        // contentViewController assignment below closes that race.
        appLock.onLock = { [weak self] reason in self?.appShell.workspace.lock.showLock(reason: reason) }
        // R2-UX-01: the lock is off, so the launch opens the app instead.
        appLock.onOpenWithoutLock = { [weak self] in self?.appShell.workspace.lock.openWithoutLock() }
        appShell.workspace.lock.onUnlocked = { [weak self] in self?.appLock.recordUnlock() }
        appShell.onLogoutRequested = { [weak self] in self?.appLock.lock(reason: .manualLogout) }
        appShell.workspace.lock.onLockStateChanged = { [weak self] locked in self?.setContentMenusEnabled(!locked) }
        appLock.start()

        // The window opens filling the screen's usable area, not a hardcoded
        // 1220x720 box.
        //
        // This is **half** of the captain's "the window doesn't cover the
        // laptop screen" report (`01-live-window-not-fullscreen.png`): a fixed
        // content rect plus `center()` meant the window simply never asked for
        // more than 1220x720. The other half was a real Auto Layout constraint
        // that capped the window at 1410pt wide no matter what was asked for,
        // including in genuine full screen - see the priority note on
        // `ToolRowLayout.build`'s name-column constraint
        // (`HelmUIComponents.swift`). Both had to go; either one alone still
        // left black bars.
        //
        // `visibleFrame` (not `frame`) so the menu bar and the Dock are
        // excluded, and it is applied as the *window* frame (title bar
        // included) so nothing is pushed off the top of the screen.
        //
        // **A1 of the UI modernization audit** (`data/grandline-ui-
        // modernization-audit/report.md` §3A) adds `.fullSizeContentView`
        // here: the content view then covers the whole window and the
        // floating bar becomes the top edge, reclaiming the stock titlebar's
        // height (measured: 32pt, not the report's estimated ~28). The rest
        // of that treatment - the transparent, titleless titlebar and the
        // traffic lights re-centred onto the bar - is `WindowChromeFusion`;
        // see its header for every measured number and for why the lights
        // have to be repositioned from a `layout()` hook.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Still set, and still worth setting, even though `titleVisibility`
        // hides it: the Window menu, Mission Control and the window's own
        // proxy menu all read it.
        window.title = Self.windowTitle(context: appShell.workspace.navigator.currentContextTitle)
        // **Review bug B8.** `isReleasedWhenClosed` defaults to `true` for a
        // window created with `init(contentRect:...)`, and this one is
        // referenced for the app's whole life - `AppDelegate.window`, the
        // resize observers, `FullScreenMenuBarFill`, `WindowChromeFusion`'s
        // per-window cluster cache, the lock overlay.
        //
        // With the stock `applicationShouldTerminateAfterLastWindowClosed`
        // answer the red button quits the app, so the release is harmless. In
        // **compact mode** that answer is `false`
        // (`CompactModePolicy.terminatesAfterLastWindowClosed`), so the red
        // button closes this window while the process keeps running - and
        // then releases a window every one of those references still holds.
        // The host editor window two hundred lines below already sets this,
        // for the same reason; the main window never did because until
        // compact mode shipped it could not outlive its own close.
        window.isReleasedWhenClosed = false
        // The floating bar becomes the window's top edge; the sidebar shell
        // keeps the system title bar and installs its own toolbar once its
        // view is in this window (`MainSplitShellController.attach(to:)`).
        if workspaceLayout == .floatingBar {
            WindowChromeFusion.apply(to: window)
        }
        fullScreenMenuBarFill = FullScreenMenuBarFill(window: window)
        // **`contentViewController` first, then the frame.** Assigning a
        // content view controller makes AppKit re-derive the window's frame
        // from that content's Auto Layout fitting size (AGENTS.md's
        // host-editor gotcha (3), in its milder form) - so setting the frame
        // *before* this line is silently undone. Measured with a real window:
        // set to 1512x950 and then given a content view controller, it came
        // back 960x652, i.e. exactly `contentMinSize` plus the title bar.
        // Review #3 §7: every navigation renames the window, so Mission
        // Control and the Window menu say which page this is. Registered
        // before `contentViewController`, which is what first lays the shell
        // out - a `show(_:)` during that pass then already finds a handler.
        if !appShell.namesThePageInTheTitleBar {
            appShell.workspace.navigator.onCurrentDestinationChanged = { [weak window] context in
                window?.title = Self.windowTitle(context: context)
            }
        }
        window.contentViewController = appShell
        window.contentMinSize = Self.minContentSize
        window.setFrame(Self.defaultWindowFrame(), display: false)
        // `setFrameAutosaveName` after the frame is set: with no saved frame
        // yet (first launch on this machine) AppKit keeps what we just asked
        // for, and from then on the captain's own resize/zoom is what is
        // restored - so this sets a sane default without overriding a
        // deliberate later choice.
        window.setFrameAutosaveName(Self.windowAutosaveName)
        // Theme-audit task: the window's own chrome (title bar) has no view
        // to force `.appearance` on, so without this it always follows the
        // OS's actual light/dark setting rather than the active Helm theme.
        window.followHelmTheme()
        // K3: install the theme crossfade now that there is a window to
        // snapshot. Deliberately here rather than in `AppShellController`,
        // which several window-backed self-tests mount and then re-theme -
        // see `ThemeTransition.swift`'s header.
        ThemeManager.shared.transitionCoordinator = ThemeTransitionCoordinator(window: window)
        // P3 of the polish report: the outgoing page fades too. Installed here
        // and nowhere else, for the same reason (`PageCrossfade`'s header).
        appShell.workspace.content.pageCrossfade = PageCrossfade()
        // Armed here for the same reason: a window-backed suite sets frames
        // wider than CI's 1024pt display on purpose, and an armed guard would
        // put them back (`WindowOverflowGuard`'s header).
        appShell.workspace.windowOverflowGuard.arm(for: window)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // F22: only now, with a real window to hide. `refresh()` is what puts
        // the status item in the menu bar, hides the three it merges, sets the
        // activation policy and - if the captain left the mode on last
        // session - orders this window straight back out. Deliberately after
        // `makeKeyAndOrderFront` rather than instead of it: the window is
        // built, laid out and session-restored exactly as it always was, so
        // leaving compact mode later is instant and `AppShellController`'s own
        // launch-time width tie (gotcha (14)) still runs against a real,
        // visible window.
        compactMode.refresh()

        // `loadView()` has now run at least once (triggered by the
        // `contentViewController` assignment above) - lock now so the very
        // first frame the captain sees is the lock screen, not the console.
        appLock.lock(reason: .launch)

        // F23: the widgets. `start()` registers the store/lock observers,
        // publishes once and applies anything a widget button queued while
        // the app was not running.
        //
        // **Deliberately after the window and after `.launch`'s lock**, for
        // two reasons rather than one. It reads `appShell.stickyBoardStore`,
        // and forcing that `lazy` property earlier would move
        // `AppShellController`'s construction ahead of the carefully-ordered
        // window/`contentViewController`/lock sequence above - which the
        // comment on `appLock.onLock` explains has already been got wrong
        // once. And publishing *after* the launch lock means the first
        // snapshot this process ever writes is the locked one, so a relaunch
        // cannot flash yesterday's tasks onto the desktop before the password
        // has been typed (GL-09).
        //
        // Cheap by construction - one small JSON write against
        // already-loaded in-memory arrays, no subprocess and no file read
        // (GL-12).
        widgetPublisher.start()

        // F2: keep the saved session current on every navigation, so a crash
        // or a force-quit loses at most whatever changed since the last one.
        appShell.workspace.navigator.onSessionStateChanged = { [weak self] in self?.saveSessionState() }

        // F2 (audit §2 item 1). After `loadView` (which is what makes GL-31's
        // own first-run landing decision) and behind the lock screen, so
        // nothing restored is visible before the captain has unlocked.
        restoreSessionIfNeeded(savedSession)
        presentWelcomeIfNeeded()

        // The rename's Keychain migration (docs/history/45-rename-to-grand-line.md's
        // third entry). Deliberately not on the launch path any more: it is a
        // chain of blocking Keychain reads that can each show a real system
        // dialog, and running it before the window existed is what left a
        // captain with several legacy accounts unable to launch at all -
        // `LegacyNameMigration.runKeychainMigrationInBackground`'s own header
        // has the full story. Dispatched here, off the main thread (GL-25),
        // now that the window is up and the captain can already use the app;
        // the short delay just keeps it off the very first frame's own layout
        // and session-restore work above.
        //
        // B4: a scratch-redirected process (a probe) has no business writing
        // real Keychain items under the app's own service names - see the
        // matching guard on `runAtLaunch()`.
        //
        // The Today page's and the calendar integration's leftovers go in the
        // same block, after the migration rather than beside it: both touch
        // the Keychain, and running them one after the other on one queue
        // means a captain sees at most one system dialog at a time.
        if !AppPaths.isScratchRedirected() {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                LegacyNameMigration.runKeychainMigrationInBackground()
                TodayCalendarRetirement.runIfNeeded()
            }
        }
    }

    /// Review #3's UX13: the first-run welcome sheet.
    ///
    /// **Registered behind the lock, not shown over it.** `appLock.lock` runs
    /// a few lines above, and a sheet presented now would sit on top of the
    /// lock screen - so a second user would meet a cheerful three-step tour
    /// layered over the password prompt the finding is complaining about.
    /// Instead this waits for the first unlock, which is the first moment the
    /// captain is actually in the app.
    ///
    /// `AppLockGate.observe` fires immediately at registration with the
    /// current state (the same convention `ThemeManager.observe` follows), so
    /// an app that is somehow already unlocked is handled by the same path
    /// rather than by a second one.
    private func presentWelcomeIfNeeded() {
        guard !AppSettings.shared.hasSeenWelcome else { return }
        var presented = false
        AppLockGate.shared.observe { [weak self] locked in
            guard let self, !locked, !presented,
                  !AppSettings.shared.hasSeenWelcome else { return }
            presented = true
            let welcome = WelcomeSheetController()
            self.appShell.presentAsSheet(welcome)
        }
    }

    // MARK: F2 - session restoration

    /// Reopens where the captain was. See `SessionRestore.swift` for exactly
    /// what is and is not restored.
    ///
    /// **GL-31 wins.** A machine with no firstmate home resolved lands on
    /// Bootstrap, and a saved destination must not drag it away from the page
    /// that fixes the cause - that landing is the whole point of GL-31's
    /// exception. Tabs are still restored in that case; only the destination
    /// defers.
    private func restoreSessionIfNeeded(_ saved: SessionRestoreState?) {
        guard let state = saved, !state.isEmpty else { return }
        // T-14d: the first-frame-to-idle interval PERF-08 is measured by.
        let interval = LaunchSignposts.begin("restoreSessionIfNeeded")
        defer { LaunchSignposts.end("restoreSessionIfNeeded", interval) }

        appShell.workspace.navigator.restoreTabs(from: state)

        // Every host that had a page, reconnected with `navigate: false` - so
        // each page exists but stays hidden, and (per `ConsoleController.
        // addTab`'s `hasAppeared` guard) forks no `ssh` until the captain
        // actually opens it. The one that was *showing* is connected
        // straight away, with navigation, so it is the page that comes up.
        // `uniquingKeysWith`, never `uniqueKeysWithValues`: the latter traps
        // on a duplicate key, and this runs on the launch path against a file
        // that can be hand-edited. `HostStore` should never produce two hosts
        // with one id, but a crash at launch is a far worse answer to that
        // than quietly keeping the first.
        let byID = Dictionary(hostStore.hosts.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        let plan = SessionRestorePlan.hosts(from: state, knownHostIDs: Set(byID.keys))
        // PERF-08: queued rather than built here. The shell builds one page
        // per run-loop turn (and a page the captain switches to at once), so
        // five restored hosts are five short turns rather than one long one
        // right after the first frame. Each still gets its strip pill now, in
        // this order, so the showing host below still registers last.
        appShell.workspace.hosts.queueRestoredHostConsoles(plan.background.compactMap { id in
            byID[id].map { ($0, $0.sshArguments(allHosts: hostStore.hosts)) }
        })

        guard FirstmateHome.homeOk() else {
            AppLog.lifecycle.info("session restore: tabs restored, destination left to GL-31's Bootstrap landing")
            return
        }

        if let showing = plan.showing, let host = byID[showing] {
            connectToHost(host)
        } else {
            appShell.workspace.navigator.restoreDestination(from: state)
        }
    }

    /// Records where the captain is, for the next launch.
    ///
    /// Called on quit and on every navigation - the second is what makes this
    /// survive a crash or a force-quit, and it is cheap: the comparison is
    /// against `SessionRestoreStore`'s in-memory copy (R2-BUG-11), and the
    /// file is written only when the result actually differs, since most
    /// navigations change nothing.
    func saveSessionState() {
        guard appShell.isViewLoaded else { return }
        let state = appShell.workspace.navigator.captureSessionState()
        guard state != AppSettings.shared.sessionRestoreState else { return }
        AppSettings.shared.sessionRestoreState = state
    }

    /// The main window's saved-frame key. Once the captain resizes or zooms
    /// the window, AppKit restores that instead of the default below.
    static let windowAutosaveName = "GrandLineMainWindow"

    /// Never smaller than this. Deliberately below any real Mac's usable
    /// height so it can never fight `defaultWindowFrame` - it only stops the
    /// captain dragging the window down to a size where the destinations
    /// stop being readable.
    static let minContentSize = NSSize(width: 960, height: 620)

    /// The window's title, from the running bundle rather than a literal.
    ///
    /// The end-to-end review's INFO finding: this was hardcoded
    /// `"Grand Line"`, so the sanctioned probe app
    /// (`Scripts/build-probe-app.sh`, its own bundle id and 17 scratch store
    /// overrides) put the *real* app's name in its own title bar - and a probe
    /// screenshot was then indistinguishable from a screenshot of the
    /// captain's live instance. That is a genuine review hazard rather than a
    /// cosmetic one: this app has no process isolation between builds sharing
    /// a bundle identity, so "which instance is this?" is exactly the question
    /// a screenshot has to answer. The probe's plist already says "Grand Line
    /// Probe", so reading the bundle makes it say so with no per-build flag.
    ///
    /// The fallback chain matters because a plain `swift build` binary has no
    /// `Info.plist` at all (the dev flow this repo documents), which is why
    /// the literal survives as the last resort rather than leaving a dev
    /// window titled "GrandLine" or blank.
    static func windowTitle() -> String {
        let info = Bundle.main.infoDictionary
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = info?[key] as? String,
               !name.trimmingCharacters(in: .whitespaces).isEmpty {
                return name
            }
        }
        return "Grand Line"
    }

    /// The app name plus whatever page is on screen.
    ///
    /// **Review #3 §7.** The title was the bundle name alone, so Mission
    /// Control, the Window menu and the proxy menu showed one indistinguishable
    /// entry whatever the captain was looking at - which is the one place a
    /// Mac app is expected to say where it is. Every other native Mac app puts
    /// the document or the context there, and this app has twenty-seven of
    /// them plus a page per saved host.
    ///
    /// The separator is a plain hyphen rather than an em dash, matching the
    /// rest of this app's copy.
    ///
    /// A `nil` or blank context answers the bare app name, which is what the
    /// window is titled for the instant between being created and the shell's
    /// first navigation - never "Grand Line - ".
    static func windowTitle(context: String?) -> String {
        let name = windowTitle()
        guard let context = context?.trimmingCharacters(in: .whitespaces), !context.isEmpty else {
            return name
        }
        return "\(name) - \(context)"
    }

    /// The screen's usable area - menu bar and Dock excluded. This is the
    /// *window* frame (title bar included), so the title bar stays on screen.
    /// Falls back to the old fixed size only when there is no screen at all
    /// to measure (a headless / self-test launch).
    static func defaultWindowFrame() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(x: 0, y: 0, width: 1220, height: 720)
        }
        return screen.visibleFrame
    }

    /// F2: a natural, low-frequency checkpoint that also catches tab changes
    /// (opened, closed, renamed) made since the last navigation - `saveSession
    /// State` is a no-op when nothing actually changed, so switching apps
    /// costs one JSON encode and no write.
    func applicationDidResignActive(_ notification: Notification) {
        saveSessionState()
    }

    // MARK: F22 - compact mode

    /// Everything compact mode is wired to, in one place.
    ///
    /// Every closure here forwards into a store `AppDelegate` already owns or
    /// into `AppShellController` - nothing new is constructed and nothing is
    /// cached twice (GL-23). `CompactModePopoverController` holds no store of
    /// its own precisely so this method is the whole of its access to the
    /// app's data, which makes "what can the menu bar see and write?" a
    /// question with one answer to read.
    private func wireCompactMode() {
        let popover = compactModePopover

        // Today. Derived by `CompactModeDigest` from the *shared* `ShiftStore`
        // - the same instance the Tasks page, the palette, ⌥Space and the
        // Tasks status item all write through.
        popover.todayProvider = { [weak self] in
            guard let self else { return .empty }
            return CompactModeDigest.today(tasks: self.shiftStore.activeTasks,
                                           followUps: self.shiftStore.followUps,
                                           focusSecondsToday: self.shiftStore.focusSecondsToday())
        }
        popover.onSetTaskCompleted = { [weak self] id, completed in
            // GL-09: the popover cannot be open while locked, but this is the
            // write, and a write is the thing that must not happen. The same
            // belt-and-braces `ShiftMenuBarController.createQuickTask` keeps.
            guard AppLockGate.shared.allows(.compactModePopover) else { return }
            self?.shiftStore.setTaskCompleted(id: id, completed: completed)
        }
        popover.onOpenTasks = { [weak self] in self?.revealInFullWindow(.shift) }

        // Notes - the third popover, reading the one `StickyBoardStore` the
        // Sticky Board destination owns.
        popover.notesProvider = { [weak self] in
            guard let self else { return [] }
            return CompactModeDigest.notes(self.appShell.workspace.stickyBoardStore.activeNotes)
        }
        popover.onRevealNote = { [weak self] id in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            self.appShell.workspace.navigator.openStickyNote(id: id)
        }
        popover.onOpenStickyBoard = { [weak self] in self?.revealInFullWindow(.stickyBoard) }

        // Vault - the same three forwards `poneglyphMenuBar` uses above, into
        // the one `CredentialVaultController` and its one store.
        popover.vaultCodesProvider = { [weak self] in self?.appShell.workspace.poneglyphQuickCodes ?? [] }
        popover.vaultUnlockedProvider = { [weak self] in self?.appShell.workspace.poneglyphIsUnlocked ?? false }
        popover.vaultPane.onCopy = { [weak self] id in self?.appShell.workspace.copyPoneglyphCodeFromMenuBar(id: id) }
        popover.vaultPane.onOpenVault = { [weak self] in self?.revealInFullWindow(.poneglyph) }

        // Crew - the crew page's own real runner and transcript, never a
        // second conversation. Identical to `strawHatMenuBar`'s own wiring.
        popover.crewPane.onAsk = { [weak self] text, completion in
            self?.appShell.workspace.askCrewFromMenuBar(text, completion: completion)
        }
        popover.crewPane.onOpenFullChat = { [weak self] in self?.revealInFullWindow(.strawHat) }

        // The footer capture line goes through the same filer ⌥Space does, so
        // a task captured from the menu bar and one captured from the overlay
        // are one code path with one set of refusals (F2).
        popover.captureFiler = appShell.workspace.makeCaptureFiler()

        // The popover's own escape hatch while the app is locked: the exact
        // password check and unlock transition the real lock screen uses,
        // never a second one - see `AppShellController.attemptUnlockFromCompactMode`.
        popover.onAttemptUnlock = { [weak self] password, completion in
            self?.appShell.workspace.lock.attemptUnlockFromCompactMode(password: password, completion: completion)
        }

        compactMode.overdueCountProvider = { [weak self] in
            guard let self else { return 0 }
            return CompactModeDigest.today(tasks: self.shiftStore.activeTasks,
                                           followUps: self.shiftStore.followUps,
                                           focusSecondsToday: 0).overdueCount
        }
        compactMode.onOpenFullWindow = { [weak self] in self?.leaveCompactMode() }
        compactMode.onOpenSettings = { [weak self] in
            // The gear opens the window on Settings but does **not** leave
            // the mode: the captain is going there to change the mode's own
            // switches, and turning it off on their behalf first would be the
            // app deciding the answer.
            self?.revealInFullWindow(.settings)
        }
        compactMode.onHideMainWindow = { [weak self] in
            // `orderOut`, not `close`: the window and its whole mounted shell
            // survive, so leaving the mode is instant and every destination
            // keeps its state. `applicationShouldTerminateAfterLastWindowClosed`
            // is what stops this from quitting the app.
            self?.window?.orderOut(nil)
        }
        compactMode.perFeatureStatusItemVisibility = { [weak self] visible in
            guard let self else { return }
            self.shiftMenuBar.setStatusItemVisible(visible)
            self.strawHatMenuBar.setStatusItemVisible(visible)
            self.poneglyphMenuBar.setStatusItemVisible(visible)
        }


        // A task completed, added or deleted anywhere in the app moves this
        // badge. GL-24's shape: the observer re-derives one count and
        // repaints - `refreshBadge()` rather than `refresh()`, so ticking a
        // checkbox does not re-apply the activation policy and re-decide
        // three status items' visibility.
        shiftStore.observe { [weak self] in self?.compactMode.refreshBadge() }

        _ = compactMode
    }

    /// Raise the window on one destination without changing the mode.
    private func revealInFullWindow(_ destination: RailDestination) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        appShell.workspace.navigator.show(destination)
    }

    /// The popover's "Open full window", and the one clean way out of the
    /// mode.
    ///
    /// Order matters: `exitCompactMode()` writes the setting and runs
    /// `refresh()`, which puts the activation policy back to `.regular` -
    /// and a `.accessory` app cannot activate or show a regular window, so
    /// raising it first would silently do nothing.
    private func leaveCompactMode() {
        compactMode.exitCompactMode()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// F22: `false` while compact mode is on, and only then.
    ///
    /// The whole mode rests on this one answer. Compact mode's way of having
    /// no window is to *close* the main one, and with the stock `true` that
    /// would quit the app the instant the mode was switched on. The decision
    /// lives in `CompactModePolicy.terminatesAfterLastWindowClosed` rather
    /// than inline here, so it is asserted in CI's blocking lane rather than
    /// only by whatever happens to exercise this delegate callback.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        CompactModePolicy.current().terminatesAfterLastWindowClosed
    }

    /// REL-05: ⌘Q while an update install or a scheduled run is in flight
    /// asks first, and on yes stops that work cleanly before quitting - see
    /// `QuitGuard`. With nothing running, it quits at once as it always did.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitGuard.shared.shouldTerminate(confirm: QuitGuard.confirmQuit) { quit in
            sender.reply(toApplicationShouldTerminate: quit)
        }
    }

    /// REL-07: a Dock click in compact mode with no window showing leaves the
    /// mode the way the popover's "Open full window" does. The decision is
    /// `CompactModePolicy.reopensFullWindow`, asserted in CI's blocking lane.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard CompactModePolicy.current().reopensFullWindow(hasVisibleWindows: flag) else { return true }
        leaveCompactMode()
        return false
    }

    /// Tear down every console's own materialized SSH keys and SRE Lead
    /// sessions on quit - the shared Firstmate console and (Fix 1) every
    /// host's own dedicated console.
    func applicationWillTerminate(_ notification: Notification) {
        // P9: the pair to `noteLaunch`. Two lifecycle lines per run is what
        // makes a crash legible after the fact - a launch with no matching
        // "quitting" before it is a run that did not exit cleanly, which is
        // exactly the case `crashReportsSinceLastLaunch()` then explains.
        DiagnosticsLog.shared.lifecycle("lifecycle", "quitting")
        console.shutdown()
        appShell.workspace.hosts.shutdownAllHostConsoles()
        // Findings 3.3/4.6: the Sticky Board's text/title writes are debounced
        // now, so quitting is one of the three points anything still queued
        // has to reach disk (the other two are leaving the destination and a
        // field giving up focus). Without this, ⌘Q within
        // `StickyBoardStore.persistDebounce` of the last keystroke would lose
        // it.
        saveSessionState()
        // R2-BUG-04: one deadline for every quit-time git flush. All seven
        // syncs share one serial queue, and each used to wait on its own
        // budget, so one slow git call ahead of them stacked 3+3+3+2+3+3s of
        // main-thread block. Now the whole set waits at most this long, and
        // a store with nothing pending does not join the queue at all.
        let gitFlushDeadline = DispatchTime.now() + ShiftGitSync.terminateFlushBudget
        appShell.workspace.shutdownStickyBoard(deadline: gitFlushDeadline)
        // F9: the same class again, one page over. The Scratchpad pad's write
        // is debounced at 500ms, so ⌘Q straight after typing would otherwise
        // lose the last line of a pad whose whole promise is that it is still
        // there next launch.
        appShell.workspace.shutdownScratchpads()
        // Audit 2 §6.8 / §2.8: the same class one destination over, and the
        // call site `CodePreviewController.shutdown()`'s own doc comment had
        // promised since it shipped while having none. Without it, ⌘Q inside
        // the page's 500ms edit debounce loses those keystrokes and the final
        // commit+push never runs.
        appShell.workspace.shutdownCodePreview(deadline: gitFlushDeadline)
        // B7: the Notebook's own 500ms edit debounce plus its git commit.
        // `NotebookController.shutdown()` documented itself as called on quit
        // and had no caller, so ⌘Q inside that window lost the last
        // keystrokes - the same class as the four flushes around it.
        appShell.workspace.shutdownNotebook(deadline: gitFlushDeadline)
        // `fm/implement-grand-line-secrets-vault-poneg-ad`: the credential
        // vault's git backup is debounced the same way, so ⌘Q within that
        // window would leave a just-added credential committed locally but not
        // pushed - i.e. absent from the next machine, which is the one property
        // this feature exists to guarantee.
        appShell.workspace.shutdownCredentialVault(deadline: gitFlushDeadline)
        // F4: the reading list's commit+push is debounced at 3s like the
        // Sticky Board's, so ⌘Q within that window would leave a link saved
        // locally but never pushed - i.e. absent from the next machine, which
        // is the whole reason the list is git-synced.
        appShell.workspace.shutdownReadingList(deadline: gitFlushDeadline)
        // Straw Hat Pirates phase 1: nothing to flush (no on-disk history yet
        // by explicit scope) - this stops an in-flight `claude -p` child from
        // outliving the app by up to its 300s bound.
        appShell.workspace.shutdownStrawHatCrew()
        // PF2: the clipboard history's seal-and-write is off the main thread
        // now, so ⌘Q inside its own write latency would lose the last copy -
        // the same class as the five flushes above it.
        appShell.shutdownClipboardHistory()
        // REL-23: the tasks repo's own 3s commit debounce (Tasks, Commands,
        // Incidents, the Log Analyzer) and the runbooks' one beside it, on
        // the same serial queue and so under the deadline every flush above
        // shares. Neither had a quit-time flush, so an edit inside the window
        // stayed uncommitted and unpushed until the next edit.
        ShiftGitSync.shared.flushForTerminationNow(deadline: gitFlushDeadline)
        DocsRunbookGitSync.shared.flushForTerminationNow(deadline: gitFlushDeadline)
        shiftHotkey.stop()
        tabShortcuts.stop()
        shiftNotifications.stop()
        BackgroundSignalsPoller.shared.stop()
        ScheduleRunner.shared.stop()
        dictationHotkey.stop()
        snippetExpander.stop()
        appLock.stop()

        // Review bug B2: the app aborts on quit whenever the local Whisper
        // engine is still loaded, and macOS logs a crash every time.
        //
        // The vendored ggml keeps its Metal devices in a C++ static
        // `std::vector<unique_ptr<ggml_metal_device>>`, whose destructor runs
        // inside `exit()` - after this method, after `terminate:`, past
        // anything AppKit can hook. `ggml_metal_device_free` asserts
        // `[rsets->data count] == 0` ("you haven't deallocated all Metal
        // resources before exiting") and `ggml_abort`s when a whisper context
        // still holds residency sets. Two captured reports:
        // `GrandLine-2026-09-24-210949.ips` and `-2026-09-25-122236.ips`,
        // both SIGABRT on the main thread with that exact stack.
        //
        // Nothing is lost - every flush above has already run - but the
        // "quit unexpectedly" dialog can appear, and a crash report per quit
        // buries a real one.
        //
        // `whisper_free` (the engine's `deinit`) is what runs
        // `ggml_metal_rsets_free`, so releasing the engine here empties the
        // set before the static destructor ever looks at it. This is also why
        // the crash only follows a *recent* dictation: E2's two-minute idle
        // unload already releases it, and a quit after that window never
        // aborted. Last in this method deliberately - it is the only entry
        // here that is about the process rather than the captain's data.
        dictationEngine.releaseWhisperEngine(reason: "terminate")
    }

    // MARK: App-level password lock (fm/grandline-app-lock)

    /// The lock overlay is opaque and topmost, so mouse clicks on rail/body
    /// content underneath it are already blocked by ordinary AppKit hit-
    /// testing - but most of this app's menu items have a concrete `target`
    /// (not `nil`, routed through the first-responder chain), so a keyboard
    /// shortcut like ⌘⌃N (New Host) would otherwise still reach its
    /// destination's action even while that destination is hidden behind the
    /// overlay. This
    /// is the one choke point that closes that gap: every submenu except
    /// Edit (Cut/Copy/Paste/Select All/Find are all `nil`-target, responder-
    /// chain-routed items - while locked, the only thing that can ever be
    /// first responder is the lock screen's own password field, so leaving
    /// these enabled is what lets a captain paste a password from a manager
    /// via ⌘V rather than breaking that) gets disabled while locked, minus
    /// the App menu's Hide/Quit (still allowed, same as any other macOS app).
    private func setContentMenusEnabled(_ enabled: Bool) {
        guard let mainMenu = NSApp.mainMenu else { return }
        let appName = AppPaths.displayName
        for topLevelItem in mainMenu.items {
            guard let submenu = topLevelItem.submenu, submenu.title != "Edit" else { continue }
            for item in submenu.items {
                // GL-17 added Hide Others/Show All next to Hide; they are the
                // same class of item (system-level app visibility, disclosing
                // and writing nothing of this app's data), so they stay enabled
                // while locked for the same reason Hide and Quit do.
                if item.title == "Hide \(appName)" || item.title == "Quit \(appName)"
                    || item.title == "Hide Others" || item.title == "Show All" { continue }
                item.isEnabled = enabled
            }
        }
    }

    // MARK: Host connect (Fix 1: dedicated per-host pages)

    /// The one place a saved host is actually connected to - reached from
    /// both the Hosts sidebar's own "Connect" and a pinned rail icon click,
    /// so there's exactly one behavior for "connect to this saved host"
    /// regardless of entry point. `AppShellController.connectHost` owns the
    /// "open the first time, just focus after that" logic
    /// (`ConsoleController.connectSSHIfNeeded`); this method's only job is
    /// resolving the host's full `ssh` argv, which needs `hostStore.hosts`
    /// for jump-chain resolution (`Host.sshArguments(allHosts:)`).
    private func connectToHost(_ host: Host) {
        appShell.workspace.hosts.connectHost(host, args: host.sshArguments(allHosts: hostStore.hosts))
    }

    // MARK: Multi-host command execution (F9, v1)

    /// Opens the "Send to…" picker, then - for the hosts the captain ticked -
    /// runs the app's one risk gate once per host and delivers the command to
    /// that host's own dedicated page.
    ///
    /// **v1 only, deliberately.** One real tab per host, no aggregation: the
    /// review's own F9 entry puts the combined result view behind Block View
    /// Stage 1 ("blocks give clean per-command output capture"), which is
    /// itself blocked on Stage 0 surviving real use. See
    /// `MultiHostSend.swift`'s header.
    private func presentMultiHostSend(command: DevOpsCommand, values: [String: String], generatedText: String) {
        let picker = MultiHostSendPickerController(
            command: command,
            generatedText: generatedText,
            hosts: hostStore.hosts,
            isConnected: { [weak self] host in self?.appShell.workspace.hosts.isHostConnected(host) ?? false }
        )
        picker.onSend = { [weak self] hosts in
            guard let self else { return }
            let executor = MultiHostSendExecutor(
                // The app's one gate (`CommandRiskConfirmation`, the same
                // definition the page's own Copy/Send buttons and the ⌘K
                // palette call), invoked once per host with that host named -
                // never one blanket confirmation covering the selection.
                confirm: { command, text, _, context, proceed in
                    CommandRiskConfirmation.confirm(
                        command: command, generatedText: text, actionVerb: "send to the terminal",
                        context: context, proceed: proceed)
                },
                deliver: { [weak self] host, text in
                    guard let self else { return }
                    self.appShell.workspace.hosts.sendCommandToHost(
                        host, args: host.sshArguments(allHosts: self.hostStore.hosts), text: text)
                }
            )
            // `nil` means the command is not sendable at all (an unfilled
            // `{{token}}`) - the button refuses before the picker even opens,
            // so this is the second check of the same rule, not the first.
            guard let outcome = executor.send(command: command, values: values, to: hosts) else {
                self.appShell.showToast("Fill in this command's parameters before sending it.")
                return
            }
            if !outcome.sent.isEmpty {
                self.commandLibraryStore.recordUsage(command.id)
                // Land on the first host that actually received it, so the
                // captain sees a real result rather than whichever page was
                // connected last.
                if let first = hosts.first(where: { outcome.sent.contains($0.id) }) {
                    self.appShell.workspace.hosts.revealHost(first, args: first.sshArguments(allHosts: self.hostStore.hosts))
                }
            }
            self.appShell.showToast(MultiHostSend.resultMessage(outcome))
        }
        appShell.presentAsSheet(picker)
    }

    // MARK: Host editor window (nav-redesign task, item 3)

    /// Open (or bring forward) the Add/Edit Host form as its own window -
    /// the same visual weight as Settings, not a sheet cramped into the
    /// narrow Hosts panel. `HostEditorController`'s fields and its inline
    /// "+ New Key…" flow (which still opens as a sheet on top of *this*
    /// window) are unchanged from PR #14.
    func presentHostEditor(for host: Host?) {
        let existingLabels = Set(hostStore.hosts.filter { $0.id != host?.id }.map { $0.label } + ["Firstmate"])
        let editor = HostEditorController(host: host, keyStore: keyStore, snippets: snippetStore.snippets, existingLabels: existingLabels)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if self.hostStore.host(id: saved.id) != nil {
                self.hostStore.update(saved)
            } else {
                self.hostStore.add(saved)
            }
            self.appShell.showToast("\u{201C}\(saved.label)\u{201D} saved")
        }
        // GL-06: the host editor window's Delete button was unconfirmed too,
        // and deleting a host also tears down that host's live console page
        // (see `HostStore.observe` in `applicationDidFinishLaunching`). Same
        // copy as the Hosts list's own row-level confirmation, via the one
        // shared prompt. Deferred a runloop turn because `deleteHost()` closes
        // the editor window right after this returns.
        editor.onDelete = { [weak self] id in
            DispatchQueue.main.async {
                guard let self, let host = self.hostStore.host(id: id) else { return }
                guard DestructiveConfirm.confirm(
                    message: "Delete \u{201C}\(host.label)\u{201D}?",
                    detail: "This removes the saved host and closes its console page. "
                          + "It does not affect any running session."
                ) else { return }
                self.hostStore.delete(id: id)
            }
        }

        // Reuse one window across repeated Add/Edit calls (matching the Keys/
        // Snippets windows below) rather than piling up a new one on every
        // "+" click - only `contentViewController` needs to change since a
        // fresh `HostEditorController` is built above for whichever host is
        // being edited this time.
        let win: NSWindow
        if let existing = hostEditorWindow {
            win = existing
        } else {
            win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.isReleasedWhenClosed = false
            // cockpit-native-host-form-fixes, Fix 1: without this, opening
            // Add/Edit Host while the main `AppShellController` window is
            // full screen makes macOS treat this second regular window as a
            // tile to dock into that same full-screen Space (its default
            // behavior for a second standard window), stretching the
            // centered form back out to full width - the exact regression
            // the centered-form fix (PR #20) was meant to close, just gated
            // behind full-screen mode. `.fullScreenAuxiliary` tells AppKit
            // this window is allowed to float over a full-screen Space
            // instead of tiling into it; `.moveToActiveSpace` matters
            // because this window is cached and reused (`hostEditorWindow`)
            // for the app's whole lifetime, so a later reopen always
            // surfaces on whichever Space (full-screen or not) is active at
            // that moment, not the Space it happened to be in last time.
            // `.floating` keeps it visually above the full-screen window's
            // own content - Space membership alone doesn't guarantee that.
            win.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            win.level = .floating
            // F2(a): A1's window fusion, applied to the one other real window
            // this app opens. Before this, the Host editor wore a stock
            // titlebar with the teal domain ribbon starting *underneath* it -
            // two stacked strips of chrome, which is precisely the shape A1
            // removed from the main window. `WindowChromeFusion.apply` makes
            // the titlebar transparent and titleless while keeping
            // close/minimise/zoom, so the ribbon runs edge to edge along the
            // very top and the lights sit over it.
            //
            // The lights stay where AppKit puts them: this window has no
            // floating bar to hand them to, so the natural top-leading cluster
            // is right, and the sheet reserves room below it rather than the
            // cluster moving (`reservesWindowChromeInset`).
            WindowChromeFusion.apply(to: win)
            win.followHelmTheme()
            hostEditorWindow = win
            // GL-09: a `.floating` window stays above the lock overlay - which
            // is a subview of the *main* window, not a screen-level shield - so
            // a Host Editor open at lock time remained fully usable, editing and
            // saving real host records. Registered once, when the window is
            // created; the gate orders it out on every lock.
            AppLockGate.shared.registerSecondaryWindow(owner: self) { [weak self] in self?.hostEditorWindow }
        }
        // Still set, though `titleVisibility` is `.hidden` under F2(a)'s
        // fusion: the Window menu, Mission Control and the proxy menu all read
        // it, and the sheet's own heading is what the captain actually sees.
        win.title = host == nil ? "New Host" : "Edit Host"
        win.contentViewController = editor
        // Set here rather than in the controller so the two halves of F2(a) -
        // fusing the window and reserving room for the lights it now shows
        // over the content - sit in one function and cannot drift apart.
        (editor.view as? HelmFormSheet)?.reservesWindowChromeInset = true
        // Fix 2 (third round): the form's content column caps at 520pt and
        // centers (`HostEditorController.maxContentWidth`), so 568pt
        // (520 + 24pt margin each side) is the narrowest width that shows the
        // whole column without horizontal clipping - AppKit enforces that as
        // a live floor via the content view controller's fitting size (verified
        // with a live probe: dragging the window narrower than 568 settles
        // back to 568 on the next layout pass, same as any AppKit dialog
        // window whose content can't shrink further). 580 leaves a hair of
        // margin above that floor; 640 is the default so the centering is
        // visibly obvious - not flush with the window edges - without the
        // captain having to widen it by hand. Height has no such floor (the
        // form scrolls vertically), so 620 stays the height floor unchanged.
        win.contentMinSize = NSSize(width: 580, height: 620)
        win.setContentSize(NSSize(width: 640, height: 780))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Shift power features (phase 5)

    @objc func showShiftQuickCapture() {
        shiftQuickCapture.present()
    }

    // MARK: Command palette (phase 4 "Knowledge and speed"; expanded by F5)

    /// The Go menu's "All Destinations…" (⌘⇧D) and ⌘K's verb of the same
    /// name - UX1.
    ///
    /// The bar's quick-access overflow menu used to carry a third row into
    /// here. It is gone: it was wired to a closure nothing ever assigned, so
    /// it did nothing at all, and the captain asked for it removed rather than
    /// repaired - see `docs/history/03-navigation-and-chrome.md`.
    @objc func showAllDestinations() {
        // The sidebar shell's sidebar is the whole map, so it reveals and
        // focuses that instead; the floating bar opens the panel.
        if appShell.revealDestinationMap() { return }
        allDestinations.toggle()
    }

    /// Help → "Keyboard Shortcuts…" (⌘⇧/) - UX3.
    ///
    /// Built fresh on every open, deliberately: the sheet is a snapshot of
    /// `NSApp.mainMenu` plus two configurable stores, and both can change
    /// while the app runs (the Settings recorder rewrites the terminal
    /// chords). A cached sheet would print yesterday's bindings.
    @objc func showKeyboardShortcuts() {
        let sections = KeyboardShortcutCatalog.all(mainMenu: NSApp.mainMenu, settings: .shared)
        appShell.presentAsSheet(KeyboardShortcutsSheetController(sections: sections))
    }

    /// Help → "Manual Checks" - UX3's second Help item.
    ///
    /// `native/MANUAL-CHECKS.md` is the repo's own list of what cannot be
    /// asserted by a suite and has to be looked at by a human (P3 of this same
    /// review is about it going stale). Opening it in the captain's editor is
    /// the honest implementation - the file lives in the checkout, this app
    /// does not vendor a copy of it, and a copy is exactly what would rot.
    @objc func showManualChecks() {
        // `#filePath` is this file's own compile-time path
        // (`…/native/Sources/GrandLine/main.swift`), which resolves the
        // checkout the running binary was built from - true for a `swift
        // build` binary and for the packaged `.app`, both of which this repo
        // builds from the captain's own working tree. The same trick
        // `SelfTestSources.appSourceDirectory()` uses, and it is checked
        // against the file actually being there rather than assumed.
        let manualChecks = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // …/Sources/GrandLine
            .deletingLastPathComponent()    // …/Sources
            .deletingLastPathComponent()    // …/native
            .appendingPathComponent("MANUAL-CHECKS.md")
        guard FileManager.default.fileExists(atPath: manualChecks.path) else {
            // GL-30: a transient "that is not here" is a toast, not an alert.
            appShell.showToast("MANUAL-CHECKS.md is not in this build\u{2019}s checkout.")
            return
        }
        NSWorkspace.shared.open(manualChecks)
    }

    @objc func showUnifiedSearch() {
        unifiedSearch.present()
    }

    /// F5 (`fm/grandline-feature-f5-command-palette-expansion`): registers
    /// every domain the palette searches.
    ///
    /// This is the one place the palette's rows get their actions, and every
    /// one of them is a call into the method that already backs that action's
    /// own UI - the review's own instruction ("action items dispatch through
    /// existing `AppShellController` methods"). Nothing here re-implements a
    /// connect, a send, an open or a navigation.
    ///
    /// Provider order is irrelevant to display (the palette groups and orders
    /// by `UnifiedSearchKind.groupOrder`); it is listed here in that same
    /// order purely so this reads like the palette looks.
    private func buildUnifiedSearchIndex() -> UnifiedSearchIndex {
        let index = UnifiedSearchIndex()

        // `fm/grandline-session-switcher`, item 4: live sessions first, and
        // they *switch* rather than reconnect. Registered before the Hosts
        // provider only for readability - the palette's own ordering comes
        // from `UnifiedSearchKind.groupOrder`, not from registration order.
        index.register(UnifiedSearchSessionProvider(
            registry: appShell.workspace.hosts.sessions,
            store: hostStore,
            onSwitch: { [weak self] hostID in self?.appShell.workspace.hosts.switchToSession(hostID: hostID) }
        ))

        // Hosts -> the one place a saved host is connected to, shared with
        // the Hosts list's own Connect and the rail's per-host icons. A host
        // that is already live is left to the group above rather than listed
        // twice with two different verbs.
        index.register(UnifiedSearchHostProvider(
            store: hostStore,
            onConnect: { [weak self] host in self?.connectToHost(host) },
            isLive: { [weak self] hostID in self?.appShell.workspace.hosts.sessions.isLive(hostID) ?? false }
        ))

        // Saved commands -> the Command Library's own Send-to-terminal path,
        // behind the Command Library's own risk gate. `CommandRiskConfirmation`
        // is the single shared definition of that alert (extracted from
        // `CommandLibraryPageView` by F5 for exactly this), so a destructive
        // command reached from the palette shows the identical confirmation it
        // shows on the page - the review's "destructive commands keep their
        // confirmation gates".
        //
        // A command that still needs a parameter is never sent; it opens on
        // the real form instead. See `UnifiedSearchCommandProvider`'s header.
        index.register(UnifiedSearchCommandProvider(
            store: commandLibraryStore,
            onSend: { [weak self] command, generated in
                guard let self else { return }
                CommandRiskConfirmation.confirm(command: command, generatedText: generated,
                                                actionVerb: "send to the terminal") {
                    self.commandLibraryStore.recordUsage(command.id)
                    self.appShell.workspace.navigator.sendCommandToConsole(generated)
                    self.appShell.showToast("Sent to terminal")
                }
            },
            onOpen: { [weak self] id in self?.appShell.workspace.navigator.openCommandLibraryCommand(id: id) }
        ))

        // Tasks / follow-ups / projects - what ⌘⇧P used to search, on the same
        // shared `shiftStore`, opening the same editor sheets a row click does.
        index.register(UnifiedSearchShiftProvider(
            store: shiftStore,
            onOpenTask: { [weak self] id in self?.appShell.workspace.navigator.openShiftTask(id: id) },
            onOpenFollowUp: { [weak self] id in self?.appShell.workspace.navigator.openShiftFollowUp(id: id) },
            onOpenProject: { [weak self] id in self?.appShell.workspace.navigator.openShiftProject(id: id) }
        ))

        // Runbooks + postmortems - the pre-F5 palette, unchanged behaviour.
        // `fm/grandline-docs-split-runbooks-postmortems` renamed the two
        // `AppShellController` methods below (they used to be
        // `openDocsRunbook`/`openDocsPostmortem`) once Runbooks/Postmortems
        // stopped being Docs tabs and became their own destinations.
        index.register(UnifiedSearchDocsProvider(
            store: docsRunbookStore,
            onOpenRunbook: { [weak self] id in self?.appShell.workspace.navigator.openRunbook(id: id) },
            onOpenPostmortem: { [weak self] id in self?.appShell.workspace.navigator.openPostmortem(id: id) }
        ))

        // F1's notebook. Reads the **live** store instance the page and the
        // canvas card share (GL-23), for the same reason the two below do.
        // F4's reading list. Reads the **live** store instance the page, the
        // canvas card and ⌥Space's filer share (GL-23).
        index.register(UnifiedSearchReadingListProvider(
            store: appShell.workspace.readingListStore,
            onOpen: { [weak self] id in self?.appShell.workspace.navigator.openReadingListLink(id: id) }
        ))

        index.register(UnifiedSearchNotebookProvider(
            store: appShell.workspace.notebookStore,
            onOpen: { [weak self] id in self?.appShell.workspace.navigator.openNotebookPage(id: id) }
        ))

        // The two newest stores (audit §6.5b / §6.6b). Both read the *live*
        // instance the page itself uses - `StickyBoardStore` caches and
        // writes, so a second one would serve stale rows and become a second
        // writer to one file (GL-23).
        index.register(UnifiedSearchStickyNoteProvider(
            store: appShell.workspace.stickyBoardStore,
            onOpen: { [weak self] id in self?.appShell.workspace.navigator.openStickyNote(id: id) }
        ))
        index.register(UnifiedSearchSnippetProvider(
            store: appShell.workspace.codePreviewStore,
            onOpen: { [weak self] name in self?.appShell.workspace.navigator.openCodeSnippet(named: name) }
        ))

        // App actions + destinations - every entry an existing menu action.
        index.register(UnifiedSearchActionProvider.standard(shell: appShell))

        return index
    }

}

// MARK: - Self-test dispatch (GL-27: debug builds only)
//
// R2-ARCH-02: the dispatch lives in `SelfTests/SelfTestDispatch.swift` now,
// compiled into debug builds only. It runs here, at the same point as before:
// before the legacy-name migration, `SingleInstanceGuard.acquire()` and
// `AppDelegate()` - every branch `exit()`s, so a headless suite never contends
// for the instance lock and never touches the real stores.
#if FM_SELFTESTS
SelfTestDispatch.run()
#endif

// The rename to "Grand Line" (docs/history/45-rename-to-grand-line.md).
//
// This sits after every `FM_RUN_*_TESTS` block - each of which `exit()`s, so a
// headless suite never runs it against the captain's real Keychain or real
// data folder - and *before* `SingleInstanceGuard.acquire()`, which is the
// first line in the process that touches
// `~/Library/Application Support/<folder>` at all.
//
// Both halves are idempotent, so this is a no-op on every launch after the
// first. See `LegacyNameMigration`'s header for why the folder is moved and
// the Keychain items are copied, and for the one thing it cannot do: the
// captain's Accessibility and Automation grants are keyed to the bundle
// identifier, which changed, and re-granting them is a manual System Settings
// step by design.
//
// B4: skipped entirely in a scratch-redirected process. Both halves operate on
// the captain's REAL locations by construction - the folder move renames
// `~/Library/Application Support/FirstmateCockpit`, and the Keychain copy
// writes real login-Keychain items - so neither has anything to do in a probe
// and both would be reaching past `FM_SCRATCH_ROOT` if they ran.
if !AppPaths.isScratchRedirected() {
    LegacyNameMigration.runAtLaunch()
}

// R2-UX-01: settle what a first launch decides (the app lock, and the
// sidebar's profile), before anything below writes a preference or creates
// the data folder - `SingleInstanceGuard.acquire()` is the first thing that
// does. After `LegacyNameMigration`, so a pre-rename install counts as the
// existing install it is.
AppSettings.shared.settleFirstLaunch(isExistingInstall: AppSettings.shared.isExistingInstall())

// GL-05: refuse to be a second instance. This sits *after* every
// `FM_RUN_*_TESTS` block above (each of which `exit()`s, so a headless
// self-test never contends for the lock and never blocks a real running
// instance) and *before* `AppDelegate()` is constructed - which is the line
// that builds `HostStore`/`SSHKeyStore`/`SnippetStore`/`DictationStore`/
// `ShiftStore` and therefore the first thing that touches the shared files
// two instances corrupt. See `SingleInstanceGuard`'s header for what each of
// the three layers (Info.plist, NSRunningApplication, flock) actually covers.
switch SingleInstanceGuard.acquire() {
case .acquired:
    break
case .alreadyRunning(let pid):
    let who = pid.map { " (pid \($0))" } ?? ""
    AppLog.lifecycle.error("""
        Grand Line is already running\(who, privacy: .public) - activating it and exiting. \
        Two instances share one set of JSON stores and one Shift git working tree; the second one \
        silently overwrites the first's saves. See GL-05.
        """)
    exit(0)
}

// P9: the on-disk diagnostics sink. This is the first thing after the instance
// guard so the launch line is the first line of every run, and it must be
// *after* the guard - a second instance that exits is not a launch and should
// not stamp `last-launch`, which is what
// `DiagnosticsLog.crashReportsSinceLastLaunch()` compares against.
//
// `DiagnosticsLog.shared` reads the *previous* stamp at init, so the read has
// already happened by the time this overwrites it.
DiagnosticsLog.shared.noteLaunch(
    version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unbundled")

let app = NSApplication.shared
// Regular activation policy so a `swift run`-launched executable gets a real
// Dock icon, menu bar, and key window instead of a background agent.
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
