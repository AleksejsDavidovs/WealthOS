import Foundation

/// A one-time future purchase paid from cash (then investments if cash runs out).
nonisolated struct OneTimePurchase: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var amount: Decimal
    var date: Date
}

/// A recurring future expense (e.g. rent increase, child care, car lease).
nonisolated struct FutureRecurringExpense: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var monthlyAmount: Decimal
    var startDate: Date
    /// Inclusive end month. `nil` means until the end of the projection.
    var endDate: Date?
    /// When true the amount grows with the scenario's inflation rate each projection year.
    var growsWithInflation: Bool = true
}

/// All user-configurable simulator assumptions. Rates are fractions (0.05 == 5 %).
nonisolated struct SimulationParameters: Codable, Equatable, Hashable, Sendable {
    var startingCash: Decimal
    var startingInvestments: Decimal
    var monthlyIncome: Decimal
    var monthlyExpenses: Decimal
    var salaryGrowth: Decimal
    var expenseGrowth: Decimal
    var monthlyContribution: Decimal
    var contributionGrowsWithSalary: Bool
    var annualReturn: Decimal
    var cashInterest: Decimal
    var inflation: Decimal
    /// Annual standard deviation of investment returns (Monte Carlo only).
    var volatility: Decimal
    var years: Int
    var oneTimePurchases: [OneTimePurchase]
    var recurringExpenses: [FutureRecurringExpense]

    var startingNetWorth: Decimal { startingCash + startingInvestments }

    static let yearRange: ClosedRange<Int> = 1...40

    /// Defaults for each preset scenario, seeded from the user's actual figures.
    static func preset(_ kind: ScenarioKind, startingCash: Decimal, startingInvestments: Decimal,
                       monthlyIncome: Decimal, monthlyExpenses: Decimal) -> SimulationParameters {
        let surplus = max(0, monthlyIncome - monthlyExpenses)
        let contribution = Money.round(surplus / 2, scale: 0)
        switch kind {
        case .conservative:
            return SimulationParameters(startingCash: startingCash, startingInvestments: startingInvestments,
                                        monthlyIncome: monthlyIncome, monthlyExpenses: monthlyExpenses,
                                        salaryGrowth: 0.015, expenseGrowth: 0.025, monthlyContribution: contribution,
                                        contributionGrowsWithSalary: false, annualReturn: 0.04, cashInterest: 0.01,
                                        inflation: 0.025, volatility: 0.10, years: 20, oneTimePurchases: [],
                                        recurringExpenses: [])
        case .balanced:
            return SimulationParameters(startingCash: startingCash, startingInvestments: startingInvestments,
                                        monthlyIncome: monthlyIncome, monthlyExpenses: monthlyExpenses,
                                        salaryGrowth: 0.025, expenseGrowth: 0.02, monthlyContribution: contribution,
                                        contributionGrowsWithSalary: true, annualReturn: 0.06, cashInterest: 0.015,
                                        inflation: 0.02, volatility: 0.15, years: 20, oneTimePurchases: [],
                                        recurringExpenses: [])
        case .optimistic:
            return SimulationParameters(startingCash: startingCash, startingInvestments: startingInvestments,
                                        monthlyIncome: monthlyIncome, monthlyExpenses: monthlyExpenses,
                                        salaryGrowth: 0.04, expenseGrowth: 0.02, monthlyContribution: contribution,
                                        contributionGrowsWithSalary: true, annualReturn: 0.08, cashInterest: 0.02,
                                        inflation: 0.02, volatility: 0.18, years: 20, oneTimePurchases: [],
                                        recurringExpenses: [])
        }
    }
}
