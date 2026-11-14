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

        context.insert(Goal(name: "Emergency Fund", type: .emergencyFund, targetAmount: 15_000,
                            targetDate: calendar.date(byAdding: .month, value: 10, to: now), allocatedAmount: 9_000,
                            monthlyContribution: 400))
        context.insert(Goal(name: "New Car", type: .car, targetAmount: 20_000,
                            targetDate: calendar.date(byAdding: .year, value: 2, to: now), allocatedAmount: 3_500,
                            monthlyContribution: 450))
        context.insert(Goal(name: "Japan Trip", type: .travel, targetAmount: 4_000,
                            targetDate: calendar.date(byAdding: .month, value: 7, to: now), allocatedAmount: 1_250,
                            monthlyContribution: 250))
        context.insert(RecurringRule(kind: .expense, amount: 13, accountID: checking.id, categoryID: category("Subscriptions"),
                                     note: "Music streaming", frequency: .monthly,
                                     startDate: calendar.date(byAdding: .month, value: 1, to: now) ?? now))
        try? context.save()
    }
}
