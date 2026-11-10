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

/// Synced Trading 212 data plus the user's "already counted there" links.
struct BrokerPortfolio {
    var snapshot: BrokerAccountSnapshot?
    var positions: [BrokerPosition]
    var links: [BrokerLink]

    static let empty = BrokerPortfolio(snapshot: nil, positions: [], links: [])

    var supersededAccountIDs: Set<UUID> { Set(links.filter { $0.kind == .account }.map(\.localID)) }
    var supersededHoldingIDs: Set<UUID> { Set(links.filter { $0.kind == .holding }.map(\.localID)) }
}

struct BrokerPositionValue: Identifiable {
    let position: BrokerPosition
    /// Value/cost/P&L converted to the base currency; nil when not reported or not convertible.
    let valueBase: Decimal?
    let costBase: Decimal?
    let unrealizedBase: Decimal?
    let missingCurrency: String?
    var id: UUID { position.id }
    var hasValuation: Bool { position.currentValue != nil || position.currentPrice != nil }
}

/// Computes balances, net worth and cash-flow statistics from persisted records.
///
/// Accounting rules:
/// - Account balance = opening balance + income − expenses ± transfers ± adjustments ± trade cash flows.
/// - Transfers move money between own accounts and are excluded from income/expenses.
/// - Investment trades move value between a cash account and a holding; they are never expenses.
/// - Net worth = Σ account balances (liabilities are negative) + Σ holding market values.
///   Goal allocations are earmarks of these assets and are never added.
/// - Trading 212: synced cash counts as investment-account cash and each position's reported
///   value as holdings — the provider's own account total is never added on top. Manual
///   accounts/holdings the user linked as "counted via Trading 212" are excluded from totals
///   (but kept and still listed), so the same money is never counted twice.
struct FinanceEngine {
    let accounts: [Account]
    let transactions: [TransactionRecord]
    let holdings: [Holding]
    let trades: [InvestmentTrade]
    let converter: CurrencyConverter
    let broker: BrokerPortfolio
    let brokerPositions: [BrokerPositionValue]
    /// Trading 212 cash in the base currency; nil without a snapshot or exchange rate.
    let brokerCashBase: Decimal?

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
         trades: [InvestmentTrade], converter: CurrencyConverter, broker: BrokerPortfolio = .empty,
         now: Date = .now, calendar: Calendar = .current) {
        self.accounts = accounts
        self.transactions = transactions
        self.holdings = holdings
        self.trades = trades
        self.converter = converter
        self.broker = broker
        let brokerPositions = Self.computeBrokerPositions(broker, converter: converter)
        self.brokerPositions = brokerPositions
        let brokerCashBase = broker.snapshot.flatMap { converter.toBase($0.cashTotal, from: $0.currencyCode) }
        self.brokerCashBase = brokerCashBase
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
        let supersededAccounts = broker.supersededAccountIDs
        let supersededHoldings = broker.supersededHoldingIDs
        var summary = Self.computeSummary(accounts: accounts.filter { !supersededAccounts.contains($0.id) },
                                          balances: balances,
                                          positions: positions.filter { !supersededHoldings.contains($0.holding.id) },
                                          converter: converter)
        if let snapshot = broker.snapshot {
            if let brokerCashBase {
                summary.investmentAccounts += brokerCashBase
            } else if snapshot.cashTotal != 0 {
                summary.missingRateCurrencies.insert(snapshot.currencyCode)
            }
        }
        for value in brokerPositions {
            if let base = value.valueBase { summary.holdingsValue += base }
            if let currency = value.missingCurrency { summary.missingRateCurrencies.insert(currency) }
        }
        self.summary = summary
    }

    // MARK: Trading 212

    static func computeBrokerPositions(_ broker: BrokerPortfolio, converter: CurrencyConverter) -> [BrokerPositionValue] {
        let accountCurrency = broker.snapshot?.currencyCode ?? ""
        return broker.positions.map { position in
            let valueCurrency = position.valueCurrency.isEmpty ? accountCurrency : position.valueCurrency
            var missing: String?
            func base(_ amount: Decimal?, _ currency: String) -> Decimal? {
                guard let amount, !currency.isEmpty else { return nil }
                guard let converted = converter.toBase(amount, from: currency) else {
                    if amount != 0 { missing = currency }
                    return nil
                }
                return converted
            }
            // Prefer Trading 212's own valuation in the account currency; fall back to
            // quantity × current price (instrument currency) only if the value is missing.
            let value = position.currentValue != nil
                ? base(position.currentValue, valueCurrency)
                : base(position.currentPrice.map { $0 * position.quantity }, position.instrumentCurrency)
            let cost = base(position.totalCost, valueCurrency)
            let unrealized: Decimal? = position.unrealizedProfitLoss != nil
                ? base(position.unrealizedProfitLoss, valueCurrency)
                : (value != nil && cost != nil ? value! - cost! : nil)
            return BrokerPositionValue(position: position, valueBase: value, costBase: cost,
                                       unrealizedBase: unrealized, missingCurrency: missing)
        }
    }

    func isSuperseded(_ holding: Holding) -> Bool { broker.supersededHoldingIDs.contains(holding.id) }
    func isSuperseded(_ account: Account) -> Bool { broker.supersededAccountIDs.contains(account.id) }

    /// Trading 212 cash + positions, in base currency. Never the provider's reported total.
    var brokerTotalBase: Decimal { (brokerCashBase ?? 0) + brokerPositions.compactMap(\.valueBase).reduce(0, +) }

    /// Manual positions that count toward totals (not superseded by Trading 212).
    var countedPositions: [PositionSummary] { positions.filter { !isSuperseded($0.holding) } }

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

    /// Cost basis over positions whose cost is known (manual + Trading 212). Unknown costs are
    /// excluded, never treated as zero — see `positionsWithoutCost`.
    var portfolioCostBasis: Decimal {
        countedPositions.compactMap(\.costBasisBase).reduce(0, +) + brokerPositions.compactMap(\.costBase).reduce(0, +)
    }
    var portfolioMarketValue: Decimal {
        countedPositions.compactMap(\.marketValueBase).reduce(0, +) + brokerPositions.compactMap(\.valueBase).reduce(0, +)
    }
    /// Unrealized P/L over positions where it can be determined.
    var portfolioUnrealized: Decimal {
        countedPositions.compactMap(\.unrealizedProfitBase).reduce(0, +) + brokerPositions.compactMap(\.unrealizedBase).reduce(0, +)
    }
    var portfolioRealized: Decimal {
        let brokerRealized = broker.snapshot.flatMap { snapshot in
            snapshot.realizedProfitLoss.flatMap { converter.toBase($0, from: snapshot.currencyCode) }
        } ?? 0
        return countedPositions.compactMap(\.realizedBase).reduce(0, +) + brokerRealized
    }
    /// Positions whose cost basis (and so P/L) isn't available.
    var positionsWithoutCost: Int {
        countedPositions.filter { $0.costBasisBase == nil }.count + brokerPositions.filter { $0.costBase == nil }.count
    }
    var hasAnyPositions: Bool { !positions.isEmpty || !brokerPositions.isEmpty }

    /// Market value by asset class in base currency (holdings only, manual + Trading 212).
    var allocation: [(assetClass: AssetClass, value: Decimal)] {
        var totals: [AssetClass: Decimal] = [:]
        for position in countedPositions {
            guard let value = position.marketValueBase, value > 0 else { continue }
            totals[position.holding.assetClass, default: 0] += value
        }
        for position in brokerPositions {
            guard let value = position.valueBase, value > 0 else { continue }
            totals[position.position.assetClass, default: 0] += value
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
