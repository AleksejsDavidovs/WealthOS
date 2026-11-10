import SwiftUI
import SwiftData

// MARK: - Settings → Integrations → Binance

struct BinanceSettingsView: View {
    @Environment(BinanceService.self) private var service
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query private var snapshots: [BinanceAccountSnapshot]
    @Query private var balances: [BinanceHolding]
    @Query private var links: [BinanceLink]
    @Query(sort: \Holding.name) private var holdings: [Holding]
    @Query(sort: \Account.name) private var accounts: [Account]

    // Credentials live only in these fields until `connect` stores them in the Keychain.
    @State private var apiKey = ""
    @State private var secretKey = ""
    @State private var isConnecting = false
    @State private var message: String?
    @State private var showDisconnect = false
    @State private var showRemoveCache = false

    var body: some View {
        Form {
            if app.isDemoMode {
                Section {
                    Label("Binance is unavailable in demo mode. Exit demo mode to connect your account.",
                          systemImage: "theatermasks.fill")
                }
            } else {
                if service.isConnected { statusSection }
                if !service.isConnected || service.needsReconnect { connectSection }
                if let snapshot = snapshots.first {
                    if !service.isConnected { cachedSection(snapshot) }
                    duplicatesSection
                }
                if service.isConnected { disconnectSection }
            }
            aboutSection
        }
        .navigationTitle("Binance")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onDisappear { apiKey = ""; secretKey = "" }
        .confirmationDialog("Disconnect Binance?", isPresented: $showDisconnect, titleVisibility: .visible) {
            Button("Disconnect, Keep Last Synced Data") { disconnect(removeData: false) }
            Button("Disconnect and Remove Binance Data", role: .destructive) { disconnect(removeData: true) }
        } message: {
            Text("The API key and secret are deleted from this iPhone. Kept data stays in your totals but no longer updates. Your manual accounts, holdings and transactions are never changed. You can also delete the key in Binance → API Management.")
        }
        .confirmationDialog("Remove cached Binance data?", isPresented: $showRemoveCache, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { disconnect(removeData: true) }
        } message: {
            Text("Removes the last synced Binance balances from WealthOS totals. Manual records are not changed.")
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            if let snapshot = snapshots.first {
                LabeledContent("Last synced", value: snapshot.syncedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Flexible Earn", value: earnText(snapshot.flexibleStatus, snapshot.flexibleSyncedAt))
                LabeledContent("Locked Earn", value: earnText(snapshot.lockedStatus, snapshot.lockedSyncedAt))
                LabeledContent("Prices updated", value: snapshot.pricesFetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                LabeledContent("Assets", value: "\(Set(balances.map(\.asset)).count)")
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
            ForEach(service.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Syncs automatically when you open WealthOS or Investments if the data is older than 15 minutes. If a sync fails, the last synced data stays in place.")
        }
    }

    private var connectSection: some View {
        Section {
            SecureField("API key", text: $apiKey)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("Secret key", text: $secretKey)
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
            .disabled(isConnecting || service.isSyncing || apiKey.isEmpty || secretKey.isEmpty)
            if let message {
                Text(message).font(.footnote).foregroundStyle(Theme.negative)
            }
        } header: {
            Text(service.needsReconnect ? "Reconnect" : "Connect")
        } footer: {
            Text("In Binance, open Account → API Management and create a system-generated (HMAC) API key with only “Enable Reading”. WealthOS checks the key's permissions with Binance and refuses keys that allow trading, transfers or withdrawals. The key and secret are stored only in the iOS Keychain on this iPhone.")
        }
    }

    private func cachedSection(_ snapshot: BinanceAccountSnapshot) -> some View {
        Section {
            LabeledContent("Last synced", value: snapshot.syncedAt.formatted(date: .abbreviated, time: .shortened))
            Button("Remove Cached Data", role: .destructive) { showRemoveCache = true }
        } header: {
            Text("Not connected")
        } footer: {
            Text("The last synced Binance balances are still counted in your totals but no longer update.")
        }
    }

    @ViewBuilder
    private var duplicatesSection: some View {
        let linked = Set(links.map(\.localID))
        let assets = Set(balances.map(\.asset))
        let suggestedHoldings = Dictionary(BinanceMatching.holdingCandidates(holdings: holdings, assets: assets, links: links)
            .map { ($0.holding.id, $0.asset) }, uniquingKeysWith: { a, _ in a })
        let suggestedAccounts = Set(BinanceMatching.accountCandidates(accounts: accounts, links: links).map(\.id))
        let shownHoldings = holdings.filter { $0.assetClass == .crypto || linked.contains($0.id) }
        let shownAccounts = accounts.filter {
            linked.contains($0.id) || suggestedAccounts.contains($0.id) || ($0.kind == .crypto && !$0.isArchived)
        }
        if !shownHoldings.isEmpty || !shownAccounts.isEmpty {
            Section {
                ForEach(shownAccounts) { account in
                    linkToggle(title: account.name, detail: suggestedAccounts.contains(account.id) ? "Looks like your Binance balance" : nil,
                               isOn: linked.contains(account.id), kind: .account, id: account.id)
                }
                ForEach(shownHoldings) { holding in
                    linkToggle(title: holding.symbol.isEmpty ? holding.name : holding.symbol,
                               detail: suggestedHoldings[holding.id].map { "Binance also holds \($0)" },
                               isOn: linked.contains(holding.id), kind: .holding, id: holding.id)
                }
            } header: {
                Text("Avoid Double Counting")
            } footer: {
                Text("Turn on “Counted via Binance” for manual crypto holdings or accounts that track the same coins as your Binance account. They stay in WealthOS with their history and cost basis, but are left out of Net Worth because Binance already counts them. Nothing is linked automatically.")
            }
        }
    }

    private func linkToggle(title: String, detail: String?, isOn: Bool, kind: BrokerLink.Kind, id: UUID) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { setLinked($0, kind: kind, id: id) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail ?? (isOn ? "Counted via Binance" : "Counted separately"))
                    .font(.caption).foregroundStyle(detail != nil ? Theme.warning : .secondary)
            }
        }
    }

    private var disconnectSection: some View {
        Section {
            Button("Disconnect Binance", role: .destructive) { showDisconnect = true }
                .disabled(isConnecting)
        }
    }

    private var aboutSection: some View {
        Section("Read-only") {
            Label("WealthOS only reads your key's permissions, Spot balances, Simple Earn positions and public market prices. It can't trade, convert, transfer, withdraw, or subscribe to or redeem Earn products.",
                  systemImage: "lock.shield")
                .font(.footnote)
            Label("Requests go directly from this iPhone to api.binance.com over HTTPS, signed on the device. No WealthOS server is involved.",
                  systemImage: "iphone")
                .font(.footnote)
            Label("Binance balances don't include what you paid, so cost basis and profit/loss are shown as unavailable.",
                  systemImage: "info.circle")
                .font(.footnote)
        }
    }

    private func earnText(_ status: BinanceEarnStatus, _ date: Date?) -> String {
        switch status {
        case .ok: date.map { "Synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "Synced"
        case .unavailable: "Not readable with this key"
        case .failed: date.map { "Couldn't refresh · last \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Couldn't refresh"
        case .notChecked: "Not checked yet"
        }
    }

    // MARK: Actions

    private func connect() {
        isConnecting = true
        message = nil
        Task {
            defer { isConnecting = false }
            do {
                try await service.connect(apiKey: apiKey, secretKey: secretKey, context: context)
                apiKey = ""
                secretKey = ""
            } catch is CancellationError {
            } catch {
                message = (error as? BinanceError)?.errorDescription ?? "Couldn't connect to Binance."
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
                try BinanceReconciler.setLinked(linked, kind: kind, localID: id, in: context)
            }
            DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Investments card

/// Synced Binance crypto. Values come from `FinanceEngine`, the same source as Home, Goals and
/// the Simulator, so every screen shows the same numbers.
struct BinancePortfolioCard: View {
    let engine: FinanceEngine
    @Environment(BinanceService.self) private var service
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"

    var body: some View {
        if let snapshot = engine.binance.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Binance") {
                    NavigationLink("Manage") { BinanceSettingsView() }.font(.subheadline.weight(.medium))
                }
                VStack(alignment: .leading, spacing: 14) {
                    header(snapshot)
                    MetricRow(metrics: [
                        Metric(title: "Total Crypto", value: MoneyFormat.string(engine.binanceTotalBase, code: baseCurrency)),
                        Metric(title: "Spot", value: MoneyFormat.string(engine.binanceSpotBase, code: baseCurrency, fractionDigits: 0)),
                        Metric(title: "Earn", value: earnUnreadable(snapshot) && engine.binanceAssets.allSatisfy({ $0.earnQuantity == 0 })
                               ? "Unavailable" : MoneyFormat.string(engine.binanceEarnBase, code: baseCurrency, fractionDigits: 0)),
                        Metric(title: "Assets", value: "\(engine.binanceAssets.count)"),
                    ])
                    banners(snapshot)
                    if !engine.binanceAssets.isEmpty {
                        Divider()
                        ForEach(engine.binanceAssets) { value in
                            BinanceAssetRow(value: value, syncedAt: snapshot.syncedAt)
                            if value.id != engine.binanceAssets.last?.id { Divider() }
                        }
                    } else {
                        Text("No crypto balances on Binance.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .card(padding: 14)
            }
        }
    }

    private func earnUnreadable(_ snapshot: BinanceAccountSnapshot) -> Bool {
        snapshot.flexibleStatus == .unavailable || snapshot.lockedStatus == .unavailable
    }

    @ViewBuilder
    private func banners(_ snapshot: BinanceAccountSnapshot) -> some View {
        let unpriced = engine.binanceUnpriced.map(\.asset)
        if !unpriced.isEmpty {
            InfoBanner(text: "No reliable EUR price on Binance for \(unpriced.joined(separator: ", ")). \(unpriced.count == 1 ? "It's" : "They're") shown by quantity and left out of totals.",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
        if earnUnreadable(snapshot) {
            InfoBanner(text: "Simple Earn isn't readable with this API key, so Earn balances are unknown — not zero — and aren't included.",
                       symbol: "eye.slash", tint: .orange)
        }
        if !snapshot.mergedSpotAssets.isEmpty {
            InfoBanner(text: "Binance also lists Flexible Earn in Spot (\(snapshot.mergedSpotAssets)). Those are counted once, as Earn.")
        }
        if duplicateCount > 0 {
            NavigationLink { BinanceSettingsView() } label: {
                InfoBanner(text: "\(duplicateCount) manual record\(duplicateCount == 1 ? "" : "s") may track the same crypto as Binance. Tap to review so nothing is counted twice.",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            .buttonStyle(.plain)
        }
    }

    private func header(_ snapshot: BinanceAccountSnapshot) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: "bitcoinsign.circle.fill", color: Theme.accentFill, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.isConnected ? "Live · read-only" : "Not connected").font(.subheadline.weight(.semibold))
                TimelineView(.everyMinute) { _ in
                    Text(service.isSyncing ? "Syncing…" : "Synced \(snapshot.syncedAt.relativeDescription)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = service.lastError {
                    Text(error.errorDescription ?? "Sync failed.")
                        .font(.caption).foregroundStyle(Theme.warning).lineLimit(3)
                }
                ForEach(service.warnings, id: \.self) { warning in
                    Text(warning).font(.caption).foregroundStyle(.secondary).lineLimit(3)
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
                .accessibilityLabel("Sync Binance")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var duplicateCount: Int {
        BinanceMatching.holdingCandidates(holdings: engine.holdings, assets: Set(engine.binanceAssets.map(\.asset)),
                                          links: engine.binance.links).count
            + BinanceMatching.accountCandidates(accounts: engine.accounts, links: engine.binance.links).count
    }
}

struct BinanceAssetRow: View {
    let value: BinanceAssetValue
    let syncedAt: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: AssetClass.crypto.symbol, color: Theme.color(named: AssetClass.crypto.colorName))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(value.asset).font(.body.weight(.semibold))
                    if let name = Self.name(for: value.asset) {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Text("\(Self.quantity(value.quantity)) \(value.asset)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(value.wallets.map(\.title).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(priceStatus)
                    .font(.caption2).foregroundStyle(value.priceEUR == nil ? Theme.warning : .secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let eur = value.valueEUR {
                    Text(MoneyFormat.string(eur, code: BinancePricing.target)).font(.body.weight(.semibold)).monospacedDigit()
                } else {
                    Text("No price").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text("Cost basis n/a").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var priceStatus: String {
        guard let price = value.priceEUR, let date = value.pricedAt else { return "No validated EUR price on Binance" }
        let age = date < syncedAt ? "Cached price · \(date.relativeDescription)" : "Price \(date.relativeDescription)"
        return "\(MoneyFormat.string(price, code: BinancePricing.target, fractionDigits: price < 1 ? 6 : 2)) · \(age) · \(value.priceRoute)"
    }

    /// Full precision (up to 18 places) so small balances are never displayed as 0.
    static func quantity(_ amount: Decimal) -> String {
        amount.formatted(.number.precision(.fractionLength(0...18)))
    }

    static func name(for asset: String) -> String? {
        PopularAssets.crypto.first { $0.ticker.uppercased() == asset.uppercased() }?.name
    }
}
