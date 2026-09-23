// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-notification-ambient-expand-fix`: the "Waiting for you"
// popover's Tool Updates and GitHub Sync rows must expand into the tools and
// the repos **before either page has ever been mounted** - which is the only
// state the captain ever sees at launch, and the state in which the redesign
// (#451) shipped an unexpandable row.
//
// The captain's report was exactly that: "2 tools have updates" with no
// disclosure chevron. The expand mechanism was never broken - a row with no
// `AppNotificationChild` children simply has nothing to expand into, and the
// poller's own ambient pass was the one producer that published none.
//
// **Pure logic, no window.** Every case here drives the poller's own ambient
// pass and reads the published `GrandLineNotificationCenter` entry back, so it
// belongs in the blocking CI lane and is deliberately not in `NEEDS_SESSION`.
// The popover's *rendering* of children (the chevron, the keyboard expand, the
// child row's own button) is already asserted by
// `NotificationCenterRedesignSelfTest`, which is window-backed - this file is
// about whether the children exist at all.
//
// What each case pins:
//
//   1. **The ambient tool pass**, driven through the real `sweepSoftware` and
//      the real publish with nothing faked but the subprocess
//      (`DependencyCheckCache.checkOverrideForTests`, the seam
//      `DependencyCheckCacheSelfTest` already uses): the published entry must
//      carry one child per tool that is offering an Update, by name, with its
//      real version-pair detail - and none for a tool that is up to date.
//   2. **The ambient fork pass**, the same way one seam further in (the real
//      check is a live `gh api` call, so the outcomes are the fixture):
//      children by repo name, furthest behind first.
//   3. **Each child's action is real** - it routes the tool/repo id back to
//      the shell, which shows the page and runs that page's own update/sync.
//      Asserted both ways: the closure reaches the poller's routing hook with
//      the right id, and a source guard that the hook is wired to a real page
//      action rather than left dangling (the wiring half no behavioural check
//      in a headless suite can see).
//   4. **The two producers cannot drift** - the ambient pass and the pages
//      build children through one helper, so "what counts as pending" and how
//      a child reads are answered in one place.
//
// Run with:
//   swift build && FM_RUN_AMBIENT_SIGNAL_CHILDREN_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum AmbientSignalChildrenSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkAmbientToolPassPublishesRealChildren,
                      checkAmbientForkPassPublishesRealChildren,
                      checkEveryChildActionReachesARealPath,
                      checkBothProducersShareOneChildBuilder] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "AmbientSignalChildrenSelfTest: all checks passed"
                    : "AmbientSignalChildrenSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static func item(_ id: String) -> DependencyItem {
        DependencyItem(id: id, name: id.uppercased(), category: "Test", kind: .npmGlobal(package: id))
    }

    private static func outcome(_ status: DependencyStatus, _ detail: String) -> CheckOutcome {
        CheckOutcome(installedLabel: "1.0.0", latestLabel: "1.1.0", status: status, detail: detail, log: "")
    }

    private static func repo(_ name: String) -> GitHubSyncRepoConfig {
        GitHubSyncRepoConfig(owner: "manjesh-raj", name: name)
    }

    private static func forkOutcome(_ status: GitHubSyncStatus, _ detail: String) -> GitHubSyncCheckOutcome {
        GitHubSyncCheckOutcome(status: status, upstreamFullName: "upstream/x", detail: detail, log: "")
    }

    /// Every case publishes into the real shared center and the real shared
    /// poller, so each one restores both - AGENTS.md's hermeticity rule, the
    /// same shape `SummaryFreshnessSelfTest.withPollerRestored` uses.
    private static func withAmbientEnv(_ body: () -> Void) {
        let poller = BackgroundSignalsPoller.shared
        let counts = poller.lastCounts
        let onUpdateTool = poller.onUpdateTool
        let onSyncFork = poller.onSyncFork
        let override = DependencyCheckCache.checkOverrideForTests
        defer {
            DependencyCheckCache.checkOverrideForTests = override
            poller.onUpdateTool = onUpdateTool
            poller.onSyncFork = onSyncFork
            poller.debugSetCounts(counts)
            poller.debugResetReadingClock()
            GrandLineNotificationCenter.shared.resetForTesting()
        }
        poller.debugResetReadingClock()
        GrandLineNotificationCenter.shared.resetForTesting()
        body()
    }

    private static func publishedChildren(_ id: String) -> [AppNotificationChild]? {
        GrandLineNotificationCenter.shared.entries.first { $0.id == id }?.children
    }

    // MARK: 1 - the ambient tool pass

    private static func checkAmbientToolPassPublishesRealChildren(_ ok: inout Bool) {
        print("\n-- the poller's own pass, no page ever mounted, expands into the tools --")

        // Two of five are offering an update. The other three are the
        // discriminating half: a builder that forgot to filter would pass
        // every "the pending ones are present" assertion below.
        let details = ["gh-axi": "0.2.3 \u{2192} 0.2.4", "no-mistakes": "1.4.0 \u{2192} 1.5.0"]
        let items = ["gh-axi", "no-mistakes", "treehouse", "lavish-axi", "quota-axi"].map(item)
        DependencyCheckCache.checkOverrideForTests = { item in
            if let detail = details[item.id] { return outcome(.updateAvailable, detail) }
            return outcome(.upToDate, "1.0.0 is current")
        }

        withAmbientEnv {
            let poller = BackgroundSignalsPoller.shared
            // The real ambient half: the real `sweepSoftware` against a
            // disposable cache, then the real main-thread apply that the real
            // pass dispatches to.
            poller.debugRunAmbientToolPass(cache: DependencyCheckCache(), items: items)

            guard let children = publishedChildren(NotificationSources.toolUpdatesID) else {
                fail("the ambient pass published no Tool Updates entry at all", &ok)
                return
            }
            check(children.map(\.name) == ["GH-AXI", "NO-MISTAKES"],
                  "the ambient pass expanded into \(children.map(\.name)) - expected the two tools that offer an Update, in catalog order",
                  &ok)
            check(children.map(\.meta) == ["0.2.3 \u{2192} 0.2.4", "1.4.0 \u{2192} 1.5.0"],
                  "the children carry \(children.map(\.meta)) rather than the real version pairs the check produced", &ok)
            check(children.allSatisfy { $0.actionLabel == "Update" },
                  "an ambient tool child has no Update button - the row would expand into a dead list", &ok)
            check(children.allSatisfy { $0.isMonospaced },
                  "a version pair is not monospaced in the ambient case, so it reads differently from the page's own", &ok)
            check(children.allSatisfy { $0.perform != nil },
                  "an ambient tool child's action is nil - AGENTS.md: a button that cannot act is worse than no button", &ok)
        }
        if ok { print("  OK   two children, by name, with their real version pairs and a live Update") }
    }

    // MARK: 2 - the ambient fork pass

    private static func checkAmbientForkPassPublishesRealChildren(_ ok: inout Bool) {
        print("\n-- the same for GitHub Sync, furthest behind first --")

        let repos = [repo("chrome-devtools-axi"), repo("gh-axi"), repo("treehouse"), repo("tasks-axi")]
        let outcomes = [forkOutcome(.behind(3), "3 commits behind upstream/x"),
                        forkOutcome(.behind(12), "12 commits behind upstream/x"),
                        forkOutcome(.inSync, "in sync"),
                        forkOutcome(.diverged(localOnly: 1, upstreamAhead: 2), "diverged")]

        withAmbientEnv {
            BackgroundSignalsPoller.shared.debugRunAmbientForkPass(repos: repos, outcomes: outcomes)

            guard let children = publishedChildren(NotificationSources.githubSyncID) else {
                fail("the ambient pass published no GitHub Sync entry at all", &ok)
                return
            }
            // `.diverged` and `.inSync` are the discriminating half here: a
            // diverged repo has nothing to fast-forward, and counting it would
            // put a child under a title that never counted it.
            check(children.map(\.name) == ["gh-axi", "chrome-devtools-axi"],
                  "the ambient fork pass expanded into \(children.map(\.name)) - expected the two syncable repos, furthest behind first",
                  &ok)
            check(children.map(\.meta) == ["12 commits behind upstream/x", "3 commits behind upstream/x"],
                  "the children carry \(children.map(\.meta)) rather than the real behind-by lines the check produced", &ok)
            check(children.allSatisfy { $0.actionLabel == "Sync" && $0.perform != nil },
                  "an ambient fork child has no live Sync button", &ok)
            check(children.first?.id == "manjesh-raj/gh-axi",
                  "a child's id is \(children.first?.id ?? "nil") - the page keys its own by full name, and the two must match "
                      + "or the popover re-animates every row when a page takes over", &ok)
        }
        if ok { print("  OK   two children, furthest behind first, with a live Sync") }
    }

    // MARK: 3 - each child's action is real

    private static func checkEveryChildActionReachesARealPath(_ ok: inout Bool) {
        print("\n-- a child's button routes to the real page action, not to nothing --")

        withAmbientEnv {
            let poller = BackgroundSignalsPoller.shared
            var updated: [String] = []
            var synced: [String] = []
            poller.onUpdateTool = { updated.append($0) }
            poller.onSyncFork = { synced.append($0) }

            DependencyCheckCache.checkOverrideForTests = { item in
                outcome(item.id == "gh-axi" ? .updateAvailable : .upToDate, "0.2.3 \u{2192} 0.2.4")
            }
            poller.debugRunAmbientToolPass(cache: DependencyCheckCache(),
                                           items: [item("gh-axi"), item("quota-axi")])
            publishedChildren(NotificationSources.toolUpdatesID)?.first?.perform?()
            check(updated == ["gh-axi"],
                  "pressing an ambient tool child's Update routed \(updated) - it must hand that tool's id to the shell", &ok)

            poller.debugRunAmbientForkPass(repos: [repo("gh-axi")],
                                           outcomes: [forkOutcome(.behind(2), "2 commits behind")])
            publishedChildren(NotificationSources.githubSyncID)?.first?.perform?()
            check(synced == ["manjesh-raj/gh-axi"],
                  "pressing an ambient fork child's Sync routed \(synced)", &ok)
        }

        // The wiring half. A headless suite cannot mount the shell, so the
        // routing hooks above could reach a real page action or nothing at
        // all and every assertion so far would read identically - which is
        // precisely the gap AGENTS.md's "a behavioural check and a source
        // guard catch different things" rule is about.
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  NOTE: could not resolve the app sources - skipping the wiring guard")
            return
        }
        func read(_ name: String) -> String {
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let main = read("main.swift")
        check(main.contains("onUpdateTool = ") && main.contains("onSyncFork = "),
              "main.swift no longer wires the poller's per-tool/per-repo routing hooks, so every ambient child's button is dead", &ok)

        let shell = read("AppShellController.swift")
        check(shell.contains("requestUpdateFromNotification"),
              "AppShellController no longer asks the Updates page to run the update it was handed", &ok)
        check(shell.contains("requestSyncFromNotification"),
              "AppShellController no longer asks the GitHub Sync page to run the sync it was handed", &ok)

        // And the page halves really run the real action rather than only
        // scrolling somewhere.
        let updates = read("UpdatesController.swift")
        check(updates.contains("confirmAndUpdate(row)"),
              "UpdatesController.requestUpdateFromNotification no longer reaches the page's own confirm-and-update path", &ok)
        let sync = read("GitHubSyncController.swift")
        check(sync.contains("self.sync(row)") || sync.contains("sync(row)"),
              "GitHubSyncController.requestSyncFromNotification no longer reaches the page's own sync path", &ok)
        if ok { print("  OK   ids route out of the poller and into each page's own real action") }
    }

    // MARK: 4 - one builder, two producers

    private static func checkBothProducersShareOneChildBuilder(_ ok: inout Bool) {
        print("\n-- the ambient pass and the pages cannot drift about what is pending --")

        // The shared builder's own contract, asserted directly: the filter is
        // the same predicate the title's count applies.
        let tools = [NotificationSignalChildren.Tool(id: "a", name: "A", status: .updateAvailable, detail: "1 \u{2192} 2"),
                     NotificationSignalChildren.Tool(id: "b", name: "B", status: .upToDate, detail: "2"),
                     NotificationSignalChildren.Tool(id: "c", name: "C", status: .notInstalled, detail: "-")]
        let built = NotificationSignalChildren.tools(tools, perform: { _ in })
        let counted = BackgroundSignalsPoller.toolUpdateCount(from: tools.map(\.status))
        check(built.count == counted,
              "the builder produced \(built.count) children under a title counting \(String(describing: counted)) - "
                  + "the list and the number must be the same predicate", &ok)

        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  NOTE: could not resolve the app sources - skipping the one-builder guard")
            return
        }
        for name in ["UpdatesController.swift", "GitHubSyncController.swift", "BackgroundSignalsPoller.swift"] {
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            check(code.contains("NotificationSignalChildren."),
                  "\(name) no longer builds its tool/fork notification children through NotificationSignalChildren - "
                      + "a second hand-rolled mapping is how the ambient row and the page's row come to disagree", &ok)
            // The poller is exempt from the second half: `publishSetupStepResults`
            // legitimately builds its own children, because the setup steps name
            // themselves and have exactly one producer.
            guard name != "BackgroundSignalsPoller.swift" else { continue }
            check(!code.contains("AppNotificationChild(id:"),
                  "\(name) hand-rolls an AppNotificationChild again", &ok)
        }
        if ok { print("  OK   one filter, one mapping, three call sites") }
    }
}

#endif
