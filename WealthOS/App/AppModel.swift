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
    #if DEBUG
    /// Development aid: a screen to open at launch for visual checks (see `-UIScreen`).
    var debugScreen: String?
    #endif
    /// Set by Quick Add controls; MainTabView presents the transaction editor.
    var quickAddRequest: TransactionEditorRequest?

    /// True if the store already held data at launch; onboarding is then never shown.
    private(set) var storeHadDataAtLaunch = false

    init() {
        do {
            if Persistence.isHostingTests() {
                persistentContainer = try Persistence.makeInMemoryContainer()
            } else {
                persistentContainer = try Persistence.makePersistentContainer()
            }
            loadError = nil
            storeHadDataAtLaunch = persistentContainer.map { Persistence.containsUserData($0.mainContext) } ?? false
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
        // `-UIScreen <analytics|categoryEditor>` additionally opens that screen on the Transactions tab.
        if let index = arguments.firstIndex(of: "-UIScreen"), index + 1 < arguments.count {
            debugScreen = arguments[index + 1]
        }
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
        let broker = BrokerPortfolio(snapshot: (try? context.fetch(FetchDescriptor<BrokerAccountSnapshot>()))?.first,
                                     positions: (try? context.fetch(FetchDescriptor<BrokerPosition>())) ?? [],
                                     links: (try? context.fetch(FetchDescriptor<BrokerLink>())) ?? [])
        let binance = BinancePortfolio(snapshot: (try? context.fetch(FetchDescriptor<BinanceAccountSnapshot>()))?.first,
                                       holdings: (try? context.fetch(FetchDescriptor<BinanceHolding>())) ?? [],
                                       links: (try? context.fetch(FetchDescriptor<BinanceLink>())) ?? [])
        let bank = BankPortfolio(links: (try? context.fetch(FetchDescriptor<BankAccountLink>())) ?? [],
                                 connections: (try? context.fetch(FetchDescriptor<BankConnection>())) ?? [])
        return FinanceEngine(accounts: (try? context.fetch(FetchDescriptor<Account>())) ?? [],
                             transactions: (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? [],
                             holdings: (try? context.fetch(FetchDescriptor<Holding>())) ?? [],
                             trades: (try? context.fetch(FetchDescriptor<InvestmentTrade>())) ?? [],
                             converter: CurrencyConverter.make(base: baseCurrency, rates: rates), broker: broker,
                             binance: binance, bank: bank)
    }

    /// Launch / foreground housekeeping: default categories, due recurring transactions,
    /// and today's automatic net worth snapshot.
    static func run(context: ModelContext, baseCurrency: String) {
        LedgerService.seedDefaultCategoriesIfNeeded(in: context)
        RecurringService.processDueRules(in: context)
        refreshSnapshot(context: context, baseCurrency: baseCurrency)
    }

    @discardableResult
    static func refreshSnapshot(context: ModelContext, baseCurrency: String) -> SnapshotService.AutomaticSnapshotOutcome {
        let engine = makeEngine(context: context, baseCurrency: baseCurrency)
        // Budget thresholds and subscription reminders: real data only — never the in-memory
        // demo store or a test host.
        if !Persistence.isHostingTests(), context.container.configurations.contains(where: { !$0.isStoredInMemoryOnly }) {
            PlanningMonitor.run(context: context, engine: engine)
        }
        return SnapshotService.recordAutomaticSnapshot(summary: engine.summary, currencyCode: baseCurrency,
                                                hasData: !engine.accounts.isEmpty || !engine.holdings.isEmpty
                                                    || engine.broker.snapshot != nil || engine.binance.snapshot != nil,
                                                in: context)
    }
}

extension CurrencyConverter {
    static func make(base: String, rates: [CurrencyRate]) -> CurrencyConverter {
        CurrencyConverter(baseCode: base, rates: Dictionary(rates.map { ($0.code, $0.rateToBase) }, uniquingKeysWith: { a, _ in a }))
    }
}

/// The single source of financial truth for every screen: a `FinanceEngine` rebuilt from
/// live SwiftData queries on the main context. Any saved (or pending) insert, edit or delete
/// of an account, transaction, holding, trade or rate — including bulk restore/import into
/// that context — re-renders every visible reader. No totals are cached anywhere else.
struct FinanceReader<Content: View>: View {
    @Query private var accounts: [Account]
    @Query private var transactions: [TransactionRecord]
    @Query private var holdings: [Holding]
    @Query private var trades: [InvestmentTrade]
    @Query private var rates: [CurrencyRate]
    @Query private var brokerSnapshots: [BrokerAccountSnapshot]
    @Query private var brokerPositions: [BrokerPosition]
    @Query private var brokerLinks: [BrokerLink]
    @Query private var binanceSnapshots: [BinanceAccountSnapshot]
    @Query private var binanceHoldings: [BinanceHolding]
    @Query private var binanceLinks: [BinanceLink]
    @Query private var bankLinks: [BankAccountLink]
    @Query private var bankConnections: [BankConnection]
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    /// Balances depend on "today" (future-dated records count from their date), which no
    /// query observes; bumping this at midnight or after a date change re-evaluates the body.
    @State private var day = Calendar.current.startOfDay(for: .now)
    private let content: (FinanceEngine) -> Content

    init(@ViewBuilder content: @escaping (FinanceEngine) -> Content) {
        self.content = content
    }

    var body: some View {
        let _ = day
        content(FinanceEngine(accounts: accounts, transactions: transactions, holdings: holdings, trades: trades,
                              converter: .make(base: baseCurrency, rates: rates),
                              broker: BrokerPortfolio(snapshot: brokerSnapshots.first, positions: brokerPositions,
                                                      links: brokerLinks),
                              binance: BinancePortfolio(snapshot: binanceSnapshots.first, holdings: binanceHoldings,
                                                        links: binanceLinks),
                              bank: BankPortfolio(links: bankLinks, connections: bankConnections)))
            .task {
                for await _ in NotificationCenter.default.notifications(named: UIApplication.significantTimeChangeNotification) {
                    day = Calendar.current.startOfDay(for: .now)
                }
            }
    }
}
