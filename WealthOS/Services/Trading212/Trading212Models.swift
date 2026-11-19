import Foundation
import SwiftData

// Locally cached, read-only copy of the Trading 212 account. These rows are a provider
// snapshot, not user-entered records: each sync replaces them, keyed by Trading 212's own
// instrument ticker, so repeated syncs never duplicate anything. They are never mixed into
// manual holdings or trades, so manual cost basis and history are never overwritten.

/// Account-level figures from `GET /equity/account/summary`, in the account's primary currency.
@Model
final class BrokerAccountSnapshot {
    var id: UUID = UUID()
    var environmentRaw: String = Trading212Environment.live.rawValue
    /// Trading 212 "Primary trading account number".
    var accountNumber: Int?
    var currencyCode: String = "EUR"
    var cashAvailable: Decimal = 0
    var cashInPies: Decimal = 0
    var cashReserved: Decimal = 0
    var investmentsValue: Decimal?
    var investmentsCost: Decimal?
    var unrealizedProfitLoss: Decimal?
    var realizedProfitLoss: Decimal?
    /// The provider's own total. Shown for reconciliation only — never added to net worth.
    var reportedTotal: Decimal?
    var syncedAt: Date = Date()
    /// Came from a backup and hasn't been re-synced since; values are last known, not verified.
    var restoredFromBackup: Bool = false

    init(environment: Trading212Environment, currencyCode: String, syncedAt: Date) {
        self.environmentRaw = environment.rawValue
        self.currencyCode = currencyCode
        self.syncedAt = syncedAt
    }

    var environment: Trading212Environment { Trading212Environment(rawValue: environmentRaw) ?? .live }
    /// All cash held at Trading 212: free, in pies and reserved for pending orders.
    var cashTotal: Decimal { cashAvailable + cashInPies + cashReserved }
}

/// One open position from `GET /equity/positions`.
@Model
final class BrokerPosition {
    var id: UUID = UUID()
    /// Stable provider identifier, e.g. "AAPL_US_EQ".
    var ticker: String = ""
    var name: String = ""
    /// From `/equity/metadata/instruments`; empty until instrument metadata has been fetched.
    var shortName: String = ""
    var instrumentType: String = ""
    var isin: String = ""
    var instrumentCurrency: String = ""
    var quantity: Decimal = 0
    /// Per share, in the instrument currency.
    var averagePrice: Decimal?
    var currentPrice: Decimal?
    /// Currency of the wallet-impact figures below (the account currency).
    var valueCurrency: String = ""
    var currentValue: Decimal?
    var totalCost: Decimal?
    var unrealizedProfitLoss: Decimal?
    var fxImpact: Decimal?
    var openedAt: Date?
    var syncedAt: Date = Date()

    init(ticker: String, syncedAt: Date) {
        self.ticker = ticker
        self.syncedAt = syncedAt
    }

    var displaySymbol: String {
        if !shortName.isEmpty { return shortName }
        return Trading212Matching.baseSymbol(ofTicker: ticker)
    }

    var assetClass: AssetClass {
        switch instrumentType.uppercased() {
        case "ETF": .etf
        case "STOCK": .stock
        default: .other
        }
    }
}

/// The user's explicit decision that a manual holding or account is already represented by
/// the Trading 212 data, so it must not be counted a second time. The manual record is kept.
@Model
final class BrokerLink {
    enum Kind: String { case holding, account }

    var id: UUID = UUID()
    var kindRaw: String = Kind.holding.rawValue
    var localID: UUID = UUID()
    var createdAt: Date = Date()

    init(kind: Kind, localID: UUID, createdAt: Date = .now) {
        self.kindRaw = kind.rawValue
        self.localID = localID
        self.createdAt = createdAt
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .holding }
}

/// One paid-out dividend from `GET /equity/history/dividends`. Keyed by Trading 212's own
/// `reference`, so repeated syncs update instead of duplicating. Informational only: the cash
/// is already part of the account's cash balance, so dividends never change net worth.
@Model
final class BrokerDividend {
    var id: UUID = UUID()
    /// Stable provider key (`reference`, or a derived key when the API omits it).
    var key: String = ""
    var ticker: String = ""
    var name: String = ""
    /// Net amount in the account currency (`currencyCode`).
    var amount: Decimal = 0
    var currencyCode: String = ""
    var paidOn: Date = Date()
    var quantity: Decimal?
    /// Gross per share, in the instrument currency.
    var grossPerShare: Decimal?
    var instrumentCurrency: String = ""
    var type: String = ""
    var syncedAt: Date = Date()

    init(key: String, syncedAt: Date) {
        self.key = key
        self.syncedAt = syncedAt
    }

    var displaySymbol: String { Trading212Matching.baseSymbol(ofTicker: ticker) }
}

/// One executed fill from `GET /equity/history/orders` (read-only history). Keyed by the
/// provider's fill/order id, so repeated syncs never duplicate. Informational: holdings and cash
/// already come from the live snapshot, so trades never change net worth.
@Model
final class BrokerOrder {
    var id: UUID = UUID()
    var key: String = ""
    var ticker: String = ""
    var name: String = ""
    /// "BUY" or "SELL".
    var side: String = ""
    var quantity: Decimal = 0
    /// Per share, in the instrument currency.
    var price: Decimal?
    var instrumentCurrency: String = ""
    /// Cash moved, as a positive amount in the account currency (`currencyCode`).
    var netValue: Decimal = 0
    /// Taxes and fees charged on the fill (account currency).
    var fees: Decimal = 0
    /// Realized profit/loss of a sale (account currency); 0 for buys.
    var realized: Decimal = 0
    var currencyCode: String = ""
    var filledAt: Date = Date()
    var syncedAt: Date = Date()

    init(key: String, syncedAt: Date) {
        self.key = key
        self.syncedAt = syncedAt
    }

    var isBuy: Bool { side.uppercased() == "BUY" }
    var displaySymbol: String { Trading212Matching.baseSymbol(ofTicker: ticker) }
}

/// A deposit, withdrawal, fee, transfer or interest payment from `GET /equity/history/transactions`.
@Model
final class BrokerCashTransaction {
    var id: UUID = UUID()
    var key: String = ""
    /// DEPOSIT, WITHDRAW, FEE, TRANSFER, INTEREST_ON_FREE_CASH, LENDING_INTEREST.
    var type: String = ""
    /// Signed: money into the account is positive, out is negative.
    var amount: Decimal = 0
    var currencyCode: String = ""
    var date: Date = Date()
    var syncedAt: Date = Date()

    init(key: String, syncedAt: Date) {
        self.key = key
        self.syncedAt = syncedAt
    }
}

/// The Trading 212 account's value (cash + positions) once per day, recorded on sync. The
/// provider has no value history, so the "worth" line starts on the first synced day.
@Model
final class BrokerValuePoint {
    var id: UUID = UUID()
    var date: Date = Date()
    var currencyCode: String = ""
    var value: Decimal = 0
    var cash: Decimal = 0

    init(date: Date, currencyCode: String, value: Decimal, cash: Decimal) {
        self.date = date
        self.currencyCode = currencyCode
        self.value = value
        self.cash = cash
    }
}
