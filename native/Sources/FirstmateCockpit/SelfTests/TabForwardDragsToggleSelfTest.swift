// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for the tab-lifecycle half of the "Forward Drags to
// This Tab's Program" toggle (`fm/grandline-terminal-selection-sidebar-bleed`)
// - the `ConsoleController`/`TabChipView` wiring around
// `CockpitTerminalView.forwardDragsToChild`, not the mouse-routing formula
// itself. That half is `TerminalSelectionRenderSelfTest.swift`'s case 7,
// proven from real pixels and real captured bytes; this file drives the
// *real* `ConsoleController.newShellTab`/`duplicateTab`/
// `toggleForwardDragsToChild` - not reimplementations - following
// `ConsoleClaudeUsageSelfTest.swift`'s construction pattern (a real
// `ConsoleController` mounted in a real, off-screen `NSWindow`).
//
// Only `.shell` launches are used here, on purpose - see
// `CockpitTerminalView.forwardDragsToChild`'s own doc comment and
// `data/grandline-terminal-selection-sidebar-bleed/report.md` for why the
// toggle is `.shell`-only, and `TerminalSelectionRenderSelfTest`'s case 5 for
// the source guard proving `.ssh` never wires it. Driving a real `.ssh`
// launch through a real, appeared `ConsoleController` would attempt a real
// `ssh` subprocess - genuinely unsafe in a headless suite - so that half is
// deliberately left to the source guard rather than a second, riskier
// behavioural harness here.
//
// Run with:
//   swift build && FM_RUN_TAB_FORWARD_DRAGS_TOGGLE_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only - see ConsoleClaudeUsageSelfTest.swift's
// header for the full reasoning. Do not remove this guard: `Phase3PolishSelfTest`
// asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum TabForwardDragsToggleSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("freshShellTabStartsWithTheToggleOff", test_freshTabStartsOff),
            ("toggleFlipsAndTheChipClosureReflectsIt", test_toggleFlipsAndClosureReflectsIt),
            ("toggleActionClosureActuallyToggles", test_onToggleForwardDragsClosureToggles),
            ("duplicateCarriesAnAlreadyToggledStateForward", test_duplicatePropagatesToggle),
            ("aFreshTabNeverInheritsAnUnrelatedTabsToggle", test_freshTabDoesNotInheritSiblingState),
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
            ? "TabForwardDragsToggleSelfTest: all \(cases.count) cases passed"
            : "TabForwardDragsToggleSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// Mirrors `ConsoleClaudeUsageSelfTest.makeTestConsole` - a real
    /// `ConsoleController` mounted in a real, off-screen `NSWindow`.
    private static func makeTestConsole() -> (window: NSWindow, controller: ConsoleController) {
        let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(), isFirstmateConsole: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    // MARK: Cases

    private static func test_freshTabStartsOff() -> String? {
        let (window, controller) = makeTestConsole()
        controller.newShellTab()
        guard let tab = controller.currentTab else { return "no current tab after newShellTab()" }
        guard tab.terminal.forwardDragsToChild == false else {
            return "a fresh .shell tab's forwardDragsToChild was already true"
        }
        guard let chip = tab.chip, let enabled = chip.forwardDragsEnabled else {
            return "the .shell tab's chip never wired forwardDragsEnabled"
        }
        guard enabled() == false else {
            return "the chip's forwardDragsEnabled() closure reported true for a fresh tab"
        }
        guard chip.onToggleForwardDrags != nil else {
            return "the .shell tab's chip never wired onToggleForwardDrags"
        }
        _ = window
        return nil
    }

    private static func test_toggleFlipsAndClosureReflectsIt() -> String? {
        let (window, controller) = makeTestConsole()
        controller.newShellTab()
        guard let tab = controller.currentTab else { return "no current tab after newShellTab()" }
        guard let enabled = tab.chip.forwardDragsEnabled else { return "forwardDragsEnabled never wired" }

        controller.toggleForwardDragsToChild(id: tab.id)
        guard tab.terminal.forwardDragsToChild == true else {
            return "toggleForwardDragsToChild(id:) did not flip forwardDragsToChild to true"
        }
        guard enabled() == true else {
            return "the chip's forwardDragsEnabled() closure still reads false after toggling on - the menu checkmark would be stale"
        }

        controller.toggleForwardDragsToChild(id: tab.id)
        guard tab.terminal.forwardDragsToChild == false else {
            return "a second toggleForwardDragsToChild(id:) call did not flip it back off"
        }
        guard enabled() == false else {
            return "the chip's forwardDragsEnabled() closure still reads true after toggling back off"
        }
        _ = window
        return nil
    }

    /// The right-click menu item's actual `@objc` action goes through
    /// `chip.onToggleForwardDrags`, not `toggleForwardDragsToChild(id:)`
    /// directly - proving the closure itself (what `TabChipView.rightMouseDown`
    /// actually wires to the menu item) performs the real toggle, not just
    /// that the controller method works when called by id.
    private static func test_onToggleForwardDragsClosureToggles() -> String? {
        let (window, controller) = makeTestConsole()
        controller.newShellTab()
        guard let tab = controller.currentTab else { return "no current tab after newShellTab()" }
        guard let onToggle = tab.chip.onToggleForwardDrags else { return "onToggleForwardDrags never wired" }

        onToggle()
        guard tab.terminal.forwardDragsToChild == true else {
            return "calling the chip's onToggleForwardDrags closure did not flip forwardDragsToChild"
        }
        _ = window
        return nil
    }

    private static func test_duplicatePropagatesToggle() -> String? {
        let (window, controller) = makeTestConsole()
        controller.newShellTab()
        guard let src = controller.currentTab else { return "no current tab after newShellTab()" }
        controller.toggleForwardDragsToChild(id: src.id)
        guard src.terminal.forwardDragsToChild == true else { return "setup: toggle did not take" }

        controller.duplicateTab(id: src.id)
        guard let dup = controller.currentTab, dup.id != src.id else {
            return "duplicateTab did not select a new, distinct tab"
        }
        guard dup.terminal.forwardDragsToChild == true else {
            return "a duplicate of an already-toggled tab did not carry forwardDragsToChild forward - it started false"
        }
        guard let dupEnabled = dup.chip.forwardDragsEnabled, dupEnabled() == true else {
            return "the duplicate's own chip closure does not reflect the carried-forward toggle"
        }
        _ = window
        return nil
    }

    /// The inverse of the case above: a *fresh* tab (⌘T, not a duplicate) must
    /// never pick up a sibling tab's own toggle state - each `.shell` tab's
    /// choice is independent unless the captain explicitly duplicates it.
    private static func test_freshTabDoesNotInheritSiblingState() -> String? {
        let (window, controller) = makeTestConsole()
        controller.newShellTab()
        guard let first = controller.currentTab else { return "no current tab after first newShellTab()" }
        controller.toggleForwardDragsToChild(id: first.id)
        guard first.terminal.forwardDragsToChild == true else { return "setup: toggle did not take" }

        controller.newShellTab()
        guard let second = controller.currentTab, second.id != first.id else {
            return "the second newShellTab() did not open a new, distinct tab"
        }
        guard second.terminal.forwardDragsToChild == false else {
            return "a brand-new .shell tab inherited an unrelated tab's forwardDragsToChild state - each tab's toggle must start independent"
        }
        _ = window
        return nil
    }
}

#endif
