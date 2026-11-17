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
    /// Price per unit in `currencyCode` used for valuation. Entered manually, or copied from a
    /// market quote only when the user taps "Use" or enabled automatic updates for this holding.
    var currentPrice: Decimal = 0
    var priceUpdatedAt: Date?
    /// Optional investment account this position is held in (organizational only).
    var accountID: UUID?
    var notes: String = ""
    var createdAt: Date = Date()
    /// Provider identifier: Alpha Vantage symbol (e.g. "VWCE.DEX") or CoinGecko coin id ("bitcoin").
    var marketSymbol: String = ""
    /// Currency the provider quotes in (may be "GBX" for London listings). Empty = holding currency.
    var marketCurrencyCode: String = ""
    var priceSourceRaw: String = PriceSource.manual.rawValue
    /// Explicit per-holding opt-in to copy refreshed market quotes into `currentPrice`.
    var autoApplyMarketPrice: Bool = false

    init(id: UUID = UUID(), name: String, symbol: String, assetClass: AssetClass, currencyCode: String,
         currentPrice: Decimal, priceUpdatedAt: Date? = nil, accountID: UUID? = nil, notes: String = "",
         createdAt: Date = .now, marketSymbol: String = "", marketCurrencyCode: String = "",
         priceSource: PriceSource = .manual, autoApplyMarketPrice: Bool = false) {
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
        self.marketSymbol = marketSymbol
        self.marketCurrencyCode = marketCurrencyCode
        self.priceSourceRaw = priceSource.rawValue
        self.autoApplyMarketPrice = autoApplyMarketPrice
    }

    var assetClass: AssetClass {
        get { AssetClass(rawValue: assetClassRaw) ?? .other }
        set { assetClassRaw = newValue.rawValue }
    }

    var priceSource: PriceSource {
        get { PriceSource(rawValue: priceSourceRaw) ?? .manual }
        set { priceSourceRaw = newValue.rawValue }
    }

    /// Which provider can quote this holding, if a market symbol is linked.
    var marketProvider: MarketProvider? {
        guard !marketSymbol.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        switch assetClass {
        case .crypto: return .coinGecko
        case .etf, .stock, .other: return .alphaVantage
        case .cash: return nil
        }
    }

    /// Currency the provider reports prices in for this holding.
    var marketQuoteCurrency: String {
        if marketProvider == .coinGecko { return currencyCode }
        return marketCurrencyCode.isEmpty ? currencyCode : marketCurrencyCode
    }

    var marketQuoteKey: String? {
        marketProvider.map { MarketQuote.key(provider: $0, symbol: marketSymbol, currency: marketQuoteCurrency) }
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
    /// 1 unit of `code` equals `rateToBase` units of the base currency.
    var rateToBase: Decimal = 1
    var updatedAt: Date = Date()
    var sourceRaw: String = PriceSource.manual.rawValue

    init(code: String, rateToBase: Decimal, updatedAt: Date = .now, source: PriceSource = .manual) {
        self.code = code
        self.rateToBase = rateToBase
        self.updatedAt = updatedAt
        self.sourceRaw = source.rawValue
    }

    var source: PriceSource {
        get { PriceSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
}

/// Local cache of public market quotes. Quotes never affect valuation by themselves;
/// they're copied into a holding's price or a currency rate only on explicit opt-in.
@Model
final class MarketQuote {
    var key: String = ""
    var providerRaw: String = MarketProvider.coinGecko.rawValue
    var symbol: String = ""
    /// Currency of `price` (for FX quotes: the base currency; `price` = 1 `symbol` in base).
    var currencyCode: String = ""
    var price: Decimal = 0
    /// Provider's own timestamp for the quote (trading day or last update), if supplied.
    var quoteTime: Date?
    /// When WealthOS last fetched this quote successfully.
    var fetchedAt: Date = Date()

    init(provider: MarketProvider, symbol: String, currencyCode: String, price: Decimal,
         quoteTime: Date?, fetchedAt: Date) {
        self.key = Self.key(provider: provider, symbol: symbol, currency: currencyCode)
        self.providerRaw = provider.rawValue
        self.symbol = symbol
        self.currencyCode = currencyCode
        self.price = price
        self.quoteTime = quoteTime
        self.fetchedAt = fetchedAt
    }

    var provider: MarketProvider { MarketProvider(rawValue: providerRaw) ?? .coinGecko }

    static func key(provider: MarketProvider, symbol: String, currency: String) -> String {
        "\(provider.rawValue):\(symbol.lowercased()):\(currency.uppercased())"
    }

    var value: QuoteValue {
        QuoteValue(provider: provider, symbol: symbol, currency: currencyCode, price: price,
                   quoteTime: quoteTime, fetchedAt: fetchedAt)
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

// MARK: - Planning (added after bank support; new tables only, every field has a default,
// so existing stores migrate automatically)

/// A monthly spending limit for one expense category, or for all expenses (`categoryID == nil`),
/// in the base currency.
@Model
final class Budget {
    var id: UUID = UUID()
    var categoryID: UUID?
    var amount: Decimal = 0
    /// Adds last month's unspent amount (never a deficit) to this month's limit.
    var rollover: Bool = false
    /// Notification bookkeeping: the month ("2026-11") and highest threshold (80 / 100) already
    /// notified, so each threshold is announced at most once per month.
    var alertedMonth: String = ""
    var alertedLevel: Int = 0
    var createdAt: Date = Date()

    init(id: UUID = UUID(), categoryID: UUID?, amount: Decimal, rollover: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.categoryID = categoryID
        self.amount = amount
        self.rollover = rollover
        self.createdAt = createdAt
    }
}

nonisolated enum SubscriptionDecisionStatus: String, Codable, Sendable {
    /// The user confirmed a suggestion, or marked a payment as a subscription.
    case confirmed
    /// "Not a subscription": never suggested again.
    case dismissed
}

/// The user's decision about a payee detected (or marked) as a subscription. Detection itself
/// is computed from transactions; only decisions are stored.
@Model
final class SubscriptionDecision {
    var id: UUID = UUID()
    /// The payee key (`SubscriptionDetector.key`), e.g. "merchant:spotify" or "note:music streaming".
    var key: String = ""
    var statusRaw: String = SubscriptionDecisionStatus.confirmed.rawValue
    var createdAt: Date = Date()

    init(id: UUID = UUID(), key: String, status: SubscriptionDecisionStatus, createdAt: Date = .now) {
        self.id = id
        self.key = key
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
    }

    var status: SubscriptionDecisionStatus {
        get { SubscriptionDecisionStatus(rawValue: statusRaw) ?? .confirmed }
        set { statusRaw = newValue.rawValue }
    }
}
