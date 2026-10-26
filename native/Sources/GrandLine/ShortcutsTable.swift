// Grand Line - native macOS app.
//
// Settings > Shortcuts' table (T5 and T6 of the Termius-style plan): every
// keyboard shortcut the app has, in one list, and which of them collide.
//
// ## Where the rows come from
//
// Four families, and none of them is a second hand-written table of the menu:
//
//   - **The menu bar**, from `KeyboardShortcutCatalog.menuItems(from:)` - the
//     same live walk the Help menu's sheet prints, so the page and the sheet
//     cannot drift from each other or from what the menu bar does.
//   - **The fixed tab table** (`TabShortcut`): ⌘T, ⌘D, ⌘W, ⌘R, ⇧⌘R and
//     ⌘1-⌘9. These live in a local monitor rather than a menu, so the walk
//     never sees them. Each row is derived by asking `TabShortcut.from` what a
//     chord means, rather than restated.
//   - **The global hotkey** that opens Grand Line from anywhere
//     (`CompactModeHotkey`), which is fixed.
//   - **The configurable families** (choice C3): the nine terminal chords,
//     quick capture and dictation. These are the only rows that can be
//     rebound; everything else says where it is set.
//
// ⌘1-⌘9 is one fixed row, as the plan asks. The sidebar layout's Go menu
// gives each of the first nine modules its own ⌘-digit item, and on Console, a
// host page and Tools the same chords pick that page's tab (R2-UX-03, the
// captain's option A). Nine menu rows plus a tab-table row would print one
// idea ten times, so the menu's digit items fold into the fixed row.
//
// ## Chords, physically
//
// A menu item stores a *character* and a modifier mask; a recorded chord is a
// keycode and a mask. Comparing them needs one shape, so every row carries the
// physical `KeyChord`s it binds. A shifted character in a key equivalent
// carries its Shift implicitly (`"{"` is ⇧[, `"N"` is ⇧N), which is why the Go
// menu's Next Tab (`"}"` + ⌘) and the terminal's own next tab (⇧⌘]) are the
// same keys.
//
// That pair, and Previous Tab beside it, are a collision this app makes on
// purpose: R2-UX-03 gave the Go menu the system's own tab chords, and on a
// page with its own tabs `TabKeyboardShortcuts` sees the key first and moves
// that page's tabs instead. The Tasks menu's Capture item is the other: it is
// quick capture's own no-Accessibility fallback, re-keyed to whatever chord
// the captain records (`AppDelegate.applyQuickCaptureMenuChord`), so it always
// shares that chord by design. All three are listed in `intendedOverlaps`
// rather than being reported as conflicts, so the Conflicts filter only ever
// shows something a captain created.
//
// Modifier masks always go through `KeyChord.relevantModifierMask`
// (gotcha (21)): Caps Lock or Fn riding along must never make two chords
// different.

import AppKit

/// One binding the captain can change - choice C3's three families.
enum ConfigurableShortcut: Hashable {
    case terminal(TerminalShortcutAction)
    case quickCapture
    case dictation

    static var all: [ConfigurableShortcut] {
        TerminalShortcutAction.allCases.map { .terminal($0) } + [.quickCapture, .dictation]
    }

    var id: String {
        switch self {
        case .terminal(let action): return "terminal.\(action.rawValue)"
        case .quickCapture: return "quickCapture"
        case .dictation: return "dictation"
        }
    }

    var title: String {
        switch self {
        case .terminal(let action): return action.title
        case .quickCapture: return "Open the capture panel"
        case .dictation: return "Start / stop dictation"
        }
    }

    /// The section heading the row sits under.
    var section: String {
        switch self {
        case .terminal: return "Terminal"
        case .quickCapture: return "Capture"
        case .dictation: return "Dictation"
        }
    }

    /// Where the binding works, said under an unchanged row.
    var whereItWorks: String {
        switch self {
        case .terminal: return "Console, host pages and Tools"
        case .quickCapture: return "From any app, once Accessibility is granted"
        case .dictation: return "Hold to record, from any app"
        }
    }

    var defaultChord: KeyChord {
        switch self {
        case .terminal(let action): return action.defaultChord
        case .quickCapture: return .quickCaptureDefault
        case .dictation: return .dictationDefault
        }
    }

    /// What its recorder accepts. Dictation's trigger is *held*, so a lone
    /// modifier is its default; every other one is a command and needs a
    /// real key plus a modifier (`KeyChordRecorderView.Mode`).
    var recorderMode: KeyChordRecorderView.Mode {
        self == .dictation ? .any : .command
    }

    func current(in settings: AppSettings) -> KeyChord {
        switch self {
        case .terminal(let action): return settings.terminalShortcuts[action]
        case .quickCapture: return settings.quickCaptureShortcut
        case .dictation: return settings.dictationShortcut
        }
    }

    func store(_ chord: KeyChord, in settings: AppSettings) {
        switch self {
        case .terminal(let action):
            var set = settings.terminalShortcuts
            set[action] = chord
            settings.terminalShortcuts = set
        case .quickCapture:
            settings.quickCaptureShortcut = chord
        case .dictation:
            settings.dictationShortcut = chord
        }
    }
}

/// One row of Settings > Shortcuts.
struct ShortcutRow: Equatable {
    enum Kind: Equatable {
        /// Set by a main-menu item. Read-only (C3).
        case menu
        /// One of this app's fixed tables. Read-only.
        case fixed
        case configurable(ConfigurableShortcut)
    }

    let id: String
    let title: String
    let section: String
    /// The keycaps to draw, one per glyph (`HelmKeyHint`).
    let keys: [String]
    /// The physical chords this row binds - one for most rows, nine for
    /// ⌘1-⌘9, and none for a menu character no keycode table covers.
    let chords: [KeyChord]
    let kind: Kind
    /// A menu row's action, so an intended overlap can be recognised by what
    /// the item does rather than by its title.
    let menuAction: Selector?
    /// Where the binding is set, said under the title.
    let source: String
    /// Whether a configurable binding is off its default.
    let isChanged: Bool
    /// "Section › Title" of every row this one collides with.
    var conflicts: [String] = []

    var label: String { "\(section) \u{203A} \(title)" }
    var isConfigurable: Bool { if case .configurable = kind { return true } else { return false } }
    var configurable: ConfigurableShortcut? { if case .configurable(let shortcut) = kind { return shortcut } else { return nil } }
}

enum ShortcutsTable {

    /// What the page's filter tabs choose between.
    enum Filter: String, CaseIterable {
        case all, changed, conflicts

        var title: String {
            switch self {
            case .all: return "All"
            case .changed: return "Changed"
            case .conflicts: return "Conflicts"
            }
        }
    }

    /// The deliberate collisions - see the header. Keyed by the configurable
    /// binding and the menu action it shares keys with.
    static let intendedOverlaps: [(ConfigurableShortcut, Selector)] = [
        (.terminal(.nextTab), #selector(WorkspaceShellController.selectNextModuleTab(_:))),
        (.terminal(.previousTab), #selector(WorkspaceShellController.selectPreviousModuleTab(_:))),
        (.quickCapture, #selector(AppDelegate.showShiftQuickCapture)),
    ]

    // MARK: Building the table

    /// Every row, in page order: the configurable families first (the rows a
    /// captain comes here to change), then the fixed ones, then the menu bar
    /// in its own order. Conflicts are filled in.
    static func rows(mainMenu: NSMenu?, settings: AppSettings) -> [ShortcutRow] {
        var rows = configurableRows(settings: settings) + fixedRows()
        if let mainMenu { rows += menuRows(from: mainMenu) }
        return markingConflicts(rows)
    }

    static func configurableRows(settings: AppSettings) -> [ShortcutRow] {
        ConfigurableShortcut.all.map { shortcut in
            let chord = shortcut.current(in: settings)
            let changed = chord != shortcut.defaultChord
            let source = changed
                ? "Changed \u{00B7} the default is \(shortcut.defaultChord.displayString)"
                : shortcut.whereItWorks
            return ShortcutRow(id: "configurable.\(shortcut.id)", title: shortcut.title, section: shortcut.section,
                               keys: [chord.displayString], chords: [chord], kind: .configurable(shortcut),
                               menuAction: nil, source: source, isChanged: changed)
        }
    }

    /// The fixed tab table, asked of `TabShortcut.from` so a row cannot claim
    /// a chord the monitor does not answer to, plus ⌘1-⌘9 and the global
    /// hotkey.
    static func fixedRows() -> [ShortcutRow] {
        let section = "Tabs and pages"
        let candidates: [(String, NSEvent.ModifierFlags)] = [
            ("t", [.command]), ("d", [.command]), ("w", [.command]), ("r", [.command]), ("r", [.command, .shift]),
        ]
        var rows: [ShortcutRow] = []
        for (character, modifiers) in candidates {
            guard let meaning = TabShortcut.from(characters: character, modifiers: modifiers),
                  let chord = chord(keyEquivalent: character, modifiers: modifiers) else { continue }
            rows.append(ShortcutRow(id: "fixed.\(meaning)", title: title(of: meaning), section: section,
                                    keys: KeyboardShortcutCatalog.keycaps(keyEquivalent: character, modifiers: modifiers),
                                    chords: [chord], kind: .fixed, menuAction: nil,
                                    source: "Fixed \u{00B7} Console, host pages and Tools", isChanged: false))
        }
        let digits = (1...9).compactMap { chord(keyEquivalent: "\($0)", modifiers: [.command]) }
        rows.append(ShortcutRow(id: "fixed.modules", title: "Open a sidebar module, or this page's tab",
                                section: section, keys: [HelmKeyHint.command, "1\u{2013}9"], chords: digits,
                                kind: .fixed, menuAction: nil,
                                source: "Fixed \u{00B7} the first nine sidebar modules; on Console, host pages and Tools, that page's tabs",
                                isChanged: false))
        rows.append(ShortcutRow(id: "fixed.openFromAnywhere", title: "Open Grand Line from anywhere",
                                section: "Global",
                                keys: HelmKeyHint.keys(for: CompactModeHotkey.modifiers, key: "G"),
                                chords: [KeyChord(key: CompactModeHotkey.gKeyCode, CompactModeHotkey.modifiers)],
                                kind: .fixed, menuAction: nil,
                                source: "Fixed \u{00B7} works from any app", isChanged: false))
        return rows
    }

    /// The menu bar, by its own walk. A ⌘-digit item is the fixed row above.
    static func menuRows(from mainMenu: NSMenu) -> [ShortcutRow] {
        var rows: [ShortcutRow] = []
        for section in KeyboardShortcutCatalog.menuItems(from: mainMenu) {
            for item in section.items {
                let modifiers = item.keyEquivalentModifierMask.intersection(KeyChord.relevantModifierMask)
                if modifiers == [.command], let digit = Int(item.keyEquivalent), (1...9).contains(digit) { continue }
                let chords = chord(keyEquivalent: item.keyEquivalent, modifiers: modifiers).map { [$0] } ?? []
                rows.append(ShortcutRow(id: "menu.\(section.title)/\(item.title)", title: item.title,
                                        section: section.title,
                                        keys: KeyboardShortcutCatalog.keycaps(keyEquivalent: item.keyEquivalent,
                                                                              modifiers: modifiers),
                                        chords: chords, kind: .menu, menuAction: item.action,
                                        source: "Set by the menu", isChanged: false))
            }
        }
        return rows
    }

    private static func title(of shortcut: TabShortcut) -> String {
        switch shortcut {
        case .newTab: return "New tab"
        case .duplicate: return "Duplicate tab"
        case .close: return "Close tab"
        case .rename: return "Rename tab"
        case .reconnect: return "Reconnect tab"
        case .select: return "Select tab"
        }
    }

    // MARK: Chords

    /// The physical chord a menu key equivalent stands for, or `nil` when no
    /// keycode table here covers the character.
    static func chord(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) -> KeyChord? {
        var mods = modifiers.intersection(KeyChord.relevantModifierMask)
        var key = keyEquivalent
        if let base = shiftedSymbols[key] {
            key = base
            mods.insert(.shift)
        } else if key.count == 1, key.lowercased() != key {
            key = key.lowercased()
            mods.insert(.shift)
        }
        guard let code = keyCodeByMenuCharacter[key] else { return nil }
        return KeyChord(key: code, mods)
    }

    /// A US-layout shifted symbol and the key it is on.
    private static let shiftedSymbols: [String: String] = [
        "{": "[", "}": "]", "?": "/", "+": "=", "_": "-", ":": ";",
        "\"": "'", "<": ",", ">": ".", "|": "\\", "~": "`",
    ]

    /// The inverse of `KeyChord.menuKeyEquivalent(for:)`, so a menu character
    /// and a recorded keycode meet in one table.
    private static let keyCodeByMenuCharacter: [String: UInt16] = {
        var table: [String: UInt16] = [:]
        for code in UInt16(0)..<UInt16(128) {
            guard let character = KeyChord.menuKeyEquivalent(for: code), table[character] == nil else { continue }
            table[character] = code
        }
        return table
    }()

    /// Whether two chords are the same keys - the same keycode, the same
    /// shape and the same four relevant modifiers, whatever else rode along.
    static func sameKeys(_ a: KeyChord, _ b: KeyChord) -> Bool {
        a.keyCode == b.keyCode && a.isModifierOnly == b.isModifierOnly
            && a.modifiers.intersection(KeyChord.relevantModifierMask)
                == b.modifiers.intersection(KeyChord.relevantModifierMask)
    }

    // MARK: Conflicts

    /// Every row whose keys `chord` would also press, for `shortcut`'s
    /// recorder. The row's own binding is not a conflict with itself, and an
    /// intended overlap is not one at all.
    static func owners(of chord: KeyChord, for shortcut: ConfigurableShortcut, in rows: [ShortcutRow]) -> [ShortcutRow] {
        rows.filter { row in
            guard row.configurable != shortcut else { return false }
            guard row.chords.contains(where: { sameKeys($0, chord) }) else { return false }
            return !isIntendedOverlap(shortcut, row)
        }
    }

    static func isIntendedOverlap(_ shortcut: ConfigurableShortcut, _ row: ShortcutRow) -> Bool {
        guard let action = row.menuAction else { return false }
        return intendedOverlaps.contains { $0.0 == shortcut && $0.1 == action }
    }

    /// Fill in `conflicts` on both sides of every collision a configurable
    /// binding is part of. Two read-only rows sharing keys are this app's own
    /// design (the tab table's ⌘R and the File menu's Run Snippet are
    /// dispatched by different pages), not something the captain can act on,
    /// so they are not reported.
    static func markingConflicts(_ rows: [ShortcutRow]) -> [ShortcutRow] {
        var marked = rows
        for (index, row) in rows.enumerated() {
            guard let shortcut = row.configurable else { continue }
            for chord in row.chords {
                for other in owners(of: chord, for: shortcut, in: rows) {
                    guard let otherIndex = rows.firstIndex(where: { $0.id == other.id }) else { continue }
                    if !marked[index].conflicts.contains(other.label) { marked[index].conflicts.append(other.label) }
                    if !marked[otherIndex].conflicts.contains(row.label) { marked[otherIndex].conflicts.append(row.label) }
                }
            }
        }
        return marked
    }

    // MARK: Filtering

    /// The rows the page shows for a filter and a search. The search matches
    /// the title, the section, where it is set and the chord as drawn, so
    /// "split", "Hosts" and "⌃⌘" all find something.
    static func visible(_ rows: [ShortcutRow], filter: Filter, search: String) -> [ShortcutRow] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            switch filter {
            case .all: break
            case .changed: guard row.isChanged else { return false }
            case .conflicts: guard !row.conflicts.isEmpty else { return false }
            }
            guard !needle.isEmpty else { return true }
            let haystack = [row.title, row.section, row.source, row.keys.joined()].joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
    }
}
