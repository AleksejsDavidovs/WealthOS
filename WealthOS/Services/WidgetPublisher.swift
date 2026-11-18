import Foundation
import SwiftData
import WidgetKit

/// Writes the figures the Home/Lock Screen widgets show into the shared App Group container
/// and asks WidgetKit to reload. Real store only (see `DataMaintenance.refreshSnapshot`).
@MainActor
enum WidgetPublisher {
    static func snapshot(engine: FinanceEngine, budgets: [Budget], connections: [BankConnection], currency: String,
                         hidesAmounts: Bool, categories: [TransactionCategory] = [], history: [NetWorthSnapshot] = [],
                         now: Date = .now, calendar: Calendar = .current) -> WidgetSnapshot {
        let entries = engine.cashFlowEntries()
        func spent(_ component: Calendar.Component) -> Decimal {
            guard let interval = calendar.dateInterval(of: component, for: now) else { return 0 }
            return Money.round(BudgetMath.spent(categoryID: nil, in: interval, entries: entries))
        }
        let overview = BudgetMath.overview(PlanningMonitor.budgetStatuses(budgets, entries: entries, now: now, calendar: calendar))
        let month = calendar.dateInterval(of: .month, for: now)
        let summary = engine.summary
        return WidgetSnapshot(currencyCode: currency,
                              netWorth: Money.round(engine.summary.netWorth),
                              isComplete: engine.summary.isComplete,
                              spentToday: spent(.day),
                              spentThisMonth: spent(.month),
                              budgetLimit: overview.map { Money.round($0.limit) },
                              budgetSpent: overview.map { Money.round($0.spent) },
                              bankAccessUntil: bankAccessUntil(connections),
                              hidesAmounts: hidesAmounts,
                              updatedAt: now,
                              liquid: Money.round(summary.liquid + summary.otherAssets),
                              investments: Money.round(summary.investments),
                              liabilities: Money.round(summary.liabilities),
                              incomeThisMonth: month.map { interval in
                                  Money.round(entries.reduce(Decimal(0)) {
                                      $0 + ($1.kind == .income && $1.date >= interval.start && $1.date < interval.end ? $1.amount : 0)
                                  })
                              },
                              netWorthMonthStart: month.flatMap { monthStart(history, before: $0.start, currency: currency) },
                              topCategories: month.map { topCategories(entries, in: $0, categories: categories) })
    }

    /// Net worth at the end of last month: the latest snapshot in this currency before the 1st.
    static func monthStart(_ history: [NetWorthSnapshot], before start: Date, currency: String) -> Decimal? {
        history.filter { $0.date < start && $0.currencyCode == currency }.max { $0.date < $1.date }.map { Money.round($0.netWorth) }
    }

    static func topCategories(_ entries: [CashFlowEntry], in interval: DateInterval, categories: [TransactionCategory],
                              limit: Int = 3) -> [WidgetSnapshot.CategoryAmount] {
        var totals: [UUID?: Decimal] = [:]
        for entry in entries where entry.kind == .expense && entry.date >= interval.start && entry.date < interval.end {
            totals[entry.categoryID, default: 0] += entry.amount
        }
        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return totals.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : (names[$0.key ?? UUID()] ?? "") < (names[$1.key ?? UUID()] ?? "") }
            .prefix(limit)
            .map { .init(name: $0.key.flatMap { names[$0] } ?? "Uncategorized", amount: Money.round($0.value)) }
    }

    /// "Hide amounts until tapped" — on unless turned off.
    static func hidesAmounts(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: SettingsKey.widgetHidesAmounts) as? Bool ?? true
    }

    /// Earliest end of an active consent; an already-passed date means expired.
    static func bankAccessUntil(_ connections: [BankConnection]) -> Date? {
        connections.filter { $0.status == .active }.compactMap(\.validUntil).min()
    }

    static func publish(context: ModelContext, engine: FinanceEngine, currency: String, hasData: Bool,
                        defaults: UserDefaults = .standard, now: Date = .now) {
        guard hasData else {
            if WidgetSnapshot.load() != nil {
                WidgetSnapshot.remove()
                WidgetCenter.shared.reloadAllTimelines()
            }
            return
        }
        let next = snapshot(engine: engine,
                            budgets: (try? context.fetch(FetchDescriptor<Budget>())) ?? [],
                            connections: (try? context.fetch(FetchDescriptor<BankConnection>())) ?? [],
                            currency: currency,
                            hidesAmounts: hidesAmounts(defaults),
                            categories: (try? context.fetch(FetchDescriptor<TransactionCategory>())) ?? [],
                            history: (try? context.fetch(FetchDescriptor<NetWorthSnapshot>())) ?? [],
                            now: now)
        // Skip identical figures from the same day ("today" values depend on the date).
        if let current = WidgetSnapshot.load(), current.hasSameValues(as: next),
           Calendar.current.isDate(current.updatedAt, inSameDayAs: now) { return }
        guard next.save() else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
