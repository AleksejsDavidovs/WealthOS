import SwiftUI
import SwiftData
import Charts

/// Cash-flow analytics: period picker, spending/income donut with category breakdown, a daily
/// chart, comparison with the previous period and average daily amount. Everything is derived
/// from `FinanceEngine.cashFlowEntries()`, so it updates live and never counts transfers,
/// balance adjustments, scheduled records or bank transactions that aren't recorded yet.
struct AnalyticsView: View {
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @Query private var budgets: [Budget]

    @State private var period: AnalyticsPeriod
    @State private var anchor: Date
    @State private var customStart: Date
    @State private var customEnd: Date
    @State private var kind: TransactionKind = .expense
    @State private var selectedAngle: Double?
    @State private var selectedSlice: String?
    @State private var selectedDay: Date?

    private let calendar = Calendar.current

    init(period: AnalyticsPeriod = .month, anchor: Date = .now,
         customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now,
         customEnd: Date = .now, kind: TransactionKind = .expense) {
        _period = State(initialValue: period)
        _anchor = State(initialValue: anchor)
        _customStart = State(initialValue: customStart)
        _customEnd = State(initialValue: customEnd)
        _kind = State(initialValue: kind)
    }

    /// Opens on the same period as the Transactions date filter.
    init(filter: TransactionFilter) {
        let now = Date.now
        var anchor = now
        var start = filter.customStart, end = filter.customEnd
        switch filter.range {
        case .lastMonth: anchor = Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now
        case .last3Months:
            if let interval = filter.range.interval(customStart: start, customEnd: end) {
                start = interval.start
                end = interval.end.addingTimeInterval(-1)
            }
        default: break
        }
        self.init(period: .matching(filter.range), anchor: anchor, customStart: start, customEnd: end)
    }

    var body: some View {
        FinanceReader { engine in
            let entries = engine.cashFlowEntries()
            let interval = period.interval(anchor: anchor, customStart: customStart, customEnd: customEnd,
                                           earliest: entries.map(\.date).min())
            let current = CashFlowAnalytics(entries: entries, interval: interval, kind: kind)
            let previous = period.previous(of: interval).map { CashFlowAnalytics(entries: entries, interval: $0, kind: kind) }
            ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: 16) {
                    periodControls(interval)
                    Picker("Show", selection: $kind) {
                        Text("Expenses").tag(TransactionKind.expense)
                        Text("Income").tag(TransactionKind.income)
                    }
                    .pickerStyle(.segmented)
                    overview(current, previous: previous, interval: interval)
                    breakdown(current, interval: interval)
                    dailyChart(current).id("daily")
                }
                .padding()
            }
            #if DEBUG
            .onAppear {
                // Development aid: `-UIScrollTo daily` for visual checks of the lower charts.
                if ProcessInfo.processInfo.arguments.contains("-UIScrollTo") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { scroller.scrollTo("daily", anchor: .bottom) }
                }
            }
            #endif
            }
            .screenBackground()
        }
        .navigationTitle("Analytics")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: anchor)
        .sensoryFeedback(.selection, trigger: selectedSlice)
        .onChange(of: period) { selectedSlice = nil; selectedDay = nil }
        .onChange(of: kind) { selectedSlice = nil; selectedDay = nil }
        .onChange(of: anchor) { selectedSlice = nil; selectedDay = nil }
    }

    // MARK: Period

    private func periodControls(_ interval: DateInterval) -> some View {
        VStack(spacing: 12) {
            Picker("Period", selection: $period) {
                ForEach(AnalyticsPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch period {
            case .week, .month, .year:
                HStack {
                    Button { withAnimation(.spring) { anchor = period.shifted(anchor, by: -1) } } label: {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Previous \(period.title.lowercased())")
                    Spacer()
                    Text(periodTitle(interval)).font(.headline).contentTransition(.numericText())
                    Spacer()
                    Button { withAnimation(.spring) { anchor = period.shifted(anchor, by: 1) } } label: {
                        Image(systemName: "chevron.right").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                    }
                    .disabled(interval.end > .now)
                    .accessibilityLabel("Next \(period.title.lowercased())")
                }
            case .custom:
                HStack {
                    DatePicker("From", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                        .labelsHidden()
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    DatePicker("To", selection: $customEnd, in: customStart...Date.now, displayedComponents: .date)
                        .labelsHidden()
                }
                .frame(maxWidth: .infinity)
            case .all:
                Text(periodTitle(interval)).font(.headline)
            }
        }
    }

    private func periodTitle(_ interval: DateInterval) -> String {
        let last = interval.end.addingTimeInterval(-1)
        switch period {
        case .month: return interval.start.formatted(.dateTime.month(.wide).year())
        case .year: return interval.start.formatted(.dateTime.year())
        case .all: return "Since \(interval.start.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .week, .custom:
            let sameYear = calendar.isDate(interval.start, equalTo: last, toGranularity: .year)
            let from = sameYear ? interval.start.formatted(.dateTime.day().month(.abbreviated))
                                : interval.start.formatted(.dateTime.day().month(.abbreviated).year())
            return "\(from) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
    }

    private var previousLabel: String {
        switch period {
        case .week: "last week"
        case .month: "last month"
        case .year: "last year"
        case .custom: "the previous period"
        case .all: ""
        }
    }

    // MARK: Overview

    private var kindColor: Color { kind == .expense ? Theme.negative : Theme.positive }

    private func overview(_ current: CashFlowAnalytics, previous: CashFlowAnalytics?, interval: DateInterval) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind == .expense ? "Spent" : "Earned").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(MoneyFormat.string(current.total, code: baseCurrency))
                .scaledFont(34, weight: .bold, relativeTo: .largeTitle)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            comparison(current, previous: previous)
            Divider()
            HStack(alignment: .top) {
                miniStat("Per day", MoneyFormat.string(current.averageDaily, code: baseCurrency),
                         "over \(current.elapsedDays) day\(current.elapsedDays == 1 ? "" : "s")")
                miniStat("Transactions", "\(current.count)", nil)
                miniStat("Net", MoneyFormat.string(current.net, code: baseCurrency, showSign: true, fractionDigits: 0),
                         nil, color: Theme.signColor(current.net))
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func comparison(_ current: CashFlowAnalytics, previous: CashFlowAnalytics?) -> some View {
        if let previous {
            if let change = CashFlowAnalytics.change(current: current.total, previous: previous.total) {
                let up = change > 0
                // More spending is bad, more income is good.
                let color = change == 0 ? Color.secondary : ((up == (kind == .income)) ? Theme.positive : Theme.negative)
                HStack(spacing: 6) {
                    Image(systemName: change == 0 ? "equal" : (up ? "arrow.up.right" : "arrow.down.right"))
                        .font(.caption.weight(.bold))
                    Text("\(MoneyFormat.percent(abs(change), fractionDigits: 0)) vs \(previousLabel)")
                        .font(.subheadline.weight(.semibold))
                    Text("(\(MoneyFormat.string(previous.total, code: baseCurrency, fractionDigits: 0)))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(color.opacity(0.12), in: Capsule())
            } else {
                Text("Nothing to compare with \(previousLabel)").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func miniStat(_ title: String, _ value: String, _ detail: String?, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Categories

    private func category(_ id: UUID?) -> TransactionCategory? {
        id.flatMap { id in categories.first { $0.id == id } }
    }

    private func name(_ share: CashFlowAnalytics.CategoryShare) -> String { category(share.categoryID)?.name ?? "Uncategorized" }
    private func color(_ share: CashFlowAnalytics.CategoryShare) -> Color {
        Theme.color(named: category(share.categoryID)?.colorName ?? "gray")
    }

    /// Maps a tapped angle (in the chart's value units) to the slice under it.
    private func slice(at angle: Double, in data: [CashFlowAnalytics.CategoryShare]) -> String? {
        var cumulative = 0.0
        for share in data {
            cumulative += share.amount.doubleValue
            if angle <= cumulative { return share.id }
        }
        return data.last?.id
    }

    private func breakdown(_ current: CashFlowAnalytics, interval: DateInterval) -> some View {
        let data = current.categories
        let selected = data.first { $0.id == selectedSlice }
        return VStack(alignment: .leading, spacing: 14) {
            Text(kind == .expense ? "Spending by Category" : "Income by Category").font(.headline)
            if data.isEmpty {
                Text(kind == .expense ? "No spending in this period." : "No income in this period.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(data) { share in
                    SectorMark(angle: .value("Amount", share.amount.doubleValue),
                               innerRadius: .ratio(0.64), outerRadius: .ratio(share.id == selectedSlice ? 1 : 0.94),
                               angularInset: 1.5)
                        .foregroundStyle(color(share).gradient)
                        .cornerRadius(5)
                        .opacity(selectedSlice == nil || share.id == selectedSlice ? 1 : 0.35)
                }
                .chartAngleSelection(value: $selectedAngle)
                .onChange(of: selectedAngle) { _, angle in
                    guard let angle else { return }
                    let hit = slice(at: angle, in: data)
                    withAnimation(.spring(response: 0.3)) { selectedSlice = hit == selectedSlice ? nil : hit }
                }
                .chartBackground { _ in
                    VStack(spacing: 2) {
                        Text(selected.map(name) ?? "Total").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(MoneyFormat.string(selected?.amount ?? current.total, code: baseCurrency, fractionDigits: 0))
                            .font(.title3.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        if let selected {
                            Text(MoneyFormat.percent(selected.share, fractionDigits: 0)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 120)
                }
                .frame(height: 220)
                .accessibilityLabel(kind == .expense ? "Spending by category chart" : "Income by category chart")

                VStack(spacing: 4) {
                    ForEach(data) { share in
                        NavigationLink {
                            CategoryTransactionsView(categoryID: share.categoryID, kind: kind, interval: interval,
                                                     title: name(share))
                        } label: {
                            categoryRow(share, highlighted: share.id == selectedSlice)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .card()
    }

    private func categoryRow(_ share: CashFlowAnalytics.CategoryShare, highlighted: Bool) -> some View {
        let category = category(share.categoryID)
        return HStack(spacing: 12) {
            IconBadge(symbol: category?.symbol ?? "tag.fill", color: color(share), size: 34)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(name(share)).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(MoneyFormat.string(share.amount, code: baseCurrency))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                HStack(spacing: 8) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule().fill(color(share).gradient)
                                .frame(width: max(4, proxy.size.width * CGFloat(share.share.doubleValue)))
                        }
                    }
                    .frame(height: 5)
                    Text(MoneyFormat.percent(share.share, fractionDigits: 0))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                        .frame(minWidth: 34, alignment: .trailing)
                }
                HStack(spacing: 4) {
                    Text("\(share.count) transaction\(share.count == 1 ? "" : "s")")
                    // Budgets are monthly: compared only on the Month view.
                    if period == .month, kind == .expense, let budget = budgets.first(where: { $0.categoryID == share.categoryID && $0.categoryID != nil }) {
                        Text("· of \(MoneyFormat.string(budget.amount, code: baseCurrency, fractionDigits: 0)) budget")
                            .foregroundStyle(share.amount > budget.amount ? Theme.negative : .secondary)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background(highlighted ? color(share).opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows its transactions")
    }

    // MARK: Daily chart

    private func dailyChart(_ current: CashFlowAnalytics) -> some View {
        let isDaily = current.granularity == .day
        let unit: Calendar.Component = isDaily ? .day : .month
        let selected = selectedDay.flatMap { day in
            current.buckets.first { calendar.isDate($0.date, equalTo: day, toGranularity: unit) }
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(isDaily ? (kind == .expense ? "Daily Spending" : "Daily Income")
                             : (kind == .expense ? "Monthly Spending" : "Monthly Income")).font(.headline)
                Spacer()
                if let selected {
                    Text("\(selected.date.formatted(isDaily ? .dateTime.day().month(.abbreviated) : .dateTime.month(.abbreviated).year())) · \(MoneyFormat.string(selected.amount, code: baseCurrency))")
                        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(kindColor)
                } else if isDaily {
                    Text("avg \(MoneyFormat.string(current.averageDaily, code: baseCurrency))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Chart {
                ForEach(current.buckets) { bucket in
                    BarMark(x: .value("Date", bucket.date, unit: unit), y: .value("Amount", bucket.amount.doubleValue))
                        .foregroundStyle(kindColor.gradient)
                        .cornerRadius(3)
                        .opacity(selected == nil || selected?.date == bucket.date ? 1 : 0.4)
                }
                if isDaily, current.averageDaily > 0 {
                    RuleMark(y: .value("Average", current.averageDaily.doubleValue))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
            }
            .chartXSelection(value: $selectedDay)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4, roundLowerBound: false)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel(format: isDaily ? .dateTime.day().month(.abbreviated) : .dateTime.month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel { if let v = value.as(Double.self) { Text(MoneyFormat.compact(v, code: baseCurrency)) } }
                }
            }
            .frame(height: 190)
            .accessibilityLabel(isDaily ? "Amount per day" : "Amount per month")
        }
        .card()
    }
}

/// The income or expense transactions of one category in a period.
struct CategoryTransactionsView: View {
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @State private var editorRequest: TransactionEditorRequest?
    let categoryID: UUID?
    let kind: TransactionKind
    let interval: DateInterval
    let title: String

    var body: some View {
        FinanceReader { engine in
            let ids = Set(engine.cashFlowEntries().filter {
                $0.kind == kind && $0.categoryID == categoryID && $0.date >= interval.start && $0.date < interval.end
            }.map(\.id))
            let records = engine.transactions.filter { ids.contains($0.id) }.sorted { $0.date > $1.date }
            let total = engine.cashFlowEntries().filter { ids.contains($0.id) }.reduce(Decimal(0)) { $0 + $1.amount }
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MoneyFormat.string(total, code: baseCurrency))
                            .font(.title2.weight(.bold)).monospacedDigit()
                        Text("\(records.count) transaction\(records.count == 1 ? "" : "s") · \(interval.start.formatted(.dateTime.day().month(.abbreviated).year())) – \(interval.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated).year()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    ForEach(records) { record in
                        Button { editorRequest = .init(kind: record.kind, transaction: record) } label: {
                            TransactionRow(transaction: record, engine: engine, categories: categories)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView("No Transactions", systemImage: "tray",
                                           description: Text("Nothing in this category for the period."))
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editorRequest) { TransactionEditorView(request: $0) }
    }
}
