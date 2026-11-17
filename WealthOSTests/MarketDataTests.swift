import Foundation
import SwiftData
import Testing
@testable import WealthOS

// MARK: - Test doubles (no live network is ever used)

final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    var handler: (URLRequest) throws -> (Int, String) = { _ in (404, "{}") }
    private(set) var requests: [URLRequest] = []

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func count(host: String) -> Int { requests.filter { $0.url?.host == host }.count }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    var values: [String: String] = [:]
    func lookup(_ account: String) -> SecretLookup { values[account].map { .found($0) } ?? .notFound }
    func save(_ value: String, account: String) throws { values[account] = value }
    func delete(_ account: String) throws { values[account] = nil }
}

enum Fixtures {
    static let coinGecko = #"{"bitcoin":{"eur":68153.61652486335,"last_updated_at":1794046656},"ethereum":{"eur":2014.41,"last_updated_at":1794046656}}"#
    static func alphaVantage(_ symbol: String, _ price: String) -> String {
        #"{"Global Quote":{"01. symbol":"\#(symbol)","05. price":"\#(price)","07. latest trading day":"2026-11-06"}}"#
    }
    static let alphaVantageLimit = #"{"Information":"We have detected your API key and our standard API rate limit is 25 requests per day."}"#
    static let frankfurter = #"{"amount":1.0,"base":"EUR","date":"2026-11-06","rates":{"USD":1.25,"GBP":0.8}}"#
}

// MARK: - Parsing

@Suite("Market data parsing & validation")
struct MarketParsingTests {
    let now = Date(timeIntervalSince1970: 1_794_050_000)

    @Test func coinGeckoParsesPricesAndTimestamps() throws {
        let result = try CoinGeckoAPI.parsePrices(Data(Fixtures.coinGecko.utf8), ids: ["bitcoin", "ethereum"], currency: "EUR", fetchedAt: now)
        #expect(result.missing.isEmpty)
        let btc = try #require(result.quotes.first { $0.symbol == "bitcoin" })
        #expect(btc.price == Money.round(Decimal(string: "68153.61652486335")!, scale: 8))
        #expect(btc.currency == "EUR")
        #expect(btc.quoteTime == Date(timeIntervalSince1970: 1_794_046_656))
    }

    @Test func coinGeckoReportsMissingCoins() throws {
        let result = try CoinGeckoAPI.parsePrices(Data(Fixtures.coinGecko.utf8), ids: ["bitcoin", "dogecoin"], currency: "EUR", fetchedAt: now)
        #expect(result.missing == ["dogecoin"])
        #expect(result.quotes.count == 1)
    }

    @Test func malformedAndInvalidPricesAreRejected() {
        #expect(throws: MarketDataError.invalidResponse("CoinGecko format")) {
            try CoinGeckoAPI.parsePrices(Data("<html>".utf8), ids: ["bitcoin"], currency: "EUR", fetchedAt: now)
        }
        #expect(throws: MarketDataError.invalidPrice("bitcoin")) {
            try CoinGeckoAPI.parsePrices(Data(#"{"bitcoin":{"eur":0}}"#.utf8), ids: ["bitcoin"], currency: "EUR", fetchedAt: now)
        }
        #expect(throws: MarketDataError.invalidPrice("bitcoin")) {
            try CoinGeckoAPI.parsePrices(Data(#"{"bitcoin":{"eur":-5}}"#.utf8), ids: ["bitcoin"], currency: "EUR", fetchedAt: now)
        }
        #expect(throws: MarketDataError.invalidPrice("X")) {
            try AlphaVantageAPI.parseQuote(Data(Fixtures.alphaVantage("X", "99999999999").utf8), symbol: "X", quoteCurrency: "USD", fetchedAt: now)
        }
    }

    @Test func alphaVantageParsesQuoteAsEndOfDay() throws {
        let quote = try AlphaVantageAPI.parseQuote(Data(Fixtures.alphaVantage("VWCE.DEX", "128.4500").utf8),
                                                   symbol: "VWCE.DEX", quoteCurrency: "EUR", fetchedAt: now)
        #expect(quote.price == Decimal(string: "128.45"))
        #expect(quote.currency == "EUR")
        #expect(quote.quoteTime != nil)
        #expect(MarketProvider.alphaVantage.latency == .endOfDay)
    }

    @Test func londonPenceAreConvertedToPounds() throws {
        let quote = try AlphaVantageAPI.parseQuote(Data(Fixtures.alphaVantage("TSCO.LON", "345.60").utf8),
                                                   symbol: "TSCO.LON", quoteCurrency: "GBX", fetchedAt: now)
        #expect(quote.price == Decimal(string: "3.456"))
        #expect(quote.currency == "GBP")
    }

    @Test func alphaVantageMessagesMapToErrors() {
        #expect(throws: MarketDataError.rateLimited(.alphaVantage)) {
            try AlphaVantageAPI.parseQuote(Data(Fixtures.alphaVantageLimit.utf8), symbol: "IBM", quoteCurrency: "USD", fetchedAt: now)
        }
        #expect(throws: MarketDataError.symbolNotFound("NOPE")) {
            try AlphaVantageAPI.parseQuote(Data(#"{"Global Quote":{}}"#.utf8), symbol: "NOPE", quoteCurrency: "USD", fetchedAt: now)
        }
        #expect(throws: MarketDataError.symbolNotFound("BAD")) {
            try AlphaVantageAPI.parseQuote(Data(#"{"Error Message":"Invalid API call."}"#.utf8), symbol: "BAD", quoteCurrency: "USD", fetchedAt: now)
        }
    }

    @Test func alphaVantageSearchKeepsListingCurrency() throws {
        let json = #"{"bestMatches":[{"1. symbol":"TSCO.LON","2. name":"Tesco PLC","3. type":"Equity","4. region":"United Kingdom","8. currency":"GBX"}]}"#
        let matches = try AlphaVantageAPI.parseSearch(Data(json.utf8))
        #expect(matches.first?.symbol == "TSCO.LON")
        #expect(matches.first?.currency == "GBX")
    }

    @Test func frankfurterRatesAreInvertedToRateToBase() throws {
        let quotes = try FrankfurterAPI.parseLatest(Data(Fixtures.frankfurter.utf8), base: "EUR", fetchedAt: now)
        #expect(quotes.first { $0.symbol == "USD" }?.price == Decimal(string: "0.8"))
        #expect(quotes.first { $0.symbol == "GBP" }?.price == Decimal(string: "1.25"))
        #expect(throws: MarketDataError.invalidResponse("unexpected base")) {
            try FrankfurterAPI.parseLatest(Data(Fixtures.frankfurter.utf8), base: "USD", fetchedAt: now)
        }
    }

    @Test func onlyAllowlistedHTTPSHostsAndValidSymbols() throws {
        #expect(throws: MarketDataError.blockedHost) { try MarketHosts.validate(URL(string: "http://api.coingecko.com/x")) }
        #expect(throws: MarketDataError.blockedHost) { try MarketHosts.validate(URL(string: "https://evil.example.com/")) }
        #expect(throws: MarketDataError.invalidSymbol("../etc")) { try AlphaVantageAPI.quoteRequest(symbol: "../etc", apiKey: "k") }
        #expect(throws: MarketDataError.self) { try CoinGeckoAPI.priceRequest(ids: ["Bit Coin"], currency: "EUR", apiKey: nil) }

        let request = try CoinGeckoAPI.priceRequest(ids: ["bitcoin"], currency: "EUR", apiKey: "demo-key-123")
        #expect(request.url?.scheme == "https")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "x-cg-demo-api-key") == "demo-key-123")
        let names = Set(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        #expect(names == ["ids", "vs_currencies", "include_last_updated_at", "precision"])
    }
}

// MARK: - Rate limits & freshness

@Suite("Rate limiting & cache freshness")
struct RateLimitAndFreshnessTests {
    let now = Date(timeIntervalSince1970: 1_794_050_000)

    @Test func perMinuteWindow() {
        var state = RateLimitState()
        let policy = RateLimitPolicy(perMinute: 2, perDay: nil)
        state.record(now: now)
        state.record(now: now)
        #expect(!state.canRequest(policy, now: now.addingTimeInterval(10)))
        #expect(state.canRequest(policy, now: now.addingTimeInterval(61)))
    }

    @Test func dailyQuotaResetsNextUTCDay() {
        var state = RateLimitState()
        let policy = RateLimitPolicy(perMinute: 100, perDay: 3)
        for i in 0..<3 { state.record(now: now.addingTimeInterval(Double(i) * 70)) }
        #expect(!state.canRequest(policy, now: now.addingTimeInterval(300)))
        #expect(state.remainingToday(policy, now: now.addingTimeInterval(300)) == 0)
        #expect(state.canRequest(policy, now: now.addingTimeInterval(86_400 * 1.5)))
    }

    @Test func providerBlockLastsUntilNextDay() {
        var state = RateLimitState()
        state.block(now: now, dailyQuota: true)
        let policy = RateLimitPolicy(perMinute: 5, perDay: 25)
        #expect(!state.canRequest(policy, now: now.addingTimeInterval(60)))
        #expect(state.canRequest(policy, now: now.addingTimeInterval(86_400 + 60)))
    }

    @Test func freshnessLabels() {
        #expect(QuoteFreshness.evaluate(latency: .nearRealTime, fetchedAt: now, now: now.addingTimeInterval(60)) == .live)
        #expect(QuoteFreshness.evaluate(latency: .nearRealTime, fetchedAt: now, now: now.addingTimeInterval(600)) == .cached)
        #expect(QuoteFreshness.evaluate(latency: .endOfDay, fetchedAt: now, now: now.addingTimeInterval(3_600)) == .delayed)
        #expect(QuoteFreshness.evaluate(latency: .endOfDay, fetchedAt: now, now: now.addingTimeInterval(2 * 86_400)) == .cached)
        #expect(QuoteFreshness.evaluate(latency: .dailyReference, fetchedAt: now, now: now.addingTimeInterval(4 * 86_400)) == .stale)
        #expect(QuoteFreshness.live.title(for: .nearRealTime) == "Near real-time")
    }
}

// MARK: - Service behaviour

@MainActor
@Suite("Market data service")
struct MarketDataServiceTests {
    let container: ModelContainer
    let client = MockHTTPClient()
    let secrets = MemorySecrets()
    let defaults: UserDefaults
    let service: MarketDataService
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_794_050_000)

    init() throws {
        container = try Persistence.makeInMemoryContainer()
        defaults = UserDefaults(suiteName: "WealthOSTests.market.\(UUID().uuidString)")!
        defaults.set(true, forKey: SettingsKey.marketDataEnabled)
        service = MarketDataService(client: client, secrets: secrets, defaults: defaults)
        client.handler = { request in
            switch request.url?.host {
            case "api.coingecko.com": return (200, Fixtures.coinGecko)
            case "api.frankfurter.dev": return (200, Fixtures.frankfurter)
            case "www.alphavantage.co":
                let symbol = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "symbol" }?.value ?? ""
                return (200, Fixtures.alphaVantage(symbol, "130.00"))
            default: return (404, "{}")
            }
        }
    }

    @discardableResult
    private func makeBitcoin(price: Decimal = 60_000, autoApply: Bool = false) -> Holding {
        let holding = Holding(name: "Bitcoin", symbol: "BTC", assetClass: .crypto, currencyCode: "EUR", currentPrice: price,
                              priceUpdatedAt: now.addingTimeInterval(-86_400), marketSymbol: "bitcoin", autoApplyMarketPrice: autoApply)
        context.insert(holding)
        context.insert(InvestmentTrade(holdingID: holding.id, kind: .buy, date: now.addingTimeInterval(-86_400 * 30),
                                       quantity: Decimal(string: "0.5")!, pricePerUnit: 40_000))
        try? context.save()
        return holding
    }

    private func engine() throws -> FinanceEngine {
        FinanceEngine(accounts: try context.fetch(FetchDescriptor<Account>()),
                      transactions: try context.fetch(FetchDescriptor<TransactionRecord>()),
                      holdings: try context.fetch(FetchDescriptor<Holding>()),
                      trades: try context.fetch(FetchDescriptor<InvestmentTrade>()),
                      converter: .make(base: "EUR", rates: try context.fetch(FetchDescriptor<CurrencyRate>())), now: now)
    }

    @Test func disabledMakesNoNetworkRequests() async {
        makeBitcoin()
        defaults.set(false, forKey: SettingsKey.marketDataEnabled)
        let report = await service.refresh(context: context, baseCurrency: "EUR", now: now)
        #expect(client.requests.isEmpty)
        #expect(report.errors == [MarketDataError.disabled.localizedDescription])
    }

    @Test func manualPricesArePreservedWithoutOptIn() async throws {
        let holding = makeBitcoin(price: 60_000, autoApply: false)
        let report = await service.refresh(context: context, baseCurrency: "EUR", now: now)
        #expect(report.updatedQuotes >= 1)
        #expect(holding.currentPrice == 60_000)
        #expect(holding.priceSource == .manual)
        #expect(try context.fetch(FetchDescriptor<MarketQuote>()).contains { $0.symbol == "bitcoin" })
        // Quotes alone never change valuation (no double counting).
        #expect(try engine().summary.holdingsValue == 30_000)
    }

    @Test func optInAppliesPriceKeepsHistoryAndRecalculates() async throws {
        let holding = makeBitcoin(price: 60_000, autoApply: true)
        let tradesBefore = try context.fetchCount(FetchDescriptor<InvestmentTrade>())
        let report = await service.refresh(context: context, baseCurrency: "EUR", now: now)
        let expected = Money.round(Decimal(string: "68153.61652486335")!, scale: 8)
        #expect(report.appliedPrices == 1)
        #expect(holding.currentPrice == expected)
        #expect(holding.priceSource == .market)
        #expect(try context.fetch(FetchDescriptor<PricePoint>()).contains { $0.price == expected })
        #expect(try context.fetchCount(FetchDescriptor<InvestmentTrade>()) == tradesBefore)
        let position = try #require(try engine().positions.first)
        #expect(position.marketValue == expected * Decimal(string: "0.5")!)
        #expect(position.position.costBasis == 20_000)
    }

    @Test func manualEntryAfterMarketUpdateWinsAndStopsAutoUpdates() async throws {
        let holding = makeBitcoin(autoApply: true)
        await service.refresh(context: context, baseCurrency: "EUR", now: now)
        try LedgerService.updatePrice(of: holding, to: 61_000, in: context)
        #expect(holding.priceSource == .manual)
        #expect(holding.autoApplyMarketPrice == false)
        await service.refresh(context: context, baseCurrency: "EUR", force: true, now: now.addingTimeInterval(300))
        #expect(holding.currentPrice == 61_000)
    }

    @Test func cacheTTLPreventsRepeatedRequests() async {
        makeBitcoin()
        await service.refresh(context: context, baseCurrency: "EUR", now: now)
        let first = client.requests.count
        let second = await service.refresh(context: context, baseCurrency: "EUR", now: now.addingTimeInterval(30))
        #expect(first > 0)
        #expect(client.requests.count == first)
        #expect(second.skippedFresh >= 1)
        // After the TTL a new request is made.
        await service.refresh(context: context, baseCurrency: "EUR", now: now.addingTimeInterval(MarketProvider.coinGecko.cacheTTL + 1))
        #expect(client.count(host: "api.coingecko.com") == 2)
    }

    @Test func offlineFallbackKeepsCachedQuotesAndPrices() async throws {
        let holding = makeBitcoin(price: 60_000, autoApply: true)
        await service.refresh(context: context, baseCurrency: "EUR", now: now)
        let cached = try #require(try context.fetch(FetchDescriptor<MarketQuote>()).first { $0.symbol == "bitcoin" })
        let priceAfterFirst = holding.currentPrice

        client.handler = { _ in throw URLError(.notConnectedToInternet) }
        let report = await service.refresh(context: context, baseCurrency: "EUR", force: true, now: now.addingTimeInterval(3_600))
        #expect(report.errors.contains(MarketDataError.offline.localizedDescription))
        #expect(cached.fetchedAt == now)
        #expect(holding.currentPrice == priceAfterFirst)
        #expect(service.lastSuccessAt == now)
    }

    @Test func networkErrorsAndHTTPStatusesAreHandled() async {
        makeBitcoin()
        client.handler = { _ in (429, "{}") }
        let limited = await service.refresh(context: context, baseCurrency: "EUR", now: now)
        #expect(limited.errors.contains(MarketDataError.rateLimited(.coinGecko).localizedDescription))
        #expect(MarketDataError.from(URLError(.timedOut)) == .timeout)
        #expect(MarketDataError.from(URLError(.cannotFindHost)) == .network)
    }

    @Test func alphaVantageRequiresKeyAndStopsAtProviderLimit() async throws {
        for symbol in ["VWCE.DEX", "AAPL"] {
            context.insert(Holding(name: symbol, symbol: symbol, assetClass: .etf, currencyCode: "EUR", currentPrice: 100,
                                   marketSymbol: symbol))
        }
        try context.save()
        let noKey = await service.refresh(context: context, baseCurrency: "EUR", now: now)
        #expect(client.count(host: "www.alphavantage.co") == 0)
        #expect(noKey.errors.contains(MarketDataError.missingAPIKey(.alphaVantage).localizedDescription))

        try service.setAPIKey("TESTKEY12345", for: .alphaVantage)
        client.handler = { _ in (200, Fixtures.alphaVantageLimit) }
        let limited = await service.refresh(context: context, baseCurrency: "EUR", now: now)
        #expect(client.count(host: "www.alphavantage.co") == 1)
        #expect(limited.errors.contains(MarketDataError.rateLimited(.alphaVantage).localizedDescription))
        // Blocked until the next UTC day: no further requests.
        await service.refresh(context: context, baseCurrency: "EUR", force: true, now: now.addingTimeInterval(120))
        #expect(client.count(host: "www.alphavantage.co") == 1)
    }

    @Test func requestsNeverContainPersonalFinancialData() async throws {
        let account = Account(name: "Secret Savings", kind: .savings, currencyCode: "USD", openingBalance: 98_765)
        context.insert(account)
        context.insert(Goal(name: "Private Goal", type: .home, targetAmount: 54_321))
        let holding = makeBitcoin(price: 60_000)
        context.insert(InvestmentTrade(holdingID: holding.id, kind: .buy, date: now.addingTimeInterval(-100),
                                       quantity: Decimal(string: "0.123456")!, pricePerUnit: 50_000))
        try context.save()
        try service.setAPIKey("DEMOKEY12345", for: .coinGecko)
        await service.refresh(context: context, baseCurrency: "EUR", now: now)
        #expect(!client.requests.isEmpty)
        for request in client.requests {
            let text = (request.url?.absoluteString ?? "") + (request.allHTTPHeaderFields?.description ?? "")
            for secret in ["98765", "54321", "0.123456", "Secret", "Private", "60000", "40000"] {
                #expect(!text.contains(secret), "Request leaked \(secret)")
            }
            #expect(request.httpBody == nil)
            #expect(MarketHosts.allowed.contains(request.url?.host ?? ""))
        }
    }

    @Test func exchangeRatesApplyOnlyWithOptInAndStayConsistent() async throws {
        context.insert(Account(name: "USD", kind: .checking, currencyCode: "USD", openingBalance: 100))
        context.insert(CurrencyRate(code: "USD", rateToBase: Decimal(string: "0.9")!))
        try context.save()

        await service.refresh(context: context, baseCurrency: "EUR", now: now)
        var rate = try #require(try context.fetch(FetchDescriptor<CurrencyRate>()).first)
        #expect(rate.rateToBase == Decimal(string: "0.9"))
        #expect(try engine().summary.netWorth == 90)

        defaults.set(true, forKey: SettingsKey.marketAutoApplyFX)
        let report = await service.refresh(context: context, baseCurrency: "EUR", force: true, now: now.addingTimeInterval(120))
        rate = try #require(try context.fetch(FetchDescriptor<CurrencyRate>()).first)
        #expect(report.appliedRates == 1)
        #expect(rate.rateToBase == Decimal(string: "0.8"))
        #expect(rate.source == .market)
        #expect(try engine().summary.netWorth == 80)
    }

    @Test func foreignCurrencyQuotesConvertThroughAppRates() throws {
        let holding = Holding(name: "Apple", symbol: "AAPL", assetClass: .stock, currencyCode: "EUR", currentPrice: 100,
                              marketSymbol: "AAPL", marketCurrencyCode: "USD")
        context.insert(holding)
        let quote = QuoteValue(provider: .alphaVantage, symbol: "AAPL", currency: "USD", price: 200, quoteTime: nil, fetchedAt: now)
        let noRate = CurrencyConverter(baseCode: "EUR")
        #expect(MarketPriceApplier.price(of: quote, in: "EUR", converter: noRate) == nil)
        #expect(!MarketPriceApplier.apply(quote, to: holding, converter: noRate, context: context))
        #expect(holding.currentPrice == 100)

        let converter = CurrencyConverter(baseCode: "EUR", rates: ["USD": Decimal(string: "0.9")!])
        #expect(MarketPriceApplier.apply(quote, to: holding, converter: converter, context: context))
        #expect(holding.currentPrice == 180)
    }

    @Test func apiKeysAreValidatedAndRemovable() throws {
        #expect(throws: MarketDataError.self) { try service.setAPIKey("bad key with spaces", for: .alphaVantage) }
        try service.setAPIKey("  ABCDEFGH1234  ", for: .alphaVantage)
        #expect(service.apiKey(for: .alphaVantage) == "ABCDEFGH1234")
        service.deleteAllKeys()
        #expect(!service.hasKey(.alphaVantage))
    }

    @Test func backupPreservesMarketLinksButNotQuotesOrKeys() throws {
        makeBitcoin(autoApply: true)
        context.insert(MarketQuote(provider: .coinGecko, symbol: "bitcoin", currencyCode: "EUR", price: 1, quoteTime: nil, fetchedAt: now))
        try service.setAPIKey("SECRETKEY999", for: .coinGecko)
        try context.save()
        let payload = try BackupService.makePayload(from: context, baseCurrency: "EUR")
        let json = String(decoding: try BackupPayload.encoder().encode(payload), as: UTF8.self)
        #expect(!json.contains("SECRETKEY999"))
        #expect(payload.holdings.first?.marketSymbol == "bitcoin")
        #expect(payload.holdings.first?.autoApplyMarketPrice == true)

        let target = try Persistence.makeInMemoryContainer()
        try BackupService.restore(payload, into: target.mainContext)
        let restored = try #require(try target.mainContext.fetch(FetchDescriptor<Holding>()).first)
        #expect(restored.marketSymbol == "bitcoin")
        #expect(try target.mainContext.fetchCount(FetchDescriptor<MarketQuote>()) == 0)
    }
}

@Suite("Keychain")
struct KeychainTests {
    @Test func roundTrip() throws {
        let store = KeychainStore(service: "WealthOSTests.\(UUID().uuidString)")
        try store.save("value-1", account: "a")
        #expect(store.read("a") == "value-1")
        try store.save("value-2", account: "a")
        #expect(store.read("a") == "value-2")
        try store.delete("a")
        #expect(store.read("a") == nil)
    }
}
