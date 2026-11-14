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
