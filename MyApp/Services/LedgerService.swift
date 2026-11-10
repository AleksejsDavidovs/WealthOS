import Foundation
import SwiftData

/// All mutations that touch more than one record live here so the rules for
/// safe deletion and balance consistency are implemented in one place.
enum LedgerService {
    // MARK: Categories

    static let defaultExpenseCategories: [(String, String, String)] = [
        ("Food", "fork.knife", "orange"),
        ("Transport", "tram.fill", "blue"),
        ("Shopping", "bag.fill", "pink"),
        ("Subscriptions", "repeat.circle.fill", "purple"),
        ("Entertainment", "popcorn.fill", "indigo"),
        ("Health", "heart.fill", "red"),
        ("Car", "car.fill", "teal"),
        ("Education", "book.fill", "cyan"),
    ]

    static let defaultIncomeCategories: [(String, String, String)] = [
        ("Salary", "briefcase.fill", "green"),
        ("Freelance", "laptopcomputer", "mint"),
        ("Gifts", "gift.fill", "pink"),
    ]

    /// Seeds the default categories on an empty store. Categories are configuration,
    /// not financial data, so this never creates transactions or balances.
    static func seedDefaultCategoriesIfNeeded(in context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<TransactionCategory>())) ?? 0
        guard count == 0 else { return }
        for (index, item) in defaultExpenseCategories.enumerated() {
            context.insert(TransactionCategory(name: item.0, kind: .expense, symbol: item.1, colorName: item.2, sortOrder: index))
        }
        context.insert(TransactionCategory(name: "Other", kind: .expense, symbol: "ellipsis.circle.fill",
                                           colorName: "gray", isSystem: true, sortOrder: 99))
        for (index, item) in defaultIncomeCategories.enumerated() {
            context.insert(TransactionCategory(name: item.0, kind: .income, symbol: item.1, colorName: item.2, sortOrder: index))
        }
        context.insert(TransactionCategory(name: "Other income", kind: .income, symbol: "plus.circle.fill",
                                           colorName: "gray", isSystem: true, sortOrder: 99))
        try? context.save()
    }

    static func fallbackCategory(for kind: CategoryKind, in context: ModelContext) -> TransactionCategory {
        let categories = (try? context.fetch(FetchDescriptor<TransactionCategory>())) ?? []
        if let system = categories.first(where: { $0.kind == kind && $0.isSystem }) { return system }
        let created = TransactionCategory(name: kind == .expense ? "Other" : "Other income", kind: kind,
                                          symbol: "ellipsis.circle.fill", colorName: "gray", isSystem: true, sortOrder: 99)
        context.insert(created)
        return created
    }

    static func usageCount(of category: TransactionCategory, in context: ModelContext) -> Int {
        let transactions = (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? []
        return transactions.filter { $0.categoryID == category.id }.count
    }

    /// Deletes a category and reassigns its transactions and recurring rules to the
    /// kind's system fallback category, so no transaction is lost or left uncategorized.
    static func delete(category: TransactionCategory, in context: ModelContext) throws {
        guard !category.isSystem else { return }
        let fallback = fallbackCategory(for: category.kind, in: context)
        let id = category.id
        for transaction in try context.fetch(FetchDescriptor<TransactionRecord>()) where transaction.categoryID == id {
            transaction.categoryID = fallback.id
        }
        for rule in try context.fetch(FetchDescriptor<RecurringRule>()) where rule.categoryID == id {
            rule.categoryID = fallback.id
        }
        context.delete(category)
        try context.save()
    }

    // MARK: Accounts

    struct AccountUsage {
        var transactions = 0
        var trades = 0
        var rules = 0
        var holdings = 0
        var isEmpty: Bool { transactions == 0 && trades == 0 && rules == 0 && holdings == 0 }
    }

    static func usage(of account: Account, in context: ModelContext) -> AccountUsage {
        let id = account.id
        var usage = AccountUsage()
        usage.transactions = ((try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? [])
            .filter { $0.accountID == id || $0.destinationAccountID == id }.count
        usage.trades = ((try? context.fetch(FetchDescriptor<InvestmentTrade>())) ?? []).filter { $0.cashAccountID == id }.count
        usage.rules = ((try? context.fetch(FetchDescriptor<RecurringRule>())) ?? [])
            .filter { $0.accountID == id || $0.destinationAccountID == id }.count
        usage.holdings = ((try? context.fetch(FetchDescriptor<Holding>())) ?? []).filter { $0.accountID == id }.count
        return usage
    }

    /// Deletes an account together with every transaction and recurring rule that
    /// references it (including both legs of transfers). Trades funded from the account
    /// keep their holding position but lose the cash link.
    static func delete(account: Account, in context: ModelContext) throws {
        let id = account.id
        for transaction in try context.fetch(FetchDescriptor<TransactionRecord>())
        where transaction.accountID == id || transaction.destinationAccountID == id {
            context.delete(transaction)
        }
        for rule in try context.fetch(FetchDescriptor<RecurringRule>())
        where rule.accountID == id || rule.destinationAccountID == id {
            context.delete(rule)
        }
        for trade in try context.fetch(FetchDescriptor<InvestmentTrade>()) where trade.cashAccountID == id {
            trade.cashAccountID = nil
            trade.cashAmount = nil
        }
        for holding in try context.fetch(FetchDescriptor<Holding>()) where holding.accountID == id {
            holding.accountID = nil
        }
        context.delete(account)
        try context.save()
    }

    /// Records a balance correction so the account shows `newBalance`. The difference is an
    /// adjustment, never income or expense.
    @discardableResult
    static func adjustBalance(of account: Account, currentBalance: Decimal, to newBalance: Decimal,
                              date: Date = .now, note: String = "Balance update", in context: ModelContext) throws -> TransactionRecord? {
        let difference = newBalance - currentBalance
        guard difference != 0 else { return nil }
        let adjustment = TransactionRecord(kind: .adjustment, amount: difference, date: date, note: note, accountID: account.id)
        context.insert(adjustment)
        try context.save()
        return adjustment
    }

    // MARK: Investments

    /// Deletes one trade only if the holding's remaining history stays valid at every date —
    /// e.g. a buy that a later sell depends on can't be removed (it would leave an oversold,
    /// unvaluable position). Throws the calculator's error and changes nothing otherwise.
    static func delete(trade: InvestmentTrade, in context: ModelContext) throws {
        let holdingID = trade.holdingID
        let tradeID = trade.id
        let remaining = try context.fetch(FetchDescriptor<InvestmentTrade>())
            .filter { $0.holdingID == holdingID && $0.id != tradeID }
            .map { TradeInput(kind: $0.kind, date: $0.date, quantity: $0.quantity, price: $0.pricePerUnit, fee: $0.fee, createdAt: $0.createdAt) }
        _ = try InvestmentCalculator.position(for: remaining)
        context.delete(trade)
    }

    static func delete(holding: Holding, in context: ModelContext) throws {
        let id = holding.id
        for trade in try context.fetch(FetchDescriptor<InvestmentTrade>()) where trade.holdingID == id {
            context.delete(trade)
        }
        for point in try context.fetch(FetchDescriptor<PricePoint>()) where point.holdingID == id {
            context.delete(point)
        }
        context.delete(holding)
        try context.save()
    }

    /// Manual price entry. A typed price always wins: it marks the price as manual and turns
    /// off automatic market updates for this holding so it isn't overwritten later.
    static func updatePrice(of holding: Holding, to price: Decimal, date: Date = .now, in context: ModelContext) throws {
        holding.currentPrice = price
        holding.priceUpdatedAt = date
        holding.priceSource = .manual
        holding.autoApplyMarketPrice = false
        context.insert(PricePoint(holdingID: holding.id, date: date, price: price))
        try context.save()
    }

    // MARK: Exchange rates

    static func setRate(_ rate: Decimal, for code: String, in context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<CurrencyRate>()).first { $0.code == code }
        if let existing {
            existing.rateToBase = rate
            existing.updatedAt = .now
            existing.source = .manual
        } else {
            context.insert(CurrencyRate(code: code, rateToBase: rate))
        }
        try context.save()
    }

    /// Re-expresses stored rates when the base currency changes. If the new base had a
    /// rate r (1 new = r old), every rate x becomes x / r and the old base gets 1 / r.
    /// Without a known rate the existing rates are removed so nothing is converted wrongly.
    static func rebaseRates(from oldBase: String, to newBase: String, in context: ModelContext) throws {
        guard oldBase != newBase else { return }
        let rates = try context.fetch(FetchDescriptor<CurrencyRate>())
        if let pivot = rates.first(where: { $0.code == newBase }), pivot.rateToBase > 0 {
            let r = pivot.rateToBase
            for rate in rates where rate.code != newBase {
                rate.rateToBase = rate.rateToBase / r
            }
            context.delete(pivot)
            context.insert(CurrencyRate(code: oldBase, rateToBase: 1 / r, updatedAt: pivot.updatedAt))
        } else {
            for rate in rates { context.delete(rate) }
        }
        try context.save()
    }

    // MARK: Reset

    static func deleteAllData(in context: ModelContext) throws {
        for account in try context.fetch(FetchDescriptor<Account>()) { context.delete(account) }
        for item in try context.fetch(FetchDescriptor<TransactionRecord>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<TransactionCategory>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<RecurringRule>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<Holding>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<InvestmentTrade>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<PricePoint>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<CurrencyRate>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<NetWorthSnapshot>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<Goal>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<SimulationScenario>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<MarketQuote>()) { context.delete(item) }
    }
}

enum RecurringService {
    /// Generates transactions for every due occurrence up to `now`. Returns the count created.
    /// Rules advance by occurrence index, so running this repeatedly is idempotent.
    @discardableResult
    static func processDueRules(in context: ModelContext, now: Date = .now, calendar: Calendar = .current) -> Int {
        guard let rules = try? context.fetch(FetchDescriptor<RecurringRule>()) else { return 0 }
        let accounts = Set(((try? context.fetch(FetchDescriptor<Account>())) ?? []).map(\.id))
        let limit = calendar.startOfDay(for: now).addingTimeInterval(86_399)
        var created = 0
        for rule in rules where rule.isActive {
            guard accounts.contains(rule.accountID) else { continue }
            var safety = 0
            while let due = rule.nextDueDate, due <= limit, safety < 1_000 {
                context.insert(TransactionRecord(kind: rule.kind, amount: rule.amount,
                                                 destinationAmount: rule.destinationAmount, date: due,
                                                 note: rule.note, accountID: rule.accountID,
                                                 destinationAccountID: rule.destinationAccountID,
                                                 categoryID: rule.categoryID, recurringRuleID: rule.id))
                rule.generatedCount += 1
                created += 1
                safety += 1
            }
            if rule.nextDueDate == nil, let end = rule.endDate, end < now { rule.isActive = false }
        }
        if created > 0 { try? context.save() }
        return created
    }
}

enum SnapshotService {
    /// Records (or refreshes) today's automatic snapshot from actual current balances.
    /// Never back-fills past dates: history only contains values that really existed.
    static func recordAutomaticSnapshot(summary: NetWorthSummary, currencyCode: String, hasData: Bool,
                                        in context: ModelContext, now: Date = .now, calendar: Calendar = .current) {
        guard hasData else { return }
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let automatic = SnapshotSource.automatic.rawValue
        let descriptor = FetchDescriptor<NetWorthSnapshot>(predicate: #Predicate {
            $0.date >= start && $0.date < end && $0.sourceRaw == automatic
        })
        let existing = (try? context.fetch(descriptor)) ?? []
        if let snapshot = existing.first, snapshot.currencyCode == currencyCode {
            guard snapshot.netWorth != summary.netWorth || snapshot.investmentTotal != summary.investments
                    || snapshot.liquidTotal != summary.liquid || snapshot.liabilitiesTotal != summary.liabilities else { return }
            snapshot.date = now
            snapshot.netWorth = summary.netWorth
            snapshot.liquidTotal = summary.liquid
            snapshot.investmentTotal = summary.investments
            snapshot.otherAssetsTotal = summary.otherAssets
            snapshot.liabilitiesTotal = summary.liabilities
        } else {
            for stale in existing { context.delete(stale) }
            context.insert(NetWorthSnapshot(date: now, netWorth: summary.netWorth, liquidTotal: summary.liquid,
                                            investmentTotal: summary.investments, otherAssetsTotal: summary.otherAssets,
                                            liabilitiesTotal: summary.liabilities, source: .automatic,
                                            currencyCode: currencyCode))
        }
        try? context.save()
    }
}
