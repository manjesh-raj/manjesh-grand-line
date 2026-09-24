// Grand Line - the WidgetKit extension.
//
// The app's Daylight/Dusk tokens, in the one form a widget can use.
//
// ## Why the values are duplicated here, and what stops them drifting
//
// The extension is a separate Mach-O that cannot link `GrandLine`:
// `HelmDaylight.swift` reaches `AppKit`, `ThemeManager` and `HelmContrast`
// within a few lines, and pulling that in would mean pulling in the whole app.
// So the two tables are literal hex strings in two binaries, which is exactly
// the shape this repo's own audits keep finding as a defect.
//
// What makes it safe is a guard rather than a promise:
// `WidgetSnapshotSelfTest.checkThePaletteMatchesDaylight` greps this file and
// asserts every token below equals `DaylightTokens.light`/`.dusk`'s own value
// and that the two domain-hue pairs equal `HelmDomainHue`'s. Change a token in
// `HelmDaylight.swift` without changing it here and the suite fails by name.
// Confirmed to catch it: see that case's own comment.
//
// ## Which register a widget draws in
//
// The snapshot carries it (`GrandLineWidgetSnapshot.Appearance`), because the
// app's theme is a choice out of fourteen palettes and not the system
// appearance - Dusk is the default on a Mac that may be in light mode. The
// environment's `colorScheme` is the fallback for the one case where there is
// no snapshot: the "Not available" state, where there is nothing else to go on.

import SwiftUI

/// One register's tokens. Field-for-field a subset of the app's
/// `DaylightTokens` - only the ones a widget actually paints.
struct WidgetPalette {
    let paper: Color
    let card: Color
    let inset: Color
    let hair: Color
    let ink: Color
    let muted: Color
    let faint: Color
    let okText: Color
    let warnText: Color
    let badText: Color

    /// `DaylightTokens.light` - `HelmDaylight.swift`'s §2.1 table.
    static let daylight = WidgetPalette(
        paper: Color(hex: "F5F2EA"),
        card: Color(hex: "FFFFFF"),
        inset: Color(hex: "F3F0E7"),
        hair: Color(hex: "E4DFD2"),
        ink: Color(hex: "2A2B33"),
        muted: Color(hex: "726D60"),
        faint: Color(hex: "B0AA97"),
        okText: Color(hex: "1D7B5E"),
        warnText: Color(hex: "93621E"),
        badText: Color(hex: "BC4142")
    )

    /// `DaylightTokens.dusk` - the app's default theme.
    static let dusk = WidgetPalette(
        paper: Color(hex: "191A1F"),
        card: Color(hex: "23242B"),
        inset: Color(hex: "1E1F25"),
        hair: Color(hex: "383A45"),
        ink: Color(hex: "E8E6DE"),
        muted: Color(hex: "979283"),
        faint: Color(hex: "6B675C"),
        okText: Color(hex: "38A882"),
        warnText: Color(hex: "CD8D2E"),
        badText: Color(hex: "E07272")
    )

    static func resolve(_ appearance: GrandLineWidgetSnapshot.Appearance) -> WidgetPalette {
        appearance == .light ? .daylight : .dusk
    }

    static func resolve(_ colorScheme: ColorScheme) -> WidgetPalette {
        colorScheme == .light ? .daylight : .dusk
    }
}

/// The app's own per-feature identity gradients (`HelmDomainHue`'s §2.2
/// pairs), which that file's header is explicit do **not** move between
/// light and dark - so neither do these.
///
/// Tasks is `rose` and the Sticky Board is `amber`, taken from the app's own
/// `RailDestination` mapping rather than from the reviewed mockup, which drew
/// the Tasks tile violet. The identity table is the app's, and a widget that
/// used a different hue for Tasks than every other Tasks surface would be the
/// one place the captain's own colour language breaks.
enum WidgetDomainHue {
    static let taskGradient = [Color(hex: "D9527E"), Color(hex: "EC8FAC")]   // HelmDomainHue.rose
    static let stickyGradient = [Color(hex: "C77E13"), Color(hex: "E8AE4E")] // HelmDomainHue.amber
}

extension Color {
    /// `RRGGBB`, the form every token in this app is written in.
    ///
    /// Deliberately total: an unparseable string yields a visible magenta
    /// rather than a crash or a silent clear, because a widget that renders
    /// nothing looks identical to a widget with no data - which is the GL-14
    /// failure this whole feature is most exposed to.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = Color(red: 1, green: 0, blue: 1)
            return
        }
        self = Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: 1
        )
    }
}
