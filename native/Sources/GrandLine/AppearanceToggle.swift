// Grand Line - native macOS app.
//
// The window toolbar's light/dark toggle: its two symbols and the tooltip
// it shows. These lived on `DaylightThemeToggleButton`, the floating bar's
// square, which P-03 of the 2026-11-25 review removed with the rest of that
// layout. The sidebar shell's toolbar item was already reading them from
// there, so they moved here unchanged.

import Foundation

enum AppearanceToggle {
    static let lightSymbol = HelmSymbol.Role.themeLight.name
    static let darkSymbol = HelmSymbol.Role.themeDark.name

    /// No chord in it: the "(⌘⌥T)" this used to promise went with the View
    /// menu (`buildMenu`'s note on its removal), so the tooltip was offering a
    /// shortcut that did nothing.
    ///
    /// The theme split added the second sentence: this flips the **app's**
    /// appearance, and whether the terminal moves with it depends on Settings
    /// > Terminal > Terminal colours, so the tooltip says which.
    static func tooltip(isDark: Bool) -> String {
        let flip = isDark ? "Dark appearance - switch to Light" : "Light appearance - switch to Dark"
        return "\(flip). \(terminalNote(ThemeManager.shared.terminalColors))"
    }

    static func terminalNote(_ colors: TerminalColorsSettings) -> String {
        switch (colors.mode, colors.changesWithAppearance) {
        case (.matchApp, _): return "The terminal follows."
        case (.custom, true): return "The terminal switches to its own light or dark scheme."
        case (.custom, false): return "The terminal keeps the scheme chosen for it in \(PlaceName.of(.settings))."
        }
    }
}
