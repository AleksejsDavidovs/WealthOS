import SwiftUI

/// Exact-value editor for a scenario, including future purchases and recurring expenses.
struct ScenarioEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    let title: String
    let onSave: (SimulationParameters) -> Void

    @State private var years: Int
    @State private var fields: [Field: String]
    @State private var contributionGrows: Bool
    @State private var purchases: [OneTimePurchase]
    @State private var recurring: [FutureRecurringExpense]
    @State private var showPurchaseEditor = false
    @State private var showRecurringEditor = false

    enum Field: String, CaseIterable {
        case startingCash, startingInvestments, monthlyIncome, monthlyExpenses, monthlyContribution
        case salaryGrowth, expenseGrowth, annualReturn, cashInterest, inflation, volatility

        var title: String {
            switch self {
            case .startingCash: "Starting cash & other (net)"
            case .startingInvestments: "Starting investments"
            case .monthlyIncome: "Monthly income (net)"
            case .monthlyExpenses: "Monthly expenses"
            case .monthlyContribution: "Monthly investing"
            case .salaryGrowth: "Salary growth / yr"
            case .expenseGrowth: "Expense growth / yr"
            case .annualReturn: "Investment return / yr"
            case .cashInterest: "Cash interest / yr"
            case .inflation: "Inflation / yr"
            case .volatility: "Return volatility / yr"
            }
        }

        var isPercent: Bool {
            switch self {
            case .salaryGrowth, .expenseGrowth, .annualReturn, .cashInterest, .inflation, .volatility: true
            default: false
            }
        }

        var allowsNegative: Bool { self == .startingCash || self == .salaryGrowth || self == .expenseGrowth || self == .annualReturn }

        var keyPath: WritableKeyPath<SimulationParameters, Decimal> {
            switch self {
            case .startingCash: \.startingCash
            case .startingInvestments: \.startingInvestments
            case .monthlyIncome: \.monthlyIncome
            case .monthlyExpenses: \.monthlyExpenses
            case .monthlyContribution: \.monthlyContribution
            case .salaryGrowth: \.salaryGrowth
            case .expenseGrowth: \.expenseGrowth
            case .annualReturn: \.annualReturn
            case .cashInterest: \.cashInterest
            case .inflation: \.inflation
            case .volatility: \.volatility
            }
        }
    }

    private let original: SimulationParameters

    init(parameters: SimulationParameters, title: String, onSave: @escaping (SimulationParameters) -> Void) {
        self.original = parameters
        self.title = title
        self.onSave = onSave
        _years = State(initialValue: parameters.years)
        var values: [Field: String] = [:]
        for field in Field.allCases {
            let value = parameters[keyPath: field.keyPath]
            values[field] = field.isPercent ? (value * 100).inputString : value.inputString
        }
        _fields = State(initialValue: values)
        _contributionGrows = State(initialValue: parameters.contributionGrowsWithSalary)
        _purchases = State(initialValue: parameters.oneTimePurchases)
        _recurring = State(initialValue: parameters.recurringExpenses)
    }

    private func validation(_ field: Field) -> AmountValidation {
        let text = fields[field] ?? ""
        if field.isPercent {
            let range: ClosedRange<Decimal> = field == .volatility ? 0...100 : (field.allowsNegative ? -50...50 : 0...50)
            return .percent(text, range: range)
        }
        let result = AmountValidation.money(text, allowZero: true, allowNegative: field.allowsNegative)
        guard let value = result.value else { return result }
        let limit = field == .startingCash || field == .startingInvestments
            ? SimulationParameters.maxStartingBalance : SimulationParameters.maxMonthlyAmount
        if abs(value) > limit {
            return .invalid("Maximum is \(MoneyFormat.string(limit, code: baseCurrency, fractionDigits: 0)).")
        }
        return result
    }

    private var isValid: Bool { Field.allCases.allSatisfy { validation($0).value != nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Projection: \(years) years", value: $years, in: SimulationParameters.yearRange)
                }
                Section("Starting Point") { fieldRows([.startingCash, .startingInvestments]) }
                Section {
                    fieldRows([.monthlyIncome, .monthlyExpenses, .monthlyContribution])
                    Toggle("Investing grows with salary", isOn: $contributionGrows)
                } header: {
                    Text("Monthly Cash Flow")
                } footer: {
                    Text("Investing is funded only from the monthly surplus (income − expenses).")
                }
                Section("Rates (%)") {
                    fieldRows([.salaryGrowth, .expenseGrowth, .annualReturn, .cashInterest, .inflation, .volatility])
                }
                Section {
                    ForEach(purchases) { purchase in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(purchase.name)
                                Text(purchase.date.formatted(.dateTime.month(.wide).year())).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(MoneyFormat.string(purchase.amount, code: baseCurrency, fractionDigits: 0)).monospacedDigit()
                        }
                    }
                    .onDelete { purchases.remove(atOffsets: $0) }
                    Button("Add Purchase", systemImage: "plus.circle") { showPurchaseEditor = true }
                } header: {
                    Text("One-Time Purchases")
                } footer: {
                    Text("e.g. a car, a wedding or a home deposit. Paid from cash, then investments if needed.")
                }
                Section {
                    ForEach(recurring) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name)
                                Text("From \(item.startDate.formatted(.dateTime.month(.abbreviated).year()))" +
                                     (item.endDate.map { " to \($0.formatted(.dateTime.month(.abbreviated).year()))" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(MoneyFormat.string(item.monthlyAmount, code: baseCurrency, fractionDigits: 0))/mo").monospacedDigit()
                        }
                    }
                    .onDelete { recurring.remove(atOffsets: $0) }
                    Button("Add Recurring Expense", systemImage: "plus.circle") { showRecurringEditor = true }
                } header: {
                    Text("Recurring Future Expenses")
                }
            }
            .navigationTitle("\(title) Scenario")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!isValid)
                }
            }
            .sheet(isPresented: $showPurchaseEditor) {
                PurchaseEditor { purchases.append($0); purchases.sort { $0.date < $1.date } }
            }
            .sheet(isPresented: $showRecurringEditor) {
                RecurringExpenseEditor { recurring.append($0) }
            }
        }
    }

    @ViewBuilder
    private func fieldRows(_ list: [Field]) -> some View {
        ForEach(list, id: \.self) { field in
            AmountField(title: field.title,
                        text: Binding(get: { fields[field] ?? "" }, set: { fields[field] = $0 }),
                        currencyCode: field.isPercent ? nil : baseCurrency,
                        validation: validation(field), prompt: "0",
                        allowNegative: field.allowsNegative)
        }
    }

    private func save() {
        var result = original
        for field in Field.allCases {
            guard let value = validation(field).value else { return }
            result[keyPath: field.keyPath] = value
        }
        result.years = years
        result.contributionGrowsWithSalary = contributionGrows
        result.oneTimePurchases = purchases
        result.recurringExpenses = recurring
        onSave(result)
        dismiss()
    }
}

struct PurchaseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    let onAdd: (OneTimePurchase) -> Void
    @State private var name = ""
    @State private var amountText = ""
    @State private var date = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now

    var body: some View {
        NavigationStack {
            Form {
                TextField("What (e.g. Car)", text: $name)
                AmountField(title: "Amount", text: $amountText, currencyCode: baseCurrency,
                            validation: amountText.isEmpty ? .empty : .money(amountText))
                DatePicker("When", selection: $date, in: Date.now..., displayedComponents: .date)
            }
            .navigationTitle("One-Time Purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let amount = AmountValidation.money(amountText).value else { return }
                        onAdd(OneTimePurchase(name: name.isEmpty ? "Purchase" : name, amount: amount, date: date))
                        dismiss()
                    }
                    .disabled(AmountValidation.money(amountText).value == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct RecurringExpenseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    let onAdd: (FutureRecurringExpense) -> Void
    @State private var name = ""
    @State private var amountText = ""
    @State private var startDate = Date.now
    @State private var hasEnd = false
    @State private var endDate = Calendar.current.date(byAdding: .year, value: 5, to: .now) ?? .now
    @State private var grows = true

    var body: some View {
        NavigationStack {
            Form {
                TextField("What (e.g. Child care)", text: $name)
                AmountField(title: "Per month", text: $amountText, currencyCode: baseCurrency,
                            validation: amountText.isEmpty ? .empty : .money(amountText))
                DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                Toggle("Ends", isOn: $hasEnd.animation())
                if hasEnd { DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date) }
                Toggle("Grows with inflation", isOn: $grows)
            }
            .navigationTitle("Recurring Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let amount = AmountValidation.money(amountText).value else { return }
                        onAdd(FutureRecurringExpense(name: name.isEmpty ? "Expense" : name, monthlyAmount: amount,
                                                     startDate: startDate, endDate: hasEnd ? endDate : nil, growsWithInflation: grows))
                        dismiss()
                    }
                    .disabled(AmountValidation.money(amountText).value == nil)
                }
            }
        }
    }
}
