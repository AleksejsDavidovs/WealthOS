import Foundation

/// A tradable listing returned by a provider (or a known reference asset).
/// `symbol` is the provider identifier: Alpha Vantage symbol ("VWCE.DEX") or CoinGecko id ("bitcoin").
nonisolated struct CatalogAsset: Codable, Hashable, Identifiable, Sendable {
    var provider: MarketProvider
    var symbol: String
    var name: String
    /// Display ticker, e.g. "VWCE" or "BTC".
    var ticker: String
    var assetClass: AssetClass
    /// Provider-reported region / exchange text, e.g. "XETRA" or "United Kingdom".
    var region: String?
    /// Listing currency as reported by the provider (may be "GBX" for London). Nil for crypto.
    var currency: String?
    var isin: String?

    var id: String { "\(provider.rawValue):\(symbol.lowercased())" }

    /// Human-readable exchange: known Alpha Vantage suffixes, otherwise the provider's region text.
    var exchangeName: String? {
        ExchangeDirectory.name(forSymbol: symbol) ?? region
    }

    /// Currency a holding of this listing is valued in (GBX listings are tracked in GBP).
    var holdingCurrency: String? {
        guard let currency = currency?.uppercased() else { return nil }
        return currency == "GBX" ? "GBP" : currency
    }
}

nonisolated enum ExchangeDirectory {
    /// Only suffixes documented by Alpha Vantage. Other listings show the provider's region.
    private static let suffixes: [String: String] = [
        "DEX": "XETRA", "LON": "London Stock Exchange", "TRT": "Toronto Stock Exchange",
        "BSE": "BSE India", "SHH": "Shanghai Stock Exchange", "SHZ": "Shenzhen Stock Exchange",
    ]

    static func name(forSymbol symbol: String) -> String? {
        guard let dot = symbol.lastIndex(of: ".") else { return nil }
        return suffixes[String(symbol[symbol.index(after: dot)...]).uppercased()]
    }

    /// Ticker without the exchange suffix ("VWCE.DEX" → "VWCE").
    static func baseTicker(_ symbol: String) -> String {
        guard let dot = symbol.lastIndex(of: "."), name(forSymbol: symbol) != nil else { return symbol.uppercased() }
        return String(symbol[..<dot]).uppercased()
    }
}

nonisolated enum DiscoveryFilter: String, CaseIterable, Identifiable, Sendable {
    case stocks, etfs, crypto
    var id: String { rawValue }

    var title: String {
        switch self {
        case .stocks: "Stocks"
        case .etfs: "ETFs"
        case .crypto: "Crypto"
        }
    }

    var provider: MarketProvider { self == .crypto ? .coinGecko : .alphaVantage }

    func includes(_ asset: CatalogAsset) -> Bool {
        switch self {
        case .stocks: asset.assetClass == .stock
        case .etfs: asset.assetClass == .etf
        case .crypto: asset.assetClass == .crypto
        }
    }
}

nonisolated enum CatalogError: LocalizedError, Equatable {
    case isinNotSupported

    var errorDescription: String? {
        switch self {
        case .isinNotSupported:
            "Alpha Vantage can't search by ISIN. This ISIN isn't in WealthOS's built-in list — search by fund name or ticker instead."
        }
    }
}

// MARK: - ISIN

nonisolated enum ISIN {
    /// ISO 6166: 2-letter country, 9 alphanumerics, 1 check digit (Luhn over digit expansion).
    static func isValid(_ text: String) -> Bool {
        let isin = text.uppercased().trimmingCharacters(in: .whitespaces)
        guard isin.range(of: #"^[A-Z]{2}[A-Z0-9]{9}[0-9]$"#, options: .regularExpression) != nil else { return false }
        var digits = ""
        for character in isin {
            if let value = character.wholeNumberValue {
                digits.append(String(value))
            } else if let ascii = character.asciiValue {
                digits.append(String(Int(ascii) - 55)) // A=10 … Z=35
            }
        }
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            var value = character.wholeNumberValue ?? 0
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }
}

// MARK: - Popular assets

/// Well-known reference assets. These contain only stable identifiers — never prices.
/// UCITS ETFs are search shortcuts: their listings (exchange, currency) always come from
/// the provider so nothing is assumed about where they trade.
nonisolated enum PopularAssets {
    struct ETFShortcut: Identifiable, Hashable, Sendable {
        let name: String
        let isin: String
        let query: String
        var id: String { isin }
    }

    static let stocks: [CatalogAsset] = [
        ("AAPL", "Apple Inc."), ("MSFT", "Microsoft Corporation"), ("NVDA", "NVIDIA Corporation"),
        ("AMZN", "Amazon.com, Inc."), ("GOOGL", "Alphabet Inc. (Class A)"), ("META", "Meta Platforms, Inc."),
        ("TSLA", "Tesla, Inc."),
    ].map {
        CatalogAsset(provider: .alphaVantage, symbol: $0.0, name: $0.1, ticker: $0.0, assetClass: .stock,
                     region: "United States", currency: "USD", isin: nil)
    }

    static let crypto: [CatalogAsset] = [
        ("bitcoin", "Bitcoin", "BTC"), ("ethereum", "Ethereum", "ETH"), ("solana", "Solana", "SOL"),
        ("ripple", "XRP", "XRP"), ("cardano", "Cardano", "ADA"), ("dogecoin", "Dogecoin", "DOGE"),
    ].map {
        CatalogAsset(provider: .coinGecko, symbol: $0.0, name: $0.1, ticker: $0.2, assetClass: .crypto,
                     region: nil, currency: nil, isin: nil)
    }

    static let etfs: [ETFShortcut] = [
        ETFShortcut(name: "Vanguard FTSE All-World UCITS ETF (Acc)", isin: "IE00BK5BQT80", query: "VWCE"),
        ETFShortcut(name: "iShares Core MSCI World UCITS ETF (Acc)", isin: "IE00B4L5Y983", query: "iShares Core MSCI World"),
        ETFShortcut(name: "iShares Core S&P 500 UCITS ETF (Acc)", isin: "IE00B5BMR087", query: "CSPX"),
        ETFShortcut(name: "iShares Core MSCI EM IMI UCITS ETF (Acc)", isin: "IE00BKM4GZ66", query: "EIMI"),
        ETFShortcut(name: "Vanguard S&P 500 UCITS ETF (Dist)", isin: "IE00B3XXRP09", query: "VUSA"),
    ]

    /// Maps a known ISIN to a provider search query (the provider has no ISIN search).
    static func query(forISIN isin: String) -> ETFShortcut? {
        etfs.first { $0.isin == isin.uppercased() }
    }
}

// MARK: - Recent selections & search cache (local only)

nonisolated struct RecentAssetsStore {
    static let key = "discoveryRecentAssets"
    static let limit = 12
    let defaults: UserDefaults

    func load() -> [CatalogAsset] {
        guard let data = defaults.data(forKey: Self.key),
              let assets = try? JSONDecoder().decode([CatalogAsset].self, from: data) else { return [] }
        return assets
    }

    func record(_ asset: CatalogAsset) {
        var assets = load().filter { $0.id != asset.id }
        assets.insert(asset, at: 0)
        defaults.set(try? JSONEncoder().encode(Array(assets.prefix(Self.limit))), forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

/// Persisted provider search results so repeated searches don't spend free-tier requests.
nonisolated struct CatalogSearchCache {
    static let key = "discoverySearchCache"
    static let ttl: TimeInterval = 24 * 3_600
    static let limit = 40

    struct Entry: Codable {
        let date: Date
        let results: [CatalogAsset]
    }

    let defaults: UserDefaults

    static func cacheKey(provider: MarketProvider, query: String) -> String {
        "\(provider.rawValue):\(query.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    private func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    func results(provider: MarketProvider, query: String, now: Date) -> [CatalogAsset]? {
        guard let entry = load()[Self.cacheKey(provider: provider, query: query)],
              now.timeIntervalSince(entry.date) < Self.ttl else { return nil }
        return entry.results
    }

    func store(_ results: [CatalogAsset], provider: MarketProvider, query: String, now: Date) {
        var entries = load().filter { now.timeIntervalSince($0.value.date) < Self.ttl }
        entries[Self.cacheKey(provider: provider, query: query)] = Entry(date: now, results: results)
        if entries.count > Self.limit {
            for key in entries.sorted(by: { $0.value.date < $1.value.date }).prefix(entries.count - Self.limit).map(\.key) {
                entries[key] = nil
            }
        }
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

// MARK: - Provider parsing into catalog listings

nonisolated enum CatalogParsing {
    /// Alpha Vantage SYMBOL_SEARCH → listings with type, region and currency.
    static func alphaVantage(_ data: Data) throws -> [CatalogAsset] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MarketDataError.invalidResponse("Alpha Vantage search format")
        }
        try AlphaVantageAPI.checkMessages(object, symbol: "")
        let matches = object["bestMatches"] as? [[String: String]] ?? []
        return matches.prefix(20).compactMap { item in
            guard let symbol = item["1. symbol"], QuoteValidator.isValidTicker(symbol),
                  let name = item["2. name"], !name.isEmpty else { return nil }
            let type = (item["3. type"] ?? "").lowercased()
            let assetClass: AssetClass
            if type.contains("etf") { assetClass = .etf }
            else if type.contains("equity") { assetClass = .stock }
            else { return nil } // mutual funds, warrants etc. aren't offered in the catalog
            let currency = item["8. currency"].flatMap { $0.isEmpty ? nil : $0 }
            return CatalogAsset(provider: .alphaVantage, symbol: symbol, name: name,
                                ticker: ExchangeDirectory.baseTicker(symbol), assetClass: assetClass,
                                region: item["4. region"], currency: currency == "GBp" ? "GBX" : currency, isin: nil)
        }
    }

    /// CoinGecko /search → coins (ids are the provider symbols).
    static func coinGecko(_ data: Data) throws -> [CatalogAsset] {
        try CoinGeckoAPI.parseSearch(data).map { match in
            CatalogAsset(provider: .coinGecko, symbol: match.symbol, name: match.name,
                         ticker: match.detail.components(separatedBy: " · ").first ?? match.symbol.uppercased(),
                         assetClass: .crypto, region: nil, currency: nil, isin: nil)
        }
    }
}

// MARK: - Purchase maths

nonisolated enum PurchaseError: LocalizedError, Equatable {
    case invalidPrice, invalidAmount, feeExceedsAmount, quantityTooSmall

    var errorDescription: String? {
        switch self {
        case .invalidPrice: "Enter the price per unit you paid."
        case .invalidAmount: "Enter the amount you invested."
        case .feeExceedsAmount: "The fee can't be larger than the amount invested."
        case .quantityTooSmall: "The resulting quantity is too small to record."
        }
    }
}

nonisolated struct PurchaseCalculation: Equatable, Sendable {
    let quantity: Decimal
    let pricePerUnit: Decimal
    let fee: Decimal
    /// quantity × price + fee — what the position's cost basis increases by.
    var totalCost: Decimal { quantity * pricePerUnit + fee }
}

/// Converts the two entry modes into a trade. All Decimal; quantities are rounded *down*
/// to 8 places so the recorded cost never exceeds the amount actually invested.
nonisolated enum PurchaseCalculator {
    static let quantityScale = 8

    static func fromAmount(_ amount: Decimal, price: Decimal, fee: Decimal = 0) throws -> PurchaseCalculation {
        guard price > 0 else { throw PurchaseError.invalidPrice }
        guard amount > 0 else { throw PurchaseError.invalidAmount }
        guard fee >= 0, fee < amount else { throw PurchaseError.feeExceedsAmount }
        let quantity = Money.round((amount - fee) / price, scale: quantityScale, mode: .down)
        guard quantity > 0 else { throw PurchaseError.quantityTooSmall }
        return PurchaseCalculation(quantity: quantity, pricePerUnit: price, fee: fee)
    }

    static func fromQuantity(_ quantity: Decimal, price: Decimal, fee: Decimal = 0) throws -> PurchaseCalculation {
        guard price > 0 else { throw PurchaseError.invalidPrice }
        guard quantity > 0 else { throw PurchaseError.quantityTooSmall }
        guard fee >= 0 else { throw PurchaseError.feeExceedsAmount }
        return PurchaseCalculation(quantity: quantity, pricePerUnit: price, fee: fee)
    }
}
