import SwiftUI
import SwiftData

enum DateRangeOption: String, CaseIterable, Identifiable {
    case all, thisMonth, lastMonth, last3Months, thisYear, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All Time"
        case .thisMonth: "This Month"
        case .lastMonth: "Last Month"
        case .last3Months: "Last 3 Months"
        case .thisYear: "This Year"
        case .custom: "Custom"
        }
    }

    func interval(customStart: Date, customEnd: Date, now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .all: return nil
        case .thisMonth: return calendar.dateInterval(of: .month, for: now)
        case .lastMonth:
            return calendar.date(byAdding: .month, value: -1, to: now).flatMap { calendar.dateInterval(of: .month, for: $0) }
        case .last3Months:
            guard let current = calendar.dateInterval(of: .month, for: now),
                  let start = calendar.date(byAdding: .month, value: -2, to: current.start) else { return nil }
            return DateInterval(start: start, end: current.end)
        case .thisYear: return calendar.dateInterval(of: .year, for: now)
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(customStart, customEnd))) ?? customEnd
            return DateInterval(start: start, end: end)
        }
    }
}

struct TransactionFilter: Equatable {
    var kinds: Set<TransactionKind> = []
    var categoryIDs: Set<UUID> = []
    var accountID: UUID?
    var range: DateRangeOption = .all
    var customStart = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    var customEnd = Date.now

    var isActive: Bool { !kinds.isEmpty || !categoryIDs.isEmpty || accountID != nil || range != .all }
    var activeCount: Int {
        (kinds.isEmpty ? 0 : 1) + (categoryIDs.isEmpty ? 0 : 1) + (accountID == nil ? 0 : 1) + (range == .all ? 0 : 1)
    }
}

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \TransactionRecord.date, order: .reverse) private var transactions: [TransactionRecord]
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @Query(sort: \BankTransaction.bookingDate, order: .reverse) private var bankRows: [BankTransaction]

    @State private var searchText = ""
    @State private var filter = TransactionFilter()
    @State private var showFilters = false
    @State private var editorRequest: TransactionEditorRequest?
    @State private var pendingDeletion: TransactionRecord?
    @State private var saveError: String?
    @State private var showAccountEditor = false
    @State private var showAnalytics = false
    #if DEBUG
    @State private var showDebugCategoryEditor = false
    #endif

    private func transactionList(engine: FinanceEngine) -> some View {
        let filtered = filteredTransactions(engine: engine)
        return List {
            if app.isDemoMode {
                DemoBanner().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            Section {
                Button { showAnalytics = true } label: {
                    CashFlowCard(transactions: filtered, engine: engine, code: baseCurrency,
                                 title: filter.isActive || !searchText.isEmpty ? "Filtered" : filter.range.title)
                }
                .buttonStyle(CardPressStyle())
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            if !app.isDemoMode { bankSections(engine: engine) }
            if filtered.isEmpty && !transactions.isEmpty {
                Section {
                    if searchText.isEmpty {
                        ContentUnavailableView {
                            Label("No Matching Transactions", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("Nothing matches the current filters.")
                        } actions: {
                            Button("Reset Filters") { filter = TransactionFilter() }
                        }
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
                .listRowBackground(Color.clear)
            }
            ForEach(grouped(filtered), id: \.0) { day, items in
                Section(day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())) {
                    ForEach(items) { transaction in
                        Button { editorRequest = .init(kind: transaction.kind, transaction: transaction) } label: {
                            TransactionRow(transaction: transaction, engine: engine, categories: categories, showsDate: false)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { pendingDeletion = transaction } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    var body: some View {
        NavigationStack {
            FinanceReader { engine in
                if transactions.isEmpty && (app.isDemoMode || !hasBankActivity) {
                    TransactionsEmptyState(hasAccounts: !engine.accounts.isEmpty, isDemo: app.isDemoMode,
                                           onAdd: { editorRequest = .init(kind: $0) },
                                           onAddAccount: { showAccountEditor = true })
                } else {
                    transactionList(engine: engine)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        NavigationLink { AnalyticsView() } label: { Label("Analytics", systemImage: "chart.pie") }
                        NavigationLink { RecurringRulesView() } label: { Label("Recurring", systemImage: "repeat") }
                        NavigationLink { CategoryManagerView() } label: { Label("Categories", systemImage: "square.grid.2x2") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(filter.isActive ? "Filters, \(filter.activeCount) active" : "Filters")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { editorRequest = .init(kind: .expense) } label: { Label("Expense", systemImage: TransactionKind.expense.symbol) }
                        Button { editorRequest = .init(kind: .income) } label: { Label("Income", systemImage: TransactionKind.income.symbol) }
                        Button { editorRequest = .init(kind: .transfer) } label: { Label("Transfer", systemImage: TransactionKind.transfer.symbol) }
                    } label: {
                        Image(systemName: "plus")
                    } primaryAction: {
                        editorRequest = .init(kind: .expense)
                    }
                    .accessibilityLabel("Add transaction")
                }
            }
            .navigationDestination(isPresented: $showAnalytics) { AnalyticsView(filter: filter) }
            #if DEBUG
            .onAppear {
                // Development aid: `-UIScreen analytics|categoryEditor` (see AppModel).
                switch app.debugScreen {
                case "analytics": showAnalytics = true
                case "analyticsMonth": filter.range = .thisMonth; showAnalytics = true
                case "categoryEditor": showDebugCategoryEditor = true
                default: break
                }
                app.debugScreen = nil
            }
            .sheet(isPresented: $showDebugCategoryEditor) { CategoryEditorView(category: nil, kind: .expense) }
            #endif
            .sheet(isPresented: $showFilters) { TransactionFilterView(filter: $filter) }
            .sheet(item: $editorRequest) { TransactionEditorView(request: $0) }
            .sheet(isPresented: $showAccountEditor) { AccountEditorView(account: nil) }
            .confirmationDialog("Delete this transaction?", isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let pendingDeletion {
                        do {
                            try Persistence.commit(context) { context.delete(pendingDeletion) }
                            DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                    pendingDeletion = nil
                }
            } message: {
                Text("Balances will be recalculated. This can't be undone.")
            }
            .saveErrorAlert($saveError)
        }
    }

    // MARK: Bank transactions not in the ledger yet

    private var reviewRows: [BankTransaction] { bankRows.filter { $0.status == .booked && $0.resolution == .needsReview } }
    private var pendingRows: [BankTransaction] { bankRows.filter { $0.status == .pending } }
    private var hasBankActivity: Bool { !reviewRows.isEmpty || !pendingRows.isEmpty }

    /// Booked bank transactions waiting for a decision, and pending ones. Neither is in the
    /// ledger, so neither changes totals; the account balance already reflects them via the bank.
    @ViewBuilder
    private func bankSections(engine: FinanceEngine) -> some View {
        let review = reviewRows
        if !review.isEmpty {
            Section {
                ForEach(review.prefix(5)) { row in
                    NavigationLink { BankReviewDetailView(row: row) } label: {
                        BankTransactionSummaryRow(row: row, accountName: accountName(for: row, engine: engine))
                    }
                }
                NavigationLink { BankReviewListView() } label: {
                    Label(review.count > 5 ? "Review All \(review.count)" : "Open Review", systemImage: "questionmark.circle")
                        .foregroundStyle(Theme.accent)
                }
            } header: {
                Text("From your bank · to review")
            } footer: {
                Text("Not counted in income or spending until you record them. Your bank balance already includes them.")
            }
        }
        let pending = pendingRows
        if !pending.isEmpty {
            Section {
                ForEach(pending) { row in
                    BankTransactionSummaryRow(row: row, accountName: accountName(for: row, engine: engine))
                        .opacity(0.6)
                }
            } header: {
                Text("Pending at the bank")
            } footer: {
                Text("Recorded automatically once the bank books them.")
            }
        }
    }

    private func accountName(for row: BankTransaction, engine: FinanceEngine) -> String? {
        engine.bank.links.first { $0.accountKey == row.accountKey }?.localAccountID.flatMap { engine.accountsByID[$0]?.name }
    }

    private func filteredTransactions(engine: FinanceEngine) -> [TransactionRecord] {
        let interval = filter.range.interval(customStart: filter.customStart, customEnd: filter.customEnd)
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let categoryNames = Dictionary(categories.map { ($0.id, $0.name.lowercased()) }, uniquingKeysWith: { a, _ in a })
        return transactions.filter { transaction in
            if !filter.kinds.isEmpty && !filter.kinds.contains(transaction.kind) { return false }
            if !filter.categoryIDs.isEmpty && !(transaction.categoryID.map(filter.categoryIDs.contains) ?? false) { return false }
            if let accountID = filter.accountID, transaction.accountID != accountID && transaction.destinationAccountID != accountID { return false }
            if let interval, !(transaction.date >= interval.start && transaction.date < interval.end) { return false }
            if !query.isEmpty {
                let haystack = [transaction.note.lowercased(),
                                transaction.categoryID.flatMap { categoryNames[$0] } ?? "",
                                engine.accountsByID[transaction.accountID]?.name.lowercased() ?? "",
                                transaction.destinationAccountID.flatMap { engine.accountsByID[$0]?.name.lowercased() } ?? "",
                                "\(transaction.amount)"]
                if !haystack.contains(where: { $0.contains(query) }) { return false }
            }
            return true
        }
    }

    private func grouped(_ items: [TransactionRecord]) -> [(Date, [TransactionRecord])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: items) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }
}

/// First-run screen for the Transactions tab: explains the next step and offers direct actions.
struct TransactionsEmptyState: View {
    let hasAccounts: Bool
    let isDemo: Bool
    let onAdd: (TransactionKind) -> Void
    let onAddAccount: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if isDemo { DemoBanner() }
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.12)).frame(width: 112, height: 112)
                    Image(systemName: "list.bullet.rectangle.portrait.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .symbolRenderingMode(.hierarchical)
                }
                .padding(.top, 36)
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(hasAccounts ? "No transactions yet" : "Start with an account")
                        .font(.title2.bold())
                    Text(hasAccounts
                         ? "Record income and spending to see monthly totals, savings rate and category insights."
                         : "Transactions belong to an account. Add your bank account, cash or card first.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    if hasAccounts {
                        Button { onAdd(.expense) } label: {
                            Label("Add Expense", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity)
                        }
                        .prominentButtonStyle()
                        HStack(spacing: 12) {
                            Button { onAdd(.income) } label: {
                                Label("Income", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                            }
                            Button { onAdd(.transfer) } label: {
                                Label("Transfer", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(action: onAddAccount) {
                            Label("Add Account", systemImage: "building.columns.fill").frame(maxWidth: .infinity)
                        }
                        .prominentButtonStyle()
                    }
                }
                .controlSize(.large)
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 14) {
                    tip("arrow.left.arrow.right", "Transfers between your accounts never count as income or spending.")
                    tip("repeat", "Turn on Repeat for rent, salary or subscriptions — they're added automatically.")
                    tip("square.and.arrow.down", "Import past transactions from CSV in Settings.")
                }
                .card()
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("Transactions")
        .navigationBarTitleDisplayMode(.large)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        }
    }
}

/// The period's cash flow at a glance; tapping it opens Analytics. Counts only income and expense
/// records up to today (no transfers, balance adjustments, scheduled or unrecorded bank rows).
struct CashFlowCard: View {
    let transactions: [TransactionRecord]
    let engine: FinanceEngine
    let code: String
    let title: String

    var body: some View {
        let totals = computeTotals()
        let net = totals.income - totals.expenses
        let sum = totals.income + totals.expenses
        let incomeShare = sum > 0 ? CGFloat((totals.income / sum).doubleValue) : 0.5
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(title, systemImage: "calendar").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Analytics").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Net cash flow").font(.caption).foregroundStyle(.secondary)
                Text(MoneyFormat.string(net, code: code, showSign: net != 0))
                    .scaledFont(32, weight: .bold, relativeTo: .largeTitle)
                    .monospacedDigit().foregroundStyle(Theme.signColor(net))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
            }
            GeometryReader { proxy in
                let spacing: CGFloat = sum > 0 && totals.income > 0 && totals.expenses > 0 ? 3 : 0
                let width = max(0, proxy.size.width - spacing)
                HStack(spacing: spacing) {
                    if sum == 0 {
                        Capsule().fill(Color.secondary.opacity(0.18))
                    } else {
                        if totals.income > 0 {
                            Capsule().fill(Theme.positive.gradient).frame(width: max(6, width * incomeShare))
                        }
                        if totals.expenses > 0 {
                            Capsule().fill(Theme.negative.gradient)
                        }
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            HStack(alignment: .top) {
                figure("Income", totals.income, Theme.positive, symbol: "arrow.down.left")
                Spacer(minLength: 12)
                figure("Expenses", totals.expenses, Theme.negative, symbol: "arrow.up.right", alignment: .trailing)
            }
        }
        .card()
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .animation(.spring(response: 0.35), value: net)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cash flow, \(title). Net \(MoneyFormat.string(net, code: code, showSign: true)). Income \(MoneyFormat.string(totals.income, code: code)). Expenses \(MoneyFormat.string(totals.expenses, code: code)).")
        .accessibilityHint("Opens analytics")
        .accessibilityAddTraits(.isButton)
    }

    private func computeTotals() -> (income: Decimal, expenses: Decimal) {
        var income: Decimal = 0, expenses: Decimal = 0
        for transaction in transactions where transaction.date <= engine.asOfDate {
            guard let account = engine.accountsByID[transaction.accountID],
                  let value = engine.converter.toBase(transaction.amount, from: account.currencyCode) else { continue }
            if transaction.kind == .income { income += value }
            if transaction.kind == .expense { expenses += value }
        }
        return (income, expenses)
    }

    private func figure(_ title: String, _ value: Decimal, _ color: Color, symbol: String,
                        alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.caption2.weight(.bold)).foregroundStyle(color)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(MoneyFormat.string(value, code: code))
                .font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

/// Subtle press feedback for tappable cards.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25), value: configuration.isPressed)
    }
}

struct TransactionFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: TransactionFilter
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]

    var body: some View {
        NavigationStack {
            Form {
                Section("Date Range") {
                    Picker("Range", selection: $filter.range) {
                        ForEach(DateRangeOption.allCases) { Text($0.title).tag($0) }
                    }
                    if filter.range == .custom {
                        DatePicker("From", selection: $filter.customStart, displayedComponents: .date)
                        DatePicker("To", selection: $filter.customEnd, displayedComponents: .date)
                    }
                }
                Section("Type") {
                    ForEach(TransactionKind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { filter.kinds.contains(kind) },
                            set: { if $0 { filter.kinds.insert(kind) } else { filter.kinds.remove(kind) } }))
                    }
                }
                Section("Account") {
                    Picker("Account", selection: $filter.accountID) {
                        Text("All Accounts").tag(UUID?.none)
                        ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                ForEach(CategoryKind.allCases, id: \.self) { kind in
                    Section("\(kind.title) Categories") {
                        ForEach(categories.filter { $0.kind == kind }) { category in
                            Button {
                                if filter.categoryIDs.contains(category.id) { filter.categoryIDs.remove(category.id) }
                                else { filter.categoryIDs.insert(category.id) }
                            } label: {
                                HStack {
                                    Image(systemName: category.symbol).foregroundStyle(Theme.color(named: category.colorName))
                                    Text(category.name).foregroundStyle(.primary)
                                    Spacer()
                                    if filter.categoryIDs.contains(category.id) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .accessibilityAddTraits(filter.categoryIDs.contains(category.id) ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { filter = TransactionFilter() }.disabled(!filter.isActive)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
