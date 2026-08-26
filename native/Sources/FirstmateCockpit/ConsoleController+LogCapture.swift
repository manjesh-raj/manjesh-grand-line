// Manjesh Grand Line - native macOS app.
//
// GL-36, part of `ConsoleController`'s decomposition: Block View
// (`fm/cockpit-block-view-stage0`) - the shell marking its own command
// boundaries (OSC 133) so this app can see them and render parsed blocks
// instead of raw scrollback.
//
// This file used to also hold the Log Analyzer capture bridge (spec §2),
// which read those same OSC 133 marks to decide how much scrollback a
// captain meant by "analyze this" - removed along with the rest of that
// feature by `fm/grandline-menubar-remove-items`, which also collapsed a
// console down to one session and renamed every `tab` here to `session`
// accordingly.

import AppKit
import SwiftTerm

extension ConsoleController {

    // MARK: Block view (`fm/cockpit-block-view-stage0`)

    /// Decides which of the session's two views (raw `terminal` or parsed
    /// `blockContainer`) is visible right now - never both. Toggling never
    /// touches `terminal`'s process or `startProcess` state either way. A
    /// session with no `blockContainer` (every session except the one
    /// opted-in host's, when the feature is enabled - see
    /// `ConsoleSession.blockViewOptIn`) always shows raw `terminal`
    /// regardless of `blockViewShowing`.
    func updateSessionViewVisibility(_ target: ConsoleSession) {
        if blockViewShowing, let container = target.blockContainer {
            target.terminal.isHidden = true
            container.isHidden = false
        } else {
            target.terminal.isHidden = false
            target.blockContainer?.isHidden = true
        }
    }

    /// Toolbar toggle - only meaningful (and only shown at all, see
    /// `updateBlockViewControls`) for the one opted-in host's session.
    @objc func toggleBlockView() {
        guard session?.blockContainer != nil else { return }
        blockViewShowing.toggle()
        if let target = session { updateSessionViewVisibility(target) }
        updateBlockViewControls()
    }

    /// Stage 0's one interactive action on the block view: re-parse
    /// `blockTracker.blocks` (already kept current by the OSC 133 handler -
    /// see `TerminalBlockTracker`'s header for why that's not the same as
    /// live-streaming) into the visible list. Nothing calls `render`
    /// automatically - this manual click is the only way the panel updates,
    /// by design (see `BlockView.swift`'s header).
    @objc func refreshBlockView() {
        guard let target = session, let tracker = target.blockTracker, let container = target.blockContainer else { return }
        container.render(tracker.blocks)
    }

    /// Shows/hides and restyles the two block-view toolbar buttons - only
    /// present at all when this console's session has a tracker (i.e. is the
    /// one opted-in host's session with the feature enabled).
    func updateBlockViewControls() {
        let available = session?.blockContainer != nil
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
