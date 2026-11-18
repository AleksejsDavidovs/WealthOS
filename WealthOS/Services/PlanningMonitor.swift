import Foundation
import SwiftData
import UserNotifications

/// Local notifications only — nothing leaves the device. Texts never contain amounts.
protocol PlanningNotifying: AnyObject {
    func authorize() async -> Bool
    func post(id: String, title: String, body: String, at date: Date?) async
    func removePending(prefix: String) async
    /// True only while iOS hasn't asked the user yet.
    func isAuthorizationUndetermined() async -> Bool
}

final class SystemPlanningNotifier: PlanningNotifying {
    private var center: UNUserNotificationCenter { .current() }

    func authorize() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func post(id: String, title: String, body: String, at date: Date?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var trigger: UNNotificationTrigger?
        if let date {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        }
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func isAuthorizationUndetermined() async -> Bool {
        await center.notificationSettings().authorizationStatus == .notDetermined
    }

    func removePending(prefix: String) async {
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

@MainActor
enum PlanningMonitor {
    static var notifier: PlanningNotifying = SystemPlanningNotifier()

    struct BudgetAlert: Equatable {
        let budgetID: UUID
        let level: Int
        let title: String
        let body: String
    }

    static func budgetStatuses(_ budgets: [Budget], entries: [CashFlowEntry], month: Date = .now, now: Date = .now,
                               calendar: Calendar = .current) -> [BudgetStatus] {
        budgets.map {
            BudgetMath.status(of: .init(id: $0.id, categoryID: $0.categoryID, amount: $0.amount, rollover: $0.rollover),
                              month: month, entries: entries, now: now, calendar: calendar)
        }
    }

    static func subscriptions(context: ModelContext, engine: FinanceEngine, now: Date = .now,
                              calendar: Calendar = .current) -> [DetectedSubscription] {
        let decisions = Dictionary(((try? context.fetch(FetchDescriptor<SubscriptionDecision>())) ?? []).map { ($0.key, $0.status) },
                                   uniquingKeysWith: { a, _ in a })
        let rows = (try? context.fetch(FetchDescriptor<BankTransaction>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<TransactionCategory>())) ?? []
        let charges = SubscriptionDetector.charges(entries: engine.cashFlowEntries(), records: engine.transactions, bankRows: rows)
        return SubscriptionDetector.detect(charges: charges, decisions: decisions,
                                           subscriptionCategoryIDs: subscriptionCategoryIDs(categories), now: now, calendar: calendar)
    }

    static func subscriptionCategoryIDs(_ categories: [TransactionCategory]) -> Set<UUID> {
        let names = Set((["Subscriptions"] + (BankCategorizer.categoryAliases["Subscriptions"] ?? [])).map(BankHash.normalizedName))
        return Set(categories.filter { $0.kind == .expense && names.contains(BankHash.normalizedName($0.name)) }.map(\.id))
    }

    /// Thresholds to announce now; marks each budget so a threshold is announced once per month.
    static func takeBudgetAlerts(budgets: [Budget], statuses: [BudgetStatus], categories: [TransactionCategory],
                                 now: Date = .now, calendar: Calendar = .current) -> [BudgetAlert] {
        let month = BudgetMath.monthKey(now, calendar: calendar)
        let byID = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var alerts: [BudgetAlert] = []
        for budget in budgets {
            guard let status = byID[budget.id],
                  let level = BudgetMath.alertLevel(for: status, alertedMonth: budget.alertedMonth,
                                                    alertedLevel: budget.alertedLevel, monthKey: month) else { continue }
            budget.alertedMonth = month
            budget.alertedLevel = level
            let name = budget.categoryID.flatMap { id in categories.first { $0.id == id }?.name } ?? "Monthly spending"
            let body = level >= 100
                ? "You've reached this month's budget."
                : "You've used \(MoneyFormat.percent(status.fraction, fractionDigits: 0)) of this month's budget."
            alerts.append(BudgetAlert(budgetID: budget.id, level: level, title: "Budget: \(name)", body: body))
        }
        return alerts
    }

    /// When to remind about a confirmed subscription: 10:00 the day before its next charge.
    static func reminderDate(for subscription: DetectedSubscription, now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard subscription.status == .confirmed, !subscription.isMissed,
              let dayBefore = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: subscription.nextDate)),
              let at = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: dayBefore),
              at > now, at.timeIntervalSince(now) < 35 * 86_400 else { return nil }
        return at
    }

    /// 10:00 on the first day of next month: when last month's report is ready.
    static func reportDate(now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard let thisMonth = calendar.dateInterval(of: .month, for: now) else { return nil }
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: thisMonth.end)
    }

    struct ConsentReminder: Equatable {
        let id: String
        let title: String
        let body: String
        let at: Date
    }

    /// Bank consent reminders: 10:00 seven days and one day before access ends, for each active
    /// connection. Past times are skipped; the in-app banner covers the rest.
    static func consentReminders(_ connections: [BankConnection], now: Date = .now,
                                 calendar: Calendar = .current) -> [ConsentReminder] {
        connections.filter { $0.status == .active }.flatMap { connection -> [ConsentReminder] in
            guard let until = connection.validUntil, until > now else { return [] }
            return [7, 1].compactMap { days in
                guard let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: until)),
                      let at = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day),
                      at > now, at < until else { return nil }
                let body = days == 1
                    ? "\(connection.title) access ends tomorrow. Reconnect in WealthOS to keep syncing."
                    : "\(connection.title) access ends in \(days) days. Reconnect in WealthOS to keep syncing."
                return ConsentReminder(id: "consent.\(connection.id.uuidString).\(days)",
                                       title: "Bank access expires soon", body: body, at: at)
            }
        }
    }

    static func consentRemindersEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: SettingsKey.bankConsentReminders) as? Bool ?? true
    }

    /// Runs after data changes (see `DataMaintenance.refreshSnapshot`), on the real store only.
    static func run(context: ModelContext, engine: FinanceEngine, now: Date = .now, defaults: UserDefaults = .standard) {
        #if DEBUG
        // Visual-check launches (`-UIDemoTab`) never schedule notifications or ask for permission.
        if ProcessInfo.processInfo.arguments.contains("-UIDemoTab") { return }
        #endif
        let budgetAlerts = defaults.bool(forKey: SettingsKey.budgetAlerts)
        let reminders = defaults.bool(forKey: SettingsKey.subscriptionReminders)
        let report = defaults.bool(forKey: SettingsKey.monthlyReportNotification)
        let consent = consentRemindersEnabled(defaults)
        let consentPosts = consent
            ? consentReminders((try? context.fetch(FetchDescriptor<BankConnection>())) ?? [], now: now)
            : []
        guard budgetAlerts || reminders || report || consent else { return }
        var posts: [(id: String, title: String, body: String, at: Date?)] = []

        if budgetAlerts, let budgets = try? context.fetch(FetchDescriptor<Budget>()), !budgets.isEmpty {
            let categories = (try? context.fetch(FetchDescriptor<TransactionCategory>())) ?? []
            let statuses = budgetStatuses(budgets, entries: engine.cashFlowEntries(), now: now)
            let alerts = takeBudgetAlerts(budgets: budgets, statuses: statuses, categories: categories, now: now)
            if !alerts.isEmpty, Persistence.flush(context) {
                posts += alerts.map { ("budget.\($0.budgetID.uuidString).\($0.level)", $0.title, $0.body, nil) }
            }
        }
        let schedule: [(id: String, title: String, body: String, at: Date?)] = reminders
            ? subscriptions(context: context, engine: engine, now: now).compactMap { subscription in
                reminderDate(for: subscription, now: now).map {
                    ("sub.\(subscription.key.hashValue)", subscription.title, "Renews tomorrow.", $0)
                }
            }
            : []

        var reportPost: (id: String, title: String, body: String, at: Date?)?
        if report, let at = reportDate(now: now) {
            let month = Calendar.current.date(byAdding: .month, value: -1, to: at) ?? now
            reportPost = ("report.\(BudgetMath.monthKey(month))", "Monthly report",
                          "Your \(month.formatted(.dateTime.month(.wide))) report is ready.", at)
        }

        let notifier = self.notifier
        Task {
            // Re-planned on every run: a reconnect or disconnect moves or drops the reminders.
            if consent {
                // A bank is connected but iOS never asked: ask once, so the reminder can arrive.
                if !consentPosts.isEmpty, await notifier.isAuthorizationUndetermined() { _ = await notifier.authorize() }
                await notifier.removePending(prefix: "consent.")
                for item in consentPosts { await notifier.post(id: item.id, title: item.title, body: item.body, at: item.at) }
            }
            if reminders { await notifier.removePending(prefix: "sub.") }
            if let reportPost {
                await notifier.removePending(prefix: "report.")
                await notifier.post(id: reportPost.id, title: reportPost.title, body: reportPost.body, at: reportPost.at)
            }
            for item in posts + schedule { await notifier.post(id: item.id, title: item.title, body: item.body, at: item.at) }
        }
    }
}
