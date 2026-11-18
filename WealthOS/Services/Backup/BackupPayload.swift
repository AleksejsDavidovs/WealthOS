import Foundation

/// Plain Codable mirror of the whole database. Encrypted before it ever touches disk.
nonisolated struct BackupPayload: Codable, Equatable, Sendable {
    /// 1: ledger only. 2: adds `external` (non-secret provider snapshots and "Counted via" links).
    static let currentVersion = 2

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
    /// Version 2+. Cached Trading 212 / Binance data and reconciliation links — never API keys
    /// or secrets, which stay in the device Keychain. nil in version 1 backups.
    var external: ExternalDTO? = nil
    /// Budgets and subscription decisions (optional; absent in backups made before budgets).
    var planning: PlanningDTO? = nil
    /// Daily portfolio points for performance history (optional; absent in older backups).
    var portfolioHistory: [PortfolioSnapshotDTO]? = nil

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
        var marketSymbol: String?, marketCurrencyCode: String?, priceSource: String?, autoApplyMarketPrice: Bool?
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
        var source: String?
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

    struct PortfolioSnapshotDTO: Codable, Equatable, Sendable {
        var id: UUID, date: Date, currencyCode: String, totalValue: Decimal, costedValue: Decimal, costBasis: Decimal, realized: Decimal
    }
    struct PlanningDTO: Codable, Equatable, Sendable {
        var budgets: [BudgetDTO]
        var subscriptionDecisions: [SubscriptionDecisionDTO]
    }
    struct BudgetDTO: Codable, Equatable, Sendable {
        var id: UUID, categoryID: UUID?, amount: Decimal, rollover: Bool, alertedMonth: String, alertedLevel: Int, createdAt: Date
    }
    struct SubscriptionDecisionDTO: Codable, Equatable, Sendable {
        var id: UUID, key: String, status: String, createdAt: Date
    }

    // MARK: External providers (version 2)

    struct ExternalDTO: Codable, Equatable, Sendable {
        var trading212: Trading212DTO?
        var binance: BinanceDTO?
        /// Bank reconciliation metadata (optional; absent in backups from before bank support).
        /// Never contains consents, Enable Banking session/account ids or backend credentials.
        var banking: BankingDTO? = nil
    }
    struct BankingDTO: Codable, Equatable, Sendable {
        var links: [BankLinkDTO]
        /// Booked provenance rows only. They are what keeps a restored ledger from importing the
        /// same bank transactions a second time.
        var transactions: [BankEntryDTO]
        var rules: [BankRuleDTO]
    }
    struct BankLinkDTO: Codable, Equatable, Sendable {
        var accountKey: String, aspspName: String, aspspCountry: String, localAccountID: UUID?
        var displayName: String, maskedIdentifier: String, currencyCode: String, cashAccountType: String, product: String
        var creditLimit: Decimal?, balanceAmount: Decimal?, balanceType: String, balanceReferenceDate: Date?
        var lastSuccessfulSyncAt: Date?, importStartDate: Date?, createdAt: Date
    }
    struct BankEntryDTO: Codable, Equatable, Sendable {
        var key: String, accountKey: String, identityKind: String, providerTransactionID: String, entryReference: String
        var amount: Decimal, currencyCode: String, directionKnown: Bool
        var bookingDate: Date?, valueDate: Date?, transactionDate: Date?
        var counterpartyName: String, counterpartyAccountHash: String, counterpartyAccountMasked: String
        var remittance: String, referenceNumber: String, bankTransactionCode: String, merchantCategoryCode: String
        var contentHash: String, bankDataChanged: Bool, resolution: String, reviewReason: String
        var ledgerRecordID: UUID?, candidateRecordIDs: String, firstSeenAt: Date, lastSeenAt: Date
    }
    struct BankRuleDTO: Codable, Equatable, Sendable {
        var matchKey: String, direction: String, action: String, categoryID: UUID?, otherAccountID: UUID?
        var label: String, createdAt: Date
    }
    struct LinkDTO: Codable, Equatable, Sendable {
        var kind: String, localID: UUID, createdAt: Date
    }
    struct Trading212DTO: Codable, Equatable, Sendable {
        var snapshot: Trading212SnapshotDTO?
        var positions: [Trading212PositionDTO]
        var links: [LinkDTO]
    }
    struct Trading212SnapshotDTO: Codable, Equatable, Sendable {
        var environment: String, accountNumber: Int?, currencyCode: String
        var cashAvailable: Decimal, cashInPies: Decimal, cashReserved: Decimal
        var investmentsValue: Decimal?, investmentsCost: Decimal?, unrealizedProfitLoss: Decimal?
        var realizedProfitLoss: Decimal?, reportedTotal: Decimal?, syncedAt: Date
    }
    struct Trading212PositionDTO: Codable, Equatable, Sendable {
        var ticker: String, name: String, shortName: String, instrumentType: String, isin: String
        var instrumentCurrency: String, quantity: Decimal, averagePrice: Decimal?, currentPrice: Decimal?
        var valueCurrency: String, currentValue: Decimal?, totalCost: Decimal?, unrealizedProfitLoss: Decimal?
        var fxImpact: Decimal?, openedAt: Date?, syncedAt: Date
    }
    struct BinanceDTO: Codable, Equatable, Sendable {
        var snapshot: BinanceSnapshotDTO?
        var holdings: [BinanceHoldingDTO]
        var links: [LinkDTO]
    }
    struct BinanceSnapshotDTO: Codable, Equatable, Sendable {
        var uid: Int64?, accountType: String, syncedAt: Date
        var flexibleStatus: String, flexibleSyncedAt: Date?, lockedStatus: String, lockedSyncedAt: Date?
        var pricesFetchedAt: Date?, mergedSpotAssets: String
    }
    struct BinanceHoldingDTO: Codable, Equatable, Sendable {
        var key: String, asset: String, wallet: String, productRef: String
        var free: Decimal, locked: Decimal, amount: Decimal
        var priceEUR: Decimal?, priceRoute: String, pricedAt: Date?, syncedAt: Date
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
        if let portfolioHistory { try unique(portfolioHistory.map(\.id), "portfolio snapshot") }
        if let planning {
            try unique(planning.budgets.map(\.id), "budget")
            try unique(planning.subscriptionDecisions.map(\.key), "subscription decision")
            if planning.budgets.contains(where: { $0.amount <= 0 }) { throw BackupValidationError.invalidValue("budget amount") }
        }

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
        try validateExternal()
    }

    private func validateExternal() throws {
        guard let external else { return }
        if version < 2 { throw BackupValidationError.invalidValue("provider data in a version 1 backup") }
        func links(_ items: [LinkDTO]) throws {
            for link in items where BrokerLinkKind(rawValue: link.kind) == nil {
                throw BackupValidationError.invalidValue("link type \(link.kind)")
            }
        }
        if let t212 = external.trading212 {
            if Set(t212.positions.map(\.ticker)).count != t212.positions.count {
                throw BackupValidationError.duplicateIdentifiers("Trading 212 position")
            }
            if t212.positions.contains(where: { $0.quantity < 0 || $0.ticker.isEmpty }) {
                throw BackupValidationError.invalidValue("Trading 212 position")
            }
            if !t212.positions.isEmpty && t212.snapshot == nil {
                throw BackupValidationError.brokenReference("Trading 212 positions without an account snapshot")
            }
            try links(t212.links)
        }
        if let binance = external.binance {
            if Set(binance.holdings.map(\.key)).count != binance.holdings.count {
                throw BackupValidationError.duplicateIdentifiers("Binance balance")
            }
            if binance.holdings.contains(where: {
                $0.amount < 0 || $0.free < 0 || $0.locked < 0 || $0.asset.isEmpty || BinanceWallet(rawValue: $0.wallet) == nil
                    || ($0.priceEUR.map { $0 <= 0 } ?? false)
            }) {
                throw BackupValidationError.invalidValue("Binance balance")
            }
            if !binance.holdings.isEmpty && binance.snapshot == nil {
                throw BackupValidationError.brokenReference("Binance balances without an account snapshot")
            }
            try links(binance.links)
        }
        if let banking = external.banking {
            if Set(banking.links.map(\.accountKey)).count != banking.links.count {
                throw BackupValidationError.duplicateIdentifiers("bank account link")
            }
            if Set(banking.transactions.map(\.key)).count != banking.transactions.count {
                throw BackupValidationError.duplicateIdentifiers("bank transaction")
            }
            let linkedLocal = banking.links.compactMap(\.localAccountID)
            if Set(linkedLocal).count != linkedLocal.count {
                throw BackupValidationError.invalidValue("two bank accounts linked to one account")
            }
            for entry in banking.transactions {
                guard let resolution = BankTransactionResolution(rawValue: entry.resolution), resolution != .pending,
                      !entry.key.isEmpty, entry.key.hasPrefix(entry.accountKey + "|") else {
                    throw BackupValidationError.invalidValue("bank transaction")
                }
            }
            for rule in banking.rules where BankRuleAction(rawValue: rule.action) == nil || !["in", "out"].contains(rule.direction) {
                throw BackupValidationError.invalidValue("bank rule")
            }
        }
    }
}

/// Raw values of `BrokerLink.Kind`, usable from nonisolated backup code.
nonisolated enum BrokerLinkKind: String {
    case holding, account
}
