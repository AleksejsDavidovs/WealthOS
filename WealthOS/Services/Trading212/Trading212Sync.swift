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

        // Another account (or demo ↔ live): its history must not mix with this one.
        if accountChanged {
            for row in try context.fetch(FetchDescriptor<BrokerDividend>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<BrokerOrder>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<BrokerCashTransaction>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<BrokerValuePoint>()) { context.delete(row) }
        }
        let positionsValue = positions.reduce(Decimal(0)) { $0 + ($1.currentValue ?? 0) }
        try recordValuePoint(value: Money.round(snapshot.cashTotal + positionsValue), cash: Money.round(snapshot.cashTotal),
                             currency: currency, now: now, in: context)
    }

    /// One point per calendar day (the latest sync of the day wins).
    static func recordValuePoint(value: Decimal, cash: Decimal, currency: String, now: Date,
                                 calendar: Calendar = .current, in context: ModelContext) throws {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let today = try context.fetch(FetchDescriptor<BrokerValuePoint>(predicate: #Predicate { $0.date >= start && $0.date < end }))
        if let point = today.first {
            point.date = now
            point.value = value
            point.cash = cash
            point.currencyCode = currency
            for extra in today.dropFirst() { context.delete(extra) }
        } else {
            context.insert(BrokerValuePoint(date: now, currencyCode: currency, value: value, cash: cash))
        }
    }

    static func removeAllData(in context: ModelContext) throws {
        for row in try context.fetch(FetchDescriptor<BrokerAccountSnapshot>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BrokerPosition>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BrokerLink>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BrokerDividend>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BrokerOrder>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BrokerCashTransaction>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BrokerValuePoint>()) { context.delete(row) }
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
    nonisolated static func listingCurrency(_ code: String) -> String {
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
    /// What is known about the stored key/secret pair; see `CredentialState`.
    private(set) var credentialState: CredentialState = .missing
    /// Connected only with a complete, verified pair — never while locked, failing or uncertain.
    var isConnected: Bool { credentialState == .stored }
    /// Half of a key/secret pair left behind by an earlier failed deletion; Disconnect removes it.
    var hasLeftoverCredential: Bool { credentialState == .partial }
    /// Moving the stored items to the "when unlocked" class failed; they keep working and the
    /// migration is retried on the next activation.
    private(set) var protectionUpgradeFailed = false
    private(set) var isSyncing = false
    private(set) var lastError: Trading212Error?
    private(set) var lastFailureAt: Date?
    private(set) var environment: Trading212Environment
    /// Last download failure per history feed (e.g. the key lacks that history scope). Kept
    /// apart from `lastError`: balances keep syncing without history.
    private(set) var historyErrors: [Trading212HistoryKind: Trading212Error] = [:]
    var dividendError: Trading212Error? { historyErrors[.dividends] }

    /// Automatic syncs (opening Investments, returning to the app) only run when data is older.
    static let staleInterval: TimeInterval = 15 * 60
    /// Account summary allows 1 request / 5 s; never start syncs closer together than that.
    static let minimumInterval: TimeInterval = 6
    /// Instrument metadata changes rarely and is limited to 1 request / 50 s.
    static let instrumentsInterval: TimeInterval = 24 * 3600
    /// History (dividends, trades, cash movements) is re-checked at most every 6 hours, or on a manual sync.
    static let dividendsInterval: TimeInterval = 6 * 3600
    /// 50 items per page; the first download of a feed stops after this many pages.
    static let historyMaxPages = 40

    private static let keyAccount = "apiKey"
    private static let secretAccount = "apiSecret"
    private static let environmentKey = "trading212Environment"
    private static let instrumentsFetchedKey = "trading212InstrumentsFetchedAt"
    private static func historyFetchedKey(_ kind: Trading212HistoryKind) -> String { "trading212HistoryFetchedAt.\(kind.rawValue)" }

    /// When a history feed was last downloaded successfully; nil = never.
    func historyFetchedAt(_ kind: Trading212HistoryKind) -> Date? { defaults.object(forKey: Self.historyFetchedKey(kind)) as? Date }
    var dividendsFetchedAt: Date? { historyFetchedAt(.dividends) }

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

    private var keychainPair: CredentialPair {
        CredentialPair(secrets: secrets, keyAccount: Self.keyAccount, secretAccount: Self.secretAccount,
                       defaults: defaults, journalKey: "credentialWriteInProgress.trading212")
    }

    /// Re-reads the Keychain (and moves older items to the "when unlocked" class). Call when the
    /// app becomes active: the credentials are readable only while the device is unlocked, so a
    /// launch while locked reports `.locked`. Never deletes anything.
    func reloadConnectionState() {
        protectionUpgradeFailed = !keychainPair.upgradeProtection()
        credentialState = keychainPair.state()
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
        // Can't know what's stored, so a failed write couldn't be rolled back safely.
        reloadConnectionState()
        guard credentialState != .locked, credentialState != .unavailable else { throw Trading212Error.keychainUnavailable }
        isSyncing = true
        defer { isSyncing = false }

        let client = makeClient(credentials, environment)
        let started = generation
        do {
            let snapshot = try await download(client: client, forceInstruments: true)
            guard started == generation else { throw CancellationError() }
            // All-or-nothing: the new key is only kept if the first snapshot is saved too.
            // An uncertain pair is never "restored": the rollback target is then "nothing stored".
            let previous = keychainPair.values()
            let outcome = keychainPair.replace(with: (credentials.apiKey, credentials.apiSecret), previous: previous)
            credentialState = keychainPair.state()
            switch outcome {
            case .written: break
            case .rolledBack: throw Trading212Error.credentialStorage
            case .uncertain: throw Trading212Error.credentialStateUncertain
            }
            do {
                try save(snapshot, environment: environment, now: now, context: context)
            } catch {
                let restored = keychainPair.restore(previous)
                credentialState = keychainPair.state()
                if !restored { throw Trading212Error.credentialStateUncertain }
                throw error
            }
            self.environment = environment
            defaults.set(environment.rawValue, forKey: Self.environmentKey)
            credentialState = keychainPair.state()
            await refreshHistory(client: client, force: true, started: started, context: context, now: now)
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
            let client = makeClient(credentials, environment)
            let snapshot = try await download(client: client, forceInstruments: false, context: context, now: now)
            // Disconnected while downloading: drop the result instead of resurrecting the data.
            guard started == generation, isConnected else { return false }
            try save(snapshot, environment: environment, now: now, context: context)
            await refreshHistory(client: client, force: force, started: started, context: context, now: now)
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
    /// Succeeds only when both values are verifiably gone. Otherwise throws — and keeps
    /// reporting whatever is known to be stored; it never claims a disconnect that didn't happen.
    func disconnect(removeData: Bool, context: ModelContext) throws {
        generation += 1
        let deleted = keychainPair.delete()
        credentialState = keychainPair.state()
        guard deleted else {
            throw credentialState == .uncertain ? Trading212Error.credentialStateUncertain : Trading212Error.credentialStorage
        }
        lastError = nil
        lastFailureAt = nil
        automaticRetryAfter = nil
        lastAttemptAt = nil
        if removeData {
            try Persistence.commit(context) { try Trading212Reconciler.removeAllData(in: context) }
            defaults.removeObject(forKey: Self.instrumentsFetchedKey)
            for kind in Trading212HistoryKind.allCases { defaults.removeObject(forKey: Self.historyFetchedKey(kind)) }
            historyErrors = [:]
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

    /// Downloads each history feed newest first and stops at the first page that contains an
    /// already stored item, so only the first download walks the whole history. Never fails
    /// the balance sync: errors are kept per feed in `historyErrors`, stored rows stay as they were.
    private func refreshHistory(client: Trading212Client, force: Bool, started: Int, context: ModelContext, now: Date) async {
        for kind in Trading212HistoryKind.allCases {
            guard started == generation, isConnected else { return }
            await refresh(kind, client: client, force: force, started: started, context: context, now: now)
        }
    }

    private func refresh(_ kind: Trading212HistoryKind, client: Trading212Client, force: Bool, started: Int,
                         context: ModelContext, now: Date) async {
        let error = historyErrors[kind]
        if !force, error == nil, let last = historyFetchedAt(kind), now.timeIntervalSince(last) < Self.dividendsInterval { return }
        // A key without the scope fails the same way every time; only a manual sync retries it.
        if !force, error == .missingPermission { return }
        do {
            switch kind {
            case .dividends:
                let known = Set(try context.fetch(FetchDescriptor<BrokerDividend>()).map(\.key))
                let items = try await walkPages(known: known) { cursor in
                    let page = try await client.dividends(cursor: cursor)
                    return (page.items ?? [], page.nextPagePath)
                } keys: { Trading212DividendParsing.parse($0).map(\.key) }
                guard started == generation, isConnected else { return }
                let parsed = Trading212DividendParsing.parse(items)
                try Persistence.commit(context, save: saveContext) { try Trading212DividendReconciler.apply(parsed, now: now, in: context) }
            case .orders:
                let known = Set(try context.fetch(FetchDescriptor<BrokerOrder>()).map(\.key))
                let items = try await walkPages(known: known) { cursor in
                    let page = try await client.orders(cursor: cursor)
                    return (page.items ?? [], page.nextPagePath)
                } keys: { Trading212HistoryParsing.orders($0).map(\.key) }
                guard started == generation, isConnected else { return }
                let parsed = Trading212HistoryParsing.orders(items)
                try Persistence.commit(context, save: saveContext) { try Trading212HistoryReconciler.apply(orders: parsed, now: now, in: context) }
            case .transactions:
                let known = Set(try context.fetch(FetchDescriptor<BrokerCashTransaction>()).map(\.key))
                let items = try await walkPages(known: known) { cursor in
                    let page = try await client.transactions(cursor: cursor)
                    return (page.items ?? [], page.nextPagePath)
                } keys: { Trading212HistoryParsing.transactions($0).map(\.key) }
                guard started == generation, isConnected else { return }
                let parsed = Trading212HistoryParsing.transactions(items)
                try Persistence.commit(context, save: saveContext) { try Trading212HistoryReconciler.apply(transactions: parsed, now: now, in: context) }
            }
            defaults.set(now, forKey: Self.historyFetchedKey(kind))
            historyErrors[kind] = nil
        } catch is CancellationError {
            return
        } catch {
            guard started == generation else { return }
            historyErrors[kind] = (error as? Trading212Error) ?? (error is PersistenceError ? .localSaveFailed : .network)
        }
    }

    /// Follows `nextPagePath` cursors until a page contains a known key, the feed ends or the page cap is hit.
    private func walkPages<Item>(known: Set<String>, fetch: (String?) async throws -> ([Item], String?),
                                 keys: ([Item]) -> [String]) async throws -> [Item] {
        var all: [Item] = []
        var cursor: String?
        for _ in 0..<Self.historyMaxPages {
            let (items, nextPath) = try await fetch(cursor)
            all += items
            if keys(items).contains(where: known.contains) { break }
            guard !items.isEmpty, let next = Trading212Client.cursor(fromNextPagePath: nextPath), next != cursor else { break }
            cursor = next
        }
        return all
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

    /// The verified pair, or nil when missing, partial, locked, failing or uncertain.
    private func storedCredentials() -> Trading212Credentials? {
        guard let values = keychainPair.values() else { return nil }
        let credentials = Trading212Credentials(apiKey: values.key, apiSecret: values.secret)
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
    func lookup(_ account: String) -> SecretLookup { .notFound }
    func save(_ value: String, account: String) throws { throw KeychainError.status(errSecNotAvailable) }
    func delete(_ account: String) throws {}
}
