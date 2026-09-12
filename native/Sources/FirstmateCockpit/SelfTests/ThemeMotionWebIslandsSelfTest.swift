// Manjesh Grand Line - native macOS app.
//
// The UI modernization audit's §3K, §3L and §3M - the last round of that
// rollout: Dusk as the daily theme (K1), the theme crossfade (K3), the motion
// spec's one remaining gap (L), and the two web-island seam-hiders (M1, M2).
//
// K2's own substance is a set of measured contrast ratios, so it lives in
// `HelmContrastSelfTest.checkTerminalCard` instead - that suite is where every
// other palette measurement in this app is re-run, and a palette check that
// sat somewhere else would be the one nobody thinks to extend. (Both suites
// are window-backed and both therefore run in the same `--session-only` lane;
// there is no CI-lane difference between them.)
//
// What is asserted, and what deliberately is not. §3L is a motion spec, and a
// check that measures an animation's *duration* is taste: it only ever fails
// for the wrong reason. So this spends its assertions on the things that can
// silently stop working, several of which render perfectly while broken:
//
//   1. **K1's default is Dusk, and a saved preference still wins.** The
//      second half matters more than the first: a fresh default that
//      overrode a stored choice would silently discard a decision the
//      captain already made, which is a real defect rather than a new
//      default.
//   2. **K3 takes a snapshot, fades it, and removes it.** A coordinator that
//      applies the theme and forgets the overlay leaves a frozen picture of
//      the *old* theme permanently on top of the app - the worst possible
//      failure, and invisible to every colour check, because every layer
//      underneath is correct.
//   3. **K3 is interruptible and never stacks.** Two changes inside the fade
//      window must leave exactly one overlay.
//   4. **K3 skips a page with visible web content**, and only when it is
//      genuinely visible. Every destination in this app is mounted once and
//      then only hidden (GL-37), so a guard that vetoed on mere presence
//      would disable the crossfade app-wide after one visit to the
//      Whiteboard.
//   5. **K3 applies the theme on every path**, including the ones that skip
//      the animation. An early return that forgot `apply` would be a theme
//      picker that does nothing.
//   6. **L's two shared primitives set a curve.** `HelmMotion.fade` and
//      `.animate` are what most of this app's motion runs through, and they
//      took AppKit's default ease-in-ease-out - which is literally §3L's
//      headline complaint ("No timing curves set (default ease)").
//   7. **M1's island tokens resolve from the theme and are actually sent.**
//      A literal hex here would be the one thing §6 forbids, and a mapping
//      that is correct but never reaches `setTheme` renders exactly like
//      today's app.
//   8. **M2's hairline exists and is driven by the relay**, with the boolean
//      re-derived through `ScrollEdgeObserver`'s own threshold so native and
//      web-hosted pages share one definition of "away from the top".
//
// Window-backed (K3 needs a real window to snapshot), so it is in
// `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// Run with:
//   swift build && FM_RUN_THEME_MOTION_WEB_ISLANDS_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import WebKit

enum ThemeMotionWebIslandsSelfTest {

    static func run() -> Bool {
        // `setTheme` persists to the real `UserDefaults` domain, and a suite
        // that leaves `fm.themeID` changed poisons every later suite in the
        // run (AGENTS.md: "the self-test suite is not hermetic").
        // `Phase3PolishSelfTest.checkSuitesRestoreTheTheme` fails the run if
        // this pair is missing.
        let restoreTheme = ThemeManager.shared.theme
        defer {
            ThemeManager.shared.transitionCoordinator = nil
            ThemeManager.shared.setTheme(restoreTheme)
            HelmMotion.reducedOverrideForTests = nil
        }
        var allOK = true
        for check in [checkDuskIsTheDefault,
                      checkThemeCrossfade,
                      checkCrossfadeSkipsWebIslands,
                      checkSharedMotionPrimitivesSetACurve,
                      checkExcalidrawIslandTokens,
                      checkMonacoScrollEdge] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "ThemeMotionWebIslandsSelfTest: all checks passed"
                    : "ThemeMotionWebIslandsSelfTest: FAILED")
        return allOK
    }

    // MARK: Helpers

    private static func sourceFile(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    /// Far off-screen: this machine may be running the captain's own
    /// instance, so nothing this suite builds should appear on his display.
    private static func makeWindow(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        // A window that was never ordered in is not `isVisible`, which the
        // coordinator checks before snapshotting - so ordering it front is
        // what makes this suite able to test the animated path at all.
        window.orderFront(nil)
        return window
    }

    private static func drainMain(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// A plain themed page, standing in for a destination.
    private static func makePage(background: NSColor) -> NSView {
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        page.wantsLayer = true
        page.layer?.backgroundColor = background.cgColor
        let label = NSTextField(labelWithString: "Grand Line")
        label.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: page.centerYAnchor),
        ])
        return page
    }

    private static func snapshotOverlays(in view: NSView) -> [NSImageView] {
        view.subviews.compactMap { $0 as? NSImageView }
    }

    // MARK: 1. K1 - Dusk is the daily theme

    private static func checkDuskIsTheDefault(_ ok: inout Bool) {
        print("\n-- K1: Dusk is the default, and a saved choice still wins --")

        if ThemeManager.fallbackTheme.id != "dusk" {
            print("  FAIL the no-preference fallback is \(ThemeManager.fallbackTheme.id), want dusk (K1, the captain's own decision)")
            ok = false
        } else {
            print("  OK   a fresh install lands on Dusk")
        }

        // The other thirteen stay selectable - K1 moved a default, it did not
        // retire a palette.
        if HelmTheme.allThemes.count != 14 {
            print("  FAIL \(HelmTheme.allThemes.count) themes registered, want 14 - K1 must not remove a palette")
            ok = false
        } else {
            print("  OK   all 14 palettes still registered")
        }

        // The load-bearing half: `init` must only reach the fallback when
        // there is genuinely nothing stored. Asserted as source, because
        // `ThemeManager` is a singleton whose `init` has already run by the
        // time any suite can observe it - there is no way to re-run it
        // against a seeded domain without a second instance, and the failure
        // worth catching (a default that overrides a stored choice) is a
        // change to this exact branch order.
        guard let source = sourceFile("ThemeManager.swift") else {
            print("  NOTE could not read ThemeManager.swift - skipping the precedence guard")
            return
        }
        let storedFirst = source.range(of: "UserDefaults.standard.string(forKey: Self.defaultsKey)")
        let fallbackUse = source.range(of: "theme = Self.fallbackTheme")
        guard let storedFirst, let fallbackUse, storedFirst.lowerBound < fallbackUse.lowerBound else {
            print("  FAIL ThemeManager.init must read the saved fm.themeID BEFORE falling back, or a new default silently discards the captain's own past choice")
            ok = false
            return
        }
        print("  OK   a stored fm.themeID is read before the fallback")
        if !source.contains("legacyMode == \"light\" ? .light : .dark") {
            print("  FAIL the legacy fm.themeMode migration is gone - a pre-themeID install would be reset rather than migrated")
            ok = false
        } else {
            print("  OK   the legacy fm.themeMode preference is still honoured")
        }
    }

    // MARK: 2. K3 - the crossfade

    private static func checkThemeCrossfade(_ ok: inout Bool) {
        print("\n-- K3: snapshot, fade, remove - and apply on every path --")
        HelmMotion.reducedOverrideForTests = false

        let page = makePage(background: .red)
        let window = makeWindow(page)
        guard let content = window.contentView else {
            print("  FAIL the probe window has no content view")
            ok = false
            return
        }
        let coordinator = ThemeTransitionCoordinator(window: window)

        // A snapshot needs a genuinely visible window, and a process that
        // cannot establish one (some CI runners) would fail every assertion
        // below for the environment rather than for the code. Say so and hold
        // to the halves that do not need one, the way `WhiteboardViewSelfTest`
        // already does for its own uncapturable half - never pass silently.
        guard window.isVisible else {
            print("  NOTE this process cannot make a window visible, so the snapshot half cannot run here")
            var reducedApplied = 0
            coordinator.performThemeChange { reducedApplied += 1 }
            if reducedApplied != 1 {
                print("  FAIL the change ran \(reducedApplied) times, want exactly 1")
                ok = false
            } else {
                print("  OK   the theme change still applies with no window to snapshot")
            }
            checkCrossfadeWiringSource(&ok)
            return
        }

        var applied = 0
        coordinator.performThemeChange { applied += 1 }
        if applied != 1 {
            print("  FAIL the change ran \(applied) times, want exactly 1")
            ok = false
        }
        guard let overlay = coordinator.debugLiveOverlay else {
            print("  FAIL no snapshot was taken - there is nothing to fade from")
            ok = false
            return
        }
        print("  OK   a snapshot was taken and the change applied once")

        // A picture of something, not an empty rect: an overlay with no image
        // fades nothing and would pass a mere existence check.
        guard let image = overlay.image, image.size.width >= 1, image.size.height >= 1 else {
            print("  FAIL the snapshot overlay carries no image")
            ok = false
            return
        }
        if overlay.superview !== content {
            print("  FAIL the overlay is not in the content view")
            ok = false
        }
        if content.subviews.last !== overlay {
            print("  FAIL the overlay is not the topmost subview - the new theme would render on top of the picture it is fading from")
            ok = false
        } else {
            print("  OK   the overlay is topmost, over the freshly re-themed tree")
        }
        // And it must not swallow the captain's next click: a 200ms window in
        // which the whole app is dead is a real defect, and one that no
        // colour or geometry check can see.
        if !coordinator.debugOverlayIsHitTestTransparent {
            print("  FAIL the snapshot overlay is not hit-test transparent - every click during the fade would land on a picture")
            ok = false
        } else {
            print("  OK   the overlay is transparent to the mouse")
        }

        // Interruptible: a second change inside the fade window must leave
        // exactly one overlay, not a stack of them.
        coordinator.performThemeChange { applied += 1 }
        let live = snapshotOverlays(in: content)
        if live.count != 1 {
            print("  FAIL \(live.count) snapshot overlays after a second change inside the fade window, want 1")
            ok = false
        } else {
            print("  OK   a change mid-fade replaces the snapshot rather than stacking")
        }

        // And it goes away. This is the failure that matters most: a
        // coordinator that forgets its overlay leaves a frozen picture of the
        // old theme permanently on top, with every layer underneath correct.
        drainMain(ThemeTransitionCoordinator.duration + 0.25)
        if !snapshotOverlays(in: content).isEmpty {
            print("  FAIL the snapshot overlay is still there after the fade - the app is stuck showing the old theme")
            ok = false
        } else {
            print("  OK   the overlay removes itself once faded")
        }
        if coordinator.debugLiveOverlay != nil {
            print("  FAIL the coordinator still holds a faded overlay")
            ok = false
        }

        // Reduce Motion: the end state instantly, and still applied. Never
        // the same motion, slower (`HelmMotion`'s own rule).
        HelmMotion.reducedOverrideForTests = true
        var reducedApplied = 0
        coordinator.performThemeChange { reducedApplied += 1 }
        if reducedApplied != 1 {
            print("  FAIL Reduce Motion: the change ran \(reducedApplied) times, want exactly 1")
            ok = false
        }
        if coordinator.debugLiveOverlay != nil || !snapshotOverlays(in: content).isEmpty {
            print("  FAIL Reduce Motion took a snapshot - the end state has to arrive instantly, with no picture to cross-fade")
            ok = false
        } else {
            print("  OK   Reduce Motion applies instantly with no snapshot")
        }
        HelmMotion.reducedOverrideForTests = false

        // A theme change before there is a window to snapshot still has to
        // change the theme.
        let orphan = ThemeTransitionCoordinator(window: NSWindow())
        var orphanApplied = 0
        orphan.performThemeChange { orphanApplied += 1 }
        if orphanApplied != 1 {
            print("  FAIL an unsnapshotable window: the change ran \(orphanApplied) times, want exactly 1")
            ok = false
        } else {
            print("  OK   an unsnapshotable window still gets the theme change")
        }

        // And the choke point is actually wired: `setTheme` must route
        // through the coordinator when one is installed. Behavioural, because
        // a coordinator that is never called is a crossfade nobody sees.
        ThemeManager.shared.transitionCoordinator = coordinator
        let other = ThemeManager.shared.theme.id == "dusk" ? HelmTheme.daylight : HelmTheme.dusk
        ThemeManager.shared.setTheme(other)
        if ThemeManager.shared.theme.id != other.id {
            print("  FAIL setTheme did not change the theme while a coordinator was installed")
            ok = false
        } else if coordinator.debugLiveOverlay == nil {
            print("  FAIL setTheme did not route through the transition coordinator - K3's choke point is unwired")
            ok = false
        } else {
            print("  OK   ThemeManager.setTheme routes through the coordinator")
        }
        ThemeManager.shared.transitionCoordinator = nil
        drainMain(ThemeTransitionCoordinator.duration + 0.2)
        window.orderOut(nil)

        checkCrossfadeWiringSource(&ok)
    }

    /// Where the coordinator is installed - the half that needs no window.
    ///
    /// Production wiring lives at the one place a self-test never reaches, so
    /// a window-backed suite that mounts a real shell and re-themes it is
    /// never measuring through a transient snapshot overlay.
    private static func checkCrossfadeWiringSource(_ ok: inout Bool) {
        guard let main = sourceFile("main.swift") else { return }
        if !main.contains("ThemeManager.shared.transitionCoordinator = ThemeTransitionCoordinator(window: window)") {
            print("  FAIL the coordinator is not installed at launch - K3 would never run in the real app")
            ok = false
        } else {
            print("  OK   installed from applicationDidFinishLaunching")
        }
        if let shell = sourceFile("AppShellController.swift"),
           shell.contains("transitionCoordinator =") {
            print("  FAIL AppShellController installs the coordinator: every window-backed suite that mounts a shell and re-themes it would then measure through a snapshot overlay")
            ok = false
        }
    }

    // MARK: 3. K3 - the web-island carve-out

    private static func checkCrossfadeSkipsWebIslands(_ ok: inout Bool) {
        print("\n-- K3: skipped for a visible web island, not for a hidden one --")
        HelmMotion.reducedOverrideForTests = false

        let page = makePage(background: .blue)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        page.addSubview(web)
        let window = makeWindow(page)
        let coordinator = ThemeTransitionCoordinator(window: window)

        var applied = 0
        coordinator.performThemeChange { applied += 1 }
        if applied != 1 {
            print("  FAIL a skipped transition must still apply the theme (ran \(applied) times)")
            ok = false
        }
        guard window.isVisible else {
            print("  NOTE this process cannot make a window visible; the veto's two directions need one to be distinguishable")
            checkWebContentPredicate(&ok)
            window.orderOut(nil)
            return
        }
        if coordinator.debugLiveOverlay != nil {
            print("  FAIL a visible WKWebView was snapshotted - cacheDisplay cannot capture web content, so the fade would flash a blank rectangle over the canvas")
            ok = false
        } else {
            print("  OK   a visible web view skips the crossfade, theme still applied")
        }

        // Hidden is the case that matters for the rest of the app: every
        // destination is mounted once and then only hidden, so vetoing on
        // mere presence would kill the crossfade for good after one visit to
        // the Whiteboard or Code Preview.
        web.isHidden = true
        window.contentView?.layoutSubtreeIfNeeded()
        coordinator.performThemeChange { applied += 1 }
        if coordinator.debugLiveOverlay == nil {
            print("  FAIL a HIDDEN web view still vetoed the crossfade - one visit to the Whiteboard would disable it app-wide")
            ok = false
        } else {
            print("  OK   a hidden web view does not veto the crossfade")
        }

        checkWebContentPredicate(&ok)

        drainMain(ThemeTransitionCoordinator.duration + 0.2)
        window.orderOut(nil)
    }

    /// The predicate itself, on the shapes that are easy to get wrong. Needs
    /// no window, so both paths above reach it.
    private static func checkWebContentPredicate(_ ok: inout Bool) {
        let nested = NSView()
        let inner = NSView()
        nested.addSubview(inner)
        inner.addSubview(WKWebView())
        if !ThemeTransitionCoordinator.containsVisibleWebContent(nested) {
            print("  FAIL a nested web view was not found - the walk has to be recursive")
            ok = false
        }
        let hiddenBranch = NSView()
        let hiddenInner = NSView()
        hiddenInner.isHidden = true
        hiddenInner.addSubview(WKWebView())
        hiddenBranch.addSubview(hiddenInner)
        if ThemeTransitionCoordinator.containsVisibleWebContent(hiddenBranch) {
            print("  FAIL a web view inside a hidden ANCESTOR counted as visible")
            ok = false
        } else {
            print("  OK   the walk is recursive and skips hidden subtrees")
        }
    }

    // MARK: 4. L - the shared primitives set a curve

    private static func checkSharedMotionPrimitivesSetACurve(_ ok: inout Bool) {
        print("\n-- L: the two shared motion primitives set the spec's ease-out --")
        guard let source = sourceFile("HelmMotion.swift") else {
            print("  NOTE could not read HelmMotion.swift")
            return
        }
        // §3L's headline complaint is "No springs anywhere. No timing curves
        // set (default ease)." Earlier rounds answered the springs and set a
        // curve at each new call site; `fade` and `animate` - which most of
        // this app's motion runs through - still took AppKit's default. A
        // source guard because `NSAnimationContext`'s timing function is not
        // readable back off a completed animation group.
        var bodies: [String: String] = [:]
        for name in ["fade", "animate", "animateLayers"] {
            guard let start = source.range(of: "static func \(name)(") else { continue }
            let rest = source[start.upperBound...]
            let end = rest.range(of: "\n    }") ?? rest.startIndex..<rest.startIndex
            bodies[name] = String(rest[rest.startIndex..<end.lowerBound])
        }
        for (name, body) in bodies.sorted(by: { $0.key < $1.key }) {
            if body.contains("context.timingFunction") {
                print("  OK   HelmMotion.\(name) sets a timing function")
            } else {
                print("  FAIL HelmMotion.\(name) sets no timing function - it takes AppKit's default ease, which is exactly what section 3L's spec is about")
                ok = false
            }
        }
        if bodies.count != 3 {
            print("  FAIL expected to find fade/animate/animateLayers, found \(bodies.count)")
            ok = false
        }
        // The spec's two curves still exist and are still two.
        if HelmMotion.springDuration <= 0 || HelmMotion.stateDuration <= 0 {
            print("  FAIL the spec's two durations are not both positive")
            ok = false
        }
        if ThemeTransitionCoordinator.duration != 0.2 {
            print("  FAIL the theme crossfade is \(ThemeTransitionCoordinator.duration)s, and section 3K states 200ms")
            ok = false
        } else {
            print("  OK   the crossfade is the report's stated 200ms")
        }
    }

    // MARK: 5. M1 - Excalidraw's island tokens

    private static func checkExcalidrawIslandTokens(_ ok: inout Bool) {
        print("\n-- M1: Excalidraw's island reads this app's own card tokens --")

        for theme in HelmTheme.allThemes {
            let tokens = WhiteboardController.islandTokens(for: theme)
            guard let bg = tokens["bg"], let radius = tokens["radius"], let shadow = tokens["shadow"] else {
                print("  FAIL \(theme.id): island tokens are incomplete")
                ok = false
                continue
            }
            // §6's constraint: "no literal hexes proposed" - every
            // recommendation routes through existing tokens. The fill has to
            // BE this theme's card, in all fourteen palettes, or the island
            // matches one of them and clashes with thirteen.
            if bg.lowercased() != "#" + theme.chromeBackgroundHex.lowercased() {
                print("  FAIL \(theme.id): island fill is \(bg), want this theme's chromeBackgroundHex")
                ok = false
            }
            if radius != "\(HelmMetrics.rCard)px" {
                print("  FAIL \(theme.id): island radius is \(radius), want HelmMetrics.rCard")
                ok = false
            }
            if !shadow.hasPrefix("0px ") || !shadow.contains("rgba(") {
                print("  FAIL \(theme.id): island shadow is not a CSS shadow: \(shadow)")
                ok = false
            }
        }
        print("  OK   all \(HelmTheme.allThemes.count) palettes resolve an island fill, radius and shadow")

        // A themed value that never reaches the page is invisible from every
        // other angle: the mapping can be perfect and the island unchanged.
        guard let controller = sourceFile("WhiteboardController.swift") else { return }
        if !controller.contains("\"island\": Self.islandTokens(for: theme)") {
            print("  FAIL pushTheme does not send the island tokens - M1's mapping would never reach Excalidraw")
            ok = false
        } else {
            print("  OK   pushTheme sends them with every theme push")
        }

        // And the page has to write them onto the document root, where
        // `.Island` reads them from. The committed bundle is what the app
        // loads, so the built artifact is what gets checked - a src edit with
        // no rebuild is the one failure mode here (see
        // `Scripts/build-excalidraw-web.sh`).
        let bundle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SelfTests
            .deletingLastPathComponent()   // FirstmateCockpit
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // native
            .appendingPathComponent("Vendor/Excalidraw/web/whiteboard.js")
        guard let built = try? String(contentsOf: bundle, encoding: .utf8) else {
            print("  NOTE could not read the built Excalidraw bundle - skipping the artifact guard")
            return
        }
        for property in ["--island-bg-color", "--border-radius-lg", "--shadow-island"] {
            if !built.contains(property) {
                print("  FAIL the built bundle never writes \(property) - re-run Scripts/build-excalidraw-web.sh after editing src/whiteboard.js")
                ok = false
            }
        }
        print("  OK   the committed bundle writes all three custom properties")
    }

    // MARK: 6. M2 - Monaco's scroll edge

    private static func checkMonacoScrollEdge(_ ok: inout Bool) {
        print("\n-- M2: Monaco's page gets the native scroll-edge hairline --")

        // The hairline itself, driven externally rather than by a scroll view
        // this page does not have.
        let card = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let hairline = HelmScrollEdgeHairline(atTopOf: card, in: card)
        let cardWindow = makeWindow(card)
        defer { cardWindow.orderOut(nil) }
        if hairline.debugIsVisible {
            print("  FAIL the hairline is visible before anything has scrolled")
            ok = false
        }
        HelmMotion.reducedOverrideForTests = true
        hairline.setScrolled(true)
        if !hairline.debugIsVisible {
            print("  FAIL the hairline did not appear when told the editor had scrolled")
            ok = false
        }
        hairline.setScrolled(false)
        if hairline.debugIsVisible {
            print("  FAIL the hairline did not go away when the editor returned to its top")
            ok = false
        } else {
            print("  OK   an externally-driven hairline follows the reported state")
        }
        HelmMotion.reducedOverrideForTests = false
        // It spans the target and sits on its top edge, like every native one.
        card.layoutSubtreeIfNeeded()
        let line = hairline.debugLine
        if abs(line.frame.width - card.bounds.width) > 0.6 || line.frame.height > 1.5 {
            print("  FAIL the hairline is \(line.frame.width)x\(line.frame.height) in a \(card.bounds.width)pt card")
            ok = false
        } else {
            print("  OK   it spans the card at hairline thickness")
        }

        // The relay: the page reports a raw offset and the boolean is
        // re-derived here, through the same threshold a native page uses, so
        // the two kinds of page cannot disagree about "away from the top".
        guard let webSource = sourceFile("CodePreviewWebView.swift") else { return }
        if !webSource.contains("case \"scroll\":") {
            print("  FAIL the web view does not handle the page's scroll message")
            ok = false
        }
        if !webSource.contains("ScrollEdgeObserver.offsetThreshold") {
            print("  FAIL the relay does not re-derive through ScrollEdgeObserver's own threshold - a web page and a native page would answer 'am I scrolled' differently")
            ok = false
        } else {
            print("  OK   the boolean is re-derived through ScrollEdgeObserver.offsetThreshold")
        }
        guard let page = sourceFile("CodePreviewController.swift") else { return }
        if !page.contains("HelmScrollEdgeHairline(atTopOf: editorCard") {
            print("  FAIL the Code Preview page installs no hairline")
            ok = false
        }
        if !page.contains("webView.onScrolledAwayFromTop") {
            print("  FAIL the page never subscribes to the scroll relay - the hairline would never move")
            ok = false
        } else {
            print("  OK   the page installs the hairline and subscribes to the relay")
        }

        // And the built artifact posts it - the app loads the committed
        // bundle, never `src/`.
        let bundle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor/Monaco/web/code-preview.js")
        guard let built = try? String(contentsOf: bundle, encoding: .utf8) else {
            print("  NOTE could not read the built Monaco bundle - skipping the artifact guard")
            return
        }
        if !built.contains("onDidScrollChange") || !built.contains("type:\"scroll\"") {
            print("  FAIL the committed Monaco bundle does not post a scroll event - re-run Scripts/build-monaco-web.sh after editing src/code-preview.js")
            ok = false
        } else {
            print("  OK   the committed bundle posts the scroll event")
        }
    }
}

#endif
