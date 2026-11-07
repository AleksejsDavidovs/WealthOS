import SwiftUI
import SwiftData

struct BackupExportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @State private var password = ""
    @State private var confirmation = ""
    @State private var acknowledged = false
    @State private var isWorking = false
    @State private var exportURL: URL?
    @State private var errorMessage: String?

    private var validationMessage: String? {
        if password.count < BackupCrypto.minimumPasswordLength { return "Use at least \(BackupCrypto.minimumPasswordLength) characters." }
        if password != confirmation { return "Passwords don't match." }
        if !acknowledged { return "Confirm that you've stored the password safely." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let exportURL {
                    Section {
                        VStack(spacing: 14) {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundStyle(Theme.positive)
                            Text("Backup encrypted").font(.headline)
                            Text(exportURL.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                            ShareLink(item: exportURL) {
                                Label("Save to Files or Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }
                            .prominentButtonStyle()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } footer: {
                        Text("Keep the backup somewhere safe, e.g. iCloud Drive or a computer. It's useless without the password.")
                    }
                } else {
                    Section {
                        SecureField("Backup password", text: $password)
                            .textContentType(.newPassword)
                        SecureField("Confirm password", text: $confirmation)
                            .textContentType(.newPassword)
                    } footer: {
                        Text("The backup is encrypted with AES-256-GCM using a key derived from this password (PBKDF2-SHA256).")
                    }
                    Section {
                        Toggle(isOn: $acknowledged) {
                            Text("I understand that if I lose this password, the backup **cannot be recovered** by anyone.")
                                .font(.subheadline)
                        }
                    }
                    Section {
                        Button {
                            Task { await export() }
                        } label: {
                            HStack {
                                Spacer()
                                if isWorking { ProgressView() } else { Text("Create Encrypted Backup").bold() }
                                Spacer()
                            }
                        }
                        .disabled(validationMessage != nil || isWorking)
                    } footer: {
                        if let validationMessage, !password.isEmpty { Text(validationMessage) }
                    }
                }
            }
            .navigationTitle("Encrypted Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(exportURL == nil ? "Cancel" : "Done") { dismiss() } } }
            .alert("Backup Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func export() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await BackupService.encryptedBackup(from: context, baseCurrency: baseCurrency, password: password)
            exportURL = try BackupService.writeTemporaryFile(data, name: BackupService.backupFileName())
            password = ""
            confirmation = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct BackupRestoreView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @AppStorage(SettingsKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    let data: Data
    @State private var password = ""
    @State private var payload: BackupPayload?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showConfirm = false
    @State private var restored = false

    var body: some View {
        NavigationStack {
            Form {
                if restored {
                    Section {
                        Label("Backup restored successfully.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                    }
                } else if let payload {
                    Section("Backup Contents") {
                        LabeledContent("Created", value: payload.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("App version", value: payload.appVersion)
                        LabeledContent("Base currency", value: payload.baseCurrency)
                        LabeledContent("Accounts", value: "\(payload.accounts.count)")
                        LabeledContent("Transactions", value: "\(payload.transactions.count)")
                        LabeledContent("Holdings", value: "\(payload.holdings.count) (\(payload.trades.count) trades)")
                        LabeledContent("Goals", value: "\(payload.goals.count)")
                        LabeledContent("Snapshots", value: "\(payload.snapshots.count)")
                    }
                    Section {
                        Button("Replace All Data with Backup", role: .destructive) { showConfirm = true }
                            .disabled(isWorking)
                    } footer: {
                        Text("The backup passed integrity checks. Restoring replaces everything currently in WealthOS. If anything fails, your current data is kept.")
                    }
                } else {
                    Section {
                        SecureField("Backup password", text: $password)
                            .textContentType(.password)
                            .onSubmit { Task { await unlock() } }
                        Button {
                            Task { await unlock() }
                        } label: {
                            HStack { Spacer(); if isWorking { ProgressView() } else { Text("Decrypt Backup").bold() }; Spacer() }
                        }
                        .disabled(password.isEmpty || isWorking)
                    } footer: {
                        Text("Nothing is changed until you confirm the restore.")
                    }
                }
            }
            .navigationTitle("Restore Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(restored ? "Done" : "Cancel") { dismiss() } } }
            .confirmationDialog("Replace all current data?", isPresented: $showConfirm, titleVisibility: .visible) {
                Button("Replace All Data", role: .destructive) { restore() }
            } message: {
                Text("Your current accounts, transactions, investments and goals will be replaced by the backup.")
            }
            .alert("Restore Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func unlock() async {
        guard !password.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            payload = try await BackupService.readBackup(data, password: password)
            password = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore() {
        guard let payload else { return }
        do {
            try BackupService.restore(payload, into: context)
            baseCurrency = payload.baseCurrency
            hasCompletedOnboarding = true
            LedgerService.seedDefaultCategoriesIfNeeded(in: context)
            DataMaintenance.refreshSnapshot(context: context, baseCurrency: payload.baseCurrency)
            restored = true
        } catch {
            errorMessage = "The restore failed and your existing data was kept. (\(error.localizedDescription))"
        }
    }
}

struct CSVImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @Query private var accounts: [Account]
    @Query private var categories: [TransactionCategory]
    @Query private var transactions: [TransactionRecord]
    let data: Data
    @State private var preview: CSVService.ImportPreview?
    @State private var errorMessage: String?
    @State private var importedCount: Int?

    var body: some View {
        NavigationStack {
            Form {
                if let importedCount {
                    Section {
                        Label("Imported \(importedCount) transaction\(importedCount == 1 ? "" : "s").", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.positive)
                    }
                } else if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.negative)
                    } footer: {
                        Text("Expected columns: date, type (income/expense/transfer), amount, account; optional: currency, to_account, to_amount, category, note. Account names must match existing accounts.")
                    }
                } else if let preview {
                    if preview.fileAlreadyImported {
                        Section {
                            Label("This exact file was imported before. Duplicates are skipped automatically.",
                                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    Section("Summary") {
                        LabeledContent("Ready to import", value: "\(preview.rows.count)")
                        LabeledContent("Duplicates skipped", value: "\(preview.duplicates.count)")
                        LabeledContent("Rows with errors", value: "\(preview.errors.count)")
                        if !preview.newCategories.isEmpty {
                            LabeledContent("New categories", value: preview.newCategories.joined(separator: ", "))
                        }
                    }
                    if !preview.rows.isEmpty {
                        Section("Preview") {
                            ForEach(preview.rows.prefix(20)) { row in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(row.note.isEmpty ? (row.categoryName ?? row.kind.title) : row.note).lineLimit(1)
                                        Text("\(row.kind.title) · \(row.date.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(row.amount.formatted(.number.precision(.fractionLength(2)))).monospacedDigit()
                                }
                            }
                            if preview.rows.count > 20 {
                                Text("…and \(preview.rows.count - 20) more").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !preview.errors.isEmpty {
                        Section("Errors (not imported)") {
                            ForEach(preview.errors.prefix(30)) { error in
                                Text("Line \(error.line): \(error.message)").font(.caption)
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(importedCount == nil ? "Cancel" : "Done") { dismiss() } }
                if importedCount == nil, let preview, !preview.rows.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import \(preview.rows.count)") { commit(preview) }
                    }
                }
            }
            .task { buildPreview() }
        }
    }

    private func buildPreview() {
        guard preview == nil, errorMessage == nil else { return }
        do {
            preview = try CSVService.preview(data: data, accounts: accounts, categories: categories, existing: transactions,
                                             importedHashes: UserDefaults.standard.stringArray(forKey: SettingsKey.importedFileHashes) ?? [])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commit(_ preview: CSVService.ImportPreview) {
        do {
            importedCount = try CSVService.commit(preview, into: context)
            DataMaintenance.refreshSnapshot(context: context, baseCurrency: baseCurrency)
        } catch {
            context.rollback()
            errorMessage = "Import failed. No transactions were added."
        }
    }
}
