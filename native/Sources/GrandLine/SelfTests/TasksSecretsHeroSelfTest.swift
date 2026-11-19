// Grand Line - native macOS app.
//
// The words and colours of Tasks' T-4 band and lanes, Secrets' S-3 hero
// column and Automic Vault's S-1 split card - pure, so they run headless in
// CI's blocking lane. Where they sit and what their controls run is
// `TasksSecretsHeroViewSelfTest`'s, in a window.
//
// Run with:
//   swift build && FM_RUN_TASKS_SECRETS_HERO_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum TasksSecretsHeroSelfTest {

    static func run() -> Bool {
        print("== TasksSecretsHeroSelfTest ==")
        var allOK = true
        let cases: [(String, (inout Bool) -> Void)] = [
            ("T-4 the band's verdict", checkBandWords),
            ("T-4 a store that could not be read is not zeroes", checkBandUnread),
            ("T-4 a lane's detail line", checkLaneDetail),
        ]
        for (name, body) in cases {
            var ok = true
            autoreleasepool { body(&ok) }
            print("  \(ok ? "OK  " : "FAIL") \(name)")
            allOK = allOK && ok
        }
        print(allOK ? "TasksSecretsHeroSelfTest: all checks passed" : "TasksSecretsHeroSelfTest: FAILED")
        return allOK
    }

    static var everyTheme: [HelmTheme] {
        var seen = Set<String>()
        return (HelmTheme.appThemes + HelmTheme.allThemes).filter { seen.insert($0.id).inserted }
    }

    // MARK: T-4

    private static func summary(open: Int, due: Int, overdue: Int, followUps: Int) -> ShiftStore.Summary {
        ShiftStore.Summary(open: open, dueToday: due, overdue: overdue, followUps: followUps, overdueFollowUps: 0)
    }

    private static func checkBandWords(_ ok: inout Bool) {
        let cases: [(ShiftStore.Summary, String)] = [
            (summary(open: 7, due: 1, overdue: 1, followUps: 2), "2 things need you today."),
            (summary(open: 7, due: 1, overdue: 0, followUps: 0), "1 thing needs you today."),
            (summary(open: 7, due: 0, overdue: 0, followUps: 2), "Only follow-ups are waiting."),
            (summary(open: 7, due: 0, overdue: 0, followUps: 1), "Only a follow-up is waiting."),
            (summary(open: 7, due: 0, overdue: 0, followUps: 0), "Nothing is due today."),
            (summary(open: 0, due: 0, overdue: 0, followUps: 0), "Nothing on the board."),
        ]
        for (counts, want) in cases {
            let band = ShiftHeroWords.band(summary: counts, doneLastWeek: 1)
            check(band.headline == want, "\(counts) reads \"\(band.headline)\", want \"\(want)\"", &ok)
        }
        let band = ShiftHeroWords.band(summary: summary(open: 7, due: 1, overdue: 1, followUps: 2), doneLastWeek: 1)
        check(band.figures?.due == 1 && band.figures?.overdue == 1 && band.figures?.followUps == 2 && band.figures?.done == 1,
              "the figures are \(String(describing: band.figures))", &ok)
        check(band.ring?.done == 1 && band.ring?.total == 8, "the ring is \(String(describing: band.ring))", &ok)
        check(band.kicker.hasPrefix("Tasks \u{00B7} "), "the kicker is \(band.kicker)", &ok)
        let empty = ShiftHeroWords.band(summary: summary(open: 0, due: 0, overdue: 0, followUps: 0), doneLastWeek: 0)
        check(empty.ring == nil, "an empty board draws a ring of nothing", &ok)
    }

    private static func checkBandUnread(_ ok: inout Bool) {
        let band = ShiftHeroWords.band(summary: nil, doneLastWeek: 3)
        check(band.figures == nil && band.ring == nil && band.isDimmed,
              "a failed read draws figures or a ring, or does not dim", &ok)
        check(band.headline == "Your tasks could not be read.", "a failed read says \"\(band.headline)\"", &ok)
    }

    private static func checkLaneDetail(_ ok: inout Bool) {
        // Local noon, `Calendar.current` - AGENTS.md's rule for a day fixture.
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        func day(_ offset: Int) -> String {
            let date = calendar.date(byAdding: .day, value: offset, to: now) ?? now
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1)
        }
        let cases: [([(String?, String?)], String)] = [
            ([(day(-2), nil), (day(0), nil), (day(3), nil)], "1 overdue \u{00B7} 1 due today"),
            ([(day(1), nil), (nil, nil)], "1 due tomorrow"),
            ([(day(5), nil), (nil, nil)], "Nothing due soon"),
            ([], "Nothing here yet"),
        ]
        for (dues, want) in cases {
            let detail = ShiftHeroWords.laneDetail(dues: dues.map { (date: $0.0, time: $0.1) }, empty: "Nothing here yet",
                                                   now: now, calendar: calendar)
            check(detail == want, "\(dues) reads \"\(detail)\", want \"\(want)\"", &ok)
        }
    }
}

#endif
