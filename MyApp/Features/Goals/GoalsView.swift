import SwiftUI
import SwiftData

struct GoalsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \Goal.createdAt) private var goals: [Goal]
    @State private var showEditor = false

    var body: some View {
        NavigationStack {
            FinanceReader { engine in
                ScrollView {
                    VStack(spacing: 20) {
                        if app.isDemoMode { DemoBanner() }
                        earmarkCard(engine)
                        NavigationLink { PurchaseImpactView() } label: { whatIfCard }
                            .buttonStyle(.plain)
                        if goals.isEmpty {
                            EmptyStateCard(title: "No goals yet",
                                           message: "Create goals like an emergency fund, a car or a trip. Earmark part of your savings and track progress.",
                                           symbol: "target", actionTitle: "Create Goal") { showEditor = true }
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                ForEach(goals) { goal in
                                    NavigationLink { GoalDetailView(goal: goal) } label: {
                                        GoalCard(goal: goal, code: baseCurrency)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .screenBackground()
            }
            .navigationTitle("Goals")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showEditor = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add goal")
                }
            }
            .sheet(isPresented: $showEditor) { GoalEditorView(goal: nil) }
        }
    }

    private func earmarkCard(_ engine: FinanceEngine) -> some View {
        let summary = engine.summary
        let overview = GoalMath.overview(summary: summary, goals: goals.map { ($0.allocatedAmount, $0.targetAmount) })
        let allocated = overview.allocated
        let target = overview.target
        let available = overview.available
        let unallocated = overview.unallocated
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Earmarked for Goals").font(.subheadline).foregroundStyle(.secondary)
                    MoneyText(amount: allocated, code: baseCurrency).scaledFont(30)
                    Text("of \(MoneyFormat.string(target, code: baseCurrency, fractionDigits: 0)) total targets")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProgressRing(progress: GoalMath.progress(allocated: allocated, target: target), color: Theme.accent, lineWidth: 9)
                    .frame(width: 64, height: 64)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cash + investments").font(.caption).foregroundStyle(.secondary)
                    Text(MoneyFormat.string(available, code: baseCurrency, fractionDigits: 0)).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Not earmarked").font(.caption).foregroundStyle(.secondary)
                    Text(MoneyFormat.string(unallocated, code: baseCurrency, fractionDigits: 0))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(unallocated < 0 ? Theme.negative : .primary)
                }
            }
            if overview.isOverAllocated {
                Label("Goals earmark more than your cash and investments. Reduce allocations to keep them realistic.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
            // These exclusions are why the figure can legitimately stay put after a save.
            if !summary.missingRateCurrencies.isEmpty {
                Label("Not included: balances in \(summary.missingRateCurrencies.sorted().formatted(.list(type: .and))) — add an exchange rate in Settings.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
            if engine.scheduledCount > 0 {
                Label("\(engine.scheduledCount) future-dated \(engine.scheduledCount == 1 ? "entry counts" : "entries count") from \(engine.scheduledCount == 1 ? "its" : "their") date.",
                      systemImage: "calendar.badge.clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Counts cash, bank, savings and investments — not property, other assets or debts. Earmarks are portions of money you already have and are not added to your net worth.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private var whatIfCard: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: "questionmark.bubble.fill", color: .purple, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("What if I buy…?").font(.headline)
                Text("See how a big purchase changes your projected wealth.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .card(padding: 14)
    }
}

struct GoalCard: View {
    let goal: Goal
    let code: String

    var body: some View {
        let progress = GoalMath.progress(allocated: goal.allocatedAmount, target: goal.targetAmount)
        let color = Theme.color(named: goal.colorName)
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                ProgressRing(progress: progress, color: color, lineWidth: 9)
                Image(systemName: goal.type.symbol).font(.title3).foregroundStyle(color)
            }
            .frame(width: 66, height: 66)
            VStack(alignment: .leading, spacing: 3) {
                Text(goal.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(progress.formatted(.percent.precision(.fractionLength(0)))).font(.title3.weight(.bold)).monospacedDigit()
                Text("\(MoneyFormat.string(goal.allocatedAmount, code: code, fractionDigits: 0)) of \(MoneyFormat.string(goal.targetAmount, code: code, fractionDigits: 0))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                if let completion = GoalMath.estimatedCompletion(allocated: goal.allocatedAmount, target: goal.targetAmount,
                                                                 monthly: goal.monthlyContribution), progress < 1 {
                    Text("Est. \(completion.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if progress >= 1 {
                    Label("Reached", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(Theme.positive)
                }
            }
        }
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

struct GoalCompactRow: View {
    let goal: Goal
    let code: String

    var body: some View {
        let progress = GoalMath.progress(allocated: goal.allocatedAmount, target: goal.targetAmount)
        let color = Theme.color(named: goal.colorName)
        HStack(spacing: 12) {
            ZStack {
                ProgressRing(progress: progress, color: color, lineWidth: 5)
                Image(systemName: goal.type.symbol).font(.caption).foregroundStyle(color)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.name).font(.subheadline.weight(.medium))
                Text(goal.targetDate.map { "Target \($0.formatted(.dateTime.month(.abbreviated).year()))" } ?? "No target date")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(progress.formatted(.percent.precision(.fractionLength(0)))).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(MoneyFormat.string(GoalMath.remaining(allocated: goal.allocatedAmount, target: goal.targetAmount), code: code, fractionDigits: 0) + " left")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
