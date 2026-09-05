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
// **The board underneath them is a THIRD category, and the distinction is
// the whole point of `fm/grandline-sticky-code-preview-polish`.** The
// captain's own correction was that the board itself is a real cork board
// (see `StickyBoardCork` below): cork is cork, so its hue is literal in the
// same way a note's paper is - but a cork board photographed in a dark room
// is a *darker* cork, so its tone genuinely follows the app's light/dark
// mode. So there are three rules in this feature, not two:
//
//   - Board/toolbar/header chrome: full theme tokens (`HelmTheme`), like
//     every other page in the app.
//   - The cork surface and its wood frame: literal cork/wood hues, chosen
//     per `theme.mode` - never per palette, so all seven light themes show
//     the same cork and all seven dark ones show the same darker cork.
//   - A note's own paper: one literal value, identical in all 14 themes.
//
// Every (paper, ink) pair below clears WCAG AA's 4.5:1 text floor with real
// margin (8.75-10.25:1, computed with the exact formula `HelmContrast.ratio`
// uses) - verified in `StickyBoardSelfTest.checkColorContrast`, not just
// eyeballed. Both light and dark chrome around the note reads fine because
// the ink is dark-on-light in every case, independent of the app's own
// light/dark state - a real physical sticky note doesn't get harder to read
// because the room went dark either.

import AppKit

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

/// The cork board's own surface and frame - literal cork/wood hues chosen by
/// the app's light/dark **mode**, never by palette. See this file's header for
/// why this is a deliberate third colour category rather than either a theme
/// token or a fixed literal.
///
/// The captain's authoritative reference is a photo of a real corkboard in a
/// wooden picture frame: tan/brown flecked cork inside a wood-toned border.
/// (An earlier "detective corkboard" mockup showed a green felt board; the
/// captain's own later correction explicitly overrides it - "NOT the green
/// felt board", "use the plain cork-photo reference as the authoritative
/// colour/material direction". Where a spec's summary line and the captain's
/// own explicit description disagree, AGENTS.md's standing rule is that the
/// description wins.)
enum StickyBoardCork {
    /// The cork's base fill. The flecks in `StickyBoardCanvasView`'s tile are
    /// drawn as lighter/darker variants of exactly this.
    static func baseHex(dark: Bool) -> String { dark ? "5A4130" : "C9A87C" }

    /// The darker speck. Cork's own pits read as shadow, so this is the base
    /// pushed toward black rather than a separate hue.
    static func fleckDarkHex(dark: Bool) -> String { dark ? "42301F" : "A8834F" }

    /// The lighter speck - the raised, catching-the-light half of the grain.
    static func fleckLightHex(dark: Bool) -> String { dark ? "6E5340" : "DCC099" }

    /// The picture-frame band around the board. Drawn as the board card's own
    /// fill with the scroll view inset inside it (see
    /// `StickyBoardController`), which is what makes it read as a frame the
    /// cork sits inside rather than a border stroked on top of it.
    static func frameHex(dark: Bool) -> String { dark ? "3B2A1B" : "8B5E3C" }

    /// How wide that band is.
    static let frameWidth: CGFloat = 7
}

/// The Sticky Board's own font roles.
///
/// Named-font wrapping goes through a small feature-scoped accessor rather
/// than an inline `NSFont(name:)` at each call site - `ShiftFont` (Shift's
/// Georgia serif) is the established precedent for exactly this shape. Two
/// things this buys that a literal would not:
///
///   - **A ranked fallback chain.** `NSFont(name:size:)` returns `nil` for a
///     name macOS does not have, and the usual `?? .systemFont` then fails
///     *silently* - a typo ships as "the handwriting font didn't apply" with
///     no error anywhere (`NSFont(name: "Chalkboard-Regular", ...)` is a real
///     example: `Chalkboard` resolves, `Chalkboard-Regular` does not).
///     `resolve(_:size:)` walks a list and only falls back to the system font
///     when every candidate is genuinely absent.
///   - **One place for a self-test to assert the resolution actually
///     happened**, which `StickyBoardSelfTest.checkFonts` does by checking the
///     resolved face is not the system font.
///
/// Every name below was verified to resolve on macOS before shipping.
enum StickyFont {
    /// The note body: a real handwriting face, per the captain's reference
    /// photo of index cards. Noteworthy leads because it stays legible at
    /// small sizes across several lines, which a marker face does not.
    static func hand(_ size: CGFloat) -> NSFont {
        resolve(["Noteworthy-Light", "BradleyHandITCTT-Bold", "MarkerFelt-Thin", "Chalkboard"], size: size)
    }

    /// The note's own title line - the reference photo's "IDEA #01" /
    /// "QUESTION" / "CLUE" header. Same family as the body where possible, so
    /// a note reads as one hand.
    static func handBold(_ size: CGFloat) -> NSFont {
        resolve(["Noteworthy-Bold", "BradleyHandITCTT-Bold", "MarkerFelt-Wide", "ChalkboardSE-Bold"], size: size)
    }

    /// The board's own case-file header - the reference's typewriter voice.
    static func typewriter(_ size: CGFloat) -> NSFont {
        resolve(["AmericanTypewriter-Bold", "CourierNewPS-BoldMT"], size: size)
    }

    /// Walks `names` in order, returning the first face macOS actually has.
    /// Falls back to a bold system font only when none of them resolve.
    static func resolve(_ names: [String], size: CGFloat) -> NSFont {
        for name in names {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return .systemFont(ofSize: size, weight: .semibold)
    }
}

/// One sticky note. `id` is the on-disk identity (never regenerated from
/// content, matching `DocsRunbook`'s own convention) so an edit never orphans
/// the record.
struct StickyNote: Identifiable, Equatable {
    let id: String
    /// The captain's own short label for this note, rendered as its own bold
    /// header line above the body - the reference photo's index-card headers.
    /// Empty is a legitimate value (a note with nothing but body text), which
    /// is why it is not optional: the view renders a placeholder rather than
    /// collapsing the row, so the field stays discoverable.
    var title: String
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
    /// The note's own size. Persisted per note (like `x`/`y`) so a note the
    /// captain grew to hold a longer thought is still that size next launch.
    /// Clamped to `StickyBoardMetrics.minNoteSize...maxNoteSize` on the way in
    /// and out - see `StickyBoardMetrics.clampSize(_:)`.
    var width: Double
    var height: Double
    var rotationDegrees: Double
    var createdAt: Date

    var size: CGSize { CGSize(width: width, height: height) }
}
