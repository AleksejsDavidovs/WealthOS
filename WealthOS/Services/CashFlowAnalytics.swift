import Foundation

/// One income or expense ledger record in the base currency — the only records cash-flow
/// statistics count. Transfers, balance adjustments (including bank balance corrections and
/// refunds), scheduled (future-dated) records and bank transactions that are still pending or
/// waiting for review are never entries: they are not income or spending.
nonisolated struct CashFlowEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let kind: TransactionKind
    let categoryID: UUID?
    /// Positive, in the base currency.
    let amount: Decimal
}

extension FinanceEngine {
    /// Income and expense records up to today, converted to the base currency. Records whose
    /// currency can't be converted are left out, exactly as in `cashFlow(in:)`.
    func cashFlowEntries() -> [CashFlowEntry] {
        transactions.compactMap { transaction in
            guard transaction.kind == .income || transaction.kind == .expense, transaction.date <= asOfDate,
                  let account = accountsByID[transaction.accountID],
                  let value = converter.toBase(transaction.amount, from: account.currencyCode) else { return nil }
            return CashFlowEntry(id: transaction.id, date: transaction.date, kind: transaction.kind,
                                 categoryID: transaction.categoryID, amount: value)
        }
    }
}

nonisolated enum AnalyticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case week, month, year, all, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .all: "All"
        case .custom: "Custom"
        }
    }

    var component: Calendar.Component? {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .all, .custom: nil
        }
    }

    /// Half-open interval [start, end) the period covers.
    func interval(anchor: Date, customStart: Date, customEnd: Date, earliest: Date?, now: Date = .now,
                  calendar: Calendar = .current) -> DateInterval {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        switch self {
        case .week, .month, .year:
            return calendar.dateInterval(of: component!, for: anchor) ?? DateInterval(start: anchor, duration: 86_400)
        case .all:
            let start = calendar.startOfDay(for: min(earliest ?? now, now))
            return DateInterval(start: start, end: max(tomorrow, start.addingTimeInterval(86_400)))
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(customStart, customEnd)))
                ?? start.addingTimeInterval(86_400)
            return DateInterval(start: start, end: end)
        }
    }

    /// The period just before `interval`, of the same kind and length; nil for "All".
    func previous(of interval: DateInterval, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .week, .month, .year:
            guard let start = calendar.date(byAdding: component!, value: -1, to: interval.start) else { return nil }
            return calendar.dateInterval(of: component!, for: start)
        case .custom:
            let days = calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
            guard days > 0, let start = calendar.date(byAdding: .day, value: -days, to: interval.start) else { return nil }
            return DateInterval(start: start, end: interval.start)
        case .all:
            return nil
        }
    }

    func shifted(_ anchor: Date, by steps: Int, calendar: Calendar = .current) -> Date {
        guard let component else { return anchor }
        return calendar.date(byAdding: component, value: steps, to: anchor) ?? anchor
    }

    /// The analytics period matching a Transactions date filter.
    static func matching(_ range: DateRangeOption) -> AnalyticsPeriod {
        switch range {
        case .all: .all
        case .thisMonth, .lastMonth: .month
        case .thisYear: .year
        case .last3Months, .custom: .custom
        }
    }
}

/// Cash-flow statistics for one period, all in `Decimal`.
nonisolated struct CashFlowAnalytics: Sendable {
    struct CategoryShare: Identifiable, Equatable, Sendable {
        /// Stable identity for charts and selection ("none" for uncategorized).
        var id: String { categoryID?.uuidString ?? "none" }
        let categoryID: UUID?
        let amount: Decimal
        /// Fraction of the period total, 0...1.
        let share: Decimal
        let count: Int
    }

    struct Bucket: Identifiable, Equatable, Sendable {
        var id: Date { date }
        let date: Date
        let amount: Decimal
    }

    enum Granularity: Sendable { case day, month }

    /// Ranges up to this many days chart one bar per day; longer ones one bar per month.
    static let dailyLimit = 92

    let interval: DateInterval
    let kind: TransactionKind
    let income: Decimal
    let expenses: Decimal
    /// Total of `kind` in the period.
    let total: Decimal
    let count: Int
    /// Largest first.
    let categories: [CategoryShare]
    let granularity: Granularity
    /// Every day (or month) of the period up to today, including empty ones.
    let buckets: [Bucket]
    /// Days of the period that have started (at least 1).
    let elapsedDays: Int
    /// `total` spread over the elapsed days, rounded to cents.
    let averageDaily: Decimal

    var net: Decimal { income - expenses }

    init(entries: [CashFlowEntry], interval: DateInterval, kind: TransactionKind, now: Date = .now,
         calendar: Calendar = .current) {
        self.interval = interval
        self.kind = kind
        let inPeriod = entries.filter { $0.date >= interval.start && $0.date < interval.end }
        income = inPeriod.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }
        expenses = inPeriod.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }
        let selected = inPeriod.filter { $0.kind == kind }
        let total = selected.reduce(Decimal(0)) { $0 + $1.amount }
        self.total = total
        count = selected.count

        var byCategory: [UUID?: (amount: Decimal, count: Int)] = [:]
        for entry in selected {
            byCategory[entry.categoryID, default: (0, 0)].amount += entry.amount
            byCategory[entry.categoryID, default: (0, 0)].count += 1
        }
        categories = byCategory.map { id, value in
            CategoryShare(categoryID: id, amount: value.amount, share: total > 0 ? value.amount / total : 0, count: value.count)
        }
        .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.id < $1.id }

        let start = calendar.startOfDay(for: interval.start)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let visibleEnd = max(min(interval.end, tomorrow), start.addingTimeInterval(1))
        let endDay = calendar.startOfDay(for: visibleEnd)
        var started = calendar.dateComponents([.day], from: start, to: endDay).day ?? 0
        if endDay < visibleEnd { started += 1 }  // a partial last day still counts
        let days = max(1, started)
        elapsedDays = days
        averageDaily = Money.round(total / Decimal(days))

        let totalDays = calendar.dateComponents([.day], from: start, to: interval.end).day ?? 0
        let granularity: Granularity = totalDays <= Self.dailyLimit ? .day : .month
        self.granularity = granularity
        let component: Calendar.Component = granularity == .day ? .day : .month
        var sums: [Date: Decimal] = [:]
        for entry in selected {
            let key = calendar.dateInterval(of: component, for: entry.date)?.start ?? calendar.startOfDay(for: entry.date)
            sums[key, default: 0] += entry.amount
        }
        var buckets: [Bucket] = []
        var cursor = calendar.dateInterval(of: component, for: start)?.start ?? start
        while cursor < visibleEnd, buckets.count < 5_000 {
            buckets.append(Bucket(date: cursor, amount: sums[cursor] ?? 0))
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        self.buckets = buckets
    }

    /// Relative change from `previous` to `current`; nil when there is nothing to compare with.
    static func change(current: Decimal, previous: Decimal) -> Decimal? {
        previous > 0 ? (current - previous) / previous : nil
    }
}
