import CryptoKit
import Foundation

// Client for the WealthOS banking backend (see /backend in the repository). The backend holds
// the Enable Banking application key, signs Enable Banking JWTs and is the only party that
// talks to Enable Banking. This client authenticates with an HMAC signature over every request
// (the shared secret itself is never transmitted), so a captured request can't be replayed or
// altered. There is deliberately no payment, transfer or any money-moving endpoint.

nonisolated enum BankEntryStatus: String, Sendable, Codable {
    case booked = "BOOK"
    case pending = "PDNG"
    case other = "OTHR"
}

/// ISO 20022 balance types listed in the Enable Banking `BalanceType` schema.
nonisolated enum BankBalanceType: String, Sendable, CaseIterable {
    case closingAvailable = "CLAV", closingBooked = "CLBD", forwardAvailable = "FWAV", info = "INFO"
    case interimAvailable = "ITAV", interimBooked = "ITBD", openingAvailable = "OPAV", openingBooked = "OPBD"
    case other = "OTHR", previouslyClosedBooked = "PRCD", valueDate = "VALU", expected = "XPCD"

    var title: String {
        switch self {
        case .closingBooked: "Booked balance (end of day)"
        case .interimBooked: "Booked balance"
        case .expected: "Expected balance"
        case .openingBooked: "Opening booked balance"
        case .closingAvailable, .interimAvailable: "Available balance"
        default: rawValue
        }
    }
}

// MARK: - Backend wire format

nonisolated struct BankAuthStartResponse: Decodable, Sendable {
    var attemptID: String
    var authorizationURL: String
    var expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case attemptID = "attempt_id", authorizationURL = "authorization_url", expiresAt = "expires_at"
    }
}

nonisolated struct BankAmountDTO: Decodable, Sendable, Equatable {
    /// Decimal string exactly as the bank sent it; never converted through Double.
    var amount: String?
    var currency: String?
}

nonisolated struct BankAccountDTO: Decodable, Sendable, Equatable {
    var uid: String
    var accountKey: String
    var displayName: String?
    var maskedIdentifier: String?
    var currency: String?
    var cashAccountType: String?
    var product: String?
    var creditLimit: BankAmountDTO?

    enum CodingKeys: String, CodingKey {
        case uid, currency, product
        case accountKey = "account_key", displayName = "display_name", maskedIdentifier = "masked_identifier"
        case cashAccountType = "cash_account_type", creditLimit = "credit_limit"
    }
}

nonisolated struct BankConnectionDTO: Decodable, Sendable {
    struct ASPSP: Decodable, Sendable { var name: String; var country: String }
    var connectionID: String
    var aspsp: ASPSP
    var validUntil: String?
    var accounts: [BankAccountDTO]

    enum CodingKeys: String, CodingKey {
        case aspsp, accounts
        case connectionID = "connection_id", validUntil = "valid_until"
    }
}

nonisolated struct BankConnectionStatusDTO: Decodable, Sendable {
    /// Enable Banking session status: AUTHORIZED, EXPIRED, REVOKED, CLOSED, CANCELLED, INVALID…
    var status: String
    var validUntil: String?

    enum CodingKeys: String, CodingKey { case status, validUntil = "valid_until" }
}

nonisolated struct BankBalanceDTO: Decodable, Sendable, Equatable {
    var name: String?
    var amount: String?
    var currency: String?
    var balanceType: String?
    var referenceDate: String?
    var lastChangeDateTime: String?

    enum CodingKeys: String, CodingKey {
        case name, amount, currency
        case balanceType = "balance_type", referenceDate = "reference_date", lastChangeDateTime = "last_change_date_time"
    }
}

nonisolated struct BankBalancesResponse: Decodable, Sendable { var balances: [BankBalanceDTO] }

/// One transaction, normalized by the backend from the Enable Banking `Transaction` schema:
/// the counterparty is the creditor for debits and the debtor for credits, and counterparty
/// account numbers arrive only as a hash plus a masked form.
nonisolated struct BankTransactionDTO: Decodable, Sendable, Equatable {
    var transactionID: String?
    var entryReference: String?
    var status: String?
    var creditDebitIndicator: String?
    var amount: String?
    var currency: String?
    var bookingDate: String?
    var valueDate: String?
    var transactionDate: String?
    var counterpartyName: String?
    var counterpartyAccountHash: String?
    var counterpartyAccountMasked: String?
    var remittance: [String]?
    var referenceNumber: String?
    var bankTransactionCode: String?
    var merchantCategoryCode: String?

    enum CodingKeys: String, CodingKey {
        case status, amount, currency, remittance
        case transactionID = "transaction_id", entryReference = "entry_reference"
        case creditDebitIndicator = "credit_debit_indicator", bookingDate = "booking_date", valueDate = "value_date"
        case transactionDate = "transaction_date", counterpartyName = "counterparty_name"
        case counterpartyAccountHash = "counterparty_account_hash", counterpartyAccountMasked = "counterparty_account_masked"
        case referenceNumber = "reference_number", bankTransactionCode = "bank_transaction_code"
        case merchantCategoryCode = "merchant_category_code"
    }
}

nonisolated struct BankTransactionsPage: Decodable, Sendable {
    var transactions: [BankTransactionDTO]
    var continuationKey: String?

    enum CodingKeys: String, CodingKey { case transactions, continuationKey = "continuation_key" }
}

nonisolated struct BankErrorDTO: Decodable, Sendable {
    var error: String?
    var reason: String?
}

// MARK: - Errors

nonisolated enum BankingError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidBackendURL
    case unauthorized
    case consentExpired
    case consentRevoked
    case authorizationCancelled
    case authorizationRejected
    case authorizationFailed
    case invalidCallback
    case attemptExpired
    case attemptPending
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case timeout
    case network
    case bankUnavailable
    case server(Int)
    case invalidResponse
    case tooManyPages
    case busy
    case blockedRequest
    case currencyMismatch
    case noConfirmedBalance
    case credentialStorage
    case keychainUnavailable
    case localSaveFailed
    case notFound

    /// Never contains secrets, identifiers, amounts or response bodies.
    var errorDescription: String? {
        switch self {
        case .notConfigured: "Set up the banking server address and client key first."
        case .invalidBackendURL: "The banking server address must be https://, or http://localhost / 127.0.0.1 for local development."
        case .unauthorized: "The banking server rejected this app's client key. Check the client ID and secret."
        case .consentExpired: "Your bank access has expired. Reconnect to continue syncing; your data is kept."
        case .consentRevoked: "Your bank access was revoked or closed. Reconnect to continue syncing; your data is kept."
        case .authorizationCancelled: "The bank connection was cancelled. Nothing was changed."
        case .authorizationRejected: "Access wasn't granted at the bank. Nothing was changed."
        case .authorizationFailed: "The bank authorization didn't complete. Nothing was changed — try again."
        case .invalidCallback: "Ignored an unexpected bank callback. Nothing was changed — start the connection again."
        case .attemptExpired: "The connection attempt expired. Start again."
        case .attemptPending: "The bank hasn't confirmed the authorization yet. Try again in a moment."
        case .rateLimited(let wait):
            wait.map { "Too many bank requests. Try again in \(Int($0.rounded(.up))) s." } ?? "Too many bank requests. Try again later."
        case .offline: "You're offline. Showing the last confirmed bank data."
        case .timeout: "The banking server didn't respond in time."
        case .network: "Couldn't reach the banking server."
        case .bankUnavailable: "The bank is temporarily unavailable. Showing the last confirmed data."
        case .server(let code): "The banking server had a problem (\(code)). Try again later."
        case .invalidResponse: "The bank returned data WealthOS couldn't read. Nothing was changed."
        case .tooManyPages: "The bank returned more transaction pages than expected. Nothing was changed for this account."
        case .busy: "A bank sync is already running."
        case .blockedRequest: "Blocked a request that wasn't a read-only call to the banking server."
        case .currencyMismatch: "The bank reported a different currency than the linked WealthOS account. Nothing was changed."
        case .noConfirmedBalance: "The bank didn't report a booked balance, so the last confirmed balance was kept."
        case .credentialStorage: "The iOS Keychain didn't accept the change. Nothing was changed."
        case .keychainUnavailable: "The Keychain isn't available right now (the iPhone may be locked). Try again."
        case .localSaveFailed: "WealthOS couldn't save the bank data on this iPhone. Nothing was changed."
        case .notFound: "The banking server doesn't know this connection anymore. Reconnect."
        }
    }

    var requiresReconnect: Bool {
        switch self {
        case .consentExpired, .consentRevoked, .notFound: true
        default: false
        }
    }
}

// MARK: - Transport

/// Sends one request to the configured banking backend.
nonisolated protocol BankingHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The backend address. Production must use HTTPS; plain HTTP is accepted only for the local
/// loopback development server (which is never reachable from a physical iPhone).
nonisolated struct BankingBackendConfig: Sendable, Equatable {
    let baseURL: URL

    init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil
        else { return nil }
        guard scheme == "https" || (scheme == "http" && Self.loopbackHosts.contains(host)) else { return nil }
        if components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { return nil }
        baseURL = url
    }

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    var host: String { baseURL.host?.lowercased() ?? "" }
}

/// URLSession transport restricted to the configured backend host. Ephemeral session (no
/// cookies, cache or credential storage), no redirects, TLS 1.2+, response size cap.
nonisolated final class BankingTransport: NSObject, BankingHTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    static let maximumBytes = 5_000_000
    private let session: URLSession
    private let allowedHost: String

    init(allowedHost: String) {
        self.allowedHost = allowedHost.lowercased()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpAdditionalHeaders = ["User-Agent": "WealthOS", "Accept": "application/json"]
        session = URLSession(configuration: configuration)
        super.init()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try BankingClient.validate(request, allowedHost: allowedHost)
        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse, http.url?.host?.lowercased() == allowedHost else {
            throw BankingError.blockedRequest
        }
        guard data.count <= Self.maximumBytes else { throw BankingError.invalidResponse }
        return (data, http)
    }

    /// Never follow redirects: they could carry the signed request elsewhere.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Used in test hosts and previews: every request is refused before it leaves the device.
nonisolated struct DisabledBankingHTTPClient: BankingHTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw BankingError.blockedRequest }
}

// MARK: - Client

nonisolated struct BankingCredentials: Sendable, Equatable {
    let clientID: String
    let clientSecret: String

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The secret must carry at least 256 bits (64 hex characters or ~43 base64 characters).
    var isComplete: Bool { !clientID.isEmpty && clientID.count <= 64 && clientSecret.count >= 43 }
}

nonisolated struct BankingClient: Sendable {
    let config: BankingBackendConfig
    let credentials: BankingCredentials
    let http: BankingHTTPClient
    var now: @Sendable () -> Date = { .now }
    var nonce: @Sendable () -> String = { UUID().uuidString.lowercased() }
    /// Upper bound on transaction pages per account and sync (guards against a looping key).
    var maxPages = 50
    /// The user started this fetch while using the app. The backend then passes the user's IP and
    /// app to the bank (PSU headers), so it isn't counted as a background fetch — PSD2 banks allow
    /// only about four of those per day and account.
    var userPresent = false

    /// Every path the app may call, with its method. Anything else is refused locally.
    static let allowedRoutes: [(method: String, pattern: String)] = [
        ("POST", "/v1/auth/start"),
        ("POST", "/v1/auth/complete"),
        ("GET", "/v1/connections/*"),
        ("DELETE", "/v1/connections/*"),
        ("GET", "/v1/connections/*/accounts/*/balances"),
        ("GET", "/v1/connections/*/accounts/*/transactions"),
    ]

    static func validate(_ request: URLRequest, allowedHost: String) throws {
        guard let url = request.url, let host = url.host?.lowercased(), host == allowedHost.lowercased(),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && BankingBackendConfig.loopbackHosts.contains(host)) else {
            throw BankingError.blockedRequest
        }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = allowedRoutes.contains { route in
            guard route.method == method else { return false }
            let pattern = route.pattern.split(separator: "/", omittingEmptySubsequences: false)
            guard pattern.count == segments.count else { return false }
            return zip(pattern, segments).allSatisfy { p, s in p == "*" ? (!s.isEmpty && s.allSatisfy(Self.isIDCharacter)) : p == s }
        }
        guard allowed else { throw BankingError.blockedRequest }
    }

    private static func isIDCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }

    // MARK: Endpoints

    func startAuthorization(aspspName: String, country: String) async throws -> BankAuthStartResponse {
        try await call("POST", "/v1/auth/start", body: ["aspsp_name": aspspName, "aspsp_country": country, "psu_type": "personal"])
    }

    func completeAuthorization(attemptID: String) async throws -> BankConnectionDTO {
        try await call("POST", "/v1/auth/complete", body: ["attempt_id": attemptID])
    }

    func connectionStatus(_ connectionID: String) async throws -> BankConnectionStatusDTO {
        try await call("GET", "/v1/connections/\(try Self.pathID(connectionID))")
    }

    func deleteConnection(_ connectionID: String) async throws {
        let _: BankErrorDTO = try await call("DELETE", "/v1/connections/\(try Self.pathID(connectionID))")
    }

    func balances(connectionID: String, accountUID: String) async throws -> [BankBalanceDTO] {
        let response: BankBalancesResponse = try await call(
            "GET", "/v1/connections/\(try Self.pathID(connectionID))/accounts/\(try Self.pathID(accountUID))/balances")
        return response.balances
    }

    /// Reads every page from `dateFrom` (inclusive) to today. All-or-nothing: any failing page
    /// fails the whole read, so a partial history is never treated as complete.
    func transactions(connectionID: String, accountUID: String, dateFrom: String) async throws -> [BankTransactionDTO] {
        var all: [BankTransactionDTO] = []
        var key: String?
        var seenKeys: Set<String> = []
        for _ in 0..<maxPages {
            var query = [URLQueryItem(name: "date_from", value: dateFrom)]
            if let key { query.append(URLQueryItem(name: "continuation_key", value: key)) }
            let page: BankTransactionsPage = try await call(
                "GET", "/v1/connections/\(try Self.pathID(connectionID))/accounts/\(try Self.pathID(accountUID))/transactions",
                query: query)
            all.append(contentsOf: page.transactions)
            guard let next = page.continuationKey, !next.isEmpty else { return all }
            guard seenKeys.insert(next).inserted else { throw BankingError.invalidResponse }
            key = next
        }
        throw BankingError.tooManyPages
    }

    // MARK: Signing

    /// HMAC-SHA256 over method, path+query, timestamp, nonce and the body hash. The backend
    /// rejects stale timestamps and reused nonces (replay protection).
    static func signature(secret: String, method: String, pathAndQuery: String, timestamp: String, nonce: String, body: Data) -> String {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonical = [method, pathAndQuery, timestamp, nonce, bodyHash].joined(separator: "\n")
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return Data(mac).base64EncodedString()
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: String]? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw BankingError.invalidBackendURL
        }
        components.path += path
        // Strict RFC 3986 encoding ("+" and "/" included), so the signed bytes and the bytes the
        // server parses are identical.
        components.percentEncodedQuery = query.isEmpty ? nil : query.map {
            "\(Self.encode($0.name))=\(Self.encode($0.value ?? ""))"
        }.joined(separator: "&")
        guard let url = components.url else { throw BankingError.invalidBackendURL }
        let pathAndQuery = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data()
        if body != nil {
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let timestamp = String(Int(now().timeIntervalSince1970))
        let nonce = nonce()
        request.setValue(credentials.clientID, forHTTPHeaderField: "X-WOS-Client")
        request.setValue(timestamp, forHTTPHeaderField: "X-WOS-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-WOS-Nonce")
        request.setValue(Self.signature(secret: credentials.clientSecret, method: method, pathAndQuery: pathAndQuery,
                                        timestamp: timestamp, nonce: nonce, body: data),
                         forHTTPHeaderField: "X-WOS-Signature")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if userPresent { request.setValue("1", forHTTPHeaderField: "X-WOS-User-Present") }
        return request
    }

    static func encode(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func pathID(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 128, value.allSatisfy(isIDCharacter) else { throw BankingError.invalidResponse }
        return value
    }

    /// No automatic retries: Enable Banking/PSD2 limits unattended access per day, so a retry
    /// storm could lock the user out. Callers decide when to try again.
    private func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                    body: [String: String]? = nil) async throws -> T {
        try Task.checkCancellation()
        let request = try request(method, path, query: query, body: body)
        try Self.validate(request, allowedHost: config.host)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch let error as BankingError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw Self.map(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BankingError.network
        }
        switch response.statusCode {
        case 200...299:
            do { return try JSONDecoder().decode(T.self, from: data) } catch { throw BankingError.invalidResponse }
        default:
            throw Self.mapStatus(response, data: data)
        }
    }

    static func mapStatus(_ response: HTTPURLResponse, data: Data) -> BankingError {
        let code = (try? JSONDecoder().decode(BankErrorDTO.self, from: data))?.error ?? ""
        switch (response.statusCode, code) {
        case (401, _), (403, "forbidden"): return .unauthorized
        case (_, "consent_expired"): return .consentExpired
        case (_, "consent_revoked"): return .consentRevoked
        case (_, "attempt_pending"): return .attemptPending
        case (_, "attempt_expired"): return .attemptExpired
        case (_, "authorization_rejected"): return .authorizationRejected
        case (_, "authorization_cancelled"): return .authorizationCancelled
        case (_, "authorization_failed"): return .authorizationFailed
        case (404, _): return .notFound
        case (429, _):
            let wait = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(retryAfter: wait)
        case (502, _), (503, _): return .bankUnavailable
        case (504, _), (408, _): return .timeout
        case (500...599, _): return .server(response.statusCode)
        default: return .invalidResponse
        }
    }

    static func map(_ error: URLError) -> BankingError {
        switch error.code {
        case .timedOut: .timeout
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: .offline
        default: .network
        }
    }
}

// MARK: - Authorization callback

/// The backend finishes the Enable Banking redirect itself (it exchanges the code server-side)
/// and then sends the browser to `wealthos://bank-callback?attempt=…&result=…`. The URL carries
/// no code, token or account data — only the attempt id this app started — so a forged or
/// replayed callback can at most make the app ask the backend about an attempt it owns.
nonisolated struct BankCallback: Equatable, Sendable {
    enum Result: Equatable, Sendable { case success, cancelled, rejected, failed }
    let attemptID: String
    let result: Result

    static func parse(_ url: URL, expectedAttemptID: String) throws -> BankCallback {
        guard url.scheme?.lowercased() == BankingConstants.callbackScheme,
              url.host?.lowercased() == BankingConstants.callbackHost,
              url.path.isEmpty || url.path == "/",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw BankingError.invalidCallback
        }
        var values: [String: String] = [:]
        for item in items {
            // Repeated parameters are a classic injection trick; refuse instead of guessing.
            guard values[item.name] == nil, let value = item.value else { throw BankingError.invalidCallback }
            values[item.name] = value
        }
        guard let attempt = values["attempt"], !expectedAttemptID.isEmpty,
              constantTimeEquals(attempt, expectedAttemptID) else { throw BankingError.invalidCallback }
        let result: Result
        switch values["result"] {
        case "success": result = .success
        case "error":
            switch values["error"] {
            case "access_denied", "rejected": result = .rejected
            case "cancelled": result = .cancelled
            default: result = .failed
            }
        default: throw BankingError.invalidCallback
        }
        return BankCallback(attemptID: attempt, result: result)
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
