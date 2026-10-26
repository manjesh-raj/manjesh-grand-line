// Grand Line - native macOS app.
//
// Terminal keyword highlighting (T1 of the Termius-style plan): "error" in
// red, "warning" in yellow, an IP address in cyan, in plain terminal output,
// the way Termius colours a log.
//
// ## Where it runs, and what it never touches
//
// The colouring happens while a visible row is built for drawing, through the
// eighth vendored SwiftTerm patch (`Vendor/SwiftTerm/Sources/SwiftTerm/Apple/
// RowHighlighting.swift`, and that README's "Eighth patch" section). Nothing
// here sees the byte stream. The buffer, scrollback, copy, search, the
// `getBufferAsData` readers (the Kubernetes feed tab, SRE Lead's bridge) and
// every log a tab captures are exactly what the program wrote. Only the
// foreground colour a cell is *drawn* in changes.
//
// The patch decides *when* a row is asked about: only visible rows, only when
// patch 7's row cache misses, and memoised by the row's own text, so a row is
// scanned once per distinct text rather than once per frame. It also decides
// what is never coloured: the alternate screen (vim, htop, less), any cell a
// program already coloured, and rows over 2,000 columns. This file decides
// *what* a row's text matches.
//
// ## How a row is matched
//
// Two passes, both cheap, and the second usually skipped:
//
// 1. One word-boundary scan over the row's UTF-16 units. A word is a maximal
//    run of ASCII letters, digits and `_` (the same boundary `\b` uses), it is
//    lower-cased into a 16-byte packed key, and one dictionary lookup answers
//    whether it is any class's keyword. All built-in classes share that one
//    table, so the cost is one pass and one hash per word, however many
//    classes are on. The same pass counts the separators an address needs.
// 2. One precompiled pattern for IPv4, IPv6 and MAC addresses, run only when
//    the counts from pass 1 say an address is possible at all. A timestamp's
//    two colons, a version's two dots and a date's two dashes never reach it.
//
// ## Colours
//
// Each class defaults to one of the active theme's own ANSI colours (red,
// yellow, green, blue, magenta, cyan), from the same table the terminal's own
// cells use, so it is right in all 26 palettes by construction. Every colour,
// theme or custom, is then passed through `HelmContrast.legibleOn` against the
// terminal's real cell background, so it clears 4.5:1 there too.

import AppKit
import SwiftTerm

// MARK: - Classes

/// One built-in keyword class. The raw value is the persisted key.
enum KeywordHighlightClass: String, CaseIterable, Codable {
    case error
    case warning
    case ok
    case info
    case debug
    case address

    var title: String {
        switch self {
        case .error: return "Error"
        case .warning: return "Warning"
        case .ok: return "OK"
        case .info: return "Info"
        case .debug: return "Debug"
        case .address: return "IP & MAC"
        }
    }

    /// The theme ANSI colour this class takes by default, in SwiftTerm/xterm
    /// order (`HelmTheme.ansiHex`).
    var defaultANSIIndex: Int {
        switch self {
        case .error: return 1      // red
        case .warning: return 3    // yellow
        case .ok: return 2         // green
        case .info: return 4       // blue
        case .debug: return 5      // magenta
        case .address: return 6    // cyan
        }
    }

    /// The words this class colours, matched whole and case-insensitively.
    /// `.address` has none: it is matched by `KeywordMatcher.addressPattern`.
    ///
    /// Deliberately conservative. A word here colours every plain-text
    /// occurrence in every tab, so anything that is also ordinary English in a
    /// non-log sense ("up", "down", "running", "note") is left out.
    var words: [String] {
        switch self {
        case .error:
            return ["error", "errors", "err", "fail", "failed", "failure", "failures", "fatal",
                    "exception", "panic", "critical", "crit", "denied", "refused", "unauthorized",
                    "forbidden", "aborted", "crashed", "emerg", "emergency", "segfault"]
        case .warning:
            return ["warn", "warning", "warnings", "deprecated", "deprecation", "timeout",
                    "retrying", "caution"]
        case .ok:
            return ["ok", "okay", "success", "succeeded", "successful", "successfully", "passed",
                    "done", "completed", "healthy"]
        case .info:
            return ["info", "notice", "information"]
        case .debug:
            return ["debug", "dbg", "trace", "verbose"]
        case .address:
            return []
        }
    }

    /// What the Settings row says the class covers.
    var sample: String {
        switch self {
        case .address: return "192.168.1.20, fe80::1, 3c:22:fb:91:0a:7e"
        default: return words.prefix(5).joined(separator: ", ")
        }
    }
}

// MARK: - Settings

/// A highlight colour: one of the theme's sixteen ANSI colours, or a fixed
/// RGB hex the captain picked.
///
/// A struct with two optionals rather than an enum with payloads, so the JSON
/// is two plain keys and a value written by a newer build with a third kind
/// still decodes (GL-01) - it falls back to the class default instead.
struct KeywordHighlightColor: Codable, Equatable {
    var ansiIndex: Int?
    var hex: String?

    static func ansi(_ index: Int) -> KeywordHighlightColor {
        KeywordHighlightColor(ansiIndex: index, hex: nil)
    }

    static func custom(_ hex: String) -> KeywordHighlightColor {
        KeywordHighlightColor(ansiIndex: nil, hex: hex)
    }

    var isCustom: Bool { hex != nil }

    init(ansiIndex: Int?, hex: String?) {
        self.ansiIndex = ansiIndex
        self.hex = hex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ansiIndex = try c.decodeIfPresent(Int.self, forKey: .ansiIndex)
        hex = try c.decodeIfPresent(String.self, forKey: .hex)
    }
}

/// One class's setting.
struct KeywordHighlightClassSetting: Codable, Equatable {
    var enabled: Bool = true
    /// `nil` is the class's theme default.
    var color: KeywordHighlightColor?

    init(enabled: Bool = true, color: KeywordHighlightColor? = nil) {
        self.enabled = enabled
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        color = try c.decodeIfPresent(KeywordHighlightColor.self, forKey: .color)
    }
}

/// Everything Settings > Terminal's highlighting card controls, stored as one
/// JSON value in `AppSettings.terminalHighlighting` (choice C2: per Mac, the
/// same shape as `fm.terminalShortcuts`).
///
/// Every field is `decodeIfPresent` with a default (GL-01), and classes are
/// keyed by raw value with a per-class fallback, so a value written by a build
/// with a class this one does not know still decodes and keeps the rest.
struct KeywordHighlightSettings: Codable, Equatable {
    /// The master switch. On by default: the captain asked for this, and
    /// it only colours plain text a program left uncoloured.
    var enabled: Bool = true
    /// Keyed by `KeywordHighlightClass.rawValue`.
    private var classSettings: [String: KeywordHighlightClassSetting] = [:]

    static let defaults = KeywordHighlightSettings()

    init() {}

    subscript(cls: KeywordHighlightClass) -> KeywordHighlightClassSetting {
        get { classSettings[cls.rawValue] ?? KeywordHighlightClassSetting() }
        set { classSettings[cls.rawValue] = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case classSettings = "classes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        classSettings = try c.decodeIfPresent([String: KeywordHighlightClassSetting].self,
                                              forKey: .classSettings) ?? [:]
    }
}

// MARK: - Matching

/// The pure half: which runs of a row's text match which class. No colours,
/// no theme and no view, so a headless suite can drive it directly.
struct KeywordMatcher {

    /// One match: UTF-16 offsets into the row, and what matched.
    struct Match: Equatable {
        var range: Range<Int>
        var slot: Slot
    }

    /// What a match belongs to.
    enum Slot: Hashable {
        case builtIn(KeywordHighlightClass)
    }

    /// A lower-cased ASCII word of at most 16 bytes, packed into two words so
    /// a lookup hashes 16 bytes rather than building a `String`.
    struct PackedWord: Hashable {
        var lo: UInt64 = 0
        var hi: UInt64 = 0
    }

    static let maximumWordLength = 16

    #if FM_SELFTESTS
    /// How many rows reached the address pattern, so a suite can prove the
    /// pre-check keeps a timestamp-only row away from it.
    static var debugAddressPatternRuns = 0
    #endif

    private(set) var words: [PackedWord: Slot] = [:]
    private(set) var matchesAddresses = false

    init(classes: Set<KeywordHighlightClass>) {
        for cls in KeywordHighlightClass.allCases where classes.contains(cls) {
            if cls == .address {
                matchesAddresses = true
                continue
            }
            for word in cls.words {
                if let key = Self.pack(word) { words[key] = .builtIn(cls) }
            }
        }
    }

    var isEmpty: Bool { words.isEmpty && !matchesAddresses }

    /// Packs an ASCII word, lower-cased, or `nil` if it is not one this scan
    /// can see as a single word.
    static func pack(_ word: String) -> PackedWord? {
        let units = Array(word.utf16)
        guard !units.isEmpty, units.count <= maximumWordLength, units.allSatisfy(isWordUnit) else {
            return nil
        }
        var key = PackedWord()
        for (i, unit) in units.enumerated() { key.add(lowercased(unit), at: i) }
        return key
    }

    @inline(__always)
    static func isWordUnit(_ u: UInt16) -> Bool {
        (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F
    }

    @inline(__always)
    static func isHexUnit(_ u: UInt16) -> Bool {
        (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66)
    }

    @inline(__always)
    static func isDigitUnit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }

    @inline(__always)
    static func lowercased(_ u: UInt16) -> UInt16 { (u >= 0x41 && u <= 0x5A) ? u + 0x20 : u }

    /// IPv4 (with an optional CIDR suffix), MAC (colon or dash separated) and
    /// IPv6 (full, or compressed with `::`), as one precompiled pattern.
    ///
    /// Each alternative carries its own boundary, because the right one
    /// differs: an IPv4 address after `addr:` is still an address, while a
    /// MAC or IPv6 group after a colon is the middle of something longer.
    static let addressPattern: NSRegularExpression = {
        let octet = "(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)"
        let ipv4 = "(?<![\\w.])(?:\(octet)\\.){3}\(octet)(?:/(?:3[0-2]|[12]?\\d))?(?![\\w-]|\\.\\d)"
        let hex = "[0-9a-f]"
        let mac = "(?<![\\w:-])\(hex){2}([:-])\(hex){2}(?:\\1\(hex){2}){4}(?![\\w:-])"
        let group = "\(hex){1,4}"
        let ipv6Full = "(?<![\\w:])(?:\(group):){7}\(group)(?![\\w:])"
        let ipv6Compressed = "(?<![\\w:])(?:\(group):){1,7}:(?:\(group)(?::\(group)){0,6})?(?![\\w:])"
        let ipv6Leading = "(?<![\\w:])::\(group)(?::\(group)){0,6}(?![\\w:])"
        let pattern = [ipv4, mac, ipv6Full, ipv6Compressed, ipv6Leading].joined(separator: "|")
        // A pattern literal compiled once; a failure is a programming error
        // caught by the matcher suite on its first run.
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Every match in one row, in order, never overlapping.
    func matches(in units: [UInt16]) -> [Match] {
        var found: [Match] = []
        let n = units.count

        // Separator counts for the address pre-check. Each counts a separator
        // with the right kind of character on both sides.
        var digitDots = 0
        var hexColons = 0
        var hexDashes = 0
        var doubleColon = false

        var i = 0
        while i < n {
            let u = units[i]
            if Self.isWordUnit(u) {
                let start = i
                var key = PackedWord()
                var length = 0
                while i < n, Self.isWordUnit(units[i]) {
                    if length < Self.maximumWordLength { key.add(Self.lowercased(units[i]), at: length) }
                    length += 1
                    i += 1
                }
                if length <= Self.maximumWordLength, let slot = words[key] {
                    found.append(Match(range: start..<i, slot: slot))
                }
                continue
            }
            if matchesAddresses, i > 0, i + 1 < n {
                let before = units[i - 1]
                let after = units[i + 1]
                switch u {
                case 0x2E: // .
                    if Self.isDigitUnit(before) && Self.isDigitUnit(after) { digitDots += 1 }
                case 0x3A: // :
                    if after == 0x3A { doubleColon = true }
                    if Self.isHexUnit(before) && Self.isHexUnit(after) { hexColons += 1 }
                case 0x2D: // -
                    if Self.isHexUnit(before) && Self.isHexUnit(after) { hexDashes += 1 }
                default:
                    break
                }
            } else if matchesAddresses, u == 0x3A, i + 1 < n, units[i + 1] == 0x3A {
                doubleColon = true
            }
            i += 1
        }

        let maybeAddress = matchesAddresses
            && (digitDots >= 3 || hexColons >= 5 || hexDashes >= 5 || doubleColon)
        guard maybeAddress else { return found }

        #if FM_SELFTESTS
        Self.debugAddressPatternRuns += 1
        #endif
        let text = units.withUnsafeBufferPointer { buffer in
            NSString(characters: buffer.baseAddress!, length: n)
        }
        var addresses: [Match] = []
        Self.addressPattern.enumerateMatches(in: text as String, options: [],
                                             range: NSRange(location: 0, length: n)) { result, _, _ in
            guard let r = result?.range, r.length > 0 else { return }
            addresses.append(Match(range: r.location..<(r.location + r.length), slot: .builtIn(.address)))
        }
        guard !addresses.isEmpty else { return found }
        // Words are claimed first. An address never contains one of the
        // built-in words, but a merge that keeps the rule explicit is what
        // stops a later class from silently overlapping.
        for address in addresses where !found.contains(where: { $0.range.overlaps(address.range) }) {
            found.append(address)
        }
        found.sort { $0.range.lowerBound < $1.range.lowerBound }
        return found
    }
}

extension KeywordMatcher.PackedWord {
    @inline(__always)
    mutating func add(_ unit: UInt16, at index: Int) {
        let byte = UInt64(truncatingIfNeeded: unit)
        if index < 8 {
            lo |= byte << UInt64(index * 8)
        } else {
            hi |= byte << UInt64((index - 8) * 8)
        }
    }
}

// MARK: - The highlighter

/// The app's `TerminalRowHighlighter`: compiled settings plus theme colours.
///
/// One shared instance serves every terminal, because the settings and the
/// theme are app-wide. A suite builds its own, so nothing it does reaches the
/// shared one.
final class TerminalKeywordHighlighter: TerminalRowHighlighter {

    static let shared = TerminalKeywordHighlighter(settings: AppSettings.shared.terminalHighlighting,
                                                   theme: ThemeManager.shared.theme)

    private(set) var settings: KeywordHighlightSettings
    private(set) var theme: HelmTheme
    private(set) var highlightVersion: UInt64 = 1
    var highlightsEnabled: Bool { settings.enabled && !matcher.isEmpty }

    private var matcher: KeywordMatcher
    private var colors: [KeywordMatcher.Slot: NSColor] = [:]
    /// Every terminal this highlighter is installed on, so a settings or
    /// theme change can repaint them. Weak: a closed tab simply drops out.
    private let views = NSHashTable<TerminalView>.weakObjects()

    init(settings: KeywordHighlightSettings, theme: HelmTheme) {
        self.settings = settings
        self.theme = theme
        self.matcher = KeywordMatcher(classes: [])
        recompile()
    }

    /// Install on a terminal. Idempotent.
    func attach(_ view: TerminalView) {
        if view.rowHighlighter !== self { view.rowHighlighter = self }
        views.add(view)
    }

    /// New settings from Settings > Terminal.
    func update(settings: KeywordHighlightSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        recompile()
    }

    /// The theme a terminal was just painted with (`HelmTheme.apply(to:)`).
    /// A no-op when it is already this one, so painting twenty panes with one
    /// theme recompiles once.
    func update(theme: HelmTheme) {
        guard theme.id != self.theme.id else { return }
        self.theme = theme
        recompile()
    }

    /// The colour a class paints with in `theme`, after the contrast floor.
    static func resolvedColor(for cls: KeywordHighlightClass,
                              settings: KeywordHighlightSettings,
                              theme: HelmTheme) -> NSColor {
        let choice = settings[cls].color ?? .ansi(cls.defaultANSIIndex)
        return resolvedColor(choice, fallbackANSIIndex: cls.defaultANSIIndex, theme: theme)
    }

    /// Any highlight colour in `theme`: a theme ANSI colour or a custom hex,
    /// then corrected to clear `HelmContrast.textTarget` against the
    /// terminal's real cell background.
    static func resolvedColor(_ choice: KeywordHighlightColor,
                              fallbackANSIIndex: Int,
                              theme: HelmTheme) -> NSColor {
        let palette = theme.terminalCard?.ansiHex ?? theme.ansiHex
        let base: NSColor
        if let hex = choice.hex, isValidHex(hex) {
            base = HelmTheme.nsColor(hex)
        } else {
            let index = choice.ansiIndex.flatMap { palette.indices.contains($0) ? $0 : nil }
                ?? fallbackANSIIndex
            base = HelmTheme.nsColor(palette[index])
        }
        return HelmContrast.legibleOn(fill: terminalBackground(theme), preferring: base)
    }

    /// The colour the terminal's cells sit on, the same one
    /// `HelmTheme.apply(to:)` installs.
    static func terminalBackground(_ theme: HelmTheme) -> NSColor {
        HelmTheme.nsColor(theme.terminalCard?.backgroundHex ?? theme.backgroundHex)
    }

    static func isValidHex(_ hex: String) -> Bool {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        return s.count == 6 && s.allSatisfy(\.isHexDigit)
    }

    private func recompile() {
        let classes = Set(KeywordHighlightClass.allCases.filter { settings[$0].enabled })
        matcher = KeywordMatcher(classes: classes)
        var resolved: [KeywordMatcher.Slot: NSColor] = [:]
        for cls in KeywordHighlightClass.allCases {
            resolved[.builtIn(cls)] = Self.resolvedColor(for: cls, settings: settings, theme: theme)
        }
        colors = resolved
        highlightVersion &+= 1
        for view in views.allObjects { view.needsDisplay = true }
    }

    // MARK: TerminalRowHighlighter

    func highlights(forRow units: [UInt16]) -> [TerminalRowHighlight] {
        #if FM_SELFTESTS
        let started = CFAbsoluteTimeGetCurrent()
        defer { debugMatchSeconds += CFAbsoluteTimeGetCurrent() - started }
        #endif
        return matcher.matches(in: units).compactMap { match in
            guard let color = colors[match.slot] else { return nil }
            return TerminalRowHighlight(range: match.range, color: color)
        }
    }

    #if FM_SELFTESTS
    /// Wall time spent matching, for the benchmark's breakdown.
    var debugMatchSeconds: Double = 0
    #endif
}
