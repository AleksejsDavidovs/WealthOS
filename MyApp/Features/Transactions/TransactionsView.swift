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

    @State private var searchText = ""
    @State private var filter = TransactionFilter()
    @State private var showFilters = false
    @State private var editorRequest: TransactionEditorRequest?
    @State private var pendingDeletion: TransactionRecord?
    @State private var showAccountEditor = false

    private func transactionList(engine: FinanceEngine) -> some View {
        let filtered = filteredTransactions(engine: engine)
        return List {
            if app.isDemoMode {
                DemoBanner().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            Section {
                FilteredSummaryView(transactions: filtered, engine: engine, code: baseCurrency,
                                    title: filter.isActive || !searchText.isEmpty ? "Filtered" : filter.range.title)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if filtered.isEmpty {
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
                if transactions.isEmpty {
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
                        NavigationLink { StatisticsView() } label: { Label("Statistics", systemImage: "chart.bar.xaxis") }
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
            .sheet(isPresented: $showFilters) { TransactionFilterView(filter: $filter) }
            .sheet(item: $editorRequest) { TransactionEditorView(request: $0) }
            .sheet(isPresented: $showAccountEditor) { AccountEditorView(account: nil) }
            .confirmationDialog("Delete this transaction?", isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let pendingDeletion {
                        context.delete(pendingDeletion)
                        try? context.save()
                        DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
                    }
                    pendingDeletion = nil
                }
            } message: {
                Text("Balances will be recalculated. This can't be undone.")
            }
        }
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

struct FilteredSummaryView: View {
    let transactions: [TransactionRecord]
    let engine: FinanceEngine
    let code: String
    let title: String

    var body: some View {
        let totals = computeTotals()
        HStack(spacing: 12) {
            summaryItem("Income", totals.income, Theme.positive)
            summaryItem("Expenses", totals.expenses, Theme.negative)
            summaryItem("Net", totals.income - totals.expenses, Theme.signColor(totals.income - totals.expenses))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) totals")
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

    private func summaryItem(_ title: String, _ value: Decimal, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(MoneyFormat.string(value, code: code, fractionDigits: 0))
                .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
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
