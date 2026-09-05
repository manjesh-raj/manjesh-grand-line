// Manjesh Grand Line - native macOS app.
//
// GL-32's second remaining half (audit §6.1): fixed table `rowHeight`s that
// did not grow with the chrome text scale.
//
// Every list in this app that renders `HelmAccentRow`-style cards uses a fixed
// row height rather than `usesAutomaticRowHeights` - deliberately, for the
// demand-driven-table reasons those files document. But all of those heights
// were measured at scale 1.0, so at "Large"/"Larger" the text grew and the row
// did not. That is the same clipping the 74 -> 78pt Shift fix already proved
// once at a single fixed scale; this suite is what stops it recurring at the
// other two.
//
// Two halves, and only both together are worth anything:
//
//   * the arithmetic - every scaled height really does grow with the setting;
//   * the *fit* - a real, configured `HelmAccentRow` still fits inside the
//     height its table hands it at every step. Without this half the first
//     one passes against a formula that grows by the wrong amount.
//
// It also drives each list's real `applyTheme(_:)`, because that is the whole
// re-derivation mechanism: a scale change arrives as an app-wide theme
// re-fire, so a list that reads its height only in `init` would keep the old
// one until relaunch and every arithmetic check above would still pass.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum TextScaleRowHeightSelfTest {

    static func run() -> Bool {
        // `ChromeTextScale.setScale` writes through to the real
        // `AppSettings.uiTextScale`, so the captain's own setting is saved and
        // restored - the non-hermetic hazard `Phase3PolishSelfTest`'s own
        // source guard exists for.
        let captainScale = ChromeTextScale.shared.scale
        defer { ChromeTextScale.shared.setScale(captainScale) }

        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        checkHeightsGrowWithTheScale(check)
        checkRowsStillFitAtEveryScale(check)
        checkListsReDeriveOnThemeReFire(check)

        if failures.isEmpty {
            print("TextScaleRowHeightSelfTest: OK")
            return true
        }
        print("TextScaleRowHeightSelfTest: \(failures.count) failure(s)")
        for f in failures { print("  - \(f)") }
        return false
    }

    /// Every fixed row height in the app, with the base it was measured at.
    private static let heights: [(name: String, base: CGFloat, current: () -> CGFloat)] = [
        ("ShiftTaskListView", ShiftTaskListView.baseRowHeight, { ShiftTaskListView.rowHeight }),
        ("ShiftFollowUpListView", ShiftTaskListView.baseRowHeight, { ShiftFollowUpListView.rowHeight }),
        ("ReviewPRListView", ReviewPRListView.baseRowHeight, { ReviewPRListView.rowHeight }),
        ("DictationHistoryListView", DictationHistoryListView.baseRowHeight, { DictationHistoryListView.rowHeight }),
        ("HostsListSection", HostsListSection.baseRecordRowHeight, { HostsListSection.recordRowHeight }),
        ("FleetLogListView", FleetLogListView.baseEventRowHeight, { FleetLogListView.eventRowHeight }),
    ]

    private static func checkHeightsGrowWithTheScale(_ check: (Bool, String) -> Void) {
        for step in ChromeTextScale.steps {
            ChromeTextScale.shared.setScale(step.scale)
            for entry in heights {
                let want = entry.base * step.scale
                check(abs(entry.current() - want) < 0.01,
                      "\(entry.name) is \(entry.current())pt at \(step.title), want \(want)pt")
            }
        }
        // And the default step really is a no-op, or every row in the app
        // silently changed height for captains who never touched the setting.
        ChromeTextScale.shared.setScale(1.0)
        for entry in heights {
            check(abs(entry.current() - entry.base) < 0.01,
                  "\(entry.name) is \(entry.current())pt at Default, want its measured \(entry.base)pt")
        }
    }

    /// The half that makes the arithmetic mean something: a real row, with
    /// realistic content, still fits.
    private static func checkRowsStillFitAtEveryScale(_ check: (Bool, String) -> Void) {
        let theme = ThemeManager.shared.theme
        // The tallest realistic shape one of these rows takes: a kicker, a
        // title, a meta line and a chip.
        let content = HelmAccentRow.Content(
            tint: .info,
            kicker: "PREPROD BASTION",
            title: "contract-ingest-worker-0 restarted four times in six hours",
            meta: "Last seen 12 minutes ago \u{00B7} raas-uat",
            badgeSymbol: "bolt.fill",
            chipText: "Needs you"
        )
        for step in ChromeTextScale.steps {
            ChromeTextScale.shared.setScale(step.scale)
            let row = HelmAccentRow()
            row.configure(content, theme: theme)
            row.applyTheme(theme)
            // A real width, or a wrapping label reports a single-line height
            // and the whole measurement is meaningless.
            row.frame = NSRect(x: 0, y: 0, width: 520, height: ShiftTaskListView.rowHeight)
            row.layoutSubtreeIfNeeded()

            let needed = row.fittingSize.height
            check(needed > 0, "the measured row had no height at all at \(step.title)")
            for entry in heights where entry.name.hasPrefix("Shift") || entry.name == "DictationHistoryListView" {
                check(needed <= entry.current(),
                      "at \(step.title) a real row needs \(needed)pt but \(entry.name) gives it "
                      + "\(entry.current())pt - descenders clip")
            }
        }
    }

    /// The mechanism: a list re-reads its row height on the app-wide theme
    /// re-fire a scale change arrives as.
    ///
    /// Read back through `NSTableView.rowHeight`, which **quantizes to the
    /// nearest half point** - a 101.4 assignment reads back as 101.5, a 83.2
    /// as 83.0. Measured, not assumed: the first version of this check used
    /// the same 0.01 tolerance as the pure arithmetic above and reported three
    /// lists as never re-deriving when all three had. The tolerance below is
    /// that rounding, and is still far tighter than the ~23pt a genuinely
    /// stale height would be off by.
    private static func checkListsReDeriveOnThemeReFire(_ check: (Bool, String) -> Void) {
        let theme = ThemeManager.shared.theme
        let tableRounding: CGFloat = 0.5

        ChromeTextScale.shared.setScale(1.0)
        let tasks = ShiftTaskListView()
        let history = DictationHistoryListView()
        let log = FleetLogListView(frame: .zero)
        let reviews = ReviewPRListView(
            emptyTitle: "Nothing to review", emptyBody: "No open PRs.",
            actionTarget: NSObject(), reviewAction: #selector(NSObject.description),
            mergeAction: #selector(NSObject.description),
            checksVisuals: { _ in (.good, "Passing") })
        for (name, built) in [("ShiftTaskListView", tasks.tableView.rowHeight),
                              ("ReviewPRListView", reviews.tableView.rowHeight),
                              ("DictationHistoryListView", history.tableView.rowHeight),
                              ("FleetLogListView", log.tableView.rowHeight)] {
            check(built > 0, "\(name) built with no row height")
        }

        ChromeTextScale.shared.setScale(1.3)
        // Nothing has re-themed yet, so the *tables* should still be stale -
        // which is what proves the assertions below are measuring the
        // re-derivation rather than a value that was already right.
        check(abs(tasks.tableView.rowHeight - ShiftTaskListView.baseRowHeight) <= tableRounding,
              "the table changed height without a theme re-fire, so this check proves nothing")

        tasks.applyTheme(theme)
        reviews.applyTheme(theme)
        history.applyTheme(theme)
        log.applyTheme(theme)

        check(abs(tasks.tableView.rowHeight - ShiftTaskListView.rowHeight) <= tableRounding,
              "ShiftTaskListView did not re-derive its row height on a theme re-fire "
              + "(\(tasks.tableView.rowHeight) vs \(ShiftTaskListView.rowHeight))")
        check(abs(reviews.tableView.rowHeight - ReviewPRListView.rowHeight) <= tableRounding,
              "ReviewPRListView did not re-derive its row height on a theme re-fire "
              + "(\(reviews.tableView.rowHeight) vs \(ReviewPRListView.rowHeight))")
        check(abs(history.tableView.rowHeight - DictationHistoryListView.rowHeight) <= tableRounding,
              "DictationHistoryListView did not re-derive its row height on a theme re-fire "
              + "(\(history.tableView.rowHeight) vs \(DictationHistoryListView.rowHeight))")
        check(abs(log.tableView.rowHeight - FleetLogListView.eventRowHeight) <= tableRounding,
              "FleetLogListView did not re-derive its row height on a theme re-fire "
              + "(\(log.tableView.rowHeight) vs \(FleetLogListView.eventRowHeight))")
    }
}

#endif
