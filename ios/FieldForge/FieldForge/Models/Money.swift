//
//  Money.swift
//  FieldForge
//
//  Money is stored as an integer number of minor units (cents) everywhere in
//  this app. Donation receipts are legal-ish documents and a half-cent of
//  binary floating point drift in a tax acknowledgment is not acceptable, so
//  Double never touches an amount. Formatting is the only place a Decimal
//  appears, and only long enough to hand it to NumberFormatter.
//

import Foundation

/// An exact monetary amount in a single currency.
struct Money: Hashable, Codable, Sendable {

    /// Amount in minor units — cents for USD. Negative values are legal
    /// (a refund or a correction) but the UI does not offer them.
    var minorUnits: Int

    /// ISO 4217 code. Stored per-gift so an organization that works across a
    /// border does not silently re-denominate its history.
    var currencyCode: String

    static let zero = Money(minorUnits: 0, currencyCode: Locale.current.currency?.identifier ?? "USD")

    init(minorUnits: Int, currencyCode: String = Locale.current.currency?.identifier ?? "USD") {
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode
    }

    /// Convenience for literals in code and tests: `Money(dollars: 250)`.
    init(dollars: Int, cents: Int = 0, currencyCode: String = "USD") {
        self.minorUnits = dollars * 100 + cents
        self.currencyCode = currencyCode
    }

    var isZero: Bool { minorUnits == 0 }
    var isPositive: Bool { minorUnits > 0 }

    /// `Decimal` form, used for formatting and for PassKit summary items.
    var decimalValue: Decimal {
        Decimal(minorUnits) / 100
    }

    /// "$1,250.00" — currency-correct and locale-aware.
    var formatted: String {
        decimalValue.formatted(.currency(code: currencyCode))
    }

    /// "$1,250" — drops trailing zero cents. Used in letter body copy, where
    /// "one thousand two hundred fifty dollars" reads better without ".00".
    var formattedCompact: String {
        if minorUnits % 100 == 0 {
            return decimalValue.formatted(
                .currency(code: currencyCode).precision(.fractionLength(0))
            )
        }
        return formatted
    }

    static func + (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currencyCode == rhs.currencyCode, "Refusing to add \(lhs.currencyCode) to \(rhs.currencyCode)")
        return Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currencyCode: lhs.currencyCode)
    }

    static func - (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currencyCode == rhs.currencyCode, "Refusing to subtract \(rhs.currencyCode) from \(lhs.currencyCode)")
        return Money(minorUnits: lhs.minorUnits - rhs.minorUnits, currencyCode: lhs.currencyCode)
    }

    static func sum(_ values: [Money], currencyCode: String = "USD") -> Money {
        let code = values.first?.currencyCode ?? currencyCode
        return Money(
            minorUnits: values.filter { $0.currencyCode == code }.reduce(0) { $0 + $1.minorUnits },
            currencyCode: code
        )
    }
}

extension Money {

    /// Parses whatever a thumb typed into the amount field. Tolerates currency
    /// symbols, thousands separators, and a decimal comma, because a staffer
    /// on a sidewalk should not have to care.
    ///
    /// Returns `nil` for input with no digits at all.
    static func parse(_ input: String, currencyCode: String = Locale.current.currency?.identifier ?? "USD") -> Money? {
        let allowed = input.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
        guard allowed.contains(where: \.isNumber) else { return nil }

        let isNegative = allowed.hasPrefix("-")
        var digitsAndSeparators = allowed.replacingOccurrences(of: "-", with: "")

        // Whichever separator appears last is the decimal separator; the other
        // one is grouping. "1.234,56" and "1,234.56" both land on 123456.
        let lastDot = digitsAndSeparators.lastIndex(of: ".")
        let lastComma = digitsAndSeparators.lastIndex(of: ",")
        let decimalSeparator: Character?
        switch (lastDot, lastComma) {
        case let (dot?, comma?): decimalSeparator = dot > comma ? "." : ","
        case (.some, nil): decimalSeparator = "."
        case (nil, .some): decimalSeparator = ","
        case (nil, nil): decimalSeparator = nil
        }

        var fraction = 0
        if let separator = decimalSeparator, let index = digitsAndSeparators.lastIndex(of: separator) {
            let fractionDigits = digitsAndSeparators[digitsAndSeparators.index(after: index)...].filter(\.isNumber)
            // Only two digits after the separator means cents; three means it
            // was actually a grouping separator ("1,234" -> 1234 dollars).
            if fractionDigits.count <= 2 {
                fraction = Int(fractionDigits.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
                digitsAndSeparators = String(digitsAndSeparators[..<index])
            }
        }

        let whole = Int(digitsAndSeparators.filter(\.isNumber)) ?? 0
        let magnitude = whole * 100 + fraction
        return Money(minorUnits: isNegative ? -magnitude : magnitude, currencyCode: currencyCode)
    }
}
