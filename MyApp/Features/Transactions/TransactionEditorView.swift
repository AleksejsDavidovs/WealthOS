import SwiftUI
import SwiftData

struct TransactionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @Query private var rates: [CurrencyRate]
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"

    private let existing: TransactionRecord?
    @State private var kind: TransactionKind
    @State private var amountText: String
    @State private var accountID: UUID?
    @State private var destinationAccountID: UUID?
    @State private var destinationAmountText: String
    @State private var categoryID: UUID?
    @State private var date: Date
    @State private var note: String
    @State private var isRecurring = false
    @State private var frequency: RecurrenceFrequency = .monthly
    @State private var hasEndDate = false
    @State private var endDate = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
    @State private var showDeleteConfirmation = false
    @State private var showAccountEditor = false
    @State private var saveCount = 0
    @State private var saveError: String?
    @FocusState private var amountFocused: Bool

    init(request: TransactionEditorRequest) {
        let transaction = request.transaction
        existing = transaction
        _kind = State(initialValue: transaction?.kind ?? request.kind)
        _amountText = State(initialValue: transaction?.amount.inputString ?? "")
        _accountID = State(initialValue: transaction?.accountID ?? request.presetAccountID)
        _destinationAccountID = State(initialValue: transaction?.destinationAccountID)
        _destinationAmountText = State(initialValue: transaction?.destinationAmount?.inputString ?? "")
        _categoryID = State(initialValue: transaction?.categoryID)
        _date = State(initialValue: transaction?.date ?? .now)
        _note = State(initialValue: transaction?.note ?? "")
    }

    private var activeAccounts: [Account] {
        accounts.filter { !$0.isArchived || $0.id == accountID || $0.id == destinationAccountID }
    }
    private var account: Account? { accounts.first { $0.id == accountID } }
    private var destination: Account? { accounts.first { $0.id == destinationAccountID } }
    private var needsDestinationAmount: Bool {
        kind == .transfer && account != nil && destination != nil && account?.currencyCode != destination?.currencyCode
    }
    private var amountValidation: AmountValidation {
        kind == .adjustment ? .money(amountText, allowNegative: true) : .money(amountText)
    }
    private var destinationValidation: AmountValidation { .money(destinationAmountText) }
    private var kindCategories: [TransactionCategory] {
        guard let categoryKind = kind.categoryKind else { return [] }
        return categories.filter { $0.kind == categoryKind }
    }

    private var validationMessage: String? {
        if accounts.isEmpty { return "Create an account first." }
        if amountValidation.value == nil { return amountValidation.message ?? "Enter an amount." }
        if account == nil { return "Choose an account." }
        if kind == .transfer {
            if destination == nil { return "Choose a destination account." }
            if destinationAccountID == accountID { return "Source and destination must be different." }
            if needsDestinationAmount && destinationValidation.value == nil { return "Enter the amount received in \(destination?.currencyCode ?? "")." }
        }
        if isRecurring && hasEndDate && endDate < date { return "End date must be after the start date." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if existing == nil || existing?.kind != .adjustment {
                    Section {
                        Picker("Type", selection: $kind) {
                            ForEach([TransactionKind.expense, .income, .transfer]) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }

                Section {
                    VStack(spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(Currencies.symbol(for: account?.currencyCode ?? baseCurrency))
                                .scaledFont(30, weight: .semibold)
                                .foregroundStyle(.secondary)
                            TextField("0", text: $amountText)
                                .scaledFont(48)
                                .keyboardType(kind == .adjustment ? .numbersAndPunctuation : .decimalPad)
                                .monospacedDigit()
                                .focused($amountFocused)
                                .fixedSize()
                                .accessibilityLabel("Amount")
                        }
                        .frame(maxWidth: .infinity)
                        if let message = amountValidation.message {
                            Text(message).font(.caption).foregroundStyle(Theme.negative)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    if accounts.isEmpty {
                        Button("Create an Account", systemImage: "plus.circle") { showAccountEditor = true }
                    } else {
                        Picker(kind == .transfer ? "From" : "Account", selection: $accountID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(activeAccounts) { Text("\($0.name) (\($0.currencyCode))").tag(Optional($0.id)) }
                        }
                        if kind == .transfer {
                            Picker("To", selection: $destinationAccountID) {
                                Text("Choose…").tag(UUID?.none)
                                ForEach(activeAccounts.filter { $0.id != accountID }) {
                                    Text("\($0.name) (\($0.currencyCode))").tag(Optional($0.id))
                                }
                            }
                            if needsDestinationAmount, let destination {
                                AmountField(title: "Received", text: $destinationAmountText, currencyCode: destination.currencyCode,
                                            validation: destinationAmountText.isEmpty ? .empty : destinationValidation)
                            }
                        }
                    }
                } footer: {
                    if kind == .transfer {
                        Text("Transfers move money between your own accounts and are never counted as income or expenses.")
                    } else if kind == .adjustment {
                        Text("Adjustments correct a balance and are not counted as income or expenses.")
                    }
                }

                if !kindCategories.isEmpty {
                    Section("Category") {
                        CategoryGrid(categories: kindCategories, selection: $categoryID)
                    }
                }

                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                } footer: {
                    if date > Calendar.current.startOfDay(for: .now).addingTimeInterval(86_399) {
                        Text("Future-dated transactions are scheduled and affect balances on their date.")
                    }
                }

                if existing == nil && kind != .adjustment {
                    Section {
                        Toggle("Repeat", isOn: $isRecurring.animation())
                        if isRecurring {
                            Picker("Frequency", selection: $frequency) {
                                ForEach(RecurrenceFrequency.allCases) { Text($0.title).tag($0) }
                            }
                            Toggle("End Date", isOn: $hasEndDate.animation())
                            if hasEndDate {
                                DatePicker("Ends", selection: $endDate, in: date..., displayedComponents: .date)
                            }
                        }
                    } footer: {
                        if isRecurring {
                            Text("Future occurrences are added automatically when they're due. Manage them under Transactions → Recurring.")
                        }
                    }
                }

                if existing != nil {
                    Section {
                        Button("Delete Transaction", role: .destructive) { showDeleteConfirmation = true }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New \(kind.title)" : "Edit \(kind.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(validationMessage != nil)
                }
            }
            // The decimal pad has no return key; dragging the form dismisses any keyboard.
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if let message = validationMessage, !amountText.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .padding(8).frame(maxWidth: .infinity).background(.bar)
                }
            }
            .confirmationDialog("Delete this transaction?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteTransaction() }
            } message: {
                Text("Account balances will be recalculated. This can't be undone.")
            }
            .sheet(isPresented: $showAccountEditor) { AccountEditorView(account: nil) }
            .onAppear(perform: applyDefaults)
            .onChange(of: kind) { _, _ in applyDefaults(resetCategory: true) }
            .onChange(of: destinationAccountID) { _, _ in suggestDestinationAmount() }
            .onChange(of: amountText) { _, _ in suggestDestinationAmount() }
            .sensoryFeedback(.success, trigger: saveCount)
            .saveErrorAlert($saveError)
        }
    }

    private func applyDefaults() { applyDefaults(resetCategory: false) }

    private func applyDefaults(resetCategory: Bool) {
        if accountID == nil {
            accountID = accounts.first { !$0.isArchived && $0.kind.group == .liquid }?.id ?? accounts.first?.id
        }
        if resetCategory || categoryID == nil || !kindCategories.contains(where: { $0.id == categoryID }) {
            categoryID = kindCategories.first?.id
        }
        if existing == nil && amountText.isEmpty { amountFocused = true }
    }

    /// Pre-fills the received amount for cross-currency transfers using the manual rates.
    private func suggestDestinationAmount() {
        guard needsDestinationAmount, existing == nil, let account, let destination,
              let amount = amountValidation.value else { return }
        let converter = CurrencyConverter.make(base: baseCurrency, rates: rates)
        if let converted = converter.convert(amount, from: account.currencyCode, to: destination.currencyCode) {
            destinationAmountText = Money.round(converted).inputString
        }
    }

    private func save() {
        guard validationMessage == nil, let amount = amountValidation.value, let accountID else { return }
        let destinationAmount = needsDestinationAmount ? destinationValidation.value : nil
        let category = kind.categoryKind == nil ? nil : categoryID
        let destinationID = kind == .transfer ? destinationAccountID : nil
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            // Balances are derived from records, so an edit replaces the old effect rather than
            // stacking on it. If saving fails, the edit is rolled back and no balance changes.
            try Persistence.commit(context) {
                if let existing {
                    existing.kind = kind
                    existing.amount = amount
                    existing.accountID = accountID
                    existing.destinationAccountID = destinationID
                    existing.destinationAmount = destinationAmount
                    existing.categoryID = category
                    existing.date = date
                    existing.note = trimmedNote
                } else if isRecurring {
                    let isDue = date <= Calendar.current.startOfDay(for: .now).addingTimeInterval(86_399)
                    let rule = RecurringRule(kind: kind, amount: amount, destinationAmount: destinationAmount, accountID: accountID,
                                             destinationAccountID: destinationID, categoryID: category, note: trimmedNote,
                                             frequency: frequency, startDate: date, endDate: hasEndDate ? endDate : nil,
                                             generatedCount: isDue ? 1 : 0)
                    context.insert(rule)
                    if isDue {
                        context.insert(TransactionRecord(kind: kind, amount: amount, destinationAmount: destinationAmount, date: date,
                                                         note: trimmedNote, accountID: accountID, destinationAccountID: destinationID,
                                                         categoryID: category, recurringRuleID: rule.id))
                    }
                } else {
                    context.insert(TransactionRecord(kind: kind, amount: amount, destinationAmount: destinationAmount, date: date,
                                                     note: trimmedNote, accountID: accountID, destinationAccountID: destinationID,
                                                     categoryID: category))
                }
            }
        } catch {
            saveError = error.localizedDescription
            return
        }
        if isRecurring { RecurringService.processDueRules(in: context) }
        DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
        saveCount += 1
        dismiss()
    }

    private func deleteTransaction() {
        guard let existing else { return }
        do {
            try Persistence.commit(context) { context.delete(existing) }
        } catch {
            saveError = error.localizedDescription
            return
        }
        DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
        dismiss()
    }
}

struct CategoryGrid: View {
    let categories: [TransactionCategory]
    @Binding var selection: UUID?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 12) {
            ForEach(categories) { category in
                let isSelected = selection == category.id
                Button {
                    selection = category.id
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: category.symbol)
                            .font(.title3)
                            .foregroundStyle(isSelected ? .white : Theme.color(named: category.colorName))
                            .frame(width: 46, height: 46)
                            .background(isSelected ? AnyShapeStyle(Theme.color(named: category.colorName).gradient)
                                                   : AnyShapeStyle(Theme.color(named: category.colorName).opacity(0.15)),
                                        in: Circle())
                        Text(category.name).font(.caption).lineLimit(1).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(category.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .sensoryFeedback(.selection, trigger: selection)
        .animation(.spring(response: 0.3), value: selection)
    }
}
