// Grand Line - native macOS app.
//
// Coverage for the Run History fix: each run's status is now unambiguous
// (succeeded / failed / needs attention, not just the shared "Clean"/"Needs
// you"/"Failed" kicker vocabulary), and its real output is persisted and
// viewable from the sheet. Run with:
//
//   swift build && FM_RUN_SCHEDULE_RUN_HISTORY_STATUS_LOG_TESTS=1 .build/debug/GrandLine; echo $?
//
// The bug this closes, reproduced first before any code changed: opening
// "View History..." on a schedule showed a row per run with only a kicker
// like "Needs you" (which is itself a *success* - see `ScheduleRunVerdict
// .changed`'s own doc comment - but reads as ambiguous at a glance) and a
// one-line summary, with no way to see the run's real output. `ScheduleAction
// Result` already had access to real command output (`CheckOutcome.log` /
// `GitHubSyncCheckOutcome.log` / `GitHubSyncSyncOutcome.log`, all captured
// from real `Subprocess` calls for the Updates/GitHub-Sync pages' own
// session-only expandable logs) - it just never carried it out to the
// persisted `ScheduleRunHistoryEntry`.
//
// Pure-logic cases need no window; the last three mount real
// `ScheduleHistoryController`/`ScheduleRunLogController` instances (the same
// `mountSheet()`-style harness `AppKitAuditSelfTest`'s M5/M6 cases use), so
// this sits in `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list.

#if FM_SELFTESTS

import AppKit

enum ScheduleRunHistoryStatusAndLogSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("outcomeChipText_isUnambiguousAndNoSuccessReadsAsAnAlarm", test_outcomeChipText),
            ("oldChangedVerdictStillDecodesToFoundSomething", test_oldChangedVerdictStillDecodes),
            ("scheduleActionResult_logDefaultsToSummaryWhenNotGiven", test_logDefaultsToSummary),
            ("historyEntry_logPersistsAcrossARealDiskReload", test_logPersists),
            ("historyEntry_logIsTruncatedAtAGenerousBound", test_logTruncation),
            ("historyEntry_anOldOnDiskLineWithNoLogKeyStillDecodes", test_oldFormatTolerance),
            ("historySheet_rowsShowTheChipAlongsideTheUnchangedKicker", test_rowsShowChipAndKicker),
            ("historySheet_viewLogResolvesToTheClickedRunsOwnEntry", test_viewLogResolvesCorrectEntry),
            ("runLogController_rendersTheRunsRealOutputAndCopiesIt", test_runLogControllerRendersAndCopies),
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
              ? "ScheduleRunHistoryStatusAndLogSelfTest: all \(cases.count) cases passed"
              : "ScheduleRunHistoryStatusAndLogSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Status clarity (pure logic)

    /// The whole point of this fix: a captain scanning Run History has to be
    /// able to answer "did this succeed?" at a glance.
    ///
    /// **This case used to pin `.label` to "Clean"/"Needs you"/"Failed" and
    /// fail the build on any change**, on the stated grounds that it was
    /// "the exact vocabulary SchedulesCardView's row already renders on the
    /// main Schedules list". `fm/grandline-schedule-status-clarity`
    /// deliberately overturns that, and the reason the guard is *replaced*
    /// rather than deleted is worth writing down: the rule was protecting
    /// **consistency between the two surfaces**, not those particular words.
    /// The captain reported that a successful run reading "Needs you" /
    /// "Needs Attention" told him nothing about what, if anything, he had to
    /// do - and that same task's own notes had already recorded the wording
    /// as ambiguous. So the vocabulary changed in both places at once, and
    /// what this case guards now is the property that actually matters: the
    /// two surfaces agree, and no *success* is labelled as if it were a
    /// problem.
    private static func test_outcomeChipText() -> String? {
        let expected: [(ScheduleRunVerdict, String)] = [
            (.clean, "Succeeded"),
            (.didWork, "Succeeded"),
            (.foundSomething, "Succeeded - found something"),
            (.partial, "Partly failed"),
            (.failed, "Failed"),
        ]
        for (verdict, want) in expected {
            guard verdict.outcomeChipText == want else {
                return "\(verdict) chip text was \(verdict.outcomeChipText.debugDescription), expected \(want.debugDescription)"
            }
        }
        let expectedLabels: [(ScheduleRunVerdict, String)] = [
            (.clean, "All clear"),
            (.didWork, "Done"),
            (.foundSomething, "Found something"),
            (.partial, "Couldn\u{2019}t check everything"),
            (.failed, "Didn\u{2019}t finish"),
        ]
        for (verdict, want) in expectedLabels {
            guard verdict.label == want else {
                return "\(verdict).label was \(verdict.label.debugDescription), expected \(want.debugDescription) - this is the vocabulary SchedulesCardView's row and this sheet both render, and they must not drift apart"
            }
        }
        // The property the old pin was really defending: a run that succeeded
        // must never be labelled with alarm words. This is what the captain
        // actually reported, so it is asserted directly rather than implied
        // by a list of strings.
        let alarmWords = ["needs you", "needs attention", "attention", "failed", "error", "problem"]
        for verdict in [ScheduleRunVerdict.clean, .didWork, .foundSomething] {
            let text = (verdict.label + " " + verdict.outcomeChipText).lowercased()
            for word in alarmWords where text.contains(word) {
                return "\(verdict) succeeded but its wording (\(verdict.label.debugDescription) / \(verdict.outcomeChipText.debugDescription)) contains the alarm word \(word.debugDescription)"
            }
        }
        // And the converse: a verdict that did NOT succeed must not read as a
        // clean success, which is the shape of the two logic defects this
        // change fixes.
        for verdict in [ScheduleRunVerdict.partial, .failed] {
            guard !verdict.succeeded, verdict.needsCaptain else {
                return "\(verdict) should both not-succeed and need the captain"
            }
            guard verdict.outcomeChipText.lowercased().contains("fail") else {
                return "\(verdict)'s chip (\(verdict.outcomeChipText.debugDescription)) does not say it failed"
            }
        }
        // `.foundSomething` is the one success allowed to ask for attention at
        // all, and its chip has to say more than a bare "Succeeded" or the
        // distinction the row exists to draw is lost.
        guard ScheduleRunVerdict.foundSomething.outcomeChipText != ScheduleRunVerdict.clean.outcomeChipText else {
            return "foundSomething's chip is identical to clean's - the sheet no longer distinguishes a run that found something"
        }
        return nil
    }

    /// GL-01: a run recorded before the five-state split carries the raw
    /// string `"changed"`, which is not a case any more. It must still
    /// decode, and it must land on `.foundSomething` - see
    /// `ScheduleRunVerdict.init(from:)` for why that is the safer of the two
    /// candidate meanings.
    private static func test_oldChangedVerdictStillDecodes() -> String? {
        // Assert the fixture's own discriminating power first: if `"changed"`
        // were somehow a live raw value again, this case would be vacuous.
        guard ScheduleRunVerdict(rawValue: "changed") == nil else {
            return "\"changed\" is a live raw value again - this check cannot fail and proves nothing"
        }
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(ScheduleRunVerdict.self, from: Data("\"changed\"".utf8)) else {
            return "an old on-disk \"changed\" verdict no longer decodes - every existing schedules.json and runs.jsonl is now unreadable"
        }
        guard decoded == .foundSomething else {
            return "an old \"changed\" decoded to \(decoded), expected .foundSomething"
        }
        // Every current case must still round-trip through its own raw value.
        for verdict in [ScheduleRunVerdict.clean, .didWork, .foundSomething, .partial, .failed] {
            let json = Data("\"\(verdict.rawValue)\"".utf8)
            guard let back = try? decoder.decode(ScheduleRunVerdict.self, from: json), back == verdict else {
                return "\(verdict) did not round-trip through its raw value"
            }
        }
        // And an genuinely unknown value must still be refused rather than
        // silently becoming some default.
        guard (try? decoder.decode(ScheduleRunVerdict.self, from: Data("\"nonsense\"".utf8))) == nil else {
            return "an unknown verdict string decoded instead of throwing"
        }
        return nil
    }

    // MARK: Log capture (pure logic)

    /// An action with nothing deeper to say (the early-return failure guards
    /// in `ScheduleActions.vaultRecipeExport`/`.configBackupExport`, for
    /// example) must still leave "View Log" with something real to show,
    /// never a blank pane.
    private static func test_logDefaultsToSummary() -> String? {
        // The failing initializer, which is the one an early-return guard
        // uses - it must still leave "View Log" something real to show.
        let result = ScheduleActionResult(failing: .failed,
                                          summary: "No local manjesh-config clone found.",
                                          whatFailed: "The vault recipe couldn\u{2019}t be exported.",
                                          why: "There is no local clone of manjesh-config on this Mac.",
                                          whatToDo: "Set up the dotfiles card in Bootstrap, then run it again.")
        guard result.log == result.summary else {
            return "log defaulted to \(result.log.debugDescription), expected it to fall back to the summary (\(result.summary.debugDescription))"
        }
        // And that initializer is the only way to build a failing result, so
        // a failure can never reach the sheet with nothing to explain it.
        guard result.failure != nil else {
            return "a failing result carried no explanation - the Run Report would have nothing to lead with"
        }
        guard ScheduleActionResult(verdict: .clean, summary: "fine").failure == nil else {
            return "a succeeding result carried a failure explanation"
        }
        let withLog = ScheduleActionResult(verdict: .foundSomething, summary: "short summary", log: "a real, longer transcript")
        guard withLog.log == "a real, longer transcript" else {
            return "an explicitly-provided log was overwritten by the summary fallback"
        }
        return nil
    }

    private static func scratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-run-history-log-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real disk round trip - a fresh store instance over the same
    /// directory, exactly `ScheduleRunnerSelfTest.checkRunHistoryPersistsAndFilters`'s
    /// own convention - proves the *file* carries the log, the property that
    /// actually matters for a rebuild/relaunch to still show it.
    private static func test_logPersists() -> String? {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scheduleID = UUID()
        let at = Date()

        let first = ScheduleRunHistoryStore(directory: dir)
        first.append(ScheduleRunHistoryEntry(
            scheduleID: scheduleID, at: at, verdict: .failed,
            summary: "2 forks failed.",
            actionTitle: "Fork sync",
            log: "repo-a: 502 from GitHub\nrepo-b: network unreachable"))

        let second = ScheduleRunHistoryStore(directory: dir)
        second.debugForgetCache()
        guard let reloaded = second.entries(for: scheduleID).first else {
            return "the appended entry did not come back from a fresh store instance over the same directory"
        }
        guard reloaded.log == "repo-a: 502 from GitHub\nrepo-b: network unreachable" else {
            return "the log did not survive a real disk reload, got \(reloaded.log.debugDescription)"
        }
        return nil
    }

    /// A run's real command output can run to tens of KB across a dozen tools
    /// - bounded so an unusually chatty run cannot make `runs.jsonl` grow
    /// without limit.
    private static func test_logTruncation() -> String? {
        let huge = String(repeating: "x", count: ScheduleRunHistoryEntry.maxLogLength + 5_000)
        let entry = ScheduleRunHistoryEntry(
            scheduleID: UUID(), at: Date(), verdict: .clean, summary: "ok", actionTitle: "Drift check", log: huge)
        guard let stored = entry.log else { return "a huge log was dropped to nil instead of truncated" }
        guard stored.count <= ScheduleRunHistoryEntry.maxLogLength + 100 else {
            return "a \(huge.count)-character log was not truncated - stored \(stored.count) characters"
        }
        guard stored.contains("truncated") else {
            return "a truncated log gives no indication that it was cut, which reads as the run's real output ending mid-sentence"
        }
        // A log under the bound must be left completely alone.
        let short = ScheduleRunHistoryEntry(
            scheduleID: UUID(), at: Date(), verdict: .clean, summary: "ok", actionTitle: "Drift check", log: "short and real")
        guard short.log == "short and real" else {
            return "a log well under the bound was altered: \(short.log.debugDescription)"
        }
        return nil
    }

    /// `Swift`'s synthesized `Decodable` treats a missing key on an
    /// `Optional` property as `nil` - the same tolerance `Host.init(from:)`
    /// and `AutomationSchedule.init(from:)` document for their own
    /// custom-decoded fields, here relied on directly since `log` needed no
    /// custom decoder at all. A real on-disk line an *old* build wrote (no
    /// `log` key) must still decode, or every pre-existing history file on a
    /// captain's machine would go unreadable the moment this build runs.
    private static func test_oldFormatTolerance() -> String? {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ScheduleRunHistoryStore(directory: dir)
        let scheduleID = UUID()

        // The exact shape a pre-this-fix build would have written - every
        // field this type carried before `log` existed, and nothing else.
        let oldLine: [String: Any] = [
            "id": UUID().uuidString,
            "scheduleID": scheduleID.uuidString,
            "at": ISO8601DateFormatter().string(from: Date()),
            "verdict": "clean",
            "summary": "Dotfiles clean, agent instructions linked.",
            "actionTitle": "Drift check",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: oldLine) else {
            return "could not build the old-format fixture line"
        }
        var line = String(data: data, encoding: .utf8) ?? ""
        line += "\n"
        do {
            try line.write(to: store.debugFileURL, atomically: true, encoding: .utf8)
        } catch {
            return "could not write the old-format fixture file: \(error.localizedDescription)"
        }

        let reader = ScheduleRunHistoryStore(directory: dir)
        let entries = reader.entries(for: scheduleID)
        guard entries.count == 1 else {
            return "an old-format line with no log key failed to decode at all - got \(entries.count) entries"
        }
        guard entries[0].log == nil else {
            return "an old-format line invented a log value out of nothing: \(entries[0].log.debugDescription)"
        }
        guard entries[0].summary == "Dotfiles clean, agent instructions linked." else {
            return "every other field on the old-format line should still decode correctly"
        }
        return nil
    }

    // MARK: The sheet (window-backed)

    /// A real store seeded with one entry per verdict, and the real
    /// `ScheduleHistoryController` mounted against it - `AppKitAuditSelfTest
    /// .mountSheet()`'s own shape, extended to carry real, distinct rows.
    private static func mountSheetWithEntries(
        _ entries: [(verdict: ScheduleRunVerdict, summary: String, log: String?)]
    ) -> (sheet: ScheduleHistoryController, window: NSWindow) {
        let schedule = AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 9, minute: 0))
        let store = ScheduleRunHistoryStore(directory: scratchDir())
        let now = Date()
        // Oldest-appended-first on disk, but `entries(for:)` reads back
        // newest-first - descending timestamps here so the row order this
        // test asserts against matches the order the sheet actually shows.
        for (index, entry) in entries.enumerated() {
            store.append(ScheduleRunHistoryEntry(
                scheduleID: schedule.id,
                at: now.addingTimeInterval(TimeInterval(-index * 60)),
                verdict: entry.verdict,
                summary: entry.summary,
                actionTitle: schedule.action.title,
                log: entry.log))
        }
        let sheet = ScheduleHistoryController(schedule: schedule, historyStore: store)
        let window = OffScreenProbe.window(width: 460, height: 480)
        window.contentView = sheet.view
        sheet.view.layoutSubtreeIfNeeded()
        return (sheet, window)
    }

    /// The chip states the plain succeeded/failed/needs-attention answer;
    /// the kicker renders `ScheduleRunVerdict.label`, the same vocabulary
    /// `SchedulesCardView`'s own row uses on the main Schedules list, so the
    /// two surfaces never drift into two different words for one state.
    private static func test_rowsShowChipAndKicker() -> String? {
        let (sheet, window) = mountSheetWithEntries([
            (.clean, "All good.", nil),
            (.foundSomething, "3 tools have an update available.", nil),
            (.failed, "network unreachable.", nil),
        ])
        defer { window.contentView = nil }
        let expectedChip = ["Succeeded", "Succeeded - found something", "Failed"]
        // `HelmAccentRow` renders the kicker uppercase (see its own doc
        // comment), so this asserts `ScheduleRunVerdict.label` exactly as it
        // is actually painted.
        let expectedKicker = ["All clear", "Found something", "Didn\u{2019}t finish"].map { $0.uppercased() }
        for row in 0..<3 {
            guard let rowView = sheet.debugRowView(at: row) as? HelmAccentRow else {
                return "row \(row) did not produce a HelmAccentRow"
            }
            guard rowView.debugChipText == expectedChip[row] else {
                return "row \(row) chip read \(rowView.debugChipText.debugDescription), expected \(expectedChip[row].debugDescription)"
            }
            guard rowView.debugKickerText == expectedKicker[row] else {
                return "row \(row) kicker read \(rowView.debugKickerText.debugDescription), expected \(expectedKicker[row].debugDescription) - the shared main-list vocabulary must not change"
            }
        }
        return nil
    }

    /// Rows are dequeued/reused as an `NSTableView` scrolls, and
    /// `HelmAccentRow.trailingAccessory` is fixed at `init` - so the "View
    /// Log" button has to be re-pointed at whichever entry a row is
    /// *currently* showing on every `viewFor:row:` call. A stale button
    /// would open the wrong run's log.
    private static func test_viewLogResolvesCorrectEntry() -> String? {
        let (sheet, window) = mountSheetWithEntries([
            (.clean, "All good.", "clean-run-log-body"),
            (.failed, "network unreachable.", "failed-run-log-body"),
        ])
        defer { window.contentView = nil }
        var observed: [String] = []
        sheet.debugOnPresentLog = { entry in observed.append(entry.log ?? "<nil>") }
        for row in 0..<2 {
            guard let rowView = sheet.debugRowView(at: row) as? HelmAccentRow else {
                return "row \(row) did not produce a HelmAccentRow"
            }
            rowView.debugClickTrailingAccessory()
        }
        guard observed == ["clean-run-log-body", "failed-run-log-body"] else {
            return "View Log clicks resolved to \(observed), expected each row's own entry's log"
        }
        return nil
    }

    /// The log body shows the run's real output (never a placeholder), Copy
    /// Log reaches the pasteboard with that same text, and this sheet keeps
    /// the M5/M6 footer contract every sibling sheet in this app already
    /// carries (`ScheduleHistoryController`'s own doc comments on why).
    private static func test_runLogControllerRendersAndCopies() -> String? {
        let schedule = AutomationSchedule(action: .forkSync, cadence: .daily(hour: 11, minute: 0))
        let entry = ScheduleRunHistoryEntry(
            scheduleID: schedule.id, at: Date(timeIntervalSince1970: 1_700_000_000), verdict: .failed,
            summary: "2 forks failed.", actionTitle: schedule.action.title,
            log: "repo-a: some real detail\nrepo-b: another line",
            failure: ScheduleFailureExplanation(
                whatFailed: "2 of your 8 forks couldn\u{2019}t be brought up to date.",
                why: "GitHub refused the fast-forward for repo-a and repo-b.",
                whatToDo: "Open GitHub Sync and try those two by hand. Nothing was force-pushed."))

        let controller = ScheduleRunLogController(entry: entry)
        let window = OffScreenProbe.window(width: 560, height: 460)
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }

        // **The sheet leads with a sentence, not with raw output.** This is
        // the captain's own report turned into an assertion: the headline has
        // to be the plain-English "what failed", and the raw log has to be
        // out of the way until asked for.
        guard controller.debugHeadline == "2 of your 8 forks couldn\u{2019}t be brought up to date." else {
            return "the sheet did not lead with the plain-English headline, got \(controller.debugHeadline.debugDescription)"
        }
        guard controller.debugSubtitle.contains(schedule.action.title), controller.debugSubtitle.contains(entry.verdict.label) else {
            return "the subtitle did not name the action/verdict, got \(controller.debugSubtitle.debugDescription)"
        }
        let fields = controller.debugExplainFields
        guard fields.map(\.caption) == ["What failed", "Why", "What to do"] else {
            return "a failure must explain all three of what/why/what-to-do, got \(fields.map(\.caption))"
        }
        guard fields[2].body.contains("GitHub Sync") else {
            return "the 'what to do' field did not carry the run's own advice, got \(fields[2].body.debugDescription)"
        }
        // The raw log is kept verbatim and is still reachable - collapsed,
        // with its own size stated so it never reads as an empty section.
        guard controller.debugRawIsVisible == false else {
            return "the raw log was expanded by default - the sheet is leading with output again"
        }
        guard controller.debugRawToggleTitle.contains("2 lines") else {
            return "the disclosure must state the log's size, got \(controller.debugRawToggleTitle.debugDescription)"
        }
        controller.debugToggleRaw()
        guard controller.debugRawIsVisible else {
            return "the disclosure did not reveal the raw log"
        }
        guard controller.debugLogText == entry.log else {
            return "the log body did not show the run's real output, got \(controller.debugLogText.debugDescription)"
        }

        // Copy Log: verified through the real pasteboard, restoring whatever
        // was already there so this test does not clobber the machine's own
        // clipboard.
        let pasteboard = NSPasteboard.general
        let priorItems = pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) }
        defer {
            pasteboard.clearContents()
            if let prior = priorItems?.first { pasteboard.setString(prior, forType: .string) }
        }
        controller.debugCopyClicked()
        guard pasteboard.string(forType: .string) == entry.log else {
            return "Copy Log did not place the run's real output on the pasteboard"
        }
        // Copy Report is the other half, and it must carry the explanation
        // rather than the transcript - the two answer different questions.
        controller.debugCopyReportClicked()
        let report = pasteboard.string(forType: .string) ?? ""
        guard report.contains("What to do"), report.contains("GitHub Sync") else {
            return "Copy Report did not place the plain-English report on the pasteboard, got \(report.debugDescription)"
        }
        guard !report.contains("repo-a: some real detail") else {
            return "Copy Report dragged the raw transcript along with it"
        }

        guard let frames = controller.debugFooterFrames, frames.close.width < 200 else {
            return "the Close button is absorbing the row's slack instead of the spacer (gotchas 10/12) - it resolved to \(controller.debugFooterFrames?.close.width ?? -1)pt"
        }
        let before = controller.debugCloseRequests
        controller.cancelOperation(nil)
        guard controller.debugCloseRequests == before + 1 else {
            return "Escape did not reach this sheet's own close action - a keyboard user is stuck tabbing to Close"
        }
        return nil
    }
}

#endif
