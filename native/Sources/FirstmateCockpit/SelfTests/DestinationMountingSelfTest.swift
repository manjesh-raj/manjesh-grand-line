// Manjesh Grand Line - native macOS app.
//
// GL-37 regression coverage: the destination table and
// lazy-mount-with-permanent-retention (`DestinationRegistry.swift`).
//
// Two halves, because the property has two halves worth protecting.
//
// The **table** cases are pure logic: every `RailDestination` resolves to a
// registered slot, the four Setup pages share one, and the top bar's title
// is the destination's own name everywhere except that group. A future
// destination added to the enum without a slot fails here immediately
// rather than silently rendering nothing at runtime.
//
// The **mounting** cases drive a real `AppShellController` in a real
// `NSWindow` - the same harness shape `AppShellBodyWidthSelfTest` already
// uses - and assert the three things GL-37 actually claims: only the eager
// slots exist at launch, a first visit builds exactly the one slot asked
// for, and a revisit reuses that same view rather than rebuilding it. The
// eager set is asserted by name rather than by count, because each of the
// three has its own invariant behind it (a live PTY, two launch-seeded rail
// badges) and a future change quietly moving one of them out of eager
// mounting should have to say so here.
//
// Confirmed, per this project's convention, to catch a real regression
// rather than merely to pass: reverting `show(_:)` to eagerly mount every
// slot at launch (the pre-GL-37 shape) fails
// `onlyEagerSlotsAreMountedAtLaunch`, `firstVisitMountsExactlyOneSlot` and
// `mounterIsLazyAndBuildsEachSlotOnce`; making `mountIfNeeded` unconditional
// (dropping its `isMounted` guard, i.e. re-mounting on every visit) fails
// `mounterIsLazyAndBuildsEachSlotOnce`, which counts real `mount` calls.
// Note which case does *not* catch that second one, and why:
// `revisitReusesTheSameView` cannot, because `NSViewController` caches its
// own `view` - a second `addChild`/`embed` of the same controller would
// duplicate constraints and warn, but would not hand back a different view.
// Counting the mount calls is the only way to see it.
//
// Run with:
//   swift build && FM_RUN_DESTINATION_MOUNTING_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DestinationMountingSelfTest {

    /// The three slots that cannot wait for a first visit. Kept here as an
    /// explicit expectation rather than read back off the mounter, so this
    /// test disagrees with the app when the app changes.
    private static let expectedEagerSlots: Set<DestinationSlotID> = [.console, .overview, .review]

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("everyRailDestinationResolvesToARegisteredSlot", test_everyDestinationHasASlot),
            ("setupGroupSharesOneSlotAndOneTitle", test_setupGroupSharesOneSlot),
            ("bodyTitleMatchesTheRailRowElsewhere", test_bodyTitleMatchesRailTitle),
            ("onlyEagerSlotsAreMountedAtLaunch", test_onlyEagerSlotsMountedAtLaunch),
            ("firstVisitMountsExactlyOneSlot", test_firstVisitMountsOneSlot),
            ("revisitReusesTheSameView", test_revisitReusesSameView),
            ("everySlotIsReachableAndMountsCleanly", test_everySlotMounts),
            ("schedulesHasItsOwnSlotAndAutomationNoLongerRendersIt", test_schedulesIsSeparateFromAutomation),
            ("mounterIsLazyAndBuildsEachSlotOnce", test_mounterUnitBehaviour),
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
            ? "DestinationMountingSelfTest: all \(cases.count) cases passed"
            : "DestinationMountingSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Table (pure logic, no view hierarchy)

    private static func test_everyDestinationHasASlot() -> String? {
        var seen: Set<DestinationSlotID> = []
        for dest in RailDestination.allCases { seen.insert(dest.slot) }
        let missing = Set(DestinationSlotID.allCases).subtracting(seen)
        guard missing.isEmpty else {
            return "slots with no rail destination pointing at them: \(missing.map(\.rawValue).sorted())"
        }
        return nil
    }

    private static func test_setupGroupSharesOneSlot() -> String? {
        let setupGroup: [RailDestination] = [.updates, .bootstrap, .automation, .githubSync]
        for dest in setupGroup {
            guard dest.slot == .setup else { return "\(dest) should map to the setup slot, got \(dest.slot.rawValue)" }
            guard dest.bodyTitle == "Setup" else { return "\(dest).bodyTitle should be \"Setup\", got \"\(dest.bodyTitle)\"" }
            guard SetupTab(destination: dest) != nil else { return "\(dest) has no SetupTab, so show(_:) could not select its tab" }
        }
        // And nothing outside that group leaks into the shared slot.
        for dest in RailDestination.allCases where !setupGroup.contains(dest) {
            guard dest.slot != .setup else { return "\(dest) unexpectedly shares the setup slot" }
        }
        return nil
    }

    private static func test_bodyTitleMatchesRailTitle() -> String? {
        for dest in RailDestination.allCases where dest.slot != .setup {
            guard dest.bodyTitle == dest.title else {
                return "\(dest): bodyTitle \"\(dest.bodyTitle)\" should match the rail row's \"\(dest.title)\""
            }
        }
        return nil
    }

    // MARK: Mounting (real shell, real window)

    private static func test_onlyEagerSlotsMountedAtLaunch() -> String? {
        withScratchEnv {
            let (_, shell) = makeMountedShell()
            // `loadView` ends with a `show(...)` of its own (Console, or
            // Setup on an unconfigured machine), so the launch set is the
            // eager slots plus at most that one.
            let mounted = Set(shell.mountedDestinationSlotsForTests)
            guard expectedEagerSlots.isSubset(of: mounted) else {
                return "eager slots missing at launch: \(expectedEagerSlots.subtracting(mounted).map(\.rawValue).sorted())"
            }
            let extra = mounted.subtracting(expectedEagerSlots)
            guard extra.count <= 1 else {
                return "expected at most the launch destination beyond the eager set, also mounted: \(extra.map(\.rawValue).sorted())"
            }
            // The expensive ones must not be among them under any launch path.
            let mustBeLazy: Set<DestinationSlotID> = [.docs, .tools, .logAnalyzer, .vault, .dictation, .schedules, .hosts, .shift, .settings]
            let eagerlyBuilt = mounted.intersection(mustBeLazy)
            guard eagerlyBuilt.isEmpty else {
                return "these should not be built at launch: \(eagerlyBuilt.map(\.rawValue).sorted())"
            }
            return nil
        }
    }

    private static func test_firstVisitMountsOneSlot() -> String? {
        withScratchEnv {
            let (_, shell) = makeMountedShell()
            let before = Set(shell.mountedDestinationSlotsForTests)
            guard !before.contains(.docs) else { return "docs was already mounted before its first visit" }

            shell.show(.docs)
            let after = Set(shell.mountedDestinationSlotsForTests)
            guard after.contains(.docs) else { return "show(.docs) did not mount the docs slot" }
            let added = after.subtracting(before)
            guard added == [.docs] else {
                return "show(.docs) mounted \(added.map(\.rawValue).sorted()), expected exactly [docs]"
            }
            guard shell.destinationViewIfMountedForTests(.docs)?.isHidden == false else {
                return "the docs view should be visible right after show(.docs)"
            }
            // A sibling that was never asked for is still unbuilt.
            guard shell.destinationViewIfMountedForTests(.tools) == nil else {
                return "tools was built as a side effect of showing docs"
            }
            return nil
        }
    }

    private static func test_revisitReusesSameView() -> String? {
        withScratchEnv {
            let (_, shell) = makeMountedShell()
            shell.show(.tools)
            guard let first = shell.destinationViewIfMountedForTests(.tools) else {
                return "tools did not mount on its first visit"
            }
            let firstID = ObjectIdentifier(first)

            shell.show(.console)
            guard shell.destinationViewIfMountedForTests(.tools)?.isHidden == true else {
                return "navigating away from tools should hide its view, not drop it"
            }

            shell.show(.tools)
            guard let second = shell.destinationViewIfMountedForTests(.tools) else {
                return "tools lost its view across a navigate-away-and-back cycle"
            }
            guard ObjectIdentifier(second) == firstID else {
                return "tools was rebuilt on revisit - permanent retention is what stops in-progress page state being thrown away"
            }
            guard second.isHidden == false else { return "tools should be visible again after the second show" }
            return nil
        }
    }

    private static func test_everySlotMounts() -> String? {
        withScratchEnv {
            let (_, shell) = makeMountedShell()
            // Visit every rail destination once, in enum order, exactly as a
            // captain clicking down the rail would.
            for dest in RailDestination.allCases {
                shell.show(dest)
                guard let view = shell.destinationViewIfMountedForTests(dest.slot) else {
                    return "show(\(dest)) left slot \(dest.slot.rawValue) unmounted"
                }
                guard view.isHidden == false else { return "show(\(dest)) did not reveal slot \(dest.slot.rawValue)" }
                // Exactly one body view visible at a time.
                let visible = DestinationSlotID.allCases.filter {
                    shell.destinationViewIfMountedForTests($0)?.isHidden == false
                }
                guard visible == [dest.slot] else {
                    return "after show(\(dest)) the visible slots were \(visible.map(\.rawValue)), expected [\(dest.slot.rawValue)]"
                }
            }
            guard Set(shell.mountedDestinationSlotsForTests) == Set(DestinationSlotID.allCases) else {
                return "visiting every destination should end with every slot mounted"
            }
            return nil
        }
    }

    /// `fm/grandline-schedules-sidebar-move`: F11's Schedules card used to be
    /// nested inside `.automation` (itself only reachable via the Setup
    /// flyout - a hover/click, then a scroll past the pipeline stepper). The
    /// captain's own correction was that Schedules needed its own rail icon,
    /// directly visible, and that the card must actually leave the Automation
    /// page rather than just gaining a second entry point. Both halves are
    /// checked here: `.schedules` mounts to a slot of its own (not `.setup`,
    /// the one Updates/Bootstrap/Automation/GitHub Sync all share), and the
    /// real `SetupContainerController` root that `.automation` shows -
    /// which parents all four Setup pages' views up front, regardless of
    /// which tab is active (see `SetupContainerController.loadView`) - no
    /// longer contains a "Schedules" card header anywhere in its view tree.
    ///
    /// Confirmed to catch a real regression, not just to pass: temporarily
    /// re-adding `SchedulesCardView`'s card to `AutomationController`'s own
    /// stack (the pre-move shape) makes this fail on the second assertion,
    /// naming the leftover "Schedules" label, while every other case in this
    /// file keeps passing.
    private static func test_schedulesIsSeparateFromAutomation() -> String? {
        withScratchEnv {
            let (_, shell) = makeMountedShell()

            guard RailDestination.schedules.slot != RailDestination.automation.slot else {
                return "schedules must not share a slot with automation"
            }

            shell.show(.schedules)
            guard let schedulesView = shell.destinationViewIfMountedForTests(.schedules) else {
                return "show(.schedules) did not mount the schedules slot"
            }
            guard schedulesView.isHidden == false else {
                return "the schedules view should be visible right after show(.schedules)"
            }

            // Visiting Schedules must not have built the shared Setup slot as
            // a side effect - it is a fully independent destination now.
            guard shell.destinationViewIfMountedForTests(.setup) == nil else {
                return "show(.schedules) unexpectedly mounted the setup slot too"
            }

            shell.show(.automation)
            guard let setupView = shell.destinationViewIfMountedForTests(.setup) else {
                return "show(.automation) did not mount the setup slot"
            }
            let labels = collectTextFieldValues(in: setupView)
            guard !labels.contains("Schedules") else {
                return "the Automation page (behind the Setup flyout) still renders a \"Schedules\" card header - it should have moved to its own destination"
            }
            guard !labels.contains(where: { $0.localizedCaseInsensitiveContains("new schedule") }) else {
                return "the Automation page still renders a schedule-creation control"
            }
            return nil
        }
    }

    /// A plain recursive walk - this file's only need for one, so it stays
    /// local rather than becoming a shared utility.
    private static func collectTextFieldValues(in view: NSView) -> [String] {
        var result: [String] = []
        if let field = view as? NSTextField { result.append(field.stringValue) }
        for sub in view.subviews { result.append(contentsOf: collectTextFieldValues(in: sub)) }
        return result
    }

    // MARK: The mounter itself, with stub controllers

    /// Counts its own `loadView` so "was this built?" is measured rather
    /// than inferred from a flag the mounter itself sets.
    private final class CountingViewController: NSViewController {
        private(set) var loadViewCount = 0
        override func loadView() {
            loadViewCount += 1
            view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    private static func test_mounterUnitBehaviour() -> String? {
        var mountCalls: [ObjectIdentifier] = []
        let mounter = DestinationMounter { controller in
            mountCalls.append(ObjectIdentifier(controller))
            // Touch the view the way the real `embed` does.
            _ = controller.view
        }
        let eager = CountingViewController()
        let lazyOne = CountingViewController()
        mounter.register(DestinationSlot(id: .console, title: "Console", mountsEagerly: true, controller: eager))
        mounter.register(DestinationSlot(id: .docs, title: "Docs", mountsEagerly: false, controller: lazyOne))

        mounter.mountEagerSlots()
        guard eager.loadViewCount == 1 else { return "eager slot should have loaded exactly once, got \(eager.loadViewCount)" }
        guard lazyOne.loadViewCount == 0 else { return "lazy slot must not load during mountEagerSlots" }
        guard eager.view.isHidden else { return "an eagerly mounted slot should start hidden" }

        // hideAll must not touch an unmounted slot's view.
        mounter.hideAll()
        guard lazyOne.loadViewCount == 0 else { return "hideAll built an unmounted slot's view" }

        guard mounter.show(.docs) != nil else { return "show(.docs) returned no slot" }
        guard lazyOne.loadViewCount == 1 else { return "first show should build the lazy slot exactly once" }
        guard lazyOne.view.isHidden == false else { return "first show should reveal the slot" }

        mounter.hideAll()
        guard mounter.show(.docs) != nil else { return "second show(.docs) returned no slot" }
        guard lazyOne.loadViewCount == 1 else { return "a revisit rebuilt the slot (loadView ran \(lazyOne.loadViewCount) times)" }
        guard mountCalls.count == 2 else { return "mount should have run once per slot, ran \(mountCalls.count) times" }

        guard mounter.show(.vault) == nil else { return "an unregistered slot should return nil rather than mounting something" }
        return nil
    }

    // MARK: Harness

    /// A fresh scratch directory per call so every store this test touches
    /// reads and writes disposable files - never the captain's real saved
    /// hosts/keys/snippets/tasks/dictation data. Same shape as
    /// `AppShellBodyWidthSelfTest.withScratchEnv`.
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-destination-mounting-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_DOCS_DIR": dir.appendingPathComponent("docs").path,
            "FM_LOG_ANALYZER_DIR": dir.appendingPathComponent("loganalyzer").path,
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
}

#endif
