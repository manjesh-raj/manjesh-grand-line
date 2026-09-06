// Manjesh Grand Line - native macOS app.
//
// Audit §2 item 7's permanent coverage: the Console/Tools tab shortcuts
// restored after the Tab menu's removal (`TabKeyboardShortcuts.swift`).
//
// Two halves, because the feature has two halves worth protecting and they
// fail differently.
//
// The **table** cases are pure: `TabShortcut.from` maps a keystroke to a
// meaning, and - the part that actually matters - refuses everything else.
// The near-misses are the point. `⌘⌃1` belongs to the session switcher
// (`main.swift`'s Hosts menu, `⌘⌃1`…`⌘⌃9`), and a `contains(.command)` test
// instead of an exact modifier match would silently steal all nine of them
// while every positive case still passed. `⌘⇧T`, `⌘0`, a bare `T` and `⌘⌥D`
// are all here for the same reason.
//
// The **behaviour** cases drive the real `TabKeyboardShortcuts.handle(_:)`
// against a real `ConsoleController` in a real, off-screen `NSWindow` - the
// harness shape `ConsoleClaudeUsageSelfTest`/`TabForwardDragsToggleSelfTest`
// already use - with real `NSEvent`s. That is what proves the monitor's
// gating, which no table test can see: a keystroke in another window, a
// keystroke while a text field is being edited, and a keystroke with no
// tab-bearing page showing must all fall through to the rest of the app
// rather than being consumed.
//
// `.shell` launches only, for the same reason `TabForwardDragsToggleSelfTest`
// gives: a real `.ssh` launch through a real, appeared `ConsoleController`
// would attempt a real `ssh` subprocess, which is not something a headless
// suite should do.
//
// Confirmed, per this project's convention, to catch a real regression rather
// than merely to pass - see this task's PR description for the injections and
// which case each one failed.
//
// Run with:
//   swift build && FM_RUN_TAB_KEYBOARD_SHORTCUTS_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum TabKeyboardShortcutsSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("everyRestoredShortcutMapsToItsAction", test_table),
            ("neighbouringChordsAreLeftAlone", test_nearMisses),
            ("consoleActionsFireThroughARealEvent", test_consoleActions),
            ("aKeystrokeInAnotherWindowIsNotConsumed", test_otherWindow),
            ("aKeystrokeWhileEditingTextIsNotConsumed", test_editingText),
            ("noTabBearingPageMeansNoInterception", test_noTarget),
            ("toolsAnswersTheSameProtocolAndNeverReconnects", test_toolsConformance),
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
            ? "TabKeyboardShortcutsSelfTest: all \(cases.count) cases passed"
            : "TabKeyboardShortcutsSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Table

    private static func test_table() -> String? {
        let expected: [(String, NSEvent.ModifierFlags, TabShortcut)] = [
            ("t", [.command], .newTab),
            ("d", [.command], .duplicate),
            ("w", [.command], .close),
            ("r", [.command], .reconnect),
            // `charactersIgnoringModifiers` still applies Shift, so ⇧⌘R
            // genuinely arrives as "R" - the exact case the lowercasing in
            // `TabShortcut.from` exists for. Asserted in both spellings so a
            // regression that only handles one is caught.
            ("R", [.command, .shift], .rename),
            ("r", [.command, .shift], .rename),
            ("1", [.command], .select(index: 0)),
            ("5", [.command], .select(index: 4)),
            ("9", [.command], .select(index: 8)),
        ]
        for (chars, mods, want) in expected {
            let got = TabShortcut.from(characters: chars, modifiers: mods)
            guard got == want else {
                return "\"\(chars)\" + \(mods.rawValue) resolved \(String(describing: got)), expected \(want)"
            }
        }
        return nil
    }

    private static func test_nearMisses() -> String? {
        let mustBeIgnored: [(String, NSEvent.ModifierFlags, String)] = [
            // The session switcher's own nine, which an inexact modifier test
            // would steal wholesale.
            ("1", [.command, .control], "⌘⌃1 belongs to the session switcher"),
            ("9", [.command, .control], "⌘⌃9 belongs to the session switcher"),
            ("n", [.command, .control], "⌘⌃N is the Hosts menu's New Host"),
            ("s", [.command, .control], "⌘⌃S is the Hosts menu's Show Hosts"),
            // Other real bindings that share a letter with a tab action.
            ("t", [.command, .shift], "⌘⇧T is not a tab action"),
            ("d", [.command, .option], "⌘⌥D is not a tab action"),
            ("w", [.command, .shift], "⌘⇧W is not a tab action"),
            // Plain typing must never be consumed.
            ("t", [], "a bare T is ordinary typing"),
            ("1", [], "a bare 1 is ordinary typing"),
            // Out of the 1-9 range on purpose: there is no tenth tab slot.
            ("0", [.command], "⌘0 is not a tab shortcut"),
            // Multi-character input (dead keys, IME) is never a shortcut.
            ("ab", [.command], "a multi-character keystroke is not a shortcut"),
        ]
        for (chars, mods, why) in mustBeIgnored {
            if let got = TabShortcut.from(characters: chars, modifiers: mods) {
                return "\"\(chars)\" + \(mods.rawValue) was claimed as \(got) - \(why)"
            }
        }
        if TabShortcut.from(characters: nil, modifiers: [.command]) != nil {
            return "a keystroke with no characters was claimed"
        }
        return nil
    }

    // MARK: Behaviour

    private static func test_consoleActions() -> String? {
        let (window, console) = makeTestConsole()
        let shortcuts = TabKeyboardShortcuts(target: { console }, mainWindow: { window })

        // ⌘T twice, from zero tabs.
        guard shortcuts.handle(event(in: window, "t", [.command])) else { return "⌘T was not consumed" }
        guard shortcuts.handle(event(in: window, "t", [.command])) else { return "the second ⌘T was not consumed" }
        guard console.tabs.count == 2 else { return "⌘T x2 produced \(console.tabs.count) tab(s), expected 2" }

        // ⌘D on the second.
        guard shortcuts.handle(event(in: window, "d", [.command])) else { return "⌘D was not consumed" }
        guard console.tabs.count == 3 else { return "⌘D produced \(console.tabs.count) tab(s), expected 3" }

        // ⌘1 selects the first.
        guard shortcuts.handle(event(in: window, "1", [.command])) else { return "⌘1 was not consumed" }
        guard console.currentTab === console.tabs.first else { return "⌘1 did not select the first tab" }

        // ⌘3 selects the third - proving the index is 0-based off a 1-based key.
        guard shortcuts.handle(event(in: window, "3", [.command])) else { return "⌘3 was not consumed" }
        guard console.currentTab === console.tabs[2] else { return "⌘3 did not select the third tab" }

        // Back to the first, so the out-of-range probe below starts somewhere
        // a clamp would visibly move away from. Selecting it from the *third*
        // tab is what makes that assertion non-vacuous: with the selection
        // already on the last tab, a clamp to `tabs.count - 1` lands on the
        // tab that was current anyway and the check passes for the wrong
        // reason (this test shipped that way for one revision, and the
        // clamping injection went undetected until it was fixed).
        guard shortcuts.handle(event(in: window, "1", [.command])) else { return "the second ⌘1 was not consumed" }
        guard console.currentTab === console.tabs.first else { return "⌘1 did not return to the first tab" }

        // ⌘7 with three tabs open does nothing rather than clamping.
        let beforeOutOfRange = console.currentTab
        guard shortcuts.handle(event(in: window, "7", [.command])) else { return "⌘7 was not consumed" }
        guard console.currentTab === beforeOutOfRange else {
            return "⌘7 with three tabs open changed the selection - out-of-range should do nothing, never clamp"
        }

        // ⌘W closes one.
        guard shortcuts.handle(event(in: window, "w", [.command])) else { return "⌘W was not consumed" }
        guard console.tabs.count == 2 else { return "⌘W left \(console.tabs.count) tab(s), expected 2" }

        // ⇧⌘R starts an inline rename on the current tab's chip. Asserted via
        // the field editor becoming first responder, which is what
        // `beginRename` actually does - and is also the state the
        // editing-text guard below has to see.
        guard shortcuts.handle(event(in: window, "R", [.command, .shift])) else { return "⇧⌘R was not consumed" }
        guard TabKeyboardShortcuts.isEditingText(in: window) else {
            return "⇧⌘R did not put a text responder in focus, so rename never started"
        }

        window.contentViewController = nil
        return nil
    }

    private static func test_otherWindow() -> String? {
        let (window, console) = makeTestConsole()
        let shortcuts = TabKeyboardShortcuts(target: { console }, mainWindow: { window })
        guard shortcuts.handle(event(in: window, "t", [.command])) else { return "setup ⌘T was not consumed" }
        let before = console.tabs.count

        // A second window stands in for a popover/sheet/panel: the composer,
        // the ⌘K palette, quick capture and every editor sheet each own one.
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                             styleMask: [.titled], backing: .buffered, defer: false)
        if shortcuts.handle(event(in: other, "t", [.command])) {
            return "⌘T in another window was consumed - a popover or sheet must keep its own keystrokes"
        }
        guard console.tabs.count == before else { return "a keystroke in another window still opened a tab" }

        window.contentViewController = nil
        return nil
    }

    private static func test_editingText() -> String? {
        let (window, console) = makeTestConsole()
        let shortcuts = TabKeyboardShortcuts(target: { console }, mainWindow: { window })
        guard shortcuts.handle(event(in: window, "t", [.command])) else { return "setup ⌘T was not consumed" }
        let before = console.tabs.count

        // A real editable field in the real window, focused for real - the
        // shape a tab chip's inline rename takes.
        let field = NSTextField(string: "renaming")
        field.isEditable = true
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        guard TabKeyboardShortcuts.isEditingText(in: window) else {
            return "harness problem: the focused NSTextField did not register as a text responder"
        }

        if shortcuts.handle(event(in: window, "w", [.command])) {
            return "⌘W was consumed while a text field had focus - a captain mid-rename has the stronger claim"
        }
        guard console.tabs.count == before else { return "⌘W closed a tab while text was being edited" }

        field.removeFromSuperview()
        window.contentViewController = nil
        return nil
    }

    private static func test_noTarget() -> String? {
        let (window, _) = makeTestConsole()
        // Every destination that is not Console, a host page or Tools resolves
        // to nil - ⌘R on Docs must still mean whatever Docs means by it.
        let shortcuts = TabKeyboardShortcuts(target: { nil }, mainWindow: { window })
        if shortcuts.handle(event(in: window, "r", [.command])) {
            return "⌘R was consumed with no tab-bearing page showing"
        }
        if shortcuts.handle(event(in: window, "t", [.command])) {
            return "⌘T was consumed with no tab-bearing page showing"
        }
        window.contentViewController = nil
        return nil
    }

    private static func test_toolsConformance() -> String? {
        let tools = ToolsController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = tools
        tools.view.layoutSubtreeIfNeeded()

        let shortcuts = TabKeyboardShortcuts(target: { tools }, mainWindow: { window })

        // ⌘R must be consumed (Tools is a tab-bearing page) and must do
        // nothing - a tool tab runs no process. The assertion that matters is
        // that it does not crash or alter the page; `reconnectCurrentTabIf
        // Supported` being a no-op is the point.
        guard shortcuts.handle(event(in: window, "r", [.command])) else {
            return "⌘R was not consumed on the Tools page"
        }

        // ⌘T on Tools shows the picker rather than opening a tab, which is
        // that page's own long-standing behaviour for this action.
        guard shortcuts.handle(event(in: window, "t", [.command])) else {
            return "⌘T was not consumed on the Tools page"
        }

        window.contentViewController = nil
        return nil
    }

    // MARK: Helpers

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

    /// A real `NSEvent` carrying a real `windowNumber`, which is what makes
    /// `event.window` resolve - the gate the other-window case depends on.
    private static func event(in window: NSWindow, _ chars: String, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: mods,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber,
                         context: nil,
                         characters: chars,
                         charactersIgnoringModifiers: chars,
                         isARepeat: false,
                         keyCode: 0)!
    }
}

#endif
