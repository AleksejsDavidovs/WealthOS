import Foundation
import SwiftData
import SwiftUI
import os

enum Persistence {
    static let modelTypes: [any PersistentModel.Type] = [
        Account.self, TransactionRecord.self, TransactionCategory.self, RecurringRule.self,
        Holding.self, InvestmentTrade.self, PricePoint.self, CurrencyRate.self,
        NetWorthSnapshot.self, Goal.self, SimulationScenario.self, MarketQuote.self,
        BrokerAccountSnapshot.self, BrokerPosition.self, BrokerLink.self,
        BinanceAccountSnapshot.self, BinanceHolding.self, BinanceLink.self,
        BankConnection.self, BankAccountLink.self, BankTransaction.self, BankCounterpartyRule.self,
        Budget.self, SubscriptionDecision.self, PortfolioSnapshot.self
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

    /// Saves a user-initiated change. If saving fails, the unsaved edits are rolled back so
    /// the UI never shows a change that wasn't persisted, and a user-facing error is thrown.
    /// - Parameter save: injectable for tests; always `context.save()` in the app.
    static func commit(_ context: ModelContext, save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        do {
            try save(context)
        } catch {
            context.rollback()
            logger.error("Saving a user change failed (\((error as NSError).code, privacy: .public)).")
            throw PersistenceError.saveFailed
        }
    }

    /// Performs `change` (which may itself save) and commits it. Any failure rolls back.
    static func commit(_ context: ModelContext, save: (ModelContext) throws -> Void = { try $0.save() },
                       _ change: () throws -> Void) throws {
        do {
            try change()
        } catch {
            context.rollback()
            logger.error("Applying a user change failed (\((error as NSError).code, privacy: .public)).")
            throw PersistenceError.saveFailed
        }
        try commit(context, save: save)
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
    static let budgetAlerts = "budgetAlertsEnabled"
    static let subscriptionReminders = "subscriptionRemindersEnabled"
    static let monthlyReportNotification = "monthlyReportNotificationEnabled"
    /// Defaults to on (unset = on): bank access is lost silently otherwise.
    static let bankConsentReminders = "bankConsentRemindersEnabled"
    static let widgetHidesAmounts = "widgetHidesAmounts"
    /// The month ("2026-10") whose report the user last opened or dismissed on Home.
    static let lastSeenReportMonth = "lastSeenReportMonth"
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

    /// nil = follow the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Window-level style; `.unspecified` follows the system setting.
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    static func resolve(_ rawValue: String) -> AppearanceMode { AppearanceMode(rawValue: rawValue) ?? .dark }
}

enum PersistenceError: LocalizedError, Equatable {
    case saveFailed

    var errorDescription: String? {
        "Your change couldn't be saved, so nothing was changed. Please try again."
    }
}
