import SwiftUI
import SwiftData
import Charts

struct StatisticsView: View {
    enum Period: String, CaseIterable, Identifiable {
        case month = "Month", year = "Year"
        var id: String { rawValue }
    }

    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @State private var period: Period = .month
    @State private var anchor = Date.now
    @State private var breakdownKind: TransactionKind = .expense

    private let calendar = Calendar.current

    private var interval: DateInterval {
        calendar.dateInterval(of: period == .month ? .month : .year, for: anchor) ?? DateInterval(start: anchor, duration: 1)
    }

    private var title: String {
        period == .month ? anchor.formatted(.dateTime.month(.wide).year()) : anchor.formatted(.dateTime.year())
    }

    var body: some View {
        FinanceReader { engine in
            let flow = engine.cashFlow(in: interval)
            ScrollView {
                VStack(spacing: 18) {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Previous \(period.rawValue.lowercased())")
                        Spacer()
                        Text(title).font(.headline)
                        Spacer()
                        Button { shift(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(interval.end > .now)
                            .accessibilityLabel("Next \(period.rawValue.lowercased())")
                    }
                    .padding(.horizontal, 8)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        StatTile(title: "Income", value: MoneyFormat.string(flow.income, code: baseCurrency),
                                 symbol: "arrow.down.circle.fill", tint: Theme.positive)
                        StatTile(title: "Expenses", value: MoneyFormat.string(flow.expenses, code: baseCurrency),
                                 symbol: "arrow.up.circle.fill", tint: Theme.negative)
                        StatTile(title: "Saved", value: MoneyFormat.string(flow.savings, code: baseCurrency),
                                 symbol: "banknote.fill", tint: .blue)
                        StatTile(title: "Savings Rate", value: flow.savingsRate.map { MoneyFormat.percent($0) } ?? "—",
                                 symbol: "percent", tint: Theme.accent)
                    }

                    trendChart(engine)
                    breakdown(engine)
                }
                .padding()
            }
            .screenBackground()
        }
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: anchor)
    }

    private func shift(_ direction: Int) {
        withAnimation(.spring) {
            anchor = calendar.date(byAdding: period == .month ? .month : .year, value: direction, to: anchor) ?? anchor
        }
    }

    private struct Bar: Identifiable {
        let id = UUID()
        let date: Date
        let series: String
        let value: Double
    }

    /// Year view: 12 months of the selected year. Month view: the 6 months ending at the selected month.
    private func bars(_ engine: FinanceEngine) -> [Bar] {
        var months: [Date] = []
        if period == .year {
            months = (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: interval.start) }
        } else {
            months = (0..<6).reversed().compactMap { calendar.date(byAdding: .month, value: -$0, to: interval.start) }
        }
        return months.flatMap { month -> [Bar] in
            guard let range = calendar.dateInterval(of: .month, for: month) else { return [] }
            let flow = engine.cashFlow(in: range)
            return [Bar(date: month, series: "Income", value: flow.income.doubleValue),
                    Bar(date: month, series: "Expenses", value: flow.expenses.doubleValue)]
        }
    }

    private func trendChart(_ engine: FinanceEngine) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(period == .year ? "Monthly Overview" : "Last 6 Months").font(.headline)
            Chart(bars(engine)) { bar in
                BarMark(x: .value("Month", bar.date, unit: .month), y: .value("Amount", bar.value))
                    .foregroundStyle(by: .value("Type", bar.series))
                    .position(by: .value("Type", bar.series))
                    .cornerRadius(4)
            }
            .chartForegroundStyleScale(["Income": Theme.positive, "Expenses": Theme.negative])
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel { if let v = value.as(Double.self) { Text(MoneyFormat.compact(v, code: baseCurrency)) } }
                }
            }
            .frame(height: 200)
            .accessibilityLabel("Income and expenses by month")
        }
        .card()
    }

    private struct Slice: Identifiable {
        let id: UUID
        let name: String
        let color: Color
        let symbol: String
        let value: Decimal
    }

    private func slices(_ engine: FinanceEngine) -> [Slice] {
        engine.categoryTotals(kind: breakdownKind, in: interval).map { id, value in
            let category = id.flatMap { id in categories.first { $0.id == id } }
            return Slice(id: id ?? UUID(), name: category?.name ?? "Uncategorized",
                         color: Theme.color(named: category?.colorName ?? "gray"),
                         symbol: category?.symbol ?? "tag.fill", value: value)
        }
        .sorted { $0.value > $1.value }
    }

    private func breakdown(_ engine: FinanceEngine) -> some View {
        let data = slices(engine)
        let total = data.reduce(Decimal(0)) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("By Category").font(.headline)
                Spacer()
                Picker("Kind", selection: $breakdownKind) {
                    Text("Expenses").tag(TransactionKind.expense)
                    Text("Income").tag(TransactionKind.income)
                }
                .pickerStyle(.menu)
            }
            if data.isEmpty {
                Text("No \(breakdownKind == .expense ? "expenses" : "income") in this period.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(data) { slice in
                    SectorMark(angle: .value("Amount", slice.value.doubleValue), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(slice.color.gradient)
                        .cornerRadius(4)
                }
                .chartBackground { _ in
                    VStack(spacing: 2) {
                        Text("Total").font(.caption).foregroundStyle(.secondary)
                        Text(MoneyFormat.string(total, code: baseCurrency, fractionDigits: 0))
                            .font(.headline).monospacedDigit()
                    }
                }
                .frame(height: 200)
                .accessibilityLabel("Category breakdown")

                VStack(spacing: 10) {
                    ForEach(data) { slice in
                        HStack(spacing: 10) {
                            IconBadge(symbol: slice.symbol, color: slice.color, size: 28)
                            Text(slice.name).font(.subheadline)
                            Spacer()
                            Text(total > 0 ? MoneyFormat.percent(slice.value / total, fractionDigits: 0) : "")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(MoneyFormat.string(slice.value, code: baseCurrency))
                                .font(.subheadline.weight(.medium)).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .card()
    }
}
