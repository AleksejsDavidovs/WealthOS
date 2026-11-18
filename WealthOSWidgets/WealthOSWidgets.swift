import AppIntents
import SwiftUI
import WidgetKit

@main
struct WealthOSWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NetWorthWidget()
        SpendingWidget()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// nil = nothing published yet (app not opened / no data). Its `hidesAmounts` is already
    /// resolved for this entry's date (false while a tap has revealed the amounts).
    let snapshot: WidgetSnapshot?
    /// "Hide until tapped" is on: a tap toggles the amounts instead of opening the app.
    var tapReveals = false

    init(date: Date, snapshot: WidgetSnapshot?, revealUntil: Date? = nil) {
        self.date = date
        tapReveals = snapshot?.hidesAmounts ?? false
        if var resolved = snapshot {
            resolved.hidesAmounts = !resolved.showsAmounts(at: date, revealUntil: revealUntil)
            self.snapshot = resolved
        } else {
            self.snapshot = nil
        }
    }
}

/// Tap on a Home Screen widget: show the amounts for 30 seconds (tap again to hide), in place.
struct RevealAmountsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Amounts"
    static let description = IntentDescription("Shows the amounts in WealthOS widgets for 30 seconds.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        let now = Date.now
        if let until = WidgetSnapshot.revealUntil(), until > now {
            WidgetSnapshot.setRevealUntil(nil)
        } else {
            WidgetSnapshot.setRevealUntil(now.addingTimeInterval(WidgetSnapshot.revealDuration))
        }
        return .result()
    }
}

struct SnapshotProvider: TimelineProvider {
    static let sample = WidgetSnapshot(currencyCode: "EUR", netWorth: 48_250, isComplete: true, spentToday: 23,
                                       spentThisMonth: 812, budgetLimit: 1_200, budgetSpent: 812,
                                       bankAccessUntil: nil, hidesAmounts: false, updatedAt: .now,
                                       liquid: 6_400, investments: 43_100, liabilities: 1_250, incomeThisMonth: 2_900,
                                       netWorthMonthStart: 47_480,
                                       topCategories: [.init(name: "Food", amount: 342), .init(name: "Transport", amount: 128),
                                                       .init(name: "Subscriptions", amount: 47)])

    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, snapshot: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let stored = WidgetSnapshot.load()
        completion(SnapshotEntry(date: .now, snapshot: stored ?? (context.isPreview ? Self.sample : nil)))
    }

    /// The app reloads timelines whenever its data changes. The extra entry at midnight resets
    /// "today" (and, on the 1st, "this month") even if the app isn't opened.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        let reveal = WidgetSnapshot.revealUntil()
        let now = Date.now
        var dates = [now]
        // Hide again when the reveal ends.
        if let reveal, reveal > now { dates.append(reveal) }
        if let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) {
            dates.append(midnight)
        }
        let entries = dates.sorted().map { SnapshotEntry(date: $0, snapshot: snapshot, revealUntil: reveal) }
        completion(Timeline(entries: entries, policy: .never))
    }
}

// MARK: - Widgets

struct NetWorthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NetWorthWidget", provider: SnapshotProvider()) { entry in
            NetWorthWidgetView(entry: entry)
        }
        .configurationDisplayName("Net Worth")
        .description("Your net worth, this month's spending and budget.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

struct SpendingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SpendingWidget", provider: SnapshotProvider()) { entry in
            SpendingWidgetView(entry: entry)
        }
        .configurationDisplayName("Spending & Budget")
        .description("Spent today and this month, and what's left of your monthly budget.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Formatting

enum WidgetFormat {
    static func money(_ value: Decimal, _ snapshot: WidgetSnapshot) -> String {
        guard !snapshot.hidesAmounts else { return "••••" }
        return value.formatted(.currency(code: snapshot.currencyCode).precision(.fractionLength(0)))
    }

    static func signedMoney(_ value: Decimal, _ snapshot: WidgetSnapshot) -> String {
        guard !snapshot.hidesAmounts else { return "••••" }
        return value.formatted(.currency(code: snapshot.currencyCode).precision(.fractionLength(0))
            .sign(strategy: .always(showZero: false)))
    }

    static func budgetColor(_ fraction: Double) -> Color {
        fraction >= 1 ? .red : (fraction >= 0.8 ? .orange : .green)
    }

    static func bankText(_ days: Int) -> String {
        switch days {
        case ..<0: "Bank access expired"
        case 0: "Bank access ends today"
        case 1: "Bank access: 1 day left"
        default: "Bank access: \(days) days left"
        }
    }
}

/// Home Screen widgets with "hide until tapped": the whole widget is a button that reveals
/// the amounts in place; otherwise a tap opens the app as usual.
private struct TapToReveal<Content: View>: View {
    let entry: SnapshotEntry
    @ViewBuilder let content: Content

    var body: some View {
        if entry.tapReveals {
            Button(intent: RevealAmountsIntent()) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

private struct RevealHint: View {
    let entry: SnapshotEntry
    var body: some View {
        if entry.tapReveals {
            Image(systemName: entry.snapshot?.hidesAmounts == false ? "eye" : "eye.slash")
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityLabel(entry.snapshot?.hidesAmounts == false ? "Amounts shown" : "Tap to show amounts")
        }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.title3).foregroundStyle(.tint)
            Spacer(minLength: 0)
            Text("WealthOS").font(.headline)
            Text("Open the app to show your figures here.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Budget progress, or nil-safe empty bar.
private struct BudgetBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(WidgetFormat.budgetColor(fraction))
                    .frame(width: max(4, proxy.size.width * min(1, fraction)))
            }
        }
        .frame(height: 6)
    }
}

private struct FooterLine: View {
    let snapshot: WidgetSnapshot
    let date: Date

    var body: some View {
        if let days = snapshot.bankAccessDaysLeft(asOf: date), days <= 7 {
            Label(WidgetFormat.bankText(days), systemImage: "building.columns")
                .font(.caption2.weight(.semibold)).foregroundStyle(.orange).lineLimit(1)
        } else {
            Text("Updated \(snapshot.updatedAt, style: .relative) ago")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - Net worth

struct NetWorthWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        TapToReveal(entry: entry) { content }.containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder private var content: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryInline:
                Text("Net worth \(WidgetFormat.money(snapshot.netWorth, snapshot))").privacySensitive()
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text("Net worth").font(.caption2).foregroundStyle(.secondary)
                    Text(WidgetFormat.money(snapshot.netWorth, snapshot))
                        .font(.headline).minimumScaleFactor(0.6).lineLimit(1).privacySensitive()
                    Text("Month \(WidgetFormat.money(snapshot.spentThisMonth(asOf: entry.date), snapshot))")
                        .font(.caption2).lineLimit(1).privacySensitive()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .systemMedium:
                medium(snapshot)
            case .systemLarge:
                LargeNetWorthView(snapshot: snapshot, entry: entry)
            default:
                small(snapshot)
            }
        } else if family == .accessoryInline || family == .accessoryRectangular {
            Text("Open WealthOS")
        } else {
            EmptyStateView()
        }
    }

    private func headline(_ snapshot: WidgetSnapshot, showChange: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Net Worth").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if !snapshot.isComplete {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                RevealHint(entry: entry)
            }
            Text(WidgetFormat.money(snapshot.netWorth, snapshot))
                .font(.title2.weight(.bold)).monospacedDigit()
                .minimumScaleFactor(0.5).lineLimit(1)
                .privacySensitive()
            if showChange, let change = snapshot.monthChange(asOf: entry.date) {
                MonthChangeText(change: change, snapshot: snapshot)
            }
        }
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            headline(snapshot)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 1) {
                Text("This month").font(.caption2).foregroundStyle(.secondary)
                Text(WidgetFormat.money(snapshot.spentThisMonth(asOf: entry.date), snapshot))
                    .font(.subheadline.weight(.semibold)).monospacedDigit().privacySensitive()
            }
            FooterLine(snapshot: snapshot, date: entry.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                headline(snapshot, showChange: true)
                Spacer(minLength: 0)
                FooterLine(snapshot: snapshot, date: entry.date)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            SpendingColumn(snapshot: snapshot, date: entry.date)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct SpendingColumn: View {
    let snapshot: WidgetSnapshot
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Today", snapshot.spentToday(asOf: date))
            row("This month", snapshot.spentThisMonth(asOf: date))
            Spacer(minLength: 0)
            if let budget = snapshot.budget(asOf: date) {
                let fraction = NSDecimalNumber(decimal: budget.spent / budget.limit).doubleValue
                let left = budget.limit - budget.spent
                VStack(alignment: .leading, spacing: 3) {
                    Text(left >= 0 ? "\(WidgetFormat.money(left, snapshot)) left" : "\(WidgetFormat.money(-left, snapshot)) over")
                        .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).privacySensitive()
                    BudgetBar(fraction: fraction)
                }
            }
        }
    }

    private func row(_ title: String, _ value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(WidgetFormat.money(value, snapshot))
                .font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).privacySensitive()
        }
    }
}

// MARK: - Spending

struct SpendingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        TapToReveal(entry: entry) { content }.containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder private var content: some View {
        if let snapshot = entry.snapshot {
            let budget = snapshot.budget(asOf: entry.date)
            let fraction = budget.map { NSDecimalNumber(decimal: $0.spent / $0.limit).doubleValue } ?? 0
            switch family {
            case .accessoryCircular:
                if let budget {
                    Gauge(value: min(1, fraction)) {
                        Image(systemName: "cart")
                    } currentValueLabel: {
                        Text(snapshot.hidesAmounts ? "••" : "\(Int((fraction * 100).rounded()))%")
                            .privacySensitive()
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .accessibilityLabel("Budget used")
                    .accessibilityValue(WidgetFormat.money(budget.spent, snapshot))
                } else {
                    VStack(spacing: 0) {
                        Image(systemName: "cart").font(.caption)
                        Text(WidgetFormat.money(snapshot.spentToday(asOf: entry.date), snapshot))
                            .font(.caption2).minimumScaleFactor(0.5).lineLimit(1).privacySensitive()
                    }
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today \(WidgetFormat.money(snapshot.spentToday(asOf: entry.date), snapshot))")
                        .font(.headline).lineLimit(1).minimumScaleFactor(0.6).privacySensitive()
                    if let budget {
                        let left = budget.limit - budget.spent
                        Text(left >= 0 ? "Budget \(WidgetFormat.money(left, snapshot)) left" : "Budget \(WidgetFormat.money(-left, snapshot)) over")
                            .font(.caption).lineLimit(1).privacySensitive()
                        ProgressView(value: min(1, fraction))
                    } else {
                        Text("Month \(WidgetFormat.money(snapshot.spentThisMonth(asOf: entry.date), snapshot))")
                            .font(.caption).lineLimit(1).privacySensitive()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Spending").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        RevealHint(entry: entry)
                    }
                    SpendingColumn(snapshot: snapshot, date: entry.date)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        } else if family == .systemSmall {
            EmptyStateView()
        } else {
            Image(systemName: "cart")
        }
    }
}

// MARK: - Large

private struct MonthChangeText: View {
    let change: Decimal
    let snapshot: WidgetSnapshot

    var body: some View {
        let color: Color = snapshot.hidesAmounts || change == 0 ? .secondary : (change > 0 ? .green : .red)
        Text("\(WidgetFormat.signedMoney(change, snapshot)) this month")
            .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(color).lineLimit(1)
            .privacySensitive()
    }
}

private struct LargeNetWorthView: View {
    let snapshot: WidgetSnapshot
    let entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Net worth
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Net Worth").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if !snapshot.isComplete {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    RevealHint(entry: entry)
                }
                Text(WidgetFormat.money(snapshot.netWorth, snapshot))
                    .font(.largeTitle.weight(.bold)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                    .privacySensitive()
                if let change = snapshot.monthChange(asOf: entry.date) {
                    MonthChangeText(change: change, snapshot: snapshot)
                }
            }

            // Breakdown
            HStack(spacing: 8) {
                tile("Cash", snapshot.liquid, symbol: "banknote", tint: .blue)
                tile("Investments", snapshot.investments, symbol: "chart.line.uptrend.xyaxis", tint: .purple)
                tile("Debts", snapshot.liabilities, symbol: "creditcard", tint: .orange)
            }

            Divider()

            // This month
            HStack(alignment: .top) {
                figure("Today", snapshot.spentToday(asOf: entry.date))
                Spacer(minLength: 4)
                figure("Spent", snapshot.spentThisMonth(asOf: entry.date))
                Spacer(minLength: 4)
                figure("Income", snapshot.incomeThisMonth(asOf: entry.date))
            }
            if let budget = snapshot.budget(asOf: entry.date) {
                let fraction = NSDecimalNumber(decimal: budget.spent / budget.limit).doubleValue
                let left = budget.limit - budget.spent
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Budget").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(left >= 0 ? "\(WidgetFormat.money(left, snapshot)) left" : "\(WidgetFormat.money(-left, snapshot)) over")
                            .font(.caption.weight(.semibold)).monospacedDigit().privacySensitive()
                    }
                    BudgetBar(fraction: fraction)
                }
            }

            // Top categories
            let top = snapshot.topCategories(asOf: entry.date)
            if !top.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top spending").font(.caption2).foregroundStyle(.secondary)
                    ForEach(Array(top.enumerated()), id: \.offset) { _, category in
                        HStack {
                            Text(category.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text(WidgetFormat.money(category.amount, snapshot))
                                .font(.caption.weight(.semibold)).monospacedDigit().privacySensitive()
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            FooterLine(snapshot: snapshot, date: entry.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tile(_ title: String, _ value: Decimal?, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption2).foregroundStyle(tint).lineLimit(1)
            Text(WidgetFormat.money(value ?? 0, snapshot))
                .font(.subheadline.weight(.semibold)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                .privacySensitive()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func figure(_ title: String, _ value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(WidgetFormat.money(value, snapshot))
                .font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .privacySensitive()
        }
    }
}
