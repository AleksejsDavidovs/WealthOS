import Foundation
import SwiftData
import Testing
@testable import WealthOS

private let riga: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Riga")!
    return calendar
}()

private func day(_ text: String, hour: Int = 12) -> Date {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    return riga.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
}

private func entry(_ date: String, _ kind: TransactionKind, _ amount: Decimal, _ category: UUID? = nil) -> CashFlowEntry {
    CashFlowEntry(id: UUID(), date: day(date), kind: kind, categoryID: category, amount: amount)
}

@Suite("Monthly report")
struct MonthlyReportTests {
    let food = UUID(), rent = UUID(), fun = UUID()

    var entries: [CashFlowEntry] {
        [entry("2026-10-01", .income, 3_000), entry("2026-10-03", .expense, 900, rent), entry("2026-10-05", .expense, 120, food),
         entry("2026-10-20", .expense, 80, food), entry("2026-10-22", .expense, 60, fun),
         entry("2026-09-01", .income, 2_800), entry("2026-09-03", .expense, 900, rent), entry("2026-09-10", .expense, 160, food),
         entry("2026-08-03", .expense, 1_100, rent),
         entry("2026-11-02", .expense, 999, food)]  // next month: not in October's report
    }

    @Test func totalsComparisonsAndAverages() {
        let report = MonthlyReport(entries: entries, month: day("2026-10-15"), now: day("2026-11-17"), calendar: riga)
        #expect(report.isComplete)
        #expect(report.income == 3_000 && report.expenses == 1_160 && report.net == 1_840)
        #expect(abs(report.savingsRate! - Decimal(string: "0.61333")!) < Decimal(string: "0.0001")!)
        #expect(report.previousIncome == 2_800 && report.previousExpenses == 1_060)
        // August 1 100 and September 1 060; July had nothing and isn't averaged in.
        #expect(report.averageExpenses == 1_080)
        #expect(report.dailySpending == Money.round(Decimal(1_160) / 31))
        #expect(report.previousDailySpending == Money.round(Decimal(1_060) / 30))
    }

    @Test func topCategoriesAndBiggestExpense() {
        let report = MonthlyReport(entries: entries, month: day("2026-10-15"), now: day("2026-11-17"), calendar: riga)
        #expect(report.topCategories.map(\.categoryID) == [rent, food, fun])
        #expect(report.topCategories[1].amount == 200 && report.topCategories[1].previous == 160)
        #expect(report.topCategories[1].change == Decimal(string: "0.25")!)
        #expect(report.topCategories[2].change == nil)  // nothing in September to compare with
        #expect(report.biggestExpense?.amount == 900)
    }

    @Test func currentMonthIsSoFarAndCountsElapsedDays() {
        let report = MonthlyReport(entries: entries, month: day("2026-11-01"), now: day("2026-11-10"), calendar: riga)
        #expect(!report.isComplete)
        #expect(report.expenses == 999 && report.dailySpending == Money.round(Decimal(999) / 10))
    }

    @Test func netWorthAndInvestmentsFromSnapshots() {
        let netWorth: [(date: Date, value: Decimal)] = [(day("2026-09-28"), 10_000), (day("2026-10-15"), 10_500), (day("2026-10-31"), 11_200),
                                                        (day("2026-11-05"), 99_999)]
        let report = MonthlyReport(entries: entries, month: day("2026-10-10"), netWorth: netWorth,
                                   investments: [(day("2026-10-04"), 4_000), (day("2026-10-30"), 4_400)],
                                   now: day("2026-11-17"), calendar: riga)
        #expect(report.netWorthStart == 10_000 && report.netWorthEnd == 11_200 && report.netWorthChange == 1_200)
        // No investment point before October: the first one in the month is the start.
        #expect(report.investmentsStart == 4_000 && report.investmentsChange == 400)
        let none = MonthlyReport(entries: entries, month: day("2026-10-10"), now: day("2026-11-17"), calendar: riga)
        #expect(none.netWorthChange == nil && none.investmentsChange == nil)
    }

    @Test func emptyMonthHasNoActivityAndDefaultIsLastMonth() {
        #expect(!MonthlyReport(entries: entries, month: day("2026-06-10"), now: day("2026-11-17"), calendar: riga).hasActivity)
        #expect(riga.component(.month, from: MonthlyReport.defaultMonth(now: day("2026-11-03"), calendar: riga)) == 10)
    }
}

@Suite("Portfolio performance")
struct PortfolioPerformanceTests {
    private func point(_ date: String, _ value: Decimal, _ cost: Decimal) -> PortfolioPoint {
        PortfolioPoint(date: day(date), costedValue: value, costBasis: cost, totalValue: value)
    }

    @Test func moneyAddedIsNotAGainAndTimeWeightedIgnoresIt() {
        let points = [point("2026-01-01", 1_000, 1_000), point("2026-02-01", 1_100, 1_000),
                      point("2026-03-01", 2_100, 2_000),  // +1 000 put in, no market move
                      point("2026-04-01", 2_310, 2_000)]
        let performance = PortfolioPerformance(points: points, from: nil, calendar: riga)
        #expect(performance.contributions == 1_000)
        #expect(performance.marketGain == 310)
        #expect(performance.timeWeighted == Decimal(string: "0.21")!)  // 1.1 × 1.0 × 1.1 − 1
        #expect(performance.annualized == nil)  // shorter than a year
    }

    @Test func rangeStartsFromTheLastPointBeforeIt() {
        let points = [point("2026-01-01", 1_000, 1_000), point("2026-05-01", 1_200, 1_000), point("2026-06-01", 1_260, 1_000)]
        let performance = PortfolioPerformance(points: points, from: day("2026-05-15"), calendar: riga)
        #expect(performance.points.count == 2 && performance.startValue == 1_200)
        #expect(performance.marketGain == 60 && performance.timeWeighted == Decimal(string: "0.05")!)
    }

    @Test func annualizedOnlyForAYearOrMore() throws {
        let points = [point("2024-01-01", 1_000, 1_000), point("2026-01-01", 1_210, 1_000)]
        let performance = PortfolioPerformance(points: points, from: nil, calendar: riga)
        let annualized = try #require(performance.annualized)
        #expect(abs(annualized - Decimal(string: "0.1")!) < Decimal(string: "0.001")!)  // 21 % over ~2 years ≈ 10 % a year
    }

    @Test func totalReturnIncludesRealized() {
        let total = PortfolioPerformance.totalReturn(unrealized: 300, realized: 100, costBasis: 2_000)
        #expect(total.amount == 400 && total.fraction == Decimal(string: "0.2")!)
        #expect(PortfolioPerformance.totalReturn(unrealized: 0, realized: 0, costBasis: 0).fraction == nil)
        #expect(PortfolioPerformance(points: [], from: nil).timeWeighted == nil)
    }
}

@MainActor
@Suite("Portfolio history storage")
struct PortfolioHistoryStorageTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    init() throws { container = try Persistence.makeInMemoryContainer() }

    private func engine(now: Date) throws -> FinanceEngine {
        FinanceEngine(accounts: try context.fetch(FetchDescriptor<Account>()),
                      transactions: try context.fetch(FetchDescriptor<TransactionRecord>()),
                      holdings: try context.fetch(FetchDescriptor<Holding>()),
                      trades: try context.fetch(FetchDescriptor<InvestmentTrade>()),
                      converter: .make(base: "EUR", rates: []), now: now)
    }

    @Test func onePointPerDayUpdatedInPlace() throws {
        let now = day("2026-11-17", hour: 9)
        #expect(!SnapshotService.recordPortfolioSnapshot(engine: try engine(now: now), currencyCode: "EUR", in: context, now: now, calendar: riga))
        let broker = Account(name: "Broker", kind: .investment, currencyCode: "EUR", openingBalance: 5_000)
        context.insert(broker)
        let etf = Holding(name: "ETF", symbol: "VWCE", assetClass: .etf, currencyCode: "EUR", currentPrice: 110, accountID: broker.id)
        context.insert(etf)
        context.insert(InvestmentTrade(holdingID: etf.id, kind: .buy, date: day("2026-10-01"), quantity: 10, pricePerUnit: 100, fee: 0,
                                       cashAccountID: broker.id, cashAmount: 1_000))
        try context.save()
        #expect(SnapshotService.recordPortfolioSnapshot(engine: try engine(now: now), currencyCode: "EUR", in: context, now: now, calendar: riga))
        let first = try #require(try context.fetch(FetchDescriptor<PortfolioSnapshot>()).first)
        #expect(first.costBasis == 1_000 && first.costedValue == 1_100 && first.totalValue == 1_100)
        etf.currentPrice = 120
        let later = day("2026-11-17", hour: 18)
        #expect(SnapshotService.recordPortfolioSnapshot(engine: try engine(now: later), currencyCode: "EUR", in: context, now: later, calendar: riga))
        let points = try context.fetch(FetchDescriptor<PortfolioSnapshot>())
        #expect(points.count == 1 && points[0].costedValue == 1_200)
        #expect(!SnapshotService.recordPortfolioSnapshot(engine: try engine(now: later), currencyCode: "EUR", in: context, now: later, calendar: riga))
    }

    @Test func sourcesSplitManualHoldingsWithInvestedAndValue() throws {
        let broker = Account(name: "Broker", kind: .investment, currencyCode: "EUR", openingBalance: 5_000)
        context.insert(broker)
        let etf = Holding(name: "ETF", symbol: "VWCE", assetClass: .etf, currencyCode: "EUR", currentPrice: 125, accountID: broker.id)
        context.insert(etf)
        context.insert(InvestmentTrade(holdingID: etf.id, kind: .buy, date: day("2026-10-01"), quantity: 8, pricePerUnit: 100, fee: 0,
                                       cashAccountID: broker.id, cashAmount: 800))
        try context.save()
        let sources = try engine(now: day("2026-11-17")).portfolioSources
        #expect(sources.map(\.id) == ["manual"])
        #expect(sources[0].invested == 800 && sources[0].value == 1_000 && sources[0].costedValue == 1_000)
        #expect(sources[0].gain == 200 && sources[0].fraction == Decimal(string: "0.25")!)
    }

    @Test func historyIsBackedUpAndOldBackupsStillRestore() throws {
        context.insert(PortfolioSnapshot(date: day("2026-11-01"), currencyCode: "EUR", totalValue: 1_500, costedValue: 1_200,
                                         costBasis: 1_000, realized: 25))
        try context.save()
        let payload = try BackupService.makePayload(from: context, baseCurrency: "EUR")
        let data = try BackupPayload.encoder().encode(payload)
        let target = try Persistence.makeInMemoryContainer()
        try BackupService.restore(try BackupPayload.decoder().decode(BackupPayload.self, from: data), into: target.mainContext)
        let restored = try #require(try target.mainContext.fetch(FetchDescriptor<PortfolioSnapshot>()).first)
        #expect(restored.costedValue == 1_200 && restored.costBasis == 1_000 && restored.realized == 25 && restored.totalValue == 1_500)

        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "portfolioHistory")
        let old = try BackupPayload.decoder().decode(BackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
        let another = try Persistence.makeInMemoryContainer()
        try BackupService.restore(old, into: another.mainContext)
        #expect(try another.mainContext.fetchCount(FetchDescriptor<PortfolioSnapshot>()) == 0)
        try LedgerService.deleteAllData(in: target.mainContext)
        #expect(try target.mainContext.fetchCount(FetchDescriptor<PortfolioSnapshot>()) == 0)
    }

    @Test func reportNotificationIsOnTheFirstAtTen() {
        #expect(PlanningMonitor.reportDate(now: day("2026-11-17"), calendar: riga)
                == riga.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 10)))
    }
}
