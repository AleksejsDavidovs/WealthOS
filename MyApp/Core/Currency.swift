import Foundation

/// Supported ISO 4217 currency codes and display helpers.
nonisolated enum Currencies {
    static let supported: [String] = [
        "EUR", "USD", "GBP", "CHF", "PLN", "CZK", "SEK", "NOK", "DKK", "HUF", "RON", "JPY", "CAD", "AUD"
    ]

    static func name(for code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code) ?? code
    }

    static func symbol(for code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.currencySymbol ?? code
    }
}

/// Converts amounts between currencies using manually entered exchange rates.
/// Rates are expressed as "1 unit of `code` = `rate` units of the base currency".
nonisolated struct CurrencyConverter: Sendable, Equatable {
    let baseCode: String
    let rates: [String: Decimal]

    init(baseCode: String, rates: [String: Decimal] = [:]) {
        self.baseCode = baseCode
        self.rates = rates
    }

    func rate(for code: String) -> Decimal? {
        if code == baseCode { return 1 }
        guard let rate = rates[code], rate > 0 else { return nil }
        return rate
    }

    /// Converts an amount in `code` to the base currency. Returns `nil` when no rate is known.
    func toBase(_ amount: Decimal, from code: String) -> Decimal? {
        guard let rate = rate(for: code) else { return nil }
        return amount * rate
    }

    /// Converts between two arbitrary currencies through the base currency.
    func convert(_ amount: Decimal, from source: String, to target: String) -> Decimal? {
        if source == target { return amount }
        guard let sourceRate = rate(for: source), let targetRate = rate(for: target) else { return nil }
        return amount * sourceRate / targetRate
    }
}

/// Currency-aware formatting. Negative values are rendered with a leading minus sign.
nonisolated enum MoneyFormat {
    private static let cache = NSCache<NSString, NumberFormatter>()

    /// NumberFormatter is thread-safe for formatting; instances are cached per currency/precision.
    private static func formatter(code: String, fractionDigits: Int) -> NumberFormatter {
        let key = "\(Locale.current.identifier)|\(code)|\(fractionDigits)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.roundingMode = .halfUp
        cache.setObject(formatter, forKey: key)
        return formatter
    }

    static func string(_ amount: Decimal, code: String, showSign: Bool = false, fractionDigits: Int = 2) -> String {
        let text = formatter(code: code, fractionDigits: fractionDigits).string(from: NSDecimalNumber(decimal: amount))
            ?? "\(amount) \(code)"
        if showSign && amount > 0 { return "+" + text }
        return text
    }

    /// Short form for chart axes and dense layouts, e.g. "€12.5K", "-€1.2M".
    static func compact(_ amount: Double, code: String) -> String {
        let symbol = Currencies.symbol(for: code)
        let sign = amount < 0 ? "-" : ""
        let magnitude = abs(amount)
        let number = magnitude.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
        return "\(sign)\(symbol)\(number)"
    }

    static func percent(_ value: Decimal, fractionDigits: Int = 1, showSign: Bool = false) -> String {
        var style = Decimal.FormatStyle.Percent().precision(.fractionLength(fractionDigits))
        if showSign { style = style.sign(strategy: .always(includingZero: false)) }
        return value.formatted(style)
    }

    static func quantity(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...8)))
    }
}
