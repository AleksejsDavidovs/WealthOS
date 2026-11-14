import SwiftUI
import SwiftData

/// Manually record a historical (or current) net worth value, e.g. from old statements.
struct SnapshotEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"
    @State private var date = Date.now
    @State private var amountText = ""
    @State private var note = ""
    @State private var saved = false

    private var validation: AmountValidation { .money(amountText, allowZero: true, allowNegative: true) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                    AmountField(title: "Net worth", text: $amountText, currencyCode: baseCurrency,
                                validation: validation, allowNegative: true)
                    TextField("Note (optional)", text: $note)
                } footer: {
                    Text("Manual snapshots appear as diamonds on the history chart, separate from values recorded automatically by the app.")
                }
            }
            .navigationTitle("Record Snapshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(validation.value == nil)
                }
            }
            .sensoryFeedback(.success, trigger: saved)
        }
    }

    private func save() {
        guard let value = validation.value else { return }
        context.insert(NetWorthSnapshot(date: date, netWorth: value, source: .manual, currencyCode: baseCurrency, note: note))
        try? context.save()
        saved = true
        dismiss()
    }
}

struct SnapshotListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \NetWorthSnapshot.date, order: .reverse) private var snapshots: [NetWorthSnapshot]
    @State private var showEditor = false

    var body: some View {
        List {
            if snapshots.isEmpty {
                ContentUnavailableView("No Snapshots", systemImage: "chart.xyaxis.line",
                                       description: Text("Snapshots are recorded automatically once a day, or add past values manually."))
            }
            ForEach(snapshots) { snapshot in
                HStack {
                    Image(systemName: snapshot.source == .manual ? "diamond.fill" : "circle.fill")
                        .foregroundStyle(snapshot.source == .manual ? .orange : Theme.accent)
                        .font(.caption)
                        .accessibilityLabel(snapshot.source == .manual ? "Manual" : "Automatic")
                    VStack(alignment: .leading) {
                        Text(snapshot.date.formatted(date: .abbreviated, time: .omitted))
                        if !snapshot.note.isEmpty {
                            Text(snapshot.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    MoneyText(amount: snapshot.netWorth, code: snapshot.currencyCode)
                }
            }
            .onDelete { offsets in
                for index in offsets { context.delete(snapshots[index]) }
                try? context.save()
            }
        }
        .navigationTitle("Snapshots")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showEditor = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Record snapshot")
            }
        }
        .sheet(isPresented: $showEditor) { SnapshotEditorView() }
    }
}
