import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import MyApp

@Suite("Appearance preference")
struct AppearanceTests {
    @Test func preferenceMapsToColorScheme() {
        #expect(AppearanceMode.system.colorScheme == nil)
        #expect(AppearanceMode.light.colorScheme == .light)
        #expect(AppearanceMode.dark.colorScheme == .dark)
        // Window-level override used so open sheets update and System really follows iOS.
        #expect(AppearanceMode.system.interfaceStyle == .unspecified)
        #expect(AppearanceMode.light.interfaceStyle == .light)
        #expect(AppearanceMode.dark.interfaceStyle == .dark)
    }

    @Test func storedValuesResolveAndDefaultToDark() {
        #expect(AppearanceMode.resolve("light") == .light)
        #expect(AppearanceMode.resolve("system") == .system)
        #expect(AppearanceMode.resolve("") == .dark)
        #expect(AppearanceMode.resolve("unknown") == .dark)
    }
}

/// User-initiated price/valuation changes must never look saved when saving failed.
@MainActor
@Suite("Save failure feedback")
struct SaveFeedbackTests {
    struct SimulatedSaveError: Error {}

    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_794_050_000)

    init() throws { container = try Persistence.makeInMemoryContainer() }

    private func makeHolding() throws -> Holding {
        let holding = Holding(name: "ETF", symbol: "VWCE", assetClass: .etf, currencyCode: "EUR", currentPrice: 100,
                              priceUpdatedAt: now.addingTimeInterval(-86_400), marketSymbol: "VWCE.DEX")
        context.insert(holding)
        try context.save()
        return holding
    }

    @Test func successfulCommitPersists() throws {
        let holding = try makeHolding()
        try Persistence.commit(context) { try LedgerService.updatePrice(of: holding, to: 110, in: context) }
        #expect(holding.currentPrice == 110)
        #expect(!context.hasChanges)
    }

    @Test func failedSaveOfMarketPriceRollsBackAndReportsError() throws {
        let holding = try makeHolding()
        let quote = QuoteValue(provider: .alphaVantage, symbol: "VWCE.DEX", currency: "EUR", price: 130, quoteTime: now, fetchedAt: now)
        #expect(MarketPriceApplier.apply(quote, to: holding, converter: CurrencyConverter(baseCode: "EUR"), context: context))
        #expect(holding.currentPrice == 130)

        #expect(throws: PersistenceError.saveFailed) {
            try Persistence.commit(context, save: { _ in throw SimulatedSaveError() })
        }
        // The UI must not keep showing the unsaved market price.
        #expect(holding.currentPrice == 100)
        #expect(holding.priceSource == .manual)
        #expect(try context.fetchCount(FetchDescriptor<PricePoint>()) == 0)
        #expect(!context.hasChanges)
    }

    @Test func failedSaveOfExchangeRateRollsBack() throws {
        context.insert(CurrencyRate(code: "USD", rateToBase: Decimal(string: "0.9")!))
        try context.save()
        let quote = QuoteValue(provider: .frankfurter, symbol: "USD", currency: "EUR", price: Decimal(string: "0.8")!,
                               quoteTime: now, fetchedAt: now)
        let rates = try context.fetch(FetchDescriptor<CurrencyRate>())
        #expect(MarketPriceApplier.applyRate(quote, baseCurrency: "EUR", rates: rates, context: context))
        #expect(throws: PersistenceError.saveFailed) {
            try Persistence.commit(context, save: { _ in throw SimulatedSaveError() })
        }
        let rate = try #require(try context.fetch(FetchDescriptor<CurrencyRate>()).first)
        #expect(rate.rateToBase == Decimal(string: "0.9"))
        #expect(rate.source == .manual)
    }

    @Test func failingChangeRollsBackEarlierEditsInTheSameAction() throws {
        let holding = try makeHolding()
        #expect(throws: PersistenceError.saveFailed) {
            try Persistence.commit(context) {
                holding.autoApplyMarketPrice = true
                context.insert(InvestmentTrade(holdingID: holding.id, kind: .buy, date: now, quantity: 1, pricePerUnit: 100))
                throw SimulatedSaveError()
            }
        }
        #expect(!holding.autoApplyMarketPrice)
        #expect(try context.fetchCount(FetchDescriptor<InvestmentTrade>()) == 0)
    }

    @Test func saveFailureMessageIsUserFacing() {
        let message = PersistenceError.saveFailed.localizedDescription
        #expect(message.contains("couldn't be saved"))
        #expect(!message.contains("NSCocoaErrorDomain"))
    }
}
