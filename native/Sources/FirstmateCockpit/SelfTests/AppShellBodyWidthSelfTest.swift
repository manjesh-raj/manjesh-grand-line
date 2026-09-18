// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-live-gap-rootcause-scout`: regression coverage for the
// captain-reported "black/blank gap on the right side of the window" bug.
// The scout report (`data/grandline-live-gap-rootcause-scout/report.md`)
// captured, live, on the captain's own running instance:
//
//   window.frame                = {{0, 0}, {1033, 949}}
//   contentView.frame           = {{0, 0}, {1032.5, 949}}   (tracks window)
//   bodyContainer.frame         = {{84, 0}, {1428, 949}}    (does NOT)
//
// `bodyContainer`'s width (1428) matched the *screen's* width minus the
// rail (1512 - 84), not the window's real, current width minus the rail
// (1033 - 84 = 949) - a 479pt discrepancy repeated identically across
// `bodyContainer` and all twelve destination views mounted inside it. This
// file builds a real `AppShellController` inside a real `NSWindow` (the
// same shape `BlockViewHierarchySelfTest.swift`/`SRELeadPerTabSelfTest.swift`
// already use for this kind of real-view-hierarchy regression test) and
// drives real window resizes through it, asserting `bodyContainer`'s width
// tracks the window's actual current content width at every step - the
// property this task's report found to be violated.
//
// The first two cases are ordinary sanity coverage; they can pass even on
// a build that never hits the specific staleness this task fixed, since a
// freshly-built, freshly-resized hierarchy has no reason to already be
// stale. The third case, `widthSelfHealsAfterATieIsSilentlyBroken`, is what
// actually proves the fix: it deliberately reproduces the exact starting
// condition the live bug exhibited (the width tie inactive, the frame
// stuck at a stale, screen-sized value) via
// `AppShellController.debugBreakBodyWidthTieForTests()`, then fires a real
// resize and asserts `reassertBodyContainerWidthTie()` (wired to
// `NSWindow.didResizeNotification`) repairs it. Confirmed live, per this
// project's own convention, to actually catch a regression rather than
// just pass: temporarily reverting `AppShellController.swift`'s fix (no
// resize observer, no reactivation) makes this exact case fail - the frame
// stays at its stale, pre-break value after the resize, since nothing
// notices the tie is inactive - and reapplying the fix makes it pass again.
//
// `fm/grand-line-body-width-selfheal-layout-fix` then closed the *trigger*
// gap that case could not see: the repair it exercises had exactly two call
// sites, `loadView` and the resize observer, so a tie broken for any other
// reason stayed broken until the captain resized or restarted - which is
// what he had to do. `widthSelfHealsOnALayoutPassWithNoResize` is that
// task's coverage, and it deliberately fires **no** resize; see its own doc
// comment for why it asserts the tie's activity rather than a stale frame
// (measured: a frame assertion cannot distinguish the two builds here).
//
// `fm/grandline-log-analyzer-body-width-regression` found and fixed a SECOND,
// unrelated way to reach this same symptom (identical geometry, but nothing
// to do with the width-tie staleness above): `LogAnalyzerController`'s
// Compare tab ties `comparePopupBefore`/`comparePopupAfter` to their own
// column at `.required`. That tie is a real, externally-added constraint -
// not one a stack's own `.gravityAreas`/arrangement math would skip for a
// hidden arranged subview - so it stayed fully binding straight through the
// Compare tab (hidden until chosen), `tabContainer` (hidden until an
// analysis exists) and this destination's own root, all the way up to
// `bodyContainer`. A popup's intrinsic width comes from its populated menu
// items (`renderComparePickers()` always adds at least one, and one per
// captured evidence label - free-form text a captain can make arbitrarily
// long), so it could cap the *whole window* at whatever width those items
// needed - on every destination, not just Log Analyzer, since bodyContainer
// is shared. `test_bodyContainerTracksWindowAcrossRealisticWidths` below is
// the regression coverage for that fix - confirmed live, per this project's
// convention, to actually catch it: reverting the `LogAnalyzerController`
// fix (dropping that tie back to `.required`) fails this case at every one
// of its swept widths, not just one, and reapplying the fix passes it again.
//
// `fm/grandline-body-width-regression-recur` found and fixed a THIRD way to
// reach this same symptom, and - unlike the first two, which were each fixed
// in isolation - closed the actual structural gap this time: neither of the
// two cases above ever visits a *lazily*-mounted destination
// (`DestinationRegistry.swift`'s non-`mountsEagerly` set - Hosts, Tasks, Log
// Analyzer, Tools, Vault, Dictation, Schedules, Health, Docs, the other three
// Setup pages, Settings), so a bug confined to one of those could ship clean
// through this whole file, and did: `ToolsController`'s landing-grid title
// label set `.byTruncatingTail` but never lowered its horizontal compression
// resistance off `NSTextField`'s own >500-priority default, so a rebuild at a
// wide window baked an oversized floor into the (permanently-mounted, only-
// ever-hidden - GL-37) Tools view that stuck around long after Tools was
// hidden again, capping every other destination's minimum window width via
// the shared `bodyContainer`. See `test_widthTracksAcrossAllDestinations`'s
// own doc comment for the full root-cause writeup and why its sweep - every
// `RailDestination`, not just the eager three - is what should keep this from
// recurring a fourth time.
//
// `fm/grandline-daylight-shell-regressions` investigated a captain-reported
// recurrence of this same symptom against Daylight Phase 2 (#257) - a
// "blank/black area on the right side of the window" while `.console` was
// showing - plus a separately-reported sustained-CPU/input-lag symptom the
// captain suspected was related (Activity Monitor: ~85% CPU, near-zero idle
// wake-ups). `test_widthTracksAcrossAllSpaces` below is the width-cap half of
// that investigation: it closes a real, previously-untested combination
// (every `DaylightSpace`, swept across widths), but it did **not** reproduce
// the reported blank area - every width/space/destination combination this
// file's five original cases now cover (well beyond what any single prior
// regression needed) resolves `bodyContainer` correctly. Live captain
// evidence during this task also narrowed, then retracted, a "only in genuine
// full screen" framing, and finally landed on "CPU is normal on a fresh
// relaunch, only rising over a long session" - i.e. a per-usage accumulation,
// not a static geometry bug.
//
// The remaining cases are that CPU half. Four separate, concrete mechanisms
// were investigated with a real test each, not just reasoned about:
// `test_healthCardLayoutConverges` (an AppKit scrollbar/wrap-width feedback
// loop - not reproduced), `test_moduleCardTrackingAreaDoesNotLeak` (an
// `NSTrackingArea` retain cycle on one card in isolation - not reproduced),
// `test_moduleCardLayoutRunsOnceForOneRequest` (a self-re-triggering layout
// pass - not reproduced), and `test_moduleCardCountDoesNotAccumulateOverALongSession`
// (a per-switch accumulation across a real, 300-switch, per-event-pooled,
// real-display-pass session - not reproduced: flat at every checkpoint).
// That last one **appeared** to turn up one real, if narrow, finding along
// the way - isolated into its own case, `test_initialCanvasRenderIsOrphanedOnce`:
// `HomeCanvasController`'s very first render, at app-launch mount time,
// looked like it was never replaced by the next `.overview` visit the way
// every later generation correctly is, orphaning one fixed batch of cards
// once, at startup. That case originally asserted a literal fifteen, then
// (`fm/grandline-daylight-canvas-card-sizing`, once the canvas moved to
// `HelmResponsiveGrid.spanningRows` for §6.1's wide briefing and the observed
// magnitude moved to a full eighteen - one whole `.overview` generation)
// asserted boundedness and constancy instead of a literal, attributing the
// retention to "AppKit's own bookkeeping around `NSStackView.
// removeArrangedSubview`", observed but not explained.
//
// `fm/grandline-daylight-canvas-orphaned-render-fix` re-derived this from the
// actual code and found that attribution was itself wrong: there is no
// retention at all, in either grid path. `rebuildGrid()` has no first-render
// special case to unify - the "orphaned batch" was the exact self-test-harness
// autoreleasepool pitfall this file already names two paragraphs down, just
// not yet applied to *this* case's own baseline capture. See that case's own
// doc comment for the full account - once its mount and first resize are
// pool-wrapped like every other call in this file, the true count is a
// deterministic 0, not a bounded batch, under either grid path.
//
// Also confirmed, along the way, as a real self-test-harness pitfall worth
// recording rather than repeating: an early version of the long-session test
// ran 300 raw `selectSpace` calls with **no** enclosing `autoreleasepool`
// anywhere in the call stack (`main.swift` dispatches to
// `AppShellBodyWidthSelfTest.run()` with none of its own), and that
// specific arrangement produced a large, apparently-permanent excess that an
// explicit `RunLoop.main.run(until:)` drain afterward did *not* clear. Wrapping
// each iteration in its own `autoreleasepool` - which is what a real app's
// `NSApp.run()` already guarantees happens once per discrete event, so this
// is the only arrangement that actually represents the shipped app - made the
// excess disappear completely. Treat "a headless burst with zero
// autoreleasepools anywhere" as a test-harness artifact, not evidence about
// the real app, and always wrap a repeated-call stress test the same way a
// real event loop would.
//
// Combined with a full line-by-line scan of Daylight Phase 0/1/2's entire
// diff (`git diff e21a7e8 9195e29 -- native/Sources`) for any new `Timer`/
// `RunLoop`/`DispatchSourceTimer`/busy-`while` construct - there is exactly
// one new `DispatchQueue.main.async` in the whole diff
// (`HomeCanvasController.setNeedsRender()`'s render-coalescing hop, which is
// itself guarded against re-entry by its own `renderPending` flag) - this
// did not find a reproducible, growing app-side root cause for either report
// in the Daylight shell code. See this file's own PR description for what
// would actually make further progress: a live `sample`/spindump of the
// captain's own running process, which is the one piece of evidence that
// would show the exact thread and call stack responsible and that nothing in
// this sandboxed, headless environment can produce.
//
// Run with:
//   swift build && FM_RUN_APP_SHELL_BODY_WIDTH_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum AppShellBodyWidthSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("bodyContainerWidthTracksWindowAtLaunch", test_widthTracksWindowAtLaunch),
            ("bodyContainerWidthTracksASeriesOfResizes", test_widthTracksResizeSeries),
            ("widthSelfHealsAfterATieIsSilentlyBroken", test_widthSelfHealsAfterTieBroken),
            ("widthSelfHealsOnALayoutPassWithNoResize", test_widthSelfHealsOnALayoutPassWithNoResize),
            ("widthSelfHealsWhenContentViewDriftsFromTheWindow", test_widthSelfHealsWhenContentViewDrifts),
            ("widthSelfHealsWhenTheShowingPageDriftsFromTheBody", test_widthSelfHealsWhenPageDrifts),
            ("theWidthRepairNeverForcesANestedLayoutPass", test_repairNeverForcesANestedLayoutPass),
            ("bodyContainerTracksWindowAcrossRealisticWidths", test_widthTracksAcrossRealisticWidths),
            ("bodyContainerTracksWindowAcrossAllDestinations", test_widthTracksAcrossAllDestinations),
            ("bodyHeightTracksWindowAcrossAllDestinations", test_heightTracksAcrossAllDestinations),
            ("bodyContainerTracksWindowWithSeededHosts", test_widthTracksWithSeededHosts),
            ("bodyContainerTracksWindowAcrossAllSpaces", test_widthTracksAcrossAllSpaces),
            ("healthCardDescriptionWidthConverges", test_healthCardLayoutConverges),
            ("moduleCardDeallocatesAfterRemoval", test_moduleCardTrackingAreaDoesNotLeak),
            ("moduleCardLayoutSettlesForOneRequest", test_moduleCardLayoutRunsOnceForOneRequest),
            ("moduleCardCountDoesNotAccumulateOverALongSession", test_moduleCardCountDoesNotAccumulateOverALongSession),
            ("initialCanvasRenderIsOrphanedOnce", test_initialCanvasRenderIsOrphanedOnce),
            ("plainStackViewArrangedSubviewRemovalDoesNotLeak", test_stackViewArrangedSubviewRemovalLeaksOneGeneration),
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
            ? "AppShellBodyWidthSelfTest: all \(cases.count) cases passed"
            : "AppShellBodyWidthSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

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
            .appendingPathComponent("grandline-appshell-body-width-test-\(UUID().uuidString)")
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
        // not `UserDefaults` - and mounting a real `AppShellController` writes
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

    /// Builds a real `AppShellController` (the exact production dependency
    /// shape `main.swift` uses) mounted as a real `NSWindow`'s
    /// `contentViewController` - matching `main.swift`'s own
    /// `window.contentViewController = appShell` ordering, since that
    /// ordering is itself part of what this file's bug lives near (see
    /// AGENTS.md's `fm/grandline-design-fidelity-fixes` history). The window
    /// is deliberately never made key/ordered front - a real resize still
    /// fires `NSWindow.didResizeNotification` for a window that exists but
    /// isn't on screen, and keeping it off screen means this test can never
    /// visibly disturb anything on a shared machine.
    private static func makeMountedShell(seedHosts: [Host] = [])
        -> (window: NSWindow, shell: AppShellController) {
        let window = OffScreenProbe.window(width: 1220, height: 720, styleMask: [.titled, .resizable])
        let hostStore = HostStore()
        // Seeded **before** the shell is built, so the Hosts page renders with
        // real rows (and, for a tagged host, its tag strip) from its very first
        // layout pass rather than after one.
        for host in seedHosts { hostStore.add(host) }
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let shiftStore = ShiftStore()
        let dictationStore = DictationStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore),
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: shiftStore,
            dictationStore: dictationStore, commandLibraryStore: CommandLibraryStore(), scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        return (window, shell)
    }

    /// The width `bodyContainer` should have for a given window.
    ///
    /// Was "the window's content width minus the fixed 84pt rail" - the exact
    /// relationship the scout report found violated live. Daylight Phase 2
    /// removed the rail (migration §5.1), so the body now spans the window's
    /// *full* content width and the relationship being asserted is simply
    /// equality. Everything else about these cases is unchanged: the bug they
    /// guard against is `bodyContainer`'s frame going stale relative to the
    /// window, whatever the correct width happens to be.
    private static func expectedBodyWidth(for window: NSWindow) -> CGFloat {
        window.contentView?.bounds.width ?? 0
    }

    // MARK: Cases

    private static func test_widthTracksWindowAtLaunch() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            let expected = expectedBodyWidth(for: window)
            let actual = shell.bodyContainerFrameForTests.width
            guard abs(actual - expected) < 0.5 else {
                return "expected bodyContainer width \(expected) at launch (window content width \(window.contentView?.bounds.width ?? -1)), got \(actual)"
            }
            return nil
        }
    }

    private static func test_widthTracksResizeSeries() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            // A wide, screen-like size (matching the scout report's real
            // 1512-wide screen) followed by a narrower one (matching the
            // real 1033-wide window the report captured) - the exact
            // direction of resize the live bug involved.
            for width in [CGFloat(1512), CGFloat(1033), CGFloat(1220), CGFloat(900)] {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: true)
                let expected = expectedBodyWidth(for: window)
                let actual = shell.bodyContainerFrameForTests.width
                guard abs(actual - expected) < 0.5 else {
                    return "after resizing to \(width) wide: expected bodyContainer width \(expected), got \(actual)"
                }
            }
            return nil
        }
    }

    /// `fm/grand-line-body-width-selfheal-layout-fix`: the same self-heal,
    /// proven from a **layout pass with no resize** - the trigger the repair
    /// did not have until this task, and the whole reason the captain's
    /// window stayed visibly broken (a full-width surface with only ~670pt of
    /// it laid out, the rest undrawn black) until he quit and reopened. See
    /// `data/grand-line-stray-window-glitch-scout/report.md` "BUG B".
    ///
    /// `widthSelfHealsAfterATieIsSilentlyBroken` above fires a real resize,
    /// so it passes on either build: the `NSWindow.didResizeNotification`
    /// observer has always been wired. This case fires **no** resize at all.
    ///
    /// **Why it asserts the tie's activity rather than a stale frame**, which
    /// is not the obvious shape and was arrived at by measurement: there is
    /// no way to make `bodyContainer`'s frame genuinely stale without
    /// resizing the window, and resizing the window posts the very
    /// notification this case exists to do without. A window's content view
    /// is sized by the window, so setting its frame directly leaves
    /// `bounds.width` reporting the new value while Auto Layout's engine
    /// still solves against the window's real width - `bodyContainer` then
    /// correctly resolves to the window's width, and a frame assertion says
    /// nothing about which trigger repaired it. Whether the tie is **active
    /// again** after an ordinary layout pass is what actually separates the
    /// two builds. The break is asserted before the pass, so this can never
    /// pass vacuously against a tie that was never broken.
    ///
    /// The closing resize is deliberately not the discriminator - it would
    /// be repaired by the long-standing observer on either build. It is
    /// there so this case proves the reactivated tie genuinely *binds*,
    /// rather than only that an `isActive` flag flipped back.
    ///
    /// Confirmed, per this project's convention, to actually catch the
    /// regression rather than just pass: removing
    /// `reassertBodyContainerWidthTie()` from `ChromeFusionRootView`'s
    /// `onLayout` hook leaves the tie inactive after the layout pass, and
    /// restoring it passes again.
    /// The repair must never call `layoutSubtreeIfNeeded()` from inside
    /// `ChromeFusionRootView.layout()`.
    ///
    /// AppKit forbids it - "It's not legal to call -layoutSubtreeIfNeeded on a
    /// view which is already being laid out" - and on **macOS 14 it traps**
    /// rather than logs: this suite died with `Trace/BPT trap: 5` on CI while
    /// passing on a macOS 26 developer machine, which is exactly the shape of
    /// bug a local run cannot be trusted to catch.
    ///
    /// The repair is still allowed to force a pass from a caller that is *not*
    /// in a layout pass (launch, and the resize notification), which is what
    /// `widthSelfHealsAfterATieIsSilentlyBroken` above covers.
    private static func test_repairNeverForcesANestedLayoutPass() -> String? {
        withScratchEnv {
            AppShellController.repairsInsideALayoutPassForTests = 0
            AppShellController.nestedLayoutForcingsForTests = 0

            let (window, shell) = makeMountedShell()
            defer { window.close() }
            // The widths this suite already sweeps - the conflicting-constraint
            // resizes are what drive AppKit to lay out repeatedly.
            for width in [1440.0, 1016.0, 1900.0, 1100.0] as [CGFloat] {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: true)
                shell.view.layoutSubtreeIfNeeded()
            }

            // Not vacuous: the repair has to have genuinely run from inside a
            // layout pass, or "it forced none" says nothing at all.
            guard AppShellController.repairsInsideALayoutPassForTests > 0 else {
                return "the repair never ran from inside a layout pass, so this case cannot tell "
                    + "the fix from its absence - has ChromeFusionRootView.onLayout stopped "
                    + "calling reassertBodyContainerWidthTie(insideLayoutPass:)?"
            }
            guard AppShellController.nestedLayoutForcingsForTests == 0 else {
                return "the width repair forced "
                    + "\(AppShellController.nestedLayoutForcingsForTests) nested layout pass(es) "
                    + "from inside ChromeFusionRootView.layout(). AppKit traps on that (macOS 14): "
                    + "mark the view dirty and let the next pass do it."
            }
            return nil
        }
    }

    private static func test_widthSelfHealsOnALayoutPassWithNoResize() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            // The scout report's real screen width, so the value this
            // reproduces is the one it actually captured (1512).
            window.setFrame(NSRect(x: 0, y: 0, width: 1512, height: 900), display: true)
            guard let content = window.contentView else { return "setup failed: window has no content view" }
            guard shell.bodyWidthTieIsActiveForTests else {
                return "setup failed: the width tie was already inactive before this case broke it"
            }

            // The live failure's starting condition: the tie goes inactive,
            // for whatever internal AppKit reason - see this file's header.
            shell.debugBreakBodyWidthTieForTests()
            guard !shell.bodyWidthTieIsActiveForTests else {
                return "setup failed: debugBreakBodyWidthTieForTests() did not leave the width tie inactive, "
                    + "so this case would prove nothing"
            }

            // One ordinary layout pass. No `NSWindow.setFrame`, so no
            // `didResizeNotification` - the observer that has always existed
            // cannot be what repairs this.
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()

            guard shell.bodyWidthTieIsActiveForTests else {
                return "the width tie was still inactive after a layout pass with no resize - the repair is not "
                    + "riding the layout pass, so a tie broken outside a resize stays broken until the captain "
                    + "resizes the window or restarts the app (the reported bug)"
            }

            // The tie is active again; prove it actually binds.
            window.setFrame(NSRect(x: 0, y: 0, width: 1033, height: 900), display: true)
            let width = shell.bodyContainerFrameForTests.width
            let expected = expectedBodyWidth(for: window)
            guard abs(width - expected) < 0.5 else {
                return "the width tie reported itself active after the layout pass but does not bind: expected "
                    + "bodyContainer width \(expected), got \(width)"
            }
            return nil
        }
    }

    /// Review 3, B1: the **third** reference. `bodyContainer` can match `root`
    /// and `root` can match the window while the *page* inside them is still
    /// laid out narrow.
    ///
    /// Review #3's own sweep caught exactly that: from `.schedules` onward,
    /// ten destinations rendered into **973.5pt** inside a 1512pt window -
    /// 973.5 being the Log Analyzer's own `fittingSize.width`, i.e. a page
    /// shown ten destinations earlier whose preferred width the rest had
    /// adopted. Neither of the two cases above can see it, and that is not a
    /// gap in how they were written: both of their operands are correct in
    /// this state, so there is nothing for either to compare unequal.
    ///
    /// The vacuity guards keep it that way - the destination's own ties stay
    /// **active** throughout (this is a live tie that lost a resolve, not a
    /// broken one), and `bodyContainer` is asserted correct before and after.
    private static func test_widthSelfHealsWhenPageDrifts() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.setFrame(NSRect(x: 0, y: 0, width: 1512, height: 900), display: true)
            guard let content = window.contentView else { return "setup failed: window has no content view" }
            // A page with a real preferred width of its own, which is where
            // the reported 973.5 came from.
            shell.show(.logAnalyzer)
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()

            let body = shell.bodyContainerFrameForTests.width
            guard let healthy = shell.showingDestinationWidthForTests else {
                return "setup failed: no destination is showing"
            }
            guard abs(healthy - body) < 0.5 else {
                return "setup failed: the page was already \(healthy) inside a \(body)pt body"
            }
            guard !shell.showingDestinationWidthIsStaleForTests else {
                return "setup failed: the staleness check already reported a drift before this case caused one"
            }

            // The captain's own number, and the page's own fitting width.
            let drifted = CGFloat(973.5)
            shell.debugShrinkShowingDestinationForTests(to: drifted)
            guard let after = shell.showingDestinationWidthForTests, abs(after - drifted) < 0.5 else {
                return "setup failed: could not put the page at \(drifted) (it is at "
                    + "\(shell.showingDestinationWidthForTests ?? -1))"
            }
            guard shell.showingDestinationWidthIsStaleForTests else {
                return "setup failed: a page at \(drifted) inside a \(body)pt body is not reported stale, "
                    + "so this case would prove nothing"
            }
            // The two references that already existed must both still be
            // happy - otherwise one of them would repair this and the third
            // comparison would be untested.
            guard abs(shell.bodyContainerFrameForTests.width - body) < 0.5 else {
                return "setup failed: shrinking the page also moved bodyContainer, so the older checks cover this"
            }

            // One ordinary layout pass, no resize. The page comes back.
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            let repaired = shell.showingDestinationWidthForTests ?? -1
            guard abs(repaired - body) < 0.5 else {
                return "the showing page stayed \(repaired) inside a \(body)pt body after a layout pass - "
                    + "the page's own tie is never re-derived, which is the ~450pt of unpainted window the "
                    + "captain reported"
            }
            guard !shell.showingDestinationWidthIsStaleForTests else {
                return "the page's width was repaired but the staleness check still reports a drift"
            }

            // **And a source guard, because the assertion above is not
            // attributable and saying so is the honest thing.** A frame set
            // directly on a constraint-managed view leaves Auto Layout's own
            // engine holding the correct solution, so the forced pass above
            // re-applies it whether or not the repair consulted this third
            // reference at all - measured: with the comparison deleted, every
            // behavioural assertion in this case still passes. What the
            // comparison genuinely adds is that the repair *notices*, which is
            // what turns "a pass happened to run" into "a pass is forced", and
            // there is no in-process way to make the engine's own solution
            // stale without resizing the window - the same limitation
            // `bodyWidthTieIsActiveForTests` was written for one case up.
            guard let dir = SelfTestSources.appSourceDirectory(),
                  let source = try? String(contentsOf: dir.appendingPathComponent("AppShellController.swift"),
                                           encoding: .utf8) else {
                print("  NOTE could not locate the app's sources; skipping B1's wiring guard")
                return nil
            }
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            guard code.contains("if !needsLayout, showingDestinationWidthIsStale()") else {
                return "the width repair no longer consults the showing page's own width - "
                    + "the two references it keeps can both agree while the page inside them is narrow"
            }
            return nil
        }
    }

    /// `fm/grand-line-window-glitch-fix`: the captain's black-region glitch
    /// recurring *after* #412 shipped its self-heal - reproduced here as the
    /// exact geometry measured live on his own running app.
    ///
    /// His window was **1512pt** wide (its titlebar window reported exactly
    /// that, and its backing surface was 1512pt) while its content window
    /// reported **1064pt**, with content drawn only to 1063pt - **449pt of
    /// undrawn black**, and his own screenshot cut the *top bar* at the same
    /// x, which is what identifies it as `contentView` rather than any one
    /// page. His log carried **zero** reactivation lines, so no constraint had
    /// been deactivated: the tie was active and `bodyContainer` correctly
    /// matched a `root` that was itself the wrong size, which is precisely the
    /// state `bodyContainerWidthIsStale()` cannot see. It cleared only when
    /// the window was resized.
    ///
    /// Deliberately distinct from its two siblings above:
    /// `widthSelfHealsAfterATieIsSilentlyBroken` and
    /// `widthSelfHealsOnALayoutPassWithNoResize` both start by *deactivating*
    /// the tie, and both then prove binding via a `setFrame` - i.e. via the
    /// resize trigger that has always worked. Neither can see this one, and
    /// the vacuity guard below keeps it that way.
    private static func test_widthSelfHealsWhenContentViewDrifts() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.setFrame(NSRect(x: 0, y: 0, width: 1512, height: 950), display: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))

            guard let content = window.contentView else { return "setup failed: window has no content view" }
            let expected = window.contentRect(forFrameRect: window.frame).width
            guard abs(content.bounds.width - expected) < 0.5 else {
                return "setup failed: contentView is \(content.bounds.width) against a \(expected)-wide window "
                    + "before this case forced any drift"
            }

            // The live signature: the content view alone goes narrow while the
            // window stays full width.
            content.setFrameSize(NSSize(width: 1064, height: content.bounds.height))
            guard abs(content.bounds.width - 1064) < 0.5 else {
                return "setup failed: could not force the contentView drift (got \(content.bounds.width))"
            }
            // Vacuity guard: the tie must still be ACTIVE. If forcing the drift
            // also deactivated it, this case would be reproducing the
            // already-covered broken-tie scenario and would pass for the wrong
            // reason.
            guard shell.bodyWidthTieIsActiveForTests else {
                return "setup failed: forcing the contentView drift also deactivated the width tie, so this case "
                    + "would be reproducing the already-covered broken-tie scenario rather than the drift"
            }

            // Ordinary run loop turns only - no `setFrame`, so no
            // `didResizeNotification`. The resize path is exactly what the
            // captain had to trigger by hand, and is what this case must not
            // rely on.
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))

            let rootWidth = shell.view.bounds.width
            guard abs(rootWidth - expected) < 0.5 else {
                return "contentView stayed \(rootWidth) wide against a \(expected)-wide window after ordinary "
                    + "layout passes with no resize - so the window keeps a full-width surface while only "
                    + "\(rootWidth) of it is ever drawn, which is the undrawn black region the captain "
                    + "reported (it clears only when the window is resized)"
            }
            let body = shell.bodyContainerFrameForTests.width
            guard abs(body - expected) < 0.5 else {
                return "contentView resynced to \(rootWidth) but bodyContainer stayed \(body)"
            }
            return nil
        }
    }

    private static func test_widthSelfHealsAfterTieBroken() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            // Start wide (matching the report's real screen width) so the
            // "stale, screen-sized" value this bug produced is concrete and
            // matches the report's own numbers exactly, not just any old
            // value.
            window.setFrame(NSRect(x: 0, y: 0, width: 1512, height: 900), display: true)
            let staleWidth = shell.bodyContainerFrameForTests.width
            guard abs(staleWidth - 1512) < 0.5 else {
                return "setup failed: expected bodyContainer to be 1512 wide before breaking the tie, got \(staleWidth)"
            }

            // Reproduce the exact live failure: the width tie goes inactive
            // (whatever the real underlying AppKit cause was - see this
            // file's header) while the window itself later shrinks, exactly
            // as the scout report captured (window real/current, body
            // frozen at the old, wider value).
            shell.debugBreakBodyWidthTieForTests()
            window.setFrame(NSRect(x: 0, y: 0, width: 1033, height: 900), display: true)

            let afterResizeWidth = shell.bodyContainerFrameForTests.width
            let expected = expectedBodyWidth(for: window)
            guard abs(afterResizeWidth - expected) < 0.5 else {
                return "bodyContainer did not self-heal after its width tie was broken and the window resized: "
                    + "expected \(expected) (window content width \(window.contentView?.bounds.width ?? -1)), "
                    + "got \(afterResizeWidth) (still matching the stale \(staleWidth) it had before the break)"
            }
            return nil
        }
    }

    /// `fm/grandline-log-analyzer-body-width-regression`: proves
    /// `bodyContainer` fills the window's real width across a *range* of
    /// realistic widths - not just the one specific dimension a test
    /// happens to check, since a fix tuned to one width could pass this
    /// suite while still being broken generally. Every width below is well
    /// above this page's own legitimate minimum content width (confirmed
    /// separately: `LogAnalyzerController`'s Analysis tab, which is visible
    /// by default, needs roughly 980pt of real content width on its own to
    /// render its raw/structured split without being squished - a genuine
    /// floor unrelated to this bug, not something this test should fight).
    /// This is deliberately a *different* case from
    /// `widthSelfHealsAfterATieIsSilentlyBroken` above: that one reproduces
    /// a specific historical staleness in the width-*tie* mechanism itself;
    /// this one proves no destination's own content can cap the window
    /// below its requested size in the first place, which is a property of
    /// the destinations mounted inside `bodyContainer`, not of the tie.
    private static func test_widthTracksAcrossRealisticWidths() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            for width in [CGFloat(1100), 1220, 1350, 1420, 1512, 1600, 1800, 2000] {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: true)
                let actual = shell.bodyContainerFrameForTests.width
                let expected = width
                guard abs(actual - expected) < 0.5 else {
                    return "at window width \(width): expected bodyContainer \(expected), got \(actual) "
                        + "(window's own frame stayed at \(window.frame.width) - a destination's content is "
                        + "capping bodyContainer below what the window actually offers)"
                }
            }
            return nil
        }
    }
    /// `fm/grandline-body-width-regression-recur`: the captain reported the
    /// exact same "black/blank area on the right side of the window" symptom
    /// again, this time on `.console`. The two cases above only ever exercise
    /// the *eagerly*-mounted slots (`.overview`/`.console`/`.review` -
    /// `DestinationRegistry.swift`'s `mountsEagerly` set) plus whatever the
    /// app happens to land on by default (`.console`, or `.bootstrap`/`.setup`
    /// when `FirstmateHome.homeOk()` is false, as it always is in this file's
    /// scratch env) - every *lazily*-mounted destination (Hosts, Tasks, Log
    /// Analyzer, Tools, Vault, Dictation, Schedules, Health, Docs, the other
    /// three Setup pages, Settings) was never visited by either case, so a
    /// bug that only manifests once one of THOSE destinations has been shown
    /// could ship clean through this whole file.
    ///
    /// That is exactly what happened. Root cause, found by mounting every
    /// destination and sweeping widths across each in turn (not just at the
    /// end): `ToolsController.toolCard(_:width:)`'s `titleLabel` sets
    /// `lineBreakMode = .byTruncatingTail` but never lowers its horizontal
    /// compression resistance off `NSTextField`'s own default
    /// (`.defaultHigh`, 750) - a priority *above*
    /// `NSLayoutPriorityWindowSizeStayPut` (500, AGENTS.md gotcha (13)), so
    /// the truncation mode was dead code and the label instead refused to
    /// compress below its own intrinsic width. `ToolsController.rebuildGrid()`
    /// only re-lays its landing grid out while the picker is on screen
    /// (`containerWidthMayHaveChanged()`'s `!view.isHidden` guard, itself a
    /// deliberate GL-20/performance fix - see that method's own doc comment),
    /// so once a captain opened Tools at a wide window, that title label's
    /// too-high floor got baked into a row width and never shrank back down
    /// after Tools was hidden again - and since GL-37 mounts destinations
    /// once and only ever hides them (never tears them down), that stale,
    /// oversized floor stayed active in the view tree forever after,
    /// captured through the required leading/trailing ties every destination
    /// shares via `embed(_:)` into the one `bodyContainer` - exactly AGENTS.md
    /// gotcha (11)'s "a hidden view's constraints still fully participate in
    /// layout" class of bug, with the ToolsController grid as the source
    /// this time rather than `LogAnalyzerController`'s Compare-tab popups
    /// (the previous instance of this same class, see this file's header
    /// above). Fixed the same way this codebase always fixes this shape:
    /// `titleLabel.setContentCompressionResistancePriority(.defaultLow, for:
    /// .horizontal)`, so the label can never outrank the window's own resize
    /// preference and its `.byTruncatingTail` mode actually gets to fire.
    ///
    /// This case closes the actual structural gap, not just today's culprit:
    /// it visits **every** `RailDestination`, sweeping several widths while
    /// each one is showing (reproducing the exact "rebuild wide, then hide"
    /// sequence that baked in the stale floor above), and then makes a
    /// second full pass re-visiting every destination at a narrow width - so
    /// a floor left behind by destination A that only shows up once
    /// destination B (visited later) is narrowed cannot slip through. Any
    /// future destination or card that repeats this mistake (a label with a
    /// truncating/wrapping line-break mode and no lowered compression
    /// resistance, tied - however many stack views deep - into
    /// `bodyContainer`) fails this case by name instead of shipping.
    ///
    /// Confirmed to actually catch the regression, not just to pass:
    /// reverting `ToolsController.swift`'s `titleLabel` fix reproduces this
    /// exact failure (`.tools` leaves `bodyContainerFrameForTests` stuck at a
    /// wider-than-requested width for every destination shown after it, at a
    /// window width below roughly 1290pt), and reapplying the fix passes it
    /// again.
    /// The same guarantee as the sweep below, with the Hosts page holding real
    /// data - which is the one shape that sweep cannot reach on its own.
    ///
    /// **Why this case exists.** `withScratchEnv` points every store at an
    /// empty scratch file, so the Hosts page in the sweep below renders zero
    /// rows and, in particular, no tag strip. Two of that page's widest
    /// demands only exist with real hosts in it: the tag chip row
    /// (`fm/grand-line-hosts-page-layout-regression-fix`'s own subject) and,
    /// since `fm/grand-line-hosts-sidebar-restore`, a third column. Measured
    /// with tagged hosts the page's *preferred* width is 1198.5 - comfortably
    /// above the 1100pt window swept here - and that is fine, because every
    /// column is pinned at `HelmDaylightPriority.contentTie` (499), below
    /// `NSLayoutPriorityWindowSizeStayPut`. This case is what proves that
    /// distinction holds rather than being argued: a page that merely *prefers*
    /// more must still let the window be whatever the window is.
    private static func test_widthTracksWithSeededHosts() -> String? {
        withScratchEnv {
            var dev = Host(label: "DEV Bastion", address: "ec2-44-206-131-135.compute-1.amazonaws.com")
            dev.username = "centos"
            dev.tags = ["DEV"]
            var prod = Host(label: "Prod Bastion", address: "ec2-3-208-58-234.compute-1.amazonaws.com")
            prod.username = "ec2-user"
            prod.tags = ["PROD"]
            // An untagged, grouped host too: the tag strip is an
            // `NSStackView` arranged subview that leaves layout entirely when
            // it is hidden, so the two branches are genuinely different
            // layouts and both are swept.
            var plain = Host(label: "Build box", address: "build.internal")
            plain.username = "ci"
            plain.group = "CI"

            let (window, shell) = makeMountedShell(seedHosts: [dev, prod, plain])
            var failures: [String] = []
            shell.show(.hosts)
            for width in [CGFloat(1016), 1100, 1220, 1512, 2000, 1100] {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: true)
                let actual = shell.bodyContainerFrameForTests.width
                if abs(actual - width) >= 0.5 {
                    failures.append("hosts (seeded) at width \(width): expected bodyContainer \(width), got \(actual)")
                }
            }
            // And the shape the brief's own "switch away and back" asks for:
            // a destination visited in between must not leave a floor behind.
            for other in [RailDestination.console, .overview, .settings] {
                shell.show(other)
                shell.show(.hosts)
                window.setFrame(NSRect(x: 0, y: 0, width: 1016, height: 900), display: true)
                let actual = shell.bodyContainerFrameForTests.width
                if abs(actual - 1016) >= 0.5 {
                    failures.append("hosts (seeded, after visiting \(other)) at 1016: got \(actual)")
                }
            }
            return failures.isEmpty ? nil : failures.joined(separator: " | ")
        }
    }

    private static func test_widthTracksAcrossAllDestinations() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            var failures: [String] = []

            // First pass: visit every destination in rail order, sweeping a
            // narrow-to-wide range of widths *while each one is showing* -
            // this is what actually triggers a destination's own resize-
            // driven re-layout (like `ToolsController.rebuildGrid()`) at a
            // wide size before it gets hidden again.
            for dest in RailDestination.allCases {
                shell.show(dest)
                for width in [CGFloat(1100), 1512, 2000] {
                    window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: true)
                    let actual = shell.bodyContainerFrameForTests.width
                    let expected = width
                    if abs(actual - expected) >= 0.5 {
                        failures.append("\(dest) at width \(width): expected bodyContainer \(expected), got \(actual)")
                    }
                }
            }

            // Second pass: revisit every destination at one narrow width with
            // no further resizing in between - this is what actually caught
            // the `.tools` regression above, since the floor it left behind
            // only shows up once a *different*, later-visited destination is
            // shown at a width below the stale floor.
            for dest in RailDestination.allCases {
                shell.show(dest)
                window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 900), display: true)
                let actual = shell.bodyContainerFrameForTests.width
                let expected = CGFloat(1100)
                if abs(actual - expected) >= 0.5 {
                    failures.append("(revisit) \(dest) at width 1100: expected bodyContainer \(expected), got \(actual)")
                }
            }

            return failures.isEmpty ? nil : failures.joined(separator: " | ")
        }
    }

    /// Review 3, B5: a page's own content must never make the *window* taller.
    ///
    /// The width cases above are the fifth-and-counting guard against a page
    /// putting a floor under the window's width. This is the same class on the
    /// other axis, and it had none: the Hosts page's three side panels were
    /// stacked with no scroll view of their own, so their combined required
    /// height reached `bodyContainer` through a required chain and - because
    /// this window is driven by `contentViewController`, which re-derives its
    /// frame from the content's fitting size (AGENTS.md gotcha (3)) - pushed
    /// the whole window taller. Measured before the fix: a window asked for
    /// 750pt of content came back 906.
    ///
    /// Two things are asserted, and only together do they mean anything. The
    /// window's content height must be the height it was asked for (the
    /// symptom), and `bodyContainer` must genuinely fill the body area
    /// underneath the bar (without which a window that merely *stayed* small
    /// while the body collapsed would pass).
    private static func test_heightTracksAcrossAllDestinations() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            var failures: [String] = []

            // Deliberately short - shorter than the Hosts side stack's own
            // content needs, which is the only height at which the defect is
            // visible at all. A tall window satisfies the floor by accident.
            for height in [CGFloat(750), 900] {
                for dest in RailDestination.allCases {
                    shell.show(dest)
                    window.setFrame(NSRect(x: 0, y: 0, width: 1512, height: height), display: true)
                    guard let content = window.contentView else {
                        failures.append("\(dest): the window lost its content view")
                        continue
                    }
                    let contentHeight = content.bounds.height
                    let asked = window.contentRect(forFrameRect: window.frame).height
                    if abs(contentHeight - asked) >= 0.5 {
                        failures.append("\(dest) at \(height): the page drove the window's content height to \(contentHeight), not \(asked)")
                    }
                    // The body is pinned `reservedTopHeight` below the top and
                    // flush with the bottom, so in AppKit's unflipped content
                    // view that is minY 0 and maxY `contentHeight - inset`.
                    let body = shell.bodyContainerFrameForTests
                    let expectedMaxY = contentHeight - DaylightBarController.reservedTopHeight
                    if abs(body.minY) >= 0.5 || abs(body.maxY - expectedMaxY) >= 0.5 {
                        failures.append("\(dest) at \(height): bodyContainer is \(body), want minY 0 and maxY \(expectedMaxY)")
                    }
                }
            }

            return failures.isEmpty ? nil : failures.joined(separator: " | ")
        }
    }

    /// `fm/grandline-daylight-shell-regressions`: closes a real gap in the
    /// case above. `test_widthTracksAcrossAllDestinations` visits every
    /// `RailDestination` but only ever at `.homeCanvas`'s *default* space
    /// (`.overview`), and `DaylightModuleSelfTest.checkCanvasAndDrillHeader`
    /// selects every space but never resizes the window - neither exercises
    /// "a non-default space, at a swept range of widths" together. Sweeps
    /// every `DaylightSpace` via `selectSpace`, at 11 widths from 700 to
    /// 2400, checking `bodyContainer`'s width tracks the window exactly at
    /// each combination. This did not reproduce the captain's reported
    /// "blank area on the right side of the window" - every combination
    /// passes on the code as shipped in Daylight Phase 2 (#257) - but it is
    /// real, previously-missing coverage for a class of regression this
    /// codebase has hit five times before (AGENTS.md gotchas (13)/(14) and
    /// their history), so it stays as a permanent guard against a future one.
    private static func test_widthTracksAcrossAllSpaces() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            var failures: [String] = []
            for space in DaylightSpace.allCases {
                shell.selectSpace(space)
                for width in [CGFloat(700), 820, 900, 1000, 1100, 1250, 1400, 1512, 1700, 2000, 2400] {
                    window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: true)
                    let actual = shell.bodyContainerFrameForTests.width
                    if abs(actual - width) >= 0.5 {
                        failures.append("space=\(space.rawValue) width=\(width): expected bodyContainer \(width), got \(actual)")
                    }
                }
            }
            return failures.isEmpty ? nil : failures.joined(separator: " | ")
        }
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
        // convention (see `makeMountedShell()`'s comment above), a self-test
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

    /// `fm/grandline-daylight-shell-regressions`: a third hypothesis for the
    /// sustained-CPU report - a genuine internal re-layout storm, where
    /// something inside `HelmModuleCard.layout()`/`applyShadow()`/
    /// `applyTheme()` re-marks the same view dirty on every pass it runs,
    /// so a single logical layout request never actually settles. Forces one
    /// canvas render plus one explicit `layoutSubtreeIfNeeded()` and reads
    /// `HelmModuleCard.debugLayoutCallCount` (a plain counter incremented
    /// inside `layout()`, `#if FM_SELFTESTS`-gated so it costs nothing in a
    /// release build) on all fifteen cards: a small, bounded count is
    /// AppKit legitimately resolving the fresh constraint graph in a couple
    /// of internal passes; dozens or more would be the runaway signature.
    /// A second, completely idle request (nothing changed) should add zero
    /// further calls - real settling, not merely "bounded per request".
    /// **Result: it settles cleanly both times** - this hypothesis did not
    /// reproduce either.
    private static func test_moduleCardLayoutRunsOnceForOneRequest() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: true)
            shell.selectSpace(.overview)
            window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: true)

            let canvas = shell.homeCanvasForTests
            let cards = canvas.moduleCardsForTests
            guard !cards.isEmpty else { return "no module cards were built to measure" }

            // One more explicit, isolated layout request - the same call this
            // controller's own `select(space:)`/`viewWillAppear()` already make.
            shell.view.layoutSubtreeIfNeeded()
            let counts = cards.map(\.debugLayoutCallCount)
            let maxCount = counts.max() ?? 0
            // A handful of internal AppKit passes is normal; dozens or more
            // for a single explicit request is the runaway signature.
            if maxCount > 6 {
                return "a module card's layout() ran \(maxCount) times for one "
                    + "layoutSubtreeIfNeeded() request - counts: \(counts)"
            }

            // A second, completely idle request (nothing changed) should not
            // add any further layout() calls at all - real settling, not just
            // "bounded per request".
            shell.view.layoutSubtreeIfNeeded()
            let secondCounts = cards.map(\.debugLayoutCallCount)
            if secondCounts != counts {
                return "an idle layoutSubtreeIfNeeded() (nothing changed) still called layout() again - "
                    + "before: \(counts), after: \(secondCounts) - the tree is not settling"
            }
            return nil
        }
    }

    /// `fm/grandline-daylight-shell-regressions`: a fourth, more direct check
    /// of the observer-leak hypothesis than `DaylightModuleSelfTest.
    /// checkCanvasAndDrillHeader`'s own 20-switch check - live captain
    /// evidence (sustained ~85% CPU, worse over a session, clearing on
    /// relaunch) raised the possibility that check's `autoreleasepool`
    /// wrapper was masking a real leak a much longer session would still
    /// show. Drives 60 space-switch cycles (300 individual `selectSpace`
    /// calls plus a real `window.displayIfNeeded()` after each one, so actual
    /// compositing runs, not just layout) through the real, mounted shell,
    /// each wrapped in its own `autoreleasepool` - matching what a real app's
    /// run loop already guarantees per discrete event, which is the only
    /// scenario worth testing here (a headless burst with **no** enclosing
    /// pool anywhere, tried and discarded while building this test, produced
    /// a large, apparently-permanent excess that a per-event pool immediately
    /// erased in full - i.e. a self-test-harness artifact from `main.swift`'s
    /// own dispatch to `AppShellBodyWidthSelfTest.run()` having no top-level
    /// `autoreleasepool` of its own, not a finding about the shipped app,
    /// which always runs inside `NSApp.run()`'s own per-event draining).
    /// Tracks `HelmModuleCard.debugLiveInstanceCount`/`HelmGradientTile.
    /// debugLiveInstanceCount`/`HoverHighlightView.debugLiveInstanceCount`
    /// (three independent, direct construct/destruct counters) and
    /// `ThemeManager.observerCountForTests`, at five checkpoints along the
    /// way, so a genuinely *growing* leak can be told apart from a bounded
    /// one. This test starts by switching away from and back to `.overview`
    /// once before taking its baseline specifically so that baseline is a
    /// genuine steady-state generation rather than `loadView()`'s own very
    /// first render - see `test_initialCanvasRenderIsOrphanedOnce`, which
    /// isolates that first render on its own and (after
    /// `fm/grandline-daylight-canvas-orphaned-render-fix` re-derived it) found
    /// it is not actually special-cased or orphaned at all. **Result here:
    /// flat at every checkpoint** - no growth, no excess, across a session
    /// 15x longer than the existing suite's own check.
    private static func test_moduleCardCountDoesNotAccumulateOverALongSession() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: true)

            // Move away from `.overview` (the controller's own initial
            // default - `HomeCanvasController.loadView()` already rendered
            // it once before this test ever runs, via `mountEagerSlots()`)
            // and back, so "baseline" reflects a genuine steady-state
            // generation rather than that one-time initial render - see
            // `test_initialCanvasRenderIsOrphanedOnce` for that one, in
            // isolation.
            autoreleasepool { shell.selectSpace(.command) }
            autoreleasepool { shell.selectSpace(.overview) }
            let baselineInstances = HelmModuleCard.debugLiveInstanceCount
            let baselineObservers = ThemeManager.shared.observerCountForTests
            let baselineTiles = HelmGradientTile.debugLiveInstanceCount
            let baselineHovers = HoverHighlightView.debugLiveInstanceCount

            var checkpointExcess: [Int] = []
            for outer in 0..<60 {
                for space in DaylightSpace.allCases {
                    autoreleasepool {
                        shell.selectSpace(space)
                        window.displayIfNeeded()
                    }
                }
                if (outer + 1).isMultiple(of: 12) {
                    autoreleasepool {
                        shell.selectSpace(.overview)
                        window.displayIfNeeded()
                    }
                    checkpointExcess.append(HelmModuleCard.debugLiveInstanceCount - baselineInstances)
                }
            }
            let finalInstances = HelmModuleCard.debugLiveInstanceCount
            let finalObservers = ThemeManager.shared.observerCountForTests
            guard finalInstances != baselineInstances || finalObservers != baselineObservers else {
                return nil
            }
            let distinctExcess = Set(checkpointExcess)
            let shape = distinctExcess.count <= 1
                ? "constant at \(checkpointExcess.first ?? 0) extra across all 5 checkpoints - a "
                  + "bounded, one-time artifact, not a growing leak"
                : "growing across checkpoints (\(checkpointExcess)) - a genuine, unbounded leak"
            let tileExcess = HelmGradientTile.debugLiveInstanceCount - baselineTiles
            let hoverExcess = HoverHighlightView.debugLiveInstanceCount - baselineHovers
            return "300 space switches (each with its own autoreleasepool and a real display pass) left "
                + "\(finalInstances - baselineInstances) extra live HelmModuleCard instances, "
                + "\(tileExcess) extra HelmGradientTile, \(hoverExcess) extra HoverHighlightView, "
                + "and \(finalObservers - baselineObservers) extra ThemeManager observers behind - "
                + "shape: \(shape)"
        }
    }

    /// `fm/grandline-daylight-shell-regressions` isolated what looked like a
    /// real, bounded finding here: `HomeCanvasController.loadView()`'s very
    /// first render (at `mountEagerSlots()` time, before the captain ever
    /// revisits `.overview`) appeared to survive the next `.overview`
    /// selection rather than being replaced the way every later generation
    /// correctly is, permanently orphaning one full Overview batch of cards
    /// from every app launch.
    ///
    /// `fm/grandline-daylight-canvas-orphaned-render-fix` re-derived this
    /// from the actual code rather than trusting the earlier reading, and
    /// found there is no such divergence to unify:
    /// `HomeCanvasController.rebuildGrid()` removes every arranged row from
    /// `gridStack` and clears `cards` unconditionally at the top of every
    /// call, with no branch for "is this the first render" - `render()` and
    /// `select(space:)` both call it identically whether this is generation
    /// one or generation fifty. There was never a first-render special case
    /// for a fix to land in.
    ///
    /// What was actually happening: this case's own baseline
    /// (`initialInstances`, below) used to be captured right after
    /// `makeMountedShell()`'s mount and the very first `window.setFrame(...)`
    /// resize - both **outside any `autoreleasepool`**, unlike every one of
    /// this test's own `selectSpace` round trips (which were already
    /// wrapped, per this file's own established convention - see the header
    /// comment above and `test_moduleCardCountDoesNotAccumulateOverALongSession`'s).
    /// A card `rebuildGrid()` genuinely tears down still autoreleases some
    /// AppKit-owned state before it deinits, so with no pool draining
    /// between the launch render/resize and that baseline read, cards that
    /// were already correctly discarded still counted as "live" a moment
    /// longer than they actually were. Confirmed live and deterministically:
    /// wrapping the mount and the first resize in their own `autoreleasepool`
    /// - the exact fix below - drops the measured excess from a constant
    /// (not growing) 18 extra cards (the *current* `DaylightModule.allCases`
    /// count visible on `.overview`, not the stale "15" this case used to
    /// assert - a second, independent sign the assertion had drifted from
    /// reality rather than reality drifting from a real leak) to a constant
    /// 0, across repeated runs. No code outside this self-test changed.
    private static func test_initialCanvasRenderIsOrphanedOnce() -> String? {
        withScratchEnv {
            // Both the mount (which runs `HomeCanvasController.loadView()`'s
            // own first `render()`) and the launch-time resize (which fires
            // `containerWidthMayHaveChanged()` -> a second `rebuildGrid()`)
            // are now wrapped in their own `autoreleasepool`, matching every
            // `selectSpace` round trip below and what a real `NSApp.run()`
            // already guarantees per discrete event - see this method's own
            // doc comment for why an undrained baseline here used to read as
            // a false "orphaned batch" that was never actually retained.
            var window: NSWindow!
            var shell: AppShellController!
            autoreleasepool {
                let mounted = makeMountedShell()
                window = mounted.window
                shell = mounted.shell
            }
            autoreleasepool {
                window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: true)
            }

            // No prior `.command` detour here, deliberately - this baseline
            // is taken right after the controller's own initial render, the
            // one generation the test above steps around.
            let initialInstances = HelmModuleCard.debugLiveInstanceCount

            autoreleasepool { shell.selectSpace(.command) }
            autoreleasepool { shell.selectSpace(.overview) }
            let afterOneRoundTrip = HelmModuleCard.debugLiveInstanceCount - initialInstances

            for _ in 0..<5 {
                autoreleasepool { shell.selectSpace(.command) }
                autoreleasepool { shell.selectSpace(.overview) }
            }
            let afterFiveMoreRoundTrips = HelmModuleCard.debugLiveInstanceCount - initialInstances

            guard afterOneRoundTrip == 0, afterFiveMoreRoundTrips == 0 else {
                return "expected the very first render to be fully replaced (0 extra live cards left "
                    + "behind) after 1 round trip and after 6 - got \(afterOneRoundTrip) then "
                    + "\(afterFiveMoreRoundTrips). This IS the real regression this case guards against: "
                    + "the initial render must go through the exact same rebuildGrid() teardown every "
                    + "later generation does, leaving nothing behind after a round trip away and back."
            }
            return nil
        }
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
}

#endif
