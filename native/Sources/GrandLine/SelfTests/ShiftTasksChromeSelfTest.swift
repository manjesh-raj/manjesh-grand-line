// Grand Line - native macOS app.
//
// The UI/UX revamp's Tasks chrome (plan step 7), the pure half: what the
// sync status says for every state, which failures read as offline, and the
// toolbar's sort orders. The page-level half (one switcher, no stat tiles,
// no chip row, counts following the filter) is `ShiftTasksPageSelfTest`.
//
// Run with `FM_RUN_SHIFT_TASKS_CHROME_TESTS=1 .build/debug/GrandLine`.
//
// Pure logic - no window. Deliberately NOT in `NEEDS_SESSION`.
//
// What it covers:
//
//   1. **UI-19's sync mapping.** "Synced" is the one default state and the
//      only dot-and-word; every other state is a pill in a `HelmTint`; a
//      network failure is "Offline · working locally" in a neutral pill, and
//      only a real failure is red.
//   2. **Offline detection** on the remote errors `ShiftGitSync` actually
//      reports, with the discriminating half: a repository error is not
//      offline.
//   3. **The sort orders** the toolbar offers, each on a fixture where the
//      three orders genuinely disagree.
//   4. **`ShiftTaskSignals`, the one priority and due rule (UI-23, UI-24,
//      UI-32):** only High earns a pill, Low is a word, Normal says nothing;
//      a due date is red when late, amber today, muted otherwise.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum ShiftTasksChromeSelfTest {

    static func run() -> Bool {
        var ok = true
        print("== ShiftTasksChromeSelfTest ==")
        checkSyncMapping(&ok)
        checkOfflineDetection(&ok)
        checkSortOrders(&ok)
        checkTaskSignals(&ok)
        checkParseFailureLine(&ok)
        print(ok ? "ShiftTasksChromeSelfTest: OK" : "ShiftTasksChromeSelfTest: FAILED")
        return ok
    }

    // MARK: 1

    private static func checkSyncMapping(_ ok: inout Bool) {
        let synced = ShiftSyncPresentation.look(for: .synced)
        check(synced.style == .dotWord && synced.text == "Synced" && synced.tint == .good,
              "Synced should be a green dot and a word, got \(synced)", &ok)

        let others: [ShiftGitSync.Status] = [.localChanges, .syncing, .failed("git push failed: rejected"),
                                             .conflict(fileCount: 2)]
        for status in others {
            let look = ShiftSyncPresentation.look(for: status)
            check(look.style == .pill, "\(status) should be a pill, not a dot and a word", &ok)
        }
        check(ShiftSyncPresentation.look(for: .localChanges).tint == .warn, "local changes are amber", &ok)
        check(ShiftSyncPresentation.look(for: .conflict(fileCount: 2)).text == "Conflict \u{00B7} resolve",
              "a conflict says it can be resolved", &ok)

        let offline = ShiftSyncPresentation.look(for: .failed("fatal: unable to access 'https://x/': Could not resolve host: x"))
        check(offline.text == "Offline \u{00B7} working locally" && offline.tint == .neutral,
              "a network failure is offline in a neutral pill, got \(offline)", &ok)
        let failed = ShiftSyncPresentation.look(for: .failed("git commit failed: nothing to commit"))
        check(failed.text == "Sync failed" && failed.tint == .critical,
              "a repository failure is red, got \(failed)", &ok)
        check(failed.toolTip?.contains("nothing to commit") == true, "and carries its reason on hover", &ok)
    }

    // MARK: 2

    private static func checkOfflineDetection(_ ok: inout Bool) {
        let offline = [
            "fatal: unable to access 'https://github.com/x.git/': Could not resolve host: github.com",
            "ssh: connect to host github.com port 22: Network is unreachable",
            "Could not clone git@x: fatal: Could not read from remote repository. Working locally offline.",
            "ssh: connect to host github.com port 22: Operation timed out",
        ]
        for reason in offline {
            check(ShiftSyncPresentation.isOffline(reason), "\"\(reason)\" should read as offline", &ok)
        }
        let notOffline = [
            "git push failed: ! [rejected] main -> main (non-fast-forward)",
            "No local git checkout at /tmp/x",
            ConfigRepoPrivacy.publicRepoRefusalMessage,
        ]
        for reason in notOffline {
            check(!ShiftSyncPresentation.isOffline(reason), "\"\(reason)\" is not offline", &ok)
        }
    }

    // MARK: 3

    private static func task(_ id: String, priority: ShiftPriority, due: String?, updated: String) -> ShiftTask {
        var task = ShiftTask.fresh()
        task.id = id
        task.priority = priority
        task.dueDate = due
        task.updatedAt = updated
        task.createdAt = "2026-10-01T09:00:00Z"
        return task
    }

    private static func checkSortOrders(_ ok: inout Bool) {
        let tasks = [
            task("soon-low", priority: .low, due: "2026-10-15", updated: "2026-10-02T09:00:00Z"),
            task("later-high", priority: .high, due: "2026-10-30", updated: "2026-10-03T09:00:00Z"),
            task("none-normal", priority: .normal, due: nil, updated: "2026-10-10T09:00:00Z"),
        ]
        func order(_ sort: ShiftTaskSort) -> [String] { tasks.sorted(by: sort.areInOrder).map(\.id) }
        check(order(.dueDate) == ["soon-low", "later-high", "none-normal"],
              "due date first, undated last, got \(order(.dueDate))", &ok)
        check(order(.priority) == ["later-high", "none-normal", "soon-low"],
              "high, normal, low, got \(order(.priority))", &ok)
        check(order(.recentlyUpdated) == ["none-normal", "later-high", "soon-low"],
              "most recently updated first, got \(order(.recentlyUpdated))", &ok)
        // The discriminating half: the fixture really separates the orders.
        check(Set([order(.dueDate), order(.priority), order(.recentlyUpdated)].map { $0.joined() }).count == 3,
              "the fixture should give three different orders", &ok)
    }

    // MARK: 4

    private static func checkTaskSignals(_ ok: inout Bool) {
        check(ShiftTaskSignals.priorityPill(.high)?.text == "High"
                  && ShiftTaskSignals.priorityPill(.high)?.tint == .critical,
              "High earns the one red pill", &ok)
        check(ShiftTaskSignals.priorityPill(.normal) == nil && ShiftTaskSignals.priorityWord(.normal) == nil,
              "Normal says nothing (Q3)", &ok)
        check(ShiftTaskSignals.priorityPill(.low) == nil && ShiftTaskSignals.priorityWord(.low) == "Low",
              "Low is a quiet word, not a pill", &ok)

        // Pinned at local noon, so no runner's time zone lands the fixture on
        // a day boundary (AGENTS.md's "YYYY-MM-DD" fixture rule).
        var cal = Calendar.current
        cal.timeZone = .current
        let now = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        func day(_ offset: Int) -> String {
            ShiftDateFormatting.components(from: cal.date(byAdding: .day, value: offset, to: now) ?? now).dateStr
        }
        let late = ShiftTaskSignals.dueCaption(date: day(-3), time: nil, now: now, calendar: cal)
        check(late?.text == "Overdue 3 days" && late?.tint == .critical,
              "three days late is red \"Overdue 3 days\", got \(String(describing: late))", &ok)
        let today = ShiftTaskSignals.dueCaption(date: day(0), time: nil, now: now, calendar: cal)
        check(today?.text == "Due today" && today?.tint == .warn,
              "today is amber \"Due today\", got \(String(describing: today))", &ok)
        let later = ShiftTaskSignals.dueCaption(date: day(5), time: nil, now: now, calendar: cal)
        check(later != nil && later?.tint == nil, "a later date is a muted caption", &ok)
        check(ShiftTaskSignals.dueCaption(date: nil, time: nil, now: now) == nil, "no date, no caption", &ok)
    }

    // MARK: 5 - the failed-read card's line number (UI-31)

    private static func checkParseFailureLine(_ ok: inout Bool) {
        let valid = "tasks:\n  - id: t1\n    title: Fine\n"
        check(ShiftYaml.parseFailureLine(text: valid) == nil, "a document that parses has no failure line", &ok)
        let broken = "tasks:\n  - id: t1\n    title: [unclosed\n    status: todo\n"
        let line = ShiftYaml.parseFailureLine(text: broken)
        print("  parseFailureLine on the fixture: \(String(describing: line))")
        check(line.map { (1...4).contains($0) } ?? false,
              "a broken document's failure should land on one of its lines, got \(String(describing: line))", &ok)
    }
}

#endif
