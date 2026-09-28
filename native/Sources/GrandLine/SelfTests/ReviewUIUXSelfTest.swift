// Grand Line - native macOS app.
//
// The UI and UX findings of the 2026-09-27 full-application review
// (`fm/grand-line-review-ui-ux-u1-x7`): the 17 rendered UI defects and the
// seven UX issues X1..X7, one case per finding that has something a test can
// see.
//
// Most of the 17 are pixel defects and are covered by the review's own
// before/after screenshot convention rather than by a case here - only the
// findings with a behavioural or source-visible half live in this file:
//
//   U12  no em dash is used as a prose separator in this app's own copy
//   U13  the search palette's overflow line is grammatical
//   U5   the Health card's fraction and its sentence describe one thing
//   U6   DevOps Commands opens with a category selected, so a list is on screen
//   U10  an Updates row that needs nothing carries no action
//   U11  a primary action is disabled until the thing it acts on is ready
//   U16  the task editor strips the parsed date phrase out of the title
//   X1   the lock screen has a local fallback when the vault helper is down
//   X4   Bootstrap and Automation read one progress source
//   X7   the daily review no longer carries the "habits aren't in this build" row
//
// Run with:
//   swift build && FM_RUN_REVIEW_UI_UX_TESTS=1 .build/debug/GrandLine; echo $?
//
// Pure logic and source guards - no window is mounted here, so this suite is
// **not** in `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list and guards the
// blocking CI job. The window-backed half lives in
// `ReviewUIUXViewSelfTest.swift`.

// GL-27: compiled into debug builds only. Do not remove this guard when
// editing a suite - `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ReviewUIUXSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("U12_noEmDashIsUsedAsAProseSeparatorInAppCopy", test_u12NoProseEmDash),
            ("U13_searchPaletteOverflowLineIsGrammatical", test_u13OverflowGrammar),
            ("U3_emptyStateWatermarkTouchesNoText", test_u3WatermarkClearsTheCopy),
            ("U5_healthRingFractionAgreesWithItsSentence", test_u5HealthRing),
            ("U6_commandLibraryOpensWithACommandListOnScreen", test_u6CommandListOnOpen),
            ("U11_kubernetesRefreshIsOfferedOnlyWhenItCanAct", test_u11KubernetesRefresh),
            ("U11_syncAllIsOfferedOnlyWhenSomethingIsBehind", test_u11SyncAll),
            ("U7_X4_bootstrapAndAutomationReportOneProgress", test_u7x4SharedProgress),
            ("U8_runRebuildIsAPillNotAFullWidthBar", test_u8RebuildButtonWidth),
            ("U9_emptyNavColumnSaysWhatItIsForAndOffersAnAction", test_u9EmptySidebar),
            ("U9_notebookStatesOneStorageLocation", test_u9StorageWording),
            ("U10_updatesRowsCarryAnActionOnlyWhenOneIsNeeded", test_u10CheckButton),
            ("U14_allDestinationsOverlayFitsEveryName", test_u14OverlayWidth),
            ("U15_cardsHugTheContentTheyActuallyHold", test_u15CardHeights),
            ("U16_taskEditorLiftsTheDatePhraseAndEnablesTheRepeatPickers", test_u16TaskEditor),
            ("U17_lockScreenPasswordFieldDoesNotLookPreFilled", test_u17LockPlaceholder),
            ("X1_lockScreenOffersALocalFallbackWhenTheVaultIsUnreachable", test_x1LocalFallback),
            ("X3_theGoMenuNamesEachDestinationOnce", test_x3GoMenu),
            ("X5_emptyPagesOfferAnExampleToStartFrom", test_x5SeedExamples),
            ("X6_everythingCapturedTodayIsInOnePlace", test_x6CaptureInbox),
            ("X8_updatesOffersOneCheckAllNamedAfterTheWork", test_x8CheckAllIsNamedAfterTheWork),
            ("X2_oneMenuBarIconByDefaultWithAWayBack", test_x2OneStatusItem),
        ]
        var failures = 0
        for (name, body) in cases {
            if let failure = body() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
              ? "ReviewUIUXSelfTest: all \(cases.count) cases passed"
              : "ReviewUIUXSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// A source file with its `//` line comments and `/* */` block comments
    /// removed, so a guard sees only what the app actually compiles. Without
    /// this every guard below would trip on its own explanatory prose - and on
    /// the ~180 comments in this repository that legitimately use an em dash.
    private static func codeOnly(_ text: String) -> String {
        var out = ""
        var inBlock = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if inBlock {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                inBlock = false
            }
            while let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound ..< line.endIndex) {
                    line = String(line[line.startIndex ..< start.lowerBound])
                        + String(line[end.upperBound...])
                } else {
                    line = String(line[line.startIndex ..< start.lowerBound])
                    inBlock = true
                    break
                }
            }
            if let slashes = line.range(of: "//") {
                line = String(line[line.startIndex ..< slashes.lowerBound])
            }
            out += line + "\n"
        }
        return out
    }

    // MARK: U12 - em dashes in UI copy

    /// The two forms a prose em dash takes in this codebase: the literal
    /// character, and the `\u{2014}` escape several files prefer so the source
    /// stays ASCII. Both are looked for **with a space on each side**, which
    /// is what makes them a sentence separator rather than the standalone
    /// "value unknown" glyph GL-14 uses (`FleetController`'s PR count, the
    /// focus ring's empty planned time, an unchecked update's timestamp).
    /// That glyph is typography, not copy, and is deliberately left alone.
    private static let proseEmDashForms = [" \u{2014} ", " \\u{2014} "]

    /// The two files whose em dashes are not UI copy at all: they are the
    /// text of a prompt sent to Claude, where the dash is the model's input
    /// rather than something a captain reads.
    private static let promptFiles: Set<String> = ["StrawHatContext.swift", "LogAnalyzerAI.swift"]

    private static func test_u12NoProseEmDash() -> String? {
        guard let files = SelfTestSources.appSourceFiles() else {
            return "SKIP-AS-FAILURE: the app's sources are not next to this binary, "
                 + "so this guard would have checked nothing"
        }
        // Discriminating power first: the escape and the literal must both be
        // findable at all, or a typo in `proseEmDashForms` passes vacuously.
        for form in proseEmDashForms {
            guard ("a" + form + "b").contains(form) else {
                return "the guard's own needle \(form.debugDescription) does not match itself"
            }
        }
        var offenders: [String] = []
        for file in files where !promptFiles.contains(file.lastPathComponent) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = codeOnly(text)
            for form in proseEmDashForms where code.contains(form) {
                offenders.append("\(file.lastPathComponent) uses \(form.debugDescription)")
            }
        }
        guard offenders.isEmpty else {
            return "UI copy must use a plain dash, not an em dash (review U12): "
                 + offenders.joined(separator: "; ")
        }
        return nil
    }

    // MARK: U13 - the search palette's overflow line

    private static func test_u13OverflowGrammar() -> String? {
        // Every real group title, so a new plural title cannot reintroduce
        // the defect through a form this case never sees.
        for title in UnifiedSearchKind.groupOrder {
            let many = UnifiedSearchGroup(title: title, items: [], overflow: 45).overflowText
            let one = UnifiedSearchGroup(title: title, items: [], overflow: 1).overflowText
            // The defect itself: the group title used as an adjective in
            // front of a noun it does not agree with.
            if many.contains("\(title.lowercased()) match") || one.contains("\(title.lowercased()) match") {
                return "the overflow line still reads the group title as an adjective: \(many.debugDescription)"
            }
            guard many.hasPrefix("45 more matches in \(title)") else {
                return "the plural form is not grammatical: \(many.debugDescription)"
            }
            guard one.hasPrefix("1 more match in \(title)") else {
                return "the singular form is not grammatical: \(one.debugDescription)"
            }
        }
        guard !UnifiedSearchKind.groupOrder.isEmpty else {
            return "there are no group titles to check, so this case would have passed vacuously"
        }
        return nil
    }

    // MARK: U3 - the empty-state watermark

    /// The four pages the review rendered the collision on, plus the two
    /// other destinations that pass artwork - so a caller added later is
    /// swept too rather than only the four that were photographed.
    private static let watermarkDestinations: [RailDestination] =
        [.kubernetes, .stickyBoard, .docs, .postmortems, .codePreview, .whiteboard]

    private static func test_u3WatermarkClearsTheCopy() -> String? {
        // Every size the page-filling callers use, at a page-sized container
        // and at a deliberately cramped one - the cramped case is what the
        // required `top >= top` backstop exists for, and a check that only
        // ever saw a roomy container could not see it fail.
        let containers: [NSSize] = [NSSize(width: 1400, height: 760), NSSize(width: 700, height: 420)]
        for dest in watermarkDestinations {
            guard let artwork = dest.drillHeaderArtwork else {
                return "\(dest.rawValue) no longer carries drill-header artwork, so this case "
                     + "would have checked nothing for it"
            }
            for size in containers {
                let result: String? = autoreleasepool {
                    let state = HelmEmptyState(symbol: "bolt.horizontal.circle",
                                               title: "No live host session",
                                               body: "Every kubectl command runs inside a bastion session "
                                                   + "you have already logged into - that session is the only "
                                                   + "cluster credential there is. Connect a host first.",
                                               size: .standard,
                                               hue: dest.domainHue,
                                               artwork: artwork)
                    let host = NSView(frame: NSRect(origin: .zero, size: size))
                    state.translatesAutoresizingMaskIntoConstraints = false
                    host.addSubview(state)
                    NSLayoutConstraint.activate([
                        state.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                        state.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                        state.topAnchor.constraint(equalTo: host.topAnchor),
                        state.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    ])
                    host.layoutSubtreeIfNeeded()
                    let layout = state.debugWatermarkLayout()
                    let where_ = "\(dest.rawValue) at \(Int(size.width))x\(Int(size.height))"
                    // Discriminating power: a zero-sized mark, or a hidden
                    // title, would make every assertion below vacuous.
                    guard layout.watermarkFrame.width > 1, layout.watermarkFrame.height > 1 else {
                        return "\(where_): the watermark has no frame, so this case proves nothing"
                    }
                    guard layout.titleIsVisible, layout.titleFrame.height > 1,
                          layout.bodyFrame.height > 1 else {
                        return "\(where_): the title or body did not lay out, so this case proves nothing"
                    }
                    if layout.watermarkFrame.intersects(layout.titleFrame) {
                        return "\(where_): the watermark \(layout.watermarkFrame) still overlaps the "
                             + "title \(layout.titleFrame) (review U3)"
                    }
                    if layout.watermarkFrame.intersects(layout.bodyFrame) {
                        return "\(where_): the watermark \(layout.watermarkFrame) still overlaps the "
                             + "body copy \(layout.bodyFrame) (review U3)"
                    }
                    // The other half of the backstop: the mark must stay
                    // inside the state it decorates rather than painting over
                    // whatever sits above it.
                    if layout.watermarkFrame.minY < -0.5 || layout.watermarkFrame.maxY > size.height + 0.5 {
                        return "\(where_): the watermark \(layout.watermarkFrame) escapes the empty "
                             + "state's own bounds (height \(size.height))"
                    }
                    return nil
                }
                if let result { return result }
            }
        }
        return nil
    }

    // MARK: U5 - the Health card's fraction

    private typealias HealthReading = HomeCanvasController.HealthServiceReading

    private static func reading(_ title: String,
                                _ verdict: ServiceHealthState.Verdict,
                                reported: Bool) -> HealthReading {
        HealthReading(title: title, verdict: verdict, hasReported: reported)
    }

    private static func test_u5HealthRing() -> String? {
        // The review's own state: six services, two reported and healthy,
        // four never run. The defect was "2/6" beside "All reporting services
        // healthy" - the fraction counting all six, the sentence counting the
        // two.
        let partial = [
            reading("Background signals", .healthy, reported: true),
            reading("Persistence", .healthy, reported: true),
            reading("Fleet tasks", .unknown, reported: false),
            reading("Shift git sync", .unknown, reported: false),
            reading("Docs sync", .unknown, reported: false),
            reading("Scheduled automations", .unknown, reported: false),
        ]
        let summary = HomeCanvasController.healthRingSummary(partial)
        guard summary.value == 2, summary.total == 6 else {
            return "a partly-reported fleet should count reporting over total, got "
                 + "\(summary.value)/\(summary.total)"
        }
        guard summary.title == "Reporting" else {
            return "the ring still claims to be counting \(summary.title.debugDescription) while "
                 + "four of six services have never run"
        }
        guard summary.note == "2 of 6 reporting so far." else {
            return "the sentence does not name the same set as the fraction: \(summary.note.debugDescription)"
        }

        // GL-14's half: a service mid-pass that has never finished one is not
        // evidence of health. `.running` used to sit in the healthy bucket
        // whatever it had reported.
        let neverFinished = [
            reading("Background signals", .running, reported: false),
            reading("Persistence", .healthy, reported: true),
        ]
        let running = HomeCanvasController.healthRingSummary(neverFinished)
        guard running.value == 1, running.title == "Reporting" else {
            return "a service that is mid-pass and has never reported is being counted as healthy: "
                 + "\(running.value)/\(running.total) \(running.title)"
        }

        // Singular: "All 1 services healthy." is what a bare count reads as
        // on a machine where only one service has registered, which is the
        // probe's own state.
        let lone = HomeCanvasController.healthRingSummary([reading("Persistence", .healthy, reported: true)])
        guard lone.note == "The only service is healthy." else {
            return "the one-service sentence is not grammatical: \(lone.note.debugDescription)"
        }

        // Everything reported and well: the fraction and the word agree, and
        // the sentence no longer hedges with "reporting".
        let allWell = (1...3).map { reading("Service \($0)", .healthy, reported: true) }
        let well = HomeCanvasController.healthRingSummary(allWell)
        guard well.value == 3, well.total == 3, well.title == "Healthy",
              well.note == "All 3 services healthy." else {
            return "a fully healthy fleet reads \(well.value)/\(well.total) \(well.title) - "
                 + "\(well.note.debugDescription)"
        }

        // A degraded service is no longer swept into "all healthy": the old
        // sentence only ever looked at `.failing`.
        let oneDegraded = [
            reading("Docs sync", .degraded, reported: true),
            reading("Persistence", .healthy, reported: true),
        ]
        let degraded = HomeCanvasController.healthRingSummary(oneDegraded)
        guard degraded.value == 1, degraded.note == "Docs sync degraded." else {
            return "a degraded service still reads as healthy: \(degraded.value)/\(degraded.total) - "
                 + "\(degraded.note.debugDescription)"
        }

        // A failing service is named, in both the outstanding and the
        // complete case.
        let failingWhileIncomplete = [
            reading("Docs sync", .failing, reported: true),
            reading("Persistence", .unknown, reported: false),
        ]
        guard HomeCanvasController.healthRingSummary(failingWhileIncomplete).note
                == "Docs sync needs a look." else {
            return "a failing service is not named while others are still outstanding"
        }

        // And the empty case B9 established, unchanged.
        let empty = HomeCanvasController.healthRingSummary([])
        guard empty.total == 0, empty.note == "Nothing has reported yet." else {
            return "the no-services state changed: \(empty)"
        }
        return nil
    }

    // MARK: U6 - DevOps Commands opens to a visible list

    /// A scratch `FM_COMMAND_LIBRARY_DIR`, so the seeded library is built
    /// fresh rather than read out of the captain's own `~/.dotfiles` copy.
    private static func withScratchCommandLibrary<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-ui-ux-commands-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = ProcessInfo.processInfo.environment["FM_COMMAND_LIBRARY_DIR"]
        setenv("FM_COMMAND_LIBRARY_DIR", dir.path, 1)
        defer {
            if let previous { setenv("FM_COMMAND_LIBRARY_DIR", previous, 1) }
            else { unsetenv("FM_COMMAND_LIBRARY_DIR") }
        }
        return body()
    }

    private static func test_u6CommandListOnOpen() -> String? {
        withScratchCommandLibrary {
            autoreleasepool {
                let store = CommandLibraryStore()
                let page = CommandLibraryPageView(store: store)
                page.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
                page.view.layoutSubtreeIfNeeded()
                let contents = page.debugLeftPanelContents()

                // Discriminating power: a library with no commands in it
                // would make "the list is on screen" unfalsifiable.
                guard store.commands.count > 10 else {
                    return "the scratch library seeded only \(store.commands.count) commands, so "
                         + "this case could not tell a rendered list from an empty one"
                }
                // The defect itself: the detail pane says "Pick a command
                // from the list", so a command row has to be on screen when
                // it says it.
                guard page.debugEmptyDetailIsShowing else {
                    return "the detail pane no longer shows its \"pick a command\" state on open, so "
                         + "this case is measuring something else"
                }
                guard contents.commandRowCount == store.commands.count else {
                    return "DevOps Commands opens with \(contents.commandRowCount) command rows on "
                         + "screen out of \(store.commands.count) - the detail pane asks the captain "
                         + "to pick from a list that is not there (review U6)"
                }
                guard contents.categoryRowIDs.first == CommandLibraryPageView.allCategoryID else {
                    return "\"All\" is not the first category row: \(contents.categoryRowIDs.prefix(3))"
                }
                guard contents.lines.contains("ALL COMMANDS") else {
                    return "the command list carries no heading: \(contents.lines.prefix(6))"
                }
                return nil
            }
        }
    }

    // MARK: U11 - a primary action that cannot act

    private static func test_u11KubernetesRefresh() -> String? {
        autoreleasepool {
            let sessions = HostSessionRegistry()
            let controller = KubernetesController(sessions: sessions)
            let hostID = UUID()
            let feedTab = KubeFeedTab(id: UUID(), name: "EKS Bastion \u{00B7} k8s feed",
                                      terminal: FakeBridgeTerminal())
            var access = KubeSessionAccess()
            access.tabs = { _ in [feedTab] }
            controller.configure(access: access)
            controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 780)
            controller.view.layoutSubtreeIfNeeded()

            // The review's own state: no live host session at all.
            guard controller.debugEmptyStateVisible else {
                return "the page is not in its no-session state, so this case is measuring something else"
            }
            guard !controller.debugRefreshEnabled else {
                return "Refresh is offered as a filled accent pill on a page that says \"No live host "
                     + "session\" and cannot act (review U11)"
            }
            guard let reason = controller.debugRefreshTooltip, reason.contains("Connect a host") else {
                return "the disabled Refresh says nothing about why: "
                     + "\(String(describing: controller.debugRefreshTooltip))"
            }

            // And the other direction, so this is not just an assertion that
            // the button is always dead: once there is a session, a scope
            // and a feed tab, it comes back.
            sessions.register(hostID: hostID, label: "EKS Preprod Bastion",
                              accentHex: "6cd7e3", state: .connected)
            controller.debugAdoptFeedTab(feedTab)
            controller.view.layoutSubtreeIfNeeded()
            guard controller.debugRefreshEnabled else {
                return "Refresh stays disabled with a live session, a scope and a feed tab - the fix "
                     + "has turned it off permanently rather than gating it"
            }
            return nil
        }
    }

    private static func test_u11SyncAll() -> String? {
        autoreleasepool {
            let controller = GitHubSyncController()
            controller.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 900)
            controller.view.layoutSubtreeIfNeeded()

            guard controller.debugRowCount > 1 else {
                return "the page rendered \(controller.debugRowCount) repo rows, so this case could "
                     + "not tell a gated button from an empty page"
            }
            // The review's own state: every row still unchecked.
            guard !controller.debugSyncAllEnabled else {
                return "\"Sync All\" is offered as an enabled primary button while no fork has been "
                     + "checked yet (review U11)"
            }
            guard let reason = controller.debugSyncAllTooltip, reason.contains("press Refresh") else {
                return "the disabled \"Sync All\" says nothing about why: "
                     + "\(String(describing: controller.debugSyncAllTooltip))"
            }

            // Checked and everything in sync is still nothing to do.
            for index in 0 ..< controller.debugRowCount {
                controller.debugSetStatus(.inSync, atRow: index)
            }
            guard !controller.debugSyncAllEnabled else {
                return "\"Sync All\" is offered with every fork already in sync"
            }

            // One fork behind is the state it exists for.
            controller.debugSetStatus(.behind(3), atRow: 0)
            guard controller.debugSyncAllEnabled else {
                return "\"Sync All\" stays disabled with a fork 3 commits behind - the fix has "
                     + "turned it off permanently rather than gating it"
            }
            guard controller.debugSyncAllTooltip?.contains("1 fork") == true else {
                return "the enabled \"Sync All\" does not say what it would do: "
                     + "\(String(describing: controller.debugSyncAllTooltip))"
            }
            return nil
        }
    }

    // MARK: U7 / X4 - two pages, one setup checklist

    private static func test_u7x4SharedProgress() -> String? {
        let all = SetupStepKind.allCases
        guard all.count == 5 else {
            return "the canonical checklist is \(all.count) steps, not 5 - this case's expected "
                 + "sentences below were written against five"
        }

        // The review's own machine: Firstmate home verified, the rest still
        // being checked. Bootstrap said "1 of 4", Automation said "0 of 5".
        var verdicts: [SetupStepKind: Bool?] = [:]
        for kind in all { verdicts[kind] = Bool?.none }
        verdicts[.firstmateHome] = true
        let checking = SetupPipelineProgress.of(verdicts)
        guard checking.summary == "1 of 5 steps done \u{00B7} checking\u{2026}" else {
            return "a partly-checked machine reads \(checking.summary.debugDescription)"
        }

        // The denominator is the whole checklist, including the step
        // Bootstrap's own "Run full setup" does not run - the list shows
        // five, so the count says five.
        guard checking.total == all.count else {
            return "the progress line counts \(checking.total) steps while the checklist has \(all.count)"
        }
        guard all.contains(.restoreConfig), !SetupStepKind.restoreConfig.isPartOfFullSetupSequence else {
            return "restoreConfig is no longer the step outside the run sequence, so this case is "
                 + "no longer covering the denominator disagreement it was written for"
        }

        // A fully set-up machine, which is the case Automation used to
        // report as "0 of 5" however set up the Mac actually was.
        var allDone: [SetupStepKind: Bool?] = [:]
        for kind in all { allDone[kind] = true }
        guard SetupPipelineProgress.of(allDone).summary == "5 of 5 steps done" else {
            return "a fully set-up machine reads \(SetupPipelineProgress.of(allDone).summary.debugDescription)"
        }

        // A run that stopped is still reported, and it is the only thing
        // either page passes in from its own sequencer.
        var oneLeft: [SetupStepKind: Bool?] = allDone
        oneLeft[.software] = false
        guard SetupPipelineProgress.of(oneLeft, failedSteps: 1).summary
                == "4 of 5 steps done \u{00B7} 1 failed" else {
            return "a failed run is not reported: "
                 + "\(SetupPipelineProgress.of(oneLeft, failedSteps: 1).summary.debugDescription)"
        }

        // GL-14: a step nobody asked about is "still checking", never "not
        // done" - the two read differently and must keep doing so.
        guard SetupPipelineProgress.of([:]).summary == "0 of 5 steps done \u{00B7} checking\u{2026}" else {
            return "an unmeasured checklist claims to have been measured: "
                 + "\(SetupPipelineProgress.of([:]).summary.debugDescription)"
        }

        // The source guard: neither page may compose its own sentence again.
        // A behavioural check cannot see a *third* page doing it, and the
        // whole defect was two spellings of one fact.
        guard let files = SelfTestSources.appSourceFiles() else {
            return "SKIP-AS-FAILURE: the app's sources are not next to this binary, so the "
                 + "one-sentence guard would have checked nothing"
        }
        var offenders: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = codeOnly(text)
            for phrase in ["steps ready", "steps done"] where code.contains(phrase) {
                guard file.lastPathComponent != "SetupStepChecks.swift" else { continue }
                offenders.append("\(file.lastPathComponent) spells out \(phrase.debugDescription)")
            }
        }
        guard offenders.isEmpty else {
            return "the setup checklist's progress sentence is written in more than one place "
                 + "(review U7/X4): \(offenders.joined(separator: "; "))"
        }
        // And that the one place really does still contain it, so the guard
        // above cannot pass by the sentence having moved somewhere it cannot
        // see.
        let home = files.first { $0.lastPathComponent == "SetupStepChecks.swift" }
        guard let home, let text = try? String(contentsOf: home, encoding: .utf8),
              codeOnly(text).contains("steps done") else {
            return "SetupStepChecks.swift no longer composes the progress sentence, so the guard "
                 + "above is checking nothing"
        }
        return nil
    }

    // MARK: U8 - Bootstrap's "Run rebuild.sh"

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private static func test_u8RebuildButtonWidth() -> String? {
        autoreleasepool {
            let controller = BootstrapController(hostStore: HostStore(), keyStore: SSHKeyStore(),
                                                 snippetStore: SnippetStore(),
                                                 dictationStore: DictationStore())
            let state = DotfilesRepoState(repoPath: "/tmp/dotfiles", remoteURL: nil, branch: "main",
                                          dirtyFiles: [], flakeUsername: nil,
                                          commitsBehindOrigin: nil, commitsBehindOriginList: nil)
            let section = controller.debugDotfilesPresentSection(repoPath: "/tmp/dotfiles", state: state)

            let width: CGFloat = 900
            let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
            section.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(section)
            NSLayoutConstraint.activate([
                section.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                section.widthAnchor.constraint(equalToConstant: width),
                section.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            host.layoutSubtreeIfNeeded()

            guard let button = descendants(of: section).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "Run rebuild.sh" }) else {
                return "the dotfiles section no longer renders a \"Run rebuild.sh\" button, so this "
                     + "case is measuring nothing"
            }
            let frame = section.convert(button.bounds, from: button)
            // Discriminating power: a section that did not lay out would
            // report a zero-width button and pass the "not full width" test
            // for the wrong reason.
            guard frame.width > 40, section.bounds.width >= width - 1 else {
                return "the section did not lay out (button \(frame), section \(section.bounds))"
            }
            // The defect: the row loop pins every row's width to the
            // section's, and the button was one of those rows.
            guard frame.width < section.bounds.width * 0.5 else {
                return "\"Run rebuild.sh\" is \(frame.width)pt wide in a \(section.bounds.width)pt "
                     + "section - it is still a full-width bar rather than a pill (review U8)"
            }
            // And it sits at the trailing edge, where this page's other
            // actions are.
            guard abs(frame.maxX - section.bounds.width) < 2 else {
                return "\"Run rebuild.sh\" ends at \(frame.maxX) in a \(section.bounds.width)pt "
                     + "section - it is not trailing-aligned"
            }
            return nil
        }
    }

    // MARK: U9 - the Notebook's blank sidebar and contradictory copy

    private static func test_u9EmptySidebar() -> String? {
        autoreleasepool {
            let sidebar = HelmPageSidebar(surface: .panel, countStyle: .badge)
            sidebar.frame = NSRect(x: 0, y: 0, width: 275, height: 900)

            // The defect: nothing at all.
            sidebar.setSections([])
            sidebar.layoutSubtreeIfNeeded()
            let bare = descendants(of: sidebar).compactMap { ($0 as? NSTextField)?.stringValue }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard bare.isEmpty else {
                return "a column with no empty state set already draws \(bare) - this case can no "
                     + "longer tell the fix from the defect"
            }

            var pressed = 0
            sidebar.setEmptyState(.init(header: "Pages",
                                        body: "No pages yet. Every page you add shows up here.",
                                        actionTitle: "New page",
                                        onAction: { pressed += 1 }))
            sidebar.layoutSubtreeIfNeeded()
            let labels = descendants(of: sidebar).compactMap { ($0 as? NSTextField)?.stringValue }
            guard labels.contains(where: { $0.caseInsensitiveCompare("Pages") == .orderedSame }) else {
                return "the empty column still has no heading: \(labels)"
            }
            guard labels.contains(where: { $0.hasPrefix("No pages yet") }) else {
                return "the empty column still says nothing about itself: \(labels)"
            }
            guard let button = descendants(of: sidebar).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "New page" }) else {
                return "the empty column offers no action"
            }
            // The affordance has to reach the page, not merely exist - a
            // button wired to nothing is the defect with a nicer face on it.
            button.performClick(nil)
            guard pressed == 1 else {
                return "the empty column's action fired \(pressed) times, not once"
            }

            // And it gets out of the way once there is something to list.
            let row = HelmPageSidebar.Row(id: "a", indicator: .symbol("doc.text"), title: "A page")
            sidebar.setSections([HelmPageSidebar.Section(header: "Pages", rows: [row])])
            sidebar.layoutSubtreeIfNeeded()
            guard descendants(of: sidebar).compactMap({ $0 as? NSButton })
                .allSatisfy({ $0.title != "New page" }) else {
                return "the empty-state action is still drawn over a column that has rows"
            }

            // The component can be right while the page that needed it never
            // asks. A behavioural check of Notebook's own column would have
            // to stand up a `WKWebView`-backed controller, so this half is a
            // source guard and says so.
            guard let files = SelfTestSources.appSourceFiles(),
                  let notebook = files.first(where: { $0.lastPathComponent == "NotebookController.swift" }),
                  let text = try? String(contentsOf: notebook, encoding: .utf8) else {
                return "SKIP-AS-FAILURE: NotebookController.swift is not next to this binary"
            }
            guard codeOnly(text).contains("sidebar.setEmptyState(") else {
                return "Notebook's page column sets no empty state, so it is still a blank card "
                     + "with no pages in it (review U9)"
            }
            return nil
        }
    }

    private static func test_u9StorageWording() -> String? {
        let local = NotebookController.storageWording(isGitSynced: false)
        let synced = NotebookController.storageWording(isGitSynced: true)
        guard local != synced else {
            return "both storage locations read the same, so this case proves nothing"
        }
        // The contradiction itself: the empty state claimed a config repo on
        // a Mac that has none, while the header said "saved on this machine".
        guard !local.localizedCaseInsensitiveContains("repo") else {
            return "a Mac with no config repo is still told its pages are in one: \(local.debugDescription)"
        }
        guard synced.localizedCaseInsensitiveContains("repo") else {
            return "a Mac with a config repo is not told its pages are in it: \(synced.debugDescription)"
        }
        // And that the empty state really is built from it rather than
        // spelling its own sentence again.
        guard let files = SelfTestSources.appSourceFiles(),
              let notebook = files.first(where: { $0.lastPathComponent == "NotebookController.swift" }),
              let text = try? String(contentsOf: notebook, encoding: .utf8) else {
            return "SKIP-AS-FAILURE: NotebookController.swift is not next to this binary"
        }
        let code = codeOnly(text)
        guard !code.contains("markdown file in your config repo") else {
            return "the empty state still hard-codes \"a markdown file in your config repo\" (review U9)"
        }
        guard code.contains("markdown file \\(whereItGoes)") else {
            return "the empty state no longer interpolates the shared wording, so the two sentences "
                 + "are free to drift apart again"
        }
        return nil
    }

    // MARK: U10 - an action on every Updates row

    private static func test_u10CheckButton() -> String? {
        // The rule, stated once: Check is the row's next step only when
        // nothing else is, and never beside an Update button.
        let expected: [(DependencyStatus, Bool)] = [
            (.unknown, true),
            (.checkFailed, true),
            (.upToDate, false),
            (.updateAvailable, false),
            (.notInstalled, false),
            (.updateFailed, false),
            (.checking, false),
            (.updating, false),
        ]
        for (status, shows) in expected where status.showsCheckButton != shows {
            return "\(status) \(status.showsCheckButton ? "offers" : "hides") Check, expected the "
                 + "opposite (review U10)"
        }
        // Discriminating power: a predicate that is always false would pass
        // every "hides it" line above.
        guard expected.contains(where: { $0.1 }) , DependencyStatus.unknown.showsCheckButton else {
            return "no status offers Check at all, so a row that has never been checked has no way "
                 + "to be checked"
        }
        // No row may end up with no action *and* nothing to say: every
        // status either shows Check, shows Update, or is a settled state.
        for status in [DependencyStatus.unknown, .upToDate, .updateAvailable, .notInstalled,
                       .checkFailed, .updateFailed] {
            let settled = status == .upToDate
            guard settled || status.showsCheckButton || status.showsUpdateButton else {
                return "\(status) offers no action at all and is not a settled state"
            }
        }

        return autoreleasepool { () -> String? in
            let controller = UpdatesController()
            controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
            controller.view.layoutSubtreeIfNeeded()
            let states = controller.debugRowActionStates
            guard states.count > 5 else {
                return "the page rendered \(states.count) rows, so this case could not tell a gated "
                     + "button from an empty page"
            }
            // Unchecked on first render, so every row legitimately offers
            // Check - the state the review saw, and the one this fix keeps.
            guard states.allSatisfy({ !$0.checkHidden }) else {
                return "an unchecked row hides its own Check button, which is the only thing that "
                     + "can change it"
            }
            for index in 0 ..< states.count { controller.debugSetStatus(.upToDate, atRow: index) }
            let settled = controller.debugRowActionStates
            guard settled.allSatisfy({ $0.checkHidden && $0.updateHidden }) else {
                let offenders = settled.filter { !$0.checkHidden || !$0.updateHidden }.map(\.name)
                return "an up-to-date row still carries an action: \(offenders) (review U10)"
            }
            controller.debugSetStatus(.updateAvailable, atRow: 0)
            let withUpdate = controller.debugRowActionStates[0]
            guard withUpdate.checkHidden, !withUpdate.updateHidden else {
                return "a row with an update available shows Check=\(!withUpdate.checkHidden), "
                     + "Update=\(!withUpdate.updateHidden) - it should carry Update alone"
            }

            // The toast's own band. A page whose content runs to the window's
            // bottom edge is what put "Checked 13 tools" on top of the
            // "Other tools" header.
            guard Toast.reservedBottomSpace > Toast.bottomInset + 20 else {
                return "the reserved band (\(Toast.reservedBottomSpace)) is no bigger than the old "
                     + "20pt padding plus the toast's own inset, so it reserves nothing"
            }
            guard let sources = SelfTestSources.appSourceFiles(),
                  let updates = sources.first(where: { $0.lastPathComponent == "UpdatesController.swift" }),
                  let text = try? String(contentsOf: updates, encoding: .utf8),
                  codeOnly(text).contains("Toast.reservedBottomSpace") else {
                return "the Updates page no longer reserves the toast's band, so a completion toast "
                     + "lands on its last section header again (review U10)"
            }
            return nil
        }
    }

    // MARK: U14 - the all-destinations overlay's truncated names

    private static func test_u14OverlayWidth() -> String? {
        autoreleasepool {
            let tileWidth = AllDestinationsOverlayController.tileWidth
            var offenders: [String] = []
            var longest = ""
            var longestNeeded: CGFloat = 0
            for destination in RailDestination.allCases {
                let tile = DestinationTileView(destination: destination)
                let host = NSView(frame: NSRect(x: 0, y: 0, width: tileWidth + 40, height: 80))
                tile.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(tile)
                NSLayoutConstraint.activate([
                    tile.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    tile.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                ])
                host.layoutSubtreeIfNeeded()
                let label = tile.debugTitleLabel
                let needed = label.intrinsicContentSize.width
                if needed > longestNeeded { longestNeeded = needed; longest = destination.title }
                // `intrinsicContentSize` recomputes from the field's current
                // string and font every call, so comparing it against the
                // resolved frame catches a truncated-but-otherwise-correct
                // label without knowing any pixel count - the same shape
                // `AppShellDrillHeaderTitleSelfTest` uses.
                if needed > label.frame.width + 0.5 {
                    offenders.append("\(destination.title) needs \(needed)pt, given \(label.frame.width)pt")
                }
            }
            guard longestNeeded > 0 else {
                return "no destination title measured above zero, so this case proves nothing"
            }
            guard offenders.isEmpty else {
                return "the all-destinations overlay still truncates: \(offenders.joined(separator: "; "))"
            }
            // Discriminating power: the widest title must be the thing
            // driving the width, or the tile is merely wide by luck.
            guard tileWidth > AllDestinationsOverlayController.minimumTileWidth
                    || longestNeeded + AllDestinationsOverlayController.tileChromeWidth
                        <= AllDestinationsOverlayController.minimumTileWidth else {
                return "the tile is still at its floor (\(tileWidth)pt) while \(longest.debugDescription) "
                     + "needs \(longestNeeded)pt plus chrome"
            }
            // And the panel still fits the window the overlay is opened over.
            // 1100pt is the narrow width this repo's own layout suites use.
            guard AllDestinationsOverlayController.panelWidth <= 1100 - 80 else {
                return "the panel is \(AllDestinationsOverlayController.panelWidth)pt wide, which no "
                     + "longer sits inside a 1100pt window with room around it"
            }
            return nil
        }
    }

    // MARK: U15 - fixed-height cards with one sentence in them

    private static func test_u15CardHeights() -> String? {
        // The review's own three measurements, in order.
        //
        // 1. Morning briefing at 165pt for one line. PF2 (PR #485) turned
        //    `HelmModuleCard`'s fixed height into a floor while this review
        //    was being fixed, so this half is already closed - and it is
        //    asserted here rather than assumed, because "somebody else fixed
        //    it" is exactly the claim that rots.
        let oneLine = HelmModuleCard.Content(title: "Morning briefing", subtitle: "off in Settings",
                                             symbol: "sun.horizon", hue: .amber, chip: nil,
                                             body: .note("Turn on Morning briefing in Settings to "
                                                         + "get one short summary each morning."))
        let measured: CGFloat = autoreleasepool {
            let card = HelmModuleCard()
            card.configure(oneLine)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
            card.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(card)
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                card.widthAnchor.constraint(equalToConstant: 380),
                card.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            host.layoutSubtreeIfNeeded()
            return card.frame.height
        }
        guard measured > 1 else { return "the module card did not lay out, so this case proves nothing" }
        guard measured < 165 else {
            return "a one-line module card is still \(measured)pt tall - the review measured 165 "
                 + "(review U15)"
        }
        guard abs(measured - HelmModuleCard.minimumHeight) < 1 else {
            return "a one-line module card is \(measured)pt against a \(HelmModuleCard.minimumHeight)pt "
                 + "floor, so it is not hugging - something above the floor is padding it"
        }

        // 2. The Tasks page's Follow-ups card at 480pt while empty. The
        //    shared panel height was the four-row *ceiling* used as a fixed
        //    height; it is the content's own height clamped to that ceiling
        //    now, and both panels still share one number.
        return withScratchShiftStore { store in
            autoreleasepool {
                let controller = ShiftController(store: store)
                controller.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
                // The panel heights are re-derived on every render, and a
                // controller whose view was merely loaded has not rendered.
                controller.debugRender()
                controller.view.layoutSubtreeIfNeeded()
                let ceiling = ShiftController.debugTaskFollowUpPanelBodyHeight
                guard ceiling > 200 else {
                    return "the four-row ceiling measured \(ceiling)pt, so this case cannot tell a "
                         + "hugging panel from a fixed one"
                }
                let empty = controller.debugTaskFollowUpBodyHeight
                guard empty > 0 else {
                    return "the panels have no height constraint, so this case is measuring nothing"
                }
                guard empty < ceiling else {
                    return "both panels are still \(empty)pt tall - the four-row ceiling - around one "
                         + "empty-state line each (review U15)"
                }
                guard abs(empty - ShiftTaskListView.emptyRowHeight) < 1 else {
                    return "an empty panel is \(empty)pt, not the \(ShiftTaskListView.emptyRowHeight)pt "
                         + "its one placeholder row actually draws"
                }
                return nil
            }
        }
    }

    /// A scratch `FM_SHIFT_DIR`, so a mounted Tasks page never reads or
    /// writes the captain's real board.
    private static func withScratchShiftStore<T>(_ body: (ShiftStore) -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-ui-ux-shift-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", dir.path, 1)
        defer {
            if let previous { setenv("FM_SHIFT_DIR", previous, 1) } else { unsetenv("FM_SHIFT_DIR") }
        }
        return body(ShiftStore())
    }

    // MARK: U16 - the task editor

    private static func test_u16TaskEditor() -> String? {
        // The pure half first: what the title should read once the date has
        // been lifted out of it.
        let cases: [(String, String)] = [
            ("Buy milk tomorrow at 5pm", "Buy milk"),
            ("Review deploy notes tomorrow 3pm", "Review deploy notes"),
            ("Call Bob on monday", "Call Bob"),
            ("3pm standup", "standup"),
            ("Ship the release next week", "Ship the release"),
        ]
        for (typed, expected) in cases {
            guard let parsed = ShiftDateParser.parse(typed) else {
                return "\(typed.debugDescription) no longer parses as a date at all, so this case is "
                     + "measuring something else"
            }
            let stripped = ShiftDateParser.titleWithoutDatePhrase(typed, parsed: parsed)
            guard stripped == expected else {
                return "\(typed.debugDescription) strips to \(stripped.debugDescription), expected "
                     + "\(expected.debugDescription) (review U16)"
            }
        }
        // A title that *is* the date keeps its words - blanking it would
        // lose the only thing typed.
        if let parsed = ShiftDateParser.parse("tomorrow") {
            guard ShiftDateParser.titleWithoutDatePhrase("tomorrow", parsed: parsed) == "tomorrow" else {
                return "a title that is nothing but the date phrase was emptied"
            }
        }

        return autoreleasepool { () -> String? in
            let editor = ShiftTaskEditorController(task: nil, projects: [])
            _ = editor.view

            // The review's own second half: the pickers stay dimmed after a
            // detected due date.
            guard !editor.debugRepeatEnabled, !editor.debugReminderEnabled else {
                return "Repeat/Remind are live before any due date exists, so this case cannot tell "
                     + "the fix from the defect"
            }
            editor.debugTypeTitle("Buy milk tomorrow at 5pm")
            guard editor.debugDueRowIsOn else {
                return "typing a date phrase no longer turns the due switch on"
            }
            guard editor.debugRepeatEnabled, editor.debugReminderEnabled else {
                return "a due date arrived by detection and the Repeat/Remind pickers are still "
                     + "dimmed (review U16)"
            }

            // And the first half, through the real Save the footer button
            // fires.
            var saved: ShiftTask?
            editor.onSave = { task, _ in saved = task }
            editor.debugTriggerSave()
            guard let saved else { return "Save produced no task" }
            guard saved.title == "Buy milk" else {
                return "the saved task is still called \(saved.title.debugDescription) - the detected "
                     + "phrase was not lifted out of the title (review U16)"
            }
            guard saved.dueDate != nil else {
                return "the phrase was taken out of the title without the due date being set, which "
                     + "would lose it entirely"
            }

            // Dismissing the detection is the captain saying "those words
            // are not a date", so they stay.
            let kept = ShiftTaskEditorController(task: nil, projects: [])
            _ = kept.view
            kept.debugTypeTitle("Buy milk tomorrow at 5pm")
            kept.debugDismissDetected()
            var keptTask: ShiftTask?
            kept.onSave = { task, _ in keptTask = task }
            kept.debugTriggerSave()
            guard keptTask?.title == "Buy milk tomorrow at 5pm" else {
                return "dismissing the detection still stripped the title: "
                     + "\(String(describing: keptTask?.title))"
            }
            return nil
        }
    }

    // MARK: U17 - the lock screen's pre-filled-looking password field

    private static func test_u17LockPlaceholder() -> String? {
        autoreleasepool {
            let controller = LockScreenController()
            _ = controller.view
            let placeholder = controller.debugPasswordPlaceholder
            guard !placeholder.isEmpty else {
                return "the password field has no placeholder at all, so the empty field says "
                     + "nothing about what it is for"
            }
            // The defect: a secure field showing dots is a secure field with
            // something in it.
            guard !placeholder.contains("\u{2022}") else {
                return "the empty password field still renders masked dots (\(placeholder.debugDescription)), "
                     + "which reads as a pre-filled password (review U17)"
            }
            // Any masking glyph, not just the one that shipped - a bullet
            // swapped for a middle dot or an asterisk run is the same defect.
            for glyph in ["*", "\u{00B7}", "\u{25CF}", "\u{2219}"] where placeholder.contains(glyph) {
                return "the empty password field renders \(glyph.debugDescription) as a mask, which "
                     + "reads as a pre-filled password (review U17)"
            }
            return nil
        }
    }

    // MARK: X1 - the lock screen's dependence on the vault helper

    private static func test_x1LocalFallback() -> String? {
        autoreleasepool {
            let controller = LockScreenController()
            _ = controller.view

            // Simulating "the helper is unreachable" is exactly what the two
            // waiting states *are* - `AppShellController` applies them when
            // `av list` does not answer, and retries behind them forever.
            let waiting: [LockScreenController.ContentState] = [.serviceNotRunning, .transientFailure]
            let settled: [LockScreenController.ContentState] = [
                .locked(subtitle: "Grand Line is locked."), .noPasswordConfigured, .avUnavailable,
            ]

            // Discriminating power first: with no fallback wired, the two
            // waiting states are still the dead end the review found.
            controller.localAuthAvailable = { true }
            controller.onLocalAuthAttempt = nil
            for state in waiting {
                controller.apply(state)
                guard controller.debugLocalAuthStack.isHidden else {
                    return "the fallback is offered with nothing wired to it, so this case cannot "
                         + "tell the fix from the defect"
                }
            }

            var challenges = 0
            var answer = true
            controller.onLocalAuthAttempt = { completion in
                challenges += 1
                completion(answer)
            }

            // A Mac that cannot authenticate its owner keeps the retry loop
            // rather than being shown a button that cannot work.
            controller.localAuthAvailable = { false }
            for state in waiting {
                controller.apply(state)
                guard controller.debugLocalAuthStack.isHidden else {
                    return "the fallback is offered on a Mac that cannot authenticate its owner"
                }
            }

            controller.localAuthAvailable = { true }
            for state in waiting {
                controller.apply(state)
                guard !controller.debugLocalAuthStack.isHidden else {
                    return "the vault is unreachable and there is still no way past the lock screen "
                         + "but waiting (UX issue X1)"
                }
            }

            // **GL-09.** The fallback is an extra door, not a wider one. It
            // must not appear on a state that either has a working password
            // field or has never had an app password set at all - a machine
            // with no app secret must not be unlockable by anyone who can
            // wake its screen.
            for state in settled {
                controller.apply(state)
                guard controller.debugLocalAuthStack.isHidden else {
                    return "the local fallback is offered on a settled state, which would let a Mac "
                         + "with no app password configured be unlocked anyway (GL-09)"
                }
            }

            // A real press, through the real button's target/action - not
            // the handler behind it (AGENTS.md's `debug*` hook rule).
            var unlocked = 0
            controller.onUnlockAnimationFinished = { unlocked += 1 }
            controller.apply(.transientFailure)
            answer = false
            controller.debugLocalAuthButton.performClick(nil)
            guard challenges == 1 else {
                return "pressing the fallback ran \(challenges) challenges, not one - the button is "
                     + "not wired to the real handler"
            }
            // GL-25: a cancel aborts. It must not unlock, and it must not
            // read as a wrong password the captain never typed.
            guard unlocked == 0 else {
                return "a refused challenge unlocked the app anyway (GL-09/GL-25)"
            }
            guard !controller.debugErrorLabel.isHidden,
                  !controller.debugErrorLabel.stringValue.localizedCaseInsensitiveContains("password didn't match") else {
                return "a cancelled challenge reports \(controller.debugErrorLabel.stringValue.debugDescription), "
                     + "which is either silent or blames a password nobody typed"
            }
            guard controller.debugLocalAuthButton.isEnabled else {
                return "a cancelled challenge left the fallback button dead, so the captain is stuck "
                     + "again"
            }

            // And the door actually opens.
            answer = true
            controller.debugLocalAuthButton.performClick(nil)
            guard challenges == 2 else { return "the second press ran no challenge" }
            // The success animation is what fires `onUnlockAnimationFinished`
            // (never the callback directly - `submitTapped`'s own rule), and
            // Reduce Motion is on in CI, so give the real `CATransaction`
            // completion a run-loop turn to land.
            let deadline = Date().addingTimeInterval(3)
            while unlocked == 0, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            guard unlocked == 1 else {
                return "a successful device-owner challenge did not unlock the app (UX issue X1)"
            }
            return nil
        }
    }

    // MARK: X3 - navigation vocabulary

    private static func test_x3GoMenu() -> String? {
        let menu = AppDelegate().buildMenu(installing: false)
        guard let go = menu.items.compactMap(\.submenu).first(where: { $0.title == "Go" }) else {
            return "there is no Go menu, so this case is measuring nothing"
        }
        let rows = go.items.filter { !$0.isSeparatorItem }.map(\.title)
        guard rows.count > 20 else {
            return "the Go menu has \(rows.count) rows, so it is not the full destination menu"
        }

        // The review read the collision straight off this menu: "Home",
        // "Overview", "Home", an "Overview" header containing an "Overview"
        // item, and an "Elsewhere" group holding "Home" and "Fleet".
        guard !rows.contains("Overview") else {
            return "the Go menu still says \"Overview\", which names nothing now (review X3)"
        }
        // Every *destination* appears once. Space pill rows share their
        // names with the group headers they caption, which is the menu's own
        // grammar, so the check is on the destination titles rather than on
        // every row.
        let destinationTitles = Set(RailDestination.allCases.map(\.title))
        var counts: [String: Int] = [:]
        for row in rows where destinationTitles.contains(row) { counts[row, default: 0] += 1 }
        let repeated = counts.filter { $0.value > 1 }
        guard repeated.isEmpty else {
            return "the Go menu lists \(repeated.keys.sorted()) more than once (review X3)"
        }
        guard counts["Today"] == 1, counts["Home"] == 1, counts["Fleet"] == 1 else {
            return "Home/Today/Fleet should each appear exactly once, got "
                 + "Home=\(counts["Home"] ?? 0) Today=\(counts["Today"] ?? 0) Fleet=\(counts["Fleet"] ?? 0)"
        }
        // And a group whose only destination was already listed must not
        // leave an empty header behind.
        var previousWasHeader = false
        for item in go.items {
            let isHeader = !item.isSeparatorItem && !item.isEnabled && item.submenu == nil
            if previousWasHeader, item.isSeparatorItem || isHeader {
                return "the Go menu carries an empty group header"
            }
            if !item.isSeparatorItem { previousWasHeader = isHeader }
        }
        return nil
    }

    // MARK: X5 - empty pages should teach

    private static func buttonTitles(in view: NSView) -> [String] {
        descendants(of: view).compactMap { ($0 as? NSButton)?.title }
    }

    private static func test_x5SeedExamples() -> String? {
        // The content itself, first. Each example has to demonstrate the
        // mechanic its own page reads, or it teaches nothing - a runbook
        // with no fenced blocks reports "0 steps", a postmortem with no
        // root-cause line renders the page's emptiest row, and a Welcome
        // page with no wiki-link does not show the one thing the notebook
        // gives no other clue about.
        guard DocsRunbookMetadata.stepCount(in: SeedExamples.runbookContent) >= 3 else {
            return "the example runbook has \(DocsRunbookMetadata.stepCount(in: SeedExamples.runbookContent)) "
                 + "command steps, so the page would show it as an empty checklist"
        }
        guard DocsRunbookMetadata.rootCause(in: SeedExamples.postmortemContent) != nil else {
            return "the example postmortem carries no root-cause line, which is what its own row "
                 + "subtitle reads"
        }
        guard SeedExamples.notebookContent.contains("[["),
              SeedExamples.notebookContent.contains("]]") else {
            return "the Welcome page does not demonstrate [[links]], which is the review's own "
                 + "stated reason for it (review X5)"
        }
        guard !SeedExamples.stickyText.isEmpty, !SeedExamples.stickyTitle.isEmpty else {
            return "the example sticky note is blank"
        }

        return autoreleasepool { () -> String? in
            // Every store here is redirected to this process's own scratch
            // root by `main.swift`'s `#if FM_SELFTESTS` block, so nothing
            // below reaches the captain's real records.
            let runbooks = RunbooksController()
            _ = runbooks.view
            runbooks.debugReloadRunbooks()
            guard let runbookEmpty = runbooks.debugRunbookEmptyState else {
                return "Runbooks is not showing its empty state, so this case is measuring something else"
            }
            guard buttonTitles(in: runbookEmpty).contains("Add an example runbook") else {
                return "Runbooks' empty page still offers nothing to press (review X5): "
                     + "\(buttonTitles(in: runbookEmpty))"
            }
            let runbookStore = DocsRunbookStore()
            let runbooksBefore = runbookStore.listRunbooks().count
            runbooks.debugSeedExampleRunbook()
            let runbooksAfter = DocsRunbookStore().listRunbooks()
            guard runbooksAfter.count == runbooksBefore + 1,
                  runbooksAfter.contains(where: { $0.title == SeedExamples.runbookTitle }) else {
                return "seeding wrote no runbook: \(runbooksAfter.map(\.title))"
            }

            let postmortems = PostmortemsController()
            _ = postmortems.view
            guard buttonTitles(in: postmortems.debugPostmortemEmptyState).contains("Add an example") else {
                return "Postmortems' empty page offers no example: "
                     + "\(buttonTitles(in: postmortems.debugPostmortemEmptyState))"
            }
            let postmortemsBefore = DocsRunbookStore().listPostmortems().count
            postmortems.debugSeedExamplePostmortem()
            let postmortemsAfter = DocsRunbookStore().listPostmortems()
            guard postmortemsAfter.count == postmortemsBefore + 1,
                  postmortemsAfter.contains(where: { $0.title == SeedExamples.postmortemTitle }) else {
                return "seeding wrote no postmortem: \(postmortemsAfter.map(\.title))"
            }

            let sticky = StickyBoardController()
            _ = sticky.view
            let stickyStore = sticky.store
            let notesBefore = stickyStore.activeNotes.count
            guard buttonTitles(in: sticky.view).contains("Add an example note") else {
                return "the Sticky Board's empty state offers no example note"
            }
            sticky.debugSeedExampleNote()
            guard stickyStore.activeNotes.count == notesBefore + 1,
                  stickyStore.activeNotes.contains(where: { $0.title == SeedExamples.stickyTitle }) else {
                return "seeding pinned no note: \(stickyStore.activeNotes.map(\.title))"
            }

            let notebookStore = NotebookStore()
            let notebook = NotebookController(store: notebookStore)
            _ = notebook.view
            guard let overlay = notebook.debugEditorOverlayState else {
                return "the Notebook is not showing its empty overlay"
            }
            guard buttonTitles(in: overlay).contains("Add a Welcome page") else {
                return "the Notebook's empty editor offers no Welcome page: \(buttonTitles(in: overlay))"
            }
            let pagesBefore = notebookStore.listPages().count
            notebook.debugSeedWelcomePage()
            let pagesAfter = notebookStore.listPages()
            guard pagesAfter.count == pagesBefore + 1,
                  let welcome = pagesAfter.first(where: { $0.title == SeedExamples.notebookTitle }) else {
                return "seeding wrote no Welcome page: \(pagesAfter.map(\.title))"
            }
            guard welcome.content.contains("[[") else {
                return "the written Welcome page lost its wiki-link"
            }
            return nil
        }
    }

    // MARK: X6 - capture in, triage out

    private static func test_x6CaptureInbox() -> String? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-ui-ux-capture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("capture-inbox.json")
        let env = [CaptureInboxStore.fileVariable: file.path]

        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now

        let store = CaptureInboxStore(environment: env)
        guard store.entries(on: now).isEmpty else {
            return "a fresh log already has entries, so this case cannot tell a recorded capture "
                 + "from a pre-existing one"
        }
        store.record(destination: .task, title: "Rotate the bastion keys", at: now)
        store.record(destination: .link, title: "example.com/graceful-shutdown", at: now)
        store.record(destination: .sticky, title: "Old news", at: yesterday)
        // A capture with nothing in it is not a capture.
        store.record(destination: .note, title: "   ", at: now)

        let today = store.entries(on: now)
        guard today.count == 2 else {
            return "today's log holds \(today.count) entries, expected 2: \(today.map(\.title))"
        }
        guard today.first?.title == "example.com/graceful-shutdown" else {
            return "today's log is not newest-first: \(today.map(\.title))"
        }
        guard store.entries(on: yesterday).map(\.title) == ["Old news"] else {
            return "yesterday's capture leaked into today, or was lost"
        }

        // It survives a reopen - a log that only exists in memory answers
        // "what did I capture this morning" with nothing after a relaunch.
        let reopened = CaptureInboxStore(environment: env)
        guard reopened.entries(on: now).count == 2, !reopened.loadFailed else {
            return "the log did not round-trip through its file "
                 + "(loadFailed=\(reopened.loadFailed), \(reopened.entries(on: now).count) entries)"
        }

        // GL-01: an unreadable log is its own state, and it is never
        // overwritten by the process that could not read it.
        try? Data("not json".utf8).write(to: file)
        let broken = CaptureInboxStore(environment: env)
        guard broken.loadFailed else {
            return "an unparseable log reports as readable, so the card would draw an empty day "
                 + "over a file full of captures (GL-01/GL-14)"
        }
        broken.record(destination: .task, title: "should not be written", at: now)
        guard let raw = try? String(contentsOf: file, encoding: .utf8), raw == "not json" else {
            return "the store overwrote a log it could not read (GL-01)"
        }

        return autoreleasepool { () -> String? in
            // The card, against a stated day.
            let good = CaptureInboxStore(environment: [CaptureInboxStore.fileVariable:
                dir.appendingPathComponent("card.json").path])
            good.record(destination: .task, title: "Rotate the bastion keys", at: now)
            good.record(destination: .sticky, title: "Ask Ravi about peering", at: now)
            let card = CaptureInboxCard(store: good)
            card.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
            var opened: [RailDestination] = []
            card.onOpenDestination = { opened.append($0) }
            card.render(now: now, theme: ThemeManager.shared.theme)
            card.layoutSubtreeIfNeeded()

            guard card.debugRowTitles == ["Ask Ravi about peering", "Rotate the bastion keys"] else {
                return "the card is not showing today's captures newest-first: \(card.debugRowTitles)"
            }
            // The row has to say *where* it went, which is the whole point -
            // a list of titles with no destinations is the scatter the
            // review is complaining about, written down.
            guard card.debugRowDetails.contains(where: { $0.contains(RailDestination.stickyBoard.title) }),
                  card.debugRowDetails.contains(where: { $0.contains(RailDestination.shift.title) }) else {
                return "a row does not name the page its capture landed in: \(card.debugRowDetails)"
            }
            // And following one gets there, through the real recognizer.
            card.debugClickRow(0)
            guard opened == [.stickyBoard] else {
                return "clicking the first row opened \(opened), expected the Sticky Board"
            }

            // An empty day says so, and says how to capture - it is the
            // first thing a new captain sees on this card.
            let emptyStore = CaptureInboxStore(environment: [CaptureInboxStore.fileVariable:
                dir.appendingPathComponent("empty.json").path])
            let emptyCard = CaptureInboxCard(store: emptyStore)
            emptyCard.render(now: now, theme: ThemeManager.shared.theme)
            guard emptyCard.debugRowTitles.isEmpty,
                  emptyCard.debugEmptyText?.contains("Nothing captured today") == true else {
                return "an empty day does not say so: \(String(describing: emptyCard.debugEmptyText))"
            }

            // The page hosts it. A source guard, because standing up the
            // Today page's own stores here would duplicate
            // `DailyReviewViewSelfTest`'s whole harness for one question.
            guard let sources = SelfTestSources.appSourceFiles(),
                  let page = sources.first(where: { $0.lastPathComponent == "DailyOverviewController.swift" }),
                  let text = try? String(contentsOf: page, encoding: .utf8),
                  codeOnly(text).contains("CaptureInboxCard()") else {
                return "the Today page does not host the capture log, so there is still nowhere "
                     + "showing everything captured today (review X6)"
            }
            // And the shell records into it from the one filer every capture
            // entry point goes through.
            guard let shell = sources.first(where: { $0.lastPathComponent == "AppShellController.swift" }),
                  let shellText = try? String(contentsOf: shell, encoding: .utf8),
                  codeOnly(shellText).contains("CaptureInboxStore.shared.record(") else {
                return "nothing records a capture, so the log is always empty (review X6)"
            }
            return nil
        }
    }

    // MARK: X2 - four status items for one app

    private static func test_x2OneStatusItem() -> String? {
        // A stated policy rather than the live one: `AppSettings.shared`
        // belongs to this process and a case that wrote it would be changing
        // what every other case in this run reads.
        func policy(compactMode: Bool, separate: Bool) -> CompactModePolicy {
            CompactModePolicy(isEnabled: compactMode, hidesDockIcon: false,
                              badgesOverdueCount: false, separateMenuBarItems: separate)
        }

        // The default a fresh install gets. `UserDefaults.bool(forKey:)`
        // answers false for a key nobody has written, and the setting is
        // stored inverted precisely so that false is the shipped default -
        // so this is what the menu bar looks like out of the box.
        let fresh = policy(compactMode: false, separate: false)
        guard fresh.showsCompactStatusItem, !fresh.showsPerFeatureStatusItems else {
            return "a fresh install shows merged=\(fresh.showsCompactStatusItem), "
                 + "per-feature=\(fresh.showsPerFeatureStatusItems) - the review found three icons "
                 + "in the menu bar for one app (review X2)"
        }

        // The way back the review asked for.
        let separate = policy(compactMode: false, separate: true)
        guard separate.showsPerFeatureStatusItems, !separate.showsCompactStatusItem else {
            return "the Settings switch does not bring the three separate icons back: "
                 + "merged=\(separate.showsCompactStatusItem), "
                 + "per-feature=\(separate.showsPerFeatureStatusItems)"
        }

        // **Never both**, in any combination - three items plus a fourth
        // containing all three is the state F22's mockup rules out, and it
        // has to be unreachable rather than merely not chosen.
        for compact in [true, false] {
            for wantsSeparate in [true, false] {
                let p = policy(compactMode: compact, separate: wantsSeparate)
                if p.showsCompactStatusItem && p.showsPerFeatureStatusItems {
                    return "compactMode=\(compact) separate=\(wantsSeparate) puts the merged item "
                         + "and the three per-feature ones in the menu bar at once"
                }
                if !p.showsCompactStatusItem && !p.showsPerFeatureStatusItems {
                    return "compactMode=\(compact) separate=\(wantsSeparate) leaves no menu-bar "
                         + "item at all"
                }
            }
        }

        // Compact mode wins: with the window hidden the merged item is the
        // only surface there is, so the switch must not be able to take it
        // away.
        let compactAndSeparate = policy(compactMode: true, separate: true)
        guard compactAndSeparate.showsCompactStatusItem else {
            return "compact mode with the separate-icons switch on leaves no merged item, and the "
                 + "main window is hidden - that is a windowless app with no way in"
        }

        // The tabs really are the per-feature surfaces, which is what makes
        // the merge a merge rather than a removal. `CompactModePopover`'s own
        // header records that Vault and Crew host those controllers
        // themselves; this pins the tab set.
        let tabs = Set(CompactModeTab.allCases.map(\.title))
        guard tabs.isSuperset(of: ["Vault", "Crew", "Today"]) else {
            return "the merged item's tabs do not cover the features whose own icons it replaces: "
                 + "\(CompactModeTab.allCases.map(\.title))"
        }

        // The Settings row the review asked for: "a Settings row to re-add
        // individual icons for anyone who wants them back". Driven against
        // the real page, because a switch that exists in `AppSettings` and
        // nowhere in the UI is not a way back.
        let rowFound: Bool = autoreleasepool {
            let settings = SettingsController(hostStore: HostStore(), keyStore: SSHKeyStore(),
                                              snippetStore: SnippetStore(),
                                              dictationStore: DictationStore())
            settings.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
            settings.view.layoutSubtreeIfNeeded()
            // Settings mounts one category's cards at a time (gotcha (15)),
            // so the row is asked for on its own page rather than by walking
            // whatever page happens to be selected.
            return settings.debugGroupCards(in: .menuBar)
                .flatMap { descendants(of: $0) }
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains { $0.localizedCaseInsensitiveContains("Separate icons for Tasks") }
        }
        guard rowFound else {
            return "Settings offers no way back to the separate menu-bar icons (review X2)"
        }

        // And the three controllers do not show themselves at construction -
        // otherwise every ordinary launch flashes three icons before
        // `refresh()` hides them. A source guard: an `NSStatusItem`'s real
        // visibility needs a real menu bar.
        guard let files = SelfTestSources.appSourceFiles() else {
            return "SKIP-AS-FAILURE: the app's sources are not next to this binary"
        }
        for name in ["ShiftMenuBar.swift", "StrawHatMenuBar.swift", "PoneglyphMenuBar.swift"] {
            guard let file = files.first(where: { $0.lastPathComponent == name }),
                  let text = try? String(contentsOf: file, encoding: .utf8) else {
                return "could not read \(name)"
            }
            guard codeOnly(text).contains("statusItem.isVisible = false") else {
                return "\(name) shows its status item from construction, so an ordinary launch "
                     + "flashes it before the merged item's policy hides it (review X2)"
            }
        }
        return nil
    }
    // MARK: X8 - one bulk control on Updates, and it says what it does

    /// X8 (review UX): "a single Check all plus per-row actions only when
    /// something is available".
    ///
    /// The second half is U10's, asserted in `test_u10CheckButton` above and
    /// deliberately not re-asserted here. What is left is the first: on a page
    /// where most rows correctly offer nothing at all, the one bulk control
    /// has to say what it does on its face. "Refresh" named the gesture
    /// rather than the work, and the only thing that said otherwise was a
    /// tooltip nobody hovers when every row already looks settled.
    private static func test_x8CheckAllIsNamedAfterTheWork() -> String? {
        autoreleasepool { () -> String? in
            let controller = UpdatesController()
            controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
            controller.view.layoutSubtreeIfNeeded()

            guard controller.debugCheckAllTitle == "Check all" else {
                return "the page's bulk control reads \"\(controller.debugCheckAllTitle)\" - X8 asks "
                     + "for \"Check all\", because it is the only thing on a settled page that does "
                     + "anything"
            }
            guard controller.debugCheckAllIsVisible else {
                return "the bulk control is hidden on a freshly built page"
            }

            // The state X8 is actually about: everything up to date, every
            // row correctly actionless, and this one control left. Without
            // this the label check above would pass on a page that still
            // invited thirteen clicks.
            let rowCount = controller.debugRowActionStates.count
            guard rowCount > 5 else {
                return "the page rendered \(rowCount) rows - this case could not tell a settled page "
                     + "from an empty one"
            }
            for index in 0 ..< rowCount { controller.debugSetStatus(.upToDate, atRow: index) }
            let settled = controller.debugRowActionStates
            guard settled.allSatisfy({ $0.checkHidden && $0.updateHidden }) else {
                return "a settled page still offers per-row actions, so \"Check all\" is not the "
                     + "single affordance X8 asks for"
            }
            guard controller.debugCheckAllIsVisible else {
                return "a settled page has no action at all - X8 asks for one, not none"
            }
            return nil
        }
    }

}

#endif
