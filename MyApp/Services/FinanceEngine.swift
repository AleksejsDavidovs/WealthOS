import Foundation

nonisolated struct NetWorthSummary: Equatable, Sendable {
    /// Cash, bank and savings accounts.
    var liquid: Decimal = 0
    /// Cash or manually tracked value held in investment / crypto accounts.
    var investmentAccounts: Decimal = 0
    /// Market value of tracked holdings (quantity × manual price).
    var holdingsValue: Decimal = 0
    var otherAssets: Decimal = 0
    /// Amount owed, as a positive number.
    var liabilities: Decimal = 0
    /// Currencies that could not be converted because no exchange rate was entered.
    var missingRateCurrencies: Set<String> = []

    var investments: Decimal { investmentAccounts + holdingsValue }
    var totalAssets: Decimal { liquid + investments + otherAssets }
    var netWorth: Decimal { totalAssets - liabilities }
}

nonisolated struct CashFlowSummary: Equatable, Sendable {
    var income: Decimal = 0
    var expenses: Decimal = 0
    var savings: Decimal { income - expenses }
    var savingsRate: Decimal? { income > 0 ? savings / income : nil }
}

struct PositionSummary: Identifiable {
    let holding: Holding
    let position: PositionResult
    /// quantity × current price, in the holding's currency.
    let marketValue: Decimal
    let marketValueBase: Decimal?
    let costBasisBase: Decimal?
    let realizedBase: Decimal?
    let error: String?

    var id: UUID { holding.id }
    var unrealizedProfit: Decimal { marketValue - position.costBasis }
    var unrealizedProfitBase: Decimal? {
        guard let marketValueBase, let costBasisBase else { return nil }
        return marketValueBase - costBasisBase
    }
    var returnFraction: Decimal? {
        position.costBasis > 0 ? unrealizedProfit / position.costBasis : nil
    }
}

/// Computes balances, net worth and cash-flow statistics from persisted records.
///
/// Accounting rules:
/// - Account balance = opening balance + income − expenses ± transfers ± adjustments ± trade cash flows.
/// - Transfers move money between own accounts and are excluded from income/expenses.
/// - Investment trades move value between a cash account and a holding; they are never expenses.
/// - Net worth = Σ account balances (liabilities are negative) + Σ holding market values.
///   Goal allocations are earmarks of these assets and are never added.
struct FinanceEngine {
    let accounts: [Account]
    let transactions: [TransactionRecord]
    let holdings: [Holding]
    let trades: [InvestmentTrade]
    let converter: CurrencyConverter

    let balances: [UUID: Decimal]
    let accountsByID: [UUID: Account]
    let positions: [PositionSummary]
    let summary: NetWorthSummary
    /// End of the current day; later-dated records are scheduled, not yet actual.
    let asOfDate: Date
    /// Future-dated transactions and trades, excluded from balances until their date.
    let scheduledCount: Int

    /// - Parameter now: Transactions dated after the end of this day are "scheduled" and
    ///   do not affect current balances until their date arrives.
    init(accounts: [Account], transactions: [TransactionRecord], holdings: [Holding],
         trades: [InvestmentTrade], converter: CurrencyConverter, now: Date = .now, calendar: Calendar = .current) {
        self.accounts = accounts
        self.transactions = transactions
        self.holdings = holdings
        self.trades = trades
        self.converter = converter
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.accountsByID = byID
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))?.addingTimeInterval(-1) ?? now
        self.asOfDate = endOfToday
        self.scheduledCount = transactions.lazy.filter { $0.date > endOfToday }.count
            + trades.lazy.filter { $0.date > endOfToday }.count
        let balances = Self.computeBalances(accounts: accounts, transactions: transactions, trades: trades, asOf: endOfToday)
        self.balances = balances
        let positions = Self.computePositions(holdings: holdings, trades: trades, converter: converter)
        self.positions = positions
        self.summary = Self.computeSummary(accounts: accounts, balances: balances, positions: positions, converter: converter)
    }

    // MARK: Balances

    static func computeBalances(accounts: [Account], transactions: [TransactionRecord], trades: [InvestmentTrade],
                                asOf date: Date? = nil) -> [UUID: Decimal] {
        var balances: [UUID: Decimal] = [:]
        for account in accounts { balances[account.id] = account.openingBalance }

        func apply(_ id: UUID?, _ delta: Decimal) {
            guard let id, balances[id] != nil else { return }
            balances[id, default: 0] += delta
        }

        for transaction in transactions {
            if let date, transaction.date > date { continue }
            switch transaction.kind {
            case .income:
                apply(transaction.accountID, transaction.amount)
            case .expense:
                apply(transaction.accountID, -transaction.amount)
            case .transfer:
                apply(transaction.accountID, -transaction.amount)
                apply(transaction.destinationAccountID, transaction.destinationAmount ?? transaction.amount)
            case .adjustment:
                apply(transaction.accountID, transaction.amount)
            }
        }
        for trade in trades {
            if let date, trade.date > date { continue }
            guard let cashAmount = trade.cashAmount else { continue }
            apply(trade.cashAccountID, trade.kind == .buy ? -cashAmount : cashAmount)
        }
        return balances
    }

    func balance(of account: Account) -> Decimal { balances[account.id] ?? account.openingBalance }

    func balanceInBase(of account: Account) -> Decimal? {
        converter.toBase(balance(of: account), from: account.currencyCode)
    }

    // MARK: Investments

    static func computePositions(holdings: [Holding], trades: [InvestmentTrade], converter: CurrencyConverter) -> [PositionSummary] {
        let grouped = Dictionary(grouping: trades, by: \.holdingID)
        return holdings.map { holding in
            let inputs = (grouped[holding.id] ?? []).map {
                TradeInput(kind: $0.kind, date: $0.date, quantity: $0.quantity, price: $0.pricePerUnit, fee: $0.fee, createdAt: $0.createdAt)
            }
            var position = PositionResult()
            var errorMessage: String?
            do {
                position = try InvestmentCalculator.position(for: inputs)
            } catch {
                errorMessage = error.localizedDescription
            }
            let marketValue = position.quantity * holding.currentPrice
            return PositionSummary(holding: holding, position: position, marketValue: marketValue,
                                   marketValueBase: converter.toBase(marketValue, from: holding.currencyCode),
                                   costBasisBase: converter.toBase(position.costBasis, from: holding.currencyCode),
                                   realizedBase: converter.toBase(position.realizedProfit, from: holding.currencyCode),
                                   error: errorMessage)
        }
    }

    func position(for holding: Holding) -> PositionSummary? {
        positions.first { $0.holding.id == holding.id }
    }

    var portfolioCostBasis: Decimal { positions.compactMap(\.costBasisBase).reduce(0, +) }
    var portfolioMarketValue: Decimal { positions.compactMap(\.marketValueBase).reduce(0, +) }
    var portfolioRealized: Decimal { positions.compactMap(\.realizedBase).reduce(0, +) }

    /// Market value by asset class in base currency (holdings only).
    var allocation: [(assetClass: AssetClass, value: Decimal)] {
        var totals: [AssetClass: Decimal] = [:]
        for position in positions {
            guard let value = position.marketValueBase, value > 0 else { continue }
            totals[position.holding.assetClass, default: 0] += value
        }
        return AssetClass.allCases.compactMap { cls in totals[cls].map { (cls, $0) } }
    }

    // MARK: Net worth

    static func computeSummary(accounts: [Account], balances: [UUID: Decimal], positions: [PositionSummary],
                               converter: CurrencyConverter) -> NetWorthSummary {
        var summary = NetWorthSummary()
        for account in accounts {
            let balance = balances[account.id] ?? account.openingBalance
            guard let value = converter.toBase(balance, from: account.currencyCode) else {
                if balance != 0 { summary.missingRateCurrencies.insert(account.currencyCode) }
                continue
            }
            switch account.kind.group {
            case .liquid: summary.liquid += value
            case .investments: summary.investmentAccounts += value
            case .otherAssets: summary.otherAssets += value
            case .liabilities: summary.liabilities -= value
            }
        }
        for position in positions {
            if let value = position.marketValueBase {
                summary.holdingsValue += value
            } else if position.marketValue != 0 {
                summary.missingRateCurrencies.insert(position.holding.currencyCode)
            }
        }
        return summary
    }

    // MARK: Cash flow

    func cashFlow(in interval: DateInterval) -> CashFlowSummary {
        var flow = CashFlowSummary()
        for transaction in transactions where transaction.date >= interval.start && transaction.date < interval.end
            && transaction.date <= asOfDate {
            guard transaction.kind == .income || transaction.kind == .expense,
                  let account = accountsByID[transaction.accountID],
                  let value = converter.toBase(transaction.amount, from: account.currencyCode) else { continue }
            if transaction.kind == .income { flow.income += value } else { flow.expenses += value }
        }
        return flow
    }

    func cashFlow(forMonthContaining date: Date, calendar: Calendar = .current) -> CashFlowSummary {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return CashFlowSummary() }
        return cashFlow(in: interval)
    }

    /// Totals per category (nil key = uncategorized) for income or expense transactions.
    func categoryTotals(kind: TransactionKind, in interval: DateInterval) -> [UUID?: Decimal] {
        var totals: [UUID?: Decimal] = [:]
        for transaction in transactions where transaction.kind == kind && transaction.date >= interval.start
            && transaction.date < interval.end && transaction.date <= asOfDate {
            guard let account = accountsByID[transaction.accountID],
                  let value = converter.toBase(transaction.amount, from: account.currencyCode) else { continue }
            totals[transaction.categoryID, default: 0] += value
        }
        return totals
    }

    /// Average monthly income and expenses over the last `months` complete calendar months
    /// that contain any income/expense records. Returns nil without history.
    func averageMonthlyFlow(months: Int = 3, now: Date = .now, calendar: Calendar = .current) -> CashFlowSummary? {
        guard let currentMonth = calendar.dateInterval(of: .month, for: now) else { return nil }
        var total = CashFlowSummary()
        var counted = 0
        for offset in 1...months {
            guard let start = calendar.date(byAdding: .month, value: -offset, to: currentMonth.start),
                  let interval = calendar.dateInterval(of: .month, for: start) else { continue }
            let flow = cashFlow(in: interval)
            if flow.income != 0 || flow.expenses != 0 {
                total.income += flow.income
                total.expenses += flow.expenses
                counted += 1
            }
        }
        guard counted > 0 else { return nil }
        return CashFlowSummary(income: Money.round(total.income / Decimal(counted)),
                               expenses: Money.round(total.expenses / Decimal(counted)))
    }
}
