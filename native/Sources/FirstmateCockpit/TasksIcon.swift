// Manjesh Grand Line - native macOS app.
//
// GENERATED FILE - do not hand-edit. Produced by
// `native/Scripts/build-card-shortcut-icons.py` from the captain's own
// reference image (`tasks.png`, committed under
// `native/Scripts/assets/grandline-card-shortcut-icons/` - see that
// script's own docstring for why the source lives in this repo rather
// than firstmate's `data/` directory, unlike `StrawHatFlag`/
// `StrawHatPortraits`). Re-run that script to change the crop or the
// size; see its own docstring for why this is a base64 literal rather
// than an asset catalog or an SPM resource bundle.
//
// a blue-to-orange gradient app icon with a white checklist card.
//
// The payload is a 128x128 PNG - well past any real Mac display's
// 2x for the tiles that render it
// (`HelmGradientTile.Size.module`/`.drill`, 30pt/34pt).

import AppKit

/// The card icon and floating-bar shortcut artwork for `.shift` (titled "Tasks" in this app's UI).
///
/// `NSImage(data:)` returns nil on a corrupt payload rather than trapping,
/// and every call site treats nil as "fall back to the SF Symbol" - so a
/// bad regeneration degrades to a glyph rather than to a blank tile,
/// exactly as `StrawHatFlag`/`StrawHatPortraits` do.
enum TasksIcon {

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
            AppLog.ui.error("TasksIcon: the icon payload failed to decode")
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

    // 15697 bytes, 20932 base64 characters.
    private static let base64Chunks: [String] = [
        "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",
    ]
}
