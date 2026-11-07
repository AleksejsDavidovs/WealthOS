import SwiftUI
import SwiftData

struct GoalDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    let goal: Goal
    @State private var showEditor = false
    @State private var showAdjust = false
    @State private var showDelete = false

    var body: some View {
        let progress = GoalMath.progress(allocated: goal.allocatedAmount, target: goal.targetAmount)
        let color = Theme.color(named: goal.colorName)
        List {
            Section {
                VStack(spacing: 14) {
                    ZStack {
                        ProgressRing(progress: progress, color: color, lineWidth: 16)
                        VStack(spacing: 2) {
                            Image(systemName: goal.type.symbol).font(.title2).foregroundStyle(color)
                            Text(progress.formatted(.percent.precision(.fractionLength(0)))).font(.title.bold()).monospacedDigit()
                        }
                    }
                    .frame(width: 170, height: 170)
                    Text("\(MoneyFormat.string(goal.allocatedAmount, code: baseCurrency)) of \(MoneyFormat.string(goal.targetAmount, code: baseCurrency))")
                        .font(.headline).monospacedDigit()
                    Button("Update Earmarked Amount", systemImage: "plus.forwardslash.minus") { showAdjust = true }
                        .prominentButtonStyle()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            Section("Plan") {
                LabeledContent("Remaining", value: MoneyFormat.string(GoalMath.remaining(allocated: goal.allocatedAmount, target: goal.targetAmount), code: baseCurrency))
                LabeledContent("Monthly contribution", value: MoneyFormat.string(goal.monthlyContribution, code: baseCurrency))
                LabeledContent("Estimated completion") {
                    if progress >= 1 {
                        Text("Reached").foregroundStyle(Theme.positive)
                    } else if let date = GoalMath.estimatedCompletion(allocated: goal.allocatedAmount, target: goal.targetAmount,
                                                                      monthly: goal.monthlyContribution) {
                        Text(date.formatted(.dateTime.month(.wide).year()))
                    } else {
                        Text("Set a monthly contribution").foregroundStyle(.secondary)
                    }
                }
                if let targetDate = goal.targetDate {
                    LabeledContent("Target date", value: targetDate.formatted(date: .abbreviated, time: .omitted))
                    if progress < 1 {
                        if let required = GoalMath.requiredMonthly(allocated: goal.allocatedAmount, target: goal.targetAmount, targetDate: targetDate) {
                            LabeledContent("Needed per month", value: MoneyFormat.string(required, code: baseCurrency))
                            if goal.monthlyContribution >= required {
                                Label("On track", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                            } else {
                                Label("Behind plan by \(MoneyFormat.string(required - goal.monthlyContribution, code: baseCurrency))/month",
                                      systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            }
                        } else {
                            Label("Target date has passed", systemImage: "calendar.badge.exclamationmark").foregroundStyle(.orange)
                        }
                    }
                }
            }
            if !goal.notes.isEmpty {
                Section("Notes") { Text(goal.notes) }
            }
            Section {
                Button("Delete Goal", systemImage: "trash", role: .destructive) { showDelete = true }
            } footer: {
                Text("Deleting a goal only removes the earmark. Your account balances are not affected.")
            }
        }
        .navigationTitle(goal.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { showEditor = true } } }
        .sheet(isPresented: $showEditor) { GoalEditorView(goal: goal) }
        .sheet(isPresented: $showAdjust) { GoalAllocationView(goal: goal) }
        .confirmationDialog("Delete “\(goal.name)”?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete Goal", role: .destructive) {
                context.delete(goal)
                try? context.save()
                dismiss()
            }
        }
    }
}

struct GoalAllocationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    let goal: Goal
    @State private var mode = 0
    @State private var text = ""
    @State private var saved = false

    private var validation: AmountValidation { .money(text, allowZero: mode == 2) }

    private var newAmount: Decimal? {
        guard let value = validation.value else { return nil }
        switch mode {
        case 0: return goal.allocatedAmount + value
        case 1: return goal.allocatedAmount - value
        default: return value
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Action", selection: $mode) {
                    Text("Add").tag(0)
                    Text("Remove").tag(1)
                    Text("Set").tag(2)
                }
                .pickerStyle(.segmented)
                AmountField(title: "Amount", text: $text, currencyCode: baseCurrency, validation: text.isEmpty ? .empty : validation)
                if let newAmount {
                    LabeledContent("New earmarked amount", value: MoneyFormat.string(max(0, newAmount), code: baseCurrency))
                    if newAmount < 0 {
                        Text("You can't remove more than is earmarked.").font(.caption).foregroundStyle(Theme.negative)
                    }
                }
                Section {
                } footer: {
                    Text("Earmarking doesn't move money. It reserves part of your existing balances for this goal.")
                }
            }
            .navigationTitle("Earmarked Amount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let newAmount, newAmount >= 0 else { return }
                        goal.allocatedAmount = newAmount
                        try? context.save()
                        saved = true
                        dismiss()
                    }
                    .disabled((newAmount ?? -1) < 0)
                }
            }
            .sensoryFeedback(.success, trigger: saved)
        }
        .presentationDetents([.medium])
    }
}

struct GoalEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    let goal: Goal?

    @State private var name: String
    @State private var type: GoalType
    @State private var targetText: String
    @State private var hasTargetDate: Bool
    @State private var targetDate: Date
    @State private var allocatedText: String
    @State private var monthlyText: String
    @State private var colorName: String
    @State private var notes: String

    init(goal: Goal?) {
        self.goal = goal
        _name = State(initialValue: goal?.name ?? "")
        _type = State(initialValue: goal?.type ?? .emergencyFund)
        _targetText = State(initialValue: goal?.targetAmount.inputString ?? "")
        _hasTargetDate = State(initialValue: goal == nil || goal?.targetDate != nil)
        _targetDate = State(initialValue: goal?.targetDate ?? Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now)
        _allocatedText = State(initialValue: goal.map { $0.allocatedAmount == 0 ? "" : $0.allocatedAmount.inputString } ?? "")
        _monthlyText = State(initialValue: goal.map { $0.monthlyContribution == 0 ? "" : $0.monthlyContribution.inputString } ?? "")
        _colorName = State(initialValue: goal?.colorName ?? GoalType.emergencyFund.defaultColor)
        _notes = State(initialValue: goal?.notes ?? "")
    }

    private var target: AmountValidation { .money(targetText) }
    private var allocated: AmountValidation { allocatedText.isEmpty ? .valid(0) : .money(allocatedText, allowZero: true) }
    private var monthly: AmountValidation { monthlyText.isEmpty ? .valid(0) : .money(monthlyText, allowZero: true) }
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && target.value != nil && allocated.value != nil && monthly.value != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(GoalType.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    TextField("Goal name", text: $name)
                }
                Section {
                    AmountField(title: "Target amount", text: $targetText, currencyCode: baseCurrency,
                                validation: targetText.isEmpty ? .empty : target)
                    AmountField(title: "Already earmarked", text: $allocatedText, currencyCode: baseCurrency, validation: allocated)
                    AmountField(title: "Monthly contribution", text: $monthlyText, currencyCode: baseCurrency, validation: monthly)
                    Toggle("Target date", isOn: $hasTargetDate.animation())
                    if hasTargetDate {
                        DatePicker("Date", selection: $targetDate, in: Date.now..., displayedComponents: .date)
                    }
                } footer: {
                    Text("“Already earmarked” is part of money you already have. It is not added to your net worth.")
                }
                Section("Color") { ColorSwatchPicker(selection: $colorName) }
                Section { TextField("Notes (optional)", text: $notes, axis: .vertical) }
            }
            .navigationTitle(goal == nil ? "New Goal" : "Edit Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!isValid) }
            }
            .onChange(of: type) { oldType, newType in
                if name.isEmpty || name == oldType.title { name = newType.title }
                if goal == nil { colorName = newType.defaultColor }
            }
            .onAppear { if goal == nil && name.isEmpty { name = type.title } }
        }
    }

    private func save() {
        guard let target = target.value, let allocated = allocated.value, let monthly = monthly.value else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let goal {
            goal.name = trimmed
            goal.type = type
            goal.targetAmount = target
            goal.targetDate = hasTargetDate ? targetDate : nil
            goal.allocatedAmount = allocated
            goal.monthlyContribution = monthly
            goal.colorName = colorName
            goal.notes = notes
        } else {
            context.insert(Goal(name: trimmed, type: type, targetAmount: target, targetDate: hasTargetDate ? targetDate : nil,
                                allocatedAmount: allocated, monthlyContribution: monthly, colorName: colorName, notes: notes))
        }
        try? context.save()
        dismiss()
    }
}
