import SwiftUI
import SwiftData
import Charts

/// Trading 212 dividends in the base currency, from the locally stored payouts.
private struct DividendData {
    let payments: [DividendPayment]
    let missingRates: Set<String>

    init(rows: [BrokerDividend], converter: CurrencyConverter) {
        let result = DividendStats.payments(rows.map { ($0.key, $0.paidOn, $0.amount, $0.currencyCode, $0.ticker, $0.name) },
                                            converter: converter)
        payments = result.payments
        missingRates = result.missingRates
    }
}

/// Explains why dividends may be missing; nil when everything is fine.
private func dividendNotice(_ service: Trading212Service) -> String? {
    switch service.dividendError {
    case .missingPermission?:
        return "Your Trading 212 API key doesn't include dividend history. Create a new key in Trading 212 with dividend history access (history:dividends) and reconnect in Settings → Investment Integrations."
    case _?:
        // Temporary failures are retried on the next sync; the last payouts stay visible.
        return nil
    case nil:
        return service.dividendsFetchedAt == nil && service.isConnected ? "Dividends download with the next Trading 212 sync." : nil
    }
}

// MARK: - Investments card

struct DividendsCard: View {
    let engine: FinanceEngine
    @Environment(Trading212Service.self) private var service
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \BrokerDividend.paidOn, order: .reverse) private var rows: [BrokerDividend]

    var body: some View {
        if !rows.isEmpty || (service.isConnected && engine.broker.snapshot != nil) {
            let data = DividendData(rows: rows, converter: engine.converter)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Dividends") {
                    if !rows.isEmpty {
                        NavigationLink("See All") { DividendsView(engine: engine) }.font(.subheadline.weight(.medium))
                    }
                }
                NavigationLink { DividendsView(engine: engine) } label: {
                    VStack(alignment: .leading, spacing: 14) {
                        MetricRow(metrics: [
                            Metric(title: "This month", value: MoneyFormat.string(DividendStats.thisMonth(data.payments), code: baseCurrency)),
                            Metric(title: "This year", value: MoneyFormat.string(DividendStats.thisYear(data.payments), code: baseCurrency)),
                            Metric(title: "Payouts", value: "\(data.payments.count)"),
                        ])
                        if !data.payments.isEmpty {
                            DividendBarChart(months: DividendStats.monthly(data.payments), code: baseCurrency, compact: true)
                                .frame(height: 70)
                        }
                        if let notice = dividendNotice(service) {
                            Text(notice).font(.caption).foregroundStyle(service.dividendError == nil ? Color.secondary : Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .card(padding: 14)
                }
                .buttonStyle(CardPressStyle())
                .disabled(rows.isEmpty)
            }
        }
    }
}

// MARK: - Chart

private struct DividendBarChart: View {
    let months: [DividendMonth]
    let code: String
    var compact = false
    @Binding var selected: Date?

    init(months: [DividendMonth], code: String, compact: Bool = false, selected: Binding<Date?> = .constant(nil)) {
        self.months = months
        self.code = code
        self.compact = compact
        _selected = selected
    }

    var body: some View {
        Chart {
            ForEach(months) { month in
                BarMark(x: .value("Month", month.month, unit: .month), y: .value("Dividends", month.total.doubleValue))
                    .foregroundStyle(Theme.accent.gradient)
                    .cornerRadius(3)
                    .opacity(selectedMonth == nil || selectedMonth?.month == month.month ? 1 : 0.4)
            }
        }
        .chartXSelection(value: $selected)
        .chartXAxis {
            if compact {
                AxisMarks { _ in }
            } else {
                AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
        }
        .chartYAxis {
            if compact {
                AxisMarks { _ in }
            } else {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel { if let v = value.as(Double.self) { Text(MoneyFormat.compact(v, code: code)) } }
                }
            }
        }
        .accessibilityLabel("Dividends per month")
    }

    private var selectedMonth: DividendMonth? {
        guard let selected else { return nil }
        return months.first { Calendar.current.isDate($0.month, equalTo: selected, toGranularity: .month) }
    }
}

// MARK: - Detail

struct DividendsView: View {
    let engine: FinanceEngine
    @Environment(Trading212Service.self) private var service
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \BrokerDividend.paidOn, order: .reverse) private var rows: [BrokerDividend]
    @State private var selectedMonth: Date?
    @State private var showAllPayouts = false

    var body: some View {
        let data = DividendData(rows: rows, converter: engine.converter)
        let months = DividendStats.monthly(data.payments)
        let year = Calendar.current.dateInterval(of: .year, for: .now)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let notice = dividendNotice(service), service.dividendError != nil {
                    InfoBanner(text: notice, symbol: "exclamationmark.triangle.fill", tint: .orange)
                }
                if !data.missingRates.isEmpty {
                    InfoBanner(text: "No exchange rate for \(data.missingRates.sorted().joined(separator: ", ")), so those dividends are left out of the totals.",
                               symbol: "exclamationmark.triangle.fill", tint: .orange)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    StatTile(title: "This month", value: money(DividendStats.thisMonth(data.payments)), symbol: "calendar", tint: Theme.accent)
                    StatTile(title: "This year", value: money(DividendStats.thisYear(data.payments)), symbol: "calendar.badge.checkmark", tint: Theme.accent)
                    StatTile(title: "Last 12 months", value: money(DividendStats.last12Months(data.payments)),
                             symbol: "chart.bar.fill", tint: .purple,
                             footnote: "≈ \(money(Money.round(DividendStats.last12Months(data.payments) / 12))) / month")
                    StatTile(title: "All time", value: money(Money.round(data.payments.reduce(0) { $0 + $1.amount })),
                             symbol: "sum", tint: .blue, footnote: "\(data.payments.count) payouts")
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Per Month").font(.headline)
                        Spacer()
                        if let selectedMonth, let month = months.first(where: { Calendar.current.isDate($0.month, equalTo: selectedMonth, toGranularity: .month) }) {
                            Text("\(month.month.formatted(.dateTime.month(.wide).year())) · \(money(month.total))")
                                .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.accent)
                        } else {
                            Text("Last 12 months").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DividendBarChart(months: months, code: baseCurrency, selected: $selectedMonth).frame(height: 180)
                }
                .card()

                if let year {
                    let holdings = DividendStats.byHolding(data.payments, in: year)
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("By Holding", subtitle: Date.now.formatted(.dateTime.year()))
                        VStack(spacing: 0) {
                            if holdings.isEmpty {
                                Text("No dividends this year yet.").font(.subheadline).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(holdings) { holding in
                                holdingRow(holding, yearTotal: DividendStats.thisYear(data.payments))
                                if holding.id != holdings.last?.id { Divider().padding(.vertical, 8) }
                            }
                        }
                        .card(padding: 14)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Payouts")
                    let shown = showAllPayouts ? data.payments : Array(data.payments.prefix(15))
                    VStack(spacing: 0) {
                        ForEach(shown) { payment in
                            payoutRow(payment, row: rows.first { $0.key == payment.id })
                            if payment.id != shown.last?.id { Divider().padding(.vertical, 8) }
                        }
                        if data.payments.count > shown.count {
                            Divider().padding(.vertical, 8)
                            Button("Show All \(data.payments.count) Payouts") { withAnimation { showAllPayouts = true } }
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .card(padding: 14)
                }

                Text("Net dividends as paid into your Trading 212 account (after withholding tax). They're already part of your Trading 212 cash, so they don't change net worth again.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .screenBackground()
        .navigationTitle("Dividends")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func money(_ value: Decimal) -> String { MoneyFormat.string(value, code: baseCurrency) }

    private func holdingRow(_ holding: DividendHolding, yearTotal: Decimal) -> some View {
        let share = yearTotal > 0 ? (holding.total / yearTotal).doubleValue : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(holding.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("\(Trading212Matching.baseSymbol(ofTicker: holding.ticker)) · \(holding.count) payout\(holding.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(money(holding.total)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Theme.accent).frame(width: max(3, proxy.size.width * share))
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
    }

    private func payoutRow(_ payment: DividendPayment, row: BrokerDividend?) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: "arrow.down.left", color: Theme.positive, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(payment.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(detail(payment, row: row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("+\(money(payment.amount))").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.positive)
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(_ payment: DividendPayment, row: BrokerDividend?) -> String {
        var parts = [payment.date.formatted(date: .abbreviated, time: .omitted)]
        if let row, let quantity = row.quantity, let perShare = row.grossPerShare, !row.instrumentCurrency.isEmpty {
            parts.append("\(MoneyFormat.quantity(quantity)) × \(MoneyFormat.string(perShare, code: row.instrumentCurrency, fractionDigits: 4))")
        }
        return parts.joined(separator: " · ")
    }
}
