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
}

#endif
