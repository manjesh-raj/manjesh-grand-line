// Grand Line - native macOS app.
//
// The ⌥Space capture panel's derived words, for CP-1 "Hero head capture" on
// the hero restyle board (`data/grandline-hero-restyle-designs-scout/`).
//
// Pure, Foundation only, so `CaptureRouterSelfTest` asserts it in CI's
// blocking lane. The panel's other words are unchanged and stay where they
// were (`ShiftQuickCapture.swift`), because `ReviewTwoUXModelSelfTest` reads
// that file for the crew wording R2-UX-01 retired.
//
// **The hint is derived from the destinations, not written out.** It said
// "⌘1–⌘5 choose" for as long as there were five, and F4 appended Link as ⌘6
// without anything noticing: the tile printed ⌘6 and the hint under it still
// stopped at ⌘5 (the board's finding 3). `chordRange` reads
// `CaptureDestination.allCases`, the same order `chordDigit` is derived from,
// so a seventh destination moves the hint with it.

import Foundation

enum CaptureHeroWords {

    /// "⌘1–⌘6": the first chord to the last, from the destinations
    /// themselves.
    static var chordRange: String {
        let first = CaptureDestination.allCases.first?.chordDigit ?? 1
        let last = CaptureDestination.allCases.last?.chordDigit ?? first
        return "\u{2318}\(first)\u{2013}\u{2318}\(last)"
    }

    /// The footer's key hint. Only the range is new; the words around it are
    /// the panel's own.
    static var hint: String {
        "\u{23CE} file as a task \u{00B7} \(chordRange) choose \u{00B7} Esc dismiss"
    }
}
