// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates **phase 2**: the one place a crew proposal becomes a real
// store write (the plan's milestone M2.2, second half).
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
// ## Why this is not `ConsoleCommandComposer`'s risk gate
//
// `CommandRiskConfirmation.confirmAIAuthored` exists because an AI-authored
// *shell command* can do anything, so it needs an alert before it reaches a
// terminal. These three writes are bounded and reversible-by-hand: a task, a
// follow-up, a markdown file. The confirm card *is* the gate, and adding a
// second modal on top of a button the captain deliberately pressed would be
// the "a palette is a faster way to reach an action, never a way around its
// confirmation" rule applied backwards - there is no faster path being taken
// here. The plan's phase-3 `save_command_draft` is the kind that genuinely
// needs `confirmAIAuthored`, and it is deliberately not in this phase.
//
// ## Undo: real for one kind, deliberately absent for two
//
// GL-33's rule is that `onUndo` must restore the value the caller already had
// in hand - which is why AGENTS.md records it as *not* wired to an SSH key
// delete, where the private bytes are gone and an "Undo" producing a
// key-shaped shell would be a lie.
//
// The same test splits these three:
//
//  - `create_runbook_draft` **gets a real undo.** `DocsRunbookStore.
//    deleteRunbook(id:)` exists and the created runbook's id is in hand, so
//    the undo genuinely removes the file it just wrote.
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
}

enum StrawHatProposalExecutor {

    /// Performs one confirmed proposal. Main thread only (it touches stores
    /// every view on this page also reads).
    ///
    /// `docs` is optional because `FleetController` resolves its own
    /// `DocsRunbookStore` and that can legitimately be unavailable; a runbook
    /// proposal in that state fails with a real message rather than silently
    /// doing nothing.
    static func execute(_ proposal: StrawHatProposal,
                        shift: ShiftStore,
                        docs: DocsRunbookStore?,
                        now: Date = Date()) -> StrawHatProposalOutcome {
        dispatchPrecondition(condition: .onQueue(.main))

        switch proposal.kind {
        case .addTask:
            return addTask(proposal, shift: shift, now: now)
        case .addFollowUp:
            return addFollowUp(proposal, shift: shift, now: now)
        case .createRunbookDraft:
            return createRunbookDraft(proposal, docs: docs)
        }
    }

    // MARK: The three kinds

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
            // The one genuine undo of the three - see this file's header.
            docs.deleteRunbook(id: runbook.id)
        })
    }
}
