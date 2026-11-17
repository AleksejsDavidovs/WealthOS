import Foundation
import Observation
import SwiftData

/// Owns bank connections: backend client credentials (Keychain only), the authorization flow,
/// account linking and read-only sync. Every per-account sync either fully succeeds in one save
/// or changes nothing, so the last confirmed balance and history are never lost or zeroed.
@MainActor
@Observable
final class BankingService {
    private(set) var credentialState: CredentialState = .missing
    private(set) var protectionUpgradeFailed = false
    private(set) var backendURLString: String
    private(set) var isSyncing = false
    private(set) var isConnecting = false
    private(set) var lastError: BankingError?
    private(set) var lastFailureAt: Date?
    /// Most recent per-account failure, keyed by `BankAccountLink.id` (in memory only).
    private(set) var accountErrors: [UUID: BankingError] = [:]
    private(set) var lastOutcome: BankReconciler.Outcome?

    /// Automatic syncs only run when data is older than this. PSD2 banks limit unattended
    /// account-information requests per day, so this is deliberately conservative.
    static let staleInterval: TimeInterval = 6 * 3600
    /// Manual "Sync Now" can't be pressed into a request storm.
    static let minimumInterval: TimeInterval = 60
    /// Each sync re-reads this many days before the previous sync to catch late bookings.
    static let overlapDays = 14
    /// History imported for an account WealthOS creates from a bank account (nothing to
    /// double-count: it wasn't tracked by hand). Linking an existing account keeps the user's choice.
    static let newAccountHistoryDays = 90
    /// Attempts older than this are refused; the backend expires them as well.
    static let attemptLifetime: TimeInterval = 15 * 60
    /// Consent validity requested at the bank (the backend caps it at the bank's maximum).
    static let backendURLKey = "bankingBackendURL"

    private let secrets: SecretStore
    private let defaults: UserDefaults
    private let makeHTTP: @Sendable (String) -> BankingHTTPClient
    private var pendingAttempt: (id: String, startedAt: Date)?
    private var lastAttemptAt: Date?
    /// A sync was requested while one was running (e.g. a second account was added mid-sync).
    private var rerunRequested = false
    private(set) var automaticRetryAfter: Date?
    /// Bumped by disconnect, so a sync in flight can't write its result afterwards.
    private var generation = 0
    var calendar: Calendar = .current
    /// Injectable for tests (e.g. a failing disk); always `context.save()` in the app.
    var saveContext: (ModelContext) throws -> Void = { try $0.save() }

    static func makeForApp(environment: [String: String] = ProcessInfo.processInfo.environment) -> BankingService {
        if Persistence.isHostingTests(environment: environment) || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return BankingService(secrets: NoSecretStore(), makeHTTP: { _ in DisabledBankingHTTPClient() })
        }
        return BankingService()
    }

    init(secrets: SecretStore = KeychainStore(service: "WealthOS.Banking", accessibility: .whenUnlocked),
         defaults: UserDefaults = .standard,
         makeHTTP: @escaping @Sendable (String) -> BankingHTTPClient = { BankingTransport(allowedHost: $0) }) {
        self.secrets = secrets
        self.defaults = defaults
        self.makeHTTP = makeHTTP
        backendURLString = defaults.string(forKey: Self.backendURLKey) ?? ""
        reloadConnectionState()
    }

    private var keychainPair: CredentialPair {
        CredentialPair(secrets: secrets, keyAccount: "clientID", secretAccount: "clientSecret",
                       defaults: defaults, journalKey: "credentialWriteInProgress.banking")
    }

    var config: BankingBackendConfig? { BankingBackendConfig(string: backendURLString) }
    var isConfigured: Bool { config != nil && credentialState == .stored }
    var hasPendingAuthorization: Bool { pendingAttempt != nil }

    func reloadConnectionState() {
        protectionUpgradeFailed = !keychainPair.upgradeProtection()
        credentialState = keychainPair.state()
    }

    // MARK: Backend configuration

    /// Stores the backend address (UserDefaults, not secret) and the client id + secret (Keychain).
    func configure(backendURL: String, clientID: String, clientSecret: String) throws {
        guard let config = BankingBackendConfig(string: backendURL) else { throw BankingError.invalidBackendURL }
        let credentials = BankingCredentials(clientID: clientID, clientSecret: clientSecret)
        guard credentials.isComplete else { throw BankingError.notConfigured }
        reloadConnectionState()
        guard credentialState != .locked, credentialState != .unavailable else { throw BankingError.keychainUnavailable }
        switch keychainPair.replace(with: (credentials.clientID, credentials.clientSecret), previous: keychainPair.values()) {
        case .written: break
        case .rolledBack, .uncertain:
            credentialState = keychainPair.state()
            throw BankingError.credentialStorage
        }
        backendURLString = config.baseURL.absoluteString
        defaults.set(backendURLString, forKey: Self.backendURLKey)
        credentialState = keychainPair.state()
        lastError = nil
    }

    /// Deletes the client secret. Bank connections and imported data are kept.
    func removeBackendCredentials() throws {
        generation += 1
        guard keychainPair.delete() else {
            credentialState = keychainPair.state()
            throw BankingError.credentialStorage
        }
        credentialState = keychainPair.state()
    }

    private func makeClient() throws -> BankingClient {
        guard let config else { throw BankingError.notConfigured }
        guard let values = keychainPair.values() else {
            throw credentialState == .locked ? BankingError.keychainUnavailable : BankingError.notConfigured
        }
        let credentials = BankingCredentials(clientID: values.key, clientSecret: values.secret)
        guard credentials.isComplete else { throw BankingError.notConfigured }
        return BankingClient(config: config, credentials: credentials, http: makeHTTP(config.host))
    }

    // MARK: Authorization

    /// Step 1: asks the backend to start an Enable Banking authorization for Swedbank (LV).
    /// Returns the bank's authorization page to open in an authentication session.
    func beginConnection(aspspName: String = BankingConstants.swedbankName, country: String = BankingConstants.latvia,
                         now: Date = .now) async throws -> URL {
        guard !isConnecting, !isSyncing else { throw BankingError.busy }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let response = try await makeClient().startAuthorization(aspspName: aspspName, country: country)
            guard let url = URL(string: response.authorizationURL), url.scheme?.lowercased() == "https",
                  !response.attemptID.isEmpty else { throw BankingError.invalidResponse }
            pendingAttempt = (response.attemptID, now)
            return url
        } catch {
            throw record(error, now: now)
        }
    }

    func cancelPendingConnection() { pendingAttempt = nil }

    /// Step 2: validates the callback the authentication session returned, then fetches the
    /// connection the backend created. The attempt is single-use: it's cleared whatever happens.
    @discardableResult
    func finishConnection(callbackURL: URL, context: ModelContext, now: Date = .now) async throws -> BankConnection {
        guard let attempt = pendingAttempt else { throw BankingError.invalidCallback }
        pendingAttempt = nil
        guard now.timeIntervalSince(attempt.startedAt) <= Self.attemptLifetime else { throw BankingError.attemptExpired }
        let callback = try BankCallback.parse(callbackURL, expectedAttemptID: attempt.id)
        switch callback.result {
        case .success: break
        case .cancelled: throw BankingError.authorizationCancelled
        case .rejected: throw BankingError.authorizationRejected
        case .failed: throw BankingError.authorizationFailed
        }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let dto = try await makeClient().completeAuthorization(attemptID: attempt.id)
            let connection = try BankConnectionStore.upsert(dto, now: now, context: context, save: saveContext)
            lastError = nil
            return connection
        } catch {
            throw record(error, now: now)
        }
    }

    // MARK: Linking

    /// Counts this bank account as the existing WealthOS `account` from now on. Never creates a
    /// second counted asset and never changes the account's own records.
    func link(_ link: BankAccountLink, to account: Account, importFrom start: Date, context: ModelContext) throws {
        try Persistence.commit(context, save: saveContext) {
            try BankConnectionStore.link(link, to: account, importFrom: start, calendar: calendar, context: context)
        }
        refreshSnapshot(context)
    }

    /// Creates a new WealthOS account for a bank account that isn't tracked manually yet.
    @discardableResult
    func createAccount(for link: BankAccountLink, context: ModelContext, now: Date = .now) throws -> Account {
        guard let created = try createAccounts(for: [link], context: context, now: now).first else {
            throw BankingError.localSaveFailed
        }
        return created
    }

    /// The app's base currency (Settings), used for new accounts from multi-currency bank accounts.
    private var baseCurrency: String {
        let code = UserDefaults.standard.string(forKey: SettingsKey.baseCurrency) ?? "EUR"
        return BankAmount.isCurrency(code) ? code : "EUR"
    }

    /// Creates WealthOS accounts for several untracked bank accounts in one save (all or nothing).
    @discardableResult
    func createAccounts(for links: [BankAccountLink], context: ModelContext, now: Date = .now) throws -> [Account] {
        var created: [Account] = []
        let start = calendar.date(byAdding: .day, value: -Self.newAccountHistoryDays, to: now) ?? now
        try Persistence.commit(context, save: saveContext) {
            for link in links {
                created.append(try BankConnectionStore.createAccount(for: link, now: now, importFrom: start,
                                                                     calendar: calendar, multiCurrencyDefault: baseCurrency,
                                                                     context: context))
            }
        }
        refreshSnapshot(context)
        return created
    }

    /// Stops counting the bank balance for this account. Optionally records one balance
    /// adjustment so the WealthOS balance continues from the last confirmed bank balance.
    func unlink(_ link: BankAccountLink, adjustingFrom ledgerBalance: Decimal?, context: ModelContext, now: Date = .now) throws {
        try Persistence.commit(context, save: saveContext) {
            BankConnectionStore.unlink(link, adjustingFrom: ledgerBalance, now: now, context: context)
        }
        refreshSnapshot(context)
    }

    // MARK: Sync

    static func lastSync(in links: [BankAccountLink]) -> Date? {
        links.filter(\.isLinked).compactMap(\.lastSuccessfulSyncAt).min()
    }

    func syncIfStale(context: ModelContext, now: Date = .now) async {
        await sync(context: context, force: false, now: now)
    }

    /// Returns true when at least one account was saved.
    @discardableResult
    func sync(context: ModelContext, force: Bool = false, now: Date = .now) async -> Bool {
        guard isConfigured, !isConnecting else { return false }
        if isSyncing {
            // Not dropped: when the running sync ends, accounts it didn't cover (never fetched) follow.
            rerunRequested = true
            return false
        }
        var saved = await syncOnce(context: context, force: force, now: now)
        while rerunRequested {
            rerunRequested = false
            saved = await syncOnce(context: context, force: false, now: now) || saved
        }
        return saved
    }

    /// A linked account that has never been fetched, successfully or not. Fetching it can't be a
    /// repeat request, so it isn't held back by the stale/minimum intervals.
    static func isNeverFetched(_ link: BankAccountLink) -> Bool {
        link.lastSuccessfulSyncAt == nil && link.lastAttemptAt == nil
    }

    private func syncOnce(context: ModelContext, force: Bool, now: Date) async -> Bool {
        let connections = ((try? context.fetch(FetchDescriptor<BankConnection>())) ?? []).filter { $0.status == .active }
        let allLinks = ((try? context.fetch(FetchDescriptor<BankAccountLink>())) ?? []).filter { $0.isLinked && $0.isConnected }
        guard !connections.isEmpty, !allLinks.isEmpty else { return false }
        let fresh = allLinks.filter(Self.isNeverFetched)
        var links = allLinks
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.minimumInterval {
            guard !fresh.isEmpty else { return false }
            links = fresh
        }
        if !force {
            if let automaticRetryAfter, now < automaticRetryAfter { return false }
            let synced = links.filter { !Self.isNeverFetched($0) }
            if let last = Self.lastSync(in: synced), now.timeIntervalSince(last) < Self.staleInterval {
                guard !fresh.isEmpty else { return false }
                links = fresh
            }
        }
        var client: BankingClient
        do { client = try makeClient() } catch { _ = record(error, now: now); return false }
        // Every sync runs while the app is open (Sync Now, linking, opening the app): the user is
        // present. A future background refresh must leave this false.
        client.userPresent = true
        isSyncing = true
        defer { isSyncing = false }
        lastAttemptAt = now
        let started = generation
        var savedAny = false
        var firstError: BankingError?
        var total = BankReconciler.Outcome()

        for connection in connections {
            if let until = connection.validUntil, until <= now {
                connection.status = .expired
                Persistence.flush(context)
                firstError = firstError ?? .consentExpired
                continue
            }
            for link in links where link.connectionID == connection.id {
                do {
                    let outcome = try await syncAccount(link, client: client, connection: connection, now: now,
                                                        started: started, context: context)
                    accountErrors[link.id] = nil
                    savedAny = true
                    total.imported += outcome.imported
                    total.matched += outcome.matched
                    total.needsReview += outcome.needsReview
                    total.skipped += outcome.skipped
                    total.changedAfterImport += outcome.changedAfterImport
                } catch is CancellationError {
                    return savedAny
                } catch {
                    guard started == generation else { return savedAny }
                    let mapped = map(error)
                    accountErrors[link.id] = mapped
                    firstError = firstError ?? mapped
                    link.lastAttemptAt = now
                    if mapped.requiresReconnect {
                        connection.status = mapped == .consentExpired ? .expired : .revoked
                        Persistence.flush(context)
                        break
                    }
                    Persistence.flush(context)
                    if case .rateLimited = mapped { break }
                }
            }
        }
        if savedAny {
            // Rules improve over time (new merchants, aliases): apply them to earlier downloads too.
            try? Persistence.commit(context, save: saveContext) { try BankCategoryReapply.run(in: context, now: now) }
        }
        lastOutcome = total
        if let firstError {
            _ = record(firstError, now: now)
        } else {
            lastError = nil
            lastFailureAt = nil
            automaticRetryAfter = nil
        }
        if savedAny { refreshSnapshot(context) }
        return savedAny
    }

    /// Reads balance and the transaction window first, and only then writes — in one save.
    private func syncAccount(_ link: BankAccountLink, client: BankingClient, connection: BankConnection, now: Date,
                             started: Int, context: ModelContext) async throws -> BankReconciler.Outcome {
        guard let localID = link.localAccountID,
              let account = try context.fetch(FetchDescriptor<Account>()).first(where: { $0.id == localID }) else {
            throw BankingError.notFound
        }
        guard link.accepts(account.currencyCode) else { throw BankingError.currencyMismatch }
        let balances = try await client.balances(connectionID: connection.backendConnectionID, accountUID: link.providerAccountUID)
        let balance = try BankBalanceSelection.select(balances, currency: account.currencyCode, creditLimit: link.creditLimit,
                                                      otherCurrencies: link.isMultiCurrency)
        let importStart = calendar.startOfDay(for: link.importStartDate ?? now)
        let overlapStart = link.lastSuccessfulSyncAt.flatMap { calendar.date(byAdding: .day, value: -Self.overlapDays, to: $0) }
        let windowStart = max(importStart, overlapStart.map { calendar.startOfDay(for: $0) } ?? importStart)
        let rows = try await client.transactions(connectionID: connection.backendConnectionID, accountUID: link.providerAccountUID,
                                                 dateFrom: BankDay.string(windowStart, calendar: calendar))
        // Disconnected or unlinked while downloading: drop the result.
        guard started == generation, link.connectionID == connection.id, link.localAccountID == localID else {
            throw CancellationError()
        }
        let parsed = BankParsing.parse(rows)
        var outcome = BankReconciler.Outcome()
        try Persistence.commit(context, save: saveContext) {
            BankReconciler.applyBalance(balance, to: link, calendar: calendar)
            outcome = try BankReconciler.apply(parsed, link: link, now: now, calendar: calendar, in: context)
            link.lastSuccessfulSyncAt = now
            link.lastAttemptAt = now
            link.transactionsSyncedFrom = windowStart
            link.lastErrorRaw = outcome.skipped > 0 ? "skipped:\(outcome.skipped)" : ""
        }
        return outcome
    }

    /// Checks the consent at the backend (e.g. when Settings opens). Never deletes data.
    func refreshStatus(of connection: BankConnection, context: ModelContext, now: Date = .now) async {
        guard isConfigured, let client = try? makeClient() else { return }
        do {
            let status = try await client.connectionStatus(connection.backendConnectionID)
            switch status.status.uppercased() {
            case "AUTHORIZED": connection.status = .active
            case "EXPIRED": connection.status = .expired
            default: connection.status = .revoked
            }
            if let until = status.validUntil.flatMap(BankConnectionStore.parseDate) { connection.validUntil = until }
            connection.lastCheckedAt = now
            Persistence.flush(context)
        } catch {
            let mapped = map(error)
            if mapped.requiresReconnect {
                connection.status = mapped == .consentExpired ? .expired : .revoked
                Persistence.flush(context)
            }
        }
    }

    // MARK: Disconnect

    /// Ends the consent at the bank (best effort) and forgets it on this iPhone. Balances,
    /// imported transactions, review state and account links are kept — nothing financial is
    /// deleted. Returns false if the backend couldn't confirm the remote deletion.
    @discardableResult
    func disconnect(_ connection: BankConnection, context: ModelContext) async throws -> Bool {
        generation += 1
        let remoteID = connection.backendConnectionID
        var remoteDeleted = false
        if let client = try? makeClient() {
            do {
                try await client.deleteConnection(remoteID)
                remoteDeleted = true
            } catch BankingError.notFound {
                remoteDeleted = true
            } catch {}
        }
        try Persistence.commit(context, save: saveContext) {
            try BankConnectionStore.forget(connection, context: context)
        }
        accountErrors = [:]
        lastError = nil
        automaticRetryAfter = nil
        refreshSnapshot(context)
        return remoteDeleted
    }

    // MARK: Internals

    private func map(_ error: Error) -> BankingError {
        (error as? BankingError) ?? (error is PersistenceError ? .localSaveFailed : .network)
    }

    private func record(_ error: Error, now: Date) -> Error {
        if error is CancellationError { return error }
        let mapped = map(error)
        lastError = mapped
        lastFailureAt = now
        let backoff: TimeInterval = switch mapped {
        case .rateLimited(let wait): max(wait ?? 3600, 600)
        case .offline, .network, .timeout: 15 * 60
        case .bankUnavailable, .server, .invalidResponse, .tooManyPages: 3600
        default: 0
        }
        automaticRetryAfter = backoff > 0 ? now.addingTimeInterval(backoff) : nil
        return mapped
    }

    private func refreshSnapshot(_ context: ModelContext) {
        DataMaintenance.refreshSnapshot(context: context, baseCurrency: defaults.string(forKey: SettingsKey.baseCurrency) ?? "EUR")
    }
}

// MARK: - Store operations (pure SwiftData, unit-testable)

enum BankConnectionStore {
    nonisolated static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func isValidKey(_ key: String) -> Bool {
        (16...128).contains(key.count) && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Records a completed consent. Accounts are matched to earlier links by their stable key, so
    /// reconnecting keeps every link, balance and import history; nothing is linked automatically.
    @discardableResult
    static func upsert(_ dto: BankConnectionDTO, now: Date, context: ModelContext,
                       save: (ModelContext) throws -> Void = { try $0.save() }) throws -> BankConnection {
        guard !dto.connectionID.isEmpty, dto.connectionID.count <= 128 else { throw BankingError.invalidResponse }
        // A duplicated identity would make two bank accounts indistinguishable: refuse the consent.
        let keys = dto.accounts.map(\.accountKey)
        guard Set(keys).count == keys.count else { throw BankingError.invalidResponse }
        // Accounts without a usable identity or a single currency (e.g. multi-currency accounts)
        // are left out rather than guessed; they can't be linked in this version.
        let usable = dto.accounts.filter { isValidKey($0.accountKey) && !$0.uid.isEmpty && BankAmount.isCurrency($0.currency) }
        var created: BankConnection?
        try Persistence.commit(context, save: save) {
            let connection = BankConnection(aspspName: dto.aspsp.name, aspspCountry: dto.aspsp.country,
                                            backendConnectionID: dto.connectionID,
                                            validUntil: dto.validUntil.flatMap { parseDate($0) }, createdAt: now)
            context.insert(connection)
            created = connection
            let links = try context.fetch(FetchDescriptor<BankAccountLink>())
            var byKey = Dictionary(links.map { ($0.accountKey, $0) }, uniquingKeysWith: { a, _ in a })
            for account in usable {
                let link = byKey[account.accountKey] ?? {
                    let new = BankAccountLink(accountKey: account.accountKey, aspspName: dto.aspsp.name,
                                              aspspCountry: dto.aspsp.country, createdAt: now)
                    context.insert(new)
                    return new
                }()
                byKey[account.accountKey] = link
                link.connectionID = connection.id
                link.providerAccountUID = account.uid
                link.displayName = String((account.displayName ?? "").prefix(80))
                link.maskedIdentifier = String((account.maskedIdentifier ?? "").prefix(40))
                link.cashAccountType = String((account.cashAccountType ?? "").prefix(8))
                link.product = String((account.product ?? "").prefix(80))
                let currency = account.currency ?? ""
                if link.currencyCode.isEmpty || link.localAccountID == nil {
                    link.currencyCode = currency
                }
                link.creditLimit = account.creditLimit.flatMap { limit in
                    limit.currency == currency ? BankAmount.parse(limit.amount) : nil
                }
            }
            // An older consent for the same bank no longer serves any account.
            let used = Set(try context.fetch(FetchDescriptor<BankAccountLink>()).compactMap(\.connectionID))
            for old in try context.fetch(FetchDescriptor<BankConnection>())
            where old.id != connection.id && old.aspspName == connection.aspspName && old.aspspCountry == connection.aspspCountry
                && !used.contains(old.id) {
                context.delete(old)
            }
        }
        guard let created else { throw BankingError.localSaveFailed }
        return created
    }

    static func linkableKinds() -> Set<AccountKind> { [.checking, .savings, .cash] }

    /// True when the user tracks an unlinked cash/savings account by hand in one of these bank
    /// accounts' currencies — it could be the same money, so bulk creation isn't offered.
    static func hasManualCandidates(for targets: [BankAccountLink], links: [BankAccountLink], accounts: [Account]) -> Bool {
        let taken = Set(links.compactMap(\.localAccountID))
        return accounts.contains { account in
            linkableKinds().contains(account.kind) && !taken.contains(account.id)
                && targets.contains { $0.accepts(account.currencyCode) }
        }
    }

    static func link(_ link: BankAccountLink, to account: Account, importFrom start: Date, calendar: Calendar,
                     context: ModelContext) throws {
        guard link.isLinkable, linkableKinds().contains(account.kind) else { throw BankingError.invalidResponse }
        guard link.accepts(account.currencyCode) else { throw BankingError.currencyMismatch }
        let others = try context.fetch(FetchDescriptor<BankAccountLink>())
        // One WealthOS account represents at most one bank account (and vice versa).
        guard !others.contains(where: { $0.id != link.id && $0.localAccountID == account.id }) else {
            throw BankingError.invalidResponse
        }
        link.localAccountID = account.id
        link.importStartDate = calendar.startOfDay(for: start)
        link.restoredFromBackup = false
    }

    /// `importFrom` defaults to `now` (no history); the app passes `newAccountHistoryDays` back.
    /// A multi-currency bank account becomes a WealthOS account in `multiCurrencyDefault` (the
    /// app's base currency); its other currencies' transactions wait for review.
    static func createAccount(for link: BankAccountLink, now: Date, importFrom start: Date? = nil, calendar: Calendar,
                              multiCurrencyDefault: String = "EUR", context: ModelContext) throws -> Account {
        guard link.isLinkable, BankAmount.isCurrency(link.currencyCode), link.localAccountID == nil else {
            throw BankingError.invalidResponse
        }
        let kind: AccountKind = link.cashAccountType.uppercased() == "SVGS" ? .savings : .checking
        let existing = try context.fetch(FetchDescriptor<Account>())
        let order = (existing.map(\.sortOrder).max() ?? 0) + 1
        let importStart = calendar.startOfDay(for: min(start ?? now, now))
        // Opening balance 0: until the first confirmed bank balance arrives, this account adds nothing.
        let currency = link.isMultiCurrency ? multiCurrencyDefault : link.currencyCode
        guard link.accepts(currency) else { throw BankingError.currencyMismatch }
        let account = Account(name: accountName(for: link, existing: existing), kind: kind, currencyCode: currency,
                              openingBalance: 0, openingDate: importStart, institution: link.aspspName, colorName: "orange",
                              sortOrder: order)
        context.insert(account)
        try self.link(link, to: account, importFrom: importStart, calendar: calendar, context: context)
        return account
    }

    /// The bank's account name plus the last four characters of the masked number, so several
    /// accounts with the same holder name ("Mr. Popcorn") stay distinguishable.
    static func accountName(for link: BankAccountLink, existing: [Account]) -> String {
        let suffix = String(link.maskedIdentifier.filter { $0.isLetter || $0.isNumber }.suffix(4))
        let base = link.displayName.isEmpty ? link.title : link.displayName
        let name = suffix.isEmpty || base.contains(suffix) ? base : "\(base) ·\(suffix)"
        guard existing.contains(where: { $0.name == name }) else { return name }
        var index = 2
        while existing.contains(where: { $0.name == "\(name) (\(index))" }) { index += 1 }
        return "\(name) (\(index))"
    }

    static func unlink(_ link: BankAccountLink, adjustingFrom ledgerBalance: Decimal?, now: Date, context: ModelContext) {
        if let ledgerBalance, let bank = link.balanceAmount, let accountID = link.localAccountID, bank != ledgerBalance {
            context.insert(TransactionRecord(kind: .adjustment, amount: bank - ledgerBalance, date: now,
                                             note: "Balance from \(link.aspspName)", accountID: accountID))
        }
        link.localAccountID = nil
    }

    /// Forgets a consent locally. Financial data stays; links stay so a reconnect resumes them.
    static func forget(_ connection: BankConnection, context: ModelContext) throws {
        let id = connection.id
        for link in try context.fetch(FetchDescriptor<BankAccountLink>()) where link.connectionID == id {
            link.connectionID = nil
            link.providerAccountUID = ""
        }
        context.delete(connection)
    }

    /// Removes bank data that isn't financial history: links, pending rows, rules, consents.
    /// Booked provenance rows are kept unless `includingProvenance` (used by Reset All Data).
    static func removeAll(includingProvenance: Bool, in context: ModelContext) throws {
        for row in try context.fetch(FetchDescriptor<BankConnection>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BankAccountLink>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BankCounterpartyRule>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<BankTransaction>()) where includingProvenance || row.status == .pending {
            context.delete(row)
        }
    }
}
