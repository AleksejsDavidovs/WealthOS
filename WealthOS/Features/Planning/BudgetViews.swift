import SwiftUI
import SwiftData

extension BudgetStatus.Level {
    var tint: Color {
        switch self {
        case .ok: Theme.positive
        case .warning: Theme.warning
        case .over: Theme.negative
        }
    }
}

/// Thin progress bar coloured by the budget level (green < 80 %, amber 80–100 %, red over).
struct BudgetBar: View {
    let fraction: Decimal
    let level: BudgetStatus.Level
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(level.tint.gradient)
                    .frame(width: max(fraction > 0 ? height : 0, proxy.size.width * CGFloat(min(1, fraction.doubleValue))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Compact month overview for the Transactions tab; tapping opens Budgets.
struct BudgetsCard: View {
    let statuses: [BudgetStatus]
    let code: String

    var body: some View {
        if let overview = BudgetMath.overview(statuses) {
            let fraction = overview.limit > 0 ? overview.spent / overview.limit : 0
            let level: BudgetStatus.Level = fraction >= 1 ? .over : (fraction >= Decimal(string: "0.8")! ? .warning : .ok)
            let attention = statuses.filter { $0.level != .ok }.count
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("Budgets · \(Date.now.formatted(.dateTime.month(.wide)))", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if attention > 0 {
                        Text("\(attention) need\(attention == 1 ? "s" : "") attention")
                            .font(.caption.weight(.semibold)).foregroundStyle(level.tint)
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(MoneyFormat.string(overview.spent, code: code, fractionDigits: 0))
                        .font(.title3.weight(.bold)).monospacedDigit()
                    Text("of \(MoneyFormat.string(overview.limit, code: code, fractionDigits: 0))")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text(overview.limit - overview.spent >= 0
                         ? "\(MoneyFormat.string(overview.limit - overview.spent, code: code, fractionDigits: 0)) left"
                         : "\(MoneyFormat.string(overview.spent - overview.limit, code: code, fractionDigits: 0)) over")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(level.tint).monospacedDigit()
                }
                BudgetBar(fraction: fraction, level: level, height: 7)
            }
            .card(padding: 16, shadow: false)  // lives in a List row
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens budgets")
        }
    }
}

struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \Budget.createdAt) private var budgets: [Budget]
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @State private var month = Date.now
    @State private var editing: BudgetEditorRequest?
    @State private var pendingDeletion: Budget?
    @State private var saveError: String?

    struct BudgetEditorRequest: Identifiable {
        let id = UUID()
        var budget: Budget?
    }

    private let calendar = Calendar.current
    private var isCurrentMonth: Bool { calendar.isDate(month, equalTo: .now, toGranularity: .month) }

    var body: some View {
        FinanceReader { engine in
            let statuses = PlanningMonitor.budgetStatuses(budgets, entries: engine.cashFlowEntries(), month: month)
            let byID = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            List {
                Section {
                    HStack {
                        Button { withAnimation { month = calendar.date(byAdding: .month, value: -1, to: month) ?? month } } label: {
                            Image(systemName: "chevron.left").font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("Previous month")
                        Spacer()
                        Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                        Spacer()
                        Button { withAnimation { month = calendar.date(byAdding: .month, value: 1, to: month) ?? month } } label: {
                            Image(systemName: "chevron.right").font(.body.weight(.semibold))
                        }
                        .disabled(isCurrentMonth)
                        .accessibilityLabel("Next month")
                    }
                    .buttonStyle(.borderless)
                    // The centred month title would otherwise start the separator mid-row.
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    if let overview = BudgetMath.overview(statuses) {
                        overviewRow(overview)
                    }
                }
                if budgets.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No Budgets Yet", systemImage: "gauge.with.dots.needle.33percent")
                        } description: {
                            Text("Set a monthly limit for a category — or for all spending — and see how much is left.")
                        } actions: {
                            Button("Add Budget") { editing = .init(budget: nil) }.buttonStyle(.borderedProminent)
                        }
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(sorted(budgets, by: byID)) { budget in
                            if let status = byID[budget.id] {
                                Button { editing = .init(budget: budget) } label: { row(budget, status) }
                                    .buttonStyle(.plain)
                                    .swipeActions {
                                        Button(role: .destructive) { pendingDeletion = budget } label: { Label("Delete", systemImage: "trash") }
                                    }
                            }
                        }
                        Button { editing = .init(budget: nil) } label: { Label("Add Budget", systemImage: "plus.circle.fill") }
                    } footer: {
                        Text("Counts recorded expenses only — transfers, balance adjustments and bank transactions still pending or in review aren't spending.")
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Budgets")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { BudgetEditorView(budget: $0.budget) }
        .confirmationDialog("Delete this budget?", isPresented: Binding(get: { pendingDeletion != nil },
                                                                        set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Budget", role: .destructive) {
                if let pendingDeletion {
                    do { try Persistence.commit(context) { context.delete(pendingDeletion) } }
                    catch { saveError = error.localizedDescription }
                }
                pendingDeletion = nil
            }
        } message: {
            Text("Your transactions aren't affected.")
        }
        .saveErrorAlert($saveError)
    }

    private func sorted(_ budgets: [Budget], by statuses: [UUID: BudgetStatus]) -> [Budget] {
        budgets.sorted { a, b in
            if (a.categoryID == nil) != (b.categoryID == nil) { return a.categoryID == nil }
            return (statuses[a.id]?.fraction ?? 0) > (statuses[b.id]?.fraction ?? 0)
        }
    }

    private func category(_ id: UUID?) -> TransactionCategory? { id.flatMap { id in categories.first { $0.id == id } } }

    private func overviewRow(_ overview: (limit: Decimal, spent: Decimal)) -> some View {
        let fraction = overview.limit > 0 ? overview.spent / overview.limit : 0
        let level: BudgetStatus.Level = fraction >= 1 ? .over : (fraction >= Decimal(string: "0.8")! ? .warning : .ok)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(MoneyFormat.string(overview.spent, code: baseCurrency)).font(.title2.weight(.bold)).monospacedDigit()
                Text("of \(MoneyFormat.string(overview.limit, code: baseCurrency))").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text(MoneyFormat.percent(fraction, fractionDigits: 0)).font(.headline).foregroundStyle(level.tint)
            }
            BudgetBar(fraction: fraction, level: level, height: 8)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func row(_ budget: Budget, _ status: BudgetStatus) -> some View {
        let category = category(budget.categoryID)
        return HStack(spacing: 12) {
            IconBadge(symbol: category?.symbol ?? "sum", color: Theme.color(named: category?.colorName ?? "indigo"), size: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(category?.name ?? "All spending").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(MoneyFormat.string(status.spent, code: baseCurrency, fractionDigits: 0)) / \(MoneyFormat.string(status.limit, code: baseCurrency, fractionDigits: 0))")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                BudgetBar(fraction: status.fraction, level: status.level)
                HStack {
                    Text(status.remaining >= 0
                         ? "\(MoneyFormat.string(status.remaining, code: baseCurrency, fractionDigits: 0)) left"
                         : "\(MoneyFormat.string(-status.remaining, code: baseCurrency, fractionDigits: 0)) over")
                        .foregroundStyle(status.level.tint)
                    if status.carry > 0 {
                        Text("· incl. \(MoneyFormat.string(status.carry, code: baseCurrency, fractionDigits: 0)) carried over")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let projected = status.projected, status.spent > 0 {
                        Text("~\(MoneyFormat.string(projected, code: baseCurrency, fractionDigits: 0)) by month end")
                            .foregroundStyle(projected > status.limit ? Theme.negative : .secondary)
                    }
                }
                .font(.caption).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct BudgetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @Query private var budgets: [Budget]
    let budget: Budget?

    @State private var categoryID: UUID?
    @State private var amountText: String
    @State private var rollover: Bool
    @State private var saveError: String?

    init(budget: Budget?) {
        self.budget = budget
        _categoryID = State(initialValue: budget?.categoryID)
        _amountText = State(initialValue: budget?.amount.inputString ?? "")
        _rollover = State(initialValue: budget?.rollover ?? false)
    }

    private var validation: AmountValidation { AmountValidation.money(amountText) }
    /// One budget per category (and one for all spending).
    private var isTaken: Bool { budgets.contains { $0.id != budget?.id && $0.categoryID == categoryID } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Category", selection: $categoryID) {
                        Text("All spending").tag(UUID?.none)
                        ForEach(categories.filter { $0.kind == .expense }) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    AmountField(title: "Monthly limit", text: $amountText, currencyCode: baseCurrency, validation: validation)
                } footer: {
                    if isTaken { Text("This category already has a budget.").foregroundStyle(Theme.negative) }
                }
                Section {
                    Toggle("Carry over what's left", isOn: $rollover)
                } footer: {
                    Text("Adds last month's unspent amount to this month's limit. Overspending is never carried.")
                }
            }
            .navigationTitle(budget == nil ? "New Budget" : "Edit Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(validation.value == nil || isTaken)
                }
            }
            .saveErrorAlert($saveError)
        }
    }

    private func save() {
        guard let amount = validation.value else { return }
        do {
            try Persistence.commit(context) {
                if let budget {
                    if budget.categoryID != categoryID || budget.amount != amount {
                        // A changed limit or category starts its notifications afresh this month.
                        budget.alertedMonth = ""
                        budget.alertedLevel = 0
                    }
                    budget.categoryID = categoryID
                    budget.amount = amount
                    budget.rollover = rollover
                } else {
                    context.insert(Budget(categoryID: categoryID, amount: amount, rollover: rollover))
                }
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Settings → Notifications. Asks for permission the first time one is turned on.
struct PlanningNotificationSettings: View {
    @AppStorage(SettingsKey.budgetAlerts) private var budgetAlerts = false
    @AppStorage(SettingsKey.subscriptionReminders) private var reminders = false
    @State private var denied = false

    var body: some View {
        Section {
            Toggle(isOn: binding($budgetAlerts)) { Label("Budget alerts", systemImage: "gauge.with.dots.needle.67percent") }
            Toggle(isOn: binding($reminders)) { Label("Subscription reminders", systemImage: "bell.badge") }
        } header: {
            Text("Notifications")
        } footer: {
            Text(denied
                 ? "Notifications are turned off for WealthOS in iOS Settings → Notifications."
                 : "Budget alerts at 80 % and 100 % of a monthly budget, once each per month. Reminders the day before a confirmed subscription renews. Notifications are created on this iPhone and never show amounts.")
        }
    }

    private func binding(_ storage: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { storage.wrappedValue }, set: { newValue in
            guard newValue else { storage.wrappedValue = false; return }
            Task {
                let granted = await PlanningMonitor.notifier.authorize()
                storage.wrappedValue = granted
                denied = !granted
            }
        })
    }
}
