import Foundation
import CryptoKit

// Binance Spot / Wallet / Simple Earn REST API, per https://developers.binance.com/docs
// - SIGNED (USER_DATA) requests: header `X-MBX-APIKEY`; query `…&recvWindow=…&timestamp=<ms>&signature=<hex>`,
//   where signature = HMAC-SHA256(secret, query string). No request body is ever sent.
// - Error payload: {"code": -1121, "msg": "…"}. 429 = rate limited, 418 = IP ban, both with Retry-After.
// WealthOS uses read-only GET endpoints only, on api.binance.com only.

nonisolated struct BinanceCredentials: Sendable, Equatable {
    let apiKey: String
    let secretKey: String

    init(apiKey: String, secretKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HMAC keys are ASCII letters and digits. Anything else (an RSA/Ed25519 PEM, pasted
    /// whitespace or control characters) is refused before it can reach a request header.
    var isComplete: Bool {
        func valid(_ text: String) -> Bool {
            !text.isEmpty && text.count <= 256 && text.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
        }
        return valid(apiKey) && valid(secretKey)
    }
}

/// The complete set of Binance calls WealthOS can make. All are GETs; there is deliberately
/// no order, transfer, withdrawal, convert or Earn subscribe/redeem endpoint.
nonisolated enum BinanceEndpoint: String, CaseIterable, Sendable {
    case serverTime = "/api/v3/time"                                    // public, weight 1
    case exchangeInfo = "/api/v3/exchangeInfo"                          // public, weight 20
    case tickerPrice = "/api/v3/ticker/price"                           // public, weight 4 (all symbols)
    case account = "/api/v3/account"                                    // USER_DATA, weight 20
    case apiRestrictions = "/sapi/v1/account/apiRestrictions"           // USER_DATA, weight 1
    case flexiblePositions = "/sapi/v1/simple-earn/flexible/position"   // USER_DATA, weight 150
    case lockedPositions = "/sapi/v1/simple-earn/locked/position"       // USER_DATA, weight 150

    var path: String { rawValue }

    var isSigned: Bool {
        switch self {
        case .serverTime, .exchangeInfo, .tickerPrice: false
        default: true
        }
    }
}

nonisolated enum BinanceError: LocalizedError, Equatable, Sendable {
    case missingCredentials
    case invalidCredentials
    case missingPermission
    case keyNotReadOnly([String])
    case timestampOutOfSync
    case rateLimited(retryAfter: TimeInterval?)
    case ipBanned(retryAfter: TimeInterval?)
    case accessDenied
    case timeout
    case offline
    case network
    case server(Int)
    case http(Int)
    case api(code: Int)
    case invalidResponse
    case blockedRequest
    case busy
    case credentialStorage
    case credentialStateUncertain
    case keychainUnavailable
    case localSaveFailed

    /// Never includes credentials, signatures or response bodies.
    var errorDescription: String? {
        switch self {
        case .missingCredentials: "Enter the API key and the secret key (HMAC keys only)."
        case .invalidCredentials: "Binance rejected the API key or secret. It may be wrong, deleted, or restricted to other IP addresses — reconnect with a new key."
        case .missingPermission: "This API key doesn't have the “Enable Reading” permission."
        case .keyNotReadOnly(let names):
            "For your safety WealthOS only accepts read-only keys. This key also allows: \(names.joined(separator: ", ")). Create a new key with only “Enable Reading”."
        case .timestampOutOfSync: "Your iPhone's clock differs too much from Binance's. Turn on Set Automatically in Settings → General → Date & Time."
        case .rateLimited(let wait):
            wait.map { "Binance is limiting requests. Try again in \(Int($0.rounded(.up))) s." } ?? "Binance is limiting requests. Try again shortly."
        case .ipBanned(let wait):
            wait.map { "Binance temporarily blocked requests from this network. Try again in \(Self.duration($0))." } ?? "Binance temporarily blocked requests from this network."
        case .accessDenied: "Binance refused the request (403). This can be a temporary firewall block."
        case .timeout: "Binance didn't respond in time."
        case .offline: "You're offline. Showing the last synced Binance data."
        case .network: "Couldn't reach Binance."
        case .server(let code): "Binance had a server problem (\(code)). Try again later."
        case .http(let code): "Binance returned an unexpected response (\(code))."
        case .api(let code): "Binance returned error \(code)."
        case .invalidResponse: "Binance returned data WealthOS couldn't read. Nothing was changed."
        case .blockedRequest: "Blocked a request that wasn't a read-only call to Binance."
        case .busy: "A Binance sync is already running."
        case .credentialStorage: "The iOS Keychain didn't accept the change, so the previous Binance connection state was kept. Try again."
        case .credentialStateUncertain: "After a Keychain error WealthOS can't confirm which Binance key is stored, so syncing is paused. Disconnect, then connect again."
        case .keychainUnavailable: "The Keychain isn't available right now (the iPhone may be locked). Nothing was changed — try again."
        case .localSaveFailed: "WealthOS couldn't save the Binance data on this iPhone. Nothing was changed."
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        seconds < 120 ? "\(Int(seconds.rounded(.up))) s" : "\(Int((seconds / 60).rounded(.up))) min"
    }
}

// MARK: - Response schemas (only the documented fields WealthOS reads)

nonisolated struct BinanceAccountInfo: Decodable, Sendable {
    struct Balance: Decodable, Sendable {
        var asset: String?
        /// Decimal strings, e.g. "0.59118264" — never parsed through Double.
        var free: String?
        var locked: String?
    }
    var accountType: String?
    var balances: [Balance]?
    var uid: Int64?
}

/// `GET /sapi/v1/account/apiRestrictions`.
nonisolated struct BinanceAPIRestrictions: Decodable, Sendable, Equatable {
    var ipRestrict: Bool?
    var enableReading: Bool?
    var enableWithdrawals: Bool?
    var enableInternalTransfer: Bool?
    var enableMargin: Bool?
    var enableFutures: Bool?
    var permitsUniversalTransfer: Bool?
    var enableVanillaOptions: Bool?
    var enableFixApiTrade: Bool?
    var enableSpotAndMarginTrading: Bool?
    var enablePortfolioMarginTrading: Bool?

    /// Every enabled permission that can trade or move funds. Must be empty.
    var riskyPermissions: [String] {
        [(enableWithdrawals, "withdrawals"), (enableInternalTransfer, "internal transfers"),
         (permitsUniversalTransfer, "universal transfers"), (enableSpotAndMarginTrading, "spot & margin trading"),
         (enableMargin, "margin"), (enableFutures, "futures"), (enableVanillaOptions, "options"),
         (enablePortfolioMarginTrading, "portfolio margin trading"), (enableFixApiTrade, "FIX API trading")]
            .filter { $0.0 == true }.map(\.1)
    }
}

/// Accepts identifiers documented as numbers (`positionId`) or strings (`productId`).
nonisolated struct BinanceID: Decodable, Sendable, Equatable {
    let value: String
    init(_ value: String) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text; return }
        value = String(try container.decode(Int64.self))
    }
}

nonisolated struct BinancePage<Row: Decodable & Sendable>: Decodable, Sendable {
    var rows: [Row]?
    var total: Int?
}

nonisolated struct BinanceFlexiblePosition: Decodable, Sendable {
    var asset: String?
    var totalAmount: String?
    var productId: BinanceID?
}

nonisolated struct BinanceLockedPosition: Decodable, Sendable {
    var positionId: BinanceID?
    var projectId: String?
    var asset: String?
    var amount: String?
    var status: String?
}

nonisolated struct BinanceExchangeInfo: Decodable, Sendable {
    struct Symbol: Decodable, Sendable {
        var symbol: String?
        var status: String?
        var baseAsset: String?
        var quoteAsset: String?
    }
    var symbols: [Symbol]?
}

nonisolated struct BinanceTickerPrice: Decodable, Sendable {
    var symbol: String?
    var price: String?
}

nonisolated struct BinanceServerTime: Decodable, Sendable {
    var serverTime: Int64?
}

nonisolated struct BinanceErrorBody: Decodable, Sendable {
    var code: Int?
}

// MARK: - Signing

nonisolated enum BinanceSigner {
    /// RFC 3986 unreserved characters; everything else is percent-encoded before signing.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    static func query(_ items: [(String, String)]) -> String {
        items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Lowercase hex HMAC-SHA256 of the exact query string that is sent.
    static func signature(for payload: String, secret: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }
}

/// Server time minus local time (ms), learned from `/api/v3/time` after a -1021 error.
nonisolated final class BinanceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: Int64 = 0

    var offsetMilliseconds: Int64 { lock.withLock { offset } }
    func setOffset(_ value: Int64) { lock.withLock { offset = value } }
}

// MARK: - Transport

/// URLSession transport that can only send GETs to the allow-listed Binance paths on
/// api.binance.com. Redirects are never followed (the request carries the API key).
/// Ephemeral session: no cookies, no URL cache, no credential storage; nothing is logged.
nonisolated final class BinanceTransport: NSObject, HTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    static let host = "api.binance.com"
    /// The trading-symbol list is a few MB; nothing else comes close.
    static let maximumBytes = 30_000_000
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
        guard let url = request.url, url.scheme?.lowercased() == "https", url.host?.lowercased() == host, url.port == nil,
              url.user == nil, url.fragment == nil,
              (request.httpMethod ?? "GET") == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let endpoint = BinanceEndpoint(rawValue: url.path) else {
            throw BinanceError.blockedRequest
        }
        // The API key travels only with signed requests, and signed requests must be signed.
        let hasKey = request.value(forHTTPHeaderField: "X-MBX-APIKEY") != nil
        let hasSignature = url.query?.contains("signature=") == true
        guard endpoint.isSigned == hasKey, endpoint.isSigned == hasSignature else { throw BinanceError.blockedRequest }
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Self.validate(request)
        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse, http.url?.host?.lowercased() == Self.host else {
            throw BinanceError.blockedRequest
        }
        guard data.count <= Self.maximumBytes else { throw BinanceError.invalidResponse }
        return (data, http)
    }

    /// Never follow redirects: they could forward the API key elsewhere.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Client

nonisolated struct BinanceClient: Sendable {
    static let baseURL = "https://api.binance.com"
    /// Documented maximum page size of the Simple Earn position lists.
    static let pageSize = 100
    static let maxPages = 50

    let credentials: BinanceCredentials
    let http: HTTPClient
    var clock = BinanceClock()
    /// Milliseconds; documented default 5000, maximum 60000.
    var recvWindow = 10_000
    var maxAttempts = 3
    /// Longest server-requested wait WealthOS will sit through before giving up.
    var maxRetryWait: TimeInterval = 15
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    var now: @Sendable () -> Date = { .now }

    func timestamp() -> Int64 {
        Int64((now().timeIntervalSince1970 * 1000).rounded(.down)) + clock.offsetMilliseconds
    }

    func request(for endpoint: BinanceEndpoint, parameters: [(String, String)] = []) throws -> URLRequest {
        var url = Self.baseURL + endpoint.path
        var items = parameters
        if endpoint.isSigned {
            items.append(("recvWindow", String(recvWindow)))
            items.append(("timestamp", String(timestamp())))
            let query = BinanceSigner.query(items)
            url += "?" + query + "&signature=" + BinanceSigner.signature(for: query, secret: credentials.secretKey)
        } else if !items.isEmpty {
            url += "?" + BinanceSigner.query(items)
        }
        guard let resolved = URL(string: url) else { throw BinanceError.blockedRequest }
        var request = URLRequest(url: resolved, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if endpoint.isSigned { request.setValue(credentials.apiKey, forHTTPHeaderField: "X-MBX-APIKEY") }
        return request
    }

    func apiRestrictions() async throws -> BinanceAPIRestrictions { try await fetch(.apiRestrictions) }
    func account() async throws -> BinanceAccountInfo { try await fetch(.account, parameters: [("omitZeroBalances", "true")]) }
    func flexiblePositions() async throws -> [BinanceFlexiblePosition] { try await allPages(.flexiblePositions) }
    func lockedPositions() async throws -> [BinanceLockedPosition] { try await allPages(.lockedPositions) }
    func tradingSymbols() async throws -> BinanceExchangeInfo {
        try await fetch(.exchangeInfo, parameters: [("symbolStatus", "TRADING"), ("showPermissionSets", "false")])
    }
    /// All trading symbols in one request (weight 4) instead of one request per asset.
    func prices() async throws -> [BinanceTickerPrice] { try await fetch(.tickerPrice, parameters: [("symbolStatus", "TRADING")]) }

    /// Reads every page; a list longer than `maxPages` is refused rather than silently truncated.
    func allPages<Row: Decodable & Sendable>(_ endpoint: BinanceEndpoint) async throws -> [Row] {
        var rows: [Row] = []
        for page in 1...Self.maxPages {
            let result: BinancePage<Row> = try await fetch(endpoint, parameters: [("current", String(page)), ("size", String(Self.pageSize))])
            let batch = result.rows ?? []
            rows += batch
            if batch.count < Self.pageSize || (result.total.map { rows.count >= $0 } ?? false) { return rows }
        }
        throw BinanceError.invalidResponse
    }

    /// Retries timeouts/5xx with backoff (1 s, 2 s); honours Retry-After on 429 (418 bans are
    /// never retried); re-syncs the clock once on -1021. Rejected keys are never retried.
    func fetch<T: Decodable>(_ endpoint: BinanceEndpoint, parameters: [(String, String)] = []) async throws -> T {
        var attempt = 0
        var resyncedClock = false
        while true {
            attempt += 1
            try Task.checkCancellation()
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await http.get(try request(for: endpoint, parameters: parameters))
            } catch let error as BinanceError {
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
                throw BinanceError.network
            }

            let status = response.statusCode
            if status == 200 {
                do { return try JSONDecoder().decode(T.self, from: data) } catch { throw BinanceError.invalidResponse }
            }
            let code = (try? JSONDecoder().decode(BinanceErrorBody.self, from: data))?.code
            if code == -1021 {
                guard !resyncedClock else { throw BinanceError.timestampOutOfSync }
                resyncedClock = true
                try await synchronizeClock()
                continue
            }
            if status == 401 || [-2014, -2015, -1022].contains(code) { throw BinanceError.invalidCredentials }
            if status == 418 { throw BinanceError.ipBanned(retryAfter: Self.retryAfter(response)) }
            if status == 429 || code == -1003 {
                let wait = Self.retryAfter(response)
                if attempt < maxAttempts, (wait ?? 5) <= maxRetryWait {
                    try await sleep(max(wait ?? 5, 1))
                    continue
                }
                throw BinanceError.rateLimited(retryAfter: wait)
            }
            if status == 403 { throw BinanceError.accessDenied }
            if (500...599).contains(status) {
                if attempt < maxAttempts {
                    try await sleep(backoff(attempt))
                    continue
                }
                throw BinanceError.server(status)
            }
            if let code { throw BinanceError.api(code: code) }
            throw BinanceError.http(status)
        }
    }

    /// offset = serverTime − local midpoint of the round trip.
    func synchronizeClock() async throws {
        let sent = now()
        let time: BinanceServerTime = try await fetch(.serverTime)
        guard let server = time.serverTime else { throw BinanceError.invalidResponse }
        let midpoint = (sent.timeIntervalSince1970 + now().timeIntervalSince1970) / 2 * 1000
        clock.setOffset(server - Int64(midpoint.rounded()))
    }

    private func backoff(_ attempt: Int) -> TimeInterval { pow(2, Double(attempt - 1)) }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) else { return nil }
        return max(0, seconds)
    }

    static func map(_ error: URLError) -> BinanceError {
        switch error.code {
        case .timedOut: .timeout
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: .offline
        default: .network
        }
    }
}
