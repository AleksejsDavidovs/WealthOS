import Foundation

/// Decimal helpers used for every monetary computation in the app.
/// Money is never stored or summed as floating point; `Double` is only used
/// for chart rendering and statistical (Monte Carlo) estimates.
nonisolated enum Money {
    /// Rounds a decimal to `scale` fraction digits (half-up by default).
    static func round(_ value: Decimal, scale: Int = 2, mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, mode)
        return result
    }

    /// Converts a `Double` to `Decimal` through its textual representation to
    /// avoid binary floating-point artifacts (e.g. 0.1 -> 0.1000000000000000055).
    static func decimal(from double: Double, scale: Int = 2) -> Decimal {
        guard double.isFinite else { return 0 }
        let text = String(format: "%.\(scale)f", double)
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    /// Number of significant fraction digits in a decimal value.
    static func fractionDigits(of value: Decimal) -> Int {
        let exponent = value.exponent
        return exponent < 0 ? Int(-exponent) : 0
    }
}

nonisolated extension Decimal {
    /// Value rounded to cents.
    var roundedToCents: Decimal { Money.round(self, scale: 2) }

    /// Lossy conversion for charts and statistics only.
    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }

    var isPositive: Bool { self > 0 }
}
