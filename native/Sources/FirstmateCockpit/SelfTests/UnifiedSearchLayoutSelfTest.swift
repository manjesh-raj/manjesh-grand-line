// Manjesh Grand Line - native macOS app.
//
// Layout guard for F5's command palette
// (`fm/grandline-feature-f5-command-palette-expansion`), run via
// `FM_RUN_UNIFIED_SEARCH_LAYOUT_TESTS=1 .build/debug/FirstmateCockpit`.
//
// Split out of `UnifiedSearchSelfTest` deliberately: that suite is pure logic
// and runs in CI, this one drives a real `NSPanel` and therefore belongs with
// the window-backed suites the test runner skips in a headless CI container
// (see `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list). Keeping them
// separate is what lets the provider/matching coverage stay CI-enforced.
//
// **What each check was actually demonstrated to catch**, since this project
// holds a self-test to "confirmed to catch a real regression, not just to
// pass" - and two of these honestly do not clear that bar:
//
//   * **Panel height** - CONFIRMED. Measuring one arranged subview instead of
//     summing them reproduced a 107pt palette where a real grouped list is
//     428pt: everything but the first row scrolled off screen.
//     `resizeToFit()` sums per-child fitting heights because a grouped list
//     mixes three row shapes (rows, section headers, overflow lines) at three
//     different heights.
//   * **Chip right-alignment** - CONFIRMED. Loosening the row's own trailing
//     pin to an inequality reproduced 27pt of spread between two identical
//     "Connect ↵" chips, i.e. the ragged status column §5.4 measured on the
//     Updates page (64pt there), where a chip's x drifts with the length of
//     the text beside it.
//   * **Selection clamping** - CONFIRMED. Dropping the upper clamp let
//     arrow-down walk the selection to index 501 of 7 rows - selecting
//     nothing, in a list whose section headers are not rows.
//   * **Chip width** - capable of failing, NOT a fix verification. Forcing a
//     wide chip reports it (261pt in a 580pt row), so the check is live. But
//     three realistic regressions were tried - removing the width tie,
//     removing the text column's low stack-level hugging, and removing both -
//     and none of them actually stretched the chip: this row's structure turns
//     out to resist it from more than one direction. The assertion is kept as
//     a forward guard on an invariant this codebase has broken twice
//     elsewhere, not as evidence that the width tie is load-bearing today.
//   * **Title/chip overlap** - same standing, and weaker. No mechanism tried
//     made the title render under the chip; unpinning the row's trailing edge
//     (the Updates-page mechanism, where nothing had ever made a label's
//     *frame* narrower than its text) shrank the row instead, and was caught
//     by the alignment check above rather than this one. Kept as an invariant.

// GL-27: compiled into debug builds only. Do not remove this guard when
// editing a suite: `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit

enum UnifiedSearchLayoutSelfTest {
    /// A "Connect ↵" chip is a handful of characters. Comfortably above its
    /// real natural width, comfortably below the palette's own 580pt width -
    /// so a chip that has started absorbing the row lands well past this.
    private static let maxChipWidth: CGFloat = 140

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-search-layout-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }
        setenv("FM_HOSTS_FILE", scratchRoot.appendingPathComponent("hosts.json").path, 1)
        defer { unsetenv("FM_HOSTS_FILE") }

        // A real store with real hosts, one of them deliberately long-titled -
        // the case that makes a title run under a chip if nothing truncates.
        let hostStore = HostStore()
        var short = Host(label: "Prod", address: "p.internal")
        short.tags = ["PROD"]
        var long = Host(label: "Prod EKS bastion for the payments platform, eu-west-1, shared", address: "prod-eks-bastion-payments-platform.eu-west-1.internal")
        long.tags = ["PROD"]
        hostStore.add(short)
        hostStore.add(long)

        let index = UnifiedSearchIndex()
        index.register(UnifiedSearchHostProvider(store: hostStore) { _ in })
        // Enough actions to push the palette well past one row, so the height
        // check is measuring a real grouped list rather than a single row.
        index.register(UnifiedSearchActionProvider(actions: (1...5).map { n in
            .init(title: "Prod action \(n)", meta: "Destination", keywords: ["prod"], run: {})
        }))

        let palette = UnifiedSearchController(index: index)
        // No `orderFront` - this measures frames, not pixels. (A probe that
        // sampled *drawn* colour would need it; see AGENTS.md's probe notes.)
        palette.debugReload(query: "prod")
        palette.debugLayoutNow()

        // MARK: 1 - the chip stays a chip

        check(palette.debugRowCount >= 2, "expected at least two host rows to measure, got \(palette.debugRowCount)")
        let width = palette.debugContentWidth
        check(width > 400, "the palette should be its real width for these measurements, got \(width)")
        for i in 0..<palette.debugRowCount {
            guard let geometry = palette.debugRowGeometry(at: i) else {
                failures.append("no geometry for row \(i)")
                continue
            }
            guard !geometry.chipHidden else { continue }
            check(geometry.chipWidth <= maxChipWidth,
                  "row \(i)'s chip is \(geometry.chipWidth)pt wide in a \(geometry.rowWidth)pt row - it is "
                  + "absorbing the row's slack instead of staying at its own width (AGENTS.md gotcha 12)")
            // MARK: 3 - and the title stops before it
            check(geometry.titleMaxX <= geometry.chipMinX + 0.5,
                  "row \(i)'s title runs to \(geometry.titleMaxX) but its chip starts at \(geometry.chipMinX) "
                  + "- the title must truncate, not render under the chip")
        }

        // Every chip in a group must start at the same x, or the column reads
        // ragged row to row - the exact defect §5.4 measured on the Updates
        // page (64pt of pill spread).
        let chipMinXs: [CGFloat] = (0..<palette.debugRowCount).compactMap { i in
            guard let g = palette.debugRowGeometry(at: i), !g.chipHidden else { return nil }
            return g.chipMinX
        }
        if let first = chipMinXs.first {
            // Chips carry different words ("Connect ↵" vs nothing), so compare
            // only rows whose chip text is the same - here every host row's is
            // "Connect ↵", and host rows are the only chipped rows in this
            // fixture, so they must all agree.
            let spread = (chipMinXs.max() ?? first) - (chipMinXs.min() ?? first)
            check(spread < 1.0,
                  "identical chips must be right-aligned to the same x, got \(spread)pt of spread across \(chipMinXs.count) rows")
        }

        // MARK: 2 - the palette is as tall as its content

        let groupedHeight = palette.debugPanelHeight
        check(groupedHeight > 200,
              "a grouped list of 2 hosts + 5 actions across 2 sections should be a real height, got \(groupedHeight)pt "
              + "- a collapsed palette scrolls everything but the first row off screen")

        // ...and shrinks again for a narrower result set, so the height is
        // genuinely measured per reload rather than only ever growing.
        palette.debugReload(query: "Prod EKS bastion for the payments platform")
        palette.debugLayoutNow()
        let narrowHeight = palette.debugPanelHeight
        check(narrowHeight < groupedHeight,
              "a one-result query should size the palette smaller than a seven-result one, got \(narrowHeight) vs \(groupedHeight)")
        check(narrowHeight > 60, "even a one-result palette needs room for its row, got \(narrowHeight)pt")

        // And an empty result set still leaves the "No matches." line visible
        // rather than a zero-height sliver.
        palette.debugReload(query: "zzz-no-such-thing-anywhere")
        palette.debugLayoutNow()
        check(palette.debugRowCount == 0, "a no-match query should render no selectable rows")
        check(palette.debugPanelHeight > 60, "the no-match state still needs its own height, got \(palette.debugPanelHeight)pt")

        // MARK: Selection walks the rendered rows, in order

        palette.debugReload(query: "prod")
        palette.debugLayoutNow()
        let titles = palette.debugItemTitles
        check(palette.debugSelectedIndex == 0, "a fresh query should select the first row")
        palette.debugMoveSelection(by: 1)
        check(palette.debugSelectedIndex == 1, "arrow-down should move one row")
        // The selection must never leave the rendered list - a grouped list's
        // headers are not rows, so an off-by-one here would select nothing.
        palette.debugMoveSelection(by: 500)
        check(palette.debugSelectedIndex == titles.count - 1,
              "arrow-down past the end must clamp to the last row, got \(palette.debugSelectedIndex) of \(titles.count)")
        palette.debugMoveSelection(by: -500)
        check(palette.debugSelectedIndex == 0, "arrow-up past the start must clamp to the first row")
        check(palette.debugRowCount == titles.count,
              "every selectable item must have a rendered row: \(titles.count) items, \(palette.debugRowCount) rows")

        if failures.isEmpty {
            print("UnifiedSearchLayoutSelfTest: OK")
            return true
        }
        print("UnifiedSearchLayoutSelfTest: \(failures.count) failure(s)")
        for f in failures { print("  - \(f)") }
        return false
    }
}

#endif
