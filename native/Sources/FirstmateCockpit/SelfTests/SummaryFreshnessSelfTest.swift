// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-engineering-cards-stale-counts`: the hub's summary cards must
// reflect a state change the captain made through the corresponding detail
// page, not a snapshot taken up to 15 minutes earlier.
//
// The reported bug: the captain updated every tool and synced every fork by
// hand, and the Engineering hub went on reading "3 updates" / "6 behind, of 8
// tracked" while the Updates page one click away read "13 tools - all up to
// date - 0 Updates Available" and the GitHub Sync page read "8 forks - all in
// sync". Both cards render `BackgroundSignalsPoller.lastCounts`, which before
// this task only that poller's own 15-minute pass could ever write.
//
// What each case pins, and why it is shaped the way it is:
//
//   1. **The scenario itself**, end to end, per signal: seed a stale count,
//      confirm the hub card renders it, drive the *real* detail page's own
//      choke point with fresh statuses, confirm the hub card moved. Driving
//      the choke point (`debugApplyStatusesAndRender`) rather than the
//      publish method is the point - a test that called
//      `publishToolStatuses` itself would pass with the page's wiring
//      deleted, which is exactly the bug.
//   2. **One derivation, two producers.** The count must come from one
//      place, or a page and the hub can disagree about *how* to count as
//      well as when. Checked by feeding identical raw outcomes through the
//      poller's own published derivation and each page's own predicate.
//   3. **GL-14's two honesty rules survive**: a sweep still in flight and a
//      never-checked set both publish nothing rather than stamping a
//      confident zero over a real number.
//   4. **A hidden page does not speak.** Bootstrap and Automation publish one
//      shared signal; whichever the captain is actually looking at is the one
//      that should speak for it, or a stale background rebuild can undo a
//      fresh number.
//
// Run with:
//   swift build && FM_RUN_SUMMARY_FRESHNESS_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SummaryFreshnessSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkUpdatesCardFollowsItsPage,
                      checkGitHubSyncCardFollowsItsPage,
                      checkOneDerivationPerSignal,
                      checkPendingAndUnknownPublishNothing,
                      checkHiddenPageDoesNotPublish,
                      checkAnOlderReadingNeverWins] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "SummaryFreshnessSelfTest: all checks passed"
                    : "SummaryFreshnessSelfTest: FAILED")
        return allOK
    }


    // MARK: 1 - the captain's own scenario, per signal

    /// Updates: stale "3 updates" on the hub, the page learns everything is
    /// current, the hub says so.
    private static func checkUpdatesCardFollowsItsPage(_ ok: inout Bool) {
        print("\n-- the Updates card follows a state change made on the Updates page --")

        withPollerRestored {
            withScratchEnv {
                let rig = Rig()
                let poller = BackgroundSignalsPoller.shared

                // The captain's own starting state: three tools out of date,
                // as the poller's last pass found them.
                poller.debugSetLastCompletedPassAt(Date())
                poller.debugSetCounts(.init(toolUpdates: 3, forkDrift: 6, vaultAttention: 0,
                                            setupDrift: 1, vaultSecrets: 4))
                rig.shell.selectSpace(.engineering)
                rig.canvas.debugRenderNow()

                guard let before = rig.card(.updates) else {
                    fail("no Updates card rendered on the Engineering hub", &ok)
                    return
                }
                let beforeText = (before.metricTexts + before.noteTexts + [before.chipText ?? ""]).joined(separator: " ")
                if !beforeText.contains("3") {
                    fail("the Updates card does not start from the seeded stale count - "
                         + "read '\(beforeText)', expected it to mention 3", &ok)
                }

                // The captain opens Updates and every tool comes back current.
                rig.shell.show(.updates)
                let updates = rig.shell.updatesForTests
                let allCurrent = [DependencyStatus](repeating: .upToDate, count: DependencyCatalog.items.count)
                updates.debugApplyStatusesAndRender(allCurrent)

                // ...and goes back to the hub, exactly as he did.
                rig.shell.show(.homeCanvas)
                rig.canvas.debugRenderNow()

                if poller.lastCounts.toolUpdates != 0 {
                    fail("the page reported every tool up to date but the published count is "
                         + "\(String(describing: poller.lastCounts.toolUpdates)) - the hub reads this, "
                         + "so it is still showing the stale number the captain reported", &ok)
                }
                guard let after = rig.card(.updates) else {
                    fail("no Updates card rendered after the change", &ok)
                    return
                }
                let afterText = (after.metricTexts + after.noteTexts + [after.chipText ?? ""]).joined(separator: " ")
                if afterText.contains("3 update") {
                    fail("the Updates card still reads '\(afterText)' after the page found every tool "
                         + "current - this is the reported bug", &ok)
                }
                if after.chipText != "Current" {
                    fail("the Updates card's chip is \(after.chipText ?? "nil") with zero updates "
                         + "outstanding - expected Current", &ok)
                }
                if ok { print("  OK  stale '3 updates' -> '\(after.chipText ?? "nil")' after the page checked") }
            }
        }
    }

    /// GitHub Sync: the same scenario for the second card the captain named.
    private static func checkGitHubSyncCardFollowsItsPage(_ ok: inout Bool) {
        print("\n-- the GitHub Sync card follows a state change made on the GitHub Sync page --")

        withPollerRestored {
            withScratchEnv {
                let rig = Rig()
                let poller = BackgroundSignalsPoller.shared

                poller.debugSetLastCompletedPassAt(Date())
                poller.debugSetCounts(.init(toolUpdates: 0, forkDrift: 6, vaultAttention: 0,
                                            setupDrift: 0, vaultSecrets: 4))
                rig.shell.selectSpace(.engineering)
                rig.canvas.debugRenderNow()

                guard let before = rig.card(.githubSync) else {
                    fail("no GitHub Sync card rendered on the Engineering hub", &ok)
                    return
                }
                let beforeText = (before.metricTexts + before.noteTexts + [before.chipText ?? ""]).joined(separator: " ")
                if !beforeText.contains("6") {
                    fail("the GitHub Sync card does not start from the seeded stale count - "
                         + "read '\(beforeText)'", &ok)
                }

                rig.shell.show(.githubSync)
                let sync = rig.shell.githubSyncForTests
                let allInSync = [GitHubSyncStatus](repeating: .inSync, count: GitHubSyncCatalog.repos.count)
                sync.debugApplyStatusesAndRender(allInSync)

                rig.shell.show(.homeCanvas)
                rig.canvas.debugRenderNow()

                if poller.lastCounts.forkDrift != 0 {
                    fail("every fork reported in sync but the published count is "
                         + "\(String(describing: poller.lastCounts.forkDrift))", &ok)
                }
                guard let after = rig.card(.githubSync) else {
                    fail("no GitHub Sync card rendered after the change", &ok)
                    return
                }
                let afterText = (after.metricTexts + after.noteTexts + [after.chipText ?? ""]).joined(separator: " ")
                if afterText.contains("6 ") || afterText.contains("behind") {
                    fail("the GitHub Sync card still reads '\(afterText)' after every fork synced", &ok)
                }
                if after.chipText != "In sync" {
                    fail("the GitHub Sync card's chip is \(after.chipText ?? "nil") with nothing behind "
                         + "- expected In sync", &ok)
                }
                if ok { print("  OK  stale '6 behind' -> '\(after.chipText ?? "nil")' after the page checked") }
            }
        }
    }

    // MARK: 2 - one derivation, not two counts kept in agreement

    /// The hub's number and the detail page's own summary must be the same
    /// function of the same raw outcomes.
    ///
    /// This is the half that stops the fix degrading back into "two counts
    /// that happen to agree today": the page hands over statuses, and the
    /// count is derived once. Here that shared derivation is checked against
    /// each page's own predicate over the identical input.
    private static func checkOneDerivationPerSignal(_ ok: inout Bool) {
        print("\n-- one derivation per signal, shared by every producer --")

        let toolFixture: [DependencyStatus] = [.upToDate, .updateAvailable, .upToDate,
                                               .notInstalled, .checkFailed, .upToDate]
        let expectedTools = toolFixture.filter { $0.showsUpdateButton }.count
        if BackgroundSignalsPoller.toolUpdateCount(from: toolFixture) != expectedTools {
            fail("toolUpdateCount derived \(String(describing: BackgroundSignalsPoller.toolUpdateCount(from: toolFixture))) "
                 + "but the page's own showsUpdateButton predicate counts \(expectedTools) over the same statuses", &ok)
        }

        let forkFixture: [GitHubSyncStatus] = [.inSync, .behind(3), .diverged(localOnly: 1, upstreamAhead: 2),
                                               .notAFork, .syncFailed, .inSync]
        let expectedForks = forkFixture.filter { $0.showsSyncButton }.count
        if BackgroundSignalsPoller.forkDriftCount(from: forkFixture) != expectedForks {
            fail("forkDriftCount derived \(String(describing: BackgroundSignalsPoller.forkDriftCount(from: forkFixture))) "
                 + "but the page's own showsSyncButton predicate counts \(expectedForks)", &ok)
        }
        // The predicate deliberately excludes a diverged repo and a non-fork -
        // there is nothing to pull for either, and counting them as "behind"
        // would put a number on the hub that no Sync button can ever clear.
        if expectedForks != 2 {
            fail("the fork fixture is not exercising the diverged/notAFork exclusions - "
                 + "expected 2 syncable of 6 (.behind and .syncFailed only), got \(expectedForks)", &ok)
        }

        var setup: [SetupStepKind: Bool?] = [:]
        for kind in SetupStepKind.allCases { setup[kind] = true }
        setup[.software] = false
        if BackgroundSignalsPoller.setupDriftCount(from: setup) != 1 {
            fail("setupDriftCount over four-done-one-drifted derived "
                 + "\(String(describing: BackgroundSignalsPoller.setupDriftCount(from: setup))), expected 1", &ok)
        }
        if ok { print("  OK  tools \(expectedTools), forks \(expectedForks), setup 1 - one predicate each") }
    }

    // MARK: 3 - GL-14: never a confident zero

    private static func checkPendingAndUnknownPublishNothing(_ ok: inout Bool) {
        print("\n-- a pending or never-run sweep publishes nothing --")

        // Tools mid-sweep: some already back, the rest still checking. "0
        // updates" here is a claim about an answer nobody has yet.
        let midSweep: [DependencyStatus] = [.upToDate, .checking, .upToDate]
        if let count = BackgroundSignalsPoller.toolUpdateCount(from: midSweep) {
            fail("a sweep with a .checking row derived \(count) - a pending sweep is not an answer", &ok)
        }
        if let count = BackgroundSignalsPoller.toolUpdateCount(from: [.upToDate, .updating, .upToDate]) {
            fail("a sweep with an .updating row derived \(count)", &ok)
        }
        if let count = BackgroundSignalsPoller.toolUpdateCount(from: [.unknown, .unknown, .unknown]) {
            fail("an all-unknown (freshly built, never checked) page derived \(count) - it would stamp "
                 + "a zero over a real number the poller established at launch", &ok)
        }
        if BackgroundSignalsPoller.toolUpdateCount(from: []) != nil {
            fail("an empty status set derived a count", &ok)
        }

        if let count = BackgroundSignalsPoller.forkDriftCount(from: [.inSync, .checking]) {
            fail("a fork sweep with a .checking row derived \(count)", &ok)
        }
        if let count = BackgroundSignalsPoller.forkDriftCount(from: [.inSync, .syncing]) {
            fail("a fork sweep with a .syncing row derived \(count)", &ok)
        }
        if let count = BackgroundSignalsPoller.forkDriftCount(from: [.unknown, .unknown]) {
            fail("an all-unknown fork page derived \(count)", &ok)
        }

        // One unanswered step is not four-fifths of an answer.
        var partial: [SetupStepKind: Bool?] = [:]
        for kind in SetupStepKind.allCases { partial[kind] = true }
        partial[.dotfiles] = Bool?.none
        if let count = BackgroundSignalsPoller.setupDriftCount(from: partial) {
            fail("a setup set with one still-checking step derived \(count)", &ok)
        }
        var missing: [SetupStepKind: Bool?] = [:]
        for kind in SetupStepKind.allCases where kind != .software { missing[kind] = true }
        if let count = BackgroundSignalsPoller.setupDriftCount(from: missing) {
            fail("a setup set missing a step entirely derived \(count)", &ok)
        }

        // And the honesty rule really reaches the published state, not just
        // the pure function: a mid-sweep publish must leave the last real
        // number standing.
        withPollerRestored {
            let poller = BackgroundSignalsPoller.shared
            poller.debugSetCounts(.init(toolUpdates: 3, forkDrift: nil, vaultAttention: nil,
                                        setupDrift: nil, vaultSecrets: nil))
            poller.publishToolStatuses(midSweep)
            if poller.lastCounts.toolUpdates != 3 {
                fail("publishing a mid-sweep set overwrote the standing count with "
                     + "\(String(describing: poller.lastCounts.toolUpdates))", &ok)
            }
            // A degraded `av` read says nothing about either vault number.
            poller.debugSetCounts(.init(toolUpdates: nil, forkDrift: nil, vaultAttention: 1,
                                        setupDrift: nil, vaultSecrets: 7))
            poller.publishVaultRead(secrets: nil, tools: nil)
            if poller.lastCounts.vaultSecrets != 7 || poller.lastCounts.vaultAttention != 1 {
                fail("a failed av read overwrote the vault counts - B1's rule is that it says nothing", &ok)
            }
        }
        if ok { print("  OK  pending, never-checked and degraded reads all leave the standing count alone") }
    }

    // MARK: 4 - only the page the captain is looking at speaks

    /// Bootstrap and Automation publish one shared `setupDrift` signal. A page
    /// that is mounted but hidden gets re-rendered by ordinary events (a theme
    /// change, a font-scale change) off state that can be older than the
    /// poller's own last sweep - it must not overwrite a fresher number from
    /// behind whatever the captain is actually looking at.
    private static func checkHiddenPageDoesNotPublish(_ ok: inout Bool) {
        print("\n-- a hidden detail page does not publish over a fresher number --")

        withPollerRestored {
            withScratchEnv {
                let rig = Rig()
                let poller = BackgroundSignalsPoller.shared

                // Mount Updates, then navigate away so it is hidden but alive.
                rig.shell.show(.updates)
                let updates = rig.shell.updatesForTests
                rig.shell.show(.homeCanvas)

                if !updates.view.isHidden {
                    fail("the Updates page is still visible after navigating to the canvas - "
                         + "this check cannot exercise the hidden case", &ok)
                    return
                }

                poller.debugSetCounts(.init(toolUpdates: 0, forkDrift: nil, vaultAttention: nil,
                                            setupDrift: nil, vaultSecrets: nil))
                // A hidden page re-rendering off stale rows.
                updates.debugApplyStatusesAndRender(
                    [DependencyStatus](repeating: .updateAvailable, count: DependencyCatalog.items.count))

                if poller.lastCounts.toolUpdates != 0 {
                    fail("a hidden page published \(String(describing: poller.lastCounts.toolUpdates)) "
                         + "over the standing 0 - the hub would disagree with what the captain last saw", &ok)
                }

                // ...and the same page, once visible, must still publish.
                rig.shell.show(.updates)
                updates.debugApplyStatusesAndRender(
                    [DependencyStatus](repeating: .updateAvailable, count: DependencyCatalog.items.count))
                if poller.lastCounts.toolUpdates != DependencyCatalog.items.count {
                    fail("a visible page published \(String(describing: poller.lastCounts.toolUpdates)), "
                         + "expected \(DependencyCatalog.items.count) - the visibility gate is refusing "
                         + "the case it is supposed to allow", &ok)
                }
                if ok { print("  OK  hidden page silent, visible page publishes") }
            }
        }
    }

    // MARK: 5 - an in-flight poll pass cannot undo a fresh page publish

    /// A pass spends tens of seconds gathering before it publishes, so its
    /// statuses can already be a minute old by the time they land. Without a
    /// freshness guard, a captain who fixes something on a detail page during
    /// that window watches the hub go correct and then immediately stale again
    /// - the reported bug, reintroduced through the back door.
    private static func checkAnOlderReadingNeverWins(_ ok: inout Bool) {
        print("\n-- an older reading never displaces a newer one --")

        withPollerRestored {
            let poller = BackgroundSignalsPoller.shared
            // Genuinely earlier, because that is the scenario the comment
            // above describes: a pass that began gathering tens of seconds
            // ago. Two bare `Date()` calls microseconds apart can return the
            // *same* instant, and `acceptsReading` accepts an equally-fresh
            // reading by design - so capturing "before" microseconds earlier
            // makes this case fail intermittently while asserting nothing
            // about staleness. Measured: 1 spurious failure in 6 runs.
            let passStarted = Date().addingTimeInterval(-30)
            let allCurrent = [DependencyStatus](repeating: .upToDate, count: 4)
            let allStale = [DependencyStatus](repeating: .updateAvailable, count: 4)

            // The captain's page publishes "everything is current", now.
            poller.publishToolStatuses(allCurrent)
            if poller.lastCounts.toolUpdates != 0 {
                fail("the page's own publish did not land", &ok)
                return
            }

            // The pass that began before that lands its pre-fix reading.
            poller.publishToolStatuses(allStale, gatheredAt: passStarted)
            if poller.lastCounts.toolUpdates != 0 {
                fail("a poll pass that started before the captain's fix overwrote it with "
                     + "\(String(describing: poller.lastCounts.toolUpdates)) - the hub would go stale "
                     + "again seconds after going correct", &ok)
            }

            // ...but a genuinely newer pass must still be able to report a
            // real regression, or the guard has made the signal read-only.
            poller.publishToolStatuses(allStale, gatheredAt: Date())
            if poller.lastCounts.toolUpdates != 4 {
                fail("a newer pass could not publish \(allStale.count) updates - the freshness guard "
                     + "is refusing readings it should accept", &ok)
            }

            // Each signal tracks its own freshness: an outrun tool check says
            // nothing about the same pass's fork check.
            poller.publishForkStatuses([.behind(1), .inSync], gatheredAt: passStarted)
            if poller.lastCounts.forkDrift != 1 {
                fail("a fork reading was refused because a *tool* reading was outrun - the signals "
                     + "must track freshness independently", &ok)
            }
            if ok { print("  OK  stale pass refused, newer pass accepted, signals independent") }
        }
    }

    // MARK: - Harness

    /// A real shell in a real window, with the canvas and the two detail
    /// pages reachable.
    private struct Rig {
        let shell: AppShellController
        let canvas: HomeCanvasController
        private let window: NSWindow

        init() {
            window = OffScreenProbe.window(width: 1400, height: 900, styleMask: [.titled, .resizable])
            let hostStore = HostStore()
            let keyStore = SSHKeyStore()
            let snippetStore = SnippetStore()
            shell = AppShellController(
                hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
                console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
                settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                             snippetStore: snippetStore, dictationStore: DictationStore()),
                hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
                shiftStore: ShiftStore(), dictationStore: DictationStore(),
                commandLibraryStore: CommandLibraryStore(), scheduleStore: ScheduleStore(),
                makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                     isFirstmateConsole: false) }
            )
            window.contentViewController = shell
            window.layoutIfNeeded()
            canvas = shell.homeCanvasForTests
        }

        func card(_ module: DaylightModule) -> HelmModuleCard.Anatomy? {
            guard let index = canvas.visibleModulesForTests.firstIndex(of: module),
                  index < canvas.moduleCardsForTests.count else { return nil }
            return canvas.moduleCardsForTests[index].anatomyForTests
        }
    }

    /// The poller is a process-wide singleton shared with every other suite in
    /// this run - its state is restored on the way out, the same discipline
    /// `DaylightModuleSelfTest` already applies to it.
    private static func withPollerRestored(_ body: () -> Void) {
        let poller = BackgroundSignalsPoller.shared
        let savedCounts = poller.lastCounts
        let savedCompletedAt = poller.lastCompletedPassAt
        poller.debugResetReadingClock()
        defer {
            poller.debugSetLastCompletedPassAt(savedCompletedAt)
            poller.debugSetCounts(savedCounts)
            poller.debugResetReadingClock()
        }
        body()
    }

    /// Every store this rig constructs is pointed at a scratch directory - see
    /// `DestinationMountingSelfTest.withScratchEnv`'s own doc comment for why
    /// a bare store here can otherwise reach a real clone of the captain's
    /// `manjesh-config` repo.
    private static func withScratchEnv(_ body: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-summary-freshness-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_SCHEDULES_FILE": dir.appendingPathComponent("schedules.json").path,
            "FM_DOCS_RUNBOOKS_DIR": dir.appendingPathComponent("docsRunbooks").path,
        ]
        var saved: [String: String?] = [:]
        for (key, value) in overrides {
            saved[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, old) in saved {
                if let old { setenv(key, old, 1) } else { unsetenv(key) }
            }
        }
        body()
    }
}

#endif
