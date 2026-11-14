import Foundation

/// Parses user-typed numbers into `Decimal` without going through floating point.
/// Accepts both "1,234.56" and "1.234,56" styles, spaces, currency symbols and
/// apostrophe grouping ("1'234.50").
nonisolated enum DecimalParser {
    struct Parsed: Equatable {
        let value: Decimal
        let fractionDigits: Int
    }

    static func parse(_ raw: String, locale: Locale = .current) -> Parsed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isNegative = trimmed.hasPrefix("-") || trimmed.hasPrefix("\u{2212}") || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")"))
        let filtered = trimmed.filter { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," }
        guard filtered.contains(where: { $0.isNumber }) else { return nil }

        let dotCount = filtered.filter { $0 == "." }.count
        let commaCount = filtered.filter { $0 == "," }.count
        let localeDecimal = Character(locale.decimalSeparator ?? ".")

        var decimalSeparator: Character?
        if dotCount > 0 && commaCount > 0 {
            // Whichever appears last is the decimal separator.
            let lastDot = filtered.lastIndex(of: ".")!
            let lastComma = filtered.lastIndex(of: ",")!
            decimalSeparator = lastDot > lastComma ? "." : ","
            let decimalCount = decimalSeparator == "." ? dotCount : commaCount
            if decimalCount > 1 { return nil }
        } else if dotCount + commaCount > 0 {
            let separator: Character = dotCount > 0 ? "." : ","
            let count = max(dotCount, commaCount)
            if count > 1 {
                decimalSeparator = nil // repeated separator => grouping only
            } else {
                let afterSeparator = filtered.split(separator: separator, omittingEmptySubsequences: false).last ?? ""
                if separator == localeDecimal {
                    decimalSeparator = separator
                } else if afterSeparator.count == 3 {
                    decimalSeparator = nil // "1,000" in a dot-decimal locale is grouping
                } else {
                    decimalSeparator = separator
                }
            }
        }

        var normalized = ""
        var fractionDigits = 0
        var seenDecimal = false
        for character in filtered {
            if character.isNumber {
                normalized.append(character)
                if seenDecimal { fractionDigits += 1 }
            } else if character == decimalSeparator {
                normalized.append(".")
                seenDecimal = true
            }
        }
        if normalized.hasPrefix(".") { normalized = "0" + normalized }
        if normalized.hasSuffix(".") { normalized.removeLast() }
        guard !normalized.isEmpty,
              var value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        if isNegative { value = -value }
        return Parsed(value: value, fractionDigits: fractionDigits)
    }
}

/// Validation rules for monetary and quantity inputs.
nonisolated enum AmountValidation: Equatable {
    case valid(Decimal)
    case empty
    case invalid(String)

    static let maximumAmount: Decimal = 1_000_000_000_000

    var value: Decimal? {
        if case .valid(let value) = self { return value }
        return nil
    }

    var message: String? {
        switch self {
        case .valid, .empty: return nil
        case .invalid(let message): return message
        }
    }

    /// Validates a money amount. `allowZero` and `allowNegative` relax the default
    /// "strictly positive" rule (used for balances and adjustments).
    static func money(_ text: String, allowZero: Bool = false, allowNegative: Bool = false, maxFractionDigits: Int = 2) -> AmountValidation {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .empty }
        guard let parsed = DecimalParser.parse(text) else { return .invalid("Enter a valid number.") }
        if parsed.fractionDigits > maxFractionDigits {
            return .invalid("Use at most \(maxFractionDigits) decimal places.")
        }
        if !allowNegative && parsed.value < 0 { return .invalid("Amount can't be negative.") }
        if !allowZero && parsed.value == 0 { return .invalid("Amount must be greater than zero.") }
        if abs(parsed.value) > maximumAmount { return .invalid("Amount is too large.") }
        return .valid(parsed.value)
    }

    static func quantity(_ text: String) -> AmountValidation {
        money(text, maxFractionDigits: 8)
    }

    static func price(_ text: String, allowZero: Bool = false) -> AmountValidation {
        money(text, allowZero: allowZero, maxFractionDigits: 8)
    }

    /// Percentage typed as e.g. "5.5" meaning 5.5 %. Returns the fraction (0.055).
    static func percent(_ text: String, range: ClosedRange<Decimal> = -100...100) -> AmountValidation {
        guard let parsed = DecimalParser.parse(text) else { return .invalid("Enter a valid percentage.") }
        guard range.contains(parsed.value) else { return .invalid("Value must be between \(range.lowerBound)% and \(range.upperBound)%.") }
        return .valid(parsed.value / 100)
    }
}

nonisolated extension Decimal {
    /// Plain, locale-aware text suitable for pre-filling an input field.
    var inputString: String {
        self.formatted(.number.precision(.fractionLength(0...8)).grouping(.never))
    }
}
