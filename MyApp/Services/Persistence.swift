import Foundation
import SwiftData
import os

enum Persistence {
    static let modelTypes: [any PersistentModel.Type] = [
        Account.self, TransactionRecord.self, TransactionCategory.self, RecurringRule.self,
        Holding.self, InvestmentTrade.self, PricePoint.self, CurrencyRate.self,
        NetWorthSnapshot.self, Goal.self, SimulationScenario.self
    ]

    static var schema: Schema { Schema(modelTypes) }

    /// Logger for operational errors only. Never log amounts, names or notes.
    static let logger = Logger(subsystem: "WealthOS", category: "persistence")

    static var storeDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "WealthOS", directoryHint: .isDirectory)
    }

    /// The on-device store. Files use `completeUnlessOpen` protection: encrypted with
    /// the device passcode while locked, without breaking writes already in flight.
    static func makePersistentContainer() throws -> ModelContainer {
        let directory = storeDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        let configuration = ModelConfiguration("WealthOS", schema: schema,
                                               url: directory.appending(path: "WealthOS.store"),
                                               allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        applyFileProtection()
        return container
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, allowsSave: true,
                                               cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func applyFileProtection() {
        let manager = FileManager.default
        let directory = storeDirectory
        do {
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: directory.path)
            for file in try manager.contentsOfDirectory(atPath: directory.path) {
                try manager.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
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
