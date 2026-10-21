// Grand Line - native macOS app.
//
// `CaptureFilingService` - where ⌥Space's five destinations actually land:
// the stores and pages a capture is filed into.
//
// Split out of `AppShellController` in stage 2 of the modular-shell migration
// (full review section 5.8, step 2, which names this piece the shell's
// "CaptureRouter"). The routing *rule* - which destination a capture goes to,
// and what its title and snippet name are - already lives in
// `CaptureRouter.swift` as pure logic. This is the other half, the writes,
// which needed the shell's stores and two of its pages; `Workspace` builds it
// from exactly those, so either shell files a capture the same way. Nothing
// about the filing changed in the move.

import Foundation

struct CaptureFilingService {
    let shiftStore: ShiftStore
    let notebookStore: NotebookStore
    let codePreviewStore: CodePreviewStore
    let readingListStore: ReadingListStore
    /// The Sticky Board's own add, so a captured note lands exactly as one
    /// added on the board does.
    let addStickyNote: (_ title: String, _ text: String) -> Void
    /// ⌘4's hand-off: open Poneglyph with its Add sheet already holding the
    /// secret. See `file(_:_:)`'s `.credential` case for why this navigates
    /// rather than filing silently.
    let handOffCredential: (_ secret: String) -> Void

    /// The five writes ⌥Space's router reaches, bound to the stores the
    /// workspace already owns.
    ///
    /// **Why the panel does not own any of this.** GL-23: `CredentialVaultStore`
    /// and `StickyBoardStore` cache, so a second instance is a second source
    /// of truth, and this controller is the one place all five destinations
    /// are already in scope. The same "forward, never own" shape
    /// `RecentDestinationsController.configure` uses, for the same reason.
    ///
    /// **Four of the five file silently; ⌘4 hands off, on purpose.** A
    /// captured credential is a *secret* with no title, category or location,
    /// and the vault may well be locked when ⌥Space fires (a locked
    /// `CredentialVaultStore.add` refuses outright). So ⌘4 navigates to
    /// Poneglyph and opens its own Add sheet with the secret already filled -
    /// the same "select the destination first, then act on it" shape every
    /// creation verb above uses, and the one destination where a silent write
    /// would be the wrong answer even if it were possible.
    func file(_ destination: CaptureDestination,
              _ draft: CaptureDraft) -> CaptureFilingOutcome {
        switch destination {
        case .task:
            var task = ShiftTask.fresh()
            task.title = draft.title
            task.description = draft.body
            if let due = draft.dueDate {
                let (dateStr, timeStr) = ShiftDateFormatting.components(from: due)
                task.dueDate = dateStr
                task.dueTime = draft.dueHasTime ? timeStr : nil
            }
            shiftStore.addTask(task)
            return .filed(.task)

        case .sticky:
            addStickyNote(draft.title, draft.body)
            return .filed(.sticky)

        case .note:
            _ = notebookStore.createPage(
                title: CaptureRouter.notebookTitle(for: draft),
                content: draft.text)
            return .filed(.note)

        case .codeSnippet:
            _ = codePreviewStore.create(name: CaptureRouter.snippetName(for: draft),
                                        content: draft.text)
            return .filed(.codeSnippet)

        case .link:
            // The one destination whose store decides whether the capture
            // is even a link, so the panel is told what actually happened
            // rather than being told "filed" unconditionally. A duplicate
            // and a non-URL are both `.refused`, and the panel keeps the
            // captain in the loop - the same posture ⌘4 takes below for a
            // different reason.
            switch readingListStore.add(draft.text) {
            case .added:
                // The page may never have been mounted, so the card it
                // will show is built on first visit from the store this
                // just wrote - nothing here has to reach into a view.
                return .filed(.link)
            case .duplicate(let existing):
                return .refused("\(existing.host) is already on the reading list.")
            case .rejected(let why):
                return .refused(why)
            }

        case .credential:
            handOffCredential(draft.text)
            return .handedOff(.credential)
        }
    }
}
