// Manjesh Grand Line - native macOS app.
//
// GL-36, part of `ConsoleController`'s decomposition: the two features that
// read a terminal's *output* rather than drive its input - Block View
// (`fm/cockpit-block-view-stage0`) and the Log Analyzer capture bridge
// (spec §2).
//
// They belong together because they answer the same question from opposite
// ends: Block View asks the shell to mark its own command boundaries (OSC
// 133) so this app can see them, and the capture bridge uses exactly those
// marks - when a host opted into them - to decide how much scrollback the
// captain meant by "analyze this".
//
// Split out verbatim along this controller's own existing `// MARK:` seams;
// no statement here changed in the move. See `ConsoleController.swift`'s
// header.

import AppKit
import SwiftTerm

extension ConsoleController {

    // MARK: Block view (`fm/cockpit-block-view-stage0`)


    /// Decides which of a tab's two views (raw `terminal` or parsed
    /// `blockContainer`) is visible right now - never both, and never for a
    /// tab that isn't the current one. Toggling never touches `terminal`'s
    /// process or `startProcess` state either way. A tab with no
    /// `blockContainer` (every tab except the one opted-in host's, when the
    /// feature is enabled - see `TabModel.blockViewOptIn`) always shows raw
    /// `terminal` regardless of `blockViewShowing`.
    func updateTabViewVisibility(_ tab: TabModel) {
        let isCurrent = (tab === currentTab)
        guard isCurrent else {
            tab.terminal.isHidden = true
            tab.blockContainer?.isHidden = true
            return
        }
        if blockViewShowing, let container = tab.blockContainer {
            tab.terminal.isHidden = true
            container.isHidden = false
        } else {
            tab.terminal.isHidden = false
            tab.blockContainer?.isHidden = true
        }
    }

    /// Toolbar toggle - only meaningful (and only shown at all, see
    /// `updateBlockViewControls`) for the one opted-in host's tab.
    @objc func toggleBlockView() {
        guard currentTab?.blockContainer != nil else { return }
        blockViewShowing.toggle()
        if let tab = currentTab { updateTabViewVisibility(tab) }
        updateBlockViewControls()
    }

    // MARK: Log Analyzer bridge (`fm/grandline-log-analyzer-build`, spec §2)

    /// Gathers this tab's three capture inputs and hands the decision to
    /// `LogTerminalCaptureBuilder` (which is pure logic, so every branch is
    /// covered by `LogAnalyzerSelfTest` without a terminal).
    ///
    /// **What is deliberately NOT sent:** the full scrollback. A tab holds
    /// 10,000 lines (`makeTerminal`'s `changeScrollback`) and almost none of
    /// it belongs to the command being investigated. Nor is it the visible
    /// viewport - that silently drops output that scrolled past. See
    /// `LogAnalyzerCapture.swift`'s header for the full reasoning and for
    /// what happens on a host without per-command block tracking.
    @objc func analyzeLogsTapped() {
        guard let tab = currentTab else {
            Toast.show(in: view, message: "No tab to capture from")
            return
        }
        let capture = buildLogCapture(for: tab)
        guard !capture.isEmpty else {
            Toast.show(in: view, message: "This tab has no output to analyze yet")
            return
        }
        onAnalyzeLogs?(capture, tab.name)
    }

    /// Split out of the action so the capture can be built (and inspected)
    /// without firing the callback.
    func buildLogCapture(for tab: TabModel) -> LogTerminalCapture {
        let selection = tab.terminal.selectionActive ? tab.terminal.getSelection() : nil
        let blocks = tab.blockTracker?.blocks ?? []
        let bufferLines = tab.terminal.terminal.map { TerminalBlockTracker.bufferLines($0) } ?? []
        return LogTerminalCaptureBuilder.build(selection: selection,
                                               blocks: blocks,
                                               bufferLines: bufferLines,
                                               hasBlockTracking: tab.blockTracker != nil)
    }

    /// Stage 0's one interactive action on the block view: re-parse
    /// `blockTracker.blocks` (already kept current by the OSC 133 handler -
    /// see `TerminalBlockTracker`'s header for why that's not the same as
    /// live-streaming) into the visible list. Nothing calls `render`
    /// automatically - this manual click is the only way the panel updates,
    /// by design (see `BlockView.swift`'s header).
    @objc func refreshBlockView() {
        guard let tab = currentTab, let tracker = tab.blockTracker, let container = tab.blockContainer else { return }
        container.render(tracker.blocks)
    }

    /// Shows/hides and restyles the two block-view toolbar buttons - only
    /// present at all when the current tab has a tracker (i.e. is the one
    /// opted-in host's tab with the feature enabled); every other tab hides
    /// both, matching `sreLeadButton`'s existing per-tab-relevance pattern.
    func updateBlockViewControls() {
        let available = currentTab?.blockContainer != nil
        blockViewToggleButton.isHidden = !available
        blockViewRefreshButton.isHidden = !available || !blockViewShowing
        guard available else { return }
        // `symbolName`, not `image`: `HelmButton` builds its glyph from that
        // property (at the variant's own point size / weight), so a directly
        // assigned `image` would be replaced the next time anything triggers
        // `rebuildImage()`.
        blockViewToggleButton.symbolName = blockViewShowing ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2"
        // `tint`, not `contentTintColor`: `HelmButton` owns the latter and
        // re-derives it on every theme change, so a direct assignment here
        // would survive exactly until the next theme switch. `nil` means "no
        // emphasis", i.e. the variant's own label colour.
        blockViewToggleButton.tint = blockViewShowing ? .accent : nil
        blockViewToggleButton.toolTip = blockViewShowing ? "Show Raw Scrollback" : "Show Parsed Blocks (Stage 0)"
        blockViewRefreshButton.toolTip = "Refresh Blocks"
    }
}
