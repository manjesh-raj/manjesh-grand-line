// Manjesh Grand Line - native macOS app.
//
// `FM_RUN_WINDOW_CHROME_FUSION_TESTS=1` - the UI modernization audit's A1,
// A2 and A3 (`data/grandline-ui-modernization-audit/report.md` §3A), which
// ship as one change because the report sequences them that way.
//
// Window-backed, so it sits in `run-all-tests.sh`'s `NEEDS_SESSION` list:
// every one of these is a question about a real `NSWindow`'s own chrome, a
// real laid-out bar, or a real scroll offset, and none of them can be
// answered from a constant.
//
// **What each case is guarding, and why it is written the way it is:**
//
//   - A1 is the only thing in this app that touches AppKit's own titlebar
//     subviews, and the measurements behind it are all in
//     `WindowChromeFusion`'s header. The two that a regression would silently
//     undo are the *reclaimed height* (an `.fullSizeContentView` dropped from
//     the style mask looks identical in a diff and costs 32pt) and the
//     *reposition surviving a layout pass* (which is what actually resets the
//     lights - a fix hooked on resize alone passes a naive test and fails in
//     use).
//   - A2's regression is invisible in a screenshot of the canvas: the leading
//     swap is two-way, and a one-way version leaves the wordmark and the five
//     space pills stranded off a drill page forever. Both directions are
//     asserted.
//   - A3's is a boolean, so the case drives a *real* scroll on a real page
//     and reads the bar's own state back, rather than calling the setter.

#if FM_SELFTESTS

import AppKit

enum WindowChromeFusionSelfTest {

    static func run() -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("== window chrome fusion (UI modernization audit A1/A2/A3) ==")
        var ok = true
        let cases: [(String, () -> String?)] = [
            ("A1 fusion reclaims the titlebar and keeps the buttons live", test_a1FusionReclaimsHeight),
            ("A1 the traffic lights centre on the bar and stay there", test_a1TrafficLightsHoldTheirPosition),
            ("A1 the bar's leading content clears the traffic lights", test_a1LeadingContentClearsTheCluster),
            ("A2 the leading swap is two-way", test_a2LeadingSwapIsTwoWay),
            ("A2 the page starts directly under the bar", test_a2NoStripBetweenBarAndPage),
            ("A2 the page's actions are its own views, on the bar", test_a2ActionsAreTheCallersOwnViews),
            ("A2 the merged bar lays out on both theme families", test_a2LaysOutOnBothThemeFamilies),
            ("A2 a title-only page centres its title", test_a2TitleOnlyCollapsesTheSubtitle),
            ("A3 the scroll edge reads a real offset", test_a3ScrollEdgeReadsARealOffset),
            ("A3 a real scroll toggles the bar's state", test_a3RealScrollTogglesTheBar),
            ("A3 the bar's elevation actually changes", test_a3ElevationChanges),
        ]
        for (name, body) in cases {
            if let failure = body() {
                print("  FAIL \(name): \(failure)")
                ok = false
            } else {
                print("  OK   \(name)")
            }
        }
        print(ok ? "== window chrome fusion: PASS ==" : "== window chrome fusion: FAIL ==")
        return ok
    }

    // MARK: A1

    /// `.fullSizeContentView` is what reclaims the strip, and the measurement
    /// is the content view growing to the window's own height - a style mask
    /// quietly reverted reads identically in source review and costs 32pt.
    ///
    /// The buttons are asserted *live*, not merely present: A1's whole risk
    /// note is "traffic-light hit targets", and this app's two `NSPanel`s use
    /// the same idiom while hiding all three, so hiding them here would be an
    /// easy and plausible mistake.
    private static func test_a1FusionReclaimsHeight() -> String? {
        let stock = makeWindow(fused: false)
        let fused = makeWindow(fused: true)
        defer { stock.close(); fused.close() }

        guard let stockContent = stock.contentView, let fusedContent = fused.contentView else {
            return "a probe window has no content view"
        }
        let reclaimed = fusedContent.bounds.height - stockContent.bounds.height
        guard reclaimed > 20 else {
            return "fusing the chrome reclaimed only \(reclaimed)pt - .fullSizeContentView is not in the style mask"
        }
        guard abs(fusedContent.bounds.height - fused.frame.height) < 0.5 else {
            return "the content view is \(fusedContent.bounds.height)pt tall in a \(fused.frame.height)pt window"
        }
        guard fused.titleVisibility == .hidden else { return "the window title is still visible" }
        guard fused.titlebarAppearsTransparent else { return "the titlebar is still opaque" }
        guard fused.styleMask.contains(.fullSizeContentView) else {
            return "WindowChromeFusion.apply did not add .fullSizeContentView"
        }

        // Source guard: the app's own window literal has to carry the flag
        // too. A behavioural check cannot see this - `apply` would put it
        // back - and the literal is what a reader of `main.swift` believes.
        let mainFile = SelfTestSources.appSourceDirectory()?.appendingPathComponent("main.swift")
        if let mainFile, let mainSource = try? String(contentsOf: mainFile, encoding: .utf8) {
            let constructs = mainSource.contains("styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]")
            if !constructs {
                return "main.swift's window no longer names .fullSizeContentView in its style mask"
            }
            if !mainSource.contains("WindowChromeFusion.apply(to: window)") {
                return "main.swift no longer calls WindowChromeFusion.apply"
            }
        } else {
            print("    NOTE could not read main.swift - the source half of A1 is unchecked in this run")
        }

        for (name, kind) in trafficLightKinds {
            guard let button = fused.standardWindowButton(kind) else { return "no \(name) button" }
            if button.isHidden { return "the \(name) button is hidden - a main window keeps its controls" }
            if !button.isEnabled { return "the \(name) button is disabled" }
            // The real hit path a click takes: the button has to be what the
            // window's own view tree returns under its own centre.
            let centre = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let hit = fused.contentView?.superview?.hitTest(centre)
            if hit !== button {
                return "a click at the \(name) button's centre lands on "
                    + "\(hit.map { String(describing: type(of: $0)) } ?? "nothing"), not the button"
            }
        }
        return nil
    }

    /// The reposition has to survive the two things measured to undo it: a
    /// window resize, and a forced layout with no intervening runloop turn
    /// (which this app performs on every resize, in
    /// `AppShellController.reassertBodyContainerWidthTie`).
    ///
    /// A fix hooked only on `NSWindow.didResizeNotification` passes the first
    /// half and fails the second, which is exactly the regression worth
    /// catching.
    private static func test_a1TrafficLightsHoldTheirPosition() -> String? {
        let window = makeWindow(fused: true)
        defer { window.close() }
        let root = ChromeFusionRootView(frame: NSRect(x: 0, y: 0, width: 1220, height: 720))
        root.onLayout = { [weak window] in
            WindowChromeFusion.positionTrafficLights(
                in: window,
                verticalCenter: DaylightBarController.trafficLightCenterY,
                leadingX: DaylightBarController.trafficLightLeadingX)
        }
        window.contentView = root
        window.orderFront(nil)

        let target = DaylightBarController.trafficLightCenterY
        let targetX = DaylightBarController.trafficLightLeadingX
        func drift(_ label: String) -> String? {
            guard let centre = WindowChromeFusion.trafficLightCenterForTests(in: window),
                  let span = WindowChromeFusion.trafficLightSpanForTests(in: window) else {
                return "\(label): no close button to measure"
            }
            guard abs(centre - target) < 0.51 else {
                return "\(label): the cluster is centred at \(centre), expected \(target)"
            }
            guard abs(span.minX - targetX) < 0.51 else {
                return "\(label): the cluster starts at x=\(span.minX), expected \(targetX)"
            }
            return nil
        }

        root.layoutSubtreeIfNeeded()
        if let failure = drift("after the first layout") { return failure }

        window.setFrame(NSRect(x: -20_000, y: 0, width: 1000, height: 700), display: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        if let failure = drift("after a width resize") { return failure }

        window.setFrame(NSRect(x: -20_000, y: 0, width: 1000, height: 520), display: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        if let failure = drift("after a height-only resize") { return failure }

        // The measured killer: a synchronous forced layout, no runloop turn.
        window.setFrame(NSRect(x: -20_000, y: 0, width: 1340, height: 780), display: false)
        root.layoutSubtreeIfNeeded()
        if let failure = drift("after a synchronous forced layout") { return failure }

        // And it must sit inside the bar's own vertical band, not merely at
        // some stable number.
        let barTop = DaylightBarController.topMargin
        let barBottom = barTop + DaylightBarController.height
        guard target > barTop + 4, target < barBottom - 4 else {
            return "the target centre \(target) is not comfortably inside the bar's \(barTop)...\(barBottom) band"
        }
        return nil
    }

    /// Nothing in the bar's leading area may sit under the cluster. Measured
    /// against the real laid-out bar rather than against the 78pt constant,
    /// so a change to either the constant or the bar's own inset is caught.
    private static func test_a1LeadingContentClearsTheCluster() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.orderFront(nil)
            defer { window.close() }
            window.setFrame(NSRect(x: -20_000, y: 0, width: 1440, height: 900), display: true)

            for dest in [RailDestination.homeCanvas, .review] {
                shell.show(dest)
                window.contentView?.layoutSubtreeIfNeeded()
                guard let span = WindowChromeFusion.trafficLightSpanForTests(in: window) else {
                    return "\(dest): no traffic lights to measure"
                }
                // The bar's own frame within the shell root, plus the leading
                // group's frame within the bar.
                let barOriginX = shell.bar.view.frame.minX + shell.bar.barFrameInViewForTests.minX
                let leadingContentX = barOriginX + shell.bar.leadingGroupFrameForTests.minX
                guard leadingContentX >= span.maxX else {
                    return "\(dest): the bar's leading content starts at \(leadingContentX), "
                        + "under the traffic lights (which end at \(span.maxX))"
                }
                // A1 asks for the lights to be *inset into* the bar, and the
                // bar is itself inset from the window edge - so the whole
                // cluster has to be inside it, not straddling its leading
                // edge. Confirmed in a real render before this was added:
                // left where AppKit puts them, the close button sits on the
                // page ground outside the bar's rounded corner.
                let barEndX = barOriginX + shell.bar.barFrameInViewForTests.width
                guard span.minX >= barOriginX, span.maxX <= barEndX else {
                    return "\(dest): the cluster spans \(span.minX)...\(span.maxX) but the bar is "
                        + "\(barOriginX)...\(barEndX) - the lights are not inside it"
                }
            }
            return nil
        }
    }

    // MARK: A2

    /// The swap has to work in both directions. A one-way version renders a
    /// perfectly correct drill page and strands the wordmark and the five
    /// space pills forever - which no screenshot of a drill page would show.
    private static func test_a2LeadingSwapIsTwoWay() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            defer { window.close() }
            window.setFrame(NSRect(x: -20_000, y: 0, width: 1440, height: 900), display: true)

            shell.show(.homeCanvas)
            window.contentView?.layoutSubtreeIfNeeded()
            if !shell.drillHeaderIsHiddenForTests { return "the canvas shows a drill cluster" }
            if shell.bar.wordmarkIsHiddenForTests { return "the canvas hides the wordmark" }
            if shell.bar.pillsAreHiddenForTests { return "the canvas hides the space pills" }

            shell.show(.review)
            window.contentView?.layoutSubtreeIfNeeded()
            if shell.drillHeaderIsHiddenForTests { return "a drill page shows no drill cluster" }
            if !shell.bar.wordmarkIsHiddenForTests { return "a drill page shows the wordmark too" }
            if !shell.bar.pillsAreHiddenForTests { return "a drill page leaves the space pills up" }
            let title = shell.drillHeaderForTests.titleForTests
            if title != RailDestination.review.bodyTitle {
                return "the bar says '\(title)', expected '\(RailDestination.review.bodyTitle)'"
            }

            // The back control is in the bar's own chain now, and it has to
            // actually work from there.
            if !shell.drillHeaderForTests.debugActivateBack() { return "the back button did not activate" }
            window.contentView?.layoutSubtreeIfNeeded()
            if !shell.drillHeaderIsHiddenForTests { return "back did not land on the canvas" }
            if shell.bar.wordmarkIsHiddenForTests { return "the wordmark did not come back" }
            if shell.bar.pillsAreHiddenForTests { return "the space pills did not come back" }
            return nil
        }
    }

    /// A2's actual win: the 56pt strip between the bar and the page is gone,
    /// so a destination starts at the body container's own top edge.
    private static func test_a2NoStripBetweenBarAndPage() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            defer { window.close() }
            window.setFrame(NSRect(x: -20_000, y: 0, width: 1440, height: 900), display: true)

            let inset = shell.bodyTopInsetForTests
            guard abs(inset - DaylightBarController.reservedTopHeight) < 0.5 else {
                return "the body starts \(inset)pt down, expected \(DaylightBarController.reservedTopHeight)"
            }
            for dest in [RailDestination.review, .settings, .homeCanvas] {
                shell.show(dest)
                window.contentView?.layoutSubtreeIfNeeded()
                guard let page = shell.destinationViewIfMountedForTests(dest.slot) else {
                    return "\(dest) did not mount"
                }
                guard let body = page.superview else { return "\(dest)'s view has no container" }
                // Flipped or not, "the page's top edge is the container's top
                // edge" is the same statement about the same two rects.
                let gap = body.isFlipped
                    ? page.frame.minY - body.bounds.minY
                    : body.bounds.maxY - page.frame.maxY
                guard abs(gap) < 0.5 else {
                    return "\(dest) starts \(gap)pt below the body container's top - a strip survived the merge"
                }
            }
            return nil
        }
    }

    /// Identity, not count: a copied button would render and never disable
    /// itself while the page's own fetch is in flight. This is the contract
    /// `HelmDrillHeader.setActions` carried before A2, asserted on the
    /// surface that renders it now.
    private static func test_a2ActionsAreTheCallersOwnViews() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            defer { window.close() }
            window.setFrame(NSRect(x: -20_000, y: 0, width: 1440, height: 900), display: true)

            shell.show(.review)
            window.contentView?.layoutSubtreeIfNeeded()
            guard let review = shell.destinationViewIfMountedForTests(RailDestination.review.slot)?
                .findController(ofType: ReviewController.self) ?? nil else {
                // Fall back to the shell's own view of it: what matters is
                // that the bar is showing *some* real action views.
                guard !shell.drillActionsForTests.isEmpty else {
                    return "Review's own actions never reached the bar"
                }
                return nil
            }
            let expected = review.drillHeaderActions
            guard !expected.isEmpty else { return "Review offers no actions - its Refresh never moved" }
            let shown = shell.drillActionsForTests
            guard shown.count == expected.count else {
                return "the bar is showing \(shown.count) action view(s), Review offers \(expected.count)"
            }
            guard zip(shown, expected).allSatisfy({ $0 === $1 }) else {
                return "the bar is showing \(shown.count) view(s) that are not Review's own - a copy "
                    + "renders identically and never disables itself while a fetch is in flight"
            }

            // Navigating to a page with no actions has to clear them, or the
            // previous page's buttons stay up.
            shell.show(.homeCanvas)
            window.contentView?.layoutSubtreeIfNeeded()
            guard shell.drillActionsForTests.isEmpty else {
                return "the canvas kept \(shell.drillActionsForTests.count) action view(s) from Review"
            }
            return nil
        }
    }

    /// The audit distinguishes the Daylight family from the twelve legacy
    /// palettes for anything material-like, so the merged row is laid out and
    /// measured on one of each - a theme-conditional recipe that only works
    /// on Daylight is the exact failure mode that split exists to catch.
    private static func test_a2LaysOutOnBothThemeFamilies() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.orderFront(nil)
            defer { window.close() }
            window.setFrame(NSRect(x: -20_000, y: 0, width: 1440, height: 900), display: true)

            guard let daylight = HelmTheme.theme(id: "daylight") else { return "no daylight theme" }
            for theme in [daylight, HelmTheme.dark] {
                ThemeManager.shared.setTheme(theme)
                shell.show(.review)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))

                let header = shell.drillHeaderForTests
                let title = header.titleLabelForTests
                guard header.frame.width > 0, header.frame.height > 0 else {
                    return "\(theme.id): the drill cluster has no frame"
                }
                guard title.frame.width > 0 else { return "\(theme.id): the title has no width" }
                // It must fit inside the bar's own row, not spill out of it.
                let barHeight = shell.bar.barFrameInViewForTests.height
                guard header.frame.height <= barHeight + 0.5 else {
                    return "\(theme.id): the cluster is \(header.frame.height)pt tall in a \(barHeight)pt bar"
                }
                // And it must not run into the action cluster beside it.
                if let firstAction = shell.drillActionsForTests.first {
                    let clusterEnd = header.convert(header.bounds, to: nil).maxX
                    let actionStart = firstAction.convert(firstAction.bounds, to: nil).minX
                    guard clusterEnd <= actionStart + 0.5 else {
                        return "\(theme.id): the title cluster (ends \(clusterEnd)) overlaps the actions "
                            + "(start \(actionStart))"
                    }
                }
            }
            return nil
        }
    }

    /// A hidden subtitle is a plain hidden `NSView`, so it keeps its
    /// constraints (AGENTS.md gotcha (11)) - the column has to swap which
    /// view owns its bottom edge, or a title-only page parks its title above
    /// an empty line instead of centring it in the bar.
    private static func test_a2TitleOnlyCollapsesTheSubtitle() -> String? {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: rowHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let header = HelmDrillHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        let root = window.contentView!
        root.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        header.configure(title: "Console", subtitle: "2 tabs", symbol: "terminal", hue: .teal)
        window.displayIfNeeded()
        if header.subtitleIsHiddenForTests { return "a page with a subtitle hid it" }
        let twoLine = header.textColumnForTests.frame.height
        let twoLineTitleY = header.titleLabelForTests.frame.minY

        header.configure(title: "Console", subtitle: "", symbol: "terminal", hue: .teal)
        window.displayIfNeeded()
        guard header.subtitleIsHiddenForTests else { return "an empty subtitle stayed visible" }
        let oneLine = header.textColumnForTests.frame.height
        guard oneLine < twoLine - 4 else {
            return "the column is still \(oneLine)pt tall with no subtitle (was \(twoLine)) - "
                + "the empty line did not collapse"
        }
        guard abs(header.titleLabelForTests.frame.minY - twoLineTitleY) > 1 else {
            return "the title did not move when the subtitle collapsed - it is still parked above blank space"
        }
        return nil
    }

    private static let rowHeight = DaylightBarController.height

    // MARK: A3

    /// The report's literal test (`origin.y > 0`) is right for a flipped
    /// document and inverted for a non-flipped one, so both are driven -
    /// this app's pages use `FlippedView`, and its tables do not.
    private static func test_a3ScrollEdgeReadsARealOffset() -> String? {
        for flipped in [true, false] {
            let document: NSView = flipped ? FlippedView() : NSView()
            document.frame = NSRect(x: 0, y: 0, width: 300, height: 2000)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
            scroll.documentView = document
            scroll.hasVerticalScroller = true
            scroll.layoutSubtreeIfNeeded()

            scroll.contentView.scroll(to: topOffset(of: scroll))
            scroll.reflectScrolledClipView(scroll.contentView)
            if ScrollEdgeObserver.isScrolled(scroll) {
                return "flipped=\(flipped): reported scrolled while resting at the top"
            }

            var moved = topOffset(of: scroll)
            moved.y += flipped ? 120 : -120
            scroll.contentView.scroll(to: moved)
            scroll.reflectScrolledClipView(scroll.contentView)
            if !ScrollEdgeObserver.isScrolled(scroll) {
                return "flipped=\(flipped): reported at rest after scrolling 120pt "
                    + "(clip origin \(scroll.contentView.bounds.origin.y))"
            }
        }

        // Discovery: a top-pinned scroll view is the page scroll; one below a
        // static strip is not.
        let page = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let topScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        page.addSubview(topScroll)
        guard ScrollEdgeObserver.pageScrollViews(in: page).count == 1 else {
            return "a scroll view pinned to the page's top was not found"
        }
        let belowStrip = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let inset = NSScrollView(frame: NSRect(x: 0, y: 44, width: 400, height: 556))
        belowStrip.addSubview(inset)
        guard ScrollEdgeObserver.pageScrollViews(in: belowStrip).isEmpty else {
            return "a scroll view sitting 44pt below a static strip was treated as the page scroll"
        }
        return nil
    }

    /// End to end on the real shell: scroll a real page and read the bar's
    /// own state back, rather than calling the setter.
    private static func test_a3RealScrollTogglesTheBar() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.orderFront(nil)
            defer { window.close() }
            window.setFrame(NSRect(x: -20_000, y: 0, width: 1100, height: 600), display: true)

            // Settings is the page most reliably taller than a 600pt window.
            shell.show(.settings)
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            guard let scroll = shell.scrollEdgeWatchedForTests.first else {
                return "the observer found no page scroll view on Settings"
            }
            guard let document = scroll.documentView,
                  document.bounds.height > scroll.contentView.bounds.height + 50 else {
                return "Settings' content is not taller than the window, so it cannot be scrolled"
            }
            if shell.scrollEdgeActiveForTests { return "the bar claims a scroll edge while resting at the top" }

            var offset = topOffset(of: scroll)
            offset.y += document.isFlipped ? 150 : -150
            scroll.contentView.scroll(to: offset)
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if !shell.scrollEdgeActiveForTests {
                return "the bar did not pick up a real 150pt scroll "
                    + "(clip origin \(scroll.contentView.bounds.origin.y))"
            }

            scroll.contentView.scroll(to: topOffset(of: scroll))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if shell.scrollEdgeActiveForTests {
                return "the bar stayed at its scrolled state after coming back to the top"
            }

            // Navigating to a page with no page scroll has to clear it, not
            // leave the previous page's state behind.
            offset.y += document.isFlipped ? 150 : -150
            scroll.contentView.scroll(to: offset)
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            shell.show(.console)
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if shell.scrollEdgeActiveForTests {
                return "Console (which has no page scroll) kept Settings' scroll edge"
            }
            return nil
        }
    }

    /// The state has to reach the layer. A boolean that flips correctly and
    /// paints nothing is the whole of A3 missing, on both theme families.
    private static func test_a3ElevationChanges() -> String? {
        guard let daylight = HelmTheme.theme(id: "daylight") else { return "no daylight theme" }
        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }

        for theme in [daylight, HelmTheme.dark] {
            ThemeManager.shared.setTheme(theme)
            let bar = DaylightBarController()
            _ = bar.view
            bar.view.frame = NSRect(x: 0, y: 0, width: 1200,
                                    height: DaylightBarController.height + DaylightBarController.topMargin)
            bar.view.layoutSubtreeIfNeeded()
            guard let layer = bar.barLayerForTests else { return "\(theme.id): the bar has no layer" }

            bar.setScrollEdgeActive(false)
            let restingRadius = layer.shadowRadius
            let restingOpacity = layer.shadowOpacity
            let restingBorder = layer.borderColor

            bar.setScrollEdgeActive(true)
            guard bar.scrollEdgeActiveForTests else { return "\(theme.id): the bar did not record the state" }
            guard layer.shadowRadius > restingRadius + 0.5 else {
                return "\(theme.id): the shadow radius did not deepen (\(restingRadius) -> \(layer.shadowRadius))"
            }
            guard layer.shadowOpacity > restingOpacity else {
                return "\(theme.id): the shadow opacity did not deepen "
                    + "(\(restingOpacity) -> \(layer.shadowOpacity))"
            }
            // The hairline only firms up where the palette leaves headroom:
            // Daylight/Dusk already draw it at full strength at rest (see
            // `applyScrollEdge`), so there the depth change is the whole
            // signal. Asserting a change unconditionally would be asserting
            // something the palette makes impossible.
            if !theme.isDaylight {
                guard let scrolledBorder = layer.borderColor, scrolledBorder != restingBorder else {
                    return "\(theme.id): the border did not firm up, and this palette has headroom for it"
                }
            } else if layer.borderColor != restingBorder {
                return "\(theme.id): the border changed, but this palette already draws it at full strength"
            }

            bar.setScrollEdgeActive(false)
            guard abs(layer.shadowRadius - restingRadius) < 0.01 else {
                return "\(theme.id): the shadow did not return to rest "
                    + "(\(restingRadius) -> \(layer.shadowRadius))"
            }
        }
        return nil
    }

    // MARK: Harness

    private static let trafficLightKinds: [(String, NSWindow.ButtonType)] = [
        ("close", .closeButton), ("minimise", .miniaturizeButton), ("zoom", .zoomButton),
    ]

    /// A clip view's offset when the document is resting at its own top -
    /// zero for a flipped document, its maximum for a non-flipped one.
    private static func topOffset(of scroll: NSScrollView) -> NSPoint {
        guard let document = scroll.documentView, !document.isFlipped else { return .zero }
        return NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height))
    }

    /// Built the way `main.swift` builds the real one, minus the app's own
    /// wiring - **except** that the style mask is deliberately left at the
    /// pre-A1 set even when `fused` is true, so `WindowChromeFusion.apply`
    /// is the only thing that can supply `.fullSizeContentView`.
    ///
    /// Pre-inserting it here (which `main.swift` does, and should keep
    /// doing) made the first version of this harness unable to see `apply`'s
    /// own `insert` being deleted - measured, by injecting exactly that. The
    /// production literal is covered by the source guard in
    /// `test_a1FusionReclaimsHeight` instead: the two catch different
    /// failures and both are needed.
    private static func makeWindow(fused: Bool) -> NSWindow {
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
                              styleMask: mask, backing: .buffered, defer: false)
        window.title = "Probe"
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 1220, height: 720))
        window.contentViewController = controller
        if fused { WindowChromeFusion.apply(to: window) }
        window.setFrame(NSRect(x: -20_000, y: 0, width: 1220, height: 720), display: false)
        window.orderFront(nil)
        return window
    }

    private static func makeMountedShell() -> (window: NSWindow, shell: AppShellController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        WindowChromeFusion.apply(to: window)
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
                                         dictationStore: DictationStore()),
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: ShiftStore(),
            dictationStore: DictationStore(), commandLibraryStore: CommandLibraryStore(),
            scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                 isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        window.setFrame(NSRect(x: -20_000, y: 0, width: 1220, height: 720), display: false)
        return (window, shell)
    }

    /// Same shape as every other window-backed suite's: isolate every file
    /// this touches, and put the captain's own theme and font size back (see
    /// `AppShellBodyWidthSelfTest.withScratchEnv`'s own note on why that
    /// restore is not optional).
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-window-chrome-fusion-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_DOCS_RUNBOOKS_DIR": dir.appendingPathComponent("docsRunbooks").path,
        ]
        var previous: [String: String?] = [:]
        for (key, value) in overrides {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let savedTheme = ThemeManager.shared.theme
        let savedFontSize = AppSettings.shared.fontSize
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.fontSize = savedFontSize
        }
        return body()
    }
}

private extension NSView {
    /// The controller whose `view` this is, if it is one of `type` - used
    /// only to reach a mounted page's own `DaylightDrillActions` values.
    func findController<T: NSViewController>(ofType type: T.Type) -> T? {
        var responder: NSResponder? = self.nextResponder
        while let current = responder {
            if let match = current as? T { return match }
            responder = current.nextResponder
        }
        return nil
    }
}

#endif
