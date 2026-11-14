import Foundation
import SwiftData
import Testing
@testable import MyApp

@Suite("Purchase calculator")
struct PurchaseCalculatorTests {
    @Test func amountModeDerivesQuantityRoundedDown() throws {
        let result = try PurchaseCalculator.fromAmount(1_000, price: Decimal(string: "128.45")!, fee: 1)
        #expect(result.quantity == Decimal(string: "7.77734527"))
        #expect(result.totalCost <= 1_000)
        #expect(1_000 - result.totalCost < Decimal(string: "0.0001")!)
    }

    @Test func amountModeWithoutFeeIsExactWhenDivisible() throws {
        let result = try PurchaseCalculator.fromAmount(500, price: 125)
        #expect(result.quantity == 4)
        #expect(result.totalCost == 500)
    }

    @Test func quantityModeComputesTotalCost() throws {
        let result = try PurchaseCalculator.fromQuantity(Decimal(string: "0.015")!, price: 68_000, fee: Decimal(string: "1.50")!)
        #expect(result.totalCost == Decimal(string: "1021.50"))
    }

    @Test func invalidInputsAreRejected() {
        #expect(throws: PurchaseError.invalidPrice) { try PurchaseCalculator.fromAmount(100, price: 0) }
        #expect(throws: PurchaseError.feeExceedsAmount) { try PurchaseCalculator.fromAmount(10, price: 5, fee: 10) }
        #expect(throws: PurchaseError.invalidAmount) { try PurchaseCalculator.fromAmount(0, price: 5) }
        #expect(throws: PurchaseError.quantityTooSmall) { try PurchaseCalculator.fromAmount(Decimal(string: "0.00000001")!, price: 1_000_000) }
        #expect(throws: PurchaseError.quantityTooSmall) { try PurchaseCalculator.fromQuantity(0, price: 5) }
    }
}

@Suite("Catalog reference data & parsing")
struct CatalogTests {
    @Test func isinChecksum() {
        #expect(ISIN.isValid("IE00BK5BQT80"))
        #expect(ISIN.isValid("US0378331005"))
        #expect(ISIN.isValid(" ie00b5bmr087 "))
        #expect(!ISIN.isValid("IE00BK5BQT81"))
        #expect(!ISIN.isValid("VWCE"))
        #expect(!ISIN.isValid("1E00BK5BQT80"))
        for shortcut in PopularAssets.etfs { #expect(ISIN.isValid(shortcut.isin)) }
    }

    @Test func exchangesAndCurrencies() {
        #expect(ExchangeDirectory.name(forSymbol: "VWCE.DEX") == "XETRA")
        #expect(ExchangeDirectory.name(forSymbol: "AAPL") == nil)
        #expect(ExchangeDirectory.baseTicker("CSPX.LON") == "CSPX")
        #expect(ExchangeDirectory.baseTicker("BRK.B") == "BRK.B")
        let london = CatalogAsset(provider: .alphaVantage, symbol: "VUSA.LON", name: "Vanguard S&P 500", ticker: "VUSA",
                                  assetClass: .etf, region: "United Kingdom", currency: "GBX", isin: nil)
        #expect(london.holdingCurrency == "GBP")
        #expect(london.exchangeName == "London Stock Exchange")
        let other = CatalogAsset(provider: .alphaVantage, symbol: "XYZ.PAR", name: "Other", ticker: "XYZ.PAR",
                                 assetClass: .stock, region: "Paris", currency: "EUR", isin: nil)
        #expect(other.exchangeName == "Paris")
    }

    @Test func alphaVantageSearchBecomesListings() throws {
        let json = #"""
        {"bestMatches":[
          {"1. symbol":"VWCE.DEX","2. name":"Vanguard FTSE All-World UCITS ETF USD Acc","3. type":"ETF","4. region":"XETRA","8. currency":"EUR"},
          {"1. symbol":"VWRA.LON","2. name":"Vanguard FTSE All-World UCITS ETF USD Acc","3. type":"ETF","4. region":"United Kingdom","8. currency":"USD"},
          {"1. symbol":"TSCO.LON","2. name":"Tesco PLC","3. type":"Equity","4. region":"United Kingdom","8. currency":"GBp"},
          {"1. symbol":"VFIAX","2. name":"Vanguard 500 Index Fund","3. type":"Mutual Fund","4. region":"United States","8. currency":"USD"}
        ]}
        """#
        let assets = try CatalogParsing.alphaVantage(Data(json.utf8))
        #expect(assets.map(\.symbol) == ["VWCE.DEX", "VWRA.LON", "TSCO.LON"])
        #expect(assets[0].assetClass == .etf)
        #expect(assets[0].ticker == "VWCE")
        #expect(assets[0].exchangeName == "XETRA")
        #expect(assets[1].currency == "USD")
        #expect(assets[2].assetClass == .stock)
        #expect(assets[2].currency == "GBX")
        #expect(DiscoveryFilter.etfs.includes(assets[0]) && !DiscoveryFilter.stocks.includes(assets[0]))
    }

    @Test func coinGeckoSearchBecomesListings() throws {
        let json = #"{"coins":[{"id":"solana","name":"Solana","symbol":"SOL","market_cap_rank":7}]}"#
        let assets = try CatalogParsing.coinGecko(Data(json.utf8))
        #expect(assets.first?.symbol == "solana")
        #expect(assets.first?.ticker == "SOL")
        #expect(assets.first?.assetClass == .crypto)
        #expect(assets.first?.currency == nil)
    }

    @Test func popularAssetsContainNoPrices() {
        // Reference data only: identifiers and names, never quotes.
        #expect(PopularAssets.stocks.allSatisfy { $0.currency == "USD" && QuoteValidator.isValidTicker($0.symbol) })
        #expect(PopularAssets.crypto.allSatisfy { QuoteValidator.isValidCoinID($0.symbol) })
    }

    @Test func recentAssetsAreDeduplicatedAndCapped() throws {
        let defaults = UserDefaults(suiteName: "WealthOSTests.recent.\(UUID().uuidString)")!
        let store = RecentAssetsStore(defaults: defaults)
        for asset in PopularAssets.crypto + PopularAssets.stocks { store.record(asset) }
        store.record(PopularAssets.crypto[0])
        let recents = store.load()
        #expect(recents.count == RecentAssetsStore.limit)
        #expect(recents.first?.symbol == "bitcoin")
        #expect(Set(recents.map(\.id)).count == recents.count)
    }
}

@MainActor
@Suite("Catalog search & quotes")
struct CatalogServiceTests {
    let container: ModelContainer
    let client = MockHTTPClient()
    let defaults: UserDefaults
    let service: MarketDataService
    let now = Date(timeIntervalSince1970: 1_794_050_000)
    var context: ModelContext { container.mainContext }

    static let searchJSON = #"{"bestMatches":[{"1. symbol":"VWCE.DEX","2. name":"Vanguard FTSE All-World UCITS ETF USD Acc","3. type":"ETF","4. region":"XETRA","8. currency":"EUR"},{"1. symbol":"VWRL.LON","2. name":"Vanguard FTSE All-World UCITS ETF","3. type":"ETF","4. region":"United Kingdom","8. currency":"GBX"},{"1. symbol":"VWCO","2. name":"Some Equity","3. type":"Equity","4. region":"United States","8. currency":"USD"}]}"#

    init() throws {
        container = try Persistence.makeInMemoryContainer()
        defaults = UserDefaults(suiteName: "WealthOSTests.catalog.\(UUID().uuidString)")!
        defaults.set(true, forKey: SettingsKey.marketDataEnabled)
        let secrets = MemorySecrets()
        try secrets.save("TESTKEY12345", account: "alphavantage")
        service = MarketDataService(client: client, secrets: secrets, defaults: defaults)
        client.handler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch request.url?.host {
            case "www.alphavantage.co":
                if items.contains(where: { $0.name == "function" && $0.value == "SYMBOL_SEARCH" }) { return (200, Self.searchJSON) }
                let symbol = items.first { $0.name == "symbol" }?.value ?? ""
                return (200, Fixtures.alphaVantage(symbol, "128.4500"))
            case "api.coingecko.com":
                if request.url?.path.hasSuffix("/search") == true {
                    return (200, #"{"coins":[{"id":"bitcoin","name":"Bitcoin","symbol":"BTC","market_cap_rank":1}]}"#)
                }
                return (200, Fixtures.coinGecko)
            default: return (404, "{}")
            }
        }
    }

    @Test func searchResultsAreCachedAndSharedBetweenStocksAndETFs() async throws {
        let etfs = try await service.searchCatalog("VWCE", filter: .etfs, now: now)
        #expect(etfs.map(\.symbol) == ["VWCE.DEX", "VWRL.LON"])
        let stocks = try await service.searchCatalog("vwce ", filter: .stocks, now: now.addingTimeInterval(60))
        #expect(stocks.map(\.symbol) == ["VWCO"])
        _ = try await service.searchCatalog("VWCE", filter: .etfs, now: now.addingTimeInterval(3_600))
        #expect(client.count(host: "www.alphavantage.co") == 1)
        // After the 24 h cache window a new request is made.
        _ = try await service.searchCatalog("VWCE", filter: .etfs, now: now.addingTimeInterval(CatalogSearchCache.ttl + 1))
        #expect(client.count(host: "www.alphavantage.co") == 2)
    }

    @Test func knownISINResolvesThroughBuiltInIndex() async throws {
        let results = try await service.searchCatalog("IE00BK5BQT80", filter: .etfs, now: now)
        #expect(results.allSatisfy { $0.isin == "IE00BK5BQT80" })
        let request = try #require(client.requests.first)
        let keywords = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "keywords" }?.value
        #expect(keywords == "VWCE")
    }

    @Test func unknownISINIsReportedWithoutRequest() async {
        await #expect(throws: CatalogError.isinNotSupported) {
            try await service.searchCatalog("US0378331005", filter: .stocks, now: now)
        }
        #expect(client.requests.isEmpty)
    }

    @Test func shortQueriesAndDisabledMarketDataMakeNoRequests() async throws {
        #expect(try await service.searchCatalog("VW", filter: .etfs, now: now).isEmpty)
        #expect(try await service.searchCatalog("b", filter: .crypto, now: now).isEmpty)
        defaults.set(false, forKey: SettingsKey.marketDataEnabled)
        await #expect(throws: MarketDataError.disabled) {
            try await service.searchCatalog("bitcoin", filter: .crypto, now: now)
        }
        #expect(client.requests.isEmpty)
    }

    @Test func cryptoSearchUsesCoinGecko() async throws {
        let results = try await service.searchCatalog("bit", filter: .crypto, now: now)
        #expect(results.first?.symbol == "bitcoin")
        #expect(client.count(host: "api.coingecko.com") == 1)
        #expect(client.count(host: "www.alphavantage.co") == 0)
    }

    @Test func quotesAreCachedLocally() async throws {
        let asset = CatalogAsset(provider: .alphaVantage, symbol: "VWCE.DEX", name: "Vanguard FTSE All-World", ticker: "VWCE",
                                 assetClass: .etf, region: "XETRA", currency: "EUR", isin: nil)
        let first = try await service.quote(for: asset, currency: "EUR", context: context, now: now)
        #expect(first.price == Decimal(string: "128.45"))
        let second = try await service.quote(for: asset, currency: "EUR", context: context, now: now.addingTimeInterval(600))
        #expect(second == first)
        #expect(client.count(host: "www.alphavantage.co") == 1)
        #expect(try context.fetch(FetchDescriptor<MarketQuote>()).contains { $0.key == MarketDataService.quoteKey(for: asset, currency: "EUR") })
    }

    @Test func londonListingQuoteIsInPounds() async throws {
        let asset = CatalogAsset(provider: .alphaVantage, symbol: "VWRL.LON", name: "Vanguard FTSE All-World", ticker: "VWRL",
                                 assetClass: .etf, region: "United Kingdom", currency: "GBX", isin: nil)
        let quote = try await service.quote(for: asset, currency: "EUR", context: context, now: now)
        #expect(quote.currency == "GBP")
        #expect(quote.price == Decimal(string: "1.2845"))
    }
}

@MainActor
@Suite("Recording purchases")
struct AssetPurchaseTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_794_050_000)
    let vwce = CatalogAsset(provider: .alphaVantage, symbol: "VWCE.DEX", name: "Vanguard FTSE All-World UCITS ETF", ticker: "VWCE",
                            assetClass: .etf, region: "XETRA", currency: "EUR", isin: "IE00BK5BQT80")

    init() throws { container = try Persistence.makeInMemoryContainer() }

    private func engine() throws -> FinanceEngine {
        FinanceEngine(accounts: try context.fetch(FetchDescriptor<Account>()),
                      transactions: try context.fetch(FetchDescriptor<TransactionRecord>()),
                      holdings: try context.fetch(FetchDescriptor<Holding>()),
                      trades: try context.fetch(FetchDescriptor<InvestmentTrade>()),
                      converter: .make(base: "EUR", rates: try context.fetch(FetchDescriptor<CurrencyRate>())), now: now)
    }

    private func purchase(_ calculation: PurchaseCalculation, quote: Decimal? = nil, account: UUID? = nil, cash: Decimal? = nil) -> AssetPurchase {
        AssetPurchase(asset: vwce, holdingCurrency: "EUR", calculation: calculation, date: now.addingTimeInterval(-86_400),
                      cashAccountID: account, cashAmount: cash,
                      marketQuote: quote.map { QuoteValue(provider: .alphaVantage, symbol: "VWCE.DEX", currency: "EUR", price: $0,
                                                          quoteTime: now, fetchedAt: now) },
                      autoUpdatePrice: true)
    }

    @Test func purchaseCreatesHoldingAndTracksProfitLocally() throws {
        let calc = try PurchaseCalculator.fromQuantity(2, price: 100, fee: 1)
        let holding = try AssetPurchaseService.record(purchase(calc, quote: 120), converter: CurrencyConverter(baseCode: "EUR"), context: context)
        #expect(holding.marketSymbol == "VWCE.DEX")
        #expect(holding.marketCurrencyCode == "")
        #expect(holding.currentPrice == 120)
        #expect(holding.priceSource == .market)
        #expect(holding.autoApplyMarketPrice)
        #expect(holding.notes.contains("IE00BK5BQT80"))
        let position = try #require(try engine().positions.first)
        #expect(position.position.costBasis == 201)
        #expect(position.marketValue == 240)
        #expect(position.unrealizedProfit == 39)
        // Buying an investment is not an expense.
        #expect(try context.fetchCount(FetchDescriptor<TransactionRecord>()) == 0)
    }

    @Test func purchaseWithoutQuoteKeepsPurchasePriceAsManual() throws {
        let calc = try PurchaseCalculator.fromAmount(1_000, price: 125)
        let holding = try AssetPurchaseService.record(purchase(calc), converter: CurrencyConverter(baseCode: "EUR"), context: context)
        #expect(holding.currentPrice == 125)
        #expect(holding.priceSource == .manual)
        #expect(try engine().positions.first?.position.quantity == 8)
    }

    @Test func repeatPurchasesAddToTheSamePosition() throws {
        let converter = CurrencyConverter(baseCode: "EUR")
        try AssetPurchaseService.record(purchase(try PurchaseCalculator.fromQuantity(2, price: 100), quote: 110), converter: converter, context: context)
        let holding = try AssetPurchaseService.record(purchase(try PurchaseCalculator.fromQuantity(1, price: 130), quote: 140),
                                                      converter: converter, context: context)
        #expect(try context.fetchCount(FetchDescriptor<Holding>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<InvestmentTrade>()) == 2)
        // An existing position's valuation price is not changed by recording another buy.
        #expect(holding.currentPrice == 110)
        let position = try #require(try engine().positions.first)
        #expect(position.position.quantity == 3)
        #expect(position.position.costBasis == 330)
    }

    @Test func fundingAccountIsDebitedWithoutDoubleCounting() throws {
        let broker = Account(name: "Broker cash", kind: .investment, currencyCode: "EUR", openingBalance: 1_000)
        context.insert(broker)
        try context.save()
        let calc = try PurchaseCalculator.fromAmount(500, price: 100)
        try AssetPurchaseService.record(purchase(calc, quote: 100, account: broker.id, cash: 500),
                                        converter: CurrencyConverter(baseCode: "EUR"), context: context)
        let summary = try engine().summary
        #expect(try engine().balance(of: broker) == 500)
        #expect(summary.netWorth == 1_000)
        #expect(try engine().cashFlow(forMonthContaining: now).expenses == 0)
    }

    @Test func londonListingTrackedInPoundsWithPenceQuotes() throws {
        let asset = CatalogAsset(provider: .alphaVantage, symbol: "VUSA.LON", name: "Vanguard S&P 500 UCITS ETF", ticker: "VUSA",
                                 assetClass: .etf, region: "United Kingdom", currency: "GBX", isin: nil)
        let purchase = AssetPurchase(asset: asset, holdingCurrency: "GBP", calculation: try PurchaseCalculator.fromQuantity(10, price: 80),
                                     date: now, marketQuote: QuoteValue(provider: .alphaVantage, symbol: "VUSA.LON", currency: "GBP",
                                                                        price: Decimal(string: "85.12")!, quoteTime: now, fetchedAt: now),
                                     autoUpdatePrice: false)
        let holding = try AssetPurchaseService.record(purchase, converter: CurrencyConverter(baseCode: "EUR"), context: context)
        #expect(holding.currencyCode == "GBP")
        #expect(holding.marketCurrencyCode == "GBX")
        #expect(holding.marketQuoteKey == MarketQuote.key(provider: .alphaVantage, symbol: "VUSA.LON", currency: "GBX"))
        #expect(holding.currentPrice == Decimal(string: "85.12"))
        #expect(!holding.autoApplyMarketPrice)
    }

    @Test func recordedPurchaseSurvivesReopeningDiskStore() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WealthOS-Discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let disk = try Persistence.makePersistentContainer(directory: directory)
            let calc = try PurchaseCalculator.fromAmount(1_000, price: Decimal(string: "128.45")!, fee: 1)
            try AssetPurchaseService.record(purchase(calc, quote: 130), converter: CurrencyConverter(baseCode: "EUR"), context: disk.mainContext)
        }
        let reopened = try Persistence.makePersistentContainer(directory: directory)
        let holding = try #require(try reopened.mainContext.fetch(FetchDescriptor<Holding>()).first)
        #expect(holding.marketSymbol == "VWCE.DEX")
        #expect(holding.currentPrice == 130)
        let trade = try #require(try reopened.mainContext.fetch(FetchDescriptor<InvestmentTrade>()).first)
        #expect(trade.quantity == Decimal(string: "7.77734527"))
        #expect(trade.fee == 1)
    }
}
