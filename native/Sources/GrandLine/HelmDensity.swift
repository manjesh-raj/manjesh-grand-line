// Grand Line - native macOS app.
//
// The feel pass's item 6: Comfortable or Compact, chosen in Settings,
// Appearance, Window (the feasibility audit's "a multiplier on
// `HelmType.scaledRowHeight`").
//
// **What it changes.** Every fixed row height in the app already goes
// through `HelmType.scaledRowHeight` (GL-32), so the text scale can move it.
// Density is one more factor in that same helper: Compact takes the
// prototype's 36-to-30 step off every list row, table row and sidebar row
// at once, and Comfortable is exactly today's height. It never changes the
// type scale, a radius or which elements a page shows.
//
// **How it reaches the pages.** The way a text-scale change does: every list
// re-reads `scaledRowHeight` in its own `applyTheme`, so the setter re-fires
// the current theme (`ThemeManager.reapplyCurrentTheme`) and each list picks
// up its new height. No page observes density on its own.

import Foundation

enum HelmDensity: String, CaseIterable {
    case comfortable
    case compact

    /// The captain's choice.
    static var current: HelmDensity { AppSettings.shared.density }

    var title: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    /// The factor on a row's height: the prototype's 30pt compact row over
    /// its 36pt comfortable one.
    var rowFactor: CGFloat {
        switch self {
        case .comfortable: return 1
        case .compact: return 30.0 / 36.0
        }
    }
}
