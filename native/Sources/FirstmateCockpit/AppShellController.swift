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
//   root
//   ├── DaylightBarController.view   (floating bar, pinned 14/22, height 50)
//   ├── HelmDrillHeader              (back button + tile + title; 0-height on
//   │                                 the canvas, which is the hub, not a spoke)
//   └── bodyContainer                (every destination, exactly as before)
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

    /// The back affordance every drill page gets, owned here rather than by
    /// each destination - see `HelmDrillHeader`'s own header for why that is
    /// the right level, and why per-page header restyling is Phase 4.
    private let drillHeader = HelmDrillHeader()
    /// Toggled between 0 and `HelmDrillHeader.height`. Collapsing needs both
    /// this *and* `isHidden`: an ordinary hidden `NSView`'s constraints still
    /// participate fully in Auto Layout (AGENTS.md gotcha (11)).
    private var drillHeaderHeightConstraint: NSLayoutConstraint!
    /// What the drill header was last pointed at, so a page whose live numbers
    /// changed can have its subtitle re-read without the shell having to work
    /// out which destination is showing all over again.
    private var lastDrillContext: (title: String, subtitle: String, symbol: String,
                                   hue: HelmDomainHue, controller: NSViewController?)?

    /// The hub. Owns the space filter and the module grid; knows nothing about
    /// navigation beyond the closures wired below.
    private let homeCanvas: HomeCanvasController

    private let hostsPanel: HostsController
    private let console: ConsoleController
    private let settings: SettingsController
    private let overview: FleetController
    private let shift: ShiftController
    private let review = ReviewController()
    /// `fm/grandline-log-analyzer-build`: the Log / Output Analyzer page.
    /// Owns its own `CommandLibraryStore`/`DocsRunbookStore`/
    /// `LogAnalyzerStore`, so this controller needs to know nothing about
    /// any of them - the same forward-don't-own convention every other
    /// destination here follows.
    private let logAnalyzer: LogAnalyzerController
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
    private let vault = VaultController()
    private let dictation: DictationController
    private let videoGen = VideoGenController()
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
    private let postmortems = PostmortemsController()
    private let updates = UpdatesController()
    private let bootstrap: BootstrapController
    private let automation: AutomationController
    private let githubSync = GitHubSyncController()
    /// fm/grandline-design-fidelity-fixes: the four pages above are one Setup
    /// destination with a `HelmSegmentedTabs` row across the top, so the
    /// captain can move between them without going back out to the rail's
    /// Setup flyout. They are still four independent `RailDestination` cases
    /// and four independent controllers - this only parents them and switches
    /// which one is visible. See `SetupContainerController`.
    private var setup: SetupContainerController!

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
    private lazy var mounter = DestinationMounter { [unowned self] controller in
        self.addChild(controller)
        self.embed(controller.view)
    }

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
    var onDictationShortcutChanged: ((DictationShortcut) -> Void)? {
        get { dictation.onShortcutChanged }
        set { dictation.onShortcutChanged = newValue }
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
        self.overview = FleetController(shiftStore: shiftStore)
        self.dictation = DictationController(store: dictationStore)
        // Phase 5 (cockpit-shift-power-features): `shiftStore` is now built
        // once by the app delegate and shared with the menu bar item, the
        // search palette, and quick capture - all of which need to read/
        // write the same tasks/follow-ups this page shows, not a second
        // independent store instance.
        self.shift = ShiftController(store: shiftStore, commandLibraryStore: commandLibraryStore)
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
        self.homeCanvas = HomeCanvasController(sources: .init(
            shiftStore: shiftStore,
            hostStore: hostStore,
            scheduleStore: scheduleStore,
            logAnalyzerStore: LogAnalyzerStore(),
            docsRunbookStore: DocsRunbookStore()))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1220, height: 720))
        root.wantsLayer = true
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
        bar.onSelectSettings = { [weak self] in self?.show(.settings) }
        bar.onLogoutRequested = { [weak self] in self?.onLogoutRequested?() }

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bodyContainer)

        drillHeader.onBack = { [weak self] in self?.show(.homeCanvas) }
        bodyContainer.addSubview(drillHeader)
        // Phase 4 ("Knowledge and speed") superseded Fix 4's original mapping
        // here (an in-terminal find stand-in, since there was no real global
        // search yet) - the topbar Search pill (and its `⌘K` badge) now opens
        // the real unified search palette, forwarded to the app delegate via
        // `onSearchTapped` (see that property's own doc comment) rather than
        // owned by this controller. Plain find-in-terminal is unaffected -
        // it's still reachable via the console toolbar's own magnifying-glass
        // icon (`ConsoleController.showFind`) and the Edit menu's `⌘F`.
        bar.onSearchTapped = { [weak self] in self?.onSearchTapped?() }

        // The four Setup pages become children of `setup`, not of this
        // controller - `SetupContainerController.loadView` calls `addChild`
        // for each of them, which means none of the four runs its own
        // `loadView` until the Setup slot itself is first mounted.
        setup = SetupContainerController(updates: updates, bootstrap: bootstrap,
                                         automation: automation, githubSync: githubSync)
        setup.onTabSelected = { _ in
            // Nothing to follow any more. Before Daylight this moved the rail
            // highlight; the drill header keeps saying "Setup" (all four pages
            // share one slot and one title) and the tab row directly below it
            // is what names the active sub-page, exactly as Hosts already does
            // for its own three tabs.
        }

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
        mounter.register(DestinationSlot(id: .homeCanvas, title: RailDestination.homeCanvas.bodyTitle, mountsEagerly: true, controller: homeCanvas))
        mounter.register(DestinationSlot(id: .overview, title: RailDestination.overview.bodyTitle, mountsEagerly: true, controller: overview))
        mounter.register(DestinationSlot(id: .console, title: RailDestination.console.bodyTitle, mountsEagerly: true, controller: console))
        mounter.register(DestinationSlot(id: .hosts, title: RailDestination.hosts.bodyTitle, mountsEagerly: false, controller: hostsPanel))
        mounter.register(DestinationSlot(id: .shift, title: RailDestination.shift.bodyTitle, mountsEagerly: false, controller: shift))
        mounter.register(DestinationSlot(id: .review, title: RailDestination.review.bodyTitle, mountsEagerly: true, controller: review))
        mounter.register(DestinationSlot(id: .logAnalyzer, title: RailDestination.logAnalyzer.bodyTitle, mountsEagerly: false, controller: logAnalyzer))
        mounter.register(DestinationSlot(id: .tools, title: RailDestination.tools.bodyTitle, mountsEagerly: false, controller: tools))
        mounter.register(DestinationSlot(id: .whiteboard, title: RailDestination.whiteboard.bodyTitle, mountsEagerly: false, controller: whiteboard))
        mounter.register(DestinationSlot(id: .vault, title: RailDestination.vault.bodyTitle, mountsEagerly: false, controller: vault))
        mounter.register(DestinationSlot(id: .dictation, title: RailDestination.dictation.bodyTitle, mountsEagerly: false, controller: dictation))
        mounter.register(DestinationSlot(id: .videoGen, title: RailDestination.videoGen.bodyTitle, mountsEagerly: false, controller: videoGen))
        mounter.register(DestinationSlot(id: .schedules, title: RailDestination.schedules.bodyTitle, mountsEagerly: false, controller: schedules))
        mounter.register(DestinationSlot(id: .health, title: RailDestination.health.bodyTitle, mountsEagerly: false, controller: health))
        mounter.register(DestinationSlot(id: .docs, title: RailDestination.docs.bodyTitle, mountsEagerly: false, controller: docs))
        mounter.register(DestinationSlot(id: .runbooks, title: RailDestination.runbooks.bodyTitle, mountsEagerly: false, controller: runbooks))
        mounter.register(DestinationSlot(id: .postmortems, title: RailDestination.postmortems.bodyTitle, mountsEagerly: false, controller: postmortems))
        mounter.register(DestinationSlot(id: .setup, title: RailDestination.updates.bodyTitle, mountsEagerly: false, controller: setup))
        mounter.register(DestinationSlot(id: .settings, title: RailDestination.settings.bodyTitle, mountsEagerly: false, controller: settings))

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

        drillHeaderHeightConstraint = drillHeader.heightAnchor.constraint(equalToConstant: HelmDrillHeader.height)

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

            drillHeader.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            drillHeader.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            drillHeader.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            drillHeaderHeightConstraint,
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
        // GL-31: Overview's unconfigured banner leads straight into the
        // Bootstrap stepper, which is where firstmate home is actually set.
        overview.onNavigateToSetup = { [weak self] in self?.show(.bootstrap) }
        // F12: the morning briefing's clause deep links. `show(_:)` and
        // `openShiftTask(id:)` are both already the one way this app navigates
        // to a destination / opens a task, so these are pass-throughs rather
        // than new behaviour.
        overview.onNavigateToDestination = { [weak self] dest in self?.show(dest) }
        overview.onOpenShiftTask = { [weak self] id in self?.openShiftTask(id: id) }
        // cockpit-settings-sudo-touchid: Settings' "Touch ID for sudo" row
        // runs `sudo av harden sudo`, which needs a real interactive `sudo`
        // prompt exactly like Bootstrap's provisioning actions - same
        // one-shot Console command-tab mechanism, just reached from Settings
        // instead.
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
        // fm/grandline-videogen-feasibility-scout: the video model's one-time
        // ~27GB/~15-minute setup needs the same real, visible Console tab
        // every other multi-gigabyte/long-running action in this app uses -
        // see `VideoGenEnvironment.swift`'s header for the full reasoning.
        // The tracked completion is what lets the Video page re-check its
        // own on-disk state the moment the Console tab's command exits,
        // instead of only on the page's own next `viewWillAppear`.
        videoGen.onRunCommand = { [weak self] label, command in self?.runInConsole(label: label, command: command) }
        videoGen.onRunCommandTracked = { [weak self] label, command, completion in
            self?.runInConsole(label: label, command: command, completion: completion)
        }
        // fm/grandline-devops-command-library-phase2: the Command Library's
        // "Send to Terminal" types straight into whichever console tab is
        // currently in front - not a new one-shot command tab (`runInConsole`
        // above), the exact same "type this into the active tab" behavior
        // Snippets' own "Run" already uses.
        shift.onSendCommandToTerminal = { [weak self] text in self?.console.sendCommandLibraryTextToActiveTab(text) }
        // F9 (v1): straight up to the app delegate - see `onSendCommandToHosts`.
        shift.onSendCommandToHosts = { [weak self] command, values, generated in
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

        review.onOpenPRCountChanged = { [weak self] count in
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
        console.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // Setup's header line is per-tab (§7's four tabs count entirely
        // different things), so it moves both when a sub-page's own numbers
        // change and when the captain switches tabs - `select(tab:)` fires
        // this too.
        setup.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        schedules.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        logAnalyzer.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        vault.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // Docs' subtitle still tracks the Playbook's own real sync state; its
        // action cluster no longer changes while it's on screen now that the
        // runbook editor (and the per-tab switch that used to empty the
        // cluster for it) moved to `.runbooks`.
        docs.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        whiteboard.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        // Runbooks inherited Docs' old per-editor-state cluster: "New
        // Runbook" beside a form already creating one is a second, competing
        // action, so its cluster empties while the editor is open.
        runbooks.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
        runbooks.onDrillActionsChanged = { [weak self] in self?.refreshDrillHeaderActions() }
        postmortems.onDrillSubtitleChanged = { [weak self] in self?.refreshDrillHeaderSubtitle() }
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
        // The Console module's peek rows. A closure, so the canvas never holds
        // a console or learns what a tab is.
        homeCanvas.consoleTabsProvider = { [weak self] in
            guard let self else { return [] }
            return self.console.tabs.map { tab in
                HelmModulePeekRow(state: tab.terminal.process.running ? .ok : .idle,
                                  text: tab.name,
                                  value: tab.terminal.process.running ? "live" : "exited")
            }
        }
        homeCanvas.connectedHostIDs = { [weak self] in
            guard let self else { return [] }
            return Set(self.hostConsoles.keys)
        }

        // GL-31: a machine with no firstmate home resolved lands on Setup, not
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
        NSLayoutConstraint.activate([
            destinationView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            destinationView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            destinationView.topAnchor.constraint(equalTo: drillHeader.bottomAnchor),
            destinationView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])
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
    private func reassertBodyContainerWidthTie() {
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
        if !needsLayout, bodyContainerWidthIsStale() {
            needsLayout = true
        }
        guard needsLayout else { return }
        view.layoutSubtreeIfNeeded()
    }

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
    var drillHeaderForTests: HelmDrillHeader { drillHeader }
    var drillHeaderHeightForTests: CGFloat { drillHeaderHeightConstraint.constant }
    var drillHeaderIsHiddenForTests: Bool { drillHeader.isHidden }
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
        hideAllDestinations()

        // GL-37: one table lookup replaces the fifteen-case switch this used
        // to be (and the matching line-per-destination in
        // `hideAllDestinations`). The slot is mounted here if this is its
        // first visit - see `DestinationRegistry.swift`.
        guard let slot = mounter.show(dest.slot) else { return }

        // The one destination-specific step left: four rail destinations
        // share the Setup slot, and which of them the captain asked for
        // decides the segmented tab, not the body view.
        if slot.id == .setup, let tab = SetupTab(destination: dest) {
            setup.select(tab: tab)
        }

        applyDrillHeader(title: slot.title,
                         subtitle: dest.drillSubtitle,
                         symbol: dest.symbol,
                         hue: dest.domainHue,
                         isCanvas: slot.id == .homeCanvas,
                         slotController: slot.controller)

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

        // §8 Phase 6: which destination is showing decides where the bar's
        // chain hands off, so the loop is re-derived on every navigation.
        updateKeyViewLoop()
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
        chain.last?.nextKeyView = firstBodyKeyView()
        if window.initialFirstResponder == nil { window.initialFirstResponder = chain.first }
    }

    /// The first thing below the bar the keyboard should reach: the drill
    /// header's back button on a drill page (it is the affordance out of
    /// there, and the topmost control), else the showing destination's own
    /// first focusable view - which on the canvas is its first module card.
    private func firstBodyKeyView() -> NSView? {
        if !drillHeader.isHidden, let inHeader = Self.firstKeyView(in: drillHeader) {
            return inHeader
        }
        guard let body = visibleDestinationView() else { return nil }
        return Self.firstKeyView(in: body)
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

    /// Daylight §6.4: point the shell's drill header at whatever is showing,
    /// or collapse it entirely on the canvas (the hub has no "back").
    ///
    /// Collapsing sets both `isHidden` *and* the height to 0 - AGENTS.md
    /// gotcha (11): an ordinary hidden `NSView`'s constraints still
    /// participate fully in Auto Layout, so hiding alone would leave a
    /// `HelmDrillHeader.height` gap above the canvas.
    private func applyDrillHeader(title: String, subtitle: String, symbol: String,
                                  hue: HelmDomainHue, isCanvas: Bool,
                                  slotController: NSViewController?) {
        drillHeader.isHidden = isCanvas
        drillHeaderHeightConstraint.constant = isCanvas ? 0 : HelmDrillHeader.height
        guard !isCanvas else { return }
        let page = slotController as? DaylightDrillActions
        drillHeader.configure(title: title,
                              subtitle: page?.drillHeaderSubtitle ?? subtitle,
                              symbol: symbol, hue: hue)
        // §6.4's action cluster. Asked of the destination rather than switched
        // on here, so migrating a page in a later slice is one conformance on
        // that page and no edit to the shell - and a page that has not been
        // migrated yet answers `nil`, which clears the cluster rather than
        // leaving the previous page's buttons showing.
        drillHeader.setActions(page?.drillHeaderActions ?? [])
        lastDrillContext = (title, subtitle, symbol, hue, slotController)
    }

    /// Re-read the showing page's own live subtitle (§6.4). Called by a
    /// migrated destination whose numbers just changed - never by the header.
    func refreshDrillHeaderSubtitle() {
        guard let context = lastDrillContext, !drillHeader.isHidden else { return }
        let page = context.controller as? DaylightDrillActions
        drillHeader.configure(title: context.title,
                              subtitle: page?.drillHeaderSubtitle ?? context.subtitle,
                              symbol: context.symbol, hue: context.hue)
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
        guard let context = lastDrillContext, !drillHeader.isHidden else { return }
        let page = context.controller as? DaylightDrillActions
        drillHeader.setActions(page?.drillHeaderActions ?? [])
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
        homeCanvas.select(space: space)
        show(.homeCanvas)
    }

    /// The canvas itself, for a caller that wants the hub without changing
    /// the space (the app delegate's launch landing).
    @objc func showHomeCanvas() { show(.homeCanvas) }

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
            controller.view.isHidden = true
        }
        controller.connectSSHIfNeeded(
            label: host.label, args: args, accentHex: host.accentHex,
            keyID: host.keyID, startupSnippetID: host.startupSnippetID,
            blockViewOptIn: host.blockViewOptIn
        )

        // `fm/grandline-session-switcher`: this host now has a live session.
        // Idempotent, and re-called on every connect for the same reason the
        // closures below are reassigned - a renamed host or a recoloured
        // accent should be current on the strip without needing a reconnect.
        sessions.register(hostID: host.id, label: host.label, accentHex: host.accentHex)

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
                controller.view.isHidden = false
                self.applyDrillHeader(title: hostLabel, subtitle: "Dedicated host page",
                                      symbol: RailDestination.hosts.symbol,
                                      hue: RailDestination.hosts.domainHue, isCanvas: false,
                                      slotController: controller)
                self.activeHostID = hostID
                controller.selectAndFocusTab(id: tab.id)
            }
        }

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
    func isHostConnected(_ host: Host) -> Bool {
        hostConsoles[host.id] != nil
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
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + ConsoleController.remoteShellReadyDelay) { [weak controller] in
                controller?.sendCommandLibraryTextToActiveTab(text)
            }
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
        hideAllDestinations()
        controller.view.isHidden = false
        applyDrillHeader(title: label, subtitle: "Dedicated host page",
                         symbol: RailDestination.hosts.symbol,
                         hue: RailDestination.hosts.domainHue, isCanvas: false,
                         slotController: controller)
        activeHostID = hostID
        sessions.setActive(hostID)
        controller.focusCurrentTab()
        controller.markCurrentTabAsRead()
        updateKeyViewLoop()
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
        let alert = NSAlert()
        alert.messageText = "End the session on \(session.label)?"
        alert.informativeText = "Anything still running in that terminal will be terminated."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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
        let visible = !registry.isEmpty
        sessionStrip.isHidden = !visible
        sessionStripHeightConstraint.constant = visible ? SessionStripView.height : 0
        bodyTopConstraint.constant = DaylightBarController.reservedTopHeight
            + (visible ? SessionStripView.gapBelowBar + SessionStripView.height : 0)
        // Rebuilding a hidden page's rows would be work nobody can see; it
        // gets them on its next `viewWillAppear` instead.
        if hostsPanel.isViewLoaded, !hostsPanel.view.isHidden {
            hostsPanel.refreshLiveSessionState()
        }
        updateKeyViewLoop()
    }

    private func hideAllDestinations() {
        // Only mounted slots have a view to hide - asking an unmounted one
        // for `controller.view` here would build it and defeat GL-37's whole
        // point. Host pages are tracked separately (they are not fixed
        // `RailDestination` cases) and were always lazily built.
        mounter.hideAll()
        for controller in hostConsoles.values where controller.isViewLoaded {
            controller.view.isHidden = true
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
    func openShiftTask(id: String) {
        show(.shift)
        shift.openTask(id: id)
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

    func openPostmortem(id: String) {
        show(.postmortems)
        postmortems.openPostmortem(id: id)
    }

    // MARK: Command palette navigation (F5)

    /// F5 (`fm/grandline-feature-f5-command-palette-expansion`): the command
    /// palette's action for a saved command that still needs a parameter
    /// filled in - switches to the Tasks destination's DevOps Commands tab
    /// and selects it, so the captain completes it on the real form (with its
    /// real Copy/Send buttons and their real risk gate) rather than the
    /// palette sending a half-substituted template.
    func openCommandLibraryCommand(id: String) {
        show(.shift)
        shift.openCommandLibraryCommand(id: id)
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
