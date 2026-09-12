// Manjesh Grand Line - native macOS app.
//
// I1 and I2 of the UI modernization audit: the app's one place for building an
// SF Symbol image.
//
// **I1's headline.** "Adopt **hierarchical rendering** for SF Symbols
// (currently zero usage) - it is the single cheapest '2022+' signal macOS
// iconography has." Verified before this shipped: no `symbolRenderingMode`,
// no `SymbolConfiguration(hierarchicalColor:)`, no palette or multicolour
// anywhere in the tree. Every glyph in the app was flat monochrome, tinted by
// `contentTintColor`.
//
// **What hierarchical actually buys, and where it buys nothing.** A
// hierarchical configuration takes one colour and derives the symbol's
// secondary and tertiary layers from it at reduced opacity - so
// `exclamationmark.triangle.fill` gets a lighter triangle behind a full-weight
// mark, and `bell.badge` gets a quieter bell behind its badge. On a
// **single-layer** symbol it renders identically to the flat version. That is
// what makes adopting it everywhere safe rather than a redesign: the symbols
// that have depth gain it, and the ones that do not are unchanged.
//
// **The one structural consequence, and the reason this is a shared helper
// rather than a line per call site.** A hierarchical image carries its own
// colours, so it is **not** a template and `contentTintColor` no longer
// reaches it. A component that used to tint on every theme change has to
// *rebuild* the image instead - which means it has to have kept the symbol
// name, point size and weight. Every adopter here stores that trio and calls
// `HelmSymbol.image` from its own `applyTheme`.
//
// **I2**: "several look light against bold labels ... `.medium`/`.semibold`
// symbol configurations paired to the adjacent text weight". `weight(for:)`
// is that pairing, expressed once, so a new call site asks the question
// rather than picking a weight by eye.

import AppKit

enum HelmSymbol {

    /// The symbol weight that sits beside a label of `textWeight` (I2).
    ///
    /// SF Symbols are designed to be weight-matched to their label - a
    /// regular-weight glyph next to a semibold row title reads as a lighter,
    /// separate object rather than as part of the same line. One step below
    /// the text is the pairing Apple's own HIG describes, floored at
    /// `.medium`: the audit's actual complaint is glyphs looking *light*, and
    /// a `.regular` glyph beside a `.regular` label is the most common case in
    /// this app.
    static func weight(for textWeight: NSFont.Weight) -> NSFont.Weight {
        switch textWeight {
        case .heavy, .black: return .bold
        case .bold: return .semibold
        case .semibold: return .semibold
        case .medium: return .medium
        default: return .medium
        }
    }

    /// Build an SF Symbol image.
    ///
    /// - Parameter hierarchicalColor: when given, the symbol renders
    ///   hierarchically in that colour and the result is **not** a template -
    ///   so the caller must rebuild on a theme change rather than re-tinting.
    ///   When `nil` the image is the flat template every pre-I1 call site
    ///   produced, byte for byte.
    static func image(_ name: String,
                      pointSize: CGFloat,
                      weight: NSFont.Weight = .medium,
                      hierarchicalColor: NSColor? = nil,
                      accessibilityDescription: String? = nil) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name,
                                 accessibilityDescription: accessibilityDescription) else {
            // `NSImage(systemSymbolName:)` returns nil silently, and this app
            // has shipped an invisible icon that way before - so a name that
            // does not resolve is logged rather than swallowed.
            AppLog.ui.error("symbol \(name, privacy: .public) did not resolve")
            return nil
        }
        var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let hierarchicalColor {
            // `.applying` composes rather than replaces, so the point size and
            // weight above survive - assigning a fresh
            // `SymbolConfiguration(hierarchicalColor:)` would drop both.
            config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: hierarchicalColor))
        }
        return base.withSymbolConfiguration(config)
    }

    /// Whether a rendered image came back hierarchical.
    ///
    /// A hierarchical image carries its own colours, so it is not a template -
    /// which is the one property a caller (or a check) can read back to tell
    /// the two paths apart. There is no public API that reports the rendering
    /// mode of an `NSImage`.
    static func isHierarchical(_ image: NSImage?) -> Bool {
        guard let image else { return false }
        return !image.isTemplate
    }
}
