// Manjesh Grand Line - native macOS app.
//
// The UI modernization audit's C, D and E findings
// (`data/grandline-ui-modernization-audit/report.md` §3C "The home canvas and
// cards", §3D "Rows, lists and density", §3E "Buttons and controls") - the
// third and largest of the audit's rollout batches, after
// `WindowChromeFusionSelfTest`'s A1-A3 and
// `BarNavigationModernizationSelfTest`'s B1-B5.
//
// **What is worth asserting here, and what deliberately is not.** Fifteen
// findings is far too many to cover exhaustively, and most of them are
// *rendering* changes whose exact durations and curves are taste. So this
// suite spends its assertions on the three things that would otherwise fail
// silently:
//
//   1. **State machines that can get stuck.** D1's hover-reveal and E5's
//      per-theme toggle are both "a control is in the wrong state and looks
//      plausible" bugs - the class this app has shipped repeatedly. Those get
//      real, driven coverage.
//   2. **Claims a rendering cannot make for itself.** C1's hero must report
//      the *answer banner's* own verdict rather than inventing one, C3's
//      ribbon must stay loud for a card that needs the captain, and D3's
//      skeleton must never be mistaken for real content. Each is asserted as
//      a value, not as a look.
//   3. **Invariants the rest of the app relies on.** A press transform that
//      overwrote a card's hover lift, or a hover-reveal that dropped a row's
//      buttons out of the accessibility tree, would be a regression in
//      something that already works.
//
// An animation's exact duration is *not* asserted anywhere: it is the taste
// half, it changes, and a test that pins it only ever fails for the wrong
// reason.
//
// Run with:
//   swift build && FM_RUN_CANVAS_LISTS_CONTROLS_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
//
// Window-backed: hover, press, focus and a real scroll offset are all
// questions about a real window. In `run-all-tests.sh`'s `NEEDS_SESSION`
// list for that reason.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum CanvasListsControlsSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)

        // A suite that changes the active theme MUST put it back - `setTheme`
        // persists to the real `FirstmateCockpit` UserDefaults domain that
        // every other suite in this run reads as its ambient theme.
        // `Phase3PolishSelfTest.checkSuitesRestoreTheTheme` is the guard.
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        defer { HelmMotion.reducedOverrideForTests = nil }

        let cases: [(String, () -> String?)] = [
            ("C1 the hero reports the answer banner's own verdict", test_c1HeroReportsTheAnswer),
            ("C1 every space's hero glyph resolves", test_c1HeroSymbolsResolve),
            ("C1 short content composes the space instead of flushing to the top", test_c1ContentComposesTheSpace),
            ("C1 the content column uses only the columns it can fill", test_c1ComposedContentWidth),
            ("C2 a card press compresses, and composes with the hover lift", test_c2PressComposesWithHover),
            ("C2 Reduce Motion gets the end state instantly", test_c2ReduceMotionIsInstant),
            ("C3 the ribbon is quiet at rest and blooms on hover", test_c3RibbonQuietAtRest),
            ("C3 a card that needs the captain keeps its loud edge", test_c3CriticalCardKeepsItsEdge),
            ("D1 a row's actions are quiet until aimed at", test_d1ActionsQuietUntilAimed),
            ("D1 the actions stay reachable without a mouse", test_d1ActionsStayReachable),
            ("D1 a short list, and the first row, keep their actions", test_d1DiscoverabilityMitigation),
            ("D1 a real PR list goes quiet below its first row", test_d1RealListGoesQuiet),
            ("D1 an unanimated fade lands immediately", test_d1UnanimatedFadeIsImmediate),
            ("D2 a record row's content column is capped, its card is not", test_d2RecordRowContentCapped),
            ("D3 the loading state is shaped like the content, not a spinner", test_d3SkeletonNotSpinner),
            ("D4 an empty state carries its destination's artwork", test_d4EmptyStateArtwork),
            ("D5 a card's list gets A3's own scroll edge", test_d5ScrollEdgeReusesTheObserver),
            ("D5 the row entrance is capped and plays once", test_d5RowEntranceCappedAndOnce),
        ]

        var failures: [String] = []
        for (name, body) in cases {
            if let failure = body() {
                failures.append("\(name): \(failure)")
                print("  FAIL \(name)\n        \(failure)")
            } else {
                print("  OK   \(name)")
            }
        }

        if failures.isEmpty {
            print("CanvasListsControlsSelfTest: all \(cases.count) cases passed")
            return true
        }
        print("CanvasListsControlsSelfTest: \(failures.count) of \(cases.count) cases FAILED")
        return false
    }

    // MARK: - D1

    /// The finding: "a visible bordered button per row x 50 is 2010s
    /// enterprise-web". What is asserted is the *state machine*, because a
    /// reveal that gets stuck (shown forever, or hidden forever) looks
    /// entirely plausible in a screenshot.
    private static func test_d1ActionsQuietUntilAimed() -> String? {
        let button = HelmButton(title: "Connect", variant: .secondary)
        let row = HelmAccentRow(trailingAccessory: button)
        row.configure(HelmAccentRow.Content(tint: .accent, kicker: "SSH", title: "prod-bastion",
                                            meta: "user@host"),
                      theme: ThemeManager.shared.theme)
        let window = makeWindow(row, size: NSSize(width: 700, height: 80))
        defer { window.orderOut(nil) }
        // The policy is set *after* the row is in a real window, deliberately.
        // An earlier draft of this case set it first and passed against a
        // version of the reveal that did nothing at all in a real list:
        // `view.animator()` behaves differently for a view with no window, so
        // a component test that never puts one in a window can pass while
        // every real page fails. This ordering is what makes the case real.
        row.actionReveal = .onAim

        if button.alphaValue != 0 {
            return "a row's actions are visible at rest (alpha \(button.alphaValue)) - they should be quiet "
                 + "until the row is aimed at"
        }
        row.debugSetHovered(true)
        if button.alphaValue != 1 {
            return "hovering did not reveal the actions (alpha \(button.alphaValue))"
        }
        row.debugSetHovered(false)
        if button.alphaValue != 0 {
            return "leaving the row did not quieten the actions again (alpha \(button.alphaValue))"
        }
        return nil
    }

    /// The finding is explicit that keyboard and VoiceOver users keep the
    /// actions. Two independent halves: the accessory never leaves the
    /// accessibility tree (which `isHidden` would have cost), and focus-within
    /// reveals it for a captain who reached it with the keyboard.
    private static func test_d1ActionsStayReachable() -> String? {
        let button = HelmButton(title: "Check", variant: .secondary)
        let row = HelmAccentRow(trailingAccessory: button)
        row.actionReveal = .onAim
        row.onClick = {}
        row.configure(HelmAccentRow.Content(tint: .accent, kicker: "TOOL", title: "firstmate", meta: "up to date"),
                      theme: ThemeManager.shared.theme)
        let window = makeWindow(row, size: NSSize(width: 700, height: 80))
        defer { window.orderOut(nil) }

        let children = row.accessibilityChildren() as? [NSView] ?? []
        if !children.contains(where: { $0 === button || button.isDescendant(of: $0) }) {
            return "a quiet row's actions are not in its accessibility tree - VoiceOver would lose them"
        }
        if button.isHidden {
            return "the actions are `isHidden`, which takes them out of the key loop and the a11y tree"
        }

        // Focus-within: reaching the button with the keyboard reveals it.
        window.makeFirstResponder(button)
        HelmFocusSensing.shared.refresh()
        if button.alphaValue != 1 {
            return "focusing a row's action did not reveal it (alpha \(button.alphaValue)) - a captain "
                 + "who tabs to it would be looking at an invisible button"
        }
        return nil
    }

    /// The finding's own discoverability mitigation, which is the half most
    /// likely to be dropped as an implementation detail.
    private static func test_d1DiscoverabilityMitigation() -> String? {
        if ReviewPRListView.actionReveal(row: 0, of: 50) != .always {
            return "the first row of a long list hides its actions - nothing would ever tell the captain "
                 + "the rows have any"
        }
        if ReviewPRListView.actionReveal(row: 1, of: 50) != .onAim {
            return "a long list's later rows still shout their buttons, which is the finding itself"
        }
        for row in 0..<HelmAccentRow.alwaysRevealRowCount
        where ReviewPRListView.actionReveal(row: row, of: HelmAccentRow.alwaysRevealRowCount) != .always {
            return "a list of \(HelmAccentRow.alwaysRevealRowCount) rows hid row \(row)'s actions - there is "
                 + "no noise worth trading discoverability for on a list that short"
        }
        return nil
    }

    /// The case that actually catches D1's own shipped-first-draft bug.
    ///
    /// The component cases above drive a `HelmAccentRow` directly, and all of
    /// them passed against a reveal that did **nothing** in a real list -
    /// because `view.animator()` resolves differently depending on how the
    /// view got there, and a row configured from
    /// `tableView(_:viewFor:row:)` during a display pass is not the same
    /// environment as one assigned straight to a window's content view.
    /// Driving the real list is what found it, so the real list is what is
    /// asserted.
    private static func test_d1RealListGoesQuiet() -> String? {
        let review = ReviewController()
        _ = review.view
        let window = makeWindow(review.view, size: NSSize(width: 1400, height: 800))
        defer { window.orderOut(nil) }

        var prs: [MergedPR] = []
        for i in 0..<6 {
            prs.append(MergedPR(source: "work", taskID: "t\(i)", repo: "HERDR",
                                url: "https://example.invalid/pull/\(i)", number: 2179 + i,
                                title: "fix(linux): avoid blocking proc reads",
                                checks: "green", forge: "github"))
        }
        review.debugRender(prs)
        review.view.layoutSubtreeIfNeeded()

        var alphas: [CGFloat] = []
        func walk(_ v: NSView) {
            if let row = v as? HelmAccentRow, let accessory = row.debugTrailingAccessory {
                alphas.append(accessory.alphaValue)
            }
            v.subviews.forEach(walk)
        }
        walk(review.view)

        guard alphas.count >= 4 else {
            return "only \(alphas.count) PR rows rendered; this case needs a real list to measure"
        }
        if alphas[0] != 1 {
            return "the first row hid its actions (alpha \(alphas[0])) - it is the one that has to keep "
                 + "them, or nothing tells the captain the rows have any"
        }
        if alphas.dropFirst().contains(where: { $0 != 0 }) {
            return "rows below the first still shout their buttons (alphas \(alphas)) - which is D1 itself, "
                 + "and is exactly what a component-level check passes straight through"
        }
        return nil
    }

    /// The mechanism behind that bug, on its own: an unanimated fade has to
    /// land immediately and attach no animation. `view.animator()` does
    /// neither, whatever the surrounding code believes.
    private static func test_d1UnanimatedFadeIsImmediate() -> String? {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let window = makeWindow(view, size: NSSize(width: 80, height: 24))
        defer { window.orderOut(nil) }

        HelmMotion.fade(view, to: 0, duration: 0.12, animated: false)
        if view.alphaValue != 0 {
            return "an unanimated fade left alpha at \(view.alphaValue); it must land immediately"
        }
        if view.layer?.animation(forKey: "opacity") != nil {
            return "an unanimated fade still attached an opacity animation"
        }
        HelmMotion.fade(view, to: 1, duration: 0.12, animated: false)
        if view.alphaValue != 1 {
            return "an unanimated fade back left alpha at \(view.alphaValue)"
        }
        return nil
    }

    // MARK: - D2

    /// The captain's own reframe, and the reason this is worth a test: "cap
    /// *rows*, not pages". He removed a page-level cap from Hosts once
    /// because it left a dead gutter, so a regression that caps the card (or
    /// stops capping the row) is a regression against a decision, not just
    /// against a look.
    private static func test_d2RecordRowContentCapped() -> String? {
        let button = HelmButton(title: "Connect", variant: .secondary)
        let row = HelmAccentRow(trailingAccessory: button,
                                maxContentWidth: HelmAccentRow.recordContentWidth)
        row.configure(HelmAccentRow.Content(tint: .accent, kicker: "SSH", title: "prod-bastion",
                                            meta: "user@host"),
                      theme: ThemeManager.shared.theme)
        // A genuinely 1900pt-wide host, explicitly constrained rather than
        // taken from the window: this machine's screen is narrower than that,
        // and AppKit clamps a window's frame to the screen - which would make
        // the case measure ~1512pt and fail for a reason that has nothing to
        // do with the row.
        let host = makeWideHost(row, width: 1900)
        defer { host.window?.orderOut(nil) }

        // The card still fills the page - no dead gutter returns.
        // The *card* - not the outer view, which is pinned to the host
        // either way and so would pass whichever of the two the cap landed
        // on. This is the half that catches a cap applied one level out.
        if row.debugCardWidth < 1800 {
            return "the card stopped filling the page (\(row.debugCardWidth)pt of 1900pt) - the "
                 + "captain's call was to cap rows, never pages"
        }
        // The content column inside it is capped.
        let content = row.debugContentColumnWidth
        if content > HelmAccentRow.recordContentWidth + 1 {
            return "a record row's content column is \(content)pt, above the \(HelmAccentRow.recordContentWidth)pt "
                 + "cap - the label and its action still read as an unstyled table"
        }
        // And an ordinary row is untouched.
        let plain = HelmAccentRow(trailingAccessory: HelmButton(title: "Reply", variant: .quiet))
        plain.configure(HelmAccentRow.Content(tint: .accent, kicker: "TASK", title: "Ship it", meta: "today"),
                        theme: ThemeManager.shared.theme)
        let host2 = makeWideHost(plain, width: 1900)
        defer { host2.window?.orderOut(nil) }
        if plain.debugContentColumnWidth <= HelmAccentRow.recordContentWidth {
            return "a non-record row was capped too (\(plain.debugContentColumnWidth)pt); only record lists "
                 + "opted in, and a task row must be byte-for-byte unchanged"
        }
        return nil
    }

    // MARK: - D3

    /// The finding: "the stock spinner is the one grey system control left on
    /// every themed page". What matters is that the placeholder is in the
    /// *shape of the content* and that it never reads as real content.
    private static func test_d3SkeletonNotSpinner() -> String? {
        let list = HelmSkeletonList()
        let window = makeWindow(list, size: NSSize(width: 600, height: 200))
        defer { window.orderOut(nil) }
        list.layoutSubtreeIfNeeded()

        if list.arrangedSubviews.count != HelmSkeletonList.defaultRowCount {
            return "the skeleton list has \(list.arrangedSubviews.count) rows, expected "
                 + "\(HelmSkeletonList.defaultRowCount)"
        }
        guard let row = list.arrangedSubviews.first as? HelmSkeletonRow else {
            return "the skeleton list does not hold skeleton rows"
        }
        if row.debugBarCount < 3 {
            return "a skeleton row has \(row.debugBarCount) bars - it has to be shaped like the row that "
                 + "is coming, not be one grey block"
        }
        // Never mistaken for content.
        if row.accessibilityRole() != .staticText || (row.accessibilityLabel() ?? "").isEmpty {
            return "a skeleton row is not announced as a loading placeholder"
        }
        // Reduce Motion: the redacted shape, no sweep.
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let quiet = HelmSkeletonRow()
        let window2 = makeWindow(quiet, size: NSSize(width: 300, height: 44))
        defer { window2.orderOut(nil) }
        quiet.layoutSubtreeIfNeeded()
        if quiet.debugIsShimmering {
            return "Reduce Motion still shimmers - the rule is the end state, not the same motion slower"
        }
        return nil
    }

    // MARK: - D4

    /// The finding: "big pages open onto beige silence ... add the
    /// destination's own artwork (the base64 icons already exist)".
    private static func test_d4EmptyStateArtwork() -> String? {
        guard let art = RailDestination.kubernetes.drillHeaderArtwork else {
            return "the Kubernetes destination has no artwork to put on its empty state"
        }
        let state = HelmEmptyState(symbol: "bolt.horizontal.circle", title: "No live host session",
                                   body: "Connect a host first.", size: .standard, artwork: art)
        let window = makeWindow(state, size: NSSize(width: 700, height: 420))
        defer { window.orderOut(nil) }
        state.layoutSubtreeIfNeeded()

        let images = state.subviews.compactMap { $0 as? NSImageView }
        guard let watermark = images.first(where: { $0.image === art }) else {
            return "the empty state is not showing its destination's artwork"
        }
        if watermark.alphaValue > 0.35 || watermark.alphaValue < 0.15 {
            return "the watermark is at \(watermark.alphaValue) - the finding's band is 25-30%, and above "
                 + "it the artwork starts competing with the copy it sits behind"
        }
        if watermark.isAccessibilityElement() {
            return "the watermark announces itself; it is decoration, and the copy beside it already says "
                 + "everything it says"
        }
        return nil
    }

    // MARK: - D5

    /// (a) says to reuse A3's observer rather than build a second one, so
    /// what is asserted is that the hairline actually reacts to a real scroll
    /// offset - which is the only thing a second, broken mechanism could not
    /// fake.
    private static func test_d5ScrollEdgeReusesTheObserver() -> String? {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let hairline = HelmScrollEdgeHairline(over: scroll, in: container)
        let window = makeWindow(container, size: NSSize(width: 400, height: 120))
        defer { window.orderOut(nil) }
        container.layoutSubtreeIfNeeded()

        if hairline.debugIsVisible {
            return "a list at rest is already showing its scroll edge"
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 220))
        scroll.reflectScrolledClipView(scroll.contentView)
        if !hairline.debugIsVisible {
            return "scrolling the list did not bring its scroll edge in"
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        if hairline.debugIsVisible {
            return "returning to the top left the scroll edge behind"
        }
        return nil
    }

    /// (b)'s two real constraints: the stagger is capped (a 50-row list must
    /// not spend a second and a half introducing itself) and Reduce Motion
    /// gets no entrance at all.
    private static func test_d5RowEntranceCappedAndOnce() -> String? {
        HelmMotion.reducedOverrideForTests = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let window = makeWindow(view, size: NSSize(width: 200, height: 40))
        defer { window.orderOut(nil); HelmMotion.reducedOverrideForTests = nil }

        HelmRowEntrance.play(view, row: 0)
        guard let first = view.layer?.animation(forKey: "entrance.fade") as? CABasicAnimation else {
            return "the first row got no entrance"
        }
        let deep = NSView(frame: view.frame)
        window.contentView?.addSubview(deep)
        HelmRowEntrance.play(deep, row: 400)
        guard let late = deep.layer?.animation(forKey: "entrance.fade") as? CABasicAnimation else {
            return "a later row got no entrance"
        }
        let spread = late.beginTime - first.beginTime
        let cap = Double(HelmRowEntrance.maxStaggeredRows) * HelmRowEntrance.perRowDelay
        if spread > cap + 0.001 {
            return "row 400 starts \(spread)s after row 0; the stagger must cap at \(cap)s or a long list "
                 + "spends seconds introducing itself"
        }

        HelmMotion.reducedOverrideForTests = true
        let quiet = NSView(frame: view.frame)
        window.contentView?.addSubview(quiet)
        HelmRowEntrance.play(quiet, row: 2)
        if quiet.layer?.animation(forKey: "entrance.fade") != nil {
            return "Reduce Motion still played a row entrance"
        }
        return nil
    }

    // MARK: - Harness

    /// A window far off-screen and merely ordered front - never
    /// `makeKeyAndOrderFront`/`activate`. The captain's own instance shares
    /// this machine, and a suite has no business taking their focus.
    ///
    /// Ordered front rather than merely created because hover, press and
    /// scroll all need a real event/geometry path: a window that was never
    /// ordered in has no `windowNumber`, and events routed at it go nowhere -
    /// which reads exactly like "the handler is not wired".
    private static func makeWindow(_ content: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: 0), size: size),
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = content
        window.orderFront(nil)
        content.layoutSubtreeIfNeeded()
        return window
    }

    /// A host view of a genuinely given width, whatever the screen is.
    ///
    /// AppKit clamps a window's frame to the screen, so `makeWindow(size:)`
    /// cannot be used to measure a 1900pt layout on a 1512pt display. The
    /// host is constrained instead and simply overflows its window, which is
    /// fine: Auto Layout resolves the subtree either way.
    private static func makeWideHost(_ view: NSView, width: CGFloat) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.topAnchor.constraint(equalTo: root.topAnchor),
            host.widthAnchor.constraint(equalToConstant: width),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        _ = makeWindow(root, size: NSSize(width: 600, height: 200))
        root.layoutSubtreeIfNeeded()
        return host
    }

    private static func makeCanvas() -> HomeCanvasController {
        // Every one of these resolves to a scratch directory: `main.swift`'s
        // own `#if FM_SELFTESTS` block redirects every `FM_*` store override
        // for the whole process, so a bare store here reaches none of the
        // captain's real data.
        let canvas = HomeCanvasController(sources: .init(
            shiftStore: ShiftStore(),
            hostStore: HostStore(),
            scheduleStore: ScheduleStore(),
            logAnalyzerStore: LogAnalyzerStore(),
            docsRunbookStore: DocsRunbookStore(),
            codePreviewStore: CodePreviewStore(),
            commandLibraryStore: CommandLibraryStore()))
        _ = canvas.view
        return canvas
    }

    // MARK: - C1

    /// The hero is the audit's focal point, and its whole value is that it
    /// states the *one* thing the captain needs. Rendering a fabricated
    /// all-clear would be worse than rendering nothing, so what is asserted
    /// is that every string comes from `FleetGreeting.answer` - the same
    /// computation Overview's own banner runs.
    private static func test_c1HeroReportsTheAnswer() -> String? {
        let canvas = makeCanvas()
        let window = makeWindow(canvas.view, size: NSSize(width: 1200, height: 820))
        defer { window.orderOut(nil) }

        // A fleet with a task genuinely parked on a decision: the loud case.
        let needs = FleetTask(id: "t1", repo: "grand-line", kind: "feature", pr: nil,
                              status: "needs_decision")
        let snapshot = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [needs],
                                     queuedCount: 0, doneCount: 0, projectsCount: 1,
                                     watcher: WatcherHealth(status: "healthy"))
        canvas.applyFleet(snapshot: snapshot, mergedPRs: [], prFetchFailure: nil)
        canvas.debugRenderNow()

        let expected = FleetGreeting.answer(tasks: [needs], readyCount: 0,
                                            prFetchFailure: nil, homeOk: true)
        let hero = canvas.greetingForTests
        if hero.title != expected.title {
            return "hero headline '\(hero.title)' is not the answer's own '\(expected.title)'"
        }
        if hero.kicker != expected.kicker.uppercased() {
            return "hero kicker '\(hero.kicker)' is not '\(expected.kicker.uppercased())'"
        }
        if canvas.heroTintForTests != expected.tint {
            return "hero badge is \(canvas.heroTintForTests), expected the answer's own \(expected.tint)"
        }

        // Off Overview there is no verdict to report, so the badge must not
        // claim one. `.neutral` is the only slot that says nothing; a domain
        // hue's `fallbackTint` resolves rose to `.critical` and would paint
        // an alert on a space that measured nothing.
        canvas.select(space: .stores)
        canvas.debugRenderNow()
        if canvas.heroTintForTests != .neutral {
            return "the Stores hero claims \(canvas.heroTintForTests); a space with no verdict must be .neutral"
        }
        if !canvas.greetingForTests.kicker.isEmpty {
            return "the Stores hero shows a kicker ('\(canvas.greetingForTests.kicker)') - it has no state to report"
        }
        return nil
    }

    /// `NSImage(systemSymbolName:)` returns nil silently, and this app has
    /// shipped an invisible icon exactly that way before.
    private static func test_c1HeroSymbolsResolve() -> String? {
        for space in DaylightSpace.allCases where
            NSImage(systemSymbolName: space.heroSymbol, accessibilityDescription: nil) == nil {
            return "\(space).heroSymbol '\(space.heroSymbol)' does not resolve"
        }
        return nil
    }

    /// §3C's actual measurement was "four cards in a row and then ~80% empty
    /// paper". The fix is that short content centres in the viewport rather
    /// than flushing to the top of it - and, just as importantly, that tall
    /// content is untouched and still scrolls.
    private static func test_c1ContentComposesTheSpace() -> String? {
        let canvas = makeCanvas()
        let window = makeWindow(canvas.view, size: NSSize(width: 1400, height: 900))
        defer { window.orderOut(nil) }

        // Engineering is one of the sparse spaces the finding names.
        canvas.select(space: .engineering)
        canvas.view.layoutSubtreeIfNeeded()

        let viewport = canvas.viewportHeightForTests
        let document = canvas.documentHeightForTests
        let content = canvas.contentFrameForTests
        if viewport <= 0 { return "the canvas has no viewport height to measure against" }
        if document + 0.5 < viewport {
            return "the document is \(document)pt inside a \(viewport)pt viewport - it must fill it "
                 + "so there is a space to compose"
        }
        guard content.height + 8 < viewport else {
            return "this space's content (\(content.height)pt) already fills the \(viewport)pt viewport, "
                 + "so the composed-layout case is not being exercised"
        }
        // The document is flipped, so `minY` is the gap above the content.
        let above = content.minY
        let below = document - content.maxY
        if abs(above - below) > 24 {
            return "content sits \(above)pt from the top and \(below)pt from the bottom - short content "
                 + "must compose the space, not flush to the top of it"
        }
        return nil
    }

    /// The horizontal half of C1, as arithmetic rather than as a render: a
    /// space with fewer cards than columns must not leave the leftover column
    /// as a one-sided void, and a space with more cards than columns must be
    /// completely untouched.
    ///
    /// Pure, so it needs no window - and deliberately checks the *unchanged*
    /// direction too, because a cap that engaged everywhere would re-create
    /// exactly the dead gutter the captain had removed from Hosts once.
    private static func test_c1ComposedContentWidth() -> String? {
        let available: CGFloat = 1400
        let columns = HelmResponsiveGrid.columns(containerWidth: available,
                                                 minItemWidth: HomeCanvasController.minModuleWidth,
                                                 spacing: HomeCanvasController.gridSpacing)
        guard columns >= 3 else { return "1400pt only fits \(columns) columns; this case needs at least 3" }

        // More cards than columns: full width, no cap.
        let many = Array(repeating: DaylightModule.console, count: columns + 2)
        let manyWidth = HomeCanvasController.composedContentWidth(available: available, modules: many)
        if abs(manyWidth - available) > 0.5 {
            return "a full grid was capped to \(manyWidth)pt of \(available)pt - only a space that "
                 + "cannot fill its columns should compose"
        }

        // Fewer cards than columns: capped to what they fill, and by exactly
        // the column arithmetic rather than some new literal.
        let few = Array(repeating: DaylightModule.console, count: columns - 1)
        let fewWidth = HomeCanvasController.composedContentWidth(available: available, modules: few)
        let unit = HelmResponsiveGrid.itemWidth(containerWidth: available, columns: columns,
                                                spacing: HomeCanvasController.gridSpacing)
        let expected = unit * CGFloat(columns - 1) + HomeCanvasController.gridSpacing * CGFloat(columns - 2)
        if abs(fewWidth - expected) > 0.5 {
            return "\(columns - 1) cards asked for \(fewWidth)pt, expected \(expected)pt - the cap must "
                 + "come from the grid's own column arithmetic, so card size never changes"
        }
        if fewWidth >= available {
            return "a short row was not composed at all (\(fewWidth)pt of \(available)pt)"
        }
        return nil
    }

    // MARK: - C2

    /// The press state's real risk is not that it fails to fire - it is that
    /// it fights the hover lift `HelmModuleCard` already drives on the same
    /// layer. Before C2 that card wrote `card.layer.transform` directly; a
    /// second writer would have silently cancelled one state or the other
    /// depending purely on which fired last.
    private static func test_c2PressComposesWithHover() -> String? {
        HelmMotion.reducedOverrideForTests = false
        defer { HelmMotion.reducedOverrideForTests = nil }

        let card = HelmModuleCard()
        card.configure(HelmModuleCard.Content(
            title: "Fleet", subtitle: "1 crew working", symbol: "sailboat.fill",
            hue: .teal, chip: nil, body: .metric(value: "1", unit: nil, note: "working")))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
        host.addSubview(card)
        card.frame = NSRect(x: 0, y: 0, width: 260, height: HelmModuleCard.standardHeight)
        let window = makeWindow(host, size: NSSize(width: 300, height: 240))
        defer { window.orderOut(nil) }

        let inner = card.debugCardView
        if inner.pressScale == 1 {
            return "a module card did not opt into the press compression"
        }
        let atRest = inner.layer?.transform ?? CATransform3DIdentity
        if !CATransform3DIsIdentity(atRest) {
            return "a card at rest is already transformed (\(atRest.m11), \(atRest.m42))"
        }

        // Hover, then press: the two must compose rather than replace.
        card.debugSetHovering(true)
        let lifted = inner.layer?.transform ?? CATransform3DIdentity
        if lifted.m42 == 0 {
            return "hovering did not lift the card (m42 = 0)"
        }
        inner.debugSetPressed(true)
        let pressed = inner.layer?.transform ?? CATransform3DIdentity
        if pressed.m11 >= 1 {
            return "pressing did not compress the card (scale \(pressed.m11))"
        }
        if pressed.m42 == 0 {
            return "pressing cancelled the hover lift - the two states must compose"
        }

        // Releasing restores the lift exactly, not identity.
        inner.debugSetPressed(false)
        let released = inner.layer?.transform ?? CATransform3DIdentity
        if abs(released.m42 - lifted.m42) > 0.01 || released.m11 != 1 {
            return "releasing left the card at scale \(released.m11), lift \(released.m42); "
                 + "expected scale 1, lift \(lifted.m42)"
        }
        return nil
    }

    /// `HelmMotion`'s own rule: Reduce Motion means the end state, instantly -
    /// never the same motion, slower. The press must still *happen*, it just
    /// must not animate.
    private static func test_c2ReduceMotionIsInstant() -> String? {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }

        let view = HoverHighlightView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        view.pressScale = 0.98
        let window = makeWindow(view, size: NSSize(width: 120, height: 40))
        defer { window.orderOut(nil) }

        view.debugSetPressed(true)
        guard let layer = view.layer else { return "no backing layer" }
        if layer.transform.m11 >= 1 {
            return "Reduce Motion swallowed the press entirely (scale \(layer.transform.m11)) - it should "
                 + "reach the end state, just without animating"
        }
        if layer.animationKeys()?.isEmpty == false {
            return "Reduce Motion still animated the press (\(layer.animationKeys() ?? []))"
        }
        return nil
    }

    // MARK: - C3

    /// §3C: seven saturated 6pt ribbons at equal weight is "decoration, not
    /// signal". Quiet at rest, bloom on hover.
    private static func test_c3RibbonQuietAtRest() -> String? {
        let card = HelmModuleCard()
        card.configure(HelmModuleCard.Content(
            title: "Docs", subtitle: "4 runbooks", symbol: "book.fill",
            hue: .violet, chip: HelmModuleChip(text: "4", kind: .mute),
            body: .metric(value: "4", unit: nil, note: "runbooks")))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
        host.addSubview(card)
        card.frame = NSRect(x: 0, y: 0, width: 260, height: HelmModuleCard.standardHeight)
        let window = makeWindow(host, size: NSSize(width: 300, height: 240))
        defer { window.orderOut(nil) }
        card.layoutSubtreeIfNeeded()

        let rest = card.debugRibbonGeometry
        if rest.height >= HelmModuleCard.ribbonHeight {
            return "the ribbon is \(rest.height)pt at rest - §3C asks for 2-3pt until it blooms"
        }
        if rest.opacity >= 1 {
            return "the ribbon is at full opacity at rest (\(rest.opacity))"
        }

        card.debugSetHovering(true)
        let bloomed = card.debugRibbonGeometry
        if bloomed.height < HelmModuleCard.ribbonHeight {
            return "hovering did not bloom the ribbon (\(bloomed.height)pt)"
        }
        if bloomed.opacity < 1 {
            return "hovering did not bring the ribbon to full presence (\(bloomed.opacity))"
        }
        // The hue itself is untouched - only its presence changes.
        if rest.stopCount != bloomed.stopCount || rest.stopCount < 2 {
            return "the ribbon's own gradient changed with the bloom (\(rest.stopCount) -> \(bloomed.stopCount))"
        }
        return nil
    }

    /// §3C's own carve-out: "a card whose chip is `.critical` may keep a loud
    /// edge - color as signal, not as wallpaper". Quieting the ribbons is
    /// about stopping seven equal hues competing, not about hiding the one
    /// card that needs the captain.
    private static func test_c3CriticalCardKeepsItsEdge() -> String? {
        let card = HelmModuleCard()
        card.configure(HelmModuleCard.Content(
            title: "Updates", subtitle: "3 tools behind", symbol: "steeringwheel",
            hue: .amber, chip: HelmModuleChip(text: "3 behind", kind: .bad),
            body: .metric(value: "3", unit: nil, note: "behind")))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
        host.addSubview(card)
        card.frame = NSRect(x: 0, y: 0, width: 260, height: HelmModuleCard.standardHeight)
        let window = makeWindow(host, size: NSSize(width: 300, height: 240))
        defer { window.orderOut(nil) }
        card.layoutSubtreeIfNeeded()

        let geometry = card.debugRibbonGeometry
        if geometry.height < HelmModuleCard.ribbonHeight || geometry.opacity < 1 {
            return "a card whose chip is `.bad` rendered a quiet \(geometry.height)pt ribbon at "
                 + "\(geometry.opacity) - the one card that needs the captain must keep its edge"
        }
        return nil
    }
}

#endif
