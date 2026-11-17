// Grand Line - native macOS app.
//
// R5-UX-03 of review #5: make the hidden power visible in the first week.
//
// ⌥Space capture, ⌘⇧V clipboard history, `;abbrev` expansion, the dictation
// key, ⌘K, the module digits and the inspector are all invisible until
// found. Two things carry them:
//
//   - `HomeTips`: a "Things you can do" strip on Home for the first seven
//     days, one tip a day, which the captain can dismiss for good.
//   - `PageShortcuts`: what ⌘/ shows - the chords for the page on screen and
//     the handful that work everywhere. The full generated list stays on
//     Help › Keyboard Shortcuts… (⇧⌘/), one click away from it.
//
// Both read the chords the app really has - the recorded capture and
// dictation keys from `AppSettings`, the ⌘-digits from `WorkspaceGoMenu` -
// so a tip never names a key that does something else.

import AppKit

enum HomeTips {

    struct Tip: Equatable {
        let symbol: String
        let title: String
        let body: String
    }

    /// How long the strip shows, counted from the day it first did.
    static let days = 7

    /// The week's tips, one a day, in the order they show. A tip names a key
    /// only through the setting or table that owns it.
    static func all(settings: AppSettings = .shared, layout: WorkspaceLayout = PlaceName.layout) -> [Tip] {
        let capture = settings.quickCaptureShortcut.displayString
        let dictation = settings.dictationShortcut.displayString
        let navigation: Tip = layout == .sidebar
            ? Tip(symbol: "sidebar.left", title: "\u{2318}1 to \u{2318}9 open the sidebar\u{2019}s modules",
                  body: "\u{2318}0 opens the Calendar, and \u{21E7}\u{2318}[ and \u{21E7}\u{2318}] move between a module\u{2019}s tabs.")
            : Tip(symbol: "square.grid.2x2", title: "\u{21E7}\u{2318}D shows every page at once",
                  body: "\u{2318}1 to \u{2318}6 switch between the spaces on the bar.")
        let inspector: Tip = layout == .sidebar
            ? Tip(symbol: "sidebar.right", title: "\u{2325}\u{2318}I opens the inspector",
                  body: "The details of whatever is selected - a host, a credential, a tool - beside the page.")
            : Tip(symbol: "keyboard", title: "\u{2318}/ lists the shortcuts for this page",
                  body: "Help \u{203A} Keyboard Shortcuts\u{2026} has every one the app knows.")
        return [
            Tip(symbol: "magnifyingglass", title: "\u{2318}K finds anything",
                body: "A page, a task, a note, a saved link or a command, from wherever you are."),
            Tip(symbol: "square.and.pencil", title: "\(capture) captures a thought from any app",
                body: "A task, a note, a link or a sticky note, without leaving what you are doing."),
            Tip(symbol: "doc.on.clipboard", title: "\u{21E7}\u{2318}V brings back what you copied",
                body: settings.clipboardHistoryEnabled
                    ? "Your recent clipboard, searchable, kept encrypted on this Mac."
                    : "Turn on clipboard history in \(PlaceName.of(.settings)) first. It stays encrypted on this Mac."),
            Tip(symbol: "text.insert", title: "Type ;abbreviation to expand a snippet",
                body: settings.snippetExpansionEnabled
                    ? "Any snippet's ;abbreviation expands in any app as you type it."
                    : "Turn on snippet expansion in \(PlaceName.of(.settings)), then type a snippet's ;abbreviation in any app."),
            Tip(symbol: "waveform", title: "Hold \(dictation) to dictate",
                body: "Speak, let go, and the text lands where you were typing. It runs on this Mac."),
            navigation,
            inspector,
        ]
    }

    /// The tip for `now`, or `nil` once the week is over or the strip was
    /// dismissed. Day one is the day the strip first showed.
    static func tip(firstShown: Date, now: Date, dismissed: Bool, tips: [Tip],
                    calendar: Calendar = .current) -> Tip? {
        guard !dismissed, !tips.isEmpty else { return nil }
        let day = calendar.dateComponents([.day], from: calendar.startOfDay(for: firstShown),
                                          to: calendar.startOfDay(for: now)).day ?? 0
        guard day >= 0, day < days else { return nil }
        return tips[day % tips.count]
    }
}

/// What ⌘/ shows: the chords for the page on screen, then the ones that
/// work everywhere.
enum PageShortcuts {

    static func sections(module: WorkspaceModule, route: RailDestination?, layout: WorkspaceLayout,
                         settings: AppSettings) -> [KeyboardShortcutSection] {
        var page: [KeyboardShortcutEntry] = []
        if let route, let new = ModuleTable.descriptor(for: route)?.newAction {
            page.append(.init(title: new.menuTitle, keys: ["\u{2318}", "N"]))
        }
        if layout == .sidebar {
            if module == .calendar {
                page.append(.init(title: "Previous or next period", keys: ["\u{21E7}", "\u{2318}", "[", "]"]))
            } else if module.tabs.count > 1 {
                page.append(.init(title: "Previous or next tab", keys: ["\u{21E7}", "\u{2318}", "[", "]"]))
                // S21: the tabs by number, named in order.
                let tabs = module.tabs.prefix(9)
                page.append(.init(title: tabs.map(\.name).joined(separator: " \u{00B7} "),
                                  keys: ["\u{2303}", "1\u{2013}\(tabs.count)"]))
            }
        }
        if module == .console {
            let terminal = settings.terminalShortcuts
            page += TerminalShortcutAction.allCases.map { .init(title: $0.title, keys: [terminal[$0].displayString]) }
        }

        var everywhere: [KeyboardShortcutEntry] = [
            .init(title: "Search anything", keys: ["\u{2318}", "K"]),
            .init(title: "Capture a thought from any app", keys: [settings.quickCaptureShortcut.displayString]),
            .init(title: "Dictate", keys: [settings.dictationShortcut.displayString]),
            .init(title: "Clipboard history", keys: ["\u{21E7}", "\u{2318}", "V"]),
        ]
        if layout == .sidebar {
            everywhere += [
                .init(title: "Open a module", keys: ["\u{2318}", "1\u{2013}9"]),
                .init(title: "Open \(PlaceName.of(.calendar))", keys: ["\u{2318}", "0"]),
                .init(title: "Show or hide the inspector", keys: ["\u{2325}", "\u{2318}", "I"]),
            ]
        } else {
            everywhere += [
                .init(title: "Switch space", keys: ["\u{2318}", "1\u{2013}6"]),
                .init(title: "Every page at once", keys: ["\u{21E7}", "\u{2318}", "D"]),
            ]
        }
        everywhere.append(.init(title: "Every shortcut", keys: ["\u{21E7}", "\u{2318}", "/"]))
        return [
            KeyboardShortcutSection(title: "On \(module.title)", entries: page),
            KeyboardShortcutSection(title: "Everywhere", entries: everywhere),
        ]
    }
}

/// R5-UX-10 of review #5: empty states that teach were there; "second-run"
/// states were not. After the first task, note or link a page was a list,
/// and the hint its empty state gave (⌘V pastes a link, drag a note) was
/// gone. A list page keeps one quiet hint in its header line while it holds
/// only a few items, and drops it once the captain plainly knows the page.
enum QuietHint {
    /// How many items still count as "the first few".
    static let firstFew = 5

    /// `line` with `hint` after it while `count` is one of the first few.
    /// An empty page has its empty state, so it gets no hint here.
    static func line(_ line: String, count: Int, hint: String) -> String {
        (1...firstFew).contains(count) ? "\(line) \u{00B7} \(hint)" : line
    }
}
