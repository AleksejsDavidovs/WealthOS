import SwiftUI
import SwiftData
import Charts

struct HoldingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \InvestmentTrade.date, order: .reverse) private var allTrades: [InvestmentTrade]
    @Query(sort: \PricePoint.date) private var allPrices: [PricePoint]
    @Query private var accounts: [Account]
    let holding: Holding

    @State private var tradeRequest: TradeRequest?
    @State private var showPriceUpdate = false
    @State private var showEditor = false
    @State private var showDelete = false
    @State private var saveError: String?

    struct TradeRequest: Identifiable {
        let id = UUID()
        var kind: TradeKind
        var trade: InvestmentTrade?
    }

    private var trades: [InvestmentTrade] { allTrades.filter { $0.holdingID == holding.id } }
    private var prices: [PricePoint] { allPrices.filter { $0.holdingID == holding.id } }

    var body: some View {
        FinanceReader { engine in
            List {
                if let position = engine.position(for: holding) {
                    Section { summary(position) }
                    if let error = position.error {
                        Section { InfoBanner(text: error, symbol: "exclamationmark.triangle.fill", tint: .red) }
                    }
                    Section {
                        LabeledContent("Quantity", value: MoneyFormat.quantity(position.position.quantity))
                        LabeledContent("Average Cost", value: position.position.averageCost.map {
                            MoneyFormat.string($0, code: holding.currencyCode, fractionDigits: 4) } ?? "—")
                        LabeledContent("Cost Basis", value: MoneyFormat.string(position.position.costBasis, code: holding.currencyCode))
                        LabeledContent("Unrealized P/L") {
                            MoneyText(amount: position.unrealizedProfit, code: holding.currencyCode, showSign: true, colored: true)
                        }
                        LabeledContent("Realized P/L") {
                            MoneyText(amount: position.position.realizedProfit, code: holding.currencyCode, showSign: true, colored: true)
                        }
                        LabeledContent("Total Fees", value: MoneyFormat.string(position.position.totalFees, code: holding.currencyCode))
                        if holding.currencyCode != baseCurrency {
                            LabeledContent("Value in \(baseCurrency)", value: position.marketValueBase.map {
                                MoneyFormat.string($0, code: baseCurrency) } ?? "No exchange rate")
                        }
                    } footer: {
                        Text("Average-cost method. Buy fees are added to cost basis; sell fees reduce proceeds.")
                    }
                }

                HoldingMarketSection(holding: holding, onLink: { showEditor = true })

                if prices.count >= 2 {
                    Section("Price History (manual entries)") {
                        Chart(prices) { point in
                            LineMark(x: .value("Date", point.date), y: .value("Price", point.price.doubleValue))
                                .interpolationMethod(.linear)
                            PointMark(x: .value("Date", point.date), y: .value("Price", point.price.doubleValue))
                                .symbolSize(20)
                        }
                        .foregroundStyle(Theme.color(named: holding.assetClass.colorName))
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 150)
                        .padding(.vertical, 6)
                    }
                }

                Section {
                    ForEach(trades) { trade in
                        Button { tradeRequest = .init(kind: trade.kind, trade: trade) } label: { tradeRow(trade) }
                            .buttonStyle(.plain)
                    }
                    if trades.isEmpty {
                        Text("No trades yet. Record a buy to start tracking this position.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Trades")
                }

                Section {
                    Button("Delete Holding", systemImage: "trash", role: .destructive) { showDelete = true }
                }
            }
        }
        .navigationTitle(holding.symbol.isEmpty ? holding.name : holding.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Edit") { showEditor = true } }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button { tradeRequest = .init(kind: .buy) } label: { Label("Buy", systemImage: "plus").frame(maxWidth: .infinity) }
                    .prominentButtonStyle()
                Button { tradeRequest = .init(kind: .sell) } label: { Label("Sell", systemImage: "minus").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button { showPriceUpdate = true } label: { Label("Price", systemImage: "tag").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
        .sheet(item: $tradeRequest) { TradeEditorView(holding: holding, kind: $0.kind, trade: $0.trade) }
        .sheet(isPresented: $showPriceUpdate) { PriceUpdateView(holding: holding) }
        .sheet(isPresented: $showEditor) { HoldingEditorView(holding: holding) }
        .confirmationDialog("Delete \(holding.name)?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete Holding and Trades", role: .destructive) {
                do {
                    try Persistence.commit(context) { try LedgerService.delete(holding: holding, in: context) }
                    DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
                    dismiss()
                } catch {
                    saveError = error.localizedDescription
                }
            }
        } message: {
            Text("All \(trades.count) trade(s) and price history will be deleted. Cash movements recorded by these trades will be reversed on the funding accounts.")
        }
        .saveErrorAlert($saveError)
    }

    private func summary(_ position: PositionSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                IconBadge(symbol: holding.assetClass.symbol, color: Theme.color(named: holding.assetClass.colorName))
                VStack(alignment: .leading) {
                    Text(holding.name).font(.headline)
                    Text(holding.assetClass.singularTitle + (holding.symbol.isEmpty ? "" : " · \(holding.symbol)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            MoneyText(amount: position.marketValue, code: holding.currencyCode)
                .scaledFont(32)
            if let fraction = position.returnFraction {
                Text("\(MoneyFormat.string(position.unrealizedProfit, code: holding.currencyCode, showSign: true)) (\(MoneyFormat.percent(fraction, showSign: true)))")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.signColor(fraction)).monospacedDigit()
            }
            Group {
                if let updated = holding.priceUpdatedAt {
                    Text("Price \(MoneyFormat.string(holding.currentPrice, code: holding.currencyCode)) · manually updated \(updated.relativeDescription)")
                } else {
                    Text("Price not updated yet")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func tradeRow(_ trade: InvestmentTrade) -> some View {
        let account = trade.cashAccountID.flatMap { id in accounts.first { $0.id == id } }
        return HStack {
            Image(systemName: trade.kind == .buy ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                .foregroundStyle(trade.kind == .buy ? Theme.positive : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(trade.kind.title) \(MoneyFormat.quantity(trade.quantity)) @ \(MoneyFormat.string(trade.pricePerUnit, code: holding.currencyCode))")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                Text([trade.date.formatted(date: .abbreviated, time: .omitted),
                      account.map { "via \($0.name)" },
                      trade.fee > 0 ? "fee \(MoneyFormat.string(trade.fee, code: holding.currencyCode))" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(MoneyFormat.string(InvestmentCalculator.cashImpact(kind: trade.kind, quantity: trade.quantity,
                                                                    price: trade.pricePerUnit, fee: trade.fee),
                                    code: holding.currencyCode))
                .font(.subheadline).monospacedDigit()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct HoldingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    let holding: Holding?

    @State private var name: String
    @State private var symbol: String
    @State private var assetClass: AssetClass
    @State private var currencyCode: String
    @State private var priceText: String
    @State private var accountID: UUID?
    @State private var notes: String
    @State private var marketSymbol: String
    @State private var marketCurrency: String
    @State private var autoApply: Bool
    @State private var showSearch = false
    @State private var saveError: String?
    @Environment(MarketDataService.self) private var market
    @AppStorage(SettingsKey.marketDataEnabled) private var marketEnabled = false

    init(holding: Holding?) {
        self.holding = holding
        _name = State(initialValue: holding?.name ?? "")
        _symbol = State(initialValue: holding?.symbol ?? "")
        _assetClass = State(initialValue: holding?.assetClass ?? .etf)
        _currencyCode = State(initialValue: holding?.currencyCode ?? (UserDefaults.standard.string(forKey: SettingsKey.baseCurrency) ?? "EUR"))
        _priceText = State(initialValue: holding?.currentPrice.inputString ?? "")
        _accountID = State(initialValue: holding?.accountID)
        _notes = State(initialValue: holding?.notes ?? "")
        _marketSymbol = State(initialValue: holding?.marketSymbol ?? "")
        _marketCurrency = State(initialValue: holding?.marketCurrencyCode ?? "")
        _autoApply = State(initialValue: holding?.autoApplyMarketPrice ?? false)
    }

    private var provider: MarketProvider? {
        switch assetClass {
        case .crypto: .coinGecko
        case .etf, .stock, .other: .alphaVantage
        case .cash: nil
        }
    }

    private var trimmedMarketSymbol: String { marketSymbol.trimmingCharacters(in: .whitespaces) }

    private var marketSymbolValid: Bool {
        guard !trimmedMarketSymbol.isEmpty else { return true }
        return provider == .coinGecko ? QuoteValidator.isValidCoinID(trimmedMarketSymbol.lowercased())
                                      : QuoteValidator.isValidTicker(trimmedMarketSymbol)
    }

    private var priceValidation: AmountValidation { .price(priceText, allowZero: true) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. FTSE All-World)", text: $name)
                    TextField("Symbol / Ticker (optional)", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Picker("Asset Class", selection: $assetClass) {
                        ForEach(AssetClass.allCases) { Label($0.singularTitle, systemImage: $0.symbol).tag($0) }
                    }
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(Currencies.supported, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(holding != nil)
                }
                Section {
                    AmountField(title: "Current price", text: $priceText, currencyCode: currencyCode,
                                validation: priceText.isEmpty ? .empty : priceValidation, prompt: "0.00")
                } footer: {
                    Text("The price used to value this holding. Typing a price here keeps it as a manual price.")
                }
                if let provider {
                    Section {
                        HStack {
                            TextField(provider == .coinGecko ? "Coin ID, e.g. bitcoin" : "Ticker, e.g. VWCE.DEX", text: $marketSymbol)
                                .textInputAutocapitalization(provider == .coinGecko ? .never : .characters)
                                .autocorrectionDisabled()
                            if marketEnabled {
                                Button("Search") { showSearch = true }.buttonStyle(.borderless)
                            }
                        }
                        if !marketSymbolValid {
                            Text("This symbol contains unsupported characters.").font(.caption).foregroundStyle(Theme.negative)
                        }
                        if provider == .alphaVantage && !trimmedMarketSymbol.isEmpty {
                            Picker("Quoted in", selection: $marketCurrency) {
                                Text("\(currencyCode) (same as holding)").tag("")
                                Text("GBX (pence, London)").tag("GBX")
                                ForEach(Currencies.supported.filter { $0 != currencyCode }, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        if !trimmedMarketSymbol.isEmpty {
                            Toggle("Update price automatically", isOn: $autoApply)
                        }
                    } header: {
                        Text("Market Data (\(provider.displayName))")
                    } footer: {
                        Text(provider == .coinGecko
                             ? "Optional. CoinGecko coin ID used to fetch near real-time public prices."
                             : "Optional. Alpha Vantage symbol with exchange suffix, e.g. VWCE.DEX (XETRA), CSPX.LON (London). End-of-day prices on the free plan.")
                    }
                }
                Section {
                    Picker("Held in", selection: $accountID) {
                        Text("Not specified").tag(UUID?.none)
                        ForEach(accounts.filter { $0.kind.group == .investments }) { Text($0.name).tag(Optional($0.id)) }
                    }
                } footer: {
                    Text("Optional. Used as the default funding account for buys.")
                }
                Section { TextField("Notes (optional)", text: $notes, axis: .vertical) }
            }
            .navigationTitle(holding == nil ? "New Holding" : "Edit Holding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty || !marketSymbolValid || (!priceText.isEmpty && priceValidation.value == nil))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .saveErrorAlert($saveError)
            .sheet(isPresented: $showSearch) {
                if let provider {
                    SymbolSearchView(provider: provider, initialQuery: symbol.isEmpty ? name : symbol) { match in
                        marketSymbol = match.symbol
                        if provider == .alphaVantage, let currency = match.currency?.uppercased() {
                            marketCurrency = currency == currencyCode ? "" : (currency == "GBP" || currency == "GBX" || Currencies.supported.contains(currency) ? currency : "")
                        }
                        if symbol.isEmpty { symbol = provider == .coinGecko ? match.detail.components(separatedBy: " ").first ?? "" : match.symbol }
                    }
                }
            }
        }
    }

    /// A manually typed price always wins: it disables automatic market updates.
    private func applyMarketFields(to holding: Holding, manualPriceEntered: Bool) {
        let linked = provider == nil ? "" : trimmedMarketSymbol
        holding.marketSymbol = provider == .coinGecko ? linked.lowercased() : linked.uppercased()
        holding.marketCurrencyCode = provider == .alphaVantage && !linked.isEmpty ? marketCurrency : ""
        holding.autoApplyMarketPrice = !linked.isEmpty && autoApply && !manualPriceEntered
    }

    private func save() {
        let price = priceText.isEmpty ? Decimal(0) : (priceValidation.value ?? 0)
        do {
            try Persistence.commit(context) {
                if let holding {
                    let priceChanged = holding.currentPrice != price
                    holding.name = trimmedName
                    holding.symbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
                    holding.assetClass = assetClass
                    holding.accountID = accountID
                    holding.notes = notes
                    if priceChanged { try LedgerService.updatePrice(of: holding, to: price, in: context) }
                    applyMarketFields(to: holding, manualPriceEntered: priceChanged)
                } else {
                    let created = Holding(name: trimmedName, symbol: symbol.trimmingCharacters(in: .whitespaces).uppercased(),
                                          assetClass: assetClass, currencyCode: currencyCode, currentPrice: price,
                                          priceUpdatedAt: priceText.isEmpty ? nil : .now, accountID: accountID, notes: notes)
                    applyMarketFields(to: created, manualPriceEntered: false)
                    context.insert(created)
                    if !priceText.isEmpty { context.insert(PricePoint(holdingID: created.id, date: .now, price: price)) }
                }
            }
            DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct PriceUpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    let holding: Holding
    @State private var priceText = ""
    @State private var date = Date.now
    @State private var saved = false
    @State private var saveError: String?

    private var validation: AmountValidation { .price(priceText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Current", value: MoneyFormat.string(holding.currentPrice, code: holding.currencyCode))
                    AmountField(title: "New price", text: $priceText, currencyCode: holding.currencyCode,
                                validation: priceText.isEmpty ? .empty : validation)
                    DatePicker("As of", selection: $date, in: ...Date.now)
                } footer: {
                    Text("Look up the price from your broker or exchange and enter it here. The update time is shown throughout the app.")
                }
            }
            .navigationTitle("Update Price")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let price = validation.value else { return }
                        do {
                            try Persistence.commit(context) { try LedgerService.updatePrice(of: holding, to: price, date: date, in: context) }
                            DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
                            saved = true
                            dismiss()
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                    .disabled(validation.value == nil)
                }
            }
            .sensoryFeedback(.success, trigger: saved)
            .saveErrorAlert($saveError)
        }
        .presentationDetents([.medium])
    }
}
