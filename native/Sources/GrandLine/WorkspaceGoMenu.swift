// Grand Line - native macOS app.
//
// R2-UX-02 of the second full review: one taxonomy.
//
// The sidebar layout drew one map of the app in its sidebar (Home, then Work,
// Observe, Workbench and Machine) and a second one everywhere else: Home's
// five space tabs in the toolbar and a Go menu generated from the floating
// bar's spaces (Command, Operations, Stores, Engineering). A captain learned
// two maps of one app. In the sidebar layout the spaces are gone from the
// toolbar, and the Go menu is this: the sidebar's own map, read off
// `ModuleTable` in sidebar order - each group, its modules, and under a module
// of several pages its tabs - so the two can never disagree.
//
// The floating bar keeps the space pills and the spaces' Go menu it has
// always had; it is the layout those spaces belong to.
//
// Two halves, the split the rest of the shell uses: `entries` is the pure
// model `SplitShellModelSelfTest` asserts, and `populate` turns it into menu
// items that reach `WorkspaceShellController` through the responder chain's
// target, like every other Go menu row.

import AppKit

enum WorkspaceGoMenu {

    enum Entry: Equatable {
        /// A disabled caption: one of the sidebar's four groups.
        case group(String)
        /// Home or a module - the row a click on its sidebar item is.
        case module(WorkspaceModule)
        /// One of a module's tabs, indented under it.
        case tab(ModuleTab)
    }

    /// The sidebar's map, top to bottom: Home, then each group with its
    /// modules, and a module's tabs under it where the toolbar draws them.
    static func entries(hidden: Set<WorkspaceModule> = []) -> [Entry] {
        var entries: [Entry] = [.module(.home)]
        for group in WorkspaceGroup.allCases {
            let modules = WorkspaceSidebarModel.modules(in: group, hidden: hidden)
            guard !modules.isEmpty else { continue }
            entries.append(.group(group.title))
            for module in modules {
                entries.append(.module(module))
                entries.append(contentsOf: module.tabs.map(Entry.tab))
            }
        }
        return entries
    }

    /// Append `entries` to `menu`. Separators go before each group, so the
    /// fixed items above them stay their own block.
    static func populate(_ menu: NSMenu, target: AnyObject?, hidden: Set<WorkspaceModule> = []) {
        for item in menu.items.reversed() where item.tag == itemTag { menu.removeItem(item) }
        let start = menu.items.count
        for entry in entries(hidden: hidden) {
            switch entry {
            case .group(let title):
                menu.addItem(.separator())
                // The standard Mac caption for a run of items in one menu.
                let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            case .module(let module):
                let item = NSMenuItem(title: module.title,
                                      action: #selector(WorkspaceShellController.selectModuleFromMenu(_:)),
                                      keyEquivalent: chord(for: module, hidden: hidden).map(String.init) ?? "")
                item.keyEquivalentModifierMask = [.command]
                item.withSymbol(module.symbol)
                item.representedObject = module.rawValue
                item.target = target
                item.indentationLevel = module == .home ? 0 : 1
                menu.addItem(item)
            case .tab(let tab):
                let item = NSMenuItem(title: tab.name,
                                      action: #selector(WorkspaceShellController.selectModuleTabFromMenu(_:)),
                                      keyEquivalent: "")
                item.representedObject = representation(of: tab)
                item.target = target
                item.indentationLevel = 2
                menu.addItem(item)
            }
        }
        // Tagged, so a later call can take exactly these out again when the
        // captain hides or shows a module (R2-UX-01 (b)).
        for item in menu.items[start...] { item.tag = itemTag }
    }

    /// The tag every item `populate` adds carries.
    static let itemTag = 0x474F_4D4E

    /// R2-UX-03: the number chord for `module` - ⌘1 to ⌘9 for the first nine
    /// numbered items the sidebar lists, in its order, so a hidden module
    /// gives its number to the next one down. `nil` past the ninth, and for
    /// an `unnumbered` module.
    ///
    /// On Console, a host page and Tools the same chords pick that page's own
    /// tab instead (`TabKeyboardShortcuts`, which sees the key first): the
    /// captain's choice, option A. The Go menu still shows every chord, and
    /// ⌘K and ⌘⇧[ / ⌘⇧] reach any module from those pages.
    static func chord(for module: WorkspaceModule, hidden: Set<WorkspaceModule> = []) -> Int? {
        let numbered = WorkspaceSidebarModel.listedModules(hidden: hidden).filter { !unnumbered.contains($0) }
        guard let index = numbered.firstIndex(of: module), index < 9 else {
            return nil
        }
        return index + 1
    }

    /// Rows the number chords skip. The Calendar row arrived after the
    /// chords were learned, between Tasks (⌘2) and Crew (⌘3); numbering it
    /// would have moved Crew and every module below it down one, and taken
    /// ⌘9 away from Logs. It already has its own one-click route (the
    /// toolbar's calendar button), so it takes no number and nothing moves.
    static let unnumbered: Set<WorkspaceModule> = [.calendar]

    /// The chord as the captain reads it, for a tooltip or a palette row.
    static func chordText(for module: WorkspaceModule, hidden: Set<WorkspaceModule> = []) -> String? {
        chord(for: module, hidden: hidden).map { "\u{2318}\($0)" }
    }

    /// A tab, as a menu item carries it: its module and its name.
    static func representation(of tab: ModuleTab) -> String { "\(tab.module.rawValue)/\(tab.name)" }

    static func tab(from representation: Any?) -> ModuleTab? {
        guard let raw = representation as? String, let slash = raw.firstIndex(of: "/"),
              let module = WorkspaceModule(rawValue: String(raw[..<slash])) else { return nil }
        let name = String(raw[raw.index(after: slash)...])
        return module.tabs.first { $0.name == name }
    }
}
