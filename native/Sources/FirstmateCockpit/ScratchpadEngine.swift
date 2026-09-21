// Manjesh Grand Line - native macOS app.
//
// The Scratchpad calculator's engine (F9 of full review #3 §8): one line of
// text in, one result string out, with the variables a previous line defined
// still in hand.
//
// ## Shape
//
// A hand-written lexer, a recursive-descent parser and an evaluator that works
// on `ScratchpadValue`. Roughly 250 lines of grammar - small enough to read in
// one sitting, which matters more here than generality: the thing this has to
// be is *predictable*, because a pad whose answers you have to double-check is
// worse than a calculator.
//
// The grammar, loosest binding first:
//
//     line        := statement (';' statement)*
//     statement   := IDENT '=' expression | expression
//     expression  := phrase (('in'|'to'|'as') target)*
//     phrase      := additive (('from'|'after'|'before') phrase | 'ago')?
//     additive    := multiplicative (('+'|'-') multiplicative)*
//     multiplicative := unary (('*'|'/'|'per'|'of') unary)*
//     unary       := ('-'|'+')? power
//     power       := postfix ('^' unary)?
//     postfix     := primary unit* (number unit)*
//     primary     := NUMBER | IDENT | 'that' | DATE-WORD | ISO-DATE | '(' expression ')'
//
// ## Two classes of failure, and why the pad is quiet about one of them
//
// A scratchpad is also a notepad: the captain writes "renewal quote came in
// today" on one line and `seats * seat_price` on the next, and the prose line
// must not shout. So a **parse** failure (a word that is not a unit, a
// variable or a number) renders as an empty result, while a **semantic**
// failure - units that cannot be added, an unknown variable in an otherwise
// well-formed expression, a division by zero - renders its message in the
// result column. That split is the one rule in this file a reader has to hold
// on to, and `ScratchpadEngineSelfTest` asserts both directions of it.
//
// ## Determinism
//
// `evaluate` takes `now` and a `Calendar` and never reads the clock itself.
// Every date case in the suite therefore asserts a real answer against a
// pinned Tuesday rather than something vague, which is AGENTS.md's "a check
// that cannot fail is worse than no check" applied to the one part of this
// feature that is inherently time-dependent.

import Foundation

// MARK: - Errors

enum ScratchpadError: Error {
    /// The line is not an expression at all - prose, a heading, a stray word.
    /// Rendered as nothing. See this file's header.
    case parse(String)
    /// The line *is* an expression and could not be computed. Rendered.
    case semantic(String)

    var message: String {
        switch self {
        case .parse(let text), .semantic(let text): return text
        }
    }
}

// MARK: - Lexer

enum ScratchpadToken: Equatable {
    case number(Double)
    case word(String)
    case symbol(String)
    case isoDate(Int, Int, Int)
}

enum ScratchpadLexer {

    // `%` is deliberately **not** here: it is a unit (`15%`, `2400 + 15%`),
    // and lexing it as a symbol would need the parser to special-case it in
    // three places instead of the unit table handling it in none.
    private static let symbols: Set<Character> = ["+", "-", "*", "/", "^", "(", ")", "=", "\u{00D7}", "\u{00F7}"]
    private static let currencySymbols: [Character: String] = [
        "$": "USD", "\u{20AC}": "EUR", "\u{00A3}": "GBP", "\u{20B9}": "INR", "\u{00A5}": "JPY",
    ]

    /// Tokenise one statement. Throws `.parse` for a character that cannot
    /// start a token, which is how prose drops out quietly.
    static func tokens(_ input: String) throws -> [ScratchpadToken] {
        var out: [ScratchpadToken] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "#" { break }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" { break }
            if let code = currencySymbols[c] {
                out.append(.word(code))
                i += 1
                continue
            }
            if symbols.contains(c) {
                out.append(.symbol(String(c)))
                i += 1
                continue
            }
            if c.isNumber {
                let (token, next) = try number(chars, from: i)
                out.append(token)
                i = next
                continue
            }
            if c == "%" {
                out.append(.word("%"))
                i += 1
                continue
            }
            if c.isLetter || c == "_" || c == "\u{00B5}" || c == "\u{00B0}" {
                var word = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_"
                    || chars[i] == "\u{00B5}" || chars[i] == "\u{00B0}" {
                    word.append(chars[i])
                    i += 1
                }
                out.append(.word(word))
                continue
            }
            throw ScratchpadError.parse("\(c) is not something this pad understands")
        }
        return out
    }

    /// True when the comma at `index` is a thousands separator: exactly three
    /// digits follow it, and no fourth.
    private static func isGroupSeparator(_ chars: [Character], at index: Int) -> Bool {
        let digits = chars.dropFirst(index + 1).prefix(4)
        guard digits.count >= 3 else { return false }
        let three = digits.prefix(3).allSatisfy { $0.isNumber }
        let fourth = digits.count == 4 ? digits.last!.isNumber : false
        return three && !fourth
    }

    /// A number, in decimal (with optional `_`/`,` grouping) or with a radix
    /// prefix. An ISO date is recognised here rather than in the parser, since
    /// `2026-10-09` is otherwise three numbers and two minus signs.
    private static func number(_ chars: [Character], from start: Int) throws -> (ScratchpadToken, Int) {
        var i = start
        if chars[i] == "0", i + 1 < chars.count, "xXbBoO".contains(chars[i + 1]) {
            let marker = Character(String(chars[i + 1]).lowercased())
            let radix = marker == "x" ? 16 : (marker == "b" ? 2 : 8)
            var digits = ""
            var j = i + 2
            while j < chars.count, chars[j].isHexDigit || chars[j] == "_" {
                if chars[j] != "_" { digits.append(chars[j]) }
                j += 1
            }
            guard !digits.isEmpty, let value = UInt64(digits, radix: radix) else {
                throw ScratchpadError.parse("\(String(chars[i..<min(j, chars.count)])) is not a number in base \(radix)")
            }
            return (.number(Double(value)), j)
        }
        var text = ""
        var sawDot = false
        while i < chars.count {
            let c = chars[i]
            if c.isNumber { text.append(c); i += 1; continue }
            if c == "_" { i += 1; continue }
            // A comma groups only in the shape a thousands separator actually
            // takes - exactly three digits, not followed by a fourth. `1,000`
            // is one number; `5,5` is not, so a captain writing a European
            // decimal gets nothing rather than silently getting 55.
            if c == ",", isGroupSeparator(chars, at: i) { i += 1; continue }
            if c == ".", !sawDot, i + 1 < chars.count, chars[i + 1].isNumber {
                sawDot = true
                text.append(c)
                i += 1
                continue
            }
            break
        }
        // Scientific notation, which a capacity or latency line reaches for
        // more often than it reaches for a unit: `1e5`, `1.5e3`, `2e-3`.
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            var j = i + 1
            var exponent = ""
            if j < chars.count, chars[j] == "-" || chars[j] == "+" {
                exponent.append(chars[j])
                j += 1
            }
            var digits = ""
            while j < chars.count, chars[j].isNumber {
                digits.append(chars[j])
                j += 1
            }
            // Only when the exponent is followed by nothing that could make
            // this a unit instead - `3e` is not a number, and neither is the
            // `2eur` somebody might type.
            if !digits.isEmpty, j >= chars.count || !(chars[j].isLetter || chars[j] == "_") {
                text += "e" + exponent + digits
                i = j
            }
        }
        // `yyyy-MM-dd`, recognised only in that exact shape.
        if text.count == 4, !sawDot, i + 5 < chars.count + 1 {
            let rest = Array(chars[i...])
            if rest.count >= 6, rest[0] == "-", rest[1].isNumber, rest[2].isNumber, rest[3] == "-",
               rest[4].isNumber, rest[5].isNumber,
               let year = Int(text), let month = Int(String(rest[1...2])), let day = Int(String(rest[4...5])) {
                return (.isoDate(year, month, day), i + 6)
            }
        }
        guard let value = Double(text) else {
            throw ScratchpadError.parse("\(text) is not a number")
        }
        return (.number(value), i)
    }
}

// MARK: - Context

/// What one pad knows: the variables its earlier lines defined, and the value
/// `that` refers to.
final class ScratchpadContext {
    private(set) var variables: [String: ScratchpadValue] = [:]
    private(set) var last: ScratchpadValue?
    let now: Date
    let calendar: Calendar

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    func define(_ name: String, _ value: ScratchpadValue) { variables[name.lowercased()] = value }
    func value(of name: String) -> ScratchpadValue? { variables[name.lowercased()] }
    func remember(_ value: ScratchpadValue) { last = value }
}

// MARK: - Parser / evaluator

/// Parses and evaluates in one pass. There is no AST: a pad line is evaluated
/// exactly once, the moment it is parsed, so building a tree to walk
/// immediately afterwards would be ceremony rather than structure.
struct ScratchpadParser {
    private let tokens: [ScratchpadToken]
    private var index = 0
    private let context: ScratchpadContext

    /// What dimension a bare, ambiguous unit on the right of an operator
    /// should be read as - see `ScratchpadUnits.unit(for:preferring:)`.
    ///
    /// `3h 40m + 95m` is the case: each `m` is minutes only because what it is
    /// being added to is a duration, and a recursive-descent parser otherwise
    /// evaluates the right-hand side knowing nothing about the left. Set
    /// around one sub-parse and restored immediately, so it can never leak
    /// into the next line.
    private var dimensionHint: ScratchpadDimension?

    init(tokens: [ScratchpadToken], context: ScratchpadContext) {
        self.tokens = tokens
        self.context = context
    }

    static func evaluate(_ statement: String, context: ScratchpadContext) throws -> ScratchpadValue {
        let tokens = try ScratchpadLexer.tokens(statement)
        guard !tokens.isEmpty else { throw ScratchpadError.parse("empty") }
        var parser = ScratchpadParser(tokens: tokens, context: context)
        let value = try parser.expression()
        guard parser.index == parser.tokens.count else {
            throw ScratchpadError.parse("trailing input")
        }
        return value
    }

    // MARK: Token helpers

    private var peek: ScratchpadToken? { index < tokens.count ? tokens[index] : nil }

    private func peekWord(_ offset: Int = 0) -> String? {
        guard index + offset < tokens.count, case .word(let w) = tokens[index + offset] else { return nil }
        return w
    }

    private func peekSymbol() -> String? {
        guard case .symbol(let s)? = peek else { return nil }
        return s
    }

    private mutating func matchWord(_ options: Set<String>) -> String? {
        guard let word = peekWord(), options.contains(word.lowercased()) else { return nil }
        index += 1
        return word.lowercased()
    }

    private mutating func matchSymbol(_ options: Set<String>) -> String? {
        guard let symbol = peekSymbol(), options.contains(symbol) else { return nil }
        index += 1
        return symbol
    }

    // MARK: Grammar

    private mutating func expression() throws -> ScratchpadValue {
        var value = try phrase()
        while matchWord(["in", "to", "as"]) != nil {
            value = try convert(value)
        }
        return value
    }

    private mutating func phrase() throws -> ScratchpadValue {
        let value = try additive()
        if let keyword = matchWord(["from", "after", "before"]) {
            let anchor = try phrase()
            guard let duration = value.quantity, duration.unit?.dimension == .duration else {
                throw ScratchpadError.semantic("\"\(keyword)\" needs a duration on its left")
            }
            guard case .date(let date) = anchor else {
                throw ScratchpadError.semantic("\"\(keyword)\" needs a date on its right")
            }
            return .date(ScratchpadDates.shift(date, by: duration, sign: keyword == "before" ? -1 : 1,
                                               calendar: context.calendar))
        }
        if matchWord(["ago"]) != nil {
            guard let duration = value.quantity, duration.unit?.dimension == .duration else {
                throw ScratchpadError.semantic("\"ago\" needs a duration on its left")
            }
            return .date(ScratchpadDates.shift(context.now, by: duration, sign: -1, calendar: context.calendar))
        }
        return value
    }

    private mutating func additive() throws -> ScratchpadValue {
        var left = try multiplicative()
        while let op = matchSymbol(["+", "-"]) {
            let right = try withHint(left.quantity?.unit?.dimension) { try $0.multiplicative() }
            left = try ScratchpadMath.add(left, right, subtract: op == "-", calendar: context.calendar)
        }
        return left
    }

    private mutating func multiplicative() throws -> ScratchpadValue {
        var left = try unary()
        while true {
            if let symbol = matchSymbol(["*", "/", "\u{00D7}", "\u{00F7}"]) {
                let right = try unary()
                let dividing = (symbol == "/" || symbol == "\u{00F7}")
                left = dividing ? try ScratchpadMath.divide(left, right) : try ScratchpadMath.multiply(left, right)
                continue
            }
            if matchWord(["per"]) != nil {
                let right = try unary()
                left = try ScratchpadMath.divide(left, right)
                continue
            }
            if matchWord(["of"]) != nil {
                let right = try unary()
                left = try ScratchpadMath.percentOf(left, right)
                continue
            }
            return left
        }
    }

    private mutating func unary() throws -> ScratchpadValue {
        if matchSymbol(["-"]) != nil {
            let value = try unary()
            guard var quantity = value.quantity else {
                throw ScratchpadError.semantic("a date cannot be negated")
            }
            quantity.amount = -quantity.amount
            return .quantity(quantity)
        }
        _ = matchSymbol(["+"])
        return try power()
    }

    private mutating func power() throws -> ScratchpadValue {
        let base = try postfix()
        guard matchSymbol(["^"]) != nil else { return base }
        let exponent = try unary()
        guard let b = base.quantity, let e = exponent.quantity, e.isPlain else {
            throw ScratchpadError.semantic("a power needs a plain number as its exponent")
        }
        return .quantity(ScratchpadQuantity(pow(b.amount, e.amount), unit: b.unit, per: b.per))
    }

    /// A primary, then any units written after it, then any *adjacent* same
    /// dimension quantity (`3h 40m`, `5 kg 200 g`), which reads as a sum.
    private mutating func postfix() throws -> ScratchpadValue {
        var value = try primary()
        value = attachUnits(to: value)
        while let quantity = value.quantity, let unit = quantity.unit,
              case .number? = peek, let following = peekWord(1), !ScratchpadUnits.isGrammarWord(following),
              let next = ScratchpadUnits.unit(for: following, preferring: unit.dimension),
              next.dimension == unit.dimension, next.dimension != .temperature {
            let addend = try withHint(unit.dimension) { parser -> ScratchpadValue in
                parser.attachUnits(to: try parser.primary())
            }
            value = try ScratchpadMath.add(value, addend, subtract: false, calendar: context.calendar)
        }
        return value
    }

    /// Run one sub-parse with a dimension hint in place, restoring whatever
    /// was there before - the hint belongs to one operand, not to the line.
    private mutating func withHint<T>(_ dimension: ScratchpadDimension?,
                                      _ body: (inout ScratchpadParser) throws -> T) rethrows -> T {
        let saved = dimensionHint
        dimensionHint = dimension
        defer { dimensionHint = saved }
        return try body(&self)
    }

    /// Consume unit words sitting immediately after a value.
    ///
    /// The one rewrite here is Kubernetes millicores: `m` on its own stays
    /// metres (making it minutes or millis would make `840ms` ambiguous the
    /// moment a space slipped in), and it becomes millicores only when the
    /// word `cpu`/`cores` follows it - which is exactly how a manifest writes
    /// it (`250m`, under `resources.requests.cpu`).
    private mutating func attachUnits(to value: ScratchpadValue) -> ScratchpadValue {
        guard var quantity = value.quantity else { return value }
        while let word = peekWord(), !ScratchpadUnits.isGrammarWord(word),
              let unit = ScratchpadUnits.unit(for: word, preferring: quantity.unit?.dimension ?? dimensionHint) {
            if quantity.unit == nil {
                quantity.unit = unit
            } else if quantity.unit?.code == "m", unit.dimension == .cpu {
                quantity.unit = ScratchpadUnits.unit(code: "mcpu")
            } else if quantity.unit?.dimension == .cpu, unit.dimension == .cpu {
                // `250m cpu cores` - a second cpu word adds nothing.
            } else {
                break
            }
            index += 1
        }
        return .quantity(quantity)
    }

    private mutating func primary() throws -> ScratchpadValue {
        guard let token = peek else { throw ScratchpadError.parse("the line ends early") }
        switch token {
        case .symbol("("):
            index += 1
            let value = try expression()
            guard matchSymbol([")"]) != nil else { throw ScratchpadError.parse("a ( was never closed") }
            return value
        case .number(let value):
            index += 1
            return .number(value)
        case .isoDate(let year, let month, let day):
            index += 1
            guard let date = ScratchpadDates.date(year: year, month: month, day: day, calendar: context.calendar) else {
                throw ScratchpadError.semantic("\(year)-\(month)-\(day) is not a real date")
            }
            return .date(date)
        case .word(let word):
            index += 1
            return try wordValue(word)
        case .symbol(let symbol):
            throw ScratchpadError.parse("\(symbol) cannot start a value")
        }
    }

    /// The resolution order for a bare word, and it is deliberate: a variable
    /// the captain defined wins over everything (a pad with `t = 12` on line
    /// one must not have `t` mean tonnes on line two), then `that`, then a
    /// date word, then a unit.
    private mutating func wordValue(_ word: String) throws -> ScratchpadValue {
        let lower = word.lowercased()
        if let value = context.value(of: lower) { return value }
        if ["that", "prev", "previous", "ans"].contains(lower) {
            guard let last = context.last else {
                throw ScratchpadError.semantic("there is no earlier result for \"that\" to mean")
            }
            return last
        }
        if ScratchpadDates.isDateWord(lower) {
            if let resolved = ScratchpadDates.resolve(lower, following: peekWord(), now: context.now,
                                                      calendar: context.calendar) {
                if resolved.consumedFollowing { index += 1 }
                return .date(resolved.date)
            }
        }
        if !ScratchpadUnits.isGrammarWord(word), let unit = ScratchpadUnits.unit(for: word) {
            // A currency symbol or code written *before* its number - `$100`,
            // `USD 100` - which is how half the world writes money.
            if case .number(let value)? = peek {
                index += 1
                return .quantity(ScratchpadQuantity(value, unit: unit))
            }
            return .quantity(ScratchpadQuantity(1, unit: unit))
        }
        throw ScratchpadError.parse("\(word) is not a number, a unit or anything this pad has been told about")
    }

    // MARK: Conversion (`in` / `to` / `as`)

    private mutating func convert(_ value: ScratchpadValue) throws -> ScratchpadValue {
        guard let word = peekWord() else { throw ScratchpadError.parse("nothing to convert to") }
        index += 1
        let lower = word.lowercased()
        switch lower {
        case "hex", "hexadecimal":
            return .text(try ScratchpadMath.radix(value, radix: 16, prefix: "0x"))
        case "binary", "bin":
            return .text(try ScratchpadMath.radix(value, radix: 2, prefix: "0b"))
        case "octal", "oct":
            return .text(try ScratchpadMath.radix(value, radix: 8, prefix: "0o"))
        case "decimal", "dec", "number":
            guard let quantity = value.quantity else {
                throw ScratchpadError.semantic("a date is already not a number")
            }
            return .quantity(ScratchpadQuantity(quantity.amount, unit: quantity.unit, per: quantity.per))
        case "date", "datetime", "time":
            guard let quantity = value.quantity, quantity.isPlain || quantity.dimension == .duration else {
                throw ScratchpadError.semantic("only a Unix timestamp can be read as a date")
            }
            return .date(Date(timeIntervalSince1970: quantity.isPlain ? quantity.amount : quantity.base))
        default:
            guard let target = ScratchpadUnits.unit(for: word) else {
                throw ScratchpadError.semantic("\(word) is not a unit this pad knows")
            }
            return try ScratchpadMath.convert(value, to: target, calendar: context.calendar)
        }
    }
}

// MARK: - The document API

/// Evaluate a whole pad: every line, in order, sharing one set of variables.
///
/// This is the entry point the UI calls on every keystroke and the one every
/// self-test case goes through, so what the suite asserts is what the pad
/// shows - not a layer below it.
enum ScratchpadEngine {

    /// One line's answer. `display` is exactly the string the result column
    /// paints; `isError` only says how to *colour* it, since an error already
    /// carries its own message.
    struct LineResult: Equatable {
        var display: String
        var isError: Bool
        var value: ScratchpadValue?

        static let blank = LineResult(display: "", isError: false, value: nil)
    }

    /// A line that begins with `name =` defines a variable. Deliberately
    /// anchored and deliberately narrow: `a == b` is not an assignment, and
    /// neither is anything with an operator on the left.
    private static let assignment = try? NSRegularExpression(
        pattern: "^\\s*([A-Za-z_][A-Za-z_0-9]*)\\s*=(?!=)\\s*(.+)$")

    static func evaluate(document: String, now: Date = Date(), calendar: Calendar = .current) -> [LineResult] {
        evaluate(lines: document.components(separatedBy: "\n"), now: now, calendar: calendar)
    }

    static func evaluate(lines: [String], now: Date = Date(), calendar: Calendar = .current) -> [LineResult] {
        let context = ScratchpadContext(now: now, calendar: calendar)
        return lines.map { line(for: $0, context: context) }
    }

    /// Evaluate one line against a context the caller owns - the shape the
    /// whole-document pass above is built from, exposed because a suite
    /// asserting `that` and variables one line at a time wants exactly this.
    static func line(for text: String, context: ScratchpadContext) -> LineResult {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else { return .blank }

        var result = LineResult.blank
        // `p95 = 840ms; p95 * 1.35` - several statements on one line, the last
        // one's answer being the line's answer. Every statement still runs, so
        // the assignment lands.
        for statement in trimmed.components(separatedBy: ";") {
            let piece = statement.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            result = evaluateStatement(piece, context: context)
        }
        if let value = result.value { context.remember(value) }
        return result
    }

    private static func evaluateStatement(_ statement: String, context: ScratchpadContext) -> LineResult {
        var name: String?
        var body = statement
        let range = NSRange(statement.startIndex..<statement.endIndex, in: statement)
        if let match = assignment?.firstMatch(in: statement, range: range),
           let nameRange = Range(match.range(at: 1), in: statement),
           let bodyRange = Range(match.range(at: 2), in: statement) {
            let candidate = String(statement[nameRange])
            // `that = ...` would make the pad's own pronoun a variable, and
            // `in`/`of`/`as` are grammar. A line naming one of those is not an
            // assignment; it falls through and is evaluated as an expression.
            if !reservedNames.contains(candidate.lowercased()) {
                name = candidate
                body = String(statement[bodyRange])
            }
        }
        do {
            let value = try ScratchpadParser.evaluate(body, context: context)
            if let name { context.define(name, value) }
            return LineResult(display: ScratchpadFormat.string(for: value, calendar: context.calendar, now: context.now),
                              isError: false, value: value)
        } catch let error as ScratchpadError {
            switch error {
            case .parse:
                // Prose. A pad is a notepad too - see this file's header.
                return .blank
            case .semantic(let message):
                return LineResult(display: message, isError: true, value: nil)
            }
        } catch {
            return .blank
        }
    }

    private static let reservedNames: Set<String> = [
        "that", "prev", "previous", "ans", "in", "to", "as", "of", "per", "from", "after", "before", "ago",
    ]

    /// Every result in one block, for the toolbar's "Copy all results" - blank
    /// lines kept blank so the copied column still lines up with the pad the
    /// captain is looking at.
    static func copyableResults(_ results: [LineResult]) -> String {
        results.map { $0.isError ? "" : $0.display }.joined(separator: "\n")
    }

    /// The short list under the pad. Written here rather than in the view
    /// because it is a claim about what the engine understands, and it should
    /// change in the same commit the grammar does.
    static let examples: [String] = [
        "120 GiB in MB", "15% of 2400", "3h 40m + 95m", "next tuesday", "0b1011 as hex", "250m cpu * 6",
    ]
}
