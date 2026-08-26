// Manjesh Grand Line - native macOS app.
//
// GL-36/GL-27: the `debug*` hooks the console's self-test suites drive.
//
// They live in their own file because the production reviewer's actual
// complaint about them was placement rather than existence: test-only
// surface interleaved with the real controller is a real readability cost,
// and the honest fix is to put them where they are obviously test
// scaffolding rather than to delete hooks the suites genuinely need. Every
// one of them drives the *real* machinery (`startSession`, `reconnectActive`,
// `startSRELead`, the real bridge) rather than reimplementing it in a test,
// which is precisely why those suites are worth having.
//
// They are behind `FM_SELFTESTS`. `Package.swift` defines that flag for the
// debug configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has all of them, and
// `swift build -c release` - what `build_native_app.sh` assembles the `.app`
// from - has none.
//
// `fm/grandline-menubar-remove-items` rewrote every hook here for the
// single-session model - most of the `forTabID:` disambiguation params are
// gone, since a console has at most one session and there is nothing left
// to disambiguate among.
//
// Do not add a hook here that production code calls: the release build will
// not have it.

import AppKit
import SwiftTerm

#if FM_SELFTESTS

extension ConsoleController {

    // MARK: Test support (`fm/cockpit-block-view-stage0`)
    //
    // `BlockViewRestartIntegrationSelfTest` needs to drive this controller's
    // *real* restart machinery - `startSession`/`reconnectActive` themselves,
    // not a reimplementation of them in the test - to prove both restart
    // paths leave the block tracker in the same clean state (the scout
    // report's Mechanism A: the original attempt only reset it correctly
    // from `reconnectActive`, not from the auto-reconnect timer that calls
    // `startSession` directly). These methods exist for exactly that; no
    // production code calls them.

    /// Opens a real `.ssh` session on this (non-Firstmate) console, exactly
    /// the way `AppShellController.connectHost` does for an opted-in host,
    /// minus needing a real `Host`/`AppShellController`. `127.0.0.1` with a
    /// 1s connect timeout fails fast (nothing real listens on the ssh port
    /// there in this environment) - the test only needs a real `Terminal`
    /// and a real `TerminalBlockTracker` attached to it, not a working
    /// connection.
    func debugOpenTestSSHTab(label: String) {
        openSSH(
            label: label,
            args: ["-o", "ConnectTimeout=1", "-o", "BatchMode=yes", "127.0.0.1"],
            accentHex: nil, keyID: nil, blockViewOptIn: true
        )
    }

    /// The real `Terminal` behind the session, so a test can feed synthetic
    /// OSC 133 bytes into it directly - mirroring
    /// `TerminalBlockTrackerSelfTest`'s `HeadlessTerminal` technique -
    /// without a live shell actually emitting them.
    func debugCurrentTerminal() -> Terminal? { session?.terminal.terminal }

    /// The two facts Mechanism A's bug corrupts: how many blocks the tracker
    /// holds, and whether any of them is still `.running` (the permanently-
    /// stuck-spinner symptom).
    func debugBlockState() -> (count: Int, hasRunning: Bool)? {
        guard let tracker = session?.blockTracker else { return nil }
        let hasRunning = tracker.blocks.contains {
            if case .running = $0.status { return true }
            return false
        }
        return (tracker.blocks.count, hasRunning)
    }

    /// Drives the exact "initial start / automatic reconnect" path -
    /// `processTerminated`'s auto-reconnect timer calls `startSession`
    /// directly, so this does too, rather than reimplementing what it does.
    func debugSimulateAutoReconnectRestart() {
        guard let target = session else { return }
        startSession(target)
    }

    /// Drives the exact manual ⌘R path.
    func debugSimulateManualReconnectRestart() {
        reconnectActive()
    }

    // MARK: Test support (session)

    /// The session's raw terminal output so far - `SRELeadSessionSelfTest`
    /// uses it to prove scrollback survives the SRE Lead pane opening/
    /// closing.
    func debugCurrentTerminalOutput() -> String? {
        guard let terminal = session?.terminal.terminal else { return nil }
        return String(data: terminal.getBufferAsData(), encoding: .utf8)
    }

    // MARK: Test support (`fm/grandline-sre-lead-per-tab`, now per-console)
    //
    // `SRELeadSessionSelfTest` needs to drive this controller's *real* SRE
    // Lead machinery - `startSRELead(for:)`/`handleSRELeadSubmit`/
    // `tearDownSRELead(for:)`/`closeCurrentTab` themselves, not
    // reimplementations of them - to prove SRE Lead state genuinely lives on
    // the session (a real phase transition, teardown on close). No
    // production code calls any of these.

    /// Starts SRE Lead for this console's session, exactly like clicking the
    /// toolbar pill.
    func debugStartSRELead() {
        guard let target = session else { return }
        startSRELead(for: target)
    }

    /// Tears SRE Lead down for this console's session, exactly like clicking
    /// the pill while it's ready.
    func debugTearDownSRELead() {
        guard let target = session else { return }
        tearDownSRELead(for: target)
    }

    /// Closes the session - the same `closeCurrentTab()` ⌘W drives.
    func debugCloseTab() { closeCurrentTab() }

    func debugSRELeadPhase() -> SRELeadPhase? { session?.sreLead?.phase }

    /// Submits `question` into the session's own SRE Lead chat, exactly
    /// like the captain typing into the input field and pressing Return -
    /// drives the real `handleSRELeadSubmit(_:in:)`, so a fake `claude`
    /// script (`SRELead.claudePathOverrideForTests`) is what actually
    /// answers it.
    func debugAskSRELead(question: String) {
        guard let target = session else { return }
        handleSRELeadSubmit(question, in: target)
    }

    /// The exact text of every message currently in the session's own SRE
    /// Lead chat - `nil` if it has no chat yet.
    func debugSRELeadChatTexts() -> [String]? {
        session?.sreLead?.chatView?.debugMessageTexts()
    }

    /// Whether the shared pane is currently visible (non-zero width).
    func debugSRELeadPaneOpen() -> Bool { sreLeadPaneWidthConstraint.constant > 0 }

    /// Daylight §6.13: whether the bordered terminal card is actually drawn.
    func debugTerminalCardVisible() -> Bool { !cardChrome.isHidden }

    /// The session's terminal frame in `content`'s own coordinates - the
    /// one number §6.13's card must never move (the scrollback invariant).
    func debugCurrentTerminalFrame() -> NSRect? {
        guard let term = session?.terminal else { return nil }
        return term.convert(term.bounds, to: content)
    }

    /// Whether the pane is currently showing the shared "not started yet"
    /// empty state (as opposed to a real chat) - `nil` if there's no session
    /// at all.
    func debugSRELeadShowingEmptyState() -> Bool? {
        guard session != nil else { return nil }
        return !sreLeadEmptyStateView.isHidden
    }
}

#endif
