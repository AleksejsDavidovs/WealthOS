import SwiftUI
import SwiftData

/// Catalog-first way to add an investment: search provider listings, pick the exact
/// exchange and currency, then record a purchase made elsewhere. No broker connection,
/// no orders — prices and listings only come from the provider or are entered by the user.
struct AssetDiscoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MarketDataService.self) private var market
    @AppStorage(SettingsKey.marketDataEnabled) private var enabled = false
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query private var quotes: [MarketQuote]

    @State private var filter: DiscoveryFilter = .etfs
    @State private var query = ""
    @State private var submitToken = 0
    @State private var lastSubmitToken = 0
    @State private var results: [CatalogAsset] = []
    @State private var isSearching = false
    @State private var message: String?
    @State private var selected: CatalogAsset?
    @State private var recents: [CatalogAsset] = []
    @State private var showManual = false
    @State private var showMarketSettings = false

    private struct SearchKey: Hashable {
        let query: String
        let filter: DiscoveryFilter
        let token: Int
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Asset type", selection: $filter) {
                        ForEach(DiscoveryFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                statusSection

                if trimmedQuery.isEmpty {
                    recentSection
                    popularSection
                } else {
                    resultsSection
                }

                Section {
                    Button { showManual = true } label: {
                        Label("Add Manually", systemImage: "square.and.pencil")
                    }
                } footer: {
                    Text("For assets the catalog doesn't cover, or if you prefer to enter everything yourself.")
                }
            }
            .navigationTitle("Add Investment")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: filter == .crypto ? "Coin name or symbol" : "Name, ticker or ISIN")
            .autocorrectionDisabled()
            .onSubmit(of: .search) { submitToken += 1 }
            .task(id: SearchKey(query: trimmedQuery, filter: filter, token: submitToken)) { await search() }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(item: $selected) { asset in
                AddAssetView(asset: asset) { dismiss() }
            }
            .sheet(isPresented: $showManual) { HoldingEditorView(holding: nil) }
            .sheet(isPresented: $showMarketSettings) { NavigationStack { MarketDataSettingsView() } }
            .onAppear { recents = RecentAssetsStore(defaults: .standard).load() }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var statusSection: some View {
        if !enabled {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Search needs Market Data").font(.subheadline.weight(.semibold))
                        Text("Turn on online market prices to search listings. Popular assets and manual entry work offline.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "network.slash").foregroundStyle(Theme.warning) }
                Button("Open Market Data Settings") { showMarketSettings = true }
            }
        } else if filter != .crypto && !market.hasKey(.alphaVantage) {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add a free Alpha Vantage key").font(.subheadline.weight(.semibold))
                        Text("Needed to search stocks and ETFs and to load their prices.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "key.fill").foregroundStyle(Theme.warning) }
                Button("Open Market Data Settings") { showMarketSettings = true }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        let items = recents.filter(filter.includes)
        if !items.isEmpty {
            Section("Recent") {
                ForEach(items) { asset in row(asset) }
            }
        }
    }

    @ViewBuilder
    private var popularSection: some View {
        switch filter {
        case .stocks:
            Section {
                ForEach(PopularAssets.stocks) { asset in row(asset) }
            } header: { Text("Popular") } footer: {
                Text("US listings in USD. Search for a company to see other exchanges.")
            }
        case .crypto:
            Section("Popular") {
                ForEach(PopularAssets.crypto) { asset in row(asset) }
            }
        case .etfs:
            Section {
                ForEach(PopularAssets.etfs) { shortcut in
                    Button { query = shortcut.query; submitToken += 1 } label: {
                        HStack(spacing: 12) {
                            IconBadge(symbol: AssetClass.etf.symbol, color: Theme.color(named: AssetClass.etf.colorName))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(shortcut.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("ISIN \(shortcut.isin)").font(.caption).foregroundStyle(.secondary).monospaced()
                            }
                            Spacer(minLength: 8)
                            Text("Listings").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text("Popular UCITS ETFs") } footer: {
                Text("Tap to load the exchanges and currencies this fund trades on, then pick the listing you bought.")
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        Section {
            if isSearching {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Searching \(filter.provider.displayName)…").foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(results) { asset in row(asset) }
        } header: {
            Text("Listings")
        } footer: {
            if filter != .crypto {
                let remaining = market.remainingToday(.alphaVantage).map { " · \($0) of 25 searches left today" } ?? ""
                Text("Choose the exact listing you bought — the exchange and trading currency matter for UCITS ETFs. Results are cached for 24 hours\(remaining).")
            }
        }
    }

    private func row(_ asset: CatalogAsset) -> some View {
        Button { selected = asset } label: {
            CatalogAssetRow(asset: asset,
                            quote: quotes.first { $0.key == MarketDataService.quoteKey(for: asset, currency: baseCurrency) })
        }
        .buttonStyle(.plain)
    }

    // MARK: Search

    /// Debounced: crypto after 0.5 s, stocks/ETFs after 1.2 s (they spend daily quota), or
    /// immediately when the user presses Search. Cached results never hit the network.
    private func search() async {
        let text = trimmedQuery
        let submitted = submitToken != lastSubmitToken
        lastSubmitToken = submitToken
        message = nil
        guard !text.isEmpty else { results = []; return }
        guard enabled else {
            results = []
            message = "Turn on Market Data to search, or add the asset manually."
            return
        }
        let minimum = MarketDataService.minimumQueryLength(for: filter.provider)
        let isISIN = filter != .crypto && ISIN.isValid(text)
        guard isISIN || text.count >= minimum else {
            results = []
            message = "Type at least \(minimum) characters."
            return
        }
        if !submitted {
            try? await Task.sleep(for: .milliseconds(filter == .crypto ? 500 : 1_200))
            guard !Task.isCancelled else { return }
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await market.searchCatalog(text, filter: filter)
            guard !Task.isCancelled else { return }
            results = found
            if found.isEmpty { message = "No \(filter.title.lowercased()) found for “\(text)”." }
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            message = (error as? CatalogError)?.localizedDescription ?? MarketDataError.from(error).localizedDescription
        }
    }
}

struct CatalogAssetRow: View {
    let asset: CatalogAsset
    let quote: MarketQuote?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: asset.assetClass.symbol, color: Theme.color(named: asset.assetClass.colorName))
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text([asset.ticker, asset.exchangeName, asset.currency].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let quote {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(MoneyFormat.string(quote.price, code: quote.currencyCode))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text(QuoteFreshness.evaluate(latency: asset.provider.latency, fetchedAt: quote.fetchedAt, now: .now)
                        .title(for: asset.provider.latency))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Add asset

struct AddAssetView: View {
    enum EntryMode: String, CaseIterable, Identifiable {
        case amount = "Amount", quantity = "Quantity"
        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var context
    @Environment(MarketDataService.self) private var market
    @AppStorage(SettingsKey.marketDataEnabled) private var enabled = false
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [CurrencyRate]

    let asset: CatalogAsset
    let onDone: () -> Void

    @State private var mode: EntryMode = .amount
    @State private var amountText = ""
    @State private var quantityText = ""
    @State private var priceText = ""
    @State private var feeText = ""
    @State private var date = Date.now
    @State private var holdingCurrency: String
    @State private var cashAccountID: UUID?
    @State private var cashAmountText = ""
    @State private var cashAmountEdited = false
    @State private var autoUpdate = true
    @State private var quote: QuoteValue?
    @State private var quoteMessage: String?
    @State private var loadingQuote = false
    @State private var existing: Holding?
    @State private var saveError: String?
    @State private var saved = false

    init(asset: CatalogAsset, onDone: @escaping () -> Void) {
        self.asset = asset
        self.onDone = onDone
        let base = UserDefaults.standard.string(forKey: SettingsKey.baseCurrency) ?? "EUR"
        _holdingCurrency = State(initialValue: asset.holdingCurrency ?? base)
    }

    private var converter: CurrencyConverter { .make(base: baseCurrency, rates: rates) }

    /// Market price expressed in the holding currency, if a quote and needed FX rate exist.
    private var marketPrice: Decimal? {
        quote.flatMap { MarketPriceApplier.price(of: $0, in: holdingCurrency, converter: converter) }.map { Money.round($0, scale: 4) }
    }

    private var currencyOptions: [String] {
        var options = Currencies.supported
        if let listing = asset.holdingCurrency, !options.contains(listing) { options.insert(listing, at: 0) }
        return options
    }

    private var calculation: Result<PurchaseCalculation, Error> {
        guard let price = AmountValidation.price(priceText).value else { return .failure(PurchaseError.invalidPrice) }
        let fee = feeText.isEmpty ? Decimal(0) : (AmountValidation.money(feeText, allowZero: true).value ?? -1)
        guard fee >= 0 else { return .failure(PurchaseError.feeExceedsAmount) }
        do {
            switch mode {
            case .amount:
                guard let amount = AmountValidation.money(amountText).value else { return .failure(PurchaseError.invalidAmount) }
                return .success(try PurchaseCalculator.fromAmount(amount, price: price, fee: fee))
            case .quantity:
                guard let quantity = AmountValidation.quantity(quantityText).value else { return .failure(PurchaseError.quantityTooSmall) }
                return .success(try PurchaseCalculator.fromQuantity(quantity, price: price, fee: fee))
            }
        } catch {
            return .failure(error)
        }
    }

    private var cashAccount: Account? { accounts.first { $0.id == cashAccountID } }

    var body: some View {
        Form {
            header
            if existing != nil {
                Section {
                    InfoBanner(text: "You already track this listing. The purchase will be added to your existing position.",
                               symbol: "plus.square.on.square", tint: .blue)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            listingSection
            purchaseSection
            fundingSection
            if existing == nil && enabled {
                Section {
                    Toggle("Keep price updated from market", isOn: $autoUpdate)
                } footer: {
                    Text("Refreshes the valuation price from \(asset.provider.displayName). Entering a price manually later turns this off.")
                }
            }
            Section {
            } footer: {
                Text("WealthOS doesn't connect to any broker and never places orders. This records a purchase you made elsewhere, so cost basis and profit are tracked on this iPhone.")
            }
        }
        .navigationTitle(asset.ticker)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add", action: save).disabled((try? calculation.get()) == nil || cashAmountInvalid)
            }
            // Decimal pads have no return key; give an explicit way to dismiss the keyboard.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .task { await prepare() }
        .onChange(of: holdingCurrency) { _, _ in
            if asset.provider == .coinGecko { Task { await loadQuote() } }
            suggestCashAmount()
        }
        .onChange(of: cashAccountID) { _, _ in cashAmountEdited = false; suggestCashAmount() }
        .onChange(of: amountText) { _, _ in suggestCashAmount() }
        .onChange(of: quantityText) { _, _ in suggestCashAmount() }
        .onChange(of: priceText) { _, _ in suggestCashAmount() }
        .onChange(of: feeText) { _, _ in suggestCashAmount() }
        .onChange(of: mode) { _, _ in suggestCashAmount() }
        .onChange(of: cashAmountText) { _, newValue in
            if let suggested = suggestedCashAmount, newValue != suggested.inputString { cashAmountEdited = true }
        }
        .alert("Couldn't Add", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(saveError ?? "") }
        .sensoryFeedback(.success, trigger: saved)
    }

    // MARK: Sections

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(symbol: asset.assetClass.symbol, color: Theme.color(named: asset.assetClass.colorName), size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text([asset.ticker, asset.assetClass.singularTitle, asset.exchangeName].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let isin = asset.isin {
                        Text("ISIN \(isin)").font(.caption).foregroundStyle(.secondary).monospaced()
                    }
                }
            }
            .padding(.vertical, 4)
            priceRow
        }
    }

    @ViewBuilder
    private var priceRow: some View {
        if loadingQuote {
            HStack { Text("Market price"); Spacer(); ProgressView() }
        } else if let quote, let price = marketPrice {
            LabeledContent("Market price") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(MoneyFormat.string(price, code: holdingCurrency, fractionDigits: price < 10 ? 4 : 2))
                        .font(.body.weight(.semibold)).monospacedDigit()
                    Text("\(QuoteFreshness.evaluate(latency: asset.provider.latency, fetchedAt: quote.fetchedAt, now: .now).title(for: asset.provider.latency)) · \(asset.provider.displayName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if quote != nil {
            LabeledContent("Market price", value: "Needs a \(quote?.currency ?? "")→\(holdingCurrency) exchange rate")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("No market price available").font(.subheadline)
                Text(quoteMessage ?? "Enter the price you paid below.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var listingSection: some View {
        Section {
            LabeledContent("Exchange", value: asset.exchangeName ?? (asset.provider == .coinGecko ? "Crypto market" : "—"))
            if let currency = asset.currency {
                LabeledContent("Listing currency", value: currency == "GBX" ? "GBX (pence) → valued in GBP" : currency)
            }
            Picker("Your trading currency", selection: $holdingCurrency) {
                ForEach(currencyOptions, id: \.self) { Text($0).tag($0) }
            }
            .disabled(existing != nil)
        } header: {
            Text("Listing")
        } footer: {
            Text(asset.provider == .coinGecko
                 ? "The currency you bought in. Prices are requested in this currency."
                 : "Use the currency of the listing you bought. If you choose another one, prices are converted with your exchange rates.")
        }
    }

    private var purchaseSection: some View {
        Section {
            Picker("Entry", selection: $mode) {
                ForEach(EntryMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if mode == .amount {
                AmountField(title: "Amount invested", text: $amountText, currencyCode: holdingCurrency,
                            validation: amountText.isEmpty ? .empty : .money(amountText))
            } else {
                AmountField(title: "Quantity", text: $quantityText,
                            validation: quantityText.isEmpty ? .empty : .quantity(quantityText), prompt: "0")
            }
            AmountField(title: "Price per unit", text: $priceText, currencyCode: holdingCurrency,
                        validation: priceText.isEmpty ? .empty : .price(priceText))
            if let price = marketPrice, AmountValidation.price(priceText).value != price {
                Button("Use market price \(MoneyFormat.string(price, code: holdingCurrency, fractionDigits: price < 10 ? 4 : 2))") {
                    priceText = price.inputString
                }
                .font(.subheadline)
            }
            AmountField(title: "Fee", text: $feeText, currencyCode: holdingCurrency,
                        validation: feeText.isEmpty ? .empty : .money(feeText, allowZero: true))
            DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
            switch calculation {
            case .success(let result):
                if mode == .amount {
                    LabeledContent("Quantity", value: MoneyFormat.quantity(result.quantity))
                }
                LabeledContent("Total cost", value: MoneyFormat.string(result.totalCost, code: holdingCurrency))
            case .failure(let error):
                if !priceText.isEmpty && (!amountText.isEmpty || !quantityText.isEmpty) {
                    Text(error.localizedDescription).font(.caption).foregroundStyle(Theme.negative)
                }
            }
        } header: {
            Text("Purchase")
        } footer: {
            Text(mode == .amount
                 ? "Quantity = (amount − fee) ÷ price, rounded down to 8 decimals so the recorded cost never exceeds what you invested."
                 : "Enter the exact number of units and the price you paid.")
        }
    }

    private var fundingSection: some View {
        Section {
            Picker("Paid from", selection: $cashAccountID) {
                Text("Not tracked").tag(UUID?.none)
                ForEach(accounts.filter { !$0.isArchived && !$0.kind.isLiability }) {
                    Text("\($0.name) (\($0.currencyCode))").tag(Optional($0.id))
                }
            }
            if let cashAccount {
                AmountField(title: "Debited", text: $cashAmountText, currencyCode: cashAccount.currencyCode,
                            validation: cashAmountText.isEmpty ? .empty : .money(cashAmountText))
            }
        } footer: {
            Text(cashAccount == nil
                 ? "Choose the account that paid for this so cash isn't counted twice. Without it, the position adds to your net worth as an asset you already owned."
                 : "This account's balance decreases by the debited amount. Buying an investment isn't an expense.")
        }
    }

    private var cashAmountInvalid: Bool {
        cashAccount != nil && AmountValidation.money(cashAmountText).value == nil
    }

    // MARK: Actions

    private func prepare() async {
        existing = AssetPurchaseService.existingHolding(for: asset, in: context)
        if let existing { holdingCurrency = existing.currencyCode; autoUpdate = existing.autoApplyMarketPrice }
        if cashAccountID == nil { cashAccountID = existing?.accountID }
        await loadQuote()
    }

    private func loadQuote() async {
        guard enabled else {
            quoteMessage = "Market Data is off. Enter the price you paid."
            return
        }
        loadingQuote = true
        defer { loadingQuote = false }
        do {
            quote = try await market.quote(for: asset, currency: holdingCurrency, context: context)
            quoteMessage = nil
            if priceText.isEmpty, let price = marketPrice { priceText = price.inputString }
        } catch {
            quote = nil
            quoteMessage = MarketDataError.from(error).localizedDescription
        }
    }

    private var suggestedCashAmount: Decimal? {
        guard let cashAccount, let result = try? calculation.get() else { return nil }
        return converter.convert(result.totalCost, from: holdingCurrency, to: cashAccount.currencyCode).map { Money.round($0) }
    }

    private func suggestCashAmount() {
        guard !cashAmountEdited, let suggested = suggestedCashAmount else { return }
        cashAmountText = suggested.inputString
    }

    private func save() {
        guard let result = try? calculation.get() else { return }
        let purchase = AssetPurchase(asset: asset, holdingCurrency: holdingCurrency, calculation: result, date: date,
                                     cashAccountID: cashAccountID,
                                     cashAmount: cashAccount == nil ? nil : AmountValidation.money(cashAmountText).value,
                                     marketQuote: quote, autoUpdatePrice: enabled && autoUpdate)
        do {
            try AssetPurchaseService.record(purchase, converter: converter, context: context)
            RecentAssetsStore(defaults: .standard).record(asset)
            DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
            saved = true
            onDone()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
