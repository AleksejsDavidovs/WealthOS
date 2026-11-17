import AuthenticationServices
import SwiftData
import SwiftUI

// MARK: - Settings → Bank Connections

struct BankConnectionsSettingsView: View {
    @Environment(BankingService.self) private var service
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @Query(sort: \BankConnection.createdAt) private var connections: [BankConnection]
    @Query(sort: \BankAccountLink.createdAt) private var links: [BankAccountLink]
    @Query private var bankTransactions: [BankTransaction]
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var message: String?
    @State private var disconnecting: BankConnection?
    @State private var addingAll: [BankAccountLink] = []

    private var reviewCount: Int { bankTransactions.filter { $0.status == .booked && $0.resolution == .needsReview }.count }
    private var pendingCount: Int { bankTransactions.filter { $0.status == .pending }.count }
    private var changedCount: Int { bankTransactions.filter(\.bankDataChanged).count }

    var body: some View {
        Form {
            if app.isDemoMode {
                Section {
                    Label("Bank connections are unavailable in demo mode. Exit demo mode to connect your bank.",
                          systemImage: "theatermasks.fill")
                }
            } else {
                CredentialStateSection(state: service.credentialState, protectionUpgradeFailed: service.protectionUpgradeFailed,
                                       retry: { service.reloadConnectionState() })
                serverSection
                if service.isConfigured { connectSection }
                ForEach(connections) { connection in connectionSection(connection) }
                unconnectedLinksSection
                if reviewCount > 0 || pendingCount > 0 || changedCount > 0 { activitySection }
            }
            aboutSection
        }
        .navigationTitle("Bank Connections")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !app.isDemoMode, service.isConfigured else { return }
            for connection in connections where connection.lastCheckedAt.map({ Date.now.timeIntervalSince($0) > 3600 }) ?? true {
                await service.refreshStatus(of: connection, context: context)
            }
        }
        .confirmationDialog("Disconnect \(disconnecting?.title ?? "bank")?",
                            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                if let connection = disconnecting { disconnect(connection) }
            }
        } message: {
            Text("Bank access is ended and forgotten on this iPhone. Imported transactions, your manual records and account links are kept. Linked accounts keep showing the last confirmed bank balance, marked as unverified, until you reconnect or stop using the bank balance.")
        }
        .confirmationDialog(addingAll.count == 1 ? "Add 1 bank account?" : "Add \(addingAll.count) bank accounts?",
                            isPresented: Binding(get: { !addingAll.isEmpty }, set: { if !$0 { addingAll = [] } }),
                            titleVisibility: .visible) {
            Button("Add and Sync") { addAll(addingAll) }
        } message: {
            Text(addAllWarning)
        }
    }

    /// Unlinked cash/savings accounts the user tracks by hand in the same currency. Any of them
    /// could be one of these bank accounts, so "add all" is withheld and each is decided singly.
    private func manualAccountsExist(for targets: [BankAccountLink]) -> Bool {
        BankConnectionStore.hasManualCandidates(for: targets, links: links, accounts: accounts)
    }

    private var addAllWarning: String {
        "Each becomes a WealthOS account showing its confirmed bank balance, with the last \(BankingService.newAccountHistoryDays) days of transactions."
    }

    private func addAll(_ targets: [BankAccountLink]) {
        addingAll = []
        guard !manualAccountsExist(for: targets) else { return }
        do {
            try service.createAccounts(for: targets, context: context)
            Task { await service.sync(context: context, force: true) }
        } catch {
            message = (error as? BankingError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Sections

    private var serverSection: some View {
        Section {
            NavigationLink { BankingServerSetupView() } label: {
                LabeledContent {
                    Text(service.isConfigured ? "Configured" : "Not set up")
                } label: {
                    Label("Banking Server", systemImage: "server.rack")
                }
            }
        } footer: {
            Text("WealthOS reaches your bank only through your own WealthOS banking server, which holds the Enable Banking key. Your bank password is never entered in WealthOS.")
        }
    }

    private var connectSection: some View {
        Section {
            Button(action: connect) {
                HStack {
                    Label(connections.isEmpty ? "Connect Swedbank" : "Connect Swedbank Again", systemImage: "building.columns")
                    Spacer()
                    if service.isConnecting { ProgressView() }
                }
            }
            .disabled(service.isConnecting || service.isSyncing)
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Swedbank (Latvia)")
        } footer: {
            Text("You'll sign in on Swedbank's own page (Smart-ID or eParaksts) and approve read-only access to account information. WealthOS can't make payments or move money.")
        }
    }

    private func connectionSection(_ connection: BankConnection) -> some View {
        let connectionLinks = links.filter { $0.connectionID == connection.id }
        let usable = connection.isUsable()
        return Section {
            LabeledContent("Status") {
                Text(statusText(connection)).foregroundStyle(usable ? Theme.positive : Theme.warning)
            }
            if let until = connection.validUntil {
                LabeledContent("Access valid until", value: until.formatted(date: .abbreviated, time: .shortened))
                if usable, until.timeIntervalSinceNow < 7 * 86_400 {
                    Label("Access expires soon. Reconnect to keep syncing.", systemImage: "clock.badge.exclamationmark")
                        .font(.footnote).foregroundStyle(Theme.warning)
                }
            }
            if let last = BankingService.lastSync(in: connectionLinks) {
                LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            ForEach(connectionLinks) { link in
                NavigationLink { BankAccountLinkView(link: link) } label: { BankAccountLinkRow(link: link, accounts: accounts) }
            }
            let untracked = connectionLinks.filter { !$0.isLinked && $0.isLinkable && BankAmount.isCurrency($0.currencyCode) }
            if usable, !untracked.isEmpty, !manualAccountsExist(for: untracked) {
                Button {
                    addingAll = untracked
                } label: {
                    Label(untracked.count == 1 ? "Add as New Account" : "Add All \(untracked.count) as New Accounts",
                          systemImage: "plus.circle.fill")
                }
                .disabled(service.isSyncing)
            }
            if usable, !untracked.isEmpty, manualAccountsExist(for: untracked) {
                Label("You already track accounts by hand. Open each bank account above and link it to the matching WealthOS account (or add it as new), so nothing is counted twice.",
                      systemImage: "link")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if usable {
                Button {
                    Task { await service.sync(context: context, force: true) }
                } label: {
                    HStack {
                        Label("Sync Now", systemImage: "arrow.clockwise")
                        Spacer()
                        if service.isSyncing { ProgressView() }
                    }
                }
                .disabled(service.isSyncing || !connectionLinks.contains(where: \.isLinked))
            } else {
                Button { connect() } label: { Label("Reconnect", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(service.isConnecting || !service.isConfigured)
            }
            if let error = service.lastError {
                Label(error.errorDescription ?? "Sync failed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Theme.warning)
            }
            Button("Disconnect", role: .destructive) { disconnecting = connection }
        } header: {
            Text(connection.title)
        } footer: {
            Text("Syncs when you open WealthOS if the data is older than 6 hours (banks limit background access). A failed sync never changes your balances.")
        }
    }

    @ViewBuilder
    private var unconnectedLinksSection: some View {
        let orphaned = links.filter { !$0.isConnected && ($0.isLinked || $0.balanceAmount != nil) }
        if !orphaned.isEmpty {
            Section {
                ForEach(orphaned) { link in
                    NavigationLink { BankAccountLinkView(link: link) } label: { BankAccountLinkRow(link: link, accounts: accounts) }
                }
            } header: {
                Text("Not connected")
            } footer: {
                Text("These accounts show their last confirmed bank balance, marked as unverified. Connect again to resume syncing — history continues without duplicates.")
            }
        }
    }

    private var activitySection: some View {
        Section {
            if reviewCount > 0 {
                NavigationLink { BankReviewListView() } label: {
                    LabeledContent { Text("\(reviewCount)") } label: {
                        Label("Transactions to Review", systemImage: "questionmark.circle")
                    }
                }
            }
            if pendingCount > 0 {
                LabeledContent {
                    Text("\(pendingCount)")
                } label: {
                    Label("Pending at the bank", systemImage: "hourglass")
                }
            }
            if changedCount > 0 {
                Label("\(changedCount) imported transaction\(changedCount == 1 ? " was" : "s were") changed by the bank afterwards. Your records weren't modified — compare them in Transactions.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Theme.warning)
            }
        } header: {
            Text("Activity")
        } footer: {
            Text("Pending transactions are shown by the bank but aren't recorded until they're booked. Transactions WealthOS can't classify with certainty wait for your review instead of being guessed.")
        }
    }

    private var aboutSection: some View {
        Section("Read-only") {
            Label("Only account details, balances and transactions are read. There is no payment, transfer or card feature, and no way to add one from the app.",
                  systemImage: "lock.shield")
                .font(.footnote)
            Label("Imported transactions are marked with a bank icon. Your own categories, notes and edits are never overwritten by a sync.",
                  systemImage: "building.columns")
                .font(.footnote)
        }
    }

    private func statusText(_ connection: BankConnection) -> String {
        switch connection.status {
        case .active: connection.isUsable() ? "Connected" : "Expired"
        case .expired: "Expired"
        case .revoked: "Access ended"
        }
    }

    // MARK: Actions

    private func connect() {
        message = nil
        Task {
            do {
                let url = try await service.beginConnection()
                // Ephemeral: no cookies shared with Safari; the bank login isn't remembered.
                let callback = try await webAuthentication.authenticate(using: url, callbackURLScheme: BankingConstants.callbackScheme,
                                                                        preferredBrowserSession: .ephemeral)
                try await service.finishConnection(callbackURL: callback, context: context)
                message = "Connected. Open each account below to choose how it's counted."
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                service.cancelPendingConnection()
                message = BankingError.authorizationCancelled.errorDescription
            } catch is CancellationError {
                service.cancelPendingConnection()
            } catch {
                service.cancelPendingConnection()
                message = (error as? BankingError)?.errorDescription ?? "The bank connection couldn't be completed. Nothing was changed."
            }
        }
    }

    private func disconnect(_ connection: BankConnection) {
        Task {
            do {
                let remote = try await service.disconnect(connection, context: context)
                message = remote ? "Disconnected." : "Disconnected on this iPhone. The banking server couldn't confirm ending the bank access; it expires on its own."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

struct BankAccountLinkRow: View {
    let link: BankAccountLink
    let accounts: [Account]

    private var countingCurrency: String? {
        link.countingCurrency(linkedAccountCurrency: accounts.first { $0.id == link.localAccountID }?.currencyCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(link.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                if let balance = link.balanceAmount, let code = countingCurrency {
                    Text(MoneyFormat.string(balance, code: code)).monospacedDigit()
                }
            }
            Text([link.maskedIdentifier, link.isMultiCurrency ? "Multi-currency" : link.currencyCode, link.balanceType?.title]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Group {
                if let id = link.localAccountID, let account = accounts.first(where: { $0.id == id }) {
                    Text("Counted as “\(account.name)”")
                } else {
                    Text(link.isLinkable ? "Not counted — tap to link" : "Not supported yet (\(link.cashAccountType))")
                }
            }
            .font(.caption).foregroundStyle(link.isLinked ? Theme.accent : Theme.warning)
            if let last = link.lastSuccessfulSyncAt {
                Text("Synced \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            }
            if link.restoredFromBackup {
                Text("Restored from backup — not re-synced yet").font(.caption2).foregroundStyle(Theme.warning)
            }
            if link.lastErrorRaw.hasPrefix("skipped:") {
                Text("Some transactions had incomplete data and weren't imported.").font(.caption2).foregroundStyle(Theme.warning)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Backend setup

struct BankingServerSetupView: View {
    @Environment(BankingService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var message: String?
    @State private var showRemove = false

    var body: some View {
        Form {
            Section {
                TextField("https://banking.example.com", text: $url)
                    .keyboardType(.URL).textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Client ID", text: $clientID).autocorrectionDisabled().textInputAutocapitalization(.never)
                SecureField("Client secret", text: $clientSecret)
                    .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Save") { save() }
                    .disabled(BankingBackendConfig(string: url) == nil
                              || !BankingCredentials(clientID: clientID, clientSecret: clientSecret).isComplete)
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.negative) }
            } header: {
                Text("Server")
            } footer: {
                Text("Use the values from your banking server's .env file (WOS_CLIENT_ID and WOS_CLIENT_SECRET). The secret is stored only in the iOS Keychain on this iPhone and is never sent — it signs each request. Only HTTPS is accepted, except http://localhost for the Simulator during development.")
            }
            if service.credentialState == .stored {
                Section {
                    LabeledContent("Server", value: service.backendURLString)
                    Button("Remove Client Secret", role: .destructive) { showRemove = true }
                }
            }
        }
        .navigationTitle("Banking Server")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if url.isEmpty { url = service.backendURLString } }
        .onDisappear { clientSecret = "" }
        .confirmationDialog("Remove the client secret?", isPresented: $showRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                do { try service.removeBackendCredentials() } catch { message = error.localizedDescription }
            }
        } message: {
            Text("Syncing stops until you enter it again. Bank data and connections are kept.")
        }
    }

    private func save() {
        do {
            try service.configure(backendURL: url, clientID: clientID, clientSecret: clientSecret)
            clientSecret = ""
            dismiss()
        } catch {
            message = (error as? BankingError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Linking one bank account

struct BankAccountLinkView: View {
    @Environment(BankingService.self) private var service
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query private var allLinks: [BankAccountLink]
    let link: BankAccountLink

    @State private var selectedAccountID: UUID?
    @State private var importStart = Calendar.current.startOfDay(for: .now)
    @State private var message: String?
    @State private var showUnlink = false
    @State private var showCreate = false

    private var takenAccountIDs: Set<UUID> {
        Set(allLinks.filter { $0.id != link.id }.compactMap(\.localAccountID))
    }

    private var candidates: [Account] {
        let taken = takenAccountIDs
        return accounts.filter {
            BankConnectionStore.linkableKinds().contains($0.kind) && link.accepts($0.currencyCode) && !taken.contains($0.id)
        }
    }

    /// Why the list is empty, in the user's terms.
    private var noCandidatesReason: String {
        let kinds = BankConnectionStore.linkableKinds()
        let matching = accounts.filter { kinds.contains($0.kind) && link.accepts($0.currencyCode) }
        let currency = link.isMultiCurrency ? "" : " \(link.currencyCode)"
        if !matching.isEmpty {
            return "Every\(currency) bank, savings and cash account in WealthOS is already linked to another bank account. Unlink one there first, or add this one as a new account."
        }
        if accounts.contains(where: { kinds.contains($0.kind) }) {
            return "None of your bank, savings or cash accounts is in \(link.currencyCode). Add this one as a new account, or create a \(link.currencyCode) account first."
        }
        return "You have no\(currency) bank, savings or cash account in WealthOS yet, so there is nothing to link. Add this one as a new account — it is counted once."
    }

    private var displayCurrency: String? {
        link.countingCurrency(linkedAccountCurrency: accounts.first { $0.id == link.localAccountID }?.currencyCode)
    }

    var body: some View {
        FinanceReader { engine in
            Form {
                Section("Bank account") {
                    LabeledContent("Bank", value: link.bankTitle)
                    LabeledContent("Name", value: link.title)
                    if !link.maskedIdentifier.isEmpty { LabeledContent("Account", value: link.maskedIdentifier) }
                    LabeledContent("Currency", value: link.isMultiCurrency ? "Multi-currency" : link.currencyCode)
                    if let balance = link.balanceAmount, let code = displayCurrency {
                        LabeledContent(link.balanceType?.title ?? "Balance", value: MoneyFormat.string(balance, code: code))
                    }
                    if let last = link.lastSuccessfulSyncAt {
                        LabeledContent("Last successful sync", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let error = service.accountErrors[link.id] {
                        Label(error.errorDescription ?? "Sync failed.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(Theme.warning)
                    }
                }
                if let id = link.localAccountID, let account = accounts.first(where: { $0.id == id }) {
                    linkedSection(account, engine: engine)
                } else if link.isLinkable {
                    linkSection
                } else {
                    Section {
                        Text("Card and loan accounts (\(link.cashAccountType)) aren't supported yet, so this account isn't counted.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(Theme.negative) }
                }
            }
        }
        .navigationTitle(link.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Stop using the bank balance?", isPresented: $showUnlink, titleVisibility: .visible) {
            Button("Continue From Last Bank Balance") { unlink(adjust: true) }
            Button("Keep My WealthOS Balance") { unlink(adjust: false) }
        } message: {
            Text("The account will show its WealthOS ledger balance again. “Continue from last bank balance” records one balance adjustment (not income or expense) so nothing jumps. Imported transactions stay.")
        }
        .confirmationDialog("Add “\(link.title)” as a new account?", isPresented: $showCreate, titleVisibility: .visible) {
            Button("Add New Account") { createAccount() }
        } message: {
            Text("Only do this if you don't already track this bank account in WealthOS — otherwise link it instead, so the money isn't counted twice.")
        }
    }

    private func linkedSection(_ account: Account, engine: FinanceEngine) -> some View {
        let ledger = engine.ledgerBalance(of: account)
        return Section {
            LabeledContent("Counted as", value: account.name)
            if let start = link.importStartDate {
                LabeledContent("Importing from", value: start.formatted(date: .abbreviated, time: .omitted))
            }
            if let bank = link.balanceAmount, bank != ledger {
                LabeledContent("WealthOS ledger balance", value: MoneyFormat.string(ledger, code: account.currencyCode))
                Text("Net worth uses the bank balance. The ledger differs by \(MoneyFormat.string(bank - ledger, code: account.currencyCode, showSign: true)), typically history from before the import start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Stop Using Bank Balance", role: .destructive) { showUnlink = true }
        } header: {
            Text("In WealthOS")
        } footer: {
            Text("This account's balance in Accounts, Home, Goals and the Simulator is the last confirmed bank balance. It is counted once.")
        }
    }

    private var linkSection: some View {
        Section {
            if candidates.isEmpty {
                Label(noCandidatesReason, systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Picker("Existing account", selection: $selectedAccountID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(candidates) { Text("\($0.name) · \($0.currencyCode)").tag(UUID?.some($0.id)) }
                }
                DatePicker("Import transactions from", selection: $importStart, in: ...Date.now, displayedComponents: .date)
                if importStart < Calendar.current.startOfDay(for: .now) {
                    Text("Earlier bank transactions will be compared with your manual entries; possible duplicates wait for your review.")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                Button("Link to This Account") { linkExisting() }.disabled(selectedAccountID == nil)
            }
            Button("Add as New Account Instead") { showCreate = true }
        } header: {
            Text("How should WealthOS count it?")
        } footer: {
            Text(link.isMultiCurrency
                 ? "This is a multi-currency account. Link it to the WealthOS account you track it with: WealthOS then uses the bank's balance in that account's currency instead of counting it twice. Transactions in other currencies wait for your review. Your manual transactions are kept and never changed."
                 : "If you already track this Swedbank account by hand, link it: WealthOS then shows the bank's balance for it instead of counting it twice. Your manual transactions are kept and never changed. Only \(link.currencyCode) cash and savings accounts can be linked.")
        }
    }

    private func linkExisting() {
        guard let id = selectedAccountID, let account = accounts.first(where: { $0.id == id }) else { return }
        do {
            try service.link(link, to: account, importFrom: importStart, context: context)
            Task { await service.sync(context: context, force: true) }
        } catch {
            message = (error as? BankingError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func createAccount() {
        do {
            try service.createAccount(for: link, context: context)
            Task { await service.sync(context: context, force: true) }
        } catch {
            message = (error as? BankingError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func unlink(adjust: Bool) {
        let engine = DataMaintenance.makeEngine(context: context, baseCurrency: UserDefaults.standard.string(forKey: SettingsKey.baseCurrency) ?? "EUR")
        let ledger = link.localAccountID.flatMap { id in engine.accounts.first { $0.id == id } }.map(engine.ledgerBalance(of:))
        do {
            try service.unlink(link, adjustingFrom: adjust ? ledger : nil, context: context)
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Review queue

struct BankReviewListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BankTransaction.bookingDate, order: .reverse) private var rows: [BankTransaction]
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @State private var saveError: String?
    @State private var confirmBulk = false

    var body: some View {
        let open = rows.filter { $0.status == .booked && $0.resolution == .needsReview }
        let matched = rows.filter { $0.resolution == .matched }.prefix(30)
        let bulk = open.filter(BankReview.isBulkRecordable)
        List {
            if !bulk.isEmpty {
                Section {
                    Button { confirmBulk = true } label: {
                        Label("Record \(bulk.count) as Income / Expense", systemImage: "tray.and.arrow.down.fill")
                    }
                } footer: {
                    Text("Money in becomes income, money out becomes expense, with default categories. You can edit or recategorize each one later in Transactions. Possible duplicates and unclear items stay here.")
                }
            }
            Section {
                if open.isEmpty { Text("Nothing to review.").foregroundStyle(.secondary) }
                ForEach(open) { row in
                    NavigationLink { BankReviewDetailView(row: row) } label: { BankTransactionSummaryRow(row: row) }
                }
            } footer: {
                Text("These booked transactions aren't recorded yet, so they don't affect statistics. Your account balance already reflects them through the bank balance.")
            }
            if !matched.isEmpty {
                Section("Matched to your entries") {
                    ForEach(Array(matched)) { row in
                        HStack {
                            BankTransactionSummaryRow(row: row)
                            Button("Not Same") {
                                do { try Persistence.commit(context) { BankReview.unmatch(row) } } catch {
                                    saveError = error.localizedDescription
                                }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
        .navigationTitle("Review")
        .saveErrorAlert($saveError)
        .confirmationDialog("Record these bank transactions?", isPresented: $confirmBulk, titleVisibility: .visible) {
            Button("Record as Income / Expense") { recordAll() }
        } message: {
            Text("Only do this if none of them are transfers between your own accounts or loan repayments — those would wrongly count as income or spending.")
        }
    }

    private func recordAll() {
        do {
            try Persistence.commit(context) { _ = try BankReview.recordAllAsIncomeOrExpense(rows, in: context) }
            DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
        } catch {
            saveError = (error as? BankingError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct BankTransactionSummaryRow: View {
    let row: BankTransaction
    var accountName: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: row.amount < 0 ? "arrow.up.right" : "arrow.down.left", color: row.amount < 0 ? .gray : Theme.positive)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.body.weight(.medium)).lineLimit(1)
                Text([row.day?.formatted(date: .abbreviated, time: .omitted), accountName,
                      row.reviewReason == .none ? nil : row.reviewReason.message]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(MoneyFormat.string(row.amount, code: row.currencyCode, showSign: true)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct BankReviewDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query private var records: [TransactionRecord]
    @Query private var rules: [BankCounterpartyRule]
    let row: BankTransaction

    @State private var categoryID: UUID?
    @State private var suggested: BankCategorizer.Suggestion?
    @State private var otherAccountID: UUID?
    @State private var remember = false
    @State private var saveError: String?

    private var isIncoming: Bool { row.amount > 0 }
    private var linkedAccountID: UUID? {
        let key = row.accountKey
        return (try? context.fetch(FetchDescriptor<BankAccountLink>(predicate: #Predicate { $0.accountKey == key })))?.first?.localAccountID
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Amount", value: MoneyFormat.string(row.amount, code: row.currencyCode, showSign: true))
                if let day = row.day { LabeledContent("Booked", value: day.formatted(date: .abbreviated, time: .omitted)) }
                if !row.counterpartyName.isEmpty { LabeledContent(isIncoming ? "From" : "To", value: row.counterpartyName) }
                if !row.counterpartyAccountMasked.isEmpty { LabeledContent("Account", value: row.counterpartyAccountMasked) }
                if !row.remittance.isEmpty { Text(row.remittance).font(.callout).foregroundStyle(.secondary) }
                if row.reviewReason != .none {
                    Label(row.reviewReason.message, systemImage: "questionmark.circle").font(.footnote).foregroundStyle(Theme.warning)
                }
            }
            let candidates = row.candidates.compactMap { id in records.first { $0.id == id } }
            if !candidates.isEmpty {
                Section("Already recorded?") {
                    ForEach(candidates) { record in
                        Button { apply(.sameAs(record.id)) } label: {
                            VStack(alignment: .leading) {
                                Text("Same as “\(record.note.isEmpty ? record.kind.title : record.note)”")
                                Text(record.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if row.currencyCode == accountCurrency {
                Section("Record it as") {
                    Picker("Category", selection: $categoryID) {
                        Text("Default").tag(UUID?.none)
                        ForEach(categories.filter { $0.kind == (isIncoming ? .income : .expense) }) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    if let suggested, suggested.categoryID == categoryID {
                        Label(suggested.source == .learned ? "Suggested from your earlier choice for this payee"
                              : "Suggested from the merchant", systemImage: "sparkles")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(isIncoming ? "Income (earned)" : "Expense") {
                        apply(isIncoming ? .income(categoryID: categoryID) : .expense(categoryID: categoryID))
                    }
                    Picker(isIncoming ? "Transfer from" : "Transfer to", selection: $otherAccountID) {
                        Text("Choose account…").tag(UUID?.none)
                        ForEach(accounts.filter { $0.id != linkedAccountID && $0.currencyCode == row.currencyCode }) {
                            Text($0.name).tag(UUID?.some($0.id))
                        }
                    }
                    Button("Transfer Between My Accounts") { if let otherAccountID { apply(.transfer(otherAccountID: otherAccountID)) } }
                        .disabled(otherAccountID == nil)
                    if isIncoming {
                        Button("Refund (not income)") { apply(.refund) }
                    }
                    Toggle("Remember for this counterparty", isOn: $remember)
                }
            } else {
                Section {
                    Text("This amount is in \(row.currencyCode), but the account is in \(accountCurrency). Record it manually with the correct amount, then ignore it here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Ignore — Don't Record", role: .destructive) { apply(.ignore) }
            } footer: {
                Text("A loan repayment to you is a transfer from your loan (receivable) account, not income. Ignoring keeps it out of your records.")
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .saveErrorAlert($saveError)
        .onAppear {
            guard categoryID == nil else { return }
            suggested = BankCategorizer.suggest(for: row, kind: isIncoming ? .income : .expense, categories: categories, rules: rules)
            categoryID = suggested?.categoryID
        }
    }

    private var accountCurrency: String {
        linkedAccountID.flatMap { id in accounts.first { $0.id == id }?.currencyCode } ?? row.currencyCode
    }

    private func apply(_ decision: BankReviewDecision) {
        do {
            try Persistence.commit(context) {
                try BankReview.resolve(row, decision: decision, remember: remember && decision != .ignore, in: context)
            }
            DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
            dismiss()
        } catch {
            saveError = (error as? BankingError)?.errorDescription ?? error.localizedDescription
        }
    }
}
