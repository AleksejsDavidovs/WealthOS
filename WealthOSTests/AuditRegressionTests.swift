import Foundation
import SwiftData
import Testing
@testable import MyApp

// Regression tests for the independent audit findings (AUD-002, AUD-003, AUD-006, …).
// AUD-001 (Binance partial snapshots) lives in BinanceTests. Everything here uses isolated
// in-memory stores, mocked networking and in-memory secret stores.

private func dec(_ text: String) -> Decimal { Decimal(string: text)! }

/// In-memory Keychain stand-in that can be told to fail specific writes or deletions.
final class FlakySecrets: SecretStore, @unchecked Sendable {
    var values: [String: String] = [:]
    var failSave: Set<String> = []
    var failDelete: Set<String> = []
    private(set) var upgraded: [String] = []

    func read(_ account: String) -> String? { values[account] }
    func save(_ value: String, account: String) throws {
        if failSave.contains(account) { throw KeychainError.status(-25_291) }
        values[account] = value
    }
    func delete(_ account: String) throws {
        if failDelete.contains(account) { throw KeychainError.status(-25_291) }
        values[account] = nil
    }
    func upgradeProtection(_ account: String) { upgraded.append(account) }
}

// MARK: - AUD-004 / AUD-005 / AUD-007: credential lifecycle

@MainActor
@Suite("AUD-004/005/007 credential lifecycle")
struct CredentialLifecycleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var defaults: UserDefaults { UserDefaults(suiteName: "WealthOSTests.credentials.\(UUID().uuidString)")! }

    /// An isolated store; services under test get a failing save to simulate "the first
    /// snapshot couldn't be persisted" (e.g. disk full).
    func readOnlyContainer() throws -> ModelContainer { try Persistence.makeInMemoryContainer() }
    struct DiskFull: Error {}

    // Trading 212

    @Test func t212FirstConnectRollsBackWhenTheSnapshotCannotBeSaved() async throws {
        let secrets = FlakySecrets()
        let service = Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: defaults, sleep: { _ in })
        let container = try readOnlyContainer()
        service.saveContext = { _ in throw DiskFull() }
        await #expect(throws: Trading212Error.localSaveFailed) {
            try await service.connect(apiKey: "NEWKEY", apiSecret: "NEWSECRET", environment: .live, context: container.mainContext, now: now)
        }
        #expect(secrets.values.isEmpty)
        #expect(!service.isConnected && !service.hasLeftoverCredential)
        // Relaunch sees the same state.
        #expect(!Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: defaults).isConnected)
    }

    @Test func t212FailedReconnectKeepsTheWorkingKey() async throws {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "OLDKEY", "apiSecret": "OLDSECRET"]
        let service = Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: defaults, sleep: { _ in })
        #expect(service.isConnected)
        let container = try readOnlyContainer()
        service.saveContext = { _ in throw DiskFull() }
        await #expect(throws: Trading212Error.localSaveFailed) {
            try await service.connect(apiKey: "NEWKEY", apiSecret: "NEWSECRET", environment: .demo, context: container.mainContext, now: now)
        }
        #expect(secrets.values == ["apiKey": "OLDKEY", "apiSecret": "OLDSECRET"])
        #expect(service.isConnected && service.environment == .live)
    }

    @Test func t212PartialKeychainWriteNeverLeavesAMismatchedPair() async throws {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "OLDKEY", "apiSecret": "OLDSECRET"]
        secrets.failSave = ["apiSecret"]
        let service = Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: defaults, sleep: { _ in })
        let container = try Persistence.makeInMemoryContainer()
        await #expect(throws: Trading212Error.credentialStorage) {
            try await service.connect(apiKey: "NEWKEY", apiSecret: "NEWSECRET", environment: .live, context: container.mainContext, now: now)
        }
        #expect(secrets.values == ["apiKey": "OLDKEY", "apiSecret": "OLDSECRET"])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<BrokerAccountSnapshot>()) == 0)
    }

    @Test func t212DisconnectReportsKeychainFailuresAndCanBeRetried() async throws {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "KEY", "apiSecret": "SECRET"]
        let service = Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: defaults, sleep: { _ in })
        let container = try Persistence.makeInMemoryContainer()
        #expect(await service.sync(context: container.mainContext, force: true, now: now))

        secrets.failDelete = ["apiKey"]
        #expect(throws: Trading212Error.credentialStorage) { try service.disconnect(removeData: true, context: container.mainContext) }
        #expect(secrets.values == ["apiKey": "KEY"])                 // secret gone, key stuck
        #expect(!service.isConnected && service.hasLeftoverCredential)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<BrokerAccountSnapshot>()) == 1)   // nothing removed

        // After a relaunch the leftover is still reported, never silently treated as connected.
        let relaunched = Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: defaults)
        #expect(!relaunched.isConnected && relaunched.hasLeftoverCredential)

        secrets.failDelete = []
        try relaunched.disconnect(removeData: true, context: container.mainContext)
        #expect(secrets.values.isEmpty && !relaunched.hasLeftoverCredential)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<BrokerAccountSnapshot>()) == 0)
    }

    @Test func t212ReloadUpgradesProtectionWithoutDeleting() {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "KEY", "apiSecret": "SECRET"]
        let service = Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: defaults)
        #expect(secrets.upgraded == ["apiKey", "apiSecret"])
        // Locked device: reads return nothing. State says "not connected", nothing is deleted.
        let locked = FlakySecrets()
        let lockedService = Trading212Service(http: T212MockHTTP(), secrets: locked, defaults: defaults)
        #expect(!lockedService.isConnected)
        locked.values = ["apiKey": "KEY", "apiSecret": "SECRET"]          // device unlocked again
        lockedService.reloadConnectionState()
        #expect(lockedService.isConnected && service.isConnected)
    }

    // Binance

    @Test func binanceFirstConnectRollsBackWhenTheSnapshotCannotBeSaved() async throws {
        let secrets = FlakySecrets()
        let service = BinanceService(http: BinanceMockHTTP(), secrets: secrets, defaults: defaults, sleep: { _ in })
        let container = try readOnlyContainer()
        service.saveContext = { _ in throw DiskFull() }
        await #expect(throws: BinanceError.localSaveFailed) {
            try await service.connect(apiKey: "NEWKEY1", secretKey: "NEWSECRET1", context: container.mainContext, now: now)
        }
        #expect(secrets.values.isEmpty && !service.isConnected)
    }

    @Test func binanceFailedReconnectKeepsTheWorkingKey() async throws {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "OLDKEY1", "secretKey": "OLDSECRET1"]
        let service = BinanceService(http: BinanceMockHTTP(), secrets: secrets, defaults: defaults, sleep: { _ in })
        let container = try readOnlyContainer()
        service.saveContext = { _ in throw DiskFull() }
        await #expect(throws: BinanceError.localSaveFailed) {
            try await service.connect(apiKey: "NEWKEY1", secretKey: "NEWSECRET1", context: container.mainContext, now: now)
        }
        #expect(secrets.values == ["apiKey": "OLDKEY1", "secretKey": "OLDSECRET1"] && service.isConnected)
    }

    @Test func binanceDisconnectReportsKeychainFailures() async throws {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "KEY1", "secretKey": "SECRET1"]
        let service = BinanceService(http: BinanceMockHTTP(), secrets: secrets, defaults: defaults, sleep: { _ in })
        let container = try Persistence.makeInMemoryContainer()
        #expect(await service.sync(context: container.mainContext, force: true, now: now))
        secrets.failDelete = ["secretKey"]
        #expect(throws: BinanceError.credentialStorage) { try service.disconnect(removeData: true, context: container.mainContext) }
        #expect(secrets.values == ["secretKey": "SECRET1"] && !service.isConnected && service.hasLeftoverCredential)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<BinanceAccountSnapshot>()) == 1)
        secrets.failDelete = []
        try service.disconnect(removeData: true, context: container.mainContext)
        #expect(secrets.values.isEmpty && !service.hasLeftoverCredential)
    }

    @Test func binanceReloadUpgradesProtection() {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "KEY1", "secretKey": "SECRET1"]
        let service = BinanceService(http: BinanceMockHTTP(), secrets: secrets, defaults: defaults)
        #expect(service.isConnected && secrets.upgraded == ["apiKey", "secretKey"])
    }

    // App PIN

    @Test func pinStaysActiveWithItsAttemptCounterWhenRemovalFails() throws {
        let store = FlakySecrets()
        let manager = AppPINManager(store: store)
        try manager.enroll("246810")
        _ = manager.verify("111111", now: now)
        let counter = store.values["pinAttemptState"]
        store.failDelete = ["pinVerifier"]
        #expect(throws: PINError.removalFailed) { try manager.disable() }
        #expect(manager.isEnrolled)
        #expect(store.values["pinAttemptState"] == counter)          // brute-force counter not reset
        #expect(manager.verify("246810", now: now) == .success)
    }

    @Test func pinIsOffOnceTheVerifierIsGone() throws {
        let store = FlakySecrets()
        let manager = AppPINManager(store: store)
        try manager.enroll("246810")
        store.failDelete = ["pinAttemptState"]
        try manager.disable()
        #expect(!manager.isEnrolled)
        #expect(manager.verify("246810", now: now) == .notEnrolled)
        try manager.enroll("135790")                                 // a new PIN starts with a fresh counter
        #expect(manager.verify("135790", now: now) == .success)
    }

    @Test func lockManagerReportsAFailedPINRemoval() async throws {
        let store = FlakySecrets()
        let lock = AppLockManager(biometrics: MockBiometricAuthenticator(), pin: AppPINManager(store: store))
        try await lock.enrollPIN("246810")
        store.failDelete = ["pinVerifier"]
        #expect(throws: PINError.removalFailed) { try lock.disablePIN() }
        #expect(lock.isPINEnabled)
        store.failDelete = []
        try lock.disablePIN()
        #expect(!lock.isPINEnabled)
    }
}

// MARK: - AUD-009: stronger, never-automatic duplicate suggestions

@MainActor
@Suite("AUD-009 reconciliation suggestions")
struct ReconciliationSuggestionTests {
    func t212Positions(in context: ModelContext) throws -> [BrokerPosition] {
        let summary: T212AccountSummary = try T212Fixtures.decode(T212Fixtures.summary)
        let positions = try Trading212Parsing.parse(try T212Fixtures.decode(T212Fixtures.positions))
        let instruments = Trading212Parsing.instrumentIndex(try T212Fixtures.decode(T212Fixtures.instruments))
        try Trading212Reconciler.apply(summary: summary, positions: positions, instruments: instruments, environment: .live,
                                       now: .now, in: context)
        return try context.fetch(FetchDescriptor<BrokerPosition>())
    }

    @Test func trading212RequiresSameListingCurrencyAndClass() throws {
        let container = try Persistence.makeInMemoryContainer()
        let positions = try t212Positions(in: container.mainContext)    // VWCEd_EQ: ETF in EUR; AAPL_US_EQ: stock in USD
        let match = Holding(name: "VWCE", symbol: "VWCE", assetClass: .etf, currencyCode: "EUR", currentPrice: 1)
        let otherListing = Holding(name: "VWCE", symbol: "VWCE", assetClass: .etf, currencyCode: "GBP", currentPrice: 1)
        let wrongClass = Holding(name: "VWCE", symbol: "VWCE", assetClass: .stock, currencyCode: "EUR", currentPrice: 1)
        let viaMarketSymbol = Holding(name: "Apple", symbol: "", assetClass: .stock, currencyCode: "EUR", currentPrice: 1)
        viaMarketSymbol.marketSymbol = "AAPL"
        viaMarketSymbol.marketCurrencyCode = "USD"

        let suggested = Trading212Matching.holdingCandidates(holdings: [match, otherListing, wrongClass, viaMarketSymbol],
                                                             positions: positions, links: [])
        #expect(Set(suggested.map(\.holding.id)) == [match.id, viaMarketSymbol.id])
        #expect(suggested.first { $0.holding.id == match.id }?.position.ticker == "VWCEd_EQ")
    }

    @Test func trading212AmbiguousMatchesAreNotSuggested() throws {
        let container = try Persistence.makeInMemoryContainer()
        let positions = try t212Positions(in: container.mainContext)
        let first = Holding(name: "VWCE", symbol: "VWCE", assetClass: .etf, currencyCode: "EUR", currentPrice: 1)
        let second = Holding(name: "VWCE 2", symbol: "VWCE.DEX", assetClass: .etf, currencyCode: "EUR", currentPrice: 1)
        #expect(Trading212Matching.holdingCandidates(holdings: [first, second], positions: positions, links: []).isEmpty)
        #expect(Set(Trading212Matching.ambiguousHoldings(holdings: [first, second], positions: positions, links: []).map(\.id))
                == [first.id, second.id])
        // Linking is always the user's decision; nothing above created a link.
        #expect(try container.mainContext.fetchCount(FetchDescriptor<BrokerLink>()) == 0)
    }

    @Test func binanceRequiresConsistentIdentifiers() {
        let ethByID = Holding(name: "Ethereum", symbol: "ETH", assetClass: .crypto, currencyCode: "EUR", currentPrice: 1)
        ethByID.marketSymbol = "ethereum"
        let conflicting = Holding(name: "Mixed", symbol: "ETH", assetClass: .crypto, currencyCode: "EUR", currentPrice: 1)
        conflicting.marketSymbol = "bitcoin"
        let notCrypto = Holding(name: "BTC ETF", symbol: "BTC", assetClass: .etf, currencyCode: "EUR", currentPrice: 1)
        let assets: Set<String> = ["ETH", "BTC"]

        #expect(BinanceMatching.holdingCandidates(holdings: [ethByID], assets: assets, links: []).map(\.asset) == ["ETH"])
        #expect(BinanceMatching.holdingCandidates(holdings: [conflicting], assets: assets, links: []).isEmpty)
        #expect(BinanceMatching.ambiguousHoldings(holdings: [conflicting], assets: assets, links: []).map(\.id) == [conflicting.id])
        #expect(BinanceMatching.holdingCandidates(holdings: [notCrypto], assets: assets, links: []).isEmpty)
        // Two manual ETH holdings: ambiguous, neither suggested.
        let second = Holding(name: "ETH cold wallet", symbol: "ETH", assetClass: .crypto, currencyCode: "EUR", currentPrice: 1)
        #expect(BinanceMatching.holdingCandidates(holdings: [ethByID, second], assets: assets, links: []).isEmpty)
        #expect(BinanceMatching.ambiguousHoldings(holdings: [ethByID, second], assets: assets, links: []).count == 2)
    }
}

// MARK: - AUD-002: one as-of cutoff for cash and positions

@MainActor
@Suite("AUD-002 future-dated trades")
struct FutureTradeTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let calendar = Calendar.current
    var startOfToday: Date { calendar.startOfDay(for: .now) }
    var nextWeek: Date { startOfToday.addingTimeInterval(7 * 86_400 + 3_600) }
    var lastWeek: Date { startOfToday.addingTimeInterval(-7 * 86_400) }

    init() throws { container = try Persistence.makeInMemoryContainer() }

    func engine(now: Date = .now) throws -> FinanceEngine {
        FinanceEngine(accounts: try context.fetch(FetchDescriptor<Account>()),
                      transactions: try context.fetch(FetchDescriptor<TransactionRecord>()),
                      holdings: try context.fetch(FetchDescriptor<Holding>()),
                      trades: try context.fetch(FetchDescriptor<InvestmentTrade>()),
                      converter: CurrencyConverter(baseCode: "EUR"), now: now, calendar: calendar)
    }

    func setUp() throws -> (Account, Holding) {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 10_000)
        let etf = Holding(name: "ETF", symbol: "ETF", assetClass: .etf, currencyCode: "EUR", currentPrice: 100)
        context.insert(checking)
        context.insert(etf)
        context.insert(InvestmentTrade(holdingID: etf.id, kind: .buy, date: lastWeek, quantity: 10, pricePerUnit: 100,
                                       fee: 0, cashAccountID: checking.id, cashAmount: 1_000))
        try context.save()
        return (checking, etf)
    }

    @Test func futureBuyChangesNeitherHoldingsNorCashToday() throws {
        let (checking, etf) = try setUp()
        context.insert(InvestmentTrade(holdingID: etf.id, kind: .buy, date: nextWeek, quantity: 5, pricePerUnit: 100,
                                       fee: 0, cashAccountID: checking.id, cashAmount: 500))
        try context.save()

        let today = try engine()
        #expect(today.position(for: etf)?.position.quantity == 10)
        #expect(today.balance(of: checking) == 9_000)
        #expect(today.summary.netWorth == 10_000)
        #expect(today.scheduledCount == 1)

        let then = try engine(now: nextWeek)
        #expect(then.position(for: etf)?.position.quantity == 15)
        #expect(then.balance(of: checking) == 8_500)
        #expect(then.summary.netWorth == 10_000)
    }

    @Test func futureSaleDoesNotReduceTodaysHolding() throws {
        let (checking, etf) = try setUp()
        context.insert(InvestmentTrade(holdingID: etf.id, kind: .sell, date: nextWeek, quantity: 4, pricePerUnit: 100,
                                       fee: 0, cashAccountID: checking.id, cashAmount: 400))
        try context.save()

        let today = try engine()
        #expect(today.position(for: etf)?.position.quantity == 10)
        #expect(today.summary.holdingsValue == 1_000)
        #expect(today.summary.netWorth == 10_000)

        let then = try engine(now: nextWeek)
        #expect(then.position(for: etf)?.position.quantity == 6)
        #expect(then.balance(of: checking) == 9_400)
        #expect(then.summary.netWorth == 10_000)
    }

    @Test func scheduledTransactionAndTradeShareTheCutoff() throws {
        let (checking, etf) = try setUp()
        context.insert(TransactionRecord(kind: .income, amount: 2_000, date: nextWeek, accountID: checking.id))
        context.insert(InvestmentTrade(holdingID: etf.id, kind: .buy, date: nextWeek, quantity: 20, pricePerUnit: 100,
                                       fee: 0, cashAccountID: checking.id, cashAmount: 2_000))
        try context.save()
        let today = try engine()
        #expect(today.scheduledCount == 2)
        #expect(today.summary.netWorth == 10_000)
        let then = try engine(now: nextWeek)
        #expect(then.summary.netWorth == 12_000)       // +2,000 income; the buy only moves cash into the ETF
        #expect(then.position(for: etf)?.position.quantity == 30)
    }

    @Test func dateBoundaryIsTheEndOfToday() throws {
        let (_, etf) = try setUp()
        let lastSecondToday = startOfToday.addingTimeInterval(86_400 - 1)
        let firstSecondTomorrow = startOfToday.addingTimeInterval(86_400)
        context.insert(InvestmentTrade(holdingID: etf.id, kind: .buy, date: lastSecondToday, quantity: 1, pricePerUnit: 100, fee: 0))
        context.insert(InvestmentTrade(holdingID: etf.id, kind: .buy, date: firstSecondTomorrow, quantity: 2, pricePerUnit: 100, fee: 0))
        try context.save()
        #expect(try engine().position(for: etf)?.position.quantity == 11)
        #expect(try engine(now: firstSecondTomorrow).position(for: etf)?.position.quantity == 13)
    }

    @Test func cutoffKeepsExactDecimals() throws {
        let (_, etf) = try setUp()
        etf.currentPrice = dec("100.123456789")
        context.insert(InvestmentTrade(holdingID: etf.id, kind: .buy, date: nextWeek, quantity: dec("0.00000001"), pricePerUnit: 1, fee: 0))
        try context.save()
        #expect(try engine().summary.holdingsValue == dec("1001.23456789"))
    }
}

// MARK: - AUD-006: invalid trade histories are unknown, never zero

@MainActor
@Suite("AUD-006 invalid trade histories")
struct InvalidTradeHistoryTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let t0 = Date.now.addingTimeInterval(-10 * 86_400)

    init() throws { container = try Persistence.makeInMemoryContainer() }

    var engine: FinanceEngine { DataMaintenance.makeEngine(context: context, baseCurrency: "EUR") }

    @Test func overSoldHistoryIsReportedNotValuedAtZero() throws {
        context.insert(Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 1_000))
        let bad = Holding(name: "Bad", symbol: "BAD", assetClass: .stock, currencyCode: "EUR", currentPrice: 50)
        let good = Holding(name: "Good", symbol: "GOOD", assetClass: .stock, currencyCode: "EUR", currentPrice: 10)
        context.insert(bad); context.insert(good)
        // Imported/legacy data the editor would have refused: sells 10 after buying 5.
        context.insert(InvestmentTrade(holdingID: bad.id, kind: .buy, date: t0, quantity: 5, pricePerUnit: 40, fee: 0))
        context.insert(InvestmentTrade(holdingID: bad.id, kind: .sell, date: t0.addingTimeInterval(3_600), quantity: 10, pricePerUnit: 45, fee: 0))
        context.insert(InvestmentTrade(holdingID: good.id, kind: .buy, date: t0, quantity: 3, pricePerUnit: 8, fee: 0))
        try context.save()

        let engine = engine
        let badPosition = try #require(engine.position(for: bad))
        #expect(badPosition.error != nil)
        #expect(badPosition.marketValueBase == nil && badPosition.costBasisBase == nil && badPosition.realizedBase == nil)
        #expect(engine.summary.incompleteSources.contains("Investments"))
        #expect(engine.summary.netWorth == 1_030)                 // cash + the valid holding only
        #expect(engine.position(for: good)?.marketValueBase == 30)
        #expect(engine.portfolioMarketValue == 30)
        #expect(engine.positionsWithoutCost == 0)                // the invalid one is reported separately
        #expect(try context.fetchCount(FetchDescriptor<InvestmentTrade>()) == 3)   // history preserved
    }

    @Test func sellBeforeAnyBuyIsInconsistent() throws {
        let holding = Holding(name: "X", symbol: "X", assetClass: .stock, currencyCode: "EUR", currentPrice: 10)
        context.insert(holding)
        context.insert(InvestmentTrade(holdingID: holding.id, kind: .sell, date: t0, quantity: 1, pricePerUnit: 10, fee: 0))
        context.insert(InvestmentTrade(holdingID: holding.id, kind: .buy, date: t0.addingTimeInterval(86_400), quantity: 5, pricePerUnit: 10, fee: 0))
        try context.save()
        #expect(engine.position(for: holding)?.error != nil)
        #expect(engine.summary.holdingsValue == 0 && engine.summary.incompleteSources == ["Investments"])
    }

    @Test func deletingABuyThatALaterSaleNeedsIsRefused() throws {
        let holding = Holding(name: "X", symbol: "X", assetClass: .stock, currencyCode: "EUR", currentPrice: 10)
        let buy = InvestmentTrade(holdingID: holding.id, kind: .buy, date: t0, quantity: 10, pricePerUnit: 10, fee: 0)
        let sell = InvestmentTrade(holdingID: holding.id, kind: .sell, date: t0.addingTimeInterval(86_400), quantity: 8, pricePerUnit: 12, fee: 0)
        context.insert(holding); context.insert(buy); context.insert(sell)
        try context.save()

        #expect(throws: (any Error).self) { try LedgerService.delete(trade: buy, in: context) }
        #expect(!context.hasChanges)
        #expect(try context.fetchCount(FetchDescriptor<InvestmentTrade>()) == 2)
        #expect(engine.position(for: holding)?.position.quantity == 2)

        try LedgerService.delete(trade: sell, in: context)       // removing the sale is fine
        try context.save()
        #expect(engine.position(for: holding)?.position.quantity == 10)
    }

    @Test func validHistoriesAreUnaffected() throws {
        let holding = Holding(name: "X", symbol: "X", assetClass: .stock, currencyCode: "EUR", currentPrice: 12)
        context.insert(holding)
        context.insert(InvestmentTrade(holdingID: holding.id, kind: .buy, date: t0, quantity: 10, pricePerUnit: 10, fee: 1))
        context.insert(InvestmentTrade(holdingID: holding.id, kind: .sell, date: t0.addingTimeInterval(86_400), quantity: 4, pricePerUnit: 11, fee: 0))
        try context.save()
        let position = try #require(engine.position(for: holding))
        #expect(position.error == nil && position.position.quantity == 6)
        #expect(position.marketValueBase == 72)
        #expect(engine.summary.incompleteSources.isEmpty)
    }
}

// MARK: - AUD-003: transactional restore of ledger + provider caches + links

@MainActor
@Suite("AUD-003 backup restore")
struct ProviderRestoreTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A store with manual data, Trading 212 and Binance caches, and links between them.
    func populatedStore(binanceHTTP: BinanceMockHTTP = BinanceMockHTTP()) async throws -> (ModelContainer, Holding, Account) {
        let container = try Persistence.makeInMemoryContainer()
        let context = container.mainContext
        let eth = Holding(name: "Ethereum", symbol: "ETH", assetClass: .crypto, currencyCode: "EUR", currentPrice: 3_000)
        let vwce = Holding(name: "Vanguard FTSE All-World", symbol: "VWCE", assetClass: .etf, currencyCode: "EUR", currentPrice: 95)
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 1_000)
        context.insert(eth); context.insert(vwce); context.insert(checking)
        try context.save()

        let summary: T212AccountSummary = try T212Fixtures.decode(T212Fixtures.summary)
        let positions = try Trading212Parsing.parse(try T212Fixtures.decode(T212Fixtures.positions))
        try Persistence.commit(context) {
            try Trading212Reconciler.apply(summary: summary, positions: positions, instruments: nil, environment: .live, now: now, in: context)
            try Trading212Reconciler.setLinked(true, kind: .holding, localID: vwce.id, in: context)
        }
        let secrets = MemorySecrets()
        secrets.values = ["apiKey": "TESTKEY123", "secretKey": "TESTSECRET456"]
        let binance = BinanceService(http: binanceHTTP, secrets: secrets, defaults: UserDefaults(suiteName: "WealthOSTests.restore.\(UUID().uuidString)")!,
                                     sleep: { _ in })
        #expect(await binance.sync(context: context, force: true, now: now))
        try Persistence.commit(context) { try BinanceReconciler.setLinked(true, kind: .holding, localID: eth.id, in: context) }
        return (container, eth, checking)
    }

    func counts(_ context: ModelContext) throws -> [Int] {
        [try context.fetchCount(FetchDescriptor<BrokerAccountSnapshot>()), try context.fetchCount(FetchDescriptor<BrokerPosition>()),
         try context.fetchCount(FetchDescriptor<BrokerLink>()), try context.fetchCount(FetchDescriptor<BinanceAccountSnapshot>()),
         try context.fetchCount(FetchDescriptor<BinanceHolding>()), try context.fetchCount(FetchDescriptor<BinanceLink>())]
    }

    @Test func restoreReplacesProviderCachesAndLinksInsteadOfMixingThem() async throws {
        let (source, eth, _) = try await populatedStore()
        let sourceEngine = DataMaintenance.makeEngine(context: source.mainContext, baseCurrency: "EUR")
        let payload = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR", now: now)
        #expect(payload.version == 2 && payload.external?.trading212 != nil && payload.external?.binance != nil)

        // The target device has different provider data of its own.
        let (target, _, _) = try await populatedStore()
        let tContext = target.mainContext
        let stray = BrokerPosition(ticker: "STRAY_US_EQ", syncedAt: now)
        stray.quantity = 1
        stray.currentValue = 999
        tContext.insert(stray)
        tContext.insert(BinanceLink(kind: .holding, localID: UUID()))
        try tContext.save()

        // Round-trip through the real JSON encoding.
        let decoded = try BackupPayload.decoder().decode(BackupPayload.self, from: try BackupPayload.encoder().encode(payload))
        #expect(decoded.external?.binance?.holdings.map(\.amount) == payload.external?.binance?.holdings.map(\.amount))
        #expect(decoded.external?.trading212?.positions.map(\.currentValue) == payload.external?.trading212?.positions.map(\.currentValue))
        try BackupService.restore(decoded, into: tContext)

        #expect(try counts(tContext) == counts(source.mainContext))
        #expect(try tContext.fetch(FetchDescriptor<BrokerPosition>()).allSatisfy { $0.ticker != "STRAY_US_EQ" })
        let restored = DataMaintenance.makeEngine(context: tContext, baseCurrency: "EUR")
        #expect(restored.summary.netWorth == sourceEngine.summary.netWorth)
        #expect(restored.binanceTotalBase == sourceEngine.binanceTotalBase)
        let restoredETH = try #require(try tContext.fetch(FetchDescriptor<Holding>()).first { $0.id == eth.id })
        #expect(restored.countedVia(restoredETH) == "Binance")   // UUID relationship preserved
        // Restored provider data is flagged as unverified until re-synced.
        #expect(try tContext.fetch(FetchDescriptor<BrokerAccountSnapshot>()).first?.restoredFromBackup == true)
        #expect(try tContext.fetch(FetchDescriptor<BinanceAccountSnapshot>()).first?.restoredFromBackup == true)
        #expect(restored.summary.incompleteSources.isSuperset(of: ["Trading 212", "Binance"]))
    }

    @Test func firstSyncAfterRestoreClearsTheRestoredFlag() async throws {
        let (source, _, _) = try await populatedStore()
        let payload = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR", now: now)
        let target = try Persistence.makeInMemoryContainer()
        try BackupService.restore(payload, into: target.mainContext)
        let secrets = MemorySecrets()
        secrets.values = ["apiKey": "TESTKEY123", "secretKey": "TESTSECRET456"]
        let binance = BinanceService(http: BinanceMockHTTP(), secrets: secrets,
                                     defaults: UserDefaults(suiteName: "WealthOSTests.restore.\(UUID().uuidString)")!, sleep: { _ in })
        // Restored data is old, so even an automatic (stale-only) sync refreshes it.
        await binance.syncIfStale(context: target.mainContext, now: now.addingTimeInterval(86_400))
        #expect(try target.mainContext.fetch(FetchDescriptor<BinanceAccountSnapshot>()).first?.restoredFromBackup == false)
    }

    @Test func versionOneBackupClearsProviderCachesAndLinks() async throws {
        let (source, _, _) = try await populatedStore()
        var payload = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR", now: now)
        payload.version = 1
        payload.external = nil
        // Simulate a file written by the previous app version (no "external" key at all).
        var json = try JSONSerialization.jsonObject(with: try BackupPayload.encoder().encode(payload)) as? [String: Any] ?? [:]
        json.removeValue(forKey: "external")
        let legacy = try BackupPayload.decoder().decode(BackupPayload.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(legacy.version == 1 && legacy.external == nil)

        let (target, _, _) = try await populatedStore()
        try BackupService.restore(legacy, into: target.mainContext)
        #expect(try counts(target.mainContext) == [0, 0, 0, 0, 0, 0])
        #expect(try target.mainContext.fetchCount(FetchDescriptor<Holding>()) == 2)
        // Manual holdings without trades hold nothing; no stale provider value leaks in.
        #expect(DataMaintenance.makeEngine(context: target.mainContext, baseCurrency: "EUR").summary.netWorth == 1_000)
    }

    @Test func providerDataInAVersionOneBackupIsRejected() async throws {
        let (source, _, _) = try await populatedStore()
        var payload = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR", now: now)
        payload.version = 1
        #expect(throws: BackupValidationError.self) { try payload.validate() }
    }

    @Test func invalidProviderDataIsRejectedBeforeAnythingChanges() async throws {
        let (source, _, _) = try await populatedStore()
        var payload = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR", now: now)
        payload.external?.binance?.holdings[0].amount = -1
        let (target, _, _) = try await populatedStore()
        let before = try counts(target.mainContext)
        #expect(throws: BackupValidationError.self) { try BackupService.restore(payload, into: target.mainContext) }
        #expect(try counts(target.mainContext) == before)
    }

    @Test func failedSaveLeavesEverythingAsItWas() async throws {
        let (source, _, _) = try await populatedStore()
        let payload = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR", now: now)
        let (target, _, _) = try await populatedStore()
        let beforeCounts = try counts(target.mainContext)
        let beforeNetWorth = DataMaintenance.makeEngine(context: target.mainContext, baseCurrency: "EUR").summary.netWorth
        struct DiskFull: Error {}
        #expect(throws: DiskFull.self) {
            try BackupService.restore(payload, into: target.mainContext, save: { _ in throw DiskFull() })
        }
        #expect(try counts(target.mainContext) == beforeCounts)
        #expect(DataMaintenance.makeEngine(context: target.mainContext, baseCurrency: "EUR").summary.netWorth == beforeNetWorth)
        #expect(try target.mainContext.fetch(FetchDescriptor<BinanceAccountSnapshot>()).first?.restoredFromBackup == false)
    }

    @Test func backupsNeverContainCredentialsAndDropOrphanLinks() async throws {
        let (source, _, _) = try await populatedStore()
        source.mainContext.insert(BrokerLink(kind: .holding, localID: UUID()))   // points at nothing
        try source.mainContext.save()
        let payload = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR", now: now)
        #expect(payload.external?.trading212?.links.count == 1)
        let json = String(decoding: try BackupPayload.encoder().encode(payload), as: UTF8.self)
        #expect(!json.contains("TESTKEY123") && !json.contains("TESTSECRET456"))
        #expect(!json.lowercased().contains("secret") && !json.contains("apiKey"))
    }

    @Test func restoreIntoAnEmptyStoreWithoutCredentialsKeepsDataVisibleButUnverified() async throws {
        let (source, _, _) = try await populatedStore()
        let payload = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR", now: now)
        let target = try Persistence.makeInMemoryContainer()
        try BackupService.restore(payload, into: target.mainContext)
        // A new device has no credentials: nothing can sync, values are flagged, nothing is invented.
        let t212 = Trading212Service(http: T212MockHTTP(), secrets: MemorySecrets(),
                                     defaults: UserDefaults(suiteName: "WealthOSTests.restore.\(UUID().uuidString)")!, sleep: { _ in })
        #expect(!t212.isConnected)
        #expect(await t212.sync(context: target.mainContext, force: true, now: now) == false)
        let engine = DataMaintenance.makeEngine(context: target.mainContext, baseCurrency: "EUR")
        #expect(engine.brokerTotalBase == dec("1765.118"))
        #expect(engine.summary.incompleteSources.contains("Trading 212"))
    }
}
