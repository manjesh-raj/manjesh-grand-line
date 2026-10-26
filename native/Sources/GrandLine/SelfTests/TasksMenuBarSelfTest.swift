// Grand Line - native macOS app.
//
// The Tasks menu-bar item in the Bridge shape: the real
// `ShiftMenuBarController`, over a real `ShiftStore` in a scratch directory,
// with every inline action driven through its real button (`performClick`),
// never through the handler alone.
//
// What is asserted: the popover shows the store's own tasks in the Bridge
// shape (Now, Up next with follow-ups, the backlog, done today and the
// streak); Check off, Claim and a follow-up's check reach the store and the
// pane re-renders from it; the pin keeps the popover open by switching its
// behaviour; the footer and the Now card's navigating buttons reach their
// wiring; locking clears the pane (GL-09); and the quick-add field still
// files a task. The popover is built, never shown - no suite here shows a
// real popover headlessly.
//
// Run with:
//   swift build && FM_RUN_TASKS_MENU_BAR_TESTS=1 .build/debug/GrandLine; echo $?
//
// Pure logic: no window. A status item needs no window either (the compact
// mode suites build one in the same lane), so it guards CI's blocking lane.
//
// Hermeticity: `FM_SHIFT_DIR` points the store at a fresh temporary directory
// before it is built, so nothing reaches the captain's tasks, and with that
// override the store runs no git sync at all.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum TasksMenuBarSelfTest {

    static func run() -> Bool {
        print("== Tasks menu bar, Bridge shape ==")
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-menu-bar-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        let wasLocked = AppLockGate.shared.isLocked
        AppLockGate.shared.setLocked(false)
        defer {
            AppLockGate.shared.setLocked(wasLocked)
            try? FileManager.default.removeItem(at: scratch)
        }

        let store = ShiftStore()
        check(store.activeTasks.isEmpty, "the scratch store starts empty, or the fixture below is not the whole truth")
        let seeded = seed(store)
        let controller = ShiftMenuBarController(store: store)
        var started: [String] = []
        controller.onStartFocus = { started.append($0.id) }
        controller.debugPrepareToShow()
        let content = controller.debugContent
        let pane = content.debugPane

        checkItShowsTheStoreInTheBridgeShape(pane, seeded: seeded, check)
        checkTheInlineActionsReachTheStore(controller, store: store, seeded: seeded, started: { started }, check)
        checkThePinKeepsThePopoverOpen(controller, check)
        checkTheNavigatingButtonsReachTheirWiring(controller, check)
        checkThePopoverIsCappedAndScrolls(controller, check)
        checkQuickAddStillFilesATask(controller, store: store, check)
        checkLockingClearsThePane(controller, check)

        withExtendedLifetime(controller) {}
        print(ok ? "TasksMenuBarSelfTest: all checks passed" : "TasksMenuBarSelfTest: FAILED")
        return ok
    }

    // MARK: Fixture

    private struct Seeded {
        let now: ShiftTask
        let later: ShiftTask
        let backlog: ShiftTask
        let followUp: ShiftFollowUp
    }

    /// A task overdue since yesterday with a half-done checklist (the Now
    /// card), one due tomorrow, an undated backlog task, a follow-up due
    /// today, and one task finished today and one yesterday (done today, and
    /// a two-day streak).
    private static func seed(_ store: ShiftStore) -> Seeded {
        let now = Date()
        let cal = Calendar.current
        func day(_ offset: Int) -> String {
            ShiftDateFormatting.components(from: cal.date(byAdding: .day, value: offset, to: now) ?? now).dateStr
        }
        var overdue = ShiftTask.fresh()
        overdue.title = "Rotate the staging certificate"
        overdue.dueDate = day(-1)
        overdue.subtasks = [ShiftSubtask(id: "a", title: "Issue", done: true),
                            ShiftSubtask(id: "b", title: "Deploy", done: false)]
        store.addTask(overdue)
        var later = ShiftTask.fresh()
        later.title = "Draft the Herdr upgrade plan"
        later.dueDate = day(1)
        store.addTask(later)
        var backlog = ShiftTask.fresh()
        backlog.title = "Clean up stale kube contexts"
        store.addTask(backlog)
        var followUp = ShiftFollowUp.fresh()
        followUp.title = "Vendor SSO ticket"
        followUp.followUpAt = day(0)
        store.addFollowUp(followUp)

        for (title, offset) in [("Finished today", 0), ("Finished yesterday", -1)] {
            var done = ShiftTask.fresh()
            done.title = title
            store.addTask(done)
            let stamp = cal.date(byAdding: .day, value: offset, to: now) ?? now
            store.setTaskCompleted(id: done.id, completed: true, now: stamp)
        }
        return Seeded(now: overdue, later: later, backlog: backlog, followUp: followUp)
    }

    // MARK: Cases

    private static func checkItShowsTheStoreInTheBridgeShape(_ pane: TasksBridgePane, seeded: Seeded,
                                                            _ check: (Bool, String) -> Void) {
        let card = pane.debugNowCard
        check(card.debugTitle == seeded.now.title,
              "the Now card is the overdue task from the real store - got \(card.debugTitle)")
        check(card.debugDetail.contains("1 of 2 checked"),
              "and counts its subtasks - got \(card.debugDetail)")
        check(card.debugPillText?.contains("overdue") == true,
              "and its pill says it is overdue in words - got \(card.debugPillText ?? "nil")")
        let rows = pane.debugTimelineRows.map { $0.debugTitle }
        check(rows == [seeded.followUp.title, seeded.later.title],
              "Up next is the follow-up due today, then tomorrow's task - got \(rows)")
        check(pane.debugBacklogRows.map { $0.debugTitle } == [seeded.backlog.title],
              "the undated task is in the backlog")
        check(pane.header.debugProgressText == "1/2",
              "one finished today out of it plus the one overdue - got \(pane.header.debugProgressText ?? "nil")")
        check(pane.header.debugStreakText == "2",
              "a task finished today and yesterday is a two-day streak - got \(pane.header.debugStreakText ?? "nil")")
        check(!pane.debugNowCard.debugFocusButton.isHidden,
              "Start focus shows once the item's focus timer is wired")
    }

    private static func checkTheInlineActionsReachTheStore(_ controller: ShiftMenuBarController, store: ShiftStore,
                                                          seeded: Seeded, started: () -> [String],
                                                          _ check: (Bool, String) -> Void) {
        let pane = controller.debugContent.debugPane

        pane.debugNowCard.debugFocusButton.performClick(nil)
        check(started() == [seeded.now.id], "Start focus starts the timer on the Now task - got \(started())")

        pane.debugBacklogRows.first?.debugClaimButton.performClick(nil)
        let claimed = store.activeTasks.first { $0.id == seeded.backlog.id }
        check(claimed?.status == .inProgress,
              "Claim sets the existing In progress status in the store - got \(String(describing: claimed?.status))")
        check(pane.debugBacklogRows.first?.debugClaimedIsShowing == true,
              "and the store's change repaints the row as In progress without a reopen")

        pane.debugTimelineRows.first { $0.model.kind == .followUp }?.debugCheckButton.performClick(nil)
        check(store.followUps.first { $0.id == seeded.followUp.id }?.status == .done,
              "a follow-up row's check marks that follow-up done")

        pane.debugNowCard.debugCheckOffButton.performClick(nil)
        check(!store.activeTasks.contains { $0.id == seeded.now.id }
                  && store.allCompletedTasks().contains { $0.id == seeded.now.id },
              "Check off completes the Now task through the store's own completion path")
        check(pane.debugNowCard.debugTitle != seeded.now.title,
              "and the pane re-renders from the store: the card no longer shows the finished task")
        check(pane.header.debugProgressText == "2/2",
              "and done today counts it - got \(pane.header.debugProgressText ?? "nil")")
    }

    private static func checkThePinKeepsThePopoverOpen(_ controller: ShiftMenuBarController,
                                                       _ check: (Bool, String) -> Void) {
        let pin = controller.debugContent.debugPane.header.debugPinButton
        check(!pin.isHidden, "the menu-bar item's header carries the pin")
        check(controller.debugPopover.behavior == .transient, "unpinned, the popover closes on a click away")
        pin.performClick(nil)
        check(controller.debugPopover.behavior == .applicationDefined,
              "pinned, it stays open until told to close")
        check((pin.accessibilityLabel() ?? "").hasPrefix("Unpin"),
              "and the pin says what pressing it again does - got \(pin.accessibilityLabel() ?? "nil")")
        pin.performClick(nil)
        check(controller.debugPopover.behavior == .transient, "unpinning puts the click-away close back")
    }

    private static func checkTheNavigatingButtonsReachTheirWiring(_ controller: ShiftMenuBarController,
                                                                  _ check: (Bool, String) -> Void) {
        var calls: [String] = []
        controller.onOpenTasks = { calls.append("tasks") }
        controller.onOpenSettings = { calls.append("settings") }
        controller.onOpenTask = { calls.append("task \($0)") }
        let footer = controller.debugContent.debugFooter
        footer.debugOpenTasksButton.performClick(nil)
        footer.debugSettingsButton.performClick(nil)
        let pane = controller.debugContent.debugPane
        let backlog = pane.debugBacklogRows.first
        backlog?.debugClick()
        check(calls == ["tasks", "settings", "task \(backlog?.model.id ?? "")"],
              "Open Tasks, Settings and a row's own click each reach their wiring - got \(calls)")
        check(!footer.debugSettingsButton.isHidden, "the menu-bar footer shows Settings")
    }

    private static func checkThePopoverIsCappedAndScrolls(_ controller: ShiftMenuBarController,
                                                          _ check: (Bool, String) -> Void) {
        let size = controller.debugPopover.contentSize
        check(abs(size.width - ShiftMenuBarPopoverController.width) < 0.5,
              "the popover is the Bridge's 330pt wide - got \(size.width)")
        let scroll = controller.debugContent.debugScroll
        check(scroll.frame.height <= ShiftMenuBarPopoverController.maxBodyHeight + 0.5,
              "the body never grows past its cap - got \(scroll.frame.height)")
        check(size.height > scroll.frame.height,
              "and the popover reports its whole height to AppKit, quick add and footer included - got \(size.height)")
    }

    private static func checkQuickAddStillFilesATask(_ controller: ShiftMenuBarController, store: ShiftStore,
                                                     _ check: (Bool, String) -> Void) {
        let before = store.activeTasks.count
        controller.debugContent.debugSubmitQuickAdd("Renew the wildcard cert")
        check(store.activeTasks.count == before + 1
                  && store.activeTasks.contains { $0.title == "Renew the wildcard cert" },
              "the quick-add field still files a real task through the store")
    }

    private static func checkLockingClearsThePane(_ controller: ShiftMenuBarController,
                                                  _ check: (Bool, String) -> Void) {
        let pane = controller.debugContent.debugPane
        check(!pane.debugTimelineRows.isEmpty || !pane.debugBacklogRows.isEmpty,
              "the pane shows data before the lock, or the check below cannot fail")
        AppLockGate.shared.setLocked(true)
        controller.debugRefresh()
        check(pane.debugTimelineRows.isEmpty && pane.debugBacklogRows.isEmpty
                  && pane.debugNowCard.debugActionsAreHidden && pane.header.debugProgressText == nil,
              "GL-09: locked, the popover holds none of the captain's tasks, counts or actions")
        AppLockGate.shared.setLocked(false)
    }
}

#endif
