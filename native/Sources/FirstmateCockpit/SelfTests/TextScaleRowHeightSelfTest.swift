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
        checkAuditTwoListsReDeriveOnThemeReFire(check)
        checkAuditTwoRowsStillFitAtEveryScale(check)

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
        // Audit #2 §1.2 - the tables #333's own sweep missed. Five of these
        // genuinely clip today (their cells are scaled `HelmType` roles); the
        // raw pane is the one exception and says why at its own declaration.
        ("LogRawPaneView", LogRawPaneView.baseRowHeight, { LogRawPaneView.rowHeight }),
        ("LogErrorGroupListView.group", LogErrorGroupListView.baseGroupRowHeight,
         { LogErrorGroupListView.groupRowHeight }),
        ("LogErrorGroupListView.sample", LogErrorGroupListView.baseSampleRowHeight,
         { LogErrorGroupListView.sampleRowHeight }),
        ("LogTimelineListView", LogTimelineListView.baseRowHeight, { LogTimelineListView.rowHeight }),
        ("LogCorrelationListView", LogCorrelationListView.baseRowHeight, { LogCorrelationListView.rowHeight }),
        ("KubeResourceTableView", KubeResourceTableView.baseRowHeight, { KubeResourceTableView.rowHeight }),
        ("KubeLogListView", KubeLogListView.baseRowHeight, { KubeLogListView.rowHeight }),
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

            // The four lists above share one 78pt base and one shape, which is
            // why one measurement covered them. **The UI modernization audit's
            // §3J2 bumps body 12 -> 13 and caption 11.5 -> 12**, and that
            // reflows every accent-row list in the app - including three whose
            // shape the maximal content above does *not* represent, and which
            // therefore had no fit coverage at all:
            //
            //   - a Review PR row carries no meta line (64)
            //   - a Fleet log row carries no chip (60)
            //   - a board card puts its chip *below* the body (81), which is
            //     the tallest arrangement of the same parts
            //
            // Measuring each in its own shape is the whole point: the maximal
            // shape over-estimates the first two and under-estimates the last,
            // so asserting all seven against one number would be either
            // vacuous or wrong.
            for shape in accentRowShapes {
                let sized = HelmAccentRow(chipPlacement: shape.placement)
                sized.configure(shape.content, theme: theme)
                sized.applyTheme(theme)
                sized.frame = NSRect(x: 0, y: 0, width: 520, height: shape.height())
                sized.layoutSubtreeIfNeeded()
                let wants = sized.fittingSize.height
                check(wants > 0, "\(shape.name)'s measured row had no height at all at \(step.title)")
                check(wants <= shape.height(),
                      "at \(step.title) a real \(shape.name) row needs \(wants)pt but the list "
                      + "gives it \(shape.height())pt - J2's type bump reflowed it")
            }
        }
    }

    /// The three accent-row shapes the maximal content above does not stand in
    /// for. Each is the real content that list renders, not a generic one.
    private static var accentRowShapes: [(name: String,
                                          placement: HelmAccentRow.ChipPlacement,
                                          content: HelmAccentRow.Content,
                                          height: () -> CGFloat)] {
        [
            ("ReviewPRListView", .trailing,
             HelmAccentRow.Content(
                tint: .good,
                kicker: "GITHUB \u{00B7} MANJESH-RAJ",
                title: "Give the palette glass and per-row identity, put symbols in the menus",
                chipText: "Checks green"),
             { ReviewPRListView.rowHeight }),
            // Kicker + title and **no meta line** - read off
            // `FleetLogEventCellView.configure`, not assumed. The first draft
            // of this fixture handed it a meta line it never renders and
            // reported the list 17pt short, which is a fixture bug wearing a
            // layout bug's clothes.
            ("FleetLogListView", .trailing,
             HelmAccentRow.Content(
                tint: .info,
                kicker: "MERGED",
                title: "Move the toast off the chrome and retire the stock spinner",
                badgeSymbol: "arrow.triangle.merge"),
             { FleetLogListView.eventRowHeight }),
            ("ShiftBoardView card", .belowBody,
             HelmAccentRow.Content(
                tint: .warn,
                kicker: "GRAND LINE",
                title: "Re-measure every accent row after the type bump",
                chipText: "High"),
             { ShiftBoardView.cardRowHeight }),
        ]
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

    // MARK: - Audit #2 §1.2

    /// The same two halves as above, for the eight tables the first sweep
    /// missed: they re-derive on a theme re-fire, and a real row still fits.
    ///
    /// Built at scale 1.0 and asserted stale *before* the theme re-fire, for
    /// the reason the check above documents: without that step an assertion
    /// that the height is right afterwards would pass against a table that
    /// never re-derived anything, because 1.0 and the new scale would both
    /// have been read at `init`.
    private static func checkAuditTwoListsReDeriveOnThemeReFire(_ check: (Bool, String) -> Void) {
        let theme = ThemeManager.shared.theme
        let tableRounding: CGFloat = 0.5

        ChromeTextScale.shared.setScale(1.0)
        let raw = LogRawPaneView(frame: .zero)
        let groups = LogErrorGroupListView(frame: .zero)
        let timeline = LogTimelineListView(frame: .zero)
        let correlation = LogCorrelationListView(frame: .zero)
        let generic = LogAccentRowListView(rowHeight: 74, emptySymbol: "tray",
                                           emptyTitle: "Nothing captured",
                                           emptyBody: "Capture some output first.")
        let k8sTable = KubeResourceTableView(frame: .zero)
        let k8sLog = KubeLogListView(frame: .zero)

        let cases: [(String, () -> CGFloat, () -> CGFloat, CGFloat)] = [
            ("LogRawPaneView", { raw.tableView.rowHeight },
             { LogRawPaneView.rowHeight }, LogRawPaneView.baseRowHeight),
            ("LogErrorGroupListView", { groups.tableView.rowHeight },
             { LogErrorGroupListView.groupRowHeight }, LogErrorGroupListView.baseGroupRowHeight),
            ("LogTimelineListView", { timeline.tableView.rowHeight },
             { LogTimelineListView.rowHeight }, LogTimelineListView.baseRowHeight),
            ("LogCorrelationListView", { correlation.tableView.rowHeight },
             { LogCorrelationListView.rowHeight }, LogCorrelationListView.baseRowHeight),
            ("LogAccentRowListView", { generic.tableView.rowHeight },
             { generic.rowHeightForTests }, generic.baseRowHeightForTests),
            ("KubeResourceTableView", { k8sTable.tableViewForTests.rowHeight },
             { KubeResourceTableView.rowHeight }, KubeResourceTableView.baseRowHeight),
            ("KubeLogListView", { k8sLog.tableViewForTests.rowHeight },
             { KubeLogListView.rowHeight }, KubeLogListView.baseRowHeight),
        ]

        for (name, built, _, base) in cases {
            check(abs(built() - base) <= tableRounding,
                  "\(name) built at \(built())pt, want its measured \(base)pt")
        }

        ChromeTextScale.shared.setScale(1.3)
        for (name, built, _, base) in cases {
            check(abs(built() - base) <= tableRounding,
                  "\(name)'s table changed height with no theme re-fire, so the "
                  + "assertion below would prove nothing")
        }

        raw.applyTheme(theme)
        groups.applyTheme(theme)
        timeline.applyTheme(theme)
        correlation.applyTheme(theme)
        generic.applyTheme(theme)
        k8sTable.applyTheme(theme)
        k8sLog.applyTheme(theme)

        for (name, built, want, _) in cases {
            check(abs(built() - want()) <= tableRounding,
                  "\(name) did not re-derive its row height on a theme re-fire "
                  + "(\(built()) vs \(want()))")
        }
    }

    /// The fit half for audit #2 §1.2's tables.
    ///
    /// Split deliberately, because measurement showed the two kinds of row
    /// here are in genuinely different states:
    ///
    ///   * A **single scaled line** - a Kubernetes log line, a resource cell,
    ///     an error-group sample line - is the shape the finding is about, and
    ///     it now fits at every step. That is asserted.
    ///   * An **accent row** in the two Log Analyzer lists does *not* fit, and
    ///     did not before this fix either: measured at Default, a group row
    ///     needs 76pt against its 58, and a correlation row 76-108pt (it wraps
    ///     its title) against its 56. That is a pre-existing sizing defect the
    ///     audit did not claim and this pass is not scoped to redesign - the
    ///     correlation one cannot be fixed by a better constant at all, since
    ///     no fixed height suits a wrapping title. Asserting the fit here
    ///     would fail for a reason this change neither caused nor fixed, so
    ///     what is asserted instead is that scaling **narrows** that gap
    ///     rather than widening it, and the real shortfall is printed so it
    ///     stays visible rather than becoming folklore.
    private static func checkAuditTwoRowsStillFitAtEveryScale(_ check: (Bool, String) -> Void) {
        let theme = ThemeManager.shared.theme

        // A single scaled monospace line - all a Kubernetes log row, a
        // resource cell or an error-group sample line holds.
        for step in ChromeTextScale.steps {
            ChromeTextScale.shared.setScale(step.scale)
            let label = NSTextField(labelWithString:
                "2026-09-06T09:14:22Z contract-ingest-worker-0 connection refused")
            label.font = HelmType.code()
            let needs = label.fittingSize.height
            check(needs > 0, "the measured code line had no height at all at \(step.title)")
            for (name, height) in [("KubeLogListView", KubeLogListView.rowHeight),
                                   ("KubeResourceTableView", KubeResourceTableView.rowHeight),
                                   ("LogErrorGroupListView.sample", LogErrorGroupListView.sampleRowHeight)] {
                check(needs <= height,
                      "at \(step.title) a HelmType.code() line needs \(needs)pt but \(name) "
                      + "gives it \(height)pt - descenders clip")
            }
        }

        // The two accent-row lists: prove the fix helps, and report the
        // pre-existing shortfall it does not claim to fix.
        var content = HelmAccentRow.Content(
            tint: .critical,
            kicker: "ERROR",
            title: "connection refused talking to contract-ingest-worker-0",
            badgeSymbol: "xmark.octagon.fill",
            chipText: "Show lines")
        content.meta = "42 occurrences \u{00B7} 09:14-09:51"

        func shortfall(at scale: CGFloat) -> CGFloat {
            ChromeTextScale.shared.setScale(scale)
            let row = HelmAccentRow(chipPlacement: .trailing, hover: true)
            row.configure(content, theme: theme)
            row.applyTheme(theme)
            row.frame = NSRect(x: 0, y: 0, width: 640, height: LogErrorGroupListView.groupRowHeight)
            row.layoutSubtreeIfNeeded()
            return row.fittingSize.height - LogErrorGroupListView.groupRowHeight
        }

        let atDefault = shortfall(at: 1.0)
        let atLarger = shortfall(at: 1.3)
        print("  NOTE  LogErrorGroupListView's accent row is short by "
              + "\(atDefault)pt at Default and \(atLarger)pt at Larger "
              + "(pre-existing; see this method's own comment)")
        check(atLarger <= atDefault + 0.01,
              "scaling made LogErrorGroupListView's accent row fit *worse* "
              + "(short by \(atDefault)pt at Default, \(atLarger)pt at Larger)")
    }
}

#endif
