import Foundation

nonisolated struct ProjectionPoint: Identifiable, Sendable, Equatable {
    /// Months since the start of the projection (0 = today).
    let month: Int
    let date: Date
    let cash: Decimal
    let investments: Decimal
    let netWorth: Decimal
    /// Net worth expressed in today's money (deflated by cumulative inflation).
    let realNetWorth: Decimal
    let cumulativeContributions: Decimal
    let cumulativeGrowth: Decimal
    var id: Int { month }
}

nonisolated struct YearSummary: Identifiable, Sendable, Equatable {
    let year: Int
    let date: Date
    let netWorth: Decimal
    let realNetWorth: Decimal
    let cash: Decimal
    let investments: Decimal
    let income: Decimal
    let expenses: Decimal
    let contributions: Decimal
    let growth: Decimal
    var id: Int { year }
}

nonisolated struct MilestoneResult: Identifiable, Sendable, Equatable {
    let threshold: Decimal
    /// Month in which nominal net worth first reached the threshold (0 = already reached).
    let month: Int?
    let date: Date?
    var id: Decimal { threshold }
    var isAlreadyReached: Bool { month == 0 }
}

nonisolated struct ProjectionResult: Sendable, Equatable {
    let points: [ProjectionPoint]
    let years: [YearSummary]
    let milestones: [MilestoneResult]
    let totalContributions: Decimal
    let totalGrowth: Decimal
    let totalCashInterest: Decimal
    let totalWithdrawals: Decimal
    /// Months where cash and investments were both exhausted (projected debt).
    let shortfallMonths: Int

    var final: ProjectionPoint? { points.last }
}

/// Deterministic month-by-month projection.
///
/// Conventions (applied identically by `MonteCarloEngine`):
/// 1. Time step is one calendar month. Month 0 is today's balances.
/// 2. Annual rates convert to effective monthly rates: r_m = (1 + r)^(1/12) - 1.
/// 3. Growth is applied to the balance at the *start* of each month.
/// 4. Income, expenses and contributions occur at the *end* of each month
///    (ordinary annuity), so a contribution earns returns from the next month.
/// 5. Salary and expense growth step up once per projection year (months 13, 25, …).
/// 6. Contributions are funded only from that month's surplus:
///    contribution = min(planned, max(0, income − expenses − recurring)).
///    The remaining surplus (or deficit) changes cash. Money is never counted twice.
/// 7. One-time purchases are paid at the end of their month from cash.
/// 8. If cash becomes negative, investments are sold to cover the gap. If both
///    are exhausted, cash stays negative (projected debt, no interest modelled).
/// 9. Real values = nominal / (1 + inflation)^(month / 12).
nonisolated enum SimulationEngine {
    static let milestoneThresholds: [Decimal] = [10_000, 20_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]

    static func monthlyRate(fromAnnual annual: Decimal) -> Decimal {
        let value = pow(1 + annual.doubleValue, 1.0 / 12.0) - 1
        return Money.decimal(from: value, scale: 12)
    }

    static func monthsBetween(_ start: Date, _ end: Date, calendar: Calendar) -> Int {
        let startMonth = calendar.dateComponents([.year, .month], from: start)
        let endMonth = calendar.dateComponents([.year, .month], from: end)
        return ((endMonth.year ?? 0) - (startMonth.year ?? 0)) * 12 + ((endMonth.month ?? 0) - (startMonth.month ?? 0))
    }

    /// Precomputed month-indexed cash flows shared by the deterministic and Monte Carlo engines.
    struct CashFlowSchedule: Sendable {
        let income: [Decimal]
        let expenses: [Decimal]
        let recurring: [Decimal]
        let plannedContribution: [Decimal]
        let purchases: [Decimal]
    }

    static func schedule(for p: SimulationParameters, startDate: Date, calendar: Calendar = .current) -> CashFlowSchedule {
        let months = max(1, p.years) * 12
        var income: [Decimal] = [0]
        var expenses: [Decimal] = [0]
        var recurring: [Decimal] = [0]
        var contribution: [Decimal] = [0]
        var purchases = [Decimal](repeating: 0, count: months + 1)

        for purchase in p.oneTimePurchases where purchase.amount > 0 {
            // A purchase in the current month is paid at the end of month 1.
            let offset = max(1, monthsBetween(startDate, purchase.date, calendar: calendar))
            if offset <= months { purchases[offset] += purchase.amount }
        }

        // Factors step up once per projection year: factor_y = (1 + g)^y, rounded to 10 places.
        var salaryFactor: Decimal = 1
        var expenseFactor: Decimal = 1
        var inflationFactor: Decimal = 1
        let recurringRanges = p.recurringExpenses.filter { $0.monthlyAmount > 0 }.map { item in
            (item, max(1, monthsBetween(startDate, item.startDate, calendar: calendar)),
             item.endDate.map { monthsBetween(startDate, $0, calendar: calendar) } ?? Int.max)
        }
        for month in 1...months {
            if month > 1 && (month - 1) % 12 == 0 {
                salaryFactor = Money.round(salaryFactor * (1 + p.salaryGrowth), scale: 10)
                expenseFactor = Money.round(expenseFactor * (1 + p.expenseGrowth), scale: 10)
                inflationFactor = Money.round(inflationFactor * (1 + p.inflation), scale: 10)
            }
            income.append(Money.round(p.monthlyIncome * salaryFactor))
            expenses.append(Money.round(p.monthlyExpenses * expenseFactor))
            contribution.append(Money.round(p.monthlyContribution * (p.contributionGrowsWithSalary ? salaryFactor : 1)))

            var recurringTotal: Decimal = 0
            for (item, start, end) in recurringRanges {
                if month >= start && month <= end {
                    recurringTotal += item.monthlyAmount * (item.growsWithInflation ? inflationFactor : 1)
                }
            }
            recurring.append(Money.round(recurringTotal))
        }
        return CashFlowSchedule(income: income, expenses: expenses, recurring: recurring,
                                plannedContribution: contribution, purchases: purchases)
    }

    static func project(_ p: SimulationParameters, startDate: Date = .now, calendar: Calendar = .current) -> ProjectionResult {
        let months = max(1, p.years) * 12
        let flows = schedule(for: p, startDate: startDate, calendar: calendar)
        let investmentRate = monthlyRate(fromAnnual: p.annualReturn)
        let cashRate = monthlyRate(fromAnnual: p.cashInterest)
        let monthStart = calendar.dateInterval(of: .month, for: startDate)?.start ?? startDate

        var cash = p.startingCash
        var investments = p.startingInvestments
        var cumulativeContributions: Decimal = 0
        var cumulativeGrowth: Decimal = 0
        var cumulativeInterest: Decimal = 0
        var withdrawals: Decimal = 0
        var shortfallMonths = 0

        var points: [ProjectionPoint] = [
            ProjectionPoint(month: 0, date: startDate, cash: cash, investments: investments,
                            netWorth: cash + investments, realNetWorth: cash + investments,
                            cumulativeContributions: 0, cumulativeGrowth: 0)
        ]
        points.reserveCapacity(months + 1)
        var years: [YearSummary] = []
        var yearIncome: Decimal = 0, yearExpenses: Decimal = 0, yearContributions: Decimal = 0, yearGrowth: Decimal = 0

        for month in 1...months {
            // 1. Growth on opening balances.
            let growth = investments > 0 ? Money.round(investments * investmentRate) : 0
            investments += growth
            cumulativeGrowth += growth
            let interest = cash > 0 ? Money.round(cash * cashRate) : 0
            cash += interest
            cumulativeInterest += interest

            // 2. End-of-month cash flows.
            let outflow = flows.expenses[month] + flows.recurring[month]
            let surplus = flows.income[month] - outflow
            let contribution = max(0, min(flows.plannedContribution[month], surplus))
            cash += surplus - contribution
            investments += contribution
            cumulativeContributions += contribution

            // 3. One-time purchases.
            cash -= flows.purchases[month]

            // 4. Cover negative cash by selling investments.
            if cash < 0 && investments > 0 {
                let draw = min(-cash, investments)
                investments -= draw
                cash += draw
                withdrawals += draw
            }
            if cash < 0 { shortfallMonths += 1 }

            let netWorth = cash + investments
            let deflator = Money.decimal(from: pow(1 + p.inflation.doubleValue, Double(month) / 12.0), scale: 10)
            let real = deflator > 0 ? Money.round(netWorth / deflator) : netWorth
            let date = calendar.date(byAdding: .month, value: month, to: monthStart) ?? startDate
            points.append(ProjectionPoint(month: month, date: date, cash: cash, investments: investments,
                                          netWorth: netWorth, realNetWorth: real,
                                          cumulativeContributions: cumulativeContributions,
                                          cumulativeGrowth: cumulativeGrowth))

            yearIncome += flows.income[month]
            yearExpenses += outflow + flows.purchases[month]
            yearContributions += contribution
            yearGrowth += growth + interest
            if month % 12 == 0 {
                years.append(YearSummary(year: month / 12, date: date, netWorth: netWorth, realNetWorth: real,
                                         cash: cash, investments: investments, income: yearIncome,
                                         expenses: yearExpenses, contributions: yearContributions, growth: yearGrowth))
                yearIncome = 0; yearExpenses = 0; yearContributions = 0; yearGrowth = 0
            }
        }

        let milestones = milestoneThresholds.map { threshold -> MilestoneResult in
            if let point = points.first(where: { $0.netWorth >= threshold }) {
                return MilestoneResult(threshold: threshold, month: point.month, date: point.month == 0 ? nil : point.date)
            }
            return MilestoneResult(threshold: threshold, month: nil, date: nil)
        }

        return ProjectionResult(points: points, years: years, milestones: milestones,
                                totalContributions: cumulativeContributions, totalGrowth: cumulativeGrowth,
                                totalCashInterest: cumulativeInterest, totalWithdrawals: withdrawals,
                                shortfallMonths: shortfallMonths)
    }
}
