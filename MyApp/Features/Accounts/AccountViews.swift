import SwiftUI
import SwiftData

struct AccountsListView: View {
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @State private var showEditor = false
    @State private var showArchived = false

    var body: some View {
        FinanceReader { engine in
            List {
                Section {
                    LabeledContent("Net Worth") {
                        MoneyText(amount: engine.summary.netWorth, code: baseCurrency).font(.headline)
                    }
                } footer: {
                    Text("Net worth = all account balances (debts count negative) + tracked holdings at their manually entered prices.")
                }
                ForEach(AccountGroup.allCases, id: \.self) { group in
                    let accounts = engine.accounts
                        .filter { $0.kind.group == group && (showArchived || !$0.isArchived) }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    if !accounts.isEmpty {
                        Section(group.title) {
                            ForEach(accounts) { account in
                                NavigationLink { AccountDetailView(account: account) } label: {
                                    AccountRow(account: account, balance: engine.balance(of: account))
                                        .opacity(account.isArchived ? 0.5 : 1)
                                }
                            }
                        }
                    }
                }
                if engine.accounts.isEmpty {
                    ContentUnavailableView {
                        Label("No Accounts", systemImage: "building.columns")
                    } description: {
                        Text("Add cash, bank, savings or investment accounts, and debts like loans or credit cards.")
                    } actions: {
                        Button("Add Account") { showEditor = true }.prominentButtonStyle()
                    }
                }
            }
        }
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Show Archived", isOn: $showArchived)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Options")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showEditor = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add account")
            }
        }
        .sheet(isPresented: $showEditor) { AccountEditorView(account: nil) }
    }
}

struct AccountDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \TransactionRecord.date, order: .reverse) private var transactions: [TransactionRecord]
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    let account: Account

    @State private var showEditor = false
    @State private var showBalanceUpdate = false
    @State private var showDelete = false
    @State private var editorRequest: TransactionEditorRequest?

    var body: some View {
        FinanceReader { engine in
            let balance = engine.balance(of: account)
            let related = transactions.filter { $0.accountID == account.id || $0.destinationAccountID == account.id }
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(account.kind.isLiability ? "Amount Owed" : "Current Balance")
                            .font(.subheadline).foregroundStyle(.secondary)
                        MoneyText(amount: account.kind.isLiability ? -balance : balance, code: account.currencyCode)
                            .scaledFont(34)
                        if account.currencyCode != baseCurrency {
                            if let converted = engine.balanceInBase(of: account) {
                                Text("≈ \(MoneyFormat.string(account.kind.isLiability ? -converted : converted, code: baseCurrency)) at your manual rate")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("No exchange rate for \(account.currencyCode) — excluded from totals.")
                                    .font(.caption).foregroundStyle(Theme.warning)
                            }
                        }
                        if account.isArchived {
                            Label("Archived", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    Button("Update Balance", systemImage: "pencil.and.list.clipboard") { showBalanceUpdate = true }
                    Button("Add Transaction", systemImage: "plus.circle") {
                        editorRequest = .init(kind: .expense, presetAccountID: account.id)
                    }
                }
                Section("Details") {
                    LabeledContent("Type", value: account.kind.title)
                    LabeledContent("Currency", value: account.currencyCode)
                    LabeledContent(account.kind.isLiability ? "Opening Debt" : "Opening Balance",
                                   value: MoneyFormat.string(account.kind.isLiability ? -account.openingBalance : account.openingBalance,
                                                             code: account.currencyCode))
                    LabeledContent("Opened", value: account.openingDate.formatted(date: .abbreviated, time: .omitted))
                    if !account.institution.isEmpty { LabeledContent("Institution", value: account.institution) }
                    if !account.notes.isEmpty { Text(account.notes).font(.callout).foregroundStyle(.secondary) }
                }
                Section("Activity") {
                    if related.isEmpty {
                        Text("No transactions yet.").foregroundStyle(.secondary)
                    }
                    ForEach(related.prefix(100)) { transaction in
                        Button { editorRequest = .init(kind: transaction.kind, transaction: transaction) } label: {
                            TransactionRow(transaction: transaction, engine: engine, categories: categories)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    Button(account.isArchived ? "Unarchive Account" : "Archive Account",
                           systemImage: account.isArchived ? "tray.and.arrow.up" : "archivebox") {
                        account.isArchived.toggle()
                        try? context.save()
                    }
                    Button("Delete Account", systemImage: "trash", role: .destructive) { showDelete = true }
                } footer: {
                    Text("Archived accounts are hidden from pickers but still count toward net worth.")
                }
            }
            .sheet(isPresented: $showBalanceUpdate) {
                BalanceUpdateView(account: account, currentBalance: balance)
            }
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Edit") { showEditor = true } }
        }
        .sheet(isPresented: $showEditor) { AccountEditorView(account: account) }
        .sheet(item: $editorRequest) { TransactionEditorView(request: $0) }
        .confirmationDialog("Delete “\(account.name)”?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete Account and Its Transactions", role: .destructive) {
                try? LedgerService.delete(account: account, in: context)
                DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
                dismiss()
            }
        } message: {
            let usage = LedgerService.usage(of: account, in: context)
            Text(usage.isEmpty ? "This account has no activity."
                 : "This permanently deletes \(usage.transactions) transaction(s) and \(usage.rules) recurring rule(s), including both sides of transfers. Consider archiving instead.")
        }
    }
}

/// Sets a new actual balance by recording the difference as an adjustment (not income/expense).
struct BalanceUpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    let account: Account
    let currentBalance: Decimal
    @State private var text = ""
    @State private var date = Date.now
    @State private var saveError: String?

    private var validation: AmountValidation { .money(text, allowZero: true, allowNegative: !account.kind.isLiability) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Current", value: MoneyFormat.string(account.kind.isLiability ? -currentBalance : currentBalance,
                                                                        code: account.currencyCode))
                    AmountField(title: account.kind.isLiability ? "Amount owed now" : "Actual balance", text: $text,
                                currencyCode: account.currencyCode, validation: validation, allowNegative: !account.kind.isLiability)
                    DatePicker("As of", selection: $date, in: ...Date.now, displayedComponents: .date)
                } footer: {
                    if let value = validation.value {
                        let target = account.kind.isLiability ? -value : value
                        Text("An adjustment of \(MoneyFormat.string(target - currentBalance, code: account.currencyCode, showSign: true)) will be recorded. Adjustments are not counted as income or expenses.")
                    }
                }
            }
            .navigationTitle("Update Balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let value = validation.value else { return }
                        let target = account.kind.isLiability ? -value : value
                        do {
                            try Persistence.commit(context) {
                                _ = try LedgerService.adjustBalance(of: account, currentBalance: currentBalance, to: target,
                                                                    date: date, in: context)
                            }
                            DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
                            dismiss()
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                    .disabled(validation.value == nil)
                }
            }
            .saveErrorAlert($saveError)
        }
        .presentationDetents([.medium])
    }
}

struct AccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query private var allAccounts: [Account]
    let account: Account?

    @State private var name: String
    @State private var kind: AccountKind
    @State private var currencyCode: String
    @State private var balanceText: String
    @State private var openingDate: Date
    @State private var institution: String
    @State private var notes: String
    @State private var colorName: String

    init(account: Account?, presetKind: AccountKind = .checking) {
        self.account = account
        _name = State(initialValue: account?.name ?? "")
        _kind = State(initialValue: account?.kind ?? presetKind)
        _currencyCode = State(initialValue: account?.currencyCode ?? (UserDefaults.standard.string(forKey: SettingsKey.baseCurrency) ?? "EUR"))
        let opening = account.map { $0.kind.isLiability ? -$0.openingBalance : $0.openingBalance }
        _balanceText = State(initialValue: opening?.inputString ?? "")
        _openingDate = State(initialValue: account?.openingDate ?? .now)
        _institution = State(initialValue: account?.institution ?? "")
        _notes = State(initialValue: account?.notes ?? "")
        _colorName = State(initialValue: account?.colorName ?? "blue")
    }

    private var validation: AmountValidation {
        balanceText.isEmpty ? .valid(0) : .money(balanceText, allowZero: true, allowNegative: !kind.isLiability)
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicateName: Bool {
        allAccounts.contains { $0.id != account?.id && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Account name", text: $name)
                    if duplicateName {
                        Text("Another account already uses this name.").font(.caption).foregroundStyle(Theme.negative)
                    }
                    Picker("Type", selection: $kind) {
                        ForEach(AccountKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(Currencies.supported, id: \.self) { Text("\($0) – \(Currencies.name(for: $0))").tag($0) }
                    }
                    .disabled(account != nil && hasActivity)
                }
                Section {
                    AmountField(title: kind.isLiability ? "Amount owed" : "Opening balance", text: $balanceText,
                                currencyCode: currencyCode, validation: validation, allowNegative: !kind.isLiability)
                    DatePicker("As of", selection: $openingDate, in: ...Date.now, displayedComponents: .date)
                } footer: {
                    Text(kind.isLiability
                         ? "Enter how much you owe as a positive number. It reduces your net worth."
                         : (kind.group == .investments
                            ? "For an investment account, enter uninvested cash or a manually tracked value. Holdings you add under Investments are counted separately — fund purchases from this account to avoid double counting."
                            : "The balance on the date the account starts being tracked."))
                }
                Section {
                    TextField("Institution (optional)", text: $institution)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                }
                Section("Color") { ColorSwatchPicker(selection: $colorName) }
            }
            .navigationTitle(account == nil ? "New Account" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(trimmedName.isEmpty || duplicateName || validation.value == nil)
                }
            }
        }
    }

    private var hasActivity: Bool {
        guard let account else { return false }
        return !LedgerService.usage(of: account, in: context).isEmpty
    }

    private func save() {
        guard let value = validation.value else { return }
        let opening = kind.isLiability ? -abs(value) : value
        if let account {
            account.name = trimmedName
            account.kind = kind
            account.currencyCode = currencyCode
            account.openingBalance = opening
            account.openingDate = openingDate
            account.institution = institution
            account.notes = notes
            account.colorName = colorName
        } else {
            let order = (allAccounts.map(\.sortOrder).max() ?? -1) + 1
            context.insert(Account(name: trimmedName, kind: kind, currencyCode: currencyCode, openingBalance: opening,
                                   openingDate: openingDate, institution: institution, notes: notes, colorName: colorName,
                                   sortOrder: order))
        }
        try? context.save()
        DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
        dismiss()
    }
}
