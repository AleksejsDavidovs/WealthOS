import SwiftUI
import SwiftData
import Charts

struct TransactionEditorRequest: Identifiable {
    let id = UUID()
    var kind: TransactionKind
    var transaction: TransactionRecord?
    var presetAccountID: UUID?
}

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @Query(sort: \TransactionRecord.date, order: .reverse) private var recentTransactions: [TransactionRecord]
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @Query(sort: \Goal.createdAt) private var goals: [Goal]

    @State private var editorRequest: TransactionEditorRequest?
    @State private var showSettings = false
    @State private var showSnapshotEditor = false
    @State private var showAccountEditor = false

    var body: some View {
        NavigationStack {
            FinanceReader { engine in
                ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 20) {
                        if app.isDemoMode { DemoBanner() }
                        NetWorthHeroCard(summary: engine.summary, snapshots: baseSnapshots, code: baseCurrency)
                        if !engine.accounts.isEmpty { QuickActionsRow() }
                        BankConsentBanner()
                        MonthlyReportBanner(engine: engine)
                        if !engine.summary.missingRateCurrencies.isEmpty {
                            InfoBanner(text: "Missing exchange rate for \(engine.summary.missingRateCurrencies.sorted().joined(separator: ", ")). Those balances are excluded from totals until you add a rate in Settings.",
                                       symbol: "exclamationmark.triangle.fill", tint: .orange)
                        }
                        if !engine.summary.incompleteSources.isEmpty {
                            InfoBanner(text: "Unverified valuation: \(engine.summary.incompleteSources.sorted().joined(separator: ", ")) couldn't be fully confirmed. Amounts that might be counted twice are left out, and restored or cached data may not be current — see Investments for details.",
                                       symbol: "exclamationmark.triangle.fill", tint: .orange)
                        }
                        NetWorthChartCard(snapshots: baseSnapshots, code: baseCurrency,
                                          onRecord: { showSnapshotEditor = true })
                        breakdownGrid(engine.summary)
                        MonthlyFlowCard(flow: engine.cashFlow(forMonthContaining: .now), code: baseCurrency)
                        SubscriptionsReader { subscriptions, _ in
                            if !subscriptions.isEmpty {
                                NavigationLink { SubscriptionsView() } label: {
                                    SubscriptionsCard(subscriptions: subscriptions, code: baseCurrency)
                                }
                                .buttonStyle(CardPressStyle())
                            }
                        }
                        .id("subscriptions")
                        accountsSection(engine)
                        recentSection(engine)
                        goalsSection
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
                #if DEBUG
                .onAppear {
                    // Development aid: `-UIScrollTo subscriptions` for visual checks.
                    if ProcessInfo.processInfo.arguments.contains("-UIScrollTo") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { scroller.scrollTo("subscriptions", anchor: .center) }
                    }
                    // `-UIScreen settings` opens Settings.
                    if app.debugScreen == "settings" {
                        app.debugScreen = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showSettings = true }
                    }
                }
                #endif
                }
                .screenBackground()
                .onAppear { DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency) }
            }
            .navigationTitle("WealthOS")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    QuickAddToolbarMenu()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(item: $editorRequest) { request in
                TransactionEditorView(request: request)
            }
            // The sheet has its own presentation, so it applies the appearance itself to
            // update immediately when the user switches System / Light / Dark inside it.
            .sheet(isPresented: $showSettings) { SettingsView().appAppearance() }
            .sheet(isPresented: $showSnapshotEditor) { SnapshotEditorView() }
            .sheet(isPresented: $showAccountEditor) { AccountEditorView(account: nil) }
        }
    }

    private var baseSnapshots: [NetWorthSnapshot] {
        snapshots.filter { $0.currencyCode == baseCurrency }
    }

    private func breakdownGrid(_ summary: NetWorthSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            StatTile(title: "Cash & Bank", value: MoneyFormat.string(summary.liquid, code: baseCurrency),
                     symbol: "banknote.fill", tint: .blue)
            StatTile(title: "Investments", value: MoneyFormat.string(summary.investments, code: baseCurrency),
                     symbol: "chart.line.uptrend.xyaxis", tint: .purple)
            StatTile(title: "Liabilities", value: MoneyFormat.string(summary.liabilities, code: baseCurrency),
                     symbol: "creditcard.fill", tint: Theme.negative)
            StatTile(title: "Other Assets", value: MoneyFormat.string(summary.otherAssets, code: baseCurrency),
                     symbol: "house.fill", tint: .orange)
        }
    }

    @ViewBuilder
    private func accountsSection(_ engine: FinanceEngine) -> some View {
        let visible = Array(engine.accounts.filter { !$0.isArchived }.sorted { $0.sortOrder < $1.sortOrder }.prefix(5))
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Accounts") {
                NavigationLink("See All") { AccountsListView() }.font(.subheadline.weight(.medium))
            }
            if visible.isEmpty {
                EmptyStateCard(title: "Add your first account",
                               message: "Track cash, bank, savings, investment accounts and debts. Balances stay on this device.",
                               symbol: "building.columns", actionTitle: "Add Account") { showAccountEditor = true }
            } else {
                VStack(spacing: 0) {
                    ForEach(visible) { account in
                        NavigationLink { AccountDetailView(account: account) } label: {
                            AccountRow(account: account, balance: engine.balance(of: account),
                                       countedVia: engine.countedVia(account))
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if account.id != visible.last?.id { Divider() }
                    }
                }
                .card(padding: 14)
            }
        }
    }

    @ViewBuilder
    private func recentSection(_ engine: FinanceEngine) -> some View {
        let recent = Array(recentTransactions.prefix(5))
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Recent Transactions") {
                Button("See All") { app.selectedTab = .transactions }.font(.subheadline.weight(.medium))
            }
            if recent.isEmpty {
                EmptyStateCard(title: "No transactions yet",
                               message: engine.accounts.isEmpty ? "Add an account first, then record income and expenses." : "Use Quick Add to record your first income or expense.",
                               symbol: "list.bullet.rectangle")
            } else {
                VStack(spacing: 0) {
                    ForEach(recent) { transaction in
                        Button { editorRequest = .init(kind: transaction.kind, transaction: transaction) } label: {
                            TransactionRow(transaction: transaction, engine: engine, categories: categories)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if transaction.id != recent.last?.id { Divider() }
                    }
                }
                .card(padding: 14)
            }
        }
    }

    @ViewBuilder
    private var goalsSection: some View {
        let upcoming = Array(goals.filter { $0.allocatedAmount < $0.targetAmount }
            .sorted { ($0.targetDate ?? .distantFuture) < ($1.targetDate ?? .distantFuture) }
            .prefix(3))
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Upcoming Goals") {
                Button("See All") { app.selectedTab = .goals }.font(.subheadline.weight(.medium))
            }
            if upcoming.isEmpty {
                EmptyStateCard(title: "No active goals", message: "Set savings goals like an emergency fund or a car and track progress here.",
                               symbol: "target", actionTitle: "Open Goals") { app.selectedTab = .goals }
            } else {
                VStack(spacing: 12) {
                    ForEach(upcoming) { goal in
                        GoalCompactRow(goal: goal, code: baseCurrency)
                    }
                }
                .card(padding: 14)
            }
        }
    }
}

// MARK: - Hero

struct NetWorthHeroCard: View {
    let summary: NetWorthSummary
    let snapshots: [NetWorthSnapshot]
    let code: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Net Worth")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
            Text(MoneyFormat.string(summary.netWorth, code: code))
                .scaledFont(40)
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText(value: summary.netWorth.doubleValue))
                .animation(.spring, value: summary.netWorth)
            changeLabel
            MetricRow(metrics: [
                Metric(title: "Assets", value: MoneyFormat.string(summary.totalAssets, code: code, fractionDigits: 0)),
                Metric(title: "Liabilities", value: MoneyFormat.string(summary.liabilities, code: code, fractionDigits: 0)),
                Metric(title: "Investments", value: MoneyFormat.string(summary.investments, code: code, fractionDigits: 0)),
            ], onDark: true)
            .padding(.top, 4)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.heroBackground(colorScheme), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 90, weight: .bold))
                .foregroundStyle(.white.opacity(0.06))
                .padding(16)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Compares with the latest recorded snapshot before the start of this month.
    @ViewBuilder
    private var changeLabel: some View {
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        if let previous = snapshots.last(where: { $0.date < monthStart }) {
            let change = summary.netWorth - previous.netWorth
            let fraction: Decimal? = previous.netWorth != 0 ? change / abs(previous.netWorth) : nil
            HStack(spacing: 6) {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                Text(MoneyFormat.string(change, code: code, showSign: true))
                if let fraction { Text("(\(MoneyFormat.percent(fraction, showSign: true)))") }
                Text("vs. \(previous.date.formatted(.dateTime.month(.abbreviated).day()))")
                    .foregroundStyle(.white.opacity(0.78))
            }
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(change >= 0 ? Color(red: 0.6, green: 1, blue: 0.75) : Color(red: 1, green: 0.7, blue: 0.7))
        } else {
            Text("Change vs. last month appears once a previous month is recorded.")
                .font(.footnote).foregroundStyle(.white.opacity(0.78))
        }
    }
}

// MARK: - Chart

enum ChartRange: String, CaseIterable, Identifiable {
    case month = "1M", quarter = "3M", half = "6M", year = "1Y", all = "All"
    var id: String { rawValue }

    func startDate(now: Date = .now) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .month: return calendar.date(byAdding: .month, value: -1, to: now)
        case .quarter: return calendar.date(byAdding: .month, value: -3, to: now)
        case .half: return calendar.date(byAdding: .month, value: -6, to: now)
        case .year: return calendar.date(byAdding: .year, value: -1, to: now)
        case .all: return nil
        }
    }
}

struct NetWorthChartCard: View {
    let snapshots: [NetWorthSnapshot]
    let code: String
    var onRecord: () -> Void
    @State private var range: ChartRange = .half
    @State private var selectedDate: Date?

    private var points: [NetWorthSnapshot] {
        guard let start = range.startDate() else { return snapshots }
        return snapshots.filter { $0.date >= start }
    }

    private var selected: NetWorthSnapshot? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History").font(.headline)
                    if let selected {
                        Text("\(MoneyFormat.string(selected.netWorth, code: code)) · \(selected.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("Recorded snapshots only — never estimated").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button("Record Snapshot", systemImage: "plus.circle", action: onRecord)
                    NavigationLink { SnapshotListView() } label: { Label("Manage Snapshots", systemImage: "list.bullet") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .accessibilityLabel("Snapshot options")
            }

            Picker("Range", selection: $range) {
                ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if points.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No history in this range").font(.subheadline.weight(.medium))
                    Text("WealthOS records one snapshot per day from your actual balances. You can also add past values manually.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Chart {
                    ForEach(points) { snapshot in
                        AreaMark(x: .value("Date", snapshot.date), y: .value("Net Worth", snapshot.netWorth.doubleValue))
                            .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", snapshot.date), y: .value("Net Worth", snapshot.netWorth.doubleValue))
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .interpolationMethod(.monotone)
                        if snapshot.source == .manual || points.count < 3 {
                            PointMark(x: .value("Date", snapshot.date), y: .value("Net Worth", snapshot.netWorth.doubleValue))
                                .symbol(snapshot.source == .manual ? .diamond : .circle)
                                .foregroundStyle(snapshot.source == .manual ? Color.orange : Theme.accent)
                        }
                    }
                    if let selected {
                        RuleMark(x: .value("Selected", selected.date))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(MoneyFormat.compact(v, code: code)) }
                        }
                    }
                }
                .frame(height: 190)
                .animation(.spring(response: 0.5), value: range)
                .accessibilityLabel("Net worth history chart")
                .accessibilityValue("\(points.count) recorded snapshots")

                HStack(spacing: 14) {
                    Label("Auto-recorded", systemImage: "circle.fill").foregroundStyle(Theme.accent)
                    Label("Manual", systemImage: "diamond.fill").foregroundStyle(Theme.warning)
                }
                .font(.caption)
            }
        }
        .card()
        .sensoryFeedback(.selection, trigger: range)
    }
}

// MARK: - Monthly flow

struct MonthlyFlowCard: View {
    let flow: CashFlowSummary
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("This Month").font(.headline)
                Spacer()
                Text(Date.now.formatted(.dateTime.month(.wide).year())).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                flowItem("Income", flow.income, Theme.positive)
                Divider().frame(height: 36)
                flowItem("Expenses", flow.expenses, Theme.negative)
                Divider().frame(height: 36)
                flowItem("Saved", flow.savings, Theme.signColor(flow.savings))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Savings rate").font(.subheadline)
                    Spacer()
                    Text(flow.savingsRate.map { MoneyFormat.percent($0) } ?? "—")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                GeometryReader { proxy in
                    let rate = max(0, min(1, flow.savingsRate?.doubleValue ?? 0))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(Theme.accent.gradient).frame(width: proxy.size.width * rate)
                    }
                }
                .frame(height: 8)
                .animation(.spring, value: flow.savingsRate)
                Text("Transfers and investment purchases are not counted as expenses.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func flowItem(_ title: String, _ value: Decimal, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(MoneyFormat.string(value, code: code, fractionDigits: 0))
                .font(.headline).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
