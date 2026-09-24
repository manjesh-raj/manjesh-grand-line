// Manjesh Grand Line - native macOS app.
//
// The app's one recorded-keystroke value, and the one thing every feature
// that lets a captain choose their own shortcut stores. Three of them now:
// Dictation's hold-to-record trigger, the Console's nine tab/split bindings,
// and (since `fm/grandline-capture-global-hotkey-configurable`) universal
// capture's own chord.
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
/// `AppSettings.dictationShortcut`, `AppSettings.terminalShortcuts` and
/// `AppSettings.quickCaptureShortcut` as JSON `Data`.
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

    /// Universal capture's shortcut out of the box - ⌥Space, the chord this
    /// panel has always used (`fm/grandline-capture-global-hotkey-
    /// configurable` made it recordable rather than fixed).
    ///
    /// `49` is `kVK_Space`, the same "a Carbon keycode literal without
    /// linking Carbon" note `ShiftGlobalHotkey` already carried for it.
    /// Regular-key shape, not modifier-only: Space is a real key.
    static let quickCaptureDefault = KeyChord(
        keyCode: 49,
        modifierFlagsRaw: NSEvent.ModifierFlags.option.rawValue,
        isModifierOnly: false
    )

    /// `kVK_RightOption`/`kVK_RightCommand`/... - Carbon's `HIToolbox`
    /// virtual keycodes for the standard modifier keys, both sides where
    /// macOS distinguishes them. No Carbon dependency needed for these
    /// literal values, same reasoning `quickCaptureDefault`'s own keycode
    /// note above carries.
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

    /// The character an `NSMenuItem.keyEquivalent` needs for a given keycode,
    /// or `nil` where a menu cannot express that key.
    ///
    /// Menu key equivalents are *characters*, not keycodes, so a chord the
    /// monitors match by keycode has to be translated before a menu item can
    /// print it. Deliberately a small explicit table over the same keys
    /// `regularKeyNames` covers rather than a layout round-trip through
    /// `UCKeyTranslate`: the chords a captain records are matched by keycode
    /// whatever their layout, and a menu that prints the wrong glyph for an
    /// exotic key is worse than one that prints none. `nil` means "the
    /// monitors still carry this chord, the menu just cannot draw it" - the
    /// caller clears the accelerator rather than guessing.
    static func menuKeyEquivalent(for keyCode: UInt16) -> String? {
        if let special = menuSpecialKeys[keyCode] { return special }
        guard let name = regularKeyNames[keyCode], name.count == 1 else { return nil }
        return name.lowercased()
    }

    /// The keys whose menu character is not simply their lowercased display
    /// name. Space is the one that matters here - universal capture's default
    /// chord is ⌥Space, and its display name is the word "Space".
    private static let menuSpecialKeys: [UInt16: String] = [
        49: " ",
        36: "\r",
        48: "\t",
        51: "\u{8}",
        53: "\u{1B}",
        123: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
        124: String(UnicodeScalar(NSRightArrowFunctionKey)!),
        125: String(UnicodeScalar(NSDownArrowFunctionKey)!),
        126: String(UnicodeScalar(NSUpArrowFunctionKey)!),
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

