import Foundation
import SwiftData
import Testing
@testable import MyApp

// Regression tests for the second audit (NEW-001 … NEW-004). Isolated in-memory stores,
// mocked HTTP (T212MockHTTP / BinanceMockHTTP) and mock secret stores (FlakySecrets) only.

private func dec(_ text: String) -> Decimal { Decimal(string: text)! }
private func suite() -> UserDefaults { UserDefaults(suiteName: "WealthOSTests.audit2.\(UUID().uuidString)")! }

// MARK: - NEW-001: incomplete valuations never become ordinary history

@MainActor
@Suite("NEW-001 historical snapshots")
struct HistoricalSnapshotTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws { container = try Persistence.makeInMemoryContainer() }

    var automatic: [NetWorthSnapshot] {
        ((try? context.fetch(FetchDescriptor<NetWorthSnapshot>())) ?? []).filter { $0.source == .automatic }
    }

    func summary(netWorth: Decimal, missingRate: Bool = false, incomplete: String? = nil) -> NetWorthSummary {
        var summary = NetWorthSummary()
        summary.liquid = netWorth
        if missingRate { summary.missingRateCurrencies = ["USD"] }
        if let incomplete { summary.incompleteSources = [incomplete] }
        return summary
    }

    @Test func incompleteTotalsAreNotRecorded() {
        for incomplete in [summary(netWorth: 900, missingRate: true), summary(netWorth: 900, incomplete: "Binance"),
                           summary(netWorth: 900, incomplete: "Investments"), summary(netWorth: 900, incomplete: "Trading 212")] {
            #expect(SnapshotService.recordAutomaticSnapshot(summary: incomplete, currencyCode: "EUR", hasData: true,
                                                            in: context, now: now) == .skippedIncomplete)
        }
        #expect(automatic.isEmpty)   // nothing fabricated
    }

    @Test func aCompleteSnapshotOfTheDayIsNotOverwrittenByALowerBound() {
        #expect(SnapshotService.recordAutomaticSnapshot(summary: summary(netWorth: 1_000), currencyCode: "EUR", hasData: true,
                                                        in: context, now: now) == .recorded)
        #expect(SnapshotService.recordAutomaticSnapshot(summary: summary(netWorth: 400, incomplete: "Binance"), currencyCode: "EUR",
                                                        hasData: true, in: context, now: now.addingTimeInterval(600)) == .skippedIncomplete)
        #expect(automatic.count == 1 && automatic.first?.netWorth == 1_000)
        // Recovery: the next complete valuation updates the day normally.
        #expect(SnapshotService.recordAutomaticSnapshot(summary: summary(netWorth: 1_050), currencyCode: "EUR", hasData: true,
                                                        in: context, now: now.addingTimeInterval(1_200)) == .recorded)
        #expect(automatic.count == 1 && automatic.first?.netWorth == 1_050)
    }

    @Test func partialBinanceSyncIsNotRecordedButRecoveryIs() async throws {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "KEY1", "secretKey": "SECRET1"]
        let http = BinanceMockHTTP()
        let service = BinanceService(http: http, secrets: secrets, defaults: suite(), sleep: { _ in })
        let denied: BinanceMockHTTP.Reply = (401, #"{"code":-2015,"msg":"Invalid API-key, IP, or permissions for action."}"#, [:])
        http.handler = { endpoint, _ in
            endpoint == .flexiblePositions || endpoint == .lockedPositions ? denied : BinanceFixtures.reply(endpoint)
        }
        #expect(await service.sync(context: context, force: true, now: now))
        #expect(DataMaintenance.makeEngine(context: context, baseCurrency: "EUR").summary.isComplete == false)
        #expect(automatic.isEmpty)                                         // Spot-only lower bound not stored

        http.handler = { endpoint, _ in BinanceFixtures.reply(endpoint) }
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(60)))
        let engine = DataMaintenance.makeEngine(context: context, baseCurrency: "EUR")
        #expect(engine.summary.isComplete)
        #expect(automatic.count == 1 && automatic.first?.netWorth == engine.summary.netWorth)
    }

    @Test func invalidTradeHistoryIsNotRecorded() throws {
        let holding = Holding(name: "X", symbol: "X", assetClass: .stock, currencyCode: "EUR", currentPrice: 10)
        context.insert(Account(name: "Cash", kind: .checking, currencyCode: "EUR", openingBalance: 100))
        context.insert(holding)
        context.insert(InvestmentTrade(holdingID: holding.id, kind: .sell, date: Date.now.addingTimeInterval(-86_400),
                                       quantity: 1, pricePerUnit: 10, fee: 0))
        try context.save()
        #expect(DataMaintenance.refreshSnapshot(context: context, baseCurrency: "EUR") == .skippedIncomplete)
        #expect(automatic.isEmpty)
    }

    @Test func restoredProviderDataIsNotRecordedUntilResynced() async throws {
        // Source device: Binance synced and a complete automatic snapshot for today.
        let source = try Persistence.makeInMemoryContainer()
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "KEY1", "secretKey": "SECRET1"]
        #expect(await BinanceService(http: BinanceMockHTTP(), secrets: secrets, defaults: suite(), sleep: { _ in })
            .sync(context: source.mainContext, force: true, now: now))
        let history = try source.mainContext.fetch(FetchDescriptor<NetWorthSnapshot>()).count
        let payload = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR", now: now)

        try BackupService.restore(payload, into: context)
        #expect(try context.fetch(FetchDescriptor<NetWorthSnapshot>()).count == history)   // history preserved
        #expect(DataMaintenance.refreshSnapshot(context: context, baseCurrency: "EUR") == .skippedIncomplete)

        let service = BinanceService(http: BinanceMockHTTP(), secrets: secrets, defaults: suite(), sleep: { _ in })
        #expect(await service.sync(context: context, force: true, now: Date.now))
        #expect(DataMaintenance.makeEngine(context: context, baseCurrency: "EUR").summary.isComplete)
        #expect(DataMaintenance.refreshSnapshot(context: context, baseCurrency: "EUR") != .skippedIncomplete)
    }
}

// MARK: - NEW-002: completeness metadata for Goals, Simulator and Accounts

@Suite("NEW-002 completeness metadata")
struct CompletenessMetadataTests {
    @Test func issuesDescribeEveryKindOfIncompleteness() {
        var summary = NetWorthSummary()
        summary.liquid = 1_000
        #expect(summary.isComplete && summary.completenessIssues.isEmpty)
        summary.missingRateCurrencies = ["USD"]
        summary.incompleteSources = ["Binance", "Investments"]
        #expect(!summary.isComplete)
        #expect(summary.completenessIssues.count == 2)
        #expect(summary.completenessIssues[0].contains("USD"))
        #expect(summary.completenessIssues[1].contains("Binance") && summary.completenessIssues[1].contains("Investments"))
    }

    @Test func goalsAndSimulatorUseTheSameFlaggedSummary() {
        var summary = NetWorthSummary()
        summary.liquid = 500
        summary.holdingsValue = 300
        summary.incompleteSources = ["Binance"]
        // Calculations are unchanged; the flag travels with the same summary the screens read.
        #expect(GoalMath.overview(summary: summary, goals: []).available == 800)
        #expect(SimulatorViewModel.liveStartingBalances(summary).investments == 300)
        #expect(!summary.isComplete)
    }
}

// MARK: - NEW-003: explicit, verified credential rollback

@MainActor
@Suite("NEW-003 credential rollback")
struct CredentialRollbackTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    struct DiskFull: Error {}

    @Test func t212WriteFailureFollowedByRollbackFailureIsUncertain() async throws {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "OLDKEY", "apiSecret": "OLDSECRET"]
        let defaults = suite()
        let service = Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: defaults, sleep: { _ in })
        let container = try Persistence.makeInMemoryContainer()
        secrets.mutationsBeforeFailure = 1        // key write succeeds, secret write fails, rollback fails
        await #expect(throws: Trading212Error.credentialStateUncertain) {
            try await service.connect(apiKey: "NEWKEY", apiSecret: "NEWSECRET", environment: .live, context: container.mainContext, now: now)
        }
        #expect(secrets.values == ["apiKey": "NEWKEY", "apiSecret": "OLDSECRET"])   // the mismatched pair…
        #expect(service.credentialState == .uncertain && !service.isConnected)      // …is never treated as connected
        #expect(await service.sync(context: container.mainContext, force: true, now: now) == false)

        // Survives a relaunch.
        let relaunched = Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: defaults)
        #expect(relaunched.credentialState == .uncertain && !relaunched.isConnected)

        // A verified disconnect resolves it.
        secrets.mutationsBeforeFailure = nil
        try relaunched.disconnect(removeData: false, context: container.mainContext)
        #expect(relaunched.credentialState == .missing && secrets.values.isEmpty)
        #expect(Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: defaults).credentialState == .missing)
    }

    @Test func t212SnapshotFailureFollowedByRollbackFailureIsUncertain() async throws {
        let secrets = FlakySecrets()
        let service = Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: suite(), sleep: { _ in })
        service.saveContext = { _ in throw DiskFull() }
        let container = try Persistence.makeInMemoryContainer()
        secrets.mutationsBeforeFailure = 2        // both writes succeed, then the rollback deletes fail
        await #expect(throws: Trading212Error.credentialStateUncertain) {
            try await service.connect(apiKey: "NEWKEY", apiSecret: "NEWSECRET", environment: .live, context: container.mainContext, now: now)
        }
        #expect(service.credentialState == .uncertain && !service.isConnected)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<BrokerAccountSnapshot>()) == 0)
    }

    @Test func t212VerifiedRollbackIsReportedAsSuch() async throws {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "OLDKEY", "apiSecret": "OLDSECRET"]
        let service = Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: suite(), sleep: { _ in })
        service.saveContext = { _ in throw DiskFull() }
        let container = try Persistence.makeInMemoryContainer()
        await #expect(throws: Trading212Error.localSaveFailed) {
            try await service.connect(apiKey: "NEWKEY", apiSecret: "NEWSECRET", environment: .live, context: container.mainContext, now: now)
        }
        #expect(secrets.values == ["apiKey": "OLDKEY", "apiSecret": "OLDSECRET"])
        #expect(service.credentialState == .stored)
    }

    @Test func binanceWriteFailureFollowedByRollbackFailureIsUncertain() async throws {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "OLDKEY1", "secretKey": "OLDSECRET1"]
        let defaults = suite()
        let service = BinanceService(http: BinanceMockHTTP(), secrets: secrets, defaults: defaults, sleep: { _ in })
        let container = try Persistence.makeInMemoryContainer()
        secrets.mutationsBeforeFailure = 1
        await #expect(throws: BinanceError.credentialStateUncertain) {
            try await service.connect(apiKey: "NEWKEY1", secretKey: "NEWSECRET1", context: container.mainContext, now: now)
        }
        #expect(service.credentialState == .uncertain && !service.isConnected)
        #expect(BinanceService(http: BinanceMockHTTP(), secrets: secrets, defaults: defaults).credentialState == .uncertain)
        #expect(await service.sync(context: container.mainContext, force: true, now: now) == false)
    }

    @Test func binanceSnapshotFailureFollowedByRollbackFailureIsUncertain() async throws {
        let secrets = FlakySecrets()
        let service = BinanceService(http: BinanceMockHTTP(), secrets: secrets, defaults: suite(), sleep: { _ in })
        service.saveContext = { _ in throw DiskFull() }
        let container = try Persistence.makeInMemoryContainer()
        secrets.mutationsBeforeFailure = 2
        await #expect(throws: BinanceError.credentialStateUncertain) {
            try await service.connect(apiKey: "NEWKEY1", secretKey: "NEWSECRET1", context: container.mainContext, now: now)
        }
        #expect(service.credentialState == .uncertain)
    }

    @Test func interruptedWriteIsUncertainAfterRelaunch() {
        // Simulates the app being killed between the two Keychain writes.
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "NEWKEY", "apiSecret": "OLDSECRET"]
        let defaults = suite()
        defaults.set(true, forKey: "credentialWriteInProgress.trading212")
        let service = Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: defaults)
        #expect(service.credentialState == .uncertain && !service.isConnected)
    }

    @Test func failedDisconnectIsNeverReportedAsSuccess() throws {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "KEY1", "secretKey": "SECRET1"]
        let service = BinanceService(http: BinanceMockHTTP(), secrets: secrets, defaults: suite())
        let container = try Persistence.makeInMemoryContainer()
        secrets.mutationsBeforeFailure = 0
        #expect(throws: BinanceError.credentialStorage) { try service.disconnect(removeData: false, context: container.mainContext) }
        #expect(service.credentialState == .stored && service.isConnected)
    }
}

// MARK: - NEW-004: Keychain outcomes are distinguished

@MainActor
@Suite("NEW-004 Keychain error handling")
struct KeychainOutcomeTests {
    @Test func lockedAndFailingKeychainAreNotMissingCredentials() async throws {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "KEY", "apiSecret": "SECRET"]
        secrets.locked = ["apiKey"]
        let http = T212MockHTTP()
        let service = Trading212Service(http: http, secrets: secrets, defaults: suite())
        #expect(service.credentialState == .locked && !service.isConnected && !service.hasLeftoverCredential)

        secrets.locked = []
        secrets.failLookup = ["apiSecret"]
        service.reloadConnectionState()
        #expect(service.credentialState == .unavailable)

        // Connecting now could overwrite (and then "roll back" by deleting) unknown items: refused.
        let container = try Persistence.makeInMemoryContainer()
        await #expect(throws: Trading212Error.keychainUnavailable) {
            try await service.connect(apiKey: "NEW", apiSecret: "NEW", environment: .live, context: container.mainContext)
        }
        #expect(http.requests.isEmpty)
        #expect(secrets.values == ["apiKey": "KEY", "apiSecret": "SECRET"])     // nothing deleted

        secrets.failLookup = []
        service.reloadConnectionState()
        #expect(service.credentialState == .stored)
    }

    @Test func binanceDistinguishesLockedFromMissing() {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "KEY1", "secretKey": "SECRET1"]
        secrets.locked = ["apiKey", "secretKey"]
        let service = BinanceService(http: BinanceMockHTTP(), secrets: secrets, defaults: suite())
        #expect(service.credentialState == .locked)
        #expect(BinanceService(http: BinanceMockHTTP(), secrets: FlakySecrets(), defaults: suite()).credentialState == .missing)
    }

    @Test func protectionMigrationFailureIsReportedAndKeepsTheKey() {
        let secrets = FlakySecrets()
        secrets.values = ["apiKey": "KEY", "apiSecret": "SECRET"]
        secrets.failUpgrade = ["apiSecret"]
        let service = Trading212Service(http: T212MockHTTP(), secrets: secrets, defaults: suite())
        #expect(service.protectionUpgradeFailed)
        #expect(service.isConnected)
        #expect(secrets.values.count == 2)
        secrets.failUpgrade = []
        service.reloadConnectionState()
        #expect(!service.protectionUpgradeFailed)
    }

    @Test func pinFailsClosedWhenItsStateCannotBeRead() throws {
        let store = FlakySecrets()
        let manager = AppPINManager(store: store)
        try manager.enroll("246810")
        _ = manager.verify("000000")
        _ = manager.verify("000000")                                  // two failures recorded
        let counter = store.values["pinAttemptState"]

        store.failLookup = ["pinAttemptState"]
        #expect(manager.verify("246810") == .unavailable)             // not "0 failures, correct PIN"
        #expect(store.values["pinAttemptState"] == counter)           // nothing counted or reset

        store.failLookup = []
        store.locked = ["pinVerifier"]
        #expect(manager.verify("246810") == .unavailable)             // not "no PIN enrolled"

        store.locked = []
        store.values["pinAttemptState"] = "not-base64!"
        #expect(manager.verify("246810") == .unavailable)             // corrupt counter never resets

        store.values["pinAttemptState"] = counter
        #expect(manager.verify("246810") == .success)
    }

    @Test func missingCounterStillStartsFresh() throws {
        let store = FlakySecrets()
        let manager = AppPINManager(store: store)
        try manager.enroll("246810")
        store.values["pinAttemptState"] = nil                          // genuinely absent (legacy)
        #expect(manager.verify("246810") == .success)
    }
}
