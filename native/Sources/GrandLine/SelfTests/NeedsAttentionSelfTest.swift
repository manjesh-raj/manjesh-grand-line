// Grand Line - native macOS app.
//
// The pure half of the Home page's Needs Attention card:
// `NeedsAttentionComposer` (what the card says), and the two structural
// guarantees the move itself rests on.
//
// Run with `FM_RUN_NEEDS_ATTENTION_TESTS=1 .build/debug/GrandLine`.
//
// **Why this suite is pure logic and guards CI's blocking lane.** Everything
// here is a question about a function over a struct - no window, no view, no
// store. AGENTS.md's rule is that the test is what a suite *asserts*, never
// what it imports, so the render half lives in
// `NeedsAttentionViewSelfTest` (window-backed, in `NEEDS_SESSION`) and this
// one runs everywhere.
//
// What it covers:
//
//   1. **The captain's own two records** - a "Standup Notes" task overdue
//      since 23 September and a "Follow up with Nithin on SRE bot response
//      reviews" follow-up overdue since 18 September, which are the two rows
//      in the screenshots he sent. If the chip wording ever stops reading
//      "Overdue 5 days, since <the date>", this is what says so.
//
//      **The date inside that chip is rendered in the captain's own region**
//      (`DailyReviewComposer.dayMonth` is a localised template), so this file
//      asserts the wording around it literally and the date against the same
//      rendering of an independently built `Date`. Anchoring the whole string
//      to one region is what failed CI on PR 491: en_IN renders "23 Sep",
//      the GitHub runner's en_US renders "Sep 23", and both are correct.
//      `DailyReviewSelfTest` has never asserted a rendered date for exactly
//      this reason.
//   2. **The headline sentence**, in all four states.
//   3. **The move is a move, not a copy** - a source guard that the Today
//      page's card no longer builds a due or follow-up section, and that both
//      sides filter stated gaps through one shared list rather than two
//      spellings of "Follow-ups".
//   4. **GL-14**: an unreadable Tasks store is a stated gap, never an
//      all-clear.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import Foundation

enum NeedsAttentionSelfTest {

    @discardableResult
    static func run() -> Bool {
        var ok = true
        checkTheCaptainsOwnTwoRecords(&ok)
        checkHeadlines(&ok)
        checkChipWording(&ok)
        checkAllClearAndOverflow(&ok)
        checkUnreadableTasksAreAGap(&ok)
        checkTheTodayPageNoLongerBuildsTheseSections(&ok)

        if ok {
            print("NeedsAttentionSelfTest: all checks passed")
        } else {
            print("NeedsAttentionSelfTest: FAILED")
        }
        return ok
    }

    // MARK: Fixtures

    /// A day in September 2026, at **local noon**.
    ///
    /// `Calendar.current`, never a pinned UTC one: a Shift due date is a bare
    /// `"yyyy-MM-dd"` resolved to **local** midnight, and a UTC fixture puts
    /// every date on the wrong side of `startOfDay` (AGENTS.md's own rule, and
    /// the F22 measurement behind it). Noon so no runner's time zone lands the
    /// fixture on a day boundary.
    ///
    /// Built from `DateComponents` here rather than through
    /// `ShiftDateFormatting`, so where it is compared against a date the
    /// composer resolved it is an independent witness rather than a
    /// restatement.
    static func september(_ day: Int, year: Int = 2026) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = 9
        comps.day = day
        comps.hour = 12
        return Calendar.current.date(from: comps) ?? Date()
    }

    /// 28 September 2026 - the day the captain sent the screenshots, so the
    /// day counts asserted below are the ones he saw.
    static func now() -> Date { september(28) }

    /// The two records from the captain's screenshots.
    private static func captainsInputs() -> DailyReviewInputs {
        var task = ShiftTask.fresh()
        task.id = "standup-notes"
        task.title = "Standup Notes"
        task.dueDate = "2026-09-23"
        task.priority = .normal

        var followUp = ShiftFollowUp.fresh()
        followUp.id = "nithin-sre-bot"
        followUp.title = "Follow up with Nithin on SRE bot response reviews"
        followUp.followUpAt = "2026-09-18"

        var inputs = DailyReviewInputs()
        inputs.now = now()
        inputs.tasks = .available([task])
        inputs.followUps = .available([followUp])
        return inputs
    }

    private static func summary(_ inputs: DailyReviewInputs) -> NeedsAttentionSummary {
        NeedsAttentionComposer.summary(from: DailyReviewComposer.digest(from: inputs))
    }

    // MARK: 1 - the captain's own two records

    private static func checkTheCaptainsOwnTwoRecords(_ ok: inout Bool) {
        let result = summary(captainsInputs())

        check(result.items.count == 2,
              "both of the captain's records should be rows, got \(result.items.map(\.text))", &ok)

        guard let task = result.items.first(where: { $0.kind == .task }),
              let followUp = result.items.first(where: { $0.kind == .followUp }) else {
            fail("the summary should carry one task and one follow-up, got \(result.items)", &ok)
            return
        }

        check(task.text == "Standup Notes",
              "the task's text should be its title, got \"\(task.text)\"", &ok)
        check(task.source == "Task", "and its source label should read Task, got \"\(task.source)\"", &ok)
        check(task.actionTitle == "Start",
              "a task's action is Start, got \"\(task.actionTitle)\"", &ok)
        // **The day/month rendering follows the captain's region, so it is
        // not asserted literally.** `DailyReviewComposer.dayMonth` is
        // `setLocalizedDateFormatFromTemplate("dMMM")`, which is right for a
        // captain-facing date and renders "23 Sep" on this machine (en_IN)
        // and "Sep 23" on the GitHub runner (en_US). Both are correct, and
        // pinning the string to one of them is what failed CI on PR 491.
        //
        // So the *wording around* the date is asserted literally - which is
        // the part this file owns - and the date itself is compared against
        // the same rendering of a **separately built** `Date`. That keeps the
        // check discriminating: a composer that resolved the wrong day, or
        // dropped the "since" clause, or miscounted the days, still fails.
        let rendered23 = DailyReviewComposer.dayMonth(september(23))
        // The fixture's own discriminating power, first, since comparing a
        // chip against `rendered23` proves nothing if that rendering is empty
        // or constant.
        //
        // Both properties are asserted **without naming a single character of
        // any region's output**, which is the whole point: an earlier draft
        // guarded this with `contains("sep")` and a length cap, and that
        // passed in three English regions and failed in de_DE ("23. Sept.")
        // and ja_JP ("9月23日") - a guard that is itself region-locked is the
        // bug it exists to catch, one level up.
        check(!rendered23.isEmpty, "the day/month rendering should not be empty", &ok)
        check(rendered23 != DailyReviewComposer.dayMonth(september(18)),
              "it should vary with the day, or comparing a chip against it asserts nothing - "
                  + "got \"\(rendered23)\" for both 23 and 18 September", &ok)
        // No year: a `dMMM` template that quietly grew one would widen every
        // chip on the card, and this catches it in any region because the same
        // day in a different year would then render differently.
        check(rendered23 == DailyReviewComposer.dayMonth(september(23, year: 2027)),
              "the day/month rendering should carry no year, got \"\(rendered23)\" vs "
                  + "\"\(DailyReviewComposer.dayMonth(september(23, year: 2027)))\"", &ok)

        // 23 Sep to 28 Sep is five days.
        check(task.chipText == "Overdue 5 days, since \(rendered23)",
              "the task chip should read the mockup's wording, got \"\(task.chipText)\"", &ok)
        check(task.tone == .late, "and it is late, got \(task.tone)", &ok)

        check(followUp.text.contains("Nithin"),
              "the follow-up's text should be its title, got \"\(followUp.text)\"", &ok)
        check(followUp.source == "Follow-up",
              "and its source label should read Follow-up, got \"\(followUp.source)\"", &ok)
        check(followUp.actionTitle == "Open",
              "a follow-up's action is Open, got \"\(followUp.actionTitle)\"", &ok)
        check(followUp.chipText == "Overdue 10 days, since \(DailyReviewComposer.dayMonth(september(18)))",
              "the follow-up chip should read the mockup's wording, got \"\(followUp.chipText)\"", &ok)
        // An overdue follow-up's `whenText` restates the chip, so it is not
        // repeated as the meta line.
        check(followUp.meta == nil,
              "an overdue follow-up should not repeat its date as meta, got \(followUp.meta ?? "nil")",
              &ok)

        check(result.state == .late, "two late rows is the late state, got \(result.state)", &ok)
        check(result.eyebrow == "Needs attention, 2",
              "the eyebrow should count the open rows, got \"\(result.eyebrow)\"", &ok)
        check(result.headline == "Two things are late.",
              "the headline should be the mockup's sentence, got \"\(result.headline)\"", &ok)
        check(result.symbol == "exclamationmark.triangle.fill",
              "a late card carries the alert glyph, got \(result.symbol)", &ok)
        check(result.tint == .critical, "and the red tint, got \(result.tint)", &ok)
    }

    // MARK: 2 - the sentence

    private static func checkHeadlines(_ ok: inout Bool) {
        // A check that cannot fail is worse than no check: assert the four
        // states really do produce four different sentences before believing
        // any one of them.
        let allClear = NeedsAttentionComposer.headline(state: .allClear, lateCount: 0, total: 0)
        let oneLate = NeedsAttentionComposer.headline(state: .late, lateCount: 1, total: 1)
        let mixed = NeedsAttentionComposer.headline(state: .late, lateCount: 2, total: 3)
        let dueOnly = NeedsAttentionComposer.headline(state: .dueToday, lateCount: 0, total: 2)
        let gap = NeedsAttentionComposer.headline(state: .unavailable, lateCount: 0, total: 0)

        check(Set([allClear, oneLate, mixed, dueOnly, gap]).count == 5,
              "the five states should read differently, got \([allClear, oneLate, mixed, dueOnly, gap])",
              &ok)
        check(allClear == "Nothing is due, and nobody is waiting on you.",
              "the all-clear sentence, got \"\(allClear)\"", &ok)
        check(oneLate == "One thing is late.", "one late, got \"\(oneLate)\"", &ok)
        check(mixed == "Two things are late, and one more is due today.",
              "two late and one due, got \"\(mixed)\"", &ok)
        check(dueOnly == "Two things are due today.", "two due, got \"\(dueOnly)\"", &ok)
        // GL-14: a card that could not read a source must not say all-clear.
        check(!gap.lowercased().contains("nothing"),
              "an unreadable source must not read as an all-clear, got \"\(gap)\"", &ok)
    }

    // MARK: 3 - the chip

    /// `chipText` takes the rendered day as a **parameter**, so these cases
    /// are region-independent by construction - the literal below is a
    /// stand-in for whatever `dayMonth` produced, not an expectation about
    /// how this machine renders a date.
    private static func checkChipWording(_ ok: inout Bool) {
        check(NeedsAttentionComposer.chipText(isOverdue: false, days: 0, dayText: "28 Sep")
                == "Due today",
              "a row due today says so", &ok)
        check(NeedsAttentionComposer.chipText(isOverdue: true, days: 1, dayText: "27 Sep")
                == "Overdue 1 day, since 27 Sep",
              "one day is singular", &ok)
        // A task whose due *time* passed earlier today is overdue and zero
        // days late; "Overdue 0 days" would be nonsense.
        check(NeedsAttentionComposer.chipText(isOverdue: true, days: 0, dayText: "28 Sep")
                == "Overdue today",
              "a same-day overdue row does not claim a day count", &ok)
    }

    // MARK: 4 - all clear, and the stated overflow

    private static func checkAllClearAndOverflow(_ ok: inout Bool) {
        var empty = DailyReviewInputs()
        empty.now = now()
        let quiet = summary(empty)
        check(quiet.items.isEmpty, "nothing due is no rows, got \(quiet.items.count)", &ok)
        check(quiet.state == .allClear, "and the all-clear state, got \(quiet.state)", &ok)
        check(quiet.eyebrow == "All clear", "with its own eyebrow, got \"\(quiet.eyebrow)\"", &ok)
        check(quiet.symbol == "checkmark.circle.fill" && quiet.tint == .good,
              "and the calm glyph and tint, got \(quiet.symbol)/\(quiet.tint)", &ok)
        check(quiet.overflowNote == nil, "with nothing hidden, got \(quiet.overflowNote ?? "nil")", &ok)

        // The digest caps at five due tasks and three follow-ups. An overflow
        // is *stated*, never silently dropped - the same rule the Today card
        // already follows.
        var many = DailyReviewInputs()
        many.now = now()
        many.tasks = .available((0..<9).map { index in
            var task = ShiftTask.fresh()
            task.id = "t\(index)"
            task.title = "Task \(index)"
            task.dueDate = "2026-09-28"
            return task
        })
        let capped = summary(many)
        check(capped.items.count == DailyReviewComposer.maxDueTasks,
              "the digest's own cap should hold, got \(capped.items.count)", &ok)
        check(capped.overflowNote == "+4 more in Tasks",
              "and the remainder should be stated, got \(capped.overflowNote ?? "nil")", &ok)
    }

    // MARK: 5 - GL-14

    private static func checkUnreadableTasksAreAGap(_ ok: inout Bool) {
        var broken = DailyReviewInputs()
        broken.now = now()
        broken.tasks = .unavailable("your tasks could not be read")
        broken.followUps = .unavailable("your tasks could not be read")
        let result = summary(broken)

        check(result.items.isEmpty, "an unreadable store produces no rows, got \(result.items)", &ok)
        check(result.state == .unavailable,
              "and is NOT the all-clear state, got \(result.state)", &ok)
        check(result.gaps.count == 2,
              "both sections should state their gap, got \(result.gaps)", &ok)
        check(result.gaps.allSatisfy { $0.reason.contains("could not be read") },
              "with the reason carried through, got \(result.gaps)", &ok)
        check(result.symbol != "checkmark.circle.fill",
              "and never the all-clear glyph, got \(result.symbol)", &ok)

        // The other three sections' gaps belong to the Today page and must not
        // be duplicated here.
        var calendarGap = DailyReviewInputs()
        calendarGap.now = now()
        calendarGap.calendar = .unavailable("the calendar is switched off")
        check(summary(calendarGap).gaps.isEmpty,
              "the calendar's gap stays on the Today page, got \(summary(calendarGap).gaps)", &ok)
    }

    // MARK: 6 - the move is a move

    /// A source guard, because the behaviour and the duplication are different
    /// questions: the Home card can be perfectly right while the Today page
    /// still draws the same two sections beside it, and nothing about that
    /// fails a render assertion.
    private static func checkTheTodayPageNoLongerBuildsTheseSections(_ ok: inout Bool) {
        guard let root = SelfTestSources.appSourceDirectory() else {
            fail("could not find the app's source directory - this check is vacuous without it", &ok)
            return
        }
        let path = root.appendingPathComponent("DailyReviewCard.swift")
        guard let source = try? String(contentsOf: path, encoding: .utf8) else {
            fail("could not read DailyReviewCard.swift at \(path.path)", &ok)
            return
        }

        // Assert the fixture's own discriminating power first: the file must
        // still be the card, or every absence below passes vacuously.
        check(source.contains("buildBoardColumn"),
              "DailyReviewCard.swift should still build its board column - "
                  + "without that this check cannot fail", &ok)

        check(!source.contains("buildDueColumn"),
              "the Today card still builds a due column; the captain's move was to Home", &ok)
        check(!source.contains("\"Due today \\u{00B7}"),
              "the Today card still paints a \"Due today\" section head", &ok)
        check(!source.contains("Follow-ups \\u{00B7}"),
              "the Today card still paints a \"Follow-ups\" section head", &ok)

        // One shared list of which sections moved. Two spellings of
        // "Follow-ups" would silently leave a stated gap rendered on both
        // pages or on neither.
        check(source.contains("NeedsAttentionComposer.ownedGapSections"),
              "the Today card should filter its gaps through the one shared list", &ok)
        check(NeedsAttentionComposer.ownedGapSections == ["Tasks", "Follow-ups"],
              "and that list should name exactly the two moved sections, got "
                  + "\(NeedsAttentionComposer.ownedGapSections)", &ok)
    }
}

#endif
