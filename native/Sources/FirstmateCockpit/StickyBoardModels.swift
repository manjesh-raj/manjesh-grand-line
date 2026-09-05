// Manjesh Grand Line - native macOS app.
//
// The Sticky Board's data model - a freeform corkboard of draggable, colored
// sticky notes for quick thoughts (captain's own request; a Lavish-reviewed
// interaction reference lives at
// `data/grandline-sticky-board/reference-cleaner-mockup.html`, inspiration
// only, never embedded - see `StickyBoardController.swift`'s header for what
// that means in practice).
//
// **Note colors are a deliberate exception to this app's "everything is a
// theme token" rule.** Every other surface in this app resolves its colors
// through `HelmTheme`/`HelmTint` so it looks right in all 14 themes. A real
// sticky note does not re-tint itself when the room's lighting changes - the
// captain's own instruction was explicit that the six paper hues below stay
// literal, fixed values. What DOES follow the active theme is the board's own
// background/chrome (`StickyBoardController.applyTheme`), never the notes
// sitting on it.
//
// Every (paper, ink) pair below clears WCAG AA's 4.5:1 text floor with real
// margin (8.75-10.25:1, computed with the exact formula `HelmContrast.ratio`
// uses) - verified in `StickyBoardSelfTest.checkColorContrast`, not just
// eyeballed. Both light and dark chrome around the note reads fine because
// the ink is dark-on-light in every case, independent of the app's own
// light/dark state - a real physical sticky note doesn't get harder to read
// because the room went dark either.

import Foundation

/// One of the six fixed paper colors a note can be. Declaration order is the
/// order `StickyBoardController`'s "+ New Note" picks from, and the order the
/// (rare, manual) color-swap menu on a note offers them in.
enum StickyNoteColor: String, CaseIterable, Codable {
    case yellow, pink, blue, green, orange, purple

    /// The note's paper fill.
    var paperHex: String {
        switch self {
        case .yellow: return "FFE066"
        case .pink: return "FFB3C6"
        case .blue: return "9BD3F5"
        case .green: return "A8E6A1"
        case .orange: return "FFC98A"
        case .purple: return "D3B3F5"
        }
    }

    /// The one ink color used for every label on this note - header kicker
    /// and body text alike. A single opaque value per color (not an
    /// alpha-reduced "muted" variant) is what keeps every text element on the
    /// note provably above the 4.5:1 floor without a second contrast check.
    var inkHex: String {
        switch self {
        case .yellow: return "3A2E00"
        case .pink: return "4A0E24"
        case .blue: return "0A2E45"
        case .green: return "0F3010"
        case .orange: return "4A2600"
        case .purple: return "2E1045"
        }
    }

    /// A touch darker than `paperHex` - the note's own border/fold-corner
    /// shading, drawn at low alpha over the paper so it works for all six
    /// colors without a seventh hardcoded value.
    static let edgeShadeAlpha: Double = 0.18
}

/// One sticky note. `id` is the on-disk identity (never regenerated from
/// content, matching `DocsRunbook`'s own convention) so an edit never orphans
/// the record.
struct StickyNote: Identifiable, Equatable {
    let id: String
    var text: String
    var color: StickyNoteColor
    /// Top-left position on the board, in the board's own (flipped, y grows
    /// downward) coordinate space - the same convention this app's other
    /// document views (`FlippedView`) already use, and the natural reading of
    /// a "top"/"left" position the reference mockup itself uses.
    var x: Double
    var y: Double
    /// A small, fixed tilt for the casual paper-note look (roughly -4...4
    /// degrees) - computed once, at creation, and never re-randomized on a
    /// later load. Persisting it (rather than re-rolling it every launch) is
    /// what makes the board look the same note to note across a relaunch,
    /// which is the whole point of a physical corkboard metaphor.
    var rotationDegrees: Double
    var createdAt: Date
}
