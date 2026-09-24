// Grand Line - native macOS app.
//
// F22: what the compact popover's Today and Notes tabs actually say, derived
// from the app's real stores.
//
// **Separate from the views, and now-injectable, for one reason:** every
// string on those two tabs is a function of the clock ("overdue", "due
// today", "tomorrow"), and a view that reads `Date()` of its own cannot be
// asserted - AGENTS.md's own "a live-updating view reads its numbers from one
// injectable clock" convention, learned on F7. So the whole derivation is
// here, takes `now` as a parameter, returns value types, and is asserted by
// `FM_RUN_COMPACT_MODE_TESTS` in CI's blocking lane. The panes render what
// they are handed and compute nothing.
//
// The shapes mirror `PoneglyphQuickCode`'s own convention: a snapshot
// carrying no store reference, so a pane never holds a live object and GL-23
// stays true (one caching store, owned by the page that owns the data).

import AppKit

// MARK: - Today

/// One task row on the Today tab.
struct CompactTaskRow: Equatable {
    /// How the row reads, which is also which colour its checkbox takes.
    /// GL-14's own distinction applied to a due date: "late" and "soon" are
    /// different states and must not render the same.
    enum Urgency: Equatable {
        case overdue
        case today
        case later
    }

    let id: String
    let title: String
    /// The caption under the title - "overdue \u{00B7} 16 Sep", "due today
    /// \u{00B7} High", "tomorrow".
    let detail: String
    let urgency: Urgency
}

/// Everything the Today tab shows: its rows, and the two chips under them.
struct CompactTodayDigest: Equatable {
    let rows: [CompactTaskRow]
    /// The real overdue total, which is **not** `rows.filter { .overdue }.count`
    /// - `rows` is capped at `CompactModeDigest.maxRows`, and the status
    /// item's badge has to report the truth rather than what fitted in a
    /// popover.
    let overdueCount: Int
    /// "17:24 focus" - nil when no focus time has been logged today, which is
    /// a different state from "0:00 focus" and reads differently (GL-14).
    let focusChip: String?
    /// "2 follow-ups" - nil when there are none pending.
    let followUpChip: String?

    var isEmpty: Bool { rows.isEmpty }

    static let empty = CompactTodayDigest(rows: [], overdueCount: 0, focusChip: nil, followUpChip: nil)
}

// MARK: - Notes

/// One sticky-note row on the Notes tab.
struct CompactNoteRow: Equatable {
    let id: String
    /// The note's own title, or its first non-empty line when it has none -
    /// a sticky note is not required to have a title, and an untitled row
    /// showing nothing at all is useless.
    let title: String
    /// "3 of 5 done" for a checklist note, the note's own next lines
    /// otherwise, and "Empty note" when there is genuinely nothing.
    let detail: String
    /// The note's paper colour, so the row carries the same identity the
    /// board does. `StickyNoteColor.paperHex`, resolved by the pane.
    let color: StickyNoteColor
}

// MARK: - The derivation

enum CompactModeDigest {

    /// How many rows either tab shows before it stops.
    ///
    /// Five, not "all of them": this is a 330pt popover, and a captain with
    /// forty due tasks needs the next few plus a way into the real page - the
    /// same judgment `StrawHatMenuBarPopoverController` makes when it shows
    /// one reply section and a "+N more" note rather than a transcript.
    static let maxRows = 5

    /// The Today tab, from the tasks and follow-ups a `ShiftStore` holds.
    ///
    /// Ordering is deliberate and asserted: overdue first (oldest first,
    /// because the one that has been late longest is the one being asked
    /// about), then today, then everything later soonest-first. A task with
    /// no due date never appears - this tab answers "what is due", and a
    /// backlog item is not an answer to that.
    static func today(tasks: [ShiftTask],
                      followUps: [ShiftFollowUp],
                      focusSecondsToday: Int,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> CompactTodayDigest {
        let startOfToday = calendar.startOfDay(for: now)

        struct Dated {
            let task: ShiftTask
            let due: Date
            let urgency: CompactTaskRow.Urgency
        }

        let dated: [Dated] = tasks.compactMap { task in
            guard task.status != .completed, task.status != .cancelled else { return nil }
            guard let dueDay = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return nil }
            // Compared by *day*, not by instant: a task due today at 09:00
            // read at 17:00 is still "due today", not overdue. Using the
            // task's own time here would make the tab flip a row to red
            // mid-afternoon, which is not what "overdue" means anywhere else
            // in this app (`ShiftController`'s own list agrees).
            let dueStart = calendar.startOfDay(for: dueDay)
            let urgency: CompactTaskRow.Urgency
            if dueStart < startOfToday {
                urgency = .overdue
            } else if calendar.isDate(dueStart, inSameDayAs: startOfToday) {
                urgency = .today
            } else {
                urgency = .later
            }
            return Dated(task: task, due: dueStart, urgency: urgency)
        }

        func rank(_ urgency: CompactTaskRow.Urgency) -> Int {
            switch urgency {
            case .overdue: return 0
            case .today: return 1
            case .later: return 2
            }
        }

        let sorted = dated.sorted { a, b in
            if rank(a.urgency) != rank(b.urgency) { return rank(a.urgency) < rank(b.urgency) }
            if a.due != b.due { return a.due < b.due }
            // A stable last resort, so two tasks due the same day never swap
            // places between two opens of the same popover.
            return a.task.id < b.task.id
        }

        let rows = sorted.prefix(maxRows).map { entry in
            CompactTaskRow(id: entry.task.id,
                           title: entry.task.title,
                           detail: detail(for: entry.task, urgency: entry.urgency, due: entry.due,
                                          now: now, calendar: calendar),
                           urgency: entry.urgency)
        }

        let pending = followUps.filter { $0.status == .pending }.count

        return CompactTodayDigest(
            rows: Array(rows),
            overdueCount: dated.filter { $0.urgency == .overdue }.count,
            focusChip: focusSecondsToday > 0 ? "\(focusText(seconds: focusSecondsToday)) focus" : nil,
            followUpChip: pending > 0 ? "\(pending) follow-up\(pending == 1 ? "" : "s")" : nil)
    }

    /// The caption under one task title.
    ///
    /// Built from the injected `now` rather than through
    /// `ShiftDateFormatting.friendly`, which resolves "Today"/"Tomorrow"
    /// against the real clock - a suite pinning a fabricated instant would
    /// then measure two different clocks and read as a broken feature.
    private static func detail(for task: ShiftTask,
                               urgency: CompactTaskRow.Urgency,
                               due: Date,
                               now: Date,
                               calendar: Calendar) -> String {
        var parts: [String] = []
        switch urgency {
        case .overdue:
            parts.append("overdue \u{00B7} \(ShiftDateFormatting.monthDay(due))")
        case .today:
            parts.append("due today")
        case .later:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            if let tomorrow, calendar.isDate(due, inSameDayAs: tomorrow) {
                parts.append("tomorrow")
            } else {
                parts.append(ShiftDateFormatting.monthDay(due))
            }
        }
        // Only `high` earns a word. `normal` is the default on every task
        // `ShiftTask.fresh()` makes, so printing it would put the same noise
        // on every row and say nothing.
        if task.priority == .high { parts.append("High") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// `h:mm` of focus time, matching the mockup's own "17:24 focus" - which
    /// is minutes and seconds for a session under an hour, and reads as a
    /// clock either way.
    static func focusText(seconds: Int) -> String {
        let hours = seconds / 3600
        if hours > 0 {
            return String(format: "%d:%02d", hours, (seconds % 3600) / 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The Notes tab, from the notes a `StickyBoardStore` holds.
    ///
    /// Newest first. Archived notes never appear - the board's own
    /// `activeNotes` makes the same cut, and an archived note is something
    /// the captain has explicitly put away.
    static func notes(_ notes: [StickyNote]) -> [CompactNoteRow] {
        notes
            .filter { !$0.isArchived }
            .sorted { a, b in
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                return a.id < b.id
            }
            .prefix(maxRows)
            .map { note in
                CompactNoteRow(id: note.id,
                               title: noteTitle(note),
                               detail: noteDetail(note),
                               color: note.color)
            }
    }

    /// A sticky note's title is optional, so this falls back through the text
    /// before giving up - and gives up *visibly*, per GL-14: "Untitled note"
    /// is a state, not an empty string that renders as a blank row.
    static func noteTitle(_ note: StickyNote) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let first = firstNonEmptyLine(of: note.text) { return first }
        if let firstItem = note.checklist?.first(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return firstItem.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Untitled note"
    }

    static func noteDetail(_ note: StickyNote) -> String {
        if let checklist = note.checklist {
            let done = checklist.filter { $0.isDone }.count
            return "\(done) of \(checklist.count) done"
        }
        // The line *after* whatever became the title, so a row never prints
        // its own title twice.
        let lines = note.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let titleWasFromText = note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let remainder = titleWasFromText ? Array(lines.dropFirst()) : lines
        if remainder.isEmpty { return titleWasFromText && lines.isEmpty ? "Empty note" : "" }
        return remainder.joined(separator: " \u{00B7} ")
    }

    private static func firstNonEmptyLine(of text: String) -> String? {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
