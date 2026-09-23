// Manjesh Grand Line - native macOS app.
//
// The window's root content view controller.
//
// **Read the Daylight Phase 2 note below first** - it describes the shell as
// it is now (a floating bar plus a body container). The paragraphs
// immediately following this one describe the *rail-and-top-bar* shell that
// preceded it, and are kept because the per-destination decisions they record
// are all still true; only the chrome around them changed.
//
// Historically: a fixed `IconRailController` on the left, and to its right a
// `TopBarController` (always visible) above a body area that swaps between
// five destinations:
//
//   - .overview shows `FleetController` (Fix 1): the real fleet/PR dashboard.
//   - .hosts shows `HostsController` (Fix 2) as its own full destination -
//     no longer nested inside Console, so it's reachable exactly like
//     Settings is. As of Phase 5 of the full-app UI audit that destination
//     also owns SSH Keys and Snippets as segmented tabs, so the two floating
//     windows those used to live in no longer exist.
//   - .console shows `ConsoleController` alone: just the terminal/tabs area,
//     with no Hosts panel required to be visible alongside it.
//   - .review shows `ReviewController` (Fix 3, theme-audit task): the real,
//     data-backed PR review list, replacing the earlier "coming soon"
//     `PlaceholderViewController`.
//   - .settings shows `SettingsController` directly, in the body area rather
//     than a separate floating window, matching how the web app's Settings
//     is a `view`, not a window.
//
// Fix 1 (dedicated host pages) adds a sixth kind of destination that isn't
// part of the fixed `RailDestination` enum: one independent `ConsoleController`
// per connected host, holding only that host's own ssh tab(s) - never mixed
// with the Firstmate console's own Shell tab. These are built lazily via
// `makeHostConsole` the first time `connectHost` sees a given host id, then
// kept around (and re-shown, not re-opened) for as long as that host stays
// saved - see `connectHost`/`removeHostConsole` below.
//
// Every destination view - the five fixed ones and any host page - is added
// as a child up front (or lazily for host pages) and just has its `isHidden`
// flipped, never rebuilt, so nothing here can drop a running terminal session
// or its tabs.
//
// **Daylight Phase 2 rewrote the shell's chrome, and only its chrome.**
// `IconRailController` and `TopBarController` are gone. In their place:
//
//   root                             (a `ChromeFusionRootView`, so the window's
//   │                                 traffic lights can be re-centred on the
//   │                                 bar from its own `layout()` - A1)
//   ├── DaylightBarController.view   (floating bar, pinned 14/22, height 50 -
//   │                                 and, since A1, the window's top edge:
//   │                                 there is no system titlebar above it)
//   └── bodyContainer                (every destination, exactly as before)
//
// The drill header used to be a third child here, a 56pt strip between the
// bar and the body. The UI modernization audit's A2 merged it into the bar
// itself (`HelmDrillHeader` is the bar's leading cluster now), which is
// where the shell's remaining drill wiring below points.
//
// Everything below the chrome is untouched by that change, and deliberately:
// `DestinationRegistry`'s permanent-mount model, `show(_:)`, `connectHost`,
// every deep-link closure and every menu action behave exactly as they did.
// A "drill page" IS a mounted destination shown full-body - the only
// difference is that it now sits `HelmDrillHeader.height` further down and
// has a back affordance above it.
//
// The one genuinely new destination is `.homeCanvas` (`HomeCanvasController`),
// eagerly mounted because it is the launch landing and the target of every
// back button.

import AppKit

final class AppShellController: NSViewController {

    private var chromeTextScaleObservation: ChromeTextScaleObservation?

    /// Daylight Phase 2: the floating bar that replaced the rail and the old
    /// top bar. Internal (like `rail` was) so the app delegate can reach its
    /// notification centre and its space pills.
    let bar = DaylightBarController()

    /// A3: one observer, re-pointed at whatever is showing, that tells the
    /// bar when the page has scrolled off its own top edge. See
    /// `ScrollEdge.swift` for why this discovers the page's scroll view
    /// rather than asking the page for it.
    private let scrollEdge = ScrollEdgeObserver()
    /// What the drill navigation was last pointed at, so a page whose live
    /// numbers changed can have its subtitle re-read without the shell having
    /// to work out which destination is showing all over again.
    private var lastDrillContext: (title: String, subtitle: String, symbol: String,
                                   hue: HelmDomainHue, artwork: NSImage?, controller: NSViewController?)?

    /// The hub. Owns the space filter and the module grid; knows nothing about
    /// navigation beyond the closures wired below.
    private let homeCanvas: HomeCanvasController

    private let hostsPanel: HostsController
    private let console: ConsoleController
    private let settings: SettingsController
    private let overview: FleetController
    /// `fm/grandline-overview-page-daily-review`: the Overview page - F20's
    /// daily review on a destination of its own, opened by the leftmost space
    /// pill. Lazily mounted like every other page that owns no live process.
    private let dailyOverview: DailyOverviewController
    /// `fm/polish-straw-hat-overview-card-and-voice-c8d3`: the Straw Hat
    /// Pirates chat, its own destination since the captain asked for it to be
    /// its own Overview card rather than a tab inside Fleet's page. Lazily
    /// mounted - the controller exists at launch, its view does not.
    private let strawHat: StrawHatController
    private let shift: ShiftController
    private let review = ReviewController()
    /// `fm/grandline-log-analyzer-build`: the Log / Output Analyzer page.
    /// Owns its own `CommandLibraryStore`/`DocsRunbookStore`/
    /// `LogAnalyzerStore`, so this controller needs to know nothing about
    /// any of them - the same forward-don't-own convention every other
    /// destination here follows.
    private let logAnalyzer: LogAnalyzerController
    /// `fm/grandline-k8s-cluster-tail`. `lazy` for one concrete reason: it
    /// needs *this* controller's own `sessions` registry (there is exactly
    /// one - a second would be a second source of truth for "which hosts are
    /// live"), and a stored property with an inline default cannot be read
    /// from an initialiser's phase-1 assignments. It is still lazily *mounted*
    /// like every other non-eager destination; this only defers construction.
    private lazy var kubernetes = KubernetesController(sessions: sessions)
    /// F8: the host page whose capture seeded whatever the Log Analyzer is
    /// currently showing, so a save can be attached to that host's incident.
    /// Weak - a deleted host's page is torn down and must not be kept alive
    /// by this.
    private weak var logAnalyzerCaptureSource: ConsoleController?
    private let tools = ToolsController()
    /// `fm/grand-line-whiteboard-excalidraw`: the embedded Excalidraw canvas.
    /// Lazy like every other utility destination, and deliberately so - see
    /// `WhiteboardWebView`'s gating note: a session that never opens it never
    /// starts a web content process.
    private let whiteboard = WhiteboardController()
    /// `fm/grandline-sticky-board`: a freeform corkboard of draggable, colored
    /// sticky notes. Lazy like every other utility destination - see
    /// `StickyBoardController.swift`'s header.
    private let stickyBoard = StickyBoardController()
    /// `fm/grandline-monaco-code-preview`: the embedded Monaco editor. Lazy
    /// for the same reason the Whiteboard is - see `CodePreviewWebView`'s
    /// gating note: a session that never opens it never starts a web content
    /// process, never loads the 4MB bundle and never builds an editor.
    private let codePreview: CodePreviewController
    /// `fm/grandline-tasks-kanban-devops-split`: the Command Library's own
    /// destination. Was the third tab of `shift` - see
    /// `CommandLibraryController`'s header for why it moved.
    private let commandLibrary: CommandLibraryController

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

    /// The Sticky Board's own store - one instance, for the reason its own
    /// declaration gives.
    var stickyBoardStore: StickyBoardStore { stickyBoard.store }

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
    private let vault = VaultController()
    private let poneglyph = CredentialVaultController()

    #if FM_SELFTESTS
    /// The Poneglyph page and its store, so a suite can drive the real
    /// destination inside a real shell. `CredentialVaultViewSelfTest`'s
    /// list-geometry case needs the shell specifically: the bug it guards
    /// (`HelmCard.headerCollapsed`) was an *ambiguous* layout, and a card
    /// mounted in a simpler hierarchy resolves it the harmless way.
    var debugPoneglyph: CredentialVaultController { poneglyph }
    var debugPoneglyphStore: CredentialVaultStore { poneglyph.credentialStore }
    #endif
    private let dictation: DictationController
    /// `fm/grandline-schedules-sidebar-move`: F11's Schedules card, promoted
    /// off the Automation page onto its own rail destination - see
    /// `SchedulesController.swift`'s header.
    private let schedules: SchedulesController
    /// `fm/grandline-health-sidebar-move`: F1/GL-11's Health card, promoted
    /// off the Settings page onto its own rail destination - see
    /// `HealthController.swift`'s header.
    private let health = HealthController()
    private let docs = DocsController()
    /// `fm/grandline-docs-split-runbooks-postmortems`: Runbooks and
    /// Postmortems are their own top-level destinations now, split out of
    /// `DocsController`'s former tabs - see that file's own header.
    private let runbooks = RunbooksController()
    /// F1 of full review #3 §8 - see `NotebookController.swift`'s header. Its
    /// store is built here rather than inside the page, like every other
    /// store the canvas also reads (`HomeCanvasController`'s rule 1).
    private let notebook: NotebookController
    /// F4 of full review #3 §8 - see `ReadingListController.swift`'s header.
    /// Its store is built in `init` beside every other store the canvas also
    /// reads (`HomeCanvasController`'s rule 1).
    private let readingList: ReadingListController
    private let postmortems = PostmortemsController()
    private let updates = UpdatesController()
    private let bootstrap: BootstrapController
    private let automation: AutomationController
    private let githubSync = GitHubSyncController()

    /// Fix 1: builds a fresh, host-scoped `ConsoleController` (its own ssh
    /// tab(s) only, no Firstmate host's own Shell tab - see
    /// `ConsoleController.init(isFirstmateConsole:)`). Injected so this
    /// controller doesn't need to know about
    /// `SSHKeyStore`/`SnippetStore`, matching how it already knows nothing
    /// about host persistence (see `onPresentHostEditor` below).
    private let makeHostConsole: () -> ConsoleController

    /// One dedicated page per connected host, keyed by `Host.id`. Built
    /// lazily by `connectHost`, torn down by `removeHostConsole` when a host
    /// is deleted from the store.
    private var hostConsoles: [UUID: ConsoleController] = [:]

    /// The body area every destination view (fixed or host page) is added
    /// to - a stored property (rather than a `loadView`-local `let`) so
    /// `connectHost`/`removeHostConsole` can add and remove host pages after
    /// the initial layout pass.
    private let bodyContainer = NSView()

    /// GL-37: the destination table plus the lazy-mount mechanics - see
    /// `DestinationRegistry.swift`. `unowned self` rather than `weak`: this
    /// closure only ever runs from `show(_:)`/`mountEagerSlots()`, both of
    /// which are reached through `self`, so `self` is alive by construction,
    /// and the mounter is owned by `self` so there is no retain cycle to
    /// break beyond that.
    private lazy var mounter = DestinationMounter(
        mount: { [unowned self] controller in
            self.addChild(controller)
            self.embed(controller.view)
        },
        setVisible: { [unowned self] controller, visible in
            self.setDestinationVisible(controller.view, visible)
        }
    )

    /// `fm/grandline-live-gap-rootcause-scout`: named (rather than anonymous,
    /// like every other constraint activated in `loadView`) so
    /// `reassertBodyContainerWidthTie()` can check/repair them on every
    /// window resize - see that method's own doc comment for why a plain
    /// `equalTo:` tie alone was not enough to guarantee this stays correct.
    private var bodyLeadingConstraint: NSLayoutConstraint!
    private var bodyTrailingConstraint: NSLayoutConstraint!

    /// Fires on every window resize (registered globally, `object: nil`,
    /// matching `ToolsController.containerWidthMayHaveChanged`'s own
    /// convention - see AGENTS.md) so `bodyContainer` never settles at a
    /// width that no longer matches the window's current content area.
    private var windowResizeObserver: NSObjectProtocol?

    /// Set while a host's dedicated page is showing; `nil` whenever a fixed
    /// `RailDestination` is current, so `removeHostConsole` knows whether to
    /// navigate away. It used to be mirrored by the rail's own
    /// `activeHostID` for per-host icon highlighting; with the rail gone
    /// (Daylight §5.1) this is the only copy.
    private var activeHostID: UUID?

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

    // MARK: Live SSH sessions (`fm/grandline-session-switcher`)

    /// The app's one answer to "which hosts are live right now". Written only
    /// from the three moments this controller already owned that fact
    /// (`connectHost`, `revealHostConsole`, `removeHostConsole`); read by the
    /// session strip, the Hosts list's per-row live state, the ⌘K palette's
    /// pinned "Active sessions" group and the session shortcuts. `hostConsoles`
    /// above is still the only thing that maps an id back to a real console -
    /// this registry carries no controller reference, deliberately.
    let sessions = HostSessionRegistry()

    /// The persistent pill strip, docked under the bar. Visible only while at
    /// least one session is live, and collapsed to height 0 as well as hidden
    /// when it is not - an ordinary hidden `NSView`'s constraints still
    /// participate fully in layout (AGENTS.md gotcha (11)), so hiding alone
    /// would leave a permanent gap above every destination.
    private let sessionStrip = SessionStripView()
    private var sessionStripHeightConstraint: NSLayoutConstraint!
    private var bodyTopConstraint: NSLayoutConstraint!
    private var sessionsToken: UUID?

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
    private var currentDestinationKind: RecentDestinationKind?

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

    /// Add/Edit Host, requested from the Hosts panel - forwarded to whoever
    /// owns the host store (the app delegate), since this controller only
    /// arranges views and knows nothing about persistence.
    var onPresentHostEditor: ((Host?) -> Void)?

    /// F9 (v1) - the Command Library's "Send to…" action, forwarded on for
    /// the same reason `onPresentHostEditor` above is: the picker reads the
    /// saved hosts and the send opens their dedicated pages, and the host
    /// store lives with the app delegate.
    var onSendCommandToHosts: ((DevOpsCommand, [String: String], String) -> Void)?

    // MARK: App-level password lock (fm/grandline-app-lock)

    private let lockScreen = LockScreenController()

    /// Fired once a correct password is entered - the app delegate's
    /// `AppLockController` owns turning this into "unlocked" state (and
    /// starting its own idle/hard-logout timers from this moment); this
    /// controller only knows "the form was accepted."
    var onUnlocked: (() -> Void)?

    /// Fired whenever the lock overlay's visibility changes, `true` while
    /// locked - the app delegate uses this to disable the main menu's
    /// content-bearing items (see `AppDelegate.setContentMenusEnabled`) so a
    /// keyboard shortcut like ⌘N can't reach a hidden destination's action
    /// while the overlay is covering it.
    var onLockStateChanged: ((Bool) -> Void)?

    /// The avatar's Logout action (confirmed inside `DaylightBarController`
    /// itself) - forwarded to the app delegate's `AppLockController`, which
    /// is what actually flips the lock state, matching how host-editor
    /// presentation is forwarded rather than owned here.
    var onLogoutRequested: (() -> Void)?

    /// Fired whenever the Dictation page's shortcut recorder captures a new
    /// combo - the app delegate is what actually owns the live
    /// `DictationHotkey` instance, matching `onFontSizeStep`'s own
    /// forward-don't-own convention.
    var onKeyChordChanged: ((KeyChord) -> Void)? {
        get { dictation.onShortcutChanged }
        set { dictation.onShortcutChanged = newValue }
    }

    /// Fired whenever a Settings > Terminal Shortcuts recorder captures a new
    /// combo, or the captain resets them all. Forwarded to the app delegate,
    /// which owns the live `TabKeyboardShortcuts` monitor - the same
    /// forward-don't-own convention `onKeyChordChanged` above already follows
    /// for Dictation's own hotkey.
    var onTerminalShortcutsChanged: ((TerminalShortcutSet) -> Void)? {
        get { settings.onTerminalShortcutsChanged }
        set { settings.onTerminalShortcutsChanged = newValue }
    }

    /// E2: the Dictation page's local-Whisper toggle, forwarded the same way -
    /// switching it off must be able to release a resident engine (and with it
    /// the ggml Metal residency thread), not just stop future dictations from
    /// using one.
    var onDictationLocalWhisperChanged: ((Bool) -> Void)? {
        get { dictation.onLocalWhisperEnabledChanged }
        set { dictation.onLocalWhisperEnabledChanged = newValue }
    }

    /// Phase 4 ("Knowledge and speed"): the topbar Search pill's click,
    /// forwarded to whoever owns the unified `⌘K` search palette (the app
    /// delegate, mirroring `onPresentHostEditor`'s own forward-don't-own
    /// convention) rather than presented here.
    var onSearchTapped: (() -> Void)?

    init(
        hostsPanel: HostsController, console: ConsoleController, settings: SettingsController,
        hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, shiftStore: ShiftStore,
        dictationStore: DictationStore, commandLibraryStore: CommandLibraryStore,
        scheduleStore: ScheduleStore,
        makeHostConsole: @escaping () -> ConsoleController
    ) {
        self.hostsPanel = hostsPanel
        self.console = console
        self.settings = settings
        // The shared `ShiftStore`, never a second instance - two consumers
        // on this page now. F12: the briefing's due-task count is the same
        // one the Tasks page shows. F6: Overview's "Log" tab reads the task
        // half of its feed straight from Shift's own activity YAML rather
        // than a second copy of it (see `FleetLogFeed`'s header).
        // Phase 3 (M3.1): the crew's three new proposal kinds write to the
        // command library, the sticky board and the schedules - so this page
        // now needs the *stores*, not just the command library's root. All
        // three are the shared instances (`stickyBoard.store` is `internal`
        // for exactly this reason, per audit section 6.5b): each one caches
        // its records as well as writing them, so a second instance would be
        // a second writer to the same file.
        self.overview = FleetController(shiftStore: shiftStore)
        // The same shared `ShiftStore` (GL-23), never a second instance - the
        // daily review reads the very lists the Tasks page is showing.
        self.dailyOverview = DailyOverviewController(shiftStore: shiftStore)
        // The four store dependencies below were `FleetController`'s while the
        // crew chat was a tab on that page; they came here with it. All three
        // stores are the shared instances (`stickyBoard.store` is `internal`
        // for exactly this reason, per audit section 6.5b): each caches its
        // records as well as writing them, so a second instance would be a
        // second writer to the same file. The command library is handed over
        // as a *root* URL because the crew only ever reads it through their
        // `command_search` tool - constructing a second store for that would
        // be the mistake GL-24 fixed.
        self.strawHat = StrawHatController(shiftStore: shiftStore,
                                           commandLibraryRoot: commandLibraryStore.root,
                                           commandLibraryStore: commandLibraryStore,
                                           stickyStore: stickyBoard.store,
                                           scheduleStore: scheduleStore)
        self.dictation = DictationController(store: dictationStore)
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
        self.shift = ShiftController(store: shiftStore, focusTimer: focusTimer)
        // GL-23 again: the same shared instance the Log Analyzer, the crew's
        // `command_search` tool and the ⌘K palette already read.
        self.commandLibrary = CommandLibraryController(store: commandLibraryStore)
        // GL-23: the same instance the Tasks page uses.
        self.logAnalyzer = LogAnalyzerController(commandLibrary: commandLibraryStore)
        self.bootstrap = BootstrapController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore)
        self.automation = AutomationController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
                                               dictationStore: dictationStore)
        // `fm/grandline-schedules-sidebar-move`: the schedules card's own
        // destination, not a section of `.automation` anymore.
        self.schedules = SchedulesController(scheduleStore: scheduleStore)
        self.makeHostConsole = makeHostConsole
        // Daylight Phase 2: the canvas reads already-owned stores, never its
        // own - see `HomeCanvasController`'s header, and the source guard in
        // `DaylightModuleSelfTest` that enforces it. `DocsRunbookStore` and
        // `LogAnalyzerStore` are the two the shell did not already hold, so
        // they are constructed here alongside the rest of this controller's
        // own dependencies rather than inside the canvas - each store re-reads
        // its git-synced folder per call, which is the same "an independent
        // instance is fine and cheap" pattern `UnifiedSearch` already uses.
        // One more store the shell did not already hold, on the same terms as
        // the two below: it re-reads its own git-synced folder per call, and
        // it honours `FM_CODE_PREVIEW_DIR`/`FM_SHIFT_DIR` so a self-test never
        // reaches the captain's real clone.
        // GL-23's lesson: **one** store instance shared by both consumers on
        // this page, not two. Neither caches, so two would not diverge the way
        // the two `CommandLibraryStore`s once did - but one is still the
        // cheaper and more obviously-correct answer.
        let codePreviewStore = CodePreviewStore()
        self.codePreviewStore = codePreviewStore
        self.codePreview = CodePreviewController(store: codePreviewStore)
        // GL-23's lesson again: **one** `NotebookStore`, shared by the page
        // and the canvas card. It re-reads its own git-synced folder per call
        // rather than caching, so two would not diverge - one is still the
        // cheaper and more obviously-correct answer.
        let notebookStore = NotebookStore()
        self.notebookStore = notebookStore
        self.notebook = NotebookController(store: notebookStore)
        // GL-23 again: **one** `ReadingListStore`, shared by the page, the
        // canvas card, ⌘K's provider and ⌥Space's filer. This one caches its
        // decoded array, so a second instance would genuinely be a second
        // source of truth racing the first's writes.
        let readingListStore = ReadingListStore()
        self.readingListStore = readingListStore
        self.readingList = ReadingListController(store: readingListStore)
        self.homeCanvas = HomeCanvasController(sources: .init(
            shiftStore: shiftStore,
            hostStore: hostStore,
            scheduleStore: scheduleStore,
            logAnalyzerStore: LogAnalyzerStore(),
            docsRunbookStore: DocsRunbookStore(),
            codePreviewStore: codePreviewStore,
            notebookStore: notebookStore,
            readingListStore: readingListStore,
            commandLibraryStore: commandLibraryStore,
            stickyBoardStore: stickyBoard.store))
        // F21/F24: hand the four file-backed stores and the focus timer to
        // `GrandLineServices`, which is how an App Intent (no view controller,
        // possibly a launch it triggered itself) and Settings' Backup card
        // reach the *same* instances this shell just built - never a second
        // one (GL-23). A registry, not a factory: see that file's header.
        GrandLineServices.shared.register(shiftStore: shiftStore,
                                          notebookStore: notebookStore,
                                          stickyBoardStore: stickyBoard.store,
                                          codePreviewStore: codePreviewStore,
                                          focusTimer: focusTimer)
        super.init(nibName: nil, bundle: nil)
        // F20: Overview's daily review reads the sticky board and the reading
        // list, both of which are built above - after `overview` itself, which
        // is why this is an attach rather than two more `init` parameters.
        // GL-23: the shared instances, the same ones the canvas and the two
        // destinations use.
        overview.attachDailyReviewSources(stickyBoardStore: stickyBoard.store,
                                          readingListStore: readingListStore)
        // The Overview page hosts the same card, over the same two shared
        // stores. One attach each rather than one store each - see
        // `DailyOverviewController`'s header for why both hosts exist.
        dailyOverview.attachDailyReviewSources(stickyBoardStore: stickyBoard.store,
                                               readingListStore: readingListStore)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // A1: a `ChromeFusionRootView` rather than a plain `NSView`, purely
        // for its `layout()` hook - AppKit resets the traffic lights' frames
        // on every layout pass, so the reposition has to ride that same
        // pass. `WindowChromeFusion`'s header records the measurements.
        let root = ChromeFusionRootView(frame: NSRect(x: 0, y: 0, width: 1220, height: 720))
        root.wantsLayer = true
        root.onLayout = { [weak self] in
            guard let self else { return }
            WindowChromeFusion.positionTrafficLights(
                in: self.view.window,
                verticalCenter: DaylightBarController.trafficLightCenterY,
                leadingX: DaylightBarController.trafficLightLeadingX)
            // `fm/grand-line-body-width-selfheal-layout-fix`: the width tie's
            // repair rides this same pass, for the same reason the traffic
            // lights do. Before this, `reassertBodyContainerWidthTie()` had
            // exactly two triggers - `loadView` and
            // `NSWindow.didResizeNotification` (both still below) - so a tie
            // AppKit deactivated, or a frame that went stale, for any reason
            // other than a resize stayed visibly broken until the captain
            // happened to resize the window or restart the app. A layout pass
            // is when a constraint conflict actually resolves, so repairing
            // from here catches it at the moment it happens rather than at the
            // next resize that may never come. See
            // `data/grand-line-stray-window-glitch-scout/report.md` "BUG B"
            // for the live capture (a 1512pt-wide window surface with only
            // ~670pt of it laid out and drawn, the rest undrawn black,
            // unrecoverable without a quit-and-reopen).
            //
            // **This does not reintroduce GL-20's resize-frame cost, and that
            // was measured rather than argued** (a temporary counter, reverted
            // before commit): across ten idle layout passes on a settled
            // window this enters the method ten times and forces **zero**
            // layout passes - the staleness gate GL-20 added returns early on
            // every one. The per-pass cost is two frame reads and two
            // `isActive` checks. Only a genuine break or a genuinely stale
            // frame pays for a resolve (4 across a launch plus four resizes,
            // all of them real work).
            self.reassertBodyContainerWidthTie(insideLayoutPass: true)
        }
        view = root

        // Daylight Phase 2: this view is the window's *ground* now, and it has
        // to paint. Before, the rail and the top bar between them covered
        // every pixel of it; the floating bar deliberately does not - there is
        // a real 20pt band of ground between the bar's bottom edge and the
        // body container, which is what makes the bar read as floating rather
        // than as a header strip. A layer-backed view with no explicit
        // background paints nothing at all (AGENTS.md gotcha (8)), so that
        // band would show the window's own backing through it.
        //
        // This controller had no `ThemeManager` observation before, for the
        // same reason: it painted nothing. It is an app-lifetime singleton, so
        // the token is discarded like every other such observer here.
        _ = ThemeManager.shared.observe { [weak self] theme in
            self?.view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        }

        // GL-32: one place turns a chrome-text-scale change into the app-wide
        // repaint every page already knows how to do. See
        // `ThemeManager.reapplyCurrentTheme`'s own note on why this rides the
        // theme observer rather than adding a second fan-out of its own. The
        // token is discarded deliberately - this controller is the window's
        // root and lives for the process.
        chromeTextScaleObservation = ChromeTextScale.shared.observe { [weak self] _ in
            guard let self, self.isViewLoaded else { return }
            ThemeManager.shared.reapplyCurrentTheme()
            self.view.layoutSubtreeIfNeeded()
        }

        addChild(bar)
        root.addSubview(bar.view)
        bar.view.translatesAutoresizingMaskIntoConstraints = false
        // A space pill navigates to the canvas (if it is not already showing)
        // and filters it. That two-step is here rather than in the bar for
        // §5.3's reason: the bar must not know what a canvas is.
        bar.onSelectSpace = { [weak self] space in self?.selectSpace(space) }
        // The bar's two quick-access icons (Sticky Board, Code Preview) - one
        // click from anywhere in the app, straight to the destination, using
        // the same `show(_:)` every other entry point uses rather than a
        // second navigation path (`fm/grandline-sticky-code-preview-polish`).
        bar.onSelectDestination = { [weak self] destination in self?.show(destination) }
        bar.onSelectSettings = { [weak self] in self?.show(.settings) }
        bar.onLogoutRequested = { [weak self] in self?.onLogoutRequested?() }
        // `fm/grandline-recents-navigation`: the Recents popover reads this
        // controller's own registry and dispatches a click back through
        // whichever navigation primitive already handles that kind - never a
        // third path.
        bar.recentDestinations.configure(registry: recentDestinations) { [weak self] kind in
            self?.navigateToRecentDestination(kind)
        }

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bodyContainer)

        bar.onDrillBack = { [weak self] in self?.show(.homeCanvas) }
        // A3: the bar is the only thing that reacts to the scroll edge, and
        // the observer is the only thing that knows about it.
        scrollEdge.onChange = { [weak self] active in self?.bar.setScrollEdgeActive(active) }
        // Phase 4 ("Knowledge and speed") superseded Fix 4's original mapping
        // here (an in-terminal find stand-in, since there was no real global
        // search yet) - the topbar Search pill (and its `⌘K` badge) now opens
        // the real unified search palette, forwarded to the app delegate via
        // `onSearchTapped` (see that property's own doc comment) rather than
        // owned by this controller. Plain find-in-terminal is unaffected -
        // it's still reachable via the console toolbar's own magnifying-glass
        // icon (`ConsoleController.showFind`) and the Edit menu's `⌘F`.
        bar.onSearchTapped = { [weak self] in self?.onSearchTapped?() }
        // F7: the chip is the feature's "it follows you off the Tasks page"
        // half, so the bar gets the timer as soon as both exist.
        bar.attachFocusTimer(focusTimer)

        // GL-37: the destination table. One line per body view replaces the
        // six hand-maintained per-destination edit sites this used to need
        // (see `DestinationRegistry.swift`'s header). Registration order is
        // the rail's own order, purely for readability - `show(_:)` looks
        // slots up by id.
        //
        // Constructing a controller does not run its `loadView`; only
        // `mount` does, which for a lazy slot is the first `show(_:)` that
        // names it. So every reference to these properties elsewhere in this
        // file is safe before a first visit as long as it only *assigns a
        // closure* (which the wiring below does) - anything that touches a
        // destination's views goes through `show(_:)` first.
        mounter.register(DestinationSlot(id: .homeCanvas, title: RailDestination.homeCanvas.title, mountsEagerly: true, controller: homeCanvas))
        mounter.register(DestinationSlot(id: .dailyOverview, title: RailDestination.dailyOverview.title, mountsEagerly: false, controller: dailyOverview))
        mounter.register(DestinationSlot(id: .overview, title: RailDestination.overview.title, mountsEagerly: true, controller: overview))
        mounter.register(DestinationSlot(id: .strawHat, title: RailDestination.strawHat.title, mountsEagerly: false, controller: strawHat))
        mounter.register(DestinationSlot(id: .console, title: RailDestination.console.title, mountsEagerly: true, controller: console))
        mounter.register(DestinationSlot(id: .hosts, title: RailDestination.hosts.title, mountsEagerly: false, controller: hostsPanel))
        mounter.register(DestinationSlot(id: .shift, title: RailDestination.shift.title, mountsEagerly: false, controller: shift))
        mounter.register(DestinationSlot(id: .review, title: RailDestination.review.title, mountsEagerly: true, controller: review))
        mounter.register(DestinationSlot(id: .logAnalyzer, title: RailDestination.logAnalyzer.title, mountsEagerly: false, controller: logAnalyzer))
        mounter.register(DestinationSlot(id: .kubernetes, title: RailDestination.kubernetes.title, mountsEagerly: false, controller: kubernetes))
        mounter.register(DestinationSlot(id: .tools, title: RailDestination.tools.title, mountsEagerly: false, controller: tools))
        mounter.register(DestinationSlot(id: .whiteboard, title: RailDestination.whiteboard.title, mountsEagerly: false, controller: whiteboard))
        // UX10: the board raises a note to promote; this controller is the
        // one place that holds both destinations.
        stickyBoard.onMakeTaskFromNote = { [weak self] note in self?.makeTaskFromStickyNote(note) }
        mounter.register(DestinationSlot(id: .stickyBoard, title: RailDestination.stickyBoard.title, mountsEagerly: false, controller: stickyBoard))
        mounter.register(DestinationSlot(id: .codePreview, title: RailDestination.codePreview.title, mountsEagerly: false, controller: codePreview))
        mounter.register(DestinationSlot(id: .commandLibrary, title: RailDestination.commandLibrary.title, mountsEagerly: false, controller: commandLibrary))
        mounter.register(DestinationSlot(id: .vault, title: RailDestination.vault.title, mountsEagerly: false, controller: vault))
        mounter.register(DestinationSlot(id: .dictation, title: RailDestination.dictation.title, mountsEagerly: false, controller: dictation))
        mounter.register(DestinationSlot(id: .schedules, title: RailDestination.schedules.title, mountsEagerly: false, controller: schedules))
        mounter.register(DestinationSlot(id: .health, title: RailDestination.health.title, mountsEagerly: false, controller: health))
        mounter.register(DestinationSlot(id: .docs, title: RailDestination.docs.title, mountsEagerly: false, controller: docs))
        mounter.register(DestinationSlot(id: .notebook, title: RailDestination.notebook.title, mountsEagerly: false, controller: notebook))
        mounter.register(DestinationSlot(id: .readingList, title: RailDestination.readingList.title, mountsEagerly: false, controller: readingList))
        mounter.register(DestinationSlot(id: .runbooks, title: RailDestination.runbooks.title, mountsEagerly: false, controller: runbooks))
        mounter.register(DestinationSlot(id: .postmortems, title: RailDestination.postmortems.title, mountsEagerly: false, controller: postmortems))
        // `fm/grandline-separate-setup-destinations`: four ordinary lines,
        // where this was one `.setup` slot holding a
        // `SetupContainerController` that parented all four pages. Each of
        // them is now registered, titled, mounted and lazily built exactly
        // like every other destination in this table - see
        // `RailDestination.slot` for the captain's own reasoning.
        mounter.register(DestinationSlot(id: .updates, title: RailDestination.updates.title, mountsEagerly: false, controller: updates))
        mounter.register(DestinationSlot(id: .bootstrap, title: RailDestination.bootstrap.title, mountsEagerly: false, controller: bootstrap))
        mounter.register(DestinationSlot(id: .automation, title: RailDestination.automation.title, mountsEagerly: false, controller: automation))
        mounter.register(DestinationSlot(id: .githubSync, title: RailDestination.githubSync.title, mountsEagerly: false, controller: githubSync))
        mounter.register(DestinationSlot(id: .poneglyph, title: RailDestination.poneglyph.title, mountsEagerly: false, controller: poneglyph))
        mounter.register(DestinationSlot(id: .settings, title: RailDestination.settings.title, mountsEagerly: false, controller: settings))

        // Built here, before the window is ever shown, for the three
        // invariants `DestinationRegistry.swift` documents (a live PTY, and
        // two launch-seeded rail badges that render through their own
        // views). Every other slot waits for its first `show(_:)`.
        mounter.mountEagerSlots()

        // Daylight Phase 2: `bodyContainer` now spans the window's full width -
        // there is no rail to sit beside - and starts below the floating bar's
        // reserved region. Both edges are still named, still required, and
        // still re-asserted on every resize; see
        // `reassertBodyContainerWidthTie()` for why a declared `==` is not by
        // itself enough.
        bodyLeadingConstraint = bodyContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        bodyTrailingConstraint = bodyContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor)

        // The session strip sits between the floating bar and the body, at the
        // bar's own side margins so the two read as one piece of chrome. It is
        // a sibling here rather than a second row inside
        // `DaylightBarController` because the vertical stack above the body is
        // this controller's own decision, and that controller's geometry
        // (`reservedTopHeight`, its two independently-anchored constraint
        // chains, B4's pill-label priority band) is measured and self-tested
        // as-is.
        root.addSubview(sessionStrip)
        sessionStrip.onSelect = { [weak self] id in self?.switchToSession(hostID: id) }
        sessionStrip.onClose = { [weak self] id in self?.confirmEndSession(hostID: id) }
        sessionStrip.onAddRequested = { [weak self] in self?.show(.hosts) }
        sessionStripHeightConstraint = sessionStrip.heightAnchor.constraint(equalToConstant: 0)
        bodyTopConstraint = bodyContainer.topAnchor.constraint(
            equalTo: root.topAnchor, constant: DaylightBarController.reservedTopHeight)

        NSLayoutConstraint.activate([
            bar.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.view.topAnchor.constraint(equalTo: root.topAnchor),

            sessionStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sessionStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sessionStrip.topAnchor.constraint(
                equalTo: root.topAnchor,
                constant: DaylightBarController.topMargin + DaylightBarController.height
                    + SessionStripView.gapBelowBar),
            sessionStripHeightConstraint,

            bodyLeadingConstraint,
            bodyTrailingConstraint,
            bodyTopConstraint,
            bodyContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // `fm/grandline-live-gap-rootcause-scout`: a real, live-captured
        // instance of this app showed `bodyContainer` (and every destination
        // mounted inside it) frozen at a width matching the *screen's* width
        // minus the rail - 1428pt, i.e. `1512 - 84` - while the window's
        // real, current frame was only 1033pt wide. `root` (this window's
        // own `contentView`) tracked the real window width correctly the
        // whole time (contentView's frame is kept in sync with the window's
        // content rect unconditionally by the OS, independent of Auto
        // Layout), so the tie above (`bodyTrailingConstraint`, a required
        // `==` to `root.trailingAnchor`) was declared correctly - the bug is
        // that nothing re-asserts it live. `main.swift`'s launch sequence
        // resizes this same window twice before it's ever shown
        // (`setFrame(defaultWindowFrame(), display: false)`, screen-sized,
        // then `setFrameAutosaveName` silently restoring the captain's own
        // smaller saved frame on top of it) with `display: false` both
        // times, and neither `ToolsController`'s own grid nor this window
        // has any other resize-driven correctness check the way
        // `ToolsController.containerWidthMayHaveChanged`/`SettingsController`
        // already do for their own content (see AGENTS.md) - `bodyContainer`
        // was the one major structural container with *no* such defensive
        // re-derivation at all. `reassertBodyContainerWidthTie()` closes
        // that gap: called once here (covering the window's still-off-screen
        // launch-time resizes above) and on every subsequent
        // `NSWindow.didResizeNotification`, so a stale/never-relaid-out
        // frame - or, per AGENTS.md gotcha (13)'s own documented class of
        // required-constraint conflict, a tie that AppKit silently
        // deactivated after losing to some other required constraint deep in
        // a (possibly hidden - gotcha (11)) destination view - can't survive
        // past the very next resize.
        //
        // **"Past the very next resize" was itself the defect**, and
        // `fm/grand-line-body-width-selfheal-layout-fix` closed it: the
        // repair also rides every layout pass now (see `root.onLayout`
        // above). These two remain as belt-and-braces - the launch call
        // covers the window's still-off-screen launch-time resizes, and a
        // resize can genuinely occur without a layout pass following it.
        reassertBodyContainerWidthTie()
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? NSWindow) === self.view.window else { return }
            self.reassertBodyContainerWidthTie()
        }

        hostsPanel.onAddOrEdit = { [weak self] host in self?.onPresentHostEditor?(host) }
        // cockpit-bootstrap-dotfiles: every command the Bootstrap page can run
        // that touches `darwin-rebuild switch` (needs an interactive `sudo`
        // TTY) opens as a real tab in the shared Firstmate console rather
        // than a silent background process - see `runInConsole` below.
        bootstrap.onRunCommand = { [weak self] label, command in self?.runInConsole(label: label, command: command) }
        // cockpit-bootstrap-full-setup: the "Run full setup" sequencer needs
        // to know a step's Console command actually finished (not a fixed
        // timer) before starting the next one - same tab, same command
        // string, just with a completion callback threaded through.
        bootstrap.onRunCommandTracked = { [weak self] label, command, completion in
            self?.runInConsole(label: label, command: command, completion: completion)
        }
        // fm/grandline-automation-pipeline: the automation pipeline's own
        // dotfiles step needs the exact same real Console-tab/completion
        // wiring as Bootstrap's - it runs the identical clone/rebuild command
        // (`DotfilesRunCommand`, shared by both pages).
        automation.onRunCommandTracked = { [weak self] label, command, completion in
            self?.runInConsole(label: label, command: command, completion: completion)
        }
        // cockpit-bootstrap-software: a `.notInstalled` row on the Updates
        // page no longer installs inline - it links to the Bootstrap page's
        // own Software checklist card instead (same catalog, same install
        // action, just relocated).
        updates.onNavigateToBootstrap = { [weak self] in self?.show(.bootstrap) }
        // fm/grandline-overview-drop-duplicate-pr-list: Overview's own
        // itemized "Ready to merge" list was removed as a duplicate of
        // `.review`'s - the stat tile that's left jumps straight there.
        overview.onNavigateToReview = { [weak self] in self?.show(.review) }

        // `fm/grandline-k8s-cluster-tail`: everything the `.kubernetes`
        // destination needs from the shell, as closures. Forward-don't-own -
        // that page knows nothing about `hostConsoles` or `ConsoleController`,
        // and this controller knows nothing about pods.
        kubernetes.configure(access: KubeSessionAccess(
            tabs: { [weak self] hostID in self?.hostConsoles[hostID]?.kubeFeedTabs() ?? [] },
            duplicateTabForFeed: { [weak self] hostID in self?.hostConsoles[hostID]?.duplicateTabForKubeFeed() },
            isTabBusyElsewhere: { [weak self] hostID, tabID in
                self?.hostConsoles[hostID]?.isTabBusyForKubeFeed(tabID) ?? false
            },
            revealHost: { [weak self] hostID in self?.switchToSession(hostID: hostID) },
            openHosts: { [weak self] in self?.show(.hosts) }))
        // The reverse direction of that same guard (full-app audit, finding
        // 4.1). `isTabBusyElsewhere` above lets the Kubernetes feed bridge see
        // the two console-side bridges; this lets them see it. Both halves are
        // wired here because this is the only object that holds both a
        // `ConsoleController` and the `.kubernetes` destination - neither of
        // them knows the other exists, and neither should.
        console.isKubernetesFeedBridgeBusy = { [weak self] tabID in
            self?.kubernetes.isFeedBridgeBusy(onTab: tabID) ?? false
        }
        // GL-31: Overview's unconfigured banner leads straight into the
        // Bootstrap stepper, which is where firstmate home is actually set.
        overview.onNavigateToSetup = { [weak self] in self?.show(.bootstrap) }
        // F12: the morning briefing's clause deep links. `show(_:)` and
        // `openShiftTask(id:)` are both already the one way this app navigates
        // to a destination / opens a task, so these are pass-throughs rather
        // than new behaviour.
        overview.onNavigateToDestination = { [weak self] dest in self?.show(dest) }
        overview.onOpenShiftTask = { [weak self] id in self?.openShiftTask(id: id) }
        // F20's own page: the same two pass-throughs. No drill-subtitle
        // wiring - `fm/grandline-overview-layout-fix-gmail-settings` made
        // Overview a top-level page, which has no drill header to update.
        dailyOverview.onNavigateToDestination = { [weak self] dest in self?.show(dest) }
        dailyOverview.onOpenShiftTask = { [weak self] id in self?.openShiftTask(id: id) }
        // Straw Hat phase 3 (M3.2): the crew's two navigation handoffs. Both
        // are pass-throughs into navigation this object already owns - a
        // handoff writes nothing, which is what lets its link row run on a
        // single click with no confirm card in front of it.
        strawHat.onOpenDestination = { [weak self] dest, hint in
            self?.openDestinationForCrew(dest, hint: hint)
        }
        strawHat.onOpenSRELead = { [weak self] hint in
            self?.openSRELeadForCrew(hostHint: hint)
                ?? "I couldn't reach your host pages from here."
        }
        strawHat.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // Review #3 §7: the fleet dashboard's "Ask your crew" header button.
        // Plain navigation - the composer it replaced is gone, and the crew
        // page's own composer is the one place a message to them is written.
        overview.onOpenCrew = { [weak self] in self?.show(.strawHat) }
        // The Overview card's own summary line - see
        // `StrawHatCanvasState`. Pushed rather than polled, the
        // same shape `FleetController.onSnapshotChanged` already uses for the
        // Fleet card.
        strawHat.onCanvasStateChanged = { [weak self] in
            guard let self else { return }
            self.homeCanvas.applyStrawHat(self.strawHat.canvasState)
        }
        // cockpit-settings-sudo-touchid: Settings' "Touch ID for sudo" row
        // runs `sudo av harden sudo`, which needs a real interactive `sudo`
        // prompt exactly like Bootstrap's provisioning actions - same
        // one-shot Console command-tab mechanism, just reached from Settings
        // instead.
        // Settings' own sidebar moves the header's subtitle - it names the
        // selected category, the way the reference mockup's "Settings /
        // Shortcuts & Siri" does.
        settings.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // `fm/grandline-overview-layout-fix-gmail-settings`: a Google account
        // connected (or disconnected, or its calendar switch flipped) changes
        // what the daily review's calendar column can read, on both hosts.
        // Pushed from Settings rather than polled, and the pages re-read the
        // source rather than being handed one.
        settings.onGoogleAccountsChanged = { [weak self] in
            guard let self else { return }
            self.dailyOverview.renderDailyReviewIfMounted()
            self.overview.renderDailyReviewIfMounted()
        }
        settings.onRunCommand = { [weak self] label, command in self?.runInConsole(label: label, command: command) }
        settings.onRunCommandTracked = { [weak self] label, command, completion in
            self?.runInConsole(label: label, command: command, completion: completion)
        }
        // fm/grandline-vault-tab: `av save`/`av inject` both need a real
        // interactive terminal (see `VaultController`'s header) - same
        // one-shot Console command-tab mechanism as every other
        // interactive/sudo action in this app.
        vault.onRunCommand = { [weak self] label, command in self?.runInConsole(label: label, command: command) }
        vault.onRunCommandTracked = { [weak self] label, command, completion in
            self?.runInConsole(label: label, command: command, completion: completion)
        }
        // fm/grandline-devops-command-library-phase2: the Command Library's
        // "Send to Terminal" types straight into whichever console tab is
        // currently in front - not a new one-shot command tab (`runInConsole`
        // above), the exact same "type this into the active tab" behavior
        // Snippets' own "Run" already uses.
        commandLibrary.onSendCommandToTerminal = { [weak self] text in self?.console.sendCommandLibraryTextToActiveTab(text) }
        // F9 (v1): straight up to the app delegate - see `onSendCommandToHosts`.
        commandLibrary.onSendCommandToHosts = { [weak self] command, values, generated in
            self?.onSendCommandToHosts?(command, values, generated)
        }

        // `fm/grandline-log-analyzer-build`: the Log Analyzer forwards the
        // same two things Shift's Command Library already does - "run this
        // command" goes to whichever console tab is in front, and a runbook
        // or postmortem it just wrote opens in Docs. It owns neither.
        logAnalyzer.onSendCommandToTerminal = { [weak self] text in
            self?.console.sendCommandLibraryTextToActiveTab(text)
        }
        logAnalyzer.onOpenRunbook = { [weak self] id in self?.openRunbook(id: id) }
        // `fm/grandline-docs-split-runbooks-postmortems`: `createIncident()`
        // used to route its saved-postmortem confirmation through
        // `onOpenRunbook` too, which opened it as a runbook - a postmortem id
        // is never in `listRunbooks()`, so that silently no-opped. Fixed by
        // giving it its own closure, wired to the postmortem destination.
        logAnalyzer.onOpenPostmortem = { [weak self] id in self?.openPostmortem(id: id) }
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
        logAnalyzer.onOpenConsole = { [weak self] in self?.show(.console) }

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
            NotificationSources.setFleetDecisions(count: count) { self?.show(.overview) }
        }
        // The canvas's Fleet and Merge queue modules, fed from Overview's own
        // refresh rather than a fetch of their own - see
        // `FleetController.onSnapshotChanged`.
        overview.onQuotaChanged = { [weak self] result in
            self?.homeCanvas.applyQuota(result)
        }
        overview.onSnapshotChanged = { [weak self] snapshot, prs, failure in
            self?.homeCanvas.applyFleet(snapshot: snapshot, mergedPRs: prs, prFetchFailure: failure)
        }
        // GL-11/GL-30: the two failure signals (a background service failing
        // repeatedly, a save that did not reach disk) are raised from
        // background queues that know nothing about destinations, so they get
        // their navigation from here - the same forward-don't-own split every
        // other signal in `NotificationSources` uses. Set once; both entries
        // point at `.health` - fm/grandline-health-sidebar-move gave the
        // Health card its own rail destination, off the Settings page.
        NotificationSources.navigateToHealth = { [weak self] in self?.show(.health) }

        review.onReadyToMergeCountChanged = { [weak self] count in
            NotificationSources.setPRReady(count: count) { self?.show(.review) }
        }
        // F4: the OS-banner half of the same signal. The in-app entry above is
        // a count; this is the per-PR post that carries Merge / Open PR, and it
        // needs the rows themselves (URL, task id, checks) rather than a count.
        review.onPRsChanged = { prs in FleetNotifier.shared.reconcilePRs(prs) }
        // Daylight §6.4: every migrated drill page carries live numbers in the
        // header's subtitle, and the header is the shell's. They ask; nothing
        // writes into it but `applyDrillHeader`/`refreshDrillHeaderSubtitle`.

        review.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        shift.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // The Tasks column's footer links, forwarded rather than owned - that
        // page knows nothing about the shell or the palette
        // (`onSearchTapped`'s own convention).
        shift.onNavigateToDestination = { [weak self] dest in self?.show(dest) }
        shift.onOpenCommandPalette = { [weak self] in self?.onSearchTapped?() }
        hostsPanel.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // Hosts is the first migrated page whose *actions* change while it is
        // on screen: §6.4's cluster carries the add action for the tab that is
        // showing, and the three tabs add three different records. Same shape
        // as the subtitle callback - the page says "re-ask me", the shell owns
        // the header.
        hostsPanel.onDrillActionsChanged = { [weak self] in self?.refreshDrillHeaderActions() }

        // `fm/grandline-session-switcher`: the Hosts list reads liveness from
        // the same registry the strip does, through a closure, so that page
        // never learns what a `ConsoleController` is - the same
        // forward-don't-own shape as every other `hostsPanel` hook here.
        hostsPanel.liveSession = { [weak self] hostID in self?.sessions.session(for: hostID) }
        hostsPanel.onSwitchToSession = { [weak self] hostID in self?.switchToSession(hostID: hostID) }
        hostsPanel.onEndSession = { [weak self] hostID in self?.confirmEndSession(hostID: hostID) }

        // One observer turns every registry change into the two things that
        // have to follow it: the strip re-renders (and appears/disappears),
        // and the Hosts list's live rows are rebuilt if it is showing. Fired
        // synchronously at registration, which for an empty registry is
        // exactly the collapsed strip this wants at launch.
        sessionsToken = sessions.observe { [weak self] registry in
            self?.applySessionRegistry(registry)
        }
        health.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // UI12: both pages' empty states now offer a way out of themselves.
        health.onNavigateToDestination = { [weak self] dest in self?.show(dest) }
        console.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // The four Engineering setup pages, each wired exactly like every
        // other conforming destination since
        // `fm/grandline-separate-setup-destinations`. They used to route
        // through `SetupContainerController`'s own per-tab forwarding, which
        // also had to fire on a tab switch because the line was per-tab; each
        // page owns its own header line now, so a page's own numbers moving is
        // the only thing that can change it.
        updates.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        bootstrap.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        automation.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        githubSync.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        schedules.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // `fm/grand-line-schedules-page-redesign`: a needs-you row's "Review"
        // button hands off to the page that owns that action
        // (`ScheduledActionKind.reviewDestination`). Same seam as Overview's.
        schedules.onNavigateToDestination = { [weak self] dest in self?.show(dest) }
        logAnalyzer.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        vault.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // Poneglyph is its own destination now
        // (`fm/poneglyph-own-destination-and-strawhat-toolbar-shortcut`), so
        // it wires this exactly like every other conforming destination
        // rather than through `SetupContainerController`'s own per-tab
        // forwarding.
        poneglyph.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // Docs' subtitle still tracks the Playbook's own real sync state; its
        // action cluster no longer changes while it's on screen now that the
        // runbook editor (and the per-tab switch that used to empty the
        // cluster for it) moved to `.runbooks`.
        docs.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        whiteboard.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        codePreview.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        commandLibrary.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // Runbooks inherited Docs' old per-editor-state cluster: "New
        // Runbook" beside a form already creating one is a second, competing
        // action, so its cluster empties while the editor is open.
        runbooks.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        runbooks.onDrillActionsChanged = { [weak self] in self?.refreshDrillHeaderActions() }
        readingList.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        readingList.onDrillActionsChanged = { [weak self] in self?.refreshDrillHeaderActions() }
        notebook.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        notebook.onDrillActionsChanged = { [weak self] in self?.refreshDrillHeaderActions() }
        postmortems.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        postmortems.onNavigateToDestination = { [weak self] dest in self?.show(dest) }
        dictation.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // Tools' subtitle counts open tool tabs, which the captain can change
        // without leaving the page. Like every line above it, this is safe
        // despite the page being lazily mounted (GL-37): assigning a closure
        // never touches the controller's views, so it cannot force `loadView`
        // to run early. Settings needs no callback - its subtitle is static.
        tools.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
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
        homeCanvas.onOpenDestination = { [weak self] dest in self?.show(dest) }
        homeCanvas.onOpenShiftTask = { [weak self] id in self?.openShiftTask(id: id) }
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
            return Set(self.hostConsoles.filter { $0.value.hasLiveSession }.keys)
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
            let store = self.poneglyph.credentialStore
            return (store.loadState(), store.isUnlocked, store.isUnlocked ? store.credentials.count : nil)
        }

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
        if FirstmateHome.homeOk() {
            show(.homeCanvas)
        } else {
            AppLog.lifecycle.info("firstmate home not configured - opening Setup instead of the home canvas")
            show(.bootstrap)
        }

        // Added last (and therefore topmost in z-order) so it covers the
        // rail as well as the body area - no fleet/secrets/hosts content, or
        // the rail itself, should be visible or reachable while locked.
        addChild(lockScreen)
        root.addSubview(lockScreen.view)
        lockScreen.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            lockScreen.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            lockScreen.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            lockScreen.view.topAnchor.constraint(equalTo: root.topAnchor),
            lockScreen.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        lockScreen.view.isHidden = true
        lockScreen.onAttempt = { typed, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = VaultSource.verifyAppPassword(typed)
                DispatchQueue.main.async { completion(ok) }
            }
        }
        // Fires only once the success animation has actually played out
        // (see `LockScreenController.playUnlockSuccessAnimation`) - hiding
        // the overlay from `onAttempt`'s own completion instead would cut
        // that animation off before it's visible at all.
        lockScreen.onUnlockAnimationFinished = { [weak self] in
            self?.hideLock()
            self?.onUnlocked?()
        }
        // fm/grandline-vault-bootstrap-fix: "Install Automic Vault" on the
        // `.avUnavailable` state - a plain Homebrew-cask install
        // (`VaultSource.updateInstall()`, the same mechanism the
        // Updates/Vault pages already use for this catalog entry), so it
        // needs no prior unlock and is safe to trigger straight from here.
        lockScreen.onInstallAutomicVault = { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = VaultSource.updateInstall()
                DispatchQueue.main.async {
                    let message = outcome.ok
                        ? "Installed. Set a password with \u{201c}av save GRANDLINE_APP_PASSWORD\u{201d}, then relaunch Manjesh Grand Line."
                        : "Install failed: \(outcome.detail)"
                    completion(outcome.ok, message)
                }
            }
        }
    }

    // MARK: App-level password lock (fm/grandline-app-lock)

    /// Shows the lock overlay for `reason`, re-checking whether
    /// `GRANDLINE_APP_PASSWORD` is actually configured in Automic Vault
    /// (never cached - the captain could set it between one lock and the
    /// next) before deciding which of the lock screen's two states to show.
    func showLock(reason: AppLockReason) {
        // Audit #2 §5.1(b): before `setLocked(true)` below, because a console
        // page's incident card is an `NSPopover` and the gate's generic
        // secondary-window sweep can only `orderOut` its window - which would
        // leave `NSPopover.isShown` believing it is still up, so the next
        // `showIncidentCard()` would skip its own `show()` and the card would
        // never come back. Closing it properly first means that sweep finds
        // nothing to do; the registration in `buildIncidentCard` stays as the
        // backstop for any future path that opens one without coming through
        // here.
        forEachConsole { $0.closeLockSensitiveSurfaces() }
        // `fm/implement-grand-line-secrets-vault-poneg-ad`: the credential
        // vault's own gate is independent of this one (the captain's decision:
        // two separate passwords), but the app locking means he has walked
        // away - so an unlocked vault behind the overlay must not still be
        // unlocked when he comes back. This is a *view-side* re-lock rather
        // than an `AppLockedSurface` case: the vault page (now `poneglyph`,
        // labeled "Poneglyph" - see `VaultController.swift`'s header for why)
        // is a subview of this window, so the overlay already blocks reaching
        // it; what has to happen is dropping the derived key and every
        // decrypted value from memory.
        poneglyph.lockForAppLock()
        lockScreen.view.isHidden = false
        // E4: re-add what `hideLock` removed. A re-lock does not necessarily
        // re-lay-out an already-sized overlay, so this cannot be left to
        // `viewDidLayout`'s own call.
        lockScreen.restartAnimationsIfNeeded()
        // GL-09: the overlay only covers this window. Everything that lives
        // outside it - the menu-bar status item, ⌥Space quick capture, the
        // dictation hotkey, an already-open Host Editor - consults
        // `AppLockGate`, and this is the one place it is set. Set *before*
        // anything else in this method, so there is no window in which the
        // overlay is up but a global hotkey still fires.
        AppLockGate.shared.setLocked(true)
        onLockStateChanged?(true)
        // `fm/grandline-lock-and-rail-fixes` used this moment to make the
        // rail's sailboat mark inert. The rail is gone (Daylight §5.1) and the
        // bar's logo tile is a static gradient with no animation to stop, so
        // there is nothing left to do here - the lock overlay covers the whole
        // window including the bar, which was always the real guarantee.
        // Optimistic default so the overlay never shows a blank subtitle for
        // the fraction of a second the background `av list` check takes -
        // corrected below once that check actually resolves.
        let optimisticSubtitle = reason == .sessionExpired
            ? "Your session expired - please log in again."
            : "Manjesh Grand Line is locked."
        lockScreen.apply(.locked(subtitle: optimisticSubtitle))
        lockScreen.focusPasswordField()
        // fm/grandline-vault-bootstrap-fix: proactively try to start Automic
        // Vault's own background approval service before the very first
        // check - avoids ever hitting the "service not running" state below
        // on an ordinary launch where the captain just hasn't opened the
        // menu-bar app yet (e.g. right after a reboot). Fire-and-forget on
        // the same background queue as the check that follows.
        DispatchQueue.global(qos: .userInitiated).async {
            VaultSource.ensureServiceRunning()
        }
        checkAppPasswordAvailability(reason: reason)
    }

    /// Re-checks `VaultSource.checkAppPasswordConfigured()` and updates the
    /// lock screen's content state. When the service genuinely isn't running
    /// yet (`.serviceNotRunning`), retries on a short timer rather than
    /// immediately settling on a message - `ensureServiceRunning()` above
    /// usually resolves this before the first attempt even lands; this is
    /// the fallback for a slower start (e.g. right after a reboot).
    private func checkAppPasswordAvailability(reason: AppLockReason) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let availability = VaultSource.checkAppPasswordConfigured()
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyPasswordAvailability(availability, reason: reason)
            }
        }
    }

    private func applyPasswordAvailability(_ availability: VaultSource.AppPasswordAvailability, reason: AppLockReason) {
        switch availability {
        case .configured:
            let subtitle = reason == .sessionExpired
                ? "Your session expired - please log in again."
                : "Manjesh Grand Line is locked."
            lockScreen.apply(.locked(subtitle: subtitle))
            lockScreen.focusPasswordField()
        case .notConfigured:
            lockScreen.apply(.noPasswordConfigured)
            lockScreen.focusPasswordField()
        case .avUnavailable:
            lockScreen.apply(.avUnavailable)
        case .serviceNotRunning:
            lockScreen.apply(.serviceNotRunning)
            scheduleAppPasswordAvailabilityRetry(reason: reason)
        case .transientFailure:
            // Any `av list` failure/timeout that isn't the specific
            // `.serviceNotRunning` marker text (fm/grandline-vault-wake-
            // recheck-fix) - live-confirmed that a suspended/unresponsive
            // approval helper (e.g. right after a long sleep/wake) can make
            // `av list` fail or hang in a way that previously fell through
            // to a hard, misleading `.avUnavailable` state with no retry at
            // all, even though `av` is genuinely installed and the
            // password secret genuinely exists. Retried on the same cadence
            // as `.serviceNotRunning` below.
            lockScreen.apply(.transientFailure)
            scheduleAppPasswordAvailabilityRetry(reason: reason)
        }
    }

    /// Retry every 1.5s indefinitely while the lock screen is up - there's
    /// nothing else useful to show, and the retry itself is a cheap
    /// subprocess call, not a real cost. Shared by `.serviceNotRunning` and
    /// `.transientFailure` above.
    private func scheduleAppPasswordAvailabilityRetry(reason: AppLockReason) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.lockScreen.view.isHidden else { return }
            self.checkAppPasswordAvailability(reason: reason)
        }
    }

    private func hideLock() {
        lockScreen.view.isHidden = true
        // E4: the scene's three infinite animations used to stay attached to
        // hidden layers for the rest of the session. `isHidden` alone does not
        // stop a `CAAnimation`.
        lockScreen.stopAnimations()
        AppLockGate.shared.setLocked(false)
        onLockStateChanged?(false)
        // Audit #2 §5.1: after `setLocked(false)`, so the work each console
        // replays actually passes its own gate. Only a page that appeared
        // while locked has anything owed - see
        // `ConsoleController.appearanceWorkDeferredByLock`.
        forEachConsole { $0.resumeAfterUnlock() }
    }

    /// The shared Firstmate console plus every dedicated host page, in one
    /// place, so a lock-state change reaches all of them without either half
    /// being forgotten.
    ///
    /// A push from here rather than each console registering with
    /// `AppLockGate.observe`: that API has no unregister, and a per-host
    /// `ConsoleController` is deallocated when its host is deleted - the same
    /// dead-closure leak this app already keeps theme/font observation
    /// *tokens* to avoid.
    private func forEachConsole(_ body: (ConsoleController) -> Void) {
        body(console)
        for controller in hostConsoles.values { body(controller) }
    }

    /// Open `command` as a new tab in the shared Firstmate console and bring
    /// Console forward, so its output (and any `sudo` prompt) is visible
    /// immediately - the one path every Bootstrap-page action that can invoke
    /// `darwin-rebuild switch` uses (`bootstrap.sh`, `rebuild.sh`, the initial
    /// clone).
    func runInConsole(label: String, command: String, completion: ((Bool) -> Void)? = nil) {
        console.openCommandTab(label: label, command: command) { exitCode in completion?(exitCode == 0) }
        show(.console)
    }

    /// Pin a destination view to fill `bodyContainer` below the top bar -
    /// the same anchors every fixed destination and every host page use.
    private func embed(_ destinationView: NSView) {
        destinationView.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(destinationView)
        let pins = [
            destinationView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            destinationView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            // A2: the drill header no longer sits between the bar and the
            // page, so a destination starts at the body container's own top.
            destinationView.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            destinationView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(pins)
        destinationPins[ObjectIdentifier(destinationView)] = pins
    }

    /// The four pins `embed` put on each destination view, so
    /// `setDestinationVisible` can take a hidden page out of the window's
    /// constraint graph without taking it out of the view hierarchy.
    private var destinationPins: [ObjectIdentifier: [NSLayoutConstraint]] = [:]

    /// Show or hide one destination, and attach or detach it from the
    /// window's constraint graph to match (full review #3's PF1).
    ///
    /// ## Why this is not just `isHidden`
    ///
    /// **A hidden `NSView` still participates fully in Auto Layout** -
    /// AGENTS.md gotcha (11) says so in the other direction, and it is what
    /// makes GL-37's "mounted, only ever hidden" expensive rather than free.
    /// Every mounted destination is pinned to `bodyContainer`, so all ~27 of
    /// them are one required-constraint chain inside the window, and AppKit
    /// walks that entire chain every time it has to re-derive
    /// `minFullScreenContentSize` for a full-screen-capable window.
    ///
    /// Measured with a standalone stock-AppKit probe (5s `sample` at 1ms,
    /// main-thread samples in
    /// `_doUpdateTilingConstraintsImmediately -> minFullScreenContentSize ->
    /// NSISEngine`), one mounted-destination count per row, with a label's
    /// text changing 20x/second as the invalidation source:
    ///
    ///     1 mounted     16 samples    0.4% of the main thread
    ///     3 mounted    134            3.1%
    ///     7 mounted    357            8.3%
    ///    14 mounted    973           22.7%
    ///    27 mounted   1877           43.4%
    ///
    /// Near-linear in the number of mounted destinations, and the captain's
    /// own running instance measured 1090 samples (26.8% of its main thread,
    /// 76% of everything it was doing other than blocking) - squarely on that
    /// curve. A settled graph of any size costs **zero**: this is not stock
    /// AppKit idle work, it is the re-solve that any invalidation triggers.
    ///
    /// Deactivating a hidden page's four pins leaves its subtree with no
    /// required path to the window, so the derivation skips it. Same probe,
    /// 27 mounted, same 20Hz invalidation: **1777 samples -> 34**, i.e.
    /// 41.2% of the main thread -> 0.8%.
    ///
    /// ## What this deliberately does not do
    ///
    /// Nothing is torn down. GL-37's "a mounted slot is only ever hidden,
    /// never torn down" holds exactly as before - the controller, its view
    /// hierarchy, its scroll position, its in-flight fetches and any live ssh
    /// session are all untouched. This changes only whether a *hidden* page's
    /// geometry is something Auto Layout still has to solve for, which by
    /// definition nothing can observe while it is hidden. Unmounting cold
    /// destinations - GL-37's other half, and what the review reached for -
    /// would buy the same thing and cost a great deal more.
    private func setDestinationVisible(_ destinationView: NSView, _ visible: Bool) {
        guard let pins = destinationPins[ObjectIdentifier(destinationView)] else {
            // A view this controller did not embed. Honour the visibility
            // change rather than silently ignoring it - the detach is an
            // optimisation, and it must never be the reason a page fails to
            // appear.
            destinationView.isHidden = !visible
            return
        }
        if visible {
            // Re-pin *before* unhiding, so the page is never on screen for a
            // pass with no constraints tying it to the container - which is
            // the one way this could read as a layout bug rather than as a
            // saving.
            for pin in pins where !pin.isActive { pin.isActive = true }
            destinationView.isHidden = false
            destinationView.needsLayout = true
        } else {
            destinationView.isHidden = true
            for pin in pins where pin.isActive { pin.isActive = false }
        }
    }

    /// `fm/grandline-live-gap-rootcause-scout`: re-derives `bodyContainer`'s
    /// width from `root`'s (this window's `contentView`'s) actual current
    /// bounds, on demand - called once at launch (from `loadView`, before the
    /// window is ever shown) and again on every `NSWindow.didResizeNotification`
    /// for this window. Two independent, cheap safeguards, not one:
    ///   1. Reactivate `bodyLeadingConstraint`/`bodyTrailingConstraint` if
    ///      either was ever deactivated - required constraints that lose a
    ///      genuine conflict against some other required constraint
    ///      elsewhere (possibly deep in a hidden destination view - see
    ///      AGENTS.md gotcha (11)) get silently disabled by AppKit and do
    ///      not reactivate themselves once the conflict is gone.
    ///   2. Force a real `layoutSubtreeIfNeeded()` - a resize that happens
    ///      with `display: false` (as `main.swift`'s launch sequence does,
    ///      twice, before the window is ever shown) only marks the affected
    ///      views `needsLayout`; it does not itself flush that into an
    ///      updated `.frame` the way a direct `.frame` read after this call
    ///      does.
    ///
    /// GL-20: step 2 used to run unconditionally on every resize *frame*, which
    /// resolves every mounted destination's whole view tree plus every per-host
    /// console - defeating the visibility gates those child controllers each
    /// added for exactly this reason (see `ToolsController`'s and
    /// `SettingsController`'s own measured regressions).
    ///
    /// The gate is a cheap staleness check rather than a debounce. `root` is
    /// this window's `contentView`, whose frame the OS keeps in sync with the
    /// window unconditionally (confirmed live by the scout task), so comparing
    /// `bodyContainer`'s *current* frame against what the constraints say it
    /// should be costs two frame reads and no layout. Only when those disagree
    /// - or when a constraint was found deactivated - does the expensive
    /// resolve run. A debounce was tried first and is wrong here: the whole
    /// point of #231's fix is that the frame is correct *immediately* after a
    /// resize, and `AppShellBodyWidthSelfTest` asserts exactly that
    /// synchronously.
    /// - Parameter insideLayoutPass: `true` only from
    ///   `ChromeFusionRootView.layout()`. AppKit forbids a nested
    ///   `layoutSubtreeIfNeeded()` while a view is already being laid out -
    ///   "It's not legal to call -layoutSubtreeIfNeeded on a view which is
    ///   already being laid out. If you are implementing the view's -layout
    ///   method, you can call -[super layout] instead." - and on macOS 14 that
    ///   is a trap, not a log: it crashed `AppShellBodyWidthSelfTest` with
    ///   `Trace/BPT trap: 5` on CI. It needs no nested pass either, because it
    ///   is already inside one: marking the view dirty schedules the very next
    ///   pass, which is where the repair lands. Only the callers that are *not*
    ///   in a layout pass (launch, and the resize notification) force one.
    private func reassertBodyContainerWidthTie(insideLayoutPass: Bool = false) {
        // `fm/grand-line-body-width-selfheal-layout-fix`: this also runs from
        // `ChromeFusionRootView.layout()`. It used to force a layout pass from
        // there too, which re-entered `layout()` -> `onLayout` -> here; that is
        // what `insideLayoutPass` (above) now stops, because AppKit traps on a
        // nested pass. This guard still covers the callers that *do* force one
        // (launch, and the resize notification): a repair re-enters, and that
        // is bounded on its own whenever it succeeds (the second entry finds
        // the tie active and the width correct, and returns), and **measured:
        // removing this guard does not hang or
        // recurse in `AppShellBodyWidthSelfTest`.** It is kept because the
        // one case it protects is exactly the case this whole repair exists
        // for: a required-constraint conflict the resolve cannot actually
        // satisfy leaves the width stale after the inner pass, so an
        // unguarded second entry would force another pass, and another -
        // spinning the main thread rather than merely leaving a stale frame.
        // A visibly-wrong window is a far better failure than a hung app.
        //
        // The traffic-light reposition beside it needs no equivalent: it only
        // writes frame origins and never forces layout. One repair per pass
        // loses nothing - anything still wrong afterwards is caught by the
        // very next pass.
        guard !isReassertingBodyContainerWidthTie else { return }
        var needsLayout = false
        if let bodyLeadingConstraint, !bodyLeadingConstraint.isActive {
            bodyLeadingConstraint.isActive = true
            needsLayout = true
            AppLog.ui.error("bodyContainer leading tie had been deactivated by AppKit - reactivated")
        }
        if let bodyTrailingConstraint, !bodyTrailingConstraint.isActive {
            bodyTrailingConstraint.isActive = true
            needsLayout = true
            AppLog.ui.error("bodyContainer trailing tie had been deactivated by AppKit - reactivated")
        }
        // Checked *before* the body-vs-root test below, because when `root`
        // itself has drifted that test is blind: `bodyContainer` correctly
        // matches a `root` that is the wrong size. See
        // `windowContentWidthIsStale()`.
        if windowContentWidthIsStale() {
            resyncRootWidthToWindow()
            needsLayout = true
        }
        if !needsLayout, bodyContainerWidthIsStale() {
            needsLayout = true
        }
        // The **third** reference, and review #3's B1.
        //
        // The two above compare `bodyContainer` to `root` and `root` to the
        // window. Both can agree while the *page* is still laid out narrow:
        // every destination is pinned leading and trailing to `bodyContainer`
        // (see `embed`), so a showing destination whose frame is narrower than
        // that container is a broken tie on its own - and neither existing
        // test can see it, because both of their operands are correct.
        //
        // That is the state review #3's sweep caught: from `.schedules`
        // onward, ten destinations rendered into **973.5pt** inside a 1512pt
        // window - 973.5 being the Log Analyzer's own `fittingSize.width`, a
        // page shown ten destinations earlier, i.e. one page's preferred width
        // adopted by the rest. It did not reproduce on a second run with the
        // same binary, which is what a tie that loses a resolve and is never
        // re-derived looks like from outside, and it matches the captain's own
        // "sometimes, cleared by a resize or a restart".
        if !needsLayout, showingDestinationWidthIsStale() {
            needsLayout = true
        }
        guard needsLayout else {
            deferredRepairsSinceHealthy = 0
            return
        }
        isReassertingBodyContainerWidthTie = true
        defer { isReassertingBodyContainerWidthTie = false }
        // **`needsLayout = true` is load-bearing here, and this cost a real
        // regression before it was added.** `layoutSubtreeIfNeeded()` only
        // invokes `layout()` if something already marked the view dirty -
        // the same AppKit behaviour `ChromeFusionRootView`'s own title-KVO
        // note records. Reactivating a constraint does mark things dirty, so
        // this used to work by accident from the resize observer; once the
        // repair *also* runs from inside a layout pass, that earlier call
        // consumes the dirty flag and the observer's own call moments later
        // becomes a silent no-op, leaving the frame stale. Measured: without
        // this line `widthSelfHealsAfterATieIsSilentlyBroken` - which passed
        // before this task and exercises only the resize path - fails with
        // the body frozen at its pre-break 1512.
        view.needsLayout = true
        #if FM_SELFTESTS
        // Proves the guard below is genuinely reached - it was, 12 times in
        // `AppShellBodyWidthSelfTest` - so a check that the forcing count is
        // zero cannot pass just because nothing ever got here.
        if insideLayoutPass { AppShellController.repairsInsideALayoutPassForTests += 1 }
        #endif
        guard !insideLayoutPass else {
            // **`view.needsLayout = true` above is swallowed when it is set
            // from inside this view's own `layout()`, and that is measured,
            // not assumed.** A standalone probe that re-marks itself dirty
            // from inside `layout()` and asks for five further passes gets
            // **zero**, while the same mark made *outside* `layout()` is
            // honoured every time. So #412's "marking the view dirty
            // schedules the very next pass, which is where the repair lands"
            // is not true: from the layout-pass trigger - the only
            // *continuous* trigger this repair has - the flag is discarded
            // and nothing further happens, which left the repair effectively
            // back at its pre-#412 "can't survive past the very next resize"
            // behaviour for anything a constraint reactivation alone does not
            // cure.
            //
            // A nested `layoutSubtreeIfNeeded()` is not the answer (AppKit
            // forbids it, and traps on macOS 14 - see this method's own
            // `insideLayoutPass` note), so the repair is queued for the next
            // run loop turn instead, where forcing one is legal.
            scheduleDeferredRepair()
            return
        }
        #if FM_SELFTESTS
        // Unreachable by construction - the guard above returns first. Kept as
        // the sentinel `theWidthRepairNeverForcesANestedLayoutPass` asserts on:
        // without it that case's "stayed 0" assertion would be vacuous, and a
        // future refactor that moved or dropped the guard would go unnoticed.
        if insideLayoutPass { AppShellController.nestedLayoutForcingsForTests += 1 }
        #endif
        view.layoutSubtreeIfNeeded()
    }

    /// Run the repair again on the next run loop turn - i.e. once this layout
    /// pass has finished and forcing a fresh one is legal again.
    ///
    /// Bounded on purpose. If the drift is genuinely unfixable (a required
    /// constraint conflict the resolve cannot satisfy), an unbounded
    /// re-queue would spin the main thread at run loop cadence; the existing
    /// re-entrancy guard's own reasoning applies here verbatim - **a
    /// visibly-wrong window is a far better failure than a hung app.** The
    /// budget is reset every time the repair finds nothing wrong, so an app
    /// that is healthy between two drifts always gets its full allowance.
    private func scheduleDeferredRepair() {
        guard !pendingDeferredRepair else { return }
        guard deferredRepairsSinceHealthy < Self.maxDeferredRepairsSinceHealthy else { return }
        pendingDeferredRepair = true
        deferredRepairsSinceHealthy += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingDeferredRepair = false
            self.reassertBodyContainerWidthTie()
        }
    }

    /// Whether a deferred repair is already queued - one at a time.
    private var pendingDeferredRepair = false

    /// Consecutive deferred repairs since the last pass that found nothing
    /// wrong. See `scheduleDeferredRepair()` for why this is bounded.
    private var deferredRepairsSinceHealthy = 0
    private static let maxDeferredRepairsSinceHealthy = 4

    #if FM_SELFTESTS
    /// How many times the repair ran *from inside* `ChromeFusionRootView.layout()`.
    /// Non-zero is what stops the guard below passing vacuously.
    static var repairsInsideALayoutPassForTests = 0
    /// How many times it forced a nested `layoutSubtreeIfNeeded()` from inside a
    /// layout pass. Must stay 0 - AppKit traps on it (macOS 14).
    static var nestedLayoutForcingsForTests = 0
    #endif

    /// Re-entrancy guard for the above - see its own doc comment.
    private var isReassertingBodyContainerWidthTie = false

    /// `bodyContainer` spans from the rail's trailing edge to `root`'s trailing
    /// edge, so its correct width is exactly `root.bounds.width - rail width`.
    /// A half-point tolerance covers the non-integral widths AppKit produces on
    /// a Retina display.
    private func bodyContainerWidthIsStale() -> Bool {
        // Daylight Phase 2: no rail, so the body spans the full content width.
        let expected = view.bounds.width
        guard expected > 0 else { return false }
        return abs(bodyContainer.frame.width - expected) > 0.5
    }

    /// Is the destination currently on screen laid out narrower (or wider)
    /// than the container it is pinned to?
    ///
    /// Review #3's B1 - see the call site for the evidence. Logs the page's own
    /// `fittingSize.width` alongside the two frames, because that number is
    /// what identifies *which* page's preference was adopted: a live
    /// recurrence is then attributable from the log alone rather than needing
    /// a render sweep to work out where 973.5 came from.
    private func showingDestinationWidthIsStale() -> Bool {
        guard let destination = visibleDestinationView() else { return false }
        let expected = bodyContainer.bounds.width
        guard expected > 0, destination.frame.width > 0 else { return false }
        guard abs(destination.frame.width - expected) > 0.5 else { return false }
        AppLog.ui.error("""
            the showing destination is laid out at \(destination.frame.width, privacy: .public)pt             inside a \(expected, privacy: .public)pt body (its own fitting width is             \(destination.fittingSize.width, privacy: .public)) - re-deriving
            """)
        return true
    }

    /// The width `root` (this window's `contentView`) *should* have: the
    /// window's own content width.
    ///
    /// `fm/grand-line-window-glitch-fix`: `bodyContainerWidthIsStale()` above
    /// measures `bodyContainer` against `root`, on the assumption - stated in
    /// `reassertBodyContainerWidthTie`'s own doc comment, and inherited from
    /// the scout report that produced #412 - that "the OS keeps `contentView`
    /// in sync with the window unconditionally". **That assumption is false,
    /// and it is the whole reason the black-region glitch recurred after #412
    /// shipped.** Measured live on the captain's own running app: the window
    /// was 1512pt wide (its titlebar window reported exactly that) while its
    /// content window reported 1064pt, with the backing surface 1512pt and
    /// drawn only to 1063pt - 449pt of undrawn black. Reproduced here exactly:
    /// window 1512 / `contentView` 1064, at which point `bodyContainer` is
    /// *correctly* 1064 and `bodyContainerWidthIsStale()` answers **no**, so
    /// the repair returns having found nothing wrong. Ordinary layout passes
    /// do not fix it; only a window resize does - which is precisely the
    /// captain's "I had to resize/restart" experience, and why his log carried
    /// zero reactivation lines (no constraint was ever deactivated).
    ///
    /// So the repair needs a second, independent reference: `root` measured
    /// against the *window*, which is the one geometry AppKit genuinely owns
    /// and keeps authoritative.
    ///
    /// Width only, deliberately. Every measurement of this bug - and the
    /// method this lives in - is about width; repairing height too would widen
    /// a narrowly-understood fix into geometry this bug never exercised.
    private func windowContentWidthIsStale() -> Bool {
        guard let window = view.window, window.contentView === view else { return false }
        let expected = window.contentRect(forFrameRect: window.frame).width
        guard expected > 0, view.bounds.width > 0 else { return false }
        return abs(view.bounds.width - expected) > 0.5
    }

    /// Resync `root` to the window's own content width. See
    /// `windowContentWidthIsStale()` for why this is needed at all.
    private func resyncRootWidthToWindow() {
        guard let window = view.window else { return }
        let expected = window.contentRect(forFrameRect: window.frame).width
        guard expected > 0 else { return }
        let actual = view.bounds.width
        AppLog.ui.error("contentView width had drifted from the window's (\(actual, privacy: .public) vs \(expected, privacy: .public)) - resynced")
        view.setFrameSize(NSSize(width: expected, height: view.bounds.height))
    }

    deinit {
        if let windowResizeObserver {
            NotificationCenter.default.removeObserver(windowResizeObserver)
        }
    }

    // MARK: Test hooks (`fm/grandline-live-gap-rootcause-scout`)

    /// `AppShellBodyWidthSelfTest` reads this rather than `bodyContainer`
    /// directly, since that property stays `private` - everything else in
    /// this controller only ever needs to add/remove/toggle a destination
    /// view, never measure the container itself.
    var bodyContainerFrameForTests: NSRect { bodyContainer.frame }

    /// Full review #3's PF1. How many of `bodyContainer`'s embedded
    /// destination views are currently attached to it by active constraints,
    /// and how many of those are actually showing.
    ///
    /// Exposed as counts rather than the constraints themselves so the suite
    /// asserts the *property* - "a hidden page is out of the window's
    /// constraint graph, a showing one is in it" - rather than this
    /// controller's private storage shape.
    var destinationLayoutAttachmentForTests: (attached: Int, showing: Int, embedded: Int) {
        var attached = 0
        var showing = 0
        for (key, pins) in destinationPins {
            guard let view = bodyContainer.subviews.first(where: { ObjectIdentifier($0) == key }) else { continue }
            if pins.contains(where: { $0.isActive }) { attached += 1 }
            if !view.isHidden { showing += 1 }
        }
        return (attached, showing, destinationPins.count)
    }

    // MARK: Session-switcher probe surface (`fm/grandline-session-switcher`)

    /// The real strip, so a suite can read its real pills rather than a
    /// reimplementation of what it should contain.
    var sessionStripForTests: SessionStripView { sessionStrip }
    var sessionStripIsHiddenForTests: Bool { sessionStrip.isHidden }
    var sessionStripHeightForTests: CGFloat { sessionStripHeightConstraint.constant }
    /// The gap the body reserves above itself - grows by the strip's own
    /// height plus its gap when the strip is showing, which is the half of
    /// this that a plain `isHidden` check cannot see (AGENTS.md gotcha (11)).
    var bodyTopInsetForTests: CGFloat { bodyTopConstraint.constant }
    var activeHostIDForTests: UUID? { activeHostID }

    // MARK: Recents probe surface (`fm/grandline-recents-navigation`)

    /// Seeds `hostConsoles` directly with an already-built controller,
    /// bypassing `connectHost`'s real `ssh` fork - the host-page half of
    /// `SessionSwitcherSelfTest`'s own `sessions.register(...)` trick, which
    /// only covers the registry; a Recents test additionally needs
    /// `switchToSession`/`revealHostConsole` to actually run, and both require
    /// a real entry in `hostConsoles`.
    /// F2: the restored page for a host, so a self-test can assert it exists
    /// and - the property that matters - has not started its `ssh`.
    func debugHostConsole(id: UUID) -> ConsoleController? { hostConsoles[id] }

    /// The shared Firstmate console, so audit 2 §4.1's own case can drive the
    /// real `restoreTabs(from:)` launch path and then read the tabs that
    /// actually landed. `console` stays `private` - nothing in production
    /// reaches it from outside this controller.
    ///
    /// Guarded, unlike some of its older neighbours here: GL-27's lesson is
    /// that a `debug*` hook living in a production file keeps shipping unless
    /// it says otherwise, so a *new* one is compiled into debug builds only.
    #if FM_SELFTESTS
    var debugConsole: ConsoleController { console }

    /// Which destination is showing, in the same terms `show(_:)` takes.
    ///
    /// Read off `currentDestinationKind`, the one piece of state the Recents
    /// dropdown, the tab shortcuts and F2's own capture already share - never
    /// a second notion of "what is on screen", which is how those three would
    /// start disagreeing.
    var debugCurrentDestination: RailDestination? {
        guard case .rail(let dest)? = currentDestinationKind else { return nil }
        return dest
    }

    /// Which host page is showing, or nil. Straw Hat phase 3's handoff suite
    /// asserts a refusal *did not* switch, which needs the nil case.
    var debugActiveHostID: UUID? { activeHostID }

    /// The Whiteboard destination, so the crew's "draw it out" handoff can be
    /// asserted against that page's own composer rather than against a copy
    /// of the prefill this suite passed in.
    var debugWhiteboard: WhiteboardController { whiteboard }

    var debugBootstrap: BootstrapController { bootstrap }
    #endif

    func debugSeedHostConsole(_ controller: ConsoleController, hostID: UUID) {
        hostConsoles[hostID] = controller
        addChild(controller)
        embed(controller.view)
        setDestinationVisible(controller.view, false)
    }

    /// The set the Home canvas's own "N live sessions" reads, resolved through
    /// the real closure (audit 2 §4.6). A test that rebuilt the predicate
    /// would be asserting its own copy rather than the shipped one.
    func debugConnectedHostIDs() -> Set<UUID> { homeCanvas.connectedHostIDs?() ?? [] }

    /// Drives the real Recents click handler (finding 4.3), which is
    /// `private` because the bar's own popover is its only production caller.
    /// A test that reimplemented its switch-vs-reconnect decision would be
    /// asserting its own copy of the logic rather than the shipped one.
    func debugNavigateToRecent(_ kind: RecentDestinationKind) {
        navigateToRecentDestination(kind)
    }

    /// Simulates the exact failure this task's scout report captured live:
    /// AppKit (for whatever internal reason - a transient required-
    /// constraint conflict elsewhere, or simply a resize that happened with
    /// no layout pass ever following it) leaves the width tie inactive.
    /// `reassertBodyContainerWidthTie()` is what's supposed to notice and
    /// repair this on the next resize; this hook exists so a test can force
    /// that exact starting condition without needing to actually reproduce
    /// the underlying AppKit conflict (which requires runtime conditions
    /// this scout task could not otherwise pin down - see
    /// `data/grandline-live-gap-rootcause-scout/report.md`).
    func debugBreakBodyWidthTieForTests() {
        bodyLeadingConstraint.isActive = false
        bodyTrailingConstraint.isActive = false
    }

    /// Whether both halves of the width tie are currently active.
    ///
    /// `fm/grand-line-body-width-selfheal-layout-fix` needs this because a
    /// frame check alone cannot see the repair that task added. A window's
    /// content view is sized by the window itself, not by anything this app
    /// can set, so there is no way to make `bodyContainer`'s frame genuinely
    /// stale *without* resizing the window - and resizing it posts the very
    /// `NSWindow.didResizeNotification` whose repair path has always
    /// existed. Measured: setting the content view's frame directly leaves
    /// `bounds.width` reporting the new value while Auto Layout's own engine
    /// still solves against the window's real width, so `bodyContainer`
    /// correctly resolves to the window's width and a frame assertion proves
    /// nothing about which trigger did the repairing. Whether the tie is
    /// active again after a layout pass with no resize is the property that
    /// actually distinguishes the two builds.
    var bodyWidthTieIsActiveForTests: Bool {
        bodyLeadingConstraint.isActive && bodyTrailingConstraint.isActive
    }

    // MARK: B1 probe surface (review #3)

    /// The width the destination currently on screen is laid out at.
    ///
    /// The third reference `reassertBodyContainerWidthTie` compares against,
    /// exposed so a suite can read the same number the repair reads rather
    /// than re-deriving which view is showing.
    var showingDestinationWidthForTests: CGFloat? {
        visibleDestinationView()?.frame.width
    }

    /// What `showingDestinationWidthIsStale()` currently answers.
    var showingDestinationWidthIsStaleForTests: Bool { showingDestinationWidthIsStale() }

    /// Put the showing destination's frame at `width` without touching its
    /// constraints - the state B1 is about.
    ///
    /// A destination is pinned leading and trailing to `bodyContainer` by
    /// `embed`, and those ties stay active here: the defect was never a
    /// *broken* tie (the two cases above already cover that) but a live one
    /// whose frame had lost a resolve and was never re-derived, which is why
    /// neither of the other two comparisons could see it - both of their own
    /// operands were correct throughout.
    func debugShrinkShowingDestinationForTests(to width: CGFloat) {
        guard let destination = visibleDestinationView() else { return }
        var frame = destination.frame
        frame.size.width = width
        destination.frame = frame
    }

    /// GL-37: which destination slots have actually been built.
    /// `DestinationMountingSelfTest` asserts this is exactly the eager set
    /// at launch, grows by one on a first visit, and does not grow again on
    /// a revisit.
    var mountedDestinationSlotsForTests: [DestinationSlotID] {
        mounter.mountedSlots.map(\.id)
    }

    /// Daylight Phase 2: the hub and the drill header, so
    /// `DaylightModuleSelfTest` can drive the real space filter, the real
    /// module cards and the real back button rather than stand-ins.
    #if FM_SELFTESTS
    var homeCanvasForTests: HomeCanvasController { homeCanvas }
    /// `fm/grandline-engineering-cards-stale-counts`: the two detail pages
    /// whose own state the Engineering hub's cards summarise, so
    /// `SummaryFreshnessSelfTest` can drive the real page and read the real
    /// card rather than standing either of them in.
    var updatesForTests: UpdatesController { updates }
    var githubSyncForTests: GitHubSyncController { githubSync }
    /// A2: the drill cluster lives in the bar now. These keep their names so
    /// the suites that already read them still read the same *fact* - which
    /// destination the chrome is naming, and whether it is showing at all -
    /// rather than being renamed across a dozen call sites for no gain.
    var drillHeaderForTests: HelmDrillHeader { bar.drillNavForTests }
    var drillHeaderIsHiddenForTests: Bool { bar.drillNavIsHiddenForTests }
    var drillActionsForTests: [NSView] { bar.drillActionsForTests }
    /// Whether the bar is showing the space-pill strip (a top-level page)
    /// rather than the drill cluster - the property the Overview page's own
    /// regression coverage asserts.
    var barPillsAreHiddenForTests: Bool { bar.pillsAreHiddenForTests }
    var barWordmarkIsHiddenForTests: Bool { bar.wordmarkIsHiddenForTests }
    /// The Overview page itself, so a suite can drive the real page the shell
    /// mounted rather than a second instance of it.
    var dailyOverviewForTests: DailyOverviewController { dailyOverview }
    /// A3's state, as the bar currently has it.
    var scrollEdgeActiveForTests: Bool { bar.scrollEdgeActiveForTests }
    var scrollEdgeWatchedForTests: [NSScrollView] { scrollEdge.watchedForTests }
    /// The Settings page itself, so a suite can drive its own category
    /// sidebar - `fm/grandline-settings-page-sidebar-redesign` made the page
    /// master/detail, and which pane is showing decides how tall its
    /// document is.
    var settingsForTests: SettingsController { settings }
    #endif

    /// The view a mounted slot owns, for identity comparison across a
    /// navigate-away-and-back cycle - `nil` while the slot is unmounted,
    /// deliberately, so a test cannot accidentally build the thing it is
    /// asserting stays unbuilt.
    func destinationViewIfMountedForTests(_ id: DestinationSlotID) -> NSView? {
        guard let slot = mounter.slot(for: id), slot.isMounted else { return nil }
        return slot.controller.view
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
        hideAllDestinations()

        // GL-37: one table lookup replaces the fifteen-case switch this used
        // to be (and the matching line-per-destination in
        // `hideAllDestinations`). The slot is mounted here if this is its
        // first visit - see `DestinationRegistry.swift`.
        guard let slot = mounter.show(dest.slot) else { return }

        // `fm/grandline-recents-navigation`: records whatever was showing a
        // moment ago and removes `dest` itself from the list - see
        // `RecentDestinations`'s own recording method's doc comment for why a
        // captain never sees "where I already am" in the dropdown.
        updateRecentDestinations(arriving: .rail(dest))

        applyDrillHeader(title: slot.title,
                         subtitle: dest.drillSubtitle,
                         symbol: dest.symbol,
                         hue: dest.domainHue,
                         artwork: dest.drillHeaderArtwork,
                         // `fm/grandline-overview-layout-fix-gmail-settings`:
                         // a **top-level** page, not only the canvas. A space
                         // pill that opens a page of its own
                         // (`DaylightSpace.destination`) is still the top of
                         // the navigation, so the bar keeps its wordmark and
                         // its pill strip - the captain reported the new
                         // Overview tab rendering with a back arrow and no
                         // tabs at all, which is what naming the canvas here
                         // did. Read off the same one table `selectSpace`
                         // reads, never a second copy.
                         isTopLevel: slot.id == .homeCanvas
                             || DaylightSpace.owning(destination: dest) != nil,
                         slotController: slot.controller)

        // The strip's second input (see `applySessionStripVisibility`): which
        // page is showing. `currentDestinationKind` was set by
        // `updateRecentDestinations(arriving:)` a few lines up, so this reads
        // the destination the shell is navigating *to*.
        applySessionStripVisibility()

        // A3: re-point the scroll-edge observer at what is now showing.
        // After `mounter.show` the slot's view exists but may not have been
        // laid out yet, and the observer's own test is geometric, so this
        // waits for the layout pass the navigation just scheduled.
        retargetScrollEdge(to: slot.controller.view)

        // B5 (`data/grand-line-e2e-audit/report.md`): keep the bar's selected
        // space honest on **every** navigation, not only a pill click.
        //
        // `selectSpace` was the one place that called `setSelectedSpace`, so
        // reaching a page any other way - ⌘K, a notification's deep link, a
        // canvas module card, a menu item - left the previously selected pill
        // lit while showing a page that belongs to a different space. The
        // audit's own walk caught it: every drill-page render showed
        // "Engineering" highlighted, including Schedules and Health (which are
        // `.operations`) and Tasks (`.command`). A highlight that asserts the
        // wrong location is worse than none.
        //
        // Derived from the module table (`DaylightModule.space(forDestination:)`),
        // never a second copy of that mapping. A destination no module opens,
        // and the canvas itself, leave the pills alone - the canvas's space is
        // whatever the captain last chose, which `selectSpace` still owns.

        if let space = DaylightModule.space(forDestination: dest) {
            bar.setSelectedSpace(space)
        } else if dest == .homeCanvas {
            // M1: `space(forDestination:)` returns nil for the canvas itself,
            // and both the drill-header back button and `showHomeCanvas()`
            // reach it through `show(_:)` rather than `selectSpace`. Without
            // this the pill kept asserting the drill page's space while the
            // canvas rendered the space the captain last chose - B5's own
            // failure ("a highlight that asserts the wrong location is worse
            // than none") one navigation later. The canvas owns that state, so
            // this reads it rather than keeping a second copy.
            bar.setSelectedSpace(homeCanvas.selectedSpace)
        }

        // B2: light this destination's own quick-access shortcut, if it has
        // one, and darken whichever was lit before. Pushed from here for the
        // same reason `setSelectedSpace` is - the bar draws state, it does not
        // track navigation.
        bar.setActiveDestination(dest)

        // B4: the page arrives rather than teleporting. Nothing above this
        // line knows or cares that it animates; see `animateDestinationEntrance`.
        animateDestinationEntrance(slot.controller.view,
                                   direction: dest == .homeCanvas ? .back : .drillIn,
                                   skip: wasAlreadyShowing)

        // §8 Phase 6: which destination is showing decides where the bar's
        // chain hands off, so the loop is re-derived on every navigation.
        updateKeyViewLoop()
    }

    // MARK: B4 - the navigation transition

    /// Which way a navigation reads, and therefore which way the incoming page
    /// slides in from.
    enum TransitionDirection {
        /// Going deeper: the page enters from the trailing side and settles
        /// leftward, the way a push reads.
        case drillIn
        /// Coming back out to the hub: the mirror image.
        case back

        var entryOffset: CGFloat {
            switch self {
            case .drillIn: return AppShellController.destinationTransitionOffset
            case .back: return -AppShellController.destinationTransitionOffset
            }
        }
    }

    /// §3B B4's spec, measured from its own text: "a 150-200ms crossfade + 8-12pt
    /// slide".
    static let destinationTransitionDuration: TimeInterval = 0.18
    static let destinationTransitionOffset: CGFloat = 10

    #if FM_SELFTESTS
    /// What the last navigation decided. The *decision* (which direction, and
    /// whether it was skipped) is not otherwise observable once the animation
    /// has settled, and "was this skipped?" is exactly what B4's own text asks
    /// to be true - so it is recorded rather than inferred from a frame read
    /// that would be identical either way a moment later.
    /// `entryOffset` is what was actually applied, not what the direction
    /// *would* give: a frame read cannot answer this, because
    /// `NSAnimationContext.runAnimationGroup`'s body runs synchronously, so
    /// the model transform is already back at identity by the time this method
    /// returns. The animation's own existence on the layer is what the suite
    /// checks alongside this.
    private(set) var lastTransitionForTests: (direction: TransitionDirection, skipped: Bool,
                                              reducedMotion: Bool, entryOffset: CGFloat)?
    #endif

    /// B4: fade and slide a freshly-shown destination in.
    ///
    /// **What the report asks for, and the one place this deviates.** §3B B4
    /// describes "outgoing view fades to 0 / incoming from 0". This animates
    /// the incoming page only, and hides the outgoing one immediately exactly
    /// as `hideAllDestinations()` always did. The reason is not effort: three
    /// things in this shell ask "which destination is on screen?" by looking
    /// for the one mounted view that is not hidden -
    /// `visibleDestinationView()` (which feeds `firstBodyKeyView()` and
    /// therefore the whole key view loop, and which returns the *first* match),
    /// plus accessibility and hit-testing. Keeping a second destination
    /// visible for 180ms makes all three temporarily answer wrong, and the
    /// alternative - snapshotting the outgoing page into a throwaway layer -
    /// puts a full-page `cacheDisplay` on the main thread on every single
    /// navigation, which is precisely the class of cost the same audit's §3
    /// energy work went looking for. Both pages are opaque and cover the same
    /// rect, so a true crossfade would render them muddled through each other
    /// for those 180ms rather than reading cleaner; a page fading and sliding
    /// in over the app's own ground is the motion the finding describes,
    /// minus a double render.
    ///
    /// Gated through `HelmMotion`, which per its own rule means the end state
    /// *instantly* - never the same motion, slower.
    private func animateDestinationEntrance(_ destinationView: NSView,
                                            direction: TransitionDirection,
                                            skip: Bool) {
        // A navigation to the page already showing is not a navigation. It
        // still re-runs everything else `show(_:)` does (a Setup tab switch, a
        // drill-header refresh), it just does not re-announce itself.
        #if FM_SELFTESTS
        lastTransitionForTests = (direction: direction, skipped: skip,
                                  reducedMotion: HelmMotion.isReduced,
                                  entryOffset: skip || HelmMotion.isReduced ? 0 : direction.entryOffset)
        #endif
        guard !skip else {
            destinationView.alphaValue = 1
            destinationView.layer?.transform = CATransform3DIdentity
            return
        }
        guard !HelmMotion.isReduced else {
            destinationView.alphaValue = 1
            destinationView.layer?.transform = CATransform3DIdentity
            return
        }

        // Snap to the entry state. `CATransaction` with actions disabled,
        // because a view-backed layer's `transform` would otherwise pick up
        // Core Animation's default implicit animation and slide *into* the
        // start position (`HelmMotion.withoutImplicitAnimation` is the same
        // mechanism, but it is deliberately Reduce-Motion-gated and this has
        // to happen in both states).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        destinationView.alphaValue = 0
        destinationView.layer?.transform = CATransform3DMakeTranslation(direction.entryOffset, 0, 0)
        CATransaction.commit()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.destinationTransitionDuration
            // One ease-out, which is the audit's §3L motion spec's own second
            // curve ("one spring ... and one ease-out (0.15s) as the only two
            // curves"). A spring belongs on a gesture-driven or interruptible
            // move; a 180pt-per-second settle into place does not need one.
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            destinationView.animator().alphaValue = 1
            destinationView.layer?.transform = CATransform3DIdentity
        }
    }

    // MARK: Key view loop (Daylight section 8, Phase 6)

    /// Wires Tab-key order to `bar -> canvas/content`.
    ///
    /// **Why this is wired rather than left to AppKit.** An `NSWindow`
    /// recalculates its own loop from geometry, which happens to be right
    /// today (the bar is above the body) but says nothing about the two halves
    /// of the bar: `loadView` anchors the pills from the leading edge and the
    /// trailing cluster from the trailing edge as two independent constraint
    /// chains, so their relative order is a geometric accident rather than a
    /// stated intent. It is also silent about the hand-off: with fifteen
    /// destinations mounted and hidden, "the next focusable view after the
    /// avatar" is whatever the geometry sweep happens to reach first.
    ///
    /// So: `recalculateKeyViewLoop()` still builds every destination's own
    /// internal order (that is real work this should not duplicate - each page
    /// knows its own reading order), and then the three boundaries this shell
    /// owns are stated explicitly on top of it. `autorecalculatesKeyViewLoop`
    /// is turned off because leaving it on lets AppKit re-derive the loop at
    /// an arbitrary later point and silently drop those three links.
    func updateKeyViewLoop() {
        guard let window = view.window else { return }
        window.autorecalculatesKeyViewLoop = false
        window.recalculateKeyViewLoop()

        // Bar -> session strip -> body. The strip sits between them visually,
        // so it sits between them in the key loop too; it contributes nothing
        // when collapsed, because `keyViewChain` filters hidden views.
        let chain = bar.keyViewChain + (sessionStrip.isHidden ? [] : sessionStrip.keyViewChain)
        for (from, to) in zip(chain, chain.dropFirst()) { from.nextKeyView = to }
        let body = firstBodyKeyView()
        chain.last?.nextKeyView = body

        // B3 (UI modernization audit §3B, and its own bug appendix item 3):
        // the *page*, not the chrome.
        //
        // This used to be `chain.first`, set once - and `chain` starts with
        // the bar, so the first space pill became the window's initial first
        // responder at launch and wore a focus ring beside a differently
        // decorated *selected* pill. The audit's report puts it plainly: "a
        // launch-time ring on a mouse-driven UI reads as a glitch", and it is
        // visible in every one of its ~95 captures.
        //
        // Two halves, and both are needed. This is the first: focus lands on
        // the showing destination (the canvas at launch), which is where a
        // captain reaching for the keyboard actually wants to start, and
        // leaves the navigation chrome to be *reached* by Tab rather than
        // occupied by default. The second is `HelmFocusVisibility`, which
        // stops any of this painting a ring for focus nobody moved - without
        // it, this change would only move the stray launch ring from a pill
        // onto the canvas's first module card.
        //
        // Re-set on every navigation rather than only when nil: it is read
        // when the window first becomes key, so the value that matters is
        // whatever was showing by then, and writing it again afterwards is
        // harmless. `chain.first` remains the fallback for a destination with
        // nothing focusable in it yet (a page still fetching) - which is safe
        // now precisely because of that second half.
        window.initialFirstResponder = body ?? chain.first
    }

    /// The first thing below the bar the keyboard should reach: the showing
    /// destination's own first focusable view, which on the canvas is its
    /// first module card.
    ///
    /// A2 moved the drill page's back button *into* the bar, so it is the
    /// head of `bar.keyViewChain` now rather than the first thing below it -
    /// which is the same reading order it always had, one row up.
    private func firstBodyKeyView() -> NSView? {
        guard let body = visibleDestinationView() else { return nil }
        return Self.firstKeyView(in: body)
    }

    /// A3: point the observer at a freshly-shown destination.
    ///
    /// The discovery is geometric (see `ScrollEdgeObserver`), so it has to
    /// run against a laid-out view: a slot mounted for the first time by
    /// this very navigation has its scroll view at `.zero` until the pass
    /// that follows. Forcing the pass here rather than deferring to the next
    /// runloop turn keeps the bar's state correct on the same frame the page
    /// appears, which is what stops a scrolled page briefly rendering the
    /// resting bar.
    private func retargetScrollEdge(to destinationView: NSView?) {
        destinationView?.layoutSubtreeIfNeeded()
        scrollEdge.observe(destination: destinationView)
    }

    private func visibleDestinationView() -> NSView? {
        for slot in mounter.mountedSlots where !slot.controller.view.isHidden {
            return slot.controller.view
        }
        for controller in hostConsoles.values
        where controller.isViewLoaded && !controller.view.isHidden {
            return controller.view
        }
        return nil
    }

    /// Depth-first, in subview order, for the first view that can actually
    /// take focus. `canBecomeKeyView` is the right question rather than
    /// `acceptsFirstResponder`: it already accounts for a hidden ancestor,
    /// which matters here because every unshown destination is still mounted.
    private static func firstKeyView(in root: NSView) -> NSView? {
        for sub in root.subviews {
            if sub.canBecomeKeyView { return sub }
            if let found = firstKeyView(in: sub) { return found }
        }
        return nil
    }

    #if FM_SELFTESTS
    /// The resolved loop, followed through `nextKeyView` from the first pill -
    /// the shape `DaylightAccessibilitySelfTest` asserts. Capped, and stops on
    /// a cycle, so a mis-wiring is a failed assertion rather than a hang.
    func keyViewLoopOrderForTests(limit: Int = 24) -> [NSView] {
        guard var current = bar.keyViewChain.first else { return [] }
        var out: [NSView] = [current]
        var seen = Set<ObjectIdentifier>([ObjectIdentifier(current)])
        while out.count < limit, let next = current.nextKeyView {
            if seen.contains(ObjectIdentifier(next)) { break }
            out.append(next)
            seen.insert(ObjectIdentifier(next))
            current = next
        }
        return out
    }

    var barKeyViewChainForTests: [NSView] { bar.keyViewChain }
    var firstBodyKeyViewForTests: NSView? { firstBodyKeyView() }
    #endif

    /// Daylight §6.4, as merged into the bar by the audit's A2: point the
    /// bar's leading area at whatever is showing, or hand it `nil` on the
    /// canvas (the hub has no "back", so the wordmark and the space pills
    /// come back instead).
    ///
    /// The name is unchanged because this is still the same decision it
    /// always made; only where the result is rendered moved.
    private func applyDrillHeader(title: String, subtitle: String, symbol: String,
                                  hue: HelmDomainHue, artwork: NSImage? = nil, isTopLevel: Bool,
                                  slotController: NSViewController?) {
        guard !isTopLevel else {
            bar.setDrillContext(nil)
            lastDrillContext = nil
            return
        }
        let page = slotController as? DaylightDrillActions
        bar.setDrillContext(DaylightBarController.DrillContext(
            title: title,
            subtitle: page?.drillHeaderSubtitle ?? subtitle,
            symbol: symbol, hue: hue, artwork: artwork))
        // §6.4's action cluster. Asked of the destination rather than switched
        // on here, so migrating a page in a later slice is one conformance on
        // that page and no edit to the shell - and a page that has not been
        // migrated yet answers `nil`, which clears the cluster rather than
        // leaving the previous page's buttons showing.
        bar.setDrillActions(page?.drillHeaderActions ?? [])
        lastDrillContext = (title, subtitle, symbol, hue, artwork, slotController)
    }

    /// Re-read the showing page's own live subtitle (§6.4). Called by a
    /// migrated destination whose numbers just changed - never by the header.
    func refreshDrillHeaderSubtitle() {
        guard let context = lastDrillContext else { return }
        let page = context.controller as? DaylightDrillActions
        bar.setDrillContext(DaylightBarController.DrillContext(
            title: context.title,
            subtitle: page?.drillHeaderSubtitle ?? context.subtitle,
            symbol: context.symbol, hue: context.hue, artwork: context.artwork))
    }

    /// Re-read the showing page's own action cluster (§6.4) - the sibling of
    /// `refreshDrillHeaderSubtitle`, for a page whose actions depend on
    /// something the captain can change without leaving it (Hosts' three
    /// tabs).
    ///
    /// Deliberately a second method rather than folding it into the subtitle
    /// refresh: `setActions` removes and re-adds the caller's own views, so a
    /// page whose cluster never changes (Review's Refresh button, Tasks' sync
    /// pill) should not have it torn down and rebuilt on every render.
    func refreshDrillHeaderActions() {
        guard let context = lastDrillContext else { return }
        let page = context.controller as? DaylightDrillActions
        bar.setDrillActions(page?.drillHeaderActions ?? [])
    }

    // MARK: Spaces (Daylight §5.3)

    /// A space pill was picked: land on the canvas if we are not already
    /// there, then filter it.
    ///
    /// Both halves live here rather than in either component, which is what
    /// keeps §5.3's rule true from both directions - the bar does not know
    /// what a canvas is, and the canvas does not know how to navigate.
    func selectSpace(_ space: DaylightSpace) {
        bar.setSelectedSpace(space)
        // `fm/grandline-overview-page-daily-review`: a pill can now be a page
        // rather than a filter (`DaylightSpace.destination`). The table is
        // asked rather than the case named, so a second such pill is one line
        // in that enum and none here - and the canvas's own space selection is
        // left alone, which is what makes a round trip through this page land
        // back on the space the captain was last filtering.
        if let destination = space.destination {
            show(destination)
            return
        }
        homeCanvas.select(space: space)
        show(.homeCanvas)
    }

    /// The canvas itself, for a caller that wants the hub without changing
    /// the space (the app delegate's launch landing).
    @objc func showHomeCanvas() { show(.homeCanvas) }

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
        show(destination)
    }

    // MARK: The configurable quick-access row and the all-destinations map (UX1/UX2)

    /// Raised when something asks for the all-destinations overlay. Owned by
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

    /// Pin or unpin `destination` on the floating bar's shortcut row, persist
    /// the result, and redraw the row.
    ///
    /// The one write path. `AppSettings.quickAccess` is the store of record and
    /// the bar holds only a cache of what it drew, so a caller that wrote the
    /// setting directly would leave the bar stale until the next launch.
    func toggleQuickAccessPin(_ destination: RailDestination) {
        let next = AppSettings.shared.quickAccess.toggling(destination)
        AppSettings.shared.quickAccess = next
        bar.setQuickAccess(next)
    }

    /// Whether `destination` is currently pinned - what the overlay's context
    /// menu reads to decide between "Pin to bar" and "Unpin from bar".
    func isQuickAccessPinned(_ destination: RailDestination) -> Bool {
        AppSettings.shared.quickAccess.contains(destination)
    }

    // MARK: Contextual ⌘N (UX4)

    /// What ⌘N would create right now - the File menu re-reads this on every
    /// open so the item's own title says which thing it means.
    ///
    /// `hostsPanel.currentTab` is consulted only for `.hosts`; see
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
            hostsTab: destination == .hosts ? hostsPanel.currentTab : nil)
    }

    /// Perform whatever ⌘N means on the page that is showing.
    ///
    /// Every branch dispatches the *existing* menu action rather than
    /// re-implementing the creation, which is the same rule
    /// `UnifiedSearchActionProvider` follows: one way to create each thing, so
    /// a fix to the sheet cannot miss an entry point.
    @objc func newContextualItem() {
        switch contextualNewAction {
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
        readingList.newLinkFromMenu()
    }

    @objc func newNotebookPageFromMenu() {
        show(.notebook)
        notebook.newPageFromMenu()
    }

    @objc func newStickyNoteFromMenu() {
        show(.stickyBoard)
        stickyBoard.addNoteFromMenu()
    }

    /// UX10's "Make a task" promotion. The board raises a note; this navigates
    /// to Tasks and opens the editor already filled in.
    ///
    /// Wired here rather than on the board because this controller is the one
    /// place that holds both destinations - the same forward-don't-own shape
    /// every other cross-destination action in this app uses.
    private func makeTaskFromStickyNote(_ note: StickyNote) {
        show(.shift)
        shift.presentTaskEditor(prefilledFrom: note)
    }

    // MARK: Clipboard history (F3)

    /// ⌘⇧V. The panel and its store live on the bar (see
    /// `DaylightBarController.clipboardHistory`); this is the menu's way in,
    /// and the one place the "paste it back" toast is worded.
    @objc func toggleClipboardHistory() {
        bar.clipboardHistory.toggle()
    }

    /// Arm the capture loop. Called once, from `main.swift` - never at init;
    /// see `ClipboardHistoryController.startCapturing()` for why.
    func startClipboardHistoryCapture() {
        bar.clipboardHistory.startCapturing()
        bar.clipboardHistory.onPasted = { [weak self] _ in
            self?.showToast("Copied \u{2014} \u{2318}V to paste it")
        }
    }

    // MARK: Universal capture (F2)

    /// The five writes ⌥Space's router reaches, bound to the stores this
    /// controller already owns.
    ///
    /// **Why the panel does not own any of this.** GL-23: `CredentialVaultStore`
    /// and `StickyBoardStore` cache, so a second instance is a second source
    /// of truth, and this controller is the one place all five destinations
    /// are already in scope. The same "forward, never own" shape
    /// `RecentDestinationsController.configure` uses, for the same reason.
    ///
    /// **Four of the five file silently; ⌘4 hands off, on purpose.** A
    /// captured credential is a *secret* with no title, category or location,
    /// and the vault may well be locked when ⌥Space fires (a locked
    /// `CredentialVaultStore.add` refuses outright). So ⌘4 navigates to
    /// Poneglyph and opens its own Add sheet with the secret already filled -
    /// the same "select the destination first, then act on it" shape every
    /// creation verb above uses, and the one destination where a silent write
    /// would be the wrong answer even if it were possible.
    func makeCaptureFiler() -> CaptureFiler {
        CaptureFiler { [weak self] destination, draft in
            guard let self else { return .refused("The app shell went away.") }
            switch destination {
            case .task:
                var task = ShiftTask.fresh()
                task.title = draft.title
                task.description = draft.body
                if let due = draft.dueDate {
                    let (dateStr, timeStr) = ShiftDateFormatting.components(from: due)
                    task.dueDate = dateStr
                    task.dueTime = draft.dueHasTime ? timeStr : nil
                }
                self.shiftStore.addTask(task)
                return .filed(.task)

            case .sticky:
                self.stickyBoard.addCapturedNote(title: draft.title, text: draft.body)
                return .filed(.sticky)

            case .note:
                _ = self.notebookStore.createPage(
                    title: CaptureRouter.notebookTitle(for: draft),
                    content: draft.text)
                return .filed(.note)

            case .codeSnippet:
                _ = self.codePreviewStore.create(name: CaptureRouter.snippetName(for: draft),
                                                 content: draft.text)
                return .filed(.codeSnippet)

            case .link:
                // The one destination whose store decides whether the capture
                // is even a link, so the panel is told what actually happened
                // rather than being told "filed" unconditionally. A duplicate
                // and a non-URL are both `.refused`, and the panel keeps the
                // captain in the loop - the same posture ⌘4 takes below for a
                // different reason.
                switch self.readingListStore.add(draft.text) {
                case .added:
                    // The page may never have been mounted, so the card it
                    // will show is built on first visit from the store this
                    // just wrote - nothing here has to reach into a view.
                    return .filed(.link)
                case .duplicate(let existing):
                    return .refused("\(existing.host) is already on the reading list.")
                case .rejected(let why):
                    return .refused(why)
                }

            case .credential:
                self.show(.poneglyph)
                self.poneglyph.presentCapturedCredential(secret: draft.text)
                return .handedOff(.credential)
            }
        }
    }

    @objc func newCodeSnippetFromMenu() {
        show(.codePreview)
        codePreview.newSnippetFromMenu()
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
        codePreview.runCodeSnippet()
    }

    /// F15's ⌘⇧S. Unlike `runCodeSnippetFromMenu` - which refuses off its own
    /// page because ⌘R has a page-local meaning - this one *navigates*: the
    /// capture is the thing the captain asked for, the Whiteboard is only
    /// where it lands, and refusing because they happened to be on Console
    /// would make the chord feel broken. Same shape as every `new*FromMenu`
    /// below.
    @objc func captureScreenRegionFromMenu() {
        show(.whiteboard)
        whiteboard.captureTapped()
    }

    /// The copy half. This one *does* refuse off-page: there is no board to
    /// copy anywhere else, and navigating to the Whiteboard to copy whatever
    /// happens to be on it is not what the item says.
    @objc func copyWhiteboardImageFromMenu() {
        guard case .rail(.whiteboard)? = currentDestinationKindForMenus else { return }
        whiteboard.copyImageTapped()
    }

    @objc func newCredentialFromMenu() {
        show(.poneglyph)
        poneglyph.newCredentialFromMenu()
    }

    @objc func newScheduleFromMenu() {
        show(.schedules)
        schedules.newScheduleFromMenu()
    }

    @objc func newCommandFromMenu() {
        show(.commandLibrary)
        commandLibrary.newCommandFromMenu()
    }

    @objc func newRunbookFromMenu() {
        show(.runbooks)
        runbooks.newRunbookFromMenu()
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
        guard poneglyph.isViewLoaded else { return }
        poneglyph.lockFromMenu()
    }

    /// Fix 1: connect to `host` (its own dedicated page). The first call for
    /// a given host builds its `ConsoleController` (via `makeHostConsole`),
    /// embeds it, and opens its one ssh tab; every later call for the same
    /// host just brings that already-built page forward and re-focuses its
    /// current tab - `ConsoleController.connectSSHIfNeeded` is what actually
    /// makes the "open a tab" half of that a no-op after the first time.
    /// `args` is the host's resolved `ssh` argv (`Host.sshArguments(allHosts:)`)
    /// - built by the caller, since this controller knows nothing about the
    /// host store, matching `onPresentHostEditor` above.
    func connectHost(_ host: Host, args: [String], navigate: Bool = true) {
        let controller: ConsoleController
        if let existing = hostConsoles[host.id] {
            controller = existing
        } else {
            controller = makeHostConsole()
            hostConsoles[host.id] = controller
            addChild(controller)
            embed(controller.view)
            setDestinationVisible(controller.view, false)
            // The cross-bridge collision guard's third direction (full-app
            // audit, finding 4.1), and the console this one actually matters
            // for: the `.kubernetes` destination scopes to a *saved host*, so
            // its feed tab is always one of these pages' tabs, never the
            // shared Firstmate console's. Set once at creation - unlike the
            // per-connect closures below it depends on nothing about the host
            // record, only on which two objects the shell holds.
            controller.isKubernetesFeedBridgeBusy = { [weak self] tabID in
                self?.kubernetes.isFeedBridgeBusy(onTab: tabID) ?? false
            }
        }
        controller.connectSSHIfNeeded(
            label: host.label, args: args, accentHex: host.accentHex,
            keyID: host.keyID, startupSnippetID: host.startupSnippetID,
            blockViewOptIn: host.blockViewOptIn, kubeContextBadgeOptIn: host.kubeContextBadgeOptIn
        )

        // Audit 2 §4.6: keep the registry's own reading of this page current.
        // Assigned before the `register` below, so an already-started page
        // (a re-reveal) reports `.connected` immediately rather than after
        // whatever its next start/close happens to be.
        //
        // `startTab` is the only place `TabModel.started` is ever set, so this
        // fires exactly when the answer can have changed - never on a timer,
        // and never inferred by the registry itself.
        let sessionHostID = host.id
        controller.onLiveSessionMayHaveChanged = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.sessions.setState(hostID: sessionHostID,
                                   controller.hasLiveSession ? .connected : .restored)
        }

        // `fm/grandline-session-switcher`: this host now has a live session.
        // Idempotent, and re-called on every connect for the same reason the
        // closures below are reassigned - a renamed host or a recoloured
        // accent should be current on the strip without needing a reconnect.
        //
        // Audit 2 §4.6: `.restored` unless the page has *already* started
        // something. This runs before the page appears, so a first connect is
        // genuinely not connected yet at this instant; `setState` above moves
        // it the moment `startTab` runs, which for an ordinary connect is one
        // layout pass later and for a restored (or lock-deferred) page is
        // whenever the captain actually opens it. `register` never downgrades
        // an already-live entry, so a re-reveal cannot blank a live pill.
        sessions.register(hostID: host.id, label: host.label, accentHex: host.accentHex,
                          state: controller.hasLiveSession ? .connected : .restored)

        // fm/grandline-notification-center: reassigned on every call (not
        // just the first) so a renamed host label is always current in the
        // notification's own subtext - cheap, and `host.label` is only read
        // at the moment a reply actually lands, not cached earlier than
        // that either.
        let hostID = host.id
        let hostLabel = host.label
        controller.onSRELeadReplyWhileBackground = { [weak self, weak controller] tab in
            guard let self else { return }
            NotificationSources.setSRELeadReply(tabID: tab.id, tabName: tab.name, hostLabel: hostLabel) { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.hideAllDestinations()
                self.setDestinationVisible(controller.view, true)
                // `fm/grandline-recents-navigation`: this bypasses `revealHost
                // Console` (it also needs to focus one specific tab), but it
                // is a real navigation like any other - and skipping this
                // would leave `currentDestinationKind` stale for whatever the
                // *next* real navigation tries to record as "outgoing".
                self.updateRecentDestinations(arriving: .host(id: hostID, label: hostLabel))
                self.applyDrillHeader(title: hostLabel, subtitle: "Dedicated host page",
                                      symbol: RailDestination.hosts.symbol,
                                      hue: RailDestination.hosts.domainHue, isTopLevel: false,
                                      slotController: controller)
                self.retargetScrollEdge(to: controller.view)
                self.activeHostID = hostID
                controller.selectAndFocusTab(id: tab.id)
            }
        }

        // `fm/grandline-k8s-cluster-tail`: the Shape-C deep link. Assigned
        // here (rather than in `makeHostConsole`) for the same reason every
        // closure around it is - this is where the host id exists, and a
        // reassign on every connect keeps a renamed host current.
        controller.onTailLogs = { [weak self] in self?.openKubernetes(hostID: hostID, showTail: true) }

        // `fm/grandline-log-analyzer-build`: reassigned on every call for
        // the same reason `onSRELeadReplyWhileBackground` above is - a
        // renamed host should show its current label on the imported
        // evidence, and the closure only reads it when a capture actually
        // happens.
        controller.onAnalyzeLogs = { [weak self, weak controller] capture, tabName in
            guard let self else { return }
            self.logAnalyzerCaptureSource = controller
            self.openLogAnalyzer(with: capture, hostLabel: "\(hostLabel) · \(tabName)")
        }

        // F8 (incident mode): this page's host identity. Set on every call
        // for the same reason the two closures above are reassigned - a
        // renamed host should show its current label on a new incident - and
        // it is what makes the incident toolbar action appear at all (the
        // shared Firstmate console never gets one).
        controller.hostIdentity = ConsoleHostIdentity(id: host.id.uuidString, label: host.label)

        // Daylight §6.4: a dedicated host page routes through this same
        // controller class, so it gets the same live header subtitle the
        // shared Console destination does. Assigned on every call for the same
        // reason the closures above are - the page is created once and
        // reconnected many times.
        controller.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }

        // The incident card's Evidence tab reopening a saved Log Analyzer
        // investigation. Routed through this controller because a console
        // page knows nothing about rail destinations, exactly like
        // `onAnalyzeLogs` above.
        controller.onOpenInvestigation = { [weak self] investigationID in
            guard let self else { return }
            self.show(.logAnalyzer)
            self.logAnalyzerCaptureSource = nil
            self.logAnalyzer.openSavedInvestigation(id: investigationID)
        }

        // F9 (v1): a multi-host send connects several hosts in one pass and
        // navigates once, at the end, to the first of them - so every
        // intermediate host is connected with `navigate: false` rather than
        // yanking the window through N pages the captain never asked to look
        // at. Every other caller (the rail icon, the Hosts list's Connect, the
        // ⌘K palette) keeps the default and behaves exactly as before.
        guard navigate else { return }

        // `revealHostConsole` is the shared tail (see its own note): it hides
        // every other destination, shows this page, sets the drill header,
        // records this session as the active one and re-focuses its terminal -
        // including the `markCurrentTabAsRead` that clears this page's own SRE
        // Lead unread entry, exactly as this method did inline before.
        revealHostConsole(controller, hostID: host.id, label: host.label)
    }

    /// F9 (v1): does this host already have a live dedicated page? Read by
    /// the "Send to…" picker for each row's connected/not-connected line -
    /// the same piece of state the rail's own per-host highlighting uses, not
    /// a second notion of "connected" invented for the picker.
    /// Whether `host` has a genuinely live session - a page with a running
    /// child process, not merely a page this shell has built.
    ///
    /// Audit 2 §4.5/§4.6: this used to be `hostConsoles[host.id] != nil`,
    /// which after F2 was true for a restored page that had forked nothing.
    /// F9's picker showed such a host as "Connected" and `sendCommandToHost`
    /// took its immediate-send branch, typing into a terminal with no process
    /// on the other end - silently, since nothing reports a dropped send.
    func isHostConnected(_ host: Host) -> Bool {
        guard let controller = hostConsoles[host.id] else { return false }
        return controller.hasLiveSession
    }

    /// F9 (v1): type `text` into `host`'s own dedicated page, connecting it
    /// first if it has none yet.
    ///
    /// This is the *existing* connect-then-`send(txt:)` path per host, not a
    /// second mechanism: `connectHost` (whose `connectSSHIfNeeded` is what
    /// makes a re-send to an already-open host reuse its tab instead of
    /// stacking a second one) followed by the same
    /// `sendCommandLibraryTextToActiveTab` a single-host send already calls -
    /// just on that host's console rather than the shared one.
    ///
    /// A host that was already open receives the text immediately. A host that
    /// had to be connected first gets it after a short delay, for the same
    /// reason - and with the same honest "best-effort, there is no protocol
    /// signal for *the remote shell is ready now*" caveat - as
    /// `ConsoleController.runStartupSnippet`, whose delay this matches.
    func sendCommandToHost(_ host: Host, args: [String], text: String) {
        let wasConnected = isHostConnected(host)
        connectHost(host, args: args, navigate: false)
        guard let controller = hostConsoles[host.id] else { return }
        if wasConnected {
            controller.sendCommandLibraryTextToActiveTab(text)
            return
        }
        // Audit 2 §4.5, the half that `isHostConnected` telling the truth
        // (above) does not fix on its own. `navigate: false` means this page
        // never appears, so `viewDidAppear` - and therefore `startTab` - never
        // fires, and the delayed send below would type into a terminal with no
        // process on the other end. That was true of this branch even before
        // F2; F2 only widened which hosts reach it (a restored page used to
        // take the *immediate* branch instead, which is worse).
        //
        // `runAppearanceWorkIfUnlocked` rather than `startTab` directly: it is
        // the lock-gated entry point (#340 / §5.1), so a send that arrives
        // while the app is locked defers the fork exactly like every other
        // path and replays it on unlock, instead of this being a way around
        // the gate. A page that is already started no-ops.
        controller.runAppearanceWorkIfUnlocked()
        DispatchQueue.main.asyncAfter(deadline: .now() + ConsoleController.remoteShellReadyDelay) { [weak controller] in
            controller?.sendCommandLibraryTextToActiveTab(text)
        }
    }

    /// F9 (v1): bring one host's page forward after a multi-host send, so the
    /// captain lands somewhere deliberate rather than on whichever page
    /// happened to be connected last.
    func revealHost(_ host: Host, args: [String]) {
        connectHost(host, args: args)
    }

    /// A host was deleted from the store - tear down its dedicated page
    /// (if it was ever connected to) so a stale, unreachable-from-the-rail
    /// destination can't linger. Navigates back to the Firstmate console if
    /// the deleted host's page happened to be the one showing.
    /// Flush anything the Sticky Board's debounced local write is still
    /// holding, on the way to quitting (findings 3.3/4.6).
    ///
    /// The store owns the debounce; this is only the shell's forward, needed
    /// because `stickyBoard` is `private` and the app delegate is where
    /// `applicationWillTerminate` lives. It is safe to call on a destination
    /// that was never mounted: the controller is constructed eagerly, its
    /// store with it, and a store with nothing queued flushes nothing.
    /// Drop a deleted host's Recents row (finding 4.3). Called by the app
    /// delegate's own host-delete diffing, which is the one place that knows
    /// a host has genuinely left the store - `removeHostConsole` cannot be
    /// that place, because it is also what "End session" calls, and an ended
    /// session's row must stay listed and reconnect.
    func forgetRecentHost(id: UUID) {
        recentDestinations.forget(.host(id: id, label: ""))
    }

    func shutdownStickyBoard() {
        stickyBoard.shutdown()
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
    func shutdownReadingList() {
        readingList.shutdown()
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
    func shutdownCodePreview() {
        codePreview.shutdown()
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
    func shutdownCredentialVault() {
        poneglyph.shutdown()
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
        strawHat.shutdown()
    }

    func removeHostConsole(id: UUID) {
        guard let controller = hostConsoles.removeValue(forKey: id) else { return }
        let wasActive = activeHostID == id
        controller.shutdown()
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        // `fm/grandline-session-switcher`: this is the app's one teardown path
        // for a host page (a deleted host, or an explicit "end session"), so it
        // is where the registry stops claiming that host is live. Unregistering
        // anywhere else would be a second writer.
        sessions.unregister(hostID: id)
        if wasActive {
            // Prefer a sibling live session over dumping the captain on the
            // shared Firstmate console: with two sessions open, closing one
            // should land on the other rather than somewhere neither of them
            // was. Falls back to the previous behaviour when nothing is left.
            if let next = sessions.sessions.first {
                switchToSession(hostID: next.hostID)
            } else {
                show(.console)
            }
        }
    }

    // MARK: Session switching (`fm/grandline-session-switcher`)

    /// Bring an **already live** session's page forward. Deliberately separate
    /// from `connectHost`: that one needs the host's resolved `ssh` argv (so
    /// its caller needs the host store), while switching back into a session
    /// that already exists needs nothing but its id - which is what lets the
    /// strip, the ⌘K palette and the keyboard shortcuts all reach it without
    /// any of them learning how a host's argv is built.
    ///
    /// A no-op for a host with no live session, so every caller can fire it
    /// against a possibly-stale id without checking first.
    func switchToSession(hostID: UUID) {
        guard let controller = hostConsoles[hostID],
              let session = sessions.session(for: hostID) else { return }
        revealHostConsole(controller, hostID: hostID, label: session.label)
    }

    /// The shared tail of `connectHost` and `switchToSession` - one definition
    /// of "this host's page is now the thing on screen", so the drill header,
    /// the registry's active session and the focused terminal can never
    /// disagree about which of them is showing.
    private func revealHostConsole(_ controller: ConsoleController, hostID: UUID, label: String) {
        let wasAlreadyShowing = currentDestinationKind == .host(id: hostID, label: label)
        hideAllDestinations()
        setDestinationVisible(controller.view, true)
        // B2: a host page is not a `RailDestination` at all, so no quick-access
        // shortcut corresponds to it - clear whichever was lit rather than
        // leaving the last visited destination's icon asserting it is current.
        bar.setActiveDestination(nil)
        // B4: a host page is a drill-in like any other.
        animateDestinationEntrance(controller.view, direction: .drillIn, skip: wasAlreadyShowing)
        // `fm/grandline-recents-navigation`: a saved host's own page is one of
        // the destinations the captain explicitly wants tracked - this is the
        // one place both a fresh connect and switching back into a live
        // session reach, so it needs no separate hook at either call site.
        updateRecentDestinations(arriving: .host(id: hostID, label: label))
        applyDrillHeader(title: label, subtitle: "Dedicated host page",
                         symbol: RailDestination.hosts.symbol,
                         hue: RailDestination.hosts.domainHue, isTopLevel: false,
                         slotController: controller)
        // A3: a host console has no page scroll view, so this correctly
        // clears the edge rather than leaving the previous page's state.
        retargetScrollEdge(to: controller.view)
        activeHostID = hostID
        sessions.setActive(hostID)
        controller.focusCurrentTab()
        controller.markCurrentTabAsRead()
        updateKeyViewLoop()
    }

    // MARK: F2 - session restoration

    /// Where the captain is right now, in a form that survives a relaunch.
    ///
    /// Reads the same `currentDestinationKind` the Recents dropdown and the
    /// tab shortcuts already read, and the same `hostConsoles` dictionary the
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
            openHostIDs: hostConsoles.keys.map(\.uuidString).sorted(),
            consoleTabs: console.isViewLoaded ? console.restorableConsoleTabs() : [],
            toolTabs: tools.isViewLoaded ? tools.restorableToolTabs() : []
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
            _ = console.view
            console.restoreConsoleTabs(state.consoleTabs)
        }
        if !state.toolTabs.isEmpty {
            _ = tools.view
            tools.restoreToolTabs(state.toolTabs)
        }
    }

    /// Restores the destination that was showing.
    ///
    /// Returns `false` when the state named a host page, which this method
    /// cannot open on its own (it needs the host record and its resolved `ssh`
    /// argv, which this controller deliberately knows nothing about - the same
    /// boundary `connectHost`'s own `args` parameter draws). The app delegate
    /// handles that case; everything else is an ordinary `show(_:)`.
    @discardableResult
    func restoreDestination(from state: SessionRestoreState) -> Bool {
        guard state.activeHostID == nil else { return false }
        guard let raw = state.destination, let dest = RailDestination(rawValue: raw) else { return false }
        show(dest)
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
            return hostConsoles[id]
        case .rail(let dest):
            switch dest {
            case .console: return console
            case .tools: return tools
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
    private func updateRecentDestinations(arriving kind: RecentDestinationKind) {
        recentDestinations.recordNavigation(leaving: currentDestinationKind, arriving: kind)
        currentDestinationKind = kind
        // Review #3 §7: the window title carries the current destination, so
        // Mission Control and the Window menu name a page rather than the app.
        onCurrentDestinationChanged?(kind.title)
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
    /// the host - all clear `hostConsoles`, so all three produced it.
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

    private func navigateToRecentDestination(_ kind: RecentDestinationKind) {
        switch kind {
        case .rail(let dest):
            show(dest)
        case .host(let id, _):
            if sessions.session(for: id) != nil {
                switchToSession(hostID: id)
            } else if onReconnectHost?(id) != true {
                // The host is gone from the store entirely - nothing to
                // reconnect to, so stop listing it rather than leaving a row
                // that can only ever do nothing.
                recentDestinations.forget(.host(id: id, label: ""))
            }
        }
    }

    /// End a live session, after a confirm.
    ///
    /// **Always confirmed, never conditionally.** The mockup asks for a
    /// confirm "if a command may be mid-flight", and this app has no reliable
    /// signal for that: the only structured record of a running command is
    /// `TerminalBlockTracker`'s OSC 133 markers, which exist solely on a host
    /// that opted into Block View (off by default, one host at a time - see
    /// AGENTS.md's Block View section), so on every other host "is something
    /// running?" is genuinely unknown. Confirming only when we happen to know
    /// would mean silently killing whatever was running on every host that
    /// cannot answer - so the alert is unconditional, and says why.
    func confirmEndSession(hostID: UUID) {
        guard let session = sessions.session(for: hostID) else { return }
        // G3: themed; Return still ends the session, as it did here.
        guard HelmConfirm.confirm(
            title: "End the session on \(session.label)?",
            body: "Anything still running in that terminal will be terminated.",
            confirmTitle: "End Session",
            destructive: true,
            symbol: "xmark.circle.fill",
            hue: .rose) else { return }
        removeHostConsole(id: hostID)
    }

    /// The Hosts menu's "Session N" items (⌘⌃1…⌘⌃9). The tag is 1-based and
    /// past the end is simply nothing to do - a captain with two sessions
    /// pressing ⌘⌃5 should get silence, not the nearest session.
    @objc func selectSessionByShortcut(_ sender: NSMenuItem) {
        let index = sender.tag - 1
        guard sessions.sessions.indices.contains(index) else { return }
        switchToSession(hostID: sessions.sessions[index].hostID)
    }

    /// ⌘] / ⌘[ - cycle forward/back through the live sessions, wrapping.
    @objc func nextSession() {
        guard let next = sessions.session(steppedBy: 1) else { return }
        switchToSession(hostID: next.hostID)
    }

    @objc func previousSession() {
        guard let previous = sessions.session(steppedBy: -1) else { return }
        switchToSession(hostID: previous.hostID)
    }

    /// Every registry change lands here: the strip re-renders and shows or
    /// collapses, and the Hosts list's rows are rebuilt so a row that just
    /// went live (or just died) reads correctly the moment it is looked at.
    private func applySessionRegistry(_ registry: HostSessionRegistry) {
        guard isViewLoaded, sessionStripHeightConstraint != nil else { return }
        sessionStrip.render(registry)
        applySessionStripVisibility()
        // Rebuilding a hidden page's rows would be work nobody can see; it
        // gets them on its next `viewWillAppear` instead.
        if hostsPanel.isViewLoaded, !hostsPanel.view.isHidden {
            hostsPanel.refreshLiveSessionState()
        }
        updateKeyViewLoop()
    }

    /// Whether the strip is showing, and how much room it takes.
    ///
    /// Two inputs, and the second is `fm/grandline-overview-layout-fix-gmail-settings`'s:
    /// there has to be a live session **and** the showing page has to be one
    /// the strip belongs on (`RailDestination.showsSessionStrip`). The strip
    /// was built to make a live session reachable "from anywhere"
    /// (`docs/history/03-navigation-and-chrome.md`) and still is - the one
    /// page it is now kept off is the daily-review Overview, where the
    /// captain reported a terminal tab strip reading as leftover UI bleeding
    /// into a page that has nothing to do with terminals.
    ///
    /// Called from both inputs' own change points - a registry change and a
    /// navigation - because either alone can flip the answer.
    private func applySessionStripVisibility() {
        guard isViewLoaded, sessionStripHeightConstraint != nil else { return }
        let visible = !sessions.isEmpty && currentDestinationShowsSessionStrip
        sessionStrip.isHidden = !visible
        sessionStripHeightConstraint.constant = visible ? SessionStripView.height : 0
        bodyTopConstraint.constant = DaylightBarController.reservedTopHeight
            + (visible ? SessionStripView.gapBelowBar + SessionStripView.height : 0)
    }

    /// Whether the page showing right now is one the session strip belongs
    /// on. A destination the shell has never navigated to (launch, before the
    /// first `show`) answers `true`, which is the strip's own historical
    /// behaviour.
    private var currentDestinationShowsSessionStrip: Bool {
        guard case .rail(let dest)? = currentDestinationKind else { return true }
        return dest.showsSessionStrip
    }

    private func hideAllDestinations() {
        // Only mounted slots have a view to hide - asking an unmounted one
        // for `controller.view` here would build it and defeat GL-37's whole
        // point. Host pages are tracked separately (they are not fixed
        // `RailDestination` cases) and were always lazily built.
        mounter.hideAll()
        for controller in hostConsoles.values where controller.isViewLoaded {
            setDestinationVisible(controller.view, false)
        }
        activeHostID = nil
        // `fm/grandline-session-switcher`: no session's page is on screen any
        // more. The sessions themselves are untouched - a live session that is
        // not showing is still live, just not active - so the strip keeps its
        // pills and simply stops filling one of them in.
        sessions.setActive(nil)
    }

    /// The Hosts menu's "Quick Connect" (⌘K): reveal the Hosts destination
    /// and focus its quick-connect field, regardless of which destination
    /// was active. No longer shared with the topbar Search control (Fix 4).
    @objc func revealHostsQuickConnect() {
        show(.hosts)
        hostsPanel.focusQuickConnect()
    }

    /// Wired by the app delegate: the Snippets tab's "Run" sends a snippet to
    /// the console's active tab. Forwarded rather than owned, matching
    /// `onPresentHostEditor` - this controller knows nothing about snippets.
    var onRunSnippet: ((Snippet) -> Void)? {
        get { hostsPanel.onRunSnippet }
        set { hostsPanel.onRunSnippet = newValue }
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
        if let activeHostID, let controller = hostConsoles[activeHostID] {
            controller.showFind()
            return
        }
        show(.console)
        console.showFind()
    }

    /// The App menu's "Settings…" (⌘,): select the Settings rail destination
    /// rather than opening a separate window.
    @objc func selectSettings() {
        show(.settings)
    }

    /// The Hosts menu's "Show Hosts": select the Hosts rail destination.
    @objc func selectHosts() {
        show(.hosts)
        hostsPanel.select(tab: .hosts)
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
        hostsPanel.newHost()
    }

    /// The Keys menu's "Manage Keys…" (⌘⇧K). Phase 5 of the full-app UI audit
    /// folded the SSH Keys window into the Hosts destination as a tab, so
    /// this now selects that destination and that tab rather than opening a
    /// second window.
    @objc func selectKeys() {
        show(.hosts)
        hostsPanel.select(tab: .keys)
    }

    /// The Snippets menu's "Manage Snippets…" (⌘⌥P) - same shape as
    /// `selectKeys`.
    @objc func selectSnippets() {
        show(.hosts)
        hostsPanel.select(tab: .snippets)
    }

    /// The Keys menu's "New Key…" (⌘⇧N): reveal the Keys tab and open the key
    /// editor sheet on it, regardless of which destination was showing.
    @objc func newKeyFromMenu() {
        show(.hosts)
        hostsPanel.newKey()
    }

    /// The Snippets menu's "New Snippet…" (⌘⌥N) - same shape.
    @objc func newSnippetFromMenu() {
        show(.hosts)
        hostsPanel.newSnippet()
    }

    /// The Shift menu's "New Task…" (⌘N) - selects the Shift destination
    /// first so the sheet has something to present over, then opens the New
    /// Task editor regardless of whichever destination was showing before.
    @objc func newShiftTaskFromMenu() {
        show(.shift)
        shift.presentNewTaskEditor()
    }

    /// The Shift menu's "New Follow-up…" (⌘⇧F) - same shape as
    /// `newShiftTaskFromMenu` above.
    @objc func newShiftFollowUpFromMenu() {
        show(.shift)
        shift.presentNewFollowUpEditor()
    }

    /// The Shift menu's "New Project…" (cockpit-fix-shift-new-project) - no
    /// keyboard shortcut, since ⌘⇧P (the pattern ⌘N/⌘⇧F would suggest for a
    /// third Shift creation action) is already claimed by "Search Shift…"
    /// below - same shape as "Weekly Review", which also has no shortcut.
    @objc func newShiftProjectFromMenu() {
        show(.shift)
        shift.presentNewProjectEditor()
    }

    // MARK: Search / menu bar / quick-capture navigation (phase 5)

    /// The Shift menu's "Search Shift…" (⌘⇧P) and the search palette's own
    /// entry point - selects the Shift destination so a result's editor
    /// sheet (below) has somewhere to present over.
    func showShiftDestination() { show(.shift) }

    /// The ⌘⇧P search palette's "Weekly Review" navigation, and the Shift
    /// menu's own "Weekly Review" item.
    @objc func showShiftWeeklyReview() {
        show(.shift)
        shift.showWeeklyReview()
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
        overview.showLogTab()
    }

    /// The Hosts sidebar's user row, routed into the bar's own single logout
    /// confirmation rather than a second copy of it.
    func requestLogout() { bar.requestLogout() }

    func openShiftTask(id: String) {
        show(.shift)
        shift.openTask(id: id)
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
    var poneglyphQuickCodes: [PoneglyphQuickCode] { poneglyph.quickCodeEntries }

    var poneglyphIsUnlocked: Bool { poneglyph.isVaultUnlocked }

    @discardableResult
    func copyPoneglyphCodeFromMenuBar(id: String) -> String? {
        poneglyph.copyQuickCode(id: id)
    }

    /// `fm/grandline-k8s-cluster-tail`: the Shape-C deep link. A host page's
    /// own "Tail Logs" / "Cluster" toolbar buttons land here with that host
    /// already selected as the scope, so the captain reaches the same one
    /// implementation from either front door - the identical idiom Overview's
    /// ready-to-merge tile already uses to reach Review.
    func openKubernetes(hostID: UUID, showTail: Bool) {
        show(.kubernetes)
        kubernetes.openScoped(hostID: hostID, showTail: showTail)
    }

    func openShiftFollowUp(id: String) {
        show(.shift)
        shift.openFollowUp(id: id)
    }

    func openShiftProject(id: String) {
        show(.shift)
        shift.openProject(id: id)
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
        runbooks.openRunbook(id: id)
    }

    /// ⌘K's own deep link into a saved link - it opens the page's own reader,
    /// not the system browser, because the palette is inside this app.
    func openReadingListLink(id: String) {
        show(.readingList)
        readingList.openReader(id: id)
    }

    /// ⌘K's own deep link into a notebook page.
    func openNotebookPage(id: String) {
        show(.notebook)
        notebook.openPage(id: id)
    }

    func openPostmortem(id: String) {
        show(.postmortems)
        postmortems.openPostmortem(id: id)
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
            self?.whiteboard.openDiagramComposer(prefill: hint)
        }
    }

    /// `open_sre_lead`: reveal a host's SRE Lead pane, or say why not.
    ///
    /// **This deliberately never connects a host that is not already
    /// connected**, and that restraint is what makes "a handoff writes
    /// nothing, so its link runs on a single click" literally true rather
    /// than approximately. Forking a real `/usr/bin/ssh` - and possibly
    /// prompting for Touch ID to materialise a key - is not navigation, and a
    /// model-authored link row is not where the captain should be asked for
    /// it. A host with no live session lands on the Hosts page, where Connect
    /// is their own deliberate click.
    ///
    /// **The app resolves which host, never the crew.** They cannot see hosts
    /// at all (`StrawHatCrew.persona`'s bounded-visibility rule), so a hint is
    /// only ever a name the captain themselves used earlier in the
    /// conversation. It is matched against the live-session registry - and
    /// refuses to choose between two rather than guessing, the same
    /// conservative shape `KubeContextParser`/`MultiHostSend` already use.
    ///
    /// Returns nil once the app has moved, or a message the crew's link row
    /// shows in place.
    func openSRELeadForCrew(hostHint: String?) -> String? {
        // **`isConnected`, not merely "in the registry"** - review #3's B16.
        // Since the two-state registry (#338) `sessions` also carries
        // `.restored` entries: a host page F2 brought back at launch, mounted
        // but deliberately never started, precisely so a relaunch does not
        // fork every saved host's `ssh` at once. Revealing one of those from a
        // one-click crew link is what makes its `viewDidAppear` fork the
        // connection - and prompt for Touch ID to materialise the key - which
        // is exactly the thing this method's own header says it will not do.
        // The header predates the registry gaining a second state; the
        // predicate is what makes it true again.
        let live = sessions.sessions.filter(\.isConnected)
        guard !live.isEmpty else {
            // Distinguished on purpose: "you have pages open but nothing is
            // actually connected" is a different thing to say than "you have
            // no host sessions", and only one of them is answered by opening
            // Hosts and pressing Connect on a row that is already there.
            show(.hosts)
            return sessions.sessions.isEmpty
                ? "You don't have a live host session right now - connect one from Hosts and ask me again."
                : "None of your host pages are connected right now - open one from Hosts and connect it, then ask me again."
        }

        let chosen: HostSession
        if let hint = hostHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            let needle = hint.lowercased()
            // Exact label first, then a unique substring - a host called
            // "prod" must not be ambiguous just because "prod-bastion" also
            // exists.
            let exact = live.filter { $0.label.lowercased() == needle }
            let partial = live.filter { $0.label.lowercased().contains(needle) }
            if let only = exact.first, exact.count == 1 {
                chosen = only
            } else if let only = partial.first, partial.count == 1 {
                chosen = only
            } else if partial.isEmpty {
                show(.hosts)
                // B16: a hint that matches a page which is open but not
                // connected gets its own answer rather than "I don't have a
                // session called that" - the captain can see that page in
                // Hosts, so denying it exists would read as a bug.
                let restoredMatch = sessions.sessions.contains {
                    !$0.isConnected && $0.label.lowercased().contains(needle)
                }
                return restoredMatch
                    ? "\u{201C}\(hint)\u{201D} is open but not connected - connect it from Hosts and ask me again."
                    : "I don't have a live session called \u{201C}\(hint)\u{201D} - here are your hosts."
            } else {
                show(.hosts)
                return "More than one live session matches \u{201C}\(hint)\u{201D}, so I'd rather you picked."
            }
        } else if live.count == 1, let only = live.first {
            chosen = only
        } else {
            show(.hosts)
            return "You have \(live.count) live sessions - pick the one you meant and I'll follow you there."
        }

        // Two distinct near-misses, kept distinct because saying "I opened it"
        // about a page that never appeared is the same kind of overclaim the
        // whole feature's honesty rules exist to prevent. A session can be in
        // the registry with no page behind it at all (`connectHost(navigate:
        // false)`, or an F2-restored entry), in which case `switchToSession`
        // is a documented no-op and nothing moved.
        guard let controller = hostConsoles[chosen.hostID] else {
            show(.hosts)
            return "I couldn't reach \u{201C}\(chosen.label)\u{201D}'s page - open it from Hosts and ask me again."
        }
        switchToSession(hostID: chosen.hostID)
        guard controller.openSRELeadFromCrewHandoff() else {
            return "I opened \u{201C}\(chosen.label)\u{201D}, but there was no tab there to start SRE Lead on."
        }
        AppLog.ai.info("straw hat: opened SRE Lead from a crew handoff")
        return nil
    }

    /// ⌘K landing actions for the two newest stores (audit §6.5b / §6.6b).
    ///
    /// Same shape as the two above: select the destination, then reveal the
    /// record. Selecting alone would leave the captain to hunt for the note
    /// or snippet they just searched for, which is the dead-end shape bug 4.3
    /// already corrected once for Recents.
    func openStickyNote(id: String) {
        show(.stickyBoard)
        stickyBoard.revealNote(id: id)
    }

    func openCodeSnippet(named name: String) {
        show(.codePreview)
        codePreview.openSnippet(named: name)
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
        commandLibrary.openCommand(id: id)
    }

    /// The command palette's send action for a command that needs no input -
    /// the identical call `shift.onSendCommandToTerminal` is wired to above,
    /// so both surfaces type into whichever console tab is in front. The risk
    /// gate runs *before* this (see `CommandRiskConfirmation`); this method is
    /// only the delivery half.
    func sendCommandToConsole(_ text: String) {
        console.sendCommandLibraryTextToActiveTab(text)
    }

    // MARK: Log Analyzer (`fm/grandline-log-analyzer-build`)

    /// ⌘⇧L / the Log Analyzer menu's "Open Log Analyzer" - switches to the
    /// destination and focuses its input so a paste lands immediately (spec
    /// §24's own success-criteria flow: ⌘⇧L → paste → ⌘↵).
    @objc func showLogAnalyzer() {
        show(.logAnalyzer)
        logAnalyzer.focusForPaste()
    }

    /// The clipboard quick action (spec §2).
    @objc func analyzeClipboardInLogAnalyzer() {
        show(.logAnalyzer)
        logAnalyzerCaptureSource = nil
        logAnalyzer.analyzeClipboard()
    }

    /// Spec §2's terminal bridge. Called from the app delegate, which owns
    /// the host consoles' `onAnalyzeLogs` closure - the capture decision
    /// itself is made in `ConsoleController` (which has the tab, its block
    /// tracker and its selection) via `LogTerminalCaptureBuilder`, so this
    /// only routes an already-built capture to the page.
    func openLogAnalyzer(with capture: LogTerminalCapture, hostLabel: String) {
        show(.logAnalyzer)
        logAnalyzer.importTerminalCapture(capture, hostLabel: hostLabel)
    }

    /// The remaining spec §24 shortcuts, all routed through the destination
    /// so they behave identically whether they came from the menu or the
    /// page's own buttons.
    @objc func logAnalyzerCopyAnalysis() { showThenRun { $0.menuCopyAnalysis() } }
    @objc func logAnalyzerSendToTerminal() { showThenRun { $0.menuSendToTerminal() } }
    @objc func logAnalyzerInvestigateFurther() { showThenRun { $0.menuInvestigateFurther() } }
    @objc func logAnalyzerCreateRCA() { showThenRun { $0.menuCreateRCA() } }

    private func showThenRun(_ body: (LogAnalyzerController) -> Void) {
        show(.logAnalyzer)
        body(logAnalyzer)
    }

    /// Fix 5: a host save closes its own (separate) editor window
    /// immediately, so the confirmation has to live somewhere that's still
    /// around afterward - the main window, regardless of which destination
    /// happens to be showing.
    func showToast(_ message: String) {
        Toast.show(in: view, message: message)
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
        dictation.setEngineStatus(status)
        homeCanvas.applyDictationStatus(status)
    }

    /// Fix 1: does for every host page what `AppDelegate.applicationWillTerminate`
    /// already does for the shared Firstmate `console` - tear down its
    /// materialized SSH keys and SRE Lead sessions on quit, not just the
    /// destination that happened to be visible.
    func shutdownAllHostConsoles() {
        for controller in hostConsoles.values { controller.shutdown() }
    }
}
