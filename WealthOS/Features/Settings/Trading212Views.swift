import SwiftUI
import SwiftData

// MARK: - Settings → Integrations → Trading 212

struct Trading212SettingsView: View {
    @Environment(Trading212Service.self) private var service
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query private var snapshots: [BrokerAccountSnapshot]
    @Query private var positions: [BrokerPosition]
    @Query private var links: [BrokerLink]
    @Query(sort: \Holding.name) private var holdings: [Holding]
    @Query(sort: \Account.name) private var accounts: [Account]

    // Credentials live only in these fields until `connect` stores them in the Keychain.
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var environment: Trading212Environment = .live
    @State private var isConnecting = false
    @State private var message: String?
    @State private var showDisconnect = false
    @State private var showRemoveCache = false

    var body: some View {
        Form {
            if app.isDemoMode {
                Section {
                    Label("Trading 212 is unavailable in demo mode. Exit demo mode to connect your account.",
                          systemImage: "theatermasks.fill")
                }
            } else {
                CredentialStateSection(state: service.credentialState, protectionUpgradeFailed: service.protectionUpgradeFailed,
                                       retry: { service.reloadConnectionState() })
                if service.isConnected { statusSection }
                if !service.isConnected || service.needsReconnect { connectSection }
                if let snapshot = snapshots.first {
                    if !service.isConnected { cachedSection(snapshot) }
                    duplicatesSection
                }
                if service.isConnected || service.hasLeftoverCredential || service.credentialState == .uncertain { disconnectSection }
            }
            aboutSection
        }
        .navigationTitle("Trading 212")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { environment = service.environment }
        .onDisappear { apiKey = ""; apiSecret = "" }
        .confirmationDialog("Disconnect Trading 212?", isPresented: $showDisconnect, titleVisibility: .visible) {
            Button("Disconnect, Keep Last Synced Data") { disconnect(removeData: false) }
            Button("Disconnect and Remove Trading 212 Data", role: .destructive) { disconnect(removeData: true) }
        } message: {
            Text("The API key and secret are deleted from this iPhone. Your manual accounts, holdings and transactions are never changed.")
        }
        .confirmationDialog("Remove cached Trading 212 data?", isPresented: $showRemoveCache, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { disconnect(removeData: true) }
        } message: {
            Text("Removes the last synced cash and positions from WealthOS totals. Manual records are not changed.")
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            LabeledContent("Account", value: service.environment.title)
            if let snapshot = snapshots.first {
                if let number = snapshot.accountNumber { LabeledContent("Account number", value: String(number)) }
                LabeledContent("Currency", value: snapshot.currencyCode)
                LabeledContent("Last synced", value: snapshot.syncedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Positions", value: "\(positions.count)")
            }
            Button {
                Task { await service.sync(context: context, force: true) }
            } label: {
                HStack {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                    Spacer()
                    if service.isSyncing { ProgressView() }
                }
            }
            .disabled(service.isSyncing)
            if let error = service.lastError {
                Label(error.errorDescription ?? "Sync failed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Theme.warning)
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Syncs automatically when you open WealthOS if the data is older than 15 minutes. If a sync fails, the last synced data stays in place.")
        }
    }

    private var connectSection: some View {
        Section {
            Picker("Account", selection: $environment) {
                ForEach(Trading212Environment.allCases) { Text($0.title).tag($0) }
            }
            SecureField("API key", text: $apiKey)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("API secret", text: $apiSecret)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(action: connect) {
                HStack {
                    Text(service.needsReconnect ? "Reconnect" : "Connect")
                    Spacer()
                    if isConnecting { ProgressView() }
                }
            }
            .disabled(isConnecting || service.isSyncing || !Trading212Credentials(apiKey: apiKey, apiSecret: apiSecret).isComplete)
            if let message {
                Text(message).font(.footnote).foregroundStyle(Theme.negative)
            }
        } header: {
            Text(service.needsReconnect ? "Reconnect" : "Connect")
        } footer: {
            Text("In Trading 212, open Settings → API (Beta) and generate a key with read permissions for Account data, Portfolio and Metadata only. Don't enable order permissions — WealthOS never uses them. The key and secret are checked with Trading 212, then stored only in the iOS Keychain on this iPhone.")
        }
    }

    private func cachedSection(_ snapshot: BrokerAccountSnapshot) -> some View {
        Section {
            LabeledContent("Last synced", value: snapshot.syncedAt.formatted(date: .abbreviated, time: .shortened))
            Button("Remove Cached Data", role: .destructive) { showRemoveCache = true }
        } header: {
            Text("Not connected")
        } footer: {
            Text("The last synced Trading 212 data is still counted in your totals but no longer updates.")
        }
    }

    @ViewBuilder
    private var duplicatesSection: some View {
        let linked = Set(links.map(\.localID))
        let suggestedHoldings = Dictionary(Trading212Matching.holdingCandidates(holdings: holdings, positions: positions, links: links)
            .map { ($0.holding.id, $0.position.displaySymbol) }, uniquingKeysWith: { a, _ in a })
        let suggestedAccounts = Set(Trading212Matching.accountCandidates(accounts: accounts, links: links).map(\.id))
        let ambiguousHoldings = Set(Trading212Matching.ambiguousHoldings(holdings: holdings, positions: positions, links: links).map(\.id))
        let shownHoldings = holdings.filter { $0.assetClass != .crypto }
        let shownAccounts = accounts.filter { !$0.kind.isLiability && !$0.isArchived || linked.contains($0.id) }
        if !shownHoldings.isEmpty || !shownAccounts.isEmpty {
            Section {
                ForEach(shownAccounts) { account in
                    linkToggle(title: account.name, detail: suggestedAccounts.contains(account.id) ? "Looks like your Trading 212 cash" : nil,
                               isOn: linked.contains(account.id), kind: .account, id: account.id)
                }
                ForEach(shownHoldings) { holding in
                    linkToggle(title: holding.symbol.isEmpty ? holding.name : holding.symbol,
                               detail: suggestedHoldings[holding.id].map { "Looks like \($0) at Trading 212" }
                                   ?? (ambiguousHoldings.contains(holding.id) ? "Resembles several Trading 212 positions — check before linking" : nil),
                               isOn: linked.contains(holding.id), kind: .holding, id: holding.id)
                }
            } header: {
                Text("Avoid Double Counting")
            } footer: {
                Text("Turn on “Counted via Trading 212” for manual accounts or holdings that track the same money as your Trading 212 account. They stay in WealthOS with their history but are left out of totals. Nothing is linked automatically.")
            }
        }
    }

    private func linkToggle(title: String, detail: String?, isOn: Bool, kind: BrokerLink.Kind, id: UUID) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { setLinked($0, kind: kind, id: id) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail ?? (isOn ? "Counted via Trading 212" : "Counted separately"))
                    .font(.caption).foregroundStyle(detail != nil ? Theme.warning : .secondary)
            }
        }
    }

    private var disconnectSection: some View {
        Section {
            Button("Disconnect Trading 212", role: .destructive) { showDisconnect = true }
                .disabled(isConnecting)
        }
    }

    private var aboutSection: some View {
        Section("Read-only") {
            Label("WealthOS only reads your account summary, open positions and instrument names. It can't place or cancel orders, change pies, or move money.",
                  systemImage: "lock.shield")
                .font(.footnote)
            Label("Requests go directly from this iPhone to Trading 212 over HTTPS. No WealthOS server is involved.",
                  systemImage: "iphone")
                .font(.footnote)
        }
    }

    // MARK: Actions

    private func connect() {
        isConnecting = true
        message = nil
        Task {
            defer { isConnecting = false }
            do {
                try await service.connect(apiKey: apiKey, apiSecret: apiSecret, environment: environment, context: context)
                apiKey = ""
                apiSecret = ""
            } catch is CancellationError {
            } catch {
                message = (error as? Trading212Error)?.errorDescription ?? "Couldn't connect to Trading 212."
            }
        }
    }

    private func disconnect(removeData: Bool) {
        do {
            try service.disconnect(removeData: removeData, context: context)
        } catch {
            message = error.localizedDescription
        }
    }

    private func setLinked(_ linked: Bool, kind: BrokerLink.Kind, id: UUID) {
        do {
            try Persistence.commit(context) {
                try Trading212Reconciler.setLinked(linked, kind: kind, localID: id, in: context)
            }
            DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Explains Keychain states that are neither "connected" nor "not connected". Shared with Binance.
struct CredentialStateSection: View {
    let state: CredentialState
    let protectionUpgradeFailed: Bool
    let retry: () -> Void

    var body: some View {
        if let message {
            Section {
                Label(message, systemImage: "key.slash").font(.footnote).foregroundStyle(Theme.warning)
                if state == .locked || state == .unavailable {
                    Button("Try Again", action: retry)
                }
            } header: {
                Text("Keychain")
            }
        }
    }

    private var message: String? {
        switch state {
        case .locked: "The iPhone is locked, so the stored API key can't be read. Nothing was deleted — unlock and try again."
        case .unavailable: "The Keychain reported an error, so the stored API key can't be read right now. Nothing was deleted."
        case .uncertain: "After a Keychain error WealthOS can't confirm which key is stored. Syncing is paused — disconnect, then connect again."
        case .partial: "Only part of an API key is stored (an earlier removal didn't finish). Disconnect to remove it."
        case .missing, .stored:
            protectionUpgradeFailed ? "The stored key couldn't be moved to stronger Keychain protection yet. It keeps working; WealthOS will retry." : nil
        }
    }
}

// MARK: - Investments card

/// Synced Trading 212 cash and positions. Values come from `FinanceEngine`, the same source as
/// Home, Goals and the Simulator, so every screen shows the same numbers.
struct Trading212PortfolioCard: View {
    let engine: FinanceEngine
    @Environment(Trading212Service.self) private var service
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"

    var body: some View {
        if let snapshot = engine.broker.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Trading 212") {
                    NavigationLink("Manage") { Trading212SettingsView() }.font(.subheadline.weight(.medium))
                }
                VStack(alignment: .leading, spacing: 14) {
                    header(snapshot)
                    MetricRow(metrics: [
                        Metric(title: "Total", value: MoneyFormat.string(engine.brokerTotalBase, code: baseCurrency, fractionDigits: 0)),
                        Metric(title: "Cash", value: engine.brokerCashBase.map { MoneyFormat.string($0, code: baseCurrency, fractionDigits: 0) }
                               ?? MoneyFormat.string(snapshot.cashTotal, code: snapshot.currencyCode, fractionDigits: 0)),
                        Metric(title: "Positions", value: "\(engine.brokerPositions.count)"),
                    ])
                    NavigationLink { PortfolioDetailView(engine: engine) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "chart.xyaxis.line").foregroundStyle(Theme.accent)
                            Text("History & Returns").font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if duplicateCount > 0 {
                        NavigationLink { Trading212SettingsView() } label: {
                            InfoBanner(text: "\(duplicateCount) manual record\(duplicateCount == 1 ? "" : "s") may track the same money as Trading 212. Tap to review so nothing is counted twice.",
                                       symbol: "exclamationmark.triangle.fill", tint: .orange)
                        }
                        .buttonStyle(.plain)
                    }
                    if !engine.brokerPositions.isEmpty {
                        Divider()
                        let sorted = engine.brokerPositions.sorted { ($0.valueBase ?? 0) > ($1.valueBase ?? 0) }
                        ForEach(sorted) { value in
                            BrokerPositionRow(value: value)
                            if value.id != sorted.last?.id { Divider() }
                        }
                    }
                }
                .card(padding: 14)
            }
        }
    }

    private func header(_ snapshot: BrokerAccountSnapshot) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: "building.columns.fill", color: Theme.accentFill, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.isConnected ? snapshot.environment.title : "Not connected")
                    .font(.subheadline.weight(.semibold))
                TimelineView(.everyMinute) { _ in
                    Text(service.isSyncing ? "Syncing…" : "Synced \(snapshot.syncedAt.relativeDescription)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if snapshot.restoredFromBackup {
                    Text("Restored from backup — not re-synced yet, values may be outdated")
                        .font(.caption).foregroundStyle(Theme.warning).lineLimit(2)
                }
                if let error = service.lastError {
                    Text(error.errorDescription ?? "Sync failed.")
                        .font(.caption).foregroundStyle(Theme.warning).lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            if service.isConnected && !app.isDemoMode {
                Button {
                    Task { await service.sync(context: context, force: true) }
                } label: {
                    if service.isSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise").font(.body.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(service.isSyncing)
                .accessibilityLabel("Sync Trading 212")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var duplicateCount: Int {
        Trading212Matching.holdingCandidates(holdings: engine.holdings, positions: engine.broker.positions, links: engine.broker.links).count
            + Trading212Matching.accountCandidates(accounts: engine.accounts, links: engine.broker.links).count
    }
}

struct BrokerPositionRow: View {
    let value: BrokerPositionValue

    var body: some View {
        let position = value.position
        HStack(spacing: 12) {
            IconBadge(symbol: position.assetClass.symbol, color: Theme.color(named: position.assetClass.colorName))
            VStack(alignment: .leading, spacing: 3) {
                Text(position.displaySymbol).font(.body.weight(.semibold)).lineLimit(1)
                if !position.name.isEmpty {
                    Text(position.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(priceLine(position))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(valueText(position))
                    .font(.body.weight(.semibold)).monospacedDigit()
                if let fraction = returnFraction(position) {
                    Text(MoneyFormat.percent(fraction, showSign: true))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Theme.signColor(fraction))
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func priceLine(_ position: BrokerPosition) -> String {
        let quantity = MoneyFormat.quantity(position.quantity)
        guard let price = position.currentPrice, !position.instrumentCurrency.isEmpty else { return quantity }
        return "\(quantity) × \(MoneyFormat.string(price, code: position.instrumentCurrency))"
    }

    private func valueText(_ position: BrokerPosition) -> String {
        if let current = position.currentValue, !position.valueCurrency.isEmpty {
            return MoneyFormat.string(current, code: position.valueCurrency)
        }
        if let price = position.currentPrice, !position.instrumentCurrency.isEmpty {
            return MoneyFormat.string(price * position.quantity, code: position.instrumentCurrency)
        }
        return "—"
    }

    private func returnFraction(_ position: BrokerPosition) -> Decimal? {
        guard let cost = position.totalCost, cost > 0 else { return nil }
        let profit = position.unrealizedProfitLoss ?? position.currentValue.map { $0 - cost }
        return profit.map { $0 / cost }
    }
}
