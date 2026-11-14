import Foundation

// MARK: - HTTP

/// Minimal read-only HTTP interface so providers can be tested with canned responses.
nonisolated protocol HTTPClient: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated enum MarketHosts {
    /// The only servers WealthOS is allowed to contact.
    static let allowed: Set<String> = ["api.coingecko.com", "www.alphavantage.co", "api.frankfurter.dev"]

    static func validate(_ url: URL?) throws {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), allowed.contains(host) else {
            throw MarketDataError.blockedHost
        }
    }
}

/// URLSession client hardened for public market data:
/// HTTPS only, allowlisted hosts (including redirects), ephemeral session with no cookies,
/// no disk cache, generic User-Agent, TLS 1.2+, short timeouts and a response size cap.
nonisolated final class URLSessionHTTPClient: NSObject, HTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    static let maximumBytes = 1_000_000
    private let session: URLSession

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpAdditionalHeaders = ["User-Agent": "WealthOS", "Accept": "application/json"]
        session = URLSession(configuration: configuration)
        super.init()
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try MarketHosts.validate(request.url)
        guard request.httpMethod == nil || request.httpMethod == "GET" else { throw MarketDataError.blockedHost }
        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else { throw MarketDataError.invalidResponse("no HTTP response") }
        try MarketHosts.validate(http.url)
        guard data.count <= Self.maximumBytes else { throw MarketDataError.invalidResponse("response too large") }
        return (data, http)
    }

    /// Redirects are followed only to other allowlisted HTTPS hosts.
    /// (Completion-handler form: the async variant crashes the Swift 6.4 compiler.)
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler((try? MarketHosts.validate(request.url)) != nil ? request : nil)
    }
}

nonisolated enum ResponseCheck {
    /// Maps HTTP status codes before any body is parsed.
    static func check(_ response: HTTPURLResponse, provider: MarketProvider) throws {
        switch response.statusCode {
        case 200: return
        case 429: throw MarketDataError.rateLimited(provider)
        case 401, 403: throw MarketDataError.missingAPIKey(provider)
        default: throw MarketDataError.http(response.statusCode)
        }
    }

    static func makeRequest(_ components: URLComponents, headers: [String: String] = [:]) throws -> URLRequest {
        guard let url = components.url else { throw MarketDataError.invalidResponse("bad URL") }
        try MarketHosts.validate(url)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
}

// MARK: - CoinGecko (crypto)

/// https://docs.coingecko.com — /simple/price and /search. Works keyless; a free Demo key
/// (header `x-cg-demo-api-key`) raises the limit. Data is cached by CoinGecko for ~60 s.
nonisolated enum CoinGeckoAPI {
    static func priceRequest(ids: [String], currency: String, apiKey: String?) throws -> URLRequest {
        let clean = ids.map { $0.lowercased() }
        guard !clean.isEmpty, clean.allSatisfy(QuoteValidator.isValidCoinID) else {
            throw MarketDataError.invalidSymbol(ids.joined(separator: ","))
        }
        guard QuoteValidator.isValidCurrency(currency) else { throw MarketDataError.invalidSymbol(currency) }
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: clean.joined(separator: ",")),
            URLQueryItem(name: "vs_currencies", value: currency.lowercased()),
            URLQueryItem(name: "include_last_updated_at", value: "true"),
            URLQueryItem(name: "precision", value: "full"),
        ]
        return try ResponseCheck.makeRequest(components, headers: apiKey.map { ["x-cg-demo-api-key": $0] } ?? [:])
    }

    /// Response: {"bitcoin": {"eur": 68153.61, "last_updated_at": 1794046656}}
    static func parsePrices(_ data: Data, ids: [String], currency: String, fetchedAt: Date) throws -> (quotes: [QuoteValue], missing: [String]) {
        let decoded: [String: [String: Decimal]]
        do { decoded = try JSONDecoder().decode([String: [String: Decimal]].self, from: data) } catch {
            throw MarketDataError.invalidResponse("CoinGecko format")
        }
        let key = currency.lowercased()
        var quotes: [QuoteValue] = []
        var missing: [String] = []
        for id in ids.map({ $0.lowercased() }) {
            guard let entry = decoded[id], let raw = entry[key] else { missing.append(id); continue }
            let price = try QuoteValidator.normalized(raw, symbol: id)
            let updated = entry["last_updated_at"].map { Date(timeIntervalSince1970: $0.doubleValue) }
            let quoteTime = updated.flatMap { $0 <= fetchedAt.addingTimeInterval(300) ? $0 : nil }
            quotes.append(QuoteValue(provider: .coinGecko, symbol: id, currency: currency.uppercased(), price: price,
                                     quoteTime: quoteTime, fetchedAt: fetchedAt))
        }
        return (quotes, missing)
    }

    static func searchRequest(query: String, apiKey: String?) throws -> URLRequest {
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/search")!
        components.queryItems = [URLQueryItem(name: "query", value: String(query.prefix(40)))]
        return try ResponseCheck.makeRequest(components, headers: apiKey.map { ["x-cg-demo-api-key": $0] } ?? [:])
    }

    static func parseSearch(_ data: Data) throws -> [SymbolMatch] {
        struct Response: Decodable {
            struct Coin: Decodable { let id: String; let name: String; let symbol: String; let market_cap_rank: Int? }
            let coins: [Coin]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw MarketDataError.invalidResponse("CoinGecko search format")
        }
        return response.coins.prefix(15).filter { QuoteValidator.isValidCoinID($0.id) }.map {
            SymbolMatch(symbol: $0.id, name: $0.name,
                        detail: [$0.symbol.uppercased(), $0.market_cap_rank.map { "Rank #\($0)" }].compactMap { $0 }.joined(separator: " · "),
                        currency: nil)
        }
    }
}

// MARK: - Alpha Vantage (ETFs & stocks)

/// https://www.alphavantage.co/documentation — GLOBAL_QUOTE and SYMBOL_SEARCH.
/// Free key: 25 requests/day; the quote endpoint updates at the end of each trading day.
/// International listings use suffixes such as .DEX (XETRA) and .LON (London, quoted in GBX).
nonisolated enum AlphaVantageAPI {
    static func quoteRequest(symbol: String, apiKey: String) throws -> URLRequest {
        guard QuoteValidator.isValidTicker(symbol) else { throw MarketDataError.invalidSymbol(symbol) }
        var components = URLComponents(string: "https://www.alphavantage.co/query")!
        components.queryItems = [
            URLQueryItem(name: "function", value: "GLOBAL_QUOTE"),
            URLQueryItem(name: "symbol", value: symbol.uppercased()),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        return try ResponseCheck.makeRequest(components)
    }

    static func searchRequest(query: String, apiKey: String) throws -> URLRequest {
        var components = URLComponents(string: "https://www.alphavantage.co/query")!
        components.queryItems = [
            URLQueryItem(name: "function", value: "SYMBOL_SEARCH"),
            URLQueryItem(name: "keywords", value: String(query.prefix(40))),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        return try ResponseCheck.makeRequest(components)
    }

    /// Alpha Vantage reports limits and errors with HTTP 200 and a message key.
    static func checkMessages(_ object: [String: Any], symbol: String) throws {
        if let message = (object["Note"] ?? object["Information"]) as? String {
            let lower = message.lowercased()
            if lower.contains("api key") && (lower.contains("invalid") || lower.contains("missing")) {
                throw MarketDataError.missingAPIKey(.alphaVantage)
            }
            throw MarketDataError.rateLimited(.alphaVantage)
        }
        if object["Error Message"] != nil { throw MarketDataError.symbolNotFound(symbol) }
    }

    /// `quoteCurrency` is the listing currency (from search); "GBX" (pence) is converted to GBP.
    static func parseQuote(_ data: Data, symbol: String, quoteCurrency: String, fetchedAt: Date) throws -> QuoteValue {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MarketDataError.invalidResponse("Alpha Vantage format")
        }
        try checkMessages(object, symbol: symbol)
        guard let quote = object["Global Quote"] as? [String: Any], !quote.isEmpty else {
            throw MarketDataError.symbolNotFound(symbol)
        }
        guard let priceText = quote["05. price"] as? String,
              let raw = Decimal(string: priceText, locale: Locale(identifier: "en_US_POSIX")) else {
            throw MarketDataError.invalidResponse("missing price")
        }
        var price = raw
        var currency = quoteCurrency.uppercased()
        if currency == "GBX" || quoteCurrency == "GBp" {
            price = raw / 100
            currency = "GBP"
        }
        let normalized = try QuoteValidator.normalized(price, symbol: symbol)
        var tradingDay: Date?
        if let dayText = quote["07. latest trading day"] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            tradingDay = formatter.date(from: dayText).flatMap { $0 <= fetchedAt ? $0 : nil }
        }
        return QuoteValue(provider: .alphaVantage, symbol: symbol.uppercased(), currency: currency, price: normalized,
                          quoteTime: tradingDay, fetchedAt: fetchedAt)
    }

    static func parseSearch(_ data: Data) throws -> [SymbolMatch] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MarketDataError.invalidResponse("Alpha Vantage search format")
        }
        try checkMessages(object, symbol: "")
        let matches = object["bestMatches"] as? [[String: String]] ?? []
        return matches.prefix(15).compactMap { item in
            guard let symbol = item["1. symbol"], QuoteValidator.isValidTicker(symbol) else { return nil }
            let detail = [item["3. type"], item["4. region"]].compactMap { $0 }.joined(separator: " · ")
            return SymbolMatch(symbol: symbol, name: item["2. name"] ?? symbol, detail: detail, currency: item["8. currency"])
        }
    }
}

// MARK: - Frankfurter (exchange rates)

/// https://frankfurter.dev — free, no key, no quotas. Central-bank reference rates updated daily.
nonisolated enum FrankfurterAPI {
    static func latestRequest(base: String, symbols: [String]) throws -> URLRequest {
        let codes = symbols.map { $0.uppercased() }.filter { $0 != base.uppercased() }
        guard QuoteValidator.isValidCurrency(base), !codes.isEmpty, codes.allSatisfy(QuoteValidator.isValidCurrency) else {
            throw MarketDataError.invalidSymbol(symbols.joined(separator: ","))
        }
        var components = URLComponents(string: "https://api.frankfurter.dev/v1/latest")!
        components.queryItems = [
            URLQueryItem(name: "base", value: base.uppercased()),
            URLQueryItem(name: "symbols", value: codes.sorted().joined(separator: ",")),
        ]
        return try ResponseCheck.makeRequest(components)
    }

    /// Response: {"amount":1.0,"base":"EUR","date":"2026-11-06","rates":{"USD":1.1165}}.
    /// Returns quotes as "1 <code> = price <base>" to match `CurrencyRate.rateToBase`.
    static func parseLatest(_ data: Data, base: String, fetchedAt: Date) throws -> [QuoteValue] {
        struct Response: Decodable { let base: String; let date: String; let rates: [String: Decimal] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw MarketDataError.invalidResponse("Frankfurter format")
        }
        guard response.base.uppercased() == base.uppercased() else { throw MarketDataError.invalidResponse("unexpected base") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.date(from: response.date).flatMap { $0 <= fetchedAt ? $0 : nil }
        return try response.rates.compactMap { code, perBase in
            guard QuoteValidator.isValidCurrency(code), perBase > 0, perBase < 1_000_000 else {
                throw MarketDataError.invalidPrice(code)
            }
            let rateToBase = Money.round(1 / perBase, scale: 10)
            guard rateToBase > 0 else { throw MarketDataError.invalidPrice(code) }
            return QuoteValue(provider: .frankfurter, symbol: code.uppercased(), currency: base.uppercased(),
                              price: rateToBase, quoteTime: date, fetchedAt: fetchedAt)
        }
    }
}
