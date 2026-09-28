// Grand Line - native macOS app.
//
// The pure half of the Home page's **Needs Attention** card.
// `NeedsAttentionCard.swift` owns how it looks; this file owns what it says.
//
// ## Why this exists, and why it is not a second reading of the stores
//
// The captain asked for the Today page's "Due today" and "Follow-ups"
// sections to move to Home, under one "Needs attention" section. The obvious
// way to do that is to read `ShiftStore` again on the Home page and re-derive
// what is due - and that would be a second definition of "due", which is the
// exact mistake B22 spent a whole task collapsing (`ShiftDue.isOverdue` is one
// function because a date-only task used to read as overdue at local midnight
// on one surface and not until the next day on another).
//
// So this composer's input is a **`DailyReviewDigest`** - the same digest the
// Today page's card renders, from the same `DailyReviewComposer`, including
// its caps, its ordering, its `ShiftDue` overdue predicate and its stated
// gaps. Nothing here reads a store, a date or a clock. What it owns is the
// one thing the digest does not already decide: how the rows read when they
// are a flat attention list rather than two labelled columns.
//
// ## The wording, and where it comes from
//
// The captain's reference mockup words a row's chip as "Overdue 5 days, since
// 23 Sep" and "Due today", and its headline as one plain-English sentence
// ("Two things are late."). `DailyReviewComposer.headline` is a *different*
// sentence - it counts the calendar too, because it introduces a whole daily
// review - so this file has its own, built from the same
// `DailyReviewComposer.spelled` number words rather than a second spelling
// table.
//
// ## What is deliberately not here
//
// The mockup additionally shows Claude usage and session checks as attention
// rows, and a closing "Everything else is clear" strip. Those are a broader
// "everything needing attention" concept than the captain's ask, and building
// them would mean new plumbing on a page whose first rule is that it never
// fetches anything (`HomeCanvasController`'s file header). The shape here is
// open to them - `Item` carries its own source label, tone and action title
// rather than hard-coding "Task" - but nothing fabricates them today.

import Foundation

/// One row of the attention list.
///
/// Deliberately not a `DailyReviewTaskRow`/`DailyReviewFollowUpRow` union: the
/// card draws one row shape, and a view that switches on which of two record
/// types it was handed is how the two drift apart. The differences that
/// survive are the three fields that genuinely differ - the source label, the
/// action's verb, and which store the checkbox writes to.
struct NeedsAttentionItem: Equatable {

    /// Which store a completed checkbox writes to, and nothing else. The card
    /// never branches on this for layout.
    enum Kind: Equatable {
        case task
        case followUp
    }

    /// How urgent the row is, which drives the accent bar, the chip and
    /// whether the row gets §6.5's signal wash.
    enum Tone: Equatable {
        /// Past its due day.
        case late
        /// Due today and not yet late.
        case dueToday
    }

    let id: String
    let kind: Kind
    /// The small all-caps label above the title - "Task", "Follow-up".
    /// Rendered uppercase by `HelmAccentRow`, so it is stored in sentence
    /// case.
    let source: String
    /// The row's own text: the task or follow-up title.
    let text: String
    /// The quieter line under it - a task's "RaaS Migration · High", or a
    /// follow-up's "today 3:00 PM". `nil` when there is nothing to add.
    let meta: String?
    /// "Overdue 5 days, since 23 Sep" / "Due today".
    let chipText: String
    let tone: Tone
    /// The trailing button's verb - "Start" for a task, "Open" for a
    /// follow-up, matching the mockup.
    let actionTitle: String
}

/// Everything the card paints. The card holds no counting, no pluralisation
/// and no branching on which sections were readable.
struct NeedsAttentionSummary: Equatable {

    /// The card's overall mood - its icon, its icon tint and its eyebrow.
    enum State: Equatable {
        /// Nothing is due and nothing is waiting, and both sources were
        /// readable. The only state that may say so.
        case allClear
        /// At least one row is past its due day.
        case late
        /// Rows exist, none of them late.
        case dueToday
        /// A source could not be read, and there is nothing else to report.
        /// GL-14: distinct from `allClear`, and never drawn as one.
        case unavailable
    }

    var state: State
    /// "Needs attention, 2" / "All clear" / "Not available".
    var eyebrow: String
    /// One plain-English line: "Two things are late.",
    /// "Nothing is due, and nobody is waiting on you."
    var headline: String
    var items: [NeedsAttentionItem]
    /// The digest's own stated overflow, as one line - "+3 more in Tasks".
    /// `nil` when the digest carried everything.
    var overflowNote: String?
    /// The stated gaps this card is responsible for - the Tasks and
    /// Follow-ups sections only. The Today page keeps the other three.
    var gaps: [DailyReviewGap]

    /// The SF Symbol for the header tile.
    var symbol: String {
        switch state {
        case .allClear: return "checkmark.circle.fill"
        case .late: return "exclamationmark.triangle.fill"
        case .dueToday: return "clock.fill"
        case .unavailable: return "exclamationmark.shield"
        }
    }

    /// The header tile's tint - the mockup's green / red / blue / amber.
    var tint: HelmTint {
        switch state {
        case .allClear: return .good
        case .late: return .critical
        case .dueToday: return .info
        case .unavailable: return .warn
        }
    }
}

/// The pure composer. No store, no `Date()`, no `NSView`.
enum NeedsAttentionComposer {

    /// The digest sections this card takes over from the Today page. Named
    /// once, because both this file and `DailyReviewCard` filter on them and
    /// two spellings of "Follow-ups" would silently drop a stated gap.
    static let ownedGapSections: Set<String> = ["Tasks", "Follow-ups"]

    static func summary(from digest: DailyReviewDigest) -> NeedsAttentionSummary {
        var items: [NeedsAttentionItem] = []

        for task in digest.dueTasks {
            items.append(NeedsAttentionItem(
                id: task.id,
                kind: .task,
                source: "Task",
                text: task.title,
                meta: task.meta.isEmpty ? nil : task.meta,
                chipText: chipText(isOverdue: task.isOverdue,
                                   days: task.overdueDays,
                                   dayText: task.dueDayText),
                tone: task.isOverdue ? .late : .dueToday,
                actionTitle: "Start"))
        }

        for item in digest.followUps {
            items.append(NeedsAttentionItem(
                id: item.id,
                kind: .followUp,
                source: "Follow-up",
                text: item.title,
                // A follow-up's `whenText` restates the chip once it is
                // overdue ("overdue since 23 Sep" beside "Overdue 5 days,
                // since 23 Sep"), so it is carried only where it says
                // something the chip does not - the time of day.
                meta: item.isOverdue ? nil : item.whenText,
                chipText: chipText(isOverdue: item.isOverdue,
                                   days: item.overdueDays,
                                   dayText: item.dueDayText),
                tone: item.isOverdue ? .late : .dueToday,
                actionTitle: "Open"))
        }

        let gaps = digest.gaps.filter { ownedGapSections.contains($0.section) }
        let hidden = digest.hiddenDueTaskCount + digest.hiddenFollowUpCount
        let lateCount = items.filter { $0.tone == .late }.count

        let state: NeedsAttentionSummary.State
        if !items.isEmpty {
            state = lateCount > 0 ? .late : .dueToday
        } else if !gaps.isEmpty {
            state = .unavailable
        } else {
            state = .allClear
        }

        return NeedsAttentionSummary(
            state: state,
            eyebrow: eyebrow(state: state, openCount: items.count),
            headline: headline(state: state, lateCount: lateCount, total: items.count + hidden),
            items: items,
            overflowNote: hidden > 0 ? "+\(hidden) more in Tasks" : nil,
            gaps: gaps)
    }

    // MARK: The words

    /// "Overdue 5 days, since 23 Sep" / "Due today".
    ///
    /// Digits rather than `spelled` words here on purpose: a chip is a
    /// measurement, and the mockup draws it in the same tabular voice as every
    /// other number on the page. The headline is the prose.
    static func chipText(isOverdue: Bool, days: Int, dayText: String) -> String {
        guard isOverdue else { return "Due today" }
        // A task that became overdue earlier *today* (a due time that has
        // passed) is zero days late, and "Overdue 0 days" is nonsense - it is
        // late since a time today, which "Overdue today" says without
        // pretending to a day count.
        guard days > 0 else { return "Overdue today" }
        return "Overdue \(days) \(days == 1 ? "day" : "days"), since \(dayText)"
    }

    static func eyebrow(state: NeedsAttentionSummary.State, openCount: Int) -> String {
        switch state {
        case .allClear: return "All clear"
        case .unavailable: return "Not available"
        case .late, .dueToday: return "Needs attention, \(openCount)"
        }
    }

    /// The one sentence under the eyebrow.
    ///
    /// `DailyReviewComposer.spelled` rather than a second number-word table -
    /// the two cards say "Two things" the same way or they read as two apps.
    static func headline(state: NeedsAttentionSummary.State, lateCount: Int, total: Int) -> String {
        switch state {
        case .allClear:
            return "Nothing is due, and nobody is waiting on you."
        case .unavailable:
            // GL-14: the reason itself is rendered as its own row, so this
            // line only has to avoid claiming an all-clear it cannot stand
            // behind.
            return "Some of your day could not be read."
        case .late, .dueToday:
            break
        }

        let onTime = max(0, total - lateCount)
        if lateCount == 0 {
            return "\(DailyReviewComposer.spelledCapitalised(total)) "
                + "\(DailyReviewComposer.plural(total, "thing")) \(total == 1 ? "is" : "are") due today."
        }
        let late = "\(DailyReviewComposer.spelledCapitalised(lateCount)) "
            + "\(DailyReviewComposer.plural(lateCount, "thing")) \(lateCount == 1 ? "is" : "are") late"
        if onTime == 0 { return "\(late)." }
        return "\(late), and \(DailyReviewComposer.spelled(onTime)) more "
            + "\(onTime == 1 ? "is" : "are") due today."
    }
}
