import Foundation
import SwiftData

// Locally cached, read-only copy of the Binance account. Like the Trading 212 snapshot, these
// rows are replaced by each sync (keyed by wallet + asset + Binance product/position id), so
// repeated syncs never duplicate anything, and they are never mixed into manual holdings,
// trades or transactions. Prices are Binance market prices converted to EUR.

nonisolated enum BinanceWallet: String, CaseIterable, Sendable {
    case spot, flexible, locked

    var title: String {
        switch self {
        case .spot: "Spot"
        case .flexible: "Flexible Earn"
        case .locked: "Locked Earn"
        }
    }

    var isEarn: Bool { self != .spot }
}

/// Outcome of the last attempt to read one Simple Earn product.
nonisolated enum BinanceEarnStatus: String, Sendable {
    /// Read successfully (possibly with no positions).
    case ok
    /// The key may not read Simple Earn. The amount is unknown — not zero.
    case unavailable
    /// Temporary failure; the previously synced positions are kept.
    case failed
    case notChecked
}

@Model
final class BinanceAccountSnapshot {
    var id: UUID = UUID()
    var uid: Int64?
    var accountType: String = ""
    /// Last successful Spot sync.
    var syncedAt: Date = Date()
    var flexibleStatusRaw: String = BinanceEarnStatus.notChecked.rawValue
    var flexibleSyncedAt: Date?
    var lockedStatusRaw: String = BinanceEarnStatus.notChecked.rawValue
    var lockedSyncedAt: Date?
    /// Last time EUR prices were refreshed from Binance market data.
    var pricesFetchedAt: Date?
    /// Spot rows such as "LDETH" left out because Flexible Earn already reports that asset.
    var mergedSpotAssets: String = ""

    init(syncedAt: Date) {
        self.syncedAt = syncedAt
    }

    var flexibleStatus: BinanceEarnStatus { BinanceEarnStatus(rawValue: flexibleStatusRaw) ?? .notChecked }
    var lockedStatus: BinanceEarnStatus { BinanceEarnStatus(rawValue: lockedStatusRaw) ?? .notChecked }
}

/// One balance: a Spot asset, a Flexible Earn product or a Locked Earn position.
@Model
final class BinanceHolding {
    var id: UUID = UUID()
    /// Stable upsert key: "spot:ETH", "flexible:ETH:ETH001", "locked:AXS:123123".
    var key: String = ""
    var asset: String = ""
    var walletRaw: String = BinanceWallet.spot.rawValue
    /// Binance productId (Flexible) or positionId (Locked); empty for Spot.
    var productRef: String = ""
    /// Spot only: available and order-locked parts of `amount`.
    var free: Decimal = 0
    var locked: Decimal = 0
    /// Total quantity of `asset` in this balance (Spot: free + locked).
    var amount: Decimal = 0
    /// Price of 1 unit in EUR; nil when Binance has no validated route to EUR.
    var priceEUR: Decimal?
    /// Market symbols the price came from, e.g. "ETHEUR" or "SOLUSDT → EURUSDT".
    var priceRoute: String = ""
    var pricedAt: Date?
    var syncedAt: Date = Date()

    init(key: String, asset: String, wallet: BinanceWallet, syncedAt: Date) {
        self.key = key
        self.asset = asset
        self.walletRaw = wallet.rawValue
        self.syncedAt = syncedAt
    }

    var wallet: BinanceWallet { BinanceWallet(rawValue: walletRaw) ?? .spot }
}

/// The user's explicit decision that a manual holding or account is already represented by
/// the Binance data, so it must not be counted a second time. The manual record is kept.
@Model
final class BinanceLink {
    var id: UUID = UUID()
    var kindRaw: String = BrokerLink.Kind.holding.rawValue
    var localID: UUID = UUID()
    var createdAt: Date = Date()

    init(kind: BrokerLink.Kind, localID: UUID, createdAt: Date = .now) {
        self.kindRaw = kind.rawValue
        self.localID = localID
        self.createdAt = createdAt
    }

    var kind: BrokerLink.Kind { BrokerLink.Kind(rawValue: kindRaw) ?? .holding }
}
