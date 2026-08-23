// Manjesh Grand Line - native macOS app.
//
// Permanent, env-gated self-test for F6 (fleet history / captain's log) - run
// via `FM_RUN_FLEET_LOG_TESTS=1 .build/debug/FirstmateCockpit`, same
// convention as every other suite here.
//
// What it pins, and why each one is worth a test rather than a reading of the
// code:
//
//  - **Append + reload from disk.** The store keeps an in-memory cache, so a
//    check that only reads `events()` back would pass even if nothing were
//    ever written. Every append case here drops the cache
//    (`debugForgetCache`) and re-reads the real file.
//  - **The JSONL shape.** "Append-only JSONL" is the spec's own instruction
//    and the reason the steady-state write is a seek-to-end rather than a
//    rewrite. A pretty-printing encoder would silently break the format while
//    every in-process read still passed, so the file's own bytes are checked.
//  - **The retention cap.** The one thing that cannot be observed from the UI
//    at any realistic event rate, and the one whose absence is unbounded
//    growth on the captain's disk.
//  - **The kind filter.** The mockup's filter row is the tab's only control.
//  - **Day grouping and the security sanitiser**, both pure functions with
//    exact expected outputs.
//  - **The Shift merge**, against a real `ShiftStore` on a scratch directory:
//    the task half of the feed comes from Shift's activity YAML rather than a
//    second copy (see `FleetLogFeed`'s header), so "a real task completion
//    shows up in the log" is a property of that merge, not of any write this
//    feature performs.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum FleetLogSelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-log-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // MARK: Append + reload from disk

        let logDir = scratch.appendingPathComponent("log", isDirectory: true)
        let store = FleetLogStore(directory: logDir)
        check(store.events().isEmpty, "a fresh store should have no events")

        store.append(FleetLogSources.merged(prNumber: 412, prTitle: "Fix checkout-api retry loop",
                                            repo: "checkout-api", url: "https://example.invalid/pr/412"))
        store.append(FleetLogSources.syncConflictResolved(recordKind: "task", recordTitle: "Rotate creds",
                                                          recordID: "task-129", keptLocal: true))
        store.append(FleetLogSources.investigationSaved(title: "payments-worker OOMKilled", id: "inv-1"))

        store.debugForgetCache()
        let reread = store.events()
        check(reread.count == 3, "expected 3 events read back from disk, got \(reread.count)")
        // `events()` is newest-first, and these were appended in order.
        check(reread.first?.kind == .investigation, "events() should return newest first")
        check(reread.last?.kind == .merge, "events() should return oldest last")
        check(reread.contains { $0.title.contains("Merged PR #412") && $0.title.contains("checkout-api") },
              "the merge event should name the PR and its repo")
        check(reread.contains { $0.title.contains("kept this machine's edit") },
              "a keepLocal resolution should say the local side won")
        check(reread.first?.reference == "inv-1", "an investigation event should carry its id as the reference")

        // MARK: The on-disk shape really is JSONL

        let raw = (try? String(contentsOf: store.debugFileURL, encoding: .utf8)) ?? ""
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        check(lines.count == 3, "the file should hold one line per event, got \(lines.count)")
        check(lines.allSatisfy { $0.hasPrefix("{") && $0.hasSuffix("}") },
              "every line should be one complete JSON object")

        // A line that will not decode costs itself, never the whole file.
        let withGarbage = raw + "not json at all\n"
        check(FleetLogStore.decodeLines(withGarbage).count == 3,
              "a malformed line should be skipped, not fail the whole read")

        // MARK: Retention cap

        let cappedDir = scratch.appendingPathComponent("capped", isDirectory: true)
        let capped = FleetLogStore(directory: cappedDir)
        let overflow = FleetLogStore.maxEvents + FleetLogStore.trimSlack + 5
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<overflow {
            capped.append(FleetLogEvent(date: base.addingTimeInterval(Double(i)), kind: .task,
                                        title: "event \(i)", reference: "e\(i)"))
        }
        capped.debugForgetCache()
        let kept = capped.events()
        check(kept.count <= FleetLogStore.maxEvents + FleetLogStore.trimSlack,
              "the log must never exceed its cap plus slack, got \(kept.count)")
        check(kept.count >= FleetLogStore.maxEvents,
              "trimming should keep the cap's worth of history, got \(kept.count)")
        // Oldest go first, newest survive - a cap that dropped the newest
        // would leave the feed permanently stale rather than merely bounded.
        check(kept.first?.title == "event \(overflow - 1)",
              "the newest event must survive trimming, got \(kept.first?.title ?? "none")")
        check(!kept.contains { $0.title == "event 0" }, "the oldest event should have been trimmed away")
        let cappedLines = ((try? String(contentsOf: capped.debugFileURL, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).count
        check(cappedLines == kept.count, "the file's line count should match what the store reports")

        // MARK: Kind filter (the mockup's pill row)

        let mixed: [FleetLogEvent] = [
            FleetLogEvent(date: base, kind: .merge, title: "m"),
            FleetLogEvent(date: base, kind: .task, title: "t1"),
            FleetLogEvent(date: base, kind: .task, title: "t2"),
            FleetLogEvent(date: base, kind: .sync, title: "s"),
            FleetLogEvent(date: base, kind: .investigation, title: "i"),
        ]
        check(FleetLogFeed.filtered(mixed, kind: nil).count == 5, "the All pill should filter nothing")
        check(FleetLogFeed.filtered(mixed, kind: .task).count == 2, "the Tasks pill should keep only task events")
        check(FleetLogFeed.filtered(mixed, kind: .merge).map(\.title) == ["m"], "the Merges pill should keep only merges")
        check(FleetLogListView.kind(forFilterID: FleetLogListView.allFilterID) == nil,
              "the All pill's id maps to no kind")
        check(FleetLogListView.kind(forFilterID: "sync") == .sync, "each kind's raw value is its own pill id")
        check(FleetLogListView.filterItems.count == FleetLogEventKind.allCases.count + 1,
              "the pill row should be All plus one pill per kind")

        // MARK: Day grouping

        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let older = cal.date(byAdding: .day, value: -9, to: now)!
        check(FleetLogFeed.dayLabel(for: now, reference: now, calendar: cal) == "Today", "today should say Today")
        check(FleetLogFeed.dayLabel(for: yesterday, reference: now, calendar: cal) == "Yesterday",
              "yesterday should say Yesterday")
        let olderLabel = FleetLogFeed.dayLabel(for: older, reference: now, calendar: cal)
        check(olderLabel != "Today" && olderLabel != "Yesterday" && !olderLabel.isEmpty,
              "anything older should get an absolute date, got \(olderLabel)")

        let grouped = FleetLogFeed.rows(for: [
            FleetLogEvent(date: now, kind: .merge, title: "a"),
            FleetLogEvent(date: now.addingTimeInterval(-60), kind: .task, title: "b"),
            FleetLogEvent(date: yesterday, kind: .sync, title: "c"),
            FleetLogEvent(date: older, kind: .task, title: "d"),
        ], reference: now, calendar: cal)
        // One header per distinct day, never one per event.
        let headers = grouped.compactMap { row -> String? in
            if case .header(let text) = row { return text } else { return nil }
        }
        check(headers == ["Today", "Yesterday", olderLabel], "expected one header per day, got \(headers)")
        check(grouped.count == 7, "3 headers + 4 events = 7 rows, got \(grouped.count)")
        if case .header = grouped.first {} else { check(false, "the feed should open with a day header") }

        // MARK: The security sanitiser (F6's own constraint)

        let multiline = FleetLogEvent(kind: .task, title: "line one\nline two\r\nline three")
        check(!multiline.title.contains("\n") && !multiline.title.contains("\r"),
              "an event title must never carry a newline - it is a one-line record, not log content")
        let huge = FleetLogEvent(kind: .task, title: String(repeating: "x", count: 5_000))
        check(huge.title.count <= FleetLogEvent.maxTitleLength,
              "an event title must be bounded, got \(huge.title.count)")

        // MARK: The Shift merge - a real task completion reaching the feed

        let shiftRoot = scratch.appendingPathComponent("shift", isDirectory: true)
        setenv("FM_SHIFT_DIR", shiftRoot.path, 1)
        defer { unsetenv("FM_SHIFT_DIR") }
        let shift = ShiftStore()
        let task = ShiftTask(
            id: "task-901", title: "Rotate staging DB creds", description: "",
            status: .todo, priority: .normal, dueDate: nil, dueTime: nil, projectID: nil,
            tags: [], createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            completedAt: nil, notes: nil, subtasks: [], hasAttachment: false
        )
        shift.addTask(task)
        shift.setTaskCompleted(id: task.id, completed: true)

        let feedStore = FleetLogStore(directory: scratch.appendingPathComponent("feed", isDirectory: true))
        feedStore.append(FleetLogSources.merged(prNumber: 7, prTitle: "Bump deps", repo: "infra",
                                                url: "https://example.invalid/pr/7"))
        let feed = FleetLogFeed.events(store: feedStore, shift: shift)
        check(feed.contains { $0.kind == .task && $0.title.contains("Rotate staging DB creds") },
              "a real Shift task completion should appear in the feed")
        check(feed.contains { $0.kind == .merge && $0.title.contains("PR #7") },
              "a merge appended to the store should appear in the same feed")
        check(feed.first(where: { $0.kind == .task })?.reference == task.id,
              "a task event should carry the task id as its reference")
        // Nothing about the task half is written into the JSONL file - that is
        // the whole point of reading Shift's activity YAML instead.
        feedStore.debugForgetCache()
        check(feedStore.events().allSatisfy { $0.kind != .task },
              "task events must not be duplicated into the fleet log file")
        // Newest-first across both sources, not just within each one.
        check(zip(feed, feed.dropFirst()).allSatisfy { $0.date >= $1.date },
              "the merged feed must be sorted newest-first")

        // An activity entry with an unparseable timestamp is dropped rather
        // than dated "now", which would float it to the top of the feed.
        check(FleetLogFeed.taskEvent(from: ShiftActivityEntry(
            id: "x", timestamp: "not a date", kind: "task_completed", summary: "s", targetID: nil)) == nil,
              "an undated activity entry should be dropped, not dated now")

        if failures.isEmpty {
            print("FleetLogSelfTest: all checks passed")
            return true
        }
        print("FleetLogSelfTest: FAILED")
        for f in failures { print("  - \(f)") }
        return false
    }
}

#endif
