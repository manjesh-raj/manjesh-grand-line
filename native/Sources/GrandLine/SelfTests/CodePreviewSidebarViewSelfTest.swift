// Grand Line - native macOS app.
//
// The window-backed half of Code Preview's snippet list
// (`fm/grandline-codepreview-file-sidebar`): the real `CodePreviewController`
// in a real window over a scratch store, with the real Monaco page behind it.
//
// What it locks down:
//
//   1. The list mirrors the open snippets - every one, in explorer order,
//      with the active one marked, its full name in a tooltip and its name
//      middle-truncated.
//   2. A row opens its snippet, by click and by keyboard (arrows browse
//      without opening, Return opens, Escape leaves), and its close control
//      appears on hover and closes the snippet.
//   3. Hiding the list gives the editor the full width, the toolbar button
//      and ⌘B both toggle it, and a second controller - the honest stand-in
//      for a relaunch - comes up in the remembered state and width.
//   4. A hundred snippets: the list scrolls, the tab strip scrolls, the
//      active tab is kept in view, `+` stays reachable and the window does
//      not widen.
//
// Window-backed, so it sits in `run-all-tests.sh`'s NEEDS_SESSION list. It
// raises no modal alert and starts no drag session (both hang a CI runner):
// closing a snippet shows a non-modal undo toast, and the resize handle is
// driven through its own mouse handlers rather than a drag session.
//
// `FM_RUN_CODE_PREVIEW_SIDEBAR_VIEW_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CodePreviewSidebarViewSelfTest {

    private typealias Prefs = CodePreviewSidebarPreferences

    static func run() -> Bool {
        var ok = true

        guard CodePreviewAssets.isAvailable else {
            fail("no Monaco bundle - run native/Scripts/build-monaco-web.sh", &ok)
            return false
        }

        // A per-process `AppDefaults.store` already; cleared anyway so this
        // suite starts from a profile that has never toggled the list.
        AppDefaults.store.removeObject(forKey: Prefs.visibleKey)
        AppDefaults.store.removeObject(forKey: Prefs.widthKey)
        defer {
            AppDefaults.store.removeObject(forKey: Prefs.visibleKey)
            AppDefaults.store.removeObject(forKey: Prefs.widthKey)
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-preview-sidebar-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let store = CodePreviewStore(root: scratch)
        let controller = CodePreviewController(store: store)
        let window = OffScreenProbe.window(width: 1200, height: 760, styleMask: [.titled, .resizable])
        window.contentView = controller.view
        NSApp.setActivationPolicy(.accessory)
        window.orderFront(nil)
        window.displayIfNeeded()

        guard waitFor(timeout: 30, until: { controller.debugWebView.isReady }) else {
            fail("Monaco never reported ready", &ok)
            return false
        }
        // R4-UI-09: an empty folder opens on an invitation now, not a tab.
        // The checks below start from the one untitled tab it used to make.
        controller.debugNewSnippet()
        controller.view.layoutSubtreeIfNeeded()

        checkShownByDefault(controller, &ok)
        seed(controller, names: [
            "newrelic-ai.txt", "manifest-sync.txt", "543385233843-eu8u0k3f2lljlt8xq0zk.txt",
            "http.txt", "https-hooks-slack-com-services-T0123ABCD-B0456EFGH.txt",
        ])
        checkListMirrorsTheTabs(controller, "a few files", &ok)
        checkRowsAndTooltips(controller, &ok)
        checkClickingARowOpensIt(controller, &ok)
        checkRenameFollows(controller, &ok)
        checkCloseControl(controller, store, &ok)
        checkFilter(controller, &ok)
        checkKeyboard(controller, window, &ok)
        checkHideAndShow(controller, &ok)
        checkMenuToggle(controller, window, &ok)
        checkResize(controller, &ok)
        checkPersistenceAcrossControllers(store, &ok)

        seed(controller, names: (1...20).map { "service-\($0)-config.yaml" })
        checkListMirrorsTheTabs(controller, "25 files", &ok)
        seed(controller, names: (21...95).map { "deploy-pipeline-stage-\($0)-runbook.sh" })
        checkListMirrorsTheTabs(controller, "100 files", &ok)
        checkManyFiles(controller, window, &ok)
        checkThemes(controller, &ok)

        window.orderOut(nil)
        print(ok ? "CodePreviewSidebarViewSelfTest: OK" : "CodePreviewSidebarViewSelfTest: FAILURES")
        return ok
    }

    // MARK: Helpers

    private static func seed(_ controller: CodePreviewController, names: [String]) {
        for name in names {
            controller.debugNewSnippet(named: name, content: "# \(name)\n")
        }
        controller.view.layoutSubtreeIfNeeded()
    }

    private static func explorerOrder(_ names: [String]) -> [String] {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func keyEvent(_ keyCode: UInt16, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: "",
                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)
    }

    private static func waitFor(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: 1. The list mirrors the tabs

    private static func checkShownByDefault(_ controller: CodePreviewController, _ ok: inout Bool) {
        let sidebar = controller.debugSidebar
        check(!sidebar.isHidden, "a profile that never toggled the list should see it", &ok)
        check(sidebar.frame.width >= Prefs.defaultWidth - 1,
              "the list should open at its default width, got \(sidebar.frame.width)", &ok)
        check(sidebar.debugRowNames == controller.debugTabNames,
              "a fresh page's one placeholder tab should be its one row", &ok)
    }

    private static func checkListMirrorsTheTabs(_ controller: CodePreviewController, _ label: String,
                                                _ ok: inout Bool) {
        let sidebar = controller.debugSidebar
        sidebar.debugSetFilter("")
        let tabs = controller.debugTabNames
        check(sidebar.debugRowNames == explorerOrder(tabs),
              "\(label): every open snippet should be a row, in explorer order", &ok)
        check(sidebar.debugCountText == "\(tabs.count)",
              "\(label): the header count should be \(tabs.count), got \(sidebar.debugCountText)", &ok)
        check(sidebar.debugActiveRowName == controller.debugCurrentName,
              "\(label): the active row should be the snippet on screen", &ok)
        check(sidebar.debugRows.filter(\.debugIsActive).count == 1,
              "\(label): exactly one row should be marked active", &ok)
    }

    private static func checkRowsAndTooltips(_ controller: CodePreviewController, _ ok: inout Bool) {
        let long = "https-hooks-slack-com-services-T0123ABCD-B0456EFGH.txt"
        controller.view.layoutSubtreeIfNeeded()
        guard let row = controller.debugSidebar.debugRows.first(where: { $0.entry.name == long }),
              let chip = controller.debugChip(named: long) else {
            fail("the long-named snippet has no row or no tab", &ok)
            return
        }
        check(row.toolTip == long && row.debugLabel.toolTip == long, "a row's tooltip is its full name", &ok)
        check(chip.toolTip == long, "a tab's tooltip is its full name", &ok)
        check(row.debugLabel.lineBreakMode == .byTruncatingMiddle,
              "a row's name truncates in the middle, so the extension stays visible", &ok)
        // Discriminating power: the name really does not fit, so truncation
        // is doing something.
        check(row.debugLabel.frame.width > 0
                && row.debugLabel.attributedStringValue.size().width > row.debugLabel.frame.width,
              "the fixture name should be too long for the column", &ok)
        check(row.debugIconImage != nil, "every row leads with a file icon", &ok)
        check(row.frame.height == CodePreviewFileSidebar.rowHeight,
              "rows are \(CodePreviewFileSidebar.rowHeight)pt, got \(row.frame.height)", &ok)
        check(row.isAccessibilityElement() && (row.accessibilityLabel() ?? "").contains(long),
              "VoiceOver reads a row by its name", &ok)
        check(row.closeButton.accessibilityLabel() == "Close \(long)",
              "VoiceOver finds each row's close control by name", &ok)
    }

    private static func checkClickingARowOpensIt(_ controller: CodePreviewController, _ ok: inout Bool) {
        let target = "manifest-sync.txt"
        check(controller.debugCurrentName != target, "the fixture must start on a different snippet", &ok)
        guard let row = controller.debugSidebar.debugRows.first(where: { $0.entry.name == target }) else {
            fail("no row for \(target)", &ok)
            return
        }
        // The row's own click recognizer, through its real target/action.
        check(row.performPrimaryAction(), "a row should be activatable", &ok)
        check(controller.debugCurrentName == target, "clicking a row opens its snippet", &ok)
        check(controller.debugSidebar.debugActiveRowName == target, "…and marks that row active", &ok)
    }

    /// A rename moves the tab, its tooltip and the row together - the three
    /// must never name one snippet two ways.
    private static func checkRenameFollows(_ controller: CodePreviewController, _ ok: inout Bool) {
        controller.debugRename(from: "http.txt", to: "aaa-http-probe.txt")
        let rows = controller.debugSidebar.debugRowNames
        check(rows.contains("aaa-http-probe.txt") && !rows.contains("http.txt"),
              "renaming a snippet renames its row, got \(rows)", &ok)
        check(rows == explorerOrder(controller.debugTabNames) && rows.firstIndex(of: "aaa-http-probe.txt") == 1,
              "…and re-sorts it into explorer order, got \(rows)", &ok)
        check(controller.debugChip(named: "aaa-http-probe.txt")?.toolTip == "aaa-http-probe.txt",
              "…and the tab's tooltip follows the new name", &ok)
        controller.debugRename(from: "aaa-http-probe.txt", to: "http.txt")
    }

    private static func checkCloseControl(_ controller: CodePreviewController, _ store: CodePreviewStore,
                                          _ ok: inout Bool) {
        let target = "newrelic-ai.txt"
        guard let row = controller.debugSidebar.debugRows.first(where: { $0.entry.name == target }) else {
            fail("no row for \(target)", &ok)
            return
        }
        check(row.debugCloseAlpha == 0, "a resting row hides its close control", &ok)
        row.debugSetHovering(true)
        check(row.debugCloseAlpha == 1, "hovering a row reveals its close control", &ok)
        row.debugSetHovering(false)
        check(row.debugCloseAlpha == 0, "leaving the row hides it again", &ok)

        check(store.names().contains(target), "the fixture snippet should be on disk", &ok)
        row.closeButton.performClick(nil)
        check(!controller.debugTabNames.contains(target), "the close control closes the snippet's tab", &ok)
        check(!controller.debugSidebar.debugRowNames.contains(target), "…and removes its row", &ok)
        check(!store.names().contains(target), "…and deletes it, the way closing a tab always has", &ok)
    }

    // MARK: 2. Filter and keyboard

    private static func checkFilter(_ controller: CodePreviewController, _ ok: inout Bool) {
        let sidebar = controller.debugSidebar
        sidebar.debugSetFilter("hook slack")
        check(sidebar.debugRowNames == ["https-hooks-slack-com-services-T0123ABCD-B0456EFGH.txt"],
              "the filter narrows the list, got \(sidebar.debugRowNames)", &ok)
        check(sidebar.debugCountText == "\(controller.debugTabNames.count)",
              "the header still counts every open snippet while filtering", &ok)
        _ = sidebar.debugFilterCommand(#selector(NSResponder.insertNewline(_:)))
        check(controller.debugCurrentName == "https-hooks-slack-com-services-T0123ABCD-B0456EFGH.txt",
              "Return in the filter opens the first match", &ok)

        sidebar.debugSetFilter("zzz-nothing")
        check(sidebar.debugRowNames.isEmpty, "a filter nothing matches leaves no rows", &ok)
        check(sidebar.debugEmptyMessage?.contains("zzz-nothing") == true,
              "…and says so rather than showing a blank column", &ok)

        _ = sidebar.debugFilterCommand(#selector(NSResponder.cancelOperation(_:)))
        check(sidebar.filterField.stringValue.isEmpty, "Escape clears the filter", &ok)
        check(sidebar.debugRowNames.count == controller.debugTabNames.count, "…and brings every row back", &ok)
    }

    private static func checkKeyboard(_ controller: CodePreviewController, _ window: NSWindow,
                                      _ ok: inout Bool) {
        let sidebar = controller.debugSidebar
        let names = sidebar.debugRowNames
        guard names.count >= 3 else {
            fail("the keyboard check needs at least three rows", &ok)
            return
        }
        controller.debugSelect(name: names[0])
        sidebar.focusList(at: 0)
        check(window.firstResponder === sidebar.debugListView, "the list takes keyboard focus", &ok)
        check(sidebar.debugRows.first?.debugShowsKeyboardFocus == true,
              "the row the keyboard is on shows a focus ring", &ok)

        if let down = keyEvent(125, in: window) { window.sendEvent(down) }
        check(sidebar.debugFocusedRowName == names[1], "Down moves to the next row", &ok)
        check(controller.debugCurrentName == names[0], "…without opening it: arrows browse", &ok)
        if let down = keyEvent(125, in: window) { window.sendEvent(down) }
        if let up = keyEvent(126, in: window) { window.sendEvent(up) }
        check(sidebar.debugFocusedRowName == names[1], "Up moves back", &ok)
        if let enter = keyEvent(36, in: window) { window.sendEvent(enter) }
        check(controller.debugCurrentName == names[1], "Return opens the row the keyboard is on", &ok)

        if let up = keyEvent(126, in: window) { window.sendEvent(up) }
        if let up = keyEvent(126, in: window) { window.sendEvent(up) }
        let inFilter = (window.firstResponder as? NSView)?.isDescendant(of: sidebar.filterField) == true
        check(inFilter, "Up from the first row returns to the filter field", &ok)

        sidebar.focusList()
        if let escape = keyEvent(53, in: window) { window.sendEvent(escape) }
        let stillInside = (window.firstResponder as? NSView)?.isDescendant(of: sidebar) == true
        check(!stillInside, "Escape hands the keyboard back to the editor", &ok)
        check(sidebar.debugListView.canBecomeKeyView, "the list is in the key view loop", &ok)
        check(!(sidebar.debugRows.first?.canBecomeKeyView ?? true),
              "rows are not separate key views - the list is one stop, not a hundred", &ok)
    }

    // MARK: 3. Hide, show, resize, remember

    private static func checkHideAndShow(_ controller: CodePreviewController, _ ok: inout Bool) {
        let root = controller.view
        let editor = controller.debugEditorCard
        let sidebar = controller.debugSidebar
        let inset = CodePreviewController.debugCardInset
        root.layoutSubtreeIfNeeded()
        let shownWidth = editor.frame.width
        check(editor.frame.minX >= sidebar.frame.maxX + inset - 0.5,
              "with the list showing, the editor starts after it", &ok)
        check(controller.debugSidebarButton.tint == .accent, "the toolbar button reads as on", &ok)

        controller.debugSidebarButton.performClick(nil)
        root.layoutSubtreeIfNeeded()
        check(sidebar.isHidden && controller.debugResizeHandle.isHidden, "the button hides the list", &ok)
        check(abs(editor.frame.minX - inset) < 0.5, "hidden, the editor starts at the page edge", &ok)
        check(abs(editor.frame.width - (root.bounds.width - 2 * inset)) < 0.5,
              "hidden, the editor takes the full width (got \(editor.frame.width) of \(root.bounds.width))", &ok)
        check(editor.frame.width > shownWidth + Prefs.minimumWidth,
              "hiding the list must actually give its width to the editor", &ok)
        check(controller.debugOutputPane.frame.minX == editor.frame.minX || controller.debugOutputPaneHeight == 0,
              "the output pane follows the editor's leading edge", &ok)
        check(!Prefs.isVisible(), "hiding is remembered", &ok)
        check(controller.debugSidebarButton.tint == nil, "the toolbar button reads as off", &ok)

        controller.debugSidebarButton.performClick(nil)
        root.layoutSubtreeIfNeeded()
        check(!sidebar.isHidden, "the button shows the list again", &ok)
        check(abs(editor.frame.width - shownWidth) < 0.5, "…and the editor gives the width back", &ok)
        check(Prefs.isVisible(), "showing is remembered", &ok)
    }

    private static func checkMenuToggle(_ controller: CodePreviewController, _ window: NSWindow,
                                        _ ok: inout Bool) {
        // The menu item's own handler, which `AppShellController` reaches
        // through the File menu's ⌘B.
        controller.toggleSidebarFromMenu()
        check(!controller.isSidebarVisible && controller.debugSidebar.isHidden, "\u{2318}B hides the list", &ok)
        controller.toggleSidebarFromMenu()
        check(controller.isSidebarVisible, "\u{2318}B shows it again", &ok)
        let inFilter = (window.firstResponder as? NSView)?.isDescendant(of: controller.debugSidebar.filterField) == true
        check(inFilter, "showing it from the keyboard puts the caret in the filter", &ok)
        controller.toggleSidebarFromMenu()
        let leftInside = (window.firstResponder as? NSView)?.isDescendant(of: controller.debugSidebar) == true
        check(!leftInside, "hiding it while it has the keyboard hands the keyboard to the editor", &ok)
        controller.toggleSidebarFromMenu()
    }

    private static func checkResize(_ controller: CodePreviewController, _ ok: inout Bool) {
        let handle = controller.debugResizeHandle
        let sidebar = controller.debugSidebar
        controller.view.layoutSubtreeIfNeeded()
        let before = sidebar.frame.width

        handle.debugDrag(by: 60)
        controller.view.layoutSubtreeIfNeeded()
        check(abs(sidebar.frame.width - (before + 60)) < 0.5,
              "dragging the handle widens the list (\(before) -> \(sidebar.frame.width))", &ok)
        check(abs(Prefs.width() - (before + 60)) < 0.5, "the dragged width is remembered", &ok)

        handle.debugDrag(by: 2000)
        check(controller.debugSidebarWidth == Prefs.maximumWidth, "the list cannot be dragged past its ceiling", &ok)
        handle.debugDrag(by: -2000)
        check(controller.debugSidebarWidth == Prefs.minimumWidth, "…or under its floor", &ok)
        handle.debugDoubleClick()
        check(controller.debugSidebarWidth == Prefs.defaultWidth, "double-clicking the handle resets the width", &ok)

        handle.debugDrag(by: 40)
        // Left at default + 40 for the persistence check below.
    }

    /// A second controller over the same store is the stand-in for a relaunch.
    private static func checkPersistenceAcrossControllers(_ store: CodePreviewStore, _ ok: inout Bool) {
        let rememberedWidth = Prefs.width()
        check(rememberedWidth == Prefs.defaultWidth + 40, "the fixture should leave a non-default width", &ok)

        func mount() -> (CodePreviewController, NSWindow) {
            let second = CodePreviewController(store: store)
            let window = OffScreenProbe.window(width: 1200, height: 760, styleMask: [.titled, .resizable])
            window.contentView = second.view
            second.view.layoutSubtreeIfNeeded()
            return (second, window)
        }

        let (shown, shownWindow) = mount()
        check(!shown.debugSidebar.isHidden, "a relaunch keeps the list showing", &ok)
        check(abs(shown.debugSidebar.frame.width - rememberedWidth) < 0.5,
              "a relaunch keeps the dragged width (\(shown.debugSidebar.frame.width))", &ok)
        shownWindow.contentView = nil

        Prefs.setVisible(false)
        let (hidden, hiddenWindow) = mount()
        let inset = CodePreviewController.debugCardInset
        check(hidden.debugSidebar.isHidden, "a relaunch keeps the list hidden", &ok)
        check(abs(hidden.debugEditorCard.frame.minX - inset) < 0.5, "…with the editor at full width", &ok)
        hiddenWindow.contentView = nil
        Prefs.setVisible(true)
    }

    // MARK: 4. Many files

    private static func checkManyFiles(_ controller: CodePreviewController, _ window: NSWindow,
                                       _ ok: inout Bool) {
        let sidebar = controller.debugSidebar
        let windowWidth = window.frame.width
        controller.view.layoutSubtreeIfNeeded()

        // The list scrolls rather than drawing rows over the status bar.
        let scroll = sidebar.debugScrollView
        let documentHeight = scroll.documentView?.frame.height ?? 0
        check(documentHeight > scroll.contentView.bounds.height,
              "a hundred rows should overflow the list, so it scrolls", &ok)
        check(sidebar.frame.maxY <= controller.view.bounds.maxY, "the list stays inside the page", &ok)

        // The tab strip overflows, and scrolls rather than widening anything.
        let strip = controller.debugTabScroll
        let stripDocument = strip.documentView?.frame.width ?? 0
        check(stripDocument > strip.frame.width * 2, "a hundred tabs should overflow the strip", &ok)
        // Overflowing is not enough: the strip has to scroll *instead of*
        // crushing the chips. A chip squeezed under its own fitting width is
        // an empty pill with no name - which is exactly what a too-strong
        // "fit the tabs" preference produced once.
        let crushed = controller.debugTabNames.compactMap { controller.debugChip(named: $0) }
            .filter { $0.frame.width < min($0.fittingSize.width, 240) - 1 }
        check(crushed.isEmpty, "no tab chip may be squeezed below its own width, \(crushed.count) were", &ok)
        check(abs(window.frame.width - windowWidth) < 0.5, "a hundred tabs must not widen the window", &ok)
        let plus = controller.debugPlusButton
        let plusInRoot = plus.convert(plus.bounds, to: controller.view)
        check(plusInRoot.maxX <= controller.view.bounds.maxX && plusInRoot.minX > strip.convert(strip.bounds, to: controller.view).minX,
              "the + button stays on screen after the strip", &ok)

        // Selecting the first and then the last snippet keeps each tab in view.
        let names = controller.debugTabNames
        for name in [names.first, names.last, names[names.count / 2]].compactMap({ $0 }) {
            controller.debugSelect(name: name)
            guard let chip = controller.debugChip(named: name) else { continue }
            let visible = strip.contentView.documentVisibleRect
            let chipFrame = chip.convert(chip.bounds, to: strip.documentView)
            check(visible.intersection(chipFrame).width >= chipFrame.width - 1,
                  "selecting \(name) scrolls its tab fully into view", &ok)
            if let row = sidebar.debugRows.first(where: { $0.entry.name == name }) {
                let rowFrame = row.convert(row.bounds, to: scroll.documentView)
                check(scroll.contentView.documentVisibleRect.intersection(rowFrame).height >= rowFrame.height - 1,
                      "selecting \(name) scrolls its row into view", &ok)
            }
        }

        // The wheel scrolls the strip sideways.
        controller.debugSelect(name: names[0])
        let startX = strip.contentView.bounds.origin.x
        strip.scrollHorizontally(by: 300)
        check(strip.contentView.bounds.origin.x > startX, "the tab strip scrolls sideways", &ok)
        strip.scrollHorizontally(by: -100_000)
        check(strip.contentView.bounds.origin.x == 0, "…and stops at its start", &ok)
    }

    private static func checkThemes(_ controller: CodePreviewController, _ ok: inout Bool) {
        let original = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(original) }
        for id in ["daylight", "helm-dark", "helm-light"] {
            guard let theme = HelmTheme.allThemes.first(where: { $0.id == id }) else {
                fail("no theme \(id)", &ok)
                continue
            }
            ThemeManager.shared.setTheme(theme)
            let palette = HelmPageSidebar.rowPalette(theme)
            guard let active = controller.debugSidebar.debugRows.first(where: \.debugIsActive) else {
                fail("\(id): no active row", &ok)
                continue
            }
            check(active.normalColor == palette.selectedFill,
                  "\(id): the active row wears the sidebar's selected wash", &ok)
            check(active.debugLabel.textColor == palette.selectedInk,
                  "\(id): the active row's name takes the corrected selected ink", &ok)
            let resting = controller.debugSidebar.debugRows.first { !$0.debugIsActive }
            check(resting?.debugLabel.textColor == palette.ink, "\(id): a resting row's name is page ink", &ok)
            // A theme change restyles every `HelmButton`, which resets its
            // alpha - the close controls must still be resting, not revealed.
            check(controller.debugSidebar.debugRows.allSatisfy { $0.debugCloseAlpha == 0 },
                  "\(id): a theme change must not reveal every row's close control", &ok)
            check(HelmContrast.ratio(palette.selectedInk, palette.selectedFill) >= 3,
                  "\(id): the active row's name stays legible on its wash", &ok)
        }
    }
}

#endif
