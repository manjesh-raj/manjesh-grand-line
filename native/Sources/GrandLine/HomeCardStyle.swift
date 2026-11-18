// Grand Line - native macOS app.
//
// The style of Home's two hero cards: Claude usage (the split hero) and Fleet
// (the full hero), the captain's picks on the widget-style board.
//
// The captain asked for two things on both cards. A size they can choose
// clearly - narrow, default and full width - and a colour they can choose
// and change ("i don't want a single color option"). Both live behind one
// header button (the palette glyph) that opens `HomeCardStyleMenu`.
//
// **Size is the arrangement's own.** The three modes are widths in
// `HomeCardGrid.columns`, exactly the three fixed sizes free sizing replaced
// (a quarter, a half and the whole row), so choosing one is the same edit a
// resize drag makes and it persists in `AppSettings.homeCardLayout` with the
// rest of Home's arrangement. A width dragged to anything else shows no mode
// checked. Only Home's own arranged cards have a size to choose; on another
// space or on the floating bar's hub the menu offers colour alone.
//
// **Colour is kept per card, apart from the layout** (`AppSettings.
// homeCardColors`), because it applies wherever the card is drawn. The theme's
// accent is the default and follows the theme. A preset or a custom colour is
// a fixed sRGB colour, and `HelmHeroSurface.palette(accent:)` deepens it until
// white text clears the text floor, in Daylight and Dusk alike - the same rule
// the briefing hero's own accent goes through.
//
// **State still shows through a chosen colour.** The hero keeps the captain's
// colour in every state; it does not turn amber or red. A warning or a limit
// is said by the headline, by the header's status pill, by the ring's arc in
// the state's colour, and on the Claude card by the report's own bars and
// figures, which sit on the card's surface and keep their severity colours. A
// stale reading dims the colour toward grey (GL-14).

import AppKit

/// One of the curated hero colours.
///
/// Fixed sRGB rather than theme tints: a preset is the colour the captain
/// chose, and a theme tint would move under it (Ayu's accent and its yellow
/// are one colour, for example). Spread around the wheel so no two read as
/// the same hue, and none is so light that white ink needs more than the
/// palette's usual deepening.
enum HomeCardColorPreset: String, CaseIterable {
    case ocean, teal, forest, violet, rose, ember, graphite

    var title: String {
        switch self {
        case .ocean: return "Ocean"
        case .teal: return "Teal"
        case .forest: return "Forest"
        case .violet: return "Violet"
        case .rose: return "Rose"
        case .ember: return "Ember"
        case .graphite: return "Graphite"
        }
    }

    var hex: String {
        switch self {
        case .ocean: return "#2F6FDE"
        case .teal: return "#0E8C99"
        case .forest: return "#3E8A2A"
        case .violet: return "#7652D6"
        case .rose: return "#CC4677"
        case .ember: return "#D2622A"
        case .graphite: return "#525A6A"
        }
    }
}

/// The colour one hero card is painted in.
enum HomeCardColor: Equatable {
    /// The theme's accent - the default, and it follows the theme.
    case accent
    case preset(HomeCardColorPreset)
    /// A colour from the system colour panel, as `#RRGGBB`.
    case custom(String)

    /// What `AppSettings.homeCardColors` stores.
    var storedValue: String {
        switch self {
        case .accent: return "accent"
        case let .preset(preset): return "preset:\(preset.rawValue)"
        case let .custom(hex): return hex
        }
    }

    /// `nil` for a value this build cannot read - a newer build's preset,
    /// or anything that is not a colour - which the caller treats as unset.
    init?(storedValue: String) {
        if storedValue == "accent" {
            self = .accent
        } else if storedValue.hasPrefix("preset:") {
            guard let preset = HomeCardColorPreset(rawValue: String(storedValue.dropFirst("preset:".count))) else {
                return nil
            }
            self = .preset(preset)
        } else if let hex = Self.normalisedHex(storedValue) {
            self = .custom(hex)
        } else {
            return nil
        }
    }

    var title: String {
        switch self {
        case .accent: return "Theme accent"
        case let .preset(preset): return preset.title
        case .custom: return "Custom colour"
        }
    }

    /// The tone the card is handed. The accent stays symbolic so the card
    /// re-reads it on a theme change without Home re-rendering.
    var heroColour: HelmModuleCard.HeroTone.Colour {
        switch self {
        case .accent: return .themeAccent
        case let .preset(preset): return Self.fixed(preset.hex)
        case let .custom(hex): return Self.fixed(hex)
        }
    }

    /// The colour as an sRGB triple in `theme`.
    func rgb(in theme: HelmTheme) -> (Double, Double, Double) {
        HelmModuleCard.HeroTone(colour: heroColour).accent(in: theme)
    }

    private static func fixed(_ hex: String) -> HelmModuleCard.HeroTone.Colour {
        let rgb = HelmContrast.components(HelmTheme.nsColor(hex))
        return .fixed(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    /// `#RRGGBB` in upper case, or `nil` when `text` is not six hex digits.
    static func normalisedHex(_ text: String) -> String? {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + digits.uppercased()
    }

    /// A colour panel's colour as `#RRGGBB`, in sRGB.
    static func hex(from color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(srgb.redComponent), byte(srgb.greenComponent),
                      byte(srgb.blueComponent))
    }
}

/// The three widths the style menu offers.
enum HomeCardSizeMode: CaseIterable {
    case narrow, standard, fullWidth

    var size: HomeCardLayout.CardSize {
        switch self {
        case .narrow: return .small
        case .standard: return .large
        case .fullWidth: return .fullWidth
        }
    }

    var columns: Int { size.columns }

    var title: String {
        switch self {
        case .narrow: return "Narrow"
        case .standard: return "Default"
        case .fullWidth: return "Full width"
        }
    }

    /// What the item says on hover - the width in words.
    var detail: String {
        switch self {
        case .narrow: return "A quarter of the row"
        case .standard: return "Half the row"
        case .fullWidth: return "The whole row"
        }
    }

    /// The mode a card's width is, or `nil` for a width dragged elsewhere.
    init?(columns: Int) {
        guard let mode = Self.allCases.first(where: { $0.columns == columns }) else { return nil }
        self = mode
    }
}

/// Which cards have a hero style, and the stored colour of each.
enum HomeCardStyle {
    static let modules: [DaylightModule] = [.claudeStatus, .fleet]

    static func color(for module: DaylightModule, settings: AppSettings = .shared) -> HomeCardColor {
        settings.homeCardColors[module.rawValue].flatMap(HomeCardColor.init(storedValue:)) ?? .accent
    }

    /// Store a card's colour. Every other entry is kept as it was, including
    /// one this build cannot read (GL-01's passthrough).
    static func setColor(_ color: HomeCardColor, for module: DaylightModule, settings: AppSettings = .shared) {
        var colors = settings.homeCardColors
        colors[module.rawValue] = color == .accent ? nil : color.storedValue
        settings.homeCardColors = colors
    }
}

/// The style menu behind a hero card's palette button: Size (when the card
/// can be sized), then Colour.
///
/// Every item carries its own action in `representedObject`, and the menu's
/// one target is `Dispatcher.shared`, because an `NSMenuItem`'s target is not
/// retained and a menu outlives the call that built it.
struct HomeCardStyleMenu {
    /// The card's current width, and how to change it. `nil` where the card
    /// has no size to choose.
    struct Sizing {
        let current: HomeCardSizeMode?
        let choose: (HomeCardSizeMode) -> Void
    }

    let cardTitle: String
    let sizing: Sizing?
    let color: HomeCardColor
    let chooseColor: (HomeCardColor) -> Void
    /// Open the system colour panel for a custom colour.
    let chooseCustomColor: () -> Void
    var theme: HelmTheme = ThemeManager.shared.theme

    static let tooltip = "Card size and colour"
    static let symbol = "paintpalette"

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "\(cardTitle) style")
        menu.autoenablesItems = false

        if let sizing {
            menu.addItem(Self.heading("Size"))
            for mode in HomeCardSizeMode.allCases {
                let item = Self.item(mode.title) { sizing.choose(mode) }
                item.state = sizing.current == mode ? .on : .off
                item.toolTip = mode.detail
                item.indentationLevel = 1
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(Self.heading("Colour"))
        let choices: [HomeCardColor] = [.accent] + HomeCardColorPreset.allCases.map { .preset($0) }
        for choice in choices {
            let item = Self.item(choice.title) { chooseColor(choice) }
            item.state = color == choice ? .on : .off
            item.image = Self.swatch(choice.rgb(in: theme))
            item.indentationLevel = 1
            menu.addItem(item)
        }
        let custom = Self.item("Custom colour\u{2026}") { chooseCustomColor() }
        if case .custom = color {
            custom.state = .on
            custom.image = Self.swatch(color.rgb(in: theme))
        }
        custom.toolTip = "Pick any colour. The card keeps white text readable on it."
        custom.indentationLevel = 1
        menu.addItem(custom)
        return menu
    }

    /// A disabled title row, standing in for macOS 14's section header.
    private static func heading(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func item(_ title: String, run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Dispatcher.pick(_:)), keyEquivalent: "")
        item.target = Dispatcher.shared
        item.representedObject = Action(run)
        return item
    }

    /// A 14pt rounded square in the hero's two stops for `accent`, so the
    /// swatch is the card's real gradient rather than the raw colour.
    static func swatch(_ accent: (Double, Double, Double)) -> NSImage {
        let palette = HelmHeroSurface.palette(accent: accent)
        let side: CGFloat = 14
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSGradient(starting: HelmContrast.color(palette.start), ending: HelmContrast.color(palette.end))?
                .draw(in: path, angle: -45)
            NSColor.black.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    final class Dispatcher: NSObject {
        static let shared = Dispatcher()
        @objc func pick(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.run() }
    }
}

/// The system colour panel, pointed at one card at a time.
///
/// `isContinuous` is off, so a drag across the wheel stores one colour when
/// it ends rather than re-rendering Home on every step of it.
final class HomeCardColorPanel: NSObject {
    static let shared = HomeCardColorPanel()

    private var onPick: ((HomeCardColor) -> Void)?

    func open(current: (Double, Double, Double), onPick: @escaping (HomeCardColor) -> Void) {
        self.onPick = onPick
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = false
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.color = HelmContrast.color(current)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let hex = HomeCardColor.hex(from: sender.color) else { return }
        onPick?(.custom(hex))
    }
}
