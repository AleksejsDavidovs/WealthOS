import Foundation
import SwiftData

/// Suggests a category for a bank transaction. Order of trust:
/// 1. what the user taught WealthOS for this counterparty (a remembered rule / an edited category),
/// 2. the card network's merchant category code (MCC),
/// 3. well-known merchant names in the counterparty or payment details.
/// It only ever picks among the user's existing categories (matched by name); a renamed or
/// deleted category simply isn't suggested, and the kind's fallback ("Other") is used instead.
enum BankCategorizer {
    enum Source: Equatable { case learned, merchantCode, keyword }

    struct Suggestion: Equatable {
        var categoryID: UUID
        var source: Source
    }

    static func suggest(for row: BankTransaction, kind: CategoryKind, categories: [TransactionCategory],
                        rules: [BankCounterpartyRule]) -> Suggestion? {
        let usable = categories.filter { $0.kind == kind }
        if let rule = BankReconciler.rule(for: row, rules: rules), let id = rule.categoryID,
           usable.contains(where: { $0.id == id }) {
            return Suggestion(categoryID: id, source: .learned)
        }
        if kind == .expense, let name = categoryName(merchantCode: row.merchantCategoryCode),
           let id = category(named: name, in: usable) {
            return Suggestion(categoryID: id, source: .merchantCode)
        }
        if let name = categoryName(text: row.counterpartyName + "\n" + row.remittance, kind: kind),
           let id = category(named: name, in: usable) {
            return Suggestion(categoryID: id, source: .keyword)
        }
        return nil
    }

    /// The suggestion, or the kind's system fallback category.
    static func categoryID(for row: BankTransaction, kind: CategoryKind, categories: [TransactionCategory],
                           rules: [BankCounterpartyRule]) -> UUID? {
        suggest(for: row, kind: kind, categories: categories, rules: rules)?.categoryID
            ?? categories.first { $0.kind == kind && $0.isSystem }?.id
    }

    /// Other names people give the same category (renamed or in another language).
    static let categoryAliases: [String: [String]] = [
        "Food": ["groceries", "grocery", "food drinks", "food and drinks", "food groceries", "partika", "produkti",
                 "еда", "продукты", "питание"],
        "Transport": ["transportation", "transports", "транспорт"],
        "Shopping": ["iepirksanas", "покупки", "шопинг"],
        "Health": ["veseliba", "здоровье"],
        "Car": ["auto", "машина", "авто"],
    ]

    private static func category(named name: String, in categories: [TransactionCategory]) -> UUID? {
        let names = [name] + (categoryAliases[name] ?? [])
        for candidate in names {
            let wanted = BankHash.normalizedName(candidate)
            if let id = categories.first(where: { BankHash.normalizedName($0.name) == wanted })?.id { return id }
        }
        return nil
    }

    /// Swedbank Latvia labels card purchases "PIRKUMS" in the payment details; production data
    /// carries no merchant category code, so this word is what marks a card purchase.
    static func isCardPurchase(_ row: BankTransaction) -> Bool {
        let text = " " + BankHash.normalizedName(row.counterpartyName + "\n" + row.remittance) + " "
        return cardPurchaseWords.contains { text.contains(" \($0) ") }
    }

    static let cardPurchaseWords = ["pirkums", "pirkumi"]
    /// Words in purchase details that don't identify the shop: currencies and company forms.
    static let merchantNoiseWords: Set<String> = ["eur", "usd", "gbp", "sek", "nok", "dkk", "pln", "chf", "sia", "as", "ik", "lv"]

    // MARK: Merchant category codes (ISO 18245)

    static func categoryName(merchantCode: String) -> String? {
        guard merchantCode.count == 4, let code = Int(merchantCode) else { return nil }
        switch code {
        case 6010, 6011: return nil // cash: never an expense category
        case 5411, 5412, 5422, 5441, 5451, 5462, 5499, 5811, 5812, 5813, 5814: return "Food"
        case 4111, 4112, 4121, 4131, 4511, 4582, 4784, 4789, 3000...3299: return "Transport"
        case 5172, 5531...5533, 5541, 5542, 5552, 5571, 7511, 7523, 7531, 7534, 7535, 7538, 7542, 7549: return "Car"
        case 4899, 5815...5818, 5968: return "Subscriptions"
        case 7832, 7841, 7911, 7922, 7929, 7932, 7933, 7941, 7991, 7992, 7994, 7996, 7997, 7998, 7999: return "Entertainment"
        case 5047, 5122, 5912, 5975, 5976, 8011, 8021, 8031, 8041...8049, 8050, 8062, 8071, 8099: return "Health"
        case 5942, 5943, 8211, 8220, 8241, 8244, 8249, 8299: return "Education"
        case 5200...5399, 5600...5699, 5700...5799, 5900...5999: return "Shopping"
        default: return nil
        }
    }

    // MARK: Merchant names (Latvia-first, plus common international services)

    static let expenseKeywords: [(String, [String])] = [
        ("Food", ["rimi", "maxima", "lidl", "elvi", "mego", "aibe", "citro", "spar", "lats", "nelss", "boozie", "sanitex",
                  "vendings", "vending", "wolt", "bolt food", "mcdonalds",
                  "hesburger", "lido", "kfc", "burger king", "subway", "narvesen", "caffeine", "coffee address",
                  "cafe", "kafejnica", "restorans", "restaurant", "pizza", "picerija", "bakery", "maiznica"]),
        ("Car", ["circle k", "neste", "virsi", "viada", "gotika", "orlen", "parking", "stavvieta", "autostavvieta",
                 "mobilly", "europark", "csdd", "autoserviss", "car wash", "auto mazgatava"]),
        ("Transport", ["bolt", "uber", "rigas satiksme", "satiksme", "pasazieru vilciens", "vivi", "airbaltic", "ryanair",
                       "wizz air", "flixbus", "lux express", "ecolines", "taxi", "taksometrs", "citybee", "fiqsy"]),
        ("Subscriptions", ["spotify", "netflix", "youtube premium", "apple com bill", "icloud", "google storage",
                           "google one", "disney plus", "hbo max", "go3", "tet", "lmt", "bite", "tele2", "chatgpt",
                           "openai", "adobe", "microsoft 365", "dropbox", "patreon"]),
        ("Health", ["apotheka", "aptieka", "euroaptieka", "benu", "meness aptieka", "veselibas centrs", "medicine",
                    "zobarstnieciba", "dental", "clinic", "klinika", "laboratorija", "egv", "mfd"]),
        ("Entertainment", ["forum cinemas", "apollo kino", "kino", "cinema", "bilesu serviss", "bilesu paradize", "steam",
                           "playstation", "xbox", "nintendo", "teatris", "theatre", "koncerts", "concert", "boulinga"]),
        ("Education", ["udemy", "coursera", "skillshare", "duolingo", "universitate", "university", "skola", "school",
                       "kursi", "course", "gramatnica", "janis roze", "valters un rapa"]),
        ("Shopping", ["ikea", "depo", "jysk", "k rauta", "h m", "zara", "lindex", "reserved", "sportland",
                      "decathlon", "euronics", "rd electronics", "elkor", "220 lv", "amazon", "aliexpress", "temu",
                      "zalando", "pepco", "drogas", "douglas", "humana"]),
    ]

    static let incomeKeywords: [(String, [String])] = [
        ("Salary", ["alga", "darba alga", "salary", "payroll", "wages", "atalgojums"]),
        ("Freelance", ["invoice", "rekins", "honorars", "freelance", "upwork", "fiverr"]),
        ("Gifts", ["davana", "gift", "dzimsanas diena", "birthday"]),
    ]

    /// Whole-word match on the normalized text, so "rimi" matches "RIMI Imanta" but not "primi".
    static func categoryName(text: String, kind: CategoryKind) -> String? {
        let normalized = " " + BankHash.normalizedName(text) + " "
        guard normalized.count > 2 else { return nil }
        let table = kind == .expense ? expenseKeywords : incomeKeywords
        for (category, words) in table where words.contains(where: { normalized.contains(" " + BankHash.normalizedName($0) + " ") }) {
            return category
        }
        return nil
    }
}

// MARK: - Learning from the user's corrections

enum BankCategoryLearning {
    /// Called when the user changes the category of a bank-imported record. Remembers it for this
    /// counterparty (future transactions are recorded with it) and moves the counterparty's other
    /// imported records that still carry the old category. Records the user categorized
    /// differently are left alone. Returns how many other records were updated.
    /// Callers wrap this in `Persistence.commit`.
    @discardableResult
    static func learn(record: TransactionRecord, oldCategoryID: UUID?, in context: ModelContext, now: Date = .now) throws -> Int {
        guard BankReconciler.isBankImport(record), let newCategoryID = record.categoryID, newCategoryID != oldCategoryID,
              record.kind == .income || record.kind == .expense else { return 0 }
        let recordID = record.id
        let bankRows = try context.fetch(FetchDescriptor<BankTransaction>())
        guard let row = bankRows.first(where: { $0.ledgerRecordID == recordID }),
              let key = BankReconciler.ruleKeys(for: row).first else { return 0 }
        let direction = row.amount < 0 ? "out" : "in"
        let action: BankRuleAction = record.kind == .income ? .income : .expense
        for old in try context.fetch(FetchDescriptor<BankCounterpartyRule>()) where old.matchKey == key && old.direction == direction {
            context.delete(old)
        }
        context.insert(BankCounterpartyRule(matchKey: key, direction: direction, action: action, categoryID: newCategoryID,
                                            otherAccountID: nil, label: row.title, createdAt: now))
        // Same counterparty, same direction, already imported, still on the old category.
        let siblingIDs = Set(bankRows.filter { other in
            other.id != row.id && other.resolution == .imported && (other.amount < 0) == (row.amount < 0)
                && BankReconciler.ruleKeys(for: other).first == key
        }.compactMap(\.ledgerRecordID))
        guard !siblingIDs.isEmpty else { return 0 }
        var moved = 0
        for sibling in try context.fetch(FetchDescriptor<TransactionRecord>())
        where siblingIDs.contains(sibling.id) && sibling.kind == record.kind && sibling.categoryID == oldCategoryID {
            sibling.categoryID = newCategoryID
            moved += 1
        }
        return moved
    }
}

// MARK: - Applying improved rules to what was already imported

enum BankCategoryReapply {
    struct Result: Equatable { var recorded = 0; var recategorized = 0 }

    /// Brings already-downloaded rows up to the current rules, without touching user choices:
    /// - card purchases / recognised merchants still waiting in review are recorded as expenses;
    /// - imported expenses that landed in the fallback category ("Other") get a suggested category.
    /// Records whose category the user picked are left alone (a learned rule wins over keywords,
    /// and only fallback-category records are considered). Callers wrap it in `Persistence.commit`.
    @discardableResult
    static func run(in context: ModelContext, now: Date = .now) throws -> Result {
        var result = Result()
        let categories = try context.fetch(FetchDescriptor<TransactionCategory>())
        let rules = try context.fetch(FetchDescriptor<BankCounterpartyRule>())
        guard let fallback = categories.first(where: { $0.kind == .expense && $0.isSystem })?.id else { return result }
        let rows = try context.fetch(FetchDescriptor<BankTransaction>())

        for row in rows where BankReview.isBulkRecordable(row) && row.amount < 0 {
            let suggestion = BankCategorizer.suggest(for: row, kind: .expense, categories: categories, rules: rules)
            guard suggestion != nil || BankCategorizer.isCardPurchase(row) else { continue }
            do {
                try BankReview.resolve(row, decision: .expense(categoryID: suggestion?.categoryID), remember: false,
                                       now: now, in: context)
                result.recorded += 1
            } catch BankingError.currencyMismatch {
                continue
            }
        }

        let imported = Dictionary(rows.filter { $0.resolution == .imported && $0.amount < 0 }
            .compactMap { row in row.ledgerRecordID.map { ($0, row) } }, uniquingKeysWith: { a, _ in a })
        guard !imported.isEmpty else { return result }
        for record in try context.fetch(FetchDescriptor<TransactionRecord>())
        where record.kind == .expense && record.categoryID == fallback && BankReconciler.isBankImport(record) {
            guard let row = imported[record.id],
                  let suggestion = BankCategorizer.suggest(for: row, kind: .expense, categories: categories, rules: rules),
                  suggestion.categoryID != fallback else { continue }
            record.categoryID = suggestion.categoryID
            result.recategorized += 1
        }
        return result
    }
}
