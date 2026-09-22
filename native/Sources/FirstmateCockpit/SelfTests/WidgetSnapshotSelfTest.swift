// Manjesh Grand Line - native macOS app.
//
// F23's **pure-logic** half (full review #3 §8): the widget snapshot's
// projection from the real store types, its round trip through the shared
// container, the digest both widgets render from, GL-14's unavailable and
// locked states, and the reverse channel a tapped widget button writes into.
//
// No window, no `WidgetKit`, no `NSApp` - so this suite is deliberately NOT in
// `run-all-tests.sh`'s `NEEDS_SESSION` list and it guards CI's **blocking**
// lane. That is AGENTS.md's own rule ("the test is what the suite asserts,
// never what it imports"), and here it is also the whole design of the
// feature: F23's rendering half genuinely cannot be asserted in this
// environment, so everything that can actually be *wrong* was deliberately
// written as functions of values.
//
// ## There is no windowed sibling, and that is a statement rather than a gap
//
// Every other feature in this app that has a pure suite has a windowed one
// beside it. This one cannot: a widget is not an `NSView`, so
// `OffScreenProbe`/`cacheDisplay` - this repo's screenshot substitute - has
// nothing to render. A widget's views are only drawn by the system's widget
// host, which will not load an extension without a Team-ID-signed App Group
// entitlement (see `native/Widgets/README.md` for what `codesign -dv`
// actually reports on this app today). What exists instead is
// `#Preview` blocks in the two widget files, four source guards in this
// suite, and a compile of the real extension via
// `Scripts/build-widget-extension.sh --check`.
//
// ## Why every case pins `now` and the calendar
//
// A widget entry is rendered at an instant WidgetKit chose, not at the
// instant the code ran - so "overdue" is a function of the entry's clock and
// nothing else. `GrandLineWidgetDigest` takes `now` and a `Calendar` for
// exactly that reason, and every case here pins **Monday 21 September 2026,
// 14:00 UTC** in a UTC Gregorian calendar with the POSIX locale, which is
// also the day the reviewed mockup itself draws ("Monday 21 September"). A
// suite that used the real clock could only assert something vague, which is
// AGENTS.md's "a check that cannot fail is worse than no check".
//
// `FM_RUN_WIDGET_SNAPSHOT_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum WidgetSnapshotSelfTest {

    /// Monday 21 September 2026, 14:00 UTC - the mockup's own day.
    private static let now = Date(timeIntervalSince1970: 1_789_999_200)

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkTheFixtureIsWhatItClaims(check)
        checkTheProjectionFromRealStoreTypes(check)
        checkALockedSnapshotCarriesNothing(check)
        checkTheDigestMatchesTheReviewedMockup(check)
        checkUrgencyFollowsTheEntryClock(check)
        checkTheHorizonAndUndatedTasks(check)
        checkStaleness(check)
        checkStickyOrderingAndPinning(check)
        checkUnavailableStates(check)
        checkTheRoundTripThroughTheSharedContainer(check)
        checkTheContainerHonoursItsOverride(check)
        checkTheActionQueueRoundTrips(check)
        checkTheDrainAppliesThroughTheRealStore(check)
        checkALockedAppHoldsQueuedActions(check)
        checkTheStickyStoreNotifiesItsObservers(check)
        checkThePaletteMatchesDaylight(check)
        checkTheExtensionAndTheContractAgree(check)

        print(ok ? "WidgetSnapshotSelfTest: OK" : "WidgetSnapshotSelfTest: FAILURES")
        return ok
    }

    // MARK: Fixtures

    /// The reviewed mockup's own four tasks, as real `ShiftTask` values.
    ///
    /// Dates are relative to the pinned `now`: one yesterday at 09:00 (the
    /// mockup's "overdue" row), two today with no time, one tomorrow.
    private static func mockupTasks() -> [ShiftTask] {
        func iso(_ dayOffset: Int) -> String {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now))!
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: day)
        }
        var tls = ShiftTask.fresh(now: now)
        tls.id = "tls"
        tls.title = "Renew wildcard TLS certificate"
        tls.priority = .high
        tls.dueDate = iso(-1)
        tls.dueTime = "09:00"

        var keys = ShiftTask.fresh(now: now)
        keys.id = "keys"
        keys.title = "Rotate the prod bastion SSH keys"
        keys.priority = .high
        keys.dueDate = iso(0)

        var standup = ShiftTask.fresh(now: now)
        standup.id = "standup"
        standup.title = "Standup notes"
        standup.dueDate = iso(0)
        standup.recurrence = ShiftRecurrence(frequency: .weekly, weekdays: ShiftRecurrence.weekdaySet)

        var otel = ShiftTask.fresh(now: now)
        otel.id = "otel"
        otel.title = "Review OTel Helm values"
        otel.dueDate = iso(1)

        return [otel, standup, keys, tls]   // deliberately out of order
    }

    private static func mockupNotes() -> [StickyNote] {
        let newest = StickyNote(
            id: "vpc", title: "Ask Ravi about VPC peering",
            text: "He owns the 10.42/16 range. Needs a ticket before Friday.",
            color: .yellow, x: 0, y: 0, width: 200, height: 200,
            rotationDegrees: 0, createdAt: now.addingTimeInterval(-3 * 24 * 3600)
        )
        let untitled = StickyNote(
            id: "untitled", title: "",
            text: "call the bank\nask about the fee",
            color: .blue, x: 0, y: 0, width: 200, height: 200,
            rotationDegrees: 0, createdAt: now.addingTimeInterval(-9 * 24 * 3600)
        )
        let middle = StickyNote(
            id: "grafana", title: "Grafana board for the new collector",
            text: "Two rows: OTLP ingest and exporter queue depth.",
            color: .green, x: 0, y: 0, width: 200, height: 200,
            rotationDegrees: 0, createdAt: now.addingTimeInterval(-6 * 24 * 3600)
        )
        return [untitled, newest, middle]   // deliberately out of order
    }

    /// The mockup's own day: four dated tasks **plus two undated open ones**,
    /// which is what makes its footer read "3 of 6 open" rather than "3 of 3".
    private static func mockupSnapshot() -> GrandLineWidgetSnapshot {
        var backlogA = ShiftTask.fresh(now: now)
        backlogA.id = "backlog-a"
        backlogA.title = "Read the OTel spec"
        var backlogB = ShiftTask.fresh(now: now)
        backlogB.id = "backlog-b"
        backlogB.title = "Tidy the runbooks index"
        return WidgetSnapshotPublisher.snapshot(
            tasks: mockupTasks() + [backlogA, backlogB],
            followUps: [pendingFollowUp("a"), pendingFollowUp("b"), doneFollowUp("c")],
            notes: mockupNotes(),
            now: now,
            availability: .ready,
            appearance: .dark,
            calendar: calendar
        )
    }

    private static func pendingFollowUp(_ id: String) -> ShiftFollowUp {
        var followUp = ShiftFollowUp.fresh()
        followUp.id = id
        followUp.status = .pending
        return followUp
    }

    private static func doneFollowUp(_ id: String) -> ShiftFollowUp {
        var followUp = ShiftFollowUp.fresh()
        followUp.id = id
        followUp.status = .done
        return followUp
    }

    private static func scratchDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-selftest-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Discriminating power
    //
    // AGENTS.md: "assert the fixture's own discriminating power first - that
    // the numbers really differ". Every case below leans on the fixture
    // spanning yesterday/today/tomorrow with two priorities and one
    // recurrence, so a fixture that drifted into "four identical tasks" would
    // let half this suite pass vacuously.

    private static func checkTheFixtureIsWhatItClaims(_ check: (Bool, String) -> Void) {
        let tasks = mockupTasks()
        let instants = tasks.compactMap { WidgetSnapshotPublisher.dueInstant(for: $0, calendar: calendar) }
        check(instants.count == 4, "fixture: every mockup task should have a parseable due instant")
        // Three distinct instants, not four: the mockup's two "today" rows
        // both have no due time, so they land on the same start-of-day - which
        // is deliberate here, because it is what exercises the ordering's
        // stable tiebreak by id (two tasks at the same minute must not swap
        // between refreshes).
        check(Set(instants).count == 3,
              "fixture: the mockup's two untimed today rows should share an instant, and the rest differ (got \(Set(instants).count))")
        check(instants.contains { $0 < now }, "fixture: at least one task must be genuinely in the past")
        check(instants.contains { $0 > now }, "fixture: at least one task must be genuinely in the future")
        check(tasks.contains { $0.priority == .high } && tasks.contains { $0.priority != .high },
              "fixture: both priority branches must be represented")
        check(tasks.contains { $0.recurrence != nil } && tasks.contains { $0.recurrence == nil },
              "fixture: both the recurring and the one-off branch must be represented")

        // The pinned instant really is the mockup's own Monday, in the
        // calendar this suite pins - so the medium family's header is
        // asserted against a real day rather than whatever today happens to
        // be on the runner.
        // The mockup writes this as "Monday 21 September"; the app writes
        // whatever the captain's own locale does, since `headline` goes
        // through `setLocalizedDateFormatFromTemplate`. The assertion is
        // against this suite's pinned POSIX locale, so the *day* is asserted
        // without pinning one region's word order.
        check(GrandLineWidgetDigest.headline(for: now, calendar: calendar) == "Monday, September 21",
              "fixture: the pinned clock should be Monday 21 September, the mockup's own day (got \(GrandLineWidgetDigest.headline(for: now, calendar: calendar)))")

        let notes = mockupNotes()
        check(Set(notes.map(\.createdAt)).count == 3, "fixture: the three notes' creation dates must differ")
        check(notes.contains { $0.title.isEmpty }, "fixture: one note must be untitled, to exercise the title fallback")
    }

    // MARK: The projection

    private static func checkTheProjectionFromRealStoreTypes(_ check: (Bool, String) -> Void) {
        var cancelled = ShiftTask.fresh(now: now)
        cancelled.id = "cancelled"
        cancelled.status = .cancelled
        cancelled.dueDate = "2026-09-21"

        var undated = ShiftTask.fresh(now: now)
        undated.id = "undated"
        undated.title = "Read the OTel spec"

        let snapshot = WidgetSnapshotPublisher.snapshot(
            tasks: mockupTasks() + [cancelled, undated],
            followUps: [pendingFollowUp("a"), pendingFollowUp("b"), doneFollowUp("c")],
            notes: mockupNotes(),
            now: now,
            availability: .ready,
            appearance: .light,
            calendar: calendar
        )

        check(snapshot.schemaVersion == GrandLineWidgetSnapshot.currentSchemaVersion,
              "the publisher should stamp the current schema version")
        check(snapshot.appearance == .light, "the register should travel in the snapshot")
        check(snapshot.availability == .ready, "an unlocked publish should be .ready")

        // A cancelled task is neither a row nor an open task; an undated one
        // is an open task but never a row.
        check(snapshot.openTaskCount == 5,
              "openTaskCount should count the four dated tasks plus the undated one, and not the cancelled one (got \(snapshot.openTaskCount))")
        check(snapshot.tasks.count == 4,
              "only dated, open tasks should be carried (got \(snapshot.tasks.count))")
        check(!snapshot.tasks.contains { $0.id == "cancelled" }, "a cancelled task must not reach the widget")
        check(!snapshot.tasks.contains { $0.id == "undated" }, "an undated task must not reach the widget")
        check(snapshot.pendingFollowUpCount == 2,
              "only pending follow-ups should be counted (got \(snapshot.pendingFollowUpCount))")

        // Sorted soonest-first by the publisher, so the extension never has
        // to re-sort a file it did not write.
        check(snapshot.tasks.map(\.id) == ["tls", "keys", "standup", "otel"],
              "the snapshot's tasks should be ordered soonest-first (got \(snapshot.tasks.map(\.id)))")

        let tls = snapshot.tasks.first { $0.id == "tls" }
        check(tls?.hasDueTime == true, "a task with a due time should say so")
        check(tls?.priority == "high", "the priority should travel as its raw value")
        check(tls?.dueAt == calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 9, minute: 0)),
              "a date+time task's instant should combine both fields")

        let keys = snapshot.tasks.first { $0.id == "keys" }
        check(keys?.hasDueTime == false, "a task with no due time should say so")
        check(keys?.dueAt == calendar.startOfDay(for: now),
              "a task with no due time should land on the start of its own day")

        let standup = snapshot.tasks.first { $0.id == "standup" }
        // The wording comes from the app's one derivation, never a second one
        // in the extension.
        check(standup?.recurrenceSummary == "Every weekday",
              "the recurrence summary should be ShiftRecurrence.displayName verbatim (got \(standup?.recurrenceSummary ?? "nil"))")
        check(keys?.recurrenceSummary == nil, "a one-off task should carry no recurrence summary")

        // Notes: newest first, the app's own title fallback, and the literal
        // paper/ink pair rather than a colour name the extension would have
        // to re-resolve.
        check(snapshot.stickies.map(\.id) == ["vpc", "grafana", "untitled"],
              "notes should be carried newest-first (got \(snapshot.stickies.map(\.id)))")
        let untitledNote = snapshot.stickies.first { $0.id == "untitled" }
        check(untitledNote?.title == "call the bank",
              "an untitled note should borrow its first line, the same rule \u{2318}K uses (got \(untitledNote?.title ?? "nil"))")
        let vpc = snapshot.stickies.first { $0.id == "vpc" }
        check(vpc?.paperHex == StickyNoteColor.yellow.paperHex && vpc?.inkHex == StickyNoteColor.yellow.inkHex,
              "a note should carry its own literal paper and ink, not a colour name")

        // GL-35: caps. A board with more notes than the snapshot carries is
        // truncated rather than shipped whole.
        let many = (0..<40).map { index in
            StickyNote(id: "n\(index)", title: "note \(index)", text: String(repeating: "x", count: 900),
                       color: .pink, x: 0, y: 0, width: 200, height: 200, rotationDegrees: 0,
                       createdAt: now.addingTimeInterval(Double(-index) * 60))
        }
        let capped = WidgetSnapshotPublisher.snapshot(
            tasks: [], followUps: [], notes: many, now: now,
            availability: .ready, calendar: calendar
        )
        check(capped.stickies.count == GrandLineWidgetSnapshot.stickyLimit,
              "the snapshot should cap the notes it carries (got \(capped.stickies.count))")
        check(capped.stickies.allSatisfy { $0.body.count <= GrandLineWidgetSnapshot.stickyBodyLimit },
              "a note's body should be truncated before it leaves the app's own storage")
    }

    private static func checkALockedSnapshotCarriesNothing(_ check: (Bool, String) -> Void) {
        let locked = WidgetSnapshotPublisher.snapshot(
            tasks: mockupTasks(),
            followUps: [pendingFollowUp("a")],
            notes: mockupNotes(),
            now: now,
            availability: .locked,
            appearance: .light,
            calendar: calendar
        )
        // GL-09. The point of publishing a locked snapshot rather than
        // declining to publish is that it *overwrites* what is already on the
        // desktop - so the assertion that matters is that nothing survives.
        check(locked.availability == .locked, "a locked publish should be marked locked")
        check(locked.tasks.isEmpty, "a locked snapshot must carry no tasks")
        check(locked.stickies.isEmpty, "a locked snapshot must carry no notes")
        check(locked.openTaskCount == 0 && locked.pendingFollowUpCount == 0,
              "a locked snapshot must carry no counts either - \"3 due today\" is itself a disclosure")
        check(locked.appearance == .light,
              "the locked state should still be drawn in the captain's own register")

        // And the state a widget sees for it is `.locked`, not
        // `.ready(empty)` - which is the difference between "Locked" and
        // "Nothing due".
        let directory = scratchDirectory("locked")
        let url = directory.appendingPathComponent(GrandLineWidgetContainer.snapshotFileName)
        try? GrandLineWidgetSnapshot.makeEncoder().encode(locked).write(to: url)
        check(GrandLineWidgetDigest.load(from: url) == .locked,
              "a locked snapshot should load as .locked rather than as an empty day")
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: The digest

    private static func checkTheDigestMatchesTheReviewedMockup(_ check: (Bool, String) -> Void) {
        let digest = GrandLineWidgetDigest.taskDigest(
            from: mockupSnapshot(), now: now, calendar: calendar, limit: 4
        )

        check(digest.rows.map(\.title) == [
            "Renew wildcard TLS certificate",
            "Rotate the prod bastion SSH keys",
            "Standup notes",
            "Review OTel Helm values"
        ], "the medium family's four rows should be the mockup's own, in its own order (got \(digest.rows.map(\.title)))")

        check(digest.rows.map(\.urgency) == [.overdue, .today, .today, .tomorrow],
              "the four rows' urgency should be overdue/today/today/tomorrow (got \(digest.rows.map(\.urgency.rawValue)))")

        // The mockup's own four sub-labels, with the one deliberate change
        // documented on `GrandLineWidgetDigest.detail`: a recurring task
        // keeps its *when* and gains a marker, rather than the rule's wording
        // replacing the due day.
        check(digest.rows.map(\.detail) == ["overdue", "High \u{b7} today", "today \u{b7} repeats", "tomorrow"],
              "the sub-labels should follow the documented precedence (got \(digest.rows.map(\.detail)))")

        check(digest.lateCount == 1, "exactly one of the mockup's tasks is late (got \(digest.lateCount))")
        check(digest.openSummary == "4 of 6 open",
              "the footer should count rows against every open task (got \(digest.openSummary))")
        check(digest.followUpSummary == "2 follow-ups pending",
              "the follow-up line should be pluralised off the real count (got \(digest.followUpSummary ?? "nil"))")
        check(!digest.isStale, "a snapshot generated at `now` is not stale")

        // The small family shows three of the same four, in the same order -
        // a limit, not a different selection.
        let small = GrandLineWidgetDigest.taskDigest(
            from: mockupSnapshot(), now: now, calendar: calendar, limit: 3
        )
        check(small.rows.map(\.id) == Array(digest.rows.map(\.id).prefix(3)),
              "the small family should show the first three of the same ordering")
        check(small.lateCount == digest.lateCount,
              "the late count is a property of the day, not of how many rows fit")
        check(small.openSummary == "3 of 6 open",
              "the small family's footer should count its own rows (got \(small.openSummary))")

        // One follow-up reads singular, none reads as nothing at all rather
        // than "0 follow-ups".
        let oneFollowUp = WidgetSnapshotPublisher.snapshot(
            tasks: mockupTasks(), followUps: [pendingFollowUp("a")], notes: [], now: now,
            availability: .ready, calendar: calendar
        )
        check(GrandLineWidgetDigest.taskDigest(from: oneFollowUp, now: now, calendar: calendar, limit: 4)
            .followUpSummary == "1 follow-up pending", "one follow-up should read singular")
        let noFollowUps = WidgetSnapshotPublisher.snapshot(
            tasks: mockupTasks(), followUps: [], notes: [], now: now,
            availability: .ready, calendar: calendar
        )
        check(GrandLineWidgetDigest.taskDigest(from: noFollowUps, now: now, calendar: calendar, limit: 4)
            .followUpSummary == nil, "no follow-ups should produce no line at all, never \"0 follow-ups\"")
    }

    private static func checkUrgencyFollowsTheEntryClock(_ check: (Bool, String) -> Void) {
        // AGENTS.md's injectable-clock rule, and the one thing a widget gets
        // wrong more than anything else: WidgetKit renders an entry at an
        // instant it chose, which is not the instant the code ran. The same
        // snapshot, read at two clocks, must disagree.
        let snapshot = mockupSnapshot()
        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 8, minute: 0))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 20, minute: 0))!

        let atMorning = GrandLineWidgetDigest.taskDigest(from: snapshot, now: morning, calendar: calendar, limit: 4)
        let atEvening = GrandLineWidgetDigest.taskDigest(from: snapshot, now: evening, calendar: calendar, limit: 4)

        check(atMorning.rows.map(\.urgency) != atEvening.rows.map(\.urgency),
              "the same snapshot read at two clocks must not produce the same urgencies - otherwise this check proves nothing")
        check(atMorning.lateCount == 1,
              "at 08:00 on the 21st only yesterday's task is late (got \(atMorning.lateCount))")
        // Three, not four: the fourth is the task due *on* the 22nd with no
        // due time, and an untimed task is not late on its own day however
        // late in that day it is read. That asymmetry is the whole reason the
        // publisher records `hasDueTime`.
        check(atEvening.lateCount == 3,
              "by the evening of the 22nd the three earlier tasks are late (got \(atEvening.lateCount))")

        // A task with no due time must not read overdue for the whole of the
        // day it is due - the reason the publisher records `hasDueTime` at
        // all.
        let keysRow = atMorning.rows.first { $0.id == "keys" }
        check(keysRow?.urgency == .today,
              "a task due today with no time should read .today in the morning, not .overdue")
        let lateInTheDay = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 23, minute: 30))!
        let atNight = GrandLineWidgetDigest.taskDigest(from: snapshot, now: lateInTheDay, calendar: calendar, limit: 4)
        check(atNight.rows.first { $0.id == "keys" }?.urgency == .today,
              "\u{2026} and still .today at 23:30, since it never named a time")

        // A task that *did* name a time flips the moment it passes.
        var timed = ShiftTask.fresh(now: now)
        timed.id = "timed"
        timed.title = "Deploy the collector"
        timed.dueDate = "2026-09-21"
        timed.dueTime = "15:00"
        let timedSnapshot = WidgetSnapshotPublisher.snapshot(
            tasks: [timed], followUps: [], notes: [], now: now, availability: .ready, calendar: calendar
        )
        let before = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 14, minute: 59))!
        let after = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 15, minute: 1))!
        check(GrandLineWidgetDigest.taskDigest(from: timedSnapshot, now: before, calendar: calendar, limit: 4)
            .rows.first?.urgency == .today, "a timed task is .today one minute before its time")
        check(GrandLineWidgetDigest.taskDigest(from: timedSnapshot, now: after, calendar: calendar, limit: 4)
            .rows.first?.urgency == .overdue, "\u{2026} and .overdue one minute after it")
        // The expected string is *formatted*, not written out. Two reasons,
        // both measured: this suite pins the POSIX locale, so the app's own
        // `jm` template renders "3:00 PM" rather than "15:00" - and macOS
        // separates the minutes from the meridiem with U+202F (a narrow
        // no-break space), so a hand-typed literal fails on a character that
        // is invisible in the diff.
        let expectedTime: String = {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale
            formatter.setLocalizedDateFormatFromTemplate("jm")
            return formatter.string(from: calendar.date(
                from: DateComponents(year: 2026, month: 9, day: 21, hour: 15, minute: 0)
            )!)
        }()
        let timedDetail = GrandLineWidgetDigest
            .taskDigest(from: timedSnapshot, now: before, calendar: calendar, limit: 4)
            .rows.first?.detail
        check(timedDetail == "today \(expectedTime)",
              "a timed task's sub-label should name the time (got \(timedDetail ?? "nil"))")
        check(expectedTime.contains("3"), "\u{2026} and the expectation itself must really contain a clock time")
    }

    private static func checkTheHorizonAndUndatedTasks(_ check: (Bool, String) -> Void) {
        var far = ShiftTask.fresh(now: now)
        far.id = "far"
        far.title = "Q4 capacity review"
        far.dueDate = "2026-11-02"

        var justInside = ShiftTask.fresh(now: now)
        justInside.id = "inside"
        justInside.title = "Renew the runner token"
        justInside.dueDate = "2026-09-27"      // six days out, inside the 7-day horizon

        var justOutside = ShiftTask.fresh(now: now)
        justOutside.id = "outside"
        justOutside.title = "Archive the old buckets"
        justOutside.dueDate = "2026-09-29"     // eight days out

        let snapshot = WidgetSnapshotPublisher.snapshot(
            tasks: [far, justInside, justOutside], followUps: [], notes: [], now: now,
            availability: .ready, calendar: calendar
        )
        check(snapshot.tasks.count == 3, "all three dated tasks should be carried in the snapshot")

        let digest = GrandLineWidgetDigest.taskDigest(from: snapshot, now: now, calendar: calendar, limit: 4)
        check(digest.rows.map(\.id) == ["inside"],
              "only a task inside the \(GrandLineWidgetDigest.horizonDays)-day horizon should be a row (got \(digest.rows.map(\.id)))")
        check(digest.rows.first?.urgency == .soon, "a task six days out should read .soon")
        check(digest.rows.first?.detail.contains("Sep") == true,
              "a .soon task's sub-label should name its day (got \(digest.rows.first?.detail ?? "nil"))")
        check(digest.openTaskCount == 3,
              "a task beyond the horizon is still open and still counted (got \(digest.openTaskCount))")
        check(digest.lateCount == 0, "nothing here is late")
    }

    private static func checkStaleness(_ check: (Bool, String) -> Void) {
        // GL-14's subtler half: the captain has to be able to tell a quiet
        // day from an app that has not run since Friday.
        let old = GrandLineWidgetSnapshot(
            generatedAt: now.addingTimeInterval(-3 * 24 * 3600),
            availability: .ready,
            tasks: mockupSnapshot().tasks,
            openTaskCount: 6
        )
        let staleDigest = GrandLineWidgetDigest.taskDigest(from: old, now: now, calendar: calendar, limit: 4)
        check(staleDigest.isStale, "a snapshot three days old should be marked stale")
        check(!staleDigest.rows.isEmpty,
              "a stale snapshot is still drawn - overdue is still overdue - so this is a label, not a blank")

        let fresh = GrandLineWidgetDigest.taskDigest(
            from: mockupSnapshot(), now: now.addingTimeInterval(600), calendar: calendar, limit: 4
        )
        check(!fresh.isStale, "a ten-minute-old snapshot is not stale - otherwise the flag never discriminates")
    }

    private static func checkStickyOrderingAndPinning(_ check: (Bool, String) -> Void) {
        let snapshot = mockupSnapshot()

        let unpinned = GrandLineWidgetDigest.stickyRows(from: snapshot, preferredID: nil, limit: 1)
        check(unpinned.map(\.id) == ["vpc"], "an unconfigured widget should show the newest note")
        check(GrandLineWidgetDigest.stickyKicker(preferredID: nil, resolvedID: unpinned.first?.id) == "STICKY \u{b7} NEWEST",
              "\u{2026} and say so in its kicker, because that note changes under the captain")

        let pinned = GrandLineWidgetDigest.stickyRows(from: snapshot, preferredID: "untitled", limit: 1)
        check(pinned.map(\.id) == ["untitled"], "a configured widget should show the note the captain chose")
        check(GrandLineWidgetDigest.stickyKicker(preferredID: "untitled", resolvedID: "untitled") == "STICKY \u{b7} PINNED",
              "\u{2026} and say PINNED")

        // A note deleted since the widget was configured: it falls back to
        // the newest, and the kicker tells the truth about which one this is.
        let missing = GrandLineWidgetDigest.stickyRows(from: snapshot, preferredID: "deleted-note", limit: 1)
        check(missing.map(\.id) == ["vpc"], "a configured note that no longer exists should fall back to the newest")
        check(GrandLineWidgetDigest.stickyKicker(preferredID: "deleted-note", resolvedID: missing.first?.id) == "STICKY \u{b7} NEWEST",
              "\u{2026} and must not still claim PINNED")

        // The medium family's per-note badge: the marker on the pinned note,
        // nothing on the others - derived from the same comparison, so the two
        // surfaces cannot disagree about which note is pinned.
        check(GrandLineWidgetDigest.stickyBadge(preferredID: "untitled", resolvedID: "untitled")
              == GrandLineWidgetDigest.pinnedMarker,
              "the medium family should badge a pinned note")
        check(GrandLineWidgetDigest.stickyBadge(preferredID: "untitled", resolvedID: "vpc") == nil,
              "\u{2026} and badge nothing on the notes beside it")
        check(GrandLineWidgetDigest.stickyBadge(preferredID: nil, resolvedID: "vpc") == nil,
              "\u{2026} and nothing at all when no note is pinned")
        check(GrandLineWidgetDigest.stickyKicker(preferredID: "untitled", resolvedID: "untitled")
              .hasSuffix(GrandLineWidgetDigest.pinnedMarker),
              "both surfaces should use the one pinned marker")

        // The medium family: three notes, pinned one first, rest newest-first.
        let three = GrandLineWidgetDigest.stickyRows(from: snapshot, preferredID: "untitled", limit: 3)
        check(three.map(\.id) == ["untitled", "vpc", "grafana"],
              "the medium family should hoist the pinned note and keep the rest newest-first (got \(three.map(\.id)))")

        check(GrandLineWidgetDigest.stickyRows(from: snapshot, preferredID: nil, limit: 3).map(\.id)
              == ["vpc", "grafana", "untitled"],
              "unpinned, the order is purely newest-first - otherwise the hoist above proves nothing")
    }

    // MARK: GL-14 / GL-01 - the states that are not data

    private static func checkUnavailableStates(_ check: (Bool, String) -> Void) {
        let directory = scratchDirectory("states")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(GrandLineWidgetContainer.snapshotFileName)

        check(GrandLineWidgetDigest.load(from: url) == .unavailable(.neverPublished),
              "a missing snapshot should load as .neverPublished, never as an empty day")

        try? Data("not json".utf8).write(to: url)
        check(GrandLineWidgetDigest.load(from: url) == .unavailable(.unreadable),
              "a corrupt snapshot should load as .unreadable (GL-01: present-but-unreadable is its own state)")

        // A file from a newer build is refused whole rather than
        // half-decoded - the app and the extension are two binaries that can
        // run out of step.
        var newer = mockupSnapshot()
        newer.schemaVersion = GrandLineWidgetSnapshot.currentSchemaVersion + 1
        try? GrandLineWidgetSnapshot.makeEncoder().encode(newer).write(to: url)
        check(GrandLineWidgetDigest.load(from: url) == .unavailable(.schemaTooNew),
              "a snapshot from a newer build should load as .schemaTooNew")

        var versionless = mockupSnapshot()
        versionless.schemaVersion = 0
        try? GrandLineWidgetSnapshot.makeEncoder().encode(versionless).write(to: url)
        check(GrandLineWidgetDigest.load(from: url) == .unavailable(.unreadable),
              "a snapshot with no usable version should be refused rather than guessed at")

        // Discriminating power: the same path with a *valid* file must load,
        // or every check above passes for the wrong reason.
        try? GrandLineWidgetSnapshot.makeEncoder().encode(mockupSnapshot()).write(to: url)
        guard case .ready(let loaded) = GrandLineWidgetDigest.load(from: url) else {
            check(false, "a valid snapshot at the same path must load as .ready")
            return
        }
        check(loaded.tasks.count == 4, "the valid snapshot should round-trip its four tasks")

        // Every unavailable reason has its own copy, and none of it reads as
        // "nothing due" - which is the whole of GL-14 for this feature.
        for reason in [GrandLineWidgetDigest.Unavailable.neverPublished, .unreadable, .schemaTooNew] {
            check(!reason.headline.isEmpty && !reason.detail.isEmpty,
                  "\(reason.rawValue): both the headline and the detail should say something")
            let text = (reason.headline + " " + reason.detail).lowercased()
            check(!text.contains("nothing due") && !text.contains("0 tasks") && !text.contains("no tasks"),
                  "\(reason.rawValue): an unavailable state must not borrow the wording of a finished day (GL-14)")
        }
    }

    // MARK: The round trip

    private static func checkTheRoundTripThroughTheSharedContainer(_ check: (Bool, String) -> Void) {
        let directory = scratchDirectory("roundtrip")
        defer { try? FileManager.default.removeItem(at: directory) }

        var reloads = 0
        let publisher = WidgetSnapshotPublisher(
            shiftStore: ShiftStore(),
            stickyStore: StickyBoardStore(root: directory.appendingPathComponent("sticky", isDirectory: true)),
            directory: directory,
            calendar: calendar,
            clock: { now },
            reloadTimelines: { reloads += 1 }
        )

        let snapshot = mockupSnapshot()
        check(publisher.write(snapshot), "the first write should happen")
        check(reloads == 1, "a write should reload the timelines exactly once (got \(reloads))")

        guard case .ready(let loaded) = GrandLineWidgetDigest.load(from: publisher.snapshotURL) else {
            check(false, "the written snapshot should load back as .ready")
            return
        }
        check(loaded == snapshot,
              "the snapshot should survive the round trip byte-for-byte in value terms - one encoder, one decoder, one date strategy")

        // A re-publish of identical content is dropped before the write, so
        // a noisy store observer costs a comparison rather than a write plus
        // a timeline reload (GL-13's own instinct).
        var later = snapshot
        later.generatedAt = now.addingTimeInterval(90)
        check(!publisher.write(later), "a publish that only moves `generatedAt` should be dropped")
        check(reloads == 1, "\u{2026} and must not reload the timelines again (got \(reloads))")

        var changed = snapshot
        changed.generatedAt = now.addingTimeInterval(120)
        changed.openTaskCount = 9
        check(publisher.write(changed), "a publish whose content really changed should happen")
        check(reloads == 2, "\u{2026} and should reload the timelines (got \(reloads))")

        check(WidgetSnapshotPublisher.isEquivalent(snapshot, later),
              "isEquivalent should ignore generatedAt")
        check(!WidgetSnapshotPublisher.isEquivalent(snapshot, changed),
              "\u{2026} and nothing else - otherwise the dedupe above would swallow real changes")
    }

    private static func checkTheContainerHonoursItsOverride(_ check: (Bool, String) -> Void) {
        // Every store in this app honours an `FM_*` override, and this one is
        // the store whose *default* location is the shared App Group
        // container - so the override is also what keeps a suite out of the
        // captain's real widgets (see `main.swift`'s `#if FM_SELFTESTS`
        // block).
        let override = "/tmp/fm-widget-dir-check"
        let directory = GrandLineWidgetContainer.directory(
            environment: [GrandLineWidgetContainer.directoryOverrideVariable: override]
        )
        check(directory.path == override,
              "FM_WIDGET_DIR should be honoured verbatim (got \(directory.path))")
        check(GrandLineWidgetContainer.snapshotURL(
            environment: [GrandLineWidgetContainer.directoryOverrideVariable: override]
        ).lastPathComponent == GrandLineWidgetContainer.snapshotFileName,
              "the snapshot should sit directly in the overridden directory")

        let noOverride = GrandLineWidgetContainer.directory(environment: [:])
        check(noOverride.path != override, "with no override the directory must be something else")
        check(noOverride.path.contains("GrandLineWidgets"),
              "the default directory should be namespaced (got \(noOverride.path))")
        // The measured fact this whole feature's signing note rests on: for
        // an unsandboxed process the App Group container resolves to a path
        // without any entitlement check. The app half works today; the
        // extension half is what needs the Team ID.
        check(noOverride.path.contains("Group Containers") || noOverride.path.contains("Application Support"),
              "the default should be the App Group container, or the documented fallback (got \(noOverride.path))")
    }

    // MARK: The reverse channel

    private static func checkTheActionQueueRoundTrips(_ check: (Bool, String) -> Void) {
        let directory = scratchDirectory("actions")
        defer { try? FileManager.default.removeItem(at: directory) }
        let actions = directory.appendingPathComponent(GrandLineWidgetContainer.actionsDirectoryName, isDirectory: true)

        check(GrandLineWidgetAction.pending(directory: actions).requests.isEmpty,
              "an unused queue directory should be empty rather than an error")

        // Deliberately enqueued newest-first, to prove the drain re-orders.
        let second = GrandLineWidgetAction.Request(
            id: "b", kind: .completeTask, taskID: "keys", requestedAt: now.addingTimeInterval(60)
        )
        let first = GrandLineWidgetAction.Request(
            id: "a", kind: .completeTask, taskID: "tls", requestedAt: now
        )
        do {
            try GrandLineWidgetAction.enqueue(second, directory: actions)
            try GrandLineWidgetAction.enqueue(first, directory: actions)
        } catch {
            check(false, "enqueueing a widget action should not throw: \(error)")
            return
        }

        let found = GrandLineWidgetAction.pending(directory: actions)
        check(found.requests.map(\.request.id) == ["a", "b"],
              "the queue should come back oldest-first regardless of write order (got \(found.requests.map(\.request.id)))")
        check(found.requests.map(\.request.taskID) == ["tls", "keys"], "each request should carry its task id")
        check(found.unreadable.isEmpty, "nothing here is unreadable")
        check(found.requests.allSatisfy { $0.url.lastPathComponent == "\($0.request.id).json" },
              "one file per request, named by its id - which is what makes two processes safe with no file coordination")

        // GL-01: a file this build cannot decode is its own state, reported
        // rather than silently skipped.
        let junk = actions.appendingPathComponent("junk.json")
        try? Data("{\"kind\":\"somethingElse\"}".utf8).write(to: junk)
        let withJunk = GrandLineWidgetAction.pending(directory: actions)
        check(withJunk.unreadable.map(\.lastPathComponent) == ["junk.json"],
              "an undecodable action should be reported as unreadable (got \(withJunk.unreadable.map(\.lastPathComponent)))")
        check(withJunk.requests.count == 2, "\u{2026} and must not take the readable ones down with it")
        try? FileManager.default.removeItem(at: junk)

        // GL-35: nothing unbounded. A drain that never runs must not let the
        // queue grow forever.
        for index in 0..<(GrandLineWidgetAction.queueCap + 10) {
            try? GrandLineWidgetAction.enqueue(
                GrandLineWidgetAction.Request(
                    id: "bulk-\(index)", kind: .completeTask, taskID: "t\(index)",
                    requestedAt: now.addingTimeInterval(Double(index) * 10)
                ),
                directory: actions
            )
        }
        let capped = GrandLineWidgetAction.pending(directory: actions)
        check(capped.requests.count <= GrandLineWidgetAction.queueCap,
              "the queue should be capped at \(GrandLineWidgetAction.queueCap) (got \(capped.requests.count))")
        check(capped.requests.last?.request.id == "bulk-\(GrandLineWidgetAction.queueCap + 9)",
              "pruning should drop the oldest and keep the newest tap (got \(capped.requests.last?.request.id ?? "nil"))")
    }

    private static func checkTheDrainAppliesThroughTheRealStore(_ check: (Bool, String) -> Void) {
        let scratch = scratchDirectory("drain")
        defer { try? FileManager.default.removeItem(at: scratch) }

        // A real `ShiftStore` against a scratch root, so the drain is proven
        // to go through `setTaskCompleted` - the same call the Tasks page's
        // own checkbox makes, which is what makes a ticked *recurring* task
        // advance its series.
        let shiftRoot = scratch.appendingPathComponent("tasks", isDirectory: true)
        setenv("FM_SHIFT_DIR", shiftRoot.path, 1)
        defer { unsetenv("FM_SHIFT_DIR") }
        let store = ShiftStore()

        var plain = ShiftTask.fresh(now: now)
        plain.id = "plain"
        plain.title = "Rotate the prod bastion SSH keys"
        plain.dueDate = "2026-09-21"
        store.addTask(plain)

        var repeating = ShiftTask.fresh(now: now)
        repeating.id = "repeating"
        repeating.title = "Standup notes"
        repeating.dueDate = "2026-09-21"
        repeating.recurrence = ShiftRecurrence(frequency: .weekly, weekdays: ShiftRecurrence.weekdaySet)
        store.addTask(repeating)

        let wasLocked = AppLockGate.shared.isLocked
        AppLockGate.shared.setLocked(false)
        defer { AppLockGate.shared.setLocked(wasLocked) }

        let widgetDirectory = scratch.appendingPathComponent("widgets", isDirectory: true)
        let publisher = WidgetSnapshotPublisher(
            shiftStore: store,
            stickyStore: StickyBoardStore(root: scratch.appendingPathComponent("sticky", isDirectory: true)),
            directory: widgetDirectory,
            calendar: calendar,
            clock: { now },
            reloadTimelines: {}
        )

        try? GrandLineWidgetAction.enqueue(
            GrandLineWidgetAction.Request(kind: .completeTask, taskID: "plain", requestedAt: now),
            directory: publisher.actionsDirectory
        )
        try? GrandLineWidgetAction.enqueue(
            GrandLineWidgetAction.Request(kind: .completeTask, taskID: "repeating", requestedAt: now.addingTimeInterval(1)),
            directory: publisher.actionsDirectory
        )

        check(store.activeTasks.count == 2, "both fixture tasks should start active (got \(store.activeTasks.count))")

        let applied = publisher.drainPendingActions(now: now)
        check(applied == 2, "both queued ticks should apply (got \(applied))")
        check(GrandLineWidgetAction.pending(directory: publisher.actionsDirectory).requests.isEmpty,
              "an applied request's file should be deleted")

        check(!store.activeTasks.contains { $0.id == "plain" },
              "the ticked one-off task should no longer be active")
        check(store.allCompletedTasks().contains { $0.id == "plain" },
              "\u{2026} and should be in the completed file, exactly as the in-app checkbox would leave it")

        // The reason the tick goes through the store rather than writing YAML
        // itself: completing an occurrence is what schedules the next one.
        let spawned = store.activeTasks.first { $0.title == "Standup notes" }
        check(spawned != nil, "ticking a recurring task from the widget should spawn its next occurrence")
        check(spawned?.id != "repeating", "\u{2026} as a new task, not the same one left behind")
        check(spawned?.dueDate == "2026-09-22",
              "\u{2026} due the next weekday (got \(spawned?.dueDate ?? "nil"))")

        // A stale tap for a task that is already gone is a no-op, not an
        // error - the widget's row can outlive the task by a refresh.
        try? GrandLineWidgetAction.enqueue(
            GrandLineWidgetAction.Request(kind: .completeTask, taskID: "plain", requestedAt: now.addingTimeInterval(2)),
            directory: publisher.actionsDirectory
        )
        let staleApplied = publisher.drainPendingActions(now: now)
        check(staleApplied == 1, "a stale tap should still be consumed rather than retried forever")
        check(GrandLineWidgetAction.pending(directory: publisher.actionsDirectory).requests.isEmpty,
              "\u{2026} and its file removed")

        // An unreadable request is deleted deliberately: it is a button
        // press, not captain-authored data, so there is nothing to recover.
        try? FileManager.default.createDirectory(at: publisher.actionsDirectory, withIntermediateDirectories: true)
        let junk = publisher.actionsDirectory.appendingPathComponent("broken.json")
        try? Data("{}".utf8).write(to: junk)
        _ = publisher.drainPendingActions(now: now)
        check(!FileManager.default.fileExists(atPath: junk.path),
              "an unreadable queued action should be discarded rather than retried on every activation")
    }

    private static func checkALockedAppHoldsQueuedActions(_ check: (Bool, String) -> Void) {
        let scratch = scratchDirectory("locked-drain")
        defer { try? FileManager.default.removeItem(at: scratch) }

        setenv("FM_SHIFT_DIR", scratch.appendingPathComponent("tasks", isDirectory: true).path, 1)
        defer { unsetenv("FM_SHIFT_DIR") }
        let store = ShiftStore()
        var task = ShiftTask.fresh(now: now)
        task.id = "held"
        task.title = "Rotate the prod bastion SSH keys"
        task.dueDate = "2026-09-21"
        store.addTask(task)

        let publisher = WidgetSnapshotPublisher(
            shiftStore: store,
            stickyStore: StickyBoardStore(root: scratch.appendingPathComponent("sticky", isDirectory: true)),
            directory: scratch.appendingPathComponent("widgets", isDirectory: true),
            calendar: calendar,
            clock: { now },
            reloadTimelines: {}
        )
        try? GrandLineWidgetAction.enqueue(
            GrandLineWidgetAction.Request(kind: .completeTask, taskID: "held", requestedAt: now),
            directory: publisher.actionsDirectory
        )

        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }

        // GL-09. A widget button is on the desktop, outside every overlay
        // this app can draw, so the gate is the only thing between a
        // passer-by and the captain's task list.
        AppLockGate.shared.setLocked(true)
        check(publisher.drainPendingActions(now: now) == 0,
              "a locked app must not apply a widget tap")
        check(store.activeTasks.contains { $0.id == "held" },
              "\u{2026} and the task must still be active")
        check(GrandLineWidgetAction.pending(directory: publisher.actionsDirectory).requests.count == 1,
              "\u{2026} and the request must be *kept*, not dropped - the captain did tap it")

        // And a locked publish overwrites whatever is on the desktop.
        check(publisher.publishNow(), "a locked app should still publish, to overwrite what is on screen")
        check(GrandLineWidgetDigest.load(from: publisher.snapshotURL) == .locked,
              "\u{2026} with a locked snapshot")

        // Discriminating power: the same call after unlocking must apply, or
        // the checks above would pass with the gate deleted.
        AppLockGate.shared.setLocked(false)
        check(publisher.drainPendingActions(now: now) == 1,
              "the same queued tap should apply once the app is unlocked")
        check(!store.activeTasks.contains { $0.id == "held" }, "\u{2026} and complete the task")
        guard case .ready = GrandLineWidgetDigest.load(from: publisher.snapshotURL) else {
            check(false, "an unlocked publish should be .ready again")
            return
        }
    }

    // MARK: The observer this feature added to a production store

    /// `StickyBoardStore` had no change-notification at all before F23 - the
    /// board's own controller was its only reader. The publisher needs one,
    /// so the store gained `observe`/`notifyChanged` in `ShiftStore`'s exact
    /// shape, fired from `persist()`'s success path and from the end of
    /// `reloadAll()`.
    ///
    /// Asserted here rather than in `StickyBoardSelfTest` because F23 is what
    /// added it and this is where its only caller lives - but it is a
    /// property of the store, so both call sites are covered: a write, and a
    /// reload.
    private static func checkTheStickyStoreNotifiesItsObservers(_ check: (Bool, String) -> Void) {
        let root = scratchDirectory("sticky-observer")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = StickyBoardStore(root: root)
        var fired = 0
        store.observe { fired += 1 }
        check(fired == 0, "registering an observer should not itself fire it - unlike ThemeManager.observe, nothing here needs a premature call")

        _ = store.addNote(title: "Ask Ravi about VPC peering", text: "the 10.42/16 range",
                          color: .yellow, x: 10, y: 10, rotationDegrees: 0, now: now)
        check(fired >= 1, "a write should notify (got \(fired))")

        let afterWrite = fired
        store.reloadAll()
        check(fired > afterWrite, "a reload should notify too - a pull can change the board under an in-memory copy")

        // Discriminating power: the notification really carries a change the
        // publisher would act on, rather than firing on nothing.
        check(store.activeNotes.count == 1,
              "the fixture write should really have produced a note (got \(store.activeNotes.count))")
    }

    // MARK: Source guards - the extension is a second binary this suite cannot run

    /// The extension's own `Widgets/GrandLineWidgets/` directory.
    private static func widgetSourceDirectory() -> URL? {
        guard let appSources = SelfTestSources.appSourceDirectory() else { return nil }
        let directory = appSources
            .deletingLastPathComponent()        // Sources/
            .deletingLastPathComponent()        // native/
            .appendingPathComponent("Widgets", isDirectory: true)
            .appendingPathComponent("GrandLineWidgets", isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("GrandLineWidgetBundle.swift").path
        ) else { return nil }
        return directory
    }

    /// The extension duplicates the Daylight token table, because it cannot
    /// link the app. This is the guard that keeps the two from drifting - the
    /// alternative was a promise in a comment.
    ///
    /// Confirmed to catch a real regression rather than merely to pass:
    /// changing `WidgetPalette.dusk`'s `badText` from `E07272` to `E07273` in
    /// a copy of the file failed this case by name, and restoring it passed.
    private static func checkThePaletteMatchesDaylight(_ check: (Bool, String) -> Void) {
        guard let directory = widgetSourceDirectory() else {
            print("  SKIP  WidgetSnapshotSelfTest: the widget extension's sources are not next to this binary")
            return
        }
        guard let text = try? String(contentsOf: directory.appendingPathComponent("WidgetPalette.swift"), encoding: .utf8) else {
            check(false, "WidgetPalette.swift should be readable")
            return
        }

        func block(after marker: String) -> String? {
            guard let start = text.range(of: marker) else { return nil }
            let rest = text[start.upperBound...]
            guard let end = rest.range(of: "\n    )") else { return nil }
            return String(rest[..<end.lowerBound])
        }

        let pairs: [(String, DaylightTokens, String)] = [
            ("static let daylight = WidgetPalette(", DaylightTokens.light, "Daylight"),
            ("static let dusk = WidgetPalette(", DaylightTokens.dusk, "Dusk")
        ]
        for (marker, tokens, label) in pairs {
            guard let body = block(after: marker) else {
                check(false, "\(label): WidgetPalette's table should be findable in the source")
                continue
            }
            let expected: [(String, String)] = [
                ("paper", tokens.paper), ("card", tokens.card), ("inset", tokens.inset),
                ("hair", tokens.hair), ("ink", tokens.ink), ("muted", tokens.muted),
                ("faint", tokens.faint), ("okText", tokens.okText),
                ("warnText", tokens.warnText), ("badText", tokens.badText)
            ]
            for (name, hex) in expected {
                check(body.contains("\(name): Color(hex: \"\(hex)\")"),
                      "\(label): the widget's `\(name)` should be DaylightTokens' own \(hex)")
            }
        }

        // The identity gradients, from `HelmDomainHue`'s own table rather
        // than from the mockup (which drew the Tasks tile violet).
        check(text.contains("Color(hex: \"\(HelmDomainHue.rose.daylightH1ForTests)\")"),
              "the Tasks gradient should start at HelmDomainHue.rose's own h1")
        check(text.contains("Color(hex: \"\(HelmDomainHue.amber.daylightH1ForTests)\")"),
              "the Sticky gradient should start at HelmDomainHue.amber's own h1")

        // Discriminating power: the file really does contain hex literals in
        // the form this case matches, so a rewrite that changed the shape
        // fails loudly instead of passing with zero matches.
        check(text.components(separatedBy: "Color(hex: \"").count - 1 >= 22,
              "WidgetPalette.swift should carry the full token table as hex literals")
    }

    /// Four things about the extension's own build that nothing else can see,
    /// and each of which fails *silently* if it breaks.
    private static func checkTheExtensionAndTheContractAgree(_ check: (Bool, String) -> Void) {
        guard let directory = widgetSourceDirectory() else { return }
        let native = directory.deletingLastPathComponent().deletingLastPathComponent()

        // 1. The App Group id in the entitlements must be the one the app
        // writes to. Two files, one string, and the failure mode is a widget
        // that loads and reads nothing.
        if let entitlements = try? String(
            contentsOf: directory.appendingPathComponent("GrandLineWidgets.entitlements"), encoding: .utf8
        ) {
            check(entitlements.contains("<string>\(GrandLineWidgetContainer.appGroupIdentifier)</string>"),
                  "the entitlements' App Group should be GrandLineWidgetContainer.appGroupIdentifier (\(GrandLineWidgetContainer.appGroupIdentifier))")
            check(entitlements.contains("com.apple.security.app-sandbox"),
                  "a widget extension is sandboxed by the system - the entitlements should say so")
        } else {
            check(false, "GrandLineWidgets.entitlements should be readable")
        }

        // 2. The Info.plist must declare the WidgetKit extension point, or
        // the bundle is a signed binary nothing ever loads.
        if let plist = try? String(contentsOf: directory.appendingPathComponent("Info.plist"), encoding: .utf8) {
            check(plist.contains("com.apple.widgetkit-extension"),
                  "the Info.plist should declare the WidgetKit extension point")
            check(plist.contains("<key>LSMinimumSystemVersion</key>"),
                  "the Info.plist should pin a minimum system version (interactive widgets are macOS 14)")
        } else {
            check(false, "the extension's Info.plist should be readable")
        }

        // 3. The build script must compile the shared contract out of the
        // app's own sources. If that line is lost, the extension still
        // builds - against a *copy* somebody pasted - and the two halves
        // drift with nothing failing.
        let script = native.appendingPathComponent("Scripts/build-widget-extension.sh")
        if let text = try? String(contentsOf: script, encoding: .utf8) {
            check(text.contains("Sources/FirstmateCockpit/WidgetSharedContract.swift"),
                  "build-widget-extension.sh should compile the shared contract from the app's own sources")
            check(text.contains("_NSExtensionMain"),
                  "\u{2026} and link the extension entry point, not a `main`")
            check(text.contains("-warnings-as-errors"),
                  "\u{2026} and fail on a warning, like the app's own build does (GL-07)")
        } else {
            check(false, "Scripts/build-widget-extension.sh should exist and be readable")
        }

        // 4. Every source the script names must still be there. A renamed
        // file makes the script fail loudly, which is the point - this check
        // is what makes that failure visible from the test suite too.
        if let text = try? String(contentsOf: script, encoding: .utf8) {
            for name in ["WidgetPalette.swift", "WidgetChrome.swift", "CompleteTaskIntent.swift",
                         "TasksDueWidget.swift", "StickyNoteWidget.swift", "GrandLineWidgetBundle.swift"] {
                check(text.contains(name), "build-widget-extension.sh should compile \(name)")
                check(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                      "\(name) should exist in the extension's source directory")
            }
        }

        // 5. The render probe must render the extension's *real* views, not a
        // copy - the whole value of `Scripts/render-widget-previews.sh` is
        // that what it rasterises is what the widget host would load. A
        // pasted-aside copy would still produce PNGs, and they would be of
        // nothing.
        let renderScript = native.appendingPathComponent("Scripts/render-widget-previews.sh")
        if let text = try? String(contentsOf: renderScript, encoding: .utf8) {
            for name in ["WidgetPalette.swift", "WidgetChrome.swift", "CompleteTaskIntent.swift",
                         "TasksDueWidget.swift", "StickyNoteWidget.swift",
                         "Sources/FirstmateCockpit/WidgetSharedContract.swift"] {
                check(text.contains(name), "render-widget-previews.sh should render the real \(name)")
            }
            check(!text.contains("GrandLineWidgetBundle.swift"),
                  "\u{2026} and must not compile the `@main` bundle, which would clash with its own entry point")
        } else {
            check(false, "Scripts/render-widget-previews.sh should exist and be readable")
        }

        // 6. `widgetFamily` is read-only, so each widget's renderable body
        // must take the family as a parameter. Fold the two views back
        // together and the render probe silently stops being possible.
        for name in ["TasksDueWidget.swift", "StickyNoteWidget.swift"] {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { continue }
            check(text.contains("let family: WidgetFamily"),
                  "\(name)'s renderable body should take the widget family as a parameter, not read the environment")
        }

        // 7. The two widget kinds are the contract's, not the extension's own
        // literals - a `Widget` is `@MainActor`-isolated and an `AppIntent`
        // is not, so a kind string declared on the widget cannot be read by
        // the intent that reloads it (Swift 6 rejects it outright). This is
        // the guard against somebody re-adding a local copy.
        for name in ["TasksDueWidget.swift", "StickyNoteWidget.swift"] {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { continue }
            check(text.contains("GrandLineWidgetKind."),
                  "\(name) should take its kind from GrandLineWidgetKind")
            check(!text.contains("static let kind ="),
                  "\(name) should not declare a second copy of its kind string")
        }
    }
}

#endif
