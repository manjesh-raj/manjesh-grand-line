// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-drag-forward-indicator`: how a `.shell` tab's per-tab
// `CockpitTerminalView.forwardDragsToChild` toggle is described wherever it's
// shown - the toolbar's own "drag routing" button (`ConsoleController+
// Toolbar.swift`) and, indirectly, the tab chip's small indicator icon
// (`TabChipView.swift`).
//
// A scout investigation (`data/grandline-console-chat-selection-scout/
// report.md`) found the toggle's only visible surface was that chip icon -
// tiny, tinted the same as everything else on the chip, and only shown at
// all while the toggle is on - which is why a captain hit "the same gesture,
// different selection colour, nothing else visibly different" without
// noticing it. This is the display half of the fix: mirrors `SRELeadPhase`/
// `KubeContextBadgeStatus`'s exact shape (a display-only computed mapping
// from real, already-existing state to symbol/title/tint/tooltip), not a new
// piece of state - `forwardDragsToChild` is still the one and only source of
// truth, this only decides how to describe it.
//
// **Deliberately not touching the routing itself.** `divertsToLocalSelection`
// (`CockpitTerminalView.swift`) and `prefersLocalSelection` are untouched -
// this file only reads `forwardDragsToChild`, never writes it (writing is
// still `ConsoleController.toggleForwardDragsToChild(id:)`, unchanged, now
// with one more caller).

import AppKit

/// How one `.shell` tab's plain drag / Shift+drag currently routes, purely
/// for display - derived from `CockpitTerminalView.forwardDragsToChild`.
enum DragForwardingIndicator: Equatable {
    /// The default everywhere: a plain drag builds this app's own themed
    /// selection; holding Shift forwards the drag to the tab's program
    /// (e.g. herdr) instead.
    case local
    /// The captain's own per-tab toggle is on (right-click the tab, or the
    /// toolbar button below - "Forward Drags to This Tab's Program"): the two
    /// gestures swap, so a plain drag now forwards and Shift+drag is what
    /// builds this app's own selection.
    case forwarding

    init(forwardDragsToChild: Bool) {
        self = forwardDragsToChild ? .forwarding : .local
    }
}

extension DragForwardingIndicator {
    /// Both names were already proven to resolve on this OS before being
    /// reused here (`arrowshape.turn.up.forward.fill` was already in use on
    /// the tab chip's own indicator; `character.cursor.ibeam` was checked
    /// directly - `NSImage(systemSymbolName:)` fails silently, and this app
    /// has shipped an invisible icon that way before, see `AGENTS.md`).
    var buttonSymbol: String {
        switch self {
        case .local: return "character.cursor.ibeam"
        case .forwarding: return "arrowshape.turn.up.forward.fill"
        }
    }

    var buttonTitle: String {
        switch self {
        case .local: return "Local Selection"
        case .forwarding: return "Forwarding Drags"
        }
    }

    /// `nil` for `.local` - the default state should read at the same weight
    /// as every other toolbar control, not quieter for being unremarkable
    /// (`SRELeadPhase.tint`'s own reasoning for `.notStarted`). `.forwarding`
    /// is the state worth a second look, so it gets `.warn` - the same tint
    /// the tab chip's own indicator glyph now carries, so the two surfaces
    /// never disagree about which colour means "on".
    var buttonTint: HelmTint? {
        switch self {
        case .local: return nil
        case .forwarding: return .warn
        }
    }

    /// Spells out both halves of the gesture in either state, so hovering
    /// this - on either the toolbar button or the chip's own icon - answers
    /// the acceptance question directly: what does a plain drag do, what
    /// does a Shift+drag do, right now, on this tab.
    var tooltip: String {
        switch self {
        case .local:
            return "Drags in this tab build this app's own themed selection.\n\n"
                + "Plain drag \u{2192} this app's selection.\n"
                + "Shift+drag \u{2192} forwarded to this tab's program (e.g. herdr) instead.\n\n"
                + "Click to swap this, or right-click the tab for the same toggle."
        case .forwarding:
            return "Drags in this tab are forwarded to its program (e.g. herdr) instead of building "
                + "this app's own selection.\n\n"
                + "Plain drag \u{2192} forwarded to this tab's program.\n"
                + "Shift+drag \u{2192} this app's own selection instead.\n\n"
                + "Click to turn this off, or right-click the tab for the same toggle."
        }
    }
}
