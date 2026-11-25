// Grand Line - native macOS app.
//
// The New Task and Edit Task sheet's preview words, for TK-1 "Record preview
// sheet" on the hero restyle board (`data/grandline-hero-restyle-designs-scout/`).
//
// Pure, Foundation only, so `ReviewUIUXSelfTest` asserts it in CI's blocking
// lane. The sheet's own words (the placeholder, the tip, the Detected line,
// the section names and the footer) are unchanged and stay in
// `ShiftTaskEditorController.swift`.
//
// **The preview reads the task Save would write, not the fields.** The
// header is the task's card as the board will draw it, so every word here is
// derived from a `ShiftTask` the sheet assembles exactly as Save does. The
// one rule the sheet applies on the way (review U16: a detected date phrase
// leaves the title once it has become the due date) lives here as
// `savedTitle`, and Save calls the same function, so the preview and the
// saved title cannot drift apart.

import Foundation

enum TaskHeroWords {

    // MARK: Kicker

    /// A task that does not exist yet.
    static let newKicker = "New task \u{00B7} not saved yet"
    /// The edit kicker's first half.
    static let editKicker = "Edit task"
    /// The Tasks page's board view, as its tab names it.
    static let boardName = "Board"

    /// "New task · not saved yet" for a new task, and "Edit task · Board ›
    /// In Progress" for one already on the board, naming its real column. A
    /// status the board has no column for (cancelled) says only "Edit task".
    static func kicker(editing status: ShiftTaskStatus?) -> String {
        guard let status else { return newKicker }
        guard let column = ShiftBoardColumn.column(for: status) else { return editKicker }
        return "\(editKicker) \u{00B7} \(boardName) \u{203A} \(column.title)"
    }

    // MARK: Title

    /// What the card shows, in a quieter italic, before anything is typed.
    /// The title field's own placeholder, so the two say the same thing.
    static let titlePlaceholder = "What needs to be done?"

    /// The title as Save will write it (review U16).
    ///
    /// While a detected phrase is still in force (the captain has not
    /// dismissed it or taken the date over by hand) and the task has a due
    /// date, the phrase comes out of the title. Otherwise the typed title,
    /// trimmed. `ShiftDateParser.titleWithoutDatePhrase` keeps a title that
    /// was nothing but the date.
    static func savedTitle(_ typed: String, detected: ShiftParsedDate?, hasDueDate: Bool) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasDueDate, let detected else { return trimmed }
        return ShiftDateParser.titleWithoutDatePhrase(trimmed, parsed: detected)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Card

    static let noDate = "No date"
    static let noProject = "No project"

    /// The card's second line: when, then which project. "Tomorrow at 3:00
    /// PM · Grand Line", or "No date · No project" for a bare task. The date
    /// is worded as the Detected line under the title field words it.
    static func subtitle(dueDate: String?, dueTime: String?, projectName: String?) -> String {
        let when = dueDate.map { ShiftDateFormatting.friendly($0, time: dueTime) } ?? noDate
        return "\(when) \u{00B7} \(projectName ?? noProject)"
    }

    /// The badge beside the title. Only High earns one, as on the board's
    /// card, where Normal says nothing and High is the red signal.
    static func badge(for priority: ShiftPriority) -> String? {
        priority == .high ? "High" : nil
    }

    // MARK: Facts

    /// The facts under the card, in the board's order: the priority, the
    /// project, the repeat rule and the reminder when the task has them,
    /// then every tag.
    ///
    /// The repeat and the reminder are read off the task Save would write,
    /// which has already dropped a rule or a reminder with no date to anchor
    /// on. "No reminder" is how the When panel words a task without one, so
    /// such a task gets no reminder fact. The reminder is worded as the
    /// panel's Remind menu words it, which says the clock time for a task
    /// with no time of its own.
    static func facts(for task: ShiftTask, projectName: String?, allDayReminderAt: String) -> [String] {
        var facts = ["\(task.priority.rawValue.capitalized) priority", projectName ?? noProject]
        if let rule = task.recurrence { facts.append(rule.displayName) }
        if let minutes = task.reminderMinutesBefore {
            let label = ShiftReminderOffset.label(for: minutes, allDayAt: task.dueTime == nil ? allDayReminderAt : nil)
            facts.append("Remind \(lowercasingFirst(label))")
        }
        facts += task.tags.map { "#" + $0 }
        return facts
    }

    /// "At the due time" reads "Remind at the due time" after the verb. The
    /// rest is converted explicitly, because the CI compiler rejects a
    /// `String + Substring` the local one accepts (AGENTS.md's Toolchain).
    private static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        return first.lowercased() + String(text.dropFirst())
    }
}
