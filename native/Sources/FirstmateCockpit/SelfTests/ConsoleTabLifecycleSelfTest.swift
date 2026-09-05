// Manjesh Grand Line - native macOS app.
//
// The general Console tab-lifecycle suite the full-app audit's §7 asked for.
//
// **Why this file exists.** Console's tab collection is, by AGENTS.md's own
// history, "the area with the most hand-verified-then-reverted probes" in this
// project - a long run of captain-reported bugs each verified live with a
// temporary probe that was then deleted, leaving no permanent guard. What
// coverage existed was per-regression and narrow: the forward-drags toggle
// (`TabForwardDragsToggleSelfTest`), Claude-usage button parity
// (`ConsoleClaudeUsageSelfTest`), block-view restart bookkeeping
// (`BlockViewRestartIntegrationSelfTest`) and per-tab SRE Lead
// (`SRELeadPerTabSelfTest`). Each proves its own fix and none of them asserts
// that create / duplicate / rename / close / reconnect and the numbered-name
// convention still behave - so the shared machinery underneath every one of
// those fixes was the least-guarded code in the app.
//
// This drives the **real** `ConsoleController` methods (`newShellTab`,
// `duplicateTab`, `renameTab`, `closeTab`, `select`, `reconnectActive`,
// `numberedName`) mounted in a real, off-screen `NSWindow`, following
// `ConsoleClaudeUsageSelfTest`'s construction pattern.
//
// **`.shell` launches only, deliberately.** A real `.ssh` launch through an
// appeared controller would fork a real `ssh` - genuinely unsafe in a headless
// suite, and the same boundary `TabForwardDragsToggleSelfTest` draws for the
// same reason. Every property asserted here is launch-kind-independent.
//
// Run with:
//   swift build && FM_RUN_CONSOLE_TAB_LIFECYCLE_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ConsoleTabLifecycleSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("aFreshConsoleOpensExactlyOneShellTab", test_freshConsoleHasOneTab),
            ("newShellTabAppendsAndSelects", test_newTabAppendsAndSelects),
            ("numberedNamesCountOnlyOpenTabs", test_numberedNamesCountOnlyOpenTabs),
            ("aClosedNumberIsReusedNotClimbedPast", test_closedNumberIsReused),
            ("noSequenceOfOpensClosesAndRenamesCollides", test_namesNeverCollide),
            ("duplicateCopiesTheLaunchAndSelectsTheCopy", test_duplicateCopiesLaunch),
            ("renameChangesOnlyThatTabsName", test_renameIsScopedToOneTab),
            ("renameNeverTouchesTheProcess", test_renameDoesNotRestart),
            ("closingANonSelectedTabKeepsTheSelection", test_closeNonSelectedKeepsSelection),
            ("closingTheLastTabOpensAFreshShell", test_closingLastTabOpensShell),
            ("closingTheLastTabOnAHostPageLeavesItEmpty", test_hostPageMayEndUpEmpty),
            ("reconnectKeepsTheSameTabAndTerminalView", test_reconnectReusesTheSameTab),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
            ? "ConsoleTabLifecycleSelfTest: all \(cases.count) cases passed"
            : "ConsoleTabLifecycleSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Harness

    /// A real `ConsoleController` in a real, off-screen window.
    ///
    /// `isFirstmateConsole` decides two genuinely different behaviours this
    /// suite covers on both sides: whether `loadView` opens a Shell tab of its
    /// own, and whether closing the last tab reopens one.
    ///
    /// The window is deliberately never ordered front - nothing here reads
    /// pixels, and this machine may be running the captain's own instance.
    private static func makeConsole(isFirstmate: Bool) -> (window: NSWindow, controller: ConsoleController) {
        let controller = ConsoleController(keyStore: SSHKeyStore(),
                                           snippetStore: SnippetStore(),
                                           isFirstmateConsole: isFirstmate)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private static func names(_ c: ConsoleController) -> [String] { c.tabs.map { $0.name } }

    // MARK: Creation

    private static func test_freshConsoleHasOneTab() -> String? {
        let (window, console) = makeConsole(isFirstmate: true)
        defer { console.shutdown(); window.orderOut(nil) }

        // `openFirstmateHost` opens the Shell tab from `loadView`. Since
        // `fm/grand-line-remove-firstmate-mirror` that is the only tab it
        // opens - a second one here would mean the removed Mirror/herdr tab
        // had come back.
        guard console.tabs.count == 1 else {
            return "a fresh Firstmate console should open exactly 1 tab, got \(console.tabs.count): \(names(console))"
        }
        guard console.currentTab === console.tabs[0] else {
            return "the one tab should be the current tab"
        }
        return nil
    }

    private static func test_newTabAppendsAndSelects() -> String? {
        let (window, console) = makeConsole(isFirstmate: false)
        defer { console.shutdown(); window.orderOut(nil) }

        console.newShellTab()
        console.newShellTab()
        guard console.tabs.count == 2 else { return "expected 2 tabs, got \(console.tabs.count)" }
        guard console.currentTab === console.tabs[1] else {
            return "a new tab should become the selected tab"
        }
        return nil
    }

    // MARK: The numbered-name convention

    /// Bare name for the first open tab of a kind, "N" for each concurrent
    /// one after it - `Shell`, `Shell 2`, `Shell 3`.
    private static func test_numberedNamesCountOnlyOpenTabs() -> String? {
        let (window, console) = makeConsole(isFirstmate: false)
        defer { console.shutdown(); window.orderOut(nil) }

        console.newShellTab(); console.newShellTab(); console.newShellTab()
        let expected = ["Shell", "Shell 2", "Shell 3"]
        guard names(console) == expected else {
            return "expected \(expected), got \(names(console))"
        }
        return nil
    }

    /// The half of the convention that is easy to get wrong: the counter is
    /// "how many of this kind are open right now", never a running total. So
    /// closing "Shell 2" and opening a new shell must produce "Shell 2"
    /// again rather than climbing to "Shell 4".
    private static func test_closedNumberIsReused() -> String? {
        let (window, console) = makeConsole(isFirstmate: false)
        defer { console.shutdown(); window.orderOut(nil) }

        console.newShellTab(); console.newShellTab(); console.newShellTab()
        guard let middle = console.tabs.first(where: { $0.name == "Shell 2" }) else {
            return "setup failed - no 'Shell 2' among \(names(console))"
        }
        console.closeTab(id: middle.id)
        console.newShellTab()

        let after = names(console).sorted()
        guard after == ["Shell", "Shell 2", "Shell 3"] else {
            return "after closing 'Shell 2' and opening a new shell, expected the freed number to be "
                 + "reused (Shell/Shell 2/Shell 3), got \(after)"
        }
        return nil
    }

    /// The invariant underneath the convention, and the one a captain
    /// actually sees violated: two chips in the strip with the same label.
    ///
    /// Asserted over a mixed sequence rather than a tidy one, because the
    /// count-based implementation this replaced was correct for
    /// open-three-in-a-row and only broke once a *middle* tab was closed -
    /// so a straight-line case passes happily while the real bug ships.
    private static func test_namesNeverCollide() -> String? {
        let (window, console) = makeConsole(isFirstmate: false)
        defer { console.shutdown(); window.orderOut(nil) }

        console.newShellTab(); console.newShellTab(); console.newShellTab(); console.newShellTab()
        // Close a middle one, open two more, hand-rename one, open another.
        if let middle = console.tabs.first(where: { $0.name == "Shell 2" }) {
            console.closeTab(id: middle.id)
        }
        console.newShellTab()
        console.newShellTab()
        if let third = console.tabs.first(where: { $0.name == "Shell 3" }) {
            console.renameTab(id: third.id, to: "deploys")
        }
        console.newShellTab()

        let all = names(console)
        let unique = Set(all)
        guard all.count == unique.count else {
            let dupes = all.filter { name in all.filter { $0 == name }.count > 1 }
            return "the tab strip has duplicate names \(Set(dupes).sorted()) after a mixed "
                 + "open/close/rename sequence - full strip: \(all)"
        }
        return nil
    }

    // MARK: Duplicate

    private static func test_duplicateCopiesLaunch() -> String? {
        let (window, console) = makeConsole(isFirstmate: false)
        defer { console.shutdown(); window.orderOut(nil) }

        console.newShellTab()
        guard let source = console.currentTab else { return "no tab to duplicate" }
        let sourceKind = source.launch.kindIdentity

        console.duplicateTab(id: source.id)
        guard console.tabs.count == 2 else { return "duplicate should add a tab, got \(console.tabs.count)" }
        guard let copy = console.currentTab, copy !== source else {
            return "the duplicate should become the selected tab, and be a genuinely different tab"
        }
        guard copy.launch.kindIdentity == sourceKind else {
            return "a duplicate re-runs the same launch: expected kind \(sourceKind), got \(copy.launch.kindIdentity)"
        }
        guard copy.terminal !== source.terminal else {
            return "a duplicate must own its own terminal view, not share the source's"
        }
        return nil
    }

    // MARK: Rename

    private static func test_renameIsScopedToOneTab() -> String? {
        let (window, console) = makeConsole(isFirstmate: false)
        defer { console.shutdown(); window.orderOut(nil) }

        console.newShellTab(); console.newShellTab()
        let first = console.tabs[0], second = console.tabs[1]
        let secondNameBefore = second.name

        console.renameTab(id: first.id, to: "deploys")
        guard first.name == "deploys" else { return "rename did not take: \(first.name)" }
        guard second.name == secondNameBefore else {
            return "renaming one tab changed another's name (\(secondNameBefore) -> \(second.name))"
        }
        return nil
    }

    /// A rename is a label change and must never touch the process - the
    /// property `TabModel`'s own doc comment states ("name is per-tab and
    /// never touches the process").
    private static func test_renameDoesNotRestart() -> String? {
        let (window, console) = makeConsole(isFirstmate: false)
        defer { console.shutdown(); window.orderOut(nil) }

        console.newShellTab()
        guard let tab = console.currentTab else { return "no tab" }
        let terminalBefore = ObjectIdentifier(tab.terminal)
        let launchBefore = tab.launch.kindIdentity

        console.renameTab(id: tab.id, to: "renamed")

        guard ObjectIdentifier(tab.terminal) == terminalBefore else {
            return "a rename replaced the tab's terminal view - it must only change the label"
        }
        guard tab.launch.kindIdentity == launchBefore else {
            return "a rename changed the tab's launch recipe"
        }
        return nil
    }

    // MARK: Close

    private static func test_closeNonSelectedKeepsSelection() -> String? {
        let (window, console) = makeConsole(isFirstmate: false)
        defer { console.shutdown(); window.orderOut(nil) }

        console.newShellTab(); console.newShellTab(); console.newShellTab()
        guard let selected = console.currentTab else { return "no selection" }
        let victim = console.tabs.first { $0 !== selected }
        guard let victim else { return "need a non-selected tab" }

        console.closeTab(id: victim.id)
        guard console.currentTab === selected else {
            return "closing a background tab moved the selection - it should not"
        }
        guard !console.tabs.contains(where: { $0 === victim }) else {
            return "the closed tab is still in the collection"
        }
        return nil
    }

    /// The shared Firstmate console never leaves the window empty.
    private static func test_closingLastTabOpensShell() -> String? {
        let (window, console) = makeConsole(isFirstmate: true)
        defer { console.shutdown(); window.orderOut(nil) }

        while console.tabs.count > 1 { console.closeTab(id: console.tabs[0].id) }
        guard let last = console.tabs.first else { return "setup failed - no tab left to close" }

        console.closeTab(id: last.id)
        guard console.tabs.count == 1 else {
            return "closing the last tab on the Firstmate console should open a fresh shell so the "
                 + "window is never empty, got \(console.tabs.count) tab(s)"
        }
        guard console.tabs[0] !== last else { return "the replacement should be a genuinely new tab" }
        return nil
    }

    /// A dedicated host page is *allowed* to reach zero tabs, and must - a
    /// generic shell fallback here would leave `tabs` non-empty, which makes
    /// `connectSSHIfNeeded`'s `tabs.isEmpty` guard believe the host is still
    /// connected and permanently refuse to reopen it (the reasoning
    /// `closeTab` itself records).
    private static func test_hostPageMayEndUpEmpty() -> String? {
        let (window, console) = makeConsole(isFirstmate: false)
        defer { console.shutdown(); window.orderOut(nil) }

        console.newShellTab()
        guard let only = console.tabs.first else { return "setup failed" }
        console.closeTab(id: only.id)

        guard console.tabs.isEmpty else {
            return "a host page must be allowed to reach zero tabs (or reconnecting that host breaks), "
                 + "got \(console.tabs.count): \(names(console))"
        }
        guard console.currentTab == nil else { return "currentTab should be nil with no tabs" }
        return nil
    }

    // MARK: Reconnect

    /// Reconnect restarts the child *in place*: same `TabModel`, same
    /// `CockpitTerminalView`, same launch recipe. That identity is what a
    /// pile of per-tab state depends on surviving - the forward-drags toggle
    /// explicitly relies on it (`AGENTS.md`: "restarts the child process on
    /// the *same* `CockpitTerminalView` instance (never reallocated), so the
    /// toggle survives it with no extra bookkeeping").
    private static func test_reconnectReusesTheSameTab() -> String? {
        let (window, console) = makeConsole(isFirstmate: false)
        defer { console.shutdown(); window.orderOut(nil) }

        console.newShellTab()
        guard let tab = console.currentTab else { return "no tab" }
        let tabID = tab.id
        let terminalBefore = ObjectIdentifier(tab.terminal)
        let nameBefore = tab.name
        tab.terminal.forwardDragsToChild = true

        console.reconnectActive()

        guard console.tabs.count == 1, let after = console.currentTab, after.id == tabID else {
            return "reconnect should restart the same tab, not add or replace one "
                 + "(\(console.tabs.count) tab(s) now)"
        }
        guard ObjectIdentifier(after.terminal) == terminalBefore else {
            return "reconnect replaced the terminal view - per-tab state keyed to it would be lost"
        }
        guard after.name == nameBefore else {
            return "reconnect changed the tab's name (\(nameBefore) -> \(after.name))"
        }
        guard after.terminal.forwardDragsToChild else {
            return "per-tab terminal state must survive a reconnect (forwardDragsToChild was reset)"
        }
        return nil
    }
}

#endif
