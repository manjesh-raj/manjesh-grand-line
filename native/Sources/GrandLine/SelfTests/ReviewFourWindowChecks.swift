// Grand Line - native macOS app.
//
// The window half of full review 4's UX ideas, measured in a real off-screen
// split shell after real layout passes. Run from `PageRedesignsSelfTest`,
// which already owns that shell, so this adds no window-backed suite
// (`NEEDS_SESSION` is at its ceiling). The pure halves are in
// `ReviewFourUXSelfTest`.

#if FM_SELFTESTS

import AppKit

enum ReviewFourWindowChecks {

    static func checkTasks(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL, _ ok: inout Bool) {
        checkTheTaskOpensInTheInspector(shell, window, &ok)
        checkTheWeeklyReviewWalks(shell, window, &ok)
        checkTheNotebookWrites(shell, window, &ok)
    }

    // MARK: UX-12 - write in one pane

    /// The Notebook opens in Write. Typing into the pane, with the keyboard
    /// in it, saves the page after a pause and not on the keystroke, and the
    /// save coming back leaves the caret where it was.
    private static func checkTheNotebookWrites(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        print("\n-- UX-12: the Notebook writes in one pane --")
        let store = shell.workspace.notebookStore
        let page = store.createPage(title: "Write check", content: "# Write check\nfirst line")
        let notebook = shell.workspace.notebook
        shell.workspace.navigator.show(.notebook)
        settle(shell, 0.3)
        notebook.openPage(id: page.id)
        settle(shell, 0.2)
        check(notebook.debugMode == .write && !notebook.debugWriteCardHidden && notebook.debugEditorCardHidden
                && notebook.debugWriteCard.window != nil && notebook.debugWriteCard.frame.width > 300,
              "UX-12: the Notebook opened in \(notebook.debugMode), Write card hidden \(notebook.debugWriteCardHidden)", &ok)
        let text = notebook.writeView.textView
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        text.insertText(" and more", replacementRange: text.selectedRange())
        check(store.page(id: page.id)?.content == "# Write check\nfirst line" && notebook.writeView.debugHasPendingEdit,
              "UX-12: the keystroke saved at once rather than after a pause", &ok)
        waitUntil(2) { store.page(id: page.id)?.content == "# Write check\nfirst line and more" }
        check(store.page(id: page.id)?.content == "# Write check\nfirst line and more",
              "UX-12: the pause did not save the page: \(store.page(id: page.id)?.content ?? "-")", &ok)
        settle(shell, 0.2)
        check(window.firstResponder === text && text.selectedRange().location == (text.string as NSString).length,
              "UX-12: the save took the caret to \(text.selectedRange().location)", &ok)
        shell.workspace.navigator.show(.homeCanvas)
        settle(shell, 0.2)
    }

    // MARK: UX-05 - a review you do

    /// Weekly review opens on its hero with a verdict and Start review. The
    /// walk asks about one task at a time: D through the card's own keyDown
    /// finishes the task, Skip moves on, and the end is one sentence that
    /// Save to Notebook keeps.
    private static func checkTheWeeklyReviewWalks(_ shell: MainSplitShellController, _ window: NSWindow,
                                                  _ ok: inout Bool) {
        print("\n-- UX-05: Weekly review walks the decisions --")
        let store = shell.workspace.shiftStore
        let shift = shell.workspace.shift
        shift.selectModuleTab(named: "Weekly review")
        settle(shell, 0.3)
        let band = shift.reviewBand
        let walk = shift.reviewWalkCard
        let queue = shift.reviewDecisions()
        guard queue.count >= 2 else { return fail("UX-05: the fixture leaves \(queue.count) decisions, want two or more", &ok) }
        check(!band.isHiddenOrHasHiddenAncestor && band.window != nil
                && band.debugHeadline == "\(queue.count) things to decide before next week."
                && !band.startButton.isHidden && walk.isHidden,
              "UX-05: the band reads \(band.debugHeadline), Start shown \(!band.startButton.isHidden), walk hidden \(walk.isHidden)", &ok)
        check(band.frame.minY < walk.frame.minY || walk.isHidden, "UX-05: the band is not at the top of the tab", &ok)

        band.startButton.performClick(nil)
        settle(shell, 0.2)
        check(!walk.isHidden && walk.debugCount == "1 of \(queue.count)" && walk.debugTitle == queue[0].title
                && window.firstResponder === walk && band.startButton.isHidden,
              "UX-05: Start review shows \(walk.debugCount) \(walk.debugTitle), keyboard on the card "
                + "\(window.firstResponder === walk)", &ok)
        check(abs(walk.debugFillFraction - 1 / CGFloat(queue.count)) < 0.02,
              "UX-05: the progress bar is \(walk.debugFillFraction) through", &ok)

        // D, through the card's own keyDown as a key press reaches it.
        let first = queue[0].id
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: "d",
                                        charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2) {
            window.sendEvent(event)
        }
        settle(shell, 0.2)
        check(!store.activeTasks.contains(where: { $0.id == first }) && walk.debugCount == "2 of \(queue.count)",
              "UX-05: D left \(walk.debugCount), first task still open \(store.activeTasks.contains(where: { $0.id == first }))", &ok)

        for _ in 1..<queue.count { walk.skipButton.performClick(nil) }
        settle(shell, 0.2)
        let nextWeek = store.weeklySummary().upcomingCount
        let expected = ShiftReviewWords.summary(done: 1, moved: 0, dropped: 0, skipped: queue.count - 1, nextWeek: nextWeek)
        check(walk.debugTitle == expected && !walk.saveButton.isHidden,
              "UX-05: the review ends on \(walk.debugTitle), want \(expected)", &ok)
        if let notebook = GrandLineServices.shared.notebookStore {
            let before = notebook.listPages().count
            walk.saveButton.performClick(nil)
            settle(shell, 0.2)
            check(notebook.listPages().count == before + 1 && !walk.saveButton.isEnabled,
                  "UX-05: Save to Notebook left the notebook at \(notebook.listPages().count) pages", &ok)
        } else {
            print("  SKIP UX-05: no Notebook is registered in this fixture, so Save to Notebook is not measured")
        }
        walk.closeButton.performClick(nil)
        settle(shell, 0.2)
        check(walk.isHidden && shift.reviewWalk == nil, "UX-05: Close left the review showing", &ok)
        shift.selectModuleTab(named: "Board")
        settle(shell, 0.2)
    }

    // MARK: UX-04 - the task beside the board

    /// A real click on a board card fills the inspector with that task and
    /// opens no sheet. Typing in the title and the notes saves after a
    /// pause, a tick and Return in Add an item save at once, and closing the
    /// pane lets go of the task.
    private static func checkTheTaskOpensInTheInspector(_ shell: MainSplitShellController, _ window: NSWindow,
                                                        _ ok: inout Bool) {
        print("\n-- UX-04: a task opens in the inspector, beside the board --")
        let store = shell.workspace.shiftStore
        let shift = shell.workspace.shift
        ReviewTourLab.seedDemoTasks(store)
        shell.workspace.navigator.show(.shift)
        shift.selectModuleTab(named: "Board")
        settle(shell)
        guard let task = store.activeTasks.first(where: { $0.title == "Rotate the CI deploy key" }),
              let card = shift.debugBoardView?.debugColumn(.backlog)?.debugCardViews.first(where: { $0.taskID == task.id })
        else { return fail("UX-04: the fixture's deploy-key card is not on the board", &ok) }
        check(shell.debugInspector.hostedContentView !== shift.taskInspector,
              "UX-04: the inspector shows the task before any click", &ok)

        // The click, through the window as a real one arrives.
        let centre = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
        window.sendEvent(mouseEvent(.leftMouseDown, at: centre, in: window))
        window.sendEvent(mouseEvent(.leftMouseUp, at: centre, in: window))
        settle(shell, 0.5)
        let inspector = shift.taskInspector
        check(shift.inspectedTaskID == task.id && shell.debugInspectorSource === shift
                && !shell.debugInspectorIsCollapsed && shell.debugInspector.hostedContentView === inspector
                && shell.debugInspector.debugTitle == TaskInspectorWords.title,
              "UX-04: a click on the card opened \(shift.inspectedTaskID ?? "nothing"), inspector collapsed "
                + "\(shell.debugInspectorIsCollapsed), titled \(shell.debugInspector.debugTitle)", &ok)
        check(shift.presentedViewControllers?.isEmpty ?? true, "UX-04: the click still opened the task sheet", &ok)
        check(card.isInspected, "UX-04: the card whose task shows is not marked", &ok)
        check(inspector.titleField.stringValue == task.title
                && (inspector.dueChip.text.hasPrefix("Overdue") || inspector.dueChip.text.hasPrefix("Today")),
              "UX-04: the inspector reads \(inspector.titleField.stringValue) / \(inspector.dueChip.text)", &ok)
        check(inspector.projectChip.text == "Infra hardening" && inspector.priorityChip.text == "High",
              "UX-04: the chips read \(inspector.projectChip.text) / \(inspector.priorityChip.text)", &ok)
        check(inspector.debugChecklistKicker == "CHECKLIST \u{00B7} 1 OF 3" && inspector.debugChecklistRows.count == 3
                && inspector.debugChecklistRows.first?.debugIsStruck == true,
              "UX-04: the checklist reads \(inspector.debugChecklistKicker) with \(inspector.debugChecklistRows.count) rows", &ok)
        check(inspector.notesView.string == "Old key expires on the 30th.",
              "UX-04: the notes read \(inspector.notesView.string)", &ok)
        // The board stays live: the board's own cards still take clicks.
        check(window.attachedSheet == nil, "UX-04: a sheet covers the board", &ok)

        // Typing in the title saves after a pause, without Return.
        window.makeFirstResponder(inspector.titleField)
        if let editor = inspector.titleField.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
            editor.insertText(" today", replacementRange: editor.selectedRange())
        }
        check(inspector.debugHasPendingSave && store.activeTasks.first(where: { $0.id == task.id })?.title == task.title,
              "UX-04: the title saved on the keystroke rather than after a pause", &ok)
        waitUntil(1.5) { store.activeTasks.first(where: { $0.id == task.id })?.title == "Rotate the CI deploy key today" }
        check(store.activeTasks.first(where: { $0.id == task.id })?.title == "Rotate the CI deploy key today",
              "UX-04: a typed title was not saved: \(store.activeTasks.first(where: { $0.id == task.id })?.title ?? "-")", &ok)
        check(inspector.titleField.currentEditor() != nil,
              "UX-04: the save took the caret out of the title", &ok)

        // The notes, the same way.
        window.makeFirstResponder(inspector.notesView.textView)
        let notes = inspector.notesView.textView
        notes.setSelectedRange(NSRange(location: notes.string.count, length: 0))
        notes.insertText(" Ask Priya.", replacementRange: notes.selectedRange())
        waitUntil(1.5) { store.activeTasks.first(where: { $0.id == task.id })?.description.hasSuffix("Ask Priya.") == true }
        check(store.activeTasks.first(where: { $0.id == task.id })?.description == "Old key expires on the 30th. Ask Priya.",
              "UX-04: typed notes were not saved", &ok)

        // A tick saves at once.
        inspector.debugChecklistRows.dropFirst().first?.check.performClick(nil)
        settle(shell, 0.2)
        check(store.activeTasks.first(where: { $0.id == task.id })?.subtasks.filter(\.done).count == 2
                && inspector.debugChecklistKicker == "CHECKLIST \u{00B7} 2 OF 3",
              "UX-04: ticking an item did not save (kicker \(inspector.debugChecklistKicker))", &ok)

        // Return in Add an item, as the field editor sends it.
        window.makeFirstResponder(inspector.addItemField)
        if let editor = inspector.addItemField.currentEditor() as? NSTextView {
            editor.insertText("Tell the team", replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        settle(shell, 0.2)
        let items = store.activeTasks.first(where: { $0.id == task.id })?.subtasks.map(\.title) ?? []
        check(items.last == "Tell the team" && inspector.addItemField.stringValue.isEmpty
                && inspector.debugChecklistRows.count == 4,
              "UX-04: Return in Add an item left the checklist at \(items)", &ok)

        // Closing the pane lets go of the task, and the card loses its mark.
        shell.debugInspector.debugCloseButton.performClick(nil)
        settle(shell, 0.5)
        check(shift.inspectedTaskID == nil && !card.isInspected && shift.inspectorContent == nil,
              "UX-04: closing the inspector kept \(shift.inspectedTaskID ?? "nothing") selected", &ok)

        // Weekly review has no task details to show.
        shift.inspectTask(id: task.id)
        settle(shell, 0.3)
        shift.selectModuleTab(named: "Weekly review")
        settle(shell, 0.3)
        check(shift.inspectorContent == nil, "UX-04: Weekly review still offers the task's details", &ok)
        shift.selectModuleTab(named: "Board")
        shell.debugInspector.debugCloseButton.performClick(nil)
        settle(shell, 0.4)
    }

    // MARK: Helpers

    private static func settle(_ shell: WorkspaceShellController, _ seconds: TimeInterval = 0.05) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        shell.view.layoutSubtreeIfNeeded()
    }

    private static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

#endif
