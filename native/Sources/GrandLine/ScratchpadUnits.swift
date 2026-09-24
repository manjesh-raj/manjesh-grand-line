// Grand Line - native macOS app.
//
// The Scratchpad calculator's unit table (F9 of full review #3 §8) - the
// dimensions, the unit aliases, the static currency rates, and the one place a
// computed value is turned back into text.
//
// Everything here is pure Foundation: no AppKit, no network, no store. That is
// the point. The report scoped F9 as "pure logic", and keeping the table and
// the formatter out of the view is what lets
// `ScratchpadEngineSelfTest` assert ~150 expressions without a window
// (AGENTS.md's "the test is what the suite *asserts*, never what it imports").
//
// ## Why a linear factor plus an offset
//
// Every unit here converts to its dimension's base with `base = amount *
// factor + offset`, and back with `amount = (base - offset) / factor`. All but
// three units have `offset == 0`; temperature is the exception, and giving
// every unit the affine form is cheaper than a second conversion path that
// only Celsius/Fahrenheit/Kelvin would ever take.
//
// ## Currency rates are static, and say so
//
// There is no live rate feed, deliberately - this app's Tools page promises
// "everything runs locally, nothing leaves this machine", and a calculator tab
// that silently opened a socket would break that promise for the one line in
// twelve that mentions a currency. The table below is hand-maintained, carries
// its own `asOf` date, and the pad's footer prints that date verbatim. GL-14's
// "unknown is never rendered as zero" is the reason the date is on screen
// rather than in a comment: a rate from last year is not wrong the way a
// failed fetch is, but the captain has to be able to see how old it is before
// trusting a conversion.
//
// **To update the rates**: edit `ScratchpadRates.perUSD` and
// `ScratchpadRates.asOf` together, in one commit. `ScratchpadEngineSelfTest`
// asserts the two stay in step (every code has a positive rate, USD is exactly
// 1, and `asOf` parses), so half an update fails by name.

import Foundation

/// What a quantity measures. Two quantities can only be added, subtracted or
/// converted when their dimensions match - the one exception being `.percent`,
/// which is a modifier rather than a measurement (see `ScratchpadEngine`'s
/// `applyPercent`).
enum ScratchpadDimension: String {
    case plain
    case percent
    case currency
    case length
    case mass
    case data
    case duration
    case temperature
    case cpu

    /// How a bare result of this dimension is rendered when the expression did
    /// not name an output unit - see `ScratchpadFormat`.
    var baseUnitCode: String {
        switch self {
        case .plain: return ""
        case .percent: return "%"
        case .currency: return "USD"
        case .length: return "m"
        case .mass: return "kg"
        case .data: return "B"
        case .duration: return "s"
        case .temperature: return "°C"
        case .cpu: return "cpu"
        }
    }
}

/// One unit: how it converts to its dimension's base, and how it prints.
struct ScratchpadUnit: Equatable {
    let code: String
    let dimension: ScratchpadDimension
    let factor: Double
    let offset: Double
    /// What the unit looks like in a result. Usually `code`; different only
    /// where the canonical spelling is not the nicest one to read back
    /// (`°C`, `min`).
    let display: String

    init(_ code: String, _ dimension: ScratchpadDimension, _ factor: Double,
         offset: Double = 0, display: String? = nil) {
        self.code = code
        self.dimension = dimension
        self.factor = factor
        self.offset = offset
        self.display = display ?? code
    }

    func toBase(_ amount: Double) -> Double { amount * factor + offset }
    func fromBase(_ base: Double) -> Double { (base - offset) / factor }
}

/// The static, hand-maintained exchange-rate table. See this file's header for
/// why it is static and how to update it.
enum ScratchpadRates {

    /// The day the rates below were taken. Printed in the pad's footer, so a
    /// captain can see the table's age before trusting a conversion.
    static let asOf = "2026-09-21"

    /// Units of each currency per **one US dollar**. USD is the anchor and is
    /// exactly 1 by construction.
    static let perUSD: [String: Double] = [
        "USD": 1,
        "EUR": 0.92,
        "GBP": 0.78,
        "INR": 83.55,
        "JPY": 151.20,
        "CNY": 7.23,
        "CHF": 0.88,
        "CAD": 1.36,
        "AUD": 1.51,
        "NZD": 1.64,
        "SGD": 1.34,
        "HKD": 7.82,
        "AED": 3.6725,
        "SAR": 3.75,
        "ILS": 3.70,
        "SEK": 10.45,
        "NOK": 10.65,
        "DKK": 6.87,
        "PLN": 3.95,
        "CZK": 23.30,
        "HUF": 360.0,
        "RON": 4.58,
        "TRY": 32.20,
        "RUB": 92.50,
        "UAH": 39.50,
        "ZAR": 18.40,
        "EGP": 47.50,
        "NGN": 1450.0,
        "KES": 132.0,
        "BRL": 5.05,
        "MXN": 17.10,
        "ARS": 870.0,
        "CLP": 940.0,
        "COP": 3900.0,
        "KRW": 1330.0,
        "TWD": 32.10,
        "THB": 35.80,
        "MYR": 4.72,
        "IDR": 15700.0,
        "PHP": 56.20,
        "VND": 24800.0,
        "PKR": 278.0,
        "BDT": 110.0,
        "LKR": 300.0,
    ]

    /// `asOf` as the human line the pad's footer prints.
    static var footerLine: String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: asOf) else {
            // GL-14: a date that will not parse is said out loud rather than
            // rendered as something plausible.
            return "Currency rates: a static table of \(perUSD.count) currencies, date unreadable"
        }
        let out = DateFormatter()
        out.dateFormat = "d MMM yyyy"
        return "Currency rates: a static table of \(perUSD.count) currencies, as of \(out.string(from: date)) \u{00B7} everything else is offline maths"
    }
}

/// The alias table: what a captain may type, and the unit it resolves to.
enum ScratchpadUnits {

    /// Every non-currency unit, keyed by canonical code.
    static let table: [ScratchpadUnit] = {
        var units: [ScratchpadUnit] = [
            .init("%", .percent, 0.01),

            // Length, base metre.
            .init("nm", .length, 1e-9),
            .init("um", .length, 1e-6, display: "\u{00B5}m"),
            .init("mm", .length, 1e-3),
            .init("cm", .length, 1e-2),
            .init("m", .length, 1),
            .init("km", .length, 1000),
            .init("inch", .length, 0.0254, display: "in"),
            .init("ft", .length, 0.3048),
            .init("yd", .length, 0.9144),
            .init("mi", .length, 1609.344),
            .init("nmi", .length, 1852),

            // Mass, base kilogram.
            .init("mg", .mass, 1e-6),
            .init("g", .mass, 1e-3),
            .init("kg", .mass, 1),
            .init("t", .mass, 1000),
            .init("oz", .mass, 0.028349523125),
            .init("lb", .mass, 0.45359237),
            .init("st", .mass, 6.35029318),

            // Data, base byte. Both families, because a captain reading a
            // cloud invoice (GB) and a captain reading `df -h` (GiB) are the
            // same captain ten seconds apart - which is exactly the confusion
            // `1.4 TiB in GB` exists to settle.
            .init("bit", .data, 0.125),
            .init("kbit", .data, 125),
            .init("Mbit", .data, 125_000),
            .init("Gbit", .data, 125_000_000),
            .init("B", .data, 1),
            .init("kB", .data, 1e3),
            .init("MB", .data, 1e6),
            .init("GB", .data, 1e9),
            .init("TB", .data, 1e12),
            .init("PB", .data, 1e15),
            .init("KiB", .data, 1024),
            .init("MiB", .data, 1048576),
            .init("GiB", .data, 1073741824),
            .init("TiB", .data, 1099511627776),
            .init("PiB", .data, 1125899906842624),

            // Duration, base second. A month is the Gregorian mean
            // (365.2425 / 12 days) and a year the Gregorian mean year, so
            // `1 year in months` is exactly 12 rather than 12.17 - which is
            // the answer a pad is asked for. Calendar-aware date arithmetic
            // ("2 weeks from Friday") does NOT go through these: see
            // `ScratchpadDates`, which uses a real `Calendar`.
            .init("ns", .duration, 1e-9),
            .init("us", .duration, 1e-6, display: "\u{00B5}s"),
            .init("ms", .duration, 1e-3),
            .init("s", .duration, 1),
            .init("min", .duration, 60),
            .init("h", .duration, 3600),
            .init("day", .duration, 86400),
            .init("week", .duration, 604800),
            .init("month", .duration, 2_629_746, display: "months"),
            .init("year", .duration, 31_556_952, display: "years"),

            // Temperature. The one affine family - see this file's header.
            .init("C", .temperature, 1, display: "\u{00B0}C"),
            .init("K", .temperature, 1, offset: -273.15, display: "K"),
            .init("F", .temperature, 5.0 / 9.0, offset: -32 * 5.0 / 9.0, display: "\u{00B0}F"),

            // Kubernetes CPU, base one core. `250m cpu` is millicores - see
            // `ScratchpadLexer`'s note on why `m` alone stays metres.
            .init("cpu", .cpu, 1),
            .init("mcpu", .cpu, 0.001, display: "m"),
        ]
        for (code, rate) in ScratchpadRates.perUSD {
            units.append(.init(code, .currency, 1.0 / rate))
        }
        return units
    }()

    private static let byCode: [String: ScratchpadUnit] = {
        var map: [String: ScratchpadUnit] = [:]
        for unit in table { map[unit.code] = unit }
        return map
    }()

    /// Everything a captain may type for each unit, lowercased. Ambiguity is
    /// resolved here once rather than in the parser: `m` is metres (a `m` that
    /// meant minutes would make `840ms` ambiguous the moment a space slipped
    /// in), and millicores are reached through the `cpu` word that follows
    /// them (`250m cpu`), which `ScratchpadEngine` rewrites.
    private static let aliases: [String: String] = {
        var map: [String: String] = [:]
        func alias(_ code: String, _ names: [String]) {
            for name in names { map[name.lowercased()] = code }
        }
        alias("%", ["%", "percent", "pct"])
        alias("nm", ["nm", "nanometre", "nanometer", "nanometres", "nanometers"])
        alias("um", ["um", "\u{00B5}m", "micron", "microns"])
        alias("mm", ["mm", "millimetre", "millimeter", "millimetres", "millimeters"])
        alias("cm", ["cm", "centimetre", "centimeter", "centimetres", "centimeters"])
        alias("m", ["m", "metre", "meter", "metres", "meters"])
        alias("km", ["km", "kilometre", "kilometer", "kilometres", "kilometers"])
        alias("inch", ["in", "inch", "inches", "\""])
        alias("ft", ["ft", "foot", "feet"])
        alias("yd", ["yd", "yard", "yards"])
        alias("mi", ["mi", "mile", "miles"])
        alias("nmi", ["nmi", "nauticalmile", "nauticalmiles"])
        alias("mg", ["mg", "milligram", "milligrams"])
        alias("g", ["g", "gram", "grams"])
        alias("kg", ["kg", "kilo", "kilos", "kilogram", "kilograms"])
        alias("t", ["t", "tonne", "tonnes", "tons", "ton"])
        alias("oz", ["oz", "ounce", "ounces"])
        alias("lb", ["lb", "lbs", "pound", "pounds"])
        alias("st", ["stone", "stones"])
        alias("bit", ["bit", "bits", "b"])
        alias("kbit", ["kbit", "kbits", "kb", "kilobit", "kilobits"])
        alias("Mbit", ["mbit", "mbits", "megabit", "megabits"])
        alias("Gbit", ["gbit", "gbits", "gigabit", "gigabits"])
        alias("B", ["byte", "bytes"])
        alias("kB", ["kb", "kilobyte", "kilobytes"])
        alias("MB", ["mb", "megabyte", "megabytes"])
        alias("GB", ["gb", "gigabyte", "gigabytes"])
        alias("TB", ["tb", "terabyte", "terabytes"])
        alias("PB", ["pb", "petabyte", "petabytes"])
        alias("KiB", ["kib", "kibibyte", "kibibytes"])
        alias("MiB", ["mib", "mebibyte", "mebibytes"])
        alias("GiB", ["gib", "gibibyte", "gibibytes"])
        alias("TiB", ["tib", "tebibyte", "tebibytes"])
        alias("PiB", ["pib", "pebibyte", "pebibytes"])
        alias("ns", ["ns", "nanosecond", "nanoseconds"])
        alias("us", ["us", "\u{00B5}s", "microsecond", "microseconds"])
        alias("ms", ["ms", "millisecond", "milliseconds", "msec", "msecs"])
        alias("s", ["s", "sec", "secs", "second", "seconds"])
        alias("min", ["min", "mins", "minute", "minutes"])
        alias("h", ["h", "hr", "hrs", "hour", "hours"])
        alias("day", ["d", "day", "days"])
        alias("week", ["w", "wk", "wks", "week", "weeks"])
        alias("month", ["mo", "mon", "month", "months"])
        alias("year", ["y", "yr", "yrs", "year", "years"])
        alias("C", ["c", "celsius", "centigrade"])
        alias("F", ["f", "fahrenheit"])
        alias("K", ["kelvin"])
        alias("cpu", ["cpu", "cpus", "core", "cores", "vcpu", "vcpus"])
        // `b`/`kb` above are bits, matching how a network line is quoted;
        // a captain who means bytes writes `B`/`kB`, which the
        // case-sensitive pass below resolves first.
        for unit in table where ScratchpadRates.perUSD[unit.code] != nil {
            map[unit.code.lowercased()] = unit.code
        }
        alias("USD", ["dollar", "dollars", "usd", "$"])
        alias("EUR", ["euro", "euros", "\u{20AC}"])
        alias("GBP", ["pound", "pounds", "quid", "\u{00A3}"])
        alias("INR", ["rupee", "rupees", "\u{20B9}"])
        alias("JPY", ["yen", "\u{00A5}"])
        // `pound` is mass first: a recipe outnumbers a currency line, and
        // `GBP`/`£` are unambiguous. Re-assert it after the currency aliases.
        alias("lb", ["pound", "pounds"])
        return map
    }()

    /// Words the grammar owns. A unit alias may collide with one - `in` is
    /// both "inches" and the conversion keyword, which is how `that * 12 in
    /// INR` once came out as "USD times inches" - so the parser asks
    /// `isGrammarWord` before it treats a word as a unit, and resolves the
    /// alias anyway once the keyword's own position has been taken.
    static let grammarWords: Set<String> = [
        "in", "to", "as", "of", "per", "from", "after", "before", "ago", "that", "prev", "previous", "ans",
    ]

    static func isGrammarWord(_ token: String) -> Bool { grammarWords.contains(token.lowercased()) }

    /// Ambiguous tokens, resolved by what they are sitting next to.
    ///
    /// `m` is the whole list, and it is a genuine three-way collision: metres,
    /// minutes (`3h 40m`) and millicores (`250m cpu`). It stays **metres** on
    /// its own - making it minutes would make `840ms` ambiguous the moment a
    /// space slipped in - and becomes the other two only when the quantity it
    /// is extending already has that dimension, which is exactly the context a
    /// human reads it in.
    private static let byDimension: [String: [ScratchpadDimension: String]] = [
        "m": [.duration: "min", .cpu: "mcpu"],
    ]

    /// Resolve a token given the dimension of the quantity it is attaching to.
    static func unit(for token: String, preferring dimension: ScratchpadDimension?) -> ScratchpadUnit? {
        if let dimension, let preferred = byDimension[token.lowercased()]?[dimension] {
            return unit(code: preferred)
        }
        return unit(for: token)
    }

    /// Resolve a token to a unit. The case-**sensitive** code match runs first
    /// so `B` (bytes) and `b` (bits), `MB` and `mb`, resolve the way a
    /// engineer expects before the lowercased alias table is consulted.
    static func unit(for token: String) -> ScratchpadUnit? {
        if let exact = byCode[token] { return exact }
        if let code = aliases[token.lowercased()], let unit = byCode[code] { return unit }
        return nil
    }

    static func unit(code: String) -> ScratchpadUnit? { byCode[code] }

    /// True when `token` names a unit - used by the lexer to decide whether a
    /// bare word is a unit or a variable.
    static func isUnitToken(_ token: String) -> Bool { unit(for: token) != nil }
}
