// Manjesh Grand Line - native macOS app.
//
// GENERATED FILE - do not hand-edit. Produced by
// `native/Scripts/build-card-shortcut-icons.py` from the captain's own
// reference image (`sticky-notes.png`, committed under
// `native/Scripts/assets/grandline-card-shortcut-icons/` - see that
// script's own docstring for why the source lives in this repo rather
// than firstmate's `data/` directory, unlike `StrawHatFlag`/
// `StrawHatPortraits`). Re-run that script to change the crop or the
// size; see its own docstring for why this is a base64 literal rather
// than an asset catalog or an SPM resource bundle.
//
// a blue app icon with a yellow sticky note pinned by a red pushpin.
//
// The payload is a 128x128 PNG - well past any real Mac display's
// 2x for the tiles that render it
// (`HelmGradientTile.Size.module`/`.drill`, 30pt/34pt).

import AppKit

/// The card icon and floating-bar shortcut artwork for `.stickyBoard`.
///
/// `NSImage(data:)` returns nil on a corrupt payload rather than trapping,
/// and every call site treats nil as "fall back to the SF Symbol" - so a
/// bad regeneration degrades to a glyph rather than to a blank tile,
/// exactly as `StrawHatFlag`/`StrawHatPortraits` do.
enum StickyNotesIcon {

    /// The pixel side of the payload below.
    static let side: CGFloat = 128

    /// The decoded icon, or nil if the payload is corrupt.
    ///
    /// **`isTemplate` is explicitly false.** A template image is drawn as a
    /// tintable mask, which would flatten this artwork's own colours into
    /// one solid colour - i.e. it would throw away the entire reason this
    /// is a raster asset instead of an SF Symbol. `NSImage` from PNG data
    /// already defaults to false; this states the decision so a later
    /// "make it match the other tiles" edit has to argue with it.
    static var image: NSImage? {
        if let cached { return cached }
        guard let data = Data(base64Encoded: base64Chunks.joined()),
              let image = NSImage(data: data) else {
            AppLog.ui.error("StickyNotesIcon: the icon payload failed to decode")
            return nil
        }
        image.isTemplate = false
        cached = image
        return image
    }

    /// Decoded once and kept for the process's life - the canvas rebuilds its
    /// grid on every window resize, and re-decoding a PNG per pass would be
    /// real work for a static asset.
    private static var cached: NSImage?

    // 19354 bytes, 25808 base64 characters.
    private static let base64Chunks: [String] = [
        "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",
        "rkJggg==",
    ]
}
