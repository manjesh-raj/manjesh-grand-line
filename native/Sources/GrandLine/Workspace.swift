// Grand Line - native macOS app.
//
// `Workspace` - everything a shell hosts rather than draws: the destination
// pages and the stores they share, the wiring between them, and the parts
// that navigate, mount, connect and lock them.
//
// Split out of `AppShellController` in stage 2 of the modular-shell migration
// (full review section 5.8, step 2). The floating-bar shell was the pages'
// owner and their chrome at once; the split-view shell that step 3 builds
// needs the same 29 pages, the same `DestinationMounter`, the same host pages
// and the same lock, so those moved here and the shells keep only their
// chrome. A shell owns one `Workspace`, installs its `content.bodyContainer`
// where pages belong, and implements `WorkspaceChrome` so a navigation can
// tell it what to draw.
//
// The parts, each split out of the same shell in the same stage:
//
//   - `WorkspaceContent` - the body area, the mounter and the transition,
//   - `Navigator` - where the captain is and every route,
//   - `HostSessionCoordinator` - the host pages and the live-session registry,
//   - `LockPresenter` - the lock overlay and its unlock flows,
//   - `CaptureFilingService` - where ⌥Space's captures land.
//
// Nothing about any page changed in the move. The lazy-page rules below
// ("Lazy destinations") are the shell's own, verbatim, with "the shell" now
// meaning this object.

import AppKit

/// What a shell's chrome draws when the workspace navigates. The floating-bar
/// shell (`AppShellController`) is the only implementation in stage 2.
protocol WorkspaceChrome: AnyObject {
    /// A destination is now showing: its slot is mounted and visible, and
    /// Recents has recorded it. The chrome names it and re-points anything
    /// that watches the page.
    func workspaceDidShow(_ destination: RailDestination, slot: DestinationSlot)
    /// A dedicated host page is now showing.
    func workspaceDidRevealHostPage(_ controller: ConsoleController, label: String)
    /// What is on screen changed - the one call every navigation makes.
    func workspaceCurrentDestinationDidChange(_ kind: RecentDestinationKind)
    /// The showing page's live subtitle may have changed (Daylight §6.4).
    func workspaceSubtitleMayHaveChanged()
    /// The showing page's own actions may have changed.
    func workspaceActionsMayHaveChanged()
    /// The live-session registry changed.
    func workspaceSessionsDidChange(_ registry: HostSessionRegistry)
    /// The Fleet page finished a read of the crew (`FleetController`'s
    /// `needsYouReading` has the result).
    func workspaceCrewDidRead()
    /// Which page is showing decides where the keyboard loop hands off.
    func workspaceKeyViewLoopMayHaveChanged()
    /// The window the workspace is showing in.
    var workspaceWindow: NSWindow? { get }
}

final class Workspace {

    /// The chrome of whichever shell is showing this workspace.
    weak var chrome: WorkspaceChrome?

    let content = WorkspaceContent()
    private(set) lazy var hosts = HostSessionCoordinator(workspace: self, makeHostConsole: makeHostConsole)
    private(set) lazy var navigator = Navigator(workspace: self)
    let lock = LockPresenter()

    /// Puts the window back inside its screen when a page's content pushed it
    /// past the edge (`fm/grandline-layout-breaks-refresh-reply`).
    let windowOverflowGuard = WindowOverflowGuard()

    /// The hub. Owns the space filter and the module grid; knows nothing about
    /// navigation beyond the closures wired below.
    let homeCanvas: HomeCanvasController

    let console: ConsoleController
    let overview: FleetController
    let review = ReviewController()

    // MARK: Lazy destinations (PERF-01)
    //
    // **The 2026-10 end-to-end review's PERF-01.** GL-37 made destinations
    // *mount* lazily, but every controller was still *constructed* in this
    // class's `init`, before the window existed - 26 pages the captain may
    // never open this session, with their stores, two YAML directory walks
    // and three `WKWebView`s among them. So each non-eager destination is a
    // `lazy var` now, built the first time something asks for it - which for
    // nearly every page is its first `show(_:)`, through the controller
    // closure its `DestinationSlot` holds.
    //
    // Three rules keep that true:
    //
    //   - **A page's wiring lives in its own initialiser below**, not in
    //     `loadView`. Assigning a callback to a lazy property builds it, so
    //     wiring every page from `loadView` would have built all of them at
    //     launch again.
    //   - **Anything that reaches a page from outside its own visit asks
    //     `isBuilt` first** when the answer for an unbuilt page is already
    //     known (a quit-time flush with nothing to flush, a bridge that cannot
    //     be busy on a page that does not exist). A menu action or a deep
    //     link that navigates there anyway simply builds it.
    //   - **A store another surface reads lives on the shell**, never only on
    //     the page (`stickyBoardStore`, `readingListStore`, ...), so the canvas,
    //     ⌘K and the widgets never have to build a page to read its data.
    //
    // `homeCanvas`, `overview`, `console` and `review` stay eager for the
    // reasons `DestinationRegistry.swift`'s header gives.

    /// Which lazy destinations have been built. Written only by `built(_:_:)`.
    private(set) var builtDestinations: Set<DestinationSlotID> = []

    /// Records that `id`'s controller exists and hands it back - the one
    /// line at the end of every lazy initialiser below.
    private func built<Controller: NSViewController>(_ id: DestinationSlotID,
                                                     _ controller: Controller) -> Controller {
        builtDestinations.insert(id)
        return controller
    }

    /// Whether `id`'s controller has been built yet. Asking never builds it.
    func isBuilt(_ id: DestinationSlotID) -> Bool { builtDestinations.contains(id) }

    // The stores the lazy initialisers below are built from. Held here
    // because a lazy initialiser runs long after `init` has returned.
    let hostStore: HostStore
    let keyStore: SSHKeyStore
    let snippetStore: SnippetStore
    let dictationStore: DictationStore
    let commandLibraryStore: CommandLibraryStore
    let scheduleStore: ScheduleStore
    let docsRunbookStore: DocsRunbookStore
    let logAnalyzerStore: LogAnalyzerStore

    /// The app delegate builds Hosts and Settings (it wires them to the host
    /// store, the console and the menu), so the shell holds how to reach
    /// them rather than the pages themselves.
    private let makeHostsPanel: () -> HostsController
    private let makeSettings: () -> SettingsController

    private(set) lazy var hostsPanel: HostsController = {
        let hostsPanel = makeHostsPanel()
        hostsPanel.onAddOrEdit = { [weak self] host in self?.onPresentHostEditor?(host) }
        hostsPanel.onRunSnippet = { [weak self] snippet in self?.onRunSnippet?(snippet) }
        hostsPanel.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        // Hosts is the first migrated page whose *actions* change while it is
        // on screen: §6.4's cluster carries the add action for the tab that is
        // showing, and the three tabs add three different records. Same shape
        // as the subtitle callback - the page says "re-ask me", the shell owns
        // the header.
        hostsPanel.onDrillActionsChanged = { [weak self] in self?.chromeActionsMayHaveChanged() }
        // `fm/grandline-session-switcher`: the Hosts list reads liveness from
        // the same registry the strip does, through a closure, so that page
        // never learns what a `ConsoleController` is - the same
        // forward-don't-own shape as every other `hostsPanel` hook here.
        hostsPanel.liveSession = { [weak self] hostID in self?.hosts.sessions.session(for: hostID) }
        hostsPanel.onSwitchToSession = { [weak self] hostID in self?.hosts.switchToSession(hostID: hostID) }
        hostsPanel.onEndSession = { [weak self] hostID in self?.hosts.confirmEndSession(hostID: hostID) }
        return built(.hosts, hostsPanel)
    }()

    private(set) lazy var settings: SettingsController = {
        let settings = makeSettings()
        settings.onTerminalShortcutsChanged = { [weak self] shortcuts in self?.onTerminalShortcutsChanged?(shortcuts) }
        settings.onQuickCaptureShortcutChanged = { [weak self] chord in self?.onQuickCaptureShortcutChanged?(chord) }
        // T5: Settings > Shortcuts rebinds dictation too, and the live hotkey
        // hears it through the same forward the Dictation page's recorder uses.
        settings.onDictationShortcutChanged = { [weak self] chord in self?.onKeyChordChanged?(chord) }
        // Settings' own sidebar moves the header's subtitle - it names the
        // selected category, the way the reference mockup's "Settings /
        // Shortcuts & Siri" does.
        settings.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        overview.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        // R4-UX-08: Stop joins the window toolbar while a pass is in flight.
        overview.onDrillActionsChanged = { [weak self] in self?.chromeActionsMayHaveChanged() }
        // cockpit-settings-sudo-touchid: Settings' "Touch ID for sudo" row
        // runs `sudo av harden sudo`, which needs a real interactive `sudo`
        // prompt exactly like Bootstrap's provisioning actions - same
        // one-shot Console command-tab mechanism, just reached from Settings
        // instead.
        settings.onRunCommand = { [weak self] label, command in self?.navigator.runInConsole(label: label, command: command) }
        settings.onRunCommandTracked = { [weak self] label, command, completion in
            self?.navigator.runInConsole(label: label, command: command, completion: completion)
        }
        return built(.settings, settings)
    }()

    /// `fm/polish-straw-hat-overview-card-and-voice-c8d3`: the Straw Hat
    /// Pirates chat, its own destination since the captain asked for it to be
    /// its own Overview card rather than a tab inside Fleet's page. Built on
    /// first use since PERF-01: its canvas summary starts empty either way
    /// (`StrawHatCanvasState()`), so an unbuilt page has nothing to report.
    private(set) lazy var strawHat: StrawHatController = {
        // The four store dependencies below were `FleetController`'s while the
        // crew chat was a tab on that page; they came here with it. All three
        // stores are the shared instances: each caches its records as well as
        // writing them, so a second instance would be a second writer to the
        // same file. The command library is handed over as a *root* URL
        // because the crew only ever reads it through their `command_search`
        // tool - constructing a second store for that would be the mistake
        // GL-24 fixed.
        let strawHat = StrawHatController(shiftStore: shiftStore,
                                          commandLibraryRoot: commandLibraryStore.root,
                                          commandLibraryStore: commandLibraryStore,
                                          stickyStore: stickyBoardStore,
                                          scheduleStore: scheduleStore)
        // Straw Hat phase 3 (M3.2): the crew's two navigation handoffs. Both
        // are pass-throughs into navigation this object already owns - a
        // handoff writes nothing, which is what lets its link row run on a
        // single click with no confirm card in front of it.
        strawHat.onOpenDestination = { [weak self] dest, hint in
            self?.navigator.openDestinationForCrew(dest, hint: hint)
        }
        strawHat.onOpenSRELead = { [weak self] hint in
            self?.hosts.openSRELeadForCrew(hostHint: hint)
                ?? "I couldn't reach your host pages from here."
        }
        strawHat.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        // The Overview card's own summary line - see
        // `StrawHatCanvasState`. Pushed rather than polled, the
        // same shape `FleetController.onSnapshotChanged` already uses for the
        // Fleet card.
        strawHat.onCanvasStateChanged = { [weak self] in
            guard let self else { return }
            self.homeCanvas.applyStrawHat(self.strawHat.canvasState)
        }
        return built(.strawHat, strawHat)
    }()

    private(set) lazy var shift: ShiftController = {
        let shift = ShiftController(store: shiftStore, focusTimer: focusTimer)
        shift.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        // The Tasks column's footer links, forwarded rather than owned - that
        // page knows nothing about the shell or the palette
        // (`onSearchTapped`'s own convention).
        shift.onNavigateToDestination = { [weak self] dest in self?.navigator.show(dest) }
        shift.onOpenCommandPalette = { [weak self] in self?.onSearchTapped?() }
        return built(.shift, shift)
    }()

    /// The Calendar: Shift's tasks and follow-ups by date, on the shell's one
    /// `ShiftStore` (GL-23), so a drop here and an edit on Tasks write the
    /// same records.
    private(set) lazy var calendar: TaskCalendarController = {
        let calendar = TaskCalendarController(store: shiftStore)
        calendar.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.calendar, calendar)
    }()

    /// `fm/grandline-log-analyzer-build`: the Log / Output Analyzer page.
    /// PERF-02: handed the shell's one `DocsRunbookStore` and
    /// `LogAnalyzerStore` rather than building its own.
    private(set) lazy var logAnalyzer: LogAnalyzerController = {
        // GL-23: the same `CommandLibraryStore` instance the Tasks page uses.
        let logAnalyzer = LogAnalyzerController(commandLibrary: commandLibraryStore,
                                                runbookStore: docsRunbookStore,
                                                store: logAnalyzerStore)
        // `fm/grandline-log-analyzer-build`: the Log Analyzer forwards the
        // same two things Shift's Command Library already does - "run this
        // command" goes to whichever console tab is in front, and a runbook
        // or postmortem it just wrote opens in Docs. It owns neither.
        logAnalyzer.onSendCommandToTerminal = { [weak self] text in
            self?.console.sendCommandLibraryTextToActiveTab(text)
        }
        logAnalyzer.onOpenRunbook = { [weak self] id in self?.navigator.openRunbook(id: id) }
        // `fm/grandline-docs-split-runbooks-postmortems`: `createIncident()`
        // used to route its saved-postmortem confirmation through
        // `onOpenRunbook` too, which opened it as a runbook - a postmortem id
        // is never in `listRunbooks()`, so that silently no-opped. Fixed by
        // giving it its own closure, wired to the postmortem destination.
        logAnalyzer.onOpenPostmortem = { [weak self] id in self?.navigator.openPostmortem(id: id) }
        // F8 (incident mode): a saved investigation attaches as openable
        // evidence to the incident on whichever host page handed over the
        // capture this investigation was built from - which is the only
        // honest correlation available, since the Log Analyzer itself has no
        // notion of a host. A clipboard analysis or an investigation reopened
        // from history clears that association first (see
        // `logAnalyzerCaptureSource`), so a save then attaches to nothing
        // rather than to whichever host happened to be last.
        logAnalyzer.onInvestigationSaved = { [weak self] id, title in
            self?.logAnalyzerCaptureSource?.noteInvestigationSaved(id: id, title: title)
        }
        logAnalyzer.onOpenConsole = { [weak self] in self?.navigator.show(.console) }
        logAnalyzer.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.logAnalyzer, logAnalyzer)
    }()

    /// `fm/grandline-k8s-cluster-tail`. It needs *this* controller's own
    /// `sessions` registry (there is exactly one - a second would be a second
    /// source of truth for "which hosts are live").
    private(set) lazy var kubernetes: KubernetesController = {
        let kubernetes = KubernetesController(sessions: hosts.sessions)
        // `fm/grandline-k8s-cluster-tail`: everything the `.kubernetes`
        // destination needs from the shell, as closures. Forward-don't-own -
        // that page knows nothing about `hostConsoles` or `ConsoleController`,
        // and this controller knows nothing about pods.
        kubernetes.configure(access: KubeSessionAccess(
            tabs: { [weak self] hostID in self?.hosts.hostConsoles[hostID]?.kubeFeedTabs() ?? [] },
            duplicateTabForFeed: { [weak self] hostID in self?.hosts.hostConsoles[hostID]?.duplicateTabForKubeFeed() },
            isTabBusyElsewhere: { [weak self] hostID, tabID in
                self?.hosts.hostConsoles[hostID]?.isTabBusyForKubeFeed(tabID) ?? false
            },
            revealHost: { [weak self] hostID in self?.hosts.switchToSession(hostID: hostID) },
            openHosts: { [weak self] in self?.navigator.show(.hosts) }))
        return built(.kubernetes, kubernetes)
    }()

    /// The reverse direction of the Kubernetes feed guard (full-app audit,
    /// finding 4.1), shared by the Firstmate console and every host page: a
    /// console-side bridge asks whether the `.kubernetes` page's feed bridge
    /// is using a tab. A page that has not been built has no feed bridge, so
    /// asking must not build it - the console bridges ask on every tick.
    func isKubernetesFeedBridgeBusy(onTab tabID: UUID) -> Bool {
        guard isBuilt(.kubernetes) else { return false }
        return kubernetes.isFeedBridgeBusy(onTab: tabID)
    }

    /// F8: the host page whose capture seeded whatever the Log Analyzer is
    /// currently showing, so a save can be attached to that host's incident.
    /// Weak - a deleted host's page is torn down and must not be kept alive
    /// by this.
    weak var logAnalyzerCaptureSource: ConsoleController?

    private(set) lazy var tools: ToolsController = {
        let tools = ToolsController()
        // Tools' subtitle counts open tool tabs, which the captain can change
        // without leaving the page.
        tools.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.tools, tools)
    }()

    /// `fm/grand-line-whiteboard-excalidraw`: the embedded Excalidraw canvas.
    /// Lazy like every other utility destination, and deliberately so - see
    /// `WhiteboardWebView`'s gating note: a session that never opens it never
    /// starts a web content process.
    private(set) lazy var whiteboard: WhiteboardController = {
        let whiteboard = WhiteboardController()
        whiteboard.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.whiteboard, whiteboard)
    }()

    /// `fm/grandline-sticky-board`: a freeform corkboard of draggable, colored
    /// sticky notes. Lazy like every other utility destination - see
    /// `StickyBoardController.swift`'s header. Its store is the shell's.
    private(set) lazy var stickyBoard: StickyBoardController = {
        let stickyBoard = StickyBoardController(store: stickyBoardStore)
        // UX10: the board raises a note to promote; this controller is the
        // one place that holds both destinations.
        stickyBoard.onMakeTaskFromNote = { [weak self] note in self?.navigator.makeTaskFromStickyNote(note) }
        return built(.stickyBoard, stickyBoard)
    }()

    /// `fm/grandline-monaco-code-preview`: the embedded Monaco editor. Lazy
    /// for the same reason the Whiteboard is - see `CodePreviewWebView`'s
    /// gating note: a session that never opens it never starts a web content
    /// process, never loads the 4MB bundle and never builds an editor.
    private(set) lazy var codePreview: CodePreviewController = {
        let codePreview = CodePreviewController(store: codePreviewStore)
        codePreview.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.codePreview, codePreview)
    }()

    /// `fm/grandline-tasks-kanban-devops-split`: the Command Library's own
    /// destination. Was the third tab of `shift` - see
    /// `CommandLibraryController`'s header for why it moved.
    private(set) lazy var commandLibrary: CommandLibraryController = {
        // GL-23 again: the same shared instance the Log Analyzer, the crew's
        // `command_search` tool and the ⌘K palette already read.
        let commandLibrary = CommandLibraryController(store: commandLibraryStore)
        // fm/grandline-devops-command-library-phase2: the Command Library's
        // "Send to Terminal" types straight into whichever console tab is
        // currently in front - not a new one-shot command tab (`runInConsole`
        // below), the exact same "type this into the active tab" behavior
        // Snippets' own "Run" already uses.
        commandLibrary.onSendCommandToTerminal = { [weak self] text in self?.console.sendCommandLibraryTextToActiveTab(text) }
        // F9 (v1): straight up to the app delegate - see `onSendCommandToHosts`.
        commandLibrary.onSendCommandToHosts = { [weak self] command, values, generated in
            self?.onSendCommandToHosts?(command, values, generated)
        }
        commandLibrary.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.commandLibrary, commandLibrary)
    }()

    /// The same `CodePreviewStore` instance the page uses, exposed so ⌘K's
    /// provider searches what the page shows rather than a second reader
    /// (audit §6.6b).
    let codePreviewStore: CodePreviewStore

    /// The same `ReadingListStore` instance the page and the canvas card use,
    /// exposed for ⌘K's own provider - same reason as `notebookStore` below:
    /// the palette must search what the page shows, not a second reader of the
    /// same folder (GL-23).
    let readingListStore: ReadingListStore

    /// The same `NotebookStore` instance the page and the canvas card use,
    /// exposed for ⌘K's own provider - same reason as `codePreviewStore`
    /// above: the palette must search what the page shows, not a second
    /// reader of the same folder.
    let notebookStore: NotebookStore

    /// The Sticky Board's one store (GL-23: it caches its notes *and* writes
    /// them, so a second instance would be a second writer to one file).
    /// Built here rather than inside the page since PERF-01, so the canvas,
    /// ⌘K, the crew and the widgets can read it while the page is unbuilt.
    let stickyBoardStore: StickyBoardStore

    /// The one `ShiftStore` (GL-23), held rather than only passed through, so
    /// F2's capture filer can write a task without a second instance. Every
    /// other reader on this controller already shares it via `ShiftController`.
    let shiftStore: ShiftStore
    /// F7's one timer. See the note at its construction in `init`.
    let focusTimer: FocusTimerController
    /// `fm/swap-vault-poneglyph-naming-in-grand-lin-1f`: the `.vault`
    /// destination is Automic Vault's hardening panel again (`vault`,
    /// `VaultController`), and the captain's own personal credential vault is
    /// `poneglyph` below, labeled "Poneglyph", now its own destination rather
    /// than a Setup tab (`fm/poneglyph-own-destination-and-strawhat-toolbar-
    /// shortcut`) - see `VaultController.swift`'s and
    /// `CredentialVaultController.swift`'s headers for the full history.
    private(set) lazy var vault: VaultController = {
        let vault = VaultController()
        // fm/grandline-vault-tab: `av save`/`av inject` both need a real
        // interactive terminal (see `VaultController`'s header) - same
        // one-shot Console command-tab mechanism as every other
        // interactive/sudo action in this app.
        vault.onRunCommand = { [weak self] label, command in self?.navigator.runInConsole(label: label, command: command) }
        vault.onRunCommandTracked = { [weak self] label, command, completion in
            self?.navigator.runInConsole(label: label, command: command, completion: completion)
        }
        vault.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.vault, vault)
    }()

    private(set) lazy var poneglyph: CredentialVaultController = {
        let poneglyph = CredentialVaultController()
        // Poneglyph is its own destination now
        // (`fm/poneglyph-own-destination-and-strawhat-toolbar-shortcut`), so
        // it wires this exactly like every other conforming destination
        // rather than through `SetupContainerController`'s own per-tab
        // forwarding.
        poneglyph.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.poneglyph, poneglyph)
    }()

    /// The credential vault's one store, for the readers that do not need the
    /// page: `GrandLineServices` owns it (F21), and the page holds the same
    /// instance. Reading it never builds the page.
    var credentialVaultStore: CredentialVaultStore {
        isBuilt(.poneglyph) ? poneglyph.credentialStore : GrandLineServices.shared.vault
    }

    #if FM_SELFTESTS
    /// The Poneglyph page and its store, so a suite can drive the real
    /// destination inside a real shell. `CredentialVaultViewSelfTest`'s
    /// list-geometry case needs the shell specifically: the bug it guards
    /// (`HelmCard.headerCollapsed`) was an *ambiguous* layout, and a card
    /// mounted in a simpler hierarchy resolves it the harmless way.
    var debugPoneglyph: CredentialVaultController { poneglyph }
    var debugPoneglyphStore: CredentialVaultStore { poneglyph.credentialStore }
    #endif

    private(set) lazy var dictation: DictationController = {
        let dictation = DictationController(store: dictationStore)
        dictation.onShortcutChanged = { [weak self] chord in self?.onKeyChordChanged?(chord) }
        dictation.onLocalWhisperEnabledChanged = { [weak self] enabled in self?.onDictationLocalWhisperChanged?(enabled) }
        dictation.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.dictation, dictation)
    }()

    /// `fm/grandline-schedules-sidebar-move`: F11's Schedules card, promoted
    /// off the Automation page onto its own rail destination - see
    /// `SchedulesController.swift`'s header.
    private(set) lazy var schedules: SchedulesController = {
        let schedules = SchedulesController(scheduleStore: scheduleStore)
        schedules.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        // `fm/grand-line-schedules-page-redesign`: a needs-you row's "Review"
        // button hands off to the page that owns that action
        // (`ScheduledActionKind.reviewDestination`). Same seam as Overview's.
        schedules.onNavigateToDestination = { [weak self] dest in self?.navigator.show(dest) }
        return built(.schedules, schedules)
    }()

    /// `fm/grandline-health-sidebar-move`: F1/GL-11's Health card, promoted
    /// off the Settings page onto its own rail destination - see
    /// `HealthController.swift`'s header.
    private(set) lazy var health: HealthController = {
        let health = HealthController()
        health.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        // UI12: both pages' empty states now offer a way out of themselves.
        health.onNavigateToDestination = { [weak self] dest in self?.navigator.show(dest) }
        // Stage 6: the two services with a real "run now" of their own, for
        // the sidebar layout's Retry. Both are the same entry points their
        // own pages' buttons use.
        health.retryActions = [
            .backgroundSignals: { BackgroundSignalsPoller.shared.checkNow() },
            .dotfilesAutoSync: { DotfilesAutoSync.shared.syncNowFromUI() },
        ]
        return built(.health, health)
    }()

    private(set) lazy var docs: DocsController = {
        let docs = DocsController()
        // Docs' subtitle still tracks the Playbook's own real sync state; its
        // action cluster no longer changes while it's on screen now that the
        // runbook editor (and the per-tab switch that used to empty the
        // cluster for it) moved to `.runbooks`.
        docs.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.docs, docs)
    }()

    /// `fm/grandline-docs-split-runbooks-postmortems`: Runbooks and
    /// Postmortems are their own top-level destinations now, split out of
    /// `DocsController`'s former tabs - see that file's own header.
    private(set) lazy var runbooks: RunbooksController = {
        let runbooks = RunbooksController(runbookStore: docsRunbookStore)
        // Runbooks inherited Docs' old per-editor-state cluster: "New
        // Runbook" beside a form already creating one is a second, competing
        // action, so its cluster empties while the editor is open.
        runbooks.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        runbooks.onDrillActionsChanged = { [weak self] in self?.chromeActionsMayHaveChanged() }
        return built(.runbooks, runbooks)
    }()

    /// F1 of full review #3 §8 - see `NotebookController.swift`'s header. Its
    /// store is built in `init` rather than inside the page, like every other
    /// store the canvas also reads (`HomeCanvasController`'s rule 1).
    private(set) lazy var notebook: NotebookController = {
        let notebook = NotebookController(store: notebookStore)
        notebook.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        notebook.onDrillActionsChanged = { [weak self] in self?.chromeActionsMayHaveChanged() }
        return built(.notebook, notebook)
    }()

    /// F4 of full review #3 §8 - see `ReadingListController.swift`'s header.
    /// Its store is built in `init` beside every other store the canvas also
    /// reads (`HomeCanvasController`'s rule 1).
    private(set) lazy var readingList: ReadingListController = {
        let readingList = ReadingListController(store: readingListStore)
        readingList.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        readingList.onDrillActionsChanged = { [weak self] in self?.chromeActionsMayHaveChanged() }
        return built(.readingList, readingList)
    }()

    private(set) lazy var postmortems: PostmortemsController = {
        let postmortems = PostmortemsController(runbookStore: docsRunbookStore)
        postmortems.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        postmortems.onNavigateToDestination = { [weak self] dest in self?.navigator.show(dest) }
        return built(.postmortems, postmortems)
    }()

    // The four Engineering setup pages, each wired exactly like every other
    // conforming destination since `fm/grandline-separate-setup-destinations`.
    // They used to route through `SetupContainerController`'s own per-tab
    // forwarding, which also had to fire on a tab switch because the line was
    // per-tab; each page owns its own header line now, so a page's own numbers
    // moving is the only thing that can change it.

    private(set) lazy var updates: UpdatesController = {
        let updates = UpdatesController()
        // cockpit-bootstrap-software: a `.notInstalled` row on the Updates
        // page no longer installs inline - it links to the Bootstrap page's
        // own Software checklist card instead (same catalog, same install
        // action, just relocated).
        updates.onNavigateToBootstrap = { [weak self] in self?.navigator.show(.bootstrap) }
        // An update that needs the captain's `sudo` password is never started
        // in the background (`BrewCaskSudo`); its row's "Run in Terminal"
        // opens the exact command here instead, then re-checks on exit.
        updates.onRunCommandTracked = { [weak self] label, command, completion in
            self?.navigator.runInConsole(label: label, command: command, completion: completion)
        }
        updates.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.updates, updates)
    }()

    private(set) lazy var bootstrap: BootstrapController = {
        let bootstrap = BootstrapController(hostStore: hostStore, keyStore: keyStore,
                                            snippetStore: snippetStore, dictationStore: dictationStore)
        // cockpit-bootstrap-dotfiles: every command the Bootstrap page can run
        // that touches `darwin-rebuild switch` (needs an interactive `sudo`
        // TTY) opens as a real tab in the shared Firstmate console rather
        // than a silent background process - see `runInConsole` below.
        bootstrap.onRunCommand = { [weak self] label, command in self?.navigator.runInConsole(label: label, command: command) }
        // cockpit-bootstrap-full-setup: the "Run full setup" sequencer needs
        // to know a step's Console command actually finished (not a fixed
        // timer) before starting the next one - same tab, same command
        // string, just with a completion callback threaded through.
        bootstrap.onRunCommandTracked = { [weak self] label, command, completion in
            self?.navigator.runInConsole(label: label, command: command, completion: completion)
        }
        bootstrap.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.bootstrap, bootstrap)
    }()

    private(set) lazy var automation: AutomationController = {
        let automation = AutomationController(hostStore: hostStore, keyStore: keyStore,
                                              snippetStore: snippetStore, dictationStore: dictationStore)
        // fm/grandline-automation-pipeline: the automation pipeline's own
        // dotfiles step needs the exact same real Console-tab/completion
        // wiring as Bootstrap's - it runs the identical clone/rebuild command
        // (`DotfilesRunCommand`, shared by both pages).
        automation.onRunCommandTracked = { [weak self] label, command, completion in
            self?.navigator.runInConsole(label: label, command: command, completion: completion)
        }
        automation.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        // Stage 7: the sidebar layout's Automation card lists the schedules,
        // from the app's one store, and links to the page that edits them.
        automation.scheduleStore = scheduleStore
        automation.onOpenSchedules = { [weak self] in self?.navigator.show(.schedules) }
        return built(.automation, automation)
    }()

    private(set) lazy var githubSync: GitHubSyncController = {
        let githubSync = GitHubSyncController()
        githubSync.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        return built(.githubSync, githubSync)
    }()


    /// Fix 1: builds a fresh, host-scoped `ConsoleController` (its own ssh
    /// tab(s) only, no Firstmate host's own Shell tab - see
    /// `ConsoleController.init(isFirstmateConsole:)`). Injected so this
    /// controller doesn't need to know about
    /// `SSHKeyStore`/`SnippetStore`, matching how it already knows nothing
    /// about host persistence (see `onPresentHostEditor` below).
    private let makeHostConsole: () -> ConsoleController

    // MARK: The Console canvas card's peek rows (review #3's UI9)

    /// How one console tab reads on the Console canvas card.
    ///
    /// **Review #3's UI9.** Every non-running tab used to read "exited",
    /// which is the word a crash gets - and a shell the captain closed on
    /// purpose is the overwhelmingly common case, so the card reported an
    /// alarming state for the most ordinary event a terminal has. It was
    /// honest (the process really had exited) and that is exactly why it
    /// could not simply be softened: GL-14 forbids painting an unknown or a
    /// failure as a clean result.
    ///
    /// `TabModel.ExitOutcome` is recorded where the termination actually
    /// happens, which is what lets this tell the four cases apart rather than
    /// collapsing them:
    ///
    /// - running -> `live`
    /// - exit 0 -> `closed`, and `.idle` - the ordinary end of a shell
    /// - exit N -> `exit N`, and `.warn` - the case that really is a fault
    /// - ended with no status -> `ended`, and `.warn` - not a clean exit
    /// - never started -> `idle`
    ///
    /// A static taking the three values rather than a `TabModel`, so the
    /// mapping can be asserted without a live terminal and a real child
    /// process (`Audit3UIFixesSelfTest`).
    static func consolePeekRow(name: String,
                               running: Bool,
                               lastExit: TabModel.ExitOutcome) -> HelmModulePeekRow {
        guard !running else { return HelmModulePeekRow(state: .ok, text: name, value: "live") }
        switch lastExit {
        case .clean: return HelmModulePeekRow(state: .idle, text: name, value: "closed")
        case .failed(let status): return HelmModulePeekRow(state: .warn, text: name, value: "exit \(status)")
        case .unknown: return HelmModulePeekRow(state: .warn, text: name, value: "ended")
        case .none: return HelmModulePeekRow(state: .idle, text: name, value: "idle")
        }
    }

    /// Add/Edit Host, requested from the Hosts panel - forwarded to whoever
    /// owns the host store (the app delegate), since this controller only
    /// arranges views and knows nothing about persistence.
    var onPresentHostEditor: ((Host?) -> Void)?

    /// F9 (v1) - the Command Library's "Send to…" action, forwarded on for
    /// the same reason `onPresentHostEditor` above is: the picker reads the
    /// saved hosts and the send opens their dedicated pages, and the host
    /// store lives with the app delegate.
    var onSendCommandToHosts: ((DevOpsCommand, [String: String], String) -> Void)?

    /// Fired whenever the Dictation page's shortcut recorder captures a new
    /// combo - the app delegate is what actually owns the live
    /// `DictationHotkey` instance, matching `onFontSizeStep`'s own
    /// forward-don't-own convention.
    ///
    /// Held here rather than forwarded into the page since PERF-01, so the
    /// app delegate wiring it at launch does not build the Dictation page.
    var onKeyChordChanged: ((KeyChord) -> Void)?

    /// Fired whenever a Settings > Shortcuts recorder captures a new
    /// combo, or the captain resets them all. Forwarded to the app delegate,
    /// which owns the live `TabKeyboardShortcuts` monitor - the same
    /// forward-don't-own convention `onKeyChordChanged` above already follows
    /// for Dictation's own hotkey.
    var onTerminalShortcutsChanged: ((TerminalShortcutSet) -> Void)?

    /// Fired whenever Settings > Capture's recorder captures a new chord.
    /// Forwarded to the app delegate, which owns the live `ShiftGlobalHotkey`
    /// and the Shift menu's Capture item - the same forward-don't-own
    /// convention the two above already follow.
    var onQuickCaptureShortcutChanged: ((KeyChord) -> Void)?

    /// E2: the Dictation page's local-Whisper toggle, forwarded the same way -
    /// switching it off must be able to release a resident engine (and with it
    /// the ggml Metal residency thread), not just stop future dictations from
    /// using one.
    var onDictationLocalWhisperChanged: ((Bool) -> Void)?

    /// Phase 4 ("Knowledge and speed"): the topbar Search pill's click,
    /// forwarded to whoever owns the unified `⌘K` search palette (the app
    /// delegate, mirroring `onPresentHostEditor`'s own forward-don't-own
    /// convention) rather than presented here.
    var onSearchTapped: (() -> Void)?

    /// Wired by the app delegate: the Snippets tab's "Run" sends a snippet to
    /// the console's active tab. Forwarded rather than owned, matching
    /// `onPresentHostEditor` - this controller knows nothing about snippets.
    var onRunSnippet: ((Snippet) -> Void)?

    /// `hostsPanel` and `settings` are how to build those two pages, run on
    /// their first use - the shell's own initialiser takes them as
    /// autoclosures (PERF-01), so the app delegate and every suite still write
    /// the page's construction at the call site.
    init(
        hostsPanel: @escaping () -> HostsController, console: ConsoleController,
        settings: @escaping () -> SettingsController,
        hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, shiftStore: ShiftStore,
        dictationStore: DictationStore, commandLibraryStore: CommandLibraryStore,
        scheduleStore: ScheduleStore,
        docsRunbookStore: DocsRunbookStore,
        makeHostConsole: @escaping () -> ConsoleController
    ) {
        // PERF-01: only the four eager pages (`homeCanvas`, `overview`,
        // `console`, `review`) and the stores other surfaces read are built
        // here. Every other destination is a lazy property, built on first
        // use - see "Lazy destinations" above.
        self.makeHostsPanel = hostsPanel
        self.makeSettings = settings
        self.console = console
        self.hostStore = hostStore
        self.keyStore = keyStore
        self.snippetStore = snippetStore
        self.dictationStore = dictationStore
        self.commandLibraryStore = commandLibraryStore
        self.scheduleStore = scheduleStore
        self.docsRunbookStore = docsRunbookStore
        // The shared `ShiftStore`, never a second instance - two consumers
        // on this page now. F12: the briefing's due-task count is the same
        // one the Tasks page shows. F6: Overview's "Log" tab reads the task
        // half of its feed straight from Shift's own activity YAML rather
        // than a second copy of it (see `FleetLogFeed`'s header).
        self.overview = FleetController(shiftStore: shiftStore)
        // Phase 5 (cockpit-shift-power-features): `shiftStore` is now built
        // once by the app delegate and shared with the menu bar item, the
        // search palette, and quick capture - all of which need to read/
        // write the same tasks/follow-ups this page shows, not a second
        // independent store instance.
        self.shiftStore = shiftStore
        // F7: the app's one focus timer, built from the one shared store
        // and handed to both surfaces that render it - the Tasks page's row
        // actions and the bar's chip. Never a second instance: two timers
        // would each believe they were the only one running.
        let focusTimer = FocusTimerController(store: shiftStore)
        self.focusTimer = focusTimer
        // PERF-02: one `DocsRunbookStore` (the app delegate's, which ⌘K
        // already reads) and one `LogAnalyzerStore` for every reader on this
        // shell - the Log Analyzer, Runbooks, Postmortems and the canvas.
        // Each of them used to build its own, and every one of those `init`s
        // started a git sync at launch; `GitSyncStartGate` makes a second
        // start a no-op, and this stops the second store existing at all.
        let logAnalyzerStore = LaunchSignposts.measure("LogAnalyzerStore.init") { LogAnalyzerStore() }
        self.logAnalyzerStore = logAnalyzerStore
        self.makeHostConsole = makeHostConsole
        // Daylight Phase 2: the canvas reads already-owned stores, never its
        // own - see `HomeCanvasController`'s header, and the source guard in
        // `DaylightModuleSelfTest` that enforces it. `DocsRunbookStore` and
        // `LogAnalyzerStore` are the same two instances the pages are handed
        // (PERF-02), not a second pair of the canvas's own.
        // One more store the shell did not already hold: it re-reads its own
        // git-synced folder per call, and
        // it honours `FM_CODE_PREVIEW_DIR`/`FM_SHIFT_DIR` so a self-test never
        // reaches the captain's real clone.
        // GL-23's lesson: **one** store instance shared by both consumers on
        // this page, not two. Neither caches, so two would not diverge the way
        // the two `CommandLibraryStore`s once did - but one is still the
        // cheaper and more obviously-correct answer.
        let codePreviewStore = LaunchSignposts.measure("CodePreviewStore.init") { CodePreviewStore() }
        self.codePreviewStore = codePreviewStore
        // GL-23's lesson again: **one** `NotebookStore`, shared by the page
        // and the canvas card. It re-reads its own git-synced folder per call
        // rather than caching, so two would not diverge - one is still the
        // cheaper and more obviously-correct answer.
        let notebookStore = LaunchSignposts.measure("NotebookStore.init") { NotebookStore() }
        self.notebookStore = notebookStore
        // GL-23 again: **one** `ReadingListStore`, shared by the page, the
        // canvas card, ⌘K's provider and ⌥Space's filer. This one caches its
        // decoded array, so a second instance would genuinely be a second
        // source of truth racing the first's writes.
        //
        // PERF-01: it and the Sticky Board's store below start empty and read
        // their YAML file on a background thread (`HelmBackgroundReload`).
        // Anything that reads their contents before that read lands reads the
        // file synchronously instead, so nothing ever sees an unloaded store
        // as an empty one - the canvas asks `isLoaded` and says "reading"
        // rather than paying for that read before the first frame.
        let readingListStore = LaunchSignposts.measure("ReadingListStore.init") {
            ReadingListStore(loadsInBackground: true)
        }
        self.readingListStore = readingListStore
        let stickyBoardStore = LaunchSignposts.measure("StickyBoardStore.init") {
            StickyBoardStore(loadsInBackground: true)
        }
        self.stickyBoardStore = stickyBoardStore
        let homeCanvas = HomeCanvasController(sources: .init(
            shiftStore: shiftStore,
            hostStore: hostStore,
            scheduleStore: scheduleStore,
            logAnalyzerStore: logAnalyzerStore,
            docsRunbookStore: docsRunbookStore,
            codePreviewStore: codePreviewStore,
            notebookStore: notebookStore,
            readingListStore: readingListStore,
            commandLibraryStore: commandLibraryStore,
            stickyBoardStore: stickyBoardStore))
        self.homeCanvas = homeCanvas
        // The canvas renders "reading" for either card until its store has
        // loaded; this is what puts the real contents there once it has.
        readingListStore.whenLoaded { [weak homeCanvas] in homeCanvas?.storeDidLoad() }
        stickyBoardStore.whenLoaded { [weak homeCanvas] in homeCanvas?.storeDidLoad() }
        // F21/F24: hand the four file-backed stores and the focus timer to
        // `GrandLineServices`, which is how an App Intent (no view controller,
        // possibly a launch it triggered itself) and Settings' Backup card
        // reach the *same* instances this shell just built - never a second
        // one (GL-23). A registry, not a factory: see that file's header.
        GrandLineServices.shared.register(shiftStore: shiftStore,
                                          notebookStore: notebookStore,
                                          stickyBoardStore: stickyBoardStore,
                                          codePreviewStore: codePreviewStore,
                                          focusTimer: focusTimer)
        lock.prepareForLock = { [unowned self] in self.prepareForLock() }
        lock.resumeAfterUnlock = { [unowned self] in self.hosts.forEachConsole { $0.resumeAfterUnlock() } }
        content.hostPages = { [unowned self] in Array(self.hosts.hostConsoles.values) }
    }

    /// The two things the lock does to the pages on the way in, in the order
    /// `showLock` has always run them - see `LockPresenter.showLock`.
    private func prepareForLock() {
        hosts.forEachConsole { $0.closeLockSensitiveSurfaces() }
        // PERF-01: this runs at launch (the `.launch` lock), so it only builds
        // the page when there is something to drop - the page exists, or the
        // vault's one store is open without it (an App Intent can do that).
        if isBuilt(.poneglyph) || credentialVaultStore.isUnlocked {
            poneglyph.lockForAppLock()
        }
    }

    // MARK: The destination table

    /// GL-37: the destination table. One line per body view replaces the six
    /// hand-maintained per-destination edit sites this used to need (see
    /// `DestinationRegistry.swift`'s header). Registration order is the old
    /// rail's own order, purely for readability - `show(_:)` looks slots up
    /// by id.
    ///
    /// PERF-01: each slot holds how to reach its controller rather than the
    /// controller, so a lazy page is *constructed* on its first `show(_:)` as
    /// well as mounted there. Reading a lazy property anywhere else builds the
    /// page too, which is why the pages' wiring lives in their own
    /// initialisers (see "Lazy destinations") and why a reach-in that does not
    /// navigate asks `isBuilt` first.
    ///
    /// The closures hold this object strongly rather than `unowned`: the
    /// mounter that keeps them is owned by `content`, which does not own this
    /// object, so there is no cycle to break.
    func registerDestinations() {
        let mounter = content.mounter
        mounter.register(DestinationSlot(id: .homeCanvas, title: RailDestination.homeCanvas.title, mountsEagerly: true, makeController: { [self] in self.homeCanvas }))
        mounter.register(DestinationSlot(id: .overview, title: RailDestination.overview.title, mountsEagerly: true, makeController: { [self] in self.overview }))
        mounter.register(DestinationSlot(id: .strawHat, title: RailDestination.strawHat.title, mountsEagerly: false, makeController: { [self] in self.strawHat }))
        mounter.register(DestinationSlot(id: .console, title: RailDestination.console.title, mountsEagerly: true, makeController: { [self] in self.console }))
        mounter.register(DestinationSlot(id: .hosts, title: RailDestination.hosts.title, mountsEagerly: false, makeController: { [self] in self.hostsPanel }))
        mounter.register(DestinationSlot(id: .shift, title: RailDestination.shift.title, mountsEagerly: false, makeController: { [self] in self.shift }))
        mounter.register(DestinationSlot(id: .calendar, title: RailDestination.calendar.title, mountsEagerly: false, makeController: { [self] in self.calendar }))
        mounter.register(DestinationSlot(id: .review, title: RailDestination.review.title, mountsEagerly: true, makeController: { [self] in self.review }))
        mounter.register(DestinationSlot(id: .logAnalyzer, title: RailDestination.logAnalyzer.title, mountsEagerly: false, makeController: { [self] in self.logAnalyzer }))
        mounter.register(DestinationSlot(id: .kubernetes, title: RailDestination.kubernetes.title, mountsEagerly: false, makeController: { [self] in self.kubernetes }))
        mounter.register(DestinationSlot(id: .tools, title: RailDestination.tools.title, mountsEagerly: false, makeController: { [self] in self.tools }))
        mounter.register(DestinationSlot(id: .whiteboard, title: RailDestination.whiteboard.title, mountsEagerly: false, makeController: { [self] in self.whiteboard }))
        mounter.register(DestinationSlot(id: .stickyBoard, title: RailDestination.stickyBoard.title, mountsEagerly: false, makeController: { [self] in self.stickyBoard }))
        mounter.register(DestinationSlot(id: .codePreview, title: RailDestination.codePreview.title, mountsEagerly: false, makeController: { [self] in self.codePreview }))
        mounter.register(DestinationSlot(id: .commandLibrary, title: RailDestination.commandLibrary.title, mountsEagerly: false, makeController: { [self] in self.commandLibrary }))
        mounter.register(DestinationSlot(id: .vault, title: RailDestination.vault.title, mountsEagerly: false, makeController: { [self] in self.vault }))
        mounter.register(DestinationSlot(id: .dictation, title: RailDestination.dictation.title, mountsEagerly: false, makeController: { [self] in self.dictation }))
        mounter.register(DestinationSlot(id: .schedules, title: RailDestination.schedules.title, mountsEagerly: false, makeController: { [self] in self.schedules }))
        mounter.register(DestinationSlot(id: .health, title: RailDestination.health.title, mountsEagerly: false, makeController: { [self] in self.health }))
        mounter.register(DestinationSlot(id: .docs, title: RailDestination.docs.title, mountsEagerly: false, makeController: { [self] in self.docs }))
        mounter.register(DestinationSlot(id: .notebook, title: RailDestination.notebook.title, mountsEagerly: false, makeController: { [self] in self.notebook }))
        mounter.register(DestinationSlot(id: .readingList, title: RailDestination.readingList.title, mountsEagerly: false, makeController: { [self] in self.readingList }))
        mounter.register(DestinationSlot(id: .runbooks, title: RailDestination.runbooks.title, mountsEagerly: false, makeController: { [self] in self.runbooks }))
        mounter.register(DestinationSlot(id: .postmortems, title: RailDestination.postmortems.title, mountsEagerly: false, makeController: { [self] in self.postmortems }))
        // `fm/grandline-separate-setup-destinations`: four ordinary lines,
        // where this was one `.setup` slot holding a
        // `SetupContainerController` that parented all four pages. Each of
        // them is now registered, titled, mounted and lazily built exactly
        // like every other destination in this table - see
        // `RailDestination.slot` for the captain's own reasoning.
        mounter.register(DestinationSlot(id: .updates, title: RailDestination.updates.title, mountsEagerly: false, makeController: { [self] in self.updates }))
        mounter.register(DestinationSlot(id: .bootstrap, title: RailDestination.bootstrap.title, mountsEagerly: false, makeController: { [self] in self.bootstrap }))
        mounter.register(DestinationSlot(id: .automation, title: RailDestination.automation.title, mountsEagerly: false, makeController: { [self] in self.automation }))
        mounter.register(DestinationSlot(id: .githubSync, title: RailDestination.githubSync.title, mountsEagerly: false, makeController: { [self] in self.githubSync }))
        mounter.register(DestinationSlot(id: .poneglyph, title: RailDestination.poneglyph.title, mountsEagerly: false, makeController: { [self] in self.poneglyph }))
        mounter.register(DestinationSlot(id: .settings, title: RailDestination.settings.title, mountsEagerly: false, makeController: { [self] in self.settings }))
    }

    /// The registry observation the chrome renders the session strip from.
    private var sessionsToken: UUID?

    func wireEagerPages() {
        // PERF-01: only the four eager pages are wired here. Every lazy
        // destination is wired inside its own initialiser (see "Lazy
        // destinations"), because assigning a callback to a lazy property
        // here would build the page at launch.
        //
        // Called once by the shell, at the point in its `loadView` where this
        // block used to sit: after the eager slots have mounted and before the
        // launch landing.

        // fm/grandline-overview-drop-duplicate-pr-list: Overview's own
        // itemized "Ready to merge" list was removed as a duplicate of
        // `.review`'s - the stat tile that's left jumps straight there.
        overview.onNavigateToReview = { [weak self] in self?.navigator.show(.review) }

        // The reverse direction of the Kubernetes feed guard (full-app audit,
        // finding 4.1). `isTabBusyElsewhere` lets the Kubernetes feed bridge
        // see the two console-side bridges; this lets them see it. Both halves
        // are wired by this object because it is the only one that holds both
        // a `ConsoleController` and the `.kubernetes` destination - neither of
        // them knows the other exists, and neither should.
        console.isKubernetesFeedBridgeBusy = { [weak self] tabID in
            self?.isKubernetesFeedBridgeBusy(onTab: tabID) ?? false
        }
        // GL-31: Overview's unconfigured banner leads straight into the
        // Bootstrap stepper, which is where firstmate home is actually set.
        overview.onNavigateToSetup = { [weak self] in self?.navigator.show(.bootstrap) }
        // F12: the morning briefing's clause deep links. `show(_:)` and
        // `openShiftTask(id:)` are both already the one way this app navigates
        // to a destination / opens a task, so these are pass-throughs rather
        // than new behaviour.
        overview.onNavigateToDestination = { [weak self] dest in self?.navigator.show(dest) }
        overview.onOpenShiftTask = { [weak self] id in self?.navigator.openShiftTask(id: id) }
        // Review #3 §7: the fleet dashboard's "Ask your crew" header button.
        // Plain navigation - the composer it replaced is gone, and the crew
        // page's own composer is the one place a message to them is written.
        overview.onOpenCrew = { [weak self] in self?.navigator.show(.strawHat) }

        // fm/grandline-sidebar-badges: forward each page's own already-
        // computed "needs you" count straight to its rail icon - no new
        // signal invented here, just the counts these two pages already
        // render every time they refresh.
        // fm/grandline-notification-center: these two signals already
        // recompute on every Overview/Review refresh (page visit, manual
        // refresh, and the `refreshIfNeeded()` calls just below) - piggy-
        // backing on the existing count callbacks means no new detection
        // logic and no new poll for either signal.
        // Daylight Phase 2: the rail badge these fed is gone. The same
        // already-computed counts now reach the captain through the bell (the
        // Notification Center, unchanged) and through the Fleet / Merge queue
        // modules' own chips, which read the snapshot pushed below. No new
        // signal was invented for either.
        overview.onNeedsDecisionCountChanged = { [weak self] count in
            NotificationSources.setFleetDecisions(count: count) {
                self?.navigator.show(.overview)
                // The sidebar layout's Crew › Needs you is where the decisions
                // are; the floating bar's are on the dashboard it just opened.
                self?.overview.revealNeedsYou()
            }
        }
        // The canvas's Fleet and Merge queue modules, fed from Overview's own
        // refresh rather than a fetch of their own - see
        // `FleetController.onSnapshotChanged`.
        overview.onQuotaChanged = { [weak self] result in
            self?.homeCanvas.applyQuota(result)
        }
        overview.onSnapshotChanged = { [weak self] snapshot, prs, failure in
            self?.homeCanvas.applyFleet(snapshot: snapshot, mergedPRs: prs, prFetchFailure: failure)
            self?.chrome?.workspaceCrewDidRead()
        }
        // GL-11/GL-30: the two failure signals (a background service failing
        // repeatedly, a save that did not reach disk) are raised from
        // background queues that know nothing about destinations, so they get
        // their navigation from here - the same forward-don't-own split every
        // other signal in `NotificationSources` uses. Set once; both entries
        // point at `.health` - fm/grandline-health-sidebar-move gave the
        // Health card its own rail destination, off the Settings page.
        NotificationSources.navigateToHealth = { [weak self] in self?.navigator.show(.health) }

        review.onReadyToMergeCountChanged = { [weak self] count in
            NotificationSources.setPRReady(count: count) { self?.navigator.show(.review) }
        }
        // F4: the OS-banner half of the same signal. The in-app entry above is
        // a count; this is the per-PR post that carries Merge / Open PR, and it
        // needs the rows themselves (URL, task id, checks) rather than a count.
        review.onPRsChanged = { prs in FleetNotifier.shared.reconcilePRs(prs) }
        // Daylight §6.4: every migrated drill page carries live numbers in the
        // header's subtitle, and the header is the shell's. They ask; nothing
        // writes into it but `applyDrillHeader`/`refreshDrillHeaderSubtitle`.

        review.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }

        // One observer turns every registry change into the two things that
        // have to follow it: the strip re-renders (and appears/disappears),
        // and the Hosts list's live rows are rebuilt if it is showing. Fired
        // synchronously at registration, which for an empty registry is
        // exactly the collapsed strip this wants at launch.
        sessionsToken = hosts.sessions.observe { [weak self] registry in
            self?.chrome?.workspaceSessionsDidChange(registry)
        }
        console.onDrillSubtitleChanged = { [weak self] in self?.chromeSubtitleMayHaveChanged() }
        // Trigger both pages' own refresh once at launch so the badges have
        // a real count before the captain ever visits Overview or Review -
        // every later update comes from those pages' existing refresh
        // triggers (page visit, manual refresh, a merge action), not a new
        // poll loop.
        overview.refreshIfNeeded()
        review.refreshIfNeeded()

        // Daylight Phase 2: the canvas's own forwarded actions. Every one is a
        // pass-through to something that already existed - `show(_:)`,
        // `openShiftTask(id:)`, and the two pages' own refresh entry points -
        // so the hub adds no behaviour of its own, only a faster way to reach
        // it.
        homeCanvas.onOpenDestination = { [weak self] dest in self?.navigator.show(dest) }
        homeCanvas.onOpenCrewDecisions = { [weak self] in
            self?.navigator.show(.overview)
            self?.overview.revealNeedsYou()
        }
        homeCanvas.onOpenShiftTask = { [weak self] id in self?.navigator.openShiftTask(id: id) }
        homeCanvas.onRefresh = { [weak self] in
            self?.overview.refreshIfNeeded()
            self?.review.refreshIfNeeded()
        }
        // The Claude status card's own Refresh. Overview already owns the
        // quota reading and both its readers; this forces it past the
        // freshness window rather than adding a second fetch path.
        homeCanvas.onRefreshQuota = { [weak self] in self?.overview.refreshQuotaNow() }
        // The Console module's peek rows. A closure, so the canvas never holds
        // a console or learns what a tab is.
        homeCanvas.consoleTabsProvider = { [weak self] in
            guard let self else { return [] }
            return self.console.tabs.map {
                Self.consolePeekRow(name: $0.name,
                                    running: $0.terminal.process.running,
                                    lastExit: $0.lastExit)
            }
        }
        homeCanvas.connectedHostIDs = { [weak self] in
            guard let self else { return [] }
            // Audit 2 §4.6: genuinely-connected pages, not merely built ones.
            // Every one of this closure's readers phrases the count as *live*
            // ("N host live", "N live", "N live sessions", and an `.ok` peek
            // row per host), so `Set(hostConsoles.keys)` had the canvas
            // reporting three live sessions for three F2-restored pages with
            // no process between them.
            return Set(self.hosts.hostConsoles.filter { $0.value.hasLiveSession }.keys)
        }
        // `fm/implement-grand-line-secrets-vault-poneg-ad`: the credential
        // vault's card reads this rather than constructing a store of its own
        // (`DaylightModuleSelfTest.checkCanvasConstructsNoStores` bans that,
        // and here it would also reach the production git sync). `loadState()`
        // is a `fileExists` plus, only on a genuine decode failure, GL-01's
        // one-time backup - no decryption and no subprocess, so it is safe on
        // every hub render. The count is `nil` while locked, because it is
        // inside the ciphertext.
        homeCanvas.credentialVaultState = { [weak self] in
            guard let self else { return (.absent, false, nil) }
            let store = self.credentialVaultStore
            return (store.loadState(), store.isUnlocked, store.isUnlocked ? store.credentials.count : nil)
        }
    }

    /// Where a launch lands - see the comments for why.
    func showLaunchLanding() {
        // GL-31: a machine with no firstmate home resolved lands on Bootstrap, not
        // on a Console tab in front of an Overview that can only report
        // zeroes. `FirstmateHome.root` is resolved once at launch, so this is
        // a one-time decision and cannot flap.
        //
        // Deliberately only this one condition: the app is genuinely usable
        // with no saved hosts, no Shift data and no Vault password beyond the
        // lock screen's own, so none of those should redirect a captain who
        // knows where they were going.
        // Daylight §5.2: the canvas is the launch landing - it is the
        // navigation, so landing anywhere else would hide it behind a back
        // button on the first run of every session. GL-31's own exception
        // stands unchanged: a machine with no firstmate home resolved lands on
        // Setup instead, because a canvas of modules that can only report
        // zeroes is worse than the page that fixes the cause.
        // R2-UX-01 (b): a profile that hides Setup has nothing there to fix -
        // a general user has no firstmate home and needs none - so it opens on
        // Home like any other launch.
        if FirstmateHome.homeOk() || (PlaceName.layout == .sidebar && AppSettings.shared.hiddenModules.contains(.setup)) {
            navigator.show(.homeCanvas)
        } else {
            AppLog.lifecycle.info("firstmate home not configured - opening Setup instead of the home canvas")
            navigator.show(.bootstrap)
        }
    }

    /// Flush anything the Sticky Board's debounced local write is still
    /// holding, on the way to quitting (findings 3.3/4.6).
    ///
    /// The store owns the debounce; this is only the shell's forward, needed
    /// because `stickyBoard` is `private` and the app delegate is where
    /// `applicationWillTerminate` lives. It is safe to call on a destination
    /// that was never mounted: the controller is constructed eagerly, its
    /// store with it, and a store with nothing queued flushes nothing.
    func shutdownStickyBoard(deadline: DispatchTime) {
        // PERF-01: the store can hold a pending write while the page was never
        // built - ⌘K, the crew and a widget tap all write to it directly - so
        // an unbuilt page still gets the store's two quit-time halves, in the
        // page's own order.
        guard isBuilt(.stickyBoard) else {
            stickyBoardStore.flushPendingWrite()
            _ = stickyBoardStore.gitSync?.flushForTerminationNow(deadline: deadline)
            return
        }
        stickyBoard.shutdown(deadline: deadline)
    }

    /// Flush every open Scratchpad tab's debounced text on the way to quitting
    /// (F9, `fm/grandline-feature-f9-scratchpad-calculator`).
    ///
    /// The shell's forward for the same reason its neighbours are: `tools` is
    /// `private` and the app delegate is where `applicationWillTerminate`
    /// lives. Without it, ⌘Q inside the pad's 500ms save debounce loses the
    /// last thing typed - which for a pad you come back to is the one failure
    /// that would make the feature untrustworthy. Safe on a page with no
    /// Scratchpad tab open: a tab of another kind flushes nothing.
    func shutdownScratchpads() {
        // A scratchpad is a Tools tab, so an unbuilt page has none to flush.
        guard isBuilt(.tools) else { return }
        tools.flushScratchpads()
    }

    /// Flush the reading list's debounced git commit on the way to quitting
    /// (F4, `fm/grandline-feature-f4-reading-list`).
    ///
    /// The shell's forward for the same reason the three below are:
    /// `readingList` is `private` and the app delegate is where
    /// `applicationWillTerminate` lives. Safe on a destination that was never
    /// mounted - the controller and its store are built eagerly at init, and a
    /// store with nothing queued flushes nothing.
    func shutdownReadingList(deadline: DispatchTime) {
        // PERF-01: ⌥Space and ⌘K write links without building the page, so
        // an unbuilt page still drains the store - the page's own two halves.
        guard isBuilt(.readingList) else {
            readingListStore.flush()
            readingListStore.gitSync?.flushForTerminationNow(deadline: deadline)
            return
        }
        readingList.shutdown(deadline: deadline)
    }

    /// Flush and commit anything Code Preview still has in flight, on the way
    /// to quitting (audit 2 §6.8 / §2.8).
    ///
    /// The shell's forward for the same reason `shutdownStickyBoard` is one:
    /// `codePreview` is `private` and the app delegate is where
    /// `applicationWillTerminate` lives.
    ///
    /// Safe on a destination that was never mounted - this page is lazily
    /// mounted, but its controller and store are built eagerly at init, and
    /// `CodePreviewController.shutdown()` no-ops on a page whose editor never
    /// loaded while its store still commits anything genuinely queued.
    func shutdownCodePreview(deadline: DispatchTime) {
        // PERF-01: an unbuilt page has no editor edits to wait for, but a
        // capture can still have written a snippet, so the git half runs.
        guard isBuilt(.codePreview) else {
            codePreviewStore.gitSync?.flushForTerminationNow(deadline: deadline)
            return
        }
        codePreview.shutdown(deadline: deadline)
    }

    /// Flush the Notebook's debounced edit and its git commit on the way to
    /// quitting (**review bug B7's second half**).
    ///
    /// `NotebookController.shutdown()` has been documented as "called on quit"
    /// since it shipped and had **no caller at all** - `main.swift` flushes
    /// every other debounced store and not this one. A ⌘Q inside the page's
    /// 500ms edit debounce lost the last keystrokes, which for a notebook is
    /// the sentence the captain had just finished typing.
    ///
    /// The shell's forward for the same reason the others here are: `notebook`
    /// is `private` and the app delegate is where quit is handled.
    func shutdownNotebook(deadline: DispatchTime) {
        // PERF-01: the same split as Code Preview's, for the same reason.
        guard isBuilt(.notebook) else {
            notebookStore.gitSync?.flushForTerminationNow(deadline: deadline)
            return
        }
        notebook.shutdown(deadline: deadline)
    }

    /// Flush the credential vault's debounced backup on the way to quitting,
    /// so a credential added seconds before quitting is still pushed to the
    /// captain's private config repo (`fm/implement-grand-line-secrets-vault-poneg-ad`).
    ///
    /// The shell's forward for the same reason the two above are: `poneglyph`
    /// (the credential vault, labeled "Poneglyph" - see
    /// `VaultController.swift`'s header for the full history) is `private`
    /// and the app delegate is where `applicationWillTerminate` lives. Safe on
    /// a destination that was never mounted - the controller and its store
    /// are built eagerly, and a store with nothing queued (or a vault that was
    /// never unlocked) flushes nothing.
    func shutdownCredentialVault(deadline: DispatchTime) {
        // PERF-01: the page and `GrandLineServices` hold one store; a store
        // nobody built has nothing to flush, and quitting must not build one.
        guard isBuilt(.poneglyph) else {
            if GrandLineServices.shared.hasBuiltVault { GrandLineServices.shared.vault.flushForTermination(deadline: deadline) }
            return
        }
        poneglyph.shutdown(deadline: deadline)
    }

    /// Cancel any in-flight Straw Hat turn on the way to quitting
    /// (`fm/implement-straw-hat-pirates-phase1-luffy-fb98`).
    ///
    /// The shell's forward for the same reason the three above are: `overview`
    /// is `private` and the app delegate is where `applicationWillTerminate`
    /// lives. Unlike those, this flushes nothing - there is no on-disk chat
    /// history in phase 1 by explicit scope. What it stops is a `claude -p`
    /// child outliving the app that spawned it: a turn is bounded at
    /// `ClaudeOneShot.conversationTimeout` (300s), so without this a captain
    /// who sends a message and immediately quits leaves a subprocess running
    /// for up to five minutes with nowhere to deliver its answer. GL-13's rule
    /// - background work stops when the thing it serves goes away.
    ///
    /// Safe on a page whose Crew tab was never opened: the runner is built
    /// lazily on the first send, so there is usually nothing to cancel.
    func shutdownStrawHatCrew() {
        // An unbuilt crew page has no runner to cancel.
        guard isBuilt(.strawHat) else { return }
        strawHat.shutdown()
    }

    /// `fm/straw-hat-menubar-quick-chat-popover`: one turn from the crew
    /// menu-bar popover, forwarded straight to `StrawHatController`'s own
    /// runner and real transcript - never a second, page-less conversation.
    /// See `StrawHatController.send(_:completion:)`'s own doc comment for
    /// the full reasoning, including why a proposal surfaced here is still
    /// confirmable on the real page afterward.
    func askCrewFromMenuBar(_ text: String, completion: @escaping (Result<[StrawHatSection], StrawHatError>) -> Void) {
        strawHat.send(text, completion: completion)
    }

    // MARK: F16 - the Poneglyph menu-bar popover

    /// The rows the status item's popover shows, and the copy it performs.
    ///
    /// Forwarded into the one `CredentialVaultController` rather than given
    /// a store of its own: `CredentialVaultStore` caches, GL-23 says a
    /// caching store gets exactly one instance, and two would hold two
    /// copies of the decrypted set and race each other's writes. Same
    /// forward-don't-own shape as `askCrewFromMenuBar` above.
    ///
    /// PERF-01: a locked store has no codes to list, so asking does not build
    /// the page unless the vault is open (an App Intent can open it without
    /// the page ever having been shown).
    var poneglyphQuickCodes: [PoneglyphQuickCode] {
        guard credentialVaultStore.isUnlocked else { return [] }
        return poneglyph.quickCodeEntries
    }

    var poneglyphIsUnlocked: Bool { credentialVaultStore.isUnlocked }

    @discardableResult
    func copyPoneglyphCodeFromMenuBar(id: String) -> String? {
        poneglyph.copyQuickCode(id: id)
    }

    /// fm/grandline-dictation-mvp: forwards the shared `DictationEngine`'s
    /// live state (recording/transcribing/back to a real permission-derived
    /// status) to the Dictation page, so it reflects reality in real time
    /// while visible rather than only on each `viewWillAppear`. A no-op if
    /// the page hasn't been visited yet - `DictationController.setEngineStatus`
    /// itself guards on `isViewLoaded`.
    /// Daylight Phase 3 also forwards it to the hub's Dictation module.
    /// `HomeCanvasController.applyDictationStatus` existed from Phase 2 but
    /// nothing ever called it, so that module's chip showed the initial
    /// `.ready` regardless of what the engine was actually doing - a card
    /// claiming "Ready" mid-recording, and claiming it on a machine that had
    /// never been granted microphone access. The engine already fans this
    /// status out to two subscribers (the Dictation page and the floating
    /// HUD); this is a third, not a new signal.
    func setDictationEngineStatus(_ status: DictationStatus) {
        // The page only renders a status once its view is loaded, so an
        // unbuilt page has nothing to update - and must not be built for it.
        if isBuilt(.dictation) { dictation.setEngineStatus(status) }
        homeCanvas.applyDictationStatus(status)
    }

    // MARK: Glue the pages call

    /// A page's live subtitle changed - re-read by whichever chrome is
    /// showing. Every page's `onDrillSubtitleChanged` lands here.
    func chromeSubtitleMayHaveChanged() { chrome?.workspaceSubtitleMayHaveChanged() }

    /// A page's own actions changed - see `chromeSubtitleMayHaveChanged`.
    func chromeActionsMayHaveChanged() { chrome?.workspaceActionsMayHaveChanged() }

    /// The live-session registry changed: rebuild the Hosts list's rows so a
    /// row that just went live (or just died) reads correctly the moment it
    /// is looked at. Both shells call this from `workspaceSessionsDidChange`.
    ///
    /// Rebuilding a hidden page's rows would be work nobody can see; it gets
    /// them on its next `viewWillAppear` instead.
    func refreshShowingHostsLiveSessionState() {
        if isBuilt(.hosts), hostsPanel.isViewLoaded, !hostsPanel.view.isHidden {
            hostsPanel.refreshLiveSessionState()
        }
    }

    /// ⌥Space's filer, bound to the stores and the two pages a capture can
    /// land in. See `CaptureFilingService`.
    func makeCaptureFiler() -> CaptureFiler {
        CaptureFiler { [weak self] destination, draft in
            guard let self else { return .refused("The app shell went away.") }
            return self.captureFiling.file(destination, draft)
        }
    }

    private var captureFiling: CaptureFilingService {
        CaptureFilingService(
            shiftStore: shiftStore,
            notebookStore: notebookStore,
            codePreviewStore: codePreviewStore,
            readingListStore: readingListStore,
            addStickyNote: { [weak self] title, text in
                self?.stickyBoard.addCapturedNote(title: title, text: text)
            },
            handOffCredential: { [weak self] secret in
                guard let self else { return }
                self.navigator.show(.poneglyph)
                self.poneglyph.presentCapturedCredential(secret: secret)
            })
    }

}
