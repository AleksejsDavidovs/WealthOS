import SwiftUI
import SwiftData
import Charts

struct InvestmentsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @State private var showHoldingEditor = false
    @State private var showRates = false
    @State private var selectedAngle: Double?
    @State private var debugShowDividends = false
    @State private var debugShowPortfolio = false
    @Query private var quotes: [MarketQuote]
    @Environment(MarketDataService.self) private var market
    @Environment(Trading212Service.self) private var trading212
    @Environment(BinanceService.self) private var binance
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            FinanceReader { engine in
                ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 20) {
                        if app.isDemoMode { DemoBanner() }
                        portfolioHeader(engine)
                        if !engine.hasAnyPositions && engine.broker.snapshot == nil && engine.binance.snapshot == nil {
                            EmptyStateCard(title: "Track your portfolio",
                                           message: "Find stocks, ETFs and crypto, record what you bought and follow cost basis, value and profit. No broker connection needed.",
                                           symbol: "chart.pie", actionTitle: "Add Investment") { showHoldingEditor = true }
                        } else {
                            if engine.hasAnyPositions { allocationCard(engine) }
                            PortfolioMapCard(engine: engine).id("map")
                            PortfolioPerformanceCard(engine: engine).id("performance")
                            Trading212PortfolioCard(engine: engine)
                            DividendsCard(engine: engine).id("dividends")
                            BinancePortfolioCard(engine: engine)
                            if !engine.positions.isEmpty { holdingsList(engine) }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                #if DEBUG
                .onAppear {
                    // Development aid: `-UIScrollTo <performance|dividends>` and `-UIScreen dividends` for visual checks.
                    let arguments = ProcessInfo.processInfo.arguments
                    if let index = arguments.firstIndex(of: "-UIScrollTo") {
                        let target = index + 1 < arguments.count ? arguments[index + 1] : "performance"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { scroller.scrollTo(target, anchor: .center) }
                    }
                    if app.debugScreen == "dividends" || app.debugScreen == "portfolio" {
                        let portfolio = app.debugScreen == "portfolio"
                        app.debugScreen = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            if portfolio { debugShowPortfolio = true } else { debugShowDividends = true }
                        }
                    }
                }
                #endif
                }
                .screenBackground()
                #if DEBUG
                .navigationDestination(isPresented: $debugShowDividends) { DividendsView(engine: engine) }
                .navigationDestination(isPresented: $debugShowPortfolio) { PortfolioDetailView(engine: engine) }
                #endif
                .refreshable {
                    if !app.isDemoMode {
                        async let broker: Void = refreshTrading212()
                        async let crypto: Void = refreshBinance()
                        _ = await (broker, crypto)
                    }
                    if market.isEnabled { await market.refresh(context: context, baseCurrency: baseCurrency, force: true) }
                }
            }
            .task {
                // Stale-only (15 min); the services skip fresh data, back off after failures and
                // never run twice at once. Never against demo data.
                guard !app.isDemoMode else { return }
                if trading212.isConnected { await trading212.syncIfStale(context: context) }
                if binance.isConnected { await binance.syncIfStale(context: context) }
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

    private func refreshTrading212() async {
        if trading212.isConnected { await trading212.sync(context: context, force: true) }
    }

    private func refreshBinance() async {
        if binance.isConnected { await binance.sync(context: context, force: true) }
    }

    private func portfolioHeader(_ engine: FinanceEngine) -> some View {
        let value = engine.portfolioMarketValue
        let cost = engine.portfolioCostBasis
        // Only positions with a known cost basis: synced crypto without one must not look like profit.
        let unrealized = engine.portfolioUnrealized
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
                if engine.positionsWithoutCost > 0 {
                    Text("Excludes \(engine.positionsWithoutCost) position\(engine.positionsWithoutCost == 1 ? "" : "s") without a known cost basis.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                                                                quote: market.quote(for: position.holding, in: quoteIndex)),
                                   countedVia: engine.countedVia(position.holding))
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
    /// The external source (Trading 212 / Binance) the user said already counts this holding.
    var countedVia: String?

    /// US stocks and ETFs by plain symbol ("AAPL" → "AAPL_US_EQ"); others show their letters.
    private var logoTicker: String? {
        let holding = position.holding
        guard holding.assetClass == .stock || holding.assetClass == .etf, !holding.symbol.isEmpty, !holding.symbol.contains(".") else { return nil }
        return "\(holding.symbol.uppercased())_US_EQ"
    }

    var body: some View {
        HStack(spacing: 12) {
            TickerLogo(ticker: logoTicker, symbol: position.holding.symbol.isEmpty ? position.holding.name : position.holding.symbol, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(position.holding.symbol.isEmpty ? position.holding.name : position.holding.symbol)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text("\(MoneyFormat.quantity(position.position.quantity)) × \(MoneyFormat.string(position.holding.currentPrice, code: position.holding.currencyCode))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                if position.error != nil {
                    Label("Invalid trade history · value unknown, not in totals", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(Theme.warning).lineLimit(2)
                } else if let countedVia {
                    Label("Counted via \(countedVia) · not in totals", systemImage: "link")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    PriceStatusBadge(status: status)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(position.error == nil ? MoneyFormat.string(position.marketValue, code: position.holding.currencyCode) : "—")
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
