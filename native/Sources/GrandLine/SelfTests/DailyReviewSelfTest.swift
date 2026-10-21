// Grand Line - native macOS app.
//
// F20's pure half: `DailyReviewComposer`, the digest the Home page's Needs
// Attention card renders.
//
// Run with `FM_RUN_DAILY_REVIEW_TESTS=1 .build/debug/GrandLine`.
//
// **Why this suite is pure logic and guards CI's blocking lane.** Everything
// here is a question about a function over a struct: no window, no view and
// no store. The render half is `NeedsAttentionViewSelfTest`'s.
//
// What it covers:
//
//   1. **A real morning** - ordering, the meta line and the overdue wording.
//   2. **Unknown is not zero** (GL-14). Both sections are checked in both
//      directions, because a gap that is never rendered and a zero that is
//      wrongly rendered look identical in a screenshot.
//   3. **No section for a feature that was never built.** Habits used to be
//      the live case for "graceful degradation", which the 2026-09-27
//      review's X7 disagreed with: a stated gap is for data this app could
//      not read, not for a feature that does not exist. The section is gone
//      and `checkNoHabitsSection` is what keeps it gone.
//   4. **Caps are stated, never silent.**

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import Foundation

enum DailyReviewSelfTest {

    @discardableResult
    static func run() -> Bool {
        var ok = true
        checkBusyMorning(&ok)
        checkUnknownIsNotZero(&ok)
        checkNoHabitsSection(&ok)
        checkCapsAreStated(&ok)

        if ok {
            print("DailyReviewSelfTest: all checks passed")
        } else {
            print("DailyReviewSelfTest: FAILED")
        }
        return ok
    }

    // MARK: Fixtures

    /// 21 September 2026, 08:30 local - the mockup's own morning, so the
    /// expected strings here are the ones the captain reviewed.
    static func morning() -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 21
        comps.hour = 8
        comps.minute = 30
        return Calendar.current.date(from: comps) ?? Date()
    }

    static func task(id: String, title: String, due: Date?, time: String? = nil,
                     project: String? = nil, priority: ShiftPriority = .normal,
                     status: ShiftTaskStatus = .todo) -> ShiftTask {
        var task = ShiftTask.fresh()
        task.id = id
        task.title = title
        task.status = status
        task.priority = priority
        task.projectID = project
        task.dueDate = due.map { isoDay($0) }
        task.dueTime = time
        return task
    }

    static func followUp(id: String, title: String, at: Date?, time: String? = nil,
                         status: ShiftFollowUpStatus = .pending) -> ShiftFollowUp {
        var item = ShiftFollowUp.fresh()
        item.id = id
        item.title = title
        item.status = status
        item.followUpAt = at.map { isoDay($0) }
        item.followUpTime = time
        return item
    }

    static func isoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func day(_ offset: Int, from now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
    }

    /// The mockup's morning: one task due today, one five days overdue and two
    /// pending follow-ups.
    static func busyInputs() -> DailyReviewInputs {
        let now = morning()
        var inputs = DailyReviewInputs()
        inputs.now = now
        inputs.tasks = .available([
            task(id: "t-1", title: "Rotate the prod bastion SSH keys", due: now,
                 time: "17:00", project: "p-raas", priority: .high),
            task(id: "t-2", title: "Renew wildcard TLS certificate", due: day(-5, from: now),
                 priority: .high),
            // Not due yet, and completed - neither belongs in "due today".
            task(id: "t-3", title: "Write the migration runbook", due: day(3, from: now)),
            task(id: "t-4", title: "Already handled", due: day(-1, from: now), status: .completed),
        ])
        inputs.projectNames = ["p-raas": "RaaS Migration"]
        inputs.followUps = .available([
            followUp(id: "f-1", title: "Ravi on the VPC peering request", at: now, time: "15:00"),
            followUp(id: "f-2", title: "Priya on the staging DB snapshot", at: day(-2, from: now)),
            followUp(id: "f-3", title: "Closed already", at: now, status: .done),
            followUp(id: "f-4", title: "Next week", at: day(5, from: now)),
        ])
        return inputs
    }

    // MARK: 1 - a real morning

    private static func checkBusyMorning(_ ok: inout Bool) {
        print("\n-- a busy morning --")
        let digest = DailyReviewComposer.digest(from: busyInputs())

        // Two tasks due, most urgent (the overdue one) first.
        check(digest.dueTasks.count == 2,
              "two tasks are due, got \(digest.dueTasks.count)", &ok)
        check(digest.dueTasks.first?.id == "t-2",
              "the overdue task should lead, got \(digest.dueTasks.first?.id ?? "nothing")", &ok)
        check(digest.dueTasks.first?.isOverdue == true, "the leading task is the overdue one", &ok)
        check(digest.dueTasks.first?.overdueDays == 5,
              "an overdue task says how late it is, got \(digest.dueTasks.first?.overdueDays ?? -1)", &ok)
        check(digest.dueTasks.last?.isOverdue == false,
              "a task due later today is not overdue", &ok)
        // A completed task and one due in three days are not "due today" -
        // assert the fixture's own discriminating power, so a drifted filter
        // fails loudly instead of passing vacuously.
        check(!digest.dueTasks.contains(where: { $0.id == "t-3" || $0.id == "t-4" }),
              "a future or completed task must not be due today", &ok)

        // The meta line resolves the project *name*, never the raw id.
        let today = digest.dueTasks.first(where: { $0.id == "t-1" })
        check(today?.meta == "RaaS Migration \u{00B7} High",
              "the meta line should name project and priority, got \(today?.meta ?? "nothing")", &ok)
        check(!(today?.meta.contains("p-raas") ?? true), "a raw project id must never be painted", &ok)

        // Two follow-ups pending and due; the done one and next week's are not.
        check(digest.followUps.count == 2, "two follow-ups are pending, got \(digest.followUps.count)", &ok)
        check(digest.followUps.first?.id == "f-2",
              "the overdue follow-up should lead, got \(digest.followUps.first?.id ?? "nothing")", &ok)
        check(digest.followUps.last?.whenText.hasPrefix("today") == true,
              "a follow-up due today says so, got \(digest.followUps.last?.whenText ?? "nothing")", &ok)
    }

    // MARK: 2 - unknown is never zero

    private static func checkUnknownIsNotZero(_ ok: inout Bool) {
        print("\n-- unknown is not zero --")

        // First, the discriminating half: with everything *available and
        // empty*, there are no gaps at all. Without this, "every section
        // produces a gap" would pass a composer that produced gaps always.
        var empty = DailyReviewInputs()
        empty.now = morning()
        let emptyDigest = DailyReviewComposer.digest(from: empty)
        check(emptyDigest.gaps.isEmpty,
              "an empty-but-readable day has no gaps, got \(emptyDigest.gaps.map(\.section))", &ok)
        check(emptyDigest.dueTasks.isEmpty && emptyDigest.followUps.isEmpty,
              "an empty-but-readable day has nothing due", &ok)

        // Now each section unavailable, one at a time.
        let cases: [(String, (inout DailyReviewInputs) -> Void)] = [
            ("Tasks", { $0.tasks = .unavailable("the tasks file failed to parse") }),
            ("Follow-ups", { $0.followUps = .unavailable("the follow-ups file failed to parse") }),
        ]
        for (section, mutate) in cases {
            var inputs = DailyReviewInputs()
            inputs.now = morning()
            mutate(&inputs)
            let digest = DailyReviewComposer.digest(from: inputs)
            check(digest.gaps.contains(where: { $0.section == section }),
                  "\(section) unavailable should produce a stated gap, got \(digest.gaps.map(\.section))", &ok)
            check(digest.gaps.count == 1,
                  "\(section) unavailable should produce exactly one gap, got \(digest.gaps.count)", &ok)
            check(!(digest.gaps.first?.reason.isEmpty ?? true),
                  "\(section)'s gap must carry a reason, not just a name", &ok)
        }
    }

    // MARK: 3 - habits, which do not exist here at all

    /// **UX issue X7.** The daily review used to render
    /// "Habits - no habits are tracked yet - habit streaks aren't part of
    /// this build" under a warning icon, on every review, every day, for a
    /// feature that was never built. GL-14's stated-gap rule is about data
    /// this app could not read; a feature that does not exist is not a gap
    /// in today's data, and repeating it daily under a warning teaches the
    /// captain to ignore the block that exists to be trusted.
    ///
    /// A source guard, because the thing to pin is an *absence*: no
    /// behavioural check can see a section that has been deleted, and the
    /// way this comes back is somebody re-adding the placeholder rather than
    /// somebody shipping the tracker. When the real habit tracker lands
    /// (§7.2 of the same review) it will introduce its own rows, its own
    /// source and its own cases deliberately - and this case is where it
    /// says so.
    private static func checkNoHabitsSection(_ ok: inout Bool) {
        print("\n-- no habits section (X7) --")
        guard let files = SelfTestSources.appSourceFiles() else {
            check(false, "SKIP-AS-FAILURE: the app's sources are not next to this binary", &ok)
            return
        }
        // The exact sentence the review saw, and the two symbols that
        // produced it.
        let banned = ["aren\u{2019}t part of this build", "DailyReviewHabits", "DailyReviewHabitRow"]
        var offenders: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for needle in banned where text.contains(needle) {
                offenders.append("\(file.lastPathComponent) still carries \(needle.debugDescription)")
            }
        }
        check(offenders.isEmpty,
              "the daily review's habits placeholder is back: \(offenders.joined(separator: "; "))", &ok)

        // And the behavioural half that *is* observable: a fully readable
        // day produces no gaps at all, so nothing is quietly filling the
        // "Not available" block in its place.
        let digest = DailyReviewComposer.digest(from: busyInputs())
        check(!digest.gaps.contains(where: { $0.section == "Habits" }),
              "a habits gap is still being composed, got \(digest.gaps.map(\.section))", &ok)
    }

    // MARK: 4 - caps are stated

    private static func checkCapsAreStated(_ ok: inout Bool) {
        print("\n-- caps are stated, never silent --")
        let now = morning()
        var inputs = DailyReviewInputs()
        inputs.now = now
        inputs.tasks = .available((1...8).map {
            task(id: "t-\($0)", title: "Task \($0)", due: now, time: String(format: "%02d:00", $0 + 8))
        })
        inputs.followUps = .available((1...6).map {
            followUp(id: "f-\($0)", title: "Follow-up \($0)", at: now)
        })
        let digest = DailyReviewComposer.digest(from: inputs)

        check(digest.dueTasks.count == DailyReviewComposer.maxDueTasks,
              "the task column is capped, got \(digest.dueTasks.count)", &ok)
        check(digest.hiddenDueTaskCount == 8 - DailyReviewComposer.maxDueTasks,
              "and says how many it is not showing, got \(digest.hiddenDueTaskCount)", &ok)
        check(digest.hiddenFollowUpCount == 6 - DailyReviewComposer.maxFollowUps,
              "the follow-up column too, got \(digest.hiddenFollowUpCount)", &ok)
    }
}

#endif
