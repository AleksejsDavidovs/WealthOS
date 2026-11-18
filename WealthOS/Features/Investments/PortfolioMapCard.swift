import SwiftUI

/// One tile of the portfolio map, in the base currency.
struct PortfolioMapItem: Identifiable, Equatable {
    let id: String
    let symbol: String
    let name: String
    /// Trading 212 ticker for the logo; nil = monogram.
    let logoTicker: String?
    let value: Decimal
    let gain: Decimal?
    let fraction: Decimal?
    let quantity: Decimal?
    let source: String

    /// Every valued position once: Trading 212, manual holdings (unless counted via a provider)
    /// and Binance. Largest first.
    @MainActor
    static func items(_ engine: FinanceEngine) -> [PortfolioMapItem] {
        var items: [PortfolioMapItem] = []
        let brokerTickers = Dictionary(engine.broker.positions.map { (Trading212Matching.baseSymbol(ofTicker: $0.ticker), $0.ticker) },
                                       uniquingKeysWith: { a, _ in a })
        for value in engine.brokerPositions {
            guard let base = value.valueBase, base > 0 else { continue }
            let position = value.position
            items.append(PortfolioMapItem(
                id: "t212:\(position.ticker)", symbol: position.displaySymbol,
                name: position.name.isEmpty ? position.displaySymbol : position.name,
                logoTicker: position.ticker, value: base, gain: value.unrealizedBase,
                fraction: value.unrealizedBase.flatMap { gain in value.costBase.flatMap { $0 > 0 ? gain / $0 : nil } },
                quantity: position.quantity, source: "Trading 212"))
        }
        for position in engine.positions where engine.countedVia(position.holding) == nil && position.error == nil {
            guard let base = position.marketValueBase, base > 0 else { continue }
            let holding = position.holding
            let symbol = holding.symbol.isEmpty ? holding.name : holding.symbol.uppercased()
            // Same symbol as a Trading 212 instrument → its logo; US stocks/ETFs → the usual "_US_EQ" ticker.
            let ticker = brokerTickers[symbol]
                ?? ((holding.assetClass == .stock || holding.assetClass == .etf) && !holding.symbol.isEmpty
                    && !holding.symbol.contains(".") ? "\(symbol)_US_EQ" : nil)
            items.append(PortfolioMapItem(
                id: "manual:\(holding.id)", symbol: symbol, name: holding.name.isEmpty ? symbol : holding.name,
                logoTicker: ticker, value: base, gain: position.unrealizedProfitBase,
                fraction: position.unrealizedProfitBase.flatMap { gain in position.costBasisBase.flatMap { $0 > 0 ? gain / $0 : nil } },
                quantity: position.position.quantity, source: "Manual"))
        }
        for asset in engine.binanceAssets {
            guard let base = asset.valueBase, base > 0 else { continue }
            items.append(PortfolioMapItem(id: "binance:\(asset.asset)", symbol: asset.asset, name: asset.asset, logoTicker: nil,
                                          value: base, gain: nil, fraction: nil, quantity: asset.quantity, source: "Binance"))
        }
        return items.sorted { $0.value > $1.value }
    }
}

/// Trading 212-style map: tile size = position value, color = return since purchase.
struct PortfolioMapCard: View {
    let engine: FinanceEngine
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @State private var selectedID: String?
    @State private var expanded = false

    /// Tiles shown before the rest is grouped into "Other".
    static let maximumTiles = 18

    var body: some View {
        let all = PortfolioMapItem.items(engine)
        if all.count >= 2 {
            let tiles = Self.grouped(all)
            let total = all.reduce(Decimal(0)) { $0 + $1.value }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Portfolio Map").font(.headline)
                    Spacer()
                    Text("Return since purchase").font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    let rects = Treemap.layout(tiles.map(\.value.doubleValue), in: CGRect(origin: .zero, size: proxy.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(tiles.enumerated()), id: \.element.id) { index, item in
                            let rect = rects[index].insetBy(dx: 2, dy: 2)
                            if rect.width > 1, rect.height > 1 {
                                tile(item, size: rect.size, share: total > 0 ? item.value / total : 0)
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                                    .onTapGesture {
                                        withAnimation(.snappy) { selectedID = selectedID == item.id ? nil : item.id }
                                    }
                            }
                        }
                    }
                }
                .frame(height: expanded ? 520 : 340)
                if let selected = tiles.first(where: { $0.id == selectedID }) {
                    selectionDetail(selected, share: total > 0 ? selected.value / total : 0)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                // The whole capsule is the button, not just the text.
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    Text(expanded ? "Show Less" : "Expand")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            .card()
        }
    }

    /// The largest positions, plus one "Other" tile for the rest.
    static func grouped(_ items: [PortfolioMapItem]) -> [PortfolioMapItem] {
        guard items.count > maximumTiles else { return items }
        let head = Array(items.prefix(maximumTiles - 1))
        let rest = items.dropFirst(maximumTiles - 1)
        let value = rest.reduce(Decimal(0)) { $0 + $1.value }
        let gains = rest.compactMap(\.gain)
        let gain: Decimal? = gains.isEmpty ? nil : gains.reduce(0, +)
        return head + [PortfolioMapItem(id: "other", symbol: "+\(rest.count)", name: "\(rest.count) smaller positions", logoTicker: nil,
                                        value: value, gain: gain, fraction: gain.map { $0 / max(value - $0, 1) }, quantity: nil, source: "")]
    }

    private func tileColor(_ item: PortfolioMapItem) -> Color {
        guard let fraction = item.fraction else { return Color.secondary.opacity(0.16) }
        let strength = min(1, abs(fraction.doubleValue) / 0.3)
        let base = fraction >= 0 ? Theme.positive : Theme.negative
        return base.opacity(0.16 + 0.22 * strength)
    }

    @ViewBuilder
    private func tile(_ item: PortfolioMapItem, size: CGSize, share: Decimal) -> some View {
        let short = min(size.width, size.height)
        let selected = selectedID == item.id
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tileColor(item))
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.7), lineWidth: 2)
            }
            VStack(spacing: short > 90 ? 6 : 3) {
                if short >= 38 {
                    TickerLogo(ticker: item.logoTicker, symbol: item.symbol, size: min(36, max(20, short * 0.3)))
                }
                if size.width >= 44, size.height >= 52 {
                    Text(item.symbol).font(.system(size: short > 90 ? 15 : 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                    Text(item.fraction.map { MoneyFormat.percent($0, showSign: false) } ?? MoneyFormat.percent(share, fractionDigits: 0))
                        .font(.system(size: short > 90 ? 15 : 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(item.fraction.map { $0 >= 0 ? Theme.positive : Theme.negative } ?? .secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .padding(4)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(MoneyFormat.string(item.value, code: baseCurrency))")
        .accessibilityValue(item.fraction.map { "Return \(MoneyFormat.percent($0, showSign: true))" } ?? "")
        .accessibilityAddTraits(.isButton)
    }

    private func selectionDetail(_ item: PortfolioMapItem, share: Decimal) -> some View {
        HStack(spacing: 12) {
            TickerLogo(ticker: item.logoTicker, symbol: item.symbol, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([item.quantity.map { "\(MoneyFormat.quantity($0)) \(item.symbol)" }, item.source.isEmpty ? nil : item.source,
                      "\(MoneyFormat.percent(share, fractionDigits: 1)) of portfolio"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(MoneyFormat.string(item.value, code: baseCurrency)).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let gain = item.gain {
                    Text("\(MoneyFormat.string(gain, code: baseCurrency, showSign: true))\(item.fraction.map { " (\(MoneyFormat.percent($0)))" } ?? "")")
                        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.signColor(gain))
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
