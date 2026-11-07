import SwiftUI
import SwiftData

struct ExchangeRatesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \CurrencyRate.code) private var rates: [CurrencyRate]
    @Query private var accounts: [Account]
    @Query private var holdings: [Holding]
    @State private var editingCode: String?
    @State private var addCode = "USD"
    @Query private var quotes: [MarketQuote]

    private func marketQuote(_ code: String) -> MarketQuote? {
        quotes.first { $0.key == MarketQuote.key(provider: .frankfurter, symbol: code, currency: baseCurrency) }
    }

    private var usedCurrencies: [String] {
        Set(accounts.map(\.currencyCode) + holdings.map(\.currencyCode)).subtracting([baseCurrency]).sorted()
    }

    private var listedCodes: [String] {
        Set(usedCurrencies + rates.map(\.code)).subtracting([baseCurrency]).sorted()
    }

    var body: some View {
        List {
            Section {
                ForEach(listedCodes, id: \.self) { code in
                    let rate = rates.first { $0.code == code }
                    Button { editingCode = code } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("1 \(code) = \(rate.map { "\($0.rateToBase.formatted(.number.precision(.fractionLength(2...6)))) \(baseCurrency)" } ?? "Not set")")
                                    .font(.body.weight(.semibold))
                                Text(rate.map { "\($0.source == .market ? "Market" : "Manual") · updated \($0.updatedAt.relativeDescription)" } ?? "Required for balances in \(code)")
                                    .font(.caption).foregroundStyle(rate == nil ? Theme.warning : .secondary)
                                if let quote = marketQuote(code), quote.price != rate?.rateToBase {
                                    HStack(spacing: 8) {
                                        Text("Market: \(quote.price.formatted(.number.precision(.fractionLength(2...6)))) · \(QuoteFreshness.evaluate(latency: .dailyReference, fetchedAt: quote.fetchedAt, now: .now).title(for: .dailyReference))")
                                            .font(.caption).foregroundStyle(Theme.accent)
                                        Button("Use") {
                                            if MarketPriceApplier.applyRate(quote.value, baseCurrency: baseCurrency, rates: rates, context: context) {
                                                try? context.save()
                                                DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
                                            }
                                        }
                                        .font(.caption.weight(.semibold))
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "pencil").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if rate != nil && !usedCurrencies.contains(code) {
                            Button(role: .destructive) {
                                if let rate { context.delete(rate); try? context.save() }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                if listedCodes.isEmpty {
                    Text("All your accounts and holdings use \(baseCurrency). Add a rate if you plan to use another currency.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Rates to \(baseCurrency)")
            } footer: {
                Text("Enter rates manually, or turn on Market Data to download daily central-bank reference rates (Frankfurter). Market rates replace yours only when you tap “Use” or enable automatic exchange rates.")
            }
            Section("Add Currency") {
                Picker("Currency", selection: $addCode) {
                    ForEach(Currencies.supported.filter { $0 != baseCurrency && !listedCodes.contains($0) }, id: \.self) {
                        Text("\($0) – \(Currencies.name(for: $0))").tag($0)
                    }
                }
                Button("Set Rate…") { editingCode = addCode }
                    .disabled(addCode == baseCurrency || listedCodes.contains(addCode))
            }
        }
        .navigationTitle("Exchange Rates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .sheet(item: Binding(get: { editingCode.map(IdentifiedCode.init) }, set: { editingCode = $0?.id })) { item in
            RateEditorView(code: item.id, existing: rates.first { $0.code == item.id }?.rateToBase)
        }
        .onAppear {
            if let first = Currencies.supported.first(where: { $0 != baseCurrency && !listedCodes.contains($0) }) { addCode = first }
        }
    }
}

struct IdentifiedCode: Identifiable {
    let id: String
}

struct RateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    let code: String
    @State private var text: String

    init(code: String, existing: Decimal?) {
        self.code = code
        _text = State(initialValue: existing?.inputString ?? "")
    }

    private var validation: AmountValidation { .money(text, maxFractionDigits: 8) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(title: "1 \(code) in \(baseCurrency)", text: $text, currencyCode: baseCurrency,
                                validation: text.isEmpty ? .empty : validation, prompt: "0.0000")
                } footer: {
                    Text("Look up the current rate from your bank or a trusted source.")
                }
            }
            .navigationTitle("\(code) Rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let value = validation.value else { return }
                        try? LedgerService.setRate(value, for: code, in: context)
                        DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
                        dismiss()
                    }
                    .disabled(validation.value == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
