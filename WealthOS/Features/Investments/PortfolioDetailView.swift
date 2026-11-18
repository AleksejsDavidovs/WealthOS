import SwiftUI
import SwiftData
import Charts

extension Trading212Analytics {
    /// Builds the analytics from stored rows; rows in another currency than the account's are skipped.
    static func make(snapshot: BrokerAccountSnapshot, positions: [BrokerPosition], orders: [BrokerOrder],
                     cash: [BrokerCashTransaction], dividends: [BrokerDividend], points: [BrokerValuePoint],
                     now: Date = .now) -> Trading212Analytics {
        let currency = snapshot.currencyCode
        func same(_ code: String) -> Bool { code.isEmpty || code.uppercased() == currency }
        return Trading212Analytics(
            currency: currency,
            trades: orders.filter { same($0.currencyCode) }.map {
                Trade(id: $0.key, date: $0.filledAt, ticker: $0.ticker, name: $0.name, isBuy: $0.isBuy, quantity: $0.quantity,
                      price: $0.price, instrumentCurrency: $0.instrumentCurrency, netValue: $0.netValue, fees: $0.fees, realized: $0.realized)
            },
            cash: cash.filter { same($0.currencyCode) }.map { Cash(id: $0.key, date: $0.date, type: $0.type, amount: $0.amount) },
            dividends: dividends.filter { same($0.currencyCode) }.map { Dividend(date: $0.paidOn, ticker: $0.ticker, name: $0.name, amount: $0.amount) },
            positions: positions.filter { same($0.valueCurrency) }.map {
                Position(ticker: $0.ticker, name: $0.name, value: $0.currentValue ?? 0, cost: $0.totalCost, unrealized: $0.unrealizedProfitLoss)
            },
            cashBalance: snapshot.cashTotal,
            valuePoints: points.filter { same($0.currencyCode) }.map { ValuePoint(date: $0.date, value: $0.value) },
            now: now)
    }
}

/// Everything about the portfolio: the full performance chart, and for Trading 212 the complete
/// history — deposits vs value, where the gain comes from, per-instrument results, trades and cash.
struct PortfolioDetailView: View {
    let engine: FinanceEngine
    @Environment(Trading212Service.self) private var service
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \PortfolioSnapshot.date) private var snapshots: [PortfolioSnapshot]
    @Query private var orders: [BrokerOrder]
    @Query private var cashRows: [BrokerCashTransaction]
    @Query private var dividendRows: [BrokerDividend]
    @Query(sort: \BrokerValuePoint.date) private var valuePoints: [BrokerValuePoint]

    @State private var range: PortfolioRange = .all
    @State private var selectedDate: Date?
    @State private var selectedHistoryDate: Date?
    @State private var showAllInstruments = false
    @State private var showAllTrades = false
    @State private var showAllCash = false

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                portfolioSection
                if let snapshot = engine.broker.snapshot {
                    let analytics = Trading212Analytics.make(snapshot: snapshot, positions: engine.broker.positions, orders: orders,
                                                             cash: cashRows, dividends: dividendRows, points: valuePoints)
                    trading212Sections(analytics)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        #if DEBUG
        .onAppear {
            // Development aid: `-UIDetailScroll <t212|gain|instruments|trades|cash>` for visual checks.
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-UIDetailScroll"), index + 1 < arguments.count {
                let target = arguments[index + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { scroller.scrollTo(target, anchor: .top) }
            }
        }
        #endif
        }
        .screenBackground()
        .navigationTitle("Portfolio Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Whole portfolio

    @ViewBuilder private var portfolioSection: some View {
        let points = snapshots.filter { $0.currencyCode == baseCurrency }
            .map { PortfolioPoint(date: $0.date, costedValue: $0.costedValue, costBasis: $0.costBasis, totalValue: $0.totalValue) }
        let performance = PortfolioPerformance(points: points, from: range.start(now: .now))
        let total = PortfolioPerformance.totalReturn(unrealized: engine.portfolioUnrealized, realized: engine.portfolioRealized,
                                                     costBasis: engine.portfolioCostBasis)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("All investments").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(MoneyFormat.string(engine.portfolioMarketValue, code: baseCurrency))
                    .font(.largeTitle.weight(.bold)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                HStack(spacing: 6) {
                    Text(MoneyFormat.string(total.amount, code: baseCurrency, showSign: true))
                    if let fraction = total.fraction { Text("· \(MoneyFormat.percent(fraction, showSign: true))") }
                    Text("total return").foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.signColor(total.amount))
            }
            if points.count >= 2 {
                Picker("Range", selection: $range) {
                    ForEach(PortfolioRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                selectionHeader(performance)
                portfolioChart(performance)
                HStack(alignment: .top) {
                    metric("Market gain", MoneyFormat.string(performance.marketGain, code: baseCurrency, showSign: true, fractionDigits: 0),
                           Theme.signColor(performance.marketGain))
                    metric("Added", MoneyFormat.string(performance.contributions, code: baseCurrency, showSign: true, fractionDigits: 0), .primary)
                    if let twr = performance.timeWeighted {
                        metric(performance.annualized == nil ? "Time-weighted" : "Per year",
                               MoneyFormat.percent(performance.annualized ?? twr, showSign: true), Theme.signColor(twr))
                    }
                }
            } else {
                Label("The value chart fills in one point a day from the first day WealthOS tracked your portfolio.", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .top) {
                metric("Invested", MoneyFormat.string(engine.portfolioCostBasis, code: baseCurrency, fractionDigits: 0), .primary)
                metric("Worth now", MoneyFormat.string(engine.portfolioCostedValue, code: baseCurrency, fractionDigits: 0), .primary)
                metric("Unrealized", MoneyFormat.string(engine.portfolioUnrealized, code: baseCurrency, showSign: true, fractionDigits: 0),
                       Theme.signColor(engine.portfolioUnrealized))
                metric("Realized", MoneyFormat.string(engine.portfolioRealized, code: baseCurrency, showSign: true, fractionDigits: 0),
                       Theme.signColor(engine.portfolioRealized))
            }
        }
        .card()
    }

    @ViewBuilder private func selectionHeader(_ performance: PortfolioPerformance) -> some View {
        if let selectedDate, let point = performance.points.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }) {
            HStack {
                Text(point.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                Spacer()
                Text("Worth \(MoneyFormat.string(point.costedValue, code: baseCurrency, fractionDigits: 0))")
                Text("· in \(MoneyFormat.string(point.costBasis, code: baseCurrency, fractionDigits: 0))").foregroundStyle(.secondary)
                Text(MoneyFormat.string(point.costedValue - point.costBasis, code: baseCurrency, showSign: true, fractionDigits: 0))
                    .foregroundStyle(Theme.signColor(point.costedValue - point.costBasis))
            }
            .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        } else {
            HStack(spacing: 12) {
                legend("Worth", Theme.projection, dashed: false)
                legend("Invested", .secondary, dashed: true)
                Spacer()
                Text("Touch and hold for details").foregroundStyle(.tertiary)
            }
            .font(.caption2)
        }
    }

    private func portfolioChart(_ performance: PortfolioPerformance) -> some View {
        Chart {
            ForEach(performance.points, id: \.date) { point in
                AreaMark(x: .value("Date", point.date), y: .value("Worth", point.costedValue.doubleValue))
                    .foregroundStyle(LinearGradient(colors: [Theme.projection.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", point.date), y: .value("Worth", point.costedValue.doubleValue), series: .value("Series", "Worth"))
                    .foregroundStyle(Theme.projection).interpolationMethod(.monotone)
                LineMark(x: .value("Date", point.date), y: .value("Invested", point.costBasis.doubleValue), series: .value("Series", "Invested"))
                    .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4])).interpolationMethod(.stepEnd)
            }
            if let selectedDate {
                RuleMark(x: .value("Selected", selectedDate)).foregroundStyle(Color.secondary.opacity(0.4))
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis { moneyAxis }
        .chartLegend(.hidden)
        .frame(height: 220)
        .accessibilityLabel("Portfolio worth and invested amount over time")
    }

    // MARK: Trading 212

    @ViewBuilder private func trading212Sections(_ a: Trading212Analytics) -> some View {
        let code = a.currency
        let missing = Trading212HistoryKind.allCases.filter { service.historyErrors[$0] == .missingPermission }

        SectionHeader("Trading 212", subtitle: a.firstActivity.map { "History since \($0.formatted(.dateTime.month(.abbreviated).year()))" })
            .padding(.top, 4)
            .id("t212")

        if !missing.isEmpty {
            InfoBanner(text: "Your API key can't read \(missing.map(\.title).joined(separator: ", ")). Create a key with \(missing.map(\.scope).joined(separator: ", ")) in Trading 212 and reconnect in Settings → Investment Integrations.",
                       symbol: "key.fill", tint: .orange)
        }
        if !a.hasHistory {
            InfoBanner(text: service.historyFetchedAt(.orders) == nil
                       ? "Your Trading 212 history downloads with the next sync (pull to refresh on Investments)."
                       : "No trades or deposits in your Trading 212 history yet.",
                       symbol: "clock", tint: .blue)
        }

        // Headline numbers
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            StatTile(title: "Account value", value: money(a.currentValue, code), symbol: "building.columns.fill", tint: Theme.accent,
                     footnote: "Cash \(money(a.cashBalance, code, digits: 0))")
            StatTile(title: "Deposited", value: money(a.netDeposits, code), symbol: "arrow.down.to.line", tint: .blue,
                     footnote: a.withdrawn > 0 ? "\(money(a.deposited, code, digits: 0)) in · \(money(a.withdrawn, code, digits: 0)) out" : nil)
            StatTile(title: "Total gain", value: money(a.totalGain, code, sign: true), symbol: "chart.line.uptrend.xyaxis",
                     tint: Theme.signColor(a.totalGain),
                     footnote: a.gainFraction.map { "\(MoneyFormat.percent($0, showSign: true)) on money deposited" })
            StatTile(title: "Per year", value: a.moneyWeightedReturn.map { MoneyFormat.percent(Decimal($0), showSign: true) } ?? "—",
                     symbol: "percent", tint: .purple,
                     footnote: a.moneyWeightedReturn == nil ? "Needs 30+ days of deposits" : "Money-weighted (XIRR)")
        }

        if a.hasHistory { historyChart(a) }
        gainBreakdown(a).id("gain")
        yearCard(a)
        DividendsCard(engine: engine).id("dividends")
        if !a.cash.isEmpty { monthlyFlows(a) }
        if !a.instruments.isEmpty { instrumentsCard(a).id("instruments") }
        if !a.trades.isEmpty { tradesCard(a).id("trades") }
        if !a.cash.isEmpty { cashCard(a).id("cash") }

        Text("From your Trading 212 history (read-only). Total gain = account value − money deposited. \"Per year\" weighs every deposit by how long it was invested. The account's value is recorded once a day from the first sync, so the worth line starts then.")
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
    }

    private func historyChart(_ a: Trading212Analytics) -> some View {
        let timeline = a.timeline
        let code = a.currency
        let selected = selectedHistoryDate.flatMap { date in timeline.last { $0.date <= date } ?? timeline.first }
        let selectedValue = selectedHistoryDate.flatMap { date in
            a.valuePoints.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Deposited vs Worth").font(.headline)
            if let selected, let date = selectedHistoryDate {
                HStack(spacing: 10) {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    Spacer()
                    Text("In \(money(selected.deposited, code, digits: 0))")
                    Text("At cost \(money(selected.atCost, code, digits: 0))").foregroundStyle(.secondary)
                    if let value = selectedValue, abs(value.date.timeIntervalSince(date)) < 3 * 86_400 {
                        Text("Worth \(money(value.value, code, digits: 0))").foregroundStyle(Theme.projection)
                    }
                }
                .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            } else {
                HStack(spacing: 12) {
                    legend("Deposited", .blue, dashed: false)
                    legend("Shares at cost", .secondary, dashed: true)
                    legend("Worth", Theme.projection, dashed: false)
                }
                .font(.caption2)
            }
            Chart {
                ForEach(timeline) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Deposited", point.deposited.doubleValue), series: .value("Series", "Deposited"))
                        .foregroundStyle(Color.blue).interpolationMethod(.stepEnd)
                    LineMark(x: .value("Date", point.date), y: .value("At cost", point.atCost.doubleValue), series: .value("Series", "At cost"))
                        .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4])).interpolationMethod(.stepEnd)
                }
                ForEach(a.valuePoints, id: \.date) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Worth", point.value.doubleValue), series: .value("Series", "Worth"))
                        .foregroundStyle(Theme.projection).lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                PointMark(x: .value("Date", a.now), y: .value("Worth", a.currentValue.doubleValue))
                    .foregroundStyle(Theme.projection).symbolSize(40)
                if let selectedHistoryDate {
                    RuleMark(x: .value("Selected", selectedHistoryDate)).foregroundStyle(Color.secondary.opacity(0.4))
                }
            }
            .chartXSelection(value: $selectedHistoryDate)
            .chartYAxis { moneyAxis(code) }
            .chartLegend(.hidden)
            .frame(height: 220)
            .accessibilityLabel("Money deposited, shares at cost and account worth over time")
        }
        .card()
    }

    private func gainBreakdown(_ a: Trading212Analytics) -> some View {
        let code = a.currency
        let rows: [(String, String, Decimal)] = [
            ("Price gains", "chart.line.uptrend.xyaxis", a.unrealized),
            ("Realized from sales", "checkmark.circle", a.realized),
            ("Dividends", "banknote", a.dividends),
            ("Interest on cash", "percent", a.interest),
            ("Fees and taxes", "minus.circle", -a.fees),
        ] + (a.otherGain != 0 ? [("Other (currency, rounding)", "arrow.left.arrow.right", a.otherGain)] : [])
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where the Gain Comes From").font(.headline)
                Spacer()
                Text(money(a.totalGain, code, sign: true)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(Theme.signColor(a.totalGain))
            }
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.1).font(.subheadline).foregroundStyle(.secondary).frame(width: 22)
                    Text(row.0).font(.subheadline)
                    Spacer()
                    Text(money(row.2, code, sign: true)).font(.subheadline.weight(.medium)).monospacedDigit()
                        .foregroundStyle(row.2 == 0 ? Color.secondary : Theme.signColor(row.2))
                }
            }
        }
        .card()
    }

    private func yearCard(_ a: Trading212Analytics) -> some View {
        let code = a.currency
        let year = Calendar.current.dateInterval(of: .year, for: a.now) ?? DateInterval(start: a.now, duration: 0)
        let t = a.totals(in: year)
        return VStack(alignment: .leading, spacing: 12) {
            Text("This Year · \(a.now.formatted(.dateTime.year()))").font(.headline)
            HStack(alignment: .top) {
                metric("Deposited", money(t.deposited - t.withdrawn, code, digits: 0), .primary)
                metric("Bought", money(t.bought, code, digits: 0), .primary)
                metric("Sold", money(t.sold, code, digits: 0), .primary)
            }
            HStack(alignment: .top) {
                metric("Realized", money(t.realized, code, sign: true, digits: 0), Theme.signColor(t.realized))
                metric("Dividends", money(t.dividends, code), Theme.positive)
                metric("Fees", money(t.fees, code), t.fees > 0 ? Theme.warning : .secondary)
            }
            Text("\(t.trades) trade\(t.trades == 1 ? "" : "s")\(t.interest > 0 ? " · \(money(t.interest, code)) interest" : "")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private func monthlyFlows(_ a: Trading212Analytics) -> some View {
        let months = a.monthlyFlows()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Deposits per Month").font(.headline)
                Spacer()
                Text("avg \(money(Money.round(months.reduce(0) { $0 + $1.net } / Decimal(max(1, months.count))), a.currency, digits: 0))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Chart {
                ForEach(months) { month in
                    BarMark(x: .value("Month", month.month, unit: .month), y: .value("Deposited", month.deposited.doubleValue))
                        .foregroundStyle(Color.blue.gradient).cornerRadius(3)
                    if month.withdrawn > 0 {
                        BarMark(x: .value("Month", month.month, unit: .month), y: .value("Withdrawn", -month.withdrawn.doubleValue))
                            .foregroundStyle(Color.orange.gradient).cornerRadius(3)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartYAxis { moneyAxis(a.currency) }
            .frame(height: 150)
        }
        .card()
    }

    private func instrumentsCard(_ a: Trading212Analytics) -> some View {
        let all = a.instruments
        let shown = showAllInstruments ? all : Array(all.prefix(8))
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("By Instrument", subtitle: "\(all.filter(\.isOpen).count) open · \(all.filter { !$0.isOpen }.count) closed")
            VStack(spacing: 0) {
                ForEach(shown) { item in
                    instrumentRow(item, code: a.currency)
                    if item.id != shown.last?.id { Divider().padding(.vertical, 8) }
                }
                if all.count > shown.count {
                    Divider().padding(.vertical, 8)
                    Button("Show All \(all.count)") { withAnimation { showAllInstruments = true } }
                        .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }
            }
            .card(padding: 14)
        }
    }

    private func instrumentRow(_ item: Trading212Analytics.Instrument, code: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("\(Trading212Matching.baseSymbol(ofTicker: item.ticker)) · \(item.isOpen ? "open" : "closed") · \(item.trades) trade\(item.trades == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(money(item.totalReturn, code, sign: true)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Theme.signColor(item.totalReturn))
                    if let fraction = item.returnFraction {
                        Text(MoneyFormat.percent(fraction, showSign: true)).font(.caption).monospacedDigit()
                            .foregroundStyle(Theme.signColor(item.totalReturn))
                    }
                }
            }
            Text(instrumentDetail(item, code: code)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func instrumentDetail(_ item: Trading212Analytics.Instrument, code: String) -> String {
        var parts: [String] = []
        if let value = item.value { parts.append("Worth \(money(value, code, digits: 0))") }
        if item.bought > 0 { parts.append("bought \(money(item.bought, code, digits: 0))") }
        if item.sold > 0 { parts.append("sold \(money(item.sold, code, digits: 0))") }
        if item.realized != 0 { parts.append("realized \(money(item.realized, code, sign: true, digits: 0))") }
        if item.dividends > 0 { parts.append("dividends \(money(item.dividends, code))") }
        return parts.joined(separator: " · ")
    }

    private func tradesCard(_ a: Trading212Analytics) -> some View {
        let shown = showAllTrades ? a.trades : Array(a.trades.prefix(10))
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Trades", subtitle: "\(a.trades.count) in total")
            VStack(spacing: 0) {
                ForEach(shown) { trade in
                    HStack(spacing: 12) {
                        IconBadge(symbol: trade.isBuy ? "cart.fill" : "arrow.up.right", color: trade.isBuy ? .blue : .orange, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(trade.name.isEmpty ? Trading212Matching.baseSymbol(ofTicker: trade.ticker) : trade.name)
                                .font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(tradeDetail(trade)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text((trade.isBuy ? "−" : "+") + money(trade.netValue, a.currency)).font(.subheadline.weight(.semibold)).monospacedDigit()
                            if !trade.isBuy, trade.realized != 0 {
                                Text(money(trade.realized, a.currency, sign: true)).font(.caption).monospacedDigit()
                                    .foregroundStyle(Theme.signColor(trade.realized))
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if trade.id != shown.last?.id { Divider().padding(.vertical, 8) }
                }
                if a.trades.count > shown.count {
                    Divider().padding(.vertical, 8)
                    Button("Show All \(a.trades.count) Trades") { withAnimation { showAllTrades = true } }
                        .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }
            }
            .card(padding: 14)
        }
    }

    private func tradeDetail(_ trade: Trading212Analytics.Trade) -> String {
        var parts = ["\(trade.isBuy ? "Buy" : "Sell") \(MoneyFormat.quantity(trade.quantity))"]
        if let price = trade.price, !trade.instrumentCurrency.isEmpty {
            parts[0] += " × \(MoneyFormat.string(price, code: trade.instrumentCurrency))"
        }
        parts.append(trade.date.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    private func cashCard(_ a: Trading212Analytics) -> some View {
        let shown = showAllCash ? a.cash : Array(a.cash.prefix(10))
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Deposits & Withdrawals", subtitle: "Plus fees, transfers and interest")
            VStack(spacing: 0) {
                ForEach(shown) { row in
                    HStack(spacing: 12) {
                        IconBadge(symbol: cashSymbol(row.type), color: row.amount >= 0 ? Theme.positive : .orange, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cashTitle(row.type)).font(.subheadline.weight(.medium))
                            Text(row.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(row.amount, a.currency, sign: true)).font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(row.amount >= 0 ? Theme.positive : Color.primary)
                    }
                    .accessibilityElement(children: .combine)
                    if row.id != shown.last?.id { Divider().padding(.vertical, 8) }
                }
                if a.cash.count > shown.count {
                    Divider().padding(.vertical, 8)
                    Button("Show All \(a.cash.count)") { withAnimation { showAllCash = true } }
                        .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }
            }
            .card(padding: 14)
        }
    }

    private func cashTitle(_ type: String) -> String {
        switch type.uppercased() {
        case "DEPOSIT": "Deposit"
        case "WITHDRAW": "Withdrawal"
        case "FEE": "Fee"
        case "TRANSFER": "Transfer"
        case "INTEREST_ON_FREE_CASH": "Interest on cash"
        case "LENDING_INTEREST": "Share lending interest"
        default: type.capitalized
        }
    }

    private func cashSymbol(_ type: String) -> String {
        switch type.uppercased() {
        case "DEPOSIT": "arrow.down.to.line"
        case "WITHDRAW": "arrow.up.to.line"
        case "FEE": "minus.circle"
        case "TRANSFER": "arrow.left.arrow.right"
        default: "percent"
        }
    }

    // MARK: Helpers

    private func money(_ value: Decimal, _ code: String, sign: Bool = false, digits: Int = 2) -> String {
        MoneyFormat.string(value, code: code, showSign: sign, fractionDigits: digits)
    }

    private var moneyAxis: some AxisContent { moneyAxis(baseCurrency) }

    private func moneyAxis(_ code: String) -> some AxisContent {
        AxisMarks(position: .trailing) { value in
            AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
            AxisValueLabel { if let v = value.as(Double.self) { Text(MoneyFormat.compact(v, code: code)) } }
        }
    }

    private func legend(_ title: String, _ color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 12, height: 2).opacity(dashed ? 0.6 : 1)
            Text(title).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
