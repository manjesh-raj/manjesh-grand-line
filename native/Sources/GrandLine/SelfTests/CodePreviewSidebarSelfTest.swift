// Grand Line - native macOS app.
//
// The pure-logic half of Code Preview's snippet list
// (`fm/grandline-codepreview-file-sidebar`): the list's order, the filter, the
// icon table, the remembered visibility and width, and the ⌘B menu item.
//
// Nothing here mounts a window, so it runs in CI's blocking lane. The column
// itself - rows, clicks, the keyboard, hiding and resizing in a real window -
// is `CodePreviewSidebarViewSelfTest`.
//
// `FM_RUN_CODE_PREVIEW_SIDEBAR_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CodePreviewSidebarSelfTest {

    static func run() -> Bool {
        var ok = true
        checkExplorerOrder(&ok)
        checkFilter(&ok)
        checkEverySymbolResolves(&ok)
        checkPreferences(&ok)
        checkTheMenuItem(&ok)
        print(ok ? "CodePreviewSidebarSelfTest: OK" : "CodePreviewSidebarSelfTest: FAILURES")
        return ok
    }

    private static func entries(_ names: [String]) -> [CodePreviewFileEntry] {
        names.enumerated().map { CodePreviewFileEntry(key: "k\($0.offset)", name: $0.element) }
    }

    // MARK: Order

    /// The list is the folder in explorer order, whatever order the tabs are
    /// in - and `snippet-2` comes before `snippet-10`.
    private static func checkExplorerOrder(_ ok: inout Bool) {
        let tabOrder = ["snippet-10.txt", "Zeta.yaml", "snippet-2.txt", "alpha.sh", "Beta.json"]
        let listed = CodePreviewFileList.visibleEntries(entries(tabOrder), filter: "").map(\.name)
        // Discriminating power: the fixture is not already in either order.
        check(tabOrder != tabOrder.sorted(), "the fixture must not already be sorted", &ok)
        check(listed == ["alpha.sh", "Beta.json", "snippet-2.txt", "snippet-10.txt", "Zeta.yaml"],
              "the list should be in explorer order (numeric-aware, case-insensitive), got \(listed)", &ok)

        // A total order: two names that compare equal still come out the same
        // way every time, so a rebuild can never swap them.
        let twins = [CodePreviewFileEntry(key: "b", name: "notes.txt"),
                     CodePreviewFileEntry(key: "a", name: "Notes.txt")]
        let once = CodePreviewFileList.visibleEntries(twins, filter: "")
        let again = CodePreviewFileList.visibleEntries(twins.reversed(), filter: "")
        check(once == again, "names that compare equal must still sort deterministically", &ok)

        check(CodePreviewFileList.visibleEntries([], filter: "").isEmpty, "no snippets, no rows", &ok)
    }

    // MARK: Filter

    private static func checkFilter(_ ok: inout Bool) {
        let all = entries([
            "newrelic-ai.txt", "manifest-sync.txt", "543385233843-eu8u0k3f2lljlt.txt",
            "http.txt", "https-hooks-slack-com-services-T0123.txt", "Café-notes.md",
        ])
        func names(_ filter: String) -> [String] {
            CodePreviewFileList.visibleEntries(all, filter: filter).map(\.name)
        }
        check(names("").count == all.count, "a blank filter keeps every snippet", &ok)
        check(names("   ").count == all.count, "a whitespace-only filter keeps every snippet", &ok)
        check(names("HTTP") == ["http.txt", "https-hooks-slack-com-services-T0123.txt"],
              "the filter ignores case, got \(names("HTTP"))", &ok)
        check(names("hook slack") == ["https-hooks-slack-com-services-T0123.txt"],
              "every word has to match, in any position, got \(names("hook slack"))", &ok)
        check(names("slack hook") == names("hook slack"), "word order does not matter", &ok)
        check(names("cafe") == ["Café-notes.md"], "the filter ignores diacritics, got \(names("cafe"))", &ok)
        check(names("233843").count == 1, "a fragment of a long hash name finds it", &ok)
        check(names("zzz").isEmpty, "a filter nothing matches leaves no rows", &ok)
        // The filtered rows keep explorer order rather than match order.
        let txt = names("txt")
        check(txt == txt.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
              "filtered rows stay in explorer order, got \(txt)", &ok)
    }

    // MARK: Icons

    /// `NSImage(systemSymbolName:)` returns nil silently, so a mistyped name
    /// in the table would be an invisible icon. Every language is resolved
    /// here, and the table must actually tell types apart.
    private static func checkEverySymbolResolves(_ ok: inout Bool) {
        var symbols: Set<String> = []
        for language in CodePreviewLanguage.all {
            let name = CodePreviewFileList.symbol(for: language)
            symbols.insert(name)
            check(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                  "\(language.id)'s row icon \(name) is not a real SF Symbol", &ok)
        }
        check(NSImage(systemSymbolName: CodePreviewFileList.plainSymbol, accessibilityDescription: nil) != nil,
              "the fallback icon must resolve", &ok)
        check(symbols.count >= 8, "the icon table should distinguish file types, got \(symbols.count) icons", &ok)
        check(CodePreviewFileList.symbol(for: CodePreviewLanguage.forFilename("a.swift"))
                != CodePreviewFileList.symbol(for: CodePreviewLanguage.forFilename("a.txt")),
              "a Swift file and a text file must not share an icon", &ok)
        check(CodePreviewFileEntry(key: "k", name: "deploy.sh").language.id == "shell",
              "an entry's language comes from its extension", &ok)
    }

    // MARK: Preferences

    private static func checkPreferences(_ ok: inout Bool) {
        let suite = "fm.selftest.codepreview.sidebar.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("could not open a scratch defaults domain", &ok)
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        typealias Prefs = CodePreviewSidebarPreferences

        check(Prefs.isVisible(in: defaults), "a profile that never toggled the list sees it", &ok)
        Prefs.setVisible(false, in: defaults)
        check(!Prefs.isVisible(in: defaults), "hiding the list is remembered", &ok)
        Prefs.setVisible(true, in: defaults)
        check(Prefs.isVisible(in: defaults), "showing it again is remembered", &ok)

        check(Prefs.width(in: defaults) == Prefs.defaultWidth, "no stored width reads as the default", &ok)
        check(Prefs.defaultWidth == HelmPageSidebar.width,
              "the default width is the app's own sidebar width", &ok)
        Prefs.setWidth(300, in: defaults)
        check(Prefs.width(in: defaults) == 300, "a dragged width is remembered", &ok)
        Prefs.setWidth(5, in: defaults)
        check(Prefs.width(in: defaults) == Prefs.minimumWidth, "a width below the floor is clamped up", &ok)
        Prefs.setWidth(5000, in: defaults)
        check(Prefs.width(in: defaults) == Prefs.maximumWidth, "a width above the ceiling is clamped down", &ok)
        defaults.set("wide", forKey: Prefs.widthKey)
        check(Prefs.width(in: defaults) == Prefs.defaultWidth, "a garbage stored width reads as the default", &ok)
        defaults.set(Double.nan, forKey: Prefs.widthKey)
        check(Prefs.width(in: defaults) == Prefs.defaultWidth, "a NaN stored width reads as the default", &ok)
        check(Prefs.clamp(.infinity) == Prefs.defaultWidth, "an infinite width clamps to the default", &ok)

        // The production default is `AppDefaults.store` - a suite process's
        // own domain, never the captain's.
        let previous = AppDefaults.store.object(forKey: Prefs.visibleKey)
        defer {
            if let previous { AppDefaults.store.set(previous, forKey: Prefs.visibleKey) }
            else { AppDefaults.store.removeObject(forKey: Prefs.visibleKey) }
        }
        Prefs.setVisible(false)
        check(AppDefaults.store.object(forKey: Prefs.visibleKey) as? Bool == false,
              "the default store is `AppDefaults.store`", &ok)
    }

    // MARK: The menu item

    /// ⌘B is a real File menu item routed to Code Preview, so it is
    /// discoverable and lands in the generated shortcut sheet.
    /// `NavigationCoherenceSelfTest` separately fails the run if any other
    /// item ever claims the same chord.
    private static func checkTheMenuItem(_ ok: inout Bool) {
        let menu = AppDelegate().buildMenu(installing: false)
        guard let file = menu.items.first(where: { $0.submenu?.title == "File" })?.submenu else {
            fail("no File menu", &ok)
            return
        }
        let item = file.items.first { $0.action == #selector(Navigator.toggleCodePreviewSidebarFromMenu) }
        check(item != nil, "the File menu should carry the snippet list toggle", &ok)
        check(item?.keyEquivalent == "b" && item?.keyEquivalentModifierMask == [.command],
              "the toggle should be \u{2318}B, got \(item?.keyEquivalent ?? "-") \(String(describing: item?.keyEquivalentModifierMask))",
              &ok)
        var claims = 0
        func walk(_ menu: NSMenu) {
            for entry in menu.items {
                if entry.keyEquivalent.lowercased() == "b" { claims += 1 }
                if let sub = entry.submenu { walk(sub) }
            }
        }
        walk(menu)
        check(claims == 1, "exactly one menu item may use the B key, found \(claims)", &ok)
    }
}

#endif
