// Manjesh Grand Line - native macOS app.
//
// `ContextualNewAction` - what ⌘N creates, given where the captain is.
//
// Review #3's UX4: "⌘N creates a *task* from any page (even on Hosts, where a
// new host is ⌘⌃N)". Every other creation verb in the app either had a
// second, harder-to-remember chord (⌘⇧N for a key, ⌘⌥N for a snippet) or no
// shortcut at all (a sticky note, a code snippet, a credential, a schedule).
// So the one chord a Mac user reaches for first did the same thing on all
// twenty-six destinations.
//
// This enum is the whole routing rule, deliberately separated from both the
// menu that shows it and the shell that performs it. It is pure logic with no
// AppKit dependency beyond the two enums it switches on, which is what lets
// `KeyboardShortcutCatalogSelfTest` assert the mapping - including the menu
// title ⌘N wears on each page - without mounting a window.
//
// **The title is part of the contract, not decoration.** AppKit re-reads a
// menu item's title every time the menu opens (`menuNeedsUpdate`), so the
// File menu genuinely says "New Sticky Note…" while the Sticky Board is
// showing. A ⌘N that silently did a different thing depending on the page,
// while still *reading* "New Task…", would be worse than the inconsistency
// this replaces.

import Foundation

/// What ⌘N means on the destination that is currently showing.
enum ContextualNewAction: String, CaseIterable {
    case task
    case host
    case sshKey
    case snippet
    case stickyNote
    case codeSnippet
    case credential
    case schedule
    case command
    case runbook
    case notebookPage
    case savedLink

    /// The File menu's own wording for this action, and the Shortcuts sheet's.
    ///
    /// The ellipsis is the Mac convention for "this opens something you then
    /// have to fill in"; the two that create their subject immediately (a
    /// sticky note lands on the board empty and focused, a code-preview tab
    /// opens empty) deliberately do not carry one.
    var menuTitle: String {
        switch self {
        case .task: return "New Task\u{2026}"
        case .host: return "New Host\u{2026}"
        case .sshKey: return "New SSH Key\u{2026}"
        case .snippet: return "New Snippet\u{2026}"
        case .stickyNote: return "New Sticky Note"
        case .codeSnippet: return "New Code Snippet"
        case .credential: return "New Credential\u{2026}"
        case .schedule: return "New Schedule\u{2026}"
        case .command: return "New Command\u{2026}"
        case .runbook: return "New Runbook\u{2026}"
        // No ellipsis, for the reason this property's own doc comment gives:
        // a new notebook page is created immediately and focused, and takes
        // its name from the first heading typed into it. Nothing is filled in
        // first.
        case .notebookPage: return "New Page"
        // No ellipsis, same reason: the link on the clipboard is saved
        // immediately and its title fetched afterwards. Nothing is filled in
        // first.
        case .savedLink: return "Save Link from Clipboard"
        }
    }

    /// The page that owns each verb - what the Shortcuts sheet prints beside
    /// it so "⌘N depends on where you are" is legible rather than surprising.
    var owningDestination: RailDestination {
        switch self {
        case .task: return .shift
        case .host, .sshKey, .snippet: return .hosts
        case .stickyNote: return .stickyBoard
        case .codeSnippet: return .codePreview
        case .credential: return .poneglyph
        case .schedule: return .schedules
        case .command: return .commandLibrary
        case .runbook: return .runbooks
        case .notebookPage: return .notebook
        case .savedLink: return .readingList
        }
    }

    /// The routing rule itself.
    ///
    /// `hostsTab` is consulted only on `.hosts`, which is the one destination
    /// with three creation verbs behind one page - the Hosts/SSH Keys/Snippets
    /// column UI1 kept when it removed the duplicate tab strip. Passing `nil`
    /// there resolves to `.host`, the tab that destination opens on.
    ///
    /// **A destination that owns nothing creatable falls back to `.task`**,
    /// deliberately rather than leaving ⌘N dead: a task is the app's one
    /// universal capture verb (it is what ⌥Space's quick capture makes too),
    /// and it is what ⌘N did everywhere before this. So the change is strictly
    /// additive - no page loses a working ⌘N, nine pages gain a more useful
    /// one.
    static func forDestination(_ destination: RailDestination,
                               hostsTab: HostsTab? = nil) -> ContextualNewAction {
        switch destination {
        case .shift: return .task
        case .hosts:
            switch hostsTab {
            case .keys: return .sshKey
            case .snippets: return .snippet
            case .hosts, .none: return .host
            }
        case .stickyBoard: return .stickyNote
        case .codePreview: return .codeSnippet
        case .poneglyph: return .credential
        case .schedules: return .schedule
        case .commandLibrary: return .command
        case .runbooks: return .runbook
        case .notebook: return .notebookPage
        case .readingList: return .savedLink
        case .homeCanvas, .overview, .strawHat, .console, .review, .logAnalyzer,
             .kubernetes, .tools, .whiteboard, .vault, .dictation, .health,
             .docs, .postmortems, .updates, .bootstrap, .automation,
             .githubSync, .settings:
            return .task
        }
    }
}
