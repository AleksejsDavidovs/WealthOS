import Foundation
import SwiftData

// MARK: - Budgets

/// One budget's state for a month. Spending uses the same entries as Analytics: recorded
/// expenses only (no transfers, balance adjustments, scheduled or unrecorded bank rows).
nonisolated struct BudgetStatus: Identifiable, Equatable, Sendable {
    enum Level: Int, Comparable, Sendable {
        case ok = 0, warning = 80, over = 100
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    let id: UUID
    let categoryID: UUID?
    /// The budget's own monthly amount.
    let amount: Decimal
    /// Last month's unspent amount carried over (rollover budgets only, never negative).
    let carry: Decimal
    let spent: Decimal
    /// Projected month-end spending at the current pace; nil for months that aren't in progress.
    let projected: Decimal?

    var limit: Decimal { amount + carry }
    var remaining: Decimal { limit - spent }
    var fraction: Decimal { limit > 0 ? spent / limit : 0 }
    var level: Level { fraction >= 1 ? .over : (fraction >= Decimal(string: "0.8")! ? .warning : .ok) }
}

nonisolated enum BudgetMath {
    struct Definition: Equatable, Sendable {
        let id: UUID
        let categoryID: UUID?
        let amount: Decimal
        let rollover: Bool
    }

    /// Expenses of the category (`nil` = all expenses) in the interval.
    static func spent(categoryID: UUID?, in interval: DateInterval, entries: [CashFlowEntry]) -> Decimal {
        entries.reduce(Decimal(0)) { sum, entry in
            guard entry.kind == .expense, entry.date >= interval.start, entry.date < interval.end,
                  categoryID == nil || entry.categoryID == categoryID else { return sum }
            return sum + entry.amount
        }
    }

    static func status(of budget: Definition, month: Date, entries: [CashFlowEntry], now: Date = .now,
                       calendar: Calendar = .current) -> BudgetStatus {
        let interval = calendar.dateInterval(of: .month, for: month) ?? DateInterval(start: month, duration: 86_400 * 30)
        let spent = spent(categoryID: budget.categoryID, in: interval, entries: entries)
        var carry: Decimal = 0
        if budget.rollover, let previousStart = calendar.date(byAdding: .month, value: -1, to: interval.start),
           let previous = calendar.dateInterval(of: .month, for: previousStart) {
            carry = max(0, budget.amount - Self.spent(categoryID: budget.categoryID, in: previous, entries: entries))
        }
        var projected: Decimal?
        if now >= interval.start, now < interval.end {
            let today = calendar.startOfDay(for: now)
            let elapsed = (calendar.dateComponents([.day], from: interval.start, to: today).day ?? 0) + 1
            let days = calendar.range(of: .day, in: .month, for: interval.start)?.count ?? 30
            projected = Money.round(spent / Decimal(max(1, elapsed)) * Decimal(days))
        }
        return BudgetStatus(id: budget.id, categoryID: budget.categoryID, amount: budget.amount, carry: carry,
                            spent: spent, projected: projected)
    }

    /// The month as a whole: an "all expenses" budget if there is one, otherwise the sum of the
    /// category budgets. nil without budgets.
    static func overview(_ statuses: [BudgetStatus]) -> (limit: Decimal, spent: Decimal)? {
        if let total = statuses.first(where: { $0.categoryID == nil }) { return (total.limit, total.spent) }
        guard !statuses.isEmpty else { return nil }
        return (statuses.reduce(0) { $0 + $1.limit }, statuses.reduce(0) { $0 + $1.spent })
    }

    static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// The threshold to announce now, if any: each of 80 % and 100 % at most once per month.
    /// Jumping straight past 100 % announces only 100 %.
    static func alertLevel(for status: BudgetStatus, alertedMonth: String, alertedLevel: Int, monthKey: String) -> Int? {
        let reached = status.level.rawValue
        let already = alertedMonth == monthKey ? alertedLevel : 0
        return reached > already && reached > 0 ? reached : nil
    }
}

// MARK: - Subscriptions

/// One recorded expense with the payee it belongs to.
nonisolated struct SubscriptionCharge: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    /// Base currency, positive.
    let amount: Decimal
    let categoryID: UUID?
    let key: String
    let title: String
}

nonisolated enum SubscriptionCadence: String, Sendable, CaseIterable {
    case weekly, monthly, yearly

    var title: String {
        switch self {
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }

    /// Accepted gap between charges, in days.
    var band: ClosedRange<Int> {
        switch self {
        case .weekly: 5...9
        case .monthly: 25...35
        case .yearly: 350...380
        }
    }

    var nominalDays: Int {
        switch self {
        case .weekly: 7
        case .monthly: 30
        case .yearly: 365
        }
    }

    /// Days after the expected date before a charge counts as missed.
    var grace: Int {
        switch self {
        case .weekly: 2
        case .monthly: 4
        case .yearly: 10
        }
    }

    func next(after date: Date, calendar: Calendar) -> Date {
        switch self {
        case .weekly: calendar.date(byAdding: .day, value: 7, to: date) ?? date
        case .monthly: calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .yearly: calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
    }

    /// Monthly equivalent of one charge.
    func monthly(_ amount: Decimal) -> Decimal {
        switch self {
        case .weekly: Money.round(amount * 52 / 12)
        case .monthly: amount
        case .yearly: Money.round(amount / 12)
        }
    }

    static func matching(days: Int) -> SubscriptionCadence? { allCases.first { $0.band.contains(days) } }
}

nonisolated struct DetectedSubscription: Identifiable, Equatable, Sendable {
    enum Status: Sendable { case suggested, confirmed }

    var id: String { key }
    let key: String
    let title: String
    let categoryID: UUID?
    let cadence: SubscriptionCadence
    /// The latest charge.
    let amount: Decimal
    let lastDate: Date
    let nextDate: Date
    let status: Status
    /// Previous and latest amount when the latest charge is higher.
    let priceIncrease: (from: Decimal, to: Decimal)?
    /// The expected charge hasn't arrived (past its date plus a grace period).
    let isMissed: Bool
    let charges: [SubscriptionCharge]

    var monthlyCost: Decimal { cadence.monthly(amount) }
    var yearlyCost: Decimal { monthlyCost * 12 }

    static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.amount == b.amount && a.lastDate == b.lastDate && a.status == b.status
            && a.isMissed == b.isMissed && a.priceIncrease?.from == b.priceIncrease?.from
            && a.priceIncrease?.to == b.priceIncrease?.to && a.charges == b.charges
    }
}

nonisolated enum SubscriptionDetector {
    /// Amounts within this fraction of the usual amount count as "the same price".
    static let tolerance = Decimal(string: "0.15")!
    /// A later charge up to this much higher is read as a price increase, not a different payment.
    static let maxIncrease = Decimal(string: "0.5")!

    static func detect(charges: [SubscriptionCharge], decisions: [String: SubscriptionDecisionStatus],
                       subscriptionCategoryIDs: Set<UUID> = [], now: Date = .now,
                       calendar: Calendar = .current) -> [DetectedSubscription] {
        let groups = Dictionary(grouping: charges, by: \.key)
        var result: [DetectedSubscription] = []
        for (key, group) in groups {
            let decision = decisions[key]
            if decision == .dismissed { continue }
            let confirmed = decision == .confirmed
            let sorted = group.sorted { $0.date < $1.date }
            guard let last = sorted.last else { continue }

            let gaps = zip(sorted, sorted.dropFirst()).map {
                calendar.dateComponents([.day], from: calendar.startOfDay(for: $0.date),
                                        to: calendar.startOfDay(for: $1.date)).day ?? 0
            }
            let medianGap = gaps.isEmpty ? nil : gaps.sorted()[gaps.count / 2]
            var cadence = medianGap.flatMap(SubscriptionCadence.matching(days:))

            let amounts = sorted.map(\.amount)
            let earlier = Array(amounts.dropLast())
            let baseline = earlier.isEmpty ? last.amount : earlier.sorted()[earlier.count / 2]
            let earlierStable = earlier.allSatisfy { abs($0 - baseline) <= baseline * tolerance }
            let lastPlausible = last.amount >= baseline * (1 - tolerance) && last.amount <= baseline * (1 + maxIncrease)

            let hinted = sorted.contains { $0.categoryID.map(subscriptionCategoryIDs.contains) ?? false } || key.hasPrefix("rule:")
            let needed = hinted ? 2 : 3
            var regular = false
            if let cadence {
                let onCadence = gaps.filter { cadence.band.contains($0) }.count
                regular = onCadence >= gaps.count - (gaps.count >= 3 ? 1 : 0)
            }
            let detected = cadence != nil && regular && earlierStable && lastPlausible && sorted.count >= needed

            if !detected && !confirmed { continue }
            if cadence == nil {
                // Confirmed by the user without a recognisable rhythm yet: assume monthly.
                cadence = medianGap.map { gap in SubscriptionCadence.allCases.min { abs($0.nominalDays - gap) < abs($1.nominalDays - gap) }! }
                    ?? .monthly
            }
            guard let cadence else { continue }

            let sinceLast = calendar.dateComponents([.day], from: calendar.startOfDay(for: last.date),
                                                    to: calendar.startOfDay(for: now)).day ?? 0
            // A suggestion that stopped long ago was probably cancelled.
            if !confirmed && sinceLast > cadence.nominalDays * 3 / 2 + 7 { continue }

            let next = cadence.next(after: last.date, calendar: calendar)
            let missedAfter = calendar.date(byAdding: .day, value: cadence.grace, to: next) ?? next
            // Compared with the usual price, so a rise stays visible until it becomes the usual price.
            var increase: (Decimal, Decimal)?
            if !earlier.isEmpty, last.amount > baseline * Decimal(string: "1.02")! { increase = (baseline, last.amount) }

            result.append(DetectedSubscription(
                key: key, title: last.title, categoryID: last.categoryID, cadence: cadence, amount: last.amount,
                lastDate: last.date, nextDate: next, status: confirmed ? .confirmed : .suggested,
                priceIncrease: increase, isMissed: now > missedAfter, charges: sorted))
        }
        return result.sorted { a, b in
            if a.status != b.status { return a.status == .confirmed }
            if a.monthlyCost != b.monthlyCost { return a.monthlyCost > b.monthlyCost }
            return a.key < b.key
        }
    }

    struct Summary: Equatable, Sendable {
        var confirmedCount = 0
        var suggestedCount = 0
        var monthly: Decimal = 0
        var yearly: Decimal { monthly * 12 }
    }

    /// Totals count confirmed subscriptions only; suggestions are counted separately.
    static func summary(_ subscriptions: [DetectedSubscription]) -> Summary {
        var summary = Summary()
        for subscription in subscriptions {
            if subscription.status == .confirmed {
                summary.confirmedCount += 1
                summary.monthly += subscription.monthlyCost
            } else {
                summary.suggestedCount += 1
            }
        }
        return summary
    }

    // MARK: Payee keys

    /// "merchant:boozie riga" → "Boozie Riga".
    static func title(fromKey key: String) -> String {
        guard let colon = key.firstIndex(of: ":") else { return key }
        return key[key.index(after: colon)...].split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

extension SubscriptionDetector {
    /// Expense records with their payee: the bank counterparty or card merchant for imported
    /// rows, the recurring rule or the note for manual ones. Records without any payee are left out.
    static func charges(entries: [CashFlowEntry], records: [TransactionRecord], bankRows: [BankTransaction]) -> [SubscriptionCharge] {
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let bankByRecord = Dictionary(bankRows.compactMap { row in row.ledgerRecordID.map { ($0, row) } },
                                      uniquingKeysWith: { a, _ in a })
        return entries.compactMap { entry in
            guard entry.kind == .expense, let record = recordsByID[entry.id],
                  let payee = payee(for: record, bankRow: bankByRecord[record.id]) else { return nil }
            return SubscriptionCharge(id: entry.id, date: entry.date, amount: entry.amount, categoryID: entry.categoryID,
                                      key: payee.key, title: payee.title)
        }
    }

    static func payee(for record: TransactionRecord, bankRow: BankTransaction?) -> (key: String, title: String)? {
        let note = record.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let row = bankRow, let key = BankReconciler.ruleKeys(for: row).first {
            let name = row.counterpartyName.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = !name.isEmpty ? name : (key.hasPrefix("merchant:") ? Self.title(fromKey: key) : (note.isEmpty ? "Bank payment" : note))
            return (key, title)
        }
        if let rule = record.recurringRuleID { return ("rule:" + rule.uuidString, note.isEmpty ? "Recurring payment" : note) }
        let normalized = BankHash.normalizedName(note)
        guard !normalized.isEmpty else { return nil }
        return ("note:" + normalized, note)
    }
}
