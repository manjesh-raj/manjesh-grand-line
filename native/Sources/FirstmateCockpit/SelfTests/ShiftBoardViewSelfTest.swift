// Manjesh Grand Line - native macOS app.
//
// The Kanban board's view half (`fm/grandline-tasks-kanban-devops-split`):
// a real `ShiftController` mounted in a real window, over a scratch store.
//
// **Why this is window-backed and separate from `ShiftBoardSelfTest`.**
// Everything here needs an `NSWindow`: `beginDraggingSession` needs a window
// to drag in, an `NSEvent` needs a `windowNumber` to route by, and a card
// that never receives `mouseDown` at all cannot be seen from any value check.
// The pure column/palette logic runs in CI in its sibling suite; this one
// sits in `run-all-tests.sh`'s `NEEDS_SESSION` list beside its peers.
//
// **The one thing this exists to prove.** The board's cards wrap
// `HelmAccentRow`, which carries its own `NSClickGestureRecognizer` - so
// "does a press on a card actually reach the card's own `mouseDown`, or does
// the row swallow it?" is a real question about AppKit, not a formality. It
// is answered here by synthesizing a real press and a real drag past the
// threshold and reading back whether a drag session genuinely started.
//
// Run with `FM_RUN_SHIFT_BOARD_VIEW_TESTS=1 .build/debug/FirstmateCockpit`.

#if FM_SELFTESTS

import AppKit

enum ShiftBoardViewSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        withScratchStore { store in
            // Three tasks, one per column, plus one cancelled task that must
            // stay off the board entirely.
            let backlog = seed(store, title: "Draft the runbook", status: .todo)
            let running = seed(store, title: "Rotate the prod key", status: .inProgress)
            let cancelled = seed(store, title: "Abandoned idea", status: .cancelled)
            let finished = seed(store, title: "Ship the split", status: .todo)
            store.setTaskCompleted(id: finished, completed: true)

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }

            guard let board = controller.debugBoardView else {
                failures.append("the Tasks page has no board view")
                return
            }

            // MARK: The three columns hold the right cards

            func ids(_ column: ShiftBoardColumn) -> [String] {
                board.debugColumn(column)?.debugCardViews.map(\.taskID) ?? []
            }

            check(ids(.backlog) == [backlog],
                  "Backlog should hold exactly the todo task, got \(ids(.backlog))")
            check(ids(.inProgress) == [running],
                  "In Progress should hold exactly the in-progress task, got \(ids(.inProgress))")
            check(ids(.done) == [finished],
                  "Done should hold exactly the just-completed task, got \(ids(.done))")
            check(!ids(.backlog).contains(cancelled) && !ids(.inProgress).contains(cancelled)
                  && !ids(.done).contains(cancelled),
                  "a cancelled task must not appear on the board at all")

            check(board.debugColumn(.backlog)?.debugCountText == "1",
                  "Backlog's count badge should read 1, got "
                  + "\(board.debugColumn(.backlog)?.debugCountText ?? "nil")")

            // MARK: A real press and drag starts a real drag session
            //
            // This is the AppKit question: `HelmAccentRow` fills the card and
            // owns a click recognizer, so if the events do not reach the card
            // the board simply cannot be dragged - and nothing about the way
            // it looks would say so.

            guard let card = board.debugColumn(.backlog)?.debugCardViews.first else {
                failures.append("Backlog has no card to drag")
                return
            }
            window.layoutIfNeeded()

            let origin = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)

            // Routed through `window.sendEvent`, never called on the card
            // directly: calling `card.mouseDown` by hand would prove only
            // that the method body works, while the actual question is
            // whether AppKit's own hit testing delivers a press on a card to
            // the card at all - `HelmAccentRow` fills it and owns a click
            // recognizer, and a subview there that overrode `mouseDown` would
            // swallow the gesture with nothing about the board looking wrong.
            check(window.contentView?.hitTest(origin) != nil,
                  "the card's centre should hit-test to something inside the window")
            window.sendEvent(mouseEvent(.leftMouseDown, at: origin, in: window))
            check(!card.debugIsDragging, "a bare press must not start a drag")

            // Under the threshold: still a click, not a drag. This is the
            // guard that stops ordinary hand jitter from turning every click
            // into a drag - AGENTS.md records the same fix twice, for the
            // Sticky Board and for terminal selection.
            let jitter = NSPoint(x: origin.x + ShiftBoardCardView.dragThreshold - 1, y: origin.y)
            window.sendEvent(mouseEvent(.leftMouseDragged, at: jitter, in: window))
            check(!card.debugIsDragging,
                  "a move of less than \(ShiftBoardCardView.dragThreshold)pt must not become a drag")

            let past = NSPoint(x: origin.x + ShiftBoardCardView.dragThreshold + 12, y: origin.y + 20)
            window.sendEvent(mouseEvent(.leftMouseDragged, at: past, in: window))
            check(card.debugIsDragging,
                  "a move past the threshold should have started a drag session - if this fails, "
                  + "the card is not receiving mouse events at all (HelmAccentRow's own click "
                  + "recognizer sitting on top of it is the thing to suspect)")

            // MARK: A real drop moves the task, and writes it

            guard let inProgressDrop = board.debugColumn(.inProgress)?.debugDropView else {
                failures.append("In Progress has no drop view")
                return
            }
            let dragged = dropInfo(taskID: backlog, on: window)
            check(inProgressDrop.draggingEntered(dragged) == .move,
                  "a column should accept a card drag as a move")
            check(inProgressDrop.isDropTargeted,
                  "a column should highlight while a card is over it")
            check(inProgressDrop.performDragOperation(dragged),
                  "dropping a Backlog card on In Progress should be handled")
            check(!inProgressDrop.isDropTargeted,
                  "the highlight should clear the moment the drop lands")

            check(store.activeTasks.first { $0.id == backlog }?.status == .inProgress,
                  "the dropped task's status should now be inProgress in memory")
            let reloaded = ShiftStore()
            check(reloaded.activeTasks.first { $0.id == backlog }?.status == .inProgress,
                  "the dropped task's status should have been written to disk")
            check(ids(.inProgress).sorted() == [backlog, running].sorted(),
                  "In Progress should now hold both cards, got \(ids(.inProgress))")

            // Dropping a card back into the column it is already in changes
            // nothing and says so, rather than rewriting the task for free.
            let again = dropInfo(taskID: backlog, on: window)
            check(inProgressDrop.performDragOperation(again) == false,
                  "dropping a card into the column it is already in should report no change")

            // A drag carrying no task id is refused outright - a text drag
            // from elsewhere in the app must never land on a column.
            let foreign = dropInfo(taskID: nil, on: window)
            check(inProgressDrop.draggingEntered(foreign) == [],
                  "a drag with no task id must be refused")

            // MARK: Out of Done, which is a file move rather than a flip

            guard let backlogDrop = board.debugColumn(.backlog)?.debugDropView else {
                failures.append("Backlog has no drop view")
                return
            }
            check(backlogDrop.performDragOperation(dropInfo(taskID: finished, on: window)),
                  "a Done card should be draggable back to Backlog")
            check(store.activeTasks.contains { $0.id == finished },
                  "reopening a completed task should put it back in active.yaml, not just flip a flag")
            check(!store.allCompletedTasks().contains { $0.id == finished },
                  "a reopened task should be gone from its completed month file")
            check(ids(.done).isEmpty, "Done should be empty once its one card was moved out")

            // MARK: Proportions
            //
            // The captain reacted to this board being too tall before it was
            // even merged - a fixed 420pt card area made every column 515pt
            // whatever it held, so two nearly-empty columns rendered two
            // large voids and pushed Follow-ups and Projects off the page.
            // Both halves of the fix are pinned here: a card is one card
            // tall, and a column is sized to what the fullest one holds.
            controller.debugRender()
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            if let anyCard = board.debugColumn(.inProgress)?.debugCardViews.first {
                check(anyCard.frame.height <= 110,
                      "a board card with a one-line title should be about one row tall, got "
                      + "\(anyCard.frame.height)pt")
            }
            for column in ShiftBoardColumn.allCases {
                guard let view = board.debugColumn(column) else { continue }
                check(view.debugScrollHeight <= ShiftBoardColumnView.maxBodyHeight,
                      "\(column.rawValue)'s card area should never exceed "
                      + "\(ShiftBoardColumnView.maxBodyHeight)pt, got \(view.debugScrollHeight)")
                check(view.debugScrollHeight >= ShiftBoardColumnView.minBodyHeight,
                      "\(column.rawValue)'s card area should stay a real drop target "
                      + "(>= \(ShiftBoardColumnView.minBodyHeight)pt), got \(view.debugScrollHeight)")
            }
            // A sparse board must not reserve the full ceiling - that is the
            // defect itself, and a bounds-only check would pass against it.
            if let sparse = board.debugColumn(.inProgress) {
                check(sparse.debugScrollHeight < ShiftBoardColumnView.maxBodyHeight - 100,
                      "a column holding one card should be nowhere near the ceiling, got "
                      + "\(sparse.debugScrollHeight)pt")
            }

            // MARK: The project filter

            var project = ShiftProject.fresh()
            project.name = "Grand Line"
            store.addProject(project)
            var assigned = ShiftTask.fresh()
            assigned.title = "Belongs to a project"
            assigned.projectID = project.id
            store.addTask(assigned)
            controller.debugRender()

            guard let chips = controller.debugProjectFilterBar else {
                failures.append("the board has no project filter bar")
                return
            }
            check(chips.debugChipTitles.first == "All projects",
                  "the filter row should lead with All projects, got \(chips.debugChipTitles)")
            check(chips.debugChipTitles.contains("Grand Line"),
                  "the filter row should carry a chip per project, got \(chips.debugChipTitles)")

            chips.debugClickChip(projectID: project.id)
            let filtered = ids(.backlog)
            check(filtered == [assigned.id],
                  "filtering to a project should leave only that project's cards, got \(filtered)")

            chips.debugClickChip(projectID: project.id)
            check(ids(.backlog).count > 1,
                  "clicking the active chip again should clear the filter, got \(ids(.backlog))")

            // MARK: The Board/List toggle

            controller.debugSelectTasksView("list")
            check(controller.debugBoardIsVisible == false, "List mode should hide the board")
            check(controller.debugTaskPanelIsVisible, "List mode should show the flat task list")
            controller.debugSelectTasksView("board")
            check(controller.debugBoardIsVisible, "Board mode should show the board")
            check(controller.debugTaskPanelIsVisible == false,
                  "Board mode should hide the flat task panel, so Follow-ups takes the row alone")

            // MARK: DevOps Commands is gone from this page
            //
            // The other half of the split, asserted from the page that lost
            // it - `DestinationMountingSelfTest` asserts the half about the
            // destination that gained it.
            let labels = collectTextFieldValues(in: controller.view)
            check(!labels.contains("DevOps Commands"),
                  "the Tasks page still renders a \"DevOps Commands\" tab pill - it should have "
                  + "moved to its own destination")
        }

        return report(failures)
    }

    // MARK: Harness

    private static func seed(_ store: ShiftStore, title: String, status: ShiftTaskStatus) -> String {
        var task = ShiftTask.fresh()
        task.title = title
        task.status = status
        store.addTask(task)
        return task.id
    }

    private static func mount(store: ShiftStore) -> (ShiftController, NSWindow) {
        let controller = ShiftController(store: store)
        // Far off-screen and `orderFront`, never `makeKeyAndOrderFront`: this
        // machine may be running the captain's own instance, and an event
        // needs a real `windowNumber` to route by - a window that was never
        // ordered in has none, which reads exactly like "the handler is not
        // wired".
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 1300, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFront(nil)
        controller.viewWillAppear()
        // `reloadAllAsync` renders on completion; drain the main queue so the
        // board is populated before anything reads it.
        drainMainQueue()
        controller.debugRender()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    private static func drainMainQueue(turns: Int = 40) {
        for _ in 0..<turns {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type,
                           location: point,
                           modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber,
                           context: nil,
                           eventNumber: 0,
                           clickCount: 1,
                           pressure: 1)!
    }

    /// A stand-in for the `NSDraggingInfo` AppKit hands a drop target. The
    /// destination side only ever reads the pasteboard, so this is the honest
    /// minimum rather than a mock of a whole drag session.
    private static func dropInfo(taskID: String?, on window: NSWindow) -> NSDraggingInfo {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("shift-board-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        if let taskID {
            pasteboard.writeObjects([ShiftBoardPasteboard.item(taskID: taskID)])
        } else {
            pasteboard.setString("not a task", forType: .string)
        }
        return StubDraggingInfo(pasteboard: pasteboard, window: window)
    }

    private static func withScratchStore(_ body: (ShiftStore) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shift-board-view-selftest-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            unsetenv("FM_SHIFT_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore())
    }

    private static func collectTextFieldValues(in view: NSView) -> [String] {
        var out: [String] = []
        if let field = view as? NSTextField { out.append(field.stringValue) }
        for sub in view.subviews { out += collectTextFieldValues(in: sub) }
        return out
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("[ShiftBoardViewSelfTest] all checks passed")
            return true
        }
        print("[ShiftBoardViewSelfTest] \(failures.count) failure(s):")
        for f in failures { print("  - \(f)") }
        return false
    }
}

/// The minimum `NSDraggingInfo` a `ShiftBoardDropView` actually consults.
///
/// `NSDraggingInfo` is a protocol AppKit implements privately; there is no
/// public way to construct a real one, and the drop half of this feature is
/// worth testing. Everything the board reads (`draggingPasteboard`) is real;
/// the rest answers plausibly and is never consulted.
private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    private let window: NSWindow

    init(pasteboard: NSPasteboard, window: NSWindow) {
        self.draggingPasteboard = pasteboard
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions,
                                for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

#endif
