import SwiftUI
import SwiftData
import Charts

struct SimulatorView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @State private var model = SimulatorViewModel()
    @State private var chartMode: ChartMode = .netWorth
    @State private var selectedDate: Date?
    @State private var showEditor = false
    @State private var showMethodology = false
    @State private var showSyncConfirmation = false
    /// "Keep mine" for these exact live figures; any further change to the data shows the card again.
    @State private var dismissedLiveBalances: SimulatorViewModel.StartingBalances?

    enum ChartMode: String, CaseIterable, Identifiable {
        case netWorth = "Net Worth", composition = "Composition", compare = "Compare"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            FinanceReader { engine in
                ScrollView {
                    VStack(spacing: 20) {
                        if app.isDemoMode { DemoBanner() }
                        InfoBanner(text: "Estimates based on your assumptions — not a prediction or guarantee. Investment returns vary and can be negative.",
                                   symbol: "exclamationmark.bubble.fill", tint: .orange)
                        scenarioPicker
                        if model.isLoaded, !engine.summary.isComplete {
                            // Live starting values equal the (incomplete) current totals → warn about
                            // them; otherwise the scenario uses custom inputs and only an update would.
                            ValuationCompletenessBanner(
                                summary: engine.summary,
                                subject: SimulatorViewModel.liveBalancesIfChanged(engine.summary, parameters: model.parameters) == nil
                                    ? "the starting values taken from your current data"
                                    : "your current data (your custom starting values are unaffected; updating from current data would use these lower bounds)")
                        }
                        if model.isLoaded,
                           let live = SimulatorViewModel.liveBalancesIfChanged(engine.summary, parameters: model.parameters),
                           live != dismissedLiveBalances {
                            liveDataCard(live)
                        }
                        headline
                        chartCard
                        controlsCard
                        milestonesCard
                        MonteCarloCard(model: model, code: baseCurrency)
                        breakdownLink
                        assumptionsCard
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .screenBackground()
                .onAppear {
                    if !model.isLoaded { model.load(context: context, engine: engine) }
                }
                .confirmationDialog("Use your current data?", isPresented: $showSyncConfirmation, titleVisibility: .visible) {
                    Button("Update Starting Values") { model.syncWithActualData(engine: engine) }
                    Button("Reset Scenario to Defaults", role: .destructive) { model.resetSelectedToPreset(engine: engine) }
                } message: {
                    Text("Starting cash, investments, income and expenses will be replaced with figures from your accounts and the last 3 months of transactions.")
                }
            }
            .navigationTitle("Simulator")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSyncConfirmation = true } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .accessibilityLabel("Sync with current data")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { showEditor = true }
                }
            }
            .sheet(isPresented: $showEditor) {
                ScenarioEditorView(parameters: model.parameters, title: model.selectedKind.title) { updated in
                    model.update { $0 = updated }
                    model.recomputeComparison()
                }
            }
            .sheet(isPresented: $showMethodology) { MethodologyView() }
        }
    }

    // MARK: Sections

    private func liveDataCard(_ live: SimulatorViewModel.StartingBalances) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your balances changed", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
            Text("This scenario starts from \(MoneyFormat.string(model.parameters.startingCash, code: baseCurrency, fractionDigits: 0)) cash and \(MoneyFormat.string(model.parameters.startingInvestments, code: baseCurrency, fractionDigits: 0)) investments. Your accounts now show \(MoneyFormat.string(live.cash, code: baseCurrency, fractionDigits: 0)) and \(MoneyFormat.string(live.investments, code: baseCurrency, fractionDigits: 0)).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Use Current Balances") { model.applyLiveStartingBalances(live) }
                    .buttonStyle(.borderedProminent).tint(Theme.accentFill)
                Button("Keep Scenario Values") { dismissedLiveBalances = live }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .card(padding: 14)
    }

    private var scenarioPicker: some View {
        Picker("Scenario", selection: $model.selectedKind) {
            ForEach(ScenarioKind.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .sensoryFeedback(.selection, trigger: model.selectedKind)
    }

    private var headline: some View {
        let final = model.projection.final
        let years = model.parameters.years
        return VStack(alignment: .leading, spacing: 12) {
            Text("Projected net worth in \(years) year\(years == 1 ? "" : "s")")
                .font(.subheadline).foregroundStyle(.white.opacity(0.8))
            Text(MoneyFormat.string(final?.netWorth ?? 0, code: baseCurrency, fractionDigits: 0))
                .scaledFont(38)
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText(value: final?.netWorth.doubleValue ?? 0))
                .animation(.spring(response: 0.4), value: final?.netWorth)
            Text("≈ \(MoneyFormat.string(final?.realNetWorth ?? 0, code: baseCurrency, fractionDigits: 0)) in today's money")
                .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85)).monospacedDigit()
            Divider().overlay(Color.white.opacity(0.2))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    heroMetric("Cash", final?.cash ?? 0)
                    heroMetric("Investments", final?.investments ?? 0)
                }
                GridRow {
                    heroMetric("Contributed", model.projection.totalContributions)
                    heroMetric("Investment growth", model.projection.totalGrowth)
                }
            }
            if model.projection.shortfallMonths > 0 {
                Label("Money runs out in \(model.projection.shortfallMonths) projected month(s). Review expenses or purchases.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.25, green: 0.15, blue: 0.45), Color(red: 0.06, green: 0.12, blue: 0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func heroMetric(_ title: String, _ value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.78))
            Text(MoneyFormat.string(value, code: baseCurrency, fractionDigits: 0))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedPoint: ProjectionPoint? {
        guard let selectedDate else { return nil }
        return model.projection.points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Chart", selection: $chartMode) {
                ForEach(ChartMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Group {
                if let point = selectedPoint {
                    Text("\(point.date.formatted(.dateTime.month(.abbreviated).year())): \(MoneyFormat.string(point.netWorth, code: baseCurrency, fractionDigits: 0)) nominal · \(MoneyFormat.string(point.realNetWorth, code: baseCurrency, fractionDigits: 0)) real")
                } else {
                    Text("Drag across the chart to inspect a date.")
                }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()

            chart
                .frame(height: 240)
                .chartXSelection(value: $selectedDate)
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel { if let v = value.as(Double.self) { Text(MoneyFormat.compact(v, code: baseCurrency)) } }
                    }
                }
                .animation(.spring(response: 0.45), value: model.parameters)
                .accessibilityLabel("Projection chart")
                .accessibilityValue("Final projected net worth \(MoneyFormat.string(model.projection.final?.netWorth ?? 0, code: baseCurrency))")
            Text("Projection — simulated, not recorded history.").font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    /// Keeps chart rendering light: monthly points for short horizons, quarterly beyond 10 years.
    private func sampled(_ points: [ProjectionPoint]) -> [ProjectionPoint] {
        let stride = points.count > 121 ? 3 : 1
        return points.enumerated().filter { $0.offset % stride == 0 || $0.offset == points.count - 1 }.map(\.element)
    }

    @ChartContentBuilder
    private var chartContent: some ChartContent {
        switch chartMode {
        case .netWorth:
            ForEach(sampled(model.projection.points)) { point in
                LineMark(x: .value("Date", point.date), y: .value("Value", point.netWorth.doubleValue), series: .value("Series", "Nominal"))
                    .foregroundStyle(by: .value("Series", "Nominal"))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", point.date), y: .value("Value", point.realNetWorth.doubleValue), series: .value("Series", "Real"))
                    .foregroundStyle(by: .value("Series", "Real (today's money)"))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .interpolationMethod(.monotone)
            }
        case .composition:
            ForEach(sampled(model.projection.points)) { point in
                AreaMark(x: .value("Date", point.date), y: .value("Value", point.investments.doubleValue))
                    .foregroundStyle(by: .value("Series", "Investments"))
                AreaMark(x: .value("Date", point.date), y: .value("Value", point.cash.doubleValue))
                    .foregroundStyle(by: .value("Series", "Cash"))
            }
        case .compare:
            ForEach(ScenarioKind.allCases) { kind in
                if let result = model.comparison[kind] {
                    ForEach(sampled(result.points)) { point in
                        LineMark(x: .value("Date", point.date), y: .value("Value", point.netWorth.doubleValue),
                                 series: .value("Scenario", kind.title))
                            .foregroundStyle(by: .value("Scenario", kind.title))
                            .lineStyle(StrokeStyle(lineWidth: kind == model.selectedKind ? 3 : 1.5))
                            .interpolationMethod(.monotone)
                    }
                }
            }
        }
        if let point = selectedPoint {
            RuleMark(x: .value("Selected", point.date))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch chartMode {
        case .netWorth:
            Chart { chartContent }
                .chartForegroundStyleScale(["Nominal": Theme.accent, "Real (today's money)": Color.purple])
        case .composition:
            Chart { chartContent }
                .chartForegroundStyleScale(["Investments": Color.purple.opacity(0.8), "Cash": Color.blue.opacity(0.7)])
        case .compare:
            Chart { chartContent }
                .chartForegroundStyleScale([ScenarioKind.conservative.title: Color.orange,
                                            ScenarioKind.balanced.title: Color.blue,
                                            ScenarioKind.optimistic.title: Color.green])
                .onAppear { model.recomputeComparison() }
        }
    }

    private var controlsCard: some View {
        let p = model.parameters
        let incomeMax = max(10_000, (p.monthlyIncome.doubleValue * 2).rounded())
        let expenseMax = max(10_000, (p.monthlyExpenses.doubleValue * 2).rounded())
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Assumptions").font(.headline)
                Spacer()
                Button("Precise Edit") { showEditor = true }.font(.subheadline)
            }
            ParameterSlider(title: "Projection length", valueText: "\(p.years) years",
                            value: Binding(get: { Double(p.years) }, set: { v in model.update { $0.years = Int(v.rounded()) } }),
                            range: 1...40, step: 1)
            ParameterSlider(title: "Monthly income", valueText: MoneyFormat.string(p.monthlyIncome, code: baseCurrency, fractionDigits: 0),
                            value: money(\.monthlyIncome), range: 0...incomeMax, step: 50)
            ParameterSlider(title: "Monthly expenses", valueText: MoneyFormat.string(p.monthlyExpenses, code: baseCurrency, fractionDigits: 0),
                            value: money(\.monthlyExpenses), range: 0...expenseMax, step: 50)
            ParameterSlider(title: "Monthly investing", valueText: MoneyFormat.string(p.monthlyContribution, code: baseCurrency, fractionDigits: 0),
                            value: money(\.monthlyContribution), range: 0...max(5_000, incomeMax / 2), step: 25,
                            footnote: contributionFootnote)
            ParameterSlider(title: "Expected annual return", valueText: MoneyFormat.percent(p.annualReturn),
                            value: percent(\.annualReturn), range: -0.05...0.15, step: 0.0025)
            ParameterSlider(title: "Salary growth", valueText: MoneyFormat.percent(p.salaryGrowth),
                            value: percent(\.salaryGrowth), range: -0.05...0.10, step: 0.0025)
            ParameterSlider(title: "Expense growth", valueText: MoneyFormat.percent(p.expenseGrowth),
                            value: percent(\.expenseGrowth), range: -0.05...0.10, step: 0.0025)
            ParameterSlider(title: "Inflation", valueText: MoneyFormat.percent(p.inflation),
                            value: percent(\.inflation), range: 0...0.10, step: 0.0025)
            ParameterSlider(title: "Return volatility (Monte Carlo)", valueText: MoneyFormat.percent(p.volatility),
                            value: percent(\.volatility), range: 0...0.40, step: 0.005)
        }
        .card()
    }

    private var contributionFootnote: String? {
        let p = model.parameters
        let surplus = p.monthlyIncome - p.monthlyExpenses
        if p.monthlyContribution > surplus {
            return "Exceeds today's surplus of \(MoneyFormat.string(max(0, surplus), code: baseCurrency, fractionDigits: 0)); only the surplus can be invested."
        }
        return nil
    }

    private func money(_ keyPath: WritableKeyPath<SimulationParameters, Decimal>) -> Binding<Double> {
        Binding(get: { model.parameters[keyPath: keyPath].doubleValue },
                set: { value in model.update { $0[keyPath: keyPath] = Money.decimal(from: value, scale: 0) } })
    }

    private func percent(_ keyPath: WritableKeyPath<SimulationParameters, Decimal>) -> Binding<Double> {
        Binding(get: { model.parameters[keyPath: keyPath].doubleValue },
                set: { value in model.update { $0[keyPath: keyPath] = Money.decimal(from: value, scale: 4) } })
    }

    private var milestonesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Milestones").font(.headline)
            ForEach(model.projection.milestones) { milestone in
                HStack {
                    Image(systemName: milestone.month == nil ? "circle.dashed" : "checkmark.seal.fill")
                        .foregroundStyle(milestone.month == nil ? Color.secondary : Theme.accent)
                    Text(MoneyFormat.string(milestone.threshold, code: baseCurrency, fractionDigits: 0))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    Spacer()
                    Group {
                        if milestone.isAlreadyReached {
                            Text("Already reached")
                        } else if let date = milestone.date, let month = milestone.month {
                            Text("\(date.formatted(.dateTime.month(.abbreviated).year())) · \(durationText(month))")
                        } else {
                            Text("Not within \(model.parameters.years) years")
                        }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Text("Estimated dates when projected nominal net worth first reaches each amount.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private func durationText(_ months: Int) -> String {
        let years = months / 12, rest = months % 12
        if years == 0 { return "\(rest) mo" }
        return rest == 0 ? "\(years) yr" : "\(years) yr \(rest) mo"
    }

    private var breakdownLink: some View {
        NavigationLink {
            YearlyBreakdownView(years: model.projection.years, code: baseCurrency)
        } label: {
            HStack {
                IconBadge(symbol: "tablecells", color: .indigo)
                VStack(alignment: .leading) {
                    Text("Yearly Breakdown").font(.headline)
                    Text("Income, expenses, contributions and growth per year").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .card(padding: 14)
        }
        .buttonStyle(.plain)
    }

    private var assumptionsCard: some View {
        let p = model.parameters
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("All Assumptions").font(.headline)
                Spacer()
                Button("How it works") { showMethodology = true }.font(.subheadline)
            }
            Group {
                assumption("Starting cash & other", MoneyFormat.string(p.startingCash, code: baseCurrency))
                assumption("Starting investments", MoneyFormat.string(p.startingInvestments, code: baseCurrency))
                assumption("Cash interest", MoneyFormat.percent(p.cashInterest))
                assumption("Contribution grows with salary", p.contributionGrowsWithSalary ? "Yes" : "No")
                assumption("One-time purchases", p.oneTimePurchases.isEmpty ? "None" :
                            p.oneTimePurchases.map { "\($0.name) \(MoneyFormat.string($0.amount, code: baseCurrency, fractionDigits: 0)) (\($0.date.formatted(.dateTime.month(.abbreviated).year())))" }.joined(separator: ", "))
                assumption("Recurring future expenses", p.recurringExpenses.isEmpty ? "None" :
                            p.recurringExpenses.map { "\($0.name) \(MoneyFormat.string($0.monthlyAmount, code: baseCurrency, fractionDigits: 0))/mo" }.joined(separator: ", "))
                assumption("Compounding", "Monthly, r_m = (1+r)^(1/12) − 1")
                assumption("Contribution timing", "End of month, from surplus only")
            }
        }
        .card()
    }

    private func assumption(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.footnote.weight(.medium)).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ParameterSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(valueText).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { value = $0 }),
                   in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }
}

struct MonteCarloCard: View {
    let model: SimulatorViewModel
    let code: String
    @State private var targetText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monte Carlo").font(.headline)
                    Text("\(model.monteCarloRuns.formatted()) simulated market paths · \(MoneyFormat.percent(model.parameters.volatility)) volatility")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isRunningMonteCarlo { ProgressView().controlSize(.small) }
            }

            if let result = model.monteCarlo {
                Chart(result.bands) { band in
                    AreaMark(x: .value("Date", band.date), yStart: .value("10th", band.p10), yEnd: .value("90th", band.p90))
                        .foregroundStyle(Theme.projection.opacity(0.2))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", band.date), y: .value("Median", band.p50))
                        .foregroundStyle(Theme.projection)
                        .interpolationMethod(.monotone)
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel { if let v = value.as(Double.self) { Text(MoneyFormat.compact(v, code: code)) } }
                    }
                }
                .frame(height: 180)
                .opacity(model.isRunningMonteCarlo ? 0.5 : 1)
                .accessibilityLabel("Range of outcomes chart")

                if let final = result.final {
                    HStack(spacing: 0) {
                        outcome("Pessimistic\n10th pct.", final.p10, Theme.warning)
                        outcome("Median\n50th pct.", final.p50, Theme.projection)
                        outcome("Optimistic\n90th pct.", final.p90, Theme.positive)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Target").font(.subheadline)
                        Spacer()
                        TextField(MoneyFormat.string(model.monteCarloTarget, code: code, fractionDigits: 0), text: $targetText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 150)
                            .onSubmit(applyTarget)
                            .onChange(of: targetText) { _, _ in applyTarget() }
                            .accessibilityLabel("Target net worth")
                    }
                    HStack {
                        Text("Chance of reaching it by \(model.parameters.years) years")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text(result.probabilityOfTarget.formatted(.percent.precision(.fractionLength(0))))
                            .font(.title3.weight(.bold)).monospacedDigit()
                            .foregroundStyle(Theme.accent)
                            .contentTransition(.numericText(value: result.probabilityOfTarget))
                    }
                    if result.probabilityOfShortfall > 0 {
                        Text("In \(result.probabilityOfShortfall.formatted(.percent.precision(.fractionLength(0)))) of paths net worth turned negative at some point.")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                }
                Picker("Simulations", selection: Binding(get: { model.monteCarloRuns }, set: { model.monteCarloRuns = $0 })) {
                    Text("500").tag(500)
                    Text("1,000").tag(1_000)
                    Text("2,000").tag(2_000)
                    Text("5,000").tag(5_000)
                }
                .pickerStyle(.segmented)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.2)).frame(height: 180)
                    Text("Calculating 10th, 50th and 90th percentile outcomes").font(.subheadline)
                }
                .skeleton(true)
            }

            Text("Each path draws random monthly returns (lognormal, seeded and reproducible). Percentiles show a range of plausible outcomes under your assumptions — real markets can do better or worse.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private func applyTarget() {
        if let value = AmountValidation.money(targetText).value { model.monteCarloTarget = value }
    }

    private func outcome(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text(MoneyFormat.compact(value, code: code)).font(.headline).monospacedDigit().foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct YearlyBreakdownView: View {
    let years: [YearSummary]
    let code: String

    var body: some View {
        List(years) { year in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Year \(year.year)").font(.headline)
                    Text(year.date.formatted(.dateTime.year())).foregroundStyle(.secondary)
                    Spacer()
                    Text(MoneyFormat.string(year.netWorth, code: code, fractionDigits: 0)).font(.headline).monospacedDigit()
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        cell("Real", year.realNetWorth)
                        cell("Cash", year.cash)
                        cell("Invested", year.investments)
                    }
                    GridRow {
                        cell("Income", year.income)
                        cell("Spending", year.expenses)
                        cell("Contributed", year.contributions)
                    }
                    GridRow {
                        cell("Growth", year.growth)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
        .navigationTitle("Yearly Breakdown")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func cell(_ title: String, _ value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(MoneyFormat.compact(value.doubleValue, code: code)).font(.caption.weight(.medium)).monospacedDigit()
        }
    }
}

struct MethodologyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Time step", "The projection runs month by month. Month 0 is today's starting balances.")
                    section("Compounding", "Annual rates are converted to an equivalent monthly rate: r_m = (1 + r)^(1/12) − 1. Growth is applied to the balance at the start of each month.")
                    section("Cash flow timing", "Income, expenses and contributions happen at the end of each month. A contribution starts earning returns the following month.")
                    section("No double counting", "Each month: surplus = income − expenses − recurring future expenses. Contribution = min(planned contribution, surplus), never more. The rest of the surplus (or a deficit) changes cash. Moving money into investments doesn't change net worth by itself.")
                    section("Growth of income and costs", "Salary and expense growth apply once per projection year (months 13, 25, …). Recurring future expenses can grow with inflation.")
                    section("Purchases and shortfalls", "One-time purchases are paid from cash at the end of their month. If cash goes negative, investments are sold to cover it. If both are exhausted, cash stays negative (projected debt, no interest).")
                    section("Real values", "Today's-money values divide nominal values by (1 + inflation)^(months / 12).")
                    section("Monte Carlo", "Monthly investment growth factors are drawn as exp(μ + σ·Z) with σ = volatility/√12 and μ = ln(1 + r)/12 − σ²/2, so the mean annual growth equals your expected return. Cash flows are identical to the deterministic projection. A fixed seed makes results reproducible.")
                    section("Limitations", "Taxes, fees inside funds, sequence of real market events, job changes and other life events are not modelled unless you enter them. Results are estimates, not predictions or guarantees.")
                }
                .padding()
            }
            .navigationTitle("How the Simulator Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}
