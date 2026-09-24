// Manjesh Grand Line - native macOS app.
//
// F22's **pure-logic** half: the mode's policy, its hotkey chord, its tab
// table, and the whole Today/Notes derivation.
//
// **This suite is deliberately NOT in `NEEDS_SESSION`**, and per AGENTS.md's
// "Writing a self-test" that classification is operative rather than
// decorative: it is what makes these checks guard CI's *blocking* lane. None
// of them needs a window, a layout pass or a pixel - every one is a question
// about a value type. The popover's chrome, its pane swapping and its
// rendered colours are `CompactModeViewSelfTest`, which does need one and is
// listed there.
//
// What it is really for: compact mode's three settings drive four separate
// pieces of app-level state (three status items' visibility, the
// terminate-on-last-window answer, the activation policy, and what the status
// item may say), and the failure mode is not a crash - it is two of them
// quietly disagreeing. In particular:
//
//   * `showsPerFeatureStatusItems` is asserted to be the *exact inverse* of
//     `showsCompactStatusItem`, because four status items where one contains
//     the other three is the state the reviewed mockup rules out.
//   * `activationPolicy` is asserted to be `.regular` for every combination
//     except "both on", so "hide the Dock icon" can never outlive the mode
//     and leave a captain with a window and no way to raise it.
//   * `terminatesAfterLastWindowClosed` is asserted false in compact mode,
//     because the mode's way of having no window is to close the main one -
//     with the stock answer, enabling the mode would quit the app.
//
// Hermeticity: `AppSettings` is read through an injected `UserDefaults` suite
// that is removed afterwards, so nothing here touches the captain's real
// preferences. No theme is changed, so there is nothing to restore.
//
// `FM_RUN_COMPACT_MODE_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CompactModeSelfTest {

    /// The captain's **own** calendar, deliberately - not a pinned UTC one.
    ///
    /// This is the one place where forcing a fixed time zone would make the
    /// suite wrong rather than hermetic. A task's due date is persisted as a
    /// bare `"YYYY-MM-DD"` and read back by `ShiftDateFormatting.date(from:)`,
    /// whose formatter resolves that string to **local** midnight - because
    /// "due today" means today where the captain is. Pinning this calendar to
    /// UTC made every fixture date parse 5.5 hours on the wrong side of
    /// `startOfDay` and reported a task due today as overdue: the suite
    /// measured two calendars rather than the feature. Production passes
    /// `Calendar.current`, so this does too.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// A pinned *day* at local noon, so "overdue"/"due today"/"tomorrow" are
    /// facts rather than functions of when the suite happens to run - and
    /// noon rather than midnight so no runner's time zone can put the fixture
    /// on a day boundary.
    private static let now: Date = calendar.date(from: DateComponents(
        year: 2026, month: 9, day: 22, hour: 12)) ?? Date()

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkTheFixtureIsTheDayItClaims(check)
        checkTheStatusItemsAreNeverBothShown(check)
        checkTheDockIconCannotOutliveTheMode(check)
        checkClosingTheLastWindowOnlyQuitsOutsideCompactMode(check)
        checkTheBadgeIsOptInAndLockAware(check)
        checkThePolicyReadsAllThreeSettings(check)
        checkTheHotkeyIsExactlyControlOptionG(check)
        checkOnlyTheTwoWritableTabsTakeACapture(check)
        checkTodayIsOrderedByUrgencyThenDate(check)
        checkTodayCapsItsRowsButNotItsCount(check)
        checkTodayExcludesWhatIsNotDue(check)
        checkTodayCaptionsNameTheState(check)
        checkTodayChipsDistinguishNoneFromZero(check)
        checkNotesAreNewestFirstAndNeverBlank(check)
        checkNotesDetailPrefersTheChecklistProgress(check)

        print(ok ? "CompactModeSelfTest: OK" : "CompactModeSelfTest: FAILURES")
        return ok
    }

    // MARK: Fixtures

    private static func day(_ offset: Int) -> String {
        let date = calendar.date(byAdding: .day, value: offset, to: now) ?? now
        return ShiftDateFormatting.components(from: date).dateStr
    }

    private static func task(_ id: String,
                             _ title: String,
                             dueOffsetDays: Int?,
                             priority: ShiftPriority = .normal,
                             status: ShiftTaskStatus = .todo) -> ShiftTask {
        var task = ShiftTask.fresh(now: now)
        task.id = id
        task.title = title
        task.priority = priority
        task.status = status
        task.dueDate = dueOffsetDays.map(day)
        return task
    }

    private static func note(_ id: String,
                             title: String,
                             text: String,
                             createdOffsetDays: Int,
                             color: StickyNoteColor = .yellow,
                             checklist: [StickyChecklistItem]? = nil,
                             archived: Bool = false) -> StickyNote {
        var note = StickyNote(id: id, title: title, text: text, color: color,
                              x: 0, y: 0, width: 200, height: 200, rotationDegrees: 0,
                              createdAt: calendar.date(byAdding: .day, value: createdOffsetDays, to: now) ?? now)
        note.checklist = checklist
        if archived { note.archivedAt = now }
        return note
    }

    /// One `AppSettings` over a throwaway defaults suite, so the three keys
    /// can be written and read without touching the real domain - the seam
    /// `AppSettings.init(defaults:)` exists for.
    private static func withScratchSettings(_ body: (AppSettings) -> Void) {
        let name = "com.firstmate.cockpit.compactmode.selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            body(AppSettings(defaults: .standard))
            return
        }
        body(AppSettings(defaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    private static func policy(_ enabled: Bool, _ dock: Bool, _ badge: Bool) -> CompactModePolicy {
        CompactModePolicy(isEnabled: enabled, hidesDockIcon: dock, badgesOverdueCount: badge)
    }

    // MARK: Cases

    /// The fixture's own discriminating power, asserted before anything reads
    /// it: if `now` is not the day these offsets assume, every "overdue" and
    /// "tomorrow" case below would pass or fail for the wrong reason.
    /// AGENTS.md's "assert the fixture's own discriminating power first".
    private static func checkTheFixtureIsTheDayItClaims(_ check: (Bool, String) -> Void) {
        check(day(0) != day(-1) && day(0) != day(1),
              "the fixture's day offsets must produce three distinct dates, or every "
                  + "urgency case below is vacuous")
        let digest = CompactModeDigest.today(tasks: [task("a", "yesterday", dueOffsetDays: -1),
                                                     task("b", "today", dueOffsetDays: 0),
                                                     task("c", "tomorrow", dueOffsetDays: 1)],
                                             followUps: [], focusSecondsToday: 0,
                                             now: now, calendar: calendar)
        check(Set(digest.rows.map { $0.urgency }).count == 3,
              "the fixture must produce all three urgencies, or the ordering check cannot fail")
    }

    private static func checkTheStatusItemsAreNeverBothShown(_ check: (Bool, String) -> Void) {
        for dock in [false, true] {
            for badge in [false, true] {
                let on = policy(true, dock, badge)
                let off = policy(false, dock, badge)
                check(on.showsCompactStatusItem && !on.showsPerFeatureStatusItems,
                      "compact mode on: the merged status item shows and the three it merges do not "
                          + "(dock=\(dock) badge=\(badge))")
                check(!off.showsCompactStatusItem && off.showsPerFeatureStatusItems,
                      "compact mode off: the three per-feature status items show and the merged one "
                          + "does not (dock=\(dock) badge=\(badge))")
                check(on.showsCompactStatusItem != on.showsPerFeatureStatusItems
                          && off.showsCompactStatusItem != off.showsPerFeatureStatusItems,
                      "the two status-item decisions must be exact inverses - four items where one "
                          + "contains the other three is the state the mockup rules out")
            }
        }
    }

    private static func checkTheDockIconCannotOutliveTheMode(_ check: (Bool, String) -> Void) {
        check(policy(true, true, false).activationPolicy == .accessory,
              "compact mode + hide the Dock icon should run the app as a menu-bar accessory")
        check(policy(true, false, false).activationPolicy == .regular,
              "compact mode with the Dock icon kept should stay a regular app")
        check(policy(false, true, false).activationPolicy == .regular,
              "hide-the-Dock-icon left on with compact mode OFF must still be `.regular` - "
                  + "otherwise the captain has a window and no Dock icon to raise it from")
        check(policy(false, false, false).activationPolicy == .regular,
              "both off is a plain regular app")
    }

    private static func checkClosingTheLastWindowOnlyQuitsOutsideCompactMode(_ check: (Bool, String) -> Void) {
        check(policy(false, false, false).terminatesAfterLastWindowClosed,
              "outside compact mode, closing the last window should still quit - the stock behaviour")
        check(!policy(true, false, false).terminatesAfterLastWindowClosed,
              "in compact mode, closing the last window must NOT quit: the mode's way of having no "
                  + "window is to close the main one")
        check(!policy(true, true, true).terminatesAfterLastWindowClosed,
              "the answer is keyed on the mode alone, not on the Dock or badge switches")
    }

    private static func checkTheBadgeIsOptInAndLockAware(_ check: (Bool, String) -> Void) {
        let badging = policy(true, false, true)
        let quiet = policy(true, false, false)
        check(badging.statusItemTitle(overdueCount: 3, contentAllowed: true) == " 3",
              "with the badge on and three overdue, the status item should read \" 3\"")
        check(quiet.statusItemTitle(overdueCount: 3, contentAllowed: true) == "",
              "with the badge off, three overdue tasks must not put a number in the menu bar - "
                  + "off is the default and the reason is in the mockup")
        check(badging.statusItemTitle(overdueCount: 0, contentAllowed: true) == "",
              "an overdue count of zero renders nothing rather than \" 0\"")
        check(badging.statusItemTitle(overdueCount: 3, contentAllowed: false) == "",
              "GL-09: locked, the count is a real disclosure about the captain's day and must not "
                  + "be readable by anyone at the machine")
    }

    private static func checkThePolicyReadsAllThreeSettings(_ check: (Bool, String) -> Void) {
        withScratchSettings { settings in
            check(CompactModePolicy.current(settings) == policy(false, false, false),
                  "a fresh install has all three off - compact mode must not hide the window of an "
                      + "app nobody has configured")
            settings.compactModeEnabled = true
            settings.compactModeHidesDockIcon = true
            settings.compactModeBadgesOverdueCount = true
            check(CompactModePolicy.current(settings) == policy(true, true, true),
                  "`CompactModePolicy.current` must read all three keys - a partial policy is how "
                      + "two of these decisions come to disagree")
            settings.compactModeHidesDockIcon = false
            check(CompactModePolicy.current(settings) == policy(true, false, true),
                  "each key must be read independently rather than derived from the master switch")
        }
    }

    private static func checkTheHotkeyIsExactlyControlOptionG(_ check: (Bool, String) -> Void) {
        func event(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                             timestamp: 0, windowNumber: 0, context: nil,
                             characters: "g", charactersIgnoringModifiers: "g",
                             isARepeat: false, keyCode: keyCode)
        }
        guard let match = event(keyCode: CompactModeHotkey.gKeyCode, flags: [.control, .option]) else {
            check(false, "could not synthesise a key event - this check would silently pass")
            return
        }
        check(CompactModeHotkey.matches(match),
              "\u{2303}\u{2325}G is the chord the popover's own footer advertises, so it has to be "
                  + "the chord the monitor matches")
        // An ambient flag must not decide whether the chord works - the
        // shared defect `fm/grandline-capture-global-hotkey-configurable`
        // found in `ShiftGlobalHotkey` and fixed in both. Without it, a
        // captain with Caps Lock latched on loses the shortcut and nothing
        // says why.
        if let withCapsLock = event(keyCode: CompactModeHotkey.gKeyCode,
                                    flags: [.control, .option, .capsLock]) {
            check(CompactModeHotkey.matches(withCapsLock),
                  "Caps Lock being on must not stop \u{2303}\u{2325}G matching")
        } else {
            check(false, "could not synthesise \u{2303}\u{2325}G with Caps Lock - this check would silently pass")
        }
        // Each near-miss is its own case: a predicate that accepted any of
        // these would steal a chord the captain uses elsewhere.
        let misses: [(String, NSEvent?)] = [
            ("\u{2325}G alone", event(keyCode: CompactModeHotkey.gKeyCode, flags: [.option])),
            ("\u{2303}G alone", event(keyCode: CompactModeHotkey.gKeyCode, flags: [.control])),
            ("\u{2318}G", event(keyCode: CompactModeHotkey.gKeyCode, flags: [.command])),
            ("\u{2303}\u{2325}\u{21E7}G", event(keyCode: CompactModeHotkey.gKeyCode,
                                                flags: [.control, .option, .shift])),
            ("\u{2303}\u{2325} on another key", event(keyCode: CompactModeHotkey.gKeyCode + 1,
                                                      flags: [.control, .option])),
        ]
        for (name, candidate) in misses {
            guard let candidate else {
                check(false, "could not synthesise \(name) - this check would silently pass")
                continue
            }
            check(!CompactModeHotkey.matches(candidate),
                  "\(name) must not fire compact mode's hotkey")
        }
    }

    private static func checkOnlyTheTwoWritableTabsTakeACapture(_ check: (Bool, String) -> Void) {
        check(CompactModeTab.allCases.map { $0.title } == ["Today", "Notes", "Vault", "Crew"],
              "the four tabs, in the reviewed mockup's own order")
        check(CompactModeTab.today.captureDestination == .task,
              "Today's capture line files a task")
        check(CompactModeTab.notes.captureDestination == .sticky,
              "Notes' capture line files a sticky note")
        check(CompactModeTab.vault.captureDestination == nil,
              "the Vault tab takes no capture: a menu-bar surface with no window and no Touch ID "
                  + "gate is the wrong place to type credential material")
        check(CompactModeTab.crew.captureDestination == nil,
              "the Crew tab takes no capture - its pane already owns an ask field")
        for tab in CompactModeTab.allCases where tab.captureDestination != nil {
            check(!tab.capturePlaceholder.isEmpty,
                  "\(tab.title)'s capture line needs a placeholder naming what return will do")
        }
    }

    private static func checkTodayIsOrderedByUrgencyThenDate(_ check: (Bool, String) -> Void) {
        let digest = CompactModeDigest.today(
            tasks: [
                task("later", "Review the collector values", dueOffsetDays: 3),
                task("today", "Rotate the bastion keys", dueOffsetDays: 0),
                task("old", "Renew the wildcard cert", dueOffsetDays: -6),
                task("recent", "Chase the vendor invoice", dueOffsetDays: -1),
            ],
            followUps: [], focusSecondsToday: 0, now: now, calendar: calendar)
        check(digest.rows.map { $0.id } == ["old", "recent", "today", "later"],
              "overdue first and oldest-first within that, then today, then soonest-first - the one "
                  + "that has been late longest is the one being asked about")
        check(digest.rows.map { $0.urgency } == [.overdue, .overdue, .today, .later],
              "each row's urgency has to match the date it was derived from")
    }

    private static func checkTodayCapsItsRowsButNotItsCount(_ check: (Bool, String) -> Void) {
        let tasks = (1...9).map { task("t\($0)", "Overdue \($0)", dueOffsetDays: -$0) }
        let digest = CompactModeDigest.today(tasks: tasks, followUps: [], focusSecondsToday: 0,
                                             now: now, calendar: calendar)
        check(tasks.count > CompactModeDigest.maxRows,
              "the fixture must exceed the row cap, or the cap check is vacuous")
        check(digest.rows.count == CompactModeDigest.maxRows,
              "a 330pt popover shows `maxRows` rows, not all of them")
        check(digest.overdueCount == 9,
              "the overdue *count* must be the truth, not what fitted in the popover - it is what "
                  + "the status item's badge reports")
    }

    private static func checkTodayExcludesWhatIsNotDue(_ check: (Bool, String) -> Void) {
        let digest = CompactModeDigest.today(
            tasks: [
                task("nodue", "Someday: rewrite the runbook", dueOffsetDays: nil),
                task("done", "Already shipped", dueOffsetDays: -1, status: .completed),
                task("cancelled", "Abandoned", dueOffsetDays: -1, status: .cancelled),
                task("real", "Renew the cert", dueOffsetDays: -1),
            ],
            followUps: [], focusSecondsToday: 0, now: now, calendar: calendar)
        check(digest.rows.map { $0.id } == ["real"],
              "this tab answers \"what is due\": an undated backlog item is not an answer, and a "
                  + "completed or cancelled task is not either")
        check(digest.overdueCount == 1,
              "the badge count must make the same three exclusions the rows do")
    }

    private static func checkTodayCaptionsNameTheState(_ check: (Bool, String) -> Void) {
        let digest = CompactModeDigest.today(
            tasks: [
                task("overdue", "Renew the cert", dueOffsetDays: -6),
                task("today", "Rotate the keys", dueOffsetDays: 0, priority: .high),
                task("tomorrow", "Review the values", dueOffsetDays: 1),
                task("far", "Audit the buckets", dueOffsetDays: 9),
            ],
            followUps: [], focusSecondsToday: 0, now: now, calendar: calendar)
        let byID = Dictionary(uniqueKeysWithValues: digest.rows.map { ($0.id, $0.detail) })
        check(byID["overdue"]?.hasPrefix("overdue \u{00B7} ") == true,
              "an overdue row says so in words as well as in colour (GL-16: never colour alone) - "
                  + "got \(byID["overdue"] ?? "nil")")
        check(byID["today"] == "due today \u{00B7} High",
              "a high-priority task due today names both - got \(byID["today"] ?? "nil")")
        check(byID["tomorrow"] == "tomorrow",
              "tomorrow is named relative to the *injected* clock - got \(byID["tomorrow"] ?? "nil")")
        check(byID["far"]?.isEmpty == false && byID["far"] != "tomorrow"
                  && byID["far"]?.hasPrefix("overdue") == false,
              "a date further out falls back to a month-day rather than a relative word - "
                  + "got \(byID["far"] ?? "nil")")
        check(byID["overdue"]?.contains("High") == false,
              "`normal` is the default priority on every task, so printing it would put the same "
                  + "noise on every row and say nothing")
    }

    private static func checkTodayChipsDistinguishNoneFromZero(_ check: (Bool, String) -> Void) {
        var pending = ShiftFollowUp.fresh()
        pending.title = "Chase the vendor"
        var done = ShiftFollowUp.fresh()
        done.title = "Already handled"
        done.status = .done

        let quiet = CompactModeDigest.today(tasks: [], followUps: [done], focusSecondsToday: 0,
                                            now: now, calendar: calendar)
        check(quiet.focusChip == nil,
              "GL-14: no focus time logged today is a different state from \"0:00\" and must not "
                  + "render as a chip at all")
        check(quiet.followUpChip == nil,
              "a pending count of zero renders no chip - a completed follow-up is not pending")

        let busy = CompactModeDigest.today(tasks: [], followUps: [pending, done],
                                           focusSecondsToday: 62_640,
                                           now: now, calendar: calendar)
        check(busy.followUpChip == "1 follow-up",
              "one pending follow-up is singular - got \(busy.followUpChip ?? "nil")")
        check(busy.focusChip == "17:24 focus",
              "the mockup's own \"17:24 focus\" - got \(busy.focusChip ?? "nil")")

        var second = ShiftFollowUp.fresh()
        second.title = "And another"
        let two = CompactModeDigest.today(tasks: [], followUps: [pending, second],
                                          focusSecondsToday: 0, now: now, calendar: calendar)
        check(two.followUpChip == "2 follow-ups",
              "two is plural - got \(two.followUpChip ?? "nil")")
        check(CompactModeDigest.focusText(seconds: 90) == "1:30",
              "under an hour reads as minutes and seconds - got \(CompactModeDigest.focusText(seconds: 90))")
    }

    private static func checkNotesAreNewestFirstAndNeverBlank(_ check: (Bool, String) -> Void) {
        let rows = CompactModeDigest.notes([
            note("old", title: "Older note", text: "", createdOffsetDays: -5),
            note("new", title: "Newest note", text: "", createdOffsetDays: -1),
            note("archived", title: "Put away", text: "", createdOffsetDays: 0, archived: true),
            note("untitled", title: "", text: "  \ncall the bank\nask about the fee",
                 createdOffsetDays: -2),
            note("blank", title: "", text: "", createdOffsetDays: -3),
        ])
        check(rows.map { $0.id } == ["new", "untitled", "blank", "old"],
              "newest first, and an archived note never appears - the captain has explicitly put "
                  + "that one away")
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        check(byID["untitled"]?.title == "call the bank",
              "a sticky note's title is optional, so an untitled one falls back to its first "
                  + "non-empty line - got \(byID["untitled"]?.title ?? "nil")")
        check(byID["untitled"]?.detail == "ask about the fee",
              "the detail is the line *after* whatever became the title, so a row never prints its "
                  + "own title twice - got \(byID["untitled"]?.detail ?? "nil")")
        check(byID["blank"]?.title == "Untitled note",
              "GL-14: a genuinely empty note is a state, not a blank row - "
                  + "got \(byID["blank"]?.title ?? "nil")")
        check(byID["blank"]?.detail == "Empty note",
              "and it says so in its detail too - got \(byID["blank"]?.detail ?? "nil")")
        check(byID["new"]?.color == .yellow && rows.allSatisfy { $0.title.isEmpty == false },
              "every row carries the note's own paper colour and a non-empty title")
    }

    private static func checkNotesDetailPrefersTheChecklistProgress(_ check: (Bool, String) -> Void) {
        let checklist = [
            StickyChecklistItem.fresh(text: "book the flight", isDone: true),
            StickyChecklistItem.fresh(text: "book the hotel", isDone: true),
            StickyChecklistItem.fresh(text: "expense it", isDone: false),
        ]
        let rows = CompactModeDigest.notes([
            note("list", title: "Trip", text: "ignored", createdOffsetDays: 0, checklist: checklist),
        ])
        check(rows.first?.detail == "2 of 3 done",
              "a checklist note's detail is its progress, which is the thing worth a glance - "
                  + "got \(rows.first?.detail ?? "nil")")
        let emptyTitleList = CompactModeDigest.notes([
            note("l2", title: "", text: "", createdOffsetDays: 0,
                 checklist: [StickyChecklistItem.fresh(text: "one thing", isDone: false)]),
        ])
        check(emptyTitleList.first?.title == "one thing",
              "an untitled checklist note falls back through its items rather than reading "
                  + "\"Untitled note\" - got \(emptyTitleList.first?.title ?? "nil")")
    }
}

#endif
