// Manjesh Grand Line - native macOS app.
//
// Coverage for the Run History fix: each run's status is now unambiguous
// (succeeded / failed / needs attention, not just the shared "Clean"/"Needs
// you"/"Failed" kicker vocabulary), and its real output is persisted and
// viewable from the sheet. Run with:
//
//   swift build && FM_RUN_SCHEDULE_RUN_HISTORY_STATUS_LOG_TESTS=1 .build/debug/FirstmateCockpit; echo $?
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
            ("outcomeChipText_isUnambiguousAndDistinctFromTheSharedLabel", test_outcomeChipText),
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
    /// able to answer "did this succeed?" without knowing that `.changed`'s
    /// kicker ("Needs you") is itself a success. And it must not be the
    /// *same* vocabulary `SchedulesCardView`'s row already renders on the
    /// main Schedules list - this file's own "no regression to existing
    /// Schedules list behavior" bar depends on `.label` staying untouched.
    private static func test_outcomeChipText() -> String? {
        let expected: [(ScheduleRunVerdict, String)] = [
            (.clean, "Succeeded"),
            (.changed, "Needs Attention"),
            (.failed, "Failed"),
        ]
        for (verdict, want) in expected {
            guard verdict.outcomeChipText == want else {
                return "\(verdict) chip text was \(verdict.outcomeChipText.debugDescription), expected \(want.debugDescription)"
            }
        }
        // The shared main-list vocabulary must be untouched by this addition.
        let sharedLabels: [ScheduleRunVerdict: String] = [.clean: "Clean", .changed: "Needs you", .failed: "Failed"]
        for (verdict, label) in sharedLabels {
            guard verdict.label == label else {
                return "\(verdict).label changed to \(verdict.label.debugDescription) - this is the exact vocabulary SchedulesCardView's row already renders on the main Schedules list"
            }
        }
        // `.clean`/`.changed` genuinely need the second, blunter chip word -
        // their kicker alone does not answer "did this succeed?". `.failed`
        // is the one verdict where "Failed" is already unambiguous, so its
        // chip and kicker legitimately share the same word - that is not a
        // regression, only `.clean`/`.changed` would be.
        guard ScheduleRunVerdict.clean.outcomeChipText != ScheduleRunVerdict.clean.label else {
            return "clean's chip text is still just its kicker word - it does not answer 'did this succeed?' on its own"
        }
        guard ScheduleRunVerdict.changed.outcomeChipText != ScheduleRunVerdict.changed.label else {
            return "changed's chip text is still just its kicker word ('Needs you') - a captain still has to know that means success"
        }
        return nil
    }

    // MARK: Log capture (pure logic)

    /// An action with nothing deeper to say (the early-return failure guards
    /// in `ScheduleActions.vaultRecipeExport`/`.configBackupExport`, for
    /// example) must still leave "View Log" with something real to show,
    /// never a blank pane.
    private static func test_logDefaultsToSummary() -> String? {
        let result = ScheduleActionResult(verdict: .failed, summary: "No local manjesh-config clone found.")
        guard result.log == result.summary else {
            return "log defaulted to \(result.log.debugDescription), expected it to fall back to the summary (\(result.summary.debugDescription))"
        }
        let withLog = ScheduleActionResult(verdict: .changed, summary: "short summary", log: "a real, longer transcript")
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = sheet.view
        sheet.view.layoutSubtreeIfNeeded()
        return (sheet, window)
    }

    /// The chip states the plain succeeded/failed/needs-attention answer;
    /// the kicker keeps rendering the shared "Clean"/"Needs you"/"Failed"
    /// vocabulary unchanged, so the two are never confused for one signal.
    private static func test_rowsShowChipAndKicker() -> String? {
        let (sheet, window) = mountSheetWithEntries([
            (.clean, "All good.", nil),
            (.changed, "3 tools have an update available.", nil),
            (.failed, "network unreachable.", nil),
        ])
        defer { window.contentView = nil }
        let expectedChip = ["Succeeded", "Needs Attention", "Failed"]
        // `HelmAccentRow` renders the kicker uppercase (see its own doc
        // comment) - the underlying string this test must not see change is
        // still `ScheduleRunVerdict.label`, just as it is actually painted.
        let expectedKicker = ["Clean", "Needs you", "Failed"].map { $0.uppercased() }
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
            log: "repo-a: some real detail\nrepo-b: another line")

        let controller = ScheduleRunLogController(entry: entry)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }

        guard controller.debugTitle == "Run Log" else {
            return "expected the title 'Run Log', got \(controller.debugTitle.debugDescription)"
        }
        guard controller.debugSubtitle.contains(schedule.action.title), controller.debugSubtitle.contains(entry.verdict.label) else {
            return "the subtitle did not name the action/verdict, got \(controller.debugSubtitle.debugDescription)"
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
