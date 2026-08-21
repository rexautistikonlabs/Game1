//
//  MoneyTests.swift
//  FieldForgeTests
//
//  Money is stored as integer cents specifically so that a tax document can
//  never show a rounding artefact. These tests are the guardrail on that, plus
//  the input parser, which sees whatever a thumb types on a sidewalk.
//

import Testing
@testable import FieldForge

struct MoneyTests {

    // MARK: Exactness

    @Test("Cents stay exact through arithmetic that would drift as a Double")
    func arithmeticIsExact() {
        // 0.1 + 0.2 != 0.3 in binary floating point. In cents it is exactly 30.
        let dime = Money(minorUnits: 10)
        let twoDimes = Money(minorUnits: 20)
        #expect((dime + twoDimes).minorUnits == 30)

        // A hundred ten-cent gifts is exactly ten dollars.
        let hundredDimes = Money.sum(Array(repeating: dime, count: 100))
        #expect(hundredDimes.minorUnits == 1_000)
    }

    @Test("Subtraction is exact and can go negative")
    func subtraction() {
        let payment = Money(dollars: 50)
        let benefit = Money(dollars: 60)
        #expect((payment - benefit).minorUnits == -1_000)
    }

    @Test("Summing mixed currencies ignores the ones that do not match")
    func mixedCurrencySum() {
        let usd = Money(minorUnits: 100, currencyCode: "USD")
        let eur = Money(minorUnits: 100, currencyCode: "EUR")
        let total = Money.sum([usd, eur, usd])
        #expect(total.currencyCode == "USD")
        #expect(total.minorUnits == 200)
    }

    // MARK: Parsing

    @Test("Parses the shapes a thumb actually types", arguments: [
        ("2500", 250_000),        // digit accumulation from the amount pad
        ("25.00", 2_500),
        ("25", 2_500),
        ("$1,250.00", 125_000),
        ("1250", 125_000),
        ("0.50", 50),
        (".5", 50),
        ("5.5", 550),
        ("1.234,56", 123_456),    // European separators
        ("1,234.56", 123_456),
        ("1,234", 123_400),       // three digits after a comma is grouping
        ("-25.00", -2_500),
    ])
    func parsing(input: String, expected: Int) {
        let parsed = Money.parse(input, currencyCode: "USD")
        #expect(parsed?.minorUnits == expected, "\(input) should be \(expected) cents")
    }

    @Test("Refuses input with no digits", arguments: ["", "   ", "$", "abc", "-", ".", ","])
    func parsingRejectsGarbage(input: String) {
        #expect(Money.parse(input) == nil)
    }

    // MARK: Formatting

    @Test("Compact formatting drops zero cents but keeps real ones")
    func compactFormatting() {
        let round = Money(dollars: 250, currencyCode: "USD")
        let notRound = Money(dollars: 250, cents: 37, currencyCode: "USD")
        // Locale decides the symbol and separators, so assert on the parts that
        // are ours: whether a fractional component is present at all.
        #expect(!round.formattedCompact.contains(".00"))
        #expect(notRound.formattedCompact.contains("37"))
    }

    @Test("Zero and positivity")
    func flags() {
        #expect(Money(minorUnits: 0).isZero)
        #expect(!Money(minorUnits: 0).isPositive)
        #expect(Money(minorUnits: 1).isPositive)
        #expect(!Money(minorUnits: -1).isPositive)
    }

    @Test("Decimal conversion is exact for values a donation can take")
    func decimalConversion() {
        #expect(Money(minorUnits: 12_345).decimalValue == Decimal(string: "123.45"))
        #expect(Money(minorUnits: 1).decimalValue == Decimal(string: "0.01"))
    }
}
