import SwiftUI
import SwiftData

/// First launch. Every field is optional. Entered balances become real opening balances
/// of accounts; income/expense estimates are stored only as simulator defaults.
/// No transactions or sample data are ever written to the real database here.
struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Environment(AppLockManager.self) private var lock
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @AppStorage(SettingsKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(SettingsKey.lockEnabled) private var lockEnabled = false
    @AppStorage(SettingsKey.estimatedIncome) private var estimatedIncome = ""
    @AppStorage(SettingsKey.estimatedExpenses) private var estimatedExpenses = ""

    @State private var step = 0
    @State private var currency = "EUR"
    @State private var cashText = ""
    @State private var savingsText = ""
    @State private var investmentsText = ""
    @State private var incomeText = ""
    @State private var expensesText = ""
    @State private var enableLock = false

    private let stepCount = 5

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(step), total: Double(stepCount - 1))
                .tint(Theme.accent)
                .padding(.horizontal)
                .padding(.top, 8)
                .opacity(step == 0 ? 0 : 1)
            Group {
                switch step {
                case 0: welcome
                case 1: currencyStep
                case 2: balancesStep
                case 3: monthlyStep
                default: securityStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)
            footer
        }
        .screenBackground()
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)
        .sensoryFeedback(.selection, trigger: step)
    }

    // MARK: Steps

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)
                Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                    .font(.system(size: 88))
                    .foregroundStyle(Theme.accent.gradient)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text("WealthOS").font(.largeTitle.bold())
                    Text("Your private finance tracker and financial life simulator.")
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 18) {
                    feature("lock.shield.fill", "Private by design", "Everything stays on this iPhone. No account, no cloud, no tracking.")
                    feature("chart.pie.fill", "Your whole picture", "Accounts, spending, investments and goals in one place.")
                    feature("wand.and.sparkles", "See your future", "Project scenarios and Monte Carlo ranges for your net worth.")
                }
                .padding(.horizontal, 8)
                Button("Explore with Demo Data") { app.enterDemoMode() }
                    .font(.subheadline)
                Text("Demo data lives in memory only and never mixes with your real data.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }

    private var currencyStep: some View {
        stepContainer(title: "Preferred currency", subtitle: "Totals are shown in this currency. You can change it later.") {
            Picker("Currency", selection: $currency) {
                ForEach(Currencies.supported, id: \.self) { Text("\($0) – \(Currencies.name(for: $0))").tag($0) }
            }
            .pickerStyle(.wheel)
        }
    }

    private var balancesStep: some View {
        stepContainer(title: "What do you have today?",
                      subtitle: "All optional. Each amount becomes an account with that opening balance, which you can rename or edit later.") {
            VStack(spacing: 14) {
                AmountField(title: "Cash & bank", text: $cashText, currencyCode: currency, validation: optional(cashText))
                Divider()
                AmountField(title: "Savings", text: $savingsText, currencyCode: currency, validation: optional(savingsText))
                Divider()
                AmountField(title: "Investments", text: $investmentsText, currencyCode: currency, validation: optional(investmentsText))
            }
            .card()
        }
    }

    private var monthlyStep: some View {
        stepContainer(title: "Your typical month",
                      subtitle: "Rough estimates help the simulator start with sensible values. They are not recorded as transactions.") {
            VStack(spacing: 14) {
                AmountField(title: "Monthly income", text: $incomeText, currencyCode: currency, validation: optional(incomeText))
                Divider()
                AmountField(title: "Monthly expenses", text: $expensesText, currencyCode: currency, validation: optional(expensesText))
            }
            .card()
        }
    }

    private var securityStep: some View {
        stepContainer(title: "Protect your data", subtitle: "Lock WealthOS with \(lock.biometryName) when you leave the app. Your device passcode works as a fallback.") {
            VStack(spacing: 18) {
                Image(systemName: lock.biometrySymbol).font(.system(size: 64)).foregroundStyle(Theme.accent)
                Toggle("Require \(lock.biometryName)", isOn: $enableLock).card()
                if let message = lock.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(Theme.warning)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            Button {
                if step < stepCount - 1 { step += 1 } else { Task { await finish() } }
            } label: {
                Text(step == 0 ? "Get Started" : (step == stepCount - 1 ? "Finish" : "Continue"))
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
            }
            .prominentButtonStyle()
            .controlSize(.large)
            .disabled(!canContinue)
        }
        .padding()
    }

    // MARK: Helpers

    private func optional(_ text: String) -> AmountValidation {
        text.isEmpty ? .empty : .money(text, allowZero: true)
    }

    private var canContinue: Bool {
        switch step {
        case 2: [cashText, savingsText, investmentsText].allSatisfy { $0.isEmpty || optional($0).value != nil }
        case 3: [incomeText, expensesText].allSatisfy { $0.isEmpty || optional($0).value != nil }
        default: true
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Theme.accent).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stepContainer<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.largeTitle.bold())
                    Text(subtitle).font(.body).foregroundStyle(.secondary)
                }
                content()
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func finish() async {
        if enableLock {
            lockEnabled = await lock.setLockEnabled(true)
        }
        baseCurrency = currency
        LedgerService.seedDefaultCategoriesIfNeeded(in: context)
        let entries: [(String, AccountKind, String, String)] = [
            ("Main Account", .checking, cashText, "blue"),
            ("Savings", .savings, savingsText, "green"),
            ("Investments", .investment, investmentsText, "purple"),
        ]
        for (index, entry) in entries.enumerated() {
            guard let value = optional(entry.2).value else { continue }
            context.insert(Account(name: entry.0, kind: entry.1, currencyCode: currency, openingBalance: value,
                                   colorName: entry.3, sortOrder: index))
        }
        estimatedIncome = optional(incomeText).value.map { "\($0)" } ?? ""
        estimatedExpenses = optional(expensesText).value.map { "\($0)" } ?? ""
        try? context.save()
        DataMaintenance.refreshSnapshot(context: context, baseCurrency: currency)
        hasCompletedOnboarding = true
    }
}
