// Grand Line - native macOS app.
//
// The window-backed half of the Code page's sidebar-layout presentation (the
// captain's reviewed Workbench concept): the real `CodePreviewController`,
// adopted into that layout, over a scratch store, with the real Monaco page
// behind it and real sandboxed runs of harmless shell fixtures.
//
// What it locks down, one case per piece of the change:
//
//   1. Cards: the snippet list, Quick actions, the toolbar card, the editor
//      card with its tab row, title row and code, each where the concept puts
//      it, and the page's old toolbar row gone.
//   2. The toolbar card: every page tool is in it, labelled, and the window
//      toolbar carries none of them (`drillHeaderActions` is empty); Run
//      script is the primary button; Undo reaches Monaco; the status line.
//   3. The Run results dock: a real failing run opens on its Errors tab with
//      true counts, the surface is dark in light themes too, Clear hides it.
//   4. The right column: real values, the real syntax check, and the column
//      hiding at a narrow window.
//   5. The status bar: position, language, encoding, indentation, sync.
//   6. Editor details: the current-line bar Monaco really draws, middle-
//      truncated file tabs, and the unsaved dot from the page's own message.
//
// And the rule the whole layout is built around: none of it resizes the
// window, with forty tabs open at the concept's narrow width.
//
// Window-backed, so it is in `run-all-tests.sh`'s NEEDS_SESSION list. It
// raises no modal and never touches the general pasteboard (Copy output is
// asserted through the text it would copy).
//
// `FM_RUN_CODE_PREVIEW_WORKBENCH_VIEW_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CodePreviewWorkbenchViewSelfTest {

    static func run() -> Bool {
        var ok = true
        guard CodePreviewAssets.isAvailable else {
            fail("no Monaco bundle - run native/Scripts/build-monaco-web.sh", &ok)
            return false
        }
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        setTheme("dusk")

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-workbench-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let store = CodePreviewStore(root: scratch)
        _ = store.create(name: "echo-hello.sh", content: "#!/bin/bash\n\necho \"Hello\"\necho \"Manjesh\"\n")
        _ = store.create(name: "failing-check.sh",
                         content: "#!/bin/bash\necho \"checking\"\necho \"error: missing tag\" >&2\nexit 3\n")
        _ = store.create(name: "543385233843-eu8u0k3f2lljlt8xq0zk-ca6bpjld.txt", content: "a hash-named file\n")

        let controller = CodePreviewController(store: store)
        let window = OffScreenProbe.window(width: 1272, height: 900, styleMask: [.titled, .resizable])
        window.contentView = controller.view
        NSApp.setActivationPolicy(.accessory)
        window.orderFront(nil)
        controller.adoptSidebarLayout()
        window.displayIfNeeded()

        guard waitFor(timeout: 30, until: { controller.debugWebView.isReady && !controller.debugTabNames.isEmpty }) else {
            fail("Monaco never reported ready", &ok)
            return false
        }
        CodeToolInventory.shared.probeEverything()
        controller.debugRefreshRunControls()
        controller.debugSelect(name: "echo-hello.sh")
        settle(controller)

        guard let workbench = controller.debugWorkbench else {
            fail("adopting the sidebar layout built no workbench", &ok)
            return false
        }
        let frameBefore = window.frame

        checkCards(controller, workbench, &ok)
        checkToolbarCard(controller, workbench, &ok)
        checkRunResultsDock(controller, workbench, &ok)
        checkInspector(controller, workbench, window, &ok)
        checkStatusBar(controller, &ok)
        checkEditorDetails(controller, &ok)
        checkQuickActionsAndColumns(controller, workbench, store, scratch, &ok)
        checkThemes(controller, &ok)
        checkManyTabsDoNotResizeTheWindow(controller, window, frameBefore, &ok)

        window.orderOut(nil)
        print(ok ? "CodePreviewWorkbenchViewSelfTest: OK" : "CodePreviewWorkbenchViewSelfTest: FAILURES")
        return ok
    }

    // MARK: Helpers

    private static func setTheme(_ id: String) {
        if let theme = HelmTheme.theme(id: id) { ThemeManager.shared.setTheme(theme) }
    }

    private static func waitFor(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private static func settle(_ controller: CodePreviewController, _ seconds: TimeInterval = 0.3) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        controller.view.layoutSubtreeIfNeeded()
    }

    private static func frame(_ view: NSView, in controller: CodePreviewController) -> NSRect {
        view.convert(view.bounds, to: controller.view)
    }

    private static func runAndWait(_ controller: CodePreviewController) {
        _ = waitFor(timeout: 15, until: { controller.debugRunButtonEnabled })
        controller.debugRun()
        _ = waitFor(timeout: 40, until: { !controller.debugIsRunning })
        settle(controller)
    }

    // MARK: 1. Cards

    private static func checkCards(_ controller: CodePreviewController, _ workbench: CodePreviewWorkbenchView,
                                   _ ok: inout Bool) {
        let parts = workbench.parts
        check(controller.debugSidebar.isDescendant(of: workbench.snippetCard),
              "the snippet list should sit in its own card", &ok)
        check(controller.debugSyncFooter.isDescendant(of: workbench.snippetCard),
              "the sync line should be at the foot of the snippet card", &ok)
        check(controller.debugSidebar.debugHeaderText == "Snippets" && controller.debugSidebar.debugCountText == "3 items",
              "the snippet card should read Snippets / 3 items, got \(controller.debugSidebar.debugHeaderText) / \(controller.debugSidebar.debugCountText)", &ok)
        check(controller.debugQuickActions.allSatisfy { $0.isDescendant(of: workbench.quickActionsCard) },
              "Quick actions should be their own card", &ok)
        check(controller.debugTabScroll.isDescendant(of: workbench.editorFrame),
              "the tabs should be inside the editor card", &ok)
        check(controller.debugTitleRow.isDescendant(of: workbench.editorFrame)
                && controller.debugEditorCard.isDescendant(of: workbench.editorFrame),
              "the title row and the code should be inside the editor card", &ok)
        check(!controller.debugPageActionViews.contains { $0.isDescendant(of: controller.view) && !$0.isDescendant(of: workbench) },
              "a page tool is still in the old page toolbar row", &ok)

        // The concept's order, top to bottom and left to right.
        let snippets = frame(workbench.snippetCard, in: controller)
        let quick = frame(workbench.quickActionsCard, in: controller)
        let toolbar = frame(workbench.toolbarCard, in: controller)
        let editor = frame(workbench.editorFrame, in: controller)
        let status = frame(parts.statusBar, in: controller)
        let gap = CodePreviewWorkbenchMetrics.gap
        check(abs(snippets.width - CodePreviewWorkbenchMetrics.snippetColumnWidth) < 1,
              "the snippet card should be the concept's \(CodePreviewWorkbenchMetrics.snippetColumnWidth)pt, got \(snippets.width)", &ok)
        check(quick.maxY <= snippets.minY + 0.5 || quick.minY >= snippets.maxY - 0.5,
              "Quick actions should sit under the snippet card, got \(quick) and \(snippets)", &ok)
        check(abs(toolbar.minX - (snippets.maxX + gap)) < 1,
              "the toolbar card should start one gap after the snippet card, got \(toolbar.minX) vs \(snippets.maxX)", &ok)
        check(abs(editor.minX - toolbar.minX) < 0.5,
              "the editor card should line up with the toolbar card, got \(editor.minX) vs \(toolbar.minX)", &ok)
        check(abs(toolbar.height - CodePreviewWorkbenchMetrics.toolbarHeight) < 0.5,
              "the toolbar card should be \(CodePreviewWorkbenchMetrics.toolbarHeight)pt tall, got \(toolbar.height)", &ok)
        check(abs(status.width - controller.view.bounds.width) < 0.5 && status.minY < 1,
              "the status bar should run the page's full width at its foot, got \(status)", &ok)
        check(controller.debugTitleRow.debugName == "echo-hello.sh",
              "the title row should name the open snippet, got \(controller.debugTitleRow.debugName)", &ok)
        check(controller.debugTitleRow.debugFolder.hasSuffix("/") && !controller.debugTitleRow.debugFolder.isEmpty,
              "the title row should name the snippet's folder, got \(controller.debugTitleRow.debugFolder)", &ok)
        check(CodePreviewController.folderDisplay("/Users/me/Library/Application Support/Grand Line/GrandLineDocs/code-snippets")
                == "\u{2026}/GrandLineDocs/code-snippets/",
              "a deep folder should read as its last two folders", &ok)
    }

    // MARK: 2. The toolbar card

    private static func checkToolbarCard(_ controller: CodePreviewController, _ workbench: CodePreviewWorkbenchView,
                                         _ ok: inout Bool) {
        check(controller.drillHeaderActions.isEmpty,
              "the window toolbar should carry none of the page's tools in the sidebar layout", &ok)
        let leading = workbench.debugToolbarLeadingViews
        for (name, view) in [("language picker", controller.debugLanguagePicker as NSView),
                             ("Format", controller.debugFormatButton), ("Undo", controller.debugUndoButton),
                             ("Redo", controller.debugRedoButton), ("text size", controller.debugZoomStepper),
                             ("snippet list toggle", controller.debugSidebarButton)] {
            check(leading.contains { $0 === view }, "the toolbar card has no \(name)", &ok)
        }
        check(workbench.debugToolbarTrailingViews.contains { $0 === controller.debugRunButton },
              "Run script should be at the toolbar card's trailing end", &ok)
        let run = controller.debugRunButton
        check(run.variant == .primary && run.title == "Run script",
              "Run should be the primary Run script button, got \(run.variant) \(run.title)", &ok)
        for button in [controller.debugFormatButton, controller.debugUndoButton, controller.debugRedoButton,
                       controller.debugSidebarButton, controller.debugExpandButton, run] {
            let label = (button.accessibilityLabel() ?? "").isEmpty ? (button.toolTip ?? "") : (button.accessibilityLabel() ?? "")
            check(!label.isEmpty, "a toolbar control has no VoiceOver label or tooltip", &ok)
            // Whether a button takes Tab focus is the captain's Full
            // Keyboard Access setting; what the page controls is that it
            // does not refuse it and that it has an action to perform.
            check(!button.refusesFirstResponder && button.action != nil && button.target != nil,
                  "\(label) refuses keyboard focus or has no action", &ok)
        }
        // What the old cluster reached and the card does not show is in the
        // title row's More menu, by name.
        let more = controller.debugEditorMoreMenu.debugTitles
        for item in ["Find in snippet (\u{2318}F)", "Copy snippet", "Clear snippet", "Runners and formatters\u{2026}"] {
            check(more.contains(item), "the More menu has no \(item), got \(more)", &ok)
        }
        check(more.contains { $0.contains("word wrap") }, "the More menu has no word-wrap toggle", &ok)
        check(controller.debugRunStatus.debugText == "Ready to run",
              "a runnable shell snippet should read Ready to run, got \(controller.debugRunStatus.debugText)", &ok)

        // Undo goes through the real button's own action to Monaco's command.
        controller.debugWebView.debugResetCalls()
        controller.debugUndoButton.isEnabled = true
        controller.debugUndoButton.performClick(nil)
        controller.debugRedoButton.isEnabled = true
        controller.debugRedoButton.performClick(nil)
        let calls = controller.debugWebView.debugCalls.map(\.name)
        check(calls.contains("undo") && calls.contains("redo"),
              "Undo and Redo should reach the editor, got \(calls)", &ok)
        settle(controller)
    }

    // MARK: 3. The dock

    private static func checkRunResultsDock(_ controller: CodePreviewController, _ workbench: CodePreviewWorkbenchView,
                                            _ ok: inout Bool) {
        let dock = controller.debugDock
        check(dock.isHidden && !workbench.debugCodeAboveDock,
              "before a run the dock should be hidden and the code should reach the card's foot", &ok)
        let codeBefore = frame(controller.debugEditorCard, in: controller).height

        controller.debugSelect(name: "failing-check.sh")
        settle(controller)
        runAndWait(controller)
        check(!dock.isHidden && workbench.debugCodeAboveDock, "a finished run should show the dock", &ok)
        check(dock.debugChipText == "FAILED \u{00B7} EXIT 3", "the chip should read FAILED · EXIT 3, got \(dock.debugChipText)", &ok)
        check(dock.debugElapsedText.hasSuffix("elapsed"), "the dock should state the elapsed time, got \(dock.debugElapsedText)", &ok)
        check(dock.debugNoteText.contains("temporary folder, no network"),
              "the note should state the sandbox the run had, got \(dock.debugNoteText)", &ok)
        check(dock.debugTab(.standardError)?.debugIsSelected == true,
              "a failed run that wrote to stderr should open on its Errors tab", &ok)
        check(dock.debugTab(.standardOutput)?.debugCountText == "1 line" && dock.debugTab(.standardError)?.debugCountText == "1",
              "the tab counts should be the real line counts, got \(dock.debugTab(.standardOutput)?.debugCountText ?? "") / \(dock.debugTab(.standardError)?.debugCountText ?? "")", &ok)
        check(dock.debugBodyText == "error: missing tag\n", "the Errors tab should show stderr only, got \(String(reflecting: dock.debugBodyText))", &ok)
        check(dock.visibleText == "error: missing tag\n", "Copy output should copy the tab on screen", &ok)
        dock.debugTab(.standardOutput)?.debugClick()
        check(dock.debugBodyText == "checking\n" && dock.visibleText == "checking\n",
              "the Standard output tab should show stdout only, got \(String(reflecting: dock.debugBodyText))", &ok)
        check(controller.debugRunStatus.debugText == "Last run failed \u{00B7} exit 3",
              "the toolbar status should state the last result, got \(controller.debugRunStatus.debugText)", &ok)
        let codeWithDock = frame(controller.debugEditorCard, in: controller).height
        check(codeBefore - codeWithDock > CodeRunResultsDock.preferredHeight - 2,
              "the dock should take its height from the code, lost \(codeBefore - codeWithDock)", &ok)

        // The terminal surface is dark in a light theme too.
        setTheme("daylight")
        settle(controller)
        if let ground = dock.debugBodyGround {
            check(HelmContrast.relativeLuminance(HelmContrast.components(ground)) <= CodeRunResultsModel.terminalLuminanceCeiling + 0.005,
                  "the output surface should stay dark under Daylight, got \(ground)", &ok)
            if let ink = dock.debugBodyInk {
                check(HelmContrast.ratio(ink, ground) >= 4.5, "the output text should clear 4.5:1 on its surface", &ok)
            }
        }
        setTheme("dusk")
        settle(controller)

        // Clear, through the dock's own button.
        dock.debugClearButton.performClick(nil)
        settle(controller)
        check(dock.isHidden && !workbench.debugCodeAboveDock,
              "Clear should hide the dock and give the code back its height", &ok)
        check(abs(frame(controller.debugEditorCard, in: controller).height - codeBefore) < 1,
              "after Clear the code should be its pre-run height", &ok)

        // A passing run opens on Standard output.
        controller.debugSelect(name: "echo-hello.sh")
        settle(controller)
        runAndWait(controller)
        check(dock.debugChipText == "SUCCEEDED \u{00B7} EXIT 0" && dock.debugTab(.standardOutput)?.debugIsSelected == true
                && dock.debugBodyText == "Hello\nManjesh\n" && dock.debugTab(.standardOutput)?.debugCountText == "2 lines",
              "a passing run should read SUCCEEDED · EXIT 0 on Standard output with 2 lines, got \(dock.debugChipText) \(String(reflecting: dock.debugBodyText))", &ok)
        controller.debugClearOutput()
        settle(controller)
    }

    // MARK: 4. The right column

    private static func checkInspector(_ controller: CodePreviewController, _ workbench: CodePreviewWorkbenchView,
                                       _ window: NSWindow, _ ok: inout Bool) {
        check(workbench.inspectorShown && !workbench.inspectorScroll.isHidden,
              "the right column should show at a wide window", &ok)
        let cards = controller.debugInspectorCards
        check(cards.map(\.debugTitle) == ["Run configuration", "Script checks", "Editor preferences"],
              "the three cards should be in the concept's order, got \(cards.map(\.debugTitle))", &ok)
        let config = cards[0].debugRowTexts
        for expected in ["Execution: Sandboxed process", "Network: Blocked", "Working directory: Temporary",
                         "Time limit: \(Int(CodeRunner.wallClock)) s"] {
            check(config.contains(expected), "Run configuration should say \(expected), got \(config)", &ok)
        }
        check(config.contains { $0.hasPrefix("Language: Shell \u{00B7} ") },
              "Run configuration should name the interpreter, got \(config)", &ok)

        // The real syntax check, both ways.
        _ = waitFor(timeout: 15, until: { cards[1].debugRowTexts.contains { $0.contains("No syntax errors") } })
        var checks = cards[1].debugRowTexts
        check(checks.contains { $0.hasPrefix("Passed: Interpreter detected: ") },
              "Script checks should report the interpreter, got \(checks)", &ok)
        check(checks.contains { $0.hasPrefix("Passed: No syntax errors (") },
              "a well-formed snippet should pass its syntax check, got \(checks)", &ok)
        check(checks.contains("Note: 2 code lines \u{00B7} 1 blank line \u{00B7} 1 comment"),
              "the counts should be the snippet's own, got \(checks)", &ok)
        check(cards[1].debugTally == "2/2", "both checks passed, so the tally should be 2/2, got \(cards[1].debugTally)", &ok)
        controller.debugSimulateEdit(name: "echo-hello.sh", content: "if true; then\necho broken\n")
        _ = waitFor(timeout: 15, until: { cards[1].debugRowTexts.contains { $0.hasPrefix("Failed: Syntax error") } })
        checks = cards[1].debugRowTexts
        check(checks.contains { $0.hasPrefix("Failed: Syntax error") } && cards[1].debugTally == "1/2",
              "a broken snippet should fail its syntax check, got \(checks) \(cards[1].debugTally)", &ok)
        controller.debugSimulateEdit(name: "echo-hello.sh", content: "#!/bin/bash\n\necho \"Hello\"\necho \"Manjesh\"\n")
        _ = waitFor(timeout: 15, until: { cards[1].debugTally == "2/2" })

        _ = waitFor(timeout: 5, until: { cards[2].debugRowTexts.contains { $0.hasPrefix("Font: ") && $0.contains("\u{00B7}") } })
        let prefs = cards[2].debugRowTexts
        check(prefs.contains("Line numbers: On") && prefs.contains("Word wrap: Off"),
              "Editor preferences should read Monaco's own state, got \(prefs)", &ok)
        check(prefs.contains { $0.hasPrefix("Font: ") && $0.hasSuffix("\(Int(FontSizeManager.shared.size)) pt") && $0.contains("\u{00B7}") },
              "the font row should name Monaco's resolved family and the shared size, got \(prefs)", &ok)

        // The breakpoint.
        let wide = window.frame
        var narrow = wide
        narrow.size.width = 1000
        window.setFrame(narrow, display: true)
        settle(controller)
        check(!workbench.inspectorShown && workbench.inspectorScroll.isHidden,
              "the right column should hide below the breakpoint", &ok)
        check(abs(frame(workbench.editorFrame, in: controller).maxX - frame(workbench.toolbarCard, in: controller).maxX) < 0.5,
              "with the column hidden the editor card should take its width", &ok)
        check(abs(workbench.snippetCard.frame.width - CodePreviewWorkbenchMetrics.narrowSnippetColumnWidth) < 1,
              "the snippet column should narrow with it, got \(workbench.snippetCard.frame.width)", &ok)
        window.setFrame(wide, display: true)
        settle(controller)
        check(workbench.inspectorShown, "the right column should come back at a wide window", &ok)
    }

    // MARK: 5. The status bar

    private static func checkStatusBar(_ controller: CodePreviewController, _ ok: inout Bool) {
        _ = waitFor(timeout: 5, until: { !controller.debugIndentText.isEmpty })
        let leading = controller.debugStatusLeadingTexts
        check(leading.count >= 4 && leading[0].hasPrefix("Ln ") && leading[1] == "Shell" && leading[2] == "UTF-8"
                && leading[3] == "Spaces: 2",
              "the status bar should lead with Ln/Col, language, encoding and indentation, got \(leading)", &ok)
        check(controller.debugStatusTrailingTexts == ["saved on this machine"],
              "the sync state should trail alone, got \(controller.debugStatusTrailingTexts)", &ok)
        check(CodePreviewController.indentationText(CodePreviewCursor(line: 1, column: 1, selected: 0, lines: 1,
                                                                      tabSize: 4, insertSpaces: false)) == "Tab size: 4",
              "a tab-indented model should read Tab size", &ok)
    }

    // MARK: 6. Editor details

    private static func checkEditorDetails(_ controller: CodePreviewController, _ ok: inout Bool) {
        // The bar as Monaco draws it, read back from the page.
        var reading: [String: Any]?
        controller.debugWebView.call("renderNow")
        controller.debugWebView.call("readCurrentLineBar") { result in
            if case .success(let body) = result { reading = body }
        }
        _ = waitFor(timeout: 5, until: { reading != nil })
        let shadow = (reading?["boxShadow"] as? String) ?? ""
        let accent = HelmContrast.components(HelmTheme.nsColor(ThemeManager.shared.theme.accentHex))
        let rgb = "rgb(\(Int((accent.0 * 255).rounded())), \(Int((accent.1 * 255).rounded())), \(Int((accent.2 * 255).rounded())))"
        check(reading?["present"] as? Bool == true, "Monaco drew no current-line overlay, got \(String(describing: reading))", &ok)
        check(shadow.contains(rgb) && shadow.contains("inset"),
              "the current line should carry an inset accent bar \(rgb), got \(shadow)", &ok)

        // A long name truncates in the middle.
        if let chip = controller.debugChip(named: "543385233843-eu8u0k3f2lljlt8xq0zk-ca6bpjld.txt") {
            check(chip.debugLabelLineBreakMode == .byTruncatingMiddle && chip.frame.width <= 200.5,
                  "a file tab should truncate its name in the middle under a 200pt cap, got \(chip.frame.width)", &ok)
        } else {
            fail("the hash-named snippet has no tab", &ok)
        }

        // The unsaved dot, from the page's own message, through the web
        // view's real message handler, on the tab and on the row.
        guard let key = controller.debugCurrentSnippetKey, let name = controller.debugCurrentName,
              let chip = controller.debugChip(named: name) else {
            fail("no open snippet to mark unsaved", &ok)
            return
        }
        controller.debugWebView.debugHandle(message: ["type": "pending", "id": key])
        settle(controller, 0.05)
        let row = controller.debugSidebar.debugRows.first { $0.entry.key == key }
        check(controller.debugHasPendingEdit(name: name) && chip.debugShowsUnsavedDot && row?.debugUnsavedDotVisible == true,
              "a pending edit should mark its tab and its row unsaved", &ok)
        controller.debugWebView.debugHandle(message: ["type": "change", "id": key,
                                                      "content": "#!/bin/bash\n\necho \"Hello\"\necho \"Manjesh\"\n"])
        settle(controller, 0.05)
        let rowAfter = controller.debugSidebar.debugRows.first { $0.entry.key == key }
        check(!chip.debugShowsUnsavedDot && rowAfter?.debugUnsavedDotVisible == false,
              "once the edit is written the unsaved dot should go", &ok)
    }

    // MARK: Quick actions, ⌘B and Expand

    private static func checkQuickActionsAndColumns(_ controller: CodePreviewController, _ workbench: CodePreviewWorkbenchView,
                                                    _ store: CodePreviewStore, _ scratch: URL, _ ok: inout Bool) {
        let before = controller.debugTabNames.count
        _ = controller.debugQuickActions[0].performPrimaryAction()
        settle(controller)
        check(controller.debugTabNames.count == before + 1, "New snippet should open a tab", &ok)
        check(controller.debugQuickActions[0].debugShortcut == "\u{2318}N", "New snippet should show its ⌘N", &ok)
        controller.debugCloseCurrent()

        // Outside the store's own folder, as a real import would be.
        let elsewhere = scratch.deletingLastPathComponent().appendingPathComponent("import-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let fixture = elsewhere.appendingPathComponent("imported-fixture.py")
        try? "print('fixture')\n".write(to: fixture, atomically: true, encoding: .utf8)
        controller.debugImport([fixture])
        settle(controller)
        check(controller.debugCurrentName == "imported-fixture.py", "Import should open the file as a snippet", &ok)

        controller.toggleSidebarFromMenu()
        settle(controller)
        check(!workbench.snippetColumnShown && workbench.snippetCard.isHidden,
              "⌘B should hide the snippet card", &ok)
        check(abs(workbench.toolbarCard.frame.minX - CodePreviewWorkbenchMetrics.gap) < 0.5,
              "with the list hidden the toolbar card should start at the page edge", &ok)
        controller.toggleSidebarFromMenu()
        settle(controller)
        check(workbench.snippetColumnShown, "⌘B again should bring the snippet card back", &ok)

        controller.debugExpandButton.performClick(nil)
        settle(controller)
        check(!workbench.snippetColumnShown && !workbench.inspectorShown,
              "Expand should hide both side columns", &ok)
        controller.debugExpandButton.performClick(nil)
        settle(controller)
        check(workbench.snippetColumnShown && workbench.inspectorShown, "Expand again should restore them", &ok)
        controller.debugSelect(name: "echo-hello.sh")
        settle(controller)
    }

    // MARK: Themes

    private static func checkThemes(_ controller: CodePreviewController, _ ok: inout Bool) {
        for id in ["dusk", "daylight"] {
            setTheme(id)
            settle(controller, 0.2)
            let theme = ThemeManager.shared.theme
            let expected: NSAppearance.Name = theme.mode == .dark ? .darkAqua : .aqua
            check(controller.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                  "\(id): the page's appearance should follow the theme", &ok)
        }
        setTheme("dusk")
        settle(controller, 0.2)
    }

    // MARK: The window

    private static func checkManyTabsDoNotResizeTheWindow(_ controller: CodePreviewController, _ window: NSWindow,
                                                          _ frameBefore: NSRect, _ ok: inout Bool) {
        var narrow = frameBefore
        narrow.size.width = 860
        window.setFrame(narrow, display: true)
        settle(controller)
        for index in 1...40 {
            controller.debugNewSnippet(named: "deploy-pipeline-stage-\(index)-runbook-with-a-long-name.sh",
                                       content: "echo \(index)\n")
        }
        settle(controller)
        check(abs(window.frame.width - 860) < 0.5,
              "forty tabs at a narrow window should not widen it, got \(window.frame.width)", &ok)
        let strip = controller.debugTabScroll
        check(strip.frame.width < (strip.documentView?.frame.width ?? 0),
              "with forty tabs the tab strip should scroll rather than grow", &ok)
        window.setFrame(frameBefore, display: true)
        settle(controller)
        check(window.frame == frameBefore, "the window should keep the frame it was given", &ok)
    }
}

#endif
