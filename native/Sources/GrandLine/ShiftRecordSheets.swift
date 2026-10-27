// Grand Line - native macOS app.
//
// The task and follow-up sheets, for any page that edits Shift's records.
//
// Tasks was the only page that opened these until the Calendar became its own
// destination (`TaskCalendarController`). Two pages now open the same New Task
// sheet, the same task editor with its attachment and its Delete button, and
// the same follow-up editor, so the sheets live here and each page passes
// itself as the presenter. The page still decides what to redraw afterwards,
// which is the one thing that differs between them.
//
// One way to edit each record, the same rule `Navigator.newContextualItem`
// follows for creation: a fix to the sheet cannot then miss an entry point.

import AppKit

enum ShiftRecordSheets {

    /// The task editor, presented as a sheet over `presenter`.
    ///
    /// `prefill` seeds a **new** task's fields; `task` edits an existing one.
    /// They are separate parameters rather than one, because which of the two
    /// it is decides whether saving calls `addTask` or `updateTask` - passing a
    /// prefilled task as `task` would silently make the promotion overwrite a
    /// task that does not exist yet.
    ///
    /// `defaultStatus` is how a board column's own "+ Add task" puts a brand
    /// new task straight into In Progress: the editor has no status control,
    /// so the caller applies it to whatever comes back. Ignored when editing.
    static func presentTaskEditor(from presenter: NSViewController, store: ShiftStore,
                                  task: ShiftTask?, prefill: ShiftTask? = nil,
                                  defaultProjectID: String? = nil,
                                  defaultStatus: ShiftTaskStatus? = nil,
                                  onSaved: @escaping () -> Void,
                                  onDelete: @escaping (String) -> Void) {
        let existingAttachmentData = (task?.hasAttachment ?? false) ? store.attachmentData(forTaskID: task!.id) : nil
        let editor = ShiftTaskEditorController(
            task: task ?? prefill, projects: store.projects, defaultProjectID: defaultProjectID,
            existingAttachmentData: existingAttachmentData
        )
        editor.onSave = { saved, attachmentChange in
            if task != nil {
                store.updateTask(saved, attachment: attachmentChange)
            } else {
                var created = saved
                if let defaultStatus { created.status = defaultStatus }
                store.addTask(created, attachment: attachmentChange)
            }
            onSaved()
        }
        // GL-06: the editor's own Delete button confirms through the caller's
        // one delete path. Deferred a runloop turn because the sheet dismisses
        // itself the moment this closure returns, and running a modal alert on
        // a sheet that is mid-teardown stacks one window on another - the same
        // fix `HostsController`'s own key editor carries.
        editor.onDelete = { id in
            DispatchQueue.main.async { onDelete(id) }
        }
        presenter.presentAsSheet(editor)
    }

    /// The follow-up editor: a new one when `followUp` is nil.
    ///
    /// `onDelete` is the task editor's own, for the same reason and with the
    /// same deferral: an existing follow-up's sheet carries the Delete button a
    /// task's does, and it confirms through the caller's one delete path.
    static func presentFollowUpEditor(from presenter: NSViewController, store: ShiftStore,
                                      followUp: ShiftFollowUp?, prefill: ShiftFollowUp? = nil,
                                      onSaved: @escaping () -> Void,
                                      onDelete: @escaping (String) -> Void) {
        let editor = ShiftFollowUpEditorController(followUp: followUp ?? prefill, tasks: store.activeTasks,
                                                   projects: store.projects)
        editor.onSave = { saved in
            if followUp != nil {
                store.updateFollowUp(saved)
            } else {
                store.addFollowUp(saved)
            }
            onSaved()
        }
        editor.onDelete = { id in
            DispatchQueue.main.async { onDelete(id) }
        }
        presenter.presentAsSheet(editor)
    }

    /// GL-06's one confirmation for deleting a task. Returns whether it was
    /// deleted, so the caller can redraw; the toast is posted over `view`.
    @discardableResult
    static func confirmDeleteTask(id: String, store: ShiftStore, in view: NSView) -> Bool {
        let task = store.activeTasks.first(where: { $0.id == id })
            ?? store.allCompletedTasks().first(where: { $0.id == id })
        guard let task else { return false }

        var detail = "This can't be undone."
        if task.hasAttachment { detail += " Its attached image is deleted too." }
        if !task.subtasks.isEmpty {
            detail += " Its \(task.subtasks.count) subtask\(task.subtasks.count == 1 ? "" : "s") go with it."
        }
        guard DestructiveConfirm.confirm(message: "Delete \u{201C}\(task.title)\u{201D}?",
                                         detail: detail,
                                         confirmTitle: "Delete Task",
                                         window: view.window) else { return false }
        store.deleteTask(id: id)
        Toast.show(in: view, message: "\u{201C}\(task.title)\u{201D} deleted")
        return true
    }

    /// GL-06's one confirmation for deleting a follow-up, the same shape as
    /// `confirmDeleteTask`: the Tasks page's rows and both pages' editor
    /// sheets all land here, so none of them can ask differently or not ask.
    @discardableResult
    static func confirmDeleteFollowUp(id: String, store: ShiftStore, in view: NSView) -> Bool {
        guard let item = store.followUps.first(where: { $0.id == id }) else { return false }
        guard DestructiveConfirm.confirm(message: "Delete \u{201C}\(item.title)\u{201D}?",
                                         detail: "This follow-up is removed for good. This can't be undone.",
                                         confirmTitle: "Delete Follow-up",
                                         window: view.window) else { return false }
        store.deleteFollowUp(id: id)
        Toast.show(in: view, message: "\u{201C}\(item.title)\u{201D} deleted")
        return true
    }

    /// What clicking a completed task says. `updateTask` deliberately only
    /// touches `active.yaml`, so editing one from the Done column (or a struck
    /// through calendar chip) would silently save nothing - reopening it is
    /// the honest path, and saying so beats a sheet whose Save does nothing.
    static func showCompletedNotice(for done: ShiftTask) {
        HelmConfirm.notice(
            title: "\u{201C}\(done.title)\u{201D} is done",
            body: "Completed tasks are filed away and can't be edited in place. "
                + "Move it back to Backlog or In Progress to edit it.",
            symbol: "checkmark.circle.fill",
            hue: RailDestination.shift.domainHue)
    }
}
