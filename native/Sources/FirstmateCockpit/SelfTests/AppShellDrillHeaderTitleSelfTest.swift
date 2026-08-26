// Manjesh Grand Line - native macOS app.
//
// Captain-reported bug: `HelmDrillHeader`'s title sometimes renders
// truncated to just a few characters plus an ellipsis (a screenshot showed
// "Con…" on the Console destination, instead of "Console") even though the
// subtitle line below it renders in full and the header's back button/icon
// otherwise look correctly positioned - i.e. not the previously-fixed
// window-width-cap class (AGENTS.md gotchas (13)/(14),
// `AppShellBodyWidthSelfTest.swift`), which caps the *whole window*, not one
// label inside a header that still has visible room.
//
// **Root cause, found by reproduction, not assumed.** `HelmDrillHeader` is
// one shared, permanently-mounted view (see its own header comment) whose
// title/subtitle labels get `.stringValue` reassigned on every destination
// switch (`configure(title:...)`), and whose right-aligned action cluster
// (`actions`) gets swapped on every switch too (`setActions(_:)`). The
// title's available width is bounded by one non-fixed constraint,
// `textColumn.trailingAnchor <= actions.leadingAnchor - s3`.
//
// Before this fix, the title/subtitle column (`textColumn`) was an
// `NSStackView`. Once a genuine squeeze happened - a *previous* destination
// with a wide `actions` cluster (or a narrow window) forcing the row's title
// below its natural width - the stack's own resolved cross-axis width got
// stuck at that narrowest-ever value **permanently**, even after the squeeze
// condition fully cleared (the wide actions removed, the window widened back
// up, or an entirely different, much shorter title/subtitle pair set via a
// fresh `configure()` call). Confirmed live, with a disposable
// `HelmDrillHeader` instance built directly (not through `AppShellController`)
// and driven through the exact production call shape - one destination with
// a wide `actions` cluster and a long title, immediately followed by
// `configure(title: "Console", ...)` + `setActions([])`, matching
// `AppShellController.applyDrillHeader`'s own two-call sequence: none of
// `invalidateIntrinsicContentSize()` on either label, `needsLayout`/
// `needsUpdateConstraints`, an explicit `layoutSubtreeIfNeeded()`,
// deactivating/reactivating (or entirely replacing) the external `<=` tie,
// removing and re-adding both labels as arranged subviews of the stack, nor
// even a round-trip *window* resize to a much larger size ever let the
// stack's own reported width grow back - "Console" stayed stuck rendering at
// a width computed for whatever the *previous* destination's squeeze had
// left behind, not its own genuinely correct, plenty-of-room 104pt need.
//
// **The fix**: `textColumn` (`HelmDrillHeader.swift`) is now a plain
// `NSView`, not an `NSStackView` - title/subtitle are laid out with explicit
// constraints, and the column's own width is a required `>= child` tie from
// each label rather than anything `NSStackView` derives internally. A plain
// `NSView`'s geometry is nothing but its own active constraints, re-solved
// fresh on every layout pass like everything else in this header - it has no
// equivalent of whatever one-way-ratchet internal state an `NSStackView`
// keeps for a `.leading`-aligned arranged subview's cross-axis width.
// `HelmDrillHeader.reassertTitleWidthTie()` (deactivate + replace the one
// external `<=` tie on every `configure`/`setActions` call) stays as
// defence in depth for that one constraint specifically, at zero cost.
//
// This is why the bug was intermittent rather than permanent: a fresh window
// (nothing has ever squeezed the row) never exhibited it, and the exact
// "sometimes" trigger was switching to a destination whose title should
// render in full *right after* an earlier destination's own wide action
// cluster (or a narrow window) genuinely squeezed the row at some point in
// the session - the "Con…" screenshot's own title/action content had nothing
// to do with the truncation; whatever was shown immediately before it did.
//
// Confirmed, per this project's convention, to catch a real regression
// rather than merely to pass: reverting `HelmDrillHeader`'s `textColumn`
// back to an `NSStackView` reproduces `titleStaysStuckAfterAGenuineSqueezeClears`'s
// exact failure (a real, disposable `HelmDrillHeader` showing "Console" at a
// resolved width far narrower than its own intrinsic need, right after a
// wide-actions-then-short-title transition) and reapplying the plain-`NSView`
// fix passes it again.
//
// Run with:
//   swift build && FM_RUN_DRILL_HEADER_TITLE_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum AppShellDrillHeaderTitleSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("titleRendersInFullRightAfterASimpleSwitch", test_titleFitsAfterSimpleSwitch),
            ("titleStaysStuckAfterAGenuineSqueezeClears", test_titleFitsAfterSqueezeClearsWithDifferentContent),
            ("titleYieldsCorrectlyWhenGenuinelySqueezed", test_titleYieldsToGenuineSqueeze),
            ("titleRendersInFullAcrossEveryDestinationInSequence", test_titleFitsAcrossEveryDestination),
            ("titleRendersInFullAfterRepeatedRevisits", test_titleFitsAfterRepeatedRevisits),
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
            ? "AppShellDrillHeaderTitleSelfTest: all \(cases.count) cases passed"
            : "AppShellDrillHeaderTitleSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// A fresh scratch directory per call - never the captain's real saved
    /// data. Mirrors `AppShellBodyWidthSelfTest.withScratchEnv`.
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-drillheader-title-test-\(UUID().uuidString)")
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

    /// Matches `AppShellBodyWidthSelfTest.makeMountedShell()` exactly - a real
    /// `AppShellController` inside a real, never-ordered-front `NSWindow`.
    private static func makeMountedShell() -> (window: NSWindow, shell: AppShellController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let shiftStore = ShiftStore()
        let dictationStore = DictationStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore),
            console: ConsoleController(keyStore: keyStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore, dictationStore: dictationStore),
            hostStore: hostStore, keyStore: keyStore, shiftStore: shiftStore,
            dictationStore: dictationStore, commandLibraryStore: CommandLibraryStore(), scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        return (window, shell)
    }

    /// A disposable `HelmDrillHeader`, mounted in its own real (never
    /// ordered-front) window - the direct, minimal harness that actually
    /// reproduced the bug, independent of `AppShellController`'s much larger
    /// dependency graph.
    private static func makeMountedHeader(width: CGFloat = 500) -> (window: NSWindow, header: HelmDrillHeader) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: HelmDrillHeader.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let header = HelmDrillHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        let root = window.contentView!
        root.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: HelmDrillHeader.height),
        ])
        return (window, header)
    }

    /// The check every case below runs: does the title label's *rendered*
    /// frame actually fit the text it is currently showing? `NSTextField.
    /// intrinsicContentSize` recomputes fresh from the field's current
    /// `stringValue`/`font` on every call, so comparing it against the real
    /// resolved frame catches a truncated-but-otherwise-correct title without
    /// needing to know the exact pixel width any given title should occupy.
    private static func titleFitsFailure(_ header: HelmDrillHeader, context: String) -> String? {
        guard !header.isHidden else { return nil } // the canvas has no drill header
        let label = header.titleLabelForTests
        let needed = label.intrinsicContentSize.width
        let actual = label.frame.width
        guard actual < needed - 1.0 else { return nil }
        return "\(context): title \"\(label.stringValue)\" needs \(needed)pt but its rendered frame "
            + "is only \(actual)pt wide"
    }

    // MARK: Cases

    /// Sanity baseline: switching to Console once, with a full display pass
    /// forced, should always show the title in full. This can pass even on a
    /// build that has the bug, since a single, uncontested switch gives
    /// AppKit no stale value to inherit.
    private static func test_titleFitsAfterSimpleSwitch() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.setFrame(NSRect(x: 0, y: 0, width: 1220, height: 720), display: true)
            shell.show(.console)
            window.displayIfNeeded()
            return titleFitsFailure(shell.drillHeaderForTests, context: ".console after a plain switch")
        }
    }

    /// The actual reproduction, driven directly against `HelmDrillHeader`
    /// (not through `AppShellController`) to isolate the mechanism: force a
    /// genuine squeeze (a long title plus a genuinely wide `actions` cluster
    /// at a narrow window width), then switch to a short, unrelated
    /// title/subtitle pair with an empty `actions` cluster - the exact
    /// two-call `configure()` + `setActions([])` sequence
    /// `AppShellController.applyDrillHeader` performs on every real
    /// destination switch. There is now plenty of room for the new content;
    /// the title must render in full.
    private static func test_titleFitsAfterSqueezeClearsWithDifferentContent() -> String? {
        let (window, header) = makeMountedHeader(width: 500)
        header.configure(title: "A Genuinely Very Long Title That Needs Lots Of Room",
                         subtitle: "short", symbol: "sailboat.fill", hue: .teal)
        let wideAction = NSView()
        wideAction.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wideAction.widthAnchor.constraint(equalToConstant: 300),
            wideAction.heightAnchor.constraint(equalToConstant: 30),
        ])
        header.setActions([wideAction])
        window.displayIfNeeded()
        guard header.titleLabelForTests.frame.width < 200 else {
            return "setup failed: expected a genuine squeeze (title well under 200pt) before switching, "
                + "got \(header.titleLabelForTests.frame.width)pt - the reproduction needs a real squeeze first"
        }

        // The real production sequence: a brand-new destination's title and
        // (now-empty) actions, both changed together.
        header.configure(title: "Console", subtitle: "2 tabs \u{00B7} Shell 2",
                         symbol: "terminal", hue: .teal)
        header.setActions([])
        window.displayIfNeeded()

        if let failure = titleFitsFailure(header, context: "right after the squeeze clears") {
            return failure
        }
        // A later, completely idle pass and a much wider window should not
        // be needed to fit - but confirm neither regresses it either.
        window.displayIfNeeded()
        window.setFrame(NSRect(x: 0, y: 0, width: 1500, height: HelmDrillHeader.height), display: true)
        return titleFitsFailure(header, context: "after a later idle pass and a much wider window")
    }

    /// The mirror case: when the row is *genuinely* too narrow for the
    /// current title given the current `actions` cluster, the title must
    /// still yield gracefully (per §6.4's "the title yields to the actions
    /// rather than running under them") - this fix must not turn the `<=`
    /// tie into a no-op.
    private static func test_titleYieldsToGenuineSqueeze() -> String? {
        let (window, header) = makeMountedHeader(width: 500)
        let wideAction = NSView()
        wideAction.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wideAction.widthAnchor.constraint(equalToConstant: 300),
            wideAction.heightAnchor.constraint(equalToConstant: 30),
        ])
        header.configure(title: "A Genuinely Very Long Title That Needs Lots Of Room",
                         subtitle: "short", symbol: "sailboat.fill", hue: .teal)
        header.setActions([wideAction])
        window.displayIfNeeded()

        let title = header.titleLabelForTests
        let actions = header.actionsStackForTests
        // The title must not run underneath/past the actions cluster - the
        // documented intent this constraint exists for.
        guard title.frame.maxX <= actions.frame.minX + 0.5 else {
            return "title (maxX \(title.frame.maxX)) overlaps the actions cluster "
                + "(minX \(actions.frame.minX)) - the yield-to-actions constraint is not holding"
        }
        // And it must be genuinely narrower than its own natural need, since
        // there truly isn't room for both at this window width.
        guard title.frame.width < title.intrinsicContentSize.width else {
            return "expected a genuine squeeze (title narrower than its own intrinsic need) "
                + "at this window width, got frame \(title.frame.width) vs "
                + "intrinsic \(title.intrinsicContentSize.width) - test setup no longer squeezes"
        }
        return nil
    }

    /// Every `RailDestination` in rail order, immediately followed by
    /// `.console` and the one display pass a real next frame draw would do -
    /// the broadest sweep, so a future destination whose own action cluster
    /// is wide enough to reproduce this is caught without needing to be
    /// named explicitly above.
    private static func test_titleFitsAcrossEveryDestination() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.setFrame(NSRect(x: 0, y: 0, width: 1220, height: 720), display: true)
            window.displayIfNeeded()

            var failures: [String] = []
            for dest in RailDestination.allCases {
                shell.show(dest)
                window.displayIfNeeded()
                shell.show(.console)
                window.displayIfNeeded()
                if let failure = titleFitsFailure(shell.drillHeaderForTests, context: "\(dest) -> .console") {
                    failures.append(failure)
                }
            }
            return failures.isEmpty ? nil : failures.joined(separator: " | ")
        }
    }

    /// The same wide-cluster-then-short-title transition repeated many times
    /// in a row, through the real `AppShellController` (Log Analyzer's own
    /// two-button action cluster, which is genuinely wide enough at 1220pt
    /// to matter for a very long title, is used here for a destination that
    /// exists in production rather than a synthetic one).
    private static func test_titleFitsAfterRepeatedRevisits() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.setFrame(NSRect(x: 0, y: 0, width: 1220, height: 720), display: true)
            window.displayIfNeeded()

            var failures: [String] = []
            for i in 0..<12 {
                shell.show(.logAnalyzer)
                window.displayIfNeeded()
                shell.show(.console)
                window.displayIfNeeded()
                if let failure = titleFitsFailure(shell.drillHeaderForTests, context: "revisit \(i): .logAnalyzer -> .console") {
                    failures.append(failure)
                }
            }
            return failures.isEmpty ? nil : failures.joined(separator: " | ")
        }
    }
}

#endif
