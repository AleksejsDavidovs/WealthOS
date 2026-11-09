import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import MyApp

/// Every screen derives its figures from the same `FinanceEngine`; these tests check that
/// each mutation moves *all* dependent values together and by the financially correct amount.
/// All tests use isolated in-memory stores — never the real database.
@MainActor
@Suite("Financial consistency across screens")
struct FinancialConsistencyTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws { container = try Persistence.makeInMemoryContainer() }

    /// What each screen would show right now, all from one engine.
    struct Screens: Equatable {
        var netWorth: Decimal          // Home
        var goals: GoalMath.Overview   // Goals card
        var simulator: SimulatorViewModel.StartingBalances
    }

    private func engine(now: Date = .now) throws -> FinanceEngine {
        let rates = try context.fetch(FetchDescriptor<CurrencyRate>())
        return FinanceEngine(accounts: try context.fetch(FetchDescriptor<Account>()),
                             transactions: try context.fetch(FetchDescriptor<TransactionRecord>()),
                             holdings: try context.fetch(FetchDescriptor<Holding>()),
                             trades: try context.fetch(FetchDescriptor<InvestmentTrade>()),
                             converter: .make(base: "EUR", rates: rates), now: now)
    }

    private func screens() throws -> Screens {
        let engine = try engine()
        let goals = try context.fetch(FetchDescriptor<Goal>()).map { ($0.allocatedAmount, $0.targetAmount) }
        return Screens(netWorth: engine.summary.netWorth,
                       goals: GoalMath.overview(summary: engine.summary, goals: goals),
                       simulator: SimulatorViewModel.liveStartingBalances(engine.summary))
    }

    private func balance(_ account: Account) throws -> Decimal { try engine().balance(of: account) }

    private let earlier = Date.now.addingTimeInterval(-3_600)

    // MARK: Transactions

    @Test func incomeExpenseEditAndDeleteMoveEveryScreenByTheExactDelta() throws {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 1_000)
        context.insert(checking)
        try context.save()
        let start = try screens()

        let income = TransactionRecord(kind: .income, amount: 500, date: earlier, accountID: checking.id)
        try Persistence.commit(context) { context.insert(income) }
        #expect(try balance(checking) == 1_500)
        #expect(try screens().netWorth == start.netWorth + 500)
        #expect(try screens().goals.available == start.goals.available + 500)
        #expect(try screens().simulator.cash == start.simulator.cash + 500)

        let expense = TransactionRecord(kind: .expense, amount: 200, date: earlier, accountID: checking.id)
        try Persistence.commit(context) { context.insert(expense) }
        #expect(try balance(checking) == 1_300)

        // Editing €200 → €300 takes off €100 more, not €300.
        try Persistence.commit(context) { expense.amount = 300 }
        #expect(try balance(checking) == 1_200)
        #expect(try screens().goals.available == start.goals.available + 200)

        // Deleting fully reverses its effect.
        try Persistence.commit(context) { context.delete(expense) }
        #expect(try balance(checking) == 1_500)
        try Persistence.commit(context) { context.delete(income) }
        #expect(try screens() == start)
    }

    @Test func movingATransactionToAnotherAccountReversesItOnTheFirst() throws {
        let a = Account(name: "A", kind: .checking, currencyCode: "EUR", openingBalance: 1_000)
        let b = Account(name: "B", kind: .savings, currencyCode: "EUR", openingBalance: 0)
        context.insert(a); context.insert(b)
        let expense = TransactionRecord(kind: .expense, amount: 100, date: earlier, accountID: a.id)
        context.insert(expense)
        try context.save()

        try Persistence.commit(context) { expense.accountID = b.id }

        #expect(try balance(a) == 1_000)
        #expect(try balance(b) == -100)
    }

    @Test func transferChangesBalancesButNotNetWorthOrGoalFunds() throws {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 3_000)
        let savings = Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 0)
        context.insert(checking); context.insert(savings)
        try context.save()
        let before = try screens()

        try Persistence.commit(context) {
            context.insert(TransactionRecord(kind: .transfer, amount: 1_000, date: earlier,
                                             accountID: checking.id, destinationAccountID: savings.id))
        }

        #expect(try balance(checking) == 2_000)
        #expect(try balance(savings) == 1_000)
        #expect(try screens() == before)
        #expect(try engine().cashFlow(forMonthContaining: .now) == CashFlowSummary())
    }

    // MARK: Accounts

    @Test func newSavingsAccountIsEligibleForGoalsImmediately() throws {
        let before = try screens()
        try Persistence.commit(context) {
            context.insert(Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 5_000))
        }
        let after = try screens()
        #expect(after.netWorth == before.netWorth + 5_000)
        #expect(after.goals.available == before.goals.available + 5_000)
        #expect(after.goals.unallocated == before.goals.unallocated + 5_000)
    }

    @Test func editingOpeningBalanceAndDeletingAnAccountPropagate() throws {
        let savings = Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 1_000)
        context.insert(savings)
        context.insert(TransactionRecord(kind: .income, amount: 50, date: earlier, accountID: savings.id))
        try context.save()

        try Persistence.commit(context) { savings.openingBalance = 1_200 }
        #expect(try screens().goals.available == 1_250)

        try Persistence.commit(context) { try LedgerService.delete(account: savings, in: context) }
        #expect(try screens().netWorth == 0)
        #expect(try context.fetch(FetchDescriptor<TransactionRecord>()).isEmpty)
    }

    @Test func propertyAndDebtsAreNotGoalFundsButStillNetWorth() throws {
        context.insert(Account(name: "Cash", kind: .checking, currencyCode: "EUR", openingBalance: 2_000))
        context.insert(Account(name: "Flat", kind: .otherAsset, currencyCode: "EUR", openingBalance: 100_000))
        context.insert(Account(name: "Card", kind: .liability, currencyCode: "EUR", openingBalance: -500))
        try context.save()

        let s = try screens()
        #expect(s.netWorth == 101_500)
        #expect(s.goals.available == 2_000, "Goals counts cash + investments only (existing documented rule)")
    }

    // MARK: Save failures

    @Test func failedSaveLeavesNoFalselyUpdatedBalance() throws {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 1_000)
        context.insert(checking)
        try context.save()
        let before = try screens()

        #expect(throws: PersistenceError.saveFailed) {
            try Persistence.commit(context, save: { _ in throw CocoaError(.fileWriteUnknown) }) {
                context.insert(TransactionRecord(kind: .income, amount: 9_999, date: earlier, accountID: checking.id))
            }
        }

        #expect(try screens() == before, "the unsaved income must be rolled back everywhere")
        #expect(try context.fetch(FetchDescriptor<TransactionRecord>()).isEmpty)
    }

    @Test func failedEditRestoresThePreviousAmount() throws {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 1_000)
        let expense = TransactionRecord(kind: .expense, amount: 200, date: earlier, accountID: checking.id)
        context.insert(checking); context.insert(expense)
        try context.save()

        #expect(throws: PersistenceError.saveFailed) {
            try Persistence.commit(context, save: { _ in throw CocoaError(.fileWriteUnknown) }) { expense.amount = 300 }
        }

        #expect(expense.amount == 200)
        #expect(try balance(checking) == 800)
    }

    // MARK: Investments

    @Test func buyingWithOwnCashDoesNotChangeNetWorthOrGoalFunds() throws {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 10_000)
        context.insert(checking)
        try context.save()
        let before = try screens()

        let etf = Holding(name: "ETF", symbol: "ETF", assetClass: .etf, currencyCode: "EUR", currentPrice: 100)
        try Persistence.commit(context) {
            context.insert(etf)
            context.insert(InvestmentTrade(holdingID: etf.id, kind: .buy, date: earlier, quantity: 20, pricePerUnit: 100,
                                           fee: 0, cashAccountID: checking.id, cashAmount: 2_000))
        }

        let after = try screens()
        #expect(after.netWorth == before.netWorth)
        #expect(after.goals.available == before.goals.available)
        #expect(after.simulator.cash == before.simulator.cash - 2_000)
        #expect(after.simulator.investments == before.simulator.investments + 2_000)
    }

    @Test func sellingCountsProceedsOnce() throws {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 0)
        let etf = Holding(name: "ETF", symbol: "ETF", assetClass: .etf, currencyCode: "EUR", currentPrice: 150)
        context.insert(checking); context.insert(etf)
        context.insert(InvestmentTrade(holdingID: etf.id, kind: .buy, date: earlier.addingTimeInterval(-60), quantity: 10,
                                       pricePerUnit: 100, fee: 0))
        try context.save()
        #expect(try screens().netWorth == 1_500)

        try Persistence.commit(context) {
            context.insert(InvestmentTrade(holdingID: etf.id, kind: .sell, date: earlier, quantity: 4, pricePerUnit: 150,
                                           fee: 0, cashAccountID: checking.id, cashAmount: 600))
        }

        #expect(try balance(checking) == 600)
        #expect(try engine().summary.holdingsValue == 900)
        #expect(try screens().netWorth == 1_500, "cash in, holding out — not double counted")
    }

    @Test func marketPriceChangeRevaluesWithoutFakeCashOrCostBasisChange() throws {
        let etf = Holding(name: "ETF", symbol: "ETF", assetClass: .etf, currencyCode: "EUR", currentPrice: 100)
        context.insert(etf)
        context.insert(InvestmentTrade(holdingID: etf.id, kind: .buy, date: earlier, quantity: 10, pricePerUnit: 100, fee: 0))
        try context.save()
        let costBefore = try engine().portfolioCostBasis

        try Persistence.commit(context) { try LedgerService.updatePrice(of: etf, to: 130, in: context) }

        let s = try screens()
        #expect(s.netWorth == 1_300)
        #expect(s.goals.available == 1_300)
        #expect(try engine().portfolioCostBasis == costBefore)
        #expect(try context.fetch(FetchDescriptor<TransactionRecord>()).isEmpty)
    }

    // MARK: Goals

    @Test func allocatingToAGoalReservesFundsWithoutChangingNetWorth() throws {
        context.insert(Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 5_000))
        let goal = Goal(name: "Car", type: .emergencyFund, targetAmount: 10_000)
        context.insert(goal)
        try context.save()
        let before = try screens()

        try Persistence.commit(context) { goal.allocatedAmount = 2_000 }

        let after = try screens()
        #expect(after.netWorth == before.netWorth)
        #expect(after.goals.available == before.goals.available)
        #expect(after.goals.unallocated == before.goals.unallocated - 2_000)
        #expect(after.goals.isOverAllocated == false)

        try Persistence.commit(context) { goal.allocatedAmount = 6_000 }
        #expect(try screens().goals.isOverAllocated, "earmarks above eligible funds must warn")

        try Persistence.commit(context) { context.delete(goal) }
        #expect(try screens().goals.allocated == 0)
        #expect(try screens().netWorth == before.netWorth)
    }

    // MARK: Currencies

    @Test func exchangeRateChangeRevaluesOnceAndMissingRatesAreReported() throws {
        let usd = Account(name: "US", kind: .savings, currencyCode: "USD", openingBalance: 1_000)
        context.insert(usd)
        try context.save()

        let missing = try engine().summary
        #expect(missing.missingRateCurrencies == ["USD"])
        #expect(GoalMath.allocatableAssets(missing) == 0)

        try Persistence.commit(context) { try LedgerService.setRate(Decimal(string: "0.9")!, for: "USD", in: context) }
        #expect(try screens().goals.available == 900)

        try Persistence.commit(context) { try LedgerService.setRate(Decimal(string: "0.95")!, for: "USD", in: context) }
        #expect(try screens().goals.available == 950)
        #expect(try screens().netWorth == 950)
        #expect(try balance(usd) == 1_000, "the account keeps its own currency")
    }

    // MARK: Time

    @Test func futureDatedEntriesCountFromTheirDate() throws {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 0)
        context.insert(checking)
        let nextWeek = Date.now.addingTimeInterval(7 * 86_400)
        context.insert(TransactionRecord(kind: .income, amount: 1_000, date: nextWeek, accountID: checking.id))
        try context.save()

        let today = try engine()
        #expect(today.balance(of: checking) == 0)
        #expect(today.scheduledCount == 1)

        let then = try engine(now: nextWeek)
        #expect(then.balance(of: checking) == 1_000)
        #expect(then.scheduledCount == 0)
    }

    // MARK: Bulk changes

    @Test func restoringABackupReplacesEveryDerivedValue() throws {
        context.insert(Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 4_000))
        context.insert(Goal(name: "Trip", type: .emergencyFund, targetAmount: 3_000, allocatedAmount: 1_000))
        try context.save()
        let original = try screens()
        let payload = try BackupService.makePayload(from: context, baseCurrency: "EUR")

        try Persistence.commit(context) {
            context.insert(Account(name: "Extra", kind: .checking, currencyCode: "EUR", openingBalance: 9_000))
        }
        #expect(try screens() != original)

        try BackupService.restore(payload, into: context)

        #expect(try screens() == original)
    }

    @Test func rapidConsecutiveSavesAreExact() throws {
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 0)
        context.insert(checking)
        try context.save()

        for i in 1...100 {
            try Persistence.commit(context) {
                context.insert(TransactionRecord(kind: i.isMultiple(of: 2) ? .expense : .income,
                                                 amount: Decimal(string: "10.01")!, date: earlier, accountID: checking.id))
            }
        }
        #expect(try balance(checking) == 0, "50 × 10.01 in, 50 × 10.01 out — exact Decimal arithmetic")
    }

    // MARK: Simulator

    @Test func simulatorFlagsChangedBalancesButNeverOverwritesThem() throws {
        context.insert(Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: 1_000))
        try context.save()
        var parameters = SimulationParameters.preset(.balanced, startingCash: 1_000, startingInvestments: 0,
                                                     monthlyIncome: 0, monthlyExpenses: 0)
        #expect(SimulatorViewModel.liveBalancesIfChanged(try engine().summary, parameters: parameters) == nil)

        try Persistence.commit(context) {
            context.insert(Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 500))
        }

        let live = try #require(SimulatorViewModel.liveBalancesIfChanged(try engine().summary, parameters: parameters))
        #expect(live == .init(cash: 1_500, investments: 0))
        #expect(parameters.startingCash == 1_000, "scenario assumptions stay as the user set them")

        parameters.startingCash = live.cash
        #expect(SimulatorViewModel.liveBalancesIfChanged(try engine().summary, parameters: parameters) == nil)
    }
}

// MARK: - Live SwiftUI refresh

/// Records every overview value an on-screen view actually rendered.
@MainActor
final class RenderedValues {
    var overviews: [GoalMath.Overview] = []
}

/// Same data path as the Goals card: `FinanceReader` + `@Query` goals + `GoalMath.overview`.
private struct GoalsOverviewProbe: View {
    @Query private var goals: [Goal]
    let sink: RenderedValues

    var body: some View {
        FinanceReader { engine in
            let overview = GoalMath.overview(summary: engine.summary,
                                             goals: goals.map { ($0.allocatedAmount, $0.targetAmount) })
            Text(verbatim: "\(overview.available)")
                .onChange(of: overview, initial: true) { _, rendered in sink.overviews.append(rendered) }
        }
    }
}

/// Hosts a real SwiftUI hierarchy in a visible window, then changes data underneath it.
/// This proves the shared observation pipeline re-renders an *already visible* view after
/// a save — but it is not a pixel check of the Goals screen itself.
@MainActor
@Suite("Live refresh of a visible view", .serialized)
struct LiveRefreshIntegrationTests {
    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func savingARecordUpdatesAnAlreadyVisibleGoalsOverview() async throws {
        let container = try Persistence.makeInMemoryContainer()
        let context = container.mainContext
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let sink = RenderedValues()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: GoalsOverviewProbe(sink: sink).modelContainer(container))
        window.isHidden = false
        defer { window.isHidden = true }

        await waitUntil { sink.overviews.last != nil }
        #expect(sink.overviews.last?.available == 0)

        // 1. New savings account → visible figure updates without any refresh call.
        try Persistence.commit(context) {
            context.insert(Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 5_000))
        }
        await waitUntil { sink.overviews.last?.available == 5_000 }
        #expect(sink.overviews.last?.available == 5_000)

        // 2. Earmark → unallocated drops, available unchanged.
        try Persistence.commit(context) {
            context.insert(Goal(name: "Car", type: .emergencyFund, targetAmount: 10_000, allocatedAmount: 2_000))
        }
        await waitUntil { sink.overviews.last?.unallocated == 3_000 }
        #expect(sink.overviews.last?.available == 5_000)
        #expect(sink.overviews.last?.unallocated == 3_000)

        // 3. Restore a backup of the empty-account state → the visible view follows.
        let payload = try BackupService.makePayload(from: context, baseCurrency: "EUR")
        try Persistence.commit(context) {
            context.insert(Account(name: "Extra", kind: .checking, currencyCode: "EUR", openingBalance: 1_000))
        }
        await waitUntil { sink.overviews.last?.available == 6_000 }
        #expect(sink.overviews.last?.available == 6_000)
        try BackupService.restore(payload, into: context)
        await waitUntil { sink.overviews.last?.available == 5_000 }
        #expect(sink.overviews.last?.available == 5_000)
    }
}
