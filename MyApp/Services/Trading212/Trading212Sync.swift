import Foundation
import Observation
import SwiftData

// MARK: - Parsing

nonisolated struct ParsedBrokerPosition: Sendable, Equatable {
    var ticker: String
    var name: String
    var isin: String
    var instrumentCurrency: String
    var quantity: Decimal
    var averagePrice: Decimal?
    var currentPrice: Decimal?
    var valueCurrency: String
    var currentValue: Decimal?
    var totalCost: Decimal?
    var unrealizedProfitLoss: Decimal?
    var fxImpact: Decimal?
    var openedAt: Date?
}

nonisolated enum Trading212Parsing {
    /// A position without a ticker or quantity can't be valued or matched. Skipping it would
    /// silently understate net worth, so the whole sync fails and the previous data is kept.
    static func parse(_ positions: [T212Position]) throws -> [ParsedBrokerPosition] {
        var seen: Set<String> = []
        var result: [ParsedBrokerPosition] = []
        for position in positions {
            guard let ticker = position.instrument?.ticker?.trimmingCharacters(in: .whitespaces), !ticker.isEmpty,
                  let quantity = position.quantity, quantity >= 0 else { throw Trading212Error.invalidResponse }
            guard seen.insert(ticker).inserted else { throw Trading212Error.invalidResponse }
            if quantity == 0 { continue }
            result.append(ParsedBrokerPosition(
                ticker: ticker,
                name: position.instrument?.name ?? "",
                isin: position.instrument?.isin ?? "",
                instrumentCurrency: position.instrument?.currency ?? "",
                quantity: quantity,
                averagePrice: position.averagePricePaid,
                currentPrice: position.currentPrice,
                valueCurrency: position.walletImpact?.currency ?? "",
                currentValue: position.walletImpact?.currentValue,
                totalCost: position.walletImpact?.totalCost,
                unrealizedProfitLoss: position.walletImpact?.unrealizedProfitLoss,
                fxImpact: position.walletImpact?.fxImpact,
                openedAt: position.createdAt.flatMap(parseDate)))
        }
        return result
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func instrumentIndex(_ instruments: [T212Instrument]) -> [String: (type: String, shortName: String)] {
        var index: [String: (type: String, shortName: String)] = [:]
        for instrument in instruments {
            guard let ticker = instrument.ticker, !ticker.isEmpty else { continue }
            index[ticker] = (instrument.type ?? "", instrument.shortName ?? "")
        }
        return index
    }
}

// MARK: - Reconciliation

enum Trading212Reconciler {
    /// Idempotent upsert of the provider snapshot. Positions are matched by Trading 212's ticker;
    /// closed positions are removed from the *snapshot* only. Manual holdings, trades, accounts
    /// and links are never touched. Callers wrap this in `Persistence.commit`.
    static func apply(summary: T212AccountSummary, positions: [ParsedBrokerPosition],
                      instruments: [String: (type: String, shortName: String)]?,
                      environment: Trading212Environment, now: Date, in context: ModelContext) throws {
        guard let currency = summary.currency?.uppercased(), currency.count == 3 else {
            throw Trading212Error.invalidResponse
        }

        let snapshots = try context.fetch(FetchDescriptor<BrokerAccountSnapshot>())
        let accountChanged = snapshots.first.map { $0.environmentRaw != environment.rawValue
            || ($0.accountNumber != nil && summary.id != nil && $0.accountNumber != summary.id) } ?? false
        let snapshot = snapshots.first ?? {
            let created = BrokerAccountSnapshot(environment: environment, currencyCode: currency, syncedAt: now)
            context.insert(created)
            return created
        }()
        for extra in snapshots.dropFirst() { context.delete(extra) }

        snapshot.environmentRaw = environment.rawValue
        snapshot.accountNumber = summary.id
        snapshot.currencyCode = currency
        snapshot.cashAvailable = summary.cash?.availableToTrade ?? 0
        snapshot.cashInPies = summary.cash?.inPies ?? 0
        snapshot.cashReserved = summary.cash?.reservedForOrders ?? 0
        snapshot.investmentsValue = summary.investments?.currentValue
        snapshot.investmentsCost = summary.investments?.totalCost
        snapshot.unrealizedProfitLoss = summary.investments?.unrealizedProfitLoss
        snapshot.realizedProfitLoss = summary.investments?.realizedProfitLoss
        snapshot.reportedTotal = summary.totalValue
        snapshot.syncedAt = now
        snapshot.restoredFromBackup = false

        let existing = try context.fetch(FetchDescriptor<BrokerPosition>())
        var byTicker: [String: BrokerPosition] = [:]
        for row in existing {
            if accountChanged || byTicker[row.ticker] != nil { context.delete(row) } else { byTicker[row.ticker] = row }
        }

        var seen: Set<String> = []
        for item in positions {
            seen.insert(item.ticker)
            let row = byTicker[item.ticker] ?? {
                let created = BrokerPosition(ticker: item.ticker, syncedAt: now)
                context.insert(created)
                return created
            }()
            row.name = item.name
            row.isin = item.isin
            row.instrumentCurrency = item.instrumentCurrency
            row.quantity = item.quantity
            row.averagePrice = item.averagePrice
            row.currentPrice = item.currentPrice
            row.valueCurrency = item.valueCurrency.isEmpty ? currency : item.valueCurrency.uppercased()
            row.currentValue = item.currentValue
            row.totalCost = item.totalCost
            row.unrealizedProfitLoss = item.unrealizedProfitLoss
            row.fxImpact = item.fxImpact
            row.openedAt = item.openedAt
            row.syncedAt = now
            if let meta = instruments?[item.ticker] {
                row.instrumentType = meta.type
                row.shortName = meta.shortName
            }
        }
        for (ticker, row) in byTicker where !seen.contains(ticker) { context.delete(row) }
    }

    static func removeAllData(in context: ModelContext) throws {
        for row in try context.fetch(FetchDescriptor<BrokerAccountSnapshot>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BrokerPosition>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BrokerLink>()) { context.delete(row) }
    }

    static func setLinked(_ linked: Bool, kind: BrokerLink.Kind, localID: UUID, in context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<BrokerLink>()).filter { $0.kind == kind && $0.localID == localID }
        if linked, existing.isEmpty { context.insert(BrokerLink(kind: kind, localID: localID)) }
        if !linked { existing.forEach(context.delete) }
    }
}

// MARK: - Duplicate suggestions (never applied automatically)

enum Trading212Matching {
    /// "VUSAl_EQ" → "VUSA", "AAPL_US_EQ" → "AAPL" (Trading 212 suffixes London lines with a lowercase letter).
    static func baseSymbol(ofTicker ticker: String) -> String {
        let head = ticker.split(separator: "_").first.map(String.init) ?? ticker
        let trimmed = head.count > 1 ? String(head.reversed().drop(while: \.isLowercase).reversed()) : head
        return (trimmed.isEmpty ? head : trimmed).uppercased()
    }

    static func symbols(of position: BrokerPosition) -> Set<String> {
        var result: Set<String> = [baseSymbol(ofTicker: position.ticker)]
        if !position.shortName.isEmpty { result.insert(position.shortName.uppercased()) }
        return result
    }

    static func symbols(of holding: Holding) -> Set<String> {
        var result: Set<String> = []
        for raw in [holding.symbol, holding.marketSymbol] {
            let base = raw.split(separator: ".").first.map(String.init) ?? raw
            let clean = base.trimmingCharacters(in: .whitespaces).uppercased()
            if !clean.isEmpty { result.insert(clean) }
        }
        return result
    }

    /// "GBX" (pence) and "GBP" quote the same London listing.
    static func listingCurrency(_ code: String) -> String {
        let upper = code.trimmingCharacters(in: .whitespaces).uppercased()
        return upper == "GBX" ? "GBP" : upper
    }

    /// Same instrument, not merely the same letters: the symbol must overlap, the asset class
    /// must agree when Trading 212 reports one, and the listing currency must agree when known
    /// (VUSA in GBP on London and VUSA in EUR on Amsterdam are different listings).
    static func isCompatible(_ holding: Holding, _ position: BrokerPosition) -> Bool {
        guard holding.assetClass != .crypto, !symbols(of: position).isDisjoint(with: symbols(of: holding)) else { return false }
        if position.assetClass == .etf || position.assetClass == .stock, holding.assetClass != position.assetClass { return false }
        let positionCurrency = listingCurrency(position.instrumentCurrency)
        if !positionCurrency.isEmpty {
            let mine = Set([holding.currencyCode, holding.marketCurrencyCode].map(listingCurrency).filter { !$0.isEmpty })
            if !mine.contains(positionCurrency) { return false }
        }
        return true
    }

    /// Manual holdings that clearly correspond to exactly one synced Trading 212 position (and
    /// that position to exactly one holding) and aren't linked yet. Suggestions only.
    static func holdingCandidates(holdings: [Holding], positions: [BrokerPosition], links: [BrokerLink]) -> [(holding: Holding, position: BrokerPosition)] {
        let (unique, _) = classify(holdings: holdings, positions: positions, links: links)
        return unique
    }

    /// Unlinked holdings that resemble more than one position (or share one with another
    /// holding). Never suggested as a specific match — the user has to decide.
    static func ambiguousHoldings(holdings: [Holding], positions: [BrokerPosition], links: [BrokerLink]) -> [Holding] {
        classify(holdings: holdings, positions: positions, links: links).ambiguous
    }

    private static func classify(holdings: [Holding], positions: [BrokerPosition], links: [BrokerLink])
        -> (unique: [(holding: Holding, position: BrokerPosition)], ambiguous: [Holding]) {
        let linked = Set(links.filter { $0.kind == .holding }.map(\.localID))
        let open = holdings.filter { !linked.contains($0.id) }
        let matches = open.map { holding in (holding, positions.filter { isCompatible(holding, $0) }) }
        var claims: [String: Int] = [:]
        for (_, found) in matches { for position in found { claims[position.ticker, default: 0] += 1 } }
        var unique: [(holding: Holding, position: BrokerPosition)] = []
        var ambiguous: [Holding] = []
        for (holding, found) in matches where !found.isEmpty {
            if found.count == 1, let position = found.first, claims[position.ticker] == 1 {
                unique.append((holding, position))
            } else {
                ambiguous.append(holding)
            }
        }
        return (unique, ambiguous)
    }

    /// Manual accounts that appear to represent the same Trading 212 cash.
    static func accountCandidates(accounts: [Account], links: [BrokerLink]) -> [Account] {
        let linked = Set(links.filter { $0.kind == .account }.map(\.localID))
        return accounts.filter { account in
            guard !linked.contains(account.id), !account.kind.isLiability else { return false }
            let text = "\(account.name) \(account.institution)".lowercased().replacingOccurrences(of: " ", with: "")
            return text.contains("trading212") || text.contains("t212")
        }
    }
}

// MARK: - Service

/// Owns the Trading 212 connection: credentials (Keychain only), sync state and policy.
/// A sync either fully succeeds and replaces the snapshot in one save, or changes nothing.
@MainActor
@Observable
final class Trading212Service {
    private(set) var isConnected = false
    private(set) var isSyncing = false
    private(set) var lastError: Trading212Error?
    private(set) var lastFailureAt: Date?
    private(set) var environment: Trading212Environment

    /// Automatic syncs (opening Investments, returning to the app) only run when data is older.
    static let staleInterval: TimeInterval = 15 * 60
    /// Account summary allows 1 request / 5 s; never start syncs closer together than that.
    static let minimumInterval: TimeInterval = 6
    /// Instrument metadata changes rarely and is limited to 1 request / 50 s.
    static let instrumentsInterval: TimeInterval = 24 * 3600

    private static let keyAccount = "apiKey"
    private static let secretAccount = "apiSecret"
    private static let environmentKey = "trading212Environment"
    private static let instrumentsFetchedKey = "trading212InstrumentsFetchedAt"

    private let secrets: SecretStore
    private let http: HTTPClient
    private let defaults: UserDefaults
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var lastAttemptAt: Date?
    /// Automatic syncs wait until this time after a failure (offline, rate limit, server error).
    private(set) var automaticRetryAfter: Date?
    /// Bumped by `disconnect`, so a sync already in flight can't write its result afterwards.
    private var generation = 0

    /// The app's instance. Inside unit-test hosts and SwiftUI previews it has no Keychain
    /// access and no network, so automatic refreshes there can never reach a real account.
    static func makeForApp(environment: [String: String] = ProcessInfo.processInfo.environment) -> Trading212Service {
        if Persistence.isHostingTests(environment: environment) || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return Trading212Service(http: DisabledHTTPClient(), secrets: NoSecretStore())
        }
        return Trading212Service()
    }

    init(http: HTTPClient = Trading212Transport(),
         secrets: SecretStore = KeychainStore(service: "WealthOS.Trading212", accessibility: .whenUnlocked),
         defaults: UserDefaults = .standard,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.http = http
        self.secrets = secrets
        self.defaults = defaults
        self.sleep = sleep
        environment = Trading212Environment(rawValue: defaults.string(forKey: Self.environmentKey) ?? "") ?? .live
        reloadConnectionState()
    }

    /// Half of a key/secret pair left behind by an earlier failed deletion; Disconnect removes it.
    private(set) var hasLeftoverCredential = false

    /// Re-reads the Keychain (and moves older items to the "when unlocked" class). Call when the
    /// app becomes active: the credentials are readable only while the device is unlocked, so a
    /// launch while locked sees nothing. Never deletes anything — unreadable isn't proof of absence.
    func reloadConnectionState() {
        for account in [Self.keyAccount, Self.secretAccount] { secrets.upgradeProtection(account) }
        let hasKey = secrets.read(Self.keyAccount) != nil
        let hasSecret = secrets.read(Self.secretAccount) != nil
        isConnected = hasKey && hasSecret
        hasLeftoverCredential = hasKey != hasSecret
    }

    var needsReconnect: Bool { lastError == .invalidCredentials || lastError == .missingPermission }

    static func lastSync(in context: ModelContext) -> Date? {
        (try? context.fetch(FetchDescriptor<BrokerAccountSnapshot>()))?.first?.syncedAt
    }

    /// Validates the credentials with real read-only calls before storing anything.
    func connect(apiKey: String, apiSecret: String, environment: Trading212Environment, context: ModelContext,
                 now: Date = .now) async throws {
        let credentials = Trading212Credentials(apiKey: apiKey, apiSecret: apiSecret)
        guard credentials.isComplete else { throw Trading212Error.missingCredentials }
        guard !isSyncing else { throw Trading212Error.busy }
        isSyncing = true
        defer { isSyncing = false }

        let client = makeClient(credentials, environment)
        let started = generation
        do {
            let snapshot = try await download(client: client, forceInstruments: true)
            guard started == generation else { throw CancellationError() }
            // All-or-nothing: the new key is only kept if the first snapshot is saved too.
            let previous = storedCredentials()
            try store(credentials, restoringOnFailure: previous)
            do {
                try save(snapshot, environment: environment, now: now, context: context)
            } catch {
                restoreCredentials(previous)
                throw error
            }
            self.environment = environment
            defaults.set(environment.rawValue, forKey: Self.environmentKey)
            isConnected = true
            hasLeftoverCredential = false
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
            // A rejected key fails identically every time; wait for the user to reconnect.
            if needsReconnect { return false }
            if let automaticRetryAfter, now < automaticRetryAfter { return false }
            if let last = Self.lastSync(in: context), now.timeIntervalSince(last) < Self.staleInterval { return false }
        }
        isSyncing = true
        defer { isSyncing = false }
        lastAttemptAt = now
        let started = generation

        do {
            let snapshot = try await download(client: makeClient(credentials, environment), forceInstruments: false, context: context, now: now)
            // Disconnected while downloading: drop the result instead of resurrecting the data.
            guard started == generation, isConnected else { return false }
            try save(snapshot, environment: environment, now: now, context: context)
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

    /// Deletes the stored credentials. `removeData` also deletes the cached Trading 212
    /// snapshot and duplicate links; manual holdings, accounts and transactions are never touched.
    /// Throws `.credentialStorage` — and keeps reporting whatever is still stored — if the
    /// Keychain refuses to delete either value; it never claims a disconnect that didn't happen.
    func disconnect(removeData: Bool, context: ModelContext) throws {
        generation += 1
        var deletionFailed = false
        for account in [Self.keyAccount, Self.secretAccount] {
            do { try secrets.delete(account) } catch { deletionFailed = true }
        }
        let hasKey = secrets.read(Self.keyAccount) != nil
        let hasSecret = secrets.read(Self.secretAccount) != nil
        isConnected = hasKey && hasSecret
        hasLeftoverCredential = hasKey != hasSecret
        guard !deletionFailed else { throw Trading212Error.credentialStorage }
        lastError = nil
        lastFailureAt = nil
        automaticRetryAfter = nil
        lastAttemptAt = nil
        if removeData {
            try Persistence.commit(context) { try Trading212Reconciler.removeAllData(in: context) }
            defaults.removeObject(forKey: Self.instrumentsFetchedKey)
            DataMaintenance.refreshSnapshot(context: context, baseCurrency: Self.baseCurrency(defaults))
        }
    }

    // MARK: Internals

    private struct Download {
        var summary: T212AccountSummary
        var positions: [ParsedBrokerPosition]
        var instruments: [String: (type: String, shortName: String)]?
    }

    private func download(client: Trading212Client, forceInstruments: Bool, context: ModelContext? = nil,
                          now: Date = .now) async throws -> Download {
        let summary = try await client.accountSummary()
        let positions = try Trading212Parsing.parse(try await client.positions())
        var instruments: [String: (type: String, shortName: String)]?
        if forceInstruments || needsInstruments(positions: positions, context: context, now: now) {
            // Metadata only labels positions (ETF/stock, short name); a failure here is not fatal.
            instruments = (try? await client.instruments()).map(Trading212Parsing.instrumentIndex)
        }
        return Download(summary: summary, positions: positions, instruments: instruments)
    }

    private func needsInstruments(positions: [ParsedBrokerPosition], context: ModelContext?, now: Date) -> Bool {
        if let last = defaults.object(forKey: Self.instrumentsFetchedKey) as? Date,
           now.timeIntervalSince(last) < 60 { return false }
        if let last = defaults.object(forKey: Self.instrumentsFetchedKey) as? Date,
           now.timeIntervalSince(last) > Self.instrumentsInterval { return true }
        let known = Set(((try? context?.fetch(FetchDescriptor<BrokerPosition>())) ?? [])
            .filter { !$0.instrumentType.isEmpty }.map(\.ticker))
        return positions.contains { !known.contains($0.ticker) }
    }

    /// Injectable for tests (e.g. a failing disk); always `context.save()` in the app.
    var saveContext: (ModelContext) throws -> Void = { try $0.save() }

    private func save(_ download: Download, environment: Trading212Environment, now: Date, context: ModelContext) throws {
        try Persistence.commit(context, save: saveContext) {
            try Trading212Reconciler.apply(summary: download.summary, positions: download.positions,
                                           instruments: download.instruments, environment: environment, now: now, in: context)
        }
        if download.instruments != nil { defaults.set(now, forKey: Self.instrumentsFetchedKey) }
        lastError = nil
        lastFailureAt = nil
        automaticRetryAfter = nil
        DataMaintenance.refreshSnapshot(context: context, baseCurrency: Self.baseCurrency(defaults))
    }

    /// Records the failure; the cached snapshot is left exactly as it was.
    private func record(_ error: Error, now: Date) {
        let mapped: Trading212Error = (error as? Trading212Error)
            ?? (error is PersistenceError ? .localSaveFailed : error is KeychainError ? .credentialStorage : .network)
        lastError = mapped
        lastFailureAt = now
        automaticRetryAfter = now.addingTimeInterval(Self.automaticBackoff(after: mapped))
    }

    /// How long automatic (not manual) syncs pause after a failure.
    static func automaticBackoff(after error: Trading212Error) -> TimeInterval {
        switch error {
        case .rateLimited(let wait): max(wait ?? 60, 60)
        case .offline, .network, .timeout: 60
        case .server, .http, .invalidResponse: 5 * 60
        default: 0
        }
    }

    /// Writes both values; on failure puts `previous` back (or removes both), so the Keychain
    /// never keeps a mismatched key/secret pair and a failed reconnect doesn't lose a working key.
    private func store(_ credentials: Trading212Credentials, restoringOnFailure previous: Trading212Credentials?) throws {
        do {
            try secrets.save(credentials.apiKey, account: Self.keyAccount)
            try secrets.save(credentials.apiSecret, account: Self.secretAccount)
        } catch {
            restoreCredentials(previous)
            throw Trading212Error.credentialStorage
        }
    }

    private func restoreCredentials(_ previous: Trading212Credentials?) {
        if let previous {
            try? secrets.save(previous.apiKey, account: Self.keyAccount)
            try? secrets.save(previous.apiSecret, account: Self.secretAccount)
        } else {
            try? secrets.delete(Self.keyAccount)
            try? secrets.delete(Self.secretAccount)
        }
        let hasKey = secrets.read(Self.keyAccount) != nil
        let hasSecret = secrets.read(Self.secretAccount) != nil
        isConnected = hasKey && hasSecret
        hasLeftoverCredential = hasKey != hasSecret
    }

    private func storedCredentials() -> Trading212Credentials? {
        guard let key = secrets.read(Self.keyAccount), let secret = secrets.read(Self.secretAccount) else { return nil }
        let credentials = Trading212Credentials(apiKey: key, apiSecret: secret)
        return credentials.isComplete ? credentials : nil
    }

    private func makeClient(_ credentials: Trading212Credentials, _ environment: Trading212Environment) -> Trading212Client {
        var client = Trading212Client(environment: environment, credentials: credentials, http: http)
        client.sleep = sleep
        return client
    }

    private static func baseCurrency(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: SettingsKey.baseCurrency) ?? "EUR"
    }
}

/// Used in test hosts and previews: every request is refused before it leaves the device.
nonisolated struct DisabledHTTPClient: HTTPClient {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw Trading212Error.blockedRequest }
}

/// Used in test hosts and previews: never reads or writes the real Keychain.
nonisolated struct NoSecretStore: SecretStore {
    func read(_ account: String) -> String? { nil }
    func save(_ value: String, account: String) throws { throw KeychainError.status(errSecNotAvailable) }
    func delete(_ account: String) throws {}
}
