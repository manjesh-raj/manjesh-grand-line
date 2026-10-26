// Grand Line - native macOS app.
//
// The window's root content view controller.
//
// **The floating bar is the classic layout, frozen (R2-ARCH-01).** The
// captain keeps both window layouts, and the sidebar is the default. This one
// is kept working and kept protected - its regression checks stay - but it
// receives no new features and no page redesigns: new chrome is built for the
// sidebar layout only, and Settings says so where the layout is chosen
// ("Floating bar (classic)", maintenance only). The freeze is recorded in
// `docs/modular-shell/feature-inventory.md`. A fix to something this layout
// already does still belongs here.
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
//
// **Stage 2 of the modular-shell migration split this controller in two**
// (full review section 5.8, step 2). What a shell *hosts* moved to
// `Workspace` and its parts - the pages and stores, `WorkspaceContent` (the
// body area and the mounter), `Navigator` (every route), `HostSessionCoordinator`
// (host pages and live sessions), `LockPresenter` and `CaptureFilingService` -
// so the split-view shell that step 3 builds can host the same pages. What is
// left here is the floating-bar shell's own chrome: the bar, the session
// strip, the drill header's wiring, the scroll edge, the window's
// width-tie repair and the keyboard loop. Every method the app delegate and
// the suites call on this controller still exists, and forwards to the part
// that now does the work (see "The workspace's API, forwarded"), so nothing
// that called the shell had to change.
//
// **Stage 3 made this the floating-bar layout, one of two.** The API that
// forwards to the workspace, the window's ground and the chrome text scale
// moved up into `WorkspaceShellController`, which this class and the
// split-view `MainSplitShellController` both extend. This file keeps only
// what draws the floating bar: the bar, the session strip, the drill header,
// the space pills, the quick-access row, the scroll edge, the width-tie
// repair and the keyboard loop. It is still the default layout, and nothing
// it draws changed.


import AppKit
import LocalAuthentication

final class AppShellController: WorkspaceShellController {

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

    /// The persistent pill strip, docked under the bar. Visible only while at
    /// least one session is live, and collapsed to height 0 as well as hidden
    /// when it is not - an ordinary hidden `NSView`'s constraints still
    /// participate fully in layout (AGENTS.md gotcha (11)), so hiding alone
    /// would leave a permanent gap above every destination.
    private let sessionStrip = SessionStripView()
    private var sessionStripHeightConstraint: NSLayoutConstraint!
    private var bodyTopConstraint: NSLayoutConstraint!

    /// The body area the workspace's pages are mounted into, pinned under
    /// this shell's floating bar.
    private var bodyContainer: NSView { workspace.content.bodyContainer }

    override func loadView() {
        // T-14d: everything below, including the eager destinations' own
        // `loadView`s (`mounter.mountEagerSlots()`), is one launch interval.
        let loadViewInterval = LaunchSignposts.begin("AppShellController.loadView")
        defer { LaunchSignposts.end("AppShellController.loadView", loadViewInterval) }
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
        // to paint - and a chrome-text-scale change repaints the whole app.
        // Both moved to `WorkspaceShellController` in stage 3, because the
        // sidebar shell needs exactly the same two; see that method for the
        // reasoning, which is unchanged.
        paintGroundAndFollowTextScale()

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
        bar.onSelectDestination = { [weak self] destination in self?.workspace.navigator.show(destination) }
        bar.onSelectSettings = { [weak self] in self?.workspace.navigator.show(.settings) }
        bar.onLogoutRequested = { [weak self] in self?.onLogoutRequested?() }
        // `fm/grandline-recents-navigation`: the Recents popover reads this
        // controller's own registry and dispatches a click back through
        // whichever navigation primitive already handles that kind - never a
        // third path.
        bar.recentDestinations.configure(registry: workspace.navigator.recentDestinations) { [weak self] kind in
            self?.workspace.navigator.navigateToRecentDestination(kind)
        }

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bodyContainer)

        bar.onDrillBack = { [weak self] in self?.workspace.navigator.show(.homeCanvas) }
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
        bar.onSearchTapped = { [weak self] in self?.workspace.onSearchTapped?() }
        // F7: the chip is the feature's "it follows you off the Tasks page"
        // half, so the bar gets the timer as soon as both exist.
        bar.attachFocusTimer(workspace.focusTimer)

        // GL-37: the destination table - see `Workspace.registerDestinations`,
        // which holds the one `register(...)` line per body view this method
        // used to carry.
        workspace.registerDestinations()

        // Built here, before the window is ever shown, for the three
        // invariants `DestinationRegistry.swift` documents (a live PTY, and
        // two launch-seeded rail badges that render through their own
        // views). Every other slot waits for its first `show(_:)`.
        workspace.content.mounter.mountEagerSlots()

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
        sessionStrip.onSelect = { [weak self] id in self?.workspace.hosts.switchToSession(hostID: id) }
        sessionStrip.onClose = { [weak self] id in self?.workspace.hosts.confirmEndSession(hostID: id) }
        sessionStrip.onAddRequested = { [weak self] in self?.workspace.navigator.show(.hosts) }
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
            guard let self, let window = note.object as? NSWindow, window === self.view.window else { return }
            self.reassertBodyContainerWidthTie()
            self.workspace.windowOverflowGuard.windowDidResize(window)
        }

        // The four eager pages' wiring, then the launch landing - both moved
        // to `Workspace` with the pages, and run from exactly here.
        workspace.wireEagerPages()
        workspace.showLaunchLanding()

        // Added last (and therefore topmost in z-order) so it covers the bar
        // as well as the body area - see `LockPresenter.install`.
        workspace.lock.install(in: self, over: root)
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
        guard let destination = workspace.content.visibleDestinationView() else { return false }
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

    // MARK: Test hooks
    //
    // The hooks every shell answers - the body container, the mounted
    // slots, the pages - moved to `WorkspaceShellController` in stage 3.
    // What is left here reads the floating bar's own chrome.

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
        workspace.content.visibleDestinationView()?.frame.width
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
        guard let destination = workspace.content.visibleDestinationView() else { return }
        var frame = destination.frame
        frame.size.width = width
        destination.frame = frame
    }

    #if FM_SELFTESTS
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
    /// A3's state, as the bar currently has it.
    var scrollEdgeActiveForTests: Bool { bar.scrollEdgeActiveForTests }
    var scrollEdgeWatchedForTests: [NSScrollView] { scrollEdge.watchedForTests }
    /// The bar itself, for a check on its own controls (UXP-01's search
    /// pill floor) under a drill context the suite chooses.
    var barForTests: DaylightBarController { bar }
    #endif

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
        guard let body = workspace.content.visibleDestinationView() else { return nil }
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

    /// A space pill was picked (or ⌘1-⌘5): light the pill, then let the base
    /// class land on the canvas and filter it - the same order this ran in
    /// before stage 3 moved the canvas half up.
    override func selectSpace(_ space: DaylightSpace) {
        bar.setSelectedSpace(space)
        super.selectSpace(space)
    }

    // MARK: The configurable quick-access row (UX1/UX2)

    /// The floating bar's shortcut row is this shell's drawing of the pins.
    /// `WorkspaceShellController.toggleQuickAccessPin` is still the one write
    /// path; this is what it calls once the setting is written.
    override func quickAccessDidChange(_ configuration: QuickAccessConfiguration) {
        bar.setQuickAccess(configuration)
    }

    // MARK: Clipboard history (F3)

    /// The panel and its store live on the bar (see
    /// `DaylightBarController.clipboardHistory`), which decides where it
    /// drops down from. ⌘⇧V, the quit-time drain and the capture loop are the
    /// base class's.
    override var clipboardHistoryController: ClipboardHistoryController? { bar.clipboardHistory }

    /// Every registry change lands here: the strip re-renders and shows or
    /// collapses, and the Hosts list's rows are rebuilt so a row that just
    /// went live (or just died) reads correctly the moment it is looked at.
    private func applySessionRegistry(_ registry: HostSessionRegistry) {
        guard isViewLoaded, sessionStripHeightConstraint != nil else { return }
        sessionStrip.render(registry)
        applySessionStripVisibility()
        workspace.refreshShowingHostsLiveSessionState()
        updateKeyViewLoop()
    }

    /// Whether the strip is showing, and how much room it takes. The strip
    /// makes a live session reachable "from anywhere"
    /// (`docs/history/03-navigation-and-chrome.md`), so it shows on every
    /// page whenever there is one.
    private func applySessionStripVisibility() {
        guard isViewLoaded, sessionStripHeightConstraint != nil else { return }
        let visible = !workspace.hosts.sessions.isEmpty
        sessionStrip.isHidden = !visible
        sessionStripHeightConstraint.constant = visible ? SessionStripView.height : 0
        bodyTopConstraint.constant = DaylightBarController.reservedTopHeight
            + (visible ? SessionStripView.gapBelowBar + SessionStripView.height : 0)
    }

    /// The Hosts sidebar's user row, routed into the bar's own single logout
    /// confirmation rather than a second copy of it.
    override func requestLogout() { bar.requestLogout() }

    // MARK: WorkspaceChrome - what this shell draws when the workspace navigates

    /// `show(_:)`'s chrome half, in the order it has always run: the drill
    /// header, the scroll edge, then the space pill.
    override func workspaceDidShow(_ dest: RailDestination, slot: DestinationSlot) {
        applyDrillHeader(title: slot.title,
                         subtitle: dest.drillSubtitle,
                         symbol: dest.symbol,
                         hue: dest.domainHue,
                         artwork: dest.drillHeaderArtwork,
                         isTopLevel: slot.id == .homeCanvas,
                         slotController: slot.controller)

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
            // and both the drill-header back button and `show(.homeCanvas)`
            // reach it through `show(_:)` rather than `selectSpace`. Without
            // this the pill kept asserting the drill page's space while the
            // canvas rendered the space the captain last chose - B5's own
            // failure ("a highlight that asserts the wrong location is worse
            // than none") one navigation later. The canvas owns that state, so
            // this reads it rather than keeping a second copy.
            bar.setSelectedSpace(workspace.homeCanvas.selectedSpace)
        }

        // B2: the bar's lit shortcut is pushed from
        // `workspaceCurrentDestinationDidChange`, the one call every
        // navigation route makes - not from here, which the SRE Lead
        // reply-jump bypasses.
    }

    /// A host page's chrome: the drill header names the host, and the scroll
    /// edge is re-pointed (a host console has no page scroll view, so this
    /// correctly clears the edge rather than leaving the previous page's
    /// state).
    override func workspaceDidRevealHostPage(_ controller: ConsoleController, label: String) {
        applyDrillHeader(title: label, subtitle: "Dedicated host page",
                         symbol: RailDestination.hosts.symbol,
                         hue: RailDestination.hosts.domainHue, isTopLevel: false,
                         slotController: controller)
        retargetScrollEdge(to: controller.view)
    }

    /// B2: light the bar square for this page, and darken whichever was lit
    /// before. A host page is not a `RailDestination`, so no square stands for
    /// it and it clears the bar.
    override func workspaceCurrentDestinationDidChange(_ kind: RecentDestinationKind) {
        if case .rail(let dest) = kind {
            bar.setActiveDestination(dest)
        } else {
            bar.setActiveDestination(nil)
        }
    }

    override func workspaceSubtitleMayHaveChanged() { refreshDrillHeaderSubtitle() }

    override func workspaceActionsMayHaveChanged() { refreshDrillHeaderActions() }

    override func workspaceSessionsDidChange(_ registry: HostSessionRegistry) { applySessionRegistry(registry) }

    override func workspaceKeyViewLoopMayHaveChanged() { updateKeyViewLoop() }
}
