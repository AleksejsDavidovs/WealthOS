import Foundation
import SwiftData
import Testing
@testable import WealthOS

// MARK: - Test doubles (no live network is ever used)

/// Routes by endpoint and applies the real transport's validation, so a test fails if the
/// code under test ever builds a request the app would refuse to send.
final class T212MockHTTP: HTTPClient, @unchecked Sendable {
    typealias Reply = (status: Int, body: String, headers: [String: String])
    /// `@Sendable`: the client calls the transport off the main actor, so a closure written in
    /// a `@MainActor` suite must not inherit that isolation (Swift 6 traps at runtime).
    var handler: @Sendable (Trading212Endpoint) throws -> Reply = { endpoint in
        switch endpoint {
        case .accountSummary: (200, T212Fixtures.summary, [:])
        case .positions: (200, T212Fixtures.positions, [:])
        case .instruments: (200, T212Fixtures.instruments, [:])
        }
    }
    /// Awaited before replying, to hold a request "in flight".
    var gate: (@Sendable () async -> Void)?
    private(set) var requests: [URLRequest] = []

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Trading212Transport.validate(request)
        requests.append(request)
        if let gate { await gate() }
        let path = request.url?.path ?? ""
        guard let endpoint = Trading212Endpoint.allCases.first(where: { path.hasSuffix($0.path) }) else {
            throw Trading212Error.blockedRequest
        }
        let reply = try handler(endpoint)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }

    func count(_ endpoint: Trading212Endpoint) -> Int {
        requests.filter { $0.url?.path.hasSuffix(endpoint.path) == true }.count
    }
}

nonisolated final class SleepLog: @unchecked Sendable {
    var values: [TimeInterval] = []
}

nonisolated final class CallCounter: @unchecked Sendable {
    var value = 0
    func next() -> Int { value += 1; return value }
}

/// Shapes follow https://docs.trading212.com/api (account summary, positions, instruments).
nonisolated enum T212Fixtures {
    /// `totalValue` is deliberately absurd: WealthOS must never add the provider's own total.
    static let summary = #"{"cash":{"availableToTrade":250.50,"inPies":10,"reservedForOrders":4.5},"currency":"EUR","id":12345,"investments":{"currentValue":1500.118,"realizedProfitLoss":12.5,"totalCost":1262,"unrealizedProfitLoss":238.118},"totalValue":999999}"#

    static let positions = #"[{"averagePricePaid":150.1,"createdAt":"2025-03-01T10:00:00.000Z","currentPrice":180.5,"instrument":{"currency":"USD","isin":"US0378331005","name":"Apple","ticker":"AAPL_US_EQ"},"quantity":2.5,"quantityAvailableForTrading":2.5,"quantityInPies":0,"walletImpact":{"currency":"EUR","currentValue":415.75,"fxImpact":-3.2,"totalCost":350,"unrealizedProfitLoss":65.75}},{"averagePricePaid":80,"createdAt":"2025-04-01T10:00:00Z","currentPrice":95.12,"instrument":{"currency":"EUR","isin":"IE00BK5BQT80","name":"Vanguard FTSE All-World","ticker":"VWCEd_EQ"},"quantity":11.4,"quantityAvailableForTrading":11.4,"quantityInPies":0,"walletImpact":{"currency":"EUR","currentValue":1084.368,"fxImpact":null,"totalCost":912,"unrealizedProfitLoss":172.368}}]"#

    /// Only Apple remains; VWCE was sold.
    static let positionsAfterSale = #"[{"averagePricePaid":150.1,"createdAt":"2025-03-01T10:00:00.000Z","currentPrice":190,"instrument":{"currency":"USD","isin":"US0378331005","name":"Apple","ticker":"AAPL_US_EQ"},"quantity":3,"quantityAvailableForTrading":3,"quantityInPies":0,"walletImpact":{"currency":"EUR","currentValue":525,"fxImpact":1,"totalCost":420,"unrealizedProfitLoss":105}}]"#

    static let instruments = #"[{"addedOn":"2018-01-01T00:00:00Z","currencyCode":"USD","extendedHours":true,"isin":"US0378331005","maxOpenQuantity":1000,"name":"Apple","shortName":"AAPL","ticker":"AAPL_US_EQ","type":"STOCK","workingScheduleId":1},{"addedOn":"2019-01-01T00:00:00Z","currencyCode":"EUR","extendedHours":false,"isin":"IE00BK5BQT80","maxOpenQuantity":1000,"name":"Vanguard FTSE All-World","shortName":"VWCE","ticker":"VWCEd_EQ","type":"ETF","workingScheduleId":2}]"#

    static func decode<T: Decodable>(_ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
}

// MARK: - Client and transport

@Suite("Trading 212 client")
struct Trading212ClientTests {
    let credentials = Trading212Credentials(apiKey: "KEY-abc", apiSecret: "SECRET-xyz")

    func client(_ http: T212MockHTTP, sleeps: SleepLog = SleepLog()) -> Trading212Client {
        var client = Trading212Client(environment: .live, credentials: credentials, http: http)
        client.sleep = { sleeps.values.append($0) }
        client.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        return client
    }

    @Test func usesDocumentedBasicAuthAndReadOnlyGET() async throws {
        let http = T212MockHTTP()
        _ = try await client(http).accountSummary()
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.url?.absoluteString == "https://live.trading212.com/api/v0/equity/account/summary")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("KEY-abc:SECRET-xyz".utf8).base64EncodedString())
    }

    @Test func demoEnvironmentUsesDemoHost() {
        let client = Trading212Client(environment: .demo, credentials: credentials, http: T212MockHTTP())
        #expect(client.request(for: .positions).url?.absoluteString == "https://demo.trading212.com/api/v0/equity/positions")
    }

    @Test func credentialsAreTrimmed() {
        let trimmed = Trading212Credentials(apiKey: "  key \n", apiSecret: "\tsecret ")
        #expect(trimmed.apiKey == "key" && trimmed.apiSecret == "secret")
        #expect(!Trading212Credentials(apiKey: "key", apiSecret: " ").isComplete)
    }

    @Test func onlyThreeReadOnlyEndpointsExist() {
        #expect(Set(Trading212Endpoint.allCases.map(\.path)) ==
                ["/equity/account/summary", "/equity/positions", "/equity/metadata/instruments"])
        for endpoint in Trading212Endpoint.allCases {
            #expect(!endpoint.path.contains("orders") && !endpoint.path.contains("pies"))
        }
    }

    @Test func transportBlocksTradingAndForeignRequests() throws {
        func request(_ url: String, method: String = "GET", body: Data? = nil) -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = method
            request.httpBody = body
            return request
        }
        let blocked = [
            request("https://live.trading212.com/api/v0/equity/orders/market", method: "POST", body: Data("{}".utf8)),
            request("https://live.trading212.com/api/v0/equity/orders/limit"),
            request("https://live.trading212.com/api/v0/equity/orders/1", method: "DELETE"),
            request("https://live.trading212.com/api/v0/equity/pies"),
            request("https://live.trading212.com/api/v0/equity/positions", method: "POST"),
            request("http://live.trading212.com/api/v0/equity/positions"),
            request("https://evil.example.com/api/v0/equity/positions"),
        ]
        for item in blocked {
            #expect(throws: Trading212Error.blockedRequest) { try Trading212Transport.validate(item) }
        }
        for endpoint in Trading212Endpoint.allCases {
            try Trading212Transport.validate(request("https://demo.trading212.com/api/v0" + endpoint.path))
        }
    }

    @Test func unauthorizedIsNotRetried() async {
        let http = T212MockHTTP()
        http.handler = { _ in (401, "{}", [:]) }
        await #expect(throws: Trading212Error.invalidCredentials) { _ = try await client(http).accountSummary() }
        #expect(http.requests.count == 1)

        http.handler = { _ in (403, "{}", [:]) }
        await #expect(throws: Trading212Error.missingPermission) { _ = try await client(http).positions() }
    }

    @Test func rateLimitHonoursRetryAfter() async throws {
        let http = T212MockHTTP()
        let sleeps = SleepLog()
        let calls = CallCounter()
        http.handler = { _ in
            calls.next() == 1 ? (429, "{}", ["Retry-After": "3"]) : (200, T212Fixtures.positions, [:])
        }
        let positions = try await client(http, sleeps: sleeps).positions()
        #expect(positions.count == 2)
        #expect(sleeps.values == [3])
    }

    @Test func rateLimitResetHeaderIsUsed() async {
        let http = T212MockHTTP()
        // Reset 120 s in the future: longer than WealthOS will wait, so it gives up at once.
        http.handler = { _ in (429, "{}", ["x-ratelimit-reset": "1800000120"]) }
        await #expect(throws: Trading212Error.rateLimited(retryAfter: 120)) { _ = try await client(http).accountSummary() }
        #expect(http.requests.count == 1)
    }

    @Test func serverErrorsRetryWithBackoff() async throws {
        let http = T212MockHTTP()
        let sleeps = SleepLog()
        let calls = CallCounter()
        http.handler = { _ in
            calls.next() < 3 ? (503, "", [:]) : (200, T212Fixtures.summary, [:])
        }
        _ = try await client(http, sleeps: sleeps).accountSummary()
        #expect(http.requests.count == 3)
        #expect(sleeps.values == [1, 2])
    }

    @Test func offlineMapsToOffline() async {
        let http = T212MockHTTP()
        http.handler = { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: Trading212Error.offline) { _ = try await client(http).accountSummary() }
    }

    @Test func malformedJSONIsInvalidResponse() async {
        let http = T212MockHTTP()
        http.handler = { _ in (200, "<html>", [:]) }
        await #expect(throws: Trading212Error.invalidResponse) { _ = try await client(http).accountSummary() }
    }

    @Test func errorMessagesNeverContainCredentials() {
        let errors: [Trading212Error] = [.missingCredentials, .invalidCredentials, .missingPermission, .rateLimited(retryAfter: 4),
                                         .rateLimited(retryAfter: nil), .timeout, .offline, .network, .server(502), .http(418),
                                         .invalidResponse, .blockedRequest, .busy]
        for error in errors {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty)
            #expect(!text.contains("KEY-abc") && !text.contains("SECRET-xyz") && !text.contains("Basic "))
        }
    }
}

// MARK: - Parsing

@Suite("Trading 212 parsing")
struct Trading212ParsingTests {
    @Test func documentedSummaryDecodesExactDecimals() throws {
        let summary: T212AccountSummary = try T212Fixtures.decode(T212Fixtures.summary)
        #expect(summary.currency == "EUR")
        #expect(summary.id == 12345)
        #expect(summary.cash?.availableToTrade == Decimal(string: "250.50"))
        #expect(summary.cash?.reservedForOrders == Decimal(string: "4.5"))
        #expect(summary.investments?.currentValue == Decimal(string: "1500.118"))
    }

    @Test func positionsParseWithExactQuantitiesAndValues() throws {
        let parsed = try Trading212Parsing.parse(try T212Fixtures.decode(T212Fixtures.positions))
        #expect(parsed.count == 2)
        let vwce = try #require(parsed.first { $0.ticker == "VWCEd_EQ" })
        #expect(vwce.quantity == Decimal(string: "11.4"))
        #expect(vwce.currentValue == Decimal(string: "1084.368"))
        #expect(vwce.totalCost == 912)
        #expect(vwce.fxImpact == nil)
        #expect(vwce.valueCurrency == "EUR")
        #expect(vwce.openedAt != nil)
        let apple = try #require(parsed.first { $0.ticker == "AAPL_US_EQ" })
        #expect(apple.instrumentCurrency == "USD")
        #expect(apple.openedAt != nil)
    }

    @Test func positionWithoutTickerOrQuantityFailsTheWholeSync() {
        let noTicker = [T212Position(quantity: 1, instrument: .init(ticker: nil))]
        let noQuantity = [T212Position(quantity: nil, instrument: .init(ticker: "AAPL_US_EQ"))]
        let duplicate = [T212Position(quantity: 1, instrument: .init(ticker: "A")), T212Position(quantity: 2, instrument: .init(ticker: "A"))]
        for bad in [noTicker, noQuantity, duplicate] {
            #expect(throws: Trading212Error.invalidResponse) { try Trading212Parsing.parse(bad) }
        }
    }

    @Test func zeroQuantityPositionsAreSkipped() throws {
        let parsed = try Trading212Parsing.parse([T212Position(quantity: 0, instrument: .init(ticker: "X_EQ"))])
        #expect(parsed.isEmpty)
    }

    @Test func baseSymbolStripsTrading212Suffixes() {
        #expect(Trading212Matching.baseSymbol(ofTicker: "AAPL_US_EQ") == "AAPL")
        #expect(Trading212Matching.baseSymbol(ofTicker: "VUSAl_EQ") == "VUSA")
        #expect(Trading212Matching.baseSymbol(ofTicker: "VWCEd_EQ") == "VWCE")
    }
}

// MARK: - Reconciliation and net worth

@MainActor
@Suite("Trading 212 reconciliation")
struct Trading212ReconciliationTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try Persistence.makeInMemoryContainer()
    }

    func apply(_ positionsJSON: String = T212Fixtures.positions, instruments: Bool = true, at date: Date? = nil) throws {
        let summary: T212AccountSummary = try T212Fixtures.decode(T212Fixtures.summary)
        let parsed = try Trading212Parsing.parse(try T212Fixtures.decode(positionsJSON))
        let index = instruments ? Trading212Parsing.instrumentIndex(try T212Fixtures.decode(T212Fixtures.instruments)) : nil
        try Persistence.commit(context) {
            try Trading212Reconciler.apply(summary: summary, positions: parsed, instruments: index,
                                           environment: .live, now: date ?? now, in: context)
        }
    }

    func engine() -> FinanceEngine { DataMaintenance.makeEngine(context: context, baseCurrency: "EUR") }

    @Test func repeatedSyncsNeverDuplicate() throws {
        try apply()
        try apply()
        try apply(instruments: false)
        #expect(try context.fetchCount(FetchDescriptor<BrokerAccountSnapshot>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<BrokerPosition>()) == 2)
        let vwce = try #require(try context.fetch(FetchDescriptor<BrokerPosition>()).first { $0.ticker == "VWCEd_EQ" })
        // Metadata from an earlier sync is kept when a later sync skips the instrument list.
        #expect(vwce.instrumentType == "ETF" && vwce.shortName == "VWCE" && vwce.assetClass == .etf)
    }

    @Test func closedPositionsLeaveTheSnapshotAndUpdatesApply() throws {
        try apply()
        try apply(T212Fixtures.positionsAfterSale, at: now.addingTimeInterval(3600))
        let rows = try context.fetch(FetchDescriptor<BrokerPosition>())
        #expect(rows.map(\.ticker) == ["AAPL_US_EQ"])
        #expect(rows.first?.quantity == 3)
        #expect(rows.first?.currentValue == 525)
        #expect(rows.first?.syncedAt == now.addingTimeInterval(3600))
    }

    @Test func summaryWithoutCurrencyChangesNothing() throws {
        try apply()
        var summary: T212AccountSummary = try T212Fixtures.decode(T212Fixtures.summary)
        summary.currency = nil
        #expect(throws: Trading212Error.invalidResponse) {
            try Trading212Reconciler.apply(summary: summary, positions: [], instruments: nil, environment: .live, now: now, in: context)
        }
        context.rollback()
        #expect(try context.fetchCount(FetchDescriptor<BrokerPosition>()) == 2)
    }

    @Test func netWorthCountsCashAndPositionsButNotProviderTotal() throws {
        try apply()
        let engine = engine()
        // Cash 250.50 + 10 + 4.5 = 265; positions 415.75 + 1084.368 = 1500.118. Never 999999.
        #expect(engine.brokerCashBase == Decimal(string: "265"))
        #expect(engine.brokerTotalBase == Decimal(string: "1765.118"))
        #expect(engine.summary.netWorth == Decimal(string: "1765.118"))
        #expect(engine.summary.investmentAccounts == 265)
        #expect(engine.summary.holdingsValue == Decimal(string: "1500.118"))
        #expect(engine.portfolioCostBasis == 1262)
        #expect(engine.portfolioUnrealized == Decimal(string: "238.118"))
    }

    @Test func linkedManualRecordsAreKeptButNotCountedTwice() throws {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 1_000)
        let t212Cash = Account(name: "Trading 212", kind: .investment, currencyCode: "EUR", openingBalance: 265)
        let manualVWCE = Holding(name: "Vanguard FTSE All-World", symbol: "VWCE", assetClass: .etf, currencyCode: "EUR", currentPrice: 95)
        context.insert(checking)
        context.insert(t212Cash)
        context.insert(manualVWCE)
        context.insert(InvestmentTrade(holdingID: manualVWCE.id, kind: .buy, date: Date.now.addingTimeInterval(-86_400 * 30),
                                       quantity: 11.4, pricePerUnit: 80, fee: 0))
        try context.save()
        try apply()

        // Before linking: duplicates are suggested, never applied automatically.
        let positions = try context.fetch(FetchDescriptor<BrokerPosition>())
        let holdingSuggestions = Trading212Matching.holdingCandidates(holdings: [manualVWCE], positions: positions, links: [])
        #expect(holdingSuggestions.map(\.holding.id) == [manualVWCE.id])
        #expect(Trading212Matching.accountCandidates(accounts: [checking, t212Cash], links: []).map(\.id) == [t212Cash.id])
        let unlinked = engine()
        // Checking 1000 + manual T212 account 265 + manual VWCE 11.4 × 95 = 1083 + synced 1765.118.
        #expect(unlinked.summary.netWorth == Decimal(1000 + 265 + 1083) + Decimal(string: "1765.118")!)

        try Persistence.commit(context) {
            try Trading212Reconciler.setLinked(true, kind: .holding, localID: manualVWCE.id, in: context)
            try Trading212Reconciler.setLinked(true, kind: .account, localID: t212Cash.id, in: context)
            try Trading212Reconciler.setLinked(true, kind: .account, localID: t212Cash.id, in: context) // idempotent
        }
        #expect(try context.fetchCount(FetchDescriptor<BrokerLink>()) == 2)
        let linked = DataMaintenance.makeEngine(context: context, baseCurrency: "EUR")
        #expect(linked.summary.netWorth == 1000 + Decimal(string: "1765.118")!)
        #expect(linked.isSuperseded(manualVWCE) && linked.isSuperseded(t212Cash) && !linked.isSuperseded(checking))
        // Manual records are untouched.
        #expect(try context.fetchCount(FetchDescriptor<Holding>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<InvestmentTrade>()) == 1)
        #expect(linked.balance(of: t212Cash) == 265)
    }

    @Test func foreignAccountCurrencyConvertsOrIsFlaggedMissing() throws {
        try apply()
        let snapshot = try #require(try context.fetch(FetchDescriptor<BrokerAccountSnapshot>()).first)
        snapshot.currencyCode = "EUR"
        let inUSD = DataMaintenance.makeEngine(context: context, baseCurrency: "USD")
        // No EUR→USD rate: excluded from totals and reported, never treated as 1:1.
        #expect(inUSD.summary.netWorth == 0)
        #expect(inUSD.summary.missingRateCurrencies.contains("EUR"))

        let converted = FinanceEngine(accounts: [], transactions: [], holdings: [], trades: [],
                                      converter: CurrencyConverter(baseCode: "USD", rates: ["EUR": Decimal(string: "1.1")!]),
                                      broker: BrokerPortfolio(snapshot: snapshot, positions: try context.fetch(FetchDescriptor<BrokerPosition>()), links: []))
        #expect(converted.summary.netWorth == Decimal(string: "1765.118")! * Decimal(string: "1.1")!)
    }

    @Test func removingBrokerDataNeverTouchesManualData() throws {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 1_000)
        let holding = Holding(name: "ETF", symbol: "ETF", assetClass: .etf, currencyCode: "EUR", currentPrice: 100)
        context.insert(checking)
        context.insert(holding)
        try apply()
        try Persistence.commit(context) { try Trading212Reconciler.setLinked(true, kind: .holding, localID: holding.id, in: context) }
        try Persistence.commit(context) { try Trading212Reconciler.removeAllData(in: context) }
        #expect(try context.fetchCount(FetchDescriptor<BrokerAccountSnapshot>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BrokerPosition>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BrokerLink>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Holding>()) == 1)
        #expect(DataMaintenance.makeEngine(context: context, baseCurrency: "EUR").summary.netWorth == 1000)
    }
}

// MARK: - Service (sync policy, errors, disconnect)

@MainActor
@Suite("Trading 212 service")
struct Trading212ServiceTests {
    let container: ModelContainer
    let http = T212MockHTTP()
    let secrets = MemorySecrets()
    let defaults: UserDefaults
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try Persistence.makeInMemoryContainer()
        defaults = UserDefaults(suiteName: "WealthOSTests.t212.\(UUID().uuidString)")!
    }

    func makeService(connected: Bool = true) -> Trading212Service {
        if connected {
            secrets.values["apiKey"] = "KEY-abc"
            secrets.values["apiSecret"] = "SECRET-xyz"
        }
        return Trading212Service(http: http, secrets: secrets, defaults: defaults, sleep: { _ in })
    }

    var snapshotCount: Int { (try? context.fetchCount(FetchDescriptor<BrokerAccountSnapshot>())) ?? -1 }
    var positionCount: Int { (try? context.fetchCount(FetchDescriptor<BrokerPosition>())) ?? -1 }

    @Test func connectValidatesThenStoresCredentialsOnlyInSecretStore() async throws {
        let service = makeService(connected: false)
        #expect(!service.isConnected)
        try await service.connect(apiKey: " KEY-abc ", apiSecret: "SECRET-xyz", environment: .demo, context: context, now: now)
        #expect(service.isConnected)
        #expect(service.environment == .demo)
        #expect(secrets.values["apiKey"] == "KEY-abc" && secrets.values["apiSecret"] == "SECRET-xyz")
        #expect(http.requests.allSatisfy { $0.url?.host == "demo.trading212.com" })
        #expect(http.count(.instruments) == 1)
        #expect(snapshotCount == 1 && positionCount == 2)
        // Nothing secret ends up in UserDefaults.
        for value in defaults.dictionaryRepresentation().values {
            let text = "\(value)"
            #expect(!text.contains("KEY-abc") && !text.contains("SECRET-xyz"))
        }
    }

    @Test func rejectedCredentialsAreNeverStored() async {
        let service = makeService(connected: false)
        http.handler = { _ in (401, "{}", [:]) }
        await #expect(throws: Trading212Error.invalidCredentials) {
            try await service.connect(apiKey: "bad", apiSecret: "bad", environment: .live, context: context, now: now)
        }
        #expect(!service.isConnected)
        #expect(secrets.values.isEmpty)
        #expect(snapshotCount == 0)
    }

    @Test func incompleteCredentialsMakeNoRequest() async {
        let service = makeService(connected: false)
        await #expect(throws: Trading212Error.missingCredentials) {
            try await service.connect(apiKey: "key", apiSecret: "  ", environment: .live, context: context, now: now)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func offlineKeepsCachedDataAndBacksOff() async throws {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        #expect(positionCount == 2)

        http.handler = { _ in throw URLError(.notConnectedToInternet) }
        let later = now.addingTimeInterval(Trading212Service.staleInterval + 1)
        #expect(await service.sync(context: context, now: later) == false)
        #expect(service.lastError == .offline)
        #expect(positionCount == 2 && snapshotCount == 1)
        let cached = try #require(try context.fetch(FetchDescriptor<BrokerAccountSnapshot>()).first)
        #expect(cached.syncedAt == now)

        // Rapid foreground switches during the back-off make no requests.
        let before = http.requests.count
        await service.syncIfStale(context: context, now: later.addingTimeInterval(10))
        await service.syncIfStale(context: context, now: later.addingTimeInterval(30))
        #expect(http.requests.count == before)

        // Back online: the next automatic sync after the back-off succeeds and clears the error.
        http.handler = T212MockHTTP().handler
        #expect(await service.sync(context: context, now: later.addingTimeInterval(61)))
        #expect(service.lastError == nil)
    }

    @Test func freshDataIsNotRefetchedAutomatically() async {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        let before = http.requests.count
        await service.syncIfStale(context: context, now: now.addingTimeInterval(60))
        await service.syncIfStale(context: context, now: now.addingTimeInterval(Trading212Service.staleInterval - 1))
        #expect(http.requests.count == before)
    }

    @Test func manualSyncsRespectTheSummaryRateLimit() async {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(2)) == false)
        #expect(http.count(.accountSummary) == 1)
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(Trading212Service.minimumInterval)))
        #expect(http.count(.accountSummary) == 2)
        // Instrument metadata (1 req / 50 s) isn't re-requested for known positions.
        #expect(http.count(.instruments) <= 1)
    }

    @Test func overlappingSyncsAreRefused() async {
        let service = makeService()
        http.gate = { try? await Task.sleep(for: .milliseconds(150)) }
        let first = Task { await service.sync(context: context, force: true, now: now) }
        for _ in 0..<100 where !service.isSyncing { await Task.yield() }
        #expect(service.isSyncing)
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(60)) == false)
        await #expect(throws: Trading212Error.busy) {
            try await service.connect(apiKey: "k", apiSecret: "s", environment: .live, context: context, now: now)
        }
        #expect(await first.value)
        #expect(http.count(.accountSummary) == 1)
    }

    @Test func revokedKeyStopsAutomaticSyncsButKeepsData() async {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        http.handler = { _ in (401, "{}", [:]) }
        let later = now.addingTimeInterval(Trading212Service.staleInterval + 1)
        #expect(await service.sync(context: context, now: later) == false)
        #expect(service.needsReconnect)
        #expect(positionCount == 2)
        let before = http.requests.count
        await service.syncIfStale(context: context, now: later.addingTimeInterval(3600))
        #expect(http.requests.count == before)
    }

    @Test func disconnectDuringSyncDoesNotResurrectData() async {
        let service = makeService()
        http.gate = { try? await Task.sleep(for: .milliseconds(150)) }
        let inFlight = Task { await service.sync(context: context, force: true, now: now) }
        for _ in 0..<100 where !service.isSyncing { await Task.yield() }
        try? service.disconnect(removeData: true, context: context)
        #expect(await inFlight.value == false)
        #expect(snapshotCount == 0 && positionCount == 0)
        #expect(!service.isConnected)
        #expect(secrets.values.isEmpty)
    }

    @Test func disconnectCanKeepOrRemoveCachedDataOnly() async throws {
        let account = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 500)
        context.insert(account)
        try context.save()
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))

        try service.disconnect(removeData: false, context: context)
        #expect(!service.isConnected && secrets.values.isEmpty)
        #expect(snapshotCount == 1 && positionCount == 2)
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(60)) == false)

        try service.disconnect(removeData: true, context: context)
        #expect(snapshotCount == 0 && positionCount == 0)
        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 1)
    }

    @Test func automaticBackoffDurations() {
        #expect(Trading212Service.automaticBackoff(after: .offline) == 60)
        #expect(Trading212Service.automaticBackoff(after: .rateLimited(retryAfter: 300)) == 300)
        #expect(Trading212Service.automaticBackoff(after: .rateLimited(retryAfter: nil)) == 60)
        #expect(Trading212Service.automaticBackoff(after: .server(500)) == 300)
    }

    @Test func appInstanceInTestHostCannotReachKeychainOrNetwork() async {
        let service = Trading212Service.makeForApp(environment: ["XCTestConfigurationFilePath": "/tmp/x"])
        #expect(!service.isConnected)
        #expect(await service.sync(context: context, force: true, now: now) == false)
        await #expect(throws: Trading212Error.blockedRequest) {
            try await service.connect(apiKey: "k", apiSecret: "s", environment: .live, context: context, now: now)
        }
        #expect(!service.isConnected)
        #expect(snapshotCount == 0)
        let preview = Trading212Service.makeForApp(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"])
        #expect(!preview.isConnected)
    }
}
