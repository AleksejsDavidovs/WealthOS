import Foundation
import Observation
import SwiftData

// MARK: - Parsing

nonisolated struct ParsedBinanceBalance: Sendable, Equatable {
    var key: String
    var asset: String
    var wallet: BinanceWallet
    var productRef: String
    var free: Decimal
    var locked: Decimal
    var amount: Decimal
}

nonisolated enum BinanceParsing {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Plain decimal strings only ("0.00012345"): no sign, exponent or locale separators, and
    /// never through Double, so 8+ decimal places survive exactly.
    static func decimal(_ text: String?) -> Decimal? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.count <= 64,
              text.filter({ $0 == "." }).count <= 1,
              text.allSatisfy({ $0 == "." || ("0"..."9").contains($0) }),
              text.contains(where: { ("0"..."9").contains($0) }) else { return nil }
        return Decimal(string: text, locale: posix)
    }

    static func asset(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), (1...20).contains(text.count),
              text.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return text
    }

    /// Spot total = free + locked (locked = reserved by open orders, still owned).
    /// A malformed balance fails the whole sync: skipping it would silently understate wealth.
    static func spot(_ info: BinanceAccountInfo) throws -> [ParsedBinanceBalance] {
        guard let balances = info.balances else { throw BinanceError.invalidResponse }
        var seen: Set<String> = []
        var result: [ParsedBinanceBalance] = []
        for balance in balances {
            guard let asset = asset(balance.asset), let free = decimal(balance.free), let locked = decimal(balance.locked),
                  seen.insert(asset).inserted else { throw BinanceError.invalidResponse }
            let total = free + locked
            if total == 0 { continue }
            result.append(ParsedBinanceBalance(key: "spot:\(asset)", asset: asset, wallet: .spot, productRef: "",
                                               free: free, locked: locked, amount: total))
        }
        return result
    }

    static func flexible(_ rows: [BinanceFlexiblePosition]) throws -> [ParsedBinanceBalance] {
        try earn(rows.map { ($0.asset, $0.totalAmount, $0.productId?.value ?? "") }, wallet: .flexible)
    }

    static func locked(_ rows: [BinanceLockedPosition]) throws -> [ParsedBinanceBalance] {
        try earn(rows.map { ($0.asset, $0.amount, $0.positionId?.value ?? "") }, wallet: .locked)
    }

    /// Several products/positions of the same asset stay separate rows; the engine groups them.
    private static func earn(_ rows: [(String?, String?, String)], wallet: BinanceWallet) throws -> [ParsedBinanceBalance] {
        var keys: Set<String> = []
        var result: [ParsedBinanceBalance] = []
        for (index, row) in rows.enumerated() {
            guard let asset = asset(row.0), let amount = decimal(row.1) else { throw BinanceError.invalidResponse }
            if amount == 0 { continue }
            let ref = row.2.isEmpty ? "#\(index)" : row.2
            let key = "\(wallet.rawValue):\(asset):\(ref)"
            guard keys.insert(key).inserted else { throw BinanceError.invalidResponse }
            result.append(ParsedBinanceBalance(key: key, asset: asset, wallet: wallet, productRef: row.2,
                                               free: 0, locked: 0, amount: amount))
        }
        return result
    }
}

// MARK: - EUR pricing from Binance market data

nonisolated struct BinancePair: Sendable, Equatable {
    let symbol: String
    let base: String
    let quote: String
}

nonisolated struct BinancePrice: Sendable, Equatable {
    /// EUR per 1 unit of the asset.
    let eur: Decimal
    /// Market symbols used, e.g. "ETHEUR" or "SOLUSDT → EURUSDT".
    let route: String
}

nonisolated enum BinancePricing {
    static let target = "EUR"
    /// Liquid quote assets tried, in order, when an asset has no EUR market. Each leg must be
    /// a real Binance market — e.g. USDT → EUR uses the EURUSDT price, never an assumed 1:1.
    static let bridges = ["USDT", "USDC", "BTC", "ETH", "BNB", "FDUSD"]

    static func pairs(from info: BinanceExchangeInfo) -> [BinancePair] {
        (info.symbols ?? []).compactMap { item in
            guard item.status == "TRADING", let symbol = item.symbol, let base = item.baseAsset, let quote = item.quoteAsset,
                  !symbol.isEmpty, !base.isEmpty, !quote.isEmpty else { return nil }
            return BinancePair(symbol: symbol, base: base, quote: quote)
        }
    }

    static func tickers(_ list: [BinanceTickerPrice]) -> [String: Decimal] {
        var result: [String: Decimal] = [:]
        for item in list {
            guard let symbol = item.symbol, let price = BinanceParsing.decimal(item.price), price > 0 else { continue }
            result[symbol] = price
        }
        return result
    }

    /// Assets without a validated route are absent from the result — never priced at zero.
    static func eurPrices(for assets: Set<String>, pairs: [BinancePair], tickers: [String: Decimal]) -> [String: BinancePrice] {
        var markets: [String: [String: (price: Decimal, symbol: String)]] = [:]
        for pair in pairs {
            guard let price = tickers[pair.symbol] else { continue }
            markets[pair.base, default: [:]][pair.quote] = (price, pair.symbol)
        }
        /// Units of `to` per 1 `from`, using a direct market or the inverse one.
        func rate(_ from: String, _ to: String) -> (value: Decimal, route: String)? {
            if let direct = markets[from]?[to] { return (direct.price, direct.symbol) }
            if let inverse = markets[to]?[from] { return (1 / inverse.price, inverse.symbol) }
            return nil
        }
        var result: [String: BinancePrice] = [:]
        for asset in assets {
            if asset == target {
                result[asset] = BinancePrice(eur: 1, route: target)
            } else if let direct = rate(asset, target) {
                result[asset] = BinancePrice(eur: direct.value, route: direct.route)
            } else {
                for bridge in bridges where bridge != asset {
                    guard let first = rate(asset, bridge), let second = rate(bridge, target) else { continue }
                    result[asset] = BinancePrice(eur: first.value * second.value, route: "\(first.route) → \(second.route)")
                    break
                }
            }
        }
        return result
    }
}

// MARK: - Reconciliation

enum BinanceReconciler {
    struct Input {
        var uid: Int64?
        var accountType: String
        var spot: [ParsedBinanceBalance]
        var flexible: Result<[ParsedBinanceBalance], BinanceError>
        var locked: Result<[ParsedBinanceBalance], BinanceError>
        /// nil = prices couldn't be refreshed; previously stored prices are kept (and shown as cached).
        var prices: [String: BinancePrice]?
    }

    static func earnStatus(after error: BinanceError) -> BinanceEarnStatus {
        switch error {
        case .invalidCredentials, .missingPermission, .accessDenied, .api, .http: .unavailable
        default: .failed
        }
    }

    /// Idempotent upsert of the Binance snapshot. Spot is replaced on every successful sync;
    /// an Earn product is replaced only when it was read successfully, otherwise its previous
    /// rows are kept (a failed read is not proof of a zero balance). Manual holdings, trades,
    /// accounts and links are never touched. Callers wrap this in `Persistence.commit`.
    static func apply(_ input: Input, now: Date, in context: ModelContext) throws {
        let snapshots = try context.fetch(FetchDescriptor<BinanceAccountSnapshot>())
        let accountChanged = snapshots.first.map { $0.uid != nil && input.uid != nil && $0.uid != input.uid } ?? false
        let snapshot = snapshots.first ?? {
            let created = BinanceAccountSnapshot(syncedAt: now)
            context.insert(created)
            return created
        }()
        for extra in snapshots.dropFirst() { context.delete(extra) }
        snapshot.uid = input.uid
        snapshot.accountType = input.accountType
        snapshot.syncedAt = now

        var byKey: [String: BinanceHolding] = [:]
        for row in try context.fetch(FetchDescriptor<BinanceHolding>()) {
            if accountChanged || byKey[row.key] != nil { context.delete(row) } else { byKey[row.key] = row }
        }

        var fresh: [ParsedBinanceBalance] = []
        var keptWallets: Set<BinanceWallet> = []
        for (wallet, result) in [(BinanceWallet.flexible, input.flexible), (.locked, input.locked)] {
            let status: BinanceEarnStatus
            switch result {
            case .success(let rows):
                fresh += rows
                status = .ok
            case .failure(let error):
                keptWallets.insert(wallet)
                status = earnStatus(after: error)
            }
            if wallet == .flexible {
                snapshot.flexibleStatusRaw = status.rawValue
                if status == .ok { snapshot.flexibleSyncedAt = now }
            } else {
                snapshot.lockedStatusRaw = status.rawValue
                if status == .ok { snapshot.lockedSyncedAt = now }
            }
        }

        // Binance can also report Flexible Earn inside Spot as "LD<asset>". Drop such a Spot row
        // only when Flexible Earn really holds that asset, so real coins like LDO are kept.
        let flexibleAssets = Set(fresh.filter { $0.wallet == .flexible }.map(\.asset)
            + (keptWallets.contains(.flexible) ? byKey.values.filter { $0.wallet == .flexible }.map(\.asset) : []))
        var merged: [String] = []
        for balance in input.spot {
            if balance.asset.hasPrefix("LD"), balance.asset.count > 2, flexibleAssets.contains(String(balance.asset.dropFirst(2))) {
                merged.append(balance.asset)
            } else {
                fresh.append(balance)
            }
        }
        snapshot.mergedSpotAssets = merged.sorted().joined(separator: ", ")

        var current: [BinanceHolding] = []
        var seen: Set<String> = []
        for item in fresh {
            seen.insert(item.key)
            let row = byKey[item.key] ?? {
                let created = BinanceHolding(key: item.key, asset: item.asset, wallet: item.wallet, syncedAt: now)
                context.insert(created)
                return created
            }()
            row.asset = item.asset
            row.walletRaw = item.wallet.rawValue
            row.productRef = item.productRef
            row.free = item.free
            row.locked = item.locked
            row.amount = item.amount
            row.syncedAt = now
            current.append(row)
        }
        for (key, row) in byKey where !seen.contains(key) {
            if keptWallets.contains(row.wallet) { current.append(row) } else { context.delete(row) }
        }

        if let prices = input.prices {
            for row in current {
                if let price = prices[row.asset] {
                    row.priceEUR = price.eur
                    row.priceRoute = price.route
                    row.pricedAt = now
                } else {
                    row.priceEUR = nil
                    row.priceRoute = ""
                    row.pricedAt = nil
                }
            }
            snapshot.pricesFetchedAt = now
        }
    }

    static func removeAllData(in context: ModelContext) throws {
        for row in try context.fetch(FetchDescriptor<BinanceAccountSnapshot>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BinanceHolding>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BinanceLink>()) { context.delete(row) }
    }

    static func setLinked(_ linked: Bool, kind: BrokerLink.Kind, localID: UUID, in context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<BinanceLink>()).filter { $0.kind == kind && $0.localID == localID }
        if linked, existing.isEmpty { context.insert(BinanceLink(kind: kind, localID: localID)) }
        if !linked { existing.forEach(context.delete) }
    }
}

// MARK: - Duplicate suggestions (never applied automatically)

enum BinanceMatching {
    /// Manual crypto holdings whose ticker matches a synced Binance asset and that aren't linked yet.
    static func holdingCandidates(holdings: [Holding], assets: Set<String>, links: [BinanceLink]) -> [(holding: Holding, asset: String)] {
        let linked = Set(links.filter { $0.kind == .holding }.map(\.localID))
        return holdings.compactMap { holding in
            guard holding.assetClass == .crypto, !linked.contains(holding.id) else { return nil }
            let symbols = Trading212Matching.symbols(of: holding)
            guard let asset = assets.sorted().first(where: { symbols.contains($0.uppercased()) }) else { return nil }
            return (holding, asset)
        }
    }

    /// Manual accounts that appear to hold the same Binance balance.
    static func accountCandidates(accounts: [Account], links: [BinanceLink]) -> [Account] {
        let linked = Set(links.filter { $0.kind == .account }.map(\.localID))
        return accounts.filter { account in
            guard !linked.contains(account.id), !account.kind.isLiability else { return false }
            return "\(account.name) \(account.institution)".lowercased().contains("binance")
        }
    }
}

// MARK: - Service

/// Owns the Binance connection: credentials (Keychain only), sync state and policy. Mirrors
/// `Trading212Service`: one sync at a time, stale-only automatic refresh, back-off after
/// failures, and a sync either saves a consistent snapshot in one commit or changes nothing.
@MainActor
@Observable
final class BinanceService {
    private(set) var isConnected: Bool
    private(set) var isSyncing = false
    private(set) var lastError: BinanceError?
    private(set) var lastFailureAt: Date?
    /// Automatic syncs wait until this time after a failure or rate limit.
    private(set) var automaticRetryAfter: Date?
    /// Non-fatal problems of the last successful sync (Earn or prices).
    private(set) var warnings: [String] = []

    /// Automatic syncs (launch, foreground, opening Investments) only run when data is older.
    static let staleInterval: TimeInterval = 15 * 60
    /// A full sync costs ~350 request weight of 6,000/min; never start syncs closer than this.
    static let minimumInterval: TimeInterval = 10
    /// The trading-symbol list (weight 20, a few MB) changes rarely.
    static let symbolsInterval: TimeInterval = 24 * 3600

    private static let keyAccount = "apiKey"
    private static let secretAccount = "secretKey"

    private let secrets: SecretStore
    private let http: HTTPClient
    private let defaults: UserDefaults
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let clock = BinanceClock()
    private var lastAttemptAt: Date?
    /// Bumped by `disconnect`, so a sync already in flight can't write its result afterwards.
    private var generation = 0
    private var inFlight: Task<Download, Error>?
    private var pairs: [BinancePair] = []
    private var pairsFetchedAt: Date?

    /// The app's instance. Inside unit-test hosts and SwiftUI previews it has no Keychain
    /// access and no network, so automatic refreshes there can never reach a real account.
    static func makeForApp(environment: [String: String] = ProcessInfo.processInfo.environment) -> BinanceService {
        if Persistence.isHostingTests(environment: environment) || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return BinanceService(http: DisabledHTTPClient(), secrets: NoSecretStore())
        }
        return BinanceService()
    }

    init(http: HTTPClient = BinanceTransport(),
         secrets: SecretStore = KeychainStore(service: "WealthOS.Binance"),
         defaults: UserDefaults = .standard,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.http = http
        self.secrets = secrets
        self.defaults = defaults
        self.sleep = sleep
        isConnected = secrets.read(Self.keyAccount) != nil && secrets.read(Self.secretAccount) != nil
    }

    var needsReconnect: Bool {
        switch lastError {
        case .invalidCredentials?, .missingPermission?, .keyNotReadOnly?: true
        default: false
        }
    }

    static func lastSync(in context: ModelContext) -> Date? {
        (try? context.fetch(FetchDescriptor<BinanceAccountSnapshot>()))?.first?.syncedAt
    }

    /// Checks the key's permissions and reads the account before storing anything.
    func connect(apiKey: String, secretKey: String, context: ModelContext, now: Date = .now) async throws {
        let credentials = BinanceCredentials(apiKey: apiKey, secretKey: secretKey)
        guard credentials.isComplete else { throw BinanceError.missingCredentials }
        guard !isSyncing else { throw BinanceError.busy }
        isSyncing = true
        defer { isSyncing = false }

        let started = generation
        do {
            let download = try await run(makeClient(credentials), context: context, now: now)
            guard started == generation else { throw CancellationError() }
            try store(credentials)
            isConnected = true
            lastAttemptAt = now
            try save(download, now: now, context: context)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            record(error, now: now)
            throw lastError ?? .network
        }
    }

    /// Manual "Sync now" (force) or automatic refresh. Returns true when new data was saved.
    @discardableResult
    func sync(context: ModelContext, force: Bool = false, now: Date = .now) async -> Bool {
        guard isConnected, !isSyncing, let credentials = storedCredentials() else { return false }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.minimumInterval { return false }
        if !force {
            if needsReconnect { return false }
            if let automaticRetryAfter, now < automaticRetryAfter { return false }
            if let last = Self.lastSync(in: context), now.timeIntervalSince(last) < Self.staleInterval { return false }
        }
        isSyncing = true
        defer { isSyncing = false }
        lastAttemptAt = now
        let started = generation

        do {
            let download = try await run(makeClient(credentials), context: context, now: now)
            // Disconnected while downloading: drop the result instead of resurrecting the data.
            guard started == generation, isConnected else { return false }
            try save(download, now: now, context: context)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard started == generation else { return false }
            record(error, now: now)
            return false
        }
    }

    func syncIfStale(context: ModelContext, now: Date = .now) async {
        await sync(context: context, force: false, now: now)
    }

    /// Cancels any running sync and deletes the stored credentials. `removeData` also deletes
    /// the cached Binance snapshot and links; manual records are never touched.
    func disconnect(removeData: Bool, context: ModelContext) throws {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        try? secrets.delete(Self.keyAccount)
        try? secrets.delete(Self.secretAccount)
        isConnected = false
        lastError = nil
        lastFailureAt = nil
        automaticRetryAfter = nil
        lastAttemptAt = nil
        warnings = []
        if removeData {
            try Persistence.commit(context) { try BinanceReconciler.removeAllData(in: context) }
            DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
        }
    }

    // MARK: Internals

    private struct Download {
        var input: BinanceReconciler.Input
        var warnings: [String]
        /// Back-off requested by a rate limit on an optional (Earn/price) request.
        var backoff: TimeInterval?
    }

    private func run(_ client: BinanceClient, context: ModelContext, now: Date) async throws -> Download {
        let known = Set(((try? context.fetch(FetchDescriptor<BinanceHolding>())) ?? []).map(\.asset))
        let task = Task { try await self.download(client: client, knownAssets: known, now: now) }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func download(client: BinanceClient, knownAssets: Set<String>, now: Date) async throws -> Download {
        // Refuse keys that can trade or move funds, every time — permissions can be changed later.
        let restrictions = try await client.apiRestrictions()
        guard restrictions.enableReading == true else { throw BinanceError.missingPermission }
        let risky = restrictions.riskyPermissions
        guard risky.isEmpty else { throw BinanceError.keyNotReadOnly(risky) }

        let account = try await client.account()
        let spot = try BinanceParsing.spot(account)
        let flexible = await Self.optional { try BinanceParsing.flexible(try await client.flexiblePositions()) }
        let locked = await Self.optional { try BinanceParsing.locked(try await client.lockedPositions()) }
        try Task.checkCancellation()

        var assets = knownAssets.union(spot.map(\.asset))
        for result in [flexible, locked] { if case .success(let rows) = result { assets.formUnion(rows.map(\.asset)) } }
        var priceError: BinanceError?
        var prices: [String: BinancePrice]?
        do {
            prices = try await priceTable(client: client, assets: assets, now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            priceError = (error as? BinanceError) ?? .network
        }
        try Task.checkCancellation()

        var warnings: [String] = []
        var backoff: TimeInterval?
        for (title, result) in [("Simple Earn Flexible", flexible), ("Simple Earn Locked", locked)] {
            guard case .failure(let error) = result else { continue }
            let reason = BinanceReconciler.earnStatus(after: error) == .unavailable
                ? "isn't readable with this API key — its balance is unknown, not zero"
                : "couldn't be refreshed (\(error.errorDescription ?? "error")) — showing the last synced positions"
            warnings.append("\(title) \(reason).")
            backoff = max(backoff ?? 0, Self.automaticBackoff(after: error))
        }
        if let priceError {
            warnings.append("Prices couldn't be refreshed (\(priceError.errorDescription ?? "error")) — showing cached prices.")
            backoff = max(backoff ?? 0, Self.automaticBackoff(after: priceError))
        }
        let input = BinanceReconciler.Input(uid: account.uid, accountType: account.accountType ?? "", spot: spot,
                                            flexible: flexible, locked: locked, prices: prices)
        return Download(input: input, warnings: warnings, backoff: (backoff ?? 0) > 0 ? backoff : nil)
    }

    private static func optional(_ body: () async throws -> [ParsedBinanceBalance]) async -> Result<[ParsedBinanceBalance], BinanceError> {
        do {
            return .success(try await body())
        } catch let error as BinanceError {
            return .failure(error)
        } catch {
            return .failure(.network)
        }
    }

    private func priceTable(client: BinanceClient, assets: Set<String>, now: Date) async throws -> [String: BinancePrice] {
        if pairs.isEmpty || pairsFetchedAt.map({ now.timeIntervalSince($0) > Self.symbolsInterval }) ?? true {
            let fetched = BinancePricing.pairs(from: try await client.tradingSymbols())
            guard !fetched.isEmpty else { throw BinanceError.invalidResponse }
            pairs = fetched
            pairsFetchedAt = now
        }
        let tickers = BinancePricing.tickers(try await client.prices())
        guard !tickers.isEmpty else { throw BinanceError.invalidResponse }
        return BinancePricing.eurPrices(for: assets, pairs: pairs, tickers: tickers)
    }

    private func save(_ download: Download, now: Date, context: ModelContext) throws {
        try Persistence.commit(context) { try BinanceReconciler.apply(download.input, now: now, in: context) }
        lastError = nil
        lastFailureAt = nil
        warnings = download.warnings
        automaticRetryAfter = download.backoff.map { now.addingTimeInterval($0) }
        DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
    }

    /// Records the failure; the cached snapshot is left exactly as it was.
    private func record(_ error: Error, now: Date) {
        let mapped = (error as? BinanceError) ?? (error is PersistenceError ? .invalidResponse : .network)
        lastError = mapped
        lastFailureAt = now
        automaticRetryAfter = now.addingTimeInterval(Self.automaticBackoff(after: mapped))
    }

    /// How long automatic (not manual) syncs pause after a failure.
    static func automaticBackoff(after error: BinanceError) -> TimeInterval {
        switch error {
        case .rateLimited(let wait), .ipBanned(let wait): max(wait ?? 120, 60)
        case .offline, .network, .timeout: 60
        case .server, .http, .api, .invalidResponse, .accessDenied, .timestampOutOfSync: 5 * 60
        default: 0
        }
    }

    private func store(_ credentials: BinanceCredentials) throws {
        do {
            try secrets.save(credentials.apiKey, account: Self.keyAccount)
            try secrets.save(credentials.secretKey, account: Self.secretAccount)
        } catch {
            try? secrets.delete(Self.keyAccount)
            try? secrets.delete(Self.secretAccount)
            throw error
        }
    }

    private func storedCredentials() -> BinanceCredentials? {
        guard let key = secrets.read(Self.keyAccount), let secret = secrets.read(Self.secretAccount) else { return nil }
        let credentials = BinanceCredentials(apiKey: key, secretKey: secret)
        return credentials.isComplete ? credentials : nil
    }

    private func makeClient(_ credentials: BinanceCredentials) -> BinanceClient {
        var client = BinanceClient(credentials: credentials, http: http)
        client.clock = clock
        client.sleep = sleep
        return client
    }

    private var baseCurrency: String { defaults.string(forKey: SettingsKey.baseCurrency) ?? "EUR" }
}
