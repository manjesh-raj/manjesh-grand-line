// Manjesh Grand Line - native macOS app.
//
// The app's one recorded-keystroke value, and the one thing both features
// that let a captain choose their own shortcut store.
//
// It began as `DictationShortcut`, declared inside `DictationHotkey.swift` -
// a general value wearing one feature's name. `fm/grand-line-terminal-
// shortcuts-settings` needed the identical thing for the Console's own
// configurable tab/split shortcuts, and the honest answer to "don't build a
// second recorder" is one chord type and one recorder rather than a second
// pair named after whoever asked next. Nothing about the shape changed in
// that move, and the JSON is byte-compatible: `Codable` synthesises its keys
// from the property names (`keyCode`, `modifierFlagsRaw`, `isModifierOnly`),
// none of which were touched, so a `fm.dictationShortcut` written by an
// earlier build - and a `.glbackup` exported by one - still decodes.
//
// Two shapes, because the two features need different ones:
//
//   * **Modifier-only** (Right ⌥ Option, Left ⇧, ...). A bare modifier fires
//     `.flagsChanged`, never `keyDown`/`keyUp`, so "held" is the flag being
//     present. This is what dictation's hold-to-record needs and the only
//     shape phase 1 shipped.
//   * **Regular key + modifiers** (⌘⇧D, ⌃⌘→). Ordinary `keyDown`/`keyUp`.
//     This is the only shape a *command* shortcut may take: a modifier-only
//     "split right" would fire every time the captain reached for ⌘.
//
// `isModifierOnly` is decided once, at record time, by
// `KeyChordRecorderView` - see that file for how it tells the two apart while
// capturing, and for the `Mode` that lets the terminal-shortcut rows refuse
// the first shape outright.

import AppKit

/// A recorded shortcut - either a single held modifier key, or a regular key
/// plus zero or more modifiers. `Codable` so it round-trips through
/// `AppSettings.dictationShortcut` and `AppSettings.terminalShortcuts` as
/// JSON `Data`.
///
/// Only the four standard modifiers (⌘⌥⌃⇧) are ever tracked, deliberately
/// excluding Caps Lock/Fn from `relevantModifierMask` - Caps Lock's flag
/// reflects a toggle *state*, not a momentary press, so a captain who happens
/// to have Caps Lock on would silently break matching if it were included
/// (recorded without it, matched against an event that now always carries
/// it, or vice versa). Fn was excluded for the same "ambient/sticky, not a
/// deliberate press" reasoning.
struct KeyChord: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlagsRaw: UInt
    var isModifierOnly: Bool

    static let relevantModifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlagsRaw) }

    static let dictationDefault = KeyChord(
        keyCode: DictationHotkey.rightOptionKeyCode,
        modifierFlagsRaw: NSEvent.ModifierFlags.option.rawValue,
        isModifierOnly: true
    )

    /// `kVK_RightOption`/`kVK_RightCommand`/... - Carbon's `HIToolbox`
    /// virtual keycodes for the standard modifier keys, both sides where
    /// macOS distinguishes them. No Carbon dependency needed for these
    /// literal values, same reasoning `ShiftGlobalHotkey.spaceKeyCode`'s
    /// header already documents.
    private static let modifierKeyNames: [UInt16: String] = [
        54: "Right ⌘", 55: "Left ⌘",
        56: "Left ⇧", 60: "Right ⇧",
        58: "Left ⌥", 61: "Right ⌥",
        59: "Left ⌃", 62: "Right ⌃",
    ]

    /// A modest table of common regular keys for display purposes - this
    /// isn't meant to be exhaustive (an unmapped key still displays, just as
    /// "Key N"), only to cover the combos a captain is actually likely to
    /// record (a letter, digit, or one of a few common keys alongside ⌘/⌥/⌃/⇧).
    private static let regularKeyNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
        15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
        // The four arrows and the two brackets, added for the terminal
        // shortcuts: a split's direction is most readable as the arrow that
        // points that way, and `[`/`]` is what every macOS app that has
        // next/previous-tab uses.
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        33: "[", 30: "]", 27: "-", 24: "=", 47: ".", 43: ",", 39: "'", 41: ";", 42: "\\", 44: "/", 50: "`",
    ]

    /// Whether this chord carries at least one of ⌘⌥⌃⇧.
    ///
    /// Only meaningful for a regular-key chord, and it is what the terminal
    /// shortcuts require: a bare `W` recorded as a "close pane" shortcut would
    /// eat the letter the captain was typing into their shell. Dictation has
    /// no such requirement - a bare key it can hold is a legitimate
    /// hold-to-record trigger - so this is a caller's rule rather than an
    /// invariant of the type.
    var hasModifiers: Bool { !modifiers.isEmpty }

    static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        modifierKeyNames[keyCode] != nil
    }

    var displayString: String {
        if isModifierOnly {
            return Self.modifierKeyNames[keyCode] ?? "Key \(keyCode)"
        }
        var s = ""
        let m = modifiers
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        s += Self.regularKeyNames[keyCode] ?? "Key \(keyCode)"
        return s
    }
}

