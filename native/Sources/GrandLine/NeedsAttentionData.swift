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
// ## The rest of the mockup, which the visual overhaul brought in
//
// The first pass at this card deliberately left out the mockup's three other
// attention sources (the fleet, Claude usage, session checks) and its closing
// "Everything else is clear" strip, on the reading that they were a broader
// concept than the captain's ask and would mean new plumbing on a page whose
// first rule is that it never fetches anything.
//
// `fm/grandline-home-page-visual-overhaul` is the captain asking for the
// whole reference, and it turns out none of it needs plumbing: every one of
// those sources is **already pushed into `HomeCanvasController`** for a card
// it already draws - the fleet snapshot for the Fleet card, the quota reading
// for the Claude card, `BackgroundSignalsPoller.lastCounts` for the Setup
// cards, `ServiceHealthRegistry` for Health. So they arrive here the way this
// file was already shaped for: as `Item`s the caller built, each carrying its
// own source label, tone and action title. Nothing here reads anything.
//
// The one structural change that came with them is that this card is now the
// page's **hero as well as its list** - it carries the Refresh button and the
// fleet-freshness subline the hub's separate hero band used to, because the
// reference draws one card there and the app drew two. See
// `HomeCanvasController.renderAttention`.

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
        /// A row that is not a to-do: the fleet holding for a decision,
        /// Claude near its spend cap, a session check that has not run.
        ///
        /// It carries **no checkbox**, because there is nothing here to tick
        /// off - the state clears when the thing itself changes, not when the
        /// captain says it has. A checkbox that only hid the row until the
        /// next render would be a control that lies about what it did.
        case signal(Signal)

        /// Whether this row draws a checkbox. Asked by name rather than
        /// pattern-matched at the call site, so a second signal case cannot
        /// be added and quietly get one.
        var isSignal: Bool {
            if case .signal = self { return true }
            return false
        }
    }

    /// Which non-to-do source a `.signal` row came from.
    ///
    /// An enum rather than the row's `id`, so the host's "what does this
    /// row's button open" switch is exhaustive and a new source cannot be
    /// added without deciding where it goes. This file still imports nothing
    /// but Foundation - the mapping to a `RailDestination` belongs to the
    /// host, not here.
    enum Signal: String, Equatable {
        /// The fleet is holding for a decision, or is blocked.
        case fleet
        /// Claude's extra usage is at or near its spend cap.
        case claudeUsage
        /// This session's background checks have not run yet.
        case sessionChecks
    }

    /// The row's own tint. `HelmAccentRow` takes a `HelmTint` for its accent
    /// bar, its badge and its chip, and deriving it here rather than in the
    /// card keeps the tone-to-colour decision beside the tones themselves -
    /// the same split `NeedsAttentionSummary.tint` already uses for the
    /// header tile.
    var tint: HelmTint {
        switch tone {
        case .late: return .critical
        case .risk: return .warn
        case .dueToday, .info: return .info
        }
    }

    /// How urgent the row is, which drives the accent bar, the chip and
    /// whether the row gets §6.5's signal wash.
    ///
    /// The four match the reference's own four row tones, and they are
    /// ordered here worst-first because `NeedsAttentionSummary.State` is
    /// derived by taking the worst tone present.
    enum Tone: Equatable {
        /// Past its due day.
        case late
        /// Something is close to a limit and will become a problem if
        /// ignored - Claude's extra usage against its spend cap.
        case risk
        /// Due today and not yet late.
        case dueToday
        /// A fact the captain should know about, which nothing bad follows
        /// from - a session check that has not run yet.
        case info
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
    /// What this row contributes to the card's headline sentence, or `nil`
    /// to be counted collectively instead.
    ///
    /// Tasks and follow-ups are counted ("Two things are late"); a signal is
    /// named ("Claude is near its spend cap"), because a count of one
    /// unnamed thing tells the captain nothing. That is the reference's own
    /// split, and keeping the clause **on the item** is what stops the
    /// headline growing a `switch` over sources that would have to be
    /// updated every time a new one is pushed in.
    let headlineClause: String?

    init(id: String,
         kind: Kind,
         source: String,
         text: String,
         meta: String? = nil,
         chipText: String,
         tone: Tone,
         actionTitle: String,
         headlineClause: String? = nil) {
        self.id = id
        self.kind = kind
        self.source = source
        self.text = text
        self.meta = meta
        self.chipText = chipText
        self.tone = tone
        self.actionTitle = actionTitle
        self.headlineClause = headlineClause
    }
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
        /// Rows exist, none late, at least one close to a limit.
        case risk
        /// Rows exist, none late and none at risk.
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
    /// The reference's closing strip: one short phrase per source that was
    /// checked and is fine ("Fleet idle", "7/7 services healthy").
    ///
    /// It is the counterweight to the list above it, and it is the reason
    /// this card can be read as a *whole* answer rather than as a list of
    /// complaints: without it, a card showing one late task says nothing
    /// about whether the other four sources were even looked at, which is
    /// the same "unknown read as fine" gap GL-14 is about pointed the other
    /// way. Each phrase is only ever added by a caller that actually has the
    /// reading - a source that has not reported contributes nothing rather
    /// than a cheerful line.
    var clearNotes: [String]

    /// The SF Symbol for the header tile.
    var symbol: String {
        switch state {
        case .allClear: return "checkmark.circle.fill"
        case .late, .risk: return "exclamationmark.triangle.fill"
        case .dueToday: return "clock.fill"
        case .unavailable: return "exclamationmark.shield"
        }
    }

    /// The header tile's tint - the mockup's green / red / amber / blue.
    var tint: HelmTint {
        switch state {
        case .allClear: return .good
        case .late: return .critical
        case .risk: return .warn
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

    /// The whole card, from the day's digest plus whatever else the hub
    /// already knows.
    ///
    /// - Parameters:
    ///   - extra: the non-to-do attention rows the caller built from state it
    ///     already holds - the fleet holding for a decision, Claude near its
    ///     spend cap, session checks that have not run. Appended **after** the
    ///     tasks and follow-ups, which is the reference's own order: what the
    ///     captain personally owes comes before what a machine is reporting.
    ///   - clear: the closing strip's phrases. See
    ///     `NeedsAttentionSummary.clearNotes`.
    ///   - allClearHeadline: the sentence for a card with nothing on it.
    ///     Passed in rather than written here so the hub can hand over
    ///     `FleetGreeting.Answer.title` - the app already has one all-clear
    ///     sentence, and this card taking over the hero's job must not
    ///     introduce a second one that can disagree with it.
    static func summary(from digest: DailyReviewDigest,
                        extra: [NeedsAttentionItem] = [],
                        clear: [String] = [],
                        allClearHeadline: String = "Nothing is due, and nobody is waiting on you.")
        -> NeedsAttentionSummary {
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

        items.append(contentsOf: extra)

        let gaps = digest.gaps.filter { ownedGapSections.contains($0.section) }
        let hidden = digest.hiddenDueTaskCount + digest.hiddenFollowUpCount
        let lateCount = items.filter { $0.tone == .late }.count

        let state: NeedsAttentionSummary.State
        if !items.isEmpty {
            // Worst tone wins, which is why `Tone`'s cases are declared
            // worst-first. A single late task must not be softened to
            // "due today" by three calm signals sitting beside it.
            if lateCount > 0 {
                state = .late
            } else if items.contains(where: { $0.tone == .risk }) {
                state = .risk
            } else if items.contains(where: { $0.tone == .dueToday }) {
                state = .dueToday
            } else {
                state = .dueToday
            }
        } else if !gaps.isEmpty {
            state = .unavailable
        } else {
            state = .allClear
        }

        return NeedsAttentionSummary(
            state: state,
            eyebrow: eyebrow(state: state, openCount: items.count),
            headline: headline(state: state,
                               items: items,
                               hidden: hidden,
                               allClearHeadline: allClearHeadline),
            items: items,
            overflowNote: hidden > 0 ? "+\(hidden) more in Tasks" : nil,
            gaps: gaps,
            clearNotes: clear)
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
        case .late, .risk, .dueToday: return "Needs attention, \(openCount)"
        }
    }

    /// The one sentence under the eyebrow.
    ///
    /// It is built from **clauses joined with ", and "**, which is the
    /// reference's own construction and the only shape that survives four
    /// independent sources: what is late is counted, what is a named signal
    /// is named, and what is merely due follows both.
    ///
    /// `DailyReviewComposer.spelled` rather than a second number-word table -
    /// the two cards say "Two things" the same way or they read as two apps.
    static func headline(state: NeedsAttentionSummary.State,
                         items: [NeedsAttentionItem],
                         hidden: Int,
                         allClearHeadline: String) -> String {
        switch state {
        case .allClear:
            return allClearHeadline
        case .unavailable:
            // GL-14: the reason itself is rendered as its own row, so this
            // line only has to avoid claiming an all-clear it cannot stand
            // behind.
            return "Some of your day could not be read."
        case .late, .risk, .dueToday:
            break
        }

        // Only the counted tones take the hidden overflow: it comes from the
        // digest's own caps on tasks and follow-ups, and adding it to a
        // signal count would claim more signals than were pushed in.
        let lateCount = items.filter { $0.tone == .late }.count
        let dueCount = items.filter { $0.tone == .dueToday }.count + hidden
        let infoCount = items.filter { $0.tone == .info }.count

        var clauses: [String] = []
        if lateCount > 0 {
            clauses.append("\(DailyReviewComposer.spelledCapitalised(lateCount)) "
                + "\(DailyReviewComposer.plural(lateCount, "thing")) "
                + "\(lateCount == 1 ? "is" : "are") late")
        }
        // Named signals, in list order, so the sentence reads in the same
        // order the rows below it do.
        clauses.append(contentsOf: items.compactMap(\.headlineClause))

        if dueCount > 0 {
            if clauses.isEmpty {
                clauses.append("\(DailyReviewComposer.spelledCapitalised(dueCount)) "
                    + "\(DailyReviewComposer.plural(dueCount, "thing")) "
                    + "\(dueCount == 1 ? "is" : "are") due today")
            } else {
                clauses.append("\(DailyReviewComposer.spelled(dueCount)) more "
                    + "\(dueCount == 1 ? "is" : "are") due today")
            }
        }

        if clauses.isEmpty {
            // Info-only: nothing is late, nothing is at risk, nothing is due.
            // The count is of checks that have not run, which is exactly the
            // reference's fallback sentence.
            let count = max(infoCount, 1)
            return "\(DailyReviewComposer.spelledCapitalised(count)) "
                + "\(DailyReviewComposer.plural(count, "check")) "
                + "\(count == 1 ? "is" : "are") waiting."
        }

        // The first clause is already capitalised; the rest are not, which is
        // what makes ", and " read as prose rather than as a list of titles.
        return clauses.joined(separator: ", and ") + "."
    }
}
