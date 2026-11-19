import Foundation
import SwiftData
import Testing
@testable import WealthOS

private enum HistoryFixtures {
    static func order(fill: Int, side: String, ticker: String = "AAPL_US_EQ", qty: String = "2", price: String = "150",
                      net: String = "276.5", realized: String = "0", at: String = "2026-03-01T10:00:00Z", fee: String? = nil) -> String {
        let taxes = fee.map { #"[{"currency":"EUR","name":"CURRENCY_CONVERSION_FEE","quantity":\#($0)}]"# } ?? "[]"
        return #"{"order":{"id":\#(fill + 1000),"createdAt":"\#(at)","currency":"EUR","filledQuantity":\#(qty),"instrument":{"currency":"USD","isin":"US0378331005","name":"Apple","ticker":"\#(ticker)"},"side":"\#(side)","status":"FILLED","ticker":"\#(ticker)","type":"MARKET"},"fill":{"id":\#(fill),"filledAt":"\#(at)","price":\#(price),"quantity":\#(qty),"type":"TRADE","walletImpact":{"currency":"EUR","fxRate":1.08,"netValue":\#(net),"realisedProfitLoss":\#(realized),"taxes":\#(taxes)}}}"#
    }

    static func cash(_ reference: String, type: String, amount: String, at: String = "2026-01-05T09:00:00Z") -> String {
        #"{"amount":\#(amount),"currency":"EUR","dateTime":"\#(at)","reference":"\#(reference)","type":"\#(type)"}"#
    }

    static func page(_ items: [String], next: String? = nil) -> String {
        #"{"items":[\#(items.joined(separator: ","))],"nextPagePath":\#(next.map { "\"\($0)\"" } ?? "null")}"#
    }
}

private func date(_ text: String) -> Date { Trading212Parsing.parseDate(text)! }

@Suite("Trading 212 history — parsing")
struct Trading212HistoryParsingTests {
    @Test func ordersKeepOnlyExecutedFillsWithFees() throws {
        let page: T212OrderPage = try T212Fixtures.decode(HistoryFixtures.page([
            HistoryFixtures.order(fill: 1, side: "BUY", net: "-276.504", fee: "0.41"),
            HistoryFixtures.order(fill: 1, side: "BUY"), // duplicate fill
            #"{"order":{"id":5,"side":"BUY","status":"CANCELLED","ticker":"X_EQ"}}"#, // no fill
            HistoryFixtures.order(fill: 2, side: "SELL", qty: "1", net: "190", realized: "51.75", at: "2026-06-01T10:00:00Z"),
        ]))
        let parsed = Trading212HistoryParsing.orders(page.items ?? [])
        #expect(parsed.map(\.key) == ["fill:1", "fill:2"])
        #expect(parsed[0].netValue == Decimal(string: "276.5")! && parsed[0].fees == Decimal(string: "0.41")!)
        #expect(parsed[0].side == "BUY" && parsed[0].name == "Apple" && parsed[0].currencyCode == "EUR")
        #expect(parsed[1].realized == Decimal(string: "51.75")!)
    }

    @Test func cashMovementsAreSignedByType() throws {
        let page: T212TransactionPage = try T212Fixtures.decode(HistoryFixtures.page([
            HistoryFixtures.cash("d1", type: "DEPOSIT", amount: "500"),
            HistoryFixtures.cash("w1", type: "WITHDRAW", amount: "100"),
            HistoryFixtures.cash("w2", type: "WITHDRAW", amount: "-50"),
            HistoryFixtures.cash("f1", type: "FEE", amount: "1.2"),
            HistoryFixtures.cash("i1", type: "INTEREST_ON_FREE_CASH", amount: "0.37"),
            HistoryFixtures.cash("t1", type: "TRANSFER", amount: "-20"),
            #"{"amount":5,"type":"DEPOSIT"}"#, // no date
        ]))
        let parsed = Trading212HistoryParsing.transactions(page.items ?? [])
        #expect(parsed.map(\.amount) == [500, -100, -50, Decimal(string: "-1.2")!, Decimal(string: "0.37")!, -20])
    }
}

@Suite("Trading 212 history — robustness")
struct Trading212HistoryRobustnessTests {
    @Test func transactionPagesCarryCursorAndTimeOnly() {
        let query = Trading212Client.pageQuery(nextPagePath: "/api/v0/equity/history/transactions?limit=50&cursor=abc123&time=2026-01-05T09:00:00Z&evil=1")
        #expect(query.map(\.name) == ["limit", "cursor", "time"])
        #expect(query.first { $0.name == "time" }?.value == "2026-01-05T09:00:00Z")
        let bad = Trading212Client.pageQuery(nextPagePath: "/x?cursor=1&time=2026%2F01")
        #expect(bad.map(\.name) == ["limit", "cursor"])
    }

    @Test func lenientTransactionDecoding() throws {
        let page: T212TransactionPage = try T212Fixtures.decode(#"{"items":[{"amount":"12.50","currency":"EUR","dateTime":"2026-01-05T09:00:00Z","reference":123456,"type":"DEPOSIT"}],"nextPagePath":null}"#)
        let parsed = Trading212HistoryParsing.transactions(page.items ?? [])
        #expect(parsed.first?.amount == Decimal(string: "12.5")!)
        #expect(parsed.first?.key == "ref:123456")
    }
}

@Suite("Trading 212 analytics")
struct Trading212AnalyticsTests {
    typealias A = Trading212Analytics
    let now = date("2027-01-01T00:00:00Z")

    func trade(_ id: String, _ at: String, buy: Bool, _ net: Decimal, realized: Decimal = 0, fees: Decimal = 0, ticker: String = "AAPL_US_EQ") -> A.Trade {
        A.Trade(id: id, date: date(at), ticker: ticker, name: ticker == "AAPL_US_EQ" ? "Apple" : "Vanguard", isBuy: buy, quantity: 1,
                price: nil, instrumentCurrency: "USD", netValue: net, fees: fees, realized: realized)
    }

    func cash(_ id: String, _ at: String, _ type: String, _ amount: Decimal) -> A.Cash {
        A.Cash(id: id, date: date(at), type: type, amount: amount)
    }

    var analytics: A {
        A(currency: "EUR",
          trades: [trade("b1", "2026-01-10T10:00:00Z", buy: true, 600, fees: 1),
                   trade("b2", "2026-02-10T10:00:00Z", buy: true, 300, ticker: "VWCE_EQ"),
                   trade("s1", "2026-06-10T10:00:00Z", buy: false, 400, realized: 100)],
          cash: [cash("d1", "2026-01-05T09:00:00Z", "DEPOSIT", 1_000),
                 cash("d2", "2026-03-05T09:00:00Z", "DEPOSIT", 500),
                 cash("w1", "2026-09-05T09:00:00Z", "WITHDRAW", -200),
                 cash("f1", "2026-04-01T09:00:00Z", "FEE", -2),
                 cash("i1", "2026-12-01T09:00:00Z", "INTEREST_ON_FREE_CASH", 3)],
          dividends: [A.Dividend(date: date("2026-08-01T09:00:00Z"), ticker: "VWCE_EQ", name: "Vanguard", amount: 5)],
          positions: [A.Position(ticker: "AAPL_US_EQ", name: "Apple", value: 380, cost: 300, unrealized: 80),
                      A.Position(ticker: "VWCE_EQ", name: "Vanguard", value: 320, cost: 300, unrealized: 20)],
          cashBalance: 700,
          valuePoints: [A.ValuePoint(date: date("2026-12-31T20:00:00Z"), value: 1_400)],
          now: now)
    }

    @Test func totalsAndGain() {
        let a = analytics
        #expect(a.deposited == 1_500 && a.withdrawn == 200 && a.netDeposits == 1_300)
        #expect(a.currentValue == 1_400)
        #expect(a.totalGain == 100)
        #expect(a.gainFraction == Decimal(100) / 1_300)
        #expect(a.fees == 3 && a.interest == 3 && a.dividends == 5 && a.realized == 100 && a.unrealized == 100)
        // 100 unrealized + 100 realized + 5 dividends + 3 interest − 3 fees = 205; the rest is "other".
        #expect(a.explainedGain == 205)
        #expect(a.otherGain == -105)
        #expect(a.bought == 900 && a.sold == 400)
    }

    @Test func timelineTracksDepositsAndCostOfSharesHeld() {
        let points = analytics.timeline
        #expect(points.first?.deposited == 1_000 && points.first?.atCost == 0)
        // After the sale: 600 + 300 − (400 − 100) = 600 at cost.
        let afterSale = points.first { $0.date == date("2026-06-10T10:00:00Z") }
        #expect(afterSale?.atCost == 600 && afterSale?.deposited == 1_500)
        #expect(points.last?.date == now && points.last?.deposited == 1_300)
    }

    @Test func instrumentsIncludeClosedOnesAndDividends() {
        let items = analytics.instruments
        #expect(items.map(\.ticker) == ["AAPL_US_EQ", "VWCE_EQ"])
        let apple = items[0]
        #expect(apple.bought == 600 && apple.sold == 400 && apple.realized == 100 && apple.totalReturn == 180 && apple.trades == 2)
        #expect(items[1].dividends == 5 && items[1].totalReturn == 25)
    }

    @Test func periodTotalsAndMonthlyFlows() {
        let a = analytics
        let year = DateInterval(start: date("2026-01-01T00:00:00Z"), end: date("2027-01-01T00:00:00Z"))
        let t = a.totals(in: year)
        #expect(t.deposited == 1_500 && t.withdrawn == 200 && t.bought == 900 && t.sold == 400 && t.trades == 3)
        #expect(t.fees == 3 && t.dividends == 5 && t.interest == 3 && t.realized == 100)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let months = a.monthlyFlows(months: 12, calendar: utc)
        #expect(months.count == 12)
        #expect(months.reduce(0) { $0 + $1.net } == 300) // Jan 2026 is outside Feb 2026 … Jan 2027
    }

    @Test func xirrMatchesASimpleYear() throws {
        // 1000 in a year ago, worth 1100 today → 10 % a year.
        let start = date("2026-01-01T00:00:00Z")
        let a = A(currency: "EUR", trades: [], cash: [cash("d", "2026-01-01T00:00:00Z", "DEPOSIT", 1_000)], dividends: [],
                  positions: [], cashBalance: 1_100, valuePoints: [], now: start.addingTimeInterval(365.25 * 86_400))
        let rate = try #require(a.moneyWeightedReturn)
        #expect(abs(rate - 0.10) < 1e-6)
        // Too short a history: no annualized figure.
        let short = A(currency: "EUR", trades: [], cash: [cash("d", "2026-01-01T00:00:00Z", "DEPOSIT", 1_000)], dividends: [],
                      positions: [], cashBalance: 1_010, valuePoints: [], now: start.addingTimeInterval(10 * 86_400))
        #expect(short.moneyWeightedReturn == nil)
    }
}

@Suite("Trading 212 history — sync")
@MainActor
struct Trading212HistorySyncTests {
    let container: ModelContainer
    let http = T212MockHTTP()
    let secrets = MemorySecrets()
    let defaults: UserDefaults
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try Persistence.makeInMemoryContainer()
        defaults = UserDefaults(suiteName: "WealthOSTests.t212hist.\(UUID().uuidString)")!
        secrets.values["apiKey"] = "KEY-abc"
        secrets.values["apiSecret"] = "SECRET-xyz"
    }

    func makeService() -> Trading212Service { Trading212Service(http: http, secrets: secrets, defaults: defaults, sleep: { _ in }) }

    @Test func syncStoresTradesCashAndADailyValuePoint() async throws {
        let service = makeService()
        let orderCalls = CallCounter()
        http.handler = { endpoint in
            switch endpoint {
            case .accountSummary: (200, T212Fixtures.summary, [:])
            case .positions: (200, T212Fixtures.positions, [:])
            case .instruments: (200, T212Fixtures.instruments, [:])
            case .dividends: (200, T212Fixtures.noDividends, [:])
            case .orders:
                orderCalls.next() == 1
                    ? (200, HistoryFixtures.page([HistoryFixtures.order(fill: 2, side: "SELL", realized: "10")], next: "/api/v0/equity/history/orders?cursor=7&limit=50"), [:])
                    : (200, HistoryFixtures.page([HistoryFixtures.order(fill: 1, side: "BUY")]), [:])
            case .transactions:
                (200, HistoryFixtures.page([HistoryFixtures.cash("d1", type: "DEPOSIT", amount: "1000"),
                                            HistoryFixtures.cash("w1", type: "WITHDRAW", amount: "50")]), [:])
            }
        }
        #expect(await service.sync(context: context, force: true, now: now))
        #expect(try context.fetchCount(FetchDescriptor<BrokerOrder>()) == 2)
        #expect(try context.fetch(FetchDescriptor<BrokerCashTransaction>()).map(\.amount).sorted() == [-50, 1_000])
        let points = try context.fetch(FetchDescriptor<BrokerValuePoint>())
        // Cash 265 + positions 415.75 + 1084.368.
        #expect(points.count == 1 && points.first?.value == Decimal(string: "1765.12")!)
        #expect(service.historyErrors.isEmpty)

        // A second sync the same day updates the day's point instead of adding one, and adds no duplicates.
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(120)))
        #expect(try context.fetchCount(FetchDescriptor<BrokerValuePoint>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<BrokerOrder>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<BrokerCashTransaction>()) == 2)
    }

    @Test func eachFeedFailsOnItsOwn() async throws {
        let service = makeService()
        http.handler = { endpoint in
            switch endpoint {
            case .accountSummary: (200, T212Fixtures.summary, [:])
            case .positions: (200, T212Fixtures.positions, [:])
            case .instruments: (200, T212Fixtures.instruments, [:])
            case .dividends: (200, T212Fixtures.noDividends, [:])
            case .orders: (403, "{}", [:])
            case .transactions: (200, HistoryFixtures.page([HistoryFixtures.cash("d1", type: "DEPOSIT", amount: "10")]), [:])
            }
        }
        #expect(await service.sync(context: context, force: true, now: now))
        #expect(service.historyErrors == [.orders: .missingPermission])
        #expect(try context.fetchCount(FetchDescriptor<BrokerCashTransaction>()) == 1)
        #expect(service.lastError == nil)
    }

    @Test func disconnectRemovesAllHistory() async throws {
        let service = makeService()
        http.handler = { endpoint in
            switch endpoint {
            case .accountSummary: (200, T212Fixtures.summary, [:])
            case .positions: (200, T212Fixtures.positions, [:])
            case .instruments: (200, T212Fixtures.instruments, [:])
            case .dividends: (200, T212Fixtures.noDividends, [:])
            case .orders: (200, HistoryFixtures.page([HistoryFixtures.order(fill: 1, side: "BUY")]), [:])
            case .transactions: (200, HistoryFixtures.page([HistoryFixtures.cash("d1", type: "DEPOSIT", amount: "10")]), [:])
            }
        }
        #expect(await service.sync(context: context, force: true, now: now))
        try service.disconnect(removeData: true, context: context)
        #expect(try context.fetchCount(FetchDescriptor<BrokerOrder>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BrokerCashTransaction>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BrokerValuePoint>()) == 0)
        #expect(service.historyFetchedAt(.orders) == nil)
    }

    @Test func storeFromBeforeHistoryOpensAndAcceptsIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WealthOS-HistoryMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "WealthOS.store")
        let newTypes: Set<ObjectIdentifier> = [ObjectIdentifier(BrokerDividend.self), ObjectIdentifier(BrokerOrder.self),
                                               ObjectIdentifier(BrokerCashTransaction.self), ObjectIdentifier(BrokerValuePoint.self)]
        do {
            let previous = Schema(Persistence.modelTypes.filter { !newTypes.contains(ObjectIdentifier($0)) })
            let container = try ModelContainer(for: previous, configurations: [ModelConfiguration("WealthOS", schema: previous, url: url,
                                                                                                    cloudKitDatabase: .none)])
            container.mainContext.insert(Account(name: "Swedbank", kind: .checking, currencyCode: "EUR", openingBalance: 99))
            try container.mainContext.save()
        }
        let current = try Persistence.makePersistentContainer(directory: directory)
        let context = current.mainContext
        #expect(try context.fetch(FetchDescriptor<Account>()).map(\.openingBalance) == [99])
        context.insert(BrokerOrder(key: "fill:1", syncedAt: .now))
        context.insert(BrokerCashTransaction(key: "ref:1", syncedAt: .now))
        context.insert(BrokerValuePoint(date: .now, currencyCode: "EUR", value: 1, cash: 1))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<BrokerOrder>()) == 1)
    }
}
