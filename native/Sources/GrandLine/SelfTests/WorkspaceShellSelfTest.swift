// Grand Line - native macOS app.
//
// UX-01 and UX-12 of the 2026-10 review: the Workspace shell, mounted for
// real. Window-backed, so it sits in `run-all-tests.sh`'s `NEEDS_SESSION`
// list - every case is a question about a real window's chrome, a real
// laid-out sidebar or a real navigation through the shell.
//
// What each case holds, and how it was shown to fail:
//
//   1. **The map.** Seventeen rows in Home plus four headed groups, every
//      name whole at the sidebar's full width (a truncated module name is a
//      map you cannot read).
//   2. **Every route is reachable from the sidebar**, through the sidebar's
//      own selection path and the module tab strip, and lands lit in the
//      sidebar and named in the window title.
//   3. **The chords.** ⌘1-⌘6 reach Home and the Work group through the real
//      Window-menu items.
//   4. **The window is a Mac window.** A title naming the module (the window's
//      own, and visible as the toolbar's title item), a unified `NSToolbar`,
//      full-size content, and the traffic lights where AppKit puts them - not
//      hidden, not moved.
//   5. **No back button anywhere**, and none of the retired chrome mounted.
//   6. **Icons only below the threshold** (1210pt - see
//      `WorkspaceSidebarController.compactBelowWindowWidth`), full labels
//      again above it.
//   7. **The toolbar hides with the lock**, because it sits outside the
//      content view the lock overlay covers.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum WorkspaceShellSelfTest {

    static func run() -> Bool {
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        let cases: [(String, () -> String?)] = [
            ("the sidebar is the whole map, every name whole", test_sidebarIsTheMap),
            ("every route is reachable from the sidebar and its tabs", test_everyRouteReachable),
            ("⌘1-⌘6 reach Home and the Work group", test_chordsReachModules),
            ("the window has a title naming the module, a toolbar and its own traffic lights", test_windowChrome),
            ("no back button and no retired chrome", test_noBackButton),
            ("the sidebar shows icons only below its threshold", test_compactSidebar),
            ("the toolbar hides with the lock", test_toolbarHidesWithTheLock),
        ]
        var failures = 0
        for (name, body) in cases {
            if let failure = body() {
                SelfTestAssertions.reportFailure("\(name): \(failure)")
                failures += 1
            } else {
                SelfTestAssertions.reportPass(name)
            }
        }
        print(failures == 0 ? "WorkspaceShellSelfTest: all \(cases.count) cases passed"
                            : "WorkspaceShellSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Fixtures

    /// The real shell in a real window wearing the real chrome
    /// (`ReviewTourLab.makeOffScreenShell` builds it the way `main.swift`
    /// does), with every store pointed at a scratch directory.
    private static func withShell<T>(_ body: (NSWindow, AppShellController) -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-workspace-shell-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_DOCS_RUNBOOKS_DIR": dir.appendingPathComponent("docsRunbooks").path,
        ]
        var previous: [String: String?] = [:]
        for (key, value) in overrides {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { window.orderOut(nil) }
        return body(window, shell)
    }

    private static func everyView(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(everyView) }

    // MARK: 1 - the map

    private static func test_sidebarIsTheMap() -> String? {
        withShell { window, shell in
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: 1512, height: 950), display: true)
            shell.applySidebarCompactness()
            shell.view.layoutSubtreeIfNeeded()
            let rows = shell.sidebar.debugRowTitles
            let headers = rows.filter { $0.hasPrefix("# ") }
            guard headers == ["# Work", "# Observe", "# Workbench", "# Machine"] else {
                return "expected four headed groups, found \(headers)"
            }
            guard rows.first == "Home" else { return "Home is not the first row: \(rows.prefix(3))" }
            let modules = rows.filter { !$0.hasPrefix("# ") && !$0.hasPrefix("  ") }
            guard modules == ModuleTable.all.map(\.title) else {
                return "the sidebar's rows \(modules) disagree with the module table"
            }
            for module in ModuleTable.all {
                let row = shell.sidebar.debugRow(ofModule: module.id)
                guard let cell = shell.sidebar.debugCell(atRow: row) else { return "\(module.title) has no cell" }
                cell.layoutSubtreeIfNeeded()
                guard let label = everyView(cell).compactMap({ $0 as? NSTextField })
                        .first(where: { $0.stringValue == module.title }) else {
                    return "\(module.title)'s row draws no title label"
                }
                guard label.frame.width + 0.5 >= label.intrinsicContentSize.width else {
                    return "\(module.title) is truncated in the sidebar (\(label.frame.width) of \(label.intrinsicContentSize.width)pt)"
                }
            }
            return nil
        }
    }

    // MARK: 2 - every route

    private static func test_everyRouteReachable() -> String? {
        withShell { _, shell in
            var reached: Set<RailDestination> = []
            for module in ModuleTable.all {
                // The sidebar's own selection path, the way a click reports.
                shell.sidebar.debugClickRow(shell.sidebar.debugRow(ofModule: module.id))
                guard shell.currentModuleID == module.id else {
                    return "clicking \(module.title) in the sidebar showed \(shell.currentModuleID.rawValue)"
                }
                guard shell.windowTitleForTests == module.title else {
                    return "\(module.title) titled the window \(shell.windowTitleForTests)"
                }
                // Every tab through the module's own tab strip.
                if module.tabs.count > 1 {
                    guard shell.contentPane.debugTabsAreShown,
                          shell.contentPane.moduleTabs.debugTitles == module.tabs.map(\.title) else {
                        return "\(module.title) shows tabs \(shell.contentPane.moduleTabs.debugTitles), expected \(module.tabs.map(\.title))"
                    }
                    for index in module.tabs.indices {
                        shell.contentPane.moduleTabs.debugClick(index)
                        guard let route = shell.debugCurrentDestination,
                              route == module.tabs[index].route else {
                            return "\(module.title)'s \(module.tabs[index].title) tab did not show .\(module.tabs[index].route.rawValue)"
                        }
                        guard shell.contentPane.moduleTabs.selectedIndex == index else {
                            return "\(module.title)'s tab strip did not light \(module.tabs[index].title)"
                        }
                        reached.insert(route)
                    }
                } else {
                    guard !shell.contentPane.debugTabsAreShown else {
                        return "\(module.title) has one tab but shows a tab strip"
                    }
                    reached.insert(module.defaultTab.route)
                }
            }
            let missing = Set(RailDestination.allCases).subtracting(reached).map(\.rawValue).sorted()
            guard missing.isEmpty else { return "never reached from the sidebar: \(missing)" }
            // A module remembers its tab: back to Connections lands on the tab
            // left last, the way Mail returns to a mailbox's last selection.
            shell.show(.commandLibrary)
            shell.show(.shift)
            shell.showModule(.connections)
            guard shell.debugCurrentDestination == .commandLibrary else {
                return "Connections did not return to its last tab (Commands)"
            }
            return nil
        }
    }

    // MARK: 3 - chords

    private static func test_chordsReachModules() -> String? {
        withShell { _, shell in
            let menu = AppDelegate().buildMenu(installing: false)
            guard let window = menu.items.compactMap(\.submenu).first(where: { $0.title == "Window" }) else {
                return "there is no Window menu"
            }
            let chorded = ModuleTable.all.filter { $0.chord != nil }
            guard chorded.count == 6 else { return "expected six chorded modules, found \(chorded.count)" }
            for module in chorded.reversed() {
                guard let item = window.items.first(where: { ($0.representedObject as? String) == module.id.rawValue }) else {
                    return "\(module.title) has no Window-menu item"
                }
                guard item.keyEquivalent == module.chord?.key, item.keyEquivalentModifierMask == .command else {
                    return "\(module.title)'s item carries \(item.keyEquivalentModifierMask.rawValue)+\(item.keyEquivalent)"
                }
                guard item.action == #selector(AppShellController.selectModuleFromMenu(_:)) else {
                    return "\(module.title)'s item is not wired to selectModuleFromMenu"
                }
                shell.selectModuleFromMenu(item)
                guard shell.currentModuleID == module.id else {
                    return "\(module.chord?.displayString ?? "") showed \(shell.currentModuleID.rawValue), expected \(module.id.rawValue)"
                }
            }
            return nil
        }
    }

    // MARK: 4 - the window

    private static func test_windowChrome() -> String? {
        withShell { window, shell in
            guard window.toolbar === shell.toolbarController.toolbar else { return "the window carries no Workspace toolbar" }
            // The visible title is the toolbar's own title item, over the
            // content column; the window's `title` names the module too.
            let title = shell.contentPane.titleView
            guard !title.isHiddenOrHasHiddenAncestor, title.frame.maxY > shell.contentPane.bodyHost.frame.maxY else {
                return "no visible title in the toolbar band - UX-12 asks for a visible title naming the module"
            }
            guard window.toolbarStyle == .unified else { return "the toolbar is not the unified style" }
            guard window.styleMask.contains(.fullSizeContentView) else {
                return "the content is not full-size, so the sidebar cannot run under the traffic lights"
            }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), !button.isHidden else {
                    return "the \(kind) traffic light is hidden"
                }
            }
            // Where AppKit puts them: inside their own titlebar container, not
            // pushed outside it the way the old relocation did.
            if let close = window.standardWindowButton(.closeButton), let container = close.superview {
                guard container.bounds.contains(close.frame) else {
                    return "the close button sits outside its own titlebar container (\(close.frame) in \(container.bounds))"
                }
            }
            for route in [RailDestination.shift, .review, .vault, .updates] {
                shell.show(route)
                let module = ModuleTable.module(for: route)
                guard window.title == AppDelegate.windowTitle(context: module.title) else {
                    return "on \(route) the window is titled \(window.title), expected \(module.title)"
                }
                guard shell.contentPane.titleView.debugTitle == module.title else {
                    return "on \(route) the toolbar's title reads \(shell.contentPane.titleView.debugTitle)"
                }
                guard shell.contentPane.titleView.debugSubtitle == window.subtitle else {
                    return "on \(route) the toolbar's subtitle and the window's disagree"
                }
                guard !window.subtitle.isEmpty else { return "on \(route) the window has no subtitle" }
            }
            let ids = Set(shell.toolbarController.toolbar.items.map(\.itemIdentifier))
            for wanted in [NSToolbarItem.Identifier.workspaceSidebarToggle, .workspaceSidebarSeparator, .workspaceSearch, .workspaceRecents,
                           .workspaceTheme, .workspaceBell] where !ids.contains(wanted) {
                return "the toolbar has no \(wanted.rawValue) item"
            }
            guard !shell.split.inspectorIsShown else { return "the inspector is open with nothing selected" }
            return nil
        }
    }

    // MARK: 5 - no back button

    private static func test_noBackButton() -> String? {
        withShell { window, shell in
            // The shell's own chrome - the toolbar, the sidebar and the
            // content column around the page. A page's own in-page navigation
            // (Docs' article "Back" to its list) is the page's, not a drill.
            let body = shell.contentPane.bodyHost
            func chrome(_ root: NSView) -> [NSView] {
                root === body ? [] : [root] + root.subviews.flatMap(chrome)
            }
            for route in RailDestination.allCases {
                shell.show(route)
                for view in chrome(window.contentView?.superview ?? shell.view) where !view.isHiddenOrHasHiddenAncestor {
                    let label = view.accessibilityLabel() ?? ""
                    if label == "Back" || label.hasPrefix("Back to") {
                        return "\(route) shows a Back control (\(type(of: view)))"
                    }
                    let typeName = String(describing: type(of: view))
                    if typeName.contains("DaylightBar") || typeName.contains("DrillHeader") || typeName.contains("SessionStrip") {
                        return "\(route) still mounts retired chrome: \(typeName)"
                    }
                }
            }
            return nil
        }
    }

    // MARK: 6 - compact sidebar

    private static func test_compactSidebar() -> String? {
        withShell { window, shell in
            func resize(_ width: CGFloat) {
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: width, height: 760), display: true)
                shell.applySidebarCompactness()
                shell.view.layoutSubtreeIfNeeded()
            }
            resize(1400)
            guard !shell.sidebar.isCompact,
                  abs(shell.sidebar.view.frame.width - WorkspaceSidebarController.expandedWidth) < 1.5 else {
                return "at 1400pt the sidebar is \(shell.sidebar.view.frame.width)pt (compact \(shell.sidebar.isCompact))"
            }
            resize(1100)
            guard shell.sidebar.isCompact,
                  abs(shell.sidebar.view.frame.width - WorkspaceSidebarController.compactWidth) < 1.5 else {
                return "at 1100pt the sidebar is \(shell.sidebar.view.frame.width)pt (compact \(shell.sidebar.isCompact)) - "
                    + "expected icons only at \(WorkspaceSidebarController.compactWidth)pt"
            }
            // Icons only, and every row still says what it is.
            let row = shell.sidebar.debugRow(ofModule: .tasks)
            guard let cell = shell.sidebar.debugCell(atRow: row) else { return "no Tasks cell in the icon column" }
            let visibleText = everyView(cell).compactMap { $0 as? NSTextField }
                .filter { !$0.isHiddenOrHasHiddenAncestor && !$0.stringValue.isEmpty }
            guard visibleText.isEmpty else { return "the icon column still draws text: \(visibleText.map(\.stringValue))" }
            guard (cell.accessibilityLabel() ?? "").hasPrefix("Tasks"), cell.toolTip?.isEmpty == false else {
                return "the icon-only Tasks row lost its label or tooltip"
            }
            guard shell.sidebar.debugFooter.debugVisibleExtras.isEmpty else {
                return "the icon-only account row still draws \(shell.sidebar.debugFooter.debugVisibleExtras) over the avatar"
            }
            resize(1512)
            guard !shell.sidebar.isCompact,
                  abs(shell.sidebar.view.frame.width - WorkspaceSidebarController.expandedWidth) < 1.5 else {
                return "widening back to 1512pt left the sidebar at \(shell.sidebar.view.frame.width)pt"
            }
            return nil
        }
    }

    // MARK: 7 - the lock

    /// Behaviour for the toolbar's own half, and a source guard for the
    /// wiring: driving `showLock` for real starts Automic Vault's service
    /// check, which a suite must never do.
    private static func test_toolbarHidesWithTheLock() -> String? {
        withShell { window, shell in
            shell.toolbarController.setLocked(true)
            guard window.toolbar?.isVisible == false else { return "a locked app still shows its toolbar" }
            shell.toolbarController.setLocked(false)
            guard window.toolbar?.isVisible == true else { return "unlocking did not bring the toolbar back" }
            guard let dir = SelfTestSources.appSourceDirectory(),
                  let source = try? String(contentsOf: dir.appendingPathComponent("AppShellController.swift"), encoding: .utf8) else {
                return "could not read AppShellController.swift - the wiring half would pass vacuously"
            }
            guard let show = source.range(of: "func showLock(reason: AppLockReason)"),
                  let hide = source.range(of: "private func hideLock()") else {
                return "showLock/hideLock moved - the wiring guard has lost its bearings"
            }
            let showBody = source[show.upperBound...].prefix(3000)
            let hideBody = source[hide.upperBound...].prefix(400)
            guard showBody.contains("toolbarController.setLocked(true)") else {
                return "showLock no longer hides the toolbar - the bell and Recents stay usable over the lock"
            }
            guard hideBody.contains("toolbarController.setLocked(false)") else {
                return "hideLock no longer brings the toolbar back"
            }
            return nil
        }
    }
}

#endif
