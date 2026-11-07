import SwiftUI
import SwiftData

struct CategoryManagerView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TransactionCategory.sortOrder) private var categories: [TransactionCategory]
    @State private var editing: CategoryEditorRequest?
    @State private var pendingDeletion: TransactionCategory?
    @State private var errorMessage: String?

    struct CategoryEditorRequest: Identifiable {
        let id = UUID()
        var category: TransactionCategory?
        var kind: CategoryKind
    }

    var body: some View {
        List {
            ForEach(CategoryKind.allCases, id: \.self) { kind in
                Section {
                    ForEach(categories.filter { $0.kind == kind }) { category in
                        Button { editing = .init(category: category, kind: kind) } label: {
                            HStack(spacing: 12) {
                                IconBadge(symbol: category.symbol, color: Theme.color(named: category.colorName), size: 30)
                                Text(category.name).foregroundStyle(.primary)
                                Spacer()
                                if category.isSystem {
                                    Text("Fallback").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            if !category.isSystem {
                                Button(role: .destructive) { pendingDeletion = category } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                    Button { editing = .init(category: nil, kind: kind) } label: {
                        Label("Add \(kind.title) Category", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("\(kind.title) Categories")
                } footer: {
                    if kind == .expense {
                        Text("Deleting a category moves its transactions to “Other”, so no data is lost.")
                    }
                }
            }
        }
        .navigationTitle("Categories")
        .sheet(item: $editing) { request in
            CategoryEditorView(category: request.category, kind: request.kind)
        }
        .confirmationDialog(deletionTitle, isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Category", role: .destructive) {
                if let pendingDeletion {
                    do { try LedgerService.delete(category: pendingDeletion, in: context) }
                    catch { errorMessage = "The category couldn't be deleted." }
                }
                pendingDeletion = nil
            }
        } message: {
            if let pendingDeletion {
                let count = LedgerService.usageCount(of: pendingDeletion, in: context)
                Text(count == 0 ? "This category isn't used by any transaction."
                     : "\(count) transaction\(count == 1 ? "" : "s") will be moved to the fallback category.")
            }
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var deletionTitle: String {
        "Delete “\(pendingDeletion?.name ?? "")”?"
    }
}

struct CategoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var categories: [TransactionCategory]
    let category: TransactionCategory?
    let kind: CategoryKind
    @State private var name: String
    @State private var symbol: String
    @State private var colorName: String

    static let symbols = ["tag.fill", "fork.knife", "cart.fill", "bag.fill", "tram.fill", "car.fill", "fuelpump.fill", "airplane",
                          "house.fill", "bolt.fill", "drop.fill", "wifi", "phone.fill", "tv.fill", "gamecontroller.fill",
                          "popcorn.fill", "music.note", "book.fill", "graduationcap.fill", "heart.fill", "cross.case.fill",
                          "pills.fill", "dumbbell.fill", "pawprint.fill", "gift.fill", "cup.and.saucer.fill", "wineglass.fill",
                          "tshirt.fill", "scissors", "wrench.and.screwdriver.fill", "briefcase.fill", "laptopcomputer",
                          "banknote.fill", "creditcard.fill", "building.columns.fill", "chart.line.uptrend.xyaxis",
                          "repeat.circle.fill", "figure.and.child.holdinghands", "leaf.fill", "ellipsis.circle.fill"]

    init(category: TransactionCategory?, kind: CategoryKind) {
        self.category = category
        self.kind = kind
        _name = State(initialValue: category?.name ?? "")
        _symbol = State(initialValue: category?.symbol ?? "tag.fill")
        _colorName = State(initialValue: category?.colorName ?? "blue")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool {
        categories.contains { $0.id != category?.id && $0.kind == kind && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        IconBadge(symbol: symbol, color: Theme.color(named: colorName), size: 64)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    TextField("Name", text: $name)
                    if isDuplicate {
                        Text("A category with this name already exists.").font(.caption).foregroundStyle(Theme.negative)
                    }
                }
                Section("Color") { ColorSwatchPicker(selection: $colorName) }
                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(Self.symbols, id: \.self) { item in
                            Image(systemName: item)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .foregroundStyle(item == symbol ? .white : .primary)
                                .background(item == symbol ? AnyShapeStyle(Theme.color(named: colorName).gradient)
                                                           : AnyShapeStyle(Color.secondary.opacity(0.12)), in: Circle())
                                .onTapGesture { symbol = item }
                                .accessibilityLabel(item.replacingOccurrences(of: ".", with: " "))
                                .accessibilityAddTraits(item == symbol ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(category == nil ? "New Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(trimmedName.isEmpty || isDuplicate)
                }
            }
        }
    }

    private func save() {
        if let category {
            category.name = trimmedName
            category.symbol = symbol
            category.colorName = colorName
        } else {
            let order = (categories.filter { $0.kind == kind && !$0.isSystem }.map(\.sortOrder).max() ?? 0) + 1
            context.insert(TransactionCategory(name: trimmedName, kind: kind, symbol: symbol, colorName: colorName, sortOrder: order))
        }
        try? context.save()
        dismiss()
    }
}
