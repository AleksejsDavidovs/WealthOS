import Foundation
import SwiftData

/// Builds sample data for the in-memory demo container ONLY. Never called on the real store.
enum DemoDataFactory {
    static func populate(_ context: ModelContext, now: Date = .now) {
        let calendar = Calendar.current
        LedgerService.seedDefaultCategoriesIfNeeded(in: context)
        let categories = (try? context.fetch(FetchDescriptor<TransactionCategory>())) ?? []
        func category(_ name: String) -> UUID? { categories.first { $0.name == name }?.id }
        let start = calendar.date(byAdding: .month, value: -8, to: calendar.startOfDay(for: now)) ?? now

        let checking = Account(name: "Everyday Account", kind: .checking, currencyCode: "EUR", openingBalance: 2_150,
                               openingDate: start, institution: "Demo Bank", colorName: "blue", sortOrder: 0)
        let savings = Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 9_500,
                              openingDate: start, institution: "Demo Bank", colorName: "green", sortOrder: 1)
        let wallet = Account(name: "Wallet", kind: .cash, currencyCode: "EUR", openingBalance: 120,
                             openingDate: start, colorName: "mint", sortOrder: 2)
        let broker = Account(name: "Brokerage", kind: .investment, currencyCode: "EUR", openingBalance: 7_500,
                             openingDate: start, institution: "Demo Broker", colorName: "purple", sortOrder: 3)
        let card = Account(name: "Credit Card", kind: .liability, currencyCode: "EUR", openingBalance: -380,
                           openingDate: start, institution: "Demo Bank", colorName: "red", sortOrder: 4)
        [checking, savings, wallet, broker, card].forEach(context.insert)

        context.insert(CurrencyRate(code: "USD", rateToBase: Decimal(string: "0.92")!, updatedAt: now.addingTimeInterval(-86_400 * 2)))

        var generator = SeededGenerator(seed: 42)
        func jitter(_ base: Int, _ spread: Int) -> Decimal {
            Decimal(base + Int(generator.next() % UInt64(spread * 2 + 1)) - spread)
        }

        for monthOffset in 0...8 {
            guard let monthStart = calendar.date(byAdding: .month, value: monthOffset, to: start) else { continue }
            func day(_ d: Int) -> Date? {
                let date = calendar.date(byAdding: .day, value: d - 1, to: calendar.dateInterval(of: .month, for: monthStart)?.start ?? monthStart)
                return date.flatMap { $0 <= now ? $0 : nil }
            }
            if let date = day(1) {
                context.insert(TransactionRecord(kind: .income, amount: 3_450, date: date, note: "Monthly salary",
                                                 accountID: checking.id, categoryID: category("Salary")))
            }
            if let date = day(3) {
                context.insert(TransactionRecord(kind: .expense, amount: 980, date: date, note: "Rent",
                                                 accountID: checking.id, categoryID: category("Other")))
                context.insert(TransactionRecord(kind: .transfer, amount: 400, date: date, note: "Monthly savings",
                                                 accountID: checking.id, destinationAccountID: savings.id))
            }
            for (dayNumber, name, base, spread, note) in [
                (5, "Food", 64, 20, "Groceries"), (9, "Transport", 49, 0, "Transit pass"),
                (12, "Food", 72, 25, "Groceries"), (14, "Subscriptions", 13, 0, "Music streaming"),
                (16, "Entertainment", 38, 20, "Cinema & dinner"), (19, "Food", 58, 20, "Groceries"),
                (22, "Shopping", 85, 60, "Clothes"), (25, "Health", 30, 15, "Pharmacy"), (27, "Food", 66, 20, "Groceries")
            ] {
                if let date = day(dayNumber) {
                    let account = name == "Shopping" || name == "Entertainment" ? card.id : checking.id
                    context.insert(TransactionRecord(kind: .expense, amount: jitter(base, spread), date: date, note: note,
                                                     accountID: account, categoryID: category(name)))
                }
            }
            if monthOffset % 3 == 1, let date = day(20) {
                context.insert(TransactionRecord(kind: .income, amount: jitter(600, 150), date: date, note: "Design project",
                                                 accountID: checking.id, categoryID: category("Freelance")))
            }
            if let date = day(28) {
                context.insert(TransactionRecord(kind: .transfer, amount: 150, date: date, note: "Card payment",
                                                 accountID: checking.id, destinationAccountID: card.id))
            }
        }

        // Holdings with trades funded from the brokerage cash (no double counting).
        let etf = Holding(name: "FTSE All-World", symbol: "VWCE", assetClass: .etf, currencyCode: "EUR",
                          currentPrice: Decimal(string: "128.40")!, priceUpdatedAt: now.addingTimeInterval(-3_600 * 5), accountID: broker.id,
                          marketSymbol: "VWCE.DEX")
        let stock = Holding(name: "Apple", symbol: "AAPL", assetClass: .stock, currencyCode: "USD",
                            currentPrice: Decimal(string: "231.20")!, priceUpdatedAt: now.addingTimeInterval(-86_400 * 3), accountID: broker.id,
                            marketSymbol: "AAPL")
        let crypto = Holding(name: "Bitcoin", symbol: "BTC", assetClass: .crypto, currencyCode: "USD",
                             currentPrice: 68_500, priceUpdatedAt: now.addingTimeInterval(-86_400 * 9), accountID: broker.id,
                             marketSymbol: "bitcoin")
        [etf, stock, crypto].forEach(context.insert)

        let trades: [(Holding, TradeKind, Int, Decimal, Decimal, Decimal)] = [
            (etf, .buy, 0, 20, Decimal(string: "112.50")!, 1),
            (etf, .buy, 3, 12, Decimal(string: "118.20")!, 1),
            (stock, .buy, 1, 6, Decimal(string: "189.00")!, 2),
            (crypto, .buy, 2, Decimal(string: "0.02")!, 52_000, 3),
            (etf, .buy, 6, 8, Decimal(string: "124.10")!, 1),
            (stock, .sell, 7, 2, Decimal(string: "226.00")!, 2),
        ]
        let usd = Decimal(string: "0.92")!
        for (holding, kind, month, quantity, price, fee) in trades {
            guard let date = calendar.date(byAdding: .month, value: month, to: start) else { continue }
            let impact = InvestmentCalculator.cashImpact(kind: kind, quantity: quantity, price: price, fee: fee)
            let cash = Money.round(holding.currencyCode == "USD" ? impact * usd : impact)
            context.insert(InvestmentTrade(holdingID: holding.id, kind: kind, date: date, quantity: quantity,
                                           pricePerUnit: price, fee: fee, cashAccountID: broker.id, cashAmount: cash))
            context.insert(PricePoint(holdingID: holding.id, date: date, price: price))
        }
        for holding in [etf, stock, crypto] {
            context.insert(PricePoint(holdingID: holding.id, date: holding.priceUpdatedAt ?? now, price: holding.currentPrice))
        }

        try? context.save()

        // Sample history for the demo chart only, shaped to end near the demo's actual net worth.
        let current = DataMaintenance.makeEngine(context: context, baseCurrency: "EUR").summary
        for offset in stride(from: 8, through: 1, by: -1) {
            guard let date = calendar.date(byAdding: .month, value: -offset, to: now) else { continue }
            let factor = Decimal(100 - offset * 3) / 100
            let value = Money.round(current.netWorth * factor) + jitter(0, 300)
            context.insert(NetWorthSnapshot(date: date, netWorth: value, liquidTotal: Money.round(current.liquid * factor),
                                            investmentTotal: Money.round(current.investments * factor),
                                            liabilitiesTotal: current.liabilities, source: offset == 8 ? .manual : .automatic,
                                            currencyCode: "EUR", note: offset == 8 ? "From bank statements" : ""))
        }

        // Weekly portfolio history for the performance chart (demo only), ending at today's values.
        let engineNow = DataMaintenance.makeEngine(context: context, baseCurrency: "EUR")
        let finalCost = engineNow.portfolioCostBasis, finalValue = engineNow.portfolioCostedValue
        var weeks = 34
        #if DEBUG
        // Development aid: `-UIDemoNoHistory` shows the portfolio as on a first day (no history yet).
        if ProcessInfo.processInfo.arguments.contains("-UIDemoNoHistory") { weeks = -1 }
        #endif
        for week in stride(from: 0, through: weeks, by: 1) {
            guard let date = calendar.date(byAdding: .day, value: -7 * (weeks - week), to: now) else { continue }
            let progress = Decimal(week) / Decimal(weeks)
            let funded: Decimal = week < 4 ? Decimal(string: "0.38")! : week < 9 ? Decimal(string: "0.56")! : week < 13 ? Decimal(string: "0.74")!
                : week < 26 ? Decimal(string: "0.88")! : 1
            let cost = Money.round(finalCost * funded)
            let wobble = Decimal(Int(generator.next() % 7) - 3) / 100
            let value = week == weeks ? finalValue : Money.round(cost * (1 + (finalValue / max(finalCost, 1) - 1) * progress + wobble))
            context.insert(PortfolioSnapshot(date: date, currencyCode: "EUR", totalValue: value, costedValue: value,
                                             costBasis: cost, realized: 0))
        }

        context.insert(Goal(name: "Emergency Fund", type: .emergencyFund, targetAmount: 15_000,
                            targetDate: calendar.date(byAdding: .month, value: 10, to: now), allocatedAmount: 9_000,
                            monthlyContribution: 400))
        context.insert(Goal(name: "New Car", type: .car, targetAmount: 20_000,
                            targetDate: calendar.date(byAdding: .year, value: 2, to: now), allocatedAmount: 3_500,
                            monthlyContribution: 450))
        context.insert(Goal(name: "Japan Trip", type: .travel, targetAmount: 4_000,
                            targetDate: calendar.date(byAdding: .month, value: 7, to: now), allocatedAmount: 1_250,
                            monthlyContribution: 250))
        // Subscription-like payments: one price increase, one confirmed, the rest left as suggestions.
        for monthOffset in 0...8 {
            guard let monthStart = calendar.date(byAdding: .month, value: monthOffset, to: start),
                  let first = calendar.dateInterval(of: .month, for: monthStart)?.start else { continue }
            for (dayNumber, note, amount, name) in [
                (7, "Video streaming", monthOffset >= 7 ? Decimal(string: "11.99")! : Decimal(string: "9.99")!, "Subscriptions"),
                (10, "Cloud storage", Decimal(string: "2.99")!, "Subscriptions"),
                (2, "Gym membership", Decimal(35), "Health"),
            ] {
                guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: first), date <= now else { continue }
                context.insert(TransactionRecord(kind: .expense, amount: amount, date: date, note: note,
                                                 accountID: checking.id, categoryID: category(name)))
            }
        }
        context.insert(SubscriptionDecision(key: "note:music streaming", status: .confirmed))
        context.insert(SubscriptionDecision(key: "note:video streaming", status: .confirmed))
        context.insert(Budget(categoryID: nil, amount: 1_800))
        context.insert(Budget(categoryID: category("Food"), amount: 240))
        context.insert(Budget(categoryID: category("Entertainment"), amount: 60))
        context.insert(Budget(categoryID: category("Shopping"), amount: 150, rollover: true))

        context.insert(RecurringRule(kind: .expense, amount: 13, accountID: checking.id, categoryID: category("Subscriptions"),
                                     note: "Music streaming", frequency: .monthly,
                                     startDate: calendar.date(byAdding: .month, value: 1, to: now) ?? now))

        // Trading 212 dividends (demo): a monthly payer, a quarterly ETF and a quarterly stock.
        let payers: [(ticker: String, name: String, every: Int, amount: Decimal, quantity: Decimal, perShare: Decimal)] = [
            ("O_US_EQ", "Realty Income", 1, Decimal(string: "3.12")!, 14, Decimal(string: "0.2635")!),
            ("VUSAl_EQ", "Vanguard S&P 500 UCITS ETF", 3, Decimal(string: "11.48")!, 42, Decimal(string: "0.2973")!),
            ("AAPL_US_EQ", "Apple", 3, Decimal(string: "1.53")!, 8, Decimal(string: "0.25")!),
        ]
        for payer in payers {
            for back in stride(from: 0, through: 14, by: payer.every) {
                guard let paid = calendar.date(byAdding: .month, value: -back, to: calendar.startOfDay(for: now)) else { continue }
                var parts = calendar.dateComponents([.year, .month], from: paid)
                parts.day = payer.every == 1 ? 15 : 8
                parts.hour = 9
                guard let day = calendar.date(from: parts), day <= now else { continue }
                let row = BrokerDividend(key: "demo:\(payer.ticker):\(back)", syncedAt: now)
                row.ticker = payer.ticker
                row.name = payer.name
                row.amount = payer.amount + Decimal(back % 3) / 10
                row.currencyCode = "EUR"
                row.paidOn = day
                row.quantity = payer.quantity
                row.grossPerShare = payer.perShare
                row.instrumentCurrency = "USD"
                row.type = "ORDINARY"
                context.insert(row)
            }
        }

        // Trading 212 account (demo): snapshot, positions and 15 months of history.
        let t212 = BrokerAccountSnapshot(environment: .live, currencyCode: "EUR", syncedAt: now)
        // Chosen so value − deposits matches gains + dividends + interest − fees (no unexplained "other").
        t212.cashAvailable = Decimal(string: "1675.61")!
        context.insert(t212)
        let holdings: [(ticker: String, name: String, type: String, qty: Decimal, value: Decimal, cost: Decimal)] = [
            ("VUSAl_EQ", "Vanguard S&P 500 UCITS ETF", "ETF", 42, 4_310, 3_620),
            ("O_US_EQ", "Realty Income", "STOCK", 14, 742, 768),
            ("AAPL_US_EQ", "Apple", "STOCK", 8, 1_611, 1_240),
        ]
        for holding in holdings {
            let position = BrokerPosition(ticker: holding.ticker, syncedAt: now)
            position.name = holding.name
            position.instrumentType = holding.type
            position.shortName = Trading212Matching.baseSymbol(ofTicker: holding.ticker)
            position.quantity = holding.qty
            position.valueCurrency = "EUR"
            position.currentValue = holding.value
            position.totalCost = holding.cost
            position.unrealizedProfitLoss = holding.value - holding.cost
            context.insert(position)
        }
        func monthsAgo(_ months: Int, day: Int) -> Date {
            let base = calendar.date(byAdding: .month, value: -months, to: now) ?? now
            var parts = calendar.dateComponents([.year, .month], from: base)
            parts.day = day
            parts.hour = 10
            return min(calendar.date(from: parts) ?? base, now)
        }
        var cashIndex = 0
        func cash(_ type: String, _ amount: Decimal, _ date: Date) {
            cashIndex += 1
            let row = BrokerCashTransaction(key: "demo:cash:\(cashIndex)", syncedAt: now)
            row.type = type
            row.amount = amount
            row.currencyCode = "EUR"
            row.date = date
            context.insert(row)
        }
        var orderIndex = 0
        func order(_ ticker: String, _ name: String, buy: Bool, qty: Decimal, price: Decimal, net: Decimal,
                   realized: Decimal = 0, fees: Decimal = 0, _ date: Date) {
            orderIndex += 1
            let row = BrokerOrder(key: "demo:order:\(orderIndex)", syncedAt: now)
            row.ticker = ticker
            row.name = name
            row.side = buy ? "BUY" : "SELL"
            row.quantity = qty
            row.price = price
            row.instrumentCurrency = "USD"
            row.netValue = net
            row.fees = fees
            row.realized = realized
            row.currencyCode = "EUR"
            row.filledAt = date
            context.insert(row)
        }
        cash("DEPOSIT", 2_000, monthsAgo(15, day: 2))
        order("VUSAl_EQ", "Vanguard S&P 500 UCITS ETF", buy: true, qty: 20, price: Decimal(string: "94.10")!, net: 1_745, fees: Decimal(string: "2.61")!, monthsAgo(15, day: 3))
        order("AAPL_US_EQ", "Apple", buy: true, qty: 4, price: Decimal(string: "178.20")!, net: 655, fees: Decimal(string: "0.98")!, monthsAgo(14, day: 8))
        for back in stride(from: 14, through: 0, by: -1) {
            cash("DEPOSIT", back % 4 == 0 ? 600 : 300, monthsAgo(back, day: 1))
            if back % 2 == 0 {
                order("VUSAl_EQ", "Vanguard S&P 500 UCITS ETF", buy: true, qty: 3, price: Decimal(97 + (14 - back)), net: Decimal(270 + (14 - back) * 3),
                      fees: Decimal(string: "0.40")!, monthsAgo(back, day: 3))
            }
        }
        order("O_US_EQ", "Realty Income", buy: true, qty: 14, price: Decimal(string: "58.90")!, net: 768, fees: Decimal(string: "1.15")!, monthsAgo(11, day: 12))
        order("AAPL_US_EQ", "Apple", buy: true, qty: 6, price: Decimal(string: "190.40")!, net: 1_050, fees: Decimal(string: "1.57")!, monthsAgo(9, day: 20))
        order("AAPL_US_EQ", "Apple", buy: false, qty: 2, price: Decimal(string: "228.10")!, net: 418, realized: 92, fees: Decimal(string: "0.63")!, monthsAgo(4, day: 14))
        order("TSLA_US_EQ", "Tesla", buy: true, qty: 3, price: Decimal(string: "240.00")!, net: 662, fees: Decimal(string: "0.99")!, monthsAgo(10, day: 5))
        order("TSLA_US_EQ", "Tesla", buy: false, qty: 3, price: Decimal(string: "205.00")!, net: 566, realized: -96, fees: Decimal(string: "0.85")!, monthsAgo(6, day: 22))
        cash("WITHDRAW", -500, monthsAgo(7, day: 18))
        for back in 0...11 { cash("INTEREST_ON_FREE_CASH", Decimal(string: "0.42")! + Decimal(back % 3) / 10, monthsAgo(back, day: 28)) }
        // Daily account value for the last 45 days.
        for back in stride(from: 45, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let drift = Decimal(45 - back) * 9 + Decimal(Int(generator.next() % 120)) - 60
            context.insert(BrokerValuePoint(date: day, currencyCode: "EUR", value: 7_935 + drift, cash: Decimal(string: "1675.61")!))
        }
        try? context.save()
    }
}
