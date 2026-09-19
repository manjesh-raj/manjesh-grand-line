// Manjesh Grand Line - native macOS app.
//
// `KeyboardShortcutCatalog` - what the Help menu's "Keyboard Shortcuts…"
// sheet prints.
//
// Review #3's UX3 asked for "a generated sheet from the same tables the
// Settings recorder reads", and UX4 for "surface every binding" in it. The
// implementation here is one step stronger than a shared table: it **walks
// `NSApp.mainMenu` itself**. A hand-maintained second table beside
// `buildMenu()` is a table that drifts - this repo has shipped exactly that
// failure before (`UnifiedSearchActionProvider`'s own header explains why its
// verbs dispatch through the real menu actions rather than re-implementing
// them) - whereas a walk of the live menu tree is, by construction, what the
// menu bar actually does. Add a menu item with a key equivalent and it appears
// in the sheet with no second edit; remove one and it leaves.
//
// The two binding families that are genuinely *not* in the menu bar are
// appended from their own stores, because they are configurable and the menu
// has no item for them:
//
//   - the terminal shortcuts (`AppSettings.terminalShortcuts`), which are
//     Settings > Terminal's recorder rows, and
//   - the dictation hotkey (`AppSettings.dictationShortcut`).
//
// Both are read through `AppSettings`, which is what UX3's "the same tables
// the Settings recorder reads" actually names.
//
// Pure logic against an `NSMenu` you hand it, so the suite builds a menu tree
// by hand and asserts the grouping without a window - see
// `KeyboardShortcutCatalogSelfTest`. `NSMenu` needs AppKit but no window
// server (AGENTS.md's "the test is what the suite asserts, never what it
// imports").

import AppKit

/// One printable binding: what it does, and the chord that does it.
///
/// `keys` is the chord broken into individual keycaps, because `HelmKeyHint`
/// - the app's one chord pill - draws a cap per glyph rather than one string.
/// `chord` is the same thing joined, which is what a self-test asserts against
/// and what a plain-text rendering would use.
struct KeyboardShortcutEntry: Equatable {
    let title: String
    let keys: [String]

    var chord: String { keys.joined() }
}

/// One printable section of the sheet - a top-level menu, or one of the two
/// appended non-menu families.
struct KeyboardShortcutSection: Equatable {
    let title: String
    let entries: [KeyboardShortcutEntry]
}

enum KeyboardShortcutCatalog {
    /// Render a key equivalent plus its modifier mask the way the menu bar
    /// draws it.
    ///
    /// Modifier order is Apple's own and is not negotiable: control, option,
    /// shift, command, left to right. Getting it wrong reads as a typo to
    /// anyone who has used a Mac.
    ///
    /// A shifted *letter* is a real case this app has: "Hide Others" is
    /// declared as `"h"` + `[.command, .option]`, but `New SSH Key…` is `"n"`
    /// + `[.command, .shift]`. AppKit stores the base character and the mask
    /// separately in both cases, so the letter is upper-cased for display
    /// rather than the ⇧ being inferred from the character.
    ///
    /// The three keys whose literal character is unprintable get their glyph:
    /// space, tab and return. A space key equivalent is not hypothetical here
    /// - quick capture's in-app fallback is ⌥Space.
    static func keycaps(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) -> [String] {
        guard !keyEquivalent.isEmpty else { return [] }
        let glyph: String
        switch keyEquivalent {
        case " ": glyph = "Space"
        case "\t": glyph = "\u{21E5}"
        case "\r", "\n": glyph = HelmKeyHint.returnKey
        case "\u{1b}": glyph = HelmKeyHint.escape
        default: glyph = keyEquivalent.uppercased()
        }
        return HelmKeyHint.keys(for: modifiers, key: glyph)
    }

    /// Walk a menu tree and collect every item that carries a key equivalent,
    /// grouped by its top-level menu.
    ///
    /// Submenus are walked too (this app has none carrying shortcuts today,
    /// but the Go menu's grouping makes that a matter of time) and their
    /// entries fold into the top-level section rather than making a section of
    /// their own - the sheet is a reference, not a map of the menu tree.
    ///
    /// A section with no shortcuts at all is dropped: printing a heading over
    /// nothing tells the reader the app has a gap where it has a menu.
    static func sections(from mainMenu: NSMenu) -> [KeyboardShortcutSection] {
        mainMenu.items.compactMap { topLevel -> KeyboardShortcutSection? in
            guard let submenu = topLevel.submenu else { return nil }
            let entries = collect(from: submenu)
            guard !entries.isEmpty else { return nil }
            // The app menu's own `NSMenuItem` has an empty title (AppKit
            // substitutes the process name at draw time), so fall back to the
            // submenu's title, which `buildMenu` does set.
            let title = topLevel.title.isEmpty ? submenu.title : topLevel.title
            return KeyboardShortcutSection(
                title: title.isEmpty ? ProcessInfo.processInfo.processName : title,
                entries: entries)
        }
    }

    private static func collect(from menu: NSMenu) -> [KeyboardShortcutEntry] {
        var entries: [KeyboardShortcutEntry] = []
        for item in menu.items {
            if let submenu = item.submenu {
                entries += collect(from: submenu)
                continue
            }
            guard !item.isSeparatorItem, !item.keyEquivalent.isEmpty else { continue }
            entries.append(KeyboardShortcutEntry(
                title: item.title,
                keys: keycaps(keyEquivalent: item.keyEquivalent,
                              modifiers: item.keyEquivalentModifierMask)))
        }
        return entries
    }

    /// The two configurable families the menu bar has no item for.
    ///
    /// Read from the injected `AppSettings` rather than `.shared` so a suite
    /// can assert the section without writing through to the captain's own
    /// preferences - the seam `AppSettings.init(defaults:)` exists for.
    static func configurableSections(settings: AppSettings) -> [KeyboardShortcutSection] {
        var sections: [KeyboardShortcutSection] = []

        let terminal = settings.terminalShortcuts
        let terminalEntries = TerminalShortcutAction.allCases.map { action in
            KeyboardShortcutEntry(title: action.title, keys: [terminal[action].displayString])
        }
        if !terminalEntries.isEmpty {
            sections.append(KeyboardShortcutSection(title: "Terminal", entries: terminalEntries))
        }

        sections.append(KeyboardShortcutSection(
            title: "Dictation",
            entries: [KeyboardShortcutEntry(title: "Start / stop dictation",
                                            keys: [settings.dictationShortcut.displayString])]))
        return sections
    }

    /// Everything the sheet prints, in the order it prints it.
    static func all(mainMenu: NSMenu?, settings: AppSettings) -> [KeyboardShortcutSection] {
        let menuSections = mainMenu.map { sections(from: $0) } ?? []
        return menuSections + configurableSections(settings: settings)
    }
}
