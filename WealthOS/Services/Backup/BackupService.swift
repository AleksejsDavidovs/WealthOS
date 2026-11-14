import Foundation
import SwiftData

enum BackupService {
    static let fileExtension = "wosbackup"

    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: Export

    static func makePayload(from context: ModelContext, baseCurrency: String, now: Date = .now) throws -> BackupPayload {
        BackupPayload(
            createdAt: now,
            appVersion: appVersion,
            baseCurrency: baseCurrency,
            accounts: try context.fetch(FetchDescriptor<Account>()).map {
                .init(id: $0.id, name: $0.name, kind: $0.kindRaw, currencyCode: $0.currencyCode,
                      openingBalance: $0.openingBalance, openingDate: $0.openingDate, institution: $0.institution,
                      notes: $0.notes, colorName: $0.colorName, isArchived: $0.isArchived, sortOrder: $0.sortOrder,
                      createdAt: $0.createdAt)
            },
            transactions: try context.fetch(FetchDescriptor<TransactionRecord>()).map {
                .init(id: $0.id, kind: $0.kindRaw, amount: $0.amount, destinationAmount: $0.destinationAmount,
                      date: $0.date, note: $0.note, accountID: $0.accountID, destinationAccountID: $0.destinationAccountID,
                      categoryID: $0.categoryID, recurringRuleID: $0.recurringRuleID,
                      importFingerprint: $0.importFingerprint, createdAt: $0.createdAt)
            },
            categories: try context.fetch(FetchDescriptor<TransactionCategory>()).map {
                .init(id: $0.id, name: $0.name, kind: $0.kindRaw, symbol: $0.symbol, colorName: $0.colorName,
                      isSystem: $0.isSystem, sortOrder: $0.sortOrder, createdAt: $0.createdAt)
            },
            recurringRules: try context.fetch(FetchDescriptor<RecurringRule>()).map {
                .init(id: $0.id, kind: $0.kindRaw, amount: $0.amount, destinationAmount: $0.destinationAmount,
                      accountID: $0.accountID, destinationAccountID: $0.destinationAccountID, categoryID: $0.categoryID,
                      note: $0.note, frequency: $0.frequencyRaw, startDate: $0.startDate, endDate: $0.endDate,
                      generatedCount: $0.generatedCount, isActive: $0.isActive, createdAt: $0.createdAt)
            },
            holdings: try context.fetch(FetchDescriptor<Holding>()).map {
                .init(id: $0.id, name: $0.name, symbol: $0.symbol, assetClass: $0.assetClassRaw,
                      currencyCode: $0.currencyCode, currentPrice: $0.currentPrice, priceUpdatedAt: $0.priceUpdatedAt,
                      accountID: $0.accountID, notes: $0.notes, createdAt: $0.createdAt,
                      marketSymbol: $0.marketSymbol, marketCurrencyCode: $0.marketCurrencyCode,
                      priceSource: $0.priceSourceRaw, autoApplyMarketPrice: $0.autoApplyMarketPrice)
            },
            trades: try context.fetch(FetchDescriptor<InvestmentTrade>()).map {
                .init(id: $0.id, holdingID: $0.holdingID, kind: $0.kindRaw, date: $0.date, quantity: $0.quantity,
                      pricePerUnit: $0.pricePerUnit, fee: $0.fee, cashAccountID: $0.cashAccountID,
                      cashAmount: $0.cashAmount, note: $0.note, createdAt: $0.createdAt)
            },
            pricePoints: try context.fetch(FetchDescriptor<PricePoint>()).map {
                .init(id: $0.id, holdingID: $0.holdingID, date: $0.date, price: $0.price)
            },
            rates: try context.fetch(FetchDescriptor<CurrencyRate>()).map {
                .init(code: $0.code, rateToBase: $0.rateToBase, updatedAt: $0.updatedAt, source: $0.sourceRaw)
            },
            snapshots: try context.fetch(FetchDescriptor<NetWorthSnapshot>()).map {
                .init(id: $0.id, date: $0.date, netWorth: $0.netWorth, liquidTotal: $0.liquidTotal,
                      investmentTotal: $0.investmentTotal, otherAssetsTotal: $0.otherAssetsTotal,
                      liabilitiesTotal: $0.liabilitiesTotal, source: $0.sourceRaw, currencyCode: $0.currencyCode,
                      note: $0.note)
            },
            goals: try context.fetch(FetchDescriptor<Goal>()).map {
                .init(id: $0.id, name: $0.name, type: $0.typeRaw, targetAmount: $0.targetAmount, targetDate: $0.targetDate,
                      allocatedAmount: $0.allocatedAmount, monthlyContribution: $0.monthlyContribution,
                      colorName: $0.colorName, notes: $0.notes, createdAt: $0.createdAt)
            },
            scenarios: try context.fetch(FetchDescriptor<SimulationScenario>()).compactMap { scenario in
                guard let parameters = scenario.parameters else { return nil }
                return .init(id: scenario.id, kind: scenario.kindRaw, name: scenario.name, parameters: parameters,
                             updatedAt: scenario.updatedAt)
            },
            external: try externalPayload(from: context)
        )
    }

    /// Non-secret provider caches and links. API keys and secrets live only in the Keychain
    /// and are never read here. Links to records that no longer exist are dropped.
    static func externalPayload(from context: ModelContext) throws -> BackupPayload.ExternalDTO? {
        let localIDs = Set(try context.fetch(FetchDescriptor<Account>()).map(\.id) + context.fetch(FetchDescriptor<Holding>()).map(\.id))
        func links(_ items: [(kind: String, localID: UUID, createdAt: Date)]) -> [BackupPayload.LinkDTO] {
            items.filter { localIDs.contains($0.localID) }.map { .init(kind: $0.kind, localID: $0.localID, createdAt: $0.createdAt) }
        }
        let t212Snapshot = try context.fetch(FetchDescriptor<BrokerAccountSnapshot>()).first
        let t212Positions = try context.fetch(FetchDescriptor<BrokerPosition>())
        let t212Links = links(try context.fetch(FetchDescriptor<BrokerLink>()).map { ($0.kindRaw, $0.localID, $0.createdAt) })
        let binanceSnapshot = try context.fetch(FetchDescriptor<BinanceAccountSnapshot>()).first
        let binanceHoldings = try context.fetch(FetchDescriptor<BinanceHolding>())
        let binanceLinks = links(try context.fetch(FetchDescriptor<BinanceLink>()).map { ($0.kindRaw, $0.localID, $0.createdAt) })

        let t212: BackupPayload.Trading212DTO? = (t212Snapshot == nil && t212Links.isEmpty) ? nil : .init(
            snapshot: t212Snapshot.map {
                .init(environment: $0.environmentRaw, accountNumber: $0.accountNumber, currencyCode: $0.currencyCode,
                      cashAvailable: $0.cashAvailable, cashInPies: $0.cashInPies, cashReserved: $0.cashReserved,
                      investmentsValue: $0.investmentsValue, investmentsCost: $0.investmentsCost,
                      unrealizedProfitLoss: $0.unrealizedProfitLoss, realizedProfitLoss: $0.realizedProfitLoss,
                      reportedTotal: $0.reportedTotal, syncedAt: $0.syncedAt)
            },
            positions: t212Snapshot == nil ? [] : t212Positions.map {
                .init(ticker: $0.ticker, name: $0.name, shortName: $0.shortName, instrumentType: $0.instrumentType, isin: $0.isin,
                      instrumentCurrency: $0.instrumentCurrency, quantity: $0.quantity, averagePrice: $0.averagePrice,
                      currentPrice: $0.currentPrice, valueCurrency: $0.valueCurrency, currentValue: $0.currentValue,
                      totalCost: $0.totalCost, unrealizedProfitLoss: $0.unrealizedProfitLoss, fxImpact: $0.fxImpact,
                      openedAt: $0.openedAt, syncedAt: $0.syncedAt)
            },
            links: t212Links)
        let binance: BackupPayload.BinanceDTO? = (binanceSnapshot == nil && binanceLinks.isEmpty) ? nil : .init(
            snapshot: binanceSnapshot.map {
                .init(uid: $0.uid, accountType: $0.accountType, syncedAt: $0.syncedAt,
                      flexibleStatus: $0.flexibleStatusRaw, flexibleSyncedAt: $0.flexibleSyncedAt,
                      lockedStatus: $0.lockedStatusRaw, lockedSyncedAt: $0.lockedSyncedAt,
                      pricesFetchedAt: $0.pricesFetchedAt, mergedSpotAssets: $0.mergedSpotAssets)
            },
            holdings: binanceSnapshot == nil ? [] : binanceHoldings.map {
                .init(key: $0.key, asset: $0.asset, wallet: $0.walletRaw, productRef: $0.productRef, free: $0.free,
                      locked: $0.locked, amount: $0.amount, priceEUR: $0.priceEUR, priceRoute: $0.priceRoute,
                      pricedAt: $0.pricedAt, syncedAt: $0.syncedAt)
            },
            links: binanceLinks)
        return (t212 == nil && binance == nil) ? nil : .init(trading212: t212, binance: binance)
    }

    /// Encodes and encrypts the database. Returns the encrypted bytes.
    static func encryptedBackup(from context: ModelContext, baseCurrency: String, password: String) async throws -> Data {
        let payload = try makePayload(from: context, baseCurrency: baseCurrency)
        let json = try BackupPayload.encoder().encode(payload)
        return try await BackupCrypto.encryptInBackground(json, password: password)
    }

    /// Writes data to a protected temporary file suitable for sharing.
    static func writeTemporaryFile(_ data: Data, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func cleanTemporaryExports() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directory)
    }

    static func backupFileName(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "WealthOS-Backup-\(formatter.string(from: date)).\(fileExtension)"
    }

    // MARK: Import

    /// Decrypts, decodes and validates a backup. Does not modify any data.
    static func readBackup(_ data: Data, password: String) async throws -> BackupPayload {
        let json = try await BackupCrypto.decryptInBackground(data, password: password)
        let payload: BackupPayload
        do {
            payload = try BackupPayload.decoder().decode(BackupPayload.self, from: json)
        } catch {
            throw BackupValidationError.invalidValue("unreadable backup contents")
        }
        try payload.validate()
        return payload
    }

    /// Replaces all data with the payload — ledger *and* provider caches and links, so nothing
    /// from the device's previous state is mixed into the restored one. The payload is
    /// validated first and every change happens in one save; on any failure the context is
    /// rolled back so the existing data stays intact.
    ///
    /// - Version 1 backups contain no provider data: caches and links are cleared and are
    ///   rebuilt by the next sync of a connected provider.
    /// - Version 2 provider snapshots are restored flagged `restoredFromBackup` (shown as
    ///   unverified) until the next successful sync. Credentials are never part of a backup.
    /// - Parameter save: injectable for tests; always `context.save()` in the app.
    static func restore(_ payload: BackupPayload, into context: ModelContext,
                        save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        try payload.validate()
        let wasAutosaving = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = wasAutosaving }
        do {
            try LedgerService.deleteAllData(in: context)
            try Trading212Reconciler.removeAllData(in: context)
            try BinanceReconciler.removeAllData(in: context)
            insert(payload, into: context)
            insertExternal(payload, into: context)
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    static func insertExternal(_ payload: BackupPayload, into context: ModelContext) {
        guard let external = payload.external else { return }
        let localIDs = Set(payload.accounts.map(\.id) + payload.holdings.map(\.id))
        if let t212 = external.trading212 {
            if let s = t212.snapshot {
                let snapshot = BrokerAccountSnapshot(environment: Trading212Environment(rawValue: s.environment) ?? .live,
                                                     currencyCode: s.currencyCode, syncedAt: s.syncedAt)
                snapshot.accountNumber = s.accountNumber
                snapshot.cashAvailable = s.cashAvailable
                snapshot.cashInPies = s.cashInPies
                snapshot.cashReserved = s.cashReserved
                snapshot.investmentsValue = s.investmentsValue
                snapshot.investmentsCost = s.investmentsCost
                snapshot.unrealizedProfitLoss = s.unrealizedProfitLoss
                snapshot.realizedProfitLoss = s.realizedProfitLoss
                snapshot.reportedTotal = s.reportedTotal
                snapshot.restoredFromBackup = true
                context.insert(snapshot)
                for p in t212.positions {
                    let row = BrokerPosition(ticker: p.ticker, syncedAt: p.syncedAt)
                    row.name = p.name
                    row.shortName = p.shortName
                    row.instrumentType = p.instrumentType
                    row.isin = p.isin
                    row.instrumentCurrency = p.instrumentCurrency
                    row.quantity = p.quantity
                    row.averagePrice = p.averagePrice
                    row.currentPrice = p.currentPrice
                    row.valueCurrency = p.valueCurrency
                    row.currentValue = p.currentValue
                    row.totalCost = p.totalCost
                    row.unrealizedProfitLoss = p.unrealizedProfitLoss
                    row.fxImpact = p.fxImpact
                    row.openedAt = p.openedAt
                    context.insert(row)
                }
            }
            for link in t212.links where localIDs.contains(link.localID) {
                context.insert(BrokerLink(kind: BrokerLink.Kind(rawValue: link.kind) ?? .holding, localID: link.localID,
                                          createdAt: link.createdAt))
            }
        }
        if let binance = external.binance {
            if let s = binance.snapshot {
                let snapshot = BinanceAccountSnapshot(syncedAt: s.syncedAt)
                snapshot.uid = s.uid
                snapshot.accountType = s.accountType
                snapshot.flexibleStatusRaw = s.flexibleStatus
                snapshot.flexibleSyncedAt = s.flexibleSyncedAt
                snapshot.lockedStatusRaw = s.lockedStatus
                snapshot.lockedSyncedAt = s.lockedSyncedAt
                snapshot.pricesFetchedAt = s.pricesFetchedAt
                snapshot.mergedSpotAssets = s.mergedSpotAssets
                snapshot.restoredFromBackup = true
                context.insert(snapshot)
                for h in binance.holdings {
                    let row = BinanceHolding(key: h.key, asset: h.asset, wallet: BinanceWallet(rawValue: h.wallet) ?? .spot,
                                             syncedAt: h.syncedAt)
                    row.productRef = h.productRef
                    row.free = h.free
                    row.locked = h.locked
                    row.amount = h.amount
                    row.priceEUR = h.priceEUR
                    row.priceRoute = h.priceRoute
                    row.pricedAt = h.pricedAt
                    context.insert(row)
                }
            }
            for link in binance.links where localIDs.contains(link.localID) {
                context.insert(BinanceLink(kind: BrokerLink.Kind(rawValue: link.kind) ?? .holding, localID: link.localID,
                                           createdAt: link.createdAt))
            }
        }
    }

    static func insert(_ payload: BackupPayload, into context: ModelContext) {
        for a in payload.accounts {
            context.insert(Account(id: a.id, name: a.name, kind: AccountKind(rawValue: a.kind) ?? .otherAsset,
                                   currencyCode: a.currencyCode, openingBalance: a.openingBalance, openingDate: a.openingDate,
                                   institution: a.institution, notes: a.notes, colorName: a.colorName,
                                   isArchived: a.isArchived, sortOrder: a.sortOrder, createdAt: a.createdAt))
        }
        for t in payload.transactions {
            context.insert(TransactionRecord(id: t.id, kind: TransactionKind(rawValue: t.kind) ?? .expense, amount: t.amount,
                                             destinationAmount: t.destinationAmount, date: t.date, note: t.note,
                                             accountID: t.accountID, destinationAccountID: t.destinationAccountID,
                                             categoryID: t.categoryID, recurringRuleID: t.recurringRuleID,
                                             importFingerprint: t.importFingerprint, createdAt: t.createdAt))
        }
        for c in payload.categories {
            context.insert(TransactionCategory(id: c.id, name: c.name, kind: CategoryKind(rawValue: c.kind) ?? .expense,
                                               symbol: c.symbol, colorName: c.colorName, isSystem: c.isSystem,
                                               sortOrder: c.sortOrder, createdAt: c.createdAt))
        }
        for r in payload.recurringRules {
            context.insert(RecurringRule(id: r.id, kind: TransactionKind(rawValue: r.kind) ?? .expense, amount: r.amount,
                                         destinationAmount: r.destinationAmount, accountID: r.accountID,
                                         destinationAccountID: r.destinationAccountID, categoryID: r.categoryID,
                                         note: r.note, frequency: RecurrenceFrequency(rawValue: r.frequency) ?? .monthly,
                                         startDate: r.startDate, endDate: r.endDate, generatedCount: r.generatedCount,
                                         isActive: r.isActive, createdAt: r.createdAt))
        }
        for h in payload.holdings {
            context.insert(Holding(id: h.id, name: h.name, symbol: h.symbol, assetClass: AssetClass(rawValue: h.assetClass) ?? .other,
                                   currencyCode: h.currencyCode, currentPrice: h.currentPrice, priceUpdatedAt: h.priceUpdatedAt,
                                   accountID: h.accountID, notes: h.notes, createdAt: h.createdAt,
                                   marketSymbol: h.marketSymbol ?? "", marketCurrencyCode: h.marketCurrencyCode ?? "",
                                   priceSource: PriceSource(rawValue: h.priceSource ?? "") ?? .manual,
                                   autoApplyMarketPrice: h.autoApplyMarketPrice ?? false))
        }
        for t in payload.trades {
            context.insert(InvestmentTrade(id: t.id, holdingID: t.holdingID, kind: TradeKind(rawValue: t.kind) ?? .buy,
                                           date: t.date, quantity: t.quantity, pricePerUnit: t.pricePerUnit, fee: t.fee,
                                           cashAccountID: t.cashAccountID, cashAmount: t.cashAmount, note: t.note,
                                           createdAt: t.createdAt))
        }
        for p in payload.pricePoints {
            context.insert(PricePoint(id: p.id, holdingID: p.holdingID, date: p.date, price: p.price))
        }
        for r in payload.rates {
            context.insert(CurrencyRate(code: r.code, rateToBase: r.rateToBase, updatedAt: r.updatedAt,
                                        source: PriceSource(rawValue: r.source ?? "") ?? .manual))
        }
        for s in payload.snapshots {
            context.insert(NetWorthSnapshot(id: s.id, date: s.date, netWorth: s.netWorth, liquidTotal: s.liquidTotal,
                                            investmentTotal: s.investmentTotal, otherAssetsTotal: s.otherAssetsTotal,
                                            liabilitiesTotal: s.liabilitiesTotal,
                                            source: SnapshotSource(rawValue: s.source) ?? .manual,
                                            currencyCode: s.currencyCode, note: s.note))
        }
        for g in payload.goals {
            context.insert(Goal(id: g.id, name: g.name, type: GoalType(rawValue: g.type) ?? .custom, targetAmount: g.targetAmount,
                                targetDate: g.targetDate, allocatedAmount: g.allocatedAmount,
                                monthlyContribution: g.monthlyContribution, colorName: g.colorName, notes: g.notes,
                                createdAt: g.createdAt))
        }
        for s in payload.scenarios {
            context.insert(SimulationScenario(id: s.id, kind: ScenarioKind(rawValue: s.kind) ?? .balanced, name: s.name,
                                              parameters: s.parameters, updatedAt: s.updatedAt))
        }
    }

    // MARK: Integrity

    struct IntegrityReport {
        var issues: [String] = []
        var isHealthy: Bool { issues.isEmpty }
    }

    /// Checks the live database for broken references and impossible values.
    static func integrityReport(for context: ModelContext, baseCurrency: String) -> IntegrityReport {
        var report = IntegrityReport()
        do {
            let payload = try makePayload(from: context, baseCurrency: baseCurrency)
            try payload.validate()
            let accountCurrencies = Set(payload.accounts.map(\.currencyCode) + payload.holdings.map(\.currencyCode))
            let rated = Set(payload.rates.map(\.code) + [baseCurrency])
            for missing in accountCurrencies.subtracting(rated).sorted() {
                report.issues.append("No exchange rate for \(missing); those balances are excluded from totals.")
            }
        } catch {
            report.issues.append(error.localizedDescription)
        }
        return report
    }
}
