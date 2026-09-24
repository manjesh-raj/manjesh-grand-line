// Grand Line - native macOS app.
//
// Regression coverage for the two captain-requested changes to Setup >
// GitHub Sync (`fm/grand-line-github-sync-page-refresh-cleanup`), and for
// the one property those two changes could plausibly break together.
//
// 1. The page led with a wrapping subtitle ("Pulls the latest upstream
//    changes into each of your personal forks - fast-forward only, via
//    'gh repo sync'...") that restated what the page's own rows already show,
//    one line under a drill header that already names the destination. The
//    captain had it removed. A deleted view leaves no trace in a diff a
//    reader would notice re-adding, so the absence is asserted from the real
//    view tree.
//
// 2. The page gained the same Refresh control Setup > Updates has carried
//    since `cockpit-updates-redesign`, so a captain can re-run the sync-status
//    checks without leaving and re-entering the destination. It is the shared
//    `HelmRefreshPill` rather than a second hand-rolled copy of that recipe -
//    which is what "the same button as Updates" has to mean to still be true
//    a release from now, and is also what keeps the component's own
//    `normalColor`/`hoverColor` rule (see `UpdatesRefreshButtonThemeSelfTest`)
//    from being re-derived wrong by a second page.
//
// 3. **The property worth pinning hardest: Refresh is read-only.** This page
//    already owns a "Sync All" button that fast-forwards real forks on
//    GitHub, and the captain flagged the risk of the two being confused
//    explicitly. A Refresh that reached `sync(_:)` would look identical on
//    screen and mutate eight real repositories. `checkRefreshNeverSyncs`
//    below is a source guard for that, deliberately: the behavioural half
//    cannot run here, because `GitHubSyncSource.check` shells out to real
//    `gh` against the captain's real forks and has no test seam, so driving
//    the real click in CI would mean eight network round trips per run. That
//    half was verified live instead - a real mounted page, a real click on
//    the real pill, every row observed entering "Checking..." and none
//    entering "Syncing..." - see this task's PR description.
//
// Deliberately window-free, so this runs on the blocking CI lane: nothing
// here needs a composited window, only a real `loadView()` and a real layout
// pass. Adding an `NSWindow` would move the whole suite onto the
// window-backed lane (see `E2ETestingPolicySelfTest`) for no extra coverage.
//
// Run with:
//   swift build && FM_RUN_GITHUB_SYNC_REFRESH_TESTS=1 \
//     .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum GitHubSyncRefreshSelfTest {

    private static var failures: [String] = []

    private static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        // `detail` carries the measured number, which is the whole point of
        // the line - so it goes into the recorded message rather than being
        // dropped on the way to the shared reporter.
        let suffix = detail.isEmpty ? "" : "  [\(detail)]"
        SelfTestAssertions.recordNarrated(condition, "\(label)\(suffix)", into: &failures)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        var out: [NSView] = [view]
        for sub in view.subviews { out.append(contentsOf: descendants(of: sub)) }
        return out
    }

    private static func labelText(in view: NSView) -> [String] {
        descendants(of: view)
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A real page, laid out at a real width, with no window: the page's own
    /// `viewWillAppear` is deliberately NOT called, because that is what
    /// kicks off the first-visit `gh` sweep.
    private static func mountedPage() -> GitHubSyncController {
        let vc = GitHubSyncController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 900)
        vc.view.layoutSubtreeIfNeeded()
        return vc
    }

    // MARK: 1 - the subtitle is gone

    private static func checkSubtitleIsGone() {
        print("\n-- the page's leading subtitle is gone --")
        let texts = labelText(in: mountedPage().view)
        // Fragments rather than the whole sentence: the string carried curly
        // quotes and a soft hyphen, so an exact-match assertion would be
        // fragile in the direction that makes it silently stop checking.
        for fragment in [
            "Pulls the latest upstream",
            "fast-forward only",
            "manually declared upstream",
            "never force-synced",
        ] {
            check(
                "no label still carries \u{201c}\(fragment)\u{201d}",
                !texts.contains { $0.contains(fragment) }
            )
        }
    }

    // MARK: 2 - the Refresh pill, and that it is the shared component

    private static func checkRefreshPill() {
        print("\n-- the Refresh pill --")
        let vc = mountedPage()
        let pills = descendants(of: vc.view).compactMap { $0 as? HelmRefreshPill }
        check("exactly one HelmRefreshPill on the page", pills.count == 1, "found \(pills.count)")
        guard let pill = pills.first else { return }

        check("it is labelled Refresh", labelText(in: pill).contains("Refresh"),
              labelText(in: pill).joined(separator: "|"))
        check("it carries a tooltip naming what it re-checks",
              (pill.toolTip ?? "").localizedCaseInsensitiveContains("re-check"),
              pill.toolTip ?? "nil")

        // GL-16: a recognizer-driven control is only reachable by VoiceOver
        // and by the keyboard once something is genuinely wired to it -
        // `isActivatable` is the one definition of that, and it is false for
        // a pill whose `setAction` call was dropped.
        check("it is activatable (a11y press, focus ring, Return/Space)", pill.isActivatable)
        check("it announces as a button", pill.accessibilityRole() == .button)

        // Review #3's UI5 moved this pill off a toolbar row of its own and
        // into the Repos card header's trailing action cluster - because a
        // pill alone in a 40pt row is what that finding measured. So the
        // question is no longer "is it at the page's trailing edge" (it is
        // not, and must not be: it is inset by the card) but "is it still at
        // the trailing end of the header it now lives in".
        //
        // Asserted against the card's own bounds rather than the page's, and
        // the card is found from the pill rather than assumed, so this still
        // fails if the pill is dropped somewhere arbitrary.
        var host: NSView? = pill.superview
        while let current = host, !(current is HelmCard) { host = current.superview }
        guard let card = host else {
            check("the Refresh pill lives inside a HelmCard", false); return
        }
        check("the Refresh pill lives inside a HelmCard", true)
        // The *cluster* is trailing-anchored, and Sync All is its last member
        // (see `checkRefreshIsDistinctFromSyncAll`), so the pill's own maxX is
        // one button short of the card's edge. Measure the thing that is
        // actually meant to be true: the pill is in the trailing half of its
        // header, not parked at the leading edge beside the title.
        let frame = pill.convert(pill.bounds, to: card)
        check("it sits in its card header's trailing action cluster",
              frame.minX > card.bounds.width / 2,
              "minX \(frame.minX) of \(card.bounds.width)")
    }

    // MARK: 3 - Refresh is not a second Sync All

    private static func checkRefreshIsDistinctFromSyncAll() {
        print("\n-- Refresh is visibly distinct from Sync All --")
        let vc = mountedPage()
        let all = descendants(of: vc.view)
        let pill = all.compactMap { $0 as? HelmRefreshPill }.first
        let syncAll = all.compactMap { $0 as? HelmButton }.first { $0.title == "Sync All" }

        // This one check also covers the direction worth worrying about. A
        // refactor that swept Sync All up into the shared pill component
        // would render plausibly, and would have turned this page's one
        // mutating action into a small trailing pill - leaving no
        // `HelmButton` titled "Sync All" for this lookup to find. Asserting
        // `!(syncAll is HelmRefreshPill)` on top would be a tautology the
        // compiler itself rejects: `HelmRefreshPill` descends from
        // `HoverHighlightView`, `HelmButton` from `NSButton`.
        check("the Sync All button still exists, and is still a HelmButton", syncAll != nil)

        guard let pill, let syncAll else { return }
        let pillFrame = pill.convert(pill.bounds, to: vc.view)
        let syncFrame = syncAll.convert(syncAll.bounds, to: vc.view)
        check("they do not overlap", !pillFrame.intersects(syncFrame),
              "refresh \(pillFrame) vs syncAll \(syncFrame)")
        // UI5: the two now sit side by side in one header action cluster
        // rather than in a row and a card below it, so "above" is no longer
        // the relationship to pin. What still has to hold - and is what the
        // captain's own concern was about - is that the read-only pill is
        // never mistaken for the mutating button: they are separate controls,
        // they do not overlap (asserted above), Sync All is the trailing one
        // (the position a primary action holds everywhere in this app), and
        // they are two different classes with two different looks.
        check("Sync All is the trailing action of the pair", syncFrame.minX > pillFrame.minX,
              "refresh minX \(pillFrame.minX), syncAll minX \(syncFrame.minX)")
        check("they share one row rather than one being buried elsewhere",
              abs(pillFrame.midY - syncFrame.midY) < 6,
              "refresh midY \(pillFrame.midY), syncAll midY \(syncFrame.midY)")
    }

    // MARK: 4 - source guard: Refresh can never reach a sync

    private static func checkRefreshNeverSyncs() {
        print("\n-- source guard: Refresh re-checks, and cannot sync --")
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP sources are not next to this binary")
            return
        }
        let path = dir.appendingPathComponent("GitHubSyncController.swift")
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else {
            check("GitHubSyncController.swift is readable", false, path.path)
            return
        }
        // Strip whole-line comments first: this file discusses `syncAll` at
        // length in the very doc comments that explain why Refresh must not
        // reach it, and a naive grep would trip on its own explanation.
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        func body(of signature: String) -> String? {
            guard let start = code.range(of: signature) else { return nil }
            var depth = 0
            var started = false
            var out = ""
            for ch in code[start.lowerBound...] {
                if ch == "{" { depth += 1; started = true }
                if started { out.append(ch) }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { return out }
                }
            }
            return nil
        }

        if let tapped = body(of: "@objc private func refreshTapped()") {
            check("refreshTapped() runs the check sweep", tapped.contains("checkAll()"), tapped)
            check("refreshTapped() never calls syncAll()", !tapped.contains("syncAll("), tapped)
            check("refreshTapped() never calls sync()", !tapped.contains("sync(row"), tapped)
        } else {
            check("refreshTapped() exists", false)
        }

        if let sweep = body(of: "private func checkAll()") {
            check("checkAll() never calls syncAll()", !sweep.contains("syncAll("))
            // `check(row)` is the read-only call; `sync(row)` is the mutating
            // one. The two differ by three characters at the call site, which
            // is exactly why this is worth asserting rather than reviewing.
            check("checkAll() never calls sync(row)", !sweep.contains("sync(row"))
            check("checkAll() drives the per-repo check", sweep.contains("check(row)"))
        } else {
            check("checkAll() exists", false)
        }
    }

    // MARK: Entry point

    static func run() -> Bool {
        failures = []
        print("GitHubSyncRefreshSelfTest")
        checkSubtitleIsGone()
        checkRefreshPill()
        checkRefreshIsDistinctFromSyncAll()
        checkRefreshNeverSyncs()
        if failures.isEmpty {
            print("\nGitHubSyncRefreshSelfTest: all checks passed")
            return true
        }
        print("\nGitHubSyncRefreshSelfTest: \(failures.count) check(s) failed")
        for f in failures { print("  - \(f)") }
        return false
    }
}

#endif
