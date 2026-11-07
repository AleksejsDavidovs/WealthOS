import Foundation
import SwiftData
import os

enum Persistence {
    static let modelTypes: [any PersistentModel.Type] = [
        Account.self, TransactionRecord.self, TransactionCategory.self, RecurringRule.self,
        Holding.self, InvestmentTrade.self, PricePoint.self, CurrencyRate.self,
        NetWorthSnapshot.self, Goal.self, SimulationScenario.self, MarketQuote.self
    ]

    static var schema: Schema { Schema(modelTypes) }

    /// Logger for operational errors only. Never log amounts, names or notes.
    static let logger = Logger(subsystem: "WealthOS", category: "persistence")

    static var storeDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "WealthOS", directoryHint: .isDirectory)
    }

    /// The on-device store. Files use `completeUntilFirstUserAuthentication`, Apple's
    /// recommended class for SQLite stores: encrypted at rest until the device is first
    /// unlocked after boot, and never blocking WAL/journal writes (e.g. an autosave right
    /// after the screen locks), which could otherwise fail and lose unsaved changes.
    static func makePersistentContainer(directory: URL = storeDirectory) throws -> ModelContainer {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let configuration = ModelConfiguration("WealthOS", schema: schema,
                                               url: directory.appending(path: "WealthOS.store"),
                                               allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        applyFileProtection(directory: directory)
        return container
    }

    /// True when the app process is hosting unit tests. The app then uses a throwaway
    /// in-memory store so test runs can never read or modify real financial data.
    static func isHostingTests(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    /// Saves pending changes. Failures are logged without any financial details.
    @discardableResult
    static func flush(_ context: ModelContext) -> Bool {
        guard context.hasChanges else { return true }
        do {
            try context.save()
            return true
        } catch {
            logger.error("Saving the data store failed (\((error as NSError).code, privacy: .public)).")
            return false
        }
    }

    /// Whether the store already contains user data (used to never show onboarding over it).
    static func containsUserData(_ context: ModelContext) -> Bool {
        let accounts = (try? context.fetchCount(FetchDescriptor<Account>())) ?? 0
        let holdings = (try? context.fetchCount(FetchDescriptor<Holding>())) ?? 0
        let transactions = (try? context.fetchCount(FetchDescriptor<TransactionRecord>())) ?? 0
        return accounts + holdings + transactions > 0
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, allowsSave: true,
                                               cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func applyFileProtection(directory: URL = storeDirectory) {
        let manager = FileManager.default
        do {
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            for file in try manager.contentsOfDirectory(atPath: directory.path) {
                try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                          ofItemAtPath: directory.appending(path: file).path)
            }
        } catch {
            logger.error("Could not apply file protection.")
        }
    }
}

/// Keys for lightweight preferences stored in UserDefaults. No financial data is stored here
/// except the optional onboarding estimates for income/expenses used as simulator defaults.
enum SettingsKey {
    static let appearance = "appearance"
    static let baseCurrency = "baseCurrency"
    static let lockEnabled = "lockEnabled"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let estimatedIncome = "estimatedMonthlyIncome"
    static let estimatedExpenses = "estimatedMonthlyExpenses"
    static let importedFileHashes = "importedCSVFileHashes"
    /// Online market prices are off by default; the app is fully offline until enabled.
    static let marketDataEnabled = "marketDataEnabled"
    static let marketAutoRefresh = "marketAutoRefresh"
    static let marketAutoApplyFX = "marketAutoApplyFX"
    static let marketLastSuccess = "marketLastSuccess"
    static let marketRateLimitPrefix = "marketRateLimit."
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
