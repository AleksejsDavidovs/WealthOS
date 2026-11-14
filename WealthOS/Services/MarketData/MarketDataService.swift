import Foundation
import SwiftData
import Observation

struct MarketRefreshReport: Equatable {
    var requests = 0
    var updatedQuotes = 0
    var appliedPrices = 0
    var appliedRates = 0
    var skippedFresh = 0
    var errors: [String] = []

    mutating func add(_ error: Error) {
        let message = MarketDataError.from(error).localizedDescription
        if !errors.contains(message) { errors.append(message) }
    }
}

/// Copies quotes into valuation data. Only ever called for holdings / rates the user opted in
/// for (or when they tap "Use"). Earlier prices remain in the PricePoint history; trades,
/// transactions and snapshots are never touched.
enum MarketPriceApplier {
    /// Quote price converted into the holding's currency through the app's own exchange rates.
    static func price(of quote: QuoteValue, in currency: String, converter: CurrencyConverter) -> Decimal? {
        if quote.currency.uppercased() == currency.uppercased() { return quote.price }
        return converter.convert(quote.price, from: quote.currency, to: currency).map { Money.round($0, scale: 8) }
    }

    @discardableResult
    static func apply(_ quote: QuoteValue, to holding: Holding, converter: CurrencyConverter, context: ModelContext) -> Bool {
        guard let price = price(of: quote, in: holding.currencyCode, converter: converter), price > 0 else { return false }
        let asOf = quote.quoteTime ?? quote.fetchedAt
        if holding.priceSource == .market && holding.currentPrice == price && holding.priceUpdatedAt == asOf { return false }
        holding.currentPrice = price
        holding.priceUpdatedAt = asOf
        holding.priceSource = .market
        context.insert(PricePoint(holdingID: holding.id, date: asOf, price: price))
        return true
    }

    /// FX quotes are "1 code = price base"; only valid for the current base currency.
    @discardableResult
    static func applyRate(_ quote: QuoteValue, baseCurrency: String, rates: [CurrencyRate], context: ModelContext) -> Bool {
        guard quote.provider == .frankfurter, quote.currency.uppercased() == baseCurrency.uppercased(), quote.price > 0 else { return false }
        if let existing = rates.first(where: { $0.code == quote.symbol }) {
            if existing.source == .market && existing.rateToBase == quote.price { return false }
            existing.rateToBase = quote.price
            existing.updatedAt = quote.quoteTime ?? quote.fetchedAt
            existing.source = .market
        } else {
            context.insert(CurrencyRate(code: quote.symbol, rateToBase: quote.price,
                                        updatedAt: quote.quoteTime ?? quote.fetchedAt, source: .market))
        }
        return true
    }
}

@Observable
final class MarketDataService {
    private(set) var isRefreshing = false
    private(set) var lastReport: MarketRefreshReport?
    private(set) var keyRevision = 0

    private let client: HTTPClient
    private let secrets: SecretStore
    private let defaults: UserDefaults

    init(client: HTTPClient = URLSessionHTTPClient(), secrets: SecretStore = KeychainStore(), defaults: UserDefaults = .standard) {
        self.client = client
        self.secrets = secrets
        self.defaults = defaults
    }

    // MARK: Settings

    var isEnabled: Bool { defaults.bool(forKey: SettingsKey.marketDataEnabled) }
    var autoApplyRates: Bool { defaults.bool(forKey: SettingsKey.marketAutoApplyFX) }

    var lastSuccessAt: Date? {
        let value = defaults.double(forKey: SettingsKey.marketLastSuccess)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    func hasKey(_ provider: MarketProvider) -> Bool { apiKey(for: provider) != nil }

    func apiKey(for provider: MarketProvider) -> String? {
        _ = keyRevision
        return provider.keychainAccount.flatMap { secrets.read($0) }
    }

    /// Stores (or with nil/empty removes) a provider key in the Keychain. Keys are never logged.
    func setAPIKey(_ key: String?, for provider: MarketProvider) throws {
        guard let account = provider.keychainAccount else { return }
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            try secrets.delete(account)
        } else {
            guard trimmed.range(of: #"^[A-Za-z0-9\-_]{8,128}$"#, options: .regularExpression) != nil else {
                throw MarketDataError.invalidResponse("the key contains unexpected characters")
            }
            try secrets.save(trimmed, account: account)
        }
        keyRevision += 1
    }

    func deleteAllKeys() {
        for provider in MarketProvider.allCases { try? setAPIKey(nil, for: provider) }
    }

    // MARK: Rate limits

    func rateState(_ provider: MarketProvider) -> RateLimitState {
        guard let data = defaults.data(forKey: SettingsKey.marketRateLimitPrefix + provider.rawValue),
              let state = try? JSONDecoder().decode(RateLimitState.self, from: data) else { return RateLimitState() }
        return state
    }

    private func saveRateState(_ state: RateLimitState, _ provider: MarketProvider) {
        defaults.set(try? JSONEncoder().encode(state), forKey: SettingsKey.marketRateLimitPrefix + provider.rawValue)
    }

    func remainingToday(_ provider: MarketProvider, now: Date = .now) -> Int? {
        rateState(provider).remainingToday(provider.rateLimit(hasKey: hasKey(provider)), now: now)
    }

    /// Every request goes through here: enforces the client-side limit before touching the network.
    private func send(_ request: URLRequest, provider: MarketProvider, now: Date, report: inout MarketRefreshReport) async throws -> Data {
        var state = rateState(provider)
        guard state.canRequest(provider.rateLimit(hasKey: hasKey(provider)), now: now) else {
            throw MarketDataError.rateLimited(provider)
        }
        state.record(now: now)
        saveRateState(state, provider)
        report.requests += 1
        let (data, response) = try await client.get(request)
        do {
            try ResponseCheck.check(response, provider: provider)
        } catch MarketDataError.rateLimited(let limited) {
            blockProvider(limited, now: now)
            throw MarketDataError.rateLimited(limited)
        }
        return data
    }

    private func blockProvider(_ provider: MarketProvider, now: Date) {
        var state = rateState(provider)
        state.block(now: now, dailyQuota: provider == .alphaVantage)
        saveRateState(state, provider)
    }

    // MARK: Refresh

    /// Fetches public quotes for linked holdings and needed exchange rates. Only symbols and
    /// currency codes are sent. Cached quotes younger than the provider TTL are reused.
    @discardableResult
    func refresh(context: ModelContext, baseCurrency: String, force: Bool = false, now: Date = .now) async -> MarketRefreshReport {
        var report = MarketRefreshReport()
        guard isEnabled else {
            report.add(MarketDataError.disabled)
            lastReport = report
            return report
        }
        guard !isRefreshing else { return lastReport ?? report }
        isRefreshing = true
        defer { isRefreshing = false }

        let holdings = (try? context.fetch(FetchDescriptor<Holding>())) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        var quotes = Dictionary(((try? context.fetch(FetchDescriptor<MarketQuote>())) ?? []).map { ($0.key, $0) },
                                uniquingKeysWith: { a, _ in a })
        var offline = false
        var succeeded = false

        func isStale(_ key: String, _ provider: MarketProvider) -> Bool {
            guard let quote = quotes[key] else { return true }
            let age = now.timeIntervalSince(quote.fetchedAt)
            return force ? age > 60 : age > provider.cacheTTL
        }

        func store(_ value: QuoteValue) {
            let key = MarketQuote.key(provider: value.provider, symbol: value.symbol, currency: value.currency)
            if let existing = quotes[key] {
                existing.price = value.price
                existing.quoteTime = value.quoteTime
                existing.fetchedAt = value.fetchedAt
            } else {
                let quote = MarketQuote(provider: value.provider, symbol: value.symbol, currencyCode: value.currency,
                                        price: value.price, quoteTime: value.quoteTime, fetchedAt: value.fetchedAt)
                context.insert(quote)
                quotes[key] = quote
            }
            report.updatedQuotes += 1
        }

        // Crypto — one batched request per currency.
        let crypto = holdings.filter { $0.marketProvider == .coinGecko }
        for (currency, group) in Dictionary(grouping: crypto, by: { $0.currencyCode.uppercased() }) {
            let ids = Array(Set(group.map { $0.marketSymbol.lowercased() }))
            let due = ids.filter { isStale(MarketQuote.key(provider: .coinGecko, symbol: $0, currency: currency), .coinGecko) }
            report.skippedFresh += ids.count - due.count
            guard !due.isEmpty, !offline else { continue }
            do {
                let request = try CoinGeckoAPI.priceRequest(ids: due, currency: currency, apiKey: apiKey(for: .coinGecko))
                let data = try await send(request, provider: .coinGecko, now: now, report: &report)
                let parsed = try CoinGeckoAPI.parsePrices(data, ids: due, currency: currency, fetchedAt: now)
                parsed.quotes.forEach(store)
                for id in parsed.missing { report.add(MarketDataError.symbolNotFound("\(id) in \(currency)")) }
                succeeded = true
            } catch {
                if MarketDataError.from(error) == .offline { offline = true }
                report.add(error)
            }
        }

        // ETFs & stocks — one request per symbol, strictly limited (25/day on the free tier).
        let equities = holdings.filter { $0.marketProvider == .alphaVantage }
        var seen = Set<String>()
        let pairs = equities.compactMap { holding -> (String, String)? in
            let symbol = holding.marketSymbol.uppercased()
            let currency = holding.marketQuoteCurrency.uppercased()
            return seen.insert("\(symbol)|\(currency)").inserted ? (symbol, currency) : nil
        }
        let duePairs = pairs.filter { symbol, currency in
            isStale(MarketQuote.key(provider: .alphaVantage, symbol: symbol, currency: currency == "GBX" ? "GBP" : currency), .alphaVantage)
        }
        report.skippedFresh += pairs.count - duePairs.count
        if !duePairs.isEmpty && !offline {
            if let key = apiKey(for: .alphaVantage) {
                for (symbol, currency) in duePairs {
                    do {
                        let request = try AlphaVantageAPI.quoteRequest(symbol: symbol, apiKey: key)
                        let data = try await send(request, provider: .alphaVantage, now: now, report: &report)
                        store(try AlphaVantageAPI.parseQuote(data, symbol: symbol, quoteCurrency: currency, fetchedAt: now))
                        succeeded = true
                    } catch {
                        let mapped = MarketDataError.from(error)
                        report.add(mapped)
                        if case .rateLimited = mapped { blockProvider(.alphaVantage, now: now); break }
                        if mapped == .offline || mapped == .missingAPIKey(.alphaVantage) { offline = offline || mapped == .offline; break }
                    }
                }
            } else {
                report.add(MarketDataError.missingAPIKey(.alphaVantage))
            }
        }

        // Exchange rates needed by accounts, holdings and quotes.
        var codes = Set(accounts.map { $0.currencyCode.uppercased() } + holdings.map { $0.currencyCode.uppercased() })
        for holding in holdings where holding.marketProvider != nil {
            let currency = holding.marketQuoteCurrency.uppercased()
            codes.insert(currency == "GBX" ? "GBP" : currency)
        }
        codes.remove(baseCurrency.uppercased())
        let fxCodes = codes.filter { Currencies.supported.contains($0) }.sorted()
        let dueFX = fxCodes.filter { isStale(MarketQuote.key(provider: .frankfurter, symbol: $0, currency: baseCurrency), .frankfurter) }
        report.skippedFresh += fxCodes.count - dueFX.count
        if !dueFX.isEmpty && !offline {
            do {
                let request = try FrankfurterAPI.latestRequest(base: baseCurrency, symbols: fxCodes)
                let data = try await send(request, provider: .frankfurter, now: now, report: &report)
                try FrankfurterAPI.parseLatest(data, base: baseCurrency, fetchedAt: now).forEach(store)
                succeeded = true
            } catch {
                report.add(error)
            }
        }

        // Apply only where the user opted in. Rates first, so price conversions use them.
        var rates = (try? context.fetch(FetchDescriptor<CurrencyRate>())) ?? []
        if autoApplyRates {
            for code in fxCodes {
                if let quote = quotes[MarketQuote.key(provider: .frankfurter, symbol: code, currency: baseCurrency)],
                   MarketPriceApplier.applyRate(quote.value, baseCurrency: baseCurrency, rates: rates, context: context) {
                    report.appliedRates += 1
                }
            }
            rates = (try? context.fetch(FetchDescriptor<CurrencyRate>())) ?? rates
        }
        let converter = CurrencyConverter.make(base: baseCurrency, rates: rates)
        for holding in holdings where holding.autoApplyMarketPrice {
            guard let quote = quote(for: holding, in: quotes) else { continue }
            if MarketPriceApplier.apply(quote.value, to: holding, converter: converter, context: context) {
                report.appliedPrices += 1
            }
        }

        try? context.save()
        if succeeded { defaults.set(now.timeIntervalSince1970, forKey: SettingsKey.marketLastSuccess) }
        if report.appliedPrices + report.appliedRates > 0 {
            DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
        }
        lastReport = report
        return report
    }

    /// Cached quote for a holding (London GBX quotes are stored in GBP).
    func quote(for holding: Holding, in quotes: [String: MarketQuote]) -> MarketQuote? {
        guard let provider = holding.marketProvider else { return nil }
        var currency = holding.marketQuoteCurrency.uppercased()
        if provider == .alphaVantage && currency == "GBX" { currency = "GBP" }
        return quotes[MarketQuote.key(provider: provider, symbol: holding.marketSymbol, currency: currency)]
    }

    // MARK: Catalog

    /// Minimum query lengths: Alpha Vantage spends 1 of 25 daily requests per search.
    static func minimumQueryLength(for provider: MarketProvider) -> Int { provider == .alphaVantage ? 3 : 2 }

    /// Searches the provider for listings. Results are cached for 24 h so repeating a search
    /// (or switching between Stocks and ETFs, which share one Alpha Vantage search) is free.
    /// Known ISINs are resolved via the built-in index; the provider still supplies listings.
    func searchCatalog(_ rawQuery: String, filter: DiscoveryFilter, defaults cacheDefaults: UserDefaults? = nil,
                       now: Date = .now) async throws -> [CatalogAsset] {
        guard isEnabled else { throw MarketDataError.disabled }
        var query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var isin: String?
        if filter != .crypto && ISIN.isValid(query) {
            guard let shortcut = PopularAssets.query(forISIN: query) else { throw CatalogError.isinNotSupported }
            isin = shortcut.isin
            query = shortcut.query
        }
        let provider = filter.provider
        guard query.count >= Self.minimumQueryLength(for: provider) else { return [] }
        let cache = CatalogSearchCache(defaults: cacheDefaults ?? defaults)

        var results: [CatalogAsset]
        if let cached = cache.results(provider: provider, query: query, now: now) {
            results = cached
        } else {
            var report = MarketRefreshReport()
            switch provider {
            case .coinGecko:
                let data = try await send(try CoinGeckoAPI.searchRequest(query: query, apiKey: apiKey(for: .coinGecko)),
                                          provider: .coinGecko, now: now, report: &report)
                results = try CatalogParsing.coinGecko(data)
            case .alphaVantage:
                guard let key = apiKey(for: .alphaVantage) else { throw MarketDataError.missingAPIKey(.alphaVantage) }
                let data = try await send(try AlphaVantageAPI.searchRequest(query: query, apiKey: key),
                                          provider: .alphaVantage, now: now, report: &report)
                results = try CatalogParsing.alphaVantage(data)
            case .frankfurter:
                results = []
            }
            cache.store(results, provider: provider, query: query, now: now)
        }
        if let isin {
            results = results.map { var asset = $0; if asset.assetClass == .etf { asset.isin = isin }; return asset }
        }
        return results.filter(filter.includes)
    }

    /// Price for one listing in `currency` (crypto) or the listing currency (stocks/ETFs).
    /// Uses the local quote cache first; otherwise one rate-limited request.
    func quote(for asset: CatalogAsset, currency: String, context: ModelContext, now: Date = .now) async throws -> QuoteValue {
        guard isEnabled else { throw MarketDataError.disabled }
        let quoteCurrency = asset.provider == .coinGecko ? currency.uppercased() : (asset.holdingCurrency ?? currency.uppercased())
        let key = MarketQuote.key(provider: asset.provider, symbol: asset.symbol, currency: quoteCurrency)
        let existing = try? context.fetch(FetchDescriptor<MarketQuote>()).first { $0.key == key }
        if let existing, now.timeIntervalSince(existing.fetchedAt) <= asset.provider.cacheTTL {
            return existing.value
        }
        var report = MarketRefreshReport()
        let value: QuoteValue
        switch asset.provider {
        case .coinGecko:
            let data = try await send(try CoinGeckoAPI.priceRequest(ids: [asset.symbol], currency: quoteCurrency,
                                                                    apiKey: apiKey(for: .coinGecko)),
                                      provider: .coinGecko, now: now, report: &report)
            guard let first = try CoinGeckoAPI.parsePrices(data, ids: [asset.symbol], currency: quoteCurrency, fetchedAt: now).quotes.first else {
                throw MarketDataError.symbolNotFound(asset.symbol)
            }
            value = first
        case .alphaVantage:
            guard let apiKey = apiKey(for: .alphaVantage) else { throw MarketDataError.missingAPIKey(.alphaVantage) }
            let data = try await send(try AlphaVantageAPI.quoteRequest(symbol: asset.symbol, apiKey: apiKey),
                                      provider: .alphaVantage, now: now, report: &report)
            value = try AlphaVantageAPI.parseQuote(data, symbol: asset.symbol, quoteCurrency: asset.currency ?? quoteCurrency, fetchedAt: now)
        case .frankfurter:
            throw MarketDataError.symbolNotFound(asset.symbol)
        }
        if let existing {
            existing.price = value.price
            existing.quoteTime = value.quoteTime
            existing.fetchedAt = value.fetchedAt
        } else {
            context.insert(MarketQuote(provider: value.provider, symbol: value.symbol, currencyCode: value.currency,
                                       price: value.price, quoteTime: value.quoteTime, fetchedAt: value.fetchedAt))
        }
        Persistence.flush(context)
        return value
    }

    /// Quote-cache key for a listing (lets views look up cached prices without requests).
    static func quoteKey(for asset: CatalogAsset, currency: String) -> String {
        let quoteCurrency = asset.provider == .coinGecko ? currency.uppercased() : (asset.holdingCurrency ?? currency.uppercased())
        return MarketQuote.key(provider: asset.provider, symbol: asset.symbol, currency: quoteCurrency)
    }

    // MARK: Search

    func search(_ query: String, provider: MarketProvider, now: Date = .now) async throws -> [SymbolMatch] {
        guard isEnabled else { throw MarketDataError.disabled }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var report = MarketRefreshReport()
        switch provider {
        case .coinGecko:
            let data = try await send(try CoinGeckoAPI.searchRequest(query: trimmed, apiKey: apiKey(for: .coinGecko)),
                                      provider: .coinGecko, now: now, report: &report)
            return try CoinGeckoAPI.parseSearch(data)
        case .alphaVantage:
            guard let key = apiKey(for: .alphaVantage) else { throw MarketDataError.missingAPIKey(.alphaVantage) }
            let data = try await send(try AlphaVantageAPI.searchRequest(query: trimmed, apiKey: key),
                                      provider: .alphaVantage, now: now, report: &report)
            return try AlphaVantageAPI.parseSearch(data)
        case .frankfurter:
            return []
        }
    }

    func clearCache(context: ModelContext) {
        for quote in (try? context.fetch(FetchDescriptor<MarketQuote>())) ?? [] { context.delete(quote) }
        try? context.save()
        defaults.removeObject(forKey: SettingsKey.marketLastSuccess)
        lastReport = nil
    }
}
