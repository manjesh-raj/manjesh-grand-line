// Grand Line - native macOS app.
//
// F20's pure half: `DailyReviewComposer` (what the card says) plus the two
// guarantees that are not about a render at all - that a section which could
// not be read says so rather than showing a zero, and that the calendar
// source cannot write.
//
// Run with `FM_RUN_DAILY_REVIEW_TESTS=1 .build/debug/GrandLine`.
//
// **Why this suite is pure logic and guards CI's blocking lane.** Everything
// here is a question about a function over a struct: no window, no view, no
// store, no EventKit. AGENTS.md's rule is that the test is what a suite
// *asserts*, never what it imports - so the render half lives in
// `DailyReviewViewSelfTest` (window-backed, in `NEEDS_SESSION`) and this one
// runs everywhere.
//
// What it covers:
//
//   1. **A real morning** - ordering, the meta line, the overdue wording and
//      the one sentence at the top of the card.
//   2. **Unknown is not zero** (GL-14, and the reason this feature exists in
//      this shape). Every one of the six sections is checked in both
//      directions, because a gap that is never rendered and a zero that is
//      wrongly rendered look identical in a screenshot.
//   3. **Graceful degradation for a feature that has not shipped.** Habits
//      (F8) is the live case; the available path is asserted too, with
//      fabricated rows, so the day it lands the suite already covers it.
//   4. **Caps are stated, never silent.**
//   5. **The calendar is read-only**, asserted as a source guard - the one
//      shape available, since a behavioural check would have to touch the
//      captain's real calendar to prove it does not write to it.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import Foundation

enum DailyReviewSelfTest {

    @discardableResult
    static func run() -> Bool {
        var ok = true
        checkBusyMorning(&ok)
        checkHeadlines(&ok)
        checkUnknownIsNotZero(&ok)
        checkHabitsDegradeGracefully(&ok)
        checkCapsAreStated(&ok)
        checkStickiesAndReading(&ok)
        checkDayKeyMatchesTheBriefing(&ok)
        checkCalendarSourceIsReadOnly(&ok)
        checkBothHostsRefreshGoogle(&ok)
        checkCalendarGapsAreStated(&ok)

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

    static func sticky(id: String, title: String, text: String = "", created: Date,
                       checklist: [StickyChecklistItem]? = nil,
                       archived: Date? = nil) -> StickyNote {
        StickyNote(id: id, title: title, text: text, color: .yellow,
                   x: 0, y: 0, width: 200, height: 200, rotationDegrees: 0,
                   createdAt: created, archivedAt: archived, checklist: checklist)
    }

    static func link(id: String, title: String, added: Date, read: Date? = nil) -> ReadingLink {
        ReadingLink(id: id, url: "https://example.com/\(id)", title: title, summary: "",
                    aiSummary: "", tags: [], addedAt: added, readAt: read,
                    metadataState: .resolved)
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

    /// The mockup's morning: one task due today, one five days overdue, two
    /// pending follow-ups, three events, an unread reading list and two
    /// stickies - and habits unavailable, because F8 has not shipped.
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
        inputs.calendar = .available([
            DailyReviewEventRow(title: "Platform standup", timeText: "10:00", detail: "",
                                colorHex: "6A8DED", isAllDay: false),
            DailyReviewEventRow(title: "RaaS cutover dry run", timeText: "14:30",
                                detail: "6 attendees \u{00B7} Meet", colorHex: "CD8D2E", isAllDay: false),
            DailyReviewEventRow(title: "1:1 with Priya", timeText: "17:00", detail: "",
                                colorHex: nil, isAllDay: false),
        ])
        inputs.habits = DailyReviewHabits.read()
        inputs.stickies = .available([
            sticky(id: "s-1", title: "Ask Ravi about VPC peering", created: day(-3, from: now)),
            sticky(id: "s-2", title: "Cutover checklist", created: day(-1, from: now),
                   checklist: [
                       StickyChecklistItem(id: "c1", text: "Freeze writes", isDone: true),
                       StickyChecklistItem(id: "c2", text: "Snapshot", isDone: true),
                       StickyChecklistItem(id: "c3", text: "Cut over", isDone: false),
                       StickyChecklistItem(id: "c4", text: "Verify", isDone: false),
                   ]),
            sticky(id: "s-3", title: "Archived thought", created: day(-9, from: now),
                   archived: day(-2, from: now)),
        ])
        inputs.reading = .available([
            link(id: "r-1", title: "Graceful node shutdown and pod eviction ordering",
                 added: day(-16, from: now)),
            link(id: "r-2", title: "A newer unread thing", added: day(-1, from: now)),
            link(id: "r-3", title: "Already read", added: day(-20, from: now), read: day(-2, from: now)),
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
        check(digest.dueTasks.first?.overdueText?.hasPrefix("overdue since") == true,
              "an overdue task names when it went late, got \(digest.dueTasks.first?.overdueText ?? "nothing")", &ok)
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

        // Four things are due (two tasks, two follow-ups) and two are late.
        check(digest.headline == "Four things are due, and two are already late.",
              "the sentence should count the day, got \"\(digest.headline)\"", &ok)

        // The footer offers the most urgent thing, by id rather than by name.
        check(digest.primaryTaskID == "t-2",
              "the primary action should be the overdue task, got \(digest.primaryTaskID ?? "nothing")", &ok)
        check(digest.primaryTaskTitle == "Renew wildcard TLS certificate",
              "and should carry its title", &ok)

        check(digest.events.count == 3, "three events, got \(digest.events.count)", &ok)
        check(digest.kicker.contains("\u{00B7}"),
              "the kicker joins the date and the time, got \"\(digest.kicker)\"", &ok)
    }

    // MARK: 2 - the sentence

    private static func checkHeadlines(_ ok: inout Bool) {
        print("\n-- the sentence --")
        check(DailyReviewComposer.headline(dueCount: 0, overdueCount: 0, eventCount: 0)
                == "Nothing is due today.",
              "an empty day", &ok)
        check(DailyReviewComposer.headline(dueCount: 0, overdueCount: 0, eventCount: 3)
                == "Nothing is due - three events on your calendar.",
              "nothing due, but a full calendar", &ok)
        check(DailyReviewComposer.headline(dueCount: 1, overdueCount: 0, eventCount: 0)
                == "One thing is due today.",
              "one thing, agreeing in number", &ok)
        check(DailyReviewComposer.headline(dueCount: 2, overdueCount: 1, eventCount: 0)
                == "Two things are due, and one is already late.",
              "the mockup's own sentence", &ok)
        check(DailyReviewComposer.headline(dueCount: 2, overdueCount: 0, eventCount: 1)
                == "Two things are due, and one event is on your calendar.",
              "due plus calendar", &ok)
        // Past ten it is a digit, because "seventeen" in a glance is not one.
        check(DailyReviewComposer.headline(dueCount: 17, overdueCount: 0, eventCount: 0)
                == "17 things are due today.",
              "a big count reads as a number, got \"\(DailyReviewComposer.headline(dueCount: 17, overdueCount: 0, eventCount: 0))\"",
              &ok)
    }

    // MARK: 3 - unknown is never zero

    private static func checkUnknownIsNotZero(_ ok: inout Bool) {
        print("\n-- unknown is not zero --")

        // First, the discriminating half: with everything *available and
        // empty*, there are no gaps at all. Without this, "every section
        // produces a gap" would pass a composer that produced gaps always.
        var empty = DailyReviewInputs()
        empty.now = morning()
        empty.habits = .available([])
        let emptyDigest = DailyReviewComposer.digest(from: empty)
        check(emptyDigest.gaps.isEmpty,
              "an empty-but-readable day has no gaps, got \(emptyDigest.gaps.map(\.section))", &ok)
        check(emptyDigest.dueTasks.isEmpty && emptyDigest.reading?.unreadCount == 0,
              "an empty-but-readable day still renders its sections", &ok)

        // Now each section unavailable, one at a time.
        let cases: [(String, (inout DailyReviewInputs) -> Void)] = [
            ("Tasks", { $0.tasks = .unavailable("the tasks file failed to parse") }),
            ("Follow-ups", { $0.followUps = .unavailable("the follow-ups file failed to parse") }),
            ("Calendar", { $0.calendar = .unavailable("no calendar access") }),
            ("Habits", { $0.habits = .unavailable("not tracked") }),
            ("Sticky board", { $0.stickies = .unavailable("the board file failed to parse") }),
            ("Reading list", { $0.reading = .unavailable("the reading list file failed to parse") }),
        ]
        for (section, mutate) in cases {
            var inputs = DailyReviewInputs()
            inputs.now = morning()
            inputs.habits = .available([])
            mutate(&inputs)
            let digest = DailyReviewComposer.digest(from: inputs)
            check(digest.gaps.contains(where: { $0.section == section }),
                  "\(section) unavailable should produce a stated gap, got \(digest.gaps.map(\.section))", &ok)
            check(digest.gaps.count == 1,
                  "\(section) unavailable should produce exactly one gap, got \(digest.gaps.count)", &ok)
            check(!(digest.gaps.first?.reason.isEmpty ?? true),
                  "\(section)'s gap must carry a reason, not just a name", &ok)
        }

        // A reading list that could not be read is *not* "0 unread".
        var unreadable = DailyReviewInputs()
        unreadable.now = morning()
        unreadable.habits = .available([])
        unreadable.reading = .unavailable("the reading list file failed to parse")
        let digest = DailyReviewComposer.digest(from: unreadable)
        check(digest.reading == nil,
              "an unreadable reading list must have no summary at all, got \(String(describing: digest.reading))", &ok)
    }

    // MARK: 4 - habits, which have not shipped

    private static func checkHabitsDegradeGracefully(_ ok: inout Bool) {
        print("\n-- habits (F8 has not shipped) --")
        let read = DailyReviewHabits.read()
        check(read.value == nil, "habits are not available in this build", &ok)
        check(read.unavailableReason == DailyReviewHabits.notTrackedReason,
              "and the reason is the stated one", &ok)

        var inputs = busyInputs()
        let digest = DailyReviewComposer.digest(from: inputs)
        check(digest.habits.isEmpty, "no habit rows, since there is no source", &ok)
        check(digest.gaps.contains(where: { $0.section == "Habits" }),
              "the habits section is a stated gap rather than a silent omission", &ok)

        // The path F8 will land on, asserted now so it is already covered.
        inputs.habits = .available([
            DailyReviewHabitRow(title: "Morning review", doneToday: true, streak: 23),
            DailyReviewHabitRow(title: "Read 20 min", doneToday: false, streak: nil),
        ])
        let withHabits = DailyReviewComposer.digest(from: inputs)
        check(withHabits.habits.count == 2, "two habit rows once a source exists", &ok)
        check(!withHabits.gaps.contains(where: { $0.section == "Habits" }),
              "and no habits gap once they are available", &ok)
        check(withHabits.habits.first?.streak == 23, "the streak survives composition", &ok)
    }

    // MARK: 5 - caps are stated

    private static func checkCapsAreStated(_ ok: inout Bool) {
        print("\n-- caps are stated, never silent --")
        let now = morning()
        var inputs = DailyReviewInputs()
        inputs.now = now
        inputs.habits = .available([])
        inputs.tasks = .available((1...8).map {
            task(id: "t-\($0)", title: "Task \($0)", due: now, time: String(format: "%02d:00", $0 + 8))
        })
        inputs.followUps = .available((1...6).map {
            followUp(id: "f-\($0)", title: "Follow-up \($0)", at: now)
        })
        inputs.calendar = .available((1...7).map {
            DailyReviewEventRow(title: "Event \($0)", timeText: "0\($0):00", detail: "",
                                colorHex: nil, isAllDay: false)
        })
        let digest = DailyReviewComposer.digest(from: inputs)

        check(digest.dueTasks.count == DailyReviewComposer.maxDueTasks,
              "the task column is capped, got \(digest.dueTasks.count)", &ok)
        check(digest.hiddenDueTaskCount == 8 - DailyReviewComposer.maxDueTasks,
              "and says how many it is not showing, got \(digest.hiddenDueTaskCount)", &ok)
        check(digest.hiddenFollowUpCount == 6 - DailyReviewComposer.maxFollowUps,
              "the follow-up column too, got \(digest.hiddenFollowUpCount)", &ok)
        check(digest.hiddenEventCount == 7 - DailyReviewComposer.maxEvents,
              "and the calendar column, got \(digest.hiddenEventCount)", &ok)

        // The sentence counts everything due, not just what fits on the card -
        // which is the whole reason the cap is kept out of the headline.
        // Fourteen due (8 tasks + 6 follow-ups), none late, seven events -
        // and the counts are the day's, not the column's.
        check(digest.headline == "14 things are due, and seven events are on your calendar.",
              "the sentence counts the day rather than the column, got \"\(digest.headline)\"", &ok)
    }

    // MARK: 6 - the board and the reading list

    private static func checkStickiesAndReading(_ ok: inout Bool) {
        print("\n-- the board and the reading list --")
        let digest = DailyReviewComposer.digest(from: busyInputs())

        check(digest.stickies.count == 2,
              "an archived note is not on the board, got \(digest.stickies.count)", &ok)
        check(digest.stickies.first?.id == "s-2",
              "a part-done checklist leads, got \(digest.stickies.first?.id ?? "nothing")", &ok)
        check(digest.stickies.first?.detail == "2 of 4 done",
              "and reports its progress, got \(digest.stickies.first?.detail ?? "nothing")", &ok)
        check(digest.stickies.last?.detail == "up for 3 days",
              "an ordinary note reports its age, got \(digest.stickies.last?.detail ?? "nothing")", &ok)
        check(!digest.stickies.contains(where: { $0.id == "s-3" }),
              "the archived note really was excluded", &ok)

        guard let reading = digest.reading else {
            check(false, "no reading summary", &ok); return
        }
        check(reading.unreadCount == 2, "two unread, got \(reading.unreadCount)", &ok)
        check(reading.topTitle == "Graceful node shutdown and pod eviction ordering",
              "the oldest unread is the one named, got \(reading.topTitle ?? "nothing")", &ok)
        check(reading.oldestText == "oldest saved 2 weeks ago",
              "and its age is in whole units, got \"\(reading.oldestText)\"", &ok)
    }

    // MARK: 7 - the day key

    private static func checkDayKeyMatchesTheBriefing(_ ok: inout Bool) {
        print("\n-- the day key --")
        let now = morning()
        var inputs = DailyReviewInputs()
        inputs.now = now
        inputs.habits = .available([])
        let digest = DailyReviewComposer.digest(from: inputs)
        // The same key F12 uses, so the two cards turn over together - a
        // second definition of "today" is exactly how two cards on one page
        // end up disagreeing at midnight.
        check(digest.day == MorningBriefing.dayKey(for: now),
              "the digest's day key should be the briefing's, got \(digest.day)", &ok)
        check(digest.generatedAt == now, "and it records when it was composed", &ok)
    }

    // MARK: 8 - the calendar cannot write

    /// A source guard, and the only available shape: proving "this never
    /// writes to your calendar" behaviourally would mean writing to a real
    /// calendar to see whether it happened.
    private static func checkCalendarSourceIsReadOnly(_ ok: inout Bool) {
        print("\n-- the calendar source is read-only --")
        guard let root = SelfTestSources.appSourceDirectory() else {
            check(false, "could not resolve the app's source directory - this check would pass vacuously", &ok)
            return
        }
        let path = root.appendingPathComponent("DailyReviewCalendar.swift")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            check(false, "could not read DailyReviewCalendar.swift", &ok)
            return
        }
        // The fixture's own discriminating power first: the file really is
        // the EventKit one, so a rename cannot make this check vacuous.
        check(text.contains("import EventKit"), "DailyReviewCalendar.swift should be the EventKit file", &ok)
        check(text.contains("events(matching:"), "and should be reading events", &ok)

        // Every EventKit entry point that changes something. Matched as plain
        // text, which is enough: these are method names, and a call spelled
        // any other way would not compile.
        for forbidden in [".save(", ".remove(", ".commit(", "EKEvent(",
                          ".saveCalendar(", ".removeCalendar(", ".reset()"] {
            check(!text.contains(forbidden),
                  "DailyReviewCalendar.swift must never call \(forbidden) - it is read-only", &ok)
        }

        // And it is the only file in the app that imports EventKit at all, so
        // a second, unreviewed calendar path cannot appear quietly.
        let importers = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { $0.hasSuffix(".swift") }
            .filter { name in
                guard let body = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) else {
                    return false
                }
                return body.contains("import EventKit")
            } ?? []
        check(importers == ["DailyReviewCalendar.swift"],
              "exactly one file may import EventKit, got \(importers)", &ok)
    }

    // MARK: 9 - the calendar's own states

    private static func checkCalendarGapsAreStated(_ ok: inout Bool) {
        print("\n-- the calendar's states --")
        let off = DisabledDailyReviewCalendar()
        let result = off.events(on: morning())
        check(result.value == nil, "the off source yields no events", &ok)
        check(result.unavailableReason == DisabledDailyReviewCalendar.offReason,
              "and says the column is off rather than that the day is empty", &ok)
        check(!off.canPrompt, "the off source never prompts", &ok)

        // The colour mapping, which is the one piece of `EventKit` glue that
        // is a pure function.
        check(EventKitDailyReviewCalendar.hex(from: .white) == "FFFFFF",
              "white maps to FFFFFF, got \(EventKitDailyReviewCalendar.hex(from: .white))", &ok)
        check(EventKitDailyReviewCalendar.hex(from: .black) == "000000",
              "black maps to 000000, got \(EventKitDailyReviewCalendar.hex(from: .black))", &ok)
    }

    // MARK: 10 - B16: both hosts of the card refresh Google

    /// A source guard, because the behaviour cannot be asserted without a
    /// connected Google account and a network.
    ///
    /// `DailyReviewCalendarReading.events(on:)` is synchronous and on the main
    /// thread, so a Google source can only ever serve a **cached snapshot** -
    /// something has to fetch. Overview always did; Fleet, which hosts the
    /// same card, never did (B16), so on a machine where Fleet is the page the
    /// captain opens, the calendar column rendered whatever another page had
    /// last fetched, or a stated gap forever.
    private static func checkBothHostsRefreshGoogle(_ ok: inout Bool) {
        print("\n-- both hosts of the card refresh Google --")
        guard let root = SelfTestSources.appSourceDirectory() else {
            check(false, "could not resolve the app's source directory - "
                  + "this check would pass vacuously", &ok)
            return
        }
        for name in ["DailyOverviewController.swift", "FleetController.swift"] {
            let path = root.appendingPathComponent(name)
            guard let text = try? String(contentsOf: path, encoding: .utf8) else {
                check(false, "could not read \(name)", &ok)
                continue
            }
            // Discriminating power first: this really is a host of the card.
            check(text.contains("renderDailyReview()"),
                  "\(name) should be a host of the daily review card", &ok)
            check(text.contains("DailyReviewCalendarSources.shared.refreshGoogle(for:"),
                  "\(name) hosts the daily review card and must refresh the Google source - "
                  + "`events(on:)` only ever reads a cached snapshot (B16)", &ok)
        }
    }
}

#endif
