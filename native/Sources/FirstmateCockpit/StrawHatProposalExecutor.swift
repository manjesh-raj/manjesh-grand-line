// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates: the one place a crew proposal becomes a real store write
// (the plan's milestone M2.2, second half), plus phase 3's three new kinds
// and the structural refusal that keeps a navigation handoff off this path
// entirely (M3.1 / M3.2).
//
// ## Confirm-only, and what that actually means here
//
// Nothing in this file runs until the captain clicks a confirm card's button.
// That is not a policy this file enforces with a flag - it is the shape of
// the code: `execute` is only reachable from a `HelmButton` action, there is
// no automatic path from `StrawHatEnvelope.parse` to here, and
// `StrawHatSelfTest` asserts that a parsed reply on its own writes nothing.
//
// Combined with `StrawHatProposalKind` being a closed enum, that gives the
// property the whole feature rests on: **a model cannot write to the
// captain's stores.** It can only ever hand the app a value from a fixed
// vocabulary, which the app renders as a button, which a human presses. The
// enum stops an invented `kind`; the confirm card stops an unwanted one.
//
// ## One kind gets a second gate, and exactly one
//
// `CommandRiskConfirmation.confirmAIAuthored` exists because an AI-authored
// *shell command* can do anything. Five of the six writes here are bounded
// and reversible by hand - a task, a follow-up, a markdown file, a sticky
// note, a schedule built out of six pre-approved actions - so for those the
// confirm card *is* the gate, and stacking a second modal on a button the
// captain deliberately pressed would be the "a palette is a faster way to
// reach an action, never a way around its confirmation" rule applied
// backwards: no faster path is being taken.
//
// **`save_command_draft` is the exception, and it is not optional.** A saved
// command's own `CommandRiskLevel` is a record of a human having read the
// text and vouched for it, and every *later* send (the detail pane, the
// command palette, F9's multi-host fan-out) reads that stored level instead
// of asking again - which is exactly how audit #2 section 5.3 found a
// `readOnly` command whose template a model had rewritten reaching a
// terminal with no confirmation at all. So a crew-authored command goes
// through the same two halves that finding installed one store over:
//
//  1. `confirmAIAuthored(... intent: .saveTemplate)` - the captain reads the
//     model's actual shell text and lets it into their library, or does not.
//  2. The stored risk is `heuristicRisk(of:)`, **never** anything the model
//     said (`StrawHatProposal` carries no risk field at all, deliberately),
//     and that function never answers `.readOnly` - so no crew-authored
//     command can ever be stale-low at a later sink.
//
// Because that gate is a modal, this file splits the kind the way
// `CommandLibraryPageView` splits its own: `execute` confirms and
// `commitCommandDraft` writes. A headless suite drives the write directly for
// *behaviour* and a source guard asserts the *routing* - the write being
// correct proves nothing about the gate still being in front of it.
//
// ## A navigation kind is refused here, structurally
//
// `open_sre_lead` / `open_destination` write nothing, so they never travel
// this path: the chat view renders them as link rows and runs them through
// its own handoff closure. `execute` refuses one outright rather than falling
// through to a default, so even a view that mis-rendered a handoff as a
// confirm card could not turn a press into a write.
//
// ## Four kinds route through an existing editor instead, and never reach
// `execute` at all
//
// `fm/straw-hat-task-proposal-full-editor`: `execute`'s `addTask` used to
// build a `ShiftTask` straight from the proposal and write it - no priority,
// no project, no tags, because the model was never asked for any of them and
// the captain never got a chance to set them either. That is honest ("nothing
// invented") but it is not what the captain wants: a task/follow-up/command/
// schedule draft each has a real "New X" sheet elsewhere in the app exposing
// strictly more fields than a proposal carries, so `StrawHatController.
// confirmProposal` opens that same sheet, pre-filled, for `.addTask`,
// `.addFollowUp`, `.saveCommandDraft` and `.createScheduleDraft`
// (`StrawHatProposalKind.opensEditor`) - and never calls `execute` for them at
// all, because the write that happens once the captain reviews and presses
// that sheet's own Save must use *their* edited values, not a fresh
// re-derivation from the original proposal.
//
// `execute`'s own branches for those four kinds are therefore untouched on
// purpose (see the file's own tests, which still drive them directly) rather
// than deleted: they remain the honest "what would this look like with
// nothing added" reference this file's header always described, now reachable
// only from a test calling `execute` directly, never from the confirm-card
// flow. `createRunbookDraft` and `addSticky` are the two kinds `execute` still
// serves in production - see `opensEditor`'s own doc comment for why neither
// has an equivalent dialog to route through instead.
//
// ## Undo: real for four kinds, deliberately absent for two
//
// GL-33's rule is that `onUndo` must restore the value the caller already had
// in hand - which is why AGENTS.md records it as *not* wired to an SSH key
// delete, where the private bytes are gone and an "Undo" producing a
// key-shaped shell would be a lie.
//
// The same test splits these six:
//
//  - `create_runbook_draft` **gets a real undo.** `DocsRunbookStore.
//    deleteRunbook(id:)` exists and the created runbook's id is in hand, so
//    the undo genuinely removes the file it just wrote.
//  - `add_sticky` **gets one too** - `StickyBoardStore.deleteNote(id:)`
//    returns the note it removed and `restoreNote(_:)` puts it back, which is
//    the same pair that page's own delete-with-undo already uses.
//  - `create_schedule_draft` **gets one** - `ScheduleStore.delete(id:)` plus
//    the schedule's own id, both in hand.
//  - `save_command_draft` **gets one** - `CommandLibraryStore.deleteCommand(id:)`
//    removes the file it just wrote.
//  - `add_task` / `add_follow_up` get a **plain toast, no undo.** `ShiftStore`
//    has no delete method for either (checked - it has `add`, `update`,
//    `setTaskCompleted`, `setFollowUpStatus`, `snooze`, and no remove), so an
//    "Undo" here could only pretend. Adding a real Shift delete is a genuine
//    new capability across that store, its YAML layer, its git sync and its
//    conflict resolver - well outside a phase whose job is the crew - and a
//    half-implemented one (mark it done? clear its title?) would be worse
//    than the honest confirmation the captain gets instead. The card's own
//    confirmed state names where the record went, so it is one click away on
//    the Tasks page.

import Foundation

/// What a confirmed proposal did, so the caller can phrase the toast and wire
/// the right undo without re-deriving the proposal's kind.
enum StrawHatProposalOutcome {
    /// Written. `undo` is non-nil only when it genuinely removes the record -
    /// see this file's header.
    case written(message: String, undo: (() -> Void)?)
    /// The store refused, or the write could not be attempted. Surfaced to the
    /// captain rather than swallowed: they pressed a button and are owed an
    /// answer either way.
    case failed(message: String)
    /// The proposal's own kind opens an existing editor for the captain to
    /// review before anything is written (`StrawHatProposalKind.opensEditor`)
    /// - never returned by `execute` itself, only by
    /// `StrawHatController.openEditorForReview`, which intercepts those four
    /// kinds before they would otherwise reach here. The real write, if the
    /// captain goes through with it, happens inside that editor's own Save
    /// action, entirely independent of this outcome.
    case openedForReview(message: String)
}

enum StrawHatProposalExecutor {

    /// Performs one confirmed proposal. Main thread only (it touches stores
    /// every view on this page also reads).
    ///
    /// Every store one of the six write kinds can reach, handed over by the
    /// page rather than constructed here.
    ///
    /// A struct rather than six parameters because `execute` is called from
    /// one place with all of them and the list is only going to grow; and
    /// taken as values for the reason `StrawHatContextSnapshot.capture` does
    /// the same - a file that constructs its own store both duplicates that
    /// store's root precedence (which drifts) and can reach the captain's real
    /// git-synced clone from a self-test.
    ///
    /// `docs` is optional because `FleetController` resolves its own
    /// `DocsRunbookStore` and that can legitimately be unavailable; a runbook
    /// proposal in that state fails with a real message rather than silently
    /// doing nothing. The other three are shared instances, not per-page ones,
    /// and that distinction is load-bearing rather than stylistic: all three
    /// **cache and write** the same file, so a second instance would be a
    /// second writer racing the page's own (GL-23's lesson - and for the
    /// Sticky Board specifically, its 1.5s write debounce means the board's
    /// next flush would overwrite a note this file had just added).
    struct Stores {
        let shift: ShiftStore
        let docs: DocsRunbookStore?
        let sticky: StickyBoardStore?
        let commands: CommandLibraryStore?
        let schedules: ScheduleStore?

        init(shift: ShiftStore, docs: DocsRunbookStore? = nil,
             sticky: StickyBoardStore? = nil, commands: CommandLibraryStore? = nil,
             schedules: ScheduleStore? = nil) {
            self.shift = shift
            self.docs = docs
            self.sticky = sticky
            self.commands = commands
            self.schedules = schedules
        }
    }

    static func execute(_ proposal: StrawHatProposal,
                        stores: Stores,
                        now: Date = Date()) -> StrawHatProposalOutcome {
        dispatchPrecondition(condition: .onQueue(.main))

        // A handoff writes nothing and must never reach a store path. Refused
        // here rather than left to a `default:` so this stays true even if the
        // view one day rendered one as a confirm card by mistake - see this
        // file's header.
        guard !proposal.kind.isNavigation else {
            AppLog.ai.error("straw hat: a navigation proposal reached the write path and was refused")
            return .failed(message: "That was a link, not something to save - nothing was written.")
        }

        switch proposal.kind {
        case .addTask:
            return addTask(proposal, shift: stores.shift, now: now)
        case .addFollowUp:
            return addFollowUp(proposal, shift: stores.shift, now: now)
        case .createRunbookDraft:
            return createRunbookDraft(proposal, docs: stores.docs)
        case .addSticky:
            return addSticky(proposal, sticky: stores.sticky, now: now)
        case .saveCommandDraft:
            return saveCommandDraft(proposal, commands: stores.commands)
        case .createScheduleDraft:
            return createScheduleDraft(proposal, schedules: stores.schedules, now: now)
        case .openSRELead, .openDestination:
            // Unreachable - the guard above already refused it. Kept explicit
            // rather than folded into a `default:` so adding a kind is a
            // compile error here, which is half of what makes the enum the
            // security mechanism.
            return .failed(message: "That was a link, not something to save - nothing was written.")
        }
    }

    // MARK: The six write kinds

    private static func addTask(_ proposal: StrawHatProposal,
                                shift: ShiftStore,
                                now: Date) -> StrawHatProposalOutcome {
        // `ShiftTask.fresh()` is the same starting point the New Task sheet
        // uses, so a crew-created task is indistinguishable from a
        // hand-created one - same id shape, same defaults, same `createdAt`.
        // Nothing here sets a priority or a project: the model was not asked
        // for either, and defaulting them would be the app inventing a
        // decision the captain never made.
        var task = ShiftTask.fresh(now: now)
        task.title = proposal.title
        if let notes = proposal.notes { task.notes = notes }
        if let due = proposal.resolvedDue(now: now) {
            task.dueDate = due.date
            task.dueTime = due.time
        }
        shift.addTask(task)
        AppLog.ai.info("straw hat: captain confirmed a task proposal")
        return .written(message: "Added \u{201C}\(proposal.title)\u{201D} to Tasks", undo: nil)
    }

    private static func addFollowUp(_ proposal: StrawHatProposal,
                                    shift: ShiftStore,
                                    now: Date) -> StrawHatProposalOutcome {
        var followUp = ShiftFollowUp.fresh()
        followUp.title = proposal.title
        if let notes = proposal.notes { followUp.notes = notes }
        if let due = proposal.resolvedDue(now: now) {
            followUp.followUpAt = due.date
            followUp.followUpTime = due.time
        }
        shift.addFollowUp(followUp)
        AppLog.ai.info("straw hat: captain confirmed a follow-up proposal")
        return .written(message: "Added \u{201C}\(proposal.title)\u{201D} to Follow-ups", undo: nil)
    }

    private static func createRunbookDraft(_ proposal: StrawHatProposal,
                                           docs: DocsRunbookStore?) -> StrawHatProposalOutcome {
        guard let docs else {
            return .failed(message: "I couldn't reach your runbooks folder, so there was nowhere to save that.")
        }
        guard let body = proposal.content, !body.isEmpty else {
            // `StrawHatEnvelope` already refuses a bodyless runbook draft, so
            // this is unreachable from a parsed reply - kept because this
            // function is `internal` and an empty file in the captain's
            // git-synced docs folder is not a failure worth being subtle
            // about.
            return .failed(message: "That draft had no content, so there was nothing to save.")
        }

        // A runbook's own `# Title` heading is what `DocsRunbookStore` reads
        // the display title back out of (`titleFromContent`), so a draft whose
        // body does not open with one would land in the list under its slug
        // instead of the title the crew proposed.
        let content = body.hasPrefix("# ") ? body : "# \(proposal.title)\n\n\(body)"
        let runbook = docs.createRunbook(title: proposal.title, content: content)
        AppLog.ai.info("straw hat: captain confirmed a runbook draft")
        return .written(message: "Saved \u{201C}\(runbook.title)\u{201D} to Runbooks", undo: {
            docs.deleteRunbook(id: runbook.id)
        })
    }

    // MARK: Phase 3 (M3.1)

    /// Usopp's kind: a captured idea on the corkboard.
    ///
    /// Everything about the note except its words is the app's decision, not
    /// the model's - position, colour and tilt are exactly what the board's
    /// own "New Note" button would have chosen, through the same
    /// `StickyBoardMetrics.cascadeOrigin` (extracted for this) so a proposed
    /// note lands in the next free slot rather than stacked under an existing
    /// one at the origin.
    ///
    /// The colour is deliberately random, matching that button: a model
    /// picking one would be reading meaning into six paper colours that carry
    /// none, and `StickyNoteColor` is a paper stock rather than a status.
    private static func addSticky(_ proposal: StrawHatProposal,
                                  sticky: StickyBoardStore?,
                                  now: Date) -> StrawHatProposalOutcome {
        guard let sticky else {
            return .failed(message: "I couldn't reach your Sticky Board, so there was nowhere to pin that.")
        }
        // The board is written by two owners now (its own page and this), and
        // that page caches its notes in memory - so a stale in-memory array
        // here would drop whatever the captain typed on the board itself.
        // Reading first is what makes the cascade index right, too.
        sticky.reloadAll()
        let origin = StickyBoardMetrics.cascadeOrigin(index: sticky.notes.count)
        let note = sticky.addNote(
            title: proposal.title,
            text: proposal.notes ?? "",
            color: StickyNoteColor.allCases.randomElement() ?? .yellow,
            x: Double(origin.x), y: Double(origin.y),
            rotationDegrees: Double.random(in: -4...4), now: now)
        // The board's own writes are debounced 1.5s; a confirmed proposal is a
        // deliberate one-shot act, so it goes to disk now rather than sitting
        // in memory until a timer the captain cannot see fires.
        sticky.flushPendingWrite()
        AppLog.ai.info("straw hat: captain confirmed a sticky note proposal")
        return .written(message: "Pinned \u{201C}\(proposal.title)\u{201D} to the Sticky Board", undo: {
            // The same pair the board's own delete-with-undo uses.
            guard let removed = sticky.deleteNote(id: note.id) else { return }
            _ = removed
            sticky.flushPendingWrite()
        })
    }

    /// Zoro's kind, and the one with a second gate in front of it.
    ///
    /// **`execute` is not the caller** - see this file's header. The gate is
    /// `saveCommandDraft` below, and this is only the write, split out so a
    /// headless suite can drive it (an `NSAlert.runModal()` cannot be answered
    /// from one).
    ///
    /// `internal` rather than private for exactly that reason, and
    /// `StrawHatSelfTest` carries a source guard that it has exactly one
    /// production caller and that the caller confirms first.
    static func commitCommandDraft(_ proposal: StrawHatProposal,
                                   command: String,
                                   commands: CommandLibraryStore) -> StrawHatProposalOutcome {
        // Never `.readOnly`, and never anything the model said: `heuristicRisk`
        // is coarse on purpose and its floor is `.potentiallyDisruptive`, so a
        // crew-authored command cannot be stale-low at a later sink. Audit #2
        // section 5.3 is the finding this implements.
        let risk = CommandRiskConfirmation.heuristicRisk(of: command)
        // The crew library's own home for these. A fixed category rather than
        // one the model names: a category is a *folder* in the captain's
        // git-synced command library, and letting a model create folders there
        // would scatter drafts across a tree the captain organises by hand.
        let saved = commands.createCommand(
            name: proposal.title,
            description: proposal.notes ?? "Drafted by the crew - not yet vouched for.",
            category: crewCommandCategory, subcategory: nil,
            commandTemplate: command,
            parameters: [], tags: ["crew-draft"], risk: risk)
        AppLog.ai.info("straw hat: captain confirmed a command draft, stored as \(risk.rawValue, privacy: .public)")
        return .written(
            message: "Saved \u{201C}\(saved.name)\u{201D} to DevOps Commands as \(risk.displayName)",
            undo: { commands.deleteCommand(id: saved.id) })
    }

    /// Where a crew-drafted command lands. One folder, so a draft is always
    /// findable and never mixed into a category the captain curated.
    static let crewCommandCategory = "Crew Drafts"

    private static func saveCommandDraft(_ proposal: StrawHatProposal,
                                         commands: CommandLibraryStore?) -> StrawHatProposalOutcome {
        guard let commands else {
            return .failed(message: "I couldn't reach your command library, so there was nowhere to save that.")
        }
        guard let command = proposal.command, !command.isEmpty else {
            // `StrawHatEnvelope` already refuses a command draft with no
            // command, so this is unreachable from a parsed reply - kept
            // because this function is `internal` and a named row that runs
            // nothing is not a failure worth being subtle about.
            return .failed(message: "That draft had no command in it, so there was nothing to save.")
        }

        // The captain reads the model's actual shell text and decides. Cancel
        // is the default (`confirmAIAuthored` puts it first), and a
        // multi-line command is refused outright rather than confirmed.
        var outcome = StrawHatProposalOutcome.failed(
            message: "Not saved - you can ask again if you want it after all.")
        CommandRiskConfirmation.confirmAIAuthored(command: command, source: "The crew",
                                                  intent: .saveTemplate) {
            outcome = commitCommandDraft(proposal, command: command, commands: commands)
        }
        return outcome
    }

    /// Franky's kind: a recurring automation, built out of the app's own six
    /// pre-approved actions.
    ///
    /// The action and the cadence are already real enum values - resolved by
    /// `StrawHatEnvelope` at parse time - so there is nothing to validate
    /// here and no way for this to schedule something the app cannot do. That
    /// is the same "the enum is the security mechanism" property
    /// `ScheduledActionKind` was written with, borrowed rather than re-argued.
    ///
    /// The new schedule is created **enabled**, exactly as the Schedule
    /// Editor's own Save does, and `ScheduleStore.add` seeds its
    /// `lastFiredOccurrence` so a nightly job confirmed at 15:00 means
    /// "starting tonight" rather than "and also right now".
    private static func createScheduleDraft(_ proposal: StrawHatProposal,
                                            schedules: ScheduleStore?,
                                            now: Date) -> StrawHatProposalOutcome {
        guard let schedules else {
            return .failed(message: "I couldn't reach your schedules, so there was nowhere to save that.")
        }
        guard let action = proposal.scheduleAction, let cadence = proposal.scheduleCadence else {
            return .failed(message: "That draft was missing its action or its cadence, so there was nothing to save.")
        }
        // `.changeOnly` is `ScheduleNotifyOn`'s own default and the app's
        // "quiet until it matters" principle - and it is the app's choice
        // rather than the model's, because how loudly the captain's own
        // machine talks to them is not a crew decision.
        let schedule = AutomationSchedule(action: action, cadence: cadence, notifyOn: .changeOnly)
        schedules.add(schedule, now: now)
        AppLog.ai.info("straw hat: captain confirmed a schedule draft for \(action.rawValue, privacy: .public)")
        return .written(
            message: "Added \u{201C}\(action.pickerTitle)\u{201D} \u{00B7} \(cadence.displayString)",
            undo: { schedules.delete(id: schedule.id) })
    }
}
