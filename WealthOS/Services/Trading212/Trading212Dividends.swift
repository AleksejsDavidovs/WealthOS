import Foundation
import SwiftData

// MARK: - Parsing

nonisolated struct ParsedDividend: Sendable, Equatable {
    var key: String
    var ticker: String
    var name: String
    var amount: Decimal
    var currencyCode: String
    var paidOn: Date
    var quantity: Decimal?
    var grossPerShare: Decimal?
    var instrumentCurrency: String
    var type: String
}

nonisolated enum Trading212DividendParsing {
    /// Dividends are informational (the cash is already in the balance), so a malformed row is
    /// skipped instead of failing the sync. Amounts are rounded: JSON numbers pass through Double.
    static func parse(_ items: [T212Dividend]) -> [ParsedDividend] {
        var seen: Set<String> = []
        return items.compactMap { item in
            guard let amount = item.amount, let paidText = item.paidOn,
                  let paidOn = Trading212Parsing.parseDate(paidText) else { return nil }
            let ticker = (item.ticker ?? item.instrument?.ticker ?? "").trimmingCharacters(in: .whitespaces)
            let rounded = Money.round(amount)
            let reference = item.reference?.trimmingCharacters(in: .whitespaces) ?? ""
            let key = reference.isEmpty
                ? "derived:\(ticker):\(Int(paidOn.timeIntervalSince1970)):\(rounded)"
                : "ref:\(reference)"
            guard seen.insert(key).inserted else { return nil }
            return ParsedDividend(key: key, ticker: ticker,
                                  name: item.instrument?.name ?? "",
                                  amount: rounded,
                                  currencyCode: item.currency ?? "",
                                  paidOn: paidOn,
                                  quantity: item.quantity.map { Money.round($0, scale: 8) },
                                  grossPerShare: item.grossAmountPerShare.map { Money.round($0, scale: 6) },
                                  instrumentCurrency: item.tickerCurrency ?? item.instrument?.currency ?? "",
                                  type: item.type ?? "")
        }
    }
}

// MARK: - Storage

enum Trading212DividendReconciler {
    /// Inserts new payouts and refreshes known ones (same provider key). Never deletes:
    /// older pages that weren't re-downloaded stay as they are.
    static func apply(_ dividends: [ParsedDividend], now: Date, in context: ModelContext) throws {
        let existing = Dictionary(try context.fetch(FetchDescriptor<BrokerDividend>()).map { ($0.key, $0) },
                                  uniquingKeysWith: { a, _ in a })
        for item in dividends {
            let row = existing[item.key] ?? {
                let row = BrokerDividend(key: item.key, syncedAt: now)
                context.insert(row)
                return row
            }()
            row.ticker = item.ticker
            if !item.name.isEmpty || row.name.isEmpty { row.name = item.name }
            row.amount = item.amount
            row.currencyCode = item.currencyCode
            row.paidOn = item.paidOn
            row.quantity = item.quantity
            row.grossPerShare = item.grossPerShare
            row.instrumentCurrency = item.instrumentCurrency
            row.type = item.type
            row.syncedAt = now
        }
    }
}

// MARK: - Totals

nonisolated struct DividendPayment: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    /// In the base currency.
    let amount: Decimal
    let ticker: String
    let name: String
}

nonisolated struct DividendHolding: Identifiable, Equatable, Sendable {
    var id: String { ticker }
    let ticker: String
    let name: String
    let total: Decimal
    let count: Int
}

nonisolated struct DividendMonth: Identifiable, Equatable, Sendable {
    var id: Date { month }
    let month: Date
    let total: Decimal
}

nonisolated enum DividendStats {
    /// Payouts in the base currency, newest first. Currencies without a rate are left out and reported.
    static func payments(_ rows: [(key: String, date: Date, amount: Decimal, currency: String, ticker: String, name: String)],
                         converter: CurrencyConverter) -> (payments: [DividendPayment], missingRates: Set<String>) {
        var missing: Set<String> = []
        let payments = rows.compactMap { row -> DividendPayment? in
            guard let value = converter.toBase(row.amount, from: row.currency.isEmpty ? converter.baseCode : row.currency) else {
                missing.insert(row.currency)
                return nil
            }
            return DividendPayment(id: row.key, date: row.date, amount: value, ticker: row.ticker,
                                   name: row.name.isEmpty ? Trading212Matching.baseSymbol(ofTicker: row.ticker) : row.name)
        }
        return (payments.sorted { $0.date > $1.date }, missing)
    }

    static func total(_ payments: [DividendPayment], in interval: DateInterval) -> Decimal {
        Money.round(payments.reduce(Decimal(0)) { $0 + (interval.contains($1.date) && $1.date < interval.end ? $1.amount : 0) })
    }

    static func thisMonth(_ payments: [DividendPayment], now: Date = .now, calendar: Calendar = .current) -> Decimal {
        calendar.dateInterval(of: .month, for: now).map { total(payments, in: $0) } ?? 0
    }

    static func thisYear(_ payments: [DividendPayment], now: Date = .now, calendar: Calendar = .current) -> Decimal {
        calendar.dateInterval(of: .year, for: now).map { total(payments, in: $0) } ?? 0
    }

    /// The last `count` calendar months including the current one, oldest first (empty months = 0).
    static func monthly(_ payments: [DividendPayment], months count: Int = 12, now: Date = .now,
                        calendar: Calendar = .current) -> [DividendMonth] {
        guard let current = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        return (0..<count).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .month, value: -back, to: current),
                  let interval = calendar.dateInterval(of: .month, for: start) else { return nil }
            return DividendMonth(month: start, total: total(payments, in: interval))
        }
    }

    /// Sum of the last 12 calendar months including the current one.
    static func last12Months(_ payments: [DividendPayment], now: Date = .now, calendar: Calendar = .current) -> Decimal {
        monthly(payments, months: 12, now: now, calendar: calendar).reduce(0) { $0 + $1.total }
    }

    /// Per holding in the interval, largest first.
    static func byHolding(_ payments: [DividendPayment], in interval: DateInterval) -> [DividendHolding] {
        var groups: [String: (name: String, total: Decimal, count: Int)] = [:]
        for payment in payments where interval.contains(payment.date) && payment.date < interval.end {
            let key = payment.ticker.isEmpty ? payment.name : payment.ticker
            var group = groups[key] ?? (payment.name, 0, 0)
            group.total += payment.amount
            group.count += 1
            groups[key] = group
        }
        return groups.map { DividendHolding(ticker: $0.key, name: $0.value.name, total: Money.round($0.value.total), count: $0.value.count) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
    }
}
