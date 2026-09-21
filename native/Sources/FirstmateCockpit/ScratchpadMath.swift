// Manjesh Grand Line - native macOS app.
//
// The Scratchpad calculator's arithmetic (F9 of full review #3 §8) - what
// happens when two values meet an operator, and what a conversion does.
//
// Every operation either produces a value or throws `.semantic`, and the
// message it throws is what the pad prints in its result column. They are
// written as sentences for that reason: "kg and seconds are not the same kind
// of thing" is a usable answer, "type error" is not.

import Foundation

enum ScratchpadMath {

    // MARK: Addition

    static func add(_ left: ScratchpadValue, _ right: ScratchpadValue, subtract: Bool,
                    calendar: Calendar) throws -> ScratchpadValue {
        let sign = subtract ? -1.0 : 1.0
        switch (left, right) {
        case (.date(let a), .date(let b)):
            guard subtract else { throw ScratchpadError.semantic("two dates cannot be added") }
            let seconds = a.timeIntervalSince(b)
            return .quantity(ScratchpadQuantity(seconds, unit: ScratchpadUnits.unit(code: "s")))
        case (.date(let a), .quantity(let q)):
            guard q.unit?.dimension == .duration else {
                throw ScratchpadError.semantic("only a duration can be added to a date")
            }
            return .date(ScratchpadDates.shift(a, by: q, sign: subtract ? -1 : 1, calendar: calendar))
        case (.quantity(let q), .date(let b)):
            guard !subtract, q.unit?.dimension == .duration else {
                throw ScratchpadError.semantic("only a duration can be added to a date")
            }
            return .date(ScratchpadDates.shift(b, by: q, sign: 1, calendar: calendar))
        case (.quantity(var a), .quantity(let b)):
            // `2400 + 15%` is 2760. A percentage on the right of a sum is
            // read as a change *to* the left, which is how every pad and
            // every spreadsheet user means it.
            if b.dimension == .percent, a.dimension != .percent {
                a.amount *= (1 + sign * b.base)
                return .quantity(a)
            }
            if a.dimension == .percent, b.dimension != .percent {
                throw ScratchpadError.semantic("a percentage cannot have a quantity added to it - try \"\(ScratchpadFormat.quantity(a)) of ...\"")
            }
            guard a.per == b.per else {
                throw ScratchpadError.semantic("those two are measured over different periods")
            }
            if a.unit == nil && b.unit == nil {
                a.amount += sign * b.amount
                return .quantity(a)
            }
            guard let unitA = a.unit, let unitB = b.unit else {
                throw ScratchpadError.semantic("a plain number and a \(describe(a.unit ?? b.unit)) cannot be added")
            }
            guard unitA.dimension == unitB.dimension else {
                throw ScratchpadError.semantic("\(describe(unitA)) and \(describe(unitB)) are not the same kind of thing")
            }
            // Temperature adds as a *difference*, not as two affine points:
            // 20 °C + 5 °C is 25 °C, not 298 °C.
            if unitA.dimension == .temperature {
                a.amount += sign * (unitB.factor / unitA.factor) * b.amount
                return .quantity(a)
            }
            a.amount = unitA.fromBase(unitA.toBase(a.amount) + sign * unitB.toBase(b.amount))
            return .quantity(a)
        default:
            throw ScratchpadError.semantic("those two cannot be added")
        }
    }

    // MARK: Multiplication and division

    static func multiply(_ left: ScratchpadValue, _ right: ScratchpadValue) throws -> ScratchpadValue {
        guard let a = left.quantity, let b = right.quantity else {
            throw ScratchpadError.semantic("a date cannot be multiplied")
        }
        if b.dimension == .percent { return .quantity(scaled(a, by: b.base)) }
        if a.dimension == .percent { return .quantity(scaled(b, by: a.base)) }
        if b.isPlain { return .quantity(scaled(a, by: b.amount)) }
        if a.isPlain { return .quantity(scaled(b, by: a.amount)) }
        // A rate times a span of its own period collapses to a total:
        // `$18.50/mo * 12 months` is `$222.00`.
        if let per = a.per, per.dimension == b.dimension, let unitB = b.unit {
            var result = a
            result.amount *= unitB.toBase(b.amount) / per.toBase(1)
            result.per = nil
            return .quantity(result)
        }
        if let per = b.per, per.dimension == a.dimension, let unitA = a.unit {
            var result = b
            result.amount *= unitA.toBase(a.amount) / per.toBase(1)
            result.per = nil
            return .quantity(result)
        }
        throw ScratchpadError.semantic("\(describe(a.unit)) times \(describe(b.unit)) is not something this pad measures")
    }

    static func divide(_ left: ScratchpadValue, _ right: ScratchpadValue) throws -> ScratchpadValue {
        guard let a = left.quantity, let b = right.quantity else {
            throw ScratchpadError.semantic("a date cannot be divided")
        }
        guard b.amount != 0 else { throw ScratchpadError.semantic("divided by zero") }
        if b.isPlain || b.dimension == .percent {
            return .quantity(scaled(a, by: 1 / (b.dimension == .percent ? b.base : b.amount)))
        }
        if let unitA = a.unit, let unitB = b.unit, unitA.dimension == unitB.dimension, a.per == b.per {
            return .quantity(ScratchpadQuantity(unitA.toBase(a.amount) / unitB.toBase(b.amount)))
        }
        // The rate case, and the reason `per` exists: a quantity over a
        // duration keeps the duration as its denominator rather than
        // collapsing to a number nobody can label.
        if let unitB = b.unit, unitB.dimension == .duration, a.per == nil {
            var result = a
            result.amount /= b.amount
            result.per = unitB
            return .quantity(result)
        }
        throw ScratchpadError.semantic("\(describe(a.unit)) divided by \(describe(b.unit)) is not something this pad measures")
    }

    /// `15% of 2400`.
    static func percentOf(_ left: ScratchpadValue, _ right: ScratchpadValue) throws -> ScratchpadValue {
        guard let a = left.quantity, a.dimension == .percent else {
            throw ScratchpadError.semantic("\"of\" wants a percentage on its left, as in \"15% of 2400\"")
        }
        guard let b = right.quantity else { throw ScratchpadError.semantic("\"of\" cannot take a date") }
        return .quantity(scaled(b, by: a.base))
    }

    private static func scaled(_ quantity: ScratchpadQuantity, by factor: Double) -> ScratchpadQuantity {
        var result = quantity
        // Scaling a temperature scales the *reading*, which is only meaningful
        // as a relative change - so it goes through the base the same way a
        // length does, and `20 °C * 2` is 40 °C rather than 313 °C.
        result.amount *= factor
        return result
    }

    // MARK: Conversion

    static func convert(_ value: ScratchpadValue, to target: ScratchpadUnit,
                        calendar: Calendar) throws -> ScratchpadValue {
        guard var quantity = value.quantity else {
            throw ScratchpadError.semantic("a date is not a \(describe(target))")
        }
        if target.dimension == .percent, quantity.isPlain {
            return .quantity(ScratchpadQuantity(quantity.amount * 100, unit: target, explicitUnit: true))
        }
        guard let unit = quantity.unit else {
            throw ScratchpadError.semantic("\(ScratchpadFormat.number(quantity.amount)) has no unit to convert from")
        }
        if unit.dimension == target.dimension {
            quantity.amount = target.fromBase(unit.toBase(quantity.amount))
            quantity.unit = target
            quantity.explicitUnit = true
            return .quantity(quantity)
        }
        // Re-basing a rate's *period*: `$777/mo in years` is `$9,324/yr`. The
        // numerator's dimension is untouched, which is why this is checked
        // only after the straightforward case above has missed.
        if let per = quantity.per, per.dimension == target.dimension {
            quantity.amount *= target.toBase(1) / per.toBase(1)
            quantity.per = target
            return .quantity(quantity)
        }
        throw ScratchpadError.semantic("\(describe(unit)) cannot be expressed in \(describe(target))")
    }

    /// `as hex` / `as binary` / `as octal`.
    static func radix(_ value: ScratchpadValue, radix: Int, prefix: String) throws -> String {
        guard let quantity = value.quantity, quantity.isPlain else {
            throw ScratchpadError.semantic("only a plain whole number has a base-\(radix) form")
        }
        let rounded = quantity.amount.rounded()
        guard abs(quantity.amount - rounded) < 1e-9, abs(rounded) <= 9.2e18 else {
            throw ScratchpadError.semantic("only a whole number has a base-\(radix) form")
        }
        let magnitude = String(UInt64(abs(rounded)), radix: radix).uppercased()
        return (rounded < 0 ? "-" : "") + prefix + magnitude
    }

    /// How a unit is named inside an error message.
    private static func describe(_ unit: ScratchpadUnit?) -> String {
        guard let unit else { return "a plain number" }
        switch unit.dimension {
        case .currency: return unit.code
        case .plain: return "a plain number"
        default: return unit.display
        }
    }
}
