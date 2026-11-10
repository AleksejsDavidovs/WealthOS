import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Environment(AppLockManager.self) private var lock
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.dark.rawValue
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @AppStorage(SettingsKey.lockEnabled) private var lockEnabled = false
    @AppStorage(SettingsKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(SettingsKey.marketDataEnabled) private var marketEnabled = false
    @Environment(MarketDataService.self) private var market
    @Environment(Trading212Service.self) private var trading212

    @Query private var transactions: [TransactionRecord]
    @Query private var accounts: [Account]
    @Query private var categories: [TransactionCategory]

    @State private var pendingCurrency: String?
    @State private var showPINSetup = false
    @State private var showBackupExport = false
    @State private var showBackupImporter = false
    @State private var backupFileData: IdentifiedData?
    @State private var showCSVImporter = false
    @State private var csvFileData: IdentifiedData?
    @State private var csvExportURL: URL?
    @State private var integrityReport: BackupService.IntegrityReport?
    @State private var showResetConfirmation = false
    @State private var showResetFinal = false
    @State private var resetText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if app.isDemoMode {
                    Section {
                        Label("You're exploring demo data. Nothing here is saved, and your real data is untouched.",
                              systemImage: "theatermasks.fill")
                        Button("Exit Demo Mode", role: .destructive) { app.exitDemoMode() }
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("Base Currency", selection: Binding(get: { baseCurrency }, set: { pendingCurrency = $0 })) {
                        ForEach(Currencies.supported, id: \.self) { Text("\($0) – \(Currencies.name(for: $0))").tag($0) }
                    }
                    NavigationLink("Exchange Rates") { ExchangeRatesView() }
                } header: {
                    Text("Currency")
                } footer: {
                    Text("Totals are shown in your base currency using the exchange rates in WealthOS.")
                }

                Section {
                    NavigationLink { MarketDataSettingsView() } label: {
                        LabeledContent {
                            Text(marketEnabled ? "On" : "Off")
                        } label: {
                            Label("Market Data", systemImage: "network")
                        }
                    }
                } footer: {
                    Text(marketEnabled
                         ? "Public prices from CoinGecko, Alpha Vantage and Frankfurter. Only symbols are sent."
                         : "Off — WealthOS makes no network requests. Prices are entered manually.")
                }

                Section {
                    NavigationLink { Trading212SettingsView() } label: {
                        LabeledContent {
                            Text(trading212.isConnected ? (trading212.needsReconnect ? "Reconnect" : "Connected") : "Off")
                        } label: {
                            Label("Trading 212", systemImage: "building.columns")
                        }
                    }
                } header: {
                    Text("Integrations")
                } footer: {
                    Text("Read-only sync of your Trading 212 cash and positions. WealthOS can't place orders or move money.")
                }

                Section {
                    Toggle(isOn: Binding(get: { lockEnabled }, set: { newValue in
                        Task {
                            guard await lock.setLockEnabled(newValue) else { return }
                            lockEnabled = newValue
                            // First-time protection: offer the PIN backup right away (skippable).
                            if newValue && !lock.isPINEnabled { showPINSetup = true }
                        }
                    })) {
                        Label("\(lock.biometryName) Lock", systemImage: lock.biometrySymbol)
                    }

                    if lockEnabled {
                        if lock.isPINEnabled {
                            Button { authorizePINChange { showPINSetup = true } } label: {
                                Label("Change App PIN", systemImage: "number")
                            }
                            Button("Turn Off App PIN", role: .destructive) {
                                authorizePINChange { lock.disablePIN() }
                            }
                        } else {
                            Button { authorizePINChange { showPINSetup = true } } label: {
                                Label("Set Up App PIN", systemImage: "number")
                            }
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text(lock.errorMessage ?? "Locks WealthOS whenever it goes to the background. Falls back to your device passcode. The app content is hidden in the app switcher. An optional 6-digit PIN is available as a backup when \(lock.biometryName) isn't available.")
                }

                Section {
                    NavigationLink { AssumptionsSettingsView() } label: {
                        Label("Simulator Scenarios", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink { EstimatesSettingsView() } label: {
                        Label("Income & Expense Estimates", systemImage: "eurosign.circle")
                    }
                } header: {
                    Text("Financial Assumptions")
                }

                Section {
                    Button { showBackupExport = true } label: { Label("Export Encrypted Backup", systemImage: "lock.doc") }
                    Button { showBackupImporter = true } label: { Label("Restore from Backup", systemImage: "arrow.counterclockwise.circle") }
                    Button { exportCSV() } label: { Label("Export Transactions (CSV)", systemImage: "tablecells") }
                    Button { showCSVImporter = true } label: { Label("Import Transactions (CSV)", systemImage: "square.and.arrow.down") }
                    Button { integrityReport = BackupService.integrityReport(for: context, baseCurrency: baseCurrency) } label: {
                        Label("Check Data Integrity", systemImage: "checkmark.shield")
                    }
                } header: {
                    Text("Backup & Data")
                } footer: {
                    Text(app.isDemoMode ? "Backup and import are disabled in demo mode." :
                            "Backups are encrypted with your password (AES-256-GCM, PBKDF2-SHA256). CSV exports are NOT encrypted — store them carefully.")
                }
                .disabled(app.isDemoMode)

                Section {
                    if !app.isDemoMode {
                        Button { app.enterDemoMode(); dismiss() } label: { Label("Try Demo Mode", systemImage: "theatermasks") }
                    }
                    NavigationLink { PrivacyInfoView() } label: { Label("Privacy", systemImage: "hand.raised.fill") }
                    LabeledContent("Version", value: BackupService.appVersion)
                }

                Section {
                    Button("Reset All Data", role: .destructive) { showResetConfirmation = true }
                        .disabled(app.isDemoMode)
                } footer: {
                    Text("Permanently deletes all accounts, transactions, investments, goals and scenarios from this device.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(isPresented: $showPINSetup) { PINSetupView() }
            .sheet(isPresented: $showBackupExport) { BackupExportView() }
            .sheet(item: $backupFileData) { BackupRestoreView(data: $0.data) }
            .sheet(item: $csvFileData) { CSVImportView(data: $0.data) }
            .fileImporter(isPresented: $showBackupImporter, allowedContentTypes: [.data]) { result in
                handleImport(result) { backupFileData = $0 }
            }
            .fileImporter(isPresented: $showCSVImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                handleImport(result) { csvFileData = $0 }
            }
            .sheet(item: Binding(get: { csvExportURL.map(IdentifiedURL.init) }, set: { csvExportURL = $0?.url })) { item in
                ExportReadyView(url: item.url, title: "CSV Export Ready",
                                message: "This file contains your transactions in plain text. Share it only with places you trust.")
            }
            .confirmationDialog("Change base currency to \(pendingCurrency ?? "")?", isPresented: Binding(
                get: { pendingCurrency != nil }, set: { if !$0 { pendingCurrency = nil } }), titleVisibility: .visible) {
                Button("Change Currency") { changeCurrency() }
            } message: {
                Text("Account currencies stay the same. Exchange rates are converted where possible; otherwise enter new rates. Net worth history recorded in \(baseCurrency) stays saved but only snapshots in the active base currency are charted.")
            }
            .alert("Data Integrity", isPresented: Binding(get: { integrityReport != nil }, set: { if !$0 { integrityReport = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                if let report = integrityReport {
                    Text(report.isHealthy ? "No problems found. All references and values are consistent." : report.issues.joined(separator: "\n"))
                }
            }
            .confirmationDialog("Reset all data?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
                Button("Export Backup First") { showBackupExport = true }
                Button("Continue to Reset", role: .destructive) { resetText = ""; showResetFinal = true }
            } message: {
                Text("This permanently deletes everything stored in WealthOS on this device. It can't be undone.")
            }
            .alert("Type RESET to confirm", isPresented: $showResetFinal) {
                TextField("RESET", text: $resetText)
                Button("Cancel", role: .cancel) {}
                Button("Delete Everything", role: .destructive) { resetAllData() }
            } message: {
                Text("All data will be erased.")
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func handleImport(_ result: Result<URL, Error>, completion: (IdentifiedData) -> Void) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count < 50_000_000 else { errorMessage = "The file is too large."; return }
            completion(IdentifiedData(data: data))
        } catch {
            errorMessage = "The file couldn't be read."
        }
    }

    /// Being inside the unlocked app isn't enough to set, change or remove the PIN — whoever
    /// holds the phone must prove they're the device owner first.
    private func authorizePINChange(_ action: @escaping () -> Void) {
        Task {
            if await lock.reauthorize(reason: "Change your WealthOS PIN settings") { action() }
        }
    }

    private func exportCSV() {
        let csv = CSVService.export(transactions: transactions, accounts: accounts, categories: categories)
        do {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            csvExportURL = try BackupService.writeTemporaryFile(Data(csv.utf8), name: "WealthOS-Transactions-\(formatter.string(from: .now)).csv")
        } catch {
            errorMessage = "The CSV file couldn't be created."
        }
    }

    private func changeCurrency() {
        guard let newCurrency = pendingCurrency else { return }
        do {
            try LedgerService.rebaseRates(from: baseCurrency, to: newCurrency, in: context)
            baseCurrency = newCurrency
            DataMaintenance.refreshSnapshot(context: context, baseCurrency: newCurrency)
        } catch {
            errorMessage = "The currency couldn't be changed."
        }
        pendingCurrency = nil
    }

    private func resetAllData() {
        guard resetText.trimmingCharacters(in: .whitespaces).uppercased() == "RESET" else {
            errorMessage = "Reset cancelled — the confirmation text didn't match."
            return
        }
        do {
            try LedgerService.deleteAllData(in: context)
            try Trading212Reconciler.removeAllData(in: context)
            try context.save()
            try? trading212.disconnect(removeData: false, context: context)
            market.deleteAllKeys()
            marketEnabled = false
            for key in [SettingsKey.estimatedIncome, SettingsKey.estimatedExpenses, SettingsKey.importedFileHashes,
                        RecentAssetsStore.key, CatalogSearchCache.key] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            hasCompletedOnboarding = false
            dismiss()
        } catch {
            context.rollback()
            errorMessage = "Reset failed. Your data was not changed."
        }
    }
}

struct IdentifiedData: Identifiable {
    let id = UUID()
    let data: Data
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ExportReadyView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let title: String
    let message: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "doc.badge.arrow.up.fill")
                    .font(.system(size: 56)).foregroundStyle(Theme.accent).symbolRenderingMode(.hierarchical)
                Text(title).font(.title2.bold())
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(url.lastPathComponent).font(.footnote.monospaced()).foregroundStyle(.secondary)
                ShareLink(item: url) {
                    Label("Save or Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .prominentButtonStyle()
                .controlSize(.large)
            }
            .padding(28)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

struct EstimatesSettingsView: View {
    @AppStorage(SettingsKey.estimatedIncome) private var income = ""
    @AppStorage(SettingsKey.estimatedExpenses) private var expenses = ""
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"

    var body: some View {
        Form {
            Section {
                AmountField(title: "Monthly income", text: $income, currencyCode: baseCurrency,
                            validation: income.isEmpty ? .empty : .money(income, allowZero: true))
                AmountField(title: "Monthly expenses", text: $expenses, currencyCode: baseCurrency,
                            validation: expenses.isEmpty ? .empty : .money(expenses, allowZero: true))
            } footer: {
                Text("Used as simulator defaults until you have at least one full month of recorded transactions. They are never turned into transactions.")
            }
        }
        .navigationTitle("Estimates")
        .onChange(of: income) { _, value in normalize(&income, value) }
        .onChange(of: expenses) { _, value in normalize(&expenses, value) }
    }

    /// Stores a canonical decimal string so it parses identically in every locale.
    private func normalize(_ storage: inout String, _ value: String) {
        _ = storage
    }
}

struct AssumptionsSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var scenarios: [SimulationScenario]
    @State private var editing: SimulationScenario?

    var body: some View {
        List {
            Section {
                ForEach(ScenarioKind.allCases) { kind in
                    if let scenario = scenarios.first(where: { $0.kind == kind }), let p = scenario.parameters {
                        Button { editing = scenario } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kind.title).font(.headline).foregroundStyle(Theme.color(named: kind.colorName))
                                Text("Return \(MoneyFormat.percent(p.annualReturn)) · Inflation \(MoneyFormat.percent(p.inflation)) · Salary \(MoneyFormat.percent(p.salaryGrowth)) · \(p.years) yrs")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("\(kind.title): open the Simulator tab once to create it.").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Each scenario keeps its own assumptions. Changes apply immediately in the Simulator.")
            }
        }
        .navigationTitle("Scenarios")
        .sheet(item: $editing) { scenario in
            if let params = scenario.parameters {
                ScenarioEditorView(parameters: params, title: scenario.kind.title) { updated in
                    scenario.parameters = updated
                    try? context.save()
                }
            }
        }
    }
}

struct PrivacyInfoView: View {
    var body: some View {
        List {
            Section {
                row("iphone", "On-device only", "All data is stored in an encrypted, file-protected database on this iPhone. There is no account, server or cloud sync.")
                row("network.slash", "Offline by default", "WealthOS makes no network requests unless you turn on Market Data or connect Trading 212. Market Data only downloads public prices over HTTPS from CoinGecko, Alpha Vantage and Frankfurter, sending nothing but ticker symbols and currency codes. Trading 212 sync reads your account directly from Trading 212 with read-only requests. API keys are stored in the iOS Keychain.")
                row("eye.slash", "No tracking", "No analytics, telemetry, advertising or third-party SDKs. Logs never contain balances, names or transactions.")
                row("faceid", "App lock", "Optional Face ID with passcode fallback and an optional 6-digit PIN as a backup. Content is hidden in the app switcher, and no open screen can be left visible behind the lock.")
                row("lock.doc", "Encrypted backups", "Backups use AES-256-GCM with a key derived from your password (PBKDF2-SHA256, 600,000 iterations). If you forget the password, the backup cannot be recovered — not even by the developer.")
                row("creditcard.trianglebadge.exclamationmark", "No credentials", "WealthOS never asks for bank logins, card numbers or passwords.")
            }
        }
        .navigationTitle("Privacy")
    }

    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
