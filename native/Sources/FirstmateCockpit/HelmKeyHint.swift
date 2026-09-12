// Manjesh Grand Line - native macOS app.
//
// F2(c) and H1's footer strip: a keyboard shortcut rendered as small keycaps
// rather than as a run of raw symbol characters.
//
// **What was actually wrong.** `HelmFormSheet.setFooter` built its hint as the
// literal string "\u{2318}\u{23ce} to save" and set it in the sheet's ordinary
// muted label. Two separate problems, both named by the finding:
//
// 1. **The glyphs do not sit together.** U+2318 (PLACE OF INTEREST SIGN, the
//    Command loop) and U+23CE (RETURN SYMBOL) come from different Unicode
//    blocks and, in SF, from different optical families - they are drawn at
//    different weights and sit on different baselines, so "⌘⏎" reads as two
//    unrelated marks that have collided rather than as one shortcut. No
//    kerning value fixes that, because the two glyphs are not designed as a
//    pair.
// 2. **U+23CE is the wrong Return glyph for this platform.** macOS itself -
//    every menu key equivalent, every Apple shortcut list - draws Return as
//    U+21A9 (LEFTWARDS ARROW WITH HOOK). U+23CE is the Unicode *control
//    picture* for a carriage return, which is why it renders heavier and
//    taller than everything beside it.
//
// So: one glyph per keycap, each in its own bordered chip, using the glyphs
// macOS's own shortcut rendering uses. The chips give the two marks a shared
// optical frame - which is what makes them read as a pair regardless of how
// their outlines differ - and remove the side-by-side kerning question
// entirely, because they are no longer side by side in one text run.
//
// Self-theming (its own `ThemeManager` observation, unregistered in `deinit`)
// rather than relying on an owner's registry, so the two callers - a form
// sheet's footer and the ⌘K palette's footer strip - need no per-surface
// wiring. That is `HelmSkeletonRow`'s precedent, for the same reason.

import AppKit

/// A keyboard shortcut drawn as keycaps, with an optional trailing caption.
///
/// `HelmKeyHint(keys: ["\u{2318}", "\u{21a9}"], caption: "to save")` renders
/// `[⌘][↩] to save`.
final class HelmKeyHint: NSView {

    // MARK: The glyphs macOS itself uses

    /// U+2318. The Command loop.
    static let command = "\u{2318}"
    /// U+21A9. What macOS draws for Return in every menu key equivalent - see
    /// this file's header for why it is not U+23CE.
    static let returnKey = "\u{21a9}"
    /// U+238B. Escape.
    static let escape = "\u{238b}"
    /// U+2325 (Option) and U+21E7 (Shift), for completeness - a caller that
    /// needs them should not reach for a literal.
    static let option = "\u{2325}"
    static let shift = "\u{21e7}"
    static let control = "\u{2303}"

    /// The keycaps for a real `NSEvent.ModifierFlags` plus a key glyph, in
    /// macOS's own canonical order (⌃⌥⇧⌘). One definition, so a caller can
    /// hand over the same flags it gave `keyEquivalentModifierMask` and not
    /// have to know the order.
    static func keys(for modifiers: NSEvent.ModifierFlags, key: String) -> [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append(control) }
        if modifiers.contains(.option) { caps.append(option) }
        if modifiers.contains(.shift) { caps.append(shift) }
        if modifiers.contains(.command) { caps.append(command) }
        caps.append(key)
        return caps
    }

    // MARK: Geometry

    /// The keycap's corner radius. `HelmMetrics.rChip`'s smaller sibling - a
    /// 17pt-tall cap at radius 6 reads as a lozenge rather than as a key.
    static let capCornerRadius: CGFloat = 4
    /// Horizontal padding inside a cap, either side of its glyph.
    private static let capPaddingX: CGFloat = 4
    /// Vertical padding inside a cap.
    private static let capPaddingY: CGFloat = 2
    private static let capSpacing: CGFloat = 3
    private static let captionSpacing: CGFloat = 6

    private var capViews: [NSView] = []
    private var capLabels: [NSTextField] = []
    private var captionLabel: NSTextField?
    private var observation: ThemeObservation?

    init(keys: [String], caption: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(keys: keys, caption: caption)
        observation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
    }

    private func build(keys: [String], caption: String?) {
        var arranged: [NSView] = []
        for glyph in keys {
            let label = NSTextField(labelWithString: glyph)
            label.font = HelmType.chip()
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false

            let cap = NSView()
            cap.wantsLayer = true
            cap.layer?.cornerRadius = Self.capCornerRadius
            cap.layer?.borderWidth = HelmField.hairlineBorderWidth
            cap.translatesAutoresizingMaskIntoConstraints = false
            cap.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: Self.capPaddingX),
                label.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -Self.capPaddingX),
                label.topAnchor.constraint(equalTo: cap.topAnchor, constant: Self.capPaddingY),
                label.bottomAnchor.constraint(equalTo: cap.bottomAnchor, constant: -Self.capPaddingY),
                // Square-ish: a single glyph like ⌘ is narrower than the cap
                // should be, and two caps of visibly different widths beside
                // each other is the raggedness this component exists to fix.
                cap.widthAnchor.constraint(greaterThanOrEqualTo: cap.heightAnchor),
            ])
            capViews.append(cap)
            capLabels.append(label)
            arranged.append(cap)
        }

        let row = NSStackView(views: arranged)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Self.capSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        var outer: [NSView] = [row]
        if let caption, !caption.isEmpty {
            let label = NSTextField(labelWithString: caption)
            label.font = HelmType.caption()
            label.translatesAutoresizingMaskIntoConstraints = false
            captionLabel = label
            outer.append(label)
        }

        let stack = NSStackView(views: outer)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.captionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme(ThemeManager.shared.theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        // The cap is the app's own sunken-field surface at keycap scale: the
        // same fill and hairline every well in the app wears, which is what
        // makes a keycap read as part of this design rather than as a web
        // `<kbd>`. `muted`, never `faint` - §6.10's own note about the text
        // floor applies to the glyph as much as to the caption beside it.
        let fill = HelmField.fill(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6)
        let ink = HelmField.mutedInk(theme)
        HelmMotion.withoutImplicitAnimation {
            for cap in capViews {
                cap.layer?.backgroundColor = fill.cgColor
                cap.layer?.borderColor = line.cgColor
            }
        }
        for label in capLabels {
            label.font = HelmType.chip()
            label.textColor = ink
        }
        captionLabel?.font = HelmType.caption()
        captionLabel?.textColor = ink
    }

    #if FM_SELFTESTS
    /// The glyphs actually rendered, read off the real labels - so a check
    /// cannot pass by repeating the component's own idea of what it drew.
    var debugCapGlyphs: [String] { capLabels.map { $0.stringValue } }
    var debugCaption: String? { captionLabel?.stringValue }
    var debugCapCornerRadii: [CGFloat] { capViews.map { $0.layer?.cornerRadius ?? -1 } }
    #endif
}
