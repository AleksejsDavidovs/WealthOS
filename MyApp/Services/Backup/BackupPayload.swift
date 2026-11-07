import Foundation

/// Plain Codable mirror of the whole database. Encrypted before it ever touches disk.
nonisolated struct BackupPayload: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var createdAt: Date
    var appVersion: String
    var baseCurrency: String
    var accounts: [AccountDTO]
    var transactions: [TransactionDTO]
    var categories: [CategoryDTO]
    var recurringRules: [RecurringRuleDTO]
    var holdings: [HoldingDTO]
    var trades: [TradeDTO]
    var pricePoints: [PricePointDTO]
    var rates: [RateDTO]
    var snapshots: [SnapshotDTO]
    var goals: [GoalDTO]
    var scenarios: [ScenarioDTO]

    var recordCount: Int {
        accounts.count + transactions.count + categories.count + recurringRules.count + holdings.count
            + trades.count + pricePoints.count + rates.count + snapshots.count + goals.count + scenarios.count
    }

    struct AccountDTO: Codable, Equatable, Sendable {
        var id: UUID, name: String, kind: String, currencyCode: String, openingBalance: Decimal, openingDate: Date
        var institution: String, notes: String, colorName: String, isArchived: Bool, sortOrder: Int, createdAt: Date
    }
    struct TransactionDTO: Codable, Equatable, Sendable {
        var id: UUID, kind: String, amount: Decimal, destinationAmount: Decimal?, date: Date, note: String
        var accountID: UUID, destinationAccountID: UUID?, categoryID: UUID?, recurringRuleID: UUID?
        var importFingerprint: String?, createdAt: Date
    }
    struct CategoryDTO: Codable, Equatable, Sendable {
        var id: UUID, name: String, kind: String, symbol: String, colorName: String, isSystem: Bool, sortOrder: Int, createdAt: Date
    }
    struct RecurringRuleDTO: Codable, Equatable, Sendable {
        var id: UUID, kind: String, amount: Decimal, destinationAmount: Decimal?, accountID: UUID, destinationAccountID: UUID?
        var categoryID: UUID?, note: String, frequency: String, startDate: Date, endDate: Date?, generatedCount: Int
        var isActive: Bool, createdAt: Date
    }
    struct HoldingDTO: Codable, Equatable, Sendable {
        var id: UUID, name: String, symbol: String, assetClass: String, currencyCode: String, currentPrice: Decimal
        var priceUpdatedAt: Date?, accountID: UUID?, notes: String, createdAt: Date
    }
    struct TradeDTO: Codable, Equatable, Sendable {
        var id: UUID, holdingID: UUID, kind: String, date: Date, quantity: Decimal, pricePerUnit: Decimal, fee: Decimal
        var cashAccountID: UUID?, cashAmount: Decimal?, note: String, createdAt: Date
    }
    struct PricePointDTO: Codable, Equatable, Sendable {
        var id: UUID, holdingID: UUID, date: Date, price: Decimal
    }
    struct RateDTO: Codable, Equatable, Sendable {
        var code: String, rateToBase: Decimal, updatedAt: Date
    }
    struct SnapshotDTO: Codable, Equatable, Sendable {
        var id: UUID, date: Date, netWorth: Decimal, liquidTotal: Decimal, investmentTotal: Decimal
        var otherAssetsTotal: Decimal, liabilitiesTotal: Decimal, source: String, currencyCode: String, note: String
    }
    struct GoalDTO: Codable, Equatable, Sendable {
        var id: UUID, name: String, type: String, targetAmount: Decimal, targetDate: Date?, allocatedAmount: Decimal
        var monthlyContribution: Decimal, colorName: String, notes: String, createdAt: Date
    }
    struct ScenarioDTO: Codable, Equatable, Sendable {
        var id: UUID, kind: String, name: String, parameters: SimulationParameters, updatedAt: Date
    }
}

nonisolated enum BackupValidationError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case duplicateIdentifiers(String)
    case brokenReference(String)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Backup format version \(version) is not supported."
        case .duplicateIdentifiers(let entity): "The backup contains duplicate \(entity) records."
        case .brokenReference(let detail): "The backup is inconsistent: \(detail)."
        case .invalidValue(let detail): "The backup contains an invalid value: \(detail)."
        }
    }
}

nonisolated extension BackupPayload {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Structural integrity checks run before any existing data is touched.
    func validate() throws {
        guard version >= 1 && version <= Self.currentVersion else { throw BackupValidationError.unsupportedVersion(version) }
        func unique<T: Hashable>(_ values: [T], _ name: String) throws {
            if Set(values).count != values.count { throw BackupValidationError.duplicateIdentifiers(name) }
        }
        try unique(accounts.map(\.id), "account")
        try unique(transactions.map(\.id), "transaction")
        try unique(categories.map(\.id), "category")
        try unique(recurringRules.map(\.id), "recurring rule")
        try unique(holdings.map(\.id), "holding")
        try unique(trades.map(\.id), "trade")
        try unique(goals.map(\.id), "goal")
        try unique(rates.map(\.code), "exchange rate")

        let accountIDs = Set(accounts.map(\.id))
        let categoryIDs = Set(categories.map(\.id))
        let holdingIDs = Set(holdings.map(\.id))

        for account in accounts where AccountKind(rawValue: account.kind) == nil {
            throw BackupValidationError.invalidValue("account type \(account.kind)")
        }
        for transaction in transactions {
            guard let kind = TransactionKind(rawValue: transaction.kind) else {
                throw BackupValidationError.invalidValue("transaction type")
            }
            guard accountIDs.contains(transaction.accountID) else {
                throw BackupValidationError.brokenReference("a transaction refers to a missing account")
            }
            if let destination = transaction.destinationAccountID, !accountIDs.contains(destination) {
                throw BackupValidationError.brokenReference("a transfer refers to a missing account")
            }
            if kind == .transfer && transaction.destinationAccountID == nil {
                throw BackupValidationError.brokenReference("a transfer has no destination account")
            }
            if kind != .adjustment && transaction.amount <= 0 {
                throw BackupValidationError.invalidValue("non-positive transaction amount")
            }
            if let category = transaction.categoryID, !categoryIDs.contains(category) {
                throw BackupValidationError.brokenReference("a transaction refers to a missing category")
            }
        }
        for rule in recurringRules where !accountIDs.contains(rule.accountID) {
            throw BackupValidationError.brokenReference("a recurring rule refers to a missing account")
        }
        for trade in trades {
            guard holdingIDs.contains(trade.holdingID) else {
                throw BackupValidationError.brokenReference("a trade refers to a missing holding")
            }
            if let cash = trade.cashAccountID, !accountIDs.contains(cash) {
                throw BackupValidationError.brokenReference("a trade refers to a missing account")
            }
            guard trade.quantity > 0, trade.pricePerUnit >= 0, trade.fee >= 0 else {
                throw BackupValidationError.invalidValue("trade quantity or price")
            }
        }
        // Positions must be internally consistent (no overselling).
        let grouped = Dictionary(grouping: trades, by: \.holdingID)
        for (_, holdingTrades) in grouped {
            let inputs = holdingTrades.map {
                TradeInput(kind: TradeKind(rawValue: $0.kind) ?? .buy, date: $0.date, quantity: $0.quantity,
                           price: $0.pricePerUnit, fee: $0.fee, createdAt: $0.createdAt)
            }
            do { _ = try InvestmentCalculator.position(for: inputs) } catch {
                throw BackupValidationError.invalidValue("a holding sells more units than it bought")
            }
        }
        for rate in rates where rate.rateToBase <= 0 {
            throw BackupValidationError.invalidValue("exchange rate for \(rate.code)")
        }
        for goal in goals where goal.targetAmount <= 0 || goal.allocatedAmount < 0 {
            throw BackupValidationError.invalidValue("goal amount")
        }
    }
}
