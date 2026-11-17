import Foundation
import SwiftData
import Testing
@testable import WealthOS

/// Cash-flow analytics: what counts, period arithmetic, breakdowns and averages.
/// In-memory stores only — never the real database.
@MainActor
@Suite("Cash flow analytics")
struct CashFlowAnalyticsTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Riga")!
        calendar.firstWeekday = 2
        return calendar
    }()

    init() throws { container = try Persistence.makeInMemoryContainer() }

    private func day(_ text: String, hour: Int = 12) -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
    }

    private func engine(now: Date) throws -> FinanceEngine {
        FinanceEngine(accounts: try context.fetch(FetchDescriptor<Account>()),
                      transactions: try context.fetch(FetchDescriptor<TransactionRecord>()),
                      holdings: [], trades: [], converter: .make(base: "EUR", rates: []), now: now)
    }

    @Test func onlyRecordedIncomeAndExpensesUpToTodayCount() throws {
        let now = day("2026-11-17")
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 100)
        let savings = Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 0)
        [checking, savings].forEach(context.insert)
        let food = UUID()
        context.insert(TransactionRecord(kind: .income, amount: 1_000, date: day("2026-11-01"), accountID: checking.id))
        context.insert(TransactionRecord(kind: .expense, amount: Decimal(string: "12.34")!, date: day("2026-11-03"),
                                         accountID: checking.id, categoryID: food))
        context.insert(TransactionRecord(kind: .transfer, amount: 300, date: day("2026-11-04"),
                                         accountID: checking.id, destinationAccountID: savings.id))
        context.insert(TransactionRecord(kind: .adjustment, amount: -50, date: day("2026-11-05"), accountID: checking.id))
        context.insert(TransactionRecord(kind: .expense, amount: 99, date: day("2026-11-25"), accountID: checking.id)) // scheduled
        // A pending bank transaction is not a ledger record at all.
        let pending = BankTransaction(key: "pending-1", accountKey: String(repeating: "a", count: 64), firstSeenAt: now)
        pending.amount = -40
        pending.statusRaw = BankEntryStatus.pending.rawValue
        context.insert(pending)
        try context.save()

        let engine = try engine(now: now)
        let entries = engine.cashFlowEntries()
        #expect(entries.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.expense, .income])
        let month = calendar.dateInterval(of: .month, for: now)!
        let analytics = CashFlowAnalytics(entries: entries, interval: month, kind: .expense, now: now, calendar: calendar)
        #expect(analytics.income == 1_000 && analytics.expenses == Decimal(string: "12.34")!)
        #expect(analytics.net == Decimal(string: "987.66")!)
        // Same figures as the engine's own cash flow used elsewhere in the app.
        let flow = engine.cashFlow(in: month)
        #expect(flow.income == analytics.income && flow.expenses == analytics.expenses)
    }

    @Test func categoriesAreSortedWithExactSharesAndCounts() {
        let food = UUID(), car = UUID()
        let now = day("2026-11-30")
        let entries = [
            CashFlowEntry(id: UUID(), date: day("2026-11-02"), kind: .expense, categoryID: food, amount: 30),
            CashFlowEntry(id: UUID(), date: day("2026-11-03"), kind: .expense, categoryID: food, amount: 45),
            CashFlowEntry(id: UUID(), date: day("2026-11-04"), kind: .expense, categoryID: car, amount: 25),
            CashFlowEntry(id: UUID(), date: day("2026-11-05"), kind: .expense, categoryID: nil, amount: 0.5),
            CashFlowEntry(id: UUID(), date: day("2026-11-06"), kind: .income, categoryID: nil, amount: 500),
            CashFlowEntry(id: UUID(), date: day("2026-10-31"), kind: .expense, categoryID: car, amount: 999), // outside
        ]
        let month = calendar.dateInterval(of: .month, for: now)!
        let analytics = CashFlowAnalytics(entries: entries, interval: month, kind: .expense, now: now, calendar: calendar)
        #expect(analytics.total == Decimal(string: "100.5")!)
        #expect(analytics.categories.map(\.categoryID) == [food, car, nil])
        #expect(analytics.categories.map(\.count) == [2, 1, 1])
        #expect(analytics.categories[0].amount == 75)
        let shareSum = analytics.categories.reduce(Decimal(0)) { $0 + $1.share }
        #expect(abs(shareSum - 1) < Decimal(string: "0.000001")!)  // Decimal division of repeating fractions
        let incomeView = CashFlowAnalytics(entries: entries, interval: month, kind: .income, now: now, calendar: calendar)
        #expect(incomeView.total == 500 && incomeView.categories.count == 1)
    }

    @Test func dailyBucketsCoverElapsedDaysAndAverageUsesThem() {
        let now = day("2026-11-10")
        let entries = [
            CashFlowEntry(id: UUID(), date: day("2026-11-01", hour: 1), kind: .expense, categoryID: nil, amount: 10),
            CashFlowEntry(id: UUID(), date: day("2026-11-01", hour: 23), kind: .expense, categoryID: nil, amount: 5),
            CashFlowEntry(id: UUID(), date: day("2026-11-10"), kind: .expense, categoryID: nil, amount: 15),
        ]
        let month = calendar.dateInterval(of: .month, for: now)!
        let analytics = CashFlowAnalytics(entries: entries, interval: month, kind: .expense, now: now, calendar: calendar)
        #expect(analytics.granularity == .day)
        #expect(analytics.buckets.count == 10)  // 1...10 November, the future isn't charted
        #expect(analytics.buckets.first?.amount == 15 && analytics.buckets.last?.amount == 15)
        #expect(analytics.buckets.dropFirst().dropLast().allSatisfy { $0.amount == 0 })
        #expect(analytics.elapsedDays == 10)
        #expect(analytics.averageDaily == 3)  // 30 / 10 days
    }

    @Test func longPeriodsChartMonthly() {
        let now = day("2026-11-17")
        let entries = [CashFlowEntry(id: UUID(), date: day("2026-03-05"), kind: .expense, categoryID: nil, amount: 7)]
        let year = calendar.dateInterval(of: .year, for: now)!
        let analytics = CashFlowAnalytics(entries: entries, interval: year, kind: .expense, now: now, calendar: calendar)
        #expect(analytics.granularity == .month)
        #expect(analytics.buckets.count == 11)  // January ... November
        #expect(analytics.buckets[2].amount == 7)
    }

    @Test func periodIntervalsAndPreviousPeriods() {
        let anchor = day("2026-11-17")  // a Tuesday
        let start = day("2026-10-01"), end = day("2026-10-10")
        let week = AnalyticsPeriod.week.interval(anchor: anchor, customStart: start, customEnd: end, earliest: nil,
                                                 now: anchor, calendar: calendar)
        #expect(week.start == calendar.startOfDay(for: day("2026-11-16")))  // Monday
        #expect(AnalyticsPeriod.week.previous(of: week, calendar: calendar)?.start == calendar.startOfDay(for: day("2026-11-09")))
        let month = AnalyticsPeriod.month.interval(anchor: anchor, customStart: start, customEnd: end, earliest: nil,
                                                   now: anchor, calendar: calendar)
        #expect(AnalyticsPeriod.month.previous(of: month, calendar: calendar)?.start == calendar.startOfDay(for: day("2026-10-01")))
        let custom = AnalyticsPeriod.custom.interval(anchor: anchor, customStart: end, customEnd: start, earliest: nil,
                                                     now: anchor, calendar: calendar)
        #expect(custom.start == calendar.startOfDay(for: start))
        #expect(custom.end == calendar.startOfDay(for: day("2026-10-11")))  // inclusive last day
        let previous = AnalyticsPeriod.custom.previous(of: custom, calendar: calendar)!
        #expect(previous.end == custom.start)
        #expect(calendar.dateComponents([.day], from: previous.start, to: previous.end).day == 10)
        let all = AnalyticsPeriod.all.interval(anchor: anchor, customStart: start, customEnd: end, earliest: day("2025-02-03"),
                                               now: anchor, calendar: calendar)
        #expect(all.start == calendar.startOfDay(for: day("2025-02-03")))
        #expect(AnalyticsPeriod.all.previous(of: all, calendar: calendar) == nil)
        #expect(AnalyticsPeriod.matching(.thisMonth) == .month && AnalyticsPeriod.matching(.last3Months) == .custom)
    }

    @Test func changeAgainstThePreviousPeriod() {
        #expect(CashFlowAnalytics.change(current: 150, previous: 100) == Decimal(string: "0.5")!)
        #expect(CashFlowAnalytics.change(current: 50, previous: 100) == Decimal(string: "-0.5")!)
        #expect(CashFlowAnalytics.change(current: 50, previous: 0) == nil)
    }
}
