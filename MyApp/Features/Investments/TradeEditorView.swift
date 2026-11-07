import SwiftUI
import SwiftData

/// Records a buy or sell. A trade moves value between a cash account and a holding,
/// so it never counts as an expense or income and net worth only changes by fees
/// and by the difference between trade price and the current manual price.
struct TradeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var allTrades: [InvestmentTrade]
    @Query private var rates: [CurrencyRate]
    let holding: Holding
    let trade: InvestmentTrade?

    @State private var kind: TradeKind
    @State private var date: Date
    @State private var quantityText: String
    @State private var priceText: String
    @State private var feeText: String
    @State private var cashAccountID: UUID?
    @State private var cashAmountText: String
    @State private var cashAmountEdited = false
    @State private var note: String
    @State private var showDelete = false

    init(holding: Holding, kind: TradeKind, trade: InvestmentTrade?) {
        self.holding = holding
        self.trade = trade
        _kind = State(initialValue: trade?.kind ?? kind)
        _date = State(initialValue: trade?.date ?? .now)
        _quantityText = State(initialValue: trade?.quantity.inputString ?? "")
        _priceText = State(initialValue: (trade?.pricePerUnit ?? (holding.currentPrice > 0 ? holding.currentPrice : nil))?.inputString ?? "")
        _feeText = State(initialValue: trade.map { $0.fee == 0 ? "" : $0.fee.inputString } ?? "")
        _cashAccountID = State(initialValue: trade == nil ? holding.accountID : trade?.cashAccountID)
        _cashAmountText = State(initialValue: trade?.cashAmount?.inputString ?? "")
        _cashAmountEdited = State(initialValue: trade?.cashAmount != nil)
        _note = State(initialValue: trade?.note ?? "")
    }

    private var quantity: AmountValidation { .quantity(quantityText) }
    private var price: AmountValidation { .price(priceText) }
    private var fee: AmountValidation { feeText.isEmpty ? .valid(0) : .money(feeText, allowZero: true) }
    private var cashAccount: Account? { accounts.first { $0.id == cashAccountID } }
    private var grossImpact: Decimal? {
        guard let q = quantity.value, let p = price.value, let f = fee.value else { return nil }
        return InvestmentCalculator.cashImpact(kind: kind, quantity: q, price: p, fee: f)
    }
    private var cashValidation: AmountValidation { .money(cashAmountText, allowZero: true) }

    /// Re-runs the position with this trade included to reject overselling at any date.
    private var positionError: String? {
        guard let q = quantity.value, let p = price.value, let f = fee.value else { return nil }
        var inputs = allTrades.filter { $0.holdingID == holding.id && $0.id != trade?.id }.map {
            TradeInput(kind: $0.kind, date: $0.date, quantity: $0.quantity, price: $0.pricePerUnit, fee: $0.fee, createdAt: $0.createdAt)
        }
        inputs.append(TradeInput(kind: kind, date: date, quantity: q, price: p, fee: f, createdAt: trade?.createdAt ?? .now))
        do { _ = try InvestmentCalculator.position(for: inputs); return nil } catch { return error.localizedDescription }
    }

    private var validationMessage: String? {
        if quantity.value == nil { return quantity.message ?? "Enter a quantity." }
        if price.value == nil { return price.message ?? "Enter a price." }
        if fee.value == nil { return fee.message }
        if let positionError { return positionError }
        if cashAccount != nil && cashValidation.value == nil { return "Enter the amount moved on the cash account." }
        if let impact = grossImpact, impact < 0 { return "Fee exceeds the sale proceeds." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(TradeKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                }
                Section {
                    AmountField(title: "Quantity", text: $quantityText, validation: quantityText.isEmpty ? .empty : quantity, prompt: "0")
                    AmountField(title: "Price per unit", text: $priceText, currencyCode: holding.currencyCode,
                                validation: priceText.isEmpty ? .empty : price)
                    AmountField(title: "Fee", text: $feeText, currencyCode: holding.currencyCode, validation: fee)
                    if let impact = grossImpact {
                        LabeledContent(kind == .buy ? "Total cost" : "Net proceeds",
                                       value: MoneyFormat.string(impact, code: holding.currencyCode))
                    }
                }
                Section {
                    Picker(kind == .buy ? "Paid from" : "Proceeds to", selection: $cashAccountID) {
                        Text("No cash account").tag(UUID?.none)
                        ForEach(accounts.filter { !$0.isArchived && !$0.kind.isLiability }) {
                            Text("\($0.name) (\($0.currencyCode))").tag(Optional($0.id))
                        }
                    }
                    if let cashAccount {
                        AmountField(title: kind == .buy ? "Debited" : "Credited", text: $cashAmountText,
                                    currencyCode: cashAccount.currencyCode,
                                    validation: cashAmountText.isEmpty ? .empty : cashValidation)
                    }
                } footer: {
                    Text(cashAccount == nil
                         ? "Without a cash account the position is treated as already owned or funded externally, so its value is added to net worth. Pick the account you paid from to avoid double counting."
                         : "The cash account changes by this amount. Buying an investment is not an expense.")
                }
                Section { TextField("Note (optional)", text: $note) }
                if trade != nil {
                    Section { Button("Delete Trade", role: .destructive) { showDelete = true } }
                }
            }
            .navigationTitle(trade == nil ? "\(kind.title) \(holding.symbol.isEmpty ? holding.name : holding.symbol)" : "Edit Trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(validationMessage != nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let message = validationMessage, !quantityText.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(8).frame(maxWidth: .infinity).background(.bar)
                }
            }
            .onChange(of: grossImpact) { _, _ in suggestCashAmount() }
            .onChange(of: cashAccountID) { _, _ in cashAmountEdited = false; suggestCashAmount() }
            .onChange(of: cashAmountText) { _, newValue in
                if let suggested = suggestedCashAmount(), newValue != suggested.inputString { cashAmountEdited = true }
            }
            .onAppear { suggestCashAmount() }
            .confirmationDialog("Delete this trade?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let trade { context.delete(trade); try? context.save() }
                    DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
                    dismiss()
                }
            } message: {
                Text("The position and the linked cash account balance will be recalculated.")
            }
        }
    }

    private func suggestedCashAmount() -> Decimal? {
        guard let impact = grossImpact, let cashAccount else { return nil }
        let converter = CurrencyConverter.make(base: baseCurrency, rates: rates)
        return converter.convert(impact, from: holding.currencyCode, to: cashAccount.currencyCode).map { Money.round($0) }
    }

    private func suggestCashAmount() {
        guard !cashAmountEdited, let suggested = suggestedCashAmount() else { return }
        cashAmountText = suggested.inputString
    }

    private func save() {
        guard validationMessage == nil, let q = quantity.value, let p = price.value, let f = fee.value else { return }
        let cashAmount = cashAccount == nil ? nil : cashValidation.value
        if let trade {
            trade.kind = kind
            trade.date = date
            trade.quantity = q
            trade.pricePerUnit = p
            trade.fee = f
            trade.cashAccountID = cashAccountID
            trade.cashAmount = cashAmount
            trade.note = note
        } else {
            context.insert(InvestmentTrade(holdingID: holding.id, kind: kind, date: date, quantity: q, pricePerUnit: p, fee: f,
                                           cashAccountID: cashAccountID, cashAmount: cashAmount, note: note))
            if holding.priceUpdatedAt == nil || holding.currentPrice == 0 {
                try? LedgerService.updatePrice(of: holding, to: p, date: date, in: context)
            }
        }
        try? context.save()
        DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
        dismiss()
    }
}
