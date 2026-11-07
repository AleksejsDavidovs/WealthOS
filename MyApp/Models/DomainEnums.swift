import Foundation

nonisolated enum AccountGroup: String, CaseIterable, Codable, Sendable {
    case liquid, investments, otherAssets, liabilities

    var title: String {
        switch self {
        case .liquid: "Cash & Bank"
        case .investments: "Investments"
        case .otherAssets: "Other Assets"
        case .liabilities: "Liabilities"
        }
    }
}

nonisolated enum AccountKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case cash, checking, savings, investment, crypto, otherAsset, liability

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cash: "Cash"
        case .checking: "Bank Account"
        case .savings: "Savings"
        case .investment: "Investment Account"
        case .crypto: "Crypto"
        case .otherAsset: "Other Asset"
        case .liability: "Liability / Debt"
        }
    }

    var symbol: String {
        switch self {
        case .cash: "banknote"
        case .checking: "building.columns"
        case .savings: "dollarsign.bank.building"
        case .investment: "chart.line.uptrend.xyaxis"
        case .crypto: "bitcoinsign.circle"
        case .otherAsset: "house"
        case .liability: "creditcard"
        }
    }

    var group: AccountGroup {
        switch self {
        case .cash, .checking, .savings: .liquid
        case .investment, .crypto: .investments
        case .otherAsset: .otherAssets
        case .liability: .liabilities
        }
    }

    var isLiability: Bool { self == .liability }
}

nonisolated enum TransactionKind: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Money earned. Increases the account balance and counts as income.
    case income
    /// Consumption spending. Decreases the account balance and counts as an expense.
    case expense
    /// Movement between two own accounts. Never counted as income or expense.
    case transfer
    /// Balance correction (signed). Never counted as income or expense.
    case adjustment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .income: "Income"
        case .expense: "Expense"
        case .transfer: "Transfer"
        case .adjustment: "Balance Adjustment"
        }
    }

    var symbol: String {
        switch self {
        case .income: "arrow.down.circle.fill"
        case .expense: "arrow.up.circle.fill"
        case .transfer: "arrow.left.arrow.right.circle.fill"
        case .adjustment: "slider.horizontal.3"
        }
    }

    var categoryKind: CategoryKind? {
        switch self {
        case .income: .income
        case .expense: .expense
        case .transfer, .adjustment: nil
        }
    }
}

nonisolated enum CategoryKind: String, CaseIterable, Codable, Sendable {
    case income, expense

    var title: String { self == .income ? "Income" : "Expense" }
}

nonisolated enum RecurrenceFrequency: String, CaseIterable, Codable, Identifiable, Sendable {
    case weekly, biweekly, monthly, quarterly, yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly: "Weekly"
        case .biweekly: "Every 2 Weeks"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .yearly: "Yearly"
        }
    }

    /// Date of the n-th occurrence (0-based) counted from `start`.
    /// Computing from the start date (not the previous occurrence) prevents
    /// day-of-month drift, e.g. Jan 31 -> Feb 28 -> Mar 31.
    func occurrence(_ index: Int, from start: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .weekly: calendar.date(byAdding: .day, value: 7 * index, to: start)
        case .biweekly: calendar.date(byAdding: .day, value: 14 * index, to: start)
        case .monthly: calendar.date(byAdding: .month, value: index, to: start)
        case .quarterly: calendar.date(byAdding: .month, value: 3 * index, to: start)
        case .yearly: calendar.date(byAdding: .year, value: index, to: start)
        }
    }

    /// Approximate occurrences per month, used for monthly-equivalent summaries.
    var monthlyFactor: Decimal {
        switch self {
        case .weekly: Decimal(52) / 12
        case .biweekly: Decimal(26) / 12
        case .monthly: 1
        case .quarterly: Decimal(1) / 3
        case .yearly: Decimal(1) / 12
        }
    }
}

nonisolated enum AssetClass: String, CaseIterable, Codable, Identifiable, Sendable {
    case etf, stock, crypto, cash, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .etf: "ETFs"
        case .stock: "Stocks"
        case .crypto: "Crypto"
        case .cash: "Cash Investments"
        case .other: "Other"
        }
    }

    var singularTitle: String {
        switch self {
        case .etf: "ETF"
        case .stock: "Stock"
        case .crypto: "Cryptocurrency"
        case .cash: "Cash Investment"
        case .other: "Other Asset"
        }
    }

    var symbol: String {
        switch self {
        case .etf: "square.stack.3d.up.fill"
        case .stock: "chart.bar.fill"
        case .crypto: "bitcoinsign.circle.fill"
        case .cash: "eurosign.circle.fill"
        case .other: "cube.fill"
        }
    }

    var colorName: String {
        switch self {
        case .etf: "blue"
        case .stock: "purple"
        case .crypto: "orange"
        case .cash: "mint"
        case .other: "gray"
        }
    }
}

nonisolated enum TradeKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case buy, sell
    var id: String { rawValue }
    var title: String { self == .buy ? "Buy" : "Sell" }
}

nonisolated enum GoalType: String, CaseIterable, Codable, Identifiable, Sendable {
    case car, emergencyFund, travel, education, home, financialIndependence, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .car: "Car Purchase"
        case .emergencyFund: "Emergency Fund"
        case .travel: "Travel"
        case .education: "Education"
        case .home: "Home"
        case .financialIndependence: "Financial Independence"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .car: "car.fill"
        case .emergencyFund: "cross.case.fill"
        case .travel: "airplane"
        case .education: "graduationcap.fill"
        case .home: "house.fill"
        case .financialIndependence: "leaf.fill"
        case .custom: "star.fill"
        }
    }

    var defaultColor: String {
        switch self {
        case .car: "blue"
        case .emergencyFund: "red"
        case .travel: "teal"
        case .education: "indigo"
        case .home: "orange"
        case .financialIndependence: "green"
        case .custom: "purple"
        }
    }
}

nonisolated enum ScenarioKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case conservative, balanced, optimistic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conservative: "Conservative"
        case .balanced: "Balanced"
        case .optimistic: "Optimistic"
        }
    }

    var colorName: String {
        switch self {
        case .conservative: "orange"
        case .balanced: "blue"
        case .optimistic: "green"
        }
    }
}

nonisolated enum SnapshotSource: String, Codable, Sendable {
    /// Recorded by the app from the actual balances on that day.
    case automatic
    /// Entered by the user (e.g. historical values from statements).
    case manual
}
