import Foundation
import CryptoKit
import SwiftData

/// RFC 4180 CSV reading/writing for transactions.
nonisolated enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
        var content = text
        if content.hasPrefix("\u{FEFF}") { content.removeFirst() }
        let delimiter = detectDelimiter(content)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(content).makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                inQuotes = true
            } else if character == delimiter {
                row.append(field); field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        }
        return rows
    }

    /// Semicolon-delimited files are common in European spreadsheet exports.
    static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" }
        let commas = firstLine.filter { $0 == "," }.count
        let semicolons = firstLine.filter { $0 == ";" }.count
        return semicolons > commas ? ";" : ","
    }

    static func escape(_ value: String) -> String {
        var safe = value
        // Neutralize spreadsheet formula injection.
        if let first = safe.first, "=+-@".contains(first), Decimal(string: safe) == nil { safe = "'" + safe }
        if safe.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == ";" }) {
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return safe
    }
}

enum CSVService {
    static let header = ["date", "type", "amount", "currency", "account", "to_account", "to_amount", "category", "note"]

    private static var isoDay: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    // MARK: Export

    static func export(transactions: [TransactionRecord], accounts: [Account], categories: [TransactionCategory]) -> String {
        let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let categoriesByID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let formatter = isoDay
        var lines = [header.joined(separator: ",")]
        for transaction in transactions.sorted(by: { $0.date < $1.date }) {
            let account = accountsByID[transaction.accountID]
            let destination = transaction.destinationAccountID.flatMap { accountsByID[$0] }
            let fields = [
                formatter.string(from: transaction.date),
                transaction.kind.rawValue,
                "\(transaction.amount)",
                account?.currencyCode ?? "",
                account?.name ?? "",
                destination?.name ?? "",
                transaction.destinationAmount.map { "\($0)" } ?? "",
                transaction.categoryID.flatMap { categoriesByID[$0]?.name } ?? "",
                transaction.note
            ]
            lines.append(fields.map(CSVParser.escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Import

    struct ParsedRow: Identifiable {
        let id = UUID()
        let line: Int
        let kind: TransactionKind
        let amount: Decimal
        let destinationAmount: Decimal?
        let date: Date
        let note: String
        let accountID: UUID
        let destinationAccountID: UUID?
        let categoryName: String?
        let fingerprint: String
    }

    struct RowError: Identifiable {
        let id = UUID()
        let line: Int
        let message: String
    }

    struct ImportPreview {
        var rows: [ParsedRow] = []
        var duplicates: [ParsedRow] = []
        var errors: [RowError] = []
        var newCategories: [String] = []
        var fileHash: String = ""
        var fileAlreadyImported = false
    }

    enum ImportError: LocalizedError {
        case empty
        case missingColumns([String])

        var errorDescription: String? {
            switch self {
            case .empty: "The file doesn't contain any rows."
            case .missingColumns(let columns): "Missing required columns: \(columns.joined(separator: ", "))."
            }
        }
    }

    /// Stable identity used to detect duplicates: day, type, amount, accounts and note.
    static func fingerprint(date: Date, kind: TransactionKind, amount: Decimal, accountID: UUID,
                            destinationAccountID: UUID?, note: String) -> String {
        let day = isoDay.string(from: date)
        // Fixed 2-decimal POSIX formatting so 4.5 and 4.50 produce the same key.
        let amountKey = Money.round(amount).formatted(.number.precision(.fractionLength(2)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
        let raw = [day, kind.rawValue, amountKey, accountID.uuidString, destinationAccountID?.uuidString ?? "",
                   note.trimmingCharacters(in: .whitespaces).lowercased()].joined(separator: "|")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func fileHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for format in ["yyyy-MM-dd", "dd.MM.yyyy", "dd/MM/yyyy", "yyyy/MM/dd", "yyyy-MM-dd'T'HH:mm:ss", "d.M.yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: trimmed) {
                // Normalize to noon to avoid time-zone day shifts.
                return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            }
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    static func preview(data: Data, accounts: [Account], categories: [TransactionCategory],
                        existing: [TransactionRecord], importedHashes: [String]) throws -> ImportPreview {
        let text = String(decoding: data, as: UTF8.self)
        let table = CSVParser.parse(text)
        guard let headerRow = table.first, table.count > 1 else { throw ImportError.empty }
        let columns = headerRow.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let required = ["date", "amount", "account"]
        let missing = required.filter { !columns.contains($0) }
        guard missing.isEmpty else { throw ImportError.missingColumns(missing) }
        func index(_ name: String) -> Int? { columns.firstIndex(of: name) }

        var preview = ImportPreview()
        preview.fileHash = fileHash(data)
        preview.fileAlreadyImported = importedHashes.contains(preview.fileHash)

        let accountsByName = Dictionary(accounts.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        // Multiset of existing fingerprints so identical legitimate rows are not all rejected.
        var existingCounts: [String: Int] = [:]
        for transaction in existing {
            let key = transaction.importFingerprint ?? fingerprint(date: transaction.date, kind: transaction.kind,
                                                                   amount: transaction.amount, accountID: transaction.accountID,
                                                                   destinationAccountID: transaction.destinationAccountID,
                                                                   note: transaction.note)
            existingCounts[key, default: 0] += 1
        }
        var newCategoryNames = Set<String>()

        for (offset, row) in table.dropFirst().enumerated() {
            let line = offset + 2
            func value(_ name: String) -> String {
                guard let i = index(name), i < row.count else { return "" }
                return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }

            guard let date = parseDate(value("date")) else {
                preview.errors.append(RowError(line: line, message: "Invalid date \"\(value("date"))\".")); continue
            }
            guard let parsedAmount = DecimalParser.parse(value("amount"), locale: Locale(identifier: "en_US_POSIX")),
                  parsedAmount.value != 0, parsedAmount.fractionDigits <= 2,
                  abs(parsedAmount.value) <= AmountValidation.maximumAmount else {
                preview.errors.append(RowError(line: line, message: "Invalid amount \"\(value("amount"))\".")); continue
            }
            var kind: TransactionKind
            let typeText = value("type").lowercased()
            if typeText.isEmpty {
                kind = parsedAmount.value < 0 ? .expense : .income
            } else if let parsed = TransactionKind(rawValue: typeText), parsed != .adjustment {
                kind = parsed
            } else {
                preview.errors.append(RowError(line: line, message: "Unknown type \"\(typeText)\".")); continue
            }
            let amount = abs(parsedAmount.value)
            guard let account = accountsByName[value("account").lowercased()] else {
                preview.errors.append(RowError(line: line, message: "Unknown account \"\(value("account"))\". Create it first.")); continue
            }
            var destinationID: UUID?
            var destinationAmount: Decimal?
            if kind == .transfer {
                guard let destination = accountsByName[value("to_account").lowercased()], destination.id != account.id else {
                    preview.errors.append(RowError(line: line, message: "Transfer needs a different, existing destination account.")); continue
                }
                destinationID = destination.id
                if let toAmount = DecimalParser.parse(value("to_amount"), locale: Locale(identifier: "en_US_POSIX")), toAmount.value > 0 {
                    destinationAmount = toAmount.value
                }
            }
            if let currency = Optional(value("currency")), !currency.isEmpty, currency.uppercased() != account.currencyCode {
                preview.errors.append(RowError(line: line, message: "Currency \(currency) doesn't match account currency \(account.currencyCode).")); continue
            }
            var categoryName: String?
            if let categoryKind = kind.categoryKind {
                let name = value("category")
                if !name.isEmpty {
                    categoryName = name
                    let exists = categories.contains { $0.kind == categoryKind && $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    if !exists { newCategoryNames.insert(name) }
                }
            }
            let note = value("note")
            let key = fingerprint(date: date, kind: kind, amount: amount, accountID: account.id,
                                  destinationAccountID: destinationID, note: note)
            let parsed = ParsedRow(line: line, kind: kind, amount: amount, destinationAmount: destinationAmount, date: date,
                                   note: note, accountID: account.id, destinationAccountID: destinationID,
                                   categoryName: categoryName, fingerprint: key)
            if let count = existingCounts[key], count > 0 {
                existingCounts[key] = count - 1
                preview.duplicates.append(parsed)
            } else {
                preview.rows.append(parsed)
            }
        }
        preview.newCategories = newCategoryNames.sorted()
        return preview
    }

    /// Inserts the non-duplicate rows. Missing categories are created; rows without a
    /// category go to the kind's fallback category.
    static func commit(_ preview: ImportPreview, into context: ModelContext) throws -> Int {
        var categories = try context.fetch(FetchDescriptor<TransactionCategory>())
        func category(named name: String?, kind: CategoryKind) -> UUID {
            if let name, let match = categories.first(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return match.id
            }
            if let name {
                let created = TransactionCategory(name: name, kind: kind, symbol: "tag.fill", colorName: "gray", sortOrder: 50)
                context.insert(created)
                categories.append(created)
                return created.id
            }
            return LedgerService.fallbackCategory(for: kind, in: context).id
        }
        for row in preview.rows {
            let categoryID = row.kind.categoryKind.map { category(named: row.categoryName, kind: $0) }
            context.insert(TransactionRecord(kind: row.kind, amount: row.amount, destinationAmount: row.destinationAmount,
                                             date: row.date, note: row.note, accountID: row.accountID,
                                             destinationAccountID: row.destinationAccountID, categoryID: categoryID,
                                             importFingerprint: row.fingerprint))
        }
        try context.save()
        var hashes = UserDefaults.standard.stringArray(forKey: SettingsKey.importedFileHashes) ?? []
        if !hashes.contains(preview.fileHash) { hashes.append(preview.fileHash) }
        UserDefaults.standard.set(Array(hashes.suffix(200)), forKey: SettingsKey.importedFileHashes)
        return preview.rows.count
    }
}
