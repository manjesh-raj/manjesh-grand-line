// Manjesh Grand Line - native macOS app.
//
// GENERATED FILE - do not hand-edit. Produced by
// `native/Scripts/build-straw-hat-flag.py` from the captain's v2 Jolly
// Roger reference image (`data/straw-hat-voice-order-composer-polish-8dd2/
// straw-hat-card-icon-v2-reference.png`, on the firstmate side - an input
// to that task, not an app asset, so it is not committed here). This
// replaced the original flag-in-sky photo reference with a flat-style
// icon already composed on its own card backdrop; see the script's own
// docstring for why the crop changed to "the whole image" as a result.
// Re-run that script to change the crop or the size; see its own docstring
// for why this is a base64 literal rather than an asset catalog or an SPM
// resource bundle and why the background is kept rather than cut out.
//
// The payload is a 128x128 PNG - ~3.8x the largest tile that renders it
// (`HelmGradientTile.Size.drill`, 34pt).

import AppKit

/// The Straw Hat crew's Jolly Roger, for the module card and the drill
/// header of the `.strawHat` destination.
///
/// `NSImage(data:)` returns nil on a corrupt payload rather than trapping,
/// and every call site treats nil as "fall back to the SF Symbol" - so a bad
/// regeneration degrades to a glyph rather than to a blank tile, exactly as
/// `StrawHatPortraits` does. `StrawHatSelfTest` asserts it decodes at the
/// expected size, because a silently-nil image is the kind of regression a
/// build cannot see.
enum StrawHatFlag {

    /// The pixel side of the payload below.
    static let side: CGFloat = 128

    /// The decoded flag, or nil if the payload is corrupt.
    ///
    /// **`isTemplate` is explicitly false.** A template image is drawn as a
    /// tintable mask, which would flatten the straw hat's tan and red and the
    /// skull's greys into one solid colour - i.e. it would throw away the
    /// entire reason this is a raster asset instead of an SF Symbol. `NSImage`
    /// from PNG data already defaults to false; this states the decision so a
    /// later "make it match the other tiles" edit has to argue with it.
    static var image: NSImage? {
        if let cached { return cached }
        guard let data = Data(base64Encoded: base64Chunks.joined()),
              let image = NSImage(data: data) else {
            AppLog.ui.error("straw hat: the Jolly Roger payload failed to decode")
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

    // 15731 bytes, 20976 base64 characters.
    private static let base64Chunks: [String] = [
        "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",
    ]
}
