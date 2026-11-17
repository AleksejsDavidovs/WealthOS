import Foundation
import Testing
@testable import WealthOS

@Suite("Money & parsing")
struct MoneyAndParsingTests {
    let us = Locale(identifier: "en_US")
    let de = Locale(identifier: "de_DE")

    @Test func parsesDotDecimal() {
        #expect(DecimalParser.parse("1234.56", locale: us)?.value == Decimal(string: "1234.56"))
        #expect(DecimalParser.parse("1,234.56", locale: us)?.value == Decimal(string: "1234.56"))
    }

    @Test func parsesCommaDecimal() {
        #expect(DecimalParser.parse("1.234,56", locale: de)?.value == Decimal(string: "1234.56"))
        #expect(DecimalParser.parse("12,5", locale: de)?.value == Decimal(string: "12.5"))
        #expect(DecimalParser.parse("12,5", locale: us)?.value == Decimal(string: "12.5"))
    }

    @Test func groupingOnlyInputs() {
        #expect(DecimalParser.parse("1,000", locale: us)?.value == 1000)
        #expect(DecimalParser.parse("1.000.000", locale: de)?.value == 1_000_000)
        #expect(DecimalParser.parse("1'234.50", locale: us)?.value == Decimal(string: "1234.50"))
    }

    @Test func negativeAndSymbols() {
        #expect(DecimalParser.parse("-€ 42.10", locale: us)?.value == Decimal(string: "-42.10"))
        #expect(DecimalParser.parse("abc", locale: us) == nil)
        #expect(DecimalParser.parse("", locale: us) == nil)
    }

    @Test func noFloatingPointArtifacts() {
        let a = DecimalParser.parse("0.1", locale: us)!.value
        let b = DecimalParser.parse("0.2", locale: us)!.value
        #expect(a + b == Decimal(string: "0.3"))
        #expect(Money.decimal(from: 0.1 + 0.2, scale: 2) == Decimal(string: "0.3"))
    }

    @Test func amountValidationRules() {
        // "10.123" is ambiguous (grouping in comma-decimal locales); 4 digits is always a fraction.
        #expect(AmountValidation.money("10.1234").value == nil)
        #expect(AmountValidation.money("0").value == nil)
        #expect(AmountValidation.money("0", allowZero: true).value == 0)
        #expect(AmountValidation.money("-5").value == nil)
        #expect(AmountValidation.money("-5", allowNegative: true).value == -5)
        #expect(AmountValidation.money("2000000000000").value == nil)
        #expect(AmountValidation.quantity("0.12345678").value == Decimal(string: "0.12345678"))
        #expect(AmountValidation.percent("5.5").value == Decimal(string: "0.055"))
    }

    @Test func roundingIsHalfUp() {
        #expect(Money.round(Decimal(string: "2.345")!) == Decimal(string: "2.35"))
        #expect(Money.round(Decimal(string: "-2.345")!) == Decimal(string: "-2.35"))
    }

    @Test func currencyConversion() {
        let converter = CurrencyConverter(baseCode: "EUR", rates: ["USD": Decimal(string: "0.9")!, "GBP": Decimal(string: "1.2")!])
        #expect(converter.toBase(100, from: "EUR") == 100)
        #expect(converter.toBase(100, from: "USD") == 90)
        #expect(converter.toBase(100, from: "CHF") == nil)
        #expect(converter.convert(120, from: "GBP", to: "USD") == 160)
    }
}
