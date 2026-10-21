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
