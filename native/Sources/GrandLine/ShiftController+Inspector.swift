// Grand Line - native macOS app.
//
// UX-04 of full review 4: Tasks fills the sidebar shell's inspector with the
// selected task (`ShiftTaskInspectorView`), and this file is every write the
// inspector asks for. The view never touches the store.
//
// What opens where:
//   - A click on a board card, a List row's click or its Open Task…, ⌘K and
//     the menu bar's task rows open the task here, beside the board.
//   - The calendar fills the page and keeps the sheet, and so does a
//     project's own detail page.
//   - New Task stays a sheet: a focused form for a record that does not
//     exist yet.
//   - "Open in Editor…" in the inspector opens the sheet for the fields the
//     inspector does not carry (tags, the image).

import AppKit

extension ShiftController: WorkspaceInspectorSource {

    /// The selected task, while the board or the list shows.
    var inspectorContent: WorkspaceInspectorContent? {
        guard isViewLoaded, inspectedTaskID != nil, topLevelView == .dashboard,
              tasksView != .calendar, !isProjectDetailFullPage else { return nil }
        return WorkspaceInspectorContent(title: TaskInspectorWords.title, view: taskInspector)
    }

    var inspectorEmptyText: (title: String, body: String) {
        (TaskInspectorWords.emptyTitle, TaskInspectorWords.emptyBody)
    }

    /// Closing the pane saves what was being typed and lets go of the task.
    func inspectorShouldClose() -> Bool {
        taskInspector.flushPendingEdits()
        setInspectedTask(nil)
        return true
    }

    // MARK: Selecting

    /// Show `id` in the inspector and ask the shell to open it.
    func inspectTask(id: String) {
        setInspectedTask(id)
        onInspectorContentChanged?()
        onShowInspector?()
    }

    private func setInspectedTask(_ id: String?) {
        if id != inspectedTaskID { taskInspector.flushPendingEdits() }
        inspectedTaskID = id
        markInspectedCard(id)
        if id == nil { inspectedActivity = nil }
        refreshTaskInspector()
    }

    /// Refill the inspector from the store. A task that has left the active
    /// list (finished, deleted, or gone in a sync) takes the details with it.
    func refreshTaskInspector() {
        guard let id = inspectedTaskID else { return }
        guard let task = store.activeTasks.first(where: { $0.id == id }) else {
            inspectedTaskID = nil
            inspectedActivity = nil
            markInspectedCard(nil)
            onInspectorContentChanged?()
            return
        }
        if inspectedActivity?.id != id {
            let read = store.recentActivityChecked()
            inspectedActivity = (id, TaskInspectorWords.activityLines(task: task, entries: read.entries,
                                                                      unreadable: !read.unreadableMonths.isEmpty,
                                                                      now: DayRollover.now()))
        }
        let projectName = task.projectID.flatMap { pid in store.projects.first { $0.id == pid }?.name }
        taskInspector.configure(task: task, projectName: projectName, activity: inspectedActivity?.lines ?? [],
                                now: DayRollover.now())
    }

    func makeTaskInspector() -> ShiftTaskInspectorView {
        let inspector = ShiftTaskInspectorView()
        inspector.onEditText = { [weak self] id, title, notes in self?.saveInspectorText(id: id, title: title, notes: notes) }
        inspector.onToggleSubtask = { [weak self] subtaskID, done in
            guard let self, let id = self.inspectedTaskID else { return }
            self.store.setSubtaskDone(taskID: id, subtaskID: subtaskID, done: done)
        }
        inspector.onAddSubtask = { [weak self] words in self?.addInspectorSubtask(words) }
        inspector.onRemoveSubtask = { [weak self] subtaskID in self?.removeInspectorSubtask(subtaskID) }
        inspector.onEditSchedule = { [weak self] anchor in self?.editInspectorSchedule(from: anchor) }
        inspector.onPickProject = { [weak self] anchor in self?.pickInspectorProject(from: anchor) }
        inspector.onPickPriority = { [weak self] anchor in self?.pickInspectorPriority(from: anchor) }
        inspector.onOpenEditor = { [weak self] in
            guard let self, let id = self.inspectedTaskID,
                  let task = self.store.activeTasks.first(where: { $0.id == id }) else { return }
            self.presentTaskEditor(for: task)
        }
        inspector.onDelete = { [weak self] in
            guard let self, let id = self.inspectedTaskID else { return }
            self.confirmDeleteTask(id: id)
        }
        return inspector
    }

    // MARK: Saving

    /// A pause in typing, or the field left. An empty title is not saved:
    /// the task keeps the one it had until there are words to replace it.
    private func saveInspectorText(id: String, title: String, notes: String) {
        guard var task = store.activeTasks.first(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmed.isEmpty ? task.title : trimmed
        guard newTitle != task.title || notes != task.description else { return }
        task.title = newTitle
        task.description = notes
        store.updateTask(task)
    }

    private func addInspectorSubtask(_ words: String) {
        guard let id = inspectedTaskID, var task = store.activeTasks.first(where: { $0.id == id }) else { return }
        task.subtasks.append(ShiftSubtask(id: UUID().uuidString, title: words, done: false))
        store.updateTask(task)
    }

    /// Removed with an Undo that puts the item back where it was (GL-33:
    /// the item is in hand, so the restore is real).
    private func removeInspectorSubtask(_ subtaskID: String) {
        guard let id = inspectedTaskID, var task = store.activeTasks.first(where: { $0.id == id }),
              let index = task.subtasks.firstIndex(where: { $0.id == subtaskID }) else { return }
        let removed = task.subtasks.remove(at: index)
        store.updateTask(task)
        Toast.showUndo(in: view, message: "Removed \u{201C}\(removed.title)\u{201D}") { [weak self] in
            guard let self, var current = self.store.activeTasks.first(where: { $0.id == id }),
                  !current.subtasks.contains(where: { $0.id == removed.id }) else { return }
            current.subtasks.insert(removed, at: min(index, current.subtasks.count))
            self.store.updateTask(current)
        }
    }

    /// The date chip and the repeat chip open the calendar's own When panel
    /// beside them, and commit through the same draft mapping with the same
    /// Undo.
    private func editInspectorSchedule(from anchor: NSView) {
        guard let id = inspectedTaskID, let task = store.activeTasks.first(where: { $0.id == id }) else { return }
        inspectorSchedulePopover?.close()
        let projectName = task.projectID.flatMap { pid in store.projects.first { $0.id == pid }?.name }
        let popover = ShiftSchedulePopover(task: task, projectName: projectName,
                                           allDayReminderAt: store.settings.allDayReminderAt)
        popover.onCommit = { [weak self] draft in self?.commitInspectorSchedule(draft, taskID: id) }
        popover.onOpenTask = { [weak self] in
            guard let self, let live = self.store.activeTasks.first(where: { $0.id == id }) else { return }
            self.presentTaskEditor(for: live)
        }
        popover.onClose = { [weak self, weak popover] in
            if let self, self.inspectorSchedulePopover === popover { self.inspectorSchedulePopover = nil }
        }
        inspectorSchedulePopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
    }

    func commitInspectorSchedule(_ draft: ShiftScheduleDraft, taskID id: String) {
        guard let task = store.activeTasks.first(where: { $0.id == id }), draft.changes(task) else { return }
        let updated = draft.applied(to: task)
        store.updateTask(updated)
        Toast.showUndo(in: view, message: TaskCalendarController.scheduleToast(from: task, to: updated)) { [weak self] in
            guard let self, let current = self.store.activeTasks.first(where: { $0.id == id }) else { return }
            self.store.updateTask(TaskCalendarController.restoringSchedule(of: task, into: current))
        }
    }

    private func pickInspectorProject(from anchor: NSView) {
        guard let id = inspectedTaskID, let task = store.activeTasks.first(where: { $0.id == id }) else { return }
        let menu = NSMenu()
        let none = NSMenuItem(title: "No project", action: #selector(inspectorProjectPicked(_:)), keyEquivalent: "")
        none.target = self
        none.state = task.projectID == nil ? .on : .off
        menu.addItem(none)
        if !store.projects.isEmpty { menu.addItem(.separator()) }
        for project in store.projects {
            let item = NSMenuItem(title: project.name, action: #selector(inspectorProjectPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = project.id
            item.state = task.projectID == project.id ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
    }

    @objc func inspectorProjectPicked(_ sender: NSMenuItem) {
        setInspectedTaskProject(sender.representedObject as? String)
    }

    func setInspectedTaskProject(_ projectID: String?) {
        guard let id = inspectedTaskID, var task = store.activeTasks.first(where: { $0.id == id }),
              task.projectID != projectID else { return }
        task.projectID = projectID
        store.updateTask(task)
    }

    private func pickInspectorPriority(from anchor: NSView) {
        guard let id = inspectedTaskID, let task = store.activeTasks.first(where: { $0.id == id }) else { return }
        let menu = NSMenu()
        for priority in [ShiftPriority.high, .normal, .low] {
            let item = NSMenuItem(title: priority.rawValue.capitalized, action: #selector(inspectorPriorityPicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = priority.rawValue
            item.state = task.priority == priority ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
    }

    @objc func inspectorPriorityPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let priority = ShiftPriority(rawValue: raw) else { return }
        setInspectedTaskPriority(priority)
    }

    func setInspectedTaskPriority(_ priority: ShiftPriority) {
        guard let id = inspectedTaskID, var task = store.activeTasks.first(where: { $0.id == id }),
              task.priority != priority else { return }
        task.priority = priority
        store.updateTask(task)
    }
}
