// Manjesh Grand Line - native macOS app.
//
// What the Scratchpad calculator computes, and how a computed thing is turned
// back into the one string the pad's result column shows (F9 of full review #3
// §8).
//
// Split out of `ScratchpadEngine.swift` because formatting is the half a
// self-test asserts most often and the half most likely to be argued about:
// every "why does it say 5 h 15 min rather than 18900 s" decision is in this
// file, stated once, with the reasoning next to it.

import Foundation

/// A number with an optional unit and an optional "per" period.
///
/// `per` is what makes `18.50 USD / month` a rate rather than a division that
/// has already happened: `seats * seat_price` has to come back as
/// `$777.00/mo`, not as a bare 777, and the only way to do that is to carry
/// the denominator rather than collapse it.
struct ScratchpadQuantity: Equatable {
    var amount: Double
    var unit: ScratchpadUnit?
    var per: ScratchpadUnit?

    /// Set **only** by an explicit conversion (`in GB`, `as ms`), never by
    /// merely typing a unit. It is what tells the duration formatter to leave
    /// `90 min in min` alone where a computed `1,134 ms` becomes `1.134 s`:
    /// the captain named the output unit, so that is the output unit.
    ///
    /// Presentational, so it is deliberately **not** part of equality: two
    /// quantities that measure the same thing are the same quantity whether or
    /// not one of them was asked for by name.
    var explicitUnit: Bool = false

    init(_ amount: Double, unit: ScratchpadUnit? = nil, per: ScratchpadUnit? = nil, explicitUnit: Bool = false) {
        self.amount = amount
        self.unit = unit
        self.per = per
        self.explicitUnit = explicitUnit
    }

    static func == (lhs: ScratchpadQuantity, rhs: ScratchpadQuantity) -> Bool {
        lhs.amount == rhs.amount && lhs.unit == rhs.unit && lhs.per == rhs.per
    }

    var dimension: ScratchpadDimension { unit?.dimension ?? .plain }
    var isPlain: Bool { unit == nil && per == nil }

    /// The amount in the dimension's base unit - the only form two quantities
    /// are ever compared or added in.
    var base: Double { unit?.toBase(amount) ?? amount }
}

/// One evaluated thing. Three cases rather than one because a date is not a
/// number with a unit (adding two dates is meaningless, adding a duration to
/// one is not), and a radix conversion produces a *string* whose whole point
/// is its notation.
enum ScratchpadValue: Equatable {
    case quantity(ScratchpadQuantity)
    case date(Date)
    case text(String)

    static func number(_ value: Double) -> ScratchpadValue { .quantity(ScratchpadQuantity(value)) }

    var quantity: ScratchpadQuantity? {
        if case .quantity(let q) = self { return q }
        return nil
    }
}

/// The one place a value becomes the string in the result column.
enum ScratchpadFormat {

    // MARK: Numbers

    /// Grouped, and rounded to a number of places that depends on magnitude.
    ///
    /// The rule - 4 places under 100, 2 up to 100,000, none above - is a
    /// readability decision rather than a precision one: a pad's result column
    /// is scanned, and `1,539.3163` costs two glances where `1,539.32` costs
    /// one, while `0.0625` genuinely needs its four. Trailing zeros are
    /// trimmed afterwards so `42` is never `42.00`.
    static func number(_ value: Double, maximumFractionDigits: Int? = nil) -> String {
        guard value.isFinite else { return value.isNaN ? "not a number" : (value < 0 ? "-\u{221E}" : "\u{221E}") }
        let magnitude = abs(value)
        let digits = maximumFractionDigits ?? (magnitude >= 100_000 ? 0 : (magnitude >= 100 ? 2 : 4))
        return grouped(value, locale: nil, minimumFractionDigits: 0, maximumFractionDigits: digits)
    }

    /// The one number format in this app that is **not** the machine's own
    /// locale, and deliberately so.
    ///
    /// A result column mixing `1,539.32 GB` with `92,00 €` is unreadable, so
    /// every number here groups with `,` and points with `.` - the notation an
    /// engineer reads a log line in - regardless of what the machine is set to.
    /// Currency borrows only its locale's **grouping size**, which is what
    /// keeps `₹7,78,720` in lakhs rather than flattening a rupee figure into
    /// something an Indian reader has to count digits on. The symbol is always
    /// written in front, for the same column-scanning reason.
    private static func grouped(_ value: Double, locale: Locale?,
                                minimumFractionDigits: Int, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale ?? Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Two fraction digits below 1,000 and none above: a price is cents, a
    /// total is not.
    static func currency(_ value: Double, code: String) -> String {
        let locale = currencyLocale(code)
        let digits = abs(value) >= 1000 ? 0 : 2
        let magnitude = grouped(abs(value), locale: locale,
                                minimumFractionDigits: digits, maximumFractionDigits: digits)
        let symbol = currencySymbol(code, locale: locale)
        let sign = value < 0 ? "-" : ""
        return "\(sign)\(symbol)\(magnitude)"
    }

    /// A currency's symbol, or its ISO code plus a space when the locale has
    /// no distinct one - `CHF 92.00` says what it is, `92.00` does not.
    private static func currencySymbol(_ code: String, locale: Locale) -> String {
        let symbol = locale.currencySymbol ?? code
        if symbol.isEmpty || symbol == code || symbol.count > 3 { return "\(code) " }
        return symbol
    }

    /// The locale whose grouping and symbol placement a currency is normally
    /// read in. Anything not listed falls back to the POSIX locale, which
    /// prints the ISO code rather than guessing at a symbol - GL-14's habit
    /// applied to a smaller question.
    private static func currencyLocale(_ code: String) -> Locale {
        let map: [String: String] = [
            "USD": "en_US", "EUR": "de_DE", "GBP": "en_GB", "INR": "en_IN", "JPY": "ja_JP",
            "CNY": "zh_CN", "CHF": "de_CH", "CAD": "en_CA", "AUD": "en_AU", "NZD": "en_NZ",
            "SGD": "en_SG", "HKD": "zh_HK", "KRW": "ko_KR", "TWD": "zh_TW", "THB": "th_TH",
            "BRL": "pt_BR", "MXN": "es_MX", "ZAR": "en_ZA", "SEK": "sv_SE", "NOK": "nb_NO",
            "DKK": "da_DK", "PLN": "pl_PL", "CZK": "cs_CZ", "HUF": "hu_HU", "RUB": "ru_RU",
            "TRY": "tr_TR", "ILS": "he_IL", "AED": "ar_AE", "SAR": "ar_SA", "IDR": "id_ID",
            "MYR": "ms_MY", "PHP": "en_PH", "VND": "vi_VN", "PKR": "en_PK", "BDT": "bn_BD",
        ]
        guard let identifier = map[code] else { return Locale(identifier: "en_US_POSIX") }
        return Locale(identifier: identifier)
    }

    // MARK: Values

    static func string(for value: ScratchpadValue, calendar: Calendar = .current, now: Date = Date()) -> String {
        switch value {
        case .text(let text):
            return text
        case .date(let date):
            return self.date(date, calendar: calendar, now: now)
        case .quantity(let quantity):
            return self.quantity(quantity)
        }
    }

    static func quantity(_ quantity: ScratchpadQuantity) -> String {
        let head: String
        switch quantity.dimension {
        case .plain:
            head = number(quantity.amount)
        case .percent:
            head = "\(number(quantity.amount))%"
        case .currency:
            head = currency(quantity.amount, code: quantity.unit?.code ?? "USD")
        case .duration:
            head = duration(quantity)
        case .cpu:
            // Millicores print as Kubernetes writes them (`250m`), cores as a
            // plain count - which is what a manifest and a `kubectl top` line
            // respectively show.
            // Millicores past a whole core read as cores - `1.5 cpu` is what a
            // capacity conversation says out loud, where `1,500m cpu` is what
            // the manifest happens to spell.
            let cores = quantity.base
            if !quantity.explicitUnit, abs(cores) < 1, cores != 0 {
                head = "\(number(cores * 1000))m cpu"
            } else if quantity.unit?.code == "mcpu", quantity.explicitUnit {
                head = "\(number(quantity.amount))m cpu"
            } else {
                head = "\(number(cores)) cpu"
            }
        case .data:
            head = data(quantity)
        case .temperature, .length, .mass:
            let display = quantity.unit?.display ?? quantity.dimension.baseUnitCode
            head = "\(number(quantity.amount)) \(display)"
        }
        guard let per = quantity.per else { return head }
        return "\(head)/\(perSuffix(per))"
    }

    /// How a rate's denominator is abbreviated. `$777.00/mo` rather than
    /// `$777.00/month`: the column is narrow and these six are universally
    /// read.
    static func perSuffix(_ unit: ScratchpadUnit) -> String {
        switch unit.code {
        case "month": return "mo"
        case "year": return "yr"
        case "week": return "wk"
        case "day": return "day"
        case "h": return "h"
        case "min": return "min"
        case "s": return "s"
        default: return unit.display
        }
    }

    // MARK: Durations

    /// A duration with no explicitly requested unit is rendered the way a
    /// human would say it.
    ///
    /// Under a minute it scales to one sensible unit (`1.134 s`, `840 ms`),
    /// which is what a latency number wants. At a minute and above it becomes
    /// compound with at most two terms (`5 h 15 min`, `2 days 4 h`), because
    /// `5.25 h` is a number you then have to do arithmetic on in your head -
    /// and `3h 40m + 95m` is precisely the expression this branch exists for.
    ///
    /// An *explicit* conversion never comes through here (`90 min in h` is
    /// `1.5 h`): the captain named the unit, so the answer is in that unit.
    static func duration(_ quantity: ScratchpadQuantity) -> String {
        guard quantity.unit?.dimension == .duration else { return number(quantity.amount) }
        if quantity.explicitUnit {
            let display = quantity.unit?.display ?? "s"
            return "\(number(quantity.amount)) \(display)"
        }
        let seconds = quantity.base
        let magnitude = abs(seconds)
        if magnitude < 60 {
            let scaled: [(String, Double)] = [("s", 1), ("ms", 1e-3), ("\u{00B5}s", 1e-6), ("ns", 1e-9)]
            for (name, factor) in scaled where magnitude >= factor || factor == 1e-9 {
                return "\(number(seconds / factor)) \(name)"
            }
        }
        let sign = seconds < 0 ? "-" : ""
        var remaining = magnitude
        let ladder: [(String, Double)] = [
            ("years", 31_556_952), ("days", 86400), ("h", 3600), ("min", 60), ("s", 1),
        ]
        var parts: [String] = []
        for (name, factor) in ladder {
            if parts.count == 2 { break }
            let whole = (remaining / factor).rounded(.down)
            if whole >= 1 {
                parts.append("\(number(whole, maximumFractionDigits: 0)) \(name)")
                remaining -= whole * factor
            } else if !parts.isEmpty && name == "s" && remaining > 0.0005 {
                parts.append("\(number(remaining)) s")
            }
        }
        if parts.isEmpty { return "\(number(seconds)) s" }
        return sign + parts.joined(separator: " ")
    }

    /// A size with no explicitly requested unit is scaled inside **its own
    /// family**: an answer that started in GiB stays binary, one that started
    /// in GB stays decimal. Silently crossing between the two is the single
    /// most expensive mistake a size calculator can make, and `1.4 TiB in GB`
    /// exists precisely because the captain wanted the crossing to be
    /// deliberate and visible.
    static func data(_ quantity: ScratchpadQuantity) -> String {
        guard let unit = quantity.unit, unit.dimension == .data else { return number(quantity.amount) }
        if quantity.explicitUnit {
            return "\(number(quantity.amount)) \(unit.display)"
        }
        let binary = unit.code.hasSuffix("iB")
        let ladder = binary
            ? ["PiB", "TiB", "GiB", "MiB", "KiB", "B"]
            : (unit.code.hasSuffix("bit") || unit.code == "bit"
                ? ["Gbit", "Mbit", "kbit", "bit"]
                : ["PB", "TB", "GB", "MB", "kB", "B"])
        let bytes = quantity.base
        for code in ladder {
            guard let candidate = ScratchpadUnits.unit(code: code) else { continue }
            let scaled = candidate.fromBase(bytes)
            if abs(scaled) >= 1 || code == ladder.last {
                return "\(number(scaled)) \(candidate.display)"
            }
        }
        return "\(number(quantity.amount)) \(unit.display)"
    }

    // MARK: Dates

    /// A pure date always carries its year; a date **with a time** in the
    /// current year does not.
    ///
    /// Both halves are deliberate, and both come from what the two kinds of
    /// line are for. `2 weeks from Friday` is a plan - it is worth knowing it
    /// lands in 2026 rather than 2027, so `9 Oct 2026`. `1789977651 as date`
    /// is a log line being read right now, where the year is the one thing
    /// nobody is asking about, so `21 Sep, 2:00 PM`.
    static func date(_ date: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        // The calendar the expression was evaluated in owns the time zone, or
        // a pinned-`now` self-test in UTC would be rendered in the runner's
        // own zone and assert a different hour than it computed.
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let midnight = (components.hour ?? 0) == 0 && (components.minute ?? 0) == 0 && (components.second ?? 0) == 0
        if midnight {
            formatter.dateFormat = "d MMM yyyy"
            return formatter.string(from: date)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "d MMM, h:mm a" : "d MMM yyyy, h:mm a"
        return formatter.string(from: date)
    }
}

