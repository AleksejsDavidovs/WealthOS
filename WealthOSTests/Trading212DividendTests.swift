import Foundation
import SwiftData
import Testing
@testable import WealthOS

private enum DividendFixtures {
    static func item(_ reference: String, ticker: String = "AAPL_US_EQ", name: String = "Apple", amount: String = "1.534999",
                     paidOn: String = "2026-11-14T10:00:00Z") -> String {
        #"{"amount":\#(amount),"amountInEuro":\#(amount),"currency":"EUR","grossAmountPerShare":0.25,"instrument":{"currency":"USD","isin":"US0378331005","name":"\#(name)","ticker":"\#(ticker)"},"paidOn":"\#(paidOn)","quantity":8,"reference":"\#(reference)","ticker":"\#(ticker)","tickerCurrency":"USD","type":"ORDINARY"}"#
    }

    static func page(_ items: [String], next: String?) -> String {
        let nextJSON = next.map { "\"\($0)\"" } ?? "null"
        return #"{"items":[\#(items.joined(separator: ","))],"nextPagePath":\#(nextJSON)}"#
    }
}

@Suite("Trading 212 dividends — parsing and totals")
struct Trading212DividendParsingTests {
    @Test func parsesRoundsAndSkipsMalformedRows() throws {
        let page: T212DividendPage = try T212Fixtures.decode(DividendFixtures.page([
            DividendFixtures.item("r1"),
            DividendFixtures.item("r1"), // duplicate reference
            #"{"amount":2,"ticker":"X_EQ"}"#, // no date
            #"{"amount":0.5,"paidOn":"2026-10-01T00:00:00Z","ticker":"O_US_EQ","currency":"EUR"}"#, // no reference
        ], next: nil))
        let parsed = Trading212DividendParsing.parse(page.items ?? [])
        #expect(parsed.count == 2)
        #expect(parsed[0].key == "ref:r1")
        #expect(parsed[0].amount == Decimal(string: "1.53")!)
        #expect(parsed[0].name == "Apple" && parsed[0].instrumentCurrency == "USD" && parsed[0].quantity == 8)
        #expect(parsed[1].key.hasPrefix("derived:O_US_EQ:"))
    }

    @Test func cursorIsTakenOnlyAsANumber() {
        #expect(Trading212Client.cursor(fromNextPagePath: "/api/v0/equity/history/dividends?limit=50&cursor=1700000000123") == "1700000000123")
        #expect(Trading212Client.cursor(fromNextPagePath: "/api/v0/equity/history/transactions?cursor=abc-12_X") == "abc-12_X")
        #expect(Trading212Client.cursor(fromNextPagePath: "/api/v0/equity/history/dividends?cursor=a%2Fb") == nil)
        #expect(Trading212Client.cursor(fromNextPagePath: "/api/v0/equity/history/dividends?cursor=a%20b") == nil)
        #expect(Trading212Client.cursor(fromNextPagePath: "https://evil.example/x?cursor=1&y=2") == "1") // host is ignored, only the number is used
        #expect(Trading212Client.cursor(fromNextPagePath: nil) == nil)
        #expect(Trading212Client.cursor(fromNextPagePath: "/api/v0/equity/history/dividends") == nil)
    }

    @Test func requestStaysOnTheAllowedHostWithQuery() throws {
        let client = Trading212Client(environment: .live, credentials: Trading212Credentials(apiKey: "k", apiSecret: "s"),
                                      http: T212MockHTTP())
        let request = client.request(for: .dividends, query: [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "cursor", value: "42")])
        #expect(request.url?.absoluteString == "https://live.trading212.com/api/v0/equity/history/dividends?limit=50&cursor=42")
        try Trading212Transport.validate(request)
    }

    func payment(_ date: String, _ amount: Decimal, _ ticker: String) -> DividendPayment {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Riga")!
        let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
        return DividendPayment(id: UUID().uuidString, date: day, amount: amount, ticker: ticker, name: ticker)
    }

    @Test func totalsPerMonthYearAndHolding() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Riga")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 12))!
        let payments = [payment("2026-11-15", 3, "O"), payment("2026-11-08", Decimal(string: "11.5")!, "VUSA"),
                        payment("2026-10-15", 3, "O"), payment("2026-02-08", 11, "VUSA"),
                        payment("2025-12-15", 2, "O"), payment("2025-11-30", 100, "OLD")]
        #expect(DividendStats.thisMonth(payments, now: now, calendar: calendar) == Decimal(string: "14.5")!)
        #expect(DividendStats.thisYear(payments, now: now, calendar: calendar) == Decimal(string: "28.5")!)
        // Dec 2025 … Nov 2026: Nov 2025 is outside.
        #expect(DividendStats.last12Months(payments, now: now, calendar: calendar) == Decimal(string: "30.5")!)
        let months = DividendStats.monthly(payments, now: now, calendar: calendar)
        #expect(months.count == 12)
        #expect(months.last?.total == Decimal(string: "14.5")!)
        #expect(months.first?.total == 2)
        let year = calendar.dateInterval(of: .year, for: now)!
        let holdings = DividendStats.byHolding(payments, in: year)
        #expect(holdings.map(\.ticker) == ["VUSA", "O"])
        #expect(holdings.first?.total == Decimal(string: "22.5")! && holdings.first?.count == 2)
    }

    @Test func convertsToBaseAndReportsMissingRates() {
        let converter = CurrencyConverter(baseCode: "EUR", rates: ["USD": Decimal(string: "0.9")!])
        let now = Date.now
        let result = DividendStats.payments([("a", now, 10, "USD", "AAPL_US_EQ", ""), ("b", now, 5, "EUR", "O_US_EQ", "Realty"),
                                             ("c", now, 7, "GBP", "X_EQ", "X")], converter: converter)
        #expect(result.payments.map(\.amount).sorted() == [5, 9])
        #expect(result.missingRates == ["GBP"])
        #expect(result.payments.first { $0.id == "a" }?.name == "AAPL")
    }
}

@Suite("Trading 212 dividends — sync")
@MainActor
struct Trading212DividendSyncTests {
    let container: ModelContainer
    let http = T212MockHTTP()
    let secrets = MemorySecrets()
    let defaults: UserDefaults
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try Persistence.makeInMemoryContainer()
        defaults = UserDefaults(suiteName: "WealthOSTests.t212div.\(UUID().uuidString)")!
        secrets.values["apiKey"] = "KEY-abc"
        secrets.values["apiSecret"] = "SECRET-xyz"
    }

    func makeService() -> Trading212Service {
        Trading212Service(http: http, secrets: secrets, defaults: defaults, sleep: { _ in })
    }

    var dividends: [BrokerDividend] { (try? context.fetch(FetchDescriptor<BrokerDividend>())) ?? [] }

    func reply(pages: [String]) {
        let calls = CallCounter()
        http.handler = { endpoint in
            switch endpoint {
            case .accountSummary: (200, T212Fixtures.summary, [:])
            case .positions: (200, T212Fixtures.positions, [:])
            case .instruments: (200, T212Fixtures.instruments, [:])
            case .dividends:
                (200, pages[min(calls.next() - 1, pages.count - 1)], [:])
            case .orders, .transactions: (200, T212Fixtures.noDividends, [:])
            }
        }
    }

    @Test func firstSyncWalksAllPagesThenOnlyNewOnes() async {
        let service = makeService()
        reply(pages: [
            DividendFixtures.page([DividendFixtures.item("r3"), DividendFixtures.item("r2")], next: "/api/v0/equity/history/dividends?limit=50&cursor=2"),
            DividendFixtures.page([DividendFixtures.item("r1", ticker: "O_US_EQ", name: "Realty Income")], next: nil),
        ])
        #expect(await service.sync(context: context, force: true, now: now))
        #expect(Set(dividends.map(\.key)) == ["ref:r1", "ref:r2", "ref:r3"])
        #expect(http.count(.dividends) == 2)
        let second = http.requests.filter { $0.url?.path.hasSuffix("/dividends") == true }.last?.url?.query ?? ""
        #expect(second.contains("cursor=2") && second.contains("limit=50"))
        #expect(service.dividendsFetchedAt == now)

        // Next manual sync: page 1 has a new payout and a known one → stops after one page, no duplicates.
        reply(pages: [DividendFixtures.page([DividendFixtures.item("r4"), DividendFixtures.item("r3")], next: "/x?cursor=9")])
        let before = http.count(.dividends)
        #expect(await service.sync(context: context, force: true, now: now.addingTimeInterval(60)))
        #expect(http.count(.dividends) == before + 1)
        #expect(dividends.count == 4)
    }

    @Test func automaticSyncChecksDividendsAtMostEverySixHours() async {
        let service = makeService()
        #expect(await service.sync(context: context, force: true, now: now))
        let afterFirst = http.count(.dividends)
        #expect(await service.sync(context: context, now: now.addingTimeInterval(Trading212Service.staleInterval + 1)))
        #expect(http.count(.dividends) == afterFirst)
        #expect(await service.sync(context: context, now: now.addingTimeInterval(Trading212Service.dividendsInterval + 1)))
        #expect(http.count(.dividends) == afterFirst + 1)
    }

    @Test func missingDividendScopeNeverBreaksTheBalanceSync() async {
        let service = makeService()
        http.handler = { endpoint in
            switch endpoint {
            case .accountSummary: (200, T212Fixtures.summary, [:])
            case .positions: (200, T212Fixtures.positions, [:])
            case .instruments: (200, T212Fixtures.instruments, [:])
            case .dividends: (403, "{}", [:])
            case .orders, .transactions: (200, T212Fixtures.noDividends, [:])
            }
        }
        #expect(await service.sync(context: context, force: true, now: now))
        #expect(service.lastError == nil)
        #expect(!service.needsReconnect)
        #expect(service.dividendError == .missingPermission)
        #expect((try? context.fetchCount(FetchDescriptor<BrokerPosition>())) == 2)
        // Automatic syncs don't retry a missing scope.
        let calls = http.count(.dividends)
        #expect(await service.sync(context: context, now: now.addingTimeInterval(Trading212Service.dividendsInterval + 1)))
        #expect(http.count(.dividends) == calls)
    }

    @Test func disconnectWithDataRemovalDeletesDividends() async throws {
        let service = makeService()
        reply(pages: [DividendFixtures.page([DividendFixtures.item("r1")], next: nil)])
        #expect(await service.sync(context: context, force: true, now: now))
        #expect(dividends.count == 1)
        try service.disconnect(removeData: true, context: context)
        #expect(dividends.isEmpty)
        #expect(service.dividendsFetchedAt == nil)
    }
}

@Suite("Dividends migration")
@MainActor
struct DividendMigrationTests {
    @Test func storeFromBeforeDividendsOpensAndAcceptsDividends() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WealthOS-DividendMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "WealthOS.store")
        do {
            let previous = Schema(Persistence.modelTypes.filter { ObjectIdentifier($0) != ObjectIdentifier(BrokerDividend.self) })
            let container = try ModelContainer(for: previous, configurations: [ModelConfiguration("WealthOS", schema: previous, url: url,
                                                                                                    cloudKitDatabase: .none)])
            let context = container.mainContext
            context.insert(Account(name: "Swedbank", kind: .checking, currencyCode: "EUR", openingBalance: 1_234))
            context.insert(BrokerPosition(ticker: "AAPL_US_EQ", syncedAt: .now))
            context.insert(Budget(categoryID: nil, amount: 500))
            try context.save()
        }
        let current = try Persistence.makePersistentContainer(directory: directory)
        let context = current.mainContext
        #expect(try context.fetch(FetchDescriptor<Account>()).map(\.openingBalance) == [1_234])
        #expect(try context.fetchCount(FetchDescriptor<BrokerPosition>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Budget>()) == 1)
        context.insert(BrokerDividend(key: "ref:x", syncedAt: .now))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<BrokerDividend>()) == 1)
    }
}
