// Grand Line - native macOS app.
//
// The feature inventory's guard (stage 1 of the modular-shell migration).
//
// `docs/modular-shell/feature-inventory.md` is the committed list of every
// feature the app has, each with the place it lives in the new shell.
// The captain's one hard rule for the migration is that no feature may be
// lost, and a list nobody checks is a list that drifts.
// This suite is the check, in both directions:
//
//   1. **Every feature the code has must have a row.** For each family below
//      the suite enumerates the code side - from the live enums, from the real
//      main menu (`AppDelegate.buildMenu(installing: false)`), from the
//      shortcut catalog, and from source scans where nothing enumerable exists
//      - and fails on any id with no row.
//      So a destination, a shortcut, a menu item, a ⌘K entry, a deep link, a
//      Settings category or row, or a toolbar action cannot be dropped, or
//      added, without the inventory saying so.
//   2. **Every row must point at something real.** A row in a code-backed
//      family whose id the code no longer has fails as stale. A row outside
//      those families carries an Evidence cell (a file and a token) and fails
//      when that token is gone from that file, comments stripped.
//      So deleting the old bar in step 5 cannot quietly take a chrome feature
//      with it: its row keeps failing until it names the new shell's code.
//   3. **Every row must name a real home.** The New shell cell has to start
//      with a module from `WorkspaceModule` or one of the shell places, and a
//      `Module › Child` reference has to name a child that module declares.
//      Destination rows also have to agree with `ModuleTable`.
//
// What it does **not** see, stated rather than implied: page actions wired
// through a closure rather than a selector (a `HoverHighlightView.onClick`, a
// card's tap) have no stable name to enumerate, so they are covered by their
// page's destination and surface rows rather than individually.
//
// Pure logic: the menu is built without installing it, every other family is
// an enum or a source scan, and nothing here mounts a view.
//
// Run with:
//   swift build && FM_RUN_FEATURE_INVENTORY_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum FeatureInventorySelfTest {

    static func run() -> Bool {
        guard let rows = loadInventory() else {
            print("FeatureInventorySelfTest: FAILED - the inventory could not be read")
            return false
        }
        var allOK = true
        let checks: [([InventoryRow], inout Bool) -> Void] = [
            checkRowsAreWellFormed,
            checkCodeBackedFamilies,
            checkEvidenceRows,
            checkNewShellHomes,
            checkDestinationRowsAgreeWithTheModuleTable,
            checkNoRowDropsAFeature,
            checkTheSuiteCanFail,
        ]
        for check in checks {
            var ok = true
            check(rows, &ok)
            allOK = allOK && ok
        }
        print(allOK ? "FeatureInventorySelfTest: all checks passed (\(rows.count) rows)"
                    : "FeatureInventorySelfTest: FAILED")
        return allOK
    }

    // MARK: The inventory file

    struct InventoryRow {
        let id: String
        let feature: String
        let today: String
        let newShell: String
        let evidence: String
        let line: Int
    }

    static var inventoryURL: URL? {
        SelfTestSources.appSourceDirectory()?
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // native
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("docs/modular-shell/feature-inventory.md")
    }

    /// Every table row whose first cell is a backticked id. Header and divider
    /// rows have no backticked first cell, so they are skipped by shape rather
    /// than by position.
    static func loadInventory() -> [InventoryRow]? {
        guard let url = inventoryURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseInventory(text)
    }

    static func parseInventory(_ text: String) -> [InventoryRow] {
        var rows: [InventoryRow] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("| `") else { continue }
            // Markdown escapes a pipe inside a cell as `\|`, so split only on
            // the unescaped ones.
            let placeholder = "\u{1F}"
            var cells = line.replacingOccurrences(of: "\\|", with: placeholder)
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces) }
            // A row opens and closes with a pipe, which leaves an empty cell
            // at each end.
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            guard cells.count >= 4 else {
                rows.append(InventoryRow(id: "", feature: line, today: "", newShell: "", evidence: "", line: index + 1))
                continue
            }
            let id = cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            rows.append(InventoryRow(id: id, feature: cells[1], today: cells[2], newShell: cells[3],
                                     evidence: cells.count > 4 ? cells[4] : "", line: index + 1))
        }
        return rows
    }

    // MARK: 1 - shape

    private static func checkRowsAreWellFormed(_ rows: [InventoryRow], _ ok: inout Bool) {
        var seen: [String: Int] = [:]
        for row in rows {
            guard !row.id.isEmpty else {
                fail("inventory line \(row.line) is not a five-column row: \(row.feature)", &ok)
                continue
            }
            if let first = seen[row.id] {
                fail("inventory id `\(row.id)` appears twice (lines \(first) and \(row.line))", &ok)
            }
            seen[row.id] = row.line
            check(!row.feature.isEmpty, "`\(row.id)` (line \(row.line)) has no Feature text", &ok)
            let family = codeFamilies.first { row.id.hasPrefix($0.prefix) }
            if family == nil {
                check(!row.evidence.isEmpty,
                      "`\(row.id)` (line \(row.line)) is in no code-backed family and has no Evidence cell, "
                        + "so nothing can tell when the feature it names is gone", &ok)
            }
        }
        check(rows.count > 300, "the inventory parsed to only \(rows.count) rows - the parser or the file is broken", &ok)
    }

    // MARK: 2 - code-backed families

    /// One family of ids the code itself can enumerate.
    struct CodeFamily {
        let prefix: String
        let name: String
        /// id -> a short description, used to print a ready-to-fill row.
        let enumerate: () -> [String: String]
    }

    static let codeFamilies: [CodeFamily] = [
        CodeFamily(prefix: "dest.", name: "destination", enumerate: destinationIDs),
        CodeFamily(prefix: "space.", name: "space pill", enumerate: spaceIDs),
        CodeFamily(prefix: "home.", name: "Home canvas card", enumerate: homeCardIDs),
        CodeFamily(prefix: "menu.", name: "main-menu item", enumerate: menuIDs),
        CodeFamily(prefix: "key.", name: "keyboard shortcut", enumerate: shortcutIDs),
        CodeFamily(prefix: "palette.", name: "command palette entry", enumerate: paletteIDs),
        CodeFamily(prefix: "link.", name: "deep link", enumerate: deepLinkIDs),
        CodeFamily(prefix: "settings.", name: "Settings category or row", enumerate: settingsIDs),
        CodeFamily(prefix: "tab.", name: "in-page tab", enumerate: tabIDs),
        CodeFamily(prefix: "nav.", name: "page sidebar row", enumerate: pageSidebarIDs),
        CodeFamily(prefix: "toolbar.", name: "toolbar action", enumerate: toolbarIDs),
        CodeFamily(prefix: "action.", name: "page action", enumerate: pageActionIDs),
        CodeFamily(prefix: "lock.", name: "lock-gated surface", enumerate: lockSurfaceIDs),
        CodeFamily(prefix: "drop.", name: "drag and drop target", enumerate: dropTargetIDs),
        CodeFamily(prefix: "state.", name: "saved-state key", enumerate: savedStateIDs),
    ]

    private static func checkCodeBackedFamilies(_ rows: [InventoryRow], _ ok: inout Bool) {
        let byID = Dictionary(rows.filter { !$0.id.isEmpty }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for family in codeFamilies {
            let code = family.enumerate()
            check(!code.isEmpty, "the \(family.name) family enumerated nothing - its scan is broken, "
                    + "and every row in it would pass vacuously", &ok)
            let listed = Set(byID.keys.filter { $0.hasPrefix(family.prefix) })
            let missing = Set(code.keys).subtracting(listed).sorted()
            for id in missing {
                fail("\(family.name) `\(id)` has no inventory row - add one: "
                     + "| `\(id)` | \(code[id] ?? "") | | | |", &ok)
            }
            let stale = listed.subtracting(code.keys).sorted()
            for id in stale {
                fail("inventory row `\(id)` (line \(byID[id]?.line ?? 0)) names a \(family.name) "
                     + "the code no longer has", &ok)
            }
            // The page-action family carries its selector list in the Today
            // cell, so a selector added to or removed from a file is caught
            // even though the file's row still exists.
            if family.prefix == "action." {
                for (id, expected) in code {
                    guard let row = byID[id] else { continue }
                    let listedSelectors = Set(backticked(in: row.today))
                    let codeSelectors = Set(expected.components(separatedBy: ", ").filter { !$0.isEmpty })
                    for selector in codeSelectors.subtracting(listedSelectors).sorted() {
                        fail("`\(id)` gained the page action `\(selector)` - list it in that row's Today cell", &ok)
                    }
                    for selector in listedSelectors.subtracting(codeSelectors).sorted() {
                        fail("`\(id)` lists the page action `\(selector)`, which that file no longer has", &ok)
                    }
                }
            }
        }
    }

    // MARK: 3 - evidence rows

    private static func checkEvidenceRows(_ rows: [InventoryRow], _ ok: inout Bool) {
        var checked = 0
        for row in rows where !row.evidence.isEmpty {
            let pairs = evidencePairs(row.evidence)
            check(!pairs.isEmpty, "`\(row.id)` (line \(row.line)) has an Evidence cell that names no "
                    + "`File.swift` `token` pair: \(row.evidence)", &ok)
            for (file, token) in pairs {
                guard let url = locate(file) else {
                    fail("`\(row.id)` (line \(row.line)) cites \(file), which does not exist", &ok)
                    continue
                }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    fail("`\(row.id)` cites \(file), which could not be read", &ok)
                    continue
                }
                checked += 1
                check(stripComments(text).contains(token),
                      "`\(row.id)` (line \(row.line)): \(file) no longer contains `\(token)` outside a comment - "
                        + "the feature moved or was removed, so the row has to say where it went", &ok)
            }
        }
        check(checked > 50, "only \(checked) evidence pairs were checked - the Evidence parser is broken", &ok)
    }

    /// `File.swift` `token` pairs, in order. A cell may carry several,
    /// separated by `;`.
    static func evidencePairs(_ cell: String) -> [(String, String)] {
        cell.components(separatedBy: ";").compactMap { part in
            let ticks = backticked(in: part)
            guard ticks.count == 2, ticks[0].contains(".") else { return nil }
            return (ticks[0], ticks[1])
        }
    }

    /// The source trees an Evidence cell may cite: the app, its suites'
    /// sibling scripts, and the widget extension.
    private static func locate(_ file: String) -> URL? {
        guard let app = SelfTestSources.appSourceDirectory() else { return nil }
        let native = app.deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            app.appendingPathComponent(file),
            native.appendingPathComponent("Widgets/GrandLineWidgets").appendingPathComponent(file),
            native.appendingPathComponent("Scripts").appendingPathComponent(file),
            native.appendingPathComponent(file),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: 4 - every row names a real home

    /// The shell places a feature can live in that are not a module of their
    /// own. Kept short on purpose: a new place is a design decision, and
    /// adding it here is where that decision becomes visible.
    static let shellPlaces = [
        "Sidebar", "Toolbar", "Inspector", "Main menu", "Window",
        "Menu bar extra", "System", "Navigator", "Every module",
    ]

    private static func checkNewShellHomes(_ rows: [InventoryRow], _ ok: inout Bool) {
        let modules = Dictionary(uniqueKeysWithValues: WorkspaceModule.allCases.map { ($0.title, $0) })
        // Longest first, so "Sticky Board" is not read as an unknown place
        // that happens to start like something shorter.
        let names = (Array(modules.keys) + shellPlaces).sorted { $0.count > $1.count }
        for row in rows where !row.id.isEmpty {
            let cell = plain(row.newShell)
            guard let name = names.first(where: { cell.hasPrefix($0) }) else {
                fail("`\(row.id)` (line \(row.line)): New shell \"\(row.newShell)\" does not start with a module "
                     + "or a shell place (\(shellPlaces.joined(separator: ", ")))", &ok)
                continue
            }
            guard let module = modules[name], !module.children.isEmpty else { continue }
            let rest = cell.dropFirst(name.count)
            guard rest.hasPrefix(" \u{203A} ") else { continue }
            let child = childName(String(rest.dropFirst(3)), among: module.children)
            check(child != nil, "`\(row.id)` (line \(row.line)): \(name) has no child named in "
                    + "\"\(row.newShell)\" - its children are \(module.children.joined(separator: ", "))", &ok)
        }
    }

    /// The child a `Module › …` reference names: the longest declared child the
    /// text starts with, followed by the end or a delimiter.
    static func childName(_ text: String, among children: [String]) -> String? {
        children.sorted { $0.count > $1.count }.first { child in
            guard text.hasPrefix(child) else { return false }
            let after = text.dropFirst(child.count)
            return after.isEmpty || [",", " ", ";", ")", "."].contains { after.hasPrefix($0) }
        }
    }

    // MARK: 5 - destinations agree with the module table

    private static func checkDestinationRowsAgreeWithTheModuleTable(_ rows: [InventoryRow], _ ok: inout Bool) {
        let byID = Dictionary(rows.filter { !$0.id.isEmpty }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for descriptor in ModuleTable.rows {
            guard let row = byID["dest.\(descriptor.route.rawValue)"] else { continue }
            var expected = descriptor.module.title
            if let child = descriptor.child { expected += " \u{203A} \(child)" }
            check(plain(row.newShell).hasPrefix(expected),
                  "`dest.\(descriptor.route.rawValue)` says it moves to \"\(row.newShell)\" but ModuleTable "
                    + "says \(expected)", &ok)
        }
    }

    // MARK: 6 - nothing is dropped

    /// The captain's rule, as a check on the wording: a New shell cell may say
    /// where a feature goes and what replaces a piece of chrome, but never
    /// that the feature itself is gone.
    private static func checkNoRowDropsAFeature(_ rows: [InventoryRow], _ ok: inout Bool) {
        let banned = ["removed", "dropped", "deleted", "not kept", "gone", "tbd", "todo"]
        for row in rows where !row.id.isEmpty {
            let lower = plain(row.newShell).lowercased()
            for word in banned where lower.hasPrefix(word) || lower.contains("\u{203A} \(word)")
                || lower.contains(" \(word) ") || lower.hasSuffix(" \(word)") {
                fail("`\(row.id)` (line \(row.line)): New shell says \"\(row.newShell)\" - no feature may be lost; "
                     + "name where it lives or what replaces it", &ok)
            }
        }
    }

    // MARK: 7 - the guard's own discriminating power

    /// A drifted parser fails loudly here rather than letting every row pass.
    private static func checkTheSuiteCanFail(_ rows: [InventoryRow], _ ok: inout Bool) {
        let sample = """
        | ID | Feature | Today | New shell | Evidence |
        |---|---|---|---|---|
        | `dest.shift` | Tasks | ⌘K | Tasks | |
        | `chrome.x` | X | Y | Toolbar | `ModuleTable.swift` `enum WorkspaceModule` |
        """
        let parsed = parseInventory(sample)
        check(parsed.count == 2 && parsed[0].id == "dest.shift" && parsed[1].newShell == "Toolbar",
              "the row parser no longer reads a plain five-column row", &ok)
        let pairs = evidencePairs(parsed.last?.evidence ?? "")
        check(pairs.count == 1 && pairs[0].0 == "ModuleTable.swift", "the Evidence parser no longer reads a pair", &ok)
        check(childName("Board, as a column", among: ["Board", "List"]) == "Board"
              && childName("Boardroom", among: ["Board"]) == nil,
              "the child-name matcher accepts a prefix that is not a whole child", &ok)
        check(stripComments("let a = 1 // gone\nlet b = \"http://x\"").contains("http://x")
              && !stripComments("let a = 1 // gone").contains("gone"),
              "the comment stripper either keeps comments or eats string literals", &ok)
        check(Set(menuIDs().keys).contains("menu.File/Run Snippet"),
              "the menu walk no longer finds File > Run Snippet - the menu family is not reading the real menu", &ok)
    }

    // MARK: - The families

    static func destinationIDs() -> [String: String] {
        Dictionary(uniqueKeysWithValues: RailDestination.allCases.map { ("dest.\($0.rawValue)", $0.title) })
    }

    static func spaceIDs() -> [String: String] {
        Dictionary(uniqueKeysWithValues: DaylightSpace.allCases.map { ("space.\($0.rawValue)", $0.title) })
    }

    static func homeCardIDs() -> [String: String] {
        Dictionary(uniqueKeysWithValues: DaylightModule.allCases.map { ("home.\($0.rawValue)", $0.title) })
    }

    /// Every actionable item in the real main menu, keyed by its menu and its
    /// title. Disabled caption rows (the Go menu's group headers) and
    /// separators are structure rather than features.
    static func menuIDs() -> [String: String] {
        guard let menu = cachedMenu else { return [:] }
        var out: [String: String] = [:]
        for (index, top) in menu.items.enumerated() {
            guard let submenu = top.submenu else { continue }
            // `buildMenu` names each submenu and leaves its bar item untitled
            // (an untitled `NSMenuItem` reports "NSMenuItem"), and the app
            // menu's submenu has no title at all - AppKit draws the process
            // name there.
            let topTitle = index == 0 || submenu.title.isEmpty ? "App" : submenu.title
            collectMenuItems(in: submenu, path: "menu.\(topTitle)", into: &out)
        }
        return out
    }

    /// A nested submenu's items are keyed under their parent item, so a menu
    /// that grows a level (the Go menu's grouping makes that a matter of time)
    /// still has every item checked.
    private static func collectMenuItems(in menu: NSMenu, path: String, into out: inout [String: String]) {
        for item in menu.items where !item.isSeparatorItem {
            if item.action == nil && item.submenu == nil && !item.isEnabled { continue }
            let chord = KeyboardShortcutCatalog.keycaps(keyEquivalent: item.keyEquivalent,
                                                        modifiers: item.keyEquivalentModifierMask).joined()
            out["\(path)/\(item.title)"] = chord.isEmpty ? item.title : "\(item.title) \(chord)"
            if let submenu = item.submenu {
                collectMenuItems(in: submenu, path: "\(path)/\(item.title)", into: &out)
            }
        }
    }

    private static let cachedMenu: NSMenu? = AppDelegate().buildMenu(installing: false)

    /// The Help menu's shortcut sheet, which is the app's own catalog: every
    /// menu chord, keyed by the chord, plus the configurable terminal and
    /// dictation bindings, keyed by what they do (their chord is the
    /// captain's to change).
    static func shortcutIDs() -> [String: String] {
        guard let menu = cachedMenu else { return [:] }
        let suite = "fm.selftest.feature-inventory.\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        var out: [String: String] = [:]
        for section in KeyboardShortcutCatalog.sections(from: menu) {
            for entry in section.entries {
                out["key.\(entry.chord)"] = "\(section.title): \(entry.title)"
            }
        }
        for action in TerminalShortcutAction.allCases {
            out["key.terminal.\(action.rawValue)"] = action.title
        }
        let configurable = KeyboardShortcutCatalog.configurableSections(settings: AppSettings(defaults: defaults))
        if configurable.contains(where: { $0.title == "Dictation" }) {
            out["key.dictation"] = "Start / stop dictation"
        }
        return out
    }

    /// The ⌘K palette's providers (as registered in `main.swift`) and the app
    /// verbs its action provider lists. "Switch to X" exists for every
    /// destination and is covered by the `dest.` rows.
    static func paletteIDs() -> [String: String] {
        var out: [String: String] = [:]
        if let main = source("main.swift") {
            for name in matches(#"index\.register\((UnifiedSearch[A-Za-z]+Provider)"#, in: main) {
                out["palette.provider.\(name)"] = name
            }
        }
        if let providers = source("UnifiedSearchProviders.swift") {
            for title in matches(#"Action\(title: "([^"]+)""#, in: providers).map(unescaped) {
                out["palette.action.\(title)"] = title
            }
        }
        return out
    }

    /// Every way into a page from outside it: the shell's public routes (the
    /// `open…`/`show…`/`select…`/`new…` methods notifications, App Intents,
    /// ⌘K, the menu bar extras and the Home cards call), the notification
    /// categories and their buttons, the App Intents, and the widgets.
    static func deepLinkIDs() -> [String: String] {
        var out: [String: String] = [:]
        // The shell's own API and the navigator it forwards to since stage 2
        // of the modular-shell migration: a route kept on either still
        // counts, and one dropped from all of them fails. Since stage 3 the
        // API is the base class both window layouts extend, and each layout
        // may answer a route of its own.
        for file in ["WorkspaceShellController.swift", "AppShellController.swift", "MainSplitShellController.swift",
                     "Navigator.swift"] {
            guard let text = source(file) else { continue }
            let pattern = #"(?m)^\s*(?:@objc\s+)?func\s+((?:open|show|select|switchTo|reveal|new)[A-Za-z]*)\("#
            for name in matches(pattern, in: text) { out["link.route.\(name)"] = name }
        }
        for category in NotificationActionRouting.categories() {
            out["link.notification.\(category.identifier)"] = category.identifier
            for action in category.actions {
                out["link.notification-action.\(action.identifier)"] = action.title
            }
        }
        if let intents = source("GrandLineAppIntents.swift") {
            for name in matches(#"AppShortcut\(intent: ([A-Za-z]+)\("#, in: intents) {
                out["link.intent.\(name)"] = name
            }
        }
        if let contract = source("WidgetSharedContract.swift") {
            for kind in matches(#"static let [A-Za-z]+ = "(com\.manjesh\.grandline\.native\.widget\.[a-z-]+)""#, in: contract) {
                out["link.widget.\(kind)"] = kind
            }
        }
        return out
    }

    /// The Settings page's categories, and every row whose title is a literal.
    /// Rows built in a loop (one per terminal shortcut, per App Intent, per
    /// backup section) are covered by those families' own rows.
    static func settingsIDs() -> [String: String] {
        var out: [String: String] = [:]
        for category in SettingsController.Category.allCases {
            out["settings.category.\(category.rawValue)"] = category.title
        }
        if let settings = source("SettingsController.swift") {
            // An interpolated title is a row built in a loop - see above.
            for title in matches(#"SettingsRow\(\s*title:\s*"([^"]+)""#, in: settings).map(unescaped)
            where !title.contains("\\(") {
                out["settings.row.\(title)"] = title
            }
        }
        return out
    }

    /// In-page tab strips: every `HelmSegmentedTabs` built from literal titles,
    /// plus the three tab sets that are enums.
    static func tabIDs() -> [String: String] {
        var out: [String: String] = [:]
        for (stem, text) in appSources() {
            var searchStart = text.startIndex
            while let open = text.range(of: "HelmSegmentedTabs(", range: searchStart..<text.endIndex) {
                let end = text.range(of: "selected:", range: open.upperBound..<text.endIndex)?.lowerBound
                    ?? text.index(open.upperBound, offsetBy: 600, limitedBy: text.endIndex) ?? text.endIndex
                let block = String(text[open.upperBound..<end])
                for title in matches(#"\.init\(id: [^,]+, title: "([^"]+)"\)"#, in: block).map(unescaped) {
                    out["tab.\(stem).\(title)"] = title
                }
                searchStart = open.upperBound
            }
        }
        for tab in HostsTab.allCases { out["tab.HostsTab.\(tab.rawValue)"] = tab.title }
        for tool in ToolKind.allCases { out["tab.ToolKind.\(tool.rawValue)"] = tool.rawValue }
        for tab in CompactModeTab.allCases { out["tab.CompactModeTab.\(tab.rawValue)"] = tab.rawValue }
        return out
    }

    /// The rows and headers of every page's own column (`HelmPageSidebar`):
    /// the literal ones by title, and the enum-driven ones by case. These are
    /// what the consolidation reshapes most - the Hosts column becomes
    /// Connections' tabs, Settings' becomes sidebar children, Tasks' projects
    /// and smart views become sidebar children - so each one needs a row
    /// saying where it lands. A project, a notebook page or a reading-list
    /// tag is the captain's data rather than a feature, and has no row.
    static func pageSidebarIDs() -> [String: String] {
        var out: [String: String] = [:]
        let patterns = [
            #"appendHeader\("([^"]+)"\)"#,
            #"appendRow\(id:[^)]*?title: "([^"]+)""#,
            #"\.init\(header: "([^"]+)""#,
            #"(?s)indicator: .{0,160}?title: "([^"]+)""#,
            #"\.init\(shortcut: "[^"]+", title: "([^"]+)"\)"#,
        ]
        // The component's own file declares the API rather than using it.
        let users = appSources().filter { stem, text in
            stem != "HelmPageSidebar"
                && (text.contains("HelmPageSidebar") || text.contains("appendRow(") || text.contains("quickActionsPanel"))
        }
        for (stem, text) in users {
            var titles = patterns.flatMap { matches($0, in: text) }
            if let footer = text.range(of: "setFooter(links: [") {
                let block = String(text[footer.upperBound...].prefix(400))
                let end = block.range(of: "])")?.lowerBound ?? block.endIndex
                titles += matches(#"title: "([^"]+)""#, in: String(block[..<end]))
            }
            for title in titles.map(unescaped) where !title.contains("\\(") {
                out["nav.\(stem).\(title)"] = title
            }
        }
        for scope in ShiftController.ShiftTaskScope.allCases { out["nav.ShiftTaskScope.\(scope.rawValue)"] = scope.title }
        for filter in SchedulesCardView.StatusFilter.allCases { out["nav.ScheduleStatusFilter.\(filter.rawValue)"] = filter.title }
        for category in CredentialCategory.allCases { out["nav.CredentialCategory.\(category.rawValue)"] = category.title }
        return out
    }

    /// The buttons a page hands the shell's header (`drillHeaderActions`), by
    /// property name, and every `HelmPageToolbar` button, by its selector.
    static func toolbarIDs() -> [String: String] {
        var out: [String: String] = [:]
        for (stem, text) in appSources() {
            if let start = text.range(of: "var drillHeaderActions: [NSView] {") {
                let body = braceBody(text, from: start.upperBound)
                for name in matches(#"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)"#, in: body)
                where name.hasSuffix("Button") || name.hasSuffix("button") || name.hasSuffix("Pill") {
                    out["toolbar.\(stem).\(name)"] = "drill header action"
                }
            }
            let callPattern = #"(?<!func )(?:HelmPageToolbar\.(?:labeledButton|iconButton)|make(?:Labeled|Icon)Button)\("#
            for range in ranges(callPattern, in: text) {
                let window = String(text[range.upperBound...].prefix(500))
                guard let selector = matches(#"action: #selector\(([A-Za-z_][A-Za-z0-9_]*)"#, in: window).first,
                      // The call must still be open where the selector is,
                      // or the selector belongs to a later statement.
                      let selectorRange = window.range(of: "#selector(\(selector)"),
                      !window[..<selectorRange.lowerBound].contains("\n\n") else { continue }
                let title = matches(#"title: "([^"]+)""#, in: String(window[..<selectorRange.lowerBound])).first
                    ?? matches(#"tooltip: "([^"]+)""#, in: String(window[..<selectorRange.lowerBound])).first
                    ?? selector
                out["toolbar.\(stem).\(selector)()"] = unescaped(title)
            }
        }
        return out
    }

    /// Every selector a control targets, per file. One row per file, with the
    /// selectors listed in its Today cell (checked exactly, see
    /// `checkCodeBackedFamilies`).
    static func pageActionIDs() -> [String: String] {
        var out: [String: String] = [:]
        for (stem, text) in appSources() {
            let selectors = Set(matches(#"(?:action: |\.action = )#selector\(([A-Za-z_][A-Za-z0-9_.]*)"#, in: text))
            guard !selectors.isEmpty else { continue }
            out["action.\(stem)"] = selectors.sorted().joined(separator: ", ")
        }
        return out
    }

    /// `AppLockedSurface`'s cases: every surface that asks the app lock
    /// before it shows the captain's data.
    static func lockSurfaceIDs() -> [String: String] {
        guard let gate = source("AppLockGate.swift"),
              let start = gate.range(of: "enum AppLockedSurface {") else { return [:] }
        let body = braceBody(gate, from: start.upperBound)
        return Dictionary(uniqueKeysWithValues: matches(#"(?m)^\s*case ([a-zA-Z]+)\s*$"#, in: body)
            .map { ("lock.\($0)", $0) })
    }

    static func dropTargetIDs() -> [String: String] {
        var out: [String: String] = [:]
        for (stem, text) in appSources() where text.contains("registerForDraggedTypes(") {
            out["drop.\(stem)"] = stem
        }
        return out
    }

    /// Every preference key this app owns that is declared as a constant.
    /// Notification payload keys are a wire format rather than saved state and
    /// are covered by the `link.notification` rows.
    static func savedStateIDs() -> [String: String] {
        var out: [String: String] = [:]
        for (stem, text) in appSources() where stem != "NotificationActions" {
            for key in matches(#"static let [A-Za-z]+ = "(fm\.[A-Za-z0-9.]+)""#, in: text) {
                out["state.\(key)"] = stem
            }
        }
        return out
    }

    // MARK: - Source helpers

    /// The app's sources, comments stripped, keyed by file stem.
    private static let cachedSources: [(String, String)] = {
        (SelfTestSources.appSourceFiles() ?? []).compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.deletingPathExtension().lastPathComponent, stripComments(text))
        }
    }()

    static func appSources() -> [(String, String)] { cachedSources }

    static func source(_ file: String) -> String? {
        let stem = (file as NSString).deletingPathExtension
        return cachedSources.first { $0.0 == stem }?.1
    }

    /// The text between the brace that opens just before `from` and its match.
    static func braceBody(_ text: String, from: String.Index) -> String {
        var depth = 1
        var index = from
        while index < text.endIndex {
            let c = text[index]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { return String(text[from..<index]) }
            }
            index = text.index(after: index)
        }
        return String(text[from...])
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    static func ranges(_ pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
    }

    /// A scanned string literal as it reads at run time: `\u{2026}` becomes
    /// the ellipsis it spells, so an id matches the title the captain sees.
    static func unescaped(_ literal: String) -> String {
        var out = literal
        for code in matches(#"\\u\{([0-9A-Fa-f]+)\}"#, in: literal) {
            guard let value = UInt32(code, radix: 16), let scalar = Unicode.Scalar(value) else { continue }
            out = out.replacingOccurrences(of: "\\u{\(code)}", with: String(Character(scalar)))
        }
        return out
    }

    static func backticked(in text: String) -> [String] {
        matches("`([^`]+)`", in: text)
    }

    /// Drops markdown emphasis and code ticks so a cell reads as plain words.
    static func plain(_ cell: String) -> String {
        cell.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Swift source with `//` and `/* */` comments removed and string literals
    /// kept, so a token that survives only in a comment does not count as the
    /// feature still being there.
    static func stripComments(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        let chars = Array(text)
        var i = 0
        var inString = false
        var inMultiline = false
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if inMultiline {
                if c == "\"" && next == "\"" && i + 2 < chars.count && chars[i + 2] == "\"" {
                    inMultiline = false
                    out += "\"\"\""
                    i += 3
                    continue
                }
                out.append(c)
                i += 1
                continue
            }
            if inString {
                out.append(c)
                if c == "\\", let next { out.append(next); i += 2; continue }
                if c == "\"" || c == "\n" { inString = false }
                i += 1
                continue
            }
            if c == "\"" {
                if next == "\"" && i + 2 < chars.count && chars[i + 2] == "\"" {
                    inMultiline = true
                    out += "\"\"\""
                    i += 3
                    continue
                }
                inString = true
                out.append(c)
                i += 1
                continue
            }
            if c == "/" && next == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && next == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }
}

#endif
