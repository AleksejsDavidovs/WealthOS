import Foundation
import SwiftData
import Testing
@testable import MyApp

/// Disk-backed tests: real SQLite stores in a temporary directory, closed and reopened.
@MainActor
@Suite("Disk persistence", .serialized)
struct PersistenceTests {
    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "WealthOS-PersistenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func dataSurvivesClosingAndReopeningTheStore() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = UUID()
        do {
            let container = try Persistence.makePersistentContainer(directory: directory)
            let context = container.mainContext
            context.insert(Account(id: accountID, name: "Checking", kind: .checking, currencyCode: "EUR",
                                   openingBalance: Decimal(string: "1234.56")!))
            context.insert(TransactionRecord(kind: .expense, amount: Decimal(string: "12.34")!, date: .now,
                                             note: "Lunch", accountID: accountID))
            let holding = Holding(name: "FTSE All-World", symbol: "VWCE", assetClass: .etf, currencyCode: "EUR",
                                  currentPrice: Decimal(string: "128.45")!, marketSymbol: "VWCE.DEX",
                                  priceSource: .market, autoApplyMarketPrice: true)
            context.insert(holding)
            context.insert(InvestmentTrade(holdingID: holding.id, kind: .buy, date: .now,
                                           quantity: Decimal(string: "3.141592")!, pricePerUnit: 100))
            context.insert(Goal(name: "Trip", type: .travel, targetAmount: 3_000, allocatedAmount: 500))
            context.insert(CurrencyRate(code: "USD", rateToBase: Decimal(string: "0.9123")!, source: .market))
            try context.save()
        }

        let reopened = try Persistence.makePersistentContainer(directory: directory)
        let context = reopened.mainContext
        let account = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        #expect(account.id == accountID)
        #expect(account.openingBalance == Decimal(string: "1234.56"))
        #expect(try context.fetch(FetchDescriptor<TransactionRecord>()).first?.amount == Decimal(string: "12.34"))
        let holding = try #require(try context.fetch(FetchDescriptor<Holding>()).first)
        #expect(holding.marketSymbol == "VWCE.DEX")
        #expect(holding.priceSource == .market)
        #expect(holding.autoApplyMarketPrice)
        #expect(try context.fetch(FetchDescriptor<InvestmentTrade>()).first?.quantity == Decimal(string: "3.141592"))
        #expect(try context.fetchCount(FetchDescriptor<Goal>()) == 1)
        #expect(try context.fetch(FetchDescriptor<CurrencyRate>()).first?.rateToBase == Decimal(string: "0.9123"))
    }

    @Test func flushWritesAutosavePendingChangesToDisk() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let container = try Persistence.makePersistentContainer(directory: directory)
            let context = container.mainContext
            context.autosaveEnabled = false
            context.insert(Account(name: "Unsaved", kind: .cash, currencyCode: "EUR", openingBalance: 42))
            #expect(context.hasChanges)
            #expect(Persistence.flush(context))
            #expect(!context.hasChanges)
        }
        let reopened = try Persistence.makePersistentContainer(directory: directory)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<Account>()).first?.name == "Unsaved")
        #expect(Persistence.containsUserData(reopened.mainContext))
    }

    @Test func emptyStoreIsNotReportedAsUserData() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try Persistence.makePersistentContainer(directory: directory)
        LedgerService.seedDefaultCategoriesIfNeeded(in: container.mainContext)
        #expect(!Persistence.containsUserData(container.mainContext))
    }

    @Test func unitTestRunsNeverOpenTheRealStore() throws {
        #expect(Persistence.isHostingTests(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        #expect(!Persistence.isHostingTests(environment: ["HOME": "/var/mobile"]))
        #expect(Persistence.isHostingTests())
        let model = AppModel()
        let configuration = try #require(model.persistentContainer?.configurations.first)
        #expect(configuration.isStoredInMemoryOnly)
    }

    @Test func storeFilesUseDatabaseFileProtection() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try Persistence.makePersistentContainer(directory: directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "WealthOS.store").path)
        // The simulator doesn't enforce data protection, but the requested class is recorded.
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            #expect(protection == .completeUntilFirstUserAuthentication)
        }
    }

    @Test func storeFromPreviousVersionOpensWithoutDataLoss() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "WealthOS.store")
        do {
            let schema = Schema(LegacySchemaV1.models)
            let configuration = ModelConfiguration("WealthOS", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            let account = LegacySchemaV1.Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 9_876)
            context.insert(account)
            context.insert(LegacySchemaV1.TransactionRecord(kind: .income, amount: 3_000, date: .now, accountID: account.id))
            context.insert(LegacySchemaV1.Holding(name: "Bitcoin", symbol: "BTC", assetClass: .crypto, currencyCode: "EUR",
                                                  currentPrice: 60_000))
            context.insert(LegacySchemaV1.CurrencyRate(code: "USD", rateToBase: Decimal(string: "0.9")!))
            try context.save()
        }

        let current = try Persistence.makePersistentContainer(directory: directory)
        let context = current.mainContext
        #expect(try context.fetch(FetchDescriptor<Account>()).map(\.openingBalance) == [9_876])
        #expect(try context.fetchCount(FetchDescriptor<TransactionRecord>()) == 1)
        let holding = try #require(try context.fetch(FetchDescriptor<Holding>()).first)
        #expect(holding.currentPrice == 60_000)
        #expect(holding.marketSymbol == "")
        #expect(holding.priceSource == .manual)
        #expect(try context.fetch(FetchDescriptor<CurrencyRate>()).first?.source == .manual)
    }
}
