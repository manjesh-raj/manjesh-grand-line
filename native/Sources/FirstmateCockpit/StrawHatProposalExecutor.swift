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
// ## Three kinds route through an existing editor instead, and never reach
// `execute` at all - and `add_task` used to be a fourth
//
// `fm/straw-hat-task-proposal-full-editor`: `execute`'s `addTask` used to
// build a `ShiftTask` straight from the proposal and write it - no priority,
// no project, no tags, because the model was never asked for any of them and
// the captain never got a chance to set them either. That is honest ("nothing
// invented") but it left him with a task carrying decisions he never made, so
// four kinds were re-pointed at the real "New X" sheet each already has,
// pre-filled, instead of at `execute`.
//
// **`fm/grandline-strawhat-task-direct-create` moved `add_task` back here,
// and that is the captain's own correction rather than a revert.** Routing it
// through the editor solved the missing fields and replaced them with a worse
// problem: *"I am asking the agent to create, but it is just giving me the
// task queue again so that I am going to create. It doesn't make sense for me.
// If it needs to ask me the project or something, it can ask like some sort of
// radio button or an input - a quick question back to me - but not hand the
// whole task creation form back to me."* An agent that answers "create a task"
// with the manual creation form has not done the thing.
//
// So the original defect is fixed at its actual root instead - the two fields
// that were being silently defaulted now have honest sources, neither of which
// is a sheet:
//
//  - **Project** is the captain's own inline choice on the confirm card
//    (`StrawHatConfirmChoices.projectID`, rendered by `StrawHatConfirmCard` as
//    a popup of their real projects plus "No project"). It is *their* pick,
//    made before they press, exactly the "quick question back to me" they
//    asked for. A `project` hint on the proposal only pre-selects it - see
//    `resolveProject(hint:among:)`.
//  - **Priority** comes from the proposal when the captain themselves
//    signalled one, and is otherwise `ShiftTask.fresh`'s own `.normal` - the
//    identical value the New Task sheet starts at, so nothing is defaulted
//    here that is not defaulted there. It gets no second inline control: the
//    captain asked to be asked about "the project or something", and a task
//    created at normal priority is a task he can re-prioritise in one click on
//    a page he is already going to look at.
//
// The three kinds still routed to an editor each need more review than one
// inline control can carry: a command draft has its own risk gate, category
// and parameters; a schedule has an action and a cadence; a follow-up has a
// linked task. `StrawHatProposalKind.opensEditor` is the list, and
// `StrawHatSelfTest` asserts its membership literally.
//
// `execute`'s own branches for those three kinds are untouched on purpose (see
// the file's own tests, which still drive them directly) rather than deleted:
// they remain the honest "what would this look like with nothing added"
// reference this file's header always described, now reachable only from a
// test calling `execute` directly, never from the confirm-card flow.
// `addTask`, `createRunbookDraft` and `addSticky` are the three kinds `execute`
// serves in production - see `opensEditor`'s own doc comment for why the last
// two have no equivalent dialog to route through instead.
//
// ## Undo: real for five kinds, deliberately absent for one
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
//  - `add_task` **gets one now**, which it did not when this list said four.
//    The blocker was real and is gone: `ShiftStore` genuinely had no delete
//    for a task, so an "Undo" could only have pretended. The Kanban board
//    task (`grandline-tasks-kanban-devops-split`) added
//    `ShiftStore.deleteTask(id:)` - a real delete that also removes the
//    task's attachment file and clears any follow-up pointing at it - so the
//    undo here genuinely removes the record it just wrote, the same pairing
//    `create_runbook_draft` has always had. It matters more for this kind
//    than for most: this is the one write the captain reaches by confirming
//    a card rather than by pressing Save on a form he has just read.
//  - `add_follow_up` is the one that still gets a **plain toast, no undo** -
//    not because a delete is missing (`ShiftStore.deleteFollowUp(id:)` landed
//    in the same task) but because it never reaches `execute` in production
//    at all: it routes through its own editor, whose Save is an ordinary
//    hand-created record with no toast of this file's to attach an undo to.
//    If it is ever un-routed, wire one the same way `addTask` does.

import Foundation

/// The captain's own inline choices on a confirm card, made before they press
/// it - never anything the model proposed.
///
/// A struct rather than a bare parameter so the distinction survives at every
/// call site: a `StrawHatProposal` is what the crew drafted, and this is what
/// the captain decided about it. The two must not be conflated, because only
/// one of them is a human's choice.
///
/// One field today (`fm/grandline-strawhat-task-direct-create`). It is a
/// struct rather than a lone `String?` argument so adding a second inline
/// control later is one field rather than a re-threaded signature through the
/// card, the chat view and the controller.
struct StrawHatConfirmChoices: Equatable {
    /// Which project a confirmed `.addTask` lands in - `nil` for "No project",
    /// which is a real, ordinary state (`ShiftTask.projectID` is optional and
    /// the New Task sheet itself starts there).
    ///
    /// Meaningless to every other kind, and ignored by them.
    var projectID: String?

    init(projectID: String? = nil) {
        self.projectID = projectID
    }
}

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
    /// `StrawHatController.openEditorForReview`, which intercepts those three
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

    /// - Parameter choices: what the captain picked on the card itself before
    ///   pressing it. Defaulted so every kind that has nothing to pick - and
    ///   every test driving one - reads unchanged.
    static func execute(_ proposal: StrawHatProposal,
                        stores: Stores,
                        choices: StrawHatConfirmChoices = .init(),
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
            return addTask(proposal, shift: stores.shift, choices: choices, now: now)
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

    /// Nami's kind, and the one the captain reaches most: confirming the card
    /// writes the task. See this file's header for why it does that again.
    ///
    /// Every field has an honest source. Title, notes and due date are the
    /// crew's draft; the project is the captain's own pick on the card
    /// (`choices`), never the model's; the priority is theirs only when they
    /// signalled one, and otherwise the store's own default. Nothing is
    /// guessed by the app in between.
    private static func addTask(_ proposal: StrawHatProposal,
                                shift: ShiftStore,
                                choices: StrawHatConfirmChoices,
                                now: Date) -> StrawHatProposalOutcome {
        // `ShiftTask.fresh()` is the same starting point the New Task sheet
        // uses, so a crew-created task is indistinguishable from a
        // hand-created one - same id shape, same defaults, same `createdAt`.
        var task = ShiftTask.fresh(now: now)
        task.title = proposal.title
        if let notes = proposal.notes { task.notes = notes }
        if let due = proposal.resolvedDue(now: now) {
            task.dueDate = due.date
            task.dueTime = due.time
        }
        // The captain's own choice, and only ever one of their real projects:
        // the card builds its picker from `ShiftStore.projects`, so an id that
        // is not in that list cannot come from a press. Re-checked here anyway
        // - this is `internal` and a stale id would file the task under a
        // project that no longer exists, where the Tasks page would never show
        // it.
        if let projectID = choices.projectID,
           shift.projects.contains(where: { $0.id == projectID }) {
            task.projectID = projectID
        }
        // Only when the captain themselves signalled one. `nil` deliberately
        // leaves `.normal` - the value `ShiftTask.fresh` already set and the
        // value the New Task sheet opens on - rather than the app picking a
        // level nobody asked for.
        if let priority = proposal.priority { task.priority = priority }

        shift.addTask(task)
        AppLog.ai.info("straw hat: captain confirmed a task proposal")
        let id = task.id
        return .written(message: "Added \u{201C}\(proposal.title)\u{201D} to Tasks", undo: {
            // GL-33: a real undo, not a gesture. `deleteTask` removes the row
            // from whichever file it now lives in, drops its attachment and
            // clears any follow-up that pointed at it - so this genuinely
            // restores the state the captain had before the press.
            _ = shift.deleteTask(id: id)
        })
    }

    /// The captain's own project name, matched against their real projects -
    /// or `nil`, which is an honest answer rather than a failure.
    ///
    /// The crew cannot see projects at all (`StrawHatProposal.project`'s own
    /// note has the reason), so a hint is only ever a name the captain used in
    /// their own message. This resolves it the same way
    /// `AppShellController.openSRELeadForCrew` resolves a host hint, and for
    /// the same reason: **exact name first, then a unique substring, and it
    /// refuses to choose between two.** A project called "Grand Line" must not
    /// become ambiguous just because "Grand Line v2" also exists, and an
    /// ambiguous hint must leave the picker alone rather than pre-selecting a
    /// coin flip the captain would have to notice to correct.
    ///
    /// This only ever *pre-selects* a picker the captain can still change, so
    /// the cost of returning `nil` is one click, and the cost of guessing
    /// wrong is a task filed somewhere they did not look.
    static func resolveProject(hint: String?, among projects: [ShiftProject]) -> ShiftProject? {
        guard let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hint.isEmpty else { return nil }
        let needle = hint.lowercased()
        let exact = projects.filter { $0.name.lowercased() == needle }
        if exact.count == 1 { return exact.first }
        let partial = projects.filter { $0.name.lowercased().contains(needle) }
        if partial.count == 1 { return partial.first }
        return nil
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
