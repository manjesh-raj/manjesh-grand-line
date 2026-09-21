// Manjesh Grand Line - native macOS app.
//
// The UI modernization audit's one functional finding: the phrase "ready to
// merge" was answered by three genuinely different questions, each computed
// independently, and any two of them could therefore disagree in a single
// frame without either being wrong on its own terms.
//
// What the captain actually saw:
//
//   - One screenshot of Review: its drill subtitle read "50 open - 0 ready
//     to merge" (counting `canMerge`) while its own stat tile a few inches
//     below read "34 ready to merge" (counting bare `checks == "green"`).
//   - Minutes later: Overview's canvas hero said "50 PRs ready to merge"
//     while the merge-queue card on the same canvas, off the identical
//     array, said "none ready" - because the hero counted the *open* list
//     outright and the card counted `canMerge`.
//
// `FleetDataSource.readyToMerge` is the one definition now, and this suite
// exists to keep it one. Its two halves fail for different reasons and both
// are needed:
//
//   - `checkOneDefinition` proves the shared function answers the merge
//     gate's question, against a fixture where all three old definitions
//     genuinely disagree. A fixture where they happen to agree would pass
//     against the bug, so the fixture asserts its own discriminating power
//     before it asserts anything else.
//   - `checkReviewPageAgrees` / `checkOverviewAgrees` mount the real
//     controllers and read the numbers *off the rendered views*. That is the
//     only thing that can see a surface which has stopped calling the shared
//     function - the failure that actually shipped. A check that recomputed
//     the count itself would agree with itself forever.
//   - `checkNoReDerivation` is the source guard, because the defect was a
//     *new* surface bringing its own filter, and no behavioural check can
//     see a filter nobody has written yet.
//
// Run: `FM_RUN_READY_TO_MERGE_TESTS=1 .build/debug/FirstmateCockpit`
//
// Window-backed (it mounts real controllers), so it belongs in
// `run-all-tests.sh`'s `NEEDS_SESSION` list. No network, no `gh`, no `git`,
// and no read of the captain's real `$FM_HOME`.

// GL-27: compiled into debug builds only. See `FleetDataSelfTest`'s own note.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ReadyToMergeCountSelfTest {

    static func run() -> Bool {
        var ok = true
        checkOneDefinition(&ok)
        checkReviewPageAgrees(&ok)
        checkOverviewAgrees(&ok)
        checkNoReDerivation(&ok)
        print(ok ? "ReadyToMergeCountSelfTest: all checks passed"
                 : "ReadyToMergeCountSelfTest: FAILED")
        return ok
    }


    private static func check(_ condition: Bool, _ label: String, _ ok: inout Bool) {
        SelfTestAssertions.recordNarrated(condition, label, &ok)
    }

    // MARK: The fixture

    /// Deliberately built so the three old definitions return three different
    /// numbers. Anything less and this whole suite could pass against the bug.
    ///
    ///   - open (what the greeting, the banner, the tile and the briefing all
    ///     counted):                                    6
    ///   - `checks == "green"` (what Review's tile counted):  3
    ///   - `canMerge` (what Review's subtitle counted):       2
    private static func fixture() -> [MergedPR] {
        func pr(_ n: Int, checks: String, taskID: String?) -> MergedPR {
            MergedPR(source: taskID == nil ? "forge" : "work", taskID: taskID,
                     repo: "checkout-api", url: "https://github.com/o/r/pull/\(n)",
                     number: n, title: "PR \(n)", checks: checks, forge: "github")
        }
        return [
            pr(1, checks: "green", taskID: "task-1"),     // mergeable
            pr(2, checks: "green", taskID: "task-2"),     // mergeable
            // The PR the spec names: green, but nothing owns it, so there is
            // no working path through `bin/fm-pr-merge.sh` (GL-38) and calling
            // it "ready to merge" is a claim this app cannot honour.
            pr(3, checks: "green", taskID: nil),
            pr(4, checks: "pending", taskID: "task-4"),
            pr(5, checks: "red", taskID: "task-5"),
            pr(6, checks: "none", taskID: nil),
        ]
    }

    private static let expectedOpen = 6
    private static let expectedGreen = 3
    private static let expectedReady = 2

    // MARK: One definition

    private static func checkOneDefinition(_ ok: inout Bool) {
        print("\n-- one definition of \"ready to merge\" --")

        let prs = fixture()

        // The fixture earns its keep first. If these three ever coincide, every
        // assertion below becomes vacuous and this suite stops testing anything.
        let open = prs.count
        let green = prs.filter { $0.checks == "green" }.count
        let ready = FleetDataSource.readyToMergeCount(prs)
        guard open == expectedOpen, green == expectedGreen, ready == expectedReady,
              open != green, green != ready else {
            fail("the fixture no longer discriminates: open=\(open) green=\(green) ready=\(ready) "
                 + "- it must produce three different numbers or this suite proves nothing", &ok)
            return
        }
        print("  ok  the fixture discriminates: open=\(open), green-only=\(green), ready=\(ready)")

        // The shared count is the merge gate's own answer, PR for PR.
        let gated = prs.filter(FleetDataSource.canMerge).map(\.url)
        check(FleetDataSource.readyToMerge(prs).map(\.url) == gated,
              "readyToMerge is exactly the set the Merge button is offered for", &ok)
        check(ready == gated.count, "and readyToMergeCount is that set's size", &ok)

        // A green PR with no owner is the case that separates the surviving
        // definition from the one Review's tile used.
        check(!FleetDataSource.readyToMerge(prs).contains { $0.taskID == nil },
              "a green PR with no tracked task is not counted as ready", &ok)

        check(FleetDataSource.readyToMergeCount([]) == 0, "an empty list counts zero", &ok)
    }

    // MARK: Review - the audit's own screenshot

    private static func checkReviewPageAgrees(_ ok: inout Bool) {
        print("\n-- Review: the drill subtitle and the stat tile, one frame --")

        let controller = ReviewController()
        let window = OffScreenProbe.window(width: 1100, height: 800, styleMask: [.titled, .resizable])
        window.contentViewController = controller
        window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 800), display: false)
        controller.view.layoutSubtreeIfNeeded()

        let prs = fixture()
        controller.debugRender(prs)
        controller.view.layoutSubtreeIfNeeded()

        guard let subtitle = controller.drillHeaderSubtitle else {
            fail("Review rendered no drill subtitle", &ok)
            return
        }
        guard let tile = controller.debugStatTiles.first(where: { $0.caption == "ready to merge" }) else {
            fail("Review has no \"ready to merge\" stat tile - tiles: \(controller.debugStatTiles)", &ok)
            return
        }

        // Read the number out of the rendered sentence rather than trusting a
        // format string: the defect is a *number*, and the sentence is what
        // the captain actually reads.
        guard let fromSubtitle = number(before: "ready to merge", in: subtitle) else {
            fail("could not read a ready count out of the subtitle: \"\(subtitle)\"", &ok)
            return
        }

        check(fromSubtitle == expectedReady,
              "the subtitle says \(expectedReady) ready to merge (said \(fromSubtitle))", &ok)
        check(tile.value == "\(expectedReady)",
              "the tile says \(expectedReady) too (said \(tile.value))", &ok)
        if fromSubtitle != Int(tile.value) {
            fail("the audit's exact screenshot is back: subtitle \"\(subtitle)\" beside a tile "
                 + "reading \(tile.value) - two numbers under one label, in one frame", &ok)
        }

        // The open count is the other half of that sentence and must stay the
        // open count: collapsing both halves onto one number would "fix" the
        // disagreement by deleting the information.
        check(number(before: "open", in: subtitle) == expectedOpen,
              "and still reports \(expectedOpen) open beside it", &ok)

        // **And the rows themselves** - review #3's B2.
        //
        // This sweep read the tiles and the subtitle only, which is exactly
        // why #392's own fix could unify every count on the page and leave the
        // row chip on the old `checks == "green"` test: 29 rows each wearing a
        // green "Ready to merge" chip under a subtitle reading 0. Same
        // question, one row down, and nothing asked it.
        //
        // Read off the rendered row, not re-derived: a check that computed the
        // expected label from the `MergedPR` would agree with itself whatever
        // rule the row used.
        let readyLabel = "Ready to merge"
        var rowsSayingReady = 0
        for row in 0..<controller.debugGithubRowCount {
            guard let chip = controller.debugGitHubRowChipText(at: row) else {
                fail("GitHub row \(row) rendered no chip at all", &ok)
                continue
            }
            if chip == readyLabel { rowsSayingReady += 1 }
        }
        check(rowsSayingReady == expectedReady,
              "\(expectedReady) row chip(s) say \"\(readyLabel)\" (counted \(rowsSayingReady))", &ok)
        if rowsSayingReady != expectedReady {
            fail("review #3's B2 is back: \(rowsSayingReady) rows claim \"\(readyLabel)\" under a "
                 + "subtitle and tile that both say \(expectedReady)", &ok)
        }

        // The green-but-untracked PR keeps its green tint and loses only the
        // claim: "Checks green" is true and strictly weaker, and it is what
        // tells the captain why that row has no Merge button either.
        let untrackedRow = fixture().firstIndex { $0.checks == "green" && $0.taskID == nil }
        if let untrackedRow, untrackedRow < controller.debugGithubRowCount {
            let chip = controller.debugGitHubRowChipText(at: untrackedRow)
            check(chip == "Checks green",
                  "the green-but-untracked row says \"Checks green\" (said \(chip ?? "nil"))", &ok)
        } else {
            fail("the fixture no longer carries a green-but-untracked PR - this check is vacuous", &ok)
        }
    }

    // MARK: Overview - hero, banner and tile, off one array

    private static func checkOverviewAgrees(_ ok: inout Bool) {
        print("\n-- Overview: the greeting, the banner and the tile, one array --")
        withScratchEnv {
            let prs = fixture()
            let snapshot = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                         queuedCount: 0, doneCount: 0, projectsCount: 0,
                                         watcher: WatcherHealth(status: "healthy"))

            // Overview's own page: the answer banner and the clickable tile.
            let fleet = FleetController(shiftStore: ShiftStore())
            let window = OffScreenProbe.window(width: 1200, height: 900, styleMask: [.titled, .resizable])
            window.contentViewController = fleet
            fleet.view.layoutSubtreeIfNeeded()
            fleet.debugRender(snapshot: snapshot, mergedPRs: prs)
            fleet.view.layoutSubtreeIfNeeded()

            let banner = fleet.debugBannerMeta
            if let fromBanner = number(before: "PRs ready to merge", in: banner) {
                check(fromBanner == expectedReady,
                      "the answer banner says \(expectedReady) PRs ready to merge (said \(fromBanner))", &ok)
            } else {
                fail("could not read a ready count out of the banner: \"\(banner)\"", &ok)
            }

            if let tile = fleet.debugStatTiles.first(where: { $0.caption == "ready to merge" }) {
                check(tile.value == "\(expectedReady)",
                      "Overview's tile says \(expectedReady) too (said \(tile.value))", &ok)
            } else {
                fail("Overview has no \"ready to merge\" tile - tiles: \(fleet.debugStatTiles)", &ok)
            }

            // The canvas hero, fed the same array the page pushes it.
            // **Not a first-run app.** Review #3's UX13 gave the hub its own
            // hero for a captain with nothing saved, and this case runs over
            // empty scratch stores - which is exactly that state, so without a
            // seeded task the hero below is legitimately the welcome banner
            // and carries no ready count to read. One task is the cheapest way
            // to say "this app has been used"; `NavigationCoherenceSelfTest`
            // asserts the first-run half.
            let shiftStore = ShiftStore()
            var seeded = ShiftTask.fresh()
            seeded.title = "a task, so the hub is not in its first-run state"
            shiftStore.addTask(seeded)
            let canvas = HomeCanvasController(sources: .init(
                shiftStore: shiftStore, hostStore: HostStore(), scheduleStore: ScheduleStore(),
                logAnalyzerStore: LogAnalyzerStore(), docsRunbookStore: DocsRunbookStore(),
                codePreviewStore: CodePreviewStore(),
                notebookStore: NotebookStore(), readingListStore: ReadingListStore(),
                commandLibraryStore: CommandLibraryStore(),
                stickyBoardStore: StickyBoardStore()))
            let canvasWindow = OffScreenProbe.window(width: 1400, height: 900, styleMask: [.titled, .resizable])
            canvasWindow.contentViewController = canvas
            canvas.view.layoutSubtreeIfNeeded()
            canvas.select(space: .overview)
            canvas.applyFleet(snapshot: snapshot, mergedPRs: prs, prFetchFailure: nil)
            canvas.view.layoutSubtreeIfNeeded()

            // **Review #3's UX5 deliberately took the count off this hero**,
            // and this assertion inverts rather than being deleted.
            //
            // The hub hero's all-clear detail used to enumerate the two cards
            // drawn directly under it - "N crew working / N PRs ready" - which
            // is exactly the "the same fact appears three times" the finding
            // is about. On the hub it is a freshness line now; the *Overview
            // page's* banner, which has no cards under it, still carries the
            // count and is still asserted above.
            //
            // So what this case checks here is the thing that actually
            // mattered: that the hub does not state a ready count of its own
            // that could contradict the merge-queue card below it. A hero
            // re-deriving that number is the defect this whole suite exists
            // to prevent, and a hero that does not state it cannot.
            let hero = canvas.greetingForTests.subtitle
            check(number(before: "PRs ready to merge", in: hero) == nil,
                  "the hub hero is restating the merge-queue card's count again: \"\(hero)\"", &ok)
            check(hero.hasPrefix("Fleet read "),
                  "the hub hero should carry UX5's freshness line, got \"\(hero)\"", &ok)

            // The merge-queue card is the surface that was already right, and
            // it is the one the hero visibly contradicted on the same canvas.
            // Asserting the pair is what proves the canvas agrees with itself.
            let mergeCard = canvas.moduleCardsForTests
                .first { $0.anatomyForTests.title == DaylightModule.mergeQueue.title }
            if let chip = mergeCard?.anatomyForTests.chipText {
                check(chip.contains("\(expectedReady) ready"),
                      "and the merge-queue card on the same canvas agrees (chip: \"\(chip)\")", &ok)
            } else {
                fail("the merge-queue card rendered no chip", &ok)
            }
        }
    }

    // MARK: Source guard - the surface nobody has written yet

    /// The bug was not one wrong filter; it was four surfaces each deriving a
    /// count of their own. A behavioural check can only see the surfaces that
    /// exist today, so this is the half that catches the next one.
    private static func checkNoReDerivation(_ ok: inout Bool) {
        print("\n-- source: no surface re-derives its own ready count --")
        // `appSourceFiles()` and not a recursive walk: it is deliberately
        // non-recursive so `SelfTests/` stays out of every source guard's
        // view. This suite is the live example of why - its own fixture
        // computes the old `checks == "green"` count on purpose, to prove the
        // fixture discriminates, and a recursive scan flagged that line.
        guard let files = SelfTestSources.appSourceFiles() else {
            print("  NOTE could not locate Sources/ - skipping the source guard")
            return
        }

        var offenders: [String] = []
        var scanned = 0
        for url in files {
            // `FleetData.swift` holds the one definition, and its own doc
            // comment quotes the shape it replaced in order to explain it.
            if url.lastPathComponent == "FleetData.swift" { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for (i, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Strip whole-line comments: several files name the old shape
                // in order to record why it went, and a guard that trips on
                // its own fix note is a guard nobody will keep.
                let line = String(rawLine)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if line.contains("checks == \"green\"") {
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        // A guard that scanned nothing passes for the wrong reason.
        guard scanned > 20 else {
            print("  NOTE only \(scanned) files scanned - treating the source guard as unrun")
            return
        }
        if offenders.isEmpty {
            print("  ok  \(scanned) files scanned, readiness is decided in one place")
        } else {
            for o in offenders {
                fail("re-derived readiness outside FleetDataSource - call "
                     + "`FleetDataSource.readyToMerge` instead: \(o)", &ok)
            }
        }
    }

    // MARK: Helpers

    /// The integer immediately preceding `phrase` in a rendered sentence, e.g.
    /// 2 out of "50 open \u{00B7} 2 ready to merge". Reads what the captain
    /// reads rather than re-running the app's own format string.
    private static func number(before phrase: String, in sentence: String) -> Int? {
        guard let range = sentence.range(of: phrase) else { return nil }
        let head = sentence[sentence.startIndex..<range.lowerBound]
        let digits = head.reversed().drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(String(digits.reversed()))
    }

    /// Mounting real controllers touches real stores; every one is redirected
    /// at a throwaway directory. `ThemeManager`/`AppSettings` are saved and
    /// restored for the reason `AppShellBodyWidthSelfTest`'s own copy states
    /// at length: those live in `UserDefaults`, which no env override reaches,
    /// and a leak there poisons every later suite in the run.
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-ready-to-merge-test-\(UUID().uuidString)")
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
        let savedTheme = ThemeManager.shared.theme
        let savedFontSize = AppSettings.shared.fontSize
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.fontSize = savedFontSize
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        return body()
    }
}

#endif
