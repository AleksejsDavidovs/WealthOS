import Foundation

// Trading 212 Public API (beta), per https://docs.trading212.com/api
// - Auth: HTTP Basic, base64("API_KEY:API_SECRET").
// - Only Invest and Stocks ISA accounts; all values in the account's primary currency.
// WealthOS uses six read-only GET endpoints and nothing else.

nonisolated enum Trading212Environment: String, CaseIterable, Identifiable, Sendable {
    case live, demo

    var id: String { rawValue }
    var title: String { self == .live ? "Live" : "Demo (practice)" }
    var host: String { self == .live ? "live.trading212.com" : "demo.trading212.com" }
    var baseURL: String { "https://\(host)/api/v0" }
}

nonisolated struct Trading212Credentials: Sendable, Equatable {
    let apiKey: String
    let apiSecret: String

    init(apiKey: String, apiSecret: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiSecret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isComplete: Bool { !apiKey.isEmpty && !apiSecret.isEmpty }

    /// Documented scheme: `Authorization: Basic base64(API_KEY:API_SECRET)`.
    var authorizationHeader: String {
        "Basic " + Data("\(apiKey):\(apiSecret)".utf8).base64EncodedString()
    }
}

/// The complete set of Trading 212 calls WealthOS can make. All are read-only GETs; there is
/// deliberately no order, pie or account-changing endpoint, and no way to construct one.
nonisolated enum Trading212Endpoint: String, CaseIterable, Sendable {
    case accountSummary = "/equity/account/summary"   // 1 req / 5 s
    case positions = "/equity/positions"              // 1 req / 1 s
    case instruments = "/equity/metadata/instruments" // 1 req / 50 s
    case dividends = "/equity/history/dividends"      // 20 req / 1 min, paginated; scope history:dividends
    case orders = "/equity/history/orders"            // 20 req / 1 min, paginated; scope history:orders (read-only history)
    case transactions = "/equity/history/transactions" // 20 req / 1 min, paginated; scope history:transactions

    var path: String { rawValue }
}

nonisolated enum Trading212Error: LocalizedError, Equatable, Sendable {
    case missingCredentials
    case invalidCredentials
    case missingPermission
    case rateLimited(retryAfter: TimeInterval?)
    case timeout
    case offline
    case network
    case server(Int)
    case http(Int)
    case invalidResponse
    case blockedRequest
    case busy
    case credentialStorage
    case credentialStateUncertain
    case keychainUnavailable
    case localSaveFailed

    /// Never includes credentials or response bodies.
    var errorDescription: String? {
        switch self {
        case .missingCredentials: "Enter both the API key and the API secret."
        case .invalidCredentials: "Trading 212 rejected the API key. It may be wrong, expired or revoked — reconnect with a new key."
        case .missingPermission: "This API key lacks a required read permission (account, portfolio or instrument data)."
        case .rateLimited(let wait):
            wait.map { "Trading 212 is limiting requests. Try again in \(Int($0.rounded(.up))) s." } ?? "Trading 212 is limiting requests. Try again shortly."
        case .timeout: "Trading 212 didn't respond in time."
        case .offline: "You're offline. Showing the last synced Trading 212 data."
        case .network: "Couldn't reach Trading 212."
        case .server(let code): "Trading 212 had a server problem (\(code)). Try again later."
        case .http(let code): "Trading 212 returned an unexpected response (\(code))."
        case .invalidResponse: "Trading 212 returned data WealthOS couldn't read. Nothing was changed."
        case .blockedRequest: "Blocked a request that wasn't a read-only call to Trading 212."
        case .busy: "A Trading 212 sync is already running."
        case .credentialStorage: "The iOS Keychain didn't accept the change, so the previous Trading 212 connection state was kept. Try again."
        case .credentialStateUncertain: "After a Keychain error WealthOS can't confirm which Trading 212 key is stored, so syncing is paused. Disconnect, then connect again."
        case .keychainUnavailable: "The Keychain isn't available right now (the iPhone may be locked). Nothing was changed — try again."
        case .localSaveFailed: "WealthOS couldn't save the Trading 212 data on this iPhone. Nothing was changed."
        }
    }
}

// MARK: - Response schemas (all fields optional: the API is in beta)

nonisolated struct T212AccountSummary: Decodable, Sendable {
    struct Cash: Decodable, Sendable {
        var availableToTrade: Decimal?
        var inPies: Decimal?
        var reservedForOrders: Decimal?
    }
    struct Investments: Decodable, Sendable {
        var currentValue: Decimal?
        var realizedProfitLoss: Decimal?
        var totalCost: Decimal?
        var unrealizedProfitLoss: Decimal?
    }
    var cash: Cash?
    var currency: String?
    var id: Int?
    var investments: Investments?
    var totalValue: Decimal?
}

nonisolated struct T212Position: Decodable, Sendable {
    struct Instrument: Decodable, Sendable {
        var currency: String?
        var isin: String?
        var name: String?
        var ticker: String?
    }
    struct WalletImpact: Decodable, Sendable {
        var currency: String?
        var currentValue: Decimal?
        var fxImpact: Decimal?
        var totalCost: Decimal?
        var unrealizedProfitLoss: Decimal?
    }
    var averagePricePaid: Decimal?
    var createdAt: String?
    var currentPrice: Decimal?
    var quantity: Decimal?
    var instrument: Instrument?
    var walletImpact: WalletImpact?
}

nonisolated struct T212Instrument: Decodable, Sendable {
    var ticker: String?
    var name: String?
    var shortName: String?
    var isin: String?
    var currencyCode: String?
    var type: String?
}

nonisolated struct T212DividendPage: Decodable, Sendable {
    var items: [T212Dividend]?
    var nextPagePath: String?
}

nonisolated struct T212Dividend: Decodable, Sendable {
    struct Instrument: Decodable, Sendable {
        var currency: String?
        var isin: String?
        var name: String?
        var ticker: String?
    }
    /// In the account's primary currency (`currency`).
    var amount: Decimal?
    var currency: String?
    var grossAmountPerShare: Decimal?
    var instrument: Instrument?
    var paidOn: String?
    var quantity: Decimal?
    var reference: String?
    var ticker: String?
    var tickerCurrency: String?
    var type: String?
}

nonisolated struct T212OrderPage: Decodable, Sendable {
    var items: [T212HistoricalOrder]?
    var nextPagePath: String?
}

nonisolated struct T212HistoricalOrder: Decodable, Sendable {
    struct Order: Decodable, Sendable {
        var id: Int64?
        var createdAt: String?
        var currency: String?
        var filledQuantity: Decimal?
        var filledValue: Decimal?
        var instrument: T212Dividend.Instrument?
        var side: String?
        var status: String?
        var ticker: String?
        var type: String?
    }
    struct Tax: Decodable, Sendable {
        var currency: String?
        var name: String?
        var quantity: Decimal?
    }
    struct WalletImpact: Decodable, Sendable {
        var currency: String?
        var fxRate: Decimal?
        var netValue: Decimal?
        var realisedProfitLoss: Decimal?
        var taxes: [Tax]?
    }
    struct Fill: Decodable, Sendable {
        var id: Int64?
        var filledAt: String?
        var price: Decimal?
        var quantity: Decimal?
        var type: String?
        var walletImpact: WalletImpact?
    }
    var order: Order?
    var fill: Fill?
}

nonisolated struct T212TransactionPage: Decodable, Sendable {
    var items: [T212Transaction]?
    var nextPagePath: String?
}

nonisolated struct T212Transaction: Decodable, Sendable {
    var amount: Decimal?
    var currency: String?
    var dateTime: String?
    var reference: String?
    var type: String?
}

// MARK: - Transport

/// URLSession transport that can only send authenticated GETs to the two Trading 212 API
/// hosts. Redirects are never followed (the request carries credentials). Ephemeral session:
/// no cookies, no URL cache, no credential storage; nothing is logged.
nonisolated final class Trading212Transport: NSObject, HTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    /// The instrument list for all markets is several MB.
    static let maximumBytes = 40_000_000
    static let allowedHosts: Set<String> = Set(Trading212Environment.allCases.map(\.host))
    private let session: URLSession

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpAdditionalHeaders = ["User-Agent": "WealthOS", "Accept": "application/json"]
        session = URLSession(configuration: configuration)
        super.init()
    }

    static func validate(_ request: URLRequest) throws {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), allowedHosts.contains(host),
              (request.httpMethod ?? "GET") == "GET", request.httpBody == nil,
              Trading212Endpoint.allCases.contains(where: { url.path.hasSuffix($0.path) }) else {
            throw Trading212Error.blockedRequest
        }
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Self.validate(request)
        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse,
              let host = http.url?.host?.lowercased(), Self.allowedHosts.contains(host) else {
            throw Trading212Error.blockedRequest
        }
        guard data.count <= Self.maximumBytes else { throw Trading212Error.invalidResponse }
        return (data, http)
    }

    /// Never follow redirects: they could forward the Authorization header elsewhere.
    /// (Completion-handler form: the async variant crashes the Swift 6.4 compiler.)
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Client

nonisolated struct Trading212Client: Sendable {
    let environment: Trading212Environment
    let credentials: Trading212Credentials
    let http: HTTPClient
    var maxAttempts = 3
    /// Longest server-requested wait WealthOS will sit through before giving up.
    var maxRetryWait: TimeInterval = 15
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    var now: @Sendable () -> Date = { .now }

    func request(for endpoint: Trading212Endpoint, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(string: environment.baseURL + endpoint.path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func accountSummary() async throws -> T212AccountSummary { try await fetch(.accountSummary) }
    func positions() async throws -> [T212Position] { try await fetch(.positions) }
    func instruments() async throws -> [T212Instrument] { try await fetch(.instruments) }

    /// One page of paid-out dividends, newest first. `cursor` comes from the previous page's
    /// `nextPagePath`; only that value is taken from it — the request is always built here.
    func dividends(cursor: String?) async throws -> T212DividendPage {
        try await fetch(.dividends, query: Self.pageQuery(cursor))
    }

    /// Filled and cancelled orders with their fills (history only — WealthOS never places orders).
    func orders(cursor: String?) async throws -> T212OrderPage {
        try await fetch(.orders, query: Self.pageQuery(cursor))
    }

    /// Deposits, withdrawals, fees, transfers and interest.
    func transactions(cursor: String?) async throws -> T212TransactionPage {
        try await fetch(.transactions, query: Self.pageQuery(cursor))
    }

    static func pageQuery(_ cursor: String?) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return query
    }

    /// The `cursor` value of a `nextPagePath` such as "/api/v0/equity/history/dividends?limit=50&cursor=123".
    /// Only that value is used (the path and host are ignored); it must be a short plain token.
    static func cursor(fromNextPagePath path: String?) -> String? {
        guard let path, let items = URLComponents(string: path)?.queryItems,
              let value = items.first(where: { $0.name == "cursor" })?.value,
              !value.isEmpty, value.count <= 200,
              value.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || "-_.:+=".contains($0) }) else { return nil }
        return value
    }

    /// Retries 408/5xx/timeouts with exponential backoff (1 s, 2 s) and honours Retry-After /
    /// x-ratelimit-reset on 429. 401/403 are never retried.
    func fetch<T: Decodable>(_ endpoint: Trading212Endpoint, query: [URLQueryItem] = []) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await http.get(request(for: endpoint, query: query))
            } catch let error as Trading212Error {
                throw error
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                let mapped = Self.map(error)
                if mapped == .timeout, attempt < maxAttempts {
                    try await sleep(backoff(attempt))
                    continue
                }
                throw mapped
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Trading212Error.network
            }

            switch response.statusCode {
            case 200:
                do { return try JSONDecoder().decode(T.self, from: data) } catch { throw Trading212Error.invalidResponse }
            case 401:
                throw Trading212Error.invalidCredentials
            case 403:
                throw Trading212Error.missingPermission
            case 429:
                let wait = Self.retryAfter(response, now: now())
                if attempt < maxAttempts, (wait ?? 5) <= maxRetryWait {
                    try await sleep(max(wait ?? 5, 1))
                    continue
                }
                throw Trading212Error.rateLimited(retryAfter: wait)
            case 408, 500...599:
                if attempt < maxAttempts {
                    try await sleep(backoff(attempt))
                    continue
                }
                throw response.statusCode == 408 ? Trading212Error.timeout : Trading212Error.server(response.statusCode)
            default:
                throw Trading212Error.http(response.statusCode)
            }
        }
    }

    private func backoff(_ attempt: Int) -> TimeInterval { pow(2, Double(attempt - 1)) }

    static func retryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
        if let value = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds)
        }
        if let value = response.value(forHTTPHeaderField: "x-ratelimit-reset"), let reset = TimeInterval(value) {
            return max(0, reset - now.timeIntervalSince1970)
        }
        return nil
    }

    static func map(_ error: URLError) -> Trading212Error {
        switch error.code {
        case .timedOut: .timeout
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: .offline
        default: .network
        }
    }
}
