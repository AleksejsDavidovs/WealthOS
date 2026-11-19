import Foundation
import SwiftData

// Read-only account history from Trading 212: executed orders (fills) and cash movements.
// Like dividends, these are informational — balances come from the live snapshot.

/// The paginated history feeds WealthOS reads.
nonisolated enum Trading212HistoryKind: String, CaseIterable, Sendable {
    case dividends, orders, transactions

    var title: String {
        switch self {
        case .dividends: "dividends"
        case .orders: "trade history"
        case .transactions: "deposits and withdrawals"
        }
    }

    /// The API key permission (scope) the feed needs.
    var scope: String { "history:\(rawValue)" }
}

// MARK: - Parsing

nonisolated struct ParsedOrder: Sendable, Equatable {
    var key: String
    var ticker: String
    var name: String
    var side: String
    var quantity: Decimal
    var price: Decimal?
    var instrumentCurrency: String
    var netValue: Decimal
    var fees: Decimal
    var realized: Decimal
    var currencyCode: String
    var filledAt: Date
}

nonisolated struct ParsedCashTransaction: Sendable, Equatable {
    var key: String
    var type: String
    var amount: Decimal
    var currencyCode: String
    var date: Date
}

nonisolated enum Trading212HistoryParsing {
    /// Only executed fills count; cancelled/rejected orders have no fill and are skipped.
    static func orders(_ items: [T212HistoricalOrder]) -> [ParsedOrder] {
        var seen: Set<String> = []
        return items.compactMap { item in
            guard let fill = item.fill, let filledText = fill.filledAt, let filledAt = Trading212Parsing.parseDate(filledText),
                  let quantity = fill.quantity ?? item.order?.filledQuantity, quantity != 0,
                  let side = item.order?.side?.uppercased(), side == "BUY" || side == "SELL" else { return nil }
            let key = fill.id.map { "fill:\($0)" } ?? item.order?.id.map { "order:\($0)" }
                ?? "derived:\(item.order?.ticker ?? ""):\(Int(filledAt.timeIntervalSince1970)):\(quantity)"
            guard seen.insert(key).inserted else { return nil }
            let impact = fill.walletImpact
            let currency = (impact?.currency ?? item.order?.currency ?? "").uppercased()
            let fees = (impact?.taxes ?? []).reduce(Decimal(0)) { sum, tax in
                guard let amount = tax.quantity, (tax.currency ?? currency).uppercased() == currency else { return sum }
                return sum + abs(amount)
            }
            let price = fill.price
            let net = impact?.netValue.map(abs) ?? (price.map { abs($0 * quantity) } ?? 0)
            let ticker = (item.order?.ticker ?? item.order?.instrument?.ticker ?? "").trimmingCharacters(in: .whitespaces)
            return ParsedOrder(key: key, ticker: ticker, name: item.order?.instrument?.name ?? "", side: side,
                               quantity: Money.round(abs(quantity), scale: 8), price: price.map { Money.round($0, scale: 6) },
                               instrumentCurrency: item.order?.instrument?.currency ?? "",
                               netValue: Money.round(net), fees: Money.round(fees),
                               realized: Money.round(impact?.realisedProfitLoss ?? 0),
                               currencyCode: currency, filledAt: filledAt)
        }
    }

    /// Money in is positive, out is negative — whatever sign the provider uses.
    static func signedAmount(type: String, amount: Decimal) -> Decimal {
        switch type.uppercased() {
        case "DEPOSIT", "INTEREST_ON_FREE_CASH", "LENDING_INTEREST": abs(amount)
        case "WITHDRAW", "FEE": -abs(amount)
        default: amount
        }
    }

    static func transactions(_ items: [T212Transaction]) -> [ParsedCashTransaction] {
        var seen: Set<String> = []
        return items.compactMap { item in
            guard let amount = item.amount, let text = item.dateTime, let date = Trading212Parsing.parseDate(text),
                  let type = item.type?.uppercased(), !type.isEmpty else { return nil }
            let reference = item.reference?.trimmingCharacters(in: .whitespaces) ?? ""
            let key = reference.isEmpty ? "derived:\(type):\(Int(date.timeIntervalSince1970)):\(amount)" : "ref:\(reference)"
            guard seen.insert(key).inserted else { return nil }
            return ParsedCashTransaction(key: key, type: type, amount: Money.round(signedAmount(type: type, amount: amount)),
                                         currencyCode: (item.currency ?? "").uppercased(), date: date)
        }
    }
}

// MARK: - Storage

enum Trading212HistoryReconciler {
    static func apply(orders: [ParsedOrder], now: Date, in context: ModelContext) throws {
        let existing = Dictionary(try context.fetch(FetchDescriptor<BrokerOrder>()).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for item in orders {
            let row = existing[item.key] ?? {
                let row = BrokerOrder(key: item.key, syncedAt: now)
                context.insert(row)
                return row
            }()
            row.ticker = item.ticker
            if !item.name.isEmpty || row.name.isEmpty { row.name = item.name }
            row.side = item.side
            row.quantity = item.quantity
            row.price = item.price
            row.instrumentCurrency = item.instrumentCurrency
            row.netValue = item.netValue
            row.fees = item.fees
            row.realized = item.realized
            row.currencyCode = item.currencyCode
            row.filledAt = item.filledAt
            row.syncedAt = now
        }
    }

    static func apply(transactions: [ParsedCashTransaction], now: Date, in context: ModelContext) throws {
        let existing = Dictionary(try context.fetch(FetchDescriptor<BrokerCashTransaction>()).map { ($0.key, $0) },
                                  uniquingKeysWith: { a, _ in a })
        for item in transactions {
            let row = existing[item.key] ?? {
                let row = BrokerCashTransaction(key: item.key, syncedAt: now)
                context.insert(row)
                return row
            }()
            row.type = item.type
            row.amount = item.amount
            row.currencyCode = item.currencyCode
            row.date = item.date
            row.syncedAt = now
        }
    }
}
