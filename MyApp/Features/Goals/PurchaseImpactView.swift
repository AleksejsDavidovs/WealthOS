import SwiftUI
import SwiftData
import Charts

/// "What happens if I buy a €20,000 car next year?" — compares a scenario with and
/// without a one-time purchase, including the investment growth the money would have earned.
struct PurchaseImpactView: View {
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query private var scenarios: [SimulationScenario]
    @State private var name = "Car"
    @State private var amountText = "20000"
    @State private var date = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
    @State private var scenarioKind: ScenarioKind = .balanced
    @State private var years = 10

    private var amount: Decimal? { AmountValidation.money(amountText).value }

    var body: some View {
        FinanceReader { engine in
            let base = baseParameters(engine: engine)
            let baseline = SimulationEngine.project(base)
            let withPurchase = amount.map { amount -> ProjectionResult in
                var p = base
                p.oneTimePurchases.append(OneTimePurchase(name: name, amount: amount, date: date))
                return SimulationEngine.project(p)
            }
            Form {
                Section {
                    TextField("Purchase", text: $name)
                    AmountField(title: "Price", text: $amountText, currencyCode: baseCurrency,
                                validation: amountText.isEmpty ? .empty : .money(amountText))
                    DatePicker("When", selection: $date, in: Date.now..., displayedComponents: .date)
                    Picker("Scenario", selection: $scenarioKind) {
                        ForEach(ScenarioKind.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper("Look ahead: \(years) years", value: $years, in: 1...40)
                } footer: {
                    Text("Uses the assumptions of your \(scenarioKind.title.lowercased()) scenario from the Simulator tab.")
                }

                if let withPurchase, let amount {
                    Section("Impact") {
                        impactSummary(baseline: baseline, withPurchase: withPurchase, amount: amount)
                    }
                    Section("Projected Net Worth") {
                        chart(baseline: baseline, withPurchase: withPurchase)
                            .frame(height: 220)
                            .padding(.vertical, 8)
                    }
                    Section("Milestones") {
                        ForEach(Array(zip(baseline.milestones, withPurchase.milestones)), id: \.0.threshold) { before, after in
                            if !(before.isAlreadyReached && after.isAlreadyReached) {
                                HStack {
                                    Text(MoneyFormat.string(before.threshold, code: baseCurrency, fractionDigits: 0)).monospacedDigit()
                                    Spacer()
                                    Text(delayText(before: before, after: after)).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                } footer: {
                    Text("An estimate based on your assumptions, not a prediction. The purchase is paid from cash first, then from investments if cash runs out.")
                }
            }
        }
        .navigationTitle("What If…")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func baseParameters(engine: FinanceEngine) -> SimulationParameters {
        var params: SimulationParameters
        if let stored = scenarios.first(where: { $0.kind == scenarioKind })?.parameters {
            params = stored
        } else {
            let figures = SimulatorViewModel.currentFigures(engine: engine)
            params = .preset(scenarioKind, startingCash: figures.cash, startingInvestments: figures.investments,
                             monthlyIncome: figures.income, monthlyExpenses: figures.expenses)
        }
        params.years = years
        return params
    }

    private func impactSummary(baseline: ProjectionResult, withPurchase: ProjectionResult, amount: Decimal) -> some View {
        let before = baseline.final?.netWorth ?? 0
        let after = withPurchase.final?.netWorth ?? 0
        let difference = before - after
        let lostGrowth = difference - amount
        let realDifference = (baseline.final?.realNetWorth ?? 0) - (withPurchase.final?.realNetWorth ?? 0)
        return VStack(alignment: .leading, spacing: 10) {
            Text("In \(years) years your projected net worth would be")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("\(MoneyFormat.string(difference, code: baseCurrency, fractionDigits: 0)) lower")
                .font(.title2.bold()).monospacedDigit().foregroundStyle(Theme.negative)
            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow {
                    Text("Without purchase").foregroundStyle(.secondary)
                    Text(MoneyFormat.string(before, code: baseCurrency, fractionDigits: 0)).monospacedDigit()
                }
                GridRow {
                    Text("With purchase").foregroundStyle(.secondary)
                    Text(MoneyFormat.string(after, code: baseCurrency, fractionDigits: 0)).monospacedDigit()
                }
                GridRow {
                    Text("Price").foregroundStyle(.secondary)
                    Text(MoneyFormat.string(amount, code: baseCurrency, fractionDigits: 0)).monospacedDigit()
                }
                GridRow {
                    Text("Forgone growth").foregroundStyle(.secondary)
                    Text(MoneyFormat.string(max(0, lostGrowth), code: baseCurrency, fractionDigits: 0)).monospacedDigit()
                }
                GridRow {
                    Text("In today's money").foregroundStyle(.secondary)
                    Text(MoneyFormat.string(realDifference, code: baseCurrency, fractionDigits: 0) + " lower").monospacedDigit()
                }
            }
            .font(.subheadline)
            if withPurchase.shortfallMonths > baseline.shortfallMonths {
                Label("This purchase would leave you without money in some months.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chart(baseline: ProjectionResult, withPurchase: ProjectionResult) -> some View {
        let stride = baseline.points.count > 121 ? 3 : 1
        let a = baseline.points.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
        let b = withPurchase.points.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
        return Chart {
            ForEach(a) { point in
                LineMark(x: .value("Date", point.date), y: .value("Net Worth", point.netWorth.doubleValue), series: .value("S", "Without"))
                    .foregroundStyle(by: .value("Series", "Without purchase"))
            }
            ForEach(b) { point in
                LineMark(x: .value("Date", point.date), y: .value("Net Worth", point.netWorth.doubleValue), series: .value("S", "With"))
                    .foregroundStyle(by: .value("Series", "With purchase"))
            }
            RuleMark(x: .value("Purchase", date))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                .annotation(position: .top, alignment: .leading) {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
        }
        .chartForegroundStyleScale(["Without purchase": Theme.accent, "With purchase": Color.orange])
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel { if let v = value.as(Double.self) { Text(MoneyFormat.compact(v, code: baseCurrency)) } }
            }
        }
    }

    private func delayText(before: MilestoneResult, after: MilestoneResult) -> String {
        switch (before.month, after.month) {
        case let (b?, a?) where a > b: return "\(a - b) month\(a - b == 1 ? "" : "s") later"
        case (_?, _?): return "No delay"
        case (_?, nil): return "No longer reached in \(years) yrs"
        case (nil, _): return "Not reached in \(years) yrs"
        }
    }
}
