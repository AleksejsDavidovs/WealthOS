import Foundation
import SwiftData
import Testing
@testable import MyApp

// MARK: - Test doubles (no live network is ever used)

/// Routes by endpoint and applies the real transport's validation, so a test fails if the code
/// under test ever builds a request the app would refuse to send (wrong host, method, path…).
final class BinanceMockHTTP: HTTPClient, @unchecked Sendable {
    typealias Reply = (status: Int, body: String, headers: [String: String])
    /// `@Sendable`: the client calls the transport off the main actor.
    var handler: @Sendable (BinanceEndpoint, URLRequest) throws -> Reply = { endpoint, _ in BinanceFixtures.reply(endpoint) }
    var gate: (@Sendable () async -> Void)?
    private(set) var requests: [URLRequest] = []

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try BinanceTransport.validate(request)
        requests.append(request)
        if let gate { await gate() }
        guard let endpoint = BinanceEndpoint(rawValue: request.url?.path ?? "") else { throw BinanceError.blockedRequest }
        let reply = try handler(endpoint, request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }

    func count(_ endpoint: BinanceEndpoint) -> Int { requests.filter { $0.url?.path == endpoint.path }.count }
    func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

/// Shapes follow https://developers.binance.com/docs (account, apiRestrictions, Simple Earn
/// positions, exchangeInfo, ticker/price). Amounts are decimal strings, as Binance sends them.
enum BinanceFixtures {
    static let readOnlyKey = #"{"ipRestrict":false,"createTime":1623840271000,"enableReading":true,"enableWithdrawals":false,"enableInternalTransfer":false,"enableMargin":false,"enableFutures":false,"permitsUniversalTransfer":false,"enableVanillaOptions":false,"enableFixApiTrade":false,"enableFixReadOnly":true,"enableSpotAndMarginTrading":false,"enablePortfolioMarginTrading":false}"#
    static let withdrawalKey = #"{"ipRestrict":false,"enableReading":true,"enableWithdrawals":true,"enableInternalTransfer":true,"enableSpotAndMarginTrading":true,"permitsUniversalTransfer":false}"#
    static let noReadKey = #"{"ipRestrict":false,"enableReading":false}"#

    /// ETH spot 0.5 free + 0.09118264 locked. LDUSDT duplicates Flexible USDT; LDO is a real coin;
    /// XYZ has no market.
    static let account = #"{"makerCommission":15,"takerCommission":15,"buyerCommission":0,"sellerCommission":0,"commissionRates":{"maker":"0.00150000","taker":"0.00150000","buyer":"0.00000000","seller":"0.00000000"},"canTrade":true,"canWithdraw":true,"canDeposit":true,"brokered":false,"requireSelfTradePrevention":false,"preventSor":false,"updateTime":123456789,"accountType":"SPOT","balances":[{"asset":"ETH","free":"0.50000000","locked":"0.09118264"},{"asset":"BTC","free":"0.00012345","locked":"0.00000000"},{"asset":"USDT","free":"100.00000000","locked":"0.00000000"},{"asset":"LDUSDT","free":"50.00000000","locked":"0.00000000"},{"asset":"LDO","free":"10.00000000","locked":"0.00000000"},{"asset":"XYZ","free":"5.00000000","locked":"0.00000000"}],"permissions":["SPOT"],"uid":354937868}"#

    static func account(eth free: String, locked: String = "0.00000000") -> String {
        #"{"accountType":"SPOT","balances":[{"asset":"ETH","free":""# + free + #"","locked":""# + locked + #""}],"permissions":["SPOT"],"uid":354937868}"#
    }

    static let flexible = #"{"rows":[{"totalAmount":"50.00000000","latestAnnualPercentageRate":"0.02599895","asset":"USDT","productId":"USDT001","cumulativeTotalRewards":"0.45459183","autoSubscribe":true},{"totalAmount":"0.10000000","latestAnnualPercentageRate":"0.01","asset":"ETH","productId":"ETH001","cumulativeTotalRewards":"0","autoSubscribe":true}],"total":2}"#
    static let locked = #"{"rows":[{"positionId":123123,"parentPositionId":123122,"projectId":"Eth*90","asset":"ETH","amount":"0.25000000","purchaseTime":1646182276000,"duration":"60","accrualDays":"4","rewardAsset":"ETH","APY":"0.03","rewardAmt":"0.00100000","status":"HOLDING","canRedeemEarly":true,"canFastRedemption":true,"autoSubscribe":true,"type":"AUTO"}],"total":1}"#
    static let emptyPage = #"{"rows":[],"total":0}"#

    static let exchangeInfo = #"{"timezone":"UTC","serverTime":1565246363776,"rateLimits":[],"exchangeFilters":[],"symbols":[{"symbol":"ETHEUR","status":"TRADING","baseAsset":"ETH","quoteAsset":"EUR"},{"symbol":"BTCEUR","status":"TRADING","baseAsset":"BTC","quoteAsset":"EUR"},{"symbol":"EURUSDT","status":"TRADING","baseAsset":"EUR","quoteAsset":"USDT"},{"symbol":"LDOUSDT","status":"TRADING","baseAsset":"LDO","quoteAsset":"USDT"},{"symbol":"OLDEUR","status":"BREAK","baseAsset":"OLD","quoteAsset":"EUR"}]}"#

    static func tickers(eth: String = "3000.00000000") -> String {
        #"[{"symbol":"ETHEUR","price":""# + eth + #""},{"symbol":"BTCEUR","price":"60000.00000000"},{"symbol":"EURUSDT","price":"1.25000000"},{"symbol":"LDOUSDT","price":"2.50000000"},{"symbol":"OLDEUR","price":"1.00000000"}]"#
    }

    static func reply(_ endpoint: BinanceEndpoint) -> BinanceMockHTTP.Reply {
        switch endpoint {
        case .apiRestrictions: (200, readOnlyKey, [:])
        case .account: (200, account, [:])
        case .flexiblePositions: (200, flexible, [:])
        case .lockedPositions: (200, locked, [:])
        case .exchangeInfo: (200, exchangeInfo, [:])
        case .tickerPrice: (200, tickers(), [:])
        case .serverTime: (200, #"{"serverTime":1499827319559}"#, [:])
        }
    }

    static func decode<T: Decodable>(_ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
}

private func dec(_ text: String) -> Decimal { Decimal(string: text)! }

// MARK: - Signing, requests and transport

@Suite("Binance signing and transport")
struct BinanceSigningTests {
    let credentials = BinanceCredentials(apiKey: "TESTKEY123", secretKey: "TESTSECRET456")

    @Test func hmacMatchesBinanceDocumentedExample() {
        // From the Binance Spot API docs, "SIGNED endpoint examples" (HMAC keys).
        let query = "symbol=LTCBTC&side=BUY&type=LIMIT&timeInForce=GTC&quantity=1&price=0.1&recvWindow=5000&timestamp=1499827319559"
        let signature = BinanceSigner.signature(for: query, secret: "NhqPtmdSJYdKjVHjA7PZj4Mge3R5YNiP1e3UZjInClVN65XAbvqqM6A7H5fATj0j")
        #expect(signature == "c8db56825ae71d6d79447849e617115f4a920fa2acdcab2b053c4b2838bd6b71")
    }

    @Test func nonASCIIIsPercentEncodedBeforeSigning() {
        #expect(BinanceSigner.query([("asset", "ÄB C")]) == "asset=%C3%84B%20C")
        #expect(BinanceSigner.query([("symbols", #"["BTCUSDT"]"#)]) == "symbols=%5B%22BTCUSDT%22%5D")
    }

    @Test func signedRequestCarriesTimestampWindowAndSignatureOfTheSentQuery() throws {
        var client = BinanceClient(credentials: credentials, http: BinanceMockHTTP())
        client.now = { Date(timeIntervalSince1970: 1_800_000_000.123) }
        let request = try client.request(for: .account, parameters: [("omitZeroBalances", "true")])
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://api.binance.com/api/v3/account?omitZeroBalances=true&recvWindow=10000&timestamp=1800000000123&signature="))
        let query = try #require(request.url?.query)
        let signed = String(query[..<query.range(of: "&signature=")!.lowerBound])
        let signature = String(query[query.range(of: "&signature=")!.upperBound...])
        #expect(signature == BinanceSigner.signature(for: signed, secret: "TESTSECRET456"))
        #expect(signature.count == 64)
        #expect(request.value(forHTTPHeaderField: "X-MBX-APIKEY") == "TESTKEY123")
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        // The secret itself is never sent.
        #expect(!url.contains("TESTSECRET456") && request.allHTTPHeaderFields?.values.contains("TESTSECRET456") == false)
    }

    @Test func clockOffsetShiftsTheTimestamp() throws {
        var client = BinanceClient(credentials: credentials, http: BinanceMockHTTP())
        client.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        client.clock.setOffset(-2_500)
        #expect(client.timestamp() == 1_800_000_000_000 - 2_500)
    }

    @Test func publicRequestsCarryNoKeyOrSignature() throws {
        let client = BinanceClient(credentials: credentials, http: BinanceMockHTTP())
        let request = try client.request(for: .tickerPrice, parameters: [("symbolStatus", "TRADING")])
        #expect(request.url?.absoluteString == "https://api.binance.com/api/v3/ticker/price?symbolStatus=TRADING")
        #expect(request.value(forHTTPHeaderField: "X-MBX-APIKEY") == nil)
    }

    @Test func credentialsMustBeASCIIAlphanumericHMACKeys() {
        #expect(BinanceCredentials(apiKey: " abcDEF123 \n", secretKey: "\tXYZ789 ").isComplete)
        #expect(!BinanceCredentials(apiKey: "abc", secretKey: "").isComplete)
        #expect(!BinanceCredentials(apiKey: "abc\r\nX-Evil: 1", secretKey: "s").isComplete)
        #expect(!BinanceCredentials(apiKey: "-----BEGIN PRIVATE KEY-----", secretKey: "s").isComplete)
        #expect(!BinanceCredentials(apiKey: "ключ", secretKey: "s").isComplete)
    }

    @Test func onlyReadOnlyEndpointsExist() {
        let forbidden = ["order", "withdraw", "transfer", "subscribe", "redeem", "convert", "margin", "futures", "staking", "loan", "dust"]
        for endpoint in BinanceEndpoint.allCases {
            for word in forbidden { #expect(!endpoint.path.lowercased().contains(word)) }
        }
        #expect(BinanceEndpoint.allCases.count == 7)
    }

    @Test func transportBlocksTradingWithdrawalsAndForeignHosts() throws {
        func request(_ url: String, method: String = "GET", key: Bool = true, body: Data? = nil) -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = method
            request.httpBody = body
            if key { request.setValue("TESTKEY123", forHTTPHeaderField: "X-MBX-APIKEY") }
            return request
        }
        let blocked = [
            request("https://api.binance.com/api/v3/order?symbol=ETHEUR&signature=x", method: "POST"),
            request("https://api.binance.com/api/v3/order/test?signature=x"),
            request("https://api.binance.com/sapi/v1/capital/withdraw/apply?signature=x", method: "POST"),
            request("https://api.binance.com/sapi/v1/capital/withdraw/apply?signature=x"),
            request("https://api.binance.com/sapi/v1/asset/transfer?signature=x", method: "POST"),
            request("https://api.binance.com/sapi/v1/simple-earn/flexible/subscribe?signature=x", method: "POST"),
            request("https://api.binance.com/sapi/v1/simple-earn/flexible/redeem?signature=x", method: "POST"),
            request("https://api.binance.com/sapi/v1/convert/acceptQuote?signature=x", method: "POST"),
            request("https://api.binance.com/api/v3/account?signature=x", method: "POST"),
            request("https://api.binance.com/api/v3/account?signature=x", body: Data("x".utf8)),
            request("http://api.binance.com/api/v3/account?signature=x"),
            request("https://api.binance.com:8443/api/v3/account?signature=x"),
            request("https://api.binance.us/api/v3/account?signature=x"),
            request("https://evil.example.com/api/v3/account?signature=x"),
            request("https://api.binance.com.evil.example/api/v3/account?signature=x"),
            request("https://api.binance.com/api/v3/account", key: true),                    // unsigned
            request("https://api.binance.com/api/v3/account?signature=x", key: false),       // no key
            request("https://api.binance.com/api/v3/ticker/price", key: true),               // key on a public call
        ]
        for item in blocked {
            #expect(throws: BinanceError.blockedRequest) { try BinanceTransport.validate(item) }
        }
        try BinanceTransport.validate(request("https://api.binance.com/api/v3/account?timestamp=1&signature=x"))
        try BinanceTransport.validate(request("https://api.binance.com/api/v3/ticker/price", key: false))
    }

    @Test func errorMessagesNeverContainCredentials() {
        let errors: [BinanceError] = [.missingCredentials, .invalidCredentials, .missingPermission, .keyNotReadOnly(["withdrawals"]),
                                      .timestampOutOfSync, .rateLimited(retryAfter: 3), .ipBanned(retryAfter: 600), .accessDenied,
                                      .timeout, .offline, .network, .server(503), .http(418), .api(code: -1100), .invalidResponse,
                                      .blockedRequest, .busy]
        for error in errors {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty && !text.contains("TESTKEY123") && !text.contains("TESTSECRET456"))
        }
    }
}

// MARK: - Client error handling

@Suite("Binance client")
struct BinanceClientTests {
    func client(_ http: BinanceMockHTTP, sleeps: SleepLog = SleepLog()) -> BinanceClient {
        var client = BinanceClient(credentials: BinanceCredentials(apiKey: "TESTKEY123", secretKey: "TESTSECRET456"), http: http)
        client.sleep = { sleeps.values.append($0) }
        return client
    }

    @Test func rejectedKeyOrSignatureIsNotRetried() async {
        for (status, body) in [(401, #"{"code":-2015,"msg":"Invalid API-key, IP, or permissions for action."}"#),
                               (400, #"{"code":-1022,"msg":"Signature for this request is not valid."}"#),
                               (400, #"{"code":-2014,"msg":"API-key format invalid."}"#)] {
            let http = BinanceMockHTTP()
            http.handler = { _, _ in (status, body, [:]) }
            await #expect(throws: BinanceError.invalidCredentials) { _ = try await client(http).account() }
            #expect(http.requests.count == 1)
        }
    }

    @Test func clockDriftIsCorrectedOnceThenRetried() async throws {
        let http = BinanceMockHTTP()
        let calls = CallCounter()
        let serverAhead = Int64(Date.now.timeIntervalSince1970 * 1000) + 5_000
        http.handler = { endpoint, _ in
            switch endpoint {
            case .serverTime: return (200, #"{"serverTime":\#(serverAhead)}"#, [:])
            default:
                return calls.next() == 1 ? (400, #"{"code":-1021,"msg":"Timestamp for this request is outside of the recvWindow."}"#, [:])
                                         : (200, BinanceFixtures.account, [:])
            }
        }
        let client = client(http)
        _ = try await client.account()
        #expect(http.count(.serverTime) == 1 && http.count(.account) == 2)
        let retried = try #require(http.requests.last)
        let timestamp = try #require(Int64(http.query(retried, "timestamp") ?? ""))
        #expect(abs(timestamp - serverAhead) < 2_000)
        #expect(client.clock.offsetMilliseconds > 3_000)
    }

    @Test func persistentClockErrorIsReported() async {
        let http = BinanceMockHTTP()
        http.handler = { endpoint, _ in
            endpoint == .serverTime ? (200, #"{"serverTime":1}"#, [:]) : (400, #"{"code":-1021,"msg":"x"}"#, [:])
        }
        await #expect(throws: BinanceError.timestampOutOfSync) { _ = try await client(http).account() }
    }

    @Test func rateLimitHonoursRetryAfter() async throws {
        let http = BinanceMockHTTP()
        let sleeps = SleepLog()
        let calls = CallCounter()
        http.handler = { endpoint, _ in
            calls.next() == 1 ? (429, #"{"code":-1003,"msg":"Too much request weight used"}"#, ["Retry-After": "2"])
                              : BinanceFixtures.reply(endpoint)
        }
        _ = try await client(http, sleeps: sleeps).account()
        #expect(sleeps.values == [2])
    }

    @Test func longRateLimitAndIPBanAreNotRetried() async {
        let http = BinanceMockHTTP()
        http.handler = { _, _ in (429, "{}", ["Retry-After": "120"]) }
        await #expect(throws: BinanceError.rateLimited(retryAfter: 120)) { _ = try await client(http).account() }
        #expect(http.requests.count == 1)

        let banned = BinanceMockHTTP()
        banned.handler = { _, _ in (418, #"{"code":-1003,"msg":"Way too much request weight used; IP banned"}"#, ["Retry-After": "600"]) }
        await #expect(throws: BinanceError.ipBanned(retryAfter: 600)) { _ = try await client(banned).account() }
        #expect(banned.requests.count == 1)
    }

    @Test func serverErrorsRetryWithBackoff() async throws {
        let http = BinanceMockHTTP()
        let sleeps = SleepLog()
        let calls = CallCounter()
        http.handler = { endpoint, _ in calls.next() < 3 ? (503, "", [:]) : BinanceFixtures.reply(endpoint) }
        _ = try await client(http, sleeps: sleeps).account()
        #expect(sleeps.values == [1, 2])
    }

    @Test func offlineAndMalformedResponses() async {
        let offline = BinanceMockHTTP()
        offline.handler = { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: BinanceError.offline) { _ = try await client(offline).account() }

        let garbage = BinanceMockHTTP()
        garbage.handler = { _, _ in (200, "<html>", [:]) }
        await #expect(throws: BinanceError.invalidResponse) { _ = try await client(garbage).account() }
    }

    @Test func earnPositionsArePaginated() async throws {
        let http = BinanceMockHTTP()
        http.handler = { endpoint, request in
            let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "current" }?.value ?? "") ?? 0
            let count = page == 1 ? 100 : 50
            let rows = (0..<count).map { #"{"asset":"A\#(page)x\#($0)","totalAmount":"1.5","productId":"P\#(page)-\#($0)"}"# }
            return (200, #"{"rows":[\#(rows.joined(separator: ","))],"total":150}"#, [:])
        }
        let rows = try await client(http).flexiblePositions()
        #expect(rows.count == 150)
        #expect(http.count(.flexiblePositions) == 2)
        #expect(http.requests.map { http.query($0, "size") } == ["100", "100"])
        #expect(http.requests.map { http.query($0, "current") } == ["1", "2"])
    }

    @Test func emptyEarnIsOneRequest() async throws {
        let http = BinanceMockHTTP()
        http.handler = { _, _ in (200, BinanceFixtures.emptyPage, [:]) }
        #expect(try await client(http).lockedPositions().isEmpty)
        #expect(http.requests.count == 1)
    }
}

// MARK: - Parsing and pricing

@Suite("Binance parsing and pricing")
struct BinanceParsingTests {
    @Test func spotTotalIsFreePlusLockedWithExactDecimals() throws {
        let info: BinanceAccountInfo = try BinanceFixtures.decode(BinanceFixtures.account)
        let spot = try BinanceParsing.spot(info)
        let eth = try #require(spot.first { $0.asset == "ETH" })
        #expect(eth.free == dec("0.5") && eth.locked == dec("0.09118264"))
        #expect(eth.amount == dec("0.59118264"))
        #expect(spot.first { $0.asset == "BTC" }?.amount == dec("0.00012345"))
        #expect(info.uid == 354937868)
    }

    @Test func tinyBalancesSurviveExactly() throws {
        let info: BinanceAccountInfo = try BinanceFixtures.decode(
            #"{"balances":[{"asset":"SHIB","free":"0.000000001","locked":"0.000000000000000001"}]}"#)
        #expect(try BinanceParsing.spot(info).first?.amount == dec("0.000000001000000001"))
    }

    @Test func emptyAndZeroSpotWallets() throws {
        let empty: BinanceAccountInfo = try BinanceFixtures.decode(#"{"balances":[],"uid":1}"#)
        #expect(try BinanceParsing.spot(empty).isEmpty)
        let zero: BinanceAccountInfo = try BinanceFixtures.decode(#"{"balances":[{"asset":"BNB","free":"0.00000000","locked":"0.00000000"}]}"#)
        #expect(try BinanceParsing.spot(zero).isEmpty)
    }

    @Test func malformedBalancesFailTheWholeSync() throws {
        for bad in [#"{"asset":"ETH","free":"1e-8","locked":"0"}"#, #"{"asset":"ETH","free":"-1","locked":"0"}"#,
                    #"{"asset":"ETH","free":"1,5","locked":"0"}"#, #"{"asset":"ETH","locked":"0"}"#,
                    #"{"asset":"","free":"1","locked":"0"}"#] {
            let info: BinanceAccountInfo = try BinanceFixtures.decode(#"{"balances":[\#(bad)]}"#)
            #expect(throws: BinanceError.invalidResponse) { try BinanceParsing.spot(info) }
        }
        let missing: BinanceAccountInfo = try BinanceFixtures.decode(#"{"uid":1}"#)
        #expect(throws: BinanceError.invalidResponse) { try BinanceParsing.spot(missing) }
    }

    @Test func earnProductsOfTheSameAssetStaySeparate() throws {
        let page: BinancePage<BinanceFlexiblePosition> = try BinanceFixtures.decode(
            #"{"rows":[{"asset":"ETH","totalAmount":"0.1","productId":"ETH001"},{"asset":"ETH","totalAmount":"0.2","productId":"ETH002"},{"asset":"BNB","totalAmount":"0","productId":"BNB001"}],"total":3}"#)
        let rows = try BinanceParsing.flexible(page.rows ?? [])
        #expect(rows.map(\.key) == ["flexible:ETH:ETH001", "flexible:ETH:ETH002"])
        let locked: BinancePage<BinanceLockedPosition> = try BinanceFixtures.decode(BinanceFixtures.locked)
        #expect(try BinanceParsing.locked(locked.rows ?? []).first?.key == "locked:ETH:123123")
    }

    func prices(_ assets: Set<String>, tickers: String = BinanceFixtures.tickers()) throws -> [String: BinancePrice] {
        let info: BinanceExchangeInfo = try BinanceFixtures.decode(BinanceFixtures.exchangeInfo)
        let list: [BinanceTickerPrice] = try BinanceFixtures.decode(tickers)
        return BinancePricing.eurPrices(for: assets, pairs: BinancePricing.pairs(from: info), tickers: BinancePricing.tickers(list))
    }

    @Test func directEURMarket() throws {
        let price = try #require(try prices(["ETH"])["ETH"])
        #expect(price.eur == 3000 && price.route == "ETHEUR")
    }

    @Test func stablecoinUsesTheEURUSDTMarketNotOneToOne() throws {
        let usdt = try #require(try prices(["USDT"])["USDT"])
        #expect(usdt.eur == dec("0.8"))   // 1 / 1.25
        #expect(usdt.eur != 1)
        #expect(usdt.route == "EURUSDT")
    }

    @Test func bridgedRouteMultipliesValidatedLegs() throws {
        let ldo = try #require(try prices(["LDO"])["LDO"])
        #expect(ldo.eur == dec("2"))      // 2.5 USDT × 0.8 EUR/USDT
        #expect(ldo.route == "LDOUSDT → EURUSDT")
    }

    @Test func noRouteMeansNoPriceNeverZero() throws {
        let result = try prices(["XYZ", "OLD", "USDC", "EUR"])
        #expect(result["XYZ"] == nil)
        #expect(result["OLD"] == nil)        // its only market isn't TRADING
        #expect(result["USDC"] == nil)       // no USDC market in the fixture: never assumed equal to USDT or EUR
        #expect(result["EUR"]?.eur == 1)
    }

    @Test func zeroOrMalformedTickerPricesAreIgnored() throws {
        let result = try prices(["ETH"], tickers: #"[{"symbol":"ETHEUR","price":"0.00000000"},{"symbol":"BTCEUR","price":"abc"}]"#)
        #expect(result.isEmpty)
    }
}

// MARK: - Service, reconciliation and accounting

@MainActor
@Suite("Binance sync and accounting")
struct BinanceServiceTests {
    let container: ModelContainer
    let http = BinanceMockHTTP()
    let secrets = MemorySecrets()
    let defaults: UserDefaults
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try Persistence.makeInMemoryContainer()
        defaults = UserDefaults(suiteName: "WealthOSTests.binance.\(UUID().uuidString)")!
    }

    func makeService(connected: Bool = true) -> BinanceService {
        if connected {
            secrets.values["apiKey"] = "TESTKEY123"
            secrets.values["secretKey"] = "TESTSECRET456"
        }
        return BinanceService(http: http, secrets: secrets, defaults: defaults, sleep: { _ in })
    }

    var engine: FinanceEngine { DataMaintenance.makeEngine(context: context, baseCurrency: "EUR") }
    var rowCount: Int { (try? context.fetchCount(FetchDescriptor<BinanceHolding>())) ?? -1 }
    var snapshot: BinanceAccountSnapshot? { (try? context.fetch(FetchDescriptor<BinanceAccountSnapshot>()))?.first }
    func asset(_ name: String) -> BinanceAssetValue? { engine.binanceAssets.first { $0.asset == name } }

    // Expected EUR values for the default fixtures:
    // ETH (0.59118264 spot + 0.1 flexible + 0.25 locked) × 3000 = 2823.54792
    // BTC 0.00012345 × 60000 = 7.407 · USDT (100 spot + 50 flexible) × 0.8 = 120 · LDO 10 × 2 = 20 · XYZ unpriced
    static let expectedTotal = dec("2970.95492")

    @Test func connectChecksPermissionsAndStoresKeysOnlyInTheSecretStore() async throws {
        let service = makeService(connected: false)
        try await service.connect(apiKey: "TESTKEY123", secretKey: "TESTSECRET456", context: context, now: now)
        #expect(service.isConnected)
        #expect(secrets.values == ["apiKey": "TESTKEY123", "secretKey": "TESTSECRET456"])
        #expect(http.requests.first?.url?.path == BinanceEndpoint.apiRestrictions.path)
        #expect(rowCount > 0)
        for value in defaults.dictionaryRepresentation().values {
            #expect(!"\(value)".contains("TESTKEY123") && !"\(value)".contains("TESTSECRET456"))
        }
    }

    @Test func keysThatCanTradeOrWithdrawAreRefused() async {
        let service = makeService(connected: false)
        http.handler = { endpoint, _ in endpoint == .apiRestrictions ? (200, BinanceFixtures.withdrawalKey, [:]) : BinanceFixtures.reply(endpoint) }
        await #expect(throws: BinanceError.keyNotReadOnly(["withdrawals", "internal transfers", "spot & margin trading"])) {
            try await service.connect(apiKey: "TESTKEY123", secretKey: "TESTSECRET456", context: context, now: now)
        }
        #expect(!service.isConnected && secrets.values.isEmpty && rowCount == 0)
        #expect(http.count(.account) == 0)
    }

    @Test func keysWithoutReadingAndInvalidKeysAreRefused() async {
        let service = makeService(connected: false)
        http.handler = { endpoint, _ in endpoint == .apiRestrictions ? (200, BinanceFixtures.noReadKey, [:]) : BinanceFixtures.reply(endpoint) }
        await #expect(throws: BinanceError.missingPermission) {
            try await service.connect(apiKey: "TESTKEY123", secretKey: "TESTSECRET456", context: context, now: now)
        }
        http.handler = { _, _ in (401, #"{"code":-2015,"msg":"Invalid API-key, IP, or permissions for action."}"#, [:]) }
        await #expect(throws: BinanceError.invalidCredentials) {
            try await service.connect(apiKey: "TESTKEY123", secretKey: "TESTSECRET456", context: context, now: now)
        }
        #expect(secrets.values.isEmpty && rowCount == 0)
        await #expect(throws: BinanceError.missingCredentials) {
            try await service.connect(apiKey: "", secretKey: "x", context: context, now: now)
        }
    }

    @Test func fullSyncValuesEveryWalletOnceInEUR() async throws {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        let engine = engine
        let eth = try #require(asset("ETH"))
        #expect(eth.quantity == dec("0.94118264"))
        #expect(eth.spotQuantity == dec("0.59118264") && eth.earnQuantity == dec("0.35"))
        #expect(eth.wallets == [.spot, .flexible, .locked])
        #expect(eth.valueEUR == dec("2823.54792"))
        #expect(asset("USDT")?.quantity == 150)              // LDUSDT not added again
        #expect(asset("LDUSDT") == nil)
        #expect(asset("LDO")?.valueEUR == 20)               // real coin starting with "LD" kept
        #expect(snapshot?.mergedSpotAssets == "LDUSDT")
        #expect(engine.binanceTotalBase == Self.expectedTotal)
        #expect(engine.binanceSpotBase + engine.binanceEarnBase == Self.expectedTotal)
        #expect(engine.binanceSpotBase == dec("1880.95492"))
        #expect(engine.summary.netWorth == Self.expectedTotal)
        #expect(engine.summary.holdingsValue == Self.expectedTotal)
        // Unknown asset: listed by quantity, excluded from totals, never valued at zero.
        let xyz = try #require(asset("XYZ"))
        #expect(xyz.quantity == 5 && xyz.priceEUR == nil && xyz.valueEUR == nil && xyz.valueBase == nil)
        #expect(engine.binanceUnpriced.map(\.asset) == ["XYZ"])
        // No cost basis is invented: Binance adds value but no cost and no profit.
        #expect(engine.portfolioCostBasis == 0 && engine.portfolioUnrealized == 0)
        #expect(engine.positionsWithoutCost == engine.binanceAssets.count)
        #expect(engine.allocation.first { $0.assetClass == .crypto }?.value == Self.expectedTotal)
        #expect(snapshot?.flexibleStatus == .ok && snapshot?.lockedStatus == .ok)
        #expect(http.count(.tickerPrice) == 1)               // one request for all prices
    }

    @Test func repeatedSyncsAreIdempotent() async throws {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        let rows = rowCount
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(60)))
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(120)))
        #expect(rowCount == rows)
        #expect(try context.fetchCount(FetchDescriptor<BinanceAccountSnapshot>()) == 1)
        #expect(engine.binanceTotalBase == Self.expectedTotal)
        // The symbol list is cached; prices are fetched every sync.
        #expect(http.count(.exchangeInfo) == 1 && http.count(.tickerPrice) == 3)
    }

    @Test func movingFromSpotToEarnDoesNotChangeWealth() async throws {
        let service = makeService()
        http.handler = { endpoint, _ in
            switch endpoint {
            case .account: (200, BinanceFixtures.account(eth: "1.00000000"), [:])
            case .flexiblePositions, .lockedPositions: (200, BinanceFixtures.emptyPage, [:])
            default: BinanceFixtures.reply(endpoint)
            }
        }
        #expect(await service.sync(context: context, force: true, now: now))
        let before = engine.summary.netWorth
        // 0.4 ETH subscribed to Flexible Earn: Spot shrinks, Earn grows, total unchanged.
        http.handler = { endpoint, _ in
            switch endpoint {
            case .account: (200, BinanceFixtures.account(eth: "0.60000000"), [:])
            case .flexiblePositions: (200, #"{"rows":[{"asset":"ETH","totalAmount":"0.40000000","productId":"ETH001"}],"total":1}"#, [:])
            case .lockedPositions: (200, BinanceFixtures.emptyPage, [:])
            default: BinanceFixtures.reply(endpoint)
            }
        }
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(60)))
        #expect(asset("ETH")?.quantity == 1)
        #expect(engine.summary.netWorth == before)
        #expect(before == 3000)
        #expect(try context.fetchCount(FetchDescriptor<TransactionRecord>()) == 0)
    }

    @Test func depositsWithdrawalsAndPriceMovesCreateNoTransactions() async throws {
        let service = makeService()
        func sync(eth: String, price: String, at offset: TimeInterval) async -> Bool {
            http.handler = { endpoint, _ in
                switch endpoint {
                case .account: (200, BinanceFixtures.account(eth: eth), [:])
                case .flexiblePositions, .lockedPositions: (200, BinanceFixtures.emptyPage, [:])
                case .tickerPrice: (200, BinanceFixtures.tickers(eth: price), [:])
                default: BinanceFixtures.reply(endpoint)
                }
            }
            return await service.sync(context: context, force: true, now: now.addingTimeInterval(offset))
        }
        #expect(await sync(eth: "1", price: "3000", at: 0))
        #expect(await sync(eth: "2", price: "3000", at: 60))      // deposit from own wallet
        #expect(engine.summary.netWorth == 6000)
        #expect(await sync(eth: "2", price: "3300", at: 120))     // market move revalues
        #expect(engine.summary.netWorth == 6600)
        #expect(await sync(eth: "0.5", price: "3300", at: 180))   // withdrawal to own wallet
        #expect(engine.summary.netWorth == 1650)
        #expect(try context.fetchCount(FetchDescriptor<TransactionRecord>()) == 0)
        #expect(engine.cashFlow(forMonthContaining: now).income == 0)
    }

    @Test func unreadableEarnIsReportedAndLDRowsStayUncounted() async throws {
        let service = makeService()
        http.handler = { endpoint, _ in
            switch endpoint {
            case .flexiblePositions, .lockedPositions: (401, #"{"code":-2015,"msg":"Invalid API-key, IP, or permissions for action."}"#, [:])
            default: BinanceFixtures.reply(endpoint)
            }
        }
        #expect(await service.sync(context: context, force: true, now: now))
        #expect(service.lastError == nil)
        #expect(snapshot?.flexibleStatus == .unavailable && snapshot?.lockedStatus == .unavailable)
        #expect(service.warnings.count == 2)
        // LDUSDT can't be mapped safely without Earn data: shown, unpriced, not counted.
        #expect(asset("LDUSDT")?.priceEUR == nil)
        #expect(engine.binanceUnpriced.map(\.asset).sorted() == ["LDUSDT", "XYZ"])
        // Spot only: ETH 0.59118264 × 3000 + BTC 7.407 + USDT 80 + LDO 20
        #expect(engine.binanceTotalBase == dec("1880.95492"))
        #expect(engine.summary.incompleteSources.contains("Binance"))   // Earn unknown ≠ zero
    }

    @Test func temporaryEarnFailureKeepsPreviousPositions() async throws {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        http.handler = { endpoint, _ in
            endpoint == .lockedPositions ? (503, "", [:]) : BinanceFixtures.reply(endpoint)
        }
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(60)))
        #expect(snapshot?.lockedStatus == .failed)
        #expect(snapshot?.lockedSyncedAt == now)
        // Locked 0.25 ETH is kept and shown as last known, but not counted (AUD-001).
        let eth = try #require(asset("ETH"))
        #expect(eth.earnQuantity == dec("0.1") && eth.unconfirmedQuantity == dec("0.25"))
        #expect(eth.unconfirmedValueEUR == 750)
        #expect(rowCount == 8)                                   // nothing deleted
        #expect(engine.binanceTotalBase == Self.expectedTotal - 750)
        #expect(engine.summary.incompleteSources == ["Binance"])
        #expect(!engine.binanceIncompleteReasons.isEmpty)
        #expect(!service.warnings.isEmpty)
        #expect(service.automaticRetryAfter != nil)
        // The next successful sync confirms everything again.
        http.handler = { endpoint, _ in BinanceFixtures.reply(endpoint) }
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(600)))
        #expect(engine.binanceTotalBase == Self.expectedTotal)
        #expect(engine.summary.incompleteSources.isEmpty)
    }

    // MARK: AUD-001 — partial snapshots must never double count

    func syncSecond(account: String, flexible: BinanceMockHTTP.Reply, locked: BinanceMockHTTP.Reply,
                    service: BinanceService, at offset: TimeInterval = 60) async -> Bool {
        http.handler = { endpoint, _ in
            switch endpoint {
            case .account: (200, account, [:])
            case .flexiblePositions: flexible
            case .lockedPositions: locked
            default: BinanceFixtures.reply(endpoint)
            }
        }
        return await service.sync(context: context, force: true, now: now.addingTimeInterval(offset))
    }

    @Test func lockedRedemptionDuringLockedOutageIsCountedOnce() async throws {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        // 0.25 ETH left Locked Earn and is now in Spot (0.84118264); Locked Earn can't be read.
        #expect(await syncSecond(account: BinanceFixtures.account(eth: "0.75000000", locked: "0.09118264"),
                                 flexible: (200, BinanceFixtures.flexible, [:]), locked: (503, "", [:]), service: service))
        let eth = try #require(asset("ETH"))
        #expect(eth.quantity == dec("0.94118264"))              // true ownership, not 1.19118264
        #expect(eth.valueEUR == dec("2823.54792"))
        #expect(eth.unconfirmedQuantity == dec("0.25"))
        #expect(engine.summary.incompleteSources.contains("Binance"))
    }

    @Test func flexibleRedemptionDuringFlexibleOutageIsCountedOnce() async throws {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        // Redeemed 50 USDT to Spot (150, no more LDUSDT); Flexible Earn times out.
        let account = #"{"accountType":"SPOT","balances":[{"asset":"USDT","free":"150.00000000","locked":"0.00000000"}],"uid":354937868}"#
        #expect(await syncSecond(account: account, flexible: (503, "", [:]), locked: (200, BinanceFixtures.emptyPage, [:]), service: service))
        let usdt = try #require(asset("USDT"))
        #expect(usdt.quantity == 150 && usdt.valueEUR == 120)   // not 200 USDT
        #expect(usdt.unconfirmedQuantity == 50)
        #expect(snapshot?.flexibleStatus == .failed)
    }

    @Test func ldSpotRowIsNotMatchedAgainstStaleFlexibleData() async throws {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        // Spot still reports LDUSDT, Flexible fails: neither copy is counted, nothing is dropped silently.
        let account = #"{"accountType":"SPOT","balances":[{"asset":"USDT","free":"100.00000000","locked":"0.00000000"},{"asset":"LDUSDT","free":"50.00000000","locked":"0.00000000"}],"uid":354937868}"#
        #expect(await syncSecond(account: account, flexible: (503, "", [:]), locked: (200, BinanceFixtures.emptyPage, [:]), service: service))
        #expect(asset("USDT")?.quantity == 100 && asset("USDT")?.unconfirmedQuantity == 50)
        #expect(asset("LDUSDT")?.quantity == 50 && asset("LDUSDT")?.valueBase == nil)
        #expect(snapshot?.mergedSpotAssets == "")
        #expect(engine.binanceTotalBase == 80)
        #expect(engine.summary.incompleteSources.contains("Binance"))
    }

    @Test func revokedEarnPermissionMarksKeptPositionsUnconfirmed() async throws {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        let denied: BinanceMockHTTP.Reply = (401, #"{"code":-2015,"msg":"Invalid API-key, IP, or permissions for action."}"#, [:])
        #expect(await syncSecond(account: BinanceFixtures.account, flexible: denied, locked: denied, service: service))
        #expect(snapshot?.flexibleStatus == .unavailable && snapshot?.lockedStatus == .unavailable)
        #expect(asset("ETH")?.earnQuantity == 0 && asset("ETH")?.unconfirmedQuantity == dec("0.35"))
        #expect(engine.summary.incompleteSources.contains("Binance"))
        #expect(engine.binanceTotalBase == dec("1880.95492"))   // confirmed Spot only
    }

    @Test func depositDuringEarnOutageIsCounted() async throws {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        let before = try #require(asset("ETH")).quantity
        #expect(await syncSecond(account: BinanceFixtures.account(eth: "1.50000000", locked: "0.09118264"),
                                 flexible: (200, BinanceFixtures.flexible, [:]), locked: (503, "", [:]), service: service))
        // Spot rose by 1 ETH (deposit); only the unrefreshed Locked 0.25 is withheld.
        #expect(try #require(asset("ETH")).quantity == before + 1 - dec("0.25"))
    }

    @Test func successfulSyncIsCompleteAndCountsSpotAndEarn() async throws {
        #expect(await makeService().sync(context: context, force: true, now: now))
        #expect(engine.summary.incompleteSources.isEmpty)
        #expect(engine.binanceIncompleteReasons.isEmpty)
        #expect(engine.binanceAssets.allSatisfy { $0.unconfirmedQuantity == 0 })
        #expect(engine.binanceSpotBase + engine.binanceEarnBase == Self.expectedTotal)
    }

    @Test func accountFailureChangesNothing() async throws {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        let rows = rowCount
        let failures: [BinanceMockHTTP.Reply] = [(500, "", [:]), (200, "{not json", [:]), (403, "", [:])]
        for (index, failure) in failures.enumerated() {
            http.handler = { endpoint, _ in endpoint == .account ? failure : BinanceFixtures.reply(endpoint) }
            let before = http.count(.account)
            #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(3600 + Double(index) * 60)) == false)
            #expect(http.count(.account) > before)
        }
        #expect(rowCount == rows)
        #expect(snapshot?.syncedAt == now)
        #expect(engine.binanceTotalBase == Self.expectedTotal)
    }

    @Test func priceFailureKeepsCachedPricesMarkedWithTheirTime() async throws {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        http.handler = { endpoint, _ in endpoint == .tickerPrice ? (503, "", [:]) : BinanceFixtures.reply(endpoint) }
        let later = now.addingTimeInterval(600)
        #expect(await service.sync(context: context, force: true, now: later))
        let eth = try #require(asset("ETH"))
        #expect(eth.priceEUR == 3000 && eth.pricedAt == now)   // older than syncedAt → shown as cached
        #expect(snapshot?.syncedAt == later && snapshot?.pricesFetchedAt == now)
        #expect(service.warnings.contains { $0.contains("cached prices") })
    }

    @Test func offlineKeepsDataAndBacksOff() async throws {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        http.handler = { _, _ in throw URLError(.notConnectedToInternet) }
        let later = now.addingTimeInterval(BinanceService.staleInterval + 1)
        #expect(await service.sync(context: context, now: later) == false)
        #expect(service.lastError == .offline)
        #expect(engine.binanceTotalBase == Self.expectedTotal)
        let before = http.requests.count
        await service.syncIfStale(context: context, now: later.addingTimeInterval(15))
        await service.syncIfStale(context: context, now: later.addingTimeInterval(30))
        #expect(http.requests.count == before)
        http.handler = { endpoint, _ in BinanceFixtures.reply(endpoint) }
        #expect(await service.sync(context: context, now: later.addingTimeInterval(61)))
        #expect(service.lastError == nil)
    }

    @Test func freshDataAndRateLimitIntervalSkipRequests() async {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        let before = http.requests.count
        await service.syncIfStale(context: context, now: now.addingTimeInterval(60))
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(3)) == false)
        #expect(http.requests.count == before)
    }

    @Test func revokedKeyAndLaterAddedTradingPermissionStopSyncing() async {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        http.handler = { endpoint, _ in endpoint == .apiRestrictions ? (200, BinanceFixtures.withdrawalKey, [:]) : BinanceFixtures.reply(endpoint) }
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(60)) == false)
        #expect(service.needsReconnect)
        #expect(engine.binanceTotalBase == Self.expectedTotal)    // data kept
        let before = http.requests.count
        await service.syncIfStale(context: context, now: now.addingTimeInterval(7200))
        #expect(http.requests.count == before)
    }

    @Test func overlappingSyncsAreRefused() async {
        let service = makeService()
        http.gate = { try? await Task.sleep(for: .milliseconds(150)) }
        let first = Task { await service.sync(context: context, force: true, now: now) }
        for _ in 0..<100 where !service.isSyncing { await Task.yield() }
        #expect(service.isSyncing)
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(60)) == false)
        await #expect(throws: BinanceError.busy) {
            try await service.connect(apiKey: "TESTKEY123", secretKey: "TESTSECRET456", context: context, now: now)
        }
        #expect(await first.value)
        #expect(http.count(.account) == 1)
    }

    @Test func disconnectCancelsInFlightSyncAndDeletesKeys() async {
        let service = makeService()
        http.gate = { try? await Task.sleep(for: .milliseconds(150)) }
        let inFlight = Task { await service.sync(context: context, force: true, now: now) }
        for _ in 0..<100 where !service.isSyncing { await Task.yield() }
        try? service.disconnect(removeData: true, context: context)
        #expect(await inFlight.value == false)
        #expect(rowCount == 0 && snapshot == nil)
        #expect(secrets.values.isEmpty && !service.isConnected)
    }

    @Test func disconnectCanKeepOrRemoveCachedDataOnly() async throws {
        context.insert(Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 500))
        try context.save()
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        try service.disconnect(removeData: false, context: context)
        #expect(secrets.values.isEmpty && rowCount > 0)
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(60)) == false)
        try service.disconnect(removeData: true, context: context)
        #expect(rowCount == 0)
        #expect(engine.summary.netWorth == 500)
    }

    @Test func manualCryptoIsSuggestedButOnlyExcludedWhenLinked() async throws {
        let manualETH = Holding(name: "Ethereum", symbol: "ETH", assetClass: .crypto, currencyCode: "EUR", currentPrice: 3000)
        let wallet = Account(name: "Binance", kind: .crypto, currencyCode: "EUR", openingBalance: 2970)
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 1_000)
        context.insert(manualETH); context.insert(wallet); context.insert(checking)
        context.insert(InvestmentTrade(holdingID: manualETH.id, kind: .buy, date: Date.now.addingTimeInterval(-86_400 * 60),
                                       quantity: 1, pricePerUnit: 2000, fee: 0))
        try context.save()
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))

        let links = try context.fetch(FetchDescriptor<BinanceLink>())
        #expect(links.isEmpty)   // nothing linked automatically
        let assets = Set(engine.binanceAssets.map(\.asset))
        #expect(BinanceMatching.holdingCandidates(holdings: [manualETH], assets: assets, links: []).first?.asset == "ETH")
        #expect(BinanceMatching.accountCandidates(accounts: [wallet, checking], links: []).map(\.id) == [wallet.id])
        #expect(engine.summary.netWorth == 1000 + 2970 + 3000 + Self.expectedTotal)

        try Persistence.commit(context) {
            try BinanceReconciler.setLinked(true, kind: .holding, localID: manualETH.id, in: context)
            try BinanceReconciler.setLinked(true, kind: .account, localID: wallet.id, in: context)
        }
        let linked = engine
        #expect(linked.summary.netWorth == 1000 + Self.expectedTotal)
        #expect(linked.countedVia(manualETH) == "Binance" && linked.countedVia(wallet) == "Binance")
        #expect(linked.countedVia(checking) == nil)
        // The manual record and its cost basis are preserved, just not counted.
        #expect(linked.position(for: manualETH)?.position.costBasis == 2000)
        #expect(try context.fetchCount(FetchDescriptor<InvestmentTrade>()) == 1)
    }

    @Test func coexistsWithTrading212WithoutCrossCounting() async throws {
        let summary: T212AccountSummary = try T212Fixtures.decode(T212Fixtures.summary)
        let positions = try Trading212Parsing.parse(try T212Fixtures.decode(T212Fixtures.positions))
        try Persistence.commit(context) {
            try Trading212Reconciler.apply(summary: summary, positions: positions, instruments: nil, environment: .live, now: now, in: context)
        }
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        let both = engine
        #expect(both.brokerTotalBase == dec("1765.118"))
        #expect(both.binanceTotalBase == Self.expectedTotal)
        #expect(both.summary.netWorth == dec("1765.118") + Self.expectedTotal)

        try service.disconnect(removeData: true, context: context)
        #expect(engine.summary.netWorth == dec("1765.118"))
        #expect(try context.fetchCount(FetchDescriptor<BrokerPosition>()) == 2)

        #expect(await makeService().sync(context: context, force: true, now: now.addingTimeInterval(60)))
        try Persistence.commit(context) { try Trading212Reconciler.removeAllData(in: context) }
        #expect(engine.summary.netWorth == Self.expectedTotal)
    }

    @Test func goalsAndSimulatorSeeBinanceAfterSync() async throws {
        context.insert(Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 1_000))
        try context.save()
        let before = engine.summary
        #expect(GoalMath.overview(summary: before, goals: [(allocated: 500, target: 5_000)]).available == 1000)
        #expect(await makeService().sync(context: context, force: true, now: now))
        let after = engine.summary
        #expect(GoalMath.overview(summary: after, goals: [(allocated: 500, target: 5_000)]).available == 1000 + Self.expectedTotal)
        let simulator = SimulatorViewModel.liveStartingBalances(after)
        #expect(simulator.investments == Money.round(Self.expectedTotal))
        #expect(simulator.cash == 1000)
    }

    @Test func nonEURBaseCurrencyNeedsAnEURRate() async throws {
        #expect(await makeService().sync(context: context, force: true, now: now))
        let usd = DataMaintenance.makeEngine(context: context, baseCurrency: "USD")
        #expect(usd.summary.netWorth == 0)
        #expect(usd.summary.missingRateCurrencies.contains("EUR"))
        #expect(usd.binanceUnpriced.map(\.asset) == ["XYZ"])       // priced in EUR, just not convertible
        let converted = FinanceEngine(accounts: [], transactions: [], holdings: [], trades: [],
                                      converter: CurrencyConverter(baseCode: "USD", rates: ["EUR": dec("1.1")]),
                                      binance: usd.binance)
        #expect(converted.binanceTotalBase == Self.expectedTotal * dec("1.1"))
    }

    @Test func appInstanceInTestHostCannotReachKeychainOrNetwork() async {
        let service = BinanceService.makeForApp(environment: ["XCTestConfigurationFilePath": "/tmp/x"])
        #expect(!service.isConnected)
        #expect(await service.sync(context: context, force: true, now: now) == false)
        await #expect(throws: (any Error).self) {
            try await service.connect(apiKey: "TESTKEY123", secretKey: "TESTSECRET456", context: context, now: now)
        }
        #expect(!service.isConnected && rowCount == 0)
        #expect(!BinanceService.makeForApp(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]).isConnected)
    }

    @Test func backupRestoreKeepsTheBinanceCacheAndLinks() async throws {
        let manualETH = Holding(name: "Ethereum", symbol: "ETH", assetClass: .crypto, currencyCode: "EUR", currentPrice: 3000)
        context.insert(manualETH)
        try context.save()
        #expect(await makeService().sync(context: context, force: true, now: now))
        try Persistence.commit(context) { try BinanceReconciler.setLinked(true, kind: .holding, localID: manualETH.id, in: context) }
        let payload = try BackupService.makePayload(from: context, baseCurrency: "EUR", now: now)
        try BackupService.restore(payload, into: context)
        let restored = engine
        #expect(restored.binanceTotalBase == Self.expectedTotal)
        let holding = try #require(try context.fetch(FetchDescriptor<Holding>()).first)
        #expect(holding.id == manualETH.id)
        #expect(restored.countedVia(holding) == "Binance")
        #expect(restored.summary.netWorth == Self.expectedTotal)
    }
}

// MARK: - On-disk persistence

@MainActor
@Suite("Binance persistence")
struct BinancePersistenceTests {
    @Test func syncedDataSurvivesReopeningTheStore() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "BinanceStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let container = try Persistence.makePersistentContainer(directory: directory)
            let context = container.mainContext
            let row = BinanceHolding(key: "spot:ETH", asset: "ETH", wallet: .spot, syncedAt: .now)
            row.amount = dec("0.59118264")
            row.priceEUR = dec("3000.12345678")
            context.insert(row)
            context.insert(BinanceAccountSnapshot(syncedAt: .now))
            context.insert(BinanceLink(kind: .holding, localID: UUID()))
            try context.save()
        }
        let reopened = try Persistence.makePersistentContainer(directory: directory)
        let rows = try reopened.mainContext.fetch(FetchDescriptor<BinanceHolding>())
        #expect(rows.count == 1)
        #expect(rows.first?.amount == dec("0.59118264"))
        #expect(rows.first?.priceEUR == dec("3000.12345678"))
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<BinanceAccountSnapshot>()) == 1)
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<BinanceLink>()) == 1)
    }
}
