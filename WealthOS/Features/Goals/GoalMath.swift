import Foundation

/// Pure goal calculations. Allocations are earmarks of existing assets and are
/// never added to net worth.
nonisolated enum GoalMath {
    static func progress(allocated: Decimal, target: Decimal) -> Double {
        guard target > 0 else { return 0 }
        return min(1, max(0, (allocated / target).doubleValue))
    }

    static func remaining(allocated: Decimal, target: Decimal) -> Decimal {
        max(0, target - allocated)
    }

    /// Whole months of contributions needed (rounded up). nil if it can never complete.
    static func monthsToComplete(allocated: Decimal, target: Decimal, monthly: Decimal) -> Int? {
        let left = remaining(allocated: allocated, target: target)
        if left == 0 { return 0 }
        guard monthly > 0 else { return nil }
        let months = Money.round(left / monthly, scale: 0, mode: .up)
        return NSDecimalNumber(decimal: months).intValue
    }

    static func estimatedCompletion(allocated: Decimal, target: Decimal, monthly: Decimal,
                                    from date: Date = .now, calendar: Calendar = .current) -> Date? {
        guard let months = monthsToComplete(allocated: allocated, target: target, monthly: monthly) else { return nil }
        return calendar.date(byAdding: .month, value: months, to: date)
    }

    /// Monthly amount required to reach the target by `targetDate`.
    static func requiredMonthly(allocated: Decimal, target: Decimal, targetDate: Date,
                                from date: Date = .now, calendar: Calendar = .current) -> Decimal? {
        let left = remaining(allocated: allocated, target: target)
        if left == 0 { return 0 }
        let months = calendar.dateComponents([.month], from: date, to: targetDate).month ?? 0
        guard months > 0 else { return nil }
        return Money.round(left / Decimal(months), scale: 2, mode: .up)
    }

    /// Assets that can back goal earmarks: cash, bank, savings and investments (not debts or illiquid assets).
    static func allocatableAssets(_ summary: NetWorthSummary) -> Decimal {
        max(0, summary.liquid + summary.investments)
    }

    /// The Goals overview card, derived in one place from the live engine summary and goals.
    struct Overview: Equatable {
        var allocated: Decimal
        var target: Decimal
        /// Cash + investments that can back earmarks.
        var available: Decimal
        var unallocated: Decimal { available - allocated }
        var isOverAllocated: Bool { unallocated < 0 }
    }

    static func overview(summary: NetWorthSummary, goals: [(allocated: Decimal, target: Decimal)]) -> Overview {
        Overview(allocated: goals.reduce(0) { $0 + $1.allocated },
                 target: goals.reduce(0) { $0 + $1.target },
                 available: allocatableAssets(summary))
    }
}
