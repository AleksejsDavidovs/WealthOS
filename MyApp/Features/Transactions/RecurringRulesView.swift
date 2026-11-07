import SwiftUI
import SwiftData

struct RecurringRulesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecurringRule.createdAt) private var rules: [RecurringRule]
    @Query private var accounts: [Account]
    @Query private var categories: [TransactionCategory]
    @State private var editing: RecurringRule?

    var body: some View {
        List {
            if rules.isEmpty {
                ContentUnavailableView("No Recurring Transactions", systemImage: "repeat",
                                       description: Text("Turn on “Repeat” when adding a transaction to create one."))
            } else {
                Section {
                    ForEach(rules) { rule in
                        Button { editing = rule } label: { row(rule) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(rules[index]) }
                        try? context.save()
                    }
                } footer: {
                    Text("Deleting a rule stops future occurrences. Transactions already created are kept.")
                }
            }
        }
        .navigationTitle("Recurring")
        .sheet(item: $editing) { RecurringRuleEditorView(rule: $0) }
    }

    private func row(_ rule: RecurringRule) -> some View {
        let account = accounts.first { $0.id == rule.accountID }
        let category = rule.categoryID.flatMap { id in categories.first { $0.id == id } }
        return HStack(spacing: 12) {
            IconBadge(symbol: rule.kind == .transfer ? "arrow.left.arrow.right" : (category?.symbol ?? "repeat"),
                      color: rule.kind == .transfer ? .indigo : Theme.color(named: category?.colorName ?? "gray"))
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.note.isEmpty ? (category?.name ?? rule.kind.title) : rule.note).font(.body.weight(.medium))
                Group {
                    if let next = rule.nextDueDate {
                        Text("\(rule.frequency.title) · next \(next.formatted(date: .abbreviated, time: .omitted))")
                    } else {
                        Text(rule.isActive ? "Ended" : "Paused")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(MoneyFormat.string(rule.kind == .expense ? -rule.amount : rule.amount, code: account?.currencyCode ?? "EUR",
                                    showSign: rule.kind != .transfer))
                .font(.body.weight(.semibold)).monospacedDigit()
                .foregroundStyle(rule.kind == .income ? Theme.positive : .primary)
        }
        .opacity(rule.isActive ? 1 : 0.5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct RecurringRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let rule: RecurringRule
    @State private var amountText: String
    @State private var note: String
    @State private var isActive: Bool
    @State private var hasEndDate: Bool
    @State private var endDate: Date

    init(rule: RecurringRule) {
        self.rule = rule
        _amountText = State(initialValue: rule.amount.inputString)
        _note = State(initialValue: rule.note)
        _isActive = State(initialValue: rule.isActive)
        _hasEndDate = State(initialValue: rule.endDate != nil)
        _endDate = State(initialValue: rule.endDate ?? Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now)
    }

    private var validation: AmountValidation { .money(amountText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(title: "Amount", text: $amountText, validation: validation)
                    TextField("Note", text: $note)
                    LabeledContent("Frequency", value: rule.frequency.title)
                    LabeledContent("Started", value: rule.startDate.formatted(date: .abbreviated, time: .omitted))
                } footer: {
                    Text("Changes apply to future occurrences only.")
                }
                Section {
                    Toggle("Active", isOn: $isActive)
                    Toggle("End Date", isOn: $hasEndDate.animation())
                    if hasEndDate {
                        DatePicker("Ends", selection: $endDate, in: rule.startDate..., displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("Recurring \(rule.kind.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let amount = validation.value else { return }
                        rule.amount = amount
                        rule.note = note
                        rule.isActive = isActive
                        rule.endDate = hasEndDate ? endDate : nil
                        try? context.save()
                        RecurringService.processDueRules(in: context)
                        dismiss()
                    }
                    .disabled(validation.value == nil)
                }
            }
        }
    }
}
