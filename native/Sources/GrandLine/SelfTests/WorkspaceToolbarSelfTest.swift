// Grand Line - native macOS app.
//
// R4-UI-01 of full review #4: the sidebar shell's window toolbar, at the
// captain's own window width (1512pt), on every module.
//
//   1. **At Larger text nothing overflows, on any module.** The compact
//      toolbar's breakpoint follows the chrome text scale
//      (`WorkspaceToolbar.compactWidth(scale:)`). At a fixed 1240 the full
//      toolbar stayed on at 1512 with Larger text, and Crew, Connections,
//      Console, Knowledge and Setup each put two to four items in the
//      overflow menu, the inspector button among them every time.
//   2. **The inspector button stays on the toolbar on every page that fills
//      the inspector**, at Default and at Larger text. On Connections it was
//      the first item AppKit pushed into the overflow menu, on the one module
//      where the inspector is the editing surface. Whatever does overflow at
//      Default runs from the overflow menu.
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_WORKSPACE_TOOLBAR_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum WorkspaceToolbarSelfTest {

    static let captainWidth: CGFloat = 1512

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let captainScale = ChromeTextScale.shared.scale
        defer { ChromeTextScale.shared.setScale(captainScale) }

        var allOK = true
        var ok = true
        checkTheBreakpointFollowsTheTextScale(&ok)
        allOK = allOK && ok
        for step in ChromeTextScale.steps where step.title == "Default" || step.title == "Larger" {
            ChromeTextScale.shared.setScale(step.scale)
            autoreleasepool {
                var ok = true
                checkEveryModule(at: step, &ok)
                allOK = allOK && ok
            }
        }
        print(allOK ? "WorkspaceToolbarSelfTest: all checks passed" : "WorkspaceToolbarSelfTest: FAILED")
        return allOK
    }

    private static func checkTheBreakpointFollowsTheTextScale(_ ok: inout Bool) {
        check(WorkspaceToolbar.compactWidth(scale: 1.0) == WorkspaceToolbar.compactWidth,
              "at Default text the compact breakpoint moved from \(WorkspaceToolbar.compactWidth)", &ok)
        // The fixture's own discriminating power: the captain's width has to
        // sit between the two breakpoints, or the per-module check below
        // measures the same toolbar twice.
        check(WorkspaceToolbar.compactWidth(scale: 1.0) < captainWidth
                && WorkspaceToolbar.compactWidth(scale: 1.3) > captainWidth,
              "1512pt is not between the Default and Larger breakpoints", &ok)
    }

    /// Every module's first page, in one shell built at `step`'s text scale
    /// (a launch at that size, as the tour lab's `textscale` does).
    private static func checkEveryModule(at step: (title: String, scale: CGFloat), _ ok: inout Bool) {
        let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        var frame = window.frame
        frame.size.width = captainWidth
        window.setFrame(frame, display: true)
        settle(shell)
        let larger = step.scale > 1.2
        check(shell.toolbar.debugIsCompact == larger,
              "at \(step.title) text and 1512pt the toolbar is \(shell.toolbar.debugIsCompact ? "" : "not ")compact", &ok)
        var sawInspectorPage = false
        for module in WorkspaceModule.allCases {
            guard let route = ModuleTable.routes(in: module).first else { continue }
            shell.workspace.navigator.show(route)
            settle(shell)
            let overflowed = overflowedItems(window)
            let ids = overflowed.map(\.itemIdentifier.rawValue)
            if larger {
                check(overflowed.isEmpty, "at Larger text and 1512pt \(module.rawValue) overflowed \(ids)", &ok)
            }
            if shell.debugInspectorSource != nil {
                sawInspectorPage = true
                check(!overflowed.contains { $0.itemIdentifier == WorkspaceToolbar.ItemID.inspector },
                      "at \(step.title) text and 1512pt \(module.rawValue) fills the inspector and its button overflowed",
                      &ok)
                check(shell.toolbar.debugInspectorItem?.visibilityPriority == .high,
                      "\(module.rawValue) fills the inspector and its button is not .high", &ok)
            } else {
                check(shell.toolbar.debugInspectorItem?.visibilityPriority == .low,
                      "\(module.rawValue) has no inspector content and its button outranks the page's items", &ok)
            }
            for item in overflowed {
                check(runsFromTheOverflowMenu(item),
                      "at \(step.title) text \(module.rawValue)'s \(item.itemIdentifier.rawValue) overflowed with nothing to run",
                      &ok)
            }
        }
        // Connections is the page the review measured; without a page that
        // fills the inspector the inspector half above asserts nothing.
        check(sawInspectorPage, "no module's first page fills the inspector - the check is vacuous", &ok)
    }

    private static func overflowedItems(_ window: NSWindow) -> [NSToolbarItem] {
        let visible = Set((window.toolbar?.visibleItems ?? []).map(\.itemIdentifier))
        return (window.toolbar?.items ?? []).filter {
            !visible.contains($0.itemIdentifier) && $0.itemIdentifier != .flexibleSpace
                && $0.itemIdentifier != .space && $0.itemIdentifier != .sidebarTrackingSeparator
        }
    }

    /// The same rule `MainSplitShellSelfTest` applies on Notebook: an image
    /// item runs its own action, and a view item needs a submenu or a real
    /// target, because AppKit's synthesised form for a view item runs nothing.
    private static func runsFromTheOverflowMenu(_ item: NSToolbarItem) -> Bool {
        let form = item.menuFormRepresentation
        let realTarget = form?.target.map { !($0 is NSToolbarItem) } ?? false
        return item.view == nil ? item.action != nil
            : (form?.submenu != nil || (realTarget && form?.action != nil))
    }

    private static func settle(_ shell: MainSplitShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }
}

#endif
