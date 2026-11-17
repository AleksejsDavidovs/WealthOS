import Foundation
import SwiftData
import Testing
@testable import WealthOS

private let riga: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Riga")!
    return calendar
}()

private func day(_ text: String, hour: Int = 12) -> Date {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    return riga.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
}

private func expense(_ date: String, _ amount: Decimal, _ category: UUID?) -> CashFlowEntry {
    CashFlowEntry(id: UUID(), date: day(date), kind: .expense, categoryID: category, amount: amount)
}

// MARK: - Budgets

@Suite("Budgets")
struct BudgetMathTests {
    let food = UUID(), fun = UUID()

    @Test func spendingCountsTheCategoryInTheMonthOnly() {
        let entries = [expense("2026-11-02", 50, food), expense("2026-11-20", Decimal(string: "25.50")!, food),
                       expense("2026-11-05", 40, fun), expense("2026-10-31", 99, food),
                       CashFlowEntry(id: UUID(), date: day("2026-11-03"), kind: .income, categoryID: food, amount: 500)]
        let month = riga.dateInterval(of: .month, for: day("2026-11-15"))!
        #expect(BudgetMath.spent(categoryID: food, in: month, entries: entries) == Decimal(string: "75.5")!)
        #expect(BudgetMath.spent(categoryID: nil, in: month, entries: entries) == Decimal(string: "115.5")!)
    }

    @Test func levelsAtEightyAndOneHundredPercent() {
        func status(_ spent: Decimal) -> BudgetStatus {
            BudgetMath.status(of: .init(id: UUID(), categoryID: food, amount: 100, rollover: false), month: day("2026-11-15"),
                              entries: [expense("2026-11-02", spent, food)], now: day("2026-12-05"), calendar: riga)
        }
        #expect(status(Decimal(string: "79.99")!).level == .ok)
        #expect(status(80).level == .warning)
        #expect(status(100).level == .over)
        #expect(status(130).remaining == -30)
        #expect(status(130).projected == nil)  // a finished month has no projection
    }

    @Test func rolloverCarriesOnlyUnspentMoney() {
        let budget = BudgetMath.Definition(id: UUID(), categoryID: food, amount: 200, rollover: true)
        let under = BudgetMath.status(of: budget, month: day("2026-11-10"), entries: [expense("2026-10-05", 150, food)],
                                      now: day("2026-11-10"), calendar: riga)
        #expect(under.carry == 50 && under.limit == 250)
        let over = BudgetMath.status(of: budget, month: day("2026-11-10"), entries: [expense("2026-10-05", 260, food)],
                                     now: day("2026-11-10"), calendar: riga)
        #expect(over.carry == 0 && over.limit == 200)
        let plain = BudgetMath.status(of: .init(id: UUID(), categoryID: food, amount: 200, rollover: false), month: day("2026-11-10"),
                                      entries: [expense("2026-10-05", 10, food)], now: day("2026-11-10"), calendar: riga)
        #expect(plain.carry == 0)
    }

    @Test func projectionFollowsTheCurrentPace() {
        // 100 spent in the first 10 days of a 30-day month → 300 by month end.
        let status = BudgetMath.status(of: .init(id: UUID(), categoryID: nil, amount: 250, rollover: false), month: day("2026-11-10"),
                                       entries: [expense("2026-11-03", 100, food)], now: day("2026-11-10"), calendar: riga)
        #expect(status.projected == 300)
    }

    @Test func overviewPrefersTheAllSpendingBudget() {
        let a = BudgetStatus(id: UUID(), categoryID: food, amount: 200, carry: 0, spent: 150, projected: nil)
        let b = BudgetStatus(id: UUID(), categoryID: fun, amount: 100, carry: 20, spent: 30, projected: nil)
        let all = BudgetStatus(id: UUID(), categoryID: nil, amount: 1_000, carry: 0, spent: 640, projected: nil)
        #expect(BudgetMath.overview([a, b])! == (limit: 320, spent: 180))
        #expect(BudgetMath.overview([a, b, all])! == (limit: 1_000, spent: 640))
        #expect(BudgetMath.overview([]) == nil)
    }

    @Test func eachThresholdIsAnnouncedOncePerMonth() {
        func status(_ spent: Decimal) -> BudgetStatus { .init(id: UUID(), categoryID: food, amount: 100, carry: 0, spent: spent, projected: nil) }
        #expect(BudgetMath.alertLevel(for: status(50), alertedMonth: "", alertedLevel: 0, monthKey: "2026-11") == nil)
        #expect(BudgetMath.alertLevel(for: status(85), alertedMonth: "", alertedLevel: 0, monthKey: "2026-11") == 80)
        #expect(BudgetMath.alertLevel(for: status(90), alertedMonth: "2026-11", alertedLevel: 80, monthKey: "2026-11") == nil)
        #expect(BudgetMath.alertLevel(for: status(101), alertedMonth: "2026-11", alertedLevel: 80, monthKey: "2026-11") == 100)
        #expect(BudgetMath.alertLevel(for: status(120), alertedMonth: "2026-11", alertedLevel: 100, monthKey: "2026-11") == nil)
        // Straight past 100 %: one notification, not two.
        #expect(BudgetMath.alertLevel(for: status(150), alertedMonth: "", alertedLevel: 0, monthKey: "2026-11") == 100)
        // A new month starts over.
        #expect(BudgetMath.alertLevel(for: status(85), alertedMonth: "2026-11", alertedLevel: 100, monthKey: "2026-12") == 80)
        #expect(BudgetMath.monthKey(day("2026-03-04"), calendar: riga) == "2026-03")
    }
}

@MainActor
@Suite("Budget alerts and data safety")
struct BudgetStorageTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    init() throws { container = try Persistence.makeInMemoryContainer() }

    @Test func alertsMarkBudgetsAndNeverShowAmounts() throws {
        LedgerService.seedDefaultCategoriesIfNeeded(in: context)
        let categories = try context.fetch(FetchDescriptor<TransactionCategory>())
        let food = categories.first { $0.name == "Food" }!
        let budget = Budget(categoryID: food.id, amount: 200)
        context.insert(budget)
        let entries = [expense("2026-11-02", 170, food.id)]
        let now = day("2026-11-12")
        var statuses = PlanningMonitor.budgetStatuses([budget], entries: entries, month: now, now: now, calendar: riga)
        let first = PlanningMonitor.takeBudgetAlerts(budgets: [budget], statuses: statuses, categories: categories, now: now, calendar: riga)
        #expect(first.map(\.level) == [80])
        #expect(first[0].title == "Budget: Food" && first[0].body.contains("85"))
        #expect(!first[0].body.contains("€") && !first[0].body.contains("170"))
        #expect(budget.alertedMonth == "2026-11" && budget.alertedLevel == 80)
        // Same state again: nothing new.
        #expect(PlanningMonitor.takeBudgetAlerts(budgets: [budget], statuses: statuses, categories: categories, now: now, calendar: riga).isEmpty)
        statuses = PlanningMonitor.budgetStatuses([budget], entries: entries + [expense("2026-11-10", 40, food.id)],
                                                  month: now, now: now, calendar: riga)
        #expect(PlanningMonitor.takeBudgetAlerts(budgets: [budget], statuses: statuses, categories: categories, now: now, calendar: riga)
                    .map(\.level) == [100])
    }

    @Test func deletingACategoryRemovesItsBudgetAndDeleteAllClearsPlanning() throws {
        LedgerService.seedDefaultCategoriesIfNeeded(in: context)
        let car = try context.fetch(FetchDescriptor<TransactionCategory>()).first { $0.name == "Car" }!
        context.insert(Budget(categoryID: car.id, amount: 90))
        context.insert(Budget(categoryID: nil, amount: 900))
        context.insert(SubscriptionDecision(key: "note:netflix", status: .confirmed))
        try context.save()
        try LedgerService.delete(category: car, in: context)
        #expect(try context.fetch(FetchDescriptor<Budget>()).map(\.categoryID) == [nil])
        try LedgerService.deleteAllData(in: context)
        #expect(try context.fetchCount(FetchDescriptor<Budget>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SubscriptionDecision>()) == 0)
    }

    @Test func backupCarriesBudgetsAndDecisionsAndOldBackupsStillRestore() throws {
        LedgerService.seedDefaultCategoriesIfNeeded(in: context)
        let food = try context.fetch(FetchDescriptor<TransactionCategory>()).first { $0.name == "Food" }!
        let budget = Budget(categoryID: food.id, amount: Decimal(string: "245.50")!, rollover: true)
        budget.alertedMonth = "2026-11"
        budget.alertedLevel = 80
        context.insert(budget)
        context.insert(SubscriptionDecision(key: "merchant:spotify", status: .confirmed))
        context.insert(SubscriptionDecision(key: "note:rent", status: .dismissed))
        try context.save()

        let payload = try BackupService.makePayload(from: context, baseCurrency: "EUR")
        let data = try BackupPayload.encoder().encode(payload)
        let decoded = try BackupPayload.decoder().decode(BackupPayload.self, from: data)
        #expect(decoded.planning?.budgets.count == 1 && decoded.planning?.subscriptionDecisions.count == 2)

        let target = try Persistence.makeInMemoryContainer()
        try BackupService.restore(decoded, into: target.mainContext)
        let restored = try #require(try target.mainContext.fetch(FetchDescriptor<Budget>()).first)
        #expect(restored.amount == Decimal(string: "245.50")! && restored.rollover && restored.categoryID == food.id)
        #expect(restored.alertedMonth == "2026-11" && restored.alertedLevel == 80)
        let statuses = Dictionary(try target.mainContext.fetch(FetchDescriptor<SubscriptionDecision>()).map { ($0.key, $0.status) },
                                  uniquingKeysWith: { a, _ in a })
        #expect(statuses == ["merchant:spotify": .confirmed, "note:rent": .dismissed])

        // A backup written before budgets existed has no "planning" key at all.
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "planning")
        let old = try BackupPayload.decoder().decode(BackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.planning == nil)
        let another = try Persistence.makeInMemoryContainer()
        try BackupService.restore(old, into: another.mainContext)
        #expect(try another.mainContext.fetchCount(FetchDescriptor<Budget>()) == 0)
        #expect(try another.mainContext.fetchCount(FetchDescriptor<TransactionCategory>()) > 0)
    }

    @Test func backupValidationRejectsBadPlanningData() throws {
        var payload = try BackupService.makePayload(from: context, baseCurrency: "EUR")
        let id = UUID()
        payload.planning = .init(budgets: [.init(id: id, categoryID: nil, amount: 10, rollover: false, alertedMonth: "", alertedLevel: 0, createdAt: .now),
                                           .init(id: id, categoryID: nil, amount: 20, rollover: false, alertedMonth: "", alertedLevel: 0, createdAt: .now)],
                                 subscriptionDecisions: [])
        #expect(throws: BackupValidationError.self) { try payload.validate() }
        payload.planning?.budgets = [.init(id: id, categoryID: nil, amount: 0, rollover: false, alertedMonth: "", alertedLevel: 0, createdAt: .now)]
        #expect(throws: BackupValidationError.self) { try payload.validate() }
    }
}

@MainActor
@Suite("Store migration for planning", .serialized)
struct PlanningMigrationTests {
    @Test func storeFromBeforeBudgetsOpensWithAllDataAndAcceptsBudgets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WealthOS-PlanningMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "WealthOS.store")
        let newTypes: Set<ObjectIdentifier> = [ObjectIdentifier(Budget.self), ObjectIdentifier(SubscriptionDecision.self)]
        do {
            // The schema exactly as it was before budgets: every current model except the two new ones.
            let previous = Schema(Persistence.modelTypes.filter { !newTypes.contains(ObjectIdentifier($0)) })
            let container = try ModelContainer(for: previous, configurations: [ModelConfiguration("WealthOS", schema: previous, url: url,
                                                                                                    cloudKitDatabase: .none)])
            let context = container.mainContext
            let account = Account(name: "Swedbank", kind: .checking, currencyCode: "EUR", openingBalance: 1_234)
            context.insert(account)
            context.insert(TransactionRecord(kind: .expense, amount: 12, date: .now, accountID: account.id))
            let link = BankAccountLink(accountKey: String(repeating: "a", count: 64), aspspName: "Swedbank", aspspCountry: "LV")
            link.localAccountID = account.id
            context.insert(link)
            context.insert(BankCounterpartyRule(matchKey: "merchant:rimi", direction: "out", action: .expense, categoryID: nil,
                                                otherAccountID: nil, label: "Rimi"))
            try context.save()
        }
        let current = try Persistence.makePersistentContainer(directory: directory)
        let context = current.mainContext
        #expect(try context.fetch(FetchDescriptor<Account>()).map(\.openingBalance) == [1_234])
        #expect(try context.fetchCount(FetchDescriptor<TransactionRecord>()) == 1)
        #expect(try context.fetch(FetchDescriptor<BankAccountLink>()).first?.isLinked == true)
        #expect(try context.fetchCount(FetchDescriptor<BankCounterpartyRule>()) == 1)
        context.insert(Budget(categoryID: nil, amount: 500))
        context.insert(SubscriptionDecision(key: "note:x", status: .dismissed))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Budget>()) == 1)
    }
}

// MARK: - Subscriptions

@Suite("Subscription detection")
struct SubscriptionDetectionTests {
    let subscriptionsCategory = UUID(), food = UUID()

    private func charges(_ key: String, _ dates: [String], _ amounts: [Decimal], category: UUID? = nil) -> [SubscriptionCharge] {
        zip(dates, amounts).map { SubscriptionCharge(id: UUID(), date: day($0), amount: $1, categoryID: category, key: key,
                                                     title: SubscriptionDetector.title(fromKey: key)) }
    }

    private func detect(_ charges: [SubscriptionCharge], decisions: [String: SubscriptionDecisionStatus] = [:],
                        now: String = "2026-11-17") -> [DetectedSubscription] {
        SubscriptionDetector.detect(charges: charges, decisions: decisions, subscriptionCategoryIDs: [subscriptionsCategory],
                                    now: day(now), calendar: riga)
    }

    @Test func monthlyPaymentOfTheSameAmountIsSuggested() throws {
        let found = detect(charges("merchant:spotify", ["2026-08-14", "2026-09-14", "2026-10-14", "2026-11-14"],
                                   [10.99, 10.99, 10.99, 10.99]))
        let spotify = try #require(found.first)
        #expect(spotify.cadence == .monthly && spotify.status == .suggested && spotify.title == "Spotify")
        #expect(spotify.nextDate == day("2026-12-14") && !spotify.isMissed && spotify.priceIncrease == nil)
        #expect(spotify.monthlyCost == Decimal(string: "10.99")! && spotify.yearlyCost == Decimal(string: "131.88")!)
    }

    @Test func groceriesWithChangingAmountsAreNotSubscriptions() {
        #expect(detect(charges("merchant:rimi imanta", ["2026-10-03", "2026-10-10", "2026-10-17", "2026-10-24", "2026-11-01"],
                               [43.10, 71.80, 22.40, 58.00, 90.15], category: food)).isEmpty)
    }

    @Test func twoChargesAreEnoughOnlyWithAStrongHint() {
        let pair = ["2026-10-05", "2026-11-05"]
        #expect(detect(charges("note:gym", pair, [30, 30])).isEmpty)
        #expect(detect(charges("note:icloud", pair, [2.99, 2.99], category: subscriptionsCategory)).count == 1)
        #expect(detect(charges("rule:\(UUID().uuidString)", pair, [15, 15])).count == 1)
    }

    @Test func weeklyAndYearlyCadences() throws {
        let weekly = try #require(detect(charges("note:paper", ["2026-10-27", "2026-11-03", "2026-11-10", "2026-11-17"], [3, 3, 3, 3])).first)
        #expect(weekly.cadence == .weekly && weekly.monthlyCost == 13)  // 3 × 52 / 12
        let yearly = try #require(detect(charges("note:domain", ["2024-03-01", "2025-03-02", "2026-03-01"], [12, 12, 12]),
                                         now: "2026-06-01").first)
        #expect(yearly.cadence == .yearly && yearly.monthlyCost == 1 && yearly.nextDate == day("2027-03-01"))
    }

    @Test func priceIncreaseIsFlaggedButAJumpIsNotASubscription() throws {
        let netflix = try #require(detect(charges("merchant:netflix", ["2026-08-07", "2026-09-07", "2026-10-07", "2026-11-07"],
                                                  [9.99, 9.99, 9.99, 11.99])).first)
        #expect(netflix.priceIncrease?.from == Decimal(string: "9.99")! && netflix.priceIncrease?.to == Decimal(string: "11.99")!)
        #expect(detect(charges("note:x", ["2026-08-07", "2026-09-07", "2026-10-07", "2026-11-07"], [10, 10, 10, 40])).isEmpty)
    }

    @Test func missedChargesAndCancelledSuggestions() throws {
        let dates = ["2026-07-01", "2026-08-01", "2026-09-01", "2026-10-01"]
        let late = try #require(detect(charges("note:gym", dates, [30, 30, 30, 30]), now: "2026-11-08").first)
        #expect(late.isMissed)  // expected 1 Nov, grace 4 days
        // Stopped long ago: no longer suggested, but a confirmed one stays visible.
        #expect(detect(charges("note:gym", dates, [30, 30, 30, 30]), now: "2027-01-20").isEmpty)
        #expect(detect(charges("note:gym", dates, [30, 30, 30, 30]), decisions: ["note:gym": .confirmed], now: "2027-01-20").count == 1)
    }

    @Test func decisionsAndSummary() {
        let all = charges("note:music", ["2026-09-14", "2026-10-14", "2026-11-14"], [13, 13, 13])
            + charges("note:paper", ["2026-11-03", "2026-11-10", "2026-11-17"], [3, 3, 3])
            + charges("note:rent", ["2026-09-03", "2026-10-03", "2026-11-03"], [980, 980, 980])
        let found = detect(all, decisions: ["note:music": .confirmed, "note:rent": .dismissed])
        #expect(found.map(\.key) == ["note:music", "note:paper"])  // confirmed first, dismissed gone
        let summary = SubscriptionDetector.summary(found)
        #expect(summary.confirmedCount == 1 && summary.suggestedCount == 1)
        #expect(summary.monthly == 13 && summary.yearly == 156)  // suggestions aren't counted
    }

    @MainActor
    @Test func reminderIsTheDayBeforeForConfirmedOnly() throws {
        let found = detect(charges("note:music", ["2026-09-20", "2026-10-20"], [13, 13], category: subscriptionsCategory),
                           decisions: ["note:music": .confirmed], now: "2026-11-01")
        let music = try #require(found.first)
        let at = try #require(PlanningMonitor.reminderDate(for: music, now: day("2026-11-01"), calendar: riga))
        #expect(at == riga.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 10)))
        let suggested = detect(charges("note:music", ["2026-09-20", "2026-10-20"], [13, 13], category: subscriptionsCategory),
                               now: "2026-11-01")
        #expect(PlanningMonitor.reminderDate(for: suggested[0], now: day("2026-11-01"), calendar: riga) == nil)
    }
}

@MainActor
@Suite("Subscription payees")
struct SubscriptionPayeeTests {
    @Test func payeeKeysForBankManualAndRecurringRecords() throws {
        let container = try Persistence.makeInMemoryContainer()
        let context = container.mainContext
        let account = UUID()
        let purchase = TransactionRecord(kind: .expense, amount: 5, date: .now, accountID: account)
        let row = BankTransaction(key: "b1", accountKey: String(repeating: "a", count: 64), firstSeenAt: .now)
        row.amount = -5
        row.remittance = "PIRKUMS 400000******0000 09.11.2026 SPOTIFY STOCKHOLM"
        row.ledgerRecordID = purchase.id
        context.insert(row)
        #expect(SubscriptionDetector.payee(for: purchase, bankRow: row)! == (key: "merchant:spotify stockholm", title: "Spotify Stockholm"))

        let named = BankTransaction(key: "b2", accountKey: String(repeating: "a", count: 64), firstSeenAt: .now)
        named.amount = -20
        named.counterpartyName = "Tet SIA"
        #expect(SubscriptionDetector.payee(for: purchase, bankRow: named)?.title == "Tet SIA")

        let ruleID = UUID()
        let generated = TransactionRecord(kind: .expense, amount: 13, date: .now, note: "Music", accountID: account,
                                          recurringRuleID: ruleID)
        #expect(SubscriptionDetector.payee(for: generated, bankRow: nil)! == (key: "rule:" + ruleID.uuidString, title: "Music"))
        let manual = TransactionRecord(kind: .expense, amount: 9, date: .now, note: "  Netflix ", accountID: account)
        #expect(SubscriptionDetector.payee(for: manual, bankRow: nil)?.key == "note:netflix")
        let blank = TransactionRecord(kind: .expense, amount: 9, date: .now, accountID: account)
        #expect(SubscriptionDetector.payee(for: blank, bankRow: nil) == nil)
    }
}
