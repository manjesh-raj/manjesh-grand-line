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
// That last one **did** turn up one real, if narrow, finding along the way -
// isolated into its own case, `test_initialCanvasRenderIsOrphanedOnce`:
// `HomeCanvasController`'s very first render, at app-launch mount time, is
// never replaced by the next `.overview` visit the way every later
// generation correctly is, orphaning one fixed batch of fifteen cards once,
// at startup. Real, and worth fixing on its own merits, but its magnitude
// (one small, bounded batch, exactly once) cannot be the mechanism behind a
// cost the captain's own report says *grows over a session* - that shape
// needs something that keeps recurring, and nothing found here does.
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
            ("bodyContainerTracksWindowAcrossRealisticWidths", test_widthTracksAcrossRealisticWidths),
            ("bodyContainerTracksWindowAcrossAllDestinations", test_widthTracksAcrossAllDestinations),
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
    private static func makeMountedShell() -> (window: NSWindow, shell: AppShellController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostStore = HostStore()
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)

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
    /// one. **One real, if minor, finding**: the very first render
    /// `HomeCanvasController.loadView()` performs at mount time (before this
    /// test - or any real navigation - ever revisits `.overview`) is not
    /// replaced by the *next* visit to `.overview` the way every later
    /// generation is - a one-time, bounded (one batch, never grows) orphaned
    /// set of fifteen cards from app launch, not a per-switch leak. This test
    /// starts by switching away from and back to `.overview` once specifically
    /// so its baseline is a genuine steady-state generation, not that
    /// original one, and isolates that finding to a separate, narrower probe
    /// (`test_initialCanvasRenderIsOrphanedOnce`) rather than let it read as
    /// "the steady state itself leaks". **Result here: flat at every
    /// checkpoint** - no growth, no excess, across a session 15x longer than
    /// the existing suite's own check.
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

    /// `fm/grandline-daylight-shell-regressions`: isolates the one real,
    /// bounded finding the test above deliberately excludes from its own
    /// baseline - `HomeCanvasController.loadView()`'s very first render (at
    /// `mountEagerSlots()` time, before the captain ever revisits `.overview`)
    /// is not replaced when `.overview` is next selected, the way every later
    /// generation correctly is. Fifteen cards (one full Overview batch) from
    /// that one-time initial render stay alive permanently - confirmed not to
    /// clear even after several further idle re-selections of `.overview` -
    /// but the excess never exceeds that one batch, however many further
    /// switches happen (see the test above). This is a real, worth-fixing
    /// piece of dead weight from every app launch, but its magnitude (one
    /// small, fixed batch, once, at startup) cannot explain a CPU cost that
    /// the captain's own report says *grows over a session* - that shape
    /// needs something that keeps recurring, not something that happens once.
    private static func test_initialCanvasRenderIsOrphanedOnce() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: true)

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

            guard afterOneRoundTrip == 15, afterFiveMoreRoundTrips == 15 else {
                return "expected the initial render's orphaned batch to be a constant 15 cards after "
                    + "1 round trip and after 6 - got \(afterOneRoundTrip) then \(afterFiveMoreRoundTrips). "
                    + "If this is 0, the orphaning itself may already be fixed and this test's own "
                    + "assumption is stale; if it grows past 15, that IS the growing leak this whole "
                    + "investigation was looking for and needs to be re-escalated immediately."
            }
            return nil
        }
    }

    /// `fm/grandline-daylight-shell-regressions`: isolates the mechanism
    /// behind `test_moduleCardCountDoesNotAccumulateOverALongSession`'s
    /// finding (a real, permanent-but-bounded one-batch-behind retention,
    /// not a growing leak) by removing `HomeCanvasController`/`HelmModuleCard`
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
