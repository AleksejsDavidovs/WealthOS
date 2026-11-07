import Foundation
import SwiftData
import Observation

@Observable
final class SimulatorViewModel {
    private(set) var scenarios: [ScenarioKind: SimulationScenario] = [:]
    var selectedKind: ScenarioKind = .balanced {
        didSet {
            guard oldValue != selectedKind else { return }
            // Flush pending edits of the previous scenario before switching.
            persistTask?.cancel()
            if let previous = scenarios[oldValue], previous.parameters != parameters {
                previous.parameters = parameters
                try? context?.save()
            }
            loadSelected()
        }
    }
    private(set) var parameters: SimulationParameters
    private(set) var projection: ProjectionResult
    private(set) var comparison: [ScenarioKind: ProjectionResult] = [:]

    private(set) var monteCarlo: MonteCarloResult?
    private(set) var isRunningMonteCarlo = false
    var monteCarloRuns = MonteCarloEngine.defaultRuns { didSet { scheduleMonteCarlo() } }
    var monteCarloTarget: Decimal = 100_000 { didSet { scheduleMonteCarlo() } }

    private var context: ModelContext?
    private var persistTask: Task<Void, Never>?
    private var monteCarloTask: Task<Void, Never>?
    private let startDate = Date.now

    init() {
        let empty = SimulationParameters.preset(.balanced, startingCash: 0, startingInvestments: 0, monthlyIncome: 0, monthlyExpenses: 0)
        parameters = empty
        projection = SimulationEngine.project(empty)
    }

    var isLoaded: Bool { context != nil }

    /// Loads (or creates) the three editable scenarios. New scenarios are seeded from the
    /// user's actual balances and recent cash flow, falling back to onboarding estimates.
    func load(context: ModelContext, engine: FinanceEngine) {
        self.context = context
        let existing = (try? context.fetch(FetchDescriptor<SimulationScenario>())) ?? []
        var byKind: [ScenarioKind: SimulationScenario] = [:]
        for scenario in existing where byKind[scenario.kind] == nil { byKind[scenario.kind] = scenario }
        let seed = Self.currentFigures(engine: engine)
        for kind in ScenarioKind.allCases where byKind[kind] == nil {
            let scenario = SimulationScenario(kind: kind, name: kind.title,
                                              parameters: .preset(kind, startingCash: seed.cash, startingInvestments: seed.investments,
                                                                  monthlyIncome: seed.income, monthlyExpenses: seed.expenses))
            context.insert(scenario)
            byKind[kind] = scenario
        }
        try? context.save()
        scenarios = byKind
        loadSelected()
    }

    static func currentFigures(engine: FinanceEngine) -> (cash: Decimal, investments: Decimal, income: Decimal, expenses: Decimal) {
        let summary = engine.summary
        let flow = engine.averageMonthlyFlow()
        let defaults = UserDefaults.standard
        let income = flow?.income ?? DecimalParser.parse(defaults.string(forKey: SettingsKey.estimatedIncome) ?? "")?.value ?? 0
        let expenses = flow?.expenses ?? DecimalParser.parse(defaults.string(forKey: SettingsKey.estimatedExpenses) ?? "")?.value ?? 0
        return (Money.round(summary.netWorth - summary.investments), Money.round(summary.investments), income, expenses)
    }

    /// Replaces starting balances and cash flow with the latest actual figures.
    func syncWithActualData(engine: FinanceEngine) {
        let figures = Self.currentFigures(engine: engine)
        update {
            $0.startingCash = figures.cash
            $0.startingInvestments = figures.investments
            if figures.income > 0 { $0.monthlyIncome = figures.income }
            if figures.expenses > 0 { $0.monthlyExpenses = figures.expenses }
        }
    }

    func resetSelectedToPreset(engine: FinanceEngine) {
        let figures = Self.currentFigures(engine: engine)
        update { $0 = .preset(selectedKind, startingCash: figures.cash, startingInvestments: figures.investments,
                              monthlyIncome: figures.income, monthlyExpenses: figures.expenses) }
    }

    func update(_ change: (inout SimulationParameters) -> Void) {
        var copy = parameters
        change(&copy)
        copy.years = min(max(copy.years, SimulationParameters.yearRange.lowerBound), SimulationParameters.yearRange.upperBound)
        guard copy != parameters else { return }
        parameters = copy
        recompute()
        schedulePersist()
        scheduleMonteCarlo()
    }

    private func loadSelected() {
        guard let scenario = scenarios[selectedKind], let stored = scenario.parameters else { return }
        parameters = stored
        recompute()
        recomputeComparison()
        monteCarlo = nil
        scheduleMonteCarlo(immediately: true)
    }

    private func recompute() {
        projection = SimulationEngine.project(parameters, startDate: startDate)
        comparison[selectedKind] = projection
    }

    /// Projects the other scenarios with the selected scenario's horizon so lines are comparable.
    func recomputeComparison() {
        for kind in ScenarioKind.allCases where kind != selectedKind {
            guard var other = scenarios[kind]?.parameters else { continue }
            other.years = parameters.years
            comparison[kind] = SimulationEngine.project(other, startDate: startDate)
        }
        comparison[selectedKind] = projection
    }

    private func schedulePersist() {
        persistTask?.cancel()
        let kind = selectedKind
        let snapshot = parameters
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, let scenario = self.scenarios[kind] else { return }
            scenario.parameters = snapshot
            try? self.context?.save()
        }
    }

    func scheduleMonteCarlo(immediately: Bool = false) {
        monteCarloTask?.cancel()
        let params = parameters
        let runs = monteCarloRuns
        let target = monteCarloTarget
        let start = startDate
        isRunningMonteCarlo = true
        monteCarloTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            let result = await MonteCarloEngine.runInBackground(params, runs: runs, seed: MonteCarloEngine.defaultSeed,
                                                                target: target, startDate: start)
            guard !Task.isCancelled, let self else { return }
            if let result { self.monteCarlo = result }
            self.isRunningMonteCarlo = false
        }
    }
}
