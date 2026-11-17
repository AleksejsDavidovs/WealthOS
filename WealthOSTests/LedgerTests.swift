import Foundation
import SwiftData
import Testing
@testable import WealthOS

@MainActor
@Suite("Ledger, transfers & net worth")
struct LedgerTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let converter = CurrencyConverter(baseCode: "EUR", rates: ["USD": Decimal(string: "0.9")!])

    init() throws {
        container = try Persistence.makeInMemoryContainer()
    }

    private func engine() throws -> FinanceEngine {
        FinanceEngine(accounts: try context.fetch(FetchDescriptor<Account>()),
                      transactions: try context.fetch(FetchDescriptor<TransactionRecord>()),
                      holdings: try context.fetch(FetchDescriptor<Holding>()),
                      trades: try context.fetch(FetchDescriptor<InvestmentTrade>()),
                      converter: converter)
    }

    @Test func incomeExpenseAndTransferBalances() throws {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 1_000)
        let savings = Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 500)
        context.insert(checking); context.insert(savings)
        let date = Date.now.addingTimeInterval(-60)
        context.insert(TransactionRecord(kind: .income, amount: 2_000, date: date, accountID: checking.id))
        context.insert(TransactionRecord(kind: .expense, amount: Decimal(string: "250.75")!, date: date, accountID: checking.id))
        context.insert(TransactionRecord(kind: .transfer, amount: 400, date: date, accountID: checking.id, destinationAccountID: savings.id))
        try context.save()

        let engine = try engine()
        #expect(engine.balance(of: checking) == Decimal(string: "2349.25"))
        #expect(engine.balance(of: savings) == 900)
        #expect(engine.summary.netWorth == Decimal(string: "3249.25"))
    }

    @Test func transfersAreNeverIncomeOrExpense() throws {
        let a = Account(name: "A", kind: .checking, currencyCode: "EUR", openingBalance: 1_000)
        let b = Account(name: "B", kind: .savings, currencyCode: "EUR", openingBalance: 0)
        context.insert(a); context.insert(b)
        context.insert(TransactionRecord(kind: .transfer, amount: 700, date: .now, accountID: a.id, destinationAccountID: b.id))
        context.insert(TransactionRecord(kind: .adjustment, amount: -50, date: .now, accountID: a.id))
        try context.save()

        let engine = try engine()
        let flow = engine.cashFlow(forMonthContaining: .now)
        #expect(flow.income == 0)
        #expect(flow.expenses == 0)
        #expect(engine.summary.netWorth == 950)
    }

    @Test func crossCurrencyTransferUsesDestinationAmount() throws {
        let eur = Account(name: "EUR", kind: .checking, currencyCode: "EUR", openingBalance: 1_000)
        let usd = Account(name: "USD", kind: .checking, currencyCode: "USD", openingBalance: 0)
        context.insert(eur); context.insert(usd)
        context.insert(TransactionRecord(kind: .transfer, amount: 90, destinationAmount: 100, date: .now,
                                         accountID: eur.id, destinationAccountID: usd.id))
        try context.save()
        let engine = try engine()
        #expect(engine.balance(of: eur) == 910)
        #expect(engine.balance(of: usd) == 100)
        // 910 EUR + 100 USD × 0.9 = 1000 EUR: the transfer didn't create or destroy wealth.
        #expect(engine.summary.netWorth == 1_000)
    }

    @Test func investmentPurchaseIsNotAnExpenseAndNotDoubleCounted() throws {
        let broker = Account(name: "Broker", kind: .investment, currencyCode: "EUR", openingBalance: 5_000)
        context.insert(broker)
        let etf = Holding(name: "ETF", symbol: "ETF", assetClass: .etf, currencyCode: "EUR", currentPrice: 100)
        context.insert(etf)
        context.insert(InvestmentTrade(holdingID: etf.id, kind: .buy, date: .now.addingTimeInterval(-60), quantity: 30, pricePerUnit: 100,
                                       fee: 0, cashAccountID: broker.id, cashAmount: 3_000))
        try context.save()

        let engine = try engine()
        #expect(engine.balance(of: broker) == 2_000)
        #expect(engine.summary.holdingsValue == 3_000)
        #expect(engine.summary.investments == 5_000)
        #expect(engine.summary.netWorth == 5_000)
        #expect(engine.cashFlow(forMonthContaining: .now).expenses == 0)
    }

    @Test func liabilitiesReduceNetWorth() throws {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 3_000)
        let card = Account(name: "Card", kind: .liability, currencyCode: "EUR", openingBalance: -800)
        context.insert(checking); context.insert(card)
        // Paying 300 off the card is a transfer: net worth unchanged.
        context.insert(TransactionRecord(kind: .transfer, amount: 300, date: .now, accountID: checking.id, destinationAccountID: card.id))
        // Spending 100 on the card is an expense.
        context.insert(TransactionRecord(kind: .expense, amount: 100, date: .now, accountID: card.id))
        try context.save()

        let engine = try engine()
        #expect(engine.summary.liabilities == 600)
        #expect(engine.summary.liquid == 2_700)
        #expect(engine.summary.netWorth == 2_100)
    }

    @Test func missingRateIsExcludedAndReported() throws {
        context.insert(Account(name: "CHF", kind: .checking, currencyCode: "CHF", openingBalance: 1_000))
        context.insert(Account(name: "EUR", kind: .checking, currencyCode: "EUR", openingBalance: 500))
        try context.save()
        let engine = try engine()
        #expect(engine.summary.netWorth == 500)
        #expect(engine.summary.missingRateCurrencies == ["CHF"])
    }

    @Test func scheduledTransactionsDoNotAffectTodaysBalance() throws {
        let account = Account(name: "A", kind: .checking, currencyCode: "EUR", openingBalance: 100)
        context.insert(account)
        context.insert(TransactionRecord(kind: .expense, amount: 50, date: .now.addingTimeInterval(86_400 * 5), accountID: account.id))
        try context.save()
        let engine = try engine()
        #expect(engine.balance(of: account) == 100)
    }

    @Test func goalsAreNotPartOfNetWorth() throws {
        context.insert(Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 10_000))
        context.insert(Goal(name: "Car", type: .car, targetAmount: 20_000, allocatedAmount: 8_000))
        try context.save()
        let engine = try engine()
        #expect(engine.summary.netWorth == 10_000)
        #expect(GoalMath.allocatableAssets(engine.summary) == 10_000)
    }

    @Test func balanceAdjustmentHitsTarget() throws {
        let account = Account(name: "A", kind: .checking, currencyCode: "EUR", openingBalance: 100)
        context.insert(account)
        try context.save()
        try LedgerService.adjustBalance(of: account, currentBalance: 100, to: Decimal(string: "87.40")!, in: context)
        let engine = try engine()
        #expect(engine.balance(of: account) == Decimal(string: "87.40"))
        #expect(engine.cashFlow(forMonthContaining: .now).expenses == 0)
    }

    @Test func deletingCategoryReassignsToFallback() throws {
        LedgerService.seedDefaultCategoriesIfNeeded(in: context)
        let categories = try context.fetch(FetchDescriptor<TransactionCategory>())
        let food = try #require(categories.first { $0.name == "Food" })
        let other = try #require(categories.first { $0.isSystem && $0.kind == .expense })
        let account = Account(name: "A", kind: .checking, currencyCode: "EUR", openingBalance: 0)
        context.insert(account)
        let transaction = TransactionRecord(kind: .expense, amount: 10, date: .now, accountID: account.id, categoryID: food.id)
        context.insert(transaction)
        try context.save()

        try LedgerService.delete(category: food, in: context)
        #expect(transaction.categoryID == other.id)
        #expect(try context.fetch(FetchDescriptor<TransactionRecord>()).count == 1)
    }

    @Test func systemCategoryCannotBeDeleted() throws {
        LedgerService.seedDefaultCategoriesIfNeeded(in: context)
        let other = try #require(try context.fetch(FetchDescriptor<TransactionCategory>()).first { $0.isSystem })
        try LedgerService.delete(category: other, in: context)
        #expect(try context.fetch(FetchDescriptor<TransactionCategory>()).contains { $0.id == other.id })
    }

    @Test func deletingAccountRemovesBothSidesOfTransfers() throws {
        let a = Account(name: "A", kind: .checking, currencyCode: "EUR", openingBalance: 1_000)
        let b = Account(name: "B", kind: .savings, currencyCode: "EUR", openingBalance: 0)
        context.insert(a); context.insert(b)
        context.insert(TransactionRecord(kind: .transfer, amount: 300, date: .now, accountID: a.id, destinationAccountID: b.id))
        context.insert(TransactionRecord(kind: .income, amount: 50, date: .now, accountID: a.id))
        try context.save()

        try LedgerService.delete(account: b, in: context)
        let engine = try engine()
        #expect(engine.accounts.count == 1)
        #expect(engine.transactions.count == 1)
        #expect(engine.balance(of: a) == 1_050)
    }

    @Test func recurringRulesGenerateDueOccurrencesOnce() throws {
        let calendar = Calendar.current
        let account = Account(name: "A", kind: .checking, currencyCode: "EUR", openingBalance: 0)
        context.insert(account)
        let start = calendar.date(byAdding: .month, value: -3, to: .now)!
        context.insert(RecurringRule(kind: .expense, amount: 9, accountID: account.id, frequency: .monthly, startDate: start))
        try context.save()

        let first = RecurringService.processDueRules(in: context)
        let second = RecurringService.processDueRules(in: context)
        #expect(first == 4)
        #expect(second == 0)
        #expect(try context.fetch(FetchDescriptor<TransactionRecord>()).count == 4)
    }

    @Test func monthlyRecurrenceDoesNotDrift() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let jan31 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31))!
        let feb = RecurrenceFrequency.monthly.occurrence(1, from: jan31, calendar: calendar)!
        let mar = RecurrenceFrequency.monthly.occurrence(2, from: jan31, calendar: calendar)!
        #expect(calendar.component(.day, from: feb) == 28)
        #expect(calendar.component(.day, from: mar) == 31)
    }

    @Test func rebasingRatesKeepsValuesConsistent() throws {
        context.insert(CurrencyRate(code: "USD", rateToBase: Decimal(string: "0.9")!))
        context.insert(CurrencyRate(code: "GBP", rateToBase: Decimal(string: "1.2")!))
        try context.save()
        try LedgerService.rebaseRates(from: "EUR", to: "USD", in: context)
        let rates = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CurrencyRate>()).map { ($0.code, $0.rateToBase) })
        #expect(rates["USD"] == nil)
        #expect(Money.round(rates["EUR"]!, scale: 6) == Money.round(Decimal(1) / Decimal(string: "0.9")!, scale: 6))
        #expect(Money.round(rates["GBP"]!, scale: 6) == Money.round(Decimal(string: "1.2")! / Decimal(string: "0.9")!, scale: 6))
    }

    @Test func automaticSnapshotIsOnePerDay() throws {
        let summary = NetWorthSummary(liquid: 100)
        SnapshotService.recordAutomaticSnapshot(summary: summary, currencyCode: "EUR", hasData: true, in: context)
        SnapshotService.recordAutomaticSnapshot(summary: NetWorthSummary(liquid: 150), currencyCode: "EUR", hasData: true, in: context)
        let snapshots = try context.fetch(FetchDescriptor<NetWorthSnapshot>())
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.netWorth == 150)
        SnapshotService.recordAutomaticSnapshot(summary: summary, currencyCode: "EUR", hasData: false, in: context)
        #expect(try context.fetch(FetchDescriptor<NetWorthSnapshot>()).count == 1)
    }
}
