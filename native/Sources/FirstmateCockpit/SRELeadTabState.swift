// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-sre-lead-per-tab`: SRE Lead's own investigation state - its
// session, bridge, runner, and chat - held on `ConsoleSession.sreLead`
// (`ConsoleSession.swift`, née `TabModel` before `fm/grandline-menubar-
// remove-items` collapsed the console to one session per host/window). This
// mirrors `ConsoleSession.blockTracker`/`blockContainer` for the identical
// reason: feature state that lives and dies with the session it belongs to,
// with automatic cleanup when that session closes, rather than a dictionary
// kept on `ConsoleController` that would need manual bookkeeping (see the
// original per-tab design doc's Option B, rejected for exactly that reason:
// `data/grandline-sre-lead-per-tab/design-reference.html` - written back
// when a console could hold several tabs at once).
//
// `ConsoleController`'s `sreLeadPane` is one shared, fixed slide-open panel;
// the current session's `chatView` is shown inside it, or the empty state if
// there's no session with SRE Lead started yet
// (`ConsoleController.updateSRELeadPaneContent`).

import Foundation

/// SRE Lead's own state for one console session. `nil` on `ConsoleSession`
/// until the captain explicitly starts SRE Lead for that session.
final class SRELeadTabState {
    /// `SRELeadPhase` is shared with the toolbar button rather than a second,
    /// parallel enum with the same four cases - the button always renders
    /// exactly the currently selected tab's phase (see
    /// `ConsoleController.select`/`updateSRELeadControls`).
    var phase: SRELeadPhase = .notStarted
    var session: SRELeadSession?
    var bridge: SRELeadBridge?
    var runner: SRELeadRunner?
    /// Built once, the first time this session's SRE Lead is started -
    /// lazily, not at `ConsoleSession` construction, so a session that never
    /// touches SRE Lead never allocates one.
    var chatView: SRELeadChatView?

    /// Stops the bridge's poll timer, cancels any in-flight `claude -p`
    /// turn, and removes every scratch file `SRELead.setUp` wrote for this
    /// tab - mirrors the old page-level `tearDownSRELead()`'s cleanup
    /// exactly, just scoped to one tab's own state so tearing this tab down
    /// can never touch a sibling tab's session. Leaves `chatView` and
    /// `phase` alone - the caller (`ConsoleController.tearDownSRELead(for:)`)
    /// decides what happens to those, since a "torn down because the tab
    /// closed" caller and a "torn down because the pill was toggled off"
    /// caller want different follow-up UI.
    func tearDownSession() {
        bridge?.stop()
        bridge = nil
        runner?.cancel()
        runner = nil
        session?.tearDown()
        session = nil
    }
}
