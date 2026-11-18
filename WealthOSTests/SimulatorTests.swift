import Foundation
import Testing
@testable import WealthOS

@Suite("Financial simulator")
struct SimulatorTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    var start: Date { calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))! }

    func params(cash: Decimal = 0, investments: Decimal = 0, income: Decimal = 0, expenses: Decimal = 0,
                contribution: Decimal = 0, ret: Decimal = 0, inflation: Decimal = 0, years: Int = 1) -> SimulationParameters {
        SimulationParameters(startingCash: cash, startingInvestments: investments, monthlyIncome: income, monthlyExpenses: expenses,
                             salaryGrowth: 0, expenseGrowth: 0, monthlyContribution: contribution, contributionGrowsWithSalary: false,
                             annualReturn: ret, cashInterest: 0, inflation: inflation, volatility: 0, years: years,
                             oneTimePurchases: [], recurringExpenses: [])
    }

    @Test func monthlyRateMatchesAnnualCompounding() {
        let rate = SimulationEngine.monthlyRate(fromAnnual: Decimal(string: "0.12")!)
        let annual = pow(1 + rate.doubleValue, 12) - 1
        #expect(abs(annual - 0.12) < 1e-9)
    }

    @Test func lumpSumCompoundsToAnnualRate() {
        let result = SimulationEngine.project(params(investments: 10_000, ret: Decimal(string: "0.12")!), startDate: start, calendar: calendar)
        let final = result.final!.netWorth
        #expect(abs((final - 11_200).doubleValue) < 0.1)
        #expect(result.totalContributions == 0)
        #expect(abs((result.totalGrowth - 1_200).doubleValue) < 0.1)
    }

    @Test func contributionsAreCappedAtSurplus() {
        // Planned 1,500 but only 1,000 surplus: invest 1,000/month, cash stays flat.
        let result = SimulationEngine.project(params(income: 3_000, expenses: 2_000, contribution: 1_500), startDate: start, calendar: calendar)
        #expect(result.final!.investments == 12_000)
        #expect(result.final!.cash == 0)
        #expect(result.totalContributions == 12_000)
    }

    @Test func surplusIsCountedOnce() {
        // 1,000 surplus, 400 invested: cash +600, investments +400. Net worth +1,000/month.
        let result = SimulationEngine.project(params(income: 3_000, expenses: 2_000, contribution: 400), startDate: start, calendar: calendar)
        #expect(result.final!.netWorth == 12_000)
        #expect(result.final!.cash == 7_200)
        #expect(result.final!.investments == 4_800)
    }

    @Test func contributionTimingIsEndOfMonth() {
        // One month, 12% return, 1,000 contributed at month end: no growth on it yet.
        var p = params(income: 1_000, contribution: 1_000, ret: Decimal(string: "0.12")!)
        p.years = 1
        let result = SimulationEngine.project(p, startDate: start, calendar: calendar)
        #expect(result.points[1].investments == 1_000)
        #expect(result.points[2].investments > 2_000)
    }

    @Test func purchasesDrawCashThenInvestments() {
        var p = params(cash: 1_000, investments: 10_000)
        p.oneTimePurchases = [OneTimePurchase(name: "Car", amount: 5_000, date: calendar.date(byAdding: .month, value: 1, to: start)!)]
        let result = SimulationEngine.project(p, startDate: start, calendar: calendar)
        #expect(result.points[1].cash == 0)
        #expect(result.points[1].investments == 6_000)
        #expect(result.totalWithdrawals == 4_000)
        #expect(result.shortfallMonths == 0)
    }

    @Test func shortfallIsReported() {
        let result = SimulationEngine.project(params(cash: 100, expenses: 200), startDate: start, calendar: calendar)
        #expect(result.shortfallMonths == 12)
        #expect(result.final!.netWorth == -2_300)
    }

    @Test func realValueIsDeflated() {
        let result = SimulationEngine.project(params(cash: 10_000, inflation: Decimal(string: "0.02")!), startDate: start, calendar: calendar)
        #expect(result.final!.netWorth == 10_000)
        #expect(abs((result.final!.realNetWorth - Decimal(string: "9803.92")!).doubleValue) < 0.01)
    }

    @Test func salaryGrowthStepsYearly() {
        var p = params(income: 1_000, years: 2)
        p.salaryGrowth = Decimal(string: "0.10")!
        let result = SimulationEngine.project(p, startDate: start, calendar: calendar)
        #expect(result.years[0].income == 12_000)
        #expect(result.years[1].income == 13_200)
    }

    @Test func recurringFutureExpensesApplyInRange() {
        var p = params(cash: 10_000, years: 1)
        p.recurringExpenses = [FutureRecurringExpense(name: "Lease", monthlyAmount: 100,
                                                      startDate: calendar.date(byAdding: .month, value: 3, to: start)!,
                                                      endDate: calendar.date(byAdding: .month, value: 5, to: start)!,
                                                      growsWithInflation: false)]
        let result = SimulationEngine.project(p, startDate: start, calendar: calendar)
        #expect(result.final!.netWorth == 9_700)
    }

    @Test func milestones() {
        let result = SimulationEngine.project(params(cash: 15_000, income: 1_000, years: 5), startDate: start, calendar: calendar)
        let byThreshold = Dictionary(uniqueKeysWithValues: result.milestones.map { ($0.threshold, $0) })
        #expect(byThreshold[10_000]?.isAlreadyReached == true)
        #expect(byThreshold[20_000]?.month == 5)
        #expect(byThreshold[50_000]?.month == 35)
        #expect(byThreshold[100_000]?.month == nil)
    }

    @Test func monteCarloWithZeroVolatilityMatchesDeterministic() throws {
        var p = params(cash: 2_000, investments: 20_000, income: 4_000, expenses: 3_000, contribution: 500,
                       ret: Decimal(string: "0.06")!, years: 10)
        p.volatility = 0
        let deterministic = SimulationEngine.project(p, startDate: start, calendar: calendar)
        let mc = try #require(MonteCarloEngine.run(p, runs: 50, seed: 1, target: 100_000, startDate: start, calendar: calendar))
        let final = try #require(mc.final)
        #expect(abs(final.p50 - deterministic.final!.netWorth.doubleValue) < 5)
        #expect(abs(final.p10 - final.p90) < 0.001)
    }

    @Test func monteCarloIsReproducibleAndOrdered() throws {
        var p = params(investments: 50_000, income: 3_000, expenses: 2_000, contribution: 800, ret: Decimal(string: "0.07")!, years: 20)
        p.volatility = Decimal(string: "0.18")!
        let a = try #require(MonteCarloEngine.run(p, runs: 400, seed: 99, target: 300_000, startDate: start, calendar: calendar))
        let b = try #require(MonteCarloEngine.run(p, runs: 400, seed: 99, target: 300_000, startDate: start, calendar: calendar))
        #expect(a == b)
        for band in a.bands {
            #expect(band.p10 <= band.p50)
            #expect(band.p50 <= band.p90)
        }
        #expect((0...1).contains(a.probabilityOfTarget))
        let c = try #require(MonteCarloEngine.run(p, runs: 400, seed: 100, target: 300_000, startDate: start, calendar: calendar))
        #expect(a.final != c.final)
    }

    @Test func seededGeneratorIsDeterministicAndNormal() {
        var g1 = SeededGenerator(seed: 7)
        var g2 = SeededGenerator(seed: 7)
        #expect((0..<10).map { _ in g1.next() } == (0..<10).map { _ in g2.next() })
        var g = SeededGenerator(seed: 123)
        let samples = (0..<20_000).map { _ in g.nextGaussian() }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(samples.count)
        #expect(abs(mean) < 0.03)
        #expect(abs(variance - 1) < 0.05)
    }

    @Test func percentileInterpolation() {
        let values = [1.0, 2, 3, 4, 5]
        #expect(MonteCarloEngine.percentile(values, 0.5) == 3)
        #expect(MonteCarloEngine.percentile(values, 0.1) == 1.4)
        #expect(MonteCarloEngine.percentile(values, 0.9) == 4.6)
    }

    @Test func clampedRepairsRunawayAmounts() {
        var p = params(cash: -5_000_000_000_000, investments: 9_000_000_000_000, income: 3_000_000_000_000,
                       expenses: 2_500_000_000_000, contribution: 1_000_000_000_000, years: 99)
        p = p.clamped
        #expect(p.monthlyIncome == SimulationParameters.maxMonthlyAmount)
        #expect(p.monthlyExpenses == SimulationParameters.maxMonthlyAmount)
        #expect(p.monthlyContribution == SimulationParameters.maxMonthlyAmount)
        #expect(p.startingCash == -SimulationParameters.maxStartingBalance)
        #expect(p.startingInvestments == SimulationParameters.maxStartingBalance)
        #expect(p.years == SimulationParameters.yearRange.upperBound)
        #expect(params(income: 4_000, expenses: 3_000).clamped == params(income: 4_000, expenses: 3_000))
    }
}
