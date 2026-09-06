// Manjesh Grand Line - native macOS app (Phase 2 entry point).
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    // Phase 1: saved SSH hosts + the panel that lists and connects them. The
    // panel hands a `ssh` argv to the console, which opens it as a new tab.
    let hostStore = HostStore()
    // Phase 2: the saved-keys Keychain. The console resolves a host's chosen
    // key through it at connect time; the Keys window (below) is where the
    // captain generates/imports/browses them.
    let keyStore = SSHKeyStore()
    // Phase 3: the saved-command library (B2/B5). The console resolves a
    // host's startup snippet through it at connect time, and the Snippets
    // window's "Run" sends a snippet straight to the active tab.
    let snippetStore = SnippetStore()
    // Phase 5 (cockpit-shift-power-features): one `ShiftStore` shared by the
    // main window's Shift page, the menu bar item, the search palette, and
    // quick capture - all read/write the same tasks/follow-ups, never
    // separate store instances that could drift out of sync with each other.
    let shiftStore = ShiftStore()
    lazy var console = ConsoleController(keyStore: keyStore, snippetStore: snippetStore)
    // Phase 5 of the full-app UI audit merged the Hosts destination and the
    // two floating SSH Keys / Snippets windows into one destination with
    // three segmented tabs, so this is now the only controller for all three
    // stores' browsing/editing surfaces.
    lazy var hostsPanel = HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore)
    lazy var settingsController = SettingsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore)
    lazy var shiftMenuBar = ShiftMenuBarController(store: shiftStore)
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
    let docsRunbookStore = DocsRunbookStore()
    lazy var unifiedSearch = UnifiedSearchController(index: buildUnifiedSearchIndex())
    lazy var shiftQuickCapture = ShiftQuickCaptureController(store: shiftStore)
    lazy var shiftNotifications = ShiftNotificationScheduler(store: shiftStore)
    lazy var shiftHotkey = ShiftGlobalHotkey { [weak self] in self?.shiftQuickCapture.present() }
    // fm/grandline-dictation-mvp (phase 1): one `DictationEngine` for the
    // app's whole lifetime, driven by `DictationHotkey`'s hold/release
    // callbacks - mirrors `shiftHotkey`/`shiftQuickCapture`'s own shape.
    let dictationEngine = DictationEngine()
    // Phase 2 (fm/grandline-dictation-phase2): transcription history +
    // personal vocabulary, shared by the Dictation page and the engine
    // (vocabulary bias, history recording) - same "one store, every reader/
    // writer shares it" convention as `shiftStore`.
    let dictationStore = DictationStore()
    // GL-23: one command library for the whole app. The Tasks page's DevOps
    // Commands tab and the Log Analyzer's "from your library" matching both
    // read and write it; two caching instances diverged in-session and
    // last-writer-wins on `recent.yaml`. Same one-store convention as
    // `shiftStore` and `dictationStore` above.
    let commandLibraryStore = CommandLibraryStore()
    // F11: the schedules the Automation page's Schedules card manages and
    // `ScheduleRunner` reads. Same one-store convention as `shiftStore`,
    // `dictationStore` and `commandLibraryStore` above - the runner and the
    // card must see the same list, and two instances would be two writers to
    // the same JSON file.
    let scheduleStore = ScheduleStore()
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
    // fm/grandline-app-lock: the app-level password lock's timing state
    // machine - see AppLock.swift's header for the idle/hard-logout math.
    let appLock = AppLockController()
    // F4: the `UNUserNotificationCenterDelegate` behind every notification
    // action button (Merge / Open PR / Open task / Snooze 1h / Show in app).
    // Owned here rather than by `AppShellController` for the same reason
    // `dictationHUD` is: it has to work when the app was launched *by* the tap,
    // before any window exists. See NotificationActions.swift's header.
    let notificationRouter = NotificationActionRouter()
    // Fix 1: `makeHostConsole` builds a fresh, host-scoped console (its own
    // ssh tab(s) only, no Firstmate host's own Shell tab) for
    // `AppShellController.connectHost` - captured as
    // local constants (not `self`) so this closure, which `appShell` holds
    // onto for its whole lifetime, can't form a retain cycle with `self`.
    lazy var appShell: AppShellController = {
        let keyStore = self.keyStore
        let snippetStore = self.snippetStore
        return AppShellController(
            hostsPanel: hostsPanel, console: console, settings: settingsController,
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: shiftStore,
            dictationStore: dictationStore, commandLibraryStore: commandLibraryStore,
            scheduleStore: scheduleStore,
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false) }
        )
    }()
    var hostEditorWindow: NSWindow?
    /// Fix 1: last-seen saved-host ids, so `hostStore.observe` below can
    /// detect a delete (a host id present last time but missing now) and
    /// tear down that host's dedicated page rather than leaving it stranded.
    private var knownHostIDs: Set<UUID> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Connect action from the panel: a saved host (has an id) reaches its
        // own dedicated page (Fix 1) - the same one its rail icon opens, via
        // `connectToHost` below; an ad-hoc quick-connect (no saved identity to
        // pin a page to) still opens as a plain tab in the shared Firstmate
        // console, same as before Fix 1.
        hostsPanel.onConnect = { [weak self] hostID, label, args, accentHex, keyID, startupSnippetID in
            guard let self else { return }
            if let hostID, let host = self.hostStore.host(id: hostID) {
                self.connectToHost(host)
            } else {
                self.console.openSSH(label: label, args: args, accentHex: accentHex, keyID: keyID, startupSnippetID: startupSnippetID)
                self.appShell.show(.console)
            }
        }
        // The pinned "Firstmate" entry (Fix 4) - the same Shell tab
        // the console has always opened at startup, now also reachable from
        // the Hosts list. Unaffected by Fix 1: it's the one destination that
        // deliberately stays on the shared `console`, never a dedicated page.
        hostsPanel.onConnectPinned = { [weak self] in
            guard let self else { return }
            self.console.openFirstmateHost()
            self.appShell.show(.console)
        }
        // Nav-redesign task, item 3: Add/Edit Host is a dedicated full-page
        // window, not a sheet on this ~240pt-wide panel.
        appShell.onPresentHostEditor = { [weak self] host in
            self?.presentHostEditor(for: host)
        }
        // F9 (v1) - multi-host command execution. Here rather than in
        // `AppShellController` because this is the one object holding the host
        // store, and `connectToHost`'s own argv resolution
        // (`Host.sshArguments(allHosts:)`) needs the full host list to resolve
        // a jump chain.
        appShell.onSendCommandToHosts = { [weak self] command, values, generated in
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
        if let backupPath = hostStore.loadFailureBackupPath {
            appShell.showToast("Couldn't read saved hosts - backed up the old file to \((backupPath as NSString).lastPathComponent)")
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
        var storeFailureNotices: [String] = []
        if let backupPath = keyStore.loadFailureBackupPath {
            storeFailureNotices.append("Couldn't read saved SSH keys - backed up to \((backupPath as NSString).lastPathComponent). "
                + "Keychain entries for those keys are still there.")
        }
        if let backupPath = snippetStore.loadFailureBackupPath {
            storeFailureNotices.append("Couldn't read saved snippets - backed up to \((backupPath as NSString).lastPathComponent)")
        }
        for backupPath in dictationStore.loadFailureBackupPaths {
            storeFailureNotices.append("Couldn't read a dictation file - backed up to \((backupPath as NSString).lastPathComponent)")
        }
        // F11: same treatment for schedules. Worth saying out loud rather than
        // silently starting with none, because an unreadable file means every
        // scheduled run stops happening with nothing else anywhere reporting
        // it - the schedules simply are not there to be due.
        if let backupPath = scheduleStore.loadFailureBackupPath {
            storeFailureNotices.append("Couldn't read saved schedules - backed up to \((backupPath as NSString).lastPathComponent). "
                + "Nothing is scheduled until they are set up again.")
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
        appShell.onReconnectHost = { [weak self] hostID in
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
                self.appShell.removeHostConsole(id: removedID)
                // Finding 4.3: a deleted host's page is the one Recents row
                // that is genuinely unreachable - it can neither switch to a
                // live session nor reconnect - so it stops being listed here
                // rather than waiting to be clicked and found dead. A host
                // page merely *closed* is untouched: that one reconnects.
                self.appShell.forgetRecentHost(id: removedID)
            }
            self.knownHostIDs = currentIDs
        }
        // The Snippets tab's "Run" (Phase 3, B2) sends straight to the
        // console's active tab.
        appShell.onRunSnippet = { [weak self] snippet in
            self?.console.runSnippetInActiveTab(snippet)
        }
        // Settings > Terminal's font-size stepper (Fix 3) talks straight to
        // the live console; Appearance goes through `ThemeManager` directly
        // since every theme-aware view already observes it.
        settingsController.onFontSizeStep = { [weak self] delta in
            self?.console.stepFontSize(by: delta)
        }

        // Settings > Terminal's "Bell & notifications" toggle (Fix 3): this
        // only ever gates whether a macOS banner is ALSO posted for a
        // needs-decision/blocked task - see `FleetNotifier.setEnabled`'s own
        // comment. `FleetNotifier.shared.start()` below always runs
        // regardless, since the in-app Notification Center
        // (`fm/grandline-notification-center`) must stay current whether or
        // not the captain wants OS banners too.
        FleetNotifier.shared.setEnabled(AppSettings.shared.notifyOnNeedsDecision)
        FleetNotifier.shared.onNavigateToOverview = { [weak self] in self?.appShell.show(.overview) }
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
        notificationRouter.onShow = { [weak self] destination in self?.appShell.show(destination) }
        notificationRouter.onOpenShiftTask = { [weak self] id in self?.appShell.openShiftTask(id: id) }
        notificationRouter.onOpenShiftFollowUp = { [weak self] id in self?.appShell.openShiftFollowUp(id: id) }
        notificationRouter.onSnoozeFollowUp = { [weak self] id, date in
            self?.shiftStore.snoozeFollowUp(id: id, to: date)
        }
        notificationRouter.register()

        // fm/grandline-notification-center: the slow background poll for the
        // four signals that otherwise only ever recompute on a page visit
        // (tool updates, GitHub Sync drift, Vault attention, Bootstrap
        // setup drift) - see `BackgroundSignalsPoller.swift`'s header for
        // the cadence tradeoff.
        BackgroundSignalsPoller.shared.onNavigateToUpdates = { [weak self] in self?.appShell.show(.updates) }
        BackgroundSignalsPoller.shared.onNavigateToGitHubSync = { [weak self] in self?.appShell.show(.githubSync) }
        BackgroundSignalsPoller.shared.onNavigateToVault = { [weak self] in self?.appShell.show(.vault) }
        BackgroundSignalsPoller.shared.onNavigateToBootstrap = { [weak self] in self?.appShell.show(.bootstrap) }
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
        ScheduleRunner.shared.onNavigateToSchedules = { [weak self] in self?.appShell.show(.schedules) }
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
        appShell.onSearchTapped = { [weak self] in self?.unifiedSearch.present() }
        shiftQuickCapture.onCaptured = { [weak self] in
            self?.appShell.showToast("Task captured")
        }
        // The global hotkey's system-wide (other-app-frontmost) case needs
        // Accessibility permission - see `ShiftGlobalHotkey`'s header for
        // exactly why. Requesting it here (once, at launch) surfaces the
        // real macOS prompt the first time this app ever runs rather than
        // silently failing later.
        shiftHotkey.requestPermissionIfNeeded()
        shiftHotkey.start()
        // fm/grandline-notification-center: feeds the same due-detection
        // `poll()` already computes for the OS banner into the in-app
        // Notification Center too, rather than only firing a one-shot
        // banner with no record afterward.
        shiftNotifications.onDueCountsChanged = { [weak self] taskCount, followUpCount in
            NotificationSources.setShiftDue(taskCount: taskCount, followUpCount: followUpCount) {
                self?.appShell.showShiftDestination()
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
            self?.appShell.setDictationEngineStatus(status)
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
        appShell.onDictationShortcutChanged = { [weak self] shortcut in
            self?.dictationHotkey.updateShortcut(shortcut)
        }
        // E2: turning the toggle off releases any engine that is still
        // resident, so the captain's "off" takes effect now rather than at the
        // next idle expiry.
        appShell.onDictationLocalWhisperChanged = { [weak self] enabled in
            guard !enabled else { return }
            self?.dictationEngine.releaseWhisperEngine(reason: "local Whisper turned off")
        }
        dictationHotkey.start()

        // `shiftMenuBar` is `lazy` - force it into existence now so its
        // `NSStatusItem` actually appears at launch rather than only the
        // first time something else happens to reference the property.
        _ = shiftMenuBar

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
        appLock.onLock = { [weak self] reason in self?.appShell.showLock(reason: reason) }
        appShell.onUnlocked = { [weak self] in self?.appLock.recordUnlock() }
        appShell.onLogoutRequested = { [weak self] in self?.appLock.lock(reason: .manualLogout) }
        appShell.onLockStateChanged = { [weak self] locked in self?.setContentMenusEnabled(!locked) }
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
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Manjesh Grand Line"
        // **`contentViewController` first, then the frame.** Assigning a
        // content view controller makes AppKit re-derive the window's frame
        // from that content's Auto Layout fitting size (AGENTS.md's
        // host-editor gotcha (3), in its milder form) - so setting the frame
        // *before* this line is silently undone. Measured with a real window:
        // set to 1512x950 and then given a content view controller, it came
        // back 960x652, i.e. exactly `contentMinSize` plus the title bar.
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

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // `loadView()` has now run at least once (triggered by the
        // `contentViewController` assignment above) - lock now so the very
        // first frame the captain sees is the lock screen, not the console.
        appLock.lock(reason: .launch)

    }

    /// The main window's saved-frame key. Once the captain resizes or zooms
    /// the window, AppKit restores that instead of the default below.
    static let windowAutosaveName = "GrandLineMainWindow"

    /// Never smaller than this. Deliberately below any real Mac's usable
    /// height so it can never fight `defaultWindowFrame` - it only stops the
    /// captain dragging the window down to a size where the destinations
    /// stop being readable.
    static let minContentSize = NSSize(width: 960, height: 620)

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Tear down every console's own materialized SSH keys and SRE Lead
    /// sessions on quit - the shared Firstmate console and (Fix 1) every
    /// host's own dedicated console.
    func applicationWillTerminate(_ notification: Notification) {
        console.shutdown()
        appShell.shutdownAllHostConsoles()
        // Findings 3.3/4.6: the Sticky Board's text/title writes are debounced
        // now, so quitting is one of the three points anything still queued
        // has to reach disk (the other two are leaving the destination and a
        // field giving up focus). Without this, ⌘Q within
        // `StickyBoardStore.persistDebounce` of the last keystroke would lose
        // it.
        appShell.shutdownStickyBoard()
        shiftHotkey.stop()
        shiftNotifications.stop()
        BackgroundSignalsPoller.shared.stop()
        ScheduleRunner.shared.stop()
        dictationHotkey.stop()
        appLock.stop()
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
        let appName = ProcessInfo.processInfo.processName
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
        appShell.connectHost(host, args: host.sshArguments(allHosts: hostStore.hosts))
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
            isConnected: { [weak self] host in self?.appShell.isHostConnected(host) ?? false }
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
                    self.appShell.sendCommandToHost(
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
                    self.appShell.revealHost(first, args: first.sshArguments(allHosts: self.hostStore.hosts))
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
            win.followHelmTheme()
            hostEditorWindow = win
            // GL-09: a `.floating` window stays above the lock overlay - which
            // is a subview of the *main* window, not a screen-level shield - so
            // a Host Editor open at lock time remained fully usable, editing and
            // saving real host records. Registered once, when the window is
            // created; the gate orders it out on every lock.
            AppLockGate.shared.registerSecondaryWindow { [weak self] in self?.hostEditorWindow }
        }
        win.title = host == nil ? "New Host" : "Edit Host"
        win.contentViewController = editor
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
            registry: appShell.sessions,
            store: hostStore,
            onSwitch: { [weak self] hostID in self?.appShell.switchToSession(hostID: hostID) }
        ))

        // Hosts -> the one place a saved host is connected to, shared with
        // the Hosts list's own Connect and the rail's per-host icons. A host
        // that is already live is left to the group above rather than listed
        // twice with two different verbs.
        index.register(UnifiedSearchHostProvider(
            store: hostStore,
            onConnect: { [weak self] host in self?.connectToHost(host) },
            isLive: { [weak self] hostID in self?.appShell.sessions.isLive(hostID) ?? false }
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
                    self.appShell.sendCommandToConsole(generated)
                    self.appShell.showToast("Sent to terminal")
                }
            },
            onOpen: { [weak self] id in self?.appShell.openCommandLibraryCommand(id: id) }
        ))

        // Tasks / follow-ups / projects - what ⌘⇧P used to search, on the same
        // shared `shiftStore`, opening the same editor sheets a row click does.
        index.register(UnifiedSearchShiftProvider(
            store: shiftStore,
            onOpenTask: { [weak self] id in self?.appShell.openShiftTask(id: id) },
            onOpenFollowUp: { [weak self] id in self?.appShell.openShiftFollowUp(id: id) },
            onOpenProject: { [weak self] id in self?.appShell.openShiftProject(id: id) }
        ))

        // Runbooks + postmortems - the pre-F5 palette, unchanged behaviour.
        // `fm/grandline-docs-split-runbooks-postmortems` renamed the two
        // `AppShellController` methods below (they used to be
        // `openDocsRunbook`/`openDocsPostmortem`) once Runbooks/Postmortems
        // stopped being Docs tabs and became their own destinations.
        index.register(UnifiedSearchDocsProvider(
            store: docsRunbookStore,
            onOpenRunbook: { [weak self] id in self?.appShell.openRunbook(id: id) },
            onOpenPostmortem: { [weak self] id in self?.appShell.openPostmortem(id: id) }
        ))

        // The two newest stores (audit §6.5b / §6.6b). Both read the *live*
        // instance the page itself uses - `StickyBoardStore` caches and
        // writes, so a second one would serve stale rows and become a second
        // writer to one file (GL-23).
        index.register(UnifiedSearchStickyNoteProvider(
            store: appShell.stickyBoardStore,
            onOpen: { [weak self] id in self?.appShell.openStickyNote(id: id) }
        ))
        index.register(UnifiedSearchSnippetProvider(
            store: appShell.codePreviewStore,
            onOpen: { [weak self] name in self?.appShell.openCodeSnippet(named: name) }
        ))

        // App actions + destinations - every entry an existing menu action.
        index.register(UnifiedSearchActionProvider.standard(shell: appShell))

        return index
    }

    // MARK: Menu

    /// The main menu. Two load-bearing groups:
    ///  - Edit > Paste (⌘V) targets the first responder via `NSText.paste(_:)`,
    ///    which resolves to the focused terminal's `paste(_:)` - the screenshot-
    ///    paste-into-Claude flow. A plain `swift run` executable has no Paste
    ///    action otherwise (the old WKWebView got one for free from the browser).
    ///  - Edit > Find targets the responder chain, resolving to
    ///    `ConsoleController` (the window's content view controller), so ⌘F
    ///    works from the keyboard.
    ///
    /// There is no Tab, View, Window, or Help top-level menu
    /// (`fm/grandline-console-tabs-restore-tabmenu-fix`) - see the long
    /// comment at the end of this method for what that costs and what still
    /// works. ⌘T / ⌘D / ⇧⌘R / ⌘W / ⌘R / ⌘1…⌘9 / zoom / theme no longer have
    /// any keyboard shortcut; every one of their underlying actions is still
    /// reachable from the tab strip, the console toolbar, or Settings.
    func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        // Nav-redesign task, item 5: Settings is a rail destination in the
        // main window now, not a separate window.
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppShellController.selectSettings), keyEquivalent: ",")
            .target = appShell
        appMenu.addItem(NSMenuItem.separator())
        // GL-17: Services, plus the standard Hide Others / Show All trio a Mac
        // user expects to find here. `NSApp.servicesMenu` is what makes the
        // system populate the submenu; without the assignment it stays empty.
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu - Cut/Copy/Paste/Select All + Find.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(ConsoleController.showFind), keyEquivalent: "f")
        // Phase 4 ("Knowledge and speed") reassigned ⌘K from "Find in
        // Terminal" (Fix 4's original mapping) to the real unified search
        // palette below - plain find-in-terminal stays reachable with no
        // shortcut here (same "menu item only, no keyEquivalent" convention
        // as "Quick Connect" below) since the console toolbar's own
        // magnifying-glass icon already triggers the identical action
        // independently of any menu shortcut, and ⌘F ("Find…" above) covers
        // the common case too.
        let findInTerminalItem = NSMenuItem(title: "Find in Terminal", action: #selector(AppShellController.activateConsoleFind), keyEquivalent: "")
        findInTerminalItem.target = appShell
        editMenu.addItem(findInTerminalItem)
        // ⌘K opens the app's one command palette, matching the topbar Search
        // pill's own ⌘K badge. F5 expanded what it searches from Runbooks +
        // Postmortems to hosts, saved commands, tasks/follow-ups/projects,
        // runbooks, postmortems and app actions/destinations - and absorbed
        // Shift's own ⌘⇧P palette. See `UnifiedSearch.swift`'s header (and
        // `UnifiedSearchProviders.swift`'s) for the design, including why
        // terminal history is still not included.
        let unifiedSearchItem = NSMenuItem(title: "Search…", action: #selector(AppDelegate.showUnifiedSearch), keyEquivalent: "k")
        unifiedSearchItem.target = self
        editMenu.addItem(unifiedSearchItem)

        // Hosts menu - the Phase 1 connection manager. New Host targets the
        // panel directly (so it works regardless of focus - the editor now
        // opens as its own window, so this doesn't need the Hosts
        // destination on screen); Show Hosts and Quick Connect route through
        // the shell so the Hosts destination is showing first. The panel's
        // own Connect opens an ssh tab in the console and switches to it
        // (Fix 2: Hosts and Console are decoupled destinations now).
        let hostsMenuItem = NSMenuItem()
        mainMenu.addItem(hostsMenuItem)
        let hostsMenu = NSMenu(title: "Hosts")
        hostsMenuItem.submenu = hostsMenu
        // H3: this used to be a plain ⌘N, which is also what the Tasks menu's
        // "New Task…" declares. AppKit resolves a key equivalent to the first
        // *enabled* match in menu order and neither item is ever disabled (this
        // app implements no `validateMenuItem` at all), so the Hosts menu -
        // added first - swallowed ⌘N and the Tasks item's displayed shortcut
        // could never fire. ⌘N stays with New Task, which is the far more
        // frequent action and the one AGENTS.md documents; New Host takes ⌘⌃N,
        // matching this menu's own "Show Hosts" (⌘⌃S).
        let newHostItem = NSMenuItem(title: "New Host…", action: #selector(AppShellController.newHostFromMenu), keyEquivalent: "n")
        newHostItem.keyEquivalentModifierMask = [.command, .control]
        newHostItem.target = appShell
        hostsMenu.addItem(newHostItem)
        // No keyboard shortcut (⌘K now belongs to Find in Terminal above) -
        // reachable via this menu item or by clicking the Hosts rail icon.
        let quickConnectItem = NSMenuItem(title: "Quick Connect", action: #selector(AppShellController.revealHostsQuickConnect), keyEquivalent: "")
        quickConnectItem.target = appShell
        hostsMenu.addItem(quickConnectItem)
        hostsMenu.addItem(NSMenuItem.separator())
        let showHostsItem = NSMenuItem(title: "Show Hosts", action: #selector(AppShellController.selectHosts), keyEquivalent: "s")
        showHostsItem.keyEquivalentModifierMask = [.command, .control]
        showHostsItem.target = appShell
        hostsMenu.addItem(showHostsItem)

        // Session switching (`fm/grandline-session-switcher`, item 3). These
        // live in the Hosts menu rather than a new top-level one: a session
        // *is* a host, and this app's menu bar already overruns the
        // notched-display budget (AGENTS.md's menu-bar section), so a 12th
        // top-level menu would push the gap wider for no gain.
        //
        // **⌘⌃1…9, not ⌘1…9, and that is forced rather than preferred.** The
        // mockup shows ⌘1/⌘2 on the pills, but ⌘1-⌘9 was already spoken for
        // *twice* in this app at the time this shipped: the Tab menu's
        // "Select Tab N" (nil-target, so it only resolved while a
        // Console/Tools tab held first responder) and the View menu's five
        // space shortcuts (explicit target, always enabled). Both of those
        // menus are gone now (`fm/grandline-console-tabs-restore-tabmenu-
        // fix`), which frees ⌘1-⌘9 again, but this stays on ⌘⌃1…9 regardless -
        // an already-shipped shortcut isn't this fix's to change.
        // A session's whole point is being reachable from anywhere, i.e.
        // precisely where the always-enabled space item wins, so ⌘1 could
        // never have reached a session. ⌘⌃ is the modifier this menu already
        // uses for its own two items (⌘⌃N, ⌘⌃S) and its number space is free.
        //
        // ⌘] / ⌘[ were verified unused anywhere in this menu bar.
        hostsMenu.addItem(NSMenuItem.separator())
        let nextSessionItem = NSMenuItem(title: "Next Session",
                                        action: #selector(AppShellController.nextSession),
                                        keyEquivalent: "]")
        nextSessionItem.target = appShell
        hostsMenu.addItem(nextSessionItem)
        let previousSessionItem = NSMenuItem(title: "Previous Session",
                                            action: #selector(AppShellController.previousSession),
                                            keyEquivalent: "[")
        previousSessionItem.target = appShell
        hostsMenu.addItem(previousSessionItem)
        for n in 1...9 {
            let item = NSMenuItem(title: "Session \(n)",
                                  action: #selector(AppShellController.selectSessionByShortcut(_:)),
                                  keyEquivalent: "\(n)")
            item.keyEquivalentModifierMask = [.command, .control]
            item.tag = n
            item.target = appShell
            hostsMenu.addItem(item)
        }

        // Shift menu (cockpit-shift-create-edit, phase 2) - task/follow-up
        // creation. Both items target the app shell directly (like the Hosts
        // menu's "New Host…" above), so they work regardless of which
        // destination is currently showing - the shell switches to `.shift`
        // itself before presenting the sheet.
        let shiftMenuItem = NSMenuItem()
        mainMenu.addItem(shiftMenuItem)
        let shiftMenu = NSMenu(title: "Tasks")
        shiftMenuItem.submenu = shiftMenu
        let newTaskItem = NSMenuItem(title: "New Task…", action: #selector(AppShellController.newShiftTaskFromMenu), keyEquivalent: "n")
        newTaskItem.target = appShell
        shiftMenu.addItem(newTaskItem)
        let newFollowUpItem = NSMenuItem(title: "New Follow-up…", action: #selector(AppShellController.newShiftFollowUpFromMenu), keyEquivalent: "f")
        newFollowUpItem.keyEquivalentModifierMask = [.command, .shift]
        newFollowUpItem.target = appShell
        shiftMenu.addItem(newFollowUpItem)
        // cockpit-fix-shift-new-project: no keyEquivalent - this menu follows
        // "Weekly Review"'s own no-shortcut precedent rather than force a
        // collision. (It could take ⌘⇧P now that F5 freed it, but a shortcut
        // the captain never had is not this task's to invent.)
        let newProjectItem = NSMenuItem(title: "New Project…", action: #selector(AppShellController.newShiftProjectFromMenu), keyEquivalent: "")
        newProjectItem.target = appShell
        shiftMenu.addItem(newProjectItem)
        shiftMenu.addItem(NSMenuItem.separator())
        // F5 (`fm/grandline-feature-f5-command-palette-expansion`) removed
        // this menu's own "Search Tasks… ⌘⇧P" item: ⌘K now searches tasks,
        // follow-ups and projects alongside hosts, commands, runbooks and app
        // actions, so a second search item pointing at a second palette was
        // exactly the duplication the review asked to collapse. Tasks are
        // still fully searchable - from the Edit menu's "Search… ⌘K" or the
        // topbar Search pill. ⌘⇧P is now unbound.
        let weeklyReviewItem = NSMenuItem(title: "Weekly Review", action: #selector(AppShellController.showShiftWeeklyReview), keyEquivalent: "")
        weeklyReviewItem.target = appShell
        shiftMenu.addItem(weeklyReviewItem)
        // In-app fallback for quick capture's global ⌥Space hotkey (see
        // `ShiftGlobalHotkey`'s header) - works with no Accessibility
        // permission at all as long as this app is frontmost, so it's a
        // meaningful discoverability aid even before that permission is
        // granted.
        let quickCaptureItem = NSMenuItem(title: "Quick Capture", action: #selector(AppDelegate.showShiftQuickCapture), keyEquivalent: " ")
        quickCaptureItem.keyEquivalentModifierMask = [.option]
        quickCaptureItem.target = self
        shiftMenu.addItem(quickCaptureItem)

        // Log Analyzer menu (`fm/grandline-log-analyzer-build`, spec §24).
        //
        // **Shortcut collisions were checked against this file, not assumed.**
        // ⌘⇧L / ⌘⇧C / ⌘⇧T / ⌘⇧I were all genuinely free. ⌘⇧R was NOT - the
        // Tab menu's "Rename Tab…" claimed it back when the Tab menu was a
        // top-level entry - so spec §24's "⌘⇧R Create RCA" is bound to
        // **⌘⇧A** instead (A for "after-action review"), which is free;
        // taking ⌘⇧R would have silently broken an already-shipped shortcut.
        // The Tab menu is gone from the menu bar now
        // (`fm/grandline-console-tabs-restore-tabmenu-fix`), which frees
        // ⇧⌘R again - Log Analyzer stays on ⌘⇧A regardless, since changing
        // an already-shipped shortcut isn't this fix's job. ⌘↵ (Analyze) is
        // not a menu item at all:
        // it is `analyzeButton`'s own `keyEquivalent`, so it only fires while
        // the page is on screen rather than analyzing from any destination.
        // Esc is handled by `LogAnalyzerController.cancelOperation`, the
        // responder-chain path, for the same reason.
        let logAnalyzerMenuItem = NSMenuItem()
        mainMenu.addItem(logAnalyzerMenuItem)
        let logAnalyzerMenu = NSMenu(title: "Log Analyzer")
        logAnalyzerMenuItem.submenu = logAnalyzerMenu

        let openAnalyzerItem = NSMenuItem(title: "Open Log Analyzer",
                                          action: #selector(AppShellController.showLogAnalyzer), keyEquivalent: "l")
        openAnalyzerItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(openAnalyzerItem)

        let analyzeClipboardItem = NSMenuItem(title: "Analyze Clipboard",
                                              action: #selector(AppShellController.analyzeClipboardInLogAnalyzer),
                                              keyEquivalent: "")
        logAnalyzerMenu.addItem(analyzeClipboardItem)
        logAnalyzerMenu.addItem(NSMenuItem.separator())

        let copyAnalysisItem = NSMenuItem(title: "Copy Analysis",
                                          action: #selector(AppShellController.logAnalyzerCopyAnalysis), keyEquivalent: "c")
        copyAnalysisItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(copyAnalysisItem)

        let sendToTerminalItem = NSMenuItem(title: "Send Top Command to Terminal",
                                            action: #selector(AppShellController.logAnalyzerSendToTerminal), keyEquivalent: "t")
        sendToTerminalItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(sendToTerminalItem)

        let investigateItem = NSMenuItem(title: "Investigate Further",
                                         action: #selector(AppShellController.logAnalyzerInvestigateFurther), keyEquivalent: "i")
        investigateItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(investigateItem)

        let createRCAItem = NSMenuItem(title: "Create RCA",
                                       action: #selector(AppShellController.logAnalyzerCreateRCA), keyEquivalent: "a")
        createRCAItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(createRCAItem)

        for item in logAnalyzerMenu.items { item.target = appShell }

        // Keys menu - the Phase 2 Keychain screen. Both items target the app
        // shell (so they work regardless of focus, like the Hosts menu's New
        // Host / Quick Connect above). Phase 5 of the full-app UI audit folded
        // this screen into the Hosts destination as a segmented tab, so
        // "Manage Keys…" now selects that tab instead of opening a window -
        // the shortcuts and titles are unchanged.
        let keysMenuItem = NSMenuItem()
        mainMenu.addItem(keysMenuItem)
        let keysMenu = NSMenu(title: "Keys")
        keysMenuItem.submenu = keysMenu
        keysMenu.addItem(withTitle: "New Key…", action: #selector(AppShellController.newKeyFromMenu), keyEquivalent: "n")
            .keyEquivalentModifierMask = [.command, .shift]
        keysMenu.addItem(withTitle: "Manage Keys…", action: #selector(AppShellController.selectKeys), keyEquivalent: "k")
            .keyEquivalentModifierMask = [.command, .shift]
        for item in keysMenu.items { item.target = appShell }

        // Snippets menu - the Phase 3 saved-command library (B2/B5). Same
        // shape as the Keys menu above, and folded into the same destination
        // by the same phase.
        let snippetsMenuItem = NSMenuItem()
        mainMenu.addItem(snippetsMenuItem)
        let snippetsMenu = NSMenu(title: "Snippets")
        snippetsMenuItem.submenu = snippetsMenu
        snippetsMenu.addItem(withTitle: "New Snippet…", action: #selector(AppShellController.newSnippetFromMenu), keyEquivalent: "n")
            .keyEquivalentModifierMask = [.command, .option]
        snippetsMenu.addItem(withTitle: "Manage Snippets…", action: #selector(AppShellController.selectSnippets), keyEquivalent: "p")
            .keyEquivalentModifierMask = [.command, .option]
        for item in snippetsMenu.items { item.target = appShell }

        // No Tab, View, Window, or Help top-level menu.
        //
        // View/Window/Help were standard-system-provided menus that never
        // fit this app: the View menu's `⌘1`-`⌘5` space shortcuts and
        // light/dark toggle duplicated `DaylightBarController`'s own
        // pills/button, its zoom items duplicated the Console toolbar's zoom
        // buttons and Settings' font-size presets; Window's minimize/zoom
        // are native title-bar chrome independent of any menu; Help pointed
        // at two repo docs with no other entry point. Their removal drops
        // the now-dead `openRepoDoc`/`openSetupGuide`/`openReadme` helpers
        // (their only callers) and `AppShellController`'s
        // `selectSpaceByShortcut(_:)`/`toggleTheme()` menu-item wrappers
        // (`selectSpace(_:)` itself is still very much alive - it's what
        // `DaylightBarController`'s own space pills call; only the
        // `NSMenuItem`-shaped `⌘1`-`⌘5` wrapper around it is gone. Same for
        // `ThemeManager.shared.toggle()`, still called directly by
        // `DaylightBarController`'s own theme-toggle button).
        //
        // The Tab menu (new / duplicate / rename / close / reconnect / jump
        // to tab N) is a separate, later removal
        // (`fm/grandline-console-tabs-restore-tabmenu-fix`) - the captain's
        // own original intent, distinct from the View/Window/Help cleanup
        // above: every capability it offered has a non-keyboard equivalent
        // already built into the tab strip (`TabChipView`) - the "+" button
        // for New, a chip's own double-click for Rename, and its right-click
        // menu for Rename/Duplicate/Close/**Reconnect** (the last one added
        // alongside this removal specifically so "reconnect a dead tab"
        // stays reachable with no menu backing it - see
        // `TabChipView.onReconnect`) - and jumping to a specific tab is
        // simply clicking its chip, which was always the primary way to do
        // it. What does NOT survive, because AppKit's standard key-equivalent
        // handling only walks items that are genuinely part of
        // `NSApp.mainMenu`'s tree (hiding a top-level item via `isHidden`
        // excludes its whole submenu from that walk exactly like removing it
        // outright does - there is no "present in the tree but invisible in
        // the bar" middle ground) is every one of the Tab menu's keyboard
        // shortcuts: ⌘T (new tab), ⌘D (duplicate), ⇧⌘R (rename), ⌘W (close),
        // ⌘R (reconnect), and ⌘1-⌘9 (jump to tab N). This is the same,
        // captain-accepted trade-off as ⌘M silently doing nothing once the
        // Window menu above went - the shortcuts are gone, the underlying
        // action is one click away either way. This is also shared with
        // `ToolsController`'s own, separate multi-instance tab strip, which
        // reused these exact selector names precisely so one Tab menu could
        // drive whichever controller had focus (see `ToolsController`'s own
        // `newShellTab`/`duplicateCurrentTab`/`renameCurrentTab`/
        // `closeCurrentTab`) - Tools' own "+" button and its tab chips'
        // double-click/right-click are completely unaffected, since neither
        // ever routed through this menu to begin with.

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - Self-test dispatch (GL-27: debug builds only)
//
// Every `FM_RUN_*_TESTS` block below is compiled out of the release binary,
// along with the suites themselves (see any file in `SelfTests/`). The flags
// stay greppable in this file either way, which is what
// `Scripts/run-all-tests.sh` discovers the suite list from - and that script
// builds and runs the debug binary, where they exist.
//
// This whole block sits before `SingleInstanceGuard.acquire()` and before
// `AppDelegate()` is constructed: every branch `exit()`s, so a headless suite
// never contends for the instance lock and never touches the real stores.
#if FM_SELFTESTS

// F6: redirect the captain's log to a scratch directory for the whole of a
// self-test process, unless the caller already pointed it somewhere.
//
// Not a precaution - a real defect this caught. `FleetLogStore.shared` is
// appended to by `ShiftGitSync.resolveConflicts` and `LogAnalyzerStore.save`,
// which `ShiftConflictSelfTest` and `LogAnalyzerSelfTest` both drive against
// their own scratch stores. Those suites correctly override every store they
// know about (`FM_SHIFT_DIR`, `FM_LOG_ANALYZER_DIR`, ...), but the fleet log
// is reached indirectly, through a singleton neither of them constructs - so
// a plain `./Scripts/run-all-tests.sh` wrote three fabricated events into the
// captain's real `events.jsonl`. Doing it here rather than in those two
// suites covers every present and future suite that reaches an append path,
// including a single suite run by hand, which is the case a per-suite fix
// would keep missing. Same reasoning as `CommandLibraryStore` honouring
// `FM_SHIFT_DIR` (see AGENTS.md's DevOps Commands section).
//
// Pr1 extends the same treatment to the schedule stores, for exactly the
// reason the paragraph above gives. Several suites construct a bare
// `ScheduleStore()` purely to satisfy an initializer's parameter list
// (`AppShellBodyWidthSelfTest`, `AppShellDrillHeaderTitleSelfTest`,
// `DaylightHardeningSelfTest`, `DaylightModuleSelfTest`,
// `DestinationMountingSelfTest`) and their `withScratchEnv` blocks omit
// `FM_SCHEDULES_FILE`, so each of those *reads* the captain's real
// `schedules.json` during a plain test run - and `ScheduleRunHistoryStore.shared`
// (PR #289) is a second indirectly-reachable singleton with no redirect at
// all. No suite drives a schedule write today, which is the only reason
// nothing has been corrupted yet; AGENTS.md's own post-incident rule says to
// close that here rather than wait for the suite that does.
if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("FM_RUN_") }) {
    let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("selftest-process-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)
    if (ProcessInfo.processInfo.environment["FM_FLEET_LOG_DIR"] ?? "").isEmpty {
        setenv("FM_FLEET_LOG_DIR", scratchRoot.appendingPathComponent("fleet-log", isDirectory: true).path, 1)
    }
    if (ProcessInfo.processInfo.environment["FM_SCHEDULES_FILE"] ?? "").isEmpty {
        setenv("FM_SCHEDULES_FILE", scratchRoot.appendingPathComponent("schedules.json").path, 1)
    }
    if (ProcessInfo.processInfo.environment["FM_SCHEDULE_HISTORY_DIR"] ?? "").isEmpty {
        setenv("FM_SCHEDULE_HISTORY_DIR", scratchRoot.appendingPathComponent("schedule-history", isDirectory: true).path, 1)
    }
    // `fm/grandline-sticky-board`: the same lesson, caught live during this
    // task's own verification rather than in a later follow-up. Any suite -
    // including this feature's own `StickyBoardViewSelfTest` - that
    // constructs a real `StickyBoardController()`/`StickyBoardStore()` via
    // their production `init()` (no explicit `FM_STICKY_BOARD_DIR`/
    // `FM_SHIFT_DIR` override of its own) would otherwise reach
    // `StickyBoardGitSync.shared`, which shares `ShiftGitSync.shared`'s real
    // production working tree - a real local clone of the captain's actual
    // `manjesh-config` on this machine. Running `FM_RUN_STICKY_BOARD_VIEW_TESTS`
    // once, unprotected, left a stray untracked `GrandLineDocs/sticky-board/`
    // folder sitting in that real clone (never committed or pushed, since the
    // 3s debounce never fires before a headless suite process exits - but a
    // real hazard regardless, and the exact class of bug this whole block
    // exists to close for every present and future suite at once).
    if (ProcessInfo.processInfo.environment["FM_STICKY_BOARD_DIR"] ?? "").isEmpty {
        setenv("FM_STICKY_BOARD_DIR", scratchRoot.appendingPathComponent("sticky-board", isDirectory: true).path, 1)
    }
    // `fm/grandline-monaco-code-preview`: `CodePreviewStore()` is another store
    // reachable from a bare, no-argument production constructor, so it gets an
    // entry here for the reason the Sticky Board note above spells out - not
    // because a suite is known to reach it today. Every harness that mounts an
    // `AppShellController` (which builds one) already sets `FM_SHIFT_DIR`,
    // which this store honours, and both of its own suites use the explicit
    // `CodePreviewStore(root:)` seam. This closes the case those two do not:
    // a future suite constructing `CodePreviewController(store: CodePreviewStore())`
    // with no override of its own.
    if (ProcessInfo.processInfo.environment["FM_CODE_PREVIEW_DIR"] ?? "").isEmpty {
        setenv("FM_CODE_PREVIEW_DIR", scratchRoot.appendingPathComponent("code-snippets", isDirectory: true).path, 1)
    }
    // The full-app audit's §7.2, and the entry that generalises every one
    // above: `FM_SHIFT_DIR` is the *root* override the whole
    // `GrandLineDocs/` family resolves through.
    //
    // `ShiftStore`, `IncidentStore`, `DocsRunbookStore`, `CommandLibraryStore`,
    // `LogAnalyzerStore`, `StickyBoardStore` and `CodePreviewStore` all have a
    // no-argument production `init()` that, with no override set, resolves to
    // `ShiftGitSync.shared`'s working tree - a real local clone of the
    // captain's actual private `manjesh-config` repo. Every suite that
    // constructs one today sets either its own narrow override or this one, so
    // nothing is reaching that clone right now; this closes the case where the
    // *next* one does not, which is precisely how the two incidents the
    // comments above recount both happened. A per-suite fix keeps missing it
    // because the store is usually reached indirectly - through a controller,
    // or a singleton nobody constructs on purpose.
    //
    // Setting it also switches `ShiftStore` to its non-git-backed mode
    // (`gitSync == nil`), so a suite that writes cannot queue a commit against
    // the real remote either. Deliberately last, so a suite that sets one of
    // the narrower overrides above still wins for its own store.
    if (ProcessInfo.processInfo.environment["FM_SHIFT_DIR"] ?? "").isEmpty {
        setenv("FM_SHIFT_DIR", scratchRoot.appendingPathComponent("tasks", isDirectory: true).path, 1)
    }
}

// `fm/cockpit-sre-lead-shared-terminal`: `swift build && FM_RUN_SRE_LEAD_BRIDGE_TESTS=1
// .build/debug/FirstmateCockpit` runs `SRELeadBridge`'s self-tests and exits,
// never opening a window - this project builds with Command Line Tools only
// (no Xcode), which has no `XCTest.framework` and, in practice, no working
// `swift test` story for a `swift-testing`-based test target either (see
// `SRELeadBridgeSelfTest.swift`'s header for what was actually tried and why
// it didn't work), so this is the plain, dependency-free stand-in - the same
// "env-var-gated verification, run and read the result" convention this
// codebase already uses for AppKit UI probes (see AGENTS.md's "Verifying
// native UI bugs without a real screenshot"), just kept permanently instead
// of reverted after one use.
if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_BRIDGE_TESTS"] == "1" {
    exit(SRELeadBridgeSelfTest.run() ? 0 : 1)
}

// `fm/grandline-sre-lead-per-tab`: same convention, for the real
// `ConsoleController` per-tab SRE Lead integration (independent phases, no
// chat cross-talk, tab-switch rebinding, the 5-tab cap, per-tab teardown on
// close) - see `SRELeadPerTabSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_PER_TAB_TESTS"] == "1" {
    exit(SRELeadPerTabSelfTest.run() ? 0 : 1)
}

// `fm/cockpit-sre-lead-reply-formatting`: same convention, for
// `SRELeadMarkdown.parse`'s block/callout parsing - see
// `SRELeadMarkdownSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_MARKDOWN_TESTS"] == "1" {
    exit(SRELeadMarkdownSelfTest.run() ? 0 : 1)
}

// fm/cockpit-local-state-portable: same convention, for the export/import/
// diff/apply path - see `BackupSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_BACKUP_TESTS"] == "1" {
    exit(BackupSelfTest.run() ? 0 : 1)
}

// fm/cockpit-tools-page-diff: same convention, for `DiffEngine`'s line/word
// LCS diffing - see `DiffEngineSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_DIFF_ENGINE_TESTS"] == "1" {
    exit(DiffEngineSelfTest.run() ? 0 : 1)
}

// cockpit-tools-page-specialist: same convention, for the cron next-run
// explainer, the resource-unit converter, and the certificate inspector -
// see each self-test file's own header.
if ProcessInfo.processInfo.environment["FM_RUN_CRON_EXPLAINER_TESTS"] == "1" {
    exit(CronExplainerSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_RESOURCE_UNITS_TESTS"] == "1" {
    exit(ResourceUnitsSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_TERMINAL_WRAP_REDRAW_TESTS"] == "1" {
    exit(TerminalWrapRedrawSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_CERT_INSPECTOR_TESTS"] == "1" {
    exit(CertInspectorSelfTest.run() ? 0 : 1)
}

// fm/cockpit-tools-yaml-order-perf-fix: same convention, for YamlBeautify's
// key-order fidelity - see YamlBeautifySelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_YAML_BEAUTIFY_TESTS"] == "1" {
    exit(YamlBeautifySelfTest.run() ? 0 : 1)
}

// cockpit-shift-foundation: same convention, for ShiftStore's completion/
// reopen file-move logic and YAML scalar fidelity - see
// ShiftStoreSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_STORE_TESTS"] == "1" {
    exit(ShiftStoreSelfTest.run() ? 0 : 1)
}

// fm/grandline-devops-command-library: same convention, for the DevOps
// Command Library's parameter detection/substitution/search/favorites - see
// CommandLibraryStoreSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_COMMAND_LIBRARY_TESTS"] == "1" {
    exit(CommandLibraryStoreSelfTest.run() ? 0 : 1)
}

// cockpit-shift-create-edit: same convention, for `ShiftDateParser`'s
// natural-language date/time detection - see `ShiftDateParserSelfTest.swift`'s
// header.
if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_DATE_PARSER_TESTS"] == "1" {
    exit(ShiftDateParserSelfTest.run() ? 0 : 1)
}

// cockpit-shift-git-sync: same convention, for `ShiftGitSync`'s clone/commit/
// push/pull/debounce/status logic against a real disposable local bare repo -
// see ShiftGitSyncSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_GIT_SYNC_TESTS"] == "1" {
    exit(ShiftGitSyncSelfTest.run() ? 0 : 1)
}

// cockpit-shift-power-features: same convention, for `ShiftStore.weeklySummary`'s
// completed/pushed-back/upcoming counting - see
// ShiftWeeklySummarySelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_WEEKLY_SUMMARY_TESTS"] == "1" {
    exit(ShiftWeeklySummarySelfTest.run() ? 0 : 1)
}

// cockpit-shift-conflict-handling: same convention, for the record-level
// 3-way merge and conflict-resolution flow layered on top of
// `ShiftGitSync.pullNow`'s `.diverged` case - see
// ShiftConflictSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_CONFLICT_TESTS"] == "1" {
    exit(ShiftConflictSelfTest.run() ? 0 : 1)
}

// grandline-shift-task-image-attachments: same convention, for the image
// downscale/PNG-encode logic every attach path (file picker, drag-drop,
// clipboard paste) funnels through - see
// ShiftImageAttachmentWellSelfTest.swift's header. The store-level round
// trip (hasAttachment persistence, file write/read/remove) is covered by
// ShiftStoreSelfTest.swift; the real-remote push is covered by
// ShiftGitSyncSelfTest.swift - both extended in place rather than
// duplicated here.
if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_ATTACHMENT_WELL_TESTS"] == "1" {
    exit(ShiftImageAttachmentWellSelfTest.run() ? 0 : 1)
}

// `fm/cockpit-block-view-stage0`: same convention, for the OSC 133 parser,
// the real-view-hierarchy render path, the reconnect-bookkeeping
// unification, and volume - see each file's own header for what class of
// prior production break it targets and why the other three couldn't have
// caught it.
if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_TESTS"] == "1" {
    exit(TerminalBlockTrackerSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_HIERARCHY_TESTS"] == "1" {
    exit(BlockViewHierarchySelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_RESTART_TESTS"] == "1" {
    exit(BlockViewRestartIntegrationSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_VOLUME_TESTS"] == "1" {
    exit(BlockViewVolumeSelfTest.run() ? 0 : 1)
}

// `fm/cockpit-fix-host-decode-regression`: same convention, for `Host`'s
// custom decode fallback (a new `CodingKeys` entry with a Swift-side default,
// like `blockViewOptIn`, must not break decoding of pre-existing `hosts.json`
// files) - see HostStoreSelfTest.swift's header.
// `fm/grandline-review-phase1-stabilize` (GL-01/GL-21): store durability -
// a decode failure must preserve the file, and a failed directory read must
// not look like an empty library. Runs entirely against scratch paths via the
// stores' own `FM_*` overrides.
if ProcessInfo.processInfo.environment["FM_RUN_STORE_DURABILITY_TESTS"] == "1" {
    exit(StoreDurabilitySelfTest.run() ? 0 : 1)
}

// `fm/grandline-review-phase2-harden` (GL-02/GL-15): the shared subprocess
// runner, including the stderr-flood child the review asked for by name plus
// an in-process reproduction of the pre-fix drain order still deadlocking on
// that same child - see SubprocessSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SUBPROCESS_TESTS"] == "1" {
    exit(SubprocessSelfTest.run() ? 0 : 1)
}

// `fm/grandline-review-phase2-harden` (GL-26): the one `claude -p` runner the
// five drifted copies collapsed into - see ClaudeOneShotSelfTest.swift.
if ProcessInfo.processInfo.environment["FM_RUN_CLAUDE_ONE_SHOT_TESTS"] == "1" {
    exit(ClaudeOneShotSelfTest.run() ? 0 : 1)
}

// `fm/grandline-review-phase2-harden` (GL-10/GL-11/GL-30): throwing
// persistence writes funnelled through PersistenceFailureReporter, and the
// ServiceHealth registry behind the Health card - see Phase2HardeningSelfTest.swift.
if ProcessInfo.processInfo.environment["FM_RUN_PHASE2_HARDENING_TESTS"] == "1" {
    exit(Phase2HardeningSelfTest.run() ? 0 : 1)
}

// `fm/grandline-review-phase1-stabilize` (GL-05/GL-08): the single-instance
// lock and the `ssh` argv option-terminator contract.
if ProcessInfo.processInfo.environment["FM_RUN_PHASE1_HARDENING_TESTS"] == "1" {
    exit(Phase1HardeningSelfTest.run() ? 0 : 1)
}

if ProcessInfo.processInfo.environment["FM_RUN_HOST_STORE_TESTS"] == "1" {
    exit(HostStoreSelfTest.run() ? 0 : 1)
}

// `fm/grandline-vault-tab`: same convention, for `VaultSource`'s pure logic
// (shell-token safety, the two command-string builders, `av doctor --json`
// parsing) - see VaultDataSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_VAULT_DATA_TESTS"] == "1" {
    exit(VaultDataSelfTest.run() ? 0 : 1)
}

// `fm/grandline-vault-recipe-export-diverged-fix`: real disposable local
// bare-repo coverage for `VaultRecipeGit.export`'s ahead/behind/diverged
// classification - see VaultRecipeGitSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_VAULT_RECIPE_GIT_TESTS"] == "1" {
    exit(VaultRecipeGitSelfTest.run() ? 0 : 1)
}

// `fm/grandline-live-gap-rootcause-scout`: real-view-hierarchy regression
// coverage for the captain-reported black/blank right-side window gap -
// asserts `AppShellController.bodyContainer`'s width tracks the window's
// real, current content width across a series of resizes, and self-heals
// if that tie is ever silently broken - see AppShellBodyWidthSelfTest.swift's
// header.
if ProcessInfo.processInfo.environment["FM_RUN_APP_SHELL_BODY_WIDTH_TESTS"] == "1" {
    exit(AppShellBodyWidthSelfTest.run() ? 0 : 1)
}

// A drill page header's title can render truncated to a few characters
// after switching away from a destination whose action cluster (or a narrow
// window) genuinely squeezed the row at some earlier point in the session -
// see AppShellDrillHeaderTitleSelfTest.swift's header for the root cause
// (an NSStackView's cross-axis width getting permanently stuck once squeezed).
if ProcessInfo.processInfo.environment["FM_RUN_DRILL_HEADER_TITLE_TESTS"] == "1" {
    exit(AppShellDrillHeaderTitleSelfTest.run() ? 0 : 1)
}

// Daylight Phase 2: the shell that replaced the icon rail and the top bar -
// module anatomy, span-2 grid math, the locked space table, the canvas's
// no-store rule, and the bar's window-safety. See
// DaylightModuleSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_MODULE_TESTS"] == "1" {
    exit(DaylightModuleSelfTest.run() ? 0 : 1)
}

// The lock screen's Daylight Harbour restyle - the last pre-Daylight surface
// (fm/grandline-home-login-redesign-plan). Window-backed: focus, rendering and
// the off-screen render probe all need a real window, so it sits in
// run-all-tests.sh's NEEDS_SESSION list. See LockScreenSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_LOCK_SCREEN_TESTS"] == "1" {
    exit(LockScreenSelfTest.run() ? 0 : 1)
}

// The full-app audit's §7.1: a source guard cross-checking every window-backed
// suite in `SelfTests/` against `Scripts/run-all-tests.sh`'s `NEEDS_SESSION`
// list, which CI's `--ci` / `--session-only` split depends on being accurate.
if ProcessInfo.processInfo.environment["FM_RUN_E2E_TESTING_POLICY_TESTS"] == "1" {
    exit(E2ETestingPolicySelfTest.run() ? 0 : 1)
}

// The full-app audit's §7: regression coverage for the Docs Playbook's
// WKWebView subresource-cache fix (`fm/grandline-docs-webview-cache-fix`),
// which shipped with none.
if ProcessInfo.processInfo.environment["FM_RUN_DOCS_PLAYBOOK_RELOAD_TESTS"] == "1" {
    exit(DocsPlaybookReloadSelfTest.run() ? 0 : 1)
}

// The full-app audit's §7: the general Console tab-lifecycle suite - create,
// duplicate, rename, close, reconnect and the numbered-name convention, none
// of which had permanent coverage despite being the app's most-patched area.
if ProcessInfo.processInfo.environment["FM_RUN_CONSOLE_TAB_LIFECYCLE_TESTS"] == "1" {
    exit(ConsoleTabLifecycleSelfTest.run() ? 0 : 1)
}

// The full-app audit's §7: first coverage for the Setup/Bootstrap data layer,
// via the `UpdatesDataTestSeam`/`DotfilesDataTestSeam` transport seams.
if ProcessInfo.processInfo.environment["FM_RUN_SETUP_DATA_LAYER_TESTS"] == "1" {
    exit(SetupDataLayerSelfTest.run() ? 0 : 1)
}

// Daylight Phase 6 (the last phase): the accessibility sweep and the Reduce
// Motion audit. Dusk's own colour derivation is measured by
// FM_RUN_CONTRAST_TESTS, where the palette maths already lives. See
// DaylightHardeningSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_HARDENING_TESTS"] == "1" {
    exit(DaylightHardeningSelfTest.run() ? 0 : 1)
}

// Daylight Phase 4: one suite per slice of the per-destination restyle.
// Slice 1 also covers the shared drill-page components (§6.4-6.14). See each
// DaylightDrillPage*SelfTest.swift's own header.
if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_DRILL_SLICE5_TESTS"] == "1" {
    exit(DaylightDrillPageSlice5SelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_DRILL_SLICE4_TESTS"] == "1" {
    exit(DaylightDrillPageSlice4SelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_DRILL_SLICE3_TESTS"] == "1" {
    exit(DaylightDrillPageSlice3SelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_DRILL_SLICE2_TESTS"] == "1" {
    exit(DaylightDrillPageSlice2SelfTest.run() ? 0 : 1)
}
// Daylight Phase 4 slice 6: the last two destinations in §7's table, Tools and
// Settings. See DaylightDrillPageSlice6SelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_DRILL_SLICE6_TESTS"] == "1" {
    exit(DaylightDrillPageSlice6SelfTest.run() ? 0 : 1)
}
// Daylight Phase 5: the chrome that is not a destination page - editor sheets,
// the ⌘K palette, the notification panel, toasts and empty states. See
// DaylightChromeSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_CHROME_TESTS"] == "1" {
    exit(DaylightChromeSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_DAYLIGHT_DRILL_TESTS"] == "1" {
    exit(DaylightDrillPageSelfTest.run() ? 0 : 1)
}

// GL-37: the destination table and lazy-mount-with-permanent-retention -
// only the eager slots exist at launch, a first visit builds exactly one,
// and a revisit reuses it. See DestinationMountingSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_DESTINATION_MOUNTING_TESTS"] == "1" {
    exit(DestinationMountingSelfTest.run() ? 0 : 1)
}

// F3: version comparison, GitHub release parsing, and the rule that an
// artifact this app cannot verify is refused rather than installed. See
// AppUpdateSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_APP_UPDATE_TESTS"] == "1" {
    exit(AppUpdateSelfTest.run() ? 0 : 1)
}

// fm/grandline-app-lock: same convention, for `AppLockController`'s idle/
// hard-logout timing math against a fake clock/idle-time provider - see
// AppLockSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_APP_LOCK_TESTS"] == "1" {
    exit(AppLockControllerSelfTest.run() ? 0 : 1)
}

// `fm/grandline-log-analyzer-build`: same convention, for the Log Analyzer's
// whole pure-logic layer - redaction (including byte-level greps of a built
// AI prompt and a saved investigation for planted secrets), source detection,
// severity/grouping, timeline, correlation, AI reply parsing, Command Library
// matching, artifact rendering, comparison, storage, and the terminal-capture
// scope rule - see LogAnalyzerSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_LOG_ANALYZER_TESTS"] == "1" {
    exit(LogAnalyzerSelfTest.run() ? 0 : 1)
}

// P2-P6 (`data/grand-line-e2e-audit/report.md`): the performance findings that
// are testable as behaviour - see AuditPerfFixesSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_AUDIT_PERF_FIXES_TESTS"] == "1" {
    exit(AuditPerfFixesSelfTest.run() ? 0 : 1)
}

// `data/grand-line-appkit-expert-audit/report.md`: the AppKit-expert audit's
// smaller findings, one case per finding id - see AppKitAuditSelfTest.swift.
if ProcessInfo.processInfo.environment["FM_RUN_APPKIT_AUDIT_TESTS"] == "1" {
    exit(AppKitAuditSelfTest.run() ? 0 : 1)
}

// Section 3 of `data/grandline-full-app-audit/report.md`: the standing
// per-session energy costs - see AuditEnergyFixesSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_AUDIT_ENERGY_FIXES_TESTS"] == "1" {
    exit(AuditEnergyFixesSelfTest.run() ? 0 : 1)
}

// B3-B9 (`data/grand-line-e2e-audit/report.md`): the Section 2 UI bugs, one
// case per finding id - see AuditUIFixesSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_AUDIT_UI_FIXES_TESTS"] == "1" {
    exit(AuditUIFixesSelfTest.run() ? 0 : 1)
}

// The UI-section findings from `data/grandline-full-app-audit/report.md`
// (`fm/grandline-audit-ui-fixes`), one case per finding - see
// FullAppAuditUISelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_FULL_APP_AUDIT_UI_TESTS"] == "1" {
    exit(FullAppAuditUISelfTest.run() ? 0 : 1)
}

// Section 5 of `data/grandline-full-app-audit/report.md`: the security
// findings, one case per finding id - see AuditSecurityFixesSelfTest.swift's
// header. Pure logic, so it runs in CI; §5.1's window-backed half is the
// separate suite below.
if ProcessInfo.processInfo.environment["FM_RUN_AUDIT_SECURITY_FIXES_TESTS"] == "1" {
    exit(AuditSecurityFixesSelfTest.run() ? 0 : 1)
}

// §5.1's behavioural half: builds the two real palettes and reads their
// registration back off the lock gate - see AuditSecurityLockSelfTest.swift.
if ProcessInfo.processInfo.environment["FM_RUN_AUDIT_SECURITY_LOCK_TESTS"] == "1" {
    exit(AuditSecurityLockSelfTest.run() ? 0 : 1)
}

// B1 (`data/grand-line-e2e-audit/report.md`): same convention, for the Vault
// page's failed/pending read states - see VaultLoadingStateSelfTest.swift.
if ProcessInfo.processInfo.environment["FM_RUN_VAULT_LOADING_STATE_TESTS"] == "1" {
    exit(VaultLoadingStateSelfTest.run() ? 0 : 1)
}

// E3 (`data/grand-line-e2e-audit/report.md`): same convention, for the
// backgrounded poll tier - see AppActivityStateSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_APP_ACTIVITY_STATE_TESTS"] == "1" {
    exit(AppActivityStateSelfTest.run() ? 0 : 1)
}

// E1 (`data/grand-line-e2e-audit/report.md`): same convention, for the
// terminal display gating that closed the app's dominant battery drain - see
// TerminalDisplayGatingSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_TERMINAL_DISPLAY_GATING_TESTS"] == "1" {
    exit(TerminalDisplayGatingSelfTest.run() ? 0 : 1)
}

// `fm/grand-line-shell-selection-investigate-fix`: same convention, for the
// Shell tab's own text selection measured from real rendered pixels - see
// TerminalSelectionRenderSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_TERMINAL_SELECTION_RENDER_TESTS"] == "1" {
    exit(TerminalSelectionRenderSelfTest.run() ? 0 : 1)
}

// `fm/grandline-dictation-mvp`: same convention, for `DictationHotkey`'s
// hold/release detection over synthetic `.flagsChanged` events - see
// DictationHotkeySelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_HOTKEY_TESTS"] == "1" {
    exit(DictationHotkeySelfTest.run() ? 0 : 1)
}

// `fm/grandline-dictation-phase2`: same convention, for `DictationStore`'s
// history/vocabulary persistence and `DictationShortcut`'s encode/decode +
// display-string logic - see DictationDataSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_DATA_TESTS"] == "1" {
    exit(DictationDataSelfTest.run() ? 0 : 1)
}

// `fm/grandline-dictation-phase3`: same convention, for `DictationCleanup`'s
// `claude -p` invocation/parsing/fallback logic - see
// DictationCleanupSelfTest.swift's header.
// Phase 3's own structural guards - the release-binary exclusion (GL-27), the
// text floor (GL-32), the growth caps (GL-35) and the undo slot (GL-33). See
// `SelfTests/Phase3PolishSelfTest.swift`.
if ProcessInfo.processInfo.environment["FM_RUN_PHASE3_POLISH_TESTS"] == "1" {
    exit(Phase3PolishSelfTest.run() ? 0 : 1)
}

// GL-16 (Phase 3): what the accessibility sweep guarantees - roles, labels,
// press actions, keyboard activation, focus rings and Reduce Motion, asserted
// in the shared components. See `AccessibilitySelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_ACCESSIBILITY_TESTS"] == "1" {
    exit(AccessibilitySelfTest.run() ? 0 : 1)
}

// GL-29 (Phase 3): `BackgroundSignalsPoller`'s pass latch (GL-03's own fix) and
// `ServiceHealthRegistry`'s verdicts. See `BackgroundSignalsSelfTest.swift`.
if ProcessInfo.processInfo.environment["FM_RUN_BACKGROUND_SIGNALS_TESTS"] == "1" {
    exit(BackgroundSignalsSelfTest.run() ? 0 : 1)
}

// GL-29 (Phase 3): the SSH credential path - `SSHKeyGenerator`,
// `SSHKeyMaterializer`, and the Keychain contract. See
// `CredentialPathSelfTest.swift`'s header for what it does and does not touch.
if ProcessInfo.processInfo.environment["FM_RUN_CREDENTIAL_PATH_TESTS"] == "1" {
    exit(CredentialPathSelfTest.run() ? 0 : 1)
}

// GL-29 (Phase 3): `FleetDataSource`/`OpenPRsSource` - the pair behind Overview
// and Review, including the merge action's argv. See
// `FleetDataSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_FLEET_DATA_TESTS"] == "1" {
    exit(FleetDataSelfTest.run() ? 0 : 1)
}

// F4: notification action routing - which action maps to which real function
// call, and whether the merge gate genuinely blocks a non-green PR. See
// `NotificationActionsSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_NOTIFICATION_ACTIONS_TESTS"] == "1" {
    exit(NotificationActionsSelfTest.run() ? 0 : 1)
}

// GL-29 (Phase 3): `DictationEngine`'s finish/race/timeout state machine -
// three real shipped bugs, previously verified only by reverted probes. See
// `DictationEngineSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_ENGINE_TESTS"] == "1" {
    exit(DictationEngineSelfTest.run() ? 0 : 1)
}

if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_CLEANUP_TESTS"] == "1" {
    exit(DictationCleanupSelfTest.run() ? 0 : 1)
}

// `fm/grandline-dictation-whisper-engine`: same convention, for the vendored
// whisper.cpp wrapper's model validation, audio resampling, and (when a real
// model path is provided) real load/transcribe - see
// WhisperEngineSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_WHISPER_ENGINE_TESTS"] == "1" {
    exit(WhisperEngineSelfTest.run() ? 0 : 1)
}

// Child-process-only entry point `testMetalFallbackDoesNotCrash()` spawns
// with `FM_WHISPER_METAL_RESOURCES_OVERRIDE` pointed at an empty directory -
// see that test's own doc comment for why this needs a genuinely separate
// process rather than an in-process assertion.
if ProcessInfo.processInfo.environment["FM_RUN_WHISPER_METAL_FALLBACK_ONLY_TEST"] == "1" {
    exit(WhisperEngineSelfTest.runRealModelOnly() ? 0 : 1)
}

// `fm/grandline-docs-knowledge-foundation`: same convention, for
// `DocsRunbookStore`'s CRUD/title-slug logic and `DocsKnowledgeSearch`'s
// scoped search, plus (against a real disposable local bare repo, never
// `manjesh-config`) `ShiftGitSync`'s repo-layout migration - see
// DocsRunbookDataSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_DOCS_RUNBOOK_TESTS"] == "1" {
    exit(DocsRunbookDataSelfTest.run() ? 0 : 1)
}

// `fm/grandline-sre-lead-postmortem`: same convention, for
// `SRELeadPostmortem.generate`'s `claude -p` invocation/parsing/fallback
// logic - see SRELeadPostmortemSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_POSTMORTEM_TESTS"] == "1" {
    exit(SRELeadPostmortemSelfTest.run() ? 0 : 1)
}

// `fm/grandline-console-command-composer`: same convention, for
// `ConsoleCommandComposer.generate`'s `claude -p` invocation/parsing/fallback
// logic - see ConsoleCommandComposerSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_CONSOLE_COMMAND_COMPOSER_TESTS"] == "1" {
    exit(ConsoleCommandComposerSelfTest.run() ? 0 : 1)
}

// `fm/grand-line-whiteboard-excalidraw`: the Whiteboard destination. Two
// suites, split by what they need - `WhiteboardSelfTest` is pure logic (asset
// resolution, the page's offline CSP, the AI prompt and parse, the destination
// tables) and runs in CI; `WhiteboardViewSelfTest` mounts a real `WKWebView`
// in a real window, loads the real vendored Excalidraw bundle and measures the
// hidden-view gating, so it is window-backed and lives in
// `run-all-tests.sh`'s NEEDS_SESSION list.
if ProcessInfo.processInfo.environment["FM_RUN_WHITEBOARD_TESTS"] == "1" {
    exit(WhiteboardSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_WHITEBOARD_VIEW_TESTS"] == "1" {
    exit(WhiteboardViewSelfTest.run() ? 0 : 1)
}

// `fm/grandline-quota-percent-fix`: same convention, for `QuotaSource.parse`
// against `quota-axi`'s real `percentRemaining`-keyed output - see
// QuotaDataSelfTest.swift's header.
// `fm/grandline-monaco-code-preview`: the Code Preview destination. Two
// suites, split the same way the Whiteboard's are and for the same reason -
// `CodePreviewSelfTest` is pure logic (asset resolution, the page's offline
// CSP, the language table, paste-time detection, the store's disk round trip,
// the syntax palette's measured contrast) and runs in CI; `CodePreviewViewSelfTest`
// mounts a real `WKWebView`, loads the real vendored Monaco bundle and reads
// Monaco's own tokenizer output back, so it is window-backed and lives in
// `run-all-tests.sh`'s NEEDS_SESSION list.
if ProcessInfo.processInfo.environment["FM_RUN_CODE_PREVIEW_TESTS"] == "1" {
    exit(CodePreviewSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_CODE_PREVIEW_VIEW_TESTS"] == "1" {
    exit(CodePreviewViewSelfTest.run() ? 0 : 1)
}

if ProcessInfo.processInfo.environment["FM_RUN_QUOTA_DATA_TESTS"] == "1" {
    exit(QuotaDataSelfTest.run() ? 0 : 1)
}

// `fm/grandline-notification-center`: pure store logic (add/clear/dismiss/
// dedup/badge count) - see GrandLineNotificationCenterSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_NOTIFICATION_CENTER_TESTS"] == "1" {
    exit(GrandLineNotificationCenterSelfTest.run() ? 0 : 1)
}

// The trickiest of the nine signals - SRE Lead replying on a tab you're not
// looking at - driven against a real `ConsoleController`, same convention as
// `SRELeadPerTabSelfTest.swift`. See NotificationCenterSRELeadSelfTest.swift's
// header.
if ProcessInfo.processInfo.environment["FM_RUN_NOTIFICATION_CENTER_SRE_LEAD_TESTS"] == "1" {
    exit(NotificationCenterSRELeadSelfTest.run() ? 0 : 1)
}

// `fm/grandline-design-audit-phase0`: WCAG contrast floors for the shared
// pill, icon tiles and `HelmTheme.mutedInk`, across every real palette - see
// HelmContrastSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_CONTRAST_TESTS"] == "1" {
    exit(HelmContrastSelfTest.run() ? 0 : 1)
}

// `fm/grandline-review-page-stuck-loading-fix`: the Review page's loading ->
// loaded state transition (drives `render(_:)` directly via
// `ReviewController`'s own "Probe / self-test surface", no real network
// fetch) - see ReviewControllerLoadingStateSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_REVIEW_LOADING_STATE_TESTS"] == "1" {
    exit(ReviewControllerLoadingStateSelfTest.run() ? 0 : 1)
}

// The volume measurement that proves the fix above - a demand-driven
// `NSTableView` renders hundreds of PR rows without the plain-`NSStackView`
// blowup #221 shipped. See ReviewPRListVolumeSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_REVIEW_PR_LIST_VOLUME_TESTS"] == "1" {
    exit(ReviewPRListVolumeSelfTest.run() ? 0 : 1)
}

// The row-width/button-visibility contract that regressed a second time when
// #227 ported this row into a reused NSTableView cell view without carrying
// forward the "reused row, toggling button visibility" fix
// `HostsListRecordView` already established. See
// ReviewPRRowButtonLayoutSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_REVIEW_PR_ROW_BUTTON_LAYOUT_TESTS"] == "1" {
    exit(ReviewPRRowButtonLayoutSelfTest.run() ? 0 : 1)
}

// F11: the scheduler's due / missed-while-asleep / catch-up decision, the
// store's anchoring rules, and the notify-on gate. See
// ScheduleRunnerSelfTest.swift's header for why the missed-run case is the one
// worth pinning: every symptom of getting it wrong is a run that did not
// happen, which looks exactly like a quiet night.
if ProcessInfo.processInfo.environment["FM_RUN_SCHEDULE_RUNNER_TESTS"] == "1" {
    exit(ScheduleRunnerSelfTest.run() ? 0 : 1)
}

// F11 follow-up: the one-time seed of the "daily-github-sync" schedule -
// seeds once using the pre-existing `.forkSync` action, never resurrects
// itself after the captain edits or deletes it, and introduces no new
// schedulable action. See `ScheduleSeeding.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_SCHEDULE_SEEDING_TESTS"] == "1" {
    exit(ScheduleSeedingSelfTest.run() ? 0 : 1)
}

// Run History status clarity + "View Log": the plain succeeded/failed/
// needs-attention chip, the run's own output persisting through
// `ScheduleRunHistoryEntry.log` (with truncation and old-format tolerance),
// and the Run History sheet's "View Log" button/`ScheduleRunLogController`
// pair. Window-backed - mounts real `ScheduleHistoryController`/
// `ScheduleRunLogController` instances. See
// ScheduleRunHistoryStatusAndLogSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SCHEDULE_RUN_HISTORY_STATUS_LOG_TESTS"] == "1" {
    exit(ScheduleRunHistoryStatusAndLogSelfTest.run() ? 0 : 1)
}

// F12 (`fm/grandline-feature-f12-morning-briefing`): the morning briefing's
// local composer (what data goes in, and the unknown-is-not-zero rule) plus
// its degradation path, driven through the real `ClaudeOneShot` against a
// disposable fake `claude`. See MorningBriefingSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_MORNING_BRIEFING_TESTS"] == "1" {
    exit(MorningBriefingSelfTest.run() ? 0 : 1)
}

// F9 (v1, multi-host command execution): the host-selection logic - tag
// matching, the never-preselected invariant, the risk gate firing once per
// host, and the unfilled-parameter refusal applied across a whole selection.
// See MultiHostSendSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_MULTI_HOST_SEND_TESTS"] == "1" {
    exit(MultiHostSendSelfTest.run() ? 0 : 1)
}

// F6 (fleet history / captain's log): the event store's append/retention/
// kind-filter contract, the day grouping, the one-line title sanitiser, and
// the merge with Shift's own activity YAML. See FleetLogSelfTest.swift's
// header for why the retention cap in particular is worth pinning - it is the
// one property no amount of using the app would ever surface.
// F7 (`fm/grandline-feature-f7-answer-crew-from-cockpit`): the reply-routing
// logic behind Overview's Reply affordance - the decision-key fold, the
// exactly-one `--resolve-key` rule, the argv, and `fm-send.sh`'s three-way
// exit-status contract. See `FleetActionsSelfTest.swift`'s header for what is
// faked (the script itself) and what is genuinely exercised.
if ProcessInfo.processInfo.environment["FM_RUN_FLEET_ACTIONS_TESTS"] == "1" {
    exit(FleetActionsSelfTest.run() ? 0 : 1)
}

// F7's rendering half - a real off-screen `FleetController`, real Reply
// clicks. Window-backed, so `Scripts/run-all-tests.sh` lists it in
// NEEDS_SESSION alongside its peers.
if ProcessInfo.processInfo.environment["FM_RUN_FLEET_REPLY_LAYOUT_TESTS"] == "1" {
    exit(FleetReplyLayoutSelfTest.run() ? 0 : 1)
}

// Phase 0 of the Daylight UI migration: the click-answering focus ring (D1),
// themed text selection (D4), the shared search well, and Health's pill/font/
// title fixes (D3/D5/D6) - see InputSurfaceSelfTest.swift's header. Window-
// backed (focus is meaningless without a window), so `run-all-tests.sh` lists
// it in NEEDS_SESSION.
if ProcessInfo.processInfo.environment["FM_RUN_INPUT_SURFACE_TESTS"] == "1" {
    exit(InputSurfaceSelfTest.run() ? 0 : 1)
}

if ProcessInfo.processInfo.environment["FM_RUN_FLEET_LOG_TESTS"] == "1" {
    exit(FleetLogSelfTest.run() ? 0 : 1)
}

// F8 (incident mode): the incident record's create/append/end round trip on
// real disk, the one-active-incident-per-host rule, the redaction boundary
// (grepped in the real bytes), the aggregate the postmortem generator is fed,
// and the F6 log wiring. See IncidentStoreSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_INCIDENT_TESTS"] == "1" {
    exit(IncidentStoreSelfTest.run() ? 0 : 1)
}

// Audit §6.2's relaunch-continuity half. Window-backed (it mounts a real
// `ConsoleController`), so it belongs in `run-all-tests.sh`'s NEEDS_SESSION
// list rather than beside the pure-logic store suite above.
if ProcessInfo.processInfo.environment["FM_RUN_INCIDENT_RESUME_TESTS"] == "1" {
    exit(IncidentResumeSelfTest.run() ? 0 : 1)
}

// GL-32's row-height half (audit §6.1). Pure measurement - no window - so it
// runs in CI alongside the other arithmetic suites.
if ProcessInfo.processInfo.environment["FM_RUN_TEXT_SCALE_ROW_HEIGHT_TESTS"] == "1" {
    exit(TextScaleRowHeightSelfTest.run() ? 0 : 1)
}

// Audit §6.10's P3 leftovers. Pure logic - runs in CI.
if ProcessInfo.processInfo.environment["FM_RUN_P3_LEFTOVERS_TESTS"] == "1" {
    exit(Phase4P3LeftoversSelfTest.run() ? 0 : 1)
}

// F5's command-palette providers: every domain's matching, the grouping the
// mockup shows, the "never send a half-substituted command" rule, and the
// source guards that keep the destructive-command gate a single definition the
// palette cannot bypass. See UnifiedSearchSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_UNIFIED_SEARCH_TESTS"] == "1" {
    exit(UnifiedSearchSelfTest.run() ? 0 : 1)
}

// The palette's own layout - the chip staying a chip under `.fill`, the panel
// being as tall as a grouped list, and the title truncating rather than
// running under the chip. Window-backed, so the runner skips it in a headless
// CI container; its provider/matching sibling above stays CI-enforced. See
// UnifiedSearchLayoutSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_UNIFIED_SEARCH_LAYOUT_TESTS"] == "1" {
    exit(UnifiedSearchLayoutSelfTest.run() ? 0 : 1)
}

// A real, captain-reported theming bug on Setup > Updates: the "Refresh"
// pill rendered washed-out on a fresh light-mode load and only rendered
// correctly after a dark -> light round trip. See
// UpdatesRefreshButtonThemeSelfTest.swift's header for the root cause.
if ProcessInfo.processInfo.environment["FM_RUN_UPDATES_REFRESH_BUTTON_THEME_TESTS"] == "1" {
    exit(UpdatesRefreshButtonThemeSelfTest.run() ? 0 : 1)
}

// A real, captain-reported bug on the top nav's space pills
// (`DaylightBarController`): clicking a pill and leaving the cursor in
// place left its label blended into a stale, pre-click background, in both
// light and dark mode - see TopNavPillPressedStateSelfTest.swift's header
// for the root cause (a missing `HoverHighlightView.hoverColor` repaint
// while already hovering).
if ProcessInfo.processInfo.environment["FM_RUN_TOPNAV_PILL_PRESSED_STATE_TESTS"] == "1" {
    exit(TopNavPillPressedStateSelfTest.run() ? 0 : 1)
}

// `fm/grandline-session-switcher`: the persistent live-session strip, the
// Hosts list's per-row live state, the ⌘K palette's pinned "Active sessions"
// group and the ⌘⌃1…9 / ⌘] / ⌘[ shortcut arithmetic. Window-backed (it mounts
// a real `AppShellController`), so it sits in `run-all-tests.sh`'s
// `NEEDS_SESSION` list.
// The pure-logic half of the full-app audit's "Bugs" section (§4), fixed in
// `fm/grandline-audit-bug-fixes`: IncidentStore's GL-21 read-failure class, the
// two JSONL stores' trim paths deleting lines they could not decode, the
// `SSHKey`/`Snippet` synthesized-`Decodable` landmine, and CodePreviewStore's
// swallowed delete. No views, so it runs in CI.
if ProcessInfo.processInfo.environment["FM_RUN_AUDIT_BUG_FIXES_TESTS"] == "1" {
    exit(AuditBugFixesSelfTest.run() ? 0 : 1)
}

if ProcessInfo.processInfo.environment["FM_RUN_SESSION_SWITCHER_TESTS"] == "1" {
    exit(SessionSwitcherSelfTest.run() ? 0 : 1)
}

// A real, captain-reported structural bug: Settings' whole page LAYOUT (card
// columns, and the Appearance grid's own swatch density) changed depending
// on which of the 14 themes was selected, not just its colours - see
// SettingsThemeLayoutParitySelfTest.swift's header for the root cause
// (`rebuildCardLayout()`'s two-column decision was gated on `theme.
// isDaylight` as well as on width).
if ProcessInfo.processInfo.environment["FM_RUN_SETTINGS_THEME_LAYOUT_PARITY_TESTS"] == "1" {
    exit(SettingsThemeLayoutParitySelfTest.run() ? 0 : 1)
}

// `fm/grand-line-console-claude-usage-button`: the "Claude usage" toolbar
// button restored beside Compose - its availability must mirror Compose's
// own byte-for-byte across tab-selection transitions, on both the shared
// Firstmate console and a dedicated host page. See
// ConsoleClaudeUsageSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_CONSOLE_CLAUDE_USAGE_TESTS"] == "1" {
    exit(ConsoleClaudeUsageSelfTest.run() ? 0 : 1)
}

// A scout investigation (`data/grand-line-energy-regression-scout/report.md`,
// section 2) traced "clicking through several pages in one session feels
// disproportionately expensive" to Updates/Bootstrap/Automation each
// independently re-running the same 13-item `DependencyCatalog` sweep on
// first mount. `DependencyCheckCache` is the shared, TTL'd cache they now all
// read from - see `DependencyCheckCacheSelfTest.swift`'s header for what this
// proves (caching, coalescing concurrent callers, and forceRefresh always
// bypassing both).
if ProcessInfo.processInfo.environment["FM_RUN_DEPENDENCY_CHECK_CACHE_TESTS"] == "1" {
    exit(DependencyCheckCacheSelfTest.run() ? 0 : 1)
}

// `fm/grandline-terminal-selection-sidebar-bleed`: the "Forward Drags to This
// Tab's Program" per-tab toggle's tab-lifecycle wiring (chip closures,
// duplicate propagation, a fresh tab never inheriting a sibling's state) -
// the mouse-routing formula itself is proven from real pixels by
// TerminalSelectionRenderSelfTest's case 7. See TabForwardDragsToggleSelfTest.swift's
// header.
if ProcessInfo.processInfo.environment["FM_RUN_TAB_FORWARD_DRAGS_TOGGLE_TESTS"] == "1" {
    exit(TabForwardDragsToggleSelfTest.run() ? 0 : 1)
}

// `fm/grandline-k8s-context-badge`: the context/namespace safety badge's
// parsing (`KubeContextParser`) and marker-injection mechanism
// (`KubeContextBridge`) - busy/single-flight/cross-bridge-collision guards,
// timeout, discard-on-typing, and the busy-vs-success retry cadence. See
// KubeContextBridgeSelfTest.swift's header for what this covers versus the
// Python allowlist widening's own tests in `test_sre_kubectl_mcp.py`.
if ProcessInfo.processInfo.environment["FM_RUN_KUBE_CONTEXT_BRIDGE_TESTS"] == "1" {
    exit(KubeContextBridgeSelfTest.run() ? 0 : 1)
}

// `fm/grandline-k8s-cluster-tail`: the shared `KubeBridge` plumbing both the
// Cluster browser and the Log Tail consume - its serialized queue, both
// terminal guards, the queue deadline, and the backoff/give-up the task brief
// names explicitly - plus `KubeResourceParser`'s column parsing and
// `KubeLogMerger`'s ordering/dedupe. Pure logic, so it runs in CI; the
// window-backed half is `FM_RUN_KUBERNETES_DESTINATION_TESTS`.
if ProcessInfo.processInfo.environment["FM_RUN_KUBE_BRIDGE_TESTS"] == "1" {
    exit(KubeBridgeSelfTest.run() ? 0 : 1)
}

// `fm/grandline-k8s-cluster-tail`: the real `.kubernetes` destination mounted
// in a real window - the scope strip's honest empty state, feed-tab adoption,
// a full Cluster sweep landing real parsed rows, the describe drawer, a real
// Log Tail poll producing merged coloured lines, the Shape-C deep link, and
// the give-up state's own UI. Window-backed, so it sits in
// `run-all-tests.sh`'s NEEDS_SESSION list.
if ProcessInfo.processInfo.environment["FM_RUN_KUBERNETES_DESTINATION_TESTS"] == "1" {
    exit(KubernetesDestinationSelfTest.run() ? 0 : 1)
}

// `fm/grandline-herdr-selection-color-sync`: `HerdrConfigPatcher`'s surgical
// TOML edit (in place, insert into an existing table, create a fresh table,
// every abort condition) plus `HerdrThemeSync`'s real-disk read/patch/write
// pipeline against a scratch file. See HerdrThemeSyncSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_HERDR_THEME_SYNC_TESTS"] == "1" {
    exit(HerdrThemeSyncSelfTest.run() ? 0 : 1)
}

// `fm/grandline-sticky-board`: the Sticky Board's own persistence/parsing
// layer - color contrast, the YAML round trip, the GL-01 refuse-to-overwrite
// guard, the `FM_SHIFT_DIR` fallback, and a real commit+push against a
// disposable local bare repo landing notes under the new
// `GrandLineDocs/sticky-board/` folder. See StickyBoardSelfTest.swift's
// header.
if ProcessInfo.processInfo.environment["FM_RUN_STICKY_BOARD_TESTS"] == "1" {
    exit(StickyBoardSelfTest.run() ? 0 : 1)
}

// `fm/grandline-sticky-board`: the window-backed half - the real destination
// in a real window, a theme sweep proving the board/chrome (never the
// notes) tracks the active theme, real synthesized drag mechanics, and a
// real Toast Undo button click. See StickyBoardViewSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_STICKY_BOARD_VIEW_TESTS"] == "1" {
    exit(StickyBoardViewSelfTest.run() ? 0 : 1)
}

// `fm/grandline-recents-navigation`: the "Recents" dropdown on the top bar -
// `RecentDestinations`'s own dedup/reorder/cap logic (pure Swift), a real
// `AppShellController`'s `show(_:)`/`switchToSession` navigation recording
// the destination being left (never the one being entered), the popover's
// real rows and click-to-navigate, and the bar button's own placement (after
// the space pills, before the search pill - the captain's explicit
// correction) and theming across a real light and dark theme. See
// RecentDestinationsSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_RECENT_DESTINATIONS_TESTS"] == "1" {
    exit(RecentDestinationsSelfTest.run() ? 0 : 1)
}

#endif

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
        Manjesh Grand Line is already running\(who, privacy: .public) - activating it and exiting. \
        Two instances share one set of JSON stores and one Shift git working tree; the second one \
        silently overwrites the first's saves. See GL-05.
        """)
    exit(0)
}

let app = NSApplication.shared
// Regular activation policy so a `swift run`-launched executable gets a real
// Dock icon, menu bar, and key window instead of a background agent.
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
