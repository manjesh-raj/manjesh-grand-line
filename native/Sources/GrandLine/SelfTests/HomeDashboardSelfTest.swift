// Grand Line - native macOS app.
//
// The pure half of the Home page's dashboard layout
// (`fm/grandline-home-page-visual-overhaul`).
//
// Run with `FM_RUN_HOME_DASHBOARD_TESTS=1 .build/debug/GrandLine`.
//
// **Why this suite is pure logic and guards CI's blocking lane.** Every
// question here is arithmetic over numbers, or a function over strings - no
// window, no view, no store. AGENTS.md's rule is that the test is what a
// suite *asserts*, never what it imports, so the render half lives in
// `HomeDashboardViewSelfTest` (window-backed, in `NEEDS_SESSION`) and this
// one runs everywhere.
//
// What it covers, and why each one is worth a check rather than a reading of
// the code:
//
//   1. **`HelmResponsiveGrid.proportionalWidth`'s closure property.** A row
//      whose spans sum to the track count must lay out to *exactly* the
//      container width once the stack's own gap is added. Off by one gutter
//      and the grid is a point or two narrow on every render, which is
//      invisible in a screenshot and permanent.
//   2. **The 7:5 ratio is really 7:5.** The reference's proportions are the
//      design; a formula that divided the gutters differently would still
//      produce two cards that fill the row and would no longer be the
//      captain's layout.
//   3. **`fitsProportionally` discriminates.** A threshold that is always
//      true is not a threshold, so both sides of it are asserted.
//   4. **`HomeCanvasController.sentenceList`**, which is the only place this
//      app builds an "a, b, and c" list and the only one with a serial
//      comma.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit

enum HomeDashboardSelfTest {

    @discardableResult
    static func run() -> Bool {
        var ok = true
        checkARowFillsItsContainerExactly(&ok)
        checkTheReferencesRatio(&ok)
        checkTheNarrowThresholdDiscriminates(&ok)
        checkSentenceList(&ok)

        if ok {
            print("HomeDashboardSelfTest: all checks passed")
        } else {
            print("HomeDashboardSelfTest: FAILED")
        }
        return ok
    }

    /// The reference's own spans, and the gap this app lays cards out with.
    private static let spans = [7, 5]
    private static let gap = HomeCanvasController.gridSpacing

    // MARK: 1 - the closure property

    private static func checkARowFillsItsContainerExactly(_ ok: inout Bool) {
        // Several widths, including an odd one and a half-point one: AGENTS.md
        // records that a GitHub runner is 1x and every dev Mac here is 2x, so
        // a formula that only happens to close on even widths would pass
        // locally and drift in CI.
        for container in [1468.0, 1200.0, 900.0, 1043.0, 1512.5] as [CGFloat] {
            let widths = spans.map {
                HelmResponsiveGrid.proportionalWidth(containerWidth: container,
                                                     span: $0, spacing: gap)
            }
            let laidOut = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
            // The fixture's own discriminating power first: two different
            // spans must produce two different widths, or this whole check
            // would pass against a formula that ignored `span`.
            check(widths[0] > widths[1],
                  "a 7-track card should be wider than a 5-track one at \(container), "
                      + "got \(widths)", &ok)
            check(abs(laidOut - container) < 0.001,
                  "a row of spans \(spans) at \(container)pt should lay out to exactly "
                      + "\(container), got \(laidOut)", &ok)
        }
    }

    // MARK: 2 - the ratio

    private static func checkTheReferencesRatio(_ ok: inout Bool) {
        // At a width where every track is a whole number, the two cards'
        // widths differ by exactly the two extra tracks plus their gutters -
        // which is the arithmetic statement of "7 of 12 beside 5 of 12".
        let unit: CGFloat = 100
        let container = unit * 12 + gap * 11
        let wide = HelmResponsiveGrid.proportionalWidth(containerWidth: container, span: 7, spacing: gap)
        let narrow = HelmResponsiveGrid.proportionalWidth(containerWidth: container, span: 5, spacing: gap)
        check(abs(wide - (unit * 7 + gap * 6)) < 0.001,
              "a 7-track card is 7 units plus 6 gutters, got \(wide)", &ok)
        check(abs(narrow - (unit * 5 + gap * 4)) < 0.001,
              "a 5-track card is 5 units plus 4 gutters, got \(narrow)", &ok)
    }

    // MARK: 3 - the narrow threshold

    private static func checkTheNarrowThresholdDiscriminates(_ ok: inout Bool) {
        let minimum = HomeCanvasController.minModuleWidth
        // A window this app is actually used at: both cards clear the floor.
        check(HelmResponsiveGrid.fitsProportionally(containerWidth: 1468,
                                                    spans: spans,
                                                    minItemWidth: minimum,
                                                    spacing: gap),
              "the dashboard should fit at a 1512pt window's content width", &ok)
        // And one narrow enough that the 5-track card is under a single
        // wrapping column, where the reference collapses to one per row.
        check(!HelmResponsiveGrid.fitsProportionally(containerWidth: 500,
                                                     spans: spans,
                                                     minItemWidth: minimum,
                                                     spacing: gap),
              "the dashboard should decline at 500pt, where a 5-track card is "
                  + "\(HelmResponsiveGrid.proportionalWidth(containerWidth: 500, span: 5, spacing: gap))pt "
                  + "against a \(minimum)pt floor", &ok)
    }

    // MARK: 4 - the session-checks sentence

    private static func checkSentenceList(_ ok: inout Bool) {
        check(HomeCanvasController.sentenceList([]) == "",
              "an empty list is an empty string", &ok)
        check(HomeCanvasController.sentenceList(["a"]) == "a",
              "one part is itself, got \"\(HomeCanvasController.sentenceList(["a"]))\"", &ok)
        check(HomeCanvasController.sentenceList(["a", "b"]) == "a and b",
              "two parts take no comma, got \"\(HomeCanvasController.sentenceList(["a", "b"]))\"", &ok)
        // The reference's own three-clause sentence, which is the case a
        // plain `joined(separator: ", ")` gets wrong.
        let three = HomeCanvasController.sentenceList(["forks behind upstream",
                                                       "tool updates",
                                                       "setup drift"])
        check(three == "forks behind upstream, tool updates, and setup drift",
              "three parts take a serial comma, got \"\(three)\"", &ok)
    }
}
#endif
