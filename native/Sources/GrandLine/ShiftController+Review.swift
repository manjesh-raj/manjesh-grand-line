// Grand Line - native macOS app.
//
// UX-05 of full review 4: the Weekly review's hero and the review walk
// (`ShiftWeeklyReviewWalk.swift`), and every write the walk asks for.
//
//   - Done completes the task, through the same store call a card's Done
//     makes.
//   - Reschedule… offers Tomorrow, Next week, or the When panel for any
//     other date. The task stays in front of the captain until a new date
//     lands.
//   - Drop it deletes the task through the page's one delete path, so it
//     asks first (GL-06). Cancelling the prompt keeps the task on screen.
//   - Skip leaves it for later.
//
// The queue is fixed when the review starts, so the count ("2 of 4") never
// moves under the captain. A task that left the active list while the
// review was open (a sync, the board) is passed over rather than shown.

import AppKit

extension ShiftController {

    /// The review in progress.
    struct ReviewWalk {
        var queue: [ShiftReviewWords.Decision]
        var index = 0
        var done = 0
        var moved = 0
        var dropped = 0
        var skipped = 0
        var finished = false
        var saved = false
    }

    func wireReviewWalk() {
        reviewBand.onStart = { [weak self] in self?.startReview() }
        reviewWalkCard.onDone = { [weak self] in self?.reviewDone() }
        reviewWalkCard.onReschedule = { [weak self] anchor in self?.reviewReschedule(from: anchor) }
        reviewWalkCard.onDrop = { [weak self] in self?.reviewDrop() }
        reviewWalkCard.onSkip = { [weak self] in self?.reviewAdvance { $0.skipped += 1 } }
        reviewWalkCard.onStop = { [weak self] in self?.stopReview() }
        reviewWalkCard.onSaveToNotebook = { [weak self] in self?.saveReviewToNotebook() }
    }

    /// The queue the review would walk right now.
    func reviewDecisions(summary: ShiftWeeklySummary? = nil) -> [ShiftReviewWords.Decision] {
        let pushed = (summary ?? store.weeklySummary()).pushedBack
        return ShiftReviewWords.decisions(active: store.activeTasks, pushedBack: pushed, projects: store.projects,
                                          now: DayRollover.now())
    }

    /// The band: the week, the verdict, done this week and the focus time.
    func renderReviewBand(summary: ShiftWeeklySummary, focusSeconds: Int) {
        let decisions = reviewDecisions(summary: summary)
        let verdict = ShiftReviewWords.verdict(decisions)
        reviewBand.configure(kicker: ShiftReviewWords.kicker(now: DayRollover.now()),
                             headline: verdict.headline, body: verdict.body,
                             done: summary.completedCount,
                             focus: focusSeconds > 0 ? FocusTimerFormat.total(focusSeconds) : "None",
                             canStart: !decisions.isEmpty && reviewWalk == nil)
        renderReviewWalk()
    }

    func startReview() {
        let queue = reviewDecisions()
        guard !queue.isEmpty else { return }
        reviewWalk = ReviewWalk(queue: queue)
        reviewBand.startButton.isHidden = true
        renderReviewWalk()
        view.window?.makeFirstResponder(reviewWalkCard)
    }

    func stopReview() {
        reviewWalk = nil
        reviewWalkCard.isHidden = true
        if topLevelView == .weeklyReview { renderWeeklyReviewFromWalk() }
    }

    /// Shows the decision the walk is on, passing over any task that is no
    /// longer active, or the summary once the queue is through.
    func renderReviewWalk() {
        guard var walk = reviewWalk else {
            reviewWalkCard.isHidden = true
            return
        }
        while !walk.finished, walk.index < walk.queue.count,
              !store.activeTasks.contains(where: { $0.id == walk.queue[walk.index].id }) {
            walk.index += 1
        }
        if walk.index >= walk.queue.count { walk.finished = true }
        reviewWalk = walk
        reviewWalkCard.isHidden = false
        if walk.finished {
            let nextWeek = store.weeklySummary().upcomingCount
            reviewWalkCard.configure(.finished(summary: ShiftReviewWords.summary(
                done: walk.done, moved: walk.moved, dropped: walk.dropped, skipped: walk.skipped, nextWeek: nextWeek),
                saved: walk.saved))
        } else {
            reviewWalkCard.configure(.deciding(index: walk.index, total: walk.queue.count,
                                               decision: walk.queue[walk.index]))
        }
    }

    /// The decision on screen, if the walk is on one.
    var currentReviewTaskID: String? {
        guard let walk = reviewWalk, !walk.finished, walk.index < walk.queue.count else { return nil }
        return walk.queue[walk.index].id
    }

    func reviewAdvance(_ tally: (inout ReviewWalk) -> Void) {
        guard var walk = reviewWalk, !walk.finished else { return }
        tally(&walk)
        walk.index += 1
        reviewWalk = walk
        renderWeeklyReviewFromWalk()
        if view.window?.firstResponder !== reviewWalkCard { view.window?.makeFirstResponder(reviewWalkCard) }
    }

    private func reviewDone() {
        guard let id = currentReviewTaskID else { return }
        store.setTaskCompleted(id: id, completed: true)
        reviewAdvance { $0.done += 1 }
    }

    private func reviewReschedule(from anchor: NSView) {
        guard currentReviewTaskID != nil else { return }
        let menu = NSMenu()
        for option in ShiftDuePush.allCases {
            let item = NSMenuItem(title: option.menuTitle, action: #selector(reviewPushPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let pick = NSMenuItem(title: "Pick a Date\u{2026}", action: #selector(reviewPickDate(_:)), keyEquivalent: "")
        pick.target = self
        pick.representedObject = anchor
        menu.addItem(pick)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
    }

    @objc func reviewPushPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = ShiftDuePush(rawValue: raw) else { return }
        reviewPush(option)
    }

    /// Tomorrow or Next week, through the board's own push (with its Undo).
    func reviewPush(_ option: ShiftDuePush) {
        guard let id = currentReviewTaskID, let task = store.activeTasks.first(where: { $0.id == id }) else { return }
        pushDueDate(task, by: option)
        reviewAdvance { $0.moved += 1 }
    }

    @objc func reviewPickDate(_ sender: NSMenuItem) {
        guard let anchor = sender.representedObject as? NSView, let id = currentReviewTaskID,
              let task = store.activeTasks.first(where: { $0.id == id }) else { return }
        let projectName = task.projectID.flatMap { pid in store.projects.first { $0.id == pid }?.name }
        let popover = ShiftSchedulePopover(task: task, projectName: projectName,
                                           allDayReminderAt: store.settings.allDayReminderAt)
        popover.onCommit = { [weak self] draft in
            guard let self else { return }
            self.commitInspectorSchedule(draft, taskID: id)
            if self.currentReviewTaskID == id { self.reviewAdvance { $0.moved += 1 } }
        }
        popover.onOpenTask = { [weak self] in
            guard let self, let live = self.store.activeTasks.first(where: { $0.id == id }) else { return }
            self.presentTaskEditor(for: live)
        }
        inspectorSchedulePopover?.close()
        inspectorSchedulePopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// Deleted through the page's one path, which asks first. A cancelled
    /// prompt leaves the task on screen.
    private func reviewDrop() {
        guard let id = currentReviewTaskID else { return }
        confirmDeleteTask(id: id)
        guard !store.activeTasks.contains(where: { $0.id == id }) else { return }
        reviewAdvance { $0.dropped += 1 }
    }

    /// The summary, as a note in the Notebook.
    func saveReviewToNotebook() {
        guard var walk = reviewWalk, walk.finished, !walk.saved else { return }
        guard let notebook = GrandLineServices.shared.notebookStore else {
            Toast.show(in: view, message: "The Notebook isn\u{2019}t open yet, so the summary was not saved.")
            return
        }
        let now = DayRollover.now()
        let title = ShiftReviewWords.notebookTitle(now: now)
        let summary = ShiftReviewWords.summary(done: walk.done, moved: walk.moved, dropped: walk.dropped,
                                               skipped: walk.skipped, nextWeek: store.weeklySummary().upcomingCount)
        notebook.createPage(title: title, content: "# \(title)\n\n\(summary)\n")
        walk.saved = true
        reviewWalk = walk
        renderReviewWalk()
        Toast.show(in: view, message: "Saved to the Notebook as \u{201C}\(title)\u{201D}")
    }

    /// The whole tab again: a decision changes the verdict, the pushed-back
    /// list and the agenda under the walk.
    func renderWeeklyReviewFromWalk() {
        render()
        if topLevelView != .weeklyReview { renderReviewWalk() }
    }
}
