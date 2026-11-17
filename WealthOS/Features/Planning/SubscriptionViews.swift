import SwiftUI
import SwiftData

enum SubscriptionDecisions {
    /// Records (or replaces) the user's decision for a payee. Callers commit.
    static func set(_ status: SubscriptionDecisionStatus, for key: String, in context: ModelContext) throws {
        for old in try context.fetch(FetchDescriptor<SubscriptionDecision>()) where old.key == key { context.delete(old) }
        context.insert(SubscriptionDecision(key: key, status: status))
    }

    /// Forgets the decision: a confirmed subscription goes back to being a suggestion (if detected).
    static func clear(for key: String, in context: ModelContext) throws {
        for old in try context.fetch(FetchDescriptor<SubscriptionDecision>()) where old.key == key { context.delete(old) }
    }
}

/// Reactive detection for views: re-runs when transactions, decisions or bank rows change.
struct SubscriptionsReader<Content: View>: View {
    @Query private var decisions: [SubscriptionDecision]
    @Query private var bankRows: [BankTransaction]
    @Query private var categories: [TransactionCategory]
    @ViewBuilder let content: ([DetectedSubscription], FinanceEngine) -> Content

    var body: some View {
        FinanceReader { engine in
            let charges = SubscriptionDetector.charges(entries: engine.cashFlowEntries(), records: engine.transactions,
                                                       bankRows: bankRows)
            let detected = SubscriptionDetector.detect(
                charges: charges,
                decisions: Dictionary(decisions.map { ($0.key, $0.status) }, uniquingKeysWith: { a, _ in a }),
                subscriptionCategoryIDs: PlanningMonitor.subscriptionCategoryIDs(categories))
            content(detected, engine)
        }
    }
}

/// One compact row for Home. Hidden when nothing is detected or confirmed.
struct SubscriptionsCard: View {
    let subscriptions: [DetectedSubscription]
    let code: String

    var body: some View {
        let summary = SubscriptionDetector.summary(subscriptions)
        if summary.confirmedCount + summary.suggestedCount > 0 {
            HStack(spacing: 12) {
                IconBadge(symbol: "repeat.circle.fill", color: .purple, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subscriptions").font(.subheadline.weight(.semibold))
                    Text(detail(summary)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if summary.confirmedCount > 0 {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(MoneyFormat.string(summary.monthly, code: code)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        Text("per month").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .card(padding: 14)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens subscriptions")
        }
    }

    private func detail(_ summary: SubscriptionDetector.Summary) -> String {
        var parts: [String] = []
        if summary.confirmedCount > 0 { parts.append("\(summary.confirmedCount) active") }
        if summary.suggestedCount > 0 { parts.append("\(summary.suggestedCount) to review") }
        return parts.joined(separator: " · ")
    }
}

struct SubscriptionsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @AppStorage(SettingsKey.subscriptionReminders) private var reminders = false
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @State private var saveError: String?

    var body: some View {
        SubscriptionsReader { subscriptions, engine in
            let confirmed = subscriptions.filter { $0.status == .confirmed }
            let suggested = subscriptions.filter { $0.status == .suggested }
            let summary = SubscriptionDetector.summary(subscriptions)
            List {
                if !confirmed.isEmpty {
                    Section {
                        HStack {
                            stat("Per month", MoneyFormat.string(summary.monthly, code: baseCurrency))
                            stat("Per year", MoneyFormat.string(summary.yearly, code: baseCurrency, fractionDigits: 0))
                            stat("Active", "\(summary.confirmedCount)")
                        }
                        .padding(.vertical, 4)
                    }
                    Section("Your Subscriptions") {
                        ForEach(confirmed) { subscription in
                            NavigationLink { SubscriptionDetailView(key: subscription.key) } label: { row(subscription) }
                        }
                    }
                }
                if !suggested.isEmpty {
                    Section {
                        ForEach(suggested) { subscription in
                            VStack(alignment: .leading, spacing: 10) {
                                NavigationLink { SubscriptionDetailView(key: subscription.key) } label: { row(subscription) }
                                HStack(spacing: 10) {
                                    Button { decide(.confirmed, subscription.key) } label: {
                                        Label("Confirm", systemImage: "checkmark").lineLimit(1).frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent).tint(Theme.accentFill)
                                    .accessibilityLabel("Confirm \(subscription.title) as a subscription")
                                    Button { decide(.dismissed, subscription.key) } label: {
                                        Text("Not one").lineLimit(1).frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered).tint(.secondary)
                                    .accessibilityLabel("\(subscription.title) is not a subscription")
                                }
                                .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Suggestions")
                    } footer: {
                        Text("Found from regular payments of a similar amount to the same payee. They aren't counted until you confirm them.")
                    }
                }
                if subscriptions.isEmpty {
                    Section {
                        ContentUnavailableView("No Subscriptions Found", systemImage: "repeat.circle",
                                               description: Text("Regular payments to the same payee appear here as suggestions. You can also swipe right on an expense in Transactions to mark it."))
                    }
                    .listRowBackground(Color.clear)
                }
                if !confirmed.isEmpty {
                    Section {
                        Label(reminders ? "Reminders are on: you're notified the day before a charge."
                                        : "Turn on reminders in Settings → Notifications to be told the day before a charge.",
                              systemImage: reminders ? "bell.fill" : "bell")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .animation(.default, value: subscriptions.map(\.key))
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .saveErrorAlert($saveError)
    }

    private func decide(_ status: SubscriptionDecisionStatus, _ key: String) {
        do { try Persistence.commit(context) { try SubscriptionDecisions.set(status, for: key, in: context) } }
        catch { saveError = error.localizedDescription }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ subscription: DetectedSubscription) -> some View {
        SubscriptionRow(subscription: subscription, category: subscription.categoryID.flatMap { id in categories.first { $0.id == id } },
                        code: baseCurrency)
    }
}

struct SubscriptionRow: View {
    let subscription: DetectedSubscription
    let category: TransactionCategory?
    let code: String

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: category?.symbol ?? "repeat", color: Theme.color(named: category?.colorName ?? "purple"), size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(subscription.cadence.title) · next \(subscription.nextDate.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let increase = subscription.priceIncrease {
                        badge("Price up \(MoneyFormat.string(increase.from, code: code)) → \(MoneyFormat.string(increase.to, code: code))",
                              Theme.warning)
                    }
                    if subscription.isMissed { badge("Charge missed", .secondary) }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(MoneyFormat.string(subscription.amount, code: code)).font(.subheadline.weight(.semibold)).monospacedDigit()
                if subscription.cadence != .monthly {
                    Text("\(MoneyFormat.string(subscription.monthlyCost, code: code))/mo").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }
}

struct SubscriptionDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @State private var saveError: String?
    let key: String

    var body: some View {
        SubscriptionsReader { subscriptions, _ in
            if let subscription = subscriptions.first(where: { $0.key == key }) {
                List {
                    Section {
                        SubscriptionRow(subscription: subscription,
                                        category: subscription.categoryID.flatMap { id in categories.first { $0.id == id } },
                                        code: baseCurrency)
                    }
                    Section {
                        LabeledContent("Per month", value: MoneyFormat.string(subscription.monthlyCost, code: baseCurrency))
                        LabeledContent("Per year", value: MoneyFormat.string(subscription.yearlyCost, code: baseCurrency))
                        LabeledContent("Last charge", value: subscription.lastDate.formatted(date: .abbreviated, time: .omitted))
                        LabeledContent(subscription.isMissed ? "Was expected" : "Next charge",
                                       value: subscription.nextDate.formatted(date: .abbreviated, time: .omitted))
                    }
                    Section("Charges") {
                        ForEach(subscription.charges.reversed()) { charge in
                            LabeledContent(charge.date.formatted(date: .abbreviated, time: .omitted),
                                           value: MoneyFormat.string(charge.amount, code: baseCurrency))
                                .monospacedDigit()
                        }
                    }
                    Section {
                        if subscription.status == .suggested {
                            Button("It's a Subscription") { decide { try SubscriptionDecisions.set(.confirmed, for: key, in: context) } }
                        } else {
                            Button("Remove from Subscriptions") { decide { try SubscriptionDecisions.clear(for: key, in: context) } }
                        }
                        Button("Not a Subscription", role: .destructive) {
                            decide { try SubscriptionDecisions.set(.dismissed, for: key, in: context) }
                            dismiss()
                        }
                    } footer: {
                        Text("“Not a subscription” hides this payee from suggestions. Transactions are never changed.")
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ContentUnavailableView("Not a Subscription", systemImage: "repeat.circle",
                                       description: Text("This payee is no longer listed."))
            }
        }
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .saveErrorAlert($saveError)
    }

    private func decide(_ change: () throws -> Void) {
        do { try Persistence.commit(context, change) } catch { saveError = error.localizedDescription }
    }
}
