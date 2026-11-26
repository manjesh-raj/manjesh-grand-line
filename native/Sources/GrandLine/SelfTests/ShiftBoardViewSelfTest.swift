// Grand Line - native macOS app.
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
// Run with `FM_RUN_SHIFT_BOARD_VIEW_TESTS=1 .build/debug/GrandLine`.

#if FM_SELFTESTS

import AppKit

enum ShiftBoardViewSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        // First, and on purpose: the revamp case drives no drag. The drag case
        // below starts a real `NSDraggingSession` and never sends its
        // mouse-up, and on a CI runner anything that comes after it - this
        // case's own window, first-responder changes and run-loop turns -
        // waits behind that session until the suite's 300s bound kills it.
        checkTheRevampBoard(check)
        checkTheMetaLineWraps(check)
        // Also before the drag case, for the same reason.
        checkTheBoardFitsTheMinimumWindow(check)

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
            // S09: the Done lane states its window beside its own number,
            // since the filter row no longer carries a note for it.
            check(board.debugColumn(.done)?.debugCountText == "1 \u{00B7} last 7 days",
                  "Done's count should read \"1 · last 7 days\", got "
                  + "\(board.debugColumn(.done)?.debugCountText ?? "nil")")

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

            // UI-17: the band's project menu is the one project filter - the
            // chip row that repeated it above the board is gone.
            check(!controller.debugHasProjectChipRow, "the board should carry no project chip row")
            controller.debugPickProject(id: project.id)
            let filtered = ids(.backlog)
            check(filtered == [assigned.id],
                  "filtering to a project should leave only that project's cards, got \(filtered)")

            controller.debugPickProject(id: nil)
            check(ids(.backlog).count > 1,
                  "All projects should clear the filter, got \(ids(.backlog))")

            // MARK: The Board/List toggle

            controller.debugSelectTasksView("list")
            check(controller.debugBoardIsVisible == false, "List mode should hide the board")
            check(!controller.debugTasksTable.card.isHidden, "List mode should show the tasks table")
            controller.debugSelectTasksView("board")
            check(controller.debugBoardIsVisible, "Board mode should show the board")
            check(controller.debugTasksTable.card.isHidden, "Board mode should hide the tasks table")

            // MARK: DevOps Commands is gone from this page
            //
            // The other half of the split, asserted from the page that lost
            // it - `DestinationMountingSelfTest` asserts the half about the
            // destination that gained it.
            let labels = collectTextFieldValues(in: controller.view)
            check(!labels.contains("DevOps Commands"),
                  "the Tasks page still renders a \"DevOps Commands\" tab pill - it should have "
                  + "moved to its own destination")

            // MARK: U1 - an empty column uses the app's one empty-state shape
            //
            // The review: "Tasks columns say 'Nothing here.' Pick
            // `HelmEmptyState` everywhere and give every one an action."
            // Measured on real columns rather than asserted on the string,
            // because the interesting failure is a component that is in the
            // tree and clipped inside the column that holds it.
            //
            // The invariant, per column: the empty state shows exactly when
            // the column has no cards. By this point in the run the drag
            // cases above have already moved cards around, which is what
            // makes this discriminating for free - some columns hold cards
            // and at least one does not, so a state that always shows and a
            // state that never shows both fail.
            var emptyColumns = 0
            var filledColumns = 0
            for column in ShiftBoardColumn.allCases {
                guard let view = board.debugColumn(column) else {
                    check(false, "U1: no \(column.title) column")
                    continue
                }
                let state = view.debugEmptyState
                let isEmpty = view.debugCardViews.isEmpty
                if isEmpty { emptyColumns += 1 } else { filledColumns += 1 }
                check(state.isMounted,
                      "U1: \(column.title)'s empty state is not in the column's view tree")
                check(state.isShowing == isEmpty,
                      "U1: \(column.title) holds \(view.debugCardViews.count) card(s) and its "
                      + "empty state is \(state.isShowing ? "showing" : "hidden")")
                guard isEmpty else { continue }

                // It has to fit the column it is drawn in.
                check(state.frame.width > 0 && state.frame.height > 0,
                      "U1: \(column.title)'s empty state has no laid-out size (\(state.frame))")
                let needed = state.view.fittingSize
                check(needed.width <= state.frame.width + 0.5,
                      "U1: \(column.title)'s empty state needs \(needed.width)pt and the column "
                      + "gives it \(state.frame.width)pt - it is clipped sideways")
                // U1's other half: the column still offers an action. The add
                // button is always there, directly beneath, which is why the
                // empty state deliberately carries no second copy of it.
                // The Done lane takes no new task (UI-25) - a task is finished
                // by moving it there - so only the open lanes owe an action.
                if column != .done {
                    check(!view.debugAddButton.isHidden && view.debugAddButton.fittingSize.width >= HelmIconButton.minimumSide,
                          "U1/UI-25: an empty \(column.title) lane should offer its quiet Add task")
                }
            }
            check(emptyColumns > 0 && filledColumns > 0,
                  "U1: the board has \(emptyColumns) empty and \(filledColumns) filled columns - "
                  + "this case needs one of each to mean anything")
        }

        return report(failures)
    }

    // MARK: UI-04 - the meta line wraps

    /// UI-04 of full review 4: a card's meta line wraps onto a second line
    /// when it does not fit, rather than cutting the project's name. The
    /// stack it replaced squeezed the name first: "Infra har..." on the
    /// overdue, High card, "Infra h..." at the Large text size. A card in a
    /// narrow lane, with a long project, an overdue date and Low's chip.
    private static func checkTheMetaLineWraps(_ check: (Bool, String) -> Void) {
        autoreleasepool {
            let window = OffScreenProbe.window(width: 400, height: 300, styleMask: [.titled])
            defer { window.orderOut(nil) }
            let card = ShiftWorkspaceTaskCard()
            card.translatesAutoresizingMaskIntoConstraints = false
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = host
            host.addSubview(card)
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
                card.topAnchor.constraint(equalTo: host.topAnchor, constant: 20),
                card.widthAnchor.constraint(equalToConstant: 236),
            ])
            var project = ShiftProject.fresh()
            project.name = "Infra hardening"
            var task = ShiftTask.fresh()
            task.title = "Renew the staging TLS certificate"
            task.priority = .low
            task.dueDate = ShiftDateFormatting.components(from: Date().addingTimeInterval(-2 * 86_400)).dateStr
            card.configure(task: task, project: project, column: .backlog, theme: ThemeManager.shared.theme)
            for _ in 0..<3 { host.layoutSubtreeIfNeeded() }
            let meta = card.debugMeta
            let name = card.debugProjectLabel
            // The fixture can fail: what the line holds is wider than the card.
            let natural = meta.lines(width: .greatestFiniteMagnitude).first?.reduce(CGFloat(0)) {
                $0 + $1.size.width + ShiftCardMetaFlow.spacing
            } ?? 0
            check(natural > meta.bounds.width,
                  "UI-04: fixture: the meta line (\(natural)pt) fits the card's \(meta.bounds.width)pt on one line")
            check(meta.debugLineCount == 2, "UI-04: the meta line takes \(meta.debugLineCount) lines, want 2")
            check(name.frame.width + 0.5 >= name.intrinsicContentSize.width,
                  "UI-04: the project's name is cut: \(name.frame.width)pt of \(name.intrinsicContentSize.width)pt")
            check(card.debugDue?.hasPrefix("Overdue") == true && card.debugChip == "Low",
                  "UI-04: the card lost its due state (\(card.debugDue ?? "none")) or Low's chip")
            // Everything the line holds sits inside the card.
            for item in meta.subviews where !item.isHidden {
                let frame = item.convert(item.bounds, to: card)
                check(frame.maxX <= card.bounds.width - ShiftWorkspaceTaskCard.padding.right + 0.5
                        && frame.maxY <= card.bounds.height + 0.5,
                      "UI-04: a meta item (\(frame)) runs out of the card (\(card.bounds))")
            }
        }
    }

    // MARK: The UI/UX revamp's board (UI-21 to UI-29)

    /// What the revamp changed on the board, read off the mounted page:
    ///
    ///   - UI-21: a lane is not a card - no `HelmCard` anywhere in a lane;
    ///   - UI-22: a task card is a card, since stage 7 the prototype's;
    ///   - UI-23: a Normal task carries no chip; High and Low each carry one
    ///     (Q3);
    ///   - UI-24: the due date is said on the card's due line;
    ///   - UI-26: an empty lane's copy is the quiet "Nothing in progress";
    ///   - UI-27: a targeted lane shows its dashed outline, and only then;
    ///   - UI-28: a focused card renders selected;
    ///   - UI-29: a Done card is struck through and says when it finished.
    private static func checkTheRevampBoard(_ check: (Bool, String) -> Void) {
        withScratchStore { store in
            var normal = ShiftTask.fresh()
            normal.title = "Normal priority, no date"
            store.addTask(normal)
            var high = ShiftTask.fresh()
            high.title = "High priority, due today"
            high.priority = .high
            high.dueDate = ShiftDateFormatting.components(from: Date()).dateStr
            store.addTask(high)
            var low = ShiftTask.fresh()
            low.title = "Low priority"
            low.priority = .low
            store.addTask(low)
            var finished = ShiftTask.fresh()
            finished.title = "Already done"
            store.addTask(finished)
            store.setTaskCompleted(id: finished.id, completed: true)

            let (controller, window) = mount(store: store)
            defer { window.orderOut(nil) }
            guard let board = controller.debugBoardView,
                  let backlog = board.debugColumn(.backlog),
                  let progress = board.debugColumn(.inProgress),
                  let done = board.debugColumn(.done) else {
                check(false, "the revamp case needs a mounted board")
                return
            }

            func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
            check(!descendants(backlog).contains { $0 is HelmCard }, "UI-21: a lane must not be a card")

            func card(_ id: String) -> ShiftBoardCardView? {
                (backlog.debugCardViews + done.debugCardViews).first { $0.taskID == id }
            }
            // The page draws the prototype's card (stage 7), so these read
            // that card - the board's older accent row is never configured.
            if let c = card(normal.id) {
                check(c.debugWorkspaceCard != nil, "UI-22: a task card should be the prototype's card")
                check(c.debugWorkspaceCard?.debugChip == nil, "UI-23: a Normal task carries no chip")
            } else { check(false, "the Normal task should be on the board") }
            if let c = card(high.id) {
                // UI-04 of full review 4: High is a flag before the title,
                // so the meta line keeps its room for the project and due.
                check(c.debugWorkspaceCard?.debugChip == nil && c.debugWorkspaceCard?.debugIsFlagged == true,
                      "UI-04: a High task carries a chip (\(c.debugWorkspaceCard?.debugChip ?? "none")) "
                      + "or no flag before its title")
                check(c.debugWorkspaceCard?.debugDue == "Due today",
                      "UI-24: a task due today says so on its due line, got "
                      + "\"\(c.debugWorkspaceCard?.debugDue ?? "nothing")\"")
            } else { check(false, "the High task should be on the board") }
            if let c = card(low.id) {
                check(c.debugWorkspaceCard?.debugChip == "Low",
                      "UI-23: a Low task carries its chip (Q3: a chip for High and Low), got "
                      + "\(String(describing: c.debugWorkspaceCard?.debugChip))")
            } else { check(false, "the Low task should be on the board") }
            if let c = card(finished.id) {
                check(c.debugWorkspaceCard?.debugIsStruck == true,
                      "UI-29: a Done card's title is struck through")
                check(c.debugWorkspaceCard?.debugDue?.hasPrefix("Done ") == true,
                      "UI-29: a Done card says when it finished")
            } else { check(false, "the finished task should be in the Done lane") }

            check(progress.debugEmptyState.isShowing, "In Progress is empty in this fixture")
            check(collectTextFieldValues(in: progress).contains("Nothing in progress"),
                  "UI-26: the empty lane should read \"Nothing in progress\"")
            check(!collectTextFieldValues(in: progress).contains { $0.contains("in in progress") },
                  "UI-26: never \"in in progress\"")

            check(!progress.debugDropOutlineVisible, "UI-27: no outline while nothing is dragged")
            progress.debugSetDropTargeted(true)
            check(progress.debugDropOutlineVisible, "UI-27: a targeted lane shows its dashed outline")
            progress.debugSetDropTargeted(false)
            check(!progress.debugDropOutlineVisible, "UI-27: and loses it when the drag leaves")

            if let c = card(normal.id) {
                window.makeFirstResponder(c)
                check(c.debugWorkspaceCard?.isSelected == true, "UI-28: a focused card renders selected")
                window.makeFirstResponder(nil)
                check(c.debugWorkspaceCard?.isSelected == false, "UI-28: and stops when focus moves on")
                check((c.debugLiftedSnapshotSize()?.width ?? 0) > c.bounds.width,
                      "UI-27: the drag image is padded for its lifted shadow")
            }

            // UX-03: a card to do shows Done, Tomorrow and Focus while it has
            // the keyboard, Space, T and F do them, and J and K move on.
            if let c = card(normal.id), let next = card(high.id) ?? card(low.id), let workspace = c.debugWorkspaceCard {
                check(!workspace.showsQuickActions, "UX-03: a card at rest shows its quick actions")
                window.makeFirstResponder(c)
                window.contentView?.layoutSubtreeIfNeeded()
                check(workspace.showsQuickActions && workspace.actionButtons.map(\.title) == ["Done", "Tomorrow", "Focus"]
                        && workspace.actionButtons.allSatisfy { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor },
                      "UX-03: a focused card does not show Done, Tomorrow and Focus")
                // A click on a showing action reaches the button, not the card.
                let done = workspace.actionButtons[0]
                let point = c.superview?.convert(NSPoint(x: done.bounds.midX, y: done.bounds.midY), from: done) ?? .zero
                check(c.hitTest(point) === done, "UX-03: a click on Done is taken by the card")
                var actions: [String] = []
                c.onComplete = { actions.append("done") }
                let savedPush = c.onPushDue, savedFocus = c.onStartFocus
                c.onPushDue = { actions.append("push \($0.rawValue)") }
                c.onStartFocus = { actions.append("focus \($0)") }
                func key(_ characters: String, _ code: UInt16) {
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       characters: characters, charactersIgnoringModifiers: characters,
                                                       isARepeat: false, keyCode: code) else { return }
                    c.keyDown(with: event)
                }
                key(" ", 49)
                key("t", 17)
                key("f", 3)
                check(actions == ["done", "push tomorrow", "focus \(FocusTimerEngine.defaultMinutes)"],
                      "UX-03: Space, T and F did \(actions)")
                done.performClick(nil)
                check(actions.last == "done" && actions.count == 4, "UX-03: the Done button did \(actions)")
                c.onPushDue = savedPush
                c.onStartFocus = savedFocus
                c.onComplete = nil
                _ = next
                key("j", 38)
                let moved = window.firstResponder as? ShiftBoardCardView
                check(moved != nil && moved !== c, "UX-03: J did not move to another card")
                if let moved {
                    let up = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, characters: "k",
                                              charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)
                    if let up { moved.keyDown(with: up) }
                    check(window.firstResponder === c, "UX-03: K did not come back to the card")
                }
                window.makeFirstResponder(nil)
                check(!workspace.showsQuickActions, "UX-03: the quick actions stay after focus moves on")
            } else {
                check(false, "UX-03: the fixture has no second card to move to")
            }
            if let c = card(finished.id) {
                check(c.debugWorkspaceCard?.offersQuickActions == false, "UX-03: a Done card offers the quick actions")
            }
        }
    }

    // MARK: Harness

    /// B5 of the Grand Line vs Automic Vault polish report, as verified: the
    /// report's own symptoms were the tour lab's never-ordered window, but
    /// verifying them with realistic data found a real one. At 1100pt and
    /// 960pt the board stayed 924.5pt wide and its Done column ended at maxX
    /// 1180.5, past the window: the Done lane's empty-state sentence held its
    /// one-line width at compression resistance 750, the three lanes are tied
    /// to equal widths, so all three were 297.5pt. It did that while
    /// *hidden*, because a hidden view still lays out - so the shape that
    /// shows it is a Done lane holding a card. Both shapes are checked.
    private static func checkTheBoardFitsTheMinimumWindow(_ check: (Bool, String) -> Void) {
        for shape in ["every lane holds a card", "every lane is empty"] {
            withScratchStore { store in
                if shape == "every lane holds a card" {
                    _ = seed(store, title: "Renew the staging TLS certificate", status: .todo)
                    _ = seed(store, title: "Write the release notes", status: .inProgress)
                    let done = seed(store, title: "Upgrade Postgres on staging", status: .todo)
                    store.setTaskCompleted(id: done, completed: true)
                }
                let controller = ShiftController(store: store)
                let window = OffScreenProbe.window(width: 960, height: 620, styleMask: [.titled, .resizable])
                defer { window.orderOut(nil) }
                window.contentView = controller.view
                window.orderFront(nil)
                controller.viewWillAppear()
                drainMainQueue()
                controller.debugRender()
                controller.view.layoutSubtreeIfNeeded()

                let width = window.contentLayoutRect.width
                var columns: [NSRect] = []
                func walk(_ view: NSView) {
                    if view is ShiftBoardColumnView { columns.append(view.convert(view.bounds, to: nil)) }
                    view.subviews.forEach(walk)
                }
                walk(controller.view)
                check(columns.count == 3, "\(shape): the board shows \(columns.count) columns, expected 3")
                let reach = columns.map(\.maxX).max() ?? 0
                check(reach <= width + 0.5,
                      "\(shape): at the \(width)pt minimum window the board's last column ends at maxX \(reach) - "
                      + "a lane's own copy is holding the lanes wider than the page")
            }
        }
    }

    private static func seed(_ store: ShiftStore, title: String, status: ShiftTaskStatus) -> String {
        var task = ShiftTask.fresh()
        task.title = title
        task.status = status
        store.addTask(task)
        return task.id
    }

    private static func mount(store: ShiftStore) -> (ShiftController, NSWindow) {
        let controller = ShiftController(store: store)
        // `OffScreenProbe.window(...)` and `orderFront`, never
        // `makeKeyAndOrderFront`: this
        // machine may be running the captain's own instance, and an event
        // needs a real `windowNumber` to route by - a window that was never
        // ordered in has none, which reads exactly like "the handler is not
        // wired".
        // `needsWindowServerMouse`: this is the app's only suite that drives a
        // real `NSDraggingSession` (`ShiftBoardViews.swift:334` is the app's
        // only `beginDraggingSession` call). It starts one and never sends a
        // matching mouse-up, so in a window the window server ignores the
        // session sits waiting and the later `debugClickChip` blocks behind it
        // in `NSCoreDragManager._dragUntilMouseUp`. Measured over five runs
        // each: **1-3s** here, **4-25s** fully off-screen - which is what hit
        // CI's 300s per-suite bound twice, against ~4s on `main`. So this one
        // window is invisible by alpha rather than by position; see
        // `OffScreenProbeWindow.swift`'s "one exception" section.
        let window = OffScreenProbe.window(width: 1300, height: 900,
                                           styleMask: [.titled, .resizable],
                                           needsWindowServerMouse: true)
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
