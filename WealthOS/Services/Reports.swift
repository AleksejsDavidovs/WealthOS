import Foundation

// MARK: - Portfolio performance

nonisolated struct PortfolioPoint: Equatable, Sendable {
    let date: Date
    /// Value of the positions with a known cost basis.
    let costedValue: Decimal
    let costBasis: Decimal
    /// Every position, including those without a cost basis (Binance).
    let totalValue: Decimal
}

nonisolated enum PortfolioRange: String, CaseIterable, Identifiable, Sendable {
    case month = "1M", quarter = "3M", half = "6M", year = "1Y", all = "All"
    var id: String { rawValue }

    func start(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .month: calendar.date(byAdding: .month, value: -1, to: now)
        case .quarter: calendar.date(byAdding: .month, value: -3, to: now)
        case .half: calendar.date(byAdding: .month, value: -6, to: now)
        case .year: calendar.date(byAdding: .year, value: -1, to: now)
        case .all: nil
        }
    }
}

/// How the portfolio did over a period, from daily points. Money added or withdrawn is the change
/// in cost basis, so it is never counted as a gain.
nonisolated struct PortfolioPerformance: Sendable {
    /// The points shown: the last one before the period (as its starting value) and those inside it.
    let points: [PortfolioPoint]
    let startValue: Decimal
    let endValue: Decimal
    /// Net money put in during the period (change in cost basis).
    let contributions: Decimal
    /// Change in value not explained by money put in or taken out.
    let marketGain: Decimal
    /// Time-weighted return for the period (independent of when money was added); nil without
    /// at least two points with a value.
    let timeWeighted: Decimal?
    /// `timeWeighted` per year, only for periods of at least a year.
    let annualized: Decimal?

    init(points all: [PortfolioPoint], from start: Date?, calendar: Calendar = .current) {
        let sorted = all.sorted { $0.date < $1.date }
        var selected = sorted
        if let start {
            let inside = sorted.filter { $0.date >= start }
            let baseline = sorted.last { $0.date < start }
            selected = (baseline.map { [$0] } ?? []) + inside
        }
        points = selected
        let first = selected.first, last = selected.last
        startValue = first?.costedValue ?? 0
        endValue = last?.costedValue ?? 0
        let contributions = (last?.costBasis ?? 0) - (first?.costBasis ?? 0)
        self.contributions = contributions
        marketGain = (endValue - startValue) - contributions

        var factor: Decimal = 1
        var periods = 0
        for (previous, current) in zip(selected, selected.dropFirst()) where previous.costedValue > 0 {
            let flow = current.costBasis - previous.costBasis
            factor *= (current.costedValue - flow) / previous.costedValue
            periods += 1
        }
        let twr: Decimal? = periods > 0 ? factor - 1 : nil
        timeWeighted = twr.map { Money.round($0, scale: 6) }

        if let twr, let first, let last,
           let days = calendar.dateComponents([.day], from: first.date, to: last.date).day, days >= 365 {
            let yearly = pow((1 + twr).doubleValue, 365.0 / Double(days)) - 1
            annualized = Money.round(Decimal(yearly), scale: 6)
        } else {
            annualized = nil
        }
    }

    /// Return on what is invested right now: unrealized plus realized profit over the cost basis.
    static func totalReturn(unrealized: Decimal, realized: Decimal, costBasis: Decimal) -> (amount: Decimal, fraction: Decimal?) {
        let amount = unrealized + realized
        return (amount, costBasis > 0 ? amount / costBasis : nil)
    }
}

// MARK: - Monthly report

nonisolated struct MonthlyReport: Sendable {
    struct CategoryLine: Identifiable, Equatable, Sendable {
        var id: String { categoryID?.uuidString ?? "none" }
        let categoryID: UUID?
        let amount: Decimal
        let previous: Decimal
        /// Relative change against the previous month; nil when it had nothing in this category.
        var change: Decimal? { previous > 0 ? (amount - previous) / previous : nil }
    }

    let month: DateInterval
    /// The month is over (otherwise the report is "so far").
    let isComplete: Bool
    let income: Decimal
    let expenses: Decimal
    let previousIncome: Decimal
    let previousExpenses: Decimal
    /// Average monthly spending over the three months before, counting only months with activity.
    let averageExpenses: Decimal?
    let topCategories: [CategoryLine]
    let biggestExpense: CashFlowEntry?
    let dailySpending: Decimal
    let previousDailySpending: Decimal
    let netWorthStart: Decimal?
    let netWorthEnd: Decimal?
    let investmentsStart: Decimal?
    let investmentsEnd: Decimal?

    var net: Decimal { income - expenses }
    var savingsRate: Decimal? { income > 0 ? net / income : nil }
    var netWorthChange: Decimal? { netWorthStart.flatMap { start in netWorthEnd.map { $0 - start } } }
    var investmentsChange: Decimal? { investmentsStart.flatMap { start in investmentsEnd.map { $0 - start } } }
    var hasActivity: Bool { income > 0 || expenses > 0 }

    static func change(_ current: Decimal, _ previous: Decimal) -> Decimal? { previous > 0 ? (current - previous) / previous : nil }

    /// - Parameters:
    ///   - netWorth / investments: dated values (snapshots), any order.
    init(entries: [CashFlowEntry], month date: Date, netWorth: [(date: Date, value: Decimal)] = [],
         investments: [(date: Date, value: Decimal)] = [], now: Date = .now, calendar: Calendar = .current) {
        let month = calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 86_400 * 30)
        self.month = month
        isComplete = month.end <= now
        func interval(_ offset: Int) -> DateInterval? {
            calendar.date(byAdding: .month, value: offset, to: month.start).flatMap { calendar.dateInterval(of: .month, for: $0) }
        }
        func total(_ kind: TransactionKind, _ interval: DateInterval?) -> Decimal {
            guard let interval else { return 0 }
            return entries.reduce(0) { $1.kind == kind && $1.date >= interval.start && $1.date < interval.end ? $0 + $1.amount : $0 }
        }
        let previous = interval(-1)
        let expenses = total(.expense, month), previousExpenses = total(.expense, previous)
        income = total(.income, month)
        self.expenses = expenses
        previousIncome = total(.income, previous)
        self.previousExpenses = previousExpenses

        let prior = (1...3).compactMap { interval(-$0) }.map { total(.expense, $0) }.filter { $0 > 0 }
        averageExpenses = prior.isEmpty ? nil : Money.round(prior.reduce(0, +) / Decimal(prior.count))

        let inMonth = entries.filter { $0.kind == .expense && $0.date >= month.start && $0.date < month.end }
        let inPrevious = previous.map { p in entries.filter { $0.kind == .expense && $0.date >= p.start && $0.date < p.end } } ?? []
        var current: [UUID?: Decimal] = [:], before: [UUID?: Decimal] = [:]
        for entry in inMonth { current[entry.categoryID, default: 0] += entry.amount }
        for entry in inPrevious { before[entry.categoryID, default: 0] += entry.amount }
        topCategories = current.map { CategoryLine(categoryID: $0.key, amount: $0.value, previous: before[$0.key] ?? 0) }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.id < $1.id }
            .prefix(3).map { $0 }
        biggestExpense = inMonth.max { $0.amount != $1.amount ? $0.amount < $1.amount : $0.date > $1.date }

        func days(in interval: DateInterval) -> Int {
            let end = min(interval.end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now)
            return max(1, calendar.dateComponents([.day], from: interval.start, to: max(end, interval.start)).day ?? 1)
        }
        dailySpending = Money.round(expenses / Decimal(days(in: month)))
        previousDailySpending = previous.map { Money.round(previousExpenses / Decimal(days(in: $0))) } ?? 0

        /// The latest value at or before `moment`; for the start, the first value in the month if none came before.
        func value(_ series: [(date: Date, value: Decimal)], at moment: Date, fallbackFirstInMonth: Bool) -> Decimal? {
            let sorted = series.sorted { $0.date < $1.date }
            if let before = sorted.last(where: { $0.date <= moment }) { return before.value }
            guard fallbackFirstInMonth else { return nil }
            return sorted.first { $0.date >= month.start && $0.date < month.end }?.value
        }
        let endMoment = min(month.end.addingTimeInterval(-1), now)
        let netWorthStart = value(netWorth, at: month.start, fallbackFirstInMonth: true)
        let investmentsStart = value(investments, at: month.start, fallbackFirstInMonth: true)
        self.netWorthStart = netWorthStart
        netWorthEnd = netWorthStart == nil ? nil : value(netWorth, at: endMoment, fallbackFirstInMonth: false)
        self.investmentsStart = investmentsStart
        investmentsEnd = investmentsStart == nil ? nil : value(investments, at: endMoment, fallbackFirstInMonth: false)
    }

    /// The month a report is offered for by default: the last complete month.
    static func defaultMonth(now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: -1, to: now) ?? now
    }
}

// MARK: - Portfolio by source

/// One place the portfolio is held. `invested` is nil when no purchase prices are known (Binance).
nonisolated struct PortfolioSource: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let symbol: String
    /// Market value of everything held there.
    let value: Decimal
    /// What was paid for the positions with a known cost basis.
    let invested: Decimal?
    /// Market value of those same positions (what `invested` compares with).
    let costedValue: Decimal

    var gain: Decimal? { invested.map { costedValue - $0 } }
    var fraction: Decimal? { invested.flatMap { $0 > 0 ? (costedValue - $0) / $0 : nil } }
}

extension FinanceEngine {
    /// Manual holdings, Trading 212 and Binance, each with value and (where known) invested amount.
    var portfolioSources: [PortfolioSource] {
        var sources: [PortfolioSource] = []
        let manual = countedPositions
        let manualCosted = manual.filter { $0.costBasisBase != nil }
        if !manual.isEmpty {
            sources.append(PortfolioSource(
                id: "manual", name: "Manual holdings", symbol: "hand.point.up.left.fill",
                value: manual.compactMap(\.marketValueBase).reduce(0, +),
                invested: manualCosted.isEmpty ? nil : manualCosted.compactMap(\.costBasisBase).reduce(0, +),
                costedValue: manualCosted.compactMap(\.marketValueBase).reduce(0, +)))
        }
        let broker = brokerPositions
        let brokerCosted = broker.filter { $0.costBase != nil }
        if !broker.isEmpty {
            sources.append(PortfolioSource(
                id: "trading212", name: "Trading 212", symbol: "chart.line.uptrend.xyaxis",
                value: broker.compactMap(\.valueBase).reduce(0, +),
                invested: brokerCosted.isEmpty ? nil : brokerCosted.compactMap(\.costBase).reduce(0, +),
                costedValue: brokerCosted.compactMap(\.valueBase).reduce(0, +)))
        }
        if !binanceAssets.isEmpty {
            sources.append(PortfolioSource(id: "binance", name: "Binance", symbol: "bitcoinsign.circle.fill",
                                           value: binanceTotalBase, invested: nil, costedValue: 0))
        }
        return sources
    }
}
