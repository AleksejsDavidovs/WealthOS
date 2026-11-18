import Foundation

/// The few figures the widgets show, written by the app into the shared App Group container
/// after every data refresh. The widget extension never opens the database itself.
/// Compiled into both the app and the widget extension.
nonisolated struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let appGroup = "group.lv.davidovs.wealthos"
    static let fileName = "widget-snapshot.json"

    var currencyCode: String
    var netWorth: Decimal
    /// False when some values couldn't be confirmed (missing rate, unverified source).
    var isComplete: Bool
    var spentToday: Decimal
    var spentThisMonth: Decimal
    /// This month's budget overview; nil without budgets.
    var budgetLimit: Decimal?
    var budgetSpent: Decimal?
    /// Earliest end of an active bank consent (may already be in the past = expired).
    var bankAccessUntil: Date?
    /// User setting: show "••••" until the widget is tapped.
    var hidesAmounts: Bool
    var updatedAt: Date

    // Extra figures for the large widget. Optional so older snapshot files still decode.
    var liquid: Decimal?
    var investments: Decimal?
    var liabilities: Decimal?
    var incomeThisMonth: Decimal?
    /// Net worth at the end of last month (latest snapshot before the 1st); nil without history.
    var netWorthMonthStart: Decimal?
    /// This month's biggest expense categories, largest first (at most 3).
    var topCategories: [CategoryAmount]?

    nonisolated struct CategoryAmount: Codable, Equatable, Sendable {
        var name: String
        var amount: Decimal
    }

    // MARK: Values as of a timeline date
    // "Today" and "this month" figures are only valid in the day / month they were taken.

    func spentToday(asOf date: Date, calendar: Calendar = .current) -> Decimal {
        calendar.isDate(updatedAt, inSameDayAs: date) ? spentToday : 0
    }

    func spentThisMonth(asOf date: Date, calendar: Calendar = .current) -> Decimal {
        calendar.isDate(updatedAt, equalTo: date, toGranularity: .month) ? spentThisMonth : 0
    }

    func budget(asOf date: Date, calendar: Calendar = .current) -> (limit: Decimal, spent: Decimal)? {
        guard let budgetLimit, budgetLimit > 0 else { return nil }
        let sameMonth = calendar.isDate(updatedAt, equalTo: date, toGranularity: .month)
        return (budgetLimit, sameMonth ? (budgetSpent ?? 0) : 0)
    }

    func incomeThisMonth(asOf date: Date, calendar: Calendar = .current) -> Decimal {
        calendar.isDate(updatedAt, equalTo: date, toGranularity: .month) ? (incomeThisMonth ?? 0) : 0
    }

    func topCategories(asOf date: Date, calendar: Calendar = .current) -> [CategoryAmount] {
        calendar.isDate(updatedAt, equalTo: date, toGranularity: .month) ? (topCategories ?? []) : []
    }

    /// Change since the end of last month; nil without history or once the month has passed.
    func monthChange(asOf date: Date, calendar: Calendar = .current) -> Decimal? {
        guard calendar.isDate(updatedAt, equalTo: date, toGranularity: .month), let netWorthMonthStart else { return nil }
        return netWorth - netWorthMonthStart
    }

    /// Whole days until bank access ends (0 = ends today, negative = expired); nil without a bank.
    func bankAccessDaysLeft(asOf date: Date, calendar: Calendar = .current) -> Int? {
        guard let bankAccessUntil else { return nil }
        if bankAccessUntil <= date { return -1 }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                       to: calendar.startOfDay(for: bankAccessUntil)).day
    }

    // MARK: Tap to reveal
    // A tap on a widget (an App Intent in the extension) shows amounts for a short while.

    static let revealDuration: TimeInterval = 30
    private static let revealKey = "widgetRevealUntil"

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func revealUntil(_ defaults: UserDefaults? = sharedDefaults) -> Date? {
        defaults?.object(forKey: revealKey) as? Date
    }

    static func setRevealUntil(_ date: Date?, _ defaults: UserDefaults? = sharedDefaults) {
        if let date { defaults?.set(date, forKey: revealKey) } else { defaults?.removeObject(forKey: revealKey) }
    }

    /// Amounts are visible at `date`: hiding is off, or a tap revealed them until later than `date`.
    func showsAmounts(at date: Date, revealUntil: Date?) -> Bool {
        !hidesAmounts || (revealUntil.map { date < $0 } ?? false)
    }

    // MARK: Storage

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load(from url: URL? = fileURL) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    @discardableResult
    func save(to url: URL? = Self.fileURL) -> Bool {
        guard let url, let data = try? JSONEncoder().encode(self) else { return false }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    static func remove(at url: URL? = fileURL) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Same figures (ignoring the timestamp).
    func hasSameValues(as other: WidgetSnapshot) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }
}
