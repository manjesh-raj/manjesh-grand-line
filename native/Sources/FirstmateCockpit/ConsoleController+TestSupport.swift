// Manjesh Grand Line - native macOS app.
//
// GL-36/GL-27: the `debug*` hooks the console's self-test suites drive.
//
// Two things changed about these in the Phase 4 decomposition, neither of
// them behavioural.
//
// They now live in their own file, because the production reviewer's actual
// complaint about them was placement rather than existence: ~150 lines of
// test-only surface interleaved with the real controller is a real
// readability cost, and the honest fix is to put them where they are
// obviously test scaffolding rather than to delete hooks the suites
// genuinely need. Every one of them drives the *real* machinery
// (`startTab`, `reconnectActive`, `startSRELead`, the real bridge) rather
// than reimplementing it in a test, which is precisely why those suites are
// worth having.
//
// And they are now behind `FM_SELFTESTS`, which they never were. Phase 3
// (GL-27) moved every self-test *file* behind that flag so the shipped
// binary stops carrying its own test suite - but these hooks sat in a
// production file and kept shipping. `Package.swift` defines `FM_SELFTESTS`
// for the debug configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has all of them, and
// `swift build -c release` - what `build_native_app.sh` assembles the `.app`
// from - now has none.
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
    // *real* restart machinery - `startTab`/`reconnectActive` themselves,
    // not a reimplementation of them in the test - to prove both restart
    // paths leave the block tracker in the same clean state (the scout
    // report's Mechanism A: the original attempt only reset it correctly
    // from `reconnectActive`, not from the auto-reconnect timer that calls
    // `startTab` directly). These five methods exist for exactly that; no
    // production code calls them.

    /// Opens a real `.ssh` tab on this (non-Firstmate) console, exactly the
    /// way `AppShellController.connectHost` does for an opted-in host, minus
    /// needing a real `Host`/`AppShellController`. `127.0.0.1` with a 1s
    /// connect timeout fails fast (nothing real listens on the ssh port
    /// there in this environment) - the test only needs a real `Terminal`
    /// and a real `TerminalBlockTracker` attached to it, not a working
    /// connection.
    func debugOpenTestSSHTab(label: String) {
        openSSH(
            label: label,
            args: ["-o", "ConnectTimeout=1", "-o", "BatchMode=yes", "127.0.0.1"],
            accentHex: nil, keyID: nil, startupSnippetID: nil, blockViewOptIn: true
        )
    }

    /// The real `Terminal` behind the current tab, so a test can feed
    /// synthetic OSC 133 bytes into it directly - mirroring
    /// `TerminalBlockTrackerSelfTest`'s `HeadlessTerminal` technique - without
    /// a live shell actually emitting them.
    func debugCurrentTerminal() -> Terminal? { currentTab?.terminal.terminal }

    /// The two facts Mechanism A's bug corrupts: how many blocks the tracker
    /// holds, and whether any of them is still `.running` (the permanently-
    /// stuck-spinner symptom).
    func debugBlockState() -> (count: Int, hasRunning: Bool)? {
        guard let tracker = currentTab?.blockTracker else { return nil }
        let hasRunning = tracker.blocks.contains {
            if case .running = $0.status { return true }
            return false
        }
        return (tracker.blocks.count, hasRunning)
    }

    /// Drives the exact "initial start / automatic reconnect" path -
    /// `processTerminated`'s auto-reconnect timer calls `startTab` directly,
    /// so this does too, rather than reimplementing what it does.
    func debugSimulateAutoReconnectRestart() {
        guard let tab = currentTab else { return }
        startTab(tab)
    }

    /// Drives the exact manual ⌘R path.
    func debugSimulateManualReconnectRestart() {
        reconnectActive()
    }

    // MARK: Test support (tabs)

    /// Every open tab's id, in tab-bar order - so a test can find and select
    /// a specific tab without `tabs` itself needing to be internal.
    func debugAllTabIDs() -> [UUID] { tabs.map { $0.id } }

    /// Selects a tab by id, exactly like clicking its chip.
    func debugSelectTab(_ id: UUID) { select(tabID: id, focus: false) }

    /// The current tab's raw terminal output so far - `SRELeadPerTabSelfTest`
    /// uses it to prove a tab's scrollback survives the SRE Lead pane
    /// opening/closing.
    func debugCurrentTerminalOutput() -> String? {
        guard let terminal = currentTab?.terminal.terminal else { return nil }
        return String(data: terminal.getBufferAsData(), encoding: .utf8)
    }

    // MARK: Test support (`fm/grandline-sre-lead-per-tab`)
    //
    // `SRELeadPerTabSelfTest` needs to drive this controller's *real*
    // per-tab SRE Lead machinery - `startSRELead(for:)`/`handleSRELeadSubmit`/
    // `tearDownSRELead(for:)`/`closeTab` themselves, not reimplementations of
    // them - to prove the state genuinely lives per-tab (independent phases,
    // no cross-talk between two tabs' chats, per-tab teardown on close, the
    // 5-tab cap). No production code calls any of these.

    /// Starts SRE Lead for the tab at `id`, exactly like clicking the
    /// toolbar pill while that tab is current - but without needing to
    /// actually select it first, so a test can start it on several tabs in
    /// any order.
    func debugStartSRELead(forTabID id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        startSRELead(for: tab)
    }

    /// Tears SRE Lead down for the tab at `id`, exactly like clicking the
    /// pill while that tab is current and ready.
    func debugTearDownSRELead(forTabID id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tearDownSRELead(for: tab)
    }

    /// Closes a tab by id - the same `closeTab(id:)` a chip's "×"/⌘W drives.
    func debugCloseTab(id: UUID) { closeTab(id: id) }

    func debugSRELeadPhase(forTabID id: UUID) -> SRELeadPhase? {
        tabs.first(where: { $0.id == id })?.sreLead?.phase
    }

    /// Submits `question` into the tab at `id`'s own SRE Lead chat, exactly
    /// like the captain typing into that tab's input field and pressing
    /// Return - drives the real `handleSRELeadSubmit(_:in:)`, so a fake
    /// `claude` script (`SRELead.claudePathOverrideForTests`) is what
    /// actually answers it.
    func debugAskSRELead(forTabID id: UUID, question: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        handleSRELeadSubmit(question, in: tab)
    }

    /// The exact text of every message currently in the tab at `id`'s own
    /// SRE Lead chat - `nil` if that tab has no chat yet.
    func debugSRELeadChatTexts(forTabID id: UUID) -> [String]? {
        tabs.first(where: { $0.id == id })?.sreLead?.chatView?.debugMessageTexts()
    }

    /// How many tabs on this page currently have SRE Lead actively running -
    /// the same count `startSRELead(for:)` checks against `sreLeadMaxConcurrent`.
    func debugActiveSRELeadCount() -> Int { activeSRELeadTabCount() }

    /// Whether the shared pane is currently visible (non-zero width) - never
    /// which tab's content it shows, since `updateSRELeadPaneContent()`
    /// already has its own dedicated debug surface below.
    func debugSRELeadPaneOpen() -> Bool { sreLeadPaneWidthConstraint.constant > 0 }

    /// Daylight §6.13: whether the bordered terminal card is actually drawn.
    func debugTerminalCardVisible() -> Bool { !cardChrome.isHidden }

    /// The current tab's terminal frame in `content`'s own coordinates - the
    /// one number §6.13's card must never move (the scrollback invariant).
    func debugCurrentTerminalFrame() -> NSRect? {
        guard let term = currentTab?.terminal else { return nil }
        return term.convert(term.bounds, to: content)
    }

    /// Whether the pane is currently showing the shared "not started yet"
    /// empty state (as opposed to some tab's real chat) - `nil` if there is
    /// no current tab at all.
    func debugSRELeadShowingEmptyState() -> Bool? {
        guard currentTab != nil else { return nil }
        return !sreLeadEmptyStateView.isHidden
    }
}

#endif
