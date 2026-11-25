// Grand Line - native macOS app.
//
// The shell's body, in a real window: the cases from `AppShellBodyWidthSelfTest`
// that measure code the sidebar shell still runs. P-03 of the 2026-11-25 full
// review removed the floating bar, and with it `AppShellController`, its
// body-width tie and its repair (gotcha (14)'s worked example) and its space
// pills. Their cases went with them. These stayed, ported to
// `MainSplitShellController`:
//
//   - Gotcha (15): a hidden page is taken out of the window's constraint
//     graph (`WorkspaceContent.setDestinationVisible`), and a revisited page
//     is put back and laid out at the body's width.
//   - The Health card's wrapping descriptions converge over repeated layout.
//   - A `HelmModuleCard` deallocates once removed, and a plain `NSStackView`
//     does not leak a generation of arranged subviews.
//
// Window-backed: listed in `NEEDS_SESSION`. Run with
// `FM_RUN_WORKSPACE_BODY_TESTS=1 .build/debug/GrandLine`.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum WorkspaceBodySelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("healthCardDescriptionWidthConverges", test_healthCardLayoutConverges),
            ("moduleCardDeallocatesAfterRemoval", test_moduleCardTrackingAreaDoesNotLeak),
            ("plainStackViewArrangedSubviewRemovalDoesNotLeak", test_stackViewArrangedSubviewRemovalLeaksOneGeneration),
            ("onlyTheShowingDestinationIsInTheWindowsConstraintGraph", test_hiddenDestinationsLeaveTheConstraintGraph),
            ("aRevisitedDestinationIsPutBackIntoTheGraph", test_revisitingReattachesTheDestination),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
            ? "WorkspaceBodySelfTest: all \(cases.count) cases passed"
            : "WorkspaceBodySelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    /// The shell the app builds, mounted in a real window that is never
    /// ordered front (`ReviewTourLab.makeOffScreenShell`).
    private static func makeMountedShell() -> (window: NSWindow, shell: MainSplitShellController) {
        ReviewTourLab.makeOffScreenShell()
    }

    /// A fresh scratch directory per call, so every store this test touches
    /// (`HostStore`/`SSHKeyStore`/`SnippetStore`/`ShiftStore`/`DictationStore`)
    /// reads/writes disposable files under it - never the captain's real
    /// saved hosts/keys/snippets/tasks/dictation data - matching this app's
    /// established `FM_*_FILE`/`FM_*_DIR` scratch-override convention (see
    /// AGENTS.md).
    ///
    /// `FM_DOCS_RUNBOOKS_DIR` was added by `fm/grandline-docs-split-runbooks-
    /// postmortems` - see `DestinationMountingSelfTest.withScratchEnv`'s own
    /// doc comment for why `RunbooksController`/`PostmortemsController` (and
    /// `.docs` before them) need it: with no override, `DocsRunbookStore()`
    /// falls through to a real clone of the captain's `manjesh-config` repo.
    /// `bodyContainerTracksWindowAcrossAllDestinations` below visits every
    /// `RailDestination`, so this harness needs the same protection.
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-workspace-body-test-\(UUID().uuidString)")
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

        // The env overrides above isolate every FILE this suite touches, but
        // not `UserDefaults` - and mounting a real shell writes
        // there. Measured: this suite left `fm.themeID = dusk` behind, and the
        // suites that run after it in `run-all-tests.sh` then measured
        // theme-derived geometry under an ambient theme nobody selected, so
        // `FM_RUN_CONTRAST_TESTS` and `FM_RUN_DAYLIGHT_DRILL_SLICE2_TESTS`
        // failed intermittently on a clean tree. Worse, the leak is
        // *persistent*: a run interrupted before this restore poisons every
        // subsequent run of every suite until the domain is cleared by hand,
        // which reads exactly like a flaky test and is not one.
        //
        // Saved and restored here rather than fixed at the write site, because
        // writing the selection is correct behaviour for the app - it is only
        // a test that must not keep it.
        let savedTheme = ThemeManager.shared.theme
        let savedFontSize = AppSettings.shared.fontSize
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.fontSize = savedFontSize
        }
        return body()
    }

    /// `fm/grandline-daylight-shell-regressions`: investigates a specific
    /// hypothesis for the captain's reported sustained-CPU/input-lag report.
    /// `HealthCardView.layoutDidChange()` (added in Daylight Phase 0) re-derives
    /// each description label's `preferredMaxLayoutWidth` from `card.bounds.width`
    /// on every layout pass - a real, live AppKit feedback loop is possible
    /// here in principle (wrap width -> wrapped line count -> document height ->
    /// non-overlay vertical scroller visibility -> clip width -> wrap width
    /// again), which would show up as continuous main-thread layout work with
    /// no user input at all. Seeds every `HealthService` with a long failure
    /// detail so the description labels genuinely wrap, then forces 40
    /// explicit layout passes at 11 window heights spanning the range where a
    /// scroller could plausibly toggle, checking `card.bounds.width` settles
    /// rather than alternating. **Result: it converges at every height
    /// tried** - this hypothesis did not reproduce. (Separately confirmed by
    /// reading `NSScrollView`'s own behaviour: with a non-overlay/`.legacy`
    /// scroller style, `hasVerticalScroller = true` reserves the scrollbar's
    /// width track unconditionally, not only once content overflows, so the
    /// clip width this card reads never actually depends on the document's
    /// own height in the first place - there is no feedback path to close.)
    /// Kept as permanent coverage since `layoutDidChange()`'s mechanism is
    /// still real, load-bearing code that a future edit could genuinely break.
    private static func test_healthCardLayoutConverges() -> String? {
        withScratchEnv {
            let window = OffScreenProbe.window(width: 620, height: 700, styleMask: [.titled, .resizable])
            let health = HealthController()
            window.contentViewController = health
            // Force the non-overlay scroller style: without a real mouse
            // attached, this sandbox's own `NSScroller.preferredScrollerStyle`
            // would default to `.overlay` (no width impact at all), which
            // would make this test incapable of ever exercising the one
            // scroller behaviour ("Show scroll bars: Always", AGENTS.md
            // gotcha #4) that could plausibly feed back into this card's
            // width in the first place.
            health.debugForceLegacyScrollerStyle()

            // Seed every known service with a real failure carrying a long
            // detail string, so the description labels actually wrap (the
            // mechanism this probe is checking) rather than fitting on one
            // line regardless of width.
            for service in HealthService.allCases {
                ServiceHealthRegistry.shared.recordFailure(
                    service,
                    "A deliberately long failure detail string, long enough to wrap across "
                    + "more than one line at any width this probe will try, so a change in "
                    + "available width always changes the number of wrapped lines.")
            }
            // Let the registry's async `DispatchQueue.main.async` notify land
            // before measuring - `recordFailure`/`mutate` dispatch to main.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))

            var failures: [String] = []
            for height in [CGFloat(300), 340, 360, 380, 400, 420, 460, 520, 600, 700, 900] {
                window.setFrame(NSRect(x: 0, y: 0, width: 620, height: height), display: true)
                var widths: [CGFloat] = []
                for _ in 0..<40 {
                    health.view.layoutSubtreeIfNeeded()
                    widths.append(health.debugCardWidth)
                }
                let distinctTrailing = Set(widths.suffix(10).map { ($0 * 10).rounded() / 10 })
                if distinctTrailing.count > 1 {
                    failures.append("height=\(height): card width did not converge over 40 forced layout "
                        + "passes - last 10 values: \(widths.suffix(10))")
                }
            }
            return failures.isEmpty ? nil : failures.joined(separator: " | ")
        }
    }

    /// `fm/grandline-daylight-shell-regressions`: a second hypothesis for the
    /// sustained-CPU report. `HelmModuleCard`'s own hover `NSTrackingArea`
    /// (`owner: self`) is a textbook shape for an un-breakable retain cycle -
    /// the tracking area retains its owner, and the card retains the tracking
    /// area as a stored property - and `HomeCanvasController.rebuildGrid()`
    /// tears down and rebuilds all fifteen cards on every space switch and
    /// every width change. `DaylightModuleSelfTest`'s own leak check already
    /// covers `ThemeManager` observer count (with an `autoreleasepool`
    /// wrapper it explicitly notes is needed only because a headless suite
    /// never drains the pool a real run loop would) but never puts a card in
    /// a real window, so `updateTrackingAreas()` may never actually run there
    /// - a leak sourced from *that* mechanism specifically would be invisible
    /// to it. This test mounts one card in a real (never shown - see the
    /// window comment below) `NSWindow`, forces a real layout+display pass so
    /// tracking areas genuinely resolve, removes the card, and checks a
    /// `weak` reference. **Result: it deallocates cleanly** - this hypothesis
    /// did not reproduce either; whatever this AppKit version does with a
    /// removed view's own tracking areas, it does not leave this pair
    /// permanently retaining each other. Kept as permanent regression
    /// coverage for exactly the failure mode it was written to catch.
    private static func test_moduleCardTrackingAreaDoesNotLeak() -> String? {
        // Deliberately never ordered front - per this project's own
        // convention (`OffScreenProbe`), a self-test
        // window must never visibly disturb a shared machine. `layout()` +
        // `displayIfNeeded()` still resolve tracking areas for a view that is
        // genuinely part of a real window's view hierarchy.
        let window = OffScreenProbe.window(width: 400, height: 300, styleMask: [.titled, .resizable])

        weak var weakCard: HelmModuleCard?
        autoreleasepool {
            let card = HelmModuleCard()
            card.configure(.init(title: "Title", subtitle: "sub", symbol: "sailboat.fill",
                                 hue: .teal, chip: nil, body: .note("hi")))
            card.frame = NSRect(x: 0, y: 0, width: 300, height: 170)
            window.contentView?.addSubview(card)
            // Force AppKit to actually resolve tracking areas for a view that
            // is genuinely in a real, ordered-front window - `layout()` alone
            // (what the headless suite calls) does not guarantee
            // `updateTrackingAreas()` runs; a real display pass does.
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            card.removeFromSuperview()
            weakCard = card
        }
        // Give the real run loop a moment to drain autorelease pools /
        // process any deferred AppKit cleanup, exactly as a live app's event
        // loop would between ticks.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        guard weakCard == nil else {
            return "HelmModuleCard did not deallocate after removeFromSuperview() - "
                + "its own hover NSTrackingArea (owner: self) is a likely retain cycle"
        }
        return nil
    }

    /// `fm/grandline-daylight-shell-regressions`: was built to isolate the
    /// mechanism behind what looked, at the time, like a real,
    /// permanent-but-bounded one-batch-behind retention in
    /// `HomeCanvasController`'s own grid rebuild -
    /// `fm/grandline-daylight-canvas-orphaned-render-fix` later found that
    /// retention was never real (see `test_initialCanvasRenderIsOrphanedOnce`'s
    /// own doc comment) - by removing `HomeCanvasController`/`HelmModuleCard`
    /// from the picture entirely, while matching `rebuildGrid()`'s exact
    /// two-level structure: an outer `gridStack`-equivalent holding
    /// per-rebuild *row* stack views (not the cards directly), each row
    /// carrying the same explicit `row.widthAnchor.constraint(equalTo:
    /// gridStack.widthAnchor).isActive = true` `rebuildGrid()` adds after
    /// `addArrangedSubview` - plain `NSView`s inside each row, added/removed
    /// the same way (`addArrangedSubview` then, on the next cycle,
    /// `removeArrangedSubview` + `removeFromSuperview()`), with no theme
    /// observers, no gesture recognizers, no tracking areas at all. If the
    /// same shape reproduces here, the mechanism is this exact
    /// two-level-stack-plus-explicit-constraint structure (or `NSStackView`'s
    /// own internal bookkeeping around it), not anything specific to this
    /// app's module cards.
    private static func test_stackViewArrangedSubviewRemovalLeaksOneGeneration() -> String? {
        let gridStack = NSStackView()
        gridStack.orientation = .vertical

        // Track liveness the same direct way `HelmModuleCard.
        // debugLiveInstanceCount` does, via a tiny counted subclass local to
        // this test.
        final class CountedView: NSView {
            static var live = 0
            override init(frame: NSRect) { super.init(frame: frame); Self.live += 1 }
            required init?(coder: NSCoder) { fatalError() }
            deinit { Self.live -= 1 }
        }

        func rebuildCounted() {
            for row in gridStack.arrangedSubviews {
                gridStack.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            let row = NSStackView(views: (0..<15).map { _ -> NSView in
                let v = CountedView()
                v.translatesAutoresizingMaskIntoConstraints = false
                return v
            })
            row.orientation = .horizontal
            row.translatesAutoresizingMaskIntoConstraints = false
            gridStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: gridStack.widthAnchor).isActive = true
        }

        autoreleasepool { rebuildCounted() }
        let baseline = CountedView.live
        var excesses: [Int] = []
        for i in 0..<20 {
            autoreleasepool { rebuildCounted() }
            if i % 4 == 3 { excesses.append(CountedView.live - baseline) }
        }
        let distinct = Set(excesses)
        guard distinct != [0] else {
            return nil // ruled out: plain NSStackView add/remove does not leak a generation on its own
        }
        return "a plain NSStackView, with no HelmModuleCard/HomeCanvasController involved at all, "
            + "reproduces the same shape - excess counts across checkpoints: \(excesses) "
            + "(baseline \(baseline)) - so the mechanism is NSStackView's own arranged-subview "
            + "removal bookkeeping, not anything specific to this app's module cards"
    }

    /// Full review #3's **PF1**. A hidden `NSView` still participates fully
    /// in Auto Layout (AGENTS.md gotcha (11) says so in the other
    /// direction), so GL-37's ~27 permanently-mounted destinations were one
    /// required-constraint chain inside the window - and AppKit re-walks that
    /// whole chain every time anything invalidates the window's
    /// `minFullScreenContentSize`, which a single live-updating label is
    /// enough to do.
    ///
    /// Measured on the captain's own running instance: 1095 of 4072
    /// main-thread samples (26.9%) inside CoreAutoLayout under
    /// `_doUpdateTilingConstraintsImmediately`. A standalone stock-AppKit
    /// probe put the cost at near-linear in the mounted count and at
    /// **zero** for a settled graph of any size - so this is the re-solve,
    /// not stock idle work.
    ///
    /// This asserts the property the fix turns on, which no frame
    /// measurement can see: a page that is not showing has no active pins to
    /// `bodyContainer`.
    private static func test_hiddenDestinationsLeaveTheConstraintGraph() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            _ = window
            // Visit several destinations so more than one is mounted - the
            // whole finding is about what mounting *accumulates*.
            for dest in [RailDestination.overview, .console, .hosts, .settings] {
                shell.workspace.navigator.show(dest)
            }
            shell.view.layoutSubtreeIfNeeded()

            let state = shell.destinationLayoutAttachmentForTests
            // Fixture discrimination first: if only one page ever got
            // embedded, "hidden pages are detached" is vacuously true.
            guard state.embedded >= 4 else {
                return "expected at least 4 embedded destinations after visiting 4, got \(state.embedded)"
            }
            guard state.showing == 1 else {
                return "expected exactly 1 showing destination, got \(state.showing) of \(state.embedded)"
            }
            guard state.attached == 1 else {
                return "expected only the showing destination to hold active constraints to bodyContainer, "
                    + "got \(state.attached) attached of \(state.embedded) embedded - "
                    + "every hidden page is back in the window's constraint graph (PF1)"
            }
            return nil
        }
    }

    /// The other direction, which matters more than the saving: coming back
    /// to a page must put it back in the graph and lay it out at the body's
    /// real width. A detach that never reattaches is a blank page, which is
    /// a far worse bug than the cost it was removing.
    private static func test_revisitingReattachesTheDestination() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            shell.workspace.navigator.show(.hosts)
            shell.workspace.navigator.show(.settings)
            shell.view.layoutSubtreeIfNeeded()
            // Back to the one that is now detached.
            shell.workspace.navigator.show(.hosts)
            shell.view.layoutSubtreeIfNeeded()

            let state = shell.destinationLayoutAttachmentForTests
            guard state.attached == 1, state.showing == 1 else {
                return "after revisiting, expected 1 showing and 1 attached, "
                    + "got showing=\(state.showing) attached=\(state.attached)"
            }
            // And it is actually laid out, not merely re-pinned: a reattached
            // page has to reach the body's real width.
            _ = window
            let expected = shell.bodyContainerFrameForTests.width
            guard expected > 0 else { return "the body never laid out - the width check would be vacuous" }
            guard let showingWidth = shell.showingDestinationWidthForTests else {
                return "no destination is showing after revisiting it"
            }
            guard abs(showingWidth - expected) < 0.5 else {
                return "a revisited destination laid out at \(showingWidth), expected the body's \(expected)"
            }
            return nil
        }
    }
}

#endif
