// Manjesh Grand Line - native macOS app.
//
// The Console's configurable keyboard shortcuts: move between tabs, and split
// a tab's terminal into panes (`fm/grand-line-terminal-shortcuts-settings`).
//
// ## What was already there, verified rather than assumed
//
// `TabKeyboardShortcuts` has owned a fixed table since audit §2 item 7 -
// ⌘T/⌘D/⌘W/⌘R/⇧⌘R and a real, wired ⌘1…⌘9 index jump (`TabShortcut.select`
// -> `TabShortcutHandling.selectTab(atIndex:)`). What it never had is a
// *relative* move: switching to the tab beside the current one had no
// keystroke at all, only a chip click. That is the gap this closes, and it is
// why "next tab" is wired straight through the same `selectTab(atIndex:)`
// every other selection path already funnels into rather than reaching for
// `select(tabID:)` itself.
//
// ## Why these live beside that fixed table rather than replacing it
//
// The fixed table is a *mapping*; this is a *setting*. Both are matched by
// the same single local `NSEvent` monitor, which is the whole point - that
// monitor already carries four gates worth having and none of them is worth
// writing twice (main window only, never while a text responder is editing,
// never while the app is locked, and only while a tab-bearing page is
// showing). See `TabKeyboardShortcuts.swift`'s header for why a monitor and
// not a menu.
//
// The two are matched differently on purpose, and the difference is not
// stylistic. The fixed table matches on `charactersIgnoringModifiers`, which
// is what makes ⌘1 mean "the first tab" on any keyboard layout. A configured
// chord matches on **keyCode**, because a `KeyChord` is what the recorder
// captured - the captain pressed a physical key and the row shows what they
// pressed. Dictation's own configurable hotkey matches by keyCode for exactly
// this reason.
//
// ## Defaults, and the collision check behind them
//
// Every default below was checked against `main.swift`'s complete menu tree
// and against this app's other two `NSEvent` monitors before being picked.
// What is already taken:
//
//   ⌘        , h q x c v a f k, ] [ (session next/previous), t d w r 1-9
//   ⌘⇧       f l c t i a n k r
//   ⌘⌥       h n p
//   ⌘⌃       n s 1-9 (the session switcher)
//   ⌥        Space (quick capture)
//
// So:
//
//   Next tab           ⌘⇧]     Safari, Chrome and Terminal.app all use this
//   Previous tab       ⌘⇧[     pair for exactly this. One modifier away from
//                              this app's own ⌘]/⌘[, which switch *sessions*
//                              (a different host) rather than tabs within
//                              one - deliberately adjacent, since they are
//                              the same gesture at two scales.
//   Split right        ⌃⌘→     The direction is the key. ⌃⌘ is the emptiest
//   Split left         ⌃⌘←     modifier pair this app uses, and macOS itself
//   Split down         ⌃⌘↓     assigns none of these three.
//   Focus next pane    ⌥⌘]     Reads as "next", one modifier from the tab
//   Focus prev. pane   ⌥⌘[     pair above, which is the same idea one level in.
//   Close pane         ⌃⌘W     ⌘W closes the whole tab; this closes one pane.
//   Zoom pane          ⌃⌘⏎     Temporarily fill the tab with the focused pane.
//
// A captain can record anything over any of them. Nothing here validates a
// new chord against the fixed table or the menus - a shortcut recorder that
// silently refused half the keyboard would be worse than one that lets the
// captain decide, and the monitor's own ordering makes the consequence
// bounded and predictable: see `TabKeyboardShortcuts.handle`.

import AppKit

/// One configurable Console action.
///
/// `String`-backed and `CaseIterable`: the raw value is the persisted key in
/// `AppSettings.terminalShortcuts`, so renaming a case orphans that captain's
/// binding back to its default rather than crashing - and `allCases` is what
/// drives both the Settings rows and the defaults table, so a case added
/// without a default fails to compile rather than shipping unbound.
enum TerminalShortcutAction: String, CaseIterable {
    case nextTab
    case previousTab
    case splitRight
    case splitLeft
    case splitDown
    case focusNextPane
    case focusPreviousPane
    case closePane
    case zoomPane

    /// The Settings row's title.
    var title: String {
        switch self {
        case .nextTab: return "Next tab"
        case .previousTab: return "Previous tab"
        case .splitRight: return "Split right"
        case .splitLeft: return "Split left"
        case .splitDown: return "Split down"
        case .focusNextPane: return "Focus next pane"
        case .focusPreviousPane: return "Focus previous pane"
        case .closePane: return "Close pane"
        case .zoomPane: return "Zoom pane"
        }
    }

    /// The Settings row's description. Says what the action does *and*, where
    /// it matters, what it deliberately does not - a captain reading "Close
    /// pane" next to a ⌘W they already know should not have to find out by
    /// experiment which one closes the tab.
    var detail: String {
        switch self {
        case .nextTab:
            return "Move to the next tab in this page's strip, wrapping at the end."
        case .previousTab:
            return "Move to the previous tab, wrapping at the start."
        case .splitRight:
            return "Open a second terminal beside this one, to its right. It runs the same thing this tab runs."
        case .splitLeft:
            return "The same, placed to the left of the current pane."
        case .splitDown:
            return "The same, placed below the current pane."
        case .focusNextPane:
            return "Move the keyboard to the next split pane, wrapping at the last."
        case .focusPreviousPane:
            return "Move the keyboard to the previous split pane."
        case .closePane:
            return "End the focused pane's process and give its space back. Does nothing when the tab has only one pane - \u{2318}W closes the tab itself."
        case .zoomPane:
            return "Fill the tab with the focused pane, hiding the others. Press again to bring them back."
        }
    }

    /// Grouping for the Settings card, so the nine rows read as three ideas
    /// rather than one list.
    var group: Group {
        switch self {
        case .nextTab, .previousTab: return .tabs
        case .splitRight, .splitLeft, .splitDown: return .splitting
        case .focusNextPane, .focusPreviousPane, .closePane, .zoomPane: return .panes
        }
    }

    enum Group: String, CaseIterable {
        case tabs, splitting, panes

        var title: String {
            switch self {
            case .tabs: return "Tabs"
            case .splitting: return "Split the terminal"
            case .panes: return "Split panes"
            }
        }
    }

    /// The shipped binding. See the header for the collision check.
    var defaultChord: KeyChord {
        switch self {
        case .nextTab: return KeyChord(key: 30, [.command, .shift])            // ⌘⇧]
        case .previousTab: return KeyChord(key: 33, [.command, .shift])        // ⌘⇧[
        case .splitRight: return KeyChord(key: 124, [.command, .control])      // ⌃⌘→
        case .splitLeft: return KeyChord(key: 123, [.command, .control])       // ⌃⌘←
        case .splitDown: return KeyChord(key: 125, [.command, .control])       // ⌃⌘↓
        case .focusNextPane: return KeyChord(key: 30, [.command, .option])     // ⌥⌘]
        case .focusPreviousPane: return KeyChord(key: 33, [.command, .option]) // ⌥⌘[
        case .closePane: return KeyChord(key: 13, [.command, .control])        // ⌃⌘W
        case .zoomPane: return KeyChord(key: 36, [.command, .control])         // ⌃⌘⏎
        }
    }
}

extension KeyChord {
    /// A regular-key chord, the only shape a command shortcut may take.
    init(key: UInt16, _ modifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: key, modifierFlagsRaw: modifiers.rawValue, isModifierOnly: false)
    }
}

/// Every action's current binding.
///
/// Stored as one JSON value in `AppSettings.terminalShortcuts` rather than
/// nine flat keys - the same "one cohesive value, always read and written as a
/// unit" reasoning `dictationShortcut` and `sessionRestoreState` already
/// follow. A missing or unreadable entry falls back to that action's own
/// default, so a hand-edited or partially-written preference degrades one
/// binding at a time rather than resetting the lot.
struct TerminalShortcutSet: Codable, Equatable {
    /// Keyed by `TerminalShortcutAction.rawValue`.
    private var chords: [String: KeyChord]

    init(chords: [String: KeyChord] = [:]) {
        self.chords = chords
    }

    static let defaults = TerminalShortcutSet()

    subscript(action: TerminalShortcutAction) -> KeyChord {
        get { chords[action.rawValue] ?? action.defaultChord }
        set { chords[action.rawValue] = newValue }
    }

    /// Whether `action` is currently on something other than its default -
    /// what the Settings card's "Reset to defaults" button is enabled by.
    var hasCustomBindings: Bool {
        TerminalShortcutAction.allCases.contains { self[$0] != $0.defaultChord }
    }

    mutating func reset() { chords.removeAll() }

    /// The action a keystroke means, or `nil`.
    ///
    /// Matching is on keyCode plus an **exact** modifier set, never
    /// `.contains` - the same rule `TabShortcut.from` and
    /// `DictationHotkey.handleKeyEvent` both follow, and the one that keeps
    /// ⌘⇧] (next tab) and a hypothetical ⌘⌥⇧] apart instead of claiming both.
    ///
    /// Ties are resolved by `allCases` order, which is the declaration order
    /// above. Two actions can only collide if the captain deliberately put
    /// them on the same chord, and answering with the first is both stable and
    /// better than answering with whichever the dictionary happened to yield.
    func action(forKeyCode keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> TerminalShortcutAction? {
        let mods = modifiers.intersection(KeyChord.relevantModifierMask)
        return TerminalShortcutAction.allCases.first { action in
            let chord = self[action]
            return !chord.isModifierOnly && chord.keyCode == keyCode && chord.modifiers == mods
        }
    }
}
