import Foundation
import Security

/// Whether a valuation price was typed by the user or copied from a market quote.
nonisolated enum PriceSource: String, Codable, Sendable {
    case manual, market
}

/// How current a provider's data is, as documented by the provider itself.
nonisolated enum QuoteLatency: String, Codable, Sendable {
    /// CoinGecko: prices cached by the provider for roughly 60 seconds.
    case nearRealTime
    /// Alpha Vantage free tier: quote endpoint updated at the end of each trading day.
    case endOfDay
    /// Frankfurter: central-bank reference rates published once per working day.
    case dailyReference

    var title: String {
        switch self {
        case .nearRealTime: "Near real-time"
        case .endOfDay: "End of day"
        case .dailyReference: "Daily reference rate"
        }
    }
}

nonisolated enum MarketProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case coinGecko, alphaVantage, frankfurter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .coinGecko: "CoinGecko"
        case .alphaVantage: "Alpha Vantage"
        case .frankfurter: "Frankfurter (ECB)"
        }
    }

    var coverage: String {
        switch self {
        case .coinGecko: "Cryptocurrencies"
        case .alphaVantage: "ETFs & stocks"
        case .frankfurter: "Exchange rates"
        }
    }

    var latency: QuoteLatency {
        switch self {
        case .coinGecko: .nearRealTime
        case .alphaVantage: .endOfDay
        case .frankfurter: .dailyReference
        }
    }

    /// A cached quote younger than this is reused instead of requesting again.
    var cacheTTL: TimeInterval {
        switch self {
        case .coinGecko: 120
        case .alphaVantage: 6 * 3_600
        case .frankfurter: 6 * 3_600
        }
    }

    var requiresAPIKey: Bool { self == .alphaVantage }
    var supportsOptionalKey: Bool { self == .coinGecko }

    /// Keychain account name for this provider's API key.
    var keychainAccount: String? {
        switch self {
        case .coinGecko: "coingecko.demo"
        case .alphaVantage: "alphavantage"
        case .frankfurter: nil
        }
    }

    /// Conservative client-side limits, well inside each provider's published free tier.
    func rateLimit(hasKey: Bool) -> RateLimitPolicy {
        switch self {
        case .coinGecko: RateLimitPolicy(perMinute: hasKey ? 30 : 5, perDay: nil)
        case .alphaVantage: RateLimitPolicy(perMinute: 5, perDay: 25)
        case .frankfurter: RateLimitPolicy(perMinute: 10, perDay: nil)
        }
    }

    var signupURL: URL? {
        switch self {
        case .coinGecko: URL(string: "https://www.coingecko.com/en/api/pricing")
        case .alphaVantage: URL(string: "https://www.alphavantage.co/support/#api-key")
        case .frankfurter: URL(string: "https://frankfurter.dev")
        }
    }
}

/// A validated quote from a provider, independent of persistence.
nonisolated struct QuoteValue: Sendable, Equatable {
    let provider: MarketProvider
    let symbol: String
    /// Currency of `price`. For FX quotes this is the base currency.
    let currency: String
    let price: Decimal
    let quoteTime: Date?
    let fetchedAt: Date
}

nonisolated struct SymbolMatch: Identifiable, Sendable, Equatable {
    var id: String { symbol }
    let symbol: String
    let name: String
    let detail: String
    /// Quote currency when the provider reports it (Alpha Vantage search does; may be "GBX").
    let currency: String?
}

/// Display state of a quote: provider latency combined with how long ago it was fetched.
nonisolated enum QuoteFreshness: String, Sendable, Equatable {
    case live, delayed, cached, stale

    static func evaluate(latency: QuoteLatency, fetchedAt: Date, now: Date) -> QuoteFreshness {
        let age = now.timeIntervalSince(fetchedAt)
        if age > 3 * 86_400 { return .stale }
        switch latency {
        case .nearRealTime:
            return age <= 5 * 60 ? .live : .cached
        case .endOfDay, .dailyReference:
            return age <= 86_400 ? .delayed : .cached
        }
    }

    func title(for latency: QuoteLatency) -> String {
        switch self {
        case .live: latency.title
        case .delayed: latency.title
        case .cached: "Cached"
        case .stale: "Cached · outdated"
        }
    }

    var symbol: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .delayed: "clock"
        case .cached: "tray.full"
        case .stale: "exclamationmark.clock"
        }
    }
}

nonisolated enum MarketDataError: LocalizedError, Equatable, Sendable {
    case disabled
    case offline
    case timeout
    case blockedHost
    case invalidSymbol(String)
    case missingAPIKey(MarketProvider)
    case rateLimited(MarketProvider)
    case http(Int)
    case invalidResponse(String)
    case symbolNotFound(String)
    case invalidPrice(String)
    case network

    var errorDescription: String? {
        switch self {
        case .disabled: "Online market prices are turned off."
        case .offline: "You're offline. Showing cached prices."
        case .timeout: "The market data service didn't respond in time."
        case .blockedHost: "Blocked a request to an unapproved server."
        case .invalidSymbol(let symbol): "“\(symbol)” isn't a valid symbol."
        case .missingAPIKey(let provider): "\(provider.displayName) needs a free API key. Add it in Settings → Market Data."
        case .rateLimited(let provider): "\(provider.displayName) request limit reached. Cached prices are kept; try again later."
        case .http(let code): "The market data service returned an error (HTTP \(code))."
        case .invalidResponse(let detail): "Unexpected response from the market data service (\(detail))."
        case .symbolNotFound(let symbol): "No quote found for “\(symbol)”."
        case .invalidPrice(let symbol): "Rejected an invalid price for “\(symbol)”."
        case .network: "Couldn't reach the market data service."
        }
    }

    static func from(_ error: Error) -> MarketDataError {
        if let error = error as? MarketDataError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            case .timedOut: return .timeout
            default: return .network
            }
        }
        return .network
    }
}

/// Bounds and normalization applied to every price before it is stored.
nonisolated enum QuoteValidator {
    static let maximumPrice: Decimal = 1_000_000_000

    static func normalized(_ price: Decimal, symbol: String) throws -> Decimal {
        guard price > 0, price < maximumPrice else { throw MarketDataError.invalidPrice(symbol) }
        return Money.round(price, scale: 8)
    }

    /// Ticker symbols: letters, digits and . - _ ^ = : (e.g. "VWCE.DEX", "BRK-B").
    static func isValidTicker(_ symbol: String) -> Bool {
        symbol.range(of: #"^[A-Za-z0-9.\-_^=:]{1,32}$"#, options: .regularExpression) != nil
    }

    /// CoinGecko ids: lowercase letters, digits and dashes (e.g. "bitcoin", "usd-coin").
    static func isValidCoinID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9\-]{1,80}$"#, options: .regularExpression) != nil
    }

    static func isValidCurrency(_ code: String) -> Bool {
        code.range(of: #"^[A-Za-z]{3}$"#, options: .regularExpression) != nil
    }
}

// MARK: - Rate limiting

nonisolated struct RateLimitPolicy: Sendable, Equatable {
    let perMinute: Int
    let perDay: Int?
}

/// Sliding one-minute window plus a per-UTC-day counter. Persisted between launches.
nonisolated struct RateLimitState: Codable, Equatable, Sendable {
    var recent: [Date] = []
    var day: String = ""
    var dayCount: Int = 0
    /// Set when the provider itself reports its limit was hit.
    var blockedUntil: Date?

    static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    func canRequest(_ policy: RateLimitPolicy, now: Date) -> Bool {
        if let blockedUntil, now < blockedUntil { return false }
        let windowCount = recent.filter { now.timeIntervalSince($0) < 60 }.count
        if windowCount >= policy.perMinute { return false }
        if let perDay = policy.perDay, day == Self.dayKey(now), dayCount >= perDay { return false }
        return true
    }

    func remainingToday(_ policy: RateLimitPolicy, now: Date) -> Int? {
        guard let perDay = policy.perDay else { return nil }
        return day == Self.dayKey(now) ? max(0, perDay - dayCount) : perDay
    }

    mutating func record(now: Date) {
        recent = recent.filter { now.timeIntervalSince($0) < 60 } + [now]
        let key = Self.dayKey(now)
        if day != key { day = key; dayCount = 0 }
        dayCount += 1
    }

    /// Provider reported exhaustion: back off until the next UTC day (daily quota) or an hour.
    mutating func block(now: Date, dailyQuota: Bool) {
        if dailyQuota {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let start = calendar.startOfDay(for: now)
            blockedUntil = calendar.date(byAdding: .day, value: 1, to: start)
        } else {
            blockedUntil = now.addingTimeInterval(3_600)
        }
    }
}

// MARK: - Secrets

nonisolated protocol SecretStore: Sendable {
    func read(_ account: String) -> String?
    func save(_ value: String, account: String) throws
    func delete(_ account: String) throws
}

nonisolated enum KeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? { "The API key couldn't be saved to the Keychain." }
}

/// API keys live only in the iOS Keychain: this device only, available after first unlock,
/// never synced to iCloud and never included in WealthOS backups.
nonisolated struct KeychainStore: SecretStore {
    var service = "WealthOS.MarketData"

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add.merge(update) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
