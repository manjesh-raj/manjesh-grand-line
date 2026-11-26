// Grand Line - native macOS app.
//
// UI-01 and UI-12 of full review 4: every page that opens on a hero gives up
// the shell's header line, so every hero starts at one height under the
// toolbar.
//
// Tasks, Calendar, Crew, Review, Console and the Sticky Board already did
// (`WorkspaceHeaderLineCollapsing`, each in its own file). The pages below
// either kept an empty 32pt slot above their hero (Home, Connections, Health,
// DevOps Hub, Secrets - UI-01), or printed a grey line that the hero right
// under it already says in full (Health's "8 services · 1 failing", Secrets'
// "Locked", Automic Vault, the four Setup tabs and Dictation - UI-12). Both
// made the hero jump by 32pt as the captain moved between pages.
//
// The subtitle is still each page's summary: the crew panel reads it as the
// page's context. It is only not repeated on the line. The adoptions live
// together here so the set of hero pages is one list, and
// `MainSplitShellPanesSelfTest`'s S03 check asserts that every one of them
// starts its hero on the same line as Tasks.

import AppKit

extension HomeCanvasController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { true }
    var drawsSubtitleOnHeaderLine: Bool { false }
}

extension HostsController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { true }
    var drawsSubtitleOnHeaderLine: Bool { false }
}

extension HealthController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { true }
    var drawsSubtitleOnHeaderLine: Bool { false }
}

/// Only the cards have a hero. A project's own view keeps the line, which
/// names what the project is doing.
extension DevOpsHubController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { mode == .cards }
    var drawsSubtitleOnHeaderLine: Bool { mode != .cards }
}

extension CredentialVaultController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { true }
    var drawsSubtitleOnHeaderLine: Bool { false }
}

extension VaultController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { true }
    var drawsSubtitleOnHeaderLine: Bool { false }
}

extension UpdatesController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { true }
    var drawsSubtitleOnHeaderLine: Bool { false }
}

extension BootstrapController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { true }
    var drawsSubtitleOnHeaderLine: Bool { false }
}

extension AutomationController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { true }
    var drawsSubtitleOnHeaderLine: Bool { false }
}

extension GitHubSyncController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { true }
    var drawsSubtitleOnHeaderLine: Bool { false }
}

extension DictationController: WorkspaceHeaderLineCollapsing {
    var collapsesEmptyHeaderLine: Bool { true }
    var drawsSubtitleOnHeaderLine: Bool { false }
}
