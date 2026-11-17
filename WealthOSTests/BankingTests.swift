import Foundation
import SwiftData
import Testing
@testable import WealthOS

// Bank (Enable Banking via the WealthOS backend) integration. Everything runs against an
// in-memory store, an in-memory secret store and a mock transport: no network, no Keychain,
// no real bank and no real WealthOS data is ever touched.

// MARK: - Test doubles

final class BankMockHTTP: BankingHTTPClient, @unchecked Sendable {
    typealias Reply = (status: Int, body: String)
    /// `@Sendable`: the client calls the transport off the main actor.
    var handler: @Sendable (URLRequest) throws -> Reply = { _ in (404, #"{"error":"not_found"}"#) }
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Same validation as the real transport: a test fails if the app builds a request it
        // would refuse to send (e.g. anything that isn't an allow-listed read-only route).
        try BankingClient.validate(request, allowedHost: request.url?.host ?? "")
        requests.append(request)
        let reply = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Retry-After": "120"])!
        return (Data(reply.body.utf8), response)
    }

    func count(_ fragment: String) -> Int { requests.filter { $0.url?.path.contains(fragment) == true }.count }
}

nonisolated final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

nonisolated enum BankFixtures {
    static let keyA = String(repeating: "a", count: 64)
    static let keyB = String(repeating: "b", count: 64)
    static let secret = String(repeating: "s", count: 64)

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func day(_ text: String) -> Date { BankDay.date(text, calendar: calendar)! }
    static let now = day("2026-11-15")
    static let importStart = day("2026-11-01")

    static func tx(id: String? = nil, ref: String? = nil, status: String = "BOOK", indicator: String? = "DBIT",
                   amount: String, currency: String = "EUR", booking: String? = "2026-11-05", transactionDate: String? = nil,
                   name: String? = nil, counterpartyHash: String? = nil, remittance: [String]? = nil,
                   code: String? = nil, mcc: String? = nil) -> BankTransactionDTO {
        BankTransactionDTO(transactionID: id, entryReference: ref, status: status, creditDebitIndicator: indicator,
                           amount: amount, currency: currency, bookingDate: booking, valueDate: nil,
                           transactionDate: transactionDate, counterpartyName: name, counterpartyAccountHash: counterpartyHash,
                           counterpartyAccountMasked: nil, remittance: remittance, referenceNumber: nil,
                           bankTransactionCode: code, merchantCategoryCode: mcc)
    }

    static func json(_ object: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    static func connection(id: String = "conn-1", validUntil: String = "2027-05-01T00:00:00+00:00",
                           accounts: [(uid: String, key: String, currency: String)] = [("acc-1", keyA, "EUR")]) -> String {
        json(["connection_id": id, "aspsp": ["name": "Swedbank", "country": "LV"], "valid_until": validUntil,
              "accounts": accounts.map { ["uid": $0.uid, "account_key": $0.key, "display_name": "Main account",
                                          "masked_identifier": "LV** **** 1234", "currency": $0.currency,
                                          "cash_account_type": "CACC"] }])
    }

    static func balances(_ amount: String, type: String = "ITBD", currency: String = "EUR") -> String {
        json(["balances": [["name": "b", "amount": amount, "currency": currency, "balance_type": type,
                            "reference_date": "2026-11-15"]]])
    }

    static func page(_ rows: [[String: Any]], next: String? = nil) -> String {
        var object: [String: Any] = ["transactions": rows]
        if let next { object["continuation_key"] = next }
        return json(object)
    }

    static func row(id: String, amount: String, indicator: String = "DBIT", status: String = "BOOK",
                    booking: String = "2026-11-05", mcc: String? = nil, name: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["transaction_id": id, "amount": amount, "currency": "EUR", "status": status,
                                  "credit_debit_indicator": indicator, "booking_date": booking]
        if let mcc { row["merchant_category_code"] = mcc }
        if let name { row["counterparty_name"] = name }
        return row
    }
}

/// An in-memory store with one manual EUR account linked to a connected bank account.
@MainActor
struct BankStore {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let account: Account
    let link: BankAccountLink
    let connection: BankConnection

    init(opening: Decimal = 1000, accountKey: String = BankFixtures.keyA, importStart: Date = BankFixtures.importStart) throws {
        container = try Persistence.makeInMemoryContainer()
        let context = container.mainContext
        LedgerService.seedDefaultCategoriesIfNeeded(in: context)
        account = Account(name: "Swedbank (manual)", kind: .checking, currencyCode: "EUR", openingBalance: opening,
                          openingDate: BankFixtures.day("2026-01-01"))
        context.insert(account)
        connection = BankConnection(aspspName: "Swedbank", aspspCountry: "LV", backendConnectionID: "conn-1",
                                    // Far future: the engine checks consent validity against the real clock.
                                    validUntil: BankFixtures.day("2099-01-01"))
        context.insert(connection)
        link = BankAccountLink(accountKey: accountKey, aspspName: "Swedbank", aspspCountry: "LV")
        link.connectionID = connection.id
        link.providerAccountUID = "acc-1"
        link.currencyCode = "EUR"
        link.cashAccountType = "CACC"
        link.localAccountID = account.id
        link.importStartDate = importStart
        context.insert(link)
        try context.save()
    }

    @discardableResult
    func apply(_ rows: [BankTransactionDTO]) throws -> BankReconciler.Outcome {
        var outcome = BankReconciler.Outcome()
        try Persistence.commit(context) {
            outcome = try BankReconciler.apply(BankParsing.parse(rows), link: link, now: BankFixtures.now,
                                               calendar: BankFixtures.calendar, in: context)
        }
        return outcome
    }

    func records() throws -> [TransactionRecord] { try context.fetch(FetchDescriptor<TransactionRecord>()) }
    func imported() throws -> [TransactionRecord] { try records().filter(BankReconciler.isBankImport) }
    func rows() throws -> [BankTransaction] { try context.fetch(FetchDescriptor<BankTransaction>()) }
    func engine() -> FinanceEngine { DataMaintenance.makeEngine(context: context, baseCurrency: "EUR") }
}

@MainActor
func makeBankService(http: BankMockHTTP) throws -> BankingService {
    let service = BankingService(secrets: MemorySecrets(), defaults: UserDefaults(suiteName: "bank-tests-\(UUID().uuidString)")!,
                                 makeHTTP: { _ in http })
    service.calendar = BankFixtures.calendar
    try service.configure(backendURL: "http://localhost:8787", clientID: "ios-test", clientSecret: BankFixtures.secret)
    return service
}

// MARK: - Authorization callback

@Suite("Bank authorization callback")
struct BankCallbackTests {
    @Test func acceptsOnlyTheExpectedAttempt() throws {
        let ok = try BankCallback.parse(URL(string: "wealthos://bank-callback?attempt=att_1&result=success")!, expectedAttemptID: "att_1")
        #expect(ok.result == .success)
        #expect(throws: BankingError.invalidCallback) {
            try BankCallback.parse(URL(string: "wealthos://bank-callback?attempt=att_2&result=success")!, expectedAttemptID: "att_1")
        }
        #expect(throws: BankingError.invalidCallback) {
            try BankCallback.parse(URL(string: "wealthos://bank-callback?attempt=att_1&result=success")!, expectedAttemptID: "")
        }
    }

    @Test func rejectsForeignSchemesHostsAndPaths() {
        for text in ["https://bank-callback?attempt=a&result=success", "wealthos://evil?attempt=a&result=success",
                     "wealthos://bank-callback/extra?attempt=a&result=success", "otherapp://bank-callback?attempt=a&result=success"] {
            #expect(throws: BankingError.invalidCallback) { try BankCallback.parse(URL(string: text)!, expectedAttemptID: "a") }
        }
    }

    @Test func rejectsRepeatedOrMissingParameters() {
        #expect(throws: BankingError.invalidCallback) {
            try BankCallback.parse(URL(string: "wealthos://bank-callback?attempt=a&attempt=b&result=success")!, expectedAttemptID: "a")
        }
        #expect(throws: BankingError.invalidCallback) {
            try BankCallback.parse(URL(string: "wealthos://bank-callback?attempt=a")!, expectedAttemptID: "a")
        }
        #expect(throws: BankingError.invalidCallback) {
            try BankCallback.parse(URL(string: "wealthos://bank-callback?attempt=a&result=maybe")!, expectedAttemptID: "a")
        }
    }

    @Test func mapsBankErrors() throws {
        let denied = try BankCallback.parse(URL(string: "wealthos://bank-callback?attempt=a&result=error&error=access_denied")!,
                                            expectedAttemptID: "a")
        #expect(denied.result == .rejected)
        let cancelled = try BankCallback.parse(URL(string: "wealthos://bank-callback?attempt=a&result=error&error=cancelled")!,
                                               expectedAttemptID: "a")
        #expect(cancelled.result == .cancelled)
        let other = try BankCallback.parse(URL(string: "wealthos://bank-callback?attempt=a&result=error&error=server_error")!,
                                           expectedAttemptID: "a")
        #expect(other.result == .failed)
    }
}

// MARK: - Connect flow and consent

@Suite("Bank connection flow")
@MainActor
struct BankConnectionFlowTests {
    func route(_ http: BankMockHTTP, connection: String = BankFixtures.connection()) {
        http.handler = { request in
            switch request.url?.path ?? "" {
            case "/v1/auth/start":
                (200, #"{"attempt_id":"att_1","authorization_url":"https://tilisy.enablebanking.com/auth?x=1","expires_at":"2026-11-15T12:15:00Z"}"#)
            case "/v1/auth/complete": (200, connection)
            default: (404, #"{"error":"not_found"}"#)
            }
        }
    }

    @Test func successfulAuthorizationCreatesUnlinkedAccounts() async throws {
        let http = BankMockHTTP()
        route(http)
        let service = try makeBankService(http: http)
        let container = try Persistence.makeInMemoryContainer()
        let url = try await service.beginConnection(now: BankFixtures.now)
        #expect(url.host == "tilisy.enablebanking.com")
        try await service.finishConnection(callbackURL: URL(string: "wealthos://bank-callback?attempt=att_1&result=success")!,
                                           context: container.mainContext, now: BankFixtures.now)
        let links = try container.mainContext.fetch(FetchDescriptor<BankAccountLink>())
        #expect(links.count == 1)
        #expect(links[0].localAccountID == nil) // never linked or counted automatically
        #expect(try container.mainContext.fetch(FetchDescriptor<Account>()).isEmpty)
        // Every request was signed and carried no secret.
        for request in http.requests {
            #expect(request.value(forHTTPHeaderField: "X-WOS-Signature") != nil)
            #expect(!(request.allHTTPHeaderFields ?? [:]).values.contains(BankFixtures.secret))
        }
    }

    @Test func callbackCannotBeReplayed() async throws {
        let http = BankMockHTTP()
        route(http)
        let service = try makeBankService(http: http)
        let container = try Persistence.makeInMemoryContainer()
        _ = try await service.beginConnection(now: BankFixtures.now)
        let callback = URL(string: "wealthos://bank-callback?attempt=att_1&result=success")!
        try await service.finishConnection(callbackURL: callback, context: container.mainContext, now: BankFixtures.now)
        await #expect(throws: BankingError.invalidCallback) {
            try await service.finishConnection(callbackURL: callback, context: container.mainContext, now: BankFixtures.now)
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<BankConnection>()).count == 1)
    }

    @Test func rejectedAuthorizationChangesNothing() async throws {
        let http = BankMockHTTP()
        route(http)
        let service = try makeBankService(http: http)
        let container = try Persistence.makeInMemoryContainer()
        _ = try await service.beginConnection(now: BankFixtures.now)
        await #expect(throws: BankingError.authorizationRejected) {
            try await service.finishConnection(
                callbackURL: URL(string: "wealthos://bank-callback?attempt=att_1&result=error&error=access_denied")!,
                context: container.mainContext, now: BankFixtures.now)
        }
        #expect(http.count("/v1/auth/complete") == 0)
        #expect(try container.mainContext.fetch(FetchDescriptor<BankConnection>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<BankAccountLink>()).isEmpty)
    }

    @Test func expiredAttemptIsRefused() async throws {
        let http = BankMockHTTP()
        route(http)
        let service = try makeBankService(http: http)
        let container = try Persistence.makeInMemoryContainer()
        _ = try await service.beginConnection(now: BankFixtures.now)
        await #expect(throws: BankingError.attemptExpired) {
            try await service.finishConnection(callbackURL: URL(string: "wealthos://bank-callback?attempt=att_1&result=success")!,
                                               context: container.mainContext, now: BankFixtures.now.addingTimeInterval(3600))
        }
    }

    @Test func reconnectKeepsLinksAndHistory() async throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "t1", amount: "5.00", mcc: "5411")])
        let dto = try JSONDecoder().decode(BankConnectionDTO.self,
                                           from: Data(BankFixtures.connection(id: "conn-2", accounts: [("acc-NEW", BankFixtures.keyA, "EUR")]).utf8))
        store.context.delete(store.connection)
        try BankConnectionStore.upsert(dto, now: BankFixtures.now, context: store.context)
        let links = try store.context.fetch(FetchDescriptor<BankAccountLink>())
        #expect(links.count == 1)
        #expect(links[0].localAccountID == store.account.id)
        #expect(links[0].providerAccountUID == "acc-NEW")
        try store.apply([BankFixtures.tx(id: "t1", amount: "5.00", mcc: "5411")])
        #expect(try store.imported().count == 1)
    }

    @Test func expiredConsentIsNotUsedAndKeepsTheBalance() async throws {
        let http = BankMockHTTP()
        let store = try BankStore()
        store.link.balanceAmount = 1500
        store.connection.validUntil = BankFixtures.day("2026-11-10")
        try store.context.save()
        let service = try makeBankService(http: http)
        let saved = await service.sync(context: store.context, force: true, now: BankFixtures.now)
        #expect(!saved)
        #expect(http.requests.isEmpty)
        #expect(store.connection.status == .expired)
        #expect(service.lastError == .consentExpired)
        #expect(store.engine().balance(of: store.account) == 1500)
        #expect(store.engine().summary.incompleteSources.contains("Swedbank"))
    }

    @Test func consentExpiredAtTheBankMarksConnection() async throws {
        let http = BankMockHTTP()
        http.handler = { _ in (410, #"{"error":"consent_expired"}"#) }
        let store = try BankStore()
        let service = try makeBankService(http: http)
        await service.sync(context: store.context, force: true, now: BankFixtures.now)
        #expect(store.connection.status == .expired)
        #expect(service.accountErrors[store.link.id] == .consentExpired)
    }
}

// MARK: - Client, transport, pagination

@Suite("Bank client")
@MainActor
struct BankClientTests {
    func client(_ http: BankMockHTTP) -> BankingClient {
        var client = BankingClient(config: BankingBackendConfig(string: "http://localhost:8787")!,
                                   credentials: BankingCredentials(clientID: "ios", clientSecret: BankFixtures.secret), http: http)
        client.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        return client
    }

    @Test func followsContinuationKeysAcrossPages() async throws {
        let http = BankMockHTTP()
        http.handler = { request in
            let query = request.url?.query ?? ""
            if query.contains("continuation_key=k%2B2") {
                return (200, BankFixtures.page([BankFixtures.row(id: "t3", amount: "3.00")]))
            }
            if query.contains("continuation_key=k1") {
                return (200, BankFixtures.page([BankFixtures.row(id: "t2", amount: "2.00")], next: "k+2"))
            }
            return (200, BankFixtures.page([BankFixtures.row(id: "t1", amount: "1.00")], next: "k1"))
        }
        let rows = try await client(http).transactions(connectionID: "c1", accountUID: "a1", dateFrom: "2026-11-01")
        #expect(rows.map(\.transactionID) == ["t1", "t2", "t3"])
        #expect(http.requests.count == 3)
    }

    @Test func loopingContinuationKeyFails() async throws {
        let http = BankMockHTTP()
        http.handler = { _ in (200, BankFixtures.page([], next: "same")) }
        await #expect(throws: BankingError.invalidResponse) {
            try await client(http).transactions(connectionID: "c1", accountUID: "a1", dateFrom: "2026-11-01")
        }
    }

    @Test func pageLimitFails() async throws {
        let http = BankMockHTTP()
        let counter = Box(0)
        http.handler = { _ in counter.value += 1; return (200, BankFixtures.page([], next: "k\(counter.value)")) }
        var limited = client(http)
        limited.maxPages = 3
        await #expect(throws: BankingError.tooManyPages) {
            try await limited.transactions(connectionID: "c1", accountUID: "a1", dateFrom: "2026-11-01")
        }
    }

    @Test func refusesNonAllowlistedRoutesAndInsecureHosts() throws {
        for (method, path) in [("POST", "/v1/payments"), ("GET", "/v1/aspsps"), ("POST", "/v1/connections/c1"),
                               ("GET", "/v1/connections/../admin")] {
            var request = URLRequest(url: URL(string: "http://localhost:8787\(path)")!)
            request.httpMethod = method
            #expect(throws: BankingError.blockedRequest) { try BankingClient.validate(request, allowedHost: "localhost") }
        }
        #expect(BankingBackendConfig(string: "http://banking.example.com") == nil)
        #expect(BankingBackendConfig(string: "https://user:pw@banking.example.com") == nil)
        #expect(BankingBackendConfig(string: "https://banking.example.com") != nil)
        #expect(BankingBackendConfig(string: "http://localhost:8787") != nil)
    }

    @Test func mapsRateLimitsAndServerErrors() {
        func map(_ status: Int, _ body: String) -> BankingError {
            BankingClient.mapStatus(HTTPURLResponse(url: URL(string: "http://localhost")!, statusCode: status, httpVersion: nil,
                                                    headerFields: ["Retry-After": "90"])!, data: Data(body.utf8))
        }
        #expect(map(429, "{}") == .rateLimited(retryAfter: 90))
        #expect(map(401, "{}") == .unauthorized)
        #expect(map(410, #"{"error":"consent_expired"}"#) == .consentExpired)
        #expect(map(403, #"{"error":"consent_revoked"}"#) == .consentRevoked)
        #expect(map(503, "{}") == .bankUnavailable)
    }

    @Test func signatureCoversMethodPathBodyAndNonce() {
        let base = BankingClient.signature(secret: "k", method: "GET", pathAndQuery: "/v1/x", timestamp: "1", nonce: "n", body: Data())
        #expect(base != BankingClient.signature(secret: "k", method: "POST", pathAndQuery: "/v1/x", timestamp: "1", nonce: "n", body: Data()))
        #expect(base != BankingClient.signature(secret: "k", method: "GET", pathAndQuery: "/v1/y", timestamp: "1", nonce: "n", body: Data()))
        #expect(base != BankingClient.signature(secret: "k", method: "GET", pathAndQuery: "/v1/x", timestamp: "2", nonce: "n", body: Data()))
        #expect(base != BankingClient.signature(secret: "k", method: "GET", pathAndQuery: "/v1/x", timestamp: "1", nonce: "m", body: Data()))
        #expect(base != BankingClient.signature(secret: "k", method: "GET", pathAndQuery: "/v1/x", timestamp: "1", nonce: "n", body: Data("x".utf8)))
        #expect(BankingClient.encode("a+b/= ") == "a%2Bb%2F%3D%20")
    }

    /// Cross-language test vectors. The SAME constants are asserted in
    /// backend/tests/test_backend.py (`test_signature_matches_cross_language_test_vectors`); the
    /// expected values were computed independently with `openssl dgst -sha256 -hmac`, so an
    /// interoperability break on either side fails both suites.
    static let crossLanguageSecret = String(repeating: "0123456789abcdef", count: 4)
    static let crossLanguagePost = "aOL+10RprGLFWsBP5tLOaEMDSVe3qljqYrwU/gJZ3eM="
    static let crossLanguageGet = "v72Ml1hXFJjx+wNu+XO/btKklVu3qYBay+Y0UYdhBpY="

    @Test func signatureMatchesCrossLanguageTestVectors() {
        #expect(BankingClient.signature(secret: Self.crossLanguageSecret, method: "POST", pathAndQuery: "/v1/auth/complete",
                                        timestamp: "1800000000", nonce: "nonce-00000001",
                                        body: Data(#"{"attempt_id":"att_123"}"#.utf8)) == Self.crossLanguagePost)
        #expect(BankingClient.signature(secret: Self.crossLanguageSecret, method: "GET",
                                        pathAndQuery: "/v1/connections/con_abc/accounts/acc-1/transactions?date_from=2026-11-01&continuation_key=next%2B%2F%3D",
                                        timestamp: "1800000000", nonce: "nonce-00000002", body: Data()) == Self.crossLanguageGet)
    }

    /// End to end through the real request builder: the headers the app actually sends carry the
    /// vector signatures (body serialisation, path and query encoding included).
    @Test func sentRequestsCarryCrossLanguageVectorSignatures() async throws {
        func vectorClient(_ http: BankMockHTTP, nonce: String) -> BankingClient {
            var client = BankingClient(config: BankingBackendConfig(string: "http://localhost:8787")!,
                                       credentials: BankingCredentials(clientID: "wealthos-ios", clientSecret: Self.crossLanguageSecret),
                                       http: http)
            client.now = { Date(timeIntervalSince1970: 1_800_000_000) }
            client.nonce = { nonce }
            return client
        }

        let post = BankMockHTTP()
        post.handler = { _ in (404, #"{"error":"not_found"}"#) }
        _ = try? await vectorClient(post, nonce: "nonce-00000001").completeAuthorization(attemptID: "att_123")
        let sentPost = try #require(post.requests.first)
        #expect(sentPost.httpBody == Data(#"{"attempt_id":"att_123"}"#.utf8))
        #expect(sentPost.value(forHTTPHeaderField: "X-WOS-Signature") == Self.crossLanguagePost)

        let get = BankMockHTTP()
        get.handler = { request in
            request.url?.query?.contains("continuation_key") == true
                ? (200, BankFixtures.page([]))
                : (200, BankFixtures.page([], next: "next+/="))
        }
        _ = try await vectorClient(get, nonce: "nonce-00000002")
            .transactions(connectionID: "con_abc", accountUID: "acc-1", dateFrom: "2026-11-01")
        #expect(get.requests.count == 2)
        let sentGet = try #require(get.requests.last)
        #expect(sentGet.url?.path == "/v1/connections/con_abc/accounts/acc-1/transactions")
        #expect(sentGet.url?.query == "date_from=2026-11-01&continuation_key=next%2B%2F%3D")
        #expect(sentGet.value(forHTTPHeaderField: "X-WOS-Signature") == Self.crossLanguageGet)
    }

    /// Replay protection on the client side: every request (retries and pages included) carries a
    /// fresh nonce in the format the backend accepts (`[A-Za-z0-9-]{8,64}`), so the server's
    /// single-use nonce check never rejects a legitimate request and a captured one can't be reused.
    @Test func everyRequestCarriesAFreshWellFormedNonce() async throws {
        let http = BankMockHTTP()
        let counter = Box(0)
        http.handler = { _ in
            counter.value += 1
            return (200, BankFixtures.page([], next: counter.value < 4 ? "k\(counter.value)" : nil))
        }
        _ = try await client(http).transactions(connectionID: "c1", accountUID: "a1", dateFrom: "2026-11-01")
        let nonces = http.requests.compactMap { $0.value(forHTTPHeaderField: "X-WOS-Nonce") }
        #expect(nonces.count == 4)
        #expect(Set(nonces).count == nonces.count)
        for nonce in nonces {
            #expect(nonce.range(of: #"^[A-Za-z0-9-]{8,64}$"#, options: .regularExpression) != nil)
        }
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-WOS-Timestamp") == "1800000000" })
    }
}

// MARK: - Parsing: balances, decimals, currencies

@Suite("Bank parsing")
struct BankParsingTests {
    @Test func decimalsAreExactAndStrict() {
        let a = BankAmount.parse("0.10")!, b = BankAmount.parse("0.20")!
        #expect(a + b == Decimal(string: "0.3", locale: Locale(identifier: "en_US_POSIX"))!)
        #expect(BankAmount.parse("12345678901234.99")! == Decimal(string: "12345678901234.99", locale: Locale(identifier: "en_US_POSIX"))!)
        #expect(BankAmount.parse("-5.5") == Decimal(-55) / 10)
        for bad in ["1e5", "1,50", "12.3.4", "", " ", "NaN", "0x10", "1 000.00", ".5"] {
            #expect(BankAmount.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func prefersBookedBalanceOverAvailable() throws {
        let balances = [
            BankBalanceDTO(name: nil, amount: "2500.00", currency: "EUR", balanceType: "ITAV", referenceDate: "2026-11-15"),
            BankBalanceDTO(name: nil, amount: "1200.55", currency: "EUR", balanceType: "ITBD", referenceDate: "2026-11-15"),
            BankBalanceDTO(name: nil, amount: "1300.00", currency: "EUR", balanceType: "XPCD", referenceDate: "2026-11-15"),
        ]
        let selected = try BankBalanceSelection.select(balances, currency: "EUR", creditLimit: nil)
        #expect(selected.amount == Decimal(string: "1200.55", locale: Locale(identifier: "en_US_POSIX"))!)
        #expect(selected.type == .interimBooked)
    }

    @Test func availableBalanceAloneIsNotTrustedWithPossibleCreditLimit() throws {
        let available = [BankBalanceDTO(name: nil, amount: "2500.00", currency: "EUR", balanceType: "ITAV", referenceDate: "2026-11-15")]
        #expect(throws: BankingError.noConfirmedBalance) { try BankBalanceSelection.select(available, currency: "EUR", creditLimit: nil) }
        #expect(try BankBalanceSelection.select(available, currency: "EUR", creditLimit: 0).amount == 2500)
    }

    @Test func expectedBalanceIsAFallback() throws {
        let balances = [BankBalanceDTO(name: nil, amount: "99.99", currency: "EUR", balanceType: "XPCD", referenceDate: nil)]
        #expect(try BankBalanceSelection.select(balances, currency: "EUR", creditLimit: nil).type == .expected)
    }

    @Test func balanceInAnotherCurrencyIsRejected() {
        let balances = [BankBalanceDTO(name: nil, amount: "10", currency: "USD", balanceType: "ITBD", referenceDate: nil)]
        #expect(throws: BankingError.currencyMismatch) { try BankBalanceSelection.select(balances, currency: "EUR", creditLimit: nil) }
        #expect(throws: BankingError.noConfirmedBalance) { try BankBalanceSelection.select([], currency: "EUR", creditLimit: nil) }
    }

    @Test func directionComesFromIndicator() {
        let result = BankParsing.parse([
            BankFixtures.tx(id: "1", indicator: "DBIT", amount: "10.00"),
            BankFixtures.tx(id: "2", indicator: "CRDT", amount: "10.00"),
            BankFixtures.tx(id: "3", indicator: "DBIT", amount: "-10.00"),
            BankFixtures.tx(id: "4", indicator: nil, amount: "10.00"),
        ])
        #expect(result.transactions.map(\.amount) == [-10, 10, -10, 10])
        #expect(result.transactions.map(\.directionKnown) == [true, true, true, false])
    }

    @Test func unreadableRowsAreCountedNotGuessed() {
        let result = BankParsing.parse([
            BankFixtures.tx(id: "1", amount: "abc"),
            BankFixtures.tx(id: "2", amount: "1.00", currency: "eur"),
            BankFixtures.tx(id: "3", status: "OTHR", amount: "1.00"),
            BankFixtures.tx(id: "4", amount: "1.00", booking: nil),
            BankFixtures.tx(id: "5", amount: "1.00", booking: "05/11/2026"),
            BankFixtures.tx(id: "6", amount: "1.00"),
        ])
        #expect(result.skipped == 5)
        #expect(result.transactions.map(\.providerTransactionID) == ["6"])
    }

    @Test func identicalRowsWithoutIDsStayDistinct() {
        let row = BankFixtures.tx(amount: "3.50", name: "Coffee")
        let result = BankParsing.parse([row, row])
        #expect(result.transactions.count == 2)
        #expect(Set(result.transactions.map(\.identity)).count == 2)
        #expect(result.transactions.map(\.occurrence) == [0, 1])
    }

    @Test func conflictingDuplicateIDsFallBackToFingerprints() {
        let result = BankParsing.parse([BankFixtures.tx(id: "X", amount: "1.00"), BankFixtures.tx(id: "X", amount: "2.00"),
                                        BankFixtures.tx(id: "Y", amount: "1.00"), BankFixtures.tx(id: "Y", amount: "1.00")])
        #expect(result.transactions.count == 3)
        #expect(result.transactions.filter { $0.identityKind == .fingerprint }.count == 2)
    }
}

// MARK: - Reconciliation and idempotency

@Suite("Bank reconciliation")
@MainActor
struct BankReconciliationTests {
    @Test func secondSyncCreatesNoDuplicates() throws {
        let store = try BankStore()
        let rows = [BankFixtures.tx(id: "t1", amount: "12.30", mcc: "5411"), BankFixtures.tx(id: "t2", amount: "4.00", code: "PMNT|CCRD|POSD")]
        let first = try store.apply(rows)
        #expect(first.imported == 2)
        let second = try store.apply(rows)
        #expect(second.imported == 0 && second.newRows == 0)
        #expect(try store.imported().count == 2)
        #expect(try store.rows().count == 2)
    }

    @Test func overlappingWindowsAndRetriesAreIdempotent() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "a", amount: "1.00", booking: "2026-11-02", mcc: "5411"),
                         BankFixtures.tx(id: "b", amount: "2.00", booking: "2026-11-03", mcc: "5411")])
        try store.apply([BankFixtures.tx(id: "b", amount: "2.00", booking: "2026-11-03", mcc: "5411"),
                         BankFixtures.tx(id: "c", amount: "3.00", booking: "2026-11-04", mcc: "5411")])
        #expect(try store.imported().map(\.amount).sorted() == [1, 2, 3])
    }

    @Test func pendingNeverEntersTheLedgerAndBookedCountsOnce() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "p1", status: "PDNG", amount: "20.00", mcc: "5812")])
        #expect(try store.records().isEmpty)
        #expect(try store.rows().first?.resolution == .pending)
        // Booked under a different id: the pending row disappears, one record is created.
        try store.apply([BankFixtures.tx(id: "b1", amount: "20.00", mcc: "5812")])
        #expect(try store.imported().count == 1)
        #expect(try store.rows().count == 1)
        #expect(try store.rows().first?.status == .booked)
    }

    @Test func pendingTurningBookedWithSameIDUpdatesInPlace() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "same", status: "PDNG", amount: "20.00", mcc: "5812")])
        try store.apply([BankFixtures.tx(id: "same", amount: "20.00", mcc: "5812")])
        try store.apply([BankFixtures.tx(id: "same", amount: "20.00", mcc: "5812")])
        #expect(try store.imported().count == 1)
        #expect(try store.rows().count == 1)
    }

    @Test func bookedEntryChangedByBankIsFlaggedNotRewritten() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "t1", amount: "10.00", mcc: "5411")])
        let outcome = try store.apply([BankFixtures.tx(id: "t1", amount: "11.00", mcc: "5411")])
        #expect(outcome.changedAfterImport == 1)
        #expect(try store.imported().map(\.amount) == [10])
        #expect(try store.rows().first?.bankDataChanged == true)
    }

    @Test func transactionsBeforeImportStartAreIgnored() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "old", amount: "9.00", booking: "2026-10-30", mcc: "5411")])
        #expect(try store.rows().isEmpty)
        #expect(try store.records().isEmpty)
    }

    @Test func userEditsAndDeletionsSurviveResync() throws {
        let store = try BankStore()
        let rows = [BankFixtures.tx(id: "t1", amount: "10.00", mcc: "5411"), BankFixtures.tx(id: "t2", amount: "5.00", mcc: "5411")]
        try store.apply(rows)
        let records = try store.imported().sorted { $0.amount < $1.amount }
        records[1].note = "Groceries — edited"
        store.context.delete(records[0])
        try store.context.save()
        try store.apply(rows)
        let after = try store.imported()
        #expect(after.count == 1)
        #expect(after.first?.note == "Groceries — edited")
    }

    @Test func identicalTwinWithoutIDGoesToReview() throws {
        let store = try BankStore()
        let row = BankFixtures.tx(amount: "3.50", name: "Coffee", mcc: "5814")
        try store.apply([row, row])
        #expect(try store.imported().count == 1)
        #expect(try store.rows().filter { $0.resolution == .needsReview }.first?.reviewReason == .identicalTwin)
        try store.apply([row, row])
        #expect(try store.rows().count == 2)
        #expect(try store.imported().count == 1)
    }

    @Test func foreignCurrencyAndUnknownDirectionGoToReview() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "usd", amount: "10.00", currency: "USD", mcc: "5411"),
                         BankFixtures.tx(id: "nodir", indicator: nil, amount: "10.00")])
        #expect(try store.records().isEmpty)
        let reasons = Set(try store.rows().map(\.reviewReason))
        #expect(reasons == [.foreignCurrency, .missingDirection])
    }

    @Test func incomingMoneyIsNeverAutoIncome() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "salary", indicator: "CRDT", amount: "2500.00", name: "ACME SIA"),
                         BankFixtures.tx(id: "loan", indicator: "CRDT", amount: "100.00", name: "Friend"),
                         BankFixtures.tx(id: "refund", indicator: "CRDT", amount: "15.00", mcc: "5411"),
                         BankFixtures.tx(id: "atm", amount: "50.00", mcc: "6011")])
        #expect(try store.records().isEmpty)
        #expect(try store.rows().allSatisfy { $0.resolution == .needsReview })
        #expect(try store.rows().first { $0.providerTransactionID == "refund" }?.reviewReason == .refundLike)
        let flow = store.engine().cashFlow(in: DateInterval(start: BankFixtures.importStart, end: BankFixtures.now))
        #expect(flow.income == 0 && flow.expenses == 0)
    }
}

// MARK: - Manual matching, transfers, review

@Suite("Bank matching and review")
@MainActor
struct BankMatchingTests {
    @Test func sameDayExactManualEntryIsMatchedNotDuplicated() throws {
        let store = try BankStore()
        let manual = TransactionRecord(kind: .expense, amount: Decimal(string: "12.30", locale: Locale(identifier: "en_US_POSIX"))!,
                                       date: BankFixtures.day("2026-11-05").addingTimeInterval(-3600 * 3), note: "Rimi",
                                       accountID: store.account.id, categoryID: nil)
        store.context.insert(manual)
        try store.context.save()
        let outcome = try store.apply([BankFixtures.tx(id: "t1", amount: "12.30", mcc: "5411")])
        #expect(outcome.matched == 1 && outcome.imported == 0)
        #expect(try store.records().count == 1)
        #expect(try store.records().first?.note == "Rimi")
        #expect(try store.rows().first?.ledgerRecordID == manual.id)
    }

    @Test func uncertainMatchesWaitForReview() throws {
        let store = try BankStore()
        // Two days apart: plausible but not certain.
        store.context.insert(TransactionRecord(kind: .expense, amount: 40, date: BankFixtures.day("2026-11-03"),
                                               accountID: store.account.id))
        // Two identical manual candidates for one bank row.
        store.context.insert(TransactionRecord(kind: .expense, amount: 7, date: BankFixtures.day("2026-11-08"), accountID: store.account.id))
        store.context.insert(TransactionRecord(kind: .expense, amount: 7, date: BankFixtures.day("2026-11-08"), accountID: store.account.id))
        try store.context.save()
        try store.apply([BankFixtures.tx(id: "a", amount: "40.00", mcc: "5411"),
                         BankFixtures.tx(id: "b", amount: "7.00", booking: "2026-11-08", mcc: "5411")])
        #expect(try store.imported().isEmpty)
        let rows = try store.rows()
        #expect(rows.allSatisfy { $0.resolution == .needsReview && $0.reviewReason == .possibleDuplicate })
        #expect(rows.first { $0.providerTransactionID == "b" }?.candidates.count == 2)
    }

    @Test func reviewDecisionSameAsLinksWithoutChangingTheRecord() throws {
        let store = try BankStore()
        let manual = TransactionRecord(kind: .expense, amount: 40, date: BankFixtures.day("2026-11-03"), note: "Mine",
                                       accountID: store.account.id)
        store.context.insert(manual)
        try store.context.save()
        try store.apply([BankFixtures.tx(id: "a", amount: "40.00", mcc: "5411")])
        let row = try #require(try store.rows().first)
        try Persistence.commit(store.context) { try BankReview.resolve(row, decision: .sameAs(manual.id), remember: false, in: store.context) }
        #expect(row.resolution == .matched)
        #expect(try store.records().count == 1)
        #expect(manual.note == "Mine" && manual.amount == 40)
    }

    @Test func loanRepaymentRecordedAsTransferFromReceivable() throws {
        let store = try BankStore()
        let loan = Account(name: "Loan to Anna", kind: .otherAsset, currencyCode: "EUR", openingBalance: 500)
        store.context.insert(loan)
        try store.context.save()
        try store.apply([BankFixtures.tx(id: "r1", indicator: "CRDT", amount: "100.00", name: "Anna")])
        let row = try #require(try store.rows().first)
        try Persistence.commit(store.context) {
            try BankReview.resolve(row, decision: .transfer(otherAccountID: loan.id), remember: true, in: store.context)
        }
        let engine = store.engine()
        #expect(engine.balance(of: loan) == 400)
        let flow = engine.cashFlow(in: DateInterval(start: BankFixtures.importStart, end: BankFixtures.now))
        #expect(flow.income == 0)
        // Remembered: the next repayment from Anna is a transfer automatically.
        try store.apply([BankFixtures.tx(id: "r2", indicator: "CRDT", amount: "100.00", booking: "2026-11-10", name: "ANNA")])
        #expect(store.engine().balance(of: loan) == 300)
    }

    @Test func rememberedIncomeRuleImportsFutureSalary() throws {
        let store = try BankStore()
        let salary = try #require(try store.context.fetch(FetchDescriptor<TransactionCategory>()).first { $0.name == "Salary" })
        try store.apply([BankFixtures.tx(id: "s1", indicator: "CRDT", amount: "2500.00", booking: "2026-11-02", name: "ACME SIA")])
        let row = try #require(try store.rows().first)
        try Persistence.commit(store.context) {
            try BankReview.resolve(row, decision: .income(categoryID: salary.id), remember: true, in: store.context)
        }
        try store.apply([BankFixtures.tx(id: "s2", indicator: "CRDT", amount: "2500.00", booking: "2026-11-14", name: "ACME SIA")])
        #expect(try store.imported().filter { $0.kind == .income && $0.categoryID == salary.id }.count == 2)
    }

    @Test func transferBetweenTwoLinkedAccountsIsOneRecord() throws {
        let store = try BankStore()
        let savings = Account(name: "Swedbank savings", kind: .savings, currencyCode: "EUR", openingBalance: 0)
        store.context.insert(savings)
        let linkB = BankAccountLink(accountKey: BankFixtures.keyB, aspspName: "Swedbank", aspspCountry: "LV")
        linkB.connectionID = store.connection.id
        linkB.providerAccountUID = "acc-2"
        linkB.currencyCode = "EUR"
        linkB.localAccountID = savings.id
        linkB.importStartDate = BankFixtures.importStart
        store.context.insert(linkB)
        try store.context.save()
        try store.apply([BankFixtures.tx(id: "out", amount: "300.00", counterpartyHash: BankFixtures.keyB)])
        try Persistence.commit(store.context) {
            _ = try BankReconciler.apply(BankParsing.parse([BankFixtures.tx(id: "in", indicator: "CRDT", amount: "300.00",
                                                                            booking: "2026-11-06", counterpartyHash: BankFixtures.keyA)]),
                                         link: linkB, now: BankFixtures.now, calendar: BankFixtures.calendar, in: store.context)
        }
        let transfers = try store.records().filter { $0.kind == .transfer }
        #expect(transfers.count == 1)
        #expect(transfers.first?.accountID == store.account.id && transfers.first?.destinationAccountID == savings.id)
        #expect(try store.rows().allSatisfy { $0.ledgerRecordID == transfers.first?.id })
        let flow = store.engine().cashFlow(in: DateInterval(start: BankFixtures.importStart, end: BankFixtures.now))
        #expect(flow.income == 0 && flow.expenses == 0)
    }
}

// MARK: - Linking and net worth

@Suite("Bank linking and net worth")
@MainActor
struct BankNetWorthTests {
    @Test func linkedBankBalanceReplacesManualBalanceExactlyOnce() throws {
        let store = try BankStore(opening: 1000)
        #expect(store.engine().summary.netWorth == 1000) // no bank balance yet: ledger
        store.link.balanceAmount = Decimal(string: "1234.56", locale: Locale(identifier: "en_US_POSIX"))!
        try store.context.save()
        let engine = store.engine()
        #expect(engine.balance(of: store.account) == Decimal(string: "1234.56", locale: Locale(identifier: "en_US_POSIX"))!)
        #expect(engine.summary.netWorth == Decimal(string: "1234.56", locale: Locale(identifier: "en_US_POSIX"))!)
        #expect(engine.ledgerBalance(of: store.account) == 1000)
        #expect(engine.summary.isComplete)
    }

    @Test func importedSpendingDoesNotChangeNetWorthTwice() throws {
        let store = try BankStore(opening: 1000)
        store.link.balanceAmount = 900
        try store.context.save()
        try store.apply([BankFixtures.tx(id: "t1", amount: "100.00", mcc: "5411")])
        let engine = store.engine()
        #expect(engine.summary.netWorth == 900)
        #expect(engine.cashFlow(in: DateInterval(start: BankFixtures.importStart, end: BankFixtures.now)).expenses == 100)
    }

    @Test func oneAccountCannotRepresentTwoBankAccounts() throws {
        let store = try BankStore()
        let other = BankAccountLink(accountKey: BankFixtures.keyB, aspspName: "Swedbank", aspspCountry: "LV")
        other.currencyCode = "EUR"
        store.context.insert(other)
        #expect(throws: BankingError.invalidResponse) {
            try BankConnectionStore.link(other, to: store.account, importFrom: BankFixtures.now, calendar: BankFixtures.calendar,
                                         context: store.context)
        }
    }

    @Test func linkingRequiresMatchingCurrencyAndCashKind() throws {
        let store = try BankStore()
        let usd = Account(name: "USD", kind: .checking, currencyCode: "USD", openingBalance: 0)
        let debt = Account(name: "Loan", kind: .liability, currencyCode: "EUR", openingBalance: 0)
        store.context.insert(usd)
        store.context.insert(debt)
        let link = BankAccountLink(accountKey: BankFixtures.keyB, aspspName: "Swedbank", aspspCountry: "LV")
        link.currencyCode = "EUR"
        store.context.insert(link)
        #expect(throws: BankingError.currencyMismatch) {
            try BankConnectionStore.link(link, to: usd, importFrom: .now, calendar: BankFixtures.calendar, context: store.context)
        }
        #expect(throws: BankingError.invalidResponse) {
            try BankConnectionStore.link(link, to: debt, importFrom: .now, calendar: BankFixtures.calendar, context: store.context)
        }
    }

    @Test func createdAccountStartsAtZero() throws {
        let container = try Persistence.makeInMemoryContainer()
        let link = BankAccountLink(accountKey: BankFixtures.keyB, aspspName: "Swedbank", aspspCountry: "LV")
        link.currencyCode = "EUR"
        link.cashAccountType = "SVGS"
        link.displayName = "Krājkonts"
        container.mainContext.insert(link)
        let account = try BankConnectionStore.createAccount(for: link, now: BankFixtures.now, calendar: BankFixtures.calendar,
                                                            context: container.mainContext)
        #expect(account.openingBalance == 0 && account.kind == .savings && link.localAccountID == account.id)
    }

    @Test func unlinkCanContinueFromLastBankBalance() throws {
        let store = try BankStore(opening: 1000)
        store.link.balanceAmount = 1250
        try store.context.save()
        BankConnectionStore.unlink(store.link, adjustingFrom: 1000, now: BankFixtures.now, context: store.context)
        try store.context.save()
        let engine = store.engine()
        #expect(engine.balance(of: store.account) == 1250)
        #expect(engine.cashFlow(in: DateInterval(start: BankFixtures.importStart, end: BankFixtures.now.addingTimeInterval(86_400))).income == 0)
    }

    @Test func deletingTheAccountReleasesTheLink() throws {
        let store = try BankStore()
        try LedgerService.delete(account: store.account, in: store.context)
        #expect(store.link.localAccountID == nil)
    }
}

// MARK: - Sync failures, partial syncs, disconnect

@Suite("Bank sync safety")
@MainActor
struct BankSyncSafetyTests {
    @Test func successfulSyncSavesBalanceAndTransactions() async throws {
        let http = BankMockHTTP()
        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/balances") { return (200, BankFixtures.balances("850.25")) }
            if path.hasSuffix("/transactions") {
                #expect(request.url?.query?.contains("date_from=2026-11-01") == true)
                return (200, BankFixtures.page([BankFixtures.row(id: "t1", amount: "4.75", mcc: "5411")]))
            }
            return (404, "{}")
        }
        let store = try BankStore()
        let service = try makeBankService(http: http)
        #expect(await service.sync(context: store.context, force: true, now: BankFixtures.now))
        #expect(store.link.balanceAmount == Decimal(string: "850.25", locale: Locale(identifier: "en_US_POSIX"))!)
        #expect(store.link.lastSuccessfulSyncAt == BankFixtures.now)
        #expect(try store.imported().count == 1)
        // Automatic sync right after is skipped (stale interval), so no extra bank requests.
        let before = http.requests.count
        await service.syncIfStale(context: store.context, now: BankFixtures.now.addingTimeInterval(120))
        #expect(http.requests.count == before)
    }

    @Test func failedTransactionPageKeepsEverythingUnchanged() async throws {
        let http = BankMockHTTP()
        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/balances") { return (200, BankFixtures.balances("1.00")) }
            if request.url?.query?.contains("continuation_key") == true { return (503, #"{"error":"bank_unavailable"}"#) }
            return (200, BankFixtures.page([BankFixtures.row(id: "t1", amount: "4.75", mcc: "5411")], next: "k1"))
        }
        let store = try BankStore()
        store.link.balanceAmount = 777
        try store.context.save()
        let service = try makeBankService(http: http)
        #expect(!(await service.sync(context: store.context, force: true, now: BankFixtures.now)))
        #expect(store.link.balanceAmount == 777) // never replaced by the unconfirmed balance, never zero
        #expect(try store.rows().isEmpty)
        #expect(try store.records().isEmpty)
        #expect(service.accountErrors[store.link.id] == .bankUnavailable)
        #expect(store.engine().summary.netWorth == 777)
    }

    @Test func networkFailureKeepsLastConfirmedBalance() async throws {
        let http = BankMockHTTP()
        http.handler = { _ in throw URLError(.notConnectedToInternet) }
        let store = try BankStore()
        store.link.balanceAmount = 500
        try store.context.save()
        let service = try makeBankService(http: http)
        await service.sync(context: store.context, force: true, now: BankFixtures.now)
        #expect(service.lastError == .offline)
        #expect(store.engine().balance(of: store.account) == 500)
        #expect(service.automaticRetryAfter != nil)
    }

    @Test func oneFailingAccountDoesNotBlockAnother() async throws {
        let http = BankMockHTTP()
        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/acc-1/") { return (502, #"{"error":"bank_error"}"#) }
            if path.hasSuffix("/balances") { return (200, BankFixtures.balances("10.00")) }
            return (200, BankFixtures.page([]))
        }
        let store = try BankStore()
        let savings = Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 0)
        store.context.insert(savings)
        let linkB = BankAccountLink(accountKey: BankFixtures.keyB, aspspName: "Swedbank", aspspCountry: "LV")
        linkB.connectionID = store.connection.id
        linkB.providerAccountUID = "acc-2"
        linkB.currencyCode = "EUR"
        linkB.localAccountID = savings.id
        linkB.importStartDate = BankFixtures.importStart
        store.context.insert(linkB)
        try store.context.save()
        let service = try makeBankService(http: http)
        #expect(await service.sync(context: store.context, force: true, now: BankFixtures.now))
        #expect(store.link.balanceAmount == nil)
        #expect(linkB.balanceAmount == 10)
    }

    @Test func rateLimitStopsFurtherRequests() async throws {
        let http = BankMockHTTP()
        http.handler = { _ in (429, #"{"error":"rate_limited"}"#) }
        let store = try BankStore()
        let service = try makeBankService(http: http)
        await service.sync(context: store.context, force: true, now: BankFixtures.now)
        #expect(service.lastError == .rateLimited(retryAfter: 120))
        let count = http.requests.count
        await service.syncIfStale(context: store.context, now: BankFixtures.now.addingTimeInterval(300))
        #expect(http.requests.count == count)
    }

    @Test func disconnectKeepsFinancialDataAndFlagsBalance() async throws {
        let http = BankMockHTTP()
        http.handler = { request in request.httpMethod == "DELETE" ? (200, #"{"deleted":true}"#) : (404, "{}") }
        let store = try BankStore()
        store.link.balanceAmount = 640
        try store.context.save()
        try store.apply([BankFixtures.tx(id: "t1", amount: "4.00", mcc: "5411")])
        let service = try makeBankService(http: http)
        #expect(try await service.disconnect(store.connection, context: store.context))
        #expect(try store.context.fetch(FetchDescriptor<BankConnection>()).isEmpty)
        #expect(try store.imported().count == 1)
        #expect(store.link.localAccountID == store.account.id)
        #expect(!store.link.isConnected)
        let engine = store.engine()
        #expect(engine.balance(of: store.account) == 640)
        #expect(engine.summary.incompleteSources.contains("Swedbank"))
        #expect(http.count("/v1/connections/conn-1") == 1)
    }
}

// MARK: - Backup and migration

@Suite("Bank backup and migration")
@MainActor
struct BankBackupTests {
    @Test func backupRoundTripPreventsReimportAndExcludesSecrets() throws {
        let store = try BankStore()
        store.link.balanceAmount = 900
        try store.context.save()
        let rows = [BankFixtures.tx(id: "t1", amount: "10.00", mcc: "5411"), BankFixtures.tx(id: "t2", indicator: "CRDT", amount: "50.00")]
        try store.apply(rows)
        try store.apply([BankFixtures.tx(id: "p", status: "PDNG", amount: "1.00", mcc: "5411")])

        let payload = try BackupService.makePayload(from: store.context, baseCurrency: "EUR")
        let json = String(data: try BackupPayload.encoder().encode(payload), encoding: .utf8)!
        #expect(!json.contains("conn-1"))          // backend connection id
        #expect(!json.contains("acc-1"))           // Enable Banking account uid
        #expect(!json.contains(BankFixtures.secret))
        #expect(payload.external?.banking?.transactions.count == 2) // pending rows aren't backed up

        let target = try Persistence.makeInMemoryContainer()
        try BackupService.restore(try BackupPayload.decoder().decode(BackupPayload.self, from: Data(json.utf8)), into: target.mainContext)
        let link = try #require(try target.mainContext.fetch(FetchDescriptor<BankAccountLink>()).first)
        #expect(link.restoredFromBackup && link.connectionID == nil && link.providerAccountUID.isEmpty)
        #expect(link.localAccountID == store.account.id)
        let engine = DataMaintenance.makeEngine(context: target.mainContext, baseCurrency: "EUR")
        #expect(engine.summary.netWorth == 900)
        #expect(engine.summary.incompleteSources.contains("Swedbank"))

        // Reconnect + sync after restore: nothing is imported twice, the review item is kept.
        try Persistence.commit(target.mainContext) {
            _ = try BankReconciler.apply(BankParsing.parse(rows), link: link, now: BankFixtures.now,
                                         calendar: BankFixtures.calendar, in: target.mainContext)
        }
        let imported = try target.mainContext.fetch(FetchDescriptor<TransactionRecord>()).filter(BankReconciler.isBankImport)
        #expect(imported.count == 1)
        #expect(try target.mainContext.fetch(FetchDescriptor<BankTransaction>()).filter { $0.resolution == .needsReview }.count == 1)
    }

    @Test func restoreKeepsDeviceConsentAndReattachesByAccountKey() throws {
        let store = try BankStore()
        let payload = try BackupService.makePayload(from: store.context, baseCurrency: "EUR")
        try BackupService.restore(payload, into: store.context)
        let link = try #require(try store.context.fetch(FetchDescriptor<BankAccountLink>()).first)
        #expect(link.connectionID == store.connection.id)
        #expect(link.providerAccountUID == "acc-1")
        #expect(try store.context.fetch(FetchDescriptor<BankConnection>()).count == 1)
    }

    @Test func backupsWithoutBankDataStillDecode() throws {
        let store = try BankStore()
        var payload = try BackupService.makePayload(from: store.context, baseCurrency: "EUR")
        payload.external = nil
        var json = String(data: try BackupPayload.encoder().encode(payload), encoding: .utf8)!
        json = json.replacingOccurrences(of: #""banking":null,"#, with: "")
        let decoded = try BackupPayload.decoder().decode(BackupPayload.self, from: Data(json.utf8))
        try decoded.validate()
        let target = try Persistence.makeInMemoryContainer()
        try BackupService.restore(decoded, into: target.mainContext)
        #expect(try target.mainContext.fetch(FetchDescriptor<BankAccountLink>()).isEmpty)
    }

    @Test func invalidBankBackupIsRejectedBeforeAnythingChanges() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "t1", amount: "10.00", mcc: "5411")])
        var payload = try BackupService.makePayload(from: store.context, baseCurrency: "EUR")
        let first = try #require(payload.external?.banking?.transactions.first)
        payload.external?.banking?.transactions.append(first)
        #expect(throws: BackupValidationError.duplicateIdentifiers("bank transaction")) { try payload.validate() }
    }

    /// A store written by the previous app version (no bank models) opens with the new schema
    /// and keeps all its data: the new models are purely additive.
    @Test func previousStoreOpensWithBankModels() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bank-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "WealthOS.store")
        let previous: [any PersistentModel.Type] = Persistence.modelTypes.filter {
            !($0 == BankConnection.self || $0 == BankAccountLink.self || $0 == BankTransaction.self || $0 == BankCounterpartyRule.self)
        }
        do {
            let schema = Schema(previous)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            container.mainContext.insert(Account(name: "Old", kind: .checking, currencyCode: "EUR", openingBalance: 42))
            container.mainContext.insert(TransactionRecord(kind: .expense, amount: 2, date: .now, accountID: UUID()))
            try container.mainContext.save()
        }
        let container = try ModelContainer(for: Persistence.schema,
                                           configurations: [ModelConfiguration(schema: Persistence.schema, url: url)])
        let accounts = try container.mainContext.fetch(FetchDescriptor<Account>())
        #expect(accounts.map(\.openingBalance) == [42])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TransactionRecord>()) == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<BankAccountLink>()).isEmpty)
    }
}

// MARK: - New bank accounts, bulk recording

@Suite("Bank new accounts and bulk review")
@MainActor
struct BankNewAccountTests {
    private func unlinked(_ key: String, uid: String, connection: BankConnection, in context: ModelContext) -> BankAccountLink {
        let link = BankAccountLink(accountKey: key, aspspName: "Swedbank", aspspCountry: "LV")
        link.connectionID = connection.id
        link.providerAccountUID = uid
        link.currencyCode = "EUR"
        link.cashAccountType = "CACC"
        link.displayName = "Mr. Popcorn"
        link.maskedIdentifier = "LV** **** \(uid.suffix(4))"
        context.insert(link)
        return link
    }

    @Test func addAllCreatesDistinctAccountsWithHistoryInOneSave() async throws {
        let store = try BankStore()
        let a = unlinked(String(repeating: "c", count: 64), uid: "u-0141", connection: store.connection, in: store.context)
        let b = unlinked(String(repeating: "d", count: 64), uid: "u-0109", connection: store.connection, in: store.context)
        try store.context.save()
        let service = try makeBankService(http: BankMockHTTP())
        let created = try service.createAccounts(for: [a, b], context: store.context, now: BankFixtures.now)
        #expect(created.map(\.name) == ["Mr. Popcorn ·0141", "Mr. Popcorn ·0109"])
        #expect(created.allSatisfy { $0.openingBalance == 0 })
        let expectedStart = BankFixtures.calendar.date(byAdding: .day, value: -BankingService.newAccountHistoryDays, to: BankFixtures.now)!
        #expect(a.importStartDate == BankFixtures.calendar.startOfDay(for: expectedStart))
        #expect(a.localAccountID == created[0].id && b.localAccountID == created[1].id)
    }

    @Test func sameNameAndNumberGetsAUniqueSuffix() {
        let link = BankAccountLink(accountKey: BankFixtures.keyB, aspspName: "Swedbank", aspspCountry: "LV")
        link.displayName = "Main"
        link.maskedIdentifier = "LV** **** 1234"
        let taken = [Account(name: "Main ·1234", kind: .checking, currencyCode: "EUR", openingBalance: 0)]
        #expect(BankConnectionStore.accountName(for: link, existing: taken) == "Main ·1234 (2)")
    }

    @Test func accountAddedAfterASyncIsFetchedWithoutWaitingSixHours() async throws {
        let http = BankMockHTTP()
        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/balances") { return (200, BankFixtures.balances("10.00")) }
            return (200, BankFixtures.page([]))
        }
        let store = try BankStore()
        let service = try makeBankService(http: http)
        #expect(await service.sync(context: store.context, force: true, now: BankFixtures.now))
        let second = unlinked(BankFixtures.keyB, uid: "acc-2", connection: store.connection, in: store.context)
        try store.context.save()
        try service.createAccounts(for: [second], context: store.context, now: BankFixtures.now)
        let before = http.count("/acc-1/")
        // Within the 60 s minimum and the 6 h stale interval: only the new account is fetched.
        #expect(await service.sync(context: store.context, now: BankFixtures.now.addingTimeInterval(10)))
        #expect(second.balanceAmount == 10)
        #expect(http.count("/acc-1/") == before)
        // Once fetched, it follows the normal limits again.
        let count = http.requests.count
        await service.sync(context: store.context, now: BankFixtures.now.addingTimeInterval(20))
        #expect(http.requests.count == count)
    }

    @Test func bulkRecordingTakesOnlyUnambiguousRows() throws {
        let store = try BankStore()
        store.context.insert(TransactionRecord(kind: .expense, amount: 30, date: BankFixtures.day("2026-11-05"), note: "manual",
                                               accountID: store.account.id))
        try store.context.save()
        try store.apply([BankFixtures.tx(id: "in", indicator: "CRDT", amount: "100.00", name: "ACME"),
                         BankFixtures.tx(id: "out", amount: "12.00", name: "Shop", code: "PMNT"),
                         BankFixtures.tx(id: "dup", amount: "30.00", booking: "2026-11-06", name: "Maybe manual"),
                         BankFixtures.tx(id: "refund", indicator: "CRDT", amount: "5.00", mcc: "5411"),
                         BankFixtures.tx(id: "usd", amount: "7.00", currency: "USD"),
                         BankFixtures.tx(id: "pend", status: "PDNG", amount: "3.00")])
        var recorded = 0
        try Persistence.commit(store.context) { recorded = try BankReview.recordAllAsIncomeOrExpense(try store.rows(), in: store.context) }
        #expect(recorded == 2)
        let rows = try store.rows()
        func row(_ id: String) -> BankTransaction? { rows.first { $0.providerTransactionID == id } }
        #expect(row("in")?.resolution == .imported && row("out")?.resolution == .imported)
        #expect(row("dup")?.resolution == .needsReview && row("refund")?.resolution == .needsReview)
        #expect(row("usd")?.resolution == .needsReview && row("pend")?.resolution == .pending)
        let imported = try store.imported()
        #expect(imported.count == 2 && imported.allSatisfy { $0.categoryID != nil })
        #expect(Set(imported.map(\.kind)) == [.income, .expense])
        // A later sync of the same row never records it a second time.
        try store.apply([BankFixtures.tx(id: "in", indicator: "CRDT", amount: "100.00", name: "ACME")])
        #expect(try store.imported().count == 2)
    }
}

// MARK: - Automatic categories

@Suite("Bank automatic categories")
@MainActor
struct BankCategorizerTests {
    private func category(_ name: String, in store: BankStore) throws -> UUID? {
        try store.context.fetch(FetchDescriptor<TransactionCategory>()).first { $0.name == name }?.id
    }

    private func record(for id: String, in store: BankStore) throws -> TransactionRecord? {
        let row = try store.rows().first { $0.providerTransactionID == id }
        return try store.records().first { $0.id == row?.ledgerRecordID }
    }

    @Test func merchantCodesAndNamesMapToCategories() {
        #expect(BankCategorizer.categoryName(merchantCode: "5411") == "Food")
        #expect(BankCategorizer.categoryName(merchantCode: "5541") == "Car")
        #expect(BankCategorizer.categoryName(merchantCode: "6011") == nil)
        #expect(BankCategorizer.categoryName(merchantCode: "abcd") == nil)
        #expect(BankCategorizer.categoryName(text: "RIMI Latvija SIA, Imanta", kind: .expense) == "Food")
        #expect(BankCategorizer.categoryName(text: "BOLT FOOD", kind: .expense) == "Food")
        #expect(BankCategorizer.categoryName(text: "Bolt.eu ride", kind: .expense) == "Transport")
        #expect(BankCategorizer.categoryName(text: "Circle K Latvia", kind: .expense) == "Car")
        #expect(BankCategorizer.categoryName(text: "primitive store", kind: .expense) == nil) // whole words only
        #expect(BankCategorizer.categoryName(text: "Darba alga par oktobri", kind: .income) == "Salary")
    }

    @Test func cardPaymentGetsMerchantCategory() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "rimi", amount: "23.10", name: "RIMI IMANTA", mcc: "5411"),
                         BankFixtures.tx(id: "fuel", amount: "50.00", name: "Somewhere", mcc: "5541"),
                         BankFixtures.tx(id: "card", amount: "9.99", name: "Unknown Ltd", code: "PMNT-CCRD-POSD")])
        #expect(try record(for: "rimi", in: store)?.categoryID == category("Food", in: store))
        #expect(try record(for: "fuel", in: store)?.categoryID == category("Car", in: store))
        #expect(try record(for: "card", in: store)?.categoryID == category("Other", in: store))
    }

    @Test func recognisedMerchantTransferIsRecordedButUnknownTransferWaits() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "tet", amount: "25.00", name: "Tet SIA", code: "PMNT-ICDT-ESCT"),
                         BankFixtures.tx(id: "friend", amount: "100.00", name: "Janis Berzins", code: "PMNT-ICDT-ESCT"),
                         BankFixtures.tx(id: "atm", amount: "40.00", name: "Rimi", mcc: "6011")])
        #expect(try record(for: "tet", in: store)?.categoryID == category("Subscriptions", in: store))
        let rows = try store.rows()
        #expect(rows.first { $0.providerTransactionID == "friend" }?.resolution == .needsReview)
        #expect(rows.first { $0.providerTransactionID == "atm" }?.resolution == .needsReview) // cash is never an expense
    }

    @Test func incomeIsSuggestedButStillReviewed() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "pay", indicator: "CRDT", amount: "2500.00", name: "ACME SIA",
                                         remittance: ["Darba alga 10/2026"])])
        let row = try #require(try store.rows().first)
        #expect(row.resolution == .needsReview)
        let suggestion = BankCategorizer.suggest(for: row, kind: .income,
                                                 categories: try store.context.fetch(FetchDescriptor<TransactionCategory>()), rules: [])
        #expect(suggestion?.categoryID == (try category("Salary", in: store)))
        try Persistence.commit(store.context) { _ = try BankReview.recordAllAsIncomeOrExpense([row], in: store.context) }
        #expect(try record(for: "pay", in: store)?.categoryID == category("Salary", in: store))
    }

    @Test func changingACategoryTeachesThePayee() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "a", amount: "5.00", booking: "2026-11-03", name: "Kiosk 24", code: "PMNT-CCRD-POSD"),
                         BankFixtures.tx(id: "b", amount: "6.00", booking: "2026-11-04", name: "Kiosk 24", code: "PMNT-CCRD-POSD"),
                         BankFixtures.tx(id: "c", amount: "7.00", booking: "2026-11-05", name: "Kiosk 24", code: "PMNT-CCRD-POSD")])
        let food = try #require(try category("Food", in: store))
        let health = try #require(try category("Health", in: store))
        let other = try category("Other", in: store)
        // "c" was set to Health by hand earlier; a correction elsewhere must not overwrite it.
        let c = try #require(try record(for: "c", in: store))
        c.categoryID = health
        try store.context.save()
        let a = try #require(try record(for: "a", in: store))
        var moved = 0
        try Persistence.commit(store.context) {
            a.categoryID = food
            moved = try BankCategoryLearning.learn(record: a, oldCategoryID: other, in: store.context)
        }
        #expect(moved == 1)
        #expect(try record(for: "b", in: store)?.categoryID == food)
        #expect(c.categoryID == health)
        // Future transactions from the payee follow the latest choice.
        try store.apply([BankFixtures.tx(id: "d", amount: "8.00", booking: "2026-11-10", name: "KIOSK 24", code: "PMNT-ICDT-ESCT")])
        #expect(try record(for: "d", in: store)?.categoryID == food)
        #expect(try store.context.fetch(FetchDescriptor<BankCounterpartyRule>()).count == 1)
    }
}

@Suite("Bank production safety")
@MainActor
struct BankProductionSafetyTests {
    @Test func bulkCreationIsWithheldWhileAManualAccountCouldBeTheSameMoney() throws {
        let store = try BankStore()  // its manual EUR account is linked to keyA
        let link = BankAccountLink(accountKey: BankFixtures.keyB, aspspName: "Swedbank", aspspCountry: "LV")
        link.currencyCode = "EUR"
        store.context.insert(link)
        let links = try store.context.fetch(FetchDescriptor<BankAccountLink>())
        var accounts = try store.context.fetch(FetchDescriptor<Account>())
        // The only manual account is already linked: nothing else could be the same money.
        #expect(!BankConnectionStore.hasManualCandidates(for: [link], links: links, accounts: accounts))
        let cash = Account(name: "Swedbank (by hand)", kind: .checking, currencyCode: "EUR", openingBalance: 300)
        store.context.insert(cash)
        accounts.append(cash)
        #expect(BankConnectionStore.hasManualCandidates(for: [link], links: links, accounts: accounts))
        // A USD account can't be this EUR bank account; a loan isn't linkable at all.
        let others = [Account(name: "USD", kind: .checking, currencyCode: "USD", openingBalance: 0)]
        #expect(!BankConnectionStore.hasManualCandidates(for: [link], links: links, accounts: accounts.filter { $0.id != cash.id } + others))
    }
}

// MARK: - Multi-currency bank accounts (Swedbank reports them with currency "XXX")

@MainActor
struct BankMultiCurrencyTests {
    private func multiCurrencyStore() throws -> BankStore {
        let store = try BankStore()
        store.link.currencyCode = "XXX"
        try store.context.save()
        return store
    }

    @Test func multiCurrencyAccountAcceptsRealCurrenciesOnly() {
        let link = BankAccountLink(accountKey: BankFixtures.keyA, aspspName: "Swedbank", aspspCountry: "LV")
        link.currencyCode = "XXX"
        #expect(link.isMultiCurrency)
        #expect(link.accepts("EUR") && link.accepts("USD"))
        #expect(!link.accepts("XXX") && !link.accepts(""))
        #expect(link.countingCurrency(linkedAccountCurrency: nil) == nil)
        #expect(link.countingCurrency(linkedAccountCurrency: "EUR") == "EUR")
        link.currencyCode = "EUR"
        #expect(!link.isMultiCurrency && link.accepts("EUR") && !link.accepts("USD"))
    }

    @Test func manualEuroAccountIsOfferedForAMultiCurrencyBankAccount() throws {
        let store = try multiCurrencyStore()
        store.link.localAccountID = nil
        // The manual EUR account is a candidate, so "Add All" is withheld (no duplicate).
        #expect(BankConnectionStore.hasManualCandidates(for: [store.link], links: [store.link], accounts: [store.account]))
        try BankConnectionStore.link(store.link, to: store.account, importFrom: BankFixtures.now,
                                     calendar: BankFixtures.calendar, context: store.context)
        #expect(store.link.localAccountID == store.account.id)
        #expect(store.link.currencyCode == "XXX")  // the bank's own report is kept
    }

    @Test func newAccountFromMultiCurrencyUsesTheBaseCurrency() throws {
        let store = try multiCurrencyStore()
        store.link.localAccountID = nil
        let account = try BankConnectionStore.createAccount(for: store.link, now: BankFixtures.now, calendar: BankFixtures.calendar,
                                                            multiCurrencyDefault: "EUR", context: store.context)
        #expect(account.currencyCode == "EUR")
        #expect(store.link.localAccountID == account.id)
    }

    @Test func balanceInTheAccountCurrencyIsPickedAmongOthers() throws {
        let balances = [
            BankBalanceDTO(name: nil, amount: "99.00", currency: "USD", balanceType: "ITBD", referenceDate: "2026-11-15"),
            BankBalanceDTO(name: nil, amount: "1200.55", currency: "EUR", balanceType: "ITBD", referenceDate: "2026-11-15"),
        ]
        // Single-currency accounts still treat another currency as an error...
        #expect(throws: BankingError.currencyMismatch) { try BankBalanceSelection.select(balances, currency: "EUR", creditLimit: nil) }
        // ...multi-currency accounts take the linked account's currency.
        #expect(try BankBalanceSelection.select(balances, currency: "EUR", creditLimit: nil, otherCurrencies: true).amount == Decimal(string: "1200.55"))
    }

    @Test func syncCountsTheEuroBalanceOfAMultiCurrencyAccount() async throws {
        let http = BankMockHTTP()
        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/balances") {
                return (200, BankFixtures.json(["balances": [
                    ["name": "b", "amount": "15.00", "currency": "USD", "balance_type": "ITBD", "reference_date": "2026-11-15"],
                    ["name": "b", "amount": "321.09", "currency": "EUR", "balance_type": "ITBD", "reference_date": "2026-11-15"],
                ]]))
            }
            return (200, BankFixtures.page([]))
        }
        let store = try multiCurrencyStore()
        let service = try makeBankService(http: http)
        #expect(await service.sync(context: store.context, force: true, now: BankFixtures.now))
        #expect(store.link.balanceAmount == Decimal(string: "321.09"))
        #expect(store.link.lastErrorRaw.isEmpty)
    }
}

// MARK: - Swedbank production card purchases ("PIRKUMS", no merchant code)

@MainActor
struct BankCardPurchaseTests {
    private func category(_ name: String, in store: BankStore) throws -> UUID? {
        try store.context.fetch(FetchDescriptor<TransactionCategory>()).first { $0.name == name }?.id
    }

    private func record(for id: String, in store: BankStore) throws -> TransactionRecord? {
        let row = try store.rows().first { $0.providerTransactionID == id }
        return try store.records().first { $0.id == row?.ledgerRecordID }
    }

    @Test func foodShopsAreRecognisedInSwedbankPurchaseTexts() {
        #expect(BankCategorizer.categoryName(text: "PIRKUMS 4*** ****1234 03.11.2026 BOOZIE RIGA", kind: .expense) == "Food")
        #expect(BankCategorizer.categoryName(text: "VENDINGS LV\nPIRKUMS 4*** ****1234", kind: .expense) == "Food")
        #expect(BankCategorizer.categoryName(text: "PIRKUMS RIMI MEZCIEMS", kind: .expense) == "Food")
        #expect(BankCategorizer.categoryName(text: "PIRKUMS LATS VEIKALS", kind: .expense) == "Food")
        #expect(BankCategorizer.categoryName(text: "PIRKUMS 400000******0000 09.11.2026 0.99 EUR (123456) SIA SANITEX - Birojs LV-21",
                                             kind: .expense) == "Food")
    }

    @Test func purchasesWithoutMerchantCodeAreRecordedNotReviewed() throws {
        let store = try BankStore()
        try store.apply([
            BankFixtures.tx(id: "boozie", amount: "6.40", remittance: ["PIRKUMS 4*** ****1234 03.11.2026 BOOZIE RIGA"]),
            BankFixtures.tx(id: "vend", amount: "1.50", name: "VENDINGS LV", remittance: ["PIRKUMS 4*** ****1234"]),
            BankFixtures.tx(id: "shop", amount: "19.99", remittance: ["PIRKUMS 4*** ****1234 SOME UNKNOWN SHOP"]),
            BankFixtures.tx(id: "transfer", amount: "50.00", name: "Janis Berzins", remittance: ["Par vakarinam"]),
        ])
        #expect(try record(for: "boozie", in: store)?.categoryID == category("Food", in: store))
        #expect(try record(for: "vend", in: store)?.categoryID == category("Food", in: store))
        #expect(try record(for: "shop", in: store)?.categoryID == category("Other", in: store))  // a purchase, shop unknown
        #expect(try store.rows().first { $0.providerTransactionID == "transfer" }?.resolution == .needsReview)
    }

    @Test func renamedFoodCategoryIsStillFound() throws {
        let store = try BankStore()
        let food = try store.context.fetch(FetchDescriptor<TransactionCategory>()).first { $0.name == "Food" }!
        food.name = "Groceries"
        try store.context.save()
        try store.apply([BankFixtures.tx(id: "rimi", amount: "12.00", remittance: ["PIRKUMS RIMI IMANTA"])])
        #expect(try record(for: "rimi", in: store)?.categoryID == food.id)
    }

    @Test func improvedRulesReachEarlierDownloadsButNotUserChoices() throws {
        let store = try BankStore()
        let other = try category("Other", in: store), foodID = try category("Food", in: store)
        let health = try category("Health", in: store)
        try store.apply([
            BankFixtures.tx(id: "old1", amount: "5.00", remittance: ["PIRKUMS RIMI"]),
            BankFixtures.tx(id: "old2", amount: "7.00", remittance: ["PIRKUMS RIMI"]),
        ])
        // Simulate rows imported before the rules knew these shops: one left on "Other", one the
        // user moved to Health by hand, and a purchase that went to review.
        try record(for: "old1", in: store)?.categoryID = other
        try record(for: "old2", in: store)?.categoryID = health
        try store.apply([BankFixtures.tx(id: "waiting", amount: "3.20", name: "Janis", remittance: ["Par kafiju"])])
        let waiting = try store.rows().first { $0.providerTransactionID == "waiting" }!
        waiting.remittance = "PIRKUMS 4*** BOOZIE RIGA"  // what the bank sends for it
        try store.context.save()

        let result = try BankCategoryReapply.run(in: store.context, now: BankFixtures.now)
        #expect(result.recorded == 1 && result.recategorized == 1)
        #expect(try record(for: "old1", in: store)?.categoryID == foodID)
        #expect(try record(for: "old2", in: store)?.categoryID == health)  // the user's choice stays
        #expect(try record(for: "waiting", in: store)?.categoryID == foodID)
        // Running again changes nothing.
        #expect(try BankCategoryReapply.run(in: store.context, now: BankFixtures.now) == .init())
    }

    @Test func otherChosenOnPurposeForAMerchantIsKept() throws {
        let store = try BankStore()
        let other = try category("Other", in: store)
        try store.apply([BankFixtures.tx(id: "a", amount: "4.00", remittance: ["PIRKUMS BOOZIE"])])
        let rec = try record(for: "a", in: store)!
        let old = rec.categoryID
        rec.categoryID = other
        try BankCategoryLearning.learn(record: rec, oldCategoryID: old, in: store.context)  // the user set Other
        try store.context.save()
        try BankCategoryReapply.run(in: store.context, now: BankFixtures.now)
        #expect(rec.categoryID == other)
    }

    @Test func purchaseMerchantIsTheRuleKey() throws {
        let store = try BankStore()
        try store.apply([BankFixtures.tx(id: "p", amount: "2.00", remittance: ["PIRKUMS 4*** ****1234 03.11.2026 BOOZIE RIGA"])])
        let row = try store.rows().first { $0.providerTransactionID == "p" }!
        #expect(BankReconciler.ruleKeys(for: row) == ["merchant:boozie riga"])
        try store.apply([BankFixtures.tx(id: "s", amount: "0.99",
                                         remittance: ["PIRKUMS 400000******0000 09.11.2026 0.99 EUR (123456) SIA SANITEX - Birojs LV-21"])])
        let sanitex = try store.rows().first { $0.providerTransactionID == "s" }!
        #expect(BankReconciler.ruleKeys(for: sanitex) == ["merchant:sanitex birojs"])
        #expect(try store.records().first { $0.id == sanitex.ledgerRecordID }?.categoryID
                == store.context.fetch(FetchDescriptor<TransactionCategory>()).first { $0.name == "Food" }?.id)
    }
}


// MARK: - PSU presence

struct BankUserPresenceTests {
    @Test func userPresentRequestsCarryTheMarkerAndOthersDoNot() throws {
        var client = BankingClient(config: BankingBackendConfig(string: "http://localhost:8787")!,
                                   credentials: BankingCredentials(clientID: "ios", clientSecret: BankFixtures.secret),
                                   http: BankMockHTTP())
        #expect(try client.request("GET", "/v1/connections/c").value(forHTTPHeaderField: "X-WOS-User-Present") == nil)
        client.userPresent = true
        #expect(try client.request("GET", "/v1/connections/c").value(forHTTPHeaderField: "X-WOS-User-Present") == "1")
    }

    @MainActor
    @Test func syncTellsTheBackendTheUserIsPresent() async throws {
        let http = BankMockHTTP()
        http.handler = { request in
            let path = request.url?.path ?? ""
            #expect(request.value(forHTTPHeaderField: "X-WOS-User-Present") == "1")
            if path.hasSuffix("/balances") { return (200, BankFixtures.balances("10.00")) }
            return (200, BankFixtures.page([]))
        }
        let store = try BankStore()
        let service = try makeBankService(http: http)
        #expect(await service.sync(context: store.context, force: true, now: BankFixtures.now))
        #expect(!http.requests.isEmpty)
    }
}
