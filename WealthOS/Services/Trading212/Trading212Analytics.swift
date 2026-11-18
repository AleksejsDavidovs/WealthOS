import Foundation

/// Account-level analytics for Trading 212 from its history (trades, cash movements, dividends)
/// and the live snapshot. Everything is in the account currency; rows in another currency are
/// left out and counted. Pure value type — no SwiftData — so every figure is unit tested.
nonisolated struct Trading212Analytics: Sendable {
    struct Trade: Sendable, Equatable, Identifiable {
        let id: String
        let date: Date
        let ticker: String
        let name: String
        let isBuy: Bool
        let quantity: Decimal
        let price: Decimal?
        let instrumentCurrency: String
        /// Positive cash moved, account currency.
        let netValue: Decimal
        let fees: Decimal
        let realized: Decimal
    }
    struct Cash: Sendable, Equatable, Identifiable {
        let id: String
        let date: Date
        let type: String
        /// Signed: into the account positive.
        let amount: Decimal
    }
    struct Dividend: Sendable, Equatable {
        let date: Date
        let ticker: String
        let name: String
        let amount: Decimal
    }
    struct Position: Sendable, Equatable {
        let ticker: String
        let name: String
        let value: Decimal
        let cost: Decimal?
        let unrealized: Decimal?
    }
    struct ValuePoint: Sendable, Equatable {
        let date: Date
        let value: Decimal
    }

    struct TimelinePoint: Sendable, Equatable, Identifiable {
        var id: Date { date }
        let date: Date
        /// Cumulative deposits − withdrawals (incl. transfers).
        let deposited: Decimal
        /// Cost of the shares held at that moment.
        let atCost: Decimal
    }

    struct Instrument: Sendable, Equatable, Identifiable {
        var id: String { ticker }
        let ticker: String
        let name: String
        let bought: Decimal
        let sold: Decimal
        let realized: Decimal
        let dividends: Decimal
        let fees: Decimal
        let trades: Int
        /// nil when the position is closed (fully sold).
        let value: Decimal?
        let cost: Decimal?
        let unrealized: Decimal?

        var isOpen: Bool { value != nil }
        /// Price gain (open) + realized + dividends.
        var totalReturn: Decimal { (unrealized ?? 0) + realized + dividends }
        /// Against the current cost of an open position, or everything bought for a closed one.
        var returnFraction: Decimal? {
            let invested = isOpen ? (cost ?? bought) : bought
            return invested > 0 ? totalReturn / invested : nil
        }
    }

    struct PeriodTotals: Sendable, Equatable {
        var deposited: Decimal = 0
        var withdrawn: Decimal = 0
        var bought: Decimal = 0
        var sold: Decimal = 0
        var realized: Decimal = 0
        var dividends: Decimal = 0
        var interest: Decimal = 0
        var fees: Decimal = 0
        var trades = 0
    }

    struct MonthFlow: Sendable, Equatable, Identifiable {
        var id: Date { month }
        let month: Date
        let deposited: Decimal
        let withdrawn: Decimal
        var net: Decimal { deposited - withdrawn }
    }

    let currency: String
    let trades: [Trade]
    let cash: [Cash]
    let dividendRows: [Dividend]
    let positions: [Position]
    let cashBalance: Decimal
    let valuePoints: [ValuePoint]
    let now: Date

    init(currency: String, trades: [Trade], cash: [Cash], dividends: [Dividend], positions: [Position],
         cashBalance: Decimal, valuePoints: [ValuePoint], now: Date = .now) {
        self.currency = currency
        self.trades = trades.sorted { $0.date > $1.date }
        self.cash = cash.sorted { $0.date > $1.date }
        self.dividendRows = dividends.sorted { $0.date > $1.date }
        self.positions = positions
        self.cashBalance = cashBalance
        self.valuePoints = valuePoints.sorted { $0.date < $1.date }
        self.now = now
    }

    var hasHistory: Bool { !trades.isEmpty || !cash.isEmpty }

    // MARK: Totals

    static func isExternalFlow(_ type: String) -> Bool { ["DEPOSIT", "WITHDRAW", "TRANSFER"].contains(type.uppercased()) }
    static func isInterest(_ type: String) -> Bool { ["INTEREST_ON_FREE_CASH", "LENDING_INTEREST"].contains(type.uppercased()) }

    var deposited: Decimal { cash.filter { Self.isExternalFlow($0.type) && $0.amount > 0 }.reduce(0) { $0 + $1.amount } }
    var withdrawn: Decimal { cash.filter { Self.isExternalFlow($0.type) && $0.amount < 0 }.reduce(0) { $0 - $1.amount } }
    var netDeposits: Decimal { deposited - withdrawn }
    var interest: Decimal { cash.filter { Self.isInterest($0.type) }.reduce(0) { $0 + $1.amount } }
    var cashFees: Decimal { cash.filter { $0.type.uppercased() == "FEE" }.reduce(0) { $0 - $1.amount } }
    var tradeFees: Decimal { trades.reduce(0) { $0 + $1.fees } }
    var fees: Decimal { cashFees + tradeFees }
    var dividends: Decimal { dividendRows.reduce(0) { $0 + $1.amount } }
    var realized: Decimal { trades.reduce(0) { $0 + $1.realized } }
    var unrealized: Decimal { positions.reduce(0) { $0 + ($1.unrealized ?? 0) } }
    var positionsValue: Decimal { positions.reduce(0) { $0 + $1.value } }
    var currentValue: Decimal { Money.round(cashBalance + positionsValue) }
    var bought: Decimal { trades.filter(\.isBuy).reduce(0) { $0 + $1.netValue } }
    var sold: Decimal { trades.filter { !$0.isBuy }.reduce(0) { $0 + $1.netValue } }

    /// What the account is worth beyond the money put in.
    var totalGain: Decimal { Money.round(currentValue - netDeposits) }
    var gainFraction: Decimal? { netDeposits > 0 ? totalGain / netDeposits : nil }

    /// The parts that explain `totalGain`; "other" is the rest (FX on cash, rounding, history
    /// older than what the API returned).
    var explainedGain: Decimal { unrealized + realized + dividends + interest - fees }
    var otherGain: Decimal { Money.round(totalGain - explainedGain) }

    var firstActivity: Date? { (trades.map(\.date) + cash.map(\.date)).min() }

    // MARK: Money-weighted return

    /// Annualized money-weighted return (XIRR) of deposits/withdrawals against today's value.
    /// nil with less than 30 days of history or when no rate fits.
    var moneyWeightedReturn: Double? {
        let flows = cash.filter { Self.isExternalFlow($0.type) }.map { (date: $0.date, amount: -$0.amount.doubleValue) }
            + [(date: now, amount: currentValue.doubleValue)]
        guard let first = flows.map(\.date).min(), now.timeIntervalSince(first) >= 30 * 86_400,
              flows.contains(where: { $0.amount < 0 }) else { return nil }
        return Self.xirr(flows, now: now)
    }

    static func xirr(_ flows: [(date: Date, amount: Double)], now: Date) -> Double? {
        func npv(_ rate: Double) -> Double {
            flows.reduce(0) { sum, flow in
                let years = now.timeIntervalSince(flow.date) / (365.25 * 86_400)
                // Discount to today: value of each flow grown to `now`.
                return sum + flow.amount * pow(1 + rate, years)
            }
        }
        var low = -0.99, high = 10.0
        var fLow = npv(low), fHigh = npv(high)
        guard fLow.isFinite, fHigh.isFinite, fLow.sign != fHigh.sign else { return nil }
        for _ in 0..<200 {
            let mid = (low + high) / 2
            let fMid = npv(mid)
            if abs(fMid) < 1e-7 || high - low < 1e-9 { return mid }
            if fMid.sign == fLow.sign { low = mid; fLow = fMid } else { high = mid; fHigh = fMid }
        }
        return (low + high) / 2
    }

    // MARK: Periods

    func totals(in interval: DateInterval) -> PeriodTotals {
        func inside(_ date: Date) -> Bool { date >= interval.start && date < interval.end }
        var totals = PeriodTotals()
        for row in cash where inside(row.date) {
            if Self.isExternalFlow(row.type) {
                if row.amount > 0 { totals.deposited += row.amount } else { totals.withdrawn -= row.amount }
            } else if Self.isInterest(row.type) {
                totals.interest += row.amount
            } else if row.type.uppercased() == "FEE" {
                totals.fees -= row.amount
            }
        }
        for trade in trades where inside(trade.date) {
            if trade.isBuy { totals.bought += trade.netValue } else { totals.sold += trade.netValue }
            totals.realized += trade.realized
            totals.fees += trade.fees
            totals.trades += 1
        }
        for dividend in dividendRows where inside(dividend.date) { totals.dividends += dividend.amount }
        return totals
    }

    /// Deposits and withdrawals per calendar month, oldest first, ending with the current month.
    func monthlyFlows(months count: Int = 12, calendar: Calendar = .current) -> [MonthFlow] {
        guard let current = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        return (0..<count).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .month, value: -back, to: current),
                  let interval = calendar.dateInterval(of: .month, for: start) else { return nil }
            let totals = totals(in: interval)
            return MonthFlow(month: start, deposited: totals.deposited, withdrawn: totals.withdrawn)
        }
    }

    // MARK: Timeline

    /// Step series over the whole history: money deposited and the cost of shares held,
    /// recomputed after every event, plus a final point today.
    var timeline: [TimelinePoint] {
        enum Event { case cash(Cash), trade(Trade) }
        let events: [(Date, Event)] = (cash.filter { Self.isExternalFlow($0.type) }.map { ($0.date, Event.cash($0)) }
            + trades.map { ($0.date, Event.trade($0)) }).sorted { $0.0 < $1.0 }
        var deposited: Decimal = 0, atCost: Decimal = 0
        var points: [TimelinePoint] = []
        for (date, event) in events {
            switch event {
            case .cash(let row): deposited += row.amount
            case .trade(let trade):
                // A sale removes what the sold shares cost: proceeds minus the realized result.
                atCost += trade.isBuy ? trade.netValue : -(trade.netValue - trade.realized)
                atCost = max(0, atCost)
            }
            if let last = points.last, last.date == date { points.removeLast() }
            points.append(TimelinePoint(date: date, deposited: Money.round(deposited), atCost: Money.round(atCost)))
        }
        if let last = points.last, last.date < now {
            points.append(TimelinePoint(date: now, deposited: last.deposited, atCost: last.atCost))
        }
        return points
    }

    // MARK: Instruments

    /// Every instrument ever traded or held, open ones first, then by total return.
    var instruments: [Instrument] {
        var tickers = Set(trades.map(\.ticker)).union(positions.map(\.ticker)).union(dividendRows.map(\.ticker))
        tickers.remove("")
        let positionsByTicker = Dictionary(positions.map { ($0.ticker, $0) }, uniquingKeysWith: { a, _ in a })
        return tickers.map { ticker in
            let rows = trades.filter { $0.ticker == ticker }
            let position = positionsByTicker[ticker]
            let name = position?.name.nonEmpty ?? rows.first(where: { !$0.name.isEmpty })?.name
                ?? dividendRows.first(where: { $0.ticker == ticker && !$0.name.isEmpty })?.name
                ?? Trading212Matching.baseSymbol(ofTicker: ticker)
            return Instrument(ticker: ticker, name: name,
                              bought: Money.round(rows.filter(\.isBuy).reduce(0) { $0 + $1.netValue }),
                              sold: Money.round(rows.filter { !$0.isBuy }.reduce(0) { $0 + $1.netValue }),
                              realized: Money.round(rows.reduce(0) { $0 + $1.realized }),
                              dividends: Money.round(dividendRows.filter { $0.ticker == ticker }.reduce(0) { $0 + $1.amount }),
                              fees: Money.round(rows.reduce(0) { $0 + $1.fees }),
                              trades: rows.count,
                              value: position?.value, cost: position?.cost, unrealized: position?.unrealized)
        }
        .sorted { a, b in
            if a.isOpen != b.isOpen { return a.isOpen }
            if a.isOpen { return (a.value ?? 0) > (b.value ?? 0) }
            return a.totalReturn > b.totalReturn
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
