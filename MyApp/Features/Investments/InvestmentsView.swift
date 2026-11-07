import SwiftUI
import SwiftData
import Charts

struct InvestmentsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @State private var showHoldingEditor = false
    @State private var showRates = false
    @State private var selectedAngle: Double?
    @Query private var quotes: [MarketQuote]
    @Environment(MarketDataService.self) private var market
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            FinanceReader { engine in
                ScrollView {
                    VStack(spacing: 20) {
                        if app.isDemoMode { DemoBanner() }
                        MarketStatusCard()
                        portfolioHeader(engine)
                        if engine.positions.isEmpty {
                            EmptyStateCard(title: "Track your portfolio",
                                           message: "Find stocks, ETFs and crypto, record what you bought and follow cost basis, value and profit. No broker connection needed.",
                                           symbol: "chart.pie", actionTitle: "Add Investment") { showHoldingEditor = true }
                        } else {
                            allocationCard(engine)
                            historyCard
                            holdingsList(engine)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .screenBackground()
                .refreshable {
                    if market.isEnabled { await market.refresh(context: context, baseCurrency: baseCurrency, force: true) }
                }
            }
            .navigationTitle("Investments")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showRates = true } label: { Image(systemName: "dollarsign.arrow.circlepath") }
                        .accessibilityLabel("Exchange rates")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showHoldingEditor = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add investment")
                }
            }
            .sheet(isPresented: $showHoldingEditor) { AssetDiscoveryView() }
            .sheet(isPresented: $showRates) { NavigationStack { ExchangeRatesView() } }
        }
    }

    private func portfolioHeader(_ engine: FinanceEngine) -> some View {
        let value = engine.portfolioMarketValue
        let cost = engine.portfolioCostBasis
        let unrealized = value - cost
        let fraction: Decimal? = cost > 0 ? unrealized / cost : nil
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Portfolio Value").font(.subheadline).foregroundStyle(.secondary)
                MoneyText(amount: value, code: baseCurrency)
                    .scaledFont(34)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 6) {
                    Text(MoneyFormat.string(unrealized, code: baseCurrency, showSign: true))
                    if let fraction {
                        Text(MoneyFormat.percent(fraction, showSign: true))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.signColor(unrealized).opacity(0.14), in: Capsule())
                    }
                    Text("unrealized").font(.subheadline).foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(Theme.signColor(unrealized))
            }
            Divider()
            MetricRow(metrics: [
                Metric(title: "Cost basis", value: MoneyFormat.string(cost, code: baseCurrency, fractionDigits: 0)),
                Metric(title: "Realized P/L", value: MoneyFormat.string(engine.portfolioRealized, code: baseCurrency, showSign: true, fractionDigits: 0),
                       color: Theme.signColor(engine.portfolioRealized)),
                Metric(title: "Uninvested cash", value: MoneyFormat.string(engine.summary.investmentAccounts, code: baseCurrency, fractionDigits: 0)),
            ])
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func allocationCard(_ engine: FinanceEngine) -> some View {
        let data = engine.allocation
        let total = data.reduce(Decimal(0)) { $0 + $1.value }
        let selected = selectedSlice(data)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Allocation").font(.headline)
            if data.isEmpty {
                Text("Allocation appears once holdings have a value.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 20) {
                    Chart(data, id: \.assetClass) { item in
                        SectorMark(angle: .value("Value", item.value.doubleValue), innerRadius: .ratio(0.64), angularInset: 2)
                            .foregroundStyle(Theme.color(named: item.assetClass.colorName).gradient)
                            .cornerRadius(5)
                            .opacity(selected == nil || selected == item.assetClass ? 1 : 0.4)
                    }
                    .chartAngleSelection(value: $selectedAngle)
                    .chartBackground { _ in
                        VStack(spacing: 0) {
                            if let selected, let item = data.first(where: { $0.assetClass == selected }), total > 0 {
                                Text(selected.title).font(.caption).foregroundStyle(.secondary)
                                Text(MoneyFormat.percent(item.value / total, fractionDigits: 0)).font(.headline)
                            } else {
                                Image(systemName: "chart.pie.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 130, height: 130)
                    .accessibilityLabel("Asset allocation chart")

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(data, id: \.assetClass) { item in
                            HStack(spacing: 8) {
                                Circle().fill(Theme.color(named: item.assetClass.colorName)).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.assetClass.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(MoneyFormat.string(item.value, code: baseCurrency, fractionDigits: 0))
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Text(total > 0 ? MoneyFormat.percent(item.value / total, fractionDigits: 0) : "—")
                                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .card()
    }

    private func selectedSlice(_ data: [(assetClass: AssetClass, value: Decimal)]) -> AssetClass? {
        guard let selectedAngle else { return nil }
        var cumulative = 0.0
        for item in data {
            cumulative += item.value.doubleValue
            if selectedAngle <= cumulative { return item.assetClass }
        }
        return nil
    }

    @ViewBuilder
    private var historyCard: some View {
        let points = snapshots.filter { $0.currencyCode == baseCurrency && $0.investmentTotal != 0 }
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: 12) {
                Text("Investment Value History").font(.headline)
                Text("From recorded daily snapshots (holdings + investment account balances).")
                    .font(.caption).foregroundStyle(.secondary)
                Chart(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Value", point.investmentTotal.doubleValue))
                        .foregroundStyle(Color.purple)
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Date", point.date), y: .value("Value", point.investmentTotal.doubleValue))
                        .foregroundStyle(LinearGradient(colors: [.purple.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel { if let v = value.as(Double.self) { Text(MoneyFormat.compact(v, code: baseCurrency)) } }
                    }
                }
                .frame(height: 160)
            }
            .card()
        }
    }

    private func holdingsList(_ engine: FinanceEngine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Holdings")
            VStack(spacing: 0) {
                let sorted = engine.positions.sorted { ($0.marketValueBase ?? 0) > ($1.marketValueBase ?? 0) }
                let quoteIndex = Dictionary(quotes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                ForEach(sorted) { position in
                    NavigationLink { HoldingDetailView(holding: position.holding) } label: {
                        HoldingRow(position: position, baseCurrency: baseCurrency,
                                   status: PriceStatus.describe(holding: position.holding,
                                                                quote: market.quote(for: position.holding, in: quoteIndex)))
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if position.id != sorted.last?.id { Divider() }
                }
            }
            .card(padding: 14)
        }
    }
}

struct HoldingRow: View {
    let position: PositionSummary
    let baseCurrency: String
    let status: PriceStatus

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: position.holding.assetClass.symbol, color: Theme.color(named: position.holding.assetClass.colorName))
            VStack(alignment: .leading, spacing: 3) {
                Text(position.holding.symbol.isEmpty ? position.holding.name : position.holding.symbol)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text("\(MoneyFormat.quantity(position.position.quantity)) × \(MoneyFormat.string(position.holding.currentPrice, code: position.holding.currencyCode))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                PriceStatusBadge(status: status)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(MoneyFormat.string(position.marketValue, code: position.holding.currencyCode))
                    .font(.body.weight(.semibold)).monospacedDigit()
                if let fraction = position.returnFraction {
                    Text(MoneyFormat.percent(fraction, showSign: true))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Theme.signColor(fraction))
                }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
