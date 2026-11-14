import Foundation
import SwiftData

/// A purchase the user already made at their broker, recorded locally. No order is placed.
struct AssetPurchase {
    var asset: CatalogAsset
    /// Currency the holding is valued and the purchase price is entered in.
    var holdingCurrency: String
    var calculation: PurchaseCalculation
    var date: Date
    var cashAccountID: UUID?
    /// Amount debited from the cash account, in that account's currency.
    var cashAmount: Decimal?
    /// Latest provider quote, used as the current valuation price for a new holding.
    var marketQuote: QuoteValue?
    var autoUpdatePrice: Bool
    var note: String = ""
}

enum AssetPurchaseService {
    /// The holding already tracking this listing, if any (matched by provider symbol).
    static func existingHolding(for asset: CatalogAsset, in context: ModelContext) -> Holding? {
        let holdings = (try? context.fetch(FetchDescriptor<Holding>())) ?? []
        return holdings.first { holding in
            holding.marketProvider == asset.provider
                && holding.marketSymbol.caseInsensitiveCompare(asset.symbol) == .orderedSame
        }
    }

    /// Records a buy as an investment trade. Creates the holding on first purchase; later
    /// purchases of the same listing are added to it, so cost basis stays in one position.
    /// Transactions are never created: buying an investment isn't an expense.
    @discardableResult
    static func record(_ purchase: AssetPurchase, converter: CurrencyConverter, context: ModelContext) throws -> Holding {
        let calculation = purchase.calculation
        guard calculation.quantity > 0, calculation.pricePerUnit > 0, calculation.fee >= 0 else {
            throw PurchaseError.invalidPrice
        }
        let asset = purchase.asset
        let holding: Holding
        if let existing = existingHolding(for: asset, in: context) {
            holding = existing
        } else {
            let listingCurrency = asset.currency?.uppercased() ?? ""
            let marketCurrency = asset.provider == .alphaVantage && !listingCurrency.isEmpty
                && listingCurrency != purchase.holdingCurrency.uppercased() ? listingCurrency : ""
            holding = Holding(name: asset.name, symbol: asset.ticker, assetClass: asset.assetClass,
                              currencyCode: purchase.holdingCurrency, currentPrice: calculation.pricePerUnit,
                              priceUpdatedAt: purchase.date,
                              marketSymbol: asset.provider == .coinGecko ? asset.symbol.lowercased() : asset.symbol.uppercased(),
                              marketCurrencyCode: marketCurrency, priceSource: .manual,
                              autoApplyMarketPrice: purchase.autoUpdatePrice)
            if let isin = asset.isin { holding.notes = "ISIN \(isin)" }
            context.insert(holding)
            context.insert(PricePoint(holdingID: holding.id, date: purchase.date, price: calculation.pricePerUnit))
            // Value the new position at the latest market price when one is available.
            if let quote = purchase.marketQuote {
                MarketPriceApplier.apply(quote, to: holding, converter: converter, context: context)
            }
        }
        context.insert(InvestmentTrade(holdingID: holding.id, kind: .buy, date: purchase.date,
                                       quantity: calculation.quantity, pricePerUnit: calculation.pricePerUnit,
                                       fee: calculation.fee, cashAccountID: purchase.cashAccountID,
                                       cashAmount: purchase.cashAccountID == nil ? nil : purchase.cashAmount,
                                       note: purchase.note))
        try context.save()
        return holding
    }
}
