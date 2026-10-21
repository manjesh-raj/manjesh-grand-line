// Grand Line - native macOS app.
//
// The page-level polish findings UXP-01 to UXP-20 of the 2026-10 full review.
// One case (or a few) per finding, each written against what is drawn rather
// than what a helper computed, and each confirmed to fail with its fix
// reverted - the PR that added this file names the injection per case.
//
// Window-backed: every case mounts a real page in an `OffScreenProbe` window,
// and several read resolved geometry from a real layout pass.
//
//   swift build && FM_RUN_PAGE_POLISH_UXP_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum PagePolishUXPSelfTest {

    static func run() -> Bool {
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        let cases: [(String, () -> Bool)] = [
            ("uxp01ReviewDrawsDashesNotZerosAfterATotalFailure", uxp01ReviewDrawsDashesNotZeros),
            ("uxp01ReviewKeepsRealCountsOnAPartialFailure", uxp01ReviewKeepsRealCountsOnAPartialFailure),
            ("uxp01SearchPillKeepsItsPlaceholderBesideALongSubtitle", uxp01SearchPillKeepsItsPlaceholder),
            ("uxp02ProjectCardsRepaintOnAThemeSwitch", uxp02ProjectCardsRepaintOnAThemeSwitch),
            ("uxp03WeeklyReviewKeepsThePageMargin", uxp03WeeklyReviewKeepsThePageMargin),
            ("uxp09ReviewForgePlaceholderRowIsTallEnoughToDraw", uxp09ForgePlaceholderRowIsTallEnough),
        ]
        var failed = 0
        for (name, body) in cases {
            let passed = autoreleasepool { body() }
            print(passed ? "PASS \(name)" : "FAIL \(name)")
            if !passed { failed += 1 }
        }
        print(failed == 0
              ? "PagePolishUXPSelfTest: all \(cases.count) cases passed"
              : "PagePolishUXPSelfTest: \(failed)/\(cases.count) cases FAILED")
        return failed == 0
    }

    // MARK: Helpers

    private static func mountReview() -> (window: NSWindow, controller: ReviewController) {
        let controller = ReviewController()
        let window = OffScreenProbe.window(width: 1512, height: 950)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1512, height: 950)
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private static func pr(_ index: Int, forge: String = "github", checks: String = "green") -> MergedPR {
        MergedPR(source: "forge", taskID: nil, repo: "acme/repo-\(index)",
                 url: "https://github.com/acme/repo-\(index)/pull/\(index)", number: index,
                 title: "Change \(index)", checks: checks, forge: forge)
    }

    // MARK: UXP-01

    /// A scan that could not list the projects folder read nothing, so the
    /// three tiles are unknown. They used to read 0 / 0 / 0 under a sentence
    /// saying the folder could not be read (GL-14), and the drill subtitle
    /// carried the whole path.
    private static func uxp01ReviewDrawsDashesNotZeros() -> Bool {
        var ok = true
        let (window, review) = mountReview()
        defer { _ = window }
        review.debugRender([], scan: OpenPRsSource.FetchResult(projectsUnreadable: true))
        review.view.layoutSubtreeIfNeeded()

        let tiles = review.debugStatTiles
        check(tiles.count == 3, "UXP-01: Review should draw three stat tiles, drew \(tiles.count)", &ok)
        for tile in tiles {
            check(tile.value != "0", "UXP-01: the \(tile.caption) tile reads 0 after a failed read", &ok)
            check(tile.value == HelmReading<Int>.dash,
                  "UXP-01: the \(tile.caption) tile should draw a dash, drew \"\(tile.value)\"", &ok)
        }
        check(review.debugStatTileToolTips.allSatisfy { ($0 ?? "").contains(FirstmateHome.projects.path) },
              "UXP-01: each unknown tile should carry the failure as its tooltip", &ok)

        let subtitle = review.drillHeaderSubtitle ?? ""
        check(!subtitle.contains("/"), "UXP-01: the drill subtitle carries a path: \"\(subtitle)\"", &ok)
        check(subtitle.count <= 40, "UXP-01: the drill subtitle is \(subtitle.count) characters long", &ok)

        check(review.debugIsFailureStateVisible, "UXP-01: a total failure should show one failure block", &ok)
        check(!review.debugAreForgeSectionsVisible,
              "UXP-09: a total failure should hide the two forge cards that have nothing to say", &ok)
        check(!review.debugIsBodySubtitleVisible,
              "UXP-01: the body line should give way to the failure block, not repeat it", &ok)

        // The path is behind the disclosure, once.
        check(!review.debugFailureStateBody.contains(FirstmateHome.projects.path),
              "UXP-01: the path should be behind the disclosure, not in the block's first read", &ok)
        review.debugToggleFailureDetail()
        check(review.debugFailureStateBody.contains(FirstmateHome.projects.path),
              "UXP-01: Show folder path should reveal the projects path", &ok)

        // A later clean render puts the page back.
        review.debugRender([pr(1)], scan: OpenPRsSource.FetchResult())
        check(!review.debugIsFailureStateVisible && review.debugAreForgeSectionsVisible,
              "UXP-01: a clean scan after a failure should restore the forge cards", &ok)
        check(review.debugStatTiles.first?.value == "1", "UXP-01: a clean scan should count its one PR", &ok)
        return ok
    }

    /// A partial failure found real PRs, so its counts stand - with a tooltip
    /// that says they cover only the repositories that answered.
    private static func uxp01ReviewKeepsRealCountsOnAPartialFailure() -> Bool {
        var ok = true
        let (window, review) = mountReview()
        defer { _ = window }
        review.debugRender([pr(1), pr(2, checks: "pending")],
                           scan: OpenPRsSource.FetchResult(prs: [], failedRepos: ["a", "b"]))
        let values = review.debugStatTiles.map(\.value)
        check(values.first == "2", "UXP-01: a partial failure should keep its found count, drew \(values)", &ok)
        check(!review.debugIsFailureStateVisible, "UXP-01: a partial failure is not the total-failure block", &ok)
        check(review.debugStatTileToolTips.allSatisfy { ($0 ?? "").contains("only the repositories") },
              "UXP-01: a partial failure's tiles should say what their counts cover", &ok)
        check(review.drillHeaderSubtitle == "Couldn't reach the forge for 2 repositories.",
              "UXP-01: unexpected partial-failure subtitle \(review.drillHeaderSubtitle ?? "nil")", &ok)
        return ok
    }

    /// The search pill holds its whole placeholder beside the longest drill
    /// subtitle a page can produce. It used to collapse to "Se…".
    private static func uxp01SearchPillKeepsItsPlaceholder() -> Bool {
        var ok = true
        ThemeManager.shared.setTheme(HelmTheme.theme(id: "dusk") ?? ThemeManager.shared.theme)
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { _ = window }
        shell.show(.review)
        let bar = shell.barForTests
        bar.setDrillContext(.init(title: "Review", subtitle: String(repeating: "Couldn't read a path ", count: 10),
                                  symbol: "arrow.triangle.branch", hue: .green, artwork: nil))
        shell.view.layoutSubtreeIfNeeded()
        guard let pill = bar.debugSearchPill() as? DaylightSearchPill else {
            fail("UXP-01: the bar's search pill is not a DaylightSearchPill", &ok)
            return ok
        }
        let readable = pill.debugReadableWidth
        check(readable > 120, "UXP-01: the pill's readable width should be a real placeholder width, got \(readable)", &ok)
        check(pill.debugFloorWidth >= readable - 0.5,
              "UXP-01: the pill's floor is \(pill.debugFloorWidth), below its readable width \(readable)", &ok)
        check(pill.frame.width >= readable - 0.5,
              "UXP-01: the pill collapsed to \(pill.frame.width)pt beside a long subtitle (needs \(readable))", &ok)
        check(!pill.debugPlaceholderIsTruncated, "UXP-01: the search placeholder is truncated", &ok)
        return ok
    }

    // MARK: UXP-02

    private static func withScratchShiftStore(_ body: (ShiftStore) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-polish-uxp-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore())
    }

    private static func mountShift(_ store: ShiftStore) -> (window: NSWindow, controller: ShiftController) {
        let controller = ShiftController(store: store)
        let window = OffScreenProbe.window(width: 1512, height: 950)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1512, height: 950)
        controller.debugRender()
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private static func sameColor(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    /// A project card built under Dusk is repainted when the theme flips to
    /// Daylight, with no data render in between. It used to keep Dusk's
    /// near-white title on Daylight's white card.
    private static func uxp02ProjectCardsRepaintOnAThemeSwitch() -> Bool {
        var ok = true
        guard let dusk = HelmTheme.theme(id: "dusk"), let daylight = HelmTheme.theme(id: "daylight") else {
            fail("UXP-02: the dusk and daylight palettes should exist", &ok)
            return ok
        }
        // The fixture only discriminates if the two inks really differ.
        check(!sameColor(HelmTheme.nsColor(dusk.chromeInkHex), HelmTheme.nsColor(daylight.chromeInkHex)),
              "UXP-02: Dusk's and Daylight's ink should differ, or this case cannot fail", &ok)
        ThemeManager.shared.setTheme(dusk)
        withScratchShiftStore { store in
            var project = ShiftProject.fresh()
            project.name = "Infra hardening"
            store.addProject(project)
            let (window, shift) = mountShift(store)
            defer { _ = window }
            guard let card = shift.debugProjectCards.first else {
                fail("UXP-02: the Tasks page built no project card for a seeded project", &ok)
                return
            }
            check(sameColor(card.debugNameColor, HelmTheme.nsColor(dusk.chromeInkHex)),
                  "UXP-02: the card's title should start in Dusk's ink", &ok)
            ThemeManager.shared.setTheme(daylight)
            check(shift.debugProjectCards.first === card,
                  "UXP-02: a theme switch should repaint the card, not rebuild it (GL-24)", &ok)
            check(sameColor(card.debugNameColor, HelmTheme.nsColor(daylight.chromeInkHex)),
                  "UXP-02: after a switch to Daylight the card's title is still painted "
                  + "\(card.debugNameColor.map { "\($0)" } ?? "nil")", &ok)
        }
        ThemeManager.shared.setTheme(dusk)
        return ok
    }

    // MARK: UXP-03

    /// Weekly Review collapses the column, and its content keeps the page's
    /// own gutter from the window edge. It used to sit about 7pt from it,
    /// because the inset the other views had came from the column.
    private static func uxp03WeeklyReviewKeepsThePageMargin() -> Bool {
        var ok = true
        withScratchShiftStore { store in
            let (window, shift) = mountShift(store)
            defer { _ = window }
            let board = shift.debugContentLeadingInWindow
            check(shift.debugContentStartsAfterSidebar, "UXP-03: the board should show the column", &ok)
            // The fixture discriminates only if the board's content really
            // starts past a column.
            check(board.tabs > 200, "UXP-03: the board's content should start after the column, at \(board.tabs)", &ok)

            shift.debugShowView("review")
            let review = shift.debugContentLeadingInWindow
            check(!shift.debugContentStartsAfterSidebar, "UXP-03: Weekly Review should collapse the column", &ok)
            check(review.reviewHeader >= HelmMetrics.pageGutter - 0.5,
                  "UXP-03: the review header sits \(review.reviewHeader)pt (tabs \(review.tabs)) from the window edge, "
                  + "under the \(HelmMetrics.pageGutter)pt page gutter", &ok)
            check(review.tabs >= HelmMetrics.pageGutter - 0.5,
                  "UXP-03: the view switcher sits \(review.tabs)pt from the window edge on Review", &ok)

            // Back on the board the content returns to where it was.
            shift.debugShowView("board")
            let back = shift.debugContentLeadingInWindow
            check(abs(back.tabs - board.tabs) < 0.5,
                  "UXP-03: the board's content moved from \(board.tabs) to \(back.tabs) after a visit to Review", &ok)

            // The captain's own Toggle Sidebar on the board gets the same gutter.
            shift.debugToggleSidebar()
            let toggled = shift.debugContentLeadingInWindow
            check(toggled.tabs >= HelmMetrics.pageGutter - 0.5,
                  "UXP-03: with the column hidden by Toggle Sidebar the content sits \(toggled.tabs)pt from the edge", &ok)
            shift.debugToggleSidebar()
        }
        return ok
    }

    // MARK: UXP-09

    /// The placeholder row of an empty or unavailable forge list is as tall
    /// as the table, so its glyph and words are drawn inside the box.
    private static func uxp09ForgePlaceholderRowIsTallEnough() -> Bool {
        var ok = true
        let (window, review) = mountReview()
        defer { _ = window }
        review.debugRender([pr(1, forge: "bitbucket")],
                           scan: OpenPRsSource.FetchResult(prs: [], failedRepos: ["a"]))
        let height = review.debugGithubPlaceholderRowHeight
        check(height >= ReviewPRListView.emptyRowHeight - 0.5,
              "UXP-09: the empty GitHub list's placeholder row is \(height)pt in a "
              + "\(ReviewPRListView.emptyRowHeight)pt table", &ok)
        return ok
    }
}

#endif
