// Manjesh Grand Line - native macOS app.
//
// Audit §2 item 7: the Console/Tools tab shortcuts that died with the Tab menu.
//
// `fm/grandline-console-tabs-restore-tabmenu-fix` removed the top-level Tab
// menu outright and said so plainly: ⌘T/⌘D/⌘W/⌘R/⇧⌘R/⌘1-9 are lost, and every
// action stays reachable only from the tab strip's own "+" button, double
// click and right-click menu. That was an accepted trade at the time; a
// captain who lives in Console tabs then has no keyboard tab switching at all,
// which is what the audit re-raised.
//
// ## Why a local `NSEvent` monitor and not a menu
//
// AppKit only fires a key equivalent for an `NSMenuItem` that is actually in
// `NSApp.mainMenu`'s tree - `isHidden` on a top-level item excludes its whole
// submenu from that walk exactly like never adding it does, so there is no
// "in the tree but invisible in the bar" middle ground (see AGENTS.md's "Menu
// bar" section). Re-adding a real Tab menu would put this app back over the
// notched-display menu-bar budget that same section measured: total top-level
// width was ~840pt against a 663pt pre-notch budget when there were 11 menus,
// which is what produced the captain's "large gap before View/Window/Help"
// report. A monitor restores the keystrokes without spending any menu-bar
// width, which is the honest mechanism for this constraint.
//
// ## Scope, and why it is narrow on purpose
//
// A monitor sees *every* key event this app receives, so the matching half is
// deliberately conservative and the gating half is deliberately strict:
//
//   * **Exact modifier match.** `⌘1` is not `⌘⌃1` - the session switcher owns
//     `⌘⌃1`…`⌘⌃9` (`main.swift`'s Hosts menu) and must keep it. Comparing the
//     whole `deviceIndependentFlagsMask` rather than using `.contains` is what
//     keeps the two apart, the same rule `ShiftGlobalHotkey.matches` follows.
//   * **Only the app's own main window.** A popover, sheet or panel has its
//     own window, so the composer, the ⌘K palette, quick capture and every
//     editor sheet are all excluded by construction rather than by listing
//     them.
//   * **Never while text is being edited.** A tab chip's inline-rename field
//     and the SRE Lead composer are real text responders inside the main
//     window; a captain mid-word has a stronger claim on ⌘W than the tab strip
//     does. SwiftTerm's `TerminalView` is a plain `NSView` (verified against
//     the vendored source - `open class TerminalView: NSView`), so this guard
//     costs nothing in the one place these shortcuts matter most.
//   * **Only while a tab-bearing page is showing.** `AppShellController.
//     activeTabShortcutTarget()` answers with the shared Console, a dedicated
//     host page's console, or the Tools page - and `nil` everywhere else, so
//     ⌘R on the Docs page still means whatever Docs means by it.
//
// The matching itself is a pure function (`TabShortcut.from`) so a self-test
// can assert the whole table - including the near-misses it must *not* claim -
// without synthesizing events.

import AppKit

/// What a tab-bearing page can be asked to do from the keyboard.
///
/// Deliberately a plain Swift protocol rather than `@objc`: these are direct
/// calls, not selector dispatch. The names match the methods both controllers
/// already had when the Tab menu existed, so conforming is a declaration
/// rather than a set of shims.
protocol TabShortcutHandling: AnyObject {
    /// ⌘T. Console opens a shell; Tools shows its picker (its own long-
    /// standing behaviour for this action - a "new tool tab" has to be a
    /// choice of which tool).
    func newShellTab()
    /// ⌘D.
    func duplicateCurrentTab()
    /// ⌘W.
    func closeCurrentTab()
    /// ⇧⌘R.
    func renameCurrentTab()
    /// ⌘R. Console restarts the current tab's process. Tools has no
    /// connection to restart, so its implementation is deliberately a no-op
    /// rather than this protocol growing an `isReconnectSupported` flag every
    /// caller would have to check.
    func reconnectCurrentTabIfSupported()
    /// ⌘1…⌘9, 0-based. Out-of-range is ignored by the implementation, so a
    /// ⌘7 with three tabs open does nothing rather than clamping to the last
    /// tab - clamping would make a mistyped shortcut silently switch tabs.
    func selectTab(atIndex index: Int)
}

/// One keystroke's meaning. `Equatable` so a self-test can assert the whole
/// table by value.
enum TabShortcut: Equatable {
    case newTab
    case duplicate
    case close
    case rename
    case reconnect
    /// 0-based, so it can be handed straight to `selectTab(atIndex:)`.
    case select(index: Int)

    /// The only modifier set a plain tab shortcut uses.
    private static let command: NSEvent.ModifierFlags = [.command]
    /// Rename's, and the one reason this table needs to look at more than the
    /// character.
    private static let shiftCommand: NSEvent.ModifierFlags = [.command, .shift]

    /// Decides what (if anything) a keystroke means.
    ///
    /// `characters` is expected to be `charactersIgnoringModifiers`, which per
    /// Apple's own documentation still applies Shift - so `⇧⌘R` arrives as
    /// "R", not "r". Lowercasing before comparing is what lets one table entry
    /// cover both cases, and the modifier set is what tells ⌘R and ⇧⌘R apart.
    static func from(characters: String?, modifiers: NSEvent.ModifierFlags) -> TabShortcut? {
        guard let key = characters?.lowercased(), key.count == 1 else { return nil }
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)

        if mods == shiftCommand {
            // Rename is the only ⇧⌘ shortcut here. Everything else with Shift
            // held is somebody else's - or nobody's - and must fall through.
            return key == "r" ? .rename : nil
        }

        // An exact `[.command]` match, never `.contains(.command)`: ⌘⌃1 is the
        // session switcher's and ⌘⌥1 is nobody's, and both would be stolen by
        // a `contains` test.
        guard mods == command else { return nil }

        switch key {
        case "t": return .newTab
        case "d": return .duplicate
        case "w": return .close
        case "r": return .reconnect
        default:
            guard let digit = Int(key), (1...9).contains(digit) else { return nil }
            return .select(index: digit - 1)
        }
    }

    /// Performs this shortcut against a page. Kept next to the table so the
    /// two cannot drift - a new case has to be handled here to compile.
    func perform(on target: TabShortcutHandling) {
        switch self {
        case .newTab: target.newShellTab()
        case .duplicate: target.duplicateCurrentTab()
        case .close: target.closeCurrentTab()
        case .rename: target.renameCurrentTab()
        case .reconnect: target.reconnectCurrentTabIfSupported()
        case .select(let index): target.selectTab(atIndex: index)
        }
    }
}

/// Installs the local monitor. App-lifetime, owned by `AppDelegate` alongside
/// the other two monitor-backed shortcuts (`ShiftGlobalHotkey`,
/// `DictationHotkey`).
///
/// Local only, deliberately: unlike quick capture and dictation these act on
/// what is on screen *in this app*, so a global monitor would be both useless
/// and a needless Accessibility-permission dependency.
final class TabKeyboardShortcuts {
    private var monitor: Any?

    /// Answers with whichever tab-bearing page is showing, or `nil`. Injected
    /// rather than reading a shell reference directly, so this class knows
    /// nothing about destinations and a self-test can drive the whole
    /// decision path with a stand-in.
    private let target: () -> TabShortcutHandling?

    /// The window these shortcuts belong to. A keystroke in any other window
    /// - a popover, a sheet, the ⌘K palette - is left alone.
    private let mainWindow: () -> NSWindow?

    init(target: @escaping () -> TabShortcutHandling?, mainWindow: @escaping () -> NSWindow?) {
        self.target = target
        self.mainWindow = mainWindow
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// `true` when this keystroke was consumed. Internal (not private) so a
    /// self-test can drive the real decision without an installed monitor -
    /// the monitor closure above is a one-line adapter over exactly this.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard let shortcut = TabShortcut.from(characters: event.charactersIgnoringModifiers,
                                              modifiers: event.modifierFlags) else { return false }
        guard let window = mainWindow(), event.window === window else { return false }
        guard !Self.isEditingText(in: window) else { return false }
        guard let target = target() else { return false }
        shortcut.perform(on: target)
        return true
    }

    /// Is the captain mid-edit in a real text control?
    ///
    /// Both shapes matter and neither covers the other: an `NSTextView` is the
    /// first responder for the SRE Lead composer, while an `NSTextField` lends
    /// its editing to the window's shared *field editor* (itself an
    /// `NSTextView` whose `isFieldEditor` is true) - which is what a tab
    /// chip's inline rename is using. Checking for `NSText` covers both, since
    /// `NSTextView` is an `NSText` subclass.
    static func isEditingText(in window: NSWindow) -> Bool {
        window.firstResponder is NSText
    }
}
