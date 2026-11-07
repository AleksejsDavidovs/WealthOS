import SwiftUI
import SwiftData

// MARK: - Status helpers

/// Describes where a holding's valuation price comes from and how fresh it is.
struct PriceStatus {
    let text: String
    let symbol: String
    let tint: Color

    static func describe(holding: Holding, quote: MarketQuote?, now: Date = .now) -> PriceStatus {
        if holding.priceSource == .market {
            let latency = holding.marketProvider?.latency ?? .endOfDay
            let freshness = quote.map { QuoteFreshness.evaluate(latency: latency, fetchedAt: $0.fetchedAt, now: now) } ?? .cached
            let tint: Color = switch freshness {
            case .live: Theme.positive
            case .delayed: Theme.accent
            case .cached: .secondary
            case .stale: Theme.warning
            }
            return PriceStatus(text: "Market · \(freshness.title(for: latency))", symbol: freshness.symbol, tint: tint)
        }
        let age = holding.priceUpdatedAt.map { Date.now.timeIntervalSince($0) } ?? .infinity
        return PriceStatus(text: holding.priceUpdatedAt.map { "Manual · \($0.formatted(.relative(presentation: .numeric)))" } ?? "Manual · no price",
                           symbol: "hand.point.up.left", tint: age > 7 * 86_400 ? Theme.warning : .secondary)
    }
}

struct PriceStatusBadge: View {
    let status: PriceStatus

    var body: some View {
        Label(status.text, systemImage: status.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.tint)
            .lineLimit(1)
    }
}

// MARK: - Investments header card

struct MarketStatusCard: View {
    @Environment(MarketDataService.self) private var market
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @AppStorage(SettingsKey.marketDataEnabled) private var enabled = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if enabled {
                HStack(alignment: .center, spacing: 12) {
                    IconBadge(symbol: "chart.line.uptrend.xyaxis", color: Theme.accentFill, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Online prices").font(.subheadline.weight(.semibold))
                        Group {
                            if market.isRefreshing {
                                Text("Updating…")
                            } else if let last = market.lastSuccessAt {
                                Text("Last update \(last.formatted(date: .abbreviated, time: .shortened))")
                            } else {
                                Text("Not updated yet")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if let error = market.lastReport?.errors.first {
                            Text(error).font(.caption).foregroundStyle(Theme.warning).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await market.refresh(context: context, baseCurrency: baseCurrency, force: true) }
                    } label: {
                        if market.isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise").font(.body.weight(.semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .disabled(market.isRefreshing)
                    .accessibilityLabel("Refresh prices")
                }
                .card(padding: 14)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "hand.point.up.left.fill").foregroundStyle(.blue).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prices are entered manually").font(.subheadline.weight(.semibold))
                        Text("Optionally fetch public market prices. Off by default — no data leaves your iPhone.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Set Up") { showSettings = true }
                        .buttonStyle(.bordered)
                }
                .card(padding: 14)
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { MarketDataSettingsView() } }
    }
}

// MARK: - Settings

struct MarketDataSettingsView: View {
    @Environment(MarketDataService.self) private var market
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @AppStorage(SettingsKey.marketDataEnabled) private var enabled = false
    @AppStorage(SettingsKey.marketAutoRefresh) private var autoRefresh = true
    @AppStorage(SettingsKey.marketAutoApplyFX) private var autoApplyFX = false
    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled.animation()) {
                    Label("Online Market Prices", systemImage: "network")
                }
            } footer: {
                Text("When on, WealthOS requests public prices over HTTPS. Only ticker symbols and currency codes are sent — never balances, quantities, goals or transactions. Providers can see your IP address, as with any website. Off by default; everything keeps working offline.")
            }

            if enabled {
                Section {
                    Toggle("Refresh When Opening the App", isOn: $autoRefresh)
                    Toggle("Apply Exchange Rates Automatically", isOn: $autoApplyFX)
                    Button {
                        Task { await market.refresh(context: context, baseCurrency: baseCurrency, force: true) }
                    } label: {
                        HStack {
                            Label("Refresh Now", systemImage: "arrow.clockwise")
                            Spacer()
                            if market.isRefreshing { ProgressView() }
                        }
                    }
                    .disabled(market.isRefreshing)
                    LabeledContent("Last successful update",
                                   value: market.lastSuccessAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    if let report = market.lastReport {
                        LabeledContent("Last refresh",
                                       value: "\(report.updatedQuotes) quotes · \(report.requests) requests · \(report.skippedFresh) cached")
                        ForEach(report.errors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(Theme.warning)
                        }
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Holding prices change only for holdings where you turn on “Update price automatically”, or when you tap “Use”. Prices you type yourself always take priority. Exchange rates are applied automatically only with the switch above.")
                }

                ForEach(MarketProvider.allCases) { provider in
                    ProviderSection(provider: provider)
                }

                Section {
                    Button("Clear Cached Quotes", role: .destructive) { showClearConfirmation = true }
                } footer: {
                    Text("Removes downloaded quotes. Your holding prices, price history and exchange rates are not changed.")
                }
            }

            Section("What the labels mean") {
                legend("dot.radiowaves.left.and.right", "Near real-time", "CoinGecko prices, refreshed by the provider about every minute.")
                legend("clock", "End of day", "Alpha Vantage free tier: closing price of the latest trading day.")
                legend("clock", "Daily reference rate", "Central-bank exchange rates published once per working day.")
                legend("tray.full", "Cached", "Last downloaded value, shown when a refresh isn't due or you're offline.")
                legend("hand.point.up.left", "Manual", "A price you entered yourself.")
            }
        }
        .navigationTitle("Market Data")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("Clear cached quotes?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { market.clearCache(context: context) }
        }
    }

    private func legend(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProviderSection: View {
    @Environment(MarketDataService.self) private var market
    let provider: MarketProvider
    @State private var keyText = ""
    @State private var message: String?

    var body: some View {
        Section {
            LabeledContent("Covers", value: provider.coverage)
            LabeledContent("Data", value: provider.latency.title)
            if let remaining = market.remainingToday(provider) {
                LabeledContent("Requests left today", value: "\(remaining) of \(provider.rateLimit(hasKey: true).perDay ?? 0)")
            }
            if provider.keychainAccount != nil {
                if market.hasKey(provider) {
                    LabeledContent("API key", value: "Saved in Keychain")
                    Button("Remove API Key", role: .destructive) {
                        try? market.setAPIKey(nil, for: provider)
                    }
                } else {
                    SecureField(provider.requiresAPIKey ? "API key (required)" : "Demo API key (optional)", text: $keyText)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Save Key") {
                        do {
                            try market.setAPIKey(keyText, for: provider)
                            keyText = ""
                            message = nil
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                    .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let signup = provider.signupURL {
                    Link(provider.requiresAPIKey ? "Get a free API key" : "About API keys", destination: signup)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.negative) }
            }
        } header: {
            Text(provider.displayName)
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        switch provider {
        case .coinGecko:
            "Works without a key at a low shared limit. A free Demo key (100 calls/min, 10,000/month) is more reliable. Use CoinGecko coin IDs such as “bitcoin” or “ethereum”."
        case .alphaVantage:
            "Free key: 25 requests per day, end-of-day prices. Supports US listings and many international exchanges via suffixes, e.g. VWCE.DEX (XETRA) or CSPX.LON (London, priced in pence). Real-time data requires a paid plan (from $49.99/month). Quotes are cached for 6 hours to save requests."
        case .frankfurter:
            "Free, no key, no quotas. Central-bank reference rates updated once per working day."
        }
    }
}

// MARK: - Holding detail

struct HoldingMarketSection: View {
    @Environment(MarketDataService.self) private var market
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @AppStorage(SettingsKey.marketDataEnabled) private var enabled = false
    @Query private var quotes: [MarketQuote]
    @Query private var rates: [CurrencyRate]
    @Bindable var holding: Holding
    var onLink: () -> Void

    private var quote: MarketQuote? {
        market.quote(for: holding, in: Dictionary(quotes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    var body: some View {
        Section {
            if let provider = holding.marketProvider {
                LabeledContent("Symbol", value: holding.marketSymbol)
                LabeledContent("Source", value: provider.displayName)
                if let quote {
                    let converter = CurrencyConverter.make(base: baseCurrency, rates: rates)
                    let converted = MarketPriceApplier.price(of: quote.value, in: holding.currencyCode, converter: converter)
                    let freshness = QuoteFreshness.evaluate(latency: provider.latency, fetchedAt: quote.fetchedAt, now: .now)
                    LabeledContent("Market price") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(converted.map { MoneyFormat.string($0, code: holding.currencyCode, fractionDigits: 2) } ?? "No exchange rate")
                                .font(.body.weight(.semibold)).monospacedDigit()
                            Label(freshness.title(for: provider.latency), systemImage: freshness.symbol)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let time = quote.quoteTime {
                        LabeledContent(provider.latency == .nearRealTime ? "Quote time" : "Trading day",
                                       value: provider.latency == .nearRealTime
                                       ? time.formatted(date: .abbreviated, time: .shortened)
                                       : time.formatted(date: .abbreviated, time: .omitted))
                    }
                    LabeledContent("Fetched", value: quote.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                    if let converted, converted != holding.currentPrice || holding.priceSource == .manual {
                        Button {
                            if MarketPriceApplier.apply(quote.value, to: holding, converter: converter, context: context) {
                                try? context.save()
                                DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
                            }
                        } label: {
                            Label("Use Market Price", systemImage: "arrow.down.to.line")
                        }
                    }
                } else {
                    Text(enabled ? "No quote downloaded yet. Pull to refresh on the Investments tab." :
                            "Turn on Online Market Prices in Settings to download quotes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Update price automatically", isOn: Binding(
                    get: { holding.autoApplyMarketPrice },
                    set: { holding.autoApplyMarketPrice = $0; try? context.save() }))
            } else {
                Button("Link a Market Symbol…", systemImage: "link", action: onLink)
            }
        } header: {
            Text("Market Data")
        } footer: {
            Text(holding.marketProvider == nil
                 ? "Optional. Link a ticker or coin to compare your price with public market data."
                 : "Your price is only replaced when you tap “Use Market Price” or turn on automatic updates. Entering a price manually turns automatic updates off. Previous prices stay in the price history.")
        }
    }
}

// MARK: - Symbol search

struct SymbolSearchView: View {
    @Environment(MarketDataService.self) private var market
    @Environment(\.dismiss) private var dismiss
    let provider: MarketProvider
    let initialQuery: String
    let onSelect: (SymbolMatch) -> Void
    @State private var query = ""
    @State private var results: [SymbolMatch] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(provider == .coinGecko ? "Coin name, e.g. Bitcoin" : "Name or ticker, e.g. Vanguard FTSE All-World",
                                  text: $query)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await search() } }
                        Button("Search") { Task { await search() } }
                            .disabled(query.trimmingCharacters(in: .whitespaces).count < 2 || isSearching)
                    }
                } footer: {
                    if provider == .alphaVantage {
                        Text("Each search uses 1 of the 25 daily Alpha Vantage requests.")
                    }
                }
                if isSearching { ProgressView().frame(maxWidth: .infinity) }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.warning).font(.footnote)
                }
                ForEach(results) { match in
                    Button {
                        onSelect(match)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(match.symbol).font(.body.weight(.semibold))
                                Spacer()
                                if let currency = match.currency {
                                    Text(currency).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                            Text(match.name).font(.subheadline).lineLimit(2)
                            if !match.detail.isEmpty {
                                Text(match.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Find Symbol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if query.isEmpty { query = initialQuery } }
        }
    }

    private func search() async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            results = try await market.search(query, provider: provider)
            if results.isEmpty { errorMessage = "No matches." }
        } catch {
            errorMessage = MarketDataError.from(error).localizedDescription
        }
    }
}
