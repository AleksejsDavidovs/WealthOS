import Foundation
import SwiftData
import Testing
@testable import WealthOS

@MainActor
@Suite("Backup & restore")
struct BackupTests {
    private func populatedContainer() throws -> ModelContainer {
        let container = try Persistence.makeInMemoryContainer()
        let context = container.mainContext
        LedgerService.seedDefaultCategoriesIfNeeded(in: context)
        let checking = Account(name: "Checking", kind: .checking, currencyCode: "EUR", openingBalance: Decimal(string: "1234.56")!)
        let savings = Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 0)
        context.insert(checking); context.insert(savings)
        let food = try context.fetch(FetchDescriptor<TransactionCategory>()).first { $0.name == "Food" }
        context.insert(TransactionRecord(kind: .expense, amount: Decimal(string: "12.34")!, date: .now, note: "Lunch",
                                         accountID: checking.id, categoryID: food?.id))
        context.insert(TransactionRecord(kind: .transfer, amount: 100, date: .now, accountID: checking.id, destinationAccountID: savings.id))
        let holding = Holding(name: "ETF", symbol: "ETF", assetClass: .etf, currencyCode: "USD", currentPrice: 110, priceUpdatedAt: .now)
        context.insert(holding)
        context.insert(InvestmentTrade(holdingID: holding.id, kind: .buy, date: .now, quantity: Decimal(string: "1.5")!, pricePerUnit: 100,
                                       cashAccountID: checking.id, cashAmount: 135))
        context.insert(CurrencyRate(code: "USD", rateToBase: Decimal(string: "0.9")!))
        context.insert(Goal(name: "Trip", type: .travel, targetAmount: 3_000, allocatedAmount: 500))
        context.insert(SimulationScenario(kind: .balanced, name: "Balanced",
                                          parameters: .preset(.balanced, startingCash: 1_000, startingInvestments: 0,
                                                              monthlyIncome: 3_000, monthlyExpenses: 2_000)))
        try context.save()
        return container
    }

    @Test func encryptDecryptRoundTrip() throws {
        let plaintext = Data("sensitive financial data".utf8)
        let encrypted = try BackupCrypto.encrypt(plaintext, password: "correct horse", iterations: 10_000)
        #expect(!encrypted.contains(plaintext.prefix(9)))
        #expect(try BackupCrypto.decrypt(encrypted, password: "correct horse") == plaintext)
    }

    @Test func wrongPasswordFails() throws {
        let encrypted = try BackupCrypto.encrypt(Data("x".utf8), password: "password-1", iterations: 10_000)
        #expect(throws: BackupCryptoError.wrongPasswordOrCorrupted) {
            try BackupCrypto.decrypt(encrypted, password: "password-2")
        }
    }

    @Test func tamperingIsDetected() throws {
        var encrypted = try BackupCrypto.encrypt(Data("hello world".utf8), password: "password-1", iterations: 10_000)
        encrypted[encrypted.count - 5] ^= 0xFF
        #expect(throws: BackupCryptoError.wrongPasswordOrCorrupted) {
            try BackupCrypto.decrypt(encrypted, password: "password-1")
        }
        var header = try BackupCrypto.encrypt(Data("hello world".utf8), password: "password-1", iterations: 10_000)
        header[12] ^= 0x01 // salt byte, authenticated as associated data
        #expect(throws: BackupCryptoError.wrongPasswordOrCorrupted) {
            try BackupCrypto.decrypt(header, password: "password-1")
        }
    }

    @Test func shortPasswordsAndGarbageAreRejected() {
        #expect(throws: BackupCryptoError.passwordTooShort) { try BackupCrypto.encrypt(Data(), password: "short") }
        #expect(throws: BackupCryptoError.notABackup) { try BackupCrypto.decrypt(Data("not a backup at all, definitely".utf8), password: "whatever1") }
    }

    @Test func saltMakesEachBackupUnique() throws {
        let a = try BackupCrypto.encrypt(Data("same".utf8), password: "password-1", iterations: 10_000)
        let b = try BackupCrypto.encrypt(Data("same".utf8), password: "password-1", iterations: 10_000)
        #expect(a != b)
    }

    @Test func fullBackupRestoreRoundTrip() throws {
        let source = try populatedContainer()
        let payload = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR")
        try payload.validate()
        let json = try BackupPayload.encoder().encode(payload)
        let encrypted = try BackupCrypto.encrypt(json, password: "backup-password", iterations: 10_000)
        let decoded = try BackupPayload.decoder().decode(BackupPayload.self, from: try BackupCrypto.decrypt(encrypted, password: "backup-password"))

        let target = try Persistence.makeInMemoryContainer()
        target.mainContext.insert(Account(name: "Old", kind: .cash, currencyCode: "EUR", openingBalance: 1))
        try target.mainContext.save()
        try BackupService.restore(decoded, into: target.mainContext)

        let restored = try BackupService.makePayload(from: target.mainContext, baseCurrency: "EUR")
        #expect(Set(restored.accounts.map(\.id)) == Set(payload.accounts.map(\.id)))
        #expect(Set(restored.transactions.map(\.id)) == Set(payload.transactions.map(\.id)))
        #expect(restored.transactions.map(\.amount).reduce(0, +) == payload.transactions.map(\.amount).reduce(0, +))
        #expect(restored.trades.first?.quantity == Decimal(string: "1.5"))
        #expect(restored.goals.count == 1)
        #expect(restored.scenarios.first?.parameters == payload.scenarios.first?.parameters)
        #expect(!restored.accounts.contains { $0.name == "Old" })

        // Net worth is identical after restore.
        let before = DataMaintenance.makeEngine(context: source.mainContext, baseCurrency: "EUR").summary.netWorth
        let after = DataMaintenance.makeEngine(context: target.mainContext, baseCurrency: "EUR").summary.netWorth
        #expect(before == after)
    }

    @Test func invalidBackupDoesNotTouchExistingData() throws {
        let source = try populatedContainer()
        var payload = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR")
        payload.transactions[0].accountID = UUID() // broken reference

        let target = try populatedContainer()
        let countBefore = try target.mainContext.fetchCount(FetchDescriptor<TransactionRecord>())
        #expect(throws: BackupValidationError.self) {
            try BackupService.restore(payload, into: target.mainContext)
        }
        #expect(try target.mainContext.fetchCount(FetchDescriptor<TransactionRecord>()) == countBefore)
        #expect(try target.mainContext.fetchCount(FetchDescriptor<Account>()) == 2)
    }

    @Test func validationCatchesDuplicatesAndOverselling() throws {
        let source = try populatedContainer()
        var duplicate = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR")
        duplicate.accounts.append(duplicate.accounts[0])
        #expect(throws: BackupValidationError.self) { try duplicate.validate() }

        var oversell = try BackupService.makePayload(from: source.mainContext, baseCurrency: "EUR")
        var sell = oversell.trades[0]
        sell.id = UUID()
        sell.kind = TradeKind.sell.rawValue
        sell.quantity = 10
        sell.date = sell.date.addingTimeInterval(60)
        oversell.trades.append(sell)
        #expect(throws: BackupValidationError.self) { try oversell.validate() }
    }

    @Test func integrityReportIsHealthyForConsistentData() throws {
        let container = try populatedContainer()
        #expect(BackupService.integrityReport(for: container.mainContext, baseCurrency: "EUR").isHealthy)
    }
}

@MainActor
@Suite("CSV import & export")
struct CSVTests {
    @Test func parsesQuotedFieldsAndSemicolons() {
        let rows = CSVParser.parse("a,b,c\n\"hello, world\",\"say \"\"hi\"\"\",3\r\n")
        #expect(rows == [["a", "b", "c"], ["hello, world", "say \"hi\"", "3"]])
        let semi = CSVParser.parse("date;amount;account\n2026-01-02;12,50;Main\n")
        #expect(semi[1] == ["2026-01-02", "12,50", "Main"])
    }

    @Test func escapesFormulaInjection() {
        #expect(CSVParser.escape("=SUM(A1)") == "'=SUM(A1)")
        #expect(CSVParser.escape("-12.5") == "-12.5")
        #expect(CSVParser.escape("a,b") == "\"a,b\"")
    }

    @Test func exportThenImportDetectsDuplicates() throws {
        let container = try Persistence.makeInMemoryContainer()
        let context = container.mainContext
        LedgerService.seedDefaultCategoriesIfNeeded(in: context)
        let account = Account(name: "Main", kind: .checking, currencyCode: "EUR", openingBalance: 0)
        let savings = Account(name: "Savings", kind: .savings, currencyCode: "EUR", openingBalance: 0)
        context.insert(account); context.insert(savings)
        let categories = try context.fetch(FetchDescriptor<TransactionCategory>())
        let date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
        context.insert(TransactionRecord(kind: .expense, amount: Decimal(string: "4.50")!, date: date, note: "Coffee, large",
                                         accountID: account.id, categoryID: categories.first { $0.name == "Food" }?.id))
        context.insert(TransactionRecord(kind: .income, amount: 3_000, date: date, note: "Salary", accountID: account.id,
                                         categoryID: categories.first { $0.name == "Salary" }?.id))
        context.insert(TransactionRecord(kind: .transfer, amount: 200, date: date, accountID: account.id, destinationAccountID: savings.id))
        try context.save()

        let transactions = try context.fetch(FetchDescriptor<TransactionRecord>())
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let csv = CSVService.export(transactions: transactions, accounts: accounts, categories: categories)
        let data = Data(csv.utf8)

        let duplicatePreview = try CSVService.preview(data: data, accounts: accounts, categories: categories,
                                                      existing: transactions, importedHashes: [])
        #expect(duplicatePreview.rows.isEmpty)
        #expect(duplicatePreview.duplicates.count == 3)
        #expect(duplicatePreview.errors.isEmpty)

        let freshPreview = try CSVService.preview(data: data, accounts: accounts, categories: categories,
                                                  existing: [], importedHashes: [CSVService.fileHash(data)])
        #expect(freshPreview.rows.count == 3)
        #expect(freshPreview.fileAlreadyImported)
        #expect(freshPreview.rows.contains { $0.note == "Coffee, large" && $0.amount == Decimal(string: "4.50") })
    }

    @Test func invalidRowsAreReportedNotImported() throws {
        let container = try Persistence.makeInMemoryContainer()
        let context = container.mainContext
        let account = Account(name: "Main", kind: .checking, currencyCode: "EUR", openingBalance: 0)
        context.insert(account)
        try context.save()
        let csv = """
        date,type,amount,account,category,note
        2026-02-01,expense,12.50,Main,Groceries,ok
        not-a-date,expense,1,Main,,bad date
        2026-02-02,expense,abc,Main,,bad amount
        2026-02-03,expense,5,Unknown,,bad account
        2026-02-04,transfer,5,Main,,no destination
        2026-02-05,expense,1.999,Main,,too many decimals
        """
        let preview = try CSVService.preview(data: Data(csv.utf8), accounts: [account], categories: [], existing: [], importedHashes: [])
        #expect(preview.rows.count == 1)
        #expect(preview.errors.count == 5)
        #expect(preview.newCategories == ["Groceries"])

        let imported = try CSVService.commit(preview, into: context)
        #expect(imported == 1)
        let categories = try context.fetch(FetchDescriptor<TransactionCategory>())
        #expect(categories.contains { $0.name == "Groceries" })
    }

    @Test func missingColumnsThrow() {
        #expect(throws: CSVService.ImportError.self) {
            try CSVService.preview(data: Data("foo,bar\n1,2\n".utf8), accounts: [], categories: [], existing: [], importedHashes: [])
        }
    }
}
