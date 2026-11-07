import Foundation
import SwiftData
import SwiftUI
import os

enum AppTab: Hashable {
    case home, transactions, investments, simulator, goals
}

/// Owns the model containers. The real store and the demo store are fully separate:
/// demo data lives only in memory and can never be written into the user's database.
@Observable
final class AppModel {
    let persistentContainer: ModelContainer?
    let loadError: String?
    private(set) var demoContainer: ModelContainer?
    var selectedTab: AppTab = .home

    init() {
        do {
            persistentContainer = try Persistence.makePersistentContainer()
            loadError = nil
        } catch {
            Persistence.logger.error("Failed to open the data store.")
            persistentContainer = nil
            loadError = "WealthOS couldn't open its data store. Your data has not been modified. Restart the app; if the problem persists, restore from a backup."
        }
        #if DEBUG
        // Development aid only (stripped from Release): `-UIDemoTab <home|transactions|investments|simulator|goals>`
        // launches straight into the in-memory demo store for visual checks.
        // `-UITab <name>` selects a tab without demo data (e.g. to inspect empty states).
        let arguments = ProcessInfo.processInfo.arguments
        let demoIndex = arguments.firstIndex(of: "-UIDemoTab")
        let tabIndex = demoIndex ?? arguments.firstIndex(of: "-UITab")
        if let index = tabIndex, index + 1 < arguments.count {
            if demoIndex != nil { enterDemoMode() }
            switch arguments[index + 1] {
            case "transactions": selectedTab = .transactions
            case "investments": selectedTab = .investments
            case "simulator": selectedTab = .simulator
            case "goals": selectedTab = .goals
            default: selectedTab = .home
            }
        }
        #endif
    }

    /// In-memory container for previews and tests.
    init(inMemory: Bool) {
        persistentContainer = try? Persistence.makeInMemoryContainer()
        loadError = nil
    }

    var isDemoMode: Bool { demoContainer != nil }
    var activeContainer: ModelContainer? { demoContainer ?? persistentContainer }

    func enterDemoMode() {
        guard let container = try? Persistence.makeInMemoryContainer() else { return }
        DemoDataFactory.populate(container.mainContext)
        selectedTab = .home
        demoContainer = container
    }

    func exitDemoMode() {
        selectedTab = .home
        demoContainer = nil
    }
}

enum DataMaintenance {
    static func makeEngine(context: ModelContext, baseCurrency: String) -> FinanceEngine {
        let rates = (try? context.fetch(FetchDescriptor<CurrencyRate>())) ?? []
        return FinanceEngine(accounts: (try? context.fetch(FetchDescriptor<Account>())) ?? [],
                             transactions: (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? [],
                             holdings: (try? context.fetch(FetchDescriptor<Holding>())) ?? [],
                             trades: (try? context.fetch(FetchDescriptor<InvestmentTrade>())) ?? [],
                             converter: CurrencyConverter.make(base: baseCurrency, rates: rates))
    }

    /// Launch / foreground housekeeping: default categories, due recurring transactions,
    /// and today's automatic net worth snapshot.
    static func run(context: ModelContext, baseCurrency: String) {
        LedgerService.seedDefaultCategoriesIfNeeded(in: context)
        RecurringService.processDueRules(in: context)
        refreshSnapshot(context: context, baseCurrency: baseCurrency)
    }

    static func refreshSnapshot(context: ModelContext, baseCurrency: String) {
        let engine = makeEngine(context: context, baseCurrency: baseCurrency)
        SnapshotService.recordAutomaticSnapshot(summary: engine.summary, currencyCode: baseCurrency,
                                                hasData: !engine.accounts.isEmpty || !engine.holdings.isEmpty,
                                                in: context)
    }
}

extension CurrencyConverter {
    static func make(base: String, rates: [CurrencyRate]) -> CurrencyConverter {
        CurrencyConverter(baseCode: base, rates: Dictionary(rates.map { ($0.code, $0.rateToBase) }, uniquingKeysWith: { a, _ in a }))
    }
}

/// Supplies a `FinanceEngine` built from live SwiftData queries.
struct FinanceReader<Content: View>: View {
    @Query private var accounts: [Account]
    @Query private var transactions: [TransactionRecord]
    @Query private var holdings: [Holding]
    @Query private var trades: [InvestmentTrade]
    @Query private var rates: [CurrencyRate]
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    private let content: (FinanceEngine) -> Content

    init(@ViewBuilder content: @escaping (FinanceEngine) -> Content) {
        self.content = content
    }

    var body: some View {
        content(FinanceEngine(accounts: accounts, transactions: transactions, holdings: holdings, trades: trades,
                              converter: .make(base: baseCurrency, rates: rates)))
    }
}
