// Grand Line - native macOS app.
//
// P9 of the Grand Line vs Automic Vault polish report: the seven pages that
// drew their own navigation column now hold it in a real split view
// (`HelmSplitPage`) - draggable, collapsible, and answering Toggle Sidebar.
//
// Every case drives the real shell: the page is shown through
// `AppShellController.show` and the geometry is read after a real layout
// pass. UX-01 of the 2026-10 review gave the Toggle Sidebar command (⌥⌘S) to
// the Workspace sidebar, the way Mail and Notes use it, so a page's own
// column is collapsed through its split view's own `toggleSidebar` (what a
// divider drag to zero does) and the menu command is asserted to leave it
// alone. Reduce Motion
// is pinned on so a collapse is instant rather than animated; the animated
// path is the same `isCollapsed` change inside an animation group.
//
// Run with:
//   swift build && FM_RUN_SPLIT_SIDEBAR_TESTS=1 .build/debug/GrandLine; echo $?
//
// Window-backed: listed in `run-all-tests.sh`'s `NEEDS_SESSION`.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SplitSidebarSelfTest {

    /// Each page's sidebar pane at its opening width: the column (208) plus
    /// the gutter it was pinned in, and for Tasks the gap to its hairline and
    /// for Settings the band's padding on both sides - i.e. exactly where the
    /// pinned column used to end, so the content starts where it did.
    private static let pages: [(RailDestination, CGFloat)] = [
        (.schedules, 24 + 208),
        (.readingList, HelmMetrics.s3 + 208),
        (.notebook, HelmMetrics.s3 + 208),
        (.poneglyph, 24 + 208),
        (.hosts, 24 + 208),
        (.shift, 24 + 208 + 16),
        (.settings, 24 + 208 + 24),
    ]

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        var ok = true
        for each in [checkEveryPageOpensWhereItWas, checkToggleSidebarCollapsesAndRestores,
                     checkADraggedDividerSticks, checkTasksPutsItsColumnAwayOffTheBoard,
                     checkTheCommandIsANoOpElsewhere] {
            var caseOK = true
            each(&caseOK)
            ok = ok && caseOK
        }
        print(ok ? "SplitSidebarSelfTest: all checks passed" : "SplitSidebarSelfTest: FAILED")
        return ok
    }

    private static func settle(_ shell: AppShellController) {
        shell.view.layoutSubtreeIfNeeded()
        // A window re-derives its frame from its content on a run-loop pass,
        // not inside `layoutSubtreeIfNeeded`; a page that holds the window
        // passes however long this is.
        let until = Date().addingTimeInterval(0.4)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        shell.view.layoutSubtreeIfNeeded()
    }

    private static func split(_ shell: AppShellController, _ dest: RailDestination) -> HelmSplitPage? {
        (shell.debugSlotController(dest) as? HelmSplitPageHosting)?.splitPage
    }

    /// A window whose *content column* is `width` wide: the Workspace
    /// sidebar takes its own room beside the page now, and these cases are
    /// about the page's column at the page widths they always measured.
    private static func mount(width: CGFloat, height: CGFloat) -> (NSWindow, AppShellController) {
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        window.orderFront(nil)
        var frame = window.frame
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: true)
        shell.view.layoutSubtreeIfNeeded()
        frame.size.width = width + shell.nonContentColumnsWidthForTests
        window.setFrame(frame, display: true)
        shell.applySidebarCompactness()
        shell.view.layoutSubtreeIfNeeded()
        frame.size.width = width + shell.nonContentColumnsWidthForTests
        window.setFrame(frame, display: true)
        return (window, shell)
    }

    /// The window width that gives the content column `width`.
    private static func windowWidth(forContent width: CGFloat, _ shell: AppShellController) -> CGFloat {
        width + shell.nonContentColumnsWidthForTests
    }

    // MARK: Cases

    private static func checkEveryPageOpensWhereItWas(_ ok: inout Bool) {
        print("\n-- P9: every sidebar page opens with its column where it was, in a 960pt content column --")
        let (window, shell) = mount(width: 960, height: 620)
        let wanted = window.frame.width
        defer { window.orderOut(nil) }
        for (dest, expected) in pages {
            shell.show(dest)
            settle(shell)
            guard let split = split(shell, dest) else {
                fail("\(dest.rawValue) has no split-view sidebar", &ok)
                continue
            }
            check(!split.isSidebarCollapsed, "\(dest.rawValue) opens with its sidebar collapsed", &ok)
            check(abs(split.debugSidebarWidth - expected) < 0.5,
                  "\(dest.rawValue)'s sidebar opens \(split.debugSidebarWidth)pt wide, expected \(expected)", &ok)
            check(abs(window.frame.width - wanted) < 0.5,
                  "\(dest.rawValue) grew the \(wanted)pt window to \(window.frame.width)pt", &ok)
        }
        if ok { print("  OK   7 pages, each column at its old width, the window held") }
    }

    private static func checkToggleSidebarCollapsesAndRestores(_ ok: inout Bool) {
        print("\n-- P9: collapsing a page's column gives its content the room --")
        let (window, shell) = mount(width: 1300, height: 800)
        let wanted = window.frame.width
        defer { window.orderOut(nil) }
        for (dest, expected) in pages {
            shell.show(dest)
            settle(shell)
            guard let split = split(shell, dest) else { continue }
            let contentBefore = split.contentPane.frame.width
            split.toggleSidebar(nil)
            settle(shell)
            check(split.isSidebarCollapsed, "\(dest.rawValue): its split's toggle did not collapse the column", &ok)
            check(split.contentPane.frame.width > contentBefore + expected - 2,
                  "\(dest.rawValue): collapsed, the content is \(split.contentPane.frame.width)pt, "
                  + "not the column's \(expected)pt wider than \(contentBefore)", &ok)
            check(abs(window.frame.width - wanted) < 0.5, "\(dest.rawValue): collapsing resized the window", &ok)
            split.toggleSidebar(nil)
            settle(shell)
            check(!split.isSidebarCollapsed && abs(split.debugSidebarWidth - expected) < 0.5,
                  "\(dest.rawValue): reopened at \(split.debugSidebarWidth)pt, expected \(expected)", &ok)
        }
        if ok { print("  OK   collapsed and reopened on all 7 pages") }
    }

    private static func checkADraggedDividerSticks(_ ok: inout Bool) {
        print("\n-- P9: a dragged divider holds through a window resize --")
        let (window, shell) = mount(width: 1300, height: 800)
        defer { window.orderOut(nil) }
        shell.show(.schedules)
        settle(shell)
        guard let split = split(shell, .schedules) else { return fail("Schedules has no split", &ok) }
        // Where a drag ends: the split view's own positioning call.
        split.splitView.setPosition(300, ofDividerAt: 0)
        settle(shell)
        check(abs(split.debugSidebarWidth - 300) < 0.5, "the divider did not move to 300 (\(split.debugSidebarWidth))", &ok)
        var frame = window.frame
        frame.size.width = windowWidth(forContent: 1500, shell)
        window.setFrame(frame, display: true)
        settle(shell)
        check(abs(split.debugSidebarWidth - 300) < 0.5,
              "a wider window moved the dragged column to \(split.debugSidebarWidth)pt - the content should take the room", &ok)
        split.splitView.setPosition(1000, ofDividerAt: 0)
        settle(shell)
        check(split.debugSidebarWidth <= HelmPageSidebar.width * 1.6 + 0.5,
              "the column was dragged past its maximum, to \(split.debugSidebarWidth)pt", &ok)
        if ok { print("  OK   held at 300pt through a resize, and capped at its maximum") }
    }

    private static func checkTasksPutsItsColumnAwayOffTheBoard(_ ok: inout Bool) {
        print("\n-- P9: Tasks' column belongs to its board, and keeps the captain's own choice --")
        let (window, shell) = mount(width: 1300, height: 800)
        defer { window.orderOut(nil) }
        shell.show(.shift)
        settle(shell)
        guard let split = split(shell, .shift) else { return fail("Tasks has no split", &ok) }
        let tasks = shell.debugShift
        tasks.showWeeklyReview()
        settle(shell)
        check(split.isSidebarCollapsed, "Weekly Review left the board's column open", &ok)
        split.toggleSidebar(nil)
        settle(shell)
        check(split.isSidebarCollapsed, "toggling reopened a column the page had put away", &ok)
        tasks.showDashboard()
        settle(shell)
        check(!split.isSidebarCollapsed, "back on the board, the column did not come back", &ok)
        // The captain's own collapse survives a trip to the review.
        split.toggleSidebar(nil)
        settle(shell)
        tasks.showWeeklyReview()
        settle(shell)
        tasks.showDashboard()
        settle(shell)
        check(split.isSidebarCollapsed, "a trip to Weekly Review undid the captain's own collapse", &ok)
        split.toggleSidebar(nil)
        settle(shell)
        if ok { print("  OK   put away on Weekly Review, back on the board, the captain's collapse kept") }
    }

    private static func checkTheCommandIsANoOpElsewhere(_ ok: inout Bool) {
        print("\n-- UX-01: Toggle Sidebar is the Workspace sidebar's, and leaves a page's column alone --")
        let (window, shell) = mount(width: 1300, height: 800)
        defer { window.orderOut(nil) }
        shell.show(.schedules)
        settle(shell)
        guard let page = split(shell, .schedules) else { return fail("Schedules has no split", &ok) }
        shell.toggleSidebarFromMenu()
        settle(shell)
        check(shell.split.sidebarItem.isCollapsed, "⌥⌘S did not collapse the Workspace sidebar", &ok)
        check(!page.isSidebarCollapsed, "⌥⌘S collapsed Schedules' own column as well", &ok)
        shell.toggleSidebarFromMenu()
        settle(shell)
        check(!shell.split.sidebarItem.isCollapsed, "a second ⌥⌘S did not bring the Workspace sidebar back", &ok)
        if ok { print("  OK   the Workspace sidebar collapsed and returned; the page's column untouched") }
    }
}

#endif
