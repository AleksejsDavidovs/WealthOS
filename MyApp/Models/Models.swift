import Foundation
import SwiftData

// All models reference each other by UUID instead of SwiftData relationships.
// This keeps deletes explicit (see LedgerService), makes backups a straight
// mapping, and avoids cascading surprises with personal financial data.
// Enum-typed values are persisted as raw strings for schema stability.

@Model
final class Account {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = AccountKind.checking.rawValue
    var currencyCode: String = "EUR"
    /// Signed balance at `openingDate`. Liabilities are stored as negative values.
    var openingBalance: Decimal = 0
    var openingDate: Date = Date()
    var institution: String = ""
    var notes: String = ""
    var colorName: String = "blue"
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    init(id: UUID = UUID(), name: String, kind: AccountKind, currencyCode: String, openingBalance: Decimal,
         openingDate: Date = .now, institution: String = "", notes: String = "", colorName: String = "blue",
         isArchived: Bool = false, sortOrder: Int = 0, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.currencyCode = currencyCode
        self.openingBalance = openingBalance
        self.openingDate = openingDate
        self.institution = institution
        self.notes = notes
        self.colorName = colorName
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .otherAsset }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
final class TransactionRecord {
    var id: UUID = UUID()
    var kindRaw: String = TransactionKind.expense.rawValue
    /// Positive amount in the source account's currency. Adjustments are signed.
    var amount: Decimal = 0
    /// Amount credited to the destination account for cross-currency transfers.
    var destinationAmount: Decimal?
    var date: Date = Date()
    var note: String = ""
    var accountID: UUID = UUID()
    var destinationAccountID: UUID?
    var categoryID: UUID?
    var recurringRuleID: UUID?
    var importFingerprint: String?
    var createdAt: Date = Date()

    init(id: UUID = UUID(), kind: TransactionKind, amount: Decimal, destinationAmount: Decimal? = nil, date: Date,
         note: String = "", accountID: UUID, destinationAccountID: UUID? = nil, categoryID: UUID? = nil,
         recurringRuleID: UUID? = nil, importFingerprint: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.amount = amount
        self.destinationAmount = destinationAmount
        self.date = date
        self.note = note
        self.accountID = accountID
        self.destinationAccountID = destinationAccountID
        self.categoryID = categoryID
        self.recurringRuleID = recurringRuleID
        self.importFingerprint = importFingerprint
        self.createdAt = createdAt
    }

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
final class TransactionCategory {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = CategoryKind.expense.rawValue
    var symbol: String = "tag.fill"
    var colorName: String = "gray"
    /// System categories ("Other", "Other income") are the fallback when a category is deleted.
    var isSystem: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    init(id: UUID = UUID(), name: String, kind: CategoryKind, symbol: String, colorName: String,
         isSystem: Bool = false, sortOrder: Int = 0, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.symbol = symbol
        self.colorName = colorName
        self.isSystem = isSystem
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    var kind: CategoryKind {
        get { CategoryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
final class RecurringRule {
    var id: UUID = UUID()
    var kindRaw: String = TransactionKind.expense.rawValue
    var amount: Decimal = 0
    var destinationAmount: Decimal?
    var accountID: UUID = UUID()
    var destinationAccountID: UUID?
    var categoryID: UUID?
    var note: String = ""
    var frequencyRaw: String = RecurrenceFrequency.monthly.rawValue
    var startDate: Date = Date()
    var endDate: Date?
    /// Number of occurrences already generated as transactions.
    var generatedCount: Int = 0
    var isActive: Bool = true
    var createdAt: Date = Date()

    init(id: UUID = UUID(), kind: TransactionKind, amount: Decimal, destinationAmount: Decimal? = nil,
         accountID: UUID, destinationAccountID: UUID? = nil, categoryID: UUID? = nil, note: String = "",
         frequency: RecurrenceFrequency, startDate: Date, endDate: Date? = nil, generatedCount: Int = 0,
         isActive: Bool = true, createdAt: Date = .now) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.amount = amount
        self.destinationAmount = destinationAmount
        self.accountID = accountID
        self.destinationAccountID = destinationAccountID
        self.categoryID = categoryID
        self.note = note
        self.frequencyRaw = frequency.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.generatedCount = generatedCount
        self.isActive = isActive
        self.createdAt = createdAt
    }

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var frequency: RecurrenceFrequency {
        get { RecurrenceFrequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }

    /// The next occurrence that has not been generated yet, or nil if the rule has ended.
    var nextDueDate: Date? {
        guard isActive, let next = frequency.occurrence(generatedCount, from: startDate) else { return nil }
        if let endDate, next > endDate { return nil }
        return next
    }
}

@Model
final class Holding {
    var id: UUID = UUID()
    var name: String = ""
    var symbol: String = ""
    var assetClassRaw: String = AssetClass.etf.rawValue
    var currencyCode: String = "EUR"
    /// Manually entered market price per unit, in `currencyCode`. Never fetched live.
    var currentPrice: Decimal = 0
    var priceUpdatedAt: Date?
    /// Optional investment account this position is held in (organizational only).
    var accountID: UUID?
    var notes: String = ""
    var createdAt: Date = Date()

    init(id: UUID = UUID(), name: String, symbol: String, assetClass: AssetClass, currencyCode: String,
         currentPrice: Decimal, priceUpdatedAt: Date? = nil, accountID: UUID? = nil, notes: String = "",
         createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.assetClassRaw = assetClass.rawValue
        self.currencyCode = currencyCode
        self.currentPrice = currentPrice
        self.priceUpdatedAt = priceUpdatedAt
        self.accountID = accountID
        self.notes = notes
        self.createdAt = createdAt
    }

    var assetClass: AssetClass {
        get { AssetClass(rawValue: assetClassRaw) ?? .other }
        set { assetClassRaw = newValue.rawValue }
    }
}

@Model
final class InvestmentTrade {
    var id: UUID = UUID()
    var holdingID: UUID = UUID()
    var kindRaw: String = TradeKind.buy.rawValue
    var date: Date = Date()
    var quantity: Decimal = 0
    /// Price per unit in the holding's currency.
    var pricePerUnit: Decimal = 0
    /// Fee in the holding's currency.
    var fee: Decimal = 0
    /// Account the purchase was paid from / sale proceeds were credited to.
    /// A trade moves value between cash and investments; it is never an expense or income.
    var cashAccountID: UUID?
    /// Amount debited/credited on `cashAccountID`, in that account's currency.
    var cashAmount: Decimal?
    var note: String = ""
    var createdAt: Date = Date()

    init(id: UUID = UUID(), holdingID: UUID, kind: TradeKind, date: Date, quantity: Decimal, pricePerUnit: Decimal,
         fee: Decimal = 0, cashAccountID: UUID? = nil, cashAmount: Decimal? = nil, note: String = "",
         createdAt: Date = .now) {
        self.id = id
        self.holdingID = holdingID
        self.kindRaw = kind.rawValue
        self.date = date
        self.quantity = quantity
        self.pricePerUnit = pricePerUnit
        self.fee = fee
        self.cashAccountID = cashAccountID
        self.cashAmount = cashAmount
        self.note = note
        self.createdAt = createdAt
    }

    var kind: TradeKind {
        get { TradeKind(rawValue: kindRaw) ?? .buy }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
final class PricePoint {
    var id: UUID = UUID()
    var holdingID: UUID = UUID()
    var date: Date = Date()
    var price: Decimal = 0

    init(id: UUID = UUID(), holdingID: UUID, date: Date, price: Decimal) {
        self.id = id
        self.holdingID = holdingID
        self.date = date
        self.price = price
    }
}

@Model
final class CurrencyRate {
    var code: String = ""
    /// 1 unit of `code` equals `rateToBase` units of the base currency. Entered manually.
    var rateToBase: Decimal = 1
    var updatedAt: Date = Date()

    init(code: String, rateToBase: Decimal, updatedAt: Date = .now) {
        self.code = code
        self.rateToBase = rateToBase
        self.updatedAt = updatedAt
    }
}

@Model
final class NetWorthSnapshot {
    var id: UUID = UUID()
    var date: Date = Date()
    var netWorth: Decimal = 0
    var liquidTotal: Decimal = 0
    var investmentTotal: Decimal = 0
    var otherAssetsTotal: Decimal = 0
    var liabilitiesTotal: Decimal = 0
    var sourceRaw: String = SnapshotSource.automatic.rawValue
    var currencyCode: String = "EUR"
    var note: String = ""

    init(id: UUID = UUID(), date: Date, netWorth: Decimal, liquidTotal: Decimal = 0, investmentTotal: Decimal = 0,
         otherAssetsTotal: Decimal = 0, liabilitiesTotal: Decimal = 0, source: SnapshotSource,
         currencyCode: String, note: String = "") {
        self.id = id
        self.date = date
        self.netWorth = netWorth
        self.liquidTotal = liquidTotal
        self.investmentTotal = investmentTotal
        self.otherAssetsTotal = otherAssetsTotal
        self.liabilitiesTotal = liabilitiesTotal
        self.sourceRaw = source.rawValue
        self.currencyCode = currencyCode
        self.note = note
    }

    var source: SnapshotSource {
        get { SnapshotSource(rawValue: sourceRaw) ?? .automatic }
        set { sourceRaw = newValue.rawValue }
    }
}

@Model
final class Goal {
    var id: UUID = UUID()
    var name: String = ""
    var typeRaw: String = GoalType.custom.rawValue
    var targetAmount: Decimal = 0
    var targetDate: Date?
    /// Earmarked portion of existing assets. NOT an additional asset; never added to net worth.
    var allocatedAmount: Decimal = 0
    var monthlyContribution: Decimal = 0
    var colorName: String = "blue"
    var notes: String = ""
    var createdAt: Date = Date()

    init(id: UUID = UUID(), name: String, type: GoalType, targetAmount: Decimal, targetDate: Date? = nil,
         allocatedAmount: Decimal = 0, monthlyContribution: Decimal = 0, colorName: String? = nil,
         notes: String = "", createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.typeRaw = type.rawValue
        self.targetAmount = targetAmount
        self.targetDate = targetDate
        self.allocatedAmount = allocatedAmount
        self.monthlyContribution = monthlyContribution
        self.colorName = colorName ?? type.defaultColor
        self.notes = notes
        self.createdAt = createdAt
    }

    var type: GoalType {
        get { GoalType(rawValue: typeRaw) ?? .custom }
        set { typeRaw = newValue.rawValue }
    }
}

@Model
final class SimulationScenario {
    var id: UUID = UUID()
    var kindRaw: String = ScenarioKind.balanced.rawValue
    var name: String = ""
    /// JSON-encoded `SimulationParameters`.
    var parametersData: Data = Data()
    var updatedAt: Date = Date()

    init(id: UUID = UUID(), kind: ScenarioKind, name: String, parameters: SimulationParameters, updatedAt: Date = .now) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.name = name
        self.parametersData = (try? JSONEncoder().encode(parameters)) ?? Data()
        self.updatedAt = updatedAt
    }

    var kind: ScenarioKind {
        get { ScenarioKind(rawValue: kindRaw) ?? .balanced }
        set { kindRaw = newValue.rawValue }
    }

    var parameters: SimulationParameters? {
        get { try? JSONDecoder().decode(SimulationParameters.self, from: parametersData) }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else { return }
            parametersData = data
            updatedAt = .now
        }
    }
}
