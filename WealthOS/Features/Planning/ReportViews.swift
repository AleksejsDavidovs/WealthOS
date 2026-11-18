import SwiftUI
import SwiftData
import Charts

// MARK: - Monthly report

struct MonthlyReportView: View {
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @AppStorage(SettingsKey.lastSeenReportMonth) private var lastSeenReportMonth = ""
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @Query(sort: \Budget.createdAt) private var budgets: [Budget]
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @Query(sort: \PortfolioSnapshot.date) private var portfolio: [PortfolioSnapshot]
    @State private var month: Date

    private let calendar = Calendar.current

    init(month: Date = MonthlyReport.defaultMonth()) {
        _month = State(initialValue: month)
    }

    var body: some View {
        SubscriptionsReader { subscriptions, engine in
            let entries = engine.cashFlowEntries()
            let report = MonthlyReport(
                entries: entries, month: month,
                netWorth: snapshots.filter { $0.currencyCode == baseCurrency }.map { ($0.date, $0.netWorth) },
                investments: portfolio.filter { $0.currencyCode == baseCurrency }.map { ($0.date, $0.totalValue) })
            ScrollView {
                VStack(spacing: 16) {
                    navigator(report)
                    if report.hasActivity {
                        hero(report)
                        if report.netWorthChange != nil || report.investmentsChange != nil { wealth(report) }
                        spending(report, engine: engine)
                        if !budgets.isEmpty { budgetsCard(entries: entries) }
                        subscriptionsCard(subscriptions)
                    } else {
                        ContentUnavailableView("No Activity", systemImage: "doc.text.magnifyingglass",
                                               description: Text("Nothing was recorded in \(month.formatted(.dateTime.month(.wide).year()))."))
                            .padding(.top, 40)
                    }
                }
                .padding()
            }
            .screenBackground()
        }
        .navigationTitle("Monthly Report")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { lastSeenReportMonth = BudgetMath.monthKey(MonthlyReport.defaultMonth()) }
    }

    private var isCurrentMonth: Bool { calendar.isDate(month, equalTo: .now, toGranularity: .month) }

    private func navigator(_ report: MonthlyReport) -> some View {
        HStack {
            Button { withAnimation { month = calendar.date(byAdding: .month, value: -1, to: month) ?? month } } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 36, height: 36)
            }
            .accessibilityLabel("Previous month")
            Spacer()
            VStack(spacing: 1) {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                if !report.isComplete { Text("So far").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { withAnimation { month = calendar.date(byAdding: .month, value: 1, to: month) ?? month } } label: {
                Image(systemName: "chevron.right").font(.body.weight(.semibold)).frame(width: 36, height: 36)
            }
            .disabled(isCurrentMonth)
            .accessibilityLabel("Next month")
        }
    }

    // Saved, income, expenses

    private func hero(_ report: MonthlyReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.net >= 0 ? "Saved" : "Spent more than earned").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(MoneyFormat.string(report.net, code: baseCurrency, showSign: report.net < 0))
                    .scaledFont(34, weight: .bold, relativeTo: .largeTitle).monospacedDigit()
                    .foregroundStyle(Theme.signColor(report.net)).lineLimit(1).minimumScaleFactor(0.5)
                if let rate = report.savingsRate {
                    Text("\(MoneyFormat.percent(rate, fractionDigits: 0)) of income")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.signColor(report.net))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.signColor(report.net).opacity(0.12), in: Capsule())
                }
            }
            Divider()
            flowRow("Income", report.income, previous: report.previousIncome, goodWhenUp: true, color: Theme.positive)
            flowRow("Expenses", report.expenses, previous: report.previousExpenses, goodWhenUp: false, color: Theme.negative)
            if let average = report.averageExpenses {
                let delta = report.expenses - average
                Text(delta <= 0
                     ? "\(MoneyFormat.string(-delta, code: baseCurrency, fractionDigits: 0)) below your 3-month average spending"
                     : "\(MoneyFormat.string(delta, code: baseCurrency, fractionDigits: 0)) above your 3-month average spending")
                    .font(.caption).foregroundStyle(delta <= 0 ? Theme.positive : Theme.warning)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func flowRow(_ title: String, _ value: Decimal, previous: Decimal, goodWhenUp: Bool, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.subheadline)
            Spacer()
            if let change = MonthlyReport.change(value, previous) {
                changeChip(change, goodWhenUp: goodWhenUp)
            }
            Text(MoneyFormat.string(value, code: baseCurrency)).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }

    private func changeChip(_ change: Decimal, goodWhenUp: Bool) -> some View {
        let up = change > 0
        let color: Color = change == 0 ? .secondary : (up == goodWhenUp ? Theme.positive : Theme.negative)
        return HStack(spacing: 2) {
            Image(systemName: change == 0 ? "equal" : (up ? "arrow.up.right" : "arrow.down.right")).font(.caption2.weight(.bold))
            Text(MoneyFormat.percent(abs(change), fractionDigits: 0)).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .accessibilityLabel("\(up ? "up" : "down") \(MoneyFormat.percent(abs(change), fractionDigits: 0)) from the previous month")
    }

    // Net worth and investments

    private func wealth(_ report: MonthlyReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wealth").font(.headline)
            if let start = report.netWorthStart, let end = report.netWorthEnd, let change = report.netWorthChange {
                wealthRow("Net worth", start: start, end: end, change: change)
            }
            if let start = report.investmentsStart, let end = report.investmentsEnd, let change = report.investmentsChange {
                wealthRow("Investments", start: start, end: end, change: change)
            }
            Text("From recorded snapshots at the start and end of the month.").font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private func wealthRow(_ title: String, start: Decimal, end: Decimal, change: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(MoneyFormat.string(change, code: baseCurrency, showSign: true, fractionDigits: 0))
                    .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.signColor(change))
                if start > 0 {
                    Text("(\(MoneyFormat.percent(change / start, fractionDigits: 1, showSign: true)))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text("\(MoneyFormat.string(start, code: baseCurrency, fractionDigits: 0)) → \(MoneyFormat.string(end, code: baseCurrency, fractionDigits: 0))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    // Where the money went

    private func category(_ id: UUID?) -> TransactionCategory? { id.flatMap { id in categories.first { $0.id == id } } }

    private func spending(_ report: MonthlyReport, engine: FinanceEngine) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where It Went").font(.headline)
            ForEach(report.topCategories) { line in
                let category = category(line.categoryID)
                HStack(spacing: 12) {
                    IconBadge(symbol: category?.symbol ?? "tag.fill", color: Theme.color(named: category?.colorName ?? "gray"), size: 32)
                    Text(category?.name ?? "Uncategorized").font(.subheadline)
                    Spacer()
                    if let change = line.change { changeChip(change, goodWhenUp: false) }
                    Text(MoneyFormat.string(line.amount, code: baseCurrency)).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            Divider()
            if let biggest = report.biggestExpense {
                let record = engine.transactions.first { $0.id == biggest.id }
                let title = (record?.note).flatMap { $0.isEmpty ? nil : $0 } ?? category(biggest.categoryID)?.name ?? "Expense"
                LabeledContent("Biggest expense") {
                    Text("\(title) · \(MoneyFormat.string(biggest.amount, code: baseCurrency)) · \(biggest.date.formatted(.dateTime.day().month(.abbreviated)))")
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                }
                .font(.subheadline)
            }
            LabeledContent("Per day") {
                HStack(spacing: 6) {
                    Text(MoneyFormat.string(report.dailySpending, code: baseCurrency)).monospacedDigit()
                    if report.previousDailySpending > 0 {
                        Text("vs \(MoneyFormat.string(report.previousDailySpending, code: baseCurrency))").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .font(.subheadline)
        }
        .card()
    }

    // Budgets and subscriptions

    private func budgetsCard(entries: [CashFlowEntry]) -> some View {
        let statuses = PlanningMonitor.budgetStatuses(budgets, entries: entries, month: month)
        let over = statuses.filter { $0.level == .over }
        return NavigationLink { BudgetsView() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Budgets").font(.headline)
                    Spacer()
                    Text("\(statuses.count - over.count) of \(statuses.count) kept")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(over.isEmpty ? Theme.positive : Theme.warning)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
                ForEach(over) { status in
                    HStack {
                        Text(category(status.categoryID)?.name ?? "All spending").font(.subheadline)
                        Spacer()
                        Text("\(MoneyFormat.string(-status.remaining, code: baseCurrency, fractionDigits: 0)) over")
                            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.negative).monospacedDigit()
                    }
                }
            }
            .card()
        }
        .buttonStyle(CardPressStyle())
    }

    @ViewBuilder
    private func subscriptionsCard(_ subscriptions: [DetectedSubscription]) -> some View {
        let summary = SubscriptionDetector.summary(subscriptions)
        if summary.confirmedCount > 0 {
            NavigationLink { SubscriptionsView() } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Subscriptions").font(.headline)
                        Text("\(summary.confirmedCount) active · \(MoneyFormat.string(summary.yearly, code: baseCurrency, fractionDigits: 0)) a year")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(MoneyFormat.string(summary.monthly, code: baseCurrency))/mo").font(.subheadline.weight(.semibold)).monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
                .card()
            }
            .buttonStyle(CardPressStyle())
        }
    }
}

/// Home, first week of a month: one dismissible row pointing to last month's report.
struct MonthlyReportBanner: View {
    @AppStorage(SettingsKey.lastSeenReportMonth) private var lastSeenReportMonth = ""
    let engine: FinanceEngine

    var body: some View {
        let month = MonthlyReport.defaultMonth()
        let key = BudgetMath.monthKey(month)
        let day = Calendar.current.component(.day, from: .now)
        if day <= 7, lastSeenReportMonth != key, MonthlyReport(entries: engine.cashFlowEntries(), month: month).hasActivity {
            HStack(spacing: 12) {
                NavigationLink { MonthlyReportView(month: month) } label: {
                    HStack(spacing: 12) {
                        IconBadge(symbol: "doc.text.fill", color: Theme.accentFill, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your \(month.formatted(.dateTime.month(.wide))) report is ready").font(.subheadline.weight(.semibold))
                            Text("Savings, spending and wealth at a glance").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                    }
                }
                .buttonStyle(.plain)
                Button { withAnimation { lastSeenReportMonth = key } } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 28, height: 28)
                }
                .accessibilityLabel("Dismiss report reminder")
            }
            .card(padding: 14)
        }
    }
}

// MARK: - Portfolio performance

struct PortfolioPerformanceCard: View {
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \PortfolioSnapshot.date) private var snapshots: [PortfolioSnapshot]
    @State private var range: PortfolioRange = .half
    let engine: FinanceEngine

    var body: some View {
        let total = PortfolioPerformance.totalReturn(unrealized: engine.portfolioUnrealized, realized: engine.portfolioRealized,
                                                     costBasis: engine.portfolioCostBasis)
        let points = snapshots.filter { $0.currencyCode == baseCurrency }
            .map { PortfolioPoint(date: $0.date, costedValue: $0.costedValue, costBasis: $0.costBasis, totalValue: $0.totalValue) }
        let performance = PortfolioPerformance(points: points, from: range.start(now: .now))
        if engine.hasAnyPositions || points.count >= 2 {
            VStack(alignment: .leading, spacing: 14) {
                Text("Performance").font(.headline)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(MoneyFormat.string(total.amount, code: baseCurrency, showSign: true))
                            .font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(Theme.signColor(total.amount))
                        if let fraction = total.fraction {
                            Text(MoneyFormat.percent(fraction, showSign: true)).font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.signColor(total.amount))
                        }
                    }
                    Text("Total return, including realized profit").font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    metric("Invested", MoneyFormat.string(engine.portfolioCostBasis, code: baseCurrency, fractionDigits: 0), .primary)
                    metric("Worth now", MoneyFormat.string(engine.portfolioCostedValue, code: baseCurrency, fractionDigits: 0), .primary)
                    metric("Unrealized", MoneyFormat.string(engine.portfolioUnrealized, code: baseCurrency, showSign: true, fractionDigits: 0),
                           Theme.signColor(engine.portfolioUnrealized))
                    metric("Realized", MoneyFormat.string(engine.portfolioRealized, code: baseCurrency, showSign: true, fractionDigits: 0),
                           Theme.signColor(engine.portfolioRealized))
                }
                if points.count >= 2 {
                    Picker("Range", selection: $range) {
                        ForEach(PortfolioRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    chart(performance)
                    HStack(alignment: .top) {
                        metric("Market gain", MoneyFormat.string(performance.marketGain, code: baseCurrency, showSign: true, fractionDigits: 0),
                               Theme.signColor(performance.marketGain))
                        metric("Added in period", MoneyFormat.string(performance.contributions, code: baseCurrency, showSign: true, fractionDigits: 0), .primary)
                        if let twr = performance.timeWeighted {
                            metric(performance.annualized == nil ? "Return" : "Per year",
                                   MoneyFormat.percent(performance.annualized ?? twr, showSign: true), Theme.signColor(twr))
                        }
                    }
                } else {
                    comparisonBars(invested: engine.portfolioCostBasis, value: engine.portfolioCostedValue)
                    Label("The chart over time starts filling in from tomorrow — one point a day.", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let sources = engine.portfolioSources
                if !sources.isEmpty {
                    Divider()
                    VStack(spacing: 10) {
                        ForEach(sources) { sourceRow($0) }
                    }
                }
                if engine.binanceTotalBase > 0 || engine.positionsWithoutCost > 0 {
                    Text("Positions without a purchase price (such as Binance balances) aren't included in returns.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .card()
        }
    }

    private func chart(_ performance: PortfolioPerformance) -> some View {
        Chart {
            ForEach(performance.points, id: \.date) { point in
                AreaMark(x: .value("Date", point.date), y: .value("Value", point.costedValue.doubleValue))
                    .foregroundStyle(LinearGradient(colors: [Theme.projection.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", point.date), y: .value("Value", point.costedValue.doubleValue), series: .value("Series", "Value"))
                    .foregroundStyle(Theme.projection)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", point.date), y: .value("Invested", point.costBasis.doubleValue), series: .value("Series", "Invested"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .interpolationMethod(.stepEnd)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel { if let v = value.as(Double.self) { Text(MoneyFormat.compact(v, code: baseCurrency)) } }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 170)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 12) {
                legend("Value", Theme.projection, dashed: false)
                legend("Invested", .secondary, dashed: true)
            }
            .font(.caption2)
        }
        .accessibilityLabel("Portfolio value and invested amount over time")
    }

    /// Before there is history: invested against what it's worth now.
    private func comparisonBars(invested: Decimal, value: Decimal) -> some View {
        let top = max(invested, value, 1)
        return VStack(alignment: .leading, spacing: 8) {
            bar("Invested", invested, fraction: invested / top, color: .secondary)
            bar("Worth now", value, fraction: value / top, color: Theme.projection)
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(_ title: String, _ amount: Decimal, fraction: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(MoneyFormat.string(amount, code: baseCurrency)).font(.caption.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(color.gradient).frame(width: max(6, proxy.size.width * CGFloat(fraction.doubleValue)))
                }
            }
            .frame(height: 10)
        }
    }

    private func sourceRow(_ source: PortfolioSource) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: source.symbol, color: source.id == "binance" ? .orange : (source.id == "trading212" ? .blue : .indigo), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.subheadline.weight(.medium))
                if let invested = source.invested {
                    Text("\(MoneyFormat.string(invested, code: baseCurrency, fractionDigits: 0)) invested → \(MoneyFormat.string(source.costedValue, code: baseCurrency, fractionDigits: 0))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("No purchase prices — value only").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(MoneyFormat.string(source.value, code: baseCurrency, fractionDigits: 0)).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let gain = source.gain {
                    Text("\(MoneyFormat.string(gain, code: baseCurrency, showSign: true, fractionDigits: 0))\(source.fraction.map { " · " + MoneyFormat.percent($0, showSign: true) } ?? "")")
                        .font(.caption.weight(.medium)).foregroundStyle(Theme.signColor(gain)).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func legend(_ title: String, _ color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 12, height: 2).opacity(dashed ? 0.6 : 1)
            Text(title).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
